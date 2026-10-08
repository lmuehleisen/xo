#!/usr/bin/env node
// Verify eligibility for the generated no-mistakes body length exception.
// Usage: fm-no-mistakes-body.mjs <config> <trusted-gh> <dest> <base> <head>
//        <pr-number> <pr-branch> <body-file> [--sanitize]
// --sanitize prints a compact publication body only after the same live checks.
// It retains What Changed and the original attestation bytes, drops generated
// session evidence, and reports step completion without claiming tests passed.
// It never creates or edits an attestation; all output still needs the full gate.
// Retained v1 JSON allows only head_sha, steps (step/status), and optional
// live_validation (verdict/live/total), with decoded enum and count validation.
// Private no-mistakes-submissions rows are: <upstream> <fork> <contrib/branch>.
// Only live GitHub facts bind the body to the approved fork branch and head.
// This verifies author-editable v1 assertions, not cryptographic provenance.
// Exit 0 qualifies, 1 retains ordinary limits, 2 refuses malformed config.
// In sanitize mode, exit 3 refuses an eligible body with an unsafe/unknown layout.
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const [config, gh, dest, base, head, pr, selector, file, mode] = process.argv.slice(2);
try {
  const scope = path.join(config, "no-mistakes-submissions");
  if (!existsSync(scope)) process.exit(1);
  const repo = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
  const branch = /^contrib\/[A-Za-z0-9][A-Za-z0-9._/-]*$/;
  const rows = readFileSync(scope, "utf8").split(/\r?\n/)
    .filter((line) => line.trim() && !line.trim().startsWith("#"))
    .map((line) => line.trim().split(/\s+/));
  if (rows.some((r) => r.length !== 3 || !repo.test(r[0]) || !repo.test(r[1])
    || r[0] === r[1] || !branch.test(r[2]) || r[2].includes(".."))) {
    process.stderr.write("malformed no-mistakes-submissions config\n");
    process.exit(2);
  }
  const body = readFileSync(file, "utf8");
  const marker = "<!-- no-mistakes-pipeline-attestation:v1 ";
  if (body.split(marker).length !== 2 || !body.includes("\n## Pipeline\n")
    || !body.includes("Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)")) process.exit(1);
  const match = /<!-- no-mistakes-pipeline-attestation:v1 ([\s\S]*?) -->/.exec(body);
  if (!match) process.exit(1);
  const a = JSON.parse(match[1]);
  if (!a || !/^[0-9a-f]{40}$/.test(a.head_sha) || !Array.isArray(a.steps)) process.exit(1);
  const steps = new Map();
  for (const s of a.steps) {
    if (!s || typeof s.step !== "string" || typeof s.status !== "string" || steps.has(s.step)) process.exit(1);
    steps.set(s.step, s);
  }
  if (!["review", "test", "document"].every((s) => steps.get(s)?.status === "completed")
    || steps.get("test").override_reason) process.exit(1);
  const env = { ...process.env };
  for (const k of ["GH_HOST", "GH_REPO", "GH_CONFIG_DIR", "XDG_CONFIG_HOME", "HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR"]) delete env[k];
  const read = (args) => {
    const r = spawnSync(gh, args, { env, encoding: "utf8", timeout: 5000, maxBuffer: 1024 * 1024 });
    if (r.status !== 0) throw new Error("live read unavailable");
    return r.stdout.trim();
  };
  const api = (endpoint) => JSON.parse(read(["api", "--hostname", "github.com", endpoint]));
  let number = pr;
  if (!number && selector) number = read(["pr", "view", selector, "--repo", dest, "--json", "number", "--jq", ".number"]);
  let actualBase = base, actualBranch, fork, actualHead;
  if (number) {
    if (!/^[0-9]+$/.test(number)) process.exit(1);
    const p = api(`repos/${dest}/pulls/${number}`);
    actualBase = p.base?.ref;
    if (base && base !== actualBase) process.exit(1);
    fork = p.head?.repo?.full_name;
    actualBranch = p.head?.ref;
    actualHead = p.head?.sha;
  }
  if (actualBase !== "main") process.exit(1);
  const candidates = rows.filter((r) => r[0] === dest);
  for (const [upstream, approvedFork, approvedBranch] of candidates) {
    if (number ? (fork !== approvedFork || actualBranch !== approvedBranch)
      : head !== `${approvedFork.split("/")[0]}:${approvedBranch}`) continue;
    const f = api(`repos/${approvedFork}`);
    if (!f.fork || f.private !== false || f.full_name !== approvedFork || f.parent?.full_name !== upstream) continue;
    const ref = api(`repos/${approvedFork}/git/ref/heads/${approvedBranch}`);
    if (ref.object?.type !== "commit" || ref.object?.sha !== a.head_sha
      || (number && actualHead !== a.head_sha)) continue;
    if (mode === "--sanitize") {
      const changed = /^## What Changed\s*\n([\s\S]*?)(?=^## |$(?![\s\S]))/im.exec(body)?.[1]?.trim();
      if (!changed) process.exit(3);
      // Never fall back to publishing raw evidence from an eligible body.
      // The original marker stays immutable, so private marker metadata refuses.
      const privateDisplay = /(?:```|~~~|<\/?(?:details|pre)\b|~[/\\]|\/(?:Users|home|tmp|private|var)\/|[A-Z]:\\Users\\|WATCHER DOWN|SUPERVISION IS OFF|^=== |\b[0-9A-HJKMNP-TV-Z]{26}\b|\b\d+(?:\.\d+)?(?:ms|[smh])(?:\d+(?:\.\d+)?[smh])*\b|\b\d{1,2}:\d{2}(?::\d{2})?\b)/im;
      const publicFields = (value, keys) => value && typeof value === "object"
        && !Array.isArray(value) && Object.keys(value).every((key) => keys.includes(key));
      if (!publicFields(a, ["head_sha", "steps", "live_validation"])
        || !a.steps.every((s) => publicFields(s, ["step", "status"]))
        || privateDisplay.test(changed) || privateDisplay.test(match[0])) process.exit(3);
      const names = ["intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"];
      const statuses = ["completed", "skipped", "running", "pending", "failed"];
      if ([...steps].some(([name, s]) => !names.includes(name) || !statuses.includes(s.status))) process.exit(3);
      const table = [...steps].map(([name, s]) => `| ${name} | ${s.status} |`).join("\n");
      let live = "";
      const v = a.live_validation;
      if (Object.hasOwn(a, "live_validation")) {
        if (!publicFields(v, ["verdict", "live", "total"])
          || !["go", "no-go", "inconclusive"].includes(v.verdict)
          || !Number.isSafeInteger(v.live) || !Number.isSafeInteger(v.total)
          || v.live < 0 || v.total < v.live) process.exit(3);
        live = `\nLive validation: ${v.verdict}; ${v.live} of ${v.total} scenarios driven live.\n`;
      }
      process.stdout.write(`## Intent\n\nThis contribution contains the completed changes summarized below.\n\n## What Changed\n\n${changed}\n\n## Pipeline\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n${match[0]}\n\nStep completion records pipeline execution, not a claim that every scenario passed.\n\n| Step | Status |\n| --- | --- |\n${table}\n${live}`);
    }
    process.exit(0);
  }
  process.exit(1);
} catch {
  process.exit(1);
}
