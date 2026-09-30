#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude Code Calm mod
# (.claude/mods/firstmate-calm) in a real Claude Code TUI under tmux, mirroring the
# Pi interactive case in tests/fm-calm-pi-extension.test.sh. It proves, against the
# installed Claude Code and the shipped project auto-load path (.claude/skills):
#   1. With CLAUDE_CODE_ENABLE_FUNCTION_HOOKS unset, the mod is a complete no-op even
#      with the per-home preference already on: no hooks module loads, /calm is not a
#      command, the stock working row shows, and tool rows draw as stock.
#   2. With the flag on, the sailboat replaces the working row and moves, tool rows and
#      a record-backed operational doorbell (the carrier Firstmate types into Claude
#      Code, which strips U+2063 from submitted prompts) draw at zero height, as does an
#      away-mode escalation typed through the daemon's real inject_msg, which must
#      still classify as away-supervisor after Claude Code 2.1.277+ removes its U+2063
#      mark; /calm restores them and persists off, /calm hides them again and persists
#      on, all without a Calm output row in the transcript.
#   3. `claude --continue` restores the transcript with those rows still hidden.
#   4. With Calm off, the supervision notes draw from a store bin/fm-branch-outcome.sh
#      writes: the session-start replay, new sailboat and anchor lines, and the latch
#      note, each drawn behind the plugin's `fm:` label rather than `firstmate-calm:`,
#      without moving a store marker or reaching the model, and a resume shows each
#      anchor once.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication and one trusted temporary folder. A few Haiku turns are submitted.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_CALM_LIVE_E2E claude tmux jq

MOD="$ROOT/.claude/mods/firstmate-calm"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"
CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-calm-claude-live)
PROJECT="$LAB/project"
FM_HOME_DIR="$LAB/fmhome"
DEBUG_LOG_OFF="$LAB/debug-off.log"
DEBUG_LOG_ON="$LAB/debug-on.log"
DEBUG_LOG_RESUME="$LAB/debug-resume.log"
SOCKET="fm-calm-claude-$$"
SESSION="fm-calm-claude-e2e"
# A fixed id for the flag-on session, so its transcript can be read back.
SESSION_ID=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null) \
  || fail "could not generate a session id"
SESSION_ID=$(printf '%s' "$SESSION_ID" | tr '[:upper:]' '[:lower:]')
REAL_TMUX=$(command -v tmux)
HULL='╲▁▁▁╱'
SAIL='◿│◣'

cleanup() {
  local i=0
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # Claude's debug logger may still be flushing into the lab for a moment, and would
  # recreate it after removal. Its argv carries the path unquoted.
  while [ "$i" -lt 20 ] && pgrep -f "debug-file $LAB/" >/dev/null 2>&1; do
    sleep 0.25
    i=$((i + 1))
  done
  fm_test_rm_tmproot "${LAB:-}" || true
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$PROJECT/.claude/skills" "$FM_HOME_DIR/config" "$FM_HOME_DIR/state" "$LAB/bin"
# The daemon's bare tmux calls reach this test's private server through a PATH shim.
printf '#!/bin/sh\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCKET" >"$LAB/bin/tmux"
chmod +x "$LAB/bin/tmux"
ln -s "$MOD" "$PROJECT/.claude/skills/firstmate-calm"
printf 'alpha\nbeta\ngamma\n' >"$PROJECT/notes.txt"
printf 'on\n' >"$FM_HOME_DIR/config/calm"

# Claude Code refuses to nest inside another Claude session, so the inherited session
# markers are dropped from the lab's environment; the flag is set per launch only.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+|CLAUDE_CONFIG_DIR)=' | cut -d= -f1 | sort -u)
}

# skipDangerousModePermissionPrompt keeps a machine that never accepted bypass mode from
# opening its one-time acceptance dialog, whose cursor starts on "No, exit".
launch() {  # <debug-log> <flag: 1|0> [claude args...]
  local log=$1 flag=$2 flag_env=''
  shift 2
  [ "$flag" = 1 ] && flag_env="CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1"
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PROJECT" \
    "env $(unset_inherited) $flag_env FM_HOME='$FM_HOME_DIR' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\",\"skipDangerousModePermissionPrompt\":true}' --debug-file '$log' $*; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 30"
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

send() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
}

