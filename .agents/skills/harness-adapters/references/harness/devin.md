# devin (Devin CLI)

Cognition's Devin CLI, verified on 2026-09-14 with devin-cli 3000.10.21 on macOS.
Verified for crewmate and scout work only, never a secondmate or primary.
`../../../../../bin/fm-spawn.sh` owns the concrete launch and hook mechanics, through the fork-only `../../../../../bin/fm-devin-lib.sh` it sources.

## Operating facts

| Fact | Value |
|---|---|
| Binary | `devin` resolved from `PATH` (e.g. `/opt/homebrew/bin/devin`, installed via Homebrew cask `devin-cli`). A single arm64 Mach-O binary. Refused at spawn when missing. |
| Launch | Positional prompt `-- "<prompt>"` starts the interactive session. `--print` / `-p` is headless and never used for a worker. |
| Directory grants | None needed; Devin CLI operates in the working directory. `--respect-workspace-trust false` bypasses the workspace trust prompt. |
| Approvals | Reviewed mode via `--permission-mode smart` for `auto` and `--permission-mode normal` for `manual`. Unconditional bypass (`dangerous`) is never emitted. A fixed non-destructive command set is pre-allowed in the task's private config, and firstmate's permission policy hooks refuse, approve, judge, or escalate the rest (see Approvals and permissions). |
| Busy state | `devin-hook`: `UserPromptSubmit` opens a turn (busy); `Stop` and `SessionEnd` close it (idle). `SessionStart` is omitted to avoid false busy on resume. Double-Escape interruption emits no `Stop`, so `bin/fm-control.sh` invalidates the interrupted incarnation to `unknown` rather than claiming idle. |
| Rendered tail | Delivery guard only, via either of two independent signals: `esc (twice\|again) to interrupt` or the `❭ Guide Devin while it works` working composer. Not a worker-state source. |
| Turn end | Native `Stop` hook in the private config touches `$TURNEND` only after its generation-bound idle apply succeeds, so a stale incarnation's `Stop` wakes nothing. |
| Exit | Firstmate sends plain `exit`, one Enter (`fm_control_exit_command`). `/exit` is documented as an equivalent alias but is ambiguous against Devin's `/revert <step>` fuzzy slash-command search and can open that menu instead of exiting; plain `exit` has no such ambiguity. |
| Interrupt | Double `Escape` (repeat 2) cancels the running turn, but the control plane sends the second press only after the first renders `esc again to interrupt` and at least 0.5 seconds later: a fast idle pair opens Devin's `/revert` picker, where Enter reverts file changes. An idle agent gets one press and `cancel=not-running`; a picker a mistimed press opened is closed with one `Escape`, and `exit` refuses while one is open. Devin prints `✱ Canceled. What should Devin do?` and leaves the composer empty. `bin/fm-control-lib.sh` owns the arm signal, press gap, and picker signature, taken from upstream's 2026-09-22 live evidence on devin 3000.11.1. |
| Resume | `devin -c` / `--continue` for the most recent session, or `devin -r <SESSION_ID>` / `--resume <SESSION_ID>`. Session IDs are hyphenated word pairs (`<word>-<word>`). |
| Models | `--model <model>`. An omitted or `default` model launches `--model swe-2-max`, the worker default; an explicit model passes through unchanged. The launch footer (`SWE-2 Max`), not task metadata, is the runtime evidence. |
| Effort | Encoded in model ids (`swe-2-high`, `swe-2-max`); there is no separate CLI effort flag. Requested effort is recorded in task metadata only (record-and-omit). |
| Marker | None. Devin publishes no harness-identity marker, so `bin/fm-harness.sh` identifies it by an exact `devin` ancestor (`comm=devin`), which outranks an inherited foreign marker; `bin/fm-spawn.sh` also clears foreign markers at the launch boundary. |
| Composer | Structured composer between a top mode rule (`──── (smart mode on) ─`), prompt row with `❭` (U+276D), and a solid bottom `─` rule, followed by a model and context footer (`Context: ... tokens`). Idle placeholder is `Ask Devin to build features, fix bugs, or work on your code`; busy placeholder is `Guide Devin while it works`. |
| Skill | Skills discovered in `.devin/skills/` and `.claude/skills/`. |
| Config | User config at `~/.config/devin/config.json`. Passing `--config <path>` replaces only that user layer; project `.devin` config still merges over it. Firstmate launches every worker with `--config state/<id>.devin-config.json`, a private copy of the user config carrying firstmate's wiring (see Lifecycle hooks and configuration layers). |
| Attribution | Defaults to `true` in Devin CLI, emitting `Generated with [Devin]` and `Co-Authored-By: Devin`. Unless the home sets `config/keep-ai-trailers` (`../../../../../docs/configuration.md` "Commit attribution"), firstmate pins `"attribution": false` in the private config, which is the user scope the vendor documents for that key; with the flag, the user config's setting is kept. |

