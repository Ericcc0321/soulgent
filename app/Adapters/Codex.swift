import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

// ───────── Codex CLI sessions ─────────
//
// Codex CLI keeps each conversation (a thread) in a rollout file under its CODEX_HOME, and an index of the threads in
// <CODEX_HOME>/state_5.sqlite; both are Codex's internal formats, as of version 0.160. A session here is an interactive
// `codex` process: the thread it has open, as that index and the end of its rollout describe it. Codex asks nothing the
// way Claude Code does (no approvals or questions were ever found in a rollout), so its sessions are busy or idle only.

/// What a session's card says after its name about which agent it is; `short`, the mark that fits on a name plate in the
/// office: the prompt Codex CLI's own header starts with (the Codex app's too, the same agent), WorkBuddy's initials.
/// Claude Code's sessions, the most, go without.
func kindTag(_ s: Session, short: Bool = false) -> String? {
    switch s.kind {
    case "codex": return short ? ">_" : "Codex"
    case "codexApp": return short ? ">_" : "Codex App"
    case "workbuddy": return short ? "WB" : "WorkBuddy"
    default: return nil
    }
}

/// A Codex thread's name: the one the user gave it, else the first line of its first message, cut to 24 characters.
func codexName(name: String?, title: String) -> String {
    codexGivenName(name: name, title: title) ?? "未命名"
}

/// `codexName` short of its default: nil when it is the default untitled name for want of a name or a first line (`nameUntitled`).
func codexGivenName(name: String?, title: String) -> String? {
    if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
    let first = title.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
    return first.map { String($0.prefix(24)) }
}

/// Codex's subcommands that run with no conversation of theirs: its servers and one-shot runs, with their short forms.
private let codexOthers: Set<String> = [
    "app-server", "exec-server", "exec", "e", "mcp", "mcp-server", "login", "logout", "apply", "a", "completion", "sandbox", "debug",
    "cloud", "features", "help", "proto", "responses-api-proxy", "stdio-to-uds",
]

/// Whether a process, by its arguments, is a Codex session the user types in: `codex` bare, resumed or with a prompt, whatever its
/// flags. Not one of its servers or one-shot runs, nor a program named otherwise (the node script that starts the real
/// binary, `codex-code-mode-host`).
func codexInteractive(_ args: [String]) -> Bool {
    guard let program = args.first, (program as NSString).lastPathComponent == "codex" else { return false }
    return !args.dropFirst().contains(where: codexOthers.contains)
}

let codexStamps: ISO8601DateFormatter = {
    let format = ISO8601DateFormatter()
    format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return format
}()

/// Calls `body` with the whole lines of a file from `floor` (where a line starts) to `end`, the last line first, until it
/// says it has seen enough; gives where the whole lines end. It reads back from the end in chunks that double: what is
/// wanted lies near the end, and a single line before it can run to megabytes. A last line without its newline is still
/// being written, and is left for the next read.
func linesBackward(_ handle: FileHandle, from end: UInt64, to floor: UInt64, _ body: (UnsafeRawBufferPointer) -> Bool) -> UInt64 {
    var upper = end, chunk: UInt64 = 400_000
    var carry = Data()  // the end of a line that began before `upper`
    var through: UInt64?
    // By the bytes: Data's own search goes one byte at a time through its indices, slow across megabytes of one line.
    func newline(in data: Data, last: Bool) -> Int? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int? in
            guard let base = raw.baseAddress else { return nil }
            if !last { return memchr(base, 0x0A, raw.count).map { base.distance(to: UnsafeRawPointer($0)) } }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            var i = raw.count - 1
            while i >= 0 && bytes[i] != 0x0A { i -= 1 }
            return i >= 0 ? i : nil
        }
    }
    while upper > floor {
        let lower = upper - min(chunk, upper - floor)
        chunk *= 2
        try? handle.seek(toOffset: lower)
        guard var data = try? handle.read(upToCount: Int(upper - lower)) else { break }
        if !carry.isEmpty { data.append(carry) }
        upper = lower
        if through == nil {
            guard let last = newline(in: data, last: true) else {
                carry = data
                continue
            }
            through = lower + UInt64(last + 1)
            data = data.prefix(last + 1)
        }
        var start = 0
        if lower > floor {
            guard let first = newline(in: data, last: false) else {
                carry = data
                continue
            }
            carry = data.subdata(in: 0..<(first + 1))
            start = first + 1
        } else {
            carry = Data()
        }
        let enough = data[start...].withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return false }
            var lines: [Range<Int>] = []
            var from = 0
            while from < raw.count {
                let to = memchr(base + from, 0x0A, raw.count - from).map { base.distance(to: UnsafeRawPointer($0)) } ?? raw.count
                if to > from { lines.append(from..<to) }
                from = to + 1
            }
            for line in lines.reversed() {
                if body(UnsafeRawBufferPointer(rebasing: raw[line])) { return true }
            }
            return false
        }
        if enough { break }
    }
    return through ?? floor
}

/// Where a Codex rollout stands, from its end: the latest turn event says whether a turn is running and since when, and
/// the agent's latest message is what its card says. Read for the Codex app (`app`), it also keeps what the thread waits
/// on the user for, apart from how its turn stands: the question cards it put up that the user has not answered, and approvals its
/// running turn asked for. Those are the app's own ways of asking; the CLI's sessions are busy or idle only.
struct CodexTail {
    var size: UInt64 = 0
    var mtime = Date.distantPast
    var parsedAt = Date.distantPast
    /// Where the whole lines read so far end: the next read starts there, as the file only grows.
    var offset: UInt64 = 0
    /// Whether the latest turn event started a turn, and when it came.
    var busy = false
    var since: Date?
    /// The agent's latest message, by its first line or its own progress-marker line, as a Claude session's reply gives. In the
    /// app's, "a You: prefix" instead while the user's latest words are newer.
    var summaryLine = SummaryLine.empty
    var summary: String { summaryLine.rendered }
    /// The app's: the agent's latest words, and the user's, from the items the app marks as typed by the user (`user.text`); the
    /// others it files as the user's (the machine, the page open beside the chat) are not the user's words.
    var said: (at: String, text: String)?
    var asked: (at: String, text: String)?
    /// The app's question cards (`request_user_input_async`) the user has not answered, by card and question: its title, and
    /// when it came up. A card outlives its turn, which ends seconds after putting it up; the user's answer starts a new turn.
    var questions: [String: (title: String, at: Date)] = [:]
    /// Approvals the app's running turn asked for and has had no answer to, by call: when it asked.
    var approvals: [String: Date] = [:]
    /// The whole lines read were there and none of a kind known (`FormatCensus`): Codex's rollout format changed.
    var unknownLines = false

