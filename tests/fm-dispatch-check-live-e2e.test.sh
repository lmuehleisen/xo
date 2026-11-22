#!/usr/bin/env bash
# Live guard for the top-lane checker's harness contract (bin/fm-dispatch-check-lib.sh).
#
# The checker's verdict comes from what each vendor CLI emits: Claude Code's
# --output-format json structured_output, and Codex's --output-schema answer in
# its -o file. tests/fm-dispatch-resolve.test.sh pins the logic with fakes; this
# guard runs one real check through every INSTALLED checker harness and fails
# naming the harness and version when the answer no longer parses. It submits a
# prompt, so it is opt-in: FM_DISPATCH_CHECK_LIVE=1 (or FM_LIVE=1) runs it.
# FM_DISPATCH_CHECK_LIVE_CLAUDE_MODEL and FM_DISPATCH_CHECK_LIVE_CODEX_MODEL
# override the default models.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_DISPATCH_CHECK_LIVE jq

LAB=$(fm_test_tmproot fm-dispatch-check-live)
cleanup() { fm_test_rm_tmproot "${LAB:-}"; }
trap cleanup EXIT

cat > "$LAB/task.txt" <<'MD'
## Captain's intent
Fix a typo in the README heading.

## Firstmate spec
Change "Instalation" to "Installation" in the README's first heading. No other edits.
MD

checked=0
for harness in claude codex; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf 'note - %s not installed; its checker route was not exercised\n' "$harness"
    continue
  fi
  case "$harness" in
    claude) model=${FM_DISPATCH_CHECK_LIVE_CLAUDE_MODEL:-claude-opus-5-5}; version=$(claude --version 2>/dev/null | head -1) ;;
    codex) model=${FM_DISPATCH_CHECK_LIVE_CODEX_MODEL:-gpt-6.2-sol}; version=$(codex --version 2>/dev/null | head -1) ;;
  esac
  jq -n --arg h "$harness" --arg m "$model" '{
    lane_check: {top_lanes: ["deep"], harness: $h, model: $m, effort: "medium", timeout_seconds: 30},
    classes: {c: {family: "c", unmetered: true, routes: [{harness: "claude"}]}},
    rules: [
      {lane: "deep", when: "Intricate cross-process systems work.", classes: ["c"]},
      {lane: "small", when: "A one-line or typo fix whose exact change the brief states.", classes: ["c"]}]}' \
    > "$LAB/rules-$harness.json"
  # shellcheck disable=SC2016 # expanded by the child shell
  result=$(bash -c '. "$1/bin/fm-dispatch-check-lib.sh"; fm_dispatch_check_run "$2" "$3" example /nonexistent' \
    _ "$ROOT" "$LAB/rules-$harness.json" "$LAB/task.txt")
  jq -e '.ran == true and (.pick | IN("deep", "small")) and (.reason | type) == "string" and (.reason | length) > 0' \
    <<<"$result" >/dev/null || fail "$harness ($version, $model): the checker answer did not parse: $result"
  printf 'ok - %s (%s, %s) answered %s in %s ms\n' "$harness" "$version" "$model" \
    "$(jq -r .pick <<<"$result")" "$(jq -r .latency_ms <<<"$result")"
  checked=$((checked + 1))
done
[ "$checked" -gt 0 ] || fail "no checker harness is installed, so nothing was checked"
pass "every installed checker harness returns a parseable lane pick"
