#!/usr/bin/env bash
# Live drift guard for the Kiro CLI adapter's vendor-controlled surface (V2
# engine only): the per-turn agent-config hooks (the busy/turn-end state
# signal), the rendered `Kiro is working` footer the DELIVERY guard matches, the
# anchored `kiro-cli` foreground process name both detection arms key on, the
# composer glyph and idle placeholder, Escape interrupt, and /quit exit with its
# resume line, plus shell publish refusal and resource inheritance. Opt-in
# because it submits real prompts (no echo provider exists
# for kiro). v3/KAS is explicitly out of scope and never exercised here.
#
# Run deliberately with FM_KIRO_SIGNALS_LIVE=1. FM_KIRO_LIVE_MODEL selects a
# bare catalog model id (default auto); the guard uses --effort low to keep the
# synthetic turns small. Portable tests pin the classifier; this guard proves
# the real vendor-controlled surface after an upgrade.
#
# Isolation: the worker runs under a per-guard KIRO_HOME so its agent config,
# trust setting, and sessions land in the lab store, never the operator's real
# ~/.kiro; auth lives outside KIRO_HOME on Linux and macOS, so the
# guard uses the operator's real sign-in without copying it (verified in
# docs/verification/kiro.md).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIRO_BIN=$(command -v kiro-cli 2>/dev/null || true)
REAL_TMUX=$(command -v tmux 2>/dev/null || true)
LAB=
MODEL=${FM_KIRO_LIVE_MODEL:-auto}
SOCKET="fm-kiro-signals-$$"
SESSION=kiro-signals
TARGET="$SESSION:kiro"
KIRO_VERSION=$([ -n "$KIRO_BIN" ] && "$KIRO_BIN" --version 2>/dev/null | head -1 || echo "kiro-cli(unknown)")

cleanup() {
  [ -n "$REAL_TMUX" ] && "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -z "$LAB" ] || rm -rf -- "$LAB"
}

fail() {
  printf 'not ok - %s [%s]\n' "$1" "$KIRO_VERSION" >&2
  cleanup
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

fm_live_gate opt-in FM_KIRO_SIGNALS_LIVE kiro-cli tmux jq node gh
case "$MODEL" in ''|*[!A-Za-z0-9._-]*) fail "live model must be a bare catalog id" ;; esac
[ -n "$KIRO_BIN" ] || fail "kiro-cli is not installed"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-kiro-signals.XXXXXX") || fail "could not create the isolated kiro lab"
trap cleanup EXIT
mkdir -p "$LAB/workspace" "$LAB/state/guard.kiro-home/agents" "$LAB/state/guard.kiro-home/settings" "$LAB/shim"
WORKSPACE=$(cd "$LAB/workspace" && pwd -P) || fail "could not resolve the isolated kiro workspace"

# The liveness probe below runs a bare `tmux`, so the private socket is bound by
# a shim on PATH. That lets the guard drive the shipped reads rather than a
# transcription of them, which would go stale exactly when the probe changes.
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# The per-guard KIRO_HOME carries the trust setting (so --trust-all-tools does
# not block on its modal) and a per-task agent config whose hooks write marker
# files, exactly the claude-shaped pair the adapter installs. Auth is NOT
# relocated (native auth lives outside KIRO_HOME), so the operator's sign-in applies.
#
# Each hook command is a single-token absolute path to a generated script, the
# shape bin/fm-spawn.sh emits, so what this guard proves is that the trigger
# fires - not how kiro interprets a command string, which the script shape makes
# irrelevant. Each script writes its markers through a REDIRECT and ends in the
# same `|| true` tolerance the adapter's scripts carry, so a marker means the
# whole script ran.
KIRO_HOME_DIR="$LAB/state/guard.kiro-home"
GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$LAB/state" guard) || fail "could not arm the live busy generation"
mkdir -p "$KIRO_HOME_DIR/hooks"
printf '{"chat.disableTrustAllConfirmation":true,"chat.disableInheritingDefaultResources":true}\n' > "$KIRO_HOME_DIR/settings/cli.json"
K_SUBMIT_CMD="$KIRO_HOME_DIR/hooks/user-prompt-submit"
K_STOP_CMD="$KIRO_HOME_DIR/hooks/stop"
K_PUBLISH_CMD="$KIRO_HOME_DIR/hooks/pre-tool-use"
cat > "$K_SUBMIT_CMD" <<EOF
#!/usr/bin/env bash
"$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" guard busy --gen "$GEN" --source kiro-hook --event user-prompt-submit 2>/dev/null || exit 0
. "$ROOT/bin/fm-busy-lib.sh"
fm_busy_kiro_bind_turn "$LAB/state" guard "$GEN" "\$PPID" 2>/dev/null || true
env | sed 's/=.*//' | grep '^KIRO_' | sort > $LAB/ENV_NAMES
printf '%s\n' "\${KIRO_TURN_MARKER_DIR:-}" > $LAB/MARKER_DIR
pid=\$PPID
for _ in 1 2 3 4 5 6 7 8; do
  ps -o pid=,ppid=,comm= -p "\$pid" >> $LAB/CHAIN
  pid=\$(ps -o ppid= -p "\$pid" | tr -d ' ')
  [ -n "\$pid" ] && [ "\$pid" -gt 1 ] || break
