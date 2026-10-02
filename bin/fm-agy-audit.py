#!/usr/bin/env python3
"""Archive a small agy task summary before teardown removes runtime records.

Usage: python3 bin/fm-agy-audit.py <state-dir> <task-id>
Appends to state/agy-permission-audit.jsonl, once per task/metadata digest.
Keeps task kind/mode, version, posture, armed generations, judge identity,
terminal state, permission decisions/resolution timing and judge metrics.
No command input, output, credentials or status prose is copied. Missing
historical timing/identity remains null, never inferred as a successful run.
Manual and observer-only tasks are explicitly outside confirmed judge coverage.
Malformed source records fail cleanup so the original evidence survives.
"""

import datetime as dt
import hashlib
import json
import re
import sys
from pathlib import Path


def timestamp(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def archive(state, task):
    if not re.fullmatch(r"[A-Za-z0-9._-]+", task):
        raise ValueError("invalid task id")
    meta_bytes = (state / f"{task}.meta").read_bytes()
    meta = dict(line.split("=", 1) for line in meta_bytes.decode().splitlines() if "=" in line)
    if meta.get("harness") != "agy":
        raise ValueError("archive requires an agy task record")
    identity = hashlib.sha256(task.encode() + b"\0" + meta_bytes).hexdigest()
    destination = state / "agy-permission-audit.jsonl"
    if destination.exists():
        for line in destination.read_text().splitlines():
            if json.loads(line).get("archive_key") == identity:
                return
    policy_path = state / f"{task}.agy-permission.json"
    policy = json.loads(policy_path.read_text()) if policy_path.exists() else {}
    rows = []
    log = state / "agy-permission-log.jsonl"
    if log.exists():
        with log.open() as stream:
            for line in stream:
                row = json.loads(line)
                if row.get("task") == task:
                    rows.append(row)
    armed = [r for r in rows if r.get("event") == "armed"]
    # Retry/timeout-verdict diagnostics use the same hook event as the final
    # decision and carry cumulative counters. Count each terminal verdict once.
    decisions = [r for r in rows if r.get("event") == "pre-tool-use"
                 and r.get("decision") in {"approve", "refuse", "escalate"}]
    holds = {"agy-permission-" + r["tool_use_id"]: timestamp(r.get("ts"))
             for r in decisions if r.get("decision") == "escalate" and r.get("tool_use_id")}
    resolutions = []
    for row in rows:
        reason = row.get("reason", "")
        key = reason[len("escalation "):] if reason.startswith("escalation ") else ""
        if key not in holds or row.get("event") not in {"approve", "decline", "retire", "post-tool-use"}:
            continue
        resolved = timestamp(row.get("ts"))
        held = holds[key]
        resolutions.append({"key": key, "held_at": held, "resolved_at": resolved,
                            "elapsed_seconds": resolved - held if resolved is not None and held is not None else None,
                            "result": row.get("decision"), "decider": row.get("decider")})
    status_path = state / f"{task}.status"
    terminal = None
    captain_calls = []
    if status_path.exists():
        for line in status_path.read_text().splitlines():
            match = re.match(r"(done|failed|blocked|paused|working|needs-decision|resolved)(?: \[([^]]+)\])*:", line)
            if match and match[1] != "resolved":
                terminal = match[1]
            # Preserve attribution only when the producer actually recorded it.
            if "[key=agy-permission-" in line and re.search(r"\[(?:actor|decider)=captain\]", line):
                epoch = re.search(r"\[at=(\d+)\]", line)
                key = re.search(r"\[key=([^]]+)\]", line)
                captain_calls.append({"key": key[1], "state": line.split(" ", 1)[0],
                                      "at": int(epoch[1]) if epoch else None})
    judged = [r for r in decisions if r.get("decider") == "judge"]
    metrics_complete = all(all(field in r for field in ("judge_attempts", "judge_elapsed_seconds", "judge_timeouts")) for r in judged)
    summary = {
        "archive_key": identity, "task": task, "archived_at": dt.datetime.now(dt.timezone.utc).isoformat(),
        "kind": meta.get("kind"), "mode": meta.get("effective_mode", meta.get("mode")),
        "agy_version": policy.get("agy_version", meta.get("agy_version")),
        "permission_mode": meta.get("agy_permission_mode"),
        "bypass": meta.get("agy_bypass") == "on", "result": terminal,
        "judge_tier": policy.get("judge_tier"), "judge_model": policy.get("judge_model"),
        "recorded_judge": meta.get("agy_judge"),
        "armed_generations": [{"gen": r.get("gen"), "session_id": r.get("session_id"), "at": r.get("ts"), "agy_version": r.get("agy_version"),
                               "judge_tier": r.get("judge_tier"), "judge_model": r.get("judge_model")} for r in armed],
        "confirmed_judge_coverage": meta.get("agy_bypass") == "on" and bool(policy.get("gen")) and any(
            a.get("gen") == policy["gen"] and any(
                r.get("gen") == a["gen"] and r.get("session_id") == a.get("session_id") for r in decisions
            ) for a in armed
        ),
        "decisions": {name: sum(r.get("decision") == name for r in decisions) for name in ("approve", "refuse", "escalate")},
        "resolution_timing": resolutions, "captain_resolution_timing": captain_calls,
        "captain_timing_complete": False,  # Existing records do not prove who was asked in chat.
        "judge_metrics_complete": metrics_complete,
        "judge_elapsed_seconds": sum(r.get("judge_elapsed_seconds", 0) for r in judged) if metrics_complete else None,
        "judge_attempts": sum(r.get("judge_attempts", 0) for r in judged) if metrics_complete else None,
        "judge_retries": sum(max(0, r.get("judge_attempts", 0) - 1) for r in judged) if metrics_complete else None,
        "judge_timeouts": sum(r.get("judge_timeouts", 0) for r in judged) if metrics_complete else None,
        "approved_retries": sum(r.get("decider") in {"cache", "firstmate"} for r in decisions),
    }
    with destination.open("a") as stream:
        stream.write(json.dumps(summary, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: fm-agy-audit.py <state-dir> <task-id>")
        archive(Path(sys.argv[1]), sys.argv[2])
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"fm-agy-audit: archive failed: {error}", file=sys.stderr)
        sys.exit(1)
