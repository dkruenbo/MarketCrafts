# MarketCrafts — Tech Stack

> **Addon:** MarketCrafts (standalone)
> **Game:** World of Warcraft — Burning Crusade Classic 2.5.5
> **Date:** 2026-03-02

---

## Platform

| | |
|---|---|
| **Game** | World of Warcraft — Burning Crusade Classic 2.5.5 |
| **Interface version** | `20504` / `20505` — verify against current live build before shipping |
| **Language** | Lua 5.1 (WoW embedded runtime) |
| **Addon format** | Standalone `.toc` + Lua source files |
| **Distribution** | CurseForge / WoWInterface ZIP — all libraries bundled |

---

## Core Libraries

### Ace3

Ace3 is the standard framework for structured WoW addon development. All modules are Ace3-based.

| Library | Usage |
|---|---|
| `AceAddon-3.0` | Addon lifecycle — `NewAddon`, `OnInitialize`, `OnEnable`, `OnDisable` |
| `AceEvent-3.0` | Event registration — `CHAT_MSG_CHANNEL`, `GET_ITEM_INFO_RECEIVED`, `CHAT_MSG_CHANNEL_NOTICE`, `PLAYER_LOGIN` |
| `AceTimer-3.0` | Keep-alive broadcast timer (25 min interval), login delay timer, cooldown tracking |
| `AceDB-3.0` | SavedVariables management — `MarketCraftsDB` **character-scoped**; TBC Classic is not cross-realm, no realm-scoping needed |
| `AceConsole-3.0` | `/mc` slash command parsing and dispatch |
| `LibStub` | Library bootstrapping — required by all Ace3 libs |
| `CallbackHandler-1.0` | Inter-module callback dispatch — required by Ace3 |

> **AceComm-3.0 is intentionally NOT used.**
> AceComm wraps `C_ChatInfo.SendAddonMessage`, which only works on `GUILD`, `PARTY`, `RAID`, and `WHISPER` channels. Custom channels like `MCMarket` require `SendChatMessage` instead. AceComm is not applicable here.

### Required Transitive Dependencies

| Library | Required By |
|---|---|
| `LibStub` | All Ace3 libraries |
| `CallbackHandler-1.0` | AceEvent-3.0, AceDB-3.0 |

---

## UI Framework — AceGUI-3.0

**Decided:** MarketCrafts uses **AceGUI-3.0** to match the look and feel of GuildCrafts.

- Scroll frames, edit boxes, buttons, dropdowns, and tabs are provided out-of-box — minimal boilerplate for the listing UI.
- Visual consistency with GuildCrafts is the primary driver: same window chrome, same widget style, same font.
- AceGUI-3.0 is bundled in the `Libs/` folder alongside the rest of the Ace3 suite.

---

## Communication Layer

| Mechanism | Purpose |
|---|---|
| `SendChatMessage(msg, "CHANNEL", nil, channelIndex)` | Broadcast `[MCR]L:` and `[MCR]R:` listing messages to `MCMarket` |
| `ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", fn)` | Suppress `[GC]` messages from all chat windows (taint-safe, local function only) |
| `CHAT_MSG_CHANNEL` event | Receive and parse incoming listing messages |
| `CHAT_MSG_CHANNEL_NOTICE` event | Handle channel join confirmations, leave events, and failure codes |
| `JoinChannelByName("MCMarket[N]")` | Join primary channel or fallback |
| `LeaveChannelByName("MCMarket[N]")` | Clean channel leave on disable or fallback rotation |
| `ChatFrame_RemoveChannel(ChatFrame1, "MCMarket[N]")` | Hide channel from chat frames after successful join |
| `GetNumCustomChannels()` | Pre-flight check — WoW TBC allows max 10 custom channels |

> **NOT used:** `C_ChatInfo.SendAddonMessage` / AceComm-3.0.
> `SendAddonMessage` does not support custom channels. Using it on `MCMarket` would silently fail or error.

---

## Data & Item Resolution

| Mechanism | Purpose |
|---|---|
| `SavedVariables` via `AceDB-3.0` | Persist own listings, blocklist, and settings across sessions (`MarketCraftsDB`) — character-scoped |
| In-memory Lua table | Peer listing cache — ephemeral, intentionally not persisted (stale on login anyway) |
| `GetItemInfo(itemID)` | Resolve item name, icon, and quality from a numeric item ID |
| `GET_ITEM_INFO_RECEIVED` event | Async callback for items not yet in the client cache; triggers UI refresh for pending entries |

**Why item IDs over item names in the wire format:**
EU realm servers host clients in English, German, and French. Item names differ per locale; item IDs are universal. Receivers always resolve names locally via `GetItemInfo`.

---

## Wire Format

