import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

final class Loader {
    private var paths: [String: String] = [:]  // session id -> transcript path
    private var tails: [String: TailInfo] = [:]
    private var bgScans: [String: BGScan] = [:]  // session id -> its transcript as far as read for its background tasks
    private let bgCachePath: String
    private var bgLoaded = false  // the file has been read (at the first look)
    private var bgDirty = false  // what is kept differs from the file
    /// Session id -> the moment (epoch seconds) its process was first found dead with its registry file left; kept in a
    /// file (`gone.json` in the caches folder) because every `--dump` is a process of its own.
    private var gone: [String: GoneEntry] = [:]
    private let goneCachePath: String
    private var lastIndexed = Date.distantPast
    private let registry: String
    private let codex: CodexSessions
    private let codexApp: CodexAppSessions
    private let workbuddy: WorkBuddySessions
    private let restartList: String
    /// Each Claude Code session as last read from its own file, never from a restart: what a restart goes on showing.
    private var lastKnown: [String: Session] = [:]
    /// Those shown as restarting at the last look.
    private var held = Set<String>()
    /// Restarted idle and back idle: the `since` it had before (`kept`), held while its new file still says the moment
    /// the new process started (`stamp`). Any other moment, or any other state, is a turn of its own.
    /// Restarted from idle: the `since` it had before (`kept`) and its last reply then (`reply`). Shown with `kept` while
    /// it stays idle with no new reply, however often its new process rewrites its file (it does, a second after
    /// starting). Busy before it is first back idle is its start-up; busy after that, waiting, or a new reply is a
    /// turn of its own and ends it.
    private var keptSince: [String: (kept: Date, reply: String, idleSeen: Bool)] = [:]
    /// Each Claude Code session's last reply stamp, as last read while it was not being restarted.
    private var lastReply: [String: String] = [:]
    /// What of the formats read was not understood at the last look, from every source this reads (`FormatWarning`), and what
    /// the log has been told of it.
    private(set) var formatMarks: FormatMarks = [:]
    private var formatTold = FormatLog()
    /// Where a format warning's coming and going is told (panel.log); a check catches it. Not in a `--dump`, a process each 3 s.
    var formatNote: (String) -> Void = { log($0) }

    /// Where Claude Code's registry is, and the other sources; a check gives its own.
    init(
        registry: String = registryDir, codex: CodexSessions = CodexSessions(), codexApp: CodexAppSessions = CodexAppSessions(),
        workbuddy: WorkBuddySessions = WorkBuddySessions(), restarting: String = restartingFile, bgCache: String = defaultBGCache,
        goneCache: String = defaultGoneCache
    ) {
        self.bgCachePath = bgCache
        self.goneCachePath = goneCache
        self.registry = registry
        self.restartList = restarting
        self.codex = codex
        self.codexApp = codexApp
        self.workbuddy = workbuddy
    }

    /// Whether a process is a one-off print of a forked copy (`claude -p --resume <id> --fork-session …`): the phone's
    /// context view runs one for a few seconds, under the same name as the session it copies. Nobody's session. By pid, as
    /// its arguments never change.
    private var forks: [Int32: Bool] = [:]
    private func isFork(_ pid: Int32) -> Bool {
        if let known = forks[pid] { return known }
        let args = processArguments(pid)?.args ?? []
        let fork = args.contains("--fork-session") && (args.contains("-p") || args.contains("--print"))
        forks[pid] = fork
        return fork
    }

