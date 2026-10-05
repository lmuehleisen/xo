# Upstream integration

This fork takes upstream [kunchenguid/firstmate](https://github.com/kunchenguid/firstmate) changes on a recurring schedule.
This page is the maintainer checklist for one integration run; the fork's invariants and every other deliberate difference from upstream are recorded in the [fork divergences ledger](fork-divergences.md).

## Contract

- Integrate on a disposable branch based on the fork's published `origin/main`, never in an operational installation.
- Merge `upstream/main` with a real merge that preserves upstream ancestry, and record the full upstream source commit.
- Land the pull request with a merge commit, never squash or rebase: a squashed integration leaves the installation's commits outside remote ancestry, and the updater then refuses to fast-forward.
- Resolve conflicts by preserving every fork invariant first, taking upstream fixes and tests that do not depend on a dropped dependency second, and preferring the fork's native design where upstream built an alternative, porting only what upstream does better.
- Merge approval stays with the fork owner, and an installation is reconciled only after the merge lands.

## Checklist

1. Fetch `origin` and `upstream`, branch from `origin/main`, and before merging record three commits: `git merge-base origin/main upstream/main` (the upstream commit the previous integration merged), `git rev-parse upstream/main`, and `git rev-parse origin/main`.
2. Run `git merge --no-ff upstream/main`.
   A fully automatic merge still gets every step below; a clean textual merge is the case most likely to hide a semantic break.
   When upstream reformatted a file the fork also changed, resolve that file with a normalized three-way merge (the same formatter on base, fork, and upstream, then `git merge-file`) rather than hunk by hunk, and never with `-X ignore-all-space`, which silently keeps the fork's old formatting.
3. Run the call-site scan with the three commits recorded in step 1, before any test:

   ```sh
   bin/fm-upstream-callsite-scan.sh <merge-base> <upstream/main> <origin/main>
   ```

   It checks both directions: fork-only lines calling a helper whose definition line upstream changed, and upstream-added lines calling a helper whose definition line the fork changed.
   It also reports fork tests that extract a function body upstream changed, and upstream-added harness lists that omit a harness only the fork has.
   Read each reported line against the other side's current code, fix any caller, test, or list that no longer fits, and account for every reported line in the pull request body.
   The script's `--help` owns the exact matching rules and their limits.
   A convention change confined to a helper's body stays invisible to it, so also read each fork-divergent function that upstream-new code calls.
4. Verify the fork's dropped dependencies stay dropped and review what upstream changed under the opt-in: `git grep -n -E 'gh-axi|lavish-axi|chrome-devtools-axi|no-mistakes' -- bin .agents/skills AGENTS.md README.md CONTRIBUTING.md docs`, and account for every new hit upstream introduced.
   Include `CONTRIBUTING.md` and `docs`, because upstream prose can reintroduce a requirement the fork removed, such as a required check the fork deleted.
   gh-axi and chrome-devtools-axi stay dropped, while `no-mistakes` is an optional opt-in through `config/no-mistakes` and `lavish-axi` an optional toggle through `config/lavish`, so an upstream change to either can belong in the fork instead of being stripped; never accept an upstream Lavish change that runs `setup`, `update`, or `share`, unpins the version, or widens the bound address.
5. Classify every divergent hunk in a shared file: for each file present upstream in `git diff --stat upstream/main HEAD`, read `git diff upstream/main HEAD -- <file>` and match each hunk against the behavior and scope a ledger `Seam:` line describes.
   A file named by one entry does not claim its other hunks, so report each hunk no entry's scope covers in the pull request body as an incidental candidate and propose its realignment.
   Also list the fork-only paths from the current trees, `comm -23 <(git ls-tree -r --name-only HEAD | sort) <(git ls-tree -r --name-only upstream/main | sort)`, which also catches a path the fork keeps after upstream deleted or renamed it, and report each one that no entry's `Seam:` or `Guard:` line and no incidental item names so it gets an entry or is removed.
   For each `carried` entry, check whether this upstream range ships an equivalent, and if so propose dropping the fork copy.
   Also look for fork-tuned values inside upstream-owned files that an upstream test now pins.
6. Run every guard the ledger names on the merged tree, before the broader suite; `grep '^- Guard:' docs/fork-divergences.md | grep -o 'tests/[a-z0-9-]*\.test\.sh' | sort -u` lists them.
   A failing guard on an `intended` entry means an upstream change reached that divergence: adapt the upstream change, never the guard, and name the entry in the pull request body.
   A failing guard on a `carried` entry may mean upstream now ships an equivalent: evaluate dropping the fork copy and its entry before defending it, and name the outcome in the pull request body.
   List every entry whose `Guard:` line names no test (it reads `none`) in the pull request body as unprotected.
   An opt-in live guard only skips by default, and a skip is not a pass: run the guards with `FM_LIVE=1` where each guard's harness is installed and signed in (the `fm_live_gate` contract in `tests/lib.sh`), and list every guard that still reported a skip in the pull request body as not exercised.
7. Run `bin/fm-test-run.sh --changed` and `bin/fm-test-run.sh --check-coverage`, then each portable lane from `bin/fm-test-run.sh --list-lanes`, and `bin/fm-lint.sh`.
   When `--changed` refuses an unmapped path, run every suite the conflicts, the scan's findings, and the fork's divergent areas touch instead of skipping to the next step.
   A failing test that pins one side's design is adapted to the fork's intended behavior as the ledger records it, and the pull request body names each adaptation and why.
8. Update the ledger in the same pull request: drop carried entries upstream made redundant, add entries for newly deliberate differences, remove realigned incidental items, and check that README "Fork: what differs" and `AGENTS.md` section 7 still describe the fork.
9. Open the pull request against the fork with `gh pr create --repo lmuehleisen/xo --base main`, always passing `--repo` because this checkout also carries the upstream remote.
   Its body states the upstream source commit, that a merge commit is required, every conflict and its resolution, every upstream change dropped or adapted, the call-site scan result, the shared-file classification, the guard results, the ledger changes, and the test results.
   The body may use up to 80 lines and 6000 characters when the publish gate verifies the integration ancestry and the recorded source commit; see `bin/fm-publish-gate.sh policy` for the verification and fallback limits.
   Keep it a concise technical record, with no machine names, runner details, logs, or full hunk audit; the publish judge still reviews the whole description.
