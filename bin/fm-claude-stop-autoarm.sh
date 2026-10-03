#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it: the recorded pid is a harness
#     ancestor, or a live lock was recorded under this same trusted Claude
#     session id (which is what keeps a background session arming after its
#     transient helper chain is recycled).
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh as a tracked child it
#     waits on inside this hook-owned process tree (never a fire-and-forget
#     shell &); Claude owns the process group, so its timeout/session teardown
#     kills arm and watcher together, and the hook TERMs the arm with itself.
#     A killed hook's rewake is never delivered (Claude drops the exit 2 of a
#     hook it terminated at the configured timeout; measured on Claude Code
#     2.1.278 and 2.1.281, docs/verification/supervision.md). The cycle
#     therefore closes itself first: the hook passes FM_WATCH_DEADLINE, derived
#     from its own declared timeout by autoarm_hook_deadline_secs below, to the
#     arm, so a cycle with nothing to report ends before the timeout with one
#     no-op "check: autoarm-deadline" wake, translated like any other actionable
#     close; the rewake turn's own Stop re-arms with a fresh timeout. HUP,
#     TERM, and INT are translated through the ordinary durable failure
#     handoff instead of leaving the generation frozen at arming.
#   - Handling successor: Pi, omp, and OpenCode start the next arm before they
#     deliver an actionable wake, so the fleet stays covered while the model
#     handles it. After an actionable close, including an attached peer cycle
#     that ended, this hook starts one successor bin/fm-watch-arm.sh with the
#     closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, the same handoff the
#     Pi extension passes for its closed arm child, so the arm starts a
#     handling-successor watcher and links the lifecycle ledger. A child of
#     this hook cannot outlive the exit-2 rewake, so the successor is launched
#     the one way a process survives a Claude hook: nohup, stdio detached, in
#     its own process group (the shape bin/fm-startup-network.sh uses;
#     docs/verification/supervision.md records the survival check). The hook
#     waits for the successor's one status line, adds one banner line when no
#     live watcher was confirmed, and never withholds the wake for it; the
#     next Stop's foreground arm attaches to that live cycle. The supervision
#     host owns its own successors, so its path is unchanged.
#   - Supervision host: a home that runs it (by default on this Claude
#     primary; docs/configuration.md "Supervision host" owns the gate and its
#     opt-out) runs bin/fm-supervision-host.sh in the arm's place, bound
#     to this generation.
#     To this hook it is an arm that also takes away-posture wakes itself and
#     ends its own park before the hook timeout with a "supervision-host:"
#     line, which is actionable here like a wake line; its rewake banner
#     carries every "supervision-host:" line the host printed, in order, while
#     its wake lines keep the arm's eight-line cap. A "supervision-host stood
#     down:" close exits 0 silently, and a host that died without a close is
#     retried instead of being judged by the healthy-watcher predicate
#     (docs/supervision-host.md). On a home that opted out nothing below
#     changes.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). The irrevocable commit point is the EXIT STATUS:
#     the harness delivers the collected stderr only on exit 2, so an owned
#     terminal commit decides the exit. Markerless outcomes commit with the
#     ledger write; the failure notice additionally requires its marker write.
#     A refused generation exits 0 silently even after printing. A close that
#     reports no actionable reason is benign when a live identity-matched
#     watcher still has a fresh beacon. An actionable close is itself positive
#     watcher recovery: it clears any leftover failure episode and always
#     rewakes, whoever left that episode behind.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open, after
#     which failures stay silent until positive recovery.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, and binds rewake outcomes to the session-lock pid and
# watcher recovery generation, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later failure continuation in that unresolved episode.
#
# In hook mode it never blocks the Stop decision itself or prints to stdout:
# exit 0 is silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# StopFailure mode (--stop-failure): the same script is also registered as the
# StopFailure asyncRewake hook beside the two Stop hooks. Claude Code fires
# StopFailure INSTEAD of Stop when a turn ends on an API error (a usage limit,
# an overload, an auth failure), so neither Stop hook runs and nothing re-arms
# the watcher, which would leave the home unsupervised until the next captain
# message (tests/fm-claude-stop-autoarm.test.sh owns the regression). After
# the unchanged foreign-host, scope, identity, AFK, and need gates above, this
# mode starts at most ONE recovery turn per failure:
#   - Classify the payload's "error". Errors a retry cannot fix
#     (authentication_failed, oauth_org_not_allowed, account_on_hold,
#     verification_required, billing_error, cloud_credential_error,
#     invalid_request, model_not_found) record a halt decision and stand down:
#     the captain must act, and a recovery turn would only fail again. The halt
#     first claims the next ledger generation with the terminal outcome
#     "stopfailure-halt", so a waiter from an earlier transient failure, claimed
#     or not yet claimed, is superseded and never starts the turn this error
#     rules out.
#     rate_limit waits for the limit reset; every other error, including any
#     error name a later Claude Code adds, is transient and backs off.
#   - Stand down while a live open Stop-owned claim or a healthy watcher already
#     owns continuity (that watcher's next wake rewakes normally), and after the
#     attended fail-open alarm, exactly as the Stop path suppresses continuation.
#   - Claim the next epoch-ledger generation with outcome "stopfailure-wait",
#     which is never open: an ordinary Stop never defers to it and supersedes
#     it by taking the next generation, and a newer StopFailure supersedes it
#     the same way, so sleepers never stack and a superseded one goes silent.
#     No lock is held while waiting.
#   - Order hooks by when they started. Before any gate or settling work, each
#     hook notes the WHOLE ledger record it sees (fm_autoarm_ledger_token), and
#     every claim it makes, wait or halt, is a compare-and-swap against exactly
#     that record. Any write at all since then - a halt, another hook's claim,
#     a predecessor committing its rewake or any other outcome in the same
#     generation, or a Stop-owned cycle - means another hook owns the outcome,
#     so this one exits without claiming. A halt is therefore terminal for
#     every hook that started before it, while a failure that starts after the
#     halt is handled on its own. A stand-down gives ownership up rather than
#     taking it, so it never writes the ledger: its waiting entry stays behind,
#     never open, and a newer hook that started meanwhile can still claim.
#   - Wait. For rate_limit: until the reset plus FM_CLAUDE_STOPFAILURE_RESET_SLACK
#     (default 180s, so that where Claude Code's own continue-at-usage-limit is
#     active its turn starts first and the turn-started check below stands
#     this hook down), preferring quotaLimits.resetsAt from the transcript's
#     fresh API-error entry, then the "resets <h[:mm]am|pm> (<zone>)" text of
#     the error message; a dated "resets <Mon> <d>, ..." text names a reset more
#     than a day away and waits the cap. Otherwise, and whenever the reset time
#     cannot be read: a capped exponential backoff from
#     FM_CLAUDE_STOPFAILURE_BACKOFF_BASE (default 300s) to
#     FM_CLAUDE_STOPFAILURE_BACKOFF_MAX (default 1800s). The attempt number
#     grows only while the ledger still ends on this mode's own rewake, meaning
#     the recovery turn itself failed again; from the second attempt the wait
#     is at least the backoff even when a reset time is known. Every wait is
#     capped at FM_CLAUDE_STOPFAILURE_MAX_WAIT (default: the deadline
#     autoarm_hook_deadline_secs derives from this hook's own declared
#     StopFailure timeout), so a limit that outlasts the cap costs one rejected
#     recovery turn per cap window and the next StopFailure starts a new wait:
#     never an unbounded wait and never a tight loop.
#   - Every FM_CLAUDE_STOPFAILURE_POLL seconds (default 30), and again before
#     firing, stand down on supersession, AFK, lost session-lock identity,
#     vanished need, a healthy watcher, the attended alarm, or transcript
#     evidence that another turn began after the failure (a new prompt or
#     task-notification user entry, a dequeued prompt, or real assistant
#     output), so a recovery turn never lands on a turn in progress. The wait
#     uses the wall clock, so machine sleep shortens rather than extends it.
#   - Fire: print the recovery banner, commit outcome=rewake bound to the
#     session-lock pid and watcher recovery generation (the same binding an
#     ordinary rewake carries, so the mid-turn pull guard stays quiet), and exit
#     2. That recovery turn ends normally, and its Stop auto-arm resumes the
#     watcher. HUP, TERM, and INT are trapped before the claim is published and
#     only mark the signal, so a signal can never interrupt a ledger write or
#     land between publishing the wait and trapping; the first safe point after
#     the claim (at once, or when the current poll's sleep ends) fires the same
#     way after the same rechecks.
# state/.claude-stopfailure holds the latest decision on one line (epoch,
# attempt, error, decision, wait, reset, reason); it carries the attempt count
# and is read only by this mode. A print-mode (-p) session runs async hooks
# synchronously and ignores StopFailure exit codes, so there this mode only
# holds that session for its wait; only the lock-owning session reaches it.
# The Stop hook passes no arguments and the StopFailure hook passes only
# --stop-failure, so any other argument means a manual run: -h or --help prints
# usage and an unknown argument is refused, both before anything is sourced,
# read, or armed. A park started from a model's tool call would be owned by that
# short-lived process and leave supervision down once it exits.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-autoarm.sh [--stop-failure]

