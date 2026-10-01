#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) harness adapter: harness
# detection, the approval-mode mapping and its refusals, the mandatory
# worktree grant, the effort ceiling and the model-id/--effort conflict, the
# secondmate launch, native hook transports, and the control mechanics.
#
# The facts pinned here are the ones an Antigravity release could silently
# change and the ones a wrong guess would make dangerous:
#   1. --dangerously-skip-permissions must be unreachable from every
#      config/crew-permissions value. It is agy's only blanket approval switch,
#      routine work stays reviewed rather than routed through it, and a parked
#      worker must never be unblocked by adding it.
#   2. --add-dir for the task worktree is load-bearing, not cosmetic. Verified
#      on agy 1.2.0: with the pane cwd already inside the worktree but no
#      --add-dir, a file write landed in agy's own scratch directory while the
#      model reported success. A launch missing it changes nothing in the task's
#      local copy and still looks healthy.
#   3. agy publishes reasoning effort TWICE - as a suffix inside model ids and
#      as --effort - and passing both is a launch-refusing conflict, so the
#      adapter must emit at most one of them.
#   4. Worker hooks bind generation and conversation before closing busy;
#      primary hooks compose the shared guard without bypassing review.
#   5. Herdr, the public agent-native terminal backend (herdr.dev) that
#      bin/backends/herdr.sh drives, already registers agy panes as agents, and
#      exit detection proves the agent at process level before trusting any
#      registration (the shared post-#4115 contract in that backend): a
#      registered status plus a process view naming agy is live and refuses
#      replacement, a registered status over a proven shell-only pane is the
#      explicit stale-agent state, and nothing short of that shared proof flips
#      an agy pane to agent-free.
#
# Detection and launch shape are harness-dependent facts, so this portable
# suite pins the classifier and the rendered command with real processes and no
# agy installed, while tests/fm-agy-signals-live-e2e.test.sh proves the same
# facts against the real binary.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# bin/fm-harness.sh checks verified ENV markers before ancestry, so an
# inherited marker from whichever harness launched this suite would outrank the
# agy signals these cases assert. Drop the ambient markers first.
unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT \
  CURSOR_INVOKED_AS GEMINI_CLI JETSKI_APP_DATA_DIR ATLASSIAN_AGENT_TYPE \
  FM_DEVIN_HARNESS FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)

# --- detection --------------------------------------------------------------

# bin/fm-harness.sh lets a structural ancestor of a DIFFERENT harness outrank a
# marker, so a marker case run under whichever real harness launched this suite
# (a Claude or Codex parent, say) would assert that parent's verdict instead of
# the marker's. Marker cases therefore run with the ancestry walk blinded by a
# fake ps that reports a bash chain ending at pid 1; the ancestry cases below
# use real processes, and the precedence case pins what the blinding hides.
BLIND_PS=$(fm_fakebin "$TMP_ROOT/blind-ps")
cat > "$BLIND_PS/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'ppid='*) printf '%s\n' 1 ;;
  *) printf '%s\n' bash ;;
esac
SH
chmod +x "$BLIND_PS/ps"

marker_verdict() {  # [env args...] -> the verdict from markers alone
  env "$@" PATH="$BLIND_PS:$PATH" "$HARNESS"
}

test_agy_marker_outranks_inherited_claudecode() {
  local out
  # The blinding must leave no ancestor to answer, or every marker case below
  # could be passing on an ancestry verdict.
  out=$(marker_verdict)
  [ "$out" = unknown ] || fail "the blinded ancestry walk must leave no verdict, got '$out'"
  # agy was not verified to scrub an inherited CLAUDECODE, so the adapter is
  # ordered before it. Pin that order rather than the hope that agy clears it.
  out=$(marker_verdict CLAUDECODE=1 JETSKI_APP_DATA_DIR=antigravity-cli)
  [ "$out" = agy ] || fail "CLAUDECODE + agy marker must detect agy, got '$out'"
  # Drive the signals apart so the case above cannot go quietly vacuous: each
  # marker alone must still produce its own verdict.
  out=$(marker_verdict JETSKI_APP_DATA_DIR=antigravity-cli)
  [ "$out" = agy ] || fail "the agy marker alone must detect agy, got '$out'"
  out=$(marker_verdict CLAUDECODE=1)
  [ "$out" = claude ] || fail "CLAUDECODE alone must still detect claude, got '$out'"
  # Cursor's marker still outranks agy's, preserving the documented order.
  out=$(marker_verdict CURSOR_AGENT=1 JETSKI_APP_DATA_DIR=antigravity-cli)
  [ "$out" = cursor ] || fail "CURSOR_AGENT must still outrank the agy marker, got '$out'"
  pass "fm-harness.sh: agy's marker outranks an inherited CLAUDECODE"
}

test_agy_marker_is_the_cli_not_the_ide() {
  local out
  # The Antigravity IDE keeps its state under ~/.gemini/antigravity, so its app
  # data dir is `antigravity`. Only the CLI's exact value is agy.
  out=$(marker_verdict JETSKI_APP_DATA_DIR=antigravity)
  [ "$out" != agy ] \
    || fail "the IDE's app data dir must not be read as the agy CLI, got '$out'"
  out=$(marker_verdict JETSKI_APP_DATA_DIR=antigravity-cli-other)
  [ "$out" != agy ] \
    || fail "a non-exact app data dir must not claim agy, got '$out'"
  pass "fm-harness.sh: only the CLI's exact app data dir claims agy"
}

test_agy_does_not_claim_the_gemini_identity() {
  local out
  # agy shares the ~/.gemini config root with Google's separate gemini adapter
  # but does NOT set GEMINI_CLI (verified in an agy tool process environment).
  # A GEMINI_CLI session must stay gemini, and an agy session must not be
  # reported as gemini.
  out=$(marker_verdict GEMINI_CLI=1)
  [ "$out" = gemini ] || fail "GEMINI_CLI must still detect gemini, got '$out'"
  out=$(marker_verdict JETSKI_APP_DATA_DIR=antigravity-cli)
  [ "$out" = agy ] || fail "an agy session must not be read as gemini, got '$out'"
  pass "fm-harness.sh: agy and the Gemini CLI keep separate identities"
}

# The verdict has to come from a live process tree rather than a string this
# test also wrote, so each ancestry case runs a real executable under the name
# being checked. It must be a locally BUILT executable: copying a system binary
# under a new name is SIGKILLed by macOS code signing (exit 137), and a symlink
# does not work either because `ps -o comm=` resolves it back to the real
# binary's name. A tiny C launcher that runs the probe as a CHILD keeps the
# tested name in the ancestry the walk reads. Returns 2 when cc is absent.
build_named_probe() {  # <dir> <name> -> path
  command -v cc >/dev/null 2>&1 || return 2
  mkdir -p "$1"
  [ -f "$1/run.c" ] || cat > "$1/run.c" <<'C'
#include <stdlib.h>
int main(int argc, char **argv) { if (argc < 2) return 1; return system(argv[1]) == 0 ? 0 : 1; }
C
  cc -o "$1/$2" "$1/run.c" 2>/dev/null || return 1
  printf '%s\n' "$1/$2"
}

# Every foreign marker is dropped from an ancestry probe, so a case asserts the
# markers it names and nothing inherited.
ANCESTRY_CLEAN="env -u JETSKI_APP_DATA_DIR -u CLAUDECODE -u CURSOR_AGENT"
ANCESTRY_CLEAN="$ANCESTRY_CLEAN -u CURSOR_INVOKED_AS -u GEMINI_CLI -u PI_CODING_AGENT"
ANCESTRY_CLEAN="$ANCESTRY_CLEAN -u GROK_AGENT -u ATLASSIAN_AGENT_TYPE"
ANCESTRY_CLEAN="$ANCESTRY_CLEAN -u FM_DEVIN_HARNESS -u FM_OMP_HARNESS"

test_agy_marker_yields_to_a_different_native_ancestor() {
  local dir="$TMP_ROOT/precedence" codex agy out rc
  # A marker names a harness, but a structural ancestor of a DIFFERENT harness
  # owns the process tree and wins: this is what a retained agy marker under a
  # native Codex parent must resolve to, and why the marker cases above blind
  # the walk. The symmetric case keeps an inherited CLAUDECODE from renaming a
  # real agy worker.
  rc=0
  codex=$(build_named_probe "$dir" codex) || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'skip - fm-harness.sh: agy precedence needs cc to build a named process\n'
    return 0
  fi
  [ "$rc" -eq 0 ] || fail "could not build the codex ancestry probe"
  agy=$(build_named_probe "$dir" agy) || fail "could not build the agy ancestry probe"
  out=$("$codex" "$ANCESTRY_CLEAN JETSKI_APP_DATA_DIR=antigravity-cli $HARNESS" | tr -d '\n')
  [ "$out" = codex ] \
    || fail "a native codex ancestor must outrank a retained agy marker, got '$out'"
  out=$("$agy" "$ANCESTRY_CLEAN CLAUDECODE=1 $HARNESS" | tr -d '\n')
  [ "$out" = agy ] \
    || fail "a native agy ancestor must outrank an inherited CLAUDECODE, got '$out'"
  # Drive the layers apart: the same markers with the walk blinded still name
  # their own harness, so the verdicts above are ancestry's, not the markers'.
  out=$(marker_verdict JETSKI_APP_DATA_DIR=antigravity-cli)
  [ "$out" = agy ] || fail "the agy marker alone must detect agy, got '$out'"
  out=$(marker_verdict CLAUDECODE=1)
  [ "$out" = claude ] || fail "CLAUDECODE alone must detect claude, got '$out'"
  pass "fm-harness.sh: a different native ancestor outranks the agy marker, and agy's outranks a foreign one"
}

test_agy_ancestry_matches_only_the_exact_command_name() {
  local dir="$TMP_ROOT/ancestry" out probe bin rc
  rc=0
  bin=$(build_named_probe "$dir" agy) || rc=$?
  if [ "$rc" -eq 2 ]; then
    printf 'skip - fm-harness.sh: agy ancestry needs cc to build a named process\n'
    return 0
  fi
  [ "$rc" -eq 0 ] || fail "could not build the agy ancestry probe"
  # Every marker is dropped, so each verdict below is the ancestry walk's.
  probe="$ANCESTRY_CLEAN $HARNESS"

  out=$("$bin" "$probe" | tr -d '\n')
  [ "$out" = agy ] || fail "an exact agy ancestor must detect agy, got '$out'"

  # Anchored, never *agy*: both of these would match a careless glob. They must
  # not merely fail to say agy - they must fall THROUGH to whatever really
  # launched this suite, which is what proves the arm did not fire.
  bin=$(build_named_probe "$dir" legacy) \
    || fail "could not build the legacy ancestry probe"
  out=$("$bin" "$probe" | tr -d '\n')
  [ "$out" != agy ] || fail "a 'legacy' command must not be misread as agy"
  bin=$(build_named_probe "$dir" agyrate) \
    || fail "could not build the agyrate ancestry probe"
  out=$("$bin" "$probe" | tr -d '\n')
  [ "$out" != agy ] || fail "an 'agyrate' command must not be misread as agy"
  pass "fm-harness.sh: agy ancestry is anchored to the exact command name"
}

