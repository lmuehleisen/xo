# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | Unknown until a semantic source is live-verified: the app-server turn lifecycle is unreachable for a pane worker, and project lifecycle hooks did not fire for a Firstmate-launched worker. |
| Exit command | `/quit`; its slash popup needs about one second between text and Enter, which the shared submit path used by the control plane handles. |
| Interrupt | Single Escape. |
| Skill invocation | `$<skill>`, for example `$no-mistakes`; `/<skill>` is Claude-only and Codex rejects it as "Unrecognized command". |
| Resume | `codex resume <session-id>`, using the id printed on quit. |
| Model flag | `--model <model>`. |
| Effort flag | `-c 'model_reasoning_effort="<low\|medium\|high\|xhigh\|max\|ultra>"'`; `max` uses the installed model cache, preserving the Luna-only fallback when unavailable. Ultra uses the refusal contract in `bin/fm-harness.sh validate-native-effort`; omitted ordinary effort is recorded and warned at spawn. |
| Model discovery | Open the current interactive session's `/model` picker. |
| Marker | None; identity comes from ancestry, and `../../../bin/fm-harness.sh` is what keeps a retained foreign `CLAUDECODE` from renaming it. Verified on 2026-09-01 with codex-cli 0.152.0: the pane process is the `node` npm shim and the native `codex` binary runs as its foreground child, so a tool subprocess reaches the native name directly while the shim itself is identified from its script path. |

A directory trust dialog appears on the first run for a repository root: "Do you trust the contents of this directory?"
Accept it with Enter and verify the instructions begin processing.
The decision persists for the repository, so later worktrees of the same project skip it.

## Task launch opt-ins

Verified on 2026-10-05 with codex-cli 0.160.0.
`codex -c 'model_reasoning_effort="ultra"' debug models --bundled` both validates the installed configuration parser and returns its shipped model catalog.
Ultra is advertised in `supported_reasoning_levels` for GPT-6 Astra, GPT-6.1 Sol, GPT-6 Sol, GPT-5.6 Sol, and GPT-5.6 Terra; it is absent for the Luna variants.
Discover support from the installed CLI rather than treating that list as a permanent model allowlist.

`/goal <objective>` is a built-in slash command backed by the `goals` feature, not a `$goal` skill or dedicated launch flag.
[`Using Goals in Codex`](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex) documents its thread-scoped objective and lifecycle.
`codex --enable goals features list` confirms the feature is available.
The initial positional prompt bypasses the native slash parser on 0.160.0: a trivial `/goal` initial prompt produced a response but `/goal` status subsequently reported no goal set.
The same command typed after startup reported `Goal active Objective:` and completed with `Goal achieved`.
Therefore an opted-in worker starts without an ordinary initial prompt and receives its native goal as the first input through the existing backend composer and submit path.
The current live composer uses `»`, while transcript prompts retain `›`; the shared composer classifier recognizes both.

[`fm-spawn.sh`](../../../../../bin/fm-spawn.sh) owns the explicit flags, quota posture, condition bounds, brief pointer, refusal behavior, and submission mechanics.
Refresh live evidence with [`fm-worker-launch-optins-live-e2e.test.sh`](../../../../../tests/fm-worker-launch-optins-live-e2e.test.sh); dated results belong in [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#task-launch-opt-ins).

## Hook trust

A second dialog, "Hooks need review - N hooks are new or changed", appears whenever the machine's `~/.codex/hooks.json` or a project's own `.codex/hooks.json` carries a hook Codex has not persisted trust for.
It is unanswerable rather than merely inconvenient: its selection starts on "Review hooks", which is neither trusting nor declining, and Firstmate's key plane carries Enter, Escape and Ctrl-C with no arrow navigation.
Writing Codex's own trust store to pre-accept it would manufacture an operator consent that was never given.
So crewmate and scout launches disable Codex's hook layer outright (`bin/fm-spawn.sh`'s launch template owns the flag), which is the opposite of `--dangerously-bypass-hook-trust` - that flag RUNS the untrusted hooks.
A crewmate loses nothing: its turn-end signal is the `-c notify=` program on the same launch, and the Firstmate hooks in a project's `.codex/hooks.json` are primary-session infrastructure that stands down in a child worktree.
A secondmate is a primary in its own home and keeps its hooks, so an unanswerable modal there is still possible and is the operator's own hook review to settle.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
`../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

The primary integration was verified on 2026-07-08 with codex-cli 0.142.1.
The firstmate primary's `.codex/hooks.json` registers a Stop hook that pipes Codex's payload to `../../../bin/fm-turnend-guard.sh`.
Codex Stop hooks preserve exit status 2 and stderr to block, and expose `stop_hook_active` for the same one-block loop safety used by the guard's default mode.

The Stop payload includes `cwd`, but the tracked hook does not use it to choose the guard executable.
Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.
The tracked hook anchors to `pwd -P`, verifies that root is Firstmate-shaped and hook-bearing, and then invokes the guard with the original payload.

Codex's primary watcher protocol is `../../../bin/fm-watch-checkpoint.sh --seconds "${FM_CODEX_WATCH_CHECKPOINT:-180}"`, not `../../../bin/fm-watch-arm.sh`.
Codex cannot reason while a foreground tool call is running, so the checkpoint is deliberately foreground and bounded to return control regularly for user messages and queued notifications.
In a home with `config/supervision-host` and no `config/supervision-host-off` the checkpoint runs the supervision host instead of the watcher, with Claude's print mode as its headless engine, and holds for at least an hour while away; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host and that bound.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
