// Lightweight Markdown parser (pure functions, no DOM, shared by browser and node).
// parseMarkdown(text) → array of blocks:
//   {type:"heading", level, c} {type:"para", c} {type:"code", lang, text} {type:"hr"}
//   {type:"list", ordered, start, items:[blocks]} {type:"quote", blocks}
//   {type:"table", align:[null|"left"|"center"|"right"], head:[inline nodes], rows:[[inline nodes]]}
// Inline nodes: {t:"text",text} {t:"br"} {t:"code",text} {t:"strong"|"em"|"del", c} {t:"link", href, c}
// Never throws on any input; anything unrecognized is text. Link hrefs are not protocol-filtered; the renderer decides.

const MAX_DEPTH = 12;
// When the parser itself fails, hand the error to diagErr in app.js (listens for sg-err); node has no dispatchEvent, so stay silent
function reportErr(where, err) {
  try { globalThis.dispatchEvent(new CustomEvent("sg-err", { detail: { where, err } })); } catch (e) { /* ignore */ }
}
const FENCE_RE = /^ {0,3}(`{3,}|~{3,})\s*([^\s`]*)[^`]*$/;
const HEADING_RE = /^ {0,3}(#{1,6})(?:[ \t]+(.*?))?(?:[ \t]+#+)?[ \t]*$/;
const HR_RE = /^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const LIST_RE = /^( *)([-*+]|\d{1,9}[.)])[ \t]+(.*)$/;
const QUOTE_RE = /^ {0,3}>[ ]?(.*)$/;
const SEP_CELL_RE = /^:?-{1,}:?$/;

const indentOf = (l) => l.length - l.replace(/^ +/, "").length;
const isBlank = (l) => l.trim() === "";

export function parseMarkdown(text) {
  try {
    const src = String(text == null ? "" : text).replace(/\r\n?/g, "\n").replace(/\t/g, "    ");
    return parseBlocks(src.split("\n"), 0);
  } catch (e) {
    reportErr("parseMarkdown", e); // fall back to one plain-text paragraph, and report the error
    return [{ type: "para", c: [{ t: "text", text: String(text) }] }];
  }
}

function isHeading(l) { return /^ {0,3}#{1,6}(?:[ \t]|$)/.test(l); }

function startsBlock(l) {
  return FENCE_RE.test(l) || isHeading(l) || HR_RE.test(l) || QUOTE_RE.test(l) || LIST_RE.test(l);
}

function parseBlocks(lines, depth) {
  const out = [];
  if (depth > MAX_DEPTH) {
    const t = lines.join("\n").trim();
    if (t) out.push({ type: "para", c: [{ t: "text", text: t }] });
    return out;
  }
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (isBlank(line)) { i++; continue; }
    let m;
    // fenced code block (unclosed runs to the end)
    if ((m = FENCE_RE.exec(line))) {
      const fence = m[1];
      const ch = fence[0];
      const body = [];
      i++;
      while (i < lines.length) {
        const t = lines[i].trim();
        if (t.length >= fence.length && t.split(ch).join("") === "") { i++; break; }
        body.push(lines[i]);
        i++;
      }
      out.push({ type: "code", lang: m[2] || "", text: body.join("\n") });
      continue;
    }
    if (isHeading(line) && (m = HEADING_RE.exec(line))) {
      out.push({ type: "heading", level: m[1].length, c: parseInline(m[2] || "", 0) });
      i++;
      continue;
    }
    if (HR_RE.test(line)) { out.push({ type: "hr" }); i++; continue; }
    if (QUOTE_RE.test(line)) {
      const inner = [];
      while (i < lines.length && (m = QUOTE_RE.exec(lines[i]))) { inner.push(m[1]); i++; }
      out.push({ type: "quote", blocks: parseBlocks(inner, depth + 1) });
      continue;
    }
    if (LIST_RE.test(line)) {
      const r = parseList(lines, i, depth);
      out.push(r.block);
      i = r.next;
      continue;
    }
    const tb = tryTable(lines, i);
    if (tb) { out.push(tb.block); i = tb.next; continue; }
    const para = [line];
    i++;
    while (i < lines.length && !isBlank(lines[i]) && !startsBlock(lines[i]) && !tryTable(lines, i)) {
      para.push(lines[i]);
      i++;
    }
    out.push({ type: "para", c: parseInline(para.map((l) => l.trim()).join("\n"), 0) });
  }
  return out;
}

function parseList(lines, start, depth) {
  const first = LIST_RE.exec(lines[start]);
  const base = first[1].length;
  const ordered = /\d/.test(first[2]);
  const startNum = ordered ? parseInt(first[2], 10) : 1;
  const items = [];
  let i = start;
  while (i < lines.length) {
    const m = LIST_RE.exec(lines[i]);
    if (!m || m[1].length > base || /\d/.test(m[2]) !== ordered) break;
    const content = [m[3] || ""];
    i++;
    const cont = [];
    // collect more deeply indented lines (including blank lines between, as long as an indented line follows)
    while (i < lines.length) {
      const l = lines[i];
      if (isBlank(l)) {
        let j = i;
        while (j < lines.length && isBlank(lines[j])) j++;
        if (j < lines.length && indentOf(lines[j]) > base) { for (; i < j; i++) cont.push(""); continue; }
        break;
      }
      if (indentOf(l) > base) { cont.push(l); i++; continue; }
      break;
    }
    if (cont.length) {
      const strip = Math.min(...cont.filter((l) => !isBlank(l)).map(indentOf));
      for (const l of cont) content.push(isBlank(l) ? "" : l.slice(strip));
    }
    items.push(parseBlocks(content, depth + 1));
    // blank line between list items: continue if a same-level item follows immediately
    let j = i;
    while (j < lines.length && isBlank(lines[j])) j++;
    if (j > i && j < lines.length) {
      const n = LIST_RE.exec(lines[j]);
      if (n && n[1].length <= base && /\d/.test(n[2]) === ordered) i = j;
    }
  }
  return { block: { type: "list", ordered, start: startNum, items }, next: i };
}

function splitRow(line) {
  let s = line.trim();
  if (s.startsWith("|")) s = s.slice(1);
  const cells = [];
  let cur = "";
  let inCode = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "\\" && s[i + 1] === "|") { cur += "|"; i++; continue; }
    if (c === "`") inCode = !inCode;
    if (c === "|" && !inCode) { cells.push(cur); cur = ""; continue; }
    cur += c;
  }
  cells.push(cur);
  // a trailing | produces an empty last cell
  if (cells.length > 1 && cells[cells.length - 1].trim() === "" && /\|\s*$/.test(line)) cells.pop();
  return cells.map((x) => x.trim());
}

