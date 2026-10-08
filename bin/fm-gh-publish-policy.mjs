#!/usr/bin/env node
// Publish policy for agent shell commands: the gh publish guard and the git
// identity and hook-bypass refusals.
//
// gh: a command that publishes text, uploads a file, or creates a destination
// on GitHub (the commands in SPECS below: pr create|edit|comment|review, pr
// merge|close|reopen when they carry text, issue create|edit|comment, issue
// close|reopen when they carry text, release create|edit|upload|delete|
// delete-asset, gist create|edit|rename, repo create|edit, and every gh api
// write) must name its destination explicitly (--repo, a full GitHub URL
// argument, the repo argument, or the API path), and its text must pass
// `bin/fm-publish-gate.sh check-text`, which owns the destination allowlist,
// the private denylist, and the public-text policy. The guard refuses what it
// cannot vouch for:
//   - text it cannot read: a shell expansion, a body piped from another
//     command, a missing file;
//   - text gh would generate or ask for after this check (--fill, --editor,
//     --web, --template, --recover, --generate-notes, --notes-from-tag, a gist
//     edit that opens an editor), and a PR or issue created without an
//     explicit title and body (an explicit empty body is fine);
//   - an option spelling it does not know for that command, a combined short
//     option (-db), or any option before the command group other than
//     --repo/-R, so no unrecognized spelling can carry text past it;
//   - a text file read by a command that is not run on its own: in a compound
//     command, a pipeline, or next to a substitution another command could
//     rewrite the file or change the directory before gh reads it, and a
//     relative path is refused when a wrapper changes the directory;
//   - a file the gate cannot scan (a release asset, an --attach file, a repo
//     template copy, an API content or ref write) for a public destination;
//   - a gh api write it cannot place: anything but repos/<owner>/<repo>/... or
//     gists, on a host other than github.com, a write whose URL carries a query
//     string, and every GraphQL mutation except the text-free review-thread
//     (un)resolve;
//   - a PR or issue named by a URL that disagrees with --repo, is on another
//     host, or cannot be read: gh looks a URL selector up in the URL's own
//     repository whatever --repo says;
//   - a repository visibility change (gh repo edit --visibility, an API write
//     of private or visibility, a template generate, a Pages write), whatever
//     the destination's class: it publishes the whole repository, which no
//     text check covers, so it is left to a reviewed manual change.
// Boolean options are read the way gh reads them (--help=false is false, and
// the last spelling wins), so only a real --help skips the checks.
// A proven read (a gh api GET, a GraphQL document with only queries) passes.
//
// judge override: the publish judge's override (bin/fm-publish-judge.sh
// override) is the captain's alone, typed at their own terminal. A command
// that names the judge followed by its override verb on one line is refused
// however it would run it: directly, through a pseudo-terminal wrapper
// (script, unbuffer, expect, a python pty), sent to another terminal, or fed
// to an interpreter as a heredoc. So is a command that writes the
// judge-overrides file itself.
//
// git: fleet git commands must not choose their own identity or skip hooks:
// --no-verify (and git commit -n), -c core.hooksPath, -c user.*/author.*/
// committer.*, git commit --author, git config writes of those keys, and GIT_AUTHOR_* or
// GIT_COMMITTER_* prefix assignments are refused. The identity comes from the
// launch pin (bin/fm-spawn.sh) or git config only.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell
// classification. This policy never evaluates, expands, sources, or runs any
// byte of the submitted command; the only process it starts is the gate
// scanner, with the extracted text passed as files.
//
// Usage: node bin/fm-gh-publish-policy.mjs --command <cmd> [--cwd <dir>]
// Prints "allow", or "deny<TAB><code><TAB><reason>".

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, readFileSync, rmSync, existsSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const SELF_DIR = path.dirname(fileURLToPath(import.meta.url));
const GATE = path.join(SELF_DIR, "fm-publish-gate.sh");

const REASONS = {
  "gh-no-repo":
    "a gh publish command must name its destination explicitly with --repo <owner>/<repo> (or a full GitHub URL argument), so it can be checked against the publish allowlist.",
  "gh-unreadable-text":
    "the publish guard cannot read this command's title or body (a shell expansion, a piped body, or a missing file). Write the text to a file and pass it with --body-file/--notes-file, or use a literal quoted string.",
  "gh-implicit-text":
    "the publish guard cannot see text gh would generate or ask for after this check (--fill, --editor, --web, --template, --recover, generated release notes, or a missing title or body). Pass the exact title and body with --title and --body or --body-file.",
  "gh-file-compound":
    "a gh publish command that reads a text file must run on its own with a stable path: in a compound command another command could rewrite the file or change the directory before gh reads it. Write the file in one step, then run the plain gh command.",
  "gh-other-host":
    "a gh publish command aimed at a host other than github.com is refused: only exact github.com owner/repo destinations can be allowlisted.",
  "gh-unsupported-write":
    "the publish guard cannot place or scan this gh api write (only repos/<owner>/<repo>/... and gists writes, and the text-free GraphQL review-thread resolve, are supported). Use a gh command the guard checks, such as gh pr comment.",
  "gh-unparsed":
    "the publish guard could not parse this gh command; write the text to a file and run a plain gh command with --repo and --body-file.",
  "gh-target-conflict":
    "gh looks up a PR or issue named by a URL in the URL's own repository, whatever --repo says, so the URL must be a readable github.com link that agrees with --repo.",
  "gh-visibility":
    "changing a repository's visibility publishes everything it holds, which no text check covers, so no agent command may change it.",
  "gh-api-query":
    "a gh api write carrying a query string sends values the publish guard does not scan.",
  "gh-refused": "the publish gate refused this text or destination",
  "judge-override":
    "the publish judge's override is the captain's alone: an agent never runs it, wraps it in a pseudo-terminal, scripts it, or writes its judge-overrides file.",
  "git-no-verify": "skipping git hooks (--no-verify, or git commit -n) is refused: the hooks carry the publish gate.",
  "git-hooks-path": "overriding core.hooksPath is refused: the fleet hooks path carries the publish gate.",
  "git-identity":
    "choosing a commit identity (-c user.*/author.*/committer.*, --author, git config of those keys, or GIT_AUTHOR_*/GIT_COMMITTER_* assignments) is refused: the identity comes from the launch pin or git config only.",
};

const REPO_FLAGS = ["-R", "--repo"];
const PUBLISH_GROUPS = new Set(["pr", "issue", "release", "gist", "repo", "api"]);
const RELEASE_READ_VERBS = new Set(["view", "list", "download", "verify", "verify-asset"]);

// The argument grammar of each publishing gh command, from gh 2.101.0's own
// help. text: flags whose value is published, with the kind the gate's shape
// limits apply to (title, body, reply, or other). file: flags naming a file
// whose text is published. asset: flags uploading a file the gate cannot scan.
// generated: flags that make gh produce text itself or ask an editor or a
// browser for it (listed in values too when they take one). values: other
// flags taking a value. bools: other flags taking none.
// needs: the flag groups that must each appear, given the flags present.
// onlyWithText: the command publishes only when it carries text.
// positional: how the non-option words are read. repoFlags: whether the
// inherited --repo/-R applies. visibility: flags that change the repository's
// visibility, refused outright.
const COMMENT_SPEC = {
  repoFlags: true,
  text: { "-b": "reply", "--body": "reply" },
  file: { "-F": "reply", "--body-file": "reply" },
  asset: ["--attach"],
  generated: ["-e", "--editor", "-w", "--web"],
  bools: ["--create-if-none", "--delete-last", "--edit-last", "--yes"],
  needs: (has) => (has("--delete-last") ? [] : [["-b", "--body", "-F", "--body-file"]]),
  positional: "target",
};

