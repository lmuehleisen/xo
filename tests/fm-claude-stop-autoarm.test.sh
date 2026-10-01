#!/usr/bin/env bash
# Behavior tests for the Claude Stop-owned watcher auto-arm
# (bin/fm-claude-stop-autoarm.sh, docs/watcher-continuity.md).
#
# The hook fires as a Claude asyncRewake Stop hook. These tests run it hermetically
# as a child of a fake harness (a bash symlink named "claude") whose pid is
# written into the fixture home's state/.lock for ordinary owned-lock cases.
# Stale-owner cases instead leave a dead recorded pid for the hook to reclaim
# through the real fm-lock.sh path. The arm wrapper is a per-test fixture, so no
# real watcher, model, or fleet state is touched.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME expands inside the fake harness child, and grep needles are literal strings
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-stop-autoarm)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"
export FAKE_CLAUDE

# Copy the hook and its sourced dependencies into a fixture checkout.
install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  cp "$ROOT/bin/fm-claude-lib.sh" "$dir/bin/fm-claude-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-afk-contract.sh" "$dir/bin/fm-afk-contract.sh"
  cp "$ROOT/bin/fm-classify-lib.sh" "$dir/bin/fm-classify-lib.sh"
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh" "$dir/bin/fm-afk-contract.sh"
}

make_primary_dir() {
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

make_secondmate_dir() {
  local dir=$1
  make_primary_dir "$dir" >/dev/null
  printf 'sm-autoarm-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree: the shape every crewmate/scout task worktree
# has (git-dir != git-common-dir), which must keep the hook inert.
make_crewmate_worktree_dir() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/autoarm-test-branch
  mkdir -p "$dir/state"
  : > "$dir/AGENTS.md"
  install_autoarm_scripts "$dir"
  printf '%s\n' "$dir"
}

# Run the hook as a child of the fake harness holding the fixture home's
# session lock. $1 = fixture dir. $2 = optional Stop payload, defaulting to a
# bare Claude-shaped payload with no transcript_path. Any extra env
# assignments must be exported before invocation. Captures stdout+stderr;
# exit code on stdout of the caller.
run_autoarm() {
  local dir=$1 payload=${2:-'{"session_id":"sess-autoarm","stop_hook_active":false}'} rc=0
  printf '%s\n' "$payload" \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1 || rc=$?
  printf 'RC=%s\n' "$rc" >&2
  return "$rc"
}

# Arm fixture variants, installed per test as <dir>/bin/fm-watch-arm.sh.
write_arm_fixture() {
  local dir=$1 kind=$2
  # Every fixture records the hook's foreground arms in state/arm-ran. A handling
  # successor (FM_WATCH_PREDECESSOR_ARM_PID set) is recorded apart in
  # state/successor-ran so attempt counts stay about the foreground; it confirms
  # a started watcher and exits, parks while state/successor-park exists, or
  # fails while state/successor-fail exists.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'arm=%s predecessor=%s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID" >> "$FM_HOME/state/successor-ran"
  if [ -e "$FM_HOME/state/successor-fail" ]; then
    printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
    exit 1
  fi
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  while [ -e "$FM_HOME/state/successor-park" ]; do sleep 0.05; done
  exit 0
fi
echo "$$" >> "$FM_HOME/state/arm-ran"
SH
  case "$kind" in
    actionable)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    failed)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    clean)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    benign-live)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    actionable-many)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'stale: fixture-%s actionable\n' "$i"; done
exit 0
SH
      ;;
    reset-boundary)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
: > "$FM_HOME/state/arm-waiting"
while [ ! -e "$FM_HOME/state/arm-release" ]; do sleep 0.02; done
printf 'watcher: FAILED - cycle ended without an actionable reason\n'
exit 1
SH
      ;;
    slow-actionable)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
sleep 2
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: slow fixture\n'
exit 0
SH
      ;;
    blocking-actionable)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
sleep 6
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    supersede-then-fail)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'epoch=999 owner_pid=1 outcome=arming updated_at=%s\nfixture-superseder-identity\n' "$(date +%s)" \
  > "$FM_HOME/state/.claude-autoarm-epoch"
printf 'watcher: FAILED - no live watcher with a fresh beacon\n'
exit 1
SH
      ;;
    meta-vanishes)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
rm -f "$FM_HOME/state/task.meta"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'signal: task.status done: fixture\n'
exit 0
SH
      ;;
    afk-appears)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
: > "$FM_HOME/state/.afk"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
      ;;
    records-deadline)
      cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf '%s\n' "${FM_WATCH_DEADLINE:-unset}" > "$FM_HOME/state/arm-received-deadline"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    records-grace)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf '%s\n' "${FM_GUARD_GRACE:-unset}" > "$FM_HOME/state/arm-received-grace"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
      ;;
    attached-delivered)
      cat >> "$dir/bin/fm-watch-arm.sh" <<'SH'
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
printf 'signal: task.status done: fixture peer cycle ended\n'
exit 0
SH
      ;;
    *)
      echo "unknown arm fixture: $kind" >&2
      return 2
      ;;
  esac
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

epoch_outcome() {
  sed -n '1s/^.*outcome=\([a-z][a-z-]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

# Run the hook in the background under the fake harness, output captured to a
# file. Sets RUN_AUTOARM_BG_PID (a direct child of the calling shell, so the
# caller can `wait` on it for the hook's exit status).
RUN_AUTOARM_BG_PID=
run_autoarm_bg() {
  local dir=$1 out=$2
  printf '%s\n' '{"session_id":"sess-autoarm","stop_hook_active":false}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' > "$out" 2>&1 &
  RUN_AUTOARM_BG_PID=$!
}

watcher_identity() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$dir/bin/fm-wake-lib.sh" "$pid"
}

record_watcher_lock() {
  local dir=$1 pid=$2 identity=$3 root bin_dir
  root=$dir
  bin_dir=$(cd "$dir/bin" && pwd)
  mkdir -p "$dir/state/.watch.lock"
  printf '%s\n' "$pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$root" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$bin_dir/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$dir/state/.watch.lock/pid-identity"
}

# --- registration contract ----------------------------------------------------

# --- scope and gates ----------------------------------------------------------

test_inert_in_child_worktree() {
  local base dir out status
  base="$TMP_ROOT/crew-base"
  dir="$TMP_ROOT/crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stay inert in a child task worktree"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed inside a child worktree"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch inside a child worktree"
  pass "auto-arm: inert in a linked child worktree even when in-flight"
}

test_inert_without_session_lock() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/no-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # No state/.lock: run the hook directly (no fake harness, no lock file).
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" 2>&1); status=$?
  expect_code 0 "$status" "hook must stay inert when no session holds the home lock"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed without a session lock"
  pass "auto-arm: inert with no session lock"
}

test_reclaims_stale_session_lock_before_arming() {
  local dir out status expected_owner actual_owner
  dir=$(make_primary_dir "$TMP_ROOT/stale-lock")
  : > "$dir/state/task.meta"
  printf '9999999\n' > "$dir/state/.lock"
  write_arm_fixture "$dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/expected-owner"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
      ' 2>&1); status=$?
  expect_code 2 "$status" "a dead recorded session owner must be reclaimed before the actionable rewake"
  expected_owner=$(cat "$dir/state/expected-owner")
  actual_owner=$(cat "$dir/state/.lock")
  [ "$actual_owner" = "$expected_owner" ] || fail "stale session lock was not claimed by the current harness: expected $expected_owner, got $actual_owner"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm after reclaiming the stale session lock"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "stale-lock recovery must record outcome=rewake"
  pass "auto-arm: a demonstrably dead recorded session owner is reclaimed through fm-lock.sh before arming"
}

test_inert_when_lock_held_by_other_harness() {
  local dir other out status owner_after
  dir=$(make_primary_dir "$TMP_ROOT/other-lock")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # The trailing no-op keeps the fake harness process alive instead of allowing
  # bash to exec the final sleep into a non-harness process.
  "$FAKE_CLAUDE" -c 'sleep 60; :' &
  other=$!
  printf '%s\n' "$other" > "$dir/state/.lock"
  out=$(printf '%s\n' '{"session_id":"s"}' | FM_HOME="$dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  owner_after=$(cat "$dir/state/.lock")
  kill "$other" 2>/dev/null || true
  wait "$other" 2>/dev/null || true
  expect_code 0 "$status" "hook must stay inert when another live harness holds the session lock"
  [ "$owner_after" = "$other" ] || fail "hook replaced another live harness owner: expected $other, got $owner_after"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while another session owned the lock"
  [ ! -e "$dir/state/.claude-autoarm-epoch" ] || fail "hook wrote an epoch while another session owned the lock"
  pass "auto-arm: inert without arm, rewake, or lock replacement when another live harness owns the home"
}

test_inert_when_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must never arm or rewake while away mode owns triage"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed while state/.afk existed"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "AFK without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "AFK without positive recovery reset the attended alarm"
  pass "auto-arm: inert while AFK owns supervision"
}

test_stale_lock_recovery_preserves_afk_and_need_gates() {
  local afk_dir idle_dir out status
  afk_dir=$(make_primary_dir "$TMP_ROOT/stale-afk")
  : > "$afk_dir/state/task.meta"
  : > "$afk_dir/state/.afk"
  printf '9999999\n' > "$afk_dir/state/.lock"
  write_arm_fixture "$afk_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-afk"}' | FM_HOME="$afk_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the AFK gate"
  [ "$(cat "$afk_dir/state/.lock")" = 9999999 ] || fail "AFK stale lock was reclaimed despite away ownership"
  [ ! -e "$afk_dir/state/arm-ran" ] || fail "stale AFK home armed"

  idle_dir=$(make_primary_dir "$TMP_ROOT/stale-idle")
  printf '9999999\n' > "$idle_dir/state/.lock"
  write_arm_fixture "$idle_dir" actionable
  out=$(printf '%s\n' '{"session_id":"stale-idle"}' | FM_HOME="$idle_dir" "$FAKE_CLAUDE" -c '"$FM_HOME/bin/fm-claude-stop-autoarm.sh"' 2>&1); status=$?
  expect_code 0 "$status" "a stale owner must not widen the supervision-need gate"
  [ "$(cat "$idle_dir/state/.lock")" = 9999999 ] || fail "idle stale lock was reclaimed without supervision need"
  [ ! -e "$idle_dir/state/arm-ran" ] || fail "stale idle home armed"
  pass "auto-arm: stale-owner recovery leaves the AFK and supervision-need gates unchanged"
}

test_resolves_outermost_claude_pid_in_nested_bgspare_chain() {
  local dir out status inner_pid lock_pid
  dir=$(make_primary_dir "$TMP_ROOT/nested-chain")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  # A genuine multi-level contiguous claude-named ancestry: the hook fires
  # inside an inner fake-claude process (its recorded pid is distinct from its
  # own parent, a second, outer fake-claude process holding the session lock -
  # the bg-spare shape). Only the outer pid may own the lock; a
  # first-match-wins walk would resolve to the inner pid instead and leave the
  # hook inert. The inner process records its own pid before running the hook
  # so bash cannot tail-exec-collapse it into the outer pid, which would
  # collapse the two-hop chain this test depends on down to one hop.
  out=$(printf '%s\n' '{"session_id":"nested"}' \
    | FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FAKE_CLAUDE" -c "
          printf \"%s\n\" \"\$\$\" > \"\$FM_HOME/state/inner-pid\"
          \"\$FM_HOME/bin/fm-claude-stop-autoarm.sh\"
        "
      ' 2>&1); status=$?
  inner_pid=$(cat "$dir/state/inner-pid" 2>/dev/null || true)
  lock_pid=$(cat "$dir/state/.lock" 2>/dev/null || true)
  [ -n "$inner_pid" ] && [ "$inner_pid" != "$lock_pid" ] \
    || fail "test setup did not produce a genuine two-hop claude chain: inner=$inner_pid lock=$lock_pid"
  expect_code 2 "$status" "a nested contiguous claude ancestry must resolve to the outer lock-owning pid and arm"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not resolve past the inner claude-named process to the outer lock owner"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "nested-chain arm must record outcome=rewake"
  pass "auto-arm: resolves the outermost pid of a nested contiguous claude ancestry (bg-spare chain)"
}

test_inert_when_fleet_idle() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/idle")
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must exit 0 in an idle home with no X-mode poll"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed an idle home"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "idle state without positive recovery reset the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "idle state without positive recovery reset the attended alarm"
  pass "auto-arm: inert with nothing in flight and no X-mode need"
}

# --- the armed cycle ----------------------------------------------------------

test_actionable_close_rewakes_with_reason() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/actionable")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an actionable arm close must exit 2 so Claude rewakes"
  assert_contains "$out" "firstmate watcher wake" "rewake must carry the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "rewake must carry the arm's reason line"
  assert_contains "$out" "bin/fm-wake-drain.sh" "rewake must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "rewake must forbid a duplicate model re-arm"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ "$(epoch_field "$dir" session_pid)" = "$(cat "$dir/state/.lock")" ] \
    || fail "rewake epoch must bind the lock-owning Claude session"
  [ "$(epoch_field "$dir" recovery_generation)" = fixture-generation ] \
    || fail "rewake epoch must bind the watcher recovery generation"
  [ ! -e "$dir/state/.claude-autoarm.lock" ] || fail "owner lock must be released after the cycle"
  [ -e "$dir/state/arm-ran" ] || fail "hook never foregrounded the arm wrapper"
  pass "auto-arm: actionable close translates to exactly one exit-2 rewake with reason"
}

# pi-code (Pi's Claude-hook compatibility extension) delivers a Claude-shaped
# Stop payload but awaits the hook with no asyncRewake support, so the hook
# must stand down or it wedges Pi's turn for the declared timeout (issue
# #3343). The discriminator is the payload's transcript_path: pi-code stamps
# Pi's own session file under .pi/, which a Claude transcript path never
# contains, so the stand-down must not overmatch a genuine Claude payload or a
# payload with no transcript_path at all.
test_stands_down_only_on_pi_code_transcript_path() {
  local dir out status

  dir=$(make_primary_dir "$TMP_ROOT/picode-pi")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" '{"session_id":"sess-pi","stop_hook_active":false,"transcript_path":"/home/u/.pi/agent/sessions/s.jsonl"}' 2>/dev/null); status=$?
  expect_code 0 "$status" "hook must stand down silently on a pi-code-delivered transcript_path"
  [ -z "$out" ] || fail "pi-code stand-down printed output: $out"
  [ ! -e "$dir/state/arm-ran" ] || fail "hook armed on a pi-code-delivered payload"

  dir=$(make_primary_dir "$TMP_ROOT/picode-claude")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" '{"session_id":"sess-claude","stop_hook_active":false,"transcript_path":"/home/u/.claude/projects/-home-u--pi-proj/s.jsonl"}' 2>/dev/null); status=$?
  expect_code 2 "$status" "a Claude-shaped transcript_path must still arm and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm with a Claude-shaped transcript_path present"

  dir=$(make_primary_dir "$TMP_ROOT/picode-none")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a payload without transcript_path must still arm"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm without a transcript_path"

  pass "auto-arm: stands down only on a pi-code-delivered transcript_path (/.pi/)"
}

