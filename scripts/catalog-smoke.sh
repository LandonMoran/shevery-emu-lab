#!/bin/bash
# Catalog fix smoke test: token dialog + link + error/empty surfaces (trim-audit-round1)
# Usage: catalog-smoke.sh <apk-or-dir> [adb-target]
#   adb-target: usually 'shevery-emu:5555' (Tailscale) or empty for local
set -uo pipefail

PKG=com.hamondev.shevery
ADB_HOST="${ADB_HOST:-}"
ADB_TARGET="${2:-}"
# resolve adb: not on default PATH in non-interactive shells
if ! command -v adb >/dev/null 2>&1 && [ -x /opt/android-sdk/platform-tools/adb ]; then
  PATH="/opt/android-sdk/platform-tools:$PATH"
fi
adbx() {
  if [ -n "$ADB_HOST" ]; then adb -H "$ADB_HOST" -P 5037 "$@"; else adb "$@"; fi
}
AD() { adbx "$@"; }
PASS=0
FAIL=0
log()  { echo "[SMOKE] $*"; }
pass() { PASS=$((PASS+1)); log "PASS: $*"; }
fail() { FAIL=$((FAIL+1)); log "FAIL: $*"; }
chk()  { local l="$1"; shift; if "$@"; then pass "$l"; else fail "$l"; fi; }

ui_dump() {
  for i in 1 2 3; do
    AD shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
    AD pull /sdcard/ui.xml /tmp/ui.xml >/dev/null 2>&1
    if [ -s /tmp/ui.xml ]; then return 0; fi
    sleep 2
  done
  return 1
}

find_bounds() { # find_bounds <pattern> -> "x y" or empty (exact text, then regex)
  python3 - "$1" <<'PYEOF'
import re, sys, xml.etree.ElementTree as ET
pat = sys.argv[1]
try:
    tree = ET.parse('/tmp/ui.xml')
except Exception:
    sys.exit(1)
def center(el):
    b = el.get('bounds', '')
    m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
    if m:
        return (int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2
    return None
for el in tree.iter('node'):
    if el.get('text') == pat:
        c = center(el)
        if c:
            print(*c); sys.exit(0)
for el in tree.iter('node'):
    text = el.get('text') or ''
    rid = el.get('resource-id') or ''
    desc = el.get('content-desc') or ''
    if re.search(pat, text) or re.search(pat, rid) or re.search(pat, desc):
        c = center(el)
        if c:
            print(*c); sys.exit(0)
sys.exit(1)
PYEOF
}

ui_tap_text() { # ui_tap_text <pattern> [retries]
  local pat="$1" retries="${2:-6}" i xy
  for i in $(seq 1 "$retries"); do
    ui_dump || { sleep 2; continue; }
    xy=$(find_bounds "$pat") || true
    if [ -n "$xy" ]; then
      # shellcheck disable=SC2086
      AD shell input tap $xy
      sleep 3
      return 0
    fi
    sleep 3
  done
  log "ui_tap_text: '$pat' not found after $retries tries"
  return 1
}

assert_text() { # assert_text <label> <pattern> [retries]
  local label="$1" pat="$2" retries="${3:-5}" i
  for i in $(seq 1 "$retries"); do
    ui_dump || { sleep 2; continue; }
    if find_bounds "$pat" >/dev/null 2>&1; then pass "$label"; return 0; fi
    sleep 3
  done
  fail "$label ('$pat' not visible)"
  return 1
}

assert_no_text() { # assert_no_text <label> <pattern> [rounds]
  local label="$1" pat="$2" rounds="${3:-4}" i
  for i in $(seq 1 "$rounds"); do
    ui_dump || { sleep 2; continue; }
    if ! find_bounds "$pat" >/dev/null 2>&1; then pass "$label"; return 0; fi
    sleep 2
  done
  fail "$label ('$pat' still visible)"
  return 1
}

# full mCurrentFocus line, spaces included up to closing brace
current_focus() {
  AD shell dumpsys window 2>/dev/null | grep -oE 'mCurrentFocus=[^}]*}' | head -1
}

wait_for_pkg_focus() { # wait_for_pkg_focus <package> [rounds]
  local pkg="$1" n="${2:-8}" fg i
  for i in $(seq 1 "$n"); do
    fg=$(current_focus)
    case "$fg" in
      *"$pkg"*) return 0 ;;
      *) sleep 2 ;;
    esac
  done
  log "app foreground not seen (last: $fg)"
  return 1
}

