#!/usr/bin/env bash
# Live guard for the Claude StopFailure recovery
# (bin/fm-claude-stop-autoarm.sh --stop-failure), run against the installed
# Claude Code and the real tracked .claude/settings.json registration.
#
# Three facts in this area come from the vendor, not from Firstmate, so a stub
# can only confirm the assumption already written into the stub:
#
#   (a) a turn that ends on an API error fires StopFailure and NOT Stop, and a
#       turn that ends normally fires Stop and NOT StopFailure;
#   (b) an asyncRewake StopFailure hook that exits 2 starts a new turn in an
#       interactive session, although Claude Code describes StopFailure as
#       fire-and-forget (print mode runs async hooks synchronously, so only an
#       interactive session can show this);
#   (c) the rejected turn's error text reaches the hook, reset time included.
#
# tests/fm-claude-stop-autoarm.test.sh pins the hook's own logic portably.
#
# It spends no model tokens and uses no credentials: Claude Code runs in an
# isolated tmux server with an isolated CLAUDE_CONFIG_DIR against a local fake
# Messages API. That API rejects every request with a 429 naming a reset about
# a minute ahead until that reset passes, then answers normally. The hook must
# wait for the reset, start exactly one recovery turn, and that turn's normal
# Stop must re-arm through the Stop auto-arm. So it runs by default wherever
# claude, tmux, python3, jq, and git are installed; run it after every Claude
# Code upgrade and before trusting refreshed evidence in
# docs/verification/supervision.md:
#
#   FM_CLAUDE_STOPFAILURE_LIVE_E2E=1 tests/fm-claude-stopfailure-live-e2e.test.sh
#
# Under this API-key path Claude Code shows the API's own error text rather than
# its subscriber usage-limit notice, so the guard proves the reset-from-text
# path. The subscriber quotaLimits.resetsAt path the hook prefers is pinned
# portably from the transcript shape Claude Code 2.1.278 records.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_CLAUDE_STOPFAILURE_LIVE_E2E claude tmux python3 jq git

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
# Outside the repo on purpose: the lab project is its own clone, and nesting it
# inside this checkout would show up as an embedded repository.
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-stopfailure-live.XXXXXX")" && pwd -P)
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
API="$LAB/api"
SOCKET="fmsf-live-$$"
STUB_PID=

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  [ -z "$STUB_PID" ] || kill "$STUB_PID" 2>/dev/null || true
  fm_test_rm_tmproot "${LAB:-}"
}
trap cleanup EXIT

diagnose() {
  printf '# claude %s\n' "$CLAUDE_VERSION" >&2
  printf '# events: %s\n' "$(tr '\n' ' ' < "$HOME_DIR/state/events" 2>/dev/null)" >&2
  printf '# requests:\n' >&2
  sed 's/^/#   /' "$API/requests.log" >&2 2>/dev/null || true
  printf '# stopfailure record: %s\n' "$(cat "$HOME_DIR/state/.claude-stopfailure" 2>/dev/null)" >&2
  printf '# ledger: %s\n' "$(sed -n 1p "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" >&2
  tmux -L "$SOCKET" capture-pane -p -t sf 2>/dev/null | grep -v '^[[:space:]]*$' | tail -20 | sed 's/^/# pane: /' >&2
}

# --- the local fake Messages API ------------------------------------------------
mkdir -p "$API"
cat > "$LAB/fake-api.py" <<'PY'
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE = sys.argv[1]

def log(line):
    with open(os.path.join(STATE, 'requests.log'), 'a') as f:
        f.write(line + '\n')

