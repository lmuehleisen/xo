#!/usr/bin/env bash
# Hourly provider retries through the command interface, without vendor output
# matching or a live harness. Existing watcher/daemon timed-pause tests own wakes.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-rate-limit-retry-tests)
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home/state"
cp "$ROOT/bin/"*.sh "$TMP_ROOT/bin/"
cat > "$TMP_ROOT/bin/fm-send.sh" <<'SEND'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/sends"
[ "${FM_TEST_SEND_FAIL:-0}" = 0 ]
SEND
chmod +x "$TMP_ROOT/bin/fm-send.sh"
STATE_TEST="$TMP_ROOT/home/state"
printf 'kind=ship\n' > "$STATE_TEST/worker.meta"
printf 'working: implementation\n' > "$STATE_TEST/worker.status"
run_retry() { FM_HOME="$TMP_ROOT/home" FM_STATE_OVERRIDE="$STATE_TEST" "$TMP_ROOT/bin/fm-rate-limit-retry.sh" worker; }

out=$(run_retry) || fail "initial schedule refused"
assert_contains "$out" 'scheduled:' "first observation registers one timed pause"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"
line=$(last_status_line "$STATE_TEST/worker.status")
status_is_paused "$line" || fail "rate limit was not declared paused"
until=$(status_paused_until "$line") || fail "pause has no portable clearing time"
remaining=$(( until - $(date +%s) ))
[ "$remaining" -gt 3590 ] && [ "$remaining" -le 3600 ] || fail "default cadence is not hourly: $remaining"
size=$(wc -c < "$STATE_TEST/worker.status")
out=$(run_retry) || fail "duplicate observation refused"
assert_contains "$out" 'waiting:' "known cause quietly waits"
[ "$size" = "$(wc -c < "$STATE_TEST/worker.status")" ] || fail "repeat limit observation appended another status"
[ ! -e "$TMP_ROOT/home/sends" ] || fail "retry sent before interval"
pass "known provider limit schedules an hourly recheck without repeated statuses or early retries"

printf 'paused [at=1] [key=provider-rate-limit]: provider rate limit until 2000-01-01T00:00:00Z\n' >> "$STATE_TEST/worker.status"
# The away posture changes no permissions or provider in this command.
printf 'mode=away\n' > "$STATE_TEST/.afk-contract"
out=$(run_retry) || fail "due away retry refused"
assert_contains "$out" 'retried:' "due retry resumes in away posture"
[ "$(wc -l < "$TMP_ROOT/home/sends" | tr -d ' ')" = 1 ] || fail "due retry did not send exactly once"
assert_contains "$(cat "$TMP_ROOT/home/sends")" 'same model and provider' "retry never switches provider"
assert_contains "$(cat "$TMP_ROOT/home/sends")" '--fire-and-forget' "known wait cannot enter the inbox escalation ladder"
run_retry >/dev/null || fail "post-retry observation refused"
[ "$(wc -l < "$TMP_ROOT/home/sends" | tr -d ' ')" = 1 ] || fail "replay duplicated resume attempt"
pass "due away retry sends once and resets hourly spacing"

printf 'done: ready\n' >> "$STATE_TEST/worker.status"
run_retry >/dev/null 2>&1 && fail "finished task was paused over"
printf 'needs-decision [key=choice]: choose\n' >> "$STATE_TEST/worker.status"
run_retry >/dev/null 2>&1 && fail "decision was paused over"
printf 'kind=secondmate\n' > "$STATE_TEST/worker.meta"
run_retry >/dev/null 2>&1 && fail "secondmate got worker retry"
printf 'kind=ship\nharness=devin\n' > "$STATE_TEST/worker.meta"
run_retry >/dev/null 2>&1 && fail "Devin acquired a competing retry schedule"
FM_RATE_LIMIT_RETRY_SECS=00 run_retry >/dev/null 2>&1 && fail "zero retry interval accepted"
pass "new outcomes, secondmates, Devin, and invalid spacing cannot acquire a retry pause"

printf 'kind=scout\n' > "$STATE_TEST/worker.meta"
printf 'paused [at=1] [key=provider-rate-limit]: provider rate limit until 2000-01-01T00:00:00Z\n' > "$STATE_TEST/worker.status"
out=$(FM_TEST_SEND_FAIL=1 run_retry 2>&1) && fail "delivery failure passed silently"
assert_contains "$out" 'resume steer failed' "retry failure is actionable"
run_retry >/dev/null || fail "failed attempt lost spacing"
[ "$(wc -l < "$TMP_ROOT/home/sends" | tr -d ' ')" = 2 ] || fail "failed attempt was duplicated immediately"
pass "failed delivery surfaces and retains spacing for inspection"

# Drive the away daemon's existing timed-pause consumer with the command's
# actual status format, then advance its clock without waiting a real hour.
(
  dir=$(make_supercase provider-retry-wake)
  state="$dir/state"
  window=test:fm-worker
  printf 'idle prompt $\n' > "$dir/pane.txt"
  fm_write_meta "$state/worker.meta" "window=$window" "kind=ship" "harness=opencode"
  printf 'working: implementation\n' > "$state/worker.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$TMP_ROOT/bin/fm-rate-limit-retry.sh" worker >/dev/null \
    || fail "away wake schedule refused"
  retry_at=$(status_paused_until "$(last_status_line "$state/worker.status")") || fail "retry timestamp unreadable"
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  test_clock=$(( retry_at - 30 ))
  _now() { printf '%s' "$test_clock"; }
  tick() {
    PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
      FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
      FM_ESCALATE_BATCH_SECS=999999 FM_HEARTBEAT_SCAN_SECS=999999 housekeeping "$state"
  }
  tick
  [ ! -s "$state/.subsuper-escalations" ] || fail "provider pause woke before its retry"
  test_clock=$(( retry_at + 1 ))
  tick
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" = 1 ] || fail "hourly retry produced no away recheck"
  tick
  [ "$(wc -l < "$state/.subsuper-escalations" | tr -d ' ')" = 1 ] || fail "same provider retry repeatedly escalated"
  pass "generated hourly pause triggers exactly one due away recheck"
) || exit 1
