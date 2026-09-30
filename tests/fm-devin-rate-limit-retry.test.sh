#!/usr/bin/env bash
# tests/fm-devin-rate-limit-retry.test.sh - behavior of the Devin rate-limit
# retry (bin/fm-devin-rate-limit-retry.sh) through its hook interface. A fake
# `devin acp` process owns a session log named after its pid, exactly as Devin
# names its own, and runs the hooks; the test appends synthetic log lines in
# the format Devin writes when a turn stops on the model rate limit, and a
# fake fm-send.sh beside a copy of the script records
# the steer the sentinel sends. Covers the reset parsing, the retry through
# fm-send with its home and state, a Stop or a new prompt superseding a
# scheduled retry, the lines that must not trigger a retry, the consecutive
# cap with its blocked line and the resolved line a later normal Stop writes,
# the home-wide stagger between two workers, the unarmed case, retire, a
# reused pid's stale log, an undelivered retry, a held send lock, a long reset
# that must not delay a shorter one, spacing measured from a slow send's end,
# a superseded retry that leaves nothing behind, a stale log under a non-devin
# ancestor, a capped task whose retry state is retired, a cap detected after
# its turn was retired, a task lock a dead holder left behind, a retire that
# cannot move the state aside, a retire whose state dir is gone, a cap on a
# task with no status file yet, a status line that cannot be written, and a
# retire whose resolved line cannot be written, state an earlier retire left
# under its retiring name by a dead or live pid, a retire after the status log
# is gone, and a retry whose count cannot be recorded.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || {
  printf 'skip - fm-devin-rate-limit-retry: jq not installed\n'
  exit 0
}

TMP_ROOT=$(fm_test_tmproot fm-devin-rate-limit-retry)
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cp "$ROOT/bin/fm-devin-rate-limit-retry.sh" "$ROOT/bin/fm-wake-lib.sh" "$ROOT/bin/fm-path-lib.sh" "$BIN/"
RETRY="$BIN/fm-devin-rate-limit-retry.sh"
cat >"$BIN/fm-send.sh" <<'EOF'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/fail-send" ] || exit 1
[ ! -e "$FM_HOME/slow-send-$1" ] || sleep "$(cat "$FM_HOME/slow-send-$1")"
printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$FM_HOME" "$FM_STATE_OVERRIDE" "$1" "$2" >>"$FM_HOME/sent"
EOF
chmod +x "$BIN/fm-send.sh"
# The fake `devin` process: bash started under the name devin, as the real
# CLI's process is.
ln -s "$(command -v bash)" "$BIN/devin"

cleanup_sentinels() {
  pkill -f "$BIN/fm-devin-rate-limit-retry.sh watch" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_sentinels EXIT

export FM_DEVIN_RETRY_POLL=1 FM_DEVIN_RETRY_BACKOFF=1 FM_DEVIN_RETRY_JITTER=0 \
  FM_DEVIN_RETRY_SPACING=0 FM_DEVIN_RETRY_MAX=4

RATE_LIMIT_WARN='2026-09-24T19:40:44.203793Z  WARN affogato::agent::control_loop: attempt=2 max=3 error=Inference(ServerError(message=Reached free model rate limit. Upgrade to Max for higher limits, or switch to a different model. Your limit will reset in 1 second. (trace ID: fm-test-trace-1))) Transient inference error; retrying on next iteration'

# rate_limit_line <reset-text>: the line that ends a rate-limited turn.
rate_limit_line() {
  printf '%s\n' "2026-09-24T19:40:44.366855Z  WARN run_acp_server: agent_client_protocol::jsonrpc::outgoing_actor: Sending error response id=Str(\"00000000-0000-4000-8000-000000000001\") method=session/prompt error=Error { code: -32010: Unknown error, message: \"Reached free model rate limit. Upgrade to Max for higher limits, or switch to a different model. Your limit will reset in $1. (trace ID: fm-test-trace-2)\", data: Some(Object {\"cognition.ai/errorKind\": String(\"unavailable\"), \"cognition.ai/retryable\": Bool(true)}) }"
}

CONNECTION_ERROR_LINE='2026-09-25T03:38:41.394254Z  WARN run_acp_server: agent_client_protocol::jsonrpc::outgoing_actor: Sending error response id=Str("00000000-0000-4000-8000-000000000002") method=session/prompt error=Error { code: -32010: Unknown error, message: "Connection error, send a message to continue retrying", data: Some(Object {"cognition.ai/errorKind": String("unavailable"), "cognition.ai/retryable": Bool(true)}) }'

# new_home <name>: a home with a state dir and one status file per task.
new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/logs"
  printf '%s\n' "$home"
}

