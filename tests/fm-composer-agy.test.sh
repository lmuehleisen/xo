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
  local rule='────────────────────' hint=$FM_COMPOSER_AGY_HINT screen
  screen=$(printf '%s\n> %s[2m%s%s[0m\n%s\n? for shortcuts     accept-edits · Gemini 3.8 Flash · low\n' "$rule" "$ESC" "$hint" "$ESC" "$rule")
  assert_screen 'agy styled idle' empty "$CAPS_TMUX" "$screen" 1
  assert_screen 'agy cursorless styled idle' empty "$CAPS_STYLED" "$screen"
  assert_screen 'agy unstyled hint is ambiguous' unknown "$CAPS_PLAIN" "$screen"
  screen=$(printf '%s\n> %s\n%s\n? for shortcuts     accept-edits · Gemini 3.8 Flash · low\n' "$rule" "$FM_COMPOSER_AGY_HINT_STYLED" "$rule")
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
