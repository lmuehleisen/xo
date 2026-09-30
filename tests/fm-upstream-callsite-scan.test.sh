#!/usr/bin/env bash
# Behavior tests for bin/fm-upstream-callsite-scan.sh: a fork-only caller of a
# helper whose definition upstream rewrote, an upstream caller of a helper whose
# definition the fork rewrote, a fork test extracting a function body upstream
# changed, and an upstream harness list missing a fork-only harness are each
# reported and fail the scan, while unchanged helpers, longer names, unrelated
# files, unchanged extracted bodies, short lists, and comments stay quiet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCAN="$ROOT/bin/fm-upstream-callsite-scan.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-callsite-scan)

commit_all() {  # <repo> <message>
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -qm "$2"
}

harness_script() {  # <names>: a bin/fm-harness.sh whose usage lists names
  printf '#!/usr/bin/env bash\n# Usage: fm-harness.sh    print own harness: %s|unknown\n' "$1"
}

# B: the previous integration point. U: upstream rewrote task_show's definition
# (stdout to a variable), kept pr_for_task byte-identical, changed only the body
# of check_config, added a caller of dod_block that sources lib.sh and one that
# does not, and added harness enumerations. F: the fork added callers of task_show
# and pr_for_task, a longer name containing task_show, a rewritten dod_block
# definition line, a test extracting check_config and helper_kept bodies, and a
# fork-only devin harness.
make_history() {  # <repo>
  local repo=$1
  mkdir -p "$repo/bin" "$repo/tests"
  git -C "$repo" init -q
  cat > "$repo/bin/lib.sh" <<'SH'
task_show() {
  printf '%s\n' "row"
}
pr_for_task() {
  printf '%s\n' "pr"
}
dod_block() {  # <mode>
  printf '%s\n' "$1"
}
check_config() {
  echo ok
}
helper_kept() { :; }
SH
  harness_script 'claude|codex|pi|pi-signed|grok' > "$repo/bin/fm-harness.sh"
  commit_all "$repo" base
  git -C "$repo" branch -q base
  git -C "$repo" checkout -q -b upstream
  cat > "$repo/bin/lib.sh" <<'SH'
task_show() {  # sets TASK_SHOW_OUTPUT
  TASK_SHOW_OUTPUT=row
}
pr_for_task() {
  printf '%s\n' "pr"
}
dod_block() {  # <mode>
  printf '%s\n' "$1"
}
check_config() {
  echo "${NEW_REQUIRED_GLOBAL:?}"
}
helper_kept() { :; }
SH
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' 'task_show "$id"' > "$repo/bin/upstream-caller.sh"
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' '. "$DIR/lib.sh"' 'dod_block "$MODE"' 'dod_block_legacy "$MODE"' > "$repo/bin/promote.sh"
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' 'dod_block "$MODE"' > "$repo/bin/unrelated.sh"
  # shellcheck disable=SC2016  # literal fixture source, expanded by nothing
  printf '%s\n' \
    "printf '%s\\n' claude codex pi pi-signed grok" \
    'case "$h" in claude|codex|pi) ;; esac' \
    '# claude codex pi pi-signed grok are markerless' > "$repo/bin/harness-lists.sh"
  commit_all "$repo" upstream
  git -C "$repo" checkout -q -b fork base
  cat > "$repo/bin/fork-caller.sh" <<'SH'
show=$(task_show "$id") || exit 1
out=$(pr_for_task "$id")
task_show_legacy "$id"
helper_kept
SH
  sed -i.bak 's/^dod_block() {  # <mode>$/dod_block() {  # <mode> [pipeline]/' "$repo/bin/lib.sh"
  rm -f "$repo/bin/lib.sh.bak"
  cat > "$repo/tests/fork.test.sh" <<'SH'
eval "$(sed -n '/^check_config() {/,/^}/p' "$ROOT/bin/lib.sh")"
eval "$(sed -n '/^helper_kept() {/p' "$ROOT/bin/lib.sh")"
SH
  harness_script 'claude|codex|pi|pi-signed|grok|devin' > "$repo/bin/fm-harness.sh"
  commit_all "$repo" fork
}

test_fork_caller_of_redefined_helper_is_reported() {
  local repo="$TMP_ROOT/history" out status
  make_history "$repo"
  out=$(cd "$repo" && "$SCAN" base upstream fork)
  status=$?
  expect_code 1 "$status" "a fork caller of a redefined helper must fail the scan: $out"
  assert_contains "$out" 'REDEFINED: task_show' 'the rewritten definition was not listed'
  # shellcheck disable=SC2016  # the reported fixture line, verbatim
  assert_contains "$out" 'CALLSITE: task_show bin/fork-caller.sh: show=$(task_show "$id") || exit 1' \
    'the fork-only caller was not reported with its path and line'
  assert_contains "$out" 'SUMMARY: 1 redefined helper(s), 1 fork-only call site(s)' 'wrong summary'
  assert_not_contains "$out" 'REDEFINED: pr_for_task' 'an unchanged definition was reported as redefined'
  assert_not_contains "$out" 'task_show_legacy' 'a longer name containing a redefined one was reported'
  assert_not_contains "$out" 'upstream-caller.sh' "upstream's own caller was reported as fork-only"
  pass 'fm-upstream-callsite-scan: a fork-only caller of a redefined helper is reported and fails the scan'
}

