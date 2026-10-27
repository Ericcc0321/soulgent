"""Fictional data for README screenshots only (kept apart from gen.py so regression scenarios are unaffected).
python3 -I gen_readme.py <output dir> [en|zh-Hans|zh-Hant] [rec [desk]]
rec (GIF recording, run.mjs --record): the unanswered question becomes a multi-select one (tick several + a typed note), see REC below.
All sessions have made-up generic names: Web-redesign (star of the chat page: tool figure + question card with options), Ops-backup (waiting for approval), Docs-sync (busy), and so on.
Session content (messages/summaries/question cards) is produced in English / Simplified / Traditional Chinese (Taiwan usage) per the language argument; session and zone names are always English.
Avatars: each session is hard-wired to one demo pet id (list in PETS); serve.py --pets only accepts ids on that list. Prints one line of JSON: the session ids."""
import json
import os
import shutil
import sys
import time
from datetime import datetime, timezone

args = sys.argv[1:]
if not args:
    sys.exit("usage: gen_readme.py <output dir> [en|zh-Hans|zh-Hant] [rec [desk]]")
OUT = os.path.abspath(args[0])
LANG = args[1] if len(args) > 1 else "en"
if LANG not in ("en", "zh-Hans", "zh-Hant"):
    sys.exit("language must be en / zh-Hans / zh-Hant")
FXZ = len(args) > 2 and args[2] == "fxz"  # recording-only variant: one busy session in each of the four zones (zone effects GIF)
FLIP = len(args) > 2 and args[2] == "flip"  # recording-only variant: Docs-sync dispatched three sub-agents (one running, two done): the bubble is flippable
KC = len(args) > 2 and args[2] == "kc"  # recording-only variant (knock-close): Docs-sync belongs to no zone (no zone tag, no star) and stays busy, so its pet walks out along the name row
REC = len(args) > 2 and args[2] in ("rec", "fxz", "flip", "kc")
DESK = REC and len(args) > 3 and args[3] == "desk"  # desktop GIF: longer Docs-sync history and a few more idle sessions so the list and the chat pane both fill the 900 px height
MODEL = "claude-sonnet-5-5"
MODEL_OPUS = "claude-opus-5-5"
MARK = os.path.join(OUT, ".render-check")
if os.path.exists(OUT):
    if not os.path.isfile(MARK):
        sys.exit("refusing to overwrite: %s exists and was not created by render-check" % OUT)
    shutil.rmtree(OUT)
DATA, PROJ, STATE, FILES = (os.path.join(OUT, d) for d in ("data", "projects", "state", "files"))
os.makedirs(OUT)
with open(MARK, "w") as f:
    f.write("render-check fixture\n")
for d in (DATA, PROJ, STATE, FILES, os.path.join(OUT, "outbox"), os.path.join(OUT, "uploads"), os.path.join(DATA, "textidx")):
    os.makedirs(d, exist_ok=True)

now = time.time()
HOST = "/Users/demo/projects"


def iso(t):
    return datetime.fromtimestamp(t, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def sid(n):
    return "%08x-0000-4000-8000-%012x" % (0xabcd0000 + n, n)


def u(text, t):
    return {"type": "user", "message": {"role": "user", "content": text}, "timestamp": iso(t), "isSidechain": False}


def a(blocks, t):
    return {"type": "assistant", "message": {"role": "assistant", "content": blocks, "model": MODEL},
            "timestamp": iso(t), "isSidechain": False}


def txt(t):
    return {"type": "text", "text": t}


def tool(name, inp, tid):
    return {"type": "tool_use", "id": tid, "name": name, "input": inp}


def res(tid, t, content="ok"):
    return {"type": "user", "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": tid, "content": content}]}, "timestamp": iso(t), "isSidechain": False}


ZONES = [
    {"code": "Web", "name": "Web", "color": "#5080D0", "fx": "orbit", "order": 1, "lead": "Web-redesign", "taskboard": {"mtime": now - 3600}},
    {"code": "Docs", "name": "Docs", "color": "#E0A040", "fx": "marquee", "order": 2, "lead": "Docs-sync"},
    {"code": "Ops", "name": "Ops", "color": "#40B0A0", "fx": "halo", "order": 3, "lead": "Ops-backup"},
    {"code": "Infra", "name": "Infra", "color": "#B070C0", "fx": "circuit", "order": 4, "lead": "Infra-ci"},
]
# Per-language session content (session and zone names are not here; always English). Index = language.
L = {"en": 0, "zh-Hans": 1, "zh-Hant": 2}[LANG]


