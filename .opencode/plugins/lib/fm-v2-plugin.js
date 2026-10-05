// OpenCode V2 entrypoint adapter for Firstmate's existing hook implementations.
// V2 public events carry data and execution lifecycle events, rather than the
// V1 properties/session.idle surface. Keep that translation at this boundary.
import { realpathSync } from "node:fs";
import { resolve } from "node:path";

function directoryIdentity(directory) {
  if (typeof directory !== "string" || !directory) return "";
  try { return realpathSync(directory); } catch { return resolve(directory); }
}

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
      const sessions = new Map();
      const primaryDirectory = directoryIdentity(ctx.location.directory);
      let rootSessionID;
      async function isPrimarySession(sessionID, select = false) {
        if (!rootOnly) return true;
        if (!sessionID || !primaryDirectory) return false;
        if (!sessions.has(sessionID)) {
          // Native resume and tool-only plugins can miss the creation event.
          try {
            // Promise plugins unwrap the HTTP API's single data envelope.
            const session = await ctx.session.get({ sessionID });
            if (session.id !== sessionID) return false;
            sessions.set(sessionID, session);
          } catch {
            return false;
          }
        }
        const session = sessions.get(sessionID);
        if (session.parentID || directoryIdentity(session.location?.directory) !== primaryDirectory) return false;
        if (select || !rootSessionID) rootSessionID = sessionID;
        return sessionID === rootSessionID;
      }
      if (hooks["tool.execute.before"]) {
        await ctx.tool.hook("execute.before", async (event) => {
          if (!await isPrimarySession(event.sessionID)) return;
          return hooks["tool.execute.before"](
            { tool: event.tool === "shell" ? "bash" : event.tool, sessionID: event.sessionID },
            { args: event.input },
          );
        });
      }
      const controller = new AbortController();
      const stream = hooks.event || rootOnly ? (async () => {
        for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
          let type = event.type;
          let properties = event.data;
          if (rootOnly && type === "session.created") {
            sessions.set(event.data.sessionID, { ...event.data, id: event.data.sessionID });
            if (!await isPrimarySession(event.data.sessionID, true)) continue;
          }
          if (rootOnly && type.startsWith("session.execution.")) {
            if (!await isPrimarySession(event.data.sessionID)) continue;
          }
          if (type === "session.execution.started") {
            type = "session.status";
            properties = { ...event.data, status: { type: "busy" } };
          } else if (["session.execution.succeeded", "session.execution.failed", "session.execution.interrupted"].includes(type)) {
            // Shutdown preserves the execution claim for resume, not an idle turn.
            if (event.data.reason === "shutdown") continue;
            type = "session.idle";
          }
          if (hooks.event) await hooks.event({ event: { type, properties } });
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
