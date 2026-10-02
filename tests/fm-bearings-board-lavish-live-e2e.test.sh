#!/usr/bin/env bash
# tests/fm-bearings-board-lavish-live-e2e.test.sh - live drift guard proving
# the real lavish-axi still behaves the way bin/fm-bearings-board.sh's session
# check and bin/fm-lavish-lib.sh's loopback pin are written against.
#
# The build's "is this board actually open" verdict comes from what lavish-axi
# prints, a surface the vendor controls. Opening a session the captain ended
# from the browser EXITS 0 while refusing to reopen, so a build that trusted
# the exit status would arm a poll against a dead session. A stubbed lavish-axi
# can only confirm the assumption already written into the stub, so this runs
# the real tool: an answers-mode build must report the session live, bind and
# arm, serve only on loopback, and reopen a captain-ended session.
#
# The captain-ended state is reached through the same server route the
# browser's End session button calls, so no browser is needed. Everything runs
# in a temporary home with its own Lavish state directory and a free loopback
# port, and the server it started is stopped before the guard returns.
#
# Standard CI has no lavish-axi, so this reports a capability skip there. The
# portable counterpart in tests/fm-bearings-board.test.sh pins the build's
# logic against a stub that reproduces these shapes. Run this guard after a
# lavish-axi upgrade and before trusting refreshed evidence.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fm_live_gate default-on FM_BEARINGS_LAVISH_LIVE lavish-axi jq curl lsof python3

pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

LAB=''
cleanup() {
  fm_test_reap_procevent_homes
  [ -z "$LAB" ] || {
    LAVISH_AXI_TELEMETRY=0 lavish-axi stop >/dev/null 2>&1 || true
    rm -rf "$LAB"
  }
}
fail() { printf 'not ok - %s\n' "$1" >&2; cleanup; exit 1; }
trap cleanup EXIT

VERSION=$(LAVISH_AXI_TELEMETRY=0 lavish-axi --version 2>/dev/null | tr -d '[:space:]')
note "lavish-axi ${VERSION:-version-unknown}"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-bearings-lavish-live.XXXXXX") || fail "cannot create the guard lab"
LAB=$(cd -P -- "$LAB" && pwd -P)
mkdir -p "$LAB/state" "$LAB/data" "$LAB/config" "$LAB/lavish-state"
printf 'answers\n' > "$LAB/config/lavish"
fm_test_track_procevent_home "$LAB" "$LAB/procevent-claims"
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()') \
  || fail "cannot pick a free loopback port"
export LAVISH_AXI_STATE_DIR="$LAB/lavish-state" LAVISH_AXI_PORT="$PORT"
unset LAVISH_AXI_HOST

cat > "$LAB/payload.json" <<'JSON'
{
  "schema": "fm-bearings-board.v1",
  "home": "lavish-live-guard",
  "generated": "2026-01-01T00:00Z",
  "prs_live": false,
  "captains_call": [
    {
      "key": "sample-live-guard-call",
      "type": "decision",
      "repo": "sample",
      "title": "Guard placeholder",
      "options": [{ "value": "yes", "label": "Yes" }]
    }
  ],
  "underway": [],
  "landed": [],
  "charted": []
}
JSON

run_board() {
  FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_DATA_OVERRIDE="$LAB/data" \
    FM_PROCEVENT_CLAIM_ROOT="$LAB/procevent-claims" \
    "$ROOT/bin/fm-bearings-board.sh" "$@"
}

BOARD="$LAB/.lavish/bearings-board.html"
out=$(run_board build "$LAB/payload.json" 2>&1) || fail "the guard board did not build: $out"
case "$out" in
  *"session: live"*"bound: "*"armed: "*) ;;
  *) fail "an answers-mode build against lavish-axi ${VERSION:-version-unknown} did not serve, bind, and arm: $out" ;;
esac
url=$(printf '%s\n' "$out" | sed -n 's/^url: //p')
case "$url" in
  "http://127.0.0.1:$PORT/session/"*) ;;
  *) fail "lavish-axi ${VERSION:-version-unknown} printed a non-loopback session URL under the pin: $url" ;;
esac
listen=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }' | sort -u)
[ "$listen" = "127.0.0.1:$PORT" ] \
  || fail "lavish-axi ${VERSION:-version-unknown} listens beyond loopback under the pin: ${listen:-nothing}"
pass "an answers-mode build serves, binds, and arms the board on loopback only with lavish-axi ${VERSION:-version-unknown}"

key=${url##*/}
base=${url%/session/*}
# End it exactly as the browser's End session button does.
curl -fsS -X POST "$base/api/$key/end" >/dev/null 2>&1 \
  || fail "could not end the guard board session as the captain"

# ASSUMPTION UNDER GUARD: this exits 0 while reporting the session is not open.
ended_rc=0
ended_out=$(FM_HOME="$LAB" "$ROOT/bin/fm-lavish.sh" run "$BOARD" 2>&1) || ended_rc=$?
[ "$ended_rc" -eq 0 ] \
  || fail "lavish-axi ${VERSION:-version-unknown} now exits $ended_rc on a captain-ended session; the board build's session check must be revisited"
ended_status=$(printf '%s\n' "$ended_out" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1 | tr -d '"')
[ "$ended_status" = user-ended ] \
  || fail "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session as '$ended_status', not user-ended; the board build's session check must be revisited"
pass "lavish-axi ${VERSION:-version-unknown} reports a captain-ended session as user-ended without failing"

# THE BEHAVIOR UNDER GUARD: the build must not accept that, and must recover.
out=$(run_board build "$LAB/payload.json" 2>&1) \
  || fail "the board build refused a recoverable captain-ended session: $out"
case "$out" in
  *"session: reopened"*) ;;
  *) fail "the board build did not reopen the captain-ended session: $out" ;;
esac
pass "the board build reopens a captain-ended session against real lavish-axi instead of arming a dead one"