test_no_fork_caller_passes() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream base)
  status=$?
  expect_code 0 "$status" "a fork with no added callers must pass: $out"
  assert_contains "$out" 'REDEFINED: task_show' 'redefinitions must still be listed when nothing calls them'
  assert_contains "$out" 'SUMMARY: 1 redefined helper(s), 0 fork-only call site(s), 0 fork-redefined helper(s), 0 upstream call site(s), 0 test extraction(s), 0 harness list(s)' \
    'wrong clean summary'
  pass 'fm-upstream-callsite-scan: a fork with no affected callers passes while still listing redefinitions'
}

test_upstream_caller_of_fork_redefined_helper_is_reported() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream fork)
  status=$?
  expect_code 1 "$status" "an upstream caller of a fork-redefined helper must fail the scan: $out"
  assert_contains "$out" 'FORK_REDEFINED: dod_block' 'the fork-rewritten definition was not listed'
  # shellcheck disable=SC2016  # the reported fixture line, verbatim
  assert_contains "$out" 'UPSTREAM_CALLSITE: dod_block bin/promote.sh: dod_block "$MODE"' \
    'the upstream caller in a file sourcing the definition was not reported'
  assert_not_contains "$out" 'bin/unrelated.sh' 'a caller in a file unrelated to the definition was reported'
  assert_not_contains "$out" 'UPSTREAM_CALLSITE: dod_block bin/promote.sh: dod_block_legacy' \
    'a longer name containing a fork-redefined one was reported'
  assert_not_contains "$out" 'FORK_REDEFINED: task_show' 'an upstream-only redefinition was listed as the fork'"'"'s'
  pass 'fm-upstream-callsite-scan: an upstream caller of a fork-redefined helper is reported, scoped to files using it'
}

test_test_extraction_of_changed_body_is_reported() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream fork)
  status=$?
  expect_code 1 "$status" "a fork test extracting a changed body must fail the scan: $out"
  assert_contains "$out" "EXTRACTION: check_config tests/fork.test.sh: eval \"\$(sed -n '/^check_config() {/,/^}/p'" \
    'the extraction of a body upstream changed was not reported'
  assert_not_contains "$out" 'EXTRACTION: helper_kept' 'an extraction of an unchanged body was reported'
  assert_not_contains "$out" 'EXTRACTION: check_config bin/' 'the definition itself was reported as an extraction'
  pass 'fm-upstream-callsite-scan: a fork test extracting a function body upstream changed is reported'
}

test_harness_list_missing_fork_harness_is_reported() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream fork)
  status=$?
  expect_code 1 "$status" "an upstream harness list missing a fork harness must fail the scan: $out"
  assert_contains "$out" "HARNESS_LIST: missing devin bin/harness-lists.sh: printf '%s\\n' claude codex pi pi-signed grok" \
    'the upstream enumeration without devin was not reported'
  assert_not_contains "$out" 'claude|codex|pi) ;;' 'a list of fewer than four harnesses was reported'
  assert_not_contains "$out" 'are markerless' 'a comment naming harnesses was reported'
  assert_contains "$out" 'SUMMARY: 1 redefined helper(s), 1 fork-only call site(s), 1 fork-redefined helper(s), 1 upstream call site(s), 1 test extraction(s), 1 harness list(s)' \
    'wrong summary for the full history'
  pass 'fm-upstream-callsite-scan: an upstream harness list missing a fork-only harness is reported'
}

test_missing_harness_list_refuses() {
  local repo="$TMP_ROOT/no-harness" out status
  mkdir -p "$repo/bin"
  git -C "$repo" init -q
  printf '%s\n' 'helper() { :; }' > "$repo/bin/lib.sh"
  commit_all "$repo" base
  out=$(cd "$repo" && "$SCAN" HEAD HEAD HEAD 2>&1)
  status=$?
  expect_code 2 "$status" "a history without a harness list must refuse: $out"
  assert_contains "$out" "no 'print own harness:' list in bin/fm-harness.sh" 'the refusal did not name the missing list'
  pass 'fm-upstream-callsite-scan: a history without a readable harness list refuses without a verdict'
}

test_invalid_refs_refuse() {
  local repo="$TMP_ROOT/history" out status
  out=$(cd "$repo" && "$SCAN" base upstream no-such-ref 2>&1)
  status=$?
  expect_code 2 "$status" "an unknown ref must refuse: $out"
  assert_contains "$out" 'not a commit in this repository: no-such-ref' 'the refusal did not name the ref'
  out=$(cd "$repo" && "$SCAN" base upstream 2>&1)
  status=$?
  expect_code 2 "$status" "a missing argument must print usage: $out"
  pass 'fm-upstream-callsite-scan: unknown refs and missing arguments refuse without a verdict'
}

test_fork_caller_of_redefined_helper_is_reported
test_no_fork_caller_passes
test_upstream_caller_of_fork_redefined_helper_is_reported
test_test_extraction_of_changed_body_is_reported
test_harness_list_missing_fork_harness_is_reported
test_missing_harness_list_refuses
test_invalid_refs_refuse
