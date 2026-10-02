#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's pre-launch abort rollback and its raw agy
# launch path, driven against a REAL tmux server on a private -S socket.
#
# A fresh spawn that refuses after it created its endpoint and leased its slot,
# but before the launch line reaches the pane, must leave nothing behind: the
# window it opened is closed, the slot goes back to the pool through the
# fixture treehouse, and its lease receipt, busy-state files, and harness
# wiring are gone. A raw agy launch command must launch rather than abort on
# an executable it never resolved.
#
# Every tmux call, including the ones fm-spawn.sh makes through PATH, reaches
# only this suite's private server: the PATH shim strips TMUX/TMUX_PANE and
# pins -S to the suite socket, so the default server and any firstmate
# session are never touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" || exit 1

SPAWN="$ROOT/bin/fm-spawn.sh"
REAL_TMUX=$(command -v tmux || true)
if [ -z "$REAL_TMUX" ]; then
  echo "skip: tmux not found; the pre-launch rollback suite needs a real private tmux server"
  exit 0
fi
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found; the agy wiring needs it"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-spawn-prelaunch-rollback)
# A unix socket path must stay short, so it lives outside the deep temp root.
SOCK_DIR=$(mktemp -d /tmp/fm-rb.XXXXXX)
SOCK="$SOCK_DIR/s"
SESSION=rollback
cleanup_rollback() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$SOCK_DIR"
  [ -z "${LAUNCH_BLOCKER:-}" ] || rm -f "$LAUNCH_BLOCKER"
  fm_test_cleanup
}
trap cleanup_rollback EXIT

ptmux() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" "$@"
}

ptmux -f /dev/null new-session -d -s "$SESSION" -x 200 -y 50 /bin/bash ||
  fail "could not start the private tmux server"
ptmux set-option -g default-shell /bin/bash >/dev/null
ptmux set-option -g default-command /bin/bash >/dev/null

make_case() {  # <name> <id> -> case_dir|home|proj|wt|fakebin
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
exec env -u TMUX -u TMUX_PANE $(printf '%q' "$REAL_TMUX") -S $(printf '%q' "$SOCK") "\$@"
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --version) printf 'agy 1.2.5\n' ;; esac
exit 0
SH
  chmod +x "$fakebin/agy"
  fm_fake_exit0 "$fakebin" gh-axi gh
  fm_fake_treehouse_lease "$fakebin"
  fm_test_spawn_home "$home"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  fm_test_spawn_brief "$home" "$id" "Exercise the pre-launch rollback for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <proj> <wt> <fakebin> <id> [args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_LEASE_PATH="$wt" TMUX="$SOCK,0,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" "$@" 2>&1
}

window_present() {  # <window-name>
  ptmux list-windows -t "=$SESSION" -F '#{window_name}' 2>/dev/null | grep -qxF -- "$1"
}

# Everything a refused fresh spawn acquired before launch must be gone.
assert_rolled_back() {  # <label> <home> <wt> <fakebin> <id> <spawn-output>
  local label=$1 home=$2 wt=$3 fakebin=$4 id=$5 out=$6 leftover
  ! window_present "fm-$id" || fail "$label: the refused spawn left its window fm-$id open"
  grep -qxF -- "return --force $wt" "$fakebin/treehouse-calls" 2>/dev/null ||
    fail "$label: the leased slot was not returned; treehouse calls: $(cat "$fakebin/treehouse-calls" 2>/dev/null); slot status: $(git -C "$wt" status --porcelain --ignored=matching --untracked-files=all 2>&1); spawn output: $out"
  for leftover in treehouse-lease busy-state busy-gen meta agy-hooks agy-permission.json agy-permission-cache; do
    [ ! -e "$home/state/$id.$leftover" ] && [ ! -L "$home/state/$id.$leftover" ] ||
      fail "$label: the refused spawn left state/$id.$leftover behind"
  done
}

# Case (2): --agy-bypass refuses a worktree carrying a tracked
# .agents/hooks.json. The refusal itself stays; what it acquired first must not.
test_bypass_hooks_refusal_rolls_back() {
  local id="rb-hooks-$$" fields case_dir home proj wt fakebin out status
  fields=$(make_case hooks "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$fields
EOF
  : "$case_dir"
  mkdir -p "$proj/.agents"
  printf '{"firstmate-worker":{}}\n' > "$proj/.agents/hooks.json"
  git -C "$proj" add .agents/hooks.json
  git -C "$proj" -c user.email=t@t -c user.name=t commit -qm hooks
  git -C "$proj" push -q origin HEAD:main 2>/dev/null ||
    git -C "$proj" push -q origin HEAD 2>/dev/null ||
    fail "hooks: the fixture's project hook file did not reach origin"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" agy --scout --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "hooks: a bypass spawn over a project hooks.json must refuse: $out"
  case "$out" in
    *'worker hooks to be the only hooks in force'*) ;;
    *) fail "hooks: expected the hooks.json refusal, got: $out" ;;
  esac
  grep -qxF -- "get --lease --lease-holder $home:$id" "$fakebin/treehouse-calls" ||
    fail "hooks: the case must lease a slot before refusing, or it proves nothing: $(cat "$fakebin/treehouse-calls" 2>/dev/null)"
  assert_rolled_back hooks "$home" "$wt" "$fakebin" "$id" "$out"
  pass "fm-spawn.sh: an agy bypass refusal after leasing returns the slot and closes its window"
}

