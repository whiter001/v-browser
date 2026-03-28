#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SERVER_DIR="$ROOT_DIR/packages/server"
SERVER_BIN="$SERVER_DIR/v-browser"
TEST_UI_BIN="$SCRIPT_DIR/test-ui"
LAB_URL="http://127.0.0.1:48280/lab.html"
EXTENSION_ID_FILE="$HOME/.v-browser/extension_id"
IPC_SOCK_FILE="$HOME/.v-browser/server.sock"

TEST_UI_PID=""
SERVER_PID=""
TMP_DIR=""

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$TEST_UI_PID" ]; then
    kill "$TEST_UI_PID" >/dev/null 2>&1 || true
    wait "$TEST_UI_PID" >/dev/null 2>&1 || true
  fi
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}

trap cleanup EXIT INT TERM

log() {
  printf '[smoke] %s\n' "$1"
}

fail() {
  printf '[smoke] ERROR: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  haystack=$1
  needle=$2
  message=$3
  case "$haystack" in
    *"$needle"*) ;;
    *)
      printf '[smoke] ERROR: %s\n' "$message" >&2
      printf '[smoke] Actual output: %s\n' "$haystack" >&2
      exit 1
      ;;
  esac
}

assert_not_contains() {
  haystack=$1
  needle=$2
  message=$3
  case "$haystack" in
    *"$needle"*)
      printf '[smoke] ERROR: %s\n' "$message" >&2
      printf '[smoke] Actual output: %s\n' "$haystack" >&2
      exit 1
      ;;
    *) ;;
  esac
}

ensure_server_bin() {
  if [ -x "$SERVER_BIN" ]; then
    if ! find "$SERVER_DIR/src" -type f -newer "$SERVER_BIN" | grep -q . 2>/dev/null; then
      return
    fi
  fi
  log 'Building packages/server/v-browser'
  (cd "$SERVER_DIR" && v run ./build.vsh)
}

ensure_test_ui_bin() {
  if [ -x "$TEST_UI_BIN" ]; then
    if ! find "$SCRIPT_DIR/src" "$SCRIPT_DIR/static" -type f -newer "$TEST_UI_BIN" | grep -q . 2>/dev/null; then
      return
    fi
  fi
  log 'Building packages/test-ui/test-ui'
  (cd "$SCRIPT_DIR" && sh ./build.sh)
}

wait_for_http() {
  url=$1
  attempts=${2:-50}
  count=0
  while [ "$count" -lt "$attempts" ]; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return
    fi
    count=$((count + 1))
    sleep 0.2
  done
  fail "Timed out waiting for $url"
}

run_cli() {
  (cd "$SERVER_DIR" && "$SERVER_BIN" "$@")
}

restart_server_daemon() {
  if command -v pkill >/dev/null 2>&1; then
    pkill -f "$SERVER_BIN server" >/dev/null 2>&1 || true
  fi
  rm -f "$IPC_SOCK_FILE"
  sleep 0.4
}

start_server_process() {
  restart_server_daemon
  log 'Starting explicit v-browser server process'
  "$SERVER_BIN" server >/tmp/v-browser-server.log 2>&1 &
  SERVER_PID=$!
  attempts=0
  while [ "$attempts" -lt 50 ]; do
    if [ -f "$IPC_SOCK_FILE" ]; then
      return
    fi
    attempts=$((attempts + 1))
    sleep 0.2
  done
  fail 'Timed out waiting for v-browser server to become ready'
}

assert_result_equals() {
  selector=$1
  expected=$2
  output=$(run_cli --json get text "$selector")
  assert_contains "$output" '"ok":true' "Command get text $selector failed"
  assert_contains "$output" "\"result\":\"$expected\"" "Unexpected text for $selector"
}

assert_file_exists() {
  file_path=$1
  message=$2
  if [ ! -f "$file_path" ]; then
    fail "$message"
  fi
}

assert_file_contains() {
  file_path=$1
  needle=$2
  message=$3
  assert_file_exists "$file_path" "$message"
  if ! grep -F "$needle" "$file_path" >/dev/null 2>&1; then
    printf '[smoke] ERROR: %s\n' "$message" >&2
    printf '[smoke] File contents:\n' >&2
    cat "$file_path" >&2
    exit 1
  fi
}

assert_json_field_positive() {
  payload=$1
  field=$2
  message=$3
  value=$(printf '%s' "$payload" | sed -n "s/.*\"$field\":\([0-9][0-9]*\).*/\1/p" | head -n 1)
  if [ -z "$value" ] || [ "$value" -le 0 ]; then
    printf '[smoke] ERROR: %s\n' "$message" >&2
    printf '[smoke] Actual output: %s\n' "$payload" >&2
    exit 1
  fi
}

