#!/usr/bin/env bash
# Scratch scout cleanup must delete a nested directory the scout left without
# owner write permission. A symlink to an outside directory is not followed.
# A ship with that same tree still uncommitted is refused and left unchanged.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-scout-readonly)

# GNU stat accepts -c. BSD stat accepts -f. GNU stat -f is a filesystem
# query and exits 0, so the GNU form has to be tried first.
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

skip_if_directory_mode_is_bypassed() {
  if [ "$(id -u)" -eq 0 ]; then
    pass "$1 skipped: the superuser bypasses directory write permission"
    return 0
  fi
  return 1
}

make_case() {  # <name>
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

write_task() {  # <case_dir> <id> <kind>
  fm_write_meta "$1/state/$2.meta" \
    "window=firstmate:fm-$2" \
    "endpoint_task_id=$2" \
    "worktree=$1/wt" \
    "project=$1/project" \
    "kind=$3" \
    "mode=direct-PR" \
    "yolo=off" \
    "spawn_gen=teardown-test-$2" \
    "decisions_reviewed=1" \
    "decision_keys="
}

# stat %m reports the same mount for the copy and the bind. The mount table
# names the bind, which is the signal a same-filesystem bind can hide from stat.
plant_bind_report() {  # <case_dir> <walk> <bind>
  local case_dir=$1 walk=$2 bind=$3 real_stat point
  real_stat=$(command -v stat)
  point=$(python3 -c '
import sys
out = []
for ch in sys.argv[1]:
    if ch == "\\":
        out.append("\\134")
    elif ch == " ":
        out.append("\\040")
    elif ch == "\t":
        out.append("\\011")
    elif ch == "\n":
        out.append("\\012")
    else:
        out.append(ch)
sys.stdout.write("".join(out))
' "$bind")
  # The copy itself sits on the root mount. A table that names only the bind
  # leaves the fallback resolver with no mount that contains the copy.
  printf '1 1 0:1 / / rw - ext4 /dev/disk1 rw\n' > "$case_dir/mountinfo"
  printf '2 1 0:1 / %s rw - ext4 /dev/disk0 rw\n' "$point" >> "$case_dir/mountinfo"
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
set -u
path=
wants_mount=0
for arg in "\$@"; do
  case "\$arg" in
    *%m*) wants_mount=1 ;;
  esac
  case "\$arg" in
    -*) ;;
    *) path=\$arg ;;
  esac
done
if [ "\$wants_mount" -eq 1 ] && { [ "\$path" = "$walk" ] || [ "\$path" = "$bind" ]; }; then
  printf '%s\n' same-mount
  exit 0
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/stat"
}

plant_readonly_tree() {  # <case_dir>
  local wt="$1/wt" outside="$1/outside"
  mkdir -p "$wt/copied-hooks/nested" "$outside"
  printf '#!/bin/sh\n' > "$wt/copied-hooks/nested/commit-msg"
  printf 'secret\n' > "$outside/file"
  ln -s "$outside" "$wt/copied-hooks/nested/escape-dir"
  chmod a-w "$wt/copied-hooks" "$wt/copied-hooks/nested" \
    "$wt/copied-hooks/nested/commit-msg" "$outside" "$outside/file"
}

run_teardown() {  # <case_dir> <id>
  : > "$1/treehouse.log"
  FM_HOME="$1" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/state" \
    FM_DATA_OVERRIDE="$1/data" \
    FM_CONFIG_OVERRIDE="$1/config" \
    FM_TREEHOUSE_LOG="$1/treehouse.log" \
    FM_TEST_SEAM="${FM_TEST_SEAM:-}" \
    FM_TEST_MOUNTINFO="${FM_TEST_MOUNTINFO:-}" \
    PATH="$1/fakebin:$PATH" \
    "$TEARDOWN" "$2"
}

test_scout_readonly_tree_is_deleted_and_outside_directory_stays() {
  local case_dir id=scout-ro rc dir_mode
  skip_if_directory_mode_is_bypassed "scout-readonly" && return 0
  case_dir=$(make_case scout-readonly)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  plant_readonly_tree "$case_dir"
  dir_mode=$(mode_of "$case_dir/outside")

  rc=0
  git -C "$case_dir/wt" clean -fd >"$case_dir/preclean.out" 2>"$case_dir/preclean.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-readonly: git clean deleted a non-writable tree"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "scout-readonly: the non-writable file was removed before teardown"

  rc=0
  run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "scout-readonly: teardown should succeed"$'\n'"$(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-readonly: the non-writable hooks tree is still in the scratch copy"
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "scout-readonly: teardown did not return the worktree"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/outside")" \
    "scout-readonly: outside directory mode changed"
  assert_equals "secret" "$(cat "$case_dir/outside/file")" \
    "scout-readonly: outside file contents changed"
  pass "a scratch scout with a non-writable nested tree is cleaned up, and the outside directory is unchanged"
}

