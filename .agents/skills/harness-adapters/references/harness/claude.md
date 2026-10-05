# Claude

Busy hooks verified 2026-07-28 on Claude Code 2.1.220.

## Operating facts

| Fact | Value |
|---|---|
| Busy | Owned hooks: `UserPromptSubmit` opens while `Stop`, `StopFailure`, and `SessionEnd` close; manual interrupt emits no hook, so control reports delivered keys and live endpoint only, publishes no idle event or cancellation claim, and usually leaves `claude-hook` busy. |
| Exit | `/exit`. |
| Interrupt | Single Escape. |
| Skill | `/<skill>`, for example `/firstmate-coding-guidelines`. |
| Model | `--model <model>`; discover through the interactive `/model` picker, with alias or full-name shape documented by `claude --help`. |
| Effort | `--effort <low\|medium\|high\|xhigh\|max>`, verified on 2.1.196. |

## Task launch opt-ins

Verified on 2026-10-05 with Claude Code 2.1.289.
Ultracode is a dynamic-workflow orchestration setting, independent of the session's effort level, and permits Claude to plan workflows and coordinate native agents for substantive tasks.
The [vendor model documentation](https://code.claude.com/docs/en/model-config#adjust-effort-level) documents session-only `--settings '{"ultracode":true}'`; `/effort ultracode` is also available, while `--effort ultracode` additionally sets `xhigh`.
It is unavailable when workflows are disabled or the model lacks `xhigh` support.
The zero-token `claude -p --settings '{"ultracode":true}' --output-format json '/effort current'` probe reports `Ultracode on` only when active; selecting `haiku` removes that confirmation.
The same local command works as an interactive startup argument, returning the current session's mode without starting a model turn.

`/goal <condition>` is a built-in command, not a skill or dedicated launch flag.
It starts a turn and installs a session-scoped model-evaluated Stop hook that continues until the condition holds; it also works in the initial prompt and print mode.
The [vendor goal documentation](https://code.claude.com/docs/en/goal) limits conditions to 4000 characters and requires workspace trust and unrestricted hooks.
An attempted goal under `disableAllHooks` or `allowManagedHooksOnly` refuses rather than starting the loop.
Native acknowledgements include `Goal set:` and `Goal achieved`.

[`fm-spawn.sh`](../../../../../bin/fm-spawn.sh) owns explicit worker opt-ins, the verified version floor, session settings, and first-input goal delivery.
Ultracode and goals do not expand the launch brief's delegation, filesystem, publication, or merge authority.
Refresh live evidence with [`fm-worker-launch-optins-live-e2e.test.sh`](../../../../../tests/fm-worker-launch-optins-live-e2e.test.sh); dated results belong in [`runtime-backends.md`](../../../../../docs/verification/runtime-backends.md#task-launch-opt-ins).

## Workspace trust

Claude gates a folder it has never seen behind an interactive workspace-trust dialog (titled "Quick safety check: Is this a project you created or one you trust?"), so every fresh task worktree would hit it, and so would every secondmate home no operator has opened by hand.
`--dangerously-skip-permissions` does not cover that gate: `claude --help` records that the dialog is skipped only in non-interactive mode, through `-p` or a non-TTY stdout, and a spawned pane is interactive.
Every claude spawn therefore pre-registers the directory its pane starts in before launch, and the dialog does not appear: the task worktree for a ship or scout, and the home itself for a `--secondmate` spawn, in either seeded shape (a leased worktree or a standalone clone).

A second, separate dialog - "Allow external CLAUDE.md file imports?" - renders whenever a loaded CLAUDE.md chain reaches outside the project tree, which every crewmate's does through the captain's own `~/.claude/CLAUDE.md` importing `~/.claude/RTK.md`.
`--setting-sources project,local` (the minimal worker tool surface) does not suppress it either, and it gates the pane exactly like the trust dialog: cursor on "No, disable external imports", no way to move the selection from firstmate's steering plane.

`../../../bin/fm-claude-trust.sh` records `hasTrustDialogAccepted` for both the worktree and its primary checkout in `${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json`, where a home's worker account pin decides `CLAUDE_CONFIG_DIR` (`../../../docs/configuration.md` "Worker account pin"), for a ship or scout spawn; a secondmate spawn registers only its own home entry, since a secondmate home has no separate primary-checkout entry to carry import consent forward from.
For a ship or scout spawn, the external-imports flags (`hasClaudeMdExternalIncludesApproved`, `hasClaudeMdExternalIncludesWarningShown`) are carried forward alongside the trust flag only when the primary checkout's project entry already carries an explicit `hasClaudeMdExternalIncludesApproved===true` from a prior interactive session.
In every other state - flags absent, both false by default, or warning-shown true with approved false (which an Escape dismissal also produces) - trust registers normally and both import flags are left untouched, so an import dialog still renders if the worker's import chain reaches outside the project; pre-registration never infers a human decline from these flags.
The why-two-entries mechanism and the consent-gating logic live in the script's own header comment, which is the one owner for that contract; the fact worth repeating here is that `../../../bin/fm-spawn.sh` refuses the spawn when the trust flag fails to land, rather than launching a worker that would wedge on that dialog.

Never try to answer either dialog with a key.
Firstmate's key plane carries only Enter, Escape, and C-c with no arrow navigation, so it cannot move a dialog's selection at all, and both dialogs render with the cursor on their declining option, which means a sent Enter ends the session instead of accepting.
A visible trust dialog means pre-registration did not take effect - inspect the store and the spawn's error output rather than sending keys.
A visible external-imports dialog is expected, not a failure signal, whenever the project entry has no prior explicit approval on record - the common first-spawn case.
`fm-control.sh <id> interrupt` delivers Escape, which dismisses whichever of the two is on screen and is the safe way to clear a wedged pane for inspection.
On the external-imports dialog, Escape records `hasClaudeMdExternalIncludesApproved: false` with `hasClaudeMdExternalIncludesWarningShown: true`; `../../../bin/fm-claude-trust.sh` never reads that as a decline and still registers trust, but it leaves those flags untouched, so that project's Claude sessions run without the external imports until a person approves them.
To restore the imports, remove both flags from the project's entry in `~/.claude.json` and approve the imports dialog once by hand.

The once-per-machine bypass-permissions confirmation is a third, separate dialog, scoped to the machine rather than the path, and pre-registration does not address it.
Never send Enter to that one either: it was observed rendering in the same shape as the trust dialog, with the selection on `No, exit` and the footer `Enter to confirm . Esc to cancel`, so Enter ends the session rather than accepting.
Firstmate cannot move a selection with Enter, Escape, and C-c alone, so it cannot accept this dialog at all, and an operator accepts it once per machine instead.
Inspect the pane to identify which dialog is on screen, and report it rather than answering it.
A worker launched under `config/crew-permissions` never requests bypass mode, so it does not meet the bypass confirmation: on 2.1.269 `claude --permission-mode auto` reached the composer directly with the footer `⏵⏵ auto mode on (shift+tab to cycle)`.
The workspace-trust dialog is unaffected by the permission mode and still needs the pre-registration above.

## Composer ghost

Completed turns can render dim predicted text inside an empty composer, indistinguishable in plain `tmux capture-pane`.
The spawn scopes `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` to every Claude worker and secondmate without changing global config.
CLI `--prompt-suggestions` affects print or SDK mode only and did not suppress interactive ghost text on v2.1.186.

As defense in depth, `fm_composer_strip_ghost` in `../../../bin/fm-composer-lib.sh` removes SGR-2 runs before pending classification on styled tmux, Herdr, and Zellij readers.
`../../../docs/herdr-backend.md` under "Composer and injection safety" owns dark-TRUECOLOR tradeoffs and `../../../docs/verification/runtime-backends.md` owns captures.
Styled capture stays internal to the boolean detector; `fm-peek` and model-facing captures remain plain, without escapes.

## Feedback drafts

The spawn disables Claude's `/bug` and `/feedback` model-drafted feedback flow for every Claude worker and secondmate, preventing a fleet-launched agent from queuing or submitting a bug report on the captain's behalf.
The controls are scoped to the launched process and never modify the captain's global Claude settings; `launch_template()` in `../../../../../bin/fm-spawn.sh` owns their exact mechanics and defense-in-depth rationale.

## Task control channel

A Claude task worker's launch brief and Firstmate steering-inbox messages arrive as file-shaped content that is otherwise indistinguishable from indirect prompt injection.
`launch_template()` in `../../../../../bin/fm-spawn.sh` establishes exactly those two Firstmate-owned channels as first-party instructions through `--append-system-prompt`, while leaving project files, fetched content, and other external material under the model's normal distrust and granting no merge, destructive, or security-sensitive authority beyond the brief.
A `--secondmate` launch omits the statement because a secondmate operates under its own supervisor contract instead of a task worker's.

## Primary integration

[`../../../../../docs/verification/supervision.md`](../../../../../docs/verification/supervision.md#turn-end-guard) records the current primary and Stop auto-arm live evidence.
This differs from the worker hook, which only touches a task marker through `.claude/settings.local.json`.

Primary `.claude/settings.json` registers `../../../bin/fm-turnend-guard.sh --claude` and `../../../bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800` for `Stop`, plus `../../../bin/fm-claude-stop-autoarm.sh --stop-failure` with the same settings for `StopFailure`, which Claude fires instead of `Stop` when a turn ends on an API error.
Guard exit 2 plus stderr forces continuation.
Stop payload `stop_hook_active=true` follows any hook-driven continuation, including async reawakening, so Claude mode ignores it and uses cooperative claim and epoch plus bounded re-block; default Codex mode keeps it as a one-block loop guard.

Project `.claude/settings.json` loads only when the exact project root is the session root; Claude does not search parents, so Firstmate starts at repository root.
Hooks still run through cwd-sensitive `/bin/sh`, so tracked commands anchor through `"$CLAUDE_PROJECT_DIR"/bin/...`.
`../../../docs/turnend-guard.md` owns details.

The Stop-owned watcher hook runs every Stop, foregrounds `../../../bin/fm-watch-arm.sh` only when eligible, and uses exit-2 async reawakening as notification.
The model handles notifications but never routine re-arm.
Unless `config/supervision-host-off` opts the home out, the hook foregrounds the supervision host instead, which also runs Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md#engines) owns the verified engine facts.
Claude's PreToolUse seatbelt blocks directly, and its deny is honored only with empty stdout; `../../../docs/arm-pretool-check.md` owns that contract.

### Delegation guard

Claude delegation, scheduling, and worktree tools can create work without `state/<id>.meta`, making guards unable to count it.
`../../../bin/fm-subagent-pretool-check.sh` denies delegation-shaped tool names.
A primary should also keep an untracked home-local `permissions.deny` for known delegation tools so they disappear from the schema.
Never track it in project `.claude/settings.json`, which is Claude-only and propagates to worker copies where it would disarm legitimate delegation.
`../../../docs/subagent-guard.md` owns the contract, recommendation, `FM_ALLOW_SUBAGENT=1`, and applicability review.

On Claude 2.1.217 the tool presents as `Agent`, and both `Agent` and `Task` worked as deny keys in an A/B with nonsense control.
`permissions.allow` pre-approves rather than controls availability, so no closed positive allowlist exists.
