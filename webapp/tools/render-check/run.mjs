// render-check: run the real frontend in headless Chrome, visit every rendering path in all three languages, and catch console errors and uncaught exceptions.
// Any of these fails the run: an uncaught exception, console.error, a failed /api/file load, the page showing the "file no longer exists" text (any of the three languages),
// an err record reported to /api/diag by the frontend, or the scenario's own check failing. Exit code 1.
//
//   node tools/render-check/run.mjs                    all scenarios x en/hans/hant (using the repo's web/)
//   node tools/render-check/run.mjs --web /tmp/x/web   use another copy of the frontend (e.g. an older exported version)
//   node tools/render-check/run.mjs --only reader-md,chat --langs en
//   node tools/render-check/run.mjs --shots /tmp/shots [--tag before]   screenshot each scenario at the end as <scenario>[-<tag>]-<language>.png
//   node tools/render-check/run.mjs --md some.md       attach an extra external Markdown file (scenario reader-extra) to debug real files
//   node tools/render-check/run.mjs --record /tmp/soulchat-gif --only soulchat-knock --langs en   record GIF frames (see README, section GIF feature wall; needs RC_PETS_DIR)
//   --list lists scenarios; --keep keeps the temp data directory; -v prints every record
// All data is fictional content produced by gen.py; the server is the repo's api/server.py (serve.py only adds auto-login and static files).
import { spawn } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, rmSync, appendFileSync, renameSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import net from "node:net";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = resolve(HERE, "..", "..");
const argv = process.argv.slice(2);
const opt = (k, d = "") => { const i = argv.indexOf(k); return i >= 0 ? argv[i + 1] : d; };
const flag = (k) => argv.includes(k);
const WEB = resolve(opt("--web", join(REPO, "web")));
const SHOTS = opt("--shots") ? resolve(opt("--shots")) : "";
const TAG = opt("--tag");
const MD = opt("--md") ? resolve(opt("--md")) : "";
const ONLY = opt("--only") ? opt("--only").split(",") : null;
const LANGS = (opt("--langs") || "en,hans,hant").split(",");
const VERBOSE = flag("-v");
const PY = existsSync("/usr/bin/python3") ? "/usr/bin/python3" : "python3";
const CHROME = process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const GONE = ["File no longer exists", "文件已不在", "檔案已不在"]; // i18n c.fileGone / at.goneName in three languages

// ---------- scenarios ----------
// path: URL to open (the # part opens a session); tab: bottom-bar page pre-written into localStorage; run: async function (as a string) executed in the page,
// returns { fail: [...] } (empty array = pass). The page has an rc helper: rc.wait(fn|selector, ms, description), rc.click(selector), rc.sleep, rc.q, rc.qa, rc.lang
// expectGone: this scenario deliberately has a broken image, so the "file no longer exists" text and that /api/file 404 do not count as failures;
// allowErr: a report this scenario triggers on purpose (where equals it); the matching console.error and the err record in diag.jsonl do not count as failures
const IDS = {}; // session ids printed by gen.py, filled in after startup
const RIDS = {}; // session ids printed by gen_readme.py (fixture for README screenshots only; scenarios with readme:true)
// Send two messages in quick succession: while the first is in flight the send key does not spin or disable and the input stays usable; the second is queued and sent in order;
// tap the red ! to open the resend / delete menu: resend goes back to the clock and then delivers; delete removes the bubble and does not put the text back into the input
const rc_burst = `
    await rc.wait("#list .cg", 8000, "chat");
    await rc.sleep(800);
    const f = [];
    let failOnce = new Set(["Retry me please.", "Drop me please."]);
    const posts = rc.stubSend((tx) => (failOnce.delete(tx) ? "fail" : "done"), 900);
    const btn = rc.q("#btn-send"), ta = rc.q("#reply");
    const pend = () => rc.qa("#list .m.me.pend");
    await rc.send("First quick message.");
    await rc.sleep(50);
    if (btn.classList.contains("busy") || btn.querySelector(".spinner")) f.push("send button is spinning");
    if (ta.disabled || ta.readOnly) f.push("input box is locked");
    if (ta.value) f.push("input box not cleared");
    await rc.send("Second quick message.");
    await rc.sleep(50);
    if (pend().length !== 2) f.push("second message not drawn (pending bubbles: " + pend().length + ")");
    else if (!pend()[1].querySelector(".rc-mk.rc-clock")) f.push("second message not queued on the clock");
    await rc.wait(() => pend().length === 2 && pend().every((e) => e.querySelector(".rc-mk.rc-delivered")), 8000, "both delivered (yellow single tick)");
    if (rc.q("#toast.show")) f.push("toast still showing after delivery: " + rc.q("#toast").textContent);
    const order = posts.map((p) => p.text);
    if (order.join("|") !== "First quick message.|Second quick message.") f.push("wrong send order: " + order.join(" | "));
    await rc.send("Retry me please.");
    await rc.wait(() => pend()[2] && pend()[2].querySelector(".rc-mk.rc-failed"), 6000, "red ! (pending resend)");
    if (ta.value) f.push("text was put back into input after failure: " + ta.value);
    pend()[2].querySelector(".rc-mk.rc-failed").click();
    await rc.wait(() => rc.qa(".bm-pop .bm-it").length === 2, 2000, "resend / delete menu");
    rc.qa(".bm-pop .bm-it")[0].click();
    await rc.wait(() => pend()[2] && pend()[2].querySelector(".rc-mk.rc-clock, .rc-mk.rc-sent"), 2000, "resend returned to clock");
    await rc.wait(() => pend()[2] && pend()[2].querySelector(".rc-mk.rc-delivered"), 8000, "delivered after resend");
    await rc.send("Drop me please.");
    await rc.wait(() => pend()[3] && pend()[3].querySelector(".rc-mk.rc-failed"), 6000, "second red !");
    pend()[3].querySelector(".rc-mk.rc-failed").click();
    await rc.wait(() => rc.qa(".bm-pop .bm-it").length === 2, 2000, "menu");
    rc.qa(".bm-pop .bm-it")[1].click();
    await rc.wait(() => pend().length === 3, 2000, "bubble removed after delete");
    if (ta.value) f.push("text was put back into input after delete: " + ta.value);
    return { fail: f };`;
// Preview questions (scenarios ask-preview-note1 / 2): every question card is ticked first, then submitted. k = which option ends up selected; with k=2 option 1 is tapped and then option 2 (only moves the selection, nothing is sent);
// the note row is always shown after the option group; k=1 sends via the submit button, k=2 sends by pressing Enter in the note box
const rc_previewNote = (k) => `
    const sid = decodeURIComponent(location.hash.slice(3));
    rc.stubSnap((j) => { const s = j.sessions.find((x) => x.id === sid); if (s) s.status = "waiting"; return j; });
    rc.stubTranscript((j) => {
      const it = j.items[j.items.length - 1];
      if (it && it.role === "ask") j.items[j.items.length - 1] = Object.assign({}, it, { answered: false, answers: null, notes: null });
      return j;
    });
    const posts = rc.stubSend(() => "done", 100);
    await rc.wait("#list .ask.live .opt", 10000, "unanswered preview question card");
    await rc.sleep(800);
    const f = [];
    const L = rc.lang();
    const ph = { en: "Add a note…", hans: "附带备注…", hant: "附帶備註…" }[L];
    const box = rc.q("#list .ask.live");
    const opts = () => [...box.querySelectorAll(".opts > button.opt")];
    if (opts().length !== 2) f.push("wrong preview option count: " + opts().length);
    if (box.querySelector(".own-row:not(.note-row)")) f.push("preview question should not have a free-text row");
    if (box.querySelector(".o-nb") || box.querySelector(".note-sw")) f.push("should not have the add-note chip / note switch");
    const go = box.querySelector(".ask-go");
    const btn = go && go.querySelector("button.go");
    if (!go || go.hidden || !btn) f.push("submit button must always be visible");
    if (btn && !btn.disabled) f.push("submit button should be disabled with no option selected");
    const row = box.querySelector(".note-row");
    if (!row || row.hidden || getComputedStyle(row).display === "none") f.push("note row must always be visible");
    if (row && opts()[1].nextElementSibling !== row) f.push("note row is not at the end of the option group");
    const inp = row && row.querySelector("input");
    if (!inp || inp.placeholder !== ph) f.push("wrong note placeholder: " + (inp && inp.placeholder));
    opts()[0].click();
    await rc.sleep(200);
    if (posts.length) f.push("clicking an option must not send directly");
    if (!opts()[0].classList.contains("on")) f.push("clicking option 1 did not select it");
    if (btn.disabled) f.push("submit button should be enabled after selecting");
    if (${k} === 2) {
      opts()[1].click();
      await rc.sleep(200);
      if (posts.length) f.push("switching to option 2 must not send directly");
      if (!opts()[1].classList.contains("on") || opts()[0].classList.contains("on")) f.push("switching to option 2 had no effect");
    }
    const keep = row.parentNode;
    inp.value = "Fold the story by default.";
    inp.dispatchEvent(new Event("input", { bubbles: true }));
    if (!row.classList.contains("on")) f.push("note row not highlighted after typing a note");
    if (row.parentNode !== keep || !inp.isConnected) f.push("note row re-inserted into DOM while typing (loses focus)");
    if (${k} === 2) inp.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", bubbles: true }));
    else btn.click();
    await rc.wait(() => posts.length, 3000, "submit request");
    const want = ${k} === 1 ? ["2", "1"] : ["1", "2"];
    const exp = JSON.stringify([{ key: want[0] }, { key: want[1] }, { key: "n" }, { text: "Fold the story by default." }, { key: "enter" }]);
    if (JSON.stringify(posts[0].steps) !== exp) f.push("wrong steps sent: " + JSON.stringify(posts[0].steps));
    if (posts.length !== 1) f.push("should send exactly once: " + posts.length);
    return { fail: f };`;
