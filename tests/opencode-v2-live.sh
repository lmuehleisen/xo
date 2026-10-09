#!/usr/bin/env bash
# V2 branch of fm-opencode-primary-live-e2e.test.sh. Uses only a private tmux
# socket, disposable profile, and independently initialized scratch repositories.
set -eu
if [ "${FM_OPENCODE_LIVE_BACKEND:-tmux}" = herdr ]; then
  exec bash "$(dirname "${BASH_SOURCE[0]}")/opencode-v2-herdr-live.sh"
fi
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_LIVE_E2E opencode tmux git jq node
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=$(opencode --version)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-v2.XXXXXX")
ID="oc-v2-probe-$$"
MODEL=${FM_OPENCODE_LIVE_MODEL:-opencode/muse-spark-1.3-contributor-free}
REAL_TMUX=$(command -v tmux)
unset TMUX TMUX_PANE
CODE_ROOT="$LAB/code"
mkdir -p "$CODE_ROOT/.agents/skills/fm-local-skill-probe" "$CODE_ROOT/.agents/skills/fm-worktree-skill-probe"
CODE_ROOT=$(cd "$CODE_ROOT" && pwd -P)
ln -s "$ROOT/bin" "$CODE_ROOT/bin"
ln -s "$ROOT/.opencode" "$CODE_ROOT/.opencode"
cat > "$CODE_ROOT/.agents/skills/fm-local-skill-probe/SKILL.md" <<'SKILL'
---
name: fm-local-skill-probe
description: Load only to verify worker skill discovery.
---
The verification token is FM_OPENCODE_LOCAL_SKILL_OK.
SKILL
cat > "$CODE_ROOT/.agents/skills/fm-worktree-skill-probe/SKILL.md" <<'SKILL'
---
name: fm-worktree-skill-probe
description: Load only to verify worktree skill precedence.
---
The verification token is FM_OPENCODE_PRIMARY_SKILL_STALE.
SKILL
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$CODE_ROOT"
LAB_HOME_HELPER="$ROOT/bin/fm-lab-home.sh"
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$FM_HOME")
SOCKET="$LAB_TMUX_DIR/tmux-$(id -u)/default"
export XDG_CONFIG_HOME="$LAB/config" XDG_DATA_HOME="$LAB/data"
export XDG_STATE_HOME="$LAB/runtime" XDG_CACHE_HOME="$LAB/cache"
export FM_SPAWN_NO_GUARD=1
cleanup() {
  "$REAL_TMUX" -S "$SOCKET" kill-server 2>/dev/null || true
  "$LAB_HOME_HELPER" teardown "$FM_HOME"
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
fm_git_init_commit "$LAB/project"
git clone -q --no-local "$LAB/project" "$LAB/wt"
mkdir -p "$LAB/wt/.agents/skills/fm-worktree-skill-probe"
cat > "$LAB/wt/.agents/skills/fm-worktree-skill-probe/SKILL.md" <<'SKILL'
---
name: fm-worktree-skill-probe
description: Load only to verify worktree skill precedence.
---
The verification token is FM_OPENCODE_WORKTREE_SKILL_OK.
SKILL
printf '.agents/skills/fm-worktree-skill-probe/\n' >> "$LAB/wt/.git/info/exclude"
# Only allocation is stubbed: no fleet pool or linked worktree is administered.
cat > "$LAB/shim/treehouse" <<SH
#!/usr/bin/env bash
[ "\$1" = get ] || exit 1
printf '%s\n' '$LAB/wt'
SH
chmod +x "$LAB/shim/treehouse"
cat > "$FM_HOME/data/$ID/brief.md" <<BRIEF
# Task
## Captain's intent
Verify a trivial runtime task.
## Firstmate spec
Do not edit any project files.
Inspect skill instructions only through the skill tool.
Call the skill tool with id="fm-local-skill-probe" and then id="fm-worktree-skill-probe" before reporting.
Append a newline-terminated line containing "working: brief processed" and both verification tokens from the skill tool's returned bodies to $FM_HOME/state/$ID.status.
Do not read SKILL.md through a file tool or use a fallback; if the skill tool fails, report its error and stop.
Then reply BRIEF_OK and stop until an instruction arrives.
Your steering inbox is $FM_HOME/state/$ID.inbox.
Read each *.msg there when instructed and acknowledge it by moving it into handled/.
If the status file already contains "brief processed", append "working: relaunched" instead.
BRIEF
TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" new-session -d -s probe -n anchor -c "$LAB/project" -x 140 -y 40 "bash --noprofile --norc -i"
# Keep the new endpoint on this private server; production allocation still
# creates the worker window and enters the independent scratch copy.
export TMUX="$SOCKET,$$,0"
TARGET="probe:fm-$ID"
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
assert_local_skill_loaded() {
  local session
  session=$(cd "$LAB/wt" && opencode session list --standalone --max-count 1 --format json | jq -er '.[0].id') \
    || fail "$VERSION: could not find the scratch worker session"
  (cd "$LAB/wt" && opencode session export --standalone "$session") > "$LAB/skill-session.json" \
    || fail "$VERSION: could not export the scratch worker session"
  jq -e --arg base "$CODE_ROOT/.agents/skills/fm-local-skill-probe" \
    --arg worktree_base "$(cd "$LAB/wt/.agents/skills/fm-worktree-skill-probe" && pwd -P)" '
    [.messages[] | select(.type == "assistant") | .content[] |
      select(.type == "tool" and .name == "skill" and .state.status == "completed")] as $skills |
    any($skills[]; .state.input.id == "fm-local-skill-probe" and .state.metadata.directory == $base and
      any(.state.content[]; .type == "text" and (.text | contains("FM_OPENCODE_LOCAL_SKILL_OK")))) and
    any($skills[]; .state.input.id == "fm-worktree-skill-probe" and .state.metadata.directory == $worktree_base and
      any(.state.content[]; .type == "text" and (.text | contains("FM_OPENCODE_WORKTREE_SKILL_OK"))))
  ' "$LAB/skill-session.json" > /dev/null || {
    jq -c '.messages[] | select(.type == "assistant") | .content[] |
      select(.type == "tool" and .name == "skill") |
      {name,status:.state.status,input:.state.input,directory:.state.metadata.directory}' "$LAB/skill-session.json" >&2
    fail "$VERSION: native skill tool did not load the home-local skill from the Firstmate code root"
  }
}
. "$ROOT/bin/fm-busy-lib.sh"
# A tmux cursor can prove readiness while cursorless backends reject the same
# fresh home screen. Exercise it before submitting a prompt or opening a session.
. "$ROOT/bin/fm-tmux-lib.sh"
HOME_CONFIG=$(jq -nc --arg model "$MODEL" '{model:$model,agents:{build:{model:$model}}}')
tmux new-window -d -t probe: -n home -c "$LAB/wt" \
  "OPENCODE_CONFIG_CONTENT='$HOME_CONFIG' opencode --standalone --auto"
