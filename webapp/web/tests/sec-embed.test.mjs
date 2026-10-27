// Security: an embedded image from before a window switch must use the session id of the transcript it actually lives in (the server tags ref items with sid), not the current session id
import { test } from "node:test";
import assert from "node:assert/strict";
import { fileUrl } from "../logic.js";

test("fileUrl: when a ref item carries a sid (earlier window) use it instead of the current session id", () => {
  assert.equal(fileUrl({ ref: "12:1:ab", sid: "old-1" }, "cur-2"), "/api/file?sid=old-1&ref=12%3A1%3Aab&t=full");
  assert.equal(fileUrl({ ref: "12:1:ab", sid: "old-1" }, "cur-2", "thumb"), "/api/file?sid=old-1&ref=12%3A1%3Aab&t=thumb");
  assert.equal(fileUrl({ ref: "12:1:ab" }, "cur-2"), "/api/file?sid=cur-2&ref=12%3A1%3Aab&t=full"); // current window: uses the current session id
});
