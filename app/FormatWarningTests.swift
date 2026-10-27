// The checks of the format warnings (`FormatWarning`), run alone with `--format-only`. Every reader of another program's files
// is given the made-up samples in Adapters/samples/<source>/ (paths under /Users/demo, names and words invented; nothing of a
// real session): for each source one of the format as read today, which gives no warning, and one changed the way a new
// version might change it, which gives its reason. The samples are copied into a scratch folder and given what only the run
// knows (a live pid, the scratch paths, recent times); the machine's own sessions, apps and Orca are not touched.

import AppKit
import SQLite3
import SwiftUI

@MainActor func formatWarningTests() {
    let fm = FileManager.default
    let samples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Adapters/samples").path
    let dir = NSTemporaryDirectory() + "format-tests-\(getpid())"
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: dir) }
    let savedLive = appSessionsLive
    appSessionsLive = false
    defer { appSessionsLive = savedLive }
    var orcaSaid: [String] = []
    let keptOrcaNote = OrcaFormat.shared.note
    OrcaFormat.shared.reset()
    OrcaFormat.shared.note = { orcaSaid.append($0) }
    defer {
        OrcaFormat.shared.reset()
        OrcaFormat.shared.note = keptOrcaNote
    }

    func sample(_ name: String) -> Data { fm.contents(atPath: samples + "/" + name) ?? Data() }
    func text(_ name: String) -> String { String(decoding: sample(name), as: UTF8.self) }
    func folder(_ tag: String) -> String {
        let path = dir + "/" + tag
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
    func write(_ data: Data, _ path: String) {
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path))
    }
    let now = Date()
    let ms = now.timeIntervalSince1970 * 1000
    let sampleNames = [
        "claude/registry-current.json", "claude/registry-broken.json", "claude/transcript-current.jsonl", "claude/transcript-broken.jsonl",
        "codex/rollout-current.jsonl", "codex/rollout-broken.jsonl", "codex/state-current.sql", "codex/state-broken.sql",
        "codex/turns-current.sql", "codex/turns-broken.sql", "workbuddy/database-current.sql", "workbuddy/database-broken.sql",
        "workbuddy/log-current.log", "workbuddy/log-broken.log", "orca/runtime-current.json", "orca/runtime-broken.json",
        "orca/terminals-current.json", "orca/terminals-broken.json",
    ]
    let allText = sampleNames.map(text).joined(separator: "\n")
    check("format: every sample is there, made up (paths under /Users/demo only, no one's home)",
        sampleNames.allSatisfy { !sample($0).isEmpty } && !allText.contains(home)
            && allText.components(separatedBy: "/Users/").dropFirst().allSatisfy { $0.hasPrefix("demo/") })

    // ── 1. Claude Code: the registry and the transcript ──
    let claudeID = "00000000-demo-0000-0000-format000001"
    func noCodex() -> CodexSessions {
        let none = CodexSessions()
        none.processes = { [] }
        return none
    }
    func noApp() -> CodexAppSessions {
        let none = CodexAppSessions(home: dir + "/no-codex")
        none.running = { nil }
        return none
    }
    func noWorkBuddy() -> WorkBuddySessions {
        let none = WorkBuddySessions(home: dir + "/no-workbuddy")
        none.running = { nil }
        return none
    }
    /// A registry file from a sample, with this process's pid (a live one) and a recent status.
    func registryFile(_ name: String) -> Data {
        guard var o = (try? JSONSerialization.jsonObject(with: sample(name))) as? [String: Any] else { return Data() }
        if o["pid"] != nil { o["pid"] = Int(getpid()) }
        if o["processId"] != nil { o["processId"] = Int(getpid()) }
        if o["statusUpdatedAt"] != nil { o["statusUpdatedAt"] = ms }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
    func claudeLoader(
        _ tag: String, registry: [String], transcript: Data?, codex: CodexSessions? = nil, app: CodexAppSessions? = nil,
        workbuddy: WorkBuddySessions? = nil, extra: [String: Data] = [:]
    ) -> Loader {
        let base = folder(tag)
        try? fm.createDirectory(atPath: base + "/sessions", withIntermediateDirectories: true)
        for (i, name) in registry.enumerated() { write(registryFile(name), base + "/sessions/\(i + 1).json") }
        for (file, data) in extra { write(data, base + "/sessions/" + file) }
        let l = Loader(
            registry: base + "/sessions", codex: codex ?? noCodex(), codexApp: app ?? noApp(), workbuddy: workbuddy ?? noWorkBuddy(),
            restarting: base + "/none.json", bgCache: "", goneCache: "")
        l.formatNote = { _ in }
        if let transcript { write(transcript, base + "/\(claudeID).jsonl") }
        l.remember(transcript: base + "/\(claudeID).jsonl", for: claudeID)
        return l
    }
    func warningsJSON(_ row: [String: Any]?) -> [[String: String]]? { row?["formatWarnings"] as? [[String: String]] }

    let good = claudeLoader("claude-good", registry: ["claude/registry-current.json"], transcript: sample("claude/transcript-current.jsonl"))
    let goodRows = dumpRows(good, now: now)
    check("format claude: the current registry and transcript — the session is listed, named from its transcript, and no warning at all",
        goodRows.count == 1 && goodRows.first?["id"] as? String == claudeID && goodRows.first?["name"] as? String == "demo-garden"
            && warningsJSON(goodRows.first) == [] && good.formatWarnings.isEmpty)

    let badRegistry = claudeLoader(
        "claude-registry", registry: ["claude/registry-current.json", "claude/registry-broken.json"], transcript: sample("claude/transcript-current.jsonl"))
    let badRegistryRows = dumpRows(badRegistry, now: now)
    check("format claude: a registry file that reads but has no pid and sessionId — claude/registry, on the rows of Claude Code (it names no session of its own)",
        badRegistryRows.count == 1 && warningsJSON(badRegistryRows.first) == [["source": "claude", "reason": "registry"]]
            && badRegistry.formatWarnings == [.claudeRegistry])
    let noCwd: Data = {
        var o = (try? JSONSerialization.jsonObject(with: registryFile("claude/registry-current.json"))) as? [String: Any] ?? [:]
        o["cwd"] = nil
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }()
    let cwdGone = claudeLoader("claude-cwd", registry: [], transcript: sample("claude/transcript-current.jsonl"), extra: ["1.json": noCwd])
    let cwdGoneList = cwdGone.load(now: now)
    check("format claude: a registry file without its cwd — still listed, and claude/registry",
        cwdGoneList.map(\.id) == [claudeID] && cwdGone.formatWarnings == [.claudeRegistry])
    let halfWritten = claudeLoader(
        "claude-half", registry: ["claude/registry-current.json"], transcript: sample("claude/transcript-current.jsonl"),
        extra: ["2.json": Data(text("claude/registry-current.json").prefix(40).utf8), "3.json": Data()])
    _ = halfWritten.load(now: now)
    check("format claude: a registry file half written or empty, beside a whole one — no warning (not JSON yet says nothing)",
        halfWritten.formatWarnings.isEmpty)

    let badTranscript = claudeLoader("claude-transcript", registry: ["claude/registry-current.json"], transcript: sample("claude/transcript-broken.jsonl"))
    var transcriptSaid: [String] = []
    badTranscript.formatNote = { transcriptSaid.append($0) }
    var dumped = ""
    runDump(badTranscript, now: now, environment: [:], logFolder: folder("dump-log")) { dumped = $0 }
    let badTranscriptRows = (try? JSONSerialization.jsonObject(with: Data(dumped.utf8))) as? [[String: Any]] ?? []
    check("format claude: a transcript whose lines are all of kinds unknown — claude/transcript, on that session's row",
        warningsJSON(badTranscriptRows.first) == [["source": "claude", "reason": "transcript"]] && badTranscript.formatWarnings == [.claudeTranscript]
            && badTranscript.formatMarks[.claudeTranscript] == [claudeID])
    check("format claude: --dump runs say nothing to the log (a process every 3 s would say it every time)", transcriptSaid.isEmpty)
    for _ in 0..<3 { _ = badTranscript.load(now: now) }
    check("format claude: in the panel it is told once when it appears, not once a look",
        transcriptSaid.count == 1 && transcriptSaid[0].contains("claude transcript"))
    write(sample("claude/transcript-current.jsonl"), dir + "/claude-transcript/\(claudeID).jsonl")
    _ = badTranscript.load(now: now)
    check("format claude: the transcript understood again — the warning goes, and that is told once",
        badTranscript.formatWarnings.isEmpty && transcriptSaid.count == 2 && transcriptSaid[1].contains("understood again"))

    let brokenLines = text("claude/transcript-broken.jsonl").split(separator: "\n").map(String.init)
    let fewLines = claudeLoader("claude-few", registry: ["claude/registry-current.json"], transcript: Data((brokenLines.prefix(4).joined(separator: "\n") + "\n").utf8))
    _ = fewLines.load(now: now)
    let writing = claudeLoader(
        "claude-writing", registry: ["claude/registry-current.json"], transcript: Data((brokenLines.prefix(4).joined(separator: "\n") + "\n" + brokenLines[4]).utf8))
    _ = writing.load(now: now)
    let mixed = claudeLoader(
        "claude-mixed", registry: ["claude/registry-current.json"],
        transcript: Data((brokenLines.joined(separator: "\n") + "\n" + text("claude/transcript-current.jsonl")).utf8))
    _ = mixed.load(now: now)
    let empty = claudeLoader("claude-empty", registry: ["claude/registry-current.json"], transcript: Data())
    _ = empty.load(now: now)
    let missing = claudeLoader("claude-missing", registry: ["claude/registry-current.json"], transcript: nil)
    _ = missing.load(now: now)
    check("format claude: no warning for four unknown lines (too few), four and a fifth still being written, unknown lines with known ones after, an empty transcript, none at all",
        [fewLines, writing, mixed, empty, missing].allSatisfy { $0.formatWarnings.isEmpty })
    // The first line of a tail read from inside the file is cut: it is not counted (here the one known line is that cut one).
    let cutTail = String(repeating: "x", count: Int(tailBytes)) + #"{"type":"user","message":{"role":"user","content":"hi"}}"# + "\n"
        + brokenLines.joined(separator: "\n") + "\n"
    let cut = claudeLoader("claude-cut", registry: ["claude/registry-current.json"], transcript: Data(cutTail.utf8))
    _ = cut.load(now: now)
    check("format claude: a known line cut by where the tail begins does not count — six unknown whole lines after it are claude/transcript",
        cut.formatWarnings == [.claudeTranscript])

    // ── 2. Codex CLI: the rollout and the thread index ──
    let cliID = "00000000-demo-0000-0000-codex0000001", appID = "00000000-demo-0000-0000-codex0000002"
    func codexHome(_ tag: String, state: String, turns: String = "codex/turns-current.sql", rollout: String) -> String {
        let h = folder(tag)
        _ = fixtureSQL(h + "/state_5.sqlite", text(state))
        _ = fixtureSQL(h + "/thread_history_1.sqlite", text(turns))
        write(sample(rollout), h + "/rollout-cli.jsonl")
        write(sample(rollout), h + "/rollout-app.jsonl")
        _ = fixtureSQL(h + "/state_5.sqlite", "UPDATE threads SET rollout_path = '\(h)/rollout-cli.jsonl' WHERE id = '\(cliID)'")
        _ = fixtureSQL(
            h + "/state_5.sqlite",
            "UPDATE threads SET rollout_path = '\(h)/rollout-app.jsonl', recency_at_ms = \(Int64(ms) - 60_000), updated_at_ms = \(Int64(ms) - 60_000) WHERE id = '\(appID)'")
        return h
    }
    func cli(_ h: String) -> CodexSessions {
        let reader = CodexSessions()
        reader.processes = { [CodexProcess(pid: getpid(), start: 0, home: h)] }
        reader.rollout = { _ in h + "/rollout-cli.jsonl" }
        return reader
    }
    let cliGood = cli(codexHome("codex-good", state: "codex/state-current.sql", rollout: "codex/rollout-current.jsonl"))
    let cliGoodList = cliGood.load(now: now)
    check("format codex: the current index and rollout — the thread listed with its name and last words, no warning",
        cliGoodList.map(\.id) == [cliID] && cliGoodList.first?.name == "demo apples" && cliGoodList.first?.summary == "There are twelve demo apples."
            && cliGood.formatMarks.isEmpty)
    let cliRollout = cli(codexHome("codex-rollout", state: "codex/state-current.sql", rollout: "codex/rollout-broken.jsonl"))
    _ = cliRollout.load(now: now)
    check("format codex: a rollout whose lines are all of kinds unknown — codex/rollout, for that thread",
        cliRollout.formatMarks == [.codexRollout: [cliID]])
    let cliIndex = cli(codexHome("codex-index", state: "codex/state-broken.sql", rollout: "codex/rollout-current.jsonl"))
    let cliIndexList = cliIndex.load(now: now)
    check("format codex: an index without a column it is read by — codex/threads, for all of Codex's (no thread found to name)",
        cliIndexList.isEmpty && cliIndex.formatMarks == [.codexThreads: [""]])
    let noIndex = CodexSessions()
    noIndex.processes = { [CodexProcess(pid: getpid(), start: 0, home: folder("codex-none"))] }
    noIndex.rollout = { _ in nil }
    _ = noIndex.load(now: now)
    check("format codex: no index at all (Codex never ran there) — no warning", noIndex.formatMarks.isEmpty)
    let goodTail = CodexTail.read(dir + "/codex-good/rollout-cli.jsonl", after: nil, now: now)
    let badTail = CodexTail.read(dir + "/codex-rollout/rollout-cli.jsonl", after: nil, now: now)
    check("format codex: the rollout read alone — the current one understood, the changed one not", !goodTail.unknownLines && badTail.unknownLines)

    // ── 3. The Codex app: its index, its turn table, its rollouts ──
    func app(_ h: String) -> CodexAppSessions {
        let reader = CodexAppSessions(home: h)
        reader.running = { 4242 }
        reader.readsFirstInline = true
        return reader
    }
    let appGood = app(dir + "/codex-good")
    let appGoodList = appGood.load(now: now)
    check("format codex app: the current index, turn table and rollout — its thread listed, no warning",
        appGoodList.map(\.id) == [appID] && appGoodList.first?.kind == "codexApp" && appGood.formatMarks.isEmpty)
    let appRollout = app(dir + "/codex-rollout")
    _ = appRollout.load(now: now)
    let appIndex = app(dir + "/codex-index")
    _ = appIndex.load(now: now)
    let appTurns = app(codexHome("codex-turns", state: "codex/state-current.sql", turns: "codex/turns-broken.sql", rollout: "codex/rollout-current.jsonl"))
    _ = appTurns.load(now: now)
    check("format codex app: a changed rollout — codex/rollout for its thread; a changed index — codex/threads; a changed turn table — codex/turns",
        appRollout.formatMarks == [.codexRollout: [appID]] && appIndex.formatMarks == [.codexThreads: [""]] && appTurns.formatMarks == [.codexTurns: [""]])
    appIndex.running = { nil }
    _ = appIndex.load(now: now)
    check("format codex app: the app quits — what it had goes with it", appIndex.formatMarks.isEmpty)

    // ── 4. WorkBuddy: its database and its log ──
    let wbID = "00000000-demo-0000-0000-workbuddy001"
    let wbNow = Date(timeIntervalSince1970: 1_790_000_000 + 60)
    func workbuddyHome(_ tag: String, database: String, log: String) -> WorkBuddySessions {
        let h = folder(tag)
        _ = fixtureSQL(h + "/workbuddy.db", text(database))
        write(sample(log), h + "/logs/2026-10-20/sdk/conversations/\(wbID).log")
        let reader = WorkBuddySessions(home: h)
        reader.running = { 4343 }
        return reader
    }
    let wbGood = workbuddyHome("wb-good", database: "workbuddy/database-current.sql", log: "workbuddy/log-current.log")
    let wbGoodList = wbGood.load(now: wbNow)
    check("format workbuddy: the current database and log — the session waiting for its answer (three options), no warning",
        wbGoodList.map(\.id) == [wbID] && wbGoodList.first?.status == "waiting" && wbGoodList.first?.summaryLine == .answer(options: 3)
            && wbGood.formatMarks.isEmpty)
    let wbLog = workbuddyHome("wb-log", database: "workbuddy/database-current.sql", log: "workbuddy/log-broken.log")
    let wbLogList = wbLog.load(now: wbNow)
    check("format workbuddy: a log whose lines are of another shape — workbuddy/log, for that session (still listed, taken as a permission wait)",
        wbLogList.map(\.id) == [wbID] && wbLog.formatMarks == [.workbuddyLog: [wbID]])
    let wbDatabase = workbuddyHome("wb-db", database: "workbuddy/database-broken.sql", log: "workbuddy/log-current.log")
    let wbDatabaseList = wbDatabase.load(now: wbNow)
    check("format workbuddy: a database without the columns it is read by — workbuddy/database, for all of WorkBuddy's",
        wbDatabaseList.isEmpty && wbDatabase.formatMarks == [.workbuddyDatabase: [""]])
    let wbShort = folder("wb-short") + "/short.log"
    write(Data((text("workbuddy/log-broken.log").split(separator: "\n").prefix(3).joined(separator: "\n") + "\n").utf8), wbShort)
    check("format workbuddy: the log read alone — the current one understood, the changed one not, three lines too few to say",
        WorkBuddySessions.read(log: dir + "/wb-good/logs/2026-10-20/sdk/conversations/\(wbID).log").odd == false
            && WorkBuddySessions.read(log: dir + "/wb-log/logs/2026-10-20/sdk/conversations/\(wbID).log").odd == true
            && WorkBuddySessions.read(log: wbShort).odd == nil && WorkBuddySessions.read(log: dir + "/nowhere.log").odd == nil)

    // ── 5. Orca: its runtime file and its terminal list ──
    let runtime = orcaRuntime(sample("orca/runtime-current.json"))
    check("format orca: the current runtime file — its token and socket, no warning",
        runtime?.token == "demo-token-not-a-secret" && runtime?.endpoint.hasSuffix("demo.sock") == true && OrcaFormat.shared.warnings.isEmpty)
    for _ in 0..<3 { _ = orcaRuntime(sample("orca/runtime-broken.json")) }
    check("format orca: a runtime file without them — nothing to call, orca/runtime, told once however often it is read",
        orcaRuntime(sample("orca/runtime-broken.json")) == nil && OrcaFormat.shared.warnings == [.orcaRuntime] && orcaSaid.count == 1)
    _ = orcaRuntime(Data(text("orca/runtime-current.json").prefix(30).utf8))
    let keptOnHalf = OrcaFormat.shared.warnings
    _ = orcaRuntime(nil)
    check("format orca: a runtime file half written changes nothing; no file (Orca not there) clears it, told once",
        keptOnHalf == [.orcaRuntime] && OrcaFormat.shared.warnings.isEmpty && orcaSaid.count == 2)
    func reply(_ name: String) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: sample(name))) as? [String: Any] }
    check("format orca: terminal.list — the current answer understood, a list as a result too, the changed one not; no answer or an error says nothing",
        orcaTerminalsUnderstood(reply("orca/terminals-current.json")) == true
            && orcaTerminalsUnderstood(["result": [["handle": "term_demo_1"]]]) == true
            && orcaTerminalsUnderstood(["result": ["visualLayouts": [Any]()]]) == true
            && orcaTerminalsUnderstood(reply("orca/terminals-broken.json")) == false
            && orcaTerminalsUnderstood(["result": ["terminals": [["ref": "term_demo_1"]]]]) == false
            && orcaTerminalsUnderstood(nil) == nil && orcaTerminalsUnderstood(["ok": false, "error": ["message": "busy"]]) == nil)
    _ = orcaTerminalList(reply("orca/terminals-current.json"))
    let afterGoodList = OrcaFormat.shared.warnings
    _ = orcaTerminalList(reply("orca/terminals-broken.json"))
    check("format orca: the list's answer noted where it is read — the current one leaves nothing, the changed one orca/terminals",
        afterGoodList.isEmpty && OrcaFormat.shared.warnings == [.orcaTerminals])

    // ── 6. --dump: formatWarnings on every row, each row its own source's, Orca's on all ──
    OrcaFormat.shared.reset()
    let wholeGood = claudeLoader(
        "dump-good", registry: ["claude/registry-current.json"], transcript: sample("claude/transcript-current.jsonl"),
        codex: cli(dir + "/codex-good"), app: app(dir + "/codex-good"),
        workbuddy: workbuddyHome("dump-wb-good", database: "workbuddy/database-current.sql", log: "workbuddy/log-current.log"))
    let dumpNow = now
    let goodDump = dumpRows(wholeGood, now: dumpNow)
    check("format dump: a row of each source (claude, codex, codexApp, workbuddy)",
        Set(goodDump.compactMap { $0["kind"] as? String }) == ["claude", "codex", "codexApp", "workbuddy"] && goodDump.count == 4)
    check("format dump: ...every row has the key, and it is [] on each",
        !goodDump.isEmpty && goodDump.allSatisfy { warningsJSON($0) == [] })
    let again = wholeGood.load(now: dumpNow)
    let sameOld = goodDump.allSatisfy { row in
        guard let s = again.first(where: { $0.id == row["id"] as? String }) else { return false }
        var old = row
        old["formatWarnings"] = nil
        let before = dumpRow(s, model: wholeGood.model(of: s.id) ?? "")
        return (try? JSONSerialization.data(withJSONObject: old, options: [.sortedKeys])) == (try? JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]))
    }
    check("format dump: ...and besides that key each row is byte for byte the row it was (dumpRow)", sameOld)

    let wholeBad = claudeLoader(
        "dump-bad", registry: ["claude/registry-current.json"], transcript: sample("claude/transcript-broken.jsonl"),
        codex: cli(dir + "/codex-rollout"), app: app(dir + "/codex-good"),
        workbuddy: workbuddyHome("dump-wb-bad", database: "workbuddy/database-current.sql", log: "workbuddy/log-broken.log"))
    _ = orcaTerminalList(reply("orca/terminals-broken.json"))
    let badDump = dumpRows(wholeBad, now: dumpNow)
    func row(_ id: String) -> [[String: String]]? { warningsJSON(badDump.first { $0["id"] as? String == id }) }
    let terminals = ["source": "orca", "reason": "terminals"]
    check("format dump: each row its own source's warnings and Orca's, sorted by source and reason: claude transcript, codex rollout, workbuddy log, none for the app's thread",
        row(claudeID) == [["source": "claude", "reason": "transcript"], terminals]
            && row(cliID) == [["source": "codex", "reason": "rollout"], terminals]
            && row(wbID) == [terminals, ["source": "workbuddy", "reason": "log"]]
            && row(appID) == [terminals])
    check("format dump: the JSON of a row's warnings, as the phone reads it",
        String(decoding: (try? JSONSerialization.data(withJSONObject: row(cliID) ?? [], options: [.sortedKeys])) ?? Data(), as: UTF8.self)
            == #"[{"reason":"rollout","source":"codex"},{"reason":"terminals","source":"orca"}]"#)
    OrcaFormat.shared.reset()
    let merged = mergeFormatMarks([[.codexRollout: [cliID]], [.codexRollout: ["", appID]], [.codexThreads: []]])
    var codexRow = Session(id: cliID, pid: 1, project: "p", name: "n", status: "idle", since: now, summary: "")
    codexRow.kind = "codex"
    var claudeRow = codexRow
    claudeRow.kind = "claude"
    check("format dump: one warning from two readers is given once; one with no session is no warning; another source's is not on the row",
        rowFormatWarnings(merged, for: codexRow) == [.codexRollout] && merged[.codexThreads] == nil && rowFormatWarnings(merged, for: claudeRow).isEmpty)

    // ── 7. The title bar: the words in three languages, the dot only with a warning ──
    func inLanguage<T>(_ lang: String, _ body: () -> T) -> T {
        L10n.reset()
        L10n.pin(lang)
        defer {
            L10n.reset()
            L10n.pin(L10n.source)
        }
        return body()
    }
    let one: [FormatWarning] = [.claudeTranscript]
    let words = ["zh-Hans", "en", "zh-Hant"].map { lang in inLanguage(lang) { formatWarningWords(one) } }
    check("format bar: the words in simplified Chinese, English and traditional Chinese, Claude Code's",
        words == ["Claude Code 会话格式变了，部分信息可能缺失", "Claude Code's session format has changed; some details may be missing",
            "Claude Code 會話格式變了，部分資訊可能缺失"])
    let several: [FormatWarning] = [.workbuddyLog, .orcaTerminals, .codexThreads, .codexRollout, .orcaRuntime]
    let lines = ["zh-Hans", "en", "zh-Hant"].map { lang in inLanguage(lang) { formatWarningWords(several).components(separatedBy: "\n") } }
    check("format bar: several sources — one line each, the name put in (Codex, Orca, WorkBuddy), none empty, in every language",
        lines[0] == ["Codex 会话格式变了，部分信息可能缺失", "Orca 会话格式变了，部分信息可能缺失", "WorkBuddy 会话格式变了，部分信息可能缺失"]
            && lines[1] == ["Codex's session format has changed; some details may be missing", "Orca's session format has changed; some details may be missing",
                "WorkBuddy's session format has changed; some details may be missing"]
            && lines[2] == ["Codex 會話格式變了，部分資訊可能缺失", "Orca 會話格式變了，部分資訊可能缺失", "WorkBuddy 會話格式變了，部分資訊可能缺失"]
            && lines.allSatisfy { $0.allSatisfy { !$0.isEmpty } })

    func drawn<V: View>(_ view: V) -> (size: CGSize, pixels: Pixels?) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        let size = host.fittingSize
        let window = NSWindow(contentRect: CGRect(x: -8000, y: -8000, width: size.width, height: size.height), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        defer { window.close() }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return (size, nil) }
        host.cacheDisplay(in: host.bounds, to: rep)
        return (size, rep.cgImage.map(Pixels.init))
    }
    func amber(_ p: Pixels?) -> Bool {
        guard let p else { return false }
        for i in stride(from: 0, to: p.data.count, by: 4) where p.data[i + 3] == 255 {
            let r = UInt32(p.data[i]), g = UInt32(p.data[i + 1]), b = UInt32(p.data[i + 2])
            let colour: UInt32 = (r << 16) | (g << 8) | b
            if same(colour, failAmberHex) { return true }
        }
        return false
    }
    let store = Store()
    store.formatWarnings = []
    let plain = drawn(CountsBar(store: store)), before = drawn(FormatCountsBarBefore(store: store))
    check("format bar: no warning — the counts bar is drawn pixel for pixel as it was before the dot, no amber in it",
        plain.size == before.size && plain.pixels != nil && plain.pixels?.data == before.pixels?.data && !amber(plain.pixels))
    store.formatWarnings = one
    let dotted = drawn(CountsBar(store: store))
    check("format bar: a warning — the bar a little wider, with the amber dot (0xF0B429) in it",
        dotted.size.width > plain.size.width && dotted.size.height == plain.size.height && amber(dotted.pixels))
    store.formatWarnings = []
}

