#!/usr/bin/env bash
# fm-afk-sentinel.sh - fork-only away watchdog that lives outside tmux and
# outside the harness, so a lost fleet tmux server or a stopped away watcher is
# reported even when everything supervising the fleet died with it.
#
# Why it exists: the away daemon and its watcher run as a session on the fleet's
# tmux server, so when that server dies they die with it and nothing alarms.
# This watchdog shares no failure domain with them: `start` launches it as a
# fully detached process (double fork plus setsid, standard streams redirected),
# in its own session and process group, and it runs no tmux command at all.
#
# Usage:
#   fm-afk-sentinel.sh start   Record the fleet tmux server identity from the
#                              caller's TMUX (server pid plus that pid's start
#                              time and command), then launch the detached
#                              watchdog. Idempotent: a live watchdog is kept.
#                              Refuses without a standing away-posture record.
#   fm-afk-sentinel.sh stop    Stop the recorded watchdog by exact pid identity.
#   fm-afk-sentinel.sh status  Exit 0 when the recorded watchdog is running,
#                              1 when its record names a dead process, 2 when
#                              no watchdog was recorded, and 3 when the home
#                              cannot be resolved.
#   fm-afk-sentinel.sh run ... Internal: the loop `start` detaches.
#   fm-afk-sentinel.sh notify <summary>
#                              Internal: fire the wedge-alarm channels once.
#
# LOOP. While state/.afk-contract exists it checks every poll interval:
#   1. The recorded fleet tmux server: its pid gone or its identity changed,
#      confirmed on one re-read, means the fleet's tmux server stopped. With no
#      TMUX at start (a non-tmux primary) this check is skipped; a TMUX whose
#      server cannot be identified is recorded as a finding at start instead.
#   2. The watcher liveness beacon (state/.last-watcher-beat) older than the
#      threshold means away monitoring stopped. This check arms only after the
#      watchdog has seen a fresh beacon, so a home that never ran a watcher does
#      not alarm.
# On a finding it adds one line per new finding to state/.afk-sentinel-alarm
# (what stopped and when it was detected) and fires the wedge-alarm channels
# (docs/wedge-alarm.md owns them; FM_WEDGE_ALARM_EXEC stays the only notifier
# seam), at most once per re-alarm interval. It never attempts recovery.
# It exits by itself once the away record is gone or its own record names
# another process, so a missed stop is harmless.
#
# Files (all under state/): .afk-sentinel (pid, pid identity, and the watched
# server identity, written by the running watchdog), .afk-sentinel-alarm (the
# durable finding lines bin/fm-afk-return.sh reports as gaps and clears after a
# clean catch-up), and .afk-sentinel.log.
#
# Tunables: FM_AFK_SENTINEL_POLL_SECS (60), FM_AFK_SENTINEL_BEAT_SECS (900),
# FM_AFK_SENTINEL_REALARM_SECS (3600).
set -u

SENTINEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SENTINEL_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_HOME=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
  echo "fm-afk-sentinel: FM_HOME directory cannot be resolved" >&2
  exit 3
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
STATE=$(CDPATH='' cd -- "$STATE" 2>/dev/null && pwd -P) || {
  echo "fm-afk-sentinel: state directory cannot be resolved" >&2
  exit 3
}
export FM_HOME STATE
[ -z "${FM_STATE_OVERRIDE:-}" ] || export FM_STATE_OVERRIDE="$STATE"

RECORD="$STATE/.afk-sentinel"
MARKER="$STATE/.afk-sentinel-alarm"
SENTINEL_LOG="$STATE/.afk-sentinel.log"
BEAT="$STATE/.last-watcher-beat"

# shellcheck source=bin/fm-wake-lib.sh
. "$SENTINEL_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SENTINEL_DIR/fm-afk-contract.sh"

sentinel_log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$SENTINEL_LOG" 2>/dev/null || true; }

sentinel_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf 'epoch %s' "$1"
}

sentinel_field() {  # <name>  value of name=... in the record
  sed -n "s/^$1=//p" "$RECORD" 2>/dev/null | head -1
}

# Exit 0 when the recorded watchdog is live, 1 when recorded but dead, 2 when
# no record exists.
sentinel_status() {
  local pid identity
  [ -f "$RECORD" ] || return 2
  pid=$(sentinel_field pid)
  identity=$(sentinel_field identity)
  fm_pid_alive "$pid" || return 1
  [ -n "$identity" ] && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ] || return 1
  return 0
}

