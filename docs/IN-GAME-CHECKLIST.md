# GoldCompass in-game checklist (about 5 minutes)

Nothing here has been run in the game yet. Each line says what to type, what should happen, and what to send back.
Send back: the exact chat text (copy it) or a screenshot, plus any Lua error popup.

## Before you start

Install in `E:\Programmes\World of Warcraft\_forever_\Interface\AddOns` (CurseForge app, game version WoW Forever):

| Addon | From |
|---|---|
| GatherMate2 (1.52.7 or later) | https://www.curseforge.com/wow/addons/gathermate2 |
| GatherMate2_Data (v42.0 or later) | https://www.curseforge.com/wow/addons/gathermate2_data |
| Auctionator (12.1.5 or later) | https://www.curseforge.com/wow/addons/auctionator |

GoldCompass is already copied there by `scripts/deploy.sh`. Log in with a low-level character and tick GoldCompass in the AddOns list.
Do the lines in order; lines 3 to 5 need the three addons installed but NOT yet configured.

| # | Type | Expected | Send back |
|---|---|---|---|
| 1 | (log in) | Chat shows `Gold Compass : chargé. Tape /gc.` (spike S1) | Yes / no. If no: screenshot of the AddOns list and any error |
| 2 | `/gc spike` | Lines tagged `[spike]` for S1 to S4. `TOC used` says `forever-suffix` or `plain`. `Durotar (1411)` shows `0 herb spots, 0 ore spots` before the import. Every `Auctionator.API.v1.*` says `present` or `MISSING` | ALL `[spike]` lines |
| 3 | `/gc map` | `Aucune donnée de ressources` message (empty state, no GatherMate data) | The text |
| 4 | `/gathermate`, then Import (GatherMate2_Data), then `/gc spike` | `Durotar (1411)` now shows herb and ore counts above 0 (spike S2) | The two S2 lines |
| 5 | `/gc map` | `Pas encore de prix` message (data but no auction scan) | The text |
| 6 | Open the auction house, run an Auctionator scan, then `/gc spike` | S3 lines show a price and an age for Copper Ore (2770) and Peacebloom (2447), no `ERROR` | The S3 lines |
| 7 | `/gc map` | Title line, then up to 10 lines `N. Zone  ~Xg/h (estimation)  items  [prix N j]`, then the grey footer. The title says `Si tu apprends...` if the character has no gathering profession, otherwise `Classement pour tes métiers de récolte` | The full output |
| 8 | `/gc dump`, then `/reload` | Message says the result is saved | The file `WTF\Account\<ACCOUNT>\SavedVariables\GoldCompass.lua` |
| 9 | `/gc` | Window `Gold Compass · Carte de rentabilité` opens: brief "Lecture des données en cours" panel, then the same ranking as line 7, a footer, buttons `Voir sur la carte` and `Actualiser`, a `Carte` tab under the frame | Screenshot |
| 10 | Click a zone row, then press Escape | The world map opens on that zone (GatherMate pins visible); Escape closes the window | Yes / no |
| 11 | Click `Actualiser` | The button greys out while loading, then the list returns | Yes / no |
| 12 | Drag the window, `/reload`, `/gc` | The window reopens where you left it | Yes / no |
| 13 | Disable Auctionator in the AddOns list, `/reload`, `/gc map` | `Auctionator n'est pas installé` message. Repeat with GatherMate2 disabled instead: `GatherMate2 n'est pas installé` | The two texts |

Spike S4 (zone and level) is the `S4` lines of line 2: the map ID should match the zone you stand in, and each profession line shows its `skillLine` (GoldCompass expects 182 for Herbalism and 186 for Mining; if yours differ, say so, the ranking will think you have no profession).
Spike S6 (is 60 nodes per hour realistic) is separate: gather for 15 minutes in one zone and count; send the count.
