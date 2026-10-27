import test from "node:test";
import assert from "node:assert/strict";
import { busyText, awayFromBottom, countNewItems, nextNewCount, newBtnText, quotePreview, buildQuoteText, scaledSize, imagePlan, uploadName, uploadPath } from "../logic.js";


test("busyText", () => {
  assert.equal(busyText(1000, 1030), "已干不到 1 分钟");
  assert.equal(busyText(1000, 1000 + 5 * 60 + 10), "已干 5 分钟");
  assert.equal(busyText(1000, 1000 + 3900), "已干 1 小时 5 分钟");
  assert.equal(busyText(0, 5000), "");
});

test("away from bottom threshold is 120px", () => {
  assert.equal(awayFromBottom(1000, 500, 380), false); // 120
  assert.equal(awayFromBottom(1000, 499, 380), true);  // 121
});

test("new item counting and button state", () => {
  const a = [{ role: "user" }, { role: "tool" }];
  const b = a.concat([{ role: "tool" }, { role: "assistant" }, { role: "assistant" }]);
  assert.equal(countNewItems(a, b), 2);
  assert.equal(countNewItems(b, a), 0);
  assert.equal(nextNewCount(1, 2, true), 3);
  assert.equal(nextNewCount(5, 2, false), 0);
  assert.equal(newBtnText(0), "");
  assert.equal(newBtnText(1), "↓ 新消息");
  assert.equal(newBtnText(4), "↓ 新消息 4");
});

test("quote preview and text", () => {
  assert.equal(quotePreview("a\nb"), "a b");
  // quote bar: 120 chars, two lines then ellipsis; sent body is "> quote (cut at 300)" + blank line + body (see msgops.test.mjs)
  assert.equal(quotePreview("x".repeat(130)), "x".repeat(120) + "…");
  assert.equal(buildQuoteText("line1\nline2", " hi \n"), "> line1 line2\n\nhi");
  assert.equal(buildQuoteText("x".repeat(400), "y"), "> " + "x".repeat(300) + "…\n\ny");
  assert.equal(buildQuoteText("", "y"), "y");
  assert.equal(buildQuoteText("q", ""), "> q");
});

test("scaledSize", () => {
  assert.deepEqual(scaledSize(1000, 500), { w: 1000, h: 500, scaled: false });
  assert.deepEqual(scaledSize(4000, 3000), { w: 2000, h: 1500, scaled: true });
  assert.deepEqual(scaledSize(3000, 6000), { w: 1000, h: 2000, scaled: true });
  assert.deepEqual(scaledSize(2000, 2000), { w: 2000, h: 2000, scaled: false });
});

test("imagePlan", () => {
  assert.deepEqual(imagePlan("image/png", 800, 600), { mode: "keep", type: "image/png", w: 800, h: 600 });
  assert.deepEqual(imagePlan("image/png", 4000, 2000), { mode: "canvas", type: "image/png", w: 2000, h: 1000 });
  assert.deepEqual(imagePlan("image/gif", 100, 100), { mode: "keep", type: "image/gif", w: 100, h: 100 });
  assert.deepEqual(imagePlan("image/heic", 3000, 1500), { mode: "canvas", type: "image/jpeg", w: 2000, h: 1000 });
  assert.deepEqual(imagePlan("image/jpeg", 500, 500), { mode: "canvas", type: "image/jpeg", w: 500, h: 500 });
});

test("uploadName and uploadPath", () => {
  assert.equal(uploadName("IMG_1.HEIC", "image/jpeg"), "IMG_1.jpg");
  assert.equal(uploadName("a.b.png", "image/png"), "a.b.png");
  assert.equal(uploadName("报告.pdf", "application/pdf"), "报告.pdf");
  assert.equal(uploadPath("s 1", "a&b.jpg", "说 明"), "/api/sessions/s%201/upload?name=a%26b.jpg&caption=%E8%AF%B4%20%E6%98%8E");
});

import { addAttachments, canSend, uploadProgressText, plainUploadPath, buildSendBody, MAX_ATTACH } from "../logic.js";
import { setLang } from "../i18n.js";
setLang("hans"); // node's navigator is en-US; these assertions are written for Simplified

test("addAttachments caps at 9 and drops oversize", () => {
  const f = (n, size = 1) => ({ name: n, size });
  let r = addAttachments([], [f("a"), f("b")]);
  assert.equal(r.list.length, 2);
  const eight = Array.from({ length: 8 }, (_, i) => f("x" + i));
  r = addAttachments(eight, [f("a"), f("b"), f("c")]);
  assert.equal(r.list.length, MAX_ATTACH);
  assert.equal(r.overLimit, 2);
  r = addAttachments([], [f("big", 21 * 1024 * 1024), f("ok")]);
  assert.deepEqual([r.list.length, r.tooBig, r.overLimit], [1, 1, 0]);
  const cur = [f("k")];
  addAttachments(cur, [f("z")]);
  assert.equal(cur.length, 1); // does not mutate the input
});

test("canSend needs text or attachments", () => {
  assert.equal(canSend("", 0), false);
  assert.equal(canSend("  \n ", 0), false);
  assert.equal(canSend("", 1), true);
  assert.equal(canSend("hi", 0), true);
});

test("upload progress text and paths", () => {
  assert.equal(uploadProgressText(1, 3), "上传中 2/3");
  assert.equal(uploadProgressText(3, 3), "上传中 3/3");
  assert.equal(plainUploadPath("照片 1.jpg"), "/api/uploads?name=" + encodeURIComponent("照片 1.jpg"));
});

test("buildSendBody", () => {
  assert.deepEqual(buildSendBody("hi", []), { text: "hi", enter: true });
  assert.deepEqual(buildSendBody("", ["a", "b"]), { text: "", files: ["a", "b"] });
  assert.deepEqual(buildSendBody("x", ["a"]), { text: "x", files: ["a"] });
});