test_actionable_close_with_live_successor_rewakes_once() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/actionable-live-successor")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live successor for actionable close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"

  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  write_arm_fixture "$dir" benign-live
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?

  expect_code 2 "$status" "an actionable close must rewake when a live successor already exists"
  expect_code 0 "$status2" "a repeated non-actionable close with the live successor must stay quiet"
  [ "$(printf '%s\n' "$out" | grep -c '^firstmate watcher wake')" -eq 1 ] \
    || fail "actionable close with a live successor did not emit exactly one wake banner: $out"
  [ "$(printf '%s\n' "$out" | grep -c '^stale: fixture-win actionable')" -eq 1 ] \
    || fail "actionable close with a live successor did not surface its reason exactly once: $out"
  [ -z "$out2" ] || fail "repeated hook duplicated the delivered actionable result: $out2"
  kill -0 "$pid" 2>/dev/null || fail "actionable delivery stopped or replaced the live successor"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "the later benign close must record outcome=clean"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: actionable close survives a healthy successor without duplicate delivery"
}

# An arm that attached to a peer cycle returns when that cycle ends with the wake
# the peer delivered. Pi, omp, and OpenCode start the next arm before notifying
# the model; the hook must do the same, naming the closed arm as the successor's
# predecessor, and the successor must outlive the hook's exit-2 rewake.
test_attached_cycle_end_starts_handling_successor() {
  local dir out status foreground predecessor successor i
  dir=$(make_primary_dir "$TMP_ROOT/attached-successor")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" attached-delivered
  : > "$dir/state/successor-park"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an attached cycle's delivered wake must still rewake"
  assert_contains "$out" "signal: task.status done: fixture peer cycle ended" "rewake must carry the delivered reason"
  [ -s "$dir/state/successor-ran" ] \
    || fail "the hook returned from the ended attached cycle without starting a handling successor"
  [ "$(wc -l < "$dir/state/successor-ran" | tr -d ' ')" -eq 1 ] \
    || fail "exactly one handling successor must start per actionable close: $(cat "$dir/state/successor-ran")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 1 ] || fail "the foreground arm must run once"
  foreground=$(cat "$dir/state/arm-ran")
  predecessor=$(sed -n 's/^arm=[0-9]* predecessor=\([0-9]*\)$/\1/p' "$dir/state/successor-ran")
  [ "$predecessor" = "$foreground" ] \
    || fail "the successor must name the closed foreground arm $foreground as its predecessor, got: $(cat "$dir/state/successor-ran")"
  successor=$(sed -n 's/^arm=\([0-9]*\) .*$/\1/p' "$dir/state/successor-ran")
  kill -0 "$successor" 2>/dev/null || fail "the handling successor did not outlive the hook's rewake"
  rm -f "$dir/state/successor-park"
  i=0
  while kill -0 "$successor" 2>/dev/null && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ "$(printf '%s\n' "$out" | grep -c '^firstmate watcher wake')" -eq 1 ] \
    || fail "the successor start must not change the single wake banner: $out"
  assert_not_contains "$out" "did not confirm" "a confirmed successor adds nothing to the rewake"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "epoch must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: an attached cycle's end starts a handling successor named after the closed arm before the rewake"
}

test_unconfirmed_handling_successor_still_rewakes() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/successor-unconfirmed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" attached-delivered
  : > "$dir/state/successor-fail"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a failed handling successor must never withhold the delivered wake"
  assert_contains "$out" "signal: task.status done: fixture peer cycle ended" "rewake must still carry the delivered reason"
  assert_contains "$out" "did not confirm a live watcher" "the rewake must say this turn runs uncovered"
  assert_contains "$out" "watcher: FAILED - no live watcher with a fresh beacon" "the rewake must carry the successor's own failure line"
  [ "$(wc -l < "$dir/state/successor-ran" | tr -d ' ')" -eq 1 ] || fail "the failed successor must not be retried inside the rewake path"
  pass "auto-arm: an unconfirmed handling successor is reported in the rewake instead of blocking it"
}

test_failed_close_rewakes_with_failure_banner() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/failed")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a typed watcher failure must rewake as an alarm"
  assert_contains "$out" "automatic supervision mechanism is broken" "failure rewake must describe the automatic mechanism failure"
  assert_contains "$out" "watcher: FAILED" "failure rewake must carry the arm's typed failure"
  assert_not_contains "$out" "bin/fm-watch-arm.sh" "failure rewake must not create a manual arm loop"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "failure must exhaust exactly two bounded arm attempts"
  pass "auto-arm: bounded failure verification emits one automatic-mechanism alarm"
}

test_failed_cycles_notify_once_and_keep_retrying() {
  local dir out1 out2 status1 status2
  dir=$(make_primary_dir "$TMP_ROOT/failed-dedup")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  expect_code 2 "$status1" "the first exhausted failure must notify"
  expect_code 2 "$status2" "a consecutive exhausted failure must force another Stop-owned retry"
  [ -n "$out1" ] || fail "the first exhausted failure did not notify"
  [ -z "$out2" ] || fail "consecutive exhausted failure repeated an operator notice: $out2"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 4 ] || fail "each cycle must retain bounded automatic retries"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "failure episode marker was not recorded"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "second failure must record failed-suppressed"
  pass "auto-arm: consecutive failures keep Stop-owned retry without repeating notice"
}

test_failure_notice_marker_write_refuses_delivery_and_retries() {
  local dir marker out1 out2 out3 status1 status2 status3 gen1 delivered
  dir=$(make_primary_dir "$TMP_ROOT/failed-marker-refusal")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" failed
  marker="$dir/state/.claude-autoarm-failure-notified"
  ln -s "$dir/state/missing/notice" "$marker"

  out1=$(run_autoarm "$dir" 2>/dev/null); status1=$?
  expect_code 0 "$status1" "an unrecordable failure notice must refuse delivery"
  [ -L "$marker" ] || fail "the failed marker write unexpectedly replaced its dangling symlink"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "the refused generation must leave its terminal ledger outcome"
  gen1=$(epoch_field "$dir" epoch)

  rm -f "$marker"
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  out3=$(run_autoarm "$dir" 2>/dev/null); status3=$?
  expect_code 2 "$status2" "a successor must retry and deliver after the marker path is restored"
  expect_code 2 "$status3" "a later failure must retain the Stop-owned retry"
  [ "$(epoch_field "$dir" epoch)" -gt "$gen1" ] || fail "the successor did not supersede the refused terminal entry"
  assert_present "$marker" "the successful successor did not record the failure notice"
  assert_contains "$out2" "automatic supervision mechanism is broken" "the successful successor did not deliver the failure notice"
  [ -z "$out3" ] || fail "the firing after the successful marker commit repeated the notice: $out3"
  delivered=$(printf '%s\n%s\n' "$out2" "$out3" | grep -c 'automatic supervision mechanism is broken' || true)
  [ "$delivered" -eq 1 ] || fail "the restored episode delivered $delivered failure notices instead of one"
  pass "auto-arm: marker-write refusal defers delivery until one successor commits the notice"
}

test_unverified_clean_close_exhausts_retries() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/clean")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" clean
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a non-actionable close without a healthy watcher must fail closed"
  assert_contains "$out" "automatic supervision mechanism is broken" "unverified close must report automatic failure"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "unverified close must exhaust exactly two bounded attempts"
  [ "$(epoch_outcome "$dir")" = failed ] || fail "epoch must record outcome=failed, got: $(epoch_outcome "$dir")"
  pass "auto-arm: unverified clean close exhausts retries and fails closed"
}

# A host-timeout kill can leave the failure notice and a later read-only
# session's attended fail-open can add the alarm; an actionable wake of the
# next live session must still rewake rather than be recorded
# failed-suppressed.
test_leftover_failure_episode_never_suppresses_actionable_wake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/post-alarm-actionable")
  : > "$dir/state/task.meta"
  printf 'epoch=7 owner_pid=999 outcome=failed updated_at=1\n' > "$dir/state/.claude-autoarm-epoch"
  printf 'session=sess-other\ncount=4\nepoch=7\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a real wake must rewake even when an earlier failure episode left its alarm"
  assert_contains "$out" "firstmate watcher wake" "the leftover episode swallowed the wake banner"
  assert_contains "$out" "stale: fixture-win actionable" "the leftover episode swallowed the wake reason"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the actionable close must record outcome=rewake, got: $(epoch_outcome "$dir")"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "a real wake left the stale failure notice"
  assert_absent "$dir/state/.claude-autoarm-failure-alarmed" "a real wake left the stale attended alarm"
  assert_absent "$dir/state/.turnend-claude-blocks" "a real wake left the stale block budget"
  pass "auto-arm: a leftover failure episode never suppresses an actionable wake, and the wake ends that episode"
}

# The deadline passed to the arm is the declared hook timeout less
# min(600s, a quarter of it), counted from when the hook started.
test_arm_deadline_derives_from_declared_timeout() {
  local dir case_name timeout expected before deadline status
  for case_name in declared short absent; do
    dir=$(make_primary_dir "$TMP_ROOT/deadline-$case_name")
    : > "$dir/state/task.meta"
    write_arm_fixture "$dir" records-deadline
    case "$case_name" in
      declared) timeout=28800; expected=28200 ;;
      short) timeout=40; expected=30 ;;
      absent) timeout=; expected=450 ;;
    esac
    if [ -n "$timeout" ]; then
      mkdir -p "$dir/.claude"
      jq -n --argjson t "$timeout" '{hooks: {
          Stop: [{hooks: [
            {type: "command", command: "bin/fm-turnend-guard.sh --claude"},
            {type: "command", command: "bin/fm-claude-stop-autoarm.sh", asyncRewake: true, timeout: $t}]}],
          StopFailure: [{hooks: [
            {type: "command", command: "bin/fm-claude-stop-autoarm.sh --stop-failure", asyncRewake: true, timeout: 5}]}]}}' \
        > "$dir/.claude/settings.json"
    fi
    before=$(date +%s)
    run_autoarm "$dir" >/dev/null 2>&1; status=$?
    expect_code 2 "$status" "$case_name: the recording fixture's unverified close must still fail closed"
    deadline=$(cat "$dir/state/arm-received-deadline" 2>/dev/null || true)
    case "$deadline" in
      ''|*[!0-9]*) fail "$case_name: the arm received no FM_WATCH_DEADLINE, got: '$deadline'" ;;
    esac
    [ "$((deadline - before))" -ge "$expected" ] && [ "$((deadline - before))" -le "$((expected + 3))" ] \
      || fail "$case_name: deadline is $((deadline - before))s after the hook started, expected about ${expected}s"
  done
  pass "auto-arm: the arm deadline derives from this hook's own declared Stop timeout, with a 600s fallback"
}

# The real arm and watcher, with nothing to report, close before a short
# declared timeout through one no-op check wake that the hook translates into
# an ordinary rewake. On a build without the deadline the cycle outlives the
# timeout, which is what a host kill turns into a lost rewake.
test_real_cycle_closes_before_declared_timeout() {
  local dir out start elapsed hook_pid status i
  dir=$(make_primary_dir "$TMP_ROOT/deadline-real-cycle")
  rm -rf "${dir:?}/bin"
  cp -R "$ROOT/bin" "$dir/bin"
  : > "$dir/state/task.meta"
  mkdir -p "$dir/.claude"
  jq -n '{hooks: {Stop: [{hooks: [
      {type: "command", command: "bin/fm-claude-stop-autoarm.sh", asyncRewake: true, timeout: 24}]}]}}' \
    > "$dir/.claude/settings.json"
  out="$dir/hook.out"
  start=$(date +%s)
  FM_POLL=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 run_autoarm_bg "$dir" "$out"
  hook_pid=$RUN_AUTOARM_BG_PID
  i=0
  while kill -0 "$hook_pid" 2>/dev/null && [ "$i" -lt 290 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  elapsed=$(( $(date +%s) - start ))
  if kill -0 "$hook_pid" 2>/dev/null; then
    # Only this fixture's own processes match its unique temporary path.
    pkill -KILL -f "$dir/bin/fm-" 2>/dev/null || true
    kill -KILL "$hook_pid" 2>/dev/null || true
    wait "$hook_pid" 2>/dev/null || true
    fail "the hook-owned cycle was still running ${elapsed}s after start, past its 24s declared timeout"
  fi
  wait "$hook_pid"; status=$?
  expect_code 2 "$status" "the pre-timeout close must rewake"
  [ "$elapsed" -lt 24 ] || fail "the cycle closed after ${elapsed}s, not before its 24s declared timeout"
  assert_contains "$(cat "$out")" "check: autoarm-deadline" "the rewake did not carry the deadline wake"
  grep -q "$(printf '\tcheck\tautoarm-deadline\t')" "$dir/state/.wake-queue" \
    || fail "the deadline wake was not queued for the drain: $(cat "$dir/state/.wake-queue" 2>/dev/null)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the deadline close must record outcome=rewake, got: $(epoch_outcome "$dir")"
  pass "auto-arm: a real quiet cycle closes before the declared hook timeout with one queued no-op wake and a rewake"
}

test_benign_cycle_end_with_live_watcher_is_silent() {
  local dir out out2 status status2 pid identity
  dir=$(make_primary_dir "$TMP_ROOT/benign-live")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for benign close"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  out2=$(run_autoarm "$dir" 2>/dev/null); status2=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a failed-looking cycle with a live fresh watcher must be benign"
  expect_code 0 "$status2" "the next Stop-owned cycle must remain benign with the live watcher"
  [ -z "$out" ] || fail "benign live cycle produced an operator notice: $out"
  [ -z "$out2" ] || fail "next benign live cycle produced an operator notice: $out2"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "benign live cycle must record outcome=clean, got: $(epoch_outcome "$dir")"
  [ "$(wc -l < "$dir/state/arm-ran" | tr -d ' ')" -eq 2 ] || fail "the next Stop-owned cycle must run its own bounded arm"
  [ ! -e "$dir/state/.turnend-claude-blocks" ] || fail "benign live cycle must clear the prior block budget"
  [ ! -e "$dir/state/.claude-autoarm-failure-notified" ] || fail "benign live cycle must not leave a failure-notice marker"
  [ ! -e "$dir/state/.claude-autoarm-failure-alarmed" ] || fail "benign live cycle must not leave an attended-alarm marker"
  pass "auto-arm: benign cycle end with a live watcher and fresh beacon stays silent across the next cycle"
}