test_agy_tmux_names_the_native_binary_an_agent() {
  local got
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source tmux || fail "fm_backend_source tmux failed"
  got=$(fm_agent_process_classify_name agy)
  [ "$got" = agent ] || fail "tmux liveness must read the agy binary as an agent, got '$got'"
  got=$(fm_agent_process_classify_name magyk)
  [ "$got" = other ] || fail "tmux liveness must not read magyk as an agent, got '$got'"
  got=$(fm_agent_process_classify_name bash)
  [ "$got" = shell ] || fail "tmux liveness must still read bash as a shell, got '$got'"
  pass "bin/fm-agent-process-lib.sh: agy is an agent, fragments are not"
}

# Canned `pane process-info` bodies for the herdr fixtures. The shared
# exit-detection contract proves a registered agent at process level before
# trusting it (bin/backends/herdr.sh fm_backend_herdr_pane_process_state), so
# every registered-status fixture pairs its `agent get` body with a process
# view. The agy-shaped body names the foreground process exactly `agy`, which
# is the same identity surface the tmux liveness probe and the ancestry
# detector use - no real agy process is needed because the foreground branch
# answers before the descendant walk touches the process table.
agy_herdr_process_info_body() {  # <shell-pid> <foreground-name> -> JSON
  printf '%s\n' "{\"result\":{\"type\":\"pane_process_info\",\"process_info\":{\"pane_id\":\"w9:p1\",\"shell_pid\":$1,\"foreground_processes\":[{\"pid\":$(( $1 + 1 )),\"name\":\"$2\",\"argv\":[\"$2\",\"--prompt-interactive\"],\"argv0\":\"$2\",\"cmdline\":\"$2 --prompt-interactive\"}]}}}"
}

agy_herdr_agent_state() {  # <fixture-dir> -> verdict; logs every CLI call
  local dir=$1
  : > "$dir/calls.log"
  AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_PROC="$dir/process-info.json" \
    AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$AGY_FIX_LOG"
      case "$*" in
        *"agent get"*) cat "$AGY_FIX_RESP" ;;
        *"pane process-info"*) cat "$AGY_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_pane_agent_state testsession w9:p1' "$ROOT" 2>&1
}

test_herdr_done_with_live_registry_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-done"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"done","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  agy_herdr_process_info_body 424242 agy > "$dir/process-info.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered done status with an agy process view must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    || fail "the shared contract proves a registered agent at process level; the verdict trusted the registration alone"
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_PROC="$dir/process-info.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"agent get"*) cat "$AGY_FIX_RESP" ;;
        *"pane process-info"*) cat "$AGY_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = refused ] || fail "a live pane must refuse husk replacement, got '$out'"
  pass "herdr exit detection: done with a live registry and an agy process view stays live and refuses replacement"
}

test_herdr_registered_status_over_a_shell_only_pane_is_stale_not_live() {
  local dir out shell_pid
  dir="$TMP_ROOT/herdr-stale"; mkdir -p "$dir"
  # The descendant walk reads the REAL process table, so the canned pane shell
  # must be a process this test owns and can prove alive: a short-lived sleep.
  sleep 30 & shell_pid=$!
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"done","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  agy_herdr_process_info_body "$shell_pid" bash > "$dir/process-info.json"
  out=$(agy_herdr_agent_state "$dir")
  kill "$shell_pid" 2>/dev/null || true
  [ "$out" = stale-agent ] || fail "a registered status over a proven shell-only pane must read stale-agent, got '$out'"
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_PROC="$dir/process-info.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in
        *"agent get"*) cat "$AGY_FIX_RESP" ;;
        *"pane process-info"*) cat "$AGY_FIX_PROC" ;;
        *) exit 0 ;;
      esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = refused ] || fail "a stale registration must still refuse husk replacement, got '$out'"
  pass "herdr exit detection: a registered status over a shell-only pane is stale-agent and still refuses closing"
}

test_herdr_shell_first_with_live_registry_stays_live() {
  local dir out
  dir="$TMP_ROOT/herdr-idle"; mkdir -p "$dir"
  printf '%s\n' '{"result":{"agent":{"agent":"agy","agent_status":"idle","pane_id":"w9:p1"}}}' > "$dir/agent-get.json"
  # The pane shell is present in the process view too (shell_pid), but the
  # foreground names agy: the verified harness identity outranks shell-first
  # ranking, and the shared contract's process proof is satisfied.
  agy_herdr_process_info_body 424242 agy > "$dir/process-info.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = live ] || fail "a registered idle status with an agy foreground must stay live, got '$out'"
  grep -q "process-info" "$dir/calls.log" \
    || fail "the shared contract proves a registered agent at process level; the verdict trusted the registration alone"
  pass "herdr exit detection: a registered pane with an agy foreground stays live however its shell ranks"
}

test_herdr_lone_unregistered_pane_is_agent_free() {
  local dir out
  dir="$TMP_ROOT/herdr-gone"; mkdir -p "$dir"
  printf '%s\n' '{"error":{"code":"agent_not_found","message":"agent target w9:p1 not found"}}' > "$dir/agent-get.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = no-agent ] || fail "an unregistered pane must read no-agent, got '$out'"
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      case "$*" in *"agent get"*) cat "$AGY_FIX_RESP" ;; *) exit 0 ;; esac
    }
    fm_backend_herdr_tab_is_husk testsession w9:p1 && printf husk || printf refused' "$ROOT" 2>&1)
  [ "$out" = husk ] || fail "an agent-free pane must allow husk replacement, got '$out'"
  pass "herdr exit detection: only a positively unregistered pane is agent-free"
}

test_herdr_malformed_and_failed_reads_stay_unknown() {
  local dir out
  dir="$TMP_ROOT/herdr-malformed"; mkdir -p "$dir"
  printf '%s\n' '{not json at all' > "$dir/agent-get.json"
  out=$(agy_herdr_agent_state "$dir")
  [ "$out" = unknown ] || fail "a malformed registry response must read unknown, got '$out'"
  dir="$TMP_ROOT/herdr-failed"; mkdir -p "$dir"
  printf '%s\n' '{"result":{}}' > "$dir/agent-get.json"
  export AGY_FIX_FAIL=1
  out=$(AGY_FIX_RESP="$dir/agent-get.json" AGY_FIX_LOG="$dir/calls.log" bash -c '
    . "$0/bin/backends/herdr.sh"
    fm_backend_herdr_pane_presence_state() { printf "present"; }
    fm_backend_herdr_cli() {
      printf "%s\n" "$*" >> "$AGY_FIX_LOG"
      case "$*" in *"agent get"*) [ "${AGY_FIX_FAIL:-0}" = 1 ] && exit 3; cat "$AGY_FIX_RESP" ;; *) exit 0 ;; esac
    }
    fm_backend_herdr_pane_agent_state testsession w9:p1' "$ROOT" 2>&1)
  unset AGY_FIX_FAIL
  [ "$out" = unknown ] || fail "a failed registry query must read unknown, got '$out'"
  pass "herdr exit detection: malformed and failed reads stay unknown"
}

# --- spawn scaffolding ------------------------------------------------------

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
  # The relaunch agent-state classifier reads the pane's foreground command;
  # a shell name is the positively agent-free answer it requires.
  *"#{pane_current_command}"*)
    if [ -s "$FM_FAKE_LAUNCH_LOG.command" ]; then cat "$FM_FAKE_LAUNCH_LOG.command"; else printf '%s\n' "${FM_FAKE_PANE_COMMAND:-bash}"; fi
    exit 0 ;;
  # A relaunch waits for the adopted pane's shell to hold a steady prompt row.
  *"#{cursor_y}"*) printf '0\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf '$ \n'; exit 0 ;;
  new-window)
    prev=
    for arg in "$@"; do
      [ "$prev" != -n ] || printf '%s\n' "$arg" > "$FM_FAKE_LAUNCH_LOG.window"
      prev=$arg
    done
    exit 0
    ;;
  list-windows)
    # Presence is the session's exact window inventory: the launched window
    # stays listed until a kill really closes it, which is how spawn confirms
    # closure.
    if [ -s "$FM_FAKE_LAUNCH_LOG.window" ] && [ ! -e "$FM_FAKE_LAUNCH_LOG.closed" ]; then
      cat "$FM_FAKE_LAUNCH_LOG.window"
    fi
    exit 0
    ;;
  has-session|new-session) exit 0 ;;
  kill-window)
    printf 'kill-window %s\n' "$*" >> "$FM_FAKE_LAUNCH_LOG.kills"
    # FM_FAKE_KILL_FAILS models a kill that leaves the window running.
    [ "${FM_FAKE_KILL_FAILS:-0}" = 1 ] || : > "$FM_FAKE_LAUNCH_LOG.closed"
    exit 0
    ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        # A spawn types a short line sourcing its staged launch file; log the
        # staged command itself so assertions read what the pane runs.
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || arg=$(cat "$staged") ;;
        esac
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        case "$arg" in
          *' claude '*) printf 'claude\n' > "$FM_FAKE_LAUNCH_LOG.pending-command" ;;
          *.agy-hooks*) printf 'agy\n' > "$FM_FAKE_LAUNCH_LOG.pending-command" ;;
        esac
        case "$arg" in
          *.agy-hooks*)
            printf '%s\n' "$arg" | grep -o "[^' ]*\.agy-hooks" | head -n 1 \
              > "$FM_FAKE_LAUNCH_LOG.agy-hooks"
            ;;
        esac
        exit 0
      fi
      prev=$arg
    done
    if [ "${*: -1}" = Enter ] && [ -f "$FM_FAKE_LAUNCH_LOG.pending-command" ]; then
      mv "$FM_FAKE_LAUNCH_LOG.pending-command" "$FM_FAKE_LAUNCH_LOG.command"
    fi
    # Stand-in for agy starting its brief: the Enter that submits the launch
    # line runs every installed worker PreInvocation hook in array order with
    # the payload agy sends, unless the case models a launch that never
    # reaches the model. The bypass layer's armed heartbeat rides the same
    # array behind the busy hook.
    if [ "${*: -1}" = Enter ] && [ "${FM_FAKE_AGY_START:-1}" = 1 ] \
       && [ -s "$FM_FAKE_LAUNCH_LOG.agy-hooks" ]; then
      hooks="$(cat "$FM_FAKE_LAUNCH_LOG.agy-hooks")/.agents/hooks.json"
      wt=$(cd "$FM_FAKE_PANE_PATH" 2>/dev/null && pwd -P) || exit 0
      jq -r '."firstmate-worker".PreInvocation[]?.command // empty' "$hooks" 2>/dev/null \
        | while IFS= read -r cmd; do
            [ -n "$cmd" ] || continue
            # FM_FAKE_AGY_SKIP_ADAPTER models a permission-adapter entry agy
            # silently dropped: the busy hook still reports, but the armed
            # line never reaches the observer log.
            case "$cmd" in
              *fm-agy-permission-policy*)
                [ "${FM_FAKE_AGY_SKIP_ADAPTER:-0}" = 1 ] && continue ;;
            esac
            jq -n --arg wt "$wt" '{conversationId:"fake-conversation",workspacePaths:[$wt]}' \
              | bash -c "$cmd"
          done
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  # A stand-in `agy` on PATH: the spawn resolves the executable to an absolute
  # path before launching, and refuses when none exists, so the resolver needs
  # something executable to find. Only its `models` catalog is ever run, shaped
  # like agy 1.2.11's: suffixed ids, a model with no medium level, and one
  # unsuffixed id. FM_FAKE_AGY_MODELS_FAIL and _HANG model an unreachable and a
  # stalled listing; the stall outlasts AGY_MODEL_HANG_LIMIT by far, so only
  # the probe's own bound can end it within that limit.
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = models ]; then
  [ "${FM_FAKE_AGY_MODELS_FAIL:-0}" = 1 ] && exit 3
  if [ "${FM_FAKE_AGY_MODELS_HANG:-0}" = 1 ]; then cat > /dev/null; sleep 300; exit 0; fi
  printf 'gemini-3.8-flash-high\tGemini 3.8 Flash (High)\n'
  printf 'gemini-3.8-flash-medium\tGemini 3.8 Flash (Medium)\n'
  printf 'gemini-3.8-flash-low\tGemini 3.8 Flash (Low)\n'
  printf 'gemini-3.1-pro-high\tGemini 3.1 Pro (High)\n'
  printf 'gemini-3.1-pro-low\tGemini 3.1 Pro (Low)\n'
  printf 'claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)\n'
