#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2031 # Snippets expand inside the daemon() subshell, which sources the daemon library.
# Opt-in credentialed live guard for away-mode digest delivery into a real Claude
# Code primary under tmux. It proves, against the installed Claude Code:
#   1. Counterfactual: a digest of more than 2,000 characters typed inline arrives
#      folded (wrapped as pasted content, or cut to its tail), so it does NOT
#      classify as away-supervisor. This keeps the guard from passing vacuously if
#      Claude Code stops folding.
#   2. The same digest through escalate_flush's default is typed as a short pointer
#      line, arrives classifying as away-supervisor, and the named file holds every
#      event.
#   3. With the primary mid-turn, the Claude busy guard reads busy and the flush
#      defers; once the turn ends the flush delivers a line that still classifies.
#   4. A digest an unconfirmed submit left under Claude's invisible-character
#      review banner is submitted once by the next flush and still classifies.
#   5. A stale owned digest is cleared from the wrapped composer with Ctrl+U a row
#      at a time and never submitted.
# The stand-in Claude has no tools, no Chrome, and no MCP servers; it only receives
# text. Its project and FM_HOME are isolated temporary folders, and a few Haiku turns
# are submitted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_AFK_CLAUDE_DIGEST_LIVE_E2E claude tmux jq

OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-afk-claude-digest)
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/fmhome"
STATE="$FM_HOME_DIR/state"
SOCKET="fm-afk-digest-$$"
SESSION="fm-afk-digest-e2e"
SESSION_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null) \
  || fail "could not generate a session id"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr '[:upper:]' '[:lower:]')
REAL_TMUX=$(command -v tmux)

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT" "$STATE" "$LAB/bin"
# The daemon's bare tmux calls reach this test's private server through a PATH shim.
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCKET" >"$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"

# Claude Code refuses to nest inside another Claude session, so the inherited session
# markers are dropped from the lab's environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 200 -y 50 -c "$PROJECT" \
  "env $(unset_inherited) CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --tools '' --no-chrome --disallowedTools 'mcp__*' --strict-mcp-config --permission-mode default --session-id $SESSION_ID --settings '{\"feedbackDrafts\":\"off\"}'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30" \
  || fail "could not start the lab tmux session"
PANE=$(tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_id}') \
  || fail "could not read the lab pane id"

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

# The folder-trust dialog opens with its cursor on "No, exit": move onto the trusting
# option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 1 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) tmux -L "$SOCKET" send-keys -t "$SESSION" Enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
  return 0
}

# Every daemon call runs in a subshell with the lab's environment, as the detached
# daemon runs with the captain's harness handed over by the launcher.
daemon() {  # <shell snippet run with the daemon library sourced>
  (
    export PATH="$LAB/bin:$PATH" FM_HOME="$FM_HOME_DIR" FM_SUPERVISOR_TARGET="$PANE" \
      FM_SUPERVISOR_BACKEND=tmux FM_DAEMON_PRIMARY_HARNESS=claude
    LOG="$STATE/.supervise-daemon.log"
    # shellcheck source=bin/fm-supervise-daemon.sh
    . "$ROOT/bin/fm-supervise-daemon.sh"
    eval "$1"
  )
}

# Wait until the primary is idle with a proven-empty composer, answering the trust
# dialog on the way.
wait_ready() {  # <what>
  local i=0 shot
  while [ "$i" -lt 240 ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*) printf '%s\n' "$shot" >&2; fail "Claude Code $CLAUDE_VERSION exited while waiting for $1" ;;
    esac
    if ! answer_trust_dialog "$shot" \
      && daemon '! pane_is_busy "$PANE" tmux && [ "$(fm_backend_composer_state tmux "$PANE")" = empty ]'; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never became ready for $1"
}

