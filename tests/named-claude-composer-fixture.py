#!/usr/bin/env python3
"""A composer drawn like a named Claude Code session, for the away daemon's tests.

tests/fm-afk-inject-titled-composer.test.sh (tmux) and
tests/fm-afk-inject-titled-composer-herdr-e2e.test.sh (herdr) run it as a pane's
own process: a titled top rule, the word-wrapped prompt, a plain bottom rule,
the auto-mode hint, and the cursor parked at the end of the typed text. A
submitted line is logged to <dir>/submitted.log and each key to <dir>/keys.log;
a submitted doorbell opens the operational record it names, and the footer
shows `esc to interrupt` for a short turn.

Usage: named-claude-composer-fixture.py <dir> <state> <root> <title>
"""
import codecs, os, select, shutil, subprocess, sys, textwrap, time, tty

DIR, STATE, ROOT, TITLE = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
# FIXTURE_COLS pins the drawn width where the pane cannot report its own.
COLS = int(os.environ.get("FIXTURE_COLS") or 0)
# On herdr the fixture reports itself as a Claude agent, idle or working, so the
# adapter's native agent state and its Claude payload proof both apply.
HERDR = os.environ.get("FIXTURE_HERDR_BIN")
HERDR_SESSION = os.environ.get("FIXTURE_HERDR_SESSION")
DOORBELL_HEAD = ": Firstmate operational input waiting: read '"
fd = sys.stdin.fileno()
tty.setraw(fd)
decode = codecs.getincrementaldecoder("utf-8")(errors="replace").decode
buf, working_until, drawn, reported = "", 0.0, None, None


def report(state):
    global reported
    if not HERDR or state == reported:
        return
    reported = state
    subprocess.run([HERDR, "pane", "report-agent", os.environ.get("HERDR_PANE_ID", ""),
                    "--source", "fm-test-titled", "--agent", "claude", "--state", state,
                    "--session", HERDR_SESSION],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def log(name, line):
    with open(os.path.join(DIR, name), "a") as f:
        f.write(line + "\n")


def rule(w, title=""):
    tail = (" " + title + " ─") if title else ""
    return "─" * (w - len(tail)) + tail


def redraw():
    global drawn
    w = COLS or shutil.get_terminal_size((150, 20)).columns
    busy = time.time() < working_until
    report("working" if busy else "idle")
    frame = (busy, buf, w)
    if frame == drawn:
        return
    drawn = frame
    rows = textwrap.wrap(buf, width=w - 2, break_on_hyphens=False) or [""]
    prompt = ["❯ " + rows[0]] + ["  " + r for r in rows[1:]]
    footer = "  ⏵⏵ auto mode on (shift+tab to cycle)" + (" · esc to interrupt" if busy else "")
    out = ["✻ Working… (3s)" if busy else "✻ Crunched for 1m 50s", "", rule(w, TITLE)] + prompt + [rule(w), footer]
    sys.stdout.write("\x1b[H\x1b[J" + "\r\n".join(out))
    # Park the cursor at the end of the typed text, as Claude Code does.
    last = len(prompt) - 1
    col = len(prompt[last]) + 1
    sys.stdout.write("\x1b[%d;%dH" % (3 + last + 1, col))
    sys.stdout.flush()


def submit(now):
    global buf, working_until
    log("submitted.log", buf)
    if buf.startswith(DOORBELL_HEAD):
        path = buf[len(DOORBELL_HEAD):].split("'", 1)[0]
        subprocess.run([ROOT + "/bin/fm-operational-input.sh", "open", path],
                       env=dict(os.environ, FM_STATE_OVERRIDE=STATE),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    working_until = now + 1.2
    buf = ""


redraw()
while True:
    ready, _, _ = select.select([fd], [], [], 0.1)
    if ready:
        for ch in decode(os.read(fd, 4096)):
            now = time.time()
            if ch in "\r\n":
                log("keys.log", "Enter")
                if buf:
                    submit(now)
            elif ch == "\x15":
                log("keys.log", "C-u")
                buf = ""
            else:
                buf += ch
    redraw()
