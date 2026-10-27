import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

/// A phrase to look for in raw transcript bytes. Transcripts run to hundreds of megabytes of
/// JSON lines; finding phrases with Swift's string search took seconds per file and froze the
/// panel while it ran. The C library's byte search does the same in milliseconds.
struct Phrase {
    fileprivate let bytes: [UInt8]
    init(_ text: String) { bytes = Array(text.utf8) }

    func isIn(_ line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        return bytes.withUnsafeBytes { memmem(base, line.count, $0.baseAddress, $0.count) != nil }
    }

    static let assistant = Phrase("\"type\":\"assistant\"")
    static let user = Phrase("\"type\":\"user\"")
    static let text = Phrase("\"type\":\"text\"")
    static let toolUse = Phrase("\"type\":\"tool_use\"")
    static let toolResult = Phrase("\"tool_result\"")
    static let recap = Phrase("\"subtype\":\"away_summary\"")
    static let customTitle = Phrase("\"type\":\"custom-title\"")
    static let aiTitle = Phrase("\"type\":\"ai-title\"")
    static let sendMessage = Phrase("\"name\":\"SendMessage\"")
    static let incoming = Phrase("cross-session-message from=")
    static let model = Phrase("\"message\":{\"model\":\"")
    static let sidechain = Phrase("\"isSidechain\":true")
    // An API error's assistant line (the false ones, "No response requested.", say `false`), the note of a retry, a compaction's end.
    static let apiError = Phrase("\"isApiErrorMessage\":true")
    static let apiRetry = Phrase("\"subtype\":\"api_error\"")
    static let compacted = Phrase("\"subtype\":\"compact_boundary\"")
    // The four things a transcript line says of a background task, tried before the line is decoded.
    static let bgLaunch = Phrase("backgroundTaskId")
    static let asyncLaunched = Phrase("async_launched")
    static let notification = Phrase("task-notification")
    static let taskType = Phrase("task_type")
    static let agentsKilled = Phrase("agents_killed")
    static let bashCall = Phrase("\"name\":\"Bash\"")  // an assistant record with a Bash call in it
    static let toolUseId = Phrase("\"tool_use_id\":\"")
    static let promptSource = Phrase("\"promptSource\"")  // a record of what the user typed, whatever its content (an image, say)
    static let userText = Phrase("\"role\":\"user\",\"content\":\"")  // a user record whose content is a string: a turn

    /// Where this phrase ends on the line, the first time it is there.
    func end(in line: UnsafeRawBufferPointer) -> Int? {
        guard let base = line.baseAddress,
            let hit = bytes.withUnsafeBytes({ memmem(base, line.count, $0.baseAddress, $0.count) })
        else { return nil }
        return base.distance(to: UnsafeRawPointer(hit)) + bytes.count
    }
}

/// The model an assistant transcript line names (`"message":{"model":"…"`), read off the bytes: most such lines are tool
/// calls, never decoded. Nil for none, an empty one or Claude Code's own `<synthetic>` notes.
func replyModel(_ line: UnsafeRawBufferPointer) -> String? {
    guard let from = Phrase.model.end(in: line), let quote = line[from...].prefix(80).firstIndex(of: 0x22), quote > from else { return nil }
    let id = String(decoding: line[from..<quote], as: UTF8.self)
    return id.hasPrefix("<") ? nil : id
}

/// Calls `body` with each non-empty line of `data` and its line number.
func forEachLine(of data: Data, _ body: (Int, UnsafeRawBufferPointer) -> Void) {
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        guard let base = raw.baseAddress else { return }
        var start = 0
        var number = 0
        while start < raw.count {
            let newline = memchr(base + start, 0x0A, raw.count - start)
            let end = newline.map { start + (base + start).distance(to: UnsafeRawPointer($0)) } ?? raw.count
            if end > start { body(number, UnsafeRawBufferPointer(rebasing: raw[start..<end])) }
            start = end + 1
            number += 1
        }
    }
}

