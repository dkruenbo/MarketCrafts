# MarketCrafts — Addon Source

This directory is the WoW addon package. Copy it directly into `Interface/AddOns/`.

---

## File Overview

| File | Purpose |
|---|---|
| `MarketCrafts.toc` | Addon manifest — load order, interface version, SavedVariables |
| `MarketCrafts.lua` | Core addon, lifecycle hooks, slash commands, M2 listing API |
| `Channel.lua` | M1 channel state machine — joins/maintains `MCMarket[N]` pool |
| `Broadcast.lua` | M3 outbound message queue with keep-alive and back-off |
| `Listener.lua` | M3 inbound parser — feeds `[MCR]` messages into Cache |
| `ChatFilter.lua` | M3 suppresses `[MCR]` messages from all chat frames |
| `Cache.lua` | M5 in-memory peer listing cache — TTL, rate limiting, icons |
| `UI.lua` | M4 AceGUI window — Browse panel, My Listings panel |
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
/mc debug        — toggle debug/verbose mode
/mc sim <N>      — inject N fake sellers (debug mode required)
/mc sim clear    — remove all simulated listings
/mc help         — print all commands
```

---

## Adding a Listing (until recipe picker is implemented)

```
/run MarketCrafts:AddMyListing(itemID, "Profession", "Item Name")
```

Example:
```
/run MarketCrafts:AddMyListing(22861, "Alchemy", "Flask of Supreme Power")
```

---

## Bundled Libraries (`Libs/`)

| Library | Purpose |
|---|---|
| `LibStub` | Library version management |
| `CallbackHandler-1.0` | Event callback glue (AceEvent dependency) |
| `AceAddon-3.0` | Addon lifecycle and module system |
| `AceEvent-3.0` | WoW event registration |
| `AceTimer-3.0` | Reliable timer scheduling |
| `AceDB-3.0` | SavedVariables with character scoping |
| `AceConsole-3.0` | Slash command and print helpers |
| `AceGUI-3.0` | UI widget framework (includes all widget files) |

All libraries are bundled — the addon does not rely on shared libraries from other addons.

---

## Testing Checklist (Phase 0 → M5)

Enable taint logging before each session:
```
/run SetCVar("taintLog", 1)
```
Then `/reload` and check `Interface/Logs/taint.log` after testing.

**Phase 0**: `/mc help` prints command list. Zero errors in BugSack.

**M1**: Channel joined within 15s of login. `/run MarketCrafts.Channel:StartRevalidate()` triggers leave + rejoin.

**M2**: Add a listing, `/mc list`, `/reload` — listing persists.

**M3 (single account)**: `/mc debug` → `/mc sim 5` → open `/mc` window → listings appear in Browse. `/mc sim clear` removes them.

**M3 (two accounts)**: Account A `/mc optin`, add listing. Account B sees it in Browse within ~2s.

**Taint**: Zero entries in taint log after any test session.
