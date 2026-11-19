#!/usr/bin/env bash
# Gold Compass daily data update. Checks the upstream data sources, rebuilds what changed, runs the gates, then commits, deploys to the PC and pushes.
#
#   scripts/update-data.sh              scheduled mode (what launchd runs): retries a pending deploy/push, checks the sources about once a day
#   scripts/update-data.sh --force      rebuild everything, whatever changed
#   scripts/update-data.sh --dry-run    detect changes + build + gates in a temporary copy; no commit, deploy, push or state change
#   scripts/update-data.sh --status     last run, source versions, pending deploy
#   scripts/update-data.sh --check-now  check the sources now, even if they were checked less than a day ago
#   scripts/update-data.sh --install-agent | --uninstall-agent    (un)load the launchd job (daily 09:30 + hourly pending-deploy retry)
# Log: ~/Library/Logs/GoldCompass/data-update.log   State: ~/.cache/goldcompass/state.json
set -euo pipefail
export PATH="$HOME/.luarocks54/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=dev.goldcompass.data-update
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

case "${1:-}" in
  --install-agent)
    mkdir -p "$HOME/Library/Logs/GoldCompass" "$HOME/Library/LaunchAgents"
    sed -e "s#__REPO__#$(dirname "$HERE")#g" -e "s#__HOME__#$HOME#g" "$HERE/launchd/$LABEL.plist" > "$PLIST"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl print "gui/$(id -u)/$LABEL" | head -12 ;;
  --uninstall-agent)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST" ;;
  -h|--help)
    sed -n '2,10p' "$0" ;;
  *)
    exec python3 "$HERE/update_data.py" "$@" ;;
esac