## Approvals and permissions

Devin CLI provides multiple permission modes: `normal` (alias `auto`), `accept-edits`, `smart`, and `dangerous` (alias `yolo`, `bypass`).
`config/crew-permissions` maps onto reviewed modes and never onto blanket bypass:

| Setting | Devin launch | Effect |
|---|---|---|
| `auto` (or absent) | `--permission-mode smart` | Smart mode auto-approves workspace file edits and shell appends outside the workspace. Prompts on commands outside smart model confidence and outside the pre-allowed set. |
| `manual` | `--permission-mode normal` | Drops smart mode's automatic approvals. The same pre-allowed set and policy hooks below still apply, so a call they allow or approve runs without a prompt, a refused call is blocked, and the rest prompt. |
| anything else | refused | The launch stops; there is no fallback onto bypass. |

`--permission-mode dangerous` is emitted by neither setting and is never used.
This matches Firstmate's non-negotiable safety policy against unconditional bypass.
In smart mode, prompts for non-git commands present an 8-option menu:
`1 Yes (Approve once)`, `2 Yes, allow <command>`, `3 Yes, always allow ... in wt`, `4 Yes, always allow ... in all projects`, `5 Yes, switch to bypass mode`, `6 Edit command`, `7 Describe change to command`, `8 No`.
The worker may block on approvals for in-repo scripts; Firstmate delegates prompts or answers option 1 or 2, and must never choose options 3, 4, or 5 on the captain's behalf.
Firstmate pre-allows `Exec(git commit)` and `Exec(git push)` in the private config so unattended worker ship turns do not park on git mutations.
`permissions.allow` also covers the rest of the routine command surface: `Exec(git checkout -b)`, `Exec(git switch -c)`, `Exec(git remote -v)`, `Exec(git remote get-url)`, `Exec(git fetch)`, `Exec(git status)`, `Exec(git log)`, `Exec(git diff)`, `Exec(ls)`, `Exec(gh pr create)`, `Exec(gh pr view)`, `Exec(gh pr list)`, `Exec(gh pr checks)`, and the firstmate repo scripts `bin/fm-lint.sh`, `bin/fm-test-run.sh`, `bin/fm-install-shellcheck.sh`, `bin/fm-install-actionlint.sh` (each in its `bin/x`, `./bin/x`, and `bash bin/x` spellings).
`permissions.deny` holds `Exec(git push --force)`, `Exec(git push --force-with-lease)`, `Exec(git push --force-if-includes)`, and `Exec(git push -f)`, which override the allowed `Exec(git push)` prefix for those first-position spellings.

`Exec(...)` rules match each command segment by whitespace-token prefix: a segment must equal the rule text or begin with the rule text followed by a space, a compound command (`&&`, `;`, pipes) is split so each segment is judged on its own, and `*` is literal rather than a glob.
Two consequences follow: the deny list covers only the first-position force spellings above, so the permission policy hooks below own force-push refusal in every position, and `bash tests/<name>.test.sh` cannot be pattern-allowed because the token after `tests` varies; the covered test path is `bin/fm-test-run.sh tests/<name>.test.sh`.
Branch creation and remote reads are pre-allowed only in those safe forms, never as a bare `git checkout`, `git switch`, or `git remote` prefix.
Not pre-allowed by design: `rm`, anything under `gh repo`, and any unconditional bypass.

