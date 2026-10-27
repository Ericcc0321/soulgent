import AppKit

/// Seaview: every session is an employee with a desk in its workzone. This file holds what can be decided without a
/// screen: which zone a session belongs to, which desk it keeps, where a waiting one goes, and what each desk shows. The
/// view (`ZoneView.swift`) only draws what these say.

/// What a session is doing, as the zone sees it: the board's five groups.
enum ZoneState: Equatable { case busy, unread, seen, resting, waiting }

/// `~/.claude/workzones.json`: the zones, which project folders belong to which, and the zone for the rest (`default`).
/// Written by another session; read as it is, missing fields tolerated.
struct ZoneConfig: Equatable {
    struct Zone: Equatable {
        let code: String
        let name: String
        let color: UInt32?
        let order: Int
        let lead: String?
        /// The island of the art it sits on (points.json `zones[].name`); nil: the island of its own name, else the next
        /// free one in `order` (`ZoneScene.seating`).
        var island: String? = nil
    }
    var zones: [Zone] = []
    /// Folder (with `~` expanded) → zone code. A `*` in a key is part of the folder's name, not a pattern.
    var dirs: [String: String] = [:]
    /// The zone for a session no prefix or folder places; nil when the file says null or names no known zone.
    var fallback: String?
    /// Off duty (off-duty mode, `offduty`): the names that never go off duty, and the zones none of whose sessions do. Each zone's lead
    /// never does either (`isResident`).
    var resident: Set<String> = []
    var residentZones: Set<String> = []

    static func parse(_ data: Data, home: String) -> ZoneConfig {
        var config = ZoneConfig()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return config }
        let zones = root["zones"] as? [String: Any] ?? [:]
        for (code, value) in zones {
            let entry = value as? [String: Any] ?? [:]
            let name = entry["name"] as? String ?? code
            let order = (entry["order"] as? NSNumber)?.intValue ?? Int.max
            let lead = entry["lead"] as? String
            config.zones.append(Zone(code: code, name: name, color: zoneHex(entry["color"] as? String), order: order, lead: lead,
                                     island: entry["island"] as? String))
        }
        config.zones.sort { $0.order != $1.order ? $0.order < $1.order : $0.code < $1.code }
        let dirs = root["dirs"] as? [String: Any] ?? [:]
        for (folder, value) in dirs {
            guard let code = value as? String else { continue }
            config.dirs[expand(folder, home: home)] = code
        }
        if let code = root["default"] as? String, config.zone(code) != nil { config.fallback = code }
        let offduty = root["offduty"] as? [String: Any] ?? [:]
        config.resident = Set(offduty["resident"] as? [String] ?? [])
        config.residentZones = Set(offduty["resident_zones"] as? [String] ?? [])
        return config
    }

    /// whether a session of this name (in this zone) keeps its seat for good: on the resident list, in a resident
    /// zone, or its zone's lead.
    func isResident(_ name: String, zone code: String?) -> Bool {
        if resident.contains(name) { return true }
        guard let code else { return false }
        return residentZones.contains(code) || zone(code)?.lead == name
    }

    static func expand(_ folder: String, home: String) -> String {
        if folder == "~" { return home }
        if folder.hasPrefix("~/") { return home + String(folder.dropFirst()) }
        return folder
    }

    func zone(_ code: String) -> Zone? { zones.first { $0.code == code } }

    /// The prefix before the first "-" when it names a zone.
    func prefix(of name: String) -> String? {
        guard let dash = name.firstIndex(of: "-") else { return nil }
        let head = String(name[..<dash])
        return zone(head) == nil ? nil : head
    }

    /// The name's zone prefix, else the folder's longest listed ancestor (or itself), else `default`, else none.
    func resolve(name: String, cwd: String) -> String? {
        if let code = prefix(of: name) { return code }
        var best: (length: Int, code: String)?
        if !cwd.isEmpty {
            for (folder, code) in dirs where zone(code) != nil {
                let holds = cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
                if holds && folder.count > (best?.length ?? -1) { best = (folder.count, code) }
            }
        }
        return best?.code ?? fallback
    }

    /// The name on a plate: without its zone prefix (`Web-API-comet` → `API-comet`), not shortened any further. A name
    /// whose first part names no zone keeps it: there it is part of the name.
    func plate(_ name: String) -> String {
        guard let code = prefix(of: name) else { return name }
        let rest = String(name.dropFirst(code.count + 1))
        return rest.isEmpty ? name : rest
    }
}

/// The workzones file as it is now, read again whenever its date or size changes.
@MainActor enum ZoneConfigFile {
    static var path = home + "/.claude/workzones.json"
    private static var stamp = ""
    private static var cached = ZoneConfig()
    private static var saidMissing = false

    static func current() -> ZoneConfig {
        let now = zoneStamp(path)
        if now == stamp { return cached }
        stamp = now
        guard let data = FileManager.default.contents(atPath: path) else {
            if !saidMissing { log("Seaview: no workzones file at \(path); every session is unzoned") }
            saidMissing = true
            cached = ZoneConfig()
            return cached
        }
        cached = ZoneConfig.parse(data, home: home)
        return cached
    }
}

/// A colour written as six hex digits, with or without a "#".
func zoneHex(_ text: String?) -> UInt32? {
    guard let text else { return nil }
    let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
    return digits.count == 6 ? UInt32(digits, radix: 16) : nil
}

/// A file's date and size as one string; empty for no file.
func zoneStamp(_ path: String) -> String {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "" }
    let date = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    return "\(date) \(size)"
}

/// A session still being checked in (`workzone-pending.json`, by session id): the name the hook suggests. Only shown,
/// never acted on; an entry older than seven days is stale.
struct ZonePending: Equatable {
    let suggest: String
    let zone: String?

    static let lifetime: TimeInterval = 7 * 24 * 3600

    static func parse(_ data: Data, now: Date) -> [String: ZonePending] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var result: [String: ZonePending] = [:]
        for (id, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            if let ts = stampSeconds(entry["ts"]), now.timeIntervalSince1970 - ts > lifetime { continue }
            result[id] = ZonePending(suggest: entry["suggest"] as? String ?? "", zone: entry["zone"] as? String)
        }
        return result
    }

    /// `ts` as seconds since 1970: a number (seconds or milliseconds) or an ISO 8601 date.
    static func stampSeconds(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue > 1e11 ? n.doubleValue / 1000 : n.doubleValue }
        guard let text = value as? String else { return nil }
        if let n = Double(text) { return n > 1e11 ? n / 1000 : n }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: text) { return d.timeIntervalSince1970 }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text)?.timeIntervalSince1970
    }
}

@MainActor enum ZonePendingFile {
    /// Written by a hook of the machine's own (none comes with the panel): `SOULGENT_PENDING_FILE` or the setting
    /// `pendingFile`; "" (no one shown as checking in) when neither says.
    static var path = localPath("pendingFile", env: "SOULGENT_PENDING_FILE")
    private static var stamp = ""
    private static var cached: [String: ZonePending] = [:]

    static func current(now: Date = Date()) -> [String: ZonePending] {
        let fresh = zoneStamp(path)
        if fresh != stamp {
            stamp = fresh
            cached = FileManager.default.contents(atPath: path).map { ZonePending.parse($0, now: now) } ?? [:]
        }
        return cached
    }

    /// Its entry while the session's name still has no zone prefix; the file is cleaned only now and then.
    static func entry(for s: Session, config: ZoneConfig) -> ZonePending? {
        config.prefix(of: s.name) == nil ? current()[s.id] : nil
    }
}

/// A desk: its zone and its number there, 1 to `ZonePlan.desksPerZone` (1 is the lead's).
struct ZoneDesk: Hashable {
    let zone: String
    let index: Int
    var key: String { "\(zone)#\(index)" }

    init(zone: String, index: Int) {
        self.zone = zone
        self.index = index
    }

    init?(key: String) {
        guard let hash = key.lastIndex(of: "#"), let n = Int(key[key.index(after: hash)...]) else { return nil }
        zone = String(key[..<hash])
        index = n
    }
}

/// The strip under a desk: off, ice blue while its owner works there, warm orange while its owner is away waiting for you.
enum ZoneLED: Equatable { case off, ice, orange }

struct ZoneMember: Equatable {
    let id: String
    let name: String
    let zone: String?
    let state: ZoneState
    let since: Date
}

/// where a session is this pass. One of these for every session, from `ZonePlan.make`'s table and nothing else.
enum ZonePlace: Hashable {
    /// Its own desk (busy, seen, or unread / waiting with nowhere else to go).
    case desk(ZoneDesk)
    /// Its zone's sofa: a seat (`slot` in finish order), or a standing spot beside it.
    case sofaSeat(String, Int)
    case sofaSpot(String, Int)
    /// In front of the boss's desk, `slot` 0 the head; and an unzoned waiting one beyond the six, carrying the line on.
    case line(Int)
    case lobby(Int)
    /// The rest room: a seat, or counted on its "+N" pill and listed (not drawn).
    case rest(Int)
    case restListed
    /// Unzoned: on the check-in spot, or counted on its label and listed (not drawn).
    case checkIn
    case checkInListed
}

/// Who sits where this pass, and what each desk shows.
struct ZonePlan: Equatable {
    /// Twelve desks in each zone, 1–6 in one row, 7–12 in the other; desk 1 (the lead's) the south-most.
    static let desksPerZone = 12
    static let visitorKey = "visitor"

    /// every session's place (the table's answer); the lists below are read off it.
    var place: [String: ZonePlace] = [:]
    /// Each session's own desk, kept while it is away (sofa, line, …).
    var desks: [String: ZoneDesk] = [:]
    /// Zone → those of it with no desk this pass (the sign's "+N"), in the order they came.
    var overflow: [String: [String]] = [:]
    /// The one unzoned session at the check-in spot, and the rest of the unzoned not in the line (listed on its label).
    var visitor: String?
    var visitorList: [String] = []
    /// How many line up in front of the boss's desk when the art has no `queue_line` (the art's line says how many fit,
    /// `ZoneScene.lineCapacity`).
    static let lineLength = 6
    /// The waiting ones in front of the boss's desk, longest waiting first: the head on the queue spot, the rest behind.
    var line: [String] = []
    /// The one waiting longest, at the head of the line.
    var queue: String? { line.first }
    /// Zone → its sofa's sitters seat by seat (first finished first), and those standing at its spots.
    var sofa: [String: [String]] = [:]
    var sofaOverflow: [String: [String]] = [:]
    /// Unzoned waiting ones beyond the line (they have no sofa): they carry the line on.
    var lobby: [String] = []
    /// Name → desk key ("Web#3", or `visitorKey`) after this pass: what is remembered.
    var memory: [String: String] = [:]
    var screens: [ZoneDesk: Bool] = [:]
    var leds: [ZoneDesk: ZoneLED] = [:]
    /// the rest room is for those with no desk (their zone already has twelve owners), nothing else: seat by seat, then
    /// counted on its "+N" pill and listed.
    var rest: [String] = []
    var restOverflow: [String] = []

    func screenOn(_ desk: ZoneDesk) -> Bool { screens[desk] ?? false }
    func led(_ desk: ZoneDesk) -> ZoneLED { leds[desk] ?? .off }

    /// One step of a row of the table: a kind of place, tried in the row's order until one has room.
    enum Try: Equatable { case ownDesk, sofaSeat, sofaSpot, line, lobby, restRoom, checkIn }

    /// The placement table, one row per state, as the places to try in order. Every zoned session
    /// owns a desk while its zone has fewer than `desksPerZone` (twelve) owners; "seen" covers the office's resting ones too (nothing goes to
    /// the rest room for being old or put away).
    ///
    /// | state                         | where                                                        |
    /// | busy                          | own desk (no desk: rest room)                                |
    /// | done & unread (has-news, awaiting-reply) | sofa seat → sofa spot → own desk (no desk: seat → rest room) |
    /// | seen / idle, however long ago | own desk (no desk: rest room)                                |
    /// | waiting for the user          | line (as many as fit) → sofa spot → own desk (no desk: rest) |
    /// | unzoned                       | check-in spot; waiting ones join the line, then carry it on  |
    static func tries(_ state: ZoneState, zoned: Bool, hasDesk: Bool) -> [Try] {
        guard zoned else { return state == .waiting ? [.line, .lobby] : [.checkIn] }
        let home: Try = hasDesk ? .ownDesk : .restRoom
        switch state {
        case .busy, .seen, .resting: return [home]
        case .unread: return hasDesk ? [.sofaSeat, .sofaSpot, .ownDesk] : [.sofaSeat, .restRoom]
        case .waiting: return [.line, .sofaSpot, home]
        }
    }

