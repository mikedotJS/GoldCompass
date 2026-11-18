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

GoldCompass (with LICENSE, NOTICE and THIRD-PARTY) is already copied there by `scripts/deploy.sh`. Log in with a low-level character and tick GoldCompass in the AddOns list.
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

### Tooltip, Bags tab, Here tab, map controls (steps 4 to 6)

Use a character with at least one profession (ideally one recipe known), a few items in the bags, and the auction scan done (line 6).

| # | Type | Expected | Send back |
|---|---|---|---|
| 14 | `/gc spike`, read the `S5` lines | `TooltipDataProcessor`, `C_Container`, `IsPlayerSpell` true; `IsPlayerSpell(2329)` is true only if you know that Alchemy recipe | The S5 lines |
| 15 | Hover a herb or ore in the bags | Under the normal tooltip: a teal `GOLD COMPASS` header, ONE action line (green, with a price on the right) and a grey reason; then `Sert à N usages` with at most 3 recipes (`✓ connue` green, `à apprendre : ...` gold, grey for missing profession), then `~ estimation · prix HV vus il y a ...` | Screenshot |
| 16 | Hold Shift while hovering | The full recipe list appears without moving the mouse | Screenshot |
| 17 | Hover a grey item, then an item with no AH price and no vendor value | Grey item: vendor action. No price at all: the line `Aucune valeur connue` and under it `aucun prix : scanne l'hôtel des ventes`. A price of 0 is never shown as `<1s`: it reads `prix inconnu` | What you saw |
| 18 | Hover an item during combat | No Gold Compass lines, no error | Yes / no |
| 19 | Enable Forever Ledger, hover a herb | No second verdict line from Gold Compass, only the recipes list | Screenshot |
| 20 | `/gc`, click the `Sac` tab | Loading panel, then groups (Vendre à l'HV, Fabriquer / désenchanter, Garder, Vendre au marchand) with totals, and `Ton sac vaut environ ...` at the bottom | Screenshot |
| 21 | Loot or sell an item with the Sac tab open | The list updates by itself | Yes / no |
| 22 | Empty your bags except the Hearthstone (or use a fresh character) | `Ton sac est vide` panel (the Hearthstone is ignored) | Yes / no |
| 23 | Click the `Ici` tab, walk into another zone | Zone name, `~X/h pour toi`, a comparison line, `À récolter ici`, quest pick-ups when the zone has quests, a profession hint if you lack Herbalism or Mining. It refreshes when the zone changes. In a city: `Pas de données pour cette zone` | Screenshot of two zones |
| 24 | On the `Carte` tab, tick `Mon niveau seulement` | High-level zones disappear instantly (no reload) | Yes / no |
| 25 | Click the `Métier : ...` button four times | It cycles Tous, Herboristerie, Minage, Pêche, back to Tous; the list is recomputed each time | Yes / no |
| 26 | Select `Métier : Pêche` on a character that has never had GatherMate record a fishing pool | Panel `Aucun banc enregistré` / `Aucun banc enregistré ici : pêche des bancs en jouant, GatherMate les mémorise.` with `Réessayer` (not an error) | The text |
| 27 | Fish a few pools (Oily Blackmouth, Firefin Snapper, Sagefish, Deviate Fish, Stonescale Eel) so GatherMate records them, then select `Pêche` again | Only the zones with recorded pools are ranked, figures show `~...(estimation)`, the banner `Pêche : seules les zones où GatherMate a enregistré des bancs sont classées.` is shown. Expect small figures: the pace is cut when fewer than 100 spots are known | Screenshot, and which pool gave which item |
| 28 | Open the profession window of a profession you know (Alchemy for example), close it, then hover an ingredient | The recipes you know show `✓ connue` even if `/gc spike` said `IsPlayerSpell` is false | Yes / no |
| 29 | Visit a vendor selling a reagent (vial, flux, thread), then hover a herb used in a recipe needing it | The craft can now be recommended (before the visit the tooltip says a craft `pourrait rapporter plus (estimation haute ...)`) | What you saw |
| 30 | Hover a soulbound green item in the bags, with and without the Bags tab open | Never `Vendre à l'HV`; the tooltip and the Bags tab agree | Yes / no |
| 31 | Tick `Mon niveau seulement` | Zones with an unknown level (the four Forever-only zones) disappear and the banner says `N zone(s) de niveau inconnu masquée(s)`. Send the real name and level range of map IDs 2482, 2521, 2548, 2652 if you can read them | The names |
| 32 | In combat, click a zone row; also hover an item and press Shift | The map does not open and chat says `Impossible d'ouvrir la carte en combat.`; the tooltip does not redraw | Yes / no |

Spike S4 (zone and level) is the `S4` lines of line 2: the map ID should match the zone you stand in, and each profession line shows its `skillLine` (GoldCompass expects 182 for Herbalism and 186 for Mining; if yours differ, say so, the ranking will think you have no profession).
Spike S6 (is 60 nodes per hour realistic) is separate: gather for 15 minutes in one zone and count; send the count.

## Send me the logs (no screenshots needed)

1. Reproduce the problem (for the Auctionator popup, optionally first type `/console taintLog 2` so the game also writes `Logs\taint.log`).
2. Type `/reload` (the game only writes the log to disk on reload or logout).
3. Tell Claude "logs". Claude runs `scripts/fetch-logs.sh`, which reads over ssh, without changing anything: the GoldCompass log (chat output, Lua errors, blocked-action events with addon and function, a login header) and the last 40 lines of `taint.log`.
4. In game, `/gc log` shows the last 20 entries and `/gc log clear` empties the log.

## Map window layout and filters (after the first photos)

| # | Type | Expected | Send back |
|---|---|---|---|
| 33 | `/gc` on the Carte tab | The window is about 460 px wide, on the right side of the screen, clear of the unit frames, the action bars and the minimap. Tabs hang below the frame without touching it | Screenshot |
| 34 | Look at the rows | Zone name on one line (cut with `...` if long), a dim second line with nodes and level, the figure `~Xs/h (estimation)` on the right with `prix d'aujourd'hui` or `prix de N j` under it, nothing wrapping onto the next row | Screenshot |
| 35 | Move the mouse over the rows | The row text stays readable (soft gold highlight behind the text). A tooltip appears to the LEFT of the window: full zone name, nodes with value per point, price age, the assumptions | Screenshot |
| 36 | `Métier : Tous` on a character with Fishing but no Mining or Herbalism | A ranking, not `Aucune donnée de ressources`; subtitle `Si tu apprends Minage / Herboristerie (niveau de métier supposé : N)` | Screenshot |
| 37 | Tick and untick `Mon niveau seulement` | A green box with a check mark when on, an empty dark box when off | Yes / no |
| 38 | Wait for loading, then hover `Voir sur la carte` while it is grey | The line next to it says why (`Indisponible pendant la lecture...`, `Indisponible en combat.`); when ready it says `Les points restent affichés par GatherMate.` | What you saw |
| 39 | Click a zone row (out of combat) | The world map opens on that zone through `C_Map.OpenWorldMap`; if the Blizzard "action bloquée" popup appears, `/reload` and tell Claude "logs" | The popup text, then the logs |

## "Monter un métier" tab (profession leveling advisor)

| # | Type | Expected | Send back |
|---|---|---|---|
| 40 | `/gc spike`, read the `S6` lines | `GetRecipeSchematic`, `GetRecipeInfo`, `GetBaseProfessionInfo` and `Enum.TradeskillRelativeDifficulty` all true; the enum reads `Optimal=0 Medium=1 Easy=2 Trivial=3` (if not, the colours are mislabelled: say so) | The S6 lines |
| 41 | `/gc`, click the `Métier` tab BEFORE opening any profession window | Each profession of the character is listed with its skill, and `Ouvre la fenêtre de <métier> une fois pour que Gold Compass la lise.` Fishing, Herbalism and Skinning say `Pas de recettes à fabriquer pour ce métier.` | Screenshot |
| 42 | Open a profession window (for example Alchimie), close it, click `Actualiser` on the `Métier` tab | The profession now shows `Monte avec <recette en français> : coût ~<pièces> par point` (or `gain ~...` when crafting earns money), a dim line `couleur orange · chance d'un point ~100 % (estimation)`, and, under it, the recipes to learn (rows 54 to 60) | Screenshot |
| 43 | Same tab, after `/reload` | The data is still there without reopening the window (remembered per character) | Yes / no |
| 44 | Compare the proposed recipe with the colours in the profession window | The colour named on the dim line matches the recipe's colour in the window | Yes / no, and the recipe name |
| 45 | A profession where a reagent has no auction price and no vendor price | A yellow line `Prix manquant : <objets>` instead of a made-up number | Screenshot |
| 46 | `/gc log` after opening a profession window | No new error entries | The lines |

## "Avec mon sac" filter (Métier tab)

| # | Type | Expected | Send back |
|---|---|---|---|
| 47 | `/gc`, `Métier` tab, tick `Avec mon sac` (same green check box as `Mon niveau seulement`) | Only recipes you can craft right now remain; the best one reads `Monte avec <recette> (avec ton sac, ×N) : ...` where N is the number of crafts your bags allow | Screenshot |
| 48 | Compare N with your bags | N = the scarcest reagent (owned / needed, rounded down). Bank and reagent bank are NOT counted | Yes / no |
| 49 | Put a reagent in the bank, or sell it, with the tab open | The list updates within about a second (no flicker, no storm); nothing redraws during combat | What you saw |
| 50 | Empty your bags of reagents | `Rien à fabriquer avec ton sac pour ce métier.` and a `Voir sans filtre` button that unticks the filter; a dim line `Presque : <recette>, il manque N × <objet>` | Screenshot |
| 51 | `/reload`, then reopen `/gc` | The checkbox is still ticked for this character; another character has its own setting | Yes / no |
| 52 | Footer with the filter on | Mentions `Composants du sac valorisés au prix du marché` (owned reagents are still priced at market value) | Yes / no |
| 53 | Tick the filter on a profession not read yet | Still `Ouvre la fenêtre de <métier> une fois` | Screenshot |

## Recipes to learn (Métier tab)

Sources (`entraîneur`, `vendeur`, `butin de monstre`, `butin`, `quête`) come from Classic data, not confirmed on Forever.

| # | Type | Expected | Send back |
|---|---|---|---|
| 54 | `/gc spike`, read the `S7` lines | One line per remembered profession: `N now, M soon, K priced and ranked, J without a reagent price` | The S7 lines |
| 55 | `Métier` tab on a profession already read | Under the known recipes: `À apprendre maintenant` with `Meilleure à apprendre : <recette>`, a dim line with source, skill needed, colour and chance `(estimation)`, then other rows `<recette> · <source>, niv. N   ~<prix>/pt` | Screenshot |
| 56 | Compare the list with the profession window and the trainer | No recipe you already know appears; a trainer recipe you cannot buy yet (rank) says `rang supérieur possible`; sources match the trainer/vendor you find | Yes / no, and any wrong source |
| 57 | Look for the line `Apprendre <recette> ferait baisser ton coût par point de ~<prix>` | Shown only when the best recipe to learn is cheaper per point than your best known one | Yes / no |
| 58 | `Bientôt (dans les 25 prochains points)` | At most 3 recipes whose learn skill is within 25 points above yours | Screenshot |
| 59 | Tick `Avec mon sac` | Only recipes to learn whose reagents you carry; with none, `Rien à apprendre qui soit fabricable avec ton sac.` and the `Voir sans filtre` button | Screenshot |
| 60 | Footer, and a profession with nothing left to learn | Footer says `données Classic, non confirmées sur Forever` and `Coût d'apprentissage non inclus`; the empty profession says `Aucune recette à apprendre pour ce métier.`; Fishing, Herbalism, Skinning keep `Pas de recettes` | Screenshot |
| 61 | A lot of professions or rows | The list is cut with `... et N autres` (never overflows the frame, never overlaps the footer) | Screenshot |