/// The name of the last tool call on a transcript line (an assistant entry with `tool_use` blocks), read as
/// `pendingRequest` reads it; nil when the line has none.
func toolUseName(_ line: Data) -> String? {
    guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
        let use = blocks.last(where: { ($0["type"] as? String) == "tool_use" })
    else { return nil }
    return use["name"] as? String
}

/// What a waiting session wants from the user, read from its unanswered tool call.
func pendingRequest(_ line: Data) -> String? { pendingRequestLine(line)?.rendered }

/// `pendingRequest` as a code and its arguments.
func pendingRequestLine(_ line: Data) -> SummaryLine? {
    guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
        let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]],
        let use = blocks.last(where: { ($0["type"] as? String) == "tool_use" })
    else { return nil }
    let input = use["input"] as? [String: Any] ?? [:]
    func brief(_ text: String?) -> String { String(plain(text ?? "").split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces) }
    switch use["name"] as? String ?? "" {
    case "AskUserQuestion":
        let questions = input["questions"] as? [[String: Any]] ?? []
        guard let first = questions.first?["question"] as? String else { return .askGeneric }
        return .ask(question: brief(first), count: questions.count)
    case "ExitPlanMode":
        return .plan
    case "Bash":
        return .approveRun(command: brief(input["description"] as? String ?? input["command"] as? String))
    case "Edit", "Write", "NotebookEdit":
        return .approveEdit(file: (input["file_path"] as? String).map { ($0 as NSString).lastPathComponent })
    case let name:
        return .approveTool(tool: name)
    }
}

// ───────── Background tasks ─────────
//
// Claude Code's registry says nothing of background work, so it is read from the session's transcript (an internal
// format, as of 2.1.310; on the list to check after an upgrade, with tailInfo's): a task starts with a `type:user` line
// whose `toolUseResult` has a `backgroundTaskId` (a background command, also one moved there by its timeout) or the
// `agentId` of an `async_launched` subagent; it ends with a `<task-notification>` (completed, failed, killed or stopped)
// in a `queue-operation` enqueue line or a `type:user` line, or with a TaskStop's result (`task_id` beside `task_type`),
// or, for subagents all at once, with a `type:system` line of subtype `agents_killed`.
// Only those lines, decoded as JSON, are believed: a quotation of a notification elsewhere is not one.
// A transcript runs to tens of megabytes and the panel looks every 2 s (the phone's helper runs `--dump` every 3 s), so each
// is read once, then only what was added. How far each has been read is kept in a file (`bg-scan.json` in the caches folder)
// that the panel and every `--dump` read at their start and write back, whole and by rename, when it changed; whichever
// wrote last stands, each being a consistent picture, and at worst the next one reads a little more.

/// Where the progress is kept; none in the checks, which give their own.
#if TESTING
let defaultBGCache = ""
#else
let defaultBGCache = cacheFolder + "/bg-scan.json"
#endif
/// Where the moments dead processes were first found are kept; none in the checks, which give their own.
#if TESTING
let defaultGoneCache = ""
#else
let defaultGoneCache = cacheFolder + "/gone.json"
#endif
/// How long a session that went without leave stays on the list as `disconnected`, from the moment it was found gone.
let disconnectedShown: TimeInterval = 600
/// What `BGScan.advance` has read from transcripts in this process, in bytes (for the checks).
var bgBytesRead: UInt64 = 0
let bgCacheVersion = 3
/// The longest a task's words (`BGItem.desc`) run, in characters.
let bgDescLength = 80

/// A background task running longer than this is likely hung (the earliest of them sets `Session.bgStale`).
let bgStaleAfter: TimeInterval = 2 * 3600

/// One background task running, as `--dump`'s bgList gives it.
struct BGItem: Equatable {
    /// "cmd" (a background command, also one moved there by its timeout) or "agent" (a background subagent).
    var kind: String
    /// What it does, on one line and no longer than `bgDescLength`: the Bash call's description (else the start of its command), a subagent's description.
    var desc: String
    var since: Date
    /// The `backgroundTaskId` of a command, the `agentId` of a subagent.
    var id: String
    /// The id of the tool call that began it.
    var toolUseId: String
    var json: [String: Any] {
        ["kind": kind, "desc": desc, "since": since.timeIntervalSince1970, "id": id, "toolUseId": toolUseId]
    }
}