    /// The plan for these sessions: each one's place by `tries`, and what each desk shows. `memory` is last pass's (name →
    /// desk key); `sofaSeats` how many seats each zone's sofa has in the art, `sofaSpots` how many stand by it, `restSeats`
    /// the rest room's seats. Who goes first where room is short: the finished in finish order, then the waiting longest
    /// first (`lineLength` for the line, whatever their zone; then the spots the finished left); the rest room's seats go
    /// to the busy, then the finished, the waiting and the seen, each the longest first. `lineLength`: how many the line
    /// holds (as many as fit along the art's `queue_line`).
    ///
    /// Off duty (off-duty mode): `offDuty` is the roster's names (name → its zone): they are not here, so a desk of theirs is free for
    /// others, except a resident's (`ZoneConfig.isResident`), which stays held for it. Their desks stay remembered by name.
    /// `holders` is last pass's desks (desk key → name): when two remember the same desk (one woke up to find a newcomer on
    /// it), the one sitting there keeps it and the other takes its zone's first free desk.
    static func make(_ members: [ZoneMember], config: ZoneConfig, memory: [String: String], sofaSeats: [String: Int], sofaSpots: [String: Int] = [:],
                     restSeats: Int = 0, lineLength: Int = ZonePlan.lineLength, offDuty: [String: String] = [:],
                     holders: [String: String] = [:]) -> ZonePlan {
        var plan = ZonePlan()
        var remembered = memory
        func zoneOf(_ m: ZoneMember) -> String? { m.zone.flatMap { config.zone($0) != nil ? $0 : nil } }
        let here = Set(members.map(\.name))

        // Desks: sticky by name, the lead on desk 1, newcomers on the lowest free of 2–12; beyond that none ("+N").
        var byZone: [String: [ZoneMember]] = [:]
        for m in members { if let code = zoneOf(m) { byZone[code, default: []].append(m) } }
        for zone in config.zones {
            guard let list = byZone[zone.code] else { continue }
            var taken: [Int: String] = [:]
            var others: [ZoneMember] = []
            for m in list {
                if let lead = zone.lead, m.name == lead, taken[1] == nil {
                    taken[1] = m.id
                    plan.desks[m.id] = ZoneDesk(zone: zone.code, index: 1)
                    remembered[m.name] = ZoneDesk(zone: zone.code, index: 1).key
                } else {
                    others.append(m)
                }
            }
            // an off-duty resident's desk is held for it while it is away.
            for (name, code) in offDuty.sorted(by: { $0.key < $1.key }) where code == zone.code && !here.contains(name) && config.isResident(name, zone: code) {
                guard let kept = remembered[name].flatMap({ ZoneDesk(key: $0) }), kept.zone == zone.code, kept.index >= 2,
                    kept.index <= desksPerZone, taken[kept.index] == nil
                else { continue }
                taken[kept.index] = "offduty:" + name
            }
            // whoever sat at its remembered desk last pass is placed first, so it keeps that desk.
            func sat(_ m: ZoneMember) -> Bool { remembered[m.name].map { holders[$0] == m.name } ?? false }
            others = others.filter(sat) + others.filter { !sat($0) }
            var newcomers: [ZoneMember] = []
            for m in others {
                let kept = remembered[m.name].flatMap { ZoneDesk(key: $0) }
                if let kept, kept.zone == zone.code, kept.index >= 2, kept.index <= desksPerZone, taken[kept.index] == nil {
                    taken[kept.index] = m.id
                    plan.desks[m.id] = kept
                } else {
                    newcomers.append(m)
                }
            }
            for m in newcomers {
                if let free = (2...desksPerZone).first(where: { taken[$0] == nil }) {
                    taken[free] = m.id
                    let desk = ZoneDesk(zone: zone.code, index: free)
                    plan.desks[m.id] = desk
                    remembered[m.name] = desk.key
                } else {
                    plan.overflow[zone.code, default: []].append(m.id)
                }
            }
        }

        // The table, in the order room is handed out.
        func older(_ a: ZoneMember, _ b: ZoneMember) -> Bool { a.since != b.since ? a.since < b.since : a.id < b.id }
        let unread = members.filter { $0.state == .unread }.sorted(by: older)
        let order = unread.filter { plan.desks[$0.id] != nil } + unread.filter { plan.desks[$0.id] == nil }
            + members.filter { $0.state == .waiting }.sorted(by: older) + members.filter { $0.state != .unread && $0.state != .waiting }
        var seats: [String: Int] = [:], spots: [String: Int] = [:], lineCount = 0, lobbyCount = 0
        var resting: [ZoneMember] = [], checking: [ZoneMember] = []
        for m in order {
            let code = zoneOf(m)
            for step in tries(m.state, zoned: code != nil, hasDesk: plan.desks[m.id] != nil) {
                var placed: ZonePlace?
                switch step {
                case .ownDesk: placed = plan.desks[m.id].map { .desk($0) }
                case .sofaSeat:
                    if let code, seats[code, default: 0] < sofaSeats[code] ?? 0 {
                        placed = .sofaSeat(code, seats[code, default: 0])
                        seats[code, default: 0] += 1
                    }
                case .sofaSpot:
                    if let code, spots[code, default: 0] < sofaSpots[code] ?? 0 {
                        placed = .sofaSpot(code, spots[code, default: 0])
                        spots[code, default: 0] += 1
                    }
                case .line:
                    if lineCount < lineLength {
                        placed = .line(lineCount)
                        lineCount += 1
                    }
                case .lobby:
                    placed = .lobby(lobbyCount)
                    lobbyCount += 1
                case .restRoom: resting.append(m)
                case .checkIn: checking.append(m)
                }
                if step == .restRoom || step == .checkIn { break }
                if let placed {
                    plan.place[m.id] = placed
                    break
                }
            }
        }
        // The rest room's seats: the busy first, then the finished, the waiting and the seen, each the longest first.
        let rank: [ZoneState: Int] = [.busy: 0, .unread: 1, .waiting: 2, .seen: 3, .resting: 3]
        resting.sort { (rank[$0.state] ?? 3, $0.since, $0.id) < (rank[$1.state] ?? 3, $1.since, $1.id) }
        for (i, m) in resting.enumerated() { plan.place[m.id] = i < restSeats ? .rest(i) : .restListed }
        // One check-in spot: whoever had it keeps it.
        let held = checking.first { remembered[$0.name] == visitorKey }
        if let first = held ?? checking.first {
            remembered[first.name] = visitorKey
            for m in checking { plan.place[m.id] = m.id == first.id ? .checkIn : .checkInListed }
        }

        // The lists the view and the signs read, off the places.
        plan.read(members)

        // What each desk shows (the table's "look"): busy → screen on, ice; waiting → orange (its desk is empty while it
        // queues); unread and seen → dark.
        for m in members {
            guard let desk = plan.desks[m.id] else { continue }
            switch m.state {
            case .busy:
                plan.screens[desk] = true
                plan.leds[desk] = .ice
            case .waiting:
                plan.leds[desk] = .orange
            case .unread, .seen, .resting:
                break
            }
        }
        // Closed sessions keep their desk for a comeback, within reason.
        if remembered.count > 400 {
            let open = here.union(offDuty.keys)  // the off-duty keep theirs for when they wake
            remembered = remembered.filter { open.contains($0.key) }
        }
        plan.memory = remembered
        return plan
    }

    /// The line, the sofas, the lobby, the rest room and check-in as lists in their slots' order, from `place`.
    private mutating func read(_ members: [ZoneMember]) {
        var line: [(Int, String)] = [], lobby: [(Int, String)] = [], rest: [(Int, String)] = []
        var seats: [String: [(Int, String)]] = [:], spots: [String: [(Int, String)]] = [:]
        for m in members {
            switch place[m.id] {
            case .line(let i)?: line.append((i, m.id))
            case .lobby(let i)?: lobby.append((i, m.id))
            case .rest(let i)?: rest.append((i, m.id))
            case .restListed?: restOverflow.append(m.id)
            case .sofaSeat(let z, let i)?: seats[z, default: []].append((i, m.id))
            case .sofaSpot(let z, let i)?: spots[z, default: []].append((i, m.id))
            case .checkIn?: visitor = m.id
            case .checkInListed?: visitorList.append(m.id)
            case .desk?, nil: break
            }
        }
        func sorted(_ list: [(Int, String)]) -> [String] { list.sorted { $0.0 < $1.0 }.map(\.1) }
        self.line = sorted(line)
        self.lobby = sorted(lobby)
        self.rest = sorted(rest)
        sofa = seats.mapValues(sorted)
        sofaOverflow = spots.mapValues(sorted)
    }
}

/// Where the desks are remembered between runs, by session name; never written by a read-only store.
@MainActor enum ZoneMemory {
    static let key = "zoneDeskBySession.v1"
    static var remembered: [String: String] = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    /// who sat at which desk last pass (desk key → name), in memory only: who keeps a desk two remember.
    static var holders: [String: String] = [:]
    /// each session's name last pass (id → name), in memory only, so a renamed one (/rename) keeps its desk.
    static var names: [String: String] = [:]

    /// the memory and the holders with a renamed session's desk carried from its old name to its new one (the same id
    /// under another name than last pass), unless its new name already remembers a desk or its old one is still in use.
    static func renamed(_ memory: [String: String], holders: [String: String], before: [String: String], members: [ZoneMember])
        -> (memory: [String: String], holders: [String: String]) {
        var memory = memory, holders = holders
        let here = Set(members.map(\.name))
        for m in members {
            guard let old = before[m.id], old != m.name, !here.contains(old), memory[m.name] == nil, let desk = memory[old] else { continue }
            memory[m.name] = desk
            memory[old] = nil
            for (key, name) in holders where name == old { holders[key] = m.name }
        }
        return (memory, holders)
    }

    static func keep(_ memory: [String: String], store: Store) {
        guard memory != remembered else { return }
        remembered = memory
        if !store.readOnly { UserDefaults.standard.set(memory, forKey: key) }
    }

    /// the memory after `mover` is dragged to `target` (by hand, long-press): its zone's desk 2–12 other than its own;
    /// the owner, if any, takes the mover's old desk (a swap), else the old desk is left free. Names are the sessions' (the
    /// memory's keys). Nil when the move is not allowed: no desk, the lead's desk 1 either side, another zone, its own desk.
    static func moved(_ memory: [String: String], plan: ZonePlan, names: [String: String], mover: String, to target: ZoneDesk) -> [String: String]? {
        guard let from = plan.desks[mover], let name = names[mover], from.zone == target.zone, from.index >= 2, target.index >= 2,
            target.index <= ZonePlan.desksPerZone, from != target
        else { return nil }
        var memory = memory
        memory[name] = target.key
        if let owner = plan.desks.first(where: { $0.value == target })?.key {
            guard let other = names[owner], other != name else { return nil }
            memory[other] = from.key
        }
        return memory
    }

    /// moves a desk by hand and keeps the result (on disk unless read-only); false when not allowed.
    static func move(_ store: Store, plan: ZonePlan, mover: String, to target: ZoneDesk) -> Bool {
        let names = Dictionary(store.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        guard let memory = moved(remembered, plan: plan, names: names, mover: mover, to: target) else { return false }
        keep(memory, store: store)
        return true
    }
}

extension ZonePlan {
    /// The members for a store: each session in its board group, with its zone.
    @MainActor static func members(_ store: Store, config: ZoneConfig, now: Date) -> [ZoneMember] {
        let b = Buckets(store, now: now)
        var result: [ZoneMember] = []
        // the office's resting ones (six hours on, or sent to rest from the menu) are simply seen here: at their desks.
        // an error not looked at is with the news (a sofa, its plate red or amber); an unexpected exit is seen (its own desk,
        // faint, its plate grey, its screen dark).
        let groups: [([Session], ZoneState)] = [(b.waiting, .waiting), (b.busy, .busy), (b.unread, .unread), (b.failed, .unread), (b.seen, .seen),
                                                (b.gone, .seen), (b.resting, .seen)]
        for (sessions, state) in groups {
            for s in sessions {
                result.append(ZoneMember(id: s.id, name: s.name, zone: config.resolve(name: s.name, cwd: s.cwd), state: state, since: s.since))
            }
        }
        return result
    }

    /// The plan for the store now, remembering its desks (in memory always, on disk unless read-only).
    @MainActor static func current(_ store: Store, scene: ZoneScene?, now: Date = Date()) -> ZonePlan {
        let config = ZoneConfigFile.current()
        var seats: [String: Int] = [:], spots: [String: Int] = [:]
        for sofa in scene?.sofas ?? [] {
            seats[sofa.zone] = sofa.seats.count
            // The art's standing spots; without any, as many in a short row behind it as it has seats.
            spots[sofa.zone] = sofa.overflow.isEmpty ? sofa.seats.count : sofa.overflow.count
        }
        var offDuty: [String: String] = [:]
        for (name, entry) in ZoneRosterFile.current() { offDuty[name] = config.resolve(name: name, cwd: entry.cwd) ?? entry.zone }
        let list = members(store, config: config, now: now)
        let carried = ZoneMemory.renamed(ZoneMemory.remembered, holders: ZoneMemory.holders, before: ZoneMemory.names, members: list)
        ZoneMemory.names = Dictionary(list.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let plan = make(list, config: config, memory: carried.memory, sofaSeats: seats,
                        sofaSpots: spots, restSeats: scene?.restSeats.count ?? 0, lineLength: scene?.lineCapacity ?? lineLength,
                        offDuty: offDuty, holders: carried.holders)
        ZoneMemory.keep(plan.memory, store: store)
        var holders: [String: String] = [:]
        for m in list { if let desk = plan.desks[m.id] { holders[desk.key] = m.name } }
        ZoneMemory.holders = holders
        return plan
    }
}

// ───────── The art's points ─────────

/// `points.json` from the Blender render: where every desk, seat, screen and sign is, in the picture's pixels (top-left
/// origin, y down). Read as it is; an optional field missing is skipped, logged once.
struct ZoneScene {
    struct Desk {
        var zone: String
        let index: Int
        let seat: CGPoint
        let floor: CGPoint?
        let screen: [CGPoint]
        let glow: CGRect?
        let led: [CGPoint]?
        /// the desk top's corners in the picture (its rounded outline's box, at the top's height), in the order
        /// back-left, back-right, front-right, front-left of the world's axes; empty when the art says too little.
        var top: [CGPoint] = []
        /// The whole desk as drawn: round its top and the same corners on the floor (its legs, its front), for keeping
        /// visitors off it; empty without `top`.
        var footprint: [CGPoint] = []
        /// The top's edge nearest the camera (the world's -Y side, away from the chair and the screen), from its left end
        /// to its right in the picture; nil without `top`.
        var near: (CGPoint, CGPoint)?
        /// Which way its chair faces, one metre of it in the picture's pixels on the floor; nil when the art does not say.
        var facing: CGVector?
        /// Where one who comes to see it stands: on the floor beside its chair, on the aisle side away from the desk and
        /// a little in front, along the chair's facing; nil when the art does not say enough.
        var stand: CGPoint?
        /// One metre along the aisle beside its chair, towards the camera, in the picture's pixels: where a second visitor
        /// steps to.
        var aisle: CGVector?

        /// its foreground layer (the desk as the render draws it, to cover what stands behind it), from
        /// `desks/desk-layers.json` beside points.json; nil without one (then nothing covers the figures).
        var layer: ZoneDeskLayer? = nil

        /// Whether a point of the picture is on the desk as drawn (its footprint).
        func covers(_ p: CGPoint) -> Bool { ZoneScene.inside(p, footprint) }
    }
    struct Sofa {
        var zone: String
        let seats: [CGPoint]
        /// Standing spots once the seats are taken, from the art when it has them.
        let overflow: [CGPoint]
        /// One step backwards from the sofa, in pixels, for a row behind it when the art gives no spots.
        let back: CGVector
        /// The sofa's middle on the floor (the art's `center`, else the middle of its seats).
        let center: CGPoint
        /// Where the art says it stands, for reading only: the room goes by the points, not by rows and columns.
        let row: Int?
        let column: Int?
        /// which way it faces, one metre of it on the floor in the picture's pixels; nil when the art does not say.
        var facing: CGVector? = nil
    }
    struct Sign {
        var zone: String
        let face: [CGPoint]
        let plate: [CGPoint]
        /// the anchor the zone's label is centred on (`center`, else the middle of its face). The art does not draw the
        /// plates; their quads are anchors only.
        var center: CGPoint
    }