# The newest transcript user row containing <text>, as plain text.
user_row() {  # <text>
  local transcript i=0 row
  while [ "$i" -lt 120 ]; do
    transcript=$(find "$HOME/.claude/projects" -name "$SESSION_ID.jsonl" 2>/dev/null | head -1)
    if [ -n "$transcript" ]; then
      row=$(jq -s -j --arg text "$1" '[.[] | select(.type == "user") | .message.content
        | if type == "string" then . else (map(select(.type == "text") | .text) | join("")) end
        | select(contains($text))] | last // empty' "$transcript")
      [ -n "$row" ] && { printf '%s' "$row"; return 0; }
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

classify() {  # <row>
  printf '%s' "$1" | "$OPERATIONAL_INPUT" classify 2>/dev/null || printf none
}

# Buffer eight events of about 330 characters each, tagged with <token>.
buffer_long_digest() {  # <token>
  local i
  for i in 1 2 3 4 5 6 7 8; do
    daemon "escalate_add \"\$STATE\" \"lab-$1-$i.status: blocked: $1 event $i - the review needs a design pick between keeping the legacy adapter interface and migrating every caller to the new typed registry; both branches pass their tests, so the choice is about long-term maintenance cost [key=$1-$i]\""
  done
}

export STATE
daemon 'afk_enter "$STATE"'

# 1. Counterfactual: the long digest typed inline.
wait_ready 'the counterfactual inline digest'
buffer_long_digest INLINECASE
daemon 'FM_INJECT_INLINE_MAX=100000 escalate_flush "$STATE"' \
  || fail "Claude Code $CLAUDE_VERSION: the inline long digest was not confirmed delivered"
row=$(user_row 'INLINECASE') || fail "Claude Code $CLAUDE_VERSION transcript holds no inline long-digest row"
kind=$(classify "$row")
# Claude Code folds the burst either by wrapping it as pasted content or by
# submitting only its tail; both move the header off the first character.
case "$row" in
  *'<pasted_content'*) shape='wrapped as pasted content' ;;
  'FIRSTMATE_OP: '*) shape='intact' ;;
  *) shape="cut to its last ${#row} characters" ;;
esac
[ "$kind" != away-supervisor ] \
  || fail "Claude Code $CLAUDE_VERSION delivered a long inline digest $shape that still classifies as away-supervisor; the counterfactual no longer reproduces, so re-measure INJECT_INLINE_MAX_DEFAULT before trusting this guard"
pass "Claude Code $CLAUDE_VERSION: a digest of more than 2,000 characters typed inline arrives $shape and classifies as $kind"

# 2. The same digest through the default flush: a short pointer line.
wait_ready 'the pointer digest'
buffer_long_digest POINTERCASE
daemon 'escalate_flush "$STATE"' \
  || fail "Claude Code $CLAUDE_VERSION: the pointer line was not confirmed delivered"
row=$(user_row "$STATE/.subsuper-digests/") \
  || fail "Claude Code $CLAUDE_VERSION transcript holds no pointer row"
kind=$(classify "$row")
[ "$kind" = away-supervisor ] \
  || fail "Claude Code $CLAUDE_VERSION delivered the pointer line as $kind, not away-supervisor: $row"