def X(*v):
    return v[L]


# Demo pets (id must be on serve.py's DEMO_PETS list; every session has its own list pet, never soulflame). plate -> pet id
# Zones carry an fx (marquee / circuit / halo / orbit) like real zones, so busy rows show a zone effect instead of walking out of the avatar frame
PETS = {"redesign": "prompt-penguin", "backup": "blue-boba-axolotl", "sync": "whaley", "ci": "octopus",
        "landing": "little-deer", "guide": "boxcat", "reports": "red-panda",
        "api": "cloudlet", "mobile": "byte-bunny", "audit": "cream-cat"}
Q_LAYOUT = X("Which layout should the landing page use?", "落地页应该用哪种布局？", "登陸頁應該用哪種版面配置？")
if REC:  # multi-select variant for the reply GIF: tick options and type a note into the "add more" row
    Q_LAYOUT = X("Which sections should the landing page keep?", "落地页要保留哪些板块？", "登陸頁要保留哪些區塊？")
# (n, zone, plate, status, minutes_ago, summary, waitingFor, code, ctxPct)
S = [
    (1, "Web", "redesign", "waiting", 2, "", X("input needed", "需要你回答", "需要你回答"),
     ("wait.ask", {"question": Q_LAYOUT}), 62),
    (2, "Ops", "backup", "waiting", 4, "", X("permission prompt", "等待授权", "等待授權"),
     ("wait.approve.run", {"command": "make backup ENV=staging"}), 87),
    (3, "Docs", "sync", "busy", 1, X("Syncing the API reference", "正在同步接口文档", "正在同步 API 文件"), "", None, 41),
    (4, "Infra", "ci", "idle", 6, X("All 48 checks passed.", "48 项检查全部通过。", "48 項檢查全部通過。"), "", None, 19),
    (5, "Web", "landing", "idle", 22, X("Compressed the hero images.", "已压缩首屏图片。", "已壓縮主視覺圖片。"), "", None, 9),
    (6, "Docs", "guide", "idle", 55, X("Drafted the setup guide.", "已起草安装指南。", "已起草安裝指南。"), "", None, 33),
    (7, "Ops", "reports", "idle", 130, X("Weekly report is ready.", "周报已经备好。", "週報已經備好。"), "", None, 27),
]
if DESK:  # three more idle sessions (kept within the recent hours so they are not folded into the "rest" row)
    S += [(8, "Web", "api", "idle", 75, X("Mapped the new endpoints.", "已梳理新接口。", "已梳理新介面。"), "", None, 14),
          (9, "Docs", "mobile", "idle", 85, X("Checked the mobile layout.", "已检查移动端布局。", "已檢查行動版版面。"), "", None, 22),
          (10, "Ops", "audit", "idle", 95, X("Audit log exported.", "审计日志已导出。", "稽核日誌已匯出。"), "", None, 31)]
if FXZ:  # Web-redesign, Ops-backup, Infra-ci become busy (Docs-sync already is); the question / approval cards are not needed here
    BUSY = {"redesign": X("Reworking the landing layout", "正在调整落地页布局", "正在調整登陸頁版面"),
            "backup": X("Running the staging backup", "正在执行预发布备份", "正在執行預備環境備份"),
            "ci": X("Running the CI checks", "正在运行 CI 检查", "正在執行 CI 檢查")}
    S = [(n, z, p_, "busy", ago if n != 1 else 1, BUSY[p_], "", None, c) if p_ in BUSY else (n, z, p_, st, ago, sm, wf, cd, c)
         for n, z, p_, st, ago, sm, wf, cd, c in S]
if KC:  # unzoned: not in the zones table, so busyFx picks the walk mode; the old Docs lead no longer exists
    S = [(n, "", p_, st, ago, sm, wf, cd, c) if p_ == "sync" else (n, z, p_, st, ago, sm, wf, cd, c) for n, z, p_, st, ago, sm, wf, cd, c in S]
    PETS["sync"] = "cream-cat"  # side-view running frames on row 7; serve.py DEMO_CAPS marks it as able to walk (the audit row that also uses it only exists in the desk variant)
    for z in ZONES:
        if z["code"] == "Docs":
            z["lead"] = "Docs-guide"