Claude Stop and StopFailure hook registered in .claude/settings.json; not for
manual use. It reads the hook payload on stdin and, in a primary home that
needs supervision, arms the watcher or supervision host for this session;
--stop-failure selects the StopFailure recovery mode.
Exit 0 is silent; exit 2 carries a rewake banner on stderr.
EOF
}

MODE=stop
if [ "$#" -gt 0 ]; then
  case "$1" in
    --stop-failure) MODE=stop-failure ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

# fm-watch.sh touches the liveness beacon once per cycle, immediately before
# its terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace (bin/fm-wake-lib.sh) is the single
# owner of that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Claude kills this hook's whole process tree at the timeout declared for it
# in the tracked .claude/settings.json and delivers nothing from a killed
# hook. This is the one owner of how far below that timeout the hook finishes
# on its own: the declared timeout of this script's <event> entry, less a
# quarter of it capped at 600s, which covers the watcher's poll and check
# sweep; an unreadable declaration falls back to 600s. It is wall-clock time,
# so a machine sleep only brings the deadline closer.
HOOK_STARTED=$(date +%s)
autoarm_hook_deadline_secs() {  # <Stop|StopFailure>
  local timeout margin
  timeout=$(jq -r --arg event "$1" '
      [.hooks[$event][]?.hooks[]?
        | select((.command // "") | contains("fm-claude-stop-autoarm.sh"))
        | .timeout | numbers | floor] | first // empty' \
    "$FM_ROOT/.claude/settings.json" 2>/dev/null || true)
  case "$timeout" in
    ''|*[!0-9]*|0) timeout=600 ;;
  esac
  margin=$((timeout / 4))
  [ "$margin" -le 600 ] || margin=600
  [ "$margin" -ge 1 ] || margin=1
  if [ "$timeout" -gt "$margin" ]; then
    printf '%s\n' "$((timeout - margin))"
  else
    printf '1\n'
  fi
}

# StopFailure mode notes the whole ledger record first, before the payload,
# gates, or settling, so its claim can be a compare-and-swap against the state
# it started from. The generation and outcome read next only feed the attempt
# count; any change between the two reads fails that compare-and-swap anyway.
SF_OBSERVED_TOKEN=
SF_OBSERVED_GEN=
SF_OBSERVED_OUTCOME=
if [ "$MODE" = stop-failure ]; then
  SF_OBSERVED_TOKEN=$(fm_autoarm_ledger_token "$STATE")
  SF_OBSERVED_GEN=$(_fm_autoarm_epoch_field "$STATE/.claude-autoarm-epoch" epoch 2>/dev/null || true)
  case "$SF_OBSERVED_GEN" in
    ''|*[!0-9]*) SF_OBSERVED_GEN=0 ;;
  esac
  SF_OBSERVED_OUTCOME=$(_fm_autoarm_epoch_field "$STATE/.claude-autoarm-epoch" outcome 2>/dev/null || true)
