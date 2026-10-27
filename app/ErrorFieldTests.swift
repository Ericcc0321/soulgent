// The checks of the error / disconnect fields of --dump (errorKind, errorStatus, errorText, errorSince, retryAttempt, retryMax,
// disconnected, disconnectedSince, compactedAt, helpers): run alone with `--error-only`.
// The transcripts are made here in the shapes Claude Code writes: the structure and the error words of
// real error lines, nothing a user wrote.

import Foundation

@MainActor func errorFieldTests() {
    let bench = RestartBench("err")
    defer { bench.done() }
    let files = FileManager.default
    let now = Date()
    func stamp(_ ago: TimeInterval) -> String { codexStamps.string(from: now.addingTimeInterval(-ago)) }
    func json(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
    func near(_ a: Date?, _ ago: TimeInterval) -> Bool { a.map { abs($0.timeIntervalSince(now.addingTimeInterval(-ago))) < 0.01 } ?? false }

    // ── Transcript lines.
    func typed(_ ago: TimeInterval) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(ago), "message": ["role": "user", "content": "请继续"]])
    }
    func said(_ text: String, _ ago: TimeInterval, side: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": side, "timestamp": stamp(ago),
              "message": ["model": "claude-demo-1", "role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    func tool(_ ago: TimeInterval, side: Bool = false) -> String {
        json(["type": "assistant", "isSidechain": side, "timestamp": stamp(ago),
              "message": ["model": "claude-demo-1", "role": "assistant", "content": [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls"]]]]])
    }
    func result(_ ago: TimeInterval) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(ago),
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]]])
    }
    /// An API error row as Claude Code writes it: a synthetic assistant reply, the error's name and, when there is one, the status.
    func apiError(_ text: String, error: String?, status: Int?, _ ago: TimeInterval, side: Bool = false) -> String {
        var o: [String: Any] = ["parentUuid": NSNull(), "isSidechain": side, "type": "assistant", "uuid": "u-" + UUID().uuidString, "timestamp": stamp(ago),
            "message": ["model": "<synthetic>", "id": "msg_x", "type": "message", "role": "assistant", "content": [["type": "text", "text": text]]],
            "isApiErrorMessage": true, "userType": "external"]
        if let error { o["error"] = error }
        if let status { o["apiErrorStatus"] = status; o["requestId"] = "req_x" }
        return json(o)
    }
    func retryRow(_ attempt: Int, _ ago: TimeInterval, side: Bool = false) -> String {
        json(["type": "system", "subtype": "api_error", "level": "error", "isSidechain": side, "timestamp": stamp(ago),
              "error": ["status": 500, "headers": ["server": "cloudflare"], "requestID": NSNull(), "type": NSNull()],
              "retryInMs": 554.6, "retryAttempt": attempt, "maxRetries": 10])
    }
    func compactRow(_ ago: TimeInterval) -> String {
        json(["type": "system", "subtype": "compact_boundary", "content": "Conversation compacted", "isSidechain": false, "timestamp": stamp(ago),
              "compactMetadata": ["trigger": "auto", "preTokens": 405111, "durationMs": 25363]])
    }
    func turnEnd(_ ago: TimeInterval) -> String {
        json(["type": "system", "subtype": "turn_duration", "durationMs": 1200, "isSidechain": false, "timestamp": stamp(ago)])
    }

    // The words of the real errors (appendix A of the plan).
    let overloaded = "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. If it persists, check https://status.claude.com."
    let weekly = "You've hit your weekly limit · resets 1pm (UTC)"
    let login = "Please run /login · API Error: 403 Request not allowed"
    let orgOff = "Your organization has disabled Claude subscription access for Claude Code · Use an Anthropic API key instead, or ask your admin to enable access"
    let socket = "API Error: The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()"
    let dropped = "API Error: Connection dropped (ECONNRESET)"

    var n = 0
    /// Puts a session in the bench's registry (pid 1: alive), with its transcript; the session as the loader gives it.
    func load(_ status: String, _ lines: [String], fileMoment: TimeInterval = 0) -> Session {
        n += 1
        let id = "err-\(n)"
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.map { $0 + "\n" }.joined()).write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        bench.open(id, status, since: now.addingTimeInterval(-fileMoment))
        return bench.load().first { $0.id == id }!
    }
    func args(_ s: Session) -> [String: Any] { s.line.args }

    // ── 1. Each kind of error, with the words as Claude Code wrote them.
    var s = load("idle", [typed(300), tool(250), result(240), apiError(overloaded, error: "server_error", status: 529, 200), turnEnd(199)])
    check("error fields: 529 Overloaded (server_error) — kind api, status 529, text as written, since = the error row's moment",
        s.errorKind == "api" && s.errorStatus == 529 && s.errorText == overloaded && near(s.errorSince, 200) && s.retryAttempt == nil && s.retryMax == nil)
    let overloadedWords = "Overloaded. This is a server-side issue, usually temporary — try again in a moment. If it persists, check https://status.claude.com."
    check("error fields: ...its card line is state.apiError, the API-error-529 prefix and the words without their own \"API Error: 529\" (no 529 twice)",
        s.line.code == "state.apiError" && s.summary == "API 出错 529：" + overloadedWords && !s.summary.contains("API Error") && s.summary.components(separatedBy: "529").count == 2
            && args(s)["kind"] as? String == "api" && args(s)["status"] as? Int == 529 && args(s)["text"] as? String == overloadedWords)
    check("error fields: ...and the error's words are not the card's line (not a reply cut at 90 characters)", s.summary != String(overloaded.prefix(90)) && s.summary.hasPrefix("API 出错"))

    s = load("idle", [typed(300), apiError(weekly, error: "rate_limit", status: 429, 100)])
    check("error fields: 429 rate_limit — kind rate_limit, status 429, the line is Claude Code's own words",
        s.errorKind == "rate_limit" && s.errorStatus == 429 && s.errorText == weekly && s.summary == weekly && s.line.code == "state.apiError" && args(s)["kind"] as? String == "rate_limit")

    s = load("idle", [typed(300), apiError(login, error: "authentication_failed", status: 403, 100)])
    check("error fields: 403 authentication_failed — kind auth, the line is the re-login text, the args keep the words (they do not start with API Error:)",
        s.errorKind == "auth" && s.errorStatus == 403 && s.errorText == login && s.summary == "要重新登录" && args(s)["text"] as? String == login && args(s)["status"] as? Int == 403)
    s = load("idle", [typed(300), apiError(orgOff, error: "oauth_org_not_allowed", status: 403, 100)])
    check("error fields: oauth_org_not_allowed — kind auth too", s.errorKind == "auth" && s.summary == "要重新登录" && s.errorText == orgOff)

    s = load("idle", [typed(300), apiError(socket, error: "unknown", status: nil, 100)])
    check("error fields: unknown, no status (the socket closed) — kind api, status null, the API-error prefix and the words after API Error:",
        s.errorKind == "api" && s.errorStatus == nil && s.summary == "API 出错：The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()"
            && args(s)["status"] is NSNull)
    s = load("idle", [typed(300), apiError(dropped, error: "server_error", status: nil, 100)])
    check("error fields: server_error with no status (connection dropped) — kind api, status null, the API-error prefix and \"Connection dropped (ECONNRESET)\"",
        s.errorKind == "api" && s.errorStatus == nil && s.summary == "API 出错：Connection dropped (ECONNRESET)")
    s = load("idle", [typed(300), apiError("API Error: 400 Claude Code 2.1.250 does not support this model.", error: "unknown", status: 400, 100)])
    check("error fields: unknown 400 — kind api, the status after API Error: is taken off once, from the words", s.errorKind == "api" && s.errorStatus == 400 && s.summary == "API 出错 400：Claude Code 2.1.250 does not support this model.")
    s = load("idle", [typed(300), apiError(overloaded, error: nil, status: 529, 100)])
    check("error fields: an error row naming no error is api", s.errorKind == "api")
    let long = "API Error: 500 " + String(repeating: "长", count: 300)
    s = load("idle", [typed(300), apiError(long, error: "server_error", status: 500, 100)])
    check("error fields: errorText is the first 160 characters of Claude Code's words (and the line's words are cut from those)",
        s.errorText == String(long.prefix(160)) && s.errorText?.count == 160 && (args(s)["text"] as? String)?.count == 160 - "API Error: 500 ".count)
    check("error fields: the words of a row cut at a line end keep the first line only on the card", {
        let two = load("idle", [typed(300), apiError("API Error: 503 Service Unavailable\nsee the status page", error: "server_error", status: 503, 100)])
        return two.summary == "API 出错 503：Service Unavailable" && two.errorText == "API Error: 503 Service Unavailable\nsee the status page"
    }())
    check("error fields: apiErrorWords — API Error: and a three-digit status off, words not so started left alone",
        apiErrorWords("API Error: 529 Overloaded") == "Overloaded" && apiErrorWords("API Error:529 x") == "x" && apiErrorWords("API Error: Connection dropped") == "Connection dropped"
            && apiErrorWords("Please run /login · API Error: 403 Request not allowed") == "Please run /login · API Error: 403 Request not allowed"
            && apiErrorWords("API Error: 5290 big") == "5290 big" && apiErrorWords("API Error: 42") == "42" && apiErrorWords("") == "" && apiErrorWords("API Error: 529") == "")

    // ── 1b. The lines in the very shape and key order of real transcripts (ids, paths and times made up; only the error's words are real).
    let realUsage = #""usage":{"output_tokens_details":null,"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"server_tool_use":{"web_search_requests":0,"web_fetch_requests":0},"service_tier":null,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0},"inference_geo":null,"iterations":null,"speed":null}"#
    func realError(_ words: String, error: String, status: Int?, _ ago: TimeInterval) -> String {
        let at = status.map { #","apiErrorStatus":\#($0)"# } ?? ""
        return #"{"parentUuid":"p-1","isSidechain":false,"type":"assistant","uuid":"u-1","timestamp":"\#(stamp(ago))","message":{"diagnostics":null,"id":"m-1","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message",\#(realUsage),"content":[{"type":"text","text":"\#(words)"}],"context_management":null},"requestId":"req_x","error":"\#(error)","isApiErrorMessage":true\#(at),"perTurnEffort":"xhigh","session_id":"s-1","userType":"external","entrypoint":"cli","cwd":"/tmp/demo","sessionId":"s-1","version":"2.1.290","gitBranch":"HEAD"}"#
    }
    let realRetry = #"{"parentUuid":"p-1","isSidechain":false,"type":"system","subtype":"api_error","level":"error","error":{"status":500,"headers":{"date":"Sun, 10 May 2026 13:20:48 GMT","content-length":"0","connection":"keep-alive","server":"cloudflare","cf-cache-status":"DYNAMIC"},"requestID":null,"type":null},"retryInMs":554.6310492117696,"retryAttempt":2,"maxRetries":10,"timestamp":"\#(stamp(5))","uuid":"u-2","userType":"external","entrypoint":"cli","cwd":"/tmp/demo","sessionId":"s-1","version":"2.1.138","gitBranch":"HEAD"}"#
    let realCompact = #"{"parentUuid":null,"logicalParentUuid":"p-1","isSidechain":false,"type":"system","subtype":"compact_boundary","content":"Conversation compacted","isMeta":false,"timestamp":"\#(stamp(77))","uuid":"u-3","level":"info","compactMetadata":{"trigger":"auto","preTokens":405111,"durationMs":25363,"preCompactDiscoveredTools":["Monitor"],"preservedSegment":{"headUuid":"h","anchorUuid":"a","tailUuid":"t"}}}"#
    s = load("idle", [typed(300), realError(overloaded, error: "server_error", status: 529, 100)])
    check("error fields: a 529 line in the real shape — api, 529, the words, the API-error-529 prefix and 'Overloaded. ...'", s.errorKind == "api" && s.errorStatus == 529 && s.errorText == overloaded && s.summary.hasPrefix("API 出错 529：Overloaded. This is"))
    s = load("idle", [typed(300), realError("You've reached your Fable limit. Run /usage-credits to continue or switch models with /model.", error: "rate_limit", status: 429, 100)])
    check("error fields: a 429 line in the real shape — rate_limit, 429, the words are the line", s.errorKind == "rate_limit" && s.errorStatus == 429 && s.summary.hasPrefix("You've reached your Fable limit."))
    s = load("idle", [typed(300), realError("Failed to authenticate: OAuth session expired and could not be refreshed", error: "authentication_failed", status: nil, 100)])
    check("error fields: an authentication_failed line without a status in the real shape — auth, status null, the re-login text", s.errorKind == "auth" && s.errorStatus == nil && s.summary == "要重新登录")
    s = load("busy", [typed(300), realRetry])
    check("error fields: a retry note in the real shape (headers and all) — busy: 2 of 10", s.retryAttempt == 2 && s.retryMax == 10 && s.summary == "正在重试 2/10")
    s = load("idle", [typed(300), realCompact, said("接着做", 50)])
    check("error fields: a compact_boundary row in the real shape — its moment", near(s.compactedAt, 77))

    // ── 2. No error: nothing; and what clears one.
    s = load("idle", [typed(300), said("好了，改完了", 100), turnEnd(99)])
    check("error fields: a session with no error — kind, status, text, since all null; no retry; not disconnected; no compaction",
        s.errorKind == nil && s.errorStatus == nil && s.errorText == nil && s.errorSince == nil && s.retryAttempt == nil && s.retryMax == nil
            && !s.disconnected && s.disconnectedSince == nil && s.compactedAt == nil && s.summary == "好了，改完了")
    s = load("idle", [typed(300), apiError(overloaded, error: "server_error", status: 529, 200), typed(150), said("重试成功，改完了", 100)])
    check("error fields: the user tried again and it worked (a reply after the error) — no error any more, the reply is the line", s.errorKind == nil && s.errorText == nil && s.summary == "重试成功，改完了")
    s = load("idle", [typed(300), apiError(overloaded, error: "server_error", status: 529, 200), tool(100), result(99)])
    check("error fields: an assistant line of any kind after it (a tool call) clears it too", s.errorKind == nil && s.errorSince == nil)
    s = load("idle", [typed(300), apiError(overloaded, error: "server_error", status: 529, 200), typed(100)])
    check("error fields: a prompt typed after it clears it (the session is about to answer)", s.errorKind == nil)
    s = load("idle", [typed(300), apiError(overloaded, error: "server_error", status: 529, 200), typed(150), apiError(weekly, error: "rate_limit", status: 429, 100)])
    check("error fields: two errors — the later one is the current one", s.errorKind == "rate_limit" && s.errorStatus == 429 && near(s.errorSince, 100))
    s = load("idle", [typed(300), said("上一条回复", 250), apiError(overloaded, error: "server_error", status: 529, 200), tool(100, side: true), said("子代理说话", 90, side: true)])
    check("error fields: a sidechain (subagent) line after the error is not the session's — the error stays", s.errorKind == "api")
    s = load("idle", [typed(300), said("上一条回复", 250), apiError(overloaded, error: "server_error", status: 529, 200, side: true)])
    check("error fields: a sidechain error is not the session's", s.errorKind == nil && s.summary == "上一条回复")
    s = load("busy", [typed(300), apiError(overloaded, error: "server_error", status: 529, 200)])
    check("error fields: busy with an error as the last line — not an error now (it is working again)", s.errorKind == nil && s.retryAttempt == nil)
    s = load("idle", [typed(300), said("No response requested.", 100), json(["type": "assistant", "isSidechain": false, "timestamp": stamp(90), "isApiErrorMessage": false,
        "message": ["model": "<synthetic>", "role": "assistant", "content": [["type": "text", "text": "No response requested."]]]])])
    check("error fields: isApiErrorMessage:false (No response requested.) is no error", s.errorKind == nil)

    // The error row stays the last thing said as far as when the card was last news goes (nothing moves on the board).
    s = load("idle", [typed(1500), said("很早的回复", 1200), apiError(overloaded, error: "server_error", status: 529, 600)])
    check("error fields: since = the error row's moment (the card does not move)", near(s.since, 600))

    // ── 3. Retrying.
    s = load("busy", [typed(300), tool(250), result(240), retryRow(3, 5)])
    check("error fields: retrying — busy and the retry's note newer than every assistant and user line: 3 of 10, the line is the retrying 3/10 text",
        s.retryAttempt == 3 && s.retryMax == 10 && s.errorKind == nil && s.summary == "正在重试 3/10" && s.line.code == "state.retrying"
            && args(s)["attempt"] as? Int == 3 && args(s)["max"] as? Int == 10)
    s = load("busy", [typed(300), retryRow(1, 20), retryRow(2, 15), retryRow(4, 5)])
    check("error fields: the last retry note counts", s.retryAttempt == 4 && s.retryMax == 10)
    s = load("idle", [typed(300), retryRow(3, 5)])
    check("error fields: the same lines on an idle session — not retrying", s.retryAttempt == nil && s.retryMax == nil && s.line.code != "state.retrying")
    s = load("waiting", [typed(300), retryRow(3, 5)])
    check("error fields: ...nor on a waiting one", s.retryAttempt == nil)
    s = load("busy", [typed(300), retryRow(3, 20), said("通了，继续", 5)])
    check("error fields: busy, a reply after the note (it worked) — not retrying", s.retryAttempt == nil && s.summary != "正在重试 3/10")
    s = load("busy", [typed(300), retryRow(3, 20), tool(10)])
    check("error fields: ...a tool call after the note too", s.retryAttempt == nil)
    s = load("busy", [typed(300), tool(250), retryRow(3, 20), result(5)])
    check("error fields: ...a tool result after it too", s.retryAttempt == nil)
    s = load("busy", [typed(300), retryRow(3, 20), typed(5)])
    check("error fields: ...a prompt typed after it too", s.retryAttempt == nil)
    s = load("busy", [typed(300), retryRow(3, 20), tool(10, side: true)])
    check("error fields: a sidechain line after the note does not end it", s.retryAttempt == 3)
    s = load("busy", [typed(300), retryRow(3, 20, side: true)])
    check("error fields: a sidechain retry note is not the session's", s.retryAttempt == nil)
    s = load("idle", [typed(300), retryRow(10, 20), apiError(dropped, error: "server_error", status: nil, 10)])
    check("error fields: retries used up — the error row after the last note is the error (idle), not a retry", s.errorKind == "api" && s.retryAttempt == nil && s.summary.hasPrefix("API 出错"))
    s = load("idle", [typed(300), said("上次的回复", 100), compactRow(90)])
    check("error fields: a compaction row is neither a reply nor a prompt (the line is still the last reply)", s.summary == "上次的回复")

    // ── 4. Compaction.
    s = load("idle", [typed(300), compactRow(200), said("压缩后继续", 100)])
    check("error fields: compactedAt = the compact_boundary row's moment", near(s.compactedAt, 200))
    s = load("busy", [typed(900), compactRow(500), tool(400), result(399), compactRow(100), tool(50)])
    check("error fields: the latest compaction counts", near(s.compactedAt, 100))
    check("error fields: no compaction row — null", load("idle", [typed(300), said("x", 100)]).compactedAt == nil)

    // ── 5. WorkBuddy: errorKind only, the line unchanged.
    let wbSource = appFixtures + "/workbuddy"
    if files.fileExists(atPath: wbSource + "/workbuddy.db") {
        func wbSession(_ status: String) -> Session? {
            let dir = bench.dir + "/wb-" + status
            try? files.createDirectory(atPath: dir, withIntermediateDirectories: true)
            for item in ["workbuddy.db", "workbuddy.db-shm", "workbuddy.db-wal", "projects", "logs", "sessions"] {
                try? files.removeItem(atPath: dir + "/" + item)
                try? files.copyItem(atPath: wbSource + "/" + item, toPath: dir + "/" + item)
            }
            _ = fixtureSQL(dir + "/workbuddy.db", "UPDATE sessions SET status = '\(status)'")
            let updated = Double(fixtureValue(dir + "/workbuddy.db", "SELECT updated_at FROM sessions") ?? "0") ?? 0
            let reader = WorkBuddySessions(home: dir)
            reader.running = { 4343 }
            return reader.load(now: Date(timeIntervalSince1970: updated / 1000 + 600)).first
        }
        for (status, kind, line, code) in [("error", "wb_error", "出错", "state.error"), ("failed", "wb_error", "出错", "state.error"),
            ("terminated", "wb_stopped", "已中止", "state.stopped"), ("cancelled", "wb_stopped", "已中止", "state.stopped")] {
            let w = wbSession(status)
            check("error fields: WorkBuddy \(status) — errorKind \(kind), the line and code stay \(line) / \(code), no other error field",
                w?.errorKind == kind && w?.summary == line && w?.line.code == code && w?.errorStatus == nil && w?.errorText == nil && w?.errorSince == nil
                    && w?.retryAttempt == nil && w?.disconnected == false && w?.status == "idle")
        }
        let done = wbSession("completed")
        check("error fields: WorkBuddy completed — no errorKind", done != nil && done?.errorKind == nil)
    } else {
        skipped("no WorkBuddy fixture", "error fields: WorkBuddy error / stopped")
    }
    check("error fields: WorkBuddy's states — only error/failed and terminated/cancelled are wb_error / wb_stopped, the other rows are as they were",
        WorkBuddySessions.stateLine("error", wait: nil, mode: "").line == .error && WorkBuddySessions.stateLine("terminated", wait: nil, mode: "").line == .stopped
            && WorkBuddySessions.stateLine("paused", wait: nil, mode: "").line == .paused && WorkBuddySessions.stateLine("working", wait: nil, mode: "").line == nil)

    // ── 6. Disconnected: the process dead, the registry file left.
    let goneBench = RestartBench("err-gone")
    defer { goneBench.done() }
    let gonePath = goneBench.dir + "/caches/gone.json"
    func process() -> Loader {  // a new process, nothing in memory: the same file
        let noCLI = CodexSessions()
        noCLI.processes = { [] }
        return Loader(registry: goneBench.registry, codex: noCLI, restarting: goneBench.list, goneCache: gonePath)
    }
    let dead = Process()
    dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? dead.run()
    dead.waitUntilExit()
    let deadPid = dead.processIdentifier
    func register(_ id: String, pid: Int32, name: String? = nil, file: String? = nil, extra: [String: Any] = [:]) {
        let ms = now.timeIntervalSince1970 * 1000
        var o: [String: Any] = ["pid": Int(pid), "sessionId": id, "status": "busy", "statusUpdatedAt": ms, "startedAt": ms, "name": name ?? "名-" + id, "nameSource": "user", "cwd": "/tmp/" + id]
        for (k, v) in extra { o[k] = v }
        if name == "" { o["name"] = nil; o["nameSource"] = nil }
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: goneBench.registry + "/" + (file ?? id) + ".json"))
    }
    func gone(_ id: String, among list: [Session]) -> Session? { list.first { $0.id == id } }
    func goneKeys() -> [String: Double] { Loader.decodeGone(FileManager.default.contents(atPath: gonePath)).mapValues(\.at) }

    register("d1", pid: deadPid)
    register("live1", pid: 1)
    var first = process()
    var list = first.load(now: now)
    var d1 = gone("d1", among: list)
    check("error fields: disconnected — a dead process whose file is left is listed: idle, the exited-unexpectedly text (state.disconnected), disconnected true, since = when it was found",
        d1?.disconnected == true && d1?.status == "idle" && d1?.summary == "意外退出" && d1?.line.code == "state.disconnected" && d1?.line.args.isEmpty == true
            && near(d1?.disconnectedSince, 0) && d1.map { near($0.since, 0) } == true && d1?.name == "名-d1" && d1?.pid == deadPid && d1?.nameUntitled == false)
    check("error fields: ...no task, no error, no retry; the live session beside it is not disconnected",
        d1?.bgTasks == 0 && d1?.bgAgents == 0 && d1?.errorKind == nil && d1?.retryAttempt == nil && gone("live1", among: list)?.disconnected == false)
    check("error fields: ...its first sight is written to gone.json", goneKeys().keys.sorted() == ["d1"] && abs((goneKeys()["d1"] ?? 0) - now.timeIntervalSince1970) < 1)
    first = process()  // a --dump a few minutes later: another process, the same card, from the file
    list = first.load(now: now.addingTimeInterval(300))
    d1 = gone("d1", among: list)
    check("error fields: ...another process 5 minutes later (a --dump) lists the same card with the same disconnectedSince", d1?.disconnected == true && near(d1?.disconnectedSince, 0))
    let rowsLater = dumpRows(process(), now: now.addingTimeInterval(300))
    let rowD1 = rowsLater.first { $0["id"] as? String == "d1" }
    check("error fields: ...as --dump gives it: disconnected true, disconnectedSince a number, status idle, summaryCode state.disconnected, helpers 0",
        rowD1?["disconnected"] as? Bool == true && abs((rowD1?["disconnectedSince"] as? Double ?? 0) - now.timeIntervalSince1970) < 1 && rowD1?["status"] as? String == "idle"
            && rowD1?["summaryCode"] as? String == "state.disconnected" && rowD1?["summary"] as? String == "意外退出" && rowD1?["helpers"] as? Int == 0
            && (rowsLater.first { $0["id"] as? String == "live1" })?["disconnected"] as? Bool == false)
    list = process().load(now: now.addingTimeInterval(599))
    check("error fields: ...still there at 9 minutes 59", gone("d1", among: list) != nil)
    list = process().load(now: now.addingTimeInterval(601))
    check("error fields: ...gone after 10 minutes", gone("d1", among: list) == nil && gone("live1", among: list) != nil)
    list = process().load(now: now.addingTimeInterval(1200))
    check("error fields: ...and does not come back while its file is left (the moment stays on record)", gone("d1", among: list) == nil && goneKeys().keys.contains("d1"))
    goneBench.close("d1")
    _ = process().load(now: now.addingTimeInterval(1300))
    check("error fields: ...the record goes when the file does", goneKeys().isEmpty)
    check("error fields: gone.json is small and leaves no scratch file",
        ((try? files.contentsOfDirectory(atPath: (gonePath as NSString).deletingLastPathComponent)) ?? []) == ["gone.json"])

    // Not disconnected: asked to go, or replaced.
    register("d2", pid: deadPid)
    goneBench.restarting([("d2", 5)])
    list = process().load(now: now)
    check("error fields: a session on the restart list is not generated", gone("d2", among: list) == nil)
    goneBench.restarting([])
    goneBench.close("d2")
    register("d3", pid: deadPid, name: "同一个窗")
    register("d3-new", pid: 1, name: "同一个窗")
    list = process().load(now: now)
    check("error fields: a new session of the same name (window swap) — no disconnected card for the old one", gone("d3", among: list) == nil && gone("d3-new", among: list) != nil)
    register("d4", pid: deadPid, file: "dead-file")
    register("d4", pid: 1, file: "live-file")
    list = process().load(now: now)
    check("error fields: the same session id live under another pid (resumed) — no disconnected card, the live one stays", list.filter { $0.id == "d4" }.count == 1 && gone("d4", among: list)?.disconnected == false)
    register("d5", pid: deadPid, extra: ["kind": "bg", "spare": true])
    list = process().load(now: now)
    check("error fields: a dead spare background process is nobody's session", gone("d5", among: list) == nil)
    goneBench.close("d3"); goneBench.close("d3-new"); goneBench.close("dead-file"); goneBench.close("live-file"); goneBench.close("d5"); goneBench.close("live1")
    list = process().load(now: now)
    check("error fields: a session that left by itself (/exit: its file removed with it) — nothing generated", list.isEmpty)
    // The same name, but the new one gone: the old one's record is made when it is first found, and a name no one has now is not window swap.
    register("d6", pid: deadPid, name: "")
    list = process().load(now: now)
    check("error fields: a dead one with no name still counts, and is called the untitled default name", gone("d6", among: list)?.disconnected == true && gone("d6", among: list)?.name == "未命名" && gone("d6", among: list)?.nameUntitled == true)
    goneBench.close("d6")
    _ = process().load(now: now.addingTimeInterval(700))  // its time is over

    // ── 6b. The file is cleaned away within seconds by another Claude Code; the card goes on from the row kept in gone.json.
    let bareList = process().load(now: now)
    check("error fields (more): nothing left over from before — no card", !bareList.contains { $0.disconnected } && goneKeys().isEmpty)
    register("d7", pid: deadPid, name: "窗7", extra: ["cwd": "/tmp/demo/d7"])
    var l7 = process().load(now: now)
    check("error fields (more): first sight, file there — the card", gone("d7", among: l7)?.disconnected == true)
    goneBench.close("d7")  // another process cleans the file away
    l7 = process().load(now: now.addingTimeInterval(30))
    var c7 = gone("d7", among: l7)
    check("error fields (more): the file gone 30 s later (another process) — the card stays, from the row kept: same name, pid, cwd, kind, moment, idle, exited unexpectedly",
        c7?.disconnected == true && c7?.status == "idle" && c7?.summary == "意外退出" && c7?.name == "窗7" && c7?.pid == deadPid && c7?.cwd == "/tmp/demo/d7"
            && c7?.kind == "claude" && c7?.registryName == "窗7" && near(c7?.disconnectedSince, 0) && c7.map { near($0.since, 0) } == true && c7?.line.code == "state.disconnected")
    let r7 = dumpRows(process(), now: now.addingTimeInterval(60)).first { $0["id"] as? String == "d7" }
    check("error fields (more): ...as --dump gives it: disconnected true, bg fields zero, helpers 0, errors null, the name and project as kept",
        r7?["disconnected"] as? Bool == true && r7?["bgTasks"] as? Int == 0 && r7?["bgAgents"] as? Int == 0 && r7?["bgSince"] is NSNull && r7?["bgStale"] as? Bool == false
            && r7?["helpers"] as? Int == 0 && r7?["errorKind"] is NSNull && r7?["name"] as? String == "窗7" && r7?["project"] as? String == "d7" && r7?["status"] as? String == "idle")
    check("error fields (more): ...a board that has been running all along and a new --dump both give it", gone("d7", among: first.load(now: now.addingTimeInterval(61))) != nil)
    check("error fields (more): ...still there at 9 minutes 59", gone("d7", among: process().load(now: now.addingTimeInterval(599))) != nil)
    check("error fields (more): ...gone at 10 minutes 1, and gone.json holds nothing of it (its file is gone too)",
        gone("d7", among: process().load(now: now.addingTimeInterval(601))) == nil && goneKeys()["d7"] == nil)
    // A same-named session coming alive drops it at once.
    register("d8", pid: deadPid, name: "窗8")
    _ = process().load(now: now)
    goneBench.close("d8")
    check("error fields (more): a card kept for a file already gone shows (before the new window)", gone("d8", among: process().load(now: now.addingTimeInterval(5))) != nil && goneKeys()["d8"] != nil)
    register("d8-new", pid: 1, name: "窗8")
    list = process().load(now: now.addingTimeInterval(6))
    check("error fields (more): a new session of the same name (window swap) — the card goes at once and its row with it", gone("d8", among: list) == nil && goneKeys()["d8"] == nil && gone("d8-new", among: list) != nil)
    goneBench.close("d8-new")
    check("error fields (more): ...and does not come back when the new one has gone", gone("d8", among: process().load(now: now.addingTimeInterval(7))) == nil)
    // The same id alive (resumed).
    register("d9", pid: deadPid)
    _ = process().load(now: now)
    goneBench.close("d9")
    register("d9", pid: 1, file: "d9-resumed")
    list = process().load(now: now.addingTimeInterval(5))
    check("error fields (more): the same id alive under another pid (resumed) — no card, the row dropped, the live one listed", list.filter { $0.id == "d9" }.count == 1 && gone("d9", among: list)?.disconnected == false && goneKeys()["d9"] == nil)
    goneBench.close("d9-resumed")
    // On the restart list now: the row is dropped.
    register("d10", pid: deadPid)
    _ = process().load(now: now)
    goneBench.close("d10")
    goneBench.restarting([("d10", 3)])
    check("error fields (more): put on the restart list after being found — no card, row dropped", gone("d10", among: process().load(now: now.addingTimeInterval(5))) == nil && goneKeys()["d10"] == nil)
    goneBench.restarting([])
    // gone.json broken, or of the old version: no error, as if none.
    register("d11", pid: deadPid)
    for (label, text) in [("garbage", "{{{"), ("empty", ""), ("old version 1", #"{"version":1,"sessions":{"d11":{"at":1}}}"#), ("wrong shape", #"{"version":2,"sessions":[1,2]}"#),
        ("an entry without its fields", #"{"version":2,"sessions":{"d11":{"at":1,"row":{"pid":1}},"x":5}}"#)] {
        try? text.write(toFile: gonePath, atomically: true, encoding: .utf8)
        let broken = process().load(now: now.addingTimeInterval(10))
        check("error fields (more): gone.json \(label) — no error, taken as none: the dead file makes a fresh card, and the file is whole again",
            gone("d11", among: broken)?.disconnected == true && near(gone("d11", among: broken)?.disconnectedSince, -10) && goneKeys().keys.sorted() == ["d11"])
        goneBench.close("d11")
        _ = process().load(now: now.addingTimeInterval(2000))
        register("d11", pid: deadPid)
    }
    goneBench.close("d11")
    _ = process().load(now: now.addingTimeInterval(3000))
    check("error fields (more): version 2 is what is written", { () -> Bool in
        register("d12", pid: deadPid)
        _ = process().load(now: now)
        let o = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: gonePath)))) as? [String: Any]
        goneBench.close("d12")
        _ = process().load(now: now.addingTimeInterval(4000))
        return o?["version"] as? Int == 2
    }())
    // Two processes (the panel and a --dump) taking turns on the one file.
    let panelProc = process()
    register("da", pid: deadPid, name: "窗a")
    _ = panelProc.load(now: now)
    register("db", pid: deadPid, name: "窗b")
    let dumpProc = process()
    _ = dumpProc.load(now: now.addingTimeInterval(2))
    goneBench.close("da"); goneBench.close("db")
    let viaPanel = panelProc.load(now: now.addingTimeInterval(4))  // the panel's memory has only da; the file has both
    check("error fields (more): two processes taking turns — the panel (which saw only da) and the --dump (which saw db later) both show both after the files are gone",
        gone("da", among: viaPanel) != nil && gone("db", among: viaPanel) != nil && gone("da", among: dumpProc.load(now: now.addingTimeInterval(5))) != nil
            && goneKeys().keys.sorted() == ["da", "db"] && near(gone("da", among: viaPanel)?.disconnectedSince, 0) && near(gone("db", among: viaPanel)?.disconnectedSince, -2))
    list = process().load(now: now.addingTimeInterval(601))
    check("error fields (more): ...da's time ends at 10 minutes, db's 2 seconds after, each on its own", gone("da", among: list) == nil && gone("db", among: list) != nil)
    _ = process().load(now: now.addingTimeInterval(700))
    check("error fields (more): ...and the file ends empty once both are over", goneKeys().isEmpty)

    // The card is drawn elsewhere: the panel's two reads of the loader go through `Store.shown`, which keeps such sessions (showFailed on)
    // or leaves them out (off). --jump still does not aim at one.
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let panelText = panelSources(sources)
    check("error fields: the panel's two loads go through Store.shown, and --jump does not aim at one",
        panelText.components(separatedBy: "Self.shown(loader.load())").count == 3 && panelText.contains("first(where: { !$0.disconnected && ($0.name == wanted"))

    // ── 7. helpers.
    let formula: [(subagents: Int, bgAgents: Int, bgTasks: Int, helpers: Int)] = [
        (0, 0, 0, 0), (2, 0, 0, 2), (0, 0, 3, 3), (0, 2, 2, 2), (2, 2, 2, 2), (3, 1, 2, 4), (1, 2, 2, 2), (0, 1, 3, 3), (4, 2, 5, 7), (2, 3, 3, 3),
    ]
    check("error fields: helpers = max(subagents, bgAgents) + max(0, bgTasks − bgAgents) over \(formula.count) cases — a subagent seen both ways is counted once",
        formula.allSatisfy { f in
            var x = Session(id: "h", pid: 1, project: "p", name: "h", status: "idle", since: now, summary: "")
            (x.bgAgents, x.bgTasks) = (f.bgAgents, f.bgTasks)
            return x.helpers(subagents: f.subagents) == f.helpers && dumpRow(x, model: "", subagents: f.subagents)["helpers"] as? Int == f.helpers
        })
    check("error fields: dumpRow without the subagents given counts the background ones only", {
        var x = Session(id: "h", pid: 1, project: "p", name: "h", status: "idle", since: now, summary: "")
        (x.bgAgents, x.bgTasks) = (1, 3)
        return dumpRow(x, model: "")["helpers"] as? Int == 3
    }())

    // A session with 2 subagents running (their folder beside the transcript), 1 background subagent and 2 commands in its transcript.
    let helperBench = RestartBench("err-helpers")
    defer { helperBench.done() }
    let noCLI = CodexSessions()
    noCLI.processes = { [] }
    let helperLoader = Loader(registry: helperBench.registry, codex: noCLI, restarting: helperBench.list)
    func launch(_ id: String, agent: Bool) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(50),
              "toolUseResult": agent ? ["isAsync": true, "status": "async_launched", "agentId": id] : ["stdout": "", "backgroundTaskId": id],
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "x"]]]])
    }
    func helperSession(_ id: String, lines: [String], agents: Int) {
        let path = helperBench.dir + "/\(id).jsonl"
        try? (lines.map { $0 + "\n" }.joined()).write(toFile: path, atomically: true, encoding: .utf8)
        helperLoader.remember(transcript: path, for: id)
        helperBench.open(id, "busy", since: now)
        let folder = helperBench.dir + "/\(id)/subagents"
        try? files.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for i in 0..<agents {
            files.createFile(atPath: "\(folder)/agent-r\(i).jsonl", contents: Data((tool(5, side: true) + "\n").utf8))
            files.createFile(atPath: "\(folder)/agent-r\(i).meta.json", contents: Data(#"{"agentType":"general-purpose","description":"跑测试"}"#.utf8))
        }
    }
    helperSession("hp-both", lines: [typed(100), launch("a1", agent: true), launch("b1", agent: false), launch("b2", agent: false)], agents: 2)
    helperSession("hp-agents", lines: [typed(100), tool(50)], agents: 3)
    helperSession("hp-cmds", lines: [typed(100), launch("b1", agent: false), launch("b2", agent: false)], agents: 0)
    helperSession("hp-none", lines: [typed(100)], agents: 0)
    let helperRows = dumpRows(helperLoader)
    func helpersOf(_ id: String) -> Int? { helperRows.first { $0["id"] as? String == id }?["helpers"] as? Int }
    check("error fields: --dump's helpers from real folders — 2 subagents running + 1 background subagent + 2 commands = max(2,1) + (3−1) = 4; 3 subagents alone = 3; 2 commands alone = 2; none = 0",
        helpersOf("hp-both") == 4 && helpersOf("hp-agents") == 3 && helpersOf("hp-cmds") == 2 && helpersOf("hp-none") == 0)
    let store = Store()
    store.readOnly = true
    store.sessions = helperLoader.load()
    store.readAgents(store.sessions.compactMap { x in helperLoader.transcript(of: x.id).map { (x.id, $0) } }, at: now)
    check("error fields: ...and the panel's own count (Store.helpers, from agentCounts) is the same number for every one of them",
        store.sessions.count == 4 && store.sessions.allSatisfy { store.helpers(of: $0) == helpersOf($0.id) })

    // ── 8. The dump: keys, and the summary-code invariant over every row.
    let keys = Set(helperRows.flatMap { $0.keys })
    check("error fields: --dump's rows carry the old 14 keys, the seven BG ones, the ten error fields and formatWarnings (FormatWarningTests.swift), and no other",
        helperRows.allSatisfy { Set($0.keys) == summaryCodeOldKeys.union(summaryCodeNewKeys).union(summaryCodeBgKeys).union(summaryCodeErrorFieldKeys).union(["formatWarnings"]) } && keys.count == 32 && summaryCodeErrorFieldKeys.count == 10)
    let errorLoader = bench.loader
    let all = errorLoader.load()
    var allRows = all.map { dumpRow($0, model: "m") }
    allRows += rowsLater
    let data = try! JSONSerialization.data(withJSONObject: allRows, options: [.prettyPrinted, .sortedKeys])
    let back = (try! JSONSerialization.jsonObject(with: data)) as! [[String: Any]]
    check("error fields: the summary-code invariant over all \(back.count) rows (errors, retries, disconnected, plain), through JSON: the simplified template and summaryArgs render the summary byte for byte",
        back.count > 20 && back.allSatisfy { SummaryLine.render(code: $0["summaryCode"] as? String ?? "?", args: $0["summaryArgs"] as? [String: Any] ?? [:]) == ($0["summary"] as? String) })
    let text = String(decoding: data, as: UTF8.self)
    check("error fields: the absent ones are written as null (errorKind, errorStatus, errorText, errorSince, retryAttempt, retryMax, disconnectedSince, compactedAt) and the booleans as booleans",
        ["errorKind", "errorStatus", "errorText", "errorSince", "retryAttempt", "retryMax", "disconnectedSince", "compactedAt"].allSatisfy { text.contains("\"\($0)\" : null") }
            && text.contains("\"disconnected\" : false") && text.contains("\"disconnected\" : true"))
    let o529 = back.first { ($0["errorStatus"] as? Int) == 529 }
    check("error fields: a row with an error — errorKind api, errorStatus 529, errorText the words as written, errorSince a number",
        o529?["errorKind"] as? String == "api" && o529?["errorText"] as? String == overloaded && o529?["errorSince"] is Double && o529?["summaryCode"] as? String == "state.apiError")
}
