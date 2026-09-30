#!/usr/bin/env bash
# Credentialed primary guard for agy, Google's Antigravity CLI: native startup
# nudge, real session ownership, forced Stop continuation, real watcher
# background completion, and secondmate scope. Uses only a throwaway home and a
# private tmux server; no fleet or operator settings are changed. The startup
# digest is a fixture that acquires the real lock; watcher, guard, hook
# transport, and the agy binary are production.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_AGY_PRIMARY_LIVE agy tmux python3 jq
LAB=$(fm_test_tmproot fm-agy-primary-live)
cleanup() {
  local rc=$? evidence
  if [ "$rc" -ne 0 ]; then
    evidence=$(mktemp -d "${TMPDIR:-/tmp}/agy-primary-evidence.XXXXXX")
    cp -R "$LAB/." "$evidence/"
    rm -f "$evidence/.fm-test-fixture"
    printf 'Agy primary failure evidence retained: %s\n' "$evidence" >&2
  fi
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
python3 "$ROOT/tests/agy-primary-live-probe.py" "$ROOT" "$LAB"
