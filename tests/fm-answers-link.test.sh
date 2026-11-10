#!/usr/bin/env bash
# tests/fm-answers-link.test.sh - the bin/fm-spawn.sh --answers link between a
# dispatched ship/scout and the captain-held call it was sent to answer.
#
# Dispatch validates the named id is an open captain call, records the call as
# blocked-by the task at the dispatch commit, and writes answers= in the task
# record for relaunch and promotion to carry. bin/fm-teardown.sh asks
# fm-captain-hold.sh open about that recorded call after the landed close and
# prints one naming line when it is still held; it never answers, releases, or
# closes the call, and an unreadable hold check warns without failing.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_git_identity fmtest fmtest@example.invalid

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-answers-link)

command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

# A fake `orca` CLI of the same minimal shape tests/fm-spawn-orca-worktree.test.sh
# uses: it performs a REAL `git worktree add` for `worktree create` and answers
# every other lifecycle call with the JSON bin/backends/orca.sh accepts.
make_orca_fakebin() {
  local dir=$1 fb
  fb=$(fm_fakebin "$dir")
  cat > "$fb/orca" <<'SH'
#!/usr/bin/env bash
set -u
DIR="${FM_TEST_ORCA_DIR:?}"
case "$1 $2" in
  "status --json")
    printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n'
    exit 0
    ;;
  "repo show")
    exit 1
    ;;
  "repo add")
    printf '{"ok":true,"result":{"repo":{"id":"repo1"}}}\n'
    exit 0
    ;;
  "worktree create")
    name=
    prev=
    for a in "$@"; do
      [ "$prev" = --name ] && name=$a
      prev=$a
    done
    wt="$DIR/orca-worktrees/$name"
    mkdir -p "$DIR/orca-worktrees"
    git -C "$DIR/project" worktree add --quiet -b "orca-$name" "$wt" >&2 || exit 1
    printf '{"ok":true,"result":{"worktree":{"id":"wt-%s","path":"%s"}}}\n' "$name" "$wt"
    exit 0
    ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"term-1"}}}\n'
    exit 0
    ;;
  "terminal close")
    touch "$DIR/terminal-closed"
    exit 0
    ;;
  "terminal send")
    printf '{"ok":true}\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fb/orca"
  printf '%s\n' "$fb"
}

# A markdown-backlog home plus a fixture project with a local bare origin.
# Seeds the backlog file, a queued ship row for $id, and its brief.
make_spawn_home() {  # <name> <id>
  local name=$1 id=$2 home
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$home/data/backlog.md"
  printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' \
    > "$home/.tasks.toml"
  tasks-axi add "$id" "work for $id" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an --answers dispatch for $id.

## Firstmate spec
Land the assigned work and report.
EOF
  fm_git_init_commit "$TMP_ROOT/$name/project"
  fm_git_add_origin "$TMP_ROOT/$name/project" "$TMP_ROOT/$name/project.origin.git"
  printf '%s\n' "$home"
}

# An open captain call in the home's backlog.
hold_call() {  # <home> <call-id>
  local home=$1 call=$2
  tasks-axi add "$call" "captain call $call" --kind captain \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi hold "$call" --kind captain --reason 'waiting on the captain' \
    --file "$home/data/backlog.md" >/dev/null
}

run_orca_spawn() {  # <name> <id> [extra args...]
  local name=$1 id=$2 fb
  shift 2
  fb="$TMP_ROOT/$name/fakebin"
  FM_ROOT_OVERRIDE='' FM_HOME="$TMP_ROOT/$name/home" HOME="$TMP_ROOT/$name/user-home" \
    FM_STATE_OVERRIDE="$TMP_ROOT/$name/home/state" \
    FM_DATA_OVERRIDE="$TMP_ROOT/$name/home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/$name/home/projects" \
    FM_CONFIG_OVERRIDE="$TMP_ROOT/$name/home/config" \
    FM_SPAWN_NO_GUARD=1 FM_TEST_ORCA_DIR="$TMP_ROOT/$name" \
    PATH="$fb:$PATH" \
    "$SPAWN" "$id" "$TMP_ROOT/$name/project" --backend orca "$@" 2>&1
}

show_field() {  # <file> <id> <field>
  tasks-axi show "$2" --file "$1" 2>/dev/null | sed -n "s/^  $3: *//p" | head -1
}

