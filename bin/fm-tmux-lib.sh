#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE tmux source for delivery-busy detection, composer capture primitives,
# and verified submit.
# Both the away-mode daemon and bin/fm-send.sh reach these primitives through
# backend dispatch, while bin/fm-composer-lib.sh owns the shared verdict.
#
# Composer shapes and verdicts are owned by bin/fm-composer-lib.sh.
# This file owns only tmux's styled capture, cursor and Pi identity primitives,
# delivery busy read, agent-submit conversions, and owned-input recovery for
# shell commands and agent composers.
# Styled captures remain internal; fm-peek and every human-facing capture stay
# plain.
#
# OpenCode's busy-queued Enter conversion accepts only structurally proven
# pending text after retries, while the separate turn-started conversion accepts
# an unknown post-Enter composer only after this submit observed an idle baseline
# become busy.
# The queued-Enter policy itself lives in fm_composer_queued_enter_verdict
# (bin/fm-composer-lib.sh); this file supplies tmux's pane-busy primitive.
#
# FM_COMPOSER_IDLE_RE is interpreted by the shared classifier with its structural
# and styling safety gates.
# FM_BUSY_REGEX overrides the rendered delivery-busy matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The matching below serves only delivery guards: the submit
# acknowledgement and the away-mode supervisor-pane busy guard. Both ask about
# the pane receiving input, not the state of a recorded worker task. Matching
# stays harness-scoped so one harness's output cannot make another read busy.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer classification is NOT owned here: every shape, glyph, border
# family, geometry rule, and verdict decision lives in the shared
# bin/fm-composer-lib.sh (fm_composer_classify_screen), sourced below and
# reused by every backend adapter so the decision cannot drift. This file
# keeps only tmux's genuine capture-side primitives - the styled pane
# capture, the #{cursor_y} cursor read, the pi foreground-process identity
# probe, and the capability descriptor - plus the busy detection and submit
# cores that consume the shared verdict.

# The sibling directory is derived without forking dirname, because a backend
# probe can re-source this adapter inside a subshell on every watcher cycle.
_FM_TMUX_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_TMUX_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_TMUX_LIB_DIR=.
# shellcheck source=bin/fm-composer-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-composer-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_TMUX_LIB_DIR


# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's/cursor's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# --- tmux composer capture and capability primitives ------------------------
#
# These four functions are the ONLY tmux-specific composer knowledge left:
# how to capture a styled screen, how to read the cursor row, how to probe a
# live pi agent, and the static capability facts. Every shape, glyph, border
# family, and verdict decision lives in the shared owner
# (bin/fm-composer-lib.sh, fm_composer_classify_screen), so a new harness
# shape is taught there once and never here.

# fm_tmux_composer_capture: the visible pane WITH ANSI styling. The styled
# capture is consumed internally by the classifier and is NEVER surfaced
# (fm-peek and every human/LLM-facing path stay plain).
fm_tmux_composer_capture() {  # <target>
  tmux capture-pane -e -p -t "$1" -S 0 -E - 2>/dev/null
}

# fm_tmux_composer_cursor_row: the pane's cursor row, zero-based, relative to
# the visible pane - tmux's genuine primitive that no other backend has.
fm_tmux_composer_cursor_row() {  # <target>
  tmux display-message -p -t "$1" '#{cursor_y}' 2>/dev/null
}

# fm_tmux_composer_caps: the tmux capability descriptor - static data, not
# logic (see the capability model in bin/fm-composer-lib.sh).
fm_tmux_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n'
}

