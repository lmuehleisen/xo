# agy (Antigravity CLI)

Google's Antigravity CLI, with native worker Auto verified on agy 1.4.7.
The verification record below owns dated worker and primary results.
Verified for interactive primary, secondmate, crewmate, and scout work.
`../../../../../bin/fm-spawn.sh` owns the concrete launch and grant mechanics, through the fork-only `../../../../../bin/fm-agy-lib.sh` it sources.
agy updates itself often and without asking, so treat every version-scoped fact here as refreshable rather than settled, and re-run the live guard after an upgrade.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `agy` from `PATH`, resolved once and refused if absent. A single self-updating Go binary; the installed path is the real executable, not a launcher. |
| Launch | Native Auto starts interactively without the task prompt and verifies activation before delivering it. Manual and recorded legacy launches retain `-i`. Headless `-p` is never a worker route. |
| Directory grants | `--add-dir`, repeatable, and MANDATORY - see "The worktree grant" below. |
| Approvals | New Auto workers use verified native Auto plus deterministic task constraints. Manual retains native review. See "Approvals" below. |
| Busy state | `agy-hook`: PreInvocation opens; fullyIdle Stop closes. The worker binds its generation and main conversation; interruption emits no Stop and conservatively leaves busy. |
| Spawn start | Native Auto must prove activation and a real harmless result before receiving the brief, then prove a later worker invocation accepted the brief. `../../../../../bin/fm-agy-lib.sh` owns the gates and bounds. |
| Rendered tail | Not a state source, but the running turn's footer is the one ASCII busy token: `esc to cancel` while a turn runs, `? for shortcuts` when idle. The right of the footer names the active mode and model, e.g. `accept-edits · Gemini 3.8 Flash · medium`. |
| Turn end | Native Stop; see "Native hooks and primary integration" below. |
| Exit | `/exit` (alias `quit`), one Enter; prints `Resume with -c (or command below): agy --conversation=<uuid>`. |
| Interrupt | Single `Escape`, which prints `Interrupted · What should Antigravity CLI do instead?` and leaves the composer EMPTY, so no clear key is needed. |
| Resume | `agy -c` / `--continue` for the most recent conversation, or `agy --conversation=<uuid>` from the id printed at exit. |
| Models | `--model <model>`, checked against `agy models` before launch; effort is also encoded as a model-id suffix - see "Model and effort". |
| Effort | Firstmate emits `--effort low\|medium\|high` only; requested `xhigh` and `max` cap at `high`. See "Model and effort". |
| Marker | `JETSKI_APP_DATA_DIR=antigravity-cli` on tool subprocesses, alongside `ANTIGRAVITY_LS_VERSION=cli-<version>`, `ANTIGRAVITY_PROJECT_ID`, `ANTIGRAVITY_TRAJECTORY_ID`, `ANTIGRAVITY_LS_ADDRESS`, and `ANTIGRAVITY_SOURCE_METADATA`. agy does NOT set `GEMINI_CLI`. |
| Composer | `>` between solid rules and the native footer; `../../../../../bin/fm-composer-lib.sh` owns shape and placeholder classification. |
| Skill | `/<skill>`; typing `/` opens a filtered command menu and ONE Enter selects and submits. |
| Config | Global user settings at `~/.gemini/antigravity-cli/settings.json`; shared customization (hooks, skills, plugins, per-project settings) under `~/.gemini/config/`. Firstmate writes none of it. |

## Not the Gemini CLI

agy shares the `~/.gemini` configuration root with Google's separate `gemini` adapter and is a different tool with a different launch, approval model, and hook story.
Detection keeps them apart on their own markers: agy publishes `JETSKI_APP_DATA_DIR=antigravity-cli` and no `GEMINI_CLI`, and the value is the CLI's exact app-data directory, which the Antigravity IDE does not share (the IDE keeps state under `~/.gemini/antigravity`).
`JETSKI_APP_DATA_DIR` is tested before the `CLAUDECODE` line because whether agy scrubs an inherited Claude marker was NOT verified; ordering it first is correct either way, and the launch clears the foreign markers as defense in depth.

## The worktree grant

Every launch must pass `--add-dir` for the task worktree, and every granted path must be PHYSICALLY RESOLVED.

Both halves are load-bearing, and each fails in its own quiet way:

- With no grant, agy does not refuse and does not prompt.
  It writes into its own scratch directory (`~/.gemini/antigravity-cli/scratch`) while the model reports success, so the worker looks productive and the task's local copy never changes.
- With an unresolved grant whose parent is a symlink, agy resolves the path before testing it against the granted workspace, decides its own worktree is outside it, and parks on `Allow creation of this file? ... Reason: outside workspace`.