/// What a task begun is, kept while it runs.
struct BGTask {
    var at: Date
    var agent: Bool
    var desc = ""
    var toolUseId = ""
}

/// A text on one line and cut to `bgDescLength` characters.
func bgOneLine(_ text: String) -> String {
    let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    return String(flat.prefix(bgDescLength))
}

struct BGState: Equatable {
    var tasks = 0
    var agents = 0
    var since: Date? = nil
    /// When the last background task ended (a notification, a TaskStop's result, `agents_killed`), the moment of that line.
    var endedAt: Date? = nil
    /// Since the last turn the user started, a background task was begun.
    var owned = false
    /// The tasks themselves, earliest first (equal moments: by id).
    var list: [BGItem] = []
    static let none = BGState()
    /// Nothing running (whatever has ended, and whether one was begun in the turn).
    var quiet: Bool { tasks == 0 && agents == 0 && since == nil }
    func stale(now: Date) -> Bool { since.map { now.timeIntervalSince($0) > bgStaleAfter } ?? false }
}

/// One transcript read so far: which file, where it stopped, and the tasks begun and ended in what has been read.
struct BGScan {
    var path = ""
    var inode: UInt64 = 0
    /// Where the first line not yet read begins; a last line still being written is left until it has its newline.
    var offset: UInt64 = 0
    var started: [String: BGTask] = [:]
    var ended = Set<String>()
    /// The Bash calls seen and not yet answered: tool call id -> its description (the command's start when it has none). A
    /// command that went to the background is told by the answer, and the call is where its words are. Gone when answered.
    var asked: [String: String] = [:]
    /// When each of those calls was made (the line's own time, else when it was read): a call still unanswered after a day is
    /// not going to be (the session ended mid-call), and leaves the table, so the cache file does not grow with them.
    var askedAt: [String: Date] = [:]
    static let askedKeeps: TimeInterval = 24 * 3600
    var endedAt: Date? = nil
    var owned = false

    private static let endings: Set<String> = ["completed", "failed", "killed", "stopped"]

    /// At most this much of a transcript is read in one look; the rest waits for the next one.
    nonisolated(unsafe) static var roundBytes: UInt64 = 64 << 20
    /// A line longer than this is not taken: it is passed over up to its newline.
    nonisolated(unsafe) static var lineBytes: UInt64 = 16 << 20
    /// The bytes from `offset` up to here have no newline in them (not kept in the cache file).
    var searched: UInt64 = 0
    /// The line at `offset` is longer than `lineBytes`: what is left of it, up to its newline, is passed over.
    var skipping = false

    /// Begun and not ended: the count, the subagents among them, and the earliest start.
    var state: BGState {
        var s = BGState()
        s.endedAt = endedAt
        s.owned = owned
        for (id, t) in started where !ended.contains(id) {
            s.tasks += 1
            if t.agent { s.agents += 1 }
            if s.since.map({ t.at < $0 }) ?? true { s.since = t.at }
            s.list.append(BGItem(kind: t.agent ? "agent" : "cmd", desc: t.desc, since: t.at, id: id, toolUseId: t.toolUseId))
        }
        s.list.sort { $0.since != $1.since ? $0.since < $1.since : $0.id < $1.id }
        return s
    }

    /// Reads what the file has added since the last look; the whole of it again when it is another file (a new inode or
    /// path) or has become shorter. Whether anything of the scan changed (what is to be kept).
    /// Drops the calls asked more than a day before `now` that were never answered. Whether any went.
    @discardableResult
    mutating func dropOldAsked(now: Date = Date()) -> Bool {
        var gone = false
        for id in asked.keys {
            let at = askedAt[id] ?? { askedAt[id] = now; return now }()  // a table from before the stamps: from now on
            if now.timeIntervalSince(at) > Self.askedKeeps { asked[id] = nil; askedAt[id] = nil; gone = true }
        }
        for id in askedAt.keys where asked[id] == nil { askedAt[id] = nil }
        return gone
    }

