# Fork divergences

This fork-only ledger owns which differences between this fork and upstream [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) are deliberate.
README "Fork: what differs" stays the owner of user-visible fork behavior; an entry here names its README bullet rather than restating it, and adds the class, seam, guard, and upstream position.
The [upstream integration checklist](upstream-integration.md) runs every guard named here and classifies each shared-file difference against these entries.

Divergence from upstream is a cost to weigh, not a hard gate.
A divergence is justified when it serves reliable local use, familiar tools, or less prescriptive workflows and no upstream option achieves it, taking the upstreamable shape wherever that shape is free.
A divergence should be resisted when an upstream mechanism or option already covers it, or when a free upstreamable shape was not taken; alignment never justifies contorting a design.
A fork PR that adds or widens a difference in a shared file names the entry it adds or extends here, or says why the difference is incidental, and states its upstream cost.

Classes:

- `intended`: kept indefinitely; an upstream change that breaks its guard is adapted to keep this behavior, never the reverse.
- `carried`: a fork fix or port kept only until upstream ships an equivalent; each integration run checks whether it can be dropped.
- `incidental`: no reason to differ; realign when convenient.

A `Seam:` claims only the hunks that carry its entry's behavior, not the whole file; a hunk in a file shared with upstream that no entry's scope covers, or a fork-only path that no entry's `Seam:` or `Guard:` and no incidental item names, is unclassified, and the integration run reports it.
An entry whose convergence is still under investigation says so in its `Class:` line and is not a decision.

Each entry has these one-line fields: `Intent:` with its source, `Class:`, `Seam:` naming the files (fork-only or shared), `Guard:` naming the test that fails if the divergence is lost (or `none`, which is itself a finding), and `Upstream:` with what upstream does instead and, for carried entries, what would let the fork drop it.

## Intended

### gh-not-gh-axi

- Intent: GitHub operations use plain `gh`; README "No required `gh-axi`".
- Class: intended.
- Seam: `bin/fm-pr-merge.sh`, `bin/fm-bootstrap.sh`, and the `gh-axi` wording in `bin/fm-brief.sh`, `bin/fm-dod-lib.sh`, `bin/fm-project-mode.sh`, `bin/fm-teardown.sh`, the timing-artifact download in `docs/fm-test-portable-shards.md`, and the bearings, bootstrap-diagnostics, project-management, and secondmate-provisioning skills (shared); upstream's optional, inert `gh-axi` fallback in `fm_pr_github_read_record` is deliberately kept.
- Guard: `tests/fm-bootstrap.test.sh` `test_dropped_tools_are_not_required`.
- Upstream: requires `gh-axi`.

### no-chrome-devtools-axi

- Intent: browser work uses harness browser tools or Playwright; README "No required `chrome-devtools-axi`".
- Class: intended.
- Seam: `bin/fm-bootstrap.sh`, the browser line in `bin/fm-brief.sh`, and the bootstrap-diagnostics skill (shared).
- Guard: `tests/fm-bootstrap.test.sh` `test_dropped_tools_are_not_required`.
- Upstream: requires `chrome-devtools-axi`.

### optional-lavish-axi

- Intent: Lavish is optional, off by default, hook-free, version-pinned, and loopback-only; chat stays the primary answer path, and an answers board carries decision cards only; README "Optional `lavish-axi`".
- Class: intended.
- Seam: `bin/fm-lavish-lib.sh` and `bin/fm-lavish.sh` (fork-only), `bin/fm-bearings-board.sh`, `.agents/skills/bearings/assets/board-template.html`, the scout-brief Lavish line and `--lavish` in `bin/fm-brief.sh`, the Lavish install hint and toggle line in `bin/fm-bootstrap.sh` (plus the `lavish-reply-compatible` probe that `bin/fm-procevent-lavish.sh` calls), `bin/fm-config-inherit-lib.sh`, the pinned environment in `bin/fm-procevent-lavish.sh`, fork-only `docs/lavish.md` and `docs/verification/lavish-remote-forward.md`, the live test's family entry in `bin/fm-test-run.sh`, and the Lavish wording in the bearings, bootstrap-diagnostics, captain-hold-lifecycle, operational-home-layout, and process-event-sources skills (shared).
- Guard: `tests/fm-lavish.test.sh`; `tests/fm-bearings-board.test.sh` `test_build_does_not_invoke_lavish` and the Lavish mode tests; `tests/fm-brief.test.sh` `test_scout_lavish_follows_toggle_and_override`; `tests/fm-bootstrap.test.sh` `test_dropped_tools_are_not_required` and `test_lavish_opt_in_reports_unavailable_cli`; `tests/fm-procevent.test.sh`, whose upstream legacy-reply stand-ins report the pin, with "an off-pin older Lavish is refused before any reply is posted"; live, `tests/fm-bearings-board-lavish-live-e2e.test.sh`.
- Upstream: requires `lavish-axi`, installs it with `setup hooks`, reports its version floors at bootstrap, always drives an interactive board with merge and dispatch controls, and lets Lavish bind a Tailscale address by default.