    var status: String { busy ? "busy" : "idle" }

    /// How far back a first look goes: one turn's tool output can run to megabytes, and a rollout can grow by tens of
    /// megabytes in a day.
    static let farthest: UInt64 = 64 << 20
    private static let started = Phrase("\"type\":\"task_started\""), complete = Phrase("\"type\":\"task_complete\"")
    private static let aborted = Phrase("\"type\":\"turn_aborted\""), message = Phrase("\"type\":\"message\"")
    private static let assistant = Phrase("\"role\":\"assistant\"")

    /// The rollout read on from where `previous` left off, newest lines first, until a turn event and the agent's words turn
    /// up among what is new; what does not turn up stays as it was. A 400 KB tail is not enough: a working turn writes
    /// megabytes of tool output after the event that started it. Like a Claude transcript it is read again only when it
    /// changed, and while busy at most every 10 s, so a finished turn can show up to 10 s late. The app's is read back to
    /// its latest turn start and the agent's words: a card from before that start no longer counts, so nothing
    /// older is needed; the chunks read back double from 400 KB, up to `farthest`.
    static func read(_ path: String, after previous: CodexTail?, now: Date, farthest: UInt64 = farthest, app: Bool = false) -> CodexTail {
        var file = stat()
        guard stat(path, &file) == 0 else { return previous ?? CodexTail() }
        let size = UInt64(file.st_size)
        let mtime = Date(timeIntervalSince1970: Double(file.st_mtimespec.tv_sec) + Double(file.st_mtimespec.tv_nsec) / 1_000_000_000)
        if let previous {
            if previous.size == size && previous.mtime == mtime { return previous }
            if previous.status == "busy" && now.timeIntervalSince(previous.parsedAt) < 10 { return previous }
        }
        var tail = previous ?? CodexTail()
        if size < tail.offset { tail = CodexTail() }  // the file was replaced
        tail.size = size
        tail.mtime = mtime
        tail.parsedAt = now
        guard let handle = FileHandle(forReadingAtPath: path) else { return tail }
        defer { try? handle.close() }
        var turn: (started: Bool, at: String)?
        var reply: (at: String, text: String)?
        var found = AppLines()
        var startSeen = false  // the latest task_started among what is new
        let floor = max(tail.offset, size > farthest ? size - farthest : 0), capped = floor > tail.offset
        var census = FormatCensus()  // only whole lines come here; the first may be cut when capped, which says nothing then
        tail.offset = linesBackward(handle, from: size, to: floor) { line in
            // A line's kinds come first in it; looking only there passes over the megabytes of a tool's output.
            let head = UnsafeRawBufferPointer(rebasing: line.prefix(400))
            census.whole += 1
            if census.known == 0, codexLineKinds.contains(where: { $0.isIn(head) }) { census.known += 1 }
            if turn == nil, started.isIn(head) || complete.isIn(head) || aborted.isIn(head),
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], (o["type"] as? String) == "event_msg",
                let kind = (o["payload"] as? [String: Any])?["type"] as? String, ["task_started", "task_complete", "turn_aborted"].contains(kind),
                let at = o["timestamp"] as? String
            {
                turn = (kind == "task_started", at)
                startSeen = startSeen || kind == "task_started"
            } else if app, !startSeen, started.isIn(head),
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], (o["type"] as? String) == "event_msg",
                ((o["payload"] as? [String: Any])?["type"] as? String) == "task_started"
            {
                startSeen = true
            } else if reply == nil, message.isIn(head), assistant.isIn(head),
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], (o["type"] as? String) == "response_item",
                let payload = o["payload"] as? [String: Any], (payload["role"] as? String) == "assistant",
                let blocks = payload["content"] as? [[String: Any]], let at = o["timestamp"] as? String
            {
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply = (at, text) }
            } else if app {
                found.take(line, head: head, inLastTurn: turn == nil, beforeStart: startSeen)
            }
            return app ? startSeen && reply != nil : turn != nil && reply != nil
        }
        if !capped, let verdict = census.verdict { tail.unknownLines = verdict }
        if let turn {
            tail.busy = turn.started
            tail.since = codexStamps.date(from: turn.at)
        } else if capped {
            // All that was read back is one turn's output: it is still running. A turn ends with a task_complete or a
            // turn_aborted, one short line, and the next starts with a task_started; only a running turn writes this much
            // with no event. Since when is not known from here: it keeps what was known, else the thread's start.
            tail.busy = true
        }
        guard app else {
            if let reply { tail.summaryLine = pickSummaryLine(recap: nil, reply: reply, asked: nil) }
            return tail
        }
        if let reply { tail.said = reply }
        if let asked = found.asked { tail.asked = asked }
        tail.summaryLine = pickSummaryLine(recap: nil, reply: tail.said, asked: tail.asked)
        // A turn started since: the cards before it no longer count, whatever started it; those read now after it are
        // open unless answered later on. Without one, those read before stay open until an answer turns up.
        if startSeen {
            tail.questions = found.cards
        } else {
            tail.questions = tail.questions.filter { !found.answered.contains($0.key) }.merging(found.cards) { kept, _ in kept }
        }
        // An approval belongs to its turn: a turn that has ended, or a new one, leaves none of the old turn's waiting.
        let unanswered = found.requests.filter { !found.outputs.contains($0.key) }
        if let turn {
            tail.approvals = turn.started ? unanswered : [:]
        } else {
            tail.approvals = tail.approvals.filter { !found.outputs.contains($0.key) }.merging(unanswered) { kept, _ in kept }
        }
        return tail
    }

    /// What a backward read of the app's rollout gathers besides the turn event and the agent's words, newest line first.
    /// Tool output, command results and web content are never decoded: a line is taken apart only when its head says it
    /// is one of the user's messages, a card, or an approval request (each a few hundred bytes); an answered call is known by the
    /// call id near the start of its output line.
    private struct AppLines {
        var asked: (at: String, text: String)?
        /// Questions the user answered, by card and question, in what was read so far (all of it newer than the cards to come).
        var answered = Set<String>()
        var cards: [String: (title: String, at: Date)] = [:]
        /// In the turn the read ends in (newer than its latest turn event): approvals asked for, and the calls answered.
        var requests: [String: Date] = [:]
        var outputs = Set<String>()

        private static let user = Phrase("\"role\":\"user\""), message = Phrase("\"type\":\"message\"")
        private static let item = Phrase("\"type\":\"item_completed\""), agentMessage = Phrase("\"type\":\"AgentMessage\"")
        private static let async = Phrase("\"delivery\":\"async\"")
        private static let toolCall = Phrase("\"type\":\"custom_tool_call\""), permissions = Phrase("tools.request_permissions(")
        /// What the app marks their own typing with; its other "user" messages (the machine, the web page open beside the chat)
        /// are never decoded.
        private static let typed = Phrase("\"content_item_kinds\":[\"user.text\"]")
        private static let outputs = [Phrase("\"type\":\"custom_tool_call_output\""), Phrase("\"type\":\"function_call_output\"")]
        static let reply = "<send_user_message_question_reply>", replyEnd = "</send_user_message_question_reply>"

        /// `beforeStart`: the line is older than the latest turn start, where cards and answers no longer matter.
        mutating func take(_ line: UnsafeRawBufferPointer, head: UnsafeRawBufferPointer, inLastTurn: Bool, beforeStart: Bool) {
            if Self.message.isIn(head), Self.user.isIn(head) {
                guard Self.typed.isIn(line), let (at, payload) = Self.decode(line), (payload["role"] as? String) == "user",
                    let marks = payload["internal_chat_message_metadata_passthrough"] as? [String: Any],
                    (marks["content_item_kinds"] as? [String]) == ["user.text"]
                else { return }
                let blocks = payload["content"] as? [[String: Any]] ?? []
                let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.hasPrefix(Self.reply) {
                    if !beforeStart { answered.formUnion(Self.questionsAnswered(text)) }
                } else if asked == nil, !text.isEmpty, !text.hasPrefix("<") {
                    asked = (at, text)
                }
            } else if !beforeStart, Self.item.isIn(head), Self.agentMessage.isIn(head), Self.async.isIn(line) {
                guard let (at, payload) = Self.decode(line), let card = payload["item"] as? [String: Any],
                    (card["delivery"] as? String) == "async", let id = card["id"] as? String, let when = codexStamps.date(from: at)
                else { return }
                for (place, question) in (card["questions"] as? [[String: Any]] ?? []).enumerated() where !answered.contains("\(id) \(place)") {
                    cards["\(id) \(place)"] = (question["title"] as? String ?? "", when)
                }
            } else if inLastTurn, Self.toolCall.isIn(head), Self.permissions.isIn(line) {
                // The code mode's `tools.request_permissions(…)` called in an `exec` script (a script that only names it,
                // in a string, is not asking): it waits for the user's approval until the call has its output. (Were Codex to write exec_approval_request or apply_patch_approval_request events, as
                // its binary knows, they would be the same kind of wait; none has been seen in a rollout yet.)
                guard let (at, payload) = Self.decode(line), let call = payload["call_id"] as? String, let when = codexStamps.date(from: at)
                else { return }
                if !outputs.contains(call) { requests[call] = when }
            } else if inLastTurn, Self.outputs.contains(where: { $0.isIn(head) }), let call = Self.callID(line) {
                outputs.insert(call)
            }
        }

        private static func decode(_ line: UnsafeRawBufferPointer) -> (at: String, payload: [String: Any])? {
            guard let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], let at = o["timestamp"] as? String,
                let payload = o["payload"] as? [String: Any]
            else { return nil }
            return (at, payload)
        }

        /// The call an output line answers, from its `call_id`, which comes before the output itself.
        private static func callID(_ line: UnsafeRawBufferPointer) -> String? {
            let key = Array("\"call_id\":\"".utf8)
            let near = UnsafeRawBufferPointer(rebasing: line.prefix(1000))
            guard let base = near.baseAddress,
                let hit = key.withUnsafeBytes({ memmem(base, near.count, $0.baseAddress, $0.count) })
            else { return nil }
            let from = base.distance(to: UnsafeRawPointer(hit)) + key.count
            guard let to = near[from...].firstIndex(of: 0x22) else { return nil }
            return String(decoding: near[from..<to], as: UTF8.self)
        }

        /// The questions an answer of theirs settles: each `questionItemId` names its card and the question's place, as
        /// `["request_user_input_async", <card id>, <place>]`.
        static func questionsAnswered(_ text: String) -> Set<String> {
            guard let open = text.range(of: reply), let close = text.range(of: replyEnd, range: open.upperBound..<text.endIndex),
                let answers = (try? JSONSerialization.jsonObject(with: Data(text[open.upperBound..<close.lowerBound].utf8))) as? [[String: Any]]
            else { return [] }
            var settled = Set<String>()
            for answer in answers {
                guard let item = answer["questionItemId"] as? String,
                    let parts = (try? JSONSerialization.jsonObject(with: Data(item.utf8))) as? [Any], parts.count >= 3,
                    let card = parts[1] as? String, let place = parts[2] as? Int
                else { continue }
                settled.insert("\(card) \(place)")
            }
            return settled
        }
    }
}

