import Foundation

// ───────── Summary codes: --dump's summaryCode / summaryArgs / nameUntitled ─────────
//
// The simplified-Chinese template of a code with its arguments renders the summary byte for byte, and the
// fields --dump always had stay as they were. The `summaryCodeOld…` functions below are the reference summary makers
// (the compatibility baseline), copied word for word: every line the new code makes is held against what the old made.

private func summaryCodeOldPickSummary(recap: (String, String)?, reply: (String, String)?, asked: (String, String)?) -> String {
    if let a = asked, a.0 > (reply?.0 ?? "") { return "你：" + firstLine(a.1) }
    func clean(_ s: String) -> String {
        plain(s.replacingOccurrences(of: recapSuffix, with: "")).trimmingCharacters(in: .whitespaces)
    }
    guard let r = reply else {
        if let c = recap { return clean(c.1) }
        return asked.map { "你：" + firstLine($0.1) } ?? ""
    }
    let lines = r.1.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    if let marked = lines.last(where: { $0.hasPrefix(progressMark) }) {
        return plain(String(marked.dropFirst(progressMark.count))).trimmingCharacters(in: .whitespaces)
    }
    if let c = recap, c.0 >= r.0 { return clean(c.1) }
    return firstLine(r.1)
}

private func summaryCodeOldPendingRequest(_ line: Data) -> String? {
    guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
        let use = blocks.last(where: { ($0["type"] as? String) == "tool_use" })
    else { return nil }
    let input = use["input"] as? [String: Any] ?? [:]
    func brief(_ text: String?) -> String { String(plain(text ?? "").split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) }
    switch use["name"] as? String ?? "" {
    case "AskUserQuestion":
        let questions = input["questions"] as? [[String: Any]] ?? []
        guard let first = questions.first?["question"] as? String else { return "在等你回答问题" }
        return "问你：" + brief(first) + (questions.count > 1 ? "（共 \(questions.count) 个问题）" : "")
    case "ExitPlanMode":
        return "计划写好了，等你批准"
    case "Bash":
        return "等你批准运行：" + brief(input["description"] as? String ?? input["command"] as? String)
    case "Edit", "Write", "NotebookEdit":
        return "等你批准修改：" + ((input["file_path"] as? String).map { ($0 as NSString).lastPathComponent } ?? "文件")
    case let name:
        return "等你批准使用 " + name
    }
}

private func summaryCodeOldWaits(_ tail: CodexTail, busy: Bool) -> (waitingFor: String, ask: String, since: Date)? {
    if let asked = tail.approvals.values.min() { return ("permission prompt", "等你批准", asked) }
    guard !busy else { return nil }
    let open = tail.questions.values.sorted { $0.at < $1.at }
    guard let first = open.first else { return nil }
    let more = open.count > 1 ? "（共 \(open.count) 个问题）" : ""
    return ("input needed", "问你：" + firstLine(first.title) + more, first.at)
}

private func summaryCodeOldState(_ status: String, wait: WorkBuddySessions.Wait?, mode: String) -> (status: String, waitingFor: String, summary: String?) {
    switch status {
    case "working", "planning":
        return ("busy", "", nil)
    case "pending", "waiting_question", "waiting_permission":
        let kind: WorkBuddySessions.Wait? = status == "waiting_question" ? .question(options: nil) : status == "waiting_permission" ? .permission : wait
        if case .question(let options)? = kind {
            return ("waiting", "input needed", options.map { "等你回答（\($0) 个选项）" } ?? "等你回答")
        }
        if mode == "bypassPermissions" { return ("busy", "", nil) }
        return ("waiting", "permission request", "等你批准")
    case "paused":
        return ("waiting", "", "已暂停")
    case "terminated", "cancelled":
        return ("idle", "", "已中止")
    case "error", "failed":
        return ("idle", "", "出错")
    default:
        return ("idle", "", nil)
    }
}

private func summaryCodeOldCodexName(name: String?, title: String) -> String {
    if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
    let first = title.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    return first.map { String($0.prefix(24)) } ?? "未命名"
}

