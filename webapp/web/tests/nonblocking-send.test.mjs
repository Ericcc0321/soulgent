// Non-blocking send: text/attachment sends do not block (the send button neither spins nor disables), no "delivered" toast, four receipt styles (clock / bright-yellow single check = sent but unread / white double check = read / red !),
// tapping the red ! offers resend / delete; recall rule: queued in the transcript = delivered
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { setLang } from "../i18n.js";
import { receiptOf, canRecall, bubbleActs, recallLock, recallAsk, rcTipText, PEND_STAGES } from "../logic.js";

const rd = (f) => readFileSync(new URL("../" + f, import.meta.url), "utf8");
const app = rd("app.js");
const fnBody = (name, n = 2500) => { const i = app.indexOf("function " + name); assert.ok(i >= 0, "missing " + name); return app.slice(i, i + n); };

test("receiptOf: an optimistic bubble follows its stage clock / sent / delivered; no stage = clock; failure = failed", () => {
  assert.deepEqual(PEND_STAGES, ["clock", "sent", "delivered"]);
  assert.equal(receiptOf({ pend: true }), "clock");
  assert.equal(receiptOf({ pend: true, stage: "clock" }), "clock");
  assert.equal(receiptOf({ pend: true, stage: "sent" }), "sent");
  assert.equal(receiptOf({ pend: true, stage: "delivered" }), "delivered");
  assert.equal(receiptOf({ pend: true, stage: "read" }), "clock"); // an optimistic bubble never claims to be read
  assert.equal(receiptOf({ pend: true, stage: "delivered", failed: true }), "failed");
});

test("receiptOf: transcript read:false (queued) = delivered, bright-yellow single check (sent, unread); read:true = read, white double check; recalled / legacy data handled", () => {
  assert.equal(receiptOf({ role: "user", read: false, queued: true }), "delivered");
  assert.equal(receiptOf({ role: "user", read: false }), "delivered");
  assert.equal(receiptOf({ role: "user", read: true }), "read");
  assert.equal(receiptOf({ role: "user", read: false, recalled: true }), "recalled");
  assert.equal(receiptOf({ role: "user" }), null);
  assert.equal(receiptOf({ role: "assistant", read: false }), null);
  assert.equal(receiptOf(null), null);
});

// Recall vs. receipt stages: queued in the transcript = delivered; read is recallable; the in-flight stages (including optimistic delivered), failed and recalled never offer recall
test("canRecall / bubbleActs: only delivered / read from the transcript offer recall; optimistic bubbles never do at any stage", () => {
  assert.equal(canRecall("delivered"), true);
  assert.equal(canRecall("read"), true);
  for (const rc of ["clock", "sent", "failed", "recalled", null, "sending"]) assert.equal(canRecall(rc), false, String(rc));
  for (const rc of ["clock", "sent", "delivered", "read"]) assert.equal(canRecall(rc, true), false, "pend " + rc);
  const withR = ["copy", "quote", "forward", "recall"];
  const noR = ["copy", "quote", "forward"];
  assert.deepEqual(bubbleActs({ who: "me", receipt: "delivered" }), withR);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "read" }), withR);
  for (const rc of ["clock", "sent", "delivered", "failed"]) assert.deepEqual(bubbleActs({ who: "me", receipt: rc, pend: true }), noR, "pend " + rc);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "sent" }), noR); // sent does not appear in the transcript; if it does, recall is still not offered
  // guests follow the same rule (no forward)
  assert.deepEqual(bubbleActs({ who: "me", receipt: "delivered", guest: true }), ["copy", "quote", "recall"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "read", guest: true }), ["copy", "quote", "recall"]);
  assert.deepEqual(bubbleActs({ who: "me", receipt: "sent", pend: true, guest: true }), ["copy", "quote"]);
  assert.deepEqual(bubbleActs({ who: "self", receipt: "delivered" }), noR); // not mine: not offered
});

test("recallLock: the 2-minute window applies to delivered / read; every other stage is locked", () => {
  const ts = "2026-10-23T03:00:00Z";
  const t0 = Date.parse(ts) / 1000;
  assert.equal(recallLock("delivered", ts, t0 + 120), false);
  assert.equal(recallLock("delivered", ts, t0 + 121), true);
  assert.equal(recallLock("read", ts, t0 + 60), false);
  assert.equal(recallLock("read", ts, t0 + 121), true);
  for (const rc of ["clock", "sent", "failed", "recalled"]) assert.equal(recallLock(rc, ts, t0 + 1), true, rc);
  assert.equal(recallLock("delivered", "", t0), true); // no ts (optimistic bubble) = locked
  // read + busy keeps the interrupt confirmation; queued ones are not asked
  assert.equal(recallAsk("read", "busy", false), true);
  assert.equal(recallAsk("delivered", "busy", false), false);
  assert.equal(recallAsk("read", "busy", true), false);
});