fi
exit 0
SH
  chmod +x "$fakebin/agy"
  fm_fake_exit0 "$fakebin" gh-axi gh
  fm_fake_treehouse_lease "$fakebin"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise agy dispatch.

## Firstmate spec
Verify the agy harness behavior under test.
EOF
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_agy_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" agy "$@" 2>&1
}

# --- approvals --------------------------------------------------------------

test_agy_auto_uses_accept_edits_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case auto)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'auto\n' > "$home/config/crew-permissions"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--mode accept-edits'*) ;;
    *) fail "auto must launch agy with --mode accept-edits, got: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "auto must never reach agy's blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: agy auto selects accept-edits, never the approval bypass"
}

test_agy_manual_reviews_everything_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case manual)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'manual\n' > "$home/config/crew-permissions"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *--mode*) fail "manual must leave agy in its default review mode: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "manual must never reach agy's blanket approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: agy manual keeps every action under review"
}

test_agy_absent_setting_defaults_to_accept_edits() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case absent)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # No config/crew-permissions at all: the documented default is auto, matching
  # claude and codex, so the file's absence must not silently disable approvals
  # OR silently reach the bypass.
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--mode accept-edits'*) ;;
    *) fail "an absent setting must default to accept-edits, got: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "an absent setting must never reach the approval bypass: $launch" ;;
  esac
  pass "fm-spawn.sh: an absent permission setting defaults agy to accept-edits"
}

test_agy_invalid_setting_refuses_without_bypass() {
  local fields case_dir home proj wt fakebin id out setting
  # Every non-{auto,manual} shape must refuse: an unknown word, and an empty
  # file, which is the one a truncated write leaves behind.
  for setting in wide-open ''; do
    fields=$(make_spawn_case "invalid-${setting:-empty}")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    printf '%s' "$setting" > "$home/config/crew-permissions"
    out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) && \
      fail "an invalid permission setting ('$setting') must refuse the agy launch"
    case "$out" in
      *'invalid config/crew-permissions'*) ;;
      *) fail "the refusal must name config/crew-permissions, got: $out" ;;
    esac
    [ ! -s "$home/launch.log" ] \
      || fail "a refused agy launch must not reach the pane: $(cat "$home/launch.log")"
  done
  pass "fm-spawn.sh: an invalid permission setting refuses the agy launch"
}

# --- the mandatory worktree grant -------------------------------------------

test_agy_launch_grants_the_task_worktree() {
  local fields case_dir home proj wt fakebin id launch wt_real state_real brief_real
  fields=$(make_spawn_case adddir)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  # Without the worktree grant agy writes into its own scratch directory and
  # reports success, so its absence is a silent no-op rather than a visible
  # failure. fm_test_tmproot already hands back a resolved path, so the three
  # assertions here would pass with or without resolution: the resolution rule
  # itself is pinned by the symlink case below, which is where a real
  # divergence is constructed.
  wt_real=$(cd "$wt" && pwd -P)
  state_real=$(cd "$home/state" && pwd -P)
  brief_real=$(cd "$home/data/$id" && pwd -P)
  case "$launch" in
    *"--add-dir '$wt_real'"*) ;;
    *) fail "the agy launch must grant the resolved task worktree, got: $launch" ;;
  esac
  case "$launch" in
    *"--add-dir '$state_real'"*) ;;
    *) fail "the agy launch must grant this home's resolved state directory, got: $launch" ;;
  esac
  case "$launch" in
    *"--add-dir '$brief_real'"*) ;;
    *) fail "the agy launch must grant the brief's resolved directory, got: $launch" ;;
  esac
  # -i keeps the interactive session after the opening prompt; -p would run one
  # headless turn and exit, leaving no pane to supervise or steer.
  case "$launch" in
    *' -i '*) ;;
    *) fail "the agy launch must use -i to keep the session, got: $launch" ;;
  esac
  pass "fm-spawn.sh: an agy launch grants the worktree, state, and brief directories"
}

test_agy_grants_resolve_a_symlinked_worktree() {
  local fields case_dir home proj wt fakebin id launch link wt_real
  fields=$(make_spawn_case adddir-symlink)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  # The real regression: bin/fm-spawn.sh records the pane's RAW path as the
  # worktree, so a pane reached through a symlink yields an unresolved WT. agy
  # resolves a path before testing it against the granted workspace, so granting
  # the unresolved form made agy treat a write inside its own worktree as
  # non-workspace access and park on "Allow creation of this file? Reason:
  # outside workspace" (verified on agy 1.2.0). The two paths must genuinely
  # differ, or this case proves nothing.
  link="$case_dir/wt-link"
  ln -s "$wt" "$link"
  wt_real=$(cd "$wt" && pwd -P)
  [ "$link" != "$wt_real" ] \
    || fail "the symlink case needs a path that differs from the resolved worktree"
  run_agy_spawn "$home" "$proj" "$link" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *"--add-dir '$wt_real'"*) ;;
    *) fail "a symlinked worktree must be granted resolved, got: $launch" ;;
  esac
  case "$launch" in
    *"--add-dir '$link'"*)
      fail "the unresolved symlink path must never be the grant: $launch" ;;
  esac
  pass "fm-spawn.sh: agy grants a symlinked worktree by its resolved path"
}

# --- effort -----------------------------------------------------------------

test_agy_effort_caps_at_high() {
  local fields case_dir home proj wt fakebin id launch level
  for level in xhigh max; do
    fields=$(make_spawn_case "effort-$level")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model gemini-3.8-flash --effort "$level" >/dev/null
    launch=$(cat "$home/launch.log")
    # agy refuses anything above high, so the intent is capped rather than
    # dropped: an omitted flag would silently leave agy on its own default.
    case "$launch" in
      *"--effort 'high'"*) ;;
      *) fail "$level must cap onto agy's high, got: $launch" ;;
    esac
    case "$launch" in
      *"--effort '$level'"*) fail "$level must never reach agy verbatim: $launch" ;;
    esac
  done
  pass "fm-spawn.sh: agy caps xhigh and max onto its supported high"
}

test_agy_effort_passes_supported_levels_through() {
  local fields case_dir home proj wt fakebin id launch level
  for level in low medium high; do
    fields=$(make_spawn_case "effort-pass-$level")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model gemini-3.8-flash --effort "$level" >/dev/null
    launch=$(cat "$home/launch.log")
    case "$launch" in
      *"--effort '$level'"*) ;;
      *) fail "$level must pass through to agy, got: $launch" ;;
    esac
  done
  pass "fm-spawn.sh: agy's supported effort levels pass through unchanged"
}

test_agy_suffixed_model_id_suppresses_the_effort_flag() {
  local fields case_dir home proj wt fakebin id launch model
  # `--model gemini-3.8-flash-high --effort low` is a launch-refusing conflict
  # on agy 1.2.0, so a model id that already carries a level must win alone.
  for model in gemini-3.8-flash-high gemini-3.8-flash-medium gemini-3.8-flash-low; do
    fields=$(make_spawn_case "model-${model##*-}")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model "$model" --effort low >/dev/null
    launch=$(cat "$home/launch.log")
    case "$launch" in
      *"--model '$model'"*) ;;
      *) fail "the selected model id must reach agy, got: $launch" ;;
    esac
    case "$launch" in
      *--effort*) fail "a suffixed model id must suppress --effort: $launch" ;;
    esac
  done
  # Divergence: the unsuffixed base id must still compose with --effort, or the
  # cases above would pass for a rule that simply never emits the flag.
  fields=$(make_spawn_case model-base)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
    --model gemini-3.8-flash --effort low >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *"--effort 'low'"*) ;;
    *) fail "an unsuffixed model id must still carry --effort, got: $launch" ;;
  esac
  pass "fm-spawn.sh: agy emits a suffixed model id or --effort, never both"
}

# --- model catalog ----------------------------------------------------------

# The hung-listing cases time a whole spawn, whose own setup and launch cost
# varies by host, so the wall-clock limit is generous: it separates a probe the
# bound cut off from one left to run the stalled listing's full 300 seconds.
# The timeout notice, which only the bound's exit status produces, is what
# proves the deadline fired.
AGY_MODEL_HANG_LIMIT=150

# One scout spawn per model case; prints "<exit>|<home>" and leaves the
# spawn's output in <home>/spawn.out.
agy_catalog_spawn() {  # <case-name> [spawn args...]
  local name=$1 fields case_dir home proj wt fakebin id rc=0
  shift
  fields=$(make_spawn_case "$name")
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout "$@" \
    > "$home/spawn.out" || rc=$?
  printf '%s|%s\n' "$rc" "$home"
}

