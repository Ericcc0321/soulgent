"""render-check: generate a fully fictional test data set (snapshot, transcripts, subagents, search index, attachment files).
python3 -I gen.py <output dir> [--md some.md]   (--md: attach an extra external Markdown file for debugging real files; by default only the fictional samples in samples/ are used)

Sessions (names, paths and contents are all made up):
  CHAT  Web-render-demo   idle: tables/code blocks/quotes/lists/long text/single image/multiple images/all attachment kinds/filename tags in body/tool figure/subagent report/cross-session messages
  APPR  Ops-deploy-check  waiting for approval (last tool has no result)
  ASK   Docs-style-guide  waiting for an answer (AskUserQuestion has no result)
  BUSY  Infra-ci-matrix   busy, with one running subagent
  PEER  Ops-peer-relay    cross-session messages: one signed, one unsigned (old format)
  IMG   Web-image-inline  user-embedded images (base64 in the Claude Code transcript): the 1st is deliberately broken (shows the localized "file no longer exists" label with "Image 1"), the 2nd is fine
  NOTES Docs-readme-notes a question with previews + notes that was just answered
  BGRUN Ops-bg-run        idle, bgTasks=2 (no bgList), bgSince=10 minutes ago; the conversation has a run_in_background Bash followed by a full further round of chat
  BGHNG Ops-bg-hung       idle, bgTasks=1, bgStale=true (suspected hung), transcript as above
  BUSYBG OPS-busy-bg     busy + bgTasks=1 (with bgList); its zone OPS has the halo effect configured
  APIERR Web-api-err      idle, errorKind=rate_limit (quota exhausted, amber + CC's verbatim text), error later than last read -> red dot
  RETRY Infra-retrying    busy, retryAttempt=3/10 (amber "Retrying 3/10" notice)
  GONE  Docs-gone         disconnected (unexpected exit; row greyed, no red dot; stays out of the rest group even with since 7 hours ago)
  RCPT  Web-receipts      receipts: one read (blue double tick), one still queued (queue-operation enqueue, grey double tick); the sending stage is produced by the scenario stubbing fetch in the page
The guest is bound to CHAT. Prints one line of JSON: session ids and subagent ids."""
import base64
import json
import os
import shutil
import struct
import sys
import time
import zlib
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SAMPLES = os.path.join(HERE, "samples")
HOST = "/Users/demo/projects"  # "host path" recorded in transcripts; serve.py maps it to <output dir>/files via FILE_ROOTS

args = sys.argv[1:]
if not args:
    sys.exit("usage: gen.py <output dir> [--md file]")
OUT = os.path.abspath(args[0])
EXTRA_MD = args[args.index("--md") + 1] if "--md" in args else ""
MARK = os.path.join(OUT, ".render-check")  # only wipe directories we created: an existing directory without this marker is never touched
if os.path.exists(OUT):
    if not os.path.isfile(MARK):
        sys.exit("refusing to overwrite: %s exists and was not created by gen.py (no .render-check marker)" % OUT)
    shutil.rmtree(OUT)
DATA, PROJ, STATE, FILES = (os.path.join(OUT, d) for d in ("data", "projects", "state", "files"))
os.makedirs(OUT)
with open(MARK, "w") as f:
    f.write("render-check fixture\n")
for d in (DATA, PROJ, STATE, FILES, os.path.join(OUT, "outbox"), os.path.join(OUT, "uploads"),
          os.path.join(DATA, "textidx")):
    os.makedirs(d, exist_ok=True)

now = time.time()


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def sid(n):
    return "%08x-0000-4000-8000-%012x" % (0xc0ffee00 + n, n)


# ---------- attachment files ----------
def png(path, w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)
    body = (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(body)


def pdf(path):
    objs = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 100] /Contents 4 0 R >>"]
    stream = "BT /F1 12 Tf 20 50 Td (demo) Tj ET"
    objs.append("<< /Length %d >>\nstream\n%s\nendstream" % (len(stream), stream))
    out, offs = "%PDF-1.4\n", []
    for i, o in enumerate(objs, 1):
        offs.append(len(out))
        out += "%d 0 obj\n%s\nendobj\n" % (i, o)
    x = len(out)
    out += "xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1) + "".join("%010d 00000 n \n" % o for o in offs)
    out += "trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, x)
    with open(path, "w") as f:
        f.write(out)


