#!/usr/bin/env bash
# tests/fm-approved-publish.test.sh - a task's prepared publication runs only
# under the captain's recorded approval of exactly that procedure, and its
# publication blocks are always restored (bin/fm-approved-publish.sh, reading
# the approval through bin/fm-captain-hold.sh decision).
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-approved-publish)
TASKS_AXI_BIN=$(command -v tasks-axi || true)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  fm_test_tasks_toml "$home/.tasks.toml"
  cat > "$home/data/backlog.md" <<'MD'
## In flight

## Queued

## Done
MD
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

run_publish() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-approved-publish.sh" "$@"
}

# A procedure that records every step it runs in data/<task>/trace and prints
# its covered `message` file. Marker files in data/<task>, outside the digest
# the way a real publisher's state is, make a step print text, rewrite the
# live message, signal the runner, hang, leave a child holding its output,
# leave a detached child running, or fail. A later step records any detached
# child still alive when it starts.
write_procedure() {  # <home> <task>
  local dir="$1/data/$2/publish"
  mkdir -p "$dir"
  cat > "$dir/procedure" <<'SH'
#!/usr/bin/env bash
# Stand-in publisher: never pass --yes to anything here.
d=$FM_PUBLISH_DATA
printf '%s\n' "$1" >> "$d/trace"
if [ -s "$d/detach-pid" ] && kill -0 "$(cat "$d/detach-pid")" 2>/dev/null; then
  printf 'survivor-during-%s\n' "$1" >> "$d/trace"
fi
[ ! -e "$d/say-$1" ] || cat "$d/say-$1"
[ ! -e "$d/edit-$1" ] || cp "$d/edit-$1" "$d/publish/message"
printf 'message: %s\n' "$(cat message)"
if [ -e "$d/signal-$1" ]; then
  kill -TERM "$PPID"
  sleep 1
fi
if [ -e "$d/hang-$1" ]; then
  printf '%s\n' "$$" > "$d/hang-pid"
  sleep 30
  : > "$d/late-write"
fi
if [ -e "$d/orphan-$1" ]; then
  ( sleep 30; : > "$d/late-write" ) &
  printf '%s\n' "$!" > "$d/orphan-pid"
fi
if [ -e "$d/detach-$1" ]; then
  sleep 30 </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$d/detach-pid"
fi
[ ! -e "$d/fail-$1" ] || exit 1
exit 0
SH
  chmod +x "$dir/procedure"
  printf '%s\n' 'approved text' > "$dir/message"
  printf '%s\n' '# no-mistakes parks findings at a gate' '^[[:space:]]*gate:' > "$dir/stop-patterns"
}

# Ask the captain with the procedure's approval line and record the answer.
record_answer() {  # <home> <approval-task> <decision-text> [--release]
  local home=$1 id=$2 text=$3
  shift 3
  run_captain "$home" hold "$id" --title "Approve publication" \
    --reason "Approve the prepared publication?" --repo sample >/dev/null \
    || fail "could not hold $id for the captain"
  printf '%s\n' "$text" > "$home/$id.decision"
  run_captain "$home" answer "$id" --decision-file "$home/$id.decision" "$@" >/dev/null \
    || fail "could not record the captain's answer on $id"
}

approve() {  # <home> <task> <approval-task> [--release]
  local home=$1 task=$2 id=$3 line
  shift 3
  line=$(run_publish "$home" approval "$task") || fail "approval line for $task was refused"
  record_answer "$home" "$id" "Captain, exact words: \"go ahead and publish it\"
$line" "$@"
}

trace_of() {  # <home> <task>
  tr '\n' ' ' < "$1/data/$2/trace" 2>/dev/null
}