test_dispatch_records_the_link() {
  local name=edge home id=ship-a1 call=call-a1 fb out status dep
  home=$(make_spawn_home "$name" "$id")
  hold_call "$home" "$call"
  fb=$(make_orca_fakebin "$TMP_ROOT/$name")

  out=$(run_orca_spawn "$name" "$id" --mode local-only --yolo off --answers "$call")
  status=$?
  expect_code 0 "$status" "dispatch with --answers should succeed"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success"$'\n'"$out"
  grep -qx "answers=$call" "$home/state/$id.meta" \
    || fail "task record does not carry the --answers link"
  dep=$(show_field "$home/data/backlog.md" "$call" deps)
  [ "$dep" = "\"blocked-by:$id\"" ] || [ "$dep" = "blocked-by:$id" ] \
    || fail "the call does not read as blocked-by the dispatched task (deps: $dep)"
  [ "$(show_field "$home/data/backlog.md" "$call" hold_kind)" = captain ] \
    || fail "recording the link lifted the captain hold"
  [ "$(show_field "$home/data/backlog.md" "$call" state)" != "done" ] \
    || fail "recording the link closed the call"
  pass "dispatch with --answers writes answers= meta and the call's blocked-by edge"
}

test_dispatch_without_the_flag_writes_no_link() {
  local name=no-flag home id=ship-a2 out status
  home=$(make_spawn_home "$name" "$id")
  make_orca_fakebin "$TMP_ROOT/$name" >/dev/null

  out=$(run_orca_spawn "$name" "$id" --mode local-only --yolo off)
  status=$?
  expect_code 0 "$status" "an ordinary dispatch should still succeed"$'\n'"$out"
  ! grep -q '^answers=' "$home/state/$id.meta" \
    || fail "an ordinary spawn wrote an answers= line: $(grep '^answers=' "$home/state/$id.meta")"
  pass "a spawn without --answers writes no answers= line"
}

test_dispatch_refuses_an_id_that_is_not_an_open_captain_call() {
  local name=refusals home id=ship-a3 fb out status
  home=$(make_spawn_home "$name" "$id")
  fb=$(make_orca_fakebin "$TMP_ROOT/$name")

  # A queued ordinary row exists but is not captain-held.
  tasks-axi add plain-a3 "ordinary queued row" --kind ship \
    --file "$home/data/backlog.md" >/dev/null
  # A captain call that is already closed.
  hold_call "$home" done-a3
  tasks-axi "done" done-a3 --file "$home/data/backlog.md" >/dev/null

  while IFS='|' read -r call expect; do
    [ -n "$call" ] || continue
    out=$(run_orca_spawn "$name" "$id" --mode local-only --yolo off --answers "$call")
    status=$?
    [ "$status" -ne 0 ] || fail "--answers $call was not refused"$'\n'"$out"
    printf '%s\n' "$out" | grep -F -- "$expect" >/dev/null \
      || fail "--answers $call: missing refusal '$expect'"$'\n'"$out"
    [ ! -e "$home/state/$id.meta" ] || fail "--answers $call left a task record behind"
  done <<'ROWS'
ghost-a3|--answers ghost-a3 has no backlog item in this home
plain-a3|--answers plain-a3 is not an open captain-held task
done-a3|--answers done-a3 is not an open captain-held task
ship-a3|--answers cannot name the task being dispatched
ROWS
  pass "dispatch refuses --answers naming a missing, non-held, closed, or self id"
}

test_answers_flag_refusals_before_any_backlog_read() {
  local name=early home id=ship-a4 fb out status
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$TMP_ROOT/$name/project"
  fb=$(make_orca_fakebin "$TMP_ROOT/$name")

  out=$(run_orca_spawn "$name" "$id" --mode local-only --yolo off --answers=)
  status=$?
  [ "$status" -ne 0 ] || fail "--answers= was not refused"$'\n'"$out"
  assert_contains "$out" '--answers requires a non-empty value' \
    "empty --answers was not refused"$'\n'"$out"

  out=$(run_orca_spawn "$name" "$id" --secondmate --answers call-a4)
  status=$?
  [ "$status" -ne 0 ] || fail "--answers on a secondmate launch was not refused"$'\n'"$out"
  assert_contains "$out" '--answers is for ship and scout launches, never a secondmate' \
    "secondmate --answers was not refused"$'\n'"$out"

  out=$(run_orca_spawn "$name" "pair1-a4=$TMP_ROOT/$name/project" "pair2-a4=$TMP_ROOT/$name/project" \
    --mode local-only --yolo off --answers call-a4)
  status=$?
  [ "$status" -ne 0 ] || fail "--answers on batch dispatch was not refused"$'\n'"$out"
  assert_contains "$out" '--answers is per-task' \
    "batch --answers was not refused"$'\n'"$out"
  pass "empty, secondmate, and batch --answers are refused before any backlog read"
}

