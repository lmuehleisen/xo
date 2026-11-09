#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-removed-helper-scan.sh: a helper defined
# at the merge base or the upstream tip, absent from the merged commit, and
# still mentioned is reported, including a comment, while a longer name, a
# helper the merge kept, and an unreferenced deletion stay off the REF list.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-upstream-removed-helper-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-removed-helper-scan)

commit_all() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qm "$2"
}

# base defines five helpers. upstream deletes gone_upstream and unreferenced,
# keeps the rest, and adds upstream_only. merged keeps only kept, and still
# mentions gone_upstream, gone_on_fork, upstream_only, and stale_marker.
make_history() {  # <repo>
  local repo=$1
  rm -rf "$repo"
  mkdir -p "$repo/bin" "$repo/tests"
  git -C "$repo" init -q
  cat > "$repo/bin/lib.sh" <<'SH'
kept() { :; }
gone_upstream() { :; }
gone_on_fork() { :; }
stale_marker() { :; }
unreferenced() { :; }
SH
  commit_all "$repo" base
  git -C "$repo" branch -q base
  git -C "$repo" checkout -q -b upstream
  cat > "$repo/bin/lib.sh" <<'SH'
kept() { :; }
gone_on_fork() { :; }
stale_marker() { :; }
upstream_only() { :; }
SH
  commit_all "$repo" upstream
  git -C "$repo" checkout -q -b merged base
  cat > "$repo/bin/lib.sh" <<'SH'
kept() { :; }
SH
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' 'gone_upstream "$id"' 'kept' > "$repo/bin/fork-caller.sh"
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' 'gone_on_fork' 'upstream_only' 'gone_upstream_longer' > "$repo/bin/upstream-caller.sh"
  printf '%s\n' '# stale_marker was removed' > "$repo/bin/comment.sh"
  printf '%s\n' 'gone_upstream is only prose' > "$repo/tests/note.md"
  commit_all "$repo" merged
  # A fixed-string grep would treat the collector's `.` as a literal period.
  git -C "$repo" config grep.patternType fixed
}

test_both_directions_and_a_comment_are_reported() {
  local repo="$TMP_ROOT/history" out status
  make_history "$repo"
  out=$(cd "$repo" && "$SCAN" base upstream HEAD)
  status=$?
  expect_code 1 "$status" "a merged tree that still mentions removed helpers must fail: $out"
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  assert_contains "$out" 'REF: gone_upstream bin/fork-caller.sh:1: gone_upstream "$id"' \
    'a caller of a helper upstream deleted was not reported'
  assert_contains "$out" 'REF: gone_on_fork bin/upstream-caller.sh:1: gone_on_fork' \
    'a caller of a helper the merge dropped was not reported'
  assert_contains "$out" 'REF: upstream_only bin/upstream-caller.sh:2: upstream_only' \
    'a helper defined only at the upstream tip was not reported'
  assert_contains "$out" 'REF: stale_marker bin/comment.sh:1: # stale_marker was removed' \
    'a comment mentioning a removed helper was not reported'
  assert_contains "$out" 'SUMMARY: 4 referenced missing helper(s), 4 reference(s), 1 unreferenced missing helper(s)' \
    'wrong summary'
  assert_not_contains "$out" 'gone_upstream_longer' 'a longer name was reported'
  assert_not_contains "$out" 'REF: kept' 'a helper the merge kept was reported'
  assert_not_contains "$out" 'REF: unreferenced' 'an unreferenced deletion was listed'
  assert_not_contains "$out" 'note.md' 'a mention outside shell files was reported'
  out=$(cd "$repo" && "$SCAN" base upstream merged)
  status=$?
  expect_code 1 "$status" "the merged branch name must scan the same commit: $out"
  pass 'fm-upstream-removed-helper-scan: removed helpers still mentioned are reported from both directions'
}

test_clean_merge_passes() {
  local repo="$TMP_ROOT/history" out status
  make_history "$repo"
  out=$(cd "$repo" && "$SCAN" base upstream base)
  status=$?
  expect_code 0 "$status" "a tree that still defines every base helper must pass: $out"
  assert_contains "$out" 'SUMMARY: 0 referenced missing helper(s), 0 reference(s), 1 unreferenced missing helper(s)' \
    'upstream-only upstream_only should be the one unreferenced missing helper'
  assert_not_contains "$out" 'REF:' 'a clean tree printed a reference'
  pass 'fm-upstream-removed-helper-scan: a tree with no dangling mention passes'
}

test_invalid_refs_refuse() {
  local repo="$TMP_ROOT/history" out status
  make_history "$repo"
  out=$(cd "$repo" && "$SCAN" base upstream no-such-ref 2>&1)
  status=$?
  expect_code 2 "$status" "an unknown ref must refuse: $out"
  assert_contains "$out" 'not a commit in this repository: no-such-ref' 'the refusal did not name the ref'
  out=$(cd "$repo" && "$SCAN" base upstream 2>&1)
  status=$?
  expect_code 2 "$status" "a missing argument must print usage: $out"
  assert_contains "$out" 'Usage: fm-upstream-removed-helper-scan.sh' 'the refusal did not print usage'
  assert_contains "$out" '<merged>' 'usage did not describe the merged commit'
  pass 'fm-upstream-removed-helper-scan: unknown refs and missing arguments refuse without a verdict'
}

test_both_directions_and_a_comment_are_reported
test_clean_merge_passes
test_invalid_refs_refuse
