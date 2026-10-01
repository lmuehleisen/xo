#!/usr/bin/env bash
# tests/fm-worker-tmux-isolation.test.sh - a ship worker's bare
# `tmux kill-server` must not reach the fleet server hosting its pane
# (docs/tmux-backend.md "Worker isolation from the fleet server").
#
# A stand-in fleet runs on a private -S socket. The real spawn's launch is
# executed in a synthetic pane whose TMUX and TMUX_PANE name that stand-in, the
# way a worker pane inherits them, with the harness replaced by a probe that
# records its environment and runs the bare kill-server. Nothing reads
# bin/fm-spawn.sh's source. A teardown case then checks that the private
# directory's servers are stopped and the directory removed, and a retire case
# checks that planted sockets cannot turn that cleanup against another server.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-private-tmux-lib.sh
. "$ROOT/bin/fm-private-tmux-lib.sh"
fm_git_identity

REAL_TMUX=$(command -v tmux 2>/dev/null || true)
if [ -z "$REAL_TMUX" ]; then
  echo "skip: tmux not found (worker tmux isolation)"
  exit 0
fi
REAL_SLEEP=$(command -v sleep)
TEARDOWN="$ROOT/bin/fm-teardown.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-tmux)
# Short, because a socket path is capped (103 bytes on macOS).
FLEET_DIR=$(mktemp -d /tmp/fmwti.XXXXXX)
FLEET_SOCK="$FLEET_DIR/fleet"
PRIVATE_DIRS=()

ltmux() { env -u TMUX -u TMUX_PANE "$REAL_TMUX" "$@"; }

# pid_gone <pid>: true once <pid> has exited, allowing a stopped tmux server up
# to five seconds, since kill-server returns before the server process exits.
pid_gone() {
  for _ in $(seq 1 50); do
    kill -0 "$1" 2>/dev/null || return 0
    "$REAL_SLEEP" 0.1
  done
  return 1
}

cleanup_worker_tmux() {
  local d sock
  for d in "${PRIVATE_DIRS[@]+"${PRIVATE_DIRS[@]}"}"; do
    case "$d" in /tmp/fmwt-*) fm_private_tmux_retire "$d" || true ;; esac
  done
  # Every socket under FLEET_DIR is a stand-in this suite created.
  while IFS= read -r -d '' sock; do
    ltmux -S "$sock" kill-server >/dev/null 2>&1 || true
  done < <(find "$FLEET_DIR" -type s -print0 2>/dev/null)
  rm -rf "$FLEET_DIR"
  fm_test_cleanup
}
trap cleanup_worker_tmux EXIT

start_fleet() {
  ltmux -S "$FLEET_SOCK" kill-server >/dev/null 2>&1 || true
  ltmux -S "$FLEET_SOCK" new-session -d -s firstmate -n captain "$REAL_SLEEP 600" || return 1
  ltmux -S "$FLEET_SOCK" new-window -d -t firstmate -n fm-worker "$REAL_SLEEP 600" || return 1
  FLEET_TMUX=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{socket_path},#{pid},0')
  FLEET_PANE=$(ltmux -S "$FLEET_SOCK" display-message -p -t firstmate:fm-worker '#{pane_id}')
}

fleet_windows() {
  ltmux -S "$FLEET_SOCK" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | sort | tr '\n' ' '
}

# install_probe <bin-dir> <out>: records the environment, starts a lab server
# with a bare tmux, records its socket, then runs the bare kill-server. Paths
# are baked in because an allowlisted launch clears the environment.
install_probe() {
  cat > "$1/codex" <<SH
#!/bin/sh
{
  printf 'TMUX=%s\n' "\${TMUX-unset}"
  printf 'TMUX_PANE=%s\n' "\${TMUX_PANE-unset}"
  printf 'TMUX_TMPDIR=%s\n' "\${TMUX_TMPDIR-unset}"
} > '$2'
# With neither TMUX nor a private TMUX_TMPDIR, a bare tmux would reach the
# default server, so a broken launch records its environment and stops here.
if [ -z "\${TMUX-}" ]; then
  case "\${TMUX_TMPDIR-}" in ''|/tmp|/tmp/) exit 0 ;; esac