const SPECS = {
  "pr create": {
    repoFlags: true,
    text: { "-t": "title", "--title": "title", "-b": "body", "--body": "body" },
    file: { "-F": "body", "--body-file": "body" },
    asset: ["--attach"],
    generated: ["-f", "--fill", "--fill-first", "--fill-verbose", "-e", "--editor", "-w", "--web", "-T", "--template", "--recover"],
    values: ["-a", "--assignee", "-B", "--base", "-H", "--head", "-l", "--label", "-m", "--milestone", "-p", "--project", "-r", "--reviewer", "-T", "--template", "--recover"],
    bools: ["-d", "--draft", "--dry-run", "--no-maintainer-edit"],
    needs: () => [["-t", "--title"], ["-b", "--body", "-F", "--body-file"]],
    positional: "target",
  },
  "pr edit": {
    repoFlags: true,
    text: { "-t": "title", "--title": "title", "-b": "body", "--body": "body" },
    file: { "-F": "body", "--body-file": "body" },
    asset: ["--attach"],
    values: ["--add-assignee", "--add-label", "--add-project", "--add-reviewer", "-B", "--base", "-m", "--milestone", "--remove-assignee", "--remove-label", "--remove-project", "--remove-reviewer"],
    bools: ["--remove-milestone"],
    positional: "target",
  },
  "pr comment": COMMENT_SPEC,
  "pr review": {
    repoFlags: true,
    text: { "-b": "reply", "--body": "reply" },
    file: { "-F": "reply", "--body-file": "reply" },
    bools: ["-a", "--approve", "-c", "--comment", "-r", "--request-changes"],
    needs: (has) => (has("-c", "--comment", "-r", "--request-changes") ? [["-b", "--body", "-F", "--body-file"]] : []),
    positional: "target",
  },
  "pr merge": {
    repoFlags: true,
    onlyWithText: true,
    text: { "-t": "other", "--subject": "other", "-b": "other", "--body": "other", "-A": "other", "--author-email": "other" },
    file: { "-F": "other", "--body-file": "other" },
    values: ["--match-head-commit"],
    bools: ["--admin", "--auto", "-d", "--delete-branch", "--disable-auto", "-m", "--merge", "-r", "--rebase", "-s", "--squash"],
    positional: "target",
  },
  "pr close": {
    repoFlags: true,
    onlyWithText: true,
    text: { "-c": "reply", "--comment": "reply" },
    bools: ["-d", "--delete-branch"],
    positional: "target",
  },
  "pr reopen": { repoFlags: true, onlyWithText: true, text: { "-c": "reply", "--comment": "reply" }, positional: "target" },
  "issue create": {
    repoFlags: true,
    text: { "-t": "title", "--title": "title", "-b": "issue-body", "--body": "issue-body" },
    file: { "-F": "issue-body", "--body-file": "issue-body" },
    asset: ["--attach"],
    generated: ["-e", "--editor", "-w", "--web", "-T", "--template", "--recover"],
    values: ["-a", "--assignee", "--blocked-by", "--blocking", "-l", "--label", "-m", "--milestone", "--parent", "-p", "--project", "--type", "-T", "--template", "--recover"],
    needs: () => [["-t", "--title"], ["-b", "--body", "-F", "--body-file"]],
    positional: "target",
  },
  "issue edit": {
    repoFlags: true,
    text: { "-t": "title", "--title": "title", "-b": "issue-body", "--body": "issue-body" },
    file: { "-F": "issue-body", "--body-file": "issue-body" },
    asset: ["--attach"],
    values: [
      "--add-assignee", "--add-blocked-by", "--add-blocking", "--add-label", "--add-project", "--add-sub-issue", "-m", "--milestone",
      "--parent", "--remove-assignee", "--remove-blocked-by", "--remove-blocking", "--remove-label", "--remove-project", "--remove-sub-issue", "--type",
    ],
    bools: ["--remove-milestone", "--remove-parent", "--remove-type"],
    positional: "target",
  },
  "issue comment": COMMENT_SPEC,
  "issue close": {
    repoFlags: true,
    onlyWithText: true,
    text: { "-c": "reply", "--comment": "reply" },
    values: ["--duplicate-of", "-r", "--reason"],
    positional: "target",
  },
  "issue reopen": { repoFlags: true, onlyWithText: true, text: { "-c": "reply", "--comment": "reply" }, positional: "target" },
  "release create": {
    repoFlags: true,
    text: { "-t": "other", "--title": "other", "-n": "other", "--notes": "other" },
    file: { "-F": "other", "--notes-file": "other" },
    generated: ["--generate-notes", "--notes-from-tag"],
    values: ["--discussion-category", "--notes-start-tag", "--target"],
    bools: ["-d", "--draft", "--fail-on-no-commits", "--latest", "-p", "--prerelease", "--verify-tag"],
    positional: "release-assets",
  },
  "release edit": {
    repoFlags: true,
    text: { "-t": "other", "--title": "other", "-n": "other", "--notes": "other", "--tag": "other" },
    file: { "-F": "other", "--notes-file": "other" },
    values: ["--discussion-category", "--target"],
    bools: ["--draft", "--latest", "--prerelease", "--verify-tag"],
    positional: "tag",
  },
  "release upload": { repoFlags: true, bools: ["--clobber"], positional: "release-upload" },
  "release delete": { repoFlags: true, bools: ["-y", "--yes", "--cleanup-tag"], positional: "tag" },
  "release delete-asset": { repoFlags: true, bools: ["-y", "--yes"], positional: "tag" },
  "gist create": {
    text: { "-d": "other", "--desc": "other", "-f": "other", "--filename": "other" },
    bools: ["-p", "--public", "-w", "--web"],
    positional: "gist-files",
  },
  "gist edit": {
    text: { "-d": "other", "--desc": "other" },
    file: { "-a": "other", "--add": "other" },
    values: ["-f", "--filename", "-r", "--remove"],
    positional: "gist-edit",
  },
  "gist rename": { positional: "gist-rename" },
  "repo create": {
    text: { "-d": "other", "--description": "other", "-h": "other", "--homepage": "other" },
    asset: ["-p", "--template"],
    values: ["-g", "--gitignore", "-l", "--license", "-r", "--remote", "-s", "--source", "-t", "--team"],
    bools: ["--add-readme", "-c", "--clone", "--disable-issues", "--disable-wiki", "--include-all-branches", "--internal", "--private", "--public", "--push"],
    positional: "repo",
  },
  "repo edit": {
    text: { "-d": "other", "--description": "other", "-h": "other", "--homepage": "other", "--add-topic": "other" },
    values: ["--default-branch", "--remove-topic", "--squash-merge-commit-message", "--visibility"],
    bools: ["--accept-visibility-change-consequences", "--allow-forking", "--allow-update-branch", "--delete-branch-on-merge", "--template"],
    boolPattern: /^--enable-[a-z-]+$/,
    visibility: ["--visibility"],
    positional: "repo",
  },
};
SPECS["gist new"] = SPECS["gist create"];