enter() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

# The composer's rows: the text between the last two horizontal rules on screen.
composer_text() {  # <screen text>
  printf '%s\n' "$1" | awk 'index($0, "────────────────────") == 1 { seg++; next }
    { text[seg] = text[seg] $0 "\n" } END { if (seg > 0) printf "%s", text[seg - 1] }'
}

# Type <text> and submit it. Claude Code can take an Enter that lands inside the typed
# burst as a composer newline, so Enter is sent once the text has rendered and resent
# every 0.5 s while the composer still holds it.
submit() {  # <text>
  local head=${1:0:40} i=0
  send "$1"
  while [ "$i" -lt 40 ]; do
    case "$(composer_text "$(screen)")" in
      *"$head"*) break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  enter
  i=0
  while [ "$i" -lt 20 ]; do
    sleep 0.5
    case "$(composer_text "$(screen)")" in
      *"$head"*) enter ;;
      *) return 0 ;;
    esac
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never submitted: $head"
}

# Whether the screen is a startup dialog rather than the session: the folder-trust
# dialog draws its own option cursor with the composer's glyph, so it is answered
# before any text is matched.
dialog_open() {  # <screen text>
  case "$1" in
    *'trust this folder'*|*'Enter to confirm'*) return 0 ;;
  esac
  return 1
}

# The folder-trust dialog opens with its cursor on "No, exit", so Enter alone would
# end the session: move the cursor onto the trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

# Wait until the screen shows <text> (a fixed string), answering the folder-trust
# dialog on the way; the wait is iteration-counted so it stretches under load.
wait_screen() {  # <text> <what> [iterations]
  local text=$1 what=$2 limit=${3:-400} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    if dialog_open "$shot"; then
      answer_trust_dialog "$shot"
    else
      case "$shot" in
        *"$text"*) return 0 ;;
      esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $what"
}

wait_idle() {  # wait for the composer prompt with no dialog over it
  wait_screen '❯' 'the composer prompt'
  # A settled composer, not a dialog cursor: give a late dialog one more chance.
  sleep 1
  if dialog_open "$(screen)"; then
    wait_screen '❯' 'the composer prompt after the startup dialog'
  fi
}

# Type a slash command prefix without submitting and report whether the typeahead
# lists the mod's command; then clear the composer.
command_listed() {  # <command>
  local listed=0 i=0 shot
  send "/$1"
  while [ "$i" -lt 40 ]; do
    shot=$(screen)
    case "$shot" in
      *"Toggle Firstmate's Calm"*) listed=1; break ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  tmux -L "$SOCKET" send-keys -t "$SESSION" C-u
  sleep 0.3
  return $((1 - listed))
}

# The flag-on session transcript's user rows that contain <text>, as plain text; fails
# while that session has written no transcript.
transcript_user_rows() {  # <text>
  local transcript
  transcript=$(find "$HOME/.claude/projects" -name "$SESSION_ID.jsonl" 2>/dev/null | head -1)
  [ -n "$transcript" ] || return 1
  jq -j --arg text "$1" 'select(.type == "user") | .message.content
    | if type == "string" then . else (map(select(.type == "text") | .text) | join("")) end
    | select(contains($text))' "$transcript"
  return 0
}

hull_column() {  # <screen text>
  printf '%s\n' "$1" | awk -v hull="$HULL" 'index($0, hull) { print index($0, hull); exit }'
}

# The answer names words that live only in notes.txt, so the settled turn is told apart
# from the echoed prompt by "gamma" on screen with no working row left.
PROMPT='Run this exact bash command with the Bash tool: sleep 5; cat notes.txt   Then reply with one short sentence naming the three words.'

# The stock working row on this build: `✢ Propagating… (1s · ↓ 114 tokens)`.
working_row_shown() {  # <screen text>
  case "$1" in
    *'… ('*) return 0 ;;
  esac
  return 1
}

# Wait until the turn has settled: the answer is on screen and no working row or
# boat remains.
wait_settled() {  # <what> [iterations]
  local what=$1 limit=${2:-600} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
      *'gamma'*)
        if ! working_row_shown "$shot"; then
          case "$shot" in
            *"$HULL"*) ;;
            *) return 0 ;;
          esac
        fi
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never settled $what"
}