i=0
while [ "$i" -lt 120 ]; do
  [ "$(fm_tmux_composer_state probe:home)" != empty ] || break
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 120 ] || fail "$VERSION: fresh home composer not ready"
SCREEN=$(tmux capture-pane -p -e -t probe:home)
PLAIN=$(printf '%s\n' "$SCREEN" | fm_composer_strip_ansi)
printf '%s\n' "$PLAIN" | grep -Eq '^[[:space:]]{8,}[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' \
  || fail "$VERSION: fresh home version-label case absent"
[ "$(fm_composer_classify_screen styled=1 "$SCREEN")" = empty ] \
  || fail "$VERSION: fresh home cursorless styled composer unreadable"
[ "$(fm_composer_classify_screen styled=0 "$PLAIN")" = empty ] \
  || fail "$VERSION: fresh home cursorless plain composer unreadable"
tmux send-keys -t probe:home -l 'DRAFT_PROOF'
i=0
while [ "$i" -lt 30 ]; do
  SCREEN=$(tmux capture-pane -p -e -t probe:home)
  [ "$(fm_composer_classify_screen styled=1 "$SCREEN")" != pending ] || break
  i=$((i + 1)); sleep 0.1
done
[ "$i" -lt 30 ] || fail "$VERSION: fresh home draft classified empty"
[ "$(fm_composer_extract_selected_content styled=1 "$SCREEN")" = DRAFT_PROOF ] \
  || fail "$VERSION: fresh home draft extraction drift"
