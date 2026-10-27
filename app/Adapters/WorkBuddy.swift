import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

/// WorkBuddy's sessions (`~/.workbuddy/workbuddy.db`, table `sessions`): the local ones not deleted and not run by an
/// automation, newest 30. Their state is in the row (WorkBuddy writes it at every change); what a pending one waits for
/// is in its conversation log; the line of progress is its record's last reply. One card per session; their pid is the
/// app's. WorkBuddy reaps a session's process about a minute after it finishes, and its daemon reports running ones as
/// terminated: neither is a sign of anything here.
final class WorkBuddySessions {
    static let bundle = "com.tencent.workbuddy.mac"
    let home: String
    var running: () -> Int32? = { runningApp(WorkBuddySessions.bundle) }
    var recent: TimeInterval = 86_400
    private(set) var touched = 0

    /// What a pending session waits for: an answer to the question tool's card (with how many options), or permission.
    enum Wait: Equatable {
        case question(options: Int?)
        case permission
    }

    private struct Row {
        let id: String, name: String, cwd: String, status: String, mode: String, model: String?, updated: Double, active: Double
        var untitled = false  // `name` is the default untitled name
    }
    /// A record's end as last read: where its whole lines end, its last reply and the model that wrote it.
    private struct Record {
        var stamp: FileStamp?
        var offset: UInt64 = 0
        var parsedAt = Date.distantPast
        var replyLine = SummaryLine.empty  // as a code and its arguments
        var reply: String { replyLine.rendered }
        var model: String?
    }
    private var stamps: [FileStamp?]?
    private var rows: [Row] = []
    private var records: [String: Record] = [:]  // by session id
    private var waits: [String: (stamp: FileStamp?, wait: Wait?, odd: Bool)] = [:]  // by session id, for pending ones
    private var paths: [String: (record: String?, log: String?, at: Date)] = [:]  // where each one's files were found
    private var models: [String: String] = [:]
    /// The database was last found without a table or column it is read by; what of the formats was not understood at the last
    /// look (`FormatWarning`).
    private var schemaGone = false
    private(set) var formatMarks: FormatMarks = [:]

    init(home: String = panelHome + "/.workbuddy") { self.home = home }

    func model(of id: String) -> String? { models[id] }

    /// How a session's row reads on the board: its status as WorkBuddy wrote it, what a pending one waits for, and the
    /// permission mode it runs in. In bypass mode a permission request answers itself within seconds, so only a question
    /// is waiting then. `summary` is what the card says instead of the last reply.
    static func state(_ status: String, wait: Wait?, mode: String) -> (status: String, waitingFor: String, summary: String?) {
        let state = stateLine(status, wait: wait, mode: mode)
        return (state.status, state.waitingFor, state.line?.rendered)
    }

    /// `state` with its line as a code and its arguments.
    static func stateLine(_ status: String, wait: Wait?, mode: String) -> (status: String, waitingFor: String, line: SummaryLine?) {
        switch status {
        case "working", "planning":
            return ("busy", "", nil)
        case "pending", "waiting_question", "waiting_permission":
            let kind: Wait? = status == "waiting_question" ? .question(options: nil) : status == "waiting_permission" ? .permission : wait
            if case .question(let options)? = kind {
                return ("waiting", "input needed", .answer(options: options))
            }
            if mode == "bypassPermissions" { return ("busy", "", nil) }
            return ("waiting", "permission request", .approve)  // One word for it, as Claude Code's
        case "paused":
            return ("waiting", "", .paused)
        case "terminated", "cancelled":
            return ("idle", "", .stopped)
        case "error", "failed":
            return ("idle", "", .error)
        default:  // completed, and the table's default before anything ran
            return ("idle", "", nil)
        }
    }

