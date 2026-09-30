#!/usr/bin/env bash
# Credentialed guard for the fork's Devin rate-limit retry
# (bin/fm-devin-rate-limit-retry.sh), opt in with FM_DEVIN_RETRY_LIVE=1.
# It runs the real generated launch (tests/devin-live-helpers.sh) and proves:
#   1. The generated UserPromptSubmit hook finds the isolated Devin session
#      log from its own process ancestry, and the generated Stop retires it.
#   2. After a hook-less cancellation, like a rate-limited turn, the sentinel
#      still follows that real log. A rate-limit error line injected there
#      (Devin's model limit cannot be forced) drives a real fm-send retry that
#      the worker acknowledges through its inbox; the retry turn's Stop resets
#      the count.
#   3. The generated SessionEnd leaves no sentinel behind after plain exit.
# The injected line is labeled `fm-live-guard` and lives only in the isolated
# home's log. The log format, cap, spacing, and lock cases stay pinned by
# tests/fm-devin-rate-limit-retry.test.sh.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
fm_live_gate opt-in FM_DEVIN_RETRY_LIVE devin tmux jq
# shellcheck source=tests/devin-live-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/devin-live-helpers.sh"
fail() { printf 'not ok - %s: %s\n' "${VERSION:-devin}" "$1" >&2; exit 1; }
devin_lab_init dvr
RETRY_LOG="$H/state/devin-rate-limit-log.jsonl"
printf '{}\n' > "$H/user-home/.config/devin/config.json"
# The sentinel reads its tuning from the environment the hooks inherit.
DEVIN_LAB_PANE_ENV='FM_DEVIN_RETRY_POLL=1 FM_DEVIN_RETRY_BACKOFF=1 FM_DEVIN_RETRY_JITTER=0 FM_DEVIN_RETRY_SPACING=0'
devin_lab_spawn devin-retry "Runtime verification only: write READY into ready.txt, then stop. Do no other work and do not delegate. Later, whenever the doorbell arrives, read and acknowledge Firstmate's instruction inbox and do exactly what each message says."

wait_file "$WT/ready.txt"
wait_idle
! grep -q '"event":"unarmed"' "$RETRY_LOG" 2>/dev/null \
  || fail "the generated arm hook found no session log: $(cat "$RETRY_LOG")"
case "$(cat "$H/state/$ID.devin-retry/turn" 2>/dev/null)" in
  ended.*) ;;
  *) fail 'the generated Stop hook did not retire the retry turn' ;;
esac
pass "$VERSION: the generated arm hook finds the session log and Stop retires it"

"$ROOT/bin/fm-send.sh" "$ID" 'Runtime retry verification: run sleep 30 in your shell tool, then write DONE into slept.txt. Acknowledge this instruction by moving its .msg file into handled/ as the doorbell instructs.' > "$LAB/send.log" 2>&1 \
  || fail "steer failed: $(cat "$LAB/send.log")"
seen_busy=0
for _ in $(seq 1 240); do
  if [ "$(fm_busy_classify tmux "$TARGET" devin "$ID" "$H/state")" = 'busy devin-hook' ] \
    && capture | fm_busy_lines_match devin; then seen_busy=1; break; fi
  sleep 0.5
done
[ "$seen_busy" = 1 ] || fail 'the sleep turn never started'
"$ROOT/bin/fm-control.sh" "$ID" interrupt > "$LAB/interrupt.log" 2>&1 || fail "interrupt failed: $(cat "$LAB/interrupt.log")"
for _ in $(seq 1 60); do
  screen_text | grep -q 'Canceled. What should Devin do?' && break
  sleep 0.5
done
screen_text | grep -q 'Canceled. What should Devin do?' || fail 'the interrupt did not cancel the turn'

watch_args=
for _ in $(seq 1 20); do
  watch_pid=$(pgrep -f "fm-devin-rate-limit-retry.sh watch $H/state $ID " | head -1)
  watch_args=$(ps -o args= -p "${watch_pid:-0}" 2>/dev/null)
  [ -n "$watch_args" ] && break
  sleep 0.5
done
session_log=$(printf '%s\n' "$watch_args" | awk '{print $(NF-1)}')
case "$session_log" in
  "$H/user-home/.local/share/devin/cli/logs/devin_"*_*.log) ;;
  *) fail "no sentinel follows the isolated session log after the cancel: $watch_args" ;;
esac
printf '%s\n' '2026-09-25T19:57:19.830119Z  WARN run_acp_server: agent_client_protocol::jsonrpc::outgoing_actor: Sending error response id=Str("fm-live-guard") method=session/prompt error=Error { code: -32010: Unknown error, message: "Reached free model rate limit. Upgrade to Max for higher limits, or switch to a different model. Your limit will reset in 2 seconds. (trace ID: fm-live-guard)", data: Some(Object {"cognition.ai/errorKind": String("unavailable"), "cognition.ai/retryable": Bool(true)}) }' >> "$session_log"
retried=0
for _ in $(seq 1 60); do
  grep -q '"event":"retried"' "$RETRY_LOG" 2>/dev/null && { retried=1; break; }
  sleep 1
done
[ "$retried" = 1 ] || fail "the sentinel sent no retry after the injected line: $(cat "$RETRY_LOG")"
grep -q '"event":"detected"' "$RETRY_LOG" || fail 'the retry was sent without a detection'
retry_msg=$(grep -l 'Automatic retry' "$H/state/$ID.inbox"/*.msg "$H/state/$ID.inbox/handled"/*.msg 2>/dev/null | head -1)
[ -n "$retry_msg" ] || fail 'the retry never reached the durable inbox'
acked=0
for _ in $(seq 1 240); do
  grep -q 'Automatic retry' "$H/state/$ID.inbox/handled"/*.msg 2>/dev/null && { acked=1; break; }
  sleep 0.5
done
[ "$acked" = 1 ] || fail "the worker did not acknowledge the retry: $(screen_text | tail -15)"
wait_file "$WT/slept.txt"
wait_idle
[ ! -e "$H/state/$ID.devin-retry/count" ] || fail 'the retry turn Stop did not reset the count'
pass "$VERSION: an injected rate-limit line after a hook-less cancel drives a real acknowledged retry"

"$ROOT/bin/fm-control.sh" "$ID" exit > "$LAB/exit.log" 2>&1 || fail "exit failed: $(cat "$LAB/exit.log")"
for _ in $(seq 1 20); do
  pgrep -f "fm-devin-rate-limit-retry.sh watch $H/state $ID " >/dev/null || break
  sleep 0.5
done
! pgrep -f "fm-devin-rate-limit-retry.sh watch $H/state $ID " >/dev/null \
  || fail 'a retry sentinel survived plain exit'
pass "$VERSION: plain exit leaves no retry sentinel"
