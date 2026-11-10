#!/usr/bin/env bash
# tests/fm-composer-agy.test.sh - agy's separated composer in the shared
# composer-content classifier (bin/fm-composer-lib.sh).
#
# Agy draws its input between two horizontal rules with a shell-like glyph and a
# mode footer, so only the full structure is safe empty-composer evidence. The
# shared classifier matrix lives in tests/fm-composer-lib.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"

# Capture-capability profiles, as in tests/fm-composer-lib.test.sh.
ESC=$(printf '\033')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor] [identity]: one
# verdict, asserted under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

# Agy 1.2.0's actual shape is two rules plus a shell glyph and its footer.
# Neither a rule pair nor a shell glyph alone is safe input-container evidence.
test_agy_separated_composer() {
  local rule='────────────────────' hint='Accept-edits mode: file edits auto-approved (shift+tab to cycle)' screen
  screen=$(printf '%s\n> %s[2m%s%s[0m\n%s\n? for shortcuts     accept-edits · Gemini 3.8 Flash · low\n' "$rule" "$ESC" "$hint" "$ESC" "$rule")
  assert_screen 'agy styled idle' empty "$CAPS_TMUX" "$screen" 1
  assert_screen 'agy cursorless styled idle' empty "$CAPS_STYLED" "$screen"
  assert_screen 'agy unstyled hint is ambiguous' unknown "$CAPS_PLAIN" "$screen"
  screen=$(printf '%s\n> %s\n%s\n? for shortcuts     accept-edits · Gemini 3.8 Flash · low\n' "$rule" "${ESC}[90m${hint}${ESC}[39m" "$rule")
  assert_screen 'agy actual SGR 90 hint' empty "$CAPS_TMUX" "$screen" 1
  [ -z "$(fm_composer_extract_selected_content "$CAPS_TMUX" "$screen")" ] || fail 'agy styled hint leaked into input extraction'
  assert_screen 'agy cursor on rule is unsafe' unknown "$CAPS_TMUX" "$screen" 0
  screen=$(printf '%s\n> pending command\n%s\n? for shortcuts     Gemini 3.8 Flash · low\n' "$rule" "$rule")
  assert_screen 'agy pending input' pending "$CAPS_TMUX" "$screen" 1
  [ "$(fm_composer_extract_selected_content "$CAPS_TMUX" "$screen")" = 'pending command' ] || fail 'agy input extraction lost pending text'
  screen=$(printf '%s\n> pending command\n%s\n          accept-edits · Gemini 3.8 Flash · low\n' "$rule" "$rule")
  assert_screen 'agy typing hides shortcuts but retains mode' pending "$CAPS_TMUX" "$screen" 1
  screen=$(printf '%s\n> first line\nsecond line\n%s\n? for shortcuts     Gemini 3.8 Flash · low\n' "$rule" "$rule")
  assert_screen 'agy wrapped pending input' pending "$CAPS_TMUX" "$screen" 2
  screen=$(printf '%s\n>\n%s\n? for shortcuts     Gemini 3.8 Flash · low\n' "$rule" "$rule")
  assert_screen 'agy empty manual input' empty "$CAPS_TMUX" "$screen" 1
  assert_screen 'agy stale footer above shell' unknown "$CAPS_TMUX" "$screen"$'\n$' 4
  screen=$(printf '%s\n>\n%s\n' "$rule" "$rule")
  assert_screen 'shell between transcript rules is not agy' unknown $'styled=1\ncursor=1\nidentity=0' "$screen" 1
  pass 'agy composer requires full structure and preserves pending or ambiguous input'
}
test_agy_separated_composer

