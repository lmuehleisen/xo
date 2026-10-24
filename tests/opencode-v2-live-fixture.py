#!/usr/bin/env python3
"""Exercise a spawn-generated worker plugin in a real V2 server with a local protocol fixture.

tests/fm-opencode-primary-live-e2e.test.sh runs bin/fm-spawn.sh against a fake
pane, then hands this fixture the staged launch command it logged. The fixture
starts the given executable as a private `opencode serve` with that launch's
OPENCODE_CONFIG_CONTENT, answers every model request from a loopback provider,
and drives sessions through the public HTTP API. No provider outside this
process is contacted.
"""

import argparse
import base64
import http.server
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request


def launch_config(launch_log):
    # The logged launch is the exact command the pane would run; its
    # OPENCODE_CONFIG_CONTENT assignment is the worker's whole private config.
    for line in Path(launch_log).read_text().splitlines():
        for token in shlex.split(line):
            if token.startswith("OPENCODE_CONFIG_CONTENT="):
                return token.split("=", 1)[1]
    raise RuntimeError("the spawn launch carried no OPENCODE_CONFIG_CONTENT")


def run(lab, args):
    config = launch_config(args.launch_log)
    plugin_dirs = json.loads(config).get("plugins", [])
    assert len(plugin_dirs) == 1 and plugin_dirs[0].startswith("/tmp/fm-"), plugin_dirs
    worktree = Path(args.worktree)
    turn_ended = Path(args.state) / f"{args.task}.turn-ended"
    holds = {key: threading.Event() for key in ("HOLD_ROOT", "HOLD_CHILD", "HOLD_INTERRUPT", "HOLD_SHUTDOWN")}
    entered = {key: threading.Event() for key in holds}

    class Provider(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            messages = body.get("messages", [])
            last_user = max((i for i, item in enumerate(messages) if item.get("role") == "user"), default=0)
            text = json.dumps(messages[last_user].get("content", ""))
            if "CASE_FAIL" in text:
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b'{"error":{"message":"isolated provider failure fixture","type":"invalid_request_error"}}')
                return
            for key, release in holds.items():
                if key in text:
                    entered[key].set()
                    release.wait(timeout=60)
            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                chunk = {"id": "chatcmpl-fixture", "object": "chat.completion.chunk", "created": 1, "model": "fixture", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "NATIVE_FIXTURE_ACK"}, "finish_reason": None}]}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                chunk["choices"][0] = {"index": 0, "delta": {}, "finish_reason": "stop"}
                self.wfile.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass

    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    home = lab / "home"
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(("OPENCODE_", "FM_", "XDG_")) or key in ("TMUX", "TMUX_PANE", "HERDR_ENV", "NO_MISTAKES_GATE"):
            del env[key]
    env.update(HOME=str(home), TMPDIR=str(lab), OPENCODE_CONFIG_CONTENT=config, OPENCODE_DB=str(lab / "native.db"), OPENCODE_DISABLE_MODELS_FETCH="1", OPENCODE_DISABLE_AUTOUPDATE="1", OPENCODE_DISABLE_LSP_DOWNLOAD="1")
    for kind in ("CONFIG", "DATA", "CACHE", "STATE"):
        path = home / kind.lower()
        path.mkdir(parents=True)
        env[f"XDG_{kind}_HOME"] = str(path)
    # The provider lives in this lab's user config, so the worktree stays free
    # of OpenCode files and the spawn's config is the only Firstmate input.
    (home / "config/opencode").mkdir()
    (home / "config/opencode/opencode.json").write_text(json.dumps({
        "snapshots": False,
        "providers": {"fixture": {"package": "@opencode/ai/providers/openai-compatible", "settings": {"baseURL": f"http://127.0.0.1:{provider.server_port}/v1", "apiKey": "isolated-test-not-a-secret"}, "models": {"native": {"capabilities": {"tools": True, "input": ["text"], "output": ["text"]}, "limit": {"context": 100000, "output": 1000}}}}},
    }))
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    logpath = lab / "server.log"
    log = logpath.open("w")
    process = subprocess.Popen([os.path.abspath(args.opencode), "serve", "--hostname", "127.0.0.1", "--port", str(port)], cwd=worktree, env=env, stdout=log, stderr=log)
    headers = {}
    events = []

    def api(path, body=None, method=None):
        request = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=json.dumps(body).encode() if body is not None else None, method=method, headers={**headers, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                data = response.read()
                return json.loads(data) if data else None
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"API {path} returned {error.code}: {error.read().decode()}") from None

    def until(check, label, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            value = check()
            if value:
                return value
            time.sleep(0.1)
        raise RuntimeError(f"Timed out: {label}; busy record {busy()}")

    def busy():
        # The production record reader; prints "<state> <source> <event> <seq>".
        result = subprocess.run(["bash", "-c", '. "$1/bin/fm-busy-lib.sh" && fm_busy_record_read "$2" "$3"', "busy", args.root, args.state, args.task], capture_output=True, text=True)
        fields = result.stdout.split()
        return (fields[0], fields[1], int(fields[3])) if len(fields) == 4 else tuple(fields)

    def watch_events():
        request = urllib.request.Request(f"http://127.0.0.1:{port}/api/event", headers=headers)
        try:
            with urllib.request.urlopen(request) as stream:
                for line in stream:
                    if line.startswith(b"data: "):
                        events.append(json.loads(line[6:]))
        except (OSError, ValueError):
            pass

    def terminal_seen(sid):
        return any(e.get("type", "").startswith("session.execution.") and e.get("type") != "session.execution.started" and e.get("data", {}).get("sessionID") == sid for e in events)

    def outcome(sid):
        return api(f"/api/session/{sid}")["data"].get("outcome")

    def hold_main(key):
        turn_ended.unlink(missing_ok=True)
        api(f"/api/session/{sid}/prompt", {"text": key})
        until(entered[key].is_set, key + " model request")
        return until(lambda: busy()[:2] == ("busy", "opencode-plugin") and busy(), key + " busy")

    def settle_main(label, before):
        record = until(lambda: busy()[:2] == ("idle", "opencode-plugin") and busy(), label + " idle")
        assert record[2] == before + 2, f"{label}: expected one busy and one idle apply, record {record} after seq {before}"
        until(turn_ended.exists, label + " turn-end notification")

    def assert_still_held(label, record):
        time.sleep(1.5)
        assert busy() == record, f"{label} changed the worker's busy record: {busy()} != {record}"
        assert not turn_ended.exists(), f"{label} notified a worker turn end"

    try:
        password = until(lambda: next((line.removeprefix("server password ") for line in logpath.read_text().splitlines() if line.startswith("server password ")), None), "server readiness")
        headers["Authorization"] = "Basic " + base64.b64encode(f"opencode:{password}".encode()).decode()
        version = api("/api/info")["version"]
        threading.Thread(target=watch_events, daemon=True).start()
        location = {"location": {"directory": str(worktree)}}
        location_query = urllib.parse.urlencode({"location[directory]": str(worktree)})

        def plugin_active():
            return any(p.get("id") == "firstmate.worker-busy" and p["state"]["status"] == "active" for p in api("/api/plugin?" + location_query)["data"])

        until(plugin_active, "worker plugin readiness")
        status = subprocess.run(["git", "-C", str(worktree), "status", "--porcelain", "--ignored"], capture_output=True, text=True, check=True).stdout
        assert not status.strip(), status
        print(f"ok - OpenCode {version} loads the spawn's worker plugin from its private launch config; the worktree has no OpenCode files")
        seed = busy()
        assert seed[:2] == ("busy", "fm-spawn"), seed
        sid = api("/api/session", {**location, "agent": "build"})["data"]["id"]
        turn_ended.unlink(missing_ok=True)
        api(f"/api/session/{sid}/prompt", {"text": "Native worker smoke test."})
        until(lambda: outcome(sid) == "succeeded", "first turn")
        settle_main("succeeded turn", seed[2])
        print("ok - a succeeded turn applies busy then idle once and notifies the worker turn end")

        held = hold_main("HOLD_ROOT")
        other = api("/api/session", {**location, "agent": "build"})["data"]["id"]
        api(f"/api/session/{other}/prompt", {"text": "Unrelated root session."})
        until(lambda: outcome(other) == "succeeded" and terminal_seen(other), "unrelated root terminal event")
        assert_still_held("an unrelated root's terminal event", held)
        holds["HOLD_ROOT"].set()
        settle_main("held main turn", held[2] - 1)
        print("ok - an unrelated same-directory root's turn neither settles nor notifies the worker session")

        held = hold_main("HOLD_CHILD")
        child = api("/api/session", {**location, "agent": "build", "parentID": sid})["data"]
        assert child.get("parentID") == sid, child
        api(f"/api/session/{child['id']}/prompt", {"text": "Child session."})
        until(lambda: outcome(child["id"]) == "succeeded" and terminal_seen(child["id"]), "child terminal event")
        assert_still_held("a child session's terminal event", held)
        holds["HOLD_CHILD"].set()
        settle_main("main turn after child", held[2] - 1)
        print("ok - a child session's turn neither settles nor notifies the worker session")

        held = hold_main("HOLD_INTERRUPT")
        assert api(f"/api/session/{sid}/interrupt?resume=false", method="POST")["interrupted"]
        holds["HOLD_INTERRUPT"].set()
        until(lambda: outcome(sid) == "interrupted", "interrupted turn")
        settle_main("interrupted turn", held[2] - 1)
        print("ok - a user-interrupted turn settles idle and notifies the worker turn end")

        before = busy()[2]
        turn_ended.unlink(missing_ok=True)
        api(f"/api/session/{sid}/prompt", {"text": "CASE_FAIL"})
        until(lambda: outcome(sid) == "failed", "failed turn")
        settle_main("failed turn", before)
        print("ok - a failed turn settles idle and notifies the worker turn end")

        before = busy()[2]
        api("/api/location/reload", method="POST")
        until(plugin_active, "worker plugin after reload")
        turn_ended.unlink(missing_ok=True)
        api(f"/api/session/{sid}/prompt", {"text": "After plugin reload."})
        until(lambda: outcome(sid) == "succeeded", "turn after reload")
        settle_main("turn after reload", before)
        print("ok - after a plugin reload exactly one subscription applies the worker's lifecycle")

        held = hold_main("HOLD_SHUTDOWN")
        process.send_signal(signal.SIGTERM)
        process.wait(timeout=15)
        holds["HOLD_SHUTDOWN"].set()
        assert_still_held("server shutdown", held)
        failures = [line for line in logpath.read_text().splitlines() if "event subscription failed" in line]
        assert not failures, failures
        print("ok - server shutdown keeps the worker busy for resume, and its plugin cleanup reports no subscription failure")
    finally:
        for release in holds.values():
            release.set()
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        provider.shutdown()
        provider.server_close()
        log.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    for name in ("opencode", "launch-log", "root", "state", "task", "worktree"):
        parser.add_argument("--" + name, required=True)
    with tempfile.TemporaryDirectory(prefix="fm-opencode-v2-live-") as directory:
        run(Path(directory).resolve(), parser.parse_args())
    print("ok - private OpenCode server, provider, configuration and database cleaned")