test_positive_recovery_budget_contention_preserves_episode() {
  local dir out status pid identity holder
  dir=$(make_primary_dir "$TMP_ROOT/recovery-budget-contention")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" benign-live
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify live watcher holder for recovery contention"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  printf 'session=sess-autoarm\ncount=3\nepoch=9\n' > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.turnend-claude-blocks.lock"
  printf '%s\n' "$holder" > "$dir/state/.turnend-claude-blocks.lock/pid"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a healthy auto-arm must continue when the episode reset lock is busy"
  [ -z "$out" ] || fail "recovery contention produced an operator notice: $out"
  [ "$(epoch_outcome "$dir")" = failed-suppressed ] || fail "recovery contention must not record ordinary clean recovery"
  assert_present "$dir/state/.turnend-claude-blocks" "recovery contention partially cleared the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "recovery contention partially cleared the failure notice"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a later healthy auto-arm must complete the episode reset"
  assert_absent "$dir/state/.turnend-claude-blocks" "successful retry left the block budget"
  assert_absent "$dir/state/.claude-autoarm-failure-notified" "successful retry left the failure notice"
  pass "auto-arm: budget contention preserves the episode and forces a reset retry"
}

test_owner_mutex_contention_preserves_failure_episode_reset() {
  local dir out hook_pid status watcher watcher_id holder i
  dir=$(make_primary_dir "$TMP_ROOT/reset-owner-contention")
  : > "$dir/state/task.meta"
  : > "$dir/state/.turnend-claude-blocks"
  : > "$dir/state/.claude-autoarm-failure-notified"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_arm_fixture "$dir" reset-boundary
  sleep 60 &
  watcher=$!
  watcher_id=$(watcher_identity "$dir" "$watcher") || fail "could not identify reset-contention watcher"
  record_watcher_lock "$dir" "$watcher" "$watcher_id"
  touch "$dir/state/.last-watcher-beat"
  out="$dir/state/hook.out"
  run_autoarm_bg "$dir" "$out"
  hook_pid=$RUN_AUTOARM_BG_PID
  i=0
  while [ ! -e "$dir/state/arm-waiting" ]; do
    [ "$i" -lt 50 ] || fail "healthy owner never reached the reset boundary"
    sleep 0.05
    i=$((i + 1))
  done
  sleep 60 &
  holder=$!
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$holder" > "$dir/state/.claude-autoarm.lock/pid"
  : > "$dir/state/arm-release"
  wait "$hook_pid"; status=$?
  expect_code 0 "$status" "owner-mutex contention at reset must close quietly"
  [ ! -s "$out" ] || fail "owner-mutex contention at reset produced output: $(cat "$out")"
  assert_present "$dir/state/.turnend-claude-blocks" "contended reset deleted the block budget"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "contended reset deleted the failure notice"
  assert_present "$dir/state/.claude-autoarm-failure-alarmed" "contended reset deleted the attended alarm"
  kill "$holder" "$watcher" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  rm -rf "$dir/state/.claude-autoarm.lock"
  pass "auto-arm: owner-mutex contention preserves successor episode state"
}

test_arms_for_x_mode_poll_need_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/x-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/x-watch.check.sh"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an X-mode relay poll need must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the X-mode poll need"
  pass "auto-arm: X-mode poll need arms the cycle even with no tasks in flight"
}

test_arms_for_registered_custom_check_without_inflight() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/check-need")
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/state/issue-comments.check.sh"
  chmod 700 "$dir/state/issue-comments.check.sh"
  FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-check-register.sh" issue-comments >/dev/null \
    || fail "fm-check-register.sh could not register the custom check"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a registered custom check must keep the auto-arm active with zero tasks in flight"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm for the registered custom check"
  pass "auto-arm: a registered custom check arms the cycle even with no tasks in flight"
}

test_single_flight_admits_exactly_one_owner() {
  local dir rc1 rc2 count
  dir=$(make_primary_dir "$TMP_ROOT/single-flight")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" slow-actionable
  FM_HOME="$dir" "$FAKE_CLAUDE" -c '
    printf "%s\n" "$$" > "$FM_HOME/state/.lock"
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err1" &
    p1=$!
    printf "%s\n" "{\"session_id\":\"s\"}" | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" >/dev/null 2>"$FM_HOME/state/err2" &
    p2=$!
    wait "$p1"; echo $? > "$FM_HOME/state/rc1"
    wait "$p2"; echo $? > "$FM_HOME/state/rc2"
  '
  rc1=$(cat "$dir/state/rc1")
  rc2=$(cat "$dir/state/rc2")
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "concurrent firings must foreground exactly one arm, saw $count"
  { [ "$rc1" = 2 ] && [ "$rc2" = 0 ]; } || { [ "$rc1" = 0 ] && [ "$rc2" = 2 ]; } \
    || fail "exactly one firing must translate the close (rc 2) and the other must no-op (rc 0), got rc1=$rc1 rc2=$rc2"
  pass "auto-arm: concurrent firings admit one owner and one rewake translation"
}

# Claude terminates the complete async hook process tree when the declared hook
# timeout expires. The hook owner must turn that TERM into the same durable,
# rewake-triggering failure handoff as any other exhausted arm failure; leaving
# the generation at `arming` cannot recover without a later manual turn.
test_term_mid_arm_commits_failure_and_rewakes() {
  local dir out hook_pid i status=0
  dir=$(make_primary_dir "$TMP_ROOT/term-mid-arm")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" blocking-actionable
  out="$dir/state/autoarm.out"
  run_autoarm_bg "$dir" "$out"

  hook_pid=
  i=0
  while [ "$i" -lt 100 ]; do
    hook_pid=$(epoch_field "$dir" owner_pid)
    [ -n "$hook_pid" ] && [ -e "$dir/state/arm-ran" ] && break
    sleep 0.02
    i=$((i + 1))
  done
  [ -n "$hook_pid" ] || fail "auto-arm did not publish its generation owner before TERM"
  [ -e "$dir/state/arm-ran" ] || fail "auto-arm did not enter the foreground arm before TERM"

  kill -TERM "$hook_pid" 2>/dev/null || fail "could not TERM the foreground auto-arm owner"
  wait "$RUN_AUTOARM_BG_PID" || status=$?

  expect_code 2 "$status" "TERM mid-arm must preserve Claude's rewake-triggering hook exit"
  assert_present "$dir/state/.claude-autoarm-failure-notified" "TERM mid-arm left no durable failure marker"
  [ "$(epoch_outcome "$dir")" = failed ] \
    || fail "TERM mid-arm left a nonterminal ledger outcome: $(sed -n '1p' "$dir/state/.claude-autoarm-epoch")"
  assert_contains "$(cat "$out")" "firstmate watcher auto-arm INTERRUPTED" \
    "TERM mid-arm omitted the rewake failure banner"
  pass "auto-arm: TERM mid-arm commits a durable failure and exits 2 for rewake"
}

# --- abandoned single-flight claim recovery (legacy shim) ----------------------
# The 2026-08-14 lapse: one cycle armed, beat its beacon, delivered a single
# rewake, and exited, leaving its owner lock behind with a live pid. The single
# flight gate then turned every later firing into exit 0, so with two tasks in
# flight and a beacon 40 minutes cold nothing re-armed and both workers' reports
# sat unread until an operator drained the queue by hand. The lock alone is not
# enough to prove that: the ledger naming that same pid with a finished outcome,
# or a recorded pid-identity the live pid no longer matches, is what distinguishes
# an abandoned claim from one still deciding.
#
# These fixtures fabricate the LOCK-HOLDING claim shape a pre-generation build
# leaves behind, so this section pins the legacy shim: a live legacy owner
# still defers the gate, and an abandoned one is reclaimed once so the home
# re-arms - with an identity-verified live owner retired via TERM first, and
# an identityless one reclaimed without any signalling. The generation-claim
# section below pins the current contract.

# Fabricate a held owner lock: <dir> <pid> <role>. Plain-dir shape on purpose -
# the hook must reclaim whatever a crashed or blocked owner left behind.
record_autoarm_owner() {
  local dir=$1 pid=$2 role=${3:-autoarm}
  mkdir -p "$dir/state/.claude-autoarm.lock"
  printf '%s\n' "$pid" > "$dir/state/.claude-autoarm.lock/pid"
  printf '%s\n' "$role" > "$dir/state/.claude-autoarm.lock/role"
}

# Record the pid-identity a claim leaves inside its own lock: <dir> <pid>. The
# claim writes the identity of the process that took the lock, so passing a pid
# OTHER than the lock's own reproduces pid reuse - the recorded claimant is gone
# and an unrelated live process now answers to its number.
record_autoarm_owner_identity() {
  local dir=$1 pid=$2 identity
  identity=$(fm_test_pid_identity "$pid") || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" > "$dir/state/.claude-autoarm.lock/pid-identity"
}

# <dir> <epoch-seq> <owner-pid> <outcome>, aged well past any freshness window.
record_autoarm_epoch() {
  local dir=$1 seq=$2 owner=$3 outcome=$4
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=1\n' "$seq" "$owner" "$outcome" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
}

epoch_field() {
  local dir=$1 field=$2
  sed -n "s/^.*[[:space:]]\{0,1\}$field=\([A-Za-z0-9_-]*\).*\$/\1/p" \
    "$dir/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_abandoned_owner_claim_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/abandoned-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_epoch "$dir" 464 "$pid" rewake
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "an identityless abandoned owner must be reclaimed without being signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose ledger outcome is already terminal must be reclaimed, not deferred to forever"
  [ -e "$dir/state/arm-ran" ] || fail "abandoned claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "reclaimed cycle did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "reclaimed cycle did not record its own outcome: $(epoch_outcome "$dir")"
  [ "$(epoch_field "$dir" owner_pid)" != "$pid" ] || fail "reclaimed ledger still names the abandoned owner"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left its serialization mutex behind"
  pass "auto-arm: an abandoned owner claim is reclaimed so a lapsed cycle re-arms"
}

# An interrupted reclaim leaves the abandoned-claim mutex linked to a dead
# owner. The next reclaim must reap it directly, never by nesting another
# .steal.steal mutex around it.
test_abandoned_claim_reclaim_reaps_dead_steal_without_nesting() {
  local dir out status pid holder lnbin lnlog i
  dir=$(make_primary_dir "$TMP_ROOT/abandoned-claim-dead-steal")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_epoch "$dir" 464 "$pid" rewake
  FM_STATE_OVERRIDE="$dir/state" bash -c '
    . "$1"
    fm_lock_try_create "$2" || exit 7
    exec sleep 30
  ' _ "$dir/bin/fm-wake-lib.sh" "$dir/state/.claude-autoarm.lock.steal" >/dev/null 2>&1 &
  holder=$!
  i=0
  while [ "$i" -lt 50 ] && [ ! -s "$dir/state/.claude-autoarm.lock.steal/pid" ]; do
    sleep 0.02
    i=$((i + 1))
  done
  kill -KILL "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  assert_present "$dir/state/.claude-autoarm.lock.steal" "fixture did not leave a dead-owner steal mutex"
  lnbin="$dir/lnbin"
  lnlog="$dir/ln.log"
  mkdir -p "$lnbin"
  cat > "$lnbin/ln" <<'SH'
#!/usr/bin/env bash
last=
for arg do last=$arg; done
printf '%s\n' "$last" >> "$FM_TEST_LN_LOG"
exec /bin/ln "$@"
SH
  chmod +x "$lnbin/ln"
  : > "$lnlog"
  out=$(PATH="$lnbin:$PATH" FM_TEST_LN_LOG="$lnlog" run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a dead-owner steal mutex must not keep an abandoned claim unrecoverable"
  [ -e "$dir/state/arm-ran" ] || fail "dead-owner steal mutex left the home unarmed with work in flight"
  ! grep -q '\.steal\.steal$' "$lnlog" \
    || fail "reclaiming past a dead steal owner created a nested steal marker: $(tr '\n' ' ' < "$lnlog")"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left the dead steal mutex behind"
  pass "auto-arm: an abandoned-claim reclaim reaps a dead steal mutex without nesting"
}

test_arming_claim_with_fresh_beacon_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # An owner foregrounds the arm for the whole watcher cycle, so an old "arming"
  # entry is still in progress while its watcher keeps beating the beacon.
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a legacy claim still arming under a fresh beacon must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an arming claim lost its owner lock"
  pass "auto-arm: a legacy owner still arming is never reclaimed while its watcher keeps beating"
}

# The other legitimate legacy arming shape: a claim that JUST started arming
# after a real lapse, so the beacon is long stale but the entry is fresh. The
# arm's bounded startup window must never be stolen out from under it.
test_fresh_arming_claim_with_stale_beacon_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/fresh-arming-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=%s\n' "$pid" "$(date +%s)" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a freshly arming legacy claim must keep the single-flight gate closed even after a long lapse"
  [ -z "$out" ] || fail "deferring to a fresh arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a fresh arming claim was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "a fresh arming claim lost its owner lock"
  pass "auto-arm: a fresh legacy arming claim is never reclaimed while its startup window is still open"
}

test_claim_not_named_by_the_ledger_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/unnamed-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  # A fresh claimant holds the lock before it writes "arming", so until it does
  # the ledger still names the PREVIOUS owner. Requiring the two pids to match is
  # what keeps that window from being mistaken for abandonment.
  record_autoarm_epoch "$dir" 464 999 rewake
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live claim the ledger does not name is unproven and must be left alone"
  [ -z "$out" ] || fail "deferring to an unnamed claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a claim the ledger does not name was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "an unproven claim lost its owner lock"
  pass "auto-arm: a live claim the ledger does not name is never reclaimed"
}

# The same unrecoverable lapse, reached where the ledger cannot prove it: a session
# teardown kills the claim's whole process group before it records any outcome, so
# the entry still reads "arming" while the recorded pid is later handed to an
# unrelated live process. Only the identity the claim recorded inside its own lock
# separates that from a real arm in progress, so keep the beacon fresh here: this
# case must reclaim on the identity leg alone, not the stuck-arming leg. The
# reclaim must not signal the unrelated live process that inherited the number.
test_pid_reused_arming_claim_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/reused-pid-arming")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$$" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "the unrelated live process inheriting the number must never be signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a claim whose recorded identity no longer matches its live pid must be reclaimed, arming entry or not"
  [ -e "$dir/state/arm-ran" ] || fail "a reused-pid claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "reclaimed cycle did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  assert_absent "$dir/state/.claude-autoarm.lock.steal" "reclaim left its serialization mutex behind"
  pass "auto-arm: a claim whose pid was reused is reclaimed even while its ledger entry still reads arming"
}

# The other ledger-blind shape: no ledger at all (a fresh or hand-cleared home)
# plus a reused pid. Without the recorded identity nothing proves abandonment, so
# every later firing exits at the lock and the home never re-arms.
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/reused-pid-no-ledger")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$$" || fail "could not record a claim pid-identity"
  assert_absent "$dir/state/.claude-autoarm-epoch" "this case must start with no ledger at all"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a reused-pid claim with no ledger to consult must still be reclaimed"
  [ -e "$dir/state/arm-ran" ] || fail "a reused-pid claim with no ledger left the home unarmed"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "reclaimed cycle did not record its own outcome: $(epoch_outcome "$dir")"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaimed cycle left an owner lock behind"
  pass "auto-arm: a reused-pid claim is reclaimed even with no ledger entry to prove it"
}

