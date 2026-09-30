#!/usr/bin/env bash
# fm-devin-rate-limit-retry.sh - automatic retry for a Devin CLI worker whose
# turn stopped on the model rate limit. Fork-only; bin/fm-devin-lib.sh wires
# it as native Devin hooks in the worker's private config.
#
# Usage: fm-devin-rate-limit-retry.sh <event> <state-dir> <task-id> <fm-home>
#   events: arm | stop | end | retire | watch (internal)
#
# Why a sentinel: when Devin's model returns "Reached free model rate limit
# ... Your limit will reset in <N> <unit>" three times in a row, Devin stops
# the turn, renders "Something went wrong ... Send a message to retry", and
# idles on an empty composer. That error path fires NO hook - not Stop, not
# any other (live-verified on devin 3000.11.3; the harness-adapters devin
# reference records the evidence) - so nothing inside Devin can react. The
# only structural record of it is Devin's own session log,
# ~/.local/share/devin/cli/logs/devin_<date>_<pid>.log, written by the
# `devin acp` process that also runs the hooks, where the failed turn ends
# with one `Sending error response ... method=session/prompt error=` line
# carrying the same message, reset time included.
#
#   arm (UserPromptSubmit)
#       Opens a new turn: records a fresh turn token under
#       <state-dir>/<task-id>.devin-retry/, finds the session log by walking
#       the hook's process ancestry to the first devin process with a
#       devin_*_<pid>.log (the newest, when a reused pid left an older one),
#       and starts one detached `watch` sentinel for this
#       turn from the log's current line count. A turn whose log cannot be
#       found is logged as unarmed and gets no automatic retry.
#   stop (Stop)
#       The turn ended normally: retires the sentinel, resets the
#       consecutive-retry count, and when the blocked line below was
#       written, appends `resolved [key=devin-rate-limit]` to close it.
#   end (SessionEnd)
#       Retires the sentinel without touching the count.
#   retire (not a hook)
#       bin/fm-devin-lib.sh's teardown and relaunch retire: renames the
#       per-task directory away, which ends any sentinel within one poll,
#       resolves the blocked line when one was written, and removes it; when
#       the rename or the resolve fails, the state is left in place and
#       retire exits 1.
#   watch (internal; started by arm)
#       Follows the session log until this turn's token is replaced (a new
#       prompt, a Stop, a SessionEnd, or a retire) or a turn-ending rate-limit
#       error appears. On that error it parses the stated reset (60 seconds
#       when none is stated) and schedules one retry at
#         reset + BACKOFF * 2^count + random(0..JITTER)
#       where count is the number of automatic retries already sent since the
#       task's last normal Stop. When that time comes, it also waits until
#       SPACING seconds have passed since the latest retry any worker in this
#       home started or finished sending, recorded in
#       <state-dir>/devin-rate-limit-last-send, so workers that hit the limit
#       together retry apart; when another worker holds that record's lock
#       throughout, the retry goes out unstaggered. It gives up if the turn
#       token changes while it waits, and otherwise sends one ordinary steer
#       through bin/fm-send.sh, so the message lands in the task's durable
#       inbox and the doorbell submit starts the retry turn. Once count
#       reaches MAX it sends nothing and appends one
#       `blocked [key=devin-rate-limit]` status line instead; a send that fails
#       is not counted and appends the same keyed line.
#
# Every arm, detection, retry, cap, and failure is one JSON line in the
# home-wide <state-dir>/devin-rate-limit-log.jsonl, the evidence for how often
# the limit is hit, e.g.
#   jq -s 'group_by(.event) | map({event: .[0].event, n: length})' state/devin-rate-limit-log.jsonl
#
# Every hook invocation exits 0 so a failure here never breaks Devin's
# lifecycle; `retire`, which is not a hook, exits 1 when it left the task's
# retry state in place, so a relaunch does not proceed past a sentinel it
# could not retire or a blocker it could not resolve.
#
# Tuning (environment, read by the sentinel; seconds unless noted):
#   FM_DEVIN_RETRY_MAX      consecutive automatic retries before the cap (4)
#   FM_DEVIN_RETRY_BACKOFF  base extra delay, doubled per retry sent (15)
#   FM_DEVIN_RETRY_JITTER   upper bound of the random extra delay (10)
#   FM_DEVIN_RETRY_SPACING  minimum gap between two retries in one home (30)
#   FM_DEVIN_RETRY_POLL     log and token poll interval (5)
#   FM_DEVIN_RETRY_LIFETIME longest a sentinel watches the log for the error
#                           (21600); a retry it then schedules still waits out
#                           the stated reset and spacing, however long, unless
#                           the turn changes first
#   FM_DEVIN_RETRY_LOG_DIR  Devin's log directory
#                           (~/.local/share/devin/cli/logs)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"

