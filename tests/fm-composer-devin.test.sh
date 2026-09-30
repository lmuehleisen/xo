#!/usr/bin/env bash
# tests/fm-composer-devin.test.sh - Devin's full composer frame in the shared
# composer-content classifier (bin/fm-composer-lib.sh, with its fork-only
# selector in bin/fm-composer-devin-lib.sh), plus the fork's `esc again`
# delivery signal.
#
# Devin draws its input between a top mode rule and a solid bottom rule with a
# `❭` glyph and a model/context footer, so the whole frame is the empty-composer
# evidence even without a cursor row. The common glyph and placeholder cases
# live in tests/fm-devin-harness.test.sh; the shared classifier matrix lives in
# tests/fm-composer-lib.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

# Capture-capability profiles, as in tests/fm-composer-lib.test.sh.
ESC=$(printf '\033')
CAPS_TMUX=$'styled=1\ncursor=1\nidentity=1\nrows=0'
CAPS_STYLED=$'styled=1\ncursor=0\nidentity=1\nrows=20'      # herdr
CAPS_PLAIN=$'styled=0\ncursor=0\nidentity=0\nrows=20'       # cmux, orca

# assert_screen <label> <want> <caps> <screen> [cursor]: one verdict, asserted
# under the ambient locale AND LC_ALL=C.
assert_screen() {
  local label=$1 want=$2 out
  shift 2
  out=$(fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label: expected $want, got '$out'"
  out=$(LC_ALL=C fm_composer_classify_screen "$@")
  [ "$out" = "$want" ] || fail "$label under LC_ALL=C: expected $want, got '$out'"
}

TOP='──── (smart mode on) ─'
RULE='────────────────────'
FOOTER='SWE-2 Max        Context: 13k / 262k tokens (5%)'
PLACEHOLDER='Ask Devin to build features, fix bugs, or work on your code'

# frame <input-row...>: the four-row Devin frame around the given input rows.
frame() {
  printf '%s\n' "$TOP"
  printf '%s\n' "$@"
  printf '%s\n%s\n' "$RULE" "$FOOTER"
}

test_devin_frame_placeholders() {
  local screen
  screen=$(frame "❭ ${ESC}[2m${PLACEHOLDER}${ESC}[0m")
  assert_screen 'styled idle, cursorless' empty "$CAPS_STYLED" "$screen"
  assert_screen 'styled idle, cursor on input' empty "$CAPS_TMUX" "$screen" 1
  screen=$(frame "❭ $PLACEHOLDER")
  assert_screen 'unstyled idle placeholder' empty "$CAPS_PLAIN" "$screen"
  screen=$(frame "❭ ${ESC}[2mGuide Devin while it works${ESC}[0m")
  assert_screen 'styled working placeholder' empty "$CAPS_STYLED" "$screen"
  pass "fm-composer-lib: the full Devin frame proves an empty composer with or without a cursor"
}

# The placeholder's own words typed at ordinary intensity are a draft: styling
# is the only evidence that separates them from the dim placeholder.
test_devin_frame_drafts() {
  local screen out
  screen=$(frame "❭ $PLACEHOLDER")
  assert_screen 'literal placeholder typed as a draft' pending "$CAPS_TMUX" "$screen" 1
  screen=$(frame '❭ fix the tests')
  assert_screen 'typed draft, cursorless' pending "$CAPS_STYLED" "$screen"
  assert_screen 'typed draft, cursor on input' pending "$CAPS_TMUX" "$screen" 1
  out=$(fm_composer_extract_selected_content "$CAPS_STYLED" "$screen")
  [ "$out" = 'fix the tests' ] || fail "the selected draft must extract as 'fix the tests', got '$out'"
  screen=$(frame '❭ first line of a long draft' '  and its wrapped continuation')
  assert_screen 'wrapped draft' pending "$CAPS_STYLED" "$screen"
  pass "fm-composer-lib: a Devin draft, including the placeholder's own words, stays pending"
}

# A cursor outside the frame, or anything drawn below the footer, is not proof.
test_devin_frame_refusals() {
  local screen
  screen=$(frame '❭ fix the tests')
  assert_screen 'cursor on the top rule' unknown "$CAPS_TMUX" "$screen" 0
  assert_screen 'cursor on the footer' unknown "$CAPS_TMUX" "$screen" 3
  screen=$(frame "❭ ${ESC}[2m${PLACEHOLDER}${ESC}[0m"; printf '%s\n' '/revert  Revert to step')
  [ "$(fm_composer_classify_screen "$CAPS_STYLED" "$screen")" != empty ] \
    || fail "a popup drawn below the footer must never read as an empty composer"
  pass "fm-composer-lib: a cursor off the Devin input rows or content below its footer refuses"
}

# Devin 3000.11.x renders `esc twice` before the first Escape and `esc again`
# after it; each is an independent delivery signal beside the working composer.
test_devin_interrupt_hint_signals() {
  local signal
  for signal in 'Thinking · 1s (esc twice to interrupt)' 'Thinking · 2s (esc again to interrupt)'; do
    printf '%s\n' "$signal" | fm_busy_lines_match devin \
      || fail "fm_busy_lines_match devin must match: $signal"
  done
  ! printf '%s\n' 'Thinking · 2s' | fm_busy_lines_match devin \
    || fail "a thinking line without an interrupt hint must not read busy"
  pass "fm-composer-lib: both Devin interrupt hints are delivery signals"
}

test_devin_frame_placeholders
test_devin_frame_drafts
test_devin_frame_refusals
test_devin_interrupt_hint_signals
