#!/usr/bin/env python3
"""Read only the live agy viewport; never interpret history as a native prompt.

Usage: fm-agy-native.py active|dialog|prompt|match <candidate.json> < viewport
`prompt` emits a fingerprint and selected choice for the complete command
approval panel. `match` additionally requires its displayed command to match
the exact hook input, allowing only display wrapping. Unknown, clipped, or
ambiguous panels fail closed. No settings or credentials are read.
"""

import hashlib
import json
from pathlib import Path
import re
import sys


def live_dialog(screen):
    rows = screen.splitlines()
    footer = next((row.strip() for row in reversed(rows) if row.strip()), "")
    return ("esc to cancel" in footer and any(row.strip() in
            ("Requesting permission for:", "Run this command?") for row in rows))


def panel(screen):
    # Require the entire current panel, including both persistent choices.
    # Its fingerprint excludes selection, which changes while choosing No.
    rows = screen.splitlines()
    if not live_dialog(screen):
        raise ValueError("native approval panel is not the active viewport")
    starts = [i for i, row in enumerate(rows) if row.strip() == "Requesting permission for:"]
    if not starts:
        raise ValueError("no complete native command prompt")
    start = starts[-1]
    end = next(i for i in range(start + 1, len(rows)) if rows[i].strip() == "Run this command?")
    choices = []
    selected = None
    for row in rows[end + 1:]:
        match = re.match(r"^\s*([>❯]?)\s*([1-4])\.\s+(.*)$", row)
        if match:
            choices.append([int(match[2]), match[3].strip()])
            if match[1]:
                if selected is not None:
                    raise ValueError("multiple selected choices")
                selected = int(match[2])
        elif choices and choices[-1][0] < 4 and row.strip():
            # Narrow viewports wrap the conversation/persistent labels.
            # Only continuation rows before choice 4 belong to the panel.
            choices[-1][1] += " " + row.strip()
    if (len(choices) != 4 or [n for n, _ in choices] != [1, 2, 3, 4]
            or choices[0][1] != "Yes, run command"
            or choices[3][1] != "No, cancel"
            or "conversation" not in choices[1][1]
            or "Persist to settings.json" not in choices[2][1]
            or selected is None):
        raise ValueError("unrecognized native command choices")
    command = [row.strip() for row in rows[start + 1:end] if row.strip()]
    if not command:
        raise ValueError("empty displayed command")
    body = json.dumps([command, choices], separators=(",", ":"))
    return {"fingerprint": hashlib.sha256(body.encode()).hexdigest(),
            "selected": selected, "command": command}


def matches(display, candidate):
    command = candidate["args"]["CommandLine"]
    if not isinstance(command, str) or not command or len(command) > 16384:
        return False
    # Native panels wrap without a marker, sometimes trimming the space at
    # the edge. Permit that whitespace only at an observed row boundary.
    pattern = r"\s*".join(re.escape(row) for row in display)
    return re.fullmatch(pattern, command.strip()) is not None


def main():
    verb = sys.argv[1]
    screen = sys.stdin.read(65537)
    if len(screen) > 65536 or "\x1b" in screen or "\x00" in screen:
        raise ValueError("invalid plain viewport")
    if verb == "active":
        rows = [row.strip() for row in screen.splitlines() if row.strip()]
        footer = rows[-1] if rows else ""
        # Either native signal may survive a vendor layout change. The real
        # tool result and generation-bound Stop are separate launch gates.
        rules = [i for i, row in enumerate(rows) if len(row) >= 5 and set(row) == {"─"}]
        hint = (len(rules) >= 2 and rows[rules[-2] + 1:rules[-1]] ==
                ["> Auto mode: edits & safe commands auto-approved (shift+tab to cycle)"])
        if re.search(r"(?:accept-edits|plan) ·", footer):
            hint = False
        active = hint or re.search(r"(?:^|\s)auto · \S", footer)
        if not active:
            raise ValueError("native Auto indicator absent")
        return
    if verb == "dialog":
        if not live_dialog(screen):
            raise ValueError("no live native command dialog")
        return
    result = panel(screen)
    if verb == "match":
        candidate = json.loads(Path(sys.argv[2]).read_text())
        if not isinstance(candidate, dict) or not isinstance(candidate.get("args"), dict):
            raise ValueError("native candidate requires an args object")
        if candidate.get("tool") != "run_command" or not matches(result["command"], candidate):
            raise ValueError("native prompt does not match exact hook input")
        result["candidate_digest"] = hashlib.sha256(
            json.dumps(candidate, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    elif verb != "prompt":
        raise ValueError("unknown viewport operation")
    print(json.dumps(result, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, StopIteration, IndexError) as error:
        print("agy native viewport: " + str(error), file=sys.stderr)
        sys.exit(1)
