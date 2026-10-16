#!/usr/bin/env node
// Shared metadata-only credential classifier. JSON on stdin, verdict on stdout.
// Operations: read, write, copy, execute, load, metadata, exec-segment, native.
// Native apply_patch fields are its freeform string; the verdict also returns
// validated writeTargets for the adapter's ordinary write-root/wiring checks.
// Inputs carry literal operands with roles/expansion/glob flags, effective cwd,
// trusted userHome, recursion, trace, useGrants, and the firstmate-owned registry.
// The registry is config/declared-credentials.json, read afresh on each call:
// {version:1, revision:"...", entries:[{path:"/absolute/path", scope:"file"|
// "subtree", kind:"credential"|"nonsecret", use_modes:["source"], provenance:"..."}]}.
// A launch records registryRequired; removing/corrupting an expected registry
// holds content access. Live additions take effect before any ordinary cache.
// register-grants is an operator-only launch/repin operation: it retains source
// declarations under an exclusive registry lock and never removes identities.
// A revoked grant removes use authority, including for extensionless resources.
// No operand file is opened, enumerated, or included as contents in a verdict.
import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

const result = (category, reason) => ({ category, reason });
const inside = (p, root) => root && (p === root || p.startsWith(`${root.replace(/\/$/, "")}/`));
const fold = p => p.replace(/^\/private\/(tmp|var|etc)(?=\/|$)/, "/$1");

// Follow components before .., including the leaf, with one bound for all hops.
// A missing literal tail is resolvable; a dangling/cyclic alias is not.
function resolveOperand(value, cwd, userHome) {
  if (value === "~" || value.startsWith("~/")) {
    if (!userHome) throw new Error("home");
    value = userHome + value.slice(1);
  }
  if (!path.isAbsolute(value)) {
    if (!cwd || !path.isAbsolute(cwd)) throw new Error("cwd");
    value = `${cwd}/${value}`;
  }
  const lexical = fold(path.normalize(value));
  let parts = value.split("/"), current = "/", hops = 0, following = false;
  while (parts.length) {
    const part = parts.shift();
    if (!part || part === ".") continue;
    if (part === "..") { current = path.dirname(current); continue; }
    const next = path.join(current, part);
    let info;
    try { info = fs.lstatSync(next); }
    catch (error) {
      if (error.code !== "ENOENT" || following || parts.includes("..")) throw error;
      return { lexical, canonical: fold(path.join(next, ...parts)), exists: false };
    }
    if (info.isSymbolicLink()) {
      if (++hops > 40) throw new Error("symlink");
      const link = fs.readlinkSync(next);
      if (path.isAbsolute(link)) current = "/";
      parts = [...link.split("/"), ...parts];
      following = true;
    } else {
      current = next;
      following = false;
      if (parts.some(p => p && p !== ".") && !info.isDirectory()) throw new Error("directory");
    }
  }
  const info = fs.statSync(current);
  return { lexical, canonical: fold(current), exists: true, directory: info.isDirectory(),
    identity: `${info.dev}:${info.ino}` };
}

function protectedName(p, home) {
  const components = p.toLowerCase().split("/");
  if (components.some(c => /\.env($|\.)/.test(c)
    || /credentials|\.ssh|\.gnupg|\.netrc|\.git-credentials|\.npmrc|\.pypirc|id_(rsa|ed25519|ecdsa|dsa)|hosts\.yml|keychain/.test(c)
    || /^(credential(\..*)?|.*\.(pem|p12|pfx|key)(\..*)?)$/.test(c)
    || c.includes("antigravity-oauth-token")
    || /\.aws$/.test(c))) return true;
  const locations = [".config/gh", ".config/devin", ".devin/config", ".docker/config.json",
    ".gemini/oauth_creds.json", ".config/gcloud", ".config/antigravity-oauth-token"];
  // Conservative names cover case aliases on case-insensitive filesystems,
  // just as the filename patterns above do, without reading file contents.
  return !!home && locations.some(l => inside(p.toLowerCase(), fold(path.join(home, l)).toLowerCase()));
}

