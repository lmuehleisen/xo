// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [<key> <value> <note>]
// With a card key, the harness picks <value> (empty for none) and types <note>
// on that card's answer form, submits it, and reports what the page queued.
// Prints one JSON document:
//   { stats:[{n,label}], underway:[{title,sub,badges}],
//     charted:[{title,sub,badges,pickable}], empty, more, error, queued }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.classList = {
      add: (c) => { this.className = (this.className + " " + c).trim(); },
      contains: (c) => this.className.split(/\s+/).includes(c),
      toggle: (c, enabled) => {
        const names = new Set(this.className.split(/\s+/).filter(Boolean));
        if (enabled) names.add(c); else names.delete(c);
        this.className = [...names].join(" ");
      },
      remove: (c) => {
        this.className = this.className.split(/\s+/).filter((n) => n && n !== c).join(" ");
      },
    };
    this.listeners = {};
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, fn) { this.listeners[type] = fn; }
  querySelectorAll(sel) {
    const want = sel.replace(/^\./, "").replace(/:checked$/, "");
    const checkedOnly = sel.endsWith(":checked");
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (c.className.split(/\s+/).includes(want) && (!checkedOnly || c.checked)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("bearings-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node("div");
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
globalThis.window = {};
globalThis.TextEncoder = TextEncoder;

const [submitKey, submitValue = "", submitNote = ""] = process.argv.slice(3);
const queued = [];
if (submitKey !== undefined) {
  globalThis.window.lavish = {
    queuePrompt: (prompt, opts) => queued.push({ prompt, text: opts.text, data: opts.data }),
  };
  globalThis.setTimeout = () => 0;
}
const findAll = (node, test, out = []) => {
  for (const c of node.children) {
    if (test(c)) out.push(c);
    findAll(c, test, out);
  }
  return out;
};
globalThis.FormData = class {
  constructor(form) { this.form = form; }
  get(name) {
    const inputs = findAll(this.form, (n) => n.tagName === "input" && n.name === name);
    const hit = inputs.find((n) => n.type !== "radio" || n.checked);
    return hit ? hit.value : null;
  }
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const callDeck = byId.get("bb-call") || new Node("div");
const callControls = [];
function collectControls(node) {
  if (["form", "input", "textarea", "select"].includes(node.tagName)) callControls.push(node.tagName);
  node.children.forEach(collectControls);
}
collectControls(callDeck);
collectControls(ch);
const calls = callDeck.children.map(c => c.textContent);
if (submitKey !== undefined) {
  const form = findAll(callDeck, (n) => n.tagName === "form"
    && n.attributes["data-lavish-question"] === submitKey)[0];
  if (!form) throw new Error("no answer form for card " + submitKey);
  findAll(form, (n) => n.tagName === "input").forEach((n) => {
    if (n.type === "radio") n.checked = n.value === submitValue;
    else if (n.name === "note") n.value = submitNote;
  });
  form.listeners.submit({ preventDefault() {} });
}
process.stdout.write(
  JSON.stringify({ stats, underway, charted, empty, more, calls, callControls, error: errorText, queued }) + "\n");
