import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

// ───────── --dump's slow log ─────────
// The phone's helper runs `--dump` every 3 s and gives it 10 s; a few runs have gone over, and a run that takes 0.1 s on a
// good day gives no hint of where the long ones stand. While a `--dump` runs, each stage of it is timed (`dumpStage`, on the
// monotonic clock; a stage that holds another's time stops it while it runs, so the stages add up to the total). A run that
// took longer than `SOULGENT_DUMP_SLOW_MS` (default 1000) leaves one line in `dump-slow.log` in the data folder; one still
// running after `SOULGENT_DUMP_STALL_MS` (default 8000) leaves a line saying where it stands, so that being killed at 10 s
// still tells. The panel never sets `dumpProbe`: every call below is then one test of a nil.

/// The timing of the `--dump` under way; nil in the panel and in every other run.
var dumpProbe: DumpProbe?
/// For the checks: called as a stage begins (a way to hold one up).
var dumpStageHook: ((String) -> Void)?

/// `body` as the stage `name`, `subject` (a session id) saying whose it is. Only timed in a `--dump`.
@inline(__always) func dumpStage<T>(_ name: String, subject: String? = nil, _ body: () -> T) -> T {
    guard let probe = dumpProbe else { return body() }
    probe.begin(name, subject: subject)
    defer { probe.end() }
    return body()
}

final class DumpProbe {
    struct Frame {
        var name: String
        var subject: String?
        var since: UInt64
        var own: UInt64 = 0  // time spent in this frame itself, while no frame above it ran
    }
    static let order = [
        "registry", "restartList", "tailInfo", "transcriptIndex", "bgCacheRead", "bgScan", "bgCacheWrite", "goneRead", "goneWrite",
        "codexCLI", "codexCLI.sqlite", "codexApp", "codexApp.sqlite", "workbuddy", "workbuddy.sqlite", "runningApp", "subagents",
        "serialize", "output", "other",
    ]
    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    private let lock = NSLock()
    private let began = DumpProbe.now()
    private let bgBytesAtStart = bgBytesRead
    private var frames: [Frame]
    private var spent: [String: UInt64] = [:]
    private var slowest: [String: (subject: String, own: UInt64, detail: Int)] = [:]
    private var counts: [String: Int] = [:]
    private var finished = false
    private var stall: DispatchWorkItem?
    let logFile: String
    let threshold: Double  // ms; a run over it leaves its line
    /// Seconds from the process's launch to this probe: dyld, the binary's pages, anything before `main` got going.
    let startup: Double?

    init(logFile: String, thresholdMs: Double) {
        self.logFile = logFile
        threshold = thresholdMs
        frames = [Frame(name: "other", subject: nil, since: began)]
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        if sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
            let t = info.kp_proc.p_un.__p_starttime
            startup = Date().timeIntervalSince1970 - (Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
        } else {
            startup = nil
        }
    }

    func begin(_ name: String, subject: String?) {
        lock.lock()
        let t = Self.now()
        frames[frames.count - 1].own += t - frames[frames.count - 1].since
        frames.append(Frame(name: name, subject: subject, since: t))
        lock.unlock()
        dumpStageHook?(name)
    }

    /// Ends the stage last begun; `detail` (bytes, say) is kept with the subject if this was the slowest one of its kind.
    func end(detail: Int? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard frames.count > 1 else { return }
        let t = Self.now()
        var f = frames.removeLast()
        f.own += t - f.since
        spent[f.name, default: 0] += f.own
        frames[frames.count - 1].since = t
        if let subject = f.subject, let detail, f.own > (slowest[f.name]?.own ?? 0) { slowest[f.name] = (subject, f.own, detail) }
    }

    /// What a database look is called: after the stage it is made in ("workbuddy.sqlite").
    var sqliteStage: String {
        lock.lock()
        defer { lock.unlock() }
        return frames[frames.count - 1].name + ".sqlite"
    }

    func count(_ name: String, _ n: Int = 1) {
        lock.lock()
        counts[name, default: 0] += n
        lock.unlock()
    }