/// A process's arguments and environment as the kernel kept them from its start (`KERN_PROCARGS2`). `ps` would cut an
/// environment value at its first space, and CODEX_HOME under Orca is in "Application Support".
func processArguments(_ pid: Int32) -> (args: [String], env: [String: String])? {
    var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
    var longest: Int32 = 0, width = MemoryLayout<Int32>.size
    guard sysctl(&mib, 2, &longest, &width, nil, 0) == 0, longest > 0 else { return nil }
    var buffer = [UInt8](repeating: 0, count: Int(longest))
    var size = buffer.count
    mib = [CTL_KERN, KERN_PROCARGS2, pid]
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    // The number of arguments; the executable's path and its padding; then each argument and each variable, each ended by a
    // zero byte.
    let count = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = MemoryLayout<Int32>.size
    while i < size && buffer[i] != 0 { i += 1 }
    while i < size && buffer[i] == 0 { i += 1 }
    var strings: [String] = []
    var start = i
    while i < size {
        if buffer[i] == 0 {
            if i > start { strings.append(String(decoding: buffer[start..<i], as: UTF8.self)) }
            start = i + 1
        }
        i += 1
    }
    var env: [String: String] = [:]
    for entry in strings.dropFirst(count) {
        guard let equals = entry.firstIndex(of: "="), env[String(entry[..<equals])] == nil else { continue }
        env[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
    }
    return (Array(strings.prefix(count)), env)
}

/// The path of the file a process has open on a descriptor, if it is a file.
func openFile(_ pid: Int32, _ fd: Int32) -> String? {
    var info = vnode_fdinfowithpath()
    let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
    guard proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { return nil }
    return withUnsafeBytes(of: &info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
}

/// The rollout a Codex process has open, and on which descriptor, from the kernel's list of its open files.
func codexOpenRollout(_ pid: Int32) -> (fd: Int32, path: String)? {
    let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard bytes > 0 else { return nil }
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16)
    let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
    guard got > 0 else { return nil }
    for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_VNODE {
        guard let path = openFile(pid, fd.proc_fd) else { continue }
        let file = (path as NSString).lastPathComponent
        if file.hasPrefix("rollout-") && file.hasSuffix(".jsonl") { return (fd.proc_fd, path) }
    }
    return nil
}

/// A process's working directory.
func processCwd(_ pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    return path.isEmpty ? nil : path
}

/// A running `codex` that is a session the user types in: which process, when it started, and the CODEX_HOME it keeps its threads in.
struct CodexProcess: Equatable {
    let pid: Int32
    let start: Double  // seconds since 1970
    let home: String
}

/// The interactive Codex processes running now. One `sysctl` a tick lists every process with its command name and start;
/// a `codex` one's arguments and environment are read once. Not `proc_pidpath` for each process: a thousand calls a tick,
/// and it fails for a process whose binary an update has since replaced. The node script that starts Codex is `node` by
/// name, so only the real binary is found, the one that has the rollout open.
final class CodexProcesses {
    private var known: [String: CodexProcess] = [:]  // by pid and start: a pid can come back as another process
    private var others = Set<String>()  // codex processes that are not sessions the user types in

    func list() -> [CodexProcess] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        // Room for processes started between the two calls.
        var table = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 64)
        size = table.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &table, &size, nil, 0) == 0 else { return [] }
        var found: [CodexProcess] = []
        var alive = Set<String>()
        for i in 0..<(size / MemoryLayout<kinfo_proc>.stride) {
            var p = table[i].kp_proc
            guard withUnsafeBytes(of: &p.p_comm, { memcmp($0.baseAddress, "codex", 6) == 0 }) else { continue }
            let born = p.p_un.__p_starttime, key = "\(p.p_pid) \(born.tv_sec).\(born.tv_usec)"
            alive.insert(key)
            if let process = known[key] {
                found.append(process)
            } else if !others.contains(key) {
                if let process = describe(p.p_pid, start: Double(born.tv_sec) + Double(born.tv_usec) / 1_000_000) {
                    known[key] = process
                    found.append(process)
                } else {
                    others.insert(key)
                }
            }
        }
        known = known.filter { alive.contains($0.key) }
        others = others.filter(alive.contains)
        return found
    }

    private func describe(_ pid: Int32, start: Double) -> CodexProcess? {
        guard let (args, env) = processArguments(pid), codexInteractive(args) else { return nil }
        // Orca puts the tab's handle and pane in the environment, read here already: `ps` need not be asked again.
        if let terminal = env["ORCA_TERMINAL_HANDLE"], !terminal.isEmpty {
            OrcaTabs.shared.learn(pid, terminal: terminal, pane: env["ORCA_PANE_KEY"] ?? "")
        }
        let codexHome = env["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.codex"
        return CodexProcess(pid: pid, start: start, home: codexHome)
    }
}