# Claude Code 2.1.280 logs `hooks module fm@<source> loaded`; 2.1.272 had no source suffix.
MODULE_LOADED='hooks module fm(@[^ ]+)? loaded'

# --- 1. Flag off: a complete no-op even with the preference on --------------------
launch "$DEBUG_LOG_OFF" 0
wait_idle
grep -q 'hooks modules not loaded' "$DEBUG_LOG_OFF" \
  || fail "Claude Code $CLAUDE_VERSION did not report hooks modules off with the flag unset"
if grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_OFF"; then
  fail "Claude Code $CLAUDE_VERSION loaded the Calm hooks module although the flag was unset"
fi
if command_listed calm; then
  fail "Claude Code $CLAUDE_VERSION lists /calm although the flag is unset"
fi
submit "$PROMPT"
# Sample every frame until the turn settles: the boat must never appear, and the
# stock working row must have been seen, or the flag-off case proved nothing.
saw_working=0
i=0
while [ "$i" -lt 600 ]; do
  off_frame=$(screen)
  case "$off_frame" in
    *"$HULL"*|*"$SAIL"*)
      printf '%s\n' "$off_frame" >&2
      fail "the working ship appeared although the flag is unset"
      ;;
    *'CLAUDE_EXIT='*)
      printf '%s\n' "$off_frame" >&2
      fail "Claude Code $CLAUDE_VERSION exited during the flag-off turn"
      ;;
  esac
  if working_row_shown "$off_frame"; then
    saw_working=1
  elif [ "$saw_working" -eq 1 ]; then
    case "$off_frame" in
      *'gamma'*) break ;;
    esac
  fi
  sleep 0.1
  i=$((i + 1))
done
[ "$saw_working" -eq 1 ] || fail "Claude Code $CLAUDE_VERSION showed no stock working row during the flag-off turn, so the no-op case cannot be judged"
wait_settled 'the turn with the flag off'
off_settled=$(screen)
case "$off_settled" in
  *'Bash('*|*'shell command'*) : ;;
  *)
    printf '%s\n' "$off_settled" >&2
    fail "the stock tool row did not draw with the flag unset"
    ;;
esac
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION with the flag unset: no hooks module, no /calm, stock working row, stock tool rows, preference on ignored"

# --- 2. Flag on: the boat, the hidden rows, the toggle, the persisted choice -------
launch "$DEBUG_LOG_ON" 1 --session-id "$SESSION_ID"
wait_idle
i=0
while [ "$i" -lt 100 ] && ! grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_ON"; do
  sleep 0.1
  i=$((i + 1))
done
grep -Eq "$MODULE_LOADED" "$DEBUG_LOG_ON" \
  || fail "Claude Code $CLAUDE_VERSION did not load the Calm hooks module from the project's .claude/skills path with the flag on"
# The engine logs one benign notice for every options-less hooks module ("options
# requested but its manifest declares no userConfig"); anything else is a real problem.
if grep -E '\[(WARN|ERROR)\].*(plugin fm[:@ ]|\[fm\]|module fm@)' "$DEBUG_LOG_ON" | grep -v 'declares no userConfig' >&2; then
  fail "Claude Code $CLAUDE_VERSION loaded the Calm mod with a warning or error"
fi
command_listed calm || fail "Claude Code $CLAUDE_VERSION does not list /calm with the flag on"
submit "$PROMPT"
wait_screen "$HULL" 'the working ship during a real turn' 200
boat_one=$(screen)
case "$boat_one" in
  *"$SAIL"*) : ;;
  *)
    printf '%s\n' "$boat_one" >&2
    fail "the working ship lost its sail"
    ;;
esac
column_one=$(hull_column "$boat_one")
column_two=$column_one
i=0
while [ "$i" -lt 120 ]; do
  boat_two=$(screen)
  column_two=$(hull_column "$boat_two")
  if [ -n "$column_two" ] && [ "$column_two" != "$column_one" ]; then
    break
  fi
  sleep 0.1
  i=$((i + 1))
