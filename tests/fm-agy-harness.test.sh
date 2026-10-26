#!/usr/bin/env bash
# Behavior tests for the agy (Antigravity CLI) harness adapter: harness
# detection, the approval-mode mapping and its refusals, the mandatory
# worktree grant, the effort ceiling and the model-id/--effort conflict, the
# secondmate launch, native hook transports, and the control mechanics.
#
# The facts pinned here are the ones an Antigravity release could silently
# change and the ones a wrong guess would make dangerous:
#   Auto selects verified native review; old bypass records retain their
#   original relaunch contract. Manual retains native review prompts.
#   Physical grants, catalog/effort validation, native hook generation and
#   primary/control compatibility remain independently covered below.
#   Credentialed tests/fm-agy-native-live-e2e.test.sh proves the native route.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/agy-admission-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/agy-admission-helpers.sh"
# shellcheck source=bin/fm-agy-lib.sh
. "$ROOT/bin/fm-agy-lib.sh"
# shellcheck source=bin/fm-judge-tier-lib.sh
. "$ROOT/bin/fm-judge-tier-lib.sh"

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
if [ "${FM_FAKE_AGY_NATIVE:-0}" = 1 ] && [ -e "$FM_FAKE_LAUNCH_LOG.native-started" ]; then
  case "${1:-}" in
    capture-pane|display-message|send-keys)
      exec python3 "$FM_NATIVE_ROOT/tests/agy-native-terminal-fixture.py" "$@" ;;
  esac
fi
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
    if [ "${FM_FAKE_AGY_NATIVE:-0}" = 1 ] && [ "${*: -1}" = Enter ] \
      && [ -s "$FM_FAKE_LAUNCH_LOG.agy-hooks" ]; then
      exec python3 "$FM_NATIVE_ROOT/tests/agy-native-terminal-fixture.py" spawn-start
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
  printf 'manual\n' > "$home/config/crew-permissions"
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
  if [ "${FM_FAKE_AGY_NATIVE:-0}" = 1 ]; then
    fm_agy_fixture_receipt "$home" "$fakebin/agy" gemini-3.8-flash-low '' native-tmux '' '' || return 1
  fi
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" FM_NATIVE_ROOT="$ROOT" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" agy --model gemini-3.8-flash-low "$@" 2>&1
}

# --- approval posture -------------------------------------------------------

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

test_agy_manual_reviews_everything_and_never_bypass() {
  local fields case_dir home proj wt fakebin id launch
  fields=$(make_spawn_case manual)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
  : "$case_dir"
  rm -f "$fakebin/agy"
  fakebin=$(make_bypass_fakebin "$case_dir/fake2")
  printf 'manual\n' > "$home/config/crew-permissions"
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout >/dev/null
  launch=$(cat "$home/launch.log")
  case "$launch" in
    *'--mode '*) fail "manual must leave agy in its default review mode: $launch" ;;
  esac
  case "$launch" in
    *--dangerously-skip-permissions*)
      fail "manual must never reach agy's blanket approval bypass: $launch" ;;
  esac
  ! grep -q '^agy_bypass=' "$home/state/$id.meta" \
    || fail "manual review must not record an active bypass posture"
  pass "fm-spawn.sh: agy manual keeps every action under review"
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
  local fields case_dir home proj wt fakebin id launch level out
  for level in xhigh max; do
    fields=$(make_spawn_case "effort-$level")
    IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$fields
EOF
    : "$case_dir"
    out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout \
      --model gemini-3.8-flash --effort "$level") || fail "effort launch failed: $out"
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
  ! grep -Fq -- '--dangerously-skip-permissions' "$home/launch.log" \
    || fail "agy secondmates stay outside the worker bypass policy layer"
  ! grep -q '^agy_bypass=' "$home/state/$id.meta" \
    || fail "agy secondmates must not record a worker bypass posture"
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


test_agy_native_mapping_and_grants() (
  shell_quote() { printf '%q' "$1"; }
  AGY_BYPASS=0 AGY_BYPASS_POSTURE_SET=0 AGY_NATIVE_AUTO=0 CREW_PERMISSION_MODE=auto
  fm_agy_default_posture agy ship
  [ "$AGY_NATIVE_AUTO:$AGY_BYPASS" = 1:0 ] || fail 'Auto did not select native review'
  [ "$(fm_agy_permission_flags auto)" = '--mode auto --sandbox' ] || fail 'native review flags missing'
  [ -z "$(fm_agy_permission_flags manual)" ] || fail 'manual must preserve default native review'
  WT="$TMP_ROOT/native-grants/worktree" STATE_REAL="$TMP_ROOT/native-grants/state"
  BRIEF="$TMP_ROOT/native-grants/data/brief.md" TASK_TMP="$TMP_ROOT/native-grants/tmp" ID=t1 KIND=ship RAW_LAUNCH=0
  mkdir -p "$WT" "$STATE_REAL/$ID.agy-hooks" "${BRIEF%/*}" "$TASK_TMP"
  flags=$(fm_agy_permission_dirs)
  python3 - "$flags" "$STATE_REAL" "$TASK_TMP" <<'PY' || fail 'native directory grants differ from the exact task roots'
import shlex, sys
from pathlib import Path
flags = shlex.split(sys.argv[1])
grants = [flags[i + 1] for i in range(0, len(flags), 2) if flags[i] == "--add-dir"]
assert str(Path(sys.argv[2]).resolve()) not in grants
assert str(Path(sys.argv[3]).resolve()) in grants
PY
  pass 'agy native mapping and minimal physical grants'
)

