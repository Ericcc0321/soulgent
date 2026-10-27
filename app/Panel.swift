// Soulgent: a floating panel where every open Claude Code session is an agent with a pet.
//
// Status comes from ~/.claude/sessions/<pid>.json (one file per running session, re-read
// every 2 s). Names and the one-line summary come from the tail of each session's
// transcript, re-read only when that file changes. Both are Claude Code internal formats.
// Pets are the ones installed for petdex in ~/.petdex/pets/.
//
// Narrow window: a list like a chat inbox. Wide window: pets with speech bubbles.
//
// Build with ./build.sh (Command Line Tools are enough, no Xcode).
// `Soulgent --snapshot out.png [--width 640] [--hover <name>] [--pin <name>]` renders the
// board to a PNG and exits; --hover and --pin show it as if that card were pointed at or pinned.
// ./test.sh runs the checks in Tests.swift.
// `Soulgent --jump <session name or id prefix>` does what a click on that card does.
// `Soulgent --dump` prints the open sessions as JSON.

import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

// ───────── Data ─────────
// The data layer (sessions, Loader, --dump) lives in Data/*.swift; what reads other programs' formats (Claude Code's
// transcripts, Codex, WorkBuddy, Orca) lives in Adapters/*.swift.

/// Where a click takes a session in an app with its own window: the link that app opens a conversation by (its own
/// "copy link" and notifications use these). Nil for those in Orca's terminals.
func jumpURL(_ s: Session) -> URL? {
    // As JavaScript's encodeURIComponent, which WorkBuddy's own links go through.
    let component = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
    guard let id = s.id.addingPercentEncoding(withAllowedCharacters: component) else { return nil }
    switch s.kind {
    case "codexApp": return URL(string: "codex://threads/" + id)
    case "workbuddy": return URL(string: "workbuddy://chat/" + id)
    default: return nil
    }
}

/// The app a session of that kind lives in.
func appBundle(_ s: Session) -> String? {
    switch s.kind {
    case "codexApp": return CodexAppSessions.bundle
    case "workbuddy": return WorkBuddySessions.bundle
    default: return nil
    }
}

// ───────── Conversations between sessions ─────────

/// Another open session this one has exchanged messages with.
struct Peer: Equatable {
    let id: String
    var sent = 0  // messages this session sent to it
    var received = 0  // messages it sent to this session
    var last = Date.distantPast
    var note = ""  // what the latest message was about
    var outgoing = false  // the latest message went from this session to it

    /// Talk within the last ten minutes counts as still going on.
    func isRecent(_ now: Date) -> Bool { now.timeIntervalSince(last) < 600 }
}

/// How much of the account's allowance is used. The status line script (~/.claude/statusline.sh)
/// publishes the freshest figures any session has seen: per window, one line "percent resetEpoch".
struct Usage: Equatable {
    let percent: Int
    let resets: Date
}

let usageDir = ProcessInfo.processInfo.environment["CLAUDE_STATUSLINE_STATE_DIR"] ?? "/tmp/claude-statusline"

/// `window` is "five_hour" or "seven_day". Nothing once that window has reset: the figure is stale.
func readUsage(_ window: String, in dir: String = usageDir, now: Date) -> Usage? {
    guard let line = try? String(contentsOfFile: dir + "/shared." + window, encoding: .utf8) else { return nil }
    let parts = line.split(whereSeparator: \.isWhitespace)
    guard parts.count == 2, let percent = Int(parts[0]), let reset = TimeInterval(parts[1]),
        reset > now.timeIntervalSince1970
    else { return nil }
    return Usage(percent: percent, resets: Date(timeIntervalSince1970: reset))
}

/// Finds the messages sessions sent each other (Claude Code's SendMessage) in the transcripts
/// of the open sessions. A transcript only grows, so each is read through once and after that
/// only its new tail; what was found is kept in a cache file between launches.
final class LinkScanner {
    struct Message: Codable {
        let peer: String  // the other session's name as written in the transcript
        let at: String
        let note: String
        var address: String?  // for a received message: the sender's process address
    }
    struct Record: Codable {
        var offset: UInt64 = 0
        var sent: [Message] = []
        var received: [Message] = []
    }

    private var records: [String: Record] = [:]  // by session id; touched on `queue` only
    private let queue = DispatchQueue(label: "session-links", qos: .utility)
    private var busy = false  // main thread only
    private let cacheFile = cacheFolder + "/links-v3.json"

    init() {
        if let data = FileManager.default.contents(atPath: cacheFile),
            let saved = try? JSONDecoder().decode([String: Record].self, from: data)
        {
            records = saved
        }
    }

    /// Call on the main thread; `done` comes back on the main thread.
    func scan(_ files: [(String, String)], done: @escaping ([String: Record]) -> Void) {
        guard !busy else { return }
        busy = true
        queue.async {
            let snapshot = self.scanNow(files)
            DispatchQueue.main.async {
                self.busy = false
                done(snapshot)
            }
        }
    }

    func scanNow(_ files: [(String, String)]) -> [String: Record] {
        var changed = false
        for (sid, path) in files where read(sid, path) { changed = true }
        if changed, let data = try? JSONEncoder().encode(records) {
            try? FileManager.default.createDirectory(atPath: (cacheFile as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: cacheFile), options: .atomic)
        }
        return records
    }

