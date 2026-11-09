# Codex

Verified on 2026-06-11 with codex-cli 0.139.0 unless a fact gives a newer version.

## Operating facts

These command-line and terminal facts apply to pane-backed sessions; for T3 Code, read the [native lifecycle](../../../../../docs/t3code-backend.md#current-lifecycle-and-safety) and [provider-command limits](../../../../../docs/t3code-backend.md#active-limits).

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

## Reviewed worker sandbox errors

`fm-spawn.sh` adds the worker-facing retry guidance from [`fm_brief_codex_reviewed_sandbox`](../../../../../bin/fm-dod-lib.sh) to Codex ship/scout briefs only when the effective permission mode is auto.

## Task launch opt-ins

Verified on 2026-10-05 with codex-cli 0.160.0.
`codex debug models --bundled` returns its shipped model catalog without loading user or project configuration.
The separate `codex --model gpt-6-astra -c 'model_reasoning_effort="ultra"' --disable hooks debug prompt-input` probe loads configuration and renders prompt input without a model turn; malformed configuration refuses.
Ultra is advertised in `supported_reasoning_levels` for GPT-6 Astra, GPT-6.1 Sol, GPT-6 Sol, GPT-5.6 Sol, and GPT-5.6 Terra; it is absent for the Luna variants.
Discover support from the installed CLI rather than treating that list as a permanent model allowlist.

`/goal <objective>` is a built-in slash command backed by the `goals` feature, not a `$goal` skill or dedicated launch flag.
[`Using Goals in Codex`](https://developers.openai.com/cookbook/examples/codex/using_goals_in_codex) documents its thread-scoped objective and lifecycle.
`codex --enable goals features list` confirms the feature is available.
The initial positional prompt bypasses the native slash parser on 0.160.0: a trivial `/goal` initial prompt produced a response but `/goal` status subsequently reported no goal set.
The same command typed after startup reported `Goal active Objective:` and completed with `Goal achieved`.
Therefore an opted-in worker starts without an ordinary initial prompt and receives its native goal as the first input through the existing backend composer and submit path.
The goal objective carries the canonical launch-brief envelope and current worker role before the task directive; [`fm-spawn.sh`](../../../../../bin/fm-spawn.sh) owns that carrier and its combined length bound.
The current live composer uses `»`, while transcript prompts retain `›`; the shared composer classifier recognizes both.

[`fm-spawn.sh`](../../../../../bin/fm-spawn.sh) owns the explicit flags, quota posture, condition bounds, brief pointer, refusal behavior, and submission mechanics.
Refresh live evidence with [`fm-worker-launch-optins-live-e2e.test.sh`](../../../../../tests/fm-worker-launch-optins-live-e2e.test.sh); dated results belong in [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#task-launch-opt-ins).

## Hook trust

A second dialog, "Hooks need review - N hooks are new or changed", appears whenever the machine's `~/.codex/hooks.json` or a project's own `.codex/hooks.json` carries a hook Codex has not persisted trust for.
It is unanswerable rather than merely inconvenient: its selection starts on "Review hooks", which is neither trusting nor declining, and Firstmate's key plane carries Enter, Escape and Ctrl-C with no arrow navigation.
Writing Codex's own trust store to pre-accept it would manufacture an operator consent that was never given.
So pane-backed crewmate and scout launches request that Codex disable its hook layer (`bin/fm-spawn.sh`'s launch template owns the flag), which is the opposite of `--dangerously-bypass-hook-trust` - that flag RUNS the untrusted hooks.
A managed policy can override the requested disablement, so a worker can still encounter a policy-provided hook or its review; Firstmate does not modify the operator's Codex settings to bypass either outcome.
A crewmate loses nothing: its turn-end signal is the `-c notify=` program on the same launch, and the Firstmate hooks in a project's `.codex/hooks.json` are primary-session infrastructure that stands down in a child worktree.
A secondmate is a primary in its own home and keeps its hooks, so an unanswerable modal there is still possible and is the operator's own hook review to settle.

## Skill popup

A `$<skill>` invocation opens a `$` autocomplete popup.
Submitting too fast lets the popup swallow Enter, so the invocation never lands.
For pane-backed sessions, `../../../bin/fm-send.sh` gives a leading `$` a 1.2-second settle before the first Enter only when the exact task metadata records `harness=codex`, with the target backend's submit retry as the safety net.
That scope is load-bearing because a leading `$` commonly starts ordinary text such as `$5/month` or `$HOME`.
An explicit `session:window` target has no metadata, so its harness is unknown and uses the non-Codex fast path.
This is why `$no-mistakes` reaches a Codex worker instead of being consumed by the popup.

## Primary integration

[`turnend-guard.md`](../../../../../docs/turnend-guard.md#harness-integrations) owns the primary Stop wrapper's scoping, response streams, and bounded continuation; [runtime backend verification](../../../../../docs/verification/runtime-backends.md#stop-response-parsing) owns the current parser evidence.

Verified on 2026-07-08 with codex-cli 0.142.1: Codex runs the Stop command with process PWD set to the hook-loaded project root, while no `CODEX_PROJECT_DIR`, `CODEX_WORKSPACE_ROOT`, or `CODEX_CWD` root variable is set.

Codex CLI 0.163.0 supports the native asynchronous Stop park registered by `bin/fm-codex-stop-park.sh` in a home that opts in with [`config/codex-stop-park`](../../../../../docs/configuration.md#codex-native-stop-park-configcodex-stop-park), verified in an isolated real CLI lab on 2026-10-19.
The hook waits outside the model and delivers actionable wakes with `codex queue --thread`, including in embedded mode without a shared app-server daemon.
The script owns version and native-session selection; [`codex.md`](../../../../../docs/supervision-protocols/codex.md) owns the operating protocol and failure fallback.
Homes without the opt-in, unverified versions, and sessions without the native registration keep [`codex-checkpoint.md`](../../../../../docs/supervision-protocols/codex-checkpoint.md), the unchanged bounded foreground protocol.
The [supervision host](../../../../../docs/supervision-host.md) retains its existing posture decisions on both paths.
Codex's PreToolUse watcher-arm seatbelt blocks directly through its project hook.
