#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans) and the temp-root
# removal guard in tests/tmproot-guard.sh that every cleanup trap goes through.
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. The unmet-precondition and guard cases run
# against a disposable copy of the checkout, never this worktree. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

# make_disposable_checkout <harness>: a copy of just enough of the checkout to
# source tests/lib.sh, plus a sentinel tree, so a guard failure can only ever
# delete the copy.
make_disposable_checkout() {
  local copy="$1/checkout"
  mkdir -p "$copy/tests" "$copy/project/src"
  cp -R "$ROOT/bin" "$copy/bin"
  cp "$ROOT/tests/lib.sh" "$ROOT/tests/git-config-helpers.sh" "$ROOT/tests/tmproot-guard.sh" "$copy/tests/"
  printf 'sentinel\n' > "$copy/project/src/keep.txt"
  printf '%s\n' "$copy"
}

tree_listing() {
  (cd "$1" && find . -print | LC_ALL=C sort)
}

test_denied_ps_fails_closed_without_deleting_checkout() {
  local harness copy shim before after rc out
  harness=$(fm_test_tmproot fm-test-cleanup-denied-ps)
  copy=$(make_disposable_checkout "$harness")
  shim="$harness/shim"
  mkdir -p "$shim" "$harness/no-proc"
  printf '#!/bin/sh\necho "ps: operation not permitted" >&2\nexit 1\n' > "$shim/ps"
  chmod +x "$shim/ps"
  # The shape that can delete a worktree: source the library, canonicalize
  # the root it returned, and remove that root from an EXIT trap.
  cat > "$copy/tests/probe.test.sh" <<'PROBE'
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-probe)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
trap 'fm_test_rm_tmproot "${TMP_ROOT:-}"' EXIT
printf 'reached past the library\n'
PROBE
  before=$(tree_listing "$copy")

  rc=0
  out=$(cd "$copy" && PATH="$shim:$PATH" FM_PROC_ROOT_OVERRIDE="$harness/no-proc" \
    bash tests/probe.test.sh 2>&1) || rc=$?

  [ "$rc" -ne 0 ] || fail "tests/lib.sh exited zero when ps was denied: $out"
  assert_contains "$out" "precondition unmet" "the denied-ps failure did not name an unmet precondition"
  assert_contains "$out" "working ps" "the denied-ps failure did not name ps as the missing precondition"
  assert_not_contains "$out" "reached past the library" \
    "the sourcing test kept running after tests/lib.sh could not initialize"
  after=$(tree_listing "$copy")
  [ "$before" = "$after" ] || fail "a denied ps changed the disposable checkout"
  pass "tests/lib.sh exits non-zero naming ps when process identity is denied, deleting nothing"
}