def read(name, default=''):
    try:
        with open(os.path.join(STATE, name)) as f:
            return f.read().strip()
    except OSError:
        return default

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type='application/json', headers=()):
        self.send_response(status)
        self.send_header('content-type', content_type)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_HEAD(self):
        self.reply(200, b'')

    def do_GET(self):
        self.reply(404, b'{}')

    def do_POST(self):
        length = int(self.headers.get('content-length') or 0)
        body = self.rfile.read(length) if length else b''
        if not self.path.startswith('/v1/messages') or 'count_tokens' in self.path:
            self.reply(200, b'{"input_tokens": 1}')
            return
        now = int(time.time())
        limited_until = int(read('limited-until', '0') or 0)
        if now < limited_until:
            log('%d 429' % now)
            message = read('limit-message', 'usage limit')
            error = json.dumps({'type': 'error', 'error': {'type': 'rate_limit_error', 'message': message}})
            self.reply(429, error.encode(), headers=(
                ('x-should-retry', 'false'),
                ('anthropic-ratelimit-unified-status', 'rejected'),
                ('anthropic-ratelimit-unified-reset', str(limited_until)),
            ))
            return
        log('%d 200' % now)
        request = json.loads(body or b'{}')
        model = request.get('model', 'fake')
        message = {'id': 'msg_fake', 'type': 'message', 'role': 'assistant', 'model': model,
                   'content': [], 'stop_reason': None, 'stop_sequence': None,
                   'usage': {'input_tokens': 1, 'output_tokens': 1}}
        text = 'RECOVERED'
        if not request.get('stream'):
            message.update(content=[{'type': 'text', 'text': text}], stop_reason='end_turn')
            self.reply(200, json.dumps(message).encode())
            return
        events = [
            ('message_start', {'type': 'message_start', 'message': message}),
            ('content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}}),
            ('content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': text}}),
            ('content_block_stop', {'type': 'content_block_stop', 'index': 0}),
            ('message_delta', {'type': 'message_delta', 'delta': {'stop_reason': 'end_turn', 'stop_sequence': None}, 'usage': {'output_tokens': 1}}),
            ('message_stop', {'type': 'message_stop'}),
        ]
        stream = b''.join(('event: %s\ndata: %s\n\n' % (name, json.dumps(data))).encode() for name, data in events)
        self.reply(200, stream, content_type='text/event-stream')

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
with open(os.path.join(STATE, 'port.tmp'), 'w') as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(STATE, 'port.tmp'), os.path.join(STATE, 'port'))
server.serve_forever()
PY
python3 "$LAB/fake-api.py" "$API" >"$LAB/fake-api.log" 2>&1 &
STUB_PID=$!
n=0
while [ ! -s "$API/port" ] && [ "$n" -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
[ -s "$API/port" ] || fail "the local fake Messages API did not start: $(cat "$LAB/fake-api.log")"
PORT=$(cat "$API/port")

# --- the lab primary ------------------------------------------------------------
# A plain clone is a genuine primary checkout. It carries only committed state, so
# overlay the working-tree surfaces under test, as the auto-arm live guard does.
git clone -q "$ROOT" "$PROJECT" || fail "could not clone the lab project"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The real tracked registration stays in place. Session start is stubbed out
# because this guard is about the turn boundary, not the digest.
printf '#!/usr/bin/env bash\ncat >/dev/null 2>&1\nexit 0\n' > "$PROJECT/bin/fm-sessionstart-run.sh"
# The arm fixture stands in for the watcher: it records that the recovery turn's
# Stop re-armed, then retires the in-flight need so nothing wakes again.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'arm pid=%s at=%s\n' "$$" "$(date +%s)" >> "$FM_HOME/state/arm-ran"
rm -f "$FM_HOME/state/task.meta"
printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
exit 0
SH
chmod +x "$PROJECT/bin/fm-sessionstart-run.sh" "$PROJECT/bin/fm-watch-arm.sh"
# Observation only: record which turn-end event the harness fired, beside the
# tracked hooks, without changing their behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "Stop": [{ "hooks": [{ "type": "command", "command": "cat >/dev/null; echo stop >> \"$FM_HOME/state/events\"" }] }],
    "StopFailure": [{ "hooks": [{ "type": "command", "command": "cat >/dev/null; echo stopfailure >> \"$FM_HOME/state/events\"" }] }]
  }
}
JSON

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# The shape under test: a dead prior owner and a pending watcher downtime.
printf '9999999\n' > "$HOME_DIR/state/.lock"
printf 'pending:downtime:live-generation\n' > "$HOME_DIR/state/.watcher-down"

mkdir -p "$LAB/claude-config"
jq -n --arg p "$PROJECT" \
  '{hasCompletedOnboarding: true, projects: {($p): {hasTrustDialogAccepted: true, hasCompletedProjectOnboarding: true}}}' \
  > "$LAB/claude-config/.claude.json"