// No image flicker: send an image -> clock / single tick / grey double tick -> transcript arrives -> read; throughout, the image in the bubble is the same <img> node, already loaded,
// and the thumbnail URL is requested at most once. stop: a = stop at delivered (grey double tick), b = stop at queued in the transcript (for burst shots); direct = idle session, the image is already read and attached when the transcript arrives
// The transcript is injected in its real shape: the queued entry (queue-operation enqueue) only has the text "[Image #1]" and no files; the final user row has read:true with files
const rc_imgflash = (stop, direct) => `
    await rc.wait("#list .cg", 8000, "chat");
    await rc.sleep(600);
    const f = [];
    let phase = 0;
    const iso = (d) => new Date(Date.now() + d).toISOString();
    const qts = iso(0), uts = iso(1000);
    const UPH = "/Users/demo/app/data/uploads/2026-01-01/";
    const queued = { role: "user", text: "[Image #1]", ts: qts, read: false, queued: true };
    const formal = { role: "user", text: "[Image #1]", ts: uts, read: true, files: [{ path: UPH + "photo.png", name: "photo.png", kind: "image", src: "upload" }] };
    rc.stubTranscript((j) => {
      if (phase === 1) j.items = j.items.concat([${direct ? "formal" : "queued"}]);
      if (phase >= 2) j.items = j.items.concat([formal]);
      if (phase >= 3) j.items = j.items.concat([{ role: "assistant", text: "Got the photo.", ts: iso(2000) }]);
      return j;
    });
    rc.stubSend(() => "done", 700);
    const cv = document.createElement("canvas"); cv.width = 200; cv.height = 150;
    const g = cv.getContext("2d"); g.fillStyle = "#5a9a5a"; g.fillRect(0, 0, 200, 150); g.fillStyle = "#fff"; g.fillRect(50, 40, 100, 70);
    const blob = await new Promise((r) => cv.toBlob(r, "image/png"));
    const dt = new DataTransfer(); dt.items.add(new File([blob], "flash-probe.png", { type: "image/png" }));
    const inp = rc.q("#in-photo"); inp.files = dt.files; inp.dispatchEvent(new Event("change", { bubbles: true }));
    await rc.wait(() => rc.qa("#tray .tray-it img").length === 1, 4000, "one image appears in attachment tray");
    rc.q("#btn-send").click();
    const pimg = await rc.wait(() => { const p = rc.q("#list .m.me.pend"); const c = p && p.closest(".cg"); const im = c && c.querySelector(".at-img img"); return im && im.complete && im.naturalWidth ? im : null; }, 4000, "local preview image in pending bubble");
    pimg.dataset.rcFlash = "1";
    const thumbs = () => performance.getEntriesByType("resource").filter((e) => /\\/api\\/file/.test(e.name) && /photo\\.png/.test(decodeURIComponent(e.name))).length;
    // Layout: the bubble frame size around the image and the image position inside the bubble must match the first measurement at every step; the page must not contain "[1 attachments]" or "[Image #"
    let base = null;
    const shape = (what) => {
      if (/\\[1 attachments\\]|\\[附件 ×1\\]|\\[Image #/.test(rc.q("#list").textContent)) f.push(what + ": page still shows a text placeholder: " + rc.q("#list").textContent.replace(/\\s+/g, " ").slice(-80));
      const bub = pimg.closest(".m");
      if (!bub) { f.push(what + ": image is not inside the bubble (attached outside it)"); return; }
      if (!bub.classList.contains("at-only")) f.push(what + ": image-only bubble lacks at-only style");
      const br = bub.getBoundingClientRect(), ir = pimg.closest(".at-img").getBoundingClientRect();
      const cur = [br.width, br.height, ir.left - br.left, ir.top - br.top].map((x) => Math.round(x));
      if (!base) base = cur;
      else if (cur.some((x, i) => Math.abs(x - base[i]) > 1)) f.push(what + ": bubble layout jumped [width,height,img left,img top] " + base.join(",") + " → " + cur.join(","));
    };
    const same = (what) => {
      shape(what);
      const all = rc.qa("#list .at-img img");
      if (!pimg.isConnected) f.push(what + ": original <img> is no longer on the page (recreated)");
      else if (!(pimg.complete && pimg.naturalWidth)) f.push(what + ": image not loaded (complete=" + pimg.complete + ")");
      if (all.length !== 1) f.push(what + ": page has " + all.length + " .at-img (expected 1)");
      const b = pimg.closest(".at-img");
      if (b && b.classList.contains("at-loading")) f.push(what + ": frame still has at-loading (grey flash)");
    };
    shape("clock");
    await rc.wait(() => rc.q("#list .m.me.pend .rc-mk.rc-sent, #list .m.me.pend .rc-mk.rc-delivered"), 8000, "single tick");
    same("single tick");
    await rc.wait("#list .m.me.pend .rc-mk.rc-delivered", 8000, "grey double tick");
    same("grey double tick");
    ${stop === "a" ? "return { fail: f };" : ""}
    phase = 1;
    await rc.wait(() => !rc.q("#list .m.me.pend") && rc.qa("#list .m.me").length >= 3, 6000, "transcript record arrived (pending bubble leaves)");
    await rc.sleep(300);
    same("record arrived");
    ${direct ? "" : `const qb = pimg.closest(".cg") && pimg.closest(".cg").querySelector(".m.me .rc-mk.rc-delivered");
    if (!qb) f.push("queued: image not attached under the queued (grey double tick) bubble");
    const qm = pimg.closest(".cg") && pimg.closest(".cg").querySelector(".m.me");
    if (qm && /\\[Image #1\\]/.test(qm.textContent)) f.push("queued: bubble still contains [Image #1]");`}
    ${stop === "b" ? "return { fail: f };" : ""}
    if (!${direct ? "true" : "false"}) {
      phase = 2;
      await rc.wait(() => { const c = pimg.closest(".cg"); return c && c.querySelector(".rc-mk.rc-read"); }, 6000, "read (the real record)");
      await rc.sleep(300);
      same("read");
    } else {
      phase = 2;
      if (!(pimg.closest(".cg") && pimg.closest(".cg").querySelector(".rc-mk.rc-read"))) f.push("direct: not read when record arrived");
    }
    const b = pimg.closest(".at-img");
    if (!b || !b.dataset.f || !/photo\\.png/.test(b.dataset.f)) f.push("image in record not swapped to real file (cannot open): data-f=" + (b && b.dataset.f));
    phase = 3;
    await rc.wait(() => /Got the photo/.test(rc.q("#list").textContent), 6000, "re-render everything once more");
    await rc.sleep(300);
    same("re-render");
    const n = thumbs();
    if (n > 1) f.push("photo.png thumbnail requested " + n + " times (expected <=1)");
    return { fail: f };`;
// Images sent by others (already in the transcript): after a full redraw (new message arrived) the <img> nodes are the same ones and are not re-requested
const rc_imgstable = `
    await rc.wait(() => rc.qa("#list .at-img img").length >= 3 && rc.qa("#list .at-img img").every((i) => i.complete), 8000, "images in record loaded");
    await rc.sleep(800);
    const f = [];
    const before = rc.qa("#list img").filter((i) => i.closest(".at-img"));
    const req0 = performance.getEntriesByType("resource").filter((e) => /\\/api\\/file/.test(e.name)).length;
    let on = false;
    rc.stubTranscript((j) => { if (on) j.items = j.items.concat([{ role: "assistant", text: "One more line to force a rebuild.", ts: new Date().toISOString() }]); return j; });
    on = true;
    await rc.wait(() => /force a rebuild/.test(rc.q("#list").textContent), 6000, "full re-render");
    await rc.sleep(800);
    const gone = before.filter((i) => !i.isConnected).length;
    if (gone) f.push(gone + "/" + before.length + " images had <img> recreated (full re-render did not reuse them)");
    const req1 = performance.getEntriesByType("resource").filter((e) => /\\/api\\/file/.test(e.name)).length;
    if (req1 !== req0) f.push("after full re-render, /api/file requested an extra " + (req1 - req0) + " times");
    return { fail: f };`;
const SCEN = [
  { name: "imgflash", tab: "msg", path: () => "/#s/" + IDS.rcpt, run: rc_imgflash("", false) },
  { name: "imgflash-direct", tab: "msg", path: () => "/#s/" + IDS.rcpt, run: rc_imgflash("", true) },
  { name: "imgflash-1sent", tab: "msg", langs: ["en"], path: () => "/#s/" + IDS.rcpt, run: rc_imgflash("a", false) },
  { name: "imgflash-2queued", tab: "msg", langs: ["en"], path: () => "/#s/" + IDS.rcpt, run: rc_imgflash("b", false) },
  { name: "img-stable", tab: "msg", path: () => "/#s/" + IDS.chat, run: rc_imgstable },
  { name: "list", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs li", 6000, "message list");
    const n = rc.qa("#cr-msgs li").length;
    const f = n >= 4 ? [] : ["list has only " + n + " rows"];
    // Top row (390 wide): the Orca status must not be truncated by an ellipsis, and the quota countdown must still show (full or shortened form)
    await rc.wait(() => rc.q("#cr-quota .cr-q"), 4000, "top-row quota");
    const mt = rc.q("#cr-mac-t");
    if (!/Orca/.test(mt.textContent)) f.push("top row has no Orca status: " + mt.textContent);
    if (mt.scrollWidth > mt.clientWidth + 1) f.push("top row '" + mt.textContent + "' truncated (" + mt.scrollWidth + ">" + mt.clientWidth + ")");
    const qt = rc.qa("#cr-quota .cr-qt").filter((e) => e.offsetWidth > 0).length;
    if (qt !== rc.qa("#cr-quota .cr-q").length) f.push("top row shows " + qt + " countdowns (expected one per quota)");
    return { fail: f };` },
  { name: "chat", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "chat bubbles");
    await rc.sleep(1200);
    const f = [];
    const need = { "table": "#list .md table", "code block": "#list .md pre code", "quote": "#list .md blockquote",
      "list": "#list .md ol li", "image": "#list .at-img", "file card/chip": "#list [data-f][data-kind=md]",
      "PDF card/chip": "#list [data-f][data-kind=pdf]", "filename chip": "#list .at-chip", "tool chip": "#list .tg, #list [class*=tool]",
      "sub-agent bubble": "#list .ag-flip", "cross-session message": "#list .m-pr" };
    for (const [k, s] of Object.entries(need)) if (!rc.q(s)) f.push("missing " + k + " (" + s + ")");
    const tbls = rc.qa("#list .md table").length;
    if (tbls < 2) f.push("only " + tbls + " tables rendered (expected >=2: one in reply, one in sub-agent report)");
    const msgs = rc.q("#msgs"); msgs.scrollTop = 0; await rc.sleep(300); msgs.scrollTop = msgs.scrollHeight; await rc.sleep(300);
    return { fail: f };` },
  { name: "reader-md", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list [data-f][data-kind=md]", 8000, "md attachment card");
    rc.cardByName("guide-tables.md").click();
    await rc.wait(() => rc.q("#fs-body .at-read, #fs-body .at-note:not(:empty)") && !rc.loadingNote(), 6000, "reader page");
    const f = [];
    const n = rc.qa("#fs-body .at-md table").length;
    if (n < 5) f.push("reader page tables: " + n + " (expected 5)");
    if (!rc.q("#fs-body .at-md pre code")) f.push("reader page missing code block");
    return { fail: f };` },
  { name: "reader-extra", tab: "msg", needMd: true, path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list [data-f][data-kind=md]", 8000, "md attachment card");
    rc.cardByName(${JSON.stringify(MD ? MD.split("/").pop() : "")}).click();
    await rc.wait(() => rc.q("#fs-body .at-read, #fs-body .at-note:not(:empty)") && !rc.loadingNote(), 6000, "reader page");
    return { fail: rc.q("#fs-body .at-md") ? [] : ["reader page did not render Markdown: " + rc.q("#fs-body").innerText.slice(0, 80)] };` },
  ...[["txt", "notes.txt", "text"], ["csv", "data.csv", "data"], ["json", "config.json", "data"]].map(([k, nm]) => ({
    name: "reader-" + k, tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list [data-f][data-kind=text]", 8000, "attachment");
    rc.cardByName(${JSON.stringify(nm)}).click();
    await rc.wait(() => rc.q("#fs-body .at-read, #fs-body .at-note:not(:empty)") && !rc.loadingNote(), 6000, "reader page");
    const pre = rc.q("#fs-body pre.at-pre");
    return { fail: pre && pre.textContent.length > 20 ? [] : ["plain-text reader page is empty"] };` })),
  { name: "html", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list [data-f][data-kind=html]", 8000, "web attachment");
    rc.q("#list [data-f][data-kind=html]").click();
    await rc.wait("#fs-body iframe.at-frame", 4000, "sandbox page");
    await rc.sleep(800);
    const fr = rc.q("#fs-body iframe.at-frame");
    return { fail: fr.getAttribute("sandbox") === "allow-scripts" ? [] : ["wrong iframe sandbox: " + fr.getAttribute("sandbox")] };` },
  { name: "viewer-single", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait(() => rc.qa("#list .at-img img").some((i) => i.complete && i.naturalWidth), 8000, "thumbnail loaded");
    rc.imgByName("wide.png").click();
    await rc.wait(() => { const v = rc.q("#vw"); return v && !v.hidden && getComputedStyle(v).display !== "none"; }, 4000, "image viewer");
    await rc.sleep(800);
    return { fail: [] };` },
  { name: "viewer-multi", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait(() => rc.imgByName("a.png"), 8000, "image grid");
    rc.imgByName("a.png").click();
    await rc.wait(() => { const v = rc.q("#vw"); return v && !v.hidden && getComputedStyle(v).display !== "none"; }, 4000, "image viewer");
    for (const k of ["ArrowRight", "ArrowRight", "ArrowLeft"]) { document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true })); await rc.sleep(300); }
    return { fail: [] };` },
  { name: "agent", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .ag-flip", 8000, "sub-agent bubble");
    const w = rc.q("#list .ag-flip"); w.click();
    await rc.wait(() => w.classList.contains("on"), 3000, "flipped to back");
    await rc.sleep(700);
    w.querySelector(".ag-card").click();
    await rc.wait(() => rc.q("#detail.ag-view") && rc.q("#list .cg"), 6000, "sub-agent page");
    await rc.sleep(800);
    return { fail: rc.q("#list .md table") ? [] : ["sub-agent page table not rendered"] };` },
  { name: "agent-running", tab: "msg", path: () => "/#s/" + IDS.busy, run: `
    await rc.wait("#list .ag-flip", 8000, "running sub-agent bubble");
    await rc.sleep(1500);
    return { fail: [] };` },
  { name: "approve", tab: "msg", path: () => "/#s/" + IDS.approve, run: `
    await rc.wait("#list .approve", 8000, "approval card");
    return { fail: rc.qa("#list .approve button").length >= 2 ? [] : ["approval card has no buttons"] };` },
  { name: "ask", tab: "msg", path: () => "/#s/" + IDS.ask, run: `
    await rc.wait("#list .ask", 8000, "question card");
    return { fail: rc.qa("#list .ask button").length >= 2 ? [] : ["question card has no option buttons"] };` },
  // A question with previews + notes was answered (toolUseResult.annotations) but the session state is still waiting: the card must use the answered style and show the option and note, not the "asking you" style again
  { name: "ask-notes", tab: "msg", path: () => "/#s/" + IDS.notes, run: `
    const sid = decodeURIComponent(location.hash.slice(3));
    rc.stubSnap((j) => { const s = j.sessions.find((x) => x.id === sid); if (s) s.status = "waiting"; return j; });
    await rc.wait("#list .ask", 8000, "question card");
    await rc.sleep(2500); // wait for the snapshot to stub the state to waiting and the chat page to redraw
    const f = [];
    const box = rc.q("#list .ask");
    if (!box.classList.contains("done")) f.push("answered question card lacks answered style: " + box.className);
    if (box.classList.contains("live") || rc.qa("#list .ask button").length) f.push("answered question card still asking (has option buttons)");
    const lb = { en: "Answered", hans: "已回答", hant: "已回答" }[rc.lang()];
    const head = box.querySelector(".lb");
    if (!head || head.textContent !== lb) f.push("card header is not the localized 'Answered': " + (head && head.textContent));
    const tag = box.querySelector(".a-tag"), nt = box.querySelector(".a-nt");
    if (!tag || tag.textContent !== "Story first") f.push("selected option not shown: " + (tag && tag.textContent));
    const pre = { en: "Note: ", hans: "备注：", hant: "備註：" }[rc.lang()];
    if (!nt || nt.textContent !== pre + "Fold the story by default.") f.push("note not shown: " + (nt && nt.textContent));
    if (/GIF/.test(box.textContent)) f.push("preview raw text should not appear in the card");
    return { fail: f };` },
  // Preview question: stub the answered ask-notes question as unanswered + waiting. Tapping option 1 only selects it and the note row is always shown; writing a note and submitting sends [2, 1, n, note, Enter]
  { name: "ask-preview-note1", tab: "msg", path: () => "/#s/" + IDS.notes, run: rc_previewNote(1) },
  // Same as above, but tap option 1 first and then option 2 (only moves the selection, nothing is sent); Enter in the note box sends [1, 2, n, note, Enter]
  { name: "ask-preview-note2", tab: "msg", langs: ["en"], path: () => "/#s/" + IDS.notes, run: rc_previewNote(2) },
  // The session goes from busy to waiting, and the approval card in the transcript (pending tool_use) is written 1.2 s later:
  // the page refetches 0.5 s after a state change and polls every 1 s while busy/waiting, so the card should appear within 2 s
  { name: "wait-card-late", tab: "msg", langs: ["en"], path: () => "/#s/" + IDS.approve, run: `
    await rc.wait("#list .approve", 8000, "approval card (initial)");
    const sid = decodeURIComponent(location.hash.slice(3));
    let flip = false, W = 0;
    rc.stubSnap((j) => {
      const s = j.sessions.find((x) => x.id === sid);
      if (s) { s.status = flip ? "waiting" : "busy"; if (flip && !W) W = performance.now(); }
      return j;
    });
    rc.stubTranscript((j) => {
      if (!flip || !W || performance.now() - W < 1200) j.items = j.items.filter((it) => !it.pending);
      return j;
    });
    await rc.wait(() => !rc.q("#list .approve"), 8000, "approval card disappears with busy");
    await rc.sleep(1500);
    flip = true;
    await rc.wait(() => W, 6000, "snapshot brings waiting");
    await rc.wait("#list .approve", 8000, "approval card (appears 1.2 s late)");
    const dt = Math.round(performance.now() - W);
    console.warn("RC_WAIT_CARD_MS " + dt);
    return { fail: dt <= 2000 ? [] : ["approval card appeared after " + dt + " ms (expected <= 2000)"] };` },
  { name: "chat-peer", tab: "msg", path: () => "/#s/" + IDS.peer, run: `
    await rc.wait("#list .cg", 8000, "cross-session message chat");
    const n = rc.qa("#list .m-pr").length;
    return { fail: n >= 2 ? [] : ["cross-session messages drawn: " + n + " (expected 2)"] };` },
  { name: "offduty", tab: "msg", path: () => "/#o/" + IDS.off, run: `
    await rc.wait("#list .md table", 8000, "off-duty session transcript");
    return { fail: [] };` },
  { name: "chat-info", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "chat");
    rc.click("#d-more");
    await rc.wait(() => !rc.q("#fs").hidden && rc.q("#fs-body").children.length, 3000, "chat info page");
    await rc.sleep(500);
    const find = [...rc.qa("#fs-body button, #fs-body [role=button], #fs-body .ci-row, #fs-body li")].find((b) => b.onclick);
    if (find) { find.click(); await rc.sleep(800); }
    return { fail: [] };` },
  { name: "chat-search", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "chat");
    rc.click("#d-more");
    await rc.wait(() => !rc.q("#fs").hidden, 3000, "chat info page");
    await rc.sleep(400);
    const btn = [...rc.qa("#fs-body *")].find((e) => e.onclick && /查找|Search|搜尋|Find/.test(e.textContent || ""));
    if (!btn) return { fail: ["chat info page has no search-chat entry"] };
    btn.click();
    const inp = await rc.wait(() => rc.q("#fs-body input"), 3000, "search input");
    inp.value = "summary"; inp.dispatchEvent(new Event("input", { bubbles: true }));
    await rc.sleep(1500);
    return { fail: [] };` },
  { name: "search", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs li", 6000, "message list");
    const q = rc.q("#cr-q"); q.focus(); q.value = "style"; q.dispatchEvent(new Event("input", { bubbles: true }));
    await rc.wait(() => rc.q("#cr-sout .gs-row"), 6000, "global search results");
    rc.q("#cr-sout .gs-row").click();
    await rc.sleep(2000);
    return { fail: [] };` },
  // No pets installed (serve.py makes /pets/ always 404): list avatars and chat bubble avatars are all the soulflame image, not initials
  { name: "flame-avatar", tab: "msg", path: () => "/", run: `
    await rc.wait(() => rc.q("#cr-msgs li .cr-av .pet.pet-flame"), 6000, "soulflame avatars in list");
    const f = [];
    const rows = rc.qa("#cr-msgs li .cr-av");
    const bad = rows.filter((av) => { const p = av.querySelector(".pet"); return !p || p.hidden || !/mascot-av-(idle|busy|wait|done|rest)\\.png/.test(getComputedStyle(p).backgroundImage); });
    if (bad.length) f.push(bad.length + "/" + rows.length + " list avatars are not soulflame");
    const ini = rows.filter((av) => { const i = av.querySelector(".cr-ini"); return i && !i.hidden; });
    if (ini.length) f.push(ini.length + " list avatars still show an initial");
    const imgs = [...new Set(rows.map((av) => getComputedStyle(av.querySelector(".pet")).backgroundImage.replace(/^url\\("?|"?\\)$/g, "")))];
    for (const u of imgs) { const im = new Image(); im.src = u; try { await im.decode(); } catch (e) { f.push("soulflame image failed to load: " + u); } }
    rc.q("#cr-msgs li .cr-row").click();
    const cav = await rc.wait(() => rc.q("#list .cav-ag .cav-pet.pet-flame"), 8000, "soulflame avatar on chat page");
    if (!/mascot-av-/.test(getComputedStyle(cav).backgroundImage)) f.push("chat page avatar is not soulflame");
    if (!/mascot-av-/.test(getComputedStyle(rc.q("#d-pet")).backgroundImage)) f.push("chat page top-bar avatar is not soulflame");
    return { fail: f };` },
  { name: "contacts", tab: "contacts", path: () => "/", run: `await rc.sleep(2500); return { fail: [] };` },
  { name: "zones", tab: "zones", path: () => "/", run: `
    const z = await rc.wait('#p-zones [data-zone="Web"]', 6000, "zone card on board page");
    z.click();
    await rc.wait("#fs-body .tb-md, #fs-body .tb-load", 4000, "zone task board");
    await rc.wait(() => !rc.q("#fs-body .tb-load"), 4000, "task board loaded");
    return { fail: rc.q("#fs-body .tb-md table") ? [] : ["task board table not rendered: " + rc.q("#fs-body").innerText.slice(0, 60)] };` },
  // When the Mac is disconnected (snapshot 40 s old, stale), every card on the board page shows an "as of hh:mm" suffix after its number
  { name: "board-asof", tab: "zones", path: () => "/", run: `
    await rc.wait("#p-zones .zc", 6000, "zone card on board page");
    let gen0 = 0;
    rc.stubSnap((j) => { gen0 = gen0 || j.serverNow - 40; j.generatedAt = gen0; j.stale = true; j.down = { reason: "helper", at: gen0 }; return j; });
    await rc.wait("#p-zones .zc .zc-asof", 8000, "board page disconnected suffix");
    const f = [];
    const d = new Date(gen0 * 1000);
    const hm = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
    const want = { en: " (as of " + hm + ")", hans: "（截至 " + hm + "）", hant: "（截至 " + hm + "）" }[rc.lang()];
    const cards = rc.qa("#p-zones .zc"), sfx = rc.qa("#p-zones .zc .zc-asof");
    if (cards.length !== sfx.length) f.push("cards: " + cards.length + ", suffixes: " + sfx.length + "");
    for (const e of sfx) if (e.textContent !== want) f.push("suffix '" + e.textContent + "' should be '" + want + "'");
    return { fail: f };` },
  { name: "me", tab: "me", path: () => "/", run: `
    await rc.wait("#cr-me *", 6000, "Me page");
    await rc.sleep(1200);
    return { fail: [] };` },
  { name: "monitor", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs li", 6000, "message list");
    rc.click("#cr-mac");
    await rc.sleep(1500);
    return { fail: [] };` },
  { name: "office-download", tab: "msg", wide: true, path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list [data-f][data-kind=sheet]", 8000, "xlsx attachment card");
    const f = [];
    if (!matchMedia("(hover: hover) and (pointer: fine)").matches) f.push("wide-screen scenario is not a desktop pointer");
    const clicks = [], opens = [];
    const oc = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () { clicks.push({ href: this.href, dl: this.hasAttribute("download") }); };
    window.open = (...a) => { opens.push(a[0]); return null; };
    rc.cardByName("示例报表2026.xlsx").click();
    await rc.sleep(300);
    HTMLAnchorElement.prototype.click = oc;
    if (opens.length) f.push("clicking xlsx card on desktop still opened a new tab: " + opens[0]);
    if (clicks.length !== 1 || !clicks[0].dl || !/[?&]dl=1(&|$)/.test(clicks[0].href)) f.push("clicking xlsx card on desktop did not trigger a dl=1 download: " + JSON.stringify(clicks));
    else {
      const r = await fetch(clicks[0].href, { credentials: "same-origin" });
      const cd = r.headers.get("content-disposition") || "";
      if (r.status !== 200 || !cd.startsWith("attachment;") || !cd.includes("filename*=UTF-8''" + encodeURIComponent("示例报表2026.xlsx"))) f.push("wrong download response headers: " + r.status + " " + cd);
    }
    return { fail: f };` },
  { name: "office-phone", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    // Tapping an xlsx on a phone does not open a new tab (it would be a black screen in the home-screen app): fetch the file in-page -> system share sheet; if sharing is unavailable fall back to an invisible dl=1 download
    await rc.wait("#list [data-f][data-kind=sheet]", 8000, "xlsx attachment card");
    const f = [];
    if (matchMedia("(hover: hover) and (pointer: fine)").matches) f.push("phone scenario treated as desktop pointer");
    const opens = [], shares = [], clicks = [];
    window.open = (...a) => { opens.push(a); return null; };
    navigator.canShare = () => true;
    navigator.share = async (d) => { shares.push(d); };
    rc.cardByName("示例报表2026.xlsx").click();
    for (let i = 0; i < 30 && !shares.length; i++) await rc.sleep(100);
    if (opens.length) f.push("clicking xlsx card on phone still opened a new tab: " + JSON.stringify(opens));
    const sf = shares[0] && shares[0].files && shares[0].files[0];
    if (!sf) f.push("clicking xlsx card on phone did not open share sheet");
    else if (sf.name !== "示例报表2026.xlsx" || !(sf.size > 0)) f.push("wrong shared file: " + sf.name + " " + sf.size);
    // Sharing unavailable -> invisible download (with dl=1), still no new tab
    navigator.canShare = () => false;
    const oc = HTMLAnchorElement.prototype.click;
    HTMLAnchorElement.prototype.click = function () { clicks.push({ href: this.href, dl: this.hasAttribute("download") }); };
    rc.cardByName("示例报表2026.xlsx").click();
    for (let i = 0; i < 30 && !clicks.length; i++) await rc.sleep(100);
    HTMLAnchorElement.prototype.click = oc;
    if (opens.length) f.push("new tab opened when share unavailable");
    if (clicks.length !== 1 || !clicks[0].dl || !/[?&]dl=1(&|$)/.test(clicks[0].href)) f.push("did not fall back to dl=1 download when share unavailable: " + JSON.stringify(clicks));
    return { fail: f };` },
  { name: "desktop-chat", tab: "msg", wide: true, path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .md table", 8000, "wide-screen chat table");
    await rc.sleep(1000);
    return { fail: [] };` },
  { name: "guest-chat", account: "guest", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "guest chat");
    await rc.sleep(1000);
    return { fail: rc.q("#list .md table") ? [] : ["guest chat table not rendered"] };` },
  { name: "guest-reader", account: "guest", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list [data-f][data-kind=md]", 8000, "md uploaded by the guest");
    rc.cardByName("memo.md").click();
    await rc.wait(() => rc.q("#fs-body .at-read, #fs-body .at-note:not(:empty)") && !rc.loadingNote(), 6000, "reader page");
    return { fail: rc.q("#fs-body .at-md table") ? [] : ["guest reader page table not rendered"] };` },
  { name: "guest-viewer", account: "guest", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait(() => rc.imgByName("photo.png") && rc.imgByName("photo.png").querySelector("img").naturalWidth, 8000, "guest-uploaded image thumbnail");
    rc.imgByName("photo.png").click();
    await rc.wait(() => { const v = rc.q("#vw"); return v && !v.hidden && getComputedStyle(v).display !== "none"; }, 4000, "image viewer");
    await rc.sleep(800);
    return { fail: [] };` },
  { name: "guest-me", account: "guest", tab: "me", path: () => "/", run: `await rc.sleep(2500); return { fail: [] };` },
  { name: "image-name", tab: "msg", expectGone: true, path: () => "/#s/" + IDS.img, run: `
    await rc.wait(() => rc.q("#list .at-gone") && rc.qa("#list .at-img img").some((i) => i.complete && i.naturalWidth), 8000, "inline images (one broken, one good)");
    const w = { en: "Image", hans: "图片", hant: "圖片" }[rc.lang()];
    const f = [];
    const gone = rc.q("#list .at-gone").textContent;
    if (!gone.endsWith(" · " + w + " 1")) f.push("wrong broken-image hint: " + gone);
    const alts = rc.qa("#list .at-img img").map((i) => i.alt);
    if (!alts.includes(w + " 2")) f.push("wrong thumbnail alt: " + alts.join(","));
    const d = rc.qa("#list .at-img[data-f]").map((b) => JSON.parse(b.dataset.f).n);
    if (!d.includes(2)) f.push("attachment data missing index n: " + JSON.stringify(d));
    return { fail: f };` },
  // Five receipt states: read in the transcript (blue double tick) / queued (grey double tick) + sending stages produced by stubbing fetch in the page --
  // 1st POST 500 = red !; 2nd got a requestId and was typed into the terminal = grey double tick; 3rd got a requestId but is not typed in yet = grey single tick; 4th queued behind it = clock
  { name: "receipts", tab: "msg", path: () => "/#s/" + IDS.rcpt, run: `
    await rc.wait(() => rc.q("#list .rc-mk.rc-read") && rc.q("#list .rc-mk.rc-delivered"), 8000, "read / queued receipts in record");
    const f = [];
    const plan = { "Can you also rerun the flaky test?": "fail", "Ship it after lunch.": "done", "Ping me when CI is green.": "wait" };
    rc.stubSend((tx) => plan[tx] || "wait");
    const pend = () => rc.qa("#list .m.me.pend");
    await rc.send("Can you also rerun the flaky test?");
    await rc.wait("#list .m.me.pend .rc-mk.rc-failed", 6000, "red !");
    await rc.send("Ship it after lunch.");
    await rc.wait(() => pend().length === 2 && pend()[1].querySelector(".rc-mk.rc-delivered"), 6000, "grey double tick (typed into terminal)");
    await rc.send("Ping me when CI is green.");
    await rc.wait(() => pend().length === 3 && pend()[2].querySelector(".rc-mk.rc-sent"), 6000, "grey single tick (server received)");
    await rc.send("And post the summary.");
    await rc.wait(() => pend().length === 4 && pend()[3].querySelector(".rc-mk.rc-clock"), 4000, "clock (queued)");
    await rc.sleep(600);
    for (const k of ["clock", "sent", "delivered", "read", "failed"]) {
      const m = rc.q("#list .rc-mk.rc-" + k);
      if (!m) { f.push("missing receipt " + k); continue; }
      if (!m.getAttribute("aria-label")) f.push("receipt " + k + " has no screen-reader text");
      if (!m.querySelector(".rc-ic svg")) f.push("receipt " + k + " has no icon");
    }
    await rc.wait(() => !rc.q("#toast.show"), 6000, "red ! toast gone (clean screenshot)");
    return { fail: f };` },
  // No blue send button at the end of the attachment bar: with one image #tray holds only that image's delete ✕, sending goes through the keyboard's send key
  { name: "tray-no-send", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "chat");
    const cv = document.createElement("canvas"); cv.width = 120; cv.height = 90;
    const g = cv.getContext("2d"); g.fillStyle = "#4a90d9"; g.fillRect(0, 0, 120, 90); g.fillStyle = "#fff"; g.fillRect(30, 20, 60, 50);
    const blob = await new Promise((r) => cv.toBlob(r, "image/png"));
    const dt = new DataTransfer(); dt.items.add(new File([blob], "tray-probe.png", { type: "image/png" }));
    const inp = rc.q("#in-photo"); inp.files = dt.files; inp.dispatchEvent(new Event("change", { bubbles: true }));
    await rc.wait(() => rc.qa("#tray .tray-it img").length === 1 && !rc.q("#tray").hidden, 4000, "one image appears in attachment tray");
    await rc.sleep(300);
    const f = [];
    if (rc.q(".tray-send")) f.push("still has .tray-send send button");
    const bs = rc.qa("#tray button");
    const bad = bs.filter((b) => !b.classList.contains("tray-x"));
    if (bad.length) f.push("attachment tray has buttons besides delete ✕: " + bad.map((b) => b.className + "/" + b.textContent).join(","));
    if (bs.length !== 1) f.push("attachment tray button count: " + bs.length + " (expected only 1 ✕)");
    return { fail: f };` },
  { name: "send-burst", tab: "msg", path: () => "/#s/" + IDS.chat, run: rc_burst },
  { name: "guest-send-burst", account: "guest", tab: "msg", path: () => "/#s/" + IDS.chat, run: rc_burst },
  { name: "guest-err", account: "guest", tab: "msg", allowErr: "rc.guest-probe", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "guest chat");
    const sent = [];
    const of = window.fetch;
    window.fetch = function (u, o) { if (String(u).includes("/api/diag")) sent.push(o && o.body); return of.apply(this, arguments); };
    dispatchEvent(new CustomEvent("sg-err", { detail: { where: "rc.guest-probe", err: new TypeError("render-check probe " + rc.lang()) } }));
    await rc.wait(() => sent.length, 3000, "guest error report request");
    await rc.sleep(500);
    const ev = (JSON.parse(sent[0]).events || [])[0] || {};
    return { fail: ev.k === "err" && ev.where === "rc.guest-probe" ? [] : ["wrong report content: " + String(sent[0]).slice(0, 200)] };` },
  // ===== multiple guests =====
  // Second guest (guest2, bound to Web-receipts): the list has only its own row and does not show the first guest's Web-render-demo; other sessions return 403 and the first guest's avatar and nickname cannot be fetched
  { name: "guest2-own-only", account: "guest2", tab: "msg", path: () => "/", run: () => `
    await rc.wait("#cr-msgs .cr-row", 8000, "second guest's session row");
    await rc.sleep(800);
    const f = [];
    const rows = rc.qa("#cr-msgs .cr-row");
    if (rows.length !== 1) f.push("second guest sees " + rows.length + " rows (expected only their own 1 row)");
    const txt = rc.q("#cr-msgs").textContent;
    if (!txt.includes("receipts")) f.push("own session Web-receipts not seen: " + txt.slice(0, 120));
    if (txt.includes("render-demo")) f.push("first guest's session appears in the list");
    const me = await (await fetch("/api/auth/me")).json();
    if (me.account !== "guest2" || me.session !== "Web-receipts" || me.tag !== "[GB]" || me.guests) f.push("wrong identity: " + JSON.stringify(me));
    const snap = await (await fetch("/api/snapshot")).json();
    if (JSON.stringify(snap).includes("Web-render-demo")) f.push("snapshot (incl. roster) contains first guest's session name");
    for (const id of ${JSON.stringify([IDS.chat, IDS.approve])}) {
      const r = await fetch("/api/sessions/" + id + "/transcript");
      if (r.status !== 403) f.push("fetching another session's transcript was not rejected: " + r.status);
    }
    const ok = await fetch("/api/sessions/${IDS.rcpt}/transcript");
    if (ok.status !== 200) f.push("cannot fetch own session transcript: " + ok.status);
    const p = await (await fetch("/api/profile?account=guest")).json();
    if (p.default !== "GB Demo") f.push("profile is not their own: " + JSON.stringify(p));
    return { fail: f };` },
  // Second guest sends slash commands: /model is blocked (message in three languages, text stays in the input box, nothing sent, no bubble drawn); /window is sent as usual (no prefix); normal text gets [GB]
  { name: "guest2-slash", account: "guest2", tab: "msg", path: () => "/#s/" + IDS.rcpt, run: `
    await rc.wait("#list .cg", 8000, "second guest chat");
    await rc.sleep(800);
    const f = [];
    const posts = rc.stubSend(() => "done", 100);
    const want = { en: "This command can only be entered on the Mac", hans: "这个命令只能在 Mac 上输入", hant: "這個命令只能在 Mac 上輸入" }[rc.lang()];
    const n0 = rc.qa("#list .m.me.pend").length;
    await rc.send("/model opus");
    await rc.sleep(200);
    const tst = rc.q("#toast.show");
    if (!tst || tst.textContent !== want) f.push("wrong toast: " + (tst ? tst.textContent : "none shown"));
    if (rc.q("#reply").value !== "/model opus") f.push("text did not stay in input: " + JSON.stringify(rc.q("#reply").value));
    if (posts.length) f.push("blocked command was sent: " + JSON.stringify(posts));
    if (rc.qa("#list .m.me.pend").length !== n0) f.push("blocked command drew a pending bubble");
    await rc.send("/window");
    await rc.wait(() => posts.length === 1, 3000, "/window sent");
    if (posts[0].text !== "/window") f.push("wrong /window payload: " + JSON.stringify(posts[0]));
    await rc.send("你好");
    await rc.wait(() => posts.length === 2, 3000, "normal message sent");
    const pend = rc.qa("#list .m.me.pend");
    if (!pend.length || /\[GB\]/.test(pend[pend.length - 1].textContent)) f.push("pending bubble kept the prefix or was not drawn");
    return { fail: f };` },
  // Admin views the second guest's session: text with [GB] counts as a guest bubble (prefix stripped), using the second guest's nickname
  { name: "admin-guest2-bubble", tab: "msg", path: () => "/#s/" + IDS.rcpt, run: `
    await rc.wait("#list .cg", 8000, "chat");
    rc.stubTranscript((j) => { // append a line spoken by the second guest to the transcript (gen.py's receipt sample stays untouched so the imgflash scenario is unaffected)
      const u = (j.items || []).filter((x) => x.role === "user").pop();
      if (u) j.items.push(Object.assign({}, u, { text: "[GB] hello from the second guest", ts: new Date().toISOString(), read: true, files: undefined }));
      return j;
    });
    await rc.wait(() => rc.q("#list .cg.gst"), 8000, "second guest's bubble");
    await rc.sleep(800);
    const f = [];
    const g = rc.qa("#list .cg.gst");
    if (!g.length) f.push("[GB] message not shown as guest bubble");
    else {
      const t = g[0].textContent;
      if (!t.includes("GB Demo")) f.push("guest bubble nickname is not the second guest's: " + t.slice(0, 80));
      if (t.includes("[GB]")) f.push("guest bubble kept the prefix");
    }
    return { fail: f };` },
  // ===== status expressions =====
  // Waiting-for-you urgent shake A knock: the animation is on .cr-clip (cr-knock, 3 s); rows with a red dot or the "has something to say" tag do not shake; before the screenshot the shake is frozen around the -6 degree frame
  { name: "nudge", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-row.w", 6000, "waiting-for-you rows");
    await rc.sleep(400);
    const f = [];
    const ws = rc.qa("#cr-msgs .cr-row.w");
    if (ws.length < 2) f.push("waiting-for-you has only " + ws.length + " rows");
    for (const r of ws) {
      const clip = r.querySelector(".cr-av > .cr-clip");
      const cs = getComputedStyle(clip);
      if (cs.animationName !== "cr-knock") f.push("waiting-for-you avatar animation is " + cs.animationName);
      if (cs.animationDuration !== "3s") f.push("urgent-shake period " + cs.animationDuration);
      const dot = r.querySelector(".cr-dot");
      if (!dot || dot.hidden) f.push("waiting-for-you row has no red dot");
      else if (getComputedStyle(dot).animationName !== "none") f.push("red dot animates too");
    }
    const ds = new Set(ws.map((r) => r.querySelector(".cr-av").style.getPropertyValue("--nd")));
    if (ws.length > 1 && ds.size < 2) f.push("shakes are not staggered (--nd all equal)");
    for (const r of rc.qa("#cr-msgs .cr-row:not(.w)")) {
      const n = getComputedStyle(r.querySelector(".cr-av > .cr-clip")).animationName;
      if (n === "cr-knock") f.push("non-waiting row also shakes");
    }
    for (const r of ws) for (const a of r.querySelector(".cr-av > .cr-clip").getAnimations()) {
      a.pause(); const d = a.effect.getTiming().delay || 0; a.currentTime = ((90 + d) % 3000 + 3000) % 3000;
    }
    return { fail: f };` },
  // Avatar of a waiting-for-you row is still (knock only): the pet frame animation stays on frame 0 while busy rows keep playing frames.
  // Test data has no pets (the avatar is a single soulflame image), so a pet node with the same structure as setPet (.pet[data-n=6], frames on its ::before) and a flame layer are put into the row to check the CSS directly.
  { name: "wait-still", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-row.w", 6000, "waiting-for-you rows");
    await rc.sleep(400);
    const f = [];
    const mk = (cls, host) => { const d = document.createElement("div"); d.className = cls; d.dataset.n = "6"; d.dataset.rc = "1"; host.append(d); return d; };
    const w = rc.q("#cr-msgs .cr-row.w");
    const g = rc.q("#cr-msgs .cr-row.g");
    if (!g) f.push("no working row");
    const wp = mk("pet", w.querySelector(".cr-clip"));
    const wf = mk("fx-fire fx-fire-w", w.querySelector(".cr-av"));
    const gp = g ? mk("pet", g.querySelector(".cr-clip")) : null;
    await rc.sleep(100);
    const clip = getComputedStyle(w.querySelector(".cr-av > .cr-clip"));
    if (clip.animationName !== "cr-knock") f.push("waiting-for-you knock gone: " + clip.animationName);
    const a = getComputedStyle(wp, "::before"); // frames are drawn by the .pet::before strip (transform hold keyframes)
    if (a.animationName !== "none") f.push("waiting-for-you pet still playing frames: " + a.animationName);
    if (a.transform !== "none") f.push("waiting-for-you pet not on frame 0: " + a.transform);
    if (getComputedStyle(wf, "::before").animationName !== "none") f.push("waiting-for-you flame layer still animating: " + getComputedStyle(wf, "::before").animationName);
    if (gp && getComputedStyle(gp, "::before").animationName !== "pf6") f.push("working pet stopped playing frames: " + getComputedStyle(gp, "::before").animationName);
    for (const r of rc.qa("#cr-msgs .cr-row.w")) if (getComputedStyle(r.querySelector(".cr-av > .cr-clip")).animationName !== "cr-knock") f.push("a waiting-for-you row is not knocking");
    for (const n of rc.qa("[data-rc]")) n.remove();
    return { fail: f };` },
  // Context ring on message-list rows: three color levels, not drawn without data, long summary truncates without jumping with the number, not drawn in the collapsed rest group, 3 s refresh only changes the number without rebuilding
  { name: "ctx-ring", tab: "msg", path: () => "/", run: `
    window.__cx = { "render-demo": 9, "deploy-check": 83, "style-guide": 58, "ci-matrix": 41 };
    rc.stubSnap((j) => {
      for (const s of j.sessions) {
        if (s.plate in window.__cx) { s.meta = Object.assign({}, s.meta, { ctxPct: window.__cx[s.plate], at: j.serverNow }); } // expired meta falls back to grey: at from sample generation time would pass 5 minutes in a long run, so stub it fresh
        if (s.plate === "peer-relay") delete s.meta;
        if (s.plate === "image-inline") s.meta = Object.assign({}, s.meta, { ctxPct: "abc" });
        if (s.plate === "render-demo") s.summary = "A very long summary that keeps going and going so that it has to be cut off with an ellipsis before the ring on the right side of the row ".repeat(2);
        if (s.plate === "receipts") { s.rest = true; s.meta = Object.assign({}, s.meta, { ctxPct: 60 }); }
      }
      return j;
    });
    await rc.wait("#cr-msgs .cr-row.w", 6000, "waiting-for-you rows");
    await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").some((x) => x.textContent === "41%"), 9000, "stubbed snapshot (41%)");
    await rc.sleep(500);
    const f = [];
    const rowOf = (plate) => rc.qa("#cr-msgs .cr-row").find((r) => r.querySelector(".cr-nm").textContent.includes(plate));
    const want = { "render-demo": ["ok", "9%"], "deploy-check": ["bad", "83%"], "style-guide": ["warn", "58%"], "ci-matrix": ["ok", "41%"] };
    const col = { ok: "rgb(122, 122, 122)", warn: "rgb(255, 154, 31)", bad: "rgb(250, 81, 81)" };
    const widths = new Set();
    for (const p in want) {
      const r = rowOf(p);
      if (!r) { f.push("row not found: " + p); continue; }
      const cx = r.querySelector(".cr-l2 > .cr-cx");
      if (!cx) { f.push(p + " has no ring"); continue; }
      const [lv, tx] = want[p];
      if (!cx.classList.contains(lv)) f.push(p + " wrong level: " + cx.className);
      if (cx.querySelector("b").textContent !== tx) f.push(p + " wrong number: " + cx.querySelector("b").textContent);
      if (!cx.querySelector("svg.rg")) f.push(p + " has no ringSvg");
      else if (Math.round(cx.querySelector("svg").getBoundingClientRect().width) !== 15) f.push(p + " ring is not 15px");
      const fill = cx.querySelector(".rg-f");
      if (!fill) f.push(p + " has no progress arc");
      else if (lv === "ok") { if (getComputedStyle(cx.querySelector(".rg")).opacity === "1") f.push(p + " ring <50 not dimmed"); }
      else if (getComputedStyle(fill).stroke !== col[lv]) f.push(p + " ring colour " + getComputedStyle(fill).stroke + " expected " + col[lv]);
      const bs = getComputedStyle(cx.querySelector("b"));
      if (bs.color !== col[lv]) f.push(p + " number colour " + bs.color);
      if (bs.fontSize !== "12px") f.push(p + " number is not 12px");
      widths.add(Math.round(cx.getBoundingClientRect().width));
      const kids = [...r.querySelector(".cr-l2").children];
      if (!kids[0].classList.contains("cr-pv") || kids[1] !== cx) f.push(p + " ring is not adjacent to summary");
      if (r.querySelector(".cr-pv").getBoundingClientRect().right > cx.getBoundingClientRect().left + 0.5) f.push(p + " summary overlaps ring");
    }
    if (widths.size !== 1) f.push("ring widths differ across numbers (truncation point would jump): " + [...widths]);
    const lpv = rowOf("render-demo").querySelector(".cr-pv");
    if (lpv.scrollWidth <= lpv.clientWidth) f.push("long summary not truncated");
    if (getComputedStyle(lpv).textOverflow !== "ellipsis" || getComputedStyle(lpv).whiteSpace !== "nowrap") f.push("summary is not single-line ellipsis");
    const rights = new Set(Object.keys(want).map((p) => Math.round(rowOf(p).querySelector(".cr-pv").getBoundingClientRect().right)));
    if (rights.size !== 1) f.push("summary right edges differ across rows: " + [...rights]);
    for (const p of ["peer-relay", "image-inline"]) { const r = rowOf(p); if (!r) f.push("row not found: " + p); else if (r.querySelector(".cr-cx")) f.push(p + " has no data but drew a ring"); }
    if (rowOf("receipts")) f.push("receipts should be folded into rest");
    const fold = rc.q("#cr-fold");
    if (!fold) f.push("no rest fold row");
    else {
      fold.click();
      await rc.wait(() => rowOf("receipts"), 4000, "expanded rest row");
      if (rowOf("receipts").querySelector(".cr-cx")) f.push("row in rest drew a ring");
    }
    const r2 = rowOf("style-guide");
    const cx0 = r2.querySelector(".cr-cx"), pv0 = r2.querySelector(".cr-pv");
    window.__cx["style-guide"] = 73;
    await rc.wait(() => { const c = rowOf("style-guide").querySelector(".cr-cx"); return c && c.querySelector("b").textContent === "73%"; }, 9000, "number refreshed to 73%");
    const r3 = rowOf("style-guide");
    if (r3.querySelector(".cr-cx") !== cx0) f.push("ring node recreated after refresh");
    if (r3.querySelector(".cr-pv") !== pv0) f.push("summary node recreated after refresh (whole row flashes)");
    if (!cx0.classList.contains("bad")) f.push("73% did not turn red: " + cx0.className);
    return { fail: f };` },
  // Row ring meta expires (no update for over 5 minutes) and falls back to the grey level n, same rule as the chat page top bar; fresh ones follow the three levels
  { name: "ctx-ring-stale", tab: "msg", path: () => "/", run: `
    rc.stubSnap((j) => {
      for (const s of j.sessions) {
        if (s.plate === "render-demo") s.meta = Object.assign({}, s.meta, { ctxPct: 83, at: j.serverNow - 600 });
        if (s.plate === "deploy-check") s.meta = Object.assign({}, s.meta, { ctxPct: 83, at: j.serverNow - 5 });
      }
      return j;
    });
    await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").filter((x) => x.textContent === "83%").length === 2, 9000, "stubbed snapshot (two 83%)");
    await rc.sleep(300);
    const f = [];
    const rowOf = (plate) => rc.qa("#cr-msgs .cr-row").find((r) => r.querySelector(".cr-nm").textContent.includes(plate));
    const old = rowOf("render-demo").querySelector(".cr-cx"), fresh = rowOf("deploy-check").querySelector(".cr-cx");
    if (!old.classList.contains("n") || old.classList.contains("bad")) f.push("stale row ring is not grey level: " + old.className);
    if (getComputedStyle(old).opacity !== "0.42") f.push("stale row ring not dimmed: " + getComputedStyle(old).opacity);
    if (getComputedStyle(old.querySelector(".rg-f")).stroke !== "rgb(138, 138, 138)") f.push("stale ring colour " + getComputedStyle(old.querySelector(".rg-f")).stroke);
    if (!fresh.classList.contains("bad")) f.push("fresh 83% is not red level: " + fresh.className);
    if (getComputedStyle(fresh.querySelector(".rg-f")).stroke !== "rgb(250, 81, 81)") f.push("fresh ring colour " + getComputedStyle(fresh.querySelector(".rg-f")).stroke);
    return { fail: f };` },
  // In-app banner matches the push text: short-name title, body "[Waiting for you] content" (localized) in all three languages; do-not-disturb sessions do not pop up
  { name: "banner", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-row", 6000, "list");
    await rc.sleep(2500); // let the banner take a baseline snapshot first
    rc.stubSnap((j) => {
      for (const s of j.sessions) {
        if (s.plate === "render-demo") Object.assign(s, { status: "waiting", since: 1, unread: false, summary: "x", summaryCode: "wait.ask", summaryArgs: { question: "Ship it?" } });
      }
      return j;
    });
    await rc.wait(() => rc.q(".bn.show"), 12000, "banner slides down");
    const f = [];
    const tag = { en: "[Waiting for you] ", hans: "[在等你] ", hant: "[在等你] " }[rc.lang()];
    const ask = { en: "Asks: Ship it?", hans: "问你：Ship it?", hant: "問你：Ship it?" }[rc.lang()];
    const tt = rc.q(".bn .bn-t").textContent, bb = rc.q(".bn .bn-b").textContent;
    if (tt !== "render-demo") f.push("banner title is not the short name: " + tt);
    if (bb !== tag + ask) f.push("wrong banner body: " + bb);
    return { fail: f };` },
  { name: "banner-muted", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-row", 6000, "list");
    await rc.sleep(2500);
    rc.stubSnap((j) => {
      for (const s of j.sessions) {
        if (s.plate === "render-demo") Object.assign(s, { status: "waiting", since: 1, unread: false, muted: true });
        if (s.plate === "peer-relay") Object.assign(s, { status: "waiting", since: 2, unread: false, summary: "", summaryCode: "none" });
      }
      return j;
    });
    const f = [];
    const seen = new Set();
    const t0 = Date.now();
    while (Date.now() - t0 < 12000) {
      const b = rc.q(".bn.show .bn-t");
      if (b) seen.add(b.textContent);
      await rc.sleep(200);
    }
    if (seen.has("render-demo")) f.push("do-not-disturb session popped a banner");
    if (!seen.has("peer-relay")) f.push("control group (not muted) did not pop a banner: " + [...seen]);
    const fb = { en: "[Waiting for you] Needs your decision", hans: "[在等你] 有事要你定", hant: "[在等你] 有事要你決定" }[rc.lang()];
    const last = rc.q(".bn .bn-b");
    if (last && seen.has("peer-relay") && last.textContent !== fb) f.push("wrong banner body when content unavailable: " + last.textContent);
    return { fail: f };` },
  // While in use (phone visible) the snapshot request carries X-Zbs-Dev / X-Zbs-Act: 1; only the banner pops up, and the next request after it reports X-Zbs-Seen: s-<id>:wait (reported only once)
  { name: "presence-banner", tab: "msg", path: () => "/", run: `
    const reqs = [];
    const of = window.fetch;
    window.fetch = function (u, o) {
      if (String(u).includes("/api/snapshot")) reqs.push(Object.assign({}, (o && o.headers) || {}));
      return of.apply(this, arguments);
    };
    await rc.wait("#cr-msgs .cr-row", 6000, "list");
    await rc.sleep(2500);
    let sid = "";
    rc.stubSnap((j) => {
      for (const s of j.sessions) {
        if (s.plate === "render-demo") { sid = s.id; Object.assign(s, { status: "waiting", since: 1, unread: false, summary: "x", summaryCode: "wait.ask", summaryArgs: { question: "Ship it?" } }); }
      }
      return j;
    });
    await rc.wait(() => rc.q(".bn.show"), 12000, "banner slides down");
    const key = "s-" + encodeURIComponent(sid) + ":wait";
    const n0 = reqs.length;
    await rc.wait(() => reqs.slice(n0).some((h) => h["X-Zbs-Seen"] === key), 6000, "report " + key);
    await rc.sleep(4500);
    const f = [];
    const dev = localStorage.getItem("zbs.dev");
    if (!/^[A-Za-z0-9_-]{16}$/.test(dev || "")) f.push("wrong local device id: " + dev);
    if (!reqs.length || reqs.some((h) => h["X-Zbs-Dev"] !== dev)) f.push("not all snapshot requests carry the device id");
    if (reqs.some((h) => h["X-Zbs-Act"] !== "1")) f.push("phone is foreground-visible but reported inactive: " + JSON.stringify(reqs.map((h) => h["X-Zbs-Act"])));
    const reps = reqs.filter((h) => h["X-Zbs-Seen"]);
    if (reps.length !== 1) f.push("report should be sent once, actual " + reps.length + " times: " + JSON.stringify(reps.map((h) => h["X-Zbs-Seen"])));
    return { fail: f };` },
  // App icon badge: after every snapshot update navigator.setAppBadge(n), n = waiting-for-you + has-something-to-say (resting ones excluded, do-not-disturb ones included, same count as the bottom-bar red dot); n=0 -> clearAppBadge
  { name: "app-badge", tab: "msg", path: () => "/", run: `
    const calls = [];
    const put = (k, fn) => Object.defineProperty(navigator, k, { value: fn, configurable: true, writable: true });
    put("setAppBadge", (n) => { calls.push("set:" + n); return Promise.resolve(); });
    put("clearAppBadge", () => { calls.push("clear"); return Promise.resolve(); });
    await rc.wait("#cr-msgs .cr-row", 6000, "list");
    await rc.sleep(2500);
    window.__bd = 1;
    let want = -1;
    rc.stubSnap((j) => {
      const P = ["render-demo", "peer-relay", "deploy-check", "style-guide", "ci-matrix"];
      j.sessions.forEach((s) => {
        Object.assign(s, { status: "idle", unread: false, rest: false, muted: false, manualUnread: false });
        if (window.__bd === 1) {
          if (s.plate === P[0]) Object.assign(s, { status: "waiting", since: 1, muted: true });
          if (s.plate === P[1]) Object.assign(s, { status: "waiting", since: 2 });
          if (s.plate === P[2]) Object.assign(s, { unread: true });
          if (s.plate === P[3]) Object.assign(s, { status: "waiting", since: 3, rest: true });
        }
      });
      want = j.sessions.filter((s) => !s.rest && (s.status === "waiting" || s.unread)).length;
      return j;
    });
    const f = [];
    await rc.wait(() => calls.includes("set:3"), 9000, "setAppBadge(3)");
    const dot = rc.q("#tb-msg");
    if (dot.hidden || dot.textContent !== "3") f.push("tab-bar dot and badge disagree: " + dot.textContent);
    window.__bd = 2;
    await rc.wait(() => calls[calls.length - 1] === "clear", 9000, "n=0 → clearAppBadge");
    if (calls.slice(calls.indexOf("set:3") + 1).some((c) => c.startsWith("set:") && c !== "set:3")) f.push("unexpected badge number: " + calls.join(","));
    return { fail: f };` },
  // "Notification settings" device list (stubbing /api/push/devices): this device first with a "this device" tag, old subscriptions show an unknown device; the confirmation text differs for deleting another device vs this one; after confirming, POST {key}
  { name: "push-devices", tab: "me", path: () => "/", run: `
    const dev = localStorage.getItem("zbs.dev") || "";
    const now = Math.floor(Date.now() / 1000);
    const devs = [
      { key: "aaaaaaaaaaaaaaaa", at: now - 7200, lastActive: now - 7200 },
      { key: "bbbbbbbbbbbbbbbb", dev: "otherDev12345678", plat: "mac", standalone: true, at: now - 600, lastActive: now - 300, active: false, self: false },
      { key: "cccccccccccccccc", dev, plat: "iphone", standalone: true, at: now - 60, lastActive: now, active: true, self: true },
    ];
    const posts = [];
    const of = window.fetch;
    const j = (o) => new Response(JSON.stringify(o), { status: 200, headers: { "Content-Type": "application/json" } });
    window.fetch = function (u, o) {
      const url = String(u);
      if (url.includes("/api/push/devices/delete")) { posts.push(JSON.parse(o.body)); return Promise.resolve(j({ ok: true })); }
      if (url.includes("/api/push/devices")) return Promise.resolve(j({ devices: devs }));
      return of.apply(this, arguments);
    };
    await rc.wait('[data-me="push"]', 6000, "notification settings on Me page");
    rc.click('[data-me="push"]');
    await rc.wait(() => rc.qa(".pd-row").length === 3, 6000, "three device rows");
    await rc.sleep(400);
    const f = [];
    const L = {
      en: { me: "This device", unk: "Unknown device (old subscription)", now: "In use now", self: /stop notifications on this device/, other: /signs up again/ },
      hans: { me: "本机", unk: "未知设备（旧订阅）", now: "正在用", self: /停止本机推送/, other: /重新登记/ },
      hant: { me: "本機", unk: "未知裝置（舊訂閱）", now: "正在用", self: /停止本機推播/, other: /重新登記/ },
    }[rc.lang()];
    const rows = rc.qa(".pd-row");
    if (rows[0].dataset.key !== "cccccccccccccccc" || !rows[0].querySelector(".pd-me")) f.push("this device not first or not tagged as this device");
    else if (rows[0].querySelector(".pd-me").textContent !== L.me) f.push("this-device tag: " + rows[0].querySelector(".pd-me").textContent);
    if (rows[0].querySelector(".pd-last").textContent !== L.now) f.push("this-device in-use text: " + rows[0].querySelector(".pd-last").textContent);
    if (rows[2].querySelector(".pd-nm").textContent !== L.unk) f.push("old subscription text: " + rows[2].querySelector(".pd-nm").textContent);
    for (const r of rows) { const nm = r.querySelector(".pd-nm"); if (nm.scrollWidth > nm.clientWidth + 1) f.push("device name truncated: " + nm.textContent); }
    rows[1].querySelector(".pd-del").click();
    await rc.wait(() => rc.q(".as-btn.danger"), 3000, "delete confirmation (other device)");
    const hintO = (rc.q(".as-title small") || {}).textContent || "";
    if (!L.other.test(hintO)) f.push("delete-other confirmation does not mention re-registering: " + hintO);
    rc.click(".as-btn.cancel");
    await rc.sleep(500);
    rc.click('[data-me="push"]');
    await rc.wait(() => rc.qa(".pd-row").length === 3, 6000, "three device rows after reopening");
    rc.qa(".pd-row")[0].querySelector(".pd-del").click();
    await rc.wait(() => rc.q(".as-btn.danger"), 3000, "delete confirmation (this device)");
    const hintS = (rc.q(".as-title small") || {}).textContent || "";
    if (!L.self.test(hintS)) f.push("delete-this-device confirmation does not mention stopping local push: " + hintS);
    rc.click(".as-btn.danger");
    await rc.wait(() => posts.length === 1, 4000, "delete request");
    if (posts[0].key !== "cccccccccccccccc") f.push("delete request key: " + JSON.stringify(posts[0]));
    await rc.wait(() => rc.qa(".pd-row").length === 3, 6000, "back to notification settings after delete");
    return { fail: f };` },
  // Reduced motion: no shaking, a slow outline blink instead (::before fades in and out every 2 s)
  { name: "nudge-reduce", tab: "msg", reduce: true, path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-row.w", 6000, "waiting-for-you rows");
    await rc.sleep(400);
    const f = [];
    for (const r of rc.qa("#cr-msgs .cr-row.w")) {
      const av = r.querySelector(".cr-av");
      const b = getComputedStyle(av, "::before");
      if (b.animationName !== "cr-r3") f.push("outline animation under reduced motion is " + b.animationName);
      if (b.animationDuration !== "2s") f.push("outline period " + b.animationDuration);
      if (!/rgb\\(250, 81, 81\\)/.test(b.boxShadow)) f.push("outline is not red: " + b.boxShadow);
      if (getComputedStyle(av.querySelector(".cr-clip")).animationName !== "none") f.push("avatar still shaking under reduced motion");
    }
    for (const r of rc.qa("#cr-msgs .cr-row:not(.w)")) {
      if (getComputedStyle(r.querySelector(".cr-av"), "::before").animationName === "cr-r3") f.push("non-waiting row also has outline");
    }
    return { fail: f };` },
  // Stale snapshot (stub /api/snapshot: data 40 s old, helper stopped): whole page greyed, timers frozen, animations stopped, header states the reason
  { name: "mac-down", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-tm.live", 6000, "working timer");
    let gen0 = 0; // on a real disconnect the snapshot stops updating and generatedAt stays constant (40 s ago: past the 30 s threshold, yet later than the busy row's start time)
    rc.stubSnap((j) => { gen0 = gen0 || j.serverNow - 40; j.generatedAt = gen0; j.stale = true; j.down = { reason: "helper", at: gen0 }; return j; });
    await rc.wait(() => document.body.classList.contains("mac-down"), 6000, "body.mac-down");
    await rc.sleep(300);
    const f = [];
    const row = rc.q("#cr-msgs .cr-row");
    if (!/grayscale\\(1\\)/.test(getComputedStyle(row).filter)) f.push("row did not turn grey: " + getComputedStyle(row).filter);
    const mt = rc.q("#cr-mac-t").textContent;
    if (!/helper|小帮手|小幫手/i.test(mt)) f.push("page header does not say helper stopped: " + mt);
    const me = rc.q("#cr-mac-t");
    if (me.scrollWidth > me.clientWidth + 1) f.push("page header '" + mt + "' truncated");
    const tb = rc.q("#tb-msg");
    if (tb && !tb.hidden && getComputedStyle(tb).backgroundColor !== "rgb(94, 94, 94)") f.push("tab-bar dot did not turn grey: " + getComputedStyle(tb).backgroundColor);
    if (rc.q("#cr-msgs .cr-tm.live").textContent === "0:00") f.push("timer froze at 0:00 (should stop at the working duration when disconnected)");
    const tm = rc.q("#cr-msgs .cr-tm.live");
    const a = tm.textContent;
    await rc.sleep(2200);
    if (tm.textContent !== a) f.push("timer still ticking: " + a + " → " + tm.textContent);
    const w = rc.q("#cr-msgs .cr-row.w .cr-av > .cr-clip");
    if (w && getComputedStyle(w).animationPlayState !== "paused") f.push("urgent shake did not stop");
    const run = rc.q("#cr-msgs .fxw-runner, #cr-msgs .fxw-carrier");
    if (run && getComputedStyle(run).animationPlayState !== "paused") f.push("walking figure did not stop");
    return { fail: f };` },
  // Chat page: when the snapshot is stale a grey bar under the top bar (states the reason); when Orca is off a yellow line above the input area
  { name: "chat-down", tab: "msg", path: () => "/#s/" + IDS.chat, run: `
    await rc.wait("#list .cg", 8000, "chat");
    let gen0 = 0;
    rc.stubSnap((j) => { gen0 = gen0 || j.serverNow - 40; j.generatedAt = gen0; j.stale = true; j.down = { reason: "panel", at: gen0 }; j.orca = { running: false }; return j; });
    await rc.wait(() => !rc.q("#d-down").hidden, 6000, "chat page disconnected grey bar");
    await rc.wait(() => !rc.q("#orca-hint").hidden, 4000, "Orca-not-running hint");
    const f = [];
    if (!/Soulgent/.test(rc.q("#d-down").textContent)) f.push("grey bar does not say board unresponsive: " + rc.q("#d-down").textContent);
    if (!/Orca/.test(rc.q("#orca-hint").textContent)) f.push("wrong Orca hint: " + rc.q("#orca-hint").textContent);
    if (rc.q("#composer").hidden) f.push("input box should not be hidden when disconnected (messages queue in outbox)");
    return { fail: f };` },
  // Codex / WorkBuddy badges; WorkBuddy state.error turns into a red [Error] label
  { name: "kinds", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-kind", 6000, "identity badges");
    const f = [];
    const tags = rc.qa("#cr-msgs .cr-kind").map((e) => e.textContent);
    for (const k of ["Codex", "WorkBuddy"]) if (!tags.includes(k)) f.push("missing badge " + k + " (found: " + tags.join(",") + ")");
    if (tags.length !== 2) f.push("badges: " + tags.length + " (expected 2; Claude has none)");
    const e = rc.q("#cr-msgs .cr-pt.e");
    if (!e) f.push("WorkBuddy error has no red label");
    else if (getComputedStyle(e).color !== "rgb(196, 57, 43)") f.push("error label colour should be brick red #C4392B, actual " + getComputedStyle(e).color);
    return { fail: f };` },
  // Background expressions: list rows (bg-run running, bg-hung hung, busy-bg busy + background)
  { name: "bg-list", tab: "msg", path: () => "/", run: () => `
    await rc.wait("#cr-msgs .cr-row", 6000, "message list");
    await rc.sleep(1500);
    const f = [];
    const row = (id) => rc.q('#cr-msgs .cr-row[data-id="' + id + '"]');
    const run = row(${JSON.stringify(IDS.bgrun)}), hung = row(${JSON.stringify(IDS.bghung)}), busy = row(${JSON.stringify(IDS.busybg)});
    if (!run || !hung || !busy) return { fail: ["missing rows bg-run/bg-hung/busy-bg: " + [!!run, !!hung, !!busy]] };
    const pt = (r) => (r.querySelector(".cr-pt") || {}).textContent || "";
    const L = rc.lang();
    const wantRun = { en: "Running in background (2)", hans: "后台在跑 (2)", hant: "背景執行中 (2)" }[L];
    const wantHung = { en: "Background task may be stuck", hans: "后台任务疑似挂住", hant: "背景任務疑似卡住" }[L];
    if (!pt(run).includes(wantRun)) f.push("bg-run status text '" + pt(run) + "' should contain '" + wantRun + "'");
    if (run.querySelector(".cr-dot")) f.push("bg-run has red dot");
    if (!run.closest("li").querySelector(".fxw-track")) f.push("bg-run has no walking .fxw-track");
    // Background running, main turn idle: the avatar stands (idle frame, not the busy frame), no "running errands" badge, and the pet / soulflame in the avatar is not hidden
    const avp = run.querySelector(".cr-av .pet");
    const bgi = avp ? getComputedStyle(avp).backgroundImage : "";
    if (!avp || /mascot-av-busy|\\/7\\.webp/.test(bgi) || !/mascot-av-idle|\\/0\\.webp/.test(bgi)) f.push("bg-run avatar should be idle frame, actual " + bgi);
    if (run.closest("li").querySelector(".fxw-sign")) f.push("bg-run avatar should not carry the running-errands sign");
    const pin = run.querySelector(".cr-pin");
    if (!pin || getComputedStyle(pin).display === "none") f.push("pet / soulflame in bg-run avatar is hidden");
    const tm = run.querySelector(".cr-tm");
    if (!tm.classList.contains("live")) f.push("bg-run timer is not live");
    const m = /^(\\d+):(\\d\\d)$/.exec(tm.textContent.trim());
    const sec = m ? Number(m[1]) * 60 + Number(m[2]) : -1;
    if (!(sec >= 595 && sec <= 3000)) f.push("bg-run timer '" + tm.textContent + "' should start from bgSince (10 min ago, m:ss format; since is 5 h ago)");
    if (!pt(hung).includes(wantHung)) f.push("bg-hung status text '" + pt(hung) + "' should contain '" + wantHung + "'");
    if (getComputedStyle(hung.querySelector(".cr-pt")).color === getComputedStyle(run.querySelector(".cr-pt")).color) f.push("bg-hung label is not grey (same colour as running)");
    if (hung.closest("li").querySelector(".fxw-track")) f.push("bg-hung should not walk (has .fxw-track)");
    if (hung.querySelector(".cr-tm.live")) f.push("bg-hung should not have a timer");
    if (hung.querySelector(".cr-dot")) f.push("bg-hung has red dot");
    if (!busy.closest("li").classList.contains("fx-halo")) f.push("OPS zone of busy-bg should have halo effect (li class: " + busy.closest("li").className + ")");
    if (!/^\\d+:\\d\\d$/.test(busy.querySelector(".cr-tm").textContent.trim())) f.push("wrong busy-bg timer: " + busy.querySelector(".cr-tm").textContent);
    // Halo-zone session with background running (idle): effect toned down one level (li.fx-calm, bursts / thrown objects retracted); the busy + background row stays at the strong level
    const calm = row(${JSON.stringify(IDS.bgcalm)});
    if (!calm) f.push("missing row bg-calm");
    else {
      const cl = calm.closest("li");
      if (!cl.classList.contains("fx-halo")) f.push("bg-calm should have halo effect (li class: " + cl.className + ")");
      if (!cl.classList.contains("fx-calm")) f.push("bg-calm (idle + background running) should have weak-level fx-calm (li class: " + cl.className + ")");
      const g = cl.querySelector(".fxl");
      if (g && getComputedStyle(g).filter === "none") f.push("bg-calm effect layer not dimmed");
    }
    if (busy.closest("li").classList.contains("fx-calm")) f.push("busy-bg (main turn busy) should not be downgraded");
    // Circuit zone jitters the avatar (.cr-pin) while busy; idle + background running must keep it still (no shake / hop), while busy still animates
    const cb = row(${JSON.stringify(IDS.circbg)}), cy = row(${JSON.stringify(IDS.circbusy)});
    if (!cb || !cy) f.push("missing rows circ-bg/circ-busy: " + [!!cb, !!cy]);
    else {
      const an = (r) => { const p = r.querySelector(".cr-pin"); return p ? getComputedStyle(p).animationName : "(no .cr-pin)"; };
      if (!cb.closest("li").classList.contains("fx-calm")) f.push("circ-bg should carry fx-calm (li class: " + cb.closest("li").className + ")");
      if (an(cb) !== "none") f.push("circ-bg (idle + background running) avatar should not animate, animationName=" + an(cb));
      if (an(cy) === "none" || an(cy) === "(no .cr-pin)") f.push("circ-busy avatar should still animate, animationName=" + an(cy));
    }
    if (hung.closest("li").classList.contains("fx-calm")) f.push("bg-hung should not have fx-calm");
    hung.scrollIntoView({ block: "end" }); await rc.sleep(300); // for the screenshot: scroll both rows into the viewport
    return { fail: f };` },
  // Chat page: after a full turn the background-Bash figure is still working; top-bar capsule "SA N · BG M"; without bgList, tapping the "Background commands ×M" row jumps to the little crab
  { name: "bg-chat", tab: "msg", path: () => "/#s/" + IDS.bgrun, run: `
    await rc.wait("#list .cg", 8000, "chat bubbles");
    await rc.sleep(1500);
    const f = [];
    const stat = rc.q("#d-stat");
    if (!stat || stat.hidden) return { fail: ["top bar has no helper capsule"] };
    const txt = stat.children[0].textContent.trim();
    if (txt !== "BG 2") f.push("capsule '" + txt + "' should be 'BG 2' (same in all three languages, untranslated)");
    if (stat.children[1].textContent.trim()) f.push("capsule second line still has text: " + stat.children[1].textContent);
    if (/排队|已干|Queued|Working/.test(stat.textContent)) f.push("top bar still shows queued / worked N min");
    const fg = rc.qa("#list [data-fig]");
    if (!fg.length) f.push("no figure anchor in chat");
    // Figure: figures.js marks finished figures with fg-done / fg-docked, ones still wandering have neither. A full round of chat happened after the background Bash and the snapshot says the background is still running -> still wandering
    const figs = rc.qa(".figs .fg");
    if (!figs.length) f.push("no figures (.figs .fg)");
    const done = figs.filter((e) => e.classList.contains("fg-done") || e.classList.contains("fg-docked") || e.classList.contains("fg-err"));
    if (done.length) f.push("background Bash figure judged done (fg-done/docked " + done.length + " figures), should still be walking");
    const lg = rc.q("#list li[data-tu=toolu_bg11]");
    if (!lg) f.push("background Bash row not found (li[data-tu=toolu_bg11])");
    stat.click();
    await rc.wait("#sheet-wrap.open .hl-item", 3000, "helper list");
    const titles = rc.qa("#sheet h3").map((e) => e.textContent.trim());
    if (titles[0] !== "BG 2") f.push("list title '" + titles[0] + "' should be 'BG 2'");
    const items = rc.qa("#sheet .hl-item");
    if (items.length !== 1) f.push("without bgList there should be one row, actual " + items.length);
    else {
      const want = { en: "Background commands ×2", hans: "后台命令 ×2", hant: "背景指令 ×2" }[rc.lang()];
      if (items[0].querySelector(".hl-tx b").textContent.trim() !== want) f.push("list row '" + items[0].textContent + "' should be '" + want + "'");
      if (items[0].querySelector(".hl-tx small").textContent.trim() !== "BG") f.push("row subtitle should be BG");
      items[0].click();
      await rc.wait(() => rc.q("#list .bg-flash"), 3000, "flashes twice after jumping to the little crab");
      if (!rc.q("#list .bg-flash li[data-tu=toolu_bg11]")) f.push("flashed chip is not the background Bash tool chip");
    }
    return { fail: f };` },
  // Chat page (bg-hung, bgStale): falls back to the "a turn passed means done" rule, the figure has settled; the capsule stays
  { name: "bg-chat-hung", tab: "msg", path: () => "/#s/" + IDS.bghung, run: `
    await rc.wait("#list .cg", 8000, "chat bubbles");
    await rc.sleep(1800);
    const f = [];
    const figs = rc.qa(".figs .fg");
    if (!figs.length) f.push("no figures (.figs .fg)");
    else if (!figs.every((e) => e.classList.contains("fg-done") || e.classList.contains("fg-docked"))) f.push("figure of the hung session should settle back to avatar (fg-done), not keep walking");
    return { fail: f };` },
  // Chat page (with bgList): the busy-bg list is built from bgList; tapping a cmd row jumps to the little crab matching toolUseId
  { name: "bg-chat-list", tab: "msg", path: () => "/#s/" + IDS.busybg, run: `
    await rc.wait("#list .cg", 8000, "chat bubbles");
    await rc.sleep(1500);
    const f = [];
    const stat = rc.q("#d-stat");
    if (!stat || stat.hidden) return { fail: ["top bar has no helper capsule"] };
    if (stat.children[0].textContent.trim() !== "BG 1") f.push("capsule '" + stat.children[0].textContent + "' should be 'BG 1'");
    stat.click();
    await rc.wait("#sheet-wrap.open .hl-item", 3000, "helper list");
    const items = rc.qa("#sheet .hl-item");
    if (items.length !== 1) return { fail: ["with bgList there should be one row, actual " + items.length] };
    if (items[0].querySelector(".hl-tx b").textContent.trim() !== "npm run dev") f.push("row title should use bgList.desc: " + items[0].textContent);
    if (!/^\\d+ ?(分|min)/.test(items[0].querySelector(".hl-time").textContent.trim())) f.push("command row time should be N min: " + items[0].querySelector(".hl-time").textContent);
    items[0].click();
    await rc.wait(() => rc.q("#list .bg-flash"), 3000, "jump to the little crab for toolUseId");
    if (!rc.q("#list .bg-flash li[data-tu=toolu_bg13]")) f.push("flashed chip is not the toolu_bg13 tool chip");
    return { fail: f };` },
  // Error / retrying / unexpected exit: list rows (api-err quota exhausted, retrying in progress, gone unexpected exit)
  { name: "errors", tab: "msg", path: () => "/", run: () => `
    await rc.wait("#cr-msgs .cr-row", 6000, "message list");
    await rc.sleep(1500);
    const f = [];
    const row = (id) => rc.q('#cr-msgs .cr-row[data-id="' + id + '"]');
    const lim = row(${JSON.stringify(IDS.apierr)}), rt = row(${JSON.stringify(IDS.retrying)}), gn = row(${JSON.stringify(IDS.gone)});
    if (!lim || !rt || !gn) return { fail: ["missing rows api-err/retrying/gone: " + [!!lim, !!rt, !!gn]] };
    const pt = (r) => r.querySelector(".cr-pt");
    const txt = (r) => (pt(r) || {}).textContent || "";
    const col = (r) => (pt(r) ? getComputedStyle(pt(r)).color : "");
    const L = rc.lang();
    const AMBER = "rgb(255, 159, 10)";
    const wantLim = { en: "[Limit reached]", hans: "[额度用完]", hant: "[額度用完]" }[L];
    const wantRt = { en: "Retrying 3/10", hans: "正在重试 3/10", hant: "正在重試 3/10" }[L];
    const wantGn = { en: "Exited unexpectedly", hans: "意外退出", hant: "意外結束" }[L];
    if (txt(lim) !== wantLim) f.push("api-err label '" + txt(lim) + "' should be '" + wantLim + "'");
    if (col(lim) !== AMBER) f.push("limit-reached label should be amber, actual " + col(lim));
    if (!lim.querySelector(".cr-pv").textContent.includes("resets 1pm")) f.push("api-err second line should carry CC's original text (resets 1pm): " + lim.querySelector(".cr-pv").textContent);
    if (!lim.querySelector(".cr-dot")) f.push("api-err error is later than read, should have red dot");
    if (!txt(rt).includes(wantRt)) f.push("retrying label '" + txt(rt) + "' should contain '" + wantRt + "'");
    if (col(rt) !== AMBER) f.push("retrying label should be amber, actual " + col(rt));
    if (rt.querySelector(".cr-dot")) f.push("retrying should not have red dot");
    if (txt(gn) !== wantGn) f.push("gone label '" + txt(gn) + "' should be '" + wantGn + "' (not called disconnected)");
    if (!gn.classList.contains("gone")) f.push("gone row lacks .gone (whole row grey)");
    if (!gn.querySelector(".cr-av.off")) f.push("gone avatar is not grey (.cr-av.off)");
    if (gn.querySelector(".cr-dot")) f.push("gone should not have red dot");
    if (getComputedStyle(gn.querySelector(".cr-nm")).color === getComputedStyle(lim.querySelector(".cr-nm")).color) f.push("gone name is not grey");
    if (gn.querySelector(".cr-av.rest")) f.push("gone fell into the rest group (since 7 h ago; rest group is folded by default, so rows above would be missing)");
    gn.scrollIntoView({ block: "end" }); await rc.sleep(300); // for the screenshot
    return { fail: f };` },
  // Chat page notice bar: quota exhausted (amber + CC's verbatim text)
  { name: "errors-chat-limit", tab: "msg", path: () => "/#s/" + IDS.apierr, run: () => `
    await rc.wait("#list .cg", 8000, "chat bubbles");
    await rc.sleep(1200);
    const f = [];
    const a = rc.q("#d-alert");
    if (!a || a.hidden) return { fail: ["chat page has no alert bar #d-alert"] };
    const want = { en: "[Limit reached]", hans: "[额度用完]", hant: "[額度用完]" }[rc.lang()];
    if (!a.textContent.startsWith(want) || !a.textContent.includes("resets 1pm")) f.push("alert bar '" + a.textContent + "' should be '" + want + " ...resets 1pm'");
    if (getComputedStyle(a).color !== "rgb(255, 159, 10)") f.push("alert bar should be amber, actual " + getComputedStyle(a).color);
    // CC's synthetic error is shown as a centered system row, not an assistant bubble (quota exhausted, amber), with no avatar and no reply bubble
    const sys = rc.q("#list .tm.limit");
    if (!sys) f.push("no centred system row .tm.limit");
    else {
      if (!sys.textContent.includes("resets 1pm")) f.push("system row text '" + sys.textContent + "' should contain CC original text");
      if (getComputedStyle(sys).color !== "rgb(255, 159, 10)") f.push("system row should be amber, actual " + getComputedStyle(sys).color);
      if (getComputedStyle(sys).alignSelf !== "center") f.push("system row not centred: " + getComputedStyle(sys).alignSelf);
    }
    if (rc.qa("#list .cg").some((g) => g.textContent.includes("hit your limit"))) f.push("error still drawn as a reply bubble");
    // Opening the chat page counts as read: mark it unread again so the errors scenario in the next language still sees the red dot (the api's read state is shared across languages)
    await fetch("/api/sessions/${IDS.apierr}/unseen", { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" });
    return { fail: f };` },
  // Chat page: retrying -- placeholder bubble small text "Retrying the API (3/10)", amber notice bar
  { name: "errors-chat-retry", tab: "msg", path: () => "/#s/" + IDS.retrying, run: `
    await rc.wait("#list .ph-t", 8000, "placeholder bubble");
    await rc.sleep(800);
    const f = [];
    const want = { en: "Retrying the API (3/10)", hans: "正在重试 API（3/10）", hant: "正在重試 API（3/10）" }[rc.lang()];
    const ph = rc.q("#list .ph-t").textContent.trim();
    if (ph !== want) f.push("placeholder bubble '" + ph + "' should be '" + want + "'");
    const a = rc.q("#d-alert");
    if (!a || a.hidden || a.textContent.trim() !== want) f.push("alert bar should be '" + want + "': " + (a && !a.hidden ? a.textContent : "(not shown)"));
    return { fail: f };` },
  // Chat page: unexpected exit -- grey "The session exited unexpectedly."
  { name: "errors-chat-gone", tab: "msg", path: () => "/#s/" + IDS.gone, run: `
    await rc.wait("#list .cg", 8000, "chat bubbles");
    await rc.sleep(1200);
    const f = [];
    const a = rc.q("#d-alert");
    const want = { en: "The session exited unexpectedly.", hans: "会话意外退出。", hant: "會話意外結束。" }[rc.lang()];
    if (!a || a.hidden) return { fail: ["chat page has no alert bar #d-alert"] };
    if (a.textContent.trim() !== want) f.push("alert bar '" + a.textContent + "' should be '" + want + "'");
    if (getComputedStyle(a).color === "rgb(255, 159, 10)" || getComputedStyle(a).color === "rgb(196, 57, 43)") f.push("unexpected-exit alert bar should be grey text: " + getComputedStyle(a).color);
    return { fail: f };` },
  // Busy rows in zones without effects: no desk, the soulflame (no pets installed) leaves its frame to run errands / carry files
  // README screenshots: use gen_readme.py's clean fictional fixture (readme:true); only run with --only readme-* or the full run; --shots produces the images
  { name: "readme-list", readme: true, tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .cr-row.w", 8000, "waiting-for-you rows");
    await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").length >= 4, 8000, "context rings");
    await rc.sleep(700);
    const f = [];
    if (rc.qa("#cr-msgs .cr-row.w").length < 2) f.push("fewer than 2 waiting-for-you rows");
    for (const r of rc.qa("#cr-msgs .cr-row.w")) for (const a of r.querySelector(".cr-av > .cr-clip").getAnimations()) {
      a.pause(); const d = a.effect.getTiming().delay || 0; a.currentTime = ((120 + d) % 3000 + 3000) % 3000;
    }
    return { fail: f };` },
  { name: "readme-chat", readme: true, tab: "msg", path: () => "/#s/" + RIDS.chat, run: `
    await rc.wait("#list .ask.live .opt", 10000, "unanswered question card");
    await rc.sleep(1500);
    const f = [];
    // After scrolling to the bottom, a bubble covered by the navigation bar must not stay half visible: first hide the short transition reply right after it to make room (user bubbles stay), and if that is not enough hide the whole covered row;
    // also hide the "reached the earliest" notice (screenshot page only, product code untouched)
    const msgs = rc.q("#msgs"), lst = rc.q("#list"), hb = () => rc.q("#d-more").closest("header").getBoundingClientRect().bottom;
    const shown = () => [...lst.children].filter((c) => c.style.display !== "none" && c.getBoundingClientRect().height > 0);
    rc.q("#older").style.display = "none";
    for (let k = 0; k < 40; k++) {
      msgs.scrollTop = msgs.scrollHeight; await rc.sleep(120);
      for (const c of shown()) if (c.getBoundingClientRect().bottom <= hb()) c.style.display = "none"; // whole rows already scrolled off screen
      const cut = shown().filter((c) => c.getBoundingClientRect().top < hb() - 1);
      if (!cut.length) break;
      const rows = shown(), nxt = rows[rows.indexOf(cut[cut.length - 1]) + 1];
      if (cut.length === 1 && nxt && nxt !== rows[rows.length - 1] && nxt !== rows[rows.length - 2] && nxt.getBoundingClientRect().height < 150) nxt.style.display = "none";
      else for (const c of cut) c.style.display = "none";
    }
    await rc.sleep(600);
    { const bad = shown().filter((c) => c.getBoundingClientRect().top < hb() - 1);
      if (bad.length) f.push("chat page top still has covered rows: " + bad.length);
      const vis = shown();
      if (vis.length < 3) f.push("only " + vis.length + " rows left after hiding, too few"); }
    if (rc.qa("#list .ask.live .opts > button.opt").length < 2) f.push("question card has fewer than 2 options");
    if (!rc.q("#list .ask.live .ask-go button.go")) f.push("no submit button");
    if (!rc.q("#list .tools[data-fig]") && !rc.q("#list .m[data-fig]")) f.push("no tool figure");
    return { fail: f };` },
  { name: "readme-board", readme: true, tab: "zones", path: () => "/", run: `
    await rc.wait("#p-zones .zc", 8000, "zone card on board page");
    await rc.sleep(1200);
    return { fail: rc.qa("#p-zones .zc").length >= 4 ? [] : ["fewer than 4 zone cards"] };` },
  { name: "walk-flame", tab: "msg", path: () => "/", run: `
    await rc.wait("#cr-msgs .fxw-track", 6000, "walking track");
    const f = [];
    if (rc.q("#cr-msgs .fxw-desk, #cr-msgs .fxw-chair")) f.push("desk / chair still present");
    const spr = rc.q("#cr-msgs .fxw-track .cr-spr .pet");
    if (!spr) f.push("no figure on the track");
    else if (!/\\/figures\\/soulflame\\/7\\.webp/.test(getComputedStyle(spr).backgroundImage)) f.push("walking figure is not soulflame: " + getComputedStyle(spr).backgroundImage);
    if (rc.q("#cr-msgs .fx-walk .fxw-ghost")) f.push("no ghost should remain in avatar when soulflame stand-in walks out");
    return { fail: f };` },
];

const RC_LIB = `window.rc = {
  q: (s) => document.querySelector(s), qa: (s) => [...document.querySelectorAll(s)],
  sleep: (ms) => new Promise((r) => setTimeout(r, ms)),
  click(s) { const e = document.querySelector(s); if (!e) throw new Error("not found: " + s); e.click(); return e; },
  async wait(c, ms, what) {
    const fn = typeof c === "string" ? () => document.querySelector(c) : c;
    const end = Date.now() + ms;
    for (;;) { let v = null; try { v = fn(); } catch (e) { v = null; } if (v) return v; if (Date.now() > end) throw new Error("timed out waiting for: " + (what || c)); await new Promise((r) => setTimeout(r, 100)); }
  },
  cardByName(n) { const c = [...document.querySelectorAll("#list .at-card[data-f], #list .at-chip[data-f]")].find((b) => { try { return JSON.parse(b.dataset.f).name === n; } catch (e) { return false; } }); if (!c) throw new Error("attachment card not found: " + n); return c; },
  imgByName(n) { return [...document.querySelectorAll("#list .at-img[data-f]")].find((b) => { try { return JSON.parse(b.dataset.f).name === n; } catch (e) { return false; } }); },
  lang: () => localStorage.getItem("zbs.lang"),
  // Stub sending: how(text) -> "fail" (POST 500) / "done" (202 + poll done) / "wait" (202 + poll stays pending); delay = delay in ms for POST and polling. Returns the list of bodies sent
  stubSend(how, delay) {
    const of = window.fetch, posts = [], rid = new Map();
    const j = (o, status) => new Response(JSON.stringify(o), { status, headers: { "Content-Type": "application/json" } });
    const later = (v) => new Promise((r) => setTimeout(() => r(v), delay || 0));
    window.fetch = function (u, o) {
      const url = String(u);
      if (/\\/api\\/sessions\\/[^/]+\\/send/.test(url) && o && o.method === "POST") {
        const b = JSON.parse(o.body || "{}");
        if (b.recall) return of.apply(this, arguments);
        posts.push(b);
        const tx = String(b.text || "").replace(/^\\[[^\\]]*\\]\\s*/, "");
        const k = how(tx);
        if (k === "fail") return later(j({ error: "rc-stub" }, 500));
        const id = "rc-" + posts.length;
        rid.set(id, k);
        return later(j({ requestId: id }, 202));
      }
      const m = url.match(/\\/api\\/requests\\/([^?]+)/);
      if (m && rid.has(decodeURIComponent(m[1]))) return later(j({ status: rid.get(decodeURIComponent(m[1])) === "done" ? "done" : "pending" }, 200));
      return of.apply(this, arguments);
    };
    return posts;
  },
  // Stub the snapshot: fn(json) modifies and returns it (the mac-down scenario builds stale data; serve.py's snapshot is always fresh)
  stubSnap(fn) {
    const of = window.fetch;
    window.fetch = async function (u, o) {
      const r = await of.apply(this, arguments);
      if (!String(u).includes("/api/snapshot") || !r.ok) return r;
      const j = fn(await r.clone().json());
      return new Response(JSON.stringify(j), { status: 200, headers: { "Content-Type": "application/json" } });
    };
  },
  // Stub the first transcript page: fn(json) modifies and returns it (the imgflash scenario injects "queued / final read" entries per stage)
  stubTranscript(fn) {
    const of = window.fetch;
    window.fetch = async function (u, o) {
      const r = await of.apply(this, arguments);
      if (!/\\/transcript/.test(String(u)) || /before=/.test(String(u)) || !r.ok) return r;
      const j = fn(await r.clone().json());
      return new Response(JSON.stringify(j), { status: 200, headers: { "Content-Type": "application/json" } });
    };
  },
  async send(text) { const ta = document.querySelector("#reply"); ta.value = text; ta.dispatchEvent(new Event("input", { bubbles: true })); document.querySelector("#btn-send").click(); await new Promise((r) => setTimeout(r, 80)); },
  loadingNote() { const n = document.querySelector("#fs-body > .at-note"); return !!n && n.parentNode.children.length === 1 && /…|\\.\\.\\./.test(n.textContent); },
};`;

// ---------- starting servers ----------
function freePort() {
  return new Promise((r) => { const s = net.createServer(); s.listen(0, "127.0.0.1", () => { const p = s.address().port; s.close(() => r(p)); }); });
}
async function waitHttp(url, ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) { try { const r = await fetch(url); if (r.status < 500) return; } catch (e) { /* not up yet */ } await sleep(150); }
  throw new Error("server did not start: " + url);
}
const kids = [];
const serveErr = {}; // tail of each account server's stderr (printed on failure to debug server-side errors)
async function stopKids() { // wait for Chrome to really exit before deleting the temp directory (it keeps writing the profile until then)
  await Promise.all(kids.map((k) => new Promise((r) => { if (k.exitCode !== null || k.signalCode) return r(); k.once("exit", r); k.kill(); setTimeout(r, 3000); })));
}
function startServe(data, account, port, pets) {
  const p = spawn(PY, ["-I", join(HERE, "serve.py"), "--data", data, "--web", WEB, "--port", String(port), "--account", account, ...(pets ? ["--pets", pets] : [])],
    { stdio: ["ignore", "ignore", "pipe"] });
  let err = "";
  p.stderr.on("data", (d) => { err = (err + d).slice(-20000); });
  serveErr[account + ":" + port] = () => err;
  p.on("exit", (c) => { if (c) console.error("serve.py(" + account + ") exited with " + c + "\n" + err.slice(-2000)); });
  kids.push(p);
  return p;
}

