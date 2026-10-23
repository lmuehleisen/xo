#!/usr/bin/env bash
# fm-approved-publish.sh - run a task's prepared publication only under the
# captain's recorded approval of exactly that procedure.
#
# Usage:
#   fm-approved-publish.sh approval <task-id>
#   fm-approved-publish.sh check <task-id> [--approval <captain-task-id>]
#   fm-approved-publish.sh run <task-id> [--approval <captain-task-id>]
#
# The procedure is data the task prepares in data/<task-id>/publish/: an
# executable named `procedure` that takes one step name, plus whatever text
# files it reads (intent, verification plan, stop patterns). Every regular
# file there is covered by the procedure digest, so changing any of them after
# approval withdraws the approval; a symlink or other non-regular entry
# refuses. Keep run output elsewhere, for example in the task's publisher.
#
# Steps, in this order; the procedure must accept each one and exit 0 when it
# has nothing to do for it:
#   preflight  read-only: refuse unless every publication block is in place
#              and the outgoing content (target, branch, head) is the approved one
#   lift       lift the publication blocks for this run only
#   publish    the approved public writes, never with an auto-approval flag;
#              exit nonzero on any gate, finding, applied fix, or outcome
#              other than success
#   verify     read-only checks of what was published
#   restore    put every block back, then exit nonzero unless the blocked
#              state verifies; it must be safe to run from any state
# Each step runs with stdin from /dev/null, its working directory at the
# procedure directory, and FM_PUBLISH_TASK, FM_PUBLISH_DIR, and FM_PUBLISH_LOG
# in its environment. A step output line starting with `result: ` is repeated
# in the summary. An optional `stop-patterns` file holds extended regular
# expressions, one per line (blank and # lines ignored); a publish or verify
# output line matching one stops the run, as does any line containing REFUSED.
#
# Approval. `approval` prints the exact line, `Approved publish: <task-id>
# sha256:<digest>`, that firstmate puts in the captain's question and, only
# when the captain's words approve that publication, in the decision file it
# records through `bin/fm-captain-hold.sh answer`. `check` and `run` read the
# newest recorded captain decision on the approval task (default: <task-id>
# itself) through `fm-captain-hold.sh decision` and refuse unless it carries
# that exact line for the procedure as it is now. No flag, environment, or
# file overrides the check.
#
# `run` refuses a procedure whose non-comment lines spell an auto-approval
# flag (--yes, -y) or a publish-judge override, and allows one run per task at
# a time. It then runs preflight, lift, publish, and verify. The first failing
# step ends the run: nothing is answered, approved, retried, or overridden.
# Restore runs exactly once on every exit after preflight starts, including
# INT, TERM, and HUP, which it ignores while restoring. The full output goes to
# the terminal and to data/<task-id>/publish-logs/<UTC stamp>-<pid>.log,
# ending in a summary.
#
# Exit codes: 0 published, verified, and blocks restored; 2 usage; 3 refused
# before anything ran (no matching approval, an invalid procedure, or a run
# already in progress); 4 preflight failed; 5 lift failed; 6 publish stopped;
# 7 verify failed; 8 restore failed, which takes precedence: put the blocks
# back by hand before anything else; 130 interrupted.
set -u
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

refuse() {
  printf 'fm-approved-publish: refused: %s\n' "$*" >&2
  exit 3
}

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

TASK='' APPROVAL='' PROC_DIR='' PROC='' DIGEST='' APPROVAL_LINE=''
PATTERN_ARGS=()

parse_args() {  # <command> <args...>
  local command=$1
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --approval)
        [ "$command" != approval ] && [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        APPROVAL=$2
        shift
        ;;
      -*) usage >&2; exit 2 ;;
      *)
        [ -z "$TASK" ] || { usage >&2; exit 2; }
        TASK=$1
        ;;
    esac
    shift
  done
  [ -n "$APPROVAL" ] || APPROVAL=$TASK
  case "$TASK" in ''|*[!A-Za-z0-9._-]*) usage >&2; exit 2 ;; esac
  case "$APPROVAL" in ''|*[!A-Za-z0-9._-]*) usage >&2; exit 2 ;; esac
}