# The negative control for the identity leg: a claim whose recorded identity still
# matches the process holding the lock is genuinely in flight, so an arm that has
# legitimately been running for hours - its watcher beating the whole time - must
# keep the single-flight gate closed.
test_identity_matched_arming_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/identity-matched-arming")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "an identity-matched claim still arming must keep the single-flight gate closed"
  [ -z "$out" ] || fail "deferring to an identity-matched arming claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an identity-matched arming claim was stolen and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the arming ledger entry"
  assert_present "$dir/state/.claude-autoarm.lock" "an identity-matched arming claim lost its owner lock"
  pass "auto-arm: an identity-matched owner still arming is never reclaimed"
}

test_terminal_check_claim_is_never_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/terminal-check-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  # The synchronous guard takes the same lock under its own role while it decides
  # the attended fail-open. Reclaiming that would race the guard's own decision.
  record_autoarm_owner "$dir" "$pid" terminal-check
  record_autoarm_epoch "$dir" 464 "$pid" failed-suppressed
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "the guard's own terminal-check claim must never be reclaimed by the arm hook"
  [ -z "$out" ] || fail "deferring to a terminal-check claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "a terminal-check claim was stolen and double-armed"
  assert_present "$dir/state/.claude-autoarm.lock" "a terminal-check claim lost its owner lock"
  pass "auto-arm: the guard's terminal-check claim is never reclaimed"
}

# A proven-stuck legacy owner that is still ALIVE and identity-verified is
# retired with TERM before its lock is removed, because old-build code cannot
# re-check generations and would otherwise resume and act after supersession.
test_stuck_live_legacy_owner_is_retired_and_reclaimed() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/legacy-term")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a proven-stuck identity-verified live legacy owner must be retired and reclaimed"
  kill -0 "$pid" 2>/dev/null && fail "the stuck legacy owner was reclaimed without being retired"
  wait "$pid" 2>/dev/null || true
  [ -e "$dir/state/arm-ran" ] || fail "the reclaimed home did not re-arm"
  assert_contains "$out" "firstmate watcher wake" "the reclaimed cycle must still translate its wake"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaim left the legacy owner lock behind"
  pass "auto-arm: a stuck live legacy owner is retired via TERM and its lock reclaimed"
}

# The SIGSTOP counterfactual: a stopped legacy owner survives the bounded
# retirement wait with TERM queued, and the reclaim must proceed anyway - a
# pending TERM on the verified owner is retirement-safe because delivery
# precedes any further user code when the process continues.
test_stopped_legacy_owner_is_reclaimed_with_term_pending() {
  local dir out status pid i
  dir=$(make_primary_dir "$TMP_ROOT/legacy-term-stopped")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_owner "$dir" "$pid"
  record_autoarm_owner_identity "$dir" "$pid" || fail "could not record a claim pid-identity"
  record_autoarm_epoch "$dir" 464 "$pid" arming
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  kill -STOP "$pid" 2>/dev/null || fail "could not stop the legacy owner fixture"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a stopped legacy owner with TERM queued must not block the reclaim forever"
  [ -e "$dir/state/arm-ran" ] || fail "the reclaimed home did not re-arm past the stopped owner"
  assert_absent "$dir/state/.claude-autoarm.lock" "reclaim left the stopped owner's lock behind"
  kill -CONT "$pid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 40 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -0 "$pid" 2>/dev/null && fail "the queued TERM did not retire the owner on continue"
  wait "$pid" 2>/dev/null || true
  pass "auto-arm: a SIGSTOPped legacy owner is reclaimed with TERM pending and dies on continue"
}

# --- generation claims: optimistic single-flight and supersession --------------
# The current claim is the two-line ledger entry itself (line 1 the classic
# epoch record, line 2 the owner's MANDATORY pid-identity); no lock is held
# across arming or output. A live open claim defers every firing; a stuck,
# dead, identity-mismatched, identityless, or finished claim is superseded by
# taking the next generation; a superseded owner goes completely silent.

# Fabricate a v2 generation claim: <dir> <gen> <owner-pid> <outcome>
# <identity-pid>. The identity of <identity-pid> is recorded as line 2 (the
# claim's own pid for a matched claim, another pid to reproduce pid reuse).
record_autoarm_v2_claim() {
  local dir=$1 gen=$2 owner=$3 outcome=$4 identity_pid=$5 identity
  identity=$(fm_test_pid_identity "$identity_pid") || return 1
  [ -n "$identity" ] || return 1
  printf 'epoch=%s owner_pid=%s outcome=%s updated_at=1\n%s\n' \
    "$gen" "$owner" "$outcome" "$identity" > "$dir/state/.claude-autoarm-epoch"
}

# A live open generation claim needs no lock to keep the gate closed: the
# ledger alone defers a concurrent firing, however old the entry, while the
# watcher keeps beating the beacon.
test_open_generation_claim_defers_without_any_lock() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-open-claim")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  assert_absent "$dir/state/.claude-autoarm.lock" "this case must start with no owner lock at all"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live open generation claim must keep the single-flight gate closed with no lock held"
  [ -z "$out" ] || fail "deferring to an open generation claim produced output: $out"
  assert_absent "$dir/state/arm-ran" "an open generation claim was superseded and double-armed"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "deferred firing rewrote the open claim's ledger entry"
  pass "auto-arm: a live open generation claim defers concurrent firings with no lock held"
}

# The 2026-08-26 watcher flap in the generation model: a live, identity-matched
# owner whose ledger entry and watcher beacon are both older than grace is
# stuck, and the next firing supersedes it by taking the next generation.
test_stuck_generation_claim_is_superseded_and_rearms() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-stuck-claim")
  : > "$dir/state/task1.meta"
  : > "$dir/state/task2.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "a live owner stuck arming past grace with a beacon just as stale must be superseded, not deferred to forever"
  [ -e "$dir/state/arm-ran" ] || fail "a stuck generation claim left the home unarmed with work in flight"
  assert_contains "$out" "firstmate watcher wake" "the superseding generation must still translate its wake"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "superseding claim did not advance the frozen ledger: $(epoch_field "$dir" epoch)"
  [ "$(epoch_field "$dir" owner_pid)" != "$pid" ] || fail "superseding claim left the stuck owner on the ledger"
  assert_absent "$dir/state/.claude-autoarm.lock" "the generation claim left a lock held after finishing"
  pass "auto-arm: a hung generation owner with no watcher beat is superseded so re-arming self-heals"
}

# Identity is mandatory at read time: a bare identityless one-line arming
# ledger naming an unrelated live pid is NOT an open claim - it must neither
# defer the hook nor survive as the current entry, whatever the beacon says.
test_identityless_ledger_never_defers() {
  local dir out status pid
  dir=$(make_primary_dir "$TMP_ROOT/v2-identityless-ledger")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" actionable
  sleep 60 &
  pid=$!
  printf 'epoch=464 owner_pid=%s outcome=arming updated_at=1\n' "$pid" \
    > "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  : > "$dir/state/.last-watcher-beat"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  kill -0 "$pid" 2>/dev/null || fail "the unrelated live pid on an identityless ledger must never be signalled"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 2 "$status" "an identityless arming ledger must be superseded, never deferred to"
  [ -e "$dir/state/arm-ran" ] || fail "an identityless ledger left the home unarmed"
  [ "$(epoch_field "$dir" epoch)" -gt 464 ] || fail "the identityless entry was not superseded: $(epoch_field "$dir" epoch)"
  pass "auto-arm: an identityless arming ledger never defers the gate (reused-pid loophole closed)"
}

# A superseded owner must not start or attach another watcher: when its claim
# is superseded between arm attempts, the retry boundary goes silent instead
# of invoking the arm again.
test_superseded_owner_never_reinvokes_the_arm() {
  local dir out status count
  dir=$(make_primary_dir "$TMP_ROOT/v2-superseded-arm-boundary")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" supersede-then-fail
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an owner superseded between arm attempts must exit 0 silently"
  [ -z "$out" ] || fail "a superseded owner produced output at the arm boundary: $out"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "a superseded owner re-invoked the arm, saw $count arms"
  [ "$(epoch_field "$dir" epoch)" = 999 ] || fail "a superseded owner rewrote its successor's ledger entry: $(epoch_field "$dir" epoch)"
  pass "auto-arm: a superseded owner never re-invokes the arm and leaves its successor's claim untouched"
}

# End-to-end regression for all three concurrency edge classes at once, with a
# REAL hook process hung mid-arm:
#   1. no mutex across blocking steps - while owner A is mid-arm, a concurrent
#      firing B defers promptly instead of queueing on any lock;
#   2. stuck-owner supersession - once A's claim and the beacon age past grace
#      while A is still alive arming, firing C takes the next generation and
#      translates its own close (exit 2);
#   3. no double-translation - when A's arm finally returns, A finds itself
#      superseded and goes completely silent (exit 0, no banner, no ledger
#      write), so one supersession episode produces exactly one translation.
test_superseded_owner_goes_silent_and_never_double_translates() {
  local dir a_out a_pid b_out b_status c_out c_status a_status i count
  dir=$(make_primary_dir "$TMP_ROOT/v2-superseded-silence")
  : > "$dir/state/task1.meta"
  write_arm_fixture "$dir" blocking-actionable
  a_out="$dir/state/a.out"
  run_autoarm_bg "$dir" "$a_out"
  a_pid=$RUN_AUTOARM_BG_PID
  i=0
  while [ "$(epoch_outcome "$dir")" != arming ] || [ ! -e "$dir/state/arm-ran" ]; do
    [ "$i" -lt 50 ] || fail "owner A never published its arming claim"
    sleep 0.1
    i=$((i + 1))
  done
  b_out=$(run_autoarm "$dir" 2>/dev/null); b_status=$?
  expect_code 0 "$b_status" "a firing during a live open claim must defer promptly (no mutex is held across arming)"
  [ -z "$b_out" ] || fail "deferring firing produced output: $b_out"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 1 ] || fail "deferring firing must not arm, saw $count arms"
  # A is still alive mid-arm; make its claim stuck-shaped.
  kill -0 "$a_pid" 2>/dev/null || fail "owner A finished before the supersession could be exercised"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch"
  touch -t 202001010000 "$dir/state/.last-watcher-beat"
  c_out=$(run_autoarm "$dir" 2>/dev/null); c_status=$?
  expect_code 2 "$c_status" "the superseding generation must translate its own close"
  assert_contains "$c_out" "firstmate watcher wake" "the superseding generation must carry the rewake banner"
  wait "$a_pid"
  a_status=$?
  expect_code 0 "$a_status" "the superseded owner must exit 0 instead of double-translating"
  [ ! -s "$a_out" ] || fail "the superseded owner emitted output after losing its generation: $(cat "$a_out")"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "the superseded owner advanced the ledger past its successor: $(epoch_field "$dir" epoch)"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the superseding generation's outcome was overwritten: $(epoch_outcome "$dir")"
  count=$(wc -l < "$dir/state/arm-ran" | tr -d ' ')
  [ "$count" -eq 2 ] || fail "expected exactly the owner and superseder arms, saw $count"
  pass "auto-arm: a superseded owner goes silent - one supersession episode, one translation, no held mutex"
}

test_need_vanished_mid_cycle_closes_quietly() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/vanished")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" meta-vanishes
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "an actionable close after the fleet went idle must not rewake"
  [ -z "$out" ] || fail "vanished-need close produced output: $out"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "epoch must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: need vanishing mid-cycle closes without a rewake"
}

test_afk_mid_cycle_suppresses_rewake() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/afk-mid")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" afk-appears
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "AFK appearing mid-cycle must suppress the primary rewake"
  [ -z "$out" ] || fail "AFK-suppressed close produced output: $out"
  [ "$(epoch_outcome "$dir")" = afk ] || fail "epoch must record outcome=afk, got: $(epoch_outcome "$dir")"
  pass "auto-arm: mid-cycle AFK hands triage to the daemon with no rewake"
}

test_active_in_marked_secondmate_home() {
  local dir out status
  dir=$(make_secondmate_dir "$TMP_ROOT/secondmate")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a marked secondmate home must get the same active auto-arm as the main primary"
  [ -e "$dir/state/arm-ran" ] || fail "hook did not arm in a marked secondmate home"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "secondmate epoch must record outcome=rewake"
  pass "auto-arm: active in a marked secondmate home"
}

test_long_poll_grace_reaches_arm_wrapper() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/long-poll-grace")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" records-grace
  out=$(unset FM_GUARD_GRACE; FM_POLL=900 run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an unverified close without a healthy watcher must still fail closed"
  [ -e "$dir/state/arm-received-grace" ] || fail "arm wrapper never recorded FM_GUARD_GRACE"
  [ "$(cat "$dir/state/arm-received-grace")" = 960 ] || fail "arm wrapper must see the poll-derived grace (900+60), got: $(cat "$dir/state/arm-received-grace")"
  pass "auto-arm: a long FM_POLL with FM_GUARD_GRACE unset reaches fm-watch-arm.sh with the derived grace"
}

# Supervision-host fixture variants, installed per test as
# <dir>/bin/fm-supervision-host.sh. Each run appends its pid to state/host-ran
# and records the environment the hook handed it.
write_host_fixture() {
  local dir=$1 kind=$2
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "$$" >> "$FM_HOME/state/host-ran"\n'
    printf 'printf "gen=%%s owner=%%s primary=%%s mode=%%s\\n" "${FM_SUPERVISION_HOST_AUTOARM_GEN:-}" "${FM_SUPERVISION_HOST_OWNER_PID:-}" "${FM_SUPERVISION_HOST_PRIMARY:-}" "${1:-}" > "$FM_HOME/state/host-env"\n'
    case "$kind" in
      boundary)
        printf "printf 'pending:downtime:fixture-generation\\n' > \"\$FM_HOME/state/.watcher-down\"\n"
        printf 'touch "$FM_HOME/state/.last-watcher-beat"\n'
        printf "printf 'supervision-host: cycle boundary - fixture\\n'\n"
        ;;
      handed-back)
        printf "printf 'pending:downtime:fixture-generation\\n' > \"\$FM_HOME/state/.watcher-down\"\n"
        printf 'touch "$FM_HOME/state/.last-watcher-beat"\n'
        printf "printf 'signal: fixture.status\\n'\n"
        printf "printf 'supervision-host: the away session could not take this wake: fixture; this wake is yours\\n'\n"
        ;;
      stood-down)
        printf "printf 'supervision-host stood down: this session no longer owns supervision\\n'\n"
        ;;
      handed-back-many)
        cat <<'SH'
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'signal: fixture-%s.status\n' "$i"; done
printf 'supervision-host: the away session could not take this wake: fixture; relay its outcomes\n'
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'supervision-host: outcome %s for demo [routine]: fixture %s\n' "$i" "$i"; done
SH
        ;;
      crash)
        printf 'kill -KILL "$$"\n'
        ;;
    esac
    printf 'exit 0\n'
  } > "$dir/bin/fm-supervision-host.sh"
  chmod +x "$dir/bin/fm-supervision-host.sh"
}

