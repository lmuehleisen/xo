#!/usr/bin/env bash
# tests/fm-control-relaunch-bindings.test.sh - relaunch keeps a task's durable
# bindings intact (bin/fm-control.sh relaunch and bin/fm-spawn.sh --relaunch).
#
# A relaunch that rewrites task metadata keeps an armed merge poll bound, a
# relaunch reuses its own worktree claim while refusing another task's claim on
# the same copy, and a relaunch away from devin retires exactly the
# firstmate-owned wiring while leaving project-owned .devin content. The shared
# relaunch transaction cases live in tests/fm-control-relaunch.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch-bindings)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
fm_test_require_tmproot "$TMP_ROOT"
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    fm_test_remove_tree "${d:-}"
  done
  fm_test_remove_tree "${TMP_ROOT:-}"
}
trap relaunch_cleanup EXIT

# The lifecycle-modelling tmux stub from tests/fm-control-relaunch.test.sh,
# without its race and failure-injection hooks: the harness's exit command
# stops the agent, and a launch-brief literal starts the harness in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit) printf 'zsh' > "$D/command" ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*) cat "$D/becomes" > "$D/command" ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_width*) printf '200\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through
  # fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

# fm-control.sh relaunch rewrites metadata with control_relaunch_tx= after the
# preserved pr= / pr_head= block. That used to fail the poll identity parse.
test_relaunch_does_not_disarm_an_armed_merge_poll() {
  local dir out rc url
  dir=$(new_case poll-identity rl-poll)
  add_ship_task "$dir" rl-poll claude
  url=https://github.com/o/r/pull/10
  {
    printf '%s\n' "pr=$url"
    printf '%s\n' 'pr_head=0123456789abcdef0123456789abcdef01234567'
  } >> "$dir/home/state/rl-poll.meta"
  fm_pr_poll_prepare "$dir/home/state" rl-poll github "$url" github.com o/r 10 \
    "$ROOT/bin/fm-pr-poll.sh" \
    || fail "could not prepare the armed poll before relaunch"
  fm_pr_poll_publish_prepared || fail "could not publish the armed poll before relaunch"
  fm_pr_poll_artifacts_valid "$dir/home/state" rl-poll "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the armed poll was not valid before relaunch"
  out=$(run_control "$dir" rl-poll relaunch --note "keep the merge poll armed"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed with an armed merge poll"$'\n'"$out"
  [ -n "$(meta_field "$dir" rl-poll control_relaunch_tx)" ] \
    || fail "relaunch did not record control_relaunch_tx="
  fm_pr_poll_artifacts_valid "$dir/home/state" rl-poll "$ROOT/bin/fm-pr-poll.sh" \
    || fail "fm-control.sh relaunch disarmed the armed merge poll"
  pass "fm-control relaunch: an armed merge poll stays bound after control_relaunch_tx="
}

test_spawn_relaunch_refuses_another_tasks_worktree_claim() {
  local dir out rc
  dir=$(new_case shared-claim rl43)
  add_ship_task "$dir" rl43 claude
  printf 'zsh' > "$dir/fake/command"
  fm_write_meta "$dir/home/state/other-claim.meta" \
    "project=$dir/proj" "worktree=$dir/wt" "kind=ship"
  if out=$(run_spawn "$dir" rl43 --relaunch --harness claude); then rc=0; else rc=$?; fi
  expect_code 1 "$rc" "relaunch must refuse another task's claim"
  assert_contains "$out" other-claim "relaunch refusal must name the other claimant"
  assert_present "$dir/home/state/rl43.meta" "relaunch refusal lost its own record"
  assert_present "$dir/home/state/other-claim.meta" "relaunch refusal lost the competing record"
  assert_no_grep 'encode launch-brief' "$dir/fake/literal" "relaunch started a worker in a contested copy"
  pass "fm-spawn --relaunch: reuses its own claim but refuses a competing task's claim"
}

test_devin_pending_permission_escalation_is_retired_on_a_harness_switch() {
  local dir state key=devin-permission-exec_1-dead
  command -v jq >/dev/null 2>&1 || { printf 'skip - devin pending escalation retirement: jq not installed\n'; return 0; }
  dir=$(new_case devinpending rl36)
  add_ship_task "$dir" rl36 devin
  state="$dir/home/state"
  jq -n --arg s "$state" '{task:"rl36", status:($s+"/rl36.status"), log:($s+"/devin-permission-log.jsonl")}' \
    > "$state/rl36.devin-permission.json"
  # A Devin worker that died while waiting at an escalated permission prompt.
  mkdir -p "$state/rl36.devin-permission-pending"
  printf '%s\n%s\n' "$key" "npm install" > "$state/rl36.devin-permission-pending/exec_1-dead.pending"
  printf 'needs-decision [key=%s]: Devin is waiting at a permission prompt for exec: npm install\n' "$key" \
    > "$state/rl36.status"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl36 --relaunch --harness claude >/dev/null
  [ ! -e "$state/rl36.devin-permission-pending" ] \
    || fail "the retired devin incarnation's pending escalation markers must not outlive it"
  [ ! -e "$state/rl36.devin-permission.json" ] || fail "the devin permission policy file must be retired"
  grep -qF "resolved [key=$key]: " "$state/rl36.status" \
    || fail "the orphaned escalation must be closed in the status log: $(cat "$state/rl36.status")"
  [ "$(jq -r 'select(.decider == "prompt") | .decision' "$state/devin-permission-log.jsonl")" = not-run ] \
    || fail "the orphaned escalation must be logged as not-run"
  pass "fm-spawn --relaunch: switching away from devin closes and retires its pending permission escalations"
}

# A devin incarnation leaves two firstmate-owned files under the worktree's
# .devin/; a pooled slot keeps them across reset/clean because both sit in git
# info/exclude. Retiring the files without their directories still strands the
# shell of the wiring - the next devin spawn into that slot then refuses on the
# leftover - so the directories go too, but only while empty.
test_devin_worktree_wiring_is_retired_on_a_harness_switch() {
  local dir state
  dir=$(new_case devinwiring rl37)
  add_ship_task "$dir" rl37 devin
  state="$dir/home/state"
  mkdir -p "$dir/wt/.devin/rules"
  printf '{"attribution":false}\n' > "$dir/wt/.devin/config.local.json"
  printf 'no attribution\n' > "$dir/wt/.devin/rules/firstmate-attribution.md"
  printf '{"task":"rl37","status":"%s","log":"%s"}\n' \
    "$state/rl37.status" "$state/devin-permission-log.jsonl" \
    > "$state/rl37.devin-permission.json"
  printf '{}\n' > "$state/rl37.devin-config.json"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch away from devin should succeed"$'\n'"$out"
  [ ! -e "$dir/wt/.devin/config.local.json" ] \
    || fail "the retired devin incarnation's config.local.json must not outlive it"
  [ ! -e "$dir/wt/.devin/rules/firstmate-attribution.md" ] \
    || fail "the retired devin incarnation's attribution rule must not outlive it"
  [ ! -e "$state/rl37.devin-permission.json" ] \
    || fail "the retired devin incarnation's permission policy file must not outlive it"
  [ ! -e "$state/rl37.devin-config.json" ] \
    || fail "the retired devin incarnation's private config must not outlive it"
  [ ! -d "$dir/wt/.devin/rules" ] \
    || fail "the emptied .devin/rules directory must not outlive the retired devin incarnation"
  [ ! -d "$dir/wt/.devin" ] \
    || fail "the emptied .devin directory must not outlive the retired devin incarnation"
  pass "fm-spawn --relaunch: switching away from devin retires its private config, legacy worktree wiring, and emptied directories"
}

test_devin_relaunch_keeps_project_owned_devin_content() {
  local dir
  dir=$(new_case devinkeep rl38)
  add_ship_task "$dir" rl38 devin
  mkdir -p "$dir/wt/.devin/rules"
  printf '{"attribution":false}\n' > "$dir/wt/.devin/config.local.json"
  printf 'no attribution\n' > "$dir/wt/.devin/rules/firstmate-attribution.md"
  printf 'project rule\n' > "$dir/wt/.devin/rules/project-rule.md"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch away from devin should succeed"$'\n'"$out"
  [ ! -e "$dir/wt/.devin/config.local.json" ] \
    || fail "the retired devin incarnation's config.local.json must not outlive it"
  [ ! -e "$dir/wt/.devin/rules/firstmate-attribution.md" ] \
    || fail "the retired devin incarnation's attribution rule must not outlive it"
  [ -f "$dir/wt/.devin/rules/project-rule.md" ] \
    || fail "a relaunch must not remove project-owned .devin content"
  [ -d "$dir/wt/.devin/rules" ] && [ -d "$dir/wt/.devin" ] \
    || fail ".devin directories that still hold project content must survive a relaunch away from devin"
  pass "fm-spawn --relaunch: switching away from devin keeps project-owned .devin content and its directories"
}

# A devin worker can also make a managed path project-owned mid-task by
# committing it (the Exec allowlist permits git add/commit). Once git tracks
# the file it is the project's own, so the harness switch must leave it -
# tearing it out would strand a dirty worktree missing a tracked file.
test_devin_relaunch_keeps_a_tracked_attribution_rule() {
  local dir state
  dir=$(new_case devintracked rl39)
  add_ship_task "$dir" rl39 devin
  state="$dir/home/state"
  mkdir -p "$dir/wt/.devin/rules"
  printf '{"attribution":false}\n' > "$dir/wt/.devin/config.local.json"
  printf 'no attribution\n' > "$dir/wt/.devin/rules/firstmate-attribution.md"
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    add .devin/rules/firstmate-attribution.md
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm "Worker committed the attribution rule"
  printf '{"task":"rl39","status":"%s","log":"%s"}\n' \
    "$state/rl39.status" "$state/devin-permission-log.jsonl" \
    > "$state/rl39.devin-permission.json"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl39 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch away from devin should succeed"$'\n'"$out"
  [ ! -e "$dir/wt/.devin/config.local.json" ] \
    || fail "the retired devin incarnation's untracked config.local.json must not outlive it"
  [ ! -e "$state/rl39.devin-permission.json" ] \
    || fail "the retired devin incarnation's permission policy file must not outlive it"
  [ -f "$dir/wt/.devin/rules/firstmate-attribution.md" ] \
    || fail "a relaunch must never remove a git-tracked .devin/rules/firstmate-attribution.md"
  [ -d "$dir/wt/.devin/rules" ] && [ -d "$dir/wt/.devin" ] \
    || fail ".devin directories that still hold a tracked file must survive a relaunch away from devin"
  [ -z "$(git -C "$dir/wt" status --porcelain)" ] \
    || fail "a retained tracked file must leave the worktree clean: $(git -C "$dir/wt" status --porcelain)"
  pass "fm-spawn --relaunch: switching away from devin keeps a git-tracked attribution rule"
}

test_relaunch_does_not_disarm_an_armed_merge_poll
test_spawn_relaunch_refuses_another_tasks_worktree_claim
test_devin_pending_permission_escalation_is_retired_on_a_harness_switch
test_devin_worktree_wiring_is_retired_on_a_harness_switch
test_devin_relaunch_keeps_project_owned_devin_content
test_devin_relaunch_keeps_a_tracked_attribution_rule
