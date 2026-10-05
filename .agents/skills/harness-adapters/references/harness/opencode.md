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

OpenCode V2 is supported for crewmates and scouts only; primary and persistent secondmate support is deferred.
The primary default definitions reject V2 `setup(ctx)` before registering hooks, and `../../../bin/fm-spawn.sh` rejects V2 secondmate launches before allocation.
Use another verified harness for a Firstmate primary or secondmate.
Server events identify a session's location and parent, but do not prove which same-directory root a client selected.
The [V2 boundary](../../../../../.opencode/plugins/lib/fm-v2-plugin.js) therefore never selects or prompts a primary root.
[Supervision verification](../../../../../docs/verification/supervision.md#opencode-v2-primary-boundary) owns the current refusal evidence.

The named V1 callback implementations remain for legacy primary compatibility.
Their watcher, turn-end, pre-tool, and startup mechanics are documented in `../../../docs/supervision-protocols/opencode.md` and `../../../docs/sessionstart-nudge.md`.
V1 worker launch is not supported by the current spawn adapter.