test_ship_with_unlanded_readonly_tree_is_refused_unchanged() {
  local case_dir id=ship-dirty rc dir_mode
  skip_if_directory_mode_is_bypassed "ship-readonly" && return 0
  case_dir=$(make_case ship-dirty)
  write_task "$case_dir" "$id" ship
  plant_readonly_tree "$case_dir"
  dir_mode=$(mode_of "$case_dir/wt/copied-hooks/nested")

  rc=0
  run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "ship-readonly: teardown discarded a ship with uncommitted files"
  assert_grep "REFUSED" "$case_dir/stderr" \
    "ship-readonly: teardown did not refuse the uncommitted tree"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "ship-readonly: teardown returned the worktree after refusing it"
  [ -f "$case_dir/wt/copied-hooks/nested/commit-msg" ] \
    || fail "ship-readonly: the uncommitted file was removed"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/copied-hooks/nested")" \
    "ship-readonly: directory mode changed before the refusal"
  pass "a ship with an uncommitted non-writable tree is refused and left unchanged"
}

# A directory whose device is not the scratch copy must keep its mode, and
# cleanup must stop before the destructive return.
test_other_device_directory_is_not_made_writable() {
  local case_dir id=scout-dev rc dir_mode real_stat
  skip_if_directory_mode_is_bypassed "scout-other-device" && return 0
  case_dir=$(make_case scout-other-device)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  plant_readonly_tree "$case_dir"
  mkdir -p "$case_dir/wt/mnt"
  printf 'mounted\n' > "$case_dir/wt/mnt/secret"
  chmod a-w "$case_dir/wt/mnt" "$case_dir/wt/mnt/secret"
  dir_mode=$(mode_of "$case_dir/wt/mnt")
  real_stat=$(command -v stat)
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
set -u
path=
for arg in "\$@"; do
  case "\$arg" in
    -*) ;;
    *) path=\$arg ;;
  esac
done
if [ "\$path" = "$case_dir/wt/mnt" ]; then
  printf '%s\n' 999999999
  exit 0
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/stat"

  rc=0
  run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-other-device: teardown returned a nested mount"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "nested mount" "$case_dir/stderr" \
    "scout-other-device: teardown did not report the nested mount"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-other-device: teardown returned the worktree"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/mnt")" \
    "scout-other-device: directory on another device was made writable"
  assert_equals "mounted" "$(cat "$case_dir/wt/mnt/secret")" \
    "scout-other-device: file on another device was removed"
  [ -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-other-device: cleanup deleted the scratch copy despite the mount"
  pass "a directory on another device keeps its mode and stops cleanup before return"
}