# Shadow tasks-axi so `block` fails with <exit-code>; every other verb is real.
# A dispatch whose edge write fails trips over it at the commit point.
break_tasks_axi_block() {  # <fakebin> [exit-code]
  local fb=$1 failure_code=${2:-1} real
  real=$(command -v tasks-axi)
  cat > "$fb/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = block ]; then
  echo 'error: "block refused"' >&2
  exit "$failure_code"
fi
exec "$real" "\$@"
SH
  chmod +x "$fb/tasks-axi"
}

test_edge_failure_returns_the_row_to_queued() {
  local name=edge-fail home id=ship-a6 call=call-a6 fb out status
  home=$(make_spawn_home "$name" "$id")
  hold_call "$home" "$call"
  fb=$(make_orca_fakebin "$TMP_ROOT/$name")
  break_tasks_axi_block "$fb" 70

  out=$(run_orca_spawn "$name" "$id" --mode local-only --yolo off --answers "$call")
  status=$?
  [ "$status" -ne 0 ] || fail "a refused answers edge did not fail the dispatch"$'\n'"$out"
  assert_contains "$out" 'dispatch commit could not finish' \
    "the edge failure did not report as a partial commit"$'\n'"$out"
  [ ! -e "$home/state/$id.meta" ] || fail "the provisional record survived rollback"
  # The record removal must not leave an in-flight row without a record: that
  # orphan_in_flight shape makes the home's fleet inventory invalid.
  [ "$(show_field "$home/data/backlog.md" "$id" state)" = queued ] \
    || fail "the row was not returned to Queued after the failed edge write"
  pass "a failed answers edge removes the record and returns the row to Queued"
}

test_answers_refuses_a_home_with_no_recorded_backlog() {
  local name=manual home id=ship-a5 fb out status
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'manual\n' > "$home/config/backlog-backend"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise an --answers refusal on a manual-backlog home.

## Firstmate spec
Land the assigned work and report.
EOF
  fm_git_init_commit "$TMP_ROOT/$name/project"
  fb=$(make_orca_fakebin "$TMP_ROOT/$name")

  out=$(run_orca_spawn "$name" "$id" --mode local-only --yolo off --answers call-a5)
  status=$?
  [ "$status" -ne 0 ] || fail "--answers on a manual-backlog home was not refused"$'\n'"$out"
  assert_contains "$out" "--answers records the call in this home's backlog" \
    "manual-backlog --answers was not refused"$'\n'"$out"
  pass "--answers refuses a home whose backlog is not recorded by this launch"
}

# --- teardown ----------------------------------------------------------------