usage() {
  sed -n '2,/^set -u$/p' "$SELF" | sed '$d; s/^# \{0,1\}//'
}

case "${1-}" in
-h | --help)
  usage
  exit 0
  ;;
esac

[ "$#" -ge 4 ] || {
  echo "usage: fm-devin-rate-limit-retry.sh <arm|stop|end|retire> <state-dir> <task-id> <fm-home>" >&2
  exit 0
}

EVENT=$1 STATE=$2 TASK=$3 HOME_DIR=$4
shift 4
DIR="$STATE/$TASK.devin-retry"
EVENT_LOG="$STATE/devin-rate-limit-log.jsonl"
STATUS="$STATE/$TASK.status"
LAST_SEND="$STATE/devin-rate-limit-last-send"
SEND_LOCK="$LAST_SEND.lock"
LOG_DIR=${FM_DEVIN_RETRY_LOG_DIR:-$HOME/.local/share/devin/cli/logs}
MAX=${FM_DEVIN_RETRY_MAX:-4}
BACKOFF=${FM_DEVIN_RETRY_BACKOFF:-15}
JITTER=${FM_DEVIN_RETRY_JITTER:-10}
SPACING=${FM_DEVIN_RETRY_SPACING:-30}
POLL=${FM_DEVIN_RETRY_POLL:-5}
LIFETIME=${FM_DEVIN_RETRY_LIFETIME:-21600}
KEY=devin-rate-limit
RETRY_MESSAGE="Automatic retry: your last turn stopped on Devin's model rate limit, which has now reset. Continue the task from where it stopped."

log_event() {  # <event> <detail>
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg task "$TASK" \
    --arg event "$1" --arg detail "$2" \
    '{ts:$ts, task:$task, event:$event, detail:$detail}' \
    >>"$EVENT_LOG" 2>/dev/null || true
}

# Appends one status line, creating the task's status file when this is its
# first event; nothing is written once the task's state dir is gone. Fails,
# and logs it, when the line could not be appended, so callers keep the state
# that line would have changed.
status_append() {  # <line>
  [ -d "$STATE" ] || return 0
  printf '%s\n' "$1" >>"$STATUS" 2>/dev/null && return 0
  log_event failed "could not append to $STATUS: $1"
  return 1
}

set_turn() {  # <token>
  mkdir -p "$DIR" 2>/dev/null || return 1
  printf '%s\n' "$1" >"$DIR/turn.$$" && mv -f "$DIR/turn.$$" "$DIR/turn"
}

turn_is() {  # <token>
  [ "$(cat "$DIR/turn" 2>/dev/null)" = "$1" ]
}

retry_count() {
  local n
  n=$(cat "$DIR/count" 2>/dev/null) || n=0
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

# The session log belongs to the `devin` process that runs this hook, so the
# first ancestor that is a devin process with a devin_*_<pid>.log names it;
# other ancestors are skipped even when a reused pid left a log under their
# number, and when one left an older log for the devin pid itself, the most
# recently written one is the live session's.
find_session_log() {
  local pid=$PPID f newest comm _
  for _ in 1 2 3 4 5 6 7 8; do
    case "$pid" in '' | *[!0-9]* | 0 | 1) return 1 ;; esac
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || comm=
    comm=${comm%"${comm##*[! ]}"}
    newest=
    [ "${comm##*/}" = devin ] || {
      pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      continue
    }
    for f in "$LOG_DIR"/devin_*_"$pid".log; do
      [ -f "$f" ] || continue
      if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest=$f; fi
    done
    [ -z "$newest" ] || {
      printf '%s\n' "$newest"
      return 0
    }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

line_count() {  # <file>
  local n
  n=$(wc -l <"$1" 2>/dev/null | tr -d ' ') || n=0
  printf '%s' "${n:-0}"
}

# Seconds named by "reset in <N> <second|minute|hour>[s]"; 60 when absent.
reset_seconds() {  # <error-line>
  local parsed n unit
  parsed=$(printf '%s' "$1" | sed -nE 's/.*[Rr]eset in ([0-9]+) (second|minute|hour)s?.*/\1 \2/p' | head -1)
  n=${parsed%% *}
  unit=${parsed#* }
  case "$n" in '' | *[!0-9]*) printf '60' && return 0 ;; esac
  case "$unit" in
  minute) printf '%s' $((n * 60)) ;;
  hour) printf '%s' $((n * 3600)) ;;
  *) printf '%s' "$n" ;;
  esac
}

