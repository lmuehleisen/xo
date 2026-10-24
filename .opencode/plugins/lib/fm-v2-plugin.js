// OpenCode V2 entrypoint adapter for Firstmate's existing hook implementations.
// V2 public events carry data and execution lifecycle events, rather than the
// V1 properties/session.idle surface. Keep that translation at this boundary.
import {
  eventProperties,
  eventType,
  executionEnded,
  setupEventSubscription,
  setupToolExecuteBefore,
} from "./fm-opencode2.js";

export function v2Plugin(id, factory) {
  return {
    id,
    async setup(ctx) {
      const hooks = await factory({
        directory: ctx.location.directory,
        client: {
          session: {
            promptAsync: ({ path, body }) => ctx.session.prompt({
              sessionID: path.id,
              text: body.parts.filter((part) => part.type === "text").map((part) => part.text).join("\n"),
            }),
          },
        },
      });
      if (hooks["tool.execute.before"]) {
        await setupToolExecuteBefore(ctx, (event) => hooks["tool.execute.before"](
          { tool: event.tool === "shell" ? "bash" : event.tool, sessionID: event.sessionID },
          { args: event.input },
        ));
      }
      const unsubscribe = hooks.event && setupEventSubscription(ctx, async (event) => {
        let type = eventType(event);
        let properties = eventProperties(event);
        if (type === "session.execution.started") {
          type = "session.status";
          properties = { ...properties, status: { type: "busy" } };
        } else if (executionEnded(event)) {
          type = "session.idle";
        } else if (type.startsWith("session.execution.")) {
          // No other execution event maps to a V1 lifecycle event. A shutdown
          // terminal event preserves the execution claim for resume, not an idle turn.
          return;
        }
        await hooks.event({ event: { type, properties } });
      }, id);
      return async () => {
        if (unsubscribe) await unsubscribe();
        await hooks.dispose?.();
      };
    },
  };
}
