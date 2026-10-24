// Worker-only launch identity check. The context hook reports the native
// agent-loop model after session resolution, before inference or tool use.
// Config and catalog entries are selection/support evidence, never execution
// evidence. This cannot attest a provider's internal routing behind that ID.
import { writeFileSync, renameSync } from "node:fs";

const identity = (model) =>
  typeof model?.providerID === "string" && model.providerID.length > 0 &&
  typeof model?.id === "string" && model.id.length > 0
    ? `${model.providerID}/${model.id}` : null;

export async function installLaunchModelCheck(ctx, { expected, evidence, launchText }) {
  expected = expected && expected !== "default" ? expected.split("#")[0] : "default";
  let sessionID;
  let verified = false;
  let discovery = "pending";
  const publish = (phase, observed, detail, source = "startup") => {
    const record = { phase, expected, observed, discovery, sessionID, detail,
      source };
    writeFileSync(`${evidence}.tmp`, JSON.stringify(record) + "\n", { mode: 0o600 });
    renameSync(`${evidence}.tmp`, evidence);
  };
  const refuse = (observed, detail, source = "session.context") => {
    publish("refused", observed, detail, source);
    throw new Error(`OpenCode launch model verification failed: expected=${expected} observed=${observed}; ${detail}`);
  };
  await ctx.session.hook("prompt", async (event) => {
    // Bind the client-selected worker session, never another same-directory
    // root or a child using a different model. Admission precedes resolution.
    if (sessionID !== undefined || event.prompt.text !== launchText) return;
    sessionID = event.sessionID;
    discovery = "unavailable";
    try {
      // Admission runs after location plugins settle. A setup-time snapshot
      // can omit models registered by later plugins and cannot prove absence.
      const { data: models } = await ctx.model.list();
      if (Array.isArray(models) && models.length > 0 && models.every(identity)) {
        discovery = expected === "default" || models.some((model) => identity(model) === expected)
          ? "supported" : "unsupported";
      }
    } catch {
      // A failed catalog read is uncertainty, not unsupported proof.
    }
    if (discovery === "unsupported") {
      refuse("unavailable", "expected model is absent from the native model catalog; select a currently listed model", "model.list");
    }
    publish("pending", "unavailable", "awaiting the worker session's native agent-loop request", "session.prompt");
  });
  await ctx.session.hook("context", (event) => {
    if (verified || sessionID === undefined || event.sessionID !== sessionID) return;
    const observed = identity(event.model);
    if (observed === null) refuse("unavailable", "native agent-loop request omitted its model identity");
    if (expected !== "default" && observed !== expected) {
      refuse(observed, "native agent-loop model differs from the requested model; inspect the retained launch diagnostics");
    }
    publish("verified", observed, "native agent-loop model resolved before inference", "session.context");
    verified = true;
  });
  publish("ready", "unavailable", "awaiting the worker session's native agent-loop request");
}