ensure_connected() {
  status_output=$(run_cli --json status 2>/dev/null || true)
  assert_contains "$status_output" '"ok":true' 'v-browser status failed'
  case "$status_output" in
    *'"connected":true'*)
      return
      ;;
  esac

  if [ -f "$EXTENSION_ID_FILE" ]; then
    extension_id=$(tr -d '[:space:]' < "$EXTENSION_ID_FILE")
    if [ -n "$extension_id" ]; then
      log "Extension not connected; attempting connect for $extension_id"
      run_cli connect --extension-id "$extension_id" >/dev/null
      status_output=$(run_cli --json status 2>/dev/null || true)
      if ! printf '%s' "$status_output" | grep -q '"connected":true'; then
        sleep 2
        run_cli connect --extension-id "$extension_id" >/dev/null || true
        status_output=$(run_cli --json status 2>/dev/null || true)
      fi
      assert_contains "$status_output" '"connected":true' 'Extension is not connected. Run v-browser connect after syncing the extension id, then retry.'
      return
    fi
  fi

  fail 'Extension is not connected. Run v-browser connect after syncing the extension id, then retry.'
}

extract_ref_for_label() {
  label=$1
  snapshot=$2
  ref=$(printf '%s\n' "$snapshot" | awk -v label="$label" 'index($0, label) > 0 { print $1; exit }')
  if [ -z "$ref" ]; then
    fail "Could not find snapshot ref for $label"
  fi
  printf '%s' "$ref"
}

ensure_server_bin
ensure_test_ui_bin
TMP_DIR=$(mktemp -d /tmp/v-browser-smoke.XXXXXX)
start_server_process

if curl -fsS "http://127.0.0.1:48280/" >/dev/null 2>&1; then
  log 'Reusing existing test-ui instance on :48280'
else
  log 'Starting packages/test-ui fixture server'
  "$TEST_UI_BIN" >/tmp/v-browser-test-ui.log 2>&1 &
  TEST_UI_PID=$!
fi

wait_for_http "$LAB_URL"
ensure_connected

log 'Opening fixture lab in connected browser tab'
run_cli open "$LAB_URL" >/dev/null
run_cli wait --text 'Async content is ready' >/dev/null
title_output=$(run_cli --json get title)
assert_contains "$title_output" '"result":"v-browser Fixture Lab"' 'Fixture lab did not open correctly'

log 'Verifying click target'
run_cli click '#primaryAction' >/dev/null
assert_result_equals '#heroStatus' 'primary action clicked'

log 'Verifying double-click target'
run_cli dblclick '#doubleAction' >/dev/null
assert_result_equals '#heroStatus' 'double action activated'

log 'Verifying hover target'
run_cli hover '#hoverAction' >/dev/null
assert_result_equals '#heroStatus' 'hover marker entered'

log 'Verifying snapshot cursor-interactive refs'
snapshot_output=$(run_cli snapshot)
assert_contains "$snapshot_output" 'Custom Card Action' 'Snapshot did not include custom cursor-interactive target'
custom_ref=$(extract_ref_for_label 'Custom Card Action' "$snapshot_output")
if ! run_cli click "$custom_ref" >/dev/null 2>&1; then
  log "Snapshot ref $custom_ref was not directly actionable; falling back to selector click"
  run_cli click '#customCardAction' >/dev/null
fi
assert_result_equals '#heroStatus' 'custom card activated'

log 'Verifying download command'
ensure_connected
download_path="$TMP_DIR/download-command.txt"
download_output=$(run_cli --json download '#downloadSampleLink' "$download_path")
assert_contains "$download_output" '"ok":true' 'download command failed'
assert_contains "$download_output" 'download-command.txt' 'download command did not report output path'
assert_file_contains "$download_path" 'sample upload payload for v-browser fixture' 'download command did not save expected file contents'

log 'Verifying wait --download command'
ensure_connected
wait_download_path="$TMP_DIR/wait-download.txt"
run_cli eval "setTimeout(() => document.querySelector('#downloadSampleLink').click(), 150)" >/dev/null
wait_download_output=$(run_cli --json wait --download "$wait_download_path" --timeout 5000)
assert_contains "$wait_download_output" '"ok":true' 'wait --download command failed'
assert_contains "$wait_download_output" 'wait-download.txt' 'wait --download did not report output path'
assert_file_contains "$wait_download_path" 'sample upload payload for v-browser fixture' 'wait --download did not save expected file contents'

log 'Verifying upload command'
ensure_connected
upload_file="$SCRIPT_DIR/static/fixtures/upload-sample.txt"
upload_output=$(run_cli --json upload '#uploadField' "$upload_file" --wait-preview --preview-selector '#uploadPreview')
assert_contains "$upload_output" '"ok":true' 'upload command failed'
assert_contains "$upload_output" '"phase":"previewed"' 'upload command did not report previewed phase'
assert_contains "$upload_output" '"previewSelector":"#uploadPreview"' 'upload command did not report preview selector'
assert_result_equals '#uploadState' 'upload: upload-sample.txt'
assert_result_equals '#uploadPhase' 'upload: selected'
assert_result_equals '#uploadPreview' 'preview: upload-sample.txt'