    /// Every stage's time so far (what is running counts up to now), in the fixed order; those with none left out.
    private func stages(at t: UInt64) -> String {
        var all = spent
        for (i, f) in frames.enumerated() { all[f.name, default: 0] += f.own + (i == frames.count - 1 ? t - f.since : 0) }
        let names = Self.order + all.keys.filter { !Self.order.contains($0) }.sorted()
        return names.compactMap { n in all[n].map { "\(n)=" + Self.ms($0) } }.joined(separator: " ")
    }

    static func ms(_ ns: UInt64) -> String { String(format: "%.1f", Double(ns) / 1_000_000) }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return f.string(from: Date())
    }

    private static func load() -> String {
        var l = [Double](repeating: 0, count: 3)
        guard getloadavg(&l, 3) == 3 else { return "?" }
        return l.map { String(format: "%.2f", $0) }.joined(separator: "/")
    }

    /// Starts the clock that says where the run stands, should it still be going after `seconds`.
    func watch(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.reportStall() }
        stall = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func reportStall() {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        let t = Self.now()
        let top = frames[frames.count - 1]
        let line = "\(Self.stamp()) STALL after=\(Self.ms(t - began))ms pid=\(getpid()) load=\(Self.load()) in=\(top.name)"
            + (top.subject.map { " subject=\($0)" } ?? "") + " inStage=\(Self.ms(top.own + t - top.since))ms bgBytes=\(bgBytesRead - bgBytesAtStart)"
            + " progress: " + stages(at: t)
        lock.unlock()
        DumpProbe.append(line, to: logFile)
    }

    /// The run is over: its line when it was slow.
    func finish() {
        lock.lock()
        let t = Self.now()
        finished = true
        stall?.cancel()
        let total = Double(t - began) / 1_000_000
        guard total > threshold else {
            lock.unlock()
            return
        }
        var line = "\(Self.stamp()) total=\(String(format: "%.1f", total))ms pid=\(getpid()) load=\(Self.load())"
        line += " launch=" + (startup.map { String(format: "%.0fms", max(0, $0 * 1000)) } ?? "?")
        line += " sessions=\(counts["sessions"] ?? 0) indexFiles=\(counts["indexFiles"] ?? 0) bgBytes=\(bgBytesRead - bgBytesAtStart)"
        if let s = slowest["tailInfo"] { line += " slowTail=\(s.subject) slowTailSize=\(s.detail) slowTailMs=\(Self.ms(s.own))" }
        if let s = slowest["bgScan"] { line += " slowBG=\(s.subject) slowBGBytes=\(s.detail) slowBGMs=\(Self.ms(s.own))" }
        line += " | " + stages(at: t)
        lock.unlock()
        DumpProbe.append(line, to: logFile)
    }

    /// One line at the end of the file; past 1 MB only the later half is kept first (from a line's start). Whatever goes wrong
    /// here is the log's loss and nothing else's.
    static let limit = 1 << 20
    private static let writing = NSLock()
    static func append(_ line: String, to path: String) {
        writing.lock()
        defer { writing.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)??.intValue, size > limit,
            let old = fm.contents(atPath: path)
        {
            var keep = old.suffix(old.count / 2)
            if let nl = keep.firstIndex(of: 0x0A) { keep = keep[(nl + 1)...] }
            let scratch = path + ".\(getpid()).tmp"
            if (try? Data(keep).write(to: URL(fileURLWithPath: scratch))) == nil || rename(scratch, path) != 0 { try? fm.removeItem(atPath: scratch) }
        }
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// The milliseconds a variable says (not a number, or below 0: nil).
func dumpMilliseconds(_ environment: [String: String], _ key: String) -> Double? {
    environment[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }.flatMap { $0 >= 0 ? $0 : nil }
}

/// `--dump`: the rows as JSON, handed to `emit`, with the slow log kept as above. Its output is the same as without the log.
func runDump(
    _ loader: Loader, now: Date = Date(), environment: [String: String] = ProcessInfo.processInfo.environment,
    logFolder: String = panelDataFolder, emit: (String) -> Void = { print($0) }
) {
    let probe = DumpProbe(
        logFile: logFolder + "/dump-slow.log", thresholdMs: dumpMilliseconds(environment, "SOULGENT_DUMP_SLOW_MS") ?? 1000)
    dumpProbe = probe
    defer { dumpProbe = nil }
    probe.watch(after: (dumpMilliseconds(environment, "SOULGENT_DUMP_STALL_MS") ?? 8000) / 1000)
    let rows = dumpRows(loader, now: now)
    let text = dumpStage("serialize") { () -> String in
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
    dumpStage("output") { emit(text) }
    probe.finish()
}

/// The rows `--dump` prints. Besides the sessions' own fields each has its format warnings (`formatWarnings`) and its helpers, which need its running subagents: the panel
/// reads them every tick (`Store.readAgents`); a run of this reads them once, from the same folders and the same way.
func dumpRows(_ loader: Loader, now: Date = Date()) -> [[String: Any]] {
    let loaded = loader.load(now: now)
    let subagents = dumpStage("subagents") { OfficeSubagents().running(loaded.compactMap { s in loader.transcript(of: s.id).map { (s.id, $0) } }, now: now).mapValues(\.count) }
    // `formatWarnings` (a field agreed between this app's `--dump` and the phone helper): on every row, [] when nothing of its source's format (nor Orca's) went unread.
    return loaded.map { s in
        var row = dumpRow(s, model: loader.model(of: s.id) ?? "", subagents: subagents[s.id] ?? 0)
        row["formatWarnings"] = loader.formatWarnings(for: s).map(\.json)
        return row
    }
}

/// An API error's words as the card says them, with the leading "API Error:" and the status after it taken off (the card has
/// its own API error 529 line), on their first line: "API Error: 529 Overloaded. …" is "Overloaded. …". Words not starting so stay.
func apiErrorWords(_ text: String) -> String {
    var t = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
    if t.hasPrefix("API Error:") {
        t = t.dropFirst("API Error:".count).drop(while: { $0 == " " })
        let digits = t.prefix(while: { $0.isASCII && $0.isNumber })
        if digits.count == 3 { t = t.dropFirst(3) }
        t = t.drop(while: { $0 == " " || $0 == ":" })
    }
    return t.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
}

/// One session as `--dump` gives it: the fields it always had, then summaryCode, summaryArgs, nameUntitled, then bgTasks, bgAgents, bgSince, bgStale, bgEndedAt, bgOwned, bgList, then errorKind, errorStatus, errorText, errorSince, retryAttempt, retryMax, disconnected, disconnectedSince, compactedAt, helpers. `subagents`: how many subagents of its own it has running (`Store.agentCounts`).
func dumpRow(_ s: Session, model: String, subagents: Int = 0) -> [String: Any] {
    let line = s.line
    return [
        "id": s.id, "project": s.project, "name": s.name, "status": s.status, "waitingFor": s.waitingFor,
        "since": s.since.timeIntervalSince1970, "summary": s.summary, "kind": s.kind, "model": model,
        "origin": s.origin, "peer": s.peer,
        "summaryCode": line.code, "summaryArgs": line.args, "nameUntitled": s.nameUntitled,
        "bgTasks": s.bgTasks, "bgAgents": s.bgAgents, "bgSince": s.bgSince.map { $0.timeIntervalSince1970 } ?? NSNull(),
        "bgStale": s.bgStale, "bgEndedAt": s.bgEndedAt.map { $0.timeIntervalSince1970 } ?? NSNull(), "bgOwned": s.bgOwned,
        "bgList": s.bgList.map { $0.json },
        "errorKind": s.errorKind.map { $0 as Any } ?? NSNull(), "errorStatus": s.errorStatus.map { $0 as Any } ?? NSNull(),
        "errorText": s.errorText.map { $0 as Any } ?? NSNull(), "errorSince": s.errorSince.map { $0.timeIntervalSince1970 } ?? NSNull(),
        "retryAttempt": s.retryAttempt.map { $0 as Any } ?? NSNull(), "retryMax": s.retryMax.map { $0 as Any } ?? NSNull(),
        "disconnected": s.disconnected, "disconnectedSince": s.disconnectedSince.map { $0.timeIntervalSince1970 } ?? NSNull(),
        "compactedAt": s.compactedAt.map { $0.timeIntervalSince1970 } ?? NSNull(), "helpers": s.helpers(subagents: subagents),
    ]
}
