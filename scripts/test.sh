#!/bin/bash
# Install the APK, push test keys from secrets, run connectivity checks.
# Keys never touch git: they arrive via $TEST_API_KEYS only.
set -euo pipefail
APK=$(ls ./apks/*.apk | head -1)
docker exec android adb install -r "/work/$APK"
if [ -n "${TEST_API_KEYS:-}" ]; then
  echo "$TEST_API_KEYS" | docker exec -i android \
    sh -c 'cat > /data/local/tmp/test-keys.env'
  docker exec android adb shell am broadcast \
    -a moe.shizuku.manager.TEST_KEYS --es file /data/local/tmp/test-keys.env
fi
# Screenshot pull works headless:
docker exec android adb exec-out screencap -p > boot-check.png
echo "wrote boot-check.png"