    private func read(_ sid: String, _ path: String) -> Bool {
        guard let size = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value
        else { return false }
        var record = records[sid] ?? Record()
        if size < record.offset { record = Record() }  // the file was replaced
        guard size > record.offset, let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        try? handle.seek(toOffset: record.offset)
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            pending.append(chunk)
            guard let lastNewline = pending.lastIndex(of: 0x0A) else { continue }
            let whole = Data(pending[pending.startIndex...lastNewline])
            record.offset += UInt64(whole.count)
            forEachLine(of: whole) { _, line in
                if Phrase.sendMessage.isIn(line) {
                    parse(Data(line), sending: true, into: &record)
                } else if Phrase.incoming.isIn(line) {
                    parse(Data(line), sending: false, into: &record)
                }
            }
            pending = Data(pending[(lastNewline + 1)...])
        }
        record.sent = Array(record.sent.suffix(300))
        record.received = Array(record.received.suffix(300))
        records[sid] = record
        return true
    }

    private func parse(_ line: Data, sending: Bool, into record: inout Record) {
        if sending {
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                (entry["type"] as? String) == "assistant", (entry["isSidechain"] as? Bool) != true,
                let blocks = (entry["message"] as? [String: Any])?["content"] as? [[String: Any]]
            else { return }
            for block in blocks where (block["type"] as? String) == "tool_use" && (block["name"] as? String) == "SendMessage" {
                let input = block["input"] as? [String: Any] ?? [:]
                guard let to = (input["to"] as? String) ?? (input["recipient"] as? String) else { continue }
                let about = (input["summary"] as? String) ?? (input["message"] as? String) ?? ""
                record.sent.append(Message(peer: to, at: entry["timestamp"] as? String ?? "", note: firstLine(about, limit: 80)))
            }
        } else {
            // Only a real incoming message starts like this; the same words inside a tool
            // result or a pasted log do not.
            guard let entry = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                (entry["type"] as? String) == "user", let text = messageText(entry),
                text.hasPrefix("Another Claude session sent a message:"), text.contains("<cross-session-message from="),
                let nameRange = text.range(of: #"from-name="[^"]*""#, options: .regularExpression)
            else { return }
            let name = String(text[nameRange].dropFirst(11).dropLast(1))
            let address = text.range(of: #"message from="[^"]*""#, options: .regularExpression)
                .map { String(text[$0].dropFirst(14).dropLast(1)) }
            let body = text.range(of: ">").map { String(text[$0.upperBound...]) } ?? ""
            record.received.append(
                Message(peer: name, at: entry["timestamp"] as? String ?? "", note: firstLine(body, limit: 80), address: address))
        }
    }
}

@MainActor final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    /// When each session's last result was looked at (clicked). Newer results are "unread".
    @Published var seen: [String: Double] = UserDefaults.standard.dictionary(forKey: "seenAt") as? [String: Double] ?? [:]
    /// `seenAt` as the settings last had it, read or written by the panel: an entry that differs now was written from outside.
    private var storedSeen: [String: Double] = Store.numbers(UserDefaults.standard.dictionary(forKey: "seenAt"))
    /// Sessions kept under "Has news" by hand: looked at, but still owed an answer.
    @Published var pinned = Set(UserDefaults.standard.stringArray(forKey: "pinned") ?? [])
    /// Sessions sent to a desk or to the rest area by hand, from the menu (`rest`, `desk`).
    @Published var parked: [String: Parking] = (UserDefaults.standard.dictionary(forKey: "parked") ?? [:]).compactMapValues { entry in
        guard let entry = entry as? [String: Any], let zone = (entry["zone"] as? String).flatMap(Parking.Zone.init),
            let at = entry["at"] as? Double
        else { return nil }
        return Parking(zone: zone, at: at)
    }
    /// The account's usage in the current five hours and in the current week, when known.
    @Published private(set) var fiveHour: Usage?
    @Published private(set) var sevenDay: Usage?
    /// Sessions that have just finished: their pet jumps until this time.
    @Published var celebrating: [String: Date] = [:]
    @Published private(set) var petBySession: [String: String] =
        UserDefaults.standard.dictionary(forKey: "petBySession") as? [String: String] ?? [:]
    /// The pet each Orca pane last had, by its `ORCA_PANE_KEY`: /clear starts a new session in the same pane, and the pet
    /// stays. Not published: the views go by `petBySession`. `paneOrder` has the panes oldest first, for the cap.
    private(set) var petByPane: [String: String] = UserDefaults.standard.dictionary(forKey: "petByPane") as? [String: String] ?? [:]
    private var paneOrder: [String] = UserDefaults.standard.stringArray(forKey: "petByPaneOrder") ?? []
    /// The pet each session name (its registry name, e.g. `Demo-board`) last had. window swap (/window) ends a session and opens
    /// one with the same name, a new id and usually a new pane: it takes its name's pet back. `nameOrder` has the names
    /// oldest first, for the cap (400, never one still open).
    private(set) var petByName: [String: String] = UserDefaults.standard.dictionary(forKey: "petByName") as? [String: String] ?? [:]
    private var nameOrder: [String] = UserDefaults.standard.stringArray(forKey: "petByNameOrder") ?? []
    /// The pane a process was started in (`OrcaTabs.pane(of:)`): "" for none, nil while it is still being looked up. A
    /// check gives its own.
    var paneOf: (Int32) -> String? = { OrcaTabs.shared.pane(of: $0) }
    /// For how many rounds each new session has waited for its pane to be known.
    private var paneWaits: [String: Int] = [:]
    @Published var narrow = false  // the window is in its narrow layout; the title bar shortens too
    @Published var officeFits = false  // the window is large enough for the office; the title bar offers it then
    /// The session whose card the pointer is on; in the office, its pet or its words, or the lounge door
    /// (`OfficeLayout.doorKey`), a chip (`ChipKind.key`, the waiting chip's among them), the notice board
    /// (`OfficeLayout.boardKey`), or a row on the list by the door or the waiting chip (`OfficeList.row`).
    @Published var hovered: String?
    /// The title bar's search is open (its field over the window's top-right corner).
    @Published var searchOpen = false
    /// An extension's scene opens its own list of those behind its door without leaving the scene (`SceneExtension.doorList`).
    @Published var sceneListOpen = false
    /// That list's visible rows, for clipping their hit areas; on the store because a Swift 6.4 command-line
    /// toolchain cannot expand SwiftUI's @State macro.
    @Published var sceneListViewport = CGRect.zero
    /// The search field's words and its highlighted row (`SearchPanel`), and Settings' language and its reassign question: here,
    /// not in @State, for the same reason (a command-line toolchain without SwiftUI's macro plugin; build.sh refuses @State).
    @Published var searchQuery = ""
    @Published var searchIndex = 0
    @Published var settingsLanguage: String? = LanguageChoice.current()
    @Published var askingReassign = false
    /// Messages on their way from one pet to another, drawn for a second or two each.
    @Published private(set) var flights: [Flight] = []
    /// How many subagents each open session has running (`OfficeSubagents`): the little people on its desk. None, no entry.
    @Published var agentCounts: [String: Int] = [:]
    /// The same agents, the longest-running first: what each was asked and on which model, for its card.
    @Published var agents: [String: [OfficeSubagents.Agent]] = [:]
    /// The session the user is typing in, in Orca: the office puts a light on its pet. Kept while Orca is in the background and when
    /// its tab bar matches nothing; nil without the Accessibility permission.
    @Published var focused: String?
    /// Whether Orca was the frontmost app at the last look; the light is half as strong while it is not. Not published:
    /// the reader tells the view whenever it changes, and nothing else does.
    var orcaInFront = true
    let focus = OfficeFocus()
    /// The session a click has just jumped to, lit at once ahead of Orca's own say, and until when that holds. Till
    /// then a look at Orca's bar that names someone else, or no one, is not taken: Orca may not have switched yet (or a look
    /// begun before the click answers late). A look that names this session ends the hold early.
    private(set) var expected: (id: String, until: Date)?
    /// How long a click's light holds against a look that disagrees; when Orca is looked at again to confirm it.
    static let expectHold = 1.5, confirmAfter = 0.25
    /// The running panel's store (`start`), for a jump made where no store is in hand. None in a check or a picture.
    private(set) static weak var live: Store?
    /// When a confirming look is made: in that many seconds, on the main thread. A check gives it a hook of its own.
    var later: (Double, @escaping @MainActor () -> Void) -> Void = { seconds, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
    }
    let tracker = HoverTracker()
    /// Set for a snapshot: it shows the board as it is, and what it works out along the way
    /// (pets for new sessions, pins that have lapsed) stays out of the running panel's settings.
    var readOnly = false
    private var lastMessageAt: [String: String] = [:]  // per pair of sessions
    private var linksPrimed = false

    struct Flight: Identifiable {
        let id = UUID()
        let from: String
        let to: String
        let at = Date()
    }
    /// A round of talk between two sessions: who opened it, and when.
    struct Round: Equatable {
        let opener: String
        let since: Date
    }
    /// For the office: the rounds going on that opened while the panel watched, by pair (its ids joined with "|", the
    /// smaller first). A round opens when a pair speaks after ten quiet minutes, or for the first time; whoever sent the
    /// first of those messages opened it, though the answer may already be there when the scan sees it. It lasts while
    /// the pair has spoken within ten minutes. Not published: a round opens only with a new message, which changes
    /// `peers`, and that is published.
    private(set) var rounds: [String: Round] = [:]
    /// For each session, the other open sessions it has talked with, most recent first.
    @Published private(set) var peers: [String: [Peer]] = [:]
    /// What happened lately, for the office's notice board, as the last run left it. Written when it changes, never by a
    /// read-only store.
    @Published private(set) var activity = OfficeActivity.load()
    /// When the panel first saw anyone open: for a minute after that, what it reads is how things already were.
    private var firstSeen: Date?
    private let scanner = LinkScanner()
    private let subagents = OfficeSubagents()
    private var ticks = 0

    /// Work that finished before this moment never counts as unread. On first run that is six
    /// hours back, so the board does not open with every old session asking for attention.
    let baseline: Double = {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "seenBaseline") == nil {
            defaults.set(Date().timeIntervalSince1970 - recentIdle, forKey: "seenBaseline")
        }
        return defaults.double(forKey: "seenBaseline")
    }()

    private let loader = Loader()
    /// The other programs' formats not understood at the last look (`FormatWarning`): the title bar's amber dot while any stands.
    @Published var formatWarnings: [FormatWarning] = []
    private var timer: Timer?
    private var published = Date()
    private var lastWorking: [String: Bool] = [:]
    private var celebrated: [String: Date] = [:]
    static let celebrateGap: TimeInterval = 20
    /// A finish waiting one tick before it is celebrated (when it was seen): the registry may say idle a moment before
    /// the error's line is in the transcript, and an error is not celebrated.
    private var cheerDue: [String: Date] = [:]

    /// What the board shows of the loader's list: all of it, the sessions that exited unexpectedly too (the grey card);
    /// `showFailed` off, those are left off. `--dump` lists them either way (it never comes through here).
    nonisolated static func shown(_ list: [Session]) -> [Session] { showFailed() ? list : list.filter { !$0.disconnected } }

    func loadOnce() {
        tracker.store = self
        Pets.shared.refresh(force: true)
        Pets.shared.onReady = { [weak self] in self?.objectWillChange.send() }
        if DemoMode.active { return DemoCrowd.fill(self) }  // The made-up crowd, nothing real is read
        sessions = Self.shown(loader.load())
        takeFormatWarnings()
        readAgents(transcripts(), at: Date())
        refreshUsage()
        settle()
    }

    func start() {
        Store.live = self
        loadOnce()
        if DemoMode.active { return }  // The crowd stands still; no tick reads the real sessions
        focus.nudge = { [weak self] in self?.readFocus() }  // Orca told of a change: no need to wait for the tick
        focus.launched()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// The loader's warnings and Orca's, published only when they changed.
    private func takeFormatWarnings() {
        let now = loader.formatWarnings
        if now != formatWarnings { formatWarnings = now }
    }

    private func tick() {
        Pets.shared.refresh()
        ticks += 1
        if ticks % 5 == 1 {  // every 10 s is plenty for something that happens a few times a day
            scanner.scan(transcripts()) { [weak self] records in self?.applyLinks(records) }
            refreshUsage()
        }
        takeStored()
        take(Self.shown(loader.load()), at: Date())
        takeFormatWarnings()
        // The off-duty roster, read again when its file changes, while the Seaview scene shows (its signs list them).
        if ZoneUI.active && ZoneRosterFile.refresh() { objectWillChange.send() }
        // Every tick: a stat per agent of each open session, a read only of what changed.
        readAgents(transcripts(), at: Date())
        readFocus()
    }

    /// What a tick does about where the user types, and a notice from Orca a moment after it comes: while Orca is the frontmost app
    /// and the panel may read it (Accessibility), `focus` reads Orca's tab bar off the main thread and takes it to a terminal
    /// and so to a session. Orca in the background, or a bar that matches nothing, leaves the light where it was; without the
    /// permission there is none. A check gives `focus` hooks of its own.
    func readFocus(at now: Date = Date()) {
        let front = focus.frontmost()
        // No Orca running (a Mac without it): nothing to be behind, so the light stays full.
        let inFront = front?.bundle == OfficeFocus.orca || !focus.running()
        // In a click's hold Orca is on its way forward: a look that finds it still behind does not dim the light.
        let coming = !inFront && expected.map { now < $0.until } == true
        if inFront != orcaInFront && !coming {
            objectWillChange.send()  // the light dims or comes back up
            orcaInFront = inFront
        }
        // Only Orca's own window is read: with no Orca running the light is full, but the app in front is someone else's.
        guard inFront, let front, front.bundle == OfficeFocus.orca, officeSpotlight() else { return }
        let pid = front.pid
        guard focus.allowed() else {
            expected = nil
            if focused != nil { focused = nil }
            return
        }
        // The time the look begins is the one held against a click's light; a look begun in the hold may see Orca
        // before it switched, however late it answers.
        focus.resolve(pid, among: sessions.map { ($0.id, $0.pid, $0.name) }, now: now) { [weak self] found in
            self?.take(found, at: now)
        }
    }

    /// What a look at Orca comes to, begun at `now`: the light goes to its session, or off for a terminal no session runs
    /// in; a look that matched nothing leaves it. Within a click's hold only a look that agrees is taken.
    func take(_ found: OfficeFocus.Found, at now: Date) {
        if let held = expected {
            if found == .session(held.id) {
                expected = nil  // Orca has switched: the light was right
            } else if now < held.until {
                return  // Orca not switched yet: the click's light stays
            } else {
                expected = nil
            }
        }
        switch found {
        case .session(let id): if focused != id { focused = id }
        case .noSession: if focused != nil { focused = nil }  // a terminal of its own, a shell say: nobody to light
        case .nothing: break
        }
    }

    /// A click jumps to `s`: its pet is lit at once, not on the next look at Orca (up to 2 s, the tick), and Orca is
    /// looked at again in a quarter of a second to confirm it, and once more as the hold runs out. Only where the light
    /// would follow the jump: the light switched on, the panel allowed to read Orca, a session of Orca's (not the Codex
    /// app's or WorkBuddy's, not one known to run outside Orca). Orca is coming forward, so the light is at full strength
    /// from the start. False, and nothing touched, where it would not.
    @discardableResult func expectFocus(_ s: Session, at now: Date = Date()) -> Bool {
        guard officeSpotlight(), jumpURL(s) == nil, focus.pane(s.pid) != "", focus.running(), focus.allowed() else { return false }
        expected = (s.id, now + Self.expectHold)
        if focused != s.id { focused = s.id }
        if !orcaInFront {
            objectWillChange.send()
            orcaInFront = true
        }
        later(Self.confirmAfter) { [weak self] in self?.readFocus() }
        later(Self.expectHold + 0.1) { [weak self] in self?.readFocus() }
        return true
    }

    /// What a tick does with its reading of the sessions. A check hands it readings of its own.
    func take(_ fresh: [Session], at now: Date) {
        // At the moment the work is done: it was at work (busy, or its work in the background), it is not now, and what it
        // reports is news (the user's own turn, or a background task's report on work the user started). Not twice for one finish: a report
        // follows the last task's end by a moment, and the end alone would have celebrated already.
        // Never an error's or an unexpected exit's finish; and, with `showFailed`, decided a tick later (`cheerDue`): the
        // error's line may land in the transcript a moment after the registry says idle.
        let byID = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func cheer(_ s: Session, finished: Date) {
            if s.bgOwned, let last = celebrated[s.id], finished.timeIntervalSince(last) < Self.celebrateGap { return }  // one finish, once
            celebrated[s.id] = finished
            celebrating[s.id] = now.addingTimeInterval(1.8)
        }
        for (id, at) in cheerDue {
            cheerDue[id] = nil
            guard let s = byID[id], s.status == "idle", !s.isWorking, s.errorKind == nil, !s.disconnected else { continue }
            cheer(s, finished: at)
        }
        for s in fresh where lastWorking[s.id] == true && s.status == "idle" && !s.isWorking && Self.countsAsNews(s) && !s.disconnected {
            if showFailed() {
                if s.errorKind == nil { cheerDue[s.id] = now }
            } else {
                cheer(s, finished: now)
            }
        }
        if celebrated.count > 50 { celebrated = celebrated.filter { now.timeIntervalSince($0.value) < Self.celebrateGap } }
        if celebrating.contains(where: { $0.value <= now }) {
            celebrating = celebrating.filter { $0.value > now }
        }
        if flights.contains(where: { now.timeIntervalSince($0.at) > 3 }) {
            flights = flights.filter { now.timeIntervalSince($0.at) <= 3 }
        }

        // An error, a retry or an exit coming or going moves its card too (to Error and back, grey).
        func place(_ s: Session) -> String { s.id + s.status + (s.isWorking ? "+" : "") + (s.hasError ? "!" : "") + (s.isRetrying ? "~" : "") + (s.isGone ? "x" : "") }
        let moved = fresh.map(place) != sessions.map(place)
        // The notice board hears of it whether the board or the office shows; with nothing moved, nothing to tell.
        if moved || firstSeen == nil { noteChanges(to: fresh, at: now) }
        if moved {
            // A session changed state, arrived or left: let the cards travel to their new place.
            withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { sessions = fresh }
            published = now
        } else if fresh != sessions || now.timeIntervalSince(published) > 30 {
            sessions = fresh  // every 30 s anyway, so "N minutes" keeps moving
            published = now
        }
        settle()
    }

    private func settle() {
        lastWorking = Dictionary(sessions.map { ($0.id, $0.isWorking) }, uniquingKeysWith: { first, _ in first })
        unpinAnswered()
        assignPets()
        // The office's pets at their true size, cut ahead of the first time it is shown. Nothing to
        // do once they are; a snapshot cuts what it needs on the spot.
        if !readOnly {
            OfficePets.shared.prepare(sessions.compactMap { displayPets[$0.id] })
            // And the helpers' walkers', when any session has some.
            if sessions.contains(where: { helpers(of: $0) > 0 }) { OfficePets.shared.prepare([ZoneSubagentFigures.claudePet, ZoneSubagentFigures.codexPet]) }
        }
        OrcaTabs.shared.prepare(sessions.map(\.pid))
    }

    private func save(_ value: Any, as key: String) {
        if !readOnly { UserDefaults.standard.set(value, forKey: key) }
    }

    private func refreshUsage() {
        let now = Date()
        let short = readUsage("five_hour", now: now), long = readUsage("seven_day", now: now)
        if short != fiveHour { fiveHour = short }
        if long != sevenDay { sevenDay = long }
    }

    private func transcripts() -> [(String, String)] {
        sessions.compactMap { s in loader.transcript(of: s.id).map { (s.id, $0) } }
    }

    /// How many helpers a session has, as `--dump`'s helpers say: its running subagents or its background ones, whichever
    /// are more, and its background commands besides (no card shows it yet).
    func helpers(of s: Session) -> Int { s.helpers(subagents: max(agentCounts[s.id] ?? 0, agents[s.id]?.count ?? 0)) }

    /// The pets of a session's helpers, one each (as many as `helpers(of:)`): a subagent's by its kind (a Codex one
    /// `codexPet`); the background commands, which the dump gives no name, `claudePet`.
    func walkerPets(of s: Session) -> [String] {
        let n = helpers(of: s)
        guard n > 0 else { return [] }
        let kinds = (agents[s.id] ?? []).map { ZoneSubagentFigures.pet(for: ZoneSubagentFigures.Member(agent: $0, type: $0.agentType)) }
        return (0..<n).map { $0 < kinds.count ? kinds[$0] : ZoneSubagentFigures.claudePet }
    }

    /// The model a Codex session runs on, for its cards.
    func model(of s: Session) -> String? { loader.model(of: s.id) }

    /// For snapshots: read the transcripts right now instead of in the background.
    func scanLinksNow() { if !DemoMode.active { applyLinks(scanner.scanNow(transcripts())) } }

    /// What a tick does about the open sessions' subagents, given their transcripts. A check hands it transcripts of its
    /// own. Told only when something changed: the room is repainted for the people on the desks.
    func readAgents(_ transcripts: [(String, String)], at now: Date) {
        let running = subagents.running(transcripts, now: now)
        if running != agents { agents = running }
        let counts = running.mapValues(\.count)
        if counts != agentCounts { agentCounts = counts }
    }

    /// Turns "who wrote to which name" into pairs of open sessions. A message shows up in the
    /// sender's transcript and in the receiver's; each direction counts the larger of the two.
    /// `scanned` is when the transcripts were read, for which rounds are still going on.
    func applyLinks(_ records: [String: LinkScanner.Record], scanned: Date = Date()) {
        // A message names its target by session name, or by the address of that session's
        // process ("uds:/tmp/cc-socks/<pid>.sock").
        var idByName: [String: String] = [:]
        for s in sessions {
            idByName[s.name] = s.id
            if !s.registryName.isEmpty { idByName[s.registryName] = s.id }
            idByName["uds:/tmp/cc-socks/\(s.pid).sock"] = s.id
        }
        // Names change when a session is renamed; an old message may only match by address,
        // or by a name that differs in capitals.
        let idByLowerName = Dictionary(idByName.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        func resolve(_ m: LinkScanner.Message) -> String? {
            idByName[m.peer] ?? m.address.flatMap { idByName[$0] } ?? idByLowerName[m.peer.lowercased()]
        }
        typealias Tally = (count: Int, at: String, note: String)
        var sentBy: [String: [String: Tally]] = [:]  // sender -> receiver, as the sender recorded it
        var gotBy: [String: [String: Tally]] = [:]  // receiver -> sender, as the receiver recorded it
        func add(_ table: inout [String: [String: Tally]], _ a: String, _ b: String, _ m: LinkScanner.Message) {
            var t = table[a]?[b] ?? (0, "", "")
            t.count += 1
            if m.at >= t.at { t.at = m.at; t.note = m.note }
            table[a, default: [:]][b] = t
        }
        var said: [String: [(at: String, by: String)]] = [:]  // per pair: when each message went, and who sent it
        func pair(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }
        for s in sessions {
            guard let record = records[s.id] else { continue }
            for m in record.sent {
                guard let other = resolve(m), other != s.id else { continue }
                add(&sentBy, s.id, other, m)
                said[pair(s.id, other), default: []].append((m.at, s.id))
            }
            for m in record.received {
                guard let other = resolve(m), other != s.id else { continue }
                add(&gotBy, s.id, other, m)
                said[pair(s.id, other), default: []].append((m.at, other))
            }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func flow(_ from: String, _ to: String) -> Tally? {
            let a = sentBy[from]?[to], b = gotBy[to]?[from]
            guard a != nil || b != nil else { return nil }
            let latest = (a?.at ?? "") >= (b?.at ?? "") ? a : b
            return (max(a?.count ?? 0, b?.count ?? 0), latest?.at ?? "", latest?.note ?? "")
        }
        var result: [String: [Peer]] = [:]
        for s in sessions {
            var found: [Peer] = []
            for other in sessions where other.id != s.id {
                let out = flow(s.id, other.id), back = flow(other.id, s.id)
                guard out != nil || back != nil else { continue }
                let outgoing = out != nil && (out?.at ?? "") >= (back?.at ?? "")
                let latest = outgoing ? out : back
                found.append(Peer(id: other.id, sent: out?.count ?? 0, received: back?.count ?? 0,
                                  last: iso.date(from: latest?.at ?? "") ?? .distantPast, note: latest?.note ?? "",
                                  outgoing: outgoing))
            }
            if !found.isEmpty { result[s.id] = found.sorted { $0.last > $1.last } }
        }
        if result != peers { peers = result }

        // A message flies across the board once per round of conversation: when a pair that
        // has been quiet for five minutes speaks again. Nothing flies for history on launch.
        var seen = Set<String>()
        var rounds = self.rounds
        var opened: [(opener: String, partner: String)] = []  // for the notice board
        for a in sessions {
            for b in sessions where a.id < b.id {
                let forth = flow(a.id, b.id), back = flow(b.id, a.id)
                guard forth != nil || back != nil else { continue }
                let aSpoke = (forth?.at ?? "") >= (back?.at ?? "")
                let latest = (aSpoke ? forth?.at : back?.at) ?? ""
                let key = a.id + "|" + b.id
                seen.insert(key)
                let previous = lastMessageAt[key]
                lastMessageAt[key] = latest
                if linksPrimed, latest > (previous ?? ""), let round = Self.opening(said[key] ?? [], after: previous, iso: iso) {
                    rounds[key] = round
                    // Talk is news if the pair was already known, or if it began within ten minutes; a pair first seen
                    // with old talk (a session reopened, or restored at login) is history.
                    if previous != nil || scanned.timeIntervalSince(round.since) < 600 {
                        opened.append((round.opener, round.opener == a.id ? b.id : a.id))
                    }
                }
                guard linksPrimed, latest > (previous ?? ""), let now = iso.date(from: latest) else { continue }
                let quietFor = previous.flatMap { iso.date(from: $0) }.map { now.timeIntervalSince($0) } ?? .infinity
                if quietFor > 300 {
                    flights.append(Flight(from: aSpoke ? a.id : b.id, to: aSpoke ? b.id : a.id))
                }
            }
        }
        lastMessageAt = lastMessageAt.filter { seen.contains($0.key) }
        // A round goes with its pair, and once the pair has been quiet for ten minutes.
        self.rounds = rounds.filter { pair, _ in
            seen.contains(pair) && lastMessageAt[pair].flatMap { iso.date(from: $0) }.map { scanned.timeIntervalSince($0) < 600 } ?? false
        }
        // Every round that opened, even one already over by the time it was seen (the panel slept through it), once the
        // panel has watched for a minute.
        if !opened.isEmpty && settled(at: scanned) { log(OfficeActivity.talks(opened, among: sessions, at: scanned)) }
        linksPrimed = true
    }

    /// The round that the messages newer than `previous` open, if they open one: they come after ten quiet minutes, or
    /// are the pair's first. Its opener sent the first of them; of the run the latest ends, should the panel have slept
    /// through a round.
    private static func opening(_ said: [(at: String, by: String)], after previous: String?, iso: ISO8601DateFormatter) -> Round? {
        let new = said.filter { $0.at > (previous ?? "") }.sorted { $0.at < $1.at }.compactMap { m in iso.date(from: m.at).map { (at: $0, by: m.by) } }
        guard var first = new.last else { return nil }
        for m in new.reversed().dropFirst() where first.at.timeIntervalSince(m.at) < 600 { first = m }
        if let before = previous.flatMap({ iso.date(from: $0) }), first.at.timeIntervalSince(before) < 600 { return nil }  // still the same round
        return Round(opener: first.by, since: first.at)
    }

    /// What changed since the sessions were last read goes on the office's notice board, once the panel has watched for
    /// a minute: a restart, or Orca bringing the sessions back one tick after another at login, is not news.
    func noteChanges(to fresh: [Session], at now: Date) {
        if firstSeen == nil && !fresh.isEmpty { firstSeen = now }
        if settled(at: now) { log(OfficeActivity.events(from: sessions, to: fresh, at: now)) }
    }

    /// Whether a minute has passed since the panel first saw anyone.
    private func settled(at now: Date) -> Bool { firstSeen.map { now.timeIntervalSince($0) >= 60 } ?? false }

    /// Puts what just happened on the notice board, and keeps it for after a restart.
    func log(_ events: [OfficeActivity.Event]) {
        guard !events.isEmpty else { return }
        activity.add(events)
        if !readOnly { activity.save() }
    }

    /// The board's card has been shown in the office: its badge goes.
    func lookedAtBoard() {
        guard activity.unseen > 0 else { return }
        activity.looked()
        if !readOnly { activity.save() }
    }

    /// Whether a card should step back because the pointer is on a card it has not talked with.
    func isDimmed(_ id: String) -> Bool {
        guard let hovered, let partners = peers[hovered], !partners.isEmpty else { return false }
        return id != hovered && !partners.contains(where: { $0.id == id })
    }

    /// From the menu: fly one message between two sessions that have talked, to see the effect.
    func demoFlight() {
        guard let (id, partners) = peers.first(where: { !$0.value.isEmpty }), let other = partners.first else { return }
        flights.append(Flight(from: other.id, to: id))
    }
    #if TESTING
    /// For the README's moving pictures: one message flown from this session to that one, as a new message flies it.
    func demoFlight(from: String, to: String) { flights.append(Flight(from: from, to: to)) }
    #endif

    /// The name a session's pet is remembered by: its registry name; nil for one without (Codex, the apps).
    static func petName(_ s: Session) -> String? { s.registryName.isEmpty ? nil : s.registryName }

    /// Each session draws its own pet from the pool and keeps it. No two open sessions share
    /// one while the pool is big enough; pets on the favourites list are drawn first. A new session
    /// with a name that had a pet takes that pet back (after window swap), unless another open session
    /// holds it; else a new session in an Orca pane takes over the pet that pane last had, so after
    /// /clear the pet is still there.
    func assignPets() {
        // A banned pet is never dealt, kept or taken back by pane or name (unless every pet is banned).
        let pool = Pets.shared.ids, allowed = pool.filter { !bannedPets.contains($0) }
        let ids = allowed.isEmpty ? pool : allowed
        guard !ids.isEmpty else {
            // SF: no pet installed at all: every session shows the built-in flame, the same one for all. Held for the
            // panel only: not written down (nor by pane or name), so the phone's list and the pets remembered for later stay
            // as they were; once a pet is installed the next round deals as ever (the flame is not in `ids`).
            guard let flame = Pets.shared.fallback else { return }
            for s in sessions where petBySession[s.id] != flame { petBySession[s.id] = flame }
            return
        }
        let favourites = UserDefaults.standard.stringArray(forKey: "favoritePets") ?? []
        let dealt = petBySession
        // Read once a round: a lookup may finish halfway through.
        let open = sessions.map { (session: $0, pane: paneOf($0.pid)) }
        // One that has its pane's pet keeps it first: the session from before a /clear, resumed elsewhere, still has that
        // pet by its id, and must not take it from the one in the pane now.
        func holdsPane(_ o: (session: Session, pane: String?)) -> Bool {
            o.pane.flatMap { petByPane[$0] }.map { $0 == petBySession[o.session.id] } ?? false
        }
        var taken = Set<String>()
        var needing: [(session: Session, pane: String?)] = []
        for o in open.filter(holdsPane) + open.filter({ !holdsPane($0) }) {
            if let pet = petBySession[o.session.id], ids.contains(pet), !taken.contains(pet) {
                taken.insert(pet)
            } else {
                needing.append(o)
            }
        }
        // Off duty: an off-duty session is gone from the registry but its pet stays its own while it is away, so
        // nobody takes it over and it comes back to the same pet when woken (by its id, or by its name's pet).
        let here = Set(open.compactMap { Self.petName($0.session) })
        let reserved = Set(ZoneRosterFile.current().keys.filter { !here.contains($0) }.compactMap { petByName[$0] })
        // The panes' pets go before any draw, which could take one of them.
        var drawing: [Session] = []
        var waits: [String: Int] = [:]
        for (s, pane) in needing {
            if let pet = Self.petName(s).flatMap({ petByName[$0] }), ids.contains(pet), !taken.contains(pet) {
                // Its name's pet first: window swap opens it in another pane, which may still hold an older session's pet.
                petBySession[s.id] = pet
                taken.insert(pet)
            } else if let pet = pane.flatMap({ petByPane[$0] }), ids.contains(pet), !taken.contains(pet), !reserved.contains(pet) {
                petBySession[s.id] = pet
                taken.insert(pet)
            } else if pane == nil, petBySession[s.id] == nil, !readOnly, paneWaits[s.id, default: 0] < 3 {
                // No pet for a round or two, rather than one the pane's own would replace a moment later. A snapshot
                // has no next round to wait for.
                waits[s.id] = paneWaits[s.id, default: 0] + 1
            } else {
                drawing.append(s)
            }
        }
        paneWaits = waits
        for s in drawing {
            let free = ids.filter { !taken.contains($0) && !reserved.contains($0) }
            // More sessions than pets: one that already shares a pet it may have keeps it, rather than a new draw every round.
            if free.isEmpty, let had = petBySession[s.id], ids.contains(had) { continue }
            guard let pick = free.filter(favourites.contains).randomElement() ?? free.randomElement() ?? ids.randomElement()
            else { break }
            petBySession[s.id] = pick
            taken.insert(pick)
        }
        notePanes(open)
        noteNames()
        guard needing.count > waits.count, petBySession != dealt else { return }
        if petBySession.count > 400 {  // closed sessions keep their pet for a comeback, within reason
            let open = Set(sessions.map(\.id))
            petBySession = petBySession.filter { open.contains($0.key) }
        }
        save(petBySession, as: "petBySession")
    }

    /// Each open pane's pet: kept while a session in the pane still has it (with two in one pane, the first in order),
    /// else the pet of the one in it now. Closed panes keep theirs for a comeback, 400 at most; past that, the one noted
    /// first goes.
    private func notePanes(_ open: [(session: Session, pane: String?)]) {
        var petsIn: [String: Set<String>] = [:]
        for (s, pane) in open {
            if let pane, !pane.isEmpty, let pet = petBySession[s.id] { petsIn[pane, default: []].insert(pet) }
        }
        var noted = false
        for (s, pane) in open {
            guard let pane, let pets = petsIn[pane], let pet = petBySession[s.id], petByPane[pane].map(pets.contains) != true
            else { continue }
            petByPane[pane] = pet
            paneOrder.removeAll { $0 == pane }
            paneOrder.append(pane)
            noted = true
        }
        guard noted else { return }
        if petByPane.count > 400 {
            let listed = Set(paneOrder)
            // Any the order lost track of count as the oldest.
            paneOrder = petByPane.keys.filter { !listed.contains($0) }.sorted() + paneOrder.filter { petByPane[$0] != nil }
            for pane in paneOrder where petByPane.count > 400 && petsIn[pane] == nil { petByPane[pane] = nil }
            paneOrder = paneOrder.filter { petByPane[$0] != nil }
        }
        save(petByPane, as: "petByPane")
        save(paneOrder, as: "petByPaneOrder")
    }

    /// Each open session name's pet: kept while a session of that name still has it (with two of one name, the first in
    /// order), else the pet of the one with it now. Closed names keep theirs for a comeback, 400 at most; past that, the
    /// one noted first goes.
    private func noteNames() {
        var petsOf: [String: Set<String>] = [:]
        for s in sessions {
            if let name = Self.petName(s), let pet = petBySession[s.id] { petsOf[name, default: []].insert(pet) }
        }
        var noted = false
        for s in sessions {
            guard let name = Self.petName(s), let pets = petsOf[name], let pet = petBySession[s.id], petByName[name].map(pets.contains) != true
            else { continue }
            petByName[name] = pet
            nameOrder.removeAll { $0 == name }
            nameOrder.append(name)
            noted = true
        }
        guard noted else { return }
        if petByName.count > 400 {
            let listed = Set(nameOrder)
            nameOrder = petByName.keys.filter { !listed.contains($0) }.sorted() + nameOrder.filter { petByName[$0] != nil }
            for name in nameOrder where petByName.count > 400 && petsOf[name] == nil { petByName[name] = nil }
            nameOrder = nameOrder.filter { petByName[$0] != nil }
        }
        save(petByName, as: "petByName")
        save(nameOrder, as: "petByNameOrder")
    }

    /// Forget who has which pet, the panes' too, and draw afresh, e.g. after adding pets to the pool.
    func redealPets() {
        // An extension's scene that deals its own cast deals it afresh instead.
        if let scene = Extensions.active, scene.dealsCast {
            objectWillChange.send()
            scene.redeal(self)
            OfficePets.shared.prepare(Array(displayPets.values))
            return
        }
        petBySession = [:]
        petByPane = [:]
        paneOrder = []
        petByName = [:]
        nameOrder = []
        // Written now: should no open session be in a pane, nothing below would write it.
        save(petByPane, as: "petByPane")
        save(paneOrder, as: "petByPaneOrder")
        save(petByName, as: "petByName")
        save(nameOrder, as: "petByNameOrder")
        Pets.shared.refresh(force: true)
        assignPets()
    }

    /// Pets the user said not to use again (right-click → never use this pet again): never dealt from the shared pool; the menubar's
    /// Restore Hidden Pets clears them. A scene's own cast is not affected.
    var bannedPets: [String] = UserDefaults.standard.stringArray(forKey: "bannedPets") ?? []

    /// The pets this session could change to: the shared pool, less the banned, those any other open session holds,
    /// and its own.
    func freePets(for s: Session) -> [String] {
        let held = Set(sessions.filter { $0.id != s.id }.compactMap { petBySession[$0.id] })
        let own = petBySession[s.id]
        return Pets.shared.ids.filter { !bannedPets.contains($0) && !held.contains($0) && $0 != own }
    }

    /// A random free pet for this session, remembered by id, pane and name like a dealt one
    /// (the next `assignPets` keeps it: the session holds it, and its pane's and name's pet is it). Nil, and no change, when
    /// none is free; and in a scene that deals its own cast.
    @discardableResult func changePet(_ s: Session) -> String? {
        guard Extensions.active?.dealsCast != true, let pick = freePets(for: s).randomElement() else { return nil }
        petBySession[s.id] = pick
        notePanes(sessions.map { (session: $0, pane: paneOf($0.pid)) })
        noteNames()
        save(petBySession, as: "petBySession")
        if !readOnly { OfficePets.shared.prepare([pick]) }
        return pick
    }

    /// Its pet goes on the ban list (kept on disk), and it changes to a free one. Nothing
    /// happens when none is free (the menu greys the line then): it would keep the banned pet.
    @discardableResult func banPet(_ s: Session) -> String? {
        guard Extensions.active?.dealsCast != true, let pet = petBySession[s.id], !freePets(for: s).isEmpty else { return nil }
        if !bannedPets.contains(pet) { bannedPets.append(pet) }
        save(bannedPets, as: "bannedPets")
        return changePet(s)
    }

    /// The ban list is cleared; the pets may be dealt again from the next draw.
    func unbanPets() {
        bannedPets = []
        save(bannedPets, as: "bannedPets")
    }

    /// The figure's size multiplier steps, on top of the room's
    /// sizing rule; the middle one is the default.
    static let figureSizes: [CGFloat] = [0.75, 0.85, 1.0, 1.15, 1.3]
    /// Each figure's step off the default (−2…2, none kept at 0), by session name (window swap keeps it), else by id. Kept on
    /// disk, 400 at most; past that the one changed first goes, never one still open. `figureSizeOrder` is oldest first.
    private(set) var figureSteps: [String: Int] = UserDefaults.standard.dictionary(forKey: "zoneFigureSize") as? [String: Int] ?? [:]
    private var figureSizeOrder: [String] = UserDefaults.standard.stringArray(forKey: "zoneFigureSizeOrder") ?? []

    static func figureSizeKey(_ s: Session) -> String { petName(s) ?? s.id }
    func figureStep(_ s: Session) -> Int { figureSteps[Self.figureSizeKey(s)] ?? 0 }
    func figureSize(_ s: Session) -> CGFloat { Self.figureSizes[figureStep(s) + 2] }

    /// One step bigger (+1) or smaller (−1); false, and no change, at the end of the range.
    @discardableResult func resizeFigure(_ s: Session, by delta: Int) -> Bool {
        let step = figureStep(s) + delta
        guard delta != 0, abs(step) <= 2 else { return false }
        setFigureStep(s, step)
        return true
    }

    /// Back to the default size.
    func resetFigureSize(_ s: Session) { if figureStep(s) != 0 { setFigureStep(s, 0) } }

    private func setFigureStep(_ s: Session, _ step: Int) {
        let key = Self.figureSizeKey(s)
        objectWillChange.send()
        figureSteps[key] = step == 0 ? nil : step
        figureSizeOrder.removeAll { $0 == key }
        if step != 0 { figureSizeOrder.append(key) }
        if figureSteps.count > 400 {
            let open = Set(sessions.map(Self.figureSizeKey))
            for old in figureSizeOrder where figureSteps.count > 400 && !open.contains(old) { figureSteps[old] = nil }
            figureSizeOrder = figureSizeOrder.filter { figureSteps[$0] != nil }
        }
        save(figureSteps, as: "zoneFigureSize")
        save(figureSizeOrder, as: "zoneFigureSizeOrder")
    }

    /// Finished, with a result that has not been looked at.
    /// A turn another session or a subagent started is not news, however new.
    /// And not at work (background work running is not finished), the turn the user's own or a background task's
    /// report on work the user started (`bgOwned`), the time `finishedAt`.
    /// An error or an unexpected exit is not news (it has a group of its own, or none).
    func isFresh(_ s: Session) -> Bool {
        s.status == "idle" && !s.isWorking && !s.hasError && !s.isGone && Self.countsAsNews(s)
            && s.finishedAt.timeIntervalSince1970 > max(seen[s.id] ?? 0, baseline)
    }

    /// Under Error: an error (red, or the usage limit in amber) not looked at since it ended, whoever began the turn and
    /// whenever (an error is how it stands now, not news from before the launch). Looked at, it is looked-at like any other.
    func isFailed(_ s: Session) -> Bool {
        s.hasError && !s.isWorking && s.finishedAt.timeIntervalSince1970 > (seen[s.id] ?? 0)
    }

    /// Whether the turn that ended is news: the user started it; or a background task's report began it and the user started the task.
    nonisolated static func countsAsNews(_ s: Session) -> Bool { s.origin == "user" || (s.origin == "agent" && s.bgOwned && bgCountsAsWorking()) }

    /// Belongs under "Has news": fresh news, or pinned there by hand.
    /// Never an unexpected exit's, nor an error not looked at yet (that one is under Error).
    func isUnread(_ s: Session) -> Bool {
        s.status == "idle" && !s.isWorking && !s.isGone && !isFailed(s) && (pinned.contains(s.id) || isFresh(s))
    }

    /// Pin a session under "Has news", or take the pin off. Looking at a pinned session does
    /// not move it; it stays until it is answered or unpinned. Not one that exited unexpectedly.
    func togglePin(_ s: Session) {
        guard !s.isGone else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            if pinned.contains(s.id) { pinned.remove(s.id) } else { pinned.insert(s.id) }
        }
        savePins()
    }

    /// A pinned session that is working again has had its answer: the pin has done its job.
    func unpinAnswered() {
        let answered = sessions.filter { $0.status != "idle" && pinned.contains($0.id) }.map(\.id)
        guard !answered.isEmpty else { return }
        pinned.subtract(answered)
        savePins()
    }

    private func savePins() {
        if pinned.count > 200 {  // a closed session keeps its pin for a comeback, within reason
            let open = Set(sessions.map(\.id))
            pinned = pinned.filter(open.contains)
        }
        save(Array(pinned), as: "pinned")
    }

    func markSeen(_ s: Session) {
        seen[s.id] = Date().timeIntervalSince1970
        saveSeen()
    }

    /// Where the user sent a session from its menu, and when. It holds only until the session finishes another turn.
    struct Parking: Equatable {
        enum Zone: String { case desk, rest }
        let zone: Zone
        let at: TimeInterval
    }

    /// Of those finished, looked at and not pinned: whether it sits at the back rather than at a desk. That is six hours
    /// after it finished, unless the user has sent it somewhere since: to rest, for good; to a desk, for six hours from then,
    /// as a finish would.
    func isResting(_ s: Session, now: Date) -> Bool {
        if let p = parked[s.id], p.at >= s.finishedAt.timeIntervalSince1970 {
            if p.zone == .rest { return true }
            if now.timeIntervalSince1970 - p.at <= recentIdle { return false }
        }
        return now.timeIntervalSince(s.finishedAt) >= recentIdle
    }

    /// Move to Resting: the user is done with it, though it may end on a question. It rests until it finishes another turn, which is
    /// news again; a pin would keep it on a sofa, so the pin comes off.
    func rest(_ s: Session) {
        if pinned.remove(s.id) != nil { savePins() }
        park(s, .rest)
    }

    /// Move to Desk: looked at, and at a desk for six hours however long ago it finished. A pinned one is left alone: the pin
    /// is their own hold, and only taking it off moves it.
    func desk(_ s: Session) {
        guard !pinned.contains(s.id) else { return }
        park(s, .desk)
    }

    private func park(_ s: Session, _ zone: Parking.Zone) {
        let now = Date().timeIntervalSince1970
        seen[s.id] = now
        parked[s.id] = Parking(zone: zone, at: now)
        saveSeen()
        saveParked()
    }

    private func saveParked() {
        let finished = Dictionary(sessions.map { ($0.id, $0.finishedAt.timeIntervalSince1970) }, uniquingKeysWith: { first, _ in first })
        // Forget sessions that are gone, and parkings a newer turn has ended.
        parked = parked.filter { id, p in finished[id].map { p.at >= $0 } ?? false }
        save(parked.mapValues { ["zone": $0.zone.rawValue, "at": $0.at] as [String: Any] }, as: "parked")
    }

    func markAllSeen() {
        let now = Date().timeIntervalSince1970
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) {
            for s in sessions where s.status == "idle" { seen[s.id] = now }
        }
        saveSeen()
    }

    /// The phone's marks: the Duty Room WebApp's helper writes `seenAt` entries and the whole `pinned` list into these settings,
    /// so they are read again on every tick. An entry written from outside since the last look wins, later or
    /// earlier (the phone's Mark Unread writes a look older than the last reply); the pins are what is stored, since
    /// the panel writes its own the moment they change. Only a real change is published.
    func takeStored() {
        let stored = Self.numbers(UserDefaults.standard.dictionary(forKey: "seenAt"))
        let looked = Self.adopted(seen, stored: stored, before: storedSeen)
        storedSeen = stored
        if looked != seen { seen = looked }
        guard let pinsStored = UserDefaults.standard.stringArray(forKey: "pinned") else { return }
        let pins = Set(pinsStored)
        if pins != pinned { pinned = pins }
    }

    /// The panel's looks, with every entry the settings have that differs from what they had before taken over as it is.
    nonisolated static func adopted(_ mine: [String: Double], stored: [String: Double], before: [String: Double]) -> [String: Double] {
        var out = mine
        for (id, at) in stored where before[id] != at { out[id] = at }
        return out
    }

    /// The settings' numbers, of whatever kind `defaults` wrote them.
    nonisolated static func numbers(_ stored: [String: Any]?) -> [String: Double] {
        (stored ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    private func saveSeen() {
        let open = Set(sessions.map(\.id))
        // A mark the phone wrote since the last tick is kept, not written over.
        let stored = Self.numbers(UserDefaults.standard.dictionary(forKey: "seenAt"))
        seen = Self.adopted(seen, stored: stored, before: storedSeen).filter { open.contains($0.key) }  // forget sessions that are gone
        save(seen, as: "seenAt")
        storedSeen = readOnly ? stored : seen
    }

    func pose(of s: Session, now: Date = Date()) -> Pose {
        if s.status == "waiting" { return .waiting }
        if s.status == "busy" { return .working }
        if s.isBackgroundWorking { return .standing }  // It stands (the pet's idle frame) and its helper walks beside it
        if s.isGone || isFailed(s) { return .standing }  // No celebration, no wave: an exit stands faint, an error stands
        if let until = celebrating[s.id], until > now { return .celebrating }
        let idleFor = now.timeIntervalSince(s.finishedAt)
        // Waving for a minute is a greeting; waving for an hour is noise. After that the hand stays up.
        if isUnread(s) { return idleFor < 60 ? .waving : .handUp }
        return isResting(s, now: now) ? .sleeping : .standing
    }
}

// ───────── Jump to the session's tab in Orca ─────────

func run(_ path: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe  // orca reports failures on stderr
    do { try process.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

/// One line per event in panel.log in the data folder (`panelLogFile`; launchd points stderr there).
func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm:ss"
    FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(message)\n".utf8))
}

/// Brings the session's Orca tab to the front and says how it went.
func switchToTab(of session: Session) -> String {
    guard let tab = OrcaTabs.shared.tab(of: session.pid) else { return "this session was not started from Orca" }

    if let reply = orcaCall("terminal.focus", ["terminal": tab.terminal, "navigation": "host"]) {
        if (reply["ok"] as? Bool) == true { return "ok" }
        // The handle a session was started with can go stale; its tab and pane ids do not.
        let listed = orcaTerminalList(orcaCall("terminal.list", ["includeVisualLayouts": false]))?["result"]
        let terminals = (listed as? [[String: Any]]) ?? ((listed as? [String: Any])?["terminals"] as? [[String: Any]]) ?? []
        if let current = terminals.first(where: { "\($0["tabId"] ?? ""):\($0["leafId"] ?? "")" == tab.pane })?["handle"] as? String,
            (orcaCall("terminal.focus", ["terminal": current, "navigation": "host"])?["ok"] as? Bool) == true
        {
            return "ok (handle refreshed)"
        }
        let message = ((reply["error"] as? [String: Any])?["message"] as? String) ?? "refused"
        return "failed: " + message.prefix(120)
    }

    // Orca could not be reached directly (not running, or its socket moved): try its command line.
    guard let orca = orcaCommand() else { return "failed: Orca is not reachable" }
    let output = run(orca, ["terminal", "switch", "--terminal", tab.terminal])
    return output.contains("Focused") ? "ok (via command line)" : "failed: " + output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)
}

/// Brings a session of the Codex app or WorkBuddy to the front: the app opens its link at that conversation; should it not
/// take the link, the app is at least brought forward.
func openInApp(_ session: Session) -> String {
    if let url = jumpURL(session), NSWorkspace.shared.open(url) { return "ok (via url \(url.absoluteString))" }
    guard let bundle = appBundle(session), let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else {
        return "failed: the app is not running"
    }
    return app.activate() ? "ok (via activate)" : "failed: the app would not come forward"
}

/// What a click on a session does, and how it went: its tab in Orca, or its conversation in its app.
func jumpOutcome(_ session: Session) -> String { jumpURL(session) == nil ? switchToTab(of: session) : openInApp(session) }

/// `expect` (where no store is in hand) lights the session at once on the running panel's store (`Store.expectFocus`);
/// a click on a pet has done that itself and says false.
func jump(to session: Session, expect: Bool = true) {
    let mark = MainActor.assumeIsolated { JumpMark.label(name: session.shownName, cwd: session.cwd) }  // the zone ahead of the name
    if expect { MainActor.assumeIsolated { _ = Store.live?.expectFocus(session) } }
    // An app's link is handed over at once; Orca may take a while to answer, so it is asked off the main thread.
    if jumpURL(session) != nil {
        let started = Date()
        let result = openInApp(session)
        log("jump \(session.name) -> \(result) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        // The name as a watermark over the app's front window, once it has come forward.
        let bundle = appBundle(session)
        JumpMark.after(result, name: mark, pid: {
            bundle.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first?.processIdentifier }
        }, orca: false)
        return
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let started = Date()
        let result = switchToTab(of: session)
        log("jump \(session.name) -> \(result) (\(Int(Date().timeIntervalSince(started) * 1000)) ms)")
        // The name as a watermark over the pane Orca has just focused (measured 0.2 s after the focus call returned).
        JumpMark.after(result, name: mark, pid: {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.stablyai.orca").first?.processIdentifier
        }, orca: true)
    }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca") {
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

// ───────── Pets ─────────

/// Where pets come from (SF). Outside the app: petdex's own folder, then the pool beside this app (app/pets). The variable
/// `SOULGENT_PET_DIRS` (folders separated by colons; set but empty for none) stands in for those two, so that checks and
/// stills can run as on a Mac with no pets installed. Inside the app: the built-in flame (Contents/Resources/pets/soulflame),
/// dealt only while the outside pools have no pet at all.
enum PetSources {
    nonisolated static let builtInID = "soulflame"

    nonisolated static var outside: [String] {
        if DemoMode.active { return DemoMode.petDirs }  // The demonstration list only (DemoMode.pets), never the real pools
        if let list = ProcessInfo.processInfo.environment["SOULGENT_PET_DIRS"] {
            return list.split(separator: ":").map(String.init)
        }
        return [home + "/.petdex/pets", Bundle.main.bundleURL.deletingLastPathComponent().path + "/pets"]
    }

    /// The folder of the built-in pets: the app's resources; for the checks (built into app/build) the source folder.
    nonisolated static var builtIn: [String] {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("pets").path,
            binary.deletingLastPathComponent().appendingPathComponent("brand/soulgent/pet").path,
        ]
        return Array(candidates.compactMap { $0 }.filter { FileManager.default.fileExists(atPath: "\($0)/\(builtInID)/pet.json") }.prefix(1))
    }

    /// A pet's sheet in this folder (pet.json names it; most are spritesheet.webp, a few are PNG) and whether its avatar is
    /// the whole pet (`"avatar": "whole"`: a pet whose face is not at the top of its frame); nil without a sheet.
    nonisolated static func sheet(in dir: String, _ id: String) -> (path: String, whole: Bool)? {
        let fm = FileManager.default
        let json = fm.contents(atPath: "\(dir)/\(id)/pet.json").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let file = (json?["spritesheetPath"] as? String) ?? "spritesheet.webp"
        let path = "\(dir)/\(id)/\((file as NSString).lastPathComponent)"
        return fm.fileExists(atPath: path) ? (path, (json?["avatar"] as? String) == "whole") : nil
    }

    /// A pet's own size (pet.json `"scale"`, optional): what the office and the seaview multiply the size they give it
    /// by its height with. 1 without the field, or with anything but a number above 0 (at most 4). The board's standing pets
    /// are drawn by their frame, not by their height, and its avatars fit a circle, so neither takes it.
    nonisolated static func scale(in dir: String, _ id: String) -> CGFloat {
        let json = FileManager.default.contents(atPath: "\(dir)/\(id)/pet.json").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return scale(of: json)
    }

    nonisolated static func scale(of json: [String: Any]?) -> CGFloat {
        guard let number = json?["scale"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 1 }
        let value = CGFloat(number.doubleValue)
        return value.isFinite && value > 0 && value <= 4 ? value : 1
    }
}

/// Pets installed for petdex (~/.petdex/pets/<id>/): one sprite sheet of 8 columns, one row
/// per animation. Newly installed pets are picked up while the panel runs.
@MainActor final class Pets {
    /// A check swaps in one over pools of its own (SF: none at all).
    static var shared = Pets()
    private(set) var ids: [String] = []
    /// SF: the built-in pet while the pools have none (every session is dealt it); nil while there is any pet to deal.
    private(set) var fallback: String?
    private var frames: [String: CGImage] = [:]
    private var scanned = Date.distantPast

    private var sheetPaths: [String: String] = [:]
    /// Pets whose round avatar is the whole pet, fitted (pet.json `"avatar": "whole"`), rather than the top of the frame.
    private var wholeAvatars = Set<String>()
    /// petdex's own folder first, then the pool that ships beside this app (app/pets) (`PetSources.outside`).
    private let dirs: [String]
    /// SF: where the built-in pet is (`PetSources.builtIn`).
    private let builtIn: [String]

    init(dirs: [String] = PetSources.outside, builtIn: [String] = PetSources.builtIn) {
        self.dirs = dirs
        self.builtIn = builtIn
    }

    func refresh(force: Bool = false) {
        guard force || Date().timeIntervalSince(scanned) > 60 else { return }
        scanned = Date()
        let fm = FileManager.default
        var found: [String: String] = [:]
        var whole = Set<String>()
        for dir in dirs {
            for id in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where found[id] == nil && DemoMode.allows(id) {
                guard let sheet = PetSources.sheet(in: dir, id) else { continue }
                found[id] = sheet.path
                if sheet.whole { whole.insert(id) }
            }
        }
        // An extension's own cast is not in the shared pool unless it is installed as a pet of its own.
        let own = Set(Extensions.registered?.castIDs ?? [])
        // A pet whose sheet would not decode is not dealt while it waits to be tried again (so the flame can stand in).
        ids = found.keys.filter { id in
            (!own.contains(id) || dirs.contains { FileManager.default.fileExists(atPath: $0 + "/" + id + "/pet.json") }) && !broken(found[id] ?? "")
        }.sorted()
        // SF: the built-in flame's frames are always at hand (a session dealt it keeps showing it until the next deal), but it
        // is dealt only while the pool is empty; never beside an installed pet.
        fallback = nil
        let flame = PetSources.builtInID
        if found[flame] == nil, let sheet = builtIn.lazy.compactMap({ PetSources.sheet(in: $0, flame) }).first {
            found[flame] = sheet.path
            if sheet.whole { whole.insert(flame) }
            if ids.isEmpty { fallback = flame }
        }
        sheetPaths = found
        wholeAvatars = whole
    }

    /// Snapshots cut a pet's frames on the spot; the live panel does it in the background.
    var synchronous = false
    /// Called on the main thread when a pet's frames have just become available.
    var onReady: (() -> Void)?
    private var cutting = Set<String>()
    private let frameDir = cacheFolder + "/frames"
    /// Sheets that would not decode (empty, half downloaded, damaged), by path and modification time: when to try again and
    /// how many tries so far. A new file under the same path is tried at once.
    private var failed: [String: (until: Date, tries: Int)] = [:]
    /// How many times a sheet has been decoded, for a check.
    private(set) var cuts = 0
    /// The clock the wait after a failed decode is measured by; a check sets its own.
    var now: () -> Date = { Date() }

    /// The wait before a sheet that would not decode is tried again: a minute, doubling each time, at most an hour.
    nonisolated static func retryAfter(tries: Int) -> TimeInterval { min(60 * pow(2, Double(max(tries, 1) - 1)), 3600) }

    private static func stamp(_ sheet: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: sheet))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
    private static func failKey(_ sheet: String) -> String { "\(sheet)|\(stamp(sheet))" }

    /// Whether this sheet, as it is now, would not decode and is still waiting to be tried again.
    func broken(_ sheet: String) -> Bool { failed[Self.failKey(sheet)].map { now() < $0.until } ?? false }

    /// What a decode came to: a failure waits longer each time and has the pool looked at again (the pet is no longer dealt).
    private func cutDone(_ sheet: String, _ ok: Bool) {
        let key = Self.failKey(sheet)
        if ok {
            failed[key] = nil
            return
        }
        let tries = (failed[key]?.tries ?? 0) + 1
        failed[key] = (now() + Self.retryAfter(tries: tries), tries)
        scanned = .distantPast
    }

    /// One frame of a pet, or nil while its frames are still being cut.
    ///
    /// A sprite sheet is a 1536-pixel-wide WebP that takes half a second to decode. Drawing
    /// from the sheet, or even decoding it once per launch, froze the panel for many seconds
    /// with thirty different pets on screen. So each sheet is decoded once ever, off the main
    /// thread, into small PNG files, and after that only the few frames in use are loaded.
    func frame(_ id: String, row: Int, column: Int, head: Bool) -> CGImage? {
        let key = "\(id)/\(row)/\(column)/\(head)"
        if let cached = frames[key] { return cached }
        // An extension's own cast draws its frames from its own art.
        if let shown = Extensions.registered?.petFrame(id, row: row, column: column, head: head) {
            frames[key] = shown
            return shown
        }
        guard let sheet = sheetPaths[id], !broken(sheet) else { return nil }
        let stamp = Self.stamp(sheet)
        // SF: a whole-pet avatar has a folder of its own, so that the field turning up in pet.json cuts the avatars afresh.
        let whole = wholeAvatars.contains(id)
        let dir = "\(frameDir)/\(id)-\(Int(stamp))\(whole ? "-whole" : "")"
        if !FileManager.default.fileExists(atPath: dir + "/done") {
            if synchronous {
                cuts += 1
                let ok = Self.cut(sheet, into: dir, wholeAvatar: whole)
                cutDone(sheet, ok)
                guard ok else { return nil }
            } else {
                if cutting.insert(id).inserted {
                    cuts += 1
                    DispatchQueue.global(qos: .utility).async {
                        let ok = Self.cut(sheet, into: dir, wholeAvatar: whole)
                        DispatchQueue.main.async {
                            self.cutting.remove(id)
                            self.cutDone(sheet, ok)
                            if ok { self.onReady?() }
                        }
                    }
                }
                return nil
            }
        }
        frames[key] = Self.bitmap(atPath: "\(dir)/\(row)-\(column)\(head ? "h" : "").png")
        return frames[key]
    }

    /// Cuts every frame of a sheet into small PNGs: the whole pet, and its head for round avatars (SF: or, `wholeAvatar`,
    /// the whole pet fitted into the avatar, `Pets.wholeAvatar`).
    /// False for a sheet that would not decode, or is past `sheetPixels` or `sheetSide`, or too small for one row of
    /// cells (narrower than 8 pixels, or shorter than a cell); nothing is written then.
    @discardableResult nonisolated static func cut(_ sheetPath: String, into dir: String, wholeAvatar: Bool = false) -> Bool {
        // The size from the file's header, before anything is decoded; a file whose header gives none is left to the decoder.
        if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: sheetPath) as CFURL, nil),
            let o = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let pw = (o[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, let ph = (o[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
            pw > sheetSide || ph > sheetSide || pw * ph > sheetPixels
        {
            return false
        }
        // Decode the sheet once into a plain bitmap. Cropping the file-backed image instead
        // decodes the whole WebP again for each of its 144 crops: 5 s a pet instead of 0.5 s.
        guard let file = NSImage(contentsOfFile: sheetPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            file.width <= sheetSide, file.height <= sheetSide, file.width * file.height <= sheetPixels,
            let sheet = small(file, width: file.width, height: file.height)
        else { return false }
        // Frames are always 8 across and 192:208. Only the rows the panel shows are kept:
        // idle, waving, jumping, waiting, running.
        let w = sheet.width / 8, h = w * 208 / 192
        guard w >= 1, h >= 1, h <= sheet.height else { return false }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for row in [0, 3, 4, 6, 7] where (row + 1) * h <= sheet.height {
            let cells = (0..<8).map { sheet.cropping(to: CGRect(x: $0 * w, y: row * h, width: w, height: h)) }
            let fit = wholeAvatar ? avatarFit(cells.compactMap { $0 }) : nil
            for column in 0..<8 {
                let face = CGRect(x: column * w + w / 6, y: row * h + h / 20, width: w * 2 / 3, height: w * 2 / 3)
                save(small(cells[column], width: 144, height: 144 * h / w), "\(dir)/\(row)-\(column).png")
                if let fit {
                    save(fitted(cells[column], fit, side: 96), "\(dir)/\(row)-\(column)h.png")
                } else {
                    save(small(sheet.cropping(to: face), width: 96, height: 96), "\(dir)/\(row)-\(column)h.png")
                }
            }
        }
        FileManager.default.createFile(atPath: dir + "/done", contents: nil)
        return true
    }

    /// The largest sheet cut: 16384 pixels a side, 64 million pixels in all (a sheet of 192 x 208 cells, 8 x 9, has 2.9 million).
    nonisolated static let sheetSide = 16384, sheetPixels = 64 << 20

    /// SF: how a row's frames go into a whole-pet avatar: the centre of what the row draws (its frames' drawn parts together,
    /// so the pet still moves inside the avatar as it does in the row) and the scale that fits all of it in the square and
    /// in the circle the board clips avatars to, with a little room. In the frame's pixels; nil for a row with nothing drawn.
    nonisolated static func avatarFit(_ cells: [CGImage], side: Int = 96) -> (centre: CGPoint, scale: CGFloat)? {
        let drawn = cells.map { (cell: $0, alpha: alpha(of: $0)) }
        var left = Int.max, top = Int.max, right = -1, bottom = -1
        for (cell, alpha) in drawn {
            for y in 0..<cell.height {
                for x in 0..<cell.width where alpha[y * cell.width + x] >= 16 {
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                }
            }
        }
        guard right >= 0 else { return nil }
        let box = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        let centre = CGPoint(x: box.midX, y: box.midY)
        var reach: CGFloat = 0  // the farthest drawn pixel's corner from the centre
        for (cell, alpha) in drawn {
            for y in 0..<cell.height {
                for x in 0..<cell.width where alpha[y * cell.width + x] >= 16 {
                    let dx = max(abs(CGFloat(x) - centre.x), abs(CGFloat(x + 1) - centre.x))
                    let dy = max(abs(CGFloat(y) - centre.y), abs(CGFloat(y + 1) - centre.y))
                    reach = max(reach, (dx * dx + dy * dy).squareRoot())
                }
            }
        }
        let room = CGFloat(side) * 0.94
        return (centre, min(room / max(box.width, box.height), room / 2 / max(reach, 1)))
    }

    /// SF: a frame drawn into a `side`-pixel square, scaled by the fit and its drawn centre on the square's.
    nonisolated static func fitted(_ cell: CGImage?, _ fit: (centre: CGPoint, scale: CGFloat), side: Int) -> CGImage? {
        guard let cell,
            let context = CGContext(
                data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        let k = fit.scale, half = CGFloat(side) / 2
        // The context counts up from the bottom; the centre is counted down from the frame's top.
        context.draw(cell, in: CGRect(x: half - fit.centre.x * k, y: half - (CGFloat(cell.height) - fit.centre.y) * k,
                                      width: CGFloat(cell.width) * k, height: CGFloat(cell.height) * k))
        return context.makeImage()
    }

    /// A frame's alpha, row by row from the top.
    nonisolated static func alpha(of image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        data.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return stride(from: 3, to: data.count, by: 4).map { data[$0] }
    }

    /// A decoded copy at the given size. Images straight from a file decode lazily, again and
    /// again as they are drawn; one drawn into a plain bitmap is paid for once.
    nonisolated private static func small(_ image: CGImage?, width: Int, height: Int) -> CGImage? {
        guard let image,
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    nonisolated private static func save(_ image: CGImage?, _ path: String) {
        guard let image,
            let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(file, image, nil)
        CGImageDestinationFinalize(file)
    }

    nonisolated private static func bitmap(atPath path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return small(image, width: image.width, height: image.height)
    }
}

enum Pose {
    case working, waiting, celebrating, waving, handUp, standing, sleeping

    /// Row in the sprite sheet, frames in the loop, milliseconds per frame, column to show when still.
    var sheet: (row: Int, frames: Int, ms: Double, still: Int) {
        switch self {
        case .working: return (7, 6, 120, 1)
        // Waiting for you it stands still on the first frame of the row (the phone's does the same) and knocks now and then
        // (`WaitingNudge`); with the switch off it plays the row's loop.
        case .waiting: return WaitingNudge.enabled ? (6, 1, 0, 0) : (6, 6, 150, 2)
        case .celebrating: return (4, 5, 140, 2)
        case .waving: return (3, 4, 160, 2)
        case .handUp: return (3, 1, 0, 2)
        case .standing: return (0, 1, 0, 0)
        case .sleeping: return (0, 1, 0, 1)
        }
    }
}

// ───────── The waiting ones knock ─────────

/// A session waiting for you stands still and, every three seconds, knocks: the figure leans left and right for 0.45 s (the
/// phone's shake: 0, -6, +5, -3, +1.5, 0 degrees at 0, 18, 38, 58, 78 and 100 percent), then holds still. Both the
/// knock and the pause are Core Animation, started once; nothing redraws between knocks. With Reduce Motion it does not lean:
/// a ring in the "waiting" coral round the figure fades between full and a quarter strength, two seconds a round.
/// `defaults write <domain> waitingNudge -bool NO` turns it all off: the row's loop plays again, nobody knocks.
enum WaitingNudge {
    /// A check can set the switch; else the `waitingNudge` default, on when it is not there.
    static var override: Bool?
    static var enabled: Bool {
        if let override { return override }
        return UserDefaults.standard.object(forKey: "waitingNudge") == nil ? true : UserDefaults.standard.bool(forKey: "waitingNudge")
    }
    /// Reduce Motion is on; a check can say so.
    static var calm: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// One knock every `period` seconds, `knock` seconds long.
    static let period = 3.0, knock = 0.45
    /// The lean in degrees as a page writes it (clockwise is plus), at these shares of the knock.
    static let degrees: [Double] = [0, -6, 5, -3, 1.5, 0]
    static let shares: [Double] = [0, 0.18, 0.38, 0.58, 0.78, 1]
    /// cubic-bezier(.36, .07, .19, .97) between each pair of keys.
    static let easing = CAMediaTimingFunction(controlPoints: 0.36, 0.07, 0.19, 0.97)
    /// The ring's fade: between full and this much, `ringSeconds` each way (autoreversing: two seconds a round).
    static let ringLow: Float = 0.25, ringSeconds = 1.0
    static let tiltKey = "nudge", ringKey = "nudge-ring"

    /// Where in the three seconds a session's knock falls: one of six steps of half a second, from its id, the same every
    /// run. Those waiting together knock one after another, not in step.
    static func phase(of id: String) -> Double {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in id.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return Double(h % 6) * 0.5
    }

    /// Whether the coordinates the layer's own transform works in run downward on the screen: an odd number of flipped
    /// geometries among its superlayers.
    static func flipped(_ layer: CALayer) -> Bool {
        var odd = false
        var above = layer.superlayer
        while let up = above { if up.isGeometryFlipped { odd.toggle() }; above = up.superlayer }
        return odd
    }

    /// Where a figure's feet are, as a layer turning about them needs it: the point on its sprite layer that sits on the
    /// figure's origin (its feet), counted from the layer's anchor point.
    static func feetPivot(of sprite: CALayer) -> CGPoint {
        let frame = sprite.frame
        return CGPoint(x: -frame.minX - sprite.anchorPoint.x * frame.width, y: -frame.minY - sprite.anchorPoint.y * frame.height)
    }

    /// The ring round a figure drawn `wide` by `high` standing on its origin, 4 pt clear of it; `down`: the layer's y runs
    /// downward on the screen, so its head is at minus y.
    static func ringRect(wide: CGFloat, high: CGFloat, down: Bool) -> CGRect {
        CGRect(x: -(wide + 8) / 2, y: down ? -(high + 4) : -4, width: wide + 8, height: high + 8)
    }

    /// The lean as the layer's transform, about `pivot` (in the layer's own points from its anchor point). `flipped`: the
    /// coordinates run downward, where a positive turn is clockwise.
    static func tilt(pivot: CGPoint, flipped: Bool, phase: Double = 0, begin: CFTimeInterval = 0) -> CAAnimationGroup {
        let lean = CAKeyframeAnimation(keyPath: "transform")
        lean.values = degrees.map { degree -> NSValue in
            let turn = CGFloat(degree * .pi / 180) * (flipped ? 1 : -1)
            var t = CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0)
            t = CATransform3DConcat(t, CATransform3DMakeRotation(turn, 0, 0, 1))
            t = CATransform3DConcat(t, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
            return NSValue(caTransform3D: t)
        }
        lean.keyTimes = shares.map { NSNumber(value: $0) }
        lean.timingFunctions = Array(repeating: easing, count: degrees.count - 1)
        lean.duration = knock
        lean.isAdditive = true  // beside a slide's or a walk's own scaling
        let every = CAAnimationGroup()
        every.animations = [lean]  // the group runs three seconds; the knock takes the first 0.45 of them, then it holds
        every.duration = period
        every.repeatCount = .infinity
        every.timeOffset = phase
        every.beginTime = begin
        return every
    }

    /// The Reduce Motion ring's fade.
    static func pulse(phase: Double = 0, begin: CFTimeInterval = 0) -> CABasicAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = ringLow
        fade.duration = ringSeconds
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.timeOffset = phase
        fade.beginTime = begin
        return fade
    }

    /// The ring round a figure, in the coral the board calls with (`call`; the office's and the sea room's are the same).
    static func ring(rect: CGRect, corner: CGFloat, width: CGFloat) -> CAShapeLayer {
        let ring = CAShapeLayer()
        ring.name = ringKey
        ring.fillColor = nil
        ring.strokeColor = NSColor(call).cgColor
        ring.lineWidth = width
        ring.path = CGPath(roundedRect: rect, cornerWidth: min(corner, rect.width / 2), cornerHeight: min(corner, rect.height / 2), transform: nil)
        return ring
    }

    /// A pose's picture as the board shows it while waiting: the first frame of the row, on a layer that knocks (or, with
    /// Reduce Motion, wears the ring).
    struct Sprite: NSViewRepresentable {
        let image: CGImage
        let head: Bool
        let id: String

        final class KnockView: NSView {
            let art = CALayer(), ring = CAShapeLayer()
            var head = false, id = ""
            private var laidOut = CGSize.zero

            override init(frame: NSRect) {
                super.init(frame: frame)
                wantsLayer = true
                art.contentsGravity = .resizeAspect
                art.name = "art"
                ring.name = WaitingNudge.ringKey
                ring.fillColor = nil
                ring.strokeColor = NSColor(call).cgColor
                ring.isHidden = true
                layer?.addSublayer(art)
                layer?.addSublayer(ring)
            }
            required init?(coder: NSCoder) { fatalError() }

            override func layout() {
                super.layout()
                guard bounds.size != laidOut else { return }
                laidOut = bounds.size
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                art.frame = bounds
                let side = min(bounds.width, bounds.height)
                let made = WaitingNudge.ring(rect: bounds.insetBy(dx: 1.5, dy: 1.5), corner: head ? side : side * 0.2, width: head ? 2.5 : 2)
                ring.path = made.path
                ring.lineWidth = made.lineWidth
                CATransaction.commit()
                play()
            }

            /// Where the lean turns: the middle of the figure's foot line (of the avatar's lower part).
            func pivot() -> CGPoint {
                let up = WaitingNudge.flipped(art)
                let fromBottom = bounds.height * (head ? 0.15 : 0.06)
                return CGPoint(x: bounds.width / 2 - bounds.width / 2, y: (up ? bounds.height - fromBottom : fromBottom) - bounds.height / 2)
            }

            func play() {
                art.removeAnimation(forKey: WaitingNudge.tiltKey)
                ring.removeAnimation(forKey: WaitingNudge.ringKey)
                ring.isHidden = true
                guard window != nil, WaitingNudge.enabled, bounds.width > 0 else { return }
                let phase = WaitingNudge.phase(of: id)
                if WaitingNudge.calm() {
                    ring.isHidden = false
                    ring.add(WaitingNudge.pulse(phase: phase), forKey: WaitingNudge.ringKey)
                } else {
                    art.add(WaitingNudge.tilt(pivot: pivot(), flipped: WaitingNudge.flipped(art), phase: phase), forKey: WaitingNudge.tiltKey)
                }
            }

            // Layers drop their animations when they leave a window; start again on return.
            override func viewDidMoveToWindow() {
                super.viewDidMoveToWindow()
                if let scale = window?.backingScaleFactor { art.contentsScale = scale; ring.contentsScale = scale }
                play()
            }
        }

        func makeNSView(context: Context) -> KnockView {
            let view = KnockView()
            view.head = head
            view.id = id
            view.art.contents = image
            return view
        }

        func updateNSView(_ view: KnockView, context: Context) {
            view.head = head
            view.id = id
            if view.art.contents as AnyObject? !== image as AnyObject { view.art.contents = image }
        }
    }
}

// ───────── Look ─────────

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

// The dark violet comes from the outline the pets are drawn with; bubbles are a pale paper
// so that an agent with something to say is the brightest thing on the board.
let night = Color(hex: 0x1B1830)
let floorLine = Color(hex: 0x3A3560)
let paper = Color(hex: 0xE9E6F7)
let ink = Color(hex: 0x1E1A33)
let call = Color(hex: 0xFF6B4A)  // waiting for you
let work = Color(hex: 0x57D08A)  // working
let quiet = Color(hex: 0x9A96B8)
/// The Soulgent brand blue (the logo's); the title-bar switch's chosen scene and the menu-bar badge. One place to swap.
let brandBlueHex: UInt32 = 0x1F8FFF
let brandBlue = Color(hex: brandBlueHex)

/// The status line's steps: calm below half, warmer from 50 and from 70, alarm from 90.
func usageColor(_ percent: Int) -> Color {
    percent >= 90 ? call : percent >= 70 ? Color(hex: 0xE6C800) : percent >= 50 ? Color(hex: 0xFFB055) : work
}

func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
    .system(size: size, weight: weight, design: .rounded)
}

private struct ZoomKey: EnvironmentKey { static let defaultValue: CGFloat = 1 }
private struct StillKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Text and pet size multiplier, set from the menu bar item.
    var zoom: CGFloat {
        get { self[ZoomKey.self] }
        set { self[ZoomKey.self] = newValue }
    }
    /// True when rendering a snapshot: nothing animates.
    var still: Bool {
        get { self[StillKey.self] }
        set { self[StillKey.self] = newValue }
    }
}

/// How long ago, as a value: what is decided reads this, never the words; the words come from the table (`L10n`).
enum Elapsed: Equatable {
    case justNow, minutes(Int), hours(Int), days(Int)

    static func of(_ date: Date, now: Date) -> Elapsed {
        let s = Int(now.timeIntervalSince(date))
        if s < 60 { return .justNow }
        if s < 3600 { return .minutes(s / 60) }
        if s < 86400 { return .hours(s / 3600) }
        return .days(s / 86400)
    }

    var words: String {
        switch self {
        case .justNow: return L10n.string("time.justNow", table: "Board", zh: "刚刚")
        case .minutes(let n): return L10n.format("time.minutes", table: "Board", zh: "%lld 分钟", n)
        case .hours(let n): return L10n.format("time.hours", table: "Board", zh: "%lld 小时", n)
        case .days(let n): return L10n.format("time.days", table: "Board", zh: "%lld 天", n)
        }
    }
}

func ago(_ date: Date, now: Date) -> String { Elapsed.of(date, now: now).words }

func timeLabel(_ s: Session, now: Date) -> String {
    let elapsed = Elapsed.of(s.since, now: now), t = elapsed.words
    if s.status == "waiting" {
        // Claude Code's own words for what it waits on, and WorkBuddy's permission request (`WorkBuddySessions.state`).
        switch s.waitingFor {
        case "permission prompt", "permission request": return L10n.format("time.waitingApproval", table: "Board", zh: "等你批准 %@", t)
        case "input needed": return L10n.format("time.waitingAnswer", table: "Board", zh: "等你回答 %@", t)
        default: return L10n.format("time.waiting", table: "Board", zh: "等你 %@", t)
        }
    }
    if s.status == "busy" || elapsed == .justNow { return t }
    if s.isBackgroundWorking, let began = s.bgSince { return ago(began, now: now) }  // How long its work has been going
    return L10n.format("time.ago", table: "Board", zh: "%@前", t)
}

/// The narrow list's time: as `timeLabel`, but a waiting row keeps the bare time, its coral line saying what it waits on.
func inboxTime(_ s: Session, now: Date) -> String {
    s.status == "waiting" ? ago(s.since, now: now) : timeLabel(s, now: now)
}

/// Open sessions sorted into the groups both layouts show.
struct Buckets {
    var waiting: [Session] = []  // needs an answer or approval
    var unread: [Session] = []  // finished, result not looked at yet
    var busy: [Session] = []
    var seen: [Session] = []  // finished and looked at, within the last six hours
    var resting: [Session] = []  // finished and looked at, longer ago
    /// An error not looked at yet (red, or the usage limit in amber): after the waiting ones, before the news.
    var failed: [Session] = []
    /// Exited unexpectedly: a grey card under the looked-at ones; counted nowhere, never resting.
    var gone: [Session] = []

    @MainActor init(_ store: Store, now: Date) {
        for s in store.sessions {
            if s.isGone {
                gone.append(s)
            } else if s.status == "waiting" {
                waiting.append(s)
            } else if store.isFailed(s) {
                failed.append(s)
            } else if s.isWorking {
                busy.append(s)
            } else if store.isUnread(s) {
                unread.append(s)
            } else if !store.isResting(s, now: now) {
                seen.append(s)
            } else {
                resting.append(s)
            }
        }
        waiting.sort { $0.since < $1.since }
        busy.sort { $0.since < $1.since }
        // Pinned sessions lead their group: they are the ones already owed an answer.
        unread.sort { a, b in
            let pinA = store.pinned.contains(a.id), pinB = store.pinned.contains(b.id)
            return pinA != pinB ? pinA : a.since > b.since
        }
        seen.sort { $0.since > $1.since }
        resting.sort { $0.since > $1.since }
        failed.sort { $0.since > $1.since }
        gone.sort { $0.since > $1.since }
    }
}

// ───────── Views ─────────

/// Plays a pet's animation loop on a Core Animation layer, where the window server swaps
/// the frames. Driving the frames from SwiftUI re-laid out the whole board for each one:
/// a quarter of a CPU core for two running pets.
struct SpriteLoop: NSViewRepresentable {
    let frames: [CGImage]
    let frameSeconds: Double
    let key: String  // pet and pose; the loop restarts only when this changes

    final class LoopView: NSView {
        var frames: [CGImage] = []
        var frameSeconds = 0.12
        var key = ""

        func play() {
            guard let layer else { return }
            layer.removeAnimation(forKey: "loop")
            layer.contents = frames.first
            guard frames.count > 1 else { return }
            let loop = CAKeyframeAnimation(keyPath: "contents")
            loop.values = frames
            loop.calculationMode = .discrete
            loop.duration = frameSeconds * Double(frames.count)
            loop.repeatCount = .infinity
            layer.add(loop, forKey: "loop")
        }

        // Layers drop their animations when they leave a window; start again on return.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { play() }
        }
    }

    func makeNSView(context: Context) -> LoopView {
        let view = LoopView()
        view.wantsLayer = true
        view.layer?.contentsGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: LoopView, context: Context) {
        guard view.key != key else { return }
        view.key = key
        view.frames = frames
        view.frameSeconds = frameSeconds
        view.play()
    }
}

/// Where each session's pet and card are on the board, reported up by the cards themselves.
struct PetSpots: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CardSpots: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Knows better than a list of frames which card is at a point (window coordinates).
@MainActor protocol HoverResolver: AnyObject {
    func card(at point: CGPoint) -> String?
}

/// Works out which card the pointer is on. SwiftUI's own hover only fires in the active
/// window, and this panel floats over another app and is never that; so the window's view
/// reports pointer positions itself and they are matched against the cards' frames here.
/// Only a change of card is published, so moving the mouse costs nothing to draw.
@MainActor final class HoverTracker {
    var frames: [String: CGRect] = [:]  // in window coordinates
    weak var store: Store?
    /// Set while the office shows: its pets can overlap, and the one in front is the one meant.
    /// The board's cards never overlap, so it leaves this empty and the frames decide.
    weak var resolver: HoverResolver?

    func card(at point: CGPoint) -> String? {
        if let resolver { return resolver.card(at: point) }
        return frames.first(where: { $0.value.contains(point) })?.key
    }

    func pointer(at point: CGPoint?) {
        let id = point.flatMap(card(at:))
        if store?.hovered != id { store?.hovered = id }
    }
}

/// The way from one pet to another, kept to the gaps between the cards so that it crosses no
/// text: out at the pet's feet, along the gap under its row, along the gap left of the other
/// pet's column, and in at that pet's side. Two pets in one column are joined through the gap
/// on their left.
enum Trail {
    /// The route's turning points, `gap` away from the pets.
    static func corners(_ a: CGRect, _ b: CGRect, gap: CGFloat) -> [CGPoint] {
        let aisle = b.minX - gap
        let arrival = [CGPoint(x: aisle, y: b.midY), CGPoint(x: b.minX, y: b.midY)]
        if abs(a.minX - b.minX) < 1 {
            return [CGPoint(x: a.minX, y: a.midY), CGPoint(x: aisle, y: a.midY)] + arrival
        }
        let under = a.maxY + gap
        return [CGPoint(x: a.midX, y: a.maxY), CGPoint(x: a.midX, y: under), CGPoint(x: aisle, y: under)] + arrival
    }

    /// Straight from edge to edge, for a pet that stands outside the grid of cards.
    static func direct(_ a: CGRect, _ b: CGRect) -> [CGPoint] {
        let from = CGPoint(x: a.midX, y: a.midY), to = CGPoint(x: b.midX, y: b.midY)
        let dx = to.x - from.x, dy = to.y - from.y
        let length = (dx * dx + dy * dy).squareRoot()
        let inA = min(a.width, a.height) / 2, inB = min(b.width, b.height) / 2
        guard length > (inA + inB) * 1.5 else { return [from, to] }
        return [
            CGPoint(x: from.x + dx / length * inA, y: from.y + dy / length * inA),
            CGPoint(x: to.x - dx / length * inB, y: to.y - dy / length * inB),
        ]
    }

    /// Halfway along the route: the point, and the direction of travel there.
    static func halfway(_ corners: [CGPoint]) -> (point: CGPoint, heading: CGFloat) {
        let legs = zip(corners, corners.dropFirst()).map { (from: $0, to: $1, length: hypot($1.x - $0.x, $1.y - $0.y)) }
        var left = legs.reduce(0) { $0 + $1.length } / 2
        for leg in legs where leg.length > 0 {
            if left <= leg.length {
                let t = left / leg.length
                return (
                    CGPoint(x: leg.from.x + (leg.to.x - leg.from.x) * t, y: leg.from.y + (leg.to.y - leg.from.y) * t),
                    atan2(leg.to.y - leg.from.y, leg.to.x - leg.from.x)
                )
            }
            left -= leg.length
        }
        return (corners.last ?? .zero, 0)
    }

    /// The route as a line, its corners rounded.
    static func path(_ corners: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard let first = corners.first, let last = corners.last else { return path }
        path.move(to: first)
        for (corner, next) in zip(corners.dropFirst(), corners.dropFirst(2)) {
            path.addArc(tangent1End: corner, tangent2End: next, radius: radius)
        }
        path.addLine(to: last)
        return path
    }
}

/// A small plane seen from above, nose to the right.
struct Plane: Shape {
    /// The outline around the origin, `size` long.
    static func outline(_ size: CGFloat) -> CGPath {
        // One side from nose to tail, in units of the plane's length; the other side mirrors it.
        let side: [(CGFloat, CGFloat)] = [
            (0.36, 0.07), (0.12, 0.07), (-0.14, 0.47), (-0.26, 0.47), (-0.12, 0.07), (-0.33, 0.06), (-0.43, 0.21),
            (-0.5, 0.21), (-0.46, 0),
        ]
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0.5 * size, y: 0))
        for (x, y) in side { path.addLine(to: CGPoint(x: x * size, y: y * size)) }
        for (x, y) in side.reversed().dropFirst() { path.addLine(to: CGPoint(x: x * size, y: -y * size)) }
        path.closeSubpath()
        return path
    }

    /// The plane for Core Animation to fly, drawn around the layer's position.
    static func layer(_ size: CGFloat) -> CAShapeLayer {
        let plane = CAShapeLayer()
        plane.name = "plane"
        plane.path = outline(size)
        plane.fillColor = NSColor(paper).cgColor
        plane.shadowColor = NSColor(night).cgColor
        plane.shadowRadius = 1.5
        plane.shadowOpacity = 1
        plane.shadowOffset = .zero
        return plane
    }

    func path(in rect: CGRect) -> Path {
        Path(Plane.outline(min(rect.width, rect.height))).offsetBy(dx: rect.midX, dy: rect.midY)
    }
}