/// One of Codex's threads as its index has it: what a card needs.
struct CodexThread: Equatable {
    let id: String
    let rollout: String
    let cwd: String
    let title: String  // the first message, cut short by Codex
    let name: String?  // the one the user gave it
    let model: String?
    let created: Double
}

/// SQLite copies a bound string at once (its "transient" destructor), so the Swift string may go.
private let sqliteCopies = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A column of the row a statement is on, as text; nil for NULL.
func sqliteText(_ row: OpaquePointer, _ i: Int32) -> String? { sqlite3_column_text(row, i).map { String(cString: $0) } }

/// Another app's SQLite database, read without ever writing it or adding a file beside it. Each look opens it afresh,
/// read-only, runs one statement and closes: in WAL mode (Codex's, WorkBuddy's) a reader neither waits for the writer nor
/// holds it up, and no connection stays open across the app folding its log back or replacing its files.
///
/// A plain read-only connection still writes the -shm (its read marks), and makes one when only the -wal is there; so the
/// look asks for the -shm read-only (`readonly_shm`), and SQLite rebuilds what it needs in its own memory. With no -shm it
/// cannot read the -wal at all: with no -wal either (the app has closed the database, folded its log back and removed
/// both) or an empty one, the file alone holds everything, and the look takes it as it is (`immutable`), creating
/// nothing. A non-empty -wal with no -shm (left by a crash) is not read until the app opens the database again.
/// (Opening it read-write instead, as first thought of, would make a -wal and a -shm in the app's own folder.) Should the
/// app open the database and fold a log back in the moment between, that one look may read wrong or fail; the next tick
/// reads it right.
final class ReadOnlyDatabase {
    let path: String
    /// The last statement could not be made because a table or column it names is not there: the app's schema changed (not a
    /// lock, a busy log or a file being replaced, which say nothing of the format).
    private(set) var schemaMissing = false