sentinel_start() {
  local server_pid="" server_identity="" server_socket="" rest i
  if ! fm_afk_contract_present "$STATE"; then
    echo "fm-afk-sentinel: no away-posture record; nothing to watch" >&2
    return 1
  fi
  if sentinel_status; then
    echo "fm-afk-sentinel: already running pid $(sentinel_field pid)" >&2
    return 0
  fi
  if [ -n "${TMUX:-}" ]; then
    server_socket=${TMUX%%,*}
    rest=${TMUX#*,}
    server_pid=${rest%%,*}
    case "$server_pid" in ''|*[!0-9]*) server_pid="" ;; esac
    [ -z "$server_pid" ] || server_identity=$(fm_pid_identity "$server_pid" 2>/dev/null) || server_pid=""
    if [ -z "$server_pid" ]; then
      # A tmux primary whose server cannot be identified is a degraded window,
      # not a non-tmux one: record it so the return brief reports the gap.
      printf 'the fleet tmux server named by TMUX (%s) could not be identified at away entry, so its loss was not watched; detected %s\n' \
        "$TMUX" "$(sentinel_iso "$(date +%s)")" >> "$MARKER"
      echo "fm-afk-sentinel: the fleet tmux server could not be identified; watching the watcher beacon only" >&2
    fi
  fi
  rm -f "$RECORD"
  # Double fork plus setsid puts the loop in its own session and process group,
  # so neither the harness's background-task reaping nor a tmux server hangup
  # reaches it. perl supplies setsid(2), which macOS has no command for.
  if ! perl -MPOSIX=setsid -e '
      my $log = shift;
      defined(my $pid = fork) or die "fork: $!"; exit 0 if $pid;
      setsid() or die "setsid: $!";
      defined($pid = fork) or die "fork: $!"; exit 0 if $pid;
      chdir "/"; delete @ENV{qw(TMUX TMUX_PANE)};
      open STDIN, "<", "/dev/null"; open STDOUT, ">>", $log; open STDERR, ">&STDOUT";
      exec @ARGV or die "exec: $!";' \
      "$SENTINEL_LOG" "$SENTINEL_DIR/fm-afk-sentinel.sh" run "$server_pid" "$server_identity" "$server_socket"; then
    echo "fm-afk-sentinel: could not launch the detached watchdog" >&2
    return 1
  fi
  for i in $(seq 1 50); do
    if sentinel_status; then
      if [ -n "$server_pid" ]; then
        echo "fm-afk-sentinel: started pid $(sentinel_field pid), watching tmux server pid $server_pid and the watcher beacon" >&2
      else
        echo "fm-afk-sentinel: started pid $(sentinel_field pid), watching the watcher beacon (no tmux server to watch)" >&2
      fi
      return 0
    fi
    [ "$i" -lt 50 ] && sleep 0.1
  done
  echo "fm-afk-sentinel: the detached watchdog did not confirm its start; see $SENTINEL_LOG" >&2
  return 1
}

sentinel_stop() {
  local pid identity i
  sentinel_status
  case $? in
    2) return 0 ;;
    1) rm -f "$RECORD"; return 0 ;;
  esac
  pid=$(sentinel_field pid)
  identity=$(sentinel_field identity)
  kill -TERM "$pid" 2>/dev/null || true
  for i in $(seq 1 50); do
    fm_pid_alive "$pid" || break
    [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ] || break
    [ "$i" -lt 50 ] && sleep 0.1
  done
  if fm_pid_alive "$pid" && [ "$(fm_pid_identity "$pid" 2>/dev/null)" = "$identity" ]; then
    echo "fm-afk-sentinel: watchdog pid $pid did not exit; it exits by itself once the away record is gone" >&2
    return 1
  fi
  [ "$(sentinel_field pid)" != "$pid" ] || rm -f "$RECORD"
  return 0
}

# Fire the wedge-alarm channels in a child process (the `notify` subcommand).
# Sourcing the daemon for its channel block puts it in library mode, which
# defaults the notifier seam to discard; this is an executed production program
# like the daemon itself, so restore the seam to exactly what the caller's
# environment set.
sentinel_alarm() {  # <summary>
  "$SENTINEL_DIR/fm-afk-sentinel.sh" notify "$1" >/dev/null 2>&1 || true
}

sentinel_notify() {  # <summary>
  local had_exec exec_value
  had_exec=${FM_WEDGE_ALARM_EXEC+set}
  exec_value=${FM_WEDGE_ALARM_EXEC-}
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$SENTINEL_DIR/fm-supervise-daemon.sh"
  if [ -n "$had_exec" ]; then FM_WEDGE_ALARM_EXEC=$exec_value; else unset FM_WEDGE_ALARM_EXEC; fi
  LOG=$SENTINEL_LOG
  wedge_alarm_notify "$1" "$MARKER"
}

