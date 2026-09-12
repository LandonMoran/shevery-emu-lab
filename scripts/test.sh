#!/bin/bash
# Minimal emulator session: boot (done by the action) + serve adb over Tailscale.
# No tests, no APK, no probes. Just make the device reachable and park it.
# From outside: adb -H <runner-tailscale-ip> shell   (server listens on 0.0.0.0:5037)

# Wake the screen so the device is a live, interactive target.
adb shell input keyevent 82 >/dev/null 2>&1 || true

# Restart the adb server bound to all interfaces so it's reachable via the
# runner's Tailscale IP (default 5037, proxy-style: emulator-5554 is listed).
REMOTE_ADB_PORT="${PORT:-5037}"
adb kill-server 2>/dev/null || true
adb -a nodaemon server start >/tmp/adb.log 2>&1 &
sleep 3
adb devices

HOLD="${2:-90}"
TSIP=$(tailscale ip -4 | head -1 || echo UNKNOWN)
echo "HOLD open for ${HOLD}m"
echo "Tailscale magic: adb -H $TSIP shell"
sleep "${HOLD}m"