/// The counts bar as it was before the format dot, to hold the one with no warning to.
private struct FormatCountsBarBefore: View {
    @ObservedObject var store: Store
    @AppStorage("zoom") private var zoom = 1.0

    var body: some View {
        let b = Buckets(store, now: Date())
        let z = CGFloat(zoom)
        HStack(spacing: 14 * z) {
            count(b.waiting.count, L10n.string("count.waiting", table: "Board", zh: "在等你"), call, z)
            if showFailed() { count(b.failed.count, failedWords(), FailTone.red.color, z) }
            count(b.unread.count, L10n.string("count.news", table: "Board", zh: "有话说"), paper, z)
            count(b.busy.count, L10n.string("count.working", table: "Board", zh: "在干活"), work, z)
        }
        .padding(.leading, 6).fixedSize().frame(height: 28)
    }

    private func count(_ n: Int, _ label: String, _ color: Color, _ z: CGFloat) -> some View {
        HStack(spacing: 4 * z) {
            Circle().fill(n > 0 ? color : quiet.opacity(0.5)).frame(width: 7 * z, height: 7 * z)
            Text("\(n)").font(rounded(12.5 * z)).foregroundStyle(n > 0 ? color : quiet)
            if !store.narrow { Text(label).font(rounded(11.5 * z, .medium)).foregroundStyle(quiet) }
        }
    }
}
