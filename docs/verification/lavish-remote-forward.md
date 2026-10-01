# Lavish over an ssh LocalForward

This record supports the remote-viewing path in [`docs/lavish.md`](../lavish.md): Lavish pinned to loopback on the Firstmate machine and reached from another computer through an ssh `LocalForward`.
It was measured on 2026-09-30 with lavish-axi 0.1.80, OpenSSH 10.3p1, Node 24.20.0, and macOS 26.6.2 on arm64.
The laptop was simulated on the same machine: a throwaway user-level `sshd` on a spare loopback port with its own host and client keys, reached by an `ssh -L` client.
`$LAB` below is a scratch directory, and `<key>` stands for the session key Lavish printed.

## Setup

```sh
export LAVISH_AXI_TELEMETRY=0 LAVISH_AXI_NO_OPEN=1 LAVISH_AXI_HOST=127.0.0.1 LAVISH_AXI_STATE_DIR="$LAB/state"
lavish-axi "$LAB/art/board.html"
/usr/sbin/sshd -f "$LAB/sshd/sshd_config"      # Port 22422, ListenAddress 127.0.0.1, key auth only
ssh -F "$LAB/sshd/ssh_config" -f -N -o ExitOnForwardFailure=yes laptop-sim   # LocalForward 14387 127.0.0.1:4387
```

`lavish-axi` printed `url: "http://127.0.0.1:4387/session/<key>"` and `status: opened`, and `lsof -nP -iTCP:4387 -sTCP:LISTEN` showed the server on `127.0.0.1:4387` only.

## Results through the forward

| Check | Command | Result |
| --- | --- | --- |
| No forward yet | `curl http://127.0.0.1:14387/session/<key>` | `Failed to connect ... Couldn't connect to server` |
| Review page | `curl http://127.0.0.1:14387/session/<key>` | `200`, 18618 bytes |
| Host header of the printed link | same, with `-H 'Host: 127.0.0.1:4387'` | `200` |
| `localhost` name | `curl http://localhost:14387/session/<key>` | `200` |
| Artifact | `curl http://127.0.0.1:14387/artifact/<key>/board.html` | the artifact's own text |
| Foreign host name | `-H 'Host: evil.example:4387'` | `403` |
| Live update channel | WebSocket to `ws://127.0.0.1:14387/events/<key>` with a matching `Origin` | opened, first message `{"type":"chat-sync",...}` |
| Foreign `Origin` | the same WebSocket with `Origin: http://evil.example` | rejected `403` |
| Real browser | headless Chrome on `http://127.0.0.1:14387/session/<key>` | the Lavish editor rendered with its conversation panel |
| Two Lavish sessions | a second artifact opened beside the first | both session URLs returned `200` through one forward |

## Failure behavior

| Situation | Observed |
| --- | --- |
| Second ssh session with the same `LocalForward` | `bind [127.0.0.1]:14387: Address already in use`, `Could not request local forwarding.`, and the session ran its command; the first forward kept serving `200` |
| Same, with `ExitOnForwardFailure=yes` | the same messages and exit `255` |
| Forward-owning session closed while another session stays open | the forward was gone: `curl` could not connect |
| Forward up, Lavish server stopped (`lavish-axi stop`) | `curl: (56) Recv failure: Connection reset by peer` |
| `lavish-axi <file>` again after that | the server restarted with the same session URL, and the page returned `200` through the forward |
| Lavish's port taken by another listener on the Firstmate machine | `error: Lavish Editor server did not start`, `code: SERVER_ERROR`, exit 1 |
| `LAVISH_AXI_PORT=4388` | `url: "http://127.0.0.1:4388/session/<key>"`, so a different port must change on both sides |

## Answers board end to end

In a scratch home with `config/lavish` set to `answers` and one captain-held task, `bin/fm-bearings-board.sh build` against the real lavish-axi printed `session: live`, the session URL, `bound: lavish-<id>`, and `armed: lavish-<id>`, and `bin/fm-procevent.sh list` showed the source `live`.
A headless Chromium session (Playwright) opened the session URL through the forward, chose an option on the decision card, typed a note, queued the answer, and used Send to Agent.
The queued prompt carried the `fm-bearings-answer.v1` context, and the merge card rendered with no answer form and no dispatch picker.
The captured result classified as `feedback`, `bin/fm-procevent-lavish.sh answers` printed `<task-id>	amber	Sample widget color -> amber - warmer fits the brand`, and the held task was closed with `Answer: amber` and the captured result named as its source.
A following build with `--lavish view` printed `retired: lavish-<id>`, and afterwards no source was registered and no binding remained.

## Refresh

`tests/fm-bearings-board-lavish-live-e2e.test.sh` re-proves the vendor-dependent part on any machine with lavish-axi installed: an answers-mode build serves, binds, and arms on loopback only, and a captain-ended session is reported as `user-ended` and reopened by the build.
The ssh forward itself is standard OpenSSH behavior and needs no refresh unless the remote path changes.