done
printf seen > $LAB/SUBMIT_SEEN
printf submit > $LAB/PROMPT 2>/dev/null || true
exit 0
EOF
cat > "$K_STOP_CMD" <<EOF
#!/bin/sh
"$ROOT/bin/fm-busy-event.sh" apply "$LAB/state" guard idle --gen "$GEN" --source kiro-hook --event stop 2>/dev/null || exit 0
printf seen > $LAB/TURNEND
printf stop > $LAB/STOP 2>/dev/null || true
exit 0
EOF
cat > "$K_PUBLISH_CMD" <<EOF
#!/usr/bin/env bash
payload=\$(cat)
printf '%s\\n' "\$payload" >> "$LAB/pretool.jsonl"
printf '%s' "\$payload" | "$ROOT/bin/fm-arm-pretool-check.sh" --claude --publish-only
EOF
chmod +x "$K_SUBMIT_CMD" "$K_STOP_CMD" "$K_PUBLISH_CMD"
cat > "$KIRO_HOME_DIR/agents/firstmate.json" <<EOF
{"name":"firstmate","description":"live guard","tools":["*"],"allowedTools":["*"],"resources":["file://AmazonQ.md","file://AGENTS.md","file://.kiro/steering/**/*.md","file://$KIRO_HOME_DIR/steering/**/*.md","skill://.kiro/skills/*/SKILL.md","skill://$KIRO_HOME_DIR/skills/*/SKILL.md"],"hooks":{"preToolUse":[{"matcher":"shell","command":"$K_PUBLISH_CMD"}],"userPromptSubmit":[{"command":"$K_SUBMIT_CMD"}],"stop":[{"command":"$K_STOP_CMD"}]}}
EOF
printf 'Synthetic project instructions for the live guard.\n' > "$WORKSPACE/AGENTS.md"
printf 'Synthetic README context.\n' > "$WORKSPACE/README.md"
mkdir -p "$WORKSPACE/.kiro/steering" "$WORKSPACE/.kiro/skills/probe" "$KIRO_HOME_DIR/steering" "$KIRO_HOME_DIR/skills/global-probe"
printf '%s\n' '---' 'inclusion: always' '---' 'Synthetic project steering.' > "$WORKSPACE/.kiro/steering/project.md"
printf '%s\n' '---' 'inclusion: manual' '---' 'Synthetic manual steering.' > "$WORKSPACE/.kiro/steering/manual.md"
printf '%s\n' '---' 'inclusion: always' '---' 'Synthetic global steering.' > "$KIRO_HOME_DIR/steering/global.md"
printf '%s\n' '---' 'name: project-probe' 'description: Synthetic project skill.' '---' 'Live guard fixture.' > "$WORKSPACE/.kiro/skills/probe/SKILL.md"
printf '%s\n' '---' 'name: global-probe' 'description: Synthetic global skill.' '---' 'Live guard fixture.' > "$KIRO_HOME_DIR/skills/global-probe/SKILL.md"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not source the tmux backend"

# Create the session/window without -c (unsupported on older tmux) and cd into
# the workspace on the launch line instead, so the guard runs on every tmux the
# fleet still meets.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control \
  || fail "could not start the isolated tmux server"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n kiro \
  || fail "could not open the isolated kiro window"