    func load(now: Date = Date()) -> [Session] {
        guard let pid = dumpStage("runningApp", running) else {
            stamps = nil
            rows = []
            records = [:]
            waits = [:]
            paths = [:]
            models = [:]
            (schemaGone, formatMarks) = (false, [:])
            return []
        }
        let dbPath = home + "/workbuddy.db"
        let fresh = [FileStamp(dbPath), FileStamp(dbPath + "-wal")]
        touched += 2
        if fresh != stamps, let db = ReadOnlyDatabase(dbPath) {
            let found = db.rows(Self.columns, [], nil, Self.row)
            if found != nil || db.schemaMissing { schemaGone = db.schemaMissing }
            if let found {
                rows = found
                stamps = fresh
            }
        }
        var out: [Session] = [], models: [String: String] = [:], seen = Set<String>()
        for r in rows {
            let pending = ["pending", "waiting_question", "waiting_permission"].contains(r.status)
            let state = Self.stateLine(r.status, wait: pending ? wait(of: r.id, now: now) : nil, mode: r.mode)
            guard state.status != "idle" || now.timeIntervalSince1970 - r.active < recent else { continue }
            seen.insert(r.id)
            let record = progress(of: r, busy: state.status == "busy", now: now)
            if let model = record?.model ?? r.model, !model.isEmpty { models[r.id] = model }
            var s = Session(
                id: r.id, pid: pid, project: projectName(r.cwd), name: r.name, status: state.status, since: Date(timeIntervalSince1970: r.updated),
                summary: (state.line ?? record?.replyLine ?? .empty).rendered)
            s.summaryLine = state.line ?? record?.replyLine ?? .empty
            s.nameUntitled = r.untitled
            s.errorKind = state.line == .error ? "wb_error" : state.line == .stopped ? "wb_stopped" : nil  // Said in errorKind only
            s.waitingFor = state.waitingFor
            s.cwd = r.cwd
            s.kind = "workbuddy"
            out.append(s)
        }
        records = records.filter { seen.contains($0.key) }
        waits = waits.filter { seen.contains($0.key) }
        formatMarks = [:]
        let oddLogs = Set(waits.filter { $0.value.odd }.keys)
        if !oddLogs.isEmpty { formatMarks[.workbuddyLog] = oddLogs }
        if schemaGone { formatMarks[.workbuddyDatabase] = [""] }
        paths = paths.filter { seen.contains($0.key) }
        self.models = models
        return out
    }

    private static let columns = """
        SELECT id, COALESCE(NULLIF(custom_title, ''), title), cwd, status, permission_mode, model, updated_at, last_activity_at
        FROM sessions WHERE transport = 'local' AND COALESCE(deleted_at, -1) = -1 AND COALESCE(is_background_automation, 0) = 0
        ORDER BY MAX(updated_at, COALESCE(last_activity_at, 0)) DESC LIMIT 30
        """

    private static func row(_ row: OpaquePointer) -> Row? {
        guard let id = sqliteText(row, 0) else { return nil }
        let updated = Double(sqlite3_column_int64(row, 6)) / 1000
        return Row(
            id: id, name: sqliteText(row, 1).flatMap { $0.isEmpty ? nil : $0 } ?? "未命名", cwd: sqliteText(row, 2) ?? "",
            status: sqliteText(row, 3) ?? "", mode: sqliteText(row, 4) ?? "", model: sqliteText(row, 5), updated: updated,
            active: max(updated, Double(sqlite3_column_int64(row, 7)) / 1000),
            untitled: sqliteText(row, 1).flatMap { $0.isEmpty ? nil : $0 } == nil)
    }

    /// Where a session's record and conversation log are. The record is under its folder's name with the leading "/"
    /// dropped and the others made "-" (unlike Claude Code's, no leading "-"), else in whichever folder has it; the log
    /// under the newest day's folder that has one (a session can run past midnight). Looked up again once a minute.
    private func files(of r: Row, now: Date) -> (record: String?, log: String?) {
        if let known = paths[r.id], now.timeIntervalSince(known.at) < 60 { return (known.record, known.log) }
        let fm = FileManager.default
        let named = home + "/projects/" + r.cwd.drop(while: { $0 == "/" }).replacingOccurrences(of: "/", with: "-") + "/\(r.id).jsonl"
        touched += 1
        var record: String? = fm.fileExists(atPath: named) ? named : nil
        if record == nil {
            for dir in (try? fm.contentsOfDirectory(atPath: home + "/projects")) ?? [] where fm.fileExists(atPath: "\(home)/projects/\(dir)/\(r.id).jsonl") {
                record = "\(home)/projects/\(dir)/\(r.id).jsonl"
                break
            }
        }
        // The newest day's log of this session, should it run over midnight.
        let logs = home + "/logs"
        let days = ((try? fm.contentsOfDirectory(atPath: logs)) ?? []).sorted(by: >)
        let log = days.lazy.map { "\(logs)/\($0)/sdk/conversations/\(r.id).log" }.first { fm.fileExists(atPath: $0) }
        paths[r.id] = (record, log, now)
        return (record, log)
    }

    /// What a pending session waits for, read again only when its log has changed.
    private func wait(of id: String, now: Date) -> Wait? {
        guard let r = rows.first(where: { $0.id == id }), let log = files(of: r, now: now).log else { return nil }
        let stamp = FileStamp(log)
        touched += 1
        if let known = waits[id], known.stamp == stamp { return known.wait }
        let found = Self.read(log: log)
        waits[id] = (stamp, found.wait, found.odd ?? waits[id]?.odd ?? false)
        return found.wait
    }

    private static let transition = Phrase("state-machine:transition"), toPending = Phrase("\"to\":\"pending\"")
    private static let questionLines = [Phrase("ask-user-question:pending-created"), Phrase("ask-user-question:request-permission-received")]