/// While the pointer rests on a card: a dashed route to each session it has talked with, and a
/// small plane on it, nose toward whoever got the latest message. Talk from the last ten
/// minutes keeps its plane flying; older talk leaves it parked halfway.
struct LinkLines: View {
    /// The way from one session's pet to another's, when both are on the board.
    let route: (String, String) -> [CGPoint]?
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z
    @Environment(\.still) private var still

    struct Route: Identifiable {
        let id: String
        let corners: [CGPoint]
        let live: Bool
    }

    var body: some View {
        if let id = store.hovered, let partners = store.peers[id] {
            let now = Date()
            let routes: [Route] = partners.compactMap { peer in
                (peer.outgoing ? route(id, peer.id) : route(peer.id, id)).map {
                    Route(id: peer.id, corners: $0, live: peer.isRecent(now))
                }
            }
            ZStack {
                ForEach(routes) { route in
                    Path(Trail.path(route.corners, radius: 4 * z))
                        .stroke(
                            paper.opacity(route.live ? 0.85 : 0.55),
                            style: StrokeStyle(lineWidth: 1.3 * z, lineCap: .round, dash: [4 * z, 5 * z]))
                    if still || !route.live {
                        let middle = Trail.halfway(route.corners)
                        Plane().fill(paper).frame(width: 13 * z, height: 13 * z)
                            .shadow(color: night, radius: 1.5)
                            .rotationEffect(.radians(middle.heading))
                            .position(middle.point)
                            .opacity(route.live ? 1 : 0.75)
                    }
                }
                if !still {
                    PlaneLoops(routes: routes.filter(\.live).map(\.corners), radius: 4 * z, size: 13 * z)
                }
            }
            .transition(.opacity)
        }
    }
}