function registry(context) {
  if (!context.registryPath) return { entries: [], invalid: !!context.registryRequired };
  try {
    // This is the sole content read: an operator-owned metadata registry.
    const info = fs.lstatSync(context.registryPath);
    const resolved = resolveOperand(context.registryPath, "", context.userHome);
    if ((context.writeRoots || []).some(root => {
      let physical;
      try { physical = resolveOperand(root, context.cwd, context.userHome).canonical; }
      catch { return true; }
      return inside(resolved.canonical, physical) || inside(fold(context.registryPath), fold(root));
    })) throw new Error("mutable registry");
    if (!info.isFile() || info.isSymbolicLink() || info.size > 131072) throw new Error("registry");
    const r = JSON.parse(fs.readFileSync(context.registryPath, "utf8"));
    if (r.version !== 1 || typeof r.revision !== "string" || !r.revision || !Array.isArray(r.entries)
      || r.entries.length > 256) throw new Error("schema");
    const entries = r.entries.map(e => {
      if (!e || typeof e.path !== "string" || !path.isAbsolute(e.path)
        || /[\x00-\x1f*?\[\]]/.test(e.path) || !["file", "subtree"].includes(e.scope)
        || !["credential", "nonsecret"].includes(e.kind)
        || (e.kind === "nonsecret" && e.scope !== "file")
        || typeof e.provenance !== "string" || !e.provenance
        || !Array.isArray(e.use_modes) || e.use_modes.some(m => m !== "source")) throw new Error("entry");
      const resolved = resolveOperand(e.path, "", context.userHome);
      return { ...e, ...resolved };
    });
    return { entries, invalid: false };
  } catch (error) {
    return { entries: [], invalid: error.code !== "ENOENT" || !!context.registryRequired };
  }
}

// Bounded contention handling. A live PID is never evicted by lock age, and
// missing/uncertain owner metadata needs operator repair rather than guessing.
// A marker inside the old directory serializes dead-owner recovery; renaming
// that directory before cleanup cannot remove a replacement holder's lock.
function acquireRegistryLock(lock) {
  const token = crypto.randomBytes(16).toString("hex"), ownerFile = `${lock}/owner.json`;
  const same = (a, b) => a.dev === b.dev && a.ino === b.ino;
  const dead = pid => {
    if (!Number.isSafeInteger(pid) || pid <= 0) return false;
    try { process.kill(pid, 0); return false; }
    catch (error) { return error.code === "ESRCH"; }
  };
  const owner = () => JSON.parse(fs.readFileSync(ownerFile, "utf8"));
  const deadline = Date.now() + 5000;
  do {
    let acquired;
    try { fs.mkdirSync(lock, { mode: 0o700 }); acquired = fs.lstatSync(lock); }
    catch (error) { if (error.code !== "EEXIST") throw error; }
    if (acquired) {
      try { fs.writeFileSync(ownerFile, JSON.stringify({ pid: process.pid, token }), { flag: "wx", mode: 0o600 }); }
      catch (error) { fs.rmdirSync(lock); throw error; }
      return () => {
        if (same(acquired, fs.lstatSync(lock)) && owner().token === token) fs.rmSync(lock, { recursive: true });
      };
    }
    const recovery = `${lock}/recover`;
    let marker;
    try {
      const previous = fs.lstatSync(lock), recorded = owner();
      if (previous.isDirectory() && !previous.isSymbolicLink() && dead(recorded.pid)) {
        fs.mkdirSync(recovery, { mode: 0o700 }); marker = fs.lstatSync(recovery);
        const current = owner();
        if (same(previous, fs.lstatSync(lock)) && current.token === recorded.token && dead(current.pid)) {
          const retired = `${lock}.${crypto.randomBytes(16).toString("hex")}.retired`;
          fs.renameSync(lock, retired);
          fs.rmSync(retired, { recursive: true });
          continue;
        }
      }
    } catch { /* Another registration/recovery or uncertain metadata: retry. */ }
    finally {
      if (marker) {
        try { if (same(marker, fs.lstatSync(recovery))) fs.rmdirSync(recovery); }
        catch { /* The old directory was retired or its holder finished. */ }
      }
    }
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
  } while (Date.now() < deadline);
  throw Object.assign(new Error("lock"), { reason: "credential-registry-lock-unavailable" });
}