test_agy_catalog_accepts_listed_ids_and_base_aliases() {
  local spec model effort result home out
  # A listed id launches as is, and an unsuffixed base launches when the
  # catalog lists <base>-<level> for the level the launch passes: xhigh caps
  # onto high, so gemini-3.8-flash-high is what makes that case supported.
  for spec in gemini-3.8-flash-high:low claude-sonnet-4-6: \
    gemini-3.8-flash:medium gemini-3.8-flash:xhigh gemini-3.1-pro:low; do
    model=${spec%%:*}
    effort=${spec#*:}
    if [ -n "$effort" ]; then
      result=$(agy_catalog_spawn "catalog-ok-$model-$effort" --model "$model" --effort "$effort")
    else
      result=$(agy_catalog_spawn "catalog-ok-$model" --model "$model")
    fi
    home=${result#*|}
    out=$(cat "$home/spawn.out")
    case "$out" in
      *"agy model '"* | *"'agy models'"*)
        fail "a supported agy model ($spec) must pass the catalog check silently, got: $out" ;;
    esac
    grep -Fq -- "--model '$model'" "$home/launch.log" 2>/dev/null \
      || fail "a supported agy model ($spec) must reach the launch, got: $out"
  done
  pass "fm-spawn.sh: agy launches listed ids and base ids whose level the catalog lists"
}

test_agy_catalog_refuses_unsupported_models_before_launch() {
  local spec model effort result rc home out want
  # Each shape is one agy 1.2.11 itself refuses: an id it never lists, a base
  # with no --effort, a base with a level the catalog lacks for it, and a
  # suffixed id naming that missing level.
  for spec in \
    "gemini-9.9-nonexistent::not listed by 'agy models'" \
    "gemini-3.8-flash::listed only as effort variants (high,medium,low), and this launch would pass --effort 'none'" \
    "gemini-3.1-pro:medium:listed only as effort variants (high,low), and this launch would pass --effort 'medium'" \
    "gemini-3.1-pro-medium:low:not listed by 'agy models'"; do
    model=${spec%%:*}
    effort=${spec#*:}
    want=${effort#*:}
    effort=${effort%%:*}
    if [ -n "$effort" ]; then
      result=$(agy_catalog_spawn "catalog-bad-$model-$effort" --model "$model" --effort "$effort")
    else
      result=$(agy_catalog_spawn "catalog-bad-$model" --model "$model")
    fi
    rc=${result%%|*}
    home=${result#*|}
    out=$(cat "$home/spawn.out")
    [ "$rc" -ne 0 ] || fail "an unsupported agy model ($model${effort:+ --effort $effort}) must refuse the spawn"
    assert_contains "$out" "$want" "the refusal for $model must name its concrete reason"
    [ ! -s "$home/launch.log" ] && [ ! -e "$home/launch.log.window" ] \
      || fail "a refused agy model ($model) must not create an endpoint or launch"
  done
  pass "fm-spawn.sh: an agy model the catalog cannot support refuses before any endpoint"
}

test_agy_unreachable_listing_launches_unvalidated() {
  local result rc home out
  result=$(FM_FAKE_AGY_MODELS_FAIL=1 agy_catalog_spawn catalog-unreachable \
    --model gemini-9.9-nonexistent)
  rc=${result%%|*}
  home=${result#*|}
  out=$(cat "$home/spawn.out")
  expect_code 0 "$rc" "an unreachable model listing must not block the spawn: $out"
  assert_contains "$out" "listing is unreachable (exit 3)" \
    "an unreachable listing launched without its notice"
  grep -Fq -- "--model 'gemini-9.9-nonexistent'" "$home/launch.log" \
    || fail "an unreachable listing must launch the requested model unvalidated"
  pass "fm-spawn.sh: an unreachable agy listing establishes nothing and launches"
}

test_agy_hung_listing_is_cut_off_and_launches() {
  local result rc home out started elapsed
  started=$(date +%s)
  result=$(FM_FAKE_AGY_MODELS_HANG=1 FM_AGY_MODELS_TIMEOUT=1 \
    agy_catalog_spawn catalog-hung --model gemini-3.8-flash-low)
  elapsed=$(( $(date +%s) - started ))
  rc=${result%%|*}
  home=${result#*|}
  out=$(cat "$home/spawn.out")
  expect_code 0 "$rc" "a hung model listing must not block the spawn: $out"
  [ "$elapsed" -lt "$AGY_MODEL_HANG_LIMIT" ] \
    || fail "the model probe was not cut off by its bound (spawn took ${elapsed}s)"
  assert_contains "$out" "did not answer within 1s" "a hung listing launched without its timeout notice"
  grep -Fq -- "--model 'gemini-3.8-flash-low'" "$home/launch.log" \
    || fail "a hung listing dropped the requested model instead of launching it unvalidated"
  pass "fm-spawn.sh: a hung agy listing is cut off by the shared bound and launches unvalidated"
}

test_agy_invalid_model_timeout_is_clamped_to_the_default_bound() {
  local result rc home out started elapsed
  # Zero would disable the deadline outright; it must fall back to the default.
  started=$(date +%s)
  result=$(FM_FAKE_AGY_MODELS_HANG=1 FM_AGY_MODELS_TIMEOUT=0 \
    agy_catalog_spawn catalog-zero-bound --model gemini-3.8-flash-low)
  elapsed=$(( $(date +%s) - started ))
  rc=${result%%|*}
  home=${result#*|}
  out=$(cat "$home/spawn.out")
  expect_code 0 "$rc" "a hung listing with a zero bound must not block the spawn: $out"
  [ "$elapsed" -lt "$AGY_MODEL_HANG_LIMIT" ] \
    || fail "a zero model bound disabled the deadline (spawn took ${elapsed}s)"
  assert_contains "$out" "did not answer within 15s" \
    "a zero model bound was not clamped to the documented default"
  pass "fm-spawn.sh: an invalid FM_AGY_MODELS_TIMEOUT is clamped to the default bound"
}

# --- task kinds -------------------------------------------------------------

test_agy_secondmate_launch_is_supported() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case secondmate)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir" "$proj" "$wt"
  local sm="$case_dir/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data" "$sm/.agents"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter\n' > "$sm/data/charter.md"
  # A real secondmate home is a git checkout; the spawn installs its AI-trailer
  # strip hooks there (bin/fm-git-strip-ai-trailers.sh).
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_SKIP_SECONDMATE_INHERIT=1 FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$sm" agy --secondmate 2>&1) || fail "agy secondmate: $out"
  case "$out" in
    *'harness=agy kind=secondmate'*) ;;
    *) fail "secondmate launch did not complete: $out" ;;
  esac
  [ ! -e "$home/state/$id.agy-hooks" ] || fail "secondmate must use primary hooks, never worker hooks"
  pass "fm-spawn.sh: agy secondmate launches without worker wiring"
}

# --- start confirmation -----------------------------------------------------

test_agy_spawn_confirms_the_brief_started() {
  local fields case_dir home proj wt fakebin id out record
  fields=$(make_spawn_case started)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout) \
    || fail "agy spawn whose worker hook reported the brief failed: $out"
  case "$out" in
    *"spawned $id harness=agy kind=scout"*) ;;
    *) fail "a confirmed agy start did not report success: $out" ;;
  esac
  record=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_record_read "$2" "$3"' _ "$ROOT" "$home/state" "$id") \
    || fail "confirmed agy start left no valid busy record: $record"
  case "$record" in
    'busy agy-hook pre-invocation '*) ;;
    *) fail "spawn reported success without the worker hook's own record, got: $record" ;;
  esac
  [ -f "$home/state/$id.meta" ] || fail "a confirmed agy start did not keep its task record"
  [ ! -e "$home/launch.log.kills" ] || fail "a confirmed agy start closed its endpoint: $(cat "$home/launch.log.kills")"
  pass "fm-spawn.sh: agy spawn succeeds only after the worker hook reports the brief started"
}

test_agy_spawn_fails_and_closes_when_the_brief_never_starts() {
  local fields case_dir home proj wt fakebin id out status record
  fields=$(make_spawn_case never-started)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # The launch is typed and submitted, and spawn's own seed record is busy the
  # whole time, but agy never invokes the model (an auth prompt, a trust dialog,
  # a refused model id). The seed must not pass for a started brief.
  out=$(FM_FAKE_AGY_START=0 FM_AGY_READY_POLLS=4 FM_AGY_POLL_INTERVAL=0.1 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn reported success though its brief never started: $out"
  grep -Fq '.agy-hooks' "$home/launch.log" || fail "the case never delivered the agy launch: $out"
  case "$out" in
    *'agy did not report starting its brief'*) ;;
    *) fail "the refusal must say the brief never started, got: $out" ;;
  esac
  grep -Eq '^failed( \[at=[0-9]+\])?: agy did not report starting its brief' "$home/state/$id.status" \
    || fail "a never-started agy spawn did not record a failure: $(cat "$home/state/$id.status" 2>/dev/null)"
  grep -Fq "fm-$id" "$home/launch.log.kills" 2>/dev/null \
    || fail "a never-started agy spawn left its endpoint running: $(cat "$home/launch.log.kills" 2>/dev/null)"
  [ ! -e "$home/state/$id.meta" ] || fail "a never-started agy spawn kept its task record"
  [ ! -e "$home/state/$id.agy-hooks" ] || fail "a never-started agy spawn left its worker hooks installed"
  if record=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_record_read "$2" "$3"' _ "$ROOT" "$home/state" "$id"); then
    fail "a never-started agy spawn left a live busy record: $record"
  fi
  pass "fm-spawn.sh: agy spawn fails, records it, and closes the endpoint when the brief never starts"
}

test_agy_spawn_keeps_its_record_when_the_endpoint_will_not_close() {
  local fields case_dir home proj wt fakebin id out status record
  fields=$(make_spawn_case close-unconfirmed)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  # The brief never starts and the kill leaves the window in place, so the agy
  # process may still be running: its record, generation, and hooks must stay
  # for teardown rather than being rolled back underneath a live worker.
  out=$(FM_FAKE_AGY_START=0 FM_FAKE_KILL_FAILS=1 FM_AGY_READY_POLLS=4 \
    FM_AGY_CLOSE_POLLS=3 FM_AGY_POLL_INTERVAL=0.1 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn reported success though its brief never started: $out"
  grep -Fq "fm-$id" "$home/launch.log.kills" 2>/dev/null \
    || fail "the case never attempted to close the endpoint: $out"
  case "$out" in
    *'could not be confirmed; the agy worker may still be running'*) ;;
    *) fail "an unconfirmed close must be reported, got: $out" ;;
  esac
  grep -Eq '^failed( \[at=[0-9]+\])?: agy did not report starting its brief.*could not be confirmed closed' "$home/state/$id.status" \
    || fail "the failure record did not say the endpoint may still run: $(cat "$home/state/$id.status" 2>/dev/null)"
  [ -f "$home/state/$id.meta" ] || fail "an unconfirmed close rolled back the task record"
  record=$(bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_record_read "$2" "$3"' _ "$ROOT" "$home/state" "$id") \
    || fail "an unconfirmed close retired the busy generation: $record"
  [ -f "$home/state/$id.agy-hooks/.agents/hooks.json" ] || fail "an unconfirmed close retired the worker hooks"
  pass "fm-spawn.sh: an agy spawn whose endpoint cannot be confirmed closed keeps its record for teardown"
}

# --- agy bypass posture (--agy-bypass) ----------------------------------------

# A bypass-viable fakebin: agy answers --version with the live-verified
# release so the spawn's version gate passes.
make_bypass_fakebin() {  # <dir> -> fakebin with a version-printing agy
  local fakebin
  fakebin=$(make_spawn_fakebin "$1")
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --version) printf 'agy 1.2.5\n' ;; esac
exit 0
SH
  chmod +x "$fakebin/agy"
  printf '%s\n' "$fakebin"
}

test_agy_bypass_launch_installs_the_adapter_and_skips_permissions() {
  local fields case_dir home proj wt fakebin id out
  fields=$(make_spawn_case bypass-armed)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass) \
    || fail "an armed agy bypass spawn failed: $out"
  grep -Fq -- '--dangerously-skip-permissions' "$home/launch.log" \
    || fail "the bypass launch must carry --dangerously-skip-permissions: $(cat "$home/launch.log")"
  [ -f "$home/state/$id.agy-permission.json" ] \
    || fail "the bypass spawn must write the per-task policy file"
  [ "$(jq -r '[."firstmate-worker" | .. | objects | select(has("command")) | .command] | length' \
      "$home/state/$id.agy-hooks/.agents/hooks.json")" = 8 ] \
    || fail "the merged hooks must carry the adapter beside the observer: $(cat "$home/state/$id.agy-hooks/.agents/hooks.json")"
  jq -e 'select(.event == "armed") | .task' "$home/state/agy-permission-log.jsonl" >/dev/null 2>&1 \
    || fail "the adapter's armed line must reach the observer log: $(cat "$home/state/agy-permission-log.jsonl" 2>/dev/null)"
  grep -q '^agy_bypass=on$' "$home/state/$id.meta" \
    || fail "the bypass posture must be recorded in task metadata: $(cat "$home/state/$id.meta")"
  pass "fm-spawn.sh: --agy-bypass launches a policed bypass once the adapter is armed"
}