fi
'$REAL_TMUX' new-session -d -s lab '$REAL_SLEEP 600'
printf 'socket=%s\n' "\$('$REAL_TMUX' display-message -p -t lab '#{socket_path}')" >> '$2'
'$REAL_TMUX' kill-server >/dev/null 2>&1
SH
  chmod +x "$1/codex"
}

probe_value() { sed -n "s/^$1=//p" "$2" | tail -1; }

test_ship_worker_cannot_reach_the_fleet() {
  local setting id case_dir home proj wt fakebin out status dir real result
  for setting in absent enabled; do
    id="ship-$setting-t1"
    case_dir="$TMP_ROOT/$setting"
    home="$case_dir/home"
    proj="$case_dir/project"
    wt="$case_dir/wt"
    fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
    fm_test_spawn_home "$home" codex
    fm_git_worktree "$proj" "$wt" "wt-$setting"
    fm_test_spawn_brief "$home" "$id"
    [ "$setting" = absent ] || : > "$home/config/launch-env-allowlist"
    out=$(FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_PANE_LOG="$case_dir/pane.log" \
      fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode direct-PR --yolo off)
    status=$?
    expect_code 0 "$status" "ship spawn with allowlist=$setting should succeed: $out"
    dir=$(sed -n 's/^worker_tmux_dir=//p' "$home/state/$id.meta")
    PRIVATE_DIRS+=("$dir")
    [ -n "$dir" ] || fail "allowlist=$setting: the task record should name the private tmux directory"

    result="$case_dir/probe.out"
    install_probe "$fakebin" "$result"
    start_fleet || fail "could not start the stand-in fleet"
    env -i HOME="$TMP_ROOT/pane-home" PATH="$fakebin:$PATH" TERM=xterm \
      TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" \
      /bin/sh -c "$(grep '^export ' "$case_dir/pane.log")
$(cat "$case_dir/launch.log")" || fail "allowlist=$setting: the emitted launch failed to run"

    assert_equals "captain fm-worker " "$(fleet_windows)" \
      "allowlist=$setting: the stand-in fleet must survive the worker's bare tmux kill-server"
    assert_equals unset "$(probe_value TMUX "$result")" "allowlist=$setting: the worker must not inherit TMUX"
    assert_equals unset "$(probe_value TMUX_PANE "$result")" "allowlist=$setting: the worker must not inherit TMUX_PANE"
    assert_equals "$dir" "$(probe_value TMUX_TMPDIR "$result")" \
      "allowlist=$setting: the worker's TMUX_TMPDIR must be its private directory"
    real=$(cd "$dir" && pwd -P)
    assert_contains "$(probe_value socket "$result")" "$real/tmux-" \
      "allowlist=$setting: the worker's bare tmux must reach a server in its private directory"
  done
  pass "a ship worker's bare tmux kill-server reaches only its private server, with and without an allowlist"
}

# Without the boundary, the same probe with the fleet's TMUX inherited does stop
# the stand-in fleet even though TMUX_TMPDIR is private, so the case above is
# not passing vacuously.
test_control_inherited_tmux_reaches_the_fleet() {
  local bin="$TMP_ROOT/control-bin" dir="$TMP_ROOT/control-private"
  mkdir -p "$bin"
  (umask 077 && mkdir -p "$dir")
  install_probe "$bin" "$TMP_ROOT/control.out"
  start_fleet || fail "could not start the stand-in fleet"
  env -i HOME="$TMP_ROOT/pane-home" PATH="$PATH" TERM=xterm \
    TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" TMUX_TMPDIR="$dir" "$bin/codex"
  [ -z "$(fleet_windows)" ] ||
    fail "control: an inherited TMUX should have let a bare kill-server stop the stand-in fleet"
  pass "control: without the launch boundary an inherited TMUX outranks TMUX_TMPDIR"
}

