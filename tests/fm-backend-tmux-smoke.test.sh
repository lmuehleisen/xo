#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u
# shellcheck source=tests/tmproot-guard.sh
. "$(dirname "${BASH_SOURCE[0]}")/tmproot-guard.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

wait_for_capture_text() {  # <target> <text> [samples]
  local target=$1 text=$2 samples=${3:-100} out i=0
  while [ "$i" -lt "$samples" ]; do
    out=$(fm_backend_tmux_capture "$target" 200 2>/dev/null || true)
    case "$out" in
      *"$text"*) return 0 ;;
    esac
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_rm_tmproot "${SHIM_DIR:-}"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX") || exit 1
SHIM_DIR=$(cd "$SHIM_DIR" && pwd -P) || exit 1
fm_test_require_tmproot "$SHIM_DIR"
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

# A newly-created interactive shell can exist before its startup files and line
# editor are ready to accept Enter. Prove command execution with an output token
# that does not appear contiguously in the command, retrying the harmless probe
# until the shell acknowledges it.
SHELL_READY=false
for _ in $(seq 1 100); do
  tmux send-keys -t "$TARGET" C-c
  tmux send-keys -t "$TARGET" -l "printf 'shell-%s\\n' ready"
  tmux send-keys -t "$TARGET" Enter
  if wait_for_capture_text "$TARGET" "shell-ready" 10; then
    SHELL_READY=true
    break
  fi
done
[ "$SHELL_READY" = true ] || fail "the tmux task shell did not become ready"

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ ' && clear && printf 'setup-%s\\n' ready" Enter
wait_for_capture_text "$TARGET" "setup-ready" || fail "the tmux task shell did not complete setup"

fm_backend_tmux_send_text_line "$TARGET" "printf 'captain-on-deck-%s\\n' line" \
  || fail "fm_backend_tmux_send_text_line failed"
wait_for_capture_text "$TARGET" "captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" "printf 'literal-then-key-%s\\n' captain" \
  || fail "fm_backend_tmux_send_literal failed"
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
wait_for_capture_text "$TARGET" "literal-then-key-captain" \
  || fail "fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter did not execute"
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
wait_for_capture_text "$TARGET" "tag-line-80" \
  || fail "the numbered output did not complete before capture"
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# Exercise shell submit against real line editors on this suite's private server.
# Only the transport drops Enter; cwd/process/file postconditions stay real.
submit_test_enters=0
submit_test_drop=first
submit_test_target=
tmux() {
  if [ "${1:-}" = send-keys ] && [ "${3:-}" = "$submit_test_target" ] && [ "${4:-}" = Enter ]; then
    submit_test_enters=$((submit_test_enters + 1))
    if [ "$submit_test_drop" = all ] || { [ "$submit_test_drop" = first ] && [ "$submit_test_enters" = 1 ]; }; then
      return 0
    fi
  fi
  command tmux "$@"
}
submit_test_cwd() {
  [ "$(fm_backend_tmux_current_path "$submit_test_target")" = "$SHIM_DIR" ]
}
submit_test_process() {
  [ "$(fm_backend_tmux_current_command "$submit_test_target")" = sleep ]
}
submit_test_file() { [ -f "$SHIM_DIR/executed" ]; }
for submit_shell in /bin/bash /bin/zsh; do
  [ -x "$submit_shell" ] || { echo "skip: shell submit $submit_shell unavailable"; continue; }
  submit_test_target="$SESSION:submit-${submit_shell##*/}"
  case "$submit_shell" in
    */bash) submit_shell_args='--noprofile --norc -i' ;;
    */zsh) submit_shell_args='-f -i' ;;
  esac
  command tmux new-window -d -t "$SESSION:" -n "submit-${submit_shell##*/}" \
    "env PS1='submit-ready> ' $submit_shell $submit_shell_args"
  wait_for_capture_text "$submit_test_target" 'submit-ready>' || fail "shell did not become ready"
  submit_test_enters=0
  submit_test_drop=first
  submit_line="cd -- '$SHIM_DIR'"
  fm_backend_tmux_send_literal "$submit_test_target" "$submit_line"
  sleep 0.3
  fm_tmux_shell_submit_enter "$submit_test_target" "$submit_line" submit_test_cwd \
    || fail "real $submit_shell cd did not recover dropped Enter"
  [ "$submit_test_enters" = 2 ] || fail "real cd did not retry exactly once"
  pass "real $submit_shell cwd confirms shell submit after first Enter is dropped"

  submit_test_enters=0
  # Make the launch span multiple wrapped rows. The suffix must be captured at
  # the cursor, not guessed from a nearby transcript occurrence.
  submit_padding=$(printf '%0600d' 0)
  submit_line="SUBMIT_PADDING=$submit_padding sleep 30"
  fm_backend_tmux_send_literal "$submit_test_target" "$submit_line"
  sleep 0.3
  fm_tmux_shell_submit_enter "$submit_test_target" "$submit_line" submit_test_process \
    || fail "real $submit_shell wrapped launch did not recover dropped Enter"
  [ "$submit_test_enters" = 2 ] || fail "real launch did not retry exactly once"
  command tmux send-keys -t "$submit_test_target" C-c
  sleep 0.3
  pass "real $submit_shell process confirms wrapped launch after first Enter is dropped"

  # Keep the foreground process a shell while its builtin read delays the
  # postcondition. Accepted Enter leaves the cursor on an empty row meanwhile.
  submit_test_enters=0
  submit_test_drop=none
  submit_line="read -r -t 2 submit_unused; touch '$SHIM_DIR/executed'"
  fm_backend_tmux_send_literal "$submit_test_target" "$submit_line"
  sleep 0.3
  fm_tmux_shell_submit_enter "$submit_test_target" "$submit_line" submit_test_file \
    || fail "real $submit_shell delayed execution was not confirmed"
  [ "$submit_test_enters" = 1 ] || fail "accepted Enter was retried into the shell builtin"
  rm "$SHIM_DIR/executed"
  pass "real $submit_shell accepted Enter waits on a blank cursor without retrying"

  submit_test_enters=0
  submit_test_drop=all
  submit_line="touch '$SHIM_DIR/executed'"
  fm_backend_tmux_send_literal "$submit_test_target" "$submit_line"
  sleep 0.3
  if fm_tmux_shell_submit_enter "$submit_test_target" "$submit_line" submit_test_file; then
    fail "all lost Enters unexpectedly executed"
  fi
  [ "$submit_test_enters" = 3 ] || fail "real retry budget exceeded"
  submit_test_drop=none
  # An empty Enter after failure must not execute the abandoned command.
  command tmux send-keys -t "$submit_test_target" Enter
  sleep 0.3
  [ ! -f "$SHIM_DIR/executed" ] || fail "failed submission left executable text behind"
  pass "real $submit_shell exhausted submit clears its owned input"
  command tmux kill-window -t "$submit_test_target"
done
unset -f tmux

# --- kill and recovery-grade missing-window classification ------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
state=$(fm_backend_agent_state tmux "$TARGET")
[ "$state" = missing ] \
  || fail "a real missing window in a readable session should classify as missing, got '$state'"
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: kill removes the window and the readable session inventory authoritatively classifies it missing"

cleanup_all
trap - EXIT