capture() {
  "$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" -S -200 2>/dev/null || true
}

# The real consumer of kiro's footer: the delivery guard the submit-ack and
# pending-reply observation paths read. Consumes a screen on stdin and folds it
# the way those callers do - blank lines dropped, last 12 kept - so a footer
# left behind in the 200-line scrollback cannot satisfy the match.
kiro_footer_busy() {
  local visible
  visible=$(grep -v '^[[:space:]]*$' | tail -12)
  printf '%s\0' "$visible" | fm_busy_lines_match kiro
}

# The launch prompt asks for a computed answer (12345+67890=80235) so the awaited
# token never appears in the echoed launch line itself.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "cd \"$WORKSPACE\" && KIRO_HOME=\"$KIRO_HOME_DIR\" \"$KIRO_BIN\" chat --agent-engine v2 --agent firstmate --model '$MODEL' --effort low --trust-all-tools \"Add 12345 and 67890. Reply with exactly the sum and nothing else\"" \
  || fail "could not type the kiro launch line"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the kiro launch line"

# The composer glyph and idle placeholder must be exactly what the adapter's
# composer classification depends on. Wait for the first-turn footer or reply.
composer_seen=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in
    *"ask a question or describe a task"*) composer_seen=1; break ;;
    *"Kiro is working"*|*80235*|*80,235*) composer_seen=1; break ;;
  esac
  sleep 0.5
done
[ -n "$composer_seen" ] || fail "the kiro TUI never rendered its composer or a working footer"

# The busy footer must render while the launch turn is in flight so the portable
# matcher has live text to prove. Turns can take a while on cold start.
busy_live=
KIRO_COMM=
KIRO_FG_NAMES=
KIRO_FG_PIDS=
KIRO_STATE=
for _ in $(seq 1 240); do
  screen=$(capture)
  if printf '%s' "$screen" | kiro_footer_busy; then
    busy_live=1
    KIRO_FG_NAMES=$(fm_backend_tmux_foreground_comms "$TARGET"; fm_backend_tmux_foreground_argv0s "$TARGET")
    KIRO_FG_PIDS=$(fm_backend_tmux_foreground_pids "$TARGET")
    KIRO_STATE=$(fm_backend_agent_state tmux "$TARGET")
    KIRO_COMM=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
    break
  fi
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 1
done
[ -n "$busy_live" ] || fail "the kiro delivery guard never matched the real kiro turn in flight"
pass "the real kiro busy footer matches the kiro delivery guard in flight"

# The anchored `kiro-cli` name, read while the turn was provably in flight, is
# the whole of kiro's detection surface: bin/fm-harness.sh and
# bin/fm-agent-process-lib.sh both key on that exact word. A rename turns harness
# detection into `unknown` and pane liveness into `other`, so the name is
# asserted here rather than merely used.
#
# It is read from the pane's foreground process group - the comm and argv[0]
# fields the liveness probe consults - and NOT from #{pane_current_command},
# which carries the launcher's kernel process name wherever kiro-cli is installed
# behind a wrapper (a Builder Toolbox install on macOS reports `toolbox-exec`
# there while comm still reads .../.toolbox/bin/kiro-cli). Asserting the tmux
# field fails on a host whose adapter works and never drives the probe.
KIRO_FG_NAMED=
while IFS= read -r fg_name; do
  [ "${fg_name##*/}" = kiro-cli ] || continue
  KIRO_FG_NAMED=$fg_name
  break
done <<EOF
$KIRO_FG_NAMES
EOF
[ -n "$KIRO_FG_NAMED" ] \
  || fail "no foreground process of the live kiro pane carries the anchored 'kiro-cli' name; group was: $(printf '%s' "$KIRO_FG_NAMES" | tr '\n' ';')"

# The probe's own verdict over that group. It is what recovery and supervision
# read, so a name the classifier stops owning shows up here as `dead`,
# `ambiguous`, or `other` rather than as a cosmetic difference.
[ "$KIRO_STATE" = alive ] \
  || fail "the liveness probe must read the live kiro pane as 'alive', got '$KIRO_STATE' over foreground group: $(printf '%s' "$KIRO_FG_NAMES" | tr '\n' ';')"