    let size: CGSize
    var desks: [Desk]
    let boss: CGPoint?
    /// Where the head of the line stands: the start of the art's `queue_line`, else the boss desk's `queue_spot`.
    let queue: CGPoint?
    /// the art's waiting line, start (in front of the boss's desk) and end (by the purple island's lower corner); empty
    /// when it has none.
    var queueLine: [CGPoint] = []
    var sofas: [Sofa]
    let visitor: CGPoint?
    /// The check-in counter's sign face, when the art has one.
    let visitorSign: [CGPoint]?
    var signs: [Sign]
    /// The user's own desk (`kind: boss` among the desks), when the art has it.
    var bossDesk: Desk?
    /// Check-in is a spot to stand on (no desk, no sign), not a seat.
    let visitorStanding: Bool
    /// Pixels a metre upright, for the pets' height.
    let upright: CGFloat
    /// The rest room's seats (`rest_room.seats`: 4 sofa cushions and 2 armchairs in the top-left), empty without one.
    var restSeats: [CGPoint] = []
    /// the open floor's map for walking (islands, the boss's desk, the sofas, the railing and the pantry as obstacles);
    /// nil when the art says too little to place them.
    var walkMap: ZoneWalkMap?
    /// The art's islands (points.json `layout.zone_order`, else `zones[].name`), in the order the workzones take them; in a
    /// seated scene by the names the room goes by (`seated`).
    var islands: [String] = []
    /// the camera's view direction along the floor (world x, y; not unit length), from `desk-layers.json`; nil without
    /// desk layers.
    var forward: CGVector?

    /// every desk's layer (the workstations and the boss's), as the room draws them.
    var deskLayers: [ZoneDeskLayer] { (desks + (bossDesk.map { [$0] } ?? [])).compactMap(\.layer) }

    /// The desk layers read from `desk-layers.json` (cut from the seaview render), given to the desks
    /// they were cut for: by the art's own names (`Web_1`, …, `Boss_1`), so before `seated` renames the islands.
    mutating func attachLayers(_ data: Data, note: (String) -> Void = { log($0) }) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = root["desks"] as? [[String: Any]],
            let f = Self.point(root["camera_forward_world"])
        else {
            note("Seaview: desk-layers.json unreadable; desks drawn in the picture only")
            return
        }
        var byID: [String: ZoneDeskLayer] = [:]
        for entry in list { if let layer = ZoneDeskLayer(entry) { byID[layer.id] = layer } }
        for i in desks.indices { desks[i].layer = byID["\(desks[i].zone)_\(desks[i].index)"] }
        if bossDesk != nil, let boss = list.first(where: { $0["kind"] as? String == "boss" }), let id = boss["id"] as? String {
            bossDesk?.layer = byID[id]
        }
        forward = CGVector(dx: f.x, dy: f.y)
        let given = deskLayers.count
        if given < desks.count + (bossDesk == nil ? 0 : 1) { note("Seaview: desk layers for \(given) of \(desks.count + (bossDesk == nil ? 0 : 1)) desks") }
    }

    /// Which island each workzone sits on, island → zone code: a zone's own `island` when it names one not yet taken;
    /// then an island of the zone's own name; then, in the zones' order, the islands left over in the art's order. Zones
    /// past the last island get none.
    static func seating(_ zones: [ZoneConfig.Zone], islands: [String]) -> [String: String] {
        var seat: [String: String] = [:], placed = Set<String>()
        for zone in zones {
            guard let island = zone.island, islands.contains(island), seat[island] == nil else { continue }
            seat[island] = zone.code
            placed.insert(zone.code)
        }
        for zone in zones where !placed.contains(zone.code) && islands.contains(zone.code) && seat[zone.code] == nil {
            seat[zone.code] = zone.code
            placed.insert(zone.code)
        }
        var free = islands.filter { seat[$0] == nil }
        for zone in zones where !placed.contains(zone.code) && !free.isEmpty {
            seat[free.removeFirst()] = zone.code
            placed.insert(zone.code)
        }
        return seat
    }

    /// The scene with each island's desks, sofa and sign named by the workzone sitting there (`seating`), so the rest of
    /// the room goes by zone codes only. An island nobody sits on keeps its own name, unless a zone elsewhere has that
    /// code.
    func seated(_ zones: [ZoneConfig.Zone]) -> ZoneScene {
        let seat = Self.seating(zones, islands: islands)
        let codes = Set(zones.map(\.code))
        func label(_ island: String) -> String {
            guard islands.contains(island) else { return island }
            if let code = seat[island] { return code }
            return codes.contains(island) ? "island:" + island : island
        }
        var scene = self
        scene.desks = desks.map { var d = $0; d.zone = label(d.zone); return d }
        scene.desks.sort { $0.zone != $1.zone ? $0.zone < $1.zone : $0.index < $1.index }
        scene.sofas = sofas.map { var s = $0; s.zone = label(s.zone); return s }
        scene.signs = signs.map { var s = $0; s.zone = label(s.zone); return s }
        scene.islands = islands.map(label)
        return scene
    }

    /// The rest room's floor, for a click: round its seats, a pet's height above them and a little below.
    var restArea: CGRect? {
        guard !restSeats.isEmpty else { return nil }
        var r = CGRect.null
        for p in restSeats { r = r.union(CGRect(origin: p, size: .zero)) }
        return CGRect(x: r.minX - petHeight * 0.5, y: r.minY - petHeight, width: r.width + petHeight, height: r.height + petHeight * 1.35)
    }

    /// Where a visitor stands at the one it came to see: beside it, on its right, a little in front.
    func besideVisit(_ host: CGPoint) -> CGPoint { CGPoint(x: host.x + petHeight * 0.62, y: host.y + upright * 0.08) }

    /// Where a visitor stands at the one it came to see. At a desk: on the floor beside the host's chair, on the aisle
    /// side and a little in front (`Desk.stand`), never on the desk; elsewhere beside it. A spot another visitor
    /// already holds (`taken`), or one on any desk as drawn, moves a pet's width on along the aisle, a few times at most.
    ///
    /// `others` are where the figures round about stand (feet): a spot whose pet would cover one of them, or be covered
    /// (feet within about half a pet across and a pet's height up or down), is passed over too, for the clear spot a step or two along
    /// or across the aisle nearest its host; with none clear, the first spot.
    func visitSpot(_ host: CGPoint, taken: [CGPoint] = [], others: [CGPoint] = []) -> CGPoint {
        let desk = (desks + (bossDesk.map { [$0] } ?? [])).first { hypot($0.seat.x - host.x, $0.seat.y - host.y) < 1 }
        let start = desk?.stand ?? besideVisit(host)
        var step = desk?.aisle ?? CGVector(dx: -0.65, dy: 0.76)
        let length = max(0.001, hypot(step.dx, step.dy))
        step = CGVector(dx: step.dx / length * petHeight * 0.75, dy: step.dy / length * petHeight * 0.75)
        func blocked(_ p: CGPoint) -> Bool {
            taken.contains { hypot($0.x - p.x, $0.y - p.y) < petHeight * 0.6 } || desks.contains(where: { $0.covers(p) }) || bossDesk?.covers(p) == true
        }
        func crowded(_ p: CGPoint) -> Bool { others.contains { abs($0.x - p.x) < petHeight * 0.55 && abs($0.y - p.y) < petHeight * 1.05 } }
        var spot = start
        for _ in 0..<6 {
            guard blocked(spot) else { break }
            spot = CGPoint(x: spot.x + step.dx, y: spot.y + step.dy)
        }
        guard crowded(spot) else { return spot }
        // VISIT: at a desk the visitor keeps to the aisle beside its host's row: the stand spot, else half to one body's width along the
        // aisle either way (the clear one nearest its host), else the stand spot itself, overlapping a little. It never goes
        // across the aisle, to another row or onto a desk. `visitSpotLegacy` (defaults) = YES brings back the first search below.
        let legacy = UserDefaults.standard.bool(forKey: "visitSpotLegacy")
        if !legacy, desk?.stand != nil {
            var best: (CGFloat, CGPoint)?
            for k in [-1, -0.6, 0.6, 1] as [CGFloat] {
                let p = CGPoint(x: spot.x + step.dx * Self.visitBody / 0.75 * k, y: spot.y + step.dy * Self.visitBody / 0.75 * k)
                guard !blocked(p), !crowded(p) else { continue }
                let d = hypot(p.x - host.x, p.y - host.y)
                if best == nil || d < best!.0 { best = (d, p) }
            }
            return best?.1 ?? spot
        }
        // Steps along the aisle and across it, the clear one nearest its host (but not on it) taken.
        let across = CGVector(dx: -step.dy * 0.8, dy: step.dx * 0.8)
        var best: (CGFloat, CGPoint)?
        for a in [-2, -1, 0, 1, 2] as [CGFloat] {
            for b in [-1, 0, 1] as [CGFloat] where a != 0 || b != 0 {
                let p = CGPoint(x: spot.x + step.dx * a + across.dx * b, y: spot.y + step.dy * a + across.dy * b)
                let d = hypot(p.x - host.x, p.y - host.y)
                guard !blocked(p), !crowded(p), abs(p.x - host.x) >= petHeight * 0.45 || abs(p.y - host.y) >= petHeight * 1.05 else { continue }
                if best == nil || d < best!.0 { best = (d, p) }
            }
        }
        return best?.1 ?? spot
    }

    /// A pet's size factor: its idle frame's opaque box, max(height, width × 0.85), comes to `target`; the same
    /// factor for every pose, so a wide pet is not huge and a pose drawn smaller in the sheet stays as drawn.
    static func petFactor(tall: Int, wide: Int, target: CGFloat) -> CGFloat {
        target / max(CGFloat(max(tall, 1)), CGFloat(wide) * 0.85)
    }

    /// How tall a pet stands, in metres: about 150 px in the 2400 × 1600 picture (standing at the desks;
    /// had 114 px), where a metre upright is
    /// 83.1 px.
    static let petMeters: CGFloat = 1.805
    var petHeight: CGFloat { upright * Self.petMeters }
    /// From one in the line to the next: about 170 px in the 2400 px picture so the plates have room.
    var lineStep: CGFloat { petHeight * 1.13 }

    func desk(_ d: ZoneDesk) -> Desk? { desks.first { $0.zone == d.zone && $0.index == d.index } }

    static func point(_ value: Any?) -> CGPoint? {
        guard let list = value as? [Any], list.count >= 2, let x = list[0] as? NSNumber, let y = list[1] as? NSNumber else { return nil }
        return CGPoint(x: x.doubleValue, y: y.doubleValue)
    }

    /// A point given as `[x, y]` or as `{"pixel": [x, y]}`.
    static func pixel(_ value: Any?) -> CGPoint? {
        if let p = point(value) { return p }
        return point((value as? [String: Any])?["pixel"])
    }

    static func quad(_ value: Any?) -> [CGPoint]? {
        guard let list = value as? [Any] else { return nil }
        var points: [CGPoint] = []
        for item in list {
            guard let p = point(item) else { return nil }
            points.append(p)
        }
        return points.count >= 3 ? points : nil
    }