# fake_devin <home> <task> <event...>: runs each hook event from one devin
# process that owns devin_test_<pid>.log in the home's log dir, the way the
# real CLI runs hooks; prints the log path. With FM_TEST_STALE_LOG=1, an older
# devin_aaa_<pid>.log from an earlier process with the same pid sorts first.
# With FM_TEST_SHELL_LOG=1, each hook runs under an intermediate shell whose
# reused pid owns a stale devin_zzz_<pid>.log.
fake_devin() {
  local home=$1 task=$2
  shift 2
  # shellcheck disable=SC2016 # The fake devin is bash; its -c script expands its own arguments.
  FM_DEVIN_RETRY_LOG_DIR="$home/logs" "$BIN/devin" -c '
    [ "${FM_TEST_STALE_LOG:-}" != 1 ] || {
      printf "old session\n" >"$1/logs/devin_aaa_$$.log"
      touch -t 202001010000 "$1/logs/devin_aaa_$$.log"
    }
    log="$1/logs/devin_test_$$.log"
    printf "session start\n" >>"$log"
    printf "%s\n" "$log"
    home=$1 task=$2 retry=$3
    shift 3
    for event in "$@"; do
      if [ "${FM_TEST_SHELL_LOG:-}" = 1 ]; then
        printf "{}" | bash -c "printf \"old\\n\" >\"\$1/logs/devin_zzz_\$\$.log\"; \"\$2\" \"\$3\" \"\$1/state\" \"\$4\" \"\$1\"; :" _ "$home" "$retry" "$event" "$task"
      else
        printf "{\"hook_event_name\":\"x\",\"session_id\":\"s1\"}" | "$retry" "$event" "$home/state" "$task" "$home"
      fi
    done' _ "$home" "$task" "$RETRY" "$@"
}

# hook <home> <task> <event>: one hook call from a process with no session log.
hook() {
  printf '{"session_id":"s1"}' | FM_DEVIN_RETRY_LOG_DIR="$1/logs" "$RETRY" "$3" "$1/state" "$2" "$1"
}

# wait_for <seconds> <description> <command...>
wait_for() {
  local limit=$1 what=$2 _
  shift 2
  for _ in $(seq 1 $((limit * 5))); do
    "$@" && return 0
    sleep 0.2
  done
  fail "timed out after ${limit}s waiting for $what"
}

sent_count() { if [ -f "$1/sent" ]; then wc -l <"$1/sent" | tr -d ' '; else printf 0; fi; }
has_event() { grep -q "\"event\":\"$2\"" "$1/state/devin-rate-limit-log.jsonl" 2>/dev/null; }
sent_at_least() { [ "$(sent_count "$1")" -ge "$2" ]; }
# hold_lock <state-dir> <lock> <script>: takes <lock> through the retry's own
# lock library in a background process that then runs <script>; sets HOLDER to
# its pid. The trailing `:` keeps bash from exec-ing the script in its place,
# which would change the lock owner's identity.
hold_lock() {
  FM_STATE_OVERRIDE=$1 bash -c '. "$1/fm-wake-lib.sh"; fm_lock_try_acquire "$2" || exit 1; eval "$3"; :' _ "$BIN" "$2" "$3" >/dev/null 2>&1 &
  HOLDER=$!
}
lock_present() { [ -L "$1" ] || [ -e "$1" ]; }
detected_at_least() { [ "$(grep -c '"event":"detected"' "$1/state/devin-rate-limit-log.jsonl" 2>/dev/null)" -ge "$2" ]; }