function tryTable(lines, i) {
  if (i + 1 >= lines.length) return null;
  const head = lines[i];
  const sep = lines[i + 1];
  if (head.indexOf("|") < 0 || sep.indexOf("-") < 0) return null;
  if (!/^[\s|:-]+$/.test(sep)) return null;
  const sc = splitRow(sep);
  if (!sc.length || !sc.every((c) => SEP_CELL_RE.test(c))) return null;
  const hc = splitRow(head);
  if (hc.length !== sc.length) return null;
  const align = sc.map((c) => {
    const l = c[0] === ":", r = c[c.length - 1] === ":";
    return l && r ? "center" : r ? "right" : l ? "left" : null;
  });
  const rows = [];
  let j = i + 2;
  while (j < lines.length && !isBlank(lines[j]) && lines[j].indexOf("|") >= 0) {
    const cells = splitRow(lines[j]);
    while (cells.length < hc.length) cells.push("");
    rows.push(cells.slice(0, hc.length).map((c) => parseInline(c, 0)));
    j++;
  }
  return { block: { type: "table", align, head: hc.map((c) => parseInline(c, 0)), rows }, next: j };
}

// ---------- inline ----------
const PUNCT_RE = /[!-/:-@[-`{-~]/;
const WORD_RE = /[\p{L}\p{N}]/u;
const URL_RE = /^https?:\/\/[^\s<>\u0080-￿]+/i;

function pushText(out, s) {
  if (!s) return;
  const last = out[out.length - 1];
  if (last && last.t === "text") last.text += s;
  else out.push({ t: "text", text: s });
}

function runLen(s, i, ch) { let n = 0; while (s[i + n] === ch) n++; return n; }

// find the closing run of exactly n backticks; -1 if none
function findTick(s, from, n) {
  let j = from;
  while (j < s.length) {
    const p = s.indexOf("`", j);
    if (p < 0) return -1;
    const len = runLen(s, p, "`");
    if (len === n) return p;
    j = p + len;
  }
  return -1;
}

// find the closing marker (k copies of ch) from `from`, skipping escapes and code spans. Returns the start of the closing run or -1.
function findClose(s, from, ch, k) {
  for (let j = from; j < s.length; j++) {
    const c = s[j];
    if (c === "\\") { j++; continue; }
    if (c === "`") {
      const n = runLen(s, j, "`");
      const close = findTick(s, j + n, n);
      j = close >= 0 ? close + n - 1 : j + n - 1;
      continue;
    }
    if (c !== ch) continue;
    const n = runLen(s, j, ch);
    const prev = s[j - 1];
    const next = s[j + n];
    const okClose = j > from && !/\s/.test(prev) &&
      (ch === "*" || ch === "~" || !(next && WORD_RE.test(next)));
    if (okClose && n === k) return j;
    if (okClose && n > k && ch !== "~") return j + (n - k);
    j += n - 1;
  }
  return -1;
}

