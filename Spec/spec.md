# MarketCrafts — Feature Specification

> **Addon:** MarketCrafts (standalone)
> **Game:** World of Warcraft — Burning Crusade Classic 2.5.5
> **Source issue:** [GuildCrafts #10 — Craft Marketplace](https://github.com/dkruenbo/GuildCrafts/issues/10)
> **Date:** 2026-03-02

---

## Overview

MarketCrafts is a standalone WoW Burning Crusade Classic addon providing a **server-wide crafting service board**. Any player with the addon can list up to 5 recipes they are willing to craft as a service. Other addon users passively receive those listings and can contact sellers directly via whisper.

WoW TBC Classic has no native server-wide crafting service discovery tool. MarketCrafts fills that gap without replacing the Auction House or automating any trading.

---

## Goals

- Allow players to advertise crafting services across the entire server population using the addon.
- Keep the system fully **opt-in**: no data is ever sent unless a player explicitly marks a recipe for sale.
- Be **spam-safe**: passive broadcast model eliminates request/response storms.
- Stay **TOS-compliant**: human-readable wire format, no automated matching, no price aggregation.
- Be **resilient**: handle channel hijacking, join failures, and server-side spam muting gracefully.

## Non-Goals

- Not an Auction House replacement — no price data, no automated trade execution.
- Not integrated with GuildCrafts — MarketCrafts is a fully separate addon.
- No cross-realm support beyond the `PlayerName-Realm` tag embedded in messages.
- No guild-only visibility (the market is server-wide by design).

---

## Architecture

### Module Layout

| File | Responsibility |
|---|---|
| `MarketCrafts.lua` | Addon init, SavedVariables bootstrap, slash command registration |
| `Channel.lua` | Join/leave `MCMarket`, fallback chain, resilience event handling |
| `Broadcast.lua` | Encode and send `[MCR]L:` / `[MCR]R:` messages, keep-alive timer |
| `Listener.lua` | `CHAT_MSG_CHANNEL` handler — parse incoming messages, write to cache |
| `Cache.lua` | In-memory listing store, 30-min TTL, rate limiting, validation |
| `ChatFilter.lua` | `ChatFrame_AddMessageEventFilter` — suppress `[GC]` messages from chat |
| `UI.lua` | Market window, listing display, search/sort, Whisper button, My Listings panel |

### SavedVariables

```lua
-- Persisted via AceDB-3.0
MarketCraftsDB = {
    myListings = {
        -- up to 5 entries
        { itemID = 22861, profName = "Alchemy", spec = "Potions Master", tip = "Free for guildies" },
    },
    blocklist = {
        ["PlayerName"] = true,  -- character-scoped; TBC Classic is not cross-realm
    },
    settings = {
        optedIn         = false,
        lastBroadcast   = 0,      -- Unix timestamp of last manual broadcast
        refreshCooldown = 900,    -- 15 minutes in seconds
    },
}
```

---

## Communication Protocol

### Channel

- **Channel pool:** `MCMarket`, `MCMarket1`, `MCMarket2`, `MCMarket3`, `MCMarket4` (indices 0–4).
- WoW TBC Classic allows a maximum of **10 custom channels**. Warn the player in chat if no slot is available. Do not block addon load.
- After successfully joining: immediately call `ChatFrame_RemoveChannel` for **all chat frames** to prevent the "Joined Channel" notice and block accidental player input: `for i = 1, NUM_CHAT_WINDOWS do ChatFrame_RemoveChannel(_G["ChatFrame"..i], channelName) end`. Applying it only to `ChatFrame1` leaves the channel visible in split or addon-added frames (e.g. Prat).

#### Initial Join — Walk Down From Index 0

On login, attempt channels in order starting from `MCMarket` (index 0). Join the first one that succeeds (`YOU_JOINED`). This is the **active channel**. Store its index.

#### Channel Convergence — Periodic Re-Validate and Re-Join

Two isolation problems must be handled:

1. **Joined at a higher index:** A client that landed on `MCMarket2` because lower channels were locked stays there even after those channels are cleared, permanently separated from users in `MCMarket`.
2. **Hijacked after join:** WoW does **not** kick existing members when a channel is password-locked. A user already sitting in `MCMarket` when it gets hijacked remains silently inside a channel that no new user can enter. They appear connected but are isolated from all future joiners.

The only reliable way to detect case 2 is to **leave and attempt to rejoin**. A passive in-channel health check is not sufficient.

**Solution:** Every **10 minutes**, every client — regardless of current active index — performs a full re-validate cycle:

1. Leave the current channel (`LeaveChannelByName`). This is a player-initiated leave; set a flag so the `YOU_LEFT` handler does not trigger an accidental rejoin.
2. Walk down from index 0: attempt `MCMarket`, then `MCMarket1`, … in order.
3. **Per-step timeout:** After each `JoinChannelByName` call, wait up to **5 seconds** for `CHAT_MSG_CHANNEL_NOTICE`. If no notice arrives within that window (silent server error, packet loss), advance to the next fallback index. Without this, the walk stalls indefinitely if WoW never fires the notice.
4. Join the first channel that returns `YOU_JOINED`. Update `activeIndex`. Remove the channel from all chat frames. Resume broadcasting on the new channel.
5. **Re-broadcast only on channel change:** If `activeIndex` changed, immediately re-broadcast all listings so peers on the new channel have current data. If the client landed on the same index as before, do not re-broadcast — no disruption, no extra channel traffic.
6. If all channels fail: disable market features, notify the user, and schedule a retry in 15 minutes.

This guarantees that **all clients converge to the lowest open channel** and that **no client silently remains inside a hijacked channel** longer than 10 minutes.

### Wire Format

Messages are sent via `SendChatMessage` (visible text in the custom channel), **not** `SendAddonMessage`. This is required because `SendAddonMessage` does not support custom channels.

```
[MCR]L:<itemID>,<profession>,<itemName>
[MCR]R:<itemID>
```

| Prefix | Meaning | Fields |
|---|---|---|
| `[MCR]L:` | Listing create or update | itemID, profession, itemName |
| `[MCR]R:` | Listing remove | itemID |

**Field constraints:**

| Field | Type | Constraint |
|---|---|---|
| `itemID` | Integer | Valid WoW TBC item ID |
| `profession` | String | e.g. `Alchemy`, `Enchanting` |
| `itemName` | String | Item name in the sender's client locale — for human readability in raw chat; addon receivers use `itemID` to resolve locale-correct name and icon locally |
| Full payload | String | Hard max **255 characters** — `string.sub(payload, 1, 255)` applied before send |

**Item IDs are the authoritative identifier.** Item names are included so non-addon players can read raw `[MCR]L:` messages in the channel. Addon receivers call `GetItemInfo(itemID)` to resolve the locale-correct name and icon on their own client.

**Examples:**

```
[MCR]L:22861,Alchemy,Flask of Supreme Power
[MCR]L:27984,Enchanting,Enchant Weapon - Crusader
[MCR]R:22861
```

The sender's identity (`PlayerName`) is read from the chat message metadata — it is never included in the payload.

### Broadcast Model — Passive Broadcast, No Request/Response

There are **no request or polling messages**. The protocol is purely:

1. Sellers broadcast listings on specific player-initiated triggers.
2. Listeners passively cache what they receive.
3. Cache entries expire after 30 minutes.

This is O(1) traffic per seller action instead of the O(N) response storm a request/response model would cause.

### Broadcast Triggers & Timing

| Trigger | Action |
|---|---|
| Login | Wait **10–15 seconds** (`AceTimer-3.0` random jitter) then join channel and broadcast all listings |
| Add or update a listing | Broadcast that listing immediately |
| Remove a listing | Send `[MCR]R:<itemID>` immediately |
| Keep-alive timer | Auto re-broadcast all listings every **20 minutes** (well under the 30-min TTL) |
| Manual "Refresh My Listings" button | Re-broadcast all listings; **15-minute cooldown** between manual refreshes |

**Spacing:** When sending multiple messages in a single broadcast, space them **1–2 seconds apart**. Back off silently if the server-side spam filter mutes the player (detected via `CHAT_MSG_SYSTEM` with throttle message).

---

## Data Model

### Cached Listing Entry

```lua
{
    seller     = "PlayerName",
    itemID     = 22861,
    itemName   = "Flask of Supreme Power",  -- from wire format (sender's locale); displayed immediately
    itemIcon   = "Interface\\Icons\\...",   -- resolved async via GetItemInfo; nil until available
    profName   = "Alchemy",
    receivedAt = 1234567890,                 -- time() Unix timestamp for 30-min TTL check
}
```

### Item Resolution

- `itemName` is available immediately from the wire format (sender's locale) — no async wait needed for display.
- Call `GetItemInfo(itemID)` to resolve `itemIcon` (and the receiver's locale-correct name if preferred). If the item is not in the client cache, `itemIcon` returns `nil`.
- Register `GET_ITEM_INFO_RECEIVED` to handle async icon resolution: when fired, fill in `itemIcon` for any cache entries with that `itemID` and trigger a UI refresh. Display a fallback icon (question mark texture) until the icon resolves.
- If `GET_ITEM_INFO_RECEIVED` never fires for an `itemID` within **30 seconds**, the icon remains as the fallback — do not block or hide the listing.

### TTL & Cache Expiry

- Listings expire **30 minutes** after `receivedAt`.
- Stale entries are **hidden from UI** immediately when the list is rendered.
- A periodic scan (e.g. every 5 minutes via AceTimer) purges expired entries from memory.
- A seller's keep-alive re-broadcast (every 20 min) resets `receivedAt` for their entries.

---

## Chat Filter

The filter's **only responsibility** is suppressing `[GC]` messages from the chat window. Data parsing is done in a **completely separate** `CHAT_MSG_CHANNEL` handler. Mixing concerns risks UI taint.

```lua
-- ChatFilter.lua
-- Local function only. No globals, no closures over secure frames, no side effects.
local function MarketCraftsFilter(self, event, msg, author, ...)
    if msg and string.sub(msg, 1, 5) == "[MCR]" then
        return true  -- suppress from chat window
    end
    return false, msg, author, ...
end

ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", MarketCraftsFilter)
```

**Rules:**

- Function is `local` — no global pollution.
- No closures over secure frames or protected variables.
- No calls to protected or restricted API inside the callback.
- No modification of Blizzard UI elements.
- Test with `/run SetCVar("taintLog", 1)` and inspect output in BugSack / `!BugGrabber`.

---

## Validation & Anti-Abuse

| Rule | Detail |
|---|---|
| Max listings per sender | 5. Any `[GC]L:` beyond the 5th from the same sender in the cache is silently ignored. |
| Rate limiting | Track messages-per-minute per sender. Ignore the sender for the rest of that window if they exceed the threshold (default: 10 msg/min). |
| Item ID validation | Must be a positive integer. Reject if `tonumber(itemID) == nil` or `<= 0`. |
| Payload length | Reject any incoming message > 255 characters as malformed. |
| Field count | Reject messages with fewer than 2 comma-separated fields after the prefix. |
| Blocklist | `/mc ignore PlayerName` — all listings from that player are hidden. Stored in `MarketCraftsDB.blocklist`. |
| Own messages | A player's own `[MCR]` messages are received back from the channel server — skip them (compare sender against `UnitName("player")`; no realm suffix needed in TBC Classic). |

---

## Channel Resilience

| `CHAT_MSG_CHANNEL_NOTICE` Data String | Handling |
|---|---|
| `YOU_JOINED` | Success. Store channel index from `CHAT_MSG_CHANNEL_NOTICE`. Hide channel from chat frames. Begin broadcasting. |
| `WRONG_PASSWORD` | Channel is password-locked (hijacked). Try next fallback channel. |
| `BANNED` | Banned from channel. Try next fallback. |
| `YOU_LEFT` (unexpected, not player-initiated) | Re-join from index 0 (same as convergence cycle) — treat as an opportunity to re-validate. |
| `YOU_LEFT` (player-initiated, convergence re-validate cycle) | Expected. Walk down from index 0 and join the first open channel. Do not short-circuit back to the previous index. |
| All fallbacks exhausted (indices 0–4 all locked) | Disable all market features. Print to chat: `"MarketCrafts: Market unavailable — all MCMarket channels are locked."` Schedule a retry in 15 minutes. |

**Channel slot check:** Before joining, check `GetNumCustomChannels()`. If already at 10, print a warning and do not attempt to join. Do not block addon load.

---

## UI

### Market Window

Standalone window, opened via `/mc` or a minimap button.

**My Listings panel** (top section):

- Shows the player's own active listings (up to 5).
- "Add Listing" button — opens recipe picker.
- Remove button per row.
- "Refresh My Listings" button — re-broadcasts; greyed out with remaining cooldown shown when on cooldown.

**Browse panel** (main section):

| Column | Notes |
|---|---|
| Item | Icon + name. Icon shows fallback texture until `GetItemInfo` resolves async. |
| Profession | Text |
| Seller | `PlayerName` |
| Action | "Whisper" button → opens whisper to seller |

- **Search bar**: filters by item name, profession, or seller (case-insensitive substring match).
- **Sort**: clickable column headers (item name default).
- **Stale entries** (>30 min): automatically excluded from the rendered list.
- Listing count shown: `"Showing X listings from Y sellers"`.

### Slash Commands

| Command | Action |
|---|---|
| `/mc` | Toggle market window |
| `/mc ignore <PlayerName>` | Block all listings from that player |
| `/mc unignore <PlayerName>` | Remove player from blocklist |
| `/mc list` | Print own active listings to chat |
| `/mc help` | Print available commands |

---

## Milestone Sequence

| Milestone | Scope |
|---|---|
| **M1** | Custom channel join/leave with full fallback chain, per-step timeout, resilience event handling, and re-validate state machine (leave → timeout → walk from 0 → rejoin → conditional re-broadcast). The most complex piece of the addon. |
| **M2** | "List for Sale" toggle (max 5), SavedVariables persistence, recipe picker |
| **M3** | Passive broadcast (`[GC]L:` / `[GC]R:` via `SendChatMessage`) + taint-safe chat filter |
| **M4** | Market window: listing display, search/filter, Whisper button, My Listings panel |
| **M5** | Cache expiry (30-min TTL), rate limiting, validation, local blocklist |
| **M6** | Polish — advanced sort/filter, channel rotation, spam-filter backoff, cooldown UI |

---

## TOS & Blizzard Compliance Checklist

- [x] Max 5 listings per player (enforced in both UI and incoming message validation)
- [x] No automated matching or trade execution of any kind
- [x] No price data collection or aggregation
- [x] 100% opt-in — no data transmitted unless player explicitly opts in and lists a recipe
- [x] Human-readable wire format — no compressed or serialised blobs (avoids spam-filter gibberish triggers)
- [x] Broadcast-only protocol — no request/response message storms (F7 requests use the same passive broadcast model)
- [x] Outgoing messages spaced ≥ 1.5 seconds apart (with 3s back-off spacing during throttle)
- [x] Silent back-off on server-side spam-filter mute (5-minute suppression window)
- [x] Non-addon users see raw `[MCR]L:` / `[MCR]Q:` text — intentionally human-readable, not obfuscated

---

## As-Built Addendum (March 2026)

The sections above represent the **original design spec** written on 2 March 2026. The following documents deviations and additions made during implementation.

### Wire Format Extensions

The original 3-field listing format was extended to support crafter notes (F1) and cooldown broadcast (F6). A new request protocol (F7) was added for buyer WTB posts.

| Prefix | Format | Added In |
|---|---|---|
| `[MCR]L:` | `itemID,prof,name,note,cdSeconds` | F1 (4-field note), F6 (5-field cooldown) |
| `[MCR]Q:` | `itemName[,note]` | F7 — buyer request |
| `[MCR]QR:` | `itemName` | F7 — buyer request remove |

Parsers use cascade matching (5→4→3 field) for backward compatibility.

### Additional Modules

| File | Purpose | Added In |
|---|---|---|
| `Requests.lua` | Buyer request cache (TTL 1800s, max 3/buyer, name-keyed) | F7 |
| `MinimapButton.lua` | Draggable minimap button with live crafter count | M6 |
| `MockData.lua` | `/mc sim` testing framework | M6 |

### SavedVariables Schema (as-built)

```lua
MarketCraftsDB = {
    global = {
        altListings = {  -- F5: keyed by "Realm-CharName"
            ["Realm-Alt"] = { { itemID, profName, itemName, note }, ... }
        },
    },
    char = {
        myListings = {  -- up to 5
            { itemID, profName, itemName, note, cdSeconds, cdUpdatedAt },
        },
        myRequests = {  -- F7: up to 3
            { itemName, note },
        },
        blocklist  = { ["Name"] = true },
        favorites  = { ["Name"] = true },  -- F10
        settings = {
            optedIn           = false,
            lastBroadcast     = 0,
            refreshCooldown   = 900,
            minimapAngle      = 225,       -- radians, minimap button position
            whisperTemplate   = "Hi {seller}, I'd like {item} crafted!",  -- F4
        },
    },
}
```

### Additional Slash Commands

| Command | Added In |
|---|---|
| `/mc importalt` | F5 — cross-alt listing sync |
| `/mc request` | F7 — open Requests tab |
| `/mc template [text]` | F4 — whisper template |
| `/mc favorites` | F10 — list starred sellers |

### UI Changes

- Window uses a **TabGroup** with three tabs: My Listings, Browse, Requests (F7)
- Browse panel has **profession filter chips** (F2), **favourite star toggle** (F10), **expandable note/cooldown rows** (F1/F6), **freshness colour coding** (F9), **item tooltips + shift-click** (F8), and **right-click blocklist** (F11)
- My Listings panel shows **alt listings** section with per-entry remove and "Clear All" (F5)
- Recipe picker includes a **crafter note** field and captures **cooldown snapshot** from the open tradeskill window

### Resolved Design Decisions

| # | Decision | Resolution |
|---|---|---|
| 1 | Interface version | `20504` |
| 2 | Rate limit threshold | 10 msg/min per sender |
| 3 | Keep-alive interval | 20 minutes (no jitter — staggered by login-delay randomness) |
| 4 | Re-validate cycle | Removed (convergence handled by login walk + kick re-walk) |