# 1. A turn-ending rate-limit error sends one retry through fm-send after the
# stated reset, with this home and state and the task id.
H=$(new_home retry)
: >"$H/state/t1.status"
LOG=$(fake_devin "$H" t1 arm)
printf '%s\n' "$RATE_LIMIT_WARN" >>"$LOG"
rate_limit_line "1 second" >>"$LOG"
wait_for 15 "the retry send" sent_at_least "$H" 1
IFS='|' read -r _ sent_home sent_state sent_task sent_text <"$H/sent"
assert_equals "$H" "$sent_home" "the retry must steer through this home"
assert_equals "$H/state" "$sent_state" "the retry must name this home's state dir"
assert_equals t1 "$sent_task" "the retry must target the rate-limited task"
assert_contains "$sent_text" "rate limit" "the retry message must say why it was sent"
assert_equals 1 "$(cat "$H/state/t1.devin-retry/count")" "one retry must be counted"
has_event "$H" detected || fail "the detection must be logged"
assert_grep '"detail":"reset 1s; retry 1 of 4' "$H/state/devin-rate-limit-log.jsonl" "the detection must record the parsed reset"
wait_for 5 "the retried event" has_event "$H" retried
assert_no_grep 'blocked' "$H/state/t1.status" "a retry under the cap must not write a status line"
pass "a turn-ending rate-limit error sends one retry through fm-send"

# 2. A normal Stop resets the consecutive count.
fake_devin "$H" t1 arm stop >/dev/null
assert_absent "$H/state/t1.devin-retry/count" "a normal Stop must reset the retry count"
pass "a normal Stop resets the consecutive retry count"

# 3. Minute resets parse, and a Stop before the retry is due supersedes it.
H=$(new_home superseded)
: >"$H/state/t1.status"
LOG=$(fake_devin "$H" t1 arm)
rate_limit_line "3 minutes" >>"$LOG"
wait_for 10 "the detection" has_event "$H" detected
assert_grep '"detail":"reset 180s;' "$H/state/devin-rate-limit-log.jsonl" "a minute reset must parse to seconds"
hook "$H" t1 stop
wait_for 10 "the superseded event" has_event "$H" superseded
assert_equals 0 "$(sent_count "$H")" "a Stop before the retry is due must cancel it"
pass "a stated minute reset parses, and a Stop before the retry cancels it"

# 4. A new prompt supersedes the sentinel of the turn before it.
H=$(new_home newprompt)
LOG=$(fake_devin "$H" t1 arm)
rate_limit_line "2 seconds" >>"$LOG"
wait_for 10 "the detection" has_event "$H" detected
hook "$H" t1 arm
wait_for 10 "the superseded event" has_event "$H" superseded
assert_equals 0 "$(sent_count "$H")" "a new prompt must cancel the previous turn's retry"
pass "a new prompt cancels the previous turn's scheduled retry"

# 5. A transient in-turn rate-limit warning and a connection error that ends
# the turn trigger nothing.
H=$(new_home ignored)
LOG=$(fake_devin "$H" t1 arm)
printf '%s\n%s\n' "$RATE_LIMIT_WARN" "$CONNECTION_ERROR_LINE" >>"$LOG"
sleep 3
assert_equals 0 "$(sent_count "$H")" "only a turn-ending rate-limit error may trigger a retry"
! has_event "$H" detected || fail "a non-rate-limit error must not be detected"
hook "$H" t1 stop
pass "transient warnings and other turn-ending errors trigger no retry"