function basename(value) {
  return value.split("/").at(-1);
}

// The one command or edit that fixes each refusal; gh-refused carries the
// gate's own fix line in its detail.
const FIXES = {
  "gh-no-repo": "add --repo <owner>/<repo> to the gh command.",
  "gh-unreadable-text": "write the text to a file, then pass --body-file <absolute path> (--notes-file for a release).",
  "gh-implicit-text": "pass the exact text: --title '<title>' --body-file <absolute path>.",
  "gh-file-compound": "run the gh command on its own, with the file named by its absolute path.",
  "gh-other-host": "aim the command at github.com: drop --hostname and unset GH_HOST.",
  "gh-unsupported-write": "use the checked gh command instead, for example gh pr comment <number> --repo <owner>/<repo> --body-file <file>.",
  "gh-unparsed": "give each option separately with its value (no combined short options), for example gh pr create --repo <owner>/<repo> --title '<title>' --body-file <file>.",
  "gh-target-conflict": "name the PR or issue by its literal number with --repo <owner>/<repo>, or by its https://github.com/<owner>/<repo>/... URL alone.",
  "gh-visibility": "leave the visibility change to the captain's reviewed manual procedure (docs/configuration.md \"Publish guard\").",
  "gh-api-query": "pass each value as a field instead: gh api -X <method> <path> -f <name>=<value>.",
  "gh-refused": "follow the fix line in the gate's refusal above.",
  "judge-override": "report the refused content hash to firstmate; only the captain runs bin/fm-publish-judge.sh override <hash>, in their own terminal.",
  "git-no-verify": "drop --no-verify (or -n) and fix what the hook reports.",
  "git-hooks-path": "drop the core.hooksPath override.",
  "git-identity": "drop the identity option; the launch pin or git config supplies it.",
};

function deny(code, detail = "") {
  return { decision: "deny", code, reason: `${REASONS[code]}${detail ? ` ${detail}` : ""} Fix: ${FIXES[code]}` };
}

const ALLOW = { decision: "allow" };

function literalValue(word) {
  if (!word || !word.literal || (word.subs && word.subs.length > 0)) return null;
  return word.value;
}

