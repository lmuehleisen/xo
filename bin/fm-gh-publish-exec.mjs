#!/usr/bin/env node
// Trusted subprocess adapter for gh, including no-mistakes' stdin PR bodies.
// Usage: fm-gh-publish-exec.mjs <absolute-real-gh> <gh-args>...
// Use explicit FM_HOME/FM_CONFIG_OVERRIDE and private FM_STATE_OVERRIDE.
// Snapshots pr create/edit --body-file - bytes privately, checks argv through
// the existing policy, then forwards identical stdin bytes on approval.
// Reads pass; unsupported operations fail closed. Never evaluates argv as shell.
// FM_PUBLISH_EXEC_BLOCK=1 independently refuses all supported GitHub writes.
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import { decision, runtimeOperation, runtimeCommand } from "./fm-gh-publish-policy.mjs";

const [real, ...original] = process.argv.slice(2);
let dir;
try {
  if (!real || !path.isAbsolute(real) || real === process.argv[1]) throw new Error("absolute separate real gh required");
  const operation = runtimeOperation(original);
  if (operation === "unsupported") throw new Error("unsupported gh operation");
  const args = [...original];
  let input;
  const command = runtimeCommand(original);
  if (command?.group === "pr" && ["create", "edit"].includes(command.verb)) {
    const stdinFlags = [];
    for (let i = command.verbIndex + 1; i < args.length; i += 1) {
      if (["--body-file", "-F"].includes(args[i]) && args[i + 1] === "-") stdinFlags.push([i + 1, false]);
      else if (/^(?:--body-file=|-F=?)-$/.test(args[i])) stdinFlags.push([i, true]);
    }
    if (stdinFlags.length) {
      input = readFileSync(0);
      // Do not accept bytes the policy's UTF-8 text reader would change.
      if (!Buffer.from(input.toString("utf8")).equals(input) || input.includes(0)) throw new Error("body must be UTF-8 text without NUL");
      dir = mkdtempSync(path.join(tmpdir(), "fm-gh-stdin-"));
      const file = path.join(dir, "body.md");
      writeFileSync(file, input, { mode: 0o400 });
      for (const [i, attached] of stdinFlags) args[i] = attached ? `--body-file=${file}` : file;
    }
  }
  const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
  const verdict = decision(["gh", ...args].map(quote).join(" "), process.cwd());
  if (verdict.decision !== "allow") throw new Error(`${verdict.code}: ${verdict.reason}`);
  if (operation === "write" && process.env.FM_PUBLISH_EXEC_BLOCK === "1") throw new Error("GitHub writes blocked pending contribution approval");
  const result = spawnSync(real, original, { argv0: "gh", input, stdio: input === undefined ? "inherit" : ["pipe", "inherit", "inherit"] });
  if (result.error) throw new Error("real gh execution failed");
  process.exitCode = result.status ?? 1;
} catch (error) {
  process.stderr.write(`fm-gh-publish-exec: REFUSED: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  if (dir) rmSync(dir, { recursive: true, force: true });
}
