#!/usr/bin/env python3
"""Deterministic transport around captured agy 1.4.7 panel/cancel shapes.

The fake tmux runs only in fm-agy-native.test.sh. It sends real production
worker hooks to the busy-state owner while keeping key delivery and native
events independent, including the observed no-Stop cancellation boundary.
"""

import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys


RULE = "────────────────────────────────────────────────────────────"
IDLE = RULE + "\n>\n" + RULE + "\n? for shortcuts                         auto · Gemini\n"
# Sanitized from the real 1.4.7 no-verdict panel; the narrow viewport wraps
# choice 3. No task path, account, settings, tool output or credential data.
PROMPT = """Reason: the auto-run safety check did not reach a decision
Requesting permission for:
   {command}

Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with 'prefix'
  3. Yes, and always allow for commands that start with 'prefix'
     (Persist to settings.json)
  4. No, cancel

  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
esc to cancel                         auto · Gemini
"""
CANCELLED = ("  ⎿ User declined the tool call\n"
             "  ⎿ Interrupted · What should Antigravity CLI do instead?\n" + IDLE)


def spawn(args):
    """Backend stand-in for the public fm-spawn CLI regression, no harness."""
    log = Path(os.environ["FM_FAKE_LAUNCH_LOG"])
    screen = Path(str(log) + ".native-screen")
    typed = Path(str(log) + ".native-typed")
    mode_path = Path(str(log) + ".native-mode")
    trace = Path(str(log) + ".native-transport")
    with trace.open("a") as stream:
        stream.write(json.dumps(args) + "\n")
    hooks = Path(Path(str(log) + ".agy-hooks").read_text().strip())
    task = hooks.name[:-len(".agy-hooks")]
    policy_path = hooks.parent / (task + ".agy-permission.json")
    policy = json.loads(policy_path.read_text())

    def paint(text=""):
        mode = mode_path.read_text()
        footer = "auto · Gemini" if mode == "auto" else "Gemini"
        screen.write_text(RULE + "\n> " + text + "\n" + RULE + "\n? for shortcuts    " + footer + "\n")

    def event(name, command=None):
        root = Path(os.environ["FM_NATIVE_ROOT"])
        payload = {"conversationId": "spawn-fixture", "workspacePaths": [policy["worktree"]],
                   "fullyIdle": True, "executionNum": 0, "invocationNum": 0,
                   "stepIdx": 1, "toolCall": {"name": "run_command", "args": {
                       "CommandLine": command, "Cwd": policy["worktree"]}}}
        subprocess.run([str(root / "bin/fm-agy-hook.sh"), "worker", name,
                        str(hooks.parent), task, policy["gen"], policy["worktree"]],
                       input=json.dumps(payload), text=True, check=True)
        policy_event = {"PreInvocation": "armed", "Stop": "stop",
                        "PreToolUse": "pre-tool-use", "PostToolUse": "post-tool-use"}[name]
        result = subprocess.run([str(root / "bin/fm-agy-permission-policy.sh"), policy_event,
                                 str(policy_path)], input=json.dumps(payload), text=True,
                                stdout=subprocess.PIPE, check=True)
        if name == "PreToolUse" and result.stdout:
            raise ValueError("synthetic canary was refused by the real policy: " + result.stdout)

    if args[0] == "spawn-start":
        Path(str(log) + ".native-started").touch()
        mode_path.write_text("default")
        paint()
    elif args[0] == "capture-pane":
        print(screen.read_text(), end="")
    elif args[0] == "display-message":
        if args[-1] == "#{cursor_y}":
            print(1)
        elif args[-1] == "#{pane_current_command}":
            print("agy")
        elif args[-1] == "#{pane_current_path}":
            print(policy["worktree"])
    elif args[0] == "send-keys":
        if "-l" in args:
            typed.write_text(args[args.index("-l") + 1])
            paint(typed.read_text())
        elif args[-1] == "BTab":
            modes = ["default", "accept-edits", "auto", "plan"]
            if os.environ.get("FM_FAKE_AGY_NO_AUTO") == "1":
                modes.remove("auto")
            mode_path.write_text(modes[(modes.index(mode_path.read_text()) + 1) % len(modes)])
            paint()
        elif args[-1] == "Enter" and typed.exists():
            text = typed.read_text()
            typed.unlink()
            event("PreInvocation")
            if text.startswith("Launch activation check:"):
                command = text.split("run_command call: ", 1)[1].split(". Use no other tools", 1)[0]
                words = shlex.split(command)
                if len(words) != 4 or words[0] != "/usr/bin/printf" or words[2] != ">" or mode_path.read_text() != "auto":
                    raise ValueError("invalid synthetic activation command or inactive mode")
                event("PreToolUse", command)
                Path(words[3]).write_text(words[1])
                event("PostToolUse", command)
                Path(str(log) + ".native-canary").touch()
            elif not text.startswith("This is a launch readiness check"):
                if not Path(str(log) + ".native-canary").exists():
                    raise ValueError("real brief sent before activation proof")
                Path(str(log) + ".native-brief").write_text(text)
            event("Stop")
            paint()