    static func bounds(_ value: Any?) -> CGRect? {
        guard let entry = value as? [String: Any], let a = point(entry["min_pixel"]), let b = point(entry["max_pixel"]) else { return nil }
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    static func vector(_ value: Any?) -> CGVector? {
        guard let p = point(value) else { return nil }
        return CGVector(dx: p.x, dy: p.y)
    }

    /// a desk's top, footprint, near edge and chair facing, from its centre (world and picture), the camera's axes and
    /// its LED strips' world corners (which run round the top's rim). Left as they are when any of it is missing.
    static func shapeDesk(_ desk: inout Desk, _ d: [String: Any], xAxis: CGVector?, yAxis: CGVector?, zAxis: CGVector?) {
        guard let xAxis, let yAxis, let centre = d["desk_center"] as? [String: Any], let middle = point(centre["pixel"]),
            let world = centre["world"] as? [NSNumber], world.count >= 2
        else { return }
        let z = zAxis ?? CGVector(dx: 0, dy: -83.1)
        let cx = CGFloat(world[0].doubleValue), cy = CGFloat(world[1].doubleValue)
        func at(_ x: CGFloat, _ y: CGFloat, _ h: CGFloat) -> CGPoint {
            CGPoint(x: middle.x + (x - cx) * xAxis.dx + (y - cy) * yAxis.dx + h * z.dx, y: middle.y + (x - cx) * xAxis.dy + (y - cy) * yAxis.dy + h * z.dy)
        }
        if let facing = point(d["chair_facing_world"]) {
            desk.facing = CGVector(dx: facing.x * xAxis.dx + facing.y * yAxis.dx, dy: facing.x * xAxis.dy + facing.y * yAxis.dy)
        }
        var lo = CGPoint(x: CGFloat.infinity, y: CGFloat.infinity), hi = CGPoint(x: -CGFloat.infinity, y: -CGFloat.infinity), height: CGFloat = 0
        for strip in d["desk_led_strips"] as? [[String: Any]] ?? [] {
            for corner in strip["quad_world"] as? [[NSNumber]] ?? [] where corner.count >= 3 {
                let x = CGFloat(corner[0].doubleValue), y = CGFloat(corner[1].doubleValue)
                lo = CGPoint(x: min(lo.x, x), y: min(lo.y, y))
                hi = CGPoint(x: max(hi.x, x), y: max(hi.y, y))
                height = max(height, CGFloat(corner[2].doubleValue))
            }
        }
        guard lo.x < hi.x, lo.y < hi.y, height > 0 else { return }
        desk.top = [at(lo.x, hi.y, height), at(hi.x, hi.y, height), at(hi.x, lo.y, height), at(lo.x, lo.y, height)]
        desk.footprint = hull(desk.top + [at(lo.x, hi.y, 0), at(hi.x, hi.y, 0), at(hi.x, lo.y, 0), at(lo.x, lo.y, 0)])
        let a = at(lo.x, lo.y, height), b = at(hi.x, lo.y, height)
        desk.near = a.x <= b.x ? (a, b) : (b, a)
        if let seat = (d["chair_seat"] as? [String: Any])?["world"] as? [NSNumber], seat.count >= 2 {
            let sx = CGFloat(seat[0].doubleValue), sy = CGFloat(seat[1].doubleValue)
            let away: CGFloat = sx >= cx ? 1 : -1  // the chair's side of the desk, out into the aisle
            let face = point(d["chair_facing_world"]) ?? CGPoint(x: 0, y: -1)
            desk.stand = at(sx + away * Self.visitAside + face.x * Self.visitAhead, sy + face.y * Self.visitAhead, 0)
            desk.aisle = CGVector(dx: -yAxis.dx, dy: -yAxis.dy)
        }
    }

    /// How far a visitor stands out from the chair into the aisle, and in front of it along its facing, in metres.
    static let visitAside: CGFloat = 1.0
    static let visitAhead: CGFloat = 0.2
    /// How far along the aisle a crowded stand spot gives way, in pet heights (VISIT): about a body's width.
    static let visitBody: CGFloat = 0.5

    /// The convex hull of some points, anticlockwise on the screen's y-down axes.
    static func hull(_ points: [CGPoint]) -> [CGPoint] {
        let p = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Whether a point is inside a polygon (even-odd); false for fewer than three corners.
    static func inside(_ p: CGPoint, _ polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var hit = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { hit.toggle() }
            j = i
        }
        return hit
    }

    static func parse(_ data: Data, note: (String) -> Void = { log($0) }) -> ZoneScene? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            note("Seaview: points.json is not JSON")
            return nil
        }
        var missing = Set<String>()
        let resolution = root["resolution"] as? [String: Any] ?? [:]
        let width = (resolution["width"] as? NSNumber)?.doubleValue ?? 0, height = (resolution["height"] as? NSNumber)?.doubleValue ?? 0
        guard width > 0, height > 0 else {
            note("Seaview: points.json has no resolution")
            return nil
        }
        let scale = root["pixel_scale"] as? [String: Any] ?? [:]
        let axes = scale["axes"] as? [String: Any] ?? [:]
        var upright = (scale["sprite_vertical_pixels_per_meter"] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 0
        if upright <= 0, let z = (axes["z"] as? [String: Any])?["pixels_per_meter"] as? NSNumber { upright = CGFloat(z.doubleValue) }
        if upright <= 0 {
            missing.insert("pixel_scale")
            upright = 33
        }
        let xAxis = vector((axes["x"] as? [String: Any])?["pixel_vector_per_meter"])
        let yAxis = vector((axes["y"] as? [String: Any])?["pixel_vector_per_meter"])

        var desks: [Desk] = []
        var bossDesk: Desk?
        for item in root["desks"] as? [Any] ?? [] {
            guard let d = item as? [String: Any] else { continue }
            let kind = d["kind"] as? String ?? "workstation"
            guard kind == "workstation" || kind == "boss" else { continue }
            guard let zone = d["zone"] as? String, let index = (d["index"] as? NSNumber)?.intValue, let seat = pixel(d["chair_seat"]) else {
                missing.insert("desk fields")
                continue
            }
            let screen = quad(d["screen_quad"]) ?? []
            if screen.isEmpty { missing.insert("screen_quad") }
            let led = quad(d["desk_led_quad"]) ?? quad(d["led_quad"]) ?? quad(d["led_strip_quad"])
            var desk = Desk(zone: zone, index: index, seat: seat, floor: pixel(d["desk_center"]), screen: screen,
                            glow: bounds(d["screen_glow_bounds"]), led: led)
            Self.shapeDesk(&desk, d, xAxis: xAxis, yAxis: yAxis, zAxis: vector((axes["z"] as? [String: Any])?["pixel_vector_per_meter"]))
            if kind == "boss" { bossDesk = desk } else { desks.append(desk) }
        }
        desks.sort { $0.zone != $1.zone ? $0.zone < $1.zone : $0.index < $1.index }

        let bossEntry = root["boss_desk"] as? [String: Any]
        let boss = pixel(bossEntry?["chair_seat"])
        // the art's line, from in front of the boss's desk (towards the purple island, above the sofa row); the old
        // queue spot only without it.
        var queueLine: [CGPoint] = []
        for item in root["queue_line"] as? [Any] ?? [] { if let p = pixel(item) { queueLine.append(p) } }
        if queueLine.count < 2 { queueLine = [] }
        let queue = queueLine.first ?? pixel(bossEntry?["queue_spot"])
        if queue == nil { missing.insert("boss_desk.queue_spot") }

        var sofas: [Sofa] = []
        for item in root["sofas"] as? [Any] ?? [] {
            guard let s = item as? [String: Any], let zone = s["zone"] as? String else { continue }
            var seats: [CGPoint] = []
            for seat in s["seats"] as? [Any] ?? [] { if let p = pixel(seat) { seats.append(p) } }
            var overflow: [CGPoint] = []
            for spot in s["overflow"] as? [Any] ?? [] { if let p = pixel(spot) { overflow.append(p) } }
            var back = CGVector(dx: 0, dy: -upright * 0.7)
            var faces: CGVector?
            if let facing = point(s["facing_direction_world"]), let xAxis, let yAxis {
                let dx = -(facing.x * xAxis.dx + facing.y * yAxis.dx), dy = -(facing.x * xAxis.dy + facing.y * yAxis.dy)
                back = CGVector(dx: dx * 0.7, dy: dy * 0.7)
                faces = CGVector(dx: -dx, dy: -dy)
            }
            var middle = CGPoint.zero
            for p in seats { middle = CGPoint(x: middle.x + p.x / CGFloat(seats.count), y: middle.y + p.y / CGFloat(seats.count)) }
            let center = pixel(s["center"]) ?? middle
            sofas.append(Sofa(zone: zone, seats: seats, overflow: overflow, back: back, center: center,
                              row: (s["row"] as? NSNumber)?.intValue, column: (s["column"] as? NSNumber)?.intValue, facing: faces))
        }

        let visitorEntry = root["visitor_desk"] as? [String: Any]
        let visitor = pixel(visitorEntry?["seat"]) ?? pixel(visitorEntry?["chair_seat"])
        let visitorStanding = visitorEntry?["standing"] as? Bool ?? false
        let signEntry = visitorEntry?["sign"] as? [String: Any]
        let visitorSign = quad(signEntry?["face_quad"]) ?? quad(visitorEntry?["face_quad"]) ?? quad(visitorEntry?["sign_quad"])
            ?? quad(signEntry?["plate_quad"]) ?? quad(visitorEntry?["plate_quad"])

        var signs: [Sign] = []
        for item in root["zone_signs"] as? [Any] ?? [] {
            guard let s = item as? [String: Any], let zone = s["zone"] as? String else { continue }
            let plate = quad(s["plate_quad"]) ?? []
            guard let face = quad(s["face_quad"]) ?? (plate.isEmpty ? nil : plate) else { continue }
            let box = ZoneScene.box(face)
            signs.append(Sign(zone: zone, face: face, plate: plate.isEmpty ? face : plate, center: pixel(s["center"]) ?? CGPoint(x: box.midX, y: box.midY)))
        }
        var restSeats: [CGPoint] = []
        for seat in (root["rest_room"] as? [String: Any])?["seats"] as? [Any] ?? [] { if let p = pixel(seat) { restSeats.append(p) } }
        let walkMap = ZoneWalkMap.make(root, xAxis: xAxis, yAxis: yAxis, zAxis: vector((axes["z"] as? [String: Any])?["pixel_vector_per_meter"]))
        if restSeats.isEmpty { missing.insert("rest_room.seats") }
        if !missing.isEmpty { note("Seaview: points.json lacks \(missing.sorted().joined(separator: ", ")); drawn without them") }
        var scene = ZoneScene(size: CGSize(width: width, height: height), desks: desks, boss: boss, queue: queue, queueLine: queueLine, sofas: sofas,
                              visitor: visitor, visitorSign: visitorSign, signs: signs, bossDesk: bossDesk, visitorStanding: visitorStanding,
                              upright: upright, restSeats: restSeats, walkMap: walkMap)
        scene.islands = islandNames(root)
        return scene
    }

