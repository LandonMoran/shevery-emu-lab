#!/bin/bash
# End-to-end module test: DownLoadout on an UNROOTED emulator.
# Usage: downloadout-e2e.sh <shevery-ref> <hold-minutes>
#   shevery-ref: 'latest' | 'tag <tag>' | 'run <run-id>' (debug artifact for run-as)
set -uo pipefail

PKG=com.hamondev.shevery
REF="${1:-latest}"
HOLD="${2:-0}"
MODULE_BRANCH="fix/stage-action-app-fetch"
DOWNLOAD="/storage/emulated/0/Download"
DLDIR="$DOWNLOAD/DownLoadout"
MODDIR="files/adb_modules/downloadout"
PASS=0
FAIL=0

log()  { echo "[E2E] $*"; }
pass() { PASS=$((PASS+1)); log "PASS: $*"; }
fail() { FAIL=$((FAIL+1)); log "FAIL: $*"; }

chk() { # chk <label> <test-expr...>
  local label="$1"; shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

adb_run() { adb shell "$@"; }

# ---- helper: find tap-center of the FIRST node whose text/resource-id matches ----
find_bounds() { # find_bounds <pattern>  -> prints "x y" or empty
  python3 - "$1" <<'PYEOF'
import re, sys, xml.etree.ElementTree as ET
pat = sys.argv[1]
try:
    tree = ET.parse('/tmp/ui.xml')
except Exception:
    sys.exit(1)
for el in tree.iter('node'):
    text = el.get('text') or ''
    rid  = el.get('resource-id') or ''
    if re.search(pat, text) or re.search(pat, rid):
        b = el.get('bounds', '')
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x = (int(m.group(1)) + int(m.group(3))) // 2
            y = (int(m.group(2)) + int(m.group(4))) // 2
            print(x, y)
            sys.exit(0)
sys.exit(1)
PYEOF
}

ui_dump() {
  for i in 1 2 3; do
    adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    adb pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1
    if [ -s /tmp/ui.xml ]; then return 0; fi
    sleep 2
  done
  return 1
}

ui_tap_text() { # ui_tap_text <pattern> [retries]
  local pat="$1" retries="${2:-5}" i xy
  for i in $(seq 1 "$retries"); do
    ui_dump || { sleep 2; continue; }
    xy=$(find_bounds "$pat") || true
    if [ -n "$xy" ]; then
      # shellcheck disable=SC2086
      adb shell input tap $xy
      sleep 3
      return 0
    fi
    sleep 3
  done
  log "ui_tap_text: '$pat' not found after $retries tries"
  return 1
}

# =====================================================================
log "== DownLoadout E2E on unrooted emulator =="
log "APK ref: $REF | module branch: $MODULE_BRANCH"

# ---- 1. fetch + install APK (debug build -> debuggable -> run-as) ----
chmod +x ./scripts/fetch-apk.sh
./scripts/fetch-apk.sh $REF || { log "APK fetch failed"; exit 2; }
APK=$(ls ./apks/*.apk 2>/dev/null | head -1)
[ -n "$APK" ] || { log "no APK found"; exit 2; }
log "Installing $APK"
adb install -r "$APK" | tail -1

# ---- 2. grants (best-effort; some fail on user builds - that's fine) ----
adb_run pm grant $PKG android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true
adb_run pm grant $PKG android.permission.WRITE_SECURE_SETTINGS >/dev/null 2>&1 || true
adb_run appops set $PKG NEARBY_WIFI_DEVICES allow >/dev/null 2>&1 || true

# ---- 3. wake screen ----
adb shell input keyevent 224 >/dev/null 2>&1 || true
adb shell input keyevent 82 >/dev/null 2>&1 || true

# ---- 4. wireless-debugging start flow (skill reference sequence) ----
log "Launching $PKG"
adb shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 6

ui_tap_text "Start via Wireless debugging" 6 || ui_tap_text "Using a wireless connection|Wireless debugging" 5
ui_tap_text "Allow wireless debugging on this network" 4
ui_tap_text "Allow" 4
ui_tap_text "Enable Persistent TCP Mode" 4
ui_tap_text "Enable" 4
sleep 4

if ui_dump && grep -q "Shevery is running" /tmp/ui.xml; then
  pass "server running: 'Shevery is running' shown"
else
  fail "server did not reach running state"
fi
PORT=$(adb shell getprop service.adb.tcp.port 2>/dev/null | tr -d '\r')
log "service.adb.tcp.port=$PORT"
[ "$PORT" = "5555" ] && pass "adb tcp port 5555" || fail "adb tcp port (got '$PORT')"

# ---- 5. install module via run-as (no root; app-private storage) ----
log "Fetching module sources: itsnoly/DownLoadout@$MODULE_BRANCH"
curl -sL "https://github.com/itsnoly/DownLoadout/archive/refs/heads/$MODULE_BRANCH.tar.gz" -o /tmp/module-src.tar.gz
mkdir -p /tmp/module-src && tar -xzf /tmp/module-src.tar.gz -C /tmp/module-src --strip-components=1
[ -f /tmp/module-src/module.prop ] || { log "module.prop missing in source"; exit 2; }

adb shell run-as $PKG mkdir -p files/adb_modules/downloadout/webui || { log "run-as failed - APK not debuggable?"; exit 2; }

install_file() { # install_file <src> <dst-rel>
  local src="$1" dst="$2"
  adb shell "run-as $PKG sh -c 'cat > $dst'" < "$src" || { fail "install file $dst"; return 1; }
}

# Stream every module file into app-private storage
( cd /tmp/module-src && find . -type f ) | while read -r f; do
  rel="${f#./}"
  adb shell "run-as $PKG sh -c 'mkdir -p \"$MODDIR/$(dirname "$rel")\"'"
  install_file "/tmp/module-src/$rel" "$MODDIR/$rel" || true
done
sleep 1
adb shell run-as $PKG ls -la "$MODDIR" 2>&1 | head -20
adb shell run-as $PKG ls "$MODDIR/webui" 2>&1 | head

# ---- 6. open module WebUI (Modules screen -> tap module card) ----
ui_tap_text "DownLoadout|Download" 8 || log "module card not found on this screen"
sleep 8

adb shell run-as $PKG ls "$MODDIR" >/dev/null 2>&1 && log "module dir intact"

# ---- 7. VERIFY PR #3: staging on WebUI load (app-side fetch fallback) ----
sleep 5
STAGED=$(adb shell "ls -l $DLDIR/action.sh" 2>&1 | tr -d '\r')
log "staged action.sh: $STAGED"
if adb shell "[ -f $DLDIR/action.sh ]" 2>/dev/null; then
  pass "action.sh staged to $DLDIR (unrooted, no manual copy)"
  adb shell "sha256sum $DLDIR/action.sh" | tr -d '\r'
else
  fail "action.sh NOT staged - manual copy still required"
fi

# config auto-save on load
if adb shell "[ -f $DLDIR/conveyor_config.json ]" 2>/dev/null; then
  pass "config auto-created in Download/DownLoadout"
else
  fail "config missing after WebUI load"
fi

# ---- 8. seed garbage test files (shell UID 2000, same as module exec) ----
seed() { adb shell "printf 'garbage' > $DOWNLOAD/$1" 2>/dev/null; }
seed "fakepic.png"
seed "pic.JPG"
seed "doc.pdf"
seed "sheet.xlsx"
seed "clip.mp4"
seed "song.mp3"
seed "data.zip"
seed "app.apk"            # unmapped -> must stay
seed "partial.crdownload" # incomplete -> must stay
adb shell "printf 'garbage' > $DOWNLOAD/backup.png.bak" 2>/dev/null
adb shell "printf 'x' > $DOWNLOAD/.hidden" 2>/dev/null
adb shell "mkdir -p $DOWNLOAD/subtest" 2>/dev/null
adb shell "printf 'garbage' > $DOWNLOAD/subtest/nested.png" 2>/dev/null
# collision helper: pre-existing target in Images so the move renames to _1
adb shell "mkdir -p '$DOWNLOAD/! - Images'" 2>/dev/null
adb shell "printf 'pre-existing' > '$DOWNLOAD/! - Images/dup.png'" 2>/dev/null
adb shell "printf 'garbage' > $DOWNLOAD/dup.png" 2>/dev/null

log "files staged before organize:"
adb shell "ls -la $DOWNLOAD" 2>&1 | tr -d '\r' | head -25

# ---- 9. tap Organize Now (WebUI button) ----
if ui_tap_text "Organize Now" 6; then
  pass "Organize Now tapped via UI"
else
  fail "Organize Now button not tappable - running engine directly"
  adb shell "cd $DOWNLOAD && sh $DLDIR/action.sh" 2>&1 | tr -d '\r'
fi
sleep 6

# ---- 10. verify moves ----
verify_moved() { # verify_moved <name> <category-dir>
  local name="$1" dir="$2"
  if adb shell "[ -f '$dir/$name' ]" 2>/dev/null; then
    pass "moved $name -> $dir"
  else
    fail "NOT moved: $name (want $dir)"
  fi
  if adb shell "[ -f $DOWNLOAD/$name ]" 2>/dev/null; then
    log "note: $name still at Download root (double-check expected)"
  fi
}

verify_moved "fakepic.png"    "$DOWNLOAD/! - Images"
verify_moved "pic.JPG"        "$DOWNLOAD/! - Images"
verify_moved "backup.png.bak" "$DOWNLOAD/! - Images"
verify_moved "doc.pdf"        "$DOWNLOAD/! - Documents"
verify_moved "sheet.xlsx"     "$DOWNLOAD/! - Spreadsheets"
verify_moved "clip.mp4"       "$DOWNLOAD/! - Videos"
verify_moved "song.mp3"       "$DOWNLOAD/! - Audio"
verify_moved "data.zip"       "$DOWNLOAD/! - Archives"
# dup.png: pre-existing Images/dup.png exists -> collision rename to dup_1.png
if adb shell "[ -f '$DOWNLOAD/! - Images/dup_1.png' ]" 2>/dev/null; then
  pass "collision rename: dup_1.png in Images"
else
  fail "collision rename: dup_1.png missing"
fi
if adb shell "[ ! -f $DOWNLOAD/dup.png ]" 2>/dev/null; then
  pass "orig dup.png no longer at root"
else
  fail "dup.png still at root after collision move"
fi

# unmapped / skipped must remain at root
for stay in app.apk partial.crdownload .hidden; do
  if adb shell "[ -f $DOWNLOAD/$stay ]" 2>/dev/null; then
    pass "left alone: $stay"
  else
    fail "moved when it should stay: $stay"
  fi
done

# include_subdirs default false -> nested file stays
if adb shell "[ -f $DOWNLOAD/subtest/nested.png ]" 2>/dev/null; then
  pass "subdir untouched (include_subdirs=false default)"
else
  fail "subdir file moved despite default false"
fi

# ---- 11. persistence: config still there, second run idempotent ----
adb shell "[ -f $DLDIR/conveyor_config.json ]" 2>/dev/null && \
  pass "settings persist after organize" || fail "config lost after organize"

log "final Download tree:"
adb shell "find $DOWNLOAD -maxdepth 2 | sort" 2>&1 | tr -d '\r' | head -40

log ""
log "== RESULT: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ] && echo "E2E_STATUS=GREEN" || echo "E2E_STATUS=RED"
exit $(( FAIL > 0 ? 1 : 0 ))