# Loads bin/fm-wake-lib.sh for its owner-checked locks on first use only,
# pointed at this state dir, because the library resolves and creates a state
# dir when it loads; a retire of an absent task must create nothing.
load_lock_lib() {
  command -v fm_lock_try_acquire >/dev/null 2>&1 && return 0
  FM_STATE_OVERRIDE=$STATE
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
}

# Takes an owner-checked lock (bin/fm-wake-lib.sh): only a lock whose owner
# process died is taken over, and only its owner releases it. Fails when the
# lock's directory is gone or a live owner keeps it past a 10-second wait;
# every section these locks guard takes milliseconds.
take_lock() {  # <lock-path>
  local deadline
  [ -d "${1%/*}" ] || return 1
  load_lock_lib || return 1
  deadline=$(($(date +%s) + 10))
  while :; do
    [ -d "${1%/*}" ] || return 1
    fm_lock_try_acquire "$1" && return 0
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

# The home-wide lock around the last-send record.
send_lock() {
  take_lock "$SEND_LOCK"
}

send_unlock() {
  ! command -v fm_lock_release >/dev/null 2>&1 || fm_lock_release "$SEND_LOCK" 2>/dev/null || true
}

# The epoch of the latest retry send any worker in this home started or
# finished. A send still in flight - its record names a live sender pid, for
# at most 300 seconds - counts as happening now. A real send records at most
# one second ahead, so anything later is not trusted to hold others back.
last_send() {
  local last pid now
  read -r last pid <"$LAST_SEND" 2>/dev/null || last=0
  case "$last" in '' | *[!0-9]*) last=0 ;; esac
  now=$(date +%s)
  case "${pid-}" in
  '' | *[!0-9]*) ;;
  *) ! kill -0 "$pid" 2>/dev/null || [ $((now - last)) -ge 300 ] || last=$((now + 1)) ;;
  esac
  [ "$last" -le $((now + 1)) ] || last=$((now + 1))
  printf '%s' "$last"
}

# Records a send at the current second rounded up, never moving the record
# back, marked in flight by this process until the finishing call; the
# caller holds the lock.
record_send() {  # [in-flight]
  local at last
  at=$(($(date +%s) + 1))
  last=$(last_send)
  [ "$at" -ge "$last" ] || at=$last
  printf '%s%s\n' "$at" "${1:+ $$}" >"$LAST_SEND.$$" && mv -f "$LAST_SEND.$$" "$LAST_SEND"
}

# Waits until SPACING has passed since the latest retry send in this home, then
# records this send's start under the lock so no other worker starts inside
# the gap. Fails when the turn's token is replaced first. When a live holder
# keeps the lock throughout, it goes ahead unstaggered and records nothing.
take_send_turn() {  # <token>
  while :; do
    wait_turn_until "$1" $(($(last_send) + SPACING)) || return 1
    send_lock || {
      log_event unstaggered "the retry send lock stayed held; retry sent without home-wide spacing"
      turn_is "$1"
      return
    }
    turn_is "$1" || {
      send_unlock
      return 1
    }
    if [ "$(date +%s)" -ge $(($(last_send) + SPACING)) ]; then
      record_send in-flight
      send_unlock
      return 0
    fi
    send_unlock
  done
}

# Appends a resolved line to the status log holding its blocked line. With no
# status log - teardown retires it before the retry state - there is no open
# blocker left, so nothing is written and no orphan log is created.
status_resolve() {  # <line>
  [ -f "$STATUS" ] || return 0
  status_append "$1"
}

cmd_arm() {
  local token log start locked=
  cat >/dev/null 2>&1 || true
  token="$(date +%s).$$.$RANDOM"
  # The turn is replaced even without the lock, because keeping the old token
  # would let the previous turn's sentinel send its retry into this one.
  ! task_lock || locked=1
  set_turn "$token" || {
    [ -z "$locked" ] || task_unlock
    return 0
  }
  [ -z "$locked" ] || task_unlock
  if ! log=$(find_session_log); then
    log_event unarmed "no Devin session log found in $LOG_DIR for the hook's process ancestry"
    return 0
  fi
  start=$(line_count "$log")
  nohup "$SELF" watch "$STATE" "$TASK" "$HOME_DIR" "$token" "$log" "$start" \
    </dev/null >/dev/null 2>&1 &
  return 0
}