    @discardableResult
    mutating func advance(path newPath: String) -> Bool {
        var st = stat()
        guard stat(newPath, &st) == 0 else { return false }
        let fileInode = UInt64(st.st_ino), size = UInt64(st.st_size)
        var changed = false
        if newPath != path || fileInode != inode || size < offset {
            self = BGScan()
            path = newPath
            inode = fileInode
            changed = true
        }
        if size < searched { searched = offset }
        if dropOldAsked() { changed = true }
        // Bytes before `from` (from `offset` on) are known to hold no newline: only what follows is searched.
        let from = max(offset, searched)
        guard size > from, let handle = FileHandle(forReadingAtPath: newPath) else { return changed }
        defer { try? handle.close() }
        let stop = min(size, from + Self.roundBytes)
        try? handle.seek(toOffset: from)
        var carry = Data()  // read, not yet taken: the start (or, from `start`, the rest) of the line at `offset`
        var start = from  // where `carry` begins in the file; past `offset` when the line's start was read in an earlier look
        var at = from  // read up to here
        while at < stop, let chunk = try? handle.read(upToCount: Int(min(8 << 20, stop - at))), !chunk.isEmpty {
            bgBytesRead += UInt64(chunk.count)
            let chunkStart = at
            at += UInt64(chunk.count)
            var rest = chunk
            if skipping {
                // The rest of a line past the cap: passed over up to its newline.
                guard let nl = rest.firstIndex(of: 0x0A) else { offset = at; start = at; changed = true; continue }
                let cut = rest.distance(from: rest.startIndex, to: nl) + 1
                rest = Data(rest.dropFirst(cut))
                offset = chunkStart + UInt64(cut)
                start = offset
                skipping = false
                changed = true
            }
            if let nl = rest.firstIndex(of: 0x0A) {
                let lineEnd = (at - UInt64(rest.count)) + UInt64(rest.distance(from: rest.startIndex, to: nl))  // the newline's place
                if lineEnd - offset > Self.lineBytes {
                    // The line at `offset` is past the cap now that it has ended: passed over, its start not read again.
                    rest = Data(rest.dropFirst(rest.distance(from: rest.startIndex, to: nl) + 1))
                    carry = Data()
                    offset = lineEnd + 1
                    start = offset
                    changed = true
                } else if start > offset {
                    // The line's start, read in an earlier look and not kept: read once more now that the line is whole.
                    try? handle.seek(toOffset: offset)
                    let head = (try? handle.read(upToCount: Int(start - offset))) ?? Data()
                    bgBytesRead += UInt64(head.count)
                    try? handle.seek(toOffset: at)
                    guard head.count == Int(start - offset) else { break }
                    carry = head + carry
                    start = offset
                }
            }
            carry.append(rest)
            if let last = carry.lastIndex(of: 0x0A) {
                let end = carry.distance(from: carry.startIndex, to: last) + 1
                forEachLine(of: carry.prefix(end)) { _, line in if UInt64(line.count) <= Self.lineBytes { take(line) } }
                carry = Data(carry.dropFirst(end))
                offset = start + UInt64(end)
                start = offset
                changed = true
            }
            if at - offset > Self.lineBytes {
                // An unfinished line past the cap: from here on passed over up to its newline.
                skipping = true
                carry = Data()
                offset = at
                start = at
                changed = true
            }
        }
        searched = at
        return changed
    }

    // The file: {"version": n, "sessions": {sid: {path, inode, offset, started: {id: {at, agent}}, ended: [id]}}}.
    var asJSON: [String: Any] {
        var begun: [String: Any] = [:]
        for (id, t) in started {
            begun[id] = ["at": t.at.timeIntervalSince1970, "agent": t.agent, "desc": t.desc, "toolUseId": t.toolUseId] as [String: Any]
        }
        var o: [String: Any] = ["path": path, "inode": NSNumber(value: inode), "offset": NSNumber(value: offset), "started": begun,
            "ended": ended.sorted(), "endedAt": endedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(), "owned": owned, "asked": asked,
            "askedAt": askedAt.mapValues { $0.timeIntervalSince1970 }]
        if skipping { o["skipping"] = true }  // the line at `offset` is being passed over (left out when not)
        return o
    }

    init() {}

