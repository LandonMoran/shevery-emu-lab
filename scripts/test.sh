#!/bin/bash
# Install the APK, then emulate PR #203 wireless-ADB-over-TCP behavior as
# closely as an emulator allows. Runs INSIDE android-emulator-runner.
# PR #203 is ADB-network hardening only: no AI/provider machinery here.
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

# ============================================================
# NETWORK-EMULATION PHASE (PR #203: TCP-mode ADB lifecycle)
# Emulator limits: NO mDNS, no wireless-debugging pairing UI
# (fake wifi loops pairing on itself), no Android 16/17 random
# ports. What we CAN test with real semantics:
#   - adbd TCP LISTEN state via /proc/net/tcp (isAdbPortLive)
#   - tcpip 5555 toggle + property persistence
#   - host->guest TCP through the emulator virtual NIC (redir)
#   - stop/start adbd teardown + recovery (watchdog path)
#   - mDNS boundary (expected empty on emulator)
# ============================================================
echo "=== NET-EMU DEVICE INFO ==="
adb shell getprop ro.build.version.release
adb shell getprop ro.product.model
adb shell ip -f inet addr show 2>/dev/null | grep -E "inet |^[0-9]+:" | head -8 || true
adb root >/dev/null 2>&1 || true
sleep 2
adb wait-for-device

# On-device port-liveness probe: mirrors EnvironmentUtils.isAdbPortLive
# (checks adbd actually LISTENING, not just a config value).
# /proc/net/tcp: <ip>:<port-hex> state; $4 is state, 0A = LISTEN.
# 5555 = 0x15B3 (port rendered big-endian in the file).
probe5555() {
  # Listening adbd socket line: <ip>:15B3 00000000:0000 0A ...
  # adbd binds :: so the line lives in tcp6; probe both tables.
  adb shell "grep -q ':15B3 ' /proc/net/tcp /proc/net/tcp6 2>/dev/null" \
    >/dev/null 2>&1 && echo OPEN || echo CLOSED
}

echo "=== NET-EMU PHASE 1: pre-state ==="
PRE=$(probe5555)
echo "NET-INFO pre-tcpip listener state on 5555: $PRE"

echo "=== NET-EMU PHASE 2: tcpip 5555 (the toggle PR #203 manages) ==="
adb tcpip 5555 >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6; do sleep 2; [ "$(probe5555)" = "OPEN" ] && break; done
A1=$(probe5555)
[ "$A1" = "OPEN" ] && echo "NET-PASS tcpip: adbd LISTENING on 5555" \
                 || echo "NET-FAIL tcpip: 5555 not listening after tcpip"
adb shell "getprop service.adb.tcp.port" | tr -d '\r' | grep -qs "5555" \
  && echo "NET-PASS tcpip: service.adb.tcp.port=5555 persisted" \
  || echo "NET-FAIL tcpip: service.adb.tcp.port not set"

echo "=== NET-EMU PHASE 3: host->guest TCP through virtual NIC ==="
# redir = qemu slirp: host 127.0.0.1:15555 -> guest NIC -> adbd:5555.
# Adb-over-TCP through the emulator's NAT, the analog of a PC
# connecting to a device's Wi-Fi IP.
adb emu redir add tcp:15555:5555 >/dev/null 2>&1
sleep 2
adb connect 127.0.0.1:15555 >/dev/null 2>&1 || true
sleep 2
DEVICE_TCP=$(adb devices | grep -c "15555" || true)
[ "$DEVICE_TCP" -ge 1 ] && echo "NET-PASS tcp-connect: 127.0.0.1:15555 in adb devices" \
                        || echo "NET-FAIL tcp-connect: no TCP device after redir"
RT="FAIL"
for i in 1 2 3 4 5; do
  adb -s 127.0.0.1:15555 shell echo TCPROUNDTRIP_OK 2>/dev/null | grep -qs "TCPROUNDTRIP_OK" && { RT="PASS"; break; }
  sleep 2
done
[ "$RT" = "PASS" ] \
  && echo "NET-PASS tcp-connect: shell round-trip over host->guest TCP" \
  || echo "NET-FAIL tcp-connect: shell round-trip failed"
adb disconnect 127.0.0.1:15555 >/dev/null 2>&1 || true
adb emu redir del tcp:15555:5555 >/dev/null 2>&1 || true

