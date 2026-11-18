#!/usr/bin/env bash
# Prints GoldCompass's diagnostic log and the tail of the game's taint.log, read over ssh. Read-only: nothing is
# modified on the PC. The SavedVariables file is only written by the game on /reload or logout.
set -euo pipefail

WOW='E:\Programmes\World of Warcraft\_forever_'
LUA="$(command -v lua || command -v lua5.4 || echo /opt/homebrew/bin/lua)"
PS_UTF8='[Console]::OutputEncoding = [Text.Encoding]::UTF8;'

echo "=== (a) GoldCompassDB.log from SavedVariables ==="
files="$(ssh -o BatchMode=yes -o ConnectTimeout=15 pc "$PS_UTF8 (Get-ChildItem -Path '$WOW\\WTF\\Account\\*\\SavedVariables\\GoldCompass.lua' -ErrorAction SilentlyContinue).FullName" | tr -d '\r')"
if [ -z "$files" ]; then
  echo "(no GoldCompass.lua found: log in, then type /reload so the game writes it)"
else
  while IFS= read -r f; do
    echo "--- $f"
    ssh -o BatchMode=yes pc "$PS_UTF8 Get-Content -Raw -Encoding UTF8 -LiteralPath '$f'" | tr -d '\r' | "$LUA" -e '
      local src = io.read("a")
      local env = {}
      local chunk, err = load(src, "GoldCompass.lua", "t", env)
      if not chunk then print("(cannot parse: " .. tostring(err) .. ")") os.exit(1) end
      chunk()
      local log = env.GoldCompassDB and env.GoldCompassDB.log or {}
      print(#log .. " entries")
      for _, e in ipairs(log) do print(e.time .. " [" .. e.kind .. "] " .. e.text) end'
  done <<< "$files"
fi

echo
echo "=== (b) last 40 lines of taint.log (only exists after: /console taintLog 2) ==="
ssh -o BatchMode=yes -o ConnectTimeout=15 pc "$PS_UTF8 \$p = '$WOW\\Logs\\taint.log'; if (Test-Path -LiteralPath \$p) { Get-Content -Tail 40 -Encoding UTF8 -LiteralPath \$p } else { '(no taint.log: type /console taintLog 2, reproduce, then /reload)' }" | tr -d '\r'
