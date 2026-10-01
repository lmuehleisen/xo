# Optional Lavish

Lavish (`lavish-axi`) turns an HTML artifact into a review page you can annotate and send feedback from.
This fork works fully without it: boards stay static local files and every answer stays in chat.
This page covers turning it on, the install rules, and viewing Lavish pages from another computer over ssh.
[`docs/configuration.md`](configuration.md#optional-lavish-configlavish) owns the `config/lavish` schema, and `bin/fm-lavish.sh --help` owns the commands.

## What each mode adds

| Mode | `/bearings lavish` board | Scout review loops |
| --- | --- | --- |
| `off` (default) | A static local HTML file; answers in chat | Not offered |
| `view` | The same read-only board, opened in Lavish; annotations reach Firstmate as review feedback | Offered for visual deliverables |
| `answers` | Decision cards take answers in the page as well as in chat | Offered for visual deliverables |

In `answers` mode only decision cards are answerable on the board.
Merge, credential, and dispatch requests stay in chat, and every board answer goes through the same keyed-answer intake as a chat answer.

## Install

Install only the pinned version, with no setup step:

```sh
npm install -g --ignore-scripts lavish-axi@0.1.80
```

`bin/fm-lavish.sh install-command` prints the same line.
Neither the package nor any of its dependencies has an install-time script, so the install writes only npm's own package directory and cache.
Never run `lavish-axi setup hooks`, `setup plugin`, `update`, or `share`, and never add its agent skill: those install agent hooks, self-update, or publish a page to a public third-party host.
Firstmate treats any other installed version as unavailable.

Firstmate and its workers start Lavish only through `bin/fm-lavish.sh run`, which refuses those subcommands and pins three settings:

- `LAVISH_AXI_TELEMETRY=0`, because the published build reports usage by default.
- `LAVISH_AXI_NO_OPEN=1`, so nothing opens a browser on the Firstmate machine's own screen.
- `LAVISH_AXI_HOST=127.0.0.1` unless `config/lavish-axi-host` says otherwise, so the server is reachable only from that machine.

If you ever run `lavish-axi` by hand, set the same three variables yourself.

## Turn it on

Write `view` or `answers` into `config/lavish` in the Firstmate home; delete the file or write `off` to turn it off.
Secondmate homes inherit the file.

You can also ask for or decline Lavish for one board or one review regardless of the home setting.
Say so when you ask for it - for example, ask for "/bearings lavish answers", or say "no Lavish this time" - and Firstmate passes that choice for that one artifact.
If Lavish is wanted but not installed, Firstmate builds the static board instead and tells you why.

## View Lavish pages from another computer over ssh

The Lavish server has no login of its own: anyone who can reach its port can read files the account can read and send feedback that looks like yours.
So it listens only on the Firstmate machine's loopback address, and you reach it through the ssh connection you already use.
Do not point `config/lavish-axi-host` at a LAN, VPN, or public address, and do not put the port behind a public tunnel.

### One-time setup on your laptop

Add one line to the `Host` entry you already use to ssh into the Firstmate machine, in `~/.ssh/config` on the laptop:

```sshconfig
Host firstmate-machine
    # ...your existing HostName, User, ProxyCommand, and other lines...
    LocalForward 4387 127.0.0.1:4387
```

Beyond installing Lavish and turning it on, nothing changes on the Firstmate machine, and no network or tunnel configuration changes anywhere.
A connection that goes through a `ProxyCommand` forwards the same way, because the forward rides inside the ssh session.

### Each time you review

1. Open an ssh session to the Firstmate machine as usual (`ssh firstmate-machine`) and keep it open while you review.
2. When Firstmate gives you a Lavish link, such as `http://127.0.0.1:4387/session/0123456789abcdef`, open it unchanged in the laptop's browser.
3. Annotate or answer, then use Send to Agent; Send & End also ends the review.

The forward belongs to the first ssh session that opened it.
A second session to the same machine prints `bind [127.0.0.1]:4387: Address already in use` and carries on without its own forward, and the first session's forward keeps working.
Closing the first session closes the forward, even while other sessions stay open, so keep that one open or open a dedicated one with `ssh -N firstmate-machine`.

### Troubleshooting

| What you see | What it means | What to do |
| --- | --- | --- |
| The browser cannot connect to `127.0.0.1:4387` | No ssh session with the forward is open on this laptop | Open one, or check that the session that owned the forward is still open |
| ssh prints `bind [127.0.0.1]:4387: Address already in use` | Another session, or another program on the laptop, already holds port 4387 | If it is your earlier ssh session, carry on; otherwise use `LocalForward 14387 127.0.0.1:4387` and change `4387` to `14387` in the link |
| The connection is reset or the page is empty | The forward works, but the Lavish server on the Firstmate machine is not running; it stops 30 minutes after the last page disconnects | Ask Firstmate to reopen the board (for example `/bearings lavish` again); the link stays the same |
| `403 Forbidden` | The link was opened with a hostname other than `127.0.0.1` or `localhost` | Use the link exactly as printed |
| Firstmate reports the board session is not open | You ended that review from the browser | Ask for the board again; a fresh `/bearings lavish` reopens it once |

### What was and was not tested

This path was proven on the Firstmate machine itself, with a second ssh server on another loopback port standing in for the laptop; [`docs/verification/lavish-remote-forward.md`](verification/lavish-remote-forward.md) records the commands and results.
Through a real `LocalForward`, the review page, the artifact, and the live update channel all loaded, a headless browser answered a board decision, and that answer closed the held decision through the keyed-answer intake.

These could not be tested without the laptop itself:

- the laptop's own ssh client and its proxy hop to the Firstmate machine;
- the laptop browser over the real link, including how the page behaves when the laptop sleeps or changes network;
- whether something on the laptop already uses port 4387.

The first real review from the laptop is the confirmation; the troubleshooting table covers the failures those gaps could produce.
