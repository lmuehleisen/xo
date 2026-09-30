#!/usr/bin/env bash
# tests/fm-spawn-identity-pin.test.sh - the spawn-owned commit identity pin and
# publish hooks (bin/fm-spawn.sh; bin/fm-publish-gate.sh owns the identity file).
#
# The assertions never read bin/fm-spawn.sh's source. They drive the real spawn
# against a fake pane and a real isolated git worktree, then EXECUTE the launch
# command the pane received, with the harness binary replaced by a probe that
# commits with `git -c user.email=<other>` - the override the pin must
# neutralize - and prints the identity git recorded.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-identity-pin)

PIN_NAME='Example Owner'
# Fixture emails are assembled at runtime so the committed lines never carry
# an address the staged-change email check would refuse.
PIN_EMAIL="4242+example-owner@""users.noreply.github.com"
OTHER_EMAIL='someone.else@example.com'

make_case() { # <name> <id> -> sets HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG PANE_LOG
  local name=$1 id=$2 case_dir
  case_dir="$TMP_ROOT/$name"
  HOME_DIR="$case_dir/home"
  PROJ_DIR="$case_dir/project"
  WT_DIR="$case_dir/wt"
  LAUNCH_LOG="$case_dir/launch.log"
  PANE_LOG="$case_dir/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  fm_test_spawn_brief "$HOME_DIR" "$id"
}

run_spawn() {
  : >"$LAUNCH_LOG"
  : >"$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

# The harness probe commits in the task worktree with an explicit identity
# override, then prints author and committer emails and the hooks path it saw.
install_commit_probe() {
  cat >"$FAKEBIN_DIR/codex" <<SH
#!/bin/sh
cd $(printf '%q' "$WT_DIR") || exit 1
printf 'probe\n' >probe.txt
git add probe.txt
git -c user.name=Other -c user.email=$OTHER_EMAIL commit -q -m 'probe commit' || exit 1
git log -1 --format='%ae %ce'
git config --get core.hooksPath
SH
  chmod +x "$FAKEBIN_DIR/codex"
}

run_emitted_launch() {
  local preamble
  preamble=$(grep '^export ' "$PANE_LOG")
  env -i HOME="$TMP_ROOT/pane-home" PATH="$FAKEBIN_DIR:$PATH" TERM=xterm \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    /bin/sh -c "$preamble
$(cat "$LAUNCH_LOG")"
}

test_identity_file_pins_every_commit() {
  local out status seen
  make_case pinned pin-a1
  mkdir -p "$HOME_DIR/config/publish-guard"
  printf 'name=%s\nemail=%s\n' "$PIN_NAME" "$PIN_EMAIL" >"$HOME_DIR/config/publish-guard/identity"
  out=$(run_spawn pin-a1 "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn with an identity file should succeed: $out"
  install_commit_probe
  seen=$(run_emitted_launch) || fail "the emitted launch failed to run: $seen"
  assert_contains "$seen" "$PIN_EMAIL $PIN_EMAIL" "git -c user.email inside the worker must still record the pinned identity"
  assert_contains "$seen" "$HOME_DIR/state/pin-a1.git-hooks" "the worker must run with the per-task hooks path"
  assert_present "$HOME_DIR/state/pin-a1.git-hooks/pre-push" "the per-task pre-push hook"
  pass "an identity file pins author and committer for every commit the worker makes"
}

test_absent_identity_file_means_no_pin() {
  local out status seen
  make_case unpinned pin-b1
  out=$(run_spawn pin-b1 "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  expect_code 0 "$status" "spawn without an identity file should succeed: $out"
  install_commit_probe
  seen=$(run_emitted_launch) || fail "the emitted launch failed to run: $seen"
  assert_contains "$seen" "$OTHER_EMAIL $OTHER_EMAIL" "without an identity file the launch must not pin"
  pass "no identity file means no pin, as upstream behaves"
}

test_malformed_identity_file_stops_the_spawn() {
  local out status
  make_case malformed pin-c1
  mkdir -p "$HOME_DIR/config/publish-guard"
  printf 'email=\n' >"$HOME_DIR/config/publish-guard/identity"
  out=$(run_spawn pin-c1 "$PROJ_DIR" --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a malformed identity file should stop the spawn"
  assert_contains "$out" "publish-guard/identity is malformed" "malformed identity reason"
  assert_absent "$HOME_DIR/state/pin-c1.meta" "a refused spawn must not leave a task record"
  assert_absent "$HOME_DIR/state/pin-c1.git-hooks" "a refused spawn must not leave task hooks"
  pass "a malformed identity file stops the spawn rather than launching unpinned"
}

test_identity_file_pins_every_commit
test_absent_identity_file_means_no_pin
test_malformed_identity_file_stops_the_spawn

echo "# all fm-spawn-identity-pin tests passed"