# Validate data/<task>/publish/ and compute its digest. Refuses (exit 3) on
# anything the runner would not run.
load_procedure() {
  local bad nl=$'\n'
  PROC_DIR=$DATA/$TASK/publish
  PROC=$PROC_DIR/procedure
  [ -d "$PROC_DIR" ] && [ ! -L "$PROC_DIR" ] \
    || refuse "no procedure directory $PROC_DIR"
  [ -f "$PROC" ] && [ -x "$PROC" ] || refuse "$PROC is missing or not executable"
  bad=$(find "$PROC_DIR" -mindepth 1 ! -type f ! -type d -print 2>&1 | head -n 1)
  [ -z "$bad" ] || refuse "the procedure directory holds a non-regular entry: $bad"
  bad=$(find "$PROC_DIR" -mindepth 1 -name "*$nl*" -print 2>&1 | head -n 1)
  [ -z "$bad" ] || refuse "the procedure directory holds a name with a line break"
  # One hash over every file's own hash and relative path, in byte order.
  DIGEST=$( (cd "$PROC_DIR" && find . -type f -print) | LC_ALL=C sort | (cd "$PROC_DIR" && perl -MDigest::SHA -ne '
    chomp;
    $all .= Digest::SHA->new(256)->addfile($_, "b")->hexdigest . "  $_\n";
    END { print "sha256:", Digest::SHA::sha256_hex($all // ""), "\n" }
  ')) || refuse "cannot read every file in $PROC_DIR"
  case "$DIGEST" in sha256:????????????????????????????????????????????????????????????????) ;;
    *) refuse "cannot compute the procedure digest" ;;
  esac
  APPROVAL_LINE="Approved publish: $TASK $DIGEST"
  bad=$(grep -nEv '^[[:space:]]*#' "$PROC" \
    | grep -E '(^|[^[:alnum:]_-])(--yes|-y)([^[:alnum:]_-]|$)|fm-publish-judge(\.sh)?[[:space:]]+override' \
    | head -n 1)
  [ -z "$bad" ] || refuse "$PROC spells an auto-approval flag or a judge override (line ${bad%%:*}); findings must stop the run, never be approved past"
  PATTERN_ARGS=()
  if [ -f "$PROC_DIR/stop-patterns" ]; then
    while IFS= read -r bad || [ -n "$bad" ]; do
      case "${bad#"${bad%%[![:space:]]*}"}" in ''|'#'*) continue ;; esac
      PATTERN_ARGS+=(-e "$bad")
    done <"$PROC_DIR/stop-patterns"
    if [ "${#PATTERN_ARGS[@]}" -gt 0 ]; then
      grep -Eq "${PATTERN_ARGS[@]}" </dev/null 2>/dev/null
      [ "$?" -le 1 ] || refuse "$PROC_DIR/stop-patterns holds an invalid expression"
    fi
  fi
}

# The newest recorded captain decision on the approval task must carry the
# exact approval line for the procedure as it is now.
check_approval() {
  local decision rc=0 other
  decision=$("$SCRIPT_DIR/fm-captain-hold.sh" decision "$APPROVAL" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || refuse "no current captain answer on $APPROVAL (${decision##*fm-captain-hold: }); ask with: $APPROVAL_LINE"
  printf '%s\n' "$decision" | grep -Fxq -- "$APPROVAL_LINE" && return 0
  other=$(printf '%s\n' "$decision" | grep -E "^Approved publish: $TASK " | head -n 1)
  [ -z "$other" ] \
    || refuse "the captain's approval on $APPROVAL names another procedure (${other#"Approved publish: $TASK "}); it changed after approval, so ask again with: $APPROVAL_LINE"
  refuse "the newest captain decision on $APPROVAL does not approve this procedure; ask with: $APPROVAL_LINE"
}

# --- run ----------------------------------------------------------------------

LOG='' RUN_TMP='' LOCK='' LOCK_HELD=0 RESTORE_ARMED=0 STAGE=start
STEPS='' RESULTS='' NOTES='' RESTORED='not needed' STOP_WHY=''

say() {
  printf '%s\n' "$*"
  printf '%s\n' "$*" >>"$LOG"
}

note() {
  NOTES="$NOTES
    - $*"
  say ">> $*"
}

stop() {  # <code> <why>
  local code=$1
  shift
  note "STOP: $*"
  exit "$code"
}

# Run one procedure step, its output on the terminal and in the log. Publish
# and verify output is also scanned for REFUSED and the stop patterns.
run_step() {  # <step>
  local step=$1 out rc line
  STAGE=$step
  say ""
  say "== $step ($(now))"
  out=$(mktemp "$RUN_TMP/$step.XXXXXX") || { STEPS="$STEPS $step=no-output-file"; return 1; }
  (cd "$PROC_DIR" && exec "$PROC" "$step") </dev/null 2>&1 \
    | (trap '' INT TERM HUP; exec tee -a "$LOG" "$out")
  rc=${PIPESTATUS[0]}
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    RESULTS="$RESULTS
    - $step: ${line#result: }"
  done <<EOF
$(grep -E '^result: ' "$out")
EOF
  say "-- $step exit $rc"
  if [ "$rc" -ne 0 ]; then
    STEPS="$STEPS $step=exit-$rc"
    STOP_WHY="$step exited $rc"
    return 1
  fi
  case "$step" in
    publish|verify)
      if grep -q 'REFUSED' "$out"; then
        STEPS="$STEPS $step=REFUSED"
        STOP_WHY="a REFUSED appeared in the $step output; no override is sought"
        return 1
      fi
      line=
      [ "${#PATTERN_ARGS[@]}" -eq 0 ] || line=$(grep -E "${PATTERN_ARGS[@]}" "$out" | head -n 1)
      if [ -n "$line" ]; then
        STEPS="$STEPS $step=stop-pattern"
        STOP_WHY="the $step output matched a stop pattern: $line"
        return 1
      fi
      ;;
  esac
  STEPS="$STEPS $step=ok"
  return 0
}

on_signal() {  # <signal>
  note "interrupted by $1"
  exit 130
}

finish() {  # <exit-code>
  local rc=$1 meaning stopped_at=$STAGE
  trap '' INT TERM HUP PIPE
  if [ "$RESTORE_ARMED" = 1 ]; then
    if run_step restore; then
      RESTORED=restored
    else
      RESTORED='RESTORE FAILED: put the blocks back by hand before anything else'
      rc=8
    fi
  fi
  case "$rc" in
    0) meaning='published, verified, and blocks restored' ;;
    4) meaning='preflight failed; nothing was published' ;;
    5) meaning='lift failed' ;;
    6) meaning='publish stopped' ;;
    7) meaning='verify failed' ;;
    8) meaning='restore failed' ;;
    130) meaning='interrupted' ;;
    *) meaning='stopped' ;;
  esac
  say ""
  say "== summary ($(now))"
  say "  task:       $TASK"
  say "  approval:   $APPROVAL ($APPROVAL_LINE)"
  say "  exit code:  $rc ($meaning)"
  say "  last step:  $stopped_at"
  say "  steps:     ${STEPS:- none}"
  say "  blocks:     $RESTORED"
  [ -z "$RESULTS" ] || say "  results:$RESULTS"
  [ -z "$NOTES" ] || say "  notes:$NOTES"
  say "Full log: $LOG"
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK" || true
  rm -rf "$RUN_TMP"
  exit "$rc"
}

