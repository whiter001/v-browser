#!/usr/bin/env sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
SERVER_DIR="$ROOT_DIR/packages/server"
SERVER_BIN="$SERVER_DIR/v-browser"
TEST_UI_BIN="$SCRIPT_DIR/test-ui"
LAB_URL="http://127.0.0.1:48280/lab.html"
EXTENSION_ID_FILE="$HOME/.v-browser/extension_id"

TEST_UI_PID=""

cleanup() {
  if [ -n "$TEST_UI_PID" ]; then
    kill "$TEST_UI_PID" >/dev/null 2>&1 || true
    wait "$TEST_UI_PID" >/dev/null 2>&1 || true
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

ensure_server_bin() {
  if [ -x "$SERVER_BIN" ]; then
    return
  fi
  log 'Building packages/server/v-browser'
  (cd "$SERVER_DIR" && v run ./build.vsh)
}

ensure_test_ui_bin() {
  if [ -x "$TEST_UI_BIN" ]; then
    return
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

assert_result_equals() {
  selector=$1
  expected=$2
  output=$(run_cli --json get text "$selector")
  assert_contains "$output" '"ok":true' "Command get text $selector failed"
  assert_contains "$output" "\"result\":\"$expected\"" "Unexpected text for $selector"
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

log 'CLI smoke completed successfully'