sessions, seen, ids = [], {}, {}
for n, zone, plate, status, ago, summary, wf, code, ctx in S:
    i = sid(n)
    ids[plate] = i
    since = now - ago * 60
    projdir = "-Users-demo-projects-" + plate
    mdl = MODEL_OPUS if n in (1, 4) else MODEL
    item = {"id": i, "kind": "claude", "model": mdl, "name": (zone + "-" + plate) if zone else plate, "plate": plate,
            "project": plate, "cwd": HOST + "/" + plate, "zone": zone, "status": status, "since": since,
            "summary": summary, "waitingFor": wf, "transcript": projdir + "/" + i + ".jsonl", "origin": "user",
            "peer": "", "nameUntitled": False, "pet": PETS[plate],
            "meta": {"model": mdl, "effort": "high", "fast": False, "ctxPct": ctx,
                     "ctxUsed": ctx * 2000, "ctxWindow": 200000, "tps": None, "at": int(now)}}
    if code:
        item["summaryCode"], item["summaryArgs"] = code
    sessions.append(item)
    seen[i] = since + 30
    os.makedirs(os.path.join(PROJ, projdir), exist_ok=True)


def write(n, rows):
    with open(os.path.join(PROJ, sessions[n - 1]["transcript"]), "w", encoding="utf-8") as f:
        for r in rows:
            f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")


# 1 Web-redesign: a few rounds of conversation with a string of tool calls in the middle (figure climbing on the bubble), ending in an unanswered question
t = now - 12 * 60
rows = [u(X("Let's redesign the landing page. Start with the hero section.",
            "我们来重新设计落地页，先从首屏区域开始。", "我們來重新設計登陸頁，先從主視覺區塊開始。"), t),
        a([txt(X("Sure. I'll look at the current hero and the stylesheet first.",
                 "好的，我先看看现在的首屏和样式表。", "好的，我先看看現在的主視覺和樣式表。"))], t + 10)]
tools = [("Read", {"file_path": HOST + "/redesign/index.html"}), ("Grep", {"pattern": "hero", "path": "src"}),
         ("Read", {"file_path": HOST + "/redesign/hero.css"}), ("Edit", {"file_path": HOST + "/redesign/hero.css", "old_string": "a", "new_string": "b"})]
for k, (nm, inp) in enumerate(tools):
    tu = "toolu_r%02d" % k
    rows += [a([tool(nm, inp, tu)], t + 20 + k * 6), res(tu, t + 23 + k * 6)]
rows.append(a([txt(X("The hero is a single column with a large image. I tightened the spacing and moved the call to action above the fold.",
                     "首屏是单栏加一张大图。我收紧了间距，并把行动按钮移到了首屏以内。",
                     "主視覺是單欄加一張大圖。我收緊了間距，並把行動按鈕移到了主視覺以內。"))], t + 60))
rows.append(u(X("Looks good. Can you also check how it renders on small screens?",
                "不错。能再看看小屏幕上的显示效果吗？", "不錯。能再看看小螢幕上的顯示效果嗎？"), t + 120))
rows.append(a([txt(X("On it. Running the layout tests now.", "好，正在跑版式测试。", "好，正在跑版面測試。"))], t + 130))
for k, (nm, inp) in enumerate([("Bash", {"command": "npm run test:layout", "description": X("Run layout tests", "运行版式测试", "執行版面測試")}),
                               ("Read", {"file_path": HOST + "/redesign/report.txt"}),
                               ("Glob", {"pattern": "src/**/*.css"})]):
    tu = "toolu_s%02d" % k
    rows += [a([tool(nm, inp, tu)], t + 140 + k * 6), res(tu, t + 143 + k * 6)]
rows.append(a([txt(X("Layout tests pass on all three widths. One decision is left before I continue.",
                     "三种宽度的版式测试都通过了。继续之前还差一个决定。",
                     "三種寬度的版面測試都通過了。繼續之前還差一個決定。"))], t + 200))
