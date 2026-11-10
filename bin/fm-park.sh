#!/usr/bin/env bash
# fm-park.sh - record a bounded supervisor park for a worker that cannot
# declare it, and retire named steering records that park supersedes.
#
# Usage: FM_HOME=<home> fm-park.sh <task-id>
#          --until <YYYY-MM-DDTHH:MM[:SS]Z> --reason <text>
#          [--retire <NNN.msg> ...]
#
# A worker killed by the condition it should declare cannot append its own
# paused line. This command appends that line on the supervisor's behalf:
#   paused [key=supervisor-park] [by=supervisor] [at=<epoch>]: <reason> until <UTC>
# bin/fm-classify-lib.sh owns how a paused line is read, including `until`.
# [by=supervisor] records who wrote the line. [key=supervisor-park] keeps an
# unrelated keyless resolution from ending the wait. A later status line that
# is not a resolution ends it the same way any other pause ends.
#
# --retire names pending inbox records, by basename only, to move from
# <task>.inbox/ to <task>.inbox/retired/. The original record bytes stay
# intact. A sibling <seq>.retired sidecar is the provenance:
#   schema=fm-task-inbox-retire.v1
#   at=<UTC>
#   by=supervisor
#   task=<task-id>
#   record=<NNN.msg>
#   until=<UTC>
#   not-worker-acknowledgement=1
#   reason=<text>
# That move is not a worker acknowledgement. Unnamed pending records stay in
# the inbox root. A record already in handled/ was read by the worker and is
# refused rather than rewritten. Sequence allocation and idempotent enqueue
# both see retired/ (bin/fm-task-inbox-lib.sh), so a retired sequence is not
# reused and a transport retry of the same body does not create a new pending
# copy. Ringing a retired record types nothing.
#
# The pause line is appended only after every named retirement succeeds. A
# failure puts back any record this command already moved. bin/fm-control.sh
# exit does not retire inbox records and does not call this command.
# A local secondmate is not relaunched while this pause still holds
# (bin/fm-secondmate-liveness-lib.sh).
#
# Refuses a missing task record, a remotely placed secondmate, a last status
# of done, failed, or captain-held, an until time that is malformed or not in
# the future, and a reason that is empty, longer than 400 characters, contains
# a newline, or itself contains an until timestamp. A retire name that is not
# a pending regular file in the inbox root is refused before anything moves.
# Does not stop the agent, change its copy of the work, or discard an
# instruction the caller did not name.
#
# FM_HOME must be explicit. FM_STATE_OVERRIDE selects the state directory, as
# other task commands do.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-park refuses to resolve a task without an explicit firstmate home" >&2
  exit 2
fi
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory" >&2
  exit 1
fi
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-park cannot resolve tasks for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"

die() {
  echo "error: $1" >&2
  exit 1
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi
ID=$1
shift
fm_pr_task_id_valid "$ID" || {
  echo "error: '$ID' is not a task id" >&2
  exit 2
}

UNTIL_TEXT=
REASON=
REASON_SET=0
RETIRE_NAMES=
want=
for arg in "$@"; do
  if [ -n "$want" ]; then
    case "$arg" in
      --*) die "--$want requires a value" ;;
    esac
    case "$want" in
      until) UNTIL_TEXT=$arg ;;
      reason) REASON=$arg; REASON_SET=1 ;;
      retire)
        fm_task_inbox_seq_of "$arg" >/dev/null || die "--retire '$arg' is not an inbox record basename"
        case $'\n'"$RETIRE_NAMES" in
          *$'\n'"$arg"$'\n'*) die "duplicate --retire $arg" ;;
        esac
        RETIRE_NAMES="${RETIRE_NAMES}${arg}"$'\n'
        ;;
    esac
    want=
    continue
  fi
  case "$arg" in
    --until) want=until ;;
    --reason) want=reason ;;
    --retire) want=retire ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown argument '$arg'" ;;
  esac
done
[ -z "$want" ] || die "--$want requires a value"
[ -n "$UNTIL_TEXT" ] || die "--until is required"
[ "$REASON_SET" = 1 ] || die "--reason is required"

case "$REASON" in
  *$'\n'*|*$'\r'*) die "--reason must be a single line" ;;
esac
REASON=${REASON#"${REASON%%[![:space:]]*}"}
REASON=${REASON%"${REASON##*[![:space:]]}"}
[ -n "$REASON" ] || die "--reason is empty"
[ "${#REASON}" -le 400 ] || die "--reason is longer than 400 characters"
if printf '%s\n' "$REASON" | grep -Eq 'until[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'; then
  die "--reason must not contain an until timestamp; the bound is --until"
fi

UNTIL_EPOCH=$(fm_utc_iso_to_epoch "$UNTIL_TEXT") || die "--until '$UNTIL_TEXT' is not a UTC timestamp"
NOW=$(date +%s)
[ "$UNTIL_EPOCH" -gt "$NOW" ] || die "--until '$UNTIL_TEXT' is not in the future"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || die "task $ID has no metadata in this home"
case "$(fm_meta_get "$META" kind)" in
  ship|scout|secondmate) ;;
  *) die "task $ID is not a ship, scout, or secondmate" ;;
esac
[ -z "$(fm_meta_get "$META" remote_host)" ] || die "task $ID is a remotely placed secondmate; park it on that host, where its steering inbox lives"

