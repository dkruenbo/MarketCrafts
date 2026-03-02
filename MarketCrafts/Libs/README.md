# MarketCrafts — Libs

This directory holds third-party Ace3 libraries bundled with the addon.

## Required Libraries

Each library must be downloaded from the [Ace3 repository](https://www.wowace.com/projects/ace3)
or extracted from an Ace3 release package, then placed in the matching sub-folder.

| Folder                   | Library File                     |
|--------------------------|----------------------------------|
| `LibStub/`               | `LibStub.lua`                    |
| `CallbackHandler-1.0/`   | `CallbackHandler-1.0.lua`        |
| `AceAddon-3.0/`          | `AceAddon-3.0.lua`               |
| `AceEvent-3.0/`          | `AceEvent-3.0.lua`               |
| `AceTimer-3.0/`          | `AceTimer-3.0.lua`               |
| `AceDB-3.0/`             | `AceDB-3.0.lua`                  |
| `AceConsole-3.0/`        | `AceConsole-3.0.lua`             |
| `AceGUI-3.0/`            | `AceGUI-3.0.lua` + `widgets/`   |

## Quick Setup

```bash
# From the MarketCrafts addon directory:
# Option 1 — Clone Ace3 and copy what you need
git clone https://repos.wowace.com/wow/ace3/mainline.git /tmp/ace3
for lib in LibStub CallbackHandler-1.0 AceAddon-3.0 AceEvent-3.0 AceTimer-3.0 AceDB-3.0 AceConsole-3.0 AceGUI-3.0; do
  cp -r "/tmp/ace3/$lib" "Libs/$lib"
done
```

Each `.lua` file referenced in `MarketCrafts.toc` must exist at the
exact relative path shown above for the addon to load.