// ---------- CDP ----------
class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pend = new Map(); this.on = new Map();
    ws.addEventListener("message", (e) => {
      const m = JSON.parse(e.data);
      if (m.id && this.pend.has(m.id)) { const [ok, no] = this.pend.get(m.id); this.pend.delete(m.id); m.error ? no(new Error(m.error.message)) : ok(m.result); }
      else if (m.method) { const f = this.on.get(m.sessionId || ""); if (f) f(m); }
    });
  }
  send(method, params = {}, sessionId) {
    return new Promise((ok, no) => { const i = ++this.id; this.pend.set(i, [ok, no]); this.ws.send(JSON.stringify(sessionId ? { id: i, method, params, sessionId } : { id: i, method, params })); });
  }
}

// ---------- GIF feature wall recording (--record <dir>) ----------
// node run.mjs --record /tmp/soulchat-gif [--only soulchat-knock,...] [--langs en,hans]
// Only uses the fictional gen_readme.py fixture (rec variant) and demo pets (RC_PETS_DIR). Per scenario and language: fresh fixture + one serve.py + one Chrome page.
// Frames come from a Page.captureScreenshot loop (screencast only gives CSS pixels), are resampled to a constant fps and written as <dir>/<lang>/frames/<name>/f0001.png; encode_media.py then makes the gif / mp4.
// The live parts (answering a card, tools finishing, the read tick) are driven by really appending lines to the fixture's transcript jsonl / snapshot.json, as the Mac side would.
const REC_DIR = opt("--record") ? resolve(opt("--record")) : "";
const REC_FOLDER = { en: "en", hans: "zh-Hans", hant: "zh-Hant" };
const REC_GEN = { en: "en", hans: "zh-Hans", hant: "zh-Hant" };
const REC_LIB = `window.rec = {
  // tap: ripple at the element centre, then click it
  tap(sel) {
    const e = typeof sel === "string" ? document.querySelector(sel) : sel;
    if (!e) throw new Error("rec.tap: not found " + sel);
    const r = e.getBoundingClientRect(), x = r.left + r.width / 2, y = r.top + r.height / 2;
    const d = document.createElement("div");
    d.style.cssText = "position:fixed;z-index:99999;pointer-events:none;width:44px;height:44px;border-radius:50%;background:rgba(255,255,255,.55);left:" + (x - 22) + "px;top:" + (y - 22) + "px;transition:transform .45s ease-out,opacity .45s ease-out;transform:scale(.4);opacity:1";
    document.body.appendChild(d);
    requestAnimationFrame(() => requestAnimationFrame(() => { d.style.transform = "scale(1.5)"; d.style.opacity = "0"; }));
    setTimeout(() => d.remove(), 600);
    e.click();
  },
  async type(sel, text, ms) {
    const e = document.querySelector(sel); e.focus();
    for (const ch of text) { e.value += ch; e.dispatchEvent(new Event("input", { bubbles: true })); await new Promise((r) => setTimeout(r, ms || 35)); }
  },
};`;
const nowIso = () => new Date().toISOString();
function recAppend(file, rows) { appendFileSync(file, rows.map((r) => JSON.stringify(r)).join("\n") + "\n"); }
const recA = (blocks) => ({ type: "assistant", message: { role: "assistant", content: blocks, model: "claude-sonnet-5-5" }, timestamp: nowIso(), isSidechain: false });
const recTool = (name, input, id) => ({ type: "tool_use", id, name, input });
const recRes = (id, extra) => Object.assign({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content: "ok" }] }, timestamp: nowIso(), isSidechain: false }, extra || {});
function recSnap(file, fn) { const j = JSON.parse(readFileSync(file, "utf8")); fn(j); writeFileSync(file + ".tmp", JSON.stringify(j)); renameSync(file + ".tmp", file); }