STATUS="$STATE/$ID.status"
if [ -e "$STATUS" ] && { [ -L "$STATUS" ] || [ ! -f "$STATUS" ]; }; then
  die "status file for $ID is not a regular file"
fi
case "$(status_line_verb "$(last_status_line "$STATUS")")" in
  done|failed|captain-held)
    die "task $ID last status is already $(status_line_verb "$(last_status_line "$STATUS")"); reconcile that before parking"
    ;;
esac

LINE=$(status_stamp_line "paused [key=supervisor-park] [by=supervisor]: $REASON until $UNTIL_TEXT")
status_is_paused "$LINE" || die "internal: pause line is not a paused declaration"
got_until=$(status_paused_until "$LINE") || die "internal: pause line has no readable until"
[ "$got_until" = "$UNTIL_EPOCH" ] || die "internal: pause line until does not match --until"
[ "$(_fm_decision_key "$LINE")" = supervisor-park ] || die "internal: pause line lost its supervisor-park key"

fm_lease_guard "$ID" 'supervisor park'
INBOX_LOCK_HELD=0
INBOX_LOCK=
MOVED_NAMES=
release_locks() {
  if [ "$INBOX_LOCK_HELD" = 1 ]; then
    INBOX_LOCK_HELD=0
    fm_lock_release "$INBOX_LOCK" || true
  fi
  fm_lease_guard_release || true
}
trap release_locks EXIT

INBOX=$(fm_task_inbox_dir "$STATE" "$ID")
RETIRED=$(fm_task_inbox_retired_dir "$STATE" "$ID")

park_restore() {
  local name src dest side
  [ -n "$MOVED_NAMES" ] || return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    src="$INBOX/$name"
    dest="$RETIRED/$name"
    side="$RETIRED/${name%.msg}.retired"
    rm -f -- "$side"
    if [ -f "$dest" ] && [ ! -L "$dest" ] && [ ! -e "$src" ]; then
      mv -- "$dest" "$src" || return 1
    fi
  done <<EOF
$MOVED_NAMES
EOF
}

retire_fail() {
  local message=$1
  park_restore || die "$message; restore of already moved records also failed"
  die "$message"
}

if [ -n "$RETIRE_NAMES" ]; then
  [ -d "$INBOX" ] && [ ! -L "$INBOX" ] || die "task $ID has no steering inbox; named records are not pending"
  if [ -L "$RETIRED" ]; then
    die "task $ID retired directory is a symlink"
  fi
  mkdir -p -- "$RETIRED" || die "could not create the retired directory"
  [ -d "$RETIRED" ] && [ ! -L "$RETIRED" ] || die "retired directory is not a real directory"
  INBOX_LOCK="$INBOX/.seq.lock"
  fm_task_inbox_lock_acquire "$INBOX_LOCK" || die "could not lock the steering inbox"
  INBOX_LOCK_HELD=1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    src="$INBOX/$name"
    dest="$RETIRED/$name"
    if [ -L "$src" ]; then
      die "--retire $name is a symlink"
    fi
    if [ ! -f "$src" ]; then
      if [ -f "$INBOX/handled/$name" ] && [ ! -L "$INBOX/handled/$name" ]; then
        die "--retire $name was already acknowledged by the worker"
      fi
      if [ -f "$dest" ] && [ ! -L "$dest" ]; then
        die "--retire $name is already retired"
      fi
      die "--retire $name is not a pending steering record"
    fi
    if [ -e "$dest" ] || [ -L "$dest" ]; then
      die "--retire $name already has a retired record"
    fi
  done <<EOF
$RETIRE_NAMES
EOF
  PARKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    src="$INBOX/$name"
    dest="$RETIRED/$name"
    side="$RETIRED/${name%.msg}.retired"
    if ! mv -- "$src" "$dest"; then
      retire_fail "could not retire $name"
    fi
    MOVED_NAMES="${MOVED_NAMES}${name}"$'\n'
    tmp=$(mktemp "$RETIRED/.retire.XXXXXX") || retire_fail "could not write provenance for $name"
    if ! {
      printf 'schema=fm-task-inbox-retire.v1\n'
      printf 'at=%s\n' "$PARKED_AT"
      printf 'by=supervisor\n'
      printf 'task=%s\n' "$ID"
      printf 'record=%s\n' "$name"
      printf 'until=%s\n' "$UNTIL_TEXT"
      printf 'not-worker-acknowledgement=1\n'
      printf 'reason=%s\n' "$REASON"
    } > "$tmp"; then
      rm -f -- "$tmp"
      retire_fail "could not write provenance for $name"
    fi
    if ! mv -- "$tmp" "$side"; then
      rm -f -- "$tmp"
      retire_fail "could not write provenance for $name"
    fi
  done <<EOF
$RETIRE_NAMES
EOF
fi

if ! printf '%s\n' "$LINE" >> "$STATUS"; then
  retire_fail "could not append the pause for $ID"
fi

RETIRE_COUNT=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  RETIRE_COUNT=$((RETIRE_COUNT + 1))
done <<EOF
$RETIRE_NAMES
EOF
printf 'parked: %s until %s retired=%s\n' "$ID" "$UNTIL_TEXT" "$RETIRE_COUNT"
