# Kiro CLI (V2 engine)

Kiro's `kiro-cli` TUI, verified end to end on 2026-09-13 with kiro-cli 2.21.4 on Amazon Linux 2 through tmux, on the V2 agent engine only.
It was re-verified on 2026-10-29 with kiro-cli 2.35.1 on Linux through tmux, with a Herdr composer probe, on Auto and on `glm-5`, and on 2026-10-13 with kiro-cli 2.24.0 on macOS through tmux, including its publish hook, context membership, and native turn-marker surfaces.
Verified as a CREWMATE and SCOUT adapter only; `../../../../../bin/fm-spawn.sh` refuses a secondmate launch on it because `../../../../../docs/supervision-protocols/` carries no kiro wake protocol.
`../../../../../docs/verification/kiro.md` owns how every fact below was established and what is still unproven.

**V2 only.** The launch pins `--agent-engine v2`, the AL2-supported engine. The v3/KAS engine is out of scope and untested here: it is unsupported on this Amazon Linux 2 host and its hooks are not yet at parity, so carry no v3 behaviour into this adapter.

## Operating facts

| Fact | Value |
|---|---|
| Binary | Absolute `kiro-cli` from `PATH`, refused if absent; the installed command is a toolbox/aim-sandbox wrapper whose foreground process name is exactly `kiro-cli` on Linux, and `kiro-cli-chat` joins its process chain on macOS. |
| Launch | `kiro-cli chat --agent-engine v2 --agent firstmate --model <id> --effort <level> --trust-all-tools "<brief>"` with the resolved absolute binary and `KIRO_HOME` relocated onto the per-task home; the positional brief auto-submits with no extra Enter. No launch-then-confirm gate: like claude, the pane just launches. Never use `--no-interactive`, whose model selection is unsupported on the measured macOS build. |
| Busy state | Claude-shaped V2 agent-config hooks are the recorded source: `userPromptSubmit` opens a turn and `stop` closes it, written as the `kiro-hook` record in `../../../../../bin/fm-busy-lib.sh`. A task-bound native turn marker can settle a stale busy hook after manual Escape; `../../../../../bin/fm-busy-lib.sh` owns binding, trust, and the conservative fallback. A kiro task with no record classifies `unknown missing`; the classifier never reads the pane for kiro. |
| Rendered tail | Busy composer footer is `Kiro is working · <elapsed> · Type to steer · Ctrl+S to queue` (2.35.1 added the elapsed time); idle shows `Trust All Tools active ... /quit to exit` or the `ask a question or describe a task` placeholder. The harness-named `Kiro is working` literal is matched, never the bare `esc to cancel` token kiro shares with agy. It is a DELIVERY guard in `../../../../../bin/fm-composer-lib.sh`, never a worker state source, and its one reachable consumer is the harness-less union in `FM_DELIVERY_BUSY_REGEX_DEFAULT` that the tmux submit core reads to acknowledge a submit; `FM_DELIVERY_KIRO_BUSY_REGEX_DEFAULT` is registered per the fleet convention and has no caller today. |
| Turn end | The `stop` hook keeps the `state/<id>.turn-ended` notification touch. Like claude, `stop` does NOT fire on a manual Escape interrupt; kiro V2 exposes no verified StopFailure/SessionEnd equivalent, so an unbound abnormal turn end leaves the record busy until the next `userPromptSubmit`, and the supervisor reads that record as provably working. |
| Exit | `/quit`, one Enter; the process exits and prints `Session ended.` then `Resume with: kiro-cli --resume-id <session-id>`. |
| Interrupt | Single `Escape`, which prints a `Cancelled ...` row and leaves an idle composer with no repollution, so no clear key follows. The control plane invalidates the busy record to `unknown` rather than claiming a cancellation acknowledgement, and a running tool process survives Escape until it finishes or the session exits; follow an interrupt with exit or relaunch when the tool must stop. |
| Publish policy | A per-task `preToolUse` hook matches `shell` and forwards V2 stdin unchanged to `../../../../../bin/fm-arm-pretool-check.sh --claude --publish-only`; exit 2 blocks before execution and returns stderr to the model; `../../../../../docs/arm-pretool-check.md` owns the shared transport. |
| Skill | No verified slash-skill form; use natural language. |
| Autonomy | `--trust-all-tools` auto-approves tool calls; its otherwise blocking confirmation modal is suppressed by the seeded `chat.disableTrustAllConfirmation` setting (see Trust below). |
| Marker | None on the verified Linux build; a live tool subprocess carries no `KIRO_*` identity variable. `KIRO_HOME` is a firstmate-set config-relocation path, not an identity. macOS exports `KIRO_SESSION_ID`, `KIRO_AGENT_ENGINE`, `KIRO_VERSION`, and `KIRO_TURN_MARKER_DIR`, but identity stays structural for compatibility with the markerless upstream build. |
| Resume | The interactive-exit line prints `--resume-id <id>`, and sessions live under the per-task `KIRO_HOME`, so `--resume-id` (or `--resume` for the most recent from the cwd) resumes with context. Firstmate does not automate resume: the control plane's deterministic `relaunch` re-reads the durable brief, matching every other adapter. |
| Model | `--model <id>` with a bare catalog `model_id` from `kiro-cli chat --agent-engine v2 --list-models -f json` (for example `claude-opus-5`, `auto`); `bin/fm-spawn.sh` refuses a requested id a reachable listing omits. The listing is a remote fetch, so the probe runs stdin-detached under the shared hard bound and an unreachable, hung, or `model_id`-less listing launches unvalidated with a notice. |
| Effort | `--effort low\|medium\|high\|xhigh\|max`; the full shared vocabulary passes through (unlike agy, which omits `xhigh`/`max`). |
| Quota | The native harness maps to quota-axi's `kiro` provider; the existing Pi provider route is separate. |
| Composer | Bare `›` (U+203A) agent-glyph row, the same glyph codex draws. The `ask a question or describe a task` placeholder is near-gray at luminance 158, drawn as truecolor `38;2;158;158;158` on a truecolor pane and as the palette index `38;5;247` - the identical grey - on a pane with no `COLORTERM`. The shared ghost strip removes both under a near-achromatic ceiling it applies only when the caller names the recorded harness `kiro` (`FM_COMPOSER_HARNESS`, owned by `fm_composer_kiro_scope` in `../../../../../bin/fm-composer-lib.sh`), so a real idle pane reads `empty` in either encoding (verified against a live capture with tmux's own descriptor). Before that ceiling existed the placeholder survived the strip and the pane read `pending`, which suppressed every steer; `../../../../../docs/verification/kiro.md` owns that history. kiro-cli 2.28.0 draws the same row in the default foreground, which no strip removes, so the kiro-scoped `FM_COMPOSER_HINTED_IDLE_RE_DEFAULT` matches the whole row by its `↵` submit hint, which typed input never renders, and reads it `empty`; a cursorless read also stops there, so the `/copy to clipboard` footer below it is never taken as wrapped input. kiro registers no entry in the fleet-wide idle-placeholder set, which changes no verdict here. |

## Out-of-tree agent config (the turn-end wiring)

`--agent` is name-only: a config path is rejected, and discovery is the global `KIRO_HOME/agents/` dir plus the workspace `<cwd>/.kiro/agents/` dir.
The workspace dir is inside the disposable worktree and must never be written, so `../../../../../bin/fm-spawn.sh` writes a firstmate-owned per-task agent config at `state/<id>.kiro-home/agents/firstmate.json` and reaches it by relocating `KIRO_HOME` onto `state/<id>.kiro-home` on the launch command, the gemini shape (a dedicated per-task config outside the project, reached through a config-pointer).
That same per-task home holds `settings/cli.json` seeding `chat.disableTrustAllConfirmation`, which suppresses the `--trust-all-tools` modal (the only blocker on a fresh launch), and `chat.disableInheritingDefaultResources`, which drops the inherited `README.md` an empty resource list would still inherit.
The config's explicit resource selectors keep root and nested project instructions, project and per-task steering inclusion rules, and project and per-task skill metadata while excluding that extra context; the spawn owner defines the selectors and the verification record proves the resulting context membership.
Relocating `KIRO_HOME` moves the whole global config root (agents, settings, sessions), and on Amazon Linux 2 it leaves auth alone because auth lives in the XDG data dir (`~/.local/share/kiro-cli`), so the worker uses the operator's real sign-in while nothing in the operator's real `~/.kiro` is touched; macOS keeps auth in `~/Library/Application Support/kiro-cli`, likewise outside `KIRO_HOME`.
Because the relocation is wholesale rather than gemini's additive single-file layer, the per-task home does not inherit the operator's global MCP servers, skills, or agents; the per-task agent config declares `tools: ["*"]` and the crewmate relies on built-in tools.
Each hook `command` in that config is a single-token absolute path to a script the spawn generates beside it under `state/<id>.kiro-home/hooks/`, so a hook runs the same whether kiro execs the command directly or hands it to a shell; the busy event, its `|| true` tolerance of a refused stale generation, the turn-end touch, the native marker binding, and the publish-policy exec all live inside the scripts.
No single token can carry whitespace or a shell-special character (quotes, `$`, backtick, `;`, `&`, `|`, `<`, `>`, parentheses, `*`, `?`, brackets, braces, `!`, backslash) under both interpretations, so a canonical kiro spawn refuses before launch when the resolved `state/<id>.kiro-home` path contains one, naming that path and asking for a `FM_HOME` or `FM_STATE_OVERRIDE` free of them; without the hooks kiro has no other recorded state source, so a pane that could never clear its busy record is never started.
`../../../../../bin/fm-control-lib.sh` lists the agent config file, the three hook scripts, and the generation-bound turn marker as retirement paths so a relaunch retires the incarnation's hooks; `../../../../../bin/fm-teardown.sh` removes the whole `state/<id>.kiro-home` directory.

## Credential precondition

A verified kiro worker ran under a signed-in account with no key export, on Amazon Linux 2 and on macOS.
macOS keeps auth at `~/Library/Application Support/kiro-cli/data.sqlite3`, outside `KIRO_HOME`, so the relocation leaves it intact on both measured platforms.
Treat any auth prompt or refusal as a credential blocker under `../../../../../AGENTS.md` section 9, fix the environment, and retire the endpoint rather than typing into it.

## Detection

Detected by ancestry alone: `../../../../../bin/fm-harness.sh` matches the anchored process names `kiro-cli` and `kiro-cli-chat`, never `*kiro*`; macOS runs both names in its process chain.
No environment marker is promoted, and kiro does not clear an inherited `CLAUDECODE`, so the spawn clears foreign markers at the launch boundary and the ancestry arm decides.
kiro is deliberately absent from the primary-capable session-lock vocabulary in `../../../../../bin/fm-session-lock-lib.sh`, where the other crewmate-only adapters are also absent: a crewmate-only adapter must never own a home session lock.

## Worker busy state and turn end

`../../../../../bin/fm-spawn.sh` arms a busy generation for kiro and embeds it in the hook commands, exactly like claude and gemini.
`fm_busy_classify` returns the `kiro-hook` record when a valid one exists, refined by a bound native turn marker when the submit hook positively bound one, and `unknown missing` when no record does; it has no kiro pane arm, so a rendered footer never classifies a kiro worker.
The marker fallback requires `jq` and a marker positively bound to that turn's generation, sequence, and process owner; missing or unproven bindings retain the hook verdict, and malformed or inaccessible native state and a lost process owner cannot establish idle.
An unbound abnormal turn end therefore leaves the record busy until the next `userPromptSubmit` re-opens it, and the watcher reads that record as provably working.
The control-plane cancellation claim remains unconfirmed even when the marker path can establish that the agent turn ended.
Teardown removes the per-task home and retires the busy generation.

## Primary integration

Unsupported and unverified.
`../../../../../docs/supervision-protocols/` carries no kiro protocol, no turn-end guard adapter exists for it, and this adapter verified only the crewmate-side launch, busy state, interrupt, exit, and resume on the V2 engine.
`references/common/primary-hooks.md`'s unsupported-boundary rule applies: never invent a wake protocol from a similar TUI.