# agy_hook <policy> <event> <tool> <arg> [step]: drive the permission adapter
# with an agy-shaped payload scoped to the policy's own worktree, the way the
# installed worker hook does. Sets OUT.
agy_hook() {
  local policy=$1 event=$2 tool=$3 arg=$4 step=${5:-1} wt payload
  wt=$(jq -r .worktree "$policy")
  payload=$(jq -nc --arg t "$tool" --arg a "$arg" --argjson s "$step" --arg wt "$wt" \
    '{conversationId:"c1", stepIdx:$s, modelName:"m", workspacePaths:[$wt],
      toolCall:{name:$t, args:(if $t == "run_command" then {CommandLine:$a, Cwd:$wt}
                              else {AbsolutePath:$a, Content:"x"} end)}}')
  OUT=$(printf '%s' "$payload" | "$ROOT/bin/fm-agy-permission-policy.sh" "$event" "$policy" 2>/dev/null)
}

test_agy_bypass_ship_keeps_every_write_guard() {
  local fields case_dir home proj wt fakebin id out policy outside
  # The bypass gate covers ships as well as scouts.
  # On a read-only scout the write guards were belt-and-braces; on a ship they
  # are the only write restriction firstmate relies on for a bypassed worker.
  # So this drives the adapter through the policy file a REAL ship spawn just
  # wrote.
  fields=$(make_spawn_case bypass-ship)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode local-only --yolo off --agy-bypass) \
    || fail "a ship bypass spawn must launch: $out"
  grep -Fq -- '--dangerously-skip-permissions' "$home/launch.log" \
    || fail "the ship bypass launch must carry the bypass flag: $(cat "$home/launch.log")"
  policy="$home/state/$id.agy-permission.json"
  [ -f "$policy" ] || fail "a ship bypass spawn must write the per-task policy file"
  grep -q '^agy_bypass=on$' "$home/state/$id.meta" \
    || fail "a ship's bypass posture must be recorded: $(cat "$home/state/$id.meta")"
  grep -q '^agy_judge=agy:' "$home/state/$id.meta" \
    || fail "a ship's judge tier must be recorded: $(cat "$home/state/$id.meta")"
  # The armed canary protects a WRITING worker now, so the spawn above only
  # succeeded because the adapter's armed line for this generation landed.
  jq -e --arg t "$id" 'select(.task == $t and .event == "armed")' \
    "$home/state/agy-permission-log.jsonl" >/dev/null 2>&1 \
    || fail "the ship spawn's canary passed without an armed line: $(cat "$home/state/agy-permission-log.jsonl" 2>/dev/null)"

  # The refusal list speaks first, before any scope or judge consideration.
  agy_hook "$policy" pre-tool-use run_command "sudo ls"
  [ "$(printf '%s' "$OUT" | jq -r .decision 2>/dev/null)" = deny ] \
    || fail "a refused command must still deny on the ship path, got: $OUT"
  printf '%s' "$OUT" | jq -r .reason | grep -qF 'Blocked by firstmate policy' \
    || fail "the ship-path refusal must name the policy: $OUT"

  # A statically visible write outside every write root is refused outright,
  # not judged - there is no prompt behind the judge to correct a bad verdict.
  # The scratch roots cover all of /tmp, and this whole fixture lives there,
  # so /etc is the honest outside, exactly as the policy suite uses it.
  outside=/etc
  agy_hook "$policy" pre-tool-use write_to_file "$outside/fm-ship-escape.txt" 2
  printf '%s' "$OUT" | jq -r .reason 2>/dev/null | grep -qF 'outside the task write roots' \
    || fail "an out-of-root write must be refused on the ship path, got: $OUT"
  agy_hook "$policy" pre-tool-use run_command "echo x > $outside/fm-ship-escape2.txt" 3
  [ "$(printf '%s' "$OUT" | jq -r .decision 2>/dev/null)" = deny ] \
    || fail "an out-of-root exec write must be refused on the ship path, got: $OUT"

  # A write through a symlink lands on the symlink's target, so the target is
  # what the root check sees - the shared chain resolver, on the ship path.
  ln -s "$outside" "$wt/escape-link" || fail "could not create the escape symlink"
  agy_hook "$policy" pre-tool-use write_to_file "$wt/escape-link/fm-ship-through.txt" 4
  printf '%s' "$OUT" | jq -r .reason 2>/dev/null | grep -qF 'outside the task write roots' \
    || fail "a symlinked write must be resolved physically on the ship path, got: $OUT"

  # The fakebin agy answers nothing, so the judge produces no verdict: that
  # must deny and hold, never abstain into a run, now that the worker writes.
  agy_hook "$policy" pre-tool-use run_command "npm install" 5
  printf '%s' "$OUT" | jq -r .reason 2>/dev/null | grep -qF 'held for firstmate' \
    || fail "a judge failure must deny and hold on the ship path, got: $OUT"
  ls "${policy%.json}-pending"/*.pending >/dev/null 2>&1 \
    || fail "a held ship call must leave a pending marker for firstmate"
  grep -q 'needs-decision' "$home/state/$id.status" \
    || fail "a held ship call must wake firstmate: $(cat "$home/state/$id.status" 2>/dev/null)"

  # And a task-local write still abstains, so the guards did not simply deny
  # everything the ship tried to do.
  agy_hook "$policy" pre-tool-use write_to_file "$wt/in-scope.txt" 6
  [ -z "$OUT" ] || fail "a task-local ship write must still abstain, got: $OUT"
  pass "fm-spawn.sh: a ship under bypass keeps every refusal, write-root, symlink, and judge guard"
}

test_agy_bypass_records_and_prints_the_judge_tier() {
  local fields case_dir home proj wt fakebin id out policy
  fields=$(make_spawn_case bypass-judge-default)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass) \
    || fail "an armed agy bypass spawn failed: $out"
  policy="$home/state/$id.agy-permission.json"
  # With no flag the judge stays on this adapter's own tier, and says so.
  [ "$(jq -r .judge_tier "$policy")" = agy ] \
    || fail "the default judge tier must be recorded in the policy: $(cat "$policy")"
  [ "$(jq -r .judge_model "$policy")" = gemini-3.6-flash-low ] \
    || fail "the tier's own model must be recorded: $(cat "$policy")"
  [ -x "$(jq -r .judge_bin "$policy")" ] \
    || fail "the resolved judge executable must be recorded: $(cat "$policy")"
  grep -q '^agy_judge=agy:gemini-3.6-flash-low$' "$home/state/$id.meta" \
    || fail "the judge tier must ride the recorded posture: $(cat "$home/state/$id.meta")"
  case "$out" in
    *"agy bypass judge tier: agy model=gemini-3.6-flash-low"*) ;;
    *) fail "the spawn must name the judge tier before launching, got: $out" ;;
  esac
  case "$out" in
    *"judge=agy:gemini-3.6-flash-low"*) ;;
    *) fail "the spawned line must name the judge tier, got: $out" ;;
  esac
  pass "fm-spawn.sh: a bypass spawn records and prints the judge tier it armed"
}

test_agy_judge_selects_another_tier() {
  local fields case_dir home proj wt fakebin id out policy
  fields=$(make_spawn_case bypass-judge-select)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  fm_fake_exit0 "$fakebin" devin
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass \
    --agy-judge devin) || fail "selecting an installed judge tier failed: $out"
  policy="$home/state/$id.agy-permission.json"
  [ "$(jq -r .judge_tier "$policy")" = devin ] \
    || fail "the selected tier must be recorded: $(cat "$policy")"
  [ "$(jq -r .judge_model "$policy")" = swe-2-high ] \
    || fail "the selected tier's own default model must be recorded: $(cat "$policy")"
  [ "$(jq -r .judge_bin "$policy")" = "$fakebin/devin" ] \
    || fail "the selected tier's executable must be resolved at launch: $(cat "$policy")"
  grep -q '^agy_judge=devin:swe-2-high$' "$home/state/$id.meta" \
    || fail "the selected tier must ride the recorded posture: $(cat "$home/state/$id.meta")"
  case "$out" in
    *"agy bypass judge tier: devin model=swe-2-high"*) ;;
    *) fail "the spawn must name the selected tier before launching, got: $out" ;;
  esac

  # An explicit model rides the same flag.
  fields=$(make_spawn_case bypass-judge-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  fm_fake_exit0 "$fakebin" devin
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass \
    --agy-judge devin:swe-2-medium) || fail "selecting a tier and model failed: $out"
  [ "$(jq -r .judge_model "$home/state/$id.agy-permission.json")" = swe-2-medium ] \
    || fail "an explicit judge model must be recorded: $(cat "$home/state/$id.agy-permission.json")"
  pass "fm-spawn.sh: --agy-judge arms another tier and records its model"
}

test_agy_judge_refuses_rather_than_falling_back() {
  local fields case_dir home proj wt fakebin id out status sans
  # An unknown tier is a typo or an unbuilt judge; falling back would put the
  # worker on a judge nobody asked for.
  fields=$(make_spawn_case bypass-judge-unknown)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass \
    --agy-judge swe-9000)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown judge tier must refuse the spawn: $out"
  case "$out" in
    *"unknown judge tier 'swe-9000'"*) ;;
    *) fail "the refusal must name the unknown tier, got: $out" ;;
  esac
  ! grep -Fq -- '--dangerously-skip-permissions' "$home/launch.log" 2>/dev/null \
    || fail "a refused judge tier must never reach the launch: $(cat "$home/launch.log")"
  [ ! -e "$home/state/$id.agy-permission.json" ] \
    || fail "a refused judge tier must not leave a policy file"

  # A known tier whose judge is not installed refuses too, rather than arming
  # a layer whose every residue call would hold for firstmate. The PATH is
  # curated rather than inherited so the case still proves that on a machine
  # where the real judge IS installed.
  fields=$(make_spawn_case bypass-judge-missing)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  sans=$(fm_test_base_path_sans "$PATH" devin) \
    || fail 'could not build a PATH without the judge tier executable'
  out=$(PATH="$sans" run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --scout --agy-bypass --agy-judge devin)
  status=$?
  [ "$status" -ne 0 ] || fail "a judge tier with no executable must refuse the spawn: $out"
  case "$out" in
    *"which is not installed"*) ;;
    *) fail "the refusal must name the missing judge executable, got: $out" ;;
  esac
  [ ! -e "$home/state/$id.agy-permission.json" ] \
    || fail "a refused judge tier must not leave a policy file"

  # The flag selects the judge for the bypass layer; without that layer there
  # is no judge to select.
  fields=$(make_spawn_case bypass-judge-no-posture)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-judge devin)
  status=$?
  [ "$status" -ne 0 ] || fail "--agy-judge without --agy-bypass must refuse: $out"
  case "$out" in
    *"without that posture no judge is installed"*) ;;
    *) fail "the refusal must explain that no judge is installed, got: $out" ;;
  esac
  pass "fm-spawn.sh: --agy-judge refuses an unknown or uninstalled tier instead of falling back"
}

test_agy_bypass_refuses_an_unverified_version() {
  local fields case_dir home proj wt fakebin id out status
  fields=$(make_spawn_case bypass-version)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --version) printf 'agy 9.9.9\n' ;; esac
exit 0
SH
  chmod +x "$fakebin/agy"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "a bypass launch on an unverified agy must refuse: $out"
  case "$out" in
    *'outside the live-verified set'*) ;;
    *) fail "the refusal must name the unverified version, got: $out" ;;
  esac
  ! grep -Fq -- '--dangerously-skip-permissions' "$home/launch.log" 2>/dev/null \
    || fail "a refused bypass must never reach the launch: $(cat "$home/launch.log")"
  [ ! -e "$home/state/$id.agy-permission.json" ] \
    || fail "a refused bypass must not leave a policy file"
  pass "fm-spawn.sh: --agy-bypass refuses an agy version outside the live-verified set"
}

test_agy_bypass_refuses_a_project_hooks_file() {
  local fields case_dir home proj wt fakebin id out status
  fields=$(make_spawn_case bypass-hooks)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  # A real project hooks file is tracked upstream, so land it on the project's
  # default branch where the worktree's base refresh keeps it.
  mkdir -p "$proj/.agents"
  printf '{"firstmate-worker":{}}\n' > "$proj/.agents/hooks.json"
  git -C "$proj" add .agents/hooks.json >/dev/null 2>&1
  git -C "$proj" -c user.email=t@t -c user.name=t commit -qm hooks >/dev/null 2>&1 \
    || fail "the fixture's project hook file did not commit"
  git -C "$proj" push -q origin HEAD:main >/dev/null 2>&1 \
    || fail "the fixture's project hook file did not reach origin"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "a bypass launch with a project hooks.json must refuse: $out"
  case "$out" in
    *'worker hooks to be the only hooks in force'*) ;;
    *) fail "the refusal must name the project hook file, got: $out" ;;
  esac
  ! grep -Fq -- '--dangerously-skip-permissions' "$home/launch.log" 2>/dev/null \
    || fail "a refused bypass must never reach the launch"
  pass "fm-spawn.sh: --agy-bypass refuses a worktree that carries its own .agents/hooks.json"
}

test_agy_bypass_refuses_the_wrong_posture() {
  local fields case_dir home proj wt fakebin id out status
  # manual review is itself an explicit prompt posture; bypass cannot ride it.
  fields=$(make_spawn_case bypass-posture)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  printf 'manual\n' > "$home/config/crew-permissions"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "--agy-bypass under manual review must refuse: $out"
  case "$out" in
    *'conflicts with config/crew-permissions=manual'*) ;;
    *) fail "the manual refusal must name the conflict, got: $out" ;;
  esac
  # A secondmate spawn is never a bypass candidate.
  fields=$(make_spawn_case bypass-secondmate)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --secondmate --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "--agy-bypass on a secondmate must refuse: $out"
  case "$out" in
    *'not a worker this layer polices'*) ;;
    *) fail "the secondmate refusal must say why a secondmate is excluded, got: $out" ;;
  esac
  # A raw launch command installs no hooks, so bypass cannot ride it.
  fields=$(make_spawn_case bypass-raw)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 'agy --raw-thing' --mode local-only --yolo off --agy-bypass 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "--agy-bypass on a raw launch must refuse: $out"
  case "$out" in
    *'cannot ride a raw launch'*) ;;
    *) fail "the raw-launch refusal must name the constraint, got: $out" ;;
  esac
  pass "fm-spawn.sh: --agy-bypass refuses manual review, secondmates, and raw launches"
}

test_agy_bypass_canary_refuses_a_dead_adapter() {
  local fields case_dir home proj wt fakebin id out status
  fields=$(make_spawn_case bypass-canary)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  # The session starts - the busy hook reports - but the adapter's armed line
  # never reaches the log, so the bypassed session's denies cannot be trusted.
  out=$(FM_FAKE_AGY_SKIP_ADAPTER=1 FM_AGY_ARMED_POLLS=4 FM_AGY_POLL_INTERVAL=0.1 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "a bypass spawn whose adapter never arms must refuse: $out"
  case "$out" in
    *'bypass canary failed'*) ;;
    *) fail "the refusal must name the canary, got: $out" ;;
  esac
  # Hooks can only fire after launch, so the flag legitimately reaches the
  # launch line; the safety is the refusal closing the endpoint.
  grep -Fq "fm-$id" "$home/launch.log.kills" 2>/dev/null \
    || fail "a dead-adapter bypass spawn left its endpoint running"
  [ ! -e "$home/state/$id.agy-permission.json" ] \
    || fail "a canary-failed spawn must not leave its policy file behind"
  pass "fm-spawn.sh: the armed canary refuses a bypass session whose adapter never logs"
}

test_agy_bypass_canary_ignores_a_stale_generation() {
  local fields case_dir home proj wt fakebin id out status
  fields=$(make_spawn_case bypass-stale)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  # A line an earlier launch of this task left in the append-only log can
  # never satisfy the canary for THIS launch: the adapter stamps its armed
  # record with the busy generation the spawn armed, so a stale generation
  # counts for nothing.
  jq -nc --arg id "$id" \
    '{ts:"2020-01-01T00:00:00Z",task:$id,event:"armed",
      tool:"fm-agy-permission-policy",gen:"stale-generation"}' \
    >> "$home/state/agy-permission-log.jsonl"
  out=$(FM_FAKE_AGY_SKIP_ADAPTER=1 FM_AGY_ARMED_POLLS=4 FM_AGY_POLL_INTERVAL=0.1 \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass)
  status=$?
  [ "$status" -ne 0 ] || fail "a stale armed line must not satisfy the canary: $out"
  case "$out" in
    *'bypass canary failed'*) ;;
    *) fail "the refusal must name the canary, got: $out" ;;
  esac
  # The same stale record beside a live adapter is harmless: the fresh
  # generation's armed line is what the canary trusts.
  fields=$(make_spawn_case bypass-stale-live)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  jq -nc --arg id "$id" \
    '{ts:"2020-01-01T00:00:00Z",task:$id,event:"armed",
      tool:"fm-agy-permission-policy",gen:"stale-generation"}' \
    >> "$home/state/agy-permission-log.jsonl"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass) \
    || fail "an armed bypass spawn beside a stale record must succeed: $out"
  [ "$(jq -s --arg id "$id" \
      'map(select(.task == $id and .event == "armed")) | length' \
      "$home/state/agy-permission-log.jsonl")" = 2 ] \
    || fail "the live adapter must add its own generation's armed line: $(cat "$home/state/agy-permission-log.jsonl")"
  pass "fm-spawn.sh: the armed canary binds to this launch's generation and ignores stale records"
}

test_agy_bypass_relaunch_inherits_only_for_an_agy_worker() {
  local fields case_dir home proj wt fakebin id out gen1 gen2
  fields=$(make_spawn_case bypass-relaunch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass) \
    || fail "the initial bypass spawn must succeed: $out"
  gen1=$(jq -r 'select(.task == "'"$id"'" and .event == "armed") | .gen' \
    "$home/state/agy-permission-log.jsonl" | tail -1)
  [ -n "$gen1" ] || fail "the first spawn left no generation-stamped armed line"
  # A same-harness scout relaunch keeps the posture: the adapter re-arms with
  # the NEW generation and the canary trusts that line, not the stale one.
  rm "$home/launch.log.command" # Model the previous agent exiting to its shell.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1) \
    || fail "a same-harness scout relaunch must keep the bypass posture: $out"
  tail -1 "$home/launch.log" | grep -Fq -- '--dangerously-skip-permissions' \
    || fail "a same-harness relaunch must still carry the bypass flag: $(tail -1 "$home/launch.log")"
  gen2=$(jq -r 'select(.task == "'"$id"'" and .event == "armed") | .gen' \
    "$home/state/agy-permission-log.jsonl" | tail -1)
  [ -n "$gen2" ] && [ "$gen2" != "$gen1" ] \
    || fail "the relaunch must arm a fresh generation's wired adapter: gen1=$gen1 gen2=$gen2"
  [ "$(jq -r .gen "$home/state/$id.agy-permission.json")" = "$gen2" ] \
    || fail "the relaunch's policy file must carry the new generation"
  grep -q '^agy_bypass=on$' "$home/state/$id.meta" \
    || fail "the relaunch must keep the recorded bypass posture"
  # A relaunch resolving onto a different harness drops the posture: no
  # bypass flag on the new launch line, and the agy wiring is retired. The
  # claude replacement changes the fixture's foreground command on Enter;
  # the launch line and the retired wiring must still match the new harness.
  fields=$(make_spawn_case bypass-relaunch-switch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  fm_fake_exit0 "$fakebin" claude
  mkdir -p "$case_dir/user-home"
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass) \
    || fail "the initial bypass spawn must succeed: $out"
  rm "$home/launch.log.command" # Model the previous agent exiting to its shell.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" HOME="$case_dir/user-home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" CLAUDE_CONFIG_DIR='' \
    FM_AGY_READY_POLLS=3 FM_AGY_POLL_INTERVAL=0.1 \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch --harness claude 2>&1)
  tail -1 "$home/launch.log" | grep -Fq -- '--dangerously-skip-permissions' \
    && fail "a harness-switch relaunch must never carry the agy bypass flag: $(tail -1 "$home/launch.log")"
  [ ! -e "$home/state/$id.agy-permission.json" ] \
    || fail "a harness-switch relaunch must retire the agy policy wiring"
  [ ! -e "$home/state/$id.agy-hooks" ] \
    || fail "a harness-switch relaunch must retire the agy worker hooks"
  # A relaunch whose recorded kind is a ship KEEPS the posture: a ship is a
  # bypass candidate too, and dropping the posture at relaunch would silently
  # move a worker off the layer its record says is policing it.
  fields=$(make_spawn_case bypass-relaunch-ship)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout --agy-bypass) \
    || fail "the initial bypass spawn must succeed: $out"
  sed -i '' 's/^kind=scout$/kind=ship/' "$home/state/$id.meta" 2>/dev/null \
    || sed -i 's/^kind=scout$/kind=ship/' "$home/state/$id.meta"
  rm "$home/launch.log.command" # Model the previous agent exiting to its shell.
  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" --relaunch 2>&1) \
    || fail "a ship agy relaunch must still launch: $out"
  tail -1 "$home/launch.log" | grep -Fq -- '--dangerously-skip-permissions' \
    || fail "a ship relaunch must keep the recorded bypass posture: $(tail -1 "$home/launch.log")"
  grep -q '^agy_bypass=on$' "$home/state/$id.meta" \
    || fail "a ship relaunch must keep the recorded posture: $(cat "$home/state/$id.meta")"
  [ -f "$home/state/$id.agy-permission.json" ] \
    || fail "a ship relaunch must keep the permission layer wired"
  pass "fm-spawn.sh: a relaunch inherits agy_bypass whenever it resolves onto an agy worker"
}

# --- control mechanics ------------------------------------------------------

test_agy_control_mechanics_are_the_verified_ones() {
  local out
  fm_control_harness_supported agy || fail "agy must be a supported control harness"
  out=$(fm_control_harness_family agy-1.2.0)
  [ "$out" = agy ] || fail "a recorded agy* harness must resolve to agy, got '$out'"
  out=$(fm_control_interrupt_key agy)
  [ "$out" = Escape ] || fail "agy interrupts on Escape, got '$out'"
  out=$(fm_control_interrupt_repeat agy)
  [ "$out" = 1 ] || fail "agy interrupts on a single press, got '$out'"
  out=$(fm_control_interrupt_clear_key agy)
  [ -z "$out" ] || fail "agy leaves an empty composer and needs no clear key, got '$out'"
  out=$(fm_control_interrupt_ack_source agy)
  [ "$out" = none ] || fail "agy has no recorded cancellation source, got '$out'"
  out=$(fm_control_exit_command agy)
  [ "$out" = /exit ] || fail "agy exits with /exit, got '$out'"
  pass "fm-control-lib.sh: agy carries its verified interrupt and exit mechanics"
}

test_agy_supports_all_task_kinds() {
  fm_control_harness_supports_kind agy ship || fail "agy must be verified for ship work"
  fm_control_harness_supports_kind agy scout || fail "agy must be verified for scout work"
  fm_control_harness_supports_kind agy secondmate || fail "agy must support secondmate work"
  pass "fm-control-lib.sh: agy supports worker, scout, and secondmate"
}

test_agy_wiring_has_a_cleanup_owner() {
  local out
  # Flat wiring cleanup and owned-directory retirement share this adapter path.
  out=$(fm_control_harness_wiring_paths agy /wt /state task-1)
  [ "$out" = "$(printf '%s\n%s\n' /state/task-1.agy-hooks/.agents/hooks.json /state/task-1.agy-permission.json)" ] \
    || fail "wrong agy wiring paths: $out"
  out=$(fm_control_harness_turnend_token_path agy /state task-1)
  [ -z "$out" ] || fail "agy mints no turn-end registry token, got '$out'"
  pass "fm-control-lib.sh: agy hook file has a cleanup path and no global token"
}

test_agy_worker_hooks() {
  local dir="$TMP_ROOT/worker hooks" state wt gen next out hook
  state="$dir/state" wt="$dir/worktree"
  hook="$ROOT/bin/fm-agy-hook.sh"
  mkdir -p "$state" "$wt/.agents"
  printf '{"project-owned":{}}\n' > "$wt/.agents/hooks.json"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-worker) || fail 'arm agy'
  "$hook" install-worker "$state" agy-worker "$gen" "$wt" || fail 'install agy hooks'
  out=$(cat "$wt/.agents/hooks.json")
  [ "$out" = '{"project-owned":{}}' ] || fail 'worker installation changed project hooks'
  agy_worker_event() {
    jq -n --arg conv "$2" --arg wt "$wt" --argjson idle "${3:-true}" \
      '{conversationId:$conv,workspacePaths:[$wt],fullyIdle:$idle}' \
      | "$hook" worker "$1" "$state" agy-worker "$gen" "$wt"
  }
  agy_worker_state() {
    bash -c '. "$1/bin/fm-busy-lib.sh"; fm_busy_classify tmux pane agy agy-worker "$2"' _ "$ROOT" "$state"
  }
  [ -z "$(agy_worker_event PreInvocation main)" ] || fail 'worker start must return an inert response'
  [ "$(agy_worker_state)" = 'busy agy-hook' ] || fail 'PreInvocation did not open busy'
  [ -z "$(agy_worker_event PreToolUse main)" ] || fail 'worker PreToolUse must stay inert: the observer logs but never answers'
  [ -z "$(agy_worker_event Stop child)" ] || fail 'rejected child Stop must return an inert response'
  [ "$(agy_worker_state)" = 'busy agy-hook' ] || fail 'child Stop settled parent'
  [ -z "$(agy_worker_event Stop main false)" ] || fail 'partial worker Stop must return an inert response'
  [ "$(agy_worker_state)" = 'busy agy-hook' ] || fail 'background work settled before fullyIdle'
  [ ! -e "$state/agy-worker.turn-ended" ] || fail 'partial Stop emitted completion'
  [ -z "$(agy_worker_event Stop main)" ] || fail 'worker completion must return an inert response'
  [ "$(agy_worker_state)" = 'idle agy-hook' ] || fail 'fullyIdle Stop did not close busy'
  [ -e "$state/agy-worker.turn-ended" ] || fail 'fullyIdle Stop did not notify watcher'
  rm "$state/agy-worker.turn-ended"
  next=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-worker) || fail 'rearm agy'
  [ -z "$(agy_worker_event Stop main)" ] || fail 'stale worker generation must return an inert response'
  [ "$(agy_worker_state)" = 'busy fm-spawn' ] || fail 'stale hook changed replacement state'
  [ ! -e "$state/agy-worker.turn-ended" ] || fail 'stale hook woke replacement'
  "$hook" retire-worker "$state" agy-worker || fail 'retire agy'
  [ ! -e "$state/agy-worker.agy-hooks" ] || fail 'retire left hook directory'
  mkdir "$state/agy-worker.agy-hooks"
  if "$hook" retire-worker "$state" agy-worker 2>/dev/null; then fail 'retired an unowned directory'; fi
  : "$next"
  pass 'agy worker hooks bind generation and conversation, preserve project hooks, and retire safely'
}

# --- log-only tool observer --------------------------------------------------

test_agy_worker_tool_observer() {
  local dir="$TMP_ROOT/observer" state wt gen hook log out line lines_before
  state="$dir/state" wt="$dir/worktree" hook="$ROOT/bin/fm-agy-hook.sh"
  mkdir -p "$state" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-obs) || fail 'arm agy-obs'
  "$hook" install-worker "$state" agy-obs "$gen" "$wt" || fail 'install agy-obs hooks'
  # The installed file carries all four groups: the turn-end pair flat, and the
  # observer pair grouped under a match-everything matcher with a timeout.
  jq -e '."firstmate-worker" as $h
    | ($h.PreInvocation[0].command | type == "string" and length > 0)
      and ($h.Stop[0].command | type == "string" and length > 0)
      and ($h.PreToolUse[0].matcher == "*")
      and ($h.PostToolUse[0].matcher == "*")
      and ($h.PreToolUse[0].hooks[0].command | type == "string" and length > 0)
      and ($h.PostToolUse[0].hooks[0].command | type == "string" and length > 0)
      and ($h.PreToolUse[0].hooks[0].timeout | type == "number" and . > 0)
      and ($h.PostToolUse[0].hooks[0].timeout | type == "number" and . > 0)' \
    "$state/agy-obs.agy-hooks/.agents/hooks.json" >/dev/null \
    || fail 'installed hooks.json lacks the observer groups or their timeouts'
  log="$state/agy-permission-log.jsonl"
  OBS_PAYLOAD=$(jq -n --arg wt "$wt" '{
    conversationId:"00000000-0000-4000-8000-0000000000a1", stepIdx:2,
    modelName:"gemini-3.6-flash-low",
    toolCall:{name:"run_command",args:{CommandLine:"/usr/bin/touch ws/A",Cwd:"/tmp/ws",WaitMsBeforeAsync:5000,toolAction:"Running shell command",toolSummary:"Touch A"}},
    workspacePaths:[$wt],
    transcriptPath:"/x/brain/conv/.system_generated/logs/transcript_full.jsonl",
    artifactDirectoryPath:"/x/brain/conv"}')
  obs_event() {  # <event> <jq-filter>
    printf '%s' "$OBS_PAYLOAD" | jq "$2" | "$hook" worker "$1" "$state" agy-obs "$gen" "$wt"
  }
  out=$(obs_event PreToolUse '.')
  [ -z "$out" ] || fail "PreToolUse observer emitted stdout: $out"
  out=$(obs_event PostToolUse '.error=""')
  [ -z "$out" ] || fail "PostToolUse observer emitted stdout: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = 2 ] || fail "expected 2 observer lines: $(cat "$log")"
  line=$(sed -n '1p' "$log")
  printf '%s' "$line" | jq -e '
    .event == "pre-tool-use" and .tool == "run_command" and .task == "agy-obs"
    and .session_id == "00000000-0000-4000-8000-0000000000a1" and .step_idx == 2
    and .model == "gemini-3.6-flash-low" and .input == "/usr/bin/touch ws/A"
    and .cwd == "/tmp/ws" and .error == ""
    and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))' >/dev/null \
    || fail "pre-tool line wrong: $line"
  line=$(sed -n '2p' "$log")
  printf '%s' "$line" | jq -e '.event == "post-tool-use" and .error == ""' >/dev/null \
    || fail "post-tool line wrong: $line"
  # A PostToolUse error lands in the error field.
  out=$(obs_event PostToolUse '.error="tool exploded"')
  printf '%s' "$(tail -1 "$log")" | jq -e '.error == "tool exploded"' >/dev/null \
    || fail "post-tool error field wrong: $(tail -1 "$log")"
  # File and web tools land their path or url in input, never the contents.
  out=$(obs_event PreToolUse '.toolCall={name:"write_to_file",args:{TargetFile:"/tmp/secret.go",CodeContent:"TOP-SECRET-BODY"}}')
  [ -z "$out" ] || fail "file-tool observer emitted stdout: $out"
  line=$(tail -1 "$log")
  printf '%s' "$line" | jq -e '.tool == "write_to_file" and .input == "/tmp/secret.go" and .cwd == ""' >/dev/null \
    || fail "file-tool line wrong: $line"
  case "$line" in *TOP-SECRET*) fail 'observer logged file contents' ;; esac
  out=$(obs_event PreToolUse '.toolCall={name:"read_url_content",args:{Url:"https://example.invalid/x"}}')
  [ -z "$out" ] || fail "web-tool observer emitted stdout: $out"
  printf '%s' "$(tail -1 "$log")" | jq -e '.input == "https://example.invalid/x"' >/dev/null \
    || fail "web-tool line wrong: $(tail -1 "$log")"
  # Only this generation's calls in this worktree reach the log.
  lines_before=$(wc -l < "$log" | tr -d ' ')
  out=$(obs_event PreToolUse '.workspacePaths=["/elsewhere"]')
  [ -z "$out" ] || fail "foreign-workspace call produced stdout: $out"
  out=$(printf '%s' "$OBS_PAYLOAD" | "$hook" worker PreToolUse "$state" agy-obs stale-gen "$wt")
  [ -z "$out" ] || fail "stale-generation call produced stdout: $out"
  [ "$(wc -l < "$log" | tr -d ' ')" = "$lines_before" ] || fail 'ungated calls reached the log'
  pass 'agy worker observer logs pre/post tool calls with the mirrored schema and no contents'
}

test_agy_worker_observer_never_blocks() {
  local dir="$TMP_ROOT/observer-fail" state wt gen hook log out payload line big i n rc
  state="$dir/state" wt="$dir/worktree" hook="$ROOT/bin/fm-agy-hook.sh"
  mkdir -p "$state" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-obsf) || fail 'arm agy-obsf'
  "$hook" install-worker "$state" agy-obsf "$gen" "$wt" || fail 'install agy-obsf hooks'
  log="$state/agy-permission-log.jsonl"
  payload=$(jq -n --arg wt "$wt" '{conversationId:"conv-f",stepIdx:1,modelName:"m",toolCall:{name:"run_command",args:{CommandLine:"date",Cwd:"/tmp"}},workspacePaths:[$wt]}')
  # Every failure path must exit 0 with empty stdout: either blocks the tool.
  out=$(printf 'not json at all' | "$hook" worker PreToolUse "$state" agy-obsf "$gen" "$wt")
  [ -z "$out" ] || fail "malformed payload produced stdout: $out"
  local sans
  sans=$(fm_test_base_path_sans "$PATH" jq) || fail 'could not build a jq-less PATH'
  out=$(printf '%s' "$payload" | PATH="$sans" "$hook" worker PreToolUse "$state" agy-obsf "$gen" "$wt")
  [ -z "$out" ] || fail "missing jq produced stdout: $out"
  [ ! -e "$log" ] || fail 'a refused observer path still wrote a log line'
  # A malformed installed command (bad argument count) stays inert for the
  # two tool events; other bad calls keep usage's loud failure.
  out=$(printf '%s' "$payload" | "$hook" worker PreToolUse "$state" agy-obsf 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "bad-arg PreToolUse blocked: rc=$rc out=$out"
  out=$(printf '%s' "$payload" | "$hook" worker PostToolUse "$state" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "bad-arg PostToolUse blocked: rc=$rc out=$out"
  printf '%s' "$payload" | "$hook" worker Stop "$state" >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail 'bad-arg Stop lost its loud failure'
  printf '%s' "$payload" | "$hook" worker >/dev/null 2>&1; rc=$?
  [ "$rc" -ne 0 ] || fail 'event-less worker call lost its loud failure'
  # An unwritable log path (a directory here) must not block either.
  mkdir "$log"
  out=$(printf '%s' "$payload" | "$hook" worker PreToolUse "$state" agy-obsf "$gen" "$wt")
  [ -z "$out" ] || fail "unwritable log produced stdout: $out"
  rmdir "$log"
  # An oversized payload still logs, with the field capped rather than copied.
  big=$(head -c 50000 /dev/zero | tr '\0' 'x')
  out=$(printf '%s' "$payload" | jq --arg big "$big" '.toolCall.args.CommandLine=$big' \
    | "$hook" worker PreToolUse "$state" agy-obsf "$gen" "$wt")
  [ -z "$out" ] || fail "oversized payload produced stdout: $out"
  line=$(tail -1 "$log")
  [ "$(printf '%s' "$line" | jq -r '.input | length')" -le 4000 ] \
    || fail 'observer input field was not capped'
  # Parallel appends from concurrent workers all land as valid JSONL.
  for i in 1 2 3 4 5 6 7 8; do
    printf '%s' "$payload" | jq --argjson i "$i" '.stepIdx=$i' \
      | "$hook" worker PostToolUse "$state" agy-obsf "$gen" "$wt" &
  done
  wait
  n=$(wc -l < "$log" | tr -d ' ')
  [ "$n" = 9 ] || fail "concurrent appends lost lines: expected 9, got $n"
  jq -c . "$log" >/dev/null || fail 'a concurrent append corrupted the JSONL'
  pass 'agy observer never blocks: malformed, missing-jq, bad-arg, unwritable, oversized, and concurrent paths stay inert'
}

test_agy_install_worker_refuses_malformed_merge() {
  local dir="$TMP_ROOT/bad-merge" state wt gen hook fakebin real_jq out
  state="$dir/state" wt="$dir/worktree" hook="$ROOT/bin/fm-agy-hook.sh"
  mkdir -p "$state" "$wt"
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" agy-bad) || fail 'arm agy-bad'
  fakebin=$(fm_fakebin "$dir")
  real_jq=$(command -v jq) || fail 'real jq required for the corruption shim'
  # Corrupt only the `jq -n` generation step: empty every handler command. The
  # file stays parseable JSON, so only install-worker's own validation of the
  # merged result can catch it - the failure mode this guard exists for.
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = -n ]; then
    "$real_jq" "\$@" | sed 's/"command": *"[^"]*"/"command":""/g'
    exit
  fi
done
exec "$real_jq" "\$@"
SH
  chmod +x "$fakebin/jq"
  out=$(PATH="$fakebin:$PATH" "$hook" install-worker "$state" agy-bad "$gen" "$wt" 2>&1) \
    && fail 'install-worker accepted a malformed merged hooks.json'
  case "$out" in
    *refusing*) ;;
    *) fail "refusal was not loud: $out" ;;
  esac
  [ ! -e "$state/agy-bad.agy-hooks/.agents/hooks.json" ] \
    || fail 'a malformed merged hooks.json was installed'
  pass 'install-worker refuses a malformed merged hooks.json loudly and installs nothing'
}

test_agy_primary_hooks() {
  local dir="$TMP_ROOT/primary" out payload filter
  mkdir -p "$dir/bin" "$dir/state" "$dir/projects/project"
  git -C "$dir" init -q
  git -C "$dir" config user.name Test
  git -C "$dir" config user.email test@example.invalid
  printf '# Firstmate\n' > "$dir/AGENTS.md"
  primary_call() {
    FM_ROOT_OVERRIDE="$dir" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
      JETSKI_APP_DATA_DIR=antigravity-cli "$ROOT/bin/fm-agy-hook.sh" primary "$1"
  }
  payload=$(jq -n --arg root "$dir" '{conversationId:"primary",workspacePaths:[$root],invocationNum:0,executionNum:0,fullyIdle:true}')
  out=$(printf '%s' "$payload" | primary_call PreInvocation)
  printf '%s' "$out" | jq -e '.injectSteps[0].ephemeralMessage | contains("fm-session-start.sh")' >/dev/null \
    || fail "startup nudge missing: $out"
  out=$(printf '%s' "$payload" | jq '.invocationNum=1' | primary_call PreInvocation)
  [ -z "$out" ] || fail 'startup nudge preempted a pending tool on a later invocation'
  out=$(printf '%s' "$payload" | jq 'del(.invocationNum)' | primary_call PreInvocation)
  [ -z "$out" ] || fail 'malformed invocation number injected startup'
  out=$(printf '%s' "$payload" | primary_call Stop)
  [ -z "$out" ] || fail "empty fleet forced a continuation: $out"
  touch "$dir/state/worker.meta"
  out=$(printf '%s' "$payload" | primary_call Stop)
  printf '%s' "$out" | jq -e '.decision == "continue" and (.reason | contains("run_command"))' >/dev/null \
    || fail "missing watcher did not force Agy recovery: $out"
  out=$(printf '%s' "$payload" | jq '.executionNum=1' | primary_call Stop)
  [ -z "$out" ] || fail 'continuation guard did not bound the follow-up'
  out=$(printf '%s' "$payload" | jq '.executionNum="0"' | primary_call Stop)
  [ -z "$out" ] || fail 'malformed execution number forced continuation'
  out=$(printf '%s' "$payload" | jq '.workspacePaths=["/elsewhere"]' | primary_call Stop)
  [ -z "$out" ] || fail 'foreign workspace forced continuation'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"bin/fm-watch-arm.sh &"}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null || fail "unsafe watcher accepted: $out"
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "ask"' >/dev/null || fail 'ordinary command must retain native review'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"write_to_file",args:{}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "ask"' >/dev/null || fail 'allowed file tool in a primary must retain native review'
  for filter in \
    'del(.conversationId)' '.conversationId=17' '.conversationId="bad/id"' \
    'del(.workspacePaths)' '.workspacePaths="wrong type"' '.workspacePaths=["/elsewhere"]' \
    'del(.toolCall)' '.toolCall.name=17' \
    'del(.toolCall.args.CommandLine)' '.toolCall.args.CommandLine=17'; do
    out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' \
      | jq "$filter" | primary_call PreToolUse)
    [ -z "$out" ] || fail "rejected PreToolUse payload must be inert ($filter), got $out"
  done
  out=$(printf 'invalid JSON' | primary_call PreToolUse)
  [ -z "$out" ] || fail 'invalid JSON must return an inert response'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"invoke_subagent",args:{}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null || fail 'untracked delegation accepted'
  # A linked worker is outside primary scope, even with a primary hook copied
  # from Firstmate itself; the marker deliberately brings a secondmate back in.
  local child="$TMP_ROOT/primary-child"
  git -C "$dir" add AGENTS.md
  git -C "$dir" commit -qm fixture
  git -C "$dir" worktree add -qb child "$child" >/dev/null 2>&1 || fail 'make linked scope'
  mkdir -p "$child/bin" "$child/state"
  dir=$child
  payload=$(printf '%s' "$payload" | jq --arg root "$dir" '.workspacePaths=[$root]')
  touch "$dir/state/worker.meta"
  out=$(printf '%s' "$payload" | primary_call Stop)
  [ -z "$out" ] || fail 'primary hook ran in worker worktree'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' | primary_call PreToolUse)
  [ -z "$out" ] || fail "primary PreToolUse must be inert in a linked worker worktree, got $out"
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"invoke_subagent",args:{}}' | primary_call PreToolUse)
  [ -z "$out" ] || fail 'out-of-scope tools must not run primary policies'
  printf 'secondmate\n' > "$dir/.fm-secondmate-home"
  out=$(printf '%s' "$payload" | primary_call Stop)
  printf '%s' "$out" | jq -e '.decision == "continue"' >/dev/null || fail 'secondmate omitted primary guard'
  out=$(printf '%s' "$payload" | jq '.toolCall={name:"run_command",args:{CommandLine:"date"}}' | primary_call PreToolUse)
  printf '%s' "$out" | jq -e '.decision == "ask"' >/dev/null || fail 'secondmate primary scope must retain native review'
  pass 'agy primary startup, guard, loop bound, pre-tool policies, and secondmate scope'
}

test_agy_session_identity() {
  bash -c '
    . "$1/bin/fm-session-lock-lib.sh"
    fm_harness_process_matches /opt/bin/agy "/opt/bin/agy --server" || exit 1
    ! fm_harness_process_matches legacy legacy || exit 1
    ! fm_harness_process_matches agyrate agyrate || exit 1
  ' _ "$ROOT" || fail 'agy session identity must use exact command evidence'
  pass 'agy session lock recognizes the exact executable and rejects similar names'
}

test_agy_marker_outranks_inherited_claudecode
test_agy_marker_is_the_cli_not_the_ide
test_agy_does_not_claim_the_gemini_identity
test_agy_marker_yields_to_a_different_native_ancestor
test_agy_ancestry_matches_only_the_exact_command_name
test_agy_tmux_names_the_native_binary_an_agent
test_herdr_done_with_live_registry_stays_live
test_herdr_registered_status_over_a_shell_only_pane_is_stale_not_live
test_herdr_shell_first_with_live_registry_stays_live
test_herdr_lone_unregistered_pane_is_agent_free
test_herdr_malformed_and_failed_reads_stay_unknown
test_agy_auto_uses_accept_edits_and_never_bypass
test_agy_manual_reviews_everything_and_never_bypass
test_agy_absent_setting_defaults_to_accept_edits
test_agy_invalid_setting_refuses_without_bypass
test_agy_launch_grants_the_task_worktree
test_agy_grants_resolve_a_symlinked_worktree
test_agy_effort_caps_at_high
test_agy_effort_passes_supported_levels_through
test_agy_suffixed_model_id_suppresses_the_effort_flag
test_agy_catalog_accepts_listed_ids_and_base_aliases
test_agy_catalog_refuses_unsupported_models_before_launch
test_agy_unreachable_listing_launches_unvalidated
test_agy_hung_listing_is_cut_off_and_launches
test_agy_invalid_model_timeout_is_clamped_to_the_default_bound
test_agy_secondmate_launch_is_supported
test_agy_spawn_confirms_the_brief_started
test_agy_spawn_fails_and_closes_when_the_brief_never_starts
test_agy_spawn_keeps_its_record_when_the_endpoint_will_not_close
test_agy_bypass_launch_installs_the_adapter_and_skips_permissions
test_agy_bypass_ship_keeps_every_write_guard
test_agy_bypass_records_and_prints_the_judge_tier
test_agy_judge_selects_another_tier
test_agy_judge_refuses_rather_than_falling_back
test_agy_bypass_refuses_an_unverified_version
test_agy_bypass_refuses_a_project_hooks_file
test_agy_bypass_refuses_the_wrong_posture
test_agy_bypass_canary_refuses_a_dead_adapter
test_agy_bypass_canary_ignores_a_stale_generation
test_agy_bypass_relaunch_inherits_only_for_an_agy_worker
test_agy_control_mechanics_are_the_verified_ones
test_agy_supports_all_task_kinds
test_agy_wiring_has_a_cleanup_owner
test_agy_worker_hooks
test_agy_worker_tool_observer
test_agy_worker_observer_never_blocks
test_agy_install_worker_refuses_malformed_merge
test_agy_primary_hooks
test_agy_session_identity
