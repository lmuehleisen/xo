#!/usr/bin/env bash
# Scratch scout cleanup must delete a nested directory the scout left without
# owner write permission. treehouse return cleans with `git clean -fd`, and
# that unlinking fails when the parent directory is not writable.
#
# The repair is scout-only and runs only after the report, completion-gate,
# and landed-work refusals. A ship worktree is not modified, including a
# forced discard. A symlink inside the scratch copy that points outside is
# not modified, including a directory symlink that is still present when
# cleanup runs. A recorded path that is a symlink to the real scratch copy
# is repaired at that physical directory. Replacing an ancestor with a
# symlink at the moment owner write is restored must not change the outside
# directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-scout-readonly)

mode_of() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

make_case() {  # <name> -> echoes the case dir
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_TREEHOUSE_LOG:?}"
if [ "${1:-}" = return ]; then
  git -C "${3:?}" clean -fd
  exit $?
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh" "$fakebin/gh-axi" "$fakebin/no-mistakes"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "fm/$name"
  touch "$case_dir/state/.last-watcher-beat"
  printf '%s\n' "$case_dir"
}

write_task() {  # <case_dir> <id> <kind> [worktree]
  local case_dir=$1 id=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=teardown-test-$id" \
    "decisions_reviewed=1" \
    "decision_keys="
}

# Drop the completion-gate attestation so verify must refuse.
clear_completion_gate() {  # <case_dir> <id>
  local meta="$1/state/$2.meta"
  grep -v '^decisions_reviewed=' "$meta" > "$meta.gate" || true
  mv "$meta.gate" "$meta"
}

plant_readonly_hooks() {  # <case_dir>
  local wt="$1/wt"
  mkdir -p "$wt/copied-hooks/nested"
  printf '#!/bin/sh\n' > "$wt/copied-hooks/nested/commit-msg"
}

lock_readonly_hooks() {  # <case_dir>
  local wt="$1/wt"
  chmod a-w "$wt/copied-hooks" "$wt/copied-hooks/nested" "$wt/copied-hooks/nested/commit-msg"
}

# Outside files and a directory symlink that sits inside the non-writable
# tree. The nested link is created before that tree loses owner write,
# because a mode-555 directory cannot gain a new entry. git clean -fd can
# remove a symlink whose parent is writable even when it fails on this tree,
# so the nested directory link is the one a pre-clean cannot delete.
plant_nested_outside_links() {  # <case_dir>
  local case_dir=$1 wt="$1/wt" outside="$1/outside"
  mkdir -p "$outside/nested" "$outside/root-target" "$wt/copied-hooks/nested"
  printf 'secret\n' > "$outside/file"
  printf 'nested-secret\n' > "$outside/nested/file"
  printf 'root-secret\n' > "$outside/root-target/file"
  ln -s "$outside/file" "$wt/copied-hooks/nested/escape-file"
  ln -s "$outside/nested" "$wt/copied-hooks/nested/escape-dir"
  chmod a-w "$outside/file" "$outside/nested" "$outside/nested/file" \
    "$outside/root-target" "$outside/root-target/file"
}

plant_root_dir_link() {  # <case_dir>
  ln -s "$1/outside/root-target" "$1/wt/escape-dir"
}

run_teardown() {  # <case_dir> <id> [extra args...]
  local case_dir=$1 id=$2
  shift 2
  : > "$case_dir/treehouse.log"
  FM_HOME="$case_dir" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" \
    FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" \
    FM_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" "$@"
}

write_scout_report() {  # <case_dir> <id>
  mkdir -p "$1/data/$2"
  printf 'findings\n' > "$1/data/$2/report.md"
}

