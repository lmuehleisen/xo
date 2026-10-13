# Kiro CLI

Kiro's interactive `kiro-cli` TUI is verified as a crewmate and scout adapter on the V2 engine.
Primary and secondmate operation are unsupported because there is no Kiro supervision protocol.
`../../../../../docs/verification/kiro.md` owns the dated macOS and upstream Linux evidence and its live refresh command.

## Adapter facts

| Surface | Verified fact |
| --- | --- |
| Binary | Absolute `kiro-cli` from `PATH`; launch refuses if absent; |
| Launch | `KIRO_HOME=<per-task> kiro-cli chat --agent-engine v2 --agent firstmate --model <id> --effort <level> --trust-all-tools "<brief>"`; the positional brief auto-submits in the interactive TUI; Never use `--no-interactive`, whose model selection is unsupported on the measured macOS build; |
| Busy state | V2 `userPromptSubmit` and `stop` hooks write `kiro-hook`; a task-bound native turn marker can settle a stale busy hook after manual Escape; `../../../../../bin/fm-busy-lib.sh` owns binding, trust, and conservative fallback; Rendered text is never a Kiro worker-state source; |
| Turn end | A successful generation-bound `stop` event touches the task's `turn-ended` notification; Escape emits no `stop`; |
| Interrupt | One Escape cancels the agent turn and leaves an empty composer; The control plane invalidates the busy record to `unknown`, without claiming cancellation acknowledgement; A running tool process survives Escape until it finishes or the session exits; follow an interrupt with exit or relaunch when the tool must stop; |
| Exit | `/quit`, one Enter; the process exits and may print `Session ended.` and `Resume with: kiro-cli --resume-id <id>`; |
| Resume | `--resume-id <id>` or cwd-scoped `--resume`; positional prompts work on resume; Firstmate automates deterministic relaunch from the durable brief; |
| Model | Bare `model_id` from `kiro-cli chat --agent-engine v2 --list-models -f json`, such as `auto` or `claude-opus-5.5`; A reachable catalog that omits the requested id refuses launch; an unreachable or unparseable listing launches unvalidated with a notice under the spawn owner's bounded probe; Auto does not disclose the served model; |
| Effort | `--effort low\|medium\|high\|xhigh\|max`; the full vocabulary passes through; |
| Quota | The native harness maps to quota-axi's `kiro` provider; the existing Pi provider route is separate; |
| Detection | Anchored `kiro-cli` and `kiro-cli-chat` ancestry; the nearer macOS ACP backend outranks foreign inherited harness markers; macOS exports `KIRO_SESSION_ID`, `KIRO_AGENT_ENGINE=v2`, `KIRO_VERSION`, and `KIRO_TURN_MARKER_DIR`, but identity remains structural for compatibility with the markerless upstream Linux build; |
| Composer | Bare `›` (U+203A); The 2.24.0 idle placeholder uses `38;2;158;158;158`; 256-color panes can use `38;5;247`; The Kiro-only gray ceiling and hinted idle row in `../../../../../bin/fm-composer-lib.sh` classify it empty without widening other harnesses' rules; Busy delivery uses `Kiro is working`; |
| Skill | No separate skill-command form is verified; use ordinary language through the data plane; |

## Per-task configuration and credentials

`--agent` accepts a name rather than a path.
Spawn writes `state/<id>.kiro-home/agents/firstmate.json` and two executable hook scripts under that home, then relocates `KIRO_HOME` to reach them.
The same home carries `settings/cli.json` with `chat.disableTrustAllConfirmation=true`, suppressing the otherwise blocking trust-all confirmation modal, and holds the task's sessions.
No project `.kiro/` or real `~/.kiro` agent, setting, or session is changed.
Hook commands are single-token absolute script paths, so spawn refuses a per-task home path containing whitespace.

Relocation preserves native login on both measured platforms: macOS stores auth in `~/Library/Application Support/kiro-cli/data.sqlite3`, and upstream Amazon Linux 2 uses `~/.local/share/kiro-cli/data.sqlite3`.
These stores are neither copied nor edited by the adapter.
An authentication failure remains a launch blocker rather than permission to change the operator's credentials.

`../../../../../bin/fm-control-lib.sh` owns retirement of generation-bound wiring on relaunch, and `../../../../../bin/fm-teardown.sh` removes the entire per-task home.

## Limits

The native marker fallback requires `jq` and a marker positively bound by the submit hook to that turn's generation, sequence, and process owner.
Missing or unproven bindings retain the hook verdict; malformed or inaccessible native state and a lost process owner cannot establish idle.
The control-plane cancellation claim remains unconfirmed even when the manual-Escape marker path can establish that the agent turn ended.
V3/KAS, primary supervision, secondmates, and live rendered-surface verification on backends other than tmux remain outside this adapter's verified scope.