fi

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# pi-code (Pi's Claude-hook compatibility extension) also loads the tracked
# Claude settings and has no asyncRewake, so it awaits every Stop hook and this
# arm would run SYNCHRONOUSLY inside Pi's turn end, holding that turn open for
# the declared multi-hour timeout - the same wedge as Cursor above (issue
# #3343). Pi's own native extensions own Pi supervision, so stand down on a
# pi-code-delivered payload. The signal is again the PAYLOAD, not the
# environment: pi-code stamps every hook payload's transcript_path with Pi's
# own session file under .pi/, which a Claude transcript path never contains.
# Fail direction matches the guard above: no payload, no jq, or no
# transcript_path means the hook RUNS.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- StopFailure mode: one recovery turn after an API-error turn end ---------
# The header's "StopFailure mode" paragraph owns this contract. Everything in
# this section runs only under --stop-failure and always exits.
SF_RECORD="$STATE/.claude-stopfailure"
SF_TRANSCRIPT=
SF_TRANSCRIPT_LINES=
SF_FAILURE_ENTRY=
SF_REASON=

sf_int() {  # <value> <default>: a positive integer, or the default
  case "$1" in
    ''|*[!0-9]*|0) printf '%s\n' "$2" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

sf_error_class() {  # <error>
  case "$1" in
    rate_limit) printf 'rate-limit\n' ;;
    authentication_failed|oauth_org_not_allowed|account_on_hold|verification_required) printf 'halt\n' ;;
    billing_error|cloud_credential_error|invalid_request|model_not_found) printf 'halt\n' ;;
    *) printf 'transient\n' ;;
  esac
}

