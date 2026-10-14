#!/usr/bin/env node
// Shared metadata-only credential classifier. JSON on stdin, verdict on stdout.
// Operations: read, write, copy, execute, load, metadata, exec-segment, native.
// Inputs carry literal operands with roles/expansion/glob flags, effective cwd,
// trusted userHome, recursion, trace, useGrants, and the firstmate-owned registry.
// The registry is config/declared-credentials.json, read afresh on each call:
// {version:1, revision:"...", entries:[{path:"/absolute/path", scope:"file"|
// "subtree", kind:"credential"|"nonsecret", use_modes:["source"], provenance:"..."}]}.
// A launch records registryRequired; removing/corrupting an expected registry
// holds content access. Live additions take effect before any ordinary cache.
// No operand file is opened, enumerated, or included as contents in a verdict.
import fs from "node:fs";
import path from "node:path";
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
  if (components.some(c => /(^|\.)env($|\.)/.test(c)
    || /^(id_(rsa|ed25519|ecdsa|dsa)(\..*)?|\.netrc|\.git-credentials|\.npmrc|\.pypirc|hosts\.yml|credentials?(\..*)?|.*\.(pem|p12|pfx|key))$/.test(c)
    || c.includes("antigravity-oauth-token")
    || [".ssh", ".aws", ".gnupg", "keychains", "keychain"].includes(c))) return true;
  const locations = [".config/gh", ".config/devin", ".devin/config", ".docker/config.json",
    ".gemini/oauth_creds.json", ".config/gcloud", ".config/antigravity-oauth-token"];
  return !!home && locations.some(l => inside(p, fold(path.join(home, l))));
}

