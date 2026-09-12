#!/bin/bash
# Install the APK, push test providers from secrets, run connectivity checks.
# Keys never touch git: they arrive via $TEST_PROVIDERS only.
# Format (one per line): Name|https://base.url/v1|model-id|api-key
set -euo pipefail
APK=$(ls ./apks/*.apk | head -1)
docker exec android adb install -r "/work/$APK"
if [ -n "${TEST_PROVIDERS:-}" ]; then
  echo "$TEST_PROVIDERS" | docker exec -i android \
    sh -c 'cat > /data/local/tmp/test-providers.txt'
  docker exec android adb shell am broadcast \
    -a moe.shizuku.manager.TEST_KEYS --es file /data/local/tmp/test-providers.txt
  sleep 5
  docker exec android logcat -d 2>/dev/null | grep "TestKeys" | tail -5
fi
# Screenshot pull works headless:
docker exec android adb exec-out screencap -p > boot-check.png
echo "wrote boot-check.png"