file=${row#*read it from }
file=${file%% (pre-read*}
[ -f "$file" ] || fail "the pointer row names no digest file: $row"
[ "$(grep -c 'POINTERCASE event' "$file")" -eq 8 ] || fail "the digest file does not hold all eight events: $file"
pass "Claude Code $CLAUDE_VERSION: a long digest arrives as a ${#row}-character pointer line that classifies as away-supervisor, with every event in its file"

# 3. Mid-turn: the busy guard defers, and the flush delivers after the turn.
wait_ready 'the mid-turn case'
tmux -L "$SOCKET" send-keys -t "$SESSION" -l 'Count from 1 to 300, one number per line, and nothing else.'
sleep 0.5
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
i=0
until daemon 'pane_is_busy "$PANE" tmux'; do
  [ "$i" -lt 60 ] || fail "Claude Code $CLAUDE_VERSION: the busy guard never saw the counting turn start"
  sleep 0.25
  i=$((i + 1))
done
daemon "escalate_add \"\$STATE\" 'lab-midturn.status: blocked: MIDTURNCASE the migration needs a window pick [key=midturn]'"
if daemon 'escalate_flush "$STATE"'; then
  fail "Claude Code $CLAUDE_VERSION: the flush typed into a primary that was mid-turn"
fi
grep -q 'inject deferred: supervisor pane busy' "$STATE/.supervise-daemon.log" \
  || fail "Claude Code $CLAUDE_VERSION: the mid-turn flush deferred for a reason other than the busy guard"
wait_ready 'the end of the counting turn'
daemon 'escalate_flush "$STATE"' \
  || fail "Claude Code $CLAUDE_VERSION: the deferred escalation was not delivered after the turn"
row=$(user_row 'MIDTURNCASE') || fail "Claude Code $CLAUDE_VERSION transcript holds no deferred escalation row"
kind=$(classify "$row")
[ "$kind" = away-supervisor ] \
  || fail "Claude Code $CLAUDE_VERSION delivered the deferred escalation as $kind: $row"
pass "Claude Code $CLAUDE_VERSION: a mid-turn escalation defers on the Claude busy guard and arrives intact after the turn"

# The number of transcript user rows containing <text>.
user_row_count() {  # <text>
  local transcript
  transcript=$(find "$HOME/.claude/projects" -name "$SESSION_ID.jsonl" 2>/dev/null | head -1)
  [ -n "$transcript" ] || { printf 0; return 0; }
  jq -s --arg text "$1" '[.[] | select(.type == "user") | .message.content
    | if type == "string" then . else (map(select(.type == "text") | .text) | join("")) end
    | select(contains($text))] | length' "$transcript"
}

# Type <typed> as the daemon does, press Enter once, and require Claude to hold it
# under its review banner, so the case cannot pass vacuously.
leave_digest_in_composer() {  # <typed> <what>
  local i=0
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 0.5
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
  until daemon 'fm_tmux_composer_owned_input "$PANE" "$TYPED"'; do
    [ "$i" -lt 20 ] || {
      printf '%s\n' "$(screen)" >&2
      fail "Claude Code $CLAUDE_VERSION no longer holds a marked digest after its first Enter; the $2 case cannot reproduce a digest left in the composer"
    }
    sleep 0.25
    i=$((i + 1))
  done
}

long_event() {  # <token>
  printf 'lab-%s.status: blocked: %s the release needs a go or no-go before the next deploy train, and the migration window closes at the end of the week, so the pick decides whether the schema change ships this sprint or waits for the next one [key=%s]' "$1" "$1" "$1"
}

# 4. A digest an unconfirmed submit left in the composer is submitted once by the
#    next flush, and the events it carried are not typed again.
wait_ready 'the owned-digest recovery case'
: > "$STATE/.subsuper-escalations"
daemon "escalate_add \"\$STATE\" '$(long_event OWNEDCASE)'"
TYPED=$(daemon 'fm_operational_input_encode away-supervisor "Supervisor escalate (1 event(s)): $(cat "$STATE/.subsuper-escalations") (pre-read; re-arm not needed — watcher daemon-managed)" t && printf "%s" "$t"')
export TYPED
leave_digest_in_composer "$TYPED" 'owned-digest recovery'
daemon '_owned_record_write "$STATE" "$PANE" tmux "$TYPED" 1 "$(cksum < "$STATE/.subsuper-escalations" | cut -d" " -f1)"'
daemon 'escalate_flush "$STATE"' \
  || fail "Claude Code $CLAUDE_VERSION: the owned digest left in the composer was not recovered"
grep -q 'inject recovered: submitted the owned digest' "$STATE/.supervise-daemon.log" \
  || fail "Claude Code $CLAUDE_VERSION: the flush delivered without the owned-digest recovery"
row=$(user_row 'OWNEDCASE') || fail "Claude Code $CLAUDE_VERSION transcript holds no recovered digest row"
kind=$(classify "$row")
[ "$kind" = away-supervisor ] \
  || fail "Claude Code $CLAUDE_VERSION delivered the recovered digest as $kind: $row"
wait_ready 'the end of the recovered digest turn'
[ "$(user_row_count OWNEDCASE)" -eq 1 ] \
  || fail "Claude Code $CLAUDE_VERSION received the recovered events $(user_row_count OWNEDCASE) times"
pass "Claude Code $CLAUDE_VERSION: a digest left under the review banner is submitted once by the next flush and classifies as away-supervisor"

# 5. A stale owned digest, whose events are no longer buffered, is cleared from a
#    wrapped Claude composer a row at a time and never submitted; the fresh
#    digest that follows arrives on its own.
wait_ready 'the stale owned-digest case'
: > "$STATE/.subsuper-escalations"
TYPED=$(daemon 'fm_operational_input_encode away-supervisor "Supervisor escalate (1 event(s)): $(long_event STALECASE) (pre-read; re-arm not needed — watcher daemon-managed)" t && printf "%s" "$t"')
export TYPED
leave_digest_in_composer "$TYPED" 'stale owned-digest'
daemon "escalate_add \"\$STATE\" 'lab-fresh.status: blocked: FRESHCASE the rollout needs a window pick [key=fresh]'"
daemon '_owned_record_write "$STATE" "$PANE" tmux "$TYPED" 1 stale'
daemon 'escalate_flush "$STATE"' \
  || fail "Claude Code $CLAUDE_VERSION: the fresh digest after a stale owned digest was not delivered"
grep -q 'cleared a stale owned digest' "$STATE/.supervise-daemon.log" \
  || fail "Claude Code $CLAUDE_VERSION: the stale owned digest was not cleared"
row=$(user_row 'FRESHCASE') || fail "Claude Code $CLAUDE_VERSION transcript holds no fresh digest row"
[ "$(classify "$row")" = away-supervisor ] \
  || fail "Claude Code $CLAUDE_VERSION delivered the fresh digest as $(classify "$row"): $row"
wait_ready 'the end of the fresh digest turn'
[ "$(user_row_count STALECASE)" -eq 0 ] \
  || fail "Claude Code $CLAUDE_VERSION received the stale owned digest"
pass "Claude Code $CLAUDE_VERSION: a stale owned digest is cleared from the wrapped composer a row at a time and never submitted"