test_host_absent_flag_keeps_the_arm() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-flag-absent")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_host_fixture "$dir" boundary
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a home without config/supervision-host must still rewake from the arm"
  assert_present "$dir/state/arm-ran" "a home without config/supervision-host did not run the arm"
  [ ! -e "$dir/state/host-ran" ] || fail "a home without config/supervision-host ran the supervision host"
  assert_contains "$out" "stale: fixture-win actionable" "the arm's reason must still reach the rewake"
  pass "auto-arm: without config/supervision-host the hook runs the arm exactly as before"
}

test_host_boundary_rewakes_with_the_host_line() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-boundary")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_host_fixture "$dir" boundary
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a host cycle boundary must rewake main"
  assert_contains "$out" "firstmate watcher wake" "the host close must carry the wake banner"
  assert_contains "$out" "supervision-host: cycle boundary - fixture" "the rewake must carry the host's line"
  [ ! -e "$dir/state/arm-ran" ] || fail "an opted-in home ran the plain arm instead of the host"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "a host boundary must record outcome=rewake, got: $(epoch_outcome "$dir")"
  [ "$(sed -n 's/^.* mode=//p' "$dir/state/host-env")" = park ] || fail "the host was not run in park mode: $(cat "$dir/state/host-env")"
  [ "$(sed -n 's/^.* primary=\([a-z]*\) .*$/\1/p' "$dir/state/host-env")" = claude ] \
    || fail "the host was not told its primary harness: $(cat "$dir/state/host-env")"
  [ "$(sed -n 's/^gen=\([0-9]*\) .*$/\1/p' "$dir/state/host-env")" = "$(epoch_field "$dir" epoch)" ] \
    || fail "the host was not bound to the hook's generation: $(cat "$dir/state/host-env") vs $(head -n 1 "$dir/state/.claude-autoarm-epoch")"
  [ "$(sed -n 's/^.* owner=\([0-9]*\) .*$/\1/p' "$dir/state/host-env")" = "$(epoch_field "$dir" owner_pid)" ] \
    || fail "the host was not bound to the hook's owner pid: $(cat "$dir/state/host-env")"
  pass "auto-arm: an opted-in home runs the host bound to its generation, and a host line rewakes like a wake"
}

test_host_handback_under_away_record_is_not_a_return() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-handback")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk-contract"
  write_host_fixture "$dir" handed-back
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a wake the host hands back must rewake main"
  assert_contains "$out" "signal: fixture.status" "the handed-back wake must carry its reason line"
  assert_contains "$out" "supervision-host: the away session could not take this wake" "the handed-back wake must say why"
  assert_contains "$out" "not from the captain: it is not a return" "an away-posture handback must say it is not the captain's return"
  pass "auto-arm: a wake the host hands back under the away record says it is automatic supervision, not a return"
}

# Quiet mode's record is a present captain (bin/fm-afk-contract.sh AWAY OR
# QUIET), so a wake the host hands back beside it carries no away note.
test_host_handback_beside_a_quiet_record_carries_no_away_note() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-handback-quiet")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  FM_HOME="$dir" FM_AFK_MODE=quiet "$ROOT/bin/fm-afk-contract.sh" enter --words 'keep routine wakes off my main' >/dev/null 2>&1 \
    || fail "fixture: could not record quiet mode"
  write_host_fixture "$dir" handed-back
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a wake the host hands back must rewake main"
  assert_contains "$out" "signal: fixture.status" "the handed-back wake must carry its reason line"
  assert_not_contains "$out" "not a return" "a present captain's rewake must not call itself away-posture supervision"
  pass "auto-arm: a wake the host hands back beside a quiet record carries no away note"
}

test_plain_arm_banner_keeps_its_wake_line_cap() {
  local dir out expected
  dir=$(make_primary_dir "$TMP_ROOT/plain-banner")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable-many
  out=$(run_autoarm "$dir" 2>/dev/null)
  expected=$(
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    for i in 1 2 3 4 5 6 7 8; do printf 'stale: fixture-%s actionable\n' "$i"; done
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  )
  [ "$out" = "$expected" ] || fail "the plain-arm rewake banner changed:"$'\n'"$out"
  pass "auto-arm: without the host the rewake banner is unchanged, eight wake lines at most"
}

test_host_handback_carries_every_host_line() {
  local dir out status expected
  dir=$(make_primary_dir "$TMP_ROOT/host-many")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  write_host_fixture "$dir" handed-back-many
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "a wake the host hands back must rewake main"
  expected=$(
    printf 'supervision-host: the away session could not take this wake: fixture; relay its outcomes\n'
    for i in 1 2 3 4 5 6 7 8 9 10; do printf 'supervision-host: outcome %s for demo [routine]: fixture %s\n' "$i" "$i"; done
  )
  [ "$(printf '%s\n' "$out" | grep '^supervision-host:')" = "$expected" ] \
    || fail "the rewake must carry every host line in the host's order:"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | grep -c '^signal: ')" -eq 8 ] || fail "the host's wake lines must keep the eight-line cap:"$'\n'"$out"
  assert_contains "$out" "signal: fixture-8.status" "the first eight wake lines must reach the rewake"
  pass "auto-arm: a host handback delivers every host line, while its wake lines keep their cap"
}

test_host_stand_down_is_silent() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-stand-down")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  write_host_fixture "$dir" stood-down
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 0 "$status" "a host that stood down must not rewake main"
  [ -z "$out" ] || fail "a host stand-down printed to main: $out"
  [ "$(wc -l < "$dir/state/host-ran" | tr -d ' ')" -eq 1 ] || fail "a host stand-down was retried"
  [ "$(epoch_outcome "$dir")" = clean ] || fail "a host stand-down must record outcome=clean, got: $(epoch_outcome "$dir")"
  pass "auto-arm: a host that stood down closes silently without a retry"
}

test_host_crash_is_retried_then_reported() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/host-crash")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  write_host_fixture "$dir" crash
  # A live watcher with a fresh beacon would pass the plain arm's benign-close
  # check; a host that died has no owner for such a cycle, so it must not.
  printf 'pending:downtime:fixture-generation\n' > "$dir/state/.watcher-down"
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "an exhausted host crash must notify"
  [ "$(wc -l < "$dir/state/host-ran" | tr -d ' ')" -eq 2 ] || fail "a crashed host was not retried within the attempt bound"
  assert_contains "$out" "auto-arm FAILED" "an exhausted host crash must deliver the failure notice"
  assert_contains "$out" "The supervision host (config/supervision-host) ran these cycles; its last one exited 137 without a wake." \
    "the failure notice must name the host and its exit"
  pass "auto-arm: a host that died without a close is retried, then reported as a failure"
}

# A model running the hook by hand mid-turn (for example to read its help) is a
# tool process under the lock-owning session with no Stop payload. Any argument
# must print help or refuse before anything is armed, since the host or arm it
# starts would be owned by that short-lived process.
test_arguments_never_arm() {
  local dir arg rc out before after before_contents after_contents status
  dir=$(make_primary_dir "$TMP_ROOT/help-mode")
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host"
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_host_fixture "$dir" boundary
  # The fake session writes state/.lock itself; everything else must be untouched.
  for arg in --help -h --bogus; do
    before=$(find "$dir/state" -mindepth 1 ! -name .lock | sort)
    before_contents=$(find "$dir/state" -type f ! -name .lock -exec cksum {} + | sort)
    rc=0
    out=$(FM_HOME="$dir" "$FAKE_CLAUDE" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        "$FM_HOME/bin/fm-claude-stop-autoarm.sh" "$1" </dev/null 2>"$FM_HOME/help-stderr"
      ' _ "$arg") || rc=$?
    after=$(find "$dir/state" -mindepth 1 ! -name .lock | sort)
    after_contents=$(find "$dir/state" -type f ! -name .lock -exec cksum {} + | sort)
    case "$arg" in
      --bogus)
        expect_code 2 "$rc" "an unknown argument must be refused"
        assert_contains "$(cat "$dir/help-stderr")" "unknown argument: --bogus" "the refusal must name the argument"
        ;;
      *)
        expect_code 0 "$rc" "$arg must exit 0"
        assert_contains "$out" "Usage: fm-claude-stop-autoarm.sh" "$arg must print usage to stdout"
        ;;
    esac
    [ ! -e "$dir/state/host-ran" ] || fail "$arg started the supervision host"
    [ ! -e "$dir/state/arm-ran" ] || fail "$arg ran the arm"
    [ "$before" = "$after" ] || fail "$arg changed state: before=[$before] after=[$after]"
    [ "$before_contents" = "$after_contents" ] || fail "$arg changed state file contents: before=[$before_contents] after=[$after_contents]"
  done
  out=$(run_autoarm "$dir" 2>/dev/null); status=$?
  expect_code 2 "$status" "the ordinary Stop path must still rewake from the host"
  assert_present "$dir/state/host-ran" "the ordinary Stop path did not run the host in the same home"
  pass "auto-arm: --help, -h, and an unknown argument arm nothing; the Stop path still arms"
}

test_fm_lock_status_still_works_with_shared_lib() {
  local out
  out=$(FM_HOME="$TMP_ROOT/lock-status-home" bash "$ROOT/bin/fm-lock.sh" status 2>&1)
  assert_contains "$out" "lock: free" "fm-lock.sh status must keep working after the session-lock lib extraction"
  pass "fm-lock: shared session-lock lib preserves the status path"
}

# --- StopFailure mode ----------------------------------------------------------
# Claude Code fires StopFailure INSTEAD of Stop when a turn ends on an API error,
# so the Stop-owned re-arm never runs.
# These cases drive --stop-failure with the hook input Claude Code 2.1.278
# delivers (error, last_assistant_message, transcript_path) and a transcript whose
# API-error entry carries the fields that version records, trimmed to what the
# hook reads. The live proof that the harness fires only StopFailure on
# an API-error turn end, only Stop on a normal one, and starts a turn on the
# asyncRewake exit 2 is tests/fm-claude-stopfailure-live-e2e.test.sh. Test knobs
# keep every wait to a few seconds.

write_failure_transcript() {  # <path> <error> <message> [resets-at-epoch]
  local path=$1 error=$2 message=$3 reset=${4:-null} ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  {
    printf '{"type":"queue-operation","operation":"dequeue","timestamp":"%s"}\n' "$ts"
    printf '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"Stop hook feedback"},"timestamp":"%s"}\n' "$ts"
    jq -nc --arg ts "$ts" --arg error "$error" --arg text "$message" --argjson reset "$reset" \
      '{type: "assistant", message: {model: "<synthetic>", role: "assistant", content: [{type: "text", text: $text}]},
        error: $error, isApiErrorMessage: true, apiErrorStatus: 429, timestamp: $ts}
       + (if $reset == null then {} else {quotaLimits: {status: "rejected", resetsAt: $reset, rateLimitType: "seven_day"}} end)'
    printf '{"type":"system","subtype":"turn_duration","timestamp":"%s"}\n' "$ts"
  } > "$path"
}

stopfailure_payload() {  # <transcript-path> <error> <message>
  jq -nc --arg t "$1" --arg e "$2" --arg m "$3" \
    '{session_id: "sess-stopfailure", transcript_path: $t, cwd: "/", hook_event_name: "StopFailure", error: $e, last_assistant_message: $m}'
}

# Every StopFailure knob, overridable per case through SF_* variables. An
# empty SF_SLACK leaves the script's own default slack in force.
stopfailure_env() {
  printf '%s\n' \
    "FM_CLAUDE_STOPFAILURE_RESET_SLACK=${SF_SLACK-1}" \
    "FM_CLAUDE_STOPFAILURE_BACKOFF_BASE=${SF_BASE:-1}" \
    "FM_CLAUDE_STOPFAILURE_BACKOFF_MAX=${SF_BACKOFF_MAX:-4}" \
    "FM_CLAUDE_STOPFAILURE_POLL=${SF_POLL:-1}" \
    "FM_CLAUDE_STOPFAILURE_MAX_WAIT=${SF_CAP:-30}"
}

# One fake Claude session: it takes the home lock, then runs <script> as its
# child, so every hook the script starts shares that session's ancestry exactly
# as the hooks of one Claude process do. $SF_HOOK and $SF_STOP are the two
# registrations' commands.
run_session() {  # <dir> <script>
  local dir=$1 script=$2 rc=0
  # shellcheck disable=SC2046 # one KEY=value word per knob
  env FM_HOME="$dir" $(stopfailure_env) \
    SF_HOOK="$dir/bin/fm-claude-stop-autoarm.sh --stop-failure" \
    SF_STOP="$dir/bin/fm-claude-stop-autoarm.sh" \
    "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$FM_HOME/state/.lock"
'"$script" </dev/null 2>&1 || rc=$?
  return "$rc"
}

# Run one StopFailure hook in the foreground of a fresh session. Prints the
# hook's collected output; the hook's exit status is the return status.
run_stopfailure() {  # <dir> <payload>
  local dir=$1
  printf '%s\n' "$2" > "$dir/state/sf-payload"
  run_session "$dir" '$SF_HOOK < "$FM_HOME/state/sf-payload"'
}

sf_record_field() {  # <dir> <field>
  awk -v field="$2" 'NR == 1 { for (i = 1; i <= NF; i++) if (index($i, field "=") == 1) { print substr($i, length(field) + 2); exit } }' \
    "$1/state/.claude-stopfailure" 2>/dev/null || true
}

# Wait until the StopFailure generation has claimed the ledger and started its
# wait, so a case can act on the sleeper mid-wait.
wait_for_sf_claim() {  # <dir>
  local n=0
  while [ "$n" -lt 100 ]; do
    [ "$(epoch_outcome "$1")" = stopfailure-wait ] && return 0
    sleep 0.1
    n=$((n + 1))
  done
  fail "the StopFailure hook never claimed its waiting generation"
}

