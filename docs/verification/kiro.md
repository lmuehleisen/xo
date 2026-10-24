# Kiro CLI adapter verification

Maintainer-verification record for the interactive V2 `kiro` crewmate/scout adapter.
The adapter reference is [Kiro CLI](../../.agents/skills/harness-adapters/references/harness/kiro.md); executable busy trust belongs to `bin/fm-busy-lib.sh`.
Run the opt-in guard after each Kiro upgrade because the process names, hooks, composer, and native marker are vendor-controlled surfaces.
The guard submits three small synthetic prompts under an isolated `KIRO_HOME` and private tmux server.

## macOS verification

Date: 2026-10-13 (UTC).
Tool: `kiro-cli 2.24.0`, native macOS app installation; backend: tmux.
The lab changes no agent, setting, or session under the real `~/.kiro`.

Exact refresh command:

```sh
FM_KIRO_SIGNALS_LIVE=1 FM_KIRO_LIVE_MODEL=claude-opus-5.5 bash tests/fm-kiro-signals-live-e2e.test.sh
```

Relevant output:

```text
ok - the real kiro busy footer matches the kiro delivery guard in flight
ok - the real kiro foreground group carries the anchored 'kiro-cli' name and the liveness probe reads it alive
ok - the ancestry walk reads the live kiro process as 'comm kiro'
ok - the real kiro worker processed its launch prompt
ok - the real kiro V2 userPromptSubmit and stop hooks both fire per turn and run their scripts through
ok - the interactive session records its requested model (claude-opus-5.5)
ok - the real styled Kiro idle composer classifies empty
ok - the real Kiro turn binds its native marker to the hook generation and sequence
ok - a single Escape cancels the real kiro turn
ok - manual Escape reads idle through the native marker even without a stop hook
ok - Escape ends the agent turn while its running tool process remains alive
ok - /quit stops the real kiro process and prints its resume-id line
ok - /quit also stops the interrupted tool process
```

### Process and environment

The hook's parent chain, with paths and process ids normalized, is:

```text
kiro-cli-chat acp -> bun tui.js -> kiro-cli-chat chat -> kiro-cli -> shell -> tmux
```

The foreground command is `kiro-cli`.
The nearest `kiro-cli-chat` process also identifies Kiro, so the adapter anchors both names rather than searching arbitrary arguments for `kiro`.
Hook subprocesses export these names on 2.24.0:

```text
KIRO_AGENT_ENGINE KIRO_CHAT_CLI_BIN KIRO_CHAT_CLI_BIN_IDENTITY
KIRO_CHAT_CLI_FALLBACK_BIN KIRO_CLI_ACP_CLIENT_NAME KIRO_CONTENT_COLLECTION_ENABLED
KIRO_ENABLED_FEATURES KIRO_FEED_FILE KIRO_HOME KIRO_INFRA_SAFETY_ROLLOUT_ENABLED
KIRO_LITE_ROLLOUT_ENABLED KIRO_LOCAL_SANDBOX_ROLLOUT_ENABLED KIRO_SESSION_ID
KIRO_TELEMETRY_CLIENT_ID KIRO_TELEMETRY_ENABLED KIRO_TELEMETRY_OTLP_ENDPOINT
KIRO_TUI_READY_FILE KIRO_TUI_READY_TOKEN KIRO_TUI_TELEMETRY_KEY_FILE
KIRO_TURN_MARKER_DIR KIRO_VERSION KIRO_VERSION_OVERRIDE KIRO_VOICE_SUPPORTED
```

`KIRO_AGENT_ENGINE=v2` and `KIRO_VERSION=2.24.0` agree with launch.
No credential or telemetry-token values are needed for detection or recorded here.

### Native state and cancellation

`userPromptSubmit` and `stop` execute the generated script form, including shell redirection, once per normal turn.
A manual Escape ends the agent turn without `stop` and removes its native marker from `~/Library/Application Support/kiro-cli/run/turn-markers/`.
The marker contains `pid`, `engine`, `session_interface`, `turn_started_at_ms`, `last_alive_at_ms`, `owner_started_at_s`, and `version_full`.
The submit hook can bind that marker through its own ancestry before cancellation; the classifier then reads idle after removal while the same owner remains alive.
A missing binding preserves the hook verdict, and a lost owner or unreadable native state does not prove idle.
Portable regressions drive the hook record, native marker, process birth, generation, sequence, and rendered footer apart, including a newer marker on the same owner and an unrelated owner's marker.

The control plane independently invalidates the generation-bound record to `unknown` after delivering Escape, matching Devin's conservative cancellation pattern.
Escape leaves an already running tool process alive until completion or session exit; ending the agent turn alone does not stop that process.
A supervisor that must stop tool work should follow interrupt with exit or relaunch.

### Composer

The live styled idle row was:

```text
›  [ESC][38;2;158;158;158mask a question or describe a task ↵[ESC][39m
```

It classified `empty` through the shared composer with `FM_COMPOSER_HARNESS=kiro`.
Typed text remains pending in the portable regression.
The upstream captures additionally establish the equivalent `38;5;247` gray on 2.21.5 and a default-foreground hinted idle row on 2.28.0.
Those encodings remain Kiro-scoped; the generic gray threshold is unchanged.

### Authentication and model selection

Native macOS auth resides at `~/Library/Application Support/kiro-cli/data.sqlite3`, outside `KIRO_HOME`.
The file's existence and successful lab authentication establish relocation without reading or copying credential contents.
`KIRO_HOME=<lab> kiro-cli whoami` succeeds, and both interactive lab turns authenticate without a login prompt.
The live guard launched with `--model claude-opus-5.5 --effort low`, and the isolated session recorded that model.
The model catalog is `kiro-cli chat --agent-engine v2 --list-models -f json`; `--model` uses a bare `model_id`, and `--effort` accepts `low|medium|high|xhigh|max`.
Interactive model selection is required: the 2.24.0 headless `--no-interactive` path can reject model selection and silently run Auto, so no adapter launch uses it.
Auto does not record which model was served.

## Publish hook and context verification

Date: 2026-10-14 (UTC).
Tool: `kiro-cli 2.24.0`, V2 engine; backend: tmux.
Refresh with the exact opt-in command above.
The [CLI 2.x reference](https://kiro.dev/docs/cli/2x-reference/) documents embedded camelCase hooks and exit 2 returning stderr to the agent while blocking a `preToolUse` call.
The [agent configuration reference](https://kiro.dev/docs/custom-agents/configuration-reference/#disabling-default-resource-inheritance) documents the resource-inheritance switch; its V2 behavior is verified live here.

The shell hook receives this shape on stdin, with identifiers and paths normalized:

```json
{"hook_event_name":"preToolUse","cwd":"/tmp/example-workspace","session_id":"example-session","tool_name":"shell","tool_input":{"command":"gh --version"}}
```

Both the canonical `shell` matcher and its `execute_bash` alias matched live shell calls.
The generated script forwards stdin unchanged to `bin/fm-arm-pretool-check.sh --claude --publish-only`.
The policy's exit 2 blocks the entire shell call before its leading marker can run, and Kiro delivers the stderr object as text in an error tool result beginning `PreToolHook blocked the tool execution:`.
An allowed call exits 0 silently and executes normally; no Kiro-specific payload or decision adapter is needed.
The guard uses a repository-free workspace and a `gh pr create --dry-run` command without a destination, then a read-only `gh --version` call, so no public write is attempted.

Relevant output:

```text
ok - the real Kiro context retains root and nested AGENTS, steering inclusion, and project/global skills without README
ok - the real Kiro shell preToolUse hook blocks a gh dry-run before execution and returns its reason to the model
ok - the real Kiro publish hook allows a read-only gh call
```

Omitting resources or setting `resources=[]` inherits `README.md` on this V2 build.
The task-local `chat.disableInheritingDefaultResources=true` setting and explicit resource selectors remove that extra context while including root and nested `AGENTS.md`, legacy `AmazonQ.md`, project/per-task steering, and project/per-task skill metadata.
The recursive instruction resource matches both root `AGENTS.md` and `services/api/AGENTS.md`; restoring only the root resource cannot establish nested instruction coverage.
The guard checks `/context show` directly with matching fixture files, including the nested instruction file, always-included steering, and manual steering that must stay excluded.
The selector list belongs to `bin/fm-spawn.sh`; project `AGENTS.md` remains available to workers.

## Regression and upstream scope

```sh
bash bin/fm-test-run.sh tests/fm-kiro-harness.test.sh tests/fm-busy-adapter-wiring.test.sh tests/fm-control.test.sh tests/fm-composer-lib.test.sh
```

The portable suites cover launch isolation, model refusal and timeout behavior, effort flags, hook generations, native-marker fallback, composer scope, lifecycle keys, teardown, and crewmate/scout publish-policy and resource wiring.
On Linux, kiro-cli 2.21.4 on Amazon Linux 2 under a toolbox/aim-sandbox wrapper kept native auth at `~/.local/share/kiro-cli/data.sqlite3` and exported no `KIRO_*` identity marker, so anchored process ancestry remains the portable detection mechanism.
The live refresh above covers macOS; Linux regression and lint are CI-enforced.

Unverified boundaries: V3/KAS, primary and secondmate operation, and rendered-surface behavior on backends other than tmux.
No StopFailure or SessionEnd-equivalent V2 hook is credited; an abnormal end without a usable marker binding remains conservative.
The guard checks `/quit` process exit; a resume line can be absent from a restored full-screen terminal, so the line itself is conditional rather than an exit requirement.