// spec: wide = desktop 1440x900 (dpr 1) otherwise phone 390x844 (dpr 2); dur ms; fps; run(ctx) = timeline, ctx: { ev(js), sleep, fx (gen_readme json), lang, L(en,hans,hant) }
const REC_SCEN = [
  // knock: 6 s = two full 3 s knock cycles, so the loop is seamless whatever the start phase
  { name: "soulchat-knock", dur: 6000, fps: 15, path: (fx) => "/", ready: `
      await rc.wait("#cr-msgs .cr-row.w", 8000, "waiting rows"); await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").length >= 4, 8000, "rings"); await rc.sleep(1500);`,
    run: async () => {} },
  // reply: tap into the chat, tick two options, write a note, submit, the card turns answered, follow-up message gets the read tick
  { name: "soulchat-reply", dur: 8000, fps: 15, path: () => "/", ready: `
      await rc.wait("#cr-msgs .cr-row.w", 8000, "waiting rows"); await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").length >= 4, 8000, "rings"); await rc.sleep(1200);
      rc.stubSend(() => "done", 150);`,
    run: async (c) => {
      const { ev, sleep, fx, L } = c, tr = fx.transcripts.redesign;
      await sleep(500); await ev(`rec.tap("#cr-msgs .cr-row.w[data-id='${fx.ids.redesign}']")`);
      await ev(`await rc.wait("#list .ask.live .opt", 8000, "card")`); await sleep(500);
      await ev(`rec.tap(rc.qa("#list .ask.live .opts > button.opt")[0])`); await sleep(450);
      await ev(`rec.tap(rc.qa("#list .ask.live .opts > button.opt")[1])`); await sleep(450);
      await ev(`rec.tap("#list .ask.live .own-row")`);
      await ev(`await rec.type("#list .ask.live .own-row input", ${JSON.stringify(L("and keep the FAQ short", "FAQ 要简短些", "FAQ 要簡短些"))}, 40)`); await sleep(250);
      await ev(`rec.tap("#list .ask.live .ask-go button.go")`);
      await sleep(250);
      const q = fx.ask, a = L("Hero banner, Feature cards, and keep the FAQ short", "首屏横幅, 功能卡片, FAQ 要简短些", "主視覺橫幅, 功能卡片, FAQ 要簡短些");
      recAppend(tr, [recRes("toolu_ask", { toolUseResult: { answers: { [q]: a } } })]);
      recSnap(fx.snapshot, (j) => { const s = j.sessions.find((x) => x.id === fx.ids.redesign); s.status = "busy"; s.waitingFor = ""; s.summary = ""; delete s.summaryCode; delete s.summaryArgs; });
      await sleep(900);
      const msg = L("Great, go ahead.", "很好，继续吧。", "很好，繼續吧。");
      await ev(`await rec.type("#reply", ${JSON.stringify(msg)}, 40)`); await sleep(200);
      await ev(`rec.tap("#btn-send")`);
      await sleep(900);
      recAppend(tr, [{ type: "user", message: { role: "user", content: msg }, timestamp: nowIso(), isSidechain: false }]);
    } },
  // tools: the agent runs three tools in a row; the figure climbs onto the bubble, works, celebrates and jumps down
  { name: "soulchat-tools", dur: 8000, fps: 15, path: (fx) => "/#s/" + fx.ids.sync, ready: `
      await rc.wait("#list .cg", 8000, "chat"); await rc.sleep(1500);`,
    run: async (c) => recTools(c) },
  // knock-close: top 3 list rows only, device scale 3, virtual time: every frame is rendered with the page animations paused at t = i / fps (so the fps is exact whatever the load).
  // Infinite animations are retimed to a whole number of cycles in the 6 s loop (knock 3 s = 2 cycles; the 5.6 s errand walk -> 6 s, a 7% change), the clock and polling are frozen, so the last frame leads into the first
  { name: "soulchat-knock-close", gen: "kc", dur: 3000, fps: 15, dpr: 3, virtual: true, retime: false, knockLead: 150, path: () => "/", ready: `
      await rc.wait("#cr-msgs .cr-row.w", 8000, "waiting rows"); await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").length >= 4, 8000, "rings");
      await rc.wait("#cr-msgs .fxw-track .cr-spr .pet", 8000, "walking pet on the unzoned busy row"); await rc.sleep(1500);`,
    crop: `const r = rc.qa("#cr-msgs .cr-row").slice(0, 3), a = r[0].getBoundingClientRect(), z = r[2].getBoundingClientRect();
      return { x: 0, y: Math.floor(a.top) - 8, width: 390, height: Math.ceil(z.bottom) - Math.floor(a.top) + 8 };`,
    run: async () => {} },
  // zone-fx: four busy sessions, one per zone (marquee / circuit / halo / orbit); gen_readme.py fxz variant; virtual time, no retiming (the effects run at their own speed), starts mid-action
  { name: "soulchat-zone-fx", gen: "fxz", dur: 3500, fps: 15, dpr: 3, virtual: true, retime: false, path: () => "/", ready: `
      await rc.wait(() => rc.qa("#cr-msgs li.fx").length >= 4, 8000, "four zone-effect rows"); await rc.sleep(2000);`,
    crop: `const r = rc.qa("#cr-msgs li.fx").slice(0, 4), a = r[0].getBoundingClientRect(), z = r[3].getBoundingClientRect();
      return { x: 0, y: Math.floor(a.top) - 6, width: 390, height: Math.ceil(z.bottom) - Math.floor(a.top) + 12 };`,
    run: async () => {} },
  // agents-flip: the sub-agent bubble flips to its back (cards), holds, a tap on the blank footer flips it back; real time, once. gen_readme.py flip variant. Crop: one message above, the bubble, one below (height measured once with the back showing)
  { name: "soulchat-agents-flip", gen: "flip", dur: 3800, fps: 15, dpr: 3, follow: true, path: (fx) => "/#s/" + fx.ids.sync, ready: `
      await rc.wait("#list .ag-flip", 8000, "flippable sub-agent bubble"); await rc.sleep(1500);
      const w0 = document.querySelector("#list .ag-flip"), all0 = [...document.querySelectorAll("#list .m")], pv0 = all0[all0.indexOf(w0) - 1];
      pv0.scrollIntoView({ block: "start" }); await rc.sleep(300);
      const sc = document.querySelector("#msgs") || document.scrollingElement; sc.scrollTop -= 14; await rc.sleep(500);`,
    crop: `const w = rc.q("#list .ag-flip"), all = rc.qa("#list .m"), i = all.indexOf(w), pv = all[i - 1], nx = w.closest(".cg");
      if (!pv || !nx) throw new Error("crop: neighbours missing " + all.map((x) => x.className.slice(0, 20)).join(" | "));
      if (window.__cropH === undefined) {
        w.click(); await rc.sleep(700); const b = nx.getBoundingClientRect(), p = pv.getBoundingClientRect(); window.__cropH = Math.ceil(b.bottom - p.top) + 44;
        rc.q("#list .ag-flip .ag-ft").click(); await rc.sleep(700);
      }
      const y = Math.floor(pv.getBoundingClientRect().top) - 30;
      return { x: 0, y, width: 390, height: Math.min(window.__cropH, Math.floor(innerHeight - y)) };`,
    run: async (c) => {
      const { ev, sleep } = c;
      await sleep(500); await ev(`rec.tap("#list .ag-flip")`);
      await sleep(1900); await ev(`rec.tap("#list .ag-flip .ag-ft")`);
    } },
  // tools-close: last 3 chat groups only, real time; one tool runs, the figure climbs on the working bubble, finishes, jumps down and parks; the parked figure then fades out so the last frame equals the first
  { name: "soulchat-tools-close", dur: 9000, fps: 15, speed: 2, dpr: 3, follow: true, pre: ({ fx, L }) => { recSnap(fx.snapshot, (j) => { j.sessions.find((x) => x.id === fx.ids.sync).status = "idle"; }); recAppend(fx.transcripts.sync, [recA([{ type: "text", text: L("Checking the docs.", "正在检查文档。", "正在檢查文件。") }])]); }, path: (fx) => "/#s/" + fx.ids.sync, ready: `
      await rc.wait("#list .cg", 8000, "chat"); await rc.sleep(1500);`,
    crop: `const g = rc.qa("#list > .cg").slice(-2), a = g[0].getBoundingClientRect(), z = g[g.length - 1].getBoundingClientRect();
      return { x: 0, y: Math.floor(a.top) - 4, width: 390, height: Math.ceil(z.bottom) - Math.floor(a.top) + 46 };`,
    run: async (c) => {
      // one action, original speed: the tool starts, the figure climbs on the working bubble, works, the check mark, jumps down; ends 0.4 s after it has parked
      const { ev, sleep, fx, L } = c, tr = fx.transcripts.sync, T = Date.now();
      await sleep(300);
      let seen = 0; const poll = (async () => { while (!seen) { const v = await ev(`return !!document.querySelector("#msgs .figs .fg:not(.fg-hide)")`); if (v) seen = Date.now(); else await sleep(40); } })();
      recAppend(tr, [recA([recTool("Bash", { command: "make docs-check", description: L("Check the docs build", "检查文档构建", "檢查文件建置") }, "toolu_c1")])]);
      await sleep(+(process.env.RC_TOOL_MS || 300)); recAppend(tr, [recRes("toolu_c1")]);
      await sleep(+(process.env.RC_PRE_MS || 500));
      for (let i = 0, last = "", same = 0; i < 60 && same < 3; i++) {
        const r = await ev(`const e = document.querySelector("#msgs .figs .fg:not(.fg-hide)"); if (!e) return ""; const b = e.getBoundingClientRect(); return Math.round(b.left) + "," + Math.round(b.top) + "," + e.className;`);
        same = r && r === last && /fg-landed/.test(r) && /fg-done/.test(r) ? same + 1 : 0; last = r; await sleep(150);
      }
      await sleep(300);
      await poll;
      return { dur: Date.now() - T, from: Math.max(0, seen - T - 350) };
    } },
  { name: "soulchat-desktop", wide: true, desk: true, dur: 8000, fps: 12, path: (fx) => "/#s/" + fx.ids.sync, ready: `
      await rc.wait("#list .cg", 8000, "chat"); await rc.wait("#cr-msgs .cr-row.w", 8000, "rows"); await rc.sleep(1500);`,
    run: async (c) => recTools(c),
    still: { path: (fx) => "/#s/" + fx.ids.redesign, ready: `await rc.wait("#list .ask.live .opt", 8000, "card"); await rc.sleep(1500);
      for (const r of rc.qa("#cr-msgs .cr-row.w")) for (const a of r.querySelector(".cr-av > .cr-clip").getAnimations()) { a.pause(); const d = a.effect.getTiming().delay || 0; a.currentTime = ((120 + d) % 3000 + 3000) % 3000; }` } },
  { name: "soulchat-iphone-still", dpr: 3, still: { path: () => "/", ready: `
      await rc.wait("#cr-msgs .cr-row.w", 8000, "waiting rows"); await rc.wait(() => rc.qa("#cr-msgs .cr-cx b").length >= 4, 8000, "rings"); await rc.sleep(1500);
      for (const r of rc.qa("#cr-msgs .cr-row.w")) for (const a of r.querySelector(".cr-av > .cr-clip").getAnimations()) { a.pause(); const d = a.effect.getTiming().delay || 0; a.currentTime = ((120 + d) % 3000 + 3000) % 3000; }` } },
];
async function recTools(c) {
  const { sleep, fx, L } = c, tr = fx.transcripts.sync, HP = "/Users/demo/projects/sync/";
  await sleep(400);
  recAppend(tr, [recA([{ type: "text", text: L("Let me read the current API reference first.", "我先读一下现有的接口文档。", "我先讀一下現有的 API 文件。") },
    recTool("Read", { file_path: HP + "docs/api.md" }, "toolu_t1")])]);
  await sleep(1800); recAppend(tr, [recRes("toolu_t1")]);
  recAppend(tr, [recA([recTool("Grep", { pattern: "endpoint", path: "docs" }, "toolu_t2")])]);
  await sleep(1500); recAppend(tr, [recRes("toolu_t2")]);
  recAppend(tr, [recA([recTool("Edit", { file_path: HP + "docs/api.md", old_string: "a", new_string: "b" }, "toolu_t3")])]);
  await sleep(1500); recAppend(tr, [recRes("toolu_t3")]);
  recAppend(tr, [recA([recTool("Bash", { command: "make docs-check", description: L("Check the docs build", "检查文档构建", "檢查文件建置") }, "toolu_t4")])]);
  await sleep(1500); recAppend(tr, [recRes("toolu_t4")]);
}