SLEEP_PID=""
sentinel_exit() {
  [ -z "$SLEEP_PID" ] || kill "$SLEEP_PID" 2>/dev/null || true
  [ "$(sentinel_field pid)" != "$SELF_PID" ] || rm -f "$RECORD"
  sentinel_log "stopped"
  exit 0
}

sentinel_server_alive() {  # <pid> <identity>
  fm_pid_alive "$1" && [ "$(fm_pid_identity "$1" 2>/dev/null)" = "$2" ]
}

sentinel_run() {
  local server_pid=${1:-} server_identity=${2:-} server_socket=${3:-}
  local poll beat_limit realarm pending tmp now age beat_armed=0 last_alarm=0 server_reported=0 beat_reported=0 findings summary beat_epoch
  poll=${FM_AFK_SENTINEL_POLL_SECS:-60}
  beat_limit=${FM_AFK_SENTINEL_BEAT_SECS:-900}
  realarm=${FM_AFK_SENTINEL_REALARM_SECS:-3600}
  trap '' HUP
  trap sentinel_exit TERM INT
  fm_current_pid SELF_PID || exit 1
  if sentinel_status && [ "$(sentinel_field pid)" != "$SELF_PID" ]; then
    exit 0
  fi
  tmp=$(mktemp "$STATE/.afk-sentinel.XXXXXX") || exit 1
  if ! {
    printf 'pid=%s\n' "$SELF_PID"
    printf 'identity=%s\n' "$(fm_pid_identity "$SELF_PID")"
    printf 'server_pid=%s\n' "$server_pid"
    printf 'server_identity=%s\n' "$server_identity"
    printf 'server_socket=%s\n' "$server_socket"
    printf 'started=%s\n' "$(date +%s)"
  } > "$tmp" || ! mv "$tmp" "$RECORD"; then
    rm -f "$tmp"
    exit 1
  fi
  sentinel_log "started pid $SELF_PID; tmux server pid ${server_pid:-none}; poll ${poll}s, beacon limit ${beat_limit}s"
  while :; do
    fm_afk_contract_present "$STATE" || { sentinel_log "away record gone"; sentinel_exit; }
    [ "$(sentinel_field pid)" = "$SELF_PID" ] || { sentinel_log "record names another watchdog"; exit 0; }
    now=$(date +%s)
    pending=""
    if [ -n "$server_pid" ] && [ "$server_reported" -eq 0 ] && ! sentinel_server_alive "$server_pid" "$server_identity"; then
      sleep 2
      if ! sentinel_server_alive "$server_pid" "$server_identity"; then
        server_reported=1
        pending="the fleet tmux server (pid $server_pid${server_socket:+, socket $server_socket}) stopped; detected $(sentinel_iso "$now")"
      fi
    fi
    age=$(fm_path_age "$BEAT")
    if [ "$age" -lt "$beat_limit" ]; then
      beat_armed=1
      beat_reported=0
    elif [ "$beat_armed" -eq 1 ] && [ "$beat_reported" -eq 0 ]; then
      beat_reported=1
      beat_epoch=$(fm_path_mtime "$BEAT" 2>/dev/null) && beat_epoch=$(sentinel_iso "$beat_epoch") || beat_epoch=unknown
      pending="${pending:+$pending
}the away watcher stopped beating (last beat $beat_epoch, limit ${beat_limit}s); detected $(sentinel_iso "$now")"
    fi
    if [ -n "$pending" ]; then
      printf '%s\n' "$pending" >> "$MARKER"
      sentinel_log "finding: $pending"
      last_alarm=0
    fi
    if [ -s "$MARKER" ] && { [ "$server_reported" -eq 1 ] || [ "$beat_reported" -eq 1 ]; } \
      && [ $((now - last_alarm)) -ge "$realarm" ]; then
      findings=$(tr '\n' ';' < "$MARKER" | sed 's/;$//; s/;/; /g')
      summary="away watchdog: $findings - see $MARKER"
      sentinel_alarm "$summary"
      last_alarm=$now
      sentinel_log "alarm fired"
    fi
    sleep "$poll" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""
  done
}

case "${1:-}" in
  start) sentinel_start ;;
  stop) sentinel_stop ;;
  status) sentinel_status ;;
  run) shift; sentinel_run "$@" ;;
  notify) sentinel_notify "${2:-}" ;;
  -h|--help|help) sed -n '/^# Usage:/,/^# LOOP\./p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' ;;
  *) sed -n '/^# Usage:/,/^# LOOP\./p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