if REC:
    ask_q = {"question": Q_LAYOUT, "header": X("Sections", "板块", "區塊"), "multiSelect": True,
             "options": [{"label": X("Hero banner", "首屏横幅", "主視覺橫幅"), "description": X("Headline and call to action", "标题和行动按钮", "標題和行動按鈕")},
                         {"label": X("Feature cards", "功能卡片", "功能卡片"), "description": X("Three cards below the hero", "首屏下方三张卡片", "主視覺下方三張卡片")},
                         {"label": X("Pricing table", "价格表", "價格表"), "description": X("Plans side by side", "套餐并排对比", "方案並排比較")}]}
else:
    ask_q = {"question": Q_LAYOUT, "header": X("Layout", "布局", "版面"), "multiSelect": False,
             "options": [{"label": X("Single column", "单栏", "單欄"), "description": X("Simple and fast on phones", "简洁，手机上加载快", "簡潔，手機上載入快")},
                         {"label": X("Two columns", "双栏", "雙欄"), "description": X("Image beside the headline", "图片放在标题旁边", "圖片放在標題旁邊")},
                         {"label": X("Card grid", "卡片网格", "卡片格狀"), "description": X("Feature cards below the hero", "首屏下方放功能卡片", "主視覺下方放功能卡片")}]}
rows.append(a([tool("AskUserQuestion", {"questions": [ask_q]}, "toolu_ask")], t + 210))
write(1, rows)
# 2 waiting for approval
t2 = now - 6 * 60
write(2, [u(X("Run the backup to staging when the checks pass.", "检查通过后，把备份跑到预发环境。", "檢查通過後，把備份跑到預備環境。"), t2),
          a([txt(X("Checks pass. Starting the backup.", "检查通过，开始备份。", "檢查通過，開始備份。"))], t2 + 30),
          a([tool("Bash", {"command": "make backup ENV=staging", "description": X("Backup to staging", "备份到预发环境", "備份到預備環境")}, "toolu_ap1")], t2 + 40)])
# rest: one question, one answer
for n, q, ans in ((3, X("Sync the API reference.", "同步接口文档。", "同步 API 文件。"), X("Working on it.", "正在处理。", "正在處理。")),
                  (4, X("Run the CI checks.", "跑一下 CI 检查。", "跑一下 CI 檢查。"), X("All 48 checks passed.", "48 项检查全部通过。", "48 項檢查全部通過。")),
                  (5, X("Compress the hero images.", "压缩首屏图片。", "壓縮主視覺圖片。"), X("Compressed the hero images.", "已压缩首屏图片。", "已壓縮主視覺圖片。")),
                  (6, X("Draft the setup guide.", "起草安装指南。", "起草安裝指南。"), X("Drafted the setup guide.", "已起草安装指南。", "已起草安裝指南。")),
                  (7, X("Prepare the weekly report.", "准备周报。", "準備週報。"), X("Weekly report is ready.", "周报已经备好。", "週報已經備好。")),
                  *([(8, X("Map the new endpoints.", "梳理新接口。", "梳理新介面。"), X("Mapped the new endpoints.", "已梳理新接口。", "已梳理新介面。")),
                     (9, X("Check the mobile layout.", "检查移动端布局。", "檢查行動版版面。"), X("Checked the mobile layout.", "已检查移动端布局。", "已檢查行動版版面。")),
                     (10, X("Export the audit log.", "导出审计日志。", "匯出稽核日誌。"), X("Audit log exported.", "审计日志已导出。", "稽核日誌已匯出。"))] if DESK else [])):
    tn = now - 30 * 60
    write(n, [u(q, tn), a([txt(ans)], tn + 60)])
