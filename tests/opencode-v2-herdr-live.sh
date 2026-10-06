#!/usr/bin/env bash
# Herdr branch of the OpenCode V2 opt-in live guard.
# Uses an independent fixture allocation, real production spawn/send/control,
# and only explicitly helper-scoped calls in a named non-default Herdr lab.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_LIVE_E2E opencode herdr git jq node
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ORIGINAL_PATH=$PATH
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name opencode-v2-live)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-herdr.XXXXXX")
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT"
LAB_TMUX_DIR=
IDS=()
cleanup() {
  local rc=$? id
  trap - EXIT
  # Reap both intake processes before removing their session, even when one
  # refused a lock. Otherwise cleanup itself makes the sibling's read fail.
  [ -z "${FIRST_PID:-}" ] || wait "$FIRST_PID" 2>/dev/null || true
  [ -z "${SECOND_PID:-}" ] || wait "$SECOND_PID" 2>/dev/null || true
  if [ -n "$LAB_TMUX_DIR" ]; then
    tmux -S "$LAB_TMUX_DIR/tmux-$(id -u)/default" kill-server 2>/dev/null || true
  fi
  [ ! -f "$FM_HOME/.fm-lab-home" ] || "$LAB_HOME_HELPER" teardown "$FM_HOME" || rc=1
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  if [ -n "${FM_OPENCODE_LIVE_EVIDENCE:-}" ]; then
    mkdir -p "$FM_OPENCODE_LIVE_EVIDENCE"
    cp "$LAB"/*.txt "$FM_OPENCODE_LIVE_EVIDENCE/" 2>/dev/null || true
  fi
  for id in ${IDS[@]+"${IDS[@]}"}; do fm_test_rm_tmproot "/tmp/fm-$id"; done
  chmod -R u+w "$LAB"
  fm_test_rm_tmproot "$LAB"
  fm_test_cleanup
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
"$LAB_HOME_HELPER" create "$FM_HOME" >/dev/null
mkdir -p "$LAB/shim" "$LAB/project"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'herdr\n' > "$FM_HOME/config/backend"
printf 'off\n' > "$FM_HOME/config/herdr-presentation-spaces"
# Include the real legacy project plugins: the scratch-repository-only guard
# cannot expose their notification footer. Never allocate from the fleet pool.
cp -R "$ROOT/.opencode" "$LAB/project/"
fm_git_init_commit "$LAB/project"
cat > "$LAB/shim/treehouse" <<'SH'
#!/usr/bin/env bash
case "$1" in
  get) printf '%s\n' "$FM_OC_FIXTURE" ;;
  return) printf '%s\n' "$*" >> "$FM_HOME/returns" ;;
  *) exit 1 ;;
esac
SH
cat > "$LAB/shim/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if [ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ]; then
  [ "${args[$((n-1))]}" = "$HERDR_LAB_SESSION" ] || exit 97
  args=("${args[@]:0:$((n-2))}")
elif [ "$*" != 'status --json' ]; then
  echo 'lab wrapper refused unscoped call' >&2; exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
SH
chmod +x "$LAB/shim/"*
export HERDR_LAB_SESSION HERDR_LAB_HELPER ORIGINAL_PATH
export PATH="$LAB/shim:$PATH" HERDR_SESSION="$HERDR_LAB_SESSION" FM_SPAWN_NO_GUARD=1
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH TMUX TMUX_PANE
VERSION=$(opencode --version)
MODEL=${FM_OPENCODE_LIVE_MODEL:-opencode/muse-spark-1.3-contributor-free}
case "$MODEL" in opencode/*free*|opencode/*contributor*) ;; *) fail 'Herdr live guard requires a free/contributor model' ;; esac
STATUS=$(PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" status --json)
printf '%s\n' "$STATUS" > "$LAB/version.txt"
HERDR_SOCKET_PATH=$(printf '%s' "$STATUS" | jq -r '.server.socket')
export HERDR_SOCKET_PATH
WS=$(PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$LAB/project" --label firstmate --no-focus)
HERDR_PANE_ID=$(printf '%s' "$WS" | jq -r '.result.root_pane.pane_id')
export HERDR_PANE_ID HERDR_ENV=1
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
capture() { fm_backend_capture herdr "$1" 100; }
wait_text() {
  local file=$1 text=$2 target=$3 i=0
  while [ "$i" -lt 180 ]; do
    if [ -f "$file" ] && grep -Fq "$text" "$file"; then return 0; fi
    i=$((i + 1)); sleep 0.5
  done
  capture "$target" > "$LAB/failure.txt" || true
  fail "$VERSION: timed out waiting for $text"
}
wait_idle() {
  local id=$1 target=$2 i=0 verdict
  while [ "$i" -lt 120 ]; do
    verdict=$(fm_busy_classify herdr "$target" opencode "$id" "$FM_HOME/state")
    [ "$verdict" != 'idle opencode-plugin' ] || return 0
    i=$((i + 1)); sleep 0.5
  done
  fail "$VERSION: busy state did not settle: $verdict"
}
prepare() {
  local id=$1
  IDS+=("$id")
  mkdir -p "$FM_HOME/data/$id" "$LAB/a-long-fixture-directory-to-exercise-shortened-home-location-footers/$id"
  FM_OC_FIXTURE="$LAB/a-long-fixture-directory-to-exercise-shortened-home-location-footers/$id/wt"
  export FM_OC_FIXTURE
  git clone -q --no-local "$LAB/project" "$FM_OC_FIXTURE"
  cat > "$FM_HOME/data/$id/brief.md" <<BRIEF
# Task
Read only this brief, then append a newline-terminated line 'working: brief processed' to $FM_HOME/state/$id.status.
Reply OK and stop. If it already contains that line, append 'working: relaunched' instead.
Your steering inbox is $FM_HOME/state/$id.inbox.
When an instruction arrives, read every *.msg there and acknowledge it by moving it into handled/.
Do not inspect or edit project files. Do not delegate or run fleet supervision.
BRIEF
}
spawn() { bash "$ROOT/bin/fm-spawn.sh" "$1" "$LAB/project" --scout --harness opencode --model "$MODEL" --effort high; }
target() { sed -n 's/^window=//p' "$FM_HOME/state/$1.meta"; }
ID="oc-herdr-$$"
prepare "$ID"
# A genuinely multi-line brief goes through the production file-pointer path.
for i in $(seq 1 30); do printf 'Probe note %s: no additional action.\n' "$i" >> "$FM_HOME/data/$ID/brief.md"; done
spawn "$ID"
TARGET=$(target "$ID")
wait_text "$FM_HOME/state/$ID.status" 'brief processed' "$TARGET"
wait_idle "$ID" "$TARGET"
[ -f "$FM_HOME/state/$ID.turn-ended" ] || fail 'native turn-end absent'
# An event record from another incarnation must not prove an idle worker.
GEN=$(cat "$FM_HOME/state/$ID.busy-gen")
printf 'stale-incarnation\n' > "$FM_HOME/state/$ID.busy-gen"
[ "$(fm_busy_classify herdr "$TARGET" opencode "$ID" "$FM_HOME/state")" = 'unknown gen-mismatch' ] || fail 'stale generation was trusted'
printf '%s\n' "$GEN" > "$FM_HOME/state/$ID.busy-gen"
[ "$(fm_backend_composer_state herdr "$TARGET")" = empty ] || fail 'cursorless idle composer unreadable'
capture "$TARGET" > "$LAB/idle.txt"
pass "$VERSION: fresh shared-workspace spawn, long brief, native busy/idle and turn-end"
bash "$ROOT/bin/fm-send.sh" "$ID" "Append 'working: steer processed' to $FM_HOME/state/$ID.status and acknowledge this message. Then stop."
wait_text "$FM_HOME/state/$ID.status" 'steer processed' "$TARGET"
wait_idle "$ID" "$TARGET"
find "$FM_HOME/state/$ID.inbox/handled" -name '*.msg' | grep -q . || fail 'durable steer not acknowledged'
bash "$ROOT/bin/fm-send.sh" "$ID" 'Run sleep 30 in the shell tool and wait for it. Then stop.'
i=0
while [ "$i" -lt 120 ]; do
  case "$(capture "$TARGET")" in *'esc interrupt'*) break ;; esac
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 120 ] || fail 'running turn not observed'
bash "$ROOT/bin/fm-control.sh" "$ID" interrupt
wait_idle "$ID" "$TARGET"
bash "$ROOT/bin/fm-control.sh" "$ID" exit
[ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail 'exit left agent alive'
printf 'preserved\n' > "$FM_OC_FIXTURE/progress.txt"
bash "$ROOT/bin/fm-control.sh" "$ID" relaunch --note 'Continue the runtime probe.'
TARGET=$(target "$ID")
wait_text "$FM_HOME/state/$ID.status" 'relaunched' "$TARGET"
wait_idle "$ID" "$TARGET"
[ "$(cat "$FM_OC_FIXTURE/progress.txt")" = preserved ] || fail 'relaunch changed work'
[ "$(sed -n 's/^model=//p' "$FM_HOME/state/$ID.meta")" = "$MODEL" ] || fail 'relaunch lost model'
bash "$ROOT/bin/fm-control.sh" "$ID" exit
pass "$VERSION: durable steer acknowledgement, interrupt, exit and control relaunch preserve work/model"
# Fresh timeout closes and returns only a clean fixture slot, leaving no
# blocking receipt. It must also retain the exact pre-close startup screen.
FAIL_ID="oc-herdr-fail-$$"
prepare "$FAIL_ID"
if FM_OPENCODE_READY_POLLS=0 spawn "$FAIL_ID" > "$LAB/timeout.txt" 2>&1; then fail 'forced timeout succeeded'; fi
[ ! -e "$FM_HOME/state/$FAIL_ID.treehouse-lease" ] || fail 'timeout left a blocking lease receipt'
[ ! -e "$FM_HOME/state/$FAIL_ID.meta" ] || fail 'timeout left a provisional task record'
find "/tmp/fm-$FAIL_ID" -name 'opencode-startup-*.log' | grep -q . || fail 'fresh timeout screen absent'
pass "$VERSION: real fresh readiness rollback removes its lease receipt"
# Two independent allocations and briefs, concurrently targeting the same home.
FIRST="oc-herdr-one-$$" SECOND="oc-herdr-two-$$"
prepare "$FIRST"; FIRST_WT=$FM_OC_FIXTURE
prepare "$SECOND"; SECOND_WT=$FM_OC_FIXTURE
FM_OC_FIXTURE="$FIRST_WT" spawn "$FIRST" > "$LAB/concurrent-one.txt" 2>&1 &
FIRST_PID=$!
FM_OC_FIXTURE="$SECOND_WT" spawn "$SECOND" > "$LAB/concurrent-two.txt" 2>&1 &
SECOND_PID=$!
FIRST_RC=0 SECOND_RC=0
wait "$FIRST_PID" || FIRST_RC=$?
wait "$SECOND_PID" || SECOND_RC=$?
# Concurrent CLI intake is deliberately fail-closed on the home/project lock.
# Prove that the refusal is before allocation and that an ordinary retry works.
for pair in "$FIRST:$FIRST_RC:$FIRST_WT:concurrent-one" "$SECOND:$SECOND_RC:$SECOND_WT:concurrent-two"; do
  id=${pair%%:*}; rest=${pair#*:}; rc=${rest%%:*}; rest=${rest#*:}; wt=${rest%:*}; log=${rest##*:}
  if [ "$rc" -ne 0 ]; then
    grep -Eq 'task set is locked|slot allocation or return is in progress' "$LAB/$log.txt" || fail "concurrent intake failed beyond its lock: $(cat "$LAB/$log.txt")"
    [ ! -e "$FM_HOME/state/$id.meta" ] && [ ! -e "$FM_HOME/state/$id.treehouse-lease" ] || fail 'contended intake left an acquisition'
    FM_OC_FIXTURE="$wt" spawn "$id" >> "$LAB/$log.txt" 2>&1
  fi
done
for id in "$FIRST" "$SECOND"; do
  t=$(target "$id")
  wait_text "$FM_HOME/state/$id.status" 'brief processed' "$t"
  wait_idle "$id" "$t"
  bash "$ROOT/bin/fm-control.sh" "$id" exit
done
pass "$VERSION: concurrent intake refuses lock contention before allocation; sequential retry processes both briefs"

# Surface-only probes use the same fixture and guarded CLI; no model request
# is needed to prove startup readiness in a new window and a genuine split.
ready_surface() {
  local pane=$1 i=0
  while [ "$i" -lt 60 ]; do
    [ "$(fm_backend_composer_state herdr "$HERDR_LAB_SESSION:$pane")" != empty ] || return 0
    i=$((i + 1)); sleep 0.5
  done
  capture "$HERDR_LAB_SESSION:$pane" > "$LAB/surface-failure.txt" || true
  fail "$VERSION: surface composer unreadable"
}
surface_launch() {
  local pane=$1 cfg=$2 command
  command="cd $(printf '%q' "$FM_OC_FIXTURE") && OPENCODE_CONFIG_CONTENT=$(printf '%q' "$cfg") opencode --standalone --auto"
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$pane" "$command" >/dev/null
}
CFG=$(jq -cn --arg model "$MODEL" '{model:$model,agents:{build:{model:$model}}}')
NEW=$(PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$FM_OC_FIXTURE" --label surface --no-focus)
PANE=$(printf '%s' "$NEW" | jq -r '.result.root_pane.pane_id')
surface_launch "$PANE" "$CFG"
ready_surface "$PANE"
capture "$HERDR_LAB_SESSION:$PANE" > "$LAB/new-window.txt"
SPLIT=$(PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane split "$PANE" --direction right --ratio 0.5 --cwd "$FM_OC_FIXTURE" --no-focus)
SPLIT_PANE=$(printf '%s' "$SPLIT" | jq -er '.result.pane.pane_id')
surface_launch "$SPLIT_PANE" "$CFG"
ready_surface "$SPLIT_PANE"
capture "$HERDR_LAB_SESSION:$SPLIT_PANE" > "$LAB/split.txt"
pass "$VERSION: fresh new-window and true split-pane composers are readable"

# A separate disposable OpenCode profile avoids inherited auto mode. Herdr's
# own config/socket is unchanged: XDG variables exist only in the pane command.
PERM=$(PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" workspace create --cwd "$FM_OC_FIXTURE" --label permission --no-focus)
PERM_PANE=$(printf '%s' "$PERM" | jq -r '.result.root_pane.pane_id')
PERM_CFG=$(jq -cn --arg model "$MODEL" '{model:$model,agents:{build:{model:$model,permissions:[{action:"shell",resource:"*",effect:"ask"}]}}}')
PERM_COMMAND="cd $(printf '%q' "$FM_OC_FIXTURE") && XDG_CONFIG_HOME=$(printf '%q' "$LAB/occonfig") XDG_DATA_HOME=$(printf '%q' "$LAB/ocdata") XDG_STATE_HOME=$(printf '%q' "$LAB/ocstate") XDG_CACHE_HOME=$(printf '%q' "$LAB/occache") OPENCODE_CONFIG_CONTENT=$(printf '%q' "$PERM_CFG") opencode --standalone"
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane run "$PERM_PANE" "$PERM_COMMAND" >/dev/null
ready_surface "$PERM_PANE"
[ "$(fm_backend_send_text_submit herdr "$HERDR_LAB_SESSION:$PERM_PANE" 'Run pwd in the shell tool, then stop.' 3 0.5 0)" = empty ] || fail 'manual probe submission failed'
i=0
while [ "$i" -lt 90 ]; do
  capture "$HERDR_LAB_SESSION:$PERM_PANE" > "$LAB/permission.txt"
  grep -q 'Permission required' "$LAB/permission.txt" && break
  i=$((i + 1)); sleep 0.5
done
[ "$i" -lt 90 ] || fail 'manual permission prompt absent'
[ "$(fm_backend_composer_state herdr "$HERDR_LAB_SESSION:$PERM_PANE")" != empty ] || fail 'permission prompt falsely allows typed input'
# Escape never selects Allow once or Always allow; teardown owns final stop.
PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PERM_PANE" escape >/dev/null
pass "$VERSION: manual permission prompt refuses typed delivery; no permission accepted"