# A compact landed-work fixture of the same shape tests/fm-teardown.test.sh
# uses: a project clone with a bare origin, a task worktree on the task branch
# with no unlanded commits, and fakebin stand-ins for the post-check tools.
make_td_case() {  # <name>
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  fm_fake_exit0 "$fakebin" treehouse tmux no-mistakes
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/gh"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" fm/task-x1
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_td_meta() {  # <case_dir> [extra meta lines...]
  local case_dir=$1
  shift
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "spawn_gen=answers-link-task-x1" \
    "$@"
  printf 'done: fixture\n' > "$case_dir/state/task-x1.status"
}

seed_td_backlog() {  # <case_dir>
  local case_dir=$1
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "answers-link fixture task" --kind ship \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

hold_td_call() {  # <case_dir> <call-id>
  local case_dir=$1 call=$2
  tasks-axi add "$call" "captain call $call" --kind captain \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi hold "$call" --kind captain --reason 'waiting on the captain' \
    --file "$case_dir/data/backlog.md" >/dev/null
}

run_td() {  # <case_dir>
  local case_dir=$1
  FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" \
    PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 2>&1
}

test_teardown_names_the_still_open_call() {
  local case_dir out status call=call-t1
  case_dir=$(make_td_case td-open)
  write_td_meta "$case_dir" "answers=$call"
  seed_td_backlog "$case_dir"
  hold_td_call "$case_dir" "$call"
  tasks-axi block "$call" --by task-x1 --file "$case_dir/data/backlog.md" >/dev/null

  out=$(run_td "$case_dir")
  status=$?
  expect_code 0 "$status" "teardown of the landed answering task should succeed"$'\n'"$out"
  printf '%s\n' "$out" | grep -F -- "$call" >/dev/null \
    || fail "the reminder does not name the still-open call"$'\n'"$out"
  printf '%s\n' "$out" | grep -F 'task-x1' >/dev/null \
    || fail "the reminder does not name the landed task"$'\n'"$out"
  printf '%s\n' "$out" | grep -F 'still held for the captain' >/dev/null \
    || fail "the reminder does not read as the printed obligation"$'\n'"$out"
  # The reminder resolves nothing: the call is still an open captain call.
  [ "$(show_field "$case_dir/data/backlog.md" "$call" state)" != "done" ] \
    || fail "the reminder closed the call"
  [ "$(show_field "$case_dir/data/backlog.md" "$call" hold_kind)" = captain ] \
    || fail "the reminder lifted the captain hold"
  pass "teardown names the still-open captain call the landed task answered"
}

test_teardown_stays_silent_when_the_call_is_closed() {
  local case_dir out status call=call-t2
  case_dir=$(make_td_case td-closed)
  write_td_meta "$case_dir" "answers=$call"
  seed_td_backlog "$case_dir"
  hold_td_call "$case_dir" "$call"
  tasks-axi "done" "$call" --file "$case_dir/data/backlog.md" >/dev/null

  out=$(run_td "$case_dir")
  status=$?
  expect_code 0 "$status" "teardown should succeed when the call is already closed"$'\n'"$out"
  assert_not_contains "$out" 'still held for the captain' \
    "a closed call still printed the reminder"$'\n'"$out"
  pass "teardown prints no reminder when the answered call is already closed"
}

test_teardown_warns_when_the_call_read_fails() {
  local case_dir out status
  case_dir=$(make_td_case td-unread)
  # An answers= value that is not a slug makes fm-captain-hold.sh open exit 2:
  # the read could not be established, so teardown warns and still succeeds.
  write_td_meta "$case_dir" "answers=not a slug"
  seed_td_backlog "$case_dir"

  out=$(run_td "$case_dir")
  status=$?
  expect_code 0 "$status" "an unreadable answers call must not fail teardown"$'\n'"$out"
  assert_contains "$out" 'warning:' \
    "the failed call read did not warn"$'\n'"$out"
  assert_not_contains "$out" 'still held for the captain' \
    "an unreadable call printed the reminder"$'\n'"$out"
  pass "teardown warns and still succeeds when the answers call cannot be read"
}

# --- promotion ---------------------------------------------------------------

test_promotion_preserves_the_link() {
  local name=promote home id=scout-p1 out status
  home="$TMP_ROOT/$name/home"
  mkdir -p "$home/data/$id" "$home/state" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  fm_git_init_commit "$TMP_ROOT/$name/project"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$TMP_ROOT/$name/wt" \
    "kind=scout" \
    "spawn_gen=answers-link-$id" \
    "answers=call-p1"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Scout the answers-link surface for $id.

## Firstmate spec
Report findings.
EOF

  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" \
    "$PROMOTE" "$id" --mode local-only --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion of the answering scout should succeed"$'\n'"$out"
  grep -qx 'kind=ship' "$home/state/$id.meta" \
    || fail "promotion did not flip kind"
  grep -qx 'answers=call-p1' "$home/state/$id.meta" \
    || fail "promotion dropped the recorded --answers link"
  pass "scout promotion preserves the recorded --answers link"
}

test_dispatch_records_the_link
test_dispatch_without_the_flag_writes_no_link
test_dispatch_refuses_an_id_that_is_not_an_open_captain_call
test_answers_flag_refusals_before_any_backlog_read
test_edge_failure_returns_the_row_to_queued
test_answers_refuses_a_home_with_no_recorded_backlog
test_teardown_names_the_still_open_call
test_teardown_stays_silent_when_the_call_is_closed
test_teardown_warns_when_the_call_read_fails
test_promotion_preserves_the_link