test_cleanup_guard_refuses_unsafe_roots() {
  local harness copy before after out rc
  harness=$(fm_test_tmproot fm-test-cleanup-guard)
  copy=$(make_disposable_checkout "$harness")
  mkdir -p "$copy/project/nested-tmp"
  # The trap pattern with its root already emptied the way a failed library
  # can leave it, sourcing only the guard so the library cannot rescue it.
  cat > "$copy/tests/guard-probe.test.sh" <<'PROBE'
set -u
. "$(dirname "${BASH_SOURCE[0]}")/tmproot-guard.sh"
EMPTY_ROOT=
EMPTY_ROOT=$(cd "$EMPTY_ROOT" && pwd)
CHECKOUT_PARENT=$(cd .. && pwd)
trap 'fm_test_rm_tmproot "${EMPTY_ROOT:-}"; fm_test_rm_tmproot "$CHECKOUT_PARENT"; fm_test_rm_tmproot ""; fm_test_rm_tmproot project/..' EXIT
PROBE
  before=$(tree_listing "$harness")

  rc=0
  out=$(cd "$copy" && bash tests/guard-probe.test.sh 2>&1) || rc=$?

  after=$(tree_listing "$harness")
  [ "$before" = "$after" ] || fail "the cleanup guard let a trap delete the checkout or its ancestor"
  assert_contains "$out" "refusing to remove $copy: it is or contains the checkout" \
    "the guard did not name the checkout when refusing an emptied, canonicalized root"
  assert_contains "$out" "refusing to remove $harness: it is or contains the checkout" \
    "the guard did not refuse an ancestor of the checkout"
  assert_contains "$out" "refusing to remove project/..: a relative directory component" \
    "the guard did not refuse a dot-dot path"

  # The disposable checkout itself lives under a temp directory, so only the
  # checkout-containment rule can stop removal of its contents.
  before=$(tree_listing "$copy")
  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_tmproot "$1/project" "$1/tests/../project/src"' _ "$copy" 2>&1) || true
  after=$(tree_listing "$copy")
  [ "$before" = "$after" ] || fail "the guard removed a directory inside a checkout that lives under a temp directory"
  assert_contains "$out" "refusing to remove $copy/project: it is inside the checkout" \
    "the guard did not refuse a path inside the checkout"
  assert_contains "$out" "refusing to remove $copy/tests/../project/src: it is inside the checkout" \
    "the guard did not refuse a dot-dot spelling of a path inside the checkout"

  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_tmproot_guard_reason /; fm_test_tmproot_guard_reason /usr' 2>&1)
  assert_contains "$out" "the filesystem root" "the guard did not refuse the filesystem root"
  assert_contains "$out" "not strictly below a temporary directory" \
    "the guard did not refuse a path outside every temporary directory"

  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_tmproot "$1"; echo "rc=$?"' _ "$harness/removable" 2>&1)
  [ "$out" = rc=0 ] || fail "an absent path was not a silent no-op: $out"
  mkdir -p "$harness/removable/inner"
  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_tmproot "$1" && [ ! -e "$1" ] && echo removed' _ "$harness/removable" 2>&1)
  assert_contains "$out" removed "the guard refused a genuine temp root"

  # A slash-terminated symlink must be removed as the link itself: rm given
  # `link/` would otherwise descend into the directory the link points at.
  local spelling target
  for spelling in / //; do
    ln -s "$copy" "$harness/link-to-checkout"
    before=$(tree_listing "$copy")
    out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_tmproot "$1"; echo "rc=$?"' \
      _ "$harness/link-to-checkout$spelling" 2>&1)
    after=$(tree_listing "$copy")
    [ "$before" = "$after" ] || fail "removing a symlink spelled with '$spelling' deleted its target's contents"
    assert_contains "$out" rc=0 "the guard refused a temp symlink spelled with '$spelling'"
    [ ! -e "$harness/link-to-checkout" ] && [ ! -L "$harness/link-to-checkout" ] \
      || fail "the guard did not remove the temp symlink spelled with '$spelling'"
  done

  # A broken symlink spelled with a trailing slash is still the link itself.
  ln -s "$harness/no-such-target" "$harness/broken-link"
  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_tmproot "$1"; echo "rc=$?"' _ "$harness/broken-link/" 2>&1)
  assert_contains "$out" rc=0 "the guard refused a broken temp symlink spelled with a trailing slash"
  [ ! -L "$harness/broken-link" ] || fail "a broken temp symlink spelled with a trailing slash was left behind"

  # A relative TMPDIR is captured canonically, so cleanup still recognizes its
  # roots after the suite changes directory.
  mkdir -p "$harness/rel-tmp"
  out=$(cd "$harness" && TMPDIR=rel-tmp bash -c '
    . "$1/tests/tmproot-guard.sh"
    d=$(mktemp -d "$TMPDIR/fm-rel.XXXXXX") && d=$(cd "$d" && pwd -P)
    cd /
    fm_test_rm_tmproot "$d"; echo "rc=$?"
    [ -e "$d" ] && echo "left:$d"
  ' _ "$copy" 2>&1)
  assert_contains "$out" rc=0 "the guard refused a root under a relative TMPDIR after a directory change"
  assert_not_contains "$out" "left:" "a root under a relative TMPDIR survived cleanup after a directory change"

  # The in-checkout live-lab exception removes only its exact shape.
  mkdir -p "$copy/.demo-live-e2e.123/inner" "$copy/.hidden" "$harness/.stray-live-e2e.9"
  ln -s "$copy/project" "$copy/.linked-live-e2e.7"
  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_checkout_lab "$1/.demo-live-e2e.123"; echo "rc=$?"' _ "$copy" 2>&1)
  assert_contains "$out" rc=0 "the live-lab helper refused a genuine in-checkout lab"
  [ ! -e "$copy/.demo-live-e2e.123" ] || fail "the live-lab helper left a genuine in-checkout lab behind"
  before=$(tree_listing "$harness")
  for target in "$copy/project" "$copy/.hidden" "$copy/.linked-live-e2e.7" "$copy/.linked-live-e2e.7/" \
    "$harness/.stray-live-e2e.9" "$copy" ""; do
    out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_rm_checkout_lab "$1"; echo "rc=$?"' _ "$target" 2>&1)
    if [ -n "$target" ]; then
      assert_contains "$out" rc=1 "the live-lab helper accepted $target"
    fi
  done
  after=$(tree_listing "$harness")
  [ "$before" = "$after" ] || fail "the live-lab helper removed something outside its exact lab shape"

  rc=0
  out=$(cd "$copy" && bash -c '. tests/tmproot-guard.sh; fm_test_require_tmproot ""; echo continued' 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fm_test_require_tmproot accepted an empty root"
  assert_not_contains "$out" continued "fm_test_require_tmproot let a test continue on an empty root"
  pass "the cleanup guard refuses empty, root, non-temporary, checkout-containing, and in-checkout paths, never follows a slash-terminated symlink, and limits the in-checkout exception to live-suite labs"
}

test_tmpdir_inside_checkout_stops_the_test() {
  local harness copy before after rc out
  harness=$(fm_test_tmproot fm-test-cleanup-tmpdir-in-checkout)
  copy=$(make_disposable_checkout "$harness")
  mkdir -p "$copy/tmp"
  cat > "$copy/tests/probe.test.sh" <<'PROBE'
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-probe)
printf 'reached with root <%s>\n' "$TMP_ROOT"
PROBE
  before=$(tree_listing "$copy")

  rc=0
  out=$(cd "$copy" && TMPDIR="$copy/tmp" bash tests/probe.test.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "tests/lib.sh accepted a TMPDIR inside the checkout: $out"
  assert_contains "$out" "must be an existing directory outside the checkout" \
    "the in-checkout TMPDIR failure did not name the precondition"
  assert_not_contains "$out" "reached with root" "a test kept running with a TMPDIR inside the checkout"
  after=$(tree_listing "$copy")
  [ "$before" = "$after" ] || fail "an in-checkout TMPDIR left files behind in the checkout"

  # A suite that sources only the guard gets the same precondition.
  cat > "$copy/tests/guard-only-probe.test.sh" <<'PROBE'
set -u
. "$(dirname "${BASH_SOURCE[0]}")/tmproot-guard.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-guard-only.XXXXXX")
printf 'reached with lab <%s>\n' "$LAB"
PROBE
  before=$(tree_listing "$copy")
  rc=0
  out=$(cd "$copy" && TMPDIR="$copy/tmp" bash tests/guard-only-probe.test.sh 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "the guard accepted a TMPDIR inside the checkout: $out"
  assert_contains "$out" "must be an existing directory outside the checkout" \
    "the guard-only in-checkout TMPDIR failure did not name the precondition"
  assert_not_contains "$out" "reached with lab" "a guard-only suite kept running with a TMPDIR inside the checkout"
  after=$(tree_listing "$copy")
  [ "$before" = "$after" ] || fail "a guard-only suite left files behind in the checkout"

  # TMPDIR moved into the checkout after sourcing: the rejected root is rolled
  # back and the owning test stops instead of receiving an empty root.
  cat > "$copy/tests/late-probe.test.sh" <<'PROBE'
set -u
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export TMPDIR="$1"
TMP_ROOT=$(fm_test_tmproot fm-late-probe)
printf 'reached with root <%s>\n' "$TMP_ROOT"
PROBE
  before=$(tree_listing "$copy")
  rc=0
  out=$(cd "$copy" && bash tests/late-probe.test.sh "$copy/tmp" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a rejected temp root let the owning test succeed: $out"
  assert_contains "$out" "refusing unsafe temp root" "the rejected temp root was not reported"
  assert_not_contains "$out" "reached with root" "the owning test continued after its temp root was rejected"
  after=$(tree_listing "$copy")
  [ "$before" = "$after" ] || fail "a rejected temp root was left behind inside the checkout"
  pass "a TMPDIR inside the checkout stops the test instead of yielding an empty root"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_denied_ps_fails_closed_without_deleting_checkout
test_cleanup_guard_refuses_unsafe_roots
test_tmpdir_inside_checkout_stops_the_test