def hook(event, kind="valid"):
    root = Path(os.environ["FM_NATIVE_ROOT"])
    policy = json.loads(Path(os.environ["FM_NATIVE_POLICY"]).read_text())
    payload = {"conversationId": "fixture", "workspacePaths": [policy["worktree"]],
               "fullyIdle": True, "executionNum": 0, "invocationNum": 0}
    if kind == "foreign":
        payload["conversationId"] = "fixture-child"
    elif kind == "not-idle":
        payload["fullyIdle"] = False
    elif kind == "malformed":
        payload["fullyIdle"] = "true"
    subprocess.run(
        [str(root / "bin/fm-agy-hook.sh"), "worker", event,
         str(Path(os.environ["FM_NATIVE_POLICY"]).parent), "t1",
         policy["gen"], policy["worktree"]],
        input=json.dumps(payload), text=True, check=True,
    )


def main():
    args = sys.argv[1:]
    if args[0] == "spawn-start" or os.environ.get("FM_FAKE_AGY_NATIVE") == "1":
        spawn(args)
        return
    screen = Path(os.environ["FM_NATIVE_SCREEN"])
    typed = screen.with_suffix(".typed")
    if args[0] == "panel":
        screen.write_text(PROMPT.format(command=args[1]))
    elif args[0] == "event":
        hook(args[1], args[2] if len(args) > 2 else "valid")
    elif args[0] == "capture-pane":
        print(screen.read_text(), end="")
    elif args[0] == "display-message":
        if args[-1] == "#{cursor_y}":
            print(next((i for i, row in enumerate(screen.read_text().splitlines())
                        if row.startswith(">")), 0))
        elif args[-1] == "#{pane_current_command}":
            print("agy")
    elif args[0] == "list-windows":
        if args[-1] == "#{window_name}":
            print("fm-t1")
        elif args[-1] == "#{window_id}|#{window_index}|#{window_name}":
            print("@1|0|fm-t1")
        else:
            print("native:fm-t1")
    elif args[0] == "send-keys":
        with Path(os.environ["FM_NATIVE_KEYS"]).open("a") as log:
            log.write(json.dumps(args) + "\n")
        if "-l" in args:
            text = args[args.index("-l") + 1]
            typed.write_text(text)
            screen.write_text(CANCELLED.replace("\n>\n", "\n> " + text + "\n"))
        elif args[-1] == "Down":
            text = screen.read_text()
            choice = re.search(r"^> ([1-4])\.", text, re.M)
            if not choice:
                raise ValueError("Down outside a captured prompt")
            selected = int(choice[1]) % 4 + 1
            text = re.sub(r"^> ([1-4])\.", r"  \1.", text, flags=re.M)
            text = re.sub(r"^  " + str(selected) + r"\.", "> " + str(selected) + ".", text, flags=re.M)
            screen.write_text(text)
            if selected == 4 and os.environ.get("FM_NATIVE_MUTATE_CANDIDATE"):
                candidate = Path(os.environ["FM_NATIVE_MUTATE_CANDIDATE"])
                payload = json.loads(candidate.read_text())
                payload["args"]["Cwd"] += "/changed"
                candidate.write_text(json.dumps(payload))
        elif args[-1] == "Enter":
            if typed.exists():
                typed.unlink()
                kind = os.environ.get("FM_NATIVE_STOP_KIND", "valid")
                if kind != "stop-only":
                    hook("PreInvocation")
                if kind != "missing":
                    hook("Stop", "valid" if kind == "stop-only" else kind)
                screen.write_text(CANCELLED)
            elif re.search(r"^> 4\. No, cancel", screen.read_text(), re.M):
                screen.write_text(CANCELLED)
                # Capture the state BEFORE any new model invocation/Stop:
                # the real harness supplies no cancellation Stop here.
                state = Path(os.environ["FM_NATIVE_POLICY"]).parent / "t1.busy-state"
                Path(os.environ["FM_NATIVE_CANCEL_STATE"]).write_text(state.read_text())
                # A model retry after cancellation is denied before recovery
                # can publish any new PreInvocation or Stop.
                payload = json.loads(Path(os.environ["FM_NATIVE_PAYLOAD"]).read_text())
                payload["stepIdx"] += 1
                result = subprocess.run(
                    [str(Path(os.environ["FM_NATIVE_ROOT"]) / "bin/fm-agy-permission-policy.sh"),
                     "pre-tool-use", os.environ["FM_NATIVE_POLICY"]],
                    input=json.dumps(payload), text=True, stdout=subprocess.PIPE, check=True)
                screen.with_suffix(".retry-verdict").write_text(result.stdout)
            elif os.environ.get("FM_NATIVE_COMPLETE") == "1":
                root = Path(os.environ["FM_NATIVE_ROOT"])
                subprocess.run(
                    [str(root / "bin/fm-agy-permission-policy.sh"), "post-tool-use",
                     os.environ["FM_NATIVE_POLICY"]],
                    input=Path(os.environ["FM_NATIVE_PAYLOAD"]).read_text(), text=True, check=True,
                )
                screen.write_text(IDLE)


if __name__ == "__main__":
    main()
