"""Interactive primary/marked-secondmate guard; invoked only by the opt-in suite."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

root, lab = (Path(arg).resolve() for arg in sys.argv[1:])
tmux_dir = os.environ["FM_AGY_PRIMARY_LIVE_TMUX_DIR"]
socket = str(Path(tmux_dir) / ("tmux-" + str(os.getuid())) / "default")
tmux = ["tmux", "-S", socket]
agy = os.environ.get("FM_AGY_BIN") or shutil.which("agy")
version = subprocess.check_output([agy, "--version"], text=True).strip()
model = os.environ.get("FM_AGY_LIVE_MODEL", "gemini-3.8-flash")


def call(*args):
    result = subprocess.run(tmux + list(args), text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


fakebin = lab / "fakebin"
fakebin.mkdir()
wrapper = fakebin / "tmux"
wrapper.write_text("#!/bin/sh\nexec " + shlex.join([shutil.which("tmux"), "-S", socket]) + ' "$@"\n')
wrapper.chmod(0o755)


def probe(role):
    home = lab / ("home" if role == "primary" else "secondmate")
    home.mkdir(exist_ok=True)
    shutil.copytree(root / "bin", home / "bin")
    shutil.copytree(root / "docs" / "supervision-protocols", home / "docs" / "supervision-protocols")
    for name in [".agents", "state", "data", "config", "projects"]:
        (home / name).mkdir(exist_ok=True)
    if role == "secondmate":
        (home / ".fm-secondmate-home").write_text("live-secondmate\n")
    (home / "AGENTS.md").write_text(
        "# Isolated adapter verification\n"
        "Follow the test prompt and native hook instructions.\n"
        "Only execute the exact prompted canary, wake drain and queue acknowledgement.\n"
        "Watcher arm and re-arm belong to the Stop hook.\n"
        "Child status is synthetic: drain and acknowledge it, then end the turn.\n"
        "Do not investigate, clean up or send messages.\n")
    subprocess.run(["git", "init", "-q", str(home)], check=True)
    marker = "AGY_SESSIONSTART_" + role.upper()
    startup = home / "bin" / "fm-session-start.sh"
    startup.write_text(
        '#!/bin/sh\n"$FM_HOME/bin/fm-lock.sh" || exit\n'
        'touch "$FM_HOME/state/startup-receipt"\n'
        '"$FM_HOME/bin/fm-supervision-instructions.sh" --harness agy\n'
        + "printf '%s\\n' " + shlex.quote(marker) + "\n")
    startup.chmod(0o755)
    recorder = home / ".agents" / "observe.py"
    recorder.write_text('''import json, os, sys, time
from pathlib import Path
p=json.load(sys.stdin)
with (Path(os.environ['FM_HOME'])/'state/events.jsonl').open('a') as f:
    f.write(json.dumps({'event':sys.argv[1], 'time':time.time(), 'cwd':os.getcwd(), 'payload':p})+'\\n')
# Silence abstains to native review, including for permitted PreToolUse calls.
''')
    hooks = json.loads((root / ".agents" / "hooks.json").read_text())
    handler = lambda event: {"type": "command", "command": shlex.join([sys.executable, str(recorder), event]), "timeout": 10}
    hooks["firstmate-live-observer"] = {
        "SessionStart": [handler("SessionStart")],
        "PreInvocation": [handler("PreInvocation")],
        "Stop": [handler("Stop")],
        "PreToolUse": [{"matcher": ".*", "hooks": [handler("PreToolUse")]}],
        "PostToolUse": [{"matcher": ".*", "hooks": [handler("PostToolUse")]}],
    }
    observer = hooks.pop("firstmate-live-observer")
    hooks = {"firstmate-live-observer": observer, **hooks}
    (home / ".agents" / "hooks.json").write_text(json.dumps(hooks))
    target = "probe:" + role
    approved_steps = set()
    allowed_canary = "printf native-review-ok > state/review-ran"
    denied_canary = "bin/fm-watch.sh; touch state/live-deny-ran"

    def events():
        path = home / "state/events.jsonl"
        rows = []
        if path.exists():
            for line in path.read_text().splitlines():
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
        return rows

    def capture_and_review():
        out = call("capture-pane", "-p", "-t", target, "-S", "-200")
        (lab / (role + "-capture.txt")).write_text(out)
        if "Run this command?" in out:
            tools = [row for row in events() if row["event"] == "PreToolUse"]
            if tools:
                payload = tools[-1]["payload"]
                key = (payload["conversationId"], payload["stepIdx"])
                if key not in approved_steps:
                    command = payload["toolCall"]["args"].get("CommandLine", "")
                    argv = shlex.split(command)
                    if argv and argv[0] in ["sh", "bash"]:
                        argv = argv[1:]
                    drain = ["bin/fm-wake-drain.sh", "./bin/fm-wake-drain.sh", str(home / "bin/fm-wake-drain.sh")]
                    simple = len(argv) == 1 and argv[0] in drain
                    recovery = home / "state/.watcher-down"
                    seq = home / "state/.wake-queue.seq"
                    ack = (len(argv) == 5 and argv[0] in drain and argv[1] == "--ack-through"
                           and argv[2].isdigit() and argv[3] == "--recovery-generation"
                           and recovery.exists() and seq.exists()
                           and recovery.read_text().strip() == "pending:handling:" + argv[4]
                           and 0 < int(argv[2]) <= int(seq.read_text()))
                    if not (simple or ack or command == allowed_canary):
                        raise RuntimeError("unexpected command review: " + command)
                    call("send-keys", "-t", target, "Enter")
                    approved_steps.add(key)
        return out

    def wait_until(predicate, label, seconds=100):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            out = capture_and_review()
            if predicate(out):
                return
            time.sleep(0.5)
        raise RuntimeError("timed out: " + role + " " + label)

    def send(prompt):
        call("send-keys", "-t", target, "-l", prompt)
        call("send-keys", "-t", target, "Enter")

    def idle(out):
        return "? for shortcuts" in out and "esc to cancel" not in out

    try:
        shellrc = lab / "shellrc"
        shellrc.write_text("PS1='FM_LIVE_SHELL_READY> '\n")
        shell = shlex.join(["/bin/bash", "--noprofile", "--rcfile", str(shellrc), "-i"])
        if role == "primary":
            subprocess.run(["tmux", "new-session", "-d", "-s", "probe", "-n", role,
                            "-c", str(home), "-x", "180", "-y", "55", shell],
                           env=dict(os.environ, TMUX_TMPDIR=tmux_dir), check=True)
        else:
            call("new-window", "-d", "-t", "probe", "-n", role, "-c", str(home), shell)
        wait_until(lambda out: "FM_LIVE_SHELL_READY>" in out, "shell readiness", seconds=15)
        child = role + "-child"
        call("new-window", "-d", "-t", "probe", "-n", child, "sleep 600")
        env = ["env", "-u", "CLAUDECODE", "-u", "CURSOR_AGENT", "-u", "CURSOR_INVOKED_AS",
               "-u", "PI_CODING_AGENT", "-u", "GROK_AGENT", "-u", "JETSKI_APP_DATA_DIR",
               "FM_HOME=" + str(home), "FM_ROOT_OVERRIDE=" + str(home),
               "FM_STATE_OVERRIDE=" + str(home / "state"), "FM_DATA_OVERRIDE=" + str(home / "data"),
               "FM_CONFIG_OVERRIDE=" + str(home / "config"), "FM_BACKEND=tmux", "FM_POLL=1",
               "FM_SIGNAL_GRACE=1", "FM_HEARTBEAT=999999", "FM_AGY_PARK_POLL=1",
               "PATH=" + str(fakebin) + ":" + os.environ["PATH"]]
        prompt = "Reply with the exact AGY_SESSIONSTART token from startup context and nothing else."
        launch = lab / (role + "-launch.sh")
        # Preserve supervisors' native default review; no Auto or bypass flag.
        launch.write_text("#!/bin/sh\nexec " + shlex.join(env + [agy, "--add-dir", str(home),
                          "--model", model, "--effort", "low", "-i", prompt]) + "\n")
        launch.chmod(0o755)
        send(shlex.quote(str(launch)))
        wait_until(lambda out: (home / "state/startup-receipt").exists() and marker in out and idle(out), "SessionStart context and idle")
        os.kill(int((home / "state/.lock").read_text().strip()), 0)
        print("ok - agy " + role + ": SessionStart context and real session ownership", flush=True)
        send("Run exactly this one shell command:\n" + denied_canary + "\nIf denied, reply BLOCKED and the reason; do not retry.")
        wait_until(lambda out: any(row["event"] == "PreToolUse" and row["payload"].get("toolCall", {}).get("args", {}).get("CommandLine") == denied_canary for row in events()) and "watcher-direct" in out and idle(out), "real PreToolUse deny")
        assert not (home / "state/live-deny-ran").exists()
        send("Run exactly this one shell command, then reply CANARY_DONE: " + allowed_canary)
        wait_until(lambda out: (home / "state/review-ran").exists() and idle(out), "native review abstention canary")
        assert (home / "state/review-ran").read_text() == "native-review-ok"
        print("ok - agy " + role + ": PreToolUse denial and silent abstention preserve native review", flush=True)
        (home / "state/child.meta").write_text("id=child\nharness=agy\nbackend=tmux\nwindow=probe:" + child + "\nkind=secondmate\n")
        stage = time.time()
        send("Reply INITIAL_TURN_DONE without tools and end this turn.")
        wait_until(lambda out: any(row["event"] == "Stop" and row["time"] > stage for row in events()) and (home / "state/.agy-park-owner").exists() and (home / "state/.last-watcher-beat").exists(), "Stop park and real watcher arm")
        owner = (home / "state/.agy-park-owner").read_text()
        signal_time = time.time()
        (home / "state/child.status").write_text("done: isolated native wake probe\n")
        wait_until(lambda out: any(row["event"] == "PreInvocation" and row["time"] > signal_time for row in events()), "automatic watcher follow-up")
        wait_until(lambda out: (home / "state/.agy-park-owner").read_text() != owner, "automatic Stop re-park")
        (home / "state/child.meta").unlink()
        send("Reply SETTLED and end this turn without tools.")
        wait_until(idle, "settled empty fleet")
        print("ok - agy " + role + ": real Stop park, automatic wake and re-park without model arming", flush=True)
        send("/exit")
        wait_until(lambda out: call("display-message", "-p", "-t", target, "#{pane_current_command}").strip() != "agy", "exit", seconds=20)
    except Exception:
        if events():
            transcript = Path(events()[0]["payload"].get("transcriptPath", ""))
            if transcript.is_file():
                shutil.copyfile(transcript, lab / (role + "-transcript.jsonl"))
        raise


try:
    for role in ["primary", "secondmate"]:
        probe(role)
    print("# all agy interactive primary live checks passed (agy " + version + ")", flush=True)
except Exception as error:
    print("not ok - agy " + version + ": " + str(error), file=sys.stderr)
    raise
