# Fork runtime backend verification

Audience: maintainer verification.

This record holds runtime evidence that is specific to this fork and kept out of the shared [runtime-backends.md](runtime-backends.md) record upstream also edits.
Each section keeps the heading it carried there, under that record's parent heading where it had one.

## Reviewed Claude and Codex worker launches

On 2026-09-09, Claude Code 2.1.236 and codex-cli 0.153.1 accepted the permission and additional-directory arguments below through their real CLI parsers.
Each command exited 0 and printed its normal help; no provider turn or worker was started.

```sh
claude --permission-mode auto --add-dir /tmp --add-dir /private/tmp --help
claude --permission-mode manual --add-dir /tmp --add-dir /private/tmp --help
codex --approve-for-me --add-dir /tmp --add-dir /private/tmp --help
codex --sandbox workspace-write --ask-for-approval on-request -c approvals_reviewer=user --add-dir /tmp --help
```

The Claude launch carries its flag and both grants through the `__CLAUDEPERMFLAG__` seam, ahead of `--settings`, with no `--` before the positional brief.
On 2026-09-15, Claude Code 2.1.273 on macOS on Apple silicon parsed that order in one short print-mode turn, listing both variadic grants and still receiving the positional prompt.
The grant directories sit outside the working directory, because a grant nested under it is folded into the working directory and not listed separately:

```sh
mkdir -p /tmp/fm-claude-verify/state /tmp/fm-claude-verify/brief /tmp/fm-claude-verify-cwd
cd /tmp/fm-claude-verify-cwd
STATE=/tmp/fm-claude-verify/state
BRIEF_DIR=/tmp/fm-claude-verify/brief
claude -p --permission-mode auto --add-dir "$STATE" --add-dir "$BRIEF_DIR" \
  --settings '{"feedbackDrafts":"off","attribution":{"commit":"","pr":"","sessionUrl":false}}' \
  --model haiku --effort low \
  "Without using any tools, list every additional working directory path from your environment context, one per line, then a final line PROMPT_RECEIVED."
echo "exit=$?"
```

Captured output:

```text
/tmp/fm-claude-verify-cwd
/tmp/fm-claude-verify/state
/tmp/fm-claude-verify/brief
PROMPT_RECEIVED
exit=0
```

The first line is the working directory, which the model included alongside the two grants; the wording of a model reply can vary between runs, but both grant paths and `PROMPT_RECEIVED` must appear.

