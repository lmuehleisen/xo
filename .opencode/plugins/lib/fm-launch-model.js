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
  let discovery = "unavailable";
  const publish = (phase, observed, detail) => {
    const record = { phase, expected, observed, discovery, sessionID, detail,
      source: phase === "verified" ? "session.context" : "startup" };
    writeFileSync(`${evidence}.tmp`, JSON.stringify(record) + "\n", { mode: 0o600 });
    renameSync(`${evidence}.tmp`, evidence);
  };
  const refuse = (observed, detail) => {
    publish("refused", observed, detail);
    throw new Error(`OpenCode launch model verification failed: expected=${expected} observed=${observed}; ${detail}`);
  };
  try {
    const models = await ctx.model.list();
    if (Array.isArray(models) && models.length > 0 && models.every(identity)) {
      discovery = expected === "default" || models.some((model) => identity(model) === expected)
        ? "supported" : "unsupported";
    }
  } catch {
    // A failed catalog read is uncertainty, not proof a model is unsupported.
  }
  if (discovery === "unsupported") {
    publish("refused", "unavailable", "expected model is absent from the native model catalog; select a currently listed model");
    return;
  }
  await ctx.session.hook("prompt", (event) => {
    // Bind the client-selected worker session, never another same-directory
    // root or a child using a different model. Admission precedes resolution.
    if (sessionID === undefined && event.prompt.text === launchText) sessionID = event.sessionID;
  });
  await ctx.session.hook("context", (event) => {
    if (verified || sessionID === undefined || event.sessionID !== sessionID) return;
    const observed = identity(event.model);
    if (observed === null) refuse("unavailable", "native agent-loop request omitted its model identity");
    if (expected !== "default" && observed !== expected) {
      refuse(observed, "native agent-loop model differs from the requested model; inspect the retained launch diagnostics");
    }
    publish("verified", observed, "native agent-loop model resolved before inference");
    verified = true;
  });
  publish("ready", "unavailable", "awaiting the worker session's native agent-loop request");
}
