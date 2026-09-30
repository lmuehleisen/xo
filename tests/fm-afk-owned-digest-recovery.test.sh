#!/usr/bin/env bash
# shellcheck disable=SC2016 # Daemon snippets expand inside the daemon() subshell, which sources the daemon library.
# tests/fm-afk-owned-digest-recovery.test.sh - the away daemon resolves a digest
# that an unconfirmed submit left in the primary's composer.
#
# A private -S tmux server runs a small composer fixture shaped like Claude Code:
# a bare "❯ " prompt that autowraps long input, an optional one-shot Enter that
# is eaten on a U+2063-marked draft (the mark is stripped and a review banner
# below a blank row parks the cursor off the composer, which reads unknown), an
# optional mode that swallows every Enter, and Ctrl+U deleting one wrapped row
# per press. A submitted line starts a visible turn: a working footer shows above
# the prompt for about a second, the turn-start proof the daemon requires. Every
# submitted line and every Enter or Ctrl+U the fixture receives is logged, so
# assertions read what reached the primary, not pane appearance.
#
#   1. An unknown verdict, deferrals while the composer is unidentified, then
#      recovery once it reads pending: the owned digest is submitted once and
#      only the events it did not carry follow.
#   2. Give-up: when Enter never lands, the owned digest is cleared row by row
#      and no daemon text is left behind; nothing is submitted.
#   3. A draft, or the owned digest with text added to it, is never submitted or
#      cleared.
#   4. A stale owned digest whose events are no longer buffered is cleared,
#      never submitted.
#
# Every tmux command runs under env -u TMUX -u TMUX_PANE against the explicit
# -S socket through a PATH shim, so the ambient server is never touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
TMP=$(fm_test_tmproot fm-afk-owned)
# A short socket directory keeps the socket path under macOS's 103-byte limit.
SOCKDIR=$(mktemp -d /tmp/fmao.XXXXXX)
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