# The per-task lock that orders the cap line against a new prompt, Stop, and
# retire, so a sentinel publishes a cap only for a turn that is still current
# and whichever hook retires that turn sees the cap and resolves it. Only these
# short sections take it, never a send.
task_lock() {
  take_lock "$DIR/.lock"
}

task_unlock() {
  ! command -v fm_lock_release >/dev/null 2>&1 || fm_lock_release "$DIR/.lock" 2>/dev/null || true
}

cmd_stop() {
  local locked=
  cat >/dev/null 2>&1 || true
  [ -d "$DIR" ] || return 0
  ! task_lock || locked=1
  set_turn "ended.$(date +%s)" || true
  rm -f "$DIR/count"
  if [ -e "$DIR/capped" ] &&
    status_resolve "resolved [at=$(date +%s)] [key=$KEY]: Devin finished a turn normally again after the rate limit"; then
    rm -f "$DIR/capped"
    log_event resolved "a normal turn ended after the retry cap"
  fi
  [ -z "$locked" ] || task_unlock
}

cmd_end() {
  cat >/dev/null 2>&1 || true
  [ -d "$DIR" ] || return 0
  set_turn "ended.$(date +%s)" || true
}

# Brings back retry state an earlier retire left under its retiring name when
# it could neither resolve nor restore it. A name whose pid is alive - a retire
# still running, or a reused pid - is left alone and fails this retire, since
# its blocker may still be open.
recover_retiring() {
  local r pid
  for r in "$DIR".retiring.*; do
    [ -d "$r" ] || continue
    pid=${r##*.}
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    ! kill -0 "$pid" 2>/dev/null || return 1
    if [ ! -e "$DIR" ]; then
      mv -- "$r" "$DIR" 2>/dev/null || return 1
    else
      [ ! -e "$r/capped" ] || : >"$DIR/capped" 2>/dev/null || return 1
      rm -rf -- "$r" 2>/dev/null || true
    fi
  done
}

cmd_retire() {
  local capped retiring="$DIR.retiring.$$"
  recover_retiring || return 1
  [ -d "$DIR" ] || return 0
  task_lock || true
  capped=
  [ ! -e "$DIR/capped" ] || capped=1
  # One rename retires the turn at once, ending any sentinel, while keeping the
  # marker until the resolved line is written; a retire that cannot rename or
  # resolve restores the state and exits 1, so the blocker and its marker stay
  # together for the next retire.
  if ! mv -- "$DIR" "$retiring" 2>/dev/null; then
    task_unlock
    return 1
  fi
  if [ -n "$capped" ] &&
    ! status_resolve "resolved [at=$(date +%s)] [key=$KEY]: the rate-limited Devin worker was relaunched or retired"; then
    if mv -- "$retiring" "$DIR" 2>/dev/null; then
      task_unlock
    else
      log_event failed "could not restore $DIR after a failed resolve; its marker is in $retiring"
    fi
    return 1
  fi
  [ -z "$capped" ] || log_event resolved "the retry state was retired after the retry cap"
  rm -rf -- "$retiring" 2>/dev/null || log_event failed "could not remove the retired $retiring"
  return 0
}

# Sleeps until <epoch>; fails as soon as this turn's token is replaced.
wait_turn_until() {  # <token> <epoch>
  local now
  while :; do
    turn_is "$1" || return 1
    now=$(date +%s)
    [ "$now" -lt "$2" ] || return 0
    if [ $(($2 - now)) -lt "$POLL" ]; then sleep $(($2 - now)); else sleep "$POLL"; fi
  done
}

# Publishes the keyed blocked line for <token>'s turn once, marked by the
# capped file that the turn's Stop or retire resolves. It is published only
# while the turn is still current, under the lock a new prompt, Stop, and
# retire take, so the turn's end always sees it; fails when nothing was
# published for this turn.
publish_blocked() {  # <token> <reason>
  local published=
  task_lock || {
    [ ! -d "$DIR" ] || log_event failed "the task's retry lock stayed held; the blocked line was not published"
    return 1
  }
  if turn_is "$1"; then
    published=1
    if [ ! -e "$DIR/capped" ]; then
      # The marker is written first and taken back when the line fails, so a
      # published blocked line always has the marker its resolution needs.
      if ! : >"$DIR/capped" 2>/dev/null; then
        log_event failed "could not record the blocker's marker in $DIR; the blocked line was not published"
        task_unlock
        return 1
      fi
      if ! status_append "blocked [at=$(date +%s)] [key=$KEY]: $2"; then
        rm -f "$DIR/capped"
        task_unlock
        return 1
      fi
      # A Stop or retire that gave up waiting for the lock may have ended
      # the turn while this line was written; resolve it here in that case.
      # The marker goes with that resolution, so a later cap publishes anew.
      turn_is "$1" ||
        ! status_resolve "resolved [at=$(date +%s)] [key=$KEY]: the rate-limited Devin turn ended while its blocker was being recorded" ||
        rm -f "$DIR/capped"
    fi
  fi
  task_unlock
  [ -n "$published" ]
}

cmd_watch() {
  local token=$1 log=$2 seen=$3 started now total segment line reset count \
    delay due
  started=$(date +%s)
  line=
  while :; do
    sleep "$POLL"
    turn_is "$token" || return 0
    now=$(date +%s)
    [ $((now - started)) -lt "$LIFETIME" ] || return 0
    total=$(line_count "$log")
    [ "$total" -gt "$seen" ] || continue
    segment=$(sed -n "$((seen + 1)),${total}p" "$log" 2>/dev/null)
    seen=$total
    line=$(printf '%s\n' "$segment" | grep -F 'method=session/prompt error=' | grep -i 'rate limit' | tail -1)
    [ -z "$line" ] || break
  done

  reset=$(reset_seconds "$line")
  count=$(retry_count)
  if [ "$count" -ge "$MAX" ]; then
    publish_blocked "$token" "Devin stopped on its model rate limit again after $count automatic retries; send it a message to retry, or move the work to another harness" &&
      log_event capped "rate limit after $count automatic retries; reset ${reset}s; no retry sent"
    return 0
  fi
  delay=$((reset + BACKOFF * (1 << count) + RANDOM % (JITTER + 1)))
  due=$(($(date +%s) + delay))
  log_event detected "reset ${reset}s; retry $((count + 1)) of $MAX due at $due"
  # Spacing is taken only once this retry is due and measured from real
  # sends, so a longer reset detected first, or a retry later superseded,
  # never delays another worker's.
  if ! wait_turn_until "$token" "$due" || ! take_send_turn "$token"; then
    log_event superseded "a new prompt or turn end arrived before retry $((count + 1))"
    return 0
  fi
  # Accepted residual race: a prompt submitted between the turn check above
  # and fm-send's enqueue still receives this retry, a harmless extra "continue"
  # steer. Holding a lock across the send that the arm hook waits on would
  # instead stall the retry's own doorbell, whose submit fires that hook while
  # fm-send is still ringing.
  # The count is written before the send, because the delivered retry starts
  # the next turn whose sentinel reads it, and restored when nothing was sent,
  # so the cap counts only retries the worker actually received.
  if ! { printf '%s\n' $((count + 1)) >"$DIR/count.$$" && mv -f "$DIR/count.$$" "$DIR/count"; } 2>/dev/null; then
    rm -f "$DIR/count.$$" 2>/dev/null
    log_event failed "retry $((count + 1)) of $MAX was not sent: its count could not be recorded"
    publish_blocked "$token" "Devin stopped on its model rate limit and its automatic retry could not be recorded; send it a message to retry" || true
    return 0
  fi
  if FM_HOME=$HOME_DIR FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-send.sh" "$TASK" "$RETRY_MESSAGE" >/dev/null 2>&1; then
    log_event retried "retry $((count + 1)) of $MAX sent"
  else
    if [ "$count" -eq 0 ]; then
      rm -f "$DIR/count"
    else
      printf '%s\n' "$count" >"$DIR/count.$$" && mv -f "$DIR/count.$$" "$DIR/count"
    fi
    log_event failed "retry $((count + 1)) of $MAX could not be sent through fm-send"
    publish_blocked "$token" "Devin stopped on its model rate limit and its automatic retry could not be sent; send it a message to retry" || true
  fi
  # The gap to the next worker's retry counts from when this send finished.
  if send_lock; then
    record_send
    send_unlock
  fi
}

case "$EVENT" in
arm) cmd_arm ;;
stop) cmd_stop ;;
end) cmd_end ;;
retire) cmd_retire || exit 1 ;;
watch) cmd_watch "$@" ;;
*) echo "fm-devin-rate-limit-retry.sh: unknown event '$EVENT'" >&2 ;;
esac
exit 0