    /// The islands of points.json in their order: `layout.zone_order`, else `zones[].name`, else the workstations' zones
    /// as they come.
    static func islandNames(_ root: [String: Any]) -> [String] {
        if let order = (root["layout"] as? [String: Any])?["zone_order"] as? [String], !order.isEmpty { return order }
        let named = (root["zones"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
        if !named.isEmpty { return named }
        var seen: [String] = []
        for item in root["desks"] as? [Any] ?? [] {
            guard let d = item as? [String: Any], (d["kind"] as? String ?? "workstation") == "workstation", let zone = d["zone"] as? String,
                !seen.contains(zone) else { continue }
            seen.append(zone)
        }
        return seen
    }

    /// The box round some points; zero for none.
    static func box(_ points: [CGPoint]) -> CGRect {
        var r = CGRect.null
        for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.isNull ? .zero : r
    }

    /// Where the `slot`th standing one waits beside a full sofa: the art's spot, else in a short row behind it.
    func sofaOverflow(_ zone: String, slot: Int) -> CGPoint? {
        guard let sofa = sofas.first(where: { $0.zone == zone }) else { return nil }
        if slot < sofa.overflow.count { return sofa.overflow[slot] }
        guard let first = sofa.seats.first else { return nil }
        let last = sofa.seats.last ?? first
        var along = CGVector(dx: last.x - first.x, dy: last.y - first.y)
        let length = (along.dx * along.dx + along.dy * along.dy).squareRoot()
        let step = upright * 0.55
        along = length > 0 ? CGVector(dx: along.dx / length * step, dy: along.dy / length * step) : CGVector(dx: step, dy: 0)
        let rank = slot - sofa.overflow.count
        let middle = CGPoint(x: (first.x + last.x) / 2 + sofa.back.dx, y: (first.y + last.y) / 2 + sofa.back.dy)
        // 0, -1, +1, -2, +2 … steps along the sofa from its middle.
        let offset = CGFloat(rank % 2 == 0 ? (rank + 1) / 2 : -(rank + 1) / 2)
        return CGPoint(x: middle.x + along.dx * offset, y: middle.y + along.dy * offset)
    }

    /// how many stand in the line: as many as fit along the art's `queue_line`, `lineStep` apart (7 in the current art's 1133 px);
    /// without one, the old six.
    var lineCapacity: Int {
        guard queueLine.count >= 2 else { return ZonePlan.lineLength }
        let length = hypot(queueLine[1].x - queueLine[0].x, queueLine[1].y - queueLine[0].y)
        return max(1, Int((length / lineStep).rounded(.down)) + 1)
    }

    /// Where the `slot`th in the line stands. along the art's `queue_line`, from its start (in front of the boss's desk)
    /// towards its end (the purple island's corner), `lineStep` (about 170 px) apart. Without one (older art), from the queue spot towards
    /// the middle of the sofas, bending gently.
    func lineSpot(_ slot: Int) -> CGPoint? {
        if queueLine.count >= 2 {
            let a = queueLine[0], b = queueLine[1]
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { return a }
            let k = lineStep * CGFloat(slot) / length
            return CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
        }
        guard let head = queue else { return nil }
        guard slot > 0 else { return head }
        var mean = CGPoint.zero
        for s in sofas { mean = CGPoint(x: mean.x + s.center.x / CGFloat(sofas.count), y: mean.y + s.center.y / CGFloat(sofas.count)) }
        var along = sofas.isEmpty ? CGVector(dx: 1, dy: -0.5) : CGVector(dx: mean.x - head.x, dy: mean.y - head.y)
        let length = (along.dx * along.dx + along.dy * along.dy).squareRoot()
        along = length > 0 ? CGVector(dx: along.dx / length, dy: along.dy / length) : CGVector(dx: 1, dy: 0)
        let turn = Self.lineTurn * .pi / 180
        along = CGVector(dx: along.dx * cos(turn) - along.dy * sin(turn), dy: along.dx * sin(turn) + along.dy * cos(turn))
        var side = CGVector(dx: -along.dy, dy: along.dx)
        if side.dy > 0 { side = CGVector(dx: -side.dx, dy: -side.dy) }
        let k = CGFloat(slot)
        let bend = lineStep * Self.lineBend * k * k
        return CGPoint(x: head.x + along.dx * lineStep * k + side.dx * bend, y: head.y + along.dy * lineStep * k + side.dy * bend)
    }

    /// Where the `slot`th unzoned waiting one beyond the line stands. a second row just in front of the line (towards the
    /// camera), half a step along, so it stays on the open floor in the picture; older art: carrying the line on.
    func lobby(slot: Int) -> CGPoint? {
        guard queueLine.count >= 2 else { return lineSpot(ZonePlan.lineLength + slot) }
        let capacity = lineCapacity
        guard let p = lineSpot(slot % capacity), let a = lineSpot(0), let b = lineSpot(1) else { return nil }
        let along = CGVector(dx: b.x - a.x, dy: b.y - a.y), length = max(0.001, hypot(b.x - a.x, b.y - a.y))
        var front = CGVector(dx: -along.dy / length, dy: along.dx / length)
        if front.dy < 0 { front = CGVector(dx: -front.dx, dy: -front.dy) }
        let row = CGFloat(1 + slot / capacity) * lineStep * 0.55
        return CGPoint(x: p.x + along.dx / length * lineStep * 0.5 + front.dx * row, y: p.y + along.dy / length * lineStep * 0.5 + front.dy * row)
    }
    /// For older art without a `queue_line`: how far the line turns from the sofas' middle towards the front (degrees,
    /// clockwise on the screen), and how much it bends towards the back each step (negative: towards the front).
    static let lineTurn: CGFloat = 16
    static let lineBend: CGFloat = -0.02
}

/// one desk's foreground layer: the desk (its top, sides, screens and things on it) cut from the render where it is
/// the nearest thing to the camera, in three lighting states (off, screen lit, LED lit; the lit ones only round their
/// lights), and its footprint on the floor for telling whether a figure stands behind it or in front.
struct ZoneDeskLayer: Equatable {
    /// The art's name for the desk (`Web_1`, `Boss_1`): its files are `desks/<id>.png`, `<id>_screen.png`, `<id>_led.png`.
    let id: String
    /// Where each picture goes, in the picture's pixels; nil for a state it has no picture of.
    let box: CGRect
    let screenBox: CGRect?
    let ledBox: CGRect?
    /// The desk centre's y in the picture: its place in the front-to-back order (on the floor, y and depth go together).
    let sortY: CGFloat
    /// Its footprint on the floor, in world metres: the centre, the unit along its width (u; v is u turned a quarter
    /// anticlockwise), and the extent along u and v from the centre (minX…maxX along u, minY…maxY along v).
    let center: CGPoint
    let u: CGVector
    let extent: CGRect
    /// The art's row on its island (0: the far one, its chairs behind the desks), for reading only.
    let row: Int?

    init?(_ d: [String: Any]) {
        func rect(_ value: Any?) -> CGRect? {
            guard let list = value as? [NSNumber], list.count >= 4 else { return nil }
            let v = list.map { CGFloat($0.doubleValue) }
            return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        }
        let layers = d["layers"] as? [String: Any] ?? [:]
        guard let id = d["id"] as? String, let box = rect((layers["off"] as? [String: Any])?["box_px"]) ?? rect(d["box_px"]),
            let sortY = (d["sort_y_px"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
            let fp = d["footprint"] as? [String: Any], let c = ZoneScene.point(fp["center_world"]),
            let yaw = (fp["yaw_rad"] as? NSNumber).map({ CGFloat($0.doubleValue) }),
            let e = (fp["local_min_max_m"] as? [NSNumber])?.map({ CGFloat($0.doubleValue) }), e.count >= 4
        else { return nil }
        self.id = id
        self.box = box
        screenBox = rect((layers["screen"] as? [String: Any])?["box_px"])
        ledBox = rect((layers["led"] as? [String: Any])?["box_px"])
        self.sortY = sortY
        center = c
        u = CGVector(dx: cos(yaw), dy: sin(yaw))
        extent = CGRect(x: e[0], y: e[1], width: e[2] - e[0], height: e[3] - e[1])
        row = (d["row"] as? NSNumber)?.intValue
    }
}

/// front to back with the desk layers. A figure's place in the order is its feet's y in the picture (on the floor y
/// and the camera's depth go together), held behind every desk it stands behind and in front of every desk it stands in
/// front of, among the desks whose layer its picture overlaps. Behind or in front is not the feet's depth against the
/// desk centre's (walking along a desk's back, the feet pass the centre's depth half way along and would come out in
/// front): the feet against the desk's footprint, seen along the camera. Along either of the footprint's axes, beyond its
/// far side is behind, short of its near side in front; neither (a corner, or on it) falls back to the depth.
enum ZoneOcclusion {
    enum Side: Equatable { case behind, front }

    /// Where floor point `w` (world metres) is from a desk, the camera looking along `forward`; nil for neither.
    static func side(of w: CGPoint, _ desk: ZoneDeskLayer, forward: CGVector) -> Side? {
        let dx = w.x - desk.center.x, dy = w.y - desk.center.y
        let v = CGVector(dx: -desk.u.dy, dy: desk.u.dx)
        let pu = dx * desk.u.dx + dy * desk.u.dy, pv = dx * v.dx + dy * v.dy
        let fu = forward.dx * desk.u.dx + forward.dy * desk.u.dy, fv = forward.dx * v.dx + forward.dy * v.dy
        var behind = false, front = false
        for (p, f, lo, hi) in [(pu, fu, desk.extent.minX, desk.extent.maxX), (pv, fv, desk.extent.minY, desk.extent.maxY)] where abs(f) > 1e-6 {
            behind = behind || (f > 0 ? p > hi : p < lo)
            front = front || (f > 0 ? p < lo : p > hi)
        }
        if behind != front { return behind ? .behind : .front }
        return nil
    }

    /// How far a figure's key keeps off a desk's, in picture pixels.
    static let gap: CGFloat = 0.01

    /// A figure's place in the order (a picture y): feet at `feet` and its picture over `box` (both in picture pixels).
    static func key(feet: CGPoint, box: CGRect, scene: ZoneScene) -> CGFloat {
        guard let forward = scene.forward, let map = scene.walkMap else { return feet.y }
        return key(feet: feet, box: box, desks: scene.deskLayers, forward: forward, map: map)
    }

    /// The same with the scene's desk layers, view and floor in hand (a walk asks a few hundred times).
    static func key(feet: CGPoint, box: CGRect, desks: [ZoneDeskLayer], forward: CGVector, map: ZoneWalkMap) -> CGFloat {
        let w = map.world(feet)
        var lo = -CGFloat.infinity, hi = CGFloat.infinity
        for desk in desks where desk.box.intersects(box) {
            switch side(of: w, desk, forward: forward) {
            case .behind?: hi = min(hi, desk.sortY - gap)
            case .front?: lo = max(lo, desk.sortY + gap)
            case nil: break
            }
        }
        guard lo <= hi else { return feet.y }
        return min(max(feet.y, lo), hi)
    }
}

/// The art: the picture and its points, found beside the app's resources (`zone3d`), beside the binary, or in the
/// source tree; nil without a `points.json`.
@MainActor enum ZoneArt {
    static var folder: String? = {
        let candidates: [String?] = [
            Bundle.main.resourceURL?.appendingPathComponent("zone3d").path,
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("zone3d").path,
            FileManager.default.currentDirectoryPath + "/themes/seaview/assets",
        ]
        for c in candidates {
            if let c, FileManager.default.fileExists(atPath: c + "/points.json") { return c }
        }
        return nil
    }()
    private static var loaded: (String, ZoneScene?)?
    private static var pictures: [String: CGImage] = [:]
    private static var absent = Set<String>()

    private static var seatedFor: (folder: String, zones: [ZoneConfig.Zone], scene: ZoneScene)?

    /// The art as points.json names it: its islands by their own names.
    static var plainScene: ZoneScene? {
        guard let folder else { return nil }
        if let loaded, loaded.0 == folder { return loaded.1 }
        var parsed = FileManager.default.contents(atPath: folder + "/points.json").flatMap { ZoneScene.parse($0) }
        // the desks' foreground layers, when the art has them.
        if let data = FileManager.default.contents(atPath: folder + "/desks/desk-layers.json") { parsed?.attachLayers(data) }
        loaded = (folder, parsed)
        return parsed
    }

    /// The art with the workzones in their seats (`ZoneScene.seated`), worked out again when the workzones change.
    static var scene: ZoneScene? {
        guard let folder, let plain = plainScene else { return nil }
        let zones = ZoneConfigFile.current().zones
        if let seatedFor, seatedFor.folder == folder, seatedFor.zones == zones { return seatedFor.scene }
        let scene = plain.seated(zones)
        seatedFor = (folder, zones, scene)
        return scene
    }

    /// `night_base`, `night_screens` or `night_leds` (or `desks/<id>…`); nil when the file is not there (yet).
    static func picture(_ name: String) -> CGImage? {
        guard let folder else { return nil }
        let path = folder + "/" + name + ".png"
        if let known = pictures[path] { return known }
        if absent.contains(path) { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            absent.insert(path)
            return nil
        }
        pictures[path] = image
        return image
    }

    /// Forget what was read, for a check that swaps the folder.
    static func reset(_ newFolder: String?) {
        folder = newFolder
        loaded = nil
        pictures = [:]
        absent = []
    }
}

/// The scene fills the view (aspect-fill, centred, the edges cropped): from the picture's pixels to the view's points.
struct ZoneFit: Equatable {
    let scale: CGFloat
    let offset: CGPoint

    init(scene: CGSize, view: CGSize) {
        guard scene.width > 0, scene.height > 0 else {
            scale = 0
            offset = .zero
            return
        }
        scale = max(view.width / scene.width, view.height / scene.height)
        offset = CGPoint(x: (view.width - scene.width * scale) / 2, y: (view.height - scene.height * scale) / 2)
    }

    func point(_ p: CGPoint) -> CGPoint { CGPoint(x: offset.x + p.x * scale, y: offset.y + p.y * scale) }
    func rect(_ r: CGRect) -> CGRect { CGRect(x: offset.x + r.minX * scale, y: offset.y + r.minY * scale, width: r.width * scale, height: r.height * scale) }
    func back(_ p: CGPoint) -> CGPoint { scale > 0 ? CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) : CGPoint(x: -1, y: -1) }
}

// ───────── Walking ─────────

/// the room's floor for walking, in world metres (x right, y back) where the islands are plain rectangles. Obstacles:
/// each zone's island (its rug: the desks and their chairs), the boss's desk, each sofa, and (taken from the
/// render as points.json does not have them) the railing at the back and the open pantry's cabinet run and high table. The
/// rest corner and the pantry have no walls any more. A walk takes the shortest way round them by their corners
/// (a visibility graph, its links worked out once), so it keeps to the aisles between and in front of the islands and
/// round the sofas. A spot inside an obstacle (a chair on its island's edge, a sofa seat) is left and reached straight,
/// out its nearest side.
struct ZoneWalkMap {
    /// A rectangle on the floor, turned by `u` (unit, along its width).
    struct Box: Equatable {
        let center: CGPoint
        let u: CGVector
        let half: CGSize
        var name = ""

        func local(_ p: CGPoint) -> CGPoint {
            let dx = p.x - center.x, dy = p.y - center.y
            return CGPoint(x: dx * u.dx + dy * u.dy, y: -dx * u.dy + dy * u.dx)
        }
        func world(_ q: CGPoint) -> CGPoint { CGPoint(x: center.x + q.x * u.dx - q.y * u.dy, y: center.y + q.x * u.dy + q.y * u.dx) }
        func contains(_ p: CGPoint, grow: CGFloat) -> Bool {
            let q = local(p)
            return abs(q.x) < half.width + grow && abs(q.y) < half.height + grow
        }
        func corners(grow: CGFloat) -> [CGPoint] {
            let w = half.width + grow, h = half.height + grow
            return [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)].map(world)
        }
        /// Whether the segment runs through the box (grown), not merely touching its rim.
        func blocks(_ a: CGPoint, _ b: CGPoint, grow: CGFloat) -> Bool {
            let p = local(a), q = local(b)
            let w = half.width + grow - 1e-4, h = half.height + grow - 1e-4
            var t0: CGFloat = 0, t1: CGFloat = 1
            let d = CGVector(dx: q.x - p.x, dy: q.y - p.y)
            for (pe, qe) in [(-d.dx, p.x + w), (d.dx, w - p.x), (-d.dy, p.y + h), (d.dy, h - p.y)] {
                if abs(pe) < 1e-12 {
                    if qe < 0 { return false }
                    continue
                }
                let t = qe / pe
                if pe < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
                if t0 > t1 { return false }
            }
            return (t1 - t0) * hypot(d.dx, d.dy) > 1e-3
        }
        /// The nearest point just outside the box (grown), straight out its nearest side.
        func exit(_ p: CGPoint, grow: CGFloat, margin: CGFloat) -> CGPoint {
            let q = local(p)
            let w = half.width + grow + margin, h = half.height + grow + margin
            let sides = [(w - q.x, CGPoint(x: w, y: q.y)), (q.x + w, CGPoint(x: -w, y: q.y)), (h - q.y, CGPoint(x: q.x, y: h)), (q.y + h, CGPoint(x: q.x, y: -h))]
            return world(sides.min { $0.0 < $1.0 }!.1)
        }
    }

    let boxes: [Box]
    /// The picture's pixel of the world's origin on the floor, and a metre along x, y and up, in pixels.
    let origin: CGPoint
    let xAxis: CGVector
    let yAxis: CGVector
    /// Spots above the floor (sofa and rest-room seats): their picture point and where they stand on the floor.
    let raised: [(pixel: CGPoint, world: CGPoint)]
    /// The obstacles' corners, a little out, and which of them see each other (with the distance).
    let nodes: [CGPoint]
    let links: [[(Int, CGFloat)]]

    /// How far a walker keeps off an obstacle, in metres.
    static let clearance: CGFloat = 0.22
    static let cornerMargin: CGFloat = 0.06

    /// the roads walks keep to; nil (older art, a check's own map) walks round the corners.
    var roads: ZoneRoads?

    init(boxes: [Box], origin: CGPoint, xAxis: CGVector, yAxis: CGVector, raised: [(pixel: CGPoint, world: CGPoint)], roads: ZoneRoads? = nil) {
        self.roads = roads
        self.boxes = boxes
        self.origin = origin
        self.xAxis = xAxis
        self.yAxis = yAxis
        self.raised = raised
        // A corner inside another obstacle is no way round.
        let corners = boxes.flatMap { $0.corners(grow: Self.clearance + Self.cornerMargin) }
        let nodes = corners.filter { c in !boxes.contains { $0.contains(c, grow: Self.clearance) } }
        self.nodes = nodes
        var links = Array(repeating: [(Int, CGFloat)](), count: nodes.count)
        for i in nodes.indices {
            for j in nodes.indices where j > i && !boxes.contains(where: { $0.blocks(nodes[i], nodes[j], grow: Self.clearance) }) {
                let d = hypot(nodes[i].x - nodes[j].x, nodes[i].y - nodes[j].y)
                links[i].append((j, d))
                links[j].append((i, d))
            }
        }
        self.links = links
    }

    /// The floor under a picture point (a seat's own floor spot when it is one of the raised ones).
    func world(_ pixel: CGPoint) -> CGPoint {
        if let known = raised.first(where: { hypot($0.pixel.x - pixel.x, $0.pixel.y - pixel.y) < 1 }) { return known.world }
        let px = pixel.x - origin.x, py = pixel.y - origin.y
        let det = xAxis.dx * yAxis.dy - yAxis.dx * xAxis.dy
        guard abs(det) > 1e-9 else { return .zero }
        return CGPoint(x: (px * yAxis.dy - yAxis.dx * py) / det, y: (xAxis.dx * py - px * xAxis.dy) / det)
    }

    func pixel(_ world: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + world.x * xAxis.dx + world.y * yAxis.dx, y: origin.y + world.x * xAxis.dy + world.y * yAxis.dy)
    }

    func clear(_ a: CGPoint, _ b: CGPoint) -> Bool { !boxes.contains { $0.blocks(a, b, grow: Self.clearance) } }

    /// Out of whatever obstacle a floor point is in, straight out its nearest side; the point itself when in none.
    func outside(_ p: CGPoint) -> CGPoint {
        guard let box = boxes.first(where: { $0.contains(p, grow: Self.clearance) }) else { return p }
        return box.exit(p, grow: Self.clearance, margin: 0.03)
    }

    /// the way along the roads, in floor metres, before its corners are cut: out of the start's obstacle, its spur, the
    /// roads, the end's spur and into its obstacle (both picture points' floor spots included); nil without roads, or when
    /// they do not reach (then `route` goes round the corners). Two spots a sidestep apart with nothing between
    /// are just the two.
    func roadRoute(from a: CGPoint, to b: CGPoint) -> [CGPoint]? {
        guard let roads else { return nil }
        let wa = world(a), wb = world(b), sa = outside(wa), sb = outside(wb)
        if hypot(sb.x - sa.x, sb.y - sa.y) < ZoneRoads.sidestep, clear(sa, sb) { return [wa, sa, sb, wb] }
        guard let way = roads.path(from: sa, to: sb, clear: clear) else { return nil }
        return [wa, sa] + way + [sb, wb]
    }

    /// The way from one picture point to another, in picture points, both ends included. along the roads, its corners
    /// cut a little; without them (or should they not reach), out of the start's obstacle, the shortest way round the rest
    /// by their corners, into the end's.
    func route(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        if let road = roadRoute(from: a, to: b) {
            // The spot and its exit out of its own obstacle stay as they are; the rest has its corners cut.
            let inner = ZoneRoads.soften(Array(road.dropFirst().dropLast()), clear: clear)
            var result = [a]
            for p in inner.map(pixel) where hypot(p.x - result.last!.x, p.y - result.last!.y) > 0.5 { result.append(p) }
            if hypot(b.x - result.last!.x, b.y - result.last!.y) > 0.5 { result.append(b) } else { result[result.count - 1] = b }
            return result
        }
        let wa = world(a), wb = world(b)
        let sa = outside(wa), sb = outside(wb)
        var way: [CGPoint] = [sa]
        if !clear(sa, sb) {
            // Dijkstra over the corners, the two ends added as nodes n and n+1.
            let n = nodes.count
            var dist = Array(repeating: CGFloat.infinity, count: n + 2), prev = Array(repeating: -1, count: n + 2), done = Array(repeating: false, count: n + 2)
            func neighbours(_ i: Int) -> [(Int, CGFloat)] {
                if i == n { return nodes.indices.filter { clear(sa, nodes[$0]) }.map { ($0, hypot(sa.x - nodes[$0].x, sa.y - nodes[$0].y)) } }
                if i == n + 1 { return [] }
                var list = links[i]
                if clear(nodes[i], sb) { list.append((n + 1, hypot(sb.x - nodes[i].x, sb.y - nodes[i].y))) }
                return list
            }
            dist[n] = 0
            while true {
                var best = -1
                for i in 0..<(n + 2) where !done[i] && dist[i] < .infinity && (best < 0 || dist[i] < dist[best]) { best = i }
                guard best >= 0, best != n + 1 else { break }
                done[best] = true
                for (j, d) in neighbours(best) where dist[best] + d < dist[j] {
                    dist[j] = dist[best] + d
                    prev[j] = best
                }
            }
            if dist[n + 1] < .infinity {
                var chain: [CGPoint] = []
                var i = prev[n + 1]
                while i >= 0 && i != n {
                    chain.append(nodes[i])
                    i = prev[i]
                }
                way += chain.reversed()
            }
        }
        way.append(sb)
        var result = [a]
        for p in way.map(pixel) where hypot(p.x - result.last!.x, p.y - result.last!.y) > 0.5 { result.append(p) }
        if hypot(b.x - result.last!.x, b.y - result.last!.y) > 0.5 { result.append(b) } else { result[result.count - 1] = b }
        return result
    }

    /// The map from points.json: nil without the camera's floor axes or any desk to place the origin by.
    static func make(_ root: [String: Any], xAxis: CGVector?, yAxis: CGVector?, zAxis: CGVector?) -> ZoneWalkMap? {
        guard let xAxis, let yAxis else { return nil }
        let z = zAxis ?? CGVector(dx: 0, dy: -83.1)
        func world(_ value: Any?) -> (x: CGFloat, y: CGFloat, h: CGFloat)? {
            guard let list = (value as? [String: Any])?["world"] as? [NSNumber], list.count >= 3 else { return nil }
            return (CGFloat(list[0].doubleValue), CGFloat(list[1].doubleValue), CGFloat(list[2].doubleValue))
        }
        var origin: CGPoint?
        var islands: [String: CGRect] = [:]
        for item in root["desks"] as? [Any] ?? [] {
            guard let d = item as? [String: Any] else { continue }
            if origin == nil, let centre = d["desk_center"] as? [String: Any], let p = ZoneScene.point(centre["pixel"]), let w = world(centre) {
                origin = CGPoint(x: p.x - w.x * xAxis.dx - w.y * yAxis.dx - w.h * z.dx, y: p.y - w.x * xAxis.dy - w.y * yAxis.dy - w.h * z.dy)
            }
            let zone = (d["kind"] as? String) == "boss" ? "boss" : d["zone"] as? String ?? "?"
            var r = islands[zone] ?? .null
            func take(_ x: CGFloat, _ y: CGFloat) { r = r.union(CGRect(x: x, y: y, width: 0, height: 0)) }
            for strip in d["desk_led_strips"] as? [[String: Any]] ?? [] {
                for corner in strip["quad_world"] as? [[NSNumber]] ?? [] where corner.count >= 2 { take(CGFloat(corner[0].doubleValue), CGFloat(corner[1].doubleValue)) }
            }
            if let c = world(d["desk_center"]) { take(c.x, c.y) }
            if let c = world(d["chair_seat"]) { take(c.x, c.y) }
            islands[zone] = r
        }
        guard let origin else { return nil }
        var boxes: [Box] = []
        for (zone, r) in islands.sorted(by: { $0.key < $1.key }) where !r.isNull {
            boxes.append(Box(center: CGPoint(x: r.midX, y: r.midY), u: CGVector(dx: 1, dy: 0), half: CGSize(width: r.width / 2, height: r.height / 2), name: zone))
        }
        var raised: [(pixel: CGPoint, world: CGPoint)] = []
        for item in root["sofas"] as? [Any] ?? [] {
            guard let sofa = item as? [String: Any] else { continue }
            var seats: [CGPoint] = []
            for seat in sofa["seats"] as? [Any] ?? [] {
                guard let p = ZoneScene.pixel(seat), let w = world(seat) else { continue }
                seats.append(CGPoint(x: w.x, y: w.y))
                raised.append((p, CGPoint(x: w.x, y: w.y)))
            }
            guard let first = seats.first, let last = seats.last, let facing = ZoneScene.point(sofa["facing_direction_world"]) else { continue }
            var along = CGVector(dx: last.x - first.x, dy: last.y - first.y)
            let length = hypot(along.dx, along.dy)
            along = length > 0 ? CGVector(dx: along.dx / length, dy: along.dy / length) : CGVector(dx: facing.y, dy: -facing.x)
            // Its seats a little in front of its middle: 0.35 m to its front, 0.55 m to its back, half a cushion past the ends.
            let mid = CGPoint(x: (first.x + last.x) / 2 - facing.x * 0.1, y: (first.y + last.y) / 2 - facing.y * 0.1)
            boxes.append(Box(center: mid, u: along, half: CGSize(width: length / 2 + 0.4, height: 0.45), name: "sofa_" + (sofa["zone"] as? String ?? "?")))
        }
        for seat in (root["rest_room"] as? [String: Any])?["seats"] as? [Any] ?? [] {
            guard let p = ZoneScene.pixel(seat), let w = world(seat) else { continue }
            raised.append((p, CGPoint(x: w.x, y: w.y)))
        }
        // the rest corner and the pantry are open, no walls. Not in points.json, so taken from the render: the
        // railing at the back (the floor ends at y = 8 m, the timber deck and its low glass railing run to y ≈ 9.1 m), and
        // the pantry's cabinet run (x 11.45…12.15, y −4.70…0.95) and its high table with stools (x 9.45…10.60, y −3.90…−0.30).
        boxes.append(Box(center: CGPoint(x: 0, y: 10.1), u: CGVector(dx: 1, dy: 0), half: CGSize(width: 17, height: 1.0), name: "railing"))
        boxes.append(Box(center: CGPoint(x: 11.80, y: -1.875), u: CGVector(dx: 1, dy: 0), half: CGSize(width: 0.35, height: 2.825), name: "pantry_cabinets"))
        boxes.append(Box(center: CGPoint(x: 10.025, y: -2.10), u: CGVector(dx: 1, dy: 0), half: CGSize(width: 0.575, height: 1.80), name: "pantry_table"))
        // from the render too, the rest corner's coffee table and the potted plants by the walkways (their pots and
        // leaves, about 0.6 m across), so the roads and the spurs to them go round.
        // the whole rest corner moved by `ZoneRoads.restShift` (the table, its roads); the plant by the beanbag down only.
        let rs = ZoneRoads.restShift
        boxes.append(Box(center: CGPoint(x: -12.15 + rs.dx, y: 5.55 + rs.dy), u: CGVector(dx: 1, dy: 0), half: CGSize(width: 0.8, height: 0.55), name: "rest_table"))
        for (name, at) in [("plant_back_left", CGPoint(x: -9.08, y: 7.59)), ("plant_back_right", CGPoint(x: 8.49, y: 7.86)),
                           ("plant_pantry", CGPoint(x: 8.83, y: -4.69)), ("plant_rest", CGPoint(x: -10.46, y: -0.12 + rs.dy)),
                           ("plant_boss", CGPoint(x: -5.08, y: -12.26))] {
            boxes.append(Box(center: at, u: CGVector(dx: 1, dy: 0), half: CGSize(width: 0.3, height: 0.3), name: name))
        }
        // the roads.
        var sofaSeats: [[CGPoint]] = [], sofaFacing: CGPoint?
        for item in root["sofas"] as? [Any] ?? [] {
            guard let sofa = item as? [String: Any] else { continue }
            sofaSeats.append((sofa["seats"] as? [Any] ?? []).compactMap { world($0).map { CGPoint(x: $0.x, y: $0.y) } })
            if sofaFacing == nil { sofaFacing = ZoneScene.point(sofa["facing_direction_world"]) }
        }
        let queue = (root["queue_line"] as? [Any] ?? []).compactMap { world($0).map { CGPoint(x: $0.x, y: $0.y) } }
        let checkIn = world((root["visitor_desk"] as? [String: Any])?["seat"]).map { CGPoint(x: $0.x, y: $0.y) }
        let entrance = world((root["entrance"] as? [String: Any])?["center"]).map { CGPoint(x: $0.x, y: $0.y) }
        let roads = ZoneRoads.make(boxes: boxes, islandNames: Set(ZoneScene.islandNames(root)), sofaSeats: sofaSeats, sofaFacing: sofaFacing,
                                   queue: queue.count >= 2 ? queue : [],
                                   checkIn: checkIn, entrance: entrance)
        return ZoneWalkMap(boxes: boxes, origin: origin, xAxis: xAxis, yAxis: yAxis, raised: raised, roads: roads)
    }
}

// ───────── roads ─────────

/// the Seaview's walks keep to roads, as people in an office do, instead of hugging the islands' corners and cutting
/// across between desks: the centre line of every aisle between the islands (along their long side, midway between
/// neighbours) and of the two outer aisles, the front walkway between the islands and the sofa row, the back walkway along
/// the railing, the sofa walkway (in front of the sofas, past their standing spots), the waiting line itself, the link
/// past the boss's desk to the line's head, the way down the right to check-in and the entrance, and the rest corner's two short
/// ways. All in world metres (x right, y back), worked out from points.json where it says enough (islands, sofas, the line,
/// check-in, the entrance), from the render where it does not (as `ZoneWalkMap.make` does for the railing and the pantry).
/// Roads are split where they cross or meet, so the network is one graph; a walk goes out of its spot by one short straight
/// spur to the nearest road it can reach without crossing anything (or one at most a metre further that leads its way), the shortest way along the roads (Dijkstra), and in
/// by a spur; its corners are cut a little (`chamfer`).
struct ZoneRoads {
    /// The rest corner's move in world metres (build_office.py `REST_SHIFT`; right 44 px, down 100 px in
    /// the picture), for its hard-coded table, plant and roads.
    static let restShift = CGVector(dx: 1.0913, dy: -1.1639)
    /// A road as laid out, for the picture: its name and its points.
    struct Road {
        let name: String
        let points: [CGPoint]
    }

