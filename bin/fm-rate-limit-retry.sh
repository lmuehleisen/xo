#!/usr/bin/env bash
# Schedule or perform a provider-limit resume attempt for a known idle worker.
# Usage: FM_HOME=<home> fm-rate-limit-retry.sh <task-id>
# Call only after inspecting the worker and confirming a provider rate limit.
# The first call declares paused [key=provider-rate-limit] until one hour later.
# Repeated calls before that time do nothing. A due call records the
# next hourly recheck before sending one resume steer through fm-send.
# That steer is fire-and-forget: inbox delivery ladders must not retry or
# escalate this known provider wait between its hourly probes.
# The existing watcher/away daemon owns timed-pause wakes; no helper sleeps.
# A newer worker status supersedes this pause and stops its retry schedule.
# Models, providers, lifecycle, and merge authority are never changed here.
# FM_RATE_LIMIT_RETRY_SECS overrides 3600 seconds (positive integer).
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] || { echo 'fm-rate-limit-retry: FM_HOME must be explicit' >&2; exit 2; }
STATE=${FM_STATE_OVERRIDE:-$FM_HOME/state}
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo 'usage: fm-rate-limit-retry.sh <task-id>' >&2
  exit 2
fi
ID=$1
INTERVAL=${FM_RATE_LIMIT_RETRY_SECS:-3600}
case "$INTERVAL" in ''|*[!0-9]*) echo 'invalid retry interval' >&2; exit 2 ;; esac
INTERVAL=$((10#$INTERVAL))
[ "$INTERVAL" -gt 0 ] || { echo 'invalid retry interval' >&2; exit 2; }
[ -f "$STATE/$ID.meta" ] || { echo 'fm-rate-limit-retry: worker metadata required' >&2; exit 1; }
case "$(sed -n 's/^kind=//p' "$STATE/$ID.meta" | tail -1)" in
  ship|scout) ;;
  *) echo 'fm-rate-limit-retry: ordinary worker required' >&2; exit 1 ;;
esac
if [ "$(sed -n 's/^harness=//p' "$STATE/$ID.meta" | tail -1)" = devin ]; then
  echo 'fm-rate-limit-retry: Devin hook already owns its retry schedule' >&2
  exit 1
fi
fm_lease_guard "$ID" 'rate-limit retry'
trap 'fm_lease_guard_release' EXIT
LAST=$(status_declared_wait_line "$STATE/$ID.status")
NOW=$(date +%s)
if status_is_paused "$LAST" && [ "$(_fm_decision_key "$LAST")" = provider-rate-limit ]; then
  UNTIL=$(status_paused_until "$LAST") || { echo 'fm-rate-limit-retry: invalid retry pause' >&2; exit 1; }
  if [ "$NOW" -lt "$UNTIL" ]; then
    printf 'waiting: provider-limit retry in %ss\n' "$(( UNTIL - NOW ))"
    exit 0
  fi
  ACTION=retried
else
  case "$(status_line_verb "$(last_status_line "$STATE/$ID.status")")" in
    done|failed|needs-decision|captain-held|blocked|paused)
      echo 'fm-rate-limit-retry: reconcile terminal status or open call before scheduling' >&2
      exit 1 ;;
  esac
  ACTION=scheduled
fi
UNTIL=$(( NOW + INTERVAL ))
STAMP=$(date -u -r "$UNTIL" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$UNTIL" +%Y-%m-%dT%H:%M:%SZ)
printf 'paused [at=%s] [key=provider-rate-limit]: provider rate limit; automatic retry until %s\n' "$NOW" "$STAMP" >> "$STATE/$ID.status"
# Record spacing before submission, so an interrupted/inconclusive attempt is
# not retried immediately. Release the lease-command lock before fm-send takes it.
fm_lease_guard_release
if [ "$ACTION" = retried ]; then
  DELIVERY_ID=$(printf '%016x' "$UNTIL")
  if ! FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-send.sh" "$ID" --fire-and-forget "$DELIVERY_ID" \
    'Retry the task on the same model and provider: the provider rate limit may have cleared. Continue from where you stopped; resolve the provider-rate-limit pause when work resumes.'; then
    echo 'fm-rate-limit-retry: resume steer failed; inspect delivery before retrying' >&2
    exit 1
  fi
fi
printf '%s: provider-limit retry at %s\n' "$ACTION" "$STAMP"
