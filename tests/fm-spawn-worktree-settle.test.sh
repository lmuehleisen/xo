#!/usr/bin/env bash
# Regression test for the fm-spawn.sh treehouse-get worktree-detection settle
# loop (bin/fm-spawn.sh, the `for _ in $(seq 1 60)` loop after `treehouse get`).
#
# On some tmux/WSL setups a brand-new window's pane_current_path transiently
# reports a stale, unrelated-but-real path on the very first poll, before the
# pane actually settles into the worktree treehouse get moved it to. That stale
# path still passes the loop's "differs from the project" check and
# validate_spawn_worktree's "is a real, distinct worktree" check (it IS a real
# git checkout, just the wrong one), so a naive single-read loop silently
# records the wrong worktree= in state/<id>.meta. This test simulates that
# transient-then-settled pane_current_path sequence with a fake tmux and
# asserts the recorded worktree resolves to the real, settled worktree, never
# the stale first read.
#
# The same loop has a second transient to survive: `treehouse get` reports the
# REPOSITORY's primary checkout as its own cwd while it is still preparing a
# slot. From a linked spawning home that path is not the project, so a poll
# comparing only against the project adopted it and the isolation guard then
# refused the launch. The cases below cover both the transient and the pane
# that never leaves the primary at all.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" || exit 1

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)
LEASE_TEST_TMUX_SOCKET=
LEASE_TEST_TMUX_BIN=
cleanup_settle() {
  if [ -n "$LEASE_TEST_TMUX_SOCKET" ]; then
    "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" kill-server 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_settle EXIT

# make_settle_fakebin <dir> builds a fake tmux whose `#{pane_current_path}`
# query returns FM_FAKE_PANE_STALE for the first FM_FAKE_PANE_STALE_READS
# calls, then FM_FAKE_PANE_PATH forever after - reproducing a pane that
# transiently reports a stale cwd before settling into the real worktree.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_command}"*) printf 'bash\n'; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
  *"#{pane_width}"*) printf '200\n'; exit 0 ;;
  *"#{pane_current_path}"*)
    if [ -n "${FM_FAKE_DROP_CD_ENTER:-}" ] && [ ! -f "$FM_FAKE_PANE_COUNTFILE.ran" ]; then
      printf '%s\n' "$FM_FAKE_PROJECT_PATH"
      exit 0
    fi
    countfile="${FM_FAKE_PANE_COUNTFILE:?FM_FAKE_PANE_COUNTFILE unset}"
    n=0
    [ -f "$countfile" ] && n=$(cat "$countfile")
    n=$((n + 1))
    printf '%s\n' "$n" > "$countfile"
    if [ "$n" -le "${FM_FAKE_PANE_STALE_READS:-0}" ]; then
      printf '%s\n' "${FM_FAKE_PANE_STALE:-}"
    else
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    fi
    exit 0
    ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  capture-pane)
    printf '$ %s\n' "$(cat "$FM_FAKE_PANE_COUNTFILE.pending" 2>/dev/null)"
    exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_DROP_CD_ENTER:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          '(cd -- '*)
            printf '%s' "$arg" > "$FM_FAKE_PANE_COUNTFILE.pending"
            echo typed >> "$FM_FAKE_PANE_COUNTFILE.types" ;;
          Enter)
            if [ -s "$FM_FAKE_PANE_COUNTFILE.pending" ]; then
              n=0; [ ! -f "$FM_FAKE_PANE_COUNTFILE.enters" ] || n=$(cat "$FM_FAKE_PANE_COUNTFILE.enters")
              n=$((n + 1)); printf '%s' "$n" > "$FM_FAKE_PANE_COUNTFILE.enters"
              if [ "$FM_FAKE_DROP_CD_ENTER" != all ] && [ "$n" -gt 1 ]; then
                : > "$FM_FAKE_PANE_COUNTFILE.ran"
                : > "$FM_FAKE_PANE_COUNTFILE.pending"
              fi
            fi ;;
          C-u) : > "$FM_FAKE_PANE_COUNTFILE.pending" ;;
        esac
      done
    fi
    if [ -n "${FM_FAKE_LEASE_ENV_LOG:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          '(cd -- '*)
            printf '%s\n' "$arg" > "$FM_FAKE_LEASE_ENV_LOG.command"
            (cd "$FM_FAKE_PROJECT_PATH" && SHELL="$(dirname "$0")/lease-shell-probe" /bin/bash -c "$arg; pwd -P") > "$FM_FAKE_LEASE_ENV_LOG"
            ;;
        esac
      done
    fi
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/lease-shell-probe" <<'SH'
#!/usr/bin/env bash
printenv TREEHOUSE_DIR
pwd -P
SH
  chmod +x "$fakebin/lease-shell-probe"
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

run_settle_spawn() {
  local id=$1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    FM_FAKE_PANE_PATH="$WT_DIR" FM_FAKE_PANE_STALE="$STALE_DIR" FM_FAKE_PROJECT_PATH="$PROJ_DIR" \
    FM_FAKE_PANE_STALE_READS="$STALE_READS" FM_FAKE_PANE_COUNTFILE="$COUNTFILE" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
}

test_dropped_cd_enter() {
  local rec id=lost-cd-s1 out rc
  rec=$(make_settle_case lost-cd "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_DROP_CD_ENTER=first run_settle_spawn "$id"); rc=$?
  expect_code 0 "$rc" "lost cd Enter spawn failed: $out"
  [ "$(cat "$COUNTFILE.enters")" = 2 ] || fail "cd did not retry Enter exactly once"
  [ "$(wc -l < "$COUNTFILE.types" | tr -d ' ')" = 1 ] || fail "cd was retyped"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "spawn never confirmed leased cwd"
  pass "spawn retries a lost cd Enter, types once, and confirms leased cwd"
}

test_exhausted_cd_enter() {
  local rec id=lost-cd-s2 out rc
  rec=$(make_settle_case lost-all-cd "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"
  out=$(FM_FAKE_DROP_CD_ENTER=all run_settle_spawn "$id"); rc=$?
  [ "$rc" -ne 0 ] || fail "spawn accepted an unsubmitted cd"
  [ "$(cat "$COUNTFILE.enters")" = 3 ] || fail "cd retries unbounded"
  [ ! -s "$COUNTFILE.pending" ] || fail "cd text left pending"
  assert_contains "$out" 'cleared owned input' "cleanup not reported"
  assert_absent "$HOME_DIR/state/$id.treehouse-lease" "failure kept the receipt of a slot it could return: $out"
  grep -qxF -- "return --force $WT_DIR" "$FAKEBIN_DIR/treehouse-calls" \
    || fail "failed cd did not return its leased slot"
  assert_absent "$HOME_DIR/state/$id.meta" "failed cd published metadata"
  pass "spawn clears an exhausted cd submit, closes its window, and returns its leased slot"
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(TREEHOUSE_DIR="$PROJ_DIR" FM_FAKE_LEASE_ENV_LOG="$HOME_DIR/lease-env" run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  assert_absent "$HOME_DIR/state/$id.treehouse-lease" "committed dispatch retained an unresolved receipt"
  assert_present "$HOME_DIR/lease-env" "lease launch did not set its slot environment"
  [ "$(sed -n '1p' "$HOME_DIR/lease-env")" = "$WT_DIR" ] || fail "lease launch inherited another slot's TREEHOUSE_DIR"
  [ "$(sed -n '2p' "$HOME_DIR/lease-env")" = "$WT_DIR" ] || fail "lease child shell did not enter its worktree"
  [ "$(sed -n '3p' "$HOME_DIR/lease-env")" = "$PROJ_DIR" ] || fail "lease launch moved the outer shell into the worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 4 ] || fail "already-settled pane took $reads reads to confirm - expected submit verification, two settled reads, and the launch-boundary cwd check"
  pass "an already-settled pane uses one submit check, two isolation reads, and one launch-boundary cwd check"
}

test_real_pane_survives_lease_child_exit() {
  local rec id=lease-shell-c9 out command target path i
  LEASE_TEST_TMUX_BIN=$(command -v tmux || true)
  [ -n "$LEASE_TEST_TMUX_BIN" ] || { echo "skip: tmux not found for real lease shell boundary"; return 0; }
  rec=$(make_settle_case lease-shell "$id" 0)
  read_settle_record "$rec"
  out=$(FM_FAKE_LEASE_ENV_LOG="$HOME_DIR/lease-env" run_settle_spawn "$id") \
    || fail "lease shell fixture spawn failed: $out"
  command=$(cat "$HOME_DIR/lease-env.command")
  LEASE_TEST_TMUX_SOCKET="fm-lease-shell-$$"
  target=lease-shell:0.0
  "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" -f /dev/null new-session -d -s lease-shell -c "$PROJ_DIR" /bin/bash \
    || fail "could not create the private tmux shell fixture"
  "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" send-keys -t "$target" -l "SHELL=/bin/bash; $command"
  "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" send-keys -t "$target" Enter
  for ((i=0; i<100; i++)); do
    path=$("$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" display-message -p -t "$target" '#{pane_current_path}')
    [ "$path" != "$WT_DIR" ] || break
    sleep 0.1
  done
  [ "$path" = "$WT_DIR" ] || fail "real pane did not enter the lease child shell"
  "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" send-keys -t "$target" -l exit
  "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" send-keys -t "$target" Enter
  for ((i=0; i<100; i++)); do
    path=$("$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" display-message -p -t "$target" '#{pane_current_path}' 2>/dev/null || true)
    [ "$path" != "$PROJ_DIR" ] || break
    sleep 0.1
  done
  [ "$path" = "$PROJ_DIR" ] || fail "exiting the lease shell removed the pane before guarded backend cleanup"
  "$LEASE_TEST_TMUX_BIN" -L "$LEASE_TEST_TMUX_SOCKET" kill-server
  LEASE_TEST_TMUX_SOCKET=
  pass "a real pane survives lease child exit with its outer shell still in the project"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. Discovery
# must confirm the exact leased path after cd, even when a backend reports an
# old primary-checkout cwd first. The settled path is a second linked worktree
# of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a pane that never left the primary checkout"$'\n'"$out"
  assert_contains "$out" "did not enter an isolated worktree matching its lease" \
    "spawn did not explain that the pane never reached an isolated worktree"
  assert_contains "$out" "$STALE_DIR" \
    "the refusal did not name the path the pane kept reporting"
  assert_contains "$out" "repository's primary checkout" \
    "the refusal did not say why that path was rejected"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "a pane stuck on the primary checkout fails loudly at the deadline"
}

make_claim_case() {
  local name=$1 id=$2 dir="$TMP_ROOT/$1"
  HOME_DIR="$dir/home"; PROJ_DIR="$dir/project"; WT_DIR="$dir/pool/1/project"
  STALE_DIR="$PROJ_DIR"; STALE_READS=0; COUNTFILE="$dir/cwd-count"
  FAKEBIN_DIR=$(make_settle_fakebin "$dir/fake")
  fm_test_spawn_home "$HOME_DIR" codex
  fm_test_spawn_brief "$HOME_DIR" "$id"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "fm/$id"
  printf '{"worktrees":[{"path":"%s","leased":false}]}\n' "$WT_DIR" > "$dir/pool/treehouse-state.json"
  cat > "$FAKEBIN_DIR/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_GET_LOG"
if [ "${1:-}" = get ]; then
  [ "${2:-}" = --lease ] || exit 9
  [ -z "${FM_FAKE_GET_READY:-}" ] || : > "$FM_FAKE_GET_READY"
  if [ -n "${FM_FAKE_GET_RELEASE:-}" ]; then
    for _ in $(seq 1 300); do
      [ ! -f "$FM_FAKE_GET_RELEASE" ] || break
      /bin/sleep 0.1
    done
    [ -f "$FM_FAKE_GET_RELEASE" ] || exit 8
  fi
  printf '%s\n' "$FM_FAKE_PANE_PATH"
fi
SH
  chmod +x "$FAKEBIN_DIR/treehouse"
}

test_unleased_detached_claim_refuses_before_get() {
  local id=claimed-new-c1 old=claimed-old-c2 before rc out claim_home
  make_claim_case legacy-unlanded "$id"
  git -C "$WT_DIR" checkout --detach -q
  printf 'unlanded detached content\n' > "$WT_DIR/unlanded"
  git -C "$WT_DIR" add unlanded
  git -C "$WT_DIR" -c user.name=test -c user.email=t@t commit -qm unlanded
  before=$(git -C "$WT_DIR" rev-parse HEAD)
  [ -z "$(git -C "$WT_DIR" status --porcelain)" ] || fail "detached fixture is dirty"
  # A cross-home claim through an alias must protect the same physical slot.
  claim_home="$HOME_DIR/../mate"
  fm_test_spawn_home "$claim_home" codex
  printf '%s\n' "- mate - fixture (home: $claim_home; scope: test; projects: project; added 2026-01-01)" > "$HOME_DIR/data/secondmates.md"
  ln -s "$WT_DIR" "$HOME_DIR/../slot-alias"
  fm_write_meta "$claim_home/state/$old.meta" "project=$PROJ_DIR" "worktree=$HOME_DIR/../slot-alias" "kind=ship"
  if out=$(FM_FAKE_GET_LOG="$HOME_DIR/get.log" run_settle_spawn "$id"); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "unleased claim was acquired"
  assert_contains "$out" "$old" "pre-get refusal must name the claimant"
  assert_absent "$HOME_DIR/get.log" "pre-get refusal invoked Treehouse"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$before" ] || fail "unlanded detached HEAD was reset"
  assert_present "$WT_DIR/unlanded" "unlanded content was removed"
  assert_absent "$HOME_DIR/state/$id.meta" "refused spawn published metadata"
  pass "a clean detached unlanded legacy claim is preserved before any get, including cross-home aliases"
}

test_post_acquisition_collision_never_returns_the_slot() {
  local id=post-new-c3 old=post-old-c4 out rc before
  make_claim_case post-collision "$id"
  printf '{"worktrees":[{"path":"%s","leased":true}]}\n' "$WT_DIR" > "$HOME_DIR/../pool/treehouse-state.json"
  fm_write_meta "$HOME_DIR/state/$old.meta" "project=$PROJ_DIR" "worktree=$WT_DIR" "kind=ship"
  before=$(git -C "$WT_DIR" rev-parse HEAD)
  # Deliberately broken provider returns a leased slot despite its exclusion.
  if out=$(FM_FAKE_GET_LOG="$HOME_DIR/get.log" run_settle_spawn "$id"); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "post-acquisition collision was accepted"
  assert_contains "$out" "$old" "post-acquisition refusal omitted the claimant"
  assert_contains "$out" "no reset or return attempted" "unsafe rollback diagnostic missing"
  assert_no_grep 'return' "$HOME_DIR/get.log" "collision auto-returned the slot"
  assert_present "$HOME_DIR/state/$id.treehouse-lease" "collision lost its lease receipt"
  assert_absent "$HOME_DIR/state/$id.meta" "collision published a second claim"
  [ "$(git -C "$WT_DIR" rev-parse HEAD)" = "$before" ] || fail "post-check reset the copy"
  pass "a broken provider's colliding lease is retained and reported, never auto-returned"
}

test_pool_claim_with_unknown_project_refuses_before_get() {
  local id=unknown-project-c7 old=unknown-owner-c8 out rc
  make_claim_case unknown-project "$id"
  fm_write_meta "$HOME_DIR/state/$old.meta" "project=$HOME_DIR" "worktree=$WT_DIR" "kind=ship"
  if out=$(FM_FAKE_GET_LOG="$HOME_DIR/get.log" run_settle_spawn "$id"); then rc=0; else rc=$?; fi
  [ "$rc" -ne 0 ] || fail "pool claim without a Git project identity was ignored"
  assert_contains "$out" "$old" "unknown pool identity refusal omitted the claimant"
  assert_contains "$out" "cannot establish the pool identity" "unknown pool identity hit an unrelated refusal"
  assert_absent "$HOME_DIR/get.log" "unknown pool identity reached Treehouse"
  assert_absent "$HOME_DIR/state/$id.meta" "unknown pool identity published metadata"
  pass "a recorded pool slot with an unknown project still refuses before get"
}

test_two_spawns_serialize_acquisition_across_homes() {
  local id=race-first-c5 second=race-second-c6 first_home mate pid i rc out
  make_claim_case race "$id"
  first_home=$HOME_DIR; mate="$HOME_DIR/../mate"
  fm_test_spawn_home "$mate" codex
  fm_test_spawn_brief "$mate" "$second"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$first_home" > "$mate/.fm-secondmate-parent"
  printf '%s\n' "- mate - fixture (home: $mate; scope: test; projects: project; added 2026-01-01)" > "$first_home/data/secondmates.md"
  FM_FAKE_GET_LOG="$first_home/get.log" FM_FAKE_GET_READY="$first_home/ready" \
    FM_FAKE_GET_RELEASE="$first_home/release" run_settle_spawn "$id" > "$first_home/out" 2>&1 &
  pid=$!
  for ((i=0; i<300; i++)); do
    [ ! -f "$first_home/ready" ] || break
    sleep 0.1
  done
  if [ ! -f "$first_home/ready" ]; then
    : > "$first_home/release"; wait "$pid" || true
    fail "first spawn never reached acquisition: $(cat "$first_home/out")"
  fi
  HOME_DIR=$mate
  if out=$(FM_FAKE_GET_LOG="$mate/get.log" run_settle_spawn "$second"); then rc=0; else rc=$?; fi
  : > "$first_home/release"
  wait "$pid" || fail "first spawn failed: $(cat "$first_home/out")"
  [ "$rc" -ne 0 ] || fail "a concurrent cross-home spawn raced allocation"
  assert_contains "$out" "another Treehouse slot allocation or return" "race did not hit the shared project lock"
  assert_absent "$mate/get.log" "racing spawn reached the provider"
  assert_present "$first_home/state/$id.meta" "winning spawn did not publish"
  assert_absent "$mate/state/$second.meta" "racing spawn published a duplicate claim"
  pass "two cross-home spawns cannot acquire before the winner publishes its claim"
}

test_real_treehouse_lease_preserves_process_free_detached_work() {
  local treehouse dir project user_root first second before out
  treehouse=$(command -v treehouse || true)
  if [ -z "$treehouse" ]; then
    printf 'skip: treehouse not found; real durable-lease regression unavailable\n'
    return
  fi
  dir="$TMP_ROOT/real-lease"; project="$dir/project"; user_root="$dir/user"
  mkdir -p "$user_root"
  fm_git_init_commit "$project"
  printf 'root = "%s"\nmax_trees = 2\n' "$dir" > "$project/treehouse.toml"
  git -C "$project" add treehouse.toml
  git -C "$project" -c user.name=test -c user.email=t@t commit -qm config
  first=$(cd "$project" && HOME="$user_root" "$treehouse" get --lease --lease-holder claimant) || fail "real first lease failed"
  git -C "$first" checkout --detach -q
  printf 'unlanded detached content\n' > "$first/unlanded"
  git -C "$first" add unlanded
  git -C "$first" -c user.name=test -c user.email=t@t commit -qm unlanded
  before=$(git -C "$first" rev-parse HEAD)
  [ -z "$(git -C "$first" status --porcelain)" ] || fail "real lease fixture must be clean"
  out=$(cd "$project" && HOME="$user_root" "$treehouse" status) || fail "real lease status failed"
  assert_contains "$out" 'leased' "process-free claim lost its durable lease"
  second=$(cd "$project" && HOME="$user_root" "$treehouse" get --lease --lease-holder next) || fail "real second lease failed"
  [ "$first" != "$second" ] || fail "Treehouse selected a leased claimant"
  [ "$(git -C "$first" rev-parse HEAD)" = "$before" ] || fail "Treehouse reset clean detached unlanded work"
  assert_present "$first/unlanded" "real lease lost committed unlanded content"
  printf '# real provider: %s\n' "$("$treehouse" --version)"
  pass "real Treehouse excludes a process-free durable lease containing clean detached unlanded work"
}

test_dropped_cd_enter
test_exhausted_cd_enter
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_real_pane_survives_lease_child_exit
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline
test_unleased_detached_claim_refuses_before_get
test_pool_claim_with_unknown_project_refuses_before_get
test_post_acquisition_collision_never_returns_the_slot
test_two_spawns_serialize_acquisition_across_homes
test_real_treehouse_lease_preserves_process_free_detached_work

echo "# all fm-spawn-worktree-settle tests passed"