test_scout_readonly_tree_is_deleted_and_outside_directory_link_survives() {
  local case_dir id=scout-ro rc file_mode dir_mode nested_mode root_mode root_file_mode
  case_dir=$(make_case scout-readonly)
  write_task "$case_dir" "$id" scout
  write_scout_report "$case_dir" "$id"
  plant_readonly_hooks "$case_dir"
  plant_nested_outside_links "$case_dir"
  lock_readonly_hooks "$case_dir"

  rc=0
  git -C "$case_dir/wt" clean -fd > "$case_dir/preclean.out" 2> "$case_dir/preclean.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-readonly: git clean deleted a non-writable tree (rc=$rc)"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "scout-readonly: the non-writable file was removed before teardown"
  [ -L "$case_dir/wt/copied-hooks/nested/escape-dir" ] \
    || fail "scout-readonly: pre-clean removed the nested directory symlink"
  [ -L "$case_dir/wt/copied-hooks/nested/escape-file" ] \
    || fail "scout-readonly: pre-clean removed the nested file symlink"
  assert_grep "Permission denied" "$case_dir/preclean.err" \
    "scout-readonly: git clean did not fail with permission denied"

  # The root directory symlink is planted after that failed clean. Cleanup
  # must see it; a pre-clean would have deleted it because its parent is
  # writable, which is the coverage hole this case closes.
  plant_root_dir_link "$case_dir"
  [ -L "$case_dir/wt/escape-dir" ] \
    || fail "scout-readonly: root directory symlink is missing before teardown"
  [ -L "$case_dir/wt/copied-hooks/nested/escape-dir" ] \
    || fail "scout-readonly: nested directory symlink is missing before teardown"

  file_mode=$(mode_of "$case_dir/outside/file")
  dir_mode=$(mode_of "$case_dir/outside/nested")
  nested_mode=$(mode_of "$case_dir/outside/nested/file")
  root_mode=$(mode_of "$case_dir/outside/root-target")
  root_file_mode=$(mode_of "$case_dir/outside/root-target/file")

  rc=0
  run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "scout-readonly: teardown should succeed"$'\n'"$(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-readonly: the non-writable hooks tree is still in the scratch copy"
  [ ! -e "$case_dir/wt/escape-dir" ] \
    || fail "scout-readonly: the root directory symlink is still in the scratch copy"
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "scout-readonly: teardown did not return the worktree"
  assert_equals "$file_mode" "$(mode_of "$case_dir/outside/file")" \
    "scout-readonly: symlink target file mode changed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/outside/nested")" \
    "scout-readonly: symlink target directory mode changed"
  assert_equals "$nested_mode" "$(mode_of "$case_dir/outside/nested/file")" \
    "scout-readonly: file inside the symlink target directory changed mode"
  assert_equals "$root_mode" "$(mode_of "$case_dir/outside/root-target")" \
    "scout-readonly: root directory symlink target mode changed"
  assert_equals "$root_file_mode" "$(mode_of "$case_dir/outside/root-target/file")" \
    "scout-readonly: file inside the root directory symlink target changed mode"
  assert_equals "secret" "$(cat "$case_dir/outside/file")" \
    "scout-readonly: symlink target contents changed"
  assert_equals "nested-secret" "$(cat "$case_dir/outside/nested/file")" \
    "scout-readonly: file inside the symlink target directory changed contents"
  assert_equals "root-secret" "$(cat "$case_dir/outside/root-target/file")" \
    "scout-readonly: file inside the root directory symlink target changed contents"
  pass "a scratch scout with a non-writable nested tree is cleaned up, and outside directory symlinks are not modified"
}

test_root_alias_readonly_tree_is_deleted_without_following_outside_links() {
  local case_dir id=scout-alias rc file_mode dir_mode
  case_dir=$(make_case scout-alias)
  ln -s wt "$case_dir/wt-alias"
  write_task "$case_dir" "$id" scout "$case_dir/wt-alias"
  write_scout_report "$case_dir" "$id"
  plant_readonly_hooks "$case_dir"
  plant_nested_outside_links "$case_dir"
  lock_readonly_hooks "$case_dir"
  plant_root_dir_link "$case_dir"
  file_mode=$(mode_of "$case_dir/outside/file")
  dir_mode=$(mode_of "$case_dir/outside/nested")

  rc=0
  run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "scout-alias: teardown through a symlinked scratch path should succeed"$'\n'"$(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-alias: the non-writable hooks tree is still in the real scratch copy"
  assert_grep "return --force $case_dir/wt-alias" "$case_dir/treehouse.log" \
    "scout-alias: teardown did not return the recorded alias"
  assert_equals "$file_mode" "$(mode_of "$case_dir/outside/file")" \
    "scout-alias: outside file mode changed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/outside/nested")" \
    "scout-alias: outside directory mode changed"
  assert_equals "secret" "$(cat "$case_dir/outside/file")" \
    "scout-alias: outside file contents changed"
  assert_equals "nested-secret" "$(cat "$case_dir/outside/nested/file")" \
    "scout-alias: outside directory contents changed"
  pass "a symlinked scratch path with a non-writable tree is cleaned up without changing outside targets"
}