command_run() {
  local stamp
  load_procedure
  check_approval
  LOCK=$STATE/.approved-publish-$TASK.lock
  fm_lock_try_acquire "$LOCK" \
    || refuse "a publication run for $TASK is already in progress (pid ${FM_LOCK_HELD_PID:-unknown})"
  LOCK_HELD=1
  RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-approved-publish.XXXXXX") || {
    fm_lock_release "$LOCK"
    refuse "cannot create a temporary directory"
  }
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$DATA/$TASK/publish-logs" && LOG=$DATA/$TASK/publish-logs/$stamp-$$.log && : >>"$LOG" || {
    fm_lock_release "$LOCK"
    rm -rf "$RUN_TMP"
    refuse "cannot create the run log under $DATA/$TASK/publish-logs"
  }
  export FM_PUBLISH_TASK=$TASK FM_PUBLISH_DIR=$PROC_DIR FM_PUBLISH_LOG=$LOG
  trap 'finish $?' EXIT
  trap 'on_signal INT' INT
  trap 'on_signal TERM' TERM
  trap 'on_signal HUP' HUP
  say "=== fm-approved-publish run started $(now)"
  say "runner:     $SCRIPT_DIR/fm-approved-publish.sh"
  say "procedure:  $PROC_DIR ($DIGEST)"
  say "approval:   newest captain decision on $APPROVAL carries: $APPROVAL_LINE"
  RESTORE_ARMED=1
  run_step preflight || stop 4 "$STOP_WHY; refusing to lift anything"
  run_step lift || stop 5 "$STOP_WHY"
  run_step publish || stop 6 "$STOP_WHY"
  run_step verify || stop 7 "$STOP_WHY"
  STAGE=done
  exit 0
}

command=${1:-}
case "$command" in
  approval|check|run) shift; parse_args "$command" "$@" ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

case "$command" in
  approval)
    load_procedure
    printf '%s\n' "$APPROVAL_LINE"
    ;;
  check)
    load_procedure
    check_approval
    printf 'approved: the newest captain decision on %s carries %s\n' "$APPROVAL" "$APPROVAL_LINE"
    ;;
  run) command_run ;;
esac