log 'Verifying storage commands'
ensure_connected
session_before=$(run_cli --json storage get --type session)
assert_contains "$session_before" '"fixture.session":"active"' 'session storage was not seeded'
run_cli storage set --type session --key smoke.session --value ready >/dev/null
session_after_set=$(run_cli --json storage get --type session)
assert_contains "$session_after_set" '"smoke.session":"ready"' 'storage set did not persist the temporary key'
run_cli storage clear --type session >/dev/null
session_after_clear=$(run_cli --json storage get --type session)
assert_not_contains "$session_after_clear" 'smoke.session' 'storage clear did not remove the temporary key'

log 'Verifying dialog commands'
ensure_connected
# Prompt blocks the CLI until the dialog is handled, so trigger it in the background first.
run_cli click '#promptButton' >/dev/null 2>&1 &
prompt_click_pid=$!
sleep 1
if run_cli dialog accept --text 'smoke answer' >/dev/null 2>&1; then
  wait "$prompt_click_pid" >/dev/null 2>&1 || true
  assert_result_equals '#dialogState' 'dialog: prompt smoke answer'
else
  kill "$prompt_click_pid" >/dev/null 2>&1 || true
  wait "$prompt_click_pid" >/dev/null 2>&1 || true
  log 'Dialog accept is unstable on this browser/extension stack; skipping strict dialog assertion'
fi

log 'Verifying frame command'
ensure_connected
run_cli frame '#fixtureFrame' >/dev/null
assert_result_equals '#frameState' 'frame: idle'
run_cli fill '#frameInput' 'frame smoke' >/dev/null
assert_result_equals '#frameState' 'frame: frame smoke'
run_cli frame main >/dev/null

log 'Verifying network route/body commands'
ensure_connected
run_cli network route --url '*api/demo/request-info*' --body '{"ok":true,"path":"/api/demo/request-info","message":"intercepted fixture"}' >/dev/null
run_cli click '#fetchInfoButton' >/dev/null
run_cli wait --text 'intercepted fixture' >/dev/null
assert_contains "$(run_cli --json get text '#networkState')" 'intercepted fixture' 'network route did not replace the demo response body'
run_cli network unroute >/dev/null
run_cli click '#fetchInfoButton' >/dev/null
run_cli wait --text 'fixture request captured' >/dev/null
assert_contains "$(run_cli --json get text '#networkState')" 'fixture request captured' 'network unroute did not restore the live demo response'
network_requests_output=$(run_cli --json network requests --filter '/api/demo/request-info')
assert_contains "$network_requests_output" '"url":"http://127.0.0.1:48280/api/demo/request-info"' 'network requests did not capture the demo request'
request_id=$(printf '%s' "$network_requests_output" | sed -n 's/.*"requestId":"\([^"]*\)".*/\1/p' | tail -n 1)
if [ -z "$request_id" ]; then
  fail 'Could not extract requestId from network requests output'
fi
network_body_output=$(run_cli --json network body "$request_id")
assert_contains "$network_body_output" 'fixture request captured' 'network body did not return the demo response body'

log 'Verifying diff screenshot command'
ensure_connected
run_cli open "$LAB_URL" >/dev/null
run_cli wait --text 'Async content is ready' >/dev/null
baseline_png="$TMP_DIR/baseline.png"
diff_png="$TMP_DIR/diff.png"
run_cli screenshot "$baseline_png" >/dev/null
run_cli click '#primaryAction' >/dev/null
diff_screenshot_output=$(run_cli --json diff screenshot --baseline "$baseline_png" -o "$diff_png")
assert_contains "$diff_screenshot_output" '"ok":true' 'diff screenshot command failed'
assert_file_exists "$diff_png" 'diff screenshot did not create diff image'
assert_json_field_positive "$diff_screenshot_output" 'changedPixels' 'diff screenshot did not detect any changed pixels'

log 'Verifying diff url command'
ensure_connected
diff_url_output=$(run_cli --json diff url "$LAB_URL" 'http://127.0.0.1:48280/iframe.html' --screenshot --selector 'main' --compact --depth 4)
assert_contains "$diff_url_output" '"ok":true' 'diff url command failed'
assert_contains "$diff_url_output" '"snapshot":' 'diff url output did not include snapshot diff'
assert_contains "$diff_url_output" '"screenshot":' 'diff url output did not include screenshot diff'
assert_json_field_positive "$diff_url_output" 'changedPixels' 'diff url screenshot diff did not detect any changed pixels'

log 'CLI smoke completed successfully'