UTF8=
for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if [ "$(LC_ALL=$loc bash -c 'x=$(printf "\xe2\x9d\xaf"); printf %s "${#x}"' 2>/dev/null)" = 1 ]; then
    UTF8=$loc
    break
  fi
done
[ -n "$UTF8" ] || { echo "skip: no UTF-8 locale for the composer fixture"; exit 0; }

FIXTURE="$TMP/composer.sh"
cat > "$FIXTURE" <<'FIX'
#!/usr/bin/env bash
# <dir>: submitted.log, keys.log, and the mode flags eat-marked-enter,
# swallow-enter, banner (present while the review banner shows).
DIR=$1
MARK=$'\xE2\x81\xA3'
stty -echo -icanon min 1 time 0 2>/dev/null || true
buf=
working=
redraw() {
  printf '\033[H\033[J'
  [ -z "$working" ] || printf 'Working... (esc to interrupt)\n'
  printf '\xe2\x9d\xaf %s' "$buf"
  [ -e "$DIR/banner" ] && printf '\n\n  Removed 1 invisible character - review and press Enter to send'
}
cols() { tput cols 2>/dev/null || echo 80; }
while :; do
  if ! IFS= read -r -n 1 -t 1 ch; then
    # Timeout: the banner is dismissed from outside by removing its flag.
    if [ -n "${shown_banner:-}" ] && [ ! -e "$DIR/banner" ]; then
      shown_banner=
      redraw
    fi
    if [ -n "$working" ]; then
      working=
      redraw
    fi
    continue
  fi
  case "$ch" in
    ''|$'\r'|$'\n')
      printf 'Enter\n' >> "$DIR/keys.log"
      if [ -e "$DIR/eat-marked-enter" ] && [ "${buf:0:1}" = "$MARK" ]; then
        rm -f "$DIR/eat-marked-enter"
        buf=${buf#"$MARK"}
        : > "$DIR/banner"
        shown_banner=1
        redraw
        continue
      fi
      if [ -e "$DIR/swallow-enter" ] || [ -z "$buf" ]; then
        continue
      fi
      printf '%s\n' "$buf" >> "$DIR/submitted.log"
      buf=
      working=1
      rm -f "$DIR/banner"
      shown_banner=
      redraw
      ;;
    $'\x15')
      printf 'C-u\n' >> "$DIR/keys.log"
      w=$(cols)
      first=$((w - 2))
      if [ "${#buf}" -le "$first" ]; then
        buf=
      else
        rem=$(( (${#buf} - first) % w ))
        [ "$rem" -gt 0 ] || rem=$w
        buf=${buf:0:$((${#buf} - rem))}
      fi
      redraw
      ;;
    *) buf="$buf$ch"; redraw ;;
  esac
done
FIX
chmod +x "$FIXTURE"

FX="$TMP/fx"
OWNED_STATE="$TMP/state"
mkdir -p "$FX" "$OWNED_STATE"
tmux new-session -d -s owned -x 100 -y 30 "env LC_ALL=$UTF8 bash '$FIXTURE' '$FX'" \
  || fail "could not start the private tmux server"
PANE=$(tmux display-message -p -t owned '#{pane_id}') || fail "could not read the fixture pane"

# Every daemon call runs in a subshell with the daemon library sourced against
# the fixture pane, as the housekeeping tick calls escalate_flush.
daemon() {  # <shell snippet>
  (
    export FM_STATE_OVERRIDE="$OWNED_STATE" FM_HOME="$TMP" FM_SUPERVISOR_TARGET="$PANE" \
      FM_SUPERVISOR_BACKEND=tmux FM_INJECT_CONFIRM_SLEEP=0.3 FM_INJECT_CONFIRM_RETRIES=3 \
      FM_INJECT_PROOF_POLLS=6 \
      LC_ALL="$UTF8" FM_DAEMON_PRIMARY_HARNESS=unknown
    # The fixture exercises a typed marked envelope, so the primary is pinned to one
    # that receives it; a harness detected from this suite's own ancestry could be
    # Claude Code, which gets a record-backed doorbell instead.
    LOG="$OWNED_STATE/.supervise-daemon.log"
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

wait_idle() {
  local i=0
  while [ "$i" -lt 50 ]; do
    tmux capture-pane -p -t "$PANE" | grep -q 'esc to interrupt' || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

reset() {
  rm -f "$FX"/* "$OWNED_STATE"/.subsuper-* 2>/dev/null
  rm -rf "$OWNED_STATE/.subsuper-submit-failures"
  : > "$OWNED_STATE/.supervise-daemon.log"
  : > "$FX/submitted.log"
  : > "$FX/keys.log"
  tmux send-keys -t "$PANE" C-u C-u C-u C-u C-u C-u C-u C-u
  wait_composer empty || fail "the fixture composer did not start empty"
  wait_idle || fail "the fixture turn did not end"
  : > "$FX/keys.log"
}

buffer() {  # <event>...
  local e
  for e in "$@"; do
    daemon "escalate_add \"\$FM_STATE_OVERRIDE\" '$e'"
  done
}

flush() { daemon 'escalate_flush "$FM_STATE_OVERRIDE"'; }
captures() { find "$OWNED_STATE/.subsuper-submit-failures" -type f -name '*.txt' 2>/dev/null | wc -l | tr -d ' '; }
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

daemon 'afk_enter "$FM_STATE_OVERRIDE"'

# --- 1. unknown verdict, deferrals, recovery -------------------------------
reset
touch "$FX/eat-marked-enter"
buffer 'lab-a.status: blocked: EVENT-ALPHA needs a design pick between the legacy adapter and the typed registry' \
  'lab-b.status: done: EVENT-BRAVO PR https://example.test/pr/1'
if flush; then
  fail "a submit whose Enter was eaten reported delivery"
fi
[ -e "$FX/banner" ] || fail "the fixture did not eat the marked Enter"
[ "$(composer)" = unknown ] || fail "the review banner did not leave the composer unidentified: $(composer)"
grep -q 'inject failed at Enter confirmation: delivery unproven .*verdict=unproven.*pane capture: ' "$OWNED_STATE/.supervise-daemon.log" \
  || fail "the failed submit did not log its verdict and pane capture"
[ -s "$OWNED_STATE/.subsuper-inject-owned" ] || fail "the failed submit left no owned-digest record"
first_capture=$(find "$OWNED_STATE/.subsuper-submit-failures" -type f -name '*.txt' | head -1)
tr -d '\n' < "$first_capture" | grep -q EVENT-ALPHA || fail "the pane capture does not show the stuck digest: $first_capture"
pass "an eaten Enter logs an unproven delivery, keeps the owned digest record, and saves a pane capture"

keys_before=$(wc -l < "$FX/keys.log")
flush && fail "a flush typed while the owned digest sat in an unidentified composer"
buffer 'lab-c.status: blocked: EVENT-CHARLIE arrived during the wedge'
flush && fail "a second flush typed while the owned digest sat in an unidentified composer"
[ "$(wc -l < "$FX/keys.log")" -eq "$keys_before" ] \
  || fail "the daemon sent keys into an unidentified composer"
[ ! -s "$FX/submitted.log" ] || fail "something was submitted during the deferrals: $(cat "$FX/submitted.log")"
[ "$(count 'inject recovery waiting' "$OWNED_STATE/.supervise-daemon.log")" -eq 1 ] \
  || fail "the unidentified composer was not noted exactly once"
[ "$(captures)" -eq 2 ] || fail "expected one capture for the failure and one for the wait, got $(captures)"
pass "while the composer is unidentified the daemon defers without sending a key, noting it once"

rm -f "$FX/banner"
wait_composer pending || fail "the dismissed banner did not leave the composer pending: $(composer)"
# The recovered digest starts a turn, so the fresh digest waits for it to end.
flush && fail "a fresh digest was typed while the recovered digest's turn was showing"
grep -q 'inject deferred: supervisor pane shows a turn in progress' "$OWNED_STATE/.supervise-daemon.log" \
  || fail "the fresh digest did not defer on the turn in progress"
wait_idle || fail "the fixture turn did not end"
flush || fail "the flush after recovery did not deliver"
[ "$(wc -l < "$FX/submitted.log")" -eq 2 ] \
  || fail "expected the recovered digest and one fresh digest: $(cat "$FX/submitted.log")"
recovered=$(sed -n 1p "$FX/submitted.log")
fresh=$(sed -n 2p "$FX/submitted.log")
case "$recovered" in
  'FIRSTMATE_OP: v1 away-supervisor: Supervisor escalate (2 event(s)): '*EVENT-ALPHA*EVENT-BRAVO*) ;;
  *) fail "the recovered submission is not the owned digest: $recovered" ;;
esac
case "$recovered" in *EVENT-CHARLIE*) fail "the recovered digest carried a later event" ;; esac
case "$fresh" in
  *EVENT-CHARLIE*) ;;
  *) fail "the event buffered during the wedge did not follow: $fresh" ;;
esac
case "$fresh" in *EVENT-ALPHA*|*EVENT-BRAVO*) fail "the recovered events were delivered twice: $fresh" ;; esac
[ ! -e "$OWNED_STATE/.subsuper-inject-owned" ] || fail "the owned-digest record survived a recovered submit"
[ ! -s "$OWNED_STATE/.subsuper-escalations" ] || fail "delivered events stayed buffered"
grep -q 'inject recovered: submitted the owned digest left in the composer (2 event(s))' "$OWNED_STATE/.supervise-daemon.log" \
  || fail "the recovery was not logged"
pass "once the composer reads pending the owned digest is submitted once, then only the later event follows"

# --- 2. give-up clears the owned digest ------------------------------------
reset
touch "$FX/swallow-enter"
buffer 'lab-d.status: blocked: EVENT-DELTA the rollout needs a window pick before the next deploy train leaves' \
  'lab-e.status: failed: EVENT-ECHO validation failed on the migration check and the retry budget is spent'
flush && fail "a swallowed submit reported delivery"
grep -q 'verdict=pending' "$OWNED_STATE/.supervise-daemon.log" || fail "the swallowed submit did not log pending"
[ "$(composer)" = pending ] || fail "the swallowed digest is not pending in the composer"
flush && fail "a give-up flush reported delivery"
[ "$(composer)" = empty ] || fail "the give-up left the composer $(composer)"
[ ! -s "$FX/submitted.log" ] || fail "the give-up submitted something: $(cat "$FX/submitted.log")"
[ "$(count C-u "$FX/keys.log")" -ge 2 ] || fail "the wrapped digest was not cleared row by row"
[ ! -e "$OWNED_STATE/.subsuper-inject-owned" ] || fail "the owned-digest record survived a confirmed cleanup"
grep -q 'inject recovery gave up: away-mode digest did not run .*cleared owned input; its events stay buffered' \
  "$OWNED_STATE/.supervise-daemon.log" || fail "the give-up was not logged"
[ "$(captures)" -eq 2 ] || fail "expected a capture for the failure and one for the give-up, got $(captures)"
[ "$(wc -l < "$OWNED_STATE/.subsuper-escalations" | tr -d ' ')" -eq 2 ] || fail "the give-up dropped buffered events"
rm -f "$FX/swallow-enter"
flush || fail "the flush after a give-up did not deliver a fresh digest"
[ "$(count EVENT-DELTA "$FX/submitted.log")" -eq 1 ] || fail "the fresh digest after a give-up is missing or doubled"
pass "a digest whose Enter never lands is cleared row by row, leaving no daemon text, and delivered fresh later"

# --- 3. text the daemon cannot prove it owns --------------------------------
reset
touch "$FX/swallow-enter"
buffer 'lab-f.status: blocked: EVENT-FOXTROT needs a pick'
flush && fail "a swallowed submit reported delivery"
tmux send-keys -t "$PANE" -l ' and the captain kept typing'
sleep 0.3
keys_before=$(wc -l < "$FX/keys.log")
flush && fail "a flush acted on a composer holding added text"
flush && fail "a second flush acted on a composer holding added text"
[ "$(wc -l < "$FX/keys.log")" -eq "$keys_before" ] || fail "the daemon sent keys into a composer holding added text"
tmux capture-pane -p -J -t "$PANE" | tr -d '\n' | grep -q 'the captain kept typing' \
  || fail "the added text is gone"
grep -q 'the composer holds text the daemon cannot prove it typed' "$OWNED_STATE/.supervise-daemon.log" \
  || fail "the unowned composer was not noted"
pass "the owned digest with text added to it is never submitted or cleared"

reset
buffer 'lab-g.status: blocked: EVENT-GOLF needs a pick'
tmux send-keys -t "$PANE" -l 'a draft from before the daemon typed'
sleep 0.3
daemon '_owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" tmux "a draft from before the daemon" 1 x'
flush && fail "a flush acted on a draft the daemon did not type"
[ ! -s "$FX/keys.log" ] || fail "the daemon sent keys into a draft it did not type"
pass "a draft that only resembles the owned digest is never touched"

reset
buffer 'lab-g.status: blocked: EVENT-GOLF needs a pick'
tmux send-keys -t "$PANE" -l 'the owned  digest after the captain added a space'
sleep 0.3
daemon '_owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" tmux "the owned digest after the captain added a space" 1 x'
flush && fail "a flush acted on a respaced owned digest"
[ ! -s "$FX/keys.log" ] || fail "the daemon sent keys into an owned digest whose spacing changed"
pass "an owned digest whose spacing the captain changed is never touched"

# --- 4. a stale owned digest is cleared, never submitted --------------------
reset
touch "$FX/swallow-enter"
buffer 'lab-h.status: blocked: EVENT-HOTEL needs a pick'
flush && fail "a swallowed submit reported delivery"
rm -f "$FX/swallow-enter"
# A return and a new away window reset the buffer; a new event arrives.
: > "$OWNED_STATE/.subsuper-escalations"
buffer 'lab-i.status: blocked: EVENT-INDIA needs a pick'
flush || fail "the flush after clearing a stale owned digest did not deliver"
[ "$(count EVENT-HOTEL "$FX/submitted.log")" -eq 0 ] || fail "the stale owned digest was submitted"
[ "$(count EVENT-INDIA "$FX/submitted.log")" -eq 1 ] || fail "the new event was not delivered once"
grep -q 'cleared a stale owned digest' "$OWNED_STATE/.supervise-daemon.log" || fail "the stale cleanup was not logged"
pass "a stale owned digest whose events are no longer buffered is cleared, never submitted"