### Permission policy hooks

Smart mode stays the default, and `../../../../../bin/fm-devin-permission-policy.sh` is firstmate's decision layer on top of it; its header owns the refuse list, the read-and-build approve set, the judge contract, and the log format.
`bin/fm-spawn.sh` wires it as `PreToolUse`, `PermissionRequest`, `PostToolUse`, `UserPromptSubmit`, `Stop`, and `SessionEnd` hooks in the private config, pointing at the script under `bin/` and the per-task policy file `state/<id>.devin-permission.json`, both outside the worktree; Devin reads hooks once at session start.
It works by full-command inspection, so it covers what `Exec(...)` prefixes cannot: force pushes in any argument position, `gh pr create` without `--repo`, and every segment of a compound command.
- Refused outright: `sudo`, `launchctl`, any git push force, a recursive `rm` not strictly inside the worktree, `gh repo`, `gh pr create` without an explicit `--repo`, and any writer reaching the task's own brief.
- Also refused at `PreToolUse`, because a call a pre-allow prefix admits reaches no later hook: a mutating `git remote` subcommand, a `git checkout` or `git switch` form that can discard uncommitted work, a push that deletes, mirrors, pushes tags, or names the default branch, a fetch naming its own upload-pack program, and a git option that writes a file or runs a program; each refusal names its fix.
- Approved silently: the read-and-build set, which includes read-only web lookups - a GET-shaped `curl` or `wget` to any host whose output lands on stdout, a pipe that is not a shell or interpreter, or a file inside the task's write roots.
- Also approved silently: replying to a review comment, requesting `@codex review`, and resolving a review thread, each only on the task's own PR, plus inline read-only GraphQL queries and `&&` chains of these calls; the script header owns the exact shapes.
- Judged: the residue goes to a headless first judge on the task's judge tier, and its approvals are silent too. Devin judges Devin by default, so that is a headless SWE-2 High call on the policy file's `judge_model`, where the model id carries the effort level; `../../../../../bin/fm-judge-tier-lib.sh` owns the tier set, and the policy file's `judge_tier`/`judge_bin` would move this adapter onto another one.
- Escalated: the never-approve class - outward actions such as a download that does something (a fetched page piped into an interpreter, written outside the task's write roots or into agent or git configuration including through a symlink, run or made executable, or a request carrying a body, a non-GET method, or local file contents like an @file header or a certificate) - plus whatever the judge declines and every judge failure, as a `needs-decision [key=devin-permission-<tool-use>]` status line naming the exact command and its reason, then Devin shows its normal prompt.
  Approving at the prompt closes the key through `PostToolUse`; a reject or interrupt fires no hook, so the key closes at the worker's next prompt or at session end.

Every refusal, approval, judge verdict, escalation, and escalation outcome is one JSON line in the home-wide `state/devin-permission-log.jsonl`, the evidence for tuning the approve set and the posture, for example `jq -s 'group_by(.decision) | map({decision: .[0].decision, n: length})' state/devin-permission-log.jsonl`.
Firstmate answers an escalation at the prompt or steers the worker; it never picks the menu's "always allow" or bypass options on the captain's behalf.
Never move a Devin worker to `--permission-mode dangerous` or `--sandbox`: the pre-allowed set, the deny list, and the policy hooks are reviewed only under the two modes above, and even there they reduce risk rather than form a security boundary.

## Workspace trust

Every task worktree is a fresh path created for that task.
Without trust bypass, Devin stops on `✱ Do you trust the authors of this directory?` with options `1 Yes, trust` and `2 No, exit`.
Passing `--respect-workspace-trust false` ensures workspace trust prompts do not block unattended startup on fresh worktrees.

## Lifecycle hooks and configuration layers

Devin CLI reads configuration and hooks from three layers:
1. User config: `~/.config/devin/config.json`, or the file `--config <path>` names instead.
2. Committed project hooks: `.devin/hooks.v1.json`.
3. Project local config: `.devin/config.local.json`.

Firstmate writes nothing into the worktree or the user's own config.
`../../../../../bin/fm-devin-config.sh` (upstream's writer) copies the user config to `state/<id>.devin-config.json` with the busy-state and turn-end hooks appended, and the fork-only `../../../../../bin/fm-devin-lib.sh` then layers the reviewed permission set, the permission policy hooks, and the rate-limit retry hooks onto that same file, keeping the user's own settings, permission rules, and hooks ahead of firstmate's.
The file is published atomically at mode 600, and a missing piece refuses the launch rather than starting a worker on a partial config; the library's header owns the composition.
The launch passes it with `--config`, so it takes the user layer's place while project `.devin` config still merges over it.
The allowed and denied `Exec(...)` sets are owned by Approvals and permissions above.
The installed hooks cover:
- `UserPromptSubmit`: fires when a user submits a prompt, applying `busy` with event `user-prompt-submit`.
- `Stop`: fires when the turn ends, applying `idle` with event `stop` and touching `$TURNEND` only when that apply is accepted.
- `SessionEnd`: fires when the session terminates, applying `idle` with event `session-end`.
- The permission policy hooks owned by Approvals and permissions above.
- The rate-limit retry hooks: `UserPromptSubmit` arms a per-turn sentinel on Devin's session log, and `Stop` and `SessionEnd` retire it; `../../../../../bin/fm-devin-rate-limit-retry.sh`'s header owns the retry, its cap, and its stagger.

The private config is removed on relaunch and teardown together with the permission policy file, its pending-escalation markers, and the rate-limit retry state under `state/`.
Older incarnations wrote `.devin/config.local.json` and `.devin/rules/firstmate-attribution.md` into the worktree instead; relaunch and teardown still retire those two files where they are provably firstmate's (untracked, and recorded as a devin task or listed in git's info/exclude), and a spawn refuses while an untracked copy is still present, because its hooks would bind to a retired task.
A project's tracked `.devin` files are its own layer and are left untouched.
`SessionStart` is intentionally omitted because it fires on `resume` with an empty composer, which would strand a false `busy` state.
Each busy-state hook command tolerates a refused event, so a stale or refused event cannot break Devin CLI's lifecycle.
Double-Escape interruption emits no `Stop` hook, so the control plane invalidates the busy state to `unknown` after delivering it; a manual keyboard cancellation outside the control plane leaves the last busy record until the next normal completion or session exit.
A turn that ends on an error - the model rate limit (`Reached free model rate limit ... Your limit will reset in <N> <unit>`) or a lost connection - fires no hook at all: Devin renders `Something went wrong ... Send a message to retry`, idles on an empty composer, and leaves the last busy record in place.
The only structural record of that error is the `devin acp` process's session log, `~/.local/share/devin/cli/logs/devin_<date>_<pid>.log`, whose failed turn ends with one `Sending error response ... method=session/prompt error=` line carrying the message and reset.

## Claude hook import

Devin CLI automatically imports hooks from `.claude/settings.json`, `~/.claude/settings.json`, `~/.claude/settings.local.json`, and `~/.claude.json`.
It executes Claude hooks with `CLAUDE_PROJECT_DIR` set to the worktree path.
In linked worktrees for crewmate tasks, Firstmate's primary Claude hooks stand down safely because `fm_primary_scope_matches` rejects non-primary checkouts.
Upstream's config writer turns `read_config_from.claude` off; the fork restores the user's own `read_config_from` in the private config, so Devin's default `true` keeps `.claude/skills` and `CLAUDE.md` loading unless the user turned it off.

## Crewmate and scout only

Devin CLI has no primary supervision protocol in `docs/supervision-protocols/`.
`bin/fm-spawn.sh` explicitly refuses `--secondmate` launches on `devin`.
`bin/fm-control-lib.sh` restricts `fm_control_harness_supports_kind` so `devin` only supports `crew` and `scout` tasks.

## Model and effort

`bin/fm-spawn.sh` passes `--model <model>` for an explicit model, and `--model swe-2-max` when none or `default` is requested.
Devin encodes effort in its model ids and has no separate CLI effort flag, so requested effort is recorded in task metadata and omitted from the launch command, following the record-and-omit contract.
The permission judge keeps its own `swe-2-high`.

## Composer and delivery

Devin CLI provides an interactive TUI composer.
The composer is structured between a top mode rule (e.g. `──── (smart mode on) ─`), an agent prompt row opening with `❭` (U+276D), a solid bottom rule `────────────────────`, and a model and context footer row (`SWE-2 Max Context: 13k / 262k tokens (5%)`).
`bin/fm-composer-lib.sh` classifies this structure into `empty`, `pending`, or `unknown`, calling the fork-only frame selector in `bin/fm-composer-devin-lib.sh`.
The idle placeholder `Ask Devin to build features, fix bugs, or work on your code` and the active-work placeholder `Guide Devin while it works` are recognized as composer furniture.
While Devin is busy thinking, the delivery token `(esc twice to interrupt)` (or `(esc again to interrupt)`) appears on the status line.
`bin/fm-composer-lib.sh`'s `FM_DELIVERY_DEVIN_BUSY_REGEX_DEFAULT` matches either signal to confirm submitted keystrokes.
Typing `!` on an empty composer enters bash mode; typing `exit` quits the session.
`/exit` is documented as an equivalent alias, but Firstmate never sends it: it is ambiguous against Devin's `/revert <step>` fuzzy slash-command search (see Exit mechanics below), so `fm_control_exit_command` sends plain `exit` for devin.

## Live verification evidence

These facts were verified on macOS with Devin CLI 3000.10.21 (`devin 3000.10.21 (611c1cba)`), signed in to Devin, in a throwaway git repository.

- `devin version` prints `devin 3000.10.21 (611c1cba)`, `devin auth status` reports `Logged in (via Devin)`, and spawn checks `command -v devin` before launch.
- With hooks in `.devin/config.local.json`, `UserPromptSubmit` applies busy, `Stop` touches `$TURNEND` and applies idle, and `SessionEnd` applies idle on exit; `SessionStart` is omitted so a resume cannot strand a false busy state.
- `devin --permission-mode smart --respect-workspace-trust false -- "<prompt>"` in tmux renders the TUI with `(smart mode on)` and receives the positional prompt without blocking on workspace trust.
- The TUI shows `(esc twice to interrupt)` while thinking and `(esc again to interrupt)` after one `Escape`.
- A second `Escape` within 0.2s cancels the turn, printing `✱ Canceled. What should Devin do?` over an empty composer, which is why `fm_control_interrupt_repeat` is `2`.
- Interruption emits no `Stop` event, so the busy state conservatively stays busy.
- `/exit` or `exit` followed by `Enter` fires `SessionEnd` (reason `prompt_input_exit`) and ends the process in a single-command session.
- `/exit` can open Devin's `/revert <step>` fuzzy slash-command search menu instead of exiting, which leaves the control path unable to confirm the exit.
- Devin's own docs (`essential-commands.mdx`, `reference/commands.mdx`) document plain `exit` (no `/` prefix) as an equivalent alias that does not open that search, so `fm_control_exit_command` returns plain `exit` for devin (`bin/fm-control-lib.sh`), and every other verified harness keeps its documented exit command.

`../../../../../docs/verification/runtime-backends-fork.md` records the devin 3000.11.3 evidence from 2026-09-25: that a turn ending on an error fires no hook ("Turn-ending errors and the rate-limit retry"), that the private config binds the reviewed wiring ("Private config layering"), and the generated launch end to end, covering ancestry-only identity from a tool subprocess, the SWE-2 Max footer, reviewed smart and normal launches with their policy hooks, a real acknowledged rate-limit retry, and native resume in reviewed mode ("Verification suite").
