Mode: Agy native background-command wake.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`.
   Handle emitted wakes, open decisions, and unread status, then run the exact `WAKE_ACK_REQUIRED` acknowledgement.
2. Source `__FM_X_MODE_ENV__` when Relay is active.
3. Start `bin/fm-watch-arm.sh` as its own native `run_command` invocation with `WaitMsBeforeAsync: 1` and the home as `Cwd`.
   Read the returned task log with `view_file` when needed to confirm the initial arm status.
   The script has no status subcommand; do not start a second arm to inspect the first.
   A shell approval prompt still requires review; neither this protocol nor its hooks bypasses that review.
4. `watcher: started ...` or `watcher: attached ...` proves one live cycle exists.
   End the turn after that proof; Agy keeps the native command alive and automatically starts a new model invocation on completion.
5. On the automatic completion notification, drain the durable queue, handle and acknowledge its work, and arm the next cycle if supervision remains necessary.
   A completion notification alone is not a task outcome; the queue owns the work.
6. Failure or missing cycle only: inspect the failure, restore the same native command path, and verify the arm status.
7. Never use shell `&`, a truncating pipe, or a bundled watcher command.
   The native PreToolUse transport invokes the shared command guards before execution.
8. Wait silently while the native watcher command runs.

The primary Stop hook invokes the shared turn-end guard and returns a native forced continuation when supervision is needed but no healthy watcher exists.
The loop bound and interrupt limitation belong to [`turnend-guard.md`](../turnend-guard.md).
Primary startup is a PreInvocation nudge; [`sessionstart-nudge.md`](../sessionstart-nudge.md) owns its compatibility limits.
This protocol is verified for interactive Agy; headless streaming is outside this adapter's primary support.