# The latest decision, one line of key=value tokens. Best effort, never fatal.
sf_record() {  # <epoch> <attempt> <error> <decision> <basis> <wait> <reset> <reason>
  local tmp="$SF_RECORD.tmp.${BASHPID:-$$}"
  if printf 'epoch=%s attempt=%s error=%s decision=%s basis=%s wait=%s reset=%s reason=%s updated_at=%s\n' \
      "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$(date +%s)" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$SF_RECORD" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
}

# Find this failure's own transcript entry: the last API-error entry among the
# final lines, accepted only when fresh, so an older failure is never read as
# this one. Claude may flush it just after the hook starts, so allow a short
# settle. SF_TRANSCRIPT_LINES is the transcript length once the failure is on
# disk; evidence of a later turn must come after it.
sf_locate_failure() {
  local entry ts tries=0
  SF_TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || true)
  if [ -z "$SF_TRANSCRIPT" ] || [ ! -f "$SF_TRANSCRIPT" ] || [ ! -r "$SF_TRANSCRIPT" ]; then
    SF_TRANSCRIPT=
    return 0
  fi
  while :; do
    entry=$(tail -n 64 "$SF_TRANSCRIPT" 2>/dev/null \
      | jq -Rc 'fromjson? | select(type == "object" and .isApiErrorMessage == true)' 2>/dev/null \
      | tail -n 1)
    if [ -n "$entry" ]; then
      ts=$(printf '%s' "$entry" \
        | jq -r '(.timestamp // "") | sub("\\.[0-9]+Z$"; "Z") | (fromdateiso8601? // empty)' 2>/dev/null || true)
      case "$ts" in
        ''|*[!0-9]*) : ;;
        *)
          if [ "$ts" -ge $((SF_STARTED - 600)) ]; then
            SF_FAILURE_ENTRY=$entry
            break
          fi
          ;;
      esac
    fi
    tries=$((tries + 1))
    [ "$tries" -lt 6 ] || break
    sleep 0.5
  done
  SF_TRANSCRIPT_LINES=$(wc -l < "$SF_TRANSCRIPT" 2>/dev/null | tr -d '[:space:]')
  case "$SF_TRANSCRIPT_LINES" in
    ''|*[!0-9]*) SF_TRANSCRIPT_LINES= ;;
  esac
}

# Positive evidence that another turn began after the failure: a delivered
# prompt or task notification, a dequeued prompt, or real model output. No
# transcript, or no such entry, is not evidence.
sf_turn_started_since() {
  [ -n "$SF_TRANSCRIPT" ] && [ -n "$SF_TRANSCRIPT_LINES" ] || return 1
  tail -n "+$((SF_TRANSCRIPT_LINES + 1))" "$SF_TRANSCRIPT" 2>/dev/null \
    | jq -Rce 'fromjson? | select(type == "object")
        | select((.type == "user" and .origin != null)
          or (.type == "queue-operation" and .operation == "dequeue")
          or (.type == "assistant" and .isApiErrorMessage != true))' >/dev/null 2>&1
}

sf_reset_from_transcript() {
  [ -n "$SF_FAILURE_ENTRY" ] || return 1
  printf '%s' "$SF_FAILURE_ENTRY" \
    | jq -r 'select(.error == "rate_limit") | .quotaLimits.resetsAt // empty | numbers | floor' 2>/dev/null
}

