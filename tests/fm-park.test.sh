#!/usr/bin/env bash
# Supervisor park through the command interface: a bounded paused declaration
# plus named steering-record retirement that is not a worker acknowledgement.
# Exit is not invoked; unlisted records and the task's files stay put.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-park)
HOME_DIR="$TMP_ROOT/home"
STATE_DIR="$HOME_DIR/state"
WORK_DIR="$TMP_ROOT/work"
mkdir -p "$STATE_DIR" "$WORK_DIR"
printf 'keep\n' > "$WORK_DIR/keep.txt"
PARK="$ROOT/bin/fm-park.sh"
UNTIL=2099-01-01T00:00:00Z

inbox_lib() {  # <function> [args...]
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" bash -c '
    . "$1"
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$@"
}

reset_task() {  # [kind-line...]
  rm -rf "$STATE_DIR/worker.inbox" "$STATE_DIR/worker.status" "$STATE_DIR/worker.meta"
  printf 'kind=ship\nworktree=%s\n' "$WORK_DIR" > "$STATE_DIR/worker.meta"
  printf 'working: still implementing\n' > "$STATE_DIR/worker.status"
}

run_park() {
  FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" "$PARK" "$@"
}

body_of() {
  inbox_lib fm_task_inbox_body "$1"
}

reset_task
KEEP_SUM=$(cksum "$WORK_DIR/keep.txt")
META_SUM=$(cksum "$STATE_DIR/worker.meta")
rec1=$(inbox_lib fm_task_inbox_write "$STATE_DIR" worker 'steer one')
rec2=$(inbox_lib fm_task_inbox_write "$STATE_DIR" worker 'steer two')
rec3=$(inbox_lib fm_task_inbox_write "$STATE_DIR" worker 'steer three')
[ "${rec1##*/}" = 001.msg ] || fail "first steer was not 001.msg: $rec1"
[ "${rec2##*/}" = 002.msg ] || fail "second steer was not 002.msg: $rec2"
[ "${rec3##*/}" = 003.msg ] || fail "third steer was not 003.msg: $rec3"
saved=$(mktemp "$TMP_ROOT/saved.XXXXXX")
cp "$rec1" "$saved"
out=$(run_park worker --until "$UNTIL" --reason 'upstream release' --retire 001.msg --retire 003.msg) \
  || fail "park refused a pending pair: $out"
assert_contains "$out" 'parked:' "park reports the pause"
assert_contains "$out" 'retired=2' "park retires only the named records"
[ ! -e "$STATE_DIR/worker.inbox/001.msg" ] || fail "named record stayed pending"
[ ! -e "$STATE_DIR/worker.inbox/003.msg" ] || fail "second named record stayed pending"
[ -f "$STATE_DIR/worker.inbox/002.msg" ] || fail "unnamed record was removed"
[ "$(body_of "$STATE_DIR/worker.inbox/002.msg")" = "steer two" ] || fail "unnamed record changed"
[ -f "$STATE_DIR/worker.inbox/retired/001.msg" ] || fail "named record was not kept"
cmp -s "$saved" "$STATE_DIR/worker.inbox/retired/001.msg" || fail "retired record bytes changed"
[ ! -e "$STATE_DIR/worker.inbox/handled/001.msg" ] || fail "retirement was stored as a worker acknowledgement"
[ ! -e "$STATE_DIR/worker.inbox/handled/003.msg" ] || fail "second retirement was stored as a worker acknowledgement"
side="$STATE_DIR/worker.inbox/retired/001.retired"
grep -qx 'schema=fm-task-inbox-retire.v1' "$side" || fail "retirement provenance missing its schema"
grep -qx 'by=supervisor' "$side" || fail "retirement provenance missing supervisor actor"
grep -qx 'not-worker-acknowledgement=1' "$side" || fail "retirement provenance claims a worker read"
grep -qx 'record=001.msg' "$side" || fail "retirement provenance names the wrong record"
line=$(last_status_line "$STATE_DIR/worker.status")
status_is_paused "$line" || fail "park was not a paused declaration: $line"
got=$(status_paused_until "$line") || fail "park pause has no readable until"
want=$(fm_utc_iso_to_epoch "$UNTIL") || fail "fixture until is not readable"
[ "$got" = "$want" ] || fail "park until does not match --until: $got"
[ "$(_fm_decision_key "$line")" = supervisor-park ] || fail "park pause lost its key: $line"
case "$line" in
  *'[by=supervisor]'*) ;;
  *) fail "park pause has no supervisor provenance: $line" ;;