/// --dump's reference row (the fields it had before the summary codes), word for word.
private func summaryCodeOldDumpRow(_ s: Session, model: String) -> [String: Any] {
    ["id": s.id, "project": s.project, "name": s.name, "status": s.status, "waitingFor": s.waitingFor,
     "since": s.since.timeIntervalSince1970, "summary": s.summary, "kind": s.kind, "model": model,
     "origin": s.origin, "peer": s.peer]
        as [String: Any]
}

let summaryCodeOldKeys: Set<String> = ["id", "project", "name", "status", "waitingFor", "since", "summary", "kind", "model", "origin", "peer"]
let summaryCodeNewKeys: Set<String> = ["summaryCode", "summaryArgs", "nameUntitled"]
/// BG: the seven background-task keys the dump has since (bgTasks, bgAgents, bgSince, bgStale, bgEndedAt, bgOwned, bgList); BGTests.swift checks them.
let summaryCodeBgKeys: Set<String> = ["bgTasks", "bgAgents", "bgSince", "bgStale", "bgEndedAt", "bgOwned", "bgList"]
/// The ten keys the dump has since (errorKind, errorStatus, errorText, errorSince, retryAttempt, retryMax, disconnected, disconnectedSince, compactedAt, helpers); ErrorFieldTests.swift checks them.
let summaryCodeErrorFieldKeys: Set<String> = ["errorKind", "errorStatus", "errorText", "errorSince", "retryAttempt", "retryMax", "disconnected", "disconnectedSince", "compactedAt", "helpers"]

private func summaryCodeJSON(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys]) }

/// A line as the phone gets it: its arguments through JSON and back, then rendered by its code's template.
private func summaryCodeRoundTrip(_ line: SummaryLine) -> String? {
    let back = (try? JSONSerialization.jsonObject(with: summaryCodeJSON(line.args))) as? [String: Any] ?? ["?": 0]
    return SummaryLine.render(code: line.code, args: back)
}

/// The new row against the old: the old fields the same, byte for byte, and only the three new ones added.
private func summaryCodeSameOldFields(_ s: Session, model: String = "") -> Bool {
    let new = dumpRow(s, model: model)
    let oldPart = new.filter { summaryCodeOldKeys.contains($0.key) }
    return Set(new.keys) == summaryCodeOldKeys.union(summaryCodeNewKeys).union(summaryCodeBgKeys).union(summaryCodeErrorFieldKeys) && summaryCodeJSON(oldPart) == summaryCodeJSON(summaryCodeOldDumpRow(s, model: model))
}

/// The line holds: it renders to the summary, also through JSON, and its code is a known one.
private func summaryCodeHolds(_ s: Session) -> Bool {
    let line = s.line
    return line.rendered == s.summary && summaryCodeRoundTrip(line) == s.summary
        && SummaryLine.render(code: line.code, args: line.args) != nil
}