test("receipt tooltips in three languages", () => {
  setLang("en");
  assert.deepEqual(["clock", "sent", "delivered", "read", "failed"].map(rcTipText), ["Sending", "Delivered — it'll read when free", "Delivered — it'll read when free", "Read", "Not delivered"]);
  setLang("hant");
  assert.deepEqual(["clock", "sent", "delivered", "read", "failed"].map(rcTipText), ["傳送中", "已送到，它忙完會讀", "已送到，它忙完會讀", "已讀", "未送達"]);
  setLang("hans");
  assert.deepEqual(["clock", "sent", "delivered", "read", "failed"].map(rcTipText), ["发送中", "已送到，它忙完会读", "已送到，它忙完会读", "已读", "未送达"]);
});

test("app: text/attachment sends leave the send button alone (clicked is null) and do not occupy st.sending; card answers keep their spinner", () => {
  assert.doesNotMatch(app, /submitSend\([^)]*\$\("#btn-send"\)/, "text/attachment sends do not turn the send button into a spinner");
  assert.equal((app.match(/submitSend\(st\.byId\.get\(sid\) \|\| s, pend\.body, null, null, "", null, pend\)/g) || []).length, 2); // text, attachment
  const ss = fnBody("submitSend(", 1200);
  assert.match(ss, /const card = !pend;/);
  assert.match(ss, /if \(card && st\.sending\) return false;/);
  assert.match(ss, /if \(card\) st\.sending = true;/);
  assert.doesNotMatch(fnBody("queueTray(", 3000), /st\.sending = true/, "the upload stage does not occupy st.sending either");
  // card answers take the keyed path (button spins, duplicate-protected)
  assert.match(app, /submitSend\(s, \{ steps: approveSteps\(choice\) \}, box, b, label, key\)/);
});

test("app: no \"delivered\" toast; i18n drops toast.delivered / recall.notSent", () => {
  assert.doesNotMatch(app, /toast\.delivered/);
  assert.doesNotMatch(fnBody("afterSent(", 600), /toast\(/);
  const i18n = rd("i18n.js");
  assert.doesNotMatch(i18n, /"toast\.delivered"|"recall\.notSent"|"rc\.sending"|"rcl\.sending"/);
  for (const k of ["rc.clock", "rc.delivered", "rcl.clock", "rcl.delivered", "bm.resend", "bm.delete"]) assert.match(i18n, new RegExp('"' + k.replace(".", "\\.") + '": \\['), k);
});

test("app: stage changes only swap the icon - got requestId = sent, typed into the terminal = delivered; the signature excludes stage", () => {
  assert.match(app, /if \(onAccepted\) onAccepted\(\);\n  const r = await pollRequest\(rid, t0\);/);
  assert.match(app, /pend \? \(\) => pendStage\(pend, "sent"\) : null/);
  assert.match(app, /if \(pend\) pendStage\(pend, "delivered"\);/);
  const pm = fnBody("pendMark(", 600);
  assert.match(pm, /const mk = rcMark\(rc, el\);\n  if \(old\) old\.replaceWith\(mk\);/);
  assert.match(pm, /meta\.receipt = rc/);
  assert.doesNotMatch(pm, /renderList/);
  assert.match(app, /const PEND_SIG_SKIP = new Set\(\["stage",/);
  assert.match(app, /receiptOf\(\{ pend: true, failed: p\.failed, stage: p\.stage \}\)/);
});

test("app: the red ! offers resend / delete; delete does not put the text back into the input; resend returns to the clock and recomputes n0", () => {
  const rm = fnBody("rcMark(", 1600);
  assert.match(rm, /if \(rc === "failed"\) \{ failMenu\(el, meta\.pend\); return; \}/);
  assert.doesNotMatch(rm, /canRecall/); // tapping the check shows no recall confirmation; recall only goes through the long-press menu
  const fm = fnBody("failMenu(", 700);
  assert.match(fm, /bm\.resend/);
  assert.match(fm, /bm\.delete/);
  assert.match(fm, /openBubblePop\(el, box, "bm-confirm"\)/);
  const df = fnBody("dropFailed(", 800);
  assert.doesNotMatch(df, /toast\(|#reply/);
  const rs = fnBody("resendPend(", 900);
  assert.match(rs, /pend\.stage = "clock"/);
  assert.match(rs, /pend\.n0 = userCount\(st\.items\)/);
  assert.match(rs, /queueTray\(s, pend\); else queueText\(s, pend\)/);
  // text failure: only an at-menu rejection (bubble removed) puts the text back into the input
  const qt = fnBody("queueText(", 1800);
  assert.match(qt, /if \(!drop\) \{/);
  assert.equal((qt.match(/\$\("#reply"\)\.value = pend\.raw/g) || []).length, 1);
  // attachment failure: attachments are not put back into the tray
  assert.doesNotMatch(fnBody("queueTray(", 3200), /st\.tray = items/);
});

test("version sync", () => {
  assert.match(rd("sw.js"), /const VERSION = "v142";/);
  assert.match(rd("index.html"), /<meta name="zbs-shell" content="v142">/);
});
