#!/usr/bin/env bash
# shellcheck disable=SC2016 # Daemon snippets expand inside the daemon() subshell, which sources the daemon library.
# tests/fm-afk-inject-titled-composer.test.sh - the away daemon must read,
# submit, and recover its own digest in a Claude Code composer whose top rule
# carries the session's name. tests/fm-afk-inject-titled-composer-herdr-e2e.test.sh
# is the herdr counterpart.
#
# Claude Code draws a named session's name into the composer's top rule
# (`───...─── firstmate ─`). A long name eats the leading rule and is truncated
# with `…`, leaving ` long-name… ─` (verified live on Claude Code 2.1.286). A
# reader that knew only an all-`─` rule saw the bottom rule as a lone separator
# and refused the screen, so on tmux the daemon typed a doorbell it could never
# read back (`unshown`, no Enter) or recover, and on herdr an idle named
# composer read `unknown` and nothing was ever typed.
#
#   1. Offline: named, short-rule, and truncated-name screens read `pending`
#      with and without a cursor, their rows prove the owned doorbell, and
#      idle reads `empty` without a cursor (the herdr path). A titled rule over
#      a shell prompt, or a lookalike transcript row, never reads `empty`.
#   2. tmux end to end: a composer fixture drawn like a named Claude session
#      takes a doorbell on the first flush, a leftover owned doorbell is
#      submitted by recovery, and the exit cleanup clears one.
#
# Every tmux command runs under env -u TMUX -u TMUX_PANE against the explicit
# -S socket through a PATH shim, so the ambient server is never touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