    init?(_ path: String) {
        // Asked to open a database that is not there, SQLite would make one, in the app's folder: look first.
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        self.path = path
    }

    /// One statement's rows, each as `make` reads it (nil skips a row); nil when it could not be read: locked past the
    /// timeout, or unreadable.
    func rows<T>(_ sql: String, _ text: [String] = [], _ number: Int64? = nil, _ make: (OpaquePointer) -> T?) -> [T]? {
        guard let file = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        if let probe = dumpProbe {
            probe.begin(probe.sqliteStage, subject: nil)
            defer { probe.end() }
            return lookup(file, sql, text, number, make)
        }
        return lookup(file, sql, text, number, make)
    }

    private func lookup<T>(_ file: String, _ sql: String, _ text: [String], _ number: Int64?, _ make: (OpaquePointer) -> T?) -> [T]? {
        schemaMissing = false
        if let found = Self.look("file:" + file + "?mode=ro&readonly_shm=1", sql, text, number, make, &schemaMissing) { return found }
        guard (FileStamp(path + "-wal")?.size ?? 0) == 0 else { return nil }
        return Self.look("file:" + file + "?immutable=1", sql, text, number, make, &schemaMissing)
    }

    private static func look<T>(
        _ name: String, _ sql: String, _ text: [String], _ number: Int64?, _ make: (OpaquePointer) -> T?, _ schema: inout Bool
    ) -> [T]? {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(name, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let handle
        else { return nil }
        sqlite3_busy_timeout(handle, 20)
        return run(handle, sql, text, number, make, &schema)
    }

    private static func run<T>(
        _ db: OpaquePointer, _ sql: String, _ text: [String], _ number: Int64?, _ make: (OpaquePointer) -> T?, _ schema: inout Bool
    ) -> [T]? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let said = String(cString: sqlite3_errmsg(db))
            if said.hasPrefix("no such table") || said.hasPrefix("no such column") { schema = true }
            return nil
        }
        defer { sqlite3_finalize(statement) }
        for (i, value) in text.enumerated() { sqlite3_bind_text(statement, Int32(i + 1), value, -1, sqliteCopies) }
        if let number { sqlite3_bind_int64(statement, Int32(text.count + 1), number) }
        var found: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if let row = make(statement) { found.append(row) }
            case SQLITE_DONE: return found
            default: return nil
            }
        }
    }
}

/// Codex's index of its threads, <CODEX_HOME>/state_5.sqlite, read as `ReadOnlyDatabase` reads another app's database.
final class CodexThreads {
    private let db: ReadOnlyDatabase
    private static let columns = "SELECT id, rollout_path, cwd, title, name, model, created_at FROM threads "

    init?(home: String) {
        guard let db = ReadOnlyDatabase(home + "/state_5.sqlite") else { return nil }
        self.db = db
    }

    /// The last look found a table or column it names gone (`ReadOnlyDatabase.schemaMissing`).
    var schemaMissing: Bool { db.schemaMissing }

    /// What a look in the index found: the thread, none, or nothing to go by (locked past the timeout, or unreadable).
    enum Answer {
        case found(CodexThread), missing, failed
    }

    /// The thread a rollout belongs to: by its path, or by the thread id that ends its file's name, should the index spell
    /// the path another way.
    func thread(rollout path: String) -> Answer {
        guard let byPath = rows("WHERE rollout_path = ?1", [path]) else { return .failed }
        if let found = byPath.first { return .found(found) }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let id = String(name.suffix(36))
        guard name.count > 36, UUID(uuidString: id) != nil else { return .missing }
        guard let byID = rows("WHERE id = ?1", [id]) else { return .failed }
        return byID.first.map(Answer.found) ?? .missing
    }

    /// For a process with no rollout open: the newest of the terminal's own threads in its folder (not an exec run's, nor
    /// one an app or Claude Code's Codex plugin drives) that is not archived, was used since the process started, and is
    /// not `taken` by another process. An older one is another session's, or one the user left: a process that has said nothing
    /// yet has no thread, as Codex writes its rollout only with the first message.
    func thread(cwd: String, usedSince start: Double, besides taken: Set<String>) -> Answer {
        guard
            let found = rows(
                "WHERE archived = 0 AND source = 'cli' AND cwd = ?1 AND updated_at >= ?2 ORDER BY updated_at DESC LIMIT 16", [cwd], Int64(start))
        else { return .failed }
        return found.first { !taken.contains($0.id) }.map(Answer.found) ?? .missing
    }

    private func rows(_ clause: String, _ text: [String], _ number: Int64? = nil) -> [CodexThread]? {
        db.rows(Self.columns + clause, text, number) { row in
            guard let id = sqliteText(row, 0), let rollout = sqliteText(row, 1) else { return nil }
            return CodexThread(
                id: id, rollout: rollout, cwd: sqliteText(row, 2) ?? "", title: sqliteText(row, 3) ?? "", name: sqliteText(row, 4),
                model: sqliteText(row, 5), created: sqlite3_column_double(row, 6))
        }
    }
}

