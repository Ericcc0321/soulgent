// Share/save must fetch the full original file (?dl=1) and refuse a body the server marked X-Truncated
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const viewer = readFileSync(new URL("../viewer.js", import.meta.url), "utf8");
const i = viewer.search(/export async function shareFile\(/);
const body = viewer.slice(i, viewer.indexOf("\n}\n", i));

test("shareFile requests the full-file variant (dl=1)", () => {
  assert.match(body, /fileUrl\(f, sid, "full", true\)/);
});
test("shareFile refuses an X-Truncated response before building the File", () => {
  const trunc = body.search(/headers\.get\("X-Truncated"\)/);
  assert.ok(trunc >= 0);
  assert.ok(trunc < body.indexOf("r.blob()"));
  assert.match(body.slice(trunc, body.indexOf("r.blob()")), /onMsg[^;]*;\s*return;/);
});