DOCS = os.path.join(FILES, "web-render", "docs")
os.makedirs(DOCS, exist_ok=True)
for n in ("guide-tables.md", "notes.txt", "data.csv", "config.json", "report.html"):
    shutil.copy(os.path.join(SAMPLES, n), os.path.join(DOCS, n))
pdf(os.path.join(DOCS, "spec.pdf"))
for n in ("示例报表2026.xlsx", "示例文档.docx"):  # file-card download scenario: content is arbitrary, only the response headers matter
    with open(os.path.join(DOCS, n), "wb") as fh:
        fh.write(b"PK\x03\x04demo")
MEDIA = os.path.join(FILES, "web-render", "shots")
png(os.path.join(MEDIA, "wide.png"), 320, 180, (80, 128, 208))
png(os.path.join(MEDIA, "tall.png"), 120, 240, (224, 160, 64))
png(os.path.join(MEDIA, "a.png"), 64, 64, (64, 176, 160))
png(os.path.join(MEDIA, "b.png"), 64, 64, (200, 80, 120))
png(os.path.join(MEDIA, "c.png"), 64, 64, (140, 120, 220))
extra_line = ""
if EXTRA_MD:
    dst = os.path.join(DOCS, os.path.basename(EXTRA_MD))
    shutil.copy(EXTRA_MD, dst)
    extra_line = "\n\nExtra: %s/web-render/docs/%s" % (HOST, os.path.basename(EXTRA_MD))
# phone uploads (the only kind a guest can see): host /Users/demo/app/data/uploads -> <output dir>/uploads
UP = os.path.join(OUT, "uploads", "2026-01-01")
os.makedirs(UP, exist_ok=True)
shutil.copy(os.path.join(SAMPLES, "guide-tables.md"), os.path.join(UP, "memo.md"))
png(os.path.join(UP, "photo.png"), 200, 150, (90, 170, 90))
UPH = "/Users/demo/app/data/uploads/2026-01-01/"
D = HOST + "/web-render/docs/"
M = HOST + "/web-render/shots/"