# fm_tmux_composer_identity: the tmux agent-identity probe backing the
# separated (pi) composer shape, tmux's analogue of herdr's native
# `agent get`. It answers only for pi, from two live signals:
#   - identity: the pane tty's FOREGROUND process group (pgid = tpgid, the
#     same scoping as fm_backend_tmux_foreground_comms) contains a pi-family
#     process (pi, pi-signed, pi-launcher - docs/verification/
#     runtime-backends.md "Agent liveness name sources"), falling back to
#     tmux's own foreground-derived #{pane_current_command}. A pane whose
#     agent died to a shell has no pi foreground process and gets NO identity,
#     which is exactly what keeps the strict blank-row rule honest: a blank
#     row between two stale rules stays unknown.
#   - status: pi's verified busy footer via fm_pane_is_busy, mapped onto the
#     idle/working vocabulary herdr's probe reports natively.
# Prints "pi<TAB>idle" or "pi<TAB>working"; exits 1 when the pane is not a
# live pi.
fm_tmux_composer_identity() {  # <target>
  local target=$1 tty pgid tpgid comm found=0 status
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || tty=
  case "$tty" in
    /dev/*)
      while read -r _ pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        case "${comm##*/}" in
          pi|pi-signed|pi-launcher|Pi) found=1 ;;
        esac
      done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
      ;;
  esac
  if [ "$found" -ne 1 ]; then
    comm=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || comm=
    case "${comm##*/}" in
      pi|pi-signed|pi-launcher) found=1 ;;
    esac
  fi
  [ "$found" -eq 1 ] || return 1
  status=$(fm_pane_busy_state "$target" pi)
  case "$status" in
    busy) printf 'pi\tworking' ;;
    idle) printf 'pi\tidle' ;;
    *) return 1 ;;
  esac
}

# fm_tmux_composer_state: the tmux composer verdict - a thin adapter over the
# shared screen classifier. The verdict contract (empty | pending |
# pending-unproven | unknown, positive proof required for empty, unrecognized
# future verdicts failing safe) is owned by bin/fm-composer-lib.sh. Identity
# is fetched lazily, only when the classifier reports the verdict depends on
# it (a pi separator pair under the cursor), so the common read never pays
# for the process probe.
fm_tmux_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cy pane verdict identity
  cy=$(fm_tmux_composer_cursor_row "$target") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux_composer_capture "$target") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  # Cursor Agent CLI parks its terminal cursor OUTSIDE its composer, below the
  # footer, with #{cursor_flag} 0 - so on a Cursor pane tmux's cursor row is not
  # a composer locator and the cursor-anchored read can only ever answer
  # `unknown`. Reclassify that pane the way every cursorless backend already
  # classifies it, letting the bottom-most shape win, which is the same rule
  # herdr, zellij, cmux, and orca use for every harness including this one.
  # Gated on Cursor's own structural process identity, never on the verdict
  # alone, so the strict blank-row posture that owns `unknown` for every other
  # harness is untouched.
  if [ "$verdict" = unknown ] && fm_tmux_pane_is_cursor "$target"; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" '')
  fi
  printf '%s' "$verdict"
}

# fm_tmux_pane_is_cursor: true when the pane's FOREGROUND process group contains
# a genuine Cursor Agent CLI process. Cursor runs as a bundled node script, so
# tmux's own #{pane_current_command} reports a bare `node`; identity therefore
# comes from Cursor's name or install tree in the command path or argv[0], whose
# single owner is bin/fm-cursor-lib.sh. The foreground scoping (pgid = tpgid)
# matches fm_tmux_composer_identity, so a pane whose agent exited to a shell has
# no Cursor foreground process and gets no reclassification.
fm_tmux_pane_is_cursor() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  while read -r pid pgid tpgid comm; do
    [ -n "$comm" ] || continue
    [ "$pgid" = "$tpgid" ] || continue
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    fm_cursor_process_matches "$comm" '' "$argv0" && return 0
  done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
  return 1
}

# fm_pane_input_pending: 0 when the composer is not proven empty, so pending
# text, ambiguous structure, unreadable state, and future verdicts all defer.
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" != empty ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local win=$1 harness=${2:-} tail40 visible
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

fm_pane_is_busy() {  # <target> [harness]
  [ "$(fm_pane_busy_state "$1" "${2:-}")" = busy ]
}