echo "=== NET-EMU PHASE 4: adbd teardown and recovery (watchdog path) ==="
adb shell "su 0 stop adbd" >/dev/null 2>&1 || true
sleep 2
B1=$(probe5555)
[ "$B1" = "CLOSED" ] && echo "NET-PASS teardown: listener gone after stop adbd" \
                     || echo "NET-WARN teardown: 5555 still open after stop (state=$B1)"
adb shell "su 0 start adbd" >/dev/null 2>&1 || true
for i in 1 2 3 4 5 6; do sleep 2; [ "$(probe5555)" = "OPEN" ] && break; done
B2=$(probe5555)
[ "$B2" = "OPEN" ] && echo "NET-PASS recovery: listener back after start adbd" \
                   || echo "NET-FAIL recovery: 5555 not listening after restart"
[ "$(adb shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')" = "5555" ] \
  && echo "NET-PASS recovery: adbd returned to TCP mode (property survived)" \
  || echo "NET-WARN recovery: adbd restarted NOT in TCP mode"

echo "=== NET-EMU PHASE 5: USB restore ==="
adb usb >/dev/null 2>&1 || true
for i in 1 2 3 4 5; do sleep 2; [ "$(probe5555)" = "CLOSED" ] && break; done
C1=$(probe5555)
[ "$C1" = "CLOSED" ] && echo "NET-PASS usb-restore: 5555 listener closed after adb usb" \
                     || echo "NET-WARN usb-restore: 5555 still open (state=$C1)"

echo "=== NET-EMU PHASE 6: mDNS (expected to fail on emulator) ==="
# Real Android 16/17 wireless debugging uses a RANDOM port found only via
# mDNS/Nsd. Emulators fake wifi and loop pairing on itself, so this is
# documented-untestable here. Attempt it to capture the boundary honestly.
timeout 8 adb mdns services >/tmp/mdns.txt 2>&1 || true
if grep -qs "_adb-tls-connect" /tmp/mdns.txt; then
  echo "NET-INFO mDNS: unexpected result, inspect /tmp/mdns.txt"
else
  echo "NET-INFO mDNS: no _adb-tls-connect services advertised (expected on emulator)"
fi

echo "=== NET-EMU PHASE 7: in-guest egress + app boot ==="
# The one genuinely-real network path: emulator NAT egresses through the
# host NIC, so TCP from INSIDE the guest traverses the actual internet.
# NOTE: slirp does not forward ICMP, so ping can never work here — TCP is
# the honest probe (and is what the app itself uses).
adb shell "echo -e '' | nc -w 5 8.8.8.8 53" >/dev/null 2>&1 \
  && echo "NET-PASS egress: TCP to 8.8.8.8:53 from guest" \
  || echo "NET-FAIL egress: no TCP path from guest"
# DNS + TCP through the guest resolver.
adb shell "echo -e '' | nc -w 5 dns.google 443" >/dev/null 2>&1 \
  && echo "NET-PASS egress: DNS+TCP to dns.google:443 from guest" \
  || echo "NET-FAIL egress: cannot resolve/reach dns.google from guest"
# App must actually boot (validates the #203 APK installs and runs).
adb shell monkey -p moe.shizuku.manager -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 6
FG=$(adb shell "dumpsys activity activities | grep -m1 'mResumedActivity'" 2>/dev/null || true)
echo "$FG" | grep -qs "moe.shizuku.manager" \
  && echo "NET-PASS app-boot: Shizuku manager in foreground on emulator" \
  || echo "NET-WARN app-boot: activity state: $FG"
adb logcat -d -t 200 2>/dev/null | grep -i "FATAL\|AndroidRuntime.*Exception" | head -3 \
  && echo "NET-WARN app-boot: crash lines in logcat (above)" \
  || echo "NET-PASS app-boot: no FATAL in recent logcat"

echo "=== NET-EMU DONE ==="

HOLD="${2:-0}"
if [ "$HOLD" != "0" ]; then
  adb kill-server 2>/dev/null || true
  adb -a nodaemon server start >/tmp/adb.log 2>&1 &
  sleep 3
  adb devices
  TSIP=$(tailscale ip -4 | head -1 || echo UNKNOWN)
  echo "HOLD open for ${HOLD}m"
  echo "Tailscale magic: adb -H $TSIP devices"
  echo "Tailscale magic: adb -H $TSIP shell getprop ro.build.version.sdk"
  sleep "${HOLD}m"
fi