esac
[ "$(cksum "$WORK_DIR/keep.txt")" = "$KEEP_SUM" ] || fail "park changed the worker files"
[ "$(cksum "$STATE_DIR/worker.meta")" = "$META_SUM" ] || fail "park rewrote task metadata"
again=$(run_park worker --until "$UNTIL" --reason 'upstream release' --retire 001.msg 2>&1) && fail "second park retired an already retired record: $again"
assert_contains "$again" 'already retired' "second park names the existing retirement"
[ "$(grep -c '^paused ' "$STATE_DIR/worker.status")" = 1 ] || fail "failed second park appended another pause"
fresh=$(inbox_lib fm_task_inbox_write "$STATE_DIR" worker 'steer four')
[ "${fresh##*/}" = 004.msg ] || fail "retired sequence was reused: ${fresh##*/}"
retry=$(inbox_lib fm_task_inbox_write_idempotent "$STATE_DIR" worker 'steer one')
[ "$retry" = "$STATE_DIR/worker.inbox/retired/001.msg" ] || fail "retry of a retired body created another record: $retry"
[ ! -e "$STATE_DIR/worker.inbox/005.msg" ] || fail "retired-body retry wrote a new pending record"
ring_rc=0
inbox_lib fm_task_inbox_ring nowhere nowhere "$STATE_DIR/worker.inbox/retired/001.msg" || ring_rc=$?
[ "$ring_rc" = 6 ] || fail "ring typed or misclassified a retired record: $ring_rc"
bell=$(inbox_lib fm_task_inbox_doorbell_line "$STATE_DIR/worker.inbox/retired/001.msg")
assert_contains "$bell" "worker.inbox" "retired doorbell must name the inbox"
case "$bell" in
  *"your 'retired'"*) fail "retired doorbell names the retirement directory" ;;
esac
export FM_TASK_INBOX_GRACE_SECS=0
due=$(inbox_lib fm_task_inbox_due_action "$STATE_DIR" worker)
unset FM_TASK_INBOX_GRACE_SECS
case "$due" in
  "ring $STATE_DIR/worker.inbox/002.msg") ;;
  *) fail "due action did not stay on the unnamed record: $due" ;;
esac
case "$due" in
  *retired*) fail "due action selected a retired record: $due" ;;
esac
pass "named records retire with provenance, unnamed records stay, and the pause is bounded"

