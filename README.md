# Gold Compass

A gold advisor addon for **WoW Forever**. It answers "how do I make gold right now?" instead of only tracking what you earn.

> **Status: alpha.** The code is unit tested outside the game, but it has not been run in a game session yet. Expect rough edges.

## What it does

- **Zone profitability map** (`/gc map`): ranks zones by estimated gold per hour of gathering (herbs, ore, fishing pools), using the nodes GatherMate2 knows and the prices Auctionator has seen. Every figure is labelled as an estimate.
- **Smart item tooltip**: one recommended action (vendor, auction house, disenchant, craft a named recipe, keep for a quest), plus the recipes the item is used in, with where to learn them and the price of the result. Hold Shift to list them all.
- **Bags tab**: what is in your bags, grouped by the best action, with a total.
- **Here tab**: what your current zone is worth for your character.

The addon only reads and displays. It never buys, sells, posts or clicks for you.

## Requirements

WoW Forever client, plus these addons (Forever builds):

- [GatherMate2](https://www.curseforge.com/wow/addons/gathermate2) and [GatherMate2_Data](https://www.curseforge.com/wow/addons/gathermate2_data) (run `/gathermate`, then Import)
- [Auctionator](https://www.curseforge.com/wow/addons/auctionator) (run a scan at the auction house)
- Optional: [Forever Ledger](https://www.curseforge.com/wow/addons/forever-ledger). When loaded, Gold Compass only adds the recipe list to the tooltip.

## Install

Copy the addon files into `Interface/AddOns/GoldCompass` inside your `_forever_` folder, or run `scripts/deploy.sh` (it targets a Windows machine over ssh; edit the host and path first).

## Develop

```sh
luacheck .
busted
```

In-game checks: [docs/IN-GAME-CHECKLIST.md](docs/IN-GAME-CHECKLIST.md). Design and build plan: [PLAN.md](PLAN.md). UI mockup: [docs/mockup.html](docs/mockup.html).

## Licence

MIT, see [LICENSE](LICENSE). Recipe and quest data are vendored from [Forever Ledger](https://github.com/ivellos/forever-ledger) (MIT), see [NOTICE](NOTICE) and [THIRD-PARTY](THIRD-PARTY).