# make_teardown_case <name> <id>: a home whose landed local-only ship <id> can be
# torn down, with fake endpoint tools; sets TD_CASE, TD_HOME, and TD_FAKEBIN.
make_teardown_case() {
  local id=$2
  TD_CASE="$TMP_ROOT/$1"
  TD_HOME="$TD_CASE/home"
  TD_FAKEBIN="$TD_CASE/fakebin"
  mkdir -p "$TD_HOME/state" "$TD_HOME/config" "$TD_HOME/data" "$TD_FAKEBIN"
  touch "$TD_HOME/state/.last-watcher-beat"
  git init -q --bare "$TD_CASE/origin.git"
  git -C "$TD_CASE/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$TD_CASE/origin.git" "$TD_CASE/seed" 2>/dev/null
  git -C "$TD_CASE/seed" commit -q --allow-empty -m baseline || fail "could not commit the teardown fixture baseline"
  git -C "$TD_CASE/seed" push -q origin HEAD:main || fail "could not push the teardown fixture baseline"
  git clone -q "$TD_CASE/origin.git" "$TD_CASE/project"
  git -C "$TD_CASE/project" remote set-head origin main 2>/dev/null || true
  git -C "$TD_CASE/project" worktree add -q -b "fm/$id" "$TD_CASE/wt" main
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TD_FAKEBIN/treehouse"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TD_FAKEBIN/gh"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$TD_FAKEBIN/gh-axi"
  # The endpoint is fake; only an exact-socket call reaches the real tmux.
  cat > "$TD_FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
[ "\${1:-}" = -S ] || exit 0
exec '$REAL_TMUX' "\$@"
SH
  chmod +x "$TD_FAKEBIN"/*
}

# write_teardown_meta <id> <worker-tmux-dir>
write_teardown_meta() {
  fm_write_meta "$TD_HOME/state/$1.meta" \
    "window=firstmate:fm-$1" "endpoint_task_id=$1" "worktree=$TD_CASE/wt" \
    "project=$TD_CASE/project" "kind=ship" "mode=local-only" "spawn_gen=worker-tmux-$1" \
    "worker_tmux_dir=$2"
}

# run_teardown <id>: tear the task down from a pane inheriting the stand-in fleet.
run_teardown() {
  FM_HOME="$TD_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$TD_HOME/state" \
    FM_DATA_OVERRIDE="$TD_HOME/data" FM_CONFIG_OVERRIDE="$TD_HOME/config" \
    TMUX="$FLEET_TMUX" TMUX_PANE="$FLEET_PANE" PATH="$TD_FAKEBIN:$PATH" \
    "$TEARDOWN" "$1" 2>&1
}

# private_tmux_dir <home> <id>: the private directory spawn derives for <id>.
private_tmux_dir() {
  printf '/tmp/fmwt-%s' "$(printf '%s\n%s' "$(cd "$1" && pwd -P)" "$2" |
    { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12)"
}

# Teardown stops every server the worker left in its private directory, including
# one it named with -S there, removes the directory, and leaves the fleet running.
test_teardown_retires_the_private_directory() {
  local id=leak-t1 dir sock own_pid out status
  make_teardown_case teardown "$id"
  dir=$(private_tmux_dir "$TD_HOME" "$id")
  PRIVATE_DIRS+=("$dir")
  (umask 077 && mkdir "$dir") || fail "could not create the private tmux directory $dir"
  write_teardown_meta "$id" "$dir"

  env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" "$REAL_TMUX" new-session -d -s leaked "$REAL_SLEEP 600" ||
    fail "could not start the leaked private server"
  sock=$(env -u TMUX -u TMUX_PANE TMUX_TMPDIR="$dir" "$REAL_TMUX" display-message -p '#{socket_path}')
  ltmux -S "$dir/own" new-session -d -s own "$REAL_SLEEP 600" || fail "could not start the worker's own -S server"
  own_pid=$(ltmux -S "$dir/own" display-message -p '#{pid}')
  [ -n "$own_pid" ] || fail "could not read the worker's own -S server pid"
  start_fleet || fail "could not start the stand-in fleet"

  # A server teardown cannot reach keeps the record that names its directory.
  chmod 000 "$dir/own"
  out=$(run_teardown "$id")
  status=$?
  chmod 600 "$dir/own"
  [ "$status" -ne 0 ] || fail "teardown must refuse while a server in the private directory cannot be stopped"
  assert_contains "$out" "private tmux directory $dir could not be retired" \
    "teardown did not name the private tmux directory it could not retire"
  [ -f "$TD_HOME/state/$id.meta" ] || fail "teardown must keep the record while its private tmux directory survives"
  kill -0 "$own_pid" 2>/dev/null || fail "the unreachable server should still be running"

  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "teardown of a landed task should succeed once its servers are reachable: $out"
  ! ltmux -S "$sock" has-session >/dev/null 2>&1 || fail "teardown must stop the worker's private tmux server"
  pid_gone "$own_pid" || fail "teardown must stop a server the worker started with -S in its directory"
  [ ! -e "$dir" ] || fail "teardown must remove the private tmux directory"
  assert_equals "captain fm-worker " "$(fleet_windows)" "teardown must leave the stand-in fleet running"
  [ ! -e "$TD_HOME/state/$id.meta" ] || fail "a completed teardown must remove the task record"
  pass "teardown refuses while a private tmux server is unreachable, then stops the servers, removes the directory, and leaves the fleet running"
}

# A recorded private directory derived from another home path, as after the home
# moved, is not touched, but while it survives teardown keeps the record, which
# may be the only pointer to a live server in it.
test_teardown_keeps_the_record_for_a_moved_private_directory() {
  local id=moved-t1 dir out status
  make_teardown_case moved "$id"
  mkdir -p "$TD_CASE/old-home"
  dir=$(private_tmux_dir "$TD_CASE/old-home" "$id")
  PRIVATE_DIRS+=("$dir")
  (umask 077 && mkdir "$dir") || fail "could not create the moved private tmux directory $dir"
  write_teardown_meta "$id" "$dir"
  start_fleet || fail "could not start the stand-in fleet"

  out=$(run_teardown "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "teardown must refuse while a moved private tmux directory survives"
  assert_contains "$out" "recorded worker tmux directory $dir is not where this home now places" \
    "teardown did not name the moved private tmux directory"
  [ -f "$TD_HOME/state/$id.meta" ] || fail "teardown must keep the record while a moved private tmux directory survives"
  [ -d "$dir" ] || fail "teardown must leave a moved private tmux directory untouched"

  rm -rf "$dir"
  out=$(run_teardown "$id")
  status=$?
  expect_code 0 "$status" "teardown should succeed once the moved directory is gone: $out"
  [ ! -e "$TD_HOME/state/$id.meta" ] || fail "a completed teardown must remove the task record"
  assert_equals "captain fm-worker " "$(fleet_windows)" "teardown must leave the stand-in fleet running"
  pass "teardown keeps the record while a moved private tmux directory survives and leaves that directory untouched"
}

# A worker can leave sockets in its private directory that name another server:
# a hardlink or a rename of a live foreign socket, or a socket whose path
# contains a newline followed by a foreign socket's path. The shared retire used
# by teardown, spawn rollback, and the test runner must stop only servers whose
# own socket is inside the directory, and must keep the directory, since a
# renamed socket may be the foreign server's only one. Every server here is a
# stand-in on a -S socket under FLEET_DIR.
test_retire_ignores_planted_foreign_sockets() {
  local dir="$FLEET_DIR/p" linked="$FLEET_DIR/a" moved="$FLEET_DIR/b"
  local split="$FLEET_DIR/c" nl own_pid nl_pid moved_pid
  (umask 077 && mkdir "$dir") || fail "could not create the private directory"
  ltmux -S "$linked" new-session -d "$REAL_SLEEP 600" || fail "could not start the hardlinked stand-in"
  ltmux -S "$moved" new-session -d "$REAL_SLEEP 600" || fail "could not start the renamed stand-in"
  ltmux -S "$split" new-session -d "$REAL_SLEEP 600" || fail "could not start the newline stand-in"
  moved_pid=$(ltmux -S "$moved" display-message -p '#{pid}')
  ln "$linked" "$dir/linked" || fail "could not hardlink a live socket into the private directory"
  mv "$moved" "$dir/moved" || fail "could not rename a live socket into the private directory"
  nl="$dir/n"$'\n'"$split"
  mkdir -p "$(dirname "$nl")"
  ltmux -S "$nl" new-session -d "$REAL_SLEEP 600" || fail "could not start the worker's newline-named server"
  nl_pid=$(ltmux -S "$nl" display-message -p '#{pid}')
  ltmux -S "$dir/own" new-session -d "$REAL_SLEEP 600" || fail "could not start the worker's own -S server"
  own_pid=$(ltmux -S "$dir/own" display-message -p '#{pid}')

  # The planted sockets really do reach the foreign servers, and a line-split
  # scan really does yield a foreign path, so the case cannot pass vacuously.
  assert_equals "$(ltmux -S "$linked" display-message -p '#{pid}')" \
    "$(ltmux -S "$dir/linked" display-message -p '#{pid}')" "the hardlink must reach the stand-in"
  assert_equals "$moved_pid" "$(ltmux -S "$dir/moved" display-message -p '#{pid}')" \
    "the renamed socket must reach the stand-in"
  find "$dir" -type s -print | grep -qxF "$split" ||
    fail "a newline-split scan should yield the outside socket path"

  if fm_private_tmux_retire "$dir"; then
    fail "retire must report failure while a socket in the directory answers for an outside server"
  fi
  ltmux -S "$linked" has-session 2>/dev/null || fail "retire must not stop a server hardlinked into the directory"
  ltmux -S "$dir/moved" has-session 2>/dev/null ||
    fail "retire must neither stop nor unlink a server's only socket renamed into the directory"
  ltmux -S "$split" has-session 2>/dev/null || fail "retire must not stop a server named after a newline"
  pid_gone "$nl_pid" || fail "retire must stop the worker's newline-named server"
  pid_gone "$own_pid" || fail "retire must stop the worker's own -S server"
  pass "retire stops only servers socketed inside the directory and keeps it while a hardlinked, renamed, or newline-named socket answers for another server"
}

# A worker can make its own live socket unreachable, for example with chmod.
# Removing the directory then would strand that server with no reachable socket,
# so retire must keep it and report failure, while a socket a stopped server
# left behind must not block the removal.
test_retire_keeps_the_directory_when_a_server_cannot_be_stopped() {
  local dir="$FLEET_DIR/q" pid
  (umask 077 && mkdir "$dir") || fail "could not create the private directory"
  ltmux -S "$dir/stopped" new-session -d "$REAL_SLEEP 600" || fail "could not start the stopped server"
  ltmux -S "$dir/stopped" kill-server || fail "could not stop the stopped server"
  [ -S "$dir/stopped" ] || fail "a stopped server should leave its socket behind"
  ltmux -S "$dir/own" new-session -d "$REAL_SLEEP 600" || fail "could not start the worker's own -S server"
  pid=$(ltmux -S "$dir/own" display-message -p '#{pid}')
  chmod 000 "$dir/own"

  if fm_private_tmux_retire "$dir"; then
    fail "retire must report failure when a server cannot be inspected"
  fi
  [ -S "$dir/own" ] || fail "retire must keep the directory holding an unreachable live server"
  kill -0 "$pid" 2>/dev/null || fail "the unreachable server should still be running"

  chmod 600 "$dir/own"
  fm_private_tmux_retire "$dir" || fail "retire should succeed once the server is reachable"
  pid_gone "$pid" || fail "retire must stop the reachable server"
  [ ! -e "$dir" ] || fail "retire must remove the directory despite the stopped server's socket"
  pass "retire keeps the directory while a live server in it cannot be stopped, but not for a stopped server's socket"
}

test_ship_worker_cannot_reach_the_fleet
test_control_inherited_tmux_reaches_the_fleet
test_teardown_retires_the_private_directory
test_teardown_keeps_the_record_for_a_moved_private_directory
test_retire_ignores_planted_foreign_sockets
test_retire_keeps_the_directory_when_a_server_cannot_be_stopped
