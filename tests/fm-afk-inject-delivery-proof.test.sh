#!/usr/bin/env bash
# shellcheck disable=SC2016 # Daemon snippets expand inside the daemon() subshell, which sources the daemon library.
# tests/fm-afk-inject-delivery-proof.test.sh - the away daemon counts a digest
# delivered only on positive proof (fm_tmux_proven_submit), owns what it types
# before typing it, and clears its own unsent text when away mode ends.
#
# The regression: a digest can stay unsent in a Claude primary's composer when
# its Enter lands inside Claude Code's paste window and the submit check reads
# the composer as empty from a frame the primary has not yet redrawn. Counting
# that as delivered writes no owned-digest record and defers every later
# digest.
#
# A private -S tmux server runs a small composer fixture shaped like Claude
# Code. It reads keys in real time, which bash 3.2 cannot, so it is Python:
#   - an Enter read within 150 ms of the last typed character is folded into
#     the paste, as Claude Code does, and logged as paste-swallowed;
#   - `frozen` stops it reading and drawing, so the screen keeps showing the
#     old empty composer while typed keys wait unread;
#   - a submitted line starts a turn (a working footer for about a second)
#     unless `no-turn`, and `open-doorbell` makes the turn open the record a
#     submitted doorbell names, as the primary does;
#   - the first typed character logs whether the owned-digest record exists;
#   - `swallow` drops every Enter, and `hide-composer` draws only a working
#     footer with no prompt row, so the composer cannot be read at all.
#
#   1. A normal delivery: the owned record exists before the first key, the
#      delivery is proven by the turn, logged with its evidence, and the
#      record is removed.
#   2. The quiet gap: an Enter sent right after typing into a primary that
#      reads the burst late is folded into the paste; the daemon instead waits
#      for the digest to show unchanged and delivers with one Enter.
#   3. The false success: while the typed digest never shows, the composer
#      still reads empty; the daemon sends no Enter, reports failure, keeps
#      the owned record, and a later flush submits the digest once.
#   4. A Claude primary: the opened record proves delivery with no visible
#      turn; with neither, the submit is unproven, and a late open is counted
#      as delivery instead of typing the doorbell again.
#   5. The exit cleanup clears the daemon's own unsent digest and never a draft.
#   6. A working footer beside an unreadable composer is not delivery: the
#      digest may still be there, so the daemon waits for a readable composer.
#
# Every tmux command runs under env -u TMUX -u TMUX_PANE against the explicit
# -S socket through a PATH shim, so the ambient server is never touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

REAL_TMUX=$(command -v tmux)
TMP=$(fm_test_tmproot fm-afk-proof)
# A short socket directory keeps the socket path under macOS's 103-byte limit.
SOCKDIR=$(mktemp -d /tmp/fmap.XXXXXX)
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

FIXTURE="$TMP/composer.py"
cat > "$FIXTURE" <<'FIX'
import codecs, os, select, subprocess, sys, time, tty

DIR, STATE, ROOT = sys.argv[1], sys.argv[2], sys.argv[3]
PASTE_WINDOW = 0.15
DOORBELL_HEAD = ": Firstmate operational input waiting: read '"
fd = sys.stdin.fileno()
tty.setraw(fd)
decode = codecs.getincrementaldecoder("utf-8")(errors="replace").decode
buf, last_read, working_until, drawn = "", 0.0, 0.0, None


def has(name):
    return os.path.exists(os.path.join(DIR, name))


def log(name, line):
    with open(os.path.join(DIR, name), "a") as f:
        f.write(line + "\n")


def redraw():
    global drawn
    hidden = has("hide-composer")
    frame = ("Working... (esc to interrupt)" if hidden or time.time() < working_until else "", buf, hidden)
    if frame == drawn:
        return
    drawn = frame
    # Rows are erased in place: a full-screen clear would push a stale footer
    # into scrollback.
    row = "" if hidden else "❯ " + frame[1]
    sys.stdout.write("\x1b[H\x1b[2K" + frame[0] + "\r\n\x1b[2K" + row + "\x1b[J")
    sys.stdout.flush()


