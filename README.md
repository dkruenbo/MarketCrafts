# MarketCrafts

A standalone World of Warcraft addon for **TBC Classic 2.5.5** that turns custom chat channels into a server-wide crafting service board — no guild required.

Players opt in to advertise their crafting services. Other players open the Market window to browse available crafters, filter by item or profession, and open a whisper with one click.

---

## Features

- **Tabbed UI** — three-panel window: My Listings, Browse, and Requests
- **Browse** — real-time listing of crafters on your realm, searchable and sortable by item, profession, or seller
- **My Listings** — advertise up to 5 recipes you are available to craft, with optional crafter notes and cooldown tracking
- **Request Board (WTB)** — buyers can post up to 3 "want to buy" requests; crafters see them and reply with one click
- **Profession Filter** — quick-filter chips by profession (Alchemy, Tailoring, etc.)
- **Favourites** — star your preferred sellers to pin them to the top of Browse
- **Crafter Notes** — attach a short note to each listing (e.g. "Free for guildies", "Have mats for 2 flasks")
- **Cooldown Broadcast** — time-gated recipes (e.g. Primal Mooncloth) show remaining cooldown with client-side decay
- **Cross-Alt Sync** — `/mc importalt` snapshots your current character's listings so other characters broadcast them too
- **Whisper Templates** — customisable whisper text with `{seller}`, `{item}`, `{prof}` tokens
- **Freshness Indicators** — colour-coded age labels (green → yellow → grey) on each listing
- **Item Tooltips** — hover icons for standard WoW item tooltips; shift-click to link in chat
- **Minimap Button** — draggable button showing live crafter count on hover
- **Right-Click Blocklist** — right-click any seller name to hide them
- **Silent protocol** — all `[MCR]` traffic is filtered from chat frames; no spam visible to players
- **Opt-in only** — no data is broadcast unless you explicitly opt in with `/mc optin`
- **Anti-abuse** — rate limiting (10 messages/min/sender), max 5 listings per player, 30-min TTL
- **Automatic channel management** — joins the lowest available `MCMarket[N]` channel with auto-convergence

---

## Repository Layout

```
MarketCrafts/          ← WoW addon (drop this into Interface/AddOns/)
Spec/                  ← Design documents
  spec.md              ← Feature specification (original design)
  tech-stack.md        ← Library and architecture decisions
  implementation-plan.md ← Improvement plan from March 2026 audit
  improvement-plan.md  ← Full bug/feature implementation plan
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
| `/mc optin` | Start broadcasting your listings |
| `/mc optout` | Stop broadcasting |
| `/mc list` | Print your active listings to chat |
| `/mc ignore <Player>` | Block a player's listings |
| `/mc unignore <Player>` | Restore a blocked player |
| `/mc importalt` | Save current char's listings as an alt profile (all chars broadcast them) |
| `/mc request` | Open the Requests tab (WTB board) |
| `/mc template [text]` | View or set whisper template (`{seller}`, `{item}`, `{prof}` tokens) |
| `/mc favorites` | List your starred sellers |
| `/mc debug` | Toggle debug mode |
| `/mc sim <N>` | Inject N fake sellers for testing (debug mode only) |
| `/mc sim clear` | Remove all simulated listings |
| `/mc help` | Print all commands |

## Adding a Listing

Use the **"Add from Profession"** button in the My Listings tab:

1. Open a profession window from your spellbook (or via `/cast Alchemy`).
2. Open the Market window with `/mc`.
3. Click **Add from Profession**, search for a recipe, optionally type a crafter note, and click **Add**.

### Advanced: scripted use

```
/run MarketCrafts:AddMyListing(22861, "Alchemy", "Flask of Supreme Power", "Have mats", nil)
```

---

## Technical Overview

- **Platform**: WoW TBC Classic 2.5.5 (interface `20504`)
- **Libraries**: AceAddon-3.0, AceEvent-3.0, AceTimer-3.0, AceDB-3.0 (character + account scoped), AceConsole-3.0, AceGUI-3.0 — all bundled
- **Wire format**:
  - `[MCR]L:<itemID>,<prof>,<name>[,<note>[,<cdSeconds>]]` — listing (3/4/5 fields)
  - `[MCR]R:<itemID>` — listing remove
  - `[MCR]Q:<itemName>[,<note>]` — buyer request (WTB)
  - `[MCR]QR:<itemName>` — buyer request remove
- **Channel pool**: `MCMarket`, `MCMarket1`–`MCMarket49`; converges to the lowest unlocked channel
- **Cache TTL**: 30 minutes; keep-alive broadcast every 20 minutes
- **Taint-safe**: zero use of protected API calls; safe for use during combat

See [Spec/spec.md](Spec/spec.md) for the original design specification.

---

## Development Status

All milestones and improvement plan items are complete.

| Milestone | Status |
|---|---|
| Phase 0 — Scaffolding | ✅ Complete |
| M1 — Channel State Machine | ✅ Complete |
| M2 — Saved Listings | ✅ Complete |
| M3 — Broadcast / Listener / ChatFilter | ✅ Complete |
| M4 — UI (Browse + My Listings) | ✅ Complete |
| M5 — Cache, TTL, Anti-Abuse | ✅ Complete |
| M6 — Polish (sort, cooldown, back-off, status) | ✅ Complete |
| M6.5 — Recipe Picker dialog | ✅ Complete |
| Bug fixes (H1-H3, M1-M6, L1-L7) | ✅ Complete (PRs #9-#11) |
| Features (F1-F11) | ✅ Complete (PRs #12-#16) |
| Request board bug fixes | ✅ Complete (PR #17) |

---

## License

MIT