    /// nil for an entry that is not what `asJSON` makes.
    init?(json o: Any?) {
        guard let o = o as? [String: Any], let path = o["path"] as? String, let inode = (o["inode"] as? NSNumber)?.uint64Value,
            let offset = (o["offset"] as? NSNumber)?.uint64Value, let begun = o["started"] as? [String: Any],
            let ended = o["ended"] as? [String], let owned = o["owned"] as? Bool, let asked = o["asked"] as? [String: String]
        else { return nil }
        self.asked = asked
        for (id, at) in (o["askedAt"] as? [String: Double]) ?? [:] where asked[id] != nil { askedAt[id] = Date(timeIntervalSince1970: at) }
        if let at = o["endedAt"] as? Double { endedAt = Date(timeIntervalSince1970: at) } else if !(o["endedAt"] is NSNull) { return nil }
        self.owned = owned
        self.skipping = (o["skipping"] as? Bool) ?? false
        self.path = path
        self.inode = inode
        self.offset = offset
        self.ended = Set(ended)
        for (id, t) in begun {
            guard let t = t as? [String: Any], let at = t["at"] as? Double, let agent = t["agent"] as? Bool,
                let desc = t["desc"] as? String, let toolUseId = t["toolUseId"] as? String
            else { return nil }
            started[id] = BGTask(at: Date(timeIntervalSince1970: at), agent: agent, desc: desc, toolUseId: toolUseId)
        }
    }

    static func encode(_ scans: [String: BGScan]) -> Data {
        let o: [String: Any] = ["version": bgCacheVersion, "sessions": scans.mapValues { $0.asJSON }]
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }

    /// Empty for a file that is missing, unreadable, of another version or not as written: the scans then start over. An
    /// entry that is not as written is dropped alone.
    static func decode(_ data: Data?) -> [String: BGScan] {
        guard let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            (o["version"] as? Int) == bgCacheVersion, let sessions = o["sessions"] as? [String: Any]
        else { return [:] }
        return sessions.compactMapValues { BGScan(json: $0) }
    }

    /// One whole line. The cheap byte searches first: nearly every line says nothing of a task.
    mutating func take(_ line: UnsafeRawBufferPointer) {
        look(line)
        release(line)
    }

    /// A call answered is no longer waited for: every `"tool_use_id":"…"` of a line that has a tool result in it. Bytes only (the
    /// lines run long), and nothing at all while no call is waited for.
    private mutating func release(_ line: UnsafeRawBufferPointer) {
        guard !asked.isEmpty, Phrase.toolResult.isIn(line), let base = line.baseAddress else { return }
        let key = Phrase.toolUseId.bytes
        var from = 0
        while from < line.count {
            guard let hit = key.withUnsafeBytes({ memmem(base + from, line.count - from, $0.baseAddress, $0.count) }) else { break }
            let start = base.distance(to: UnsafeRawPointer(hit)) + key.count
            var end = start
            while end < line.count && line[end] != 0x22 { end += 1 }
            if end < line.count {
                let id = String(decoding: UnsafeRawBufferPointer(rebasing: line[start..<end]), as: UTF8.self)
                asked.removeValue(forKey: id)
                askedAt.removeValue(forKey: id)
            }
            from = max(end, start)
        }
    }