def submit(now):
    global buf, working_until
    log("submitted.log", buf)
    if has("open-doorbell") and buf.startswith(DOORBELL_HEAD):
        path = buf[len(DOORBELL_HEAD):].split("'", 1)[0]
        subprocess.run([ROOT + "/bin/fm-operational-input.sh", "open", path],
                       env=dict(os.environ, FM_STATE_OVERRIDE=STATE),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if not has("no-turn"):
        working_until = now + 1.2
    buf = ""


redraw()
while True:
    if has("frozen"):
        time.sleep(0.05)
        continue
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready and not has("frozen"):
        for ch in decode(os.read(fd, 4096)):
            now = time.time()
            if ch in "\r\n":
                log("keys.log", "Enter")
                if now - last_read < PASTE_WINDOW:
                    log("keys.log", "paste-swallowed")
                elif buf and not has("swallow"):
                    submit(now)
            elif ch == "\x15":
                log("keys.log", "C-u")
                buf = ""
            else:
                if not buf:
                    owned = os.path.exists(os.path.join(STATE, ".subsuper-inject-owned"))
                    log("keys.log", "first-key owned-record=" + ("yes" if owned else "no"))
                buf += ch
                last_read = now
    redraw()
FIX

FX="$TMP/fx"
PROOF_STATE="$TMP/state"
mkdir -p "$FX" "$PROOF_STATE"
tmux new-session -d -s proof -x 220 -y 20 \
  "env LC_ALL=$UTF8 PYTHONIOENCODING=utf-8 python3 '$FIXTURE' '$FX' '$PROOF_STATE' '$ROOT'" \
  || fail "could not start the private tmux server"
PANE=$(tmux display-message -p -t proof '#{pane_id}') || fail "could not read the fixture pane"

# Every daemon call runs in a subshell with the daemon library sourced against
# the fixture pane, as the housekeeping tick calls escalate_flush. HARNESS pins
# the primary: unknown receives the typed envelope, claude the doorbell.
HARNESS=unknown
daemon() {  # <shell snippet>
  (
    export FM_STATE_OVERRIDE="$PROOF_STATE" FM_HOME="$TMP" FM_SUPERVISOR_TARGET="$PANE" \
      FM_SUPERVISOR_BACKEND=tmux FM_INJECT_CONFIRM_SLEEP=0.25 FM_INJECT_CONFIRM_RETRIES=3 \
      FM_INJECT_PROOF_POLLS=8 LC_ALL="$UTF8" FM_DAEMON_PRIMARY_HARNESS="$HARNESS"
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
  rm -f "$FX"/* "$PROOF_STATE"/.subsuper-* 2>/dev/null
  rm -rf "$PROOF_STATE/.subsuper-submit-failures" "$PROOF_STATE/operational-inbox"
  tmux send-keys -t "$PANE" C-u
  wait_composer empty || fail "the fixture composer did not start empty"
  wait_idle || fail "the fixture turn did not end"
  : > "$PROOF_STATE/.supervise-daemon.log"
  : > "$FX/submitted.log"
  : > "$FX/keys.log"
}

buffer() { daemon "escalate_add \"\$FM_STATE_OVERRIDE\" '$1'"; }
flush() { daemon 'escalate_flush "$FM_STATE_OVERRIDE"'; }
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }
logged() { grep -q -- "$1" "$PROOF_STATE/.supervise-daemon.log"; }

daemon 'afk_enter "$FM_STATE_OVERRIDE"'

# --- 1. a proven delivery ----------------------------------------------------
reset
buffer 'lab-a.status: done: EVENT-ALPHA PR https://example.test/pr/1'
flush || fail "a normal flush did not deliver: $(cat "$PROOF_STATE/.supervise-daemon.log")"
grep -qx 'first-key owned-record=yes' "$FX/keys.log" \
  || fail "the owned-digest record did not exist before the first key: $(cat "$FX/keys.log")"
[ "$(count EVENT-ALPHA "$FX/submitted.log")" -eq 1 ] || fail "the digest was not submitted once"
[ "$(count '^Enter$' "$FX/keys.log")" -eq 1 ] || fail "a delivered digest took more than one Enter"
logged 'inject delivered (1 event(s), [0-9]* bytes, enter=1 polls=[0-9]* proof=busy)' \
  || fail "the delivery was not logged with its evidence: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ ! -e "$PROOF_STATE/.subsuper-inject-owned" ] || fail "a proven delivery left the owned-digest record"
[ ! -s "$PROOF_STATE/.subsuper-escalations" ] || fail "a delivered event stayed buffered"
pass "a delivery is owned before the first key, proven by the turn it starts, and logged with its evidence"

# --- 2. the quiet gap ----------------------------------------------------------
reset
# The hazard is real in this fixture: an Enter sent right after typing into a
# primary that reads the burst late is folded into the paste.
touch "$FX/frozen"
tmux send-keys -t "$PANE" -l 'a burst the primary reads late'
tmux send-keys -t "$PANE" Enter
sleep 0.3
rm -f "$FX/frozen"
wait_composer pending || fail "the late-read burst did not reach the composer"
grep -qx paste-swallowed "$FX/keys.log" || fail "the fixture did not fold an Enter inside the paste window"
[ ! -s "$FX/submitted.log" ] || fail "an Enter inside the paste window submitted: $(cat "$FX/submitted.log")"
pass "an Enter that follows a late-read burst inside the paste window is swallowed"

reset
buffer 'lab-b.status: blocked: EVENT-BRAVO needs a pick'
touch "$FX/frozen"
( sleep 1; rm -f "$FX/frozen" ) &
flush || fail "a flush into a primary that read the burst late did not deliver: $(cat "$PROOF_STATE/.supervise-daemon.log")"
wait
[ "$(count paste-swallowed "$FX/keys.log")" -eq 0 ] || fail "the daemon's Enter landed inside the paste window"
[ "$(count '^Enter$' "$FX/keys.log")" -eq 1 ] || fail "expected exactly one Enter: $(cat "$FX/keys.log")"
[ "$(count EVENT-BRAVO "$FX/submitted.log")" -eq 1 ] || fail "the late-read digest was not submitted once"
pass "Enter waits until the digest shows unchanged, so a late-read burst is submitted by one Enter"

# --- 3. the false success ------------------------------------------------------
reset
buffer 'lab-c.status: failed: EVENT-CHARLIE validation failed'
touch "$FX/frozen"
flush && fail "a digest that never showed in the composer was reported delivered"
# The divergence the old rule trusted: the composer reads empty while the
# typed digest sits unread.
[ "$(composer)" = empty ] || fail "the frozen composer did not read empty: $(composer)"
logged 'inject failed at typing: the digest never showed unchanged in the composer, so no Enter was sent (verdict=unshown' \
  || fail "the unshown digest was not logged: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ -s "$PROOF_STATE/.subsuper-inject-owned" ] || fail "the unshown digest left no owned-digest record"
[ -s "$PROOF_STATE/.subsuper-escalations" ] || fail "the undelivered event was dropped"
rm -f "$FX/frozen"
wait_composer pending || fail "the typed digest did not reach the composer once the primary resumed"
[ "$(count '^Enter$' "$FX/keys.log")" -eq 0 ] || fail "an Enter was sent for a digest that never showed"
flush || fail "the flush after the digest showed did not deliver: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ "$(count EVENT-CHARLIE "$FX/submitted.log")" -eq 1 ] || fail "the owned digest was not submitted exactly once"
logged 'inject recovered: submitted the owned digest left in the composer (1 event(s))' \
  || fail "the owned digest was not recovered by submitting it"
[ ! -e "$PROOF_STATE/.subsuper-inject-owned" ] || fail "the recovered digest left its record"
[ ! -s "$PROOF_STATE/.subsuper-escalations" ] || fail "the recovered event stayed buffered"
pass "a composer that reads empty is not delivery: no Enter, a kept owned record, and a later single submit"

# --- 4. a Claude primary -------------------------------------------------------
HARNESS=claude
reset
touch "$FX/no-turn" "$FX/open-doorbell"
buffer 'lab-d.status: done: EVENT-DELTA PR https://example.test/pr/4'
flush || fail "an opened doorbell record did not prove delivery: $(cat "$PROOF_STATE/.supervise-daemon.log")"
logged 'inject delivered (1 event(s), [0-9]* bytes, enter=1 polls=[0-9]* proof=record-opened)' \
  || fail "the record-opened proof was not logged: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ "$(count "^: Firstmate operational input waiting: read '" "$FX/submitted.log")" -eq 1 ] \
  || fail "the doorbell was not submitted once"
pass "for a Claude primary, the primary opening the doorbell's record proves delivery"

reset
touch "$FX/no-turn"
buffer 'lab-e.status: blocked: EVENT-ECHO needs a pick'
flush && fail "a doorbell with no turn and no opened record was reported delivered"
logged 'inject failed at Enter confirmation: delivery unproven .*verdict=unproven' \
  || fail "the unproven doorbell was not logged: $(cat "$PROOF_STATE/.supervise-daemon.log")"
record=$(sed -n 's/^record=//p' "$PROOF_STATE/.subsuper-inject-owned")
[ -n "$record" ] && [ -f "$record" ] || fail "the owned-digest record does not name the doorbell's record"
# The primary reads the record late, after the delivery check gave up.
FM_STATE_OVERRIDE="$PROOF_STATE" "$ROOT/bin/fm-operational-input.sh" open "$record" >/dev/null \
  || fail "the doorbell's record could not be opened"
flush || fail "a late open did not count as delivery: $(cat "$PROOF_STATE/.supervise-daemon.log")"
logged 'inject delivered late: the primary opened the owned digest' || fail "the late delivery was not logged"
[ "$(count "^: Firstmate operational input waiting: read '" "$FX/submitted.log")" -eq 1 ] \
  || fail "the doorbell was typed again after a late open: $(cat "$FX/submitted.log")"
[ ! -s "$PROOF_STATE/.subsuper-escalations" ] || fail "the late-delivered event stayed buffered"
pass "without a turn or an opened record the doorbell is unproven, and a late open counts instead of a retype"
HARNESS=unknown

# --- 5. exit cleanup -----------------------------------------------------------
reset
buffer 'lab-f.status: blocked: EVENT-FOXTROT needs a pick'
touch "$FX/frozen"
flush && fail "a digest that never showed was reported delivered"
rm -f "$FX/frozen"
wait_composer pending || fail "the typed digest did not reach the composer"
FM_STATE_OVERRIDE="$PROOF_STATE" LC_ALL="$UTF8" "$ROOT/bin/fm-supervise-daemon.sh" clear-owned-input \
  || fail "the exit cleanup did not clear the daemon's own digest"
wait_composer empty || fail "the daemon's digest is still in the composer: $(composer)"
[ ! -s "$FX/submitted.log" ] || fail "the exit cleanup submitted something: $(cat "$FX/submitted.log")"
[ ! -e "$PROOF_STATE/.subsuper-inject-owned" ] || fail "the exit cleanup kept a record for cleared text"
pass "the exit cleanup clears the daemon's own unsent digest without submitting it"

reset
tmux send-keys -t "$PANE" -l 'a captain draft'
wait_composer pending || fail "the draft did not reach the composer"
daemon '_owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" tmux "a captain" 1 x'
if FM_STATE_OVERRIDE="$PROOF_STATE" LC_ALL="$UTF8" "$ROOT/bin/fm-supervise-daemon.sh" clear-owned-input 2>"$TMP/clear.err"; then
  fail "the exit cleanup reported clean while a draft it did not type sits in the composer"
fi
grep -q 'may still be in the input box' "$TMP/clear.err" || fail "the exit cleanup did not warn: $(cat "$TMP/clear.err")"
tmux capture-pane -p -t "$PANE" | grep -q 'a captain draft' || fail "the exit cleanup touched a draft"
[ "$(count C-u "$FX/keys.log")" -eq 0 ] || fail "the exit cleanup sent a key into a draft"
pass "the exit cleanup never touches a draft it did not type, and says so"

# --- 6. an unreadable composer beside a working footer -----------------------
reset
buffer 'lab-g.status: blocked: EVENT-GOLF needs a pick'
touch "$FX/swallow"
# The Enter is dropped, then the screen shows only a working footer, as a
# harness that replaces its composer while busy would; the digest is still
# unsent behind it.
( while [ "$(count '^Enter$' "$FX/keys.log")" -eq 0 ]; do sleep 0.05; done; touch "$FX/hide-composer" ) &
flush && fail "a working footer beside an unreadable composer was reported delivered"
wait
[ "$(composer)" = unknown ] || fail "the hidden composer did not read unknown: $(composer)"
logged 'inject failed at Enter confirmation: delivery unproven .*verdict=turn-started busy' \
  || fail "the unconfirmed turn was not logged: $(cat "$PROOF_STATE/.supervise-daemon.log")"
grep -qx 'turn=1' "$PROOF_STATE/.subsuper-inject-owned" || fail "the owned record did not keep the turn it saw"
[ -s "$PROOF_STATE/.subsuper-escalations" ] || fail "the unconfirmed event was dropped"
rm -f "$FX/swallow" "$FX/hide-composer"
wait_composer pending || fail "the unsent digest did not reappear in the composer"
wait_idle || fail "the fixture footer did not clear"
flush || fail "the still-unsent digest was not recovered: $(cat "$PROOF_STATE/.supervise-daemon.log")"
[ "$(count EVENT-GOLF "$FX/submitted.log")" -eq 1 ] || fail "the recovered digest was not submitted exactly once"
[ ! -s "$PROOF_STATE/.subsuper-escalations" ] || fail "the recovered event stayed buffered"
pass "a working footer beside an unreadable composer is not delivery; the digest still there is submitted once"

reset
buffer 'lab-h.status: done: EVENT-HOTEL PR https://example.test/pr/8'
# A turn hides the composer as it starts and shows it empty once it ends.
( while [ "$(count '^Enter$' "$FX/keys.log")" -eq 0 ]; do sleep 0.02; done; touch "$FX/hide-composer"; sleep 1; rm -f "$FX/hide-composer" ) &
flush || fail "a turn seen while the composer was hidden was not delivered once it read empty: $(cat "$PROOF_STATE/.supervise-daemon.log")"
wait
logged 'inject delivered (1 event(s), [0-9]* bytes, enter=1 polls=[0-9]* proof=busy)' || fail "the delivery was not logged"
[ "$(count EVENT-HOTEL "$FX/submitted.log")" -eq 1 ] || fail "the digest was not submitted once"
pass "a turn seen while the composer was unreadable is delivery once a readable composer confirms the text gone"