# ---------- sessions ----------
ZONES = [
    {"code": "Web", "name": "Web", "color": "#5080D0", "order": 1, "lead": "Web-render-demo", "taskboard": {"mtime": now - 3600}},
    {"code": "Docs", "name": "Docs", "color": "#E0A040", "order": 2, "lead": "Docs-style-guide"},
    {"code": "Ops", "name": "Ops", "color": "#40B0A0", "order": 3, "lead": "Ops-deploy-check"},
    {"code": "Infra", "name": "Infra", "color": "#B070C0", "order": 4, "lead": "Infra-ci-matrix"},
    {"code": "OPS", "name": "OPS", "color": "#C05070", "order": 5, "fx": "halo"},
    {"code": "CIR", "name": "CIR", "color": "#50A0C0", "order": 6, "fx": "circuit"},  # circuit effect animates .cr-pin (jitter): checks that bg-running rows keep the avatar still
]
# (n, zone, plate, status, minutes_ago, summary, waitingFor, code, agents)
S = [
    (1, "Web", "render-demo", "idle", 3, "Rendered the guide; see attachments.", "", None, 0),
    (2, "Ops", "deploy-check", "waiting", 2, "", "permission prompt",
     ("wait.approve.run", {"command": "make deploy ENV=staging"}), 0),
    (3, "Docs", "style-guide", "waiting", 4, "", "input needed",
     ("wait.ask", {"question": "Which heading style should the guide use?"}), 0),
    (4, "Infra", "ci-matrix", "busy", 1, "Splitting the test matrix", "", None, 1),
    (5, "Ops", "peer-relay", "idle", 30, "Relayed the note.", "", None, 0),
    (6, "Web", "image-inline", "idle", 50, "Looked at the screenshots.", "", None, 0),
    (7, "Web", "receipts", "idle", 4, "Checked the build.", "", None, 0),
    # Codex / WorkBuddy badges; WorkBuddy in error (summaryCode state.error, label replaces the summary)
    (8, "Web", "codex-lint", "idle", 6, "Lint is clean.", "", None, 0),
    (9, "Ops", "wb-report", "idle", 8, "出错", "", ("state.error", {}), 0),
    # question with previews + notes just answered (scenario ask-notes stubs it as waiting to reproduce "answered but still shown as asking")
    (10, "Docs", "readme-notes", "idle", 5, "Picked the README layout.", "", None, 0),
    # background expressions: bg-run (idle + 2 background), bg-hung (suspected hung), busy-bg (busy + 1 background, with bgList)
    # bg-run's since is deliberately 5 hours ago (bgSince is 10 minutes ago): a timer wrongly counting from since would show h:mm:ss, distinguishable from m:ss counted from bgSince
    (11, "Ops", "bg-run", "idle", 300, "Started the dev server.", "", None, 0),
    (12, "Ops", "bg-hung", "idle", 14, "Started the dev server.", "", None, 0),
    (13, "OPS", "busy-bg", "busy", 3, "Running tests while the server runs.", "", None, 0),
    # error / retrying / unexpected exit: api-err quota exhausted (error after the last read -> red dot), retrying in progress,
    # gone unexpected exit (since is deliberately 7 hours ago: without the gone rule it would fall into the rest group)
    (14, "Web", "api-err", "idle", 9, "You've hit your limit · resets 1pm", "",
     ("state.apiError", {"kind": "rate_limit", "status": 429, "text": "You've hit your limit · resets 1pm"}), 0),
    (15, "Infra", "retrying", "busy", 2, "正在重试 3/10", "", ("state.retrying", {"attempt": 3, "max": 10}), 0),
    (16, "Docs", "gone", "idle", 420, "意外退出", "", ("state.disconnected", {}), 0),
    # bg-calm: zone has an effect (OPS halo), idle + background running -> effect toned down one level (li carries fx-calm)
    (17, "OPS", "bg-calm", "idle", 30, "Started the dev server.", "", None, 0),
    # circ-bg / circ-busy: circuit-effect zone, idle + background running vs busy (avatar must be still vs animated)
    (18, "CIR", "circ-bg", "idle", 31, "Started the dev server.", "", None, 0),
    (19, "CIR", "circ-busy", "busy", 4, "Working.", "", None, 0),
]
ERR_FIELDS = {
    14: {"errorKind": "rate_limit", "errorStatus": 429, "errorText": "You've hit your limit · resets 1pm", "errorSince": now - 5 * 60},
    15: {"retryAttempt": 3, "retryMax": 10},
    16: {"disconnected": True, "disconnectedSince": now - 3 * 60, "bgTasks": 0, "bgAgents": 0, "helpers": 0},
}
BG_FIELDS = {  # background fields (only busy-bg carries bgList; bg-run takes the no-bgList fallback path)
    11: {"bgTasks": 2, "bgAgents": 0, "bgSince": now - 600, "bgStale": False, "bgEndedAt": None, "bgOwned": True, "helpers": 2},
    17: {"bgTasks": 1, "bgAgents": 0, "bgSince": now - 600, "bgStale": False, "bgEndedAt": None, "bgOwned": True, "helpers": 1},
    18: {"bgTasks": 1, "bgAgents": 0, "bgSince": now - 600, "bgStale": False, "bgEndedAt": None, "bgOwned": True, "helpers": 1},
    12: {"bgTasks": 1, "bgAgents": 0, "bgSince": now - 3 * 3600, "bgStale": True, "bgEndedAt": None, "bgOwned": True, "helpers": 1},
    13: {"bgTasks": 1, "bgAgents": 0, "bgSince": now - 300, "bgStale": False, "bgEndedAt": None, "bgOwned": True, "helpers": 1,
         "bgList": [{"kind": "cmd", "desc": "npm run dev", "since": now - 300, "id": "bx13", "toolUseId": "toolu_bg13"}]},
}
KINDS = {8: "codex", 9: "workbuddy"}  # the rest are claude
sessions, seen, ids = [], {}, {}
for n, zone, plate, status, ago, summary, wf, code, agents in S:
    i = sid(n)
    ids[zone + "-" + plate] = i
    since = now - ago * 60
    projdir = "-Users-demo-projects-" + plate
    item = {"id": i, "kind": "claude", "model": "claude-sonnet-4-5", "name": zone + "-" + plate, "plate": plate,
            "project": plate, "cwd": HOST + "/" + plate, "zone": zone, "status": status, "since": since,
            "summary": summary, "waitingFor": wf, "transcript": projdir + "/" + i + ".jsonl", "origin": "user",
            "peer": "", "nameUntitled": False,
            "meta": {"model": "claude-sonnet-4-5", "effort": "high", "fast": False, "ctxPct": 20 + n * 10,
                     "ctxUsed": 40000 + n * 20000, "ctxWindow": 200000, "tps": None, "at": int(now)}}
    if n in KINDS:  # non-Claude sessions: no transcript file, no meta (shaped like a real dump)
        item["kind"] = KINDS[n]
        item["model"] = ""
        del item["transcript"], item["meta"]
    if agents:
        item["agents"] = agents
    if n in BG_FIELDS:
        item.update(BG_FIELDS[n])
    if n in ERR_FIELDS:
        item.update(ERR_FIELDS[n])
    if code:
        item["summaryCode"], item["summaryArgs"] = code
    sessions.append(item)
    seen[i] = since + 30
    os.makedirs(os.path.join(PROJ, projdir), exist_ok=True)


