// Fake the native plugin host at the public launch/prompt boundary. Spawn
// fixtures still load the actual generated worker plugin and its model check.
import { readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const [record, text] = process.argv.slice(2);
let command;
let prompt;
if (text.includes("OPENCODE_CONFIG_CONTENT=")) {
  command = text;
  writeFileSync(record, command);
} else {
  try { command = readFileSync(record, "utf8"); } catch { process.exit(0); }
  prompt = text;
}
if (process.env.FM_FAKE_OPENCODE_PLUGIN_MISSING === "1") process.exit(0);
const match = command.match(/OPENCODE_CONFIG_CONTENT='(.*?)' opencode --standalone --auto/s);
if (!match) throw new Error("fixture could not read the native launch config");
const config = JSON.parse(match[1].replaceAll("'\\''", "'"));
const selected = (config.model || "opencode/fixture-model").split("#")[0];
const ref = (value) => {
  if (value === "missing") return undefined;
  const index = value.indexOf("/");
  return { providerID: value.slice(0, index), id: value.slice(index + 1) };
};
const hooks = {};
const mod = await import(pathToFileURL(`${config.plugins[0]}/index.mjs`));
const cleanup = await mod.default.setup({
  location: { directory: "/tmp" },
  model: { list: async () => {
    if (process.env.FM_FAKE_OPENCODE_DISCOVERY === "unavailable") throw new Error("catalog offline");
    return { data: [ref(process.env.FM_FAKE_OPENCODE_DISCOVERY === "unsupported" ? "opencode/other" : selected)] };
  } },
  session: { hook: async (name, callback) => { hooks[name] = callback; } },
  event: { subscribe: async function* () {} },
});
if (prompt && hooks.prompt) {
  try {
    await hooks.prompt({ sessionID: "ses_worker", prompt: { text: prompt } });
    await hooks.context({ sessionID: "ses_worker", model: ref(process.env.FM_FAKE_OPENCODE_ACTUAL_MODEL || selected) });
  } catch {
    // The native request fails, while terminal text delivery still succeeds.
  }
}
await cleanup();