A resolved grant also keeps agy's workspace-trust dialog off the launch path entirely.
That dialog is not merely an extra keystroke: accepting it appends the path to `trustedWorkspaces` in the operator's own global settings, so a launch that raises it grows a file Firstmate does not own, once per task worktree, forever.
Trust is not inherited from a parent directory, so every fresh worktree would raise it.

`../../../../../bin/fm-spawn.sh` owns the resolved directory grants, including the worker hook directory.

## Approvals

The [worker permission setting](../../../../../docs/configuration.md#worker-permission-mode-configcrew-permissions) owns the `auto`/`manual` mapping.
New Auto workers use native sandboxing and command review with Firstmate's deterministic constraints.
Cold mode requests may fall back on agy 1.4.7, so neither the requested flag nor headless exit 0 proves activation.
[`fm-agy-native-lib.sh`](../../../../../bin/fm-agy-native-lib.sh) owns the supported warm transition and real-result launch proof.
The verified native route supports tmux and Herdr; other backends refuse it instead of silently selecting prompted review or bypass.
Manual remains an explicit native-review choice, and secondmates retain their separate primary integration.

[`fm-agy-permission-policy.sh`](../../../../../bin/fm-agy-permission-policy.sh) owns exact task roots, protected wiring/instructions, credential metadata, force/publication and brief-scope constraints.
Ordinary residue goes to the vendor's native reviewer without a Firstmate worker judge or reusable judge approval.
An outside-sandbox command can still be approved by native Auto; the deterministic constraints and the separate publication gate continue to apply.
Static command analysis cannot establish what every opaque program will do and is not an OS security boundary.

### Native pending decisions

The watcher turns a complete live command panel into a durable keyed decision only when it matches one exact outstanding hook input.
The policy owner's `approve`, `decline` and `resume` verbs own one-shot choices and cancellation reconciliation; read that script's header before resolving a native key.
Conversation-wide and persistent approval choices are never selected.
Unknown, clipped, changed or ambiguous panels remain unapproved and surface for inspection or guarded relaunch.

Live one-shot approval and decline/reconciliation were verified on agy 1.4.7 through Herdr.
Other model/backend combinations retain their separately recorded startup/tool coverage rather than a separate live No claim.
A decline is not settled from its footer: a new accepted Stop must prove reconciliation or the decision remains open.
The [verification record](../../../../../docs/verification/runtime-backends-fork.md#native-auto-workers) owns the measured limits and refresh commands.

### Recorded legacy tasks

New-worker `--agy-bypass`, `--no-agy-bypass` and `--agy-judge` flags are deprecated and refuse with a migration diagnostic.
Recorded legacy tasks retain their bypass/judge, accept-edits or manual posture on relaunch and keep their existing pending decisions until normal retirement.
Legacy judge selection, exact retry approvals and verdict caches remain implemented for those tasks.
Shared command-policy and judge-tier code also remains available to Devin and explicitly selected judges for other adapters.

### Prompted review

Manual review can require approval for file edits and shell commands, including status appends and inbox acknowledgments.
Recorded `accept-edits` launches approve in-workspace file edits but still require shell review.
The operator's allow rules can affect whether any particular native call prompts.
Firstmate does not change global settings or install persistent allow rules on the operator's behalf.
Headless permission denial may still exit 0 and is never accepted as worker-completion evidence.

## Native hooks and primary integration

The working hook schema is a named definition in `.agents/hooks.json`, with direct handlers for PreInvocation and Stop and matcher groups for PreToolUse and PostToolUse.
Hooks run from the customization directory containing that file, so the tracked primary registration addresses its executable relative to `.agents/`.
Local hooks in a separately granted directory also execute; `../../../../../bin/fm-agy-hook.sh` uses that capability to keep worker hooks in owned state without modifying project or global configuration.
The earlier no-hook conclusion is superseded by the positive live guards.
agy bundles the authoritative hook spec inside the binary itself: `strings -n 4 "$(command -v agy)"` from the `# Lifecycle Hooks` line yields the full `hooks.json` reference, byte-identical across 1.2.4 and 1.2.5 - but matcher names are the observed function names (`write_to_file`, `list_dir`), not the spec's documented step-type derivation.
`fm-agy-hook.sh install-worker` validates the merged `hooks.json` it writes, because agy does not load hooks from a file it cannot accept.
Worker hooks additionally carry a log-only observer: every tool call appends one line to `state/agy-permission-log.jsonl`, the request record agy workers otherwise lack for permission-posture review, and `../../../../../bin/fm-agy-hook.sh` owns the schema.

Primary support composes the existing startup nudge, shared pre-tool policies, and turn-end predicate through the native transport.
`../../../../../docs/sessionstart-nudge.md` owns the nudge tier and unverified compaction boundary.
`../../../../../docs/turnend-guard.md` owns Stop continuation, its executionNum loop bound, and the manual-interruption gap.
`../../../../../docs/supervision-protocols/agy.md` owns the verified native background-command wake protocol.
A completed native command re-enters the model automatically.
The session-lock owner recognizes the exact agy process, including the long-lived language-server process that parents hook and tool commands.

Worker hooks report through the semantic busy owner and emit turn-ended notifications only after an accepted fullyIdle Stop.
PreInvocation may repeat during a turn, and Stop with fullyIdle=false does not clear busy while background work remains.
Escape supplies no semantic cancellation acknowledgement; lifecycle control reports delivery and endpoint liveness only.
Missing or invalid hook data never manufactures idle.

Composer delivery needs the native footer or accept-edits mode cell as well as the rule pair and prompt.
An unstyled accept-edits hint, a manual-mode row with no identifying footer, and rendered busy-only acknowledgement of a queued Enter remain unproven; the adapter does not manufacture a successful delivery for them.
Native background-task observation uses the returned log with `view_file`; delegation-shaped native tools retain the shared pre-tool guard.

Unsupported surfaces remain explicit: headless primary supervision, native SessionStart and compaction refresh, and general semantic interrupt completion are not supported by this integration.
Native Auto decision handling retains the per-context verification limits above.
The optional quota helper now uses Agy's own catalog for the reviewed bucket bindings owned by `../../../../../bin/fm-quota-axi-lib.sh`; the agent-side quota procedure remains authoritative.
Runtime backend lifecycle guarantees remain those of each backend's capability table; native worker activation is verified on tmux and Herdr, with current evidence in the verification owner.
Remote secondmate launch and relaunch remain unsupported and are refused by `../../../../../bin/fm-remote-secondmate-control.sh`; that Herdr-only path is separate from the verified local secondmate integration.

## Model and effort

`../../../../../bin/fm-spawn.sh` passes the selected model without pinning a default.

Effort is published TWICE and the two forms conflict:

- `agy models` lists effort-suffixed ids: `gemini-3.8-flash-high`, `-medium`, `-low`.
- `--effort low|medium|high` is a separate flag.

Passing both refuses the launch: `--model gemini-3.8-flash-high --effort low` exits with `--model gemini-3.8-flash-high conflicts with --effort=low`.
The unsuffixed base id is not listed, but agy accepts it with `--effort` when the listing carries that base at that level; without `--effort`, or with a level the listing lacks for it, agy refuses.
The adapter therefore emits at most one: a model id already carrying a level wins and no effort flag is sent.

Before any endpoint exists, spawn checks the selected model against a bounded `agy models` listing: a listed id or a supported base-plus-level alias launches, anything else refuses with the concrete reason, and a listing that fails, is empty, or times out launches the model unvalidated with a notice.
`../../../../../bin/fm-spawn.sh`'s header owns the bound and the exact acceptance rule.

Firstmate retains its verified `xhigh` and `max` mapping onto `high`, per `../common/model-and-effort.md`.
agy 1.4.4's help advertises both native levels, but the adapter has not adopted them; its current catalog-backed launch validation still uses low, medium, and high.
The requested level stays recorded in task metadata.

## Interruptions Firstmate cannot suppress

agy periodically renders a feedback survey in the pane:

```
 How's the CLI experience so far? Help us improve:
 [1] Good  [2] Fine  [3] Bad  [0] Skip
```

It can appear mid-task and waits for a keypress (`0` skips).
The control is the global `showFeedbackSurvey` setting; agy exposes no launch flag or environment variable for it, so Firstmate cannot disable it per launch the way it disables Claude's feedback prompts.
Treat it as another reason an agy pane can sit idle-looking with work outstanding, and as something an operator can turn off in their own settings if it becomes a nuisance.

## Verification

`../../../../../docs/verification/runtime-backends.md` owns the dated evidence.
`tests/fm-agy-harness.test.sh` and `tests/fm-agy-native.test.sh` are the portable regressions.
The native worker guard is `tests/fm-agy-native-live-e2e.test.sh` (`FM_AGY_NATIVE_LIVE=1`).
The compatibility guards are `tests/fm-agy-signals-live-e2e.test.sh` (`FM_AGY_SIGNALS_LIVE=1`) and `tests/fm-agy-primary-live-e2e.test.sh` (`FM_AGY_PRIMARY_LIVE=1`).