# 6. The cap: once MAX consecutive retries were sent, the next rate limit sends
# nothing and writes one blocked line; a later normal Stop resolves it.
H=$(new_home cap)
: >"$H/state/t1.status"
LOG=$(FM_DEVIN_RETRY_MAX=1 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 15 "the first retry" sent_at_least "$H" 1
wait_for 5 "the retried event" has_event "$H" retried
LOG=$(FM_DEVIN_RETRY_MAX=1 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 10 "the capped event" has_event "$H" capped
assert_equals 1 "$(sent_count "$H")" "the cap must stop further retries"
assert_equals 1 "$(grep -c '^blocked \[at=[0-9]*\] \[key=devin-rate-limit\]: ' "$H/state/t1.status")" "the cap must write exactly one keyed blocked line"
hook "$H" t1 stop
assert_equals 1 "$(grep -c '^resolved \[at=[0-9]*\] \[key=devin-rate-limit\]: ' "$H/state/t1.status")" "a normal Stop after the cap must resolve its key"
hook "$H" t1 stop
assert_equals 1 "$(grep -c '^resolved ' "$H/state/t1.status")" "a second Stop must not resolve again"
pass "the consecutive cap writes one blocked line, and a normal Stop resolves it"

# 7. Two workers in one home that hit the limit together retry apart.
H=$(new_home stagger)
LOG1=$(FM_DEVIN_RETRY_SPACING=3 fake_devin "$H" t1 arm)
LOG2=$(FM_DEVIN_RETRY_SPACING=3 fake_devin "$H" t2 arm)
rate_limit_line "1 second" >>"$LOG1"
rate_limit_line "1 second" >>"$LOG2"
wait_for 20 "both retries" sent_at_least "$H" 2
first=$(cut -d'|' -f1 "$H/sent" | sort -n | head -1)
last=$(cut -d'|' -f1 "$H/sent" | sort -n | tail -1)
[ $((last - first)) -ge 3 ] || fail "two workers' retries must be spaced by the home's spacing (got $((last - first))s)"
assert_equals "t1 t2" "$(cut -d'|' -f4 "$H/sent" | sort | tr '\n' ' ' | sed 's/ $//')" "each worker must get its own retry"
pass "two workers that hit the limit together retry at least the spacing apart"

# 8. A hook with no Devin session log in its ancestry arms nothing.
H=$(new_home unarmed)
hook "$H" t1 arm
has_event "$H" unarmed || fail "a turn without a session log must be logged as unarmed"
pass "a hook without a session log in its ancestry arms no sentinel"

# 9. Retire removes the task's retry state and ends its sentinel.
H=$(new_home retire)
LOG=$(fake_devin "$H" t1 arm)
"$RETRY" retire "$H/state" t1 - </dev/null
assert_absent "$H/state/t1.devin-retry" "retire must remove the task's retry state"
rate_limit_line "1 second" >>"$LOG"
sleep 3
assert_equals 0 "$(sent_count "$H")" "a retired task must get no retry"
pass "retire removes the retry state and its sentinel sends nothing"

# 10. A reused pid's older log is skipped for the live session's newer one.
H=$(new_home reused-pid)
LOG=$(FM_TEST_STALE_LOG=1 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 15 "the retry send" sent_at_least "$H" 1
pass "a reused pid's older session log does not hide the live one"

# 11. A retry fm-send could not deliver is not counted and raises the keyed
# blocked line, which the turn's next normal Stop resolves.
H=$(new_home send-fails)
: >"$H/fail-send"
LOG=$(fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 15 "the failed event" has_event "$H" failed
assert_absent "$H/state/t1.devin-retry/count" "an undelivered retry must not count toward the cap"
wait_for 5 "the blocked line" grep -q '^blocked \[at=[0-9]*\] \[key=devin-rate-limit\]: .*could not be sent' "$H/state/t1.status"
hook "$H" t1 stop
assert_equals 1 "$(grep -c '^resolved \[at=[0-9]*\] \[key=devin-rate-limit\]: ' "$H/state/t1.status")" "a normal Stop must resolve the undelivered retry's blocker"
pass "an undelivered retry is not counted and raises a blocker a normal Stop resolves"

# 12. A send lock held by a live holder throughout leaves the last-send record
# and the lock alone, and the retry still goes out on its own time.
H=$(new_home lock-held)
printf '%s\n' 1000000000 >"$H/state/devin-rate-limit-last-send"
hold_lock "$H/state" "$H/state/devin-rate-limit-last-send.lock" 'sleep 40'
toucher=$HOLDER
wait_for 5 "the held send lock" lock_present "$H/state/devin-rate-limit-last-send.lock"
LOG=$(FM_DEVIN_RETRY_SPACING=30 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 25 "the retry send" sent_at_least "$H" 1
wait_for 20 "the retried event" has_event "$H" retried
kill "$toucher" 2>/dev/null || true
wait "$toucher" 2>/dev/null || true
wait_for 20 "the retried event" has_event "$H" retried
has_event "$H" unstaggered || fail "a held send lock must be logged as unstaggered"
assert_equals 1000000000 "$(cat "$H/state/devin-rate-limit-last-send")" "a sender without the lock must not rewrite the last-send record"
lock_present "$H/state/devin-rate-limit-last-send.lock" || fail "a sender without the lock must not remove it"
pass "a send lock held throughout leaves the record alone and the retry unstaggered"

# 13. A longer reset detected first does not delay another worker's shorter
# one, because spacing is taken only when a retry is due.
H=$(new_home long-first)
LOG1=$(FM_DEVIN_RETRY_SPACING=5 fake_devin "$H" t1 arm)
rate_limit_line "1 hour" >>"$LOG1"
wait_for 10 "the long reset's detection" has_event "$H" detected
LOG2=$(FM_DEVIN_RETRY_SPACING=5 fake_devin "$H" t2 arm)
rate_limit_line "1 second" >>"$LOG2"
wait_for 15 "the short reset's retry" sent_at_least "$H" 1
assert_equals t2 "$(cut -d'|' -f4 "$H/sent")" "only the short reset's worker may have retried"
hook "$H" t1 stop
wait_for 10 "the long reset's superseded event" has_event "$H" superseded
pass "a longer reset detected first does not delay another worker's shorter one"

# 14. Spacing counts from when a slow send finished, not from when it was due.
H=$(new_home slow-send)
printf '4\n' >"$H/slow-send-t1"
LOG1=$(FM_DEVIN_RETRY_SPACING=2 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG1"
wait_for 10 "the first retry's start" test -s "$H/state/devin-rate-limit-last-send"
LOG2=$(FM_DEVIN_RETRY_SPACING=2 fake_devin "$H" t2 arm)
rate_limit_line "1 second" >>"$LOG2"
wait_for 25 "both retries" sent_at_least "$H" 2
t1_done=$(grep '|t1|' "$H/sent" | cut -d'|' -f1)
t2_sent=$(grep '|t2|' "$H/sent" | cut -d'|' -f1)
[ $((t2_sent - t1_done)) -ge 2 ] || fail "the next retry must wait the spacing after a slow send finished (got $((t2_sent - t1_done))s)"
pass "spacing counts from when a slow send finished"

# 15. A retry superseded while it waits for its spacing leaves nothing behind
# that delays another worker.
H=$(new_home superseded-wait)
LOG1=$(FM_DEVIN_RETRY_SPACING=6 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG1"
wait_for 15 "the first retry" sent_at_least "$H" 1
LOG2=$(FM_DEVIN_RETRY_SPACING=6 fake_devin "$H" t2 arm)
rate_limit_line "1 second" >>"$LOG2"
wait_for 10 "the second detection" detected_at_least "$H" 2
record=$(cat "$H/state/devin-rate-limit-last-send")
hook "$H" t2 stop
wait_for 15 "the superseded event" has_event "$H" superseded
assert_equals "$record" "$(cat "$H/state/devin-rate-limit-last-send")" "a superseded retry must not move the last-send record"
pass "a retry superseded while waiting for its spacing records nothing"

# 16. A reused pid's log under an intermediate, non-devin ancestor is skipped
# for the devin process's own log.
H=$(new_home shell-log)
LOG=$(FM_TEST_SHELL_LOG=1 fake_devin "$H" t1 arm)
ls "$H"/logs/devin_zzz_*.log >/dev/null 2>&1 || fail "the intermediate shell's stale log must exist for this case to mean anything"
rate_limit_line "1 second" >>"$LOG"
wait_for 15 "the retry send" sent_at_least "$H" 1
pass "a stale log under a non-devin ancestor does not hide the devin process's log"

# 17. Retiring a capped task's retry state, as a relaunch or teardown does,
# resolves its blocked line.
H=$(new_home cap-retire)
: >"$H/state/t1.status"
LOG=$(FM_DEVIN_RETRY_MAX=0 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 10 "the capped event" has_event "$H" capped
"$RETRY" retire "$H/state" t1 - </dev/null
assert_equals 1 "$(grep -c '^resolved \[at=[0-9]*\] \[key=devin-rate-limit\]: ' "$H/state/t1.status")" "retiring a capped task must resolve its key"
assert_absent "$H/state/t1.devin-retry" "retire must still remove the task's retry state"
pass "retiring a capped task's retry state resolves its blocked line"

# 18. A cap detected after its turn was retired publishes nothing: the
# sentinel revalidates its turn under the lock Stop and retire take.
H=$(new_home cap-after-stop)
: >"$H/state/t1.status"
LOG=$(FM_DEVIN_RETRY_MAX=0 fake_devin "$H" t1 arm)
hold_lock "$H/state" "$H/state/t1.devin-retry/.lock" "sleep 3; printf 'ended.1\\n' >'$H/state/t1.devin-retry/turn'; fm_lock_release '$H/state/t1.devin-retry/.lock'"
holder=$HOLDER
wait_for 5 "the held task lock" lock_present "$H/state/t1.devin-retry/.lock"
rate_limit_line "1 second" >>"$LOG"
wait "$holder" || fail "the lock holder must retire the turn and release"
sleep 3
assert_no_grep 'blocked' "$H/state/t1.status" "a cap for a retired turn must not write a blocked line"
! has_event "$H" capped || fail "a cap for a retired turn must not be logged as capped"
pass "a cap detected after its turn was retired publishes nothing"

# 19. A task lock a dead holder left behind is broken within the wait, so the
# cap is still published.
H=$(new_home dead-lock)
: >"$H/state/t1.status"
LOG=$(FM_DEVIN_RETRY_MAX=0 fake_devin "$H" t1 arm)
hold_lock "$H/state" "$H/state/t1.devin-retry/.lock" ':'
holder=$HOLDER
wait "$holder" || fail "the lock holder must take the lock before it dies"
lock_present "$H/state/t1.devin-retry/.lock" || fail "the dead holder must leave its lock behind"
rate_limit_line "1 second" >>"$LOG"
wait_for 15 "the capped event" has_event "$H" capped
assert_equals 1 "$(grep -c '^blocked \[at=[0-9]*\] \[key=devin-rate-limit\]: ' "$H/state/t1.status")" "a dead holder's lock must not stop the cap"
hook "$H" t1 stop
pass "a task lock a dead holder left behind does not stop the cap"

# 20. A retire that cannot move the task's retry state aside reports it, so a
# relaunch does not proceed past a sentinel it could not retire, and leaves a
# capped task's blocker open with its marker for the next retire.
H=$(new_home retire-fails)
: >"$H/state/t1.status"
hook "$H" t1 arm
: >"$H/state/t1.devin-retry/capped"
chmod a-w "$H/state"
if "$RETRY" retire "$H/state" t1 - </dev/null; then
  retire_rc=0
else
  retire_rc=$?
fi
chmod u+w "$H/state"
if [ -e "$H/state/t1.devin-retry" ]; then
  assert_equals 1 "$retire_rc" "a retire that left the state in place must exit 1"
  assert_no_grep 'resolved' "$H/state/t1.status" "a retire that left the state in place must not resolve the cap"
  [ -e "$H/state/t1.devin-retry/capped" ] || fail "a retire that left the state in place must keep the cap marker"
  "$RETRY" retire "$H/state" t1 - </dev/null || fail "a retire once the state dir is writable again must succeed"
  assert_absent "$H/state/t1.devin-retry" "the retire that succeeds must remove the state"
  assert_equals 1 "$(grep -c '^resolved ' "$H/state/t1.status")" "the retire that succeeds must resolve the cap"
  pass "a retire that cannot move the retry state aside exits 1 and keeps the blocker for the next retire"
else
  pass "a retire that cannot move the retry state aside exits 1 (skipped: this user can write read-only directories)"
fi

# 21. Retiring a task whose state dir is gone creates nothing, so teardown of
# a home being removed cannot bring its state dir back.
gone="$TMP_ROOT/gone-home/state"
"$RETRY" retire "$gone" t1 - </dev/null || fail "retiring an absent task must succeed"
assert_absent "$TMP_ROOT/gone-home" "retiring an absent task must not create its state dir"
pass "retiring a task whose state dir is gone creates nothing"

# 22. A cap on a task with no status file yet creates it, so the blocked line
# is never dropped.
H=$(new_home no-status)
LOG=$(FM_DEVIN_RETRY_MAX=0 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
wait_for 10 "the capped event" has_event "$H" capped
assert_equals 1 "$(grep -c '^blocked \[at=[0-9]*\] \[key=devin-rate-limit\]: ' "$H/state/t1.status" 2>/dev/null)" "the cap must create the status file with its blocked line"
hook "$H" t1 stop
pass "a cap on a task with no status file yet creates it"

# 23. A status line that cannot be written keeps the state it would change: a
# cap with an unwritable status file records no marker, and a Stop that cannot
# write its resolved line keeps the marker for the next Stop.
H=$(new_home status-unwritable)
: >"$H/state/t1.status"
chmod a-w "$H/state/t1.status"
LOG=$(FM_DEVIN_RETRY_MAX=0 fake_devin "$H" t1 arm)
rate_limit_line "1 second" >>"$LOG"
if printf 'probe\n' 2>/dev/null >>"$H/state/t1.status"; then
  chmod u+w "$H/state/t1.status"
  hook "$H" t1 stop
  pass "a status line that cannot be written keeps its state (skipped: this user can write read-only files)"
else
  wait_for 10 "the failed append" has_event "$H" failed
  assert_absent "$H/state/t1.devin-retry/capped" "a blocked line that was not written must leave no marker"
  chmod u+w "$H/state/t1.status"
  : >"$H/state/t1.devin-retry/capped"
  chmod a-w "$H/state/t1.status"
  hook "$H" t1 stop
  [ -e "$H/state/t1.devin-retry/capped" ] || fail "a Stop that could not write its resolved line must keep the marker"
  chmod u+w "$H/state/t1.status"
  hook "$H" t1 stop
  assert_absent "$H/state/t1.devin-retry/capped" "the next Stop that writes its resolved line must clear the marker"
  assert_equals 1 "$(grep -c '^resolved ' "$H/state/t1.status")" "the next Stop must resolve the blocker"
  pass "a status line that cannot be written keeps the state it would change"
fi

# 24. A retire whose resolved line cannot be written puts the state back with
# its marker and exits 1, and the next retire resolves it.
H=$(new_home retire-resolve-fails)
: >"$H/state/t1.status"
hook "$H" t1 arm
: >"$H/state/t1.devin-retry/capped"
chmod a-w "$H/state/t1.status"
if printf 'probe\n' 2>/dev/null >>"$H/state/t1.status"; then
  chmod u+w "$H/state/t1.status"
  pass "a retire whose resolved line cannot be written keeps the blocker (skipped: this user can write read-only files)"
else
  if "$RETRY" retire "$H/state" t1 - </dev/null; then fail "a retire that could not resolve must exit 1"; fi
  [ -e "$H/state/t1.devin-retry/capped" ] || fail "a retire that could not resolve must put the state back with its marker"
  chmod u+w "$H/state/t1.status"
  "$RETRY" retire "$H/state" t1 - </dev/null || fail "the next retire must succeed"
  assert_equals 1 "$(grep -c '^resolved ' "$H/state/t1.status")" "the next retire must resolve the cap"
  assert_absent "$H/state/t1.devin-retry" "the next retire must remove the state"
  pass "a retire whose resolved line cannot be written keeps the blocker for the next retire"
fi

# 25. State an earlier retire left under its retiring name, by a process that
# is gone, is brought back and resolved by the next retire.
H=$(new_home retiring-left)
: >"$H/state/t1.status"
mkdir -p "$H/state/t1.devin-retry.retiring.999999"
: >"$H/state/t1.devin-retry.retiring.999999/capped"
"$RETRY" retire "$H/state" t1 - </dev/null || fail "a retire that recovers left-behind state must succeed"
assert_equals 1 "$(grep -c '^resolved ' "$H/state/t1.status")" "left-behind capped state must be resolved"
assert_absent "$H/state/t1.devin-retry.retiring.999999" "left-behind state must be removed"
assert_absent "$H/state/t1.devin-retry" "the recovered state must be retired"
pass "state left under a retiring name is recovered and resolved by the next retire"

# 26. Retiring state under a live pid's name - a retire still running, or a
# reused pid - fails the retire rather than treating absence as success.
H=$(new_home retiring-live)
mkdir -p "$H/state/t1.devin-retry.retiring.$$"
: >"$H/state/t1.devin-retry.retiring.$$/capped"
if "$RETRY" retire "$H/state" t1 - </dev/null; then fail "a retire must not succeed past retiring state under a live pid"; fi
[ -e "$H/state/t1.devin-retry.retiring.$$/capped" ] || fail "retiring state under a live pid must be left alone"
pass "retiring state under a live pid fails the retire"

# 27. A retire after teardown already retired the status log resolves nothing
# and creates no orphan status log.
H=$(new_home retire-no-status)
hook "$H" t1 arm
: >"$H/state/t1.devin-retry/capped"
"$RETRY" retire "$H/state" t1 - </dev/null || fail "a retire without a status log must succeed"
assert_absent "$H/state/t1.status" "a retire without a status log must not create one"
assert_absent "$H/state/t1.devin-retry" "a retire without a status log must still remove the state"
pass "a retire after the status log is gone creates no orphan status log"

# 28. A retry whose count cannot be recorded is not sent and raises the keyed
# blocked line, so retries can never outrun the cap.
H=$(new_home count-unwritable)
: >"$H/state/t1.status"
LOG=$(fake_devin "$H" t1 arm)
mkdir "$H/state/t1.devin-retry/count"
chmod a-w "$H/state/t1.devin-retry/count"
rate_limit_line "1 second" >>"$LOG"
if [ -w "$H/state/t1.devin-retry/count" ]; then
  chmod u+w "$H/state/t1.devin-retry/count"
  hook "$H" t1 stop
  pass "a retry whose count cannot be recorded is not sent (skipped: this user can write read-only directories)"
else
  wait_for 15 "the blocked line" grep -q '^blocked \[at=[0-9]*\] \[key=devin-rate-limit\]: .*could not be recorded' "$H/state/t1.status"
  assert_equals 0 "$(sent_count "$H")" "a retry whose count cannot be recorded must not be sent"
  chmod u+w "$H/state/t1.devin-retry/count"
  hook "$H" t1 stop
  pass "a retry whose count cannot be recorded is not sent and raises the blocker"
fi
