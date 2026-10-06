#!/usr/bin/env node
// Outgoing Git adapter for isolated publishers, including commit-tree evidence.
// Usage: fm-git-publish-exec.mjs <absolute-real-git> <git-args>...
// Ordinary commands preserve argv. Pushes accept -C plus an explicit remote
// and explicit non-wildcard branch refspecs; unsupported forms fail closed.
// Pinned local NM_HOME/repos intake may carry no-mistakes push options; its
// --no-verify is removed so client hooks run before gate admission.
// Runs the existing pre-push gate on every tip without overriding hooksPath,
// then calls real Git, whose receive/admission hooks remain authoritative.
// FM_PUBLISH_EXEC_BLOCK=1 blocks network pushes after checks; local gate intake
// remains possible. Keep a separate pushInsteadOf block during setup pilots.
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { realpathSync } from "node:fs";

const [real, ...argv] = process.argv.slice(2);
try {
  if (!real || !path.isAbsolute(real)) throw new Error("absolute real git required");
  let cwd = process.cwd(), i = 0;
  while (argv[i] === "-C") {
    if (!argv[i + 1]) throw new Error("missing -C directory");
    cwd = path.resolve(cwd, argv[i + 1]); i += 2;
  }
  // Unknown global options cannot hide a push from the checkpoint.
  if (argv.includes("push") && argv[i] !== "push") throw new Error("unsupported global options for push");
  const run = (args) => {
    const r = spawnSync(real, args, { argv0: "git", cwd, encoding: "utf8", maxBuffer: 1024 * 1024 });
    if (r.status !== 0) throw new Error("cannot resolve outgoing push");
    return r.stdout.trim();
  };
  if (argv[i] === "push") {
    const options = new Set(["-u", "--set-upstream", "--force-with-lease", "--force", "--porcelain", "--quiet", "-q"]);
    const args = argv.slice(i + 1);
    let gateOptions = false;
    for (;;) {
      if (options.has(args[0])) { args.shift(); continue; }
      if (args[0] === "--no-verify") { gateOptions = true; args.shift(); continue; }
      if (["-o", "--push-option"].includes(args[0])) {
        if (!args[1]?.startsWith("no-mistakes.")) throw new Error("unsupported push option");
        gateOptions = true; args.splice(0, 2); continue;
      }
      if (args[0]?.startsWith("--push-option=no-mistakes.")) { gateOptions = true; args.shift(); continue; }
      break;
    }
    if (args[0] === "--") args.shift();
    const [remote, ...refs] = args;
    if (!remote || remote.startsWith("-") || !refs.length || refs.some((r) => !r || /[*\s]/.test(r) || r.startsWith("-"))) throw new Error("explicit remote and branch refspecs required");
    let url = remote;
    const named = spawnSync(real, ["config", "--get-all", `remote.${remote}.url`], { argv0: "git", cwd, encoding: "utf8" });
    if (named.status === 0) {
      const push = spawnSync(real, ["config", "--get-all", `remote.${remote}.pushurl`], { argv0: "git", cwd, encoding: "utf8" });
      const urls = (push.status === 0 ? push.stdout : named.stdout).trim().split("\n");
      if (urls.length !== 1) throw new Error("multiple push destinations refused");
      [url] = urls;
    }
    if (url === "DISABLED") throw new Error("remote pushes disabled");
    if (gateOptions) {
      // The pinned AXI intake adds --no-verify and no-mistakes push options.
      // Accept its local transport only, and REMOVE the bypass so ordinary
      // client hooks still run. Never relax public push validation.
      const gateRoot = process.env.NM_HOME && path.join(process.env.NM_HOME, "repos");
      if (!gateRoot || path.dirname(realpathSync(url)) !== realpathSync(gateRoot)) throw new Error("gate options require an isolated local gate");
    }
    const zero = "0".repeat(40), lines = [];
    for (const original of refs) {
      const ref = original.replace(/^\+/, "");
      const parts = ref.split(":");
      if (parts.length > 2 || !parts[0]) throw new Error("unsupported refspec");
      const sha = run(["rev-parse", "--verify", `${parts[0]}^{commit}`]);
      let target = parts[1] || parts[0];
      if (!target.startsWith("refs/")) target = `refs/heads/${target}`;
      run(["check-ref-format", target]);
      lines.push(`${parts[0]} ${sha} ${target} ${zero}`);
    }
    const gate = path.join(path.dirname(fileURLToPath(import.meta.url)), "fm-publish-gate.sh");
    const checked = spawnSync(gate, ["pre-push", remote, url], { argv0: "git", cwd, input: `${lines.join("\n")}\n`, stdio: ["pipe", "inherit", "inherit"] });
    if (checked.status !== 0) throw new Error("outgoing publish gate refused");
    if (process.env.FM_PUBLISH_EXEC_BLOCK === "1" && (/^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(url) && !url.startsWith("file://") || /^[^/]+:/.test(url))) throw new Error("network pushes blocked pending contribution approval");
  }
  const forwarded = argv[i] === "push" ? argv.filter((arg) => arg !== "--no-verify") : argv;
  const result = spawnSync(real, forwarded, { argv0: "git", stdio: "inherit" });
  if (result.error) throw new Error("real git execution failed");
  process.exitCode = result.status ?? 1;
} catch (error) {
  process.stderr.write(`fm-git-publish-exec: REFUSED: ${error.message}\n`);
  process.exitCode = 1;
}