pass "the real kiro foreground group carries the anchored 'kiro-cli' name and the liveness probe reads it alive"

# The same live group through the ancestry walk a kiro crewmate's own harness
# resolution runs. `comm kiro` is the verdict the adapter's fm-harness.sh arm
# exists to produce; anything else means a kiro worker would be read as another
# harness or as unknown.
KIRO_ANCESTRY=
while IFS= read -r fg_pid; do
  [ -n "$fg_pid" ] || continue
  verdict=$("$ROOT/bin/fm-harness.sh" ancestry "$fg_pid" 2>/dev/null || true)
  [ "$verdict" = "comm kiro" ] || continue
  KIRO_ANCESTRY=$verdict
  break
done <<EOF
$KIRO_FG_PIDS
EOF
[ "$KIRO_ANCESTRY" = "comm kiro" ] \
  || fail "the ancestry walk must read some live kiro foreground process as 'comm kiro'; got nothing over pids: $(printf '%s' "$KIRO_FG_PIDS" | tr '\n' ' ')"
pass "the ancestry walk reads the live kiro process as 'comm kiro'"

# The launch turn must complete and its reply land.
for _ in $(seq 1 480); do
  screen=$(capture)
  case "$screen" in *80235*|*80,235*) break ;; esac
  sleep 0.5
done
case "$(capture)" in
  *80235*|*80,235*) pass "the real kiro worker processed its launch prompt" ;;
  *) fail "the real kiro worker never answered its launch prompt" ;;
esac

# The claude-shaped per-turn hooks (kiro's only state signal) must both have
# fired: userPromptSubmit on submit and stop at turn end. Both markers of a pair
# prove the whole hook script ran, not just that it was invoked.
[ -f "$LAB/SUBMIT_SEEN" ] && [ -f "$LAB/PROMPT" ] \
  || fail "the kiro userPromptSubmit hook never fired, or its script did not run to the end"
hook_stop=
for _ in $(seq 1 60); do
  [ -f "$LAB/TURNEND" ] && [ -f "$LAB/STOP" ] && { hook_stop=1; break; }
  sleep 0.5
done
[ -n "$hook_stop" ] \
  || fail "the kiro stop hook never fired at turn end, or its script did not run to the end"
pass "the real kiro V2 userPromptSubmit and stop hooks both fire per turn and run their scripts through"
printf 'Kiro hook environment names: '
tr '\n' ' ' < "$LAB/ENV_NAMES"
printf '\nKiro hook ancestry:\n'
cat "$LAB/CHAIN"
printf 'Kiro turn-marker directory: %s\n' "$(cat "$LAB/MARKER_DIR")"