done
[ -n "$column_two" ] && [ "$column_two" != "$column_one" ] \
  || fail "the working ship never moved (hull stayed at column $column_one)"
wait_settled 'the turn with the flag on'
on_settled=$(screen)
case "$on_settled" in
  *"$HULL"*|*"$SAIL"*) fail "the working ship stayed on screen after the turn settled" ;;
  *'Bash('*|*'shell command'*|*'notes.txt)'*)
    printf '%s\n' "$on_settled" >&2
    fail "a tool row drew while Calm was on"
    ;;
esac

# Claude Code strips U+2063 from submitted prompts, so Firstmate types a plain doorbell
# naming a record that holds the envelope; that doorbell row draws at zero height while
# the answer stays visible. The answer token lives only in the record.
DOORBELL_TEXT='Firstmate operational input waiting'
operational=$(printf 'signal: %s/state/probe.status changed. Reply with exactly OPERATIONAL_PROCESSED and nothing else.' "$LAB" \
  | FM_HOME="$FM_HOME_DIR" "$OPERATIONAL_INPUT" record watcher) \
  || fail "could not publish the operational probe record"
case "$operational" in
  *"$DOORBELL_TEXT"*) : ;;
  *) fail "the operational probe is not a record-backed doorbell: $operational" ;;
esac
send "$operational"
sleep 1
enter
# A long line typed in one burst can leave Claude Code's first Enter inside its paste
# handling; like Firstmate's own submit primitive, retry Enter only, never retype.
i=0
while [ "$i" -lt 4 ]; do
  sleep 2
  case "$(screen)" in
    *"❯ : $DOORBELL_TEXT"*) enter ;;
    *) break ;;
  esac
  i=$((i + 1))
done
wait_screen 'OPERATIONAL_PROCESSED' 'the operational answer' 600
sleep 1
operational_screen=$(screen)
case "$operational_screen" in
  *"$DOORBELL_TEXT"*|*'invisible character'*)
    printf '%s\n' "$operational_screen" >&2
    fail "the operational doorbell row drew while Calm was on"
    ;;
esac

# An away-mode escalation delivered through the daemon's real injection path is
# confirmed delivered, draws at zero height, and reaches the transcript as input the
# canonical owner classifies as away-supervisor, with or without its U+2063 mark.
wait_settled 'the operational turn'
# The daemon addresses the supervisor by pane id, as it does from $TMUX_PANE: its
# tmux presence check refuses a bare session name.
supervisor_pane=$(tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_id}') \
  || fail "could not read the lab session's pane id"
(
  export PATH="$LAB/bin:$PATH" FM_HOME="$FM_HOME_DIR" FM_SUPERVISOR_TARGET="$supervisor_pane" FM_SUPERVISOR_BACKEND=tmux
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  afk_enter "$FM_HOME_DIR/state"
  inject_msg 'Supervisor escalate (1 event(s)): AWAY_PROBE_ROW escalation. Reply with exactly AWAY_PROCESSED and nothing else.' "$FM_HOME_DIR/state"
) || fail "Claude Code $CLAUDE_VERSION: the daemon could not confirm delivery of an away-mode escalation"
rm -f "$FM_HOME_DIR/state/.afk"
wait_screen 'AWAY_PROCESSED' 'the away-mode escalation answer' 600
sleep 1
away_screen=$(screen)
case "$away_screen" in
  *'AWAY_PROBE_ROW'*)
    printf '%s\n' "$away_screen" >&2
    fail "the away-mode escalation row drew while Calm was on"
    ;;
esac
away_row=$(transcript_user_rows 'AWAY_PROBE_ROW') \
  || fail "Claude Code $CLAUDE_VERSION wrote no transcript for session $SESSION_ID"
[ -n "$away_row" ] || fail "Claude Code $CLAUDE_VERSION transcript holds no away-mode escalation row"
away_kind=$(printf '%s' "$away_row" | "$OPERATIONAL_INPUT" classify) || away_kind=none
[ "$away_kind" = away-supervisor ] \
  || fail "Claude Code $CLAUDE_VERSION delivered the away-mode escalation as $away_kind, not away-supervisor: $away_row"