/// The Codex CLI sessions running now: for each interactive `codex` process, the thread it has open, as Codex's index and
/// the end of its rollout describe it. A process with no thread yet (started, nothing said) is not a session yet. None of
/// them has a transcript the panel knows, so no messages between sessions and no subagents are looked for.
final class CodexSessions {
    /// The processes to look at; a check gives its own.
    var processes: () -> [CodexProcess]
    /// A check's own say of which rollout a process has open, asked before the kernel is.
    var rollout: ((Int32) -> String?)?
    private var indexes: [String: CodexThreads] = [:]  // by CODEX_HOME
    private var open: [Int32: (fd: Int32, path: String)] = [:]  // the rollout each process had open at the last look
    private var listed: [Int32: Date] = [:]  // when a process with none open last had its files listed
    private var tails: [String: CodexTail] = [:]  // by rollout path
    private var models: [String: String] = [:]  // by thread id
    /// Each process's thread as last found, by pid and home: asked again when its rollout changes, and every 10 s for a
    /// name the user has given it since.
    private var threads: [String: (path: String?, thread: CodexThread, at: Date)] = [:]
    /// How long a thread found stays while its index cannot be read: a lock or a moment's failure should not make the card
    /// blink out and its rollout be read again from the start.
    static let keptWhileUnreadable: TimeInterval = 300
    /// The homes whose index was last found without a table or column it is read by, and what of the formats was not
    /// understood at the last look (`FormatWarning`).
    private var schemaGone = Set<String>()
    private(set) var formatMarks: FormatMarks = [:]

    init() {
        let running = CodexProcesses()
        processes = { running.list() }
    }

    /// The model a session's thread runs on, when its index says.
    func model(of id: String) -> String? { models[id] }

    func load(now: Date = Date()) -> [Session] {
        var out: [Session] = [], models: [String: String] = [:]
        var homes = Set<String>(), pids = Set<Int32>(), read = Set<String>(), looked = Set<String>(), oddRollouts = Set<String>()
        // Those with a rollout open first: each is that rollout's thread and nothing else, even while its row is not in the
        // index yet. Only then do the others (nothing said yet, or the rollout closed for a moment) take a thread from their
        // folder, and only one nobody holds: a pane just opened beside a working one must not take the working one's.
        var mapped: [(process: CodexProcess, thread: CodexThread, path: String?)] = [], rest: [CodexProcess] = []
        for p in processes() {
            pids.insert(p.pid)
            homes.insert(p.home)
            looked.insert("\(p.pid) \(p.home)")
            guard let path = rollout?(p.pid) ?? openRollout(of: p.pid, now: now) else {
                rest.append(p)
                continue
            }
            if let thread = thread(of: p, path: path, taken: [], now: now) { mapped.append((p, thread, path)) }
        }
        var taken = Set(mapped.map(\.thread.id))
        for p in rest {
            guard let thread = thread(of: p, path: nil, taken: taken, now: now) else { continue }
            taken.insert(thread.id)
            mapped.append((p, thread, nil))
        }
        for (p, thread, path) in mapped {
            let file = path ?? thread.rollout
            let tail = CodexTail.read(file, after: tails[file], now: now)
            tails[file] = tail
            read.insert(file)
            if let model = thread.model, !model.isEmpty { models[thread.id] = model }
            let cwd = thread.cwd.isEmpty ? processCwd(p.pid) ?? "" : thread.cwd
            var s = Session(
                id: thread.id, pid: p.pid, project: projectName(cwd), name: codexName(name: thread.name, title: thread.title),
                status: tail.status, since: tail.since ?? Date(timeIntervalSince1970: thread.created), summary: tail.summary)
            s.summaryLine = tail.summaryLine
            s.nameUntitled = codexGivenName(name: thread.name, title: thread.title) == nil
            s.cwd = cwd
            s.kind = "codex"
            if tail.unknownLines { oddRollouts.insert(thread.id) }
            out.append(s)
        }
        // What was kept for processes that have gone goes with them.
        schemaGone = schemaGone.filter(homes.contains)
        formatMarks = [:]
        if !oddRollouts.isEmpty { formatMarks[.codexRollout] = oddRollouts }
        if !schemaGone.isEmpty { formatMarks[.codexThreads] = [""] }
        indexes = indexes.filter { homes.contains($0.key) }
        open = open.filter { pids.contains($0.key) }
        listed = listed.filter { pids.contains($0.key) }
        threads = threads.filter { looked.contains($0.key) }
        tails = tails.filter { read.contains($0.key) }
        self.models = models
        return out
    }

    /// A process's thread: the one found within the last 10 s for the same rollout, else what its index says now: by its
    /// open rollout, or without one by its folder, among threads not `taken`. When the index cannot be read, the one found
    /// for the same rollout stays for up to 5 minutes.
    private func thread(of p: CodexProcess, path: String?, taken: Set<String>, now: Date) -> CodexThread? {
        let key = "\(p.pid) \(p.home)"
        let kept = threads[key].flatMap { $0.path == path && !taken.contains($0.thread.id) ? $0 : nil }
        if let kept, now.timeIntervalSince(kept.at) < 10 { return kept.thread }
        var answer = CodexThreads.Answer.failed
        if let index = indexes[p.home] ?? CodexThreads(home: p.home) {
            indexes[p.home] = index
            if let path {
                answer = index.thread(rollout: path)
            } else {
                answer = processCwd(p.pid).map { index.thread(cwd: $0, usedSince: p.start, besides: taken) } ?? .missing
            }
            if index.schemaMissing { schemaGone.insert(p.home) } else if case .failed = answer {} else { schemaGone.remove(p.home) }
        }
        switch answer {
        case .found(let thread):
            threads[key] = (path, thread, now)
            return thread
        case .missing:
            threads[key] = nil
            return nil
        case .failed:
            guard let kept, now.timeIntervalSince(kept.at) < Self.keptWhileUnreadable else {
                threads[key] = nil
                return nil
            }
            return kept.thread
        }
    }