# At the chmod of the nested directory, replace its parent with a symlink to
# an outside directory. A mode change that re-walks the path would change the
# outside directory. A mode change of the directory inode already entered
# would not.
install_ancestor_swap_chmod() {  # <case_dir>
  local case_dir=$1
  cat > "$case_dir/fakebin/chmod" <<'SH'
#!/usr/bin/env bash
set -u
real=${FM_REAL_CHMOD:?}
log=${FM_CHMOD_LOG:?}
wt=${FM_CHMOD_WT:?}
outside=${FM_CHMOD_OUTSIDE:?}
marker=${FM_CHMOD_MARKER:?}
printf '%s\n' "cwd=$(pwd -P) args=$*" >> "$log"
target=${2:-}
swap=0
if [ "${1:-}" = u+w ] && [ ! -e "$marker" ]; then
  if [ "$target" = "$wt/copied-hooks/nested" ]; then
    swap=1
  elif [ "$target" = . ] && [ "$(pwd -P)" = "$wt/copied-hooks/nested" ]; then
    swap=1
  fi
fi
if [ "$swap" -eq 1 ] && [ -d "$wt/copied-hooks" ] && [ ! -L "$wt/copied-hooks" ]; then
  mv "$wt/copied-hooks" "$wt/copied-hooks.real"
  ln -s "$outside" "$wt/copied-hooks"
  printf '%s\n' swapped >> "$log"
  : > "$marker"
fi
exec "$real" "$@"
SH
  chmod +x "$case_dir/fakebin/chmod"
}

test_ancestor_swap_at_chmod_does_not_change_outside_directory() {
  local case_dir id=scout-swap rc dir_mode file_mode
  case_dir=$(make_case scout-swap)
  write_task "$case_dir" "$id" scout
  write_scout_report "$case_dir" "$id"
  plant_readonly_hooks "$case_dir"
  mkdir -p "$case_dir/outside/nested"
  printf 'keep\n' > "$case_dir/outside/nested/file"
  chmod a-w "$case_dir/outside" "$case_dir/outside/nested" "$case_dir/outside/nested/file"
  lock_readonly_hooks "$case_dir"
  install_ancestor_swap_chmod "$case_dir"
  : > "$case_dir/chmod.log"
  dir_mode=$(mode_of "$case_dir/outside/nested")
  file_mode=$(mode_of "$case_dir/outside/nested/file")

  rc=0
  FM_REAL_CHMOD="$(command -v chmod)" \
    FM_CHMOD_LOG="$case_dir/chmod.log" \
    FM_CHMOD_WT="$case_dir/wt" \
    FM_CHMOD_OUTSIDE="$case_dir/outside" \
    FM_CHMOD_MARKER="$case_dir/swapped" \
    run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ -f "$case_dir/swapped" ] \
    || fail "scout-swap: the ancestor was not replaced at the mode change"$'\n'"$(cat "$case_dir/chmod.log")"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/outside/nested")" \
    "scout-swap: outside directory mode changed when its symlink replaced an ancestor (rc=$rc)"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals "$file_mode" "$(mode_of "$case_dir/outside/nested/file")" \
    "scout-swap: outside file mode changed"
  assert_equals "keep" "$(cat "$case_dir/outside/nested/file")" \
    "scout-swap: outside file contents changed"
  pass "replacing an ancestor with an outside symlink at the mode change does not change that outside directory"
}

test_ship_worktree_readonly_tree_is_not_modified() {
  local case_dir id=ship-ro rc dir_mode file_mode exclude
  case_dir=$(make_case ship-readonly)
  write_task "$case_dir" "$id" ship
  plant_readonly_hooks "$case_dir"
  lock_readonly_hooks "$case_dir"
  exclude=$(git -C "$case_dir/wt" rev-parse --git-path info/exclude)
  printf '%s\n' '/copied-hooks/' >> "$exclude"
  dir_mode=$(mode_of "$case_dir/wt/copied-hooks/nested")
  file_mode=$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")

  rc=0
  run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "ship-readonly: a clean landed ship should still be torn down"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "ship-readonly: teardown did not reach the worktree return"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "ship-readonly: the ship worktree's hooks tree was removed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested")" \
    "ship-readonly: ship directory mode changed"
  assert_equals "$file_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")" \
    "ship-readonly: ship file mode changed"
  pass "a ship worktree keeps its non-writable tree through cleanup"
}