/// Planes flying their routes over and over while the pointer stays on a card. Core Animation
/// moves them, so the board is not redrawn.
struct PlaneLoops: NSViewRepresentable {
    let routes: [[CGPoint]]
    let radius: CGFloat
    let size: CGFloat

    final class Canvas: NSView {
        var radius: CGFloat = 4
        var size: CGFloat = 13
        var routes: [[CGPoint]] = [] {
            didSet { if routes != oldValue { needsLayout = true } }
        }
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        // By the time a view is laid out it is in its window, and its layer's coordinates are settled.
        override func layout() {
            super.layout()
            guard let board = layer else { return }
            board.sublayers?.forEach { $0.removeFromSuperlayer() }
            for route in routes where route.count > 1 { board.addSublayer(plane(on: route)) }
        }

        private func plane(on route: [CGPoint]) -> CALayer {
            let corners = route.map { convertToLayer($0) }  // from the board's coordinates into the layer's
            let plane = Plane.layer(size)
            plane.position = corners[corners.count - 1]
            plane.opacity = 0  // between flights

            let length = zip(corners, corners.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let flight = min(3.6, max(1.4, Double(length) / 150))
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = Trail.path(corners, radius: radius)
            move.rotationMode = .rotateAuto  // nose along the route
            move.calculationMode = .paced
            move.duration = flight
            let shown = CAKeyframeAnimation(keyPath: "opacity")
            shown.values = [0, 1, 1, 0]
            shown.keyTimes = [0, 0.1, 0.9, 1]
            shown.duration = flight
            let loop = CAAnimationGroup()
            loop.animations = [move, shown]
            loop.duration = flight + 0.5  // a breath before the next departure
            loop.repeatCount = .infinity
            plane.add(loop, forKey: "loop")
            return plane
        }
    }

