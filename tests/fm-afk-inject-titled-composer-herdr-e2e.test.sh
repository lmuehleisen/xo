#!/usr/bin/env bash
# shellcheck disable=SC2016 # Daemon snippets expand inside the hdaemon() subshell, which sources the daemon library.
# tests/fm-afk-inject-titled-composer-herdr-e2e.test.sh - the herdr counterpart
# of tests/fm-afk-inject-titled-composer.test.sh: the away daemon must deliver,
# recover, and clear its own digest in a named Claude Code composer on real
# herdr.
#
# Herdr reads every composer without a cursor, so a reader that missed Claude's
# titled top rule read an idle named composer as `unknown` and typed nothing.
# Herdr also left the daemon's text behind whenever the primary did not take
# its Enter, with no owned record to recover it, so every later escalation
# deferred behind that text. tests/named-claude-composer-fixture.py runs in an
# isolated lab session, reporting itself as a Claude agent, and:
#   - an idle named composer reads `empty`;
#   - a doorbell is submitted once and proven;
#   - a doorbell whose every Enter was dropped is submitted by the next flush's
#     recovery;
#   - a human draft is left alone;
#   - the exit cleanup clears the daemon's own doorbell.
# Every herdr call names the lab session explicitly (tests/herdr-test-safety.sh).
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

UTF8=
for loc in C.UTF-8 C.utf8 en_US.UTF-8 en_US.utf8; do
  if [ "$(LC_ALL=$loc bash -c 'x=$(printf "\xe2\x9d\xaf"); printf %s "${#x}"' 2>/dev/null)" = 1 ]; then
    UTF8=$loc
    break
  fi
done
[ -n "$UTF8" ] || { echo "skip: no UTF-8 locale for the composer fixture"; exit 0; }

TMP=$(fm_test_tmproot fm-afk-titled-herdr)
FIXTURE="$ROOT/tests/named-claude-composer-fixture.py"
HSESSION=
cleanup() {
  if [ -n "$HSESSION" ]; then
    herdr_safe_stop_and_delete "$HSESSION" >/dev/null 2>&1 \
      || echo "warning: the herdr lab session $HSESSION could not be torn down" >&2
  fi
  fm_test_cleanup
}
trap cleanup EXIT
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
REAL_HERDR=$(command -v herdr)
LAB=fm-lab-afk-titled-$$
fm_herdr_lab_prepare "$LAB" || fail "could not prepare an isolated herdr lab session"
HSESSION=$LAB
HFX="$TMP/hfx"
HSTATE="$TMP/hstate"
mkdir -p "$HFX" "$HSTATE" "$TMP/hbin"
# A shim that drops every Enter while $HFX/.drop-enter exists: an Enter the
# primary never takes, which herdr's own CLI cannot produce.
cat > "$TMP/hbin/herdr" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = pane ] && [ "\${2:-}" = send-keys ] && [ -e '$HFX/.drop-enter' ]; then
  for a in "\$@"; do [ "\$a" = enter ] && exit 0; done
fi
exec '$REAL_HERDR' "\$@"
EOF
chmod +x "$TMP/hbin/herdr"

hdaemon() {  # <shell snippet>
  (
    # shellcheck disable=SC2030 # the shim PATH is scoped to this subshell on purpose
    export HERDR_SESSION="$HSESSION" FM_STATE_OVERRIDE="$HSTATE" FM_HOME="$TMP" FM_SUPERVISOR_TARGET="$HSESSION:${HPANE:-}" \
      FM_SUPERVISOR_BACKEND=herdr FM_INJECT_CONFIRM_SLEEP=1 FM_INJECT_CONFIRM_RETRIES=3 \
      LC_ALL="$UTF8" FM_DAEMON_PRIMARY_HARNESS="${HHARNESS:-claude}" PATH="$TMP/hbin:$PATH"
    LOG="$HSTATE/.supervise-daemon.log"
    # shellcheck source=bin/fm-supervise-daemon.sh
    . "$ROOT/bin/fm-supervise-daemon.sh"
    fm_backend_source herdr || exit 1
    eval "$1"
  )
}

# The container is named in the lab session explicitly, and nothing is created
# unless it resolved there.
HPANE=$(hdaemon 'raw=$(fm_backend_herdr_container_ensure /tmp launcher-home "$HERDR_SESSION") || exit 1
  case "$raw" in "$HERDR_SESSION":*) ;; *) exit 1 ;; esac
  ids=$(fm_backend_herdr_create_task "${raw%%$'"'"'\t'"'"'*}" fm-afk-titled /tmp "${raw#*$'"'"'\t'"'"'}") || exit 1
  printf "%s" "${ids##* }"') || fail "could not create the herdr fixture pane"