# tap the clickable URL span inside the token dialog description.
# The URL is appended on its own line ("\n" before it), so it sits at the
# bottom-left of the ClickableText node. Then verify a browser took focus.
tap_token_url() {
  ui_dump || return 1
  local c
  c=$(python3 - <<'PYEOF'
import re, sys, xml.etree.ElementTree as ET
try:
    tree = ET.parse('/tmp/ui.xml')
except Exception:
    sys.exit(1)
for el in tree.iter('node'):
    text = el.get('text') or ''
    if 'github.com/settings/tokens' in text:
        b = el.get('bounds', '')
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            # URL line: bottom of the text block, left-aligned.
            print(x1 + 90, y2 - int((y2 - y1) / 6))
            sys.exit(0)
sys.exit(1)
PYEOF
)
  [ -n "$c" ] || return 1
  # shellcheck disable=SC2086
  AD shell input tap $c
  sleep 1
  return 0
}

APK="${1:-}"
[ -n "$APK" ] && [ -f "$APK" ] || { log "APK not found: $APK"; exit 2; }
AD wait-for-device 2>/dev/null || true

log "== Catalog smoke: token dialog + link + error surface (trim) =="
AD shell input keyevent 82 >/dev/null 2>&1 || true

# ---- dismiss any system dialogs (notifications permission, etc) ----
dismiss_system_dialogs() {
  local i
  for i in 1 2 3; do
    ui_dump || { sleep 2; continue; }
    if find_bounds "Don.t allow|Deny|Cancel" >/dev/null 2>&1; then
      ui_tap_text "Don.t allow" 2 || ui_tap_text "Deny" 2 || ui_tap_text "Cancel" 2 || true
      log "dismissed a system dialog (round $i)"
      sleep 2
    else
      break
    fi
  done
}
dismiss_system_dialogs

# ---- 0. install + CLEAN state (blank token, no cache, permissions re-granted) ----
# playstore image: launcher ANR-dialog crash-loop + background-ANR dialogs kill UI driving
AD shell am force-stop com.google.android.apps.nexuslauncher >/dev/null 2>&1 || true
AD shell settings put global anr_show_background 0 >/dev/null 2>&1 || true
log "Installing $APK"
AD install -r "$APK" | tail -1
AD shell pm clear $PKG >/dev/null 2>&1 || true
AD shell pm grant $PKG android.permission.POST_NOTIFICATIONS >/dev/null 2>&1 || true

# ---- 1. launch ----
AD shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
assert_text "app launched" "Shevery|Settings|Home|catalog" 8 || true

# ---- 2. go to Catalog (ADB Modules tab -> Catalog toggle) ----
if ! ui_tap_text "ADB Modules" 8; then
  fail "could not reach ADB Modules tab"
fi
sleep 3
ui_tap_text "Catalog" 8 || fail "could not reach Catalog toggle"
sleep 4

# ---- 3. token dialog present (no token stored) ----
assert_text "token dialog appears without a token" "GitHub token required" 8 || true
assert_text "create-token link text visible" "github.com/settings/tokens" 6 || true

# ---- 4. tap the URL span -> a REAL browser window must gain focus ----
BROWSER_OPEN=0
for attempt in 1 2 3; do
  tap_token_url || { sleep 2; continue; }
  for i in 1 2 3 4; do
    FG=$(current_focus)
    case "$FG" in
      *chrome*|*browser*) BROWSER_OPEN=1; break ;;
      *com.android.settings*|*com.google.android.permissioncontroller*)
        # a browser chooser/permission dialog popped up; pick Chrome
        ui_tap_text "Chrome" 2 || ui_tap_text "Open" 2 || true
        sleep 2 ;;
    esac
    sleep 2
  done
  [ "$BROWSER_OPEN" -eq 1 ] && break
  AD shell input keyevent 4 >/dev/null 2>&1 || true  # close chooser if any
  sleep 1
done
if [ "$BROWSER_OPEN" -eq 1 ]; then
  pass "token link opens browser (real browser focus: $FG)"
else
  fail "token link did not open a browser window"