# Claude Code words a usage-limit reset as "resets 5am (<IANA zone>)" or
# "resets 6:20am (...)", the next such wall-clock time in that zone (a DST
# change can skew it by an hour, and the next failure corrects it), or as a
# dated "resets Sep 23, 5am (...)" when the reset is more than a day away.
sf_reset_from_message() {  # <message>
  local msg=$1 re hour minute zone h m s delta
  re='resets [A-Z][a-z][a-z] [0-9]{1,2}(, [0-9]{4})?, [0-9]{1,2}(:[0-9]{2})?(am|pm)'
  if [[ $msg =~ $re ]]; then
    printf 'far\n'
    return 0
  fi
  re='resets ([0-9]{1,2})(:([0-9]{2}))?(am|pm) \(([A-Za-z0-9_+/-]+)\)'
  [[ $msg =~ $re ]] || return 1
  hour=$((10#${BASH_REMATCH[1]} % 12))
  minute=$((10#${BASH_REMATCH[3]:-0}))
  [ "${BASH_REMATCH[4]}" = pm ] && hour=$((hour + 12))
  zone=${BASH_REMATCH[5]}
  case "$zone" in
    *..*) return 1 ;;
  esac
  [ -f "${TZDIR:-/usr/share/zoneinfo}/$zone" ] || return 1
  read -r h m s < <(TZ="$zone" date '+%H %M %S' 2>/dev/null) || return 1
  delta=$(( hour * 3600 + minute * 60 - (10#$h * 3600 + 10#$m * 60 + 10#$s) ))
  [ "$delta" -gt 0 ] || delta=$((delta + 86400))
  printf '%s\n' "$(( $(date +%s) + delta ))"
}

sf_backoff() {  # <attempt>
  local k=$1 wait=$SF_BACKOFF_BASE
  while [ "$k" -gt 1 ] && [ "$wait" -lt "$SF_BACKOFF_MAX" ]; do
    wait=$((wait * 2))
    k=$((k - 1))
  done
  [ "$wait" -le "$SF_BACKOFF_MAX" ] || wait=$SF_BACKOFF_MAX
  printf '%s\n' "$wait"
}

# The attempt grows only while the ledger still ends on this mode's own rewake,
# that is, when the recovery turn itself failed again. A failure that replaces
# a still-waiting generation keeps its level; anything else starts over.
sf_next_attempt() {
  local epoch attempt decision
  epoch=$(_fm_autoarm_epoch_field "$SF_RECORD" epoch 2>/dev/null || true)
  attempt=$(_fm_autoarm_epoch_field "$SF_RECORD" attempt 2>/dev/null || true)
  decision=$(_fm_autoarm_epoch_field "$SF_RECORD" decision 2>/dev/null || true)
  case "$attempt" in
    ''|*[!0-9]*|0) attempt=1 ;;
  esac
  if [ -n "$epoch" ] && [ "$epoch" = "$SF_OBSERVED_GEN" ]; then
    case "$SF_OBSERVED_OUTCOME:$decision" in
      rewake:rewake) printf '%s\n' "$((attempt + 1))"; return 0 ;;
      stopfailure-wait:wait) printf '%s\n' "$attempt"; return 0 ;;
    esac
  fi
  printf '1\n'
}

# Sets SF_REASON and succeeds when this generation must not start a turn.
sf_stand_down_reason() {
  SF_REASON=
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    SF_REASON=superseded
  elif [ -e "$STATE/.afk" ]; then
    SF_REASON=afk
  elif [ -e "$FAILURE_ALARM" ]; then
    SF_REASON=alarmed
  elif ! fm_session_lock_owned_by_self "$STATE"; then
    SF_REASON=lock_lost
  elif ! need_supervision; then
    SF_REASON=no_need
  elif fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    SF_REASON=watcher_healthy
  elif sf_turn_started_since; then
    SF_REASON=turn_started
  fi
  [ -n "$SF_REASON" ]
}

# A superseded generation goes silent. Any other stand-down gives ownership up
# rather than taking it, so it leaves the ledger untouched - its never-open
# waiting entry stays behind - and a newer hook that started meanwhile can
# still claim; only the side record keeps the reason.
sf_stand_down() {
  [ "$SF_REASON" = superseded ] && exit 0
  fm_autoarm_still_owner "$STATE" "$MY_GEN" || exit 0
  sf_record "$MY_GEN" "$SF_ATTEMPT" "$SF_ERROR" standdown "$SF_BASIS" "$SF_WAIT" "$SF_RESET_DESC" "$SF_REASON"
  exit 0
}

# Commit the recovery rewake with the same session-lock and watcher recovery
# binding an ordinary rewake carries; without a downtime marker it commits
# unbound rather than leaving the home without a recovery turn.
sf_commit_rewake() {
  local session_pid recovery=
  fm_session_lock_owned_by_self "$STATE" || return 2
  session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
  if fm_recovery_marker_snapshot "$STATE/.watcher-down"; then
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
    esac
  fi
  fm_autoarm_write_owned "$STATE" "$MY_GEN" rewake "" "$session_pid" "$recovery"
}

sf_fire() {  # <what-happened> <reason-token>
  local basis reset_at
  sf_stand_down_reason && sf_stand_down
  case "$SF_BASIS" in
    resetsAt|message)
      reset_at=$(jq -rn --argjson t "$SF_RESET_DESC" '$t | todate' 2>/dev/null || printf '%s' "$SF_RESET_DESC")
      if [ "$SF_CAPPED" -eq 1 ]; then
        basis="as long as one wait may last although the usage limit resets at $reset_at, so this turn may be rejected again"
      else
        basis="for the usage limit to reset at $reset_at"
      fi
      ;;
    far) basis='as long as one wait may last because the usage limit resets more than a day after the failure, so this turn may be rejected again' ;;
    *) basis="a bounded backoff for recovery attempt $SF_ATTEMPT" ;;
  esac
  {
    printf 'firstmate recovery turn - the previous turn ended on a Claude API error (%s), so no Stop hook ran and no watcher is supervising this home.\n' "$SF_ERROR"
    printf 'The StopFailure hook %s, waiting %s, before starting this single recovery turn.\n' "$1" "$basis"
    printf 'Run bin/fm-wake-drain.sh first, handle any presented wakes, then run its exact WAKE_ACK_REQUIRED --ack-through command. When this turn ends normally, the Stop hook re-arms the watcher automatically - do NOT run bin/fm-watch-arm.sh. If this turn also ends on an API error, the StopFailure hook waits again before any further recovery.\n'
  } >&2
  if sf_commit_rewake; then
    sf_record "$MY_GEN" "$SF_ATTEMPT" "$SF_ERROR" rewake "$SF_BASIS" "$SF_WAIT" "$SF_RESET_DESC" "$2"
    exit 2
  fi
  exit 0
}

