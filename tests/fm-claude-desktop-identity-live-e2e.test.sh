#!/usr/bin/env bash
# tests/fm-claude-desktop-identity-live-e2e.test.sh - default-on live guard
# proving the INSTALLED Claude desktop-app session executable is still
# identified as claude by both identity owners: the session-lock walk
# (bin/fm-session-lock-lib.sh) and harness detection (bin/fm-harness.sh), while
# the desktop app's shared server is still not.
#
# Why this file exists: the desktop app names its session executable by version
# inside its own install tree (bin/fm-claude-lib.sh owns that shape), a surface
# the vendor controls. A release that moves or renames it makes every desktop
# session start read-only again, and only the real install can show that.
#
# The newest installed session executable is launched bare in stream-json input
# mode from an empty directory and never sent a message, so this consumes no
# model tokens. Already-running desktop sessions and servers on the host are
# only read with ps. The portable counterparts are the desktop cases in
# tests/fm-session-lock-ancestry.test.sh and tests/fm-harness-precedence.test.sh.
# Run this guard after any desktop-app upgrade and before trusting refreshed
# evidence in docs/verification/runtime-backends.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_DESKTOP_IDENTITY

LIB="$ROOT/bin/fm-session-lock-lib.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
DESKTOP_ROOT=${FM_CLAUDE_DESKTOP_ROOT:-${HOME:-}/.claude/remote}

note() { printf '# %s\n' "$1"; }

newest=''
for candidate in "$DESKTOP_ROOT"/ccd-cli/*; do
  [ -f "$candidate" ] && [ -x "$candidate" ] || continue
  newest=$(printf '%s\n%s\n' "$newest" "${candidate##*/}" | sed '/^$/d' | sort -V | tail -n 1)
done
[ -z "$newest" ] || newest="$DESKTOP_ROOT/ccd-cli/$newest"
if [ -z "$newest" ]; then
  if [ "${FM_CLAUDE_DESKTOP_IDENTITY:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail "FM_CLAUDE_DESKTOP_IDENTITY was requested but no Claude desktop-app session executable is installed under $DESKTOP_ROOT/ccd-cli"
  fi
  printf 'skip: live: Claude desktop app absent (no %s/ccd-cli/<version>)\n' "$DESKTOP_ROOT"
  exit 0
fi

TMP_ROOT=$(fm_test_tmproot fm-claude-desktop-identity)
FIFO="$TMP_ROOT/stdin"
LAUNCHED=''
cleanup_desktop() {
  exec 3>&- 2>/dev/null || true
  if [ -n "$LAUNCHED" ]; then
    kill "$LAUNCHED" 2>/dev/null || true
    wait "$LAUNCHED" 2>/dev/null || true
  fi
}
trap cleanup_desktop EXIT

# Both owners' verdicts for one live pid, as "<lock>|<ancestry>".
identity_of() {  # <pid>
  local pid=$1 comm args lock
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  lock=$(bash -c '. "$0"; if fm_harness_process_matches "$1" "$2"; then printf "match:%s" "$FM_HARNESS_IS_CLAUDE"; else printf nomatch; fi' \
    "$LIB" "$comm" "$args")
  printf '%s|%s\n' "$lock" "$(bash "$HARNESS" ancestry "$pid")"
}

version=$("$newest" --version 2>/dev/null | head -n 1)
version=${version%% *}
[ -n "$version" ] || fail "desktop-app session executable $newest did not report a version"
note "desktop-app session executable: $newest ($version)"

mkdir -p "$TMP_ROOT/cwd"
mkfifo "$FIFO"
(
  cd "$TMP_ROOT/cwd" || exit 1
  exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN \
    "$newest" --output-format stream-json --input-format stream-json --verbose \
    < "$FIFO" > "$TMP_ROOT/session.out" 2>&1
) &
LAUNCHED=$!
exec 3> "$FIFO"
i=0
while [ "$i" -lt 100 ]; do
  case "$(ps -o args= -p "$LAUNCHED" 2>/dev/null)" in
    "$newest"*) break ;;
  esac
  sleep 0.1
  i=$((i + 1))
done
kill -0 "$LAUNCHED" 2>/dev/null || fail "the desktop-app session executable exited at launch: $(head -c 400 "$TMP_ROOT/session.out")"
got=$(identity_of "$LAUNCHED")
[ "$got" = "match:1|comm claude" ] \
  || fail "the launched $version desktop-app session resolved '$got', expected 'match:1|comm claude'"
pass "a launched $version desktop-app session is identified as claude by the lock walk and harness detection"

checked=0
while read -r pid argv0 _; do
  case "$argv0" in
    "$DESKTOP_ROOT"/srv/*/server)
      got=$(identity_of "$pid") || continue
      [ "$got" = "nomatch|" ] || fail "the shared desktop server pid $pid resolved '$got', expected no harness identity"
      checked=$((checked + 1))
      ;;
  esac
done < <(ps -axo pid=,args= 2>/dev/null)
if [ "$checked" -gt 0 ]; then
  pass "$checked running shared desktop server process(es) carry no harness identity"
else
  note "no shared desktop server running; its exclusion is pinned by the portable cases"
fi