tmux kill-window -t probe:home
pass "$VERSION: fresh home version label, cursorless styled/plain readiness and draft refusal"
bash "$ROOT/bin/fm-spawn.sh" "$ID" "$LAB/project" --scout --harness opencode --model "$MODEL"
wait_file_text "$FM_HOME/state/$ID.status" 'brief processed'
wait_idle
wait_file_text "$FM_HOME/state/$ID.status" 'FM_OPENCODE_LOCAL_SKILL_OK'
assert_local_skill_loaded
[ -z "$(git -C "$LAB/wt" status --porcelain)" ] || fail "$VERSION: skill probe wrote to the scratch project"
pass "$VERSION: native skill tool loads home-local and worktree override skills without project config"
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
bash "$ROOT/bin/fm-send.sh" "$ID" "Append 'working: steer processed' to $FM_HOME/state/$ID.status and acknowledge this inbox message. Then stop."
wait_file_text "$FM_HOME/state/$ID.status" 'steer processed'
wait_idle
find "$FM_HOME/state/$ID.inbox/handled" -name '*.msg' | grep -q . || fail "$VERSION: steer was not acknowledged"
bash "$ROOT/bin/fm-send.sh" "$ID" "Acknowledge this inbox message by moving it into handled/ before running sleep 30 in the shell tool. Do not run other tools until sleep finishes."
wait_file_text "$FM_HOME/state/$ID.inbox/handled/002.msg" 'sleep 30'
i=0
while [ "$i" -lt 90 ]; do
  SCREEN=$(tmux capture-pane -p -t "$TARGET")
  case "$SCREEN" in *'esc interrupt'*) break ;; esac
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 90 ] || fail "$VERSION: running surface not observed"
[ "$(fm_composer_classify_screen styled=0 "$SCREEN")" = empty ] || fail "$VERSION: running cursorless composer unreadable"
bash "$ROOT/bin/fm-control.sh" "$ID" interrupt
wait_idle
bash "$ROOT/bin/fm-control.sh" "$ID" exit
[ "$(fm_backend_agent_state tmux "$TARGET")" = dead ] || fail "$VERSION: exit did not stop agent"
# A direct bare replacement must inherit its model as well as its worktree.
printf 'preserved work\n' > "$LAB/wt/progress.txt"
bash "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch
[ "$(sed -n 's/^model=//p' "$FM_HOME/state/$ID.meta")" = "$MODEL" ] || fail "$VERSION: relaunch lost recorded model"
[ "$(cat "$LAB/wt/progress.txt")" = 'preserved work' ] || fail "$VERSION: relaunch changed work"
wait_file_text "$FM_HOME/state/$ID.status" 'relaunched'
wait_idle
assert_local_skill_loaded
SCREEN=$(tmux capture-pane -p -t "$TARGET")
[ "$(fm_composer_classify_screen styled=0 "$SCREEN")" = empty ] || fail "$VERSION: restarted cursorless idle unreadable"
if [ "$MODEL" = opencode/muse-spark-1.3-contributor-free ]; then
  printf '%s\n' "$SCREEN" | grep -Fq 'Muse Spark 1.3 Free OpenCode Zen' || fail "$VERSION: relaunch displayed wrong model"
fi
HANDLED_BEFORE=$(find "$FM_HOME/state/$ID.inbox/handled" -name '*.msg' | wc -l)
bash "$ROOT/bin/fm-send.sh" "$ID" "Append 'working: restarted steer processed' to $FM_HOME/state/$ID.status and acknowledge this inbox message. Then stop."
wait_file_text "$FM_HOME/state/$ID.status" 'restarted steer processed'
wait_idle
[ "$(find "$FM_HOME/state/$ID.inbox/handled" -name '*.msg' | wc -l)" -gt "$HANDLED_BEFORE" ] || fail "$VERSION: restarted steer was not acknowledged"
[ "$(fm_backend_agent_state tmux "$TARGET")" = alive ] || fail "$VERSION: restarted pane lost agent"
# Exercise the control owner's transaction feedback on a real replacement too.
RELAUNCH_COUNT=$(grep -Fc 'working: relaunched' "$FM_HOME/state/$ID.status")
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue the trivial runtime task.'
i=0
while [ "$i" -lt 180 ]; do
  CURRENT_COUNT=$(grep -Fc 'working: relaunched' "$FM_HOME/state/$ID.status")
  [ "$CURRENT_COUNT" -le "$RELAUNCH_COUNT" ] || break
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 180 ] || fail "$VERSION: control replacement did not process its brief"
wait_idle
[ "$(sed -n 's/^model=//p' "$FM_HOME/state/$ID.meta")" = "$MODEL" ] || fail "$VERSION: control replacement lost model"
bash "$ROOT/bin/fm-control.sh" "$ID" exit
# Force a readiness timeout before brief submission, then prove the real pane
# and its work survived and that the ordinary control plane can still exit it.
if FM_OPENCODE_READY_POLLS=0 bash "$ROOT/bin/fm-spawn.sh" "$ID" --relaunch > "$LAB/failed-restart.txt" 2>&1; then
  fail "$VERSION: forced readiness failure unexpectedly succeeded"
fi
grep -Fq 'endpoint and replacement wiring are preserved' "$LAB/failed-restart.txt" || fail "$VERSION: failure omitted recovery diagnostics"
i=0
while [ "$i" -lt 60 ]; do
  [ "$(fm_backend_agent_state tmux "$TARGET")" != alive ] || break
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 60 ] || fail "$VERSION: failed readiness removed the real pane"
[ "$(cat "$LAB/wt/progress.txt")" = 'preserved work' ] || fail "$VERSION: failed readiness changed work"
find "/tmp/fm-$ID" -name 'opencode-startup-*.log' | grep -q . || fail "$VERSION: no retained failure capture"
i=0
while [ "$i" -lt 60 ]; do
  [ "$(fm_backend_composer_state tmux "$TARGET")" != empty ] || break
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 60 ] || fail "$VERSION: retained failed-restart composer did not settle"
CURRENT=$(bash "$ROOT/bin/fm-crew-state.sh" "$ID")
case "$CURRENT" in
  'state: failed '*) ;;
  *) fail "$VERSION: failed restart reconciled incorrectly: $CURRENT" ;;
esac
bash "$ROOT/bin/fm-control.sh" "$ID" exit
pass "$VERSION: fresh spawn, bare relaunch model, preserved work, brief/status, busy/idle, turn-end, cursorless composer, durable steer, interrupt, exit and failed-restart retention"