fi
AD shell input keyevent 4  # back from browser
wait_for_pkg_focus "$PKG" 8 || fail "app did not regain foreground after browser-back"
sleep 3

# ---- 5. back on dialog: cancel (blank token) -> dismiss + navigate up ----
ui_dump || true
if find_bounds "GitHub token required" >/dev/null 2>&1; then
  pass "token dialog still shown after browser-back"
else
  fail "token dialog not shown after browser-back"
fi
ui_tap_text "Cancel" 5 || ui_tap_text "cancel" 5 || fail "token dialog Cancel not found"
assert_no_text "Cancel dismissed dialog (no re-trigger)" "GitHub token required|settings/tokens" 5 || true

# ---- 6. return to catalog, enter INVALID-format token -> inline warning ----
ui_tap_text "Catalog" 8 || true
sleep 4
assert_text "token dialog again (still no token)" "GitHub token required" 6 || true
ui_dump || true
XY=$(python3 - <<'PYEOF'
import re, sys, xml.etree.ElementTree as ET
tree = ET.parse('/tmp/ui.xml')
for el in tree.iter('node'):
    if el.get('class') == 'android.widget.EditText':
        b = el.get('bounds', '')
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2); sys.exit(0)
sys.exit(1)
PYEOF
)
[ -n "$XY" ] && AD shell input tap $XY && sleep 2
AD shell input text "not-a-token"
sleep 2
assert_text "invalid-format token shows inline warning" "Token should start with ghp_|github_pat_|at least 30" 5 || true
ui_tap_text "Cancel" 4 || true
sleep 2

# ---- 7. valid-format fake token -> dialog closes, fetch 401 (swallowed) -> empty state ----
ui_tap_text "Catalog" 8 || true
sleep 4
assert_text "token dialog again (2nd)" "GitHub token required" 6 || true
ui_dump || true
XY2=$(python3 - <<'PYEOF'
import re, sys, xml.etree.ElementTree as ET
tree = ET.parse('/tmp/ui.xml')
for el in tree.iter('node'):
    if el.get('class') == 'android.widget.EditText':
        b = el.get('bounds', '')
        m = re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', b)
        if m:
            print((int(m.group(1)) + int(m.group(3))) // 2, (int(m.group(2)) + int(m.group(4))) // 2); sys.exit(0)
sys.exit(1)
PYEOF
)
[ -n "$XY2" ] && AD shell input tap $XY2 && sleep 2
AD shell input text "ghp_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
sleep 2
ui_tap_text "OK" 5 || ui_tap_text "Save" 5 || fail "could not submit token"
assert_no_text "OK closed the token dialog" "GitHub token required|settings/tokens" 6 || true
sleep 4
assert_text "fetch failure surfaces the empty-state guidance" "No modules found|check your token and internet" 10 || true

# ---- 8. empty state (not banner) is the designed 401 surface ---- 
# refresh() swallows the 401 (pre-existing); CatalogScreen's banner is fetch-unreachable
if find_bounds "No modules found|check your token and internet" >/dev/null 2>&1 \
   && find_bounds "Try again" >/dev/null 2>&1 && find_bounds "Edit token" >/dev/null 2>&1; then
  pass "empty state with actions (Try again / Edit token) shown for 401"
else
  fail "empty state actions missing (Try again / Edit token)"
fi
if find_bounds "GitHub search failed|401" >/dev/null 2>&1; then
  fail "unexpected 401 banner (refresh() swallows; banner is unreachable for fetch)"
else
  pass "no 401 banner (error goes to manager._error, unobserved by catalog)"
fi

# ---- 9. toolbar Refresh re-triggers the request (stays empty, no dialog) ----
ui_tap_text "Refresh" 5 || true
sleep 4
assert_no_text "Refresh re-fetch does not re-trigger token dialog" "GitHub token required" 6 || true
assert_text "Refresh re-fetch keeps empty state" "No modules found|check your token and internet" 8 || true

# ---- 10. relaunch: stored bad token must NOT re-trigger the dialog ----
AD shell am force-stop $PKG
sleep 2
AD shell monkey -p $PKG -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 8
ui_tap_text "ADB Modules" 5 || true
sleep 2
ui_tap_text "Catalog" 5 || true
sleep 4
assert_no_text "no dialog re-trigger loop with stored token" "GitHub token required" 4 || true

log "== done: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" -eq 0 ]