test_ship_with_unlanded_readonly_tree_is_refused_unchanged() {
  local case_dir id=ship-dirty rc dir_mode file_mode
  case_dir=$(make_case ship-dirty)
  write_task "$case_dir" "$id" ship
  plant_readonly_hooks "$case_dir"
  lock_readonly_hooks "$case_dir"
  dir_mode=$(mode_of "$case_dir/wt/copied-hooks/nested")
  file_mode=$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")

  rc=0
  run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "ship-dirty: teardown discarded a ship with uncommitted files"
  assert_grep "REFUSED" "$case_dir/stderr" \
    "ship-dirty: teardown did not refuse the uncommitted tree"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "ship-dirty: teardown returned the worktree after refusing it"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "ship-dirty: the uncommitted file was removed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested")" \
    "ship-dirty: directory mode changed before the refusal"
  assert_equals "$file_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")" \
    "ship-dirty: file mode changed before the refusal"
  [ -f "$case_dir/state/$id.meta" ] \
    || fail "ship-dirty: the refusal removed the task record"
  pass "a ship with an uncommitted non-writable tree is refused and left unchanged"
}

test_forced_ship_discard_does_not_chmod_readonly_tree() {
  local case_dir id=ship-force rc dir_mode file_mode
  case_dir=$(make_case ship-force)
  write_task "$case_dir" "$id" ship
  plant_readonly_hooks "$case_dir"
  lock_readonly_hooks "$case_dir"
  dir_mode=$(mode_of "$case_dir/wt/copied-hooks/nested")
  file_mode=$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")

  rc=0
  run_teardown "$case_dir" "$id" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "ship-force: forced discard removed a non-writable ship tree"
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "ship-force: forced discard did not reach the worktree return"$'\n'"$(cat "$case_dir/stderr")"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "ship-force: the ship file was removed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested")" \
    "ship-force: ship directory mode changed"
  assert_equals "$file_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")" \
    "ship-force: ship file mode changed"
  pass "a forced discard of a ship does not restore write permission on its tree"
}

test_scout_without_report_is_refused_unchanged() {
  local case_dir id=scout-noreport rc dir_mode file_mode
  case_dir=$(make_case scout-noreport)
  write_task "$case_dir" "$id" scout
  plant_readonly_hooks "$case_dir"
  lock_readonly_hooks "$case_dir"
  dir_mode=$(mode_of "$case_dir/wt/copied-hooks/nested")
  file_mode=$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")

  rc=0
  run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-noreport: teardown cleaned up a scout with no report"
  assert_grep "no report" "$case_dir/stderr" \
    "scout-noreport: teardown did not refuse the missing report"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-noreport: teardown returned the worktree after refusing it"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "scout-noreport: the hooks file was removed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested")" \
    "scout-noreport: directory mode changed before the refusal"
  assert_equals "$file_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")" \
    "scout-noreport: file mode changed before the refusal"
  [ -f "$case_dir/state/$id.meta" ] \
    || fail "scout-noreport: the refusal removed the task record"
  pass "a scout with no report is refused without changing its non-writable tree"
}

test_scout_without_completion_gate_is_refused_unchanged() {
  local case_dir id=scout-nogate rc dir_mode file_mode
  case_dir=$(make_case scout-nogate)
  write_task "$case_dir" "$id" scout
  clear_completion_gate "$case_dir" "$id"
  write_scout_report "$case_dir" "$id"
  plant_readonly_hooks "$case_dir"
  lock_readonly_hooks "$case_dir"
  dir_mode=$(mode_of "$case_dir/wt/copied-hooks/nested")
  file_mode=$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")

  rc=0
  run_teardown "$case_dir" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-nogate: teardown cleaned up a scout that failed the completion gate"
  assert_grep "completion gate" "$case_dir/stderr" \
    "scout-nogate: teardown did not refuse the completion gate"$'\n'"$(cat "$case_dir/stderr")"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-nogate: teardown returned the worktree after refusing it"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "scout-nogate: the hooks file was removed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested")" \
    "scout-nogate: directory mode changed before the refusal"
  assert_equals "$file_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested/commit-msg")" \
    "scout-nogate: file mode changed before the refusal"
  [ -f "$case_dir/state/$id.meta" ] \
    || fail "scout-nogate: the refusal removed the task record"
  pass "a scout that has not passed the completion gate is refused without changing its non-writable tree"
}

test_scout_readonly_tree_is_deleted_and_outside_directory_link_survives
test_root_alias_readonly_tree_is_deleted_without_following_outside_links
test_ancestor_swap_at_chmod_does_not_change_outside_directory
test_ship_worktree_readonly_tree_is_not_modified
test_ship_with_unlanded_readonly_tree_is_refused_unchanged
test_forced_ship_discard_does_not_chmod_readonly_tree
test_scout_without_report_is_refused_unchanged
test_scout_without_completion_gate_is_refused_unchanged
