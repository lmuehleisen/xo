#!/usr/bin/env node
// Verify eligibility for the generated no-mistakes body length exception.
// Usage: fm-no-mistakes-body.mjs <config> <trusted-gh> <dest> <base> <head>
//        <pr-number> <pr-branch> <body-file> [--sanitize]
// --sanitize prints a compact publication body only after the same live checks.
// It retains What Changed and the original attestation bytes, drops generated
// session evidence, and reports step completion without claiming tests passed.
// It never creates or edits an attestation; all output still needs the full gate.
// Retained v1 JSON allows only head_sha, steps (step/status plus an approved
// test override_reason string without HTML comment delimiters), and optional
// live_validation (verdict/live/total), with decoded enum/count/private-display checks.
// Private no-mistakes-submissions rows are: <upstream> <fork> <contrib/branch>.
// Optional no-mistakes-test-exceptions uses the same validation and row format;
// a test override_reason requires an identical row in both private files.
// Test override reasons pass the same decoded safety checks in both modes.
// Review, test and document must still all be completed, including an exception.
// Only live GitHub facts bind the body to the approved fork branch and head.
// Exact-head checks are unchanged; new PR creation still requires that head.
// An existing PR's pre-push refresh requires synchronized fork and PR heads
// and a unique v1 attestation in the trusted live PR body naming that live head.
// This binds to the previous attested head, not the new commit, allowing the
// publisher's refresh-before-push order without accepting an unbound live update.
// This verifies author-editable v1 assertions, not cryptographic provenance;
// the new head remains an author assertion within that existing trust boundary.
// Exit 0 qualifies, 1 retains ordinary limits, 2 refuses malformed config.
// In sanitize mode, exit 3 refuses an eligible body with an unsafe/unknown layout.
import { readFileSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";

const [config, gh, dest, base, head, pr, selector, file, mode] = process.argv.slice(2);
try {
  const repo = /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/;
  const branch = /^contrib\/[A-Za-z0-9][A-Za-z0-9._/-]*$/;
  const loadRows = (name) => {
    const scope = path.join(config, name);
    const rows = existsSync(scope) ? readFileSync(scope, "utf8").split(/\r?\n/)
      .filter((line) => line.trim() && !line.trim().startsWith("#"))
      .map((line) => line.trim().split(/\s+/)) : [];
    if (rows.some((r) => r.length !== 3 || !repo.test(r[0]) || !repo.test(r[1])
      || r[0] === r[1] || !branch.test(r[2]) || r[2].includes(".."))) {
      process.stderr.write(`malformed ${name} config\n`);
      process.exit(2);
    }
    return rows;
  };
  const rows = loadRows("no-mistakes-submissions");
  const exceptions = loadRows("no-mistakes-test-exceptions");
  if (!rows.length) process.exit(1);
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
  if (!["review", "test", "document"].every((s) => steps.get(s)?.status === "completed")) process.exit(1);
  const test = steps.get("test");
  const testOverride = Object.hasOwn(test, "override_reason");
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
  let actualBase = base, actualBranch, fork, actualHead, actualBody;
  if (number) {
    if (!/^[0-9]+$/.test(number)) process.exit(1);
    const p = api(`repos/${dest}/pulls/${number}`);
    actualBase = p.base?.ref;
    if (base && base !== actualBase) process.exit(1);
    fork = p.head?.repo?.full_name;
    actualBranch = p.head?.ref;
    actualHead = p.head?.sha;
    actualBody = p.body;
  }
  if (actualBase !== "main") process.exit(1);
  const candidates = rows.filter((r) => r[0] === dest);
  for (const [upstream, approvedFork, approvedBranch] of candidates) {
    if (number ? (fork !== approvedFork || actualBranch !== approvedBranch)
      : head !== `${approvedFork.split("/")[0]}:${approvedBranch}`) continue;
    const approvedException = exceptions.some((r) => r[0] === upstream && r[1] === approvedFork && r[2] === approvedBranch);
    if (testOverride && !approvedException) continue;
    const f = api(`repos/${approvedFork}`);
    if (!f.fork || f.private !== false || f.full_name !== approvedFork || f.parent?.full_name !== upstream) continue;
    const ref = api(`repos/${approvedFork}/git/ref/heads/${approvedBranch}`);
    if (ref.object?.type !== "commit") continue;
    if (ref.object.sha !== a.head_sha || (number && actualHead !== a.head_sha)) {
      const current = typeof actualBody === "string" && actualBody.split(marker).length === 2
        ? /<!-- no-mistakes-pipeline-attestation:v1 ([\s\S]*?) -->/.exec(actualBody) : null;
      if (!number || ref.object.sha !== actualHead || !/^[0-9a-f]{40}$/.test(actualHead)
        || !current || JSON.parse(current[1])?.head_sha !== actualHead) continue;
    }
    const privateDisplay = /(?:```|~~~|<\/?(?:details|pre)\b|~[/\\]|\/(?:Users|home|tmp|private|var)\/|[A-Z]:\\Users\\|WATCHER DOWN|SUPERVISION IS OFF|^=== |\b[0-9A-HJKMNP-TV-Z]{26}\b|\b\d+(?:\.\d+)?(?:ms|[smh])(?:\d+(?:\.\d+)?[smh])*\b|\b\d{1,2}:\d{2}(?::\d{2})?\b)/im;
    if (testOverride && (typeof test.override_reason !== "string" || !test.override_reason.trim()
      || /<!--|--!?>/.test(test.override_reason) || privateDisplay.test(test.override_reason))) {
      process.exit(mode === "--sanitize" ? 3 : 1);
    }
    if (mode === "--sanitize") {
      const changed = /^## What Changed\s*\n([\s\S]*?)(?=^## |$(?![\s\S]))/im.exec(body)?.[1]?.trim();
      if (!changed) process.exit(3);
      // Never fall back to publishing raw evidence from an eligible body.
      // The original marker stays immutable, so private marker metadata refuses.
      const publicFields = (value, keys) => value && typeof value === "object"
        && !Array.isArray(value) && Object.keys(value).every((key) => keys.includes(key));
      if (!publicFields(a, ["head_sha", "steps", "live_validation"])
        || !a.steps.every((s) => publicFields(s, s.step === "test" && approvedException
          ? ["step", "status", "override_reason"] : ["step", "status"]))
        || privateDisplay.test(changed) || privateDisplay.test(match[0])) process.exit(3);
      const names = ["intent", "rebase", "review", "test", "document", "lint", "push", "pr", "ci"];
      const statuses = ["completed", "skipped", "running", "pending", "failed"];
      if ([...steps].some(([name, s]) => !names.includes(name) || !statuses.includes(s.status))) process.exit(3);
      const table = [...steps].map(([name, s]) => `| ${name} | ${s.status}${name === "test" && testOverride ? " (approved exception)" : ""} |`).join("\n");
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