# Claim the next generation with <outcome>, by compare-and-swap against the
# whole ledger record this hook observed when it started. Returns 0 with MY_GEN
# set, 2 when a live open Stop-owned claim owns continuity, 3 when anything was
# written since this hook started, and 1 when bounded micro-mutex contention or
# a write failure persists.
sf_claim() {  # <outcome>
  local rc i=0
  MY_GEN=
  while :; do
    fm_autoarm_claim_next "$STATE" "$GRACE" "$1" "$SF_OBSERVED_TOKEN"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      MY_GEN=$FM_AUTOARM_MY_GEN
      [ -n "$MY_GEN" ] || return 1
      return 0
    fi
    [ "$rc" -eq 2 ] && return 2
    [ "$rc" -eq 3 ] && return 3
    i=$((i + 1))
    [ "$i" -lt 50 ] || return 1
    sleep 0.1
  done
}

# The traps only mark the signal, so a signal can never cut a ledger write
# short; sf_act_on_signal acts on it at the next safe point after the claim.
SF_SIGNAL=
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
sf_on_signal() {
  SF_SIGNAL=$1
}

sf_act_on_signal() {
  [ -n "$SF_SIGNAL" ] || return 0
  trap - HUP TERM INT
  sf_fire "was interrupted by $SF_SIGNAL after $(( $(date +%s) - SF_STARTED ))s" "signal-$SF_SIGNAL"
}

stopfailure_recover() {
  local now reset msg remaining nap floor
  SF_STARTED=$(date +%s)
  SF_MAX_WAIT=$(sf_int "${FM_CLAUDE_STOPFAILURE_MAX_WAIT:-}" "$(autoarm_hook_deadline_secs StopFailure)")
  SF_BACKOFF_BASE=$(sf_int "${FM_CLAUDE_STOPFAILURE_BACKOFF_BASE:-}" 300)
  SF_BACKOFF_MAX=$(sf_int "${FM_CLAUDE_STOPFAILURE_BACKOFF_MAX:-}" 1800)
  SF_RESET_SLACK=$(sf_int "${FM_CLAUDE_STOPFAILURE_RESET_SLACK:-}" 180)
  SF_POLL=$(sf_int "${FM_CLAUDE_STOPFAILURE_POLL:-}" 30)
  SF_ATTEMPT=0
  SF_BASIS=none
  SF_WAIT=0
  SF_RESET_DESC=none
  SF_CAPPED=0

  SF_ERROR=$(printf '%s' "$PAYLOAD" | jq -r '.error // empty' 2>/dev/null || true)
  case "$SF_ERROR" in
    ''|*[!a-z0-9_]*) SF_ERROR=unknown ;;
  esac
  if [ "$(sf_error_class "$SF_ERROR")" = halt ]; then
    # Supersede any waiter from an earlier transient failure, so it can never
    # start the recovery turn this error rules out. A live open Stop-owned
    # claim is left alone, and a hook that started after this one owns the
    # ledger outright, so this halt then leaves no trace.
    sf_claim stopfailure-halt
    case "$?" in
      0) sf_record "$MY_GEN" 0 "$SF_ERROR" halt none 0 none needs-captain ;;
      3) : ;;
      *)
        fm_autoarm_ledger_read "$STATE" || FM_AUTOARM_GEN=0
        sf_record "${FM_AUTOARM_GEN:-0}" 0 "$SF_ERROR" halt none 0 none needs-captain
        ;;
    esac
    exit 0
  fi

  # A live Stop-owned cycle or a healthy watcher already owns continuity: that
  # watcher's next wake rewakes normally, and a failure of that turn fires this
  # hook again once its claim is terminal.
  fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME" && exit 0
  [ -e "$FAILURE_ALARM" ] && exit 0

  # Trap before anything is published, so no signal can leave a waiting claim
  # behind without its recovery.
  trap 'sf_on_signal HUP' HUP
  trap 'sf_on_signal TERM' TERM
  trap 'sf_on_signal INT' INT

  sf_locate_failure
  SF_ATTEMPT=$(sf_next_attempt)
  reset=
  if [ "$SF_ERROR" = rate_limit ]; then
    reset=$(sf_reset_from_transcript || true)
    if [ -n "$reset" ]; then
      SF_BASIS=resetsAt
    else
      msg=$(printf '%s' "$PAYLOAD" | jq -r '.last_assistant_message // empty' 2>/dev/null || true)
      [ -n "$msg" ] || msg=$(printf '%s' "$SF_FAILURE_ENTRY" \
        | jq -r '[.message.content[]? | select(.type == "text") | .text] | join(" ")' 2>/dev/null || true)
      reset=$(sf_reset_from_message "$msg" || true)
      SF_BASIS=message
    fi
  fi
  now=$(date +%s)
  case "$reset" in
    far)
      SF_BASIS=far
      SF_RESET_DESC=far
      SF_WAIT=$SF_MAX_WAIT
      ;;
    ''|*[!0-9]*)
      SF_BASIS=backoff
      SF_WAIT=$(sf_backoff "$SF_ATTEMPT")
      ;;
    *)
      if [ "$reset" -gt "$now" ]; then
        SF_RESET_DESC=$reset
        SF_WAIT=$((reset - now + SF_RESET_SLACK))
        if [ "$SF_ATTEMPT" -gt 1 ]; then
          floor=$(sf_backoff "$SF_ATTEMPT")
          [ "$SF_WAIT" -ge "$floor" ] || SF_WAIT=$floor
        fi
      else
        SF_BASIS=backoff
        SF_WAIT=$(sf_backoff "$SF_ATTEMPT")
      fi
      ;;
  esac
  if [ "$SF_WAIT" -gt "$SF_MAX_WAIT" ]; then
    SF_WAIT=$SF_MAX_WAIT
    SF_CAPPED=1
  fi

  # Claim with the never-open outcome. A competing open claim owns continuity,
  # and anything written since this hook started supersedes it.
  sf_claim stopfailure-wait || exit 0
  sf_record "$MY_GEN" "$SF_ATTEMPT" "$SF_ERROR" wait "$SF_BASIS" "$SF_WAIT" "$SF_RESET_DESC" waiting

  SF_DEADLINE=$((now + SF_WAIT))
  while :; do
    sf_act_on_signal
    sf_stand_down_reason && sf_stand_down
    remaining=$((SF_DEADLINE - $(date +%s)))
    [ "$remaining" -gt 0 ] || break
    nap=$SF_POLL
    [ "$nap" -le "$remaining" ] || nap=$remaining
    sleep "$nap"
  done
  sf_fire "waited ${SF_WAIT}s" waited
}