    func makeNSView(context: Context) -> Canvas {
        let view = Canvas()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: Canvas, context: Context) {
        view.radius = radius
        view.size = size
        view.routes = routes
    }
}

/// A message on its way: the plane flies its route once, sender to receiver, drawing the dashed
/// line behind it, and a ring opens where it lands. Drawn with Core Animation, so the board is
/// not redrawn while it moves.
struct FlightLayer: NSViewRepresentable {
    #if TESTING
    /// For the README's moving pictures, played slowed: how many times longer the flown pieces stay before they are taken away.
    nonisolated(unsafe) static var demoStretch = 1.0
    #endif
    struct Trip: Equatable {
        let id: UUID
        let corners: [CGPoint]
    }
    let trips: [Trip]
    let z: CGFloat

    final class Canvas: NSView {
        var z: CGFloat = 1
        private var played = Set<UUID>()
        private var waiting: [Trip] = []
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func offer(_ trips: [Trip]) {
            let fresh = trips.filter { $0.corners.count > 1 && played.insert($0.id).inserted }
            guard !fresh.isEmpty else { return }
            waiting += fresh
            needsLayout = true
        }

        // By the time a view is laid out it is in its window, and its layer's coordinates are settled.
        override func layout() {
            super.layout()
            for trip in waiting { fly(trip) }
            waiting = []
        }

        private func fly(_ trip: Trip) {
            guard let board = layer else { return }
            let light = NSColor(paper).cgColor
            let corners = trip.corners.map { convertToLayer($0) }  // from the board's coordinates into the layer's
            let landing = corners[corners.count - 1]
            let path = Trail.path(corners, radius: 4 * z)
            let length = zip(corners, corners.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
            let travel = min(2.6, max(1.1, Double(length) / 260))
            let glide = CAMediaTimingFunction(name: .easeInEaseOut)

            let trail = CAShapeLayer()
            trail.path = path
            trail.fillColor = nil
            trail.strokeColor = light
            trail.lineWidth = 1.3 * z
            trail.lineCap = .round
            trail.lineDashPattern = [NSNumber(value: 4 * z), NSNumber(value: 5 * z)]
            trail.opacity = 0  // where it rests when the animations end: gone
            let drawn = CABasicAnimation(keyPath: "strokeEnd")
            drawn.fromValue = 0
            drawn.toValue = 1
            drawn.duration = travel
            drawn.timingFunction = glide
            let lingers = CAKeyframeAnimation(keyPath: "opacity")
            lingers.values = [0.8, 0.8, 0]
            lingers.keyTimes = [0, NSNumber(value: travel / (travel + 0.7)), 1]
            lingers.duration = travel + 0.7
            let trailMoves = CAAnimationGroup()
            trailMoves.animations = [drawn, lingers]
            trailMoves.duration = travel + 0.7
            trail.add(trailMoves, forKey: "trail")

            let plane = Plane.layer(13 * z)
            plane.position = landing
            plane.opacity = 0  // landed and gone
            let move = CAKeyframeAnimation(keyPath: "position")
            move.path = path
            move.rotationMode = .rotateAuto  // nose along the route
            move.calculationMode = .paced
            move.duration = travel
            move.timingFunction = glide
            let shown = CAKeyframeAnimation(keyPath: "opacity")
            shown.values = [1, 1, 0]
            shown.keyTimes = [0, 0.93, 1]
            shown.duration = travel
            plane.add(move, forKey: "move")
            plane.add(shown, forKey: "shown")

            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18), transform: nil)
            ring.position = landing
            ring.fillColor = nil
            ring.strokeColor = light
            ring.lineWidth = 1.5
            ring.opacity = 0
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.4
            grow.toValue = 2.4
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.9
            fade.toValue = 0
            let opens = CAAnimationGroup()
            opens.animations = [grow, fade]
            opens.beginTime = CACurrentMediaTime() + travel - 0.05
            opens.duration = 0.6
            opens.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(opens, forKey: "landing")

            for piece in [trail, plane, ring] { board.addSublayer(piece) }
            #if TESTING
            let cleanup = (travel + 0.9) * FlightLayer.demoStretch
            #else
            let cleanup = travel + 0.9
            #endif
            DispatchQueue.main.asyncAfter(deadline: .now() + cleanup) {
                for piece in [trail, plane, ring] { piece.removeFromSuperlayer() }
            }
        }
    }