// Operator-only launch/repin registration, separate from the pure classifier.
// Firstmate retains known identities here; revoking task use never removes them.
function registerGrants(context) {
  if (!(context.useGrants || []).length) {
    return registry(context).invalid ? result("unresolved", "credential-registration-unavailable")
      : result("ordinary", "no-new-credential-identities");
  }
  if (!context.registryPath) return result("unresolved", "missing-registry-location");
  const lock = `${context.registryPath}.lock`;
  let temporary = "", releaseLock;
  try {
    const parent = resolveOperand(path.dirname(context.registryPath), "", context.userHome).canonical;
    for (const root of context.writeRoots || []) {
      if (inside(parent, resolveOperand(root, context.cwd, context.userHome).canonical)) throw new Error("mutable");
    }
    fs.mkdirSync(parent, { recursive: true, mode: 0o700 });
    releaseLock = acquireRegistryLock(lock);
    const state = registry(context);
    if (state.invalid) throw new Error("registry");
    const document = fs.existsSync(context.registryPath)
      ? JSON.parse(fs.readFileSync(context.registryPath, "utf8")) : { version: 1, revision: "initial", entries: [] };
    let changed = false;
    for (const grant of context.useGrants) {
      if (/[\x00-\x1f*?\[\]]/.test(grant)) throw new Error("grant");
      const identity = resolveOperand(grant, context.cwd, context.userHome);
      if (document.entries.some(e => e.path === identity.lexical && e.kind === "credential")) continue;
      if (document.entries.length >= 256) throw new Error("capacity");
      document.entries.push({ path: identity.lexical, scope: "file", kind: "credential",
        use_modes: ["source"], provenance: "firstmate source declaration" });
      changed = true;
    }
    if (changed) {
      document.revision = crypto.createHash("sha256").update(JSON.stringify(document.entries)).digest("hex");
      temporary = `${context.registryPath}.${process.pid}.${crypto.randomBytes(6).toString("hex")}.tmp`;
      fs.writeFileSync(temporary, JSON.stringify(document, null, 2) + "\n", { flag: "wx", mode: 0o600 });
      fs.renameSync(temporary, context.registryPath); temporary = "";
    }
    return result("ordinary", "retained-credential-identities");
  } catch (error) {
    return result("unresolved", error.reason === "credential-registry-lock-unavailable"
      ? error.reason : "credential-registration-unavailable");
  } finally {
    if (temporary) { try { fs.unlinkSync(temporary); } catch { /* no partial publication */ } }
    if (releaseLock) releaseLock();
  }
}