    /// The rollout a process has open: the one it had at the last look while that descriptor still holds it (one call to
    /// the kernel), else from the list of all its open files. A process with none is listed again at most every 10 s;
    /// one whose rollout closed (a new thread: `/new`, or a resume) is listed at once.
    private func openRollout(of pid: Int32, now: Date) -> String? {
        if let known = open[pid] {
            if openFile(pid, known.fd) == known.path { return known.path }
            open[pid] = nil
        } else if let last = listed[pid], now.timeIntervalSince(last) < 10 {
            return nil
        }
        listed[pid] = now
        guard let found = codexOpenRollout(pid) else { return nil }
        open[pid] = found
        return found.path
    }
}

// ───────── The Codex desktop app and WorkBuddy ─────────
//
// Two apps with windows of their own keep their conversations in files of their own: the Codex desktop app (inside
// ChatGPT.app; ~/.codex, the same thread index and rollouts as the CLI) and WorkBuddy (Tencent's, on CodeBuddy;
// ~/.workbuddy). Neither runs a process per conversation, so "open" means: the app is running, and the
// conversation moved within the last 24 hours or is working or waiting now. With the app not running nothing of it is
// read. Both are the apps' internal formats as of Codex 26.1007 and WorkBuddy 5.7.7.

/// The user's home, by a name the sources' own `home` does not hide.
let panelHome = home

/// Off in the checks: the machine's own apps are never read there, only fixtures handed to sources of their own.
var appSessionsLive = true

/// The app's process while it runs.
func runningApp(_ bundle: String) -> Int32? {
    guard appSessionsLive else { return nil }
    return NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.processIdentifier
}

/// A file's size and modification time, to tell whether it changed since the last look; nil when it is not there.
struct FileStamp: Equatable {
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init?(_ path: String) {
        var file = stat()
        guard stat(path, &file) == 0 else { return nil }
        size = Int64(file.st_size)
        seconds = file.st_mtimespec.tv_sec
        nanoseconds = file.st_mtimespec.tv_nsec
    }
}

/// The Codex desktop app's threads: those its sidebar shows (`source = 'vscode'`; a `codex exec` run's are `exec`) that it
/// started itself (`originator = 'Codex Desktop'`: Claude Code's Codex plugin writes `vscode` threads into ~/.codex too)
/// or the Windows app did and they were moved here (`codex_work_desktop`; the app lists and carries on with them), newest 30,
/// each as its rollout's end and the turn table describe it. One card per thread; their pid is the app's.
final class CodexAppSessions {
    static let bundle = "com.openai.codex"
    /// For a run that looks once and goes (`--dump`, `--jump`, `--snapshot`): it reads each rollout at once, there being no
    /// next tick to wait for.
    static var firstReadsInline = false
    let home: String
    /// The app's pid while it runs; a check gives its own.
    var running: () -> Int32? = { runningApp(CodexAppSessions.bundle) }
    /// How long a thread that has done nothing since stays.
    var recent: TimeInterval = 86_400
    /// How many times it has looked at a file: a check sees that it looks at nothing while the app is not running.
    private(set) var touched = 0
    /// Whether a rollout not read before is read there and then, rather than off the main thread.
    var readsFirstInline = CodexAppSessions.firstReadsInline

    private struct Row {
        let id: String, rollout: String, cwd: String, title: String, name: String?, model: String?, active: Double
    }
    private var indexStamps: [FileStamp?]?
    private var turnStamps: [FileStamp?]?
    private var rows: [Row] = []
    /// Threads whose latest turn the turn table has as running, and since when (seconds).
    private var turnsRunning: [String: Double] = [:]
    private var tails: [String: CodexTail] = [:]  // by rollout path
    private var models: [String: String] = [:]
    /// The index and the turn table were last found without a table or column they are read by; what of the formats was not
    /// understood at the last look (`FormatWarning`).
    private var indexSchemaGone = false, turnsSchemaGone = false
    private(set) var formatMarks: FormatMarks = [:]
    /// A rollout's first look, off the main thread: a thread's can run to tens of megabytes, and the app's thirty all at once
    /// when it or the panel starts. Until it is done the thread shows as idle with nothing to say; the next tick takes it.
    private let firstReads = DispatchQueue(label: "codex-app.first-reads", qos: .utility)
    private let lock = NSLock()
    private var reading = Set<String>()
    private var read: [String: CodexTail] = [:]

    init(home: String = panelHome + "/.codex") { self.home = home }

    func model(of id: String) -> String? { models[id] }

    /// How many first looks are still under way.
    var firstReadsPending: Int {
        lock.lock()
        defer { lock.unlock() }
        return reading.count
    }