UTF8=
for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if [ "$(LC_ALL=$loc bash -c 'x=$(printf "\xe2\x9d\xaf"); printf %s "${#x}"' 2>/dev/null)" = 1 ]; then
    UTF8=$loc
    break
  fi
done
[ -n "$UTF8" ] || { echo "skip: no UTF-8 locale for the composer fixture"; exit 0; }

REAL_TMUX=$(command -v tmux)
TMP=$(fm_test_tmproot fm-afk-titled)
SOCKDIR=$(mktemp -d /tmp/fmat.XXXXXX)
SOCK="$SOCKDIR/s"
cleanup() {
  env -u TMUX -u TMUX_PANE "$REAL_TMUX" -S "$SOCK" kill-server 2>/dev/null || true
  rm -rf "$SOCKDIR"
  fm_test_cleanup
}
trap cleanup EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/tmux" <<EOF
#!/bin/sh
exec env -u TMUX -u TMUX_PANE '$REAL_TMUX' -S '$SOCK' "\$@"
EOF
chmod +x "$TMP/bin/tmux"
PATH="$TMP/bin:$PATH"
export PATH
unset TMUX TMUX_PANE

# --- the screen shape, shared by the offline checks and the fixture ------------
# rule <width> [title]: Claude Code's composer rule. A named session's name
# takes the width before the rule does: `─...─ name ─`, down to no leading
# rule at all, and past that the name is truncated with `…`.
rule() {  # <width> [title]
  LC_ALL=$UTF8 python3 - "$1" "${2:-}" <<'PY'
import sys
w, title = int(sys.argv[1]), sys.argv[2]
if title and len(title) > w - 3:
    title = title[:w - 4] + "…"
tail = (" " + title + " ─") if title else ""
print("─" * (w - len(tail)) + tail)
PY
}

# wrap <width> <text>: the prompt row and its continuation rows, word-wrapped
# the way Claude Code wraps (continuations indented two columns).
wrap() {  # <width> <text>
  LC_ALL=$UTF8 python3 - "$1" "$2" <<'PY'
import sys, textwrap
w, text = int(sys.argv[1]), sys.argv[2]
rows = textwrap.wrap(text, width=w - 2, break_long_words=True, break_on_hyphens=False) or [""]
print("❯ " + rows[0])
for r in rows[1:]:
    print("  " + r)
PY
}

DOORBELL=": Firstmate operational input waiting: read '/Users/someone/firstmate/state/operational-inbox/1700000000-0123456789abcdef.msg' and handle its contents as Firstmate operational input."

screen() {  # <width> <title> <composer-text>
  printf '%s\n' "⏺ Recorded, and the away daemon is running." "" "✻ Crunched for 1m 50s" ""
  rule "$1" "$2"
  wrap "$1" "$3"
  rule "$1"
  printf '%s\n' "  ⏵⏵ auto mode on (shift+tab to cycle)"
}

offline() {  # <shell snippet>
  ( LC_ALL=$UTF8; . "$ROOT/bin/fm-tmux-lib.sh"; eval "$1" )
}

# --- 1. offline: the incident's screen ---------------------------------------
CAPS_CURSOR=$(printf 'styled=1\ncursor=1\nidentity=0\nrows=0')
CAPS_NONE=$(printf 'styled=1\ncursor=0\nidentity=0\nrows=0')
LONG_NAME=$(printf 'a-very-long-session-name-%.0s' 1 2 3 4 5 6 7 8)
SHORT_RULE_NAME=$(printf 'n%.0s' $(seq 1 145))
for title in firstmate 'Test traffic analytics filtering' "$LONG_NAME" "$SHORT_RULE_NAME"; do
  scr=$(screen 150 "$title" "$DOORBELL")
  # The cursor sits at the end of the doorbell's last row, the third row from
  # the bottom (the bottom rule and the mode hint follow it).
  cy=$(( $(printf '%s\n' "$scr" | wc -l) - 3 ))
  [ "$(printf '%s\n' "$scr" | wc -l)" -ge 9 ] || fail "the doorbell did not wrap in the test screen"
  v=$(offline 'fm_composer_classify_screen "$CAPS_CURSOR" "$scr" "$cy"')
  [ "$v" = pending ] || fail "named composer ($title), cursor-anchored: expected pending, got $v"
  v=$(offline 'fm_composer_classify_screen "$CAPS_NONE" "$scr" ""')
  [ "$v" = pending ] || fail "named composer ($title), cursorless: expected pending, got $v"
  offline 'rows=$(fm_composer_extract_selected_content "$CAPS_NONE" "$scr" $'"'"'\x1f'"'"') && fm_composer_holds_owned_text "$DOORBELL" "$rows"' \
    || fail "named composer ($title): its rows do not prove the owned doorbell"
  idle=$(screen 150 "$title" "")
  v=$(offline 'fm_composer_classify_screen "$CAPS_NONE" "$idle" ""')
  [ "$v" = empty ] || fail "idle named composer ($title), cursorless: expected empty, got $v"
done
pass "a named Claude composer, including a truncated name, reads pending and proves its owned doorbell with or without a cursor, and idle reads empty"

# Safety: a titled rule with a shell prompt under it is not a composer.
scr=$(printf '%s\n' "$(rule 150 firstmate)" 'user@host ~ % ' )
v=$(offline 'fm_composer_classify_screen "$CAPS_NONE" "$scr" ""')
[ "$v" != empty ] || fail "a titled rule above a shell prompt read empty"
pass "a titled rule above a shell prompt never reads empty"

# Safety: a transcript row that merely ends in ` ─`, with neither a leading rule
# nor Claude's one-column pad, never opens a composer.
scr=$(printf '%s\n' 'see the note ─' '❯ ' "$(rule 150)")
v=$(offline 'fm_composer_classify_screen "$CAPS_NONE" "$scr" ""')
[ "$v" != empty ] || fail "a lookalike titled row opened a composer that read empty"
pass "a lookalike row ending in a rule glyph never opens a composer"

# --- 2. end to end: a fixture drawn like a named Claude session ---------------
# tests/named-claude-composer-fixture.py draws the composer.
FIXTURE="$ROOT/tests/named-claude-composer-fixture.py"

FX="$TMP/fx"
PROOF_STATE="$TMP/state"
mkdir -p "$FX" "$PROOF_STATE"
tmux new-session -d -s titled -x 150 -y 24 \
  "env LC_ALL=$UTF8 PYTHONIOENCODING=utf-8 python3 '$FIXTURE' '$FX' '$PROOF_STATE' '$ROOT' firstmate" \
  || fail "could not start the private tmux server"
PANE=$(tmux display-message -p -t titled '#{pane_id}') || fail "could not read the fixture pane"

daemon() {  # <shell snippet>
  (
    export FM_STATE_OVERRIDE="$PROOF_STATE" FM_HOME="$TMP" FM_SUPERVISOR_TARGET="$PANE" \
      FM_SUPERVISOR_BACKEND=tmux FM_INJECT_CONFIRM_SLEEP=0.25 FM_INJECT_CONFIRM_RETRIES=3 \
      FM_INJECT_PROOF_POLLS=8 LC_ALL="$UTF8" FM_DAEMON_PRIMARY_HARNESS=claude
    LOG="$PROOF_STATE/.supervise-daemon.log"
    # shellcheck source=bin/fm-supervise-daemon.sh
    . "$ROOT/bin/fm-supervise-daemon.sh"
    eval "$1"
  )
}
composer() { daemon 'fm_tmux_composer_state "$FM_SUPERVISOR_TARGET"'; }
wait_composer() {  # <state>
  local i=0
  while [ "$i" -lt 50 ]; do
    [ "$(composer)" = "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}
reset() {
  rm -f "$FX"/* "$PROOF_STATE"/.subsuper-* 2>/dev/null
  rm -rf "$PROOF_STATE/.subsuper-submit-failures" "$PROOF_STATE/operational-inbox"
  tmux send-keys -t "$PANE" C-u
  sleep 1.5
  wait_composer empty || fail "the named fixture composer did not start empty: $(composer)"
  : > "$PROOF_STATE/.supervise-daemon.log"
  : > "$FX/submitted.log"
  : > "$FX/keys.log"
}
buffer() { daemon "escalate_add \"\$FM_STATE_OVERRIDE\" '$1'"; }
flush() { daemon 'escalate_flush "$FM_STATE_OVERRIDE"'; }
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
logged() { grep -q -- "$1" "$PROOF_STATE/.supervise-daemon.log"; }
daemon 'afk_enter "$FM_STATE_OVERRIDE"'

reset
buffer 'lab-a.status: done: EVENT-ALPHA PR https://example.test/pr/1'
flush || fail "a doorbell into a named Claude composer was not delivered: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ "$(count "^: Firstmate operational input waiting: read '" "$FX/submitted.log")" -eq 1 ] \
  || fail "the doorbell was not submitted once: $(cat "$FX/submitted.log")"
logged 'inject delivered (1 event(s)' || fail "the delivery was not logged"
[ ! -e "$PROOF_STATE/.subsuper-inject-owned" ] || fail "a proven delivery left the owned-digest record"
pass "a doorbell into a named Claude composer is shown, submitted once, and proven"

reset
# A doorbell an earlier flush typed but never submitted, with its owned record.
buffer 'lab-b.status: blocked: EVENT-BRAVO needs a pick'
daemon 'fm_operational_record_write "$FM_STATE_OVERRIDE" away-supervisor "Supervisor escalate (1 event(s)): lab-b" bell && printf "%s" "$bell" > "$FM_STATE_OVERRIDE/.bell"'
bell=$(cat "$PROOF_STATE/.bell")
tmux send-keys -t "$PANE" -l "$bell"
wait_composer pending || fail "the leftover doorbell did not reach the composer"
daemon 'n=$(wc -l < "$FM_STATE_OVERRIDE/.subsuper-escalations"); s=$(cksum < "$FM_STATE_OVERRIDE/.subsuper-escalations" | cut -d" " -f1); oprec=; fm_operational_doorbell_path "$(cat "$FM_STATE_OVERRIDE/.bell")" oprec; _owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" tmux "$(cat "$FM_STATE_OVERRIDE/.bell")" "$((n + 0))" "$s" "$oprec"'
flush || fail "the leftover owned doorbell was not recovered: $(cat "$PROOF_STATE/.supervise-daemon.log")"
logged 'inject recovered: submitted the owned digest left in the composer' \
  || fail "recovery did not submit the owned doorbell: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ "$(count "^: Firstmate operational input waiting: read '" "$FX/submitted.log")" -eq 1 ] \
  || fail "the leftover doorbell was not submitted exactly once"
pass "a leftover owned doorbell in a named Claude composer is submitted by recovery"

reset
daemon '_owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" tmux "$(cat "$FM_STATE_OVERRIDE/.bell" 2>/dev/null || echo x)" 1 x' 2>/dev/null
printf '%s' "$bell" > "$PROOF_STATE/.bell"
daemon '_owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" tmux "$(cat "$FM_STATE_OVERRIDE/.bell")" 1 x'
tmux send-keys -t "$PANE" -l "$bell"
wait_composer pending || fail "the unsent doorbell did not reach the composer"
FM_STATE_OVERRIDE="$PROOF_STATE" LC_ALL="$UTF8" "$ROOT/bin/fm-supervise-daemon.sh" clear-owned-input \
  || fail "the exit cleanup did not clear the daemon's doorbell from a named composer"
wait_composer empty || fail "the daemon's doorbell is still in the named composer: $(composer)"
[ ! -s "$FX/submitted.log" ] || fail "the exit cleanup submitted something: $(cat "$FX/submitted.log")"
pass "the exit cleanup clears the daemon's own doorbell from a named Claude composer"