`tests/fm-spawn-dispatch-profile.test.sh` exercises generated worker commands, default and explicit harness selection, auto/manual modes, reporting-directory grants, and rejection of invalid permission settings through the real spawn entry point with isolated Git worktrees and fake endpoints.
`tests/fm-secondmate-harness.test.sh` and `tests/fm-backend-orca.test.sh` cover the other affected launch shapes.
These are argument and routing checks, not evidence of account eligibility, classifier decisions, hook delivery, or end-to-end supervised operation in Auto mode.
Before relying on unattended operation, run an authenticated disposable task through the intended primary and worker harness, verify tests and status delivery, then verify that a denied operation is surfaced without falling back to bypass.
The operator contract is in [configuration](../configuration.md#worker-permission-mode-configcrew-permissions); the executable launch owner is `bin/fm-spawn.sh`.

## Remote-less local-only dispatch

`tests/fm-spawn-pool-base-freshen.test.sh` drives the real spawn entry point with real disposable Git repositories and fake terminal endpoints.
It covers remote-less local `main` and `master` advancing beyond a stale pool, selection independent of the primary's feature branch, and preservation of the no-remote configuration.
Refusal cases cover dirty files, clean unlanded commits, unknown local defaults, unrelated checkouts, PR delivery without origin, a non-origin remote, and an unreachable origin even with local-only delivery.
The same suite exercises existing remote default refresh and submodule safeguards.
These checks establish launch preparation and metadata publication, not authenticated worker execution or supervision; a real disposable worker remains the end-to-end acceptance test.
The operator boundary is in [configuration](../configuration.md#remote-less-local-projects).

## Treehouse task leases and collided-claim recovery

On 2026-09-10, Treehouse v2.0.0 (build revision `68fa3d2556542add76bf80255787b8625a5041a6`) passed the real-provider lease regression in `tests/fm-spawn-worktree-settle.test.sh`.
In an isolated local pool, a process-free leased slot kept its clean detached unlanded commit and file while a second lease acquired a different slot.
The same suite drives the real spawn entry point with fake providers and endpoints to verify refusal before acquisition for an unleased recorded claim, cross-home project-lock contention, and preservation of a colliding lease without automatic return.
It also refuses a recorded pool slot whose project identity cannot be established; `tests/fm-secondmate-harness.test.sh` checks that an unrelated non-Git secondmate home does not block an ordinary crew spawn.
The generated lease command is also exercised in a real private tmux pane: the child enters the worktree, and exiting it leaves the outer project shell alive for guarded backend cleanup.
On 2026-09-26, `tests/fm-spawn-prelaunch-rollback.test.sh` passed on macOS on Apple silicon with tmux 3.7c on a private `-S` socket and the fixture treehouse from `tests/lib.sh`.
It drives the real spawn entry point into two refusals after the slot was leased and before launch delivery - an `--agy-bypass` scout over a tracked `.agents/hooks.json`, and a non-private staged-launch directory after the task record was published - and checks that each closes its window, returns the slot with `treehouse return --force`, and leaves no lease receipt, busy-state, task record, or agy wiring behind.
A third refusal over a slot holding a file the spawn did not write closes the window but keeps the lease, its receipt, and the file.
The same suite spawns a raw agy launch command, which no longer aborts on an unresolved agy executable.

```
$ bash tests/fm-spawn-prelaunch-rollback.test.sh
ok - fm-spawn.sh: an agy bypass refusal after leasing returns the slot and closes its window
ok - fm-spawn.sh: a refusal after the record was published but before launch rolls everything back
ok - fm-spawn.sh: a refused spawn keeps the lease on a slot holding content it did not write
ok - fm-spawn.sh: a raw agy launch command spawns without resolving the agy executable
```

The same day, `tests/fm-spawn-prelaunch-lease-return.test.sh` passed on the same host with fake Herdr, Zellij, and cmux CLIs in front of the real adapters and no backend server.
It runs that abort cleanup in the exit handler's order and checks when the slot may be returned.
A Herdr pane read answering an unknown error or failing silently keeps the lease and receipt, a structured `pane_not_found` returns the slot, and a failed Zellij or cmux read keeps the lease.
A wiring path already in the slot when it was leased keeps the lease and the file, and a provisional task record that could not be rolled back keeps the lease.

```
$ bash tests/fm-spawn-prelaunch-lease-return.test.sh
ok - fm-spawn.sh: a Herdr pane whose presence reads as unknown keeps the leased slot
ok - fm-spawn.sh: a Herdr pane read that fails without a structured answer keeps the leased slot
ok - fm-spawn.sh: a Herdr pane proven gone returns a slot holding only the wiring written after leasing
ok - fm-spawn.sh: a zellij endpoint whose existence read fails keeps the leased slot
ok - fm-spawn.sh: a cmux endpoint whose existence read fails keeps the leased slot
ok - fm-spawn.sh: a wiring path already in the slot when leased keeps the lease
ok - fm-spawn.sh: a task record that could not be rolled back keeps the lease
```

`bin/fm-spawn.sh` owns acquisition, receipt, and pre-launch rollback mechanics; `bin/fm-worktree-claims-lib.sh` owns the shared local-home claim inventory.

`tests/fm-teardown-endpoint-safety.test.sh` verifies record-only recovery without reset, return, branch deletion, or endpoint termination, followed by ordinary cleanup of the remaining owner.
It refuses live or locked claimants, uncommitted work, unlanded work on either named branch, detached ownership, and a force combination.
Its squash-content case proves the stale claimant's own branch landed without using the current owner's checkout as evidence.
`tests/fm-control-relaunch.test.sh` covers reuse of the task's own worktree and refusal of another claimant.
`bin/fm-teardown.sh` owns the recovery option and its safety boundary.

Refresh these checks with:

```sh
bin/fm-test-run.sh tests/fm-spawn-worktree-settle.test.sh tests/fm-teardown-endpoint-safety.test.sh tests/fm-control-relaunch.test.sh
```

Acquisition is shared by tmux, Herdr, zellij, and cmux; Orca supplies its own worktree, and secondmate-home lease provisioning is separate.
These tests do not establish live Herdr, zellij, or cmux operation, or authenticated worker execution.
The required Herdr CI lane exercises real projected spawn and abort cleanup in `tests/fm-backend-herdr-presentation-e2e.test.sh`, whose serialization audit observes confirmed pane removal across explicit-close and idle-shell termination paths.
Its restart cases also require recovery to keep the same recorded worktree, committed and uncommitted work, and zero Treehouse calls while replacing the exact stopped endpoint.
Recovery uses the existing backend classifier and refuses an unverified result.

## tmux

### Shell command submission

Verified on 2026-09-23 with tmux 3.7c, Bash 3.2.57, and Zsh 5.9 on macOS.
The existing private-socket smoke fixture drops the first Enter while leaving the shell, cwd, and process reads real.
A shell builtin also delays the execution postcondition after an accepted Enter, proving that a blank cursor row receives no retry keys.
Its wrapped command also exercises Zsh's explicit row redraws, which need normalization beyond tmux's automatic-wrap joining.
Run:

```sh
bin/fm-test-run.sh tests/fm-backend-tmux-smoke.test.sh
```

Relevant output:

```text
ok - real /bin/bash cwd confirms shell submit after first Enter is dropped
ok - real /bin/bash process confirms wrapped launch after first Enter is dropped
ok - real /bin/bash accepted Enter waits on a blank cursor without retrying
ok - real /bin/bash exhausted submit clears its owned input
ok - real /bin/zsh cwd confirms shell submit after first Enter is dropped
ok - real /bin/zsh process confirms wrapped launch after first Enter is dropped
ok - real /bin/zsh accepted Enter waits on a blank cursor without retrying
ok - real /bin/zsh exhausted submit clears its owned input
```

`tests/fm-control-relaunch.test.sh` and `tests/fm-spawn-worktree-settle.test.sh` exercise both complete sender paths with dropped-Enter endpoints, including bounded failure, no retyping, input cleanup, retained relaunch work, and a spawn whose cd never landed returning its leased slot.
`tests/fm-tmux-submit-busy.test.sh` verifies that transcript-only matches and unreadable input receive no retry or cleanup keys.
The real-shell test uses a `sleep` process as its launch postcondition; it does not establish authenticated agent startup or reproduce a concurrent-load trigger.
Relaunch reuses the existing agent-liveness classifier and its live-harness evidence in [runtime-backends.md](runtime-backends.md#agent-liveness-name-sources).
The operator boundary is [tmux shell command submission](../tmux-backend.md#shell-command-submission).

## Claude Code operational input

Claude Code 2.1.277 added removal of invisible Unicode formatting characters from every submitted prompt, and U+2063 is always removed.
An interactive submit that removed a character holds the cleaned text with `Removed 1 invisible character · review and press Enter to send`, and the next Enter sends it; the argv launch prompt is cleaned and sent at once.
A Firstmate operational envelope therefore reaches a Claude transcript as the same `FIRSTMATE_OP: v1 <kind>: <body>` header without its leading mark, and `bin/fm-operational-input.sh` parses that exact mark-less header as the same current kind.
The daemon's ordinary Enter retry sends the cleaned text, so delivery is still confirmed.

Verified on 2026-09-21 on Linux with tmux 3.6 on a private socket, against Claude Code 2.1.276 and 2.1.278 side by side:

```sh
FM_CLAUDE_CALM_LIVE_E2E=1 tests/fm-calm-claude-mod-live-e2e.test.sh
```

Observed output:

```text
ok - Claude Code 2.1.278 (Claude Code) with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool and operational rows draw at zero height (the daemon-injected away-mode escalation arriving without its U+2063 mark and classifying as away-supervisor), /calm restores and re-hides them while persisting the shared preference
ok - Claude Code 2.1.276 (Claude Code) with the flag on: the mod auto-loads from .claude/skills, /calm exists, the sailboat replaces and moves in the working row, tool and operational rows draw at zero height (the daemon-injected away-mode escalation arriving with its U+2063 mark and classifying as away-supervisor), /calm restores and re-hides them while persisting the shared preference
```

Both versions also passed the flag-off and resume sections.
Refreshed on 2026-09-23 on macOS with tmux 3.7c against Claude Code 2.1.280: all three sections passed, with the away-mode escalation arriving without its U+2063 mark and classifying as away-supervisor.
Run with the mark-only parser on 2.1.278, the same guard fails with `not ok - the operational user row drew while Calm was on`.
The Claude Code debug log names a loaded hooks module by plugin name through 2.1.276 and by its `plugin@source` label from 2.1.277, which the guard accepts in both forms.

Claude Code folds a long typed burst, so an away-mode digest typed inline loses its header from the first character: it arrives wrapped as `<pasted_content>` or cut to its tail, and either shape reads as the captain returning.
`escalate_flush` in `bin/fm-supervise-daemon.sh` therefore types any digest over `INJECT_INLINE_MAX_DEFAULT` (480 characters) as a pointer line naming a digest file.
On 2.1.281 a 501-character line typed mid-turn arrived intact, while a line of about 1,300 characters was folded mid-turn and lines of 2,800 to 3,200 characters were folded on an idle pane; on 2.1.280 folding began at about 950 characters on an idle pane.
The daemon's Claude busy guard reads a Claude turn only when the daemon knows the primary harness, which the detached launch hands over as `FM_DAEMON_PRIMARY_HARNESS`.
Since the integration of upstream `30ef650d`, a daemon that knows its primary is Claude Code types the owner's record-backed doorbell instead of the envelope, so the pointer bound above applies to typed-envelope primaries; the runs below predate that change and have not been repeated.

Verified on 2026-09-23 on macOS with tmux 3.7c on a private socket, against Claude Code 2.1.281 with a tool-less Haiku stand-in:

```sh
FM_AFK_CLAUDE_DIGEST_LIVE_E2E=1 tests/fm-afk-claude-long-digest-live-e2e.test.sh
```

Observed output:

```text
ok - Claude Code 2.1.281 (Claude Code): a digest of more than 2,000 characters typed inline arrives cut to its last 383 characters and classifies as none
ok - Claude Code 2.1.281 (Claude Code): a long digest arrives as a 336-character pointer line that classifies as away-supervisor, with every event in its file
ok - Claude Code 2.1.281 (Claude Code): a mid-turn escalation defers on the Claude busy guard and arrives intact after the turn
```
This guard is the refresh command after a Claude Code upgrade.

The same guard proves the daemon's recovery of a digest left in the composer (`recover_owned_input` in `bin/fm-supervise-daemon.sh`).
Claude Code holds a marked digest under its review banner after the first Enter, with the composer reading pending and its rows, read across their wrap breaks, showing the typed digest without U+2063; one Ctrl+U deletes one wrapped row, so a two-row digest clears in two presses.
Refreshed on 2026-09-26 on macOS with tmux 3.7c on a private socket, against Claude Code 2.1.283:

```text
ok - Claude Code 2.1.283 (Claude Code): a digest of more than 2,000 characters typed inline arrives cut to its last 383 characters and classifies as none
ok - Claude Code 2.1.283 (Claude Code): a long digest arrives as a 336-character pointer line that classifies as away-supervisor, with every event in its file
ok - Claude Code 2.1.283 (Claude Code): a mid-turn escalation defers on the Claude busy guard and arrives intact after the turn
ok - Claude Code 2.1.283 (Claude Code): a digest left under the review banner is submitted once by the next flush and classifies as away-supervisor
ok - Claude Code 2.1.283 (Claude Code): a stale owned digest is cleared from the wrapped composer a row at a time and never submitted
```
`tests/fm-afk-owned-digest-recovery.test.sh` is the portable regression for the same recovery, including the give-up path and composers the daemon may not touch.

### Named Claude Code composer

Claude Code draws a user-set session name into its composer's top rule as `─...─ name ─`.
The name takes the width before the rule does, so a long name leaves no leading rule and is truncated with `…`, as in ` long-name… ─`, and a name just under the width leaves only a few leading `─`.
The shared reader accepts that row only as a composer's top rule, never its bottom.
Verified on 2026-09-30 on macOS with tmux 3.7c on a private socket, against Claude Code 2.1.286; no prompt is submitted:

```sh
FM_COMPOSER_MATRIX_LIVE=1 tests/fm-composer-matrix-live-e2e.test.sh
```

```text
ok - claude (2.1.286 (Claude Code)): a short-named composer reads empty idle and proves, then clears, typed text
ok - claude (2.1.286 (Claude Code)): a long-named composer reads empty idle and proves, then clears, typed text
```

This guard is the refresh command after a Claude Code upgrade.
`tests/fm-afk-inject-titled-composer.test.sh` is the portable regression, covering the offline reads (including the truncated form and herdr's cursorless read) and tmux end to end.
`tests/fm-afk-inject-titled-composer-herdr-e2e.test.sh` is its herdr end-to-end counterpart, including a dropped Enter.

## Composer classification matrix

### 2026-09-10 Codex pane re-read refresh

The 2026-09-10 command below classifies the visible surfaces of two prepared Codex panes, one idle and one holding typed input, through the Herdr lab helper without launching or closing panes.
Preparing those panes, including the OSC 10/11 animation setup, is outside this command, so this record does not reproduce that setup or tie the panes to the Codex version on its own:

```sh
FM_COMPOSER_CODEX_LIVE=1 FM_COMPOSER_CODEX_LAB_SESSION="$HERDR_LAB_SESSION" FM_COMPOSER_CODEX_LAB_IDLE="$IDLE_PANE" FM_COMPOSER_CODEX_LAB_TYPED="$HIGH_PANE" HERDR_LAB_HELPER="$HERDR_LAB_HELPER" bin/fm-test-run.sh tests/fm-composer-matrix-live-e2e.test.sh
```

```text
ok - codex-cli 0.154.0: real Codex IDLE composer classifies empty
ok - codex-cli 0.154.0: real Codex TYPED composer classifies pending
```

The portable capture regression is `tests/fm-composer-ghost.test.sh`; removing the classifier change fails with `Codex idle: expected empty, got pending`.
This refresh covers Codex animation only; the historical multi-harness [matrix](runtime-backends.md#composer-classification-matrix) retains its original version bounds.

### Braille-only drafts outside the animation

The glyph-row strip applies only to a styled capture whose every braille cell carries its own truecolor foreground, the animation's positive signature; a braille-only draft in the default foreground, such as `❯ ⠁⠂`, stays `pending` styled and `unknown` plain, which `test_matrix_braille_only_draft_outside_animation` pins with its painted-cell divergence.

## Steering-inbox doorbell

### Stranded-doorbell recovery

The same guard also types a doorbell with no Enter, records the stranded memory, and requires one ordinary re-ring to submit it with Enter alone.
Verified on 2026-09-13, tmux 3.7c, macOS on Apple silicon, private socket:

```sh
FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_HARNESSES=codex bin/fm-test-run.sh tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

```text
ok - codex (codex-cli 0.154.0): the doorbell reached a real worker, which acted and acked with the mv
ok - codex (codex-cli 0.154.0): a stranded doorbell was submitted by one re-ring (result 5), and the worker acted and acked
```

Codex 0.154.0 and Claude Code 2.1.270 both word-wrap a long composer line, dropping the space at each break and indenting continuation rows by two cells, which is why the identity check forgives whitespace only at row boundaries.
On both, a composer holding the exact doorbell matched, and appending text or deleting one character did not.
Claude Code 2.1.270's `--dangerously-skip-permissions` launch stops at a bypass-permissions acceptance dialog that this guard does not confirm, so the guard's Claude checks fail as unready on that version.
On a Claude worker launched without that flag, the same typed doorbell plus stranded memory made `fm_task_inbox_ring` return 5, and the worker acknowledged the record.

## Pi supervision branch

### Merge-grant gate under the words model, verified 2026-09-24

This fork took the words model recorded under [Pi supervision branch](runtime-backends.md#pi-supervision-branch) except its merge gate: while the away-posture record exists a merge still proceeds only for a task whose yolo posture is on or whose id the captain granted with `--grant` at `/afk`, so the merge-gate lines of the 2026-09-20 entry do not describe this fork.
The suites were run on macOS on Apple silicon, Node v26.4.0, with tasks-axi 0.2.6 and quota-axi 0.1.51 first on `PATH`; no model was selected or prompted and no provider call was made.

```sh
bin/fm-test-run.sh tests/fm-afk-contract.test.sh tests/fm-afk-launch.test.sh tests/fm-pr-merge.test.sh tests/fm-pr-check-security.test.sh tests/fm-contributions.test.sh tests/fm-branch-supervision.test.sh tests/fm-pi-branch-extension.test.sh tests/fm-send-resolve-key.test.sh
```

```text
ok - merge grants come only from --grant, are listed in the read-back, survive a refresh, and are replaced with the words
ok - a version 1 record validates, reads its words, scalars, and merge grants with the clause sections ignored, refreshes untouched, and archives
ok - enter: a --grant on a refresh is not applied and leaves the standing record alone
ok - away merges require yolo or a grant, and --attended-override does not skip that
ok - under the away-posture record the branch merges a granted green task, is held without a grant, cannot waive a red check, and is refused at the partition while attended
ok - a grant does not bypass red checks, and a recorded pr= must match the URL
ok - no away-record archive or grant revocation lands between the authority read and the merge
ok - a grant revoked before the merge's own authority read refuses the merge
ok - queued merges retain yolo and away-grant after captain return
ok - away yolo delivery is fleet work without granting merge authority
```

## agy (Antigravity CLI)

The agy crewmate adapter was verified on 2026-09-10 with agy 1.2.0 on macOS on Apple silicon, tmux 3.6a.
The current live guard uses throwaway workspaces on a private tmux socket and checks that the operator's global trusted-workspace list stays unchanged.
agy updates itself, so re-run the live guard after any upgrade before trusting these facts.

### accept-edits covers file edits, not shell commands

This is the decision `config/crew-permissions=auto` rests on.
The same mode, same granted directory, two tool classes:

```sh
agy --mode accept-edits --add-dir "$WS" -p 'Using your file writing tool, create flagcheck.txt containing FLAGS_OK. Then reply DONE.'
agy --mode accept-edits --add-dir "$WS" -p 'Run the shell command: date. Then reply with its output.'
```

```text
DONE
FLAGS_OK

jetski: no output produced - a tool required the "command" permission that headless mode cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in settings.json (e.g. command(<target>)). Alternatively, re-run with --dangerously-skip-permissions to auto-approve all tools.
```

Interactively the second case renders an answerable prompt instead of denying:

```text
Requesting permission for:
   date
Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with 'date'
  3. Yes, and always allow for commands that start with 'date' (Persist to settings.json)
  4. No, cancel
```

### The worktree grant, and why it must be resolved

Without `--add-dir`, a write reported success and landed outside the workspace:

```sh
cd "$WS" && agy -p 'Create a file named probeB.txt containing BRAVO. Then reply DONE.'
```

```text
DONE
```

```text
Created file file://$HOME/.gemini/antigravity-cli/scratch/probeB.txt with requested content.
```

With an unresolved grant whose parent is a symlink (`/var` -> `/private/var`), agy resolved the path itself and treated its own workspace as foreign:

```text
Reason: outside workspace
Allow creation of this file?
> 1. Yes, allow creation
  2. Yes, and always allow non-workspace access
  3. No, deny creation
```

A resolved grant produces neither prompt, and also suppresses the workspace-trust dialog whose acceptance appends the path to the operator's global `trustedWorkspaces`.

### Native worker hooks

Verified on 2026-09-10 with Agy 1.2.0 using the documented named-hook schema in a separately granted `.agents/hooks.json`.
The production worker installer preserves the project hook file and writes its own registration under task state.
`PreInvocation` reports busy, and a `Stop` with `fullyIdle=true` reports idle and signals turn-end for the bound generation and conversation.
An approval wait remains busy.
Escape emits no Stop, so the semantic state conservatively stays busy and control reports cancellation unconfirmed.
This positive guard supersedes the earlier negative hook probe, which used an incompatible schema.
Re-verified on 2026-09-14 with Agy 1.2.2 on macOS on Apple silicon: the `-i` opening prompt of a launch with the production worker hooks replaced the spawn seed with an `agy-hook` record and settled to `idle agy-hook`.
That record is the signal `bin/fm-spawn.sh` now waits for before reporting an agy ship or scout spawn, and `tests/fm-agy-harness.test.sh` pins the gate's success and fail-and-close paths portably.

```sh
FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
```

The current guard additionally verifies the shared composer classifier against real empty and pending input.
The nine-check run passed on 2026-09-10 with Agy 1.2.0; the composer check enables terminal color locally because the invoking test environment had `NO_COLOR=1`.
Agy 1.2.0 draws a `>` row between solid rules and a shortcuts or cancel footer with a model cell.
Its accept-edits placeholder uses SGR 90; the shared classifier removes only that exact styled hint inside the proven Agy shape.
Without styling, a placeholder-looking row stays unknown.
Typing hides the shortcuts hint while the accept-edits mode cell remains; a manual-mode row without that footer proof stays unknown.
Ordinary typed input, wrapped text, and a shell below a stale composer remain protected by the portable composer regressions.
[Google's hook reference](https://antigravity.google/docs/hooks) owns the vendor payload and response schema.

### Log-only tool observer

Verified on 2026-09-17 with agy 1.2.5 on macOS on Apple silicon: the worker hook file `bin/fm-agy-hook.sh install-worker` writes now carries `PreToolUse` and `PostToolUse` matcher groups that append one JSONL line per tool call to `state/agy-permission-log.jsonl` and abstain.
A real headless run (`-p`, `gemini-3.6-flash-low`, cheapest tier) with the installed hook directory granted emitted both lines while the observed `run_command` executed unchanged - the abstain contract holds against the real emitter.
The bypass flag below is lab-scoped so the headless tool actually runs; it is never a worker launch flag.

```sh
FM_AGY_OBSERVER_LIVE=1 bin/fm-test-run.sh tests/fm-agy-observer-live-e2e.test.sh
```

```text
ok - agy 1.2.5: installed worker hooks emit a PreToolUse and PostToolUse line while the tool runs unchanged
# agy observer live checks passed (agy 1.2.5)
```

The portable suite `tests/fm-agy-harness.test.sh` pins the record schema, the field caps, the never-log-contents rule, every inert failure path, concurrent appends, and the install-time refusal of a malformed merged `hooks.json`.

### Bypass permission layer (opt-in)

Verified on 2026-09-25 with agy 1.2.11 on macOS on Apple silicon in scratch workspaces under the task temp root, on `gemini-3.6-flash-low` headless runs.
The same six checks passed on 1.2.7 on 2026-09-20 and on 1.2.6 on 2026-09-18, and the earlier hook-contract facts were verified on 1.2.4 and 1.2.5; the same six checks then passed on 1.3.1 on 2026-10-07 (see the 1.3.1 refresh below), so the layer's live-verified set is `1.2.4 1.2.5 1.2.6 1.2.7 1.2.11 1.3.1`.
A version without that evidence, such as 1.2.8 through 1.2.10, 1.3.0, or any later release, stays outside the set.
The set stays an explicit allowlist rather than a minimum version, because each entry is individually proven against the version-sensitive hook contract.

```sh
FM_AGY_BYPASS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-bypass-live-e2e.test.sh
```

```text
ok - agy 1.2.11: a policy deny blocks a bypassed call and the reason reaches the model
ok - agy 1.2.11: an abstained task-local file op runs unchanged and the armed heartbeat logged
ok - agy 1.2.11: a timed-out judge denies, holds the call for firstmate, and never abstains
ok - agy 1.2.11: install-worker refuses a malformed merged hooks.json before any launch
ok - agy 1.2.11: a force_ask decision under bypass did not block the call - no prompt exists to force
ok - agy 1.2.11: a bypass session whose hook never logs leaves no armed line for the canary to trust
# agy bypass permission layer live checks passed (agy 1.2.11)
```

What this proves: `{"decision":"deny","reason":...}` holds under `--dangerously-skip-permissions` and the model echoes the reason; abstention runs the call (the layer's only approval surface); a dead judge still denies; a malformed merge is caught before launch; and a session that never loads the adapter produces no armed line for `fm-spawn`'s canary to trust.
What it also shows: `force_ask` is inert under bypass - there is no prompt left to force - so deny plus abstain are the only effective decisions the layer can emit, and every "ask the human" path must go through the pending-marker escalation instead.

Admission checks beyond the guard, on agy 1.2.11 (2026-09-25) with the production `install-worker` wiring and policy file shape, in headless `-p` runs and interactive `-i` sessions on a private `tmux -S` socket:

- Hook firing per tool class: `run_command`, `view_file`, `write_to_file`, `replace_file_content`, `read_url_content`, `invoke_subagent`, and `send_message` each emitted `PreToolUse`, and the first four also emitted `PostToolUse` when their call ran.
  A subagent started through `invoke_subagent` ran its own `run_command` through the same hooks under its own `conversationId`, so delegated calls are policed rather than escaping the layer.
  The 1.2.11 print-mode toolset for `gemini-3.6-flash-low` has no `list_dir`, `grep_search`, or `search_web`; directory listing and search go through `run_command`, so those three tool names have no live call to observe.
  The payload shape was unchanged: `run_command` args still carry `CommandLine`, `Cwd`, `WaitMsBeforeAsync`, `toolAction`, and `toolSummary`.
- Held calls, with a 1-second judge timeout: a denied `python3 -c` write leaves a pending marker `agy-permission-<conversationId>-s<step>` and a `needs-decision` line; once that call is approved, the model's retry in the same conversation runs with decider `cache` and no new escalation, and once it is declined, the retry is refused by policy with no new marker or `needs-decision` line.
  Retries from separate headless conversations do not share a cache key, because the model writes a fresh `toolAction`, `toolSummary`, and `WaitMsBeforeAsync` per conversation; the worker retry path is the same-conversation one above.
- Physical-path write guards: a `write_to_file` through an in-worktree symlink to a directory outside every write root was refused (`write_to_file outside the task write roots (...) is refused by firstmate policy`) and nothing landed, and a `write_to_file` into the worktree's `.agents/` was refused as agent or git configuration.
  A symlink target under `$TMPDIR` is inside the scratch write roots by design, so the probe target must sit outside `/tmp` and `$TMPDIR`.
- Startup canary in the worker shape: an interactive `-i` bypass launch wrote the adapter's armed line stamped with that launch's busy generation, which is the exact record `agy_wait_for_armed` polls.
- Default judge tier: `judge-probe` on a residue `run_command` printed `tier=agy model=gemini-3.6-flash-low static=residue verdict=approve reason=...` and left every file in the case state directory byte-identical.

`--sandbox` composition probe, 2026-09-19, agy 1.2.7: the flag composes with the bypass launch in headless mode, but the probe found no containment the adapter could rely on in that mode, and its interactive-session behaviour under a spawned pane is unverified.
The launch therefore stays on `--dangerously-skip-permissions` alone, with the policy layer's write guards as the write restriction.

#### 1.3.1 refresh (2026-10-07)

Refreshed on 2026-10-07 with agy 1.3.1 on macOS on Apple silicon, in scratch workspaces under the task temp root, on `gemini-3.6-flash-low` headless runs.
`bin/fm-spawn.sh --agy-bypass` refuses any version outside the allowlist, so 1.3.1 required this refresh before it could launch.
Nothing in the version-sensitive hook contract changed: the same six live checks and the observer live check passed unchanged, and the `agy models` catalog still lists `gemini-3.6-flash-low`, so no part of the layer needed adapting beyond adding 1.3.1 to the allowlist.
1.3.0 has no live evidence and stays outside the set.

```sh
FM_AGY_BYPASS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-bypass-live-e2e.test.sh
```

```text
ok - agy 1.3.1: a policy deny blocks a bypassed call and the reason reaches the model
ok - agy 1.3.1: an abstained task-local file op runs unchanged and the armed heartbeat logged
ok - agy 1.3.1: a timed-out judge denies, holds the call for firstmate, and never abstains
ok - agy 1.3.1: install-worker refuses a malformed merged hooks.json before any launch
ok - agy 1.3.1: a force_ask decision under bypass did not block the call - no prompt exists to force
ok - agy 1.3.1: a bypass session whose hook never logs leaves no armed line for the canary to trust
# agy bypass permission layer live checks passed (agy 1.3.1)
```

```sh
FM_AGY_OBSERVER_LIVE=1 bin/fm-test-run.sh tests/fm-agy-observer-live-e2e.test.sh
```

```text
ok - agy 1.3.1: installed worker hooks emit a PreToolUse and PostToolUse line while the tool runs unchanged
# agy observer live checks passed (agy 1.3.1)
```

The portable `tests/fm-agy-harness.test.sh` passed, and `tests/fm-agy-permission-policy.test.sh` passed every case except `fm-agy-permission-policy: exact shell inbox acknowledgements pass; siblings, globs and symlinks refuse`, which fails on a sibling-inbox `mkdir -p` the shared command policy abstains rather than denies.
That case fails independently of the agy bypass layer and this allowlist change: it exercises `bin/fm-command-policy-lib.sh`, which this change does not touch, and is tracked separately.

Portable permission-policy checks, refreshed on 2026-10-02 with fixture judges and ShellCheck 0.11.0:

```sh
bin/fm-test-run.sh tests/fm-agy-permission-policy.test.sh tests/fm-devin-permission-policy.test.sh
bin/fm-lint.sh
```

```text
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=63124
```

These checks cover exact numeric inbox acknowledgements and symlink/sibling refusals, interpreter routing, read-exclusion context beyond bounded brief excerpts, one-shot exact-batch credential approvals, and generation-bound audit retention.
The fixtures verify policy transport and enforcement, not model agreement with the revised prompt or native background-task ownership.
They do not extend the live-verified agy version set above.

### Primary and secondmate supervision

Verified on 2026-09-10 with Agy 1.2.0 and `gemini-3.8-flash` at low effort on macOS using a throwaway Firstmate home and private tmux socket.
The startup fixture acquired the real session lock and rendered the production supervision instructions; it omitted fleet bootstrap and external startup checks.
The native registration, transport, shared guard, watcher, queue drain and acknowledgement were production code.

```sh
FM_AGY_PRIMARY_LIVE=1 bin/fm-test-run.sh tests/fm-agy-primary-live-e2e.test.sh
```

```text
ok - agy primary fixture: interactive shell is ready before launch delivery
ok - agy primary fixture: native agy process started
ok - agy primary: native nudge reaches the model and real session lock is acquired
ok - agy primary: Stop forces a bounded recovery and the real watcher arms
ok - agy primary: native watcher completion re-enters the model without polling or injected keys
ok - agy primary: the same guard includes a marked linked secondmate home
# all agy primary live checks passed (agy 1.2.0)
```

The opening invocation receives the session-start nudge, while later invocations can execute pending tools without repeated injection.
Native `Stop.executionNum` advances on a forced continuation and resets for a fresh execution cycle.
In confirmed primary scope, native PreToolUse decisions preserve review with `ask` or refuse a disallowed tool with `deny`; no `allow` bypass is installed.
When native review asks, the fixture allows only its own exact commands and its generation-bound queue acknowledgement.
It keeps its terminal captures, observer events, and transcripts for a failed check.
The linked secondmate check verifies the production scope boundary; it does not provision a persistent fleet home.
Headless primary supervision, compaction refresh, semantic interrupt completion, and runtime backends other than tmux were not verified by this run.

### Inherited primary hooks in worker worktrees

Verified on 2026-09-10 with agy 1.2.0 in a real linked worktree containing the tracked `.agents/hooks.json` primary registration.
The production hook exits 0 without stdout for rejected scope or payloads.
The live fixture observes and forwards the production response and exit code, proves the inherited PreToolUse actually ran, and requires the file edit to complete automatically under accept-edits.

```sh
FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
```

```text
ok - agy: --mode accept-edits auto-approves a file edit inside the granted worktree
ok - agy: inherited primary PreToolUse exits silently and the linked worker edit remains automatic
ok - agy: a shell command still requests approval under accept-edits
# all fm-agy-signals live checks passed (agy 1.2.0)
```

Silence is required here: returning `{}` instead caused the same live worker's file write to be denied by the pre-tool hook.
The vendor's [PreToolUse response schema](https://antigravity.google/docs/hooks#pretooluse) requires a decision when returning JSON.
`tests/fm-agy-harness.test.sh` covers silent scope and payload rejection, while allowed calls in a primary or marked linked secondmate retain `ask`.

### Model ids, catalog, and --effort conflict

Refreshed 2026-09-25 with agy 1.2.11 on macOS on Apple silicon, headless in a scratch directory; `~/.gemini/antigravity-cli/settings.json` and `~/.gemini/settings.json` hashed identically before and after.
The catalog `bin/fm-spawn.sh` checks against, with `Fetching available models...` on stderr:

```sh
agy models </dev/null
```

```text
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.7-flash-high	Gemini 3.7 Flash (High)
gemini-3.7-flash-medium	Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low	Gemini 3.7 Flash (Low)
gemini-3.6-flash-high	Gemini 3.6 Flash (High)
gemini-3.6-flash-medium	Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low	Gemini 3.6 Flash (Low)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
gemini-3.1-pro-low	Gemini 3.1 Pro (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
```

Each launch pair ran as `agy -p 'Reply with exactly the word OK and nothing else. Do not use any tools.' --add-dir <scratch> --print-timeout 100s <pair> </dev/null`:

| Pair | Exit | Output |
|---|---:|---|
| `--model gemini-3.8-flash-low` | 0 | `OK` |
| `--model gemini-3.8-flash-high --effort high` | 0 | `OK` |
| `--model gemini-3.8-flash --effort low` | 0 | `OK` |
| `--model gemini-3.8-flash --effort high` | 0 | `OK` |
| `--model gemini-3.8-flash-high --effort low` | 1 | `error: invalid model selection (--model "gemini-3.8-flash-high" --effort "low"): --model gemini-3.8-flash-high conflicts with --effort=low` |
| `--model gemini-3.8-flash` | 1 | `error: invalid model selection (--model "gemini-3.8-flash" --effort ""): --model gemini-3.8-flash requires --effort (available: low, medium, high)` |
| `--model gemini-3.1-pro --effort medium` | 1 | `error: invalid model selection (--model "gemini-3.1-pro" --effort "medium"): gemini-3.1-pro has no "medium" effort (available: low, high)` |
| `--model gemini-3.8-flash --effort xhigh` | 1 | `error: invalid model selection (--model "gemini-3.8-flash" --effort "xhigh"): invalid --effort "xhigh" (valid: low, medium, high, max)` |
| `--model gemini-3.9-nonexistent` | 1 | ends with the catalog's labels, e.g. `GPT-OSS 120B (Medium)` |

A listed id or a base whose `<base>-<level>` is listed for the passed level therefore launches, and every refused shape above is one `bin/fm-spawn.sh` refuses before an endpoint exists.
agy 1.2.11 also accepts `--effort max`; the adapter still caps xhigh and max at high.
`tests/fm-agy-harness.test.sh` pins the acceptance rule and the unreachable, hung, and invalid-bound listing behavior against a fake catalog of the same shape.

### End-to-end supervised task

On agy 1.2.0, a scout dispatched through the real entry point onto a disposable pooled worktree read its brief and a worktree file without prompting, took a steer through the durable steering inbox, wrote its report, and appended its own `done:` status line.
Its footer showed the resolved profile, `accept-edits · Gemini 3.8 Flash · medium`.
Under `accept-edits`, a heredoc file write and an `echo ... >>` status append each ask for approval, and a declined out-of-workspace read returns `User declined the tool call` to the model without wedging the session.
agy can show a feedback survey (`How's the CLI experience so far?`) that waits for a keypress mid-task, and no launch flag turns it off.

Lifecycle control through the real control plane:

```text
interrupt-delivered <task-id> harness=agy backend=tmux verified=agent-alive cancel=unconfirmed
stopped <task-id> harness=agy backend=tmux endpoint=<endpoint> worktree=<worktree>
```

Without `agy` in the tmux process-name classifier, that interrupt refuses with `endpoint reads 'ambiguous' rather than a positively classified state`, so the classifier entry is required rather than cosmetic for this adapter.

`tests/fm-agy-harness.test.sh` is the portable regression.
`FM_AGY_SIGNALS_LIVE=1 tests/fm-agy-signals-live-e2e.test.sh` is the command that refreshes the version-scoped facts above against the installed binary.

### Delivery busy footer

Verified on 2026-09-10 with agy 1.2.0 through a private tmux session on macOS.
The live guard exercises `fm_busy_lines_match` against the running and idle footers, both with an explicit `agy` harness and with the harness-less submit fallback:

```sh
FM_AGY_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-agy-signals-live-e2e.test.sh
```

```text
ok - agy 1.2.0: explicit and harness-less delivery matchers read idle
ok - agy 1.2.0: explicit and harness-less delivery matchers read busy
# all fm-agy-signals live checks passed (agy 1.2.0)
```

`tests/fm-tmux-submit-busy.test.sh` covers harness isolation and the idle-to-busy submit path with an unreadable composer, including already-busy and failed-capture baselines that must remain unconfirmed.

### Composer proof through herdr

herdr 0.9.3's styled visible read, `herdr pane read <pane> --source visible --format ansi`, terminates every row with CRLF.
With agy 1.3.1 under `--dangerously-skip-permissions`, the idle footer carries no mode cell, only `? for shortcuts` and the model name.
The agy selector ignores the row terminator, so that idle shape classifies `empty` through herdr, while a `Press up to edit queued messages` footer stays unproven.
`tests/fm-composer-agy.test.sh` pins both shapes portably.
No live guard drives a herdr agy pane yet; re-read an idle agy pane through herdr after an agy or herdr upgrade to refresh this record.

### Catalog-backed quota buckets

Verified 2026-10-06 with agy 1.3.0.
The token-free live guard feeds synthetic independent bucket capacity to the public quota chooser and binds models from the installed `agy models` catalog.
No model prompt or provider quota read is performed.
Other harnesses and runtime backends do not participate in this catalog boundary.
The synthetic routing and observer matrices are covered by `tests/fm-dispatch-resolve.test.sh`, `tests/fm-quota-choose.test.sh`, and `tests/fm-procevent-quota.test.sh`.

```sh
bash bin/fm-test-run.sh tests/fm-quota-agy-catalog-live-e2e.test.sh
```

```text
ok - agy 1.3.0: catalog-backed quota buckets verified without model tokens
```

## Devin CLI (devin)

The Devin CLI crewmate and scout adapter was verified on 2026-09-14 with devin-cli 3000.10.21 (`devin 3000.10.21 (611c1cba)`) on macOS arm64, tmux 3.7c.
Verified for crewmate and scout work only, never a primary or secondmate.
Devin CLI installs from the Homebrew cask `devin-cli` as a single arm64 Mach-O binary.

### Process identity and markers

The agent process runs as `devin` (`ps -o comm=` reports `devin`) and spawns a child `devin` process.
Devin publishes no harness marker to child tool environments, which carry only `FM_*`, `GIT_EDITOR`, `GIT_TERMINAL_PROMPT`, and inherited launcher variables (`CLAUDECODE` unset).
`DEVIN_PROJECT_DIR` appears only inside hook execution environments.
`bin/fm-harness.sh` therefore identifies Devin by an exact `devin` ancestor alone, with no Firstmate launch marker.
Verified live on 2026-09-25 with `devin 3000.11.3 (9c803229faa4)`: `bin/fm-harness.sh` run from a worker's shell tool on the generated launch printed `devin`, which the common live guard asserts.
`tests/fm-devin-harness.test.sh` pins that an exact `devin` ancestor outranks an inherited `CLAUDECODE` and that `devin-helper` is not Devin, and `tests/fm-devin-fork-harness.test.sh` keeps the anchoring meaningful when the suite itself runs under a real Devin parent.

### Approvals and permissions

Devin CLI accepts `--permission-mode` options: `normal` (alias `auto`), `accept-edits`, `smart`, and `dangerous` (alias `yolo`, `bypass`).
Firstmate maps `auto` to `--permission-mode smart` and `manual` to `--permission-mode normal`, and never emits `dangerous`.
In smart mode, Devin CLI auto-approves workspace file writes and status line appends outside the workspace.
It prompts on commands outside smart model confidence and outside the pre-allowed set.
The interactive prompt for non-git commands presents an 8-option menu:
`1 Yes (Approve once)`, `2 Yes, allow <cmd>`, `3 Yes, always allow ... in wt`, `4 Yes, always allow ... in all projects`, `5 Yes, switch to bypass mode`, `6 Edit command`, `7 Describe change to command`, `8 No`.
The prompt for git commands offers a 7-option menu without option 5.
Firstmate pre-allows a fixed non-destructive `Exec(...)` set in the task's private config so unattended worker turns do not park on routine commands; the harness-adapters devin reference owns the list.

### Permission policy hooks

Verified live on 2026-09-15 with devin-cli 3000.10.21 under `--permission-mode smart`, using the hook shapes `bin/fm-spawn.sh` writes and `bin/fm-devin-permission-policy.sh`:
- `PreToolUse` (matcher `^exec$`) receives `tool_input.command` verbatim, and `{"decision":"block"}` with exit 2 rejects the call; the pane shows `Tool rejected: {"decision":"block","reason":"Blocked by firstmate policy: sudo is refused by firstmate policy"}`.
- `PermissionRequest` fires only for calls Devin would otherwise prompt on, with `tool_name`, `tool_input`, `tool_use_id`, and `session_id`; `{"decision":"approve"}` runs the call with no prompt, and exit 0 with no output falls through to the normal approval menu.
- One prompt can issue parallel tool calls whose `PreToolUse` and `PermissionRequest` events interleave, so escalations are keyed per `tool_use_id`.
- Approving at the menu fires `PostToolUse` for the same `tool_use_id`; rejecting with `7 No (Reject)` or cancelling with Escape fires neither `PostToolUse` nor `Stop`, so a pending escalation closes at the next `UserPromptSubmit` or at `SessionEnd`.
- Hooks are read once at session start, so a policy file change takes effect per call while a hook-shape change needs a relaunch.
- The generated config gives the task data directory no blanket `Write` allow, so a tool write to the brief reaches `PermissionRequest` instead of being auto-allowed. That rests on the two facts above - `PermissionRequest` fires for calls Devin would otherwise prompt on, and an `approve` decision runs the call with no prompt - rather than on any separately verified mechanism; project `deny` rules were deliberately not used, since their binding under `--permission-mode smart` has never been verified here.
- The headless first judge `devin --model swe-2-high --permission-mode normal --respect-workspace-trust=false --prompt-file <file> -p` returns its verdict on its own line; a whole `permission-request` hook call through the judge takes about 13 seconds on both `swe-2-high` and `swe-2-medium`, with the same approve and decline verdicts for `npm install --save-dev left-pad` and `git reset --hard origin/main`, so `swe-2-high` is the default; an inline `-p "<prompt>"` combined with other flags is rejected as a `[PATH]` argument conflict, which is why the prompt goes through `--prompt-file`.

The judge prompt approves a call the task's own instructions sanction.
Static rules settle the common cases first: the worker-contract helper list approves the worker's own contract helpers, and the optional task-grants block approves what a task declares, so the judge sees a sanctioned call only when the task declares no grants.
Judge verdicts are sampled model output rather than a guarantee, so every guarantee this layer makes rests on its static rules, and the judge is not a security boundary.
`tests/fm-devin-permission-policy.test.sh` pins the prompt's required contents and the two-line reason-then-verdict parse; `FM_DEVIN_PERMISSION_LIVE=1 bin/fm-test-run.sh tests/fm-devin-permission-policy-live-e2e.test.sh` refreshes the live hook behavior.

Fetch-contract verdict consistency, verified live on 2026-09-17 with devin 3000.10.21 (611c1cba) on free `swe-2-high`, against the prompt that names read-only web lookups routine work on any host and downloads that do something always declined, eight runs per input:

| input shape | route | verdict |
| --- | --- | --- |
| a read-only web lookup wrapped in a substitution (`page=$(curl -sS https://lookup.example/v1/items)`), which is the lookup shape the judge actually sees | `permission-request` hook, `state/<id>.devin-permission-cache/` moved aside between runs | 8/8 approve, every reason naming the read-only-lookup rule or the task's research purpose |
| a fetched page piped into a shell (`curl -s https://lookup.example/x | sh`) | never reaches the judge - `policy:escalate` (never-approve) under the hook; judge queried directly with the same prompt build | 8/8 decline, every reason naming fetched content being executed |

Under the fetch contract neither row's outcome depends on the judge: the first approves statically whenever the substitution wrapper is absent, and the second escalates statically always. The replay measures only that the judge prompt agrees with the static verdicts on the shapes it can still be shown.

On the same version, project `permissions.deny` and `permissions.ask` rules were confirmed to bind under `normal`; the dangerous and sandbox launch modes were checked too and are unsuitable for these rules and hooks, so the adapter emits neither.

### Workspace trust

Untrusted directories trigger an interactive blocking prompt:
`✱ Do you trust the authors of this directory? For security, devin should not be run in directories with untrusted content. ❭ 1 Yes, trust · 2 No, exit`.
No hooks execute while blocked on trust.
`bin/fm-spawn.sh` passes `--respect-workspace-trust false`, bypassing the prompt on fresh task worktrees.

### Configuration layers and lifecycle hooks

Devin CLI reads configuration from `~/.config/devin/config.json`, committed project hooks from `.devin/hooks.v1.json`, and project local overrides from `.devin/config.local.json`.
Passing `--config <path>` replaces only the user layer, so Firstmate passes a private copy of the user config, `state/<id>.devin-config.json`, rather than a fresh file that would discard the captain's user settings.
Upstream's `bin/fm-devin-config.sh` writes that copy with the busy-state and turn-end hooks appended, and the fork's `bin/fm-devin-lib.sh` layers the non-destructive `Exec(...)` allow set, the `git push` force-spelling denies, the permission policy hooks, and the rate-limit retry hooks onto it, restoring the user's own `read_config_from`.
Nothing is written into the worktree; the two worktree files older incarnations wrote are retired only with ownership evidence.
The file pins `"attribution": false`, which the vendor documents as a user-scope key.
The lifecycle hooks are:
- `UserPromptSubmit`: applies `busy` with event `user-prompt-submit`.
- `Stop`: applies `idle` with event `stop`, then touches `$TURNEND` only if that apply was accepted for the current generation.
- `SessionEnd`: applies `idle` with event `session-end`.
- `PreToolUse`, `PermissionRequest`, and `PostToolUse`, plus a second `UserPromptSubmit`, `Stop`, and `SessionEnd` entry: the permission policy hooks above.
- A third `UserPromptSubmit`, `Stop`, and `SessionEnd` entry: the rate-limit retry owned by `bin/fm-devin-rate-limit-retry.sh`.

`SessionStart` is omitted because it fires on resume (`source=resume`) with an empty composer, which would strand a false `busy` record.
Each hook command tolerates a refused event.

### Private config layering

Verified live on 2026-09-25 with `devin 3000.11.3 (9c803229faa4)` on macOS arm64, in a scratch git repository on a private tmux socket, with the config generated by the real `fm_devin_spawn_wire` from a user config that allows `Exec(git add)` but neither `Exec(git status)`, `Exec(git commit)`, nor `Exec(bin/fm-lint.sh)`, launched as `devin --permission-mode normal --respect-workspace-trust false --config state/<task-id>.devin-config.json --model swe-2-max -- "<prompt>"`:
- `PreToolUse` rejects `sudo -n true` with `Tool rejected: {"decision":"block","reason":"Blocked by firstmate policy: sudo is refused by firstmate policy"}`.
- `bin/fm-lint.sh` and a plain `git commit` run with no prompt and no `devin-permission-log.jsonl` entry, so the fork's allow rules bind from the `--config` layer; a command outside them, such as `bin/other-check.sh`, reaches `PermissionRequest`, the judge escalates it with a keyed `needs-decision` status line, and an approval at the prompt closes that key through `PostToolUse` with a `resolved` line.
- Worker commits carry no trailer or attribution line (`git log -1 --format='%B%(trailers)'` prints only the subject).
- The busy record moves `busy` then `idle source=devin-hook event=stop` and touches the task's turn-ended file, plain `exit` records `idle ... event=session-end`, the rate-limit retry hook records the turn end, and the footer reads `SWE-2 Max`.
- A launch with `--permission-mode smart` renders `(smart mode on)` and settles the same way.

The portable regressions in `tests/fm-devin-harness.test.sh` (the base writer and stale-`Stop` suppression) and `tests/fm-devin-fork-harness.test.sh` (the composition, user-config preservation, and refusal on a failed compose) pin this; the three live guards under Verification suite now drive the generated launch, so one command refreshes each part.

### Turn-ending errors and the rate-limit retry

Verified live on 2026-09-25 with `devin 3000.11.3 (9c803229faa4)`: a turn that ends on an error fires no hook, not even `Stop`.
With hooks recording every `UserPromptSubmit`, `Stop`, and `SessionEnd` payload, a normal turn records `submit` then `stop`, while a turn that loses its network connection records `submit` only and ends on `Something went wrong`, and Devin's session log carries a `session/prompt` error response (`Sending error response ... method=session/prompt error=Error { ... message: "Connection error, send a message to continue retrying" ... }`).
Devin writes that session log to `~/.local/share/devin/cli/logs/devin_<date>_<pid>.log`, named for the `devin` process that also runs the hooks.
A rate-limit stop takes the same `session/prompt` error-response path and names the reset in its message, in the form `Your limit will reset in <n> seconds.` or `... in <n> minutes.`.
The rate-limit error cannot be forced on demand, so `tests/fm-devin-rate-limit-retry-live-e2e.test.sh` proves session-log discovery and the `Stop` retire on the generated hooks, then appends a labeled rate-limit line to the isolated home's real session log after a hook-less cancel and follows it through a real `fm-send` retry the worker acknowledges; `tests/fm-devin-rate-limit-retry.test.sh` pins that error text with synthetic session-log lines in the same format.

### Control, interruption, and exit

Double-Escape (repeat 2 at 0.2s spacing) cancels the running turn.
A single Escape renders `(esc again to interrupt)` for under 5 seconds, while busy thinking displays `(esc twice to interrupt)`.
Interruption prints `✱ Canceled. What should Devin do?` and leaves the composer empty.
Interruption emits no `Stop` hook and leaves the busy state unchanged, matching the behavior of agy and Claude.
Typing `/exit` or `exit` quits the session cleanly, firing `SessionEnd` (reason `prompt_input_exit`).
Firstmate's control path (`fm_control_exit_command`) sends plain `exit`, not `/exit`: the slash form is ambiguous against Devin's `/revert <step>` fuzzy slash-command search and can open that menu instead of exiting, so the control path could not confirm the exit; plain `exit` has no such ambiguity.
On exit, Devin prints `Resume this session with devin -r <id>`, where `<id>` is a hyphenated word pair of the form `<word>-<word>`.

### Composer classification

Devin CLI draws a structured composer:
Top rule carries mode text (`──── (smart mode on) ─`), the agent prompt row opens with `❭` (U+276D), the bottom rule is a solid horizontal `─` rule, and the footer row reports model and context token usage (`SWE-2 Max Context: 13k / 262k tokens (5%)`).
`bin/fm-composer-lib.sh` classifies this structure into `empty`, `pending`, or `unknown` through the fork-only frame selector in `bin/fm-composer-devin-lib.sh`; `tests/fm-composer-devin.test.sh` pins it.
The idle placeholder `Ask Devin to build features, fix bugs, or work on your code` and active-work placeholder `Guide Devin while it works` are recognized as composer furniture.
While busy, the delivery token `(esc twice to interrupt)` (or `(esc again to interrupt)`) is matched by `FM_DELIVERY_DEVIN_BUSY_REGEX_DEFAULT` to confirm submitted keystrokes.

### Verification suite

Run the portable regressions and the live guards with the commands below; each live guard runs the real `bin/fm-spawn.sh` launch and its generated private config in an isolated home, on its own `-S` tmux socket with `TMUX` and `TMUX_PANE` removed.

```sh
bin/fm-test-run.sh tests/fm-devin-harness.test.sh tests/fm-devin-fork-harness.test.sh tests/fm-composer-devin.test.sh tests/fm-devin-permission-policy.test.sh tests/fm-devin-rate-limit-retry.test.sh
FM_DEVIN_SIGNALS_LIVE=1 bin/fm-test-run.sh tests/fm-devin-signals-live-e2e.test.sh
FM_DEVIN_RETRY_LIVE=1 bin/fm-test-run.sh tests/fm-devin-rate-limit-retry-live-e2e.test.sh
FM_DEVIN_PERMISSION_LIVE=1 bin/fm-test-run.sh tests/fm-devin-permission-policy-live-e2e.test.sh
FM_DEVIN_PERMISSION_LIVE=1 FM_DEVIN_PERMISSION_MODE=manual bin/fm-test-run.sh tests/fm-devin-permission-policy-live-e2e.test.sh
```

All four live runs passed on 2026-09-25 against `devin 3000.11.3 (9c803229faa4)` on macOS arm64, tmux 3.7c:

```text
ok - devin 3000.11.3 (9c803229faa4): spawn brief, model, reviewed mode, trust, identity and native Stop
ok - devin 3000.11.3 (9c803229faa4): no Claude Code hook ran and the worker commit carries no attribution
ok - devin 3000.11.3 (9c803229faa4): real fm-send doorbell read and acknowledged
ok - devin 3000.11.3 (9c803229faa4): idle interrupt sends one press; an open revert picker blocks exit and is closed without reverting
ok - devin 3000.11.3 (9c803229faa4): double Escape cancels, preserves agent, and invalidates busy state
ok - devin 3000.11.3 (9c803229faa4): plain exit and native -r session resume in reviewed mode
ok - devin 3000.11.3 (9c803229faa4): the generated arm hook finds the session log and Stop retires it
ok - devin 3000.11.3 (9c803229faa4): an injected rate-limit line after a hook-less cancel drives a real acknowledged retry
ok - devin 3000.11.3 (9c803229faa4): plain exit leaves no retry sentinel
ok - devin 3000.11.3 (9c803229faa4) (auto): PreToolUse delivers the exec command and a block refuses it
ok - devin 3000.11.3 (9c803229faa4) (auto): a piped download escalates and PostToolUse closes it once approved
ok - devin 3000.11.3 (9c803229faa4) (auto): a read-only command and a GET-shaped research fetch run without a prompt
ok - devin 3000.11.3 (9c803229faa4) (auto): a declined piped download does not run and the next prompt closes it
ok - devin 3000.11.3 (9c803229faa4) (auto): an explicit Claude import still runs the user's Claude Code hook
ok - devin 3000.11.3 (9c803229faa4) (auto): the generated policy's headless swe-2-high judge returns a parseable verdict
ok - devin 3000.11.3 (9c803229faa4) (manual): PreToolUse delivers the exec command and a block refuses it
ok - devin 3000.11.3 (9c803229faa4) (manual): a piped download escalates and PostToolUse closes it once approved
ok - devin 3000.11.3 (9c803229faa4) (manual): a read-only command and a GET-shaped research fetch run without a prompt
ok - devin 3000.11.3 (9c803229faa4) (manual): a declined piped download does not run and the next prompt closes it
ok - devin 3000.11.3 (9c803229faa4) (manual): an explicit Claude import still runs the user's Claude Code hook
ok - devin 3000.11.3 (9c803229faa4) (manual): the generated policy's headless swe-2-high judge returns a parseable verdict
```

The same runs showed that a GET-shaped lookup must print to stdout for the policy to approve it: `curl -o /dev/null` counts as a write outside the task write roots and escalates.

### Catalog-backed included_quota binding

Verified 2026-10-06 with devin 3000.11.3.
quota-axi reports Devin under scope `included_quota` (weekly and daily windows), the plan-included allowance the vendor bills by the selected model's token cost; its free SWE-2 family consumes none of it.
The token-free live guard confirms the Devin catalog still marks a paid GPT model with a per-token price and binds it to `included_quota` through the public quota chooser, while a free SWE-2 model stays unselected (free, draws on no plan quota).
No model prompt or provider quota read is performed, and other harnesses do not participate in this catalog boundary.
The synthetic routing matrix is covered by `tests/fm-dispatch-resolve.test.sh` and `tests/fm-quota-choose.test.sh`.

```sh
bash bin/fm-test-run.sh tests/fm-quota-devin-catalog-live-e2e.test.sh
```

```text
ok - devin 3000.11.3: catalog-backed included_quota binding verified without model tokens
```

