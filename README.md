# MarketCrafts

A standalone World of Warcraft addon for **TBC Classic 2.5.5** that turns custom chat channels into a server-wide crafting service board — no guild required.

Players opt in to advertise their crafting services. Other players open the Market window to browse available crafters, filter by item or profession, and open a whisper with one click.

---

## Features

- **Browse** — real-time listing of crafters on your realm, searchable and sortable by item, profession, or seller
- **My Listings** — advertise up to 5 recipes you are available to craft
- **Silent protocol** — all `[MCR]` traffic is filtered from chat frames; no spam visible to players
- **Opt-in only** — no data is broadcast unless you explicitly opt in with `/mc optin`
- **Anti-abuse** — rate limiting (10 messages/min/sender), max 5 listings per player, 30-min TTL
- **Blocklist** — `/mc ignore <Player>` to hide a player's listings permanently
- **Automatic channel management** — joins the lowest available `MCMarket[N]` channel, re-validates every 10 minutes

---

## Repository Layout

```
MarketCrafts/          ← WoW addon (drop this into Interface/AddOns/)
Spec/                  ← Design documents
  spec.md              ← Feature specification
  tech-stack.md        ← Library and architecture decisions
  implementation-plan.md ← Full milestone plan with code
```

---

## Installation

1. Clone or download this repository.
2. Copy the `MarketCrafts/` folder into your WoW addon directory:
   ```
   World of Warcraft/_classic_tbc_/Interface/AddOns/MarketCrafts/
   ```
3. Log in and type `/mc help` to verify the addon loaded correctly.

---

## Usage

| Command | Description |
|---|---|
| `/mc` | Open / close the Market window |
| `/mc optin` | Start broadcasting your listings to the channel |
| `/mc optout` | Stop broadcasting |
| `/mc list` | Print your active listings to chat |
| `/mc ignore <Player>` | Hide a player's listings |
| `/mc unignore <Player>` | Restore a player's listings |
| `/mc debug` | Toggle debug mode |
| `/mc sim <N>` | Inject N fake sellers for testing (debug mode only) |
| `/mc sim clear` | Remove all simulated listings |
| `/mc help` | Print all commands |

To add a listing (until the recipe picker UI is complete):
```
/run MarketCrafts:AddMyListing(22861, "Alchemy", "Flask of Supreme Power")
```

---

## Technical Overview

- **Platform**: WoW TBC Classic 2.5.5 (interface `20504`)
- **Libraries**: AceAddon-3.0, AceEvent-3.0, AceTimer-3.0, AceDB-3.0 (character-scoped), AceConsole-3.0, AceGUI-3.0 — all bundled, no external dependencies
- **Wire format**: `[MCR]L:<itemID>,<profession>,<itemName>` (list) and `[MCR]R:<itemID>` (remove)
- **Channel pool**: `MCMarket`, `MCMarket1`–`MCMarket4`; converges to the lowest unlocked channel
- **Cache TTL**: 30 minutes; keep-alive broadcast every 20 minutes
- **Taint-safe**: zero use of protected API calls; safe for use during combat

See [Spec/implementation-plan.md](Spec/implementation-plan.md) for the full design and milestone breakdown.

---

## Development Status

| Milestone | Status |
|---|---|
| Phase 0 — Scaffolding | Complete |
| M1 — Channel State Machine | Complete |
| M2 — Saved Listings | Complete |
| M3 — Broadcast / Listener / ChatFilter | Complete |
| M4 — UI (Browse + My Listings) | Complete |
| M5 — Cache, TTL, Anti-Abuse | Complete |
| M6 — Polish (sort, cooldown, back-off, status) | Complete |
| M6.5 — Recipe Picker dialog | Planned |

---

## License

MIT