if REC:  # Docs-sync gets a longer history so the tool-figure action in the GIF happens in the middle of a full screen
    tn = now - (85 if DESK else 50) * 60
    hist = [(X("Sync the API reference.", "同步接口文档。", "同步 API 文件。"), X("Working on it.", "正在处理。", "正在處理。")),
            (X("Which endpoints changed since last week?", "上周以来哪些接口有变化？", "上週以來哪些介面有變化？"),
             X("Three endpoints changed: login, export and search.", "三个接口有变化：登录、导出和搜索。", "三個介面有變化：登入、匯出和搜尋。")),
            (X("Please document the new export parameters.", "请把导出的新参数写进文档。", "請把匯出的新參數寫進文件。"),
             X("Done. The export page now lists format, range and filters.", "完成。导出页现在列出了格式、范围和筛选条件。", "完成。匯出頁現在列出了格式、範圍和篩選條件。")),
            (X("Great. Now update the changelog and re-check the links.", "好。接着更新变更记录，并重新检查链接。", "好。接著更新變更記錄，並重新檢查連結。"),
             X("On it. I will also compare the examples with the live responses.", "好的，我还会把示例和实际返回对照一遍。", "好的，我還會把範例和實際回傳對照一遍。"))]
    if DESK:
        hist = [(X("Start with the API reference.", "先从接口文档开始。", "先從 API 文件開始。"), X("Reading the current docs now.", "正在读现有文档。", "正在讀現有文件。"))] + hist + [
            (X("Also add a short note on rate limits.", "再加一段关于限流的简短说明。", "再加一段關於限流的簡短說明。"),
             X("Added. The note sits under the search endpoint.", "已加上，放在搜索接口下面。", "已加上，放在搜尋介面下面。")),
            (X("Thanks. Keep going with the rest.", "谢谢，继续处理其余部分。", "謝謝，繼續處理其餘部分。"),
             X("Will do. Next up is the changelog and the link check.", "好的。接下来是变更记录和链接检查。", "好的。接下來是變更記錄和連結檢查。"))]
    rows = []
    for k, (q, ans) in enumerate(hist):
        rows += [u(q, tn + k * 600), a([txt(ans)], tn + k * 600 + 60)]
    if FLIP:
        tf = now - 14 * 60
        AGS = [("a1b2c3d4e5f60718", X("Check API links", "检查接口链接", "檢查 API 連結"), "haiku", True, 0, 11, 41000),
               ("b2c3d4e5f6071829", X("Update the changelog", "更新变更记录", "更新變更記錄"), "sonnet", True, 0, 9, 38000),
               ("c3d4e5f607182930", X("Compare examples with live responses", "对照示例和实际返回", "對照範例和實際回傳"), "sonnet", False, 0, 3, 17000)]
        calls = [txt(X("I will split this into three helpers: links, changelog and example check.", "我把它拆给三个子代理：链接、变更记录和示例核对。", "我把它拆給三個子代理：連結、變更記錄和範例核對。"))]
        for k, (aid, desc, mdl, fin, _, mins, tok) in enumerate(AGS):
            calls.append(tool("Agent", {"description": desc, "subagent_type": "general-purpose", "model": mdl,
                                        "prompt": X("Work on: %s. Report back briefly." % desc, "任务：%s。完成后简要汇报。" % desc, "任務：%s。完成後簡要回報。" % desc)}, "toolu_ag%d" % k))
        rows += [u(X("Please run the three checks in parallel.", "请把这三项检查并行跑起来。", "請把這三項檢查平行跑起來。"), tf), a(calls, tf + 20)]
        rows += [res("toolu_ag%d" % k, tf + 21 + k, "Async agent launched") for k in range(3)]
        rows += [a([txt(X("The helpers are working. I will summarize when they report back.", "子代理们正在处理，等它们汇报后我再汇总。", "子代理們正在處理，等它們回報後我再彙總。"))], tf + 60),
                 u(X("Thanks. Tell me when the changelog is merged.", "谢谢。变更记录合并后告诉我。", "謝謝。變更記錄合併後告訴我。"), tf + 120),
                 a([txt(X("Will do.", "好的，没问题。", "好的，沒問題。"))], tf + 150)]
        sub = os.path.join(PROJ, sessions[2]["transcript"][:-6], "subagents")
        os.makedirs(sub)
        for k, (aid, desc, mdl, fin, _, mins, tok) in enumerate(AGS):
            m = {"agentType": "general-purpose", "description": desc, "toolUseId": "toolu_ag%d" % k, "spawnDepth": 1, "model": mdl}
            if fin:
                m["finished"] = True
            with open(os.path.join(sub, "agent-%s.meta.json" % aid), "w") as f:
                json.dump(m, f)
            t0 = tf + 22 + k
            ln = [{"parentUuid": None, "isSidechain": True, "agentId": aid, "type": "user", "timestamp": iso(t0),
                   "message": {"role": "user", "content": X("Work on: %s." % desc, "任务：%s。" % desc, "任務：%s。" % desc)}},
                  {"parentUuid": "x", "isSidechain": True, "agentId": aid, "type": "assistant", "timestamp": iso(t0 + mins * 60 - 5),
                   "message": {"model": "claude-" + mdl, "id": "m1", "type": "message", "role": "assistant",
                               "content": [{"type": "text", "text": X("Checked and updated.", "已检查并更新。", "已檢查並更新。")} if fin else
                                           {"type": "tool_use", "id": "tq%d" % k, "name": "Bash", "input": {"description": X("Compare responses", "对照返回结果", "對照返回結果"), "command": "x"}}],
                               "usage": {"input_tokens": tok - 2000, "output_tokens": 2000}}}]
            with open(os.path.join(sub, "agent-%s.jsonl" % aid), "w", encoding="utf-8") as f:
                for r in ln:
                    f.write(json.dumps(r, ensure_ascii=False, separators=(",", ":")) + "\n")
    write(3, rows)
