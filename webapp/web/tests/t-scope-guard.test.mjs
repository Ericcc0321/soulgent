// Second guard against `t` shadowing (a local `const t` hiding the translation function): scope analysis with a real parser,
// covering forms the regex scanner in t-shadow-guard cannot recognize
// (catch parameters, destructured parameters/defaults, method parameters, `let a, t;`, calls inside template ${}, a `const t` declared later in the same block, etc.).
// The parser is the acorn bundled with Node (node:internal, needs --expose-internals), so t-scope-guard.cjs is run in a child process.
// If acorn is unavailable this fails with the reason instead of silently skipping. The translation function keeps its name (590+ call sites); these two guards protect it.
import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";

const SCAN = fileURLToPath(new URL("./t-scope-guard.cjs", import.meta.url));
const run = (args, input) => {
  let out;
  try {
    out = execFileSync(process.execPath, ["--expose-internals", SCAN, ...args], { input, encoding: "utf8" });
  } catch (e) {
    throw new Error("t-scope-guard.cjs failed to run: " + (e.stdout || e.message));
  }
  return JSON.parse(out);
};
const scanSrc = (src) => run(["--src"], src);
const IMP = 'import { t } from "./i18n.js";\n';

test("catches every way of declaring t locally", () => {
  const bad = {
    "const t hides a t(...) call": "function f(p) { const t = h('table'); p.append(t('md.table')); }",
    "declared later in the same block (TDZ)": "function f() { g(t('a.b')); const t = 1; }",
    "arrow parameter": "const g = (t) => t('a.b');",
    "single arrow parameter without parentheses": "const g = t => t('a.b');",
    "function parameter": "function f(a, t) { return t('a.b'); }",
    "default-value parameter": "function f(a = 1, t = 2) { return t('a.b'); }",
    "destructured parameter": "const g = ({ t }) => t('a.b');",
    "array-destructured parameter": "const g = ([a, t]) => t('a.b');",
    "destructuring with rename": "function f() { const { x: t } = o; return t('a.b'); }",
    "catch parameter": "try { x(); } catch (t) { log(t('a.b')); }",
    "for-of destructuring": "for (const [k, t] of xs) t('a.b');",
    "for loop variable": "for (let t = 0; t < 3; t++) f(t('a.b'));",
    "let without initializer": "function f() { let a, t; return t('a.b'); }",
    "var hoisting": "function f() { if (x) { var t = 1; } return t('a.b'); }",
    "nested function name": "function f() { function t() {} return t('a.b'); }",
    "class name": "function f() { class t {} return t('a.b'); }",
    "method parameter": "const o = { m(t) { return t('a.b'); } };",
    "call inside a template string": "function f(t) { return `x ${t('a.b')} y`; }",
    "whoLine pattern (call first, const t afterwards)": "function whoLine(sp) { w.append(h('span', 'nm', sp.plate || t('c.peer'))); const t = whoTags(sp); if (t.star) x(); }",
  };
  for (const [k, src] of Object.entries(bad)) assert.equal(scanSrc(IMP + src).length, 1, k);
});

test("no false positives: top-level imported t, other names, properties, t( inside strings/comments/regexes", () => {
  const ok = [
    "function f() { return t('a.b'); }",
    "function f() { const tbl = 1; return t('a.b'); }",
    "function f(x) { return x.t('a.b') + o.t; }",
    "const o = { t: 1 }; function f() { return t('a.b'); }",
    "function f() { const s = 't(\"x\")'; /* t('y') */ return /t\\(/.test(s) ? t('a.b') : `t(${1})`; }",
    "function f() { { const t = 1; void t; } return t('a.b'); }", // local t is in an inner block, the call is in the outer one
    "const g = (t) => t.id; const h2 = () => t('a.b');",
  ];
  for (const src of ok) assert.deepEqual(scanSrc(IMP + src), [], src);
});

test("web/*.js: every t(...) call resolves to the i18n translation function", () => {
  const files = ["app.js", "logic.js", "viewer.js", "figures.js", "md.js", "i18n.js"].map((f) => fileURLToPath(new URL("../" + f, import.meta.url)));
  assert.deepEqual(run(files), []);
});
