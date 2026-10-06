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

# A directory whose device is not the scratch copy must keep its mode.
# find -xdev still matches that directory; the device check is what skips it.
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
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "scout-other-device: teardown did not reach the worktree return (rc=$rc)"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals "$dir_mode" "$(mode_of "$case_dir/wt/mnt")" \
    "scout-other-device: directory on another device was made writable"
  assert_equals "mounted" "$(cat "$case_dir/wt/mnt/secret")" \
    "scout-other-device: file on another device was removed"
  [ ! -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-other-device: the same-device hooks tree was not cleaned up"$'\n'"$(cat "$case_dir/stderr")"
  pass "a directory on another device keeps its mode while the scratch copy is still cleaned up"
}

# A same-filesystem bind mount has the copy's device id. stat %m is the mount
# boundary find -xdev does not prune. The reported mount must keep its mode.
test_same_filesystem_mount_is_not_made_writable() {
  local case_dir id=scout-bind rc dir_mode real_stat walk bind
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
  real_stat=$(command -v stat)
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
if [ "\$wants_mount" -eq 1 ] && [ "\$path" = "$bind" ]; then
  printf '%s\n' "\$path"
  exit 0
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/stat"

  rc=0
  run_teardown "$case_dir" "$id" >"$case_dir/stdout" 2>"$case_dir/stderr" || rc=$?
  assert_grep "return --force $case_dir/wt" "$case_dir/treehouse.log" \
    "scout-bind: teardown did not reach the worktree return (rc=$rc)"$'\n'"$(cat "$case_dir/stderr")"
  assert_equals "$dir_mode" "$(mode_of "$bind")" \
    "scout-bind: bind mount was made writable"
  assert_equals "mounted" "$(cat "$bind/secret")" \
    "scout-bind: file on the bind mount was removed"
  [ ! -e "$case_dir/wt/copied-hooks" ] \
    || fail "scout-bind: the same-device hooks tree was not cleaned up"$'\n'"$(cat "$case_dir/stderr")"
  pass "a same-filesystem mount keeps its mode while the scratch copy is still cleaned up"
}

test_scout_readonly_tree_is_deleted_and_outside_directory_stays
test_ship_with_unlanded_readonly_tree_is_refused_unchanged
test_other_device_directory_is_not_made_writable
test_same_filesystem_mount_is_not_made_writable