[ "$MODE" = stop-failure ] && stopfailure_recover

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A micro-mutex contention with a bare hold is another
# participant's short ledger section and the next Stop firing simply retries,
# while a role-carrying hold is a legacy lock-holding claim from a
# pre-generation build (or the guard's own terminal-check), which the legacy
# shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_autoarm_claim_next "$STATE" "$GRACE"
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Failure means refused or unverifiable: the caller goes silent
# (cleanup, exit 0) - the harness discards the collected stderr on exit 0, so
# even an already-printed banner is never delivered by a losing generation.
autoarm_commit() {  # <outcome> [marker-file]
  local outcome=$1 marker=${2:-} session_pid recovery
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery"
  elif [ -n "$marker" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome"
  fi
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires, which the FM_WATCH_DEADLINE close exists to pre-empt;
# session teardown or another host signal can still interrupt the arm.
# Translate a host interruption through the ordinary durable failure
# protocol: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn.
# A superseded generation remains silent, and an episode whose attended
# fail-open was already consumed must not restart automatic continuation.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  local signal=$1
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
    autoarm_commit failed "$FAILURE_NOTICE" && exit 2
    exit 0
  fi
  autoarm_commit failed-suppressed && exit 2
  exit 0
}

trap 'handle_autoarm_signal HUP' HUP
trap 'handle_autoarm_signal TERM' TERM
trap 'handle_autoarm_signal INT' INT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# The arm is a tracked child this hook waits on, never a fire-and-forget shell
# & whose child would be reaped when the hook returned: this hook process tree
# is the harness-owned lifecycle. The arm forks the watcher as its own tracked
# child exactly as it does for the model-driven background-task path, and
# propagates the wake reason on close. Holding the arm's pid lets the signal
# handler TERM it with the hook and lets the handling successor below name it
# as the predecessor whose cycle just closed.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
ARM_PID=
CLOSED_ARM_PID=
run_arm() {  # <output file, or empty for none>
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" FM_WATCH_DEADLINE="$WATCH_DEADLINE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" FM_WATCH_DEADLINE="$WATCH_DEADLINE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited within the arm's own confirmation budget plus slack. Sets
# SUCCESSOR_FAILURE to the banner line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  budget=${FM_ARM_CONFIRM_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  if ! out=$(mktemp "$STATE/.claude-autoarm-successor.XXXXXX"); then
    SUCCESSOR_FAILURE='The handling successor did not confirm a live watcher (its output file could not be created); this handling turn runs uncovered until the next turn end re-arms.'
    return 1
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_WATCH_PREDECESSOR_ARM_PID=$1 FM_GUARD_GRACE="$GRACE" \
    nohup "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  deadline=$(( $(date +%s) + budget + 2 ))
  while :; do
    if grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null; then
      rm -f "$out" 2>/dev/null || true
      return 0
    fi
    grep -q '^watcher: FAILED' "$out" 2>/dev/null && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1 || true)
  rm -f "$out" 2>/dev/null || true
  [ -z "$line" ] || line=" ($line)"
  SUCCESSOR_FAILURE="The handling successor pid=$pid did not confirm a live watcher$line; this handling turn runs uncovered until the next turn end re-arms."
  return 1
}