    let roads: [Road]
    /// The network after the split: its nodes and edges (each with the road it is part of).
    let nodes: [CGPoint]
    let edges: [(a: Int, b: Int, road: String)]
    let links: [[(Int, CGFloat)]]

    /// The longest spur from a spot to a road, in metres.
    static let spurLimit: CGFloat = 3.2
    /// How much of each corner is cut off (at most), in metres, and at most this share of the shorter leg.
    static let chamfer: CGFloat = 0.3
    static let chamferShare: CGFloat = 0.4
    /// Two spots this close (and nothing between) are a sidestep: straight across, not out to a road and back.
    static let sidestep: CGFloat = 1.3

    init(roads: [Road]) {
        self.roads = roads
        let segments = roads.flatMap { r in zip(r.points, r.points.dropFirst()).map { (a: $0, b: $1, road: r.name) } }.filter {
            hypot($0.b.x - $0.a.x, $0.b.y - $0.a.y) > 1e-3
        }
        var nodes: [CGPoint] = []
        func node(_ p: CGPoint) -> Int {
            if let i = nodes.firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 0.03 }) { return i }
            nodes.append(p)
            return nodes.count - 1
        }
        var edges: [(a: Int, b: Int, road: String)] = []
        for (i, s) in segments.enumerated() {
            // Where the others cross it or end on it, as shares along it.
            var cuts: [CGFloat] = [0, 1]
            for (j, o) in segments.enumerated() where j != i {
                if let t = Self.crossing(s.a, s.b, o.a, o.b) { cuts.append(t) }
                for e in [o.a, o.b] { if let t = Self.on(e, s.a, s.b) { cuts.append(t) } }
            }
            let sorted = cuts.sorted()
            var kept: [CGFloat] = []
            let length = hypot(s.b.x - s.a.x, s.b.y - s.a.y)
            for t in sorted where kept.last.map({ (t - $0) * length > 0.03 }) ?? true { kept.append(t) }
            if let last = kept.last, last < 1 { kept[kept.count - 1] = 1 }
            let points = kept.map { CGPoint(x: s.a.x + (s.b.x - s.a.x) * $0, y: s.a.y + (s.b.y - s.a.y) * $0) }
            for (p, q) in zip(points, points.dropFirst()) {
                let a = node(p), b = node(q)
                if a != b, !edges.contains(where: { ($0.a == a && $0.b == b) || ($0.a == b && $0.b == a) }) { edges.append((a, b, s.road)) }
            }
        }
        var links = Array(repeating: [(Int, CGFloat)](), count: nodes.count)
        for e in edges {
            let d = hypot(nodes[e.a].x - nodes[e.b].x, nodes[e.a].y - nodes[e.b].y)
            links[e.a].append((e.b, d))
            links[e.b].append((e.a, d))
        }
        self.nodes = nodes
        self.edges = edges
        self.links = links
    }