# A refusal after the provisional record was published but before launch
# delivery: a staged-launch directory that is not private refuses the launch.
test_post_publication_prelaunch_refusal_rolls_back() {
  local id="rb-stage-$$" fields case_dir home proj wt fakebin out status token
  fields=$(make_case stage "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$fields
EOF
  : "$case_dir"
  token=$(printf '%s' "$(cd "$home" && pwd -P)" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')
  LAUNCH_BLOCKER="/tmp/fm-$id+$token"
  ln -s /nonexistent "$LAUNCH_BLOCKER"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" agy --scout)
  status=$?
  rm -f "$LAUNCH_BLOCKER"
  [ "$status" -ne 0 ] || fail "stage: a non-private launch directory must refuse the spawn: $out"
  case "$out" in
    *'is not a private directory'*) ;;
    *) fail "stage: expected the staged-launch refusal, got: $out" ;;
  esac
  assert_rolled_back stage "$home" "$wt" "$fakebin" "$id" "$out"
  pass "fm-spawn.sh: a refusal after the record was published but before launch rolls everything back"
}

# The return resets the slot, so a slot holding content this spawn did not
# write keeps its lease and receipt, while the window still closes.
test_foreign_slot_content_keeps_the_lease() {
  local id="rb-foreign-$$" fields case_dir home proj wt fakebin out status token
  fields=$(make_case foreign "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$fields
EOF
  : "$case_dir"
  printf 'left by an earlier tenant\n' > "$wt/leftover.txt"
  token=$(printf '%s' "$(cd "$home" && pwd -P)" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}')
  LAUNCH_BLOCKER="/tmp/fm-$id+$token"
  ln -s /nonexistent "$LAUNCH_BLOCKER"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" agy --scout)
  status=$?
  rm -f "$LAUNCH_BLOCKER"
  [ "$status" -ne 0 ] || fail "foreign: the spawn must refuse: $out"
  ! window_present "fm-$id" || fail "foreign: the refused spawn left its window open"
  ! grep -q '^return ' "$fakebin/treehouse-calls" ||
    fail "foreign: a slot holding foreign content was returned and reset"
  [ -e "$home/state/$id.treehouse-lease" ] || fail "foreign: the retained lease lost its receipt"
  [ -f "$wt/leftover.txt" ] || fail "foreign: the foreign file was removed"
  case "$out" in
    *'holds content this spawn did not write'*) ;;
    *) fail "foreign: the retention must be reported, got: $out" ;;
  esac
  pass "fm-spawn.sh: a refused spawn keeps the lease on a slot holding content it did not write"
}

# Case (1): a raw agy launch command never resolves AGY_BIN, so the
# placeholder substitution must not abort the spawn under set -u.
test_raw_agy_launch_does_not_abort() {
  local id="rb-raw-$$" fields case_dir home proj wt fakebin out status
  fields=$(make_case raw "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$fields
EOF
  : "$case_dir"
  out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout "agy --version")
  status=$?
  case "$out" in
    *'unbound variable'*) fail "raw: the raw agy launch hit an unbound variable: $out" ;;
  esac
  expect_code 0 "$status" "raw: a raw agy launch command should spawn"$'\n'"$out"
  window_present "fm-$id" || fail "raw: the spawned window is missing"
  [ -f "$home/state/$id.meta" ] || fail "raw: the spawn published no task record"
  grep -qx 'agy_version=' "$home/state/$id.meta" || fail "raw: an unresolved launch binary must have an unknown version"
  ! grep -qx 'agy_bypass=on' "$home/state/$id.meta" || fail "raw: an unpoliced launch must not claim bypass coverage"
  pass "fm-spawn.sh: a raw agy launch command spawns without resolving the agy executable"
}

test_agy_audit_dependency_refuses_before_launch() {
  local mode id fields case_dir home proj wt fakebin out status
  for mode in auto manual raw bypass; do
    id="rb-python-$mode-$$"
    fields=$(make_case "python-$mode" "$id")
    IFS='|' read -r case_dir home proj wt fakebin <<EOF
$fields
EOF
    : "$case_dir"
    printf '#!/usr/bin/env bash\nexit 127\n' > "$fakebin/python3"
    chmod +x "$fakebin/python3"
    [ "$mode" != manual ] || printf 'manual\n' > "$home/config/crew-permissions"
    case "$mode" in
      raw) out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout 'agy --version'); status=$? ;;
      bypass) out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" agy --scout --agy-bypass); status=$? ;;
      *) out=$(run_spawn "$home" "$proj" "$wt" "$fakebin" "$id" agy --scout); status=$? ;;
    esac
    [ "$status" -ne 0 ] || fail "$mode: unusable Python must refuse agy launch"
    case "$out" in *'Python 3 is required for its cleanup audit'*) ;; *) fail "$mode: missing audit dependency diagnostic: $out" ;; esac
    ! window_present "fm-$id" || fail "$mode: dependency refusal must not open an endpoint"
    [ ! -f "$home/state/$id.meta" ] || fail "$mode: dependency refusal must not publish metadata"
    [ ! -f "$fakebin/treehouse-calls" ] || fail "$mode: dependency refusal must precede any slot acquisition"
  done
  pass "fm-spawn.sh: every agy launch checks its audit dependency before acquiring an endpoint"
}

test_agy_audit_dependency_refuses_before_launch
test_bypass_hooks_refusal_rolls_back
test_post_publication_prelaunch_refusal_rolls_back
test_foreign_slot_content_keeps_the_lease
test_raw_agy_launch_does_not_abort