    private mutating func look(_ line: UnsafeRawBufferPointer) {
        guard Phrase.bgLaunch.isIn(line) || Phrase.asyncLaunched.isIn(line) || Phrase.notification.isIn(line)
            || Phrase.taskType.isIn(line) || Phrase.agentsKilled.isIn(line) || Phrase.userText.isIn(line)
            || Phrase.promptSource.isIn(line) || Phrase.bashCall.isIn(line),
            let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
            (o["isSidechain"] as? Bool) != true
        else { return }
        switch o["type"] as? String {
        case "assistant":
            // A Bash call: its description (or the start of its command) waits here for the answer.
            for block in ((o["message"] as? [String: Any])?["content"] as? [[String: Any]]) ?? []
            where (block["type"] as? String) == "tool_use" && (block["name"] as? String) == "Bash" {
                guard let id = block["id"] as? String, !id.isEmpty, let input = block["input"] as? [String: Any] else { continue }
                let said = (input["description"] as? String) ?? ""
                asked[id] = bgOneLine(said.isEmpty ? (input["command"] as? String ?? "") : said)
                askedAt[id] = Self.moment(o) ?? Date()
            }
        case "system":
            // "All background subagents stopped now" (no task id): those begun before it in the transcript are over.
            // Commands are not said to be (not verified), and stay.
            if (o["subtype"] as? String) == "agents_killed" {
                for (id, t) in started where t.agent { ended.insert(id) }
                note(end: Self.moment(o))
            }
        case "queue-operation":
            if (o["operation"] as? String) == "enqueue", let text = o["content"] as? String { notified(text, at: Self.moment(o)) }
        case "user":
            if let result = o["toolUseResult"] as? [String: Any] {
                if let id = result["backgroundTaskId"] as? String, !id.isEmpty {
                    launched(id, o, agent: false, words: nil)
                }
                if (result["status"] as? String) == "async_launched", let id = result["agentId"] as? String, !id.isEmpty {
                    launched(id, o, agent: true, words: result["description"] as? String ?? "")
                }
                // TaskStop's result: the task it stopped leaves no notification.
                if result["task_type"] is String, let id = result["task_id"] as? String, !id.isEmpty { end(id, Self.moment(o)) }
            }
            let content = (o["message"] as? [String: Any])?["content"]
            if let text = content as? String {
                notified(text, at: Self.moment(o))
            } else if let blocks = content as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "text" {
                    if let text = block["text"] as? String { notified(text, at: Self.moment(o)) }
                }
            }
        default: break
        }
        // A turn the user started (the one rule of the panel's, `turnOrigin`: not a peer's, a subagent's or a task's notice) begins afresh.
        if let turn = turnOrigin(o) {
            if turn.origin == "user" { owned = false }
        } else if (o["type"] as? String) == "user", (o["isMeta"] as? Bool) != true, o["toolUseResult"] == nil,
            let blocks = (o["message"] as? [String: Any])?["content"] as? [[String: Any]],
            !blocks.contains(where: { ($0["type"] as? String) == "tool_result" }),
            (o["promptSource"] as? String) == "typed" || ((o["origin"] as? [String: Any])?["kind"] as? String) == "human"
        {
            owned = false  // what the user typed with a picture in it: content an array, marked as theirs
        }
    }

    private static func moment(_ line: [String: Any]) -> Date? {
        guard let stamp = line["timestamp"] as? String else { return nil }
        return codexStamps.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
    }

    private mutating func end(_ id: String, _ at: Date?) {
        if ended.insert(id).inserted { note(end: at) }
    }

    private mutating func note(end at: Date?) {
        if let at, endedAt.map({ at > $0 }) ?? true { endedAt = at }
    }

    /// `words`: what a subagent was given to do; nil for a command, whose words are those of the call that began it.
    private mutating func launched(_ id: String, _ line: [String: Any], agent: Bool, words: String?) {
        owned = true
        guard started[id] == nil else { return }
        // The call that began it: the one the line answers.
        let answered = ((line["message"] as? [String: Any])?["content"] as? [[String: Any]])?
            .first { ($0["type"] as? String) == "tool_result" }?["tool_use_id"] as? String ?? ""
        let desc = words.map(bgOneLine) ?? asked[answered] ?? ""
        started[id] = BGTask(at: Self.moment(line) ?? Date(), agent: agent, desc: desc, toolUseId: answered)
    }

    /// The notification(s) a text is made of, as the injected message is: it begins with one. A text that only mentions
    /// one further in is somebody's quotation.
    private mutating func notified(_ text: String, at: Date?) {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<task-notification>") else { return }
        func between(_ s: String, _ open: String, _ close: String) -> String? {
            guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
            return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for part in text.components(separatedBy: "<task-notification>").dropFirst() {
            if let id = between(part, "<task-id>", "</task-id>"), !id.isEmpty,
                let status = between(part, "<status>", "</status>"), Self.endings.contains(status)
            {
                end(id, at)
            }
        }
    }
}