test_agy_native_refuses_unproven_context_before_brief() {
  local setting fields case_dir home proj wt fakebin id out
  for setting in auto absent; do
    fields=$(make_spawn_case "native-$setting")
    IFS='|' read -r case_dir home proj wt fakebin id <<<"$fields"
    fakebin=$(make_bypass_fakebin "$case_dir/versioned")
    if [ "$setting" = absent ]; then rm "$home/config/crew-permissions"; else printf 'auto\n' > "$home/config/crew-permissions"; fi
    if out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout); then fail 'unproven native context launched'; fi
    case "$out" in *'native Auto candidate'*'outside >=1.4.7'*) ;; *) fail "wrong native refusal: $out" ;; esac
    [ ! -s "$home/launch.log" ] || fail 'native refusal sent a real brief or bypass'
  done
  pass 'explicit and absent Auto settings refuse an unproven native context without a task brief'
}

test_agy_native_spawn_orders_proof_before_brief() {
  local variant fields case_dir home proj wt fakebin id out state_real tasktmp
  for variant in success fallback; do
    fields=$(make_spawn_case "native-$variant-${TMP_ROOT##*.}")
    IFS='|' read -r case_dir home proj wt fakebin id <<<"$fields"
    mv "$fakebin/agy" "$fakebin/agy-catalog"
    cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then printf 'agy 1.4.7\n'; else exec "$(dirname "$0")/agy-catalog" "$@"; fi
SH
    chmod +x "$fakebin/agy"
    printf 'auto\n' > "$home/config/crew-permissions"
    printf '\nDo not read unrelated source files or credential material.\n' >> "$home/data/$id/brief.md"
    if [ "$variant" = success ]; then
      if ! out=$(FM_FAKE_AGY_NATIVE=1 FM_AGY_NATIVE_POLLS=8 FM_AGY_POLL_INTERVAL=0.1 \
        run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout); then
        cat "$home/launch.log.native-transport" "$home/launch.log.native-screen" >&2
        fail "native spawn failed: $out"
      fi
      [ -e "$home/launch.log.native-canary" ] && [ -s "$home/launch.log.native-brief" ] \
        || fail 'native spawn omitted activation or brief delivery'
      grep -q '^agy_posture=native-auto$' "$home/state/$id.meta" || fail 'native posture was not recorded'
      ! grep -q '^agy_bypass=\|^agy_judge=' "$home/state/$id.meta" || fail 'native task was recorded as legacy bypass/judge'
      grep -q -- '--mode auto --sandbox' "$home/launch.log" || fail 'native launch flags missing'
      ! grep -q -- '--dangerously-skip-permissions\|-i .*encode launch-brief' "$home/launch.log" \
        || fail 'native startup sent the task before activation or enabled bypass'
      state_real=$(cd "$home/state" && pwd -P)
      ! grep -Fq -- "--add-dir '$state_real' " "$home/launch.log" || fail 'native launch granted shared state'
    else
      if out=$(FM_FAKE_AGY_NATIVE=1 FM_FAKE_AGY_NO_AUTO=1 FM_AGY_NATIVE_POLLS=3 FM_AGY_POLL_INTERVAL=0.1 \
        run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout); then fail 'native fallback was reported dispatched'; fi
      [ ! -e "$home/launch.log.native-brief" ] && [ ! -e "$home/launch.log.native-canary" ] \
        || fail 'unproven native fallback received a task brief'
      grep -q 'native Auto activation failed' "$home/state/$id.status" || fail "native fallback refusal was not recorded: $out"
      [ -f "$home/launch.log.closed" ] || fail 'unproven native endpoint was not closed'
    fi
    tasktmp="/tmp/fm-$id"
    fm_test_rm_tmproot "$tasktmp"
  done
  pass 'native spawn: real-result proof precedes brief delivery, and unproven fallback closes without delivery'
}

test_agy_deprecated_worker_flags_refuse() {
  local flag fields case_dir home proj wt fakebin id out
  for flag in --agy-bypass --no-agy-bypass '--agy-judge=agy'; do
    fields=$(make_spawn_case "deprecated-${flag//[^a-z]/}")
    IFS='|' read -r case_dir home proj wt fakebin id <<<"$fields"
    if out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --scout "$flag"); then fail "$flag launched a new worker"; fi
    case "$out" in *'deprecated for new workers'*) ;; *) fail "unclear legacy flag refusal: $out" ;; esac
    [ ! -s "$home/launch.log" ] || fail 'deprecated flag reached the pane'
  done
  pass 'deprecated agy worker flags refuse with a migration diagnostic'
}