case "$away_row" in
  $'\xE2\x81\xA3'*) away_mark='with its U+2063 mark' ;;
  *) away_mark='without its U+2063 mark' ;;
esac

# /calm off: rows restore, the preference persists off, no Calm output row.
submit '/calm'
wait_screen 'shell command' 'the restored tool row after /calm off' 200
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "/calm did not persist off"
restored=$(screen)
case "$restored" in
  *"$DOORBELL_TEXT"*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off did not restore the operational user row"
    ;;
esac
# The toggle answers with a transient toast under the prompt, never a transcript row:
# the plugin's name must leave the screen once the toast expires.
case "$restored" in
  *'Calm off'*) : ;;
  *)
    printf '%s\n' "$restored" >&2
    fail "/calm off showed no Calm off notice"
    ;;
esac
i=0
while [ "$i" -lt 60 ]; do
  restored=$(screen)
  case "$restored" in
    *'fm: Calm'*|*'Calm off'*) ;;
    *) break ;;
  esac
  sleep 0.25
  i=$((i + 1))
done
case "$restored" in
  *'fm: Calm'*|*'Calm off'*)
    printf '%s\n' "$restored" >&2
    fail "/calm left a Calm row in the transcript after its notice should have expired"
    ;;
esac

# /calm on: rows hide again, the preference persists on.
submit '/calm'
i=0
while [ "$i" -lt 200 ]; do
  hidden_again=$(screen)
  case "$hidden_again" in
    *'Bash('*|*'shell command'*|*"$DOORBELL_TEXT"*) ;;
    *) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
case "$hidden_again" in
  *'Bash('*|*'shell command'*|*"$DOORBELL_TEXT"*)
    printf '%s\n' "$hidden_again" >&2
    fail "/calm on did not hide the rows again"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "/calm did not persist on"
case "$hidden_again" in
  *'gamma'*|*'OPERATIONAL_PROCESSED'*) : ;;
  *) fail "Calm on hid a genuine assistant reply" ;;
esac
send '/exit'
enter
sleep 2
pass "Claude Code $CLAUDE_VERSION with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool rows, the record-backed operational doorbell, and the daemon-injected away-mode escalation (arriving $away_mark and classifying as away-supervisor) draw at zero height, /calm restores and re-hides them while persisting the shared preference"

# --- 3. Resume: the restored transcript keeps the hidden rows hidden ---------------
launch "$DEBUG_LOG_RESUME" 1 --continue
wait_screen 'gamma' 'the resumed transcript' 400
sleep 1
resumed=$(screen)
case "$resumed" in
  *'Bash('*|*'shell command'*|*"$DOORBELL_TEXT"*)
    printf '%s\n' "$resumed" >&2
    fail "the resumed transcript drew a row Calm hides"
    ;;
esac
[ "$(cat "$FM_HOME_DIR/config/calm")" = on ] || fail "resume changed the persisted choice"
send '/exit'
enter
sleep 1
pass "Claude Code $CLAUDE_VERSION resumes the transcript with Calm's hidden rows still hidden and the preference intact"

