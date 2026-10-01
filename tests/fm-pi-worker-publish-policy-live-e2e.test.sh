#!/usr/bin/env bash
# Default-on live guard for the publish policy in the generated Pi worker
# extension (bin/fm-spawn.sh writes state/<id>.pi-ext.ts). Its tool_call handler
# runs bin/fm-arm-pretool-check.sh --publish-only and returns {block: true} on a
# denial; whether that stops the bash command is Pi's own contract, so only a
# real Pi can prove it. The portable regression in
# tests/fm-busy-adapter-wiring.test.sh pins the handler's verdicts in a plain
# Node host.
#
# For pi and pi-signed, whichever is installed, the real fm-spawn writes the
# extension for a scratch task, then the real binary runs it in print mode with
# a local faux provider whose only answer is one bash tool call. Each command
# first touches a marker, so a marker proves the command ran: a gh publish the
# gate cannot check and a hook-skipping push must leave none and come back as a
# tool error naming the policy's reason, and an ordinary command must leave one.
# No model turn reaches any provider, so no tokens are spent. Scratch FM_HOME,
# project, Pi agent directory, and session directory; nothing global is touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate default-on FM_PI_WORKER_PUBLISH_POLICY_LIVE pi node jq

TMP_ROOT=$(fm_test_tmproot fm-pi-worker-publish-policy)
trap fm_test_cleanup EXIT

# Resolve the real runners before any fake directory joins PATH.
RUNNERS=()
for runner in pi pi-signed; do
  bin=$(type -P -- "$runner" 2>/dev/null) || {
    printf 'skip-runner: %s is not installed, so its worker extension was not exercised\n' "$runner"
    continue
  }
  RUNNERS+=("$runner=$bin")
done
[ "${#RUNNERS[@]}" -gt 0 ] || fail "no Pi runner is installed, so nothing was checked"

ID=pi-publish-live
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
WT="$TMP_ROOT/wt"
fakebin=$(make_spawn_fakebin "$TMP_ROOT/fake" pi pi-signed)
fm_test_spawn_home "$HOME_DIR" pi
fm_git_worktree "$PROJ" "$WT" wt-pi-publish-live
fm_test_spawn_brief "$HOME_DIR" "$ID"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$ID" "$PROJ" --mode direct-PR --yolo off)
expect_code 0 $? "pi spawn should succeed: $out"
EXT="$HOME_DIR/state/$ID.pi-ext.ts"
assert_present "$EXT" "pi spawn did not write the per-task extension"

PROBE="$TMP_ROOT/faux-bash-probe.ts"
cat >"$PROBE" <<'TS'
import { createFauxCore, fauxAssistantMessage, fauxText, fauxToolCall } from "@earendil-works/pi-ai";

export default function (pi: any): void {
  const faux = createFauxCore({
    api: "publish-policy-probe-api",
    provider: "publish-policy-probe",
    models: [{
      id: "deterministic",
      name: "Worker publish-policy probe",
      reasoning: false,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: 4096,
      maxTokens: 128,
    }],
    tokenSize: { min: 1, max: 1 },
  });
  pi.registerProvider("publish-policy-probe", {
    baseUrl: "http://127.0.0.1/unused",
    apiKey: "test-only",
    api: faux.api,
    models: faux.models,
    streamSimple: faux.streamSimple,
  });
  faux.setResponses([
    fauxAssistantMessage([fauxToolCall("bash", { command: process.env.PROBE_COMMAND }, { id: "probe" })], { stopReason: "toolUse" }),
    fauxAssistantMessage([fauxText("PUBLISH_POLICY_PROBE_DONE")]),
  ]);
}
TS

# run_probe <runner-bin> <command>: one print-mode run from the worktree; prints
# the bash tool result as "<isError>\t<text>".
run_probe() {
  local events
  events=$(cd "$WT" && env -u FM_HOME -u GIT_CONFIG_COUNT PROBE_COMMAND="$2" \
    PI_CODING_AGENT_DIR="$TMP_ROOT/agent" PI_OFFLINE=1 \
    "$1" --mode json --approve --no-context-files --no-skills --no-prompt-templates --no-extensions \
    -e "$PROBE" -e "$EXT" --session-dir "$TMP_ROOT/sessions" \
    --model publish-policy-probe/deterministic go </dev/null 2>&1) || {
    printf 'run-failed\t%s\n' "$events"
    return 0
  }
  printf '%s\n' "$events" | jq -r 'select(.type == "tool_execution_end" and .toolName == "bash")
    | "\(.isError)\t\([.result.content[]?.text] | join(" "))"' 2>/dev/null | head -n 1
}

mkdir -p "$TMP_ROOT/agent" "$TMP_ROOT/sessions" "$TMP_ROOT/markers"
for entry in "${RUNNERS[@]}"; do
  runner=${entry%%=*}
  bin=${entry#*=}
  version=$("$bin" --version 2>/dev/null | head -n 1) || version=unknown
  m="$TMP_ROOT/markers/$runner"

  for case in "gh-no-repo|gh pr create --title t --body x" "git-no-verify|git push --no-verify origin HEAD"; do
    code=${case%%|*}
    result=$(run_probe "$bin" "touch '$m.$code'; ${case#*|}")
    [ ! -e "$m.$code" ] || fail "$runner $version ran a command its worker extension had to block: ${case#*|}"
    case "$result" in
      true*"$code"*) ;;
      *) fail "$runner $version did not report the publish policy's $code block for '${case#*|}': $result" ;;
    esac
  done

  result=$(run_probe "$bin" "touch '$m.ordinary'")
  [ -e "$m.ordinary" ] || fail "$runner $version did not run an ordinary command through its worker extension: $result"
  case "$result" in
    false*) ;;
    *) fail "$runner $version reported an ordinary command as an error: $result" ;;
  esac
  pass "$runner $version: the worker extension blocks a gh publish and a --no-verify push before they run and lets an ordinary command run"
done
