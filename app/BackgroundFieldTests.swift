// The checks of the background-task fields (`bgTasks`, `bgAgents`, `bgSince`, `bgStale` in --dump):
// run alone with `--bg-only`. The transcripts are made here, in the shapes Claude Code 2.1.310 writes.

import Foundation

@MainActor func bgTests() {
    let dir = NSTemporaryDirectory() + "bg-tests-\(getpid())"
    try? FileManager.default.removeItem(atPath: dir)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let now = Date()
    func stamp(_ ago: TimeInterval) -> String { codexStamps.string(from: now.addingTimeInterval(-ago)) }
    func json(_ o: [String: Any]) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
    func result(_ r: [String: Any], _ ago: TimeInterval) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(ago), "toolUseResult": r,
              "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "x"]]]])
    }
    func started(_ id: String, _ ago: TimeInterval) -> String {
        result(["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": id], ago)
    }
    func timedOut(_ id: String, _ ago: TimeInterval) -> String {
        result(["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": id, "timedOutAfterMs": 120000, "backgroundCwdHint": "/tmp"], ago)
    }
    func agent(_ id: String, _ ago: TimeInterval) -> String {
        result(["isAsync": true, "status": "async_launched", "agentId": id, "description": "样稿", "outputFile": "/tmp/x"], ago)
    }
    func note(_ id: String, _ status: String) -> String {
        "<task-notification>\n<task-id>\(id)</task-id>\n<tool-use-id>toolu_1</tool-use-id>\n<output-file>/tmp/\(id).output</output-file>\n<status>\(status)</status>\n<summary>x</summary>\n</task-notification>"
    }
    func queued(_ id: String, _ status: String, op: String = "enqueue") -> String {
        json(["type": "queue-operation", "operation": op, "timestamp": stamp(1), "sessionId": "s", "content": note(id, status)])
    }
    func told(_ id: String, _ status: String) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(1), "message": ["role": "user", "content": note(id, status)]])
    }
    func stopped(_ id: String) -> String {
        result(["message": "Successfully stopped task: \(id) (sleep 99)", "task_id": id, "task_type": "local_bash", "command": "sleep 99"], 1)
    }
    func said(_ text: String) -> String {
        json(["type": "assistant", "isSidechain": false, "timestamp": stamp(1), "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
    }
    var n = 0
    func file(_ lines: [String], tail: String = "") -> String {
        n += 1
        let path = dir + "/t\(n).jsonl"
        try? (lines.map { $0 + "\n" }.joined() + tail).write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }
    func read(_ lines: [String], tail: String = "") -> BGState {
        var scan = BGScan()
        scan.advance(path: file(lines, tail: tail))
        return scan.state
    }
    func near(_ a: Date?, _ ago: TimeInterval) -> Bool { a.map { abs($0.timeIntervalSince(now.addingTimeInterval(-ago))) < 0.01 } ?? false }

    // ── 1. Starts and ends, one transcript at a time.
    var s = read([started("b1", 600)])
    check("bg: a background command begun and not ended counts — 1 task, 0 agents, since its line's moment", s.tasks == 1 && s.agents == 0 && near(s.since, 600))
    check("bg: nothing begun — 0 tasks, no since", read([said("hi")]).quiet && read([]).quiet)
    for status in ["completed", "failed", "killed", "stopped"] {
        check("bg: \(status) in a queue-operation enqueue ends it", read([started("b1", 600), queued("b1", status)]).quiet)
        check("bg: \(status) in a user line ends it", read([started("b1", 600), told("b1", status)]).quiet)
    }
    check("bg: both lines of one notification (enqueue, then the user line) end it once, and others stay",
        read([started("b1", 600), started("b2", 500), queued("b1", "completed"), told("b1", "completed")]).tasks == 1)
    s = read([timedOut("b9", 3000)])
    check("bg: a command moved to the background by its timeout counts too", s.tasks == 1 && s.agents == 0 && near(s.since, 3000))
    check("bg: TaskStop's result (task_id beside task_type) ends it, with no notification at all",
        read([started("b1", 600), stopped("b1")]).quiet)
    s = read([agent("a1", 900)])
    check("bg: an async subagent counts — 1 task, 1 agent", s.tasks == 1 && s.agents == 1 && near(s.since, 900))
    check("bg: an async subagent's completed notification ends it", read([agent("a1", 900), queued("a1", "completed")]).quiet)
    s = read([started("b1", 300), agent("a1", 900), started("b2", 100), queued("b1", "failed")])
    check("bg: mixed — 2 left (one agent), since is the earliest of those left (the agent's), not of those ended",
        s.tasks == 2 && s.agents == 1 && near(s.since, 900))
    s = read([agent("a1", 900), started("b1", 300), queued("a1", "killed")])
    check("bg: the earliest ended — since moves to the next", s.tasks == 1 && s.agents == 0 && near(s.since, 300))
    check("bg: a launch line twice (same id) is one task", read([started("b1", 600), started("b1", 600)]).tasks == 1)
    check("bg: a notice that comes before its launch line (never in practice) is still an end", read([queued("b1", "completed"), started("b1", 600)]).quiet)
    s = read([started("b1", 600), json(["type": "user", "isSidechain": false, "timestamp": stamp(1), "message": ["role": "user",
        "content": [["type": "text", "text": note("b1", "completed") + "\n" + note("b2", "failed")]]]]), started("b2", 500)])
    check("bg: a user line whose content is text blocks, with two notifications in it, ends both", s.quiet)
    func killedAgents(_ ago: TimeInterval) -> String {
        json(["type": "system", "subtype": "agents_killed", "isSidechain": false, "timestamp": stamp(ago)])
    }
    s = read([agent("a1", 900), started("b1", 800), agent("a2", 700), killedAgents(100), agent("a3", 50)])
    check("bg: agents_killed ends the subagents begun before it, not the commands, nor a subagent begun after it — 2 left (1 agent a3)",
        s.tasks == 2 && s.agents == 1 && near(s.since, 800))
    check("bg: agents_killed with no subagent running changes nothing", read([started("b1", 800), killedAgents(100)]).tasks == 1)
    check("bg: a system line of another subtype, or an assistant line saying agents_killed, ends nothing",
        read([agent("a1", 900), json(["type": "system", "subtype": "away_summary", "timestamp": stamp(1)]), said("agents_killed")]).tasks == 1)
    check("bg: a sidechain line is not the session's",
        read([json(["type": "user", "isSidechain": true, "timestamp": stamp(1), "toolUseResult": ["backgroundTaskId": "x1"], "message": ["role": "user", "content": "x"]])]).quiet)

    // ── 1b. bgEndedAt: the moment of the first line that ended the last task; bgOwned: begun since the last turn the user started.
    func at(_ lines: [String]) -> BGState { read(lines) }
    func ended(_ s: BGState, _ ago: TimeInterval) -> Bool { near(s.endedAt, ago) }
    func queuedAt(_ id: String, _ status: String, _ ago: TimeInterval) -> String {
        json(["type": "queue-operation", "operation": "enqueue", "timestamp": stamp(ago), "sessionId": "s", "content": note(id, status)])
    }
    func toldAt(_ id: String, _ status: String, _ ago: TimeInterval) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(ago), "message": ["role": "user", "content": note(id, status)]])
    }
    func stoppedAt(_ id: String, _ ago: TimeInterval) -> String {
        result(["message": "Successfully stopped task: \(id)", "task_id": id, "task_type": "local_bash"], ago)
    }
    func typed(_ text: String, _ ago: TimeInterval, extra: [String: Any] = [:]) -> String {
        // As Claude Code writes it: the message's role, then its content.
        let content = String(decoding: try! JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
        let rest = extra.filter { $0.key != "isSidechain" }
        let tail = rest.isEmpty ? "" : "," + String(json(rest).dropFirst().dropLast())
        return "{\"type\":\"user\",\"isSidechain\":\(extra["isSidechain"] as? Bool ?? false),\"timestamp\":\"\(stamp(ago))\",\"message\":{\"role\":\"user\",\"content\":\(content)}\(tail)}"
    }
    check("bg: bgEndedAt — nothing ended: nil", read([started("b1", 600)]).endedAt == nil && read([]).endedAt == nil)
    check("bg: bgEndedAt — a notification: its line's moment (the first line of it, not the later copy for the model)",
        ended(read([started("b1", 600), queuedAt("b1", "completed", 300), toldAt("b1", "completed", 200)]), 300)
            && ended(read([started("b1", 600), toldAt("b1", "failed", 250)]), 250))
    for status in ["failed", "killed", "stopped"] {
        check("bg: bgEndedAt — \(status) counts", ended(read([started("b1", 600), queuedAt("b1", status, 90)]), 90))
    }
    check("bg: bgEndedAt — running and bogus statuses are no end", read([started("b1", 600), queuedAt("b1", "running", 90)]).endedAt == nil)
    check("bg: bgEndedAt — a TaskStop's result", ended(read([started("b1", 600), stoppedAt("b1", 120)]), 120))
    check("bg: bgEndedAt — agents_killed", ended(read([agent("a1", 600), killedAgents(80)]), 80))
    check("bg: bgEndedAt — the last of several ends", ended(read([started("b1", 900), started("b2", 800), queuedAt("b1", "completed", 500), stoppedAt("b2", 100)]), 100))
    check("bg: bgEndedAt — kept when the others still run (the end of one of two)", { let r = read([started("b1", 900), started("b2", 800), queuedAt("b1", "completed", 500)]); return r.tasks == 1 && ended(r, 500) }())
    check("bg: bgOwned — false with no task, true once one was begun (command, timeout, subagent)",
        !read([typed("你好", 900)]).owned && read([typed("跑", 900), started("b1", 600)]).owned && read([typed("跑", 900), timedOut("b1", 600)]).owned
            && read([typed("跑", 900), agent("a1", 600)]).owned)
    check("bg: bgOwned — a turn he starts afterwards puts it back to false, the task still running",
        { let r = read([typed("跑", 900), started("b1", 600), typed("再来一个问题", 300)]); return !r.owned && r.tasks == 1 }())
    check("bg: bgOwned — a task begun in the new turn makes it true again",
        read([typed("跑", 900), started("b1", 600), typed("再来", 300), started("b2", 100)]).owned)
    check("bg: bgOwned — a notification turn, a peer's message, a meta record, a tool result and a sidechain turn are not his turns",
        read([typed("跑", 900), started("b1", 600), told("b1", "completed"), typed("Another Claude session sent a message:\n<cross-session-message from-name=\"x\">hi</cross-session-message>", 200),
              typed("<system-reminder>x</system-reminder>", 150, extra: ["isMeta": true]), typed("side", 100, extra: ["isSidechain": true]),
              result(["stdout": "ok"], 50)]).owned)
    let pictured = json(["type": "user", "isSidechain": false, "timestamp": stamp(300), "origin": ["kind": "human"], "promptSource": "typed",
        "message": ["role": "user", "content": [["type": "text", "text": "看这张图"], ["type": "image", "source": ["type": "base64", "data": "AAAA"]]]]])
    let toolResult = json(["type": "user", "isSidechain": false, "timestamp": stamp(200), "origin": ["kind": "human"],
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "ok"]]]])
    check("bg: bgOwned — a turn of his with a picture in it (content an array, marked typed/human) puts it back to false",
        !read([typed("跑", 900), started("b1", 600), pictured]).owned && read([typed("跑", 900), started("b1", 600), pictured, started("b2", 100)]).owned)
    check("bg: bgOwned — a tool_result line does not reset it, even marked human", read([typed("跑", 900), started("b1", 600), toolResult]).owned)
    check("bg: bgOwned — a task begun in a notification turn counts for the turn of his that came before",
        read([typed("跑", 900), told("x", "completed"), started("b2", 100)]).owned)

    // Read in pieces gives what reading at once gives: cut anywhere (also in the middle of a line), with the kept picture
    // written and read back between the pieces.
    let whole = [typed("跑", 900), started("b1", 800), agent("a1", 700), queuedAt("b1", "completed", 600), toldAt("b1", "completed", 590),
        typed("再来", 500), timedOut("b2", 400), stoppedAt("b2", 300), agent("a2", 200), killedAgents(100), typed("<task-notification>x</task-notification>", 90), started("b3", 50)]
    let wholeText = whole.map { $0 + "\n" }.joined()
    let wholePath = file(whole)
    var all = BGScan()
    all.advance(path: wholePath)
    var allSame = true, cuts = 0
    let bytes = Array(wholeText.utf8)
    for cut in stride(from: 1, to: bytes.count, by: 97) + [bytes.count - 1] {
        let growPath = dir + "/grow\(cut).jsonl"
        FileManager.default.createFile(atPath: growPath, contents: Data(bytes[..<cut]))
        var part = BGScan()
        part.advance(path: growPath)
        part = BGScan.decode(BGScan.encode(["s": part]))["s"] ?? BGScan()  // through the file
        let h = FileHandle(forWritingAtPath: growPath)!
        h.seekToEndOfFile(); h.write(Data(bytes[cut...])); try? h.close()
        part.advance(path: growPath)
        cuts += 1
        let a = part.state, b = all.state
        if !(a == b && part.ended == all.ended && part.started.keys == all.started.keys && part.offset == all.offset) { allSame = false }
    }
    check("bg: read in two pieces (\(cuts) cuts, some mid-line, the picture through its file between) is what reading at once gives, endedAt and owned too", allSame && cuts > 5)
    var three = BGScan()
    let threePath = dir + "/three.jsonl"
    FileManager.default.createFile(atPath: threePath, contents: nil)
    for piece in [bytes[..<150], bytes[150..<151], bytes[151..<700], bytes[700...]] {
        let h = FileHandle(forWritingAtPath: threePath)!
        h.seekToEndOfFile(); h.write(Data(piece)); try? h.close()
        three.advance(path: threePath)
    }
    check("bg: read in four pieces is the same too", three.state == all.state && three.ended == all.ended)

    // ── 2. only the lines of those kinds count, and as decoded.
    let quoted = [
        said(note("b1", "completed")),  // an assistant line quoting a notification
        json(["type": "user", "isSidechain": false, "timestamp": stamp(1), "message": ["role": "user", "content": "看这个：" + note("b1", "completed")]]),  // typed, quoting
        queued("b1", "completed", op: "dequeue"),  // not an enqueue
        queued("b1", "running"), queued("b1", "bogus"),  // not an ending status
        json(["type": "attachment", "timestamp": stamp(1), "content": note("b1", "completed")]),
        json(["type": "api-request-blob", "message": ["role": "user", "content": note("b1", "completed")]]),
        said("backgroundTaskId async_launched task_type"),  // the words alone
        json(["type": "user", "isSidechain": false, "timestamp": stamp(1), "toolUseResult": "an error text with backgroundTaskId", "message": ["role": "user", "content": "x"]]),
        result(["note": "backgroundTaskId", "task_id": "b1"], 1),  // a task_id with no task_type
        "{not json task-notification backgroundTaskId",
    ]
    check("bg: quotations and look-alikes end nothing and start nothing", read([started("b1", 600)] + quoted).tasks == 1 && read(quoted).quiet)

    // ── 3. A half-written last line is left for the next look; a file that grows is read from where it stopped.
    let full = started("b2", 400)
    let cut = full.index(full.startIndex, offsetBy: full.count / 2)
    let path = file([started("b1", 600)], tail: String(full[..<cut]))
    var scan = BGScan()
    scan.advance(path: path)
    let wholeLines = UInt64(started("b1", 600).utf8.count + 1)
    check("bg: a last line without its newline is not read — 1 task, offset at the end of the last whole line", scan.state.tasks == 1 && scan.offset == wholeLines)
    let handle = FileHandle(forWritingAtPath: path)!
    handle.seekToEndOfFile()
    handle.write(Data((String(full[cut...]) + "\n").utf8))
    try? handle.close()
    scan.advance(path: path)
    check("bg: once the line is finished it is read — 2 tasks", scan.state.tasks == 2 && scan.offset == UInt64((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)??.uint64Value ?? 0))
    var lone = BGScan()
    lone.advance(path: file([], tail: started("b1", 1)))
    check("bg: a file of one unfinished line shows nothing yet, offset 0", lone.state.quiet && lone.offset == 0)

    // ── 4. Incremental: only what was added is read.
    let growing = file([started("b1", 600), started("b2", 500)])
    var inc = BGScan()
    inc.advance(path: growing)
    let after1 = inc.offset
    inc.started["b2"] = nil  // if the next look read the file from the start again, b2 would be back
    try? FileHandle(forWritingAtPath: growing).map { h in
        h.seekToEndOfFile(); h.write(Data((queued("b1", "completed") + "\n").utf8)); try? h.close()
    }
    inc.advance(path: growing)
    check("bg: a look at a file that only grew reads only the new lines — b1 ended, b2 (dropped by hand) not re-read",
        inc.state.quiet && inc.offset > after1)
    let unchanged = inc.offset
    inc.advance(path: growing)
    check("bg: a look at an unchanged file changes nothing", inc.offset == unchanged && inc.state.quiet)
    try? FileHandle(forWritingAtPath: growing).map { h in
        h.seekToEndOfFile(); h.write(Data((agent("a7", 30) + "\n").utf8)); try? h.close()
    }
    inc.advance(path: growing)
    check("bg: a later launch appended is seen — 1 task, 1 agent", inc.state.tasks == 1 && inc.state.agents == 1)

    // ── 5. A shorter file, or another file, is read from the start.
    let shrink = file([started("b1", 600), started("b2", 500), started("b3", 400)])
    var sh = BGScan()
    sh.advance(path: shrink)
    check("bg: three begun", sh.state.tasks == 3)
    let keep = FileHandle(forUpdatingAtPath: shrink)!
    try? keep.truncate(atOffset: UInt64(started("b1", 600).utf8.count + 1))  // the same file, cut short
    try? keep.close()
    sh.advance(path: shrink)
    check("bg: the same file cut short is read again from the start — 1 task left, not 3", sh.state.tasks == 1 && near(sh.state.since, 600))
    let replaced = file([agent("a1", 50)])
    try? FileManager.default.removeItem(atPath: shrink)
    try? FileManager.default.copyItem(atPath: replaced, toPath: shrink)  // another inode, longer than what had been read
    var more = String(); for _ in 0..<5 { more += agent("a2", 10) + "\n" }
    try? FileHandle(forWritingAtPath: shrink).map { h in h.seekToEndOfFile(); h.write(Data(more.utf8)); try? h.close() }
    sh.advance(path: shrink)
    check("bg: a file put in the place of the old one (new inode) is read from the start — the old b1 is gone", sh.state.tasks == 2 && sh.state.agents == 2 && sh.path == shrink)

    // ── 6. stale: the earliest left began more than 2 hours ago.
    check("bg: stale is false at 1 h 59 min and true at 2 h 1 min of the earliest",
        !read([started("b1", 7140)]).stale(now: now) && read([started("b1", 7260)]).stale(now: now) && !BGState.none.stale(now: now))
    check("bg: stale goes by the earliest left — a 3 h one ended, a 10 min one left: not stale",
        !read([started("b1", 10800), started("b2", 600), queued("b1", "completed")]).stale(now: now))
    check("bg: stale goes by the earliest — a 3 h one left beside a new one: stale",
        read([started("b1", 10800), started("b2", 60)]).stale(now: now))

    // ── 7. Through the loader, as --dump reads it.
    let bench = RestartBench("bg")
    defer { bench.done() }
    func put(_ id: String, _ lines: [String], pid: Int32 = 1) {
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.map { $0 + "\n" }.joined()).write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        let ms = now.timeIntervalSince1970 * 1000
        let o: [String: Any] = ["pid": Int(pid), "sessionId": id, "status": "idle", "statusUpdatedAt": ms, "startedAt": ms, "name": "名-" + id, "nameSource": "user", "cwd": "/tmp/" + id]
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: bench.registry + "/\(id).json"))
    }
    func append(_ id: String, _ lines: [String]) {
        let h = FileHandle(forWritingAtPath: bench.dir + "/\(id).jsonl")!
        h.seekToEndOfFile(); h.write(Data(lines.map { $0 + "\n" }.joined().utf8)); try? h.close()
    }
    func row(_ list: [Session], _ id: String) -> [String: Any]? { list.first { $0.id == id }.map { dumpRow($0, model: "") } }
    put("bg-none", [said("hi")])
    put("bg-one", [started("b1", 600)])
    put("bg-mix", [agent("a1", 9000), started("b1", 300), started("b2", 200), queued("b2", "completed")])
    put("bg-done", [started("b1", 600), told("b1", "completed")])
    var list = bench.load(), rows = list.compactMap { row(list, $0.id) }
    check("bg: loader — a session with no task says 0, 0, null, false",
        row(list, "bg-none")?["bgTasks"] as? Int == 0 && row(list, "bg-none")?["bgAgents"] as? Int == 0
            && row(list, "bg-none")?["bgSince"] is NSNull && row(list, "bg-none")?["bgStale"] as? Bool == false)
    check("bg: loader — a running command: 1, 0, its moment in epoch seconds, false",
        row(list, "bg-one")?["bgTasks"] as? Int == 1 && row(list, "bg-one")?["bgAgents"] as? Int == 0 && row(list, "bg-one")?["bgStale"] as? Bool == false
            && abs((row(list, "bg-one")?["bgSince"] as? Double ?? 0) - (now.timeIntervalSince1970 - 600)) < 0.01)
    check("bg: loader — an agent and a command left, one command ended: 2, 1, the agent's moment, stale (2.5 h)",
        row(list, "bg-mix")?["bgTasks"] as? Int == 2 && row(list, "bg-mix")?["bgAgents"] as? Int == 1 && row(list, "bg-mix")?["bgStale"] as? Bool == true
            && abs((row(list, "bg-mix")?["bgSince"] as? Double ?? 0) - (now.timeIntervalSince1970 - 9000)) < 0.01)
    check("bg: loader — everything ended: 0, 0, null, false", row(list, "bg-done")?["bgTasks"] as? Int == 0 && row(list, "bg-done")?["bgSince"] is NSNull)
    check("bg: loader — bgEndedAt is the moment of the end (epoch seconds) where one ended, null where none; bgOwned true where a task was begun",
        row(list, "bg-done")?["bgEndedAt"] is Double && row(list, "bg-none")?["bgEndedAt"] is NSNull && row(list, "bg-none")?["bgOwned"] as? Bool == false
            && row(list, "bg-one")?["bgOwned"] as? Bool == true && row(list, "bg-mix")?["bgEndedAt"] is Double)
    let dump = String(decoding: try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    check("bg: dump — the four keys are in every row, bgSince null written as null, the others as numbers and booleans",
        rows.allSatisfy { ["bgTasks", "bgAgents", "bgSince", "bgStale"].allSatisfy($0.keys.contains) } && dump.contains("\"bgSince\" : null")
            && dump.contains("\"bgTasks\" : 2") && dump.contains("\"bgStale\" : true") && dump.contains("\"bgStale\" : false"))
    let oldKeys: Set<String> = ["id", "project", "name", "status", "waitingFor", "since", "summary", "kind", "model", "origin", "peer", "summaryCode", "summaryArgs", "nameUntitled"]
    check("bg: dump — the keys are the fourteen it had plus the seven and the ten error fields, none gone", rows.allSatisfy { Set($0.keys) == oldKeys.union(["bgTasks", "bgAgents", "bgSince", "bgStale", "bgEndedAt", "bgOwned", "bgList"]).union(summaryCodeErrorFieldKeys) })
    let bare = Session(id: "x", pid: 1, project: "p", name: "x", status: "idle", since: now, summary: "")
    let bareRow = dumpRow(bare, model: "")
    check("bg: a session made without any (Codex, WorkBuddy, the checks') is 0, 0, null, false",
        bareRow["bgTasks"] as? Int == 0 && bareRow["bgAgents"] as? Int == 0 && bareRow["bgSince"] is NSNull && bareRow["bgStale"] as? Bool == false
            && bareRow["bgEndedAt"] is NSNull && bareRow["bgOwned"] as? Bool == false)

    // The next look reads only what was added: b1 ends, a new subagent begins.
    append("bg-one", [queued("b1", "completed"), agent("a2", 20)])
    append("bg-done", [started("b5", 40)])
    list = bench.load()
    check("bg: loader — a second look after lines were appended shows the new state",
        row(list, "bg-one")?["bgTasks"] as? Int == 1 && row(list, "bg-one")?["bgAgents"] as? Int == 1
            && abs((row(list, "bg-one")?["bgSince"] as? Double ?? 0) - (now.timeIntervalSince1970 - 20)) < 0.01 && row(list, "bg-done")?["bgTasks"] as? Int == 1)
    append("bg-one", [stopped("a2")])
    list = bench.load()
    check("bg: loader — a TaskStop appended on a later look ends it", row(list, "bg-one")?["bgTasks"] as? Int == 0 && row(list, "bg-one")?["bgSince"] is NSNull)

    // A process that has gone: nothing, however the transcript stands.
    let gone = Process()
    gone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? gone.run()
    gone.waitUntilExit()
    put("bg-dead", [started("b1", 600), agent("a1", 500)], pid: gone.processIdentifier)
    check("bg: the process of a session is gone — its four fields are 0, 0, null, false (bgState), though its transcript has two running",
        bench.loader.bgState(sid: "bg-dead", pid: gone.processIdentifier).quiet && read([started("b1", 600), agent("a1", 500)]).tasks == 2)
    check("bg: loader — a registry file whose process is dead lists no session of the ordinary kind (only a disconnected one, with no task)",
        bench.load().filter { $0.id == "bg-dead" }.allSatisfy { $0.disconnected && $0.bgTasks == 0 && $0.bgAgents == 0 })
    put("bg-dead", [started("b1", 600)], pid: 1)
    check("bg: the same session with a live pid shows its task again (nothing was kept from the dead look)", row(bench.load(), "bg-dead")?["bgTasks"] as? Int == 1)

    // A session being restarted is shown as it was last read, but its process is going: no tasks.
    let restartBench = RestartBench("bg-restart")
    defer { restartBench.done() }
    let rpath = restartBench.dir + "/bg-r.jsonl"
    try? (started("b1", 600) + "\n").write(toFile: rpath, atomically: true, encoding: .utf8)
    restartBench.loader.remember(transcript: rpath, for: "bg-r")
    restartBench.open("bg-r", "idle", since: now)
    let before = restartBench.load().first { $0.id == "bg-r" }
    restartBench.restarting([("bg-r", 5)])
    restartBench.close("bg-r")
    let held = restartBench.load().first { $0.id == "bg-r" }
    check("bg: restart — a session shown as restarting says 0, 0, null, false although it had a task before",
        before?.bgTasks == 1 && held?.restarting == true && held?.bgTasks == 0 && held?.bgAgents == 0 && held?.bgSince == nil && held?.bgStale == false)

    // ── 8. Cost: a big transcript is read once, quickly, then not again.
    var big = ""
    let filler = json(["type": "assistant", "isSidechain": false, "timestamp": stamp(1), "message": ["role": "assistant", "content": [["type": "text", "text": String(repeating: "填充的一行，没有任务。", count: 90)]]]]) + "\n"
    for _ in 0..<2 { big += filler }
    let bigPath = dir + "/big.jsonl"
    FileManager.default.createFile(atPath: bigPath, contents: nil)
    let bh = FileHandle(forWritingAtPath: bigPath)!
    bh.write(Data((started("b1", 5000) + "\n").utf8))
    let block = Data(String(repeating: filler, count: 2000).utf8)  // about 5 MB
    for _ in 0..<8 { bh.write(block) }  // about 40 MB
    bh.write(Data((queued("b1", "completed") + "\n" + started("b2", 70) + "\n").utf8))
    try? bh.close()
    let size = (try? FileManager.default.attributesOfItem(atPath: bigPath)[.size] as? NSNumber)??.intValue ?? 0
    var bigScan = BGScan()
    let t0 = Date()
    bigScan.advance(path: bigPath)
    let first = Date().timeIntervalSince(t0)
    let t1 = Date()
    bigScan.advance(path: bigPath)
    let second = Date().timeIntervalSince(t1)
    print(String(format: "info  bg: %d MB read in %.2f s, a look with nothing new %.4f s", size / 1_000_000, first, second))
    check("bg: a \(size / 1_000_000) MB transcript — read through, b1 ended, b2 left, in under 5 s", bigScan.state.tasks == 1 && near(bigScan.state.since, 70) && first < 5)
    check("bg: a look at it with nothing new is under 50 ms", second < 0.05 && bigScan.offset == UInt64(size))

    // ── 9. The progress kept in a file, shared by the panel and every --dump (each a process of its own: here, each a Loader).
    let cacheBench = RestartBench("bg-cache")
    defer { cacheBench.done() }
    let cachePath = cacheBench.dir + "/cache/bg-scan.json"  // its folder is not there yet: made when first written
    func process() -> Loader {  // a new process: nothing in memory, the same file
        let noCLI = CodexSessions()
        noCLI.processes = { [] }
        let l = Loader(registry: cacheBench.registry, codex: noCLI, restarting: cacheBench.list, bgCache: cachePath)
        for id in ["c1", "c2", "c3"] { l.remember(transcript: cacheBench.dir + "/\(id).jsonl", for: id) }
        return l
    }
    func cput(_ id: String, _ lines: [String], pid: Int32 = 1) {
        try? (lines.map { $0 + "\n" }.joined()).write(toFile: cacheBench.dir + "/\(id).jsonl", atomically: true, encoding: .utf8)
        let ms = now.timeIntervalSince1970 * 1000
        let o: [String: Any] = ["pid": Int(pid), "sessionId": id, "status": "idle", "statusUpdatedAt": ms, "startedAt": ms, "name": "名-" + id, "nameSource": "user", "cwd": "/tmp/" + id]
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: cacheBench.registry + "/\(id).json"))
    }
    func cappend(_ id: String, _ lines: [String]) {
        let h = FileHandle(forWritingAtPath: cacheBench.dir + "/\(id).jsonl")!
        h.seekToEndOfFile(); h.write(Data(lines.map { $0 + "\n" }.joined().utf8)); try? h.close()
    }
    func csize(_ id: String) -> UInt64 { UInt64((try? FileManager.default.attributesOfItem(atPath: cacheBench.dir + "/\(id).jsonl")[.size] as? NSNumber)??.uint64Value ?? 0) }
    func cstate(_ l: Loader, _ id: String) -> (Int, Int) { l.load().first { $0.id == id }.map { ($0.bgTasks, $0.bgAgents) } ?? (-1, -1) }
    func cacheKeys() -> Set<String> {
        let o = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: cachePath)))) as? [String: Any]
        return Set((o?["sessions"] as? [String: Any])?.keys.map { $0 } ?? [])
    }
    cput("c1", [started("b1", 600), started("b2", 500), agent("a1", 400)])
    cput("c2", [started("b3", 300)])
    var bytes0 = bgBytesRead
    let firstLoad = process().load()
    let c1First = firstLoad.first { $0.id == "c1" }
    let readAll: Bool = bgBytesRead - bytes0 == csize("c1") + csize("c2")
    check("bg cache: the first look reads each transcript whole and writes the file (the folder made)",
        readAll && FileManager.default.fileExists(atPath: cachePath) && c1First?.bgTasks == 3 && c1First?.bgAgents == 1 && cacheKeys() == ["c1", "c2"])
    bytes0 = bgBytesRead
    let secondLoad = process().load()
    let c1Second = secondLoad.first { $0.id == "c1" }, c2Second = secondLoad.first { $0.id == "c2" }
    let noBytes: Bool = bgBytesRead == bytes0
    let sameSince: Bool = c1Second?.bgSince == c1First?.bgSince
    check("bg cache: a new process with the file reads no byte of the transcripts, and says the same",
        noBytes && c1Second?.bgTasks == 3 && sameSince && c2Second?.bgTasks == 1)
    let grown = [queued("b1", "completed"), agent("a2", 20)]
    let added = UInt64(grown.map { $0.utf8.count + 1 }.reduce(0, +))
    cappend("c1", grown)
    bytes0 = bgBytesRead
    let third = process()
    check("bg cache: after lines were added a new process reads only those bytes (\(added)) and shows the new state: 3 left, 2 agents",
        { let r = cstate(third, "c1"); return bgBytesRead - bytes0 == added && r == (3, 2) }())
    bytes0 = bgBytesRead
    check("bg cache: the process after that, again nothing", { let r = cstate(process(), "c1"); return bgBytesRead == bytes0 && r == (3, 2) }())

    // Damaged, or of another version: start over, and write a good one.
    for (what, content) in [("not JSON", "{{{ nope"), ("empty", ""), ("another version", #"{"version":99,"sessions":{}}"#),
        ("no version", #"{"sessions":{}}"#), ("an entry not as written", #"{"version":1,"sessions":{"c1":{"path":3}}}"#)] {
        try? content.write(toFile: cachePath, atomically: true, encoding: .utf8)
        bytes0 = bgBytesRead
        let r = cstate(process(), "c1")
        check("bg cache: a file that is \(what) counts as none — read whole again, same state, and a good file written",
            bgBytesRead - bytes0 >= csize("c1") && r == (3, 2) && cacheKeys().contains("c1") && !BGScan.decode(FileManager.default.contents(atPath: cachePath)).isEmpty)
    }
    try? FileManager.default.removeItem(atPath: cachePath)
    bytes0 = bgBytesRead
    check("bg cache: no file at all — read whole", { let r = cstate(process(), "c1"); return bgBytesRead - bytes0 >= csize("c1") && r == (3, 2) }())

    // The file it was kept for has changed: shorter, or another file in its place.
    var cached = BGScan.decode(FileManager.default.contents(atPath: cachePath))
    cached["c1"]?.offset += 1000  // as if it had read more than the file has
    try? BGScan.encode(cached).write(to: URL(fileURLWithPath: cachePath))
    check("bg cache: kept offset beyond the end of the file (it was cut short) — read again from the start", cstate(process(), "c1") == (3, 2))
    cached["c1"]?.inode += 1
    try? BGScan.encode(cached).write(to: URL(fileURLWithPath: cachePath))
    bytes0 = bgBytesRead
    check("bg cache: kept inode not the file's (another file there) — read whole", { let r = cstate(process(), "c1"); return bgBytesRead - bytes0 >= csize("c1") && r == (3, 2) }())
    cached["c1"]?.started["zz"] = BGTask(at: now, agent: true)  // a task that is in the kept picture only
    cached["c1"]?.path = "/elsewhere"
    try? BGScan.encode(cached).write(to: URL(fileURLWithPath: cachePath))
    check("bg cache: kept path not the transcript's — read whole, the phantom task gone", cstate(process(), "c1") == (3, 2))

    // Two processes taking turns: each has its own picture in memory and writes it whole; the last to write stands.
    cput("c3", [started("d1", 100)])
    let pa = process(), pb = process()
    var ok = cstate(pa, "c3") == (1, 0)
    cappend("c3", [agent("d2", 50)])
    ok = ok && cstate(pb, "c3") == (2, 1)  // b starts from a's file, reads only the added line
    cappend("c3", [queued("d1", "completed")])
    ok = ok && cstate(pa, "c3") == (1, 1)  // a goes on from its own offset; its write replaces b's
    bytes0 = bgBytesRead
    ok = ok && cstate(process(), "c3") == (1, 1) && bgBytesRead == bytes0  // a new process after a's write: complete, nothing to read
    cappend("c3", [stopped("d2")])
    ok = ok && cstate(pb, "c3") == (0, 0) && cstate(process(), "c3") == (0, 0)  // b writes last, from its older picture: still right
    cappend("c3", [started("d3", 10)])
    ok = ok && cstate(pa, "c3") == (1, 0) && cstate(pb, "c3") == (1, 0) && cstate(process(), "c3") == (1, 0)
    check("bg cache: two processes taking turns, appends between — every look right, whichever wrote last", ok)
    check("bg cache: no scratch file is left beside it",
        ((try? FileManager.default.contentsOfDirectory(atPath: (cachePath as NSString).deletingLastPathComponent)) ?? []) == ["bg-scan.json"])

    // Sessions gone from the registry, or with a dead process, leave the file.
    check("bg cache: three sessions kept so far", cacheKeys() == ["c1", "c2", "c3"])
    cacheBench.close("c2")
    _ = process().load()
    check("bg cache: a session no longer in the registry is let go from the file", cacheKeys() == ["c1", "c3"])
    let gone2 = Process()
    gone2.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? gone2.run()
    gone2.waitUntilExit()
    cput("c3", [started("d1", 100)], pid: gone2.processIdentifier)
    let afterDead = process().load()
    check("bg cache: a session whose process died is let go too (and listed, if at all, as disconnected)", cacheKeys() == ["c1"] && afterDead.filter { $0.id == "c3" }.allSatisfy { $0.disconnected })
    let sized = (try? FileManager.default.attributesOfItem(atPath: cachePath)[.size] as? NSNumber)??.intValue ?? 0
    check("bg cache: the file is small (one session, three tasks: \(sized) bytes)", sized > 0 && sized < 2000)

    // ── 10. bgList: the tasks one by one — kind, desc, since, id, toolUseId.
    func bashUse(_ use: String, desc: String?, command: String, ago: TimeInterval, sidechain: Bool = false, more: [(String, String?, String)] = []) -> String {
        func block(_ id: String, _ d: String?, _ c: String) -> [String: Any] {
            var input: [String: Any] = ["command": c, "run_in_background": true]
            if let d { input["description"] = d }
            return ["type": "tool_use", "id": id, "name": "Bash", "input": input, "caller": ["type": "direct"]]
        }
        return json(["type": "assistant", "isSidechain": sidechain, "timestamp": stamp(ago),
                     "message": ["role": "assistant", "content": [block(use, desc, command)] + more.map { block($0.0, $0.1, $0.2) }]])
    }
    func launchRes(_ use: String, _ id: String, _ ago: TimeInterval, timeout: Bool = false) -> String {
        var r: [String: Any] = ["stdout": "", "stderr": "", "interrupted": false, "backgroundTaskId": id]
        if timeout { r["timedOutAfterMs"] = 120000; r["backgroundCwdHint"] = "/tmp" }
        return json(["type": "user", "isSidechain": false, "timestamp": stamp(ago), "toolUseResult": r,
                     "message": ["role": "user", "content": [["tool_use_id": use, "type": "tool_result", "content": "Command running in background with ID: \(id).", "is_error": false]]]])
    }
    func agentRes(_ use: String, _ id: String, _ words: String, _ ago: TimeInterval) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(ago),
              "toolUseResult": ["isAsync": true, "status": "async_launched", "agentId": id, "description": words, "prompt": "p", "outputFile": "/tmp/x"],
              "message": ["role": "user", "content": [["tool_use_id": use, "type": "tool_result", "content": [["type": "text", "text": "Async agent launched successfully.\nagentId: \(id)"]]]]]])
    }
    func plainRes(_ use: String) -> String {
        json(["type": "user", "isSidechain": false, "timestamp": stamp(1), "toolUseResult": ["stdout": "ok", "stderr": "", "interrupted": false],
              "message": ["role": "user", "content": [["tool_use_id": use, "type": "tool_result", "content": "ok", "is_error": false]]]])
    }
    func items(_ lines: [String]) -> [BGItem] { read(lines).list }

    var li = items([bashUse("toolu_A", desc: "Run the build", command: "make all", ago: 610), launchRes("toolu_A", "bx1", 600)])
    check("bglist: a background command — kind cmd, desc from the Bash call's description, since its start line's moment, id the backgroundTaskId, toolUseId the call's",
        li.count == 1 && li[0].kind == "cmd" && li[0].desc == "Run the build" && near(li[0].since, 600) && li[0].id == "bx1" && li[0].toolUseId == "toolu_A")
    li = items([bashUse("toolu_B", desc: "Wait for the pull", command: "sleep 999", ago: 400), launchRes("toolu_B", "bx2", 100, timeout: true)])
    check("bglist: a command moved to the background by its timeout — also cmd, with the call's description and ids",
        li.count == 1 && li[0].kind == "cmd" && li[0].desc == "Wait for the pull" && li[0].id == "bx2" && li[0].toolUseId == "toolu_B" && near(li[0].since, 100))
    li = items([agentRes("toolu_C", "ag1", "Survey the repo", 300)])
    check("bglist: a background subagent — kind agent, desc from the launch result, id the agentId, toolUseId the line's tool_result's",
        li.count == 1 && li[0].kind == "agent" && li[0].desc == "Survey the repo" && li[0].id == "ag1" && li[0].toolUseId == "toolu_C" && near(li[0].since, 300))
    li = items([bashUse("toolu_D", desc: nil, command: "ssh demo-host 'systemctl status chat-archive'", ago: 50), launchRes("toolu_D", "bx3", 40)])
    check("bglist: no description — the start of the command", li.first?.desc == "ssh demo-host 'systemctl status chat-archive'")
    li = items([bashUse("toolu_D", desc: "", command: "echo 空描述", ago: 50), launchRes("toolu_D", "bx3", 40)])
    check("bglist: an empty description counts as none", li.first?.desc == "echo 空描述")
    let longCommand = String(repeating: "abcdefghij", count: 20)
    li = items([bashUse("toolu_E", desc: nil, command: longCommand, ago: 50), launchRes("toolu_E", "bx4", 40)])
    check("bglist: a command of 200 characters and no description — its first 80", li.first?.desc == String(longCommand.prefix(80)) && li.first?.desc.count == 80)
    li = items([bashUse("toolu_F", desc: String(repeating: "长", count: 120), command: "x", ago: 50), launchRes("toolu_F", "bx5", 40)])
    check("bglist: a description of 120 characters is cut to 80 (characters, not bytes)", li.first?.desc == String(repeating: "长", count: 80))
    li = items([bashUse("toolu_G", desc: "line one\nline two\r\nline three\rfour", command: "x", ago: 50), launchRes("toolu_G", "bx6", 40)])
    check("bglist: line breaks in a description become spaces", li.first?.desc == "line one line two line three four")
    li = items([bashUse("toolu_H", desc: nil, command: "cd /tmp\nsleep 5\nls", ago: 50), launchRes("toolu_H", "bx7", 40)])
    check("bglist: line breaks in a command used as the description become spaces too", li.first?.desc == "cd /tmp sleep 5 ls")
    li = items([bashUse("toolu_I", desc: nil, command: String(repeating: "a", count: 78) + "\nbcd", ago: 50), launchRes("toolu_I", "bx8", 40)])
    check("bglist: the break is turned into a space before the cut — 78 letters, a space, a letter", li.first?.desc == String(repeating: "a", count: 78) + " b")
    li = items([agentRes("toolu_J", "ag2", "Sub\nagent " + String(repeating: "x", count: 100), 30)])
    check("bglist: a subagent's description goes through the same: no line breaks, 80 at most", li.first.map { $0.desc.count == 80 && !$0.desc.contains("\n") && $0.desc.hasPrefix("Sub agent x") } == true)
    li = items([launchRes("toolu_K", "bx9", 30)])
    check("bglist: a command whose call was never seen — desc empty, toolUseId from the result, still listed", li.count == 1 && li[0].desc == "" && li[0].toolUseId == "toolu_K")
    li = items([bashUse("toolu_L", desc: "side", command: "x", ago: 50, sidechain: true), launchRes("toolu_L", "bx10", 40)])
    check("bglist: a Bash call of a sidechain is not noted (desc empty)", li.first?.desc == "")
    li = items([
        bashUse("toolu_P1", desc: "first of two", command: "a", ago: 90, more: [("toolu_P2", "second of two", "b")]),
        launchRes("toolu_P2", "px2", 60), launchRes("toolu_P1", "px1", 70)])
    check("bglist: two Bash calls in one reply, answered in turn — each its own desc and toolUseId",
        li.count == 2 && li[0].id == "px1" && li[0].desc == "first of two" && li[0].toolUseId == "toolu_P1" && li[1].id == "px2" && li[1].desc == "second of two" && li[1].toolUseId == "toolu_P2")

    // The list is the tasks left: as many as bgTasks, earliest first, the same moment by id.
    let mixed = [bashUse("t1", desc: "cmd late", command: "x", ago: 300), launchRes("t1", "z-late", 200),
                 agentRes("t2", "a-early", "agent early", 500),
                 bashUse("t3", desc: "tie 2", command: "x", ago: 150), launchRes("t3", "m2", 100),
                 bashUse("t4", desc: "tie 1", command: "x", ago: 150), launchRes("t4", "m1", 100)]
    var mState = read(mixed)
    check("bglist: length is bgTasks; earliest first, a tie by id", mState.list.count == mState.tasks && mState.tasks == 4
        && mState.list.map(\.id) == ["a-early", "z-late", "m1", "m2"])
    check("bglist: the earliest's since is bgSince", mState.list.first?.since == mState.since && mState.agents == mState.list.filter { $0.kind == "agent" }.count)

    // Ends: a notification (both lines), a TaskStop, agents_killed.
    mState = read(mixed + [queued("z-late", "completed")])
    check("bglist: a task-notification (queued) takes the task out; length follows bgTasks", mState.list.map(\.id) == ["a-early", "m1", "m2"] && mState.tasks == 3)
    mState = read(mixed + [told("m1", "failed")])
    check("bglist: a task-notification (user line, failed) takes it out", mState.list.map(\.id) == ["a-early", "z-late", "m2"] && mState.tasks == 3)
    mState = read(mixed + [stopped("m2"), queued("a-early", "killed")])
    check("bglist: a TaskStop and a killed notification take theirs out", mState.list.map(\.id) == ["z-late", "m1"] && mState.tasks == 2)
    mState = read(mixed + [killedAgents(10)])
    check("bglist: agents_killed takes out the subagents and leaves the commands", mState.list.map(\.id) == ["z-late", "m1", "m2"] && mState.agents == 0 && mState.tasks == 3)
    mState = read(mixed + [queued("z-late", "completed"), queued("a-early", "completed"), queued("m1", "stopped"), queued("m2", "completed")])
    check("bglist: all ended — an empty list, as bgTasks 0", mState.list.isEmpty && mState.quiet)
    check("bglist: nothing begun — an empty list", read([said("hi")]).list.isEmpty && BGState.none.list.isEmpty)

    // The table of calls waiting for their answer: emptied as answers come, so the file does not grow.
    var table = BGScan()
    let tablePath = file([bashUse("w1", desc: "d", command: "c", ago: 20)])
    table.advance(path: tablePath)
    check("bglist: a Bash call without its answer yet waits in the table", table.asked == ["w1": "d"])
    try? FileHandle(forWritingAtPath: tablePath).map { h in h.seekToEndOfFile(); h.write(Data((plainRes("w1") + "\n").utf8)); try? h.close() }
    table.advance(path: tablePath)
    check("bglist: the answer, read on a later look, takes it out (an ordinary command, no task)", table.asked.isEmpty && table.state.list.isEmpty)
    var manyLines: [String] = []
    for i in 0..<400 { manyLines += [bashUse("m\(i)", desc: "call \(i)", command: "c", ago: 100), plainRes("m\(i)")] }
    for i in 0..<20 { manyLines += [bashUse("g\(i)", desc: "bg \(i)", command: "c", ago: 100), launchRes("g\(i)", "gid\(i)", 90), queued("gid\(i)", "completed")] }
    manyLines += [bashUse("par1", desc: "p1", command: "c", ago: 5, more: [("par2", "p2", "c")]), plainRes("par2"), plainRes("par1")]
    var tableBig = BGScan()
    tableBig.advance(path: file(manyLines))
    check("bglist: 400 ordinary calls, 20 that went to the background and ended, two in parallel — the table is empty at the end, nothing left", tableBig.asked.isEmpty && tableBig.state.list.isEmpty)
    let tableFile = BGScan.encode(["s": tableBig]).count
    check("bglist: so the kept picture stays small (\(tableFile) bytes for 20 ended tasks, no pending call)", tableFile < 3000)
    var tableOpen = BGScan()
    tableOpen.advance(path: file(manyLines + [bashUse("open1", desc: "still waiting", command: "c", ago: 1)]))
    check("bglist: a call still waiting at the end is the only one in the table", tableOpen.asked == ["open1": "still waiting"])
    var tableLoad = BGScan.decode(BGScan.encode(["s": tableOpen]))["s"] ?? BGScan()
    check("bglist: the table goes through the file and back", tableLoad.asked == ["open1": "still waiting"])
    _ = tableLoad.asked.removeValue(forKey: "open1")

    // Through the file, a call and its answer in different looks: desc and toolUseId kept with the task.
    let splitLines = [bashUse("s1", desc: "split call", command: "c", ago: 70), launchRes("s1", "sp1", 60), agentRes("s2", "spa", "split agent", 50),
                      bashUse("s3", desc: nil, command: "echo 分段", ago: 40), launchRes("s3", "sp3", 30, timeout: true), queued("sp1", "completed")]
    let splitAll = read(splitLines)
    let splitText = Array((splitLines.map { $0 + "\n" }.joined()).utf8)
    var splitOK = true, splitCuts = 0
    for cutAt in stride(from: 1, to: splitText.count, by: 53) {
        let p = dir + "/split\(cutAt).jsonl"
        FileManager.default.createFile(atPath: p, contents: Data(splitText[..<cutAt]))
        var part = BGScan()
        part.advance(path: p)
        part = BGScan.decode(BGScan.encode(["s": part]))["s"] ?? BGScan()
        let h = FileHandle(forWritingAtPath: p)!
        h.seekToEndOfFile(); h.write(Data(splitText[cutAt...])); try? h.close()
        part.advance(path: p)
        splitCuts += 1
        if part.state != splitAll || part.state.list != splitAll.list || !part.asked.isEmpty { splitOK = false }
    }
    check("bglist: read in two pieces at \(splitCuts) cuts (a call and its answer on either side of a cut too, through the file between) gives the same list as at once",
        splitOK && splitCuts > 10 && splitAll.list.map(\.desc) == ["split agent", "echo 分段"] && splitAll.list.map(\.toolUseId) == ["s2", "s3"])
    var splitFour = BGScan()
    let fourPath = dir + "/splitfour.jsonl"
    FileManager.default.createFile(atPath: fourPath, contents: nil)
    for piece in [splitText[..<120], splitText[120..<121], splitText[121..<700], splitText[700...]] {
        let h = FileHandle(forWritingAtPath: fourPath)!
        h.seekToEndOfFile(); h.write(Data(piece)); try? h.close()
        splitFour.advance(path: fourPath)
    }
    check("bglist: read in four pieces gives the same list too", splitFour.state == splitAll && splitFour.state.list == splitAll.list)

    // Through the loader, as --dump: the rows' bgList, the keys of each item, the cache.
    put("bl-none", [said("hi")])
    put("bl-two", [bashUse("t1", desc: "Deploy the thing", command: "x", ago: 400), launchRes("t1", "c-1", 300), agentRes("t2", "ag-1", "Review it", 200)])
    put("bl-done", [bashUse("t1", desc: "Short", command: "x", ago: 400), launchRes("t1", "c-1", 300), told("c-1", "completed")])
    var blList = bench.load()
    let blTwo = row(blList, "bl-two")?["bgList"] as? [[String: Any]]
    check("bglist: the dump row — an array of the items as dictionaries with kind, desc, since (epoch seconds), id, toolUseId; as long as bgTasks",
        blTwo?.count == 2 && row(blList, "bl-two")?["bgTasks"] as? Int == 2 && blTwo?.allSatisfy { Set($0.keys) == ["kind", "desc", "since", "id", "toolUseId"] } == true
            && blTwo?[0]["kind"] as? String == "cmd" && blTwo?[0]["desc"] as? String == "Deploy the thing" && blTwo?[0]["id"] as? String == "c-1" && blTwo?[0]["toolUseId"] as? String == "t1"
            && abs((blTwo?[0]["since"] as? Double ?? 0) - (now.timeIntervalSince1970 - 300)) < 0.01
            && blTwo?[1]["kind"] as? String == "agent" && blTwo?[1]["desc"] as? String == "Review it" && blTwo?[1]["id"] as? String == "ag-1" && blTwo?[1]["toolUseId"] as? String == "t2")
    check("bglist: where nothing runs (never any, or all ended) it is []",
        (row(blList, "bl-none")?["bgList"] as? [Any])?.isEmpty == true && (row(blList, "bl-done")?["bgList"] as? [Any])?.isEmpty == true)
    check("bglist: a session made without any (Codex, WorkBuddy, the checks') says []", (bareRow["bgList"] as? [Any])?.isEmpty == true)
    let blRows = blList.map { dumpRow($0, model: "") }
    let blDump = String(decoding: try! JSONSerialization.data(withJSONObject: blRows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    check("bglist: in the written dump the key is there for every row, the strings and the since number as written",
        blRows.allSatisfy { $0["bgList"] is [Any] } && blDump.contains("\"desc\" : \"Deploy the thing\"") && blDump.contains("\"toolUseId\" : \"t2\"") && blDump.contains("\"kind\" : \"agent\""))
    append("bl-two", [queued("c-1", "completed")])
    blList = bench.load()
    check("bglist: a task ended on a later look leaves the list (the other stays, desc intact)",
        (row(blList, "bl-two")?["bgList"] as? [[String: Any]])?.map { $0["id"] as? String ?? "" } == ["ag-1"] && row(blList, "bl-two")?["bgTasks"] as? Int == 1)
    append("bl-two", [bashUse("t9", desc: "Later one", command: "x", ago: 20), launchRes("t9", "c-9", 10, timeout: true)])
    blList = bench.load()
    check("bglist: a call and its answer appended on a later look make a new item", (row(blList, "bl-two")?["bgList"] as? [[String: Any]])?.last?["desc"] as? String == "Later one")

    // A process gone, a session being restarted: [].
    let blGone = Process()
    blGone.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? blGone.run()
    blGone.waitUntilExit()
    put("bl-dead", [bashUse("t1", desc: "Dies", command: "x", ago: 400), launchRes("t1", "c-1", 300)], pid: blGone.processIdentifier)
    check("bglist: the process of a session is gone — [] though its transcript has a running task", bench.loader.bgState(sid: "bl-dead", pid: blGone.processIdentifier).list.isEmpty)
    let blBench = RestartBench("bglist-restart")
    defer { blBench.done() }
    let blPath = blBench.dir + "/bl-r.jsonl"
    try? ([bashUse("t1", desc: "Running", command: "x", ago: 400), launchRes("t1", "c-1", 300)].map { $0 + "\n" }.joined()).write(toFile: blPath, atomically: true, encoding: .utf8)
    blBench.loader.remember(transcript: blPath, for: "bl-r")
    blBench.open("bl-r", "idle", since: now)
    let blBefore = blBench.load().first { $0.id == "bl-r" }
    blBench.restarting([("bl-r", 5)])
    blBench.close("bl-r")
    let blHeld = blBench.load().first { $0.id == "bl-r" }
    check("bglist: a session shown as restarting says [] although it had a task before",
        blBefore?.bgList.count == 1 && blHeld?.restarting == true && blHeld?.bgList.isEmpty == true && blHeld.map { dumpRow($0, model: "")["bgList"] is [Any] } == true)

    // The cache: version 3; an older file is read as none and the transcripts scanned again, for the desc and toolUseId it did not keep.
    check("bglist: the cache version is 3 (the file written says so)", bgCacheVersion == 3
        && ((try? JSONSerialization.jsonObject(with: BGScan.encode([:]))) as? [String: Any])?["version"] as? Int == 3)
    let verBench = RestartBench("bglist-ver")
    defer { verBench.done() }
    let verCache = verBench.dir + "/cache/bg-scan.json"
    let verTranscript = verBench.dir + "/v1.jsonl"
    try? ([bashUse("t1", desc: "Old cache task", command: "x", ago: 400), launchRes("t1", "c-1", 300)].map { $0 + "\n" }.joined()).write(toFile: verTranscript, atomically: true, encoding: .utf8)
    func verProcess() -> Loader {
        let noCLI = CodexSessions()
        noCLI.processes = { [] }
        let l = Loader(registry: verBench.registry, codex: noCLI, restarting: verBench.list, bgCache: verCache)
        l.remember(transcript: verTranscript, for: "v1")
        return l
    }
    let verMs = now.timeIntervalSince1970 * 1000
    try? JSONSerialization.data(withJSONObject: ["pid": 1, "sessionId": "v1", "status": "idle", "statusUpdatedAt": verMs, "startedAt": verMs, "name": "v1", "nameSource": "user", "cwd": "/tmp/v1"] as [String: Any])
        .write(to: URL(fileURLWithPath: verBench.registry + "/v1.json"))
    let verSize = UInt64((try? FileManager.default.attributesOfItem(atPath: verTranscript)[.size] as? NSNumber)??.uint64Value ?? 0)
    _ = verProcess().load()
    var verBytes = bgBytesRead
    let verAgain = verProcess().load().first
    check("bglist: with a cache of this version a new process reads no byte and still gives the list (desc, toolUseId from the file)",
        bgBytesRead == verBytes && verAgain?.bgList.first?.desc == "Old cache task" && verAgain?.bgList.first?.toolUseId == "t1")
    // A version-2 file (no desc, no toolUseId): same transcript, an older format.
    let v2File = #"{"version":2,"sessions":{"v1":{"path":"\#(verTranscript)","inode":1,"offset":99999,"started":{"c-1":{"at":1.0,"agent":false}},"ended":[],"endedAt":null,"owned":true}}}"#
    try? v2File.write(toFile: verCache, atomically: true, encoding: .utf8)
    check("bglist: a cache of version 2 is read as none", BGScan.decode(FileManager.default.contents(atPath: verCache)).isEmpty)
    verBytes = bgBytesRead
    let verRescan = verProcess().load().first
    check("bglist: so the transcript is scanned again from the start, and the list has what the old file could not hold",
        bgBytesRead - verBytes == verSize && verRescan?.bgList.count == 1 && verRescan?.bgList.first?.desc == "Old cache task" && verRescan?.bgList.first?.id == "c-1"
            && (((try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: verCache)))) as? [String: Any])?["version"] as? Int) == 3)
    // An entry of the right version but without the new keys is dropped alone.
    let v3Bad = #"{"version":3,"sessions":{"v1":{"path":"/x","inode":1,"offset":1,"started":{"c-1":{"at":1.0,"agent":false}},"ended":[],"endedAt":null,"owned":true,"asked":{}}}}"#
    check("bglist: an entry whose task lacks desc / toolUseId is not believed (dropped, scanned again)", BGScan.decode(v3Bad.data(using: .utf8)).isEmpty)
}