export function classify_credential_access(request, state = registry(request)) {
  if (request.environmentDisclosure) return result("protected-disclosure", "environment-or-token-output");
  if (request.operation === "metadata") return result("ordinary", "metadata-only-access");
  let protectedHit = false, modes = null;
  const operands = request.operands || [];
  for (const operand of operands) {
    if (!operand.path || operand.role === "data" || operand.role === "pattern") continue;
    const homeOnlyExpansion = /^~(?:\/|$)/.test(operand.path) && !/[$`]/.test(operand.path);
    if ((operand.expanded && !homeOnlyExpansion) || operand.glob) {
      // A removal/attribute change does not select content to disclose;
      // its existing physical-write rules remain the authority for effects.
      if (request.operation === "write") continue;
      if (request.operation !== "metadata") return result("unresolved", "dynamic-path-selection");
      continue;
    }
    let resolved;
    const literalPath = operand.path.startsWith("~") && !operand.expanded ? `./${operand.path}` : operand.path;
    try { resolved = resolveOperand(literalPath, request.cwd, request.userHome); }
    catch { return result("unresolved", "unresolvable-path-identity"); }
    const matches = state.entries.filter(e => [resolved.lexical, resolved.canonical].some(p =>
      e.scope === "subtree" ? inside(p, e.lexical) || inside(p, e.canonical)
        : p === e.lexical || p === e.canonical)
      || (e.scope === "file" && e.identity && e.identity === resolved.identity));
    const declared = matches.filter(e => e.kind === "credential");
    const nonsecret = matches.some(e => e.kind === "nonsecret") && !declared.length;
    const granted = (request.useGrants || []).some(g => {
      try { const r = resolveOperand(g, request.cwd, request.userHome);
        return r.lexical === resolved.lexical || r.canonical === resolved.canonical;
      } catch { return false; }
    });
    const sensitive = declared.length || granted || (!nonsecret
      && [resolved.lexical, resolved.canonical].some(p => protectedName(p, request.userHome)));
    if (sensitive) {
      protectedHit = true;
      modes = declared.length ? declared.every(e => e.use_modes.includes("source")) : true;
      if (request.operation !== "load" || !granted || !modes || request.trace
        || operands.length !== 1 || request.dynamicSelection) {
        return result("protected-disclosure", request.trace && request.operation === "load"
          ? "traced-credential-load" : "protected-path-access");
      }
    }
    if (resolved.directory && ["read", "copy"].includes(request.operation) && operand.role !== "destination") {
      return result("unresolved", "content-traversal-footprint");
    }
  }
  if (request.operation !== "metadata" && (request.recursive || request.dynamicSelection)) {
    return result("unresolved", "content-traversal-footprint");
  }
  if (state.invalid && request.operation !== "metadata" && operands.length) {
    return result("unresolved", "credential-registry-unavailable");
  }
  return protectedHit ? result("authorized-load", "task-authorized-source") : result("ordinary", "fixed-ordinary-access");
}

const word = (value, role = "source") => typeof value === "string"
  ? { path: value, role } : { path: value.value, role, expanded: value.expanded, glob: value.glob };
const ranked = values => values.sort((a, b) => ({ ordinary: 0, "authorized-load": 1, unresolved: 2,
  "protected-disclosure": 3 }[b.category] - { ordinary: 0, "authorized-load": 1, unresolved: 2,
  "protected-disclosure": 3 }[a.category]))[0] || result("ordinary", "no-content-access");

function jqEnvironment(values) {
  for (let i = 1; i < values.length; i++) {
    const v = values[i];
    if (["--arg", "--argjson", "--rawfile", "--slurpfile"].includes(v)) { i += 2; continue; }
    if (["-f", "--from-file", "-L", "--library-path"].includes(v)) { i++; continue; }
    if (v.startsWith("-")) continue;
    // An env property or a literal string is not jq's environment operator.
    // Keep interpolation-bearing strings, whose expressions can dump env.
    const filter = v.replace(/"(?:\\.|[^"\\])*"/g, s => s.includes("\\(") ? s : '""');
    return /(^|[^\w.])env([^\w]|$)|\$ENV\b/.test(filter);
  }
  return false;
}

function segment(request) {
  const words = request.words || [], values = words.map(w => w.value), base = path.basename(values[0] || "");
  const calls = [], operands = [];
  const add = (operation, extra = {}) => calls.push({ ...request, operation, operands: [...operands], ...extra });
  for (const r of request.redirects || []) {
    const descriptor = ["<&", ">&"].includes(r.operator) && /^(?:[0-9]+-?|-)$/u.test(r.path);
    if (["<", "<>", "<&"].includes(r.operator) && !descriptor) {
      calls.push({ ...request, operation: "read", operands: [r] });
    }
    if ([">", ">>", ">|", "<>", "&>", "&>>", ">&"].includes(r.operator)
      && !descriptor) {
      calls.push({ ...request, operation: "write", operands: [{ ...r, role: "destination" }] });
    }
  }
  // Credential semantics also apply to explicit-path wrapper invocations;
  // these checks confer no executable-identity or ordinary command authority.
  if (["env", "xargs", "nohup", "nice", "timeout", "command", "builtin", "exec"].includes(base)) {
    if ((request.depth || 0) >= 16 || base === "xargs") return result("unresolved", "wrapper-selected-input");
    let i = 1, dynamic = !!request.dynamicSelection;
    while (i < words.length) {
      const v = values[i];
      if (v === "--") { i++; break; }
      if (base === "env" && (v.startsWith("-S") || v.startsWith("--split-string"))) return result("unresolved", "wrapper-inline-program");
      if (base === "env" && /^\w+=/.test(v)) { i++; continue; }
      if (!v.startsWith("-")) break;
      if (base === "env" && ["-C", "--chdir"].includes(v)) dynamic = true;
      if (base === "env" && v.startsWith("--chdir=")) dynamic = true;
      i += (base === "env" && ["-u", "--unset", "-C", "--chdir"].includes(v))
        || (base === "nice" && v === "-n")
        || (base === "timeout" && ["-s", "-k", "--signal", "--kill-after"].includes(v)) ? 2 : 1;
    }
    if (base === "timeout" && i < words.length) i++;
    if (i >= words.length) {
      const verdict = base === "env" ? result("protected-disclosure", "environment-or-token-output") : result("ordinary", "wrapper-metadata");
      return ranked([...calls.map(c => classify_credential_access(c)), verdict]);
    }
    return ranked([...calls.map(c => classify_credential_access(c)), segment({ ...request, words: words.slice(i),
      redirects: [], dynamicSelection: dynamic, depth: (request.depth || 0) + 1 })]);
  }
  const outputExpansion = ["echo", "printf"].includes(base) && words.slice(1).some(w => w.expanded);
  const metadataSecretOutput = ["ls", "stat", "du", "df", "tree", "find", "readlink", "realpath", "ps"].includes(base)
    && words.slice(1).some(w => w.expanded && /\$(?:\{)?[A-Za-z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL)/i.test(w.value));
  const envPrinter = (base === "set" && values.length === 1)
    || (request.trace && ["set", "bash", "sh", "zsh", "ksh", "dash"].includes(base))
    || ["printenv"].includes(base)
    || (["export", "declare", "typeset"].includes(base) && (values.length === 1 || values.includes("-p")))
    || (base === "env" && (request.bareEnvironment || values.length === 1
      || values.slice(1).every(v => v.startsWith("-"))))
    || (base === "jq" && jqEnvironment(values))
    || (base === "ps" && values.slice(1).some(v => /^[A-Za-z]*e[A-Za-z]*$/.test(v) || v === "--environment" || v === "-E"))
    || (base === "gh" && values.includes("auth") && (values.includes("token") || values.some(v => v.startsWith("--show-token"))));
  if (envPrinter || outputExpansion || metadataSecretOutput) add("read", { environmentDisclosure: true });
  if (["source", "."].includes(base)) {
    operands.push(...words.slice(1).map(w => word(w)));
    add("load", { dynamicSelection: request.dynamicSelection || words.length !== 2 });
  } else if (["rm", "mv", "shred", "mkdir", "touch", "chmod"].includes(base)) {
    operands.push(...words.slice(1).filter(w => !w.value.startsWith("-")).map(w => word(w, "destination")));
    add("write");
  } else if (["ls", "stat", "du", "df", "find", "tree", "readlink", "realpath", "test", "[", "cd", "pushd"].includes(base)) {
    operands.push(...words.slice(1).filter(w => !w.value.startsWith("-")).map(w => word(w)));
    if (base === "find" && values.some(v => ["-exec", "-execdir", "-ok", "-okdir"].includes(v))) add("read", { dynamicSelection: true });
    else add("metadata");
  } else if (["echo", "printf", "pwd", "which", "type", "date", "true", "false", "sleep", "seq", "set", "env", "ps"].includes(base)) {
    // These arguments are data, unless an explicit output form above applies.
  } else {
    const search = ["grep", "egrep", "fgrep", "rg"].includes(base);
    const readers = ["cat", "head", "tail", "wc", "nl", "od", "hexdump", "strings", "file", "shasum", "sha1sum", "sha256sum", "md5", "md5sum", "cut", "sort", "uniq", "comm", "paste", "fold", "rev", "column", "diff", "cmp"];
    const copy = ["cp", "install", "rsync"].includes(base);
    const relevant = search || readers.includes(base) || copy || ["sed", "gsed", "jq"].includes(base);
    let pattern = false, options = true, recursive = false, unresolved = !!request.dynamicSelection;
    if (relevant) {
      for (let i = 1; i < words.length; i++) {
        const v = values[i];
        if (options && v === "--") { options = false; continue; }
        if (options && v.startsWith("-") && v !== "-") {
          if ((search || copy) && /^-[^-]*[rR]/.test(v) || ["--recursive", "--dereference-recursive"].includes(v)) recursive = true;
          const name = v.split("=")[0];
          if ((["-f", "--file", "--from-file"].includes(name) && (search || ["sed", "gsed", "jq", "hexdump", "file"].includes(base)))
            || ["--ignore-file", "--exclude-from", "--files0-from", "--files-from"].includes(name)) {
            const value = v.includes("=") ? word(v.slice(v.indexOf("=") + 1), "option-file") : word(words[++i] || "", "option-file");
            operands.push(value);
            if (["--files0-from", "--files-from"].includes(name) || base === "file") unresolved = true;
            if (["-f", "--file"].includes(name)) pattern = true;
            continue;
          }
          if (base === "jq" && ["--rawfile", "--slurpfile"].includes(name)) {
            i++; operands.push(word(words[++i] || "", "option-file")); continue;
          }
          if ((base === "jq" || ["sed", "gsed"].includes(base)) && /^-f.+/.test(v)) {
            operands.push(word(v.slice(2), "option-file")); pattern = true; continue;
          }
          if (["-e", "--regexp", "--expression"].includes(name) && (search || ["sed", "gsed"].includes(base))) {
            if (!v.includes("=")) i++; pattern = true; continue;
          }
          const takesValue = search ? ["-g", "--glob", "--iglob", "-t", "-T", "--type", "--type-not", "-m", "--max-count", "-A", "-B", "-C", "--context", "--encoding"]
            : base === "jq" ? ["--arg", "--argjson"]
              : ({ head: ["-n", "-c", "--lines", "--bytes"], tail: ["-n", "-c", "--lines", "--bytes", "--sleep-interval"],
                nl: ["-b", "-d", "-i", "-l", "-n", "-s", "-v", "-w"], od: ["-A", "-j", "-N", "-t", "-w"],
                hexdump: ["-e", "-n", "-s"], strings: ["-n", "-t", "-e", "--bytes", "--encoding"],
                shasum: ["-a", "--algorithm"], cut: ["-b", "-c", "-f", "-d", "--bytes", "--characters", "--fields", "--delimiter"],
                sort: ["-k", "-t", "-o", "-T", "--key", "--field-separator", "--output", "--temporary-directory"],
                uniq: ["-f", "-s", "-w", "--skip-fields", "--skip-chars", "--check-chars"],
                paste: ["-d", "--delimiters"], fold: ["-w", "--width"], column: ["-c", "-s", "--columns", "--separator"],
                diff: ["-I", "-x", "--ignore-matching-lines", "--exclude"], cmp: ["-i", "-n", "--ignore-initial", "--bytes"],
                install: ["-m", "-o", "-g", "--mode", "--owner", "--group"], rsync: ["--include", "--exclude"]
              }[base] || []);
          if (takesValue.includes(name) && !v.includes("=")) {
            i++; if (base === "jq" && ["--arg", "--argjson"].includes(name)) i++;
          } else if (/^--(pre|pre-glob|files-from|include-from|exclude-from|arg-file)/.test(v)) unresolved = true;
          else if (search && /^-[ef].+/.test(v)) {
            if (v[1] === "f") operands.push(word(v.slice(2), "option-file"));
            pattern = true;
          }
          continue;
        }
        if ((search || ["sed", "gsed", "jq"].includes(base)) && !pattern) { pattern = true; continue; }
        operands.push(word(words[i]));
      }
      if (base === "rg" && values.includes("--files")) add("metadata");
      else {
        if (search && base === "rg" && !operands.length) recursive = true;
        if (copy && operands.length) operands[operands.length - 1].role = "destination";
        add(copy ? "copy" : "read", { recursive, dynamicSelection: unresolved });
      }
    } else {
      // Explicit path and @file operands on opaque programs remain protected.
      // Opaque code itself is outside this classifier's security guarantee.
      let gitVerb = "";
      if (base === "git") {
        let i = 1;
        while (i < words.length && values[i].startsWith("-")) {
          if (values[i] === "-C") {
            try { request = { ...request, cwd: resolveOperand(values[i + 1], request.cwd, request.userHome).canonical }; }
            catch { request = { ...request, dynamicSelection: true }; }
            i += 2;
          } else if (["-c", "--git-dir", "--work-tree"].includes(values[i])) i += 2;
          else i++;
        }
        gitVerb = values[i] || "";
      }
      for (let i = 0; i < words.length; i++) {
        const v = values[i];
        if (words[i].expanded && !/^~(?:\/|$)/.test(v) || words[i].glob) continue;
        const previous = values[i - 1] || "";
        if (base === "git" && previous === "-C") continue;
        if (["bash", "sh", "zsh", "ksh", "dash"].includes(base) && /^-[^-]*c/.test(previous)) continue;
        if (["python", "python3", "node", "perl", "ruby"].includes(base) && ["-c", "-e", "--eval"].includes(previous)) continue;
        if ((base === "git" && ["-m", "--message", "--grep"].includes(previous))
          || (base === "gh" && ["--body", "--title", "--jq", "-q", "--template"].includes(previous))) continue;
        if (base === "gh" && /^(--body-file|--input)$/.test(v)) {
          operands.push(word(words[++i] || "", "option-file")); continue;
        }
        if (v.startsWith("-")) {
          if (/^--(body-file|input|file|config|cert|key|cacert)=/.test(v)) {
            operands.push(word(v.slice(v.indexOf("=") + 1).replace(/^@/, ""), "option-file"));
          }
          continue;
        }
        const input = base === "git" && ["show", "cat-file"].includes(gitVerb)
          ? v.replace(/^[^:]+:/, "") : v;
        operands.push(word({ ...words[i], value: input.replace(/^.*=@/, "").replace(/^@/, "") }));
      }
      if (operands.length) add("execute", { recursive: gitVerb === "grep" });
    }
  }
  if (request.dynamicSelection && !calls.length) add("read", { dynamicSelection: true });
  const state = registry(request);
  return ranked(calls.map(c => classify_credential_access(c, state)));
}

// Parse the complete freeform patch, not just a prefix or the first filename.
// Return every write operand, including both sides of a move; ambiguous input
// never supplies a partial target list to either policy consumer.
function patchTargets(patch) {
  if (typeof patch !== "string" || patch.includes("\0")) throw new Error("patch");
  const lines = patch.split(/\r?\n/);
  if (lines[lines.length - 1] === "") lines.pop();
  const end = lines.length - 1, targets = [];
  if (lines[0] !== "*** Begin Patch" || lines[end] !== "*** End Patch") throw new Error("patch");
  const target = value => {
    // apply_patch trims header line endings before extracting paths (including
    // Move to). Match Rust trim_end Unicode whitespace, preserving leading spaces.
    value = value.replace(/\p{White_Space}+$/u, "");
    if (!value.trim() || /[\x00-\x1f\x7f]/.test(value)) throw new Error("path");
    targets.push(value);
  };
  let i = 1;
  while (i < end) {
    const header = /^\*\*\* (Add|Update|Delete) File: (.+)$/.exec(lines[i++]);
    if (!header) throw new Error("header");
    target(header[2]);
    if (header[1] === "Delete") continue;
    if (header[1] === "Add") {
      while (i < end && lines[i].startsWith("+")) i++;
      continue;
    }
    if (i < end && lines[i].startsWith("*** Move to: ")) target(lines[i++].slice("*** Move to: ".length));
    let changes = 0, chunkStarted = false;
    while (i < end && !/^\*\*\* (Add|Update|Delete) File: /.test(lines[i])) {
      const line = lines[i++];
      if (line === "*** End of File" && changes) break;
      if (line !== "@@" && !line.startsWith("@@ ") && !/^[ +\-]/.test(line)) throw new Error("change");
      if (line === "@@" || line.startsWith("@@ ")) {
        if (chunkStarted && !changes) throw new Error("empty update chunk");
        changes = 0;
        chunkStarted = true;
      } else {
        changes++;
      }
    }
    if (!changes) throw new Error("empty update");
  }
  if (!targets.length) throw new Error("empty patch");
  return targets;
}

function native(request) {
  const a = request.fields, tool = request.tool;
  if (tool === "apply_patch") {
    let writeTargets;
    try { writeTargets = patchTargets(a); }
    catch { return result("unresolved", "unparsed-apply-patch"); }
    const verdict = writeTargets.some(p => p.startsWith("~"))
      ? result("unresolved", "ambiguous-native-home-expansion")
      : classify_credential_access({ ...request, operation: "write",
        operands: writeTargets.map(p => word(p, "native:patch-target")),
        dynamicSelection: false });
    return { ...verdict, writeTargets };
  }
  if (!a || typeof a !== "object" || Array.isArray(a)) return result("unresolved", "invalid-native-fields");
  const localUri = [a.Url, a.URL, a.url].find(u => typeof u === "string" && /^file:/i.test(u));
  if (localUri) {
    try { return classify_credential_access({ ...request, operation: "read", operands: [word(fileURLToPath(localUri), "native:local-uri")] }); }
    catch { return result("unresolved", "unresolved-native-uri"); }
  }
  if (tool === "search_web") return result("ordinary", "remote-query-data");
  if (tool === "read_url_content") {
    const url = a.Url || a.URL || a.Query || "";
    if (/^https?:\/\//i.test(url)) return result("ordinary", "remote-http-read");
    try {
      const filename = fileURLToPath(url);
      return classify_credential_access({ ...request, operation: "read", operands: [word(filename, "native:local-uri")] });
    } catch { return result("unresolved", "unresolved-native-uri"); }
  }
  const metadata = ["glob", "list_dir"].includes(tool);
  const search = ["grep", "grep_search"].includes(tool);
  const operands = [];
  for (const name of ["file_path", "path", "notebook_path", "TargetFile", "AbsolutePath", "FilePath", "File", "SearchPath", "DirectoryPath", "RootDirectory", ...(metadata ? ["Input"] : [])]) {
    if (typeof a[name] === "string" && a[name]) operands.push(word(a[name], `native:${name}`));
  }
  if (metadata) return classify_credential_access({ ...request, operation: "metadata", operands });
  if (operands.some(o => o.path.startsWith("~"))) return result("unresolved", "ambiguous-native-home-expansion");
  if (search && !operands.length) operands.push(word(request.cwd, "search-root"));
  const knownFileTool = ["read", "notebook_read", "write", "edit", "notebook_edit", "view_file", "write_to_file", "replace_file_content"].includes(tool);
  if (!operands.length && !search && !knownFileTool) return result("ordinary", "no-known-file-operand");
  const recursive = search && (a.recursive !== false && a.Recursive !== false);
  const write = ["write", "edit", "notebook_edit", "write_to_file", "replace_file_content"].includes(tool);
  return classify_credential_access({ ...request, operation: write ? "write" : "read", operands, recursive,
    dynamicSelection: !operands.length || operands.some(o => /[$*?\[\]]/.test(o.path)) });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    const request = JSON.parse(fs.readFileSync(0, "utf8"));
    const verdict = request.operation === "register-grants" ? registerGrants(request)
      : request.operation === "exec-segment" ? segment(request)
      : request.operation === "native" ? native(request) : classify_credential_access(request);
    process.stdout.write(JSON.stringify(verdict) + "\n");
    if (request.operation === "register-grants" && verdict.category !== "ordinary") process.exitCode = 1;
  } catch {
    process.stdout.write(JSON.stringify(result("unresolved", "invalid-classifier-metadata")) + "\n");
  }
}