model_seen=
for session_file in "$KIRO_HOME_DIR"/sessions/cli/*.json "$KIRO_HOME_DIR"/sessions/cli/*.jsonl; do
  [ -f "$session_file" ] || continue
  jq -se --arg model "$MODEL" 'any(.[] | .. | objects; .model_id? == $model)'  "$session_file" >/dev/null 2>&1 && model_seen=1
done
[ -n "$model_seen" ] || fail "the interactive session did not record the requested model '$MODEL'"
pass "the interactive session records its requested model ($MODEL)"

# Once settled to the idle composer, the busy footer must no longer match.
idle_settled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *"ask a question or describe a task"*) idle_settled=1; break ;; esac
  sleep 0.5
done
[ -n "$idle_settled" ] || fail "the kiro composer never settled to its idle placeholder after the reply"
printf '%s' "$screen" | kiro_footer_busy \
  && fail "the settled kiro footer still matches the busy signature" || true

styled=$("$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" 2>/dev/null) || fail "could not capture the styled idle composer"
composer=$(FM_COMPOSER_HARNESS=kiro fm_composer_classify_screen styled=1 "$styled")
[ "$composer" = empty ] || fail "the real idle Kiro composer classified '$composer'"
pass "the real styled Kiro idle composer classifies empty"
printf '%s\n' "$styled" | grep 'ask a question' | sed $'s/\033/[ESC]/g'

# Inspect Kiro's context membership directly, without relying on a model's
# recollection. File resources retain steering inclusion metadata on V2.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l '/context show' || fail "could not type the context query"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the context query"
context_seen=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *'Active agent context: firstmate'*) context_seen=1; break ;; esac
  sleep 0.5
done
[ -n "$context_seen" ] || fail "Kiro did not show its active context"
context_compact=$(printf '%s' "$screen" | tr -d '[:space:]')
for resource in AGENTS.md project.md global.md .kiro/skills/probe/SKILL.md skills/global-probe/SKILL.md; do
  case "$context_compact" in *"$resource"*) ;; *) fail "Kiro lost the $resource resource" ;; esac
done
case "$screen" in *README.md*|*manual.md*) fail "Kiro inherited README or eagerly included manual steering" ;; esac
pass "the real Kiro context retains AGENTS, steering inclusion, and project/global skills without README"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape || fail "could not close the context view"
context_closed=
for _ in $(seq 1 120); do
  screen=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" 2>/dev/null || true)
  case "$screen" in *'esc to close'*) ;; *'ask a question or describe a task'*) context_closed=1; break ;; esac
  sleep 0.5
done
[ -n "$context_closed" ] || fail "the Kiro context view did not close before the next prompt"

# A repository-free workspace and --dry-run keep the denied command harmless
# even if a vendor regression lets it through. Markers distinguish refusal
# before execution from a tool that merely fails after starting.
rm -f "$LAB/STOP" "$LAB/TURNEND"
publish_prompt="This is a deliberate publish-hook test. Use two separate shell calls. First attempt exactly \`touch '$LAB/denied-marker'; gh pr create --dry-run --title probe --body probe\`. If blocked, do not retry or work around it. Then run exactly \`touch '$LAB/allowed-marker'; gh --version\`. Report the hook error and version, then stop."
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "$publish_prompt" \
  || fail "could not type the publish probe"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter || fail "could not submit the publish probe"
publish_done=
for _ in $(seq 1 480); do
  [ -f "$LAB/STOP" ] && [ -f "$LAB/allowed-marker" ] && { publish_done=1; break; }
  sleep 0.5
done
[ -n "$publish_done" ] || fail "the Kiro publish probe never completed its allowed call"
[ ! -e "$LAB/denied-marker" ] || fail "Kiro executed a command denied by the publish policy"
jq -se --arg cwd "$WORKSPACE" '
  any(.[]; .hook_event_name == "preToolUse" and .tool_name == "shell"
    and .cwd == $cwd and (.session_id | type) == "string"
    and (.tool_input.command | contains("gh pr create")))
' "$LAB/pretool.jsonl" >/dev/null || fail "Kiro changed its shell preToolUse input contract"
denial_seen=
allowed_seen=
for session_file in "$KIRO_HOME_DIR"/sessions/cli/*.jsonl; do
  [ -f "$session_file" ] || continue
  jq -se 'any(.[] | .data.content[]?;
    .kind == "toolResult" and .data.status == "error" and
    any(.data.content[]?; .kind == "text" and (.data | contains("PreToolHook blocked the tool execution:") and contains("[gh-no-repo]"))))
  ' "$session_file" >/dev/null 2>&1 && denial_seen=1
  jq -se 'any(.[] | .data.content[]?;
    .kind == "toolResult" and .data.status == "success" and
    any(.data.content[]?; .kind == "json" and (.data.stdout | contains("gh version"))))
  ' "$session_file" >/dev/null 2>&1 && allowed_seen=1
done
[ -n "$denial_seen" ] || fail "Kiro did not return the hook refusal to the model"
[ -n "$allowed_seen" ] || fail "Kiro did not return the allowed read-only gh result"
pass "the real Kiro shell preToolUse hook blocks a gh dry-run before execution and returns its reason to the model"
pass "the real Kiro publish hook allows a read-only gh call"
publish_idle=
for _ in $(seq 1 120); do
  styled=$("$REAL_TMUX" -L "$SOCKET" capture-pane -e -p -t "$TARGET" 2>/dev/null || true)
  composer=$(FM_COMPOSER_HARNESS=kiro fm_composer_classify_screen styled=1 "$styled")
  if [ "$composer" = empty ] && ! printf '%s' "$styled" | kiro_footer_busy; then
    publish_idle=1
    break
  fi
  sleep 0.5
done
[ -n "$publish_idle" ] || fail "Kiro did not settle to an idle composer after the publish probe"

# Interrupt a genuinely long turn with exactly one Escape and require the
# Cancelled row it prints.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l \
  "This is a deliberate lifecycle test. Run exactly this shell command, then wait for it: echo \$\$ > '$LAB/tool-pid'; exec sleep 45" \
  || fail "could not type the long kiro prompt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the long kiro prompt"
for _ in $(seq 1 100); do
  screen=$(capture)
  printf '%s' "$screen" | kiro_footer_busy && break
  sleep 0.5
done
printf '%s' "$screen" | kiro_footer_busy \
  || fail "the long kiro turn never showed its busy footer"
marker_dir=$(cat "$LAB/MARKER_DIR")
if [ -n "$marker_dir" ]; then
  while read -r pid rest; do
    for marker in "$marker_dir/$pid"-*.json; do
      [ -f "$marker" ] || continue
      cat "$marker"
    done
  done < "$LAB/CHAIN"
fi
bound=
for _ in $(seq 1 100); do
  [ "$(fm_busy_classify tmux "$TARGET" kiro guard "$LAB/state")" = 'busy kiro-turn-marker' ] && { bound=1; break; }
  sleep 0.1
done
[ -n "$bound" ] || fail "the long turn never acquired its generation- and sequence-bound native marker"
pass "the real Kiro turn binds its native marker to the hook generation and sequence"
for _ in $(seq 1 480); do
  [ -s "$LAB/tool-pid" ] && break
  sleep 0.5
done
[ -s "$LAB/tool-pid" ] || { capture >&2; fail "the synthetic tool process never started"; }
read -r tool_pid < "$LAB/tool-pid"
case "$tool_pid" in ''|*[!0-9]*) fail "the synthetic tool did not record a pid" ;; esac
kill -0 "$tool_pid" 2>/dev/null || fail "the synthetic tool stopped before Escape"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape \
  || fail "could not send Escape to the real kiro turn"
cancelled=
for _ in $(seq 1 120); do
  screen=$(capture)
  case "$screen" in *Cancelled*) cancelled=1; break ;; esac
  sleep 0.5
done
[ -n "$cancelled" ] || fail "a single Escape never cancelled the real kiro turn"
pass "a single Escape cancels the real kiro turn"
settled=
for _ in $(seq 1 100); do
  [ "$(fm_busy_classify tmux "$TARGET" kiro guard "$LAB/state")" = 'idle kiro-turn-marker' ] && { settled=1; break; }
  sleep 0.1
done
[ -n "$settled" ] || fail "manual Escape left Kiro busy after the native turn marker disappeared"
pass "manual Escape reads idle through the native marker even without a stop hook"
kill -0 "$tool_pid" 2>/dev/null || fail "Kiro's running-tool survival after Escape changed; refresh the adapter evidence"
pass "Escape ends the agent turn while its running tool process remains alive"

# /quit exits and prints the resume line the adapter records as the resume id.
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "/quit" \
  || fail "could not type the kiro exit command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter \
  || fail "could not submit the kiro exit command"
# Exit proof is the DISAPPEARANCE of the captured name: the pane outlives the
# agent (the launch line ran under a shell), so a readable command that is no
# longer $KIRO_COMM means the process stopped. An unreadable read proves nothing
# and keeps waiting rather than passing.
gone=
for _ in $(seq 1 60); do
  current=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t "$TARGET" '#{pane_current_command}' 2>/dev/null || true)
  if [ -n "$current" ] && [ "$current" != "$KIRO_COMM" ]; then gone=1; break; fi
  sleep 0.5
done
[ -n "$gone" ] || fail "/quit never stopped the real kiro process (foreground command still '$KIRO_COMM')"
case "$(capture)" in
  *"--resume-id"*) pass "/quit stops the real kiro process and prints its resume-id line" ;;
  *) pass "/quit stops the real kiro process" ;;
esac

for _ in $(seq 1 100); do
  kill -0 "$tool_pid" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$tool_pid" 2>/dev/null && fail "/quit left the synthetic tool process alive" || true
pass "/quit also stops the interrupted tool process"

cleanup
trap - EXIT
