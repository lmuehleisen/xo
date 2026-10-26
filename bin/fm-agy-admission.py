#!/usr/bin/env python3
"""Executable-bound agy compatibility evidence; fm-agy-admission.sh owns admission.

Internal verbs: snapshot, match, publish, complete, assert. Receipts are private
local evidence, not signatures or a security boundary against their owner.
The binding includes executable stat/hash, platform, integration/guard bytes,
explicit worker model/effort, and selected judge identity/model. A version is
only eligibility; the historical verified-versions list never proves a binary.
"""

import hashlib
import json
import os
from pathlib import Path
import platform
import re
import stat
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
SCHEMA = "fm-agy-compatibility.v2"
GUARDS = {
    "native": [
        "verified-startup", "warm-auto", "actual-tool-result", "brief-handoff",
        "native-prompt-or-safe-completion", "deterministic-deny",
        "status-inbox-roundtrip", "busy-start-stop", "hook-retire",
    ],
    "bypass": [
        "credential-shell", "credential-native", "shell-refusal",
        "native-create-edit", "native-outside-refusal", "judge-approval",
        "dead-judge", "malformed-hooks", "force-ask-attempt", "unarmed-session",
    ],
    "observer": ["observer-pair"],
    "signals": [
        "interactive-composer", "accept-edits-native", "shell-prompt",
        "busy-start-stop", "interrupt-delivery", "interactive-exit", "hook-retire",
        "effort-conflict",
    ],
}
INTEGRATION = [
    "bin/fm-agy-admission.py", "bin/fm-agy-admission.sh",
    "bin/fm-agy-lib.sh", "bin/fm-spawn.sh", "bin/fm-agy-hook.sh",
    "bin/fm-agy-permission-policy.sh", "bin/fm-command-policy-lib.sh",
    "bin/fm-agy-native.py", "bin/fm-agy-native-lib.sh", "bin/fm-watch.sh",
    "bin/fm-backend.sh", "bin/backends/tmux.sh", "bin/backends/herdr.sh",
    "bin/fm-credential-access.mjs", "bin/fm-credential-access-lib.sh",
    "bin/fm-judge-tier-lib.sh", "bin/fm-timeout-lib.sh", "bin/fm-wake-lib.sh",
    "bin/fm-path-lib.sh", "bin/fm-primary-scope-lib.sh",
    "bin/fm-subagent-pretool-check.sh", "bin/fm-arm-pretool-check.sh",
    "bin/fm-cd-pretool-check.sh", ".agents/hooks.json",
    "bin/fm-busy-event.sh", "bin/fm-busy-lib.sh", "bin/fm-control-lib.sh",
    "bin/fm-composer-lib.sh", "bin/fm-operational-input.sh",
    "tests/lib.sh", "tests/agy-live-helpers.sh",
    "tests/git-config-helpers.sh", "tests/tmproot-guard.sh",
    "tests/fm-agy-bypass-live-e2e.test.sh",
    "tests/fm-agy-observer-live-e2e.test.sh",
    "tests/fm-agy-signals-live-e2e.test.sh",
    "tests/fm-agy-native-live-e2e.test.sh",
    "tests/fm-agy-native.test.sh", "tests/agy-native-terminal-fixture.py",
]


def guards_for(binding):
    first = "native" if binding["context"].get("posture") == "native-auto" else "bypass"
    return {name: GUARDS[name] for name in (first, "observer", "signals")}


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def identity(name):
    path = Path(name)
    if not path.is_absolute() or not os.access(path, os.X_OK):
        raise ValueError("selected executable must be an absolute executable file")
    resolved = path.resolve(strict=True)
    with resolved.open("rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("selected executable is not a regular file")
        sha = hashlib.sha256()
        for block in iter(lambda: source.read(1024 * 1024), b""):
            sha.update(block)
        after = os.fstat(source.fileno())
    def stable(info):
        return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                info.st_mtime_ns, info.st_ctime_ns)

    if (stable(before) != stable(after) or path.resolve(strict=True) != resolved
            or stable(path.stat()) != stable(after)):
        raise ValueError("executable changed while identifying it")
    return {
        "path": str(path), "resolved": str(resolved), "sha256": sha.hexdigest(),
        "device": after.st_dev, "inode": after.st_ino, "size": after.st_size,
        "mtime_ns": after.st_mtime_ns, "ctime_ns": after.st_ctime_ns,
    }


def private(path, directory=False):
    info = path.lstat()
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected(info.st_mode) or info.st_uid != os.geteuid()
            or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
            or (not directory and info.st_nlink != 1)):
        raise ValueError("untrusted compatibility evidence: " + str(path))


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def read_json(path, trusted=False):
    if trusted:
        private(path.parent, directory=True)
        private(path)
    if path.stat().st_size > 262144:
        raise ValueError("oversized compatibility evidence")
    return json.loads(path.read_text(), object_pairs_hook=unique_object)