def u(text, t, **kw):
    return dict({"type": "user", "message": {"role": "user", "content": text}, "timestamp": iso(t), "isSidechain": False}, **kw)


def a(blocks, t):
    return {"type": "assistant", "message": {"role": "assistant", "content": blocks, "model": "claude-sonnet-4-5"},
            "timestamp": iso(t), "isSidechain": False}


def txt(t):
    return {"type": "text", "text": t}


def tool(name, inp, tid):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}


def res(tid, t, content="ok"):
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "content": content}]}, "timestamp": iso(t), "isSidechain": False}


def path_of(n):
    return os.path.join(PROJ, sessions[n - 1]["transcript"])


def write(n, rows, p=None):
    with open(p or path_of(n), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")


LONG = "\n\n".join(
    "第 %d 段：这是一段很长的说明文字，用来测试长回复的折行、滚动和渲染缓存。"
    "It mixes English words, `inline code`, **bold** and *italic* so every inline path is exercised. "
    "繁體字也放一些：檔案、設定、網路。" % k for k in range(1, 13))

RICH = """Here is the summary.

| Zone | Sessions | Status |
|---|:---:|---:|
| Web | 3 | **ok** |
| Docs | 2 | `waiting` |
| | empty first cell | t |

```python
def t(x):
    return x  # a local named t inside a code block
```

> Quote line one
> > nested quote with `code`

1. First
2. Second
   - nested bullet
   - another with [a link](https://example.com)
3. Third

---

Final line with ~~strike~~ and a bare URL https://example.com/a_b."""

AID = "a1b2c3d4e5f60718"
AID2 = "b2c3d4e5f6071829"
t0 = now - 40 * 60
rows = [u("Render the style guide and attach everything you produced.", t0),
        a([txt("Let me look at the files first.")], t0 + 10)]
for k, (name, inp) in enumerate([
        ("Bash", {"command": "ls docs", "description": "List docs"}),
        ("Read", {"file_path": D + "guide-tables.md"}),
        ("Grep", {"pattern": "table", "path": "docs"}),
        ("Edit", {"file_path": D + "notes.txt", "old_string": "a", "new_string": "b"})]):
    tu = "toolu_c%02d" % k
    rows += [a([tool(name, inp, tu)], t0 + 20 + k * 5), res(tu, t0 + 22 + k * 5)]
rows.append(a([txt(RICH)], t0 + 60))
rows.append(a([txt(LONG)], t0 + 70))
rows.append(a([txt("Attachments:\n\n- Guide: " + D + "guide-tables.md\n- Notes: `" + D + "notes.txt`\n- Data: " + D +
                   "data.csv\n- Config: [config](" + D + "config.json)\n- Spec: " + D + "spec.pdf\n- Report: " +
                   D + "report.html\n- Sheet: " + D + "示例报表2026.xlsx\n- Word: " + D + "示例文档.docx" + extra_line)], t0 + 80))
rows.append(a([txt("One screenshot:\n\n![wide](" + M + "wide.png)")], t0 + 90))
rows.append(a([txt("Three more: " + M + "a.png " + M + "b.png " + M + "c.png and a tall one " + M + "tall.png")], t0 + 95))
# subagent: dispatch -> report
rows.append(a([txt("Sending a helper to check the links."),
               tool("Agent", {"description": "Check links", "subagent_type": "general-purpose", "model": "haiku",
                              "prompt": "Check every link in the guide and report broken ones."}, "toolu_agent1")], t0 + 100))
rows.append(res("toolu_agent1", t0 + 101, "Async agent launched"))
rows.append(u("<agent-message from=\"%s\">[Subagent hand-back] Check links. The report follows:\n"
              "  All **12 links** work.\n\n  | link | status |\n  |---|---|\n  | /a | 200 |\n  | /b | 200 |</agent-message>" % AID,
              t0 + 200, isMeta=True))
rows.append(u("<task-notification><task-id>%s</task-id><tool-use-id>toolu_agent1</tool-use-id><status>completed</status>"
              "<summary>Agent \"Check links\" completed</summary></task-notification>" % AID, t0 + 201, isMeta=True))
# cross-session messages
rows.append(u("<cross-session-message from=\"uds:/tmp/x\" from-name=\"Docs-style-guide\">Please use the **table** "
              "layout from the guide.\n\n| a | b |\n|---|---|\n| 1 | 2 |</cross-session-message>", t0 + 210, isMeta=True))
rows.append(u("[Guest] Here are my notes " + UPH + "memo.md and a photo " + UPH + "photo.png", t0 + 215))
rows.append(a([txt("Done. Everything is attached above.")], t0 + 220))
write(1, rows)
sub = os.path.join(path_of(1)[:-6], "subagents")
os.makedirs(sub)
with open(os.path.join(sub, "agent-%s.meta.json" % AID), "w") as f:
    json.dump({"agentType": "general-purpose", "description": "Check links", "toolUseId": "toolu_agent1",
               "spawnDepth": 1, "model": "haiku", "finished": True}, f)
write(0, [
    {"parentUuid": None, "isSidechain": True, "agentId": AID, "type": "user",
     "message": {"role": "user", "content": "Check every link in the guide and report broken ones."}, "timestamp": iso(t0 + 102)},
    {"parentUuid": "x", "isSidechain": True, "agentId": AID, "type": "assistant", "timestamp": iso(t0 + 110),
     "message": {"model": "claude-haiku", "id": "m1", "type": "message", "role": "assistant", "content": [
         {"type": "text", "text": "Checking.\n\n| link | status |\n|---|---|\n| /a | 200 |\n\n```sh\ncurl -I /a\n```"},
         {"type": "tool_use", "id": "ts1", "name": "Bash", "input": {"description": "Fetch links", "command": "curl"}}],
         "usage": {"input_tokens": 3, "output_tokens": 80}}},
    {"parentUuid": "y", "isSidechain": True, "agentId": AID, "type": "user", "timestamp": iso(t0 + 120),
     "message": {"role": "user", "content": [{"type": "tool_result", "tool_use_id": "ts1", "content": "ok"}]}},
    {"parentUuid": "z", "isSidechain": True, "agentId": AID, "type": "assistant", "timestamp": iso(t0 + 190),
     "message": {"model": "claude-haiku", "id": "m2", "type": "message", "role": "assistant", "content": [
         {"type": "text", "text": "All **12 links** work. See " + D + "notes.txt"}], "usage": {"input_tokens": 3, "output_tokens": 20}}},
], p=os.path.join(sub, "agent-%s.jsonl" % AID))

# APPR: trailing Bash has no result -> approval card
t2 = now - 5 * 60
write(2, [u("Deploy to staging when the checks pass.", t2),
          a([txt("Checks pass. Deploying now.")], t2 + 30),
          a([tool("Bash", {"command": "make deploy ENV=staging", "description": "Deploy to staging"}, "toolu_ap1")], t2 + 40)])
# ASK: AskUserQuestion has no result -> question card
t3 = now - 6 * 60
write(3, [u("Draft the style guide.", t3),
          a([tool("AskUserQuestion", {"questions": [
              {"question": "Which heading style should the guide use?", "header": "Headings", "multiSelect": False,
               "options": [{"label": "Sentence case", "description": "Only the first word capitalised"},
                           {"label": "Title Case", "description": "Every major word capitalised"}]},
              {"question": "Which sections to include?", "header": "Sections", "multiSelect": True,
               "options": [{"label": "Tables"}, {"label": "Code"}, {"label": "Images"}]}]}, "toolu_ask1")], t3 + 20)])
# BUSY: running subagent
t4 = now - 3 * 60
write(4, [u("Split the CI matrix.", t4),
          a([txt("Sending a helper."), tool("Agent", {"description": "Measure slow jobs", "subagent_type": "general-purpose",
                                                     "model": "haiku", "prompt": "Measure the slowest CI jobs."}, "toolu_agent2")], t4 + 10),
          res("toolu_agent2", t4 + 11, "Async agent launched"),
          a([tool("Bash", {"command": "make matrix", "description": "Build matrix"}, "toolu_b1")], t4 + 20)])
sub4 = os.path.join(path_of(4)[:-6], "subagents")
os.makedirs(sub4)
with open(os.path.join(sub4, "agent-%s.meta.json" % AID2), "w") as f:
    json.dump({"agentType": "general-purpose", "description": "Measure slow jobs", "toolUseId": "toolu_agent2",
               "spawnDepth": 1, "model": "haiku"}, f)
write(0, [{"parentUuid": None, "isSidechain": True, "agentId": AID2, "type": "user",
           "message": {"role": "user", "content": "Measure the slowest CI jobs."}, "timestamp": iso(t4 + 12)},
          {"parentUuid": "x", "isSidechain": True, "agentId": AID2, "type": "assistant", "timestamp": iso(t4 + 30),
           "message": {"model": "claude-haiku", "id": "m1", "type": "message", "role": "assistant", "content": [
               {"type": "tool_use", "id": "tb1", "name": "Bash", "input": {"description": "Time jobs", "command": "x"}}],
               "usage": {"input_tokens": 3, "output_tokens": 10}}}],
      p=os.path.join(sub4, "agent-%s.jsonl" % AID2))

# PEER: unsigned cross-session message (old format has only a prefix, no from-name); the name row must fall back to the localized "between sessions" label - a local variable shadowing the translation function triggers a TDZ error here and the whole page fails to render
t5 = now - 35 * 60
write(5, [u("Wait for the other session.", t5),
          u("Another Claude session sent a message:\nPing me when the guide is done.", t5 + 60, isMeta=True),
          u("<cross-session-message from=\"uds:/tmp/y\" from-name=\"Web-render-demo\">Guide is done.</cross-session-message>", t5 + 90, isMeta=True),
          a([txt("Relayed the note.")], t5 + 120)])

# IMG: embedded images are named by index (the backend supplies n, the frontend builds the localized "Image N" label)
png(os.path.join(OUT, "inline.png"), 160, 100, (210, 110, 60))
with open(os.path.join(OUT, "inline.png"), "rb") as f:
    INLINE = base64.b64encode(f.read()).decode()
t6 = now - 55 * 60
write(6, [u([{"type": "text", "text": "Two screenshots from my phone."},
             {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "bm90IGEgcG5n"}},
             {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": INLINE}}], t6),
          a([txt("The first one did not come through; the second looks fine.")], t6 + 30)])

# RCPT: one read + one queued (enqueue without dequeue/remove = still in the queue, read:false)
t7 = now - 6 * 60
write(7, [u("Please check the nightly build.", t7),
          a([txt("The nightly build is green.")], t7 + 20),
          {"type": "queue-operation", "operation": "enqueue", "timestamp": iso(t7 + 40), "sessionId": sid(7),
           "content": "Then tag the release candidate."}])

# NOTES: single-choice question with previews; the user picks option 2 and adds a note; tool_result follows the Claude Code 2.1.310 format (sample in tests/fixtures/ask_preview_notes.jsonl)
t10 = now - 8 * 60
QN = "How should the README be laid out?"
QN_OPTS = [{"label": "Product first", "description": "Screens first, story later", "preview": "# Soulgent\n[ GIF ]\n-- Features --"},
           {"label": "Story first", "description": "Author's note opens", "preview": "# Soulgent\n-- Why --\n[ GIF ]"}]
write(10, [u("Restructure the README.", t10),
           a([tool("AskUserQuestion", {"questions": [{"question": QN, "header": "README", "multiSelect": False,
                                                      "options": QN_OPTS}]}, "toolu_askn")], t10 + 20),
           {"type": "user", "isSidechain": False, "timestamp": iso(t10 + 60), "message": {"role": "user", "content": [
               {"type": "tool_result", "tool_use_id": "toolu_askn", "content":
                'The user answered: "%s"="Story first" selected preview:\n# Soulgent\n-- Why --\n[ GIF ] notes: Fold the story by default.. '
                'Read the answers carefully.' % QN}]},
            "toolUseResult": {"questions": [{"question": QN, "header": "README", "options": QN_OPTS, "multiSelect": False}],
                              "answers": {QN: "Story first"},
                              "annotations": {QN: {"preview": QN_OPTS[1]["preview"], "notes": "Fold the story by default."}}}}])

# background Bash (run_in_background) followed by a full further round of chat; the snapshot says the background is still running, so the figure should keep wandering
for n, tu, bx in ((11, "toolu_bg11", "bx11"), (12, "toolu_bg12", "bx12"), (13, "toolu_bg13", "bx13"), (17, "toolu_bg17", "bx17")):
    tb = now - 20 * 60
    write(n, [u("Start the dev server in the background.", tb),
              a([txt("Starting the dev server."), tool("Bash", {"command": "npm run dev", "description": "Dev server", "run_in_background": True}, tu)], tb + 10),
              {"type": "user", "isSidechain": False, "timestamp": iso(tb + 12), "message": {"role": "user", "content": [
                  {"type": "tool_result", "tool_use_id": tu, "content": "Command running in background with ID: " + bx}]},
               "toolUseResult": {"backgroundTaskId": bx, "stdout": "", "stderr": ""}},
              a([txt("The server is up.")], tb + 20),
              u("Thanks, anything else to check?", tb + 120),
              a([txt("Nothing else for now.")], tb + 130)])

# api-err (last entry is CC's synthetic error), retrying (user just spoke, retry in progress), gone (process exited unexpectedly after finishing)
t14 = now - 10 * 60
write(14, [u("Summarise yesterday's logs.", t14),
           a([txt("Reading the logs now.")], t14 + 20),
           {"type": "assistant", "isApiErrorMessage": True, "error": "rate_limit", "timestamp": iso(now - 5 * 60), "isSidechain": False,
            "message": {"role": "assistant", "model": "<synthetic>", "content": [txt("You've hit your limit · resets 1pm")]}}])
t15 = now - 3 * 60
write(15, [u("Rebuild the CI matrix.", t15)])
t16 = now - 425 * 60
write(16, [u("Draft the release notes.", t16), a([txt("Drafted the release notes.")], t16 + 60)])
# the api's own read state: install time is set one day back (by default it is the api start moment, newer than every session, so the red dot would never appear);
# read state still follows panel.seenAt (each session's since + 30 s); only api-err's error is later than it -> red dot
with open(os.path.join(STATE, "state.json"), "w") as f:
    json.dump({"installed_at": now - 86400, "seen": {}, "pins": [], "pinned_at": {}, "pin_changed": {}, "rest": {}, "unseen": {}}, f)
# upload records (a guest fetching uploads needs a record): the two the guest sent in Web-render-demo (#1)
with open(os.path.join(STATE, "uploads.json"), "w") as f:
    json.dump({"2026-01-01/" + n: {"account": "guest", "sids": [sid(1)], "at": now} for n in ("memo.md", "photo.png")}, f)

# off-duty sessions (opened via #o/, read-only): transcripts render as usual
OFFD = os.path.join(PROJ, "-Users-demo-projects-changelog")
os.makedirs(OFFD, exist_ok=True)
write(0, [u("Summarise the changelog.", now - 2 * 86400 - 600),
          a([txt("| version | notes |\n|---|---|\n| 0.4 | tables |\n\nDone.")], now - 2 * 86400 - 500)],
      p=os.path.join(OFFD, sid(20) + ".jsonl"))

# ---------- search index (same format as the helper's data/textidx) ----------
for n, rows_ in ((1, [("user", "Render the style guide and attach everything you produced."),
                      ("assistant", "Here is the summary. | Zone | Sessions | Status | table")]),
                 (3, [("user", "Draft the style guide.")])):
    with open(os.path.join(DATA, "textidx", sid(n) + ".jsonl"), "w", encoding="utf-8") as f:
        for k, (role, text) in enumerate(rows_):
            f.write(json.dumps({"seq": k, "ts": iso(now - 600 + k), "role": role, "text": text}, ensure_ascii=False) + "\n")
with open(os.path.join(DATA, "textidx", "_state.json"), "w") as f:
    json.dump({"v": 2, "owners": {}}, f)

# ---------- snapshot ----------
days = [{"day": datetime.fromtimestamp(now - (13 - k) * 86400).strftime("%Y-%m-%d"), "tokens": 1000000 + k * 50000}
        for k in range(14)]
snap = {
    "generatedAt": now,
    "usage": {"fiveHour": {"pct": 42, "resetsAt": int(now + 7200)}, "sevenDay": {"pct": 23, "resetsAt": int(now + 4 * 86400)}},
    "zones": ZONES, "sessions": sessions,
    "offduty": [{"name": "Docs-changelog", "sid": sid(20), "zone": "Docs", "lastActive": int(now - 2 * 86400),
                 "offAt": int(now - 2 * 86400 + 600), "transcript": "-Users-demo-projects-changelog/" + sid(20) + ".jsonl"}],
    "panel": {"seenAt": seen, "pinned": []},
    "orca": {"running": True},
    "orcaStats": {"agents": 12, "agentTimeMs": 40 * 3600 * 1000, "prs": 5, "firstEventAt": now - 30 * 86400,
                  "usage": {"totalTokens": sum(d["tokens"] for d in days), "costUsd": 0, "unpricedTokens": 0,
                            "activeDays": 14, "firstDay": days[0]["day"], "peakDay": days[-1], "days": days,
                            "byModel": [], "todayTokens": days[-1]["tokens"], "todayByProject": []}},
    "monitor": {"at": now, "orca": {"app": {"cpu": 6.5, "memory": 6.2e8}, "worktrees": [
        {"name": "render-demo", "repo": "web", "cpu": 3.1, "memory": 4.1e8, "terminals": 2}],
        "worktreeCount": 1, "worktreeMemory": 4.1e8, "worktreeCpu": 3.1, "totalCpu": 9.6, "totalMemory": 1.0e9},
        "mac": {"name": "Demo Mac", "pressure": "normal", "memTotal": 3.4e10, "memAvailable": 1.5e10,
                "mem": {"total": 34359738368, "app": 9e9, "wired": 3e9, "compressed": 1e9, "cached": 6e9, "used": 13e9},
                "cores": 10.0, "swap": {"total": 2e9, "used": 3e8}, "load": [2.1, 2.4, 2.2],
                "disk": {"free": 3.1e11, "total": 1e12}, "battery": {"pct": 84, "charging": False, "ac": True}}},
    "zoneTokens": {"byZone": {"Web": 1800000, "Docs": 650000, "Ops": 300000, "Infra": 1200000}, "unmatched": 0},
}
# zone task board (opened by clicking a zone on the board page): the api reads <snapshot dir>/taskboards/<code>.md
os.makedirs(os.path.join(DATA, "taskboards"), exist_ok=True)
with open(os.path.join(DATA, "taskboards", "Web.md"), "w", encoding="utf-8") as f:
    f.write("# Web 任务板\n\n| 编号 | 任务 | 状态 |\n|---|---|---|\n| W-1 | 拆分 app.js | 进行中 |\n| W-2 | 表格渲染回归 | ✓ |\n\n- [ ] 待办一\n- [x] 已完成\n")
with open(os.path.join(DATA, "snapshot.json"), "w", encoding="utf-8") as f:
    json.dump(snap, f, ensure_ascii=False)
print(json.dumps({"chat": sid(1), "approve": sid(2), "ask": sid(3), "busy": sid(4), "peer": sid(5), "img": sid(6), "rcpt": sid(7), "notes": sid(10), "bgrun": sid(11), "bghung": sid(12), "busybg": sid(13), "apierr": sid(14), "retrying": sid(15), "gone": sid(16), "bgcalm": sid(17), "circbg": sid(18), "circbusy": sid(19), "off": sid(20), "agent": AID, "agentBusy": AID2,
                  "guestSession": "Web-render-demo", "files": FILES, "host": HOST,
                  "extraMd": os.path.basename(EXTRA_MD) if EXTRA_MD else ""}))