[ -n "$HPANE" ] || fail "the herdr fixture pane has no id"
ready=0
for _ in $(seq 1 100); do
  if "$REAL_HERDR" pane process-info --pane "$HPANE" --session "$HSESSION" 2>/dev/null | jq -e '
      .result.process_info as $p | ($p.foreground_processes | length == 1)
        and ($p.foreground_processes[0].pid == $p.shell_pid)' >/dev/null 2>&1; then
    ready=$((ready + 1))
    [ "$ready" -lt 10 ] || break
  else
    ready=0
  fi
  sleep 0.1
done
[ "$ready" -ge 10 ] || fail "the herdr fixture pane's shell never became ready"
hdaemon "fm_backend_herdr_send_text_line \"\$FM_SUPERVISOR_TARGET\" \"env LC_ALL=$UTF8 PYTHONIOENCODING=utf-8 FIXTURE_COLS=40 FIXTURE_HERDR_BIN='$REAL_HERDR' FIXTURE_HERDR_SESSION='$HSESSION' python3 '$FIXTURE' '$HFX' '$HSTATE' '$ROOT' firstmate\"" \
  || fail "could not start the fixture in the herdr pane"

hcomposer() { hdaemon 'fm_backend_composer_state herdr "$FM_SUPERVISOR_TARGET"'; }
hscreen() { hdaemon 'fm_backend_herdr_visible_capture "$FM_SUPERVISOR_TARGET"' | grep -v '^[[:space:]]*$' | tail -12; }
hwait() {  # <state>
  local i=0
  while [ "$i" -lt 60 ]; do
    [ "$(hcomposer)" = "$1" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}
hreset() {
  rm -f "$HFX"/* "$HFX/.drop-enter" "$HFX/.no-turn" "$HSTATE"/.subsuper-* 2>/dev/null
  rm -rf "$HSTATE/.subsuper-submit-failures" "$HSTATE/operational-inbox"
  hdaemon 'fm_backend_herdr_send_key "$FM_SUPERVISOR_TARGET" C-u'
  sleep 1.5
  hwait empty || fail "the named herdr fixture composer did not read empty: $(hcomposer); screen:
$(hscreen)"
  : > "$HSTATE/.supervise-daemon.log"
  : > "$HFX/submitted.log"
}
hbuffer() { hdaemon "escalate_add \"\$FM_STATE_OVERRIDE\" '$1'"; }
hflush() { hdaemon 'escalate_flush "$FM_STATE_OVERRIDE"'; }
hlogged() { grep -q -- "$1" "$HSTATE/.supervise-daemon.log"; }
hlog() { cat "$HSTATE/.supervise-daemon.log"; }
doorbells() { count "^: Firstmate operational input waiting: read '" "$HFX/submitted.log"; }
hdaemon 'afk_enter "$FM_STATE_OVERRIDE"'

hreset
pass "an idle named Claude composer reads empty on herdr"

hbuffer 'lab-h1.status: done: EVENT-HOTEL PR https://example.test/pr/2'
hflush || fail "a doorbell into a named Claude composer on herdr was not delivered: $(hlog)"
[ "$(doorbells)" -eq 1 ] || fail "the herdr doorbell was not submitted once: $(cat "$HFX/submitted.log")"
hlogged 'inject delivered (1 event(s)' || fail "the herdr delivery was not logged: $(hlog)"
[ ! -e "$HSTATE/.subsuper-inject-owned" ] || fail "a proven herdr delivery left the owned-digest record"
pass "a doorbell into a named Claude composer on herdr is submitted once and proven"

hreset
: > "$HFX/.drop-enter"
hbuffer 'lab-h2.status: blocked: EVENT-INDIA needs a pick'
if hflush; then fail "a flush whose every Enter was dropped counted as delivered: $(hlog)"; fi
[ -s "$HSTATE/.subsuper-inject-owned" ] || fail "herdr kept no owned-digest record for text it left in the composer"
[ "$(hcomposer)" = pending ] || fail "the undelivered herdr doorbell is not in the composer: $(hcomposer)"
[ "$(doorbells)" -eq 0 ] || fail "a dropped Enter still submitted the doorbell"
rm -f "$HFX/.drop-enter"
hflush || fail "the next flush did not resolve the doorbell left on herdr: $(hlog)"
hlogged 'inject recovered: submitted the owned digest left in the composer' \
  || fail "herdr recovery did not submit the owned doorbell: $(hlog)"
[ "$(doorbells)" -eq 1 ] || fail "the doorbell left on herdr was not submitted exactly once: $(cat "$HFX/submitted.log")"
[ ! -s "$HSTATE/.subsuper-escalations" ] || fail "the recovered herdr events stayed buffered"
pass "a doorbell whose Enter herdr's primary never took is submitted by the next flush's recovery"

# The same recovery for a typed envelope (no operational record to open) into a
# primary whose turn native agent state never shows: the composer emptying
# after Enter is the proof, as in herdr's normal submit, so it is not retyped.
hreset
: > "$HFX/.no-turn"
: > "$HFX/.drop-enter"
hbuffer 'lab-h2b.status: done: EVENT-KILO'
if HHARNESS=unknown hflush; then fail "a typed envelope whose every Enter was dropped counted as delivered: $(hlog)"; fi
[ "$(hcomposer)" = pending ] || fail "the undelivered typed envelope is not in the herdr composer: $(hcomposer)"
rm -f "$HFX/.drop-enter"
HHARNESS=unknown hflush || fail "recovery did not count a typed envelope whose composer emptied as delivered: $(hlog)"
hlogged 'inject recovered: submitted the owned digest left in the composer' \
  || fail "herdr recovery did not submit the owned typed envelope: $(hlog)"
HHARNESS=unknown hflush || true
[ "$(count 'EVENT-KILO' "$HFX/submitted.log")" -eq 1 ] \
  || fail "the recovered typed envelope was submitted more than once: $(cat "$HFX/submitted.log")"
rm -f "$HFX/.no-turn"
pass "a recovered digest whose turn native state never shows counts as delivered once the herdr composer empties"

hreset
hdaemon 'fm_backend_herdr_send_literal "$FM_SUPERVISOR_TARGET" "a human draft"'
hwait pending || fail "the human draft did not reach the herdr composer"
hbuffer 'lab-h3.status: done: EVENT-JULIET'
if hflush; then fail "a flush typed over a human draft on herdr"; fi
[ ! -s "$HFX/submitted.log" ] || fail "a human draft on herdr was submitted or merged: $(cat "$HFX/submitted.log")"
[ "$(hcomposer)" = pending ] || fail "the human draft on herdr was cleared"
pass "a human draft in a named Claude composer on herdr is left alone"

hreset
hdaemon 'fm_operational_record_write "$FM_STATE_OVERRIDE" away-supervisor "Supervisor escalate (1 event(s)): lab-h4" bell && printf "%s" "$bell" > "$FM_STATE_OVERRIDE/.bell"
  _owned_record_write "$FM_STATE_OVERRIDE" "$FM_SUPERVISOR_TARGET" herdr "$bell" 1 x
  fm_backend_herdr_send_literal "$FM_SUPERVISOR_TARGET" "$bell"'
hwait pending || fail "the unsent doorbell did not reach the herdr composer"
# shellcheck disable=SC2031 # the CLI gets the same shim PATH hdaemon scopes to its subshell
FM_STATE_OVERRIDE="$HSTATE" LC_ALL="$UTF8" PATH="$TMP/hbin:$PATH" "$ROOT/bin/fm-supervise-daemon.sh" clear-owned-input \
  || fail "the exit cleanup did not clear the daemon's doorbell from a named herdr composer: $(hlog)"
hwait empty || fail "the daemon's doorbell is still in the named herdr composer: $(hcomposer)"
[ ! -s "$HFX/submitted.log" ] || fail "the herdr exit cleanup submitted something: $(cat "$HFX/submitted.log")"
pass "the exit cleanup clears the daemon's own doorbell from a named Claude composer on herdr"