OUT=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" claude; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi
attempt=0
WATCH_DEADLINE=$((HOOK_STARTED + $(autoarm_hook_deadline_secs Stop)))
while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
  # A superseded owner must not start or attach another watcher or mutate any
  # watcher/wake state: re-verify generation ownership before every arm
  # invocation, first attempt and retries alike.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  attempt=$((attempt + 1))
  OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
  if [ "$HOST_MODE" -eq 1 ]; then
    HOST_RC=0
    FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
      FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
      "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
  else
    run_arm "$OUT"
  fi

  # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
  # every subsequent classification and handoff.
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi

  ACTIONABLE=0
  if [ -n "$OUT" ]; then
    grep -Eq "$ACTIONABLE_RE" "$OUT" 2>/dev/null && ACTIONABLE=1
  fi
  [ "$ACTIONABLE" -eq 1 ] && break
  if [ "$HOST_MODE" -eq 1 ]; then
    # The host stood down because this session or generation no longer owns
    # supervision: whoever does owns continuity now.
    if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
      autoarm_record clean
      rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    # A host that died without a close may have left its cycle running with
    # no owner to deliver the close; retrying lets the next host stop what it
    # left and own a fresh cycle, which the healthy-watcher predicate cannot.
    if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
      [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      OUT=
      continue
    fi
    # A failed hand-back cannot be dismissed just because its successor
    # watcher is healthy: the close is still undelivered.
    [ "$HOST_RC" -eq 0 ] || break
  fi

  # A non-actionable close is benign when another verified watcher already owns
  # this home and is still beating within the shared grace window.
  if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    HEALTHY=1
    break
  fi
  [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  autoarm_record clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  fm_autoarm_reset_owned "$STATE" "$MY_GEN"
  RESET_RC=$?
  if [ "$RESET_RC" -eq 0 ]; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if [ "$RESET_RC" -eq 2 ]; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    [ -e "$FAILURE_ALARM" ] && exit 0
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  # The host owns its own successors and stops its cycle before handing back.
  if [ "$HOST_MODE" -eq 0 ]; then
    start_handling_successor "$CLOSED_ARM_PID" || true
  fi
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    if [ "$HOST_MODE" -eq 1 ]; then
      [ -n "$OUT" ] && awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$OUT" 2>/dev/null
    else
      [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    fi
    if [ "$HOST_MODE" -eq 1 ] && [ -e "$STATE/.afk-contract" ] \
      && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
      printf 'This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.\n'
    fi
    [ -z "$SUCCESSOR_FAILURE" ] || printf '%s\n' "$SUCCESSOR_FAILURE"
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  if autoarm_commit rewake; then
    # Only a committed hand-back proves recovery. A lost host hand-back must
    # retain its failure notice so repeated attempts do not notify again.
    # Real wakes still bypass attended-alarm suppression, and a contended
    # reset leaves the episode for the next positive recovery.
    fm_autoarm_reset_owned "$STATE" "$MY_GEN" || true
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
    && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
    && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]] \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    LOST_HANDBACK_COMMITTED=0
    if [ ! -e "$FAILURE_NOTICE" ]; then
      printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
      autoarm_commit failed "$FAILURE_NOTICE" && LOST_HANDBACK_COMMITTED=1
    else
      autoarm_commit failed-suppressed && LOST_HANDBACK_COMMITTED=1
    fi
    if [ "$LOST_HANDBACK_COMMITTED" -eq 1 ]; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another failure continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop. The notice marker
# commits in the same owned critical section as the winning failed write, so a
# losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
    [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