# Herdr's styled visible read (`pane read --source visible --format ansi`)
# terminates every row with CRLF. The shape below is a bypassed agy 1.3.1
# worker just after an Escape interrupt, as herdr returned it: no mode cell,
# the model alone on the right of the footer.
test_agy_herdr_crlf_rows() {
  local rule='────────────────────' pad='                                        ' screen
  screen="${ESC}[0m  ⎿  Interrupted · What should Antigravity CLI do instead?${ESC}[0m"$'\r\n'
  screen+="${ESC}[0m${ESC}[38;5;8m$rule${ESC}[0m"$'\r\n'
  screen+="${ESC}[0m${ESC}[38;5;12m>${ESC}[0m"$'\r\n'
  screen+="${ESC}[0m${ESC}[38;5;8m$rule${ESC}[0m"$'\r\n'
  screen+="${ESC}[0m${ESC}[38;5;8m? for shortcuts$pad${ESC}[0m${ESC}[2mGemini 3.8 Flash · high${ESC}[0m$pad"
  assert_screen 'agy herdr CRLF interrupted idle' empty "$CAPS_STYLED" "$screen"
  [ -z "$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen")" ] \
    || fail 'agy CRLF row terminator leaked into input extraction'
  local from=">$ESC" to="> keep going$ESC"
  assert_screen 'agy herdr CRLF pending input' pending "$CAPS_STYLED" "${screen/"$from"/$to}"
  # A queued steer replaces the shortcut hint; that footer proves nothing.
  from='? for shortcuts' to='  Press up to edit queued messages'
  assert_screen 'agy herdr CRLF queued messages stay unproven' need-identity "$CAPS_STYLED" "${screen/"$from"/$to}"
  # The terminator never stands in for the footer proof.
  screen="$rule"$'\r\n>\r\n'"$rule"$'\r\n'
  assert_screen 'CRLF shell between transcript rules is not agy' unknown $'styled=1\ncursor=1\nidentity=0' "$screen" 1
  pass 'agy composer proof survives herdr CRLF rows without proving a queued or unfootered pane'
}
test_agy_herdr_crlf_rows

# Composer-only bytes from agy 1.5.3, captured idle and with unsubmitted input.
# The plain captures really omit styling; CRLF replays model Herdr's row endings.
test_agy_mode_captures() {
  local mode styled plain crlf caps hint modified out
  for mode in auto plan; do
    styled=$(cat "$ROOT/tests/fixtures/agy-composer/$mode-idle.styled")
    plain=$(cat "$ROOT/tests/fixtures/agy-composer/$mode-idle.plain")
    crlf=${styled//$'\n'/$'\r\n'}$'\r'
    assert_screen "$mode tmux idle" empty "$CAPS_TMUX" "$styled" 1
    assert_screen "$mode cursorless idle" empty "$CAPS_STYLED" "$styled"
    assert_screen "$mode CRLF idle" empty "$CAPS_STYLED" "$crlf"
    assert_screen "$mode plain hint is ambiguous" unknown "$CAPS_PLAIN" "$plain"
    # Styling capability alone cannot prove a row whose hint has no SGR.
    assert_screen "$mode unstyled hint on styled capture" unknown "$CAPS_STYLED" "$plain"
    for caps in "$CAPS_TMUX" "$CAPS_STYLED"; do
      [ -z "$(fm_composer_extract_selected_content "$caps" "$styled")" ] \
        || fail "$mode styled hint leaked into input extraction"
      [ -z "$(fm_composer_extract_selected_content "$caps" "$crlf")" ] \
        || fail "$mode CRLF hint leaked into input extraction"
    done
    hint=${plain#*$'\n> '}
    hint=${hint%%$'\n'*}
    modified=${plain/"$hint"/"${ESC}[90m${hint}!${ESC}[39m"}
    assert_screen "$mode similar styled text is pending" pending "$CAPS_TMUX" "$modified" 1
    modified=${plain/"$hint"/"${ESC}[2m${hint}${ESC}[0m"}
    assert_screen "$mode dim idle hint" empty "$CAPS_TMUX" "$modified" 1
    styled=$(cat "$ROOT/tests/fixtures/agy-composer/$mode-typed.styled")
    plain=$(cat "$ROOT/tests/fixtures/agy-composer/$mode-typed.plain")
    crlf=${styled//$'\n'/$'\r\n'}$'\r'
    assert_screen "$mode tmux typed" pending "$CAPS_TMUX" "$styled" 1
    assert_screen "$mode cursorless typed" pending "$CAPS_STYLED" "$styled"
    assert_screen "$mode CRLF typed" pending "$CAPS_STYLED" "$crlf"
    assert_screen "$mode plain typed" pending "$CAPS_PLAIN" "$plain"
    for caps in "$CAPS_TMUX" "$CAPS_STYLED"; do
      out=$(fm_composer_extract_selected_content "$caps" "$crlf")
      [ "$out" = 'pending command' ] || fail "$mode extraction lost typed input: '$out'"
    done
    out=$(fm_composer_extract_selected_content "$CAPS_PLAIN" "$plain")
    [ "$out" = 'pending command' ] || fail "$mode plain extraction lost typed input"
    modified=${plain/"$mode ·"/'manual ·'}
    assert_screen "$mode unknown mode cell stays unproven" unknown "$CAPS_PLAIN" "$modified"
  done
  pass 'agy Auto and Plan captures preserve idle ambiguity and typed input across capture capabilities'
}
test_agy_mode_captures
