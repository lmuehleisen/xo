# tmux runtime backend

tmux is Firstmate's verified reference runtime backend and the fully supported baseline for secondmate homes.
[`configuration.md`](configuration.md#runtime-backend-configbackend--fm_backend) owns shared backend selection and metadata semantics.

## Setup

Install tmux with `brew install tmux` or your platform package manager.
The universal harness and toolchain requirements are in [`configuration.md`](configuration.md#toolchain).

tmux is the hard default when no explicit setting or runtime auto-detection selects another backend.
Select it explicitly with local `config/backend` containing `tmux`, with `FM_BACKEND=tmux` for one launch, or by asking Firstmate to use tmux.
Explicit tmux selection via `config/backend` or `--backend tmux` overrides runtime auto-detection.

No provisioning is required before the first task.

## Watching the crew

For the best visible experience, launch the primary harness inside a tmux session:

```sh
tmux new -s firstmate
```

Crew tasks become windows in that session.
`tmux display-message -p '#S'` prints its name.
If the primary harness runs outside tmux, Firstmate creates or reuses a detached session named `firstmate`:

```sh
tmux attach -t firstmate
```

Each task window is named `fm-<id>`.

```sh
tmux list-windows -t <session-name>
tmux select-window -t <session-name>:fm-<id>
```

Typing into an attached task window is authoritative direct intervention.
Routine supervision does not require attachment: `bin/fm-peek.sh <id>` captures a bounded tail and `FM_HOME=<home> bin/fm-send.sh <id> '<text>'` steers the recorded endpoint.

Verify setup by spawning a small task and confirming its `fm-<id>` window appears in the selected session.

## Current behavior and safety

### Worker isolation from the fleet server

tmux picks a client's server from an inherited `TMUX` before it reads `TMUX_TMPDIR`, and without either it uses the default server, where the fleet usually runs.
Every ship and scout agent therefore starts with `TMUX` and `TMUX_PANE` unset and `TMUX_TMPDIR` on a short private per-task directory, so its bare `tmux`, including `tmux kill-server`, reaches only a private server.
Teardown, a forced secondmate retire that closes its workers, and a failed spawn that drops its record stop every server socketed in that directory by its exact path and remove it, touching it only while it is still private to this user.
A failed spawn whose launched worker's endpoint was left open, and a record-only stale-claim retirement, keep the directory and name it instead, since removing it under a live worker would send its bare `tmux` back to the default server.
A socket file there proves nothing on its own, since a hardlinked, renamed, or newline-named socket can answer for another server, so `bin/fm-private-tmux-lib.sh` stops a server only when its own reported socket path is inside the directory too.
A socket that answers for a server outside the directory, a socket it cannot inspect, other than one a stopped server left behind, or a server it cannot stop keeps the directory, so no live server loses its only reachable socket, and teardown then refuses and keeps the task record until that directory is cleaned up.
Teardown and relaunch both refuse, keeping the record and leaving the directory untouched, while a recorded private directory survives that is not where the home now places it, such as after the home moved.
A fresh spawn refuses its private directory while it still holds a socket from an earlier run of the task, and reuses it when empty.
Secondmates keep `TMUX`, because they place their own crew on the fleet server, and the behavior test runner gives every suite its own such directory.
Worker briefs require any server a worker starts with `-S` to use a socket under its `TMUX_TMPDIR`; a Herdr lab primary instead keeps the socket directory `bin/fm-lab-home.sh` owns, which its own cleanup trap stops.
Naming the fleet socket with `-S`, killing tmux by process name, or clearing the environment still reaches the fleet; the worker rules forbid the first two.
`tests/fm-worker-tmux-isolation.test.sh` is the regression.

### Shell command submission

Worktree entry and replacement-agent launch use the shell-submit owner in `bin/fm-tmux-lib.sh`, reached through `bin/backends/tmux.sh`.
`bin/fm-spawn.sh` supplies the execution proof: the exact leased working directory, an identifiable agent process, or a changed foreground command after launch.
The control plane still requires a running agent before reporting a successful relaunch.
When Enter is lost, retries require the complete owned command at the shell cursor; an exhausted submission stops dispatch and clears only identifiable owned input.
Unreadable or changed input is preserved and reported for inspection.
The real-shell regression and verified versions are recorded in [runtime backend verification](verification/runtime-backends-fork.md#shell-command-submission).

The away-mode daemon reuses the same owner for a digest an unconfirmed submit left in the primary's agent composer.
There, ownership means the shared classifier places the cursor in a composer holding input that is exactly the typed digest, and cleanup presses Ctrl+U once per wrapped row.

### Agent liveness probe

A target-existence check proves only that the pane exists, and it reads that from an exact inventory of the `=`-anchored session, never from `display-message` exiting 0, which tmux does for any target while a server runs.
The deeper tmux agent-liveness probe first verifies the same exact presence, then reads process names to distinguish a running harness from a bare idle shell.
It classifies recognized Claude, Codex, OpenCode, Pi, pi-signed, Grok, Kimi, Cursor, Muse, Rovo, and AGY process identities as `alive`, common shells as `dead`, an authoritatively absent window as `missing`, unreadable state as `unreadable`, and every other process as `ambiguous`.
The process-name vocabulary behind those verdicts is owned by `bin/fm-agent-process-lib.sh` and shared with the Herdr adapter, which proves a registered agent against the same names ([herdr-backend.md](herdr-backend.md) "Restart and liveness behavior").
Only `dead` and `missing` authorize recovery because a false dead result could launch a duplicate agent.

For positive attribution, the probe combines two independent name sources rather than making either one load-bearing.
`#{pane_current_command}` and the pane tty foreground process group's kernel `comm` values expose different name fields, and which one retains executable identity is platform-dependent.
The foreground probe also reads argv[0] so an exact harness install-path component can carry the verdict when the other fields expose a rewritten process name.
Either source naming a verified harness is enough for `alive`, because a false `dead` is the one verdict that can start a duplicate agent on a live worktree, while a readable foreground process group settles the negative verdicts.

Scoping the second source to the foreground process group rather than to the pane's descendants is deliberate: a harness-named process left running in the background of an otherwise idle pane must not read as an agent.
The same scoping covers multi-process launchers without a special case, so the Pi Launcher path is attributed through its `pi-signed` wrapper and `pi` engine even though its title is the exact foreground command `pi-launcher`.
Direct executable identities `pi`, `pi-signed`, and `Pi` remain accepted exactly, and similar or prefixed process names are not accepted through those exact Pi-family entries.
Muse is likewise anchored to the exact `muse` launcher identity or the installed `muse-bin-<version>` prefix, so unrelated names such as `musescore` and `amuse` remain ambiguous.
omp is anchored to the exact `omp` identity for the same reason, so `ompd` and `comp` remain ambiguous.
AGY and Devin are anchored to the exact `agy` and `devin` identities for the same reason, so unrelated names containing either fragment remain ambiguous.
Cursor is identified from its exact `cursor-agent` identity or versioned install tree in the foreground process path or structured argv[0]; a bare `node` or unrelated `agent` remains ambiguous.

The CI-enforced portable regression and opt-in real-harness drift guard follow the split owned by `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
Run the real-harness guard after any harness upgrade and before trusting refreshed evidence.

### Composer, busy state, and delivery

Agent liveness and composer safety are separate checks.
The tmux reader is a thin adapter over the fleet-wide classifier in `bin/fm-composer-lib.sh`: it contributes one styled full-pane capture, the `#{cursor_y}` cursor row, and foreground-process identity probes, and the shape containing the cursor - a complete bordered box (titled bottom borders tolerated), a bare agent-glyph row with its wrapped input, opencode's left bar, or Pi's identity-corroborated separator pair - normally decides the verdict.
Real text in an identified shape is pending, while only positively proven emptiness reads empty.
A blank or otherwise unidentified cursor row is `unknown` and every consumer defers, except that a foreground process proven to be Cursor is re-read cursorlessly because Cursor parks its terminal cursor below its footer.
That identity-gated exception preserves the strict container-proof rule for every other pane, so a modal dialog, a dead shell between stale rules, or a mid-redraw pane is never an injection target.
The shared classifier accepts a shell glyph as an empty agent composer only inside a bordered container.
A bare shell prompt is `unknown`, so away-mode escalation is never injected into a dead shell.

Busy state is not read from rendered text on this backend.
A task's busy, idle, unknown, or dead verdict comes from the semantic busy-state contract owned by `bin/fm-busy-lib.sh`; [architecture](architecture.md#busy-state-is-semantic-per-adapter) owns its boundaries.
The isolated rendered-tail busy fallbacks that remain are harness-scoped, so one adapter's output can never classify another's task.
The submit acknowledgement and away-mode supervisor-pane busy guard below still consult rendered output, but only to decide whether input can be delivered, never to decide recorded task state.
The supervisor guard selects only the detected primary harness's signature rather than a global union of vendor patterns.

`bin/fm-tmux-lib.sh` owns exact type-and-submit mechanics.
It types a message once and retries Enter only until the composer clears.
Only a proven empty composer is a positive delivery acknowledgement.
The away-mode daemon requires more, because a stale frame also reads empty: its `fm_tmux_proven_submit` sends Enter only after the composer shows the typed text unchanged and counts delivery only when that text is gone and a turn provably started.
Text left in established structure remains `pending`, text in ambiguous structure remains unproven, and unreadable or unsafe state remains unknown.
An ordinary local `fm-send.sh` text steer and every remote text steer no longer ride this verified submit at all: they become durable steering-inbox records plus best-effort constant doorbell lines (`bin/fm-task-inbox-lib.sh`).
The verdicts above are delivery-critical only for the local typed plane - harness-native invocations and explicit backend targets - where `fm-send.sh` still never retypes or assumes a confirmed submit for an unconfirmed verdict; its header owns the distinct delivered-unconfirmed exit status and operator response.

OpenCode 1.18.4 has one busy-queue exception.
While OpenCode is mid-turn, Enter queues the message but leaves its text visible until the turn completes.
After the normal retry budget, only structurally proven pending text in a provably busy pane is accepted as queued, while an idle pane remains `pending` as a genuine swallowed Enter.
Ambiguous pending text never receives the busy-queue conversion.
A second, baseline-gated conversion covers harnesses whose mid-turn screen the classifier cannot identify (Pi replaces its separated composer while working): when and only when the pane was idle before the text was typed, an idle-to-busy transition across the submit's own Enter confirms delivery, the same turn-started signal Herdr reads natively.
Without that baseline, an `unknown` verdict is preserved untouched, so a busy-looking pane can never convert an unread composer into a confirmation.
`tests/fm-tmux-submit-busy.test.sh` covers busy and idle panes with proven, ambiguous, and cleared composers.

## Limits and regression entry points

- tmux is the reference path and supports secondmate homes.

```sh
tests/fm-backend-tmux-smoke.test.sh
tests/fm-worker-tmux-isolation.test.sh
tests/fm-tmux-agent-liveness.test.sh
tests/fm-harness-liveness-drift-live-e2e.test.sh
tests/fm-composer-ghost.test.sh
tests/fm-kimi-harness.test.sh
tests/fm-cursor-harness.test.sh
tests/fm-muse-harness.test.sh
tests/fm-omp-harness.test.sh
tests/fm-tmux-submit-busy.test.sh
tests/fm-bootstrap.test.sh
```

[`verification/runtime-backends.md`](verification/runtime-backends.md#tmux) records the active foreground-process and submit evidence.
