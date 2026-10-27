// The checks of `--dump`'s slow log (`dump-slow.log`), run alone with `--dumplog-only`. Every run here is
// `runDump` on a made-up registry and a folder of its own for the log; the machine's own sessions and log are not touched.

import Foundation

@MainActor func dumpLogTests() {
    let dir = NSTemporaryDirectory() + "dumplog-tests-\(getpid())"
    let files = FileManager.default
    try? files.removeItem(atPath: dir)
    try? files.createDirectory(atPath: dir + "/sessions", withIntermediateDirectories: true)
    defer { try? files.removeItem(atPath: dir) }
    let saved = appSessionsLive
    appSessionsLive = false
    defer { appSessionsLive = saved; dumpStageHook = nil }

    let now = Date()
    let stamp = codexStamps.string(from: now.addingTimeInterval(-50))
    let ms = now.timeIntervalSince1970 * 1000
    func put(_ id: String, pid: Int) {
        let o: [String: Any] = ["pid": pid, "sessionId": id, "status": "idle", "statusUpdatedAt": ms, "startedAt": ms, "name": "名-" + id, "nameSource": "user", "cwd": "/tmp/" + id]
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: dir + "/sessions/\(id).json"))
    }
    let launch: [String: Any] = ["type": "user", "isSidechain": false, "timestamp": stamp, "toolUseResult": ["stdout": "", "backgroundTaskId": "b1"],
        "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "x"]]]]
    let said: [String: Any] = ["type": "assistant", "isSidechain": false, "timestamp": stamp, "message": ["role": "assistant", "content": [["type": "text", "text": "好了"]]]]
    var body = ""
    for o in [launch, said] { body += String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) + "\n" }
    let transcript = dir + "/d1.jsonl"
    try? body.write(toFile: transcript, atomically: true, encoding: .utf8)
    let transcriptSize = body.utf8.count
    put("d1", pid: 1)
    let dead = Process()
    dead.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try? dead.run()
    dead.waitUntilExit()
    put("d2", pid: Int(dead.processIdentifier))

    func process() -> Loader {  // a new process: nothing in memory, the same files
        let noCLI = CodexSessions()
        noCLI.processes = { [] }
        let l = Loader(registry: dir + "/sessions", codex: noCLI, restarting: dir + "/none.json", bgCache: dir + "/caches/bg-scan.json", goneCache: dir + "/caches/gone.json")
        l.remember(transcript: transcript, for: "d1")
        return l
    }
    func run(_ log: String, _ env: [String: String] = [:]) -> String {
        var out = ""
        runDump(process(), now: now, environment: env, logFolder: log) { out = $0 }
        return out
    }
    func lines(_ log: String) -> [String] {
        (try? String(contentsOfFile: log + "/dump-slow.log", encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
    }
    func field(_ line: String, _ key: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }
    func number(_ text: String?) -> Double? { text.flatMap { Double($0.replacingOccurrences(of: "ms", with: "")) } }

    // ── 1. A run over the threshold leaves its line, with every field.
    let slow = dir + "/log-slow"
    let a = run(slow, ["SOULGENT_DUMP_SLOW_MS": "0"])
    let first = lines(slow)
    check("dumplog: threshold 0 — one line written", first.count == 1)
    let line = first.first ?? ""
    let stages = ["registry", "restartList", "tailInfo", "bgCacheRead", "bgScan", "bgCacheWrite", "goneRead", "goneWrite", "codexCLI", "codexApp", "workbuddy",
        "runningApp", "subagents", "serialize", "output", "other"]
    let missing = stages.filter { field(line, $0) == nil }
    check("dumplog: the line has every stage (missing: \(missing))", missing.isEmpty)
    check("dumplog: total, pid, load, sessions and the time are there",
        number(field(line, "total")) != nil && field(line, "pid") == "\(getpid())" && field(line, "load")?.split(separator: "/").count == 3
            && field(line, "sessions") == "2" && line.hasPrefix("20") && line.contains("T") && field(line, "launch") != nil)
    check("dumplog: the slowest session and its file's size, the bytes the background scan read",
        field(line, "slowTail") != nil && field(line, "slowTailSize") != nil && field(line, "slowTailMs") != nil
            && field(line, "bgBytes") == "\(transcriptSize)" && field(line, "slowBG") == "d1" && field(line, "slowBGBytes") == "\(transcriptSize)")
    check("dumplog: the slowest session's size is its transcript's (d1) or 0 (d2, which has none)",
        (field(line, "slowTail") == "d1" && field(line, "slowTailSize") == "\(transcriptSize)") || (field(line, "slowTail") == "d2" && field(line, "slowTailSize") == "0"))
    let parts = line.components(separatedBy: " | ")
    let sum = (parts.last ?? "").split(separator: " ").compactMap { number($0.split(separator: "=").last.map(String.init)) }.reduce(0, +)
    let total = number(field(line, "total")) ?? -1
    check("dumplog: the stages add up to the total (\(sum) of \(total) ms)", abs(sum - total) < max(2, total * 0.02))
    check("dumplog: the gone mark was written on the first run, so goneWrite took time; bgScan read the transcript", (number(field(line, "goneWrite")) ?? 0) > 0 && (number(field(line, "bgScan")) ?? 0) > 0)

    // ── 2. The output is the same bytes with the log on and off, and a second run adds a line.
    let b = run(slow, ["SOULGENT_DUMP_SLOW_MS": "0"])
    check("dumplog: a second run — a second line", lines(slow).count == 2)
    let plain = process()
    let rows = dumpRows(plain, now: now)
    let reference = String(decoding: try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    check("dumplog: --dump's output is byte for byte the one without the log (logging, not logging)", a == reference && b == reference && !a.isEmpty)
    check("dumplog: the probe is gone after a run, and a stage outside a run is just its body", dumpProbe == nil && dumpStage("x") { 7 } == 7)

    // ── 3. A normal run under the default threshold writes nothing, and nor does a bad threshold.
    let quiet = dir + "/log-quiet"
    _ = run(quiet)
    check("dumplog: default threshold — a normal run writes nothing (no file made)", !files.fileExists(atPath: quiet + "/dump-slow.log"))
    for bad in ["abc", "-5", ""] {
        _ = run(quiet, ["SOULGENT_DUMP_SLOW_MS": bad])
    }
    check("dumplog: a threshold that is not a number of milliseconds is the default", !files.fileExists(atPath: quiet + "/dump-slow.log"))
    _ = run(quiet, ["SOULGENT_DUMP_SLOW_MS": "100000"])
    check("dumplog: a high threshold — nothing", !files.fileExists(atPath: quiet + "/dump-slow.log"))
    dumpStageHook = { name in if name == "serialize" { Thread.sleep(forTimeInterval: 0.25) } }
    _ = run(quiet, ["SOULGENT_DUMP_SLOW_MS": "200"])
    dumpStageHook = nil
    let held = lines(quiet)
    check("dumplog: a run held up past the threshold writes its line, with the time in the stage held (serialize)",
        held.count == 1 && (number(field(held.first ?? "", "serialize")) ?? 0) >= 240 && (number(field(held.first ?? "", "total")) ?? 0) >= 240)

    // ── 4. Past 1 MB only the later half stays, from a line's start.
    let big = dir + "/log-big"
    try? files.createDirectory(atPath: big, withIntermediateDirectories: true)
    var filler = ""
    for i in 0..<12_000 { filler += String(format: "old line %06d ", i) + String(repeating: "x", count: 82) + "\n" }
    try? filler.write(toFile: big + "/dump-slow.log", atomically: true, encoding: .utf8)
    let before = (try? files.attributesOfItem(atPath: big + "/dump-slow.log")[.size] as? NSNumber)??.intValue ?? 0
    _ = run(big, ["SOULGENT_DUMP_SLOW_MS": "0"])
    let after = (try? files.attributesOfItem(atPath: big + "/dump-slow.log")[.size] as? NSNumber)??.intValue ?? 0
    let kept = lines(big)
    check("dumplog: a log of \(before) bytes is cut to its later half (\(after) bytes now), the new line last",
        before > 1 << 20 && after < before * 6 / 10 && after > before * 4 / 10 && kept.last?.contains("total=") == true)
    check("dumplog: the cut falls on a line's start; the newest old lines stay, the oldest are gone",
        kept.first?.hasPrefix("old line ") == true && kept.first?.count == 98 && kept.contains { $0.hasPrefix("old line 011999") } && !kept.contains { $0.hasPrefix("old line 000000") })
    _ = run(big, ["SOULGENT_DUMP_SLOW_MS": "0"])
    check("dumplog: under 1 MB nothing more is cut", lines(big).count == kept.count + 1)

    // ── 5. The stall line: a run held in a stage past the stall time says where it stands, even if it never ends in time.
    let stall = dir + "/log-stall"
    dumpStageHook = { name in if name == "goneRead" { Thread.sleep(forTimeInterval: 0.7) } }
    _ = run(stall, ["SOULGENT_DUMP_SLOW_MS": "100000", "SOULGENT_DUMP_STALL_MS": "250"])
    dumpStageHook = nil
    let stalled = lines(stall)
    let s = stalled.first ?? ""
    check("dumplog: held in goneRead past the stall time — one STALL line (and no total line under a high threshold)", stalled.count == 1 && s.contains(" STALL "))
    check("dumplog: the STALL line names the stage and its time, and the progress so far",
        field(s, "in") == "goneRead" && (number(field(s, "inStage")) ?? 0) >= 100 && (number(field(s, "after")) ?? 0) >= 240
            && field(s, "pid") == "\(getpid())" && s.contains("progress:") && field(s, "registry") != nil && field(s, "tailInfo") != nil && field(s, "goneRead") != nil)
    check("dumplog: a STALL line from a run of a session's own stage says whose (subject)", { () -> Bool in
        let again = dir + "/log-stall2"
        dumpStageHook = { name in if name == "tailInfo" { Thread.sleep(forTimeInterval: 0.5) } }
        _ = run(again, ["SOULGENT_DUMP_SLOW_MS": "100000", "SOULGENT_DUMP_STALL_MS": "200"])
        dumpStageHook = nil
        let l = lines(again).first ?? ""
        return field(l, "in") == "tailInfo" && (field(l, "subject") == "d1" || field(l, "subject") == "d2")
    }())
    let quick = dir + "/log-quick"
    _ = run(quick, ["SOULGENT_DUMP_SLOW_MS": "100000", "SOULGENT_DUMP_STALL_MS": "200"])
    Thread.sleep(forTimeInterval: 0.5)
    check("dumplog: a run that ends before the stall time cancels it — no line later", !files.fileExists(atPath: quick + "/dump-slow.log"))
    // The log's folder is made when missing, and one that cannot be written to does not stop the output.
    var unwritable = ""
    runDump(process(), now: now, environment: ["SOULGENT_DUMP_SLOW_MS": "0"], logFolder: "/dev/null/nope") { unwritable = $0 }
    check("dumplog: a log that cannot be written leaves the output as it was", unwritable == reference)
}
