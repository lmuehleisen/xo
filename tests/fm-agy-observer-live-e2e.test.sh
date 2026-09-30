#!/usr/bin/env bash
# Live guard for the agy worker log-only tool observer (bin/fm-agy-hook.sh),
# in bin/fm-test-run.sh's live-harness-optin family. Opt-in because it spends
# model tokens; it uses the cheapest Gemini catalog tier and never an agy
# Claude model.
#
# Hook firing is agy-emitted, so only the real binary can prove it: the
# installed worker hook file must make one headless run emit a PreToolUse and
# a PostToolUse line into state/agy-permission-log.jsonl while the tool runs
# unchanged - the abstain contract's entire point. A stub can only confirm
# the shape the stub already assumed.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGY_BIN=$(command -v agy 2>/dev/null || true)
AGY_VERSION=
LAB=

cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$LAB" ]; then
    printf 'agy observer failure evidence retained: %s\n' "$LAB" >&2
  else
    fm_test_rm_tmproot "${LAB:-}"
  fi
}
trap cleanup EXIT

fail() {
  printf 'not ok - %s (agy %s)\n' "$1" "${AGY_VERSION:-unknown}" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_AGY_OBSERVER_LIVE agy

[ -x "${AGY_BIN:-}" ] \
  || fail "FM_AGY_OBSERVER_LIVE=1 but no real agy executable is installed"
AGY_VERSION=$("$AGY_BIN" --version 2>/dev/null | tr -d '\n')
[ -n "$AGY_VERSION" ] || fail 'the installed agy did not report a version'

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-agy-observer.XXXXXX")
# Resolved deliberately, exactly as bin/fm-spawn.sh resolves each agy grant.
LAB=$(cd "$LAB" && pwd -P)
fm_test_require_tmproot "$LAB"
WORKSPACE="$LAB/workspace" STATE="$LAB/state" ID=agy-observer
mkdir -p "$WORKSPACE" "$STATE"
# A git workspace is the shape every real worker runs in.
git init -q "$WORKSPACE" || fail 'could not init the lab workspace'
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID") || fail 'could not arm worker state'
"$ROOT/bin/fm-agy-hook.sh" install-worker "$STATE" "$ID" "$GEN" "$WORKSPACE" \
  || fail 'could not install production worker hooks'
LOG="$STATE/agy-permission-log.jsonl"

# One trivial headless prompt, cheapest Gemini tier. This fixture passes the
# bypass flag for its own headless run, apart from the guarded worker opt-in
# that emits it with the policy layer installed, because headless mode
# auto-denies unapproved tools, so nothing would execute for PostToolUse to
# observe. Hooks were verified to still fire under it.
CANARY="$WORKSPACE/observer-canary"
out=$(cd "$WORKSPACE" && "$AGY_BIN" -p \
  "Run this exact shell command with run_command, then reply DONE: /usr/bin/touch $CANARY" \
  --model gemini-3.6-flash-low --dangerously-skip-permissions \
  --add-dir "$WORKSPACE" --add-dir "$STATE/$ID.agy-hooks" \
  --print-timeout 120s 2>&1) \
  || fail "agy headless run failed: $out"

[ -f "$CANARY" ] || fail "the observed tool did not run unchanged: $out"
[ -s "$LOG" ] || fail "the observer wrote no log: $out"
jq -c . "$LOG" >/dev/null || fail 'an observer line is not valid JSON'
jq -es --arg id "$ID" '
  (map(select(.event == "pre-tool-use")) | length >= 1)
  and (map(select(.event == "post-tool-use")) | length >= 1)
  and all(.[]; .task == $id)
  and all(.[]; .session_id | type == "string" and length > 0)
  and (map(select(.event == "post-tool-use"))[0].error == "")' "$LOG" >/dev/null \
  || fail "no matching pre/post pair landed in the log: $(cat "$LOG")"
pass "agy $AGY_VERSION: installed worker hooks emit a PreToolUse and PostToolUse line while the tool runs unchanged"

printf '# agy observer live checks passed (agy %s)\n' "$AGY_VERSION"