test_refuses_without_recorded_approval() {
  local home out rc
  home=$(make_home no-approval)
  write_procedure "$home" t1
  rc=0
  out=$(run_publish "$home" run t1 2>&1) || rc=$?
  expect_code 3 "$rc" "run with no approval task at all"
  assert_contains "$out" "Approved publish: t1 sha256:" "the refusal must name the line to ask with"
  run_captain "$home" hold t1-ok --title "Approve publication" --reason "Approve?" --repo sample >/dev/null \
    || fail "could not hold t1-ok"
  rc=0
  out=$(run_publish "$home" run t1 --approval t1-ok 2>&1) || rc=$?
  expect_code 3 "$rc" "run while the approval is still waiting on the captain"
  assert_contains "$out" "held for the captain" "an unanswered call must not read as approval"
  record_answer "$home" t1-not-yet "Captain, exact words: \"not yet\""
  rc=0
  out=$(run_publish "$home" run t1 --approval t1-not-yet 2>&1) || rc=$?
  expect_code 3 "$rc" "run with an answer that does not approve this procedure"
  assert_absent "$home/data/t1/trace" "the procedure ran without a recorded approval"
  assert_absent "$home/data/t1/publish-logs" "a refused run must not start a run log"
  pass "a run with no recorded captain approval of the procedure refuses before any step"
}

test_refuses_when_the_approval_names_another_procedure() {
  local home out rc line
  home=$(make_home mismatch)
  write_procedure "$home" t1
  approve "$home" t1 t1-ok
  run_publish "$home" check t1 --approval t1-ok >/dev/null || fail "the recorded approval did not verify"
  printf '%s\n' 'echo extra-step' >> "$home/data/t1/publish/procedure"
  rc=0
  out=$(run_publish "$home" run t1 --approval t1-ok 2>&1) || rc=$?
  expect_code 3 "$rc" "run after the procedure changed under its approval"
  assert_contains "$out" "names another procedure" "the refusal must say the approval is for a different digest"
  write_procedure "$home" t2
  line=$(run_publish "$home" approval t2) || fail "approval line for t2 was refused"
  record_answer "$home" t2-ok "${line/t2/t3}"
  rc=0
  run_publish "$home" run t2 --approval t2-ok >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "run under an approval naming another task"
  assert_absent "$home/data/t1/trace" "the changed procedure ran"
  assert_absent "$home/data/t2/trace" "the procedure ran under another task's approval"
  pass "an approval that names another procedure digest or task refuses"
}

