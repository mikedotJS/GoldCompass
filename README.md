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

## Data updates

`scripts/update-data.sh` keeps the generated `Data/` files fresh, once a day, on the maintainer's Mac (launchd job `dev.goldcompass.data-update`, 09:30 daily, plus an hourly wake-up that only retries a pending deploy). It checks the ForeverDB data version, the wowforever.be pages, the latest LibProfessionDB release and the latest Forever Ledger and pfQuest commits, and does nothing when none changed. Otherwise it rebuilds only the affected generators (and what depends on them) in a temporary copy, and only if luacheck, busted, the audit score, a personal-data scan and a load test all pass does it commit, copy the addon to the gaming PC (`scripts/deploy.sh`) and push. A failure leaves the repo untouched and sends a notification. Requests are rate-limited (1 to 2 s) with a generic User-Agent; robots.txt allows the pages used.

```sh
scripts/update-data.sh --status         # last run, source versions, pending deploy
scripts/update-data.sh --dry-run        # detect + build + gates in a temporary copy, nothing committed
scripts/update-data.sh --force          # rebuild everything
scripts/update-data.sh --install-agent  # (re)load the launchd job from scripts/launchd/
```

Log: `~/Library/Logs/GoldCompass/data-update.log` (about 1 MB cap). State and downloaded inputs: `~/.cache/goldcompass/`. ProfessionsTracker has no machine-readable release: its pinned copy must sit in `~/.cache/goldcompass/inputs/ProfessionTracker-1.2.0/`.

## Licence

GPL-3.0, see [LICENSE](LICENSE) (the addon includes ForeverDB.net data, which is GPL-3.0; credit: "Data from ForeverDB.net"). Recipe and quest data are also vendored from [Forever Ledger](https://github.com/ivellos/forever-ledger) (MIT), see [NOTICE](NOTICE) and [THIRD-PARTY](THIRD-PARTY).
