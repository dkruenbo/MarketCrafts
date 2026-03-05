# MarketCrafts — Addon Source

This directory is the WoW addon package. Copy it directly into `Interface/AddOns/`.

---

## File Overview

| File | Purpose |
|---|---|
| `MarketCrafts.toc` | Addon manifest — load order, interface version, SavedVariables |
| `MarketCrafts.lua` | Core addon, lifecycle hooks, slash commands, listing + request management API |
| `Channel.lua` | M1 channel state machine — joins/maintains `MCMarket[N]` pool with convergence |
| `Broadcast.lua` | Outbound message queue — listings, requests, keep-alive, back-off |
| `Listener.lua` | Inbound parser — feeds `[MCR]` messages into Cache (listings) and Requests (WTB) |
| `Cache.lua` | In-memory peer listing cache — TTL, rate limiting, blocklist, async icon resolution |
| `Requests.lua` | F7 buyer request cache — TTL, per-buyer cap, name-based keying |
| `ChatFilter.lua` | Suppresses `[MCR]` messages from all chat frames |
| `MinimapButton.lua` | Draggable minimap button with live crafter count tooltip |
| `UI.lua` | AceGUI tabbed window — My Listings, Browse, and Requests panels |
| `MockData.lua` | `/mc sim` commands for single-account testing |
| `Libs/` | Bundled Ace3 libraries (see below) |

---

## Slash Commands

```
/mc              — open/close the Market window
/mc optin        — start broadcasting your listings
/mc optout       — stop broadcasting
/mc list         — print your active listings to chat
/mc ignore <X>   — hide player X's listings
/mc unignore <X> — restore player X's listings
/mc importalt    — save current char's listings as alt profile (all chars broadcast them)
/mc request      — open the Requests (WTB) tab
/mc template [t] — view/set whisper template ({seller}, {item}, {prof} tokens)
/mc favorites    — list your starred sellers
/mc debug        — toggle debug/verbose mode
/mc sim <N>      — inject N fake sellers (debug mode required)
/mc sim clear    — remove all simulated listings
/mc help         — print all commands
```

---

## Adding a Listing

Open a profession window from your spellbook, then click **Add from Profession** in the My Listings tab. Search for a recipe, optionally type a crafter note, and click **Add**.

### Advanced: scripted use

```lua
/run MarketCrafts:AddMyListing(22861, "Alchemy", "Flask of Supreme Power", "Free for guildies", nil)
-- Arguments: itemID, profName, itemName, note (optional), cdSeconds (optional)
```

---

## Wire Protocol

| Prefix | Format | Purpose |
|---|---|---|
| `[MCR]L:` | `itemID,prof,name[,note[,cdSeconds]]` | Listing (3/4/5 field) |
| `[MCR]R:` | `itemID` | Remove listing |
| `[MCR]Q:` | `itemName[,note]` | Buyer request (WTB) |
| `[MCR]QR:` | `itemName` | Remove buyer request |

All payloads are hard-truncated to 255 characters. Sender identity comes from chat metadata.

---

## Bundled Libraries (`Libs/`)

| Library | Purpose |
|---|---|
| `LibStub` | Library version management |
| `CallbackHandler-1.0` | Event callback glue (AceEvent dependency) |
| `AceAddon-3.0` | Addon lifecycle and module system |
| `AceEvent-3.0` | WoW event registration |
| `AceTimer-3.0` | Reliable timer scheduling |
| `AceDB-3.0` | SavedVariables with character + account scoping |
| `AceConsole-3.0` | Slash command and print helpers |
| `AceGUI-3.0` | UI widget framework (includes all widget files) |

All libraries are bundled — the addon does not rely on shared libraries from other addons.

---

## Testing Checklist

Enable taint logging before each session:
```
/run SetCVar("taintLog", 1)
```
Then `/reload` and check `Interface/Logs/taint.log` after testing.

**Phase 0**: `/mc help` prints command list. Zero errors in BugSack.

**M1**: Channel joined within 15s of login. Debug mode shows channel settle messages.

**M2**: Add a listing, `/mc list`, `/reload` — listing persists.

**M3 (single account)**: `/mc debug` → `/mc sim 5` → open `/mc` → listings appear in Browse. `/mc sim clear` removes them.

**M3 (two accounts)**: Account A `/mc optin`, add listing. Account B sees it in Browse within ~2s.

**Requests (two accounts)**: Account A posts a request. Account B sees it in Requests tab. "Craft" button pre-fills whisper.

**Cross-alt**: `/mc importalt` on a character with listings. Log alt → `/mc` → My Listings shows alt entries under "Alt Listings" heading.

**Taint**: Zero entries in taint log after any test session.