Human-readable micro-format. No serialisation library (AceSerializer, LibDeflate) is used — compressed blobs would appear as gibberish to non-addon players and risk triggering Blizzard's spam detection.

```
[MCR]L:<itemID>,<profession>,<itemName>
[MCR]R:<itemID>
```

Payload enforcement at the send site:

```lua
local payload = string.format("[MCR]L:%d,%s,%s", itemID, prof, itemName)
payload = string.sub(payload, 1, 255)  -- SendChatMessage hard limit; truncation is silent
SendChatMessage(payload, "CHANNEL", nil, channelIndex)
```

---

## Timers & Scheduling

| Timer | Interval | Library |
|---|---|---|
| Login broadcast delay | 10–15 s random jitter after `PLAYER_LOGIN` | `AceTimer-3.0` |
| Keep-alive re-broadcast | Every 20 minutes | `AceTimer-3.0` scheduled repeating timer |
| Cache expiry scan | Every 5 minutes | `AceTimer-3.0` scheduled repeating timer |
| Message spacing | 1–2 seconds between queued outgoing messages | `AceTimer-3.0` one-shot chain |
| Manual refresh cooldown | 15 minutes tracked via `SavedVariables` timestamp | Timestamp diff on button click |
| Channel re-validate cycle | Every 10 minutes: leave current channel, walk down from index 0, rejoin first open channel; 5 s per-step timeout; re-broadcast only if channel index changed | `AceTimer-3.0` scheduled repeating timer; runs unconditionally for all clients |

---

## Addon File Structure

```
MarketCrafts/
├── MarketCrafts.toc
├── MarketCrafts.lua        -- core: init, module wiring, slash commands
├── Channel.lua             -- channel join/leave/fallback/resilience
├── Broadcast.lua           -- encode + send [GC]L: / [GC]R:, keep-alive timer
├── Listener.lua            -- CHAT_MSG_CHANNEL handler + parse into cache
├── Cache.lua               -- in-memory store, TTL, rate limiting, validation
├── ChatFilter.lua          -- ChatFrame_AddMessageEventFilter (suppress [GC] messages)
├── UI.lua                  -- market window, listing display, search, Whisper button
├── Libs/
│   ├── LibStub/
│   │   └── LibStub.lua
│   ├── CallbackHandler-1.0/
│   │   └── CallbackHandler-1.0.lua
│   ├── AceAddon-3.0/
│   ├── AceEvent-3.0/
│   ├── AceTimer-3.0/
│   ├── AceDB-3.0/
│   ├── AceConsole-3.0/
    └── AceGUI-3.0/
└── Spec/
    ├── spec.md
    └── tech-stack.md
```

### TOC File (draft)

```toc
## Interface: 20504
## Title: MarketCrafts
## Notes: Server-wide crafting service board for TBC Classic
## Author: dkruenbo
## Version: 0.1.0
## SavedVariables: MarketCraftsDB

## OptionalDeps: Ace3

Libs\LibStub\LibStub.lua
Libs\CallbackHandler-1.0\CallbackHandler-1.0.lua
Libs\AceAddon-3.0\AceAddon-3.0.lua
Libs\AceEvent-3.0\AceEvent-3.0.lua
Libs\AceTimer-3.0\AceTimer-3.0.lua
Libs\AceDB-3.0\AceDB-3.0.lua
Libs\AceConsole-3.0\AceConsole-3.0.lua
Libs\AceGUI-3.0\AceGUI-3.0.lua

MarketCrafts.lua
Channel.lua
Broadcast.lua
Listener.lua
Cache.lua
ChatFilter.lua
UI.lua
```

---

## Testing & Debugging

| Tool / Technique | Purpose |
|---|---|
| `/run SetCVar("taintLog", 1)` | Enable taint logging to catch protected API violations |
| `BugSack` + `!BugGrabber` | Capture Lua errors silently without blocking the UI |
| `/run` macros in-game | Rapid functional testing of individual functions |
| Two WoW accounts on the same realm | End-to-end test of broadcast → receive cycle |
| Private TBC server (optional) | Isolated testing of channel edge cases and fallback logic |
| Manual channel hijack test | Have a second account password-lock `MCMarket`, verify fallback to `MCMarket1` |

---

## Open Decisions

| # | Decision | Options | Notes |
|---|---|---|---|
| 1 | Interface version number | `20504` or `20505` | Verify against live TBC 2.5.5 build on release |
| 2 | Rate limit threshold | Messages per minute cap per sender | Default suggested: 10 msg/min |
| 3 | Keep-alive jitter | Exact random spread on the 25-min timer | Small jitter (±30 s) prevents all users firing simultaneously |
| 4 | Re-validate cycle interval | How often to leave + rejoin from index 0 | Default: 10 minutes; shorter = faster convergence but more channel churn |
