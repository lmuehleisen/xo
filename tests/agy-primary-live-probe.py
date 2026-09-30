"""Native Agy verification driver, invoked by fm-agy-primary-live-e2e.test.sh."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import time

root, lab = (Path(arg).resolve() for arg in sys.argv[1:])
home = lab / "home"
home.mkdir()
shutil.copytree(root / "bin", home / "bin")
shutil.copytree(root / "docs" / "supervision-protocols", home / "docs" / "supervision-protocols")
for name in [".agents", "state", "data", "config", "projects"]:
    (home / name).mkdir()
(home / "AGENTS.md").write_text("# Isolated adapter verification\nFollow the test prompt and native Firstmate hook instructions.\n")
subprocess.run(["git", "init", "-q", str(home)], check=True)
# The nudge must reach the model and cause the named command. Avoid bootstrap,
# external startup checks, or real fleet work in this ephemeral home.
startup = home / "bin" / "fm-session-start.sh"
startup.write_text('#!/bin/sh\n"$FM_HOME/bin/fm-lock.sh" || exit\ntouch "$FM_HOME/state/startup-receipt"\n"$FM_HOME/bin/fm-supervision-instructions.sh" --harness agy\nprintf "AGY_STARTUP_CONFIRMED\\n"\n')
startup.chmod(0o755)
recorder = home / ".agents" / "observe.py"
recorder.write_text('''import json, os, sys, time
from pathlib import Path
p=json.load(sys.stdin)
with (Path(os.environ['FM_HOME'])/'state/events.jsonl').open('a') as f:
    f.write(json.dumps({'event':sys.argv[1], 'time':time.time(), 'cwd':os.getcwd(), 'payload':p})+'\\n')
print(json.dumps({'decision':'ask'} if sys.argv[1]=='PreToolUse' else {}))
''')
hooks = json.loads((root / ".agents" / "hooks.json").read_text())
handler = lambda event: {"command": shlex.join([sys.executable, str(recorder), event])}
hooks["firstmate-live-observer"] = {
    "PreInvocation": [handler("PreInvocation")],
    "Stop": [handler("Stop")],
    "PreToolUse": [{"matcher": "*", "hooks": [handler("PreToolUse")]}],
    "PostToolUse": [{"matcher": "*", "hooks": [handler("PostToolUse")]}],
}
(home / ".agents" / "hooks.json").write_text(json.dumps(hooks))
socket = "/tmp/fm-agy-primary-" + str(os.getpid()) + ".sock"
tmux = ["tmux", "-S", socket]
version = subprocess.check_output(["agy", "--version"], text=True).strip()


def call(*args):
    result = subprocess.run(tmux + list(args), text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return result.stdout


def events():
    path = home / "state" / "events.jsonl"
    if not path.exists():
        return []
    rows = []
    for line in path.read_text().splitlines():
        try:
            rows.append(json.loads(line))
        except ValueError:
            pass  # A currently-writing observer is not yet an event.
    return rows


approved_steps = set()


def capture_and_review():
    out = call("capture-pane", "-p", "-t", "probe:primary", "-S", "-200")
    (lab / "capture.txt").write_text(out)
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
                allowed = ["bin/fm-session-start.sh", "bin/fm-watch-arm.sh", "bin/fm-wake-drain.sh"]
                simple = len(argv) == 1 and any(argv[0] in [name, "./" + name, str(home / name)] for name in allowed)
                # Acknowledge only this fixture's published queue generation
                # and sequence, with the production drain's exact arguments.
                ack = (len(argv) == 5 and argv[0] in ["bin/fm-wake-drain.sh", "./bin/fm-wake-drain.sh", str(home / "bin/fm-wake-drain.sh")]
                       and argv[1] == "--ack-through" and argv[2].isdigit()
                       and argv[3] == "--recovery-generation"
                       and (home / "state/.watcher-down").read_text().strip() == "pending:handling:" + argv[4]
                       and 0 < int(argv[2]) <= int((home / "state/.wake-queue.seq").read_text()))
                if not (simple or ack):
                    raise RuntimeError("unexpected command review: " + command)
                call("send-keys", "-t", "probe:primary", "Enter")
                approved_steps.add(key)
    return out


def wait_until(predicate, label, seconds=100):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        out = capture_and_review()
        if predicate(out):
            return
        time.sleep(0.5)
    raise RuntimeError("timed out: " + label + "; capture: " + str(lab / "capture.txt"))


def send(prompt):
    call("send-keys", "-t", "probe:primary", "-l", prompt)
    call("send-keys", "-t", "probe:primary", "Enter")


try:
    shellrc = lab / "shellrc"
    shellrc.write_text("PS1='FM_LIVE_SHELL_READY> '\n")
    call("new-session", "-d", "-s", "probe", "-n", "primary", "-c", str(home), "-x", "180", "-y", "55",
         shlex.join(["/bin/bash", "--noprofile", "--rcfile", str(shellrc), "-i"]))
    wait_until(lambda out: "FM_LIVE_SHELL_READY>" in out, "fixture shell readiness", seconds=15)
    print("ok - agy primary fixture: interactive shell is ready before launch delivery", flush=True)
    call("new-window", "-d", "-t", "probe", "-n", "worker", "sleep 300")
    env = ["env", "-u", "CLAUDECODE", "-u", "CURSOR_AGENT", "-u", "CURSOR_INVOKED_AS", "-u", "PI_CODING_AGENT", "-u", "GROK_AGENT",
           "FM_HOME=" + str(home), "FM_ROOT_OVERRIDE=" + str(home), "FM_STATE_OVERRIDE=" + str(home / "state"),
           "FM_DATA_OVERRIDE=" + str(home / "data"), "FM_CONFIG_OVERRIDE=" + str(home / "config"),
           "FM_BACKEND=tmux", "FM_POLL=1", "FM_SIGNAL_GRACE=1", "FM_HEARTBEAT=999999"]
    # tmux's backend CLI must stay on the probe socket, never the operator's.
    fakebin = lab / "fakebin"
    fakebin.mkdir()
    tmux_binary = shutil.which("tmux")
    wrapper = fakebin / "tmux"
    wrapper.write_text("#!/bin/sh\nexec " + shlex.join([tmux_binary, "-S", socket]) + ' "$@"\n')
    wrapper.chmod(0o755)
    env += ["PATH=" + str(fakebin) + ":" + os.environ["PATH"]]
    prompt = "Perform the native startup instruction if one is injected, then reply READY. Do not do other work."
    launch = lab / "launch.sh"
    launch.write_text("#!/bin/sh\nexec " + shlex.join(env + ["agy", "--add-dir", str(home), "--model", "gemini-3.8-flash", "--effort", "low", "-i", prompt]) + "\n")
    launch.chmod(0o755)
    send(shlex.quote(str(launch)))
    wait_until(lambda out: call("display-message", "-p", "-t", "probe:primary", "#{pane_current_command}").strip() == "agy",
               "native agy process startup", seconds=30)
    (lab / "processes.txt").write_text(call("display-message", "-p", "-t", "probe:primary", "#{pane_pid} #{pane_current_command}"))
    print("ok - agy primary fixture: native agy process started", flush=True)
    wait_until(lambda out: (home / "state/startup-receipt").exists() and "? for shortcuts" in out, "native startup and idle")
    pid = int((home / "state/.lock").read_text().strip())
    os.kill(pid, 0)
    print("ok - agy primary: native nudge reaches the model and real session lock is acquired", flush=True)
    # An idle secondmate is healthy by contract; a shell pretending to be a
    # working ship would immediately emit a stale wake before our test signal.
    (home / "state/child.meta").write_text("id=child\nharness=agy\nbackend=tmux\nbackend_target=probe:worker\nwindow=probe:worker\nkind=secondmate\n")
    stage = time.time()
    send("Reply INITIAL_TURN_DONE without tools and end this turn.")
    wait_until(lambda out: any(row["event"] == "Stop" and row["time"] > stage and row["payload"].get("executionNum") == 1 and row["payload"].get("fullyIdle") is False for row in events()) and (home / "state/.last-watcher-beat").exists(), "forced recovery and real watcher arm")
    print("ok - agy primary: Stop forces a bounded recovery and the real watcher arms", flush=True)
    # A registered native command remains alive beyond the model's Stop. Its
    # completion must cause a new invocation without sending another prompt.
    signal_time = time.time()
    (home / "state/child.status").write_text("done: isolated Agy native wake probe\n")
    wait_until(lambda out: any(row["event"] == "PreInvocation" and row["time"] > signal_time for row in events()), "native watcher completion wake")
    (home / "state/child.meta").unlink(missing_ok=True)
    wait_until(lambda out: "? for shortcuts" in out and "esc to cancel" not in out, "settled wake")
    assert all(row["cwd"] == str(home / ".agents") for row in events())
    print("ok - agy primary: native watcher completion re-enters the model without polling or injected keys", flush=True)
    # Secondmate scope uses the same hook registration. Test a real linked home
    # boundary through the production helper without creating a fleet record.
    subprocess.run(["git", "-C", str(home), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "--allow-empty", "-qm", "fixture"], check=True)
    linked = lab / "secondmate"
    subprocess.run(["git", "-C", str(home), "worktree", "add", "-qb", "secondmate", str(linked)], check=True, capture_output=True)
    for directory in ["bin", "state"]:
        (linked / directory).mkdir()
    (linked / "AGENTS.md").write_text("# Firstmate\n")
    (linked / ".fm-secondmate-home").write_text("live-secondmate\n")
    (linked / "state/child.meta").touch()
    payload = {"conversationId": "live-secondmate", "workspacePaths": [str(linked)], "executionNum": 0, "fullyIdle": True}
    probe_env = dict(os.environ, FM_ROOT_OVERRIDE=str(linked), FM_HOME=str(linked), FM_STATE_OVERRIDE=str(linked / "state"), JETSKI_APP_DATA_DIR="antigravity-cli")
    result = subprocess.run([str(root / "bin/fm-agy-hook.sh"), "primary", "Stop"], input=json.dumps(payload), text=True, capture_output=True, env=probe_env, check=True)
    assert json.loads(result.stdout)["decision"] == "continue"
    print("ok - agy primary: the same guard includes a marked linked secondmate home", flush=True)
    send("/exit")
    wait_until(lambda out: call("display-message", "-p", "-t", "probe:primary", "#{pane_current_command}").strip() != "agy", "exit", seconds=20)
    print("# all agy primary live checks passed (agy " + version + ")", flush=True)
except Exception as error:
    (lab / "capture.txt").write_text(call("capture-pane", "-p", "-t", "probe:primary", "-S", "-200"))
    if events():
        transcript = Path(events()[0]["payload"]["transcriptPath"])
        if transcript.is_file():
            shutil.copyfile(transcript, lab / "transcript.jsonl")
    print("not ok - agy " + version + ": " + str(error), file=sys.stderr)
    raise
finally:
    subprocess.run(tmux + ["kill-server"], capture_output=True)
