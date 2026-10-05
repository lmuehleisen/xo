// OpenCode V2 entrypoint adapter for Firstmate's existing hook implementations.
// V2 public events carry data and execution lifecycle events, rather than the
// V1 properties/session.idle surface. Keep that translation at this boundary.
export function v2Plugin(id, factory, { rootOnly = false } = {}) {
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
        await ctx.tool.hook("execute.before", (event) => hooks["tool.execute.before"](
          { tool: event.tool === "shell" ? "bash" : event.tool },
          { args: event.input },
        ));
      }
      const controller = new AbortController();
      const parents = new Map();
      let rootSessionID;
      const stream = hooks.event ? (async () => {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          let type = event.type;
          let properties = event.data;
          if (rootOnly && type === "session.created") {
            parents.set(event.data.sessionID, event.data.parentID ?? null);
            if (event.data.parentID) continue;
          }
          if (rootOnly && type.startsWith("session.execution.")) {
            const sessionID = event.data.sessionID;
            if (!parents.has(sessionID)) {
              // Native resume can omit creation from this live subscription.
              try {
                const { data: session } = await ctx.session.get({ sessionID });
                if (session.id !== sessionID) continue;
                parents.set(sessionID, session.parentID ?? null);
              } catch {
                continue;
              }
            }
            if (parents.get(sessionID)) continue;
            rootSessionID ??= sessionID;
            if (sessionID !== rootSessionID) continue;
          }
          if (type === "session.execution.started") {
            type = "session.status";
            properties = { ...event.data, status: { type: "busy" } };
          } else if (["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].includes(type)) {
            // Shutdown preserves the execution claim for resume, not an idle turn.
            if (event.data.reason === "shutdown") continue;
            type = "session.idle";
          }
          await hooks.event({ event: { type, properties } });
        }
      })() : Promise.resolve();
      // Keep unexpected stream failures visible in OpenCode's plugin logs.
      stream.catch((error) => {
        if (!controller.signal.aborted) console.error(`${id}: event subscription failed`, error);
      });
      return async () => {
        controller.abort();
        await stream.catch(() => {});
        await hooks.dispose?.();
      };
    },
  };
}