    func load(now: Date = Date()) -> [Session] {
        let fm = FileManager.default
        var out: [Session] = []
        var replies: [String: String] = [:]
        var entries: [(o: [String: Any], pid: Int32, sid: String)] = [], alive = Set<Int32>()
        var dead: [(o: [String: Any], pid: Int32, sid: String)] = []
        // A registry file that reads as JSON but lacks what a card is made of: Claude Code's registry format changed. One that
        // does not read (being written, empty) is no sign.
        var registryOdd = false, transcriptOdd = Set<String>()
        dumpProbe?.begin("registry", subject: nil)
        for file in (try? fm.contentsOfDirectory(atPath: registry)) ?? [] where file.hasSuffix(".json") {
            guard let data = fm.contents(atPath: registry + "/" + file),
                let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { continue }
            if !(o["cwd"] is String) { registryOdd = true }  // the card's project and folder; the session is still shown
            guard let pidNumber = o["pid"] as? Int, let sid = o["sessionId"] as? String else {
                registryOdd = true
                continue
            }
            let pid = Int32(pidNumber)
            if kill(pid, 0) != 0 && errno == ESRCH {  // left behind by a dead process: shown as gone if it did not leave by itself
                dead.append((o, pid, sid))
                continue
            }
            alive.insert(pid)
            if isFork(pid) { continue }
            entries.append((o, pid, sid))
        }
        dumpProbe?.end()
        forks = forks.filter { alive.contains($0.key) }  // a pid comes round again for another process
        // Claude Code's background copies: a session handed to one (`parkedJobId`) stops where it was, busy,
        // while the copy (`kind` bg, `jobId` the same) carries on under the same name: only the copy is shown, the original
        // again once the copy is gone. A spare background process (`spare`) is nobody's session.
        let jobs = Set(entries.compactMap { $0.o["jobId"] as? String })
        for (o, pid, sid) in entries {
            if (o["kind"] as? String) == "bg", (o["spare"] as? Bool) == true { continue }
            if let parked = o["parkedJobId"] as? String, !parked.isEmpty, (o["jobId"] as? String) != parked, jobs.contains(parked) { continue }
            let rawStatus = o["status"] as? String ?? "idle"
            var status = ["waiting", "busy"].contains(rawStatus) ? rawStatus : "idle"
            let ms = (o["statusUpdatedAt"] as? Double) ?? (o["updatedAt"] as? Double) ?? (o["startedAt"] as? Double) ?? 0
            var tail = tailInfo(for: sid, status: status), staleWait = false
            // Claude Code's file can be left saying waiting after the session went on (a peer's message held for the
            // user's approval, approved, the turn run, the file never written again): lines of its own written more than
            // 5 s after that status say it is not waiting; busy while the transcript is still being written, else idle.
            if status == "waiting", let last = Self.stampDate(tail.lastTurnStamp), last.timeIntervalSince1970 * 1000 > ms + 5000 {
                status = now.timeIntervalSince(tail.mtime) < Self.staleWaitBusyFor ? "busy" : "idle"
                staleWait = true
                tail = tailInfo(for: sid, status: status)
            }
            replies[sid] = tail.replyStamp
            if tail.unknownLines { transcriptOdd.insert(sid) }
            let registryName = o["name"] as? String
            let userNamed = (o["nameSource"] as? String) == "user"
            let cwd = o["cwd"] as? String ?? ""
            let named = (userNamed ? registryName : nil) ?? tail.customTitle ?? tail.aiTitle ?? registryName
            let line = status == "waiting" && !tail.pending.isEmpty ? tail.pendingLine ?? tail.summaryLine : tail.summaryLine
            let bg = bgState(sid: sid, pid: pid)
            var session =
                Session(
                    id: sid, pid: pid, project: projectName(cwd),
                    name: named ?? "未命名",
                    status: status, since: idleSince(Date(timeIntervalSince1970: ms / 1000), status: status, reply: tail.replyStamp),
                    summary: line.rendered,
                    waitingFor: staleWait ? "" : o["waitingFor"] as? String ?? "", registryName: registryName ?? "", cwd: cwd,
                    tool: status == "busy" ? tail.tool : "", origin: tail.origin, peer: tail.peer, model: tail.model,
                    summaryLine: line, nameUntitled: named == nil)
            (session.bgTasks, session.bgAgents, session.bgSince, session.bgStale) = (bg.tasks, bg.agents, bg.since, bg.stale(now: now))
            (session.bgEndedAt, session.bgOwned, session.bgList) = (bg.endedAt, bg.owned, bg.list)
            (session.errorKind, session.errorStatus, session.errorText, session.errorSince) = (tail.errorKind, tail.errorStatus, tail.errorText, tail.errorSince)
            (session.retryAttempt, session.retryMax, session.compactedAt) = (tail.retryAttempt, tail.retryMax, tail.compactedAt)
            out.append(session)
        }
        bgKeep(only: Set(entries.map { $0.sid }))  // one closed is read afresh if it comes back
        // Read after the registry: an entry is written before the old process goes, so a session whose file is already
        // gone is always found listed here.
        let listed = dumpStage("restartList") { Self.restarting(in: restartList, now: now) }
        out = holdRestarting(out, listed: listed, replies: replies)
        out += disconnected(dead, among: out, listed: listed, now: now)
        // Codex CLI has no registry: its sessions are its interactive processes. The two apps have their own stores.
        out += dumpStage("codexCLI") { codex.load() }
        out += dumpStage("codexApp") { codexApp.load() }
        out += dumpStage("workbuddy") { workbuddy.load() }
        var claudeMarks: FormatMarks = [:]
        if registryOdd { claudeMarks[.claudeRegistry] = [""] }
        if !transcriptOdd.isEmpty { claudeMarks[.claudeTranscript] = transcriptOdd }
        formatMarks = mergeFormatMarks([claudeMarks, codex.formatMarks, codexApp.formatMarks, workbuddy.formatMarks])
        if dumpProbe == nil { formatTold.take(Set(formatMarks.keys)).forEach(formatNote) }
        // One card per session, even if the same session is open in two terminals.
        var ids = Set<String>()
        return out.sorted { $0.id < $1.id }.filter { ids.insert($0.id).inserted }
    }