    /// Where segment ab is crossed by cd, as a share along ab (strictly inside both).
    static func crossing(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> CGFloat? {
        let r = CGVector(dx: b.x - a.x, dy: b.y - a.y), s = CGVector(dx: d.x - c.x, dy: d.y - c.y)
        let den = r.dx * s.dy - r.dy * s.dx
        guard abs(den) > 1e-9 else { return nil }
        let t = ((c.x - a.x) * s.dy - (c.y - a.y) * s.dx) / den, u = ((c.x - a.x) * r.dy - (c.y - a.y) * r.dx) / den
        return t > 1e-6 && t < 1 - 1e-6 && u > -1e-6 && u < 1 + 1e-6 ? t : nil
    }

    /// Where a point lies on segment ab (within 3 cm), as a share along it.
    static func on(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat? {
        let (t, foot) = project(p, a, b)
        return hypot(foot.x - p.x, foot.y - p.y) < 0.03 && t > 0 && t < 1 ? t : nil
    }

    /// The nearest point of segment ab to p, and its share along it.
    static func project(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGFloat, CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y, l2 = dx * dx + dy * dy
        let t = l2 > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2)) : 0
        return (t, CGPoint(x: a.x + dx * t, y: a.y + dy * t))
    }

    /// A spot's spur: the nearest point on any road it can walk to straight without crossing anything (`clear`), no
    /// further than `spurLimit`; with the edge it is on.
    func spur(_ p: CGPoint, clear: (CGPoint, CGPoint) -> Bool) -> (edge: Int, foot: CGPoint)? {
        spurs(p, clear: clear).first.map { ($0.edge, $0.foot) }
    }

    /// The spurs a spot may take: the nearest clear one, and those to other roads no more than `spurSlack` longer (a few at
    /// most), nearest first, so the walk can set off towards where it is going (a sofa seat in the rest corner goes out to
    /// the way beside the sofa rather than round the coffee table).
    static let spurSlack: CGFloat = 1.0
    func spurs(_ p: CGPoint, clear: (CGPoint, CGPoint) -> Bool) -> [(edge: Int, foot: CGPoint, d: CGFloat)] {
        let feet = edges.indices.map { i -> (edge: Int, foot: CGPoint, d: CGFloat) in
            let foot = Self.project(p, nodes[edges[i].a], nodes[edges[i].b]).1
            return (i, foot, hypot(foot.x - p.x, foot.y - p.y))
        }.sorted { $0.d < $1.d }
        guard let first = feet.first(where: { $0.d <= Self.spurLimit && clear(p, $0.foot) }) else { return [] }
        var out = [first]
        for f in feet where f.edge != first.edge && f.d <= min(Self.spurLimit, first.d + Self.spurSlack) && out.count < 4 {
            // Not the same junction again (the foot at an edge's end is its neighbour's too).
            guard !out.contains(where: { hypot($0.foot.x - f.foot.x, $0.foot.y - f.foot.y) < 0.05 }), clear(p, f.foot) else { continue }
            out.append(f)
        }
        return out
    }

    /// The way from one floor spot to another along the roads, both spurs' feet included (not the spots); nil when either
    /// has no spur or the roads do not join them. The shortest over the spurs each may take (`spurs`), spur included.
    func path(from a: CGPoint, to b: CGPoint, clear: (CGPoint, CGPoint) -> Bool) -> [CGPoint]? {
        let starts = spurs(a, clear: clear), ends = spurs(b, clear: clear)
        guard !starts.isEmpty, !ends.isEmpty else { return nil }
        let n = nodes.count, A = n, B = n + 1, firstStart = n + 2, firstEnd = n + 2 + starts.count, count = firstEnd + ends.count
        func d(_ p: CGPoint, _ q: CGPoint) -> CGFloat { hypot(p.x - q.x, p.y - q.y) }
        func point(_ i: Int) -> CGPoint { i < n ? nodes[i] : i >= firstEnd ? ends[i - firstEnd].foot : starts[i - firstStart].foot }
        func neighbours(_ i: Int) -> [(Int, CGFloat)] {
            if i == A { return starts.indices.map { (firstStart + $0, starts[$0].d) } }
            if i == B { return [] }
            if i >= firstEnd { return [(B, ends[i - firstEnd].d)] }
            var list: [(Int, CGFloat)] = []
            if i >= firstStart {
                let s = starts[i - firstStart], e = edges[s.edge]
                list = [(e.a, d(s.foot, nodes[e.a])), (e.b, d(s.foot, nodes[e.b]))]
                for (k, t) in ends.enumerated() where t.edge == s.edge { list.append((firstEnd + k, d(s.foot, t.foot))) }
                return list
            }
            list = links[i]
            for (k, t) in ends.enumerated() where edges[t.edge].a == i || edges[t.edge].b == i { list.append((firstEnd + k, d(nodes[i], t.foot))) }
            return list
        }
        var dist = Array(repeating: CGFloat.infinity, count: count), prev = Array(repeating: -1, count: count), done = Array(repeating: false, count: count)
        dist[A] = 0
        while true {
            var best = -1
            for i in 0..<count where !done[i] && dist[i] < .infinity && (best < 0 || dist[i] < dist[best]) { best = i }
            guard best >= 0, best != B else { break }
            done[best] = true
            for (j, w) in neighbours(best) where dist[best] + w < dist[j] {
                dist[j] = dist[best] + w
                prev[j] = best
            }
        }
        guard dist[B] < .infinity else { return nil }
        var chain: [CGPoint] = []
        var i = prev[B]
        while i >= 0 && i != A {
            chain.append(point(i))
            i = prev[i]
        }
        var way: [CGPoint] = []
        for p in chain.reversed() where way.last.map({ d($0, p) > 0.02 }) ?? true { way.append(p) }
        return way
    }

    /// The corners of a way cut a little: each inner corner that turns more than about 15° becomes two points, `chamfer`
    /// (at most `chamferShare` of the shorter leg) back along each leg, where the cut is clear; the ends are kept.
    static func soften(_ way: [CGPoint], clear: (CGPoint, CGPoint) -> Bool) -> [CGPoint] {
        guard way.count > 2 else { return way }
        var out = [way[0]]
        for i in 1..<(way.count - 1) {
            let p = way[i], q = out.last!, r = way[i + 1]
            let l1 = hypot(q.x - p.x, q.y - p.y), l2 = hypot(r.x - p.x, r.y - p.y)
            guard l1 > 1e-3, l2 > 1e-3 else { out.append(p); continue }
            let cos = ((q.x - p.x) * (r.x - p.x) + (q.y - p.y) * (r.y - p.y)) / (l1 * l2)
            let c = min(Self.chamfer, Self.chamferShare * min(l1, l2))
            guard cos > -0.966, c > 0.02 else { out.append(p); continue }  // nearly straight on
            let p1 = CGPoint(x: p.x + (q.x - p.x) / l1 * c, y: p.y + (q.y - p.y) / l1 * c)
            let p2 = CGPoint(x: p.x + (r.x - p.x) / l2 * c, y: p.y + (r.y - p.y) / l2 * c)
            if clear(p1, p2) { out += [p1, p2] } else { out.append(p) }
        }
        out.append(way[way.count - 1])
        return out
    }

    /// The roads of the art: from its islands, sofas, line, check-in spot and entrance (world metres), the railing and the
    /// pantry (`ZoneWalkMap.make`'s boxes) and, from the render, the rest corner and the potted plants. Nil when there are
    /// not at least two islands.
    static func make(boxes: [ZoneWalkMap.Box], islandNames: Set<String>, sofaSeats: [[CGPoint]], sofaFacing: CGPoint?, queue: [CGPoint],
                     checkIn: CGPoint?, entrance: CGPoint?) -> ZoneRoads? {
        let islands = boxes.filter { islandNames.contains($0.name) }.sorted { $0.center.x < $1.center.x }
        guard islands.count >= 2 else { return nil }
        func minX(_ b: ZoneWalkMap.Box) -> CGFloat { b.center.x - b.half.width }
        func maxX(_ b: ZoneWalkMap.Box) -> CGFloat { b.center.x + b.half.width }
        let low = islands.map { $0.center.y - $0.half.height }.min()!, high = islands.map { $0.center.y + $0.half.height }.max()!
        // The rugs reach about 0.45 m past the desks' box (render); the railing's glass is at the railing box's near edge.
        let rug: CGFloat = 0.45
        let railing = boxes.first { $0.name == "railing" }.map { $0.center.y - $0.half.height } ?? high + 2
        let front = low - 1.0
        let back = (high + rug + railing) / 2
        var roads: [Road] = []
        // The aisles between the islands, midway, from the front walkway to the back one.
        for (l, r) in zip(islands, islands.dropFirst()) {
            let x = (maxX(l) + minX(r)) / 2
            roads.append(Road(name: "aisle", points: [CGPoint(x: x, y: front), CGPoint(x: x, y: back)]))
        }
        // The outer aisles: on the left between the rug and the rest corner, round the plant by the railing; on the right
        // between the rug and the pantry's stools, ending short of the plant in the back corner.
        let left = minX(islands[0]) - 1.68
        let pantry = boxes.first { $0.name == "pantry_table" }.map { $0.center.x - $0.half.width }
        let right = pantry.map { (maxX(islands[islands.count - 1]) + rug + $0 - 0.55) / 2 } ?? maxX(islands[islands.count - 1]) + 1.1
        roads.append(Road(name: "aisle-left", points: [CGPoint(x: left, y: front), CGPoint(x: left, y: high - 0.6), CGPoint(x: left - 0.4, y: high - 0.1),
                                                     CGPoint(x: left - 0.4, y: back)]))
        roads.append(Road(name: "aisle-right", points: [CGPoint(x: right, y: front), CGPoint(x: right, y: high - 0.3)]))
        // The front walkway and the back one.
        roads.append(Road(name: "front", points: [CGPoint(x: left, y: front), CGPoint(x: right, y: front)]))
        roads.append(Road(name: "back", points: [CGPoint(x: left - 0.4, y: back), CGPoint(x: maxX(islands[islands.count - 1]) - 0.2, y: back)]))
        // The sofa walkway: parallel to the sofa row, 2.4 m out in front of the seats (past the standing spots, short of the
        // line), from the first sofa's end to a little past the last's.
        let seats = sofaSeats.flatMap { $0 }
        var sofaEnds: (CGPoint, CGPoint)?
        if let facing = sofaFacing, let row = sofaSeats.first(where: { $0.count >= 2 }), let first = row.first, let last = row.last {
            var u = CGVector(dx: last.x - first.x, dy: last.y - first.y)
            let l = max(1e-6, hypot(u.dx, u.dy))
            u = CGVector(dx: u.dx / l, dy: u.dy / l)
            if u.dx < 0 { u = CGVector(dx: -u.dx, dy: -u.dy) }
            let along = seats.map { $0.x * u.dx + $0.y * u.dy }, out = seats.map { $0.x * facing.x + $0.y * facing.y }
            let offset = out.reduce(0, +) / CGFloat(out.count) + 2.4
            func at(_ s: CGFloat) -> CGPoint { CGPoint(x: u.dx * s + facing.x * offset, y: u.dy * s + facing.y * offset) }
            let a = at(along.min()!), b = at(along.max()! + 0.6)
            sofaEnds = (a, b)
            roads.append(Road(name: "sofa", points: [a, b]))
        }
        // The line, and the way past the boss's desk from its head to the sofa walkway.
        if queue.count >= 2 {
            roads.append(Road(name: "queue", points: queue))
            if let (a, _) = sofaEnds { roads.append(Road(name: "boss", points: [queue[0], a])) }
        }
        // The aisles carry on down to the line and the sofa walkway: the first one to just past the line's head (clear of
        // the boss's desk), the middle ones straight down, crossing the line, to the sofa walkway.
        if let (a, b) = sofaEnds {
            let u = CGVector(dx: b.x - a.x, dy: b.y - a.y)
            for (l, r) in zip(islands, islands.dropFirst()) {
                let x = (maxX(l) + minX(r)) / 2
                guard abs(u.dx) > 1e-6 else { continue }
                let t = (x - a.x) / u.dx
                if t >= 0 && t <= 1 {
                    roads.append(Road(name: "aisle-down", points: [CGPoint(x: x, y: front), CGPoint(x: x, y: a.y + u.dy * t)]))
                } else if t < 0, queue.count >= 2 {
                    let q = CGVector(dx: queue[1].x - queue[0].x, dy: queue[1].y - queue[0].y), ql = max(1e-6, hypot(q.dx, q.dy))
                    roads.append(Road(name: "aisle-down", points: [CGPoint(x: x, y: front), CGPoint(x: queue[0].x + q.dx / ql * 0.6, y: queue[0].y + q.dy / ql * 0.6)]))
                }
            }
        }
        // Down the right to check-in and the entrance, left of the plant by the pantry; the sofa walkway's end joins it.
        if let checkIn {
            let x = checkIn.x + 0.2, bottom = min(checkIn.y, entrance?.y ?? checkIn.y) - 0.2
            roads.append(Road(name: "check-in", points: [CGPoint(x: right, y: front), CGPoint(x: x, y: front - 1.2), CGPoint(x: x, y: bottom)]))
            if let (_, b) = sofaEnds { roads.append(Road(name: "check-in", points: [b, CGPoint(x: x, y: b.y)])) }
        }
        // The rest corner (render): a way in front of the armchairs, short of the coffee table, and one up its right side
        // to the sofa's end.
        // moved with the corner (`restShift`).
        let rs = Self.restShift
        roads.append(Road(name: "rest", points: [CGPoint(x: left, y: 4.45 + rs.dy), CGPoint(x: -13.75 + rs.dx, y: 4.45 + rs.dy)]))
        roads.append(Road(name: "rest", points: [CGPoint(x: -10.75 + rs.dx, y: 4.45 + rs.dy), CGPoint(x: -10.75 + rs.dx, y: 6.55 + rs.dy),
                                                 CGPoint(x: left, y: 6.55 + rs.dy)]))
        return ZoneRoads(roads: roads)
    }
}

// ───────── Visits ─────────