# A same-filesystem bind mount has the copy device id. stat %m is the mount
# boundary find -xdev does not prune. Cleanup must stop before return.
test_same_filesystem_mount_is_not_made_writable() {
  local case_dir id=scout-bind rc dir_mode walk bind
  skip_if_directory_mode_is_bypassed "scout-bind" && return 0
  case_dir=$(make_case scout-bind)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  plant_readonly_tree "$case_dir"
  walk=$(cd "$case_dir/wt" && pwd -P)
  bind="$walk/bind"
  mkdir -p "$bind"
  printf 'mounted\n' > "$bind/secret"
  chmod a-w "$bind" "$bind/secret"
  dir_mode=$(mode_of "$bind")
  plant_bind_report "$case_dir" "$walk" "$bind"

  rc=0
  FM_TEST_MOUNTINFO="$case_dir/mountinfo" \
    run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-bind: teardown returned a nested mount"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "nested mount" "$case_dir/stderr" \
    "scout-bind: teardown did not report the nested mount"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-bind: teardown returned the worktree"
  assert_equals "$dir_mode" "$(mode_of "$bind")" \
    "scout-bind: bind mount was made writable"
  assert_equals "mounted" "$(cat "$bind/secret")" \
    "scout-bind: file on the bind mount was removed"
  [ -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-bind: cleanup deleted the scratch copy despite the mount"
  pass "a same-filesystem mount keeps its mode and stops cleanup before return"
}

# An already-writable mount under a mode 0444 ancestor becomes reachable once
# that ancestor is made searchable. The return must still not run.
test_writable_mount_under_unsearchable_ancestor_refuses_return() {
  local case_dir id=scout-hidden-mount rc dir_mode walk bind
  skip_if_directory_mode_is_bypassed "scout-hidden-mount" && return 0
  case_dir=$(make_case scout-hidden-mount)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  walk=$(cd "$case_dir/wt" && pwd -P)
  bind="$walk/locked/bind"
  mkdir -p "$bind"
  printf 'mounted\n' > "$bind/secret"
  dir_mode=$(mode_of "$bind")
  chmod 0444 "$walk/locked"
  plant_bind_report "$case_dir" "$walk" "$bind"

  rc=0
  FM_TEST_MOUNTINFO="$case_dir/mountinfo" \
    run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-hidden-mount: teardown returned a nested mount"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "nested mount" "$case_dir/stderr" \
    "scout-hidden-mount: teardown did not report the nested mount"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-hidden-mount: teardown returned the worktree"
  assert_equals "$dir_mode" "$(mode_of "$bind")" \
    "scout-hidden-mount: bind mount mode changed"
  assert_equals "mounted" "$(cat "$bind/secret")" \
    "scout-hidden-mount: file on the bind mount was removed"
  pass "a writable mount under an unsearchable directory stops cleanup before return"
}

# mount(8) listing replaces a newline in the name with ?. The kernel table
# keeps the escaped newline, and that name must still stop cleanup.
test_newline_mount_point_is_refused() {
  local case_dir id=scout-newline rc dir_mode walk bind
  skip_if_directory_mode_is_bypassed "scout-newline" && return 0
  case_dir=$(make_case scout-newline)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  walk=$(cd "$case_dir/wt" && pwd -P)
  bind="$walk/bind"$'\n'"more"
  mkdir -p -- "$bind"
  printf 'mounted\n' > "$bind/secret"
  dir_mode=$(mode_of "$bind")
  plant_bind_report "$case_dir" "$walk" "$bind"

  rc=0
  FM_TEST_MOUNTINFO="$case_dir/mountinfo" \
    run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-newline: teardown returned a nested mount"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "nested mount" "$case_dir/stderr" \
    "scout-newline: teardown did not report the nested mount"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-newline: teardown returned the worktree"
  assert_equals "$dir_mode" "$(mode_of "$bind")" \
    "scout-newline: mount mode changed"
  assert_equals "mounted" "$(cat "$bind/secret")" \
    "scout-newline: file on the mount was removed"
  pass "a mount point whose name contains a newline stops cleanup before return"
}

# Linux mount(8) replaces control characters when the kernel table is missing.
# Cleanup must refuse instead of trusting that listing.
test_missing_kernel_mount_table_refuses_cleanup() {
  local case_dir id=scout-no-mountinfo rc
  skip_if_directory_mode_is_bypassed "scout-no-mountinfo" && return 0
  case_dir=$(make_case scout-no-mountinfo)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  plant_readonly_tree "$case_dir"

  rc=0
  FM_TEST_MOUNTINFO="$case_dir/missing-mountinfo" \
    run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "scout-no-mountinfo: teardown returned without a mount table"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "no lossless mount table" "$case_dir/stderr" \
    "scout-no-mountinfo: teardown did not report the missing mount table"
  assert_no_grep "return --force" "$case_dir/treehouse.log" \
    "scout-no-mountinfo: teardown returned the worktree"
  [ -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-no-mountinfo: cleanup deleted the scratch copy"
  pass "a missing kernel mount table stops cleanup before return"
}

# Mode 0444 has no owner search bit. chmod u+w leaves it unsearchable, so the
# walk must restore read and search too or the nested tree stays behind.
test_mode_0444_directory_is_deleted() {
  local case_dir id=scout-0444 rc
  skip_if_directory_mode_is_bypassed "scout-0444" && return 0
  case_dir=$(make_case scout-0444)
  write_task "$case_dir" "$id" scout
  mkdir -p "$case_dir/data/$id" "$case_dir/wt/locked/nested"
  printf 'findings\n' > "$case_dir/data/$id/report.md"
  printf 'hidden\n' > "$case_dir/wt/locked/nested/file"
  chmod 0444 "$case_dir/wt/locked/nested/file" \
    "$case_dir/wt/locked/nested" "$case_dir/wt/locked"

  rc=0
  run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "scout-0444: teardown should succeed"$'\n'"$(cat "$case_dir/stderr")"
  [ ! -e "$case_dir/wt/locked" ] \
    || fail "scout-0444: the mode 0444 tree is still in the scratch copy"$'\n'"$(cat "$case_dir/stderr")"
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "scout-0444: teardown did not return the worktree"
  pass "a scratch scout directory left at mode 0444 is cleaned up"
}

test_scout_readonly_tree_is_deleted_and_outside_directory_stays
test_ship_with_unlanded_readonly_tree_is_refused_unchanged
test_other_device_directory_is_not_made_writable
test_same_filesystem_mount_is_not_made_writable
test_writable_mount_under_unsearchable_ancestor_refuses_return
test_newline_mount_point_is_refused
test_missing_kernel_mount_table_refuses_cleanup
test_mode_0444_directory_is_deleted
