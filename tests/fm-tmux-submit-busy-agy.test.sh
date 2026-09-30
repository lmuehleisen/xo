#!/usr/bin/env bash
# tests/fm-tmux-submit-busy-agy.test.sh - agy's running-turn footer in the
# harness-scoped busy matcher and the tmux submit confirmation
# (bin/fm-tmux-lib.sh).
#
# Agy's footer is recognized only for agy and the harness-less delivery union,
# and a submit is confirmed only by an idle-to-busy transition, never by a busy
# or unreadable baseline. The shared submit cases live in
# tests/fm-tmux-submit-busy.test.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-tmux-lib.sh"

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-tmux-submit-busy-agy.XXXXXX")
trap 'fm_test_rm_tmproot "${TMP_ROOT:-}"' EXIT

# A tmux transport fixture: capture-pane prints the composer file (optionally
# failing its first read), and Enter renders the running-turn screen.
make_submit_mock() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
COMPOSER="${FM_FAKE_COMPOSER:?}"
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac
    done
    exit 0 ;;
  capture-pane)
    if [ -n "${FM_FAKE_CAPTURE_COUNT:-}" ]; then
      count=0
      [ ! -f "$FM_FAKE_CAPTURE_COUNT" ] || count=$(cat "$FM_FAKE_CAPTURE_COUNT")
      count=$((count + 1))
      printf '%s\n' "$count" > "$FM_FAKE_CAPTURE_COUNT"
      if [ "${FM_FAKE_FAIL_FIRST_CAPTURE:-0}" = 1 ] && [ "$count" -eq 1 ]; then
        exit 1
      fi
    fi
    cat "$COMPOSER" 2>/dev/null; exit 0 ;;
  send-keys)
    shift; is_enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift ;; -l) ;; Enter) is_enter=1 ;; esac; shift
    done
    if [ "$is_enter" = 1 ]; then
      [ -z "${FM_FAKE_SENT:-}" ] || printf 'Enter\n' >> "$FM_FAKE_SENT"
      [ -z "${FM_FAKE_TURN_SCREEN:-}" ] || cat "$FM_FAKE_TURN_SCREEN" > "$COMPOSER"
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_agy_busy_signature_is_scoped() (
  local harness footer
  unset FM_BUSY_REGEX
  footer='esc to cancel                         accept-edits · Gemini 3.8 Flash · medium'
  printf '%s\n' "$footer" | fm_busy_lines_match agy \
    || fail "agy must recognize its recorded running-turn footer"
  printf '%s\n' "$footer" | fm_busy_lines_match \
    || fail "the harness-less delivery matcher must recognize agy's footer"
  for harness in claude codex opencode pi pi-signed omp grok kimi cursor gemini muse rovo unregistered; do
    if printf '%s\n' "$footer" | fm_busy_lines_match "$harness"; then
      fail "$harness must not borrow agy's busy footer"
    fi
  done
  for footer in '? for shortcuts' 'esc cancel' 'esc to interrupt' 'esc interrupt' 'Ctrl+c:cancel' 'Working...' 'Working…' 'ctrl+c to stop'; do
    if printf '%s\n' "$footer" | fm_busy_lines_match agy; then
      fail "agy must reject idle, unverified, and foreign tokens: $footer"
    fi
  done
  printf '? for shortcuts\n' | fm_busy_lines_match \
    && fail "agy's idle footer must not enter the delivery-busy union"
  pass "fm_busy_lines_match: agy's verified footer is explicit, available to submit, and harness-scoped"
)

test_agy_submit_requires_an_idle_to_busy_transition() {
  local dir fakebin composer sent turn_screen baseline expected out
  dir="$TMP_ROOT/agy-transition"
  fakebin=$(make_submit_mock "$dir")
  composer="$dir/composer"; sent="$dir/sent"; turn_screen="$dir/turn-screen"
  # Once the turn starts, only the recorded footer remains readable: no
  # composer container can independently prove that the submission landed.
  printf 'esc to cancel\n' > "$turn_screen"
  for baseline in idle busy failed; do
    : > "$sent"
    case "$baseline" in
      idle|failed) printf '? for shortcuts\n' > "$composer" ;;
      busy) cat "$turn_screen" > "$composer" ;;
    esac
    expected=unknown
    [ "$baseline" != idle ] || expected=empty
    rm -f "$dir/capture-count"
    # Fresh sourcing keeps the real busy matcher, without this suite's
    # FM_FAKE_PANE_BUSY override. Only the tmux transport is a fixture.
    out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" FM_FAKE_SENT="$sent" \
      FM_FAKE_TURN_SCREEN="$turn_screen" FM_FAKE_CAPTURE_COUNT="$dir/capture-count" \
      FM_FAKE_FAIL_FIRST_CAPTURE="$([ "$baseline" = failed ] && printf 1 || printf 0)" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; unset FM_BUSY_REGEX; fm_tmux_submit_core win /skill 3 0.01 0' _ "$ROOT")
    [ "$out" = "$expected" ] \
      || fail "agy submit from $baseline must return $expected, got '$out'"
    [ "$(wc -l < "$sent" | tr -d ' ')" = 1 ] \
      || fail "an unreadable agy composer must not cause duplicate Enter submissions"
    cmp -s "$composer" "$turn_screen" \
      || fail "agy transition regression did not render the running-turn footer"
    out=$(PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$composer" \
      bash -c '. "$1/bin/fm-tmux-lib.sh"; fm_tmux_composer_state win' _ "$ROOT")
    [ "$out" = unknown ] \
      || fail "the agy transition must be proven by busy state, not a readable composer"
  done
  pass "fm_tmux_submit_core: agy's idle-to-busy footer confirms once; busy or unreadable baselines stay unknown"
}

test_agy_submit_requires_an_idle_to_busy_transition
test_agy_busy_signature_is_scoped
