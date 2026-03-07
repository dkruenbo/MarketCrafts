# Changelog

All notable changes to MarketCrafts are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

---

## [1.0.1] — Unreleased

### Added

- **Services tab** — new outer tab structure splits the window into **Crafting** and **Services**.
  - Mages can advertise **Portals** (destinations auto-detected from spellbook) and **Food & Water**.
  - Warlocks can advertise **Ritual of Summoning**.
  - Rogues can advertise **Lockpicking**.
  - Class gate enforced at add-time — only valid services for your class are offered.
  - Portal destination note is pre-filled automatically from known portal spells.
  - Services have no cap (each class has at most the services they can offer anyway).
  - Note/price field reuses the existing free-text note pattern (same as crafting listings).
- **Wire format extensions** — two new message prefixes:
  - `[MCR]SV:<serviceKey>[,<note>]` — service offer broadcast.
  - `[MCR]SVR:<serviceKey>` — service removal broadcast.
  - Both suppressed from chat by the existing `[MCR]` filter — zero chat clutter.
- **Services included in keep-alive** — `SendAllListings` now re-broadcasts active service listings every keep-alive cycle so they stay visible to receivers within the 30-minute TTL.
- **`/mc services`** slash command — opens the window directly on the Services tab.
- **`myServices` SavedVariable** — persisted per character alongside `myListings`.

### Changed

- **UI restructured to two outer tabs** — existing My Listings / Browse / Requests tabs are now nested inside a **Crafting** outer tab. Services get their own outer tab. Active tab is preserved across `Refresh()` calls.
- **Keep-alive jitter** — the 20-minute keep-alive timer now uses a self-rescheduling one-shot with ±2-minute random jitter per cycle (18–22 min). Prevents post-maintenance login spikes from synchronising broadcasts across a large server population.
- **Profession name canonicalisation** — `profName` is normalised to canonical English at `AddMyListing` time via a `PROF_CANON` lookup table covering **enUS/enGB, deDE, frFR, and ruRU** client locales. Fixes profession filter chips showing duplicate entries (e.g. "Alchimie" vs "Alchemy") on EU mixed-locale servers.

### Fixed

- Profession filter chips in Browse would split into locale-specific duplicates on EU servers with mixed-locale clients. Now always grouped under the canonical English name.

---

## [1.0.0] — 2026-03-04

Initial stable release. Full feature set as shipped:

- Server-wide crafting service board via custom `MCMarket` channel (5-fallback pool).
- Passive broadcast model (`[MCR]L:` / `[MCR]R:`): no request/response storms.
- My Listings panel (up to 5 recipes, profession picker, opt-in/out toggle).
- Browse panel — search, sort, profession filter chips, freshness colouring, Whisper button, right-click blocklist.
- Requests tab (F7) — buyer WTB board (`[MCR]Q:` / `[MCR]QR:`), up to 3 requests per buyer.
- Crafter notes (F1), whisper template (F4), cross-alt listing sync (F5), cooldown broadcast (F6).
- Item tooltips + shift-click links (F8), freshness age colouring (F9), seller favourites (F10), right-click hide (F11).
- Draggable minimap button with live crafter count (M6).
- Channel resilience: fallback chain, per-step timeout, re-walk on kick, channel-limit retry.
- `[MCR]` chat filter — all wire messages invisible in chat frames.
- `/mc sim N` mock data framework for testing without a second account.