function repoFromUrl(value) {
  const match = /^https?:\/\/(?:www\.)?github\.com\/([^/\s]+)\/([^/\s#?]+)/i.exec(value || "");
  if (!match) return "";
  return `${match[1]}/${match[2].replace(/\.git$/, "")}`;
}

function normalizeRepo(value) {
  if (!value) return "";
  const fromUrl = repoFromUrl(value);
  if (fromUrl) return fromUrl.toLowerCase();
  const stripped = value.replace(/^github\.com\//i, "");
  return /^[A-Za-z0-9._-]+\/[A-Za-z0-9._-]+$/.test(stripped) ? stripped.toLowerCase() : "";
}

function stdinPayload(tokens) {
  for (let i = tokens.length - 1; i >= 0; i -= 1) {
    const token = tokens[i];
    if (token.type === "redir" && token.fd === 0 && typeof token.heredoc === "string") return token.heredoc;
    if (token.type === "redir" && token.value === "<<<" && token.fd === 0) {
      const next = tokens[i + 1];
      return literalValue(next);
    }
  }
  return null;
}

// Split option words from positional words the way gh's flag parser does:
// --name=value, -x value, -xvalue and -x=value for a short flag taking a
// value, and -- ending the options. `valued` and `known` say which names take
// a value and which exist at all; the first unknown option, or a combined
// short option such as -db, is returned in `unknown`. Each flag records
// whether it is boolean and whether its value was attached (--name=value).
function parseOptions(words, valued, known) {
  const flags = [];
  const positional = [];
  let unknown = "";
  let ended = false;
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i];
    const value = word.value;
    if (ended || !value.startsWith("-") || value === "-") {
      positional.push(word);
      continue;
    }
    if (value === "--") {
      ended = true;
      continue;
    }
    let name = value;
    let attached = null;
    if (value.startsWith("--")) {
      const equals = value.indexOf("=");
      if (equals !== -1) {
        name = value.slice(0, equals);
        attached = value.slice(equals + 1);
      }
    } else if (value.length > 2) {
      name = value.slice(0, 2);
      if (!valued.has(name)) {
        unknown ||= value;
        continue;
      }
      attached = value.slice(2).replace(/^=/, "");
    }
    if (!known(name)) {
      unknown ||= name;
      continue;
    }
    if (attached !== null) {
      flags.push({ name, value: literalValue(word) === null ? null : attached, attached: true, bool: !valued.has(name) });
      continue;
    }
    if (valued.has(name)) {
      flags.push({ name, value: literalValue(words[i + 1]), missing: !words[i + 1] });
      i += 1;
    } else {
      flags.push({ name, value: "", bool: true });
    }
  }
  return { flags, positional, unknown };
}

function parseGhArgs(words, spec) {
  const valued = new Set([
    ...(spec.repoFlags ? REPO_FLAGS : []),
    ...Object.keys(spec.text || {}),
    ...Object.keys(spec.file || {}),
    ...(spec.asset || []),
    ...(spec.values || []),
  ]);
  const generatedBools = (spec.generated || []).filter((name) => !valued.has(name));
  const bools = new Set([...(spec.bools || []), ...generatedBools, "--help"]);
  const known = (name) => valued.has(name) || bools.has(name) || Boolean(spec.boolPattern && spec.boolPattern.test(name));
  return parseOptions(words, valued, known);
}

// The spellings gh's flag parser accepts for a boolean option's attached value
// (Go's strconv.ParseBool); anything else is an error that stops gh.
const TRUE_WORDS = new Set(["1", "t", "T", "TRUE", "true", "True"]);
const FALSE_WORDS = new Set(["0", "f", "F", "FALSE", "false", "False"]);

// presentFlags <flags>: the options in effect, read the way gh reads them: a
// value option is in effect once given; a boolean one is in effect while its
// last spelling is true (the bare flag, or --name=<true word>), so
// --help --help=false is not help. Returns { present } or a denial for a
// boolean value gh would reject or the guard cannot read.
function presentFlags(flags) {
  const present = new Set();
  for (const flag of flags) {
    if (!flag.bool) {
      present.add(flag.name);
      continue;
    }
    let on = true;
    if (flag.attached) {
      if (TRUE_WORDS.has(flag.value)) on = true;
      else if (FALSE_WORDS.has(flag.value)) on = false;
      else return { denied: deny("gh-unparsed", `(${flag.name} takes true or false)`) };
    }
    if (on) present.add(flag.name);
    else present.delete(flag.name);
  }
  return { present };
}

// PR and issue URLs as gh reads a selector (gh 2.101.0 pkg/cmd/pr/shared and
// pkg/cmd/issue/shared, through Go's url.Parse): an http or https URL on any
// host whose unescaped path is /<owner>/<repo>/pull/<n>, or for an issue
// command also /<owner>/<repo>/issues/<n>. Go never folds . or .. segments.
const PR_URL_PATH = /^\/([^/]+)\/([^/]+)\/pull\/(\d+)/;
const ISSUE_URL_PATH = /^\/([^/]+)\/([^/]+)\/(?:issues|pull)\/(\d+)/;
const REPO_PART = /^(?!\.\.?$)[A-Za-z0-9._-]+$/;

// selectorRepo <command> <words>: the repository gh will look the PR or issue
// up in when a selector is a URL, lowercased, or "" when no selector is one
// (a number, #number, or branch leaves it to --repo). A selector the guard
// cannot read could be a URL, so it is refused; so is a URL on another host,
// a link gh cannot resolve, and URLs naming different repositories.
function selectorRepo(command, words) {
  const unreadable = deny("gh-target-conflict", "(a PR or issue URL that cannot be read)");
  let repo = "";
  for (const word of words) {
    const value = literalValue(word);
    if (value === null) return deny("gh-target-conflict", "(the PR or issue selector is not a literal)");
    if (!/^https?:/i.test(value)) continue;
    const url = /^https?:\/\/([^/?#]*)([^?#]*)/i.exec(value);
    if (!url) return unreadable;
    const host = url[1]
      .replace(/^.*@/, "")
      .replace(/:[0-9]*$/, "")
      .toLowerCase()
      .replace(/^www\./, "");
    if (!/^[a-z0-9.-]+$/.test(host)) return unreadable;
    if (host !== "github.com") return deny("gh-other-host", `(${host})`);
    let pathname;
    try {
      pathname = decodeURIComponent(url[2]);
    } catch {
      return unreadable;
    }
    const match = (command.startsWith("issue ") ? ISSUE_URL_PATH : PR_URL_PATH).exec(pathname);
    if (!match) return deny("gh-target-conflict", `(a URL that is not a link gh ${command} resolves)`);
    if (!REPO_PART.test(match[1]) || !REPO_PART.test(match[2])) return unreadable;
    const named = `${match[1]}/${match[2]}`.toLowerCase();
    if (repo && repo !== named) return deny("gh-target-conflict", `(URLs naming ${repo} and ${named})`);
    repo = named;
  }
  return { repo };
}

// A text file gh will read. Resolved against the command's working directory,
// which is known only while no wrapper changes it.
function readFile(value, kind, tokens, cwd, context, target) {
  if (value === null) return deny("gh-unreadable-text");
  if (value === "-") {
    const payload = stdinPayload(tokens);
    if (payload === null) return deny("gh-unreadable-text");
    target.texts.push({ kind, text: payload });
    return null;
  }
  if (!path.isAbsolute(value) && !context.cwdKnown) {
    return deny("gh-file-compound", `(a wrapper changes the directory before gh reads ${value})`);
  }
  const resolved = path.resolve(cwd, value);
  if (!existsSync(resolved)) return deny("gh-unreadable-text", `(missing file: ${value})`);
  target.files.push({ kind, path: resolved });
  return null;
}

function ghTarget(command, spec, parsed, tokens, cwd, context) {
  if (parsed.unknown) return deny("gh-unparsed", `(unrecognized option ${parsed.unknown} for gh ${command})`);
  const effective = presentFlags(parsed.flags);
  if (effective.denied) return effective.denied;
  const { present } = effective;
  const has = (...names) => names.some((name) => present.has(name));
  // --help in effect prints help and publishes nothing.
  if (has("--help")) return null;
  const visibility = (spec.visibility || []).find((name) => present.has(name));
  if (visibility) return deny("gh-visibility", `(gh ${command} ${visibility})`);
  const generated = (spec.generated || []).find((name) => present.has(name));
  if (generated) return deny("gh-implicit-text", `(${generated})`);
  for (const group of spec.needs ? spec.needs(has) : []) {
    if (!has(...group)) return deny("gh-implicit-text", `(gh ${command} needs ${group.filter((name) => name.startsWith("--")).join(" or ")})`);
  }
  const target = { repo: "", texts: [], files: [], unscannable: [] };
  for (const flag of parsed.flags) {
    const textKind = spec.text?.[flag.name];
    const fileKind = spec.file?.[flag.name];
    if (textKind) {
      if (flag.value === null || flag.missing) return deny("gh-unreadable-text");
      target.texts.push({ kind: textKind, text: flag.value });
    } else if (fileKind) {
      if (flag.missing) return deny("gh-unreadable-text");
      const refused = readFile(flag.value, fileKind, tokens, cwd, context, target);
      if (refused) return refused;
      // A file added to a gist is published under its own name.
      if (command === "gist edit") target.texts.push({ kind: "other", text: basename(flag.value) });
    } else if ((spec.asset || []).includes(flag.name)) {
      if (flag.value === null || flag.missing) return deny("gh-unreadable-text");
      target.unscannable.push(`gh ${command} ${flag.name}`);
    }
  }

  const positional = parsed.positional;
  if (spec.positional === "release-assets" || spec.positional === "release-upload") {
    const tag = literalValue(positional[0]);
    if (positional[0] && tag === null) return deny("gh-unreadable-text");
    if (spec.positional === "release-assets" && tag !== null) target.texts.push({ kind: "other", text: tag });
    if (positional.length > 1) target.unscannable.push(`gh ${command} asset files`);
  } else if (spec.positional === "gist-files") {
    if (positional.length === 0) {
      const refused = readFile("-", "other", tokens, cwd, context, target);
      if (refused) return refused;
    }
    for (const word of positional) {
      const value = literalValue(word);
      const refused = readFile(value, "other", tokens, cwd, context, target);
      if (refused) return refused;
      if (value !== "-") target.texts.push({ kind: "other", text: basename(value) });
    }
  } else if (spec.positional === "gist-edit") {
    if (positional.length > 2) return deny("gh-unparsed");
    if (positional[1]) {
      const refused = readFile(literalValue(positional[1]), "other", tokens, cwd, context, target);
      if (refused) return refused;
    } else if (has("-f", "--filename") || !has("-a", "--add", "-d", "--desc", "-r", "--remove")) {
      return deny("gh-implicit-text", "(gh gist edit opens an editor)");
    }
  } else if (spec.positional === "gist-rename") {
    const renamed = literalValue(positional[2]);
    if (renamed === null || positional.length !== 3) return deny("gh-unreadable-text");
    target.texts.push({ kind: "other", text: renamed });
  }
  if (spec.onlyWithText && target.texts.length === 0 && target.files.length === 0) return null;
  if (target.files.length > 0 && context.compound) return deny("gh-file-compound");

  if (command.startsWith("gist ")) {
    target.repo = "gist";
  } else if (spec.positional === "repo") {
    target.repo = normalizeRepo(literalValue(positional[0]) || "");
    if (!target.repo) return deny("gh-no-repo", `(gh ${command} needs <owner>/<repo>)`);
  } else {
    for (const flag of parsed.flags.filter((entry) => REPO_FLAGS.includes(entry.name))) {
      if (flag.value === null || flag.missing) return deny("gh-no-repo");
      target.repo = normalizeRepo(flag.value);
      if (!target.repo) return deny("gh-no-repo");
    }
    // A URL selector wins over --repo in gh, so the two must agree.
    if (spec.positional === "target") {
      const selected = selectorRepo(command, positional);
      if (selected.decision) return selected;
      if (selected.repo && target.repo && selected.repo !== target.repo) {
        return deny("gh-target-conflict", `(the URL names ${selected.repo}, --repo names ${target.repo})`);
      }
      target.repo ||= selected.repo;
    }
    if (!target.repo) return deny("gh-no-repo");
  }
  if (["pr create", "pr edit"].includes(command) && context.cwdKnown && !context.compound
    && parsed.flags.filter((flag) => ["-B", "--base", "-H", "--head"].includes(flag.name)).every((flag) => flag.value !== null && !flag.missing)) {
    const lastValue = (...names) => parsed.flags.filter((flag) => names.includes(flag.name)).at(-1)?.value || "";
    const currentBranch = () => {
      const branch = spawnSync("git", ["branch", "--show-current"], { cwd, encoding: "utf8" });
      return branch.status === 0 ? branch.stdout.trim() : "";
    };
    target.prBase = lastValue("-B", "--base");
    if (command === "pr create") {
      target.prHead = lastValue("-H", "--head") || currentBranch();
    } else {
      const selector = literalValue(positional[0]);
      target.prNumber = selector?.match(/^(?:#)?(\d+)$/)?.[1] || selector?.match(/\/pull\/(\d+)(?:[/?#]|$)/)?.[1] || "";
      if (!target.prNumber) target.prBranch = selector || currentBranch();
    }
    target.cwd = cwd;
  }
  if (command === "issue edit") {
    // The shared body applies to every selector. Only a single verified
    // issue may qualify for the extended cap; multi-target edits retain the
    // ordinary cap rather than borrowing the first target's issue type.
    const selector = positional.length === 1 ? literalValue(positional[0]) : null;
    target.issueNumber = selector?.match(/^(?:#)?(\d+)$/)?.[1]
      || selector?.match(/\/(?:issues|pull)\/(\d+)(?:[/?#]|$)/)?.[1] || "unknown";
  }
  return target;
}

// The top-level fields of each operation in a GraphQL document, or null when
// it cannot be read that far. Comments and string literals are dropped first,
// so words inside them never count; a fragment spread counts as field "...".
function graphqlOperations(document) {
  const source = document
    .replace(/"""[\s\S]*?"""/g, '""')
    .replace(/"(?:[^"\\\n]|\\.)*"/g, '""')
    .replace(/#[^\n]*/g, "");
  let i = 0;
  const skipSpace = () => {
    while (i < source.length && /[\s,]/.test(source[i])) i += 1;
  };
  const readName = () => {
    const match = /^[_A-Za-z][_0-9A-Za-z]*/.exec(source.slice(i));
    if (!match) return "";
    i += match[0].length;
    return match[0];
  };
  const skipBalanced = (open, close) => {
    let depth = 0;
    for (; i < source.length; i += 1) {
      if (source[i] === open) depth += 1;
      else if (source[i] === close) {
        depth -= 1;
        if (depth === 0) {
          i += 1;
          return true;
        }
      }
    }
    return false;
  };
  const skipArgumentsAndDirectives = () => {
    skipSpace();
    if (source[i] === "(" && !skipBalanced("(", ")")) return false;
    skipSpace();
    while (source[i] === "@") {
      i += 1;
      readName();
      skipSpace();
      if (source[i] === "(" && !skipBalanced("(", ")")) return false;
      skipSpace();
    }
    return true;
  };
  const operations = [];
  for (;;) {
    skipSpace();
    if (i >= source.length) return operations;
    let kind = "query";
    if (source[i] !== "{") {
      kind = readName();
      if (!kind) return null;
      while (i < source.length && source[i] !== "{") {
        if (source[i] === "(") {
          if (!skipBalanced("(", ")")) return null;
        } else {
          i += 1;
        }
      }
      if (i >= source.length) return null;
    }
    i += 1;
    const fields = [];
    for (;;) {
      skipSpace();
      if (i >= source.length) return null;
      if (source[i] === "}") {
        i += 1;
        break;
      }
      if (source.startsWith("...", i)) {
        i += 3;
        skipSpace();
        if (readName() === "on") {
          skipSpace();
          readName();
        }
        fields.push("...");
      } else {
        let field = readName();
        if (!field) return null;
        skipSpace();
        if (source[i] === ":") {
          i += 1;
          skipSpace();
          field = readName();
          if (!field) return null;
        }
        fields.push(field);
      }
      if (!skipArgumentsAndDirectives()) return null;
      if (source[i] === "{" && !skipBalanced("{", "}")) return null;
    }
    operations.push({ kind, fields });
  }
}

// GraphQL mutations that publish no text: resolving a review thread only
// changes its state.
const TEXT_FREE_MUTATIONS = new Set(["resolveReviewThread", "unresolveReviewThread"]);

const API_VALUED = new Set([
  "-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "-q", "--jq", "-t", "--template",
  "-p", "--preview", "--cache", "--hostname", "--input",
]);
const API_BOOLS = new Set(["-i", "--include", "--paginate", "--silent", "--slurp", "--verbose", "--allow-escape-sequences"]);

// Field and body keys that change a repository's visibility.
const VISIBILITY_KEY = /^(private|visibility)$/i;

// visibilityField <fields> <inputs> <tokens> <cwd>: a denial when a repository
// API write sets private or visibility, through a -f/-F field (its name before
// any [ ]) or a top-level key of an --input JSON body; an --input body that is
// not a readable JSON object is refused too, since it could set either.
function visibilityField(fields, inputs, tokens, cwd) {
  for (const field of fields) {
    if (VISIBILITY_KEY.test(field.name.split("[")[0])) return deny("gh-visibility", `(an API write of ${field.name.split("[")[0]})`);
  }
  for (const input of inputs) {
    let body = null;
    if (input === "-") body = stdinPayload(tokens);
    else if (input !== null && existsSync(path.resolve(cwd, input))) {
      try {
        body = readFileSync(path.resolve(cwd, input), "utf8");
      } catch {
        body = null;
      }
    }
    let parsed = null;
    try {
      parsed = body === null ? null : JSON.parse(body);
    } catch {
      parsed = null;
    }
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) {
      return deny("gh-unparsed", "(the --input body of a repository API write is not a readable JSON object)");
    }
    const key = Object.keys(parsed).find((name) => VISIBILITY_KEY.test(name));
    if (key) return deny("gh-visibility", `(an API write of ${key})`);
  }
  return null;
}

function ghApiTarget(words, tokens, cwd, context) {
  const parsed = parseOptions(words, API_VALUED, (name) => API_VALUED.has(name) || API_BOOLS.has(name));
  if (parsed.unknown) return deny("gh-unparsed", `(unrecognized option ${parsed.unknown} for gh api)`);
  let method = "";
  let hostname = "";
  const fields = [];
  const inputs = [];
  for (const flag of parsed.flags) {
    if (flag.name === "-X" || flag.name === "--method") method = flag.value === null || flag.missing ? "?" : flag.value.toUpperCase();
    else if (flag.name === "--hostname") hostname = flag.value === null ? "?" : flag.value.toLowerCase();
    else if (flag.name === "--input") inputs.push(flag.missing ? null : flag.value);
    else if (["-f", "--raw-field", "-F", "--field"].includes(flag.name)) {
      const typed = flag.name === "-F" || flag.name === "--field";
      if (flag.value === null || flag.missing) {
        fields.push({ name: "", value: null, typed });
        continue;
      }
      const equals = flag.value.indexOf("=");
      fields.push({
        name: equals === -1 ? flag.value : flag.value.slice(0, equals),
        value: equals === -1 ? "" : flag.value.slice(equals + 1),
        typed,
      });
    }
  }
  if (parsed.positional.length > 1) return deny("gh-unparsed", "(gh api takes one endpoint)");
  const endpointWord = parsed.positional[0];
  let endpoint = literalValue(endpointWord);
  let host = hostname || "github.com";
  let query = false;
  if (endpoint !== null) {
    const absolute = /^https?:\/\/([^/]+)\/(.*)$/i.exec(endpoint);
    if (absolute) {
      host = absolute[1].toLowerCase() === "api.github.com" ? "github.com" : absolute[1].toLowerCase();
      endpoint = absolute[2];
    }
    // gh sends a URL's query string as it is, so a write's values could ride
    // in it unscanned; the fragment never leaves gh.
    query = /^[^#]*\?/.test(endpoint);
    endpoint = endpoint.replace(/^\/+/, "").replace(/[?#].*$/, "");
  }
  const isWrite = method ? method !== "GET" && method !== "HEAD" : fields.length > 0 || inputs.length > 0;
  if (query && (isWrite || endpoint === "graphql")) return deny("gh-api-query");

  if (endpoint === "graphql") {
    // The document is read from its one query field: literal text, or a file
    // (or heredoc) named with -F query=@..., read the way gh will read it.
    const queries = fields.filter((field) => field.name === "query");
    if (queries.length !== 1 || queries[0].value === null || inputs.length > 0) {
      return deny("gh-unsupported-write", "(the GraphQL document is not one readable query field)");
    }
    let query = queries[0].value;
    if (queries[0].typed && query.startsWith("@")) {
      const source = { texts: [], files: [] };
      const refused = readFile(query.slice(1), "other", tokens, cwd, context, source);
      if (refused) return refused;
      if (source.files.length > 0 && context.compound) return deny("gh-file-compound");
      query = source.texts.length > 0 ? source.texts[0].text : readFileSync(source.files[0].path, "utf8");
    }
    const operations = graphqlOperations(query);
    if (operations === null) return deny("gh-unparsed", "(unreadable GraphQL document)");
    for (const operation of operations) {
      if (operation.kind === "query" || operation.kind === "fragment") continue;
      if (operation.kind !== "mutation" || !operation.fields.every((field) => TEXT_FREE_MUTATIONS.has(field))) {
        return deny("gh-unsupported-write", "(a GraphQL mutation)");
      }
    }
    return null;
  }

  if (!isWrite) return null;
  if (endpoint === null) return deny("gh-unparsed", "(the endpoint of a gh api write is not a literal)");
  if (host !== "github.com") return deny("gh-other-host");
  let repo = "";
  let rest = "";
  const repos = /^repos\/([^/]+)\/([^/]+)(?:\/(.*))?$/.exec(endpoint);
  if (repos) {
    if (repos[1].includes("{") || repos[2].includes("{")) return deny("gh-no-repo");
    repo = `${repos[1]}/${repos[2]}`.toLowerCase();
    rest = repos[3] || "";
  } else if (/^gists(\/|$)/.test(endpoint)) {
    repo = "gist";
  } else {
    return deny("gh-unsupported-write", `(${endpoint.split("/")[0] || "the API root"})`);
  }
  // A comment or review body is a reply; an issue or pull request body is a
  // description; the title field is a title; any other field is plain text.
  const replyEndpoint = /(^|\/)(comments|reviews)(\/|$)/.test(rest);
  const kindOf = (field) => {
    if (field === "title") return "title";
    if (field === "body") return replyEndpoint ? "reply" : /^issues(?:\/\d+)?$/.test(rest) ? "issue-body" : "body";
    return "other";
  };
  // A visibility change, a repository generated from this one as a template
  // (public unless asked otherwise), or a Pages site publishes the repository
  // itself, whatever class the destination has now.
  const publishesRepo = /^(generate|pages)(\/|$)/.exec(rest);
  if (repo !== "gist" && publishesRepo) return deny("gh-visibility", `(a gh api ${publishesRepo[1]} write)`);
  if (repo !== "gist") {
    const changed = visibilityField(fields, inputs, tokens, cwd);
    if (changed) return changed;
  }
  const target = { repo, texts: [], files: [], unscannable: [] };
  if (/^issues\/\d+$/.test(rest)) target.issueNumber = rest.split("/")[1];
  // A contents or git-data write creates commits or refs the pre-push gate
  // never sees, from content the text scan cannot read.
  const writeKind = /^(contents|git)(\/|$)/.exec(rest);
  if (writeKind) target.unscannable.push(`a gh api ${writeKind[1]} write`);
  for (const field of fields) {
    if (field.value === null) return deny("gh-unreadable-text");
    if (field.typed && field.value.startsWith("@")) {
      const refused = readFile(field.value.slice(1), kindOf(field.name), tokens, cwd, context, target);
      if (refused) return refused;
      continue;
    }
    target.texts.push({ kind: kindOf(field.name), text: field.value });
  }
  for (const input of inputs) {
    const refused = readFile(input, "other", tokens, cwd, context, target);
    if (refused) return refused;
  }
  if (target.files.length > 0 && context.compound) return deny("gh-file-compound");
  return target;
}

function runGate(target) {
  const dir = mkdtempSync(path.join(tmpdir(), "fm-gh-publish-"));
  try {
    const withKind = (kind, file) => (kind === "other" ? file : `${kind}:${file}`);
    const args = ["check-text", "--dest", target.repo];
    if (target.issueNumber) args.push("--issue", target.issueNumber);
    if (target.prBase) args.push("--pr-base", target.prBase);
    if (target.prHead) args.push("--pr-head", target.prHead);
    if (target.prNumber) args.push("--pr", target.prNumber);
    if (target.prBranch) args.push("--pr-branch", target.prBranch);
    for (const what of target.unscannable) args.push("--unscannable", what);
    for (const entry of target.files) args.push(withKind(entry.kind, entry.path));
    target.texts.forEach((entry, index) => {
      const file = path.join(dir, `text-${index}.txt`);
      writeFileSync(file, `${entry.text}\n`);
      args.push(withKind(entry.kind, file));
    });
    const result = spawnSync(GATE, args, { cwd: target.cwd, encoding: "utf8" });
    if (result.status === 0) return ALLOW;
    // Keep the gate's closing REFUSED and fix lines even after many findings.
    const lines = (result.stderr || "").trim().split("\n");
    const detail = (lines.length > 12 ? [...lines.slice(0, 9), "...", ...lines.slice(-2)] : lines).join(" | ");
    return deny("gh-refused", detail ? `(${detail})` : "");
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// Shared inherited repository grammar for the shell policy and argv wrapper.
function ghRepoFlagWidth(words, i) {
  const value = words[i]?.value || "";
  if (REPO_FLAGS.includes(value)) return words[i + 1] ? 2 : -1;
  if (value.startsWith("--repo=") || (value.startsWith("-R") && !value.startsWith("--"))) return 1;
  return 0;
}

// Locate group/verb without changing argv; the stdin adapter uses these same
// positions so inherited flags cannot hide a generated PR body from scanning.
function runtimeCommand(argv) {
  const words = argv.map((value) => ({ value }));
  let groupIndex = 0;
  while (argv[groupIndex]?.startsWith("-")) {
    const width = ghRepoFlagWidth(words, groupIndex);
    if (width > 0) { groupIndex += width; continue; }
    if (["--help", "--version"].includes(argv[groupIndex]) && groupIndex === 0) {
      return { group: argv[groupIndex], groupIndex, verbIndex: -1 };
    }
    return null;
  }
  const group = argv[groupIndex];
  if (!group) return null;
  if (group === "api") return groupIndex === 0 ? { group, groupIndex, verbIndex: -1 } : null;
  let verbIndex = groupIndex + 1;
  while (argv[verbIndex]?.startsWith("-")) {
    const width = ghRepoFlagWidth(words, verbIndex);
    if (width > 0) { verbIndex += width; continue; }
    if (argv[verbIndex] === "--help" || argv[verbIndex].startsWith("--help=")) { verbIndex += 1; continue; }
    return null;
  }
  return { group, groupIndex, verb: argv[verbIndex], verbIndex };
}

function checkGh(position, tokens, cwd, context) {
  const all = position.words.slice(position.index + 1);
  // gh also takes the inherited --repo/-R before the command group
  // (gh --repo o/r pr create); lift it onto the command. Its only other
  // options there are --help and --version, so any other option ahead of a
  // publishing group is refused rather than guessed at.
  const lifted = [];
  let start = 0;
  while (start < all.length) {
    const value = all[start].value;
    if (!value.startsWith("-") || value === "-") break;
    const width = ghRepoFlagWidth(all, start);
    if (width > 0) {
      lifted.push(...all.slice(start, start + width));
      start += width;
      continue;
    }
    return all.slice(start + 1).some((word) => PUBLISH_GROUPS.has(word.value))
      ? deny("gh-unparsed", `(option ${value} before the command group)`)
      : ALLOW;
  }
  const group = all[start]?.value;
  if (!group) return ALLOW;
  if (group === "api") {
    if (lifted.length > 0) return deny("gh-unparsed", "(gh api takes no --repo)");
    const target = ghApiTarget(all.slice(start + 1), tokens, cwd, context);
    if (!target) return ALLOW;
    if (target.decision) return target;
    return runGate(target);
  }
  if (!PUBLISH_GROUPS.has(group)) return ALLOW;
  // The verb is the first word after the group that is neither --repo/-R nor
  // its value; --help there is read with the verb's own options, and any other
  // option before the verb is refused rather than guessed at.
  const rest = [...lifted, ...all.slice(start + 1)];
  let verbIndex = -1;
  for (let i = 0; i < rest.length; i += 1) {
    const value = rest[i].value;
    const width = ghRepoFlagWidth(rest, i);
    if (width > 0) { i += width - 1; continue; }
    if (value === "--help" || value.startsWith("--help=")) continue;
    if (value.startsWith("-")) return deny("gh-unparsed", `(option ${value} before the gh ${group} verb)`);
    verbIndex = i;
    break;
  }
  if (verbIndex < 0) return ALLOW;
  const verb = rest[verbIndex].value;
  const command = `${group} ${verb}`;
  const spec = SPECS[command];
  if (!spec) {
    if (group === "release" && !RELEASE_READ_VERBS.has(verb)) return deny("gh-unparsed", `(gh ${command})`);
    return ALLOW;
  }
  const parsed = parseGhArgs(rest.filter((_, index) => index !== verbIndex), spec);
  const target = ghTarget(command, spec, parsed, tokens, cwd, context);
  if (!target) return ALLOW;
  if (target.decision) return target;
  return context.targetOnly ? target : runGate(target);
}

// The judge named and then its override verb, anywhere on one line.
const JUDGE_OVERRIDE = /fm-publish-judge(\.sh)?\b[^\n]*\boverride\b/;
const OVERRIDES_FILE = /judge-overrides/;
const FILE_WRITERS = new Set(["tee", "cp", "mv", "ln", "install", "dd", "rsync", "truncate"]);

// checkJudgeOverride <tokens> <position>: refuse running the captain-only
// judge override - the node's words read as one line, any single word (a
// python -c or expect -c program, a tmux send-keys string), and any heredoc
// body - and refuse writing the overrides file: an output redirection to it,
// a file-writing command naming it, or an in-place sed or perl edit of it.
function checkJudgeOverride(tokens, position) {
  const words = tokens.filter((token) => token.type === "word").map((token) => token.value);
  const heredocs = tokens.filter((token) => token.type === "redir" && typeof token.heredoc === "string").map((token) => token.heredoc);
  if ([words.join(" "), ...words, ...heredocs].some((text) => JUDGE_OVERRIDE.test(text))) return deny("judge-override");
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type === "redir" && /^>/.test(token.value) && !token.inlineTarget && OVERRIDES_FILE.test(tokens[i + 1]?.value || "")) {
      return deny("judge-override");
    }
  }
  if (!position.command) return ALLOW;
  const name = basename(position.command.value);
  const args = position.words.slice(position.index + 1).map((word) => word.value);
  if (!args.some((value) => OVERRIDES_FILE.test(value))) return ALLOW;
  if (FILE_WRITERS.has(name)) return deny("judge-override");
  if ((name === "sed" || name === "perl") && args.some((value) => /^-[A-Za-z]*i/.test(value))) return deny("judge-override");
  return ALLOW;
}

const IDENTITY_KEY = /^(user\.(name|email)|author\.(name|email)|committer\.(name|email))$/i;

function checkGit(position) {
  for (const word of position.words.slice(0, position.prefixAssignments)) {
    if (/^GIT_(AUTHOR|COMMITTER)_(NAME|EMAIL)=/.test(word.value)) return deny("git-identity");
  }
  const args = position.words.slice(position.index + 1);
  let subcommand = "";
  for (let i = 0; i < args.length; i += 1) {
    const value = args[i].value;
    if (!subcommand) {
      if (value === "-c" || value.startsWith("-c")) {
        const setting = value === "-c" ? args[i + 1]?.value || "" : value.slice(2);
        if (value === "-c") i += 1;
        const key = setting.split("=")[0];
        if (/^core\.hookspath$/i.test(key)) return deny("git-hooks-path");
        if (IDENTITY_KEY.test(key)) return deny("git-identity");
        continue;
      }
      if (value.startsWith("--config-env")) {
        const setting = value.includes("=") ? value.slice(value.indexOf("=") + 1) : args[i + 1]?.value || "";
        if (!value.includes("=")) i += 1;
        const key = setting.split("=")[0];
        if (/^core\.hookspath$/i.test(key)) return deny("git-hooks-path");
        if (IDENTITY_KEY.test(key)) return deny("git-identity");
        continue;
      }
      if (["-C", "--git-dir", "--work-tree", "--namespace"].includes(value)) {
        i += 1;
        continue;
      }
      if (value.startsWith("-")) continue;
      subcommand = value;
      continue;
    }
    if (value === "--no-verify") return deny("git-no-verify");
    if (subcommand === "commit" && /^-[A-Za-z]*n[A-Za-z]*$/.test(value) && !value.startsWith("--")) return deny("git-no-verify");
    if (subcommand === "commit" && (value === "--author" || value.startsWith("--author="))) return deny("git-identity");
    if (subcommand === "config") {
      const key = value.replace(/^--(add|replace-all)$/, "");
      if (key && !key.startsWith("-") && (IDENTITY_KEY.test(key) || /^core\.hookspath$/i.test(key))) {
        const rest = args.slice(i + 1).filter((word) => !word.value.startsWith("-"));
        if (rest.length > 0) return IDENTITY_KEY.test(key) ? deny("git-identity") : deny("git-hooks-path");
      }
    }
  }
  return ALLOW;
}

const GH_PUBLISH_HINT = /(^|[^A-Za-z0-9_-])gh\s+(pr|issue|release|gist|repo|api)\b/;

// A wrapper option that changes the directory the command runs in (env -C,
// env --chdir, sudo -D, sudo --chdir), or one the wrapper parser could not
// resolve, leaves the working directory unknown.
function cwdKnown(position) {
  if (position.unresolvedWrapperOption) return false;
  return !position.words
    .slice(0, position.index)
    .some((word) => /^--chdir(=|$)/.test(word.value) || /^-[A-Za-z0-9]*[CD]/.test(word.value));
}

// `enclosing` is true when this program runs next to other commands: any
// other command in an enclosing list, pipeline, or substitution could change
// the directory or rewrite a file before a gh command in it reads the file.
function analyze(command, cwd, depth = 0, enclosing = false) {
  if (depth > 4) return ALLOW;
  const lexed = new Lexer(command).tokenize();
  if (lexed.error) {
    if (JUDGE_OVERRIDE.test(command)) return deny("judge-override");
    return GH_PUBLISH_HINT.test(command) ? deny("gh-unparsed") : ALLOW;
  }
  const { nodes } = splitProgram(lexed.tokens);
  const compound = enclosing || nodes.length > 1;
  for (const tokens of nodes) {
    const substituted = tokens.some((token) => token.type === "group" || (token.type === "word" && token.subs && token.subs.length > 0));
    for (const token of tokens) {
      if (token.type === "group") {
        const inner = analyze(token.content, cwd, depth + 1, compound);
        if (inner.decision === "deny") return inner;
      }
      if (token.type === "word" && token.subs) {
        for (const sub of token.subs) {
          const inner = analyze(sub.content, cwd, depth + 1, true);
          if (inner.decision === "deny") return inner;
        }
      }
    }
    const position = commandPosition(tokens);
    const judged = checkJudgeOverride(tokens, position);
    if (judged.decision === "deny") return judged;
    if (!position.command) continue;
    const name = basename(position.command.value);
    const context = { compound: compound || substituted, cwdKnown: cwdKnown(position) };
    let result = ALLOW;
    if (name === "gh") result = checkGh(position, tokens, cwd, context);
    else if (name === "git") result = checkGit(position);
    else if (["sh", "bash", "zsh"].includes(name)) {
      const words = position.words;
      for (let i = position.index + 1; i < words.length; i += 1) {
        if (/^-[A-Za-z]*c[A-Za-z]*$/.test(words[i].value)) {
          const payload = literalValue(words[i + 1]);
          if (payload) result = analyze(payload, cwd, depth + 1, context.compound);
          break;
        }
      }
    } else if (name === "eval") {
      const payload = position.words.slice(position.index + 1).map(literalValue);
      if (payload.length > 0 && payload.every((value) => value !== null)) result = analyze(payload.join(" "), cwd, depth + 1, context.compound);
    }
    if (result.decision === "deny") return result;
  }
  return ALLOW;
}

function decision(command, cwd = process.cwd()) {
  return analyze(command, cwd);
}

function parseArguments(argv) {
  const result = { command: "", commandSet: false, cwd: process.cwd() };
  for (let i = 0; i < argv.length; i += 1) {
    const name = argv[i];
    if (name === "--command" || name === "--cwd") {
      if (i + 1 >= argv.length) throw new Error(`${name} requires a value`);
      if (name === "--command") {
        result.command = argv[i + 1];
        result.commandSet = true;
      } else {
        result.cwd = argv[i + 1];
      }
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${name}`);
  }
  return result;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  const self = fileURLToPath(import.meta.url);
  try {
    return realpathSync(entry) === realpathSync(self);
  } catch {
    return entry === self;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    const result = args.commandSet && args.command ? decision(args.command, args.cwd) : ALLOW;
    if (result.decision === "allow") process.stdout.write("allow\n");
    else process.stdout.write(`deny\t${result.code}\t${result.reason.replace(/[\t\n]/g, " ")}\n`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}

// A runtime wrapper cannot treat unknown verbs as reads: unlike the agent
// shell hook, it is the last checkpoint for unattended subprocess writes.
function runtimeOperation(argv) {
  const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
  const tokens = new Lexer(argv.map(quote).join(" ")).tokenize().tokens;
  const words = tokens.filter((t) => t.type === "word");
  const selected = runtimeCommand(argv);
  if (!selected) return "unsupported";
  const { group, verb, groupIndex } = selected;
  if (["--version", "--help", "help", "version"].includes(group)) return "read";
  if (group === "api") {
    const parsed = parseOptions(words.slice(groupIndex + 1), API_VALUED, (name) => API_VALUED.has(name) || API_BOOLS.has(name));
    if (parsed.unknown) return "unsupported";
    const method = parsed.flags.filter((f) => ["-X", "--method"].includes(f.name)).at(-1)?.value;
    const fields = parsed.flags.some((f) => ["-f", "-F", "--field", "--raw-field", "--input"].includes(f.name));
    return method ? (["GET", "HEAD"].includes(method.toUpperCase()) ? "read" : "write") : (fields ? "write" : "read");
  }
  const reads = {
    auth: ["status", "token"], pr: ["view", "list", "status", "checks", "diff"],
    issue: ["view", "list", "status"], repo: ["view", "list"],
    release: [...RELEASE_READ_VERBS], gist: ["view", "list"],
    run: ["view", "list", "watch", "download"], workflow: ["view", "list"],
  };
  if (reads[group]?.includes(verb)) return "read";
  return SPECS[`${group} ${verb}`] ? "write" : "unsupported";
}

// These documented file flags accept '-' as stdin. Derive supported verbs
// from the policy grammar so runtime snapshots cannot omit a checked verb.
function runtimeStdinFlags(argv) {
  const selected = runtimeCommand(argv);
  const spec = selected && SPECS[`${selected.group} ${selected.verb}`];
  return Object.keys(spec?.file || {}).filter((flag) => ["-F", "--body-file", "--notes-file"].includes(flag));
}

// Reuse the policy parser for the narrow generated-stdin preparation seam.
// Unsupported/conflicting argv never acquire normalization authority.
function runtimePrTarget(argv, cwd) {
  const selected = runtimeCommand(argv);
  if (selected?.group !== "pr" || !["create", "edit"].includes(selected.verb)) return null;
  const quote = (s) => `'${s.replaceAll("'", "'\\''")}'`;
  const tokens = new Lexer(["gh", ...argv].map(quote).join(" ")).tokenize().tokens;
  const target = checkGh(commandPosition(tokens), tokens, cwd,
    { compound: false, cwdKnown: true, targetOnly: true });
  return target?.repo && !target.decision ? target : null;
}

export { decision, runtimeOperation, runtimeCommand, runtimeStdinFlags, runtimePrTarget };