@MainActor func summaryCodeTests() {
    // ── 1. Each code: its template and arguments render the line the old code made (literals copied from it).
    let each: [(SummaryLine, String, String, String)] = [
        (.ask(question: "要不要先备份数据库？", count: 2), "wait.ask", "问你：要不要先备份数据库？（共 2 个问题）", #"{"count":2,"question":"要不要先备份数据库？"}"#),
        (.ask(question: "要不要先备份数据库？", count: 1), "wait.ask", "问你：要不要先备份数据库？", #"{"count":1,"question":"要不要先备份数据库？"}"#),
        (.ask(question: "", count: 1), "wait.ask", "问你：", #"{"count":1,"question":""}"#),
        (.askGeneric, "wait.ask.generic", "在等你回答问题", "{}"),
        (.plan, "wait.plan", "计划写好了，等你批准", "{}"),
        (.approveRun(command: "Run the unit tests"), "wait.approve.run", "等你批准运行：Run the unit tests", #"{"command":"Run the unit tests"}"#),
        (.approveRun(command: ""), "wait.approve.run", "等你批准运行：", #"{"command":""}"#),
        (.approveEdit(file: "config.yaml"), "wait.approve.edit", "等你批准修改：config.yaml", #"{"file":"config.yaml"}"#),
        (.approveEdit(file: nil), "wait.approve.edit", "等你批准修改：文件", #"{"file":null}"#),
        (.approveEdit(file: ""), "wait.approve.edit", "等你批准修改：", #"{"file":""}"#),
        (.approveTool(tool: "WebFetch"), "wait.approve.tool", "等你批准使用 WebFetch", #"{"tool":"WebFetch"}"#),
        (.approve, "wait.approve", "等你批准", "{}"),
        (.answer(options: 3), "wait.answer", "等你回答（3 个选项）", #"{"options":3}"#),
        (.answer(options: nil), "wait.answer", "等你回答", #"{"options":null}"#),
        (.paused, "state.paused", "已暂停", "{}"),
        (.stopped, "state.stopped", "已中止", "{}"),
        (.error, "state.error", "出错", "{}"),
        (.you("把登录页的按钮改成蓝色"), "prompt.you", "你：把登录页的按钮改成蓝色", #"{"text":"把登录页的按钮改成蓝色"}"#),
        (.relayAgent, "relay.agent", "处理子代理回报…", "{}"),
        (.relayPeer, "relay.peer", "处理其他会话的消息…", "{}"),
        (.relayFrom(peer: "docs-writer"), "relay.from", "处理 docs-writer 的回报…", #"{"peer":"docs-writer"}"#),
        (.apiError(kind: "api", status: 529, text: "Overloaded. This is a server-side issue."), "state.apiError", "API 出错 529：Overloaded. This is a server-side issue.",
            #"{"kind":"api","status":529,"text":"Overloaded. This is a server-side issue."}"#),
        (.apiError(kind: "api", status: nil, text: "Connection dropped (ECONNRESET)"), "state.apiError", "API 出错：Connection dropped (ECONNRESET)",
            #"{"kind":"api","status":null,"text":"Connection dropped (ECONNRESET)"}"#),
        (.apiError(kind: "rate_limit", status: 429, text: "You've hit your weekly limit · resets 1pm"), "state.apiError", "You've hit your weekly limit · resets 1pm",
            #"{"kind":"rate_limit","status":429,"text":"You've hit your weekly limit · resets 1pm"}"#),
        (.apiError(kind: "auth", status: 403, text: "Request not allowed"), "state.apiError", "要重新登录", #"{"kind":"auth","status":403,"text":"Request not allowed"}"#),
        (.retrying(attempt: 3, max: 10), "state.retrying", "正在重试 3/10", #"{"attempt":3,"max":10}"#),
        (.disconnected, "state.disconnected", "意外退出", "{}"),
        (.text("测试全部通过，已推送到分支。", kind: .reply), "text", "测试全部通过，已推送到分支。", #"{"kind":"reply","text":"测试全部通过，已推送到分支。"}"#),
        (.text("第 2 步：在改登录页样式", kind: .progress), "text", "第 2 步：在改登录页样式", #"{"kind":"progress","text":"第 2 步：在改登录页样式"}"#),
        (.text("Refactored the parser.\nFixed two tests.", kind: .recap), "text", "Refactored the parser.\nFixed two tests.", #"{"kind":"recap","text":"Refactored the parser.\nFixed two tests."}"#),
        (.text("从别处来的一行", kind: .raw), "text", "从别处来的一行", #"{"kind":"raw","text":"从别处来的一行"}"#),
        (.empty, "none", "", "{}"),
    ]
    for (line, code, said, args) in each {
        let compact = String(decoding: try! JSONSerialization.data(withJSONObject: line.args, options: [.sortedKeys]), as: UTF8.self)
        check("summary codes: \(code) \(args) renders \(said.debugDescription)",
            line.code == code && line.rendered == said && summaryCodeRoundTrip(line) == said && compact == args)
    }
    let codes = Set(each.map(\.1))
    check("summary codes: 20 codes in all, each with a case above",
        codes.count == 20 && codes.isSuperset(of: ["wait.ask", "wait.ask.generic", "wait.plan", "wait.approve.run", "wait.approve.edit",
            "wait.approve.tool", "wait.approve", "wait.answer", "state.paused", "state.stopped", "state.error", "prompt.you",
            "relay.agent", "relay.peer", "relay.from", "text", "none", "state.apiError", "state.retrying", "state.disconnected"]))
    check("summary codes: a code the template table does not know renders nil (the phone then shows summary)",
        SummaryLine.render(code: "wait.something-new", args: [:]) == nil)
    check("summary codes: an empty text line is none with {} (said, and made directly)",
        SummaryLine.said("", .reply) == .empty && SummaryLine.text("", kind: .recap).code == "none" && SummaryLine.text("", kind: .recap).args.isEmpty)

    // ── 2a. The old makers against the new, over many inputs: the same line, byte for byte.
    let stamps = ["", "2026-10-19T01:00:00.000Z", "2026-10-19T01:00:05.000Z", "2026-10-19T01:00:09.000Z"]
    let texts = ["测试全部通过", "**粗体** 和 `代码`\n第二行", "〔进度〕第 2 步：改样式\n别的", "前文\n〔进度〕 **一** \n〔进度〕二 ", "---\n### \n",
        "   ", "", "No response requested.", String(repeating: "长", count: 120), "# 标题\n- 列表项", "(disable recaps in /config)", "回顾 (disable recaps in /config)"]
    var pickedSame = 0, pickedAll = 0, pickedBad: [String] = []
    let replies: [(String, String)?] = [nil] + stamps.flatMap { s in texts.map { Optional((s, $0)) } }
    for r in replies {
        for c in [nil, (stamps[2], "**Recap** 改完了 (disable recaps in /config)"), (stamps[0], ""), (stamps[3], "多行\n回顾")] as [(String, String)?] {
            for a in [nil, (stamps[1], "帮我看看"), (stamps[3], "---"), (stamps[2], "  **改** 这里\n下一行")] as [(String, String)?] {
                pickedAll += 1
                let line = pickSummaryLine(recap: c, reply: r, asked: a)
                let old = summaryCodeOldPickSummary(recap: c, reply: r, asked: a)
                if line.rendered == old && summaryCodeRoundTrip(line) == old && pickSummary(recap: c, reply: r, asked: a) == old
                    && (old.isEmpty == (line.code == "none"))
                {
                    pickedSame += 1
                } else if pickedBad.count < 3 {
                    pickedBad.append(old.debugDescription)
                }
            }
        }
    }
    check("summary codes: pickSummary — \(pickedAll) inputs, the line and its code render what the old made \(pickedBad)", pickedSame == pickedAll)

    func use(_ name: String, _ input: [String: Any]) -> Data {
        let o: [String: Any] = ["type": "assistant", "message": ["content": [["type": "text", "text": "先说一句"], ["type": "tool_use", "id": "t1", "name": name, "input": input]]]]
        return try! JSONSerialization.data(withJSONObject: o)
    }
    let uses: [Data] = [
        use("AskUserQuestion", ["questions": [["question": "要不要先备份？\n第二行"], ["question": "第二题"]]]),
        use("AskUserQuestion", ["questions": [["question": " **用 A 还是 B** "]]]),
        use("AskUserQuestion", ["questions": [] as [Any]]),
        use("AskUserQuestion", [:]),
        use("ExitPlanMode", ["plan": "x"]),
        use("Bash", ["command": "swift test 2>&1 | tail -5", "description": "Run the unit tests"]),
        use("Bash", ["command": "ls\npwd"]),
        use("Bash", ["command": "ls", "description": ""]),
        use("Bash", [:]),
        use("Edit", ["file_path": "/tmp/demo/config.yaml"]),
        use("Write", ["file_path": ""]),
        use("NotebookEdit", [:]),
        use("WebFetch", ["url": "https://example.com"]),
        use("mcp__demo__lookup", [:]),
        use("", [:]),
        try! JSONSerialization.data(withJSONObject: ["type": "assistant", "message": ["content": [["type": "text", "text": "没有工具"]]]]),
        Data("not json".utf8),
    ]
    let pendingSame = uses.filter { d in
        let old = summaryCodeOldPendingRequest(d), line = pendingRequestLine(d)
        return old == line?.rendered && old == pendingRequest(d) && (line.map { summaryCodeRoundTrip($0) == old } ?? true)
    }.count
    check("summary codes: pendingRequest — \(uses.count) tool calls, the line renders what the old made", pendingSame == uses.count)
    check("summary codes: pendingRequest — each tool call has its code",
        uses.compactMap { pendingRequestLine($0)?.code } == ["wait.ask", "wait.ask", "wait.ask.generic", "wait.ask.generic", "wait.plan",
            "wait.approve.run", "wait.approve.run", "wait.approve.run", "wait.approve.run", "wait.approve.edit", "wait.approve.edit",
            "wait.approve.edit", "wait.approve.tool", "wait.approve.tool", "wait.approve.tool"])

    // The Codex app's waits: approvals, question cards, both, busy or not.
    let t0 = Date(timeIntervalSince1970: 1_791_000_000)
    var tails: [CodexTail] = [CodexTail()]
    var oneCard = CodexTail(); oneCard.questions = ["c1/q1": (title: "**用哪个方案？**\n细节", at: t0)]
    var twoCards = oneCard; twoCards.questions["c2/q1"] = (title: "第二个问题", at: t0 + 5)
    var emptyCard = CodexTail(); emptyCard.questions = ["c3/q1": (title: "", at: t0)]
    var approving = twoCards; approving.approvals = ["call-1": t0 + 9, "call-2": t0 + 3]
    tails += [oneCard, twoCards, emptyCard, approving]
    var waitsSame = 0
    for t in tails {
        for busy in [false, true] {
            let old = summaryCodeOldWaits(t, busy: busy), new = CodexAppSessions.waitLine(t, busy: busy), wrapped = CodexAppSessions.waits(t, busy: busy)
            if old?.ask == new?.line.rendered && old?.waitingFor == new?.waitingFor && old?.since == new?.since && wrapped?.ask == old?.ask
                && (new.map { summaryCodeRoundTrip($0.line) == old?.ask } ?? true)
            {
                waitsSame += 1
            }
        }
    }
    check("summary codes: Codex app waits — \(tails.count * 2) cases, the same line, waitingFor and since as the old",
        waitsSame == tails.count * 2 && CodexAppSessions.waitLine(approving, busy: false)?.line == .approve
            && CodexAppSessions.waitLine(twoCards, busy: false)?.line == .ask(question: "用哪个方案？", count: 2))

    // WorkBuddy: every status, wait and mode.
    var stateSame = 0, stateAll = 0
    for status in ["working", "planning", "pending", "waiting_question", "waiting_permission", "paused", "terminated", "cancelled", "error", "failed", "completed", ""] {
        for wait in [nil, .permission, .question(options: nil), .question(options: 3)] as [WorkBuddySessions.Wait?] {
            for mode in ["default", "acceptEdits", "bypassPermissions"] {
                stateAll += 1
                let old = summaryCodeOldState(status, wait: wait, mode: mode), new = WorkBuddySessions.stateLine(status, wait: wait, mode: mode)
                let wrapped = WorkBuddySessions.state(status, wait: wait, mode: mode)
                if old.status == new.status && old.waitingFor == new.waitingFor && old.summary == new.line?.rendered
                    && wrapped.summary == old.summary && wrapped.status == old.status && wrapped.waitingFor == old.waitingFor
                {
                    stateSame += 1
                }
            }
        }
    }
    check("summary codes: WorkBuddy state — \(stateAll) cases, the same status, waitingFor and line as the old", stateSame == stateAll)

    // Codex's names: the same name; untitled only for the default.
    let names: [(String?, String)] = [("摘星星", "x"), (nil, "读下交接\n然后"), ("", "\n  读下  \n"), (nil, String(repeating: "长", count: 30)), (nil, ""), ("  ", " \n "), ("未命名", ""), (nil, "未命名")]
    check("summary codes: codexName — the same names as the old; untitled only when it had none",
        names.allSatisfy { codexName(name: $0.0, title: $0.1) == summaryCodeOldCodexName(name: $0.0, title: $0.1) }
            && names.map { codexGivenName(name: $0.0, title: $0.1) == nil } == [false, false, false, false, true, true, false, false])

    // ── 2b. Through the loader, as --dump reads it: Claude Code sessions in a scratch registry.
    let bench = RestartBench("sum")
    defer { bench.done() }
    let now = Date()
    func rec(_ content: Any, type: String = "user", stamp: String, meta: Bool = false) -> String {
        var o: [String: Any] = ["type": type, "isSidechain": false, "timestamp": stamp, "message": ["role": type, "content": content]]
        if meta { o["isMeta"] = true }
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    func said(_ text: String, _ stamp: String) -> String { rec([["type": "text", "text": text]], type: "assistant", stamp: stamp) }
    func calls(_ name: String, _ input: [String: Any], _ stamp: String) -> String {
        rec([["type": "tool_use", "id": "toolu_1", "name": name, "input": input]], type: "assistant", stamp: stamp)
    }
    func recap(_ text: String, _ stamp: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "away_summary", "content": text, "timestamp": stamp, "isSidechain": false]), as: UTF8.self)
    }
    /// A session in the scratch registry; `name` nil writes none at all (the default untitled then).
    func put(_ id: String, _ status: String, _ lines: [String], name: String? = nil, nameSource: String = "user") {
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        let ms = now.timeIntervalSince1970 * 1000
        var o: [String: Any] = ["pid": 1, "sessionId": id, "status": status, "statusUpdatedAt": ms, "startedAt": ms, "cwd": "/tmp/sum-demo/" + id,
            "nameSource": nameSource]
        if let name { o["name"] = name }
        if status == "waiting" { o["waitingFor"] = "permission prompt" }
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: bench.registry + "/\(id).json"))
    }
    let s1 = "2026-10-19T01:00:00.000Z", s2 = "2026-10-19T01:00:05.000Z", s3 = "2026-10-19T01:00:09.000Z"
    let peerText = "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"docs-writer\">\n好了</cross-session-message>"
    let bareText = "<cross-session-message from=\"uds:x\">hi</cross-session-message>"
    let agentText = "<task-notification>\n<task-id>a1</task-id>\n</task-notification>"
    // (id, status, transcript, the summary the old code gave, its code)
    let cases: [(String, String, [String], String, String)] = [
        ("sum-reply", "idle", [rec("跑一下测试", stamp: s1), said("**测试全部通过**，已推送到分支。\n细节", s2)], "测试全部通过，已推送到分支。", "text"),
        ("sum-progress", "busy", [rec("改登录页", stamp: s1), said("开始\n〔进度〕第 2 步：在改登录页样式", s2)], "第 2 步：在改登录页样式", "text"),
        ("sum-recap", "idle", [rec("重构", stamp: s1), said("收到任务，开始做", s1), recap("Refactored the parser. (disable recaps in /config)", s3)], "Refactored the parser.", "text"),
        ("sum-you", "busy", [said("上一轮做完了", s1), rec("把登录页的按钮改成蓝色", stamp: s2)], "你：把登录页的按钮改成蓝色", "prompt.you"),
        ("sum-none", "idle", [], "", "none"),
        ("sum-agent", "busy", [rec("先做 A", stamp: s1), said("收到任务，开始做", s1), rec(agentText, stamp: s3)], "处理子代理回报…", "relay.agent"),
        ("sum-peer", "busy", [rec("先做 A", stamp: s1), said("收到任务，开始做", s1), rec(bareText, stamp: s3)], "处理其他会话的消息…", "relay.peer"),
        ("sum-from", "busy", [rec("先做 A", stamp: s1), said("收到任务，开始做", s1), rec(peerText, stamp: s3)], "处理 docs-writer 的回报…", "relay.from"),
        ("sum-bash", "waiting", [said("我来跑测试", s1), calls("Bash", ["command": "swift test", "description": "Run the unit tests"], s2)], "等你批准运行：Run the unit tests", "wait.approve.run"),
        ("sum-edit", "waiting", [said("改配置", s1), calls("Edit", ["file_path": "/tmp/sum-demo/config.yaml"], s2)], "等你批准修改：config.yaml", "wait.approve.edit"),
        ("sum-tool", "waiting", [said("查一下", s1), calls("WebFetch", ["url": "https://example.com"], s2)], "等你批准使用 WebFetch", "wait.approve.tool"),
        ("sum-ask", "waiting", [said("问两件事", s1), calls("AskUserQuestion", ["questions": [["question": "要不要先备份数据库？"], ["question": "用哪个分支？"]]], s2)], "问你：要不要先备份数据库？（共 2 个问题）", "wait.ask"),
        ("sum-ask0", "waiting", [said("问", s1), calls("AskUserQuestion", [:], s2)], "在等你回答问题", "wait.ask.generic"),
        ("sum-plan", "waiting", [said("计划", s1), calls("ExitPlanMode", ["plan": "1. 改 2. 测"], s2)], "计划写好了，等你批准", "wait.plan"),
        // Waiting with the tool call answered: no pending, the reply stands (summary does not say wait.*).
        ("sum-waitreply", "waiting", [said("做完了", s1), calls("Bash", ["command": "ls"], s1),
            rec([["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]], stamp: s2), said("列好了", s3)], "列好了", "text"),
    ]
    for c in cases { put(c.0, c.1, c.2, name: "名-" + c.0) }
    put("sum-untitled", "idle", [said("没有名字", s1)])
    put("sum-named-untitled", "idle", [said("他就叫它未命名", s1)], name: "未命名")
    put("sum-registry-name", "idle", [said("注册表起的名字", s1)], name: "auto-name", nameSource: "derived")
    let loaded = bench.load()
    func find(_ id: String) -> Session? { loaded.first { $0.id == id } }
    for c in cases {
        let s = find(c.0)
        check("summary codes: loader \(c.0) — summary as the old gave it, code \(c.4), the old fields unchanged",
            s?.summary == c.3 && s?.line.code == c.4 && s.map(summaryCodeHolds) == true && s.map { summaryCodeSameOldFields($0) } == true)
    }
    check("summary codes: loader — the text kinds: reply, progress, recap",
        find("sum-reply")?.line == .text("测试全部通过，已推送到分支。", kind: .reply) && find("sum-progress")?.line == .text("第 2 步：在改登录页样式", kind: .progress)
            && find("sum-recap")?.line == .text("Refactored the parser.", kind: .recap))
    check("summary codes: loader — every session it read holds the invariant and keeps the old fields",
        loaded.count == cases.count + 3 && loaded.allSatisfy(summaryCodeHolds) && loaded.allSatisfy { summaryCodeSameOldFields($0, model: "m") })

    // ── 3. none, text/raw, nameUntitled.
    let noneRow = find("sum-none").map { dumpRow($0, model: "") }
    check("summary codes: none — an empty summary is code none with {}",
        noneRow?["summary"] as? String == "" && noneRow?["summaryCode"] as? String == "none" && (noneRow?["summaryArgs"] as? [String: Any])?.isEmpty == true)
    var bare = session("sum-bare")
    let bareEmpty = dumpRow(bare, model: "")
    bare = Session(id: "sum-bare", pid: 1, project: "p", name: "x", status: "idle", since: now, summary: "一行不知从哪来的字")
    let raw = dumpRow(bare, model: "")
    check("summary codes: text/raw — a line made with no code (as the checks' own sessions) is text with kind raw, the line as it is",
        raw["summaryCode"] as? String == "text" && (raw["summaryArgs"] as? [String: String]) == ["text": "一行不知从哪来的字", "kind": "raw"]
            && bareEmpty["summaryCode"] as? String == "none" && summaryCodeHolds(bare))
    var drifted = bare
    drifted.summaryLine = .approve  // a code that says something else than the line
    check("summary codes: text/raw — a code whose line is not the summary is not given; the summary as text/raw instead",
        drifted.line == .text("一行不知从哪来的字", kind: .raw))
    let untitled = find("sum-untitled"), namedSo = find("sum-named-untitled"), fromRegistry = find("sum-registry-name")
    check("summary codes: nameUntitled — no name anywhere: the untitled default and true; the dump says so",
        untitled?.name == "未命名" && untitled?.nameUntitled == true && untitled.flatMap { dumpRow($0, model: "")["nameUntitled"] as? Bool } == true)
    check("summary codes: nameUntitled — a session named like the untitled default by the user: false",
        namedSo?.name == "未命名" && namedSo?.nameUntitled == false && namedSo.flatMap { dumpRow($0, model: "")["nameUntitled"] as? Bool } == false)
    check("summary codes: nameUntitled — named by the registry or by the user: false",
        fromRegistry?.name == "auto-name" && fromRegistry?.nameUntitled == false && find("sum-reply")?.nameUntitled == false)
    check("summary codes: nameUntitled — always a JSON boolean in the dump",
        loaded.allSatisfy { s in
            let json = String(decoding: summaryCodeJSON(dumpRow(s, model: "")), as: UTF8.self)
            return json.contains("\"nameUntitled\" : true") || json.contains("\"nameUntitled\" : false")
        })

    // Codex CLI through its tail reader: a rollout with a turn and a reply.
    let rollout = bench.dir + "/rollout-sum.jsonl"
    let lines = [
        #"{"timestamp":"2026-10-19T01:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-10-19T01:00:04.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"**改好了**，测试通过。\n第二行"}]}}"#,
        #"{"timestamp":"2026-10-19T01:00:05.000Z","type":"event_msg","payload":{"type":"task_complete"}}"#,
    ]
    try? (lines.joined(separator: "\n") + "\n").write(toFile: rollout, atomically: true, encoding: .utf8)
    let cli = CodexTail.read(rollout, after: nil, now: now)
    check("summary codes: Codex CLI tail — the reply's line as the old made it, code text/reply",
        cli.summary == summaryCodeOldPickSummary(recap: nil, reply: ("", "**改好了**，测试通过。\n第二行"), asked: nil) && cli.summary == "改好了，测试通过。"
            && cli.summaryLine == .text("改好了，测试通过。", kind: .reply) && cli.status == "idle")
}

/// Two fictional sessions, as --dump gives them (`--summary-sample`).
@MainActor func summaryCodeSample() {
    let bench = RestartBench("sum-sample")
    defer { bench.done() }
    let ms = Date(timeIntervalSince1970: 1_792_746_000).timeIntervalSince1970 * 1000
    func put(_ id: String, _ status: String, _ name: String, _ lines: [[String: Any]]) {
        let path = bench.dir + "/\(id).jsonl"
        let text = lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        var o: [String: Any] = ["pid": 1, "sessionId": id, "status": status, "statusUpdatedAt": ms, "startedAt": ms, "cwd": "/tmp/demo-shop/" + id,
            "name": name, "nameSource": "user"]
        if status == "waiting" { o["waitingFor"] = "permission prompt" }
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: bench.registry + "/\(id).json"))
    }
    func said(_ content: [[String: Any]], _ stamp: String) -> [String: Any] {
        ["type": "assistant", "isSidechain": false, "timestamp": stamp, "message": ["role": "assistant", "model": "claude-demo-1", "content": content]]
    }
    put("00000000-demo-wait", "waiting", "Demo-shop-tests", [
        said([["type": "text", "text": "我来跑一遍单元测试"]], "2026-10-23T02:00:00.000Z"),
        said([["type": "tool_use", "id": "toolu_demo", "name": "Bash", "input": ["command": "swift test", "description": "Run the unit tests"]]], "2026-10-23T02:00:01.000Z"),
    ])
    put("00000000-demo-reply", "idle", "Demo-shop-docs", [
        ["type": "user", "isSidechain": false, "timestamp": "2026-10-23T02:00:00.000Z", "message": ["role": "user", "content": "把 README 的安装步骤补全"]],
        said([["type": "text", "text": "README 的安装步骤补好了，共 4 步。\n细节见提交说明。"]], "2026-10-23T02:00:30.000Z"),
    ])
    let rows = bench.load().map { dumpRow($0, model: "claude-demo-1") }
    print(String(decoding: try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
}