# --- the limit ------------------------------------------------------------------
# A whole-minute reset at least 20 seconds ahead, worded as Claude Code words a
# usage-limit reset.
now=$(date +%s)
RESET=$(( (now / 60 + 1) * 60 ))
[ $((RESET - now)) -ge 20 ] || RESET=$((RESET + 60))
RESET_TEXT=$(python3 -c 'import sys, time
t = time.gmtime(int(sys.argv[1]))
print("%d:%02d%s" % (t.tm_hour % 12 or 12, t.tm_min, "am" if t.tm_hour < 12 else "pm"))' "$RESET")
printf '%s\n' "$RESET" > "$API/limited-until"
printf "You've hit your weekly limit · resets %s (UTC)\n" "$RESET_TEXT" > "$API/limit-message"

# --- the session ----------------------------------------------------------------
tmux -L "$SOCKET" new-session -d -s sf -x 200 -y 50 -c "$PROJECT" \
  "env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_ENABLE_FUNCTION_HOOKS \
    FM_HOME='$HOME_DIR' CLAUDE_CONFIG_DIR='$LAB/claude-config' \
    ANTHROPIC_BASE_URL='http://127.0.0.1:$PORT' ANTHROPIC_AUTH_TOKEN=fm-live-fake-token \
    CLAUDE_CODE_MAX_RETRIES=0 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
    FM_CLAUDE_STOPFAILURE_RESET_SLACK=1 FM_CLAUDE_STOPFAILURE_POLL=1 FM_CLAUDE_STOPFAILURE_MAX_WAIT=180 \
    claude --model claude-haiku-4-5-20251001; sleep 600" \
  || fail "could not start the interactive Claude session"

n=0
until tmux -L "$SOCKET" capture-pane -p -t sf 2>/dev/null | grep -q '❯'; do
  [ "$n" -lt 60 ] || { diagnose; fail "Claude $CLAUDE_VERSION never showed its prompt"; }
  sleep 1
  n=$((n + 1))
done
sleep 2
tmux -L "$SOCKET" send-keys -t sf -l 'Reply with exactly: first'
sleep 0.5
tmux -L "$SOCKET" send-keys -t sf Enter

# The recovery turn can start only after the reset; allow it a generous bound.
deadline=$((RESET + 90))
until grep -qx stop "$HOME_DIR/state/events" 2>/dev/null && [ -s "$HOME_DIR/state/arm-ran" ]; do
  [ "$(date +%s)" -lt "$deadline" ] || { diagnose; fail "Claude $CLAUDE_VERSION: no recovery turn re-armed the watcher by $((deadline - RESET))s after the reset"; }
  sleep 1
done
sleep 3

# --- what the harness did -------------------------------------------------------
events=$(tr '\n' ' ' < "$HOME_DIR/state/events")
[ "$events" = 'stopfailure stop ' ] \
  || { diagnose; fail "Claude $CLAUDE_VERSION: expected the rejected turn to fire only StopFailure and the recovery turn only Stop, got: $events"; }
# Claude Code may send more than one request inside the one rejected turn, so
# the check is that every rejected request belongs to that turn: none came from
# a recovery that retried into the limit later.
first_429=$(awk '$2 == 429 { print $1; exit }' "$API/requests.log")
last_429=$(awk '$2 == 429 { t = $1 } END { print t }' "$API/requests.log")
[ -n "$first_429" ] && [ $((last_429 - first_429)) -le 5 ] \
  || { diagnose; fail "Claude $CLAUDE_VERSION: a rejected request came after the first turn, so the recovery retried into the limit"; }
first_ok=$(awk '$2 == 200 { print $1; exit }' "$API/requests.log")
[ -n "$first_ok" ] && [ "$first_ok" -ge "$RESET" ] \
  || { diagnose; fail "Claude $CLAUDE_VERSION: the recovery turn reached the API at ${first_ok:-never}, before the reset at $RESET"; }
transcript=$(find "$LAB/claude-config/projects" -name '*.jsonl' -type f 2>/dev/null | head -n 1)
[ -n "$transcript" ] || { diagnose; fail "Claude $CLAUDE_VERSION: no transcript was written"; }
grep -q 'firstmate recovery turn' "$transcript" \
  || { diagnose; fail "Claude $CLAUDE_VERSION: the asyncRewake exit 2 did not deliver the recovery banner as a new turn"; }
! grep -q 'TURN WOULD END BLIND' "$transcript" \
  || { diagnose; fail "Claude $CLAUDE_VERSION: the turn-end guard had to force a continuation after the recovery turn"; }

# --- what the hook did ----------------------------------------------------------
record=" $(cat "$HOME_DIR/state/.claude-stopfailure" 2>/dev/null) "
for field in decision=rewake basis=message error=rate_limit attempt=1 "reset=$RESET"; do
  case "$record" in
    *" $field "*) : ;;
    *) diagnose; fail "the StopFailure hook record lacks '$field' (the reset text was '$RESET_TEXT'): $record" ;;
  esac
done
[ "$(cat "$HOME_DIR/state/.lock")" != 9999999 ] || fail "the dead prior session owner was never reclaimed"
[ "$(sed -n '1s/^epoch=\([0-9]*\) .*/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch")" = 2 ] \
  || { diagnose; fail "the recovery turn's Stop auto-arm must take the generation after the recovery's"; }
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "an auto-arm lock was left behind"

printf 'ok - Claude %s live: an API-error turn end fired only StopFailure, the hook waited for the reset named in the error text, one asyncRewake recovery turn followed, and its Stop re-armed\n' "$CLAUDE_VERSION"
