#!/usr/bin/env bash
# Opt-in live guard for Claude ultracode and both native goal parsers, using
# the same launch flags and shared backend submit path as fm-spawn.
# Spends a small model turn per installed harness; no project tools or edits.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_WORKER_LAUNCH_OPTINS_LIVE_E2E tmux jq
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
LAB=$(fm_test_tmproot fm-worker-launch-optins-live)
REAL_TMUX=$(command -v tmux)
export TMUX_TMPDIR="$LAB"
SOCKET="$TMUX_TMPDIR/lab"
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_rm_tmproot "$LAB"
}
trap cleanup EXIT
mkdir -p "$LAB/shim"
cat > "$LAB/shim/tmux" <<EOF
#!/usr/bin/env bash
exec '$REAL_TMUX' -S '$SOCKET' "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
"$REAL_TMUX" -S "$SOCKET" new-session -d -s optins -x 160 -y 45 -c "$ROOT"
checked=0
for harness in claude codex; do
  command -v "$harness" >/dev/null 2>&1 || { printf '# absent: %s\n' "$harness"; continue; }
  version=$("$harness" --version 2>/dev/null | head -1)
  args=()
  if [ "$harness" = claude ]; then
    probe=$(claude -p --settings '{"ultracode":true}' --output-format json '/effort current')
    printf '%s\n' "$probe" | jq -e '.local_command == "effort" and (.result | contains("Ultracode on")) and .num_turns == 0' >/dev/null \
      || fail "$harness $version: ultracode probe failed"
    args=(env -u CLAUDECODE CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false claude --permission-mode auto --settings '{"ultracode":true}' '/effort current')
  else
    model=${FM_WORKER_LAUNCH_OPTINS_CODEX_MODEL:-gpt-6.1-sol}
    "$ROOT/bin/fm-harness.sh" validate-native-effort codex "$model" ultra || fail "$harness $version: ultra validation failed"
    args=(codex --no-daemon --disable hooks --enable goals --model "$model" -c 'model_reasoning_effort="ultra"')
  fi
  command_line=
  for arg in "${args[@]}"; do
    printf -v quoted '%q' "$arg"
    command_line="$command_line $quoted"
  done
  tmux new-window -t optins -n "$harness" -c "$ROOT" "$command_line"
  target="optins:$harness"
  ready=0
  for _ in $(seq 1 120); do
    [ "$(fm_backend_composer_state tmux "$target")" != empty ] || { ready=1; break; }
    sleep 0.5
  done
  [ "$ready" = 1 ] || fail "$harness $version: no empty composer (check workspace/hook trust)"
  if [ "$harness" = claude ]; then
    fm_backend_capture tmux "$target" 100 | grep -q 'Ultracode on' \
      || fail "$harness $version: startup /effort current did not confirm the actual session mode"
  fi
  verdict=$(fm_backend_send_text_submit tmux "$target" '/goal Your response contains LAUNCH_OPTINS_OK and the goal is complete. Reply exactly LAUNCH_OPTINS_OK, then mark the goal complete. Use only goal lifecycle tools.' 3 0.4 1.2)
  [ "$verdict" = empty ] || fail "$harness $version: native goal submit unconfirmed ($verdict)"
  activated=0
  completed=0
  for _ in $(seq 1 180); do
    pane=$(fm_backend_capture tmux "$target" 100)
    case "$harness" in
      claude)
        printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*⎿[[:space:]]+Goal set:|^[[:space:]]*✔ Goal achieved' && activated=1
        completion_pattern='^[[:space:]]*✔ Goal achieved'
        ;;
      codex)
        printf '%s\n' "$pane" | grep -Eq '^[[:space:]]*• Goal active Objective:|^[[:space:]]*(• )?Goal achieved \(' && activated=1
        completion_pattern='^[[:space:]]*(• )?Goal achieved \('
        ;;
    esac
    if printf '%s\n' "$pane" | grep -Eq "$completion_pattern"; then completed=1; break; fi
    sleep 0.5
  done
  if [ "$activated" != 1 ] || [ "$completed" != 1 ]; then
    printf '%s\n' "${pane//$ROOT/<checkout>}" >&2
    fail "$harness $version: goal did not activate and complete (activated=$activated completed=$completed)"
  fi
  checked=$((checked + 1))
  pass "$harness $version: mode launch, native goal acknowledgement and completion"
done
[ "$checked" -gt 0 ] || fail 'no installed harness was exercised'