async function record() {
  const names = REC_SCEN.map((s) => s.name).filter((n) => !ONLY || ONLY.includes(n));
  if (!names.length) throw new Error("no recording scenario selected (names: " + REC_SCEN.map((s) => s.name).join(", ") + ")");
  const pets = process.env.RC_PETS_DIR || "";
  if (!pets) throw new Error("set RC_PETS_DIR to the demo pets directory (otherwise every avatar is the built-in soulflame)");
  const tmp = mkdtempSync(join(tmpdir(), "render-check-rec-"));
  const dport = await freePort();
  const chrome = spawn(CHROME, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars",
    "--user-data-dir=" + join(tmp, "chrome"), "--remote-debugging-port=" + dport, "about:blank"], { stdio: "ignore" });
  kids.push(chrome);
  let wsUrl = "";
  for (let i = 0; i < 60 && !wsUrl; i++) { await sleep(200); try { wsUrl = (await (await fetch(`http://127.0.0.1:${dport}/json/version`)).json()).webSocketDebuggerUrl; } catch (e) { /* not up yet */ } }
  if (!wsUrl) throw new Error("Chrome did not start");
  const ws = new WebSocket(wsUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  const cdp = new Cdp(ws);
  let bad = 0;
  for (const lang of LANGS) {
    const out = join(REC_DIR, REC_FOLDER[lang]);
    for (const name of names) {
      const sc = REC_SCEN.find((s) => s.name === name);
      const rdata = join(tmp, "fx-" + lang + "-" + name);
      const gen = await new Promise((ok, no) => {
        const p = spawn(PY, ["-I", join(HERE, "gen_readme.py"), rdata, REC_GEN[lang], sc.gen || "rec", ...(sc.desk ? ["desk"] : [])], { stdio: ["ignore", "pipe", "inherit"] });
        let o = ""; p.stdout.on("data", (d) => { o += d; }); p.on("exit", (c) => (c ? no(new Error("gen_readme.py failed")) : ok(o)));
      });
      const fx = JSON.parse(gen.trim().split("\n").pop());
      const port = await freePort();
      const srv = startServe(rdata, "admin", port, pets);
      await waitHttp(`http://127.0.0.1:${port}/index.html`, 8000);
      const errs = [];
      try {
        const L = (...v) => v[{ en: 0, hans: 1, hant: 2 }[lang]];
        if (sc.dur) await recOne(cdp, lang, port, sc, { fx, L, out, errs, still: false });
        if (sc.still) await recOne(cdp, lang, port, sc, { fx, L, out, errs, still: true });
      } catch (e) { errs.push("run error: " + e.message); }
      console.log((errs.length ? "FAIL " : "ok   ") + lang.padEnd(4) + " " + name + (errs.length ? "\n       - " + errs.join("\n       - ") : ""));
      if (errs.length) bad++;
      srv.kill(); await new Promise((r) => { if (srv.exitCode !== null || srv.signalCode) return r(); srv.once("exit", r); setTimeout(r, 3000); });
    }
  }
  ws.close();
  await stopKids();
  rmSync(tmp, { recursive: true, force: true, maxRetries: 5 });
  process.exit(bad ? 1 : 0);
}