with open(os.path.join(STATE, "state.json"), "w") as f:
    json.dump({"installed_at": now - 86400, "seen": {}, "pins": [], "pinned_at": {}, "pin_changed": {}, "rest": {}, "unseen": {}}, f)

days = [{"day": datetime.fromtimestamp(now - (13 - k) * 86400).strftime("%Y-%m-%d"), "tokens": 1000000 + k * 50000} for k in range(14)]
snap = {
    "generatedAt": now,
    "usage": {"fiveHour": {"pct": 42, "resetsAt": int(now + 7200)}, "sevenDay": {"pct": 23, "resetsAt": int(now + 4 * 86400)}},
    "zones": ZONES, "sessions": sessions, "offduty": [],
    "panel": {"seenAt": seen, "pinned": []},
    "orca": {"running": True},
    "orcaStats": {"agents": 12, "agentTimeMs": 40 * 3600 * 1000, "prs": 5, "firstEventAt": now - 30 * 86400,
                  "usage": {"totalTokens": sum(d["tokens"] for d in days), "costUsd": 0, "unpricedTokens": 0,
                            "activeDays": 14, "firstDay": days[0]["day"], "peakDay": days[-1], "days": days,
                            "byModel": [], "todayTokens": days[-1]["tokens"], "todayByProject": []}},
    "monitor": {"at": now, "orca": {"app": {"cpu": 6.5, "memory": 6.2e8}, "worktrees": [], "worktreeCount": 0,
                                    "worktreeMemory": 0, "worktreeCpu": 0, "totalCpu": 6.5, "totalMemory": 6.2e8},
                "mac": {"name": "Demo Mac", "pressure": "normal", "memTotal": 3.4e10, "memAvailable": 1.5e10,
                        "mem": {"total": 34359738368, "app": 9e9, "wired": 3e9, "compressed": 1e9, "cached": 6e9, "used": 13e9},
                        "cores": 10.0, "swap": {"total": 2e9, "used": 3e8}, "load": [2.1, 2.4, 2.2],
                        "disk": {"free": 3.1e11, "total": 1e12}, "battery": {"pct": 84, "charging": False, "ac": True}}},
    "zoneTokens": {"byZone": {"Web": 1800000, "Docs": 650000, "Ops": 300000, "Infra": 1200000}, "unmatched": 0},
}
os.makedirs(os.path.join(DATA, "taskboards"), exist_ok=True)
with open(os.path.join(DATA, "taskboards", "Web.md"), "w", encoding="utf-8") as f:
    f.write("# Web\n\n- [ ] Hero section\n- [x] Spacing pass\n")
with open(os.path.join(DATA, "snapshot.json"), "w", encoding="utf-8") as f:
    json.dump(snap, f, ensure_ascii=False)
print(json.dumps({"ids": ids, "chat": ids["redesign"], "files": FILES, "host": HOST, "ask": Q_LAYOUT,
                  "transcripts": {p: os.path.join(PROJ, sessions[n - 1]["transcript"]) for n, p in ((1, "redesign"), (3, "sync"))},
                  "snapshot": os.path.join(DATA, "snapshot.json")}, ensure_ascii=False))
