// Uses a real JS parser (the acorn bundled with Node, only reachable with --expose-internals) to find calls t(...) where t is not the i18n translation function.
// Run by t-scope-guard.test.mjs in a child process: node --expose-internals t-scope-guard.cjs <files...> (or --src to read a piece of code from stdin)
// Outputs JSON: [{ file, line, col, decl }], one entry per t(...) call that resolves to a local binding (parameter, destructuring, catch parameter, for variable,
// nested function/class name, var/let/const). Scoping follows the spec: let/const/class/block-level function belong to the nearest block, var and parameters to the nearest function,
// and a const t declared later in the same block also shadows earlier calls (temporal dead zone).
"use strict";
let acorn;
try {
  acorn = require("internal/deps/acorn/acorn/dist/acorn");
} catch (e) {
  process.stdout.write(JSON.stringify({ error: "cannot load the acorn bundled with Node (did the path change after a Node upgrade?): " + e.message }));
  process.exit(3);
}
const fs = require("fs");

function patNames(p, out) {
  if (!p) return out;
  switch (p.type) {
    case "Identifier": out.push(p); break;
    case "ObjectPattern": for (const q of p.properties) patNames(q.type === "RestElement" ? q.argument : q.value, out); break;
    case "ArrayPattern": for (const q of p.elements) patNames(q, out); break;
    case "AssignmentPattern": patNames(p.left, out); break;
    case "RestElement": patNames(p.argument, out); break;
  }
  return out;
}
const isFn = (n) => n.type === "FunctionDeclaration" || n.type === "FunctionExpression" || n.type === "ArrowFunctionExpression";

// names declared by a scope node itself -> declaration info
function declsOf(node) {
  const m = new Map();
  const add = (id, how) => { if (id && !m.has(id.name)) m.set(id.name, { how, line: id.loc.start.line }); };
  const lexical = (stmts) => {
    for (const s of stmts) {
      if (s.type === "VariableDeclaration" && s.kind !== "var") for (const d of s.declarations) for (const id of patNames(d.id, [])) add(id, s.kind);
      else if (s.type === "FunctionDeclaration" || s.type === "ClassDeclaration") add(s.id, s.type === "ClassDeclaration" ? "class" : "function");
      else if ((s.type === "ExportNamedDeclaration" || s.type === "ExportDefaultDeclaration") && s.declaration) lexical([s.declaration]);
      else if (s.type === "ImportDeclaration") for (const sp of s.specifiers) add(sp.local, "import");
    }
  };
  const hoistVar = (n) => { // var: crosses blocks, does not enter nested functions
    if (!n || typeof n !== "object") return;
    if (Array.isArray(n)) { for (const x of n) hoistVar(x); return; }
    if (isFn(n)) return;
    if (n.type === "VariableDeclaration" && n.kind === "var") for (const d of n.declarations) for (const id of patNames(d.id, [])) add(id, "var");
    for (const k in n) if (k !== "loc" && n[k] && typeof n[k] === "object") hoistVar(n[k]);
  };
  if (node.type === "Program") { lexical(node.body); hoistVar(node.body); }
  else if (isFn(node)) {
    for (const p of node.params) for (const id of patNames(p, [])) add(id, "param");
    if (node.type === "FunctionExpression" && node.id) add(node.id, "function-name");
    if (node.body.type === "BlockStatement") { lexical(node.body.body); hoistVar(node.body.body); }
  } else if (node.type === "BlockStatement" || node.type === "StaticBlock") lexical(node.body);
  else if (node.type === "SwitchStatement") lexical(node.cases.flatMap((c) => c.consequent));
  else if (node.type === "CatchClause") for (const id of patNames(node.param, [])) add(id, "catch");
  else if (node.type === "ForStatement" || node.type === "ForInStatement" || node.type === "ForOfStatement") {
    const d = node.type === "ForStatement" ? node.init : node.left;
    if (d && d.type === "VariableDeclaration" && d.kind !== "var") for (const x of d.declarations) for (const id of patNames(x.id, [])) add(id, d.kind);
  } else if (node.type === "ClassExpression" && node.id) add(node.id, "class");
  return m;
}
const SCOPES = new Set(["Program", "FunctionDeclaration", "FunctionExpression", "ArrowFunctionExpression", "BlockStatement",
  "StaticBlock", "SwitchStatement", "CatchClause", "ForStatement", "ForInStatement", "ForOfStatement", "ClassExpression"]);

function scan(src, file) {
  const ast = acorn.parse(src, { ecmaVersion: "latest", sourceType: "module", locations: true, allowHashBang: true });
  const hits = [];
  const stack = [];
  const visit = (n, parentFnBody) => {
    if (!n || typeof n !== "object") return;
    if (Array.isArray(n)) { for (const x of n) visit(x); return; }
    if (typeof n.type !== "string") return;
    // a function body's BlockStatement is the same scope as the function itself, so it is not pushed separately
    const own = SCOPES.has(n.type) && !(n.type === "BlockStatement" && parentFnBody);
    if (own) stack.push({ node: n, names: declsOf(n) });
    if (n.type === "CallExpression" && n.callee.type === "Identifier" && n.callee.name === "t") {
      for (let i = stack.length - 1; i >= 0; i--) {
        const d = stack[i].names.get("t");
        if (!d) continue;
        // only a module-level import { t } (or i18n.js's own export function t) is the translation function
        if (stack[i].node.type !== "Program" || (d.how !== "import" && d.how !== "function")) hits.push({ file, line: n.loc.start.line, col: n.loc.start.column + 1, decl: d.how + "@" + d.line });
        break;
      }
    }
    for (const k in n) {
      if (k === "loc" || k === "type") continue;
      const v = n[k];
      if (v && typeof v === "object") visit(v, isFn(n) && k === "body");
    }
    if (own) stack.pop();
  };
  visit(ast);
  return hits;
}

const args = process.argv.slice(2);
let out = [];
if (args[0] === "--src") out = scan(fs.readFileSync(0, "utf8"), "<src>");
else for (const f of args) out = out.concat(scan(fs.readFileSync(f, "utf8"), f));
process.stdout.write(JSON.stringify(out));