# --- 4. Supervision notes: shown with Calm off, from the store the host writes ----
STATE_DIR="$FM_HOME_DIR/state"
DEBUG_LOG_NOTES="$LAB/debug-notes.log"
mkdir -p "$STATE_DIR"
outcome() {
  FM_HOME="$FM_HOME_DIR" bash "$ROOT/bin/fm-branch-outcome.sh" "$@" >/dev/null \
    || fail "bin/fm-branch-outcome.sh $1 failed in the lab home"
}
outcome append --task fm-live-a --verdict captain --summary 'LIVE_PROCESSED_CAPTAIN acknowledged earlier'
outcome append --task fm-live-b --verdict captain --summary 'LIVE_REPLAY_CAPTAIN still open'
outcome mark-read --through 2
outcome mark-processed --through 1
printf 'key=live-key\nerrors=0\ncooldown=0\nretry_after=0\n' >"$STATE_DIR/.supervision-host-health"
printf 'off\n' >"$FM_HOME_DIR/config/calm"
launch "$DEBUG_LOG_NOTES" 1
wait_idle
wait_screen 'fm: ⚓ [seq 2] fm-live-b: LIVE_REPLAY_CAPTAIN still open' 'the session-start replay of an unprocessed captain outcome' 200
outcome append --task fm-live-c --verdict routine --summary 'LIVE_ROUTINE_NOTE worker healthy'
outcome append --task fm-live-d --verdict routine --summary 'LIVE_SILENT_NOTE no change' --silent true
outcome append --task fm-live-e --verdict captain --summary 'LIVE_NEW_CAPTAIN PR ready for review'
wait_screen 'fm: ⛵ fm-live-c: LIVE_ROUTINE_NOTE worker healthy' 'the routine sailboat note' 200
wait_screen 'fm: ⚓ [seq 5] fm-live-e: LIVE_NEW_CAPTAIN PR ready for review' 'the new captain anchor line' 200
printf 'key=live-key\nerrors=2\ncooldown=300\nretry_after=0\n' >"$STATE_DIR/.supervision-host-health"
wait_screen 'fm: ⛵ Supervision session paused after repeated engine errors' 'the latch-trip note' 200
notes_screen=$(screen)
case "$notes_screen" in
  *'LIVE_PROCESSED_CAPTAIN'*|*'LIVE_SILENT_NOTE'*)
    printf '%s\n' "$notes_screen" >&2
    fail "a processed captain outcome or a silent routine outcome drew a supervision note"
    ;;
  *'firstmate-calm:'*)
    printf '%s\n' "$notes_screen" >&2
    fail "a supervision note drew behind the old firstmate-calm label"
    ;;
esac
[ "$(cat "$STATE_DIR/.branch-outcomes-cursor")" = 2 ] || fail "the supervision notes moved the store's read cursor"
[ "$(cat "$STATE_DIR/.branch-outcomes-processed")" = 1 ] || fail "the supervision notes moved the processed marker"
[ "$(cat "$FM_HOME_DIR/config/calm")" = off ] || fail "the supervision notes changed the Calm preference"
# The notes never reach the model: a real turn asked to quote them quotes none. The
# answer token is spelled out rather than typed, so the echoed prompt cannot match it.
send 'Quote verbatim every line of this conversation that contains a sailboat emoji or an anchor emoji, other than this request. If there are none, reply with only the words green, harbor, and lantern in uppercase joined by underscores.'
enter
wait_screen 'GREEN_HARBOR_LANTERN' 'the model reporting that it sees no supervision note' 400
sleep 2
send '/exit'
enter
sleep 2
notes_session=$(grep -rlF 'GREEN_HARBOR_LANTERN' "$HOME/.claude/projects/"*"$(basename "$LAB" | tr -c 'A-Za-z0-9\n' -)"* 2>/dev/null | head -n 1)
[ -n "$notes_session" ] || fail "could not find the session transcript Claude Code stored for the notes turn"
if jq -e 'select(.type == "assistant") | .message.content | tostring | test("LIVE_")' "$notes_session" >/dev/null 2>&1; then
  fail "the model quoted a supervision note, so the notes reached its context: $notes_session"
fi
# Claude Code 2.1.283 keeps each note in the session as a display-only entry and
# restores it on resume, so the resumed session replays only what it has not shown.
outcome append --task fm-live-f --verdict captain --summary 'LIVE_WHILE_CLOSED captain outcome'
launch "$DEBUG_LOG_NOTES" 1 --continue
wait_screen 'fm: ⚓ [seq 6] fm-live-f: LIVE_WHILE_CLOSED captain outcome' 'the replay of an outcome recorded while the session was closed' 400
sleep 4
resumed_notes=$(screen)
[ "$(printf '%s\n' "$resumed_notes" | grep -c 'LIVE_REPLAY_CAPTAIN')" = 1 ] || {
  printf '%s\n' "$resumed_notes" >&2
  fail "the resumed session did not show the earlier anchor exactly once"
}
send '/exit'
enter
sleep 1
pass "Claude Code $CLAUDE_VERSION with Calm off shows the supervision notes: the session-start anchor for an unprocessed captain outcome, a sailboat for a new routine outcome, an anchor for a new captain outcome, and the latch-trip note, each behind the fm: label, skipping processed and silent outcomes, moving no store marker, never reaching the model, and on resume showing each anchor once"