/// The office's visit in the zone: when a round of talk between two sessions opens (the store's `rounds`, as the office
/// reads them), its opener walks to the other's place, says a word there, and walks back. The office's rules: nothing is
/// sent at the first look; a round sends one visit at most; the opener goes only from its desk or the rest room and not
/// while it waits for you; nobody visits one in the line; one visitor at a host at a time, never two visiting each other;
/// the round must have opened within `fresh`. It lasts the walk there and `stay` more, or until either moves.
struct ZoneVisits: Equatable {
    struct Visit: Equatable {
        let host: String
        /// The round it is for ("" for one set by hand, for a picture or a check: it needs no round).
        let round: String
        /// What it says there: the latest message's gist, else a plain word.
        let words: String
        /// Where the host was when it set off: the host moving ends it.
        let hostAt: CGPoint
        let until: Date
    }
    var visits: [String: Visit] = [:]
    var done: Set<String> = []
    var looked = false

    static let stay: TimeInterval = OfficeVisits.stay
    static let fresh: TimeInterval = OfficeVisits.fresh
    static var plainWords: String { L10n.string("say.plain", table: "Zone", zh: "找你说句话") }

    /// `homes`: where each one is by its own state; `free`: those who may go (at a desk or resting, not waiting); `open`:
    /// those who may be visited (not in the line). `pace` in picture pixels a second, for the walk there; `length` the way
    /// there from a home to the host's (picture pixels), the straight line without it.
    static func next(homes: [String: CGPoint], free: Set<String>, open: Set<String>, peers: [String: [Peer]], rounds: [String: Store.Round],
                     previous: ZoneVisits, now: Date, pace: CGFloat, length: ((CGPoint, CGPoint) -> CGFloat)? = nil) -> ZoneVisits {
        let going = rounds.compactMap { pair, round -> (key: String, opener: String, partner: String, since: Date)? in
            let ids = pair.split(separator: "|").map(String.init)
            guard ids.count == 2, ids.contains(round.opener), let partner = ids.first(where: { $0 != round.opener }),
                peers[round.opener]?.contains(where: { $0.id == partner && $0.isRecent(now) }) == true
            else { return nil }
            return ("\(pair) \(round.since.timeIntervalSince1970)", round.opener, partner, round.since)
        }.sorted { ($0.since, $0.key) < ($1.since, $1.key) }
        var plan = ZoneVisits(done: previous.done.intersection(going.map(\.key)), looked: true)
        guard previous.looked else {
            plan.done.formUnion(going.map(\.key))
            return plan
        }
        // Visits going on carry on while nothing has moved them and their time is not up.
        for (visitor, visit) in previous.visits.sorted(by: { $0.key < $1.key }) {
            guard now < visit.until, visit.round.isEmpty || going.contains(where: { $0.key == visit.round }), free.contains(visitor),
                open.contains(visit.host), homes[visit.host] == visit.hostAt, homes[visitor] != nil
            else { continue }
            plan.visits[visitor] = visit
        }
        for round in going where !plan.done.contains(round.key) {
            plan.done.insert(round.key)
            let busy = Set(plan.visits.keys).union(plan.visits.values.map(\.host))
            guard now.timeIntervalSince(round.since) < fresh, free.contains(round.opener), open.contains(round.partner),
                let from = homes[round.opener], let to = homes[round.partner], !busy.contains(round.opener), !busy.contains(round.partner)
            else { continue }
            let note = peers[round.opener]?.first { $0.id == round.partner }?.note ?? ""
            // the walk there by the way it really goes (by the roads, `length`), so its stay by the host does not depend on the route.
            let walk = TimeInterval((length?(from, to) ?? hypot(to.x - from.x, to.y - from.y)) / max(pace, 1))
            plan.visits[round.opener] = Visit(host: round.partner, round: round.key, words: note.isEmpty ? plainWords : note, hostAt: to,
                                              until: now + walk + stay)
        }
        return plan
    }
}

// ───────── off duty (off-duty mode) ─────────

/// One session off duty, as the roster file has it (the setting `rosterFile`, written whole by whatever tool sends sessions
/// off duty; per session its name, folder and the like): gone from the registry, kept here until it is woken.
struct ZoneRosterEntry: Equatable {
    let name: String
    var cwd = ""
    var sid = ""
    /// The roster's own zone (the name's prefix, or the unsorted bucket).
    var zone = ""
    var lastActive: Date?
    var offAt: Date?
}

enum ZoneRoster {
    /// The roster's entries by name; nil for a file that is not a JSON object (half written, broken), so the caller keeps
    /// what it had. `{}` is an empty roster.
    static func parse(_ data: Data) -> [String: ZoneRosterEntry]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        var out: [String: ZoneRosterEntry] = [:]
        for (name, value) in root {
            guard !name.isEmpty, let e = value as? [String: Any] else { continue }
            func date(_ key: String) -> Date? { (e[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
            out[name] = ZoneRosterEntry(name: name, cwd: e["cwd"] as? String ?? "", sid: e["sid"] as? String ?? "", zone: e["zone"] as? String ?? "",
                                        lastActive: date("lastActive"), offAt: date("offAt"))
        }
        return out
    }

    /// Which sign lists it: its zone's when the room has that sign, else the check-in label's (`ZonePlan.visitorKey`).
    static func sign(of entry: ZoneRosterEntry, signs: Set<String>) -> String {
        signs.contains(entry.zone) ? entry.zone : ZonePlan.visitorKey
    }

    /// The off-duty by sign (zone code, or `ZonePlan.visitorKey`), the latest to go first.
    static func bySign(_ entries: [ZoneRosterEntry], signs: Set<String>) -> [String: [ZoneRosterEntry]] {
        var out: [String: [ZoneRosterEntry]] = [:]
        for e in entries { out[sign(of: e, signs: signs), default: []].append(e) }
        return out.mapValues { list in
            list.sorted { a, b in
                let x = a.offAt ?? .distantPast, y = b.offAt ?? .distantPast
                return x != y ? x > y : a.name < b.name
            }
        }
    }

    /// "last active X hours ago" (minutes under an hour, days from two days on).
    static func lastActive(_ at: Date?, now: Date) -> String {
        guard let at else { return L10n.string("off.lastActive.unknown", table: "Zone", zh: "最后活动 未知") }
        let seconds = max(0, now.timeIntervalSince(at))
        if seconds < 3600 { return L10n.format("off.lastActive.minutes", table: "Zone", zh: "最后活动 %lld 分钟前", max(1, Int(seconds / 60))) }
        if seconds < 48 * 3600 { return L10n.format("off.lastActive.hours", table: "Zone", zh: "最后活动 %lld 小时前", Int(seconds / 3600)) }
        return L10n.format("off.lastActive.days", table: "Zone", zh: "最后活动 %lld 天前", Int(seconds / 86400))
    }

    /// "off duty since HH:mm" (local time), with the date when not today.
    static func offAt(_ at: Date?, now: Date) -> String {
        guard let at else { return L10n.string("off.at.unknown", table: "Zone", zh: "下班于 未知") }
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(at, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        return L10n.format("off.at", table: "Zone", zh: "下班于 %@", f.string(from: at))
    }
}

/// The roster file as it is now, read again whenever its date or size changes; a missing, half-written or broken file
/// keeps the last good reading.
@MainActor enum ZoneRosterFile {
    /// Written by the machine's own off-duty tool (none comes with the panel): `SOULGENT_ROSTER_FILE` or the setting
    /// `rosterFile`; "" (nobody off duty) when neither says.
    static var path = localPath("rosterFile", env: "SOULGENT_ROSTER_FILE")
    private static var stamp = ""
    private(set) static var entries: [String: ZoneRosterEntry] = [:]

    /// Reads the file again if it changed; true when what it says changed.
    @discardableResult static func refresh() -> Bool {
        let now = zoneStamp(path)
        if now == stamp { return false }
        stamp = now
        guard let data = FileManager.default.contents(atPath: path), let parsed = ZoneRoster.parse(data) else { return false }
        guard parsed != entries else { return false }
        entries = parsed
        return true
    }

    static func current() -> [String: ZoneRosterEntry] {
        refresh()
        return entries
    }

    /// For checks: forget what was read.
    static func reset() {
        stamp = ""
        entries = [:]
    }
}

/// waking an off-duty session and sending one off, by `offduty.py --wake/--off <name>` (each takes several seconds),
/// run off the main thread. One run per name at a time. What each name is going through, for the sign lists, the badges
/// and the figures.
@MainActor final class ZoneOffDuty {
    static let shared = ZoneOffDuty()
    /// The machine's own off-duty tool (none comes with the panel): `SOULGENT_OFFDUTY_SCRIPT` or the setting
    /// `offDutyScript`. Without one, or with its file gone, there is no send-off-duty and nothing to wake.
    static let script = localPath("offDutyScript", env: "SOULGENT_OFFDUTY_SCRIPT")
    /// The command the name and its flag are added to; a check gives a stub of its own. Empty: no tool.
    var launcher: [String] = ZoneOffDuty.script.isEmpty || !FileManager.default.fileExists(atPath: ZoneOffDuty.script)
        ? [] : ["/usr/bin/env", "python3", ZoneOffDuty.script]
    /// Whether there is a tool to send sessions off duty and wake them.
    var available: Bool { !launcher.isEmpty }
    /// Where a failure is written (panel.log); a check catches it.
    var logSink: (String) -> Void = { log($0) }
    /// How long "wake failed" and "not sent" show.
    static let failShows: TimeInterval = 10
    /// How long after a wake that went well its row may say "waking…" with the session still not in the registry; then it
    /// is taken as failed (the script said yes, but nothing came).
    static let wakeTimeout: TimeInterval = 90

    struct Waking {
        let entry: ZoneRosterEntry
        let since: Date
        var exited: Date?
    }
    enum RowState: Equatable { case off, waking, failed }

    /// Being woken: the roster entry as it was (the script takes it off the roster before the session is back).
    private(set) var waking: [String: Waking] = [:]
    private(set) var wakeFailed: [String: Date] = [:]
    private(set) var sending = Set<String>()
    private(set) var offRefused: [String: Date] = [:]

    /// Starts waking `name` unless it is being woken already; true when started.
    @discardableResult func wake(_ entry: ZoneRosterEntry, store: Store?) -> Bool {
        let name = entry.name
        guard available, waking[name] == nil else { return false }
        wakeFailed[name] = nil
        waking[name] = Waking(entry: entry, since: Date())
        run(["--wake", name]) { [weak self, weak store] code, err in
            guard let self else { return }
            if code == 0 {
                self.waking[name]?.exited = Date()
                self.later(Self.wakeTimeout + 0.5, store)
            } else {
                self.waking[name] = nil
                self.wakeFailed[name] = Date() + Self.failShows
                self.logSink("sea room off duty: wake \(name) failed (exit code \(code)): \(Self.tail(err))")
                self.later(Self.failShows + 0.2, store)
            }
            store?.objectWillChange.send()
        }
        return true
    }

    /// Sends `name` off duty unless that is under way; true when started. A refusal (busy, sub-agents, …) shows as "not sent".
    @discardableResult func sendOff(_ name: String, store: Store?) -> Bool {
        guard available, !name.isEmpty, sending.insert(name).inserted else { return false }
        offRefused[name] = nil
        run(["--off", name]) { [weak self, weak store] code, err in
            guard let self else { return }
            self.sending.remove(name)
            if code != 0 {
                self.offRefused[name] = Date() + Self.failShows
                self.logSink("sea room off duty: sending \(name) off duty failed (exit code \(code)): \(Self.tail(err))")
                self.later(Self.failShows + 0.2, store)
            }
            store?.objectWillChange.send()
        }
        return true
    }

    /// Those woken who are back in the registry are done; a wake gone quiet for too long counts as failed.
    func settle(awake: Set<String>, now: Date = Date()) {
        for (name, w) in waking {
            if awake.contains(name) {
                waking[name] = nil
            } else if let exited = w.exited, now.timeIntervalSince(exited) > Self.wakeTimeout {
                waking[name] = nil
                wakeFailed[name] = now + Self.failShows
                logSink("sea room off duty: \(name) still not in the registry \(Int(Self.wakeTimeout)) seconds after waking, counted as failed")
            }
        }
        wakeFailed = wakeFailed.filter { $0.value > now }
        offRefused = offRefused.filter { $0.value > now }
    }

    func state(of name: String, now: Date = Date()) -> RowState {
        if waking[name] != nil { return .waking }
        if let until = wakeFailed[name], until > now { return .failed }
        return .off
    }

    func refused(_ name: String, now: Date = Date()) -> Bool { offRefused[name].map { $0 > now } ?? false }

    /// The off-duty to show: the roster's, less any already back, plus those being woken (gone from the roster already).
    func shown(roster: [String: ZoneRosterEntry], awake: Set<String>) -> [ZoneRosterEntry] {
        var out = roster.filter { !awake.contains($0.key) }
        for (name, w) in waking where out[name] == nil && !awake.contains(name) { out[name] = w.entry }
        return Array(out.values)
    }

    /// For checks: forget every run.
    func reset() {
        waking = [:]
        wakeFailed = [:]
        sending = []
        offRefused = [:]
    }

    static func tail(_ text: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let last = lines.suffix(3).joined(separator: " | ")
        return last.isEmpty ? "(stderr empty)" : String(last.suffix(400))
    }

    private func later(_ seconds: TimeInterval, _ store: Store?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak store] in store?.objectWillChange.send() }
    }

    /// One run of the script off the main thread; `done` on the main thread with its exit code and stderr. The stderr goes
    /// to a file, not a pipe: a process the script leaves running (a terminal it opens) must not hold the read open.
    private func run(_ args: [String], done: @escaping (Int32, String) -> Void) {
        let command = launcher + args
        DispatchQueue.global(qos: .userInitiated).async {
            let errPath = NSTemporaryDirectory() + "session-panel-offduty-\(UUID().uuidString).err"
            FileManager.default.createFile(atPath: errPath, contents: nil)
            defer { try? FileManager.default.removeItem(atPath: errPath) }
            var code: Int32 = -1
            var text = ""
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" + ((env["PATH"]).map { ":" + $0 } ?? "")
            process.environment = env
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            if let handle = FileHandle(forWritingAtPath: errPath) {
                process.standardError = handle
                do {
                    try process.run()
                    process.waitUntilExit()
                    code = process.terminationStatus
                } catch {
                    text = "Failed to launch: \(error.localizedDescription)"
                }
                try? handle.close()
            } else {
                text = "Cannot write temp file \(errPath)"
            }
            if text.isEmpty { text = (FileManager.default.contents(atPath: errPath)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
            let finalCode = code, finalText = text
            DispatchQueue.main.async { done(finalCode, finalText) }
        }
    }
}
