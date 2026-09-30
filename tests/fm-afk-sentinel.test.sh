#!/usr/bin/env bash
# tests/fm-afk-sentinel.test.sh - the detached away watchdog (bin/fm-afk-sentinel.sh).
#
# A private -S tmux server stands in for the fleet: the watchdog is started from
# inside one of its panes, so it inherits a TMUX naming that server exactly as
# it would from the captain's pane, and the server is then killed by its exact
# socket. Every tmux command here runs under env -u TMUX -u TMUX_PANE with that
# explicit -S socket, so the ambient server is never touched. The wedge-alarm
# recorder seam (FM_WEDGE_ALARM_EXEC) receives every alarm, so no real
# notification is posted.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SENTINEL="$ROOT/bin/fm-afk-sentinel.sh"
CONTRACT="$ROOT/bin/fm-afk-contract.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-afk-sentinel)
# A short socket directory keeps the socket path under macOS's 103-byte limit.
SOCKDIR=$(mktemp -d /tmp/fmas.XXXXXX)
SOCK="$SOCKDIR/fleet.sock"
STARTED_PIDS=""
cleanup() {
  local pid
  for pid in $STARTED_PIDS; do kill -TERM "$pid" 2>/dev/null || true; done
  if command -v tmux >/dev/null 2>&1; then
    env -u TMUX -u TMUX_PANE tmux -S "$SOCK" kill-server 2>/dev/null || true
  fi
  rm -rf "$SOCKDIR"
  fm_test_cleanup
}
trap cleanup EXIT

RECORDER="$TMP/recorder.sh"
ALARMS="$TMP/alarms"
cat > "$RECORDER" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> '$ALARMS'
EOF
chmod +x "$RECORDER"

export FM_WEDGE_ALARM_EXEC="$RECORDER"
export FM_WEDGE_ALARM_CHANNEL=osascript
export FM_AFK_SENTINEL_POLL_SECS=1
export FM_AFK_SENTINEL_REALARM_SECS=3600

new_home() {  # <name>
  local home="$TMP/$1"
  mkdir -p "$home/state"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$CONTRACT" enter --words 'keep going' >/dev/null 2>&1 \
    || fail "$1: could not record the away posture"
  printf '%s\n' "$home"
}

sentinel() {  # <home> <subcommand>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$SENTINEL" "$2"
}

sentinel_pid() {  # <home>
  sed -n 's/^pid=//p' "$1/state/.afk-sentinel" 2>/dev/null
}

wait_for() {  # <seconds> <command...>
  local limit=$1 _
  shift
  for _ in $(seq 1 $((limit * 10))); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

# A zombie left for a slow init to reap has exited, so it does not count.
proc_running() {  # <pid>
  local st
  st=$(ps -o stat= -p "$1" 2>/dev/null) || return 1
  case "$st" in ''|*Z*) return 1 ;; esac
}

remember_pid() {  # <home>
  STARTED_PIDS="$STARTED_PIDS $(sentinel_pid "$1")"
}

# ---------------------------------------------------------------------------
# The fleet server dies: the watchdog survives, records it, and alarms.
# ---------------------------------------------------------------------------
case_fleet_server_killed() {
  local home fakebin tmux_log pid server_pid
  if ! command -v tmux >/dev/null 2>&1; then
    echo "skip: tmux not found (fleet-server case)"
    return 0
  fi
  home=$(new_home fleet)
  # Any tmux call the watchdog made would land in this log.
  fakebin="$TMP/fakebin"
  tmux_log="$TMP/tmux-calls"
  mkdir -p "$fakebin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %q\nexit 1\n' "$tmux_log" > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  env -u TMUX -u TMUX_PANE tmux -S "$SOCK" new-session -d -s fleet \
    "PATH='$fakebin':\"\$PATH\" FM_HOME='$home' FM_STATE_OVERRIDE='$home/state' '$SENTINEL' start 2> '$TMP/start.err'; exec sleep 600" \
    || fail "fleet: could not start the stand-in fleet server"
  server_pid=$(env -u TMUX -u TMUX_PANE tmux -S "$SOCK" display-message -p '#{pid}')
  wait_for 10 sentinel "$home" status || fail "fleet: watchdog did not start from the lab pane: $(cat "$TMP/start.err" 2>/dev/null)"
  remember_pid "$home"
  pid=$(sentinel_pid "$home")
  assert_equals "$(sed -n 's/^server_pid=//p' "$home/state/.afk-sentinel")" "$server_pid" "fleet: watchdog records the lab server pid from the pane's TMUX"

  env -u TMUX -u TMUX_PANE tmux -S "$SOCK" kill-server || fail "fleet: could not kill the stand-in fleet server"
  wait_for 10 grep -qs 'fleet tmux server' "$home/state/.afk-sentinel-alarm" \
    || fail "fleet: no marker within the poll bound after the server was killed"
  proc_running "$pid" || fail "fleet: the watchdog died with the tmux server"
  pass "fleet: the watchdog survives the server kill and writes the marker within the poll bound"
  assert_grep "pid $server_pid, socket $SOCK" "$home/state/.afk-sentinel-alarm" "fleet: the marker does not name the server pid and socket"
  wait_for 5 grep -qs "^osascript|away watchdog: the fleet tmux server (pid $server_pid" "$ALARMS" \
    || fail "fleet: the recorder seam did not receive the alarm: $(cat "$ALARMS" 2>/dev/null)"
  pass "fleet: the alarm reaches the wedge-alarm recorder seam naming what stopped"
  [ ! -s "$tmux_log" ] || fail "fleet: the watchdog ran tmux: $(cat "$tmux_log")"
  pass "fleet: the watchdog ran no tmux command"

  sentinel "$home" stop 2>/dev/null || fail "fleet: stop failed"
  wait_for 5 eval "! proc_running $pid" || fail "fleet: stop left the watchdog running"
  sentinel "$home" status
  [ $? -eq 2 ] || fail "fleet: stop left the watchdog record behind"
  assert_present "$home/state/.afk-sentinel-alarm" "fleet: stop removed the marker"
  pass "fleet: stop ends the watchdog by identity and keeps the marker for the return brief"
}

