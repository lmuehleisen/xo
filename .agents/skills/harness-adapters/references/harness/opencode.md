# OpenCode

The launch adapter requires OpenCode V2 >= 2.0.18.
Current live evidence and its refresh command are in [runtime verification](../../../../../docs/verification/runtime-backends.md#opencode-v2).

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned V2 plugin consumes public `session.execution.*` events, latched to the worker's own session; shutdown preserves activity for resume. |
| Exit command | `/exit`. |
| Interrupt | Double Escape, within the V2 five-second interrupt window. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | Use `../../../bin/fm-control.sh <task-id> relaunch` for deterministic brief reconstruction; V2 still accepts `--continue` and `--session` for native interactive resume. |
| Model selection | Per-spawn `OPENCODE_CONFIG_CONTENT` pins root `model` and `agents.build.model`; `--standalone` makes the private server inherit that config. V2 interactive launch has no `--model`. |
| Effort | `agents.build.model` carries `provider/model#variant` in the spawn config. The spawn owner retains the verified provider effort lists and records unsupported values without emitting a variant. |
| Model discovery | Run `opencode models --standalone` to list available provider/model identifiers; V2 has no positional provider filter. |
| Trust and permissions | No folder-trust dialog observed in the scratch live guard. `--auto` approves permissions that are not explicitly denied. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

`../../../bin/fm-spawn.sh` owns the bare-launch readiness gate and guarded brief submission.
V2 `--prompt` was observed leaving a startup draft pending, so worker launch submits only after the shared composer classifier proves readiness.
The worker plugin is a package in the task temp directory, named by launch config; no global config or project file is written for model selection or hook installation.

## Busy-queued Enter

The legacy OpenCode 1.18.4 composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

## Primary integration

The primary plugins expose V2 default definitions with stable IDs and `setup(ctx)`.
Their shared [V2 boundary](../../../../../.opencode/plugins/lib/fm-v2-plugin.js) registers tool hooks and abortable public-event subscriptions, translating execution completion into the existing guard and watch-arm callbacks.
`.opencode/plugins/fm-primary-turnend-guard.js` reacts to root execution settlement; the V2 boundary scopes lifecycle and tool hooks to the plugin home and excludes child sessions, including those whose creation was not observed.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses V2 `ctx.session.prompt` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
Legacy follow-up evidence was verified in the V1 interactive TUI; the V2 worker live guard does not claim primary watcher continuity.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it through V2 `ctx.session.prompt`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt registers `ctx.tool.hook("execute.before", ...)`; throwing prevents execution.