test_approved_run_publishes_and_restores() {
  local home out rc log
  home=$(make_home approved)
  write_procedure "$home" t1
  printf '%s\n' 'result: new PR https://example.invalid/pr/7' > "$home/data/t1/say-publish"
  approve "$home" t1 t1
  rc=0
  out=$(run_publish "$home" run t1 2>&1) || rc=$?
  expect_code 0 "$rc" "approved run"
  assert_equals "preflight lift publish verify restore " "$(trace_of "$home" t1)" "step order"
  assert_contains "$out" "publish: new PR https://example.invalid/pr/7" "the summary must repeat result lines"
  log=$(ls "$home"/data/t1/publish-logs/*.log) || fail "no run log under the task's data directory"
  assert_grep "== summary" "$log" "the run log must end in the summary"
  pass "an approved procedure runs every step in order and logs the run"
}

test_restore_always_runs() {
  local home rc log
  home=$(make_home restore)

  write_procedure "$home" t-preflight
  approve "$home" t-preflight t-preflight
  : > "$home/data/t-preflight/fail-preflight"
  rc=0
  run_publish "$home" run t-preflight >/dev/null 2>&1 || rc=$?
  expect_code 4 "$rc" "failed preflight"
  assert_equals "preflight restore " "$(trace_of "$home" t-preflight)" "a failed preflight lifts nothing and restores"

  write_procedure "$home" t-fail
  approve "$home" t-fail t-fail
  : > "$home/data/t-fail/fail-publish"
  rc=0
  run_publish "$home" run t-fail >/dev/null 2>&1 || rc=$?
  expect_code 6 "$rc" "failed publish"
  assert_equals "preflight lift publish restore " "$(trace_of "$home" t-fail)" "a failed publish restores and skips verify"

  write_procedure "$home" t-refused
  approve "$home" t-refused t-refused
  printf '%s\n' 'publish gate: REFUSED by the judge' > "$home/data/t-refused/say-publish"
  rc=0
  run_publish "$home" run t-refused >/dev/null 2>&1 || rc=$?
  expect_code 6 "$rc" "REFUSED in a publish step that exited 0"
  assert_equals "preflight lift publish restore " "$(trace_of "$home" t-refused)" "a REFUSED stops the run and restores"

  write_procedure "$home" t-gate
  approve "$home" t-gate t-gate
  printf '%s\n' '  gate: review' > "$home/data/t-gate/say-publish"
  rc=0
  run_publish "$home" run t-gate >/dev/null 2>&1 || rc=$?
  expect_code 6 "$rc" "a stop pattern in a publish step that exited 0"
  assert_equals "preflight lift publish restore " "$(trace_of "$home" t-gate)" "a finding stops the run and restores"

  write_procedure "$home" t-signal
  approve "$home" t-signal t-signal
  : > "$home/data/t-signal/signal-publish"
  rc=0
  run_publish "$home" run t-signal >/dev/null 2>&1 || rc=$?
  expect_code 130 "$rc" "interrupted run"
  assert_equals "preflight lift publish restore " "$(trace_of "$home" t-signal)" "an interrupt restores and skips verify"
  log=$(ls "$home"/data/t-signal/publish-logs/*.log) || fail "no run log for the interrupted run"
  assert_grep "interrupted by TERM" "$log" "the log must record the interrupt"
  assert_grep "blocks:     restored" "$log" "the interrupted run's summary must report the restore"

  write_procedure "$home" t-restore
  approve "$home" t-restore t-restore
  : > "$home/data/t-restore/fail-restore"
  rc=0
  run_publish "$home" run t-restore >/dev/null 2>&1 || rc=$?
  expect_code 8 "$rc" "a failed restore after a clean publication"
  log=$(ls "$home"/data/t-restore/publish-logs/*.log) || fail "no run log for the failed restore"
  assert_grep "RESTORE FAILED" "$log" "the summary must lead with the failed restore"
  assert_absent "$home/state/.approved-publish-t-restore.lock" "the run lock was left behind"
  pass "restore runs on every exit after preflight starts, and its failure takes precedence"
}

test_interrupt_stops_the_running_step() {
  local home rc runner pid i=0 log
  home=$(make_home interrupt)
  write_procedure "$home" t1
  approve "$home" t1 t1
  : > "$home/data/t1/hang-publish"
  (
    PATH="$home/fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" \
      FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_CONFIG_OVERRIDE="$home/config" exec "$ROOT/bin/fm-approved-publish.sh" run t1
  ) >/dev/null 2>&1 &
  runner=$!
  while [ ! -s "$home/data/t1/hang-pid" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i + 1)); done
  [ -s "$home/data/t1/hang-pid" ] || { kill -KILL "$runner" 2>/dev/null; fail "the publish step never started"; }
  pid=$(cat "$home/data/t1/hang-pid")
  kill -TERM "$runner"
  rc=0
  wait "$runner" || rc=$?
  expect_code 130 "$rc" "a run interrupted during a long publish step"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    fail "the interrupted publish step was still running after the runner exited"
  fi
  assert_absent "$home/data/t1/late-write" "the interrupted step made its later write"
  assert_equals "preflight lift publish restore " "$(trace_of "$home" t1)" "an interrupt mid-step stops it, restores, and skips verify"
  log=$(ls "$home"/data/t1/publish-logs/*.log) || fail "no run log for the interrupted run"
  assert_grep "stopping the interrupted publish step" "$log" "the log must record that the step was stopped"
  assert_grep "blocks:     restored" "$log" "the interrupted run's summary must report the restore"
  pass "an interrupt stops the running step and every process it started before restore runs"
}

test_step_children_never_outlive_the_step() {
  local home rc out pid held
  # A failing publish step that leaves publishers running, one still holding
  # its output and one detached from it, must not let either run on into
  # restore or past the runner's exit.
  home=$(make_home detach-fail)
  write_procedure "$home" t1
  approve "$home" t1 t1
  : > "$home/data/t1/orphan-publish"
  : > "$home/data/t1/detach-publish"
  : > "$home/data/t1/fail-publish"
  rc=0
  out=$(run_publish "$home" run t1 2>&1) || rc=$?
  held=$(cat "$home/data/t1/orphan-pid" 2>/dev/null) || fail "the failing publish step never started its output-holding child"
  pid=$(cat "$home/data/t1/detach-pid" 2>/dev/null) || fail "the failing publish step never started its detached child"
  if kill -0 "$held" 2>/dev/null || kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$held" "$pid" 2>/dev/null
    fail "a failed publish step's child was still running after the runner exited"
  fi
  assert_absent "$home/data/t1/late-write" "a failed publish step's child made its later write"
  expect_code 6 "$rc" "a publish step that fails after starting background children"
  assert_equals "preflight lift publish restore " "$(trace_of "$home" t1)" "restore must start only after the failed step's children are stopped"
  assert_contains "$out" "the publish step left processes running after it exited" "the run must report the stopped child"
  assert_contains "$out" "blocks:     restored" "the failed run must still restore"
  # The same holds for a step that succeeds.
  home=$(make_home detach-ok)
  write_procedure "$home" t1
  approve "$home" t1 t1
  : > "$home/data/t1/detach-lift"
  rc=0
  out=$(run_publish "$home" run t1 2>&1) || rc=$?
  pid=$(cat "$home/data/t1/detach-pid" 2>/dev/null) || fail "the lift step never started its child"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null
    fail "a successful lift step's child was still running after the runner exited"
  fi
  expect_code 0 "$rc" "a lift step that succeeds after starting a detached child"
  assert_equals "preflight lift publish verify restore " "$(trace_of "$home" t1)" "later steps must start only after the lift step's child is stopped"
  assert_contains "$out" "the lift step left processes running after it exited" "the run must report the stopped child"
  pass "nothing a step starts outlives it, whether the step succeeds or fails"
}

test_live_edits_never_reach_the_run() {
  local home out rc
  home=$(make_home snapshot)
  write_procedure "$home" t1
  approve "$home" t1 t1
  printf '%s\n' 'unapproved text' > "$home/data/t1/edit-preflight"
  rc=0
  out=$(run_publish "$home" run t1 2>&1) || rc=$?
  expect_code 0 "$rc" "approved run whose live procedure changed during preflight"
  assert_grep 'unapproved text' "$home/data/t1/publish/message" "the preflight edit never reached the live procedure"
  assert_not_contains "$out" "message: unapproved text" "a step ran a covered file edited after the approval check"
  assert_contains "$out" "message: approved text" "every step must run the approved copy"
  rc=0
  run_publish "$home" check t1 >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "check after the live procedure changed"
  pass "every step runs a copy of the approved procedure, so a live edit during the run never reaches it"
}

test_refuses_auto_approval_flags() {
  local home rc out
  home=$(make_home flags)
  write_procedure "$home" t1
  printf '%s\n' 'no-mistakes axi run --yes' >> "$home/data/t1/publish/procedure"
  rc=0
  out=$(run_publish "$home" approval t1 2>&1) || rc=$?
  expect_code 3 "$rc" "approval line for a procedure that spells --yes"
  assert_contains "$out" "auto-approval flag" "the refusal must name the auto-approval flag"
  write_procedure "$home" t2
  printf '%s\n' 'fm-publish-judge.sh override abc' >> "$home/data/t2/publish/procedure"
  rc=0
  run_publish "$home" approval t2 >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "approval line for a procedure that overrides the publish judge"
  assert_absent "$home/data/t1/trace" "the procedure ran"
  pass "a procedure that spells an auto-approval flag or judge override is refused"
}

test_reheld_approval_no_longer_counts() {
  local home rc
  home=$(make_home rehold)
  write_procedure "$home" t1
  approve "$home" t1 t1-ok --release
  run_publish "$home" check t1 --approval t1-ok >/dev/null || fail "a released approval did not verify"
  run_captain "$home" hold t1-ok --reason "The captain asked to revisit this publication." >/dev/null 2>&1 \
    || fail "could not re-hold t1-ok"
  rc=0
  run_publish "$home" run t1 --approval t1-ok >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "run while the approval is held for the captain again"
  assert_absent "$home/data/t1/trace" "the procedure ran under a re-held approval"
  pass "an approval held for the captain again no longer authorizes the run"
}

test_refuses_without_recorded_approval
test_refuses_when_the_approval_names_another_procedure
test_approved_run_publishes_and_restores
test_restore_always_runs
test_interrupt_stops_the_running_step
test_step_children_never_outlive_the_step
test_live_edits_never_reach_the_run
test_refuses_auto_approval_flags
test_reheld_approval_no_longer_counts
