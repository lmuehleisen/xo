#!/usr/bin/env bash
# V2 branch of fm-opencode-primary-live-e2e.test.sh. Uses only a private tmux
# socket, disposable profile, and independently initialized scratch repositories.
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_LIVE_E2E opencode tmux git jq node
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(opencode --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-v2.XXXXXX")
ID="oc-v2-probe-$$"
MODEL=${FM_OPENCODE_LIVE_MODEL:-opencode/muse-spark-1.3-contributor-free}
REAL_TMUX=$(command -v tmux)
unset TMUX TMUX_PANE
export TMUX_TMPDIR="$LAB"
SOCKET="$TMUX_TMPDIR/lab"
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT"
export XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data"
export XDG_STATE_HOME="$LAB/runtime" XDG_CACHE_HOME="$LAB/cache"
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  if [ -d "$LAB" ]; then chmod -R u+w "$LAB"; fi
  fm_test_rm_tmproot "$LAB" "/tmp/fm-$ID"
}
trap cleanup EXIT
mkdir -p "$LAB/shim" "$FM_HOME/config" "$FM_HOME/state" "$FM_HOME/data/$ID" "$LAB/project" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec '$REAL_TMUX' -S '$SOCKET' "\$@"
SH
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'tmux\n' > "$FM_HOME/config/backend"
# A fresh independent fixture repository, never the fleet's shared worktree pool.
git -C "$LAB/project" init -q
git -C "$LAB/wt" init -q
cat > "$FM_HOME/data/$ID/brief.md" <<BRIEF
# Task
## Captain's intent
Verify a trivial runtime task.
## Firstmate spec
Do not edit or inspect any project files.
Append exactly "working: brief processed" to $FM_HOME/state/probe-proof.
Then reply BRIEF_OK and stop until an instruction arrives.
Your steering inbox is $FM_HOME/state/$ID.inbox.
Read each *.msg there when instructed and acknowledge it by moving it into handled/.
If relaunched and probe-proof already exists, append "working: relaunched" instead.
BRIEF
TARGET="probe:fm-$ID"
tmux new-session -d -s probe -n "fm-$ID" -c "$LAB/wt" -x 140 -y 40 "bash --noprofile --norc -i"
sleep 0.5
cat > "$FM_HOME/state/$ID.meta" <<META
window=$TARGET
endpoint_task_id=$ID
worktree=$LAB/wt
project=$LAB/project
harness=opencode
kind=scout
backend=tmux
model=$MODEL
effort=default
META
wait_file_text() {
  local file=$1 text=$2 i=0
  while [ "$i" -lt 180 ]; do
    if [ -f "$file" ] && grep -Fq "$text" "$file"; then return 0; fi
    i=$((i + 1)); sleep 0.5
  done
  tmux capture-pane -p -t "$TARGET" -S -100 >&2
  fail "$VERSION: timed out waiting for $text"
}
wait_idle() {
  local i=0 verdict
  while [ "$i" -lt 120 ]; do
    verdict=$(fm_busy_classify tmux "$TARGET" opencode "$ID" "$FM_HOME/state" 2>/dev/null || true)
    case "$verdict" in "idle opencode-plugin") return 0 ;; esac
    i=$((i + 1)); sleep 0.5
  done
  fail "$VERSION: busy state did not settle: $verdict"
}
. "$ROOT/bin/fm-busy-lib.sh"
bash "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch --harness opencode --model "$MODEL"
wait_file_text "$FM_HOME/state/probe-proof" 'brief processed'
wait_idle
[ -f "$FM_HOME/state/$ID.turn-ended" ] || fail "$VERSION: no turn-end notification"
PLUGIN="/tmp/fm-$ID/opencode-plugin-$(cat "$FM_HOME/state/$ID.busy-gen")/index.mjs"
[ -f "$PLUGIN" ] || fail "$VERSION: missing per-task V2 plugin"
# The config and public execution event paths must retain the exact model ID.
tmux capture-pane -p -t "$TARGET" -S -100 > "$LAB/idle.txt"
if [ "$MODEL" = opencode/muse-spark-1.3-contributor-free ]; then
  grep -Fq 'Muse Spark 1.3 Free OpenCode Zen' "$LAB/idle.txt" || fail "$VERSION: wrong displayed model"
fi
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail "$VERSION: liveness drift"
PANE_PID=$(tmux display-message -p -t "$TARGET" '#{pane_pid}')
bash "$ROOT/bin/fm-harness.sh" ancestry-descent "$PANE_PID" | grep -q 'opencode' || fail "$VERSION: ancestry detection drift"
[ "$(fm_backend_composer_state tmux "$TARGET")" = empty ] || fail "$VERSION: idle composer unreadable"
SCREEN=$(tmux capture-pane -p -e -t "$TARGET")
[ "$(fm_composer_classify_screen styled=1 "$SCREEN")" = empty ] || fail "$VERSION: cursorless idle unreadable"
tmux send-keys -t "$TARGET" -l 'DRAFT_PROOF'
i=0
while [ "$i" -lt 30 ]; do
  [ "$(fm_backend_composer_state tmux "$TARGET")" != pending ] || break
  i=$((i + 1)); sleep 0.1
done
[ "$i" -lt 30 ] || fail "$VERSION: draft classified empty"
tmux send-keys -t "$TARGET" C-u
sleep 0.3
bash "$ROOT/bin/fm-send.sh" "$ID" "Append 'working: steer processed' to $FM_HOME/state/probe-proof and acknowledge this inbox message. Then stop."
wait_file_text "$FM_HOME/state/probe-proof" 'steer processed'
wait_idle
find "$FM_HOME/state/$ID.inbox/handled" -name '*.msg' | grep -q . || fail "$VERSION: steer was not acknowledged"
bash "$ROOT/bin/fm-send.sh" "$ID" "Run sleep 30 in the shell tool. Do not run other tools until it finishes."
i=0
while [ "$i" -lt 90 ]; do
  SCREEN=$(tmux capture-pane -p -t "$TARGET")
  case "$SCREEN" in *'esc interrupt'*) break ;; esac
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 90 ] || fail "$VERSION: running surface not observed"
bash "$ROOT/bin/fm-control.sh" "$ID" interrupt
wait_idle
bash "$ROOT/bin/fm-control.sh" "$ID" exit
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail "$VERSION: exit did not stop agent"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Repeat the trivial runtime probe without editing project files.'
wait_file_text "$FM_HOME/state/probe-proof" 'relaunched'
wait_idle
bash "$ROOT/bin/fm-control.sh" "$ID" exit
pass "$VERSION: requested model, brief, busy/idle, turn-end, composer, durable steer, interrupt, exit and relaunch"