### no-mistakes-optional

- Intent: no required pipeline; `no-mistakes` delivery tokens ship as `direct-PR` unless `config/no-mistakes` opts in; README "No required `no-mistakes`".
- Class: intended.
- Seam: `bin/fm-dod-lib.sh`, `bin/fm-brief.sh` (including the `config/wait-no-turns` waiting section, which names no-mistakes wait commands only in a pipeline ship brief), `bin/fm-promote.sh`, `bin/fm-spawn.sh`, `bin/fm-project-mode.sh` (the registry and default remap to `direct-PR`), `bin/fm-home-seed.sh` (no pipeline initialization), `bin/fm-bootstrap.sh`, `bin/fm-pr-check.sh`, `bin/fm-remote-home-provision.sh`, `bin/fm-teardown.sh`, `bin/fm-test-run.sh`, `bin/fm-crew-state.sh`, `bin/fm-inactive-reconcile.sh`, the no-mistakes wording in shared skills under `.agents/skills/` and their harness references, the `CONTRIBUTING.md` required-checks line, and the `VISION.md` Scope line (shared); upstream's `.github/workflows/no-mistakes-required.yml` is deleted.
- Guard: `tests/fm-brief.test.sh` `test_no_mistakes_*` and `test_workers_wait_without_spending_turns`; `tests/fm-task-delivery.test.sh` `test_no_mistakes_*`; `tests/fm-bootstrap.test.sh` `test_no_mistakes_opt_in_reports_unavailable_cli`.
- Upstream: requires the no-mistakes pipeline for every ship and enforces its minimum version at bootstrap.

### reviewed-worker-permissions