# fm_tmux_submit_core: type <text> into <target> ONCE, then submit with Enter,
# verifying the composer cleared. Retries Enter ONLY — never retypes, because a
# swallowed Enter leaves our text in the composer and retyping would duplicate
# it. Echoes the final proof-carrying verdict on stdout so callers can require
# exact `empty` before treating submission as confirmed.
# Busy-queued Enter (opencode 1.18.4): the harness accepts Enter while mid-turn
# and queues it for after the current turn, but keeps the typed text visible in
# the composer. Once the Enter-retry budget is spent and a structurally proven
# composer still reads "pending", the submit core falls back to
# `fm_pane_is_busy`: a busy pane means the Enter was accepted and queued (report
# `empty` so the caller does not re-send), while an idle pane keeps `pending` as
# a genuine swallow. Pending-unproven receives the same Enter retry budget but
# never reaches this exception.
# Turn-started confirmation (the strict blank-row posture's counterpart): a
# harness whose mid-turn screen the classifier cannot positively identify (pi
# replaces its separated composer while working) reads `unknown` right after a
# successful submit. When and only when the pane was IDLE before the text was
# typed, an idle-to-busy transition across our Enter is proof the harness
# accepted the submission - the same semantic signal herdr's native
# agent-state confirmation uses, read from the pane's verified busy footer.
# The busy read is polled across the remaining retry budget because the turn
# takes a beat to render. Without the baseline (a direct
# fm_tmux_submit_enter_core caller, or a pane already busy before typing) an
# `unknown` verdict is preserved untouched: busy conversion without the
# transition evidence could mark an undelivered message delivered.
fm_tmux_submit_enter_core() {  # <target> <retries> <enter-sleep> [baseline-idle]
  local target=$1 retries=$2 sleep_s=$3 baseline_idle=${4:-} i=0 j state busy_state
  while :; do
    tmux send-keys -t "$target" Enter 2>/dev/null || true
    sleep "$sleep_s"
    state=$(fm_tmux_composer_state "$target")
    case "$state" in
      pending|pending-unproven) ;;
      unknown)
        if [ "$baseline_idle" = 1 ]; then
          j=0
          while [ "$j" -lt "$retries" ]; do
            if fm_pane_is_busy "$target"; then
              printf 'empty'
              return 0
            fi
            j=$((j + 1))
            [ "$j" -ge "$retries" ] || sleep "$sleep_s"
          done
        fi
        printf 'unknown'
        return 0
        ;;
      *) printf '%s' "$state"; return 0 ;;
    esac
    i=$((i + 1))
    [ "$i" -lt "$retries" ] || break
  done
  if [ "$state" != pending ]; then
    printf '%s' "$state"
    return 0
  fi
  # Retries exhausted, composer still shows proven pending.
  # Busy conversion is owned by fm_composer_queued_enter_verdict.
  busy_state=idle
  fm_pane_is_busy "$target" && busy_state=busy
  fm_composer_queued_enter_verdict "$state" "$busy_state"
}

fm_tmux_submit_core() {  # <target> <text> <retries> <enter-sleep> <settle>
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 baseline_idle='' baseline_state err
  # The turn-started baseline must predate our own typing: a pane already
  # busy before the text lands can turn "busy" for reasons unrelated to our
  # Enter, so only a clean idle-to-busy transition may confirm a submit.
  baseline_state=$(fm_pane_busy_state "$target")
  [ "$baseline_state" = idle ] && baseline_idle=1
  # A failed literal send replays tmux's stderr (for example "command too
  # long") so the caller can log why nothing was typed.
  if ! err=$(tmux send-keys -t "$target" -l "$text" 2>&1 >/dev/null); then
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    printf 'send-failed'
    return 0
  fi
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s" "$baseline_idle"
}