function registry(context) {
  if (!context.registryPath) return { entries: [], invalid: !!context.registryRequired };
  if ((context.writeRoots || []).some(root => inside(fold(context.registryPath), fold(root)))) {
    return { entries: [], invalid: true };
  }
  try {
    // This is the sole content read: an operator-owned metadata registry.
    const info = fs.lstatSync(context.registryPath);
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

export function classify_credential_access(request, state = registry(request)) {
  if (request.environmentDisclosure) return result("protected-disclosure", "environment-or-token-output");
  let protectedHit = false, modes = null;
  const operands = request.operands || [];
  for (const operand of operands) {
    if (!operand.path || operand.role === "data" || operand.role === "pattern") continue;
    if ((operand.expanded && !/^~(?:\/|$)/.test(operand.path)) || operand.glob) {
      if (request.operation !== "metadata") return result("unresolved", "dynamic-path-selection");
      continue;
    }
    let resolved;
    try { resolved = resolveOperand(operand.path, request.cwd, request.userHome); }
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

function segment(request) {
  const words = request.words || [], values = words.map(w => w.value), base = path.basename(values[0] || "");
  const calls = [], operands = [];
  const add = (operation, extra = {}) => calls.push({ ...request, operation, operands: [...operands], ...extra });
  for (const r of request.redirects || []) {
    if (["<", "<>", "<&"].includes(r.operator) && !/^[0-9-]+$/.test(r.path)) {
      calls.push({ ...request, operation: "read", operands: [r] });
    }
  }
  const outputExpansion = ["echo", "printf"].includes(base) && words.slice(1).some(w => w.expanded);
  const envPrinter = (base === "set" && values.length === 1)
    || ["printenv"].includes(base)
    || (["export", "declare", "typeset"].includes(base) && (values.length === 1 || values.includes("-p")))
    || (base === "env" && (request.bareEnvironment || values.length === 1
      || values.slice(1).every(v => v.startsWith("-"))))
    || (base === "jq" && values.slice(1).some(v => /(^|[^\w])env([^\w]|$)|\$ENV\b/.test(v)))
    || (base === "ps" && values.slice(1).some(v => /^[A-Za-z]*e[A-Za-z]*$/.test(v) || v === "--environment" || v === "-E"))
    || (base === "gh" && values.includes("auth") && (values.includes("token") || values.some(v => v.startsWith("--show-token"))));
  if (envPrinter || outputExpansion) add("read", { environmentDisclosure: true });
  if (["source", "."].includes(base)) {
    operands.push(...words.slice(1).map(w => word(w)));
    add("load", { dynamicSelection: request.dynamicSelection || words.length !== 2 });
  } else if (["ls", "stat", "file", "du", "df", "find", "tree", "readlink", "realpath", "test", "[", "cd", "pushd", "rm", "mv", "shred", "mkdir", "touch", "chmod"].includes(base)) {
    operands.push(...words.slice(1).filter(w => !w.value.startsWith("-")).map(w => word(w)));
    add("metadata");
  } else if (["echo", "printf", "pwd", "which", "type", "date", "true", "false", "sleep", "seq", "set", "env", "ps"].includes(base)) {
    // These arguments are data, unless an explicit output form above applies.
  } else {
    const search = ["grep", "egrep", "fgrep", "rg"].includes(base);
    const readers = ["cat", "head", "tail", "wc", "nl", "od", "hexdump", "strings", "shasum", "sha1sum", "sha256sum", "md5", "md5sum", "cut", "sort", "uniq", "comm", "paste", "fold", "rev", "column", "diff", "cmp"];
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
          if (["-f", "--file", "--file-list"].includes(name) && (search || ["sed", "gsed", "jq"].includes(base))) {
            const value = v.includes("=") ? word(v.slice(v.indexOf("=") + 1), "option-file") : word(words[++i] || "", "option-file");
            operands.push(value); pattern = true; continue;
          }
          if (base === "jq" && ["--rawfile", "--slurpfile"].includes(name)) {
            i++; operands.push(word(words[++i] || "", "option-file")); continue;
          }
          if (["-e", "--regexp", "--expression"].includes(name) && (search || ["sed", "gsed"].includes(base))) {
            if (!v.includes("=")) i++; pattern = true; continue;
          }
          const takesValue = search ? ["-g", "--glob", "--iglob", "-t", "-T", "--type", "--type-not", "-m", "--max-count", "-A", "-B", "-C", "--context", "--encoding"]
            : base === "jq" ? ["--arg", "--argjson"]
              : ["-n", "-c", "-b", "-d", "-s", "-w", "-t", "-k", "-o", "--output", "--lines", "--bytes", "--delimiter", "--fields", "--key"];
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
      for (let i = 0; i < words.length; i++) {
        const v = values[i];
        if (["bash", "sh", "zsh", "ksh", "dash"].includes(base) && i > 0 && /^-[^-]*c/.test(values[i - 1])) continue;
        if (v.startsWith("-")) {
          if (v.includes("=")) operands.push(word(v.slice(v.indexOf("=") + 1).replace(/^@/, ""), "option-file"));
          continue;
        }
        operands.push(word({ ...words[i], value: v.replace(/^@/, "") }));
      }
      if (operands.length) add("execute");
    }
  }
  if (request.dynamicSelection && !calls.length) add("read", { dynamicSelection: true });
  const state = registry(request);
  return ranked(calls.map(c => classify_credential_access(c, state)));
}

function native(request) {
  const a = request.fields || {}, tool = request.tool;
  const metadata = ["glob", "list_dir"].includes(tool);
  const search = ["grep", "grep_search"].includes(tool);
  const operands = [];
  for (const name of ["file_path", "path", "notebook_path", "TargetFile", "AbsolutePath", "FilePath", "File", "SearchPath", "DirectoryPath", "RootDirectory", ...(metadata ? ["Input"] : [])]) {
    if (typeof a[name] === "string" && a[name]) operands.push(word(a[name], `native:${name}`));
  }
  if (metadata) return classify_credential_access({ ...request, operation: "metadata", operands });
  if (search && !operands.length) operands.push(word(request.cwd, "search-root"));
  const recursive = search && (a.recursive !== false && a.Recursive !== false);
  return classify_credential_access({ ...request, operation: "read", operands, recursive,
    dynamicSelection: !operands.length || operands.some(o => /[$*?\[\]]/.test(o.path)) });
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  try {
    const request = JSON.parse(fs.readFileSync(0, "utf8"));
    const verdict = request.operation === "exec-segment" ? segment(request)
      : request.operation === "native" ? native(request) : classify_credential_access(request);
    process.stdout.write(JSON.stringify(verdict) + "\n");
  } catch {
    process.stdout.write(JSON.stringify(result("unresolved", "invalid-classifier-metadata")) + "\n");
  }
}
