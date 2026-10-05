# Lavish on a Tailscale address

This record supports the Tailscale viewing path in [`docs/lavish.md`](../lavish.md), in which `config/lavish-axi-host` names the Firstmate machine's tailnet IPv4 address so other tailnet devices can open the board directly.
The checks cover which addresses the server listens on and answers; a fetch from another device is listed under Not covered.
It was measured on 2026-10-03 with lavish-axi 0.1.80, Tailscale 1.102.4, Node 24.20.0, and macOS 27.0.1 on arm64.
`$LAB` below is a scratch directory, `<tailnet-ip>` is the address `tailscale ip -4` printed, `<lan-ip>` is the machine's Wi-Fi address, and `<key>` is the session key Lavish printed.
A spare port and a scratch state directory kept the run apart from the home's own Lavish server.

## Setup

```sh
tailscale ip -4 > "$LAB/config/lavish-axi-host"
export FM_CONFIG_OVERRIDE="$LAB/config" LAVISH_AXI_STATE_DIR="$LAB/state" LAVISH_AXI_PORT=4399
bin/fm-lavish.sh run "$LAB/board/test.html"
```

`fm-lavish.sh run` printed `url: "http://<tailnet-ip>:4399/session/<key>"` and `status: opened`, and `lsof -nP -iTCP:4399 -sTCP:LISTEN` showed exactly two listeners, `127.0.0.1:4399` and `<tailnet-ip>:4399`.

## Results

| Check | Command | Result |
| --- | --- | --- |
| Tailnet address | `curl http://<tailnet-ip>:4399/session/<key>` | `200`, page title `ts test · Lavish` |
| Loopback | `curl http://127.0.0.1:4399/session/<key>` | `200` |
| LAN address | `curl http://<lan-ip>:4399/session/<key>` | `curl: (7)`, connection refused |
| Tailnet IPv6 address | `curl 'http://[<tailnet-ipv6>]:4399/session/<key>'` | no listener; `curl: (28)` timeout |
| MagicDNS name | `curl http://<machine>.<tailnet>.ts.net:4399/session/<key>` | `403`, because Lavish accepts only the hostnames it printed or bound |

`tailscale serve status` and `tailscale funnel status` both printed `No serve config`.

## Teardown

```sh
bin/fm-lavish.sh run end "$LAB/board/test.html"   # status: ended
bin/fm-lavish.sh run stop                          # status: not-running
lsof -nP -iTCP:4399 -sTCP:LISTEN                   # no output
```

## Not covered

No second device fetched the board, so the laptop browser, the live update channel, and Send to Agent over the tailnet remain unproven; which tailnet devices the access policy admits depends on each tailnet's policy and was not exercised from another device.
The loopback behavior that does not depend on the tailnet is refreshed by `tests/fm-bearings-board-lavish-live-e2e.test.sh`.
