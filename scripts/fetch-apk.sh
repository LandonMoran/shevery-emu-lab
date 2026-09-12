#!/bin/bash
# Fetch a Shevery APK.
# Usage: fetch-apk.sh <latest|tag <tag>|run <run-id>>
#   latest  - newest .apk attached to a LandonMoran/shevery release
#   tag     - .apk from a specific release tag
#   run     - shevery-debug artifact from a Build Android APK run
#             (HmnDev-Tech/shevery). Use for PR branches carrying the
#             debug-only TEST_KEYS receiver.
set -euo pipefail
MODE="${1:-latest}"
mkdir -p ./apks
case "$MODE" in
  run)
    gh run download "$2" --repo HmnDev-Tech/shevery -n shevery-debug --dir ./apks
    ;;
  tag)
    gh release download "$2" --repo LandonMoran/shevery --pattern '*.apk' --dir ./apks
    ;;
  latest)
    gh release download --repo LandonMoran/shevery --pattern '*.apk' --dir ./apks
    ;;
  *)
    echo "unknown mode: $MODE (want latest|tag|run)" >&2
    exit 1
    ;;
esac
ls -la ./apks