function parseInline(s, depth) {
  const out = [];
  if (depth > MAX_DEPTH) { pushText(out, s); return out; }
  let buf = "";
  const flush = () => { pushText(out, buf); buf = ""; };
  let i = 0;
  while (i < s.length) {
    const c = s[i];
    if (c === "\n") { flush(); out.push({ t: "br" }); i++; continue; }
    if (c === "\\" && i + 1 < s.length && PUNCT_RE.test(s[i + 1])) { buf += s[i + 1]; i += 2; continue; }
    if (c === "`") {
      const n = runLen(s, i, "`");
      const cl = findTick(s, i + n, n);
      if (cl >= 0) {
        flush();
        let code = s.slice(i + n, cl).replace(/\n/g, " ");
        if (code.length > 2 && code[0] === " " && code[code.length - 1] === " ") code = code.slice(1, -1);
        out.push({ t: "code", text: code });
        i = cl + n;
        continue;
      }
      buf += "`".repeat(n);
      i += n;
      continue;
    }
    if (c === "[") {
      const lk = tryLink(s, i);
      if (lk) {
        flush();
        out.push({ t: "link", href: lk.href, c: parseInline(lk.text, depth + 1) });
        i = lk.end;
        continue;
      }
    }
    if ((c === "h" || c === "H") && (i === 0 || !WORD_RE.test(s[i - 1]))) {
      const m = URL_RE.exec(s.slice(i, i + 2000));
      if (m) {
        let u = m[0];
        for (;;) { // strip trailing punctuation and extra closing parentheses
          const last = u[u.length - 1];
          if (/[.,;:!?'"*_~]/.test(last)) u = u.slice(0, -1);
          else if (last === ")" && u.split(")").length > u.split("(").length) u = u.slice(0, -1);
          else break;
        }
        if (/^https?:\/\/[^/?#]/i.test(u)) {
          flush();
          out.push({ t: "link", href: u, c: [{ t: "text", text: u }] });
          i += u.length;
          continue;
        }
      }
    }
    if (c === "*" || c === "_" || c === "~") {
      const n = runLen(s, i, c);
      const prev = s[i - 1];
      let done = false;
      const ks = c === "~" ? (n >= 2 ? [2] : []) : n >= 3 ? [3, 2, 1] : n === 2 ? [2, 1] : [1];
      for (const k of ks) {
        const after = s[i + k];
        if (after === undefined || /\s/.test(after)) continue;
        if (c === "_" && prev && WORD_RE.test(prev)) continue;
        if (n > k) continue; // the opening marker run must be exactly k long
        const close = findClose(s, i + k, c, k);
        if (close < 0 || close <= i + k) continue;
        const inner = s.slice(i + k, close);
        if (!inner.trim()) continue;
        flush();
        const kids = parseInline(inner, depth + 1);
        let node;
        if (c === "~") node = { t: "del", c: kids };
        else if (k === 3) node = { t: "em", c: [{ t: "strong", c: kids }] };
        else node = { t: k === 2 ? "strong" : "em", c: kids };
        out.push(node);
        i = close + k;
        done = true;
        break;
      }
      if (done) continue;
      buf += c.repeat(n);
      i += n;
      continue;
    }
    buf += c;
    i++;
  }
  flush();
  return out;
}

function tryLink(s, i) {
  let depth = 0;
  let j = i;
  for (; j < s.length; j++) {
    const c = s[j];
    if (c === "\\") { j++; continue; }
    if (c === "`") {
      const n = runLen(s, j, "`");
      const e = findTick(s, j + n, n);
      j = e >= 0 ? e + n - 1 : j + n - 1;
      continue;
    }
    if (c === "[") depth++;
    else if (c === "]") { depth--; if (depth === 0) break; }
  }
  if (j >= s.length || s[j + 1] !== "(") return null;
  const text = s.slice(i + 1, j);
  if (!text) return null;
  let k = j + 2;
  let paren = 0;
  let url = "";
  for (; k < s.length; k++) {
    const c = s[k];
    if (/\s/.test(c)) break;
    if (c === "(") paren++;
    else if (c === ")") { if (paren === 0) break; paren--; }
    url += c;
  }
  if (/\s/.test(s[k] || "")) { // optional title "title"
    const m = /^\s+("[^"]*"|'[^']*')\s*\)/.exec(s.slice(k));
    if (!m) return null;
    k += m[0].length;
  } else if (s[k] === ")") k++;
  else return null;
  if (!url) return null;
  return { text, href: url.replace(/^<|>$/g, ""), end: k };
}

// Copy a table as tab-separated text: rows is a 2D array of plain text; tabs and newlines inside cells are squashed to spaces
export function tsvText(rows) {
  return (rows || []).map((r) => r.map((c) => String(c == null ? "" : c).replace(/[\t\r\n]+/g, " ")).join("\t")).join("\n");
}
