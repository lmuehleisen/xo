#!/usr/bin/env node
// Outgoing Git adapter for isolated publishers, including commit-tree evidence.
// Usage: fm-git-publish-exec.mjs <absolute-real-git> <git-args>...
// Known ordinary commands preserve argv; aliases and publishing plumbing
// are refused. Pushes accept -C plus an explicit remote and branch refspecs.
// Named remotes resolve URL rewrites through Git before destination checks.
// Rewritten explicit URLs/legacy remotes refuse; use a configured remote.
// Implicit mirror/tag/helper publication and unsupported forms fail closed.
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
  let cwd = process.cwd(), i = 0, otherGlobals = false;
  while (argv[i]?.startsWith("-")) {
    const flag = argv[i];
    if (flag === "-C") {
      if (!argv[i + 1]) throw new Error("missing -C directory");
      cwd = path.resolve(cwd, argv[i + 1]); i += 2; continue;
    }
    // The trusted scanner needs literal path names; this exact formatting
    // setting cannot select aliases, identity, hooks or a publishing target.
    if (flag === "-c" && argv[i + 1]?.toLowerCase() === "core.quotepath=false") {
      otherGlobals = true; i += 2; continue;
    }
    if (flag.toLowerCase() === "-ccore.quotepath=false") {
      otherGlobals = true; i += 1; continue;
    }
    if (["--git-dir", "--work-tree"].includes(flag)) {
      if (!argv[i + 1]) throw new Error("missing Git directory");
      otherGlobals = true; i += 2; continue;
    }
    if (/^--(?:git-dir|work-tree)=.+$/.test(flag) || ["--no-pager", "--no-optional-locks"].includes(flag)) {
      otherGlobals = true; i += 1; continue;
    }
    if (["--version", "--help"].includes(flag) && argv.length === 1) break;
    throw new Error("unsupported global options for git");
  }
  const ordinary = new Set(("add apply branch cat-file check-attr check-ignore check-ref-format checkout checkout-index cherry-pick clean clone commit commit-tree config describe diff diff-index diff-tree fetch for-each-ref fsck gc hash-object init log ls-files ls-remote ls-tree merge merge-base mktree mv notes patch-id pull rebase read-tree reflog remote reset restore rev-list rev-parse revert rm show show-ref stash status switch symbolic-ref tag update-index update-ref version worktree write-tree --version --help").split(" "));
  if (argv[i] !== "push" && !ordinary.has(argv[i])) throw new Error("unsupported git command; aliases and publishing plumbing are refused");
  if (argv[i] === "push" && otherGlobals) throw new Error("unsupported global options for push");
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
    let rawUrl = remote, url, rewrittenExplicit = false;
    const named = spawnSync(real, ["config", "--get-all", `remote.${remote}.url`], { argv0: "git", cwd, encoding: "utf8" });
    const configured = (key, bool = false) => {
      const r = spawnSync(real, ["config", ...(bool ? ["--bool"] : []), "--get", key], { argv0: "git", cwd, encoding: "utf8" });
      if (![0, 1].includes(r.status)) throw new Error("cannot read push configuration");
      return r.status === 0 ? r.stdout.trim() : "";
    };
    if (configured("push.followTags", true) === "true") throw new Error("implicit tag publication refused");
    if (named.status === 0) {
      const push = spawnSync(real, ["config", "--get-all", `remote.${remote}.pushurl`], { argv0: "git", cwd, encoding: "utf8" });
      const rawUrls = (push.status === 0 ? push.stdout : named.stdout).trim().split("\n");
      if (rawUrls.length !== 1) throw new Error("multiple push destinations refused");
      [rawUrl] = rawUrls;
      if (configured(`remote.${remote}.mirror`, true) === "true" || configured(`remote.${remote}.vcs`)) throw new Error("implicit mirror or remote-helper publication refused");
      url = run(["remote", "get-url", "--push", "--all", remote]);
    } else if (named.status === 1) {
      // --get-url performs no connection and exposes insteadOf and legacy
      // remote indirection. Git has no equivalent push-URL query for a literal
      // target; require a configured remote when rewriting could affect it.
      url = run(["ls-remote", "--get-url", remote]);
      const rewrites = spawnSync(real, ["config", "--null", "--get-regexp", "^url\\..*\\.pushinsteadof$"], { argv0: "git", cwd, encoding: "utf8" });
      if (![0, 1].includes(rewrites.status)) throw new Error("cannot read URL rewrite configuration");
      rewrittenExplicit = url !== remote;
      for (const row of rewrites.stdout.split("\0").filter(Boolean)) {
        const split = row.indexOf("\n");
        if (split < 0) throw new Error("cannot parse URL rewrite configuration");
        if (remote.startsWith(row.slice(split + 1))) rewrittenExplicit = true;
      }
    } else {
      throw new Error("cannot read push destination");
    }
    if (!url || url.includes("\n")) throw new Error("multiple or empty push destinations refused");
    if (rawUrl === "DISABLED" || url === "DISABLED") throw new Error("remote pushes disabled");
    if (gateOptions && rewrittenExplicit) throw new Error("gate options require an unrewritten configured local gate");
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
    if (process.env.FM_PUBLISH_EXEC_BLOCK === "1" && [rawUrl, url].some((target) => /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(target) && !target.startsWith("file://") || /^[^/]+:/.test(target))) throw new Error("network pushes blocked pending contribution approval");
    if (rewrittenExplicit) throw new Error("explicit URL rewrite or legacy remote refused; use a configured remote");
  }
  const forwarded = argv[i] === "push" ? argv.filter((arg) => arg !== "--no-verify") : argv;
  const result = spawnSync(real, forwarded, { argv0: "git", stdio: "inherit" });
  if (result.error) throw new Error("real git execution failed");
  process.exitCode = result.status ?? 1;
} catch (error) {
  process.stderr.write(`fm-git-publish-exec: REFUSED: ${error.message}\n`);
  process.exitCode = 1;
}