# ---------------------------------------------------------------------------
# The watcher beacon ages: the check arms on a fresh beacon, alarms once, and
# re-alarms no sooner than the re-alarm interval.
# ---------------------------------------------------------------------------
case_aged_beacon() {
  local home pid old
  : > "$ALARMS"
  home=$(new_home beacon)
  FM_AFK_SENTINEL_BEAT_SECS=5 FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    env -u TMUX -u TMUX_PANE "$SENTINEL" start 2>/dev/null || fail "beacon: start failed"
  remember_pid "$home"
  pid=$(sentinel_pid "$home")
  sleep 3
  assert_absent "$home/state/.afk-sentinel-alarm" "beacon: alarmed before any fresh beacon was seen"
  pass "beacon: a home that never ran a watcher does not alarm"

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$SENTINEL" start 2>/dev/null || fail "beacon: second start failed"
  assert_equals "$(sentinel_pid "$home")" "$pid" "beacon: a second start keeps the running watchdog"

  touch "$home/state/.last-watcher-beat"
  sleep 2
  old=$(( $(date +%s) - 600 ))
  fm_touch_epoch "$old" "$home/state/.last-watcher-beat"
  wait_for 10 grep -qs 'away watcher stopped beating' "$home/state/.afk-sentinel-alarm" \
    || fail "beacon: no marker for an aged beacon"
  wait_for 5 grep -qs '^osascript|away watchdog: the away watcher stopped beating' "$ALARMS" \
    || fail "beacon: the recorder seam did not receive the aged-beacon alarm"
  pass "beacon: an aged beacon writes the marker and fires the alarm"
  sleep 3
  assert_equals "$(grep -c . "$ALARMS")" 1 "beacon: no re-alarm inside the re-alarm interval"
  assert_equals "$(grep -c . "$home/state/.afk-sentinel-alarm")" 1 "beacon: the finding is recorded once"

  # Self-exit once the away record is gone.
  rm -f "$home/state/.afk-contract"
  wait_for 10 eval "! proc_running $pid" || fail "beacon: watchdog outlived the away record"
  assert_absent "$home/state/.afk-sentinel" "beacon: the watchdog record outlived the watchdog"
  pass "beacon: the watchdog exits by itself and drops its record once the away record is gone"
}

case_unidentified_tmux_server() {
  local home
  home=$(new_home degraded)
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" TMUX="/tmp/fmas-none.sock,999999999,0" \
    "$SENTINEL" start 2>/dev/null || fail "degraded: start failed"
  remember_pid "$home"
  assert_equals "$(sed -n 's/^server_pid=//p' "$home/state/.afk-sentinel")" "" "degraded: an unidentified server was recorded as watched"
  assert_grep 'could not be identified at away entry' "$home/state/.afk-sentinel-alarm" "degraded: an unidentified tmux server left no finding"
  sentinel "$home" stop 2>/dev/null || fail "degraded: stop failed"
  pass "start: a TMUX whose server cannot be identified is recorded as a finding, not treated as a non-tmux primary"
}

case_requires_away_record() {
  local home="$TMP/noaway"
  mkdir -p "$home/state"
  if sentinel "$home" start 2>/dev/null; then
    fail "start: launched without an away-posture record"
  fi
  assert_absent "$home/state/.afk-sentinel" "start: wrote a record without an away-posture record"
  pass "start: refuses without an away-posture record"
}

case_requires_away_record
case_unidentified_tmux_server
case_aged_beacon
case_fleet_server_killed
