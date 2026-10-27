// Prevent a local variable t from shadowing the i18n translation function t (e.g. const t = h("table") in the mdBlocks table branch would degrade every table reply to plain text)
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const rd = (p) => readFileSync(new URL("../" + p, import.meta.url), "utf8");

// Blank out comments and the contents of string / template / regex literals (keeping quotes and length) so only the code skeleton remains.
// To still recognize calls like t("..."), the opening quote is kept after the string content is erased.
function strip(src) {
  let o = "", i = 0, prev = "";
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (c === "\\") { o += "  "; i += 2; continue; } // a backslash outside a string can only appear in a regex (e.g. /^image\//); skip it with the next character
    if (c === "/" && n === "/") { while (i < src.length && src[i] !== "\n") { o += " "; i++; } continue; }
    if (c === "/" && n === "*") { while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { o += src[i] === "\n" ? "\n" : " "; i++; } o += "  "; i += 2; continue; }
    if (c === '"' || c === "'" || c === "`") {
      o += c; i++;
      while (i < src.length && src[i] !== c) { if (src[i] === "\\") { o += " "; i++; } o += src[i] === "\n" ? "\n" : " "; i++; }
      o += c; i++; prev = c; continue;
    }
    // regex literal: a / preceded by an operator or ( , = : [ ! & | ? { } ; or at line start
    if (c === "/" && /[(,=:\[!&|?{};\n]|^$/.test(prev) ) {
      let j = i + 1, cls = false;
      while (j < src.length && src[j] !== "\n" && (cls || src[j] !== "/")) { if (src[j] === "\\") j++; else if (src[j] === "[") cls = true; else if (src[j] === "]") cls = false; j++; }
      if (src[j] === "/") { o += " ".repeat(j - i + 1); i = j + 1; prev = "/"; continue; }
    }
    o += c; i++;
    if (!/\s/.test(c)) prev = c; else if (c === "\n") prev = "\n";
  }
  return o;
}

// find the closing bracket that pairs with the one at open, searching after pos
function matchClose(s, open) {
  const pairs = { "{": "}", "(": ")", "[": "]" };
  let d = 0;
  for (let i = open; i < s.length; i++) {
    if ("{([".includes(s[i])) d++;
    else if ("})]".includes(s[i])) { d--; if (d === 0) return i; }
  }
  return s.length;
}

// returns [{decl, scopeStart, scopeEnd}]: scopes that declare a local variable / parameter named t
function tScopes(s) {
  const out = [];
  // block-scoped declarations: const/let/var t ... / const [a, t] / const {a, t} / for (const t of
  const declRe = /\b(?:const|let|var)\s+(?:t\b|[\[{][^=;]*?\bt\b[^=;]*?[\]}]\s*=)|\b(?:const|let|var)\s+[^;=(]*?,\s*t\s*=/g;
  for (let m; (m = declRe.exec(s));) {
    // the scope of for (const t of ...) is the for statement itself: from "for (" to its body
    const before = s.lastIndexOf("(", m.index);
    const isFor = /\bfor\s*$/.test(s.slice(Math.max(0, before - 6), before)) && matchClose(s, before) > m.index;
    if (isFor) {
      const close = matchClose(s, before);
      let k = close + 1;
      while (/\s/.test(s[k])) k++;
      const end = s[k] === "{" ? matchClose(s, k) : s.indexOf(";", k);
      out.push({ at: m.index, start: before, end });
      continue;
    }
    // plain declaration: scope = the enclosing block (search outward for the unclosed {)
    let d = 0, st = 0;
    for (let i = m.index - 1; i >= 0; i--) {
      if (s[i] === "}") d++;
      else if (s[i] === "{") { if (d === 0) { st = i; break; } d--; }
    }
    out.push({ at: m.index, start: st, end: matchClose(s, st) });
  }
  // arrow function / function parameters: (t) =>  (t, x) =>  (x, t) =>  t =>  function f(t)
  const parRe = /\(\s*(?:[^()]*?,\s*)?t\s*(?:=[^,()]*)?(?:,[^()]*)?\)\s*=>|\bt\s*=>|\bfunction\s*\w*\s*\((?:[^()]*?,\s*)?t\s*(?:=[^,()]*)?(?:,[^()]*)?\)/g;
  for (let m; (m = parRe.exec(s));) {
    let k = m.index + m[0].length;
    while (/\s/.test(s[k])) k++;
    let end;
    if (s[k] === "{") end = matchClose(s, k);
    else { // expression body: up to a , ) ; at the same level
      let d = 0, i = k;
      for (; i < s.length; i++) {
        if ("{([".includes(s[i])) d++;
        else if ("})]".includes(s[i])) { if (d === 0) break; d--; }
        else if ((s[i] === "," || s[i] === ";") && d === 0) break;
      }
      end = i;
    }
    out.push({ at: m.index, start: m.index, end });
  }
  return out;
}

// find translation calls t( inside scopes that declare a local t
function shadowedCalls(src) {
  const s = strip(src);
  const hits = [];
  for (const sc of tScopes(s)) {
    // the declaration's own initializer line does not count; only look after the declaration
    const body = s.slice(sc.at, sc.end + 1);
    const m = /(?<![\w$.])t\s*\(/.exec(body);
    if (m) hits.push({ line: s.slice(0, sc.at).split("\n").length, decl: body.slice(0, 40).replace(/\s+/g, " ") });
  }
  return hits;
}

const FILES = ["app.js", "logic.js", "viewer.js", "figures.js", "md.js"];

test("the scanner catches the pattern behind this bug", () => {
  const bad = `function f(parent) {\n  const t = h("table");\n  t.append(x);\n  parent.append(mdCopyWrap(wrap, t("md.table")));\n}`;
  assert.equal(shadowedCalls(bad).length, 1);
  assert.equal(shadowedCalls(`const g = (t) => t("a.b");`).length, 1);
  assert.equal(shadowedCalls(`for (const t of xs) { t("k.v"); }`).length, 1);
  assert.equal(shadowedCalls(`function f(a, t) { return t("k.v"); }`).length, 1);
});

test("the scanner has no false positives: after renaming, t(\" inside strings / comments, translation calls in other functions", () => {
  assert.equal(shadowedCalls(`function f() {\n  const tbl = h("table");\n  return t("md.table");\n}`).length, 0);
  assert.equal(shadowedCalls(`function f() { const t = 1; // t("x.y")\n  const s = 't("a.b")'; return t; }`).length, 0);
  assert.equal(shadowedCalls(`function f() { const t = 1; return t; }\nfunction g() { return t("a.b"); }`).length, 0);
  assert.equal(shadowedCalls(`const a = (t) => t.id;\nconst b = () => t("a.b");`).length, 0);
});

for (const f of FILES) {
  test(`${f}: no call to the translation function t("...") inside a scope that declares a local t`, () => {
    assert.deepEqual(shadowedCalls(rd(f)), []);
  });
}

test("the mdBlocks table branch does not use const t =", () => {
  const src = rd("app.js");
  const a = src.indexOf('b.type === "table"');
  assert.ok(a > 0, "table branch not found");
  const seg = src.slice(a, src.indexOf("md.table", a) + 20);
  assert.ok(seg.includes('t("md.table")'), "the table branch should call the translation function t(\"md.table\")");
  assert.doesNotMatch(seg, /\bconst t\s*=/);
  assert.doesNotMatch(seg, /\b(?:let|var) t\s*=/);
});
