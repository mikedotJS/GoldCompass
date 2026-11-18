#!/usr/bin/env bash
# Copies the addon (TOC files, Lua files, Data/, LICENSE, NOTICE, THIRD-PARTY) to the owner's Windows PC over ssh/scp, then lists the remote folder.
# Only touches the GoldCompass folder; nothing is deleted, files are overwritten.
set -euo pipefail

REMOTE_DIR='E:/Programmes/World of Warcraft/_forever_/Interface/AddOns/GoldCompass'
cd "$(dirname "$0")/.."

ssh -o BatchMode=yes -o ConnectTimeout=15 pc "New-Item -ItemType Directory -Force -Path '$REMOTE_DIR' | Out-Null"
scp -o BatchMode=yes -o ConnectTimeout=15 -r ./*.toc ./*.lua LICENSE NOTICE THIRD-PARTY Data "pc:$REMOTE_DIR/"
echo "--- remote folder:"
ssh -o BatchMode=yes pc "Get-ChildItem -Recurse -File '$REMOTE_DIR' | ForEach-Object { '{0}  {1} bytes' -f \$_.FullName.Substring(\$_.FullName.IndexOf('GoldCompass')), \$_.Length }"