    func load(now: Date = Date()) -> [Session] {
        guard let pid = dumpStage("runningApp", running) else {
            // What was kept goes with the app.
            indexStamps = nil
            turnStamps = nil
            rows = []
            turnsRunning = [:]
            tails = [:]
            models = [:]
            (indexSchemaGone, turnsSchemaGone, formatMarks) = (false, false, [:])
            lock.lock()
            read = [:]
            lock.unlock()
            return []
        }
        // Each database is asked again only when it or its log changed.
        let indexPath = home + "/state_5.sqlite", turnsPath = home + "/thread_history_1.sqlite"
        let indexNow = [FileStamp(indexPath), FileStamp(indexPath + "-wal")]
        touched += 2
        if indexNow != indexStamps, let index = ReadOnlyDatabase(indexPath) {
            let found = index.rows(Self.columns, [], nil, Self.row)
            if found != nil || index.schemaMissing { indexSchemaGone = index.schemaMissing }
            if let found {
                rows = found
                indexStamps = indexNow
            }
        }
        let turnsNow = [FileStamp(turnsPath), FileStamp(turnsPath + "-wal")]
        touched += 2
        if turnsNow != turnStamps, let turns = ReadOnlyDatabase(turnsPath) {
            let found = turns.rows(Self.runningTurns, [], nil, { row -> (String, Double)? in
                sqliteText(row, 0).map { ($0, sqlite3_column_double(row, 1)) }
            })
            if found != nil || turns.schemaMissing { turnsSchemaGone = turns.schemaMissing }
            if let found {
                turnsRunning = Dictionary(found, uniquingKeysWith: { first, _ in first })
                turnStamps = turnsNow
            }
        }
        var out: [Session] = [], kept = Set<String>(), models: [String: String] = [:], oddRollouts = Set<String>()
        for t in rows {
            // Before any rollout is read: moved within the window, or a turn running by the turn table. (A card left
            // unanswered for longer than the window goes with it; so does a turn a crash left running.)
            let start = turnsRunning[t.id].flatMap { now.timeIntervalSince1970 - $0 < recent ? $0 : nil }
            guard now.timeIntervalSince1970 - t.active < recent || start != nil else { continue }
            kept.insert(t.rollout)
            let tail = tail(of: t.rollout, now: now)
            var status = tail?.status ?? "idle", waitingFor = "", line = tail?.summaryLine ?? .empty
            var since = tail?.since ?? Date(timeIntervalSince1970: t.active)
            // The turn table has a turn running that the rollout has not shown yet (a long answer is written only once it
            // is whole): it runs. Not one older than what the rollout last said.
            if tail?.busy != true, let start, start >= (tail?.since?.timeIntervalSince1970.rounded(.down) ?? 0) {
                status = "busy"
                since = Date(timeIntervalSince1970: start)
            }
            if let tail, let wait = Self.waitLine(tail, busy: status == "busy") {
                status = "waiting"
                waitingFor = wait.waitingFor
                line = wait.line
                since = wait.since
            }
            if let model = t.model, !model.isEmpty { models[t.id] = model }
            var s = Session(
                id: t.id, pid: pid, project: projectName(t.cwd), name: codexName(name: t.name, title: t.title), status: status,
                since: since, summary: line.rendered)
            s.summaryLine = line
            s.nameUntitled = codexGivenName(name: t.name, title: t.title) == nil
            s.waitingFor = waitingFor
            s.cwd = t.cwd
            s.kind = "codexApp"
            if tail?.unknownLines == true { oddRollouts.insert(t.id) }
            out.append(s)
        }
        formatMarks = [:]
        if !oddRollouts.isEmpty { formatMarks[.codexRollout] = oddRollouts }
        if indexSchemaGone { formatMarks[.codexThreads] = [""] }
        if turnsSchemaGone { formatMarks[.codexTurns] = [""] }
        tails = tails.filter { kept.contains($0.key) }
        self.models = models
        return out
    }

    /// Where a thread's rollout stands: what is new in it since the last look, read here (a few KB a tick, at most every
    /// 10 s while busy); the first look handed to a background read, nil until that is done.
    private func tail(of path: String, now: Date) -> CodexTail? {
        touched += 1
        var previous = tails[path]
        if previous == nil && !readsFirstInline {
            lock.lock()
            let done = read.removeValue(forKey: path), started = reading.contains(path)
            if done == nil && !started { reading.insert(path) }
            lock.unlock()
            guard let done else {
                if !started {
                    firstReads.async { [self] in
                        let first = CodexTail.read(path, after: nil, now: Date(), app: true)
                        lock.lock()
                        read[path] = first
                        reading.remove(path)
                        lock.unlock()
                    }
                }
                return nil
            }
            previous = done
        }
        let tail = CodexTail.read(path, after: previous, now: now, app: true)  // catches up on what came since a first look
        tails[path] = tail
        return tail
    }

    /// What a thread waits on the user for, apart from how its turn stands: an approval its running turn asked for (the turn stands
    /// still until the user answers, so it is waiting, not busy); else, with no turn running, a question card the user has not answered.
    /// A card counts only until a later turn starts, whatever started it: the user may type instead of choosing.
    static func waits(_ tail: CodexTail, busy: Bool) -> (waitingFor: String, ask: String, since: Date)? {
        waitLine(tail, busy: busy).map { ($0.waitingFor, $0.line.rendered, $0.since) }
    }

    /// `waits` with what it asks as a code and its arguments.
    static func waitLine(_ tail: CodexTail, busy: Bool) -> (waitingFor: String, line: SummaryLine, since: Date)? {
        if let asked = tail.approvals.values.min() { return ("permission prompt", .approve, asked) }
        guard !busy else { return nil }
        let open = tail.questions.values.sorted { $0.at < $1.at }
        guard let first = open.first else { return nil }
        return ("input needed", .ask(question: firstLine(first.title), count: open.count), first.at)
    }

    private static let columns = """
        SELECT id, rollout_path, cwd, title, name, model, reasoning_effort, MAX(COALESCE(updated_at_ms, 0), recency_at_ms)
        FROM threads WHERE source = 'vscode' AND originator IN ('Codex Desktop', 'codex_work_desktop') AND archived = 0
        ORDER BY recency_at_ms DESC LIMIT 30
        """
    /// Each thread's latest turn, when the table has it running.
    private static let runningTurns = """
        SELECT t.thread_id, t.started_at FROM thread_turns t WHERE t.status = 'inProgress'
        AND t.rollout_ordinal = (SELECT MAX(rollout_ordinal) FROM thread_turns WHERE thread_id = t.thread_id)
        """

    private static func row(_ row: OpaquePointer) -> Row? {
        guard let id = sqliteText(row, 0), let rollout = sqliteText(row, 1) else { return nil }
        // The model with how hard it reasons, as a subagent's is shown: "gpt-6.1-sol · low".
        let effort = sqliteText(row, 6).flatMap { $0.isEmpty ? nil : $0 }
        let model = sqliteText(row, 5).map { model in effort.map { model + " · " + $0 } ?? model }
        return Row(
            id: id, rollout: rollout, cwd: sqliteText(row, 2) ?? "", title: sqliteText(row, 3) ?? "", name: sqliteText(row, 4), model: model,
            active: sqlite3_column_double(row, 7) / 1000)
    }
}
