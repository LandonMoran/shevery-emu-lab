#!/bin/bash
# Install the APK, push test providers from secrets, run connectivity checks.
# Runs INSIDE android-emulator-runner: local adb, emulator already booted.
# Keys never touch git: they arrive via $TEST_PROVIDERS only.
# Format (one per line): Name|https://base.url/v1|model-id|key
set -euo pipefail
REF="${1:-latest}"
MODE="latest"; ARG=""
case "$REF" in
  run\ *) MODE="run"; ARG="${REF#run }" ;;
  tag\ *) MODE="tag"; ARG="${REF#tag }" ;;
esac
scripts/fetch-apk.sh "$MODE" $ARG
APK=$(ls ./apks/*.apk | head -1)
adb install -r "$APK"
adb shell input keyevent 82 || true
if [ -n "${TEST_PROVIDERS:-}" ]; then
  printf '%s\n' "$TEST_PROVIDERS" > /tmp/providers.txt
  adb push /tmp/providers.txt /data/local/tmp/providers.txt
  shred -u /tmp/providers.txt
  adb shell am broadcast -a moe.shizuku.manager.TEST_KEYS \
    --es file /data/local/tmp/providers.txt
  sleep 3
fi
PASS=0; FAIL=0
while IFS='|' read -r name base model key; do
  [ -z "${name:-}" ] && continue
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -H "Authorization: Bearer $key" "$base/models")
  if [ "$code" = "200" ]; then echo "PASS $name"; PASS=$((PASS+1));
  else echo "FAIL $name (http $code)"; FAIL=$((FAIL+1)); fi
done < <(printf '%s\n' "${TEST_PROVIDERS:-}")
echo "RESULT pass=$PASS fail=$FAIL"
HOLD="${2:-0}"
if [ "$HOLD" != "0" ]; then
  adb kill-server 2>/dev/null || true
  adb -a nodaemon server start >/tmp/adb.log 2>&1 &
  sleep 3
  adb devices
  echo "HOLD open for ${HOLD}m — connect with: adb connect $(tailscale ip -4 | head -1)"
  sleep "${HOLD}m"
fi