test_agy_native_and_legacy_relaunch_postures() (
  local posture meta="$TMP_ROOT/relaunch-posture.meta"
  for posture in native-auto legacy-bypass legacy-prompt manual legacy-manual old-prompt; do
    printf 'model=fixture-model\neffort=high\n' > "$meta"
    case "$posture" in
      native-auto) printf 'agy_posture=native-auto\n' >> "$meta" ;;
      legacy-bypass) printf 'agy_bypass=on\nagy_judge=devin:fixture-judge\n' >> "$meta" ;;
      legacy-prompt) printf 'agy_bypass=off\n' >> "$meta" ;;
      manual) printf 'agy_posture=manual\nagy_permission_mode=manual\n' >> "$meta" ;;
      legacy-manual) printf 'agy_permission_mode=manual\nagy_bypass=off\n' >> "$meta" ;;
      old-prompt) printf 'agy_permission_mode=auto\n' >> "$meta" ;;
    esac
    ARG3=agy KIND=scout RELAUNCH_META="$meta" RELAUNCH_PRIOR_HARNESS=agy
    MODEL_SET=0 EFFORT_SET=0 MODEL='' EFFORT='' AGY_NATIVE_AUTO=0
    AGY_BYPASS=0 AGY_BYPASS_POSTURE_SET=0 AGY_BYPASS_OPT_OUT=0 AGY_JUDGE_ARG=''
    CREW_PERMISSION_MODE=auto
    fm_agy_relaunch_inherit
    fm_agy_default_posture agy scout
    [ "$MODEL:$EFFORT" = fixture-model:high ] || fail 'relaunch lost its tested model context'
    case "$posture" in
      native-auto) [ "$AGY_NATIVE_AUTO:$AGY_BYPASS" = 1:0 ] || fail 'native relaunch changed posture' ;;
      legacy-bypass) [ "$AGY_NATIVE_AUTO:$AGY_BYPASS:$AGY_JUDGE_ARG" = 0:1:devin:fixture-judge ] || fail 'legacy relaunch changed its judge' ;;
      legacy-prompt|old-prompt) [ "$AGY_NATIVE_AUTO:$AGY_BYPASS:$AGY_BYPASS_OPT_OUT" = 0:0:1 ] || fail 'legacy prompt relaunch changed posture' ;;
      manual|legacy-manual)
        [ "$AGY_NATIVE_AUTO:$CREW_PERMISSION_MODE" = 0:manual ] || fail 'manual relaunch changed posture'
        [ -z "$(fm_agy_permission_flags "$CREW_PERMISSION_MODE")" ] || fail 'manual relaunch enabled automatic edits' ;;
    esac
    # The emitted descriptor must keep the same route on a second restart.
    HARNESS=agy AGY_BIN='' AGY_JUDGE_TIER=devin AGY_JUDGE_MODEL=fixture-judge RAW_LAUNCH=0
    before="$AGY_NATIVE_AUTO:$AGY_BYPASS:$CREW_PERMISSION_MODE"
    printf 'model=fixture-model\neffort=high\n' > "$meta"
    fm_agy_meta_lines >> "$meta"
    AGY_NATIVE_AUTO=0 AGY_BYPASS=0 AGY_BYPASS_POSTURE_SET=0 AGY_BYPASS_OPT_OUT=0
    CREW_PERMISSION_MODE=auto
    fm_agy_relaunch_inherit
    [ "$AGY_NATIVE_AUTO:$AGY_BYPASS:$CREW_PERMISSION_MODE" = "$before" ] || fail 'recording the posture changed the next restart'
  done
  pass 'native, manual and recorded legacy relaunches retain their own posture and context'
)

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
    modelName:"gemini-3.8-flash-low",
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
    and .model == "gemini-3.8-flash-low" and .input == "/usr/bin/touch ws/A"
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
  out=$(obs_event PreToolUse '.toolCall={name:"edit_file",args:{Path:"/tmp/current.go",Target:"TOP-SECRET-OLD",Replacement:"TOP-SECRET-NEW"}}')
  [ -z "$out" ] || fail "current file-tool observer emitted stdout: $out"
  line=$(tail -1 "$log")
  printf '%s' "$line" | jq -e '.tool == "edit_file" and .input == "/tmp/current.go"' >/dev/null \
    || fail "current file-tool line wrong: $line"
  case "$line" in *TOP-SECRET*) fail 'observer logged replacement contents' ;; esac
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
test_agy_manual_reviews_everything_and_never_bypass
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
test_agy_control_mechanics_are_the_verified_ones
test_agy_supports_all_task_kinds
test_agy_wiring_has_a_cleanup_owner
test_agy_worker_hooks
test_agy_worker_tool_observer
test_agy_worker_observer_never_blocks
test_agy_install_worker_refuses_malformed_merge
test_agy_primary_hooks
test_agy_session_identity

test_agy_native_mapping_and_grants || exit 1
test_agy_native_refuses_unproven_context_before_brief
test_agy_native_spawn_orders_proof_before_brief
test_agy_deprecated_worker_flags_refuse
test_agy_native_and_legacy_relaunch_postures || exit 1