    /// The sessions whose process is dead while their registry file was left behind: Claude Code removes the file when
    /// it leaves by itself (`/exit`, a restart, window swap), so one left behind did not. But a file left behind is cleaned away by
    /// another running Claude Code within seconds, so the card cannot hang on it. The first time such a session is seen (and
    /// would be listed: not on the restart list, no other session of its name, none of its id alive) its row is kept in
    /// `gone.json`, whole, and the card is made from that row for `disconnectedShown` after, file or no file: idle,
    /// `disconnected`, since the moment it was first found. A same-named session or one of its id coming alive drops the row
    /// at once (window swap, resumed); at the end of the time the row goes but a bare mark stays while the dead file does, so that
    /// the file seen again does not make a second card. `gone.json` is read at every look and written when it changed (the
    /// panel and every `--dump` share it); the checks, with no path, keep it in memory.
    private func disconnected(_ dead: [(o: [String: Any], pid: Int32, sid: String)], among live: [Session], listed: Set<String>, now: Date) -> [Session] {
        var book = goneCachePath.isEmpty ? gone : dumpStage("goneRead") { Self.decodeGone(FileManager.default.contents(atPath: goneCachePath)) }
        let before = book
        let at = now.timeIntervalSince1970
        let liveIDs = Set(live.map(\.id))
        func renamed(_ name: String, _ sid: String) -> Bool { !name.isEmpty && live.contains { $0.registryName == name && $0.id != sid } }
        var present = Set<String>()
        for (o, pid, sid) in dead {
            present.insert(sid)
            let registryName = o["name"] as? String ?? ""
            if book[sid] != nil || (o["kind"] as? String) == "bg" && (o["spare"] as? Bool) == true { continue }
            if listed.contains(sid) || liveIDs.contains(sid) || renamed(registryName, sid) { continue }
            let tail = tailInfo(for: sid, status: "idle")
            let cwd = o["cwd"] as? String ?? ""
            let given = (o["nameSource"] as? String) == "user" ? o["name"] as? String : nil
            let named = given ?? tail.customTitle ?? tail.aiTitle ?? o["name"] as? String
            book[sid] = GoneEntry(at: at, row: GoneRow(
                pid: pid, name: named ?? "未命名", project: projectName(cwd), cwd: cwd, kind: "claude", model: tail.model,
                registryName: registryName, nameUntitled: named == nil, origin: tail.origin, peer: tail.peer))
        }
        var shown: [Session] = []
        for (sid, entry) in book {
            guard let row = entry.row else {
                if !present.contains(sid) { book[sid] = nil }  // the bare mark goes with its file
                continue
            }
            if liveIDs.contains(sid) || renamed(row.registryName, sid) || listed.contains(sid) {
                book[sid] = nil
            } else if at - entry.at >= disconnectedShown {
                book[sid] = present.contains(sid) ? GoneEntry(at: entry.at, row: nil) : nil
            } else {
                var session = Session(
                    id: sid, pid: row.pid, project: row.project, name: row.name, status: "idle", since: Date(timeIntervalSince1970: entry.at),
                    summary: SummaryLine.disconnected.rendered, registryName: row.registryName, cwd: row.cwd, kind: row.kind,
                    origin: row.origin, peer: row.peer, model: row.model, summaryLine: .disconnected, nameUntitled: row.nameUntitled)
                (session.disconnected, session.disconnectedSince) = (true, Date(timeIntervalSince1970: entry.at))
                shown.append(session)
            }
        }
        gone = book
        if book != before, !goneCachePath.isEmpty {
            dumpStage("goneWrite") {
                let fm = FileManager.default
                try? fm.createDirectory(atPath: (goneCachePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                let scratch = goneCachePath + ".\(getpid()).tmp"
                if (try? Self.encodeGone(book).write(to: URL(fileURLWithPath: scratch))) == nil || rename(scratch, goneCachePath) != 0 { try? fm.removeItem(atPath: scratch) }
            }
        }
        return shown
    }

    struct GoneRow: Equatable {
        var pid: Int32
        var name, project, cwd, kind, model, registryName: String
        var nameUntitled: Bool
        var origin, peer: String
    }
    /// When a dead session was first found, and its row for the card; no row: only the mark that it has had its time.
    struct GoneEntry: Equatable {
        var at: Double
        var row: GoneRow?
    }

    static func encodeGone(_ book: [String: GoneEntry]) throws -> Data {
        let sessions = book.mapValues { e -> [String: Any] in
            var o: [String: Any] = ["at": e.at]
            if let r = e.row {
                o["row"] = ["pid": Int(r.pid), "name": r.name, "project": r.project, "cwd": r.cwd, "kind": r.kind, "model": r.model,
                    "registryName": r.registryName, "nameUntitled": r.nameUntitled, "origin": r.origin, "peer": r.peer] as [String: Any]
            }
            return o
        }
        return try JSONSerialization.data(withJSONObject: ["version": 2, "sessions": sessions] as [String: Any], options: [.sortedKeys])
    }

    /// `gone.json` as read (version 2); nothing for a file missing, unreadable, of another version or not of this shape. An
    /// entry that is not whole is let go on its own.
    static func decodeGone(_ data: Data?) -> [String: GoneEntry] {
        guard let data, let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], (o["version"] as? Int) == 2,
            let sessions = o["sessions"] as? [String: Any]
        else { return [:] }
        return sessions.compactMapValues { value -> GoneEntry? in
            guard let e = value as? [String: Any], let at = e["at"] as? Double else { return nil }
            guard let r = e["row"] else { return GoneEntry(at: at, row: nil) }
            guard let r = r as? [String: Any], let pid = r["pid"] as? Int, let name = r["name"] as? String, let project = r["project"] as? String,
                let cwd = r["cwd"] as? String, let kind = r["kind"] as? String, let model = r["model"] as? String,
                let registryName = r["registryName"] as? String, let untitled = r["nameUntitled"] as? Bool,
                let origin = r["origin"] as? String, let peer = r["peer"] as? String
            else { return nil }
            return GoneEntry(at: at, row: GoneRow(pid: Int32(pid), name: name, project: project, cwd: cwd, kind: kind, model: model,
                registryName: registryName, nameUntitled: untitled, origin: origin, peer: peer))
        }
    }

    /// When an idle session last had something new to read: its file's moment, unless its last reply is older than that
    /// by more than a minute. A restart, a resume or a rename rewrites the file with a new moment and no new reply
    /// (a restart script's rounds would otherwise leave every restarted session under Has news); the reply says what is new.
    func idleSince(_ fileSince: Date, status: String, reply: String) -> Date {
        guard status == "idle", let at = Self.stampFormat.date(from: reply) ?? Self.plainStampFormat.date(from: reply),
            at < fileSince.addingTimeInterval(-60)
        else { return fileSince }
        return at
    }
    private static let stampFormat: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plainStampFormat = ISO8601DateFormatter()
    /// A transcript's timestamp as a moment.
    /// A transcript line's "timestamp" without decoding the line (tool lines can be hundreds of KB).
    static func stamp(of line: Data) -> String? {
        guard let key = line.range(of: Data(#""timestamp":""#.utf8)) else { return nil }
        let rest = line[key.upperBound...]
        guard let end = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<end], as: UTF8.self)
    }

    /// A waiting status found stale (see `load`) is busy while its transcript was written this recently, else idle.
    static let staleWaitBusyFor: TimeInterval = 120

    static func stampDate(_ stamp: String) -> Date? { stampFormat.date(from: stamp) ?? plainStampFormat.date(from: stamp) }

    /// The ids the restart script says it is restarting, each believed for `restartTrust` after its restart began. No
    /// list, an unreadable one or an entry without its time: nobody.
    static func restarting(in path: String, now: Date) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path),
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let entries = o["sessions"] as? [[String: Any]]
        else { return [] }
        var ids = Set<String>()
        for entry in entries {
            guard let id = entry["sessionId"] as? String, let since = entry["since"] as? Double else { continue }
            if now.timeIntervalSince1970 - since / 1000 <= restartTrust { ids.insert(id) }
        }
        return ids
    }

    /// Claude Code's sessions as they are to be shown while some are restarted: one listed that the panel has seen a
    /// file of is shown as it was last read, whatever its files say now (gone, its old pid dead, a new one already
    /// written); one back idle from a restart keeps the `since` it had, so that coming back is not news.
    private func holdRestarting(_ read: [Session], listed: Set<String>, replies: [String: String] = [:]) -> [Session] {
        var holding = Set<String>()
        for id in listed where lastKnown[id] != nil { holding.insert(id) }
        var shown: [Session] = []
        var seen: [String: Session] = [:]
        for fresh in read where !holding.contains(fresh.id) {
            var s = fresh
            let reply = replies[s.id] ?? ""
            if held.contains(s.id), let before = lastKnown[s.id], before.status == "idle", s.since > before.since {
                keptSince[s.id] = (kept: before.since, reply: lastReply[s.id] ?? reply, idleSeen: false)
            }
            if let k = keptSince[s.id] {
                if k.reply != reply {
                    keptSince[s.id] = nil
                } else if s.status == "idle" {
                    s.since = k.kept
                    keptSince[s.id] = (kept: k.kept, reply: k.reply, idleSeen: true)
                } else if !(s.status == "busy" && !k.idleSeen) {
                    keptSince[s.id] = nil
                }
            }
            lastReply[s.id] = reply
            shown.append(s)
            seen[s.id] = s
        }
        // window swap (`--fresh`): the new window has a new id under the same name. Once it is listed, the old one is not coming
        // back and is let go at once; held on, it kept the name's pet and the new window drew another.
        for id in holding.sorted() {
            guard var s = lastKnown[id] else { continue }
            if !s.registryName.isEmpty, read.contains(where: { $0.id != id && $0.registryName == s.registryName }) { continue }
            s.restarting = true
            (s.bgTasks, s.bgAgents, s.bgSince, s.bgStale, s.bgEndedAt, s.bgOwned, s.bgList) = (0, 0, nil, false, nil, false, [])  // its process is going, and what ran in it with it
            shown.append(s)
            seen[id] = lastKnown[id]
        }
        // Only those here now: one closed is gone for good, and a listing that comes later is ignored.
        lastKnown = seen
        held = holding
        keptSince = keptSince.filter { seen[$0.key] != nil }
        lastReply = lastReply.filter { seen[$0.key] != nil }
        return shown
    }

    /// A row's format warnings (`--dump`'s `formatWarnings`): its source's from the last look, and Orca's.
    func formatWarnings(for s: Session) -> [FormatWarning] {
        var marks = formatMarks
        for w in OrcaFormat.shared.warnings { marks[w] = [""] }
        return rowFormatWarnings(marks, for: s)
    }

    /// Every warning standing, for the title bar's dot: those of the last look, and Orca's.
    var formatWarnings: [FormatWarning] { Set(formatMarks.keys).union(OrcaFormat.shared.warnings).sorted() }

    func transcript(of sid: String) -> String? { paths[sid] }
    /// For checks: where a session's transcript is, without looking through Claude Code's projects folder.
    func remember(transcript path: String, for sid: String) { paths[sid] = path }

    /// The model a session runs on: a Codex or WorkBuddy one's as its store says, a Claude Code one's as its last reply
    /// named it; nil when nothing has said.
    func model(of sid: String) -> String? {
        codex.model(of: sid) ?? codexApp.model(of: sid) ?? workbuddy.model(of: sid) ?? tails[sid].flatMap { $0.model.isEmpty ? nil : $0.model }
    }

    /// What a session has running in the background: none for one whose process is gone (its tasks went with it, the
    /// subagents ran inside it), else as its transcript says, read from where the last look stopped.
    func bgState(sid: String, pid: Int32) -> BGState {
        if !bgLoaded {
            bgLoaded = true
            if !bgCachePath.isEmpty { bgScans = dumpStage("bgCacheRead") { BGScan.decode(FileManager.default.contents(atPath: bgCachePath)) } }
        }
        if kill(pid, 0) != 0 && errno == ESRCH {
            if bgScans.removeValue(forKey: sid) != nil { bgDirty = true }
            return .none
        }
        guard let path = transcriptPath(sid) else { return bgScans[sid]?.state ?? .none }
        if let probe = dumpProbe {
            let before = bgBytesRead
            probe.begin("bgScan", subject: sid)
            if bgScans[sid, default: BGScan()].advance(path: path) { bgDirty = true }
            probe.end(detail: Int(bgBytesRead - before))
        } else if bgScans[sid, default: BGScan()].advance(path: path) {
            bgDirty = true
        }
        return bgScans[sid]?.state ?? .none
    }

    /// Those of sessions no longer in the registry are let go, and the file is written again if anything changed: to a
    /// scratch file of this process first, then renamed over it, so that no one ever reads half of it.
    private func bgKeep(only live: Set<String>) {
        if !bgScans.keys.allSatisfy(live.contains) {
            bgScans = bgScans.filter { live.contains($0.key) }
            bgDirty = true
        }
        guard bgDirty, bgLoaded, !bgCachePath.isEmpty else { return }
        bgDirty = false
        dumpStage("bgCacheWrite") {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: (bgCachePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            let scratch = bgCachePath + ".\(getpid()).tmp"
            if (try? BGScan.encode(bgScans).write(to: URL(fileURLWithPath: scratch))) != nil, rename(scratch, bgCachePath) == 0 { return }
            try? fm.removeItem(atPath: scratch)
        }
    }

    private func transcriptPath(_ sid: String) -> String? {
        if let known = paths[sid] { return known }
        guard Date().timeIntervalSince(lastIndexed) > 10 else { return nil }
        lastIndexed = Date()
        let fm = FileManager.default
        dumpProbe?.begin("transcriptIndex", subject: nil)
        for dir in (try? fm.contentsOfDirectory(atPath: transcriptsDir)) ?? [] {
            for file in (try? fm.contentsOfDirectory(atPath: transcriptsDir + "/" + dir)) ?? [] where file.hasSuffix(".jsonl") {
                paths[String(file.dropLast(6))] = transcriptsDir + "/" + dir + "/" + file
            }
        }
        dumpProbe?.count("indexFiles", paths.count)
        dumpProbe?.end()
        return paths[sid]
    }

    private func tailInfo(for sid: String, status: String) -> TailInfo {
        guard let probe = dumpProbe else { return readTail(for: sid, status: status) }
        probe.begin("tailInfo", subject: sid)
        let info = readTail(for: sid, status: status)
        probe.count("sessions")
        probe.end(detail: Int(tails[sid]?.size ?? 0))
        return info
    }

    private func readTail(for sid: String, status: String) -> TailInfo {
        guard let path = transcriptPath(sid),
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            let size = (attrs[.size] as? NSNumber)?.uint64Value,
            let mtime = attrs[.modificationDate] as? Date
        else { return tails[sid] ?? TailInfo() }
        if let cached = tails[sid] {
            if cached.size == size && cached.mtime == mtime && cached.status == status { return cached }
            // A working session appends constantly; re-reading it every 2 s costs real CPU.
            // Catch up at once when it stops, otherwise at most every 10 s.
            if cached.status == status && status == "busy" && Date().timeIntervalSince(cached.parsedAt) < 10 {
                return cached
            }
        }

        var info = TailInfo(
            size: size, mtime: mtime, customTitle: tails[sid]?.customTitle, aiTitle: tails[sid]?.aiTitle,
            status: status, parsedAt: Date(), model: tails[sid]?.model ?? "")
        guard let handle = FileHandle(forReadingAtPath: path) else { return info }
        defer { try? handle.close() }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        let tail = (try? handle.readToEnd()) ?? Data()

        var recap: (String, String)?
        var reply: (String, String)?
        var asked: (String, String)?
        var lastToolUse: (Int, Data)?
        var lastToolResult = -1
        var origin: (origin: String, peer: String) = ("user", "")
        var foreign: (stamp: String, origin: String, peer: String)?  // the latest peer or agent turn
        // Lines are told apart by their numbers. The last API error, and what came after it: a reply of its own that is
        // not an error (an assistant line, even one that is a tool call), a prompt the user typed; the last retry's note, and the
        // last assistant or user line of the session's own; the moment compaction last finished.
        var apiError: (line: Int, stamp: String, error: String, status: Int?, text: String)?
        var normalAssistantLine = -1, askedLine = -1, lastTurnLine = -1
        var lastTurn: Data?
        var retry: (line: Int, attempt: Int, max: Int)?
        var compacted: Date?
        // The format's verdict (`FormatCensus`): the first line is cut when the read began inside the file, the last still being
        // written when the tail has no newline at its end. Each line is held one step, so that the last is known to be the last.
        var census = FormatCensus()
        var held: Bool?  // the line before: whether of a kind known; nil for one not counted
        let cutFirst = size > tailBytes, openLast = tail.last.map { $0 != 0x0A } ?? false
        forEachLine(of: tail) { number, line in
            if let h = held { census.whole += 1; if h { census.known += 1 } }
            held = cutFirst && number == 0 ? nil : census.known == 0 && held != true && claudeLineKinds.contains { $0.isIn(line) }
            if Phrase.apiRetry.isIn(line) || Phrase.compacted.isIn(line),
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any], (o["type"] as? String) == "system",
                ["api_error", "compact_boundary"].contains(o["subtype"] as? String)
            {
                if (o["isSidechain"] as? Bool) != true {
                    if (o["subtype"] as? String) == "api_error" {
                        retry = (number, o["retryAttempt"] as? Int ?? 0, o["maxRetries"] as? Int ?? 0)
                    } else if let at = (o["timestamp"] as? String).flatMap(Self.stampDate) {
                        compacted = at
                    }
                }
                return
            }
            let fromAssistant = Phrase.assistant.isIn(line), fromUser = Phrase.user.isIn(line)
            if fromAssistant || fromUser, !Phrase.sidechain.isIn(line) {
                lastTurnLine = number
                lastTurn = Data(line)
                if fromAssistant && !Phrase.apiError.isIn(line) { normalAssistantLine = number }
            }
            let isToolResult = fromUser && Phrase.toolResult.isIn(line)
            // The model rides on every assistant line; the last one that names a real one is the session's.
            if fromAssistant, !Phrase.sidechain.isIn(line), let model = replyModel(line) { info.model = model }
            if fromAssistant && Phrase.toolUse.isIn(line) {
                lastToolUse = (number, Data(line))
            } else if isToolResult {
                lastToolResult = number
            }
            // Tool calls and tool results are the bulk of a transcript (single lines can be
            // hundreds of KB) and carry nothing shown on a card, so they are never JSON-decoded.
            guard
                (fromAssistant && Phrase.text.isIn(line)) || (fromUser && !isToolResult)
                    || Phrase.recap.isIn(line) || Phrase.customTitle.isIn(line) || Phrase.aiTitle.isIn(line),
                let o = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                (o["isSidechain"] as? Bool) != true
            else { return }
            let stamp = o["timestamp"] as? String ?? ""
            switch o["type"] as? String {
            case "custom-title":
                if let t = o["customTitle"] as? String, !t.isEmpty { info.customTitle = t }
            case "ai-title":
                if let t = o["aiTitle"] as? String, !t.isEmpty { info.aiTitle = t }
            case "system":
                if (o["subtype"] as? String) == "away_summary", let c = o["content"] as? String { recap = (stamp, c) }
            case "assistant":
                if (o["isApiErrorMessage"] as? Bool) == true {  // An error is no reply (its words are the card's line)
                    apiError = (number, stamp, o["error"] as? String ?? "", o["apiErrorStatus"] as? Int, messageText(o) ?? "")
                } else if let t = messageText(o), !isFillerReply(t) {
                    reply = (stamp, t)
                }
            case "user":
                if let t = turnOrigin(o) {
                    origin = t
                    if t.origin != "user" { foreign = (stamp, t.origin, t.peer) }
                }
                // Tool results and injected notices are "user" entries too; keep only typed prompts. A peer's message or
                // a subagent's hand-back is not theirs either, whatever it starts with.
                if (o["isMeta"] as? Bool) != true, let t = messageText(o), !t.hasPrefix("<"),
                    !t.hasPrefix("[Request interrupted"), classifyTurnText(t).origin == "user"
                {
                    asked = (stamp, t)
                    askedLine = number
                }
            default: break
            }
        }
        if let h = held, !openLast { census.whole += 1; if h { census.known += 1 } }
        info.unknownLines = census.verdict ?? tails[sid]?.unknownLines ?? false
        info.summaryLine = pickSummaryLine(recap: recap, reply: reply, asked: asked)
        // A peer's or subagent's report newer than the reply and the user's words: the turn is handling it.
        if let f = foreign, f.stamp > (reply?.0 ?? ""), f.stamp >= (asked?.0 ?? "") {
            info.summaryLine = f.origin == "agent" ? .relayAgent : f.peer.isEmpty ? .relayPeer : .relayFrom(peer: f.peer)
        }
        // The error row is still the last thing said, for when the session last had something new to read (idleSince, restarts).
        info.replyStamp = max(reply?.0 ?? "", apiError?.stamp ?? "")
        (info.origin, info.peer) = origin
        // Idle after an error of the API that nothing has answered since (no assistant line, no prompt of theirs).
        if status == "idle", let e = apiError, e.line > normalAssistantLine, e.line > askedLine {
            let kind = e.error == "rate_limit" ? "rate_limit" : ["authentication_failed", "oauth_org_not_allowed"].contains(e.error) ? "auth" : "api"
            let text = String(e.text.prefix(160))
            (info.errorKind, info.errorStatus, info.errorText, info.errorSince) = (kind, e.status, text.isEmpty ? nil : text, Self.stampDate(e.stamp))
            info.summaryLine = .apiError(kind: kind, status: e.status, text: apiErrorWords(text))
        }
        // Busy, and the last thing in the session's own lines is the note of a retry (CC writes none when it works again).
        if status == "busy", let r = retry, r.line > lastTurnLine {
            (info.retryAttempt, info.retryMax) = (r.attempt, r.max)
            info.summaryLine = .retrying(attempt: r.attempt, max: r.max)
        }
        info.compactedAt = compacted
        info.lastTurnStamp = lastTurn.flatMap(Self.stamp(of:)) ?? ""
        // A tool call with no result after it is the thing a waiting session is stuck on.
        if status == "waiting", let use = lastToolUse, use.0 > lastToolResult {
            info.pendingLine = pendingRequestLine(use.1)
        }
        // The same unanswered tool call on a busy session is what it is doing right now (the Seaview scene's badge).
        if status == "busy", let use = lastToolUse, use.0 > lastToolResult {
            info.tool = toolUseName(use.1) ?? ""
        }
        tails[sid] = info
        return info
    }
}
