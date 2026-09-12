#!/bin/bash
# Fetch a Shevery APK from the main repo's releases.
# Usage: fetch-apk.sh <tag|latest>
set -euo pipefail
REF="${1:-latest}"
if [ "$REF" = "latest" ]; then
  gh release download --repo LandonMoran/shevery --pattern '*.apk' --dir ./apks
else
  gh release download "$REF" --repo LandonMoran/shevery --pattern '*.apk' --dir ./apks
fi
ls -la ./apks