- Intent: `config/crew-permissions` (automatic review by default, manual review as an option) replaces upstream's `config/claude-permission-mode`, so Claude and Codex worker launches never bypass permissions, while agy and Devin have their own entries below and other harnesses such as OpenCode, Cursor, Muse, and Rovo keep upstream's bypass launch; README "Reviewed worker permissions".
- Class: intended.
- Seam: permission resolution and `launch_template` in `bin/fm-spawn.sh`, and `docs/configuration.md` (shared).
- Guard: `tests/fm-spawn-dispatch-profile.test.sh` `test_worker_permission_modes`, `test_invalid_worker_permissions_refuse`, and `test_upstream_claude_permission_mode_file_cannot_select_bypass`; the negative bypass assertions in `tests/fm-claude-trust.test.sh`.
- Upstream: bypasses permissions by default, with automatic review as a Claude-only opt-in through `config/claude-permission-mode`; its task-channel `--add-dir` grant for Claude launches (upstream #5884) is taken beside the fork's state and task-data grant rather than replacing it.

### codex-reviewed-launch

- Intent: Codex workers launch with `--approve-for-me`, or with manual review when `config/crew-permissions` is `manual`, never with approvals and sandbox bypassed; README "Reviewed worker permissions".
- Class: intended.
- Seam: the Codex arms of `launch_template` in `bin/fm-spawn.sh` (shared) print the selected permission flags in place of upstream's `--dangerously-bypass-approvals-and-sandbox`; an alternative would keep the template lines byte-identical to upstream and substitute the flags at launch time instead.
- Guard: `tests/fm-spawn-dispatch-profile.test.sh` `test_worker_permission_modes` and `test_codex_secondmate_launch_keeps_the_hook_layer`.
- Upstream: launches Codex with `--dangerously-bypass-approvals-and-sandbox` and has no Codex permission option; an equivalent upstream option would reduce this entry to a default value.

### agy-permission-posture

- Intent: agy workers default to `--mode accept-edits` rather than a blanket skip, and bypass runs only with `--agy-bypass` under the policed permission hook and judge tier.
- Class: intended.
- Seam: fork-only `bin/fm-agy-lib.sh`, `bin/fm-agy-permission-policy.sh`, `bin/fm-command-policy-lib.sh`, `bin/fm-judge-tier-lib.sh`, and `bin/fm-agy-audit.sh`, including generation-bound approval evidence and cleanup audit, plus small spawn hooks in `bin/fm-spawn.sh` and the audit prerequisite in `docs/configuration.md` (shared).
- Guard: `tests/fm-agy-permission-policy.test.sh`; `tests/fm-agy-harness.test.sh`; the opt-in live guard `tests/fm-agy-bypass-live-e2e.test.sh`.
- Upstream: its own agy adapter has no fork permission layer.

### devin-permission-layer

- Intent: Devin workers run in reviewed mode behind firstmate's permission hook, never in bypass.
- Class: intended.
- Seam: fork-only `bin/fm-devin-permission-policy.sh` and `bin/fm-devin-lib.sh`, plus small spawn hooks in `bin/fm-spawn.sh` (shared).
- Guard: `tests/fm-devin-permission-policy.test.sh`; the opt-in live guard `tests/fm-devin-permission-policy-live-e2e.test.sh`.
- Upstream: its own Devin adapter launches with `--permission-mode dangerous`.

### read-only-web-lookups

- Intent: the agy and Devin permission layers approve GET-shaped fetches for any host, so read-only web lookups are not blocked by a host allowlist.
- Class: intended.
- Seam: the fork-only agy and Devin policy libraries listed above.
- Guard: `tests/fm-agy-permission-policy.test.sh`; `tests/fm-devin-permission-policy.test.sh`.
- Upstream: no equivalent layer.

### no-global-harness-settings-writes

- Intent: never write the captain's global `~/.gemini` settings.
- Class: intended.
- Seam: upstream's `bin/fm-agy-trust.sh`, which pre-registers worktrees in `~/.gemini/antigravity-cli/settings.json`, is deleted.
- Guard: none.
- Upstream: pre-registers each agy worktree in the global settings file.

### away-merge-grants

- Intent: while the away-posture record exists, a merge proceeds only for a `yolo` task or one granted with `--grant` at `/afk`, and the away words never grant a merge; `AGENTS.md` section 7.
- Class: intended.
- Seam: the merge-grant list in `bin/fm-afk-contract.sh`, the away-mode gate in `bin/fm-merge-authority-lib.sh` and `bin/fm-pr-merge.sh`, the `yolo` and `away-grant` authority values in `bin/fm-merge-outcome-lib.sh` and `bin/fm-contributions.jq`, and the away merge rule in `bin/fm-branch-prompt.sh` (shared).
- Guard: `tests/fm-afk-contract.test.sh` `test_merge_grants_come_only_from_the_grant_flag`; `tests/fm-pr-merge.test.sh` `test_away_grant_and_yolo_and_hold_for_return`; `tests/fm-contributions.test.sh`.
- Upstream: keeps no per-task merge-grant list and lets the away session merge green work under its reading of the away words; its rule that a quiet-mode record keeps merges attended (upstream #6064) is taken ahead of the fork's grant check.

### remote-less-local-only

- Intent: explicit `local-only` ships start from local `main` or `master` with no remote, refusing dirty or divergent bases; README "Remote-less local work".
- Class: intended.
- Seam: pool-base handling in `bin/fm-spawn.sh` and its `local_default_branch` helper in `bin/fm-ff-lib.sh` (shared).
- Guard: `tests/fm-spawn-pool-base-freshen.test.sh` `test_originless_pool_launches_without_a_freshness_fetch` and `test_originless_dirty_pool_refuses_without_discarding_work`.
- Upstream: requires a remote to freshen the pool base.

### durable-approval-waits

- Intent: completed ship work awaiting merge stays tracked, visible in Bearings, and quietly supervised after its worker is verified stopped; README "Durable approval waits".
- Class: intended.
- Seam: `bin/fm-captain-hold.sh`, including the completed-ship exception to self-inventory rejection, `bin/fm-busy-lib.sh`, and the watcher (shared).
- Guard: fork-only `tests/fm-captain-hold-completed-ship.test.sh`, `tests/fm-watch-completed-ship-hold.test.sh`, and `tests/fm-fleet-snapshot-captain-hold.test.sh`.
- Upstream: no completed-ship hold; its origin-bound inventory validation is retained, with a narrow exception for a completed ship inventorying its own durable approval hold.

### upstream-integration-tooling

- Intent: upstream arrives through real-merge integration runs and the updater only fast-forwards; README upstream integration paragraph.
- Class: intended.
- Seam: fork-only `docs/upstream-integration.md`, `docs/fork-divergences.md`, and `bin/fm-upstream-callsite-scan.sh`, plus the updater skill (shared).
- Guard: fork-only `tests/fm-upstream-callsite-scan.test.sh`.
- Upstream: not applicable.

### fork-documentation

- Intent: the fork's prose describes the fork rather than upstream: README "Fork: what differs" and every fork wording in shared prose that states the behavior of another entry here, plus the inventory rows that register fork-only prose.
- Class: intended.
- Seam: any shared prose surface, including `README.md`, `AGENTS.md`, `CONTRIBUTING.md`, `VISION.md`, `docs/` (for example `docs/configuration.md`, `docs/architecture.md`, and `docs/scripts.md`), and skill prose under `.agents/skills/`, limited to hunks that describe another entry's behavior; fork-only records such as `docs/verification/runtime-backends-fork.md`; and the `docs/documentation-audiences.json` rows that classify fork-only surfaces such as this ledger and `docs/upstream-integration.md`, while any other hunk in these files is still classified on its own.
- Guard: none; the integration run's ledger-update step reviews these files against the fork each run.
- Upstream: describes upstream's own tools, pipeline, and permission defaults.

### private-incident-evidence

- Intent: incident evidence stays in private task reports, and public PR text carries at most a sanitized reproduction.
- Class: intended.
- Seam: the two evidence-placement lines in `.agents/skills/firstmate-coding-guidelines/SKILL.md` (shared).
- Guard: none; the integration run's ledger-update step reviews the skill each run.
- Upstream: allows incident evidence in PR text.

### publish-gate

- Intent: pushes, commit messages, and public PR text pass a configurable publish gate, with a larger body cap only for verified upstream integration records; `docs/configuration.md` "Publish guard".
- Class: intended.
- Seam: fork-only `bin/fm-publish-gate.sh`, `bin/fm-publish-judge.sh`, `bin/fm-gh-publish-policy.mjs`, `bin/fm-install-gitleaks.sh`, and `.github/workflows/pr-text.yml`, plus the `publish-identity` job in `.github/workflows/ci.yml`, the publish-policy hunks in `bin/fm-arm-pretool-check.sh` (shared), where a command the publish policy must see fails closed, the nested publish-guard inheritance in `bin/fm-config-inherit-lib.sh` and `bin/fm-remote-inherit.sh`, and the gate hunks in `bin/fm-git-strip-ai-trailers.sh` and `bin/fm-spawn.sh` (shared), where `config/keep-ai-trailers` skips only the trailer strip and the per-task hooks stay installed so the gate still runs.
- Guard: fork-only `tests/fm-publish-gate.test.sh`, `tests/fm-publish-judge.test.sh`, and `tests/fm-spawn-identity-pin.test.sh`; the keep-ai-trailers cases in `tests/fm-spawn-dispatch-profile.test.sh`; the publish fail-closed cases in `tests/fm-arm-pretool-check.test.sh`; fork-only `tests/fm-pi-worker-publish-policy-live-e2e.test.sh`.
- Upstream: has no publish gate, and `config/keep-ai-trailers` removes the per-task hooks entirely.

### devin-and-agy-first-class

- Intent: Devin and agy are routine worker runtimes.
- Class: intended.
- Seam: fork-only `bin/fm-devin-lib.sh`, `bin/fm-agy-lib.sh`, `bin/fm-agy-hook.sh`, `.agents/hooks.json` (agy primary hooks), `docs/supervision-protocols/agy.md`, `tests/fm-tmux-submit-busy-agy.test.sh`, and `tests/agy-primary-live-probe.py`, plus the shared adapter hunks in `bin/fm-harness.sh`, `bin/fm-dispatch-resolve.sh` (the agy and Devin effort table), `bin/fm-secondmate-liveness-lib.sh` (agy among the verified secondmate harnesses), `bin/fm-composer-lib.sh`, `bin/fm-busy-lib.sh`, `bin/fm-control-lib.sh`, `bin/fm-session-lock-lib.sh`, and `bin/fm-supervision-instructions.sh`.
- Guard: `tests/fm-devin-harness.test.sh`; `tests/fm-agy-harness.test.sh`; `tests/fm-composer-agy.test.sh`; `tests/fm-dispatch-resolve.test.sh`; `tests/fm-tmux-submit-busy-agy.test.sh`; the opt-in live guards `tests/fm-agy-primary-live-e2e.test.sh` and `tests/fm-agy-observer-live-e2e.test.sh`.
- Upstream: ships its own Devin and agy adapters; how much of the fork's mechanics to keep is the open question in the carried entries below.

### remote-check-runner

- Intent: lint and behavior tests can run against committed HEAD on a configured Linux runner; `CONTRIBUTING.md` Development.
- Class: intended.
- Seam: fork-only `bin/fm-remote-check.sh`, its configuration and script-reference prose, and the remote-lint instruction in `.agents/skills/firstmate-coding-guidelines/SKILL.md`.
- Guard: fork-only `tests/fm-remote-check.test.sh`.
- Upstream: no equivalent remote-check entry point.

### private-local-skills

- Intent: installation-specific skills remain untracked and are discoverable in worker briefs.
- Class: intended.
- Seam: the `.agents/skills/local-*/` ignore rule in `.gitignore` and local-skill discovery in `bin/fm-brief.sh`.
- Guard: `tests/fm-brief.test.sh` local-skill listing case.
- Upstream: no local-skill brief inventory.

## Carried

### devin-adapter-mechanics

- Intent: the fork's own Devin adapter, which predates upstream's; converged onto upstream's private config writer and its common portable suite and live guard (the change that added `tests/fm-devin-fork-harness.test.sh`).
- Class: carried; after that convergence the remaining fork mechanics are plain `exit`, the SWE-2 Max default, the full-frame composer selector, and legacy worktree-wiring cleanup.
- Seam: fork-only `bin/fm-devin-lib.sh`, `bin/fm-composer-devin-lib.sh`, and `tests/devin-live-helpers.sh`; in shared files, the lines marked `Fork` in `tests/fm-devin-harness.test.sh` and `tests/fm-devin-signals-live-e2e.test.sh`, and the Devin selector's source line and calls in `bin/fm-composer-lib.sh`.
- Guard: `tests/fm-devin-harness.test.sh`; `tests/fm-devin-fork-harness.test.sh`; `tests/fm-composer-devin.test.sh`; `tests/fm-control-relaunch-bindings.test.sh` (relaunch away from Devin retires only firstmate-owned wiring); the opt-in live guards `tests/fm-devin-signals-live-e2e.test.sh` and `tests/fm-devin-rate-limit-retry-live-e2e.test.sh`.
- Upstream: exits with `/quit`, reads the composer through the generic glyph rules, and recognizes only `esc twice`; the full-frame selector and the `esc again` signal are candidates to offer upstream.

### agy-adapter-mechanics

- Intent: the fork's first-class agy adapter.
- Class: carried, open convergence question under investigation; not decided.
- Seam: fork-only `bin/fm-agy-lib.sh`, and the large fork diff in shared `tests/fm-agy-harness.test.sh`.
- Guard: `tests/fm-agy-harness.test.sh`.
- Upstream: ships its own agy adapter; converging onto it while keeping `agy-permission-posture` is the open question.

### worktree-leases

- Intent: durable Treehouse task leases; the fork dropped upstream's slot-claim files.
- Class: carried, open convergence question; not decided.
- Seam: fork-only `bin/fm-worktree-claims-lib.sh`, plus its shared callers, including spawn lease receipts and prelaunch rollback in `bin/fm-spawn.sh` and records-only stale-claim retirement in `bin/fm-teardown.sh`.
- Guard: fork-only `tests/fm-control-relaunch-bindings.test.sh` (a relaunch reuses its own claim and refuses another task's); `tests/fm-spawn-prelaunch-lease-return.test.sh`; `tests/fm-spawn-prelaunch-rollback.test.sh`.
- Upstream: has its own slot-owner claims, with further work in open PRs; which design is better is unresolved; upstream #6213 lets a stale record retire records-only when its slot's claim names another task, which the fork does not take because it reads those claims, so a lease held by another holder still refuses here.

### claude-trust-escape

- Intent: decline Claude's external-import prompt correctly.
- Class: carried.
- Seam: `bin/fm-claude-trust.sh` (shared).
- Guard: `tests/fm-claude-trust.test.sh`.
- Upstream: still refuses on an Escape dismissal; drop once upstream adopts the fork's rule.

### pr-poll-identity

- Intent: inode-only identity where upstream admits a gap.
- Class: carried.
- Seam: PR poll identity in `bin/fm-pr-lib.sh` and `bin/fm-watch.sh` (shared); a small remainder after the last integration took upstream's stricter rule elsewhere.
- Guard: none.
- Upstream: drop once upstream closes the gap.

### doorbell-stranded-enter

- Intent: recover a stranded steering doorbell.
- Class: carried.
- Seam: steering doorbell delivery in `bin/fm-send.sh`, `bin/fm-task-inbox-lib.sh`, `bin/fm-remote-secondmate-control.sh`, `bin/fm-watch.sh`, and `bin/fm-composer-lib.sh` (shared).
- Guard: none.
- Upstream: overlaps upstream PR #4485; drop once that lands equivalently.

### tmux-presence

- Intent: exact tmux session inventory, now routed through upstream's window inventory.
- Class: carried.
- Seam: exact session/window inventory in the tmux backend, `bin/fm-backend.sh`, and `bin/fm-crew-state.sh`, plus immutable window identity recorded by `bin/fm-spawn.sh` and checked before endpoint cleanup in `bin/fm-teardown.sh` (shared).
- Guard: `tests/fm-backend-tmux-smoke.test.sh`; `tests/fm-tmux-agent-liveness.test.sh` exact inventory cases; `tests/fm-teardown.test.sh` missing and replaced window cases.
- Upstream: drop the remainder once upstream's inventory covers it.

### rehold-reason

- Intent: preserve a captain-hold reason on re-hold, including trailing newlines and newline-only reasons.
- Class: carried.
- Seam: `bin/fm-captain-hold.sh` (shared).
- Guard: fork-only `tests/fm-captain-hold-rehold.test.sh`.
- Upstream: encodes hold reasons so punctuation and line breaks survive and validates their origin, but does not archive superseded reasons; the fork keeps archival preservation around those upstream operations.

### stow-audit

- Intent: stow-pass before-state snapshot and verification.
- Class: carried.
- Seam: `bin/fm-stow-audit.sh` and the stow skill.
- Guard: fork-only `tests/fm-stow-audit.test.sh`.
- Upstream: not upstream.

### claude-stop-fixes

- Intent: Claude StopFailure recovery, auto-arm timeout, away-digest integrity, a dropped Enter on spawn, and recovery of an away digest left in the primary's composer.
- Class: carried.
- Seam: `bin/fm-claude-stop-autoarm.sh`, `bin/fm-wake-lib.sh`, `bin/fm-watch-arm.sh`, `bin/fm-supervise-daemon.sh`, `bin/fm-afk-launch.sh`, `bin/fm-afk-start.sh`, `bin/fm-tmux-lib.sh`, `bin/fm-composer-lib.sh`, `bin/backends/tmux.sh`, `bin/fm-spawn.sh`, `bin/fm-test-run.sh`, and the `StopFailure` hook registration in `.claude/settings.json`, limited to the hunks those PRs added (shared).
- Guard: `tests/fm-claude-stop-autoarm.test.sh`; `tests/fm-turnend-guard.test.sh`; `tests/fm-watch-arm.test.sh`; `tests/fm-daemon.test.sh`; `tests/fm-afk-launch.test.sh`; `tests/fm-backend-tmux-smoke.test.sh`; `tests/fm-tmux-submit-busy.test.sh`; `tests/fm-control-relaunch.test.sh`; `tests/fm-afk-owned-digest-recovery.test.sh`; the opt-in live guards `tests/fm-claude-stopfailure-live-e2e.test.sh` and `tests/fm-afk-claude-long-digest-live-e2e.test.sh`.
- Upstream: delivers every away escalation to a Claude Code primary as a record-backed doorbell (upstream #5664), which the fork takes, so the pointer only shortens what a typed-envelope primary receives; upstream bounds the digest at 8 KiB with a full-text file instead (upstream #5554), which the fork does not take; `tests/fm-afk-claude-long-digest-live-e2e.test.sh` still measures the typed Claude path and needs re-pointing before its next run.
  The upstream lost-hand-back notice is retained; the fork resets its failure episode only after a rewake commits, so a failed hand-back keeps the once-per-episode notice.

### away-inject-delivery-proof

- Intent: count an away digest delivered only on positive proof, own it before typing it on tmux and herdr, read a named Claude session's composer, clear it when away mode ends, and repeat a delivery wedge as the return output's last line, because a digest that only looked submitted can stall away mode indefinitely; upstream issue https://github.com/kunchenguid/firstmate/issues/6034.
- Class: carried.
- Seam: `fm_tmux_proven_submit` in `bin/fm-tmux-lib.sh`; the titled-rule reader and the shared owned-input submit and clear loops in `bin/fm-composer-lib.sh`; `fm_backend_herdr_composer_owned_input` in `bin/backends/herdr.sh`; the tmux and herdr submit, owned-record, and exit-cleanup hunks in `bin/fm-supervise-daemon.sh`; the opened marker in `bin/fm-operational-input.sh`; the owned-text cleanup and wedge tail in `bin/fm-afk-return.sh`; the afk skill's return and submit-model text; the family registration in `bin/fm-test-run.sh` and exclusions in `bin/fm-test-isolation-proof.sh`; fork-only `tests/named-claude-composer-fixture.py`; and the turn footer in `tests/wake-helpers.sh`'s fake tmux (shared).
- Guard: fork-only `tests/fm-afk-inject-delivery-proof.test.sh`; `tests/fm-afk-owned-digest-recovery.test.sh`; `tests/fm-afk-inject-titled-composer.test.sh`; the separately gated `tests/fm-afk-inject-titled-composer-herdr-e2e.test.sh`; `tests/fm-afk-inject-e2e.test.sh`; `tests/fm-afk-return.test.sh`; the named-session checks in `tests/fm-composer-matrix-live-e2e.test.sh`.
- Upstream: counts a composer that reads empty after Enter as delivered and has no owned-text recovery; drop once upstream fixes issue 6034 equivalently.
  Its titled-rule fallback requires an eight-dash prefix and an ASCII title, so the fork retains its broader named-session reader and takes its width check and grey slash-command fix while preserving the optional row separator used by owned-input recovery.

### markless-op-header

- Intent: port of upstream #5149.
- Class: carried.
- Seam: `bin/fm-operational-input.sh` and its Calm consumers `.claude/mods/firstmate-calm/lib/fm-operational-input.ts` and `.pi/extensions/lib/fm-operational-input.ts`, the mark-less branch of `message_is_injection` in `bin/fm-supervise-daemon.sh`, with its cases in `.claude/mods/firstmate-calm/tests/calm.test.ts` and the away-mode step of `tests/fm-calm-claude-mod-live-e2e.test.sh` (shared).
- Guard: `tests/fm-operational-input.test.sh`; `tests/fm-calm-claude-mod.test.sh`; `tests/fm-calm-pi-extension.test.sh`.
- Upstream: does not parse the mark-less header; it delivers Claude-bound operational input as a record-backed doorbell (upstream #5664), which the fork also takes, so drop this entry once no fork path types an envelope into Claude Code.

### away-watchdog

- Intent: a detached watchdog outside tmux reports a lost fleet tmux server or a stopped away watcher; README "Away watchdog outside tmux".
- Class: carried.
- Seam: fork-only `bin/fm-afk-sentinel.sh`, plus its start and stop call sites in `bin/fm-afk-launch.sh`, its gap lines and marker cleanup in `bin/fm-afk-return.sh`, its row in `docs/scripts.md`, its trigger in `docs/wedge-alarm.md`, and its family entry in `bin/fm-test-run.sh` (shared).
- Guard: fork-only `tests/fm-afk-sentinel.test.sh`; `tests/fm-afk-return.test.sh` `test_return_brief_reports_away_watchdog_findings`.
- Upstream: has no watchdog outside the fleet's tmux server, and its supervision host, on by default for Claude primaries since upstream #6124, shares that failure domain; drop once upstream reports a lost fleet server equivalently.

### worker-tmux-isolation

- Intent: a ship or scout worker's tmux commands reach a private per-task server, never the fleet server hosting its pane; docs/tmux-backend.md "Worker isolation from the fleet server".
- Class: carried.
- Seam: fork-only `bin/fm-private-tmux-lib.sh` and its row in `docs/scripts.md`, plus the private-directory hunks in `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, and `bin/fm-test-run.sh`, the worker tmux rule in `bin/fm-brief.sh`, and the private-socket shim in `tests/fm-afk-launch.test.sh` (shared).
- Guard: fork-only `tests/fm-worker-tmux-isolation.test.sh`; `tests/fm-test-run.test.sh` `test_unretired_private_tmux_directory_fails_the_run`; `tests/fm-backlog-atomicity.test.sh` `test_dispatch_leaves_no_record_when_the_transition_fails`; `tests/fm-backend-orca.test.sh` `test_spawn_orca_recovery_record_keeps_the_private_tmux_directory`; `tests/fm-control-relaunch.test.sh` `test_relaunch_keeps_the_private_tmux_directory`.
- Upstream: workers inherit the fleet pane's `TMUX`, so a bare `tmux kill-server` stops the fleet; not upstream, and a candidate contribution that would retire this entry.

### claude-desktop-identity

- Intent: a firstmate primary started from the Claude desktop app identifies its own harness and can take the session lock.
- Class: carried.
- Seam: fork-only `bin/fm-claude-lib.sh` and `tests/fm-claude-desktop-identity-live-e2e.test.sh`, plus its call sites in `fm_harness_process_matches` in `bin/fm-session-lock-lib.sh` and `harness_process_verdict` in `bin/fm-harness.sh`, its sibling entries in `bin/fm-backend.sh`, its family and weight entries in `bin/fm-test-run.sh`, its evidence in `docs/verification/runtime-backends.md`, and the fixture copies in suites that source those scripts (shared).
- Guard: `tests/fm-session-lock-ancestry.test.sh` desktop cases; `tests/fm-harness-precedence.test.sh` `test_desktop_app_session_resolves_claude`; the default-on live guard `tests/fm-claude-desktop-identity-live-e2e.test.sh`.
- Upstream: does not recognize the desktop app's version-named session executable, so a desktop-app session starts read-only; drop once upstream identifies it equivalently.
  The shared backend loader now uses upstream's positional-parameter iteration for zsh compatibility, retaining only the fork's additional Claude helper in that list.

### devin-rate-limit-retry

- Intent: preserve supervised Devin progress across a recoverable rate limit.
- Class: carried.
- Seam: fork-only `bin/fm-devin-rate-limit-retry.sh` and its calls in `bin/fm-devin-lib.sh`, with runner registration in `bin/fm-test-run.sh`.
- Guard: `tests/fm-devin-rate-limit-retry.test.sh`; `tests/fm-devin-rate-limit-retry-live-e2e.test.sh`.
- Upstream: no equivalent retry owner; drop when the same bounded recovery is available.

### quota-provider-scope

- Intent: each home can restrict quota and authentication discovery to its configured providers; `docs/configuration.md` "Quota provider scope".
- Class: carried.
- Seam: fork-only `bin/fm-quota-read.sh`, its callers in `bin/fm-dispatch-resolve.sh` and `bin/fm-procevent-quota.sh`, the provider-scope configuration section, the quota read instructions in `.agents/skills/quota-array-dispatch/SKILL.md` and `.agents/skills/harness-adapters/references/common/model-and-effort.md`, and its guard selection in `bin/fm-test-run.sh`.
- Guard: `tests/fm-dispatch-resolve.test.sh`; `tests/fm-procevent-quota.test.sh`; `tests/fm-quota-array-dispatch-live-e2e.test.sh`.
- Upstream: reads the quota tool directly without this home-specific scope; drop when it offers equivalent validated scope propagation.

### contribution-forget

- Intent: stop tracking a publication only after active links are retired, retaining a recoverable audit.
- Class: carried.
- Seam: the `forget` command and record-size guard in `bin/fm-contributions.sh`, forgotten-record validation and active-owner projection in `bin/fm-contributions.jq`, and their reference lines in `docs/architecture.md` and `docs/scripts.md`.
- Guard: `tests/fm-contributions.test.sh` forget, active-link and record-size cases.
- Upstream: has no equivalent audited removal; drop once it preserves the same evidence and active-link guards.

### codex-catalog-effort

- Intent: derive Codex maximum-effort support from the installed model catalog while preserving the fallback for unavailable catalogs.
- Class: carried.
- Seam: `effort_flag_for_harness` in `bin/fm-spawn.sh` and the effort row in `.agents/skills/harness-adapters/references/harness/codex.md`.
- Guard: `tests/fm-spawn-dispatch-profile.test.sh` catalog-supported, unsupported and unavailable-catalog cases.
- Upstream: permits maximum effort only for its fixed model name; drop when equivalent catalog capability checks land.

### raw-launch-verbatim

- Intent: an explicit raw command avoids adapter probing, template substitutions, ready gates and hook wiring while retaining generic task isolation.
- Class: carried.
- Seam: `RAW_LAUNCH` guards around adapter resolution, model checks, busy wiring, template substitutions and post-launch readiness in `bin/fm-spawn.sh`.
- Guard: `tests/fm-spawn-dispatch-profile.test.sh` raw-adapter and literal-placeholder cases.
- Upstream: applies portions of adapter setup to raw commands; drop when the raw path preserves the same command and wiring boundaries.

### launch-submit-proof

- Intent: confirm shell launch execution and preserve a relaunch that starts after a reported launch failure.
- Class: carried.
- Seam: owned shell-line submission and readiness in `bin/fm-tmux-lib.sh`, `bin/backends/tmux.sh`, `bin/fm-composer-lib.sh`, and `bin/fm-spawn.sh`, plus late-start confirmation in `bin/fm-control.sh`.
- Guard: `tests/fm-tmux-submit-busy.test.sh`; `tests/fm-backend-tmux-smoke.test.sh`; `tests/fm-control-relaunch.test.sh`.
- Upstream: does not prove these shell submissions or complete the same late-start transaction; drop once equivalent.

### remote-job-recovery-latency

- Intent: preserve prompt remote recovery across sequential inheritance jobs without increasing the lifecycle guard's recovery bound.
- Class: carried.
- Seam: the 0.05-second active/result default in `bin/fm-remote-job-lib.sh` and the 20-pass post-activity dispatcher burst in `bin/fm-remote-job-worker.sh`.
- Guard: `tests/fm-remote-job.test.sh` default/override cadence and idle-worker cases; `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` watcher recovery case with its unchanged bound.
- Upstream: uses 0.25-second active/result sampling and a four-pass burst; retain the fork's prior defaults at the cost of more sampling during activity, while taking upstream's bounded builtin reads and other polling reductions, until an equivalent preserves the recovery guard.

### isolated-test-cleanup

- Intent: fixture cleanup and lab commands remain confined to their owned temporary roots and explicit tmux sockets.
- Class: carried.
- Seam: fork-only `tests/tmproot-guard.sh`, the fixture lifecycle changes in `tests/lib.sh` and its test cleanup callers, plus the explicit-socket path in `bin/fm-live-lab.sh` and its contract in `bin/fm-lab-home.sh`.
- Guard: `tests/fm-test-fixture-cleanup.test.sh`; `tests/fm-live-lab.test.sh`.
- Upstream: lacks the same fixture-root guard and missing-directory socket protection; drop once equivalent.

### herdr-server-stdio

- Intent: a detached Herdr server does not retain a remote caller's output descriptors through a waiting shell wrapper.
- Class: carried.
- Seam: the exec-based server launch in `fm_backend_herdr_server_ensure` in `bin/backends/herdr.sh`.
- Guard: `tests/fm-backend-herdr.test.sh`.
- Upstream: launches through a background shell function; drop once its launch closes the same descriptors.

### bash32-timeout-owner

- Intent: timeout ownership works when stock Bash has no `BASHPID`.
- Class: carried.
- Seam: the fallback process identity in `fm_exec_timed` in `bin/fm-timeout-lib.sh`.
- Guard: `tests/fm-timeout-lib.test.sh`.
- Upstream: reads `BASHPID` unconditionally; drop once it supports the same shell.

### pr-poll-metadata

- Intent: unrelated well-formed task metadata does not invalidate a PR poll, and poll mismatch diagnostics identify registration drift.
- Class: carried.
- Seam: `fm_pr_metadata_identity_parse` in `bin/fm-pr-lib.sh` and the registration-mismatch wake wording in `bin/fm-watch.sh`.
- Guard: `tests/fm-pr-check-security.test.sh`.
- Upstream: accepts a fixed list of trailing metadata keys and groups mismatched polls with unauthenticated checks; drop once equivalent.

## Incidental

- `codex-animation-port`: the fork's port of upstream #4297 (`tests/fixtures/codex-animation/`), which upstream replaced with #4532; the animation, painted-braille, and ghost extraction hunks in `bin/fm-composer-lib.sh`, their cases in `tests/fm-composer-ghost.test.sh` and `tests/fm-composer-lib.test.sh`, and the prepared-lab animation mode in `tests/fm-composer-matrix-live-e2e.test.sh`; kept for now at a known cost.
- `muse-fixture-symlink`: a fork fixture change that upstream PR #3539 duplicates.
- `upstream-lint-memory-fallback`: the lint owner and its regression suite take upstream https://github.com/kunchenguid/firstmate/pull/6443 ahead of the next ancestry merge; only memory-exhausted roots retry without source following, within the original bounds, while every canonical library remains a direct lint root.
  Drop this item once an integration contains that upstream commit.
- Test adaptations in upstream-owned suites are not entries of their own; they ride under the entry whose behavior they pin, and the classification step flags any that pin nothing.
