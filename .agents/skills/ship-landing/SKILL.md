---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal is `done [at=<epoch>]: PR <url>` after the worker opens a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
That signal comes before CI finishes, so it does not yet make the PR ready for the captain's review or merge.
The PR is ready only when no check is pending and every check has passed, or when each remaining failure is shown to reproduce on the default branch and to be unrelated to the change.
On GitHub, `gh pr checks <url>` must list every reported check, advisory ones included, as passed or skipped, and `bin/fm-pr-state.sh <url>` must print nothing, which also catches a PR on which no required check has reported; on GitLab read the merge request's head pipeline, and on Gerrit the change's verification votes where the project has CI.
A required check that never reported while others did is invisible to these reads; `bin/fm-pr-merge.sh` still refuses it at merge time.
A red or pending PR goes back to the worker through `bin/fm-send.sh`: wait for pending checks, fix a failure its change caused, or show each remaining failure reproducing on the default branch and unrelated, then report ready again.
Until then the PR is not registered below, listed among the captain's calls, or described as awaiting review or merge, because registration also announces a secondmate's PR as ready to its parent; when the pre-existing-failure exception applies, present the PR with that evidence stated plainly.
Once the PR is ready, run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
Then tell the captain the PR's full `https://...` URL copied from the worker's ready line or the task's `pr=` metadata, and a concise outcome summary.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