    func makeNSView(context: Context) -> Canvas {
        let view = Canvas()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: Canvas, context: Context) {
        view.z = z
        view.offer(trips)
    }
}

struct PetSprite: View {
    let pet: String?
    let pose: Pose
    let size: CGFloat
    var head = false
    /// The session it stands for: where in the three seconds its knock falls (`WaitingNudge.phase`).
    var knockID = ""
    @Environment(\.still) private var still

    var body: some View {
        let sheet = pose.sheet
        let height = head ? size : size * 208 / 192
        if sheet.frames > 1 && !still, let pet {
            SpriteLoop(
                frames: (0..<sheet.frames).compactMap { Pets.shared.frame(pet, row: sheet.row, column: $0, head: head) },
                frameSeconds: sheet.ms / 1000, key: "\(pet)/\(sheet.row)/\(head)"
            )
            .frame(width: size, height: height)
            .allowsHitTesting(false)  // clicks belong to the card around it
        } else if let pet, let image = Pets.shared.frame(pet, row: sheet.row, column: sheet.still, head: head) {
            if pose == .waiting && WaitingNudge.enabled && !still {
                // Waiting for you: the still frame on a layer that knocks (a picture shows it still, below).
                WaitingNudge.Sprite(image: image, head: head, id: knockID.isEmpty ? pet : knockID)
                    .frame(width: size, height: height).allowsHitTesting(false)
            } else {
                Image(decorative: image, scale: 1).resizable().interpolation(.high).frame(width: size, height: height)
            }
        } else {
            Circle().fill(floorLine).frame(width: size * 0.6, height: size * 0.6).frame(width: size, height: height)
        }
    }
}

/// A whole pet standing on its shadow.
struct StandingPet: View {
    let pet: String?
    let pose: Pose
    let size: CGFloat
    var knockID = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            Ellipse().fill(Color.black.opacity(0.4)).frame(width: size * 0.62, height: size * 0.13).offset(y: 1)
            PetSprite(pet: pet, pose: pose, size: size, knockID: knockID)
        }
    }
}

struct BubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The spinner on the card of a session being restarted: its ring turns on Core Animation, as `SpriteLoop`'s
/// frames do; a picture shows it still.
struct RestartBadge: View {
    let size: CGFloat
    @Environment(\.still) private var still

    var body: some View {
        if still, let image = RestartSpinner.picture(side: size) {
            Image(decorative: image, scale: RestartSpinner.pixels).resizable().frame(width: size, height: size)
        } else {
            RestartTurning(side: size).frame(width: size, height: size).allowsHitTesting(false)
        }
    }
}

struct RestartTurning: NSViewRepresentable {
    let side: CGFloat

    final class TurningView: NSView {
        var side: CGFloat = 0

        func show() {
            guard let layer, side > 0 else { return }
            let spinner = RestartSpinner.layer(side: side)
            layer.sublayers = [spinner]
            RestartSpinner.spin(spinner, window != nil && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }

        // Layers drop their animations when they leave a window; start again on return.
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            show()
        }
    }

    func makeNSView(context: Context) -> TurningView {
        let view = TurningView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: TurningView, context: Context) {
        guard view.side != side else { return }
        view.side = side
        view.show()
    }
}

/// Three dots beside a working agent, like a chat's "typing" mark. They stay still:
/// the running pet is the motion.
/// "⚙ 3" on a board card: how many subagents its session has running (`Store.agentCounts`, the office's little people).
struct SubagentMark: View {
    let count: Int
    let z: CGFloat

    var body: some View {
        Text("⚙ \(count)").font(rounded(10.5 * z, .medium)).foregroundStyle(work).fixedSize().help(L10n.format("subagents.running", table: "Plurals", zh: "有 %lld 个子代理在跑", count))
    }
}

/// What a card says of its helpers: for a session whose work runs in the background, a walker on a short lane and
/// "Background N" (grey, standing, for the hung kind); else "⚙ N", the count of `Store.helpers` (running subagents and background
/// ones, not counted twice).
@MainActor @ViewBuilder func helperMark(_ s: Session, _ store: Store, z: CGFloat, narrow: Bool) -> some View {
    if s.isBackgroundWorking || s.isBackgroundHung {
        HStack(alignment: .firstTextBaseline, spacing: 3 * z) {
            BGWalkerLane(pet: store.walkerPets(of: s).first ?? ZoneSubagentFigures.claudePet, lane: (narrow ? 44 : 48) * z, tall: 18 * z,
                         hung: s.isBackgroundHung, seed: s.id)
            Text(bgCountWords(s.bgTasks)).font(rounded(10.5 * z, .medium)).foregroundStyle(s.isBackgroundHung ? quiet : work).fixedSize()
        }
        .help(s.isBackgroundHung ? bgHungWords() : bgCountWords(s.bgTasks))
    } else {
        let n = store.helpers(of: s)
        if n > 0 { SubagentMark(count: n, z: z) }
    }
}

/// The walker on a card or row: a lane `lane` points wide, a figure `tall` points high going along it and back. Live: one
/// layer with two animations that repeat (`BGWalker`), nothing redrawn; in a snapshot, with Reduce Motion, or hung: one frame.
struct BGWalkerLane: View {
    let pet: String
    let lane: CGFloat
    let tall: CGFloat
    var hung = false
    let seed: String
    @Environment(\.still) private var still
    @Environment(\.accessibilityReduceMotion) private var calm

    var body: some View {
        Group {
            if still || calm || hung { frame } else { BGLaneLayer(pet: pet, lane: lane, tall: tall, phase: zoneFXSeed(seed, salt: 0xB6)) }
        }
        .frame(width: lane, height: tall)
        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
    }

    /// One frame: hung, or with Reduce Motion, standing in the middle; in a snapshot, where its walk is at `BGWalker.stillTime`.
    @ViewBuilder private var frame: some View {
        if let cut = BGWalker.cut(pet, tall: tall) {
            let walking = still && !hung && !calm
            let round = BGWalker.cycle(lane: max(1, lane - cut.inkWide))
            let st = BGWalker.state(at: BGWalker.stillTime + zoneFXSeed(seed, salt: 0xB6) * round, cycle: round)
            let image = (walking ? BGWalker.runFrame(cut, right: st.right, column: st.column) : nil) ?? cut.idle.image
            let u: CGFloat = walking ? st.u : 0.5
            let foot = cut.inkWide / 2 + max(0, lane - cut.inkWide) * u
            ZStack(alignment: .bottomLeading) {
                Color.clear
                Image(decorative: hung ? BGWalker.gray(image, pet: pet) : image, scale: 1).resizable().interpolation(.high)
                    .frame(width: cut.cell.width, height: cut.cell.height).opacity(hung ? Double(BGWalker.hungOpacity) : 1)
                    .offset(x: foot - cut.centre, y: cut.cell.height - cut.feetBelowTop - 1)
            }
        } else {
            Color.clear
        }
    }
}

/// The live walker: a layer view (the pet's cells are animated by the render server; see `BGWalker.layer`).
struct BGLaneLayer: NSViewRepresentable {
    let pet: String
    let lane: CGFloat
    let tall: CGFloat
    let phase: Double

    final class LaneView: NSView {
        var spec = ""
        var pet = "", lane: CGFloat = 0, tall: CGFloat = 0, phase = 0.0
        private var built = ""

        /// Made again when the spec changes, when the pet's frames come in after the first try, and on return to a window (a layer
        /// drops its animations when it leaves one).
        func build() {
            guard let layer else { return }
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            built = ""
            guard let cut = BGWalker.cut(pet, tall: tall) else { return }
            let from = CGPoint(x: cut.inkWide / 2, y: 1), to = CGPoint(x: max(cut.inkWide / 2, lane - cut.inkWide / 2), y: 1)
            guard let walker = BGWalker.layer(cut, from: from, to: to, yDown: false, mode: .walks, phase: phase, rest: 0) else { return }
            layer.addSublayer(walker)
            built = spec
        }

        func refresh() { if built != spec { build() } }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { build() }
        }
    }

    func makeNSView(context: Context) -> LaneView {
        let view = LaneView()
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: LaneView, context: Context) {
        let spec = "\(pet) \(lane) \(tall) \(phase)"
        view.pet = pet; view.lane = lane; view.tall = tall; view.phase = phase
        view.spec = spec
        view.refresh()
    }
}

struct WorkingDots: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: size * 0.6) {
            ForEach(0..<3, id: \.self) { i in
                Circle().fill(work.opacity(1 - Double(i) * 0.3)).frame(width: size, height: size)
            }
        }
    }
}

/// A card dims while pressed, so a click visibly registers before Orca comes forward.
/// The mark on a session pinned under "Has news".
struct PinMark: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "pin.fill").font(.system(size: size, weight: .semibold)).rotationEffect(.degrees(40))
            .foregroundStyle(call)
    }
}

/// What a card's tooltip says: a click jumps; a right-click opens the menu every session has, whatever it is doing.
/// A pet on the rest bench: its project and summary, then what a card's tooltip says.
@MainActor func benchHelp(_ s: Session, _ store: Store) -> String {
    (s.summary.isEmpty ? s.project : s.project + "\n" + s.shownSummary) + "\n" + cardHelp(s, store)
}

@MainActor func cardHelp(_ s: Session, _ store: Store) -> String {
    let pinned = s.status == "idle" && store.pinned.contains(s.id) ? "\n" + L10n.string("card.help.pinned", table: "Board", zh: "已标记待回复：回了话会自动取消") : ""
    // Which agent, when it is not Claude Code: the tag on the card is one word. The two apps' sessions open in the app.
    let model = store.model(of: s).map { L10n.format("card.help.model", table: "Board", zh: "，模型 %@", $0) } ?? ""
    let (place, kind): (String, String)
    switch s.kind {
    case "codex": (place, kind) = ("Orca", "\n" + L10n.string("card.help.codex", table: "Board", zh: "这是 Codex CLI 会话") + model)
    case "codexApp": (place, kind) = ("Codex App", "\n" + L10n.string("card.help.codexApp", table: "Board", zh: "这是 Codex App 的会话") + model)
    case "workbuddy": (place, kind) = ("WorkBuddy", "\n" + L10n.string("card.help.workbuddy", table: "Board", zh: "这是 WorkBuddy 的会话") + model)
    default: (place, kind) = ("Orca", "")
    }
    return L10n.format("card.help.click", table: "Board", zh: "点一下跳到 %@ 里的这个会话", place) + kind + pinned + "\n" + L10n.string("card.help.rightClick", table: "Board", zh: "右键打开菜单：跳到会话、标记或取消待回复、转到工位或休息区、在访达里打开项目目录")
}

/// The word after a session's name that says which agent it is: small and quiet, in a hairline frame, so that it reads as a
/// tag and not as the start of the project beside it.
struct KindTag: View {
    let text: String
    let z: CGFloat

    var body: some View {
        Text(text).font(rounded(9 * z, .semibold)).opacity(0.65).padding(.horizontal, 3 * z)
            .overlay(RoundedRectangle(cornerRadius: 3 * z, style: .continuous).strokeBorder(lineWidth: 0.75).opacity(0.35))
            .fixedSize()
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// How an error, a retry or an unexpected exit is drawn, on every screen: an error not looked at in brick
/// red with white words, the usage limit (not looked at) and a retry in amber with dark words, an exit grey and faint.
enum FailTone: Equatable {
    case red, amber, gone
    var hex: UInt32 { self == .red ? failRedHex : self == .amber ? failAmberHex : goneGreyHex }
    var color: Color { Color(hex: hex) }
}

extension Store {
    /// The tone a session is drawn in; nil for none (and always with `showFailed` off). An error looked at is drawn as
    /// any looked-at session is.
    func failTone(_ s: Session) -> FailTone? {
        if s.isGone { return .gone }
        if s.isRetrying { return .amber }
        if isFailed(s) { return s.errorKind == "rate_limit" ? .amber : .red }
        return nil
    }
}

/// The small round badge on a pet's corner: ! for an error, a turning arrow for a retry or the limit, × for an exit.
struct FailBadge: View {
    let tone: FailTone
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().fill(tone.color)
            switch tone {
            case .red: Text("!").font(.system(size: size * 0.78, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            case .amber: Image(systemName: "arrow.clockwise").font(.system(size: size * 0.58, weight: .heavy)).foregroundStyle(ink)
            case .gone: Image(systemName: "xmark").font(.system(size: size * 0.5, weight: .heavy)).foregroundStyle(night)
            }
        }
        .frame(width: size, height: size).overlay(Circle().stroke(night, lineWidth: 1.5))
    }
}

/// Wide layout: a pet with a speech bubble.
struct AgentCard: View {
    let s: Session
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    /// The name line: name, tag, project, then at the right what its helpers are doing and how long it has been.
    @ViewBuilder private func cardHeader(now: Date, project: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * z) {
            Text(s.shownName).font(rounded(13 * z)).lineLimit(1)
                .layoutPriority(1)  // The project gives way first, not the name
            if let tag = kindTag(s) { KindTag(text: tag, z: z) }
            if project { Text(s.project).font(.system(size: 10.5 * z)).opacity(0.6).lineLimit(1) }
            Spacer(minLength: 0)
            helperMark(s, store, z: z, narrow: false)
            if s.status == "busy" { WorkingDots(size: 5 * z) }
            if s.status == "idle" && store.pinned.contains(s.id) { PinMark(size: 10 * z) }
            // In a language whose words run long ("Needs approval · 7m") the bare time stands in when the whole does not fit,
            // so the name is not cut for it.
            ViewThatFits(in: .horizontal) {
                Text(timeLabel(s, now: now)).font(rounded(10.5 * z, .medium)).opacity(s.status == "waiting" ? 1 : 0.6).fixedSize()
                Text(inboxTime(s, now: now)).font(rounded(10.5 * z, .medium)).opacity(s.status == "waiting" ? 1 : 0.6).fixedSize()
            }
            .layoutPriority(0.5)
        }
    }

    var body: some View {
        let now = Date()
        let unread = store.isUnread(s)
        let tone = store.failTone(s)
        // A waiting agent calls in coral; one with unread news speaks on bright paper;
        // a working one murmurs; one whose news has been read falls quiet.
        // An error in brick red (white words), a retry or the limit in amber (dark words), an exit grey and quiet.
        let fill: Color =
            tone == .red || tone == .amber ? tone!.color : tone == .gone ? Color.white.opacity(0.05)
            : s.status == "waiting" ? call : s.isWorking ? Color.white.opacity(0.09) : unread ? paper : Color.white.opacity(0.05)
        let text: Color = tone == .red ? .white : tone == .amber ? ink : tone == .gone ? quiet
            : s.isWorking ? .white : (s.status == "idle" && !unread) ? quiet : ink

        Button {
            store.markSeen(s)
            jump(to: s)
        } label: {
            HStack(alignment: .bottom, spacing: 0) {
                StandingPet(pet: store.displayPets[s.id], pose: store.pose(of: s, now: now), size: 50 * z, knockID: s.id)
                    .opacity(tone == .gone ? 0.45 : 1)
                    .overlay(alignment: .topTrailing) {
                        if s.restarting { RestartBadge(size: 16 * z).offset(x: 2 * z) }
                        else if let tone { FailBadge(tone: tone, size: 15 * z).offset(x: 2 * z, y: 2 * z) }
                    }
                    .anchorPreference(key: PetSpots.self, value: .bounds) { [s.id: $0] }
                BubbleTail().fill(fill).frame(width: 7 * z, height: 12 * z).padding(.bottom, 20 * z)
                VStack(alignment: .leading, spacing: 3 * z) {
                    // A card with work in the background: when the project does not fit beside the name it goes, the name stays.
                    // And an error's, a retry's or an exit's.
                    if s.isBackgroundWorking || s.isBackgroundHung || tone != nil {
                        ViewThatFits(in: .horizontal) {
                            cardHeader(now: now, project: true)
                            cardHeader(now: now, project: false)
                        }
                    } else {
                        cardHeader(now: now, project: true)
                    }
                    if s.isBackgroundHung { Text(bgHungWords()).font(.system(size: 10.5 * z)).opacity(0.75).lineLimit(1) }
                    if !s.summary.isEmpty {
                        Text(s.shownSummary).font(.system(size: 11.5 * z)).lineSpacing(1.5 * z).opacity(0.9)
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    }
                    if let note = originNote(s) { Text(note).font(.system(size: 10.5 * z)).opacity(0.5).lineLimit(1) }
                    if let peers = store.peers[s.id] { LinksRow(peers: peers, now: now) }
                }
                .foregroundStyle(text)
                .padding(.vertical, 8 * z).padding(.horizontal, 10 * z)
                .frame(maxWidth: .infinity, minHeight: 54 * z, maxHeight: .infinity, alignment: .topLeading)
                .background(fill)
                .clipShape(RoundedRectangle(cornerRadius: 13 * z, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13 * z, style: .continuous)
                        .stroke(Color.white.opacity(store.hovered == s.id ? 0.5 : 0), lineWidth: 1.5))
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle())
            .anchorPreference(key: CardSpots.self, value: .bounds) { [s.id: $0] }
        }
        .buttonStyle(PressStyle())
        .frame(maxHeight: .infinity)
        .opacity(store.isDimmed(s.id) ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: store.hovered)
        .help(cardHelp(s, store))
        .transition(.scale(scale: 0.92).combined(with: .opacity))
    }
}

/// Under an agent's words: the other open sessions it has talked with.
/// "→" it wrote to them, "←" they wrote to it, "⇄" both ways. Talk in the last ten minutes
/// shows at full strength, older talk is faint.
struct LinksRow: View {
    let peers: [Peer]
    let now: Date
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    var body: some View {
        HStack(spacing: 9 * z) {
            ForEach(peers.prefix(3), id: \.id) { peer in
                if let other = store.sessions.first(where: { $0.id == peer.id }) {
                    HStack(spacing: 3 * z) {
                        Text(peer.sent > 0 && peer.received > 0 ? "⇄" : peer.sent > 0 ? "→" : "←")
                            .font(.system(size: 10.5 * z, weight: .bold))
                        PetSprite(pet: store.displayPets[peer.id], pose: .standing, size: 15 * z, head: true)
                            .clipShape(Circle())
                        Text(other.shownName).font(.system(size: 10.5 * z)).lineLimit(1)
                    }
                    .opacity(peer.isRecent(now) ? 1 : 0.6)
                    .help(L10n.format("peer.help", table: "Board", zh: "发给它 %lld 条，收到它 %lld 条，最近一次在 %@前", peer.sent, peer.received, ago(peer.last, now: now)) + (peer.note.isEmpty ? "" : L10n.string("peer.help.sep", table: "Board", zh: "：") + peer.note))
                }
            }
            if peers.count > 3 { Text("+\(peers.count - 3)").font(.system(size: 10.5 * z)).opacity(0.6) }
        }
        .padding(.top, 1 * z)
    }
}

struct CardRows: View {
    let items: [Session]
    let columns: Int
    @Environment(\.zoom) private var z