test_stopfailure_tracked_registration_routes_one_recovery() {
  local dir payload reset cmd out rc_line
  dir=$(make_primary_dir "$TMP_ROOT/sf-registration")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  printf 'pending:downtime:fixture-generation\n' > "$dir/state/.watcher-down"
  # Record which registration reached which entry point, then run the real
  # auto-arm; the synchronous guard is only recorded, because its cooperation
  # with the auto-arm has its own suite.
  mv "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.real.sh"
  cat > "$dir/bin/fm-claude-stop-autoarm.sh" <<'SH'
#!/usr/bin/env bash
printf 'fm-claude-stop-autoarm.sh%s\n' "${1:+ $1}" >> "$FM_HOME/state/entrypoints"
exec "$(dirname "$0")/fm-claude-stop-autoarm.real.sh" "$@"
SH
  cat > "$dir/bin/fm-turnend-guard.sh" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'fm-turnend-guard.sh%s\n' "${1:+ $1}" >> "$FM_HOME/state/entrypoints"
SH
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-turnend-guard.sh"
  reset=$(( $(date +%s) + 2 ))
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "You've hit your weekly limit" "$reset"
  payload=$(stopfailure_payload "$dir/state/transcript.jsonl" rate_limit "You've hit your weekly limit")
  printf '%s\n' "$payload" > "$dir/state/sf-payload"
  printf '%s\n' '{"session_id":"sess-stopfailure","stop_hook_active":true}' > "$dir/state/stop-payload"
  # A turn that ends on an API error: the harness runs every StopFailure
  # registration and nothing registered for Stop.
  : > "$dir/state/commands"
  while IFS= read -r cmd; do
    printf '%s\n' "$cmd" >> "$dir/state/commands"
  done < <(jq -r '.hooks.StopFailure[]?.hooks[]?.command' "$ROOT/.claude/settings.json")
  out=$(run_session "$dir" '
    while IFS= read -r cmd; do
      CLAUDE_PROJECT_DIR="$FM_HOME" bash -c "$cmd" < "$FM_HOME/state/sf-payload"
      printf "rc=%s\n" "$?"
    done < "$FM_HOME/state/commands"')
  [ "$(grep -c '^rc=' <<<"$out")" -eq 1 ] || fail "expected exactly one StopFailure registration, got: $out"
  rc_line=$(grep '^rc=' <<<"$out")
  [ "$rc_line" = rc=2 ] || fail "the API-error turn end must schedule exactly one recovery rewake, got $rc_line: $out"
  [ "$(grep -c '^firstmate recovery turn' <<<"$out")" -eq 1 ] || fail "expected exactly one recovery banner: $out"
  [ "$(cat "$dir/state/entrypoints")" = 'fm-claude-stop-autoarm.sh --stop-failure' ] \
    || fail "an API-error turn end must reach only the StopFailure mode, got: $(cat "$dir/state/entrypoints")"
  assert_absent "$dir/state/arm-ran" "the StopFailure recovery must leave re-arming to the recovery turn's Stop"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the recovery must commit outcome=rewake, got: $(epoch_outcome "$dir")"

  # The recovery turn ends normally: the harness runs every Stop registration,
  # and the ordinary auto-arm re-arms without ever entering StopFailure mode.
  : > "$dir/state/entrypoints"
  : > "$dir/state/commands"
  while IFS= read -r cmd; do
    printf '%s\n' "$cmd" >> "$dir/state/commands"
  done < <(jq -r '.hooks.Stop[]?.hooks[]?.command' "$ROOT/.claude/settings.json")
  out=$(run_session "$dir" '
    while IFS= read -r cmd; do
      CLAUDE_PROJECT_DIR="$FM_HOME" bash -c "$cmd" < "$FM_HOME/state/stop-payload"
      printf "rc=%s\n" "$?"
    done < "$FM_HOME/state/commands"')
  assert_no_grep '--stop-failure' "$dir/state/entrypoints" "a normal turn end reached the StopFailure mode"
  assert_grep 'fm-turnend-guard.sh --claude' "$dir/state/entrypoints" "a normal turn end must still run the turn-end guard"
  assert_grep 'fm-claude-stop-autoarm.sh' "$dir/state/entrypoints" "a normal turn end must still run the Stop auto-arm"
  assert_present "$dir/state/arm-ran" "the recovery turn's Stop must resume the watcher"
  assert_not_contains "$out" "firstmate recovery turn" "a normal turn end must not start another recovery"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "the recovery turn's Stop must take the next generation, got: $(epoch_field "$dir" epoch)"
  pass "StopFailure: the tracked registration turns one API-error turn end into one recovery, and the next normal Stop re-arms"
}

test_stopfailure_waits_for_reset_then_rewakes_once() {
  local dir out status reset started elapsed
  dir=$(make_primary_dir "$TMP_ROOT/sf-reset")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  printf 'pending:downtime:fixture-generation\n' > "$dir/state/.watcher-down"
  reset=$(( $(date +%s) + 3 ))
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "You've hit your weekly limit · resets 5am (Etc/UTC)" "$reset"
  started=$(date +%s)
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/transcript.jsonl" rate_limit "You've hit your weekly limit · resets 5am (Etc/UTC)")"); status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 2 "$status" "a usage-limit turn end must end in exactly one recovery rewake"
  [ "$elapsed" -ge 3 ] || fail "the recovery fired ${elapsed}s after the failure, before the limit's resetsAt"
  [ "$(grep -c '^firstmate recovery turn' <<<"$out")" -eq 1 ] || fail "expected exactly one recovery banner: $out"
  assert_contains "$out" "(rate_limit)" "the banner must name the API error"
  assert_contains "$out" "for the usage limit to reset at" "the banner must say it waited for the reset"
  assert_contains "$out" "bin/fm-wake-drain.sh" "the banner must direct the drain-first protocol"
  assert_contains "$out" "do NOT run bin/fm-watch-arm.sh" "the banner must leave re-arming to the Stop hook"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the recovery must commit outcome=rewake"
  [ "$(epoch_field "$dir" session_pid)" = "$(cat "$dir/state/.lock")" ] \
    || fail "the recovery rewake must bind the lock-owning session"
  [ "$(epoch_field "$dir" recovery_generation)" = fixture-generation ] \
    || fail "the recovery rewake must bind the watcher recovery generation"
  [ "$(sf_record_field "$dir" basis)" = resetsAt ] || fail "the wait must come from quotaLimits.resetsAt, got: $(sf_record_field "$dir" basis)"
  [ "$(sf_record_field "$dir" reset)" = "$reset" ] || fail "the record must keep the reset time"
  [ "$(sf_record_field "$dir" decision)" = rewake ] || fail "the record must end on the rewake decision"
  assert_absent "$dir/state/arm-ran" "the StopFailure mode must never arm the watcher itself"
  assert_absent "$dir/state/.claude-autoarm.lock" "no lock may be left behind"
  pass "StopFailure: a usage limit waits until its resetsAt, then commits one bound rewake and exits 2 once"
}

test_stopfailure_failed_recovery_waits_again() {
  local dir out status started elapsed payload
  dir=$(make_primary_dir "$TMP_ROOT/sf-again")
  : > "$dir/state/task.meta"
  printf 'pending:downtime:fixture-generation\n' > "$dir/state/.watcher-down"
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "limit" "$(( $(date +%s) + 1 ))"
  payload=$(stopfailure_payload "$dir/state/transcript.jsonl" rate_limit "limit")
  out=$(run_stopfailure "$dir" "$payload"); status=$?
  expect_code 2 "$status" "the first failure must recover once"
  [ "$(sf_record_field "$dir" attempt)" = 1 ] || fail "the first recovery must be attempt 1"

  # The recovery turn itself hits the same limit, whose reported reset is now
  # already past: the next recovery must wait out the attempt-2 backoff, not
  # retry at once.
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "limit" "$(( $(date +%s) - 30 ))"
  started=$(date +%s)
  out=$(SF_BASE=2 SF_BACKOFF_MAX=8 run_stopfailure "$dir" "$payload"); status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 2 "$status" "a failed recovery turn must lead to exactly one later recovery"
  [ "$(sf_record_field "$dir" attempt)" = 2 ] || fail "a failed recovery must advance to attempt 2, got: $(sf_record_field "$dir" attempt)"
  [ "$(sf_record_field "$dir" basis)" = backoff ] || fail "a past reset must fall back to the backoff"
  [ "$(sf_record_field "$dir" wait)" = 4 ] || fail "attempt 2 must double the backoff base, got wait=$(sf_record_field "$dir" wait)"
  [ "$elapsed" -ge 4 ] || fail "a failed recovery was retried after ${elapsed}s instead of waiting its backoff"

  # Once more, now with a reset that is again in the future but sooner than the
  # attempt-3 backoff: a known reset never shortens a repeated failure's wait.
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "limit" "$(( $(date +%s) + 1 ))"
  started=$(date +%s)
  out=$(SF_BASE=1 SF_BACKOFF_MAX=4 run_stopfailure "$dir" "$payload"); status=$?
  elapsed=$(( $(date +%s) - started ))
  expect_code 2 "$status" "the third failure must still recover exactly once"
  [ "$(sf_record_field "$dir" attempt)" = 3 ] || fail "attempt must keep growing across failed recoveries"
  [ "$(sf_record_field "$dir" wait)" = 4 ] || fail "a repeated failure must wait at least its backoff, got wait=$(sf_record_field "$dir" wait)"
  [ "$elapsed" -ge 4 ] || fail "attempt 3 fired after ${elapsed}s, before its backoff"
  pass "StopFailure: a recovery turn that fails again waits again with a growing backoff instead of retrying at once"
}

test_stopfailure_stands_down_under_afk() {
  local dir out status
  dir=$(make_primary_dir "$TMP_ROOT/sf-afk")
  : > "$dir/state/task.meta"
  : > "$dir/state/.afk"
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "limit" "$(( $(date +%s) + 1 ))"
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/transcript.jsonl" rate_limit "limit")"); status=$?
  expect_code 0 "$status" "the StopFailure hook must stand down while the away daemon owns supervision"
  [ -z "$out" ] || fail "an away-mode stand-down produced output: $out"
  assert_absent "$dir/state/.claude-autoarm-epoch" "an away-mode stand-down must not claim the ledger"

  dir=$(make_primary_dir "$TMP_ROOT/sf-afk-mid")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "limit" "$(( $(date +%s) + 20 ))"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" rate_limit "limit")" > "$dir/state/sf-payload"
  out=$(run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    : > "$FM_HOME/state/.afk"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "sf_rc=0" "away mode entered mid-wait must stand the recovery down"
  [ ! -s "$dir/state/sf.out" ] || fail "an away-mode stand-down mid-wait produced output: $(cat "$dir/state/sf.out")"
  [ "$(epoch_outcome "$dir")" = stopfailure-wait ] || fail "a stand-down gives ownership up and must leave the ledger untouched, got: $(epoch_outcome "$dir")"
  [ "$(sf_record_field "$dir" reason)" = afk ] || fail "the record must name away mode as the reason"
  pass "StopFailure: stands down under away mode, at the failure and when away mode starts mid-wait"
}

test_stopfailure_halts_on_errors_a_retry_cannot_fix() {
  local dir out status error started
  for error in authentication_failed billing_error model_not_found invalid_request; do
    dir=$(make_primary_dir "$TMP_ROOT/sf-halt-$error")
    : > "$dir/state/task.meta"
    write_failure_transcript "$dir/state/transcript.jsonl" "$error" "auth"
    started=$(date +%s)
    out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/transcript.jsonl" "$error" "auth")"); status=$?
    expect_code 0 "$status" "$error must not start a recovery turn that can only fail again"
    [ $(( $(date +%s) - started )) -le 2 ] || fail "$error must stand down at once, not wait"
    [ -z "$out" ] || fail "$error stand-down produced output: $out"
    [ "$(epoch_outcome "$dir")" = stopfailure-halt ] || fail "$error must close the ledger on a terminal halt generation, got: $(epoch_outcome "$dir")"
    [ "$(sf_record_field "$dir" decision)" = halt ] || fail "$error must be recorded as a halt decision"
  done
  pass "StopFailure: errors only the captain can fix are recorded and never looped"
}

# Hooks are ordered by when they started: each claims only by compare-and-swap
# against the ledger generation it saw at its start. An older hook still
# settling, before its claim, is superseded by anything published meanwhile.
# Its settle is held open by a transcript whose failure entry has not landed.
write_settling_payload() {  # <dir> <name> <error>
  printf '%s\n' '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"wake"}}' \
    > "$1/state/$2.jsonl"
  printf '%s\n' "$(stopfailure_payload "$1/state/$2.jsonl" "$3" "$3")" > "$1/state/$2-payload"
}

# The session-script prelude: start the older hook and wait until it is
# settling, which is before it could have claimed anything.
SF_OLDER_SETTLING='
    $SF_HOOK < "$FM_HOME/state/old-payload" > "$FM_HOME/state/old.out" 2>&1 &
    old=$!
    n=0
    while [ "$n" -lt 200 ] && ! pgrep -P "$old" -f "sleep 0.5" >/dev/null 2>&1; do sleep 0.02; n=$((n + 1)); done
    [ -e "$FM_HOME/state/.claude-autoarm-epoch" ] && printf "older-claimed-early\n"
'

test_stopfailure_claims_only_from_the_generation_it_started_on() {
  local dir out
  # The interleaving under test: an older transient hook is still before its
  # claim when a newer halt is published; it must never start a recovery turn.
  dir=$(make_primary_dir "$TMP_ROOT/sf-cas-halt")
  : > "$dir/state/task.meta"
  write_settling_payload "$dir" old overloaded
  printf '%s\n' "$(stopfailure_payload "$dir/state/none.jsonl" authentication_failed "Please run /login")" > "$dir/state/halt-payload"
  out=$(SF_BASE=1 SF_BACKOFF_MAX=1 run_session "$dir" "$SF_OLDER_SETTLING"'
    $SF_HOOK < "$FM_HOME/state/halt-payload" > "$FM_HOME/state/halt.out" 2>&1
    printf "halt_rc=%s\n" "$?"
    wait "$old"
    printf "old_rc=%s\n" "$?"')
  assert_not_contains "$out" "older-claimed-early" "the older hook must still be before its claim when the halt lands"
  assert_contains "$out" "halt_rc=0" "the halt must stand down"
  assert_contains "$out" "old_rc=0" "an older hook must not start a recovery turn after a newer halt"
  [ ! -s "$dir/state/old.out" ] || fail "the older hook started a recovery turn after a newer halt: $(cat "$dir/state/old.out")"
  [ "$(epoch_outcome "$dir")" = stopfailure-halt ] || fail "the ledger must end on the halt, got: $(epoch_outcome "$dir")"
  [ "$(epoch_field "$dir" epoch)" = 1 ] || fail "the older hook must not claim past the halt"

  # The reverse order: a transient failure that starts after the halt is its
  # own event and recovers once.
  dir=$(make_primary_dir "$TMP_ROOT/sf-cas-halt-then-transient")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/none.jsonl" authentication_failed "Please run /login")" > "$dir/state/halt-payload"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/new-payload"
  out=$(SF_BASE=1 SF_BACKOFF_MAX=1 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/halt-payload" > "$FM_HOME/state/halt.out" 2>&1
    printf "halt_rc=%s\n" "$?"
    $SF_HOOK < "$FM_HOME/state/new-payload" > "$FM_HOME/state/new.out" 2>&1
    printf "new_rc=%s\n" "$?"')
  assert_contains "$out" "halt_rc=0" "the halt must stand down"
  assert_contains "$out" "new_rc=2" "a failure that starts after the halt must still recover once"
  [ "$(grep -c '^firstmate recovery turn' "$dir/state/new.out")" -eq 1 ] || fail "the later failure must emit one banner"
  [ "$(epoch_outcome "$dir")" = rewake ] && [ "$(epoch_field "$dir" epoch)" = 2 ] \
    || fail "the later failure must claim past the halt and commit its rewake, got: $(sed -n 1p "$dir/state/.claude-autoarm-epoch")"

  # A newer waiter published while the older hook is still before its claim:
  # exactly one recovery, the newer one.
  dir=$(make_primary_dir "$TMP_ROOT/sf-cas-newer-waiter")
  : > "$dir/state/task.meta"
  write_settling_payload "$dir" old overloaded
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/new-payload"
  out=$(SF_BASE=1 SF_BACKOFF_MAX=1 run_session "$dir" "$SF_OLDER_SETTLING"'
    $SF_HOOK < "$FM_HOME/state/new-payload" > "$FM_HOME/state/new.out" 2>&1
    printf "new_rc=%s\n" "$?"
    wait "$old"
    printf "old_rc=%s\n" "$?"')
  assert_not_contains "$out" "older-claimed-early" "the older hook must still be before its claim when the newer one claims"
  assert_contains "$out" "new_rc=2" "the newer failure must own the one recovery"
  assert_contains "$out" "old_rc=0" "the older hook must stand down at its claim"
  [ ! -s "$dir/state/old.out" ] || fail "the older hook started a second recovery turn: $(cat "$dir/state/old.out")"
  [ "$(epoch_field "$dir" epoch)" = 1 ] || fail "the older hook must not claim past the newer waiter"

  # A Stop-owned cycle completing while the older hook is still before its claim.
  dir=$(make_primary_dir "$TMP_ROOT/sf-cas-stop-cycle")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_settling_payload "$dir" old overloaded
  out=$(SF_BASE=1 SF_BACKOFF_MAX=1 run_session "$dir" "$SF_OLDER_SETTLING"'
    printf "%s\n" "{\"session_id\":\"s\",\"stop_hook_active\":false}" | $SF_STOP > "$FM_HOME/state/stop.out" 2>&1
    printf "stop_rc=%s\n" "$?"
    wait "$old"
    printf "old_rc=%s\n" "$?"')
  assert_not_contains "$out" "older-claimed-early" "the older hook must still be before its claim when the Stop cycle completes"
  assert_contains "$out" "stop_rc=2" "the ordinary Stop must translate its own wake"
  assert_contains "$out" "old_rc=0" "the older hook must stand down after a completed Stop cycle"
  [ ! -s "$dir/state/old.out" ] || fail "the older hook started a recovery turn after a Stop cycle: $(cat "$dir/state/old.out")"
  [ "$(epoch_outcome "$dir")" = rewake ] && [ "$(epoch_field "$dir" epoch)" = 1 ] \
    || fail "the ledger must end on the Stop cycle's own rewake, got: $(sed -n 1p "$dir/state/.claude-autoarm-epoch")"
  pass "StopFailure: a hook claims only from the generation it started on, so a newer halt, waiter, or Stop cycle supersedes it"
}

# The compare-and-swap covers the WHOLE ledger record a hook saw at its start,
# not one field: a predecessor that commits within its own generation, or any
# other same-generation write, means another hook owns the outcome.
test_stopfailure_claims_only_against_the_whole_record_it_started_on() {
  local dir out kind base
  # The reported case: the predecessor commits its rewake, in its own
  # generation, while the second hook is still settling.
  dir=$(make_primary_dir "$TMP_ROOT/sf-record-predecessor-rewake")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/first-payload"
  write_settling_payload "$dir" old overloaded
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/first-payload" > "$FM_HOME/state/first.out" 2>&1 &
    first=$!
    until grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.05; done
    FM_CLAUDE_STOPFAILURE_BACKOFF_BASE=1 $SF_HOOK < "$FM_HOME/state/old-payload" > "$FM_HOME/state/second.out" 2>&1 &
    second=$!
    n=0
    while [ "$n" -lt 200 ] && ! pgrep -P "$second" -f "sleep 0.5" >/dev/null 2>&1; do sleep 0.02; n=$((n + 1)); done
    kill -TERM "$first"
    wait "$first"
    printf "first_rc=%s\n" "$?"
    grep -q "^epoch=1 .*outcome=rewake" "$FM_HOME/state/.claude-autoarm-epoch" && kill -0 "$second" 2>/dev/null \
      && printf "committed-while-second-settled\n"
    wait "$second"
    printf "second_rc=%s\n" "$?"')
  assert_contains "$out" "committed-while-second-settled" "the predecessor must commit while the second hook is still before its claim"
  assert_contains "$out" "first_rc=2" "the predecessor owns the one recovery"
  assert_contains "$out" "second_rc=0" "the second hook must not start a second recovery"
  [ ! -s "$dir/state/second.out" ] || fail "a second recovery followed the predecessor's rewake: $(cat "$dir/state/second.out")"
  [ "$(epoch_outcome "$dir")" = rewake ] && [ "$(epoch_field "$dir" epoch)" = 1 ] \
    || fail "the ledger must end on the predecessor's rewake, got: $(sed -n 1p "$dir/state/.claude-autoarm-epoch")"

  # Every same-generation change a writer can make, one fresh home each, run
  # side by side: each outcome an owned write can record, and the identity line.
  for kind in rewake failed failed-suppressed clean afk identity; do
    base="$TMP_ROOT/sf-record-same-gen-$kind"
    make_primary_dir "$base" >/dev/null
    : > "$base/state/task.meta"
    printf 'epoch=5 owner_pid=9999999 outcome=stopfailure-wait updated_at=1\nfixture-identity\n' > "$base/state/.claude-autoarm-epoch"
    write_settling_payload "$base" old overloaded
    (
      out=$(SF_BASE=1 SF_BACKOFF_MAX=1 SF_KIND="$kind" run_session "$base" '
        $SF_HOOK < "$FM_HOME/state/old-payload" > "$FM_HOME/state/old.out" 2>&1 &
        old=$!
        n=0
        while [ "$n" -lt 200 ] && ! pgrep -P "$old" -f "sleep 0.5" >/dev/null 2>&1; do sleep 0.02; n=$((n + 1)); done
        grep -q "^epoch=5 " "$FM_HOME/state/.claude-autoarm-epoch" || printf "older-claimed-early\n"
        if [ "$SF_KIND" = identity ]; then
          printf "epoch=5 owner_pid=9999999 outcome=stopfailure-wait updated_at=1\nrewritten-identity\n" > "$FM_HOME/state/.claude-autoarm-epoch"
        else
          printf "epoch=5 owner_pid=9999999 outcome=%s updated_at=1\nfixture-identity\n" "$SF_KIND" > "$FM_HOME/state/.claude-autoarm-epoch"
        fi
        wait "$old"
        printf "old_rc=%s\n" "$?"')
      printf '%s\n' "$out" > "$base/state/session.out"
    ) &
  done
  wait
  for kind in rewake failed failed-suppressed clean afk identity; do
    base="$TMP_ROOT/sf-record-same-gen-$kind"
    out=$(cat "$base/state/session.out")
    assert_not_contains "$out" "older-claimed-early" "$kind: the hook must still be before its claim when the record changes"
    assert_contains "$out" "old_rc=0" "$kind: a same-generation change must stop the claim"
    [ ! -s "$base/state/old.out" ] || fail "$kind: a recovery started after a same-generation change: $(cat "$base/state/old.out")"
    [ "$(epoch_field "$base" epoch)" = 5 ] || fail "$kind: the hook claimed past a changed record"
  done

  # A stand-down is not a claim: an older waiter giving up while a newer hook
  # settles must not leave the newer failure without its recovery.
  dir=$(make_primary_dir "$TMP_ROOT/sf-record-standdown")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/first-payload"
  write_settling_payload "$dir" old overloaded
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/first-payload" > "$FM_HOME/state/first.out" 2>&1 &
    first=$!
    until grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.05; done
    FM_CLAUDE_STOPFAILURE_BACKOFF_BASE=1 $SF_HOOK < "$FM_HOME/state/old-payload" > "$FM_HOME/state/second.out" 2>&1 &
    second=$!
    n=0
    while [ "$n" -lt 200 ] && ! pgrep -P "$second" -f "sleep 0.5" >/dev/null 2>&1; do sleep 0.02; n=$((n + 1)); done
    printf "%s\n" "{\"type\":\"user\",\"origin\":{\"kind\":\"human\"},\"message\":{\"role\":\"user\",\"content\":\"status?\"}}" >> "$FM_HOME/state/transcript.jsonl"
    wait "$first"
    printf "first_rc=%s\n" "$?"
    grep -q "^epoch=1 " "$FM_HOME/state/.claude-autoarm-epoch" && kill -0 "$second" 2>/dev/null \
      && printf "stood-down-while-second-settled\n"
    wait "$second"
    printf "second_rc=%s\n" "$?"')
  assert_contains "$out" "stood-down-while-second-settled" "the older waiter must stand down while the newer hook is still before its claim"
  assert_contains "$out" "first_rc=0" "the older waiter must stand down on the newer turn"
  assert_contains "$out" "second_rc=2" "the newer failure must still get its one recovery after an older waiter stands down"
  [ "$(grep -c '^firstmate recovery turn' "$dir/state/second.out")" -eq 1 ] || fail "the newer failure must emit one banner"
  [ ! -s "$dir/state/first.out" ] || fail "the stood-down waiter produced output: $(cat "$dir/state/first.out")"
  pass "StopFailure: a hook claims only against the whole record it started on, and a stand-down never blocks a newer failure"
}

# A transient failure's recovery is already waiting when a later turn fails on
# an error only the captain can fix: that waiter must never start its turn.
test_stopfailure_halt_supersedes_a_waiting_recovery() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/sf-halt-supersedes")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  printf '%s\n' "$(stopfailure_payload "$dir/state/none.jsonl" authentication_failed "Please run /login")" > "$dir/state/halt-payload"
  out=$(SF_BASE=4 SF_BACKOFF_MAX=4 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    $SF_HOOK < "$FM_HOME/state/halt-payload" > "$FM_HOME/state/halt.out" 2>&1
    printf "halt_rc=%s\n" "$?"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "halt_rc=0" "the halt must stand down"
  assert_contains "$out" "sf_rc=0" "the earlier waiter must stand down instead of recovering"
  [ ! -s "$dir/state/sf.out" ] || fail "the superseded waiter started a recovery turn: $(cat "$dir/state/sf.out")"
  [ ! -s "$dir/state/halt.out" ] || fail "the halt produced output: $(cat "$dir/state/halt.out")"
  [ "$(epoch_outcome "$dir")" = stopfailure-halt ] || fail "the ledger must end on the halt, got: $(epoch_outcome "$dir")"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "the halt must take the generation after the waiter's"
  [ "$(sf_record_field "$dir" decision)" = halt ] || fail "the record must end on the halt decision"
  pass "StopFailure: a halt-class failure supersedes a waiting recovery, so no recovery turn starts"
}

test_stopfailure_defers_to_live_continuity() {
  local dir out status pid identity
  dir=$(make_primary_dir "$TMP_ROOT/sf-open-claim")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  sleep 60 &
  pid=$!
  record_autoarm_v2_claim "$dir" 464 "$pid" arming "$pid" || fail "could not record a v2 claim"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")"); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a live Stop-owned cycle already owns continuity"
  [ -z "$out" ] || fail "deferring to a live cycle produced output: $out"
  [ "$(epoch_field "$dir" epoch)" = 464 ] || fail "the StopFailure hook superseded a live open Stop-owned claim"

  dir=$(make_primary_dir "$TMP_ROOT/sf-healthy-watcher")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  sleep 60 &
  pid=$!
  identity=$(watcher_identity "$dir" "$pid") || fail "could not identify the live watcher"
  record_watcher_lock "$dir" "$pid" "$identity"
  touch "$dir/state/.last-watcher-beat"
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")"); status=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  expect_code 0 "$status" "a healthy watcher already owns continuity"
  [ -z "$out" ] || fail "deferring to a healthy watcher produced output: $out"
  assert_absent "$dir/state/.claude-autoarm-epoch" "a healthy watcher must leave the ledger untouched"

  dir=$(make_primary_dir "$TMP_ROOT/sf-alarmed")
  : > "$dir/state/task.meta"
  : > "$dir/state/.claude-autoarm-failure-alarmed"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")"); status=$?
  expect_code 0 "$status" "the attended fail-open alarm suppresses automatic continuation"
  assert_absent "$dir/state/.claude-autoarm-epoch" "an alarmed episode must leave the ledger untouched"
  pass "StopFailure: defers to a live Stop cycle, a healthy watcher, and the attended alarm"
}

test_stopfailure_superseded_by_ordinary_stop_goes_silent() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/sf-superseded-by-stop")
  : > "$dir/state/task.meta"
  write_arm_fixture "$dir" actionable
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    printf "%s\n" "{\"session_id\":\"s\",\"stop_hook_active\":false}" | $SF_STOP > "$FM_HOME/state/stop.out" 2>&1
    printf "stop_rc=%s\n" "$?"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "stop_rc=2" "an ordinary Stop during the wait must arm and translate its own wake"
  assert_contains "$out" "sf_rc=0" "the superseded StopFailure generation must exit 0"
  assert_present "$dir/state/arm-ran" "an ordinary Stop must never defer to a waiting StopFailure claim"
  [ ! -s "$dir/state/sf.out" ] || fail "a superseded StopFailure generation produced output: $(cat "$dir/state/sf.out")"
  assert_contains "$(cat "$dir/state/stop.out")" "firstmate watcher wake" "the ordinary Stop must deliver its wake"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the ledger must end on the ordinary Stop's own rewake"
  [ "$(epoch_field "$dir" epoch)" = 2 ] || fail "the ordinary Stop must have taken the next generation"
  pass "StopFailure: an ordinary Stop supersedes a waiting recovery, which then stays silent"
}

test_stopfailure_newer_failure_supersedes_older_waiter() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/sf-superseded-by-failure")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf1.out" 2>&1 &
    sf1=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    FM_CLAUDE_STOPFAILURE_BACKOFF_BASE=1 $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf2.out" 2>&1
    printf "sf2_rc=%s\n" "$?"
    wait "$sf1"
    printf "sf1_rc=%s\n" "$?"')
  assert_contains "$out" "sf2_rc=2" "the newer failure must own the one recovery"
  assert_contains "$out" "sf1_rc=0" "the older waiter must stand down"
  [ ! -s "$dir/state/sf1.out" ] || fail "the superseded waiter produced output: $(cat "$dir/state/sf1.out")"
  [ "$(grep -c '^firstmate recovery turn' "$dir/state/sf2.out")" -eq 1 ] || fail "the newer failure must emit one banner"
  pass "StopFailure: a newer failure supersedes an older waiter, so two failures still yield one recovery turn"
}

test_stopfailure_turn_in_progress_stands_down() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/sf-turn-started")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    printf "%s\n" "{\"type\":\"user\",\"origin\":{\"kind\":\"human\"},\"message\":{\"role\":\"user\",\"content\":\"status?\"}}" >> "$FM_HOME/state/transcript.jsonl"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "sf_rc=0" "a turn that began after the failure must stand the recovery down"
  [ ! -s "$dir/state/sf.out" ] || fail "a recovery landed on a turn in progress: $(cat "$dir/state/sf.out")"
  [ "$(sf_record_field "$dir" reason)" = turn_started ] || fail "the record must name the turn in progress"

  # Control: entries that are not a new turn (the failure's own bookkeeping, a
  # local command's output) must not stand the recovery down.
  dir=$(make_primary_dir "$TMP_ROOT/sf-turn-control")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=2 SF_BACKOFF_MAX=2 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    printf "%s\n" "{\"type\":\"system\",\"subtype\":\"local_command\",\"content\":\"<local-command-stdout></local-command-stdout>\"}" >> "$FM_HOME/state/transcript.jsonl"
    printf "%s\n" "{\"type\":\"assistant\",\"isApiErrorMessage\":true,\"error\":\"overloaded\",\"message\":{\"content\":[]}}" >> "$FM_HOME/state/transcript.jsonl"
    printf "%s\n" "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\"}]}}" >> "$FM_HOME/state/transcript.jsonl"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "sf_rc=2" "entries that start no turn must not suppress the recovery"
  [ "$(grep -c '^firstmate recovery turn' "$dir/state/sf.out")" -eq 1 ] || fail "the control recovery must emit one banner"
  pass "StopFailure: a turn that began after the failure stands the recovery down, other transcript entries do not"
}

test_stopfailure_reset_text_and_bounded_fallbacks() {
  local dir out status now hour minute h12 suffix reset wait_s
  # The error text alone names the reset: "resets h:mmam|pm (<zone>)", here two
  # hours ahead in UTC. The cap keeps the case short and must say so.
  dir=$(make_primary_dir "$TMP_ROOT/sf-text")
  : > "$dir/state/task.meta"
  now=$(date +%s)
  hour=$(( (10#$(date -u +%H) + 2) % 24 ))
  minute=$(date -u +%M)
  suffix=am
  [ "$hour" -lt 12 ] || suffix=pm
  h12=$(( hour % 12 ))
  [ "$h12" -ne 0 ] || h12=12
  out=$(SF_CAP=1 run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/none.jsonl" rate_limit "You've hit your session limit · resets ${h12}:${minute}${suffix} (UTC)")"); status=$?
  expect_code 2 "$status" "a reset read from the error text must still recover once"
  [ "$(sf_record_field "$dir" basis)" = message ] || fail "the wait must come from the error text, got: $(sf_record_field "$dir" basis)"
  reset=$(sf_record_field "$dir" reset)
  [ "$reset" -ge $(( now + 7200 - 120 )) ] && [ "$reset" -le $(( now + 7200 + 5 )) ] \
    || fail "the parsed reset $reset is not two hours after $now"
  [ "$(sf_record_field "$dir" wait)" = 1 ] || fail "the wait must be capped"
  assert_contains "$out" "as long as one wait may last although the usage limit resets at" "a capped wait must say the turn may be rejected again"

  # With no override, the wait runs to the reset plus the default 180s slack,
  # so Claude Code's own continue-at-usage-limit can start its turn first.
  dir=$(make_primary_dir "$TMP_ROOT/sf-default-slack")
  : > "$dir/state/task.meta"
  reset=$(( $(date +%s) + 10 ))
  write_failure_transcript "$dir/state/transcript.jsonl" rate_limit "limit" "$reset"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" rate_limit "limit")" > "$dir/state/sf-payload"
  out=$(SF_SLACK='' SF_CAP=1000 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    until grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.05; done
    kill -TERM "$sf"
    wait "$sf"')
  wait_s=$(sf_record_field "$dir" wait)
  [ "$wait_s" -ge 188 ] && [ "$wait_s" -le 190 ] || fail "the default slack must wait until 180s past the reset, got wait=$wait_s"

  # A dated reset is more than a day away: wait the cap.
  dir=$(make_primary_dir "$TMP_ROOT/sf-text-far")
  : > "$dir/state/task.meta"
  out=$(SF_CAP=1 run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/none.jsonl" rate_limit "You've hit your weekly limit · resets Sep 23, 5am (Etc/UTC)")"); status=$?
  expect_code 2 "$status" "a far reset must still recover once per cap window"
  [ "$(sf_record_field "$dir" basis)" = far ] || fail "a dated reset must be read as more than a day away"
  [ "$(sf_record_field "$dir" wait)" = 1 ] || fail "a far reset must wait the cap"

  # No readable reset at all, and a transient error: the bounded backoff.
  dir=$(make_primary_dir "$TMP_ROOT/sf-no-reset")
  : > "$dir/state/task.meta"
  out=$(SF_BASE=2 run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/none.jsonl" rate_limit "Request rejected (429)")"); status=$?
  expect_code 2 "$status" "an unreadable reset must fall back to a bounded backoff"
  [ "$(sf_record_field "$dir" basis)" = backoff ] || fail "an unreadable reset must use the backoff"
  [ "$(sf_record_field "$dir" wait)" = 2 ] || fail "the first backoff must be the base"
  dir=$(make_primary_dir "$TMP_ROOT/sf-transient")
  : > "$dir/state/task.meta"
  out=$(SF_BASE=2 run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/none.jsonl" some_future_error "?")"); status=$?
  expect_code 2 "$status" "an unrecognized error must be treated as transient"
  [ "$(sf_record_field "$dir" error)" = some_future_error ] || fail "the record must keep the error name"
  [ "$(sf_record_field "$dir" basis)" = backoff ] || fail "a transient error must use the backoff"
  pass "StopFailure: reads the reset from the error text, defaults to 180s of slack, waits the cap for a far reset, and backs off when unreadable"
}

test_stopfailure_signal_fires_recovery() {
  local dir out
  dir=$(make_primary_dir "$TMP_ROOT/sf-signal")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 100 ] && ! grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do sleep 0.1; n=$((n + 1)); done
    kill -TERM "$sf"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "sf_rc=2" "a host signal mid-wait must hand off one recovery rather than go blind"
  assert_contains "$(cat "$dir/state/sf.out")" "was interrupted by TERM" "the banner must say the wait was interrupted"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "the interrupted wait must commit its rewake"
  pass "StopFailure: HUP/TERM/INT mid-wait hand off the one recovery turn"
}

# The traps are live before the waiting claim is published: a signal that lands
# before the claim, or the instant it appears, still ends in the one recovery.
test_stopfailure_signal_around_the_claim_still_recovers() {
  local dir out
  # Before the claim: the failure's entry is not in the transcript yet, so the
  # hook is still settling (sleeping in half-second steps) when TERM arrives.
  dir=$(make_primary_dir "$TMP_ROOT/sf-signal-before-claim")
  : > "$dir/state/task.meta"
  printf '%s\n' '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"wake"}}' > "$dir/state/transcript.jsonl"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    n=0
    while [ "$n" -lt 200 ] && ! pgrep -P "$sf" -f "sleep 0.5" >/dev/null 2>&1; do sleep 0.02; n=$((n + 1)); done
    [ -e "$FM_HOME/state/.claude-autoarm-epoch" ] && printf "claimed-before-signal\n"
    kill -TERM "$sf"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_not_contains "$out" "claimed-before-signal" "the case must signal before the claim is published"
  assert_contains "$out" "sf_rc=2" "a signal before the claim must still end in one recovery"
  assert_contains "$(cat "$dir/state/sf.out")" "was interrupted by TERM" "the banner must say the wait was interrupted"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "a signal before the claim must still commit a rewake, got: $(epoch_outcome "$dir")"

  # The instant the claim appears.
  dir=$(make_primary_dir "$TMP_ROOT/sf-signal-at-claim")
  : > "$dir/state/task.meta"
  write_failure_transcript "$dir/state/transcript.jsonl" overloaded "overloaded"
  printf '%s\n' "$(stopfailure_payload "$dir/state/transcript.jsonl" overloaded "overloaded")" > "$dir/state/sf-payload"
  out=$(SF_BASE=30 SF_BACKOFF_MAX=30 run_session "$dir" '
    $SF_HOOK < "$FM_HOME/state/sf-payload" > "$FM_HOME/state/sf.out" 2>&1 &
    sf=$!
    until grep -q "outcome=stopfailure-wait" "$FM_HOME/state/.claude-autoarm-epoch" 2>/dev/null; do :; done
    kill -TERM "$sf"
    wait "$sf"
    printf "sf_rc=%s\n" "$?"')
  assert_contains "$out" "sf_rc=2" "a signal delivered immediately after the claim must still end in one recovery"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "a signal right after the claim must commit the rewake, got: $(epoch_outcome "$dir")"
  [ "$(grep -c '^firstmate recovery turn' "$dir/state/sf.out")" -eq 1 ] || fail "expected exactly one recovery banner"
  pass "StopFailure: a signal before the claim or the instant it is published still commits the one recovery"
}

test_stopfailure_inert_outside_the_owning_primary() {
  local base dir out status
  base="$TMP_ROOT/sf-crew-base"
  dir="$TMP_ROOT/sf-crew-wt"
  make_crewmate_worktree_dir "$base" "$dir" >/dev/null
  : > "$dir/state/task.meta"
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/none.jsonl" rate_limit "limit")"); status=$?
  expect_code 0 "$status" "a child worktree's StopFailure must stay inert"
  assert_absent "$dir/state/.claude-autoarm-epoch" "a child worktree must not claim"

  dir=$(make_primary_dir "$TMP_ROOT/sf-idle")
  out=$(run_stopfailure "$dir" "$(stopfailure_payload "$dir/state/none.jsonl" rate_limit "limit")"); status=$?
  expect_code 0 "$status" "an idle home needs no recovery turn"
  assert_absent "$dir/state/.claude-autoarm-epoch" "an idle home must not claim"

  dir=$(make_primary_dir "$TMP_ROOT/sf-no-lock")
  : > "$dir/state/task.meta"
  out=$(printf '%s\n' "$(stopfailure_payload "$dir/state/none.jsonl" rate_limit "limit")" \
    | FM_HOME="$dir" bash "$dir/bin/fm-claude-stop-autoarm.sh" --stop-failure 2>&1); status=$?
  expect_code 0 "$status" "a session that does not own the home lock must stay inert"
  assert_absent "$dir/state/.claude-autoarm-epoch" "a non-owning session must not claim"
  pass "StopFailure: inert in child worktrees, idle homes, and sessions that do not own the home"
}

test_inert_in_child_worktree
test_inert_without_session_lock
test_reclaims_stale_session_lock_before_arming
test_inert_when_lock_held_by_other_harness
test_inert_when_afk
test_stale_lock_recovery_preserves_afk_and_need_gates
test_resolves_outermost_claude_pid_in_nested_bgspare_chain
test_inert_when_fleet_idle
test_actionable_close_rewakes_with_reason
test_actionable_close_with_live_successor_rewakes_once
test_attached_cycle_end_starts_handling_successor
test_unconfirmed_handling_successor_still_rewakes
test_failed_close_rewakes_with_failure_banner
test_failed_cycles_notify_once_and_keep_retrying
test_failure_notice_marker_write_refuses_delivery_and_retries
test_unverified_clean_close_exhausts_retries
test_leftover_failure_episode_never_suppresses_actionable_wake
test_arm_deadline_derives_from_declared_timeout
test_real_cycle_closes_before_declared_timeout
test_benign_cycle_end_with_live_watcher_is_silent
test_positive_recovery_budget_contention_preserves_episode
test_owner_mutex_contention_preserves_failure_episode_reset
test_arms_for_x_mode_poll_need_without_inflight
test_arms_for_registered_custom_check_without_inflight
test_single_flight_admits_exactly_one_owner
test_term_mid_arm_commits_failure_and_rewakes
test_abandoned_owner_claim_is_reclaimed_and_rearms
test_abandoned_claim_reclaim_reaps_dead_steal_without_nesting
test_arming_claim_with_fresh_beacon_is_never_reclaimed
test_fresh_arming_claim_with_stale_beacon_is_never_reclaimed
test_claim_not_named_by_the_ledger_is_never_reclaimed
test_pid_reused_arming_claim_is_reclaimed_and_rearms
test_pid_reused_claim_with_no_ledger_is_reclaimed_and_rearms
test_identity_matched_arming_claim_is_never_reclaimed
test_terminal_check_claim_is_never_reclaimed
test_stuck_live_legacy_owner_is_retired_and_reclaimed
test_stopped_legacy_owner_is_reclaimed_with_term_pending
test_open_generation_claim_defers_without_any_lock
test_stuck_generation_claim_is_superseded_and_rearms
test_identityless_ledger_never_defers
test_superseded_owner_never_reinvokes_the_arm
test_superseded_owner_goes_silent_and_never_double_translates
test_need_vanished_mid_cycle_closes_quietly
test_afk_mid_cycle_suppresses_rewake
test_active_in_marked_secondmate_home
test_long_poll_grace_reaches_arm_wrapper
test_host_absent_flag_keeps_the_arm
test_host_boundary_rewakes_with_the_host_line
test_host_handback_under_away_record_is_not_a_return
test_host_handback_beside_a_quiet_record_carries_no_away_note
test_plain_arm_banner_keeps_its_wake_line_cap
test_host_handback_carries_every_host_line
test_host_stand_down_is_silent
test_host_crash_is_retried_then_reported
test_arguments_never_arm
test_fm_lock_status_still_works_with_shared_lib
test_stopfailure_tracked_registration_routes_one_recovery
test_stopfailure_waits_for_reset_then_rewakes_once
test_stopfailure_failed_recovery_waits_again
test_stopfailure_stands_down_under_afk
test_stopfailure_halts_on_errors_a_retry_cannot_fix
test_stopfailure_halt_supersedes_a_waiting_recovery
test_stopfailure_claims_only_from_the_generation_it_started_on
test_stopfailure_claims_only_against_the_whole_record_it_started_on
test_stopfailure_defers_to_live_continuity
test_stopfailure_superseded_by_ordinary_stop_goes_silent
test_stopfailure_newer_failure_supersedes_older_waiter
test_stopfailure_turn_in_progress_stands_down
test_stopfailure_reset_text_and_bounded_fallbacks
test_stopfailure_signal_fires_recovery
test_stopfailure_signal_around_the_claim_still_recovers
test_stopfailure_inert_outside_the_owning_primary
test_stands_down_only_on_pi_code_transcript_path