# Shell commands cannot use an agent-composer verdict. The caller supplies an
# execution postcondition (leased cwd or agent liveness), never a key-send test.
# Retry keys require the exact owned line at a shell cursor. The capture reaches
# back into history only as far as the text plus a prompt row can wrap, so a long
# launch line stays inspectable while the read stays small: a full-history read
# of a busy pane makes the expansions below quadratic on bash 3.2, which spins at
# full CPU and defers signal handling until it finishes. A transcript match above
# the cursor or another foreground program never authorizes a retry.
# Returns 0 for owned pending input, 1 for another line, 2 for unreadable input.
fm_tmux_shell_line_pending() { # <target> <text>
  local target=$1 text=$2 command cursor width rows screen cursor_line line
  command=$(tmux display-message -p -t "$target" '#{pane_current_command}') || return 2
  fm_tmux_is_shell_command "$command" || return 2
  cursor=$(tmux display-message -p -t "$target" '#{cursor_y}') || return 2
  case "$cursor" in ''|*[!0-9]*) return 2 ;; esac
  width=$(tmux display-message -p -t "$target" '#{pane_width}') || return 2
  case "$width" in ''|0|*[!0-9]*) return 2 ;; esac
  # ${#text} counts characters, not cells: a double-width character fills two,
  # so size the window for the worst case rather than undercount and start the
  # capture inside the command.
  rows=$(( (2 * ${#text} + width - 1) / width + 2 ))
  # Preserve terminal row endings across command substitution. Remove only
  # capture-pane's final terminator, so a blank cursor row stays distinguishable
  # from the submitted command echoed immediately above it.
  screen=$(tmux capture-pane -p -J -t "$target" -S "$((cursor - rows))" -E "$cursor" && printf '.') || return 2
  screen=${screen%.}
  screen=${screen%$'\n'}
  cursor_line=${screen##*$'\n'}
  [[ "$cursor_line" == *[![:space:]]* ]] || return 1
  # ZLE can redraw a wrapped command with explicit row moves rather than
  # terminal autowrap, so tmux -J alone may retain newlines inside the input.
  # Require the full command as the suffix ending at the cursor row either way.
  line=${screen//$'\n'/}
  [ -n "$text" ] && [[ "$line" == *"$text" ]]
}

fm_tmux_is_shell_command() { # <pane_current_command>
  case "$1" in bash|zsh|sh|dash|ksh|fish|-bash|-zsh|-sh) return 0 ;; esac
  return 1
}

# <target> <timeout-seconds> [poll-seconds]
# Wait, bounded, until an agent-free pane holds a shell ready to read a typed
# line, so a relaunch never types into a pane whose shell has not started its
# line editor yet. Ready means the pane's foreground command is a shell, its
# cursor row shows non-blank prompt text, AND either its tty is out of
# canonical mode (a line editor such as ZLE or readline is reading keys - a
# kernel fact that a shell still sourcing its rc files does not show; the
# visible prompt keeps an rc-file raw read from counting) or that row has held
# the same text for two polls (a shell without a line editor). A stale alternate
# screen left by an agent killed before it could restore the terminal is left by
# writing the restore sequence to the pane's tty: that is terminal output, never
# shell input, so no keys reach the shell. The prompt the shell drew on that
# frame leaves with it, so after leaving one, a shell already past its rc files
# is ready on noncanonical mode alone. Returns 0 when ready; otherwise prints one
# error naming what the pane last showed and returns 1, having sent no input.
fm_tmux_shell_ready_wait() {
  local target=$1 timeout=$2 poll=${3:-0.5} elapsed=0 command alt tty attrs
  local cursor row prev_row='' seen='unreadable pane' left_frame=0
  while :; do
    command=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || command=
    if fm_tmux_is_shell_command "$command"; then
      tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || tty=
      alt=$(tmux display-message -p -t "$target" '#{alternate_on}' 2>/dev/null) || alt=
      seen="shell $command"
      if [ "$alt" = 1 ]; then
        seen="shell $command under a stale full-screen frame"
        case "$tty" in /dev/*) printf '\033[?1049l' 2>/dev/null >"$tty" && left_frame=1 ;; esac
      else
        cursor=$(tmux display-message -p -t "$target" '#{cursor_y}' 2>/dev/null) || cursor=
        row=
        case "$cursor" in
          ''|*[!0-9]*) ;;
          *) row=$(tmux capture-pane -p -t "$target" -S "$cursor" -E "$cursor" 2>/dev/null) || row= ;;
        esac
        [[ "$row" == *[![:space:]]* ]] && [ "$row" = "$prev_row" ] && return 0
        if { [ "$left_frame" = 1 ] || [[ "$row" == *[![:space:]]* ]]; } &&
          [[ "$tty" == /dev/* ]] && attrs=$(LC_ALL=C stty -a 2>/dev/null <"$tty") &&
          [[ " ${attrs//$'\n'/ } " == *" -icanon "* ]]; then
          return 0
        fi
        prev_row=$row
        seen="shell $command without a prompt"
      fi
    else
      prev_row=
      [ -z "$command" ] || seen="foreground $command"
    fi
    awk -v e="$elapsed" -v t="$timeout" 'BEGIN{exit !(e < t)}' || break
    sleep "$poll"
    elapsed=$(awk -v e="$elapsed" -v p="$poll" 'BEGIN{printf "%.3f", e + p}')
  done
  echo "error: $target did not show a usable shell within ${timeout}s (last seen: $seen); no input was sent" >&2
  return 1
}

# The agent-composer counterpart of fm_tmux_shell_line_pending, with the same
# return codes. Owned means the cursor-anchored verdict proves an agent
# composer holding input and that input is exactly <text>
# (fm_composer_holds_owned_text); `residue` also accepts what a partial Ctrl+U
# cleanup leaves of it. An empty composer holds nothing of ours; an unknown
# one is unreadable, because the strict posture cannot place the cursor in a
# composer there, and a key sent to an unplaced cursor could answer a dialog.
# The composer rows it read are left in FM_TMUX_OWNED_CONTENT (empty unless the
# composer held input), so a caller can compare two successive reads.
fm_tmux_composer_owned_input() { # <target> <text> [residue]
  local target=$1 text=$2 mode=${3:-} content
  FM_TMUX_OWNED_CONTENT=
  case "$(fm_tmux_composer_state "$target")" in
    empty) return 1 ;;
    pending|pending-unproven) ;;
    *) return 2 ;;
  esac
  content=$(fm_composer_extract_selected_content \
    "$(printf 'styled=1\ncursor=0\nidentity=0\nrows=0')" \
    "$(fm_tmux_composer_capture "$target")" $'\x1f') || return 2
  FM_TMUX_OWNED_CONTENT=$content
  fm_composer_holds_owned_text "$text" "$content" "$mode"
}

# <target> <text> <show-polls> <quiet-gap> <enter-retries> <proof-polls>
#   <proof-sleep> <proof-fn> [proof-args...]
# The positive-proof submit for a sender that must never count an undelivered
# message as delivered (the away daemon's inject_msg). fm_tmux_submit_core
# accepts a composer that reads empty after Enter, which a stale frame also
# shows, so an unsent message can be counted as delivered
# (tests/fm-afk-inject-delivery-proof.test.sh owns the regression). This
# primitive types <text> once and then requires evidence at both ends:
#   - Before Enter, the composer must prove it holds exactly <text>
#     (fm_tmux_composer_owned_input) on two successive reads <quiet-gap>
#     seconds apart with unchanged rows, polled up to <show-polls> times. The
#     quiet gap is timed from when the harness shows the text, not from the
#     tmux write: Claude Code folds an Enter that arrives within about 100 ms of
#     reading a typed burst into the paste, so the gap must exceed that window.
#     Text that never proves itself gets no Enter at all.
#   - After Enter, success needs the owned text provably gone (a readable
#     composer that does not hold it; an unreadable one proves nothing) AND
#     <proof-fn> [proof-args...] to succeed, which the caller defines as its
#     turn-started evidence (an idle-to-busy transition, or an opened
#     operational record); the proof function prints a short evidence word.
#     Turn evidence seen while the composer was unreadable is kept until a
#     readable read confirms the text is gone. Enter is retried, never the
#     text, while the composer still holds exactly <text>, at most
#     <enter-retries> presses in all, across <proof-polls> polls <proof-sleep>
#     seconds apart.
# Prints one line: `delivered enter=<n> polls=<n> proof=<evidence>` on proof,
# `unshown` when the text never proved itself (no Enter sent), `pending` when
# it is still in the composer, `turn-started <evidence>` when a turn started
# but no readable composer confirmed the text gone, `unproven` when it left
# the composer but no turn was proven, or `send-failed` when tmux refused the
# literal send (its stderr is replayed). Every verdict but `delivered` may
# leave the text in the composer.
fm_tmux_proven_submit() {
  local target=$1 text=$2 show=$3 gap=$4 retries=$5 polls=$6 sleep_s=$7 proof=$8
  local err prev='' shown=0 i=0 rc enters=1 evidence started=''
  shift 8
  if ! err=$(tmux send-keys -t "$target" -l "$text" 2>&1 >/dev/null); then
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    printf 'send-failed'
    return 0
  fi
  while [ "$i" -lt "$show" ]; do
    sleep "$gap"
    i=$((i + 1))
    if fm_tmux_composer_owned_input "$target" "$text"; then
      if [ -n "$prev" ] && [ "$FM_TMUX_OWNED_CONTENT" = "$prev" ]; then
        shown=1
        break
      fi
      prev=$FM_TMUX_OWNED_CONTENT
    else
      prev=
    fi
  done
  if [ "$shown" != 1 ]; then
    printf 'unshown'
    return 0
  fi
  tmux send-keys -t "$target" Enter 2>/dev/null || true
  i=0
  while [ "$i" -lt "$polls" ]; do
    sleep "$sleep_s"
    i=$((i + 1))
    rc=0
    fm_tmux_composer_owned_input "$target" "$text" || rc=$?
    if [ "$rc" != 0 ]; then
      if [ -z "$started" ] && evidence=$("$proof" "$@"); then
        started=${evidence:-yes}
      fi
      if [ "$rc" = 1 ] && [ -n "$started" ]; then
        printf 'delivered enter=%s polls=%s proof=%s' "$enters" "$i" "$started"
        return 0
      fi
    elif [ "$enters" -lt "$retries" ]; then
      tmux send-keys -t "$target" Enter 2>/dev/null || true
      enters=$((enters + 1))
    fi
  done
  if [ "$rc" = 0 ]; then
    printf 'pending'
  elif [ -n "$started" ]; then
    printf 'turn-started %s' "$started"
  else
    printf 'unproven'
  fi
}

# <target> <text> <owned-fn> <clear-presses>
# Clear input the caller has just proven it owns with at most <clear-presses>
# Ctrl+U presses, stopping as soon as <owned-fn> finds nothing of it left.
# Returns 0 when the cleanup is confirmed and 1 when it is not.
fm_tmux_clear_owned_input() {
  local target=$1 text=$2 owned=$3 presses=$4 press=0 pending_status=0
  while [ "$pending_status" = 0 ] && [ "$press" -lt "$presses" ]; do
    tmux send-keys -t "$target" C-u 2>/dev/null || true
    press=$((press + 1))
    sleep 0.3
    pending_status=0
    "$owned" "$target" "$text" residue || pending_status=$?
  done
  [ "$pending_status" = 1 ]
}

# <target> <already-typed-text> <owned-fn> <clear-presses> <label>
#   <postcondition-function> [postcondition-args...]
# The one recovery owner for input a sender typed and must submit or remove.
# <owned-fn> <target> <text> [residue] answers ownership with
# fm_tmux_shell_line_pending's return codes.
# At most three Enter attempts over 20 half-second polls. The first Enter is
# unconditional, so a caller resuming earlier input proves ownership first;
# subsequent keys require exact ownership. A failed send can still have
# executed, so always inspect the postcondition. On exhaustion, clear only
# proven owned input (fm_tmux_clear_owned_input) and report whether cleanup
# could be confirmed. Returns 0 when the postcondition held, 1 when owned input
# was cleared, 2 when owned cleanup could not be confirmed, and 3 when
# ownership was unproven so no cleanup keys were sent.
# Callers must stop on failure, never append more input to uncertain input.
fm_tmux_owned_submit_enter() {
  local target=$1 text=$2 owned=$3 presses=$4 label=$5 verify=$6 poll attempt=1
  shift 6
  tmux send-keys -t "$target" Enter 2>/dev/null || true
  for ((poll=0; poll<20; poll++)); do
    sleep 0.5
    "$verify" "$@" && return 0
    if [ "$attempt" -lt 3 ] && "$owned" "$target" "$text"; then
      tmux send-keys -t "$target" Enter 2>/dev/null || true
      attempt=$((attempt + 1))
    fi
  done
  if ! "$owned" "$target" "$text"; then
    echo "error: $label execution unconfirmed in $target; input ownership is unproven, so no cleanup keys were sent" >&2
    return 3
  fi
  if fm_tmux_clear_owned_input "$target" "$text" "$owned" "$presses"; then
    echo "error: $label did not run in $target after $attempt Enter attempts; cleared owned input" >&2
    return 1
  fi
  echo "error: $label did not run in $target after $attempt Enter attempts; owned input cleanup could not be confirmed" >&2
  return 2
}

# <target> <already-typed-text> <postcondition-function> [postcondition-args...]
# A shell line clears with one Ctrl+U, so a second press is never needed.
fm_tmux_shell_submit_enter() {
  local target=$1 text=$2
  shift 2
  fm_tmux_owned_submit_enter "$target" "$text" fm_tmux_shell_line_pending 1 'shell command' "$@"
}