    var body: some View {
        VStack(spacing: 10 * z) {
            ForEach(Array(stride(from: 0, to: items.count, by: columns)), id: \.self) { start in
                HStack(alignment: .bottom, spacing: 10 * z) {
                    ForEach(Array(items[start..<min(start + columns, items.count)])) { AgentCard(s: $0) }
                    // Keep a short last row from stretching its cards across the whole width.
                    ForEach(0..<max(0, start + columns - items.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    }
                }
                // Every bubble in a row grows to the tallest one, so the tops line up
                // even when one agent has a single line to say and its neighbour has three.
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Wide layout, bottom: agents with nothing new stand small on a bench.
struct BenchPet: View {
    let s: Session
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    var body: some View {
        Button {
            jump(to: s)
        } label: {
            VStack(spacing: 2 * z) {
                StandingPet(pet: store.displayPets[s.id], pose: .sleeping, size: 34 * z).opacity(0.75)
                    .overlay(alignment: .topTrailing) { if s.restarting { RestartBadge(size: 14 * z).offset(x: 2 * z) } }
                    .anchorPreference(key: PetSpots.self, value: .bounds) { [s.id: $0] }
                Text(s.shownName).font(.system(size: 9.5 * z)).foregroundStyle(quiet).lineLimit(1).frame(width: 70 * z)
            }
            .contentShape(Rectangle())
            .anchorPreference(key: CardSpots.self, value: .bounds) { [s.id: $0] }
        }
        .buttonStyle(PressStyle())
        .opacity(store.isDimmed(s.id) ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: store.hovered)
        .help(benchHelp(s, store))
    }
}

struct DutyRoom: View {
    let b: Buckets
    let width: CGFloat
    @Environment(\.zoom) private var z

    var body: some View {
        let inner = width - 32 * z
        let columns = max(1, Int((inner + 10 * z) / (300 * z)))
        VStack(alignment: .leading, spacing: 16 * z) {
            if !b.waiting.isEmpty { group(L10n.string("group.waiting", table: "Board", zh: "在等你"), b.waiting, call, columns) }
            if !b.failed.isEmpty { group(failedWords(), b.failed, FailTone.red.color, columns) }
            if !b.unread.isEmpty { group(L10n.string("group.unread", table: "Board", zh: "干完了，有话对你说"), b.unread, paper, columns) }
            if !b.busy.isEmpty { group(L10n.string("group.busy", table: "Board", zh: "正在干活"), b.busy, work, columns) }
            if !b.seen.isEmpty { group(L10n.string("group.seen", table: "Board", zh: "看过了"), b.seen, quiet, columns) }
            if !b.gone.isEmpty { group(exitedWords(), b.gone, quiet, columns) }  // Under the looked-at ones
            if !b.resting.isEmpty {
                let perRow = max(1, Int((inner - 16 * z + 6 * z) / (76 * z)))
                VStack(alignment: .leading, spacing: 8 * z) {
                    title(L10n.string("group.resting", table: "Board", zh: "休息区"), b.resting.count, quiet)
                    VStack(alignment: .leading, spacing: 8 * z) {
                        ForEach(Array(stride(from: 0, to: b.resting.count, by: perRow)), id: \.self) { start in
                            HStack(alignment: .top, spacing: 6 * z) {
                                ForEach(Array(b.resting[start..<min(start + perRow, b.resting.count)])) { BenchPet(s: $0) }
                            }
                        }
                    }
                    .padding(.vertical, 10 * z).padding(.horizontal, 8 * z)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 13 * z, style: .continuous))
                }
            }
        }
    }

    func title(_ text: String, _ count: Int, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6 * z) {
            Text(text).font(rounded(13 * z)).foregroundStyle(color)
            Text("\(count)").font(rounded(13 * z, .medium)).foregroundStyle(quiet)
        }
    }

    func group(_ text: String, _ items: [Session], _ color: Color, _ columns: Int) -> some View {
        VStack(alignment: .leading, spacing: 8 * z) {
            title(text, items.count, color)
            CardRows(items: items, columns: columns)
        }
    }
}

/// Narrow layout: one line per agent, like a list of chats.
struct InboxRow: View {
    let s: Session
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    var body: some View {
        let now = Date()
        let unread = store.isUnread(s)
        let tone = store.failTone(s)
        let lively = s.status != "idle" || unread || s.isWorking || tone == .red || tone == .amber
        // An error's dot brick red, a retry's or the limit's amber; an exit has none.
        let dot: Color = tone == .red || tone == .amber ? tone!.color : tone == .gone ? .clear
            : s.status == "waiting" ? call : s.isWorking ? work : unread ? paper : .clear

        Button {
            store.markSeen(s)
            jump(to: s)
        } label: {
            HStack(alignment: .center, spacing: 10 * z) {
                ZStack {
                    Circle().fill(floorLine)
                    PetSprite(pet: store.displayPets[s.id], pose: store.pose(of: s, now: now), size: 38 * z, head: true, knockID: s.id)
                        .clipShape(Circle())
                }
                .frame(width: 38 * z, height: 38 * z)
                .anchorPreference(key: PetSpots.self, value: .bounds) { [s.id: $0] }
                .opacity(tone == .gone ? 0.45 : lively ? 1 : 0.6)
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(dot).frame(width: 10 * z, height: 10 * z)
                        .overlay(Circle().stroke(night, lineWidth: dot == .clear ? 0 : 2))
                }
                .overlay(alignment: .topTrailing) {
                    if s.restarting { RestartBadge(size: 14 * z).offset(x: 3 * z, y: -3 * z) }
                    else if let tone { FailBadge(tone: tone, size: 13 * z).offset(x: 4 * z, y: -4 * z) }
                }
                VStack(alignment: .leading, spacing: 2 * z) {
                    HStack(alignment: .firstTextBaseline, spacing: 6 * z) {
                        Text(s.shownName).font(rounded(13 * z)).foregroundStyle(lively ? Color.white : quiet).lineLimit(1)
                            .layoutPriority(1)  // The project gives way first, not the name
                        // Which agent, as on the wide card and in the office.
                        if let tag = kindTag(s) { KindTag(text: tag, z: z).foregroundStyle(lively ? Color.white : quiet) }
                        Text(s.project).font(.system(size: 10.5 * z)).foregroundStyle(quiet).lineLimit(1)
                        if let peers = store.peers[s.id] {
                            Text("⇄\(peers.count)").font(rounded(10.5 * z, .medium)).foregroundStyle(quiet)
                                .help(L10n.format("peers.talked", table: "Plurals", zh: "和 %lld 个会话通过话", peers.count))
                        }
                        Spacer(minLength: 0)
                        helperMark(s, store, z: z, narrow: true)
                        if s.status == "idle" && store.pinned.contains(s.id) { PinMark(size: 10 * z) }
                        Text(inboxTime(s, now: now)).font(rounded(10.5 * z, .medium))
                            .foregroundStyle(s.status == "waiting" ? call : quiet).fixedSize()
                    }
                    HStack(spacing: 5 * z) {
                        if s.isWorking { WorkingDots(size: 5 * z) }
                        Text(s.summary.isEmpty ? " " : s.shownSummary).font(.system(size: 11.5 * z))
                            .foregroundStyle(tone == .red ? Color.white : tone == .amber ? FailTone.amber.color
                                : s.status == "waiting" ? call : unread ? paper.opacity(0.95) : quiet)
                            .lineLimit(1)
                    }
                    if let note = originNote(s) { Text(note).font(.system(size: 10.5 * z)).foregroundStyle(quiet.opacity(0.8)).lineLimit(1) }
                    if s.isBackgroundHung { Text(bgHungWords()).font(.system(size: 10.5 * z)).foregroundStyle(quiet.opacity(0.8)).lineLimit(1) }
                }
            }
            .padding(.vertical, 7 * z).padding(.horizontal, 8 * z)
            .background(
                tone == .red || tone == .amber ? tone!.color.opacity(store.hovered == s.id ? 0.28 : 0.2)
                    : s.status == "waiting" ? call.opacity(0.14) : Color.white.opacity(store.hovered == s.id ? 0.07 : 0),
                in: RoundedRectangle(cornerRadius: 10 * z, style: .continuous)
            )
            .contentShape(Rectangle())
            .anchorPreference(key: CardSpots.self, value: .bounds) { [s.id: $0] }
        }
        .buttonStyle(PressStyle())
        .opacity(store.isDimmed(s.id) ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: store.hovered)
        .help(cardHelp(s, store))
        .transition(.opacity)
    }
}

struct Inbox: View {
    let b: Buckets
    @Environment(\.zoom) private var z
    @AppStorage("showOlder") private var showOlder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(b.waiting + b.failed + b.unread + b.busy + b.seen + b.gone) { InboxRow(s: $0) }
            if !b.resting.isEmpty {
                Rectangle().fill(floorLine).frame(height: 1).padding(.vertical, 6 * z)
                Button {
                    showOlder.toggle()
                } label: {
                    Text(showOlder ? L10n.format("inbox.older.hide", table: "Board", zh: "收起更早的 %lld 个", b.resting.count) : L10n.format("inbox.older.show", table: "Board", zh: "还有 %lld 个更早的", b.resting.count))
                        .font(.system(size: 11 * z)).foregroundStyle(quiet)
                        .padding(.horizontal, 8 * z).padding(.vertical, 6 * z)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showOlder { ForEach(b.resting) { InboxRow(s: $0) } }
            }
        }
    }
}

/// "e.g. 1 waiting  9 news  2 working" — sits in the window's title bar, right of the window buttons.
struct CountsBar: View {
    @ObservedObject var store: Store
    @AppStorage("zoom") private var zoom = 1.0

    var body: some View {
        let b = Buckets(store, now: Date())
        let z = CGFloat(zoom)
        HStack(spacing: 14 * z) {
            count(b.waiting.count, L10n.string("count.waiting", table: "Board", zh: "在等你"), call, z)
            if showFailed() { count(b.failed.count, failedWords(), FailTone.red.color, z) }  // Its own cell
            count(b.unread.count, L10n.string("count.news", table: "Board", zh: "有话说"), paper, z)
            count(b.busy.count, L10n.string("count.working", table: "Board", zh: "在干活"), work, z)
            // Another program's format not understood: an amber dot, what it is on pointing at it. Nothing at all without one.
            if !store.formatWarnings.isEmpty {
                Circle().fill(Color(hex: failAmberHex)).frame(width: 7 * z, height: 7 * z).padding(3 * z).contentShape(Rectangle())
                    .help(formatWarningWords(store.formatWarnings))
            }
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

/// What the title bar's amber dot says: one line for each program whose format was not understood.
func formatWarningWords(_ warnings: [FormatWarning]) -> String {
    let names = ["claude": "Claude Code", "codex": "Codex", "workbuddy": "WorkBuddy", "orca": "Orca"]
    var sources: [String] = []
    for w in warnings.sorted() where !sources.contains(w.source) { sources.append(w.source) }
    return sources.map { L10n.format("bar.formatWarning", table: "Board", zh: "%@ 会话格式变了，部分信息可能缺失", names[$0] ?? $0) }
        .joined(separator: "\n")
}

/// "e.g. current 38% ⟳16:30  week 55%": the account's Claude Code usage, the figures the status line shows.
struct UsageBar: View {
    @ObservedObject var store: Store
    let z: CGFloat

    var body: some View {
        HStack(spacing: (store.narrow ? 7 : 12) * z) {
            if let usage = store.fiveHour { figure(L10n.string("usage.fiveHour", table: "Board", zh: "当前"), usage, resets: clock(usage.resets, "HH:mm")) }
            if let usage = store.sevenDay { figure(L10n.string("usage.week", table: "Board", zh: "本周"), usage, resets: nil) }
        }
        .fixedSize()
        .help(explanation)
    }

    private func figure(_ label: String, _ usage: Usage, resets: String?) -> some View {
        HStack(spacing: 4 * z) {
            if !store.narrow { Text(label).font(rounded(11.5 * z, .medium)).foregroundStyle(quiet) }
            Text("\(usage.percent)%").font(rounded(12.5 * z)).foregroundStyle(usageColor(usage.percent))
            if !store.narrow, let resets {
                HStack(spacing: 2 * z) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 8 * z, weight: .bold))
                    Text(resets).font(rounded(10.5 * z, .medium))
                }
                .foregroundStyle(quiet)
            }
        }
    }

    private func clock(_ date: Date, _ format: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.locale = Locale(identifier: L10n.language)  // Month names and digits in the screen's language
        return formatter.string(from: date)
    }

    private var explanation: String {
        var lines = [L10n.string("usage.help.title", table: "Board", zh: "Claude Code 用量，所有会话共用")]
        if let usage = store.fiveHour { lines.append(L10n.format("usage.help.fiveHour", table: "Board", zh: "当前 5 小时：%lld%%，%@ 重置", usage.percent, clock(usage.resets, "HH:mm"))) }
        if let usage = store.sevenDay { lines.append(L10n.format("usage.help.week", table: "Board", zh: "本周：%lld%%，%@ 重置", usage.percent, clock(usage.resets, L10n.string("usage.dateFormat", table: "Board", zh: "M月d日 HH:mm")))) }
        return lines.joined(separator: "\n")
    }
}

/// The right end of the title bar: the account's usage, and things to do to the whole board.
struct ActionsBar: View {
    @ObservedObject var store: Store
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("office") private var office = false

    var body: some View {
        let z = CGFloat(zoom)
        HStack(spacing: 14 * z) {
            UsageBar(store: store, z: z)
            // Pinned sessions stay where they are, so with only those left there is nothing to mark.
            // An error not looked at too (marking it seen takes it out of Error).
            if store.sessions.contains(where: { store.isFresh($0) || store.isFailed($0) }) {
                Button(store.narrow ? L10n.string("bar.markAllSeen.short", table: "Board", zh: "全部看过") : L10n.string("bar.markAllSeen", table: "Board", zh: "全部标为看过")) { store.markAllSeen() }
                    .buttonStyle(.plain).font(rounded(11.5 * z, .medium)).foregroundStyle(quiet)
                    .help(L10n.string("bar.markAllSeen.help", table: "Board", zh: "把所有干完的会话都当作已经看过；标记了待回复的不动"))
            }
            // Search, in every scene, beside the switch.
            SearchButton(store: store, z: z)
            if store.officeFits {
                // The setting is read through @AppStorage so the switch follows it; the theme's change publishes the store.
                OfficeSwitch(mode: office ? OfficeMode.current : .board, z: z) { $0.choose(store: store) }
            }
            // The settings, at the far right.
            Button { SettingsWindow.shared.show(store: store) } label: {
                Image(systemName: "gearshape").font(.system(size: 12.5 * z, weight: .medium))
            }
            .buttonStyle(.plain).foregroundStyle(quiet).help(L10n.string("title", table: "Settings", zh: "设置"))
        }
        .padding(.trailing, 12).fixedSize().frame(height: 28)
    }
}

struct Board: View {
    let width: CGFloat
    var showsHeader = true  // false in the window, where the title bar carries it
    @EnvironmentObject private var store: Store
    @Environment(\.still) private var still
    @Environment(\.zoom) private var z

    var body: some View {
        let b = Buckets(store, now: Date())
        let narrow = width < 520 * z
        VStack(alignment: .leading, spacing: 14 * z) {
            if showsHeader {
                HStack(spacing: 14 * z) {
                    Text(showFailed()
                        ? L10n.format("board.header.failed", table: "Board", zh: "%lld 在等你  %lld %@  %lld 有话说  %lld 在干活", b.waiting.count, b.failed.count, failedWords(), b.unread.count, b.busy.count)
                        : L10n.format("board.header", table: "Board", zh: "%lld 在等你  %lld 有话说  %lld 在干活", b.waiting.count, b.unread.count, b.busy.count))
                        .font(rounded(12.5 * z, .medium)).foregroundStyle(quiet).lineLimit(1)
                    Spacer(minLength: 0)
                    UsageBar(store: store, z: z)
                }
            }
            if store.sessions.isEmpty {
                Text(L10n.string("board.empty", table: "Board", zh: "现在没有打开的会话。在 Orca 里开一个，它就会出现在这里。"))
                    .font(.system(size: 12 * z)).foregroundStyle(quiet)
            } else if narrow {
                Inbox(b: b)
            } else {
                DutyRoom(b: b, width: width)
            }
        }
        .padding(.horizontal, 16 * z).padding(.bottom, 16 * z).padding(.top, 6 * z)
        .frame(width: width, alignment: .topLeading)
        .backgroundPreferenceValue(CardSpots.self) { cards in
            GeometryReader { proxy in
                // Hand the cards' frames to the hover tracker, in the window's coordinates.
                let origin = proxy.frame(in: .global).origin
                let _ = (store.tracker.frames = cards.mapValues { proxy[$0].offsetBy(dx: origin.x, dy: origin.y) })
                Color.clear
            }
        }
        .overlayPreferenceValue(PetSpots.self) { pets in
            GeometryReader { proxy in
                let spots = pets.mapValues { proxy[$0] }
                // Pets in the rest area stand outside the grid of cards: no gaps lead to them.
                let bench: Set<String> = narrow ? [] : Set(b.resting.map(\.id))
                // The left margin of the narrow list is roomier than the gaps between cards.
                let gap = (narrow ? 9 : 5) * z
                let route = { (from: String, to: String) -> [CGPoint]? in
                    guard let start = spots[from], let end = spots[to] else { return nil }
                    return bench.contains(from) || bench.contains(to)
                        ? Trail.direct(start, end) : Trail.corners(start, end, gap: gap)
                }
                ZStack {
                    LinkLines(route: route)
                    if !still {
                        FlightLayer(
                            trips: store.flights.compactMap { flight in
                                route(flight.from, flight.to).map { FlightLayer.Trip(id: flight.id, corners: $0) }
                            }, z: z)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: store.hovered)
            }
            .allowsHitTesting(false)
        }
    }
}

struct Root: View {
    @ObservedObject var store: Store
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("office") private var office = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if showsOffice(setting: office, size: geo.size) {
                    // The hover card is placed in the window's coordinates, where the pointer is followed.
                    let origin = geo.frame(in: .global).origin
                    // The Seaview scene draws its own room; the hover card and the lists over it are the office's.
                    if ZoneUI.active { ZoneRoom(store: store) } else { OfficeRoom(store: store) }
                    OfficeHover(
                        fit: OfficeFit(geo.size), origin: origin,
                        window: CGSize(width: origin.x + geo.size.width, height: origin.y + geo.size.height))
                } else {
                    ScrollView {
                        Board(width: geo.size.width, showsHeader: false)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                // The title bar's search, over whichever scene shows.
                if store.searchOpen { SearchPanel(store: store).padding(.top, 6).padding(.trailing, 10) }
            }
            .onAppear {
                store.narrow = geo.size.width < 520 * CGFloat(zoom)
                store.officeFits = showsOffice(setting: true, size: geo.size)
            }
            .onChange(of: geo.size.width < 520 * CGFloat(zoom)) { _, narrow in store.narrow = narrow }
            .onChange(of: showsOffice(setting: true, size: geo.size)) { _, fits in store.officeFits = fits }
        }
        .frame(minWidth: 300, minHeight: 200)
        .background(night)
        .environmentObject(store)
        .environment(\.zoom, CGFloat(zoom))
        .environment(\.colorScheme, .dark)
    }
}

// ───────── App ─────────

/// The panel floats above another app's windows and is never the active window, and AppKit
/// normally spends the first click on such a window just focusing it. Take that click.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    /// Pointer position in this view (top-left origin), or nil when it leaves.
    var onPointer: ((CGPoint?) -> Void)?
    /// The menu for a right-click at this position, if that spot has one.
    var onMenu: ((CGPoint) -> NSMenu?)?
    private var watching: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard onPointer != nil else { return }
        if let watching { removeTrackingArea(watching) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        watching = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onPointer?(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = onMenu?(convert(event.locationInWindow, from: nil)) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }
}

let liveCaptureNote = Notification.Name(appID + (DemoMode.requested(CommandLine.arguments) ? ".demo" : "") + ".capture")
let liveCapturePath = "/tmp/session-panel-live.png"

/// `--capture-live <path>`: the target made ready for the running panel's picture, and the picture put in place.
enum LiveCapture {
    /// The file the panel is asked to write, or why the target is refused.
    /// Only a regular file or a path with nothing at it is taken: a folder, a symlink or anything else there is refused and
    /// left as it is. The picture goes to a file of its own in the target's folder (named by this process and a random
    /// part), so that the target is replaced only once the picture is whole.
    static func prepare(_ path: String) -> (writeTo: String?, refusal: String?) {
        let url = URL(fileURLWithPath: path)
        let target = url.path
        if let type = (try? FileManager.default.attributesOfItem(atPath: target))?[.type] as? FileAttributeType {
            switch type {
            case .typeRegular: break
            case .typeDirectory: return (nil, "\(path) is a folder: give the path of a .png file")
            case .typeSymbolicLink: return (nil, "\(path) is a symlink: give the path of a regular file")
            default: return (nil, "\(path) is not a regular file")
            }
        }
        let folder = url.deletingLastPathComponent().path
        let part = UUID().uuidString.prefix(8)
        return (folder + "/.\(url.lastPathComponent).capture-\(getpid())-\(part).png", nil)
    }

