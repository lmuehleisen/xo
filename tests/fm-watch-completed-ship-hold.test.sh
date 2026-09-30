#!/usr/bin/env bash
# tests/fm-watch-completed-ship-hold.test.sh - the watcher's side of a completed
# ship held for the captain's approval (the real watcher with a real
# bin/fm-captain-hold.sh hold).
#
# After the finished worker exits, the held ship enters declared-wait handling:
# an idle pane and a harmless pane change stay quiet, while a new worker event is
# still surfaced and the hold and in-flight state survive. The hold command's
# own side is pinned by tests/fm-captain-hold-completed-ship.test.sh; the shared
# wake triage lives in tests/fm-watch-triage.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-completed-ship-hold)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# Common watcher knobs: tight poll/grace, no check or heartbeat cadence unless a
# test overrides them, so a test only exercises the path it targets. FM_CREW_STATE_BIN
# points at the case's hermetic fake fm-crew-state.sh (installed by make_case) so the
# absorb-only-when-provably-working triage reads a canned verdict; a test fixes that
# verdict via FM_FAKE_CREW_STATE in its environment before calling watch_bg.
watch_bg() {  # <state> <fakebin> <out> [extra env assignments...]
  local state=$1 fakebin=$2 out=$3
  shift 3
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" "$WATCH" > "$out" &
}

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# Wait until <pid>'s watcher has completed a whole poll cycle, or exited first.
# A fixed wait_live budget only proves the process is still ALIVE: fm-watch.sh
# does bounded startup work (the recovery-marker snapshot, lock acquisition)
# before its first stale scan, so on a loaded
# machine a short fixed budget can reap a round before the cycle it asserts on
# ever ran - and then every "no wake, no marker" assertion passes vacuously
# while every "marker written" assertion fails spuriously.
# The liveness beacon is touched at the TOP of every poll, so this drops any
# beacon left by an earlier round, waits for THIS watcher to write a fresh one
# (some poll's top), then waits for that one to advance (the next poll's top) -
# and the whole cycle in between is what the caller's assertions describe.
# 0 if the watcher is still alive after a completed cycle, 1 if it exited.
wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Portable mtime in epoch seconds. Platform-detected, never the `stat -f || stat -c`
# fallback (which writes a partial filesystem dump on Linux; see fm-watch.sh).
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

test_completed_ship_owner_enters_bounded_wait() {
  local dir state fakebin capture_file out statusf window key pid show
  dir=$(make_case completed-ship-owner); state="$dir/state"; fakebin="$dir/fakebin"
  capture_file="$dir/pane.txt"; out="$dir/watch.out"; statusf="$state/held.status"
  window='test:fm-held'; key='test_fm-held'
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  (cd "$dir" && tasks-axi add held 'Completed branch awaiting approval' --kind ship --repo sample --start >/dev/null) \
    || fail "could not create completed ship fixture"
  printf 'window=%s\nkind=ship\nharness=codex\nbackend=tmux\nmode=local-only\n' "$window" > "$state/held.meta"
  printf 'done: ready in branch fm/held\n' > "$statusf"
  prime_status_seen "$state" "$statusf" || fail "could not mark original completion seen"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-captain-hold.sh" hold held \
    --reason 'Awaiting merge approval' >/dev/null || fail "completed ship hold failed"
  printf 'idle shell after finished worker exit\n' > "$capture_file"
  hash_text 'idle shell after finished worker exit' > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  watch_bg "$state" "$fakebin" "$out" env FM_HOME="$dir" \
    FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_PAUSE_RESURFACE_SECS=999
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "new hold re-woke immediately: $(cat "$out")"; }
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "completed ship never entered declared-wait handling"; }
  printf 'idle shell after harmless pane change\n' > "$capture_file"
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "held pane change caused an immediate wake"; }
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "held pane became a terminal stale wake"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "quiet completed ship queued a wake"; }
  # A new real worker problem is never covered by the already-recorded hold.
  printf 'blocked: new permission prompt\n' >> "$statusf"
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "new worker problem was hidden by the hold"; }
  assert_grep "signal: $statusf" "$state/.wake-queue" "new permission problem did not surface"
  show=$(cd "$dir" && tasks-axi show held --full) || fail "held ship vanished"
  assert_contains "$show" 'held: yes' "watcher lifted merge authority"
  assert_contains "$show" 'state: in_flight' "watcher closed the unmerged ship"
  pass "real completed-ship hold stays quiet after exit and pane change, but a new permission event wakes"
}

test_completed_ship_owner_enters_bounded_wait
