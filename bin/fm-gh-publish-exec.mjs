#!/usr/bin/env node
// Trusted subprocess adapter for gh, including no-mistakes' stdin PR bodies.
// Usage: fm-gh-publish-exec.mjs <absolute-real-gh> <gh-args>...
// Use explicit FM_HOME/FM_CONFIG_OVERRIDE and private FM_STATE_OVERRIDE.
// Snapshots supported --body-file/--notes-file - bytes privately, checks argv through
// the existing policy, then forwards the checked stdin bytes on approval.
// Approved live-head-bound no-mistakes PR stdin bodies are compacted by
// fm-no-mistakes-body.mjs before checking; ordinary bodies stay byte-identical.
// Helper failures and empty/malformed successful output refuse publication.
// Copy this adapter, its policy, and the body helper into an isolated publisher's
// toolbelt together when refreshing it; a primary checkout update is insufficient.
// Gist creation from stdin (including no filename) and gh api --input - are
// unsupported runtime forms and refuse; use checked file-backed forms instead.
// Reads pass; unsupported operations fail closed. Never evaluates argv as shell.
// FM_PUBLISH_EXEC_BLOCK=1 independently refuses all supported GitHub writes.
// Checked writes pin GH_HOST to github.com; read environments stay unchanged.
// Client-side checks provide detection and friction, not a sandbox.
// Host-user processes and file-backed inputs are trusted; callers keep checked
// files stable until gh finishes. Adversarial host-user replacement is outside
// this adapter's trust boundary.
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { decision, runtimeOperation, runtimeCommand, runtimeStdinFlags, runtimePrTarget } from "./fm-gh-publish-policy.mjs";

const [real, ...original] = process.argv.slice(2);
let dir;
try {
  if (!real || !path.isAbsolute(real) || real === process.argv[1]) throw new Error("absolute separate real gh required");
  const operation = runtimeOperation(original);
  if (operation === "unsupported") throw new Error("unsupported gh operation");
  const args = [...original];
  let input;
  const command = runtimeCommand(original);
  const fileFlags = runtimeStdinFlags(original);
  if (command && fileFlags.length) {
    const stdinFlags = [];
    for (let i = command.verbIndex + 1; i < args.length; i += 1) {
      if (fileFlags.includes(args[i]) && args[i + 1] === "-") stdinFlags.push([i + 1, ""]);
      else {
        const flag = fileFlags.find((flag) => args[i] === `${flag}=-` || (flag === "-F" && args[i] === "-F-"));
        if (flag) stdinFlags.push([i, flag]);
      }
    }
    if (stdinFlags.length) {
      input = readFileSync(0);
      // Do not accept bytes the policy's UTF-8 text reader would change.
      if (!Buffer.from(input.toString("utf8")).equals(input) || input.includes(0)) throw new Error("body must be UTF-8 text without NUL");
      dir = mkdtempSync(path.join(tmpdir(), "fm-gh-stdin-"));
      const file = path.join(dir, "body.md");
      writeFileSync(file, input, { mode: 0o400 });
      for (const [i, flag] of stdinFlags) args[i] = flag ? `${flag}=${file}` : file;
      const target = runtimePrTarget(args, process.cwd());
      if (target && stdinFlags.length === 1) {
        const bin = path.dirname(fileURLToPath(import.meta.url));
        const config = spawnSync(path.join(bin, "fm-publish-gate.sh"), ["config-dir"], { encoding: "utf8" });
        if (config.status !== 0) throw new Error("publish configuration unavailable");
        const prepared = spawnSync(process.execPath, [path.join(bin, "fm-no-mistakes-body.mjs"),
          config.stdout.trim(), real, target.repo, target.prBase || "", target.prHead || "",
          target.prNumber || "", target.prBranch || "", file, "--sanitize"],
        { encoding: "utf8", maxBuffer: 1024 * 1024 });
        if (prepared.error || prepared.signal || ![0, 1, 2, 3].includes(prepared.status)
          || (prepared.status === 1 && (prepared.stdout || prepared.stderr))) {
          throw new Error("no-mistakes body preparation failed; refresh the publisher toolbelt");
        }
        if (prepared.status === 2) throw new Error("malformed no-mistakes-submissions config");
        if (prepared.status === 3) throw new Error("generated body has unsafe evidence or an unsupported layout; rewrite its change summary or refresh the pipeline format");
        if (prepared.status === 0) {
          const publication = prepared.stdout;
          const markers = (text) => text.match(/<!-- no-mistakes-pipeline-attestation:v1 [\s\S]*? -->/g) || [];
          const originalMarkers = markers(input.toString("utf8"));
          const publishedMarkers = markers(publication);
          if (!publication.trim() || originalMarkers.length !== 1 || publishedMarkers.length !== 1
            || publishedMarkers[0] !== originalMarkers[0]) {
            throw new Error("no-mistakes body preparation returned invalid output; refresh the publisher toolbelt");
          }
          input = Buffer.from(publication);
          // Use a new immutable snapshot; never rewrite the caller's source.
          const sanitized = path.join(dir, "publication.md");
          writeFileSync(sanitized, input, { mode: 0o400 });
          for (const [i, flag] of stdinFlags) args[i] = flag ? `${flag}=${sanitized}` : sanitized;
        }
      }
    }
  }
  const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
  const verdict = decision(["gh", ...args].map(quote).join(" "), process.cwd());
  if (verdict.decision !== "allow") throw new Error(`${verdict.code}: ${verdict.reason}`);
  if (operation === "write" && process.env.FM_PUBLISH_EXEC_BLOCK === "1") throw new Error("GitHub writes blocked pending contribution approval");
  const env = operation === "write" ? { ...process.env, GH_HOST: "github.com" } : process.env;
  const result = spawnSync(real, original, { argv0: "gh", input, env, stdio: input === undefined ? "inherit" : ["pipe", "inherit", "inherit"] });
  if (result.error) throw new Error("real gh execution failed");
  process.exitCode = result.status ?? 1;
} catch (error) {
  process.stderr.write(`fm-gh-publish-exec: REFUSED: ${error.message}\n`);
  process.exitCode = 1;
} finally {
  if (dir) rmSync(dir, { recursive: true, force: true });
}