def write_json(path, value):
    private(path.parent, directory=True)
    fd, temporary = tempfile.mkstemp(prefix=".proof-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(encoded(value) + b"\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def context(args):
    executable, model, effort, tier, judge_model, judge_bin = args
    if model in ("", "default"):
        raise ValueError("compatibility requires an explicit --model; the mutable default is untested")
    if tier in ("native-tmux", "native-herdr") and not judge_model and not judge_bin:
        return {"model": model, "effort": effort,
                "tool_contract": "native-file-and-shell-v2", "posture": "native-auto",
                "backend": tier[len("native-"):]}
    if tier not in ("agy", "devin") or not judge_model:
        raise ValueError("unknown judge context")
    return {
        "model": model, "effort": effort, "tool_contract": "native-file-and-shell-v1",
        "judge_tier": tier, "judge_model": judge_model,
        "judge_executable": identity(judge_bin),
    }


def snapshot(args):
    executable = args[0]
    binary = identity(executable)
    env = dict(os.environ, AGY_CLI_DISABLE_AUTO_UPDATE="1")
    result = subprocess.run(
        [executable, "--version"], env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=True,
    )
    version = result.stdout.decode().strip()
    match = re.fullmatch(r"(?:agy )?([0-9]+\.[0-9]+\.[0-9]+)", version)
    if not match or binary != identity(executable):
        raise ValueError("unreadable version or executable replaced during version query")
    hashes = {name: digest((ROOT / name).read_bytes()) for name in INTEGRATION}
    return {
        "executable": binary, "version": match[1],
        "platform": {
            "system": platform.system(), "machine": platform.machine(),
            "release": platform.release(),
        },
        "integration": digest(encoded(hashes)), "context": context(args),
    }


def coverage(proofs, binding):
    guards = guards_for(binding)
    if set(proofs) != set(guards):
        raise ValueError("incomplete live guard coverage")
    for guard, required in guards.items():
        proof = proofs[guard]
        if (proof.get("guard") != guard or proof.get("coverage") != required
                or proof.get("context") != binding["context"]
                or not isinstance(proof.get("seconds"), (int, float))
                or proof["seconds"] < 0
                or not proof.get("tools")):
            raise ValueError("incomplete or mismatched " + guard + " guard")
        if guard == "native" and any(type(proof.get(key)) is not bool
                                     for key in ("live_approval", "live_decline")):
            raise ValueError("native live observations must be explicit booleans")


def receipt_matches(path, binding):
    receipt = read_json(path, trusted=True)
    if (receipt.get("schema") != SCHEMA or receipt.get("binding") != binding
            or receipt.get("origin") not in ("patch-verification", "manual-baseline")
            or type(receipt.get("completed_at")) is not int):
        raise ValueError("stale or malformed compatibility receipt")
    coverage(receipt["proofs"], binding)
    return receipt


def main():
    verb, *args = sys.argv[1:]
    if verb == "directory":
        private(Path(args[0]), directory=True)
    elif verb == "snapshot":
        binding = snapshot(args)
        print(json.dumps(binding, sort_keys=True))
    elif verb == "key":
        print(digest(encoded(read_json(Path(args[0])))))
    elif verb == "match":
        receipt_matches(Path(args[0]), read_json(Path(args[1])))
    elif verb == "assert":
        receipt_matches(Path(args[0]), snapshot(args[1:]))
    elif verb == "complete":
        directory, guard, seconds, *logs = args
        tools = set()
        for log in logs:
            if Path(log).is_file():
                for line in Path(log).read_text().splitlines():
                    record = json.loads(line)
                    if record.get("tool"):
                        tools.add(record["tool"])
        binding = read_json(Path(os.environ["FM_AGY_ADMISSION_BINDING"]))
        proof = {
            "guard": guard, "coverage": GUARDS[guard], "tools": sorted(tools),
            "context": binding["context"], "seconds": float(seconds),
        }
        if guard == "native":
            proof["live_approval"] = os.environ.get("FM_AGY_NATIVE_OBSERVED_APPROVAL") == "1"
            proof["live_decline"] = os.environ.get("FM_AGY_NATIVE_OBSERVED_DECLINE") == "1"
        write_json(Path(directory) / (guard + ".json"), proof)
    elif verb == "publish":
        receipt, selected, proof_dir, origin, *selected_args = args
        binding = read_json(Path(selected))
        if binding != snapshot(selected_args):
            raise ValueError("executable or integration replaced during proof; evidence invalidated")
        proofs = {
            guard: read_json(Path(proof_dir) / (guard + ".json"), trusted=True)
            for guard in guards_for(binding)
        }
        coverage(proofs, binding)
        write_json(Path(receipt), {
            "schema": SCHEMA, "binding": binding, "proofs": proofs,
            "origin": origin, "completed_at": int(time.time()),
        })
    else:
        raise ValueError("unknown compatibility evidence operation")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("agy compatibility: " + str(error), file=sys.stderr)
        sys.exit(1)