    /// The size of what is at `path`, 0 for nothing.
    static func size(_ path: String) -> UInt64 {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// The picture written to `writeTo` put at `target` in one step (rename: an existing regular file is replaced whole);
    /// false when there is none, and then the target is as it was and the picture's own file is gone.
    static func finish(writeTo: String, target: String) -> Bool {
        guard size(writeTo) > 0, rename(writeTo, target) == 0 else {
            try? FileManager.default.removeItem(atPath: writeTo)
            return false
        }
        return true
    }
}
/// Asks the running panel's Seaview scene for an orca clip ("A", "B" or "C") at the sea loop's next frame 0 (`--orca A`).
let zoneOrcaNote = Notification.Name(appID + ".orca")

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = Store()  // Not private, for the menu's still
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private var watcher: AnyCancellable?
    private var titleItems: [NSView] = []
    /// The menu bar turning light or dark redraws the icon (its badged form is tinted for the bar it is on).
    private var appearanceWatch: NSKeyValueObservation?

    /// The window as it is on screen, title bar included, without its shadow. CGWindowListCreateImage is
    /// marked unavailable to Swift on newer SDKs but still works, so it is looked up by name.
    private func captureLive(to path: String) { _ = captureWindow(panel.windowNumber, to: path) }

    /// Until then a move of the panel is the system's (screens changing), not theirs.
    private var screensSettle = Date.distantPast

    /// Where the user put the panel: its screen's name and its frame from that screen's corner.
    private func notePlace() {
        guard Date() > screensSettle, panel.isVisible, let screen = panel.screen else { return }
        let f = panel.frame, corner = screen.frame.origin
        UserDefaults.standard.set(screen.localizedName, forKey: "homeScreen")
        UserDefaults.standard.set(NSStringFromRect(NSRect(x: f.minX - corner.x, y: f.minY - corner.y, width: f.width, height: f.height)), forKey: "homePlace")
    }

    private func screensChanged() {
        screensSettle = Date().addingTimeInterval(3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.returnHome() }
    }

    /// Back to the user's screen and place when that screen is here and the panel is elsewhere.
    private func returnHome() {
        guard let name = UserDefaults.standard.string(forKey: "homeScreen"), let place = UserDefaults.standard.string(forKey: "homePlace"),
            let screen = NSScreen.screens.first(where: { $0.localizedName == name }), panel.screen?.localizedName != name
        else { return }
        let r = NSRectFromString(place), room = screen.visibleFrame
        let size = NSSize(width: min(r.width, room.width), height: min(r.height, room.height))
        var origin = NSPoint(x: screen.frame.minX + r.minX, y: screen.frame.minY + r.minY)
        origin.x = min(max(origin.x, room.minX), room.maxX - size.width)
        origin.y = min(max(origin.y, room.minY), room.maxY - size.height)
        screensSettle = Date().addingTimeInterval(1)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        log("panel: back on \(name)")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(atPath: panelDataFolder, withIntermediateDirectories: true)
        settleOfficeTheme()  // a scene this build cannot show becomes Seaview, before anything reads the theme
        // A copy of the app an extension builds for review (`SceneExtension.variant`): its own window and labels.
        let variant = Extensions.registered?.variant(bundleID: Bundle.main.bundleIdentifier)
        if variant?.readOnly == true {store.readOnly=true}
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: variant?.windowSize ?? CGSize(width: 640, height: 720)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = variant?.title ?? "Soulgent"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true  // the board runs to the top edge
        // Not movable by its background: a click on a card would also count as a window drag.
        // The strip along the top edge still drags the window.
        panel.backgroundColor = NSColor(red: 0x1B / 255.0, green: 0x18 / 255.0, blue: 0x30 / 255.0, alpha: 1)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false  // the close button only hides it
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        let board = FirstClickHostingView(rootView: Root(store: store))
        board.onPointer = { [weak store] point in store?.tracker.pointer(at: point) }
        board.onMenu = { [weak self] point in self?.cardMenu(at: point) }
        panel.contentView = board
        panel.center()
        if !DemoMode.active { panel.setFrameAutosaveName("Soulgent") }  // The crowd's window leaves the real one's place alone
        // Its own screen: the iPad (Sidecar) comes and goes, and when it goes the system moves the panel to
        // another screen and the autosaved frame follows. Where the user last put it themselves is kept apart, and it goes back
        // there once that screen is back.
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.notePlace() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
        screensChanged()  // at launch too: the screen may have been away when the frame was restored
        // Counts on the left of the title bar, actions on the right. Controls placed in the
        // content under a transparent title bar would not get clicks; accessories do.
        titleItems = [
            titleBarItem(CountsBar(store: store), at: .leading),
            titleBarItem(ActionsBar(store: store), at: .trailing),
        ]
        panel.orderFrontRegardless()
        // A picture of the live window on request (`--capture-live`): grabbing another app's window needs
        // Screen Recording, grabbing your own does not, so this is the way to see what the user sees.
        DistributedNotificationCenter.default().addObserver(forName: liveCaptureNote, object: nil, queue: .main) { [weak self] note in
            let path = (note.object as? String) ?? liveCapturePath
            MainActor.assumeIsolated { self?.captureLive(to: path) }
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        appearanceWatch = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.stirs.appearance += 1; self?.showCounts() }
        }
        statusItem.menu = makeStatusMenu(variant: variant)

        // objectWillChange fires before the new values are in place; read them on the next turn.
        watcher = store.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.stirs.store += 1; self?.showCounts() }
        }

        store.start()
        showCounts()
        // The live walk probe, on a read-only review copy only.
        let args = CommandLine.arguments
        if variant?.readOnly == true, let i = args.firstIndex(of: "--zone-walk-probe"), i + 1 < args.count {
            let dir = args[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in zoneWalkProbe(self?.panel, dir: dir) }
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// The status-bar menu as an app menu (`appMenuLines`): the counts, the panel, the scenes, two things to do, Settings… and
    /// About, Quit. Everything else is in the Settings window.
    private var countsItem: NSMenuItem?

    func makeStatusMenu(variant: AppVariant? = nil) -> NSMenu {
        let menu = NSMenu()
        for line in appMenuLines(variant: variant) {
            let title = appMenuTitle(line, variant: variant)
            switch line {
            case .separator: menu.addItem(.separator())
            case .variant: menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
            case .counts:
                let b = Buckets(store, now: Date())
                let counts = NSMenuItem(title: menuCountsTitle(waiting: b.waiting.count, unread: b.unread.count, busy: b.busy.count, failed: b.failed.count), action: nil, keyEquivalent: "")
                countsItem = counts
                menu.addItem(counts)
            case .toggle: menu.addItem(item(title, #selector(togglePanel)))
            case .mode(let mode):
                // What the panel shows: the board, the office, a scene, Seaview; the one showing is ticked.
                let choice = item(title, #selector(chooseMode(_:)))
                choice.representedObject = mode.code  // The mode's code, not its title (the words change with the language)
                menu.addItem(choice)
            case .markAllSeen: menu.addItem(item(title, #selector(markAllSeen)))
            case .spotlight: menu.addItem(item(title, #selector(toggleSpotlight)))
            case .settings:
                let entry = item(title, #selector(openSettings))
                entry.keyEquivalent = ","
                menu.addItem(entry)
            case .about: menu.addItem(item(title, #selector(openAbout)))
            case .quit: menu.addItem(NSMenuItem(title: title, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
            }
        }
        return menu
    }

    @objc private func openSettings() { SettingsWindow.shared.show(store: store) }

    @objc private func openAbout() { showAbout() }

    private func titleBarItem<V: View>(_ view: V, at side: NSLayoutConstraint.Attribute) -> NSView {
        let host = FirstClickHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame.size = host.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = side
        accessory.view = host
        panel.addTitlebarAccessoryViewController(accessory)
        return host
    }

    /// CPU: what the menu bar and the title bar last showed. Every change to the store, and the bar's appearance, ask
    /// for `showCounts`; the same counts and look are not set twice, and the title bar's width is looked at once a tick at
    /// most (unguarded, it kept the main thread and WindowServer near 100 %).
    private var shownCounts = ""
    private var sizedTitleAt = Date.distantPast
    /// CPU: the asks for `showCounts` in the current minute, by who asked, and what came of them.
    private var stirs = (store: 0, appearance: 0, shown: 0, sized: 0)
    private var stirsSince = Date()
    /// No timer of its own (the restart check allows the store's tick alone): looked at as `showCounts` runs.
    private func logStirs(_ now: Date) {
        guard now.timeIntervalSince(stirsSince) >= 60 else { return }
        stirsSince = now
        if stirs.store + stirs.appearance > 60 {
            log("cpu: a minute: store \(stirs.store), appearance \(stirs.appearance), icon set \(stirs.shown), title bar sized \(stirs.sized)")
        }
        stirs = (0, 0, 0, 0)
    }
    private func showCounts() {
        let now = Date()
        logStirs(now)
        let b = Buckets(store, now: now)
        let prefix = Extensions.registered?.variant(bundleID: Bundle.main.bundleIdentifier)?.statusPrefix ?? ""
        let look = statusItem.button?.effectiveAppearance.name.rawValue ?? ""
        let key = "\(b.waiting.count) \(b.failed.count) \(b.unread.count) \(b.busy.count) \(prefix) \(look)"
        // The title bar's own numbers (usage and the like) change width too: looked at again once a tick at most.
        let resize = key != shownCounts || now.timeIntervalSince(sizedTitleAt) >= 2
        if key != shownCounts {
            shownCounts = key
            stirs.shown += 1
            // The Soulgent flame and one badge (waiting + unread); the busy count is the menu's first line.
            // An error not looked at counts in the badge and makes it red; an exit counts nowhere.
            statusItem.button?.image = statusIcon(waiting: b.waiting.count, unread: b.unread.count, failed: b.failed.count)
            statusItem.button?.title = prefix
            countsItem?.title = menuCountsTitle(waiting: b.waiting.count, unread: b.unread.count, busy: b.busy.count, failed: b.failed.count)
        }
        if resize {
            sizedTitleAt = now
            stirs.sized += 1
            for host in titleItems {  // the numbers change width
                let fit = host.fittingSize
                if host.frame.size != fit { host.setFrameSize(fit) }
            }
        }
    }

    /// Right-click on any session, on the board or in the office (its pet, or its row on the list by the door or a chip):
    /// the same menu for each, as `sessionMenu` makes it.
    private func cardMenu(at point: CGPoint) -> NSMenu? {
        guard let key = store.tracker.card(at: point) else { return nil }
        let id = OfficeList.session(key) ?? key
        guard let s = store.sessions.first(where: { $0.id == id }) else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false  // each line says itself whether it can be chosen; validation would enable them all
        for line in sessionMenu(store, s) {
            let action: Selector
            switch line.action {
            case .separator:
                menu.addItem(.separator())
                continue
            case .jump: action = #selector(jumpTo(_:))
            case .pin: action = #selector(togglePin(_:))
            case .desk: action = #selector(sendToDesk(_:))
            case .rest: action = #selector(sendToRest(_:))
            case .openFolder: action = #selector(openFolder(_:))
            case .changePet: action = #selector(changePet(_:))
            case .banPet: action = #selector(banPet(_:))
            case .sizeUp: action = #selector(sizeUp(_:))
            case .sizeDown: action = #selector(sizeDown(_:))
            case .sizeReset: action = #selector(sizeReset(_:))
            case .sendOff: action = #selector(sendOff(_:))
            }
            let entry = item(line.title, action)
            entry.representedObject = id
            entry.isEnabled = line.enabled
            menu.addItem(entry)
        }
        return menu
    }

    private func session(of sender: NSMenuItem) -> Session? {
        guard let id = sender.representedObject as? String else { return nil }
        return store.sessions.first { $0.id == id }
    }

    // As a click on its card or pet.
    @objc private func jumpTo(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.markSeen(s)
        jump(to: s)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.togglePin(s)
    }

    // Its card travels to its new group, as a pin's does; in the office the pet walks there.
    @objc private func sendToDesk(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { store.desk(s) }
    }

    // The same, to the back.
    @objc private func sendToRest(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.82)) { store.rest(s) }
    }

    // Another pet from the shared pool for this session; or this pet banned, and another.
    @objc private func changePet(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.changePet(s)
    }

    @objc private func banPet(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.banPet(s)
    }

    // The Seaview figure a step bigger or smaller, or back to its default size.
    @objc private func sizeUp(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.resizeFigure(s, by: 1)
    }

    @objc private func sizeDown(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.resizeFigure(s, by: -1)
    }

    @objc private func sizeReset(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        store.resetFigureSize(s)
    }

    // The Seaview scene's Send Off Duty, by `offduty.py --off` off the main thread; a refusal shows over the figure and goes to the log.
    @objc private func sendOff(_ sender: NSMenuItem) {
        guard let s = session(of: sender) else { return }
        ZoneOffDuty.shared.sendOff(s.registryName, store: store)
    }

    // The folder itself in a Finder window, not the folder selected in its parent.
    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let s = session(of: sender), !s.cwd.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: s.cwd))
    }

    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    @objc private func chooseMode(_ sender: NSMenuItem) {
        guard let mode = OfficeMode.coded(sender.representedObject as? String) else { return }
        store.sceneListOpen = false
        mode.choose(store: store)
    }

    // The light, as the Settings' switch does it (`switchSpotlight(store:)`: without the permission, the system's prompt).
    @objc private func toggleSpotlight() { switchSpotlight(store: store) }

    // Quitting from the menu bar: Orca's page is closed to readers again if the light opened it. Best effort, waiting a
    // moment at most; a panel killed outright leaves it open until Orca restarts.
    func applicationWillTerminate(_ notification: Notification) { store.focus.switchOff(waiting: 0.3) }

    // Double-clicking the app while it runs brings a hidden panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !panel.isVisible { panel.orderFrontRegardless() }
        return false
    }

    // The switch says why it is off in a window too narrow for the office; the light says whether it follows Orca, or
    // what it needs to.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSpotlight) {
            let state = spotlightMenuItem(trusted: AXIsProcessTrusted(), on: officeSpotlight())
            menuItem.title = state.title
            menuItem.state = state.checked ? .on : .off
            menuItem.toolTip = state.help
            return true
        }
        guard menuItem.action == #selector(chooseMode(_:)), let mode = OfficeMode.coded(menuItem.representedObject as? String) else { return true }
        let state = officeMenuItem(mode, fits: store.officeFits)
        menuItem.title = state.title
        menuItem.state = OfficeMode.current == mode ? .on : .off
        return state.enabled
    }

    @objc private func markAllSeen() { store.markAllSeen() }
}

@MainActor func snapshot(to path: String, width: CGFloat, hover: String? = nil, pin: String? = nil) {
    Pets.shared.synchronous = true
    let store = Store()
    store.readOnly = true
    store.loadOnce()
    store.scanLinksNow()
    restartDemo(store, arguments: CommandLine.arguments)
    let zoom = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1
    store.narrow = width < 520 * CGFloat(zoom)
    if let hover { store.hovered = store.sessions.first(where: { $0.name == hover })?.id }
    // Pinned for this picture only.
    if let pin, let s = store.sessions.first(where: { $0.name == pin }) { store.pinned.insert(s.id) }
    let board = Board(width: width)
        .environmentObject(store).environment(\.zoom, CGFloat(zoom)).environment(\.still, true)
        .background(night).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: board)
    renderer.scale = 2
    guard let tiff = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else { fatalError("could not render the board") }
    try! png.write(to: URL(fileURLWithPath: path))
}

#if !TESTING
@main struct Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        // `--lang <code>` shows the words in that language for this run (pictures); else the system's or Settings' choice.
        L10n.applyArguments(args)
        // `--demo-crowd`: made-up sessions, settings and files of the crowd's own; before anything reads one.
        if DemoMode.requested(args) { DemoMode.enter(arguments: args) }
        // An extension's scene, when this build has one (build.sh: the extension directory).
        registerExtensions()
        // A run that looks once and goes has no next tick to wait for a background read.
        CodexAppSessions.firstReadsInline = ["--snapshot", "--dump", "--jump"].contains(where: args.contains)
        if let defaults = Extensions.registered?.variant(bundleID: Bundle.main.bundleIdentifier)?.defaults {
            UserDefaults.standard.register(defaults: defaults)
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let given = args.firstIndex(of: "--width").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            let width = given ?? 640
            let hover = args.firstIndex(of: "--hover").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            let pin = args.firstIndex(of: "--pin").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            if args.contains("--office") {
                let height = args.firstIndex(of: "--height").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 764
                officeSnapshot(to: args[i + 1], size: CGSize(width: given ?? 1194, height: height), hover: hover)
            } else {
                snapshot(to: args[i + 1], width: CGFloat(width), hover: hover, pin: pin)
            }
            return
        }
        if args.contains("--dump") {
            // --dump is data, the same bytes in every language; it never reads the tables (SummaryLine's
            // simplified templates are its own). Pinned all the same, so nothing it might reach can follow the system.
            L10n.pin(L10n.source)
            let loader = Loader()
            runDump(loader)
            return
        }
        if let i = args.firstIndex(of: "--jump"), i + 1 < args.count {
            let wanted = args[i + 1]
            guard let session = Loader().load().first(where: { !$0.disconnected && ($0.name == wanted || $0.id.hasPrefix(wanted)) }) else {
                print("no open session named \(wanted)")
                return
            }
            print(jumpOutcome(session))
            // The link is on its way to the app; a moment for it to arrive before this process goes.
            if jumpURL(session) != nil { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
            return
        }
        // Asks the running panel for a picture of its window; prints the path once it is written.
        if let i = args.firstIndex(of: "--capture-live") {
            let path = i + 1 < args.count ? args[i + 1] : liveCapturePath
            let prepared = LiveCapture.prepare(path)
            guard let writeTo = prepared.writeTo else {
                FileHandle.standardError.write(Data("\(prepared.refusal ?? "cannot write \(path)")\n".utf8))
                exit(1)
            }
            DistributedNotificationCenter.default().postNotificationName(liveCaptureNote, object: writeTo, userInfo: nil, deliverImmediately: true)
            // Done once the picture's file has a size that holds from one look to the next.
            let deadline = Date().addingTimeInterval(3)
            var last: UInt64 = 0
            while Date() < deadline {
                let now = LiveCapture.size(writeTo)
                if now > 0 && now == last { break }
                last = now
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            print(LiveCapture.finish(writeTo: writeTo, target: path) ? path : "no picture (is the panel running?)")
            return
        }
        // Asks the running panel for an orca clip at the sea loop's next frame 0 (a debug hook; see it with --capture-live).
        if let i = args.firstIndex(of: "--orca") {
            let id = i + 1 < args.count ? args[i + 1].uppercased() : "A"
            DistributedNotificationCenter.default().postNotificationName(zoneOrcaNote, object: id, userInfo: nil, deliverImmediately: true)
            print("asked for orca \(id) (it starts at the loop's next frame 0, within 12 s, if the Seaview room is showing)")
            return
        }
        // What Orca's Accessibility tree shows of where the user types; prints and exits. Ahead of the one-panel rule: it runs
        // beside the panel, and is started through `open` so the permission asked about is this app's, not a terminal's.
        // `--focus-probe-keep` (alone or with `--focus-probe`) leaves Orca's web tree for readers on afterwards.
        if args.contains("--focus-probe") || args.contains("--focus-probe-keep") {
            OfficeFocusProbe.run(keep: args.contains("--focus-probe-keep"))
            return
        }
        // One panel only: the login job and a double-click on the app must not both show one.
        // The crowd's panel runs beside the real one (it reads and writes nothing of its).
        let me = ProcessInfo.processInfo.processIdentifier
        if !DemoMode.active, NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            .contains(where: { $0.processIdentifier != me })
        {
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // no Dock icon; quit from the menu bar item
        app.run()
    }
}
#endif

// ───────── The made-up crowd, taken in ─────────

extension Store {
    /// `--demo-crowd`: the sessions, what the user has seen, the helpers, the talk, the pets, the notice board and the light of the
    /// made-up crowd (`DemoCrowd`). Nothing is read; the pets are the listed ones, set by hand, not dealt.
    func takeDemo(_ crowd: DemoCrowd) {
        sessions = crowd.sessions
        seen = crowd.seen
        pinned = crowd.pinned
        agents = crowd.agents
        agentCounts = crowd.agents.mapValues(\.count)
        peers = crowd.peers
        petBySession = crowd.pets
        activity = crowd.activity
        focused = crowd.lit
        orcaInFront = true
        paneOf = { _ in "" }  // no pane to look up
        lastWorking = Dictionary(sessions.map { ($0.id, $0.isWorking) }, uniquingKeysWith: { first, _ in first })
    }
}