    /// What a pending session waits for, from the end of its conversation log: its state machine's latest move to pending,
    /// and whether the question tool's own lines stand by it (WorkBuddy writes one just before the move and one just after):
    /// a question; otherwise a permission. Only these kinds of line are looked at. Nil with no such move in the last 256 KB.
    static func wait(inLog path: String) -> Wait? { read(log: path).wait }

    /// `wait(inLog:)`, and whether the log's lines are of the shape it reads (`<moment> <event> {…}`): nil with too few whole
    /// lines to say (`FormatCensus`), true when none of them is: WorkBuddy's log format changed.
    static func read(log path: String) -> (wait: Wait?, odd: Bool?) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 256_000 ? end - 256_000 : 0)
        guard let data = try? handle.readToEnd() else { return (nil, nil) }
        var lines: [(pending: Bool, question: Data?)] = []
        // The first line is cut when the read began inside the file, the last still being written without its newline.
        var census = FormatCensus()
        var held: Bool?
        let cutFirst = end > 256_000, openLast = data.last.map { $0 != 0x0A } ?? false
        forEachLine(of: data) { number, line in
            if let h = held { census.whole += 1; if h { census.known += 1 } }
            held = cutFirst && number == 0 ? nil : census.known == 0 && workbuddyLogShaped(line)
            let pending = transition.isIn(line) && toPending.isIn(line)
            lines.append((pending, questionLines.contains { $0.isIn(line) } ? Data(line) : nil))
        }
        if let h = held, !openLast { census.whole += 1; if h { census.known += 1 } }
        return (wait(among: lines), census.verdict)
    }

    private static func wait(among lines: [(pending: Bool, question: Data?)]) -> Wait? {
        guard let at = lines.lastIndex(where: \.pending) else { return nil }
        let near = lines[max(0, at - 3)...min(lines.count - 1, at + 3)].compactMap(\.question)
        guard let line = near.last else { return .permission }
        // The line's JSON follows its time and name; it says how many options the card has.
        let json = line.firstIndex(of: 0x7B).map { line[$0...] } ?? Data()
        let options = ((try? JSONSerialization.jsonObject(with: json)) as? [String: Any])?["optionCount"] as? Int
        return .question(options: options)
    }

    private static let message = Phrase("\"type\":\"message\""), assistant = Phrase("\"role\":\"assistant\"")

    /// A session's last reply and the model that wrote it, from the end of its record: read on from where the last read
    /// ended, and while it works at most every 10 s. Only the assistant's messages are decoded; tool calls, their results
    /// and file snapshots are passed over by their heads.
    private func progress(of r: Row, busy: Bool, now: Date) -> Record? {
        guard let path = files(of: r, now: now).record else { return nil }
        let stamp = FileStamp(path)
        touched += 1
        var record = records[r.id] ?? Record()
        if record.stamp == stamp || busy && now.timeIntervalSince(record.parsedAt) < 10 { return record }
        guard let stamp, let handle = FileHandle(forReadingAtPath: path) else { return record }
        defer { try? handle.close() }
        let size = UInt64(stamp.size)
        if size < record.offset { record = Record() }  // the file was replaced
        record.stamp = stamp
        record.parsedAt = now
        var found: (text: String, model: String?)?
        let floor = max(record.offset, size > CodexTail.farthest ? size - CodexTail.farthest : 0)
        record.offset = linesBackward(handle, from: size, to: floor) { line in
            let head = UnsafeRawBufferPointer(rebasing: line.prefix(400))
            guard Self.message.isIn(head), Self.assistant.isIn(head),
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], (o["role"] as? String) == "assistant",
                (o["status"] as? String) == "completed", let blocks = o["content"] as? [[String: Any]]
            else { return false }
            let text = blocks.filter { ($0["type"] as? String) == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return false }
            found = (text, (o["providerData"] as? [String: Any])?["model"] as? String)
            return true
        }
        if let found {
            record.replyLine = pickSummaryLine(recap: nil, reply: ("", found.text), asked: nil)
            record.model = found.model ?? record.model
        }
        records[r.id] = record
        return record
    }
}

/// A WorkBuddy log line of the shape read (`2026-10-09T10:07:27.481Z state-machine:transition {…}`): a date first, then after one
/// space an event's name.
func workbuddyLogShaped(_ line: UnsafeRawBufferPointer) -> Bool {
    guard line.count > 26 else { return false }
    func digit(_ i: Int) -> Bool { line[i] >= 0x30 && line[i] <= 0x39 }
    guard digit(0), digit(1), digit(2), digit(3), line[4] == 0x2D, digit(5), digit(6), line[7] == 0x2D else { return false }
    guard let space = line.prefix(40).firstIndex(of: 0x20), space + 1 < line.count else { return false }
    return line[space + 1] != 0x20 && line[space + 1] != 0x7B
}