reset_task
inbox_lib fm_task_inbox_write "$STATE_DIR" worker 'only steer' >/dev/null
before=$(cksum "$STATE_DIR/worker.status")
missing=$(run_park worker --until "$UNTIL" --reason 'upstream release' --retire 001.msg --retire 009.msg 2>&1) && fail "partial retire succeeded: $missing"
[ -f "$STATE_DIR/worker.inbox/001.msg" ] || fail "failed retire removed a record it could not finish"
[ ! -e "$STATE_DIR/worker.inbox/retired/001.msg" ] || fail "failed retire left a moved record behind"
[ "$(cksum "$STATE_DIR/worker.status")" = "$before" ] || fail "failed retire appended a pause"
past=$(run_park worker --until 2000-01-01T00:00:00Z --reason 'upstream release' --retire 001.msg 2>&1) && fail "past until parked: $past"
assert_contains "$past" 'not in the future' "past until explains the refusal"
bad_reason=$(run_park worker --until "$UNTIL" --reason 'wait until 2099-06-01T00:00:00Z' --retire 001.msg 2>&1) && fail "reason smuggled a second until: $bad_reason"
[ -f "$STATE_DIR/worker.inbox/001.msg" ] || fail "refused park moved the record"
mv "$STATE_DIR/worker.inbox/001.msg" "$STATE_DIR/worker.inbox/handled/"
acked=$(run_park worker --until "$UNTIL" --reason 'upstream release' --retire 001.msg 2>&1) && fail "worker acknowledgement was retired: $acked"
assert_contains "$acked" 'acknowledged by the worker' "acknowledged record explains the refusal"
[ -f "$STATE_DIR/worker.inbox/handled/001.msg" ] || fail "refused park took an acknowledged record"
ln -s "$STATE_DIR/worker.inbox/handled/001.msg" "$STATE_DIR/worker.inbox/002.msg"
linked=$(run_park worker --until "$UNTIL" --reason 'upstream release' --retire 002.msg 2>&1) && fail "symlink record was retired: $linked"
[ -L "$STATE_DIR/worker.inbox/002.msg" ] || fail "refused park replaced the symlink"
printf 'done: shipped\n' >> "$STATE_DIR/worker.status"
finished=$(run_park worker --until "$UNTIL" --reason 'upstream release' 2>&1) && fail "finished task was parked: $finished"
assert_contains "$finished" 'already done' "finished task explains the refusal"
printf 'working: still implementing\n' > "$STATE_DIR/worker.status"
printf 'kind=ship\nremote_host=example.test\n' > "$STATE_DIR/worker.meta"
remote=$(run_park worker --until "$UNTIL" --reason 'upstream release' 2>&1) && fail "remote mate was parked: $remote"
assert_contains "$remote" 'remotely placed' "remote refusal names the other host"
pass "refused parks leave records and status unchanged"

reset_task
inbox_lib fm_task_inbox_write "$STATE_DIR" worker 'stays pending' >/dev/null
bare=$(run_park worker --until "$UNTIL" --reason 'no steer to drop') || fail "park without retire refused: $bare"
assert_contains "$bare" 'retired=0' "park without retire drops nothing"
[ -f "$STATE_DIR/worker.inbox/001.msg" ] || fail "park without retire removed a pending record"
[ "$(body_of "$STATE_DIR/worker.inbox/001.msg")" = "stays pending" ] || fail "park without retire changed a pending record"
status_is_paused "$(last_status_line "$STATE_DIR/worker.status")" || fail "park without retire wrote no pause"
pass "a park with no named records retains every pending steer"

reset_task
gate_rc=0
gate=$(env -u FM_GATE_REFUSE_BYPASS NO_MISTAKES_GATE=1 FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE_DIR" \
  "$PARK" worker --until "$UNTIL" --reason 'gate' 2>&1) || gate_rc=$?
[ "$gate_rc" = 3 ] || fail "gate context was not refused: rc=$gate_rc $gate"
[ "$(grep -c '^paused ' "$STATE_DIR/worker.status" || true)" = 0 ] || fail "gate refusal wrote a pause"
nohome_rc=0
nohome=$(env -u FM_HOME "$PARK" worker --until "$UNTIL" --reason 'missing home' 2>&1) || nohome_rc=$?
[ "$nohome_rc" = 2 ] || fail "missing FM_HOME was not a usage error: rc=$nohome_rc $nohome"
badid_rc=0
badid=$(run_park '../worker' --until "$UNTIL" --reason 'bad id' 2>&1) || badid_rc=$?
[ "$badid_rc" = 2 ] || fail "unsafe task id was not a usage error: rc=$badid_rc $badid"
pass "gate context, missing home, and unsafe ids are refused before a pause"