async function recOne(cdp, lang, port, sc, c) {
  const { fx, L, out, errs, still } = c;
  const spec = still ? sc.still : sc;
  const wide = !!sc.wide, dpr = still ? (sc.dpr || 2) : (wide ? 1 : sc.dpr || 2);
  const W = wide ? 1440 : 390, H = wide ? 900 : 844;
  const loc = { en: "en-US", hans: "zh-CN", hant: "zh-TW" }[lang];
  const { browserContextId } = await cdp.send("Target.createBrowserContext", { disposeOnDetach: true });
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank", browserContextId });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  const frames = [];
  const S = (m, p) => cdp.send(m, p, sessionId);
  cdp.on.set(sessionId, (m) => {
    const p = m.params || {};
    if (m.method === "Runtime.exceptionThrown") errs.push("uncaught exception: " + String(((p.exceptionDetails || {}).exception || {}).description || "").split("\n")[0]);
    else if (m.method === "Runtime.consoleAPICalled" && p.type === "error") errs.push("console.error: " + p.args.map((a) => a.value !== undefined ? String(a.value) : a.description || a.type).join(" ").slice(0, 300));
  });
  await S("Runtime.enable"); await S("Page.enable");
  await S("Emulation.setLocaleOverride", { locale: loc });
  if (wide) {
    await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: dpr, mobile: false });
    await S("Emulation.setUserAgentOverride", { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36", acceptLanguage: loc });
  } else {
    await S("Emulation.setDeviceMetricsOverride", { width: W, height: H, deviceScaleFactor: dpr, mobile: true });
    await S("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
    await S("Emulation.setUserAgentOverride", { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", acceptLanguage: loc });
  }
  await S("Page.addScriptToEvaluateOnNewDocument", { source: `try { localStorage.setItem("zbs.lang", ${JSON.stringify(lang)}); localStorage.setItem("zbs.tab", "msg"); } catch (e) {}\n` + RC_LIB + "\n" + REC_LIB });
  if (!still && sc.pre) sc.pre({ fx, L });   // fixture tweak before the page loads
  await S("Page.navigate", { url: `http://127.0.0.1:${port}${spec.path(fx)}` });
  await sleep(600);
  const ev = async (js) => {
    const r = await S("Runtime.evaluate", { expression: `(async () => { ${js} })()`, awaitPromise: true, returnByValue: true, timeout: 30000 });
    if (r.exceptionDetails) throw new Error("page script: " + String((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text).split("\n")[0]);
    return r.result.value;
  };
  await ev(spec.ready);
  const clip = !still && sc.crop ? await ev(sc.crop) : null;
  const body = await ev("return document.body.innerText");
  for (const g of GONE) if (String(body).includes(g)) errs.push("page shows '" + g + "'");
  if (/Failed|failed|失败|失敗/.test(await ev(`return (document.querySelector("#toast.show") || {}).textContent || ""`))) errs.push("an error toast is showing");
  if (still) {
    const shot = await S("Page.captureScreenshot", { format: "png" });
    mkdirSync(out, { recursive: true });
    writeFileSync(join(out, sc.name + (sc.dur ? "-still" : "") + ".raw.png"), Buffer.from(shot.data, "base64"));
  } else {
    if (sc.virtual) {
      const per = 1000 / sc.fps, n = Math.round(sc.dur / per);
      const info = await ev(`const F = Date.now(); Date.now = () => F; window.fetch = () => new Promise(() => {});
        const P = ${sc.dur}; window.__va = [];
        const kn = ${sc.knockLead !== undefined} ? document.getAnimations().filter((a) => a.animationName === "cr-knock") : [];
        const mods = kn.map((a) => (((a.effect.getTiming().delay || 0) % 3000) + 3000) % 3000).sort((x, y) => x - y);   // each row knocks in the first 15% of its 3 s cycle, after its own (negative) delay: start at the knock that follows the largest quiet gap
        let dmin = 0, gap = -1; for (let i = 0; i < mods.length; i++) { const g = (mods[i] - mods[(i + mods.length - 1) % mods.length] + 3000) % 3000 || 3000; if (g > gap) { gap = g; dmin = mods[i]; } }
        for (const a of document.getAnimations()) {
          const tm = a.effect && a.effect.getTiming(); if (!tm || tm.iterations !== Infinity || !(tm.duration > 0)) continue;
          const alt = String(tm.direction).startsWith("alternate") ? 2 : 1, per = tm.duration * alt, k = Math.max(1, Math.round(P / per));
          const t0 = a.currentTime; a.pause(); if (${sc.retime !== false}) a.effect.updateTiming({ duration: P / k / alt }); window.__va.push([a, kn.includes(a) ? 6000 + dmin - ${sc.knockLead || 0} : t0]);
        }
        window.__dbg = kn.map((a) => a.effect.getTiming().delay + '/' + a.effect.getTiming().duration + '/' + a.effect.target.parentElement.parentElement.className).join(' | ');
        return window.__va.length;`);
      if (process.env.RC_DBG) console.log(await ev('return window.__dbg'));
      if (!info) errs.push("no infinite animations found to drive");
      const fdir = join(out, "frames", sc.name.replace(/^soulchat-/, ""));
      rmSync(fdir, { recursive: true, force: true }); mkdirSync(fdir, { recursive: true });
      for (let i = 0; i < n; i++) {
        await ev(`for (const [a, t0] of window.__va) a.currentTime = t0 + ${i * per}; await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)));`);
        const r = await S("Page.captureScreenshot", clip ? { format: "png", clip: { ...clip, scale: 1 } } : { format: "png" });
        writeFileSync(join(fdir, "f" + String(i + 1).padStart(4, "0") + ".png"), Buffer.from(r.data, "base64"));
      }
      console.log(`       ${sc.name} ${lang}: ${n} virtual-time frames @${sc.fps}fps (${info} animations driven)`);
    } else {
    // Page.startScreencast only delivers CSS-pixel frames (390x844), so a loop of captureScreenshot (device pixels, 2x) is used instead; every frame is stamped with the middle of its capture call
    let tStart = 0;
    if (sc.lock) {  // real-time scenario: page animations outside the figure layer (typing dots, avatar frames) are retimed to whole cycles of the clip and driven from one clock, so the last frame leads into the first
      tStart = await ev(`const P = ${sc.dur}, T0 = performance.now(), E0 = Date.now() / 1000, done = new WeakSet();
        const tick = () => {
          const t = (performance.now() - T0) % P;
          for (const a of document.getAnimations()) {
            const tm = a.effect && a.effect.getTiming(); if (!tm || tm.iterations !== Infinity || !(tm.duration > 0)) continue;
            const el = a.effect.target; if (el && el.closest && el.closest(".figs")) continue;
            if (!done.has(a)) {
              const alt = String(tm.direction).startsWith("alternate") ? 2 : 1, k = Math.max(1, Math.round(P / (tm.duration * alt)));
              a.pause(); a.effect.updateTiming({ duration: P / k / alt }); done.add(a);
            }
            a.currentTime = P + (el && el.closest && el.closest(".ph-dots") ? 500 : t);   // + P: stay clear of the positive-delay "before" phase (typing dots 2 and 3) so every turn of the loop looks the same; the typing dots are held at one pose (their phase cannot be sampled exactly under load)
          }
          requestAnimationFrame(tick);
        };
        tick(); return E0;`);   // the page's own wall-clock reading of T0, so frame stamps and the animation clock share one origin
    }
    let go = true;
    const loop = (async () => {
      while (go) {
        let cl = clip;
        if (clip && sc.follow) { try { const c2 = await ev(sc.crop); cl = { ...clip, y: c2.y }; } catch (e) { /* keep the last clip */ } }   // follow: the crop keeps the same bubbles registered if the list shifts by a pixel
        const tA = Date.now();
        const r = await S("Page.captureScreenshot", cl ? { format: "png", optimizeForSpeed: true, clip: { ...cl, scale: 1 } } : { format: "png", optimizeForSpeed: true });
        frames.push({ ts: (tA + Date.now()) / 2000, data: r.data });   // the page is sampled somewhere inside the call: stamp the middle
      }
    })();
    const t0 = Date.now();
    const used = await sc.run({ ev, sleep, fx, lang, L });
    let from = 0;
    if (used && typeof used === "object") { sc.dur = used.dur; from = used.from || 0; }   // a timeline may return its own length (ms) and the start of the action: the clip runs from - to dur
    else if (typeof used === "number") sc.dur = used;
    const rest = (typeof used === "object" || typeof used === "number" ? 0 : sc.dur - (Date.now() - t0));
    if (rest > 0) await sleep(rest); else if (rest < 0 && !used) errs.push("timeline overran the duration by " + (-rest) + " ms");
    go = false;
    await loop;
    const fdir = join(out, "frames", sc.name.replace(/^soulchat-/, ""));
    rmSync(fdir, { recursive: true, force: true }); mkdirSync(fdir, { recursive: true });
    if (!frames.length) throw new Error("no screencast frames received");
    const sp = sc.speed || 1, n = Math.round((sc.dur - from) / 1000 * sc.fps / sp), ts0 = (tStart || frames[0].ts) + from / 1000;
    let k = 0;
    for (let i = 0; i < n; i++) {
      const t = ts0 + i * sp / sc.fps;
      while (k + 1 < frames.length && frames[k + 1].ts <= t) k++;
      writeFileSync(join(fdir, "f" + String(i + 1).padStart(4, "0") + ".png"), Buffer.from(frames[k].data, "base64"));
    }
    console.log(`       ${sc.name} ${lang}: ${frames.length} raw frames -> ${n} @${sc.fps}fps`);
  }
  }
  if (!still) { /* errors toast check after the timeline */
    const t = await ev(`return (document.querySelector("#toast.show") || {}).textContent || ""`);
    if (t) errs.push("toast visible at the end: " + t);
  }
  cdp.on.delete(sessionId);
  await cdp.send("Target.closeTarget", { targetId }).catch(() => {});
  await cdp.send("Target.disposeBrowserContext", { browserContextId }).catch(() => {});
}

async function main() {
  if (REC_DIR) return record();
  if (flag("--list")) { for (const s of SCEN) console.log(s.name + (s.account && s.account !== "admin" ? "  (guest " + s.account + ")" : "") + (s.needMd ? "  (needs --md)" : "")); return; }
  const tmp = mkdtempSync(join(tmpdir(), "render-check-"));
  const data = join(tmp, "fx");
  const gen = await new Promise((ok, no) => {
    const p = spawn(PY, ["-I", join(HERE, "gen.py"), data, ...(MD ? ["--md", MD] : [])], { stdio: ["ignore", "pipe", "inherit"] });
    let o = ""; p.stdout.on("data", (d) => { o += d; }); p.on("exit", (c) => (c ? no(new Error("gen.py failed")) : ok(o)));
  });
  Object.assign(IDS, JSON.parse(gen.trim().split("\n").pop()));
  const ports = { admin: await freePort(), guest: await freePort(), guest2: await freePort(), "readme-en": await freePort(), "readme-hans": await freePort(), "readme-hant": await freePort() }; // guest2: second guest; readme-*: README screenshot fixtures (one data set per language)
  startServe(data, "admin", ports.admin);
  startServe(data, "guest", ports.guest);
  startServe(data, "guest2", ports.guest2);
  await waitHttp(`http://127.0.0.1:${ports.admin}/index.html`, 8000);
  await waitHttp(`http://127.0.0.1:${ports.guest}/index.html`, 8000);
  await waitHttp(`http://127.0.0.1:${ports.guest2}/index.html`, 8000);

  if (SCEN.some((s) => s.readme && (!ONLY || ONLY.includes(s.name)))) { // separate fixtures for README screenshots, one per language (session content is generated per language)
    // Demo pets: RC_PETS_DIR points at build_pets.py's output directory (cut by petdex installed to a temporary HOME); without it the built-in soulflame is used
    const pets = process.env.RC_PETS_DIR || "";
    for (const [lg, gl] of [["en", "en"], ["hans", "zh-Hans"], ["hant", "zh-Hant"]]) {
      if (!LANGS.includes(lg)) continue;
      const rdata = join(tmp, "fx-readme-" + lg);
      const rg = await new Promise((ok, no) => {
        const p = spawn(PY, ["-I", join(HERE, "gen_readme.py"), rdata, gl], { stdio: ["ignore", "pipe", "inherit"] });
        let o = ""; p.stdout.on("data", (d) => { o += d; }); p.on("exit", (c) => (c ? no(new Error("gen_readme.py failed")) : ok(o)));
      });
      Object.assign(RIDS, JSON.parse(rg.trim().split("\n").pop()));
      startServe(rdata, "admin", ports["readme-" + lg], pets);
      await waitHttp(`http://127.0.0.1:${ports["readme-" + lg]}/index.html`, 8000);
    }
  }

  const dport = await freePort();
  const prof = join(tmp, "chrome");
  const chrome = spawn(CHROME, ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--hide-scrollbars",
    "--user-data-dir=" + prof, "--remote-debugging-port=" + dport, "about:blank"], { stdio: "ignore" });
  kids.push(chrome);
  let wsUrl = "";
  for (let i = 0; i < 60 && !wsUrl; i++) { await sleep(200); try { wsUrl = (await (await fetch(`http://127.0.0.1:${dport}/json/version`)).json()).webSocketDebuggerUrl; } catch (e) { /* not up yet */ } }
  if (!wsUrl) throw new Error("Chrome did not start");
  const ws = new WebSocket(wsUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  const cdp = new Cdp(ws);
  if (SHOTS) mkdirSync(SHOTS, { recursive: true });

  const scen = SCEN.filter((s) => (!ONLY || ONLY.includes(s.name)) && (!s.needMd || MD));
  if (!scen.length) throw new Error("no scenarios to run (typo in --only? see scenario names with --list)");
  const results = [];
  for (const lang of LANGS) {
    for (const s of scen) {
      if (s.langs && !s.langs.includes(lang)) continue; // screenshot-only scenario: one language is enough
      const r = await runOne(cdp, s, lang, ports[s.readme ? "readme-" + lang : s.account || "admin"]);
      results.push(r);
      const mark = r.fail.length ? "FAIL" : "ok  ";
      console.log(`${mark} ${lang.padEnd(4)} ${s.name}` + (r.fail.length ? "\n       - " + r.fail.join("\n       - ") : ""));
      if (VERBOSE) for (const l of r.notes) console.log("       · " + l);
    }
  }
  // Errors the frontend reports regardless of the switch (diagErr) land in the server's diag.jsonl: an err record also counts as a failure
  const dj = join(data, "state", "diag.jsonl");
  const allErr = existsSync(dj) ? readFileSync(dj, "utf8").split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch (e) { return null; } })
    .filter((x) => x && x.k === "err") : [];
  const allow = new Set(scen.map((s) => s.allowErr).filter(Boolean));
  const errs = allErr.filter((x) => !allow.has(x.where));
  // Deliberately triggered reports: they must really land in diag.jsonl, and the guest's must be tagged account=guest
  for (const s of scen.filter((x) => x.allowErr)) {
    const got = allErr.filter((x) => x.where === s.allowErr);
    console.log((got.length && (s.account !== "guest" || got.every((x) => x.account === "guest")) ? "ok  " : "FAIL") + " diag.jsonl received " + got.length + " report(s) from " + s.name);
    for (const x of got) console.log("       · " + JSON.stringify(x));
    if (!got.length || (s.account === "guest" && !got.every((x) => x.account === "guest"))) errs.push({ k: "err", where: s.allowErr, msg: "report not persisted or not tagged account=guest" });
  }
  if (errs.length) { console.log("FAIL /api/diag received " + errs.length + " frontend error report(s):"); for (const e of errs.slice(0, 20)) console.log("       - " + JSON.stringify(e).slice(0, 300)); }
  ws.close();
  await stopKids();
  if (!flag("--keep")) rmSync(tmp, { recursive: true, force: true, maxRetries: 5 }); else console.log("data directory kept at " + tmp);
  const bad = results.filter((r) => r.fail.length).length + (errs.length ? 1 : 0);
  if (bad) for (const [k, f] of Object.entries(serveErr)) { const e = f().trim(); if (e) console.log(`--- serve.py(${k}) stderr tail ---\n` + e.split("\n").slice(-15).join("\n")); }
  console.log(`\n${results.length} scenario run(s), ${results.length - results.filter((r) => r.fail.length).length} passed` + (bad ? `, ${bad} failed` : ", all passed") + ` (web=${WEB})`);
  process.exit(bad ? 1 : 0);
}

async function runOne(cdp, s, lang, port) {
  const { browserContextId } = await cdp.send("Target.createBrowserContext", { disposeOnDetach: true });
  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank", browserContextId });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });
  const fail = [], notes = [];
  const loc = { en: "en-US", hans: "zh-CN", hant: "zh-TW" }[lang] || "en-US";
  cdp.on.set(sessionId, (m) => {
    const p = m.params || {};
    if (m.method === "Runtime.exceptionThrown") {
      const d = p.exceptionDetails || {};
      fail.push("uncaught exception: " + String((d.exception && d.exception.description) || d.text).split("\n").slice(0, 3).join(" | ").slice(0, 400));
    } else if (m.method === "Runtime.consoleAPICalled" && (p.type === "error" || p.type === "assert")) {
      const msg = "console." + p.type + "：" + p.args.map((a) => a.value !== undefined ? String(a.value) : a.description || a.type).join(" ").split("\n").slice(0, 4).join(" | ").slice(0, 400);
      if (s.allowErr && msg.includes(s.allowErr)) notes.push("expected " + msg); else fail.push(msg);
    } else if (m.method === "Runtime.consoleAPICalled" && p.type === "warning") {
      notes.push("warn " + p.args.map((a) => a.value || a.description).join(" ").slice(0, 200));
    } else if (m.method === "Log.entryAdded" && p.entry.level === "error") {
      const e = p.entry;
      const url = e.url || "";
      // Resource load failures: attachments and 5xx count as failures; pet manifest 404 is expected (no pets); the rest are noted
      if (s.expectGone && /\/api\/file/.test(url) && / 404 /.test(e.text)) notes.push("expected " + e.text + " " + url);
      else if (/\/api\/file/.test(url) || / 5\d\d /.test(e.text)) fail.push("load failed: " + e.text + " " + url);
      else notes.push("log " + e.text + " " + url);
    }
  });
  const S = (m, p) => cdp.send(m, p, sessionId);
  await S("Runtime.enable");
  await S("Log.enable");
  await S("Page.enable");
  await S("Emulation.setLocaleOverride", { locale: loc });
  if (s.reduce) await S("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-motion", value: "reduce" }] });
  if (s.wide) {
    await S("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
    await S("Emulation.setUserAgentOverride", { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36", acceptLanguage: loc });
  } else {
    await S("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 2, mobile: true });
    await S("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 });
    await S("Emulation.setUserAgentOverride", { userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", acceptLanguage: loc });
  }
  await S("Page.addScriptToEvaluateOnNewDocument", { source:
    `try { localStorage.setItem("zbs.lang", ${JSON.stringify(lang)}); localStorage.setItem("zbs.tab", ${JSON.stringify(s.tab || "msg")}); } catch (e) {}\n` + RC_LIB });
  await S("Page.navigate", { url: `http://127.0.0.1:${port}${s.path()}` });
  try {
    await sleep(600);
    const r = await S("Runtime.evaluate", { expression: `(async () => { ${typeof s.run === "function" ? s.run() : s.run} })()`, awaitPromise: true, returnByValue: true, timeout: 30000 });
    if (r.exceptionDetails) fail.push("scenario script: " + String((r.exceptionDetails.exception && r.exceptionDetails.exception.description) || r.exceptionDetails.text).split("\n")[0]);
    else for (const x of (r.result.value && r.result.value.fail) || []) fail.push(x);
    await sleep(500);
    const txt = await S("Runtime.evaluate", { expression: "document.body.innerText", returnByValue: true });
    const body = String(txt.result.value || "");
    if (!s.expectGone) for (const g of GONE) if (body.includes(g)) fail.push("page shows '" + g + "'");
    if (SHOTS) {
      const shot = await S("Page.captureScreenshot", { format: "png" });
      writeFileSync(join(SHOTS, `${s.name}${TAG ? "-" + TAG : ""}-${lang}.png`), Buffer.from(shot.data, "base64"));
    }
  } catch (e) {
    fail.push("run error: " + e.message);
  }
  cdp.on.delete(sessionId);
  await cdp.send("Target.closeTarget", { targetId }).catch(() => {});
  await cdp.send("Target.disposeBrowserContext", { browserContextId }).catch(() => {});
  return { name: s.name, lang, fail, notes };
}

main().catch((e) => { console.error(e); for (const k of kids) k.kill(); process.exit(2); });
