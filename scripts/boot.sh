#!/bin/bash
# Boot a Play Store (unrooted) emulator with web view + ADB.
set -euo pipefail
docker run -d --device /dev/kvm \
  -p 6080:6080 -p 5555:5555 \
  -e EMULATOR_DEVICE="Pixel 6" -e WEB_VNC=true \
  --name android budtmo/docker-android:emulator_11.0
for i in $(seq 1 60); do
  docker exec android adb devices 2>/dev/null | grep -q "device$" && break
  sleep 10
done
docker exec android adb devices
