// The office: the same open sessions as the board, shown as a room. Whoever needs you stands
// at your desk; the ones with news sit beside it; the rest are at their desks or asleep at
// the back. At most thirty are in the room, the others wait behind the door.

import AppKit
import SwiftUI

/// Where everyone stands. Worked out from the board's groups alone, so it can be checked
/// without drawing anything.
struct OfficeLayout {
    enum Zone { case queue, sofa, desk, lounge }
    /// The board's groups, which say how a pet is drawn wherever it sits.
    enum Kind { case waiting, news, work, seen, resting }

    struct Pet: Equatable {
        let id: String
        /// Its place in an extension's scene (`SceneExtension`), when the layout is one; nil in the office.
        var sceneSlot: String? = nil
        let zone: Zone
        let seat: Int
        let x: CGFloat  // the middle of its feet
        let foot: CGFloat
        let tall: CGFloat
        let kind: Kind
        /// Where its words are: the name and project under it, or for one waiting, its card.
        let words: CGRect
        /// Who it stands beside while it visits, and that one's part of the room. Its own seat is kept meanwhile.
        var host: String? = nil
        var hostZone: Zone? = nil
        /// It has talked with another session within ten minutes: a chat mark by its head.
        var chats = false
        /// Where the mark goes: over its head where the row above leaves room for it; else beside its head; on a sofa,
        /// where the next sitter is too close for that, or with a visitor beside it, on its head's top corner. On the
        /// right, or on the left where a visitor stands at its right or its host does.
        enum MarkPlace { case over, beside, tucked }
        var markPlace = MarkPlace.over
        var markLeft = false
        /// Its pet's own size (pet.json `"scale"`, `OfficePets.size`), set by `visited`; the chat mark and the hover
        /// lines go by its head at that size. 1 for nearly every pet.
        var size: CGFloat = 1

        /// Resting: drawn faint, at the back.
        var asleep: Bool { kind == .resting }
        /// Waiting, but the queue is full: it waits where it sits, under a coral plate, until its turn.
        var flagged: Bool { kind == .waiting && zone != .queue }

        /// The pet itself: what the ring goes round.
        var body: CGRect { CGRect(x: x - tall * 0.45, y: foot - tall * 1.12, width: tall * 0.9, height: tall * 1.12 + 6) }
        /// The pet and its words in one box, for the pointer's list of frames.
        var frame: CGRect { body.union(words) }

        /// What counts as pointing at it: the pet or its words, since people point at what they
        /// read. Not the whole box: beside a waiting pet, under its card, is someone else's floor.
        func covers(_ point: CGPoint) -> Bool { body.contains(point) || words.contains(point) }
    }

    static let width: CGFloat = 1194
    /// The room at its shortest. A taller window gets a taller room, up to 1000: the rows below
    /// the wall spread out, and your corner moves down whole.
    static let baseHeight: CGFloat = 764, tallest: CGFloat = 1000
    /// More than this in one room is hard to read at a glance.
    static let holds = 30
    /// The room's grid: the desks' two blocks of four columns, 46...574 and 620...1148, either side of the centre aisle
    /// (597). The couches at the back and the sofas run from block edge to block edge, and the floor labels share one left
    /// margin, so the room lines up; only the back wall and your corner keep places of their own.
    static let blockLefts: [CGFloat] = [46, 620], blockWidth: CGFloat = 528
    /// The four sofas of "Has news", two in each block with the aisle's gap between the pairs and between the two of a pair:
    /// each 241 wide outline to outline. Where each one's frame starts, its seat pitch and its arms.
    static let sofaLefts: [CGFloat] = [47, 334, 621, 908], sofaPitch: CGFloat = 75, sofaArm: CGFloat = 7
    /// Their twelve seats, filled left to right.
    static let sofaSeats: [CGFloat] = sofaLefts.flatMap { left in (0..<3).map { (left + sofaArm + sofaPitch * (CGFloat($0) + 0.5)).rounded() } }
    /// The couches at the back: one a block in each row, five seats each, outline to outline on the block's edges.
    static let couchPitch: CGFloat = 102, couchArm: CGFloat = 8
    /// Your desk in the bottom-left corner. The queue runs from its right edge to the room's: seven who wait, and an eighth
    /// place for the card saying how many more do. Fixed places, so nobody moves when the queue grows.
    static let yourDesk = CGRect(x: 14, y: 0, width: 164, height: 0)
    static let queueLeft: CGFloat = 186, queueSlot: CGFloat = 125, cardWidth: CGFloat = 116, queueHolds = 7
    static func queueX(_ slot: Int) -> CGFloat { queueLeft + cardWidth / 2 + queueSlot * CGFloat(slot) }
    /// Where a desk starts: four either side of the aisle.
    static func deskLeft(_ column: Int) -> CGFloat { blockLefts[column < 4 ? 0 : 1] + CGFloat(column % 4) * 132 }
    /// Where the n-th seat at the back is: five a couch, a couch a block.
    static func loungeX(_ column: Int) -> CGFloat { blockLefts[column < 5 ? 0 : 1] + 1 + couchArm + couchPitch * (CGFloat(column % 5) + 0.5) }

    /// The lounge door at the back, as the painter draws it.
    static let door = CGRect(x: 1000, y: 4, width: 84, height: 66)
    /// The door's entry among the pointer's targets; session ids are UUIDs, so it meets none.
    static let doorKey = "office-door"
    /// The notice board on the back wall, between the right-hand window and the door: what happened lately.
    static let board = CGRect(x: 800, y: 12, width: 80, height: 44)
    /// The dot at its top-right corner while there is something the user has not seen, with its outline.
    static let boardMark = CGRect(x: 875, y: 7, width: 10, height: 10)
    /// What pointing at the board means: the board and its dot, which is what one aims at.
    static let boardArea = board.union(boardMark)
    static let boardKey = "office-board"
    /// What `--snapshot --office --hover` calls it; and the chip of those waiting beyond the queue.
    /// What `--hover` takes for the notice board and the waiting chip. Command-line words (scripts and checks pass them),
    /// fixed whatever language the panel shows; never shown, never translated.
    enum HoverToken: String {
        case board = "动态板", waitingChip = "在等你"
    }

    /// Who needs you or works but is not where their kind belongs: those waiting beyond the queue's
    /// seven, and anyone of these kinds the room has no place for. Never the door: a chip says it.
    enum ChipKind: CaseIterable {
        case waiting, news, work
        /// Its entry among the pointer's targets.
        var key: String {
            switch self {
            case .waiting: return "office-chip-waiting"
            case .news: return "office-chip-news"
            case .work: return "office-chip-work"
            }
        }
        func text(_ count: Int) -> String {
            switch self {
            case .waiting: return L10n.format("chip.waiting", table: "Office", zh: "还有 %lld 个在等你", count)
            case .news: return L10n.format("chip.news", table: "Office", zh: "还有 %lld 个有话说", count)
            case .work: return L10n.format("chip.work", table: "Office", zh: "还有 %lld 个在干活", count)
            }
        }
    }
    struct Chip: Equatable {
        let kind: ChipKind
        let count: Int
        let rect: CGRect
    }

    /// How many are in each part of the room (by seat), for the floor's labels.
    struct Counts: Equatable {
        let waiting: Int, news: Int, desks: Int, resting: Int
    }

    let height: CGFloat
    /// The scale its words are measured for.
    let scale: CGFloat
    var size: CGSize { CGSize(width: Self.width, height: height) }
    let loungeFloors: [CGFloat]
    let deskFloors: [CGFloat]
    /// Your corner: the rug's top edge, the sofas' floor, where the waiting stand, and the top of their cards.
    let rugTop: CGFloat, sofaFloor: CGFloat, queueFoot: CGFloat, cardTop: CGFloat
    /// Lines of what each waiting session asks, on its card.
    let asks: Int
    /// Set here, or by an extension's scene when it lays the room out again (`SceneExtension.project`).
    var pets: [Pet]
    /// The layout is an extension's scene, not the office (`SceneExtension.project`).
    var sceneMode = false
    /// ...and that scene moves its figures itself (`SceneExtension.drivesFigures`): the view leaves their walks to it.
    var sceneDriven: Bool { sceneMode && Extensions.registered?.drivesFigures == true }
    /// Looked-at and resting sessions that did not get into the room: the number on the lounge door.
    var behindDoor: Int
    /// Who they are, the looked-at first.
    var behindDoorIDs: [String]
    /// Those waiting beyond the queue, in the room or not, the longest waiting first.
    var waitingElsewhere: [String]
    /// Who is counted on each chip but not in the room.
    var outside: [ChipKind: [String]]
    var chips: [Chip]
    let counts: Counts
    /// Desks kept for sessions away in the queue or on a sofa, by session, and since which layout.
    let reserved: [String: Int]
    let reservedSince: [String: Int]
    /// Those answered in the queue who stay there a while, at work, and since when.
    let lingering: [String: Date]
    /// How long one answered in the queue stays there: it may well ask again soon, and walking off and back each
    /// time is what made the room hard to watch.
    static let linger: TimeInterval = 45
    /// One more than the layout this one was made from: how long a desk has been kept is counted in these.
    let generation: Int

    /// Where a waiting card's lines go, at the word size for this scale: the name alone, so it
    /// survives; the project and the wait; then what it asks. The card is as tall as these, with
    /// `cardPad` round them.
    static func cardLines(_ card: CGRect, scale: CGFloat, asks: Int) -> (name: CGRect, second: CGRect, ask: CGRect) {
        func line(_ base: CGFloat) -> CGFloat { OfficeLook.lineHeight(OfficeLook.type(base, scale: scale)) }
        let left = card.minX + cardPad, wide = card.width - 2 * cardPad
        let name = CGRect(x: left, y: card.minY + cardPad, width: wide, height: line(cardType.name))
        let second = CGRect(x: left, y: name.maxY + 2, width: wide, height: line(cardType.second))
        let ask = CGRect(x: left, y: second.maxY + 1, width: wide, height: CGFloat(asks) * (line(cardType.ask) + 1.5))
        return (name, second, ask)
    }
    /// A waiting card's word sizes before `OfficeLook.type`, and its padding: small enough that seven cards and the
    /// eighth for the rest fit along the bottom.
    static let cardType: (name: CGFloat, second: CGFloat, ask: CGFloat) = (12.5, 10, 10.5), cardPad: CGFloat = 7
    static func cardHeight(scale: CGFloat, asks: Int) -> CGFloat { cardLines(.zero, scale: scale, asks: asks).ask.maxY + cardPad }

    /// Where a desk sitter's words go: its name or plate under its feet, and under that the project
    /// when the picture is shown at 90% or more. The painter writes them here; the waiting cards
    /// keep above the second row's.
    static func deskWords(foot: CGFloat, middle: CGFloat, scale: CGFloat) -> (plate: CGRect, project: CGRect?) {
        let line = { (base: CGFloat) in OfficeLook.lineHeight(OfficeLook.type(base, scale: scale)) }
        let plate = CGRect(x: middle - 62, y: foot + 8, width: 124, height: line(12) + 3)
        return (plate, scale >= 0.9 ? CGRect(x: middle - 62, y: plate.maxY + 2, width: 124, height: line(10.5)) : nil)
    }

    /// A sofa sitter's words: its plate under its feet, then the project at 90% or more. Narrower than the seat pitch,
    /// so two neighbours' plates never touch.
    /// The sizes a sofa plate's name tries, largest first, before it is cut (at zoom 1; the room's words grow as it shrinks).
    static let sofaPlateSizes: [CGFloat] = [12, 10.5, 9]

    /// How far a sofa plate may reach left and right of its seat's middle: its seat's share (the pitch less a point),
    /// and on a side where the next seat of the same sofa is empty, half that seat as well; an end seat also over the
    /// sofa's arm and half the gap to the next sofa, less a point.
    static func sofaPlateReach(seat: Int, occupied: Set<Int>) -> (left: CGFloat, right: CGFloat) {
        let half = (sofaPitch - 1) / 2, place = seat % 3, end: CGFloat = 22
        return (place > 0 ? (!occupied.contains(seat - 1) ? half + sofaPitch / 2 : half) : half + end,
                place < 2 ? (!occupied.contains(seat + 1) ? half + sofaPitch / 2 : half) : half + end)
    }

    /// The first size whose plate fits `room`, else the smallest.
    static func sofaPlateType(sizes: [CGFloat], room: CGFloat, need: (CGFloat) -> CGFloat) -> CGFloat {
        sizes.first { need($0) <= room } ?? sizes.last ?? 12
    }

    static func sofaWords(foot: CGFloat, middle: CGFloat, scale: CGFloat) -> (plate: CGRect, project: CGRect?) {
        let line = { (base: CGFloat) in OfficeLook.lineHeight(OfficeLook.type(base, scale: scale)) }
        let wide = sofaPitch - 6  // clear of the sofa's legs at its ends
        let plate = CGRect(x: middle - wide / 2, y: foot + 8, width: wide, height: line(12) + 3)
        return (plate, scale >= 0.9 ? CGRect(x: middle - wide / 2, y: plate.maxY + 2, width: wide, height: line(10.5)) : nil)
    }

    /// Who is in the room and where. Thirty at most, admitted the one that matters most first: waiting,
    /// with news, at work, looked at, resting. Each kind takes its own part of the room first and the
    /// next when that is full (news: sofa, desk, back row; work and looked at: desk, back row; resting:
    /// back row, then behind the door). The queue holds seven, in waiting order; one waiting beyond them
    /// stays where it sits, or takes a seat as one at work would, flagged, until its turn. One answered in
    /// the queue stays at its place there for `linger` seconds (measured at each layout, `now`), unless one
    /// waiting is due for the place.
    ///
    /// With an earlier room, everyone still in the same part of it keeps their seat, so a pet moves only
    /// when its own state changes, or a place frees. One taking a new seat takes the free one its way is
    /// shortest to (from the door, if it is new); a desk stays kept for whoever left it to wait or to tell
    /// news, and nobody else sits there: with thirty in the room the back row has a seat for whoever finds
    /// no desk.
    init(
        waiting: [String], unread: [String], busy: [String], seen: [String], resting: [String], height: CGFloat = 764, scale: CGFloat = 1,
        now: Date = Date(), previous: OfficeLayout? = nil
    ) {
        self.height = height
        self.scale = scale
        // Top to bottom: the back wall, two couch rows, two desk rows, the sofa band, and your corner along the bottom
        // edge. Each band is first put as close under the one above as its pets allow: a pose up to 1.1 times as tall as
        // its place (all but a few in the pool) clears the words of the row above by a point. Whatever height the room has
        // over that is shared out evenly over the six gaps, under the wall and over each band below it, so a short room
        // is tight everywhere a little and a tall one roomy everywhere alike. Measured with the words at this scale.
        func line(_ base: CGFloat) -> CGFloat { OfficeLook.lineHeight(OfficeLook.type(base, scale: scale)) }
        let lounging: CGFloat = 55, standing: CGFloat = 77  // 1.1 times 50 and 70 (worked out in floats, they round up a point)
        let loungeBelow = 8 + line(12) + 3  // a plate under the feet at the back; a resting one's name is shorter
        let atDesk = Self.deskWords(foot: 0, middle: 0, scale: scale), onSofa = Self.sofaWords(foot: 0, middle: 0, scale: scale)
        let deskBelow = (atDesk.project ?? atDesk.plate).maxY, sofaBelow = (onSofa.project ?? onSofa.plate).maxY
        // Where the feet would be with nothing to spare, and the cards' top.
        let lounge1 = 70 + 1 + lounging, lounge2 = lounge1 + loungeBelow + 1 + lounging
        let desk1 = lounge2 + loungeBelow + 1 + standing, desk2 = desk1 + deskBelow + 1 + standing
        let sofa = desk2 + deskBelow + 1 + standing, cards = sofa + sofaBelow + 1
        let foot = height - 6
        queueFoot = foot
        // Two lines of what each asks where the gaps keep 3 pt each with them, else one.
        func spare(_ asks: Int) -> CGFloat { foot - standing - 9 - Self.cardHeight(scale: scale, asks: asks) - cards }
        let asking = spare(2) >= 6 * 3 ? 2 : 1
        asks = asking
        let gap = max(0, spare(asking)) / 6
        func down(_ y: CGFloat, _ gaps: Int) -> CGFloat { (y + gap * CGFloat(gaps)).rounded() }
        loungeFloors = [down(lounge1, 1) + 3, down(lounge2, 2) + 3]
        deskFloors = [down(desk1, 3) - 10, down(desk2, 4) - 10]
        sofaFloor = down(sofa, 5) + 4
        generation = (previous?.generation ?? -1) + 1
        let before = Dictionary((previous?.pets ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        // Answered in the queue (waiting → at work), a session stays at its place there for a while, at work. When
        // one waiting is due for a place, the one answered longest ago gives its place up first.
        let working = Set(busy)
        var lingering: [String: Date] = [:]
        for pet in previous?.pets ?? [] where pet.zone == .queue && working.contains(pet.id) {
            let since = previous?.lingering[pet.id] ?? now
            if now.timeIntervalSince(since) < Self.linger { lingering[pet.id] = since }
        }
        let staying = lingering.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.map(\.key)

        // Who gets in, and into which part of the room. A desk kept for one away is no one else's: admission is done
        // again with those desks left out, once it is known who is away.
        let seats: [Zone: Int] = [.queue: Self.queueHolds, .sofa: Self.sofaSeats.count, .desk: 16, .lounge: 20]
        var used: [Zone: Int] = [:], room = Self.holds
        var zoneOf: [String: Zone] = [:], kindOf: [String: Kind] = [:]
        var waitingOut: [String] = [], newsOut: [String] = [], workOut: [String] = [], seenOut: [String] = [], restingOut: [String] = []
        let lined = Array(waiting.prefix(Self.queueHolds)), flagged = Array(waiting.dropFirst(Self.queueHolds))
        func admitAll(desks: Int) {
            used = [:]
            room = Self.holds
            zoneOf = [:]
            kindOf = [:]
            var places = seats
            places[.desk] = desks
            func admit(_ ids: [String], _ kind: Kind, _ zones: (String) -> [Zone]) -> [String] {
                let candidates = Array(ids.prefix(max(0, room)))
                // Those already in the first part they may use keep their place there before the others come in; so
                // does one coming back to the desk kept for it.
                let keepers = candidates.filter { id in
                    let first = zones(id).first
                    return before[id].map { $0.zone == first } ?? false || first == .desk && previous?.reserved[id] != nil
                }
                for id in keepers + candidates.filter({ !keepers.contains($0) }) {
                    guard let zone = zones(id).first(where: { used[$0, default: 0] < places[$0, default: 0] }) else { continue }
                    zoneOf[id] = zone
                    kindOf[id] = kind
                    used[zone, default: 0] += 1
                    room -= 1
                }
                return ids.filter { zoneOf[$0] == nil }
            }
            waitingOut = admit(lined, .waiting) { _ in [.queue] }
                + admit(flagged, .waiting) { id in (before[id].flatMap { $0.zone == .queue ? nil : [$0.zone] } ?? []) + [.desk, .lounge] }
            _ = admit(staying, .work) { _ in [.queue] }  // whoever finds no place is admitted below, as one at work
            newsOut = admit(unread, .news) { _ in [.sofa, .desk, .lounge] }
            workOut = admit(busy.filter { zoneOf[$0] == nil }, .work) { _ in [.desk, .lounge] }
            seenOut = admit(seen, .seen) { _ in [.desk, .lounge] }
            restingOut = admit(resting, .resting) { _ in [.lounge] }
        }
        admitAll(desks: 16)
        // Desks kept from before for those still away, and those just left by someone now in the queue or on a sofa.
        // Who is away does not depend on how many desks the others have, so the second admission keeps it.
        let away = Set(zoneOf.filter { $0.value == .queue || $0.value == .sofa }.keys)
        var kept: [String: (seat: Int, since: Int)] = [:]
        for (id, seat) in previous?.reserved ?? [:] where away.contains(id) { kept[id] = (seat, previous?.reservedSince[id] ?? 0) }
        for id in away where kept[id] == nil {
            if let was = before[id], was.zone == .desk { kept[id] = (was.seat, generation) }
        }
        if !kept.isEmpty { admitAll(desks: 16 - kept.count) }
        self.lingering = lingering.filter { zoneOf[$0.key] == .queue }
        func inZone(_ zone: Zone, _ ids: [String]) -> [String] { ids.filter { zoneOf[$0] == zone } }

        // Where each one comes from, for taking the seat its way is shortest to: its place before, or the door.
        func origin(_ id: String) -> OfficeSpot { before[id].map { OfficeSpot(point: CGPoint(x: $0.x, y: $0.foot), lane: .row) } ?? Self.doorSpot }
        func nearest(_ free: [Int], to from: OfficeSpot, tall: CGFloat, _ spot: (Int) -> OfficeSpot) -> Int? {
            let ways = free.map { seat in
                let to = spot(seat), way = Self.length(Self.route(from: from, to: to, height: height, tall: tall))
                return (way: way, across: abs(to.point.x - from.point.x), seat: seat)
            }
            return ways.min { ($0.way, $0.across, $0.seat) < ($1.way, $1.across, $1.seat) }?.seat
        }
        func stays(_ id: String, _ zone: Zone) -> Int? { before[id].flatMap { $0.zone == zone ? $0.seat : nil } }
        func seated(_ ids: [String], _ zone: Zone, tall: CGFloat, _ spot: (Int) -> OfficeSpot) -> [(id: String, seat: Int)] {
            guard previous != nil else { return ids.enumerated().map { ($1, $0) } }
            var taken = Set(ids.compactMap { stays($0, zone) })
            return ids.map { id in
                if let seat = stays(id, zone) { return (id, seat) }
                let seat = nearest((0..<seats[zone, default: 0]).filter { !taken.contains($0) }, to: origin(id), tall: tall, spot) ?? 0
                taken.insert(seat)
                return (id, seat)
            }
        }
        var all: [Pet] = []

        // Along the bottom edge, right of your desk, each under a card saying what it needs, as tall as at a desk.
        // Those already in the queue keep their order there; whoever joins comes after them, in waiting order.
        let members = inZone(.queue, lined + staying)
        let wasAt = Dictionary(uniqueKeysWithValues: (previous?.pets ?? []).filter { $0.zone == .queue }.map { ($0.id, $0.seat) })
        let queued = members.filter { wasAt[$0] != nil }.sorted { wasAt[$0]! < wasAt[$1]! } + members.filter { wasAt[$0] == nil }
        let tall: CGFloat = 70
        // The card's tail ends a point over the head of a pose 1.1 times as tall.
        let bottom = queueFoot - standing - 9, cardWidth = Self.cardWidth
        let sofaFoot = sofaFloor - 4
        let cardHigh = Self.cardHeight(scale: scale, asks: asks), top = bottom - cardHigh
        cardTop = top
        rugTop = max(top - 8, sofaFoot + sofaBelow + 1).rounded(.down)
        func card(_ slot: Int) -> CGRect { CGRect(x: Self.queueX(slot) - cardWidth / 2, y: top, width: cardWidth, height: cardHigh) }
        for (i, id) in queued.enumerated() {
            let x = Self.queueX(i)
            if kindOf[id] == .work {
                // Answered, it stays where it stood, at work: its name plate where its card's foot was, over its head,
                // since under its feet is the room's edge.
                let high = OfficeLook.lineHeight(OfficeLook.type(12, scale: scale)) + 3
                let plate = CGRect(x: x - cardWidth / 2, y: bottom - high, width: cardWidth, height: high)
                all.append(Pet(id: id, zone: .queue, seat: i, x: x, foot: queueFoot, tall: tall, kind: .work, words: plate))
                continue
            }
            all.append(Pet(id: id, zone: .queue, seat: i, x: x, foot: queueFoot, tall: tall, kind: .waiting, words: card(i)))
        }

        let sofaSpot = { OfficeSpot(point: CGPoint(x: Self.sofaSeats[$0], y: sofaFoot), lane: .row) }
        for (id, i) in seated(inZone(.sofa, flagged + unread), .sofa, tall: 70, sofaSpot) {
            let x = Self.sofaSeats[i], words = Self.sofaWords(foot: sofaFoot, middle: x, scale: scale)
            all.append(
                Pet(
                    id: id, zone: .sofa, seat: i, x: x, foot: sofaFoot, tall: 70, kind: kindOf[id] ?? .news,
                    words: words.plate.union(words.project ?? words.plate)))
        }

        // Desks fill from the aisle outward: the ones at work first, then the rest.
        let order = [3, 4, 2, 5, 1, 6, 0, 7]
        let rows = deskFloors, backRows = loungeFloors
        let deskSpot = { (seat: Int) in OfficeSpot(point: CGPoint(x: Self.deskLeft(order[seat % 8]) + 88, y: rows[seat / 8] + 10), lane: .row) }
        let atDesks = inZone(.desk, busy + flagged + unread + seen)
        var desks: [String: Int] = [:]
        if previous == nil {
            for (i, id) in atDesks.enumerated() { desks[id] = i }
        } else {
            // Where it sat; else the desk kept for it while it was away; else the free one its way is shortest to.
            let held = Set(kept.values.map(\.seat))
            for id in atDesks { desks[id] = stays(id, .desk) }
            for id in atDesks where desks[id] == nil {
                if let mine = previous?.reserved[id], !desks.values.contains(mine), !held.contains(mine) { desks[id] = mine }
            }
            for id in atDesks where desks[id] == nil {
                // Admission leaves a desk free for each: one that is nobody's, failing that (never so far) any not taken.
                let open = (0..<16).filter { !desks.values.contains($0) }
                desks[id] = nearest(open.filter { !held.contains($0) }, to: origin(id), tall: 70, deskSpot) ?? open.first
                if let seat = desks[id], let owner = kept.first(where: { $0.value.seat == seat })?.key { kept[owner] = nil }
            }
        }
        reserved = kept.mapValues(\.seat)
        reservedSince = kept.mapValues(\.since)
        for id in atDesks {
            guard let i = desks[id] else { continue }
            let spot = deskSpot(i).point
            all.append(
                Pet(
                    id: id, zone: .desk, seat: i, x: spot.x, foot: spot.y, tall: 70, kind: kindOf[id] ?? .seen,
                    words: CGRect(x: spot.x - 88, y: spot.y, width: 124, height: 46)))
        }

        let backSpot = { (seat: Int) in OfficeSpot(point: CGPoint(x: Self.loungeX(seat % 10), y: backRows[seat / 10] - 3), lane: .row) }
        let lounge = seated(inZone(.lounge, busy + flagged + unread + seen + resting), .lounge, tall: 50, backSpot)
        for (id, i) in lounge {
            let spot = backSpot(i).point
            all.append(
                Pet(
                    id: id, zone: .lounge, seat: i, x: spot.x, foot: spot.y, tall: 50, kind: kindOf[id] ?? .resting,
                    words: CGRect(x: spot.x - 48, y: spot.y, width: 96, height: 28)))
        }
        pets = all
        behindDoorIDs = seenOut + restingOut
        behindDoor = behindDoorIDs.count
        waitingElsewhere = waiting.filter { zoneOf[$0] != .queue }
        outside = [.waiting: waitingOut, .news: newsOut, .work: workOut]
        // Who is in each part of the room now, by seat, not by state; those behind the door are its +N.
        func tally(_ zone: Zone) -> Int { all.filter { $0.zone == zone }.count }
        counts = Counts(waiting: tally(.queue), news: tally(.sofa), desks: tally(.desk), resting: tally(.lounge))

        // The chips. Those waiting beyond the queue's seven: the queue's eighth place, a card like the others. With news or
        // work the room has no place for: on the back wall at its left end, one over the other, since the sofas and desks
        // now fill their bands from edge to edge of the grid and the floor has no spare line for them.
        let size = OfficeLook.type(11, scale: scale)
        let high = OfficeLook.lineHeight(size) + 4
        var measure: OfficeCanvas?  // made only when there is a chip to measure
        func wide(_ kind: ChipKind, _ count: Int) -> CGFloat {
            if measure == nil { measure = OfficeCanvas(CGSize(width: 1, height: 1)) }
            return measure!.width(of: kind.text(count), size: size) + (kind == .work ? 26 : 16)
        }
        var chips: [Chip] = []
        if !waitingElsewhere.isEmpty {
            chips.append(Chip(kind: .waiting, count: waitingElsewhere.count, rect: card(Self.queueHolds)))
        }
        var wall: CGFloat = 10
        for (kind, ids) in [(ChipKind.news, newsOut), (.work, workOut)] where !ids.isEmpty {
            chips.append(Chip(kind: kind, count: ids.count, rect: CGRect(x: 10, y: wall, width: wide(kind, ids.count), height: high)))
            wall += high + 6
        }
        self.chips = chips
    }

    /// The session whose pet or words are at this point; of two that overlap, the one standing in front.
    func session(at point: CGPoint) -> String? {
        pets.filter { $0.covers(point) }.max { $0.foot < $1.foot }?.id
    }

    /// What the ring goes round when this is pointed at: a pet's body, the door, the notice board, or a chip.
    var loungeTarget: CGRect { sceneDriven ? Extensions.registered?.loungeRect(height: height) ?? Self.door : Self.door }
    /// The list behind the door: in a scene, waiting sessions with no place in its queue come first.
    var restListIDs:[String] {
        var used=Set<String>()
        return ((sceneMode ? waitingElsewhere : [])+pets.filter{$0.kind == .resting || $0.kind == .seen}.map(\.id)+behindDoorIDs).filter{used.insert($0).inserted}
    }
    /// A scene that moves its figures itself has no notice board: it is not drawn there, so it is nothing to point at.
    var boardShown: Bool { !sceneDriven }
    func ring(for key: String) -> CGRect? {
        if key == Self.doorKey { return loungeTarget }
        if key == Self.boardKey { return boardShown ? Self.boardArea : nil }
        if let chip = chips.first(where: { $0.kind.key == key }) { return chip.rect }
        return pets.first { $0.id == key }?.body
    }

    /// What pointing at this session means here: its pet, the door it waits behind, or the chip that counts it.
    func pointed(at id: String) -> String? {
        if pets.contains(where: { $0.id == id }) { return id }
        if behindDoorIDs.contains(id) { return Self.doorKey }
        return outside.first { $0.value.contains(id) }?.key.key
    }
}

/// A way from one place to another: its legs, the aisle it goes by (0 the centre, 1 along the left wall, 2 along
/// the right; none within a row), and how far it goes before it is on that aisle.
struct OfficeWalk {
    var route: [CGPoint]
    var aisle: Int? = nil
    var reach: CGFloat = 0
    /// Its leg up or down that aisle.
    var leg: (from: CGPoint, to: CGPoint)? = nil
}

/// Where a walk starts or ends, and how that place is reached: along its own row (the line its row's feet are on: a
/// row of desks or couches, the sofas, the queue), or along the wall to the door.
struct OfficeSpot: Equatable {
    enum Lane { case row, door }
    let point: CGPoint
    let lane: Lane
}

extension OfficeLayout {
    /// Just inside the lounge door: where whoever comes in appears and whoever leaves goes.
    static let doorSpot = OfficeSpot(point: CGPoint(x: 1042, y: 84), lane: .door)
    static let doorLane: CGFloat = 92
    /// Where your desk and chair stand in a room this tall, outline included: no way goes past them.
    static func yourDeskArea(height: CGFloat) -> CGRect { CGRect(x: yourDesk.minX - 1, y: height - 112, width: yourDesk.width + 2, height: 109) }

    /// How long a walk takes: 240 pt a second up to 2.5 s; a longer way 2.5 s up to 800 pt, then 320 pt a second, 3.5 s at
    /// most. The long ways (a desk to the queue across the room) are walked a little longer rather than run past a skate.
    static func walkSeconds(_ route: [CGPoint]) -> Double {
        let length = Double(Self.length(route))
        return min(length / 240, max(2.5, min(3.5, length / 320)))
    }

    /// Where a pet is, reached along its row; a visitor stands in its host's.
    func spot(of pet: Pet) -> OfficeSpot { OfficeSpot(point: CGPoint(x: pet.x, y: pet.foot), lane: .row) }

    /// The way from one place to another in straight legs, since the pets only run sideways or on the
    /// spot: along its own floor to the aisle, up or down the aisle, along the lane the other place is
    /// reached by, and to it. Within one row, straight along it.
    func route(from a: OfficeSpot, to b: OfficeSpot, tall: CGFloat = 70) -> [CGPoint] { walk(from: a, to: b, tall: tall).route }

    /// The route, which aisle it takes (0 the centre, 1 the left wall, 2 the right) if any, and how far it
    /// goes before it is on that aisle; for a pet this tall, or reaching this far from its feet.
    func walk(from a: OfficeSpot, to b: OfficeSpot, tall: CGFloat = 70, body: Body? = nil) -> OfficeWalk {
        if sceneMode, let scene = Extensions.registered { return scene.walk(self, from: a, to: b) }
        return Self.walk(from: a, to: b, height: height, tall: tall, body: body)
    }

    /// How far a pet's drawn pixels reach to the left and to the right of its feet.
    typealias Body = (left: CGFloat, right: CGFloat)

    /// A pet this tall when nothing more is known of it: its idle frame is drawn at most 1.1 times as
    /// wide as it is tall, about its feet.
    static func body(tall: CGFloat) -> Body {
        let half = (tall * 0.55).rounded(.up) + 1
        return (half, half)
    }

    /// A pet's reach from its frames: `extent` is the leftmost and rightmost drawn column (in the frames'
    /// pixels) of every frame it may show on the way, its sprite hung `spriteX` from its feet and shown at
    /// `scale`. Half a point more on each side for the smoothing of scaled frames.
    static func body(spriteX: CGFloat, extent: (left: Int, right: Int), scale: CGFloat) -> Body {
        (-(spriteX + CGFloat(extent.left) * scale) + 0.5, spriteX + CGFloat(extent.right + 1) * scale + 0.5)
    }

    /// The ways up and down the room: the centre, along the left wall, along the right wall (the furniture
    /// ends at 1148). A pet on a wall aisle keeps its whole body inside the room, a point clear of the
    /// wall: the wall aisles move in by as much as it reaches past them. Running frames are often wider
    /// than the idle one, and off its centre, so this goes by the pet's own frames where they are known.
    static func aisles(tall: CGFloat) -> [CGFloat] { aisles(body: body(tall: tall)) }

    static func aisles(body: Body) -> [CGFloat] {
        [597, max(28, (body.left + 1).rounded(.up)), min(1166, (width - body.right - 1).rounded(.down))]
    }

    static func length(_ route: [CGPoint]) -> CGFloat { zip(route, route.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }

    static func route(from a: OfficeSpot, to b: OfficeSpot, height: CGFloat, tall: CGFloat = 70) -> [CGPoint] {
        walk(from: a, to: b, height: height, tall: tall).route
    }

    /// Along its own floor to an aisle, up or down it, along the row the other place is in, and to it; by whichever
    /// aisle makes that shortest, the centre when two are as short. Within one row, straight along it. The sofas run
    /// the room's width, so the aisles are the only ways through their band as through the desks' and the couches'. A
    /// wall aisle that a wide pet would have to take inside the furniture's line is no way for it, and none goes past
    /// your desk: from the queue the left wall is out of reach.
    static func walk(from a: OfficeSpot, to b: OfficeSpot, height: CGFloat, tall: CGFloat, body: Body? = nil) -> OfficeWalk {
        var points = [a.point]
        var y = a.point.y
        if a.lane == .door || a.point.y < Self.doorLane {  // out of the doorway onto the lane along the wall
            y = Self.doorLane
            points.append(CGPoint(x: a.point.x, y: y))
        }
        let lane = b.lane == .row ? b.point.y : Self.doorLane
        // In one row; a visitor stands 4 pt in front of its host's row, and is still in it.
        if a.lane != .door && b.lane != .door && abs(a.point.y - b.point.y) <= 4 {
            return OfficeWalk(route: straight(points + [CGPoint(x: b.point.x, y: a.point.y), b.point]))
        }
        if y == lane { return OfficeWalk(route: straight(points + [CGPoint(x: b.point.x, y: lane), b.point])) }
        let furniture = blockLefts[0]...(blockLefts[1] + blockWidth), desk = yourDeskArea(height: height)
        var best = OfficeWalk(route: [])
        for (i, x) in aisles(body: body ?? Self.body(tall: tall)).enumerated() where i == 0 || !furniture.contains(x) {
            let route = straight(points + [CGPoint(x: x, y: y), CGPoint(x: x, y: lane), CGPoint(x: b.point.x, y: lane), b.point])
            let pastDesk = zip(route, route.dropFirst()).contains { p, q in
                CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y)).insetBy(dx: -0.5, dy: -0.5).intersects(desk)
            }
            if i > 0 && pastDesk { continue }
            if best.route.isEmpty || length(route) < length(best.route) - 0.001 {
                let on = route.firstIndex(of: CGPoint(x: x, y: y)) ?? 0
                let leg = on + 1 < route.count && route[on + 1].x == x ? (route[on], route[on + 1]) : nil
                best = OfficeWalk(route: route, aisle: i, reach: length(Array(route.prefix(on + 1))), leg: leg)
            }
        }
        return best
    }

    /// No legs of no length, and no corners where it goes straight on.
    private static func straight(_ points: [CGPoint]) -> [CGPoint] {
        var route: [CGPoint] = []
        for p in points where p != route.last {
            if let b = route.last, route.count >= 2 {
                let a = route[route.count - 2]
                let down = a.x == b.x && b.x == p.x && (b.y - a.y) * (p.y - b.y) > 0
                let across = a.y == b.y && b.y == p.y && (b.x - a.x) * (p.x - b.x) > 0
                if down || across { route.removeLast() }
            }
            route.append(p)
        }
        return route
    }
}

// ───────── Visits ─────────

/// Who visits whom ("visiting"). When a round of talk opens, its opener walks over to the one it speaks to, stands there a
/// short while, and goes back to where its own state puts it: the walk says "A went to talk to B". That they go on
/// talking is said by the chat marks, for as long as they do.
struct OfficeVisits: Equatable {
    struct Visit: Equatable {
        let host: String
        /// 1 on the host's right, -1 on its left.
        let side: CGFloat
        /// Its round: the pair and when it opened.
        let round: String
        /// The visitor's kind and part of the room, and the host's place, when it set off: either changing ends it.
        let kind: OfficeLayout.Kind
        let zone: OfficeLayout.Zone
        let hostZone: OfficeLayout.Zone
        let hostSeat: Int
        /// About 20 s after it arrives.
        let until: Date
    }
    var visits: [String: Visit] = [:]
    /// Rounds that have had their visit, or could not: one each.
    var done: Set<String> = []
    /// Whether the office has looked before. What is going on when it first looks is not opening then: no visit.
    var looked = false

    /// Visitor → host.
    var hosts: [String: String] { visits.mapValues(\.host) }

    /// How far beside its host a visitor stands, clear of a desk sitter's plate (centred 26 pt to its left).
    static let apart: CGFloat = 46
    /// How long it stands there once it has arrived.
    static let stay: TimeInterval = 20
    /// A round opened longer ago than this when the office first sees it is not opening any more: the panel was showing
    /// the board, say. The scan that finds a message comes up to 10 s after it.
    static let fresh: TimeInterval = 30

    /// How the store names a pair of sessions.
    static func pair(_ a: String, _ b: String) -> String { a < b ? a + "|" + b : b + "|" + a }

    /// Those whose talk with someone open is recent: they carry the chat mark.
    static func talking(_ peers: [String: [Peer]], now: Date) -> Set<String> {
        Set(peers.filter { $0.value.contains { $0.isRecent(now) } }.keys)
    }

    /// Who visits whom now, from what was decided at the last look. A round opening sends its opener to the other, if:
    /// both are in the room; the opener sits at a desk or at the back and does not wait for you (the queue, a flag or a
    /// sofa keeps it where it is: you come first); the other is not in the queue; neither is visiting or visited already
    /// (one visitor at a host at a time, and never two visiting each other); and there is a free spot beside the other,
    /// away from its plate. The visit lasts until about 20 s after it arrives, or until the visitor's own state or the
    /// host's place changes; then the visitor goes where its state puts it. Each round gets one visit at most, and replies
    /// within it move nobody.
    static func next(
        _ layout: OfficeLayout, peers: [String: [Peer]], rounds: [String: Store.Round], previous: OfficeVisits = OfficeVisits(), now: Date
    ) -> OfficeVisits {
        let at = Dictionary(layout.pets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The rounds going on, opener first: their talk is recent.
        let going = rounds.compactMap { pair, round -> (key: String, opener: String, partner: String, since: Date)? in
            let ids = pair.split(separator: "|").map(String.init)
            guard ids.count == 2, ids.contains(round.opener), let partner = ids.first(where: { $0 != round.opener }),
                peers[round.opener]?.contains(where: { $0.id == partner && $0.isRecent(now) }) == true
            else { return nil }
            return ("\(pair) \(round.since.timeIntervalSince1970)", round.opener, partner, round.since)
        }.sorted { ($0.since, $0.key) < ($1.since, $1.key) }
        var plan = OfficeVisits(done: previous.done.intersection(going.map(\.key)), looked: true)
        guard previous.looked else {
            plan.done.formUnion(going.map(\.key))
            return plan
        }
        // Where everyone stands: at their seats, and those visiting beside their hosts.
        var standing = Dictionary(layout.pets.map { ($0.id, CGPoint(x: $0.x, y: $0.foot)) }, uniquingKeysWith: { first, _ in first })
        func spot(_ host: OfficeLayout.Pet, _ side: CGFloat) -> CGPoint { CGPoint(x: host.x + side * apart, y: host.foot + 4) }
        func free(_ spot: CGPoint, for visitor: OfficeLayout.Pet, by host: OfficeLayout.Pet) -> Bool {
            let reach = OfficeLayout.body(tall: visitor.tall)
            guard spot.x - reach.left >= 0, spot.x + reach.right <= OfficeLayout.width else { return false }
            let tall = visitor.tall
            let body = CGRect(x: spot.x - tall * 0.45, y: spot.y - tall * 1.12, width: tall * 0.9, height: tall * 1.12 + 6)
            return layout.pets.allSatisfy { other in
                guard other.id != visitor.id, other.id != host.id, let there = standing[other.id] else { return true }
                let beside = abs(there.y - spot.y) <= 10 && abs(there.x - spot.x) < (other.tall + visitor.tall) * 0.45
                return !beside && !(other.zone == .queue && other.kind == .waiting && other.words.intersects(body))  // nor under a card
            }
        }
        // Visits going on carry on while nothing has moved them and their time is not up.
        for (visitor, visit) in previous.visits.sorted(by: { $0.key < $1.key }) {
            guard going.contains(where: { $0.key == visit.round }), now < visit.until, let me = at[visitor], let host = at[visit.host],
                me.kind == visit.kind, me.zone == visit.zone, host.zone == visit.hostZone, host.seat == visit.hostSeat,
                free(spot(host, visit.side), for: me, by: host)
            else { continue }
            plan.visits[visitor] = visit
            standing[visitor] = spot(host, visit.side)
        }
        // A round opening now: its opener goes over, if it may.
        for round in going where !plan.done.contains(round.key) {
            plan.done.insert(round.key)
            let busy = Set(plan.visits.keys).union(plan.visits.values.map(\.host))
            guard now.timeIntervalSince(round.since) < fresh, let visitor = at[round.opener], let host = at[round.partner],
                visitor.zone == .desk || visitor.zone == .lounge, visitor.kind != .waiting, host.zone != .queue,
                !busy.contains(round.opener), !busy.contains(round.partner)
            else { continue }
            // Away from the host's plate: a desk sitter's is to its left, so the right; under one on a sofa or at the back,
            // so the right if free, else the left.
            let sides: [CGFloat] = host.zone == .desk ? [1] : [1, -1]
            guard let side = sides.first(where: { free(spot(host, $0), for: visitor, by: host) }) else { continue }
            let to = OfficeSpot(point: spot(host, side), lane: .row)
            let way = layout.walk(from: layout.spot(of: visitor), to: to, tall: visitor.tall)
            plan.visits[round.opener] = Visit(
                host: round.partner, side: side, round: round.key, kind: visitor.kind, zone: visitor.zone, hostZone: host.zone,
                hostSeat: host.seat, until: now + OfficeLayout.walkSeconds(way.route) + stay)
            standing[round.opener] = spot(host, side)
        }
        return plan
    }
}

extension OfficeLayout {
    /// The room with each visitor standing by its host, its words hidden, its seat still its own; and a chat mark on
    /// everyone `talking`, but one under its own waiting card, which is in the way. A visitor's mark and its host's go on
    /// the sides away from each other.
    /// `sizes`, by session, the pets drawn at other than the size their height gives (`OfficePets.sizes`).
    func visited(by plan: OfficeVisits, talking: Set<String> = [], sizes: [String: CGFloat] = [:]) -> OfficeLayout {
        guard !plan.visits.isEmpty || !talking.isEmpty || !sizes.isEmpty else { return self }
        let at = Dictionary(pets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let visitorSide = Dictionary(plan.visits.values.map { ($0.host, $0.side) }, uniquingKeysWith: { first, _ in first })
        var copy = self
        copy.pets = pets.map { pet in
            var shown = pet
            if let visit = plan.visits[pet.id], let host = at[visit.host] {
                shown = Pet(
                    id: pet.id, zone: pet.zone, seat: pet.seat, x: host.x + visit.side * OfficeVisits.apart, foot: host.foot + 4,
                    tall: pet.tall, kind: pet.kind, words: .null)
                shown.host = host.id
                shown.hostZone = host.zone
            }
            shown.size = sizes[pet.id] ?? 1
            if sceneMode { shown.markPlace = .tucked }
            shown.chats = talking.contains(pet.id) && !(pet.zone == .queue && pet.kind == .waiting)
            guard shown.chats else { return shown }
            shown.markLeft = (plan.visits[pet.id]?.side ?? 1) < 0 || (visitorSide[pet.id] ?? -1) > 0
            if !sceneMode && shown.foot - shown.head - 17 - 1 < wordsAbove(foot: shown.foot) {
                shown.markPlace = (shown.hostZone ?? shown.zone) == .sofa || visitorSide[pet.id] != nil ? .tucked : .beside
            }
            return shown
        }
        return copy
    }
}

extension OfficeLayout {
    /// How far down the words of the band above the row whose feet are at `foot` reach (for the first row at the back,
    /// the wall): a chat mark goes over a head only where it clears them. In the queue, over the head is its card.
    func wordsAbove(foot: CGFloat) -> CGFloat {
        let plate = 8 + OfficeLook.lineHeight(OfficeLook.type(12, scale: scale)) + 3
        func desk(_ row: Int) -> CGFloat {
            let words = Self.deskWords(foot: deskFloors[row] + 10, middle: 0, scale: scale)
            return (words.project ?? words.plate).maxY
        }
        let rows: [(feet: CGFloat, above: CGFloat)] = [
            (loungeFloors[0] - 3, 70), (loungeFloors[1] - 3, loungeFloors[0] - 3 + plate), (deskFloors[0] + 10, loungeFloors[1] - 3 + plate),
            (deskFloors[1] + 10, desk(0)), (sofaFloor - 4, desk(1)), (queueFoot, .infinity),
        ]
        return rows.last { $0.feet <= foot + 0.5 }?.above ?? 70
    }
}

extension OfficeLayout.Pet {
    /// The chat mark's box: just over its head; beside it on the right, a little in from the edge of its body; or on
    /// its top right corner, clear of the row above's words and of the next sitter on the sofa.
    var mark: CGRect {
        switch markPlace {
        case .over: return CGRect(x: x - 9, y: foot - head - 17, width: 18, height: 13)
        case .beside: return CGRect(x: markLeft ? x - (head * 0.4).rounded() - 18 : x + (head * 0.4).rounded(), y: foot - head + 2, width: 18, height: 13)
        case .tucked: return CGRect(x: markLeft ? x - 24 : x + 6, y: foot - head - 4, width: 18, height: 13)
        }
    }
    /// How tall it is drawn here: its place's height times its pet's own size (`size`).
    var head: CGFloat { tall * size }
    /// The mark as painted: with its outline and the tail under it.
    var markArea: CGRect { mark.insetBy(dx: -1, dy: -1).union(CGRect(x: mark.minX + 5, y: mark.maxY, width: 4, height: 3)) }
}

/// The room last laid out for the panel's store, so the next one keeps everyone in their seat. The
/// view and the hover card both lay the room out from it, so they agree on who sits where whichever
/// goes first. One store at a time: the panel has one.
@MainActor enum OfficeSeats {
    private static weak var owner: Store?
    private static var last: OfficeLayout?

    private static var plan = OfficeVisits()

    static func previous(for store: Store) -> OfficeLayout? { owner === store ? last : nil }

    /// Who was visiting whom in that room: the hover card stands beside a visitor where it is.
    static func visits(for store: Store) -> OfficeVisits { owner === store ? plan : OfficeVisits() }

    static func remember(_ layout: OfficeLayout, visits: OfficeVisits = OfficeVisits(), for store: Store) {
        owner = store
        last = layout
        plan = visits
    }
}

/// How the picture sits in a view of some size. It is 1194 wide and as tall as the view lets it
/// be, from 764 to 1000, so a taller window shows a roomier room rather than empty wall. In a
/// view wider than that it is 764 tall and centred, with the room carrying on at the sides; in
/// one taller than a 1000-high room, it stands on the bottom edge with wall above. The pointer,
/// clicks and the ring all go through this.
struct OfficeFit {
    let scale: CGFloat
    /// How tall the room is drawn.
    let height: CGFloat
    let offset: CGPoint

    /// The office's fit, or a scene's when an extension's scene that moves its figures itself is the theme.
    @MainActor init(_ size: CGSize) { self.init(size, fills: Extensions.active?.drivesFigures == true) }

    /// Such a scene has no bands: its room is as tall as the view's shape makes it, so the scene fills the view
    /// edge to edge; between 400 and the office's tallest, so that a very tall window keeps the whole scene in view
    /// over a band of wall rather than a strip of its middle, and a very low one still shows a strip of scene.
    init(_ size: CGSize, fills: Bool) {
        let wide = OfficeLayout.width, low = OfficeLayout.baseHeight
        if fills, size.width > 0 {
            scale = size.width / wide
            height = min(OfficeLayout.tallest, max(400, size.height / scale))
        } else if size.width * low > size.height * wide {
            scale = max(0, size.height / low)
            height = low
        } else {
            scale = max(0, size.width / wide)
            height = size.width > 0 ? min(OfficeLayout.tallest, max(low, (size.height * wide / size.width).rounded(.down))) : low
        }
        offset = CGPoint(x: (size.width - wide * scale) / 2, y: size.height - height * scale)
    }

    var room: CGSize { CGSize(width: OfficeLayout.width, height: height) }
    var picture: CGRect { rect(CGRect(origin: .zero, size: room)) }

    /// From the picture into the view.
    func rect(_ r: CGRect) -> CGRect {
        CGRect(x: offset.x + r.minX * scale, y: offset.y + r.minY * scale, width: r.width * scale, height: r.height * scale)
    }

    /// From the view back into the picture; nowhere in it while the view has no size.
    func point(_ p: CGPoint) -> CGPoint {
        scale > 0 ? CGPoint(x: (p.x - offset.x) / scale, y: (p.y - offset.y) / scale) : CGPoint(x: -1, y: -1)
    }
}

/// The office shows only where it can be drawn at 72% or more (about 860 by 550): smaller, its
/// words would have to grow past what their places hold.
func showsOffice(setting: Bool, size: CGSize) -> Bool { setting && OfficeFit(size, fills: false).scale >= 0.72 }

/// What the panel shows: the board, the office in one of its own themes, an extension's scene (`SceneExtension`),
/// or Seaview. Office goes back to the office theme last chosen (`officeThemeOffice`, the grey-blue office theme until one is), so a scene and
/// back lands where the user was.
@MainActor enum OfficeMode: CaseIterable {
    case board, office, scene, zone

    var title: String {
        switch self {
        case .board: return L10n.string("mode.board", table: "Office", zh: "值班室")
        case .office: return L10n.string("mode.office", table: "Office", zh: "办公室")
        case .scene: return Extensions.registered?.modeTitle ?? ""
        case .zone: return L10n.string("mode.zone", table: "Office", zh: "海景房")  // the code keeps .zone
        }
    }

    /// What stands for the mode where it is not shown (the menu items' `representedObject`): never its title, whose
    /// words follow the language.
    var code: String {
        switch self {
        case .board: return "board"
        case .office: return "office"
        case .scene: return "scene"
        case .zone: return "zone"
        }
    }

    /// The offered mode of this code; nil for none.
    static func coded(_ code: String?) -> OfficeMode? { offered.first { $0.code == code } }

    /// From the settings alone: the picture's theme (`OfficeTheme.shown`) says nothing about what the user chose.
    static var current: OfficeMode {
        guard UserDefaults.standard.bool(forKey: "office") else { return .board }
        let theme = OfficeTheme.named(UserDefaults.standard.string(forKey: "officeTheme")).name
        if theme == OfficeTheme.zone.name { return .zone }
        return theme == Extensions.scene?.theme.name ? .scene : .office
    }

    /// The modes this build can show, in the switch's and the menu's order: no scene without an extension that can
    /// show one.
    static var offered: [OfficeMode] { allCases.filter { $0 != .scene || Extensions.scene != nil } }

    func choose(store: Store) {
        switch self {
        case .scene: if let theme = Extensions.scene?.theme { setOfficeTheme(theme.name) }
        case .zone: setOfficeTheme(OfficeTheme.zone.name)
        case .office: setOfficeTheme(UserDefaults.standard.string(forKey: "officeThemeOffice") ?? OfficeTheme.studio.name)
        case .board: break
        }
        showOffice(self != .board, store: store)
    }
}

/// The status-bar menu's line for a mode. In a window too small for the office (or a scene) it says so, rather
/// than flipping a setting that changes nothing on screen.
@MainActor func officeMenuItem(_ mode: OfficeMode, fits: Bool) -> (title: String, enabled: Bool) {
    mode == .board || fits ? (mode.title, true) : (L10n.format("menu.modeNeedsWindow", table: "Board", zh: "%@（窗口再大一些才显示）", mode.title), false)
}

/// Switches the panel between the board and the office. The title bar measures its buttons
/// again when the store changes, and nothing else tells it that the setting moved.
@MainActor func showOffice(_ on: Bool, store: Store) {
    if !on {store.sceneListOpen=false}
    UserDefaults.standard.set(on, forKey: "office")
    store.objectWillChange.send()
}

// ───────── A session's menu ─────────

/// One line of the menu a right-click on a session brings up, on the board and in the office alike.
struct SessionMenuItem: Equatable {
    enum Action { case jump, pin, desk, rest, separator, openFolder, changePet, banPet, sizeUp, sizeDown, sizeReset, sendOff }
    let title: String
    let enabled: Bool
    let action: Action
}

/// The same menu for every session, whatever it is doing, so a resting one can be pinned back to the sofas as well as a
/// waiting one jumped to. A finished one can be moved between the three quiet places: Has news by a pin, a desk, the rest
/// area; each line is off where it already is. Moving means something only once it has finished: one that works again
/// loses its pin by itself, and is at a desk anyway. A pinned one stays by design until unpinned, so it is not sent to a
/// desk from here; to the rest area it may go, the pin with it.
@MainActor func sessionMenu(_ store: Store, _ s: Session) -> [SessionMenuItem] {
    // One that exited unexpectedly cannot be pinned or moved (it is gone in ten minutes): jump and its folder only.
    let idle = s.status == "idle" && !s.isGone, pinned = store.pinned.contains(s.id)
    let resting = idle && !store.isUnread(s) && store.isResting(s, now: Date())
    var folder: ObjCBool = false
    let opens = !s.cwd.isEmpty && FileManager.default.fileExists(atPath: s.cwd, isDirectory: &folder) && folder.boolValue
    let lines = [
        SessionMenuItem(title: L10n.string("session.jump", table: "Office", zh: "跳到会话"), enabled: true, action: .jump),
        SessionMenuItem(title: pinned ? L10n.string("session.unpin", table: "Office", zh: "取消待回复") : L10n.string("session.pin", table: "Office", zh: "标记待回复（留在「有话说」）"), enabled: idle, action: .pin),
        SessionMenuItem(title: L10n.string("session.desk", table: "Office", zh: "转到工位（算看过）"), enabled: idle && !pinned && (store.isUnread(s) || resting), action: .desk),
        SessionMenuItem(title: L10n.string("session.rest", table: "Office", zh: "转到休息区（不需要了）"), enabled: idle && !resting, action: .rest),
        SessionMenuItem(title: "", enabled: false, action: .separator),
        SessionMenuItem(title: L10n.string("session.openFolder", table: "Office", zh: "在访达里打开项目目录"), enabled: opens, action: .openFolder),
    ]
    // Its pet from the shared pool, changed or banned, in the office and the Seaview scene (the board shows pets too, but its menu is
    // left as it was; a scene may deal its own cast). Greyed when no pet is free: a ban would leave it holding the banned one.
    var pets: [SessionMenuItem] = []
    let mode = OfficeMode.current
    if mode == .office || mode == .zone {
        let free = !store.freePets(for: s).isEmpty
        pets = [
            SessionMenuItem(title: "", enabled: false, action: .separator),
            SessionMenuItem(title: L10n.string("session.changePet", table: "Office", zh: "换个角色"), enabled: free, action: .changePet),
            SessionMenuItem(title: L10n.string("session.banPet", table: "Office", zh: "以后不用这个角色"), enabled: free && store.petBySession[s.id] != nil, action: .banPet),
        ]
    }
    // In the Seaview scene only, the figure a step bigger or smaller (greyed at the end of the range), and back to the default
    // when it is not.
    var size: [SessionMenuItem] = []
    if mode == .zone {
        let step = store.figureStep(s)
        size = [
            SessionMenuItem(title: "", enabled: false, action: .separator),
            SessionMenuItem(title: L10n.string("session.sizeUp", table: "Office", zh: "放大一点"), enabled: step < 2, action: .sizeUp),
            SessionMenuItem(title: L10n.string("session.sizeDown", table: "Office", zh: "缩小一点"), enabled: step > -2, action: .sizeDown),
        ]
        if step != 0 { size.append(SessionMenuItem(title: L10n.string("session.sizeReset", table: "Office", zh: "恢复默认大小"), enabled: true, action: .sizeReset)) }
    }
    // In the Seaview scene only, an idle Claude Code session with a registry name may be sent off duty by hand (no
    // confirmation: waking brings it back). Not while it works or waits, nor while a send of it is under way.
    var off: [SessionMenuItem] = []
    if mode == .zone, s.kind == "claude", s.status == "idle", !s.restarting, !s.registryName.isEmpty, ZoneOffDuty.shared.available,
        !ZoneOffDuty.shared.sending.contains(s.registryName)
    {
        off = [SessionMenuItem(title: "", enabled: false, action: .separator), SessionMenuItem(title: L10n.string("session.sendOff", table: "Office", zh: "送下班"), enabled: true, action: .sendOff)]
    }
    // In the Seaview scene nothing goes to the rest room for being put away (its seats are for those with no desk): no Move to Resting.
    return (mode == .zone ? lines.filter { $0.action != .rest } : lines) + pets + size + off
}

/// The menubar's line that clears the ban list, with how many are on it (greyed at none).
func unbanMenuTitle(_ count: Int) -> String { L10n.format("menu.unban", table: "Board", zh: "恢复拉黑的角色（%lld）", count) }

// ───────── What just happened ─────────

/// What happened lately that is news to the user, for the notice board on the office wall: the latest fifty events, oldest
/// first, and how many came since the user last pointed at the board. Kept in the caches folder, so a restart does not blank
/// the board. What the user does themselves (opening, closing, setting a session to work) is not news, and is not kept.
struct OfficeActivity: Codable, Equatable {
    struct Event: Codable, Equatable {
        enum Kind: String, Codable { case finished, failed, approve, answer, waiting, talk }
        let at: Date
        let id: String
        /// Its name at that moment: one renamed later keeps the old name here.
        let name: String
        let kind: Kind
        /// For a talk: the other one's name at that moment.
        var partner: String? = nil
        /// For a finished turn the user did not start: "peer" or "agent"; nil for their own. Logged, marked, not news.
        var origin: String? = nil

        var text: String {
            switch kind {
            case .finished where origin == "peer": return L10n.format("event.finished.peer", table: "Office", zh: "↔ 干完了（与 %@ 往来）", partner ?? L10n.string("event.otherSession", table: "Office", zh: "其他会话"))
            case .finished where origin == "agent": return L10n.string("event.finished.agent", table: "Office", zh: "⚙ 干完了（子代理回报）")
            case .finished: return L10n.string("common.done", table: "Common", zh: "干完了")
            case .failed: return failedWords()
            case .approve: return L10n.string("event.approve", table: "Office", zh: "在等你批准")
            case .answer: return L10n.string("event.answer", table: "Office", zh: "在等你回答")
            case .waiting: return L10n.string("event.waiting", table: "Office", zh: "在等你")
            case .talk: return L10n.format("event.talk", table: "Office", zh: "找 %@ 说话", partner ?? "")
            }
        }
    }
    private(set) var events: [Event] = []
    /// Added since the board's card was last shown in the office: while there are any, a dot on the board.
    private(set) var unseen = 0
    static let keeps = 50

    /// Beside the links cache. The checks point this at a scratch file of their own.
    @MainActor static var file = cacheFolder + "/activity.json"

    /// What happened between two readings of the open sessions that the user did not do themselves: busy to idle finished; into
    /// waiting, for what. Opening, closing and starting to work are their own doing; a new summary, a new name, or
    /// waiting to idle are not news. Each under its name as read, at the time of the second reading.
    static func events(from before: [Session], to after: [Session], at now: Date) -> [Event] {
        // At work in the background is still at work: busy to idle with its work running is no finish.
        // A turn that ended in an error is logged as Error, not as finished.
        func state(_ s: Session) -> String { s.isWorking ? "busy" : s.hasError ? "failed" : s.status }
        let was = Dictionary(before.map { ($0.id, state($0)) }, uniquingKeysWith: { first, _ in first })
        return after.compactMap { s in
            // A session that exited unexpectedly finished nothing (its card is grey, it is counted nowhere).
            guard let old = was[s.id], old != state(s), !s.isGone else { return nil }
            let kind: Event.Kind? =
                switch state(s) {
                case "waiting": s.waitingFor == "permission prompt" || s.waitingFor == "permission request" ? .approve : s.waitingFor == "input needed" ? .answer : .waiting
                case "idle": old == "busy" ? .finished : nil
                case "failed": .failed
                default: nil
                }
            let other = kind == .finished && !Store.countsAsNews(s)
            return kind.map {
                Event(at: now, id: s.id, name: s.shownName, kind: $0, partner: other && s.origin == "peer" && !s.peer.isEmpty ? s.peer : nil,
                      origin: other ? s.origin : nil)
            }
        }
    }

    /// Rounds of talk that have just opened, each for the one who opened it, naming the other.
    static func talks(_ opened: [(opener: String, partner: String)], among sessions: [Session], at now: Date) -> [Event] {
        let names = Dictionary(sessions.map { ($0.id, $0.shownName) }, uniquingKeysWith: { first, _ in first })
        return opened.compactMap { round in
            guard let name = names[round.opener], let partner = names[round.partner] else { return nil }
            return Event(at: now, id: round.opener, name: name, kind: .talk, partner: partner)
        }
    }

    mutating func add(_ new: [Event]) {
        guard !new.isEmpty else { return }
        // The error line can land a tick after the turn ended: then the Finished just logged for it becomes this Error.
        for event in new where event.kind == .failed {
            if let i = events.lastIndex(where: { $0.id == event.id }), events[i].kind == .finished, event.at.timeIntervalSince(events[i].at) <= 10 {
                if events[i].origin == nil { unseen = max(0, unseen - 1) }
                events.remove(at: i)
            }
        }
        events = Array((events + new).suffix(Self.keeps))
        unseen = min(unseen + new.filter { $0.origin == nil }.count, events.count)
    }

    /// The card has been shown: nothing on the board is new any more.
    mutating func looked() { unseen = 0 }

    /// As it was left; nothing if there is no file yet, or it cannot be read.
    @MainActor static func load() -> OfficeActivity {
        FileManager.default.contents(atPath: file).flatMap { try? JSONDecoder().decode(OfficeActivity.self, from: $0) } ?? OfficeActivity()
    }

    @MainActor func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        let folder = (Self.file as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.file), options: .atomic)
    }
}

extension OfficeActivity {
    private enum CodingKeys: String, CodingKey { case events, unseen }

    /// One entry of a saved log, or nothing for a kind that is not kept (opened, closed and started-working are not logged).
    private struct Entry: Decodable {
        let event: Event?
        init(from decoder: Decoder) throws { event = try? Event(from: decoder) }
    }

    /// Reads what an earlier run left, keeping only what is still news, and no more than is kept; the count of what the user has
    /// not seen stays within that.
    init(from decoder: Decoder) throws {
        let saved = try decoder.container(keyedBy: CodingKeys.self)
        events = Array(try saved.decode([Entry].self, forKey: .events).compactMap(\.event).suffix(Self.keeps))
        unseen = max(0, min(try saved.decodeIfPresent(Int.self, forKey: .unseen) ?? 0, events.count))
    }
}

extension OfficeActivity.Event.Kind {
    /// Its dot on the card: coral for waiting for you, paper for finished, quiet for talk.
    var dot: UInt32 {
        switch self {
        case .approve, .answer, .waiting: return OfficeLook.call
        case .finished: return OfficeLook.paper
        case .failed: return failRedHex
        case .talk: return 0x9A96B8  // the board's quiet
        }
    }
}

// ───────── Subagents ─────────

/// The subagents each open session has running: the little people on its desk and the lines on its card. Claude Code
/// keeps them beside the session's transcript, in `<session>/subagents/`: per agent its own transcript
/// (`agent-<id>.jsonl`, up to tens of megabytes) and what it was asked (`agent-<id>.meta.json`). A finished one's
/// transcript ends with the line Orca's SubagentStop hook leaves; a resumed one writes on, and ends with another. The
/// session's own Agent calls say nothing: a background agent's call returns as it starts.
final class OfficeSubagents {
    struct Agent: Equatable {
        let description: String
        /// As its own replies name it ("claude-opus-5-5"), or until one is read, as the Agent call asked ("opus"); empty
        /// when neither says.
        let model: String
        /// What kind of agent its meta file says it is ("general-purpose", "codex:codex-rescue"…); empty when it does not.
        var agentType = ""
    }

    /// How much of a transcript's end is read. Every stop line seen so far is under 4 KB, so a last line that began
    /// before this much of the end is the agent's own, and it is still running.
    static let window = 6 * 1024
    /// One quiet this long with no stop at its end was killed, or ran with the hook off: it is gone.
    static let gone: TimeInterval = 30 * 60
    /// Bytes read from transcripts so far: the checks hold a scan to its budget.
    private(set) var read = 0

    /// What the last read of an agent's transcript found, and the size and time the file had then.
    private struct Look {
        var size: Int64
        var mtime: Double
        var finished = false
        var model: String?  // as a reply of its own named it, once one was read
        var asked: (description: String, model: String, type: String)?  // its meta file, once it is there
    }
    /// A subagents folder as last listed: the folder's time changes only when an agent is added or removed.
    private struct Folder {
        var mtime: Double
        var names: [String]  // its agents' transcripts
        var looks: [String: Look] = [:]  // by transcript name
    }
    private var folders: [String: Folder] = [:]
    private static let stop = Phrase("\"hookEvent\":\"SubagentStop\"")
    // An agent's reply names its model first thing in its message. Other lines name models too (an advisor's, in the
    // usage a reply carries, or the session's advisor at its end), never right after "message".
    private static let reply = Array("\"message\":{\"model\":\"".utf8)

    /// The running subagents of each of these sessions (id, transcript path), by id; none running, no entry. The folders
    /// of sessions no longer among them are forgotten.
    func running(_ transcripts: [(String, String)], now: Date) -> [String: [Agent]] {
        var out: [String: [Agent]] = [:], open = Set<String>()
        for (sid, path) in transcripts where path.hasSuffix(".jsonl") {
            let folder = String(path.dropLast(6)) + "/subagents"
            open.insert(folder)
            let agents = running(in: folder, now: now)
            if !agents.isEmpty { out[sid] = agents }
        }
        folders = folders.filter { open.contains($0.key) }
        return out
    }

    /// The agents running in one session's subagents folder, the longest-running first. A look costs a `stat` of the
    /// folder and of each transcript in it; the folder is listed again only when its time has changed, and a transcript
    /// read only when its size or time has, and then only its end.
    func running(in folder: String, now: Date) -> [Agent] {
        var info = stat()
        // Most sessions have no subagents folder; asking to list a missing one costs more than the rest of the look.
        guard stat(folder, &info) == 0 else {
            folders[folder] = nil
            return []
        }
        var known = folders[folder] ?? Folder(mtime: -1, names: [])
        if known.mtime != Self.seconds(info.st_mtimespec) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            known.mtime = Self.seconds(info.st_mtimespec)
            known.names = names.filter { $0.hasPrefix("agent-") && $0.hasSuffix(".jsonl") }
        }
        let before = known.looks
        var after: [String: Look] = [:], found: [(born: Double, name: String, agent: Agent)] = []
        for name in known.names {
            let path = folder + "/" + name
            guard stat(path, &info) == 0 else { continue }
            let size = Int64(info.st_size), mtime = Self.seconds(info.st_mtimespec)
            // Quiet for half an hour it is not running, whatever its end says: not worth a read. Most transcripts are.
            guard now.timeIntervalSince1970 - mtime < Self.gone else { continue }
            var look = before[name] ?? Look(size: -1, mtime: 0)
            if look.size != size || look.mtime != mtime {
                let (end, whole) = ending(of: path, size: size)
                look.size = size
                look.mtime = mtime
                look.finished = Self.finished(end, whole: whole)
                look.model = Self.model(in: end) ?? look.model
            }
            if !look.finished && look.asked == nil { look.asked = Self.asked(at: String(path.dropLast(6)) + ".meta.json") }
            after[name] = look
            guard !look.finished else { continue }
            let agent = Agent(description: look.asked?.description ?? "", model: look.model ?? look.asked?.model ?? "",
                              agentType: look.asked?.type ?? "")
            found.append((Self.seconds(info.st_birthtimespec), name, agent))
        }
        known.looks = after
        folders[folder] = known
        return found.sorted { ($0.born, $0.name) < ($1.born, $1.name) }.map(\.agent)
    }

    private static func seconds(_ t: timespec) -> Double { Double(t.tv_sec) + Double(t.tv_nsec) / 1e9 }

    /// The last `window` bytes of a transcript, and whether that is all of it.
    private func ending(of path: String, size: Int64) -> (Data, Bool) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return (Data(), true) }
        defer { try? handle.close() }
        let from = max(0, size - Int64(Self.window))
        try? handle.seek(toOffset: UInt64(from))
        let end = (try? handle.read(upToCount: Self.window)) ?? Data()
        read += end.count
        return (end, from == 0)
    }

    /// Whether the last line in these last bytes of a transcript is the SubagentStop hook's. With nothing before it in
    /// them, it counts only if they are the whole file.
    static func finished(_ end: Data, whole: Bool) -> Bool {
        var line = end[...]
        if line.last == 0x0A { line = line.dropLast() }
        if let newline = line.lastIndex(of: 0x0A) {
            line = line[(newline + 1)...]
        } else if !whole {
            return false
        }
        return line.withUnsafeBytes { stop.isIn($0) }
    }

    /// The model a reply among these bytes names, if one is there and it is a Claude model.
    static func model(in end: Data) -> String? {
        end.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress,
                let hit = reply.withUnsafeBytes({ memmem(base, raw.count, $0.baseAddress, $0.count) })
            else { return nil }
            let from = base.distance(to: UnsafeRawPointer(hit)) + reply.count
            guard let quote = raw[from...].prefix(80).firstIndex(of: 0x22) else { return nil }
            let id = String(decoding: raw[from..<quote], as: UTF8.self)
            return id.hasPrefix("claude-") ? id : nil
        }
    }

    /// What its meta file says it was asked: the description, and the model the call asked for ("inherit": the session's
    /// own, which says nothing here), and its `agentType`.
    static func asked(at path: String) -> (description: String, model: String, type: String)? {
        guard let data = FileManager.default.contents(atPath: path),
            let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let model = o["model"] as? String ?? ""
        return ((o["description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines), model == "inherit" ? "" : model,
                o["agentType"] as? String ?? "")
    }

    /// The name a model goes by on a card, the way the status line shows it: "claude-opus-5-5" is Opus 5.5,
    /// "claude-haiku-4-5-20251001" Haiku 4.5; an alias the Agent call asked for ("opus") just Opus.
    static func name(of model: String) -> String {
        // "[1m]" is how much it holds, not which it is.
        var parts = (model.split(separator: "[").first ?? "").lowercased().split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        if let date = parts.last, date.count == 8, date.allSatisfy(\.isNumber) { parts.removeLast() }
        let words = parts.filter { !$0.allSatisfy(\.isNumber) }, version = parts.filter { $0.allSatisfy(\.isNumber) }
        guard !words.isEmpty, words != ["inherit"] else { return "" }
        return (words.map { $0.prefix(1).uppercased() + $0.dropFirst() } + (version.isEmpty ? [] : [version.joined(separator: ".")]))
            .joined(separator: " ")
    }
}

/// What `--hover <name>` points the still picture at: the notice board by its name, else that session's pet, or the door
/// or chip that counts it.
@MainActor func officePointed(named name: String, store: Store, layout: OfficeLayout) -> String? {
    let token = OfficeLayout.HoverToken(rawValue: name)
    if token == .board { return OfficeLayout.boardKey }
    if token == .waitingChip, layout.chips.contains(where: { $0.kind == .waiting }) { return OfficeLayout.ChipKind.waiting.key }
    return store.sessions.first { $0.name == name }.flatMap { layout.pointed(at: $0.id) }
}

// ───────── Where the user types ─────────

/// Whether the session the user types in, in Orca, has a light on its pet; switched in the menu bar, on until switched off. The
/// permission stays as it is either way.
func officeSpotlight() -> Bool { UserDefaults.standard.object(forKey: "officeSpotlight") as? Bool ?? true }

func setOfficeSpotlight(_ on: Bool) { UserDefaults.standard.set(on, forKey: "officeSpotlight") }

/// The status-bar item for the light: ticked while it follows Orca. Without the permission it says what it needs, and
/// choosing it asks the system for it.
func spotlightMenuItem(trusted: Bool, on: Bool) -> (title: String, checked: Bool, help: String) {
    let title = L10n.string("menu.spotlight", table: "Board", zh: "聚光灯：跟着 Orca 里的会话")
    guard trusted else {
        return (
            L10n.format("menu.spotlight.needsAccess", table: "Board", zh: "%@（需要辅助功能权限…）", title), false,
            L10n.string("menu.spotlight.help.needsAccess", table: "Board", zh: "要在 系统设置 > 隐私与安全性 > 辅助功能 里允许「Soulgent」。它请 Orca 把页面开放给辅助功能，只读标签栏上的标签名，好知道你在哪个会话里打字。")
        )
    }
    return (title, on, on ? L10n.string("menu.spotlight.help.on", table: "Board", zh: "办公室里，你在 Orca 里打字的那个会话头上有一束光。点一下关掉。") : L10n.string("menu.spotlight.help.off", table: "Board", zh: "点一下打开：办公室里给你在 Orca 里打字的那个会话打一束光。"))
}

/// Which session the user is typing in. Orca's window is titled just "Orca", and its page shows a reader nothing until one asks:
/// so while the light is on the panel asks (`AXEnhancedUserInterface`, what VoiceOver sets), finds Orca's tab bar once, and
/// on each look reads only the titles of the tabs in it. Those tabs are one of the worktrees Orca lays out; that worktree's
/// active tab shows a terminal, and the session started in it gets the light. Accessibility is used for this and nothing
/// else, and never on the main thread.
final class OfficeFocus {
    static let orca = "com.stablyai.orca"
    /// What the close button in a tab is called, the tab's title after it: Orca in Chinese, and in its own English.
    static let closeLabels = ["关闭选项卡", "Close tab"]

    /// A terminal on show in Orca: the active pane of the active tab of a worktree. `pane` is "tabId:leafId", as a session's
    /// `ORCA_PANE_KEY` has it; `tab` is the tab's title, `title` the pane's own, `worktree` the worktree's folder name.
    struct Terminal: Equatable {
        let handle: String, pane: String, tab: String, title: String, worktree: String
    }
    /// A tab in a worktree's layout: its title, and the terminal it shows (its active leaf's pane).
    struct Tab: Equatable {
        let title: String
        let terminal: Terminal?
    }
    /// A group of tabs in a worktree's layout: its tabs in order, and which is active by Orca's list.
    struct Group: Equatable {
        let tabs: [Tab]
        let active: Int?
        var titles: [String] { tabs.map(\.title) }
        /// The terminal the group shows by Orca's list: its active tab's.
        var shown: Terminal? { active.flatMap { tabs[$0].terminal } }
    }
    /// A worktree as Orca lays it out: its folder's name, and its groups of tabs (one, unless the user split it).
    struct Worktree: Equatable {
        let name: String
        let groups: [Group]
        /// Its terminals Orca lists but lays out in no tab (`orphaned`, untitled, tab id "pty:…"): those of an Orca restarted
        /// under them, live sessions still, and the shell left behind by a session woken in a new tab. Each with its handle
        /// and its `recordedPaneKey` as the pane, so a session's own handle or pane finds it.
        var orphans: [Terminal] = []
    }
    /// A tab as the bar shows it: its title; how many levels below the bar its button sits (Orca docks the active tab a
    /// level down, so a switch of tabs changes the bar even when the titles stay the same); and what its button says of
    /// itself, selected and its page's classes, either of which may tell the active tab.
    struct BarTab: Equatable {
        let title: String
        let depth: Int
        var selected = false
        var classes: [String] = []
    }
    /// What reading the bar came to: its tabs; gone, an element Orca no longer has (another worktree shown, say); or
    /// failed, no answer this time.
    enum Bar: Equatable { case tabs([BarTab]), gone, failed }
    /// An element of Orca's window as the bar's finder and reader see it, in one message: its role, its title, what it holds;
    /// for the reader also whether it is selected or focused, its value and its page's classes.
    struct Element<E> {
        var role = "", title = ""
        var children: [E] = []
        var selected = false, focused = false
        var value = ""
        var classes: [String] = []
        var gone = false, failed = false
    }
    /// Which terminal the bar is: one; none; several worktrees that fit; or one worktree split into this many groups.
    /// `orphan`: the bar's active tab is one Orca lays out in no tab; its title, plain, the terminal it is when that is
    /// certain (the bar has one tab more than the worktree's layout, and the worktree one orphan), and the orphans it may be.
    enum Match: Equatable {
        case one(Terminal), none, several(Int), split(Int)
        case orphan(title: String, sure: Terminal?, among: [Terminal])
    }
    /// What a look comes to: a session; a terminal no open session runs in; or nothing it matches.
    enum Found: Equatable { case session(String), noSession, nothing }

    /// What the reader asks, each a hook a check can replace.
    var frontmost: @MainActor () -> (bundle: String, pid: pid_t)? = {
        NSWorkspace.shared.frontmostApplication.map { ($0.bundleIdentifier ?? "", $0.processIdentifier) }
    }
    /// Whether Orca runs at all: on a Mac without it there is nothing to be behind, so the light stays full. A check gives this a hook too.
    var running: @MainActor () -> Bool = {
        !NSRunningApplication.runningApplications(withBundleIdentifier: OfficeFocus.orca).isEmpty
    }
    var trusted: () -> Bool = { AXIsProcessTrusted() }
    /// Opens Orca's page to readers, or closes it again; what came of it, for the log.
    var enhance: (pid_t, Bool) -> String = { OfficeFocus.enhance($0, on: $1) }
    /// Asks Orca to tell of focus and title changes: the observer to keep, and what came of it, for the log.
    var watch: (pid_t, OfficeFocus) -> (observer: AXObserver?, said: String) = { OfficeFocus.watch($0, $1) }
    /// Looks for the tab bars in Orca's focused window: those found, and how many elements were looked at.
    var findBar: (pid_t) -> (bars: [AXUIElement], looked: Int) = { OfficeFocus.findBar(in: $0) }
    var readBar: ([AXUIElement]) -> Bar = { OfficeFocus.tabs(in: $0, read: { OfficeFocus.element($0, full: true) }) }
    var list: () -> [String: Any]? = { orcaTerminalList(orcaCall("terminal.list", ["includeVisualLayouts": true]))?["result"] as? [String: Any] }
    var tab: (Int32) -> (terminal: String, pane: String)? = { OrcaTabs.shared.tab(of: $0) }
    /// The pane a process was started in, never waiting for `ps` (a click asks it on the main thread): "" for one not
    /// started from Orca, nil while not yet known.
    var pane: (Int32) -> String? = { OrcaTabs.shared.pane(of: $0) }
    var note: (String) -> Void = { log($0) }
    /// What a notice from Orca comes to, a moment later: the store's own look (`Store.start` sets it).
    var nudge: @MainActor () -> Void = {}
    /// Where Orca is read and its list fetched; nil for a check, which has the answer at once.
    var queue: DispatchQueue? = DispatchQueue(label: appID + ".focus", qos: .utility)

    // Touched on `queue` only (or, for a check, on the main thread only).
    /// The Orca whose page the panel opened to readers, and the observer of it.
    private var opened: pid_t?
    private var observer: AXObserver?
    /// The tab bars found in Orca's window: read on each look until Orca lets them go.
    private var bars: [AXUIElement] = []
    /// When the bar may be looked for: at once once it is lost, 10 s after a look that found none.
    private var nextLook = Date.distantPast
    private var barTold = false, missTold = false
    /// Looks in a row at which the bar gave no answer (Orca busy past the tenth of a second each element is given).
    private var unanswered = 0
    private var readOnce = false
    private var slowest = 0.05
    private var worktrees: [Worktree] = []
    private var listed = Date.distantPast
    /// The bar at the last look, and since when it has been so.
    private var lastBar: [BarTab] = []
    private var barSince = Date.distantPast
    /// The terminal each open session was started in, by session and process; nil for one not started from Orca.
    private var started: [String: (terminal: String, pane: String)?] = [:]
    /// Every name each open session has had while the panel watched, by session id. After a `/rename` Orca's tab keeps
    /// the old title until something renames it, so an orphaned tab of an old name still finds its session.
    private var namesSeen: [String: Set<String>] = [:]
    private var told = Set<String>()
    /// The bars whose match took a fallback (`pick`'s subset, an orphaned tab), each told in the log once.
    private var fellBack = Set<String>()
    /// The last change of the light told in the log, and when: at most one line a second.
    private var said: String?
    private var saidAt = Date.distantPast
    // Touched on the main thread only.
    private var busy = false
    private var known: Bool?
    private var nudging = false
    private var heard = Set<String>()
    /// Orca told of a change since the last look: that look asks for Orca's list afresh.
    private var stirred = false

    /// Opens Orca's page to readers, or closes it again, and says what came of it. Orca answers the switch with -25208 (not
    /// implemented) and does it all the same, so what it reads back is what counts. A page just opened takes a moment or two
    /// to build its tree: the first look for the bar waits for that here, off the main thread.
    static func enhance(_ pid: pid_t, on: Bool) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let name = "AXEnhancedUserInterface" as CFString
        func now() -> String {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, name, &value)
            guard error == .success, let value else { return "AXError \(error.rawValue)" }
            guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return "\(value)" }
            return CFBooleanGetValue((value as! CFBoolean)) ? "on" : "off"
        }
        let was = now()
        let set = AXUIElementSetAttributeValue(app, name, on ? kCFBooleanTrue : kCFBooleanFalse)
        if on, was != "on" { Thread.sleep(forTimeInterval: 2.5) }
        return "AXEnhancedUserInterface \(was) → \(now()) (AXError \(set.rawValue))"
    }

    /// Asks Orca to tell of focus and title changes, on the main run loop. A notice only brings the tick's own look forward;
    /// Electron may tell nothing, and then the tick is all there is.
    static func watch(_ pid: pid_t, _ focus: OfficeFocus) -> (observer: AXObserver?, said: String) {
        var made: AXObserver?
        let created = AXObserverCreate(
            pid,
            { _, _, notification, refcon in
                guard let refcon else { return }
                Unmanaged<OfficeFocus>.fromOpaque(refcon).takeUnretainedValue().noticed(notification as String)
            }, &made)
        guard created == .success, let made else { return (nil, "no observer (AXError \(created.rawValue))") }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        let me = Unmanaged.passUnretained(focus).toOpaque()
        let focusChanges = AXObserverAddNotification(made, app, kAXFocusedUIElementChangedNotification as CFString, me)
        let titleChanges = AXObserverAddNotification(made, app, kAXTitleChangedNotification as CFString, me)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(made), .defaultMode)
        return (made, "focus changes AXError \(focusChanges.rawValue), title changes AXError \(titleChanges.rawValue)")
    }

    /// The tab bars in Orca's focused window, looked for breadth first: at most 4000 elements, 25 levels down, a tenth of a
    /// second for each and five seconds in all, so a hung Orca cannot hold the light's queue for minutes.
    static func findBar(in pid: pid_t) -> (bars: [AXUIElement], looked: Int) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success, let window,
            CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return ([], 0) }
        return bars(under: window as! AXUIElement, until: CACurrentMediaTime() + 5, read: { element($0) }, same: { CFEqual($0, $1) })
    }

    /// An element's role, title and children in one message, waiting at most 0.1 s: the timeout is per element, so each gets
    /// its own. `full`, for the bar's reader, asks in the same message whether it is selected or focused, its value and its
    /// page's classes; the walk does without, over hundreds of elements. One Orca no longer has is gone; one that does not
    /// answer has failed.
    static func element(_ e: AXUIElement, full: Bool = false) -> Element<AXUIElement> {
        AXUIElementSetMessagingTimeout(e, 0.1)
        var answer: CFArray?
        let names = [kAXRoleAttribute, kAXTitleAttribute, kAXChildrenAttribute]
            + (full ? [kAXSelectedAttribute, kAXFocusedAttribute, kAXValueAttribute, "AXDOMClassList"] : [])
        let error = AXUIElementCopyMultipleAttributeValues(e, names as CFArray, [], &answer)
        var read = Element<AXUIElement>()
        guard error == .success, let values = answer as? [AnyObject], values.count == names.count else {
            read.gone = error == .invalidUIElement
            read.failed = !read.gone
            return read
        }
        // Each attribute it could not give comes back as an error of its own.
        func code(_ value: AnyObject) -> AXError? {
            guard CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError else { return nil }
            var code: Int32 = 0
            AXValueGetValue(value as! AXValue, .axError, &code)
            return AXError(rawValue: code)
        }
        if values.allSatisfy({ code($0) == .invalidUIElement }) {
            read.gone = true
            return read
        }
        read.role = values[0] as? String ?? ""
        read.title = values[1] as? String ?? ""
        read.children = (values[2] as? [AnyObject] ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
        guard full else { return read }
        read.selected = (values[3] as? Bool) == true
        read.focused = (values[4] as? Bool) == true
        read.value = code(values[5]) == nil ? (values[5] as? String ?? (values[5] as? NSNumber)?.stringValue ?? "") : ""
        read.classes = (values[6] as? [AnyObject] ?? []).compactMap { $0 as? String }
        return read
    }

    /// The tab bars below `top`, breadth first: at most `most` elements read, `deepest` levels down, until `until`. A tab's
    /// button sits right in its bar, but Orca docks the active tab in a group of its own a level down: so the bar is a
    /// button's parent, or the parent's parent when the parent holds the button alone. A tab's own parts are not looked into.
    static func bars<E>(
        under top: E, most: Int = 4000, deepest: Int = 25, until: CFTimeInterval = .infinity, read: (E) -> Element<E>,
        same: (E, E) -> Bool
    ) -> (bars: [E], looked: Int) {
        var seen: [(element: E, parent: Int, holds: Int)] = []
        var waiting: [(element: E, depth: Int, parent: Int)] = [(element: top, depth: 0, parent: -1)]
        var head = 0
        var found: [E] = []
        while head < waiting.count, seen.count < most, CACurrentMediaTime() < until {
            let (element, depth, parent) = waiting[head]
            head += 1
            let e = read(element)
            seen.append((element: element, parent: parent, holds: e.children.count))
            if e.role == kAXButtonRole, parent >= 0, tabTitle(of: e.title) != nil {
                let up = seen[parent]
                let bar = up.holds == 1 && up.parent >= 0 ? seen[up.parent].element : up.element
                if !found.contains(where: { same($0, bar) }) { found.append(bar) }
                continue
            }
            let me = seen.count - 1
            if depth < deepest { waiting += e.children.map { (element: $0, depth: depth + 1, parent: me) } }
        }
        return (found, seen.count)
    }

    /// The tabs in the bars, in order: each thing a bar holds, and inside one that is not a button up to two levels more,
    /// where Orca docks the active tab. A handful of messages to Orca: one per tab, and one or two more.
    static func tabs<E>(in bars: [E], read: (E) -> Element<E>) -> Bar {
        var found: [BarTab] = []
        func look(_ children: [E], _ depth: Int) {
            for child in children {
                let c = read(child)
                if c.role == kAXButtonRole {
                    if let title = tabTitle(of: c.title) {
                        found.append(BarTab(title: title, depth: depth, selected: c.selected, classes: c.classes))
                    }
                } else if depth < 3 {
                    look(c.children, depth + 1)
                }
            }
        }
        for bar in bars {
            let b = read(bar)
            if b.gone { return .gone }
            if b.failed { return .failed }
            look(b.children, 1)
        }
        return .tabs(found)
    }

    /// The title of the tab the bar shows as active, when it says so of one tab only: the one selected; else the one docked
    /// a level deeper than the rest (seen on the real screen); else the one whose classes mark it (a class with "active" or
    /// "selected" in it but not "inactive" or "unselected", or Orca's own `text-foreground`, which its other tabs have as
    /// `text-muted-foreground`). A tab alone is not taken for the active one unmarked: the bar may be showing only some of the
    /// worktree's tabs (a pinned one is not read). nil when nothing tells, and Orca's list has to.
    static func active(in bar: [BarTab]) -> String? {
        func only(_ marked: (BarTab) -> Bool) -> String? {
            let found = bar.filter(marked)
            return found.count == 1 ? found[0].title : nil
        }
        let shallowest = bar.map(\.depth).min() ?? 0
        func marks(_ token: String) -> Bool {
            (token.contains("active") || token.contains("selected")) && !token.contains("inactive") && !token.contains("unselected")
        }
        return only(\.selected)
            ?? only { $0.depth > shallowest }
            ?? only { $0.classes.contains(where: marks) }
            ?? only { $0.classes.contains("text-foreground") && !$0.classes.contains("text-muted-foreground") }
    }

    /// The title of the tab a button of Orca's tab bar is, from the button's own: "<status> <title> the close-tab label <title>". The
    /// status ("Working", …) is there only while there is one and may be more than a word, and a the collapse-pane label button may come
    /// before the close button's label. The title is what follows that label, and it must be said before it too. nil for
    /// any other button, a file's tab among them: its close button names no title.
    static func tabTitle(of button: String) -> String? {
        for label in closeLabels {
            guard let range = button.range(of: " \(label) ", options: .backwards) else { continue }
            let title = button[range.upperBound...].trimmingCharacters(in: .whitespaces)
            let said = button[..<range.lowerBound], bare = plain(title)
            if !title.isEmpty, said.contains(title) || (!bare.isEmpty && said.contains(bare)) { return title }
        }
        return nil
    }

    /// The worktrees in Orca's answer to `terminal.list` with its layouts: for each, its groups of tabs, each tab with the
    /// terminal it shows (its active leaf's pane), and which tab is active. Split panes may nest, and a worktree may hold
    /// more than one group: both are looked for at any depth.
    static func worktrees(_ listed: [String: Any]) -> [Worktree] {
        // Orca's terminals in no layout, by worktree id (two worktrees may share a folder): a worktree of orphans alone, which
        // no layout lists, is one more worktree with no tabs.
        var orphans: [String: (path: String, terminals: [[String: Any]])] = [:], order: [String] = []
        for t in listed["terminals"] as? [[String: Any]] ?? [] where t["orphaned"] as? Bool == true && t["handle"] is String {
            let id = t["worktreeId"] as? String ?? t["worktreePath"] as? String ?? ""
            if orphans[id] == nil { order.append(id) }
            orphans[id, default: (t["worktreePath"] as? String ?? "", [])].terminals.append(t)
        }
        func terminals(_ id: String, _ name: String) -> [Terminal] {
            (orphans[id]?.terminals ?? []).map {
                Terminal(handle: $0["handle"] as? String ?? "", pane: $0["recordedPaneKey"] as? String ?? "", tab: "", title: "", worktree: name)
            }
        }
        let layouts = listed["visualLayouts"] as? [[String: Any]] ?? []
        let laid = Set(layouts.map { $0["worktreeId"] as? String ?? $0["worktreePath"] as? String ?? "" })
        let alone = order.filter { !laid.contains($0) }.map { id -> Worktree in
            let name = ((orphans[id]?.path ?? "") as NSString).lastPathComponent
            return Worktree(name: name, groups: [], orphans: terminals(id, name))
        }
        return layouts.map { layout -> Worktree in
            let name = ((layout["worktreePath"] as? String ?? "") as NSString).lastPathComponent
            let id = layout["worktreeId"] as? String ?? layout["worktreePath"] as? String ?? ""
            let groups = all(layout["root"], where: { $0["tabs"] is [Any] }).map { group -> Group in
                let tabs = (group["tabs"] as? [[String: Any]] ?? []).map { tab -> Tab in
                    let title = tab["title"] as? String ?? ""
                    guard let id = tab["tabId"] as? String, let leaf = tab["activeLeafId"] as? String,
                        let pane = all(tab["panes"], where: { $0["handle"] is String }).first(where: { $0["leafId"] as? String == leaf }),
                        let handle = pane["handle"] as? String
                    else { return Tab(title: title, terminal: nil) }
                    return Tab(
                        title: title,
                        terminal: Terminal(
                            handle: handle, pane: "\(pane["tabId"] as? String ?? id):\(leaf)", tab: title, title: pane["title"] as? String ?? "",
                            worktree: name))
                }
                let active = (group["tabs"] as? [[String: Any]] ?? []).firstIndex { $0["tabId"] as? String == group["activeTabId"] as? String }
                return Group(tabs: tabs, active: active)
            }
            return Worktree(name: name, groups: groups, orphans: terminals(id, name))
        } + alone
    }

    /// The terminals on show in Orca: in each worktree, of each group of tabs, the active leaf of the active tab.
    static func shown(_ listed: [String: Any]) -> [Terminal] { worktrees(listed).flatMap { $0.groups.compactMap(\.shown) } }

    private static func all(_ value: Any?, where wanted: ([String: Any]) -> Bool) -> [[String: Any]] {
        if let dict = value as? [String: Any] {
            return wanted(dict) ? [dict] : dict.values.flatMap { all($0, where: wanted) }
        }
        return (value as? [Any])?.flatMap { all($0, where: wanted) } ?? []
    }

    /// A title without what a terminal puts in front of it while it works (Claude Code's ✳, a spinner) and the spaces round it.
    static func plain(_ title: String) -> String {
        String(title.drop { !$0.isLetter && !$0.isNumber }).trimmingCharacters(in: .whitespaces)
    }

    /// Which terminal the bar's tabs are: the worktree whose tabs have just those titles, as many of each, in any order; else
    /// the one worktree that has them all and more (a pinned tab has no close button, so the bar never reads it). Of several
    /// that fit, the one whose active tab by Orca's list is the one the bar shows as active, if only one is. Several still,
    /// or one split into groups (the bar does not say which group the user types in), are no match: a light on the wrong pet is
    /// worse than none.
    /// No worktree with all the bar's tabs: see `pick`'s fallback (a worktree with some of them, or the orphan the user looks at).
    static func match(_ bar: [BarTab], _ worktrees: [Worktree]) -> Match { pick(bar, worktrees).match }

    /// `match`, and whether the answer leans on Orca's list for which of several tabs is active: the bar did not tell. Then
    /// the list must be fresh, as it can lag a switch.
    /// `subset`: no worktree has all the bar's tabs, and the answer is the one worktree that has some of them and no others,
    /// the rest being tabs Orca lays out nowhere (an `orphan` answer is that too, or no worktree at all). Only when the bar
    /// tells its active tab: Orca's list cannot say a tab it does not lay out is shown.
    static func pick(_ bar: [BarTab], _ worktrees: [Worktree]) -> (match: Match, byList: Bool, subset: Bool) {
        func counted(_ titles: [String]) -> [String: Int] {
            titles.map(plain).filter { !$0.isEmpty }.reduce(into: [:]) { $0[$1, default: 0] += 1 }
        }
        let wanted = counted(bar.map(\.title))
        guard !wanted.isEmpty else { return (.none, false, false) }
        let shownActive = active(in: bar).map(plain)
        let have = worktrees.map { (worktree: $0, titles: counted($0.groups.flatMap(\.titles))) }
        let equal = have.filter { $0.titles == wanted }.map(\.worktree)
        let more = have.filter { w in wanted.allSatisfy { w.titles[$0.key, default: 0] >= $0.value } }.map(\.worktree)
        var fits = equal.isEmpty ? more : equal
        func agreeing(_ fits: [Worktree]) -> [Worktree] {
            guard fits.count > 1, let shownActive else { return fits }
            let agree = fits.filter { $0.groups.count == 1 && $0.groups[0].shown.map { plain($0.tab) } == shownActive }
            return agree.count == 1 ? agree : fits
        }
        fits = agreeing(fits)
        // No worktree has all the bar's tabs: the bar may hold tabs Orca lays out nowhere (orphans). Then the one worktree
        // whose laid-out tabs are some of the bar's; and when the active tab is not one of them, the orphan it is.
        func fallback() -> (match: Match, byList: Bool, subset: Bool) {
            guard let shownActive, !shownActive.isEmpty else { return (.none, false, false) }
            // Its orphans must be able to be the bar's tabs it does not lay out: else the bar is likely another worktree's,
            // all orphaned by a restart, that shares a title ("claude") with this one.
            let total = wanted.values.reduce(0, +)
            func extra(_ titles: [String: Int]) -> Int { total - titles.values.reduce(0, +) }
            let fewer = agreeing(have.filter { w in
                !w.titles.isEmpty && w.titles.allSatisfy { wanted[$0.key, default: 0] >= $0.value } && extra(w.titles) <= w.worktree.orphans.count
            }.map(\.worktree))
            let laidOut = have.contains { $0.titles[shownActive] != nil }
            let everyOrphan = worktrees.flatMap(\.orphans)
            // No one worktree to go by: the session of the active tab's name, if exactly one open session has it.
            // Tab bars can keep tabs of sessions that are gone (duplicates, the off-duty) while Orca has no orphans
            // for them, so no worktree would pass and only worktrees with clean bars would be lit.
            guard fewer.count == 1, let w = fewer.first else {
                return (.orphan(title: shownActive, sure: nil, among: everyOrphan), false, true)
            }
            guard w.groups.count == 1 else { return (.split(w.groups.count), false, false) }
            let named = w.groups[0].tabs.filter { plain($0.title) == shownActive }
            if named.count == 1 { return (named[0].terminal.map { .one($0) } ?? .none, false, true) }
            guard !laidOut else { return (.none, false, false) }
            let sure = extra(counted(w.groups.flatMap(\.titles))) == 1 && w.orphans.count == 1
                ? w.orphans.first.map { Terminal(handle: $0.handle, pane: $0.pane, tab: shownActive, title: "", worktree: w.name) } : nil
            return (.orphan(title: shownActive, sure: sure, among: w.orphans.isEmpty ? everyOrphan : w.orphans), false, true)
        }
        guard let w = fits.first else { return fallback() }
        guard fits.count == 1 else { return (.several(fits.count), false, false) }
        guard w.groups.count == 1 else { return (.split(w.groups.count), false, false) }
        let group = w.groups[0]
        // The tab the bar shows as active, when the worktree has only one of that title; else the one Orca's list says.
        if let shownActive {
            let named = group.tabs.filter { plain($0.title) == shownActive }
            if named.count == 1 { return (named[0].terminal.map { .one($0) } ?? .none, false, false) }
        }
        return (group.shown.map { .one($0) } ?? .none, group.tabs.count > 1, false)
    }

    /// One line at launch: whether the panel may read Orca. Then only a change of that is told.
    func launched() {
        let now = trusted()
        known = now
        note(now ? "focus: Accessibility allowed: the office lights the session in the tab Orca shows"
                 : "focus: Accessibility not allowed: no light until it is granted (menu bar: Spotlight)")
    }

    /// Whether the panel may read Orca, asked on the tick while Orca is in front.
    func allowed() -> Bool {
        let now = trusted()
        if let known, known != now { note(now ? "focus: Accessibility granted" : "focus: Accessibility withdrawn") }
        known = now
        return now
    }

    /// Takes Orca's tab bar to the session in the terminal it shows, off the main thread: Orca's page opened to readers the
    /// first time, the bar found once and then only read, Orca's layouts asked for, and `ps` for a session not looked up
    /// before. The answer comes back on the main thread. While one look is under way the next is skipped.
    func resolve(
        _ pid: pid_t, among sessions: [(id: String, pid: Int32, name: String)], now: Date, then done: @escaping (Found) -> Void
    ) {
        guard !busy else { return }
        let fresh = stirred
        stirred = false
        guard let queue else { return done(find(pid, among: sessions, now: now, fresh: fresh)) }
        busy = true
        queue.async {
            let found = self.find(pid, among: sessions, now: now, fresh: fresh)
            DispatchQueue.main.async {
                self.busy = false
                done(found)
            }
        }
    }

    /// The light switched off, or the panel quitting: Orca's page is closed to readers again if the panel opened it, and Orca
    /// is no longer watched; switched on again, the next look opens it again. At quit there is no later, so it waits up to
    /// `waiting` seconds for that, and no more: best effort.
    func switchOff(waiting: Double = 0) {
        let done = DispatchSemaphore(value: 0)
        let work = {
            if let pid = self.opened { self.note("focus: Orca (pid \(pid)) closed to readers again: \(self.enhance(pid, false))") }
            self.unwatch()
            self.opened = nil
            self.bars = []
            done.signal()
        }
        guard let queue else { return work() }
        queue.async(execute: work)
        if waiting > 0 { _ = done.wait(timeout: .now() + waiting) }
    }

    /// Orca tells of a change (the observer, on the main thread): the store's look, a quarter of a second later, once for a
    /// burst of them, with Orca's list asked for afresh. The first of each kind is logged, so whether Electron tells at all
    /// shows in the log.
    func noticed(_ what: String) {
        if heard.insert(what).inserted { note("focus: Orca tells of \(what): the light follows at once, not only on the tick") }
        stirred = true
        guard !nudging else { return }
        nudging = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.nudging = false
            Task { @MainActor in self.nudge() }
        }
    }

    /// A new Orca, or the first: its page opened to readers and watched; what was found in another is let go.
    private func open(_ pid: pid_t) {
        unwatch()
        opened = pid
        bars = []
        nextLook = .distantPast
        barTold = false
        missTold = false
        note("focus: Orca (pid \(pid)) opened to readers: \(enhance(pid, true))")
        let watched = watch(pid, self)
        observer = watched.observer
        note("focus: Orca watched for focus and title changes: \(watched.said)")
    }

    private func unwatch() {
        if let observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode) }
        observer = nil
    }

    /// Looks for the bar in Orca's window. A look that finds none is not made again for 10 s, and Orca's page is opened to
    /// readers once more meanwhile, in case something (a probe, VoiceOver going off) closed it.
    private func look(_ pid: pid_t, _ now: Date) -> (count: Int, ms: Double) {
        let start = CACurrentMediaTime()
        let found = findBar(pid)
        let ms = (CACurrentMediaTime() - start) * 1000
        bars = found.bars
        nextLook = bars.isEmpty ? now + 10 : .distantPast
        if bars.isEmpty {
            if !missTold {
                missTold = true
                note(String(format: "focus: no tab bar in Orca's window (%d elements looked at in %.0f ms); looked for every 10 s", found.looked, ms))
            }
            _ = enhance(pid, true)
        }
        return (found.looked, ms)
    }

    /// The bar read, timed: the first read is logged with how long it took, and any over 50 ms that is the slowest yet.
    private func timedRead() -> Bar {
        let start = CACurrentMediaTime()
        let bar = readBar(bars)
        let took = CACurrentMediaTime() - start
        if !readOnce || took > slowest {
            note(String(format: "focus: Orca's tab bar read in %.2f ms%@", took * 1000, readOnce ? " (the slowest yet)" : ""))
            readOnce = true
            slowest = max(slowest, took)
        }
        return bar
    }

    private func refresh(_ now: Date) {
        listed = now
        if let answer = list() { worktrees = Self.worktrees(answer) }
    }

    private func find(_ pid: pid_t, among sessions: [(id: String, pid: Int32, name: String)], now: Date, fresh: Bool) -> Found {
        if opened != pid { open(pid) }
        var bar = bars.isEmpty ? Bar.gone : timedRead()
        var looked: (count: Int, ms: Double)?
        // Lost (another worktree shown) or never found: looked for at once, unless the last look found none.
        if bar == .gone || bar == .tabs([]) {
            bars = []
            guard now >= nextLook else { return .nothing }
            looked = look(pid, now)
            guard !bars.isEmpty else { return .nothing }
            bar = timedRead()
            if bar == .gone || bar == .tabs([]) {
                bars = []
                nextLook = now + 10
            }
        }
        // A bar that does not answer keeps the light where it is; said once when that starts and once when it ends, so a
        // light that seems stuck can be told from one that is not read.
        if bar == .failed {
            if unanswered == 0 { note("focus: Orca's tab bar gave no answer: the light stays where it is until it does") }
            unanswered += 1
            return .nothing
        }
        if unanswered > 0 {
            note("focus: Orca's tab bar answers again, after \(unanswered) look\(unanswered == 1 ? "" : "s") without")
            unanswered = 0
        }
        guard case .tabs(let tabs) = bar, !tabs.isEmpty else { return .nothing }
        if let looked, !barTold {
            barTold = true
            note(String(format: "focus: tab bar found (%d tabs) among %d elements in %.0f ms", tabs.count, looked.count, looked.ms))
        }
        if tabs != lastBar {
            lastBar = tabs
            barSince = now
        }
        // Orca's own record of a switch can lag behind its screen: a list asked for before the bar had been as it is for a
        // second is asked for again, and any list once it is 10 s old.
        if now.timeIntervalSince(listed) >= 10 || listed < barSince + 1 { refresh(now) }
        // When Orca told of a change, or the answer leans on the list for which of several tabs is active, a list over a
        // second old is not good enough: it may still show the tab the user has just left.
        var (match, byList, subset) = Self.pick(tabs, worktrees)
        if fresh || byList, now.timeIntervalSince(listed) >= 1 {
            refresh(now)
            (match, byList, subset) = Self.pick(tabs, worktrees)
        }
        let names = "[" + tabs.map { "\"\($0.title)\"" }.joined(separator: ", ") + "]"
        let barKey = tabs.map(\.title).sorted().joined(separator: "\n")
        // The handle a session was started with can go stale (`switchToTab`); its tab and pane ids do not.
        var byKey: [String: (terminal: String, pane: String)?] = [:]
        for s in sessions {
            let key = "\(s.id) \(s.pid)"
            byKey.updateValue(started[key] ?? tab(s.pid), forKey: key)  // nil too: not from Orca, and `ps` is not asked again
        }
        started = byKey
        var seen: [String: Set<String>] = [:]
        for s in sessions { seen[s.id] = (namesSeen[s.id] ?? []).union([Self.plain(s.name)]) }
        namesSeen = seen
        func runs(_ s: (id: String, pid: Int32, name: String), in t: Terminal) -> Bool {
            byKey["\(s.id) \(s.pid)"].flatMap { $0 }.map { $0.terminal == t.handle || (!t.pane.isEmpty && $0.pane == t.pane) } ?? false
        }
        // The active tab is one Orca lays out nowhere: the session in that very terminal when it is certain which; else the
        // one open session of that name among those in its orphans; else the one open session of that name. Logged once.
        if case .orphan(let title, let sure, let among) = match {
            // By the name it has now; else by a name it had before (a `/rename` the tab has not followed).
            let current = sessions.filter { Self.plain($0.name) == title }
            let named = current.isEmpty ? sessions.filter { namesSeen[$0.id]?.contains(title) == true } : current
            let bySure = sure.map { t in sessions.filter { runs($0, in: t) } } ?? []
            let inOrphans = named.filter { s in among.contains { runs(s, in: $0) } }
            let (lit, how): ((id: String, pid: Int32, name: String)?, String) =
                bySure.count == 1 ? (bySure[0], "by its terminal's handle")
                : inOrphans.count == 1 ? (inOrphans[0], "by its name, among the sessions in Orca's orphaned terminals")
                : named.count == 1 ? (named[0], "by its name") : (nil, "")
            guard let lit else {
                if told.insert(barKey).inserted {
                    note("focus: no match for tabs \(names) (the active tab \"\(title)\" is in no layout of Orca's, and no one open session is it)")
                }
                return .nothing
            }
            if fellBack.insert("orphan " + barKey).inserted {
                note("focus: tabs \(names): the active tab \"\(title)\" is in no layout of Orca's (an orphaned terminal); found \(how)")
            }
            tell("focus: now \(lit.name) (tab \"\(title)\", orphaned\(sure.map { " in \($0.worktree)" } ?? ""))", now)
            return .session(lit.id)
        }
        guard let hit = match.terminal else {
            if told.insert(barKey).inserted {
                switch match {
                case .several(let count): note("focus: no match for tabs \(names) (\(count) worktrees fit)")
                case .split(let count): note("focus: no match for tabs \(names) (their worktree is split into \(count) groups)")
                default: note("focus: no match for tabs \(names)")
                }
            }
            return .nothing
        }
        if subset, fellBack.insert("subset " + barKey).inserted {
            note("focus: tabs \(names): no worktree has them all; \(hit.worktree) has some of them and no others (the rest are in no layout of Orca's)")
        }
        let lit = sessions.first { runs($0, in: hit) }
        tell(lit.map { "focus: now \($0.name) (tab \"\(hit.tab)\" in \(hit.worktree))" } ?? "focus: none (tab \"\(hit.tab)\" in \(hit.worktree) runs no open session)", now)
        return lit.map { .session($0.id) } ?? .noSession
    }

    /// Each change of the light, in the log, so a switch that goes wrong can be followed: at most one line a second; a
    /// change it skips is told at the next look after that, if it still holds.
    private func tell(_ line: String, _ now: Date) {
        guard line != said, now.timeIntervalSince(saidAt) >= 1 else { return }
        said = line
        saidAt = now
        note(line)
    }
}

extension OfficeFocus.Match {
    var terminal: OfficeFocus.Terminal? {
        if case .one(let t) = self { return t }
        return nil
    }
}

/// For pictures, on a read-only store only: `--focus <name>` lights that session's pet as if the user were typing in it, Orca in
/// front. Nothing reads Orca for a picture.
@MainActor func officeFocus(_ store: Store, arguments: [String]) {
    guard store.readOnly, let i = arguments.firstIndex(of: "--focus"), i + 1 < arguments.count else { return }
    guard let s = store.sessions.first(where: { $0.name == arguments[i + 1] }) else {
        FileHandle.standardError.write(Data("no open session named \(arguments[i + 1]); the picture has no light\n".utf8))
        return
    }
    store.focused = s.id
    store.orcaInFront = true
}

/// `--focus-probe`: what Orca's Accessibility tree tells of where the user types, printed so the matcher can be built on it; the
/// title of Orca's focused window is just "Orca". No `Store` is made (its baseline alone would write a setting) and the
/// permission is never asked for. One thing in Orca is changed, for the length of the walk only: an Electron app builds its
/// web page's tree for a reader only once `AXManualAccessibility` is on, so the probe turns it on if it was off and back off
/// afterwards, leaving Orca as it found it (`--focus-probe-keep` leaves it on). Section 6 reads Orca's tab bar the way the
/// light does, with `OfficeFocus`'s own finder, reader and matcher, and says where it leads.
enum OfficeFocusProbe {
    private static let manual = "AXManualAccessibility"

    /// What is read of each element, in one message to Orca.
    private static let fields: [String] = [
        kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXIdentifierAttribute,
        kAXHelpAttribute, "AXDOMIdentifier", "AXDOMClassList", kAXSelectedAttribute, kAXFocusedAttribute, kAXChildrenAttribute,
    ]
    /// How an element's fields are shown, in this order.
    private static let labels: [(String, String)] = [
        (kAXRoleAttribute, "role"), (kAXSubroleAttribute, "subrole"), (kAXTitleAttribute, "title"), (kAXDescriptionAttribute, "desc"),
        (kAXValueAttribute, "value"), (kAXIdentifierAttribute, "id"), (kAXHelpAttribute, "help"), ("AXDOMIdentifier", "dom-id"),
        ("AXDOMClassList", "dom-class"),
    ]
    /// Shown in the walk wherever they are, whatever they say.
    private static let roles: Set<String> = ["AXTabGroup", "AXTab", "AXRadioButton", "AXRadioGroup", "AXList"]
    /// Shown in the walk when they say what one of Orca's terminals is called.
    private static let texts: Set<String> = ["AXStaticText", "AXHeading", "AXButton"]

    /// An element as read: the fields it has, the error for each it has not, its children; or why none could be read.
    private struct Element {
        var values: [String: CFTypeRef] = [:]
        var errors: [String: Int32] = [:]
        var children: [AXUIElement] = []
        var failed: Int32?

        func text(_ name: String) -> String? { values[name].map(OfficeFocusProbe.describe) }
        func flag(_ name: String) -> Bool { text(name) == "true" || text(name) == "1" }
    }

    /// An element in a set: one reached twice counts once.
    private struct Seen: Hashable {
        let element: AXUIElement
        static func == (a: Seen, b: Seen) -> Bool { CFEqual(a.element, b.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// Written at once, not buffered: a walk that hangs, or is stopped, still leaves all it found before.
    private static func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    /// `names` of an element, in one message, waiting at most 0.1 s: the timeout is per element, so each gets its own.
    private static func read(_ element: AXUIElement, _ names: [String] = fields) -> Element {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var answer: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(element, names as CFArray, [], &answer)
        var read = Element()
        guard error == .success, let values = answer as? [AnyObject] else {
            read.failed = error.rawValue
            return read
        }
        for (name, value) in zip(names, values) {
            if CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetType(value as! AXValue) == .axError {
                var code: Int32 = 0
                AXValueGetValue(value as! AXValue, .axError, &code)
                read.errors[name] = code
            } else if name == kAXChildrenAttribute {
                read.children = ((value as? [AnyObject]) ?? []).filter { CFGetTypeID($0) == AXUIElementGetTypeID() }.map { $0 as! AXUIElement }
            } else {
                read.values[name] = value
            }
        }
        return read
    }

    /// One attribute, with the error when it is not there.
    private static func copy(_ element: AXUIElement, _ name: String) -> (value: CFTypeRef?, error: Int32) {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (error == .success ? value : nil, error.rawValue)
    }

    /// The element an attribute points to, if it does.
    private static func element(_ found: (value: CFTypeRef?, error: Int32)) -> AXUIElement? {
        guard let value = found.value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    /// Every attribute an element says it has: whether it has DOM ids and classes, and what else is there.
    private static func names(of element: AXUIElement) -> String {
        AXUIElementSetMessagingTimeout(element, 0.1)
        var names: CFArray?
        let error = AXUIElementCopyAttributeNames(element, &names)
        guard error == .success, let list = names as? [String] else { return "(AXError \(error.rawValue))" }
        return list.joined(separator: " ")
    }

    private static func describe(_ value: CFTypeRef) -> String {
        let type = CFGetTypeID(value)
        if type == AXUIElementGetTypeID() { return "<element>" }
        if type == CFBooleanGetTypeID() { return CFBooleanGetValue((value as! CFBoolean)) ? "true" : "false" }
        if type == AXValueGetTypeID() { return String(describing: value) }
        if value is NSNull { return "" }
        if let text = value as? String { return text }
        if let text = value as? NSAttributedString { return text.string }
        if let url = value as? URL { return url.absoluteString }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [AnyObject] { return "[" + list.map(describe).joined(separator: ", ") + "]" }
        return String(describing: value)
    }

    /// On one line, cut to `most` characters, saying how long it was.
    private static func clip(_ text: String, _ most: Int = 200) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎")
        return flat.count > most ? String(flat.prefix(most)) + "…(\(flat.count) chars)" : flat
    }

    /// An element on one line: the fields it has, each cut to 200 characters, and whether it is selected or focused.
    private static func line(_ e: Element) -> String {
        if let failed = e.failed { return "(unreadable: AXError \(failed))" }
        var parts: [String] = []
        for (name, label) in labels {
            guard let text = e.text(name), !text.isEmpty else { continue }
            parts.append(name == kAXRoleAttribute || name == kAXSubroleAttribute ? "\(label)=\(text)" : "\(label)=\"\(clip(text))\"")
        }
        if e.flag(kAXSelectedAttribute) { parts.append("SELECTED") }
        if e.flag(kAXFocusedAttribute) { parts.append("FOCUSED") }
        return parts.isEmpty ? "(no fields)" : parts.joined(separator: " ")
    }

    /// An element field by field, with the error for each it has not: absent (-25212) and unsupported (-25205) differ.
    private static func block(_ e: Element, _ shown: [(String, String)]) {
        if let failed = e.failed { return say("  (unreadable: AXError \(failed))") }
        for (name, label) in shown {
            if let text = e.text(name) {
                say("  \(label): \"\(clip(text))\"")
            } else {
                say("  \(label): (AXError \(e.errors[name].map { String($0) } ?? "?"))")
            }
        }
    }

    /// The roles from the window down, a run of the same one counted: "AXWindow > AXGroup×4 > AXWebArea".
    private static func path(_ roles: [String]) -> String {
        var runs: [(role: String, count: Int)] = []
        for role in roles {
            if runs.last?.role == role { runs[runs.count - 1].count += 1 } else { runs.append((role, 1)) }
        }
        return runs.map { $0.count > 1 ? "\($0.role)×\($0.count)" : $0.role }.joined(separator: " > ")
    }

    /// Every title Orca gives a terminal, a tab or a pane, without what a busy terminal puts in front; the longest first.
    private static func titles(_ listed: [String: Any]) -> [String] {
        var found = Set<String>()
        func walk(_ value: Any?) {
            if let dict = value as? [String: Any] {
                if let title = dict["title"] as? String { found.insert(OfficeFocus.plain(title)) }
                dict.values.forEach(walk)
            } else if let list = value as? [Any] {
                list.forEach(walk)
            }
        }
        walk(listed["terminals"])
        walk(listed["visualLayouts"])
        return found.filter { $0.count >= 2 }.sorted { ($0.count, $0) > ($1.count, $1) }
    }

    /// The terminal title an element's title, description or value says, or that holds its whole text.
    private static func said(by e: Element, among titles: [String]) -> String? {
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard let text = e.text(name).map(OfficeFocus.plain), !text.isEmpty else { continue }
            if let hit = titles.first(where: { text.contains($0) || (text.count >= 3 && $0.contains(text)) }) { return hit }
        }
        return nil
    }

    @MainActor static func run(keep: Bool) {
        let trusted = AXIsProcessTrusted()
        let front = NSWorkspace.shared.frontmostApplication
        let orca = NSRunningApplication.runningApplications(withBundleIdentifier: OfficeFocus.orca).first
        say("── 1. this process, the frontmost app, Orca")
        say("AXIsProcessTrusted: \(trusted)  (pid \(getpid()), \(CommandLine.arguments[0]))")
        say("  started from a shell, this is the permission of the terminal app the shell runs in")
        say("frontmost: \(front?.bundleIdentifier ?? "?") \"\(front?.localizedName ?? "?")\" pid \(front?.processIdentifier ?? 0)")
        say("Orca: " + (orca.map { "pid \($0.processIdentifier)\($0.isActive ? " (active)" : "")" } ?? "not running"))

        let listed = orcaCall("terminal.list", ["includeVisualLayouts": true])?["result"] as? [String: Any]
        let wanted = listed.map(titles) ?? []
        var bar: (lines: [String], tabs: [OfficeFocus.BarTab]?) =
            (["  skipped: " + (trusted ? "Orca is not running" : "no Accessibility permission")], nil)
        if let orca, trusted {
            let app = AXUIElementCreateApplication(orca.processIdentifier)
            let switched = switchOn(app)
            probe(app, wanted)
            bar = tabBar(orca.processIdentifier)  // while Orca's page is still open to readers
            switchBack(app, switched, keep: keep)
        } else {
            say("── 2-4 skipped: " + (trusted ? "Orca is not running" : "this process may not read other apps (no Accessibility permission)"))
        }

        say("── 5. terminal.list: the pane on show in each worktree (worktree → tab → pane → handle)")
        if let listed {
            let shown = OfficeFocus.shown(listed)
            if shown.isEmpty { say("  none") }
            for t in shown {
                say("  \(t.worktree) → tab \"\(t.tab)\" → pane \"\(t.title)\" → \(t.handle)  (pane key \(t.pane))")
            }
            say("  titles looked for in 4 (\(wanted.count)): " + wanted.map { "\"\($0)\"" }.joined(separator: ", "))
        } else {
            say("  no answer from Orca's socket")
        }

        say("── 6. Orca's tab bar as the light reads it, and where it leads (worktree → tab → pane → handle)")
        bar.lines.forEach(say)
        guard let listed else { return say("  no answer from Orca's socket: nothing to match the tabs to") }
        let worktrees = OfficeFocus.worktrees(listed)
        for w in worktrees {
            let groups = w.groups.map { g in
                "[" + g.titles.map { "\"\($0)\"" }.joined(separator: ", ") + "] showing " + (g.shown.map { "\"\($0.tab)\"" } ?? "nothing")
            }
            say("  worktree \(w.name): " + groups.joined(separator: " | "))
        }
        guard let tabs = bar.tabs else { return }
        say("  active by the bar: " + (OfficeFocus.active(in: tabs).map { "\"\($0)\"" } ?? "none told; Orca's list decides"))
        switch OfficeFocus.match(tabs, worktrees) {
        case .one(let t): say("  resolved: \(t.worktree) → tab \"\(t.tab)\" → pane \"\(t.title)\" → \(t.handle)  (pane key \(t.pane))")
        case .none: say("  resolved: no worktree has these tabs")
        case .several(let count): say("  resolved: none, \(count) worktrees have these tabs")
        case .split(let count): say("  resolved: none, their worktree is split into \(count) groups of tabs")
        case .orphan(let title, let sure, let among):
            say("  resolved: the active tab \"\(title)\" is in no layout: " + (sure.map { "orphaned terminal \($0.handle) in \($0.worktree)" }
                ?? "one of \(among.count) orphaned terminals, the session by its name"))
        }
    }

    /// Section 6's reading, made while Orca's page is open: the tab bar found and read with the light's own finder and
    /// reader, every button the reader met with its title as Orca gives it and what it says of itself (selected, focused,
    /// value, its page's classes: what could tell the active tab), and the tabs read from them.
    private static func tabBar(_ pid: pid_t) -> (lines: [String], tabs: [OfficeFocus.BarTab]?) {
        var lines: [String] = []
        let start = CACurrentMediaTime()
        let found = OfficeFocus.findBar(in: pid)
        lines.append(
            String(format: "  looked for: %d bar(s) among %d elements in %.1f ms", found.bars.count, found.looked, (CACurrentMediaTime() - start) * 1000))
        guard !found.bars.isEmpty else { return (lines + ["  no tab bar found"], nil) }
        var buttons: [OfficeFocus.Element<AXUIElement>] = []
        let began = CACurrentMediaTime()
        let bar = OfficeFocus.tabs(in: found.bars) { e in
            let read = OfficeFocus.element(e, full: true)
            if read.role == kAXButtonRole { buttons.append(read) }
            return read
        }
        lines.append(String(format: "  read in %.1f ms, %d buttons:", (CACurrentMediaTime() - began) * 1000, buttons.count))
        for b in buttons {
            lines.append("    \"\(clip(b.title))\" → " + (OfficeFocus.tabTitle(of: b.title).map { "tab \"\($0)\"" } ?? "not a tab"))
            lines.append("      selected=\(b.selected) focused=\(b.focused) value=\"\(clip(b.value))\" dom-class=" + clip("[" + b.classes.joined(separator: ", ") + "]", 600))
        }
        guard case .tabs(let tabs) = bar else { return (lines + ["  the bar could not be read: \(bar)"], nil) }
        lines.append("  tabs: " + tabs.map { "\"\($0.title)\"" + ($0.depth > 1 ? " (docked, \($0.depth) levels down)" : "") }.joined(separator: ", "))
        return (lines, tabs)
    }

    /// Turns on Orca's web tree for readers if it is not on, and gives it 2.5 s to build. Whether it was turned on here.
    private static func switchOn(_ app: AXUIElement) -> Bool {
        say("── 1b. Orca's web tree for readers (\(manual), AXEnhancedUserInterface)")
        let before = copy(app, manual), enhancedBefore = copy(app, "AXEnhancedUserInterface")
        let was = before.value.map(describe), wasEnhanced = enhancedBefore.value.map(describe)
        say("  before: \(manual)=" + (was ?? "(AXError \(before.error))")
            + " AXEnhancedUserInterface=" + (wasEnhanced ?? "(AXError \(enhancedBefore.error))"))
        // The panel's light keeps Orca's page open with the second while it is on: turning it off afterwards would put the
        // running panel's light out.
        guard was != "true", wasEnhanced != "true" else {
            say("  already on: left as it is")
            return false
        }
        let set = AXUIElementSetAttributeValue(app, manual as CFString, kCFBooleanTrue)
        say("  set to true: AXError \(set.rawValue)\(set == .success ? " (success)" : "")")
        // Chromium itself listens for the attribute VoiceOver sets, not only Electron's; try that one too.
        let enhanced = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        say("  AXEnhancedUserInterface set to true: AXError \(enhanced.rawValue)\(enhanced == .success ? " (success)" : "")")
        guard set == .success || enhanced == .success else { return false }
        Thread.sleep(forTimeInterval: 2.5)
        let after = copy(app, manual), afterEnhanced = copy(app, "AXEnhancedUserInterface")
        say("  after 2.5 s: \(manual)=" + (after.value.map(describe) ?? "(AXError \(after.error))")
            + " AXEnhancedUserInterface=" + (afterEnhanced.value.map(describe) ?? "(AXError \(afterEnhanced.error))"))
        return true
    }

    /// Leaves Orca as the probe found it: what it turned on goes off again, unless asked to keep it.
    private static func switchBack(_ app: AXUIElement, _ switched: Bool, keep: Bool) {
        guard switched else { return }
        say("── 4b. Orca's web tree for readers, put back")
        guard !keep else { return say("  left on (--focus-probe-keep): \(manual) stays true") }
        let set = AXUIElementSetAttributeValue(app, manual as CFString, kCFBooleanFalse)
        _ = AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        let now = copy(app, manual)
        say("  set to false: AXError \(set.rawValue)\(set == .success ? " (success)" : ""); now: " + (now.value.map(describe) ?? "(AXError \(now.error))"))
    }

    private static func probe(_ app: AXUIElement, _ titles: [String]) {
        say("── 2. Orca's focused window")
        say("  app attributes: \(names(of: app))")
        for name in [manual, "AXEnhancedUserInterface"] {
            let found = copy(app, name)
            say("  app \(name): " + (found.value.map(describe) ?? "(AXError \(found.error))"))
        }
        let focusedWindow = copy(app, kAXFocusedWindowAttribute)
        guard let window = element(focusedWindow) else { return say("  no focused window (AXError \(focusedWindow.error))") }
        block(
            read(window, [kAXTitleAttribute, kAXRoleAttribute, kAXSubroleAttribute, kAXDescriptionAttribute, kAXDocumentAttribute,
                          kAXIdentifierAttribute]),
            [(kAXTitleAttribute, "title"), (kAXRoleAttribute, "role"), (kAXSubroleAttribute, "subrole"), (kAXDescriptionAttribute, "desc"),
             (kAXDocumentAttribute, "document"), (kAXIdentifierAttribute, "id")])
        say("  attributes: \(names(of: window))")

        // The chain above an element, each level with the same fields; also used for the focused one the walk finds.
        func ancestors(of start: AXUIElement) {
            var current = start
            var level = 1
            while true {
                let up = copy(current, kAXParentAttribute)
                guard let parent = element(up) else {
                    say("  ↑\(level) no parent (AXError \(up.error))")
                    break
                }
                let p = read(parent, Array(fields.dropLast()))
                let role = p.text(kAXRoleAttribute) ?? ""
                say("  ↑\(level) " + line(p) + (CFEqual(parent, window) ? "  (the focused window)" : ""))
                if CFEqual(parent, window) || role == kAXWindowRole || role == kAXApplicationRole { break }
                if level == 40 {
                    say("  stopped at 40 levels")
                    break
                }
                current = parent
                level += 1
            }
        }
        say("── 3. Orca's focused element, then its ancestors up to the window")
        let focusedElement = copy(app, kAXFocusedUIElementAttribute)
        if let focused = element(focusedElement) {
            let e = read(focused)
            block(e, labels + [(kAXSelectedAttribute, "selected"), (kAXFocusedAttribute, "focused")])
            say("  children: \(e.children.count)")
            say("  attributes: \(names(of: focused))")
            ancestors(of: focused)
        } else {
            say("  no focused element (AXError \(focusedElement.error))")
        }

        say("── 4. the focused window's elements, breadth first (at most 4000 elements, 25 deep, 60 s)")
        say("  shown: roles \(roles.sorted().joined(separator: " ")), titled AXGroup; \(texts.sorted().joined(separator: " ")) naming a terminal; selected or focused")
        let start = CACurrentMediaTime()
        let top = read(window, [kAXChildrenAttribute])
        if let failed = top.failed { say("  the window's children: AXError \(failed)") }
        var queue = top.children.map { (element: $0, depth: 1, above: [kAXWindowRole]) }
        var seen: Set<Seen> = [Seen(element: window)]
        var head = 0, visited = 0, deepest = 0, shown = 0, unreadable = 0, cut = 0
        var end = "the whole window was walked"
        while head < queue.count {
            if visited == 4000 {
                end = "stopped at 4000 elements"
                break
            }
            if CACurrentMediaTime() - start > 60 {
                end = "stopped after 60 s"
                break
            }
            let (element, depth, above) = queue[head]
            head += 1
            guard seen.insert(Seen(element: element)).inserted else { continue }
            visited += 1
            deepest = max(deepest, depth)
            let e = read(element)
            if e.failed != nil { unreadable += 1 }
            let role = e.text(kAXRoleAttribute) ?? "?"
            let here = above + [role]
            var why: [String] = []
            if roles.contains(role) || (role == kAXGroupRole && !(e.text(kAXTitleAttribute) ?? "").isEmpty) { why.append("role") }
            if e.flag(kAXSelectedAttribute) { why.append("selected") }
            if e.flag(kAXFocusedAttribute) { why.append("focused") }
            if texts.contains(role), let title = said(by: e, among: titles) { why.append("says \"\(title)\"") }
            if !why.isEmpty {
                shown += 1
                say("  d\(depth) [\(why.joined(separator: ", "))] " + line(e))
                say("      path: " + path(here))
                if why.contains("focused") { ancestors(of: element) }
            }
            if depth < 25 {
                queue += e.children.map { (element: $0, depth: depth + 1, above: here) }
            } else {
                cut += e.children.count
            }
        }
        say(
            String(
                format: "  %d elements visited (%d shown, %d unreadable), %d deep at most, %.2f s: ", visited, shown, unreadable, deepest,
                CACurrentMediaTime() - start) + end
                + (head < queue.count ? "; \(queue.count - head) more were queued" : "")
                + (cut > 0 ? "; \(cut) children below depth 25 not walked" : ""))
    }
}

// ───────── Pets at their true size ─────────

/// The board shrinks pet frames for its cards. The office needs them as they were drawn:
/// a sprite sheet's frames are 192x208 on a two-pixel grid, so each is halved to 96x104 with
/// hard edges. Cut once per pet, off the main thread, into the caches folder.
@MainActor final class OfficePets {
    /// A check swaps in one with a cache of its own (an empty one, to see the checks that need cut frames stand down).
    static var shared = OfficePets()

    struct Frame {
        let image: CGImage
        let left: Int, top: Int, right: Int, bottom: Int  // the drawn part, in the frame's pixels
        var tall: Int { bottom - top + 1 }
        var wide: Int { right - left + 1 }
    }

    /// Snapshots cut a pet's frames on the spot; the live office does it in the background.
    var synchronous = false
    /// Called on the main thread when a pet's frames have just become available.
    var onReady: (() -> Void)?
    /// Whose `onReady` it is: an office leaving must not silence the one that replaced it.
    weak var listener: AnyObject?
    /// The drawn part of each frame, by pet, row and column: small, so kept for good.
    private var boxes: [String: (left: Int, top: Int, right: Int, bottom: Int)] = [:]
    /// Frames as cut, and as scaled for the room. The walking and looping rows of thirty pets do not
    /// all fit in memory; whatever is pushed out is loaded or scaled again when next asked for.
    nonisolated static let cacheLimit = 48 * 1024 * 1024
    private let images = NSCache<NSString, CGImage>()
    /// Where each pet's frames are, once they are cut, and frames its sheet does not have.
    private var done: [String: String] = [:]
    private var absent = Set<String>()
    private var cutting = Set<String>()
    /// Sheets that could not be cut, by the folder they would go to (pet and file date). Not
    /// tried again until the file changes: each try would ask for a repaint that tries again.
    private var failed = Set<String>()
    /// Pets to cut ahead of time, one after another, and whether one is being cut for that now.
    private var queue: [String] = []
    private var preparing = false
    private let folder: String
    private let pools: [String]

    init(
        folder: String = cacheFolder + "/true-frames",
        pools: [String] = PetSources.outside,
        cacheLimit: Int = OfficePets.cacheLimit
    ) {
        self.folder = folder
        // SF: the built-in flame last: only a session dealt it (no pet installed) asks for it.
        self.pools = (Extensions.registered?.petRoots ?? []) + pools + PetSources.builtIn
        images.totalCostLimit = cacheLimit
    }

    /// How much the cache of frames may hold.
    var costLimit: Int { images.totalCostLimit }

    /// idle, running right and left, waving, jumping, waiting, running on the spot.
    nonisolated static let rows = [0, 1, 2, 3, 4, 6, 7]

    /// One frame of a pet, or nil while its frames are still being cut.
    func frame(_ pet: String, row: Int, column: Int) -> Frame? {
        let key = "\(pet)/\(row)-\(column)"
        if let box = boxes[key], let image = images.object(forKey: key as NSString) {
            return Frame(image: image, left: box.left, top: box.top, right: box.right, bottom: box.bottom)
        }
        guard let image = read(pet, row, column) else { return nil }
        if boxes[key] == nil {
            guard let box = Self.drawn(image) else { return nil }
            boxes[key] = box
        }
        images.setObject(image, forKey: key as NSString, cost: image.width * image.height * 4)
        return boxes[key].map { Frame(image: image, left: $0.left, top: $0.top, right: $0.right, bottom: $0.bottom) }
    }

    /// A frame as cut, from disk; nil while the pet is not cut, or when the sheet leaves this frame empty.
    private func read(_ pet: String, _ row: Int, _ column: Int) -> CGImage? {
        let key = "\(pet)/\(row)-\(column)"
        guard !absent.contains(key), let dir = folder(of: pet) else { return nil }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(row)-\(column).png") as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            absent.insert(key)  // the folder is there (it was just looked at), so the sheet leaves this frame empty
            return nil
        }
        return image
    }

    // ───────── Which way a pet runs ─────────
    //
    // The sheets are meant to have row 1 running to the right and row 2 to the left; community sheets do not all keep to it
    // (for example a pet whose row 1 runs left, its row 2 being some other move). `pet-facing.json` (reviewed pet by pet) says, for each pet
    // that does not, which row each way takes, `m` for that row mirrored. Every running or turning frame picked by direction,
    // in every scene, comes through `runFrame` / `scaledRun`, which apply it; a mirrored frame is made once and cached beside
    // the cut ones (in memory only: the frames on disk are as cut, so their cache keeps its format).

    /// The logical facings (the same numbers as the sheet's own convention, `ZoneWalk.right` / `.left`).
    nonisolated static let right = 1
    nonisolated static let left = 2

    /// Which row a pet runs in each way and whether mirrored, by pet; a pet not listed keeps the convention.
    static var facingTable: [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))] = loadFacing()

    /// `pet-facing.json` from the app's resources, beside the binary, or the source folder (checks, snapshots); then
    /// `pet-facing.private.json` from the same places, if there is one (an extension's own table: build.sh and test.sh put it
    /// there), whose pets replace the same pets in the first. `directories` is for the checks: where to look, in this order.
    static func loadFacing(directories: [String]? = nil) -> [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))] {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let places: [String] = directories ?? [
            Bundle.main.resourceURL?.path,
            exe.path,
            exe.deletingLastPathComponent().path,
            FileManager.default.currentDirectoryPath,
        ].compactMap { $0 }
        func table(_ name: String) -> [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))] {
            for place in places {
                if let data = FileManager.default.contents(atPath: place + "/" + name) { return parseFacing(data) }
            }
            return [:]
        }
        return mergeFacing(table("pet-facing.json"), over: table("pet-facing.private.json"))
    }

    /// The public table with the private one's pets laid over it (the same pet in both: the private entry).
    nonisolated static func mergeFacing(
        _ base: [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))], over extra: [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))]
    ) -> [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))] {
        base.merging(extra) { _, private_ in private_ }
    }

    /// The table's entries (`"1"`, `"1m"` …); keys starting with `_` are notes, a value it cannot read keeps the convention.
    nonisolated static func parseFacing(_ data: Data) -> [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        func cell(_ value: Any?, _ fallback: Int) -> (row: Int, mirrored: Bool) {
            guard var text = value as? String else { return (fallback, false) }
            let mirrored = text.hasSuffix("m")
            if mirrored { text.removeLast() }
            guard let row = Int(text), (0..<9).contains(row) else { return (fallback, false) }
            return (row, mirrored)
        }
        var table: [String: (right: (row: Int, mirrored: Bool), left: (row: Int, mirrored: Bool))] = [:]
        for (pet, value) in root where !pet.hasPrefix("_") {
            guard let entry = value as? [String: Any] else { continue }
            table[pet] = (cell(entry["right"], right), cell(entry["left"], left))
        }
        return table
    }

    /// The sheet's row (and whether mirrored) a pet runs in to the right (`right`) or the left (`left`); any other number
    /// (7, running on the spot) is that row as it is.
    static func runRow(_ pet: String, facing: Int) -> (row: Int, mirrored: Bool) {
        guard facing == right || facing == left else { return (facing, false) }
        guard let entry = facingTable[pet] else { return (facing, false) }
        return facing == right ? entry.right : entry.left
    }

    /// One running (or turned) frame of a pet the way it faces, from the table: mirrored where it says so, the mirrored
    /// image made once and kept with the cut frames.
    func runFrame(_ pet: String, facing: Int, column: Int) -> Frame? {
        let (row, mirrored) = Self.runRow(pet, facing: facing)
        guard mirrored else { return frame(pet, row: row, column: column) }
        let key = "\(pet)/\(row)m-\(column)"
        if let box = boxes[key], let image = images.object(forKey: key as NSString) {
            return Frame(image: image, left: box.left, top: box.top, right: box.right, bottom: box.bottom)
        }
        guard let base = frame(pet, row: row, column: column), let image = Self.mirrored(base.image) else { return nil }
        let w = base.image.width
        let box = (left: w - 1 - base.right, top: base.top, right: w - 1 - base.left, bottom: base.bottom)
        boxes[key] = box
        images.setObject(image, forKey: key as NSString, cost: image.width * image.height * 4)
        return Frame(image: image, left: box.left, top: box.top, right: box.right, bottom: box.bottom)
    }

    /// Running frames at `scale`, by facing (`right`, `left`, or 7 on the spot) and how many columns: the table applied, the
    /// mirrored ones made from the scaled frames once and kept. Handed over as `scaled(_:rows:)` hands its frames, keyed by
    /// the facing asked for.
    func scaledRun(_ pet: String, facings: [Int: Int], scale: CGFloat, _ ready: @escaping ([Int: [CGImage]]) -> Void) {
        var resolved: [Int: (row: Int, mirrored: Bool)] = [:], rows: [Int: Int] = [:]
        for (facing, count) in facings {
            let how = Self.runRow(pet, facing: facing)
            resolved[facing] = how
            rows[how.row] = max(rows[how.row] ?? 0, count)
        }
        scaled(pet, rows: rows, scale: scale) { [weak self] frames in
            guard let self else { return }
            var out: [Int: [CGImage]] = [:]
            for (facing, how) in resolved {
                let base = frames[how.row] ?? []
                out[facing] = how.mirrored ? base.enumerated().compactMap { self.mirroredScaled(pet, how.row, $0.offset, scale: scale, $0.element) } : base
            }
            ready(out)
        }
    }

    /// A scaled frame mirrored, kept beside it (made once).
    private func mirroredScaled(_ pet: String, _ row: Int, _ column: Int, scale: CGFloat, _ image: CGImage) -> CGImage? {
        let key = "\(pet)/\(row)m-\(column)@\(scale)" as NSString
        if let known = images.object(forKey: key) { return known }
        guard let made = Self.mirrored(image) else { return nil }
        images.setObject(made, forKey: key, cost: made.bytesPerRow * made.height)
        return made
    }

    /// An image flipped left to right.
    nonisolated static func mirrored(_ image: CGImage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .none
        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// The part of a frame that is drawn, in its pixels.
    private static func drawn(_ image: CGImage) -> (left: Int, top: Int, right: Int, bottom: Int)? {
        guard let pixels = pixels(of: image) else { return nil }
        var left = image.width, right = -1, top = image.height, bottom = -1
        for y in 0..<image.height {
            for x in 0..<image.width where pixels[(y * image.width + x) * 4 + 3] > 0 {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            }
        }
        return right >= left ? (left, top, right, bottom) : nil
    }

    /// The stills the office shows a pet in (`Pose.sheet`'s rows and still columns): standing, asleep, at work, waiting,
    /// jumping, waving.
    nonisolated static let stills = [(row: 0, column: 0), (0, 1), (7, 1), (6, 2), (6, 0), (4, 2), (3, 2)]

    /// The scale a pose of this drawn size is shown at in a place this tall: by how tall the pet stands idle (`idle`), or
    /// by the pose itself where it is drawn much smaller; at most 1.1 times as wide as the place is tall.
    nonisolated static func scale(_ pose: (tall: Int, wide: Int), idle: (tall: Int, wide: Int), tall: CGFloat) -> CGFloat {
        let small = pose.tall * 5 < idle.tall * 4
        let high = CGFloat(small ? pose.tall : idle.tall), broad = CGFloat(small ? pose.wide : idle.wide)
        return min(tall / high, tall * 1.1 / broad)
    }

    /// The share of `scale`'s size a pet is shown at in a place this tall: so that every still it shows stands at most 1.1
    /// times as tall as the place (what the rows are spaced for) and, with `wide`, is no wider than that (the next seat on a
    /// sofa or a couch). 1 for nearly every pet, and for one whose frames are not cut yet. The same share in every pose, so
    /// a pet keeps its size as its pose changes.
    func fit(_ pet: String, tall: CGFloat, wide: CGFloat?) -> CGFloat {
        let key = "\(pet) \(tall) \(wide ?? 0)"
        if let known = fits[key] { return known }
        func box(_ row: Int, _ column: Int) -> (tall: Int, wide: Int)? {
            let key = "\(pet)/\(row)-\(column)"
            if boxes[key] == nil, let image = read(pet, row, column) { boxes[key] = Self.drawn(image) }
            return boxes[key].map { ($0.bottom - $0.top + 1, $0.right - $0.left + 1) }
        }
        guard let idle = box(0, 0) else { return 1 }
        var share: CGFloat = 1
        for (row, column) in Self.stills {
            guard let pose = box(row, column) else { continue }
            let scale = Self.scale(pose, idle: idle, tall: tall)
            share = min(share, tall * 1.1 / (CGFloat(pose.tall) * scale))
            if let wide { share = min(share, wide / (CGFloat(pose.wide) * scale)) }
        }
        fits[key] = share
        return share
    }
    private var fits: [String: CGFloat] = [:]

    /// How far a pet reaches to either side when it walks, in its frames' pixels: the leftmost and the
    /// rightmost drawn column over the frames it stands in (shown on the way until its running frames are
    /// ready) and every frame it runs in (to the right, to the left, on the spot). Each frame is read once:
    /// what is drawn where is kept for good, and the frame itself is not kept, so as not to push the room's
    /// scaled frames out of the cache. Nil while its frames are not cut.
    func extent(_ pet: String, stills: [(row: Int, column: Int)]) -> (left: Int, right: Int)? {
        var left = Int.max, right = Int.min
        // The rows it runs in by the facing table, a mirrored one reaching as far the other way.
        let runs = [Self.right, Self.left].map { Self.runRow(pet, facing: $0) }
        let mirroredRows = Set(runs.filter(\.mirrored).map(\.row))
        let width = mirroredRows.isEmpty ? nil : read(pet, 0, 0)?.width
        let frames = stills + (Array(Set(runs.map(\.row))).sorted() + [7]).flatMap { row in (0..<8).map { (row: row, column: $0) } }
        for (row, column) in frames {
            let key = "\(pet)/\(row)-\(column)"
            if boxes[key] == nil, let image = read(pet, row, column) { boxes[key] = Self.drawn(image) }
            guard let box = boxes[key] else { continue }
            left = min(left, box.left)
            right = max(right, box.right)
            if mirroredRows.contains(row), let width {
                left = min(left, width - 1 - box.right)
                right = max(right, width - 1 - box.left)
            }
        }
        return right >= left ? (left, right) : nil
    }

    /// Whether a frame is there to draw, starting the cutting as asking for it would. A frame once
    /// looked at is known for good, so this reads nothing from disk however much of the cache the
    /// system has taken back.
    func has(_ pet: String, row: Int, column: Int) -> Bool {
        let key = "\(pet)/\(row)-\(column)"
        return boxes[key] != nil || !absent.contains(key) && frame(pet, row: row, column: column) != nil
    }

    /// One frame at the size the room shows it, two pixels to the point (see `OfficeCanvas.prescaled`).
    func scaled(_ pet: String, row: Int, column: Int, scale: CGFloat) -> CGImage? {
        let key = Self.key(pet, row, column, scale)
        if let known = images.object(forKey: key) { return known }
        guard let frame = frame(pet, row: row, column: column), let image = OfficeCanvas.prescaled(frame.image, scale: scale) else { return nil }
        images.setObject(image, forKey: key, cost: image.bytesPerRow * image.height)
        return image
    }

    /// Frames for a loop or a walk at `scale`: for each row, its columns from 0 up to the count given,
    /// those the sheet has. Handed over at once when they are all scaled already; otherwise the rest
    /// are read and scaled off the main thread (a millisecond or two each) and handed over then, so
    /// that nobody waits for them to set off.
    func scaled(_ pet: String, rows: [Int: Int], scale: CGFloat, _ ready: @escaping ([Int: [CGImage]]) -> Void) {
        var known: [Int: [Int: CGImage]] = [:]
        var missing: [(row: Int, column: Int)] = []
        for (row, count) in rows {
            for column in 0..<count where !absent.contains("\(pet)/\(row)-\(column)") {
                if let image = images.object(forKey: Self.key(pet, row, column, scale)) {
                    known[row, default: [:]][column] = image
                } else {
                    missing.append((row, column))
                }
            }
        }
        func hand(_ frames: [Int: [Int: CGImage]]) { ready(frames.mapValues { row in row.keys.sorted().compactMap { row[$0] } }) }
        guard !missing.isEmpty, let dir = folder(of: pet) else { return hand(known) }
        DispatchQueue.global(qos: .userInitiated).async {
            let made = missing.map { frame -> CGImage? in
                guard let file = CGImageSourceCreateWithURL(URL(fileURLWithPath: "\(dir)/\(frame.row)-\(frame.column).png") as CFURL, nil),
                    let image = CGImageSourceCreateImageAtIndex(file, 0, nil)
                else { return nil }
                return OfficeCanvas.prescaled(image, scale: scale)
            }
            DispatchQueue.main.async {
                var all = known
                for (frame, image) in zip(missing, made) {
                    guard let image else {
                        // Sheets leave the frames a pose does not use empty; or the folder is gone, and is cut again.
                        if self.cutFolder(pet) != nil { self.absent.insert("\(pet)/\(frame.row)-\(frame.column)") } else { _ = self.folder(of: pet) }
                        continue
                    }
                    // One scaled meanwhile on the main thread stays: one copy of each frame.
                    let key = Self.key(pet, frame.row, frame.column, scale)
                    let kept = self.images.object(forKey: key) ?? image
                    self.images.setObject(kept, forKey: key, cost: kept.bytesPerRow * kept.height)
                    all[frame.row, default: [:]][frame.column] = kept
                }
                hand(all)
            }
        }
    }

    nonisolated private static func key(_ pet: String, _ row: Int, _ column: Int, _ scale: CGFloat) -> NSString {
        "\(pet)/\(row)-\(column)@\(scale)" as NSString
    }

    /// Whether a pet's frames are cut, without starting anything.
    func isCut(_ pet: String) -> Bool {
        if cutFolder(pet) != nil { return true }
        guard let sheet = sheetPath(pet), FileManager.default.fileExists(atPath: folder(pet, sheet) + "/done") else { return false }
        done[pet] = folder(pet, sheet)
        return true
    }

    /// Cuts these pets' frames in the background, one after another, whether or not the office is
    /// showing, so that it has them the first time it is. A pet already cut, being cut, or whose
    /// sheet cannot be cut starts nothing. Says how many were put in line.
    @discardableResult func prepare(_ pets: [String]) -> Int {
        var added = 0
        for pet in pets where !isCut(pet) && !cutting.contains(pet) && !queue.contains(pet) {
            guard let sheet = sheetPath(pet), !failed.contains(folder(pet, sheet)) else { continue }
            queue.append(pet)
            added += 1
        }
        prepareNext()
        return added
    }

    /// How many pets are being cut right now.
    var cuttingNow: Int { cutting.count }

    private func prepareNext() {
        guard !preparing, !queue.isEmpty else { return }
        let pet = queue.removeFirst()
        guard !cutting.contains(pet), !isCut(pet), let sheet = sheetPath(pet) else { return prepareNext() }
        let dir = folder(pet, sheet)
        preparing = true
        cutting.insert(pet)
        DispatchQueue.global(qos: .utility).async {
            let cut = Self.cut(sheet, into: dir)
            DispatchQueue.main.async {
                self.cutting.remove(pet)
                self.preparing = false
                if cut {
                    self.done[pet] = dir
                    self.onReady?()
                } else {
                    self.failed.insert(dir)
                }
                self.prepareNext()
            }
        }
    }

    /// Where a pet's frames are, once cut. Until then nil, and the cutting is started: in the
    /// background, or on the spot for a snapshot.
    private func folder(of pet: String) -> String? {
        if let dir = cutFolder(pet) { return dir }
        guard let sheet = sheetPath(pet) else { return nil }
        let dir = folder(pet, sheet)
        guard !failed.contains(dir) else { return nil }
        if !FileManager.default.fileExists(atPath: dir + "/done") {
            if synchronous {
                guard Self.cut(sheet, into: dir) else {
                    failed.insert(dir)
                    return nil
                }
            } else {
                if cutting.insert(pet).inserted {
                    DispatchQueue.global(qos: .utility).async {
                        let cut = Self.cut(sheet, into: dir)
                        DispatchQueue.main.async {
                            self.cutting.remove(pet)
                            if cut { self.onReady?() } else { self.failed.insert(dir) }
                        }
                    }
                }
                return nil
            }
        }
        done[pet] = dir
        return dir
    }

    /// A pet's folder of cut frames, if it is still there. The system clears caches when the disk runs
    /// short; then everything known about the pet's frames goes, and the pet is cut again.
    private func cutFolder(_ pet: String) -> String? {
        guard let dir = done[pet] else { return nil }
        if FileManager.default.fileExists(atPath: dir + "/done") { return dir }
        done[pet] = nil
        boxes = boxes.filter { !$0.key.hasPrefix(pet + "/") }
        absent = absent.filter { !$0.hasPrefix(pet + "/") }
        return nil
    }

    /// The folder for a sheet as it is now: a replaced sheet gets a new one.
    private func folder(_ pet: String, _ sheet: String) -> String {
        let stamp = ((try? FileManager.default.attributesOfItem(atPath: sheet))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(folder)/\(pet)-\(Int(stamp))"
    }

    /// A pet's own size from its pet.json (`PetSources.scale`), the one in the pool its frames come from; 1 for most.
    /// Read once.
    func size(_ pet: String) -> CGFloat {
        if let known = sizes[pet] { return known }
        let pool = pools.first { FileManager.default.fileExists(atPath: "\($0)/\(pet)/pet.json") }
        let size = pool.map { PetSources.scale(in: $0, pet) } ?? 1
        sizes[pet] = size
        return size
    }
    private var sizes: [String: CGFloat] = [:]

    /// The sessions whose pets are not shown at the size their height gives (`size` other than 1), by session.
    func sizes(_ store: Store) -> [String: CGFloat] {
        var out: [String: CGFloat] = [:]
        for (id, pet) in store.displayPets {
            let size = size(pet)
            if size != 1 { out[id] = size }
        }
        return out
    }

    private func sheetPath(_ pet: String) -> String? {
        for pool in pools {
            let json = FileManager.default.contents(atPath: "\(pool)/\(pet)/pet.json").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let file = ((json?["spritesheetPath"] as? String) ?? "spritesheet.webp") as NSString
            let path = "\(pool)/\(pet)/\(file.lastPathComponent)"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    nonisolated private static func pixels(of image: CGImage) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard
                let context = CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return drawn ? data : nil
    }

    /// Whether the sheet could be read; one that cannot leaves nothing behind.
    @discardableResult nonisolated private static func cut(_ sheetPath: String, into dir: String) -> Bool {
        guard let lazy = NSImage(contentsOfFile: sheetPath)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let sheet = pixels(of: lazy)
        else { return false }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fw = lazy.width / 8, fh = fw * 208 / 192
        let step = max(1, fw / 96)  // 2 for the usual sheet
        let w = fw / step, h = fh / step
        for row in rows where (row + 1) * fh <= lazy.height {
            for column in 0..<8 {
                var out = [UInt8](repeating: 0, count: w * h * 4)
                var any = false
                for y in 0..<h {
                    for x in 0..<w {
                        // Average the block (the values are premultiplied, so this is exact),
                        // then make the pixel either solid or absent: no soft fringe.
                        var sum = [0, 0, 0, 0]
                        for dy in 0..<step {
                            for dx in 0..<step {
                                let i = ((row * fh + y * step + dy) * lazy.width + column * fw + x * step + dx) * 4
                                for channel in 0..<4 { sum[channel] += Int(sheet[i + channel]) }
                            }
                        }
                        guard sum[3] / (step * step) >= 128 else { continue }
                        let o = (y * w + x) * 4
                        for channel in 0..<3 { out[o + channel] = UInt8(min(255, sum[channel] * 255 / max(1, sum[3]))) }
                        out[o + 3] = 255
                        any = true
                    }
                }
                guard any else { continue }  // sheets leave the frames a pose does not use empty
                let image = out.withUnsafeMutableBytes { buffer -> CGImage? in
                    CGContext(
                        data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
                }
                guard let image,
                    let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(row)-\(column).png") as CFURL, "public.png" as CFString, 1, nil)
                else { continue }
                CGImageDestinationAddImage(file, image, nil)
                CGImageDestinationFinalize(file)
            }
        }
        FileManager.default.createFile(atPath: dir + "/done", contents: nil)
        return true
    }
}

// ───────── Drawing ─────────

/// A bitmap with its origin at the top left, in points, two device pixels to the point.
/// Blocks are drawn hard-edged, the way the pets are; type and cards are smooth, the way
/// the board's are.
final class OfficeCanvas {
    let ctx: CGContext
    /// Told of everything solid painted, for the overlap check; shadows (painted see-through) are floor, and are not told.
    var tally: ((CGRect) -> Void)?

    convenience init(_ size: CGSize) { self.init(CGRect(origin: .zero, size: size)) }

    /// A canvas for one part of the picture, drawn to in the picture's own coordinates. The part
    /// should start and end on whole pixels (halves of a point), so it matches the whole picture.
    init(_ area: CGRect) {
        ctx = CGContext(
            data: nil, width: Int((area.width * 2).rounded()), height: Int((area.height * 2).rounded()), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: area.height * 2)
        ctx.scaleBy(x: 2, y: -2)
        ctx.translateBy(x: -area.minX, y: -area.minY)
    }

    static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }

    func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, _ alpha: CGFloat = 1) {
        ctx.setShouldAntialias(false)
        ctx.setFillColor(Self.rgb(hex, alpha))
        ctx.fill(CGRect(x: x, y: y, width: w, height: h))
        if alpha >= 1, w > 0, h > 0 { tally?(CGRect(x: x, y: y, width: w, height: h)) }
    }

    /// A block with its corners stepped off.
    func block(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, _ alpha: CGFloat = 1, notch: CGFloat = 2) {
        fill(x + notch, y, w - 2 * notch, h, hex, alpha)
        fill(x, y + notch, w, h - 2 * notch, hex, alpha)
    }

    /// A smooth rounded card, filled and optionally outlined.
    func card(_ r: CGRect, radius: CGFloat, _ hex: UInt32, _ alpha: CGFloat = 1, edge: UInt32? = nil) {
        let path = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if alpha >= 1 { tally?(r) }
        ctx.setShouldAntialias(true)
        ctx.addPath(path)
        ctx.setFillColor(Self.rgb(hex, alpha))
        ctx.fillPath()
        if let edge {
            ctx.addPath(path)
            ctx.setStrokeColor(Self.rgb(edge))
            ctx.setLineWidth(1)
            ctx.strokePath()
        }
    }

    /// A pet frame at `scale`, two pixels to the point. It is first enlarged four times with hard
    /// edges, so that shrinking it smoothly to any size keeps its pixels crisp. Its top left corner
    /// is on a pixel, so drawn with `image(_:in:)` it lands on the picture's pixels one to one.
    static func prescaled(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let wide = CGFloat(image.width) * scale * 2, high = CGFloat(image.height) * scale * 2
        guard
            let large = CGContext(
                data: nil, width: image.width * 4, height: image.height * 4, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        large.interpolationQuality = .none
        large.setShouldAntialias(false)
        large.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 4, height: image.height * 4))
        guard let enlarged = large.makeImage(),
            let small = CGContext(
                data: nil, width: Int(wide.rounded(.up)), height: Int(high.rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        small.setShouldAntialias(true)
        small.interpolationQuality = .high
        small.draw(enlarged, in: CGRect(x: 0, y: high.rounded(.up) - high, width: wide, height: high))
        return small.makeImage()
    }

    /// A picture of two pixels to the point, upright, filling `r`.
    func image(_ image: CGImage, in r: CGRect, alpha: CGFloat = 1) {
        ctx.saveGState()
        ctx.interpolationQuality = .none  // pieces land one to one
        ctx.setAlpha(alpha)
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    /// A string as the canvas sets it: names and times one line in the rounded face, running text wrapped in the plain one.
    static func line(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ hex: UInt32, _ alpha: CGFloat, _ align: NSTextAlignment, wraps: Bool)
        -> NSAttributedString
    {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        // Names and times in the rounded face, running text in the plain one: as on the board.
        let font = wraps ? base : base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let style = NSMutableParagraphStyle()
        // By word: Latin words stay whole; Chinese still breaks between characters, and a word longer than the line still breaks.
        style.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        style.alignment = align
        style.lineSpacing = wraps ? 1.5 : 0
        return NSAttributedString(
            string: s, attributes: [.font: font, .foregroundColor: NSColor(cgColor: Self.rgb(hex, alpha)) ?? .white, .paragraphStyle: style])
    }

    func width(of s: String, size: CGFloat, weight: NSFont.Weight = .semibold) -> CGFloat {
        ceil(Self.line(s, size, weight, 0, 1, .left, wraps: false).size().width)
    }

    /// Text in a box: one line cut with an ellipsis, or wrapped to the box's height.
    func text(
        _ s: String, in r: CGRect, size: CGFloat, weight: NSFont.Weight = .semibold, _ hex: UInt32, _ alpha: CGFloat = 1,
        align: NSTextAlignment = .left, wraps: Bool = false
    ) {
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        ctx.setShouldAntialias(true)
        Self.line(s, size, weight, hex, alpha, align, wraps: wraps).draw(with: r, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        NSGraphicsContext.current = previous
    }

    func image() -> CGImage? { ctx.makeImage() }
}

/// The board's own colours for what a session is doing, and the type sizes. Coral, green and the pin are the same in every
/// theme; the themes take their paper and ink from here.
enum OfficeLook {
    static let paper: UInt32 = 0xE9E6F7, ink: UInt32 = 0x1E1A33
    static let skin: UInt32 = 0xE6CBA6  // the little people's faces and hands: a light ash, not a new family
    static let call: UInt32 = 0xFF6B4A, work: UInt32 = 0x57D08A, pin: UInt32 = 0xD8432B
    static let shade: CGFloat = 0.30

    /// How large to paint a word so that on screen, where the picture is shown at `scale`, it is
    /// never smaller than its base size.
    static func type(_ base: CGFloat, scale: CGFloat) -> CGFloat { scale > 0 ? base * max(1, 1 / scale) : base }

    /// The scale as the signature counts it, in twentieths, so a window being resized repaints
    /// only now and then. The words themselves are painted for the exact scale.
    static func lineHeight(_ size: CGFloat) -> CGFloat { ceil(size * 1.25) }

    static func step(_ scale: CGFloat) -> CGFloat { (scale * 20 + 0.0001).rounded(.down) / 20 }
}

// ───────── Themes ─────────

/// A theme's colours: the room's, its furniture's, its lettering's. Coral and green stay `OfficeLook`'s in every theme: they
/// say who waits and who works.
struct OfficePalette: Equatable {
    /// A piece of furniture's material: a lighter top face, a front face and a darker base line.
    struct Tone: Equatable {
        let top: UInt32, front: UInt32, base: UInt32
    }
    var floor: UInt32, rug: UInt32, rugEdge: UInt32, wall: UInt32, skirting: UInt32
    var sky: UInt32, skyLow: UInt32, frame: UInt32
    /// Furniture outlines: a shade under the thing, not black.
    var line: UInt32
    /// Names, and the quieter words (projects, the resting, the floor's labels); and the inks they take on a light floor.
    var name: UInt32, faint: UInt32
    let darkName: UInt32, darkFaint: UInt32
    /// The dark plate of one at work, the work chip and the little people's count, with its edge.
    let plate: UInt32, plateEdge: UInt32
    /// The paper of news (plates, the chip, the chat marks, the board's dot) and the ink on paper and on coral. Both themes
    /// keep the board's own, so a card reads the same in the room as on the board.
    let paper: UInt32, ink: UInt32
    /// How dark the wall's shadow on the floor under the skirting is, as a share of `OfficeLook.shade`; none in a flat room.
    let wallShade: CGFloat
    let white: Tone, ash: Tone, graphite: Tone, chair: Tone, mustard: Tone, slate: Tone

    /// With a floor of their own: the wall and the skirting darker by fixed steps, the rug and its edge away from the floor by
    /// fixed steps (lighter on a dark floor, darker on a light one, so they show on either), so one colour is enough. The
    /// names keep the theme's ink unless its dark ink reads better on that floor; the quieter words go with them.
    func floored(_ hex: UInt32) -> OfficePalette {
        var p = self
        p.floor = hex
        p.wall = Self.mix(hex, 0x000000, 0.2)
        p.skirting = Self.mix(hex, 0x000000, 0.33)
        let away: UInt32 = Self.luminance(hex) > 0.5 ? 0x000000 : 0xFFFFFF
        p.rug = Self.mix(hex, away, 0.06)
        p.rugEdge = Self.mix(hex, away, 0.22)
        if Self.contrast(darkName, hex) > Self.contrast(name, hex) {
            p.name = darkName
            p.faint = darkFaint
        }
        return p
    }

    /// `share` of the way from one colour to another.
    static func mix(_ a: UInt32, _ b: UInt32, _ share: CGFloat) -> UInt32 {
        [16, 8, 0].reduce(UInt32(0)) { hex, shift in
            let from = CGFloat((a >> shift) & 255), to = CGFloat((b >> shift) & 255)
            return hex | UInt32((from + (to - from) * share).rounded()) << shift
        }
    }

    /// How light a colour reads, as WCAG counts it: 0 for black, 1 for white.
    static func luminance(_ hex: UInt32) -> CGFloat {
        [(16, 0.2126), (8, 0.7152), (0, 0.0722)].reduce(0) { sum, part in
            let c = CGFloat((hex >> UInt32(part.0)) & 255) / 255
            return sum + part.1 * (c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4))
        }
    }

    /// How far apart two colours read, as WCAG counts it: 1 for the same, 21 for black on white.
    static func contrast(_ a: UInt32, _ b: UInt32) -> CGFloat {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
}

/// A look for the office: its colours and how its furniture is drawn. The layout is the same in every theme, so a theme
/// never moves anything, and changing it repaints the room and the words in place. Another theme is one more
/// `OfficeFurniture` type and its palette, added to `all`.
@MainActor struct OfficeTheme {
    /// The theme's id: what `officeTheme` / `officeThemeOffice` store and every comparison reads. The Chinese names of
    /// the first themes (the grey-blue office theme, the warm-night office theme, Seaview; an extension's own), kept byte for byte so saved settings still mean them; never
    /// shown: what is shown is `displayName`.
    let name: String
    let palette: OfficePalette
    let furniture: any OfficeFurniture

    /// A quiet blue-grey studio, sand desks, muted blue sofas. The default.
    static let studio = OfficeTheme(
        name: "青灰",
        palette: OfficePalette(
            floor: 0x303B46, rug: 0x394957, rugEdge: 0x60717E, wall: 0x26313B, skirting: 0x202C36, sky: 0x354958, skyLow: 0x526A7A,
            frame: 0x596B78, line: 0x202A33, name: 0xCFCBE6, faint: 0xA3A0C4, darkName: 0x202A33, darkFaint: 0x465966, plate: 0x202C36,
            plateEdge: 0x607583, paper: OfficeLook.paper, ink: OfficeLook.ink, wallShade: 0,
            // Every face that meets the floor or the rug is at least 2:1 against it, so nothing standing there vanishes
            // into it; the 1-pt `line` round each piece is the one thing darker than the floor.
            white: .init(top: 0xD5C8B3, front: 0xACA699, base: 0x827F77),  // desk tops and legs, bezels, the door
            ash: .init(top: 0xC2AA86, front: 0xAC9574, base: 0x88765D),  // your desk, the sofas' legs, the board's notes
            graphite: .init(top: 0x647785, front: 0x465966, base: 0x26323D),  // the wall's things, screens that are off
            chair: .init(top: 0x9AABB6, front: 0x7F939F, base: 0x607583),  // blue-grey frames, light enough to read on the rug
            mustard: .init(top: 0x91ACBF, front: 0x7798AF, base: 0x526F83),  // the four sofas: muted blue upholstery
            slate: .init(top: 0x708491, front: 0x596F7D, base: 0x455B69)),  // the couches at the back, faint
        furniture: StudioFurniture())

    /// The board's own night violet, so switching views does not flash; white desks, mustard sofas.
    static let night = OfficeTheme(
        name: "暖夜",
        palette: OfficePalette(
            floor: 0x2C2849, rug: 0x353159, rugEdge: 0x423D6C, wall: 0x242140, skirting: 0x1B1830, sky: 0x1F2A5C, skyLow: 0x2D3C78,
            frame: 0x3A3662, line: 0x191630, name: 0xCFCBE6, faint: 0xA3A0C4, darkName: OfficeLook.ink, darkFaint: 0x4A4674, plate: 0x1B1830,
            plateEdge: 0x4A4674, paper: OfficeLook.paper, ink: OfficeLook.ink, wallShade: 0.5,
            white: .init(top: 0xECE6DA, front: 0xB9B2A4, base: 0x8C8578),  // desk tops and legs, bezels, the door
            ash: .init(top: 0xC8A882, front: 0xAA8D69, base: 0x8E7558),  // your desk, the sofas' legs, the cork
            graphite: .init(top: 0x4A4768, front: 0x3A3754, base: 0x2A2740),  // the wall's things, screens that are off
            chair: .init(top: 0x726EA8, front: 0x64609A, base: 0x4A4674),  // graphite lightened until it reads on the rug
            mustard: .init(top: 0xDDB766, front: 0xC9A24E, base: 0x9E7E3A),  // the four sofas: the one accent
            slate: .init(top: 0x6A749C, front: 0x5C668C, base: 0x525C80)),  // the couches at the back, faint
        furniture: NightFurniture())

    /// Seaview: the rendered office draws itself (`ZoneView`); this palette is only the studio's, for anything that asks.
    static let zone = OfficeTheme(name: "海景房", palette: studio.palette, furniture: StudioFurniture())

    /// The theme's name on screen, in the panel's language. An extension's theme shows its own name.
    var displayName: String {
        switch name {
        case Self.studio.name: return L10n.string("theme.studio", table: "Office", zh: "青灰")
        case Self.night.name: return L10n.string("theme.night", table: "Office", zh: "暖夜")
        case Self.zone.name: return L10n.string("theme.zone", table: "Office", zh: "海景房")
        default: return name
        }
    }

    /// Every theme, an extension's scene's (`SceneExtension.theme`) before Seaview.
    static var all: [OfficeTheme] { [studio, night] + (Extensions.registered.map { [$0.theme] } ?? []) + [zone] }
    /// The office's own themes, which the theme menu offers; a scene is a mode of the panel, not a choice here.
    static let officeThemes = [studio, night]

    /// The theme of this name; Slate for one it does not know.
    static func named(_ name: String?) -> OfficeTheme {
        let scene = Extensions.registered
        let theme = all.first { $0.name == name } ?? studio
        // A scene this build cannot show (its art did not come with it) is Seaview.
        return theme.name == scene?.theme.name && scene?.available != true ? zone : theme
    }

    /// The same theme on a floor of their own, if any.
    func floored(_ hex: UInt32?) -> OfficeTheme {
        hex.map { OfficeTheme(name: name, palette: palette.floored($0), furniture: furniture) } ?? self
    }

    /// What the room and the words are painted from, of the theme.
    var key: String { "\(name) \(palette.floor) \(palette.name)" }

    /// For a still picture: the theme it is drawn in, in memory, whatever the setting says.
    static var shown: OfficeTheme?

    /// The theme the office is drawn in: the picture's, else the setting's (`officeTheme`, with `officeFloor` over its
    /// floor when the user chose one).
    static var current: OfficeTheme {
        shown ?? named(UserDefaults.standard.string(forKey: "officeTheme")).floored(hex(UserDefaults.standard.string(forKey: "officeFloor")))
    }

    /// A colour written as six hex digits, with or without a "#".
    static func hex(_ text: String?) -> UInt32? {
        guard let text else { return nil }
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        return digits.count == 6 ? UInt32(digits, radix: 16) : nil
    }

    /// What `--theme <name>` and `--floor <hex>` ask a snapshot for; nil with neither. A floor alone goes under the theme the user
    /// has set.
    static func chosen(arguments: [String]) -> OfficeTheme? {
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } }
        let name = value("--theme"), floor = hex(value("--floor"))
        return name == nil && floor == nil ? nil : named(name ?? UserDefaults.standard.string(forKey: "officeTheme")).floored(floor)
    }
}

/// The status-bar menu's choice of theme. An office theme is also what Office goes back to from a scene.
@MainActor func setOfficeTheme(_ name: String) {
    UserDefaults.standard.set(name, forKey: "officeTheme")
    if OfficeTheme.officeThemes.contains(where: { $0.name == name }) { UserDefaults.standard.set(name, forKey: "officeThemeOffice") }
}

/// At launch: a build that cannot show an extension's scene (its art did not come with it) turns a theme saved as that scene
/// into Seaview, in the setting itself. Only here; a picture never writes a setting.
@MainActor func settleOfficeTheme() {
    if let scene = Extensions.registered, !scene.available, UserDefaults.standard.string(forKey: "officeTheme") == scene.theme.name {
        UserDefaults.standard.set(OfficeTheme.zone.name, forKey: "officeTheme")
    }
}

/// A floor of their own, or the theme's again.
func setOfficeFloor(_ hex: UInt32?) {
    if let hex { UserDefaults.standard.set(String(format: "%06X", hex), forKey: "officeFloor") } else { UserDefaults.standard.removeObject(forKey: "officeFloor") }
}

/// What a theme's furniture is drawn with: the canvas, the theme's colours (with their floor, if any), and the two shapes
/// most pieces are made of.
@MainActor struct OfficeBrush {
    let c: OfficeCanvas
    let p: OfficePalette

    /// A point to the unit, outlined a point wide, a lighter top face, a front face and a darker base line. `round` steps
    /// the corners off.
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, top: CGFloat, _ tone: OfficePalette.Tone, round: CGFloat = 0, base: Bool = true) {
        c.block(x - 1, y - 1, w + 2, h + 2, p.line, notch: round)
        c.block(x, y, w, h, tone.front, notch: round)
        c.fill(x + round, y, w - 2 * round, min(top, round), tone.top)
        if top > round { c.fill(x, y + round, w, top - round, tone.top) }
        if base { c.fill(x + round, y + h - 1, w - 2 * round, 1, tone.base) }
    }

    /// A round thing in whole points, row by row: an even width keeps every row on the grid.
    func disc(_ x: CGFloat, _ y: CGFloat, _ wide: CGFloat, _ hex: UInt32) {
        let r = wide / 2
        for i in 0..<Int(wide) {
            let dy = CGFloat(i) + 0.5 - r, half = (r * r - dy * dy).squareRoot().rounded()
            c.fill(x + r - half, y + CGFloat(i), 2 * half, 1, hex)
        }
    }
}

/// How a theme draws the room's furniture, each piece where `drawRoom` puts it and within the place the layout gives it:
/// the sitters, words and cards land where they do in every theme.
@MainActor protocol OfficeFurniture {
    /// A window on the back wall, 247 by 56 from `left`, 4 down; the first of the two.
    func window(_ b: OfficeBrush, left: CGFloat, first: Bool)
    /// The lounge door's leaf and frame; the plate on it, saying how many are behind it, is the room's.
    func door(_ b: OfficeBrush, _ door: CGRect)
    /// The notice board; the dot at its corner is the room's.
    func board(_ b: OfficeBrush, _ board: CGRect)
    /// A couch at the back or a sofa from the front, `seats` long, `pitch` a seat between arms `arm` wide: its back
    /// `back` tall over a seat `deep`, sitters' feet at `edge`, the seat's front.
    func seat(
        _ b: OfficeBrush, left: CGFloat, seats: Int, pitch: CGFloat, arm: CGFloat, edge: CGFloat, back: CGFloat, deep: CGFloat,
        _ tone: OfficePalette.Tone, legs: OfficePalette.Tone)
    /// A desk whose slab starts at `x`, its monitor (lit green while someone works there) at its left reaching
    /// `OfficePainter.monitorTop` over its `floor`, and its chair at `chair`, where the sitter stands.
    func desk(_ b: OfficeBrush, x: CGFloat, floor: CGFloat, slab: CGFloat, chair: CGFloat, working: Bool)
    /// The rug under your corner, from `top` to just inside the room's edges.
    func rug(_ b: OfficeBrush, top: CGFloat, room: CGSize)
    /// Your desk and your chair from behind, from `left`, `width` wide, standing on the room's bottom edge.
    func yourDesk(_ b: OfficeBrush, left: CGFloat, width: CGFloat, height: CGFloat)
    /// A subagent: a little person, 8 by 14 and a point to the pixel, sitting on an edge at `x`, `y`; one of four outfits.
    func person(_ b: OfficeBrush, x: CGFloat, y: CGFloat, variant: Int)
    /// What a floor label has under its words, if anything.
    func label(_ b: OfficeBrush, _ words: CGRect)
    /// Anything laid on the floor before the room's furniture, if anything (a theme of an extension's may).
    func ground(_ c: OfficeCanvas, _ layout: OfficeLayout, _ look: OfficePalette)
}

extension OfficeFurniture {
    func ground(_ c: OfficeCanvas, _ layout: OfficeLayout, _ look: OfficePalette) {}
}

/// the grey-blue office theme's furniture: modular, flat, no cast shadows; C-frame desks with wide monitors, shell chairs,
/// sofas of separate cushions in one shell, a high-back chair at your desk.
struct StudioFurniture: OfficeFurniture {
    func window(_ b: OfficeBrush, left: CGFloat, first: Bool) {
        let c = b.c, look = b.p
        c.block(left, 4, 247, 56, look.frame, notch: 4)
        c.block(left + 2, 6, 243, 52, look.sky, notch: 3)
        c.fill(left + 3, 40, 241, 14, look.skyLow)
        for dx in [CGFloat(61), 183] { c.fill(left + dx, 7, 2, 50, look.frame) }
        c.fill(left + 3, 38, 241, 2, look.frame)
        c.fill(left + 8, 58, 231, 2, look.graphite.top)
    }

    // A flush warm-white leaf in a graphite frame, a slim handle.
    func door(_ b: OfficeBrush, _ door: CGRect) {
        let c = b.c, look = b.p, graphite = look.graphite
        c.block(door.minX, door.minY, door.width, door.height, graphite.top, notch: 4)
        c.fill(door.minX + 4, door.minY + 4, door.width - 8, door.height - 4, graphite.base)
        c.fill(door.minX + 7, 36, door.width - 14, 16, look.skyLow)
        c.fill(door.minX + 7, 55, door.width - 14, 11, look.sky)
        c.fill(door.maxX - 17, 42, 10, 3, look.white.top)
    }

    // Three card strips on a dark panel in a frame.
    func board(_ b: OfficeBrush, _ board: CGRect) {
        let c = b.c, look = b.p, graphite = look.graphite
        c.block(board.minX, board.minY, board.width, board.height, graphite.top, notch: 4)
        c.fill(board.minX + 3, board.minY + 3, board.width - 6, board.height - 6, graphite.base)
        for i in 0..<3 {
            let y = board.minY + 7 + CGFloat(i) * 10
            c.fill(board.minX + 8, y, 5, 5, look.ash.front)
            c.fill(board.minX + 18, y, 48 - CGFloat(i) * 7, 2, look.white.front)
            c.fill(board.minX + 18, y + 4, 30, 1, graphite.top)
        }
    }

    // A low continuous shell unites the separate cushions into one piece, on a continuous base and two legs.
    func seat(
        _ b: OfficeBrush, left: CGFloat, seats: Int, pitch: CGFloat, arm: CGFloat, edge: CGFloat, back: CGFloat, deep: CGFloat,
        _ tone: OfficePalette.Tone, legs: OfficePalette.Tone
    ) {
        let c = b.c, wide = 2 * arm + CGFloat(seats) * pitch
        c.block(left, edge - deep - back, wide, back + deep + 4, tone.base, notch: 5)
        c.block(left + 2, edge - deep - back + 2, wide - 4, back + deep, tone.front, notch: 4)
        c.fill(left + 8, edge + 3, wide - 16, 3, legs.front)
        for x in [left + 10, left + wide - 13] { c.fill(x, edge + 3, 3, 5, legs.front) }
        for i in 0..<seats {
            let x = left + arm + CGFloat(i) * pitch
            c.block(x + 2, edge - deep - back + 2, pitch - 4, back, tone.front, notch: 3)
            if i > 0 { c.fill(x, edge - deep - back + 6, 2, back - 7, tone.base) }
            c.block(x + 2, edge - deep, pitch - 4, deep + 4, tone.top, notch: 3)
            c.fill(x + 6, edge + 2, pitch - 12, 2, tone.base)
        }
        for x in [left, left + wide - arm] {
            c.block(x, edge - deep - 12, arm, deep + 16, tone.base, notch: 2)
            c.block(x + 1, edge - deep - 12, arm - 2, deep + 13, tone.top, notch: 2)
        }
    }

    func desk(_ b: OfficeBrush, x: CGFloat, floor: CGFloat, slab: CGFloat, chair cx: CGFloat, working: Bool) {
        let c = b.c, look = b.p, white = look.white
        // Broad C-section end frames replace the needle legs.
        for lx in [x + 3, x + slab - 16] {
            c.fill(lx, floor - 26, 13, 26, white.front)
            c.fill(lx + 4, floor - 23, 9, 20, look.floor)
        }
        c.block(x, floor - 34, slab, 8, white.top, notch: 3)
        c.fill(x + 3, floor - 28, slab - 6, 2, white.base)
        // A cantilever arm leaves space for helpers on the front edge.
        c.fill(x + 9, floor - 44, 3, 10, white.front)
        c.fill(x + 9, floor - 37, 18, 3, white.front)
        c.block(x + 4, floor - OfficePainter.monitorTop, 45, 24, white.front, notch: 3)
        c.block(x + 6, floor - 64, 41, 19, working ? 0x2F6B55 : look.graphite.base, notch: 2)
        if working {
            c.fill(x + 10, floor - 61, 18, 3, OfficeLook.work)
            c.fill(x + 10, floor - 56, 24, 3, OfficeLook.work)
            c.fill(x + 10, floor - 51, 12, 3, OfficeLook.work)
        }
        // An open shell back and a sled base remain readable at empty seats.
        let chair = look.chair
        c.block(cx - 13, floor - 26, 26, 20, chair.front, notch: 5)
        c.block(cx - 7, floor - 22, 14, 4, look.floor, notch: 1)
        c.fill(cx - 15, floor - 6, 30, 3, chair.top)
        for lx in [cx - 11, cx + 8] { c.fill(lx, floor - 3, 3, 9, chair.front) }
        c.fill(cx - 11, floor + 5, 22, 3, chair.front)
    }

    func rug(_ b: OfficeBrush, top: CGFloat, room: CGSize) {
        b.c.block(2, top, room.width - 4, room.height - 4 - top, b.p.rug, notch: 12)
        b.c.fill(14, top + 3, 148, 3, b.p.rugEdge)
    }

    func yourDesk(_ b: OfficeBrush, left ux: CGFloat, width uw: CGFloat, height H: CGFloat) {
        let c = b.c, look = b.p, white = look.white, ash = look.ash, graphite = look.graphite, chair = look.chair
        let uf = H - 33, cx = ux + 77
        c.block(ux + 7, uf - 31, 32, 29, graphite.top, notch: 3)
        c.fill(ux + 12, uf - 21, 22, 2, graphite.base)
        c.fill(ux + 12, uf - 10, 22, 2, graphite.base)
        c.fill(ux + uw - 14, uf - 31, 7, 29, white.front)
        c.fill(ux + uw - 26, uf - 3, 19, 3, white.front)
        c.block(ux, uf - 44, uw, 12, ash.top, notch: 5)
        c.fill(ux + 5, uf - 34, uw - 10, 2, ash.base)
        // A broad task-light hood on a single upright, no light or glow painted.
        c.block(ux + 9, uf - 42, 20, 3, chair.front, notch: 1)
        c.fill(ux + 17, uf - 65, 3, 23, chair.front)
        c.block(ux + 7, uf - 72, 27, 8, chair.top, notch: 3)
        // A wide rounded monitor on an offset arm, matching the workstations.
        c.fill(cx - 23, uf - 54, 4, 11, white.front)
        c.fill(cx - 23, uf - 45, 19, 3, white.front)
        c.block(cx - 28, uf - 78, 59, 27, white.front, notch: 4)
        c.block(cx - 25, uf - 75, 53, 21, graphite.base, notch: 2)
        c.fill(cx - 20, uf - 72, 20, 3, OfficeLook.call)
        c.fill(cx - 20, uf - 67, 36, 3, look.paper)
        c.fill(cx - 20, uf - 62, 16, 3, OfficeLook.work)
        c.block(cx - 19, uf - 39, 38, 3, chair.front, notch: 1)
        c.block(cx + 22, uf - 39, 4, 3, chair.front, notch: 1)
        // Papers, two sheets, and the mug.
        for (dx, dy) in [(CGFloat(4), CGFloat(1)), (0, 0)] {
            b.box(ux + 112 + dx, uf - 42 + dy, 18, 8, top: 8, white, base: false)
        }
        for i in 0..<3 { c.fill(ux + 114, uf - 40 + CGFloat(i) * 2, i == 2 ? 8 : 13, 1, white.front) }
        b.box(ux + 140, uf - 49, 8, 9, top: 2, white, round: 1)
        c.fill(ux + 149, uf - 47, 3, 6, look.line)
        c.fill(ux + 149, uf - 46, 2, 4, white.front)
        // A two-piece upholstered back on an exposed central spine, viewed from behind.
        c.fill(cx - 3, H - 64, 6, 52, chair.front)
        c.block(cx - 15, H - 65, 30, 10, chair.top, notch: 4)
        c.block(cx - 20, H - 49, 40, 25, chair.front, notch: 6)
        c.fill(cx - 2, H - 46, 4, 19, chair.base)
        for ax in [cx - 25, cx + 21] { c.block(ax, H - 37, 4, 16, chair.top, notch: 1) }
        c.block(cx - 22, H - 23, 44, 5, chair.top, notch: 2)
        c.fill(cx - 18, H - 10, 36, 3, chair.front)
        for wx in [cx - 20, cx + 16] { c.block(wx, H - 7, 4, 3, graphite.top, notch: 1) }
    }

    // In overalls and short boots.
    func person(_ b: OfficeBrush, x: CGFloat, y: CGFloat, variant: Int) {
        OfficePeople.draw(b, x: x, y: y, variant: variant, rows: [
            "..hhhh..", ".hhhhhh.", ".hssssh.", ".sesesh.", "..ssss..", "...ss...", ".tttttt.",
            "stptptts", "stppppts", "..pppp..", ".pp..pp.", ".pp..pp.", ".bb..bb.", "bbb..bbb",
        ])
    }

    // A short line under its words.
    func label(_ b: OfficeBrush, _ words: CGRect) { b.c.fill(words.minX, words.maxY + 2, 26, 2, b.p.rugEdge) }
}

/// the warm-night office theme's furniture: lit from the top left, with cast shadows; white desks on slim legs, upholstered
/// sofas with wooden legs, a moon in the first window, cork on the board.
struct NightFurniture: OfficeFurniture {
    private func shadow(_ b: OfficeBrush, _ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat = 6) {
        b.c.block(x, y, w, h, 0x000000, OfficeLook.shade * 0.8, notch: 3)
    }

    // Two panes of dusk in a thin light frame, a point wide, nothing more.
    func window(_ b: OfficeBrush, left: CGFloat, first: Bool) {
        let c = b.c, look = b.p
        c.fill(left, 4, 247, 56, look.white.front)
        for pane in [left + 1, left + 124] {
            c.fill(pane, 5, 122, 27, look.sky)
            c.fill(pane, 32, 122, 27, look.skyLow)
        }
        if first {  // a crescent moon, dim, so it is not mistaken for something on the wall
            b.disc(left + 182, 11, 14, look.white.front)
            b.disc(left + 187, 8, 12, look.sky)
        }
    }

    // A flush warm-white leaf in a graphite frame, a narrow glass strip, a slim handle.
    func door(_ b: OfficeBrush, _ door: CGRect) {
        let c = b.c, look = b.p, graphite = look.graphite, white = look.white
        c.fill(door.minX, door.minY, door.width, door.height, look.line)
        c.fill(door.minX + 1, door.minY + 1, door.width - 2, door.height - 1, graphite.front)
        c.fill(door.minX + 1, door.minY + 1, door.width - 2, 1, graphite.top)
        c.fill(door.minX + 4, door.minY + 4, door.width - 8, door.height - 4, look.line)
        c.fill(door.minX + 5, door.minY + 5, door.width - 10, door.height - 5, white.top)
        c.fill(door.maxX - 6, door.minY + 5, 1, door.height - 5, white.front)  // the leaf's edge, away from the light
        c.fill(door.minX + 10, 36, 8, 27, look.line)  // a narrow glass strip, as office doors have
        c.fill(door.minX + 11, 37, 6, 13, look.sky)
        c.fill(door.minX + 11, 50, 6, 12, look.skyLow)
        c.fill(door.maxX - 15, 34, 4, 18, look.line)
        c.fill(door.maxX - 14, 35, 2, 16, graphite.front)
    }

    // Cork in a graphite frame, three paper notes pinned on it.
    func board(_ b: OfficeBrush, _ board: CGRect) {
        let c = b.c, look = b.p, graphite = look.graphite, ash = look.ash, white = look.white
        c.fill(board.minX, board.minY, board.width, board.height, look.line)
        c.fill(board.minX + 1, board.minY + 1, board.width - 2, board.height - 2, graphite.front)
        c.fill(board.minX + 1, board.minY + 1, board.width - 2, 1, graphite.top)
        c.fill(board.minX + 3, board.minY + 3, board.width - 6, board.height - 6, look.line)
        c.fill(board.minX + 4, board.minY + 4, board.width - 8, board.height - 8, ash.front)
        c.fill(board.minX + 4, board.minY + 4, board.width - 8, 1, ash.base)  // the frame's shadow on the cork
        c.fill(board.minX + 4, board.minY + 4, 1, board.height - 8, ash.base)
        func note(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, lines: [CGFloat], ink: UInt32) {
            c.fill(x + 1, y + 1, w, h, ash.base)
            c.fill(x, y, w, h, hex)
            for (i, wide) in lines.enumerated() { c.fill(x + 3, y + 7 + CGFloat(i) * 4, wide, 1, ink) }
            c.fill(x + (w / 2).rounded() - 1, y + 1, 2, 2, graphite.base)
        }
        note(board.minX + 9, board.minY + 8, 20, 22, white.top, lines: [14, 11, 13], ink: white.front)
        note(board.minX + 34, board.minY + 13, 18, 15, white.front, lines: [12, 9], ink: white.base)
        note(board.minX + 57, board.minY + 7, 15, 19, white.top, lines: [9, 7, 9], ink: white.front)
    }

    // A backrest with a seam per seat, an arm at each end, the seat cushions with a seam between, four short legs.
    func seat(
        _ b: OfficeBrush, left: CGFloat, seats: Int, pitch: CGFloat, arm: CGFloat, edge: CGFloat, back: CGFloat, deep: CGFloat,
        _ tone: OfficePalette.Tone, legs: OfficePalette.Tone
    ) {
        let c = b.c, line = b.p.line
        let wide = 2 * arm + CGFloat(seats) * pitch, front: CGFloat = deep >= 9 ? 6 : 4, n = CGFloat(seats) * pitch
        shadow(b, left - 2, edge + front - 1, wide + 4, 8)
        for x in [left + 2, left + wide - 5] {  // the front legs, at the corners
            c.fill(x - 1, edge + front, 5, 4, line)
            c.fill(x, edge + front, 3, 3, legs.front)
        }
        for x in [left + 6, left + wide - 8] {  // the back legs, just inside the front ones, in shade
            c.fill(x - 1, edge + front, 4, 3, line)
            c.fill(x, edge + front, 2, 2, legs.base)
        }
        b.box(left, edge - deep - back, wide, back + 2, top: 4, tone, round: 2, base: false)
        for i in 1..<seats { c.fill(left + arm + CGFloat(i) * pitch, edge - deep - back + 5, 1, back - 4, tone.base) }
        b.box(left + arm, edge - deep, n, deep + front + 1, top: deep, tone)
        for i in 1..<seats { c.fill(left + arm + CGFloat(i) * pitch, edge - deep, 1, deep + front, line) }
        for x in [left, left + wide - arm] { b.box(x, edge - deep - back / 2, arm, deep + back / 2 + front + 1, top: 3, tone, round: 2) }
    }

    func desk(_ b: OfficeBrush, x: CGFloat, floor: CGFloat, slab: CGFloat, chair cx: CGFloat, working: Bool) {
        let c = b.c, look = b.p, white = look.white
        shadow(b, x - 2, floor - 3, slab + 4)
        for lx in [x + 3, x + slab - 6] {
            c.fill(lx - 1, floor - 26, 5, 27, look.line)
            c.fill(lx, floor - 26, 3, 26, white.front)
            c.fill(lx, floor - 26, 1, 26, white.top)
        }
        b.box(x, floor - 34, slab, 9, top: 5, white)
        // The monitor: a thin light bezel with a chin, a small stand.
        c.fill(x + 17, floor - 36, 16, 3, look.line)
        c.fill(x + 18, floor - 35, 14, 1, white.front)
        c.fill(x + 22, floor - 42, 6, 7, look.line)
        c.fill(x + 23, floor - 42, 4, 7, white.front)
        c.fill(x + 6, floor - OfficePainter.monitorTop, 38, 26, look.line)
        c.fill(x + 7, floor - 65, 36, 24, white.front)
        c.fill(x + 7, floor - 65, 36, 1, white.top)
        c.fill(x + 8, floor - 64, 34, 20, working ? 0x2F6B55 : look.graphite.base)
        if working {
            c.fill(x + 11, floor - 61, 18, 3, OfficeLook.work)
            c.fill(x + 11, floor - 56, 24, 3, OfficeLook.work)
            c.fill(x + 11, floor - 51, 12, 3, OfficeLook.work)
        }
        // The chair, from behind, where its sitter stands.
        let chair = look.chair
        c.block(cx - 12, floor - 28, 24, 21, look.line, notch: 2)
        c.block(cx - 11, floor - 27, 22, 19, chair.front, notch: 2)
        c.fill(cx - 9, floor - 27, 18, 2, chair.top)
        c.fill(cx - 14, floor - 9, 28, 4, look.line)
        c.fill(cx - 13, floor - 8, 26, 2, chair.front)
        c.fill(cx - 2, floor - 5, 4, 10, look.line)
        c.fill(cx - 1, floor - 5, 2, 10, chair.front)
        c.fill(cx - 12, floor + 4, 24, 4, look.line)
        c.fill(cx - 11, floor + 5, 22, 2, chair.front)
    }

    func rug(_ b: OfficeBrush, top: CGFloat, room: CGSize) {
        b.c.block(2, top, room.width - 4, room.height - 4 - top, b.p.rugEdge, notch: 4)
        b.c.block(3, top + 1, room.width - 6, room.height - 6 - top, b.p.rug, notch: 3)
    }

    func yourDesk(_ b: OfficeBrush, left ux: CGFloat, width uw: CGFloat, height H: CGFloat) {
        let c = b.c, look = b.p, white = look.white, ash = look.ash, graphite = look.graphite, chair = look.chair
        let uf = H - 33, cx = ux + 77
        shadow(b, ux - 2, uf - 3, uw + 4, 6)
        for lx in [ux + 7, ux + uw - 10] {
            c.fill(lx - 1, uf - 29, 5, 29, look.line)
            c.fill(lx, uf - 29, 3, 28, white.front)
            c.fill(lx, uf - 29, 1, 28, white.top)
            c.fill(lx - 6, uf - 3, 15, 4, look.line)
            c.fill(lx - 5, uf - 2, 13, 2, white.front)
            c.fill(lx - 5, uf - 2, 13, 1, white.top)
        }
        b.box(ux, uf - 44, uw, 15, top: 11, ash)
        // The lamp, at the left: a foot, an upright, an arm, a head; its bulb a line of warm white under the head.
        b.box(ux + 8, uf - 41, 11, 2, top: 1, chair)
        c.fill(ux + 12, uf - 70, 4, 30, look.line)
        c.fill(ux + 13, uf - 69, 2, 29, chair.front)
        c.fill(ux + 12, uf - 71, 17, 4, look.line)
        c.fill(ux + 13, uf - 70, 15, 2, chair.front)
        b.box(ux + 25, uf - 70, 10, 6, top: 2, chair, round: 1)
        c.fill(ux + 26, uf - 63, 8, 1, white.top)
        // The monitor, wide, in a light bezel on a small stand; the keyboard and mouse in front of it.
        b.box(cx - 8, uf - 43, 16, 1, top: 1, white)
        c.fill(cx - 3, uf - 51, 6, 8, look.line)
        c.fill(cx - 2, uf - 51, 4, 8, white.front)
        c.fill(cx - 27, uf - 78, 54, 28, look.line)
        c.fill(cx - 26, uf - 77, 52, 26, white.front)
        c.fill(cx - 26, uf - 77, 52, 1, white.top)
        c.fill(cx - 24, uf - 75, 48, 20, graphite.base)
        c.fill(cx - 20, uf - 72, 20, 3, OfficeLook.call)
        c.fill(cx - 20, uf - 67, 36, 3, look.paper)
        c.fill(cx - 20, uf - 62, 16, 3, OfficeLook.work)
        b.box(cx - 19, uf - 39, 38, 3, top: 1, chair)
        b.box(cx + 22, uf - 39, 4, 3, top: 1, chair, round: 1)
        // Papers, two sheets, and the mug.
        for (dx, dy) in [(CGFloat(4), CGFloat(1)), (0, 0)] {
            b.box(ux + 112 + dx, uf - 42 + dy, 18, 8, top: 8, white, base: false)
        }
        for i in 0..<3 { c.fill(ux + 114, uf - 40 + CGFloat(i) * 2, i == 2 ? 8 : 13, 1, white.front) }
        b.box(ux + 140, uf - 49, 8, 9, top: 2, white, round: 1)
        c.fill(ux + 149, uf - 47, 3, 6, look.line)
        c.fill(ux + 149, uf - 46, 2, 4, white.front)
        // Your chair, high-backed, at the room's front edge: you sit facing everyone.
        b.box(cx - 10, H - 67, 20, 8, top: 2, chair, round: 2)
        c.fill(cx - 3, H - 59, 6, 4, look.line)
        c.fill(cx - 2, H - 59, 4, 4, chair.front)
        b.box(cx - 19, H - 55, 38, 35, top: 3, chair, round: 3)
        c.fill(cx - 15, H - 31, 30, 1, chair.base)
        for ax in [cx - 24, cx + 20] { b.box(ax, H - 39, 4, 17, top: 2, chair, round: 1) }
        b.box(cx - 22, H - 21, 44, 3, top: 1, chair)
        c.fill(cx - 2, H - 18, 4, 9, look.line)
        c.fill(cx - 1, H - 18, 2, 9, chair.front)
        b.box(cx - 18, H - 10, 36, 2, top: 1, chair)
        for wx in [cx - 20, cx - 2, cx + 16] { b.box(wx, H - 7, 4, 3, top: 1, chair, round: 1) }
    }

    // In a shirt, arms at its sides.
    func person(_ b: OfficeBrush, x: CGFloat, y: CGFloat, variant: Int) {
        OfficePeople.draw(b, x: x, y: y, variant: variant, rows: [
            "..hhhh..", ".hhhhhh.", ".hssssh.", ".sesses.", "..ssss..", "..tttt..", ".tttttt.",
            "tttttttt", "tttttttt", "stttttts", ".pppppp.", ".pp..pp.", ".pp..pp.", ".bb..bb.",
        ])
    }

    func label(_ b: OfficeBrush, _ words: CGRect) {}
}

/// The little people both themes draw for subagents: not a pet made small (those turn to mush at this size and would
/// pass for the session's own pet), but a person drawn a point to the pixel from `rows`, outlined in `line`. Four
/// shirts and hairs, all from the furniture's families, so none reads as a status colour.
@MainActor enum OfficePeople {
    static func draw(_ b: OfficeBrush, x: CGFloat, y: CGFloat, variant: Int, rows: [String]) {
        let c = b.c, look = b.p
        let dress: [(hair: UInt32, shirt: UInt32)] = [
            (look.graphite.base, look.mustard.front), (look.ash.base, look.white.top), (look.mustard.base, look.chair.front),
            (look.graphite.base, look.ash.front),
        ]
        let (hair, shirt) = dress[variant % dress.count]
        let cells = rows.map(Array.init)
        let hue: [Character: UInt32] = ["h": hair, "s": OfficeLook.skin, "e": look.ink, "t": shirt, "p": look.graphite.front, "b": look.line]
        for (r, row) in cells.enumerated() {
            for (i, ch) in row.enumerated() where ch != "." { c.fill(x + CGFloat(i) - 1, y + CGFloat(r) - 1, 3, 3, look.line) }
        }
        for (r, row) in cells.enumerated() {
            for (i, ch) in row.enumerated() { if let hex = hue[ch] { c.fill(x + CGFloat(i), y + CGFloat(r), 1, 1, hex) } }
        }
    }
}

/// A part of the picture painted on its own: the live view shows it as a layer, and the still
/// picture is put together from the same parts, so both show the same pixels. Where it goes in the
/// room, and how see-through.
struct OfficePiece {
    let image: CGImage
    let rect: CGRect
    var alpha: CGFloat = 1
}

/// A pet as the room shows it at rest: its pose's still frame, or a grey block while its frames
/// are being cut; its shadow; and the scale every one of its frames is shown at, so that its loop
/// and its walk fit the same spot.
struct OfficeFigure {
    let sprite: OfficePiece
    let shadow: OfficePiece?
    /// Nil for the grey block.
    let pet: String?
    let scale: CGFloat
    /// How wide the pet is drawn, its pixels' own width in this pose: what its shadow and the light on it are measured by.
    var wide: CGFloat = 20
    /// How tall it is drawn, its pixels' own height in this pose: the light hangs a little above its head.
    var high: CGFloat = 26
}

/// Paints the office: the room, and each pet's figure and words. The live view shows these as
/// layers; the still picture, for snapshots, is all of them put together.
@MainActor enum OfficePainter {
    /// Where everyone is in a room this tall, with cards sized for words shown at this scale. Everyone
    /// keeps the seat they had in `previous`, or else in the room last laid out for this store.
    static func layout(_ store: Store, now: Date, height: CGFloat = 764, scale: CGFloat = 1, previous: OfficeLayout? = nil) -> OfficeLayout {
        let groups = Buckets(store, now: now)
        // An error not looked at sits on the sofas with the news (its plate red or amber); an unexpected exit stands at its
        // own desk with the looked-at ones (faint, its plate grey).
        let layout = OfficeLayout(
            waiting: groups.waiting.map(\.id), unread: (groups.unread + groups.failed).map(\.id), busy: groups.busy.map(\.id),
            seen: (groups.seen + groups.gone).map(\.id), resting: groups.resting.map(\.id), height: height, scale: scale, now: now,
            previous: previous ?? OfficeSeats.previous(for: store))
        // An extension's scene, when it is the theme, lays the same groups out in its own places.
        return Extensions.active?.project(layout, previous: previous ?? OfficeSeats.previous(for: store)) ?? layout
    }

    /// The picture as it will be shown at `scale` (screen points per picture point): words are
    /// painted large enough to keep their size on screen. Their boxes stay tied to the seats,
    /// so at small sizes names are cut sooner, and project lines under the sitters are left out
    /// below 90%. Pass the layout made for the same scale.
    static func picture(_ store: Store, _ layout: OfficeLayout, now: Date, scale: CGFloat = 1) -> CGImage? {
        let c = OfficeCanvas(layout.size)
        drawRoom(c, store, layout, scale: scale)
        let byID = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Back to front, each with its words, so a nearer pet covers a farther one's words and not
        // the other way round.
        // The desks' walkers, caught `BGWalker.stillTime` into their walk, drawn among the pets by depth as the live room does.
        var pending = walkers(store, layout).compactMap { w in
            walkerLayer(w, layout: layout, mode: .caught(BGWalker.stillTime), caughtAt: BGWalker.stillTime).map { (z: $0.zPosition, layer: $0) }
        }.sorted { $0.z < $1.z }
        func drawWalkers(upTo z: CGFloat) {
            while let first = pending.first, first.z <= z {
                pending.removeFirst()
                for part in first.layer.sublayers ?? [] {
                    guard let image = part.contents as AnyObject?, CFGetTypeID(image) == CGImage.typeID else { continue }
                    let rect = CGRect(x: part.position.x - part.bounds.width / 2, y: part.position.y - part.bounds.height / 2, width: part.bounds.width, height: part.bounds.height)
                    c.image(image as! CGImage, in: rect, alpha: CGFloat(part.opacity))
                }
            }
        }
        for place in layout.pets.sorted(by: inFront) {
            guard let s = byID[place.id] else { continue }
            drawWalkers(upTo: place.foot)
            let figure = self.figure(store, s, place, now: now)
            if let shadow = figure.shadow { c.image(shadow.image, in: shadow.rect) }
            c.image(figure.sprite.image, in: figure.sprite.rect, alpha: figure.sprite.alpha)
            if let words = words(store, s, place, layout, now: now, scale: scale) { c.image(words.image, in: words.rect) }
        }
        drawWalkers(upTo: .infinity)
        if let chips = chips(store, layout, scale: scale) { c.image(chips.image, in: chips.rect) }
        return c.image()
    }

    /// Further down the room is nearer: drawn later, in front.
    static func inFront(_ a: OfficeLayout.Pet, _ b: OfficeLayout.Pet) -> Bool { (a.foot, a.x) < (b.foot, b.x) }

    /// The desk seats whose screens are lit: where someone at work sits, and the desk kept for one at work that
    /// stays a while at your desk after an answer.
    static func lit(_ store: Store, _ layout: OfficeLayout) -> [Int] {
        let working = Set(store.sessions.filter { $0.isWorking }.map(\.id))
        let sitting = layout.pets.filter { $0.zone == .desk && working.contains($0.id) }.map(\.seat)
        return (sitting + layout.reserved.filter { working.contains($0.key) }.map(\.value)).sorted()
    }

    /// Everything the room is painted from. A pet walking, or being pointed at, changes none of it.
    static func roomKey(_ store: Store, _ layout: OfficeLayout, scale: CGFloat) -> String {
        // The queue's eighth card names who waits beyond it.
        let chips = layout.chips.map { "\($0.kind) \($0.count) \($0.rect)" }.joined(separator: " ") + " " + layout.waitingElsewhere.prefix(3).joined()
        return "\(OfficeTheme.current.key) \(layout.height) \(OfficeLook.step(min(1, scale))) \(layout.behindDoor) \(lit(store, layout)) \(helpers(store, layout))"
            + " \(store.sessions.isEmpty) \(layout.counts) \(chips) \(store.activity.unseen > 0) \(layout.sceneDriven ? Extensions.registered?.roomKey ?? "" : "")"
    }

    /// The desk seats with someone's subagents sitting on them, and how many each: `Store.agentCounts` for whoever is at
    /// their own desk.
    static func helpers(_ store: Store, _ layout: OfficeLayout) -> [(seat: Int, count: Int)] {
        layout.pets.filter { $0.zone == .desk && $0.host == nil }.compactMap { pet in
            store.sessions.first { $0.id == pet.id }.flatMap { store.helpers(of: $0) }.flatMap { $0 > 0 ? (pet.seat, $0) : nil }
        }.sorted { $0.seat < $1.seat }
    }

    /// A desk's walkers: whose, the pets of its helpers (three at most walk), and whether they stand hung.
    struct DeskWalkers: Equatable {
        let seat: Int
        let id: String
        let pets: [String]
        let hung: Bool
    }

    static func walkers(_ store: Store, _ layout: OfficeLayout) -> [DeskWalkers] {
        layout.pets.filter { $0.zone == .desk && $0.host == nil }.compactMap { pet in
            guard let s = store.sessions.first(where: { $0.id == pet.id }) else { return nil }
            let pets = store.walkerPets(of: s)
            return pets.isEmpty ? nil : DeskWalkers(seat: pet.seat, id: pet.id, pets: Array(pets.prefix(3)), hung: s.isBackgroundHung)
        }.sorted { $0.seat < $1.seat }
    }

    /// Where a desk's lane is, in the room's points: along the desk's front edge, clear of the monitor's foot and of the
    /// pet at the chair; the walkers' feet, one height.
    static func deskLane(seat: Int, layout: OfficeLayout) -> (from: CGPoint, to: CGPoint) {
        let fill = [3, 4, 2, 5, 1, 6, 0, 7]
        let x = OfficeLayout.deskLeft(fill[seat % 8]) + 1, floor = layout.deskFloors[seat / 8]
        return (CGPoint(x: x + 6, y: floor - 27), CGPoint(x: x + 72, y: floor - 27))
    }

    static let walkerHeight: CGFloat = 19

    /// A desk's walkers as layers in a holder at the stage's origin (their frames are the room's points), as deep as their
    /// feet. `mode`: how they are shown. Nil for a pet's frames not yet cut.
    static func walkerLayer(_ w: DeskWalkers, layout: OfficeLayout, mode: BGWalker.Mode, caughtAt: Double) -> CALayer? {
        let lane = deskLane(seat: w.seat, layout: layout)
        let holder = CALayer()
        holder.name = "walkers \(w.seat)"
        holder.bounds = .zero
        holder.zPosition = lane.from.y
        for (i, pet) in w.pets.enumerated() {
            guard let cut = BGWalker.cut(pet, tall: walkerHeight) else { return nil }
            let from = CGPoint(x: lane.from.x + cut.inkWide / 2, y: lane.from.y), to = CGPoint(x: max(from.x, lane.to.x - cut.inkWide / 2), y: lane.to.y)
            let how: BGWalker.Mode = w.hung ? .hung : { if case .caught = mode { return .caught(caughtAt) }; return mode }()
            let rest = w.pets.count > 1 ? 0.15 + 0.7 * CGFloat(i) / CGFloat(w.pets.count - 1) : 0.5
            guard let layer = BGWalker.layer(cut, from: from, to: to, yDown: true, mode: how, phase: BGWalker.phase(w.id, i), rest: rest) else { return nil }
            holder.addSublayer(layer)
        }
        return holder
    }

    /// How tall the furniture the floor labels sit over stands above its sitters' feet (or, for a desk, its floor): the
    /// couches' and the sofas' backs and the monitors, outline included. `drawRoom` draws them to these.
    static let couchBack: CGFloat = 18, couchDeep: CGFloat = 7, sofaBack: CGFloat = 26, sofaDeep: CGFloat = 10, monitorTop: CGFloat = 66
    /// A desk's top, outline to outline 2 more: from its column's edge to short of the next column's.
    static let deskSlab: CGFloat = 124

    /// The room with its furniture, the lit screens and the door's number: everything but the pets and the chips.
    static func room(_ store: Store, _ layout: OfficeLayout, scale: CGFloat) -> CGImage? {
        let c = OfficeCanvas(layout.size)
        drawRoom(c, store, layout, scale: scale)
        return c.image()
    }

    /// For the overlap check: when set, `drawRoom` puts here the bounds of every piece it draws, by name (shadows and the
    /// rug, which are floor, left out).
    static var parts: [String: [CGRect]]?

    /// The quiet labels on the floor, each part of the room with its count, where `drawRoom` writes them.
    static func floorLabels(_ layout: OfficeLayout, scale: CGFloat) -> [(text: String, count: Int, rect: CGRect, hex: UInt32, alpha: CGFloat)] {
        let size = OfficeLook.type(10.5, scale: scale), high = OfficeLook.lineHeight(size), counts = layout.counts
        let measure = OfficeCanvas(CGSize(width: 1, height: 1)), faint = OfficeTheme.current.palette.faint
        func label(_ text: String, _ count: Int, x: CGFloat, y: CGFloat, _ hex: UInt32? = nil, _ alpha: CGFloat = 1)
            -> (String, Int, CGRect, UInt32, CGFloat)
        {
            let words = "\(text) \(count)"
            return (words, count, CGRect(x: x, y: y, width: measure.width(of: words, size: size, weight: .medium) + 2, height: high), hex ?? faint, alpha)
        }
        // All on one margin left of the grid, each just over the first piece of its band; for your corner, level with the
        // cards' names: the head of their row.
        return [
            label(L10n.string("wall.resting", table: "Office", zh: "休息"), counts.resting, x: 4, y: layout.loungeFloors[0] - 3 - couchDeep - couchBack - 1 - 2 - high),
            label(L10n.string("wall.desks", table: "Office", zh: "工位"), counts.desks, x: 4, y: layout.deskFloors[0] - monitorTop - 2 - high),
            label(L10n.string("wall.news", table: "Office", zh: "有话说"), counts.news, x: 4, y: layout.sofaFloor - 4 - sofaDeep - sofaBack - 1 - 2 - high),
            label(L10n.string("wall.waiting", table: "Office", zh: "在等你"), counts.waiting, x: 4, y: layout.cardTop + OfficeLayout.cardPad, OfficeLook.call, 0.8),
        ].map { (text: $0.0, count: $0.1, rect: $0.2, hex: $0.3, alpha: $0.4) }
    }

    private static func drawRoom(_ c: OfficeCanvas, _ store: Store, _ layout: OfficeLayout, scale: CGFloat) {
        let theme = OfficeTheme.current, look = theme.palette, furniture = theme.furniture, b = OfficeBrush(c: c, p: look)
        if layout.sceneMode, Extensions.registered?.drawRoom(c, store, layout, scale: scale) == true { return }
        let size = layout.size, W = size.width, H = size.height
        func type(_ base: CGFloat) -> CGFloat { OfficeLook.type(base, scale: scale) }
        func line(_ size: CGFloat) -> CGFloat { OfficeLook.lineHeight(size) }

        // Each piece is drawn on its own so the overlap check can measure it.
        func part(_ name: String, _ draw: () -> Void) {
            guard parts != nil else { return draw() }
            var drawn: [CGRect] = []
            c.tally = { drawn.append($0) }
            draw()
            c.tally = nil
            parts?[name] = drawn
        }

        // ── The back wall: two windows on the dusk, the notice board, the lounge door, a baseboard under them.
        c.fill(0, 0, W, 70, look.wall)
        c.fill(0, 62, W, 8, look.skirting)
        c.fill(0, 62, W, 1, look.graphite.front)  // the baseboard's top edge
        c.fill(0, 70, W, H - 70, look.floor)
        if look.wallShade > 0 { c.fill(0, 70, W, 6, 0x000000, OfficeLook.shade * look.wallShade) }
        furniture.ground(c, layout, look)
        // Each window 56 of the wall's 70 tall.
        for (i, left) in [CGFloat(166), 516].enumerated() {
            part("window \(i)") { furniture.window(b, left: left, first: i == 0) }
        }

        // The door to the lounge. Whoever does not fit in the room is behind it: the plate says how many.
        let door = OfficeLayout.door
        part("door") {
            furniture.door(b, door)
            let label = layout.behindDoor > 0 ? L10n.format("door.lounge.more", table: "Office", zh: "休息室 +%lld", layout.behindDoor) : L10n.string("door.lounge", table: "Office", zh: "休息室")
            let doorSize = type(11), doorWidth = c.width(of: label, size: doorSize) + 14
            c.card(
                CGRect(x: 1042 - doorWidth / 2, y: 15, width: doorWidth, height: line(doorSize) + 3), radius: 5, look.graphite.base, edge: look.line)
            c.text(
                label, in: CGRect(x: 1042 - doorWidth / 2, y: 16.5, width: doorWidth, height: line(doorSize)), size: doorSize, look.white.top,
                align: .center)
        }

        // The notice board: what happened lately is pinned up here, and pointing at it shows the list. A paper dot says
        // something came since it was last pointed at; no number, and not coral, which in this room means someone waits.
        part("board") { furniture.board(b, OfficeLayout.board) }
        if store.activity.unseen > 0 {
            let mark = OfficeLayout.boardMark
            c.block(mark.minX, mark.minY, mark.width, mark.height, look.line, notch: 2)
            c.block(mark.minX + 1, mark.minY + 1, mark.width - 2, mark.height - 2, look.paper, notch: 2)
        }

        // ── At the back: two rows of couches, one a block, always whole whether anyone rests there or not, faint.
        let slate = look.slate
        for row in 0..<2 {
            let edge = layout.loungeFloors[row] - 3
            for (side, block) in OfficeLayout.blockLefts.enumerated() {
                part("couch \(row)-\(side)") {
                    furniture.seat(
                        b, left: block + 1, seats: 5, pitch: OfficeLayout.couchPitch, arm: OfficeLayout.couchArm, edge: edge, back: couchBack,
                        deep: couchDeep, slate, legs: OfficePalette.Tone(top: slate.top, front: slate.top, base: slate.front))
                }
            }
        }

        // ── Two rows of desks: a slab on two light legs, a monitor (its screen lit green: someone works here), and in
        // front the back of its chair, which whoever stands there covers. Each desk starts on its column's edge, so the
        // first of a block lines up with the couches and the sofas.
        let lit = Set(self.lit(store, layout))
        let fill = [3, 4, 2, 5, 1, 6, 0, 7], slab = deskSlab
        let helping = Dictionary(helpers(store, layout).map { ($0.seat, $0.count) }, uniquingKeysWith: { first, _ in first })
        for seat in 0..<16 {
            let d = OfficeLayout.deskLeft(fill[seat % 8]), x = d + 1, floor = layout.deskFloors[seat / 8]
            part("desk \(seat)") { furniture.desk(b, x: x, floor: floor, slab: slab, chair: d + 88, working: lit.contains(seat)) }
            // Its sitter's helpers, while they run (subagents, and background work): little people walking the desk's
            // front edge, up to three, are layers of their own (`walkers`); here only how many more, on a tag hanging under
            // the edge, between the desk's legs: beside the third, a wide pet standing at the desk would cover it.
            if let count = helping[seat] {
                part("agents \(seat)") {
                    if count > 3 {
                        let size = type(8.5), words = "+\(count - 3)", wide = c.width(of: words, size: size) + 8
                        let r = CGRect(x: x + 20, y: floor - 23, width: wide, height: line(size) + 2)
                        c.card(r, radius: r.height / 2, look.plate, edge: look.plateEdge)
                        c.text(words, in: CGRect(x: r.minX, y: r.minY + 1, width: wide, height: line(size)), size: size, 0xFFFFFF, align: .center)
                    }
                }
            }
        }

        // ── The sofa band: the four sofas of "Has news", two a block, from block edge to block edge, on light wooden legs.
        // The gap between the pairs is the aisle's and stays open: it is the way down into your corner.
        let edge = layout.sofaFloor - 4
        for (i, left) in OfficeLayout.sofaLefts.enumerated() {
            part("sofa \(i)") {
                furniture.seat(
                    b, left: left, seats: 3, pitch: OfficeLayout.sofaPitch, arm: OfficeLayout.sofaArm, edge: edge, back: sofaBack, deep: sofaDeep,
                    look.mustard, legs: look.ash)
            }
        }

        // ── Your corner: a rug under the whole bottom band, from just inside the walls (the labels' margin is on it), your
        // desk at its left, facing up the room, no larger than it needs to be; the queue along the bottom. Its monitor
        // shows who waits (coral), who has news (paper) and who works (green); in front, your empty chair, from behind.
        furniture.rug(b, top: layout.rugTop, room: size)
        part("your desk") { furniture.yourDesk(b, left: OfficeLayout.yourDesk.minX, width: OfficeLayout.yourDesk.width, height: H) }

        // ── Labels on the floor; at half strength with nobody in their part.
        let labelSize = type(10.5)
        for label in floorLabels(layout, scale: scale) {
            furniture.label(b, label.rect)
            c.text(label.text, in: label.rect, size: labelSize, weight: .medium, label.hex, label.count > 0 ? label.alpha : label.alpha / 2)
        }
        if store.sessions.isEmpty {
            c.text(
                L10n.string("office.empty", table: "Office", zh: "现在没有打开的会话。在 Orca 里开一个，它就会走进来。"),
                in: CGRect(x: OfficeLayout.queueLeft, y: layout.rugTop + 40, width: W - OfficeLayout.queueLeft - 8, height: line(type(12)) + 2),
                size: type(12), weight: .regular, look.faint, align: .center, wraps: true)
        }
    }

    /// The chips, over the room and the pets, so one walking past the queue's eighth place along the right wall passes
    /// behind the chip there, as behind the cards. Nil without any.
    static func chips(_ store: Store, _ layout: OfficeLayout, scale: CGFloat) -> OfficePiece? {
        guard !layout.chips.isEmpty else { return nil }
        let area = layout.chips.reduce(CGRect.null) { $0.union($1.rect).union($1.rect.offsetBy(dx: 8, dy: 6)) }
        return piece(area) { c in drawChips(c, store, layout, scale: scale) }
    }

    // Chips for who needs you or works but has no place where their kind belongs: a click goes to the board. Those waiting
    // beyond the queue's seven take its eighth place, as a coral card like the others, in their ink, with the next cards
    // showing behind it to the lower right: the queue goes on. Not upward: over it are the sofas' words.
    private static func drawChips(_ c: OfficeCanvas, _ store: Store, _ layout: OfficeLayout, scale: CGFloat) {
        if layout.sceneMode, let scene = Extensions.registered { return scene.drawChips(c, layout, scale: scale) }

        let look = OfficeTheme.current.palette
        func type(_ base: CGFloat) -> CGFloat { OfficeLook.type(base, scale: scale) }
        func line(_ size: CGFloat) -> CGFloat { OfficeLook.lineHeight(size) }
        let chipSize = type(11)
        for chip in layout.chips {
            let r = chip.rect, text = chip.kind.text(chip.count)
            switch chip.kind {
            case .waiting:
                c.card(r.offsetBy(dx: 8, dy: 6), radius: 10, OfficeLook.call, 0.45, edge: look.line)
                c.card(r.offsetBy(dx: 4, dy: 3), radius: 10, OfficeLook.call, 0.75, edge: look.line)
                c.card(r.offsetBy(dx: 1, dy: 4), radius: 10, 0x000000, OfficeLook.shade)
                c.card(r, radius: 10, OfficeLook.call)
                let pad = OfficeLayout.cardPad, left = r.minX + pad, wide = r.width - 2 * pad, title = type(OfficeLayout.cardType.name)
                c.text(text, in: CGRect(x: left, y: r.minY + pad, width: wide, height: line(title)), size: title, look.ink)
                let byID = Dictionary(store.sessions.map { ($0.id, $0.shownName) }, uniquingKeysWith: { first, _ in first })
                let names = layout.waitingElsewhere.prefix(3).compactMap { byID[$0] }, more = layout.waitingElsewhere.count > 3
                let small = type(OfficeLayout.cardType.ask), step = line(small) + 1, room = r.maxY - pad - (r.minY + pad + 2 + line(title))
                let area = CGRect(x: left, y: r.minY + pad + 2 + line(title), width: wide, height: room)
                if room >= 3 * step {  // a name a line
                    for (i, name) in names.enumerated() {
                        let words = name + (more && i == names.count - 1 ? " …" : "")
                        c.text(
                            words, in: CGRect(x: left, y: area.minY + CGFloat(i) * step, width: wide, height: line(small)), size: small, weight: .medium,
                            look.ink, 0.92)
                    }
                } else {  // or one after the other, wrapped
                    c.text(names.joined(separator: "、") + (more ? "…" : ""), in: area, size: small, weight: .medium, look.ink, 0.92, wraps: true)
                }
                continue
            case .news: c.card(r, radius: r.height / 2, look.paper, edge: look.line)
            case .work:
                c.card(r, radius: r.height / 2, look.plate, edge: look.plateEdge)
                c.card(CGRect(x: r.minX + 8, y: r.midY - 3, width: 6, height: 6), radius: 3, OfficeLook.work)
            }
            let inset: CGFloat = chip.kind == .work ? 18 : 8
            c.text(
                text, in: CGRect(x: r.minX + inset, y: r.minY + 2, width: r.width - inset - 8, height: line(chipSize)), size: chipSize,
                chip.kind == .work ? 0xFFFFFF : look.ink, align: .center)
        }
    }

    /// Paints something in a bitmap of its own: `area`, rounded out to whole pixels with a little
    /// room for type, so it lands on the very pixels the whole picture would give it.
    private static func piece(_ area: CGRect, alpha: CGFloat = 1, _ paint: (OfficeCanvas) -> Void) -> OfficePiece? {
        let r = area.insetBy(dx: -2, dy: -2)
        let left = (r.minX * 2).rounded(.down) / 2, top = (r.minY * 2).rounded(.down) / 2
        let whole = CGRect(x: left, y: top, width: (r.maxX * 2).rounded(.up) / 2 - left, height: (r.maxY * 2).rounded(.up) / 2 - top)
        let c = OfficeCanvas(whole)
        paint(c)
        return c.image().map { OfficePiece(image: $0, rect: whole, alpha: alpha) }
    }

    /// A pet in its pose, standing on its shadow. Pets are drawn at very different sizes inside
    /// their frames, so each part of the room gives them one height: by how tall they stand when
    /// idle, or by this pose if it is drawn much smaller. Every frame of the pet is shown at that
    /// scale, in the same spot, so a loop or a walk keeps its feet on the floor.
    static func figure(_ store: Store, _ s: Session, _ place: OfficeLayout.Pet, now: Date) -> OfficeFigure {
        // In an extension's scene: its own figure for the character, if it has one.
        if let scene = Extensions.active, let figure = scene.figure(store, s, place) { return figure }
        let look = OfficeLook.self
        let pose = place.sceneSlot != nil && place.kind == .work ? Pose.standing.sheet : store.pose(of: s, now: now).sheet
        let pets = OfficePets.shared
        guard let name = store.displayPets[s.id], let frame = pets.frame(name, row: pose.row, column: pose.still) else {
            return block(place)
        }
        let idle = pets.frame(name, row: 0, column: 0) ?? frame
        // Its own size for this pose, then the same share smaller in every pose for a pet one of whose poses would stand
        // taller than the rows are spaced for, or crowd the next seat on a sofa or a couch.
        let seated = place.zone == .sofa || place.zone == .lounge
        // Times its pet.json's own size (`OfficePets.size`, 1 for nearly every pet); its shadow, walk, lights and the
        // room's measure of it (`OfficeFigure.high` / `wide`) all go by the result.
        let scale: CGFloat
        if place.sceneSlot != nil {
            scale=min(place.tall/CGFloat(frame.tall),place.tall*1.05/CGFloat(frame.wide)) * pets.size(name)
        } else {
            scale=OfficePets.scale((frame.tall,frame.wide),idle:(idle.tall,idle.wide),tall:place.tall)
                * pets.fit(name,tall:place.tall,wide:seated ? OfficeLayout.sofaPitch : nil) * pets.size(name)
        }
        guard let image = pets.scaled(name, row: pose.row, column: pose.still, scale: scale) else { return block(place) }
        let wide = CGFloat(frame.wide) * scale
        let x = ((place.x - CGFloat(frame.left + frame.right + 1) / 2 * scale) * 2).rounded() / 2
        let y = ((place.foot - CGFloat(frame.bottom + 1) * scale) * 2).rounded() / 2
        let rect = CGRect(x: x, y: y, width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
        // One that exited unexpectedly stands faint (45%).
        let sprite = OfficePiece(image: image, rect: rect, alpha: s.isGone ? 0.45 : place.asleep ? Extensions.active?.sleeperAlpha ?? 0.4 : 1)
        let shadow = piece(CGRect(x: place.x - wide * 0.4, y: place.foot - 4, width: wide * 0.8, height: 8)) { c in
            c.block(place.x - wide * 0.4, place.foot - 4, wide * 0.8, 8, 0x000000, look.shade, notch: 3)
        }
        return OfficeFigure(sprite: sprite, shadow: shadow, pet: name, scale: scale, wide: wide, high: CGFloat(frame.tall) * scale)
    }

    /// Where a pet's frames are still being cut: a grey block in its place.
    private static func block(_ place: OfficeLayout.Pet) -> OfficeFigure {
        let r = CGRect(x: place.x - 10, y: place.foot - 26, width: 20, height: 26)
        let piece = piece(r) { c in c.block(r.minX, r.minY, r.width, r.height, OfficeTheme.current.palette.faint, place.asleep ? 0.4 : 1, notch: 6) }
        return OfficeFigure(sprite: piece!, shadow: nil, pet: nil, scale: 1)
    }

    /// What is written under a pet, or over it on a card when it waits for you.
    static func words(
        _ store: Store, _ s: Session, _ place: OfficeLayout.Pet, _ layout: OfficeLayout, now: Date, scale: CGFloat
    ) -> OfficePiece? {
        let look = OfficeLook.self, room = OfficeTheme.current.palette
        func type(_ base: CGFloat) -> CGFloat { OfficeLook.type(base, scale: scale) }
        func line(_ size: CGFloat) -> CGFloat { OfficeLook.lineHeight(size) }

        // A Codex session's mark follows its name, in the same ink, quieter, in a hairline frame as the card's tag is; its
        // baseline on the name's. The card's word would leave a name on a sofa's plate two characters, so a plate has the
        // short mark. The name gives way to it when the plate runs out. Without a mark (Claude Code's) the name is painted
        // at its normal size.
        let mark = kindTag(s, short: true), markSize = type(9)
        let tone = store.failTone(s)
        func markWidth(_ c: OfficeCanvas) -> CGFloat { mark.map { c.width(of: $0, size: markSize, weight: .bold) } ?? 0 }
        func markRoom(_ c: OfficeCanvas) -> CGFloat { mark == nil ? 0 : markWidth(c) + 4 + 4 }  // the frame's sides, and the gap before it
        func ascent(_ size: CGFloat, _ weight: NSFont.Weight) -> CGFloat {
            (OfficeCanvas.line("C", size, weight, 0, 1, .left, wraps: false).attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.ascender ?? size
        }
        func name(_ c: OfficeCanvas, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat, weight: NSFont.Weight = .semibold, _ hex: UInt32) {
            let after = markRoom(c)
            c.text(s.shownName, in: CGRect(x: x, y: top, width: width - after, height: line(size)), size: size, weight: weight, hex)
            guard let mark else { return }
            let left = x + min(c.width(of: s.shownName, size: size, weight: weight), width - after) + 4
            let y = top + ascent(size, weight) - ascent(markSize, .bold), wide = markWidth(c)
            let frame = CGRect(x: left, y: y + 1, width: wide + 4, height: line(markSize) - 1).insetBy(dx: 0.375, dy: 0.375)
            c.ctx.setShouldAntialias(true)
            c.ctx.addPath(CGPath(roundedRect: frame, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
            c.ctx.setStrokeColor(OfficeCanvas.rgb(hex, 0.4))
            c.ctx.setLineWidth(0.75)
            c.ctx.strokePath()
            c.text(mark, in: CGRect(x: left + 2, y: y, width: wide + 1, height: line(markSize)), size: markSize, weight: .bold, hex, 0.7)
        }
        // A name and its mark written plain on the floor, centred under the pet.
        func centred(_ c: OfficeCanvas, middle: CGFloat, top: CGFloat, widest: CGFloat, size: CGFloat, _ hex: UInt32) {
            let wide = min(widest, c.width(of: s.shownName, size: size, weight: .medium) + markRoom(c))
            name(c, x: middle - wide / 2, top: top, width: wide, size: size, weight: .medium, hex)
        }

        // Its name on a plate that says what it is: paper for news (with the pin's dot when pinned),
        // dark with a green dot at work, coral when it waits for you beyond the queue; plain when looked at.
        // On a sofa it may reach into an empty neighbour's seat (`reach`), and its name steps down a size or two
        // (`sizes`) before it is cut; elsewhere it is as it was, centred, at one size, at most `widest`.
        func plate(
            _ c: OfficeCanvas, middle: CGFloat, top: CGFloat, widest: CGFloat, reach: (left: CGFloat, right: CGFloat)? = nil,
            sizes: [CGFloat]? = nil
        ) {
            let full = type(12), high = line(full) + 3
            let pinned = place.kind == .news && store.pinned.contains(s.id)
            // A plate in an error's tone has its dot (an exit's, none); a retry keeps the desk's plate.
            let toned = tone != nil && (tone != .amber || place.kind != .work)
            let pad: CGFloat = toned ? (tone == .gone ? 12 : 20) : place.kind == .work ? 26 : pinned ? 24 : 12
            let span = reach.map { $0.left + $0.right } ?? widest
            let size = OfficeLayout.sofaPlateType(sizes: sizes ?? [full], room: span) { c.width(of: s.shownName, size: $0) + markRoom(c) + pad }
            let wide = min(span, c.width(of: s.shownName, size: size) + markRoom(c) + pad)
            let middle = reach.map { r in min(middle + r.right - wide / 2, max(middle - r.left + wide / 2, middle)) } ?? middle
            let textTop = top + 1.5 + (line(full) - line(size)) / 2
            // An error's plate brick red (white words, a white dot), the limit's amber (dark words, a dark dot), an exit's
            // grey (faint words); a retry keeps the desk's dark plate with an amber dot.
            if let tone, toned {
                let r = CGRect(x: middle - wide / 2, y: top, width: wide, height: high)
                c.card(r, radius: 6, tone.hex, tone == .gone ? 0.55 : 1)
                if tone == .gone { return name(c, x: r.minX + 6, top: textTop, width: wide - 12, size: size, room.name) }
                let ink: UInt32 = tone == .red ? 0xFFFFFF : look.ink
                c.card(CGRect(x: r.minX + 5, y: top + (high - 6) / 2, width: 6, height: 6), radius: 3, ink)
                return name(c, x: r.minX + 15, top: textTop, width: wide - 18, size: size, ink)
            }
            if place.kind == .work {
                c.card(CGRect(x: middle - wide / 2, y: top, width: wide, height: high), radius: 6, room.plate, edge: room.plateEdge)
                c.card(CGRect(x: middle - wide / 2 + 7, y: top + (high - 6) / 2, width: 6, height: 6), radius: 3, tone == .amber ? tone!.hex : look.work)
                name(c, x: middle - wide / 2 + 18, top: textTop, width: wide - 24, size: size, 0xFFFFFF)
                return
            }
            guard place.kind == .news || place.flagged else {
                if mark != nil {
                    centred(c, middle: middle, top: textTop, widest: span, size: size, room.name)
                    return
                }
                c.text(
                    s.shownName, in: CGRect(x: middle - span / 2, y: textTop, width: span, height: line(size)), size: size, weight: .medium,
                    room.name, align: .center)
                return
            }
            c.card(
                CGRect(x: middle - wide / 2, y: top, width: wide, height: high), radius: 6, place.flagged ? look.call : room.paper,
                edge: place.flagged ? nil : room.line)
            if pinned { c.card(CGRect(x: middle - wide / 2 + 6, y: top + (high - 6) / 2, width: 6, height: 6), radius: 3, look.pin) }
            name(c, x: middle - wide / 2 + (pinned ? 16 : 6), top: textTop, width: wide - (pinned ? 22 : 12), size: size, room.ink)
        }
        func project(_ c: OfficeCanvas, in r: CGRect) {
            // An error, a retry, the limit or an exit says so in the project's place, in its tone.
            if let tone, let words = failShortWords(s) {
                let hex: UInt32 = tone == .red ? 0xFF9A8C : tone == .amber ? tone.hex : room.faint
                return c.text(words, in: r, size: type(10.5), weight: tone == .gone ? .regular : .semibold, hex, align: .center)
            }
            // At its desk with work in the background, in the project's place: how many tasks, or that they look hung.
            if s.isBackgroundWorking { return c.text(bgCountWords(s.bgTasks), in: r, size: type(10.5), weight: .semibold, look.work, align: .center) }
            if s.isBackgroundHung { return c.text(bgHungWords(), in: r, size: type(10.5), weight: .regular, room.faint, align: .center) }
            c.text(s.project, in: r, size: type(10.5), weight: .regular, room.faint, align: .center)
        }
        // In a visit, a chat mark over its head: a paper bubble with three dots, hard-edged like the furniture.
        func chat(_ c: OfficeCanvas) {
            let r = place.mark
            c.block(r.minX - 1, r.minY - 1, r.width + 2, r.height + 2, room.line, notch: 3)
            c.fill(r.minX + 5, r.maxY, 4, 3, room.line)
            c.block(r.minX, r.minY, r.width, r.height, room.paper, notch: 3)
            c.fill(r.minX + 6, r.maxY - 1, 2, 3, room.paper)
            for dx: CGFloat in [3, 8, 13] { c.fill(r.minX + dx, r.midY - 1, 2, 2, room.ink) }
        }
        // With the mark when it is in a chat; a visitor says nothing else, so as not to sit on its host's words.
        func piece(_ area: CGRect, _ paint: (OfficeCanvas) -> Void) -> OfficePiece? {
            guard place.chats else { return Self.piece(area, paint) }
            let mark = place.markArea
            return Self.piece(place.host == nil ? area.union(mark) : mark) { c in
                if place.host == nil { paint(c) }
                chat(c)
            }
        }

        // An extension's scene words its places itself, through the same `piece` (a chat mark with the words).
        if layout.sceneMode, let scene = Extensions.registered { return scene.words(store, s, place, scale: scale, now: now, piece: piece) }

        switch place.zone {
        case .lounge where place.asleep:
            let size = type(11), r = CGRect(x: place.x - 48, y: place.foot + 8, width: 96, height: line(size))
            return piece(r) { c in
                if mark != nil { return centred(c, middle: place.x, top: r.minY, widest: r.width, size: size, room.faint) }
                c.text(s.shownName, in: r, size: size, weight: .medium, room.faint, align: .center)
            }

        case .lounge:
            // Not asleep, only seated at the back for want of a place: its plate, at full strength.
            let r = CGRect(x: place.x - 48, y: place.foot + 8, width: 96, height: line(type(12)) + 3)
            return piece(r) { c in plate(c, middle: place.x, top: r.minY, widest: 96) }

        case .desk:
            let middle = place.x - 26, spots = OfficeLayout.deskWords(foot: place.foot, middle: middle, scale: scale)
            return piece(spots.plate.union(spots.project ?? spots.plate)) { c in
                plate(c, middle: middle, top: spots.plate.minY, widest: 124)
                if let r = spots.project { project(c, in: r) }
            }

        case .sofa:
            let spots = OfficeLayout.sofaWords(foot: place.foot, middle: place.x, scale: scale)
            // The piece is as wide as the plate may reach, or its ends would be cut off.
            let taken = Set(layout.pets.filter { $0.zone == .sofa && $0.id != s.id }.map(\.seat))
            let reach = OfficeLayout.sofaPlateReach(seat: place.seat, occupied: taken)
            let span = CGRect(x: place.x - reach.left, y: spots.plate.minY, width: reach.left + reach.right, height: spots.plate.height)
            return piece(spots.plate.union(spots.project ?? spots.plate).union(span)) { c in
                plate(c, middle: place.x, top: spots.plate.minY, widest: spots.plate.width, reach: reach, sizes: OfficeLayout.sofaPlateSizes.map(type))
                if let r = spots.project { project(c, in: r) }
            }

        case .queue where place.kind == .work:
            // Answered, it stays a while where it stood: its plate under it, as at its desk.
            let r = place.words
            return piece(r) { c in plate(c, middle: place.x, top: r.minY, widest: r.width) }

        case .queue:
            // The board's coral card. The name has its own line so it survives; under it the project
            // and how long it has waited; then what it asks.
            let r = place.words, lines = OfficeLayout.cardLines(r, scale: scale, asks: layout.asks)
            let tail = CGRect(x: place.x - 7, y: r.maxY - 1, width: 14, height: 9)
            let sizes = OfficeLayout.cardType
            return piece(r.union(r.offsetBy(dx: 1, dy: 4)).union(tail)) { c in
                c.card(r.offsetBy(dx: 1, dy: 4), radius: 10, 0x000000, look.shade)
                c.card(r, radius: 10, look.call)
                c.ctx.setFillColor(OfficeCanvas.rgb(look.call))
                c.ctx.beginPath()
                c.ctx.move(to: CGPoint(x: place.x - 7, y: r.maxY - 1))
                c.ctx.addLine(to: CGPoint(x: place.x + 7, y: r.maxY - 1))
                c.ctx.addLine(to: CGPoint(x: place.x, y: r.maxY + 8))
                c.ctx.closePath()
                c.ctx.fillPath()
                c.text(s.shownName, in: lines.name, size: type(sizes.name), room.ink)
                let small = type(sizes.second), wait = ago(s.since, now: now), waitWidth = c.width(of: wait, size: small, weight: .medium)
                let second = lines.second
                c.text(
                    wait, in: CGRect(x: second.maxX - waitWidth, y: second.minY, width: waitWidth, height: second.height), size: small,
                    weight: .medium, room.ink, 0.85)
                c.text(
                    s.project, in: CGRect(x: second.minX, y: second.minY, width: max(0, second.width - waitWidth - 6), height: second.height),
                    size: small, weight: .regular, room.ink, 0.85)
                let ask = s.summary.isEmpty ? timeLabel(s, now: now) : s.shownSummary
                c.text(ask, in: lines.ask, size: type(sizes.ask), weight: .regular, room.ink, 0.92, wraps: true)
            }
        }
    }
}

// ───────── In the panel ─────────

/// The office in the panel, as large as fits: the room as one layer, and over it a layer for each
/// pet holding its shadow, its sprite and its words, so a pet can loop its pose and walk to a new
/// place with nothing painted again. Core Animation moves them; this view only says where to. A ring
/// goes round whoever the pointer is on. The pointer itself is followed by the window's view
/// (`HoverTracker`), which this view tells where everyone is and, where pets overlap, who is in front.
class OfficeView: NSView, HoverResolver {
    enum Target: Equatable { case pet(String), door, chip(OfficeLayout.ChipKind), board }

    /// One pet's layers: its shadow, sprite and words, placed round its feet and moving as one.
    final class Figure {
        let layer = CALayer(), shadow = CALayer(), sprite = CALayer(), words = CALayer()
        /// For an extension's scene that moves its figures itself: the lower half of a seated figure, drawn over its seat.
        let seatedLegs=CALayer()
        /// ...its name plate, a layer of the stage's own rather than the figure's.
        let plate=CALayer()
        /// ...and whatever more that scene keeps on the figure.
        var sceneData: AnyObject?
        /// How far it has walked, and which way it faces, for that scene's gait.
        var gaitDistance:CGFloat=0
        var facesLeft=false
        /// Where it stands, or is on its way to.
        var place: OfficeLayout.Pet
        var spriteKey = "", wordsKey = ""
        /// Its pet and the scale its frames are shown at; no pet while it is a grey block.
        var pet: String?
        var scale: CGFloat = 1
        var still: CGImage?
        /// Which frame of its sheet that still one is.
        var stillFrame = (row: 0, column: 0)
        /// Its pose's frames when the pose loops, and how long each shows.
        var loop: [CGImage] = []
        var frameSeconds = 0.0
        /// Whether its pose is the jump of one that has just finished, and how long one jump takes.
        var jumps = false
        var jumpSeconds = 0.0
        /// Waiting for you and the switch on: it stands still and knocks (`WaitingNudge`), or with Reduce Motion wears `ring`.
        var knocks = false
        var ring: CAShapeLayer?
        /// When the walk it is on sets off and ends, and which walk that is.
        var departs: CFTimeInterval = 0
        var arrival: CFTimeInterval = 0
        var walks = 0
        var leaving = false
        /// The light on it while the user types in its session (`spotlight`), the drawn pet's width and height it is measured by,
        /// the look its pictures were put in for, and the size its spots' loops were drawn round.
        var beam: CALayer?
        var wide: CGFloat = 20
        var high: CGFloat = 26
        var painted: String?
        var spun: String?
        /// Its session is being restarted: it wears `spinner` and goes nowhere for it.
        var restarting = false
        var spinner: CALayer?
        /// In a scene that moves its figures itself, what the spinner hangs from: a stage layer at its feet, over all the
        /// scenery, that takes over its way through the scene.
        let carrier = CALayer()

        init(_ place: OfficeLayout.Pet) {
            self.place = place
            layer.name = place.id
            layer.bounds = .zero
            shadow.name = "shadow"
            sprite.name = "sprite"
            words.name = "words"
            for part in [shadow, sprite, words] { layer.addSublayer(part) }
            seatedLegs.name="seated-legs";seatedLegs.isHidden=true
            plate.name="plate-"+place.id
            carrier.name="restart-"+place.id
            carrier.bounds = .zero
            carrier.zPosition = OfficeView.restartDepth
        }
    }

    /// How a pet looked before it was dressed for its new place: it changes on the way, not at once.
    struct Look {
        let scale: CGFloat
        let alpha: Float
        let still: CGImage?
        let pet: String?
        var stillFrame = (row: 0, column: 0)
    }

    /// Takes a pet's layers away once it has walked out through the door.
    final class Departure: NSObject, CAAnimationDelegate {
        let gone: () -> Void
        init(_ gone: @escaping () -> Void) { self.gone = gone }
        func animationDidStop(_ anim: CAAnimation, finished: Bool) { if finished { gone() } }
    }

    weak var store: Store?
    /// Nothing moves: nobody walks, loops or fades. For snapshots, and for checks that hold the view
    /// up against the still picture.
    var still = false
    /// For a still picture: how far round its loop the light's ball and each of its spots is, as a share of that loop
    /// (`--focus-phase`), so two pictures can show them moving.
    static var stillPhase = 0.0
    /// Reduce Motion is on: the light's ball and spots hold still. A check can say so.
    var calm: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Where the view tells what its light is on (`spotlight`); a check listens instead.
    var note: (String) -> Void = { log($0) }
    /// For checks: instead of jumping to the session on a click on its pet.
    var onClick: ((Session) -> Void)?
    /// What the log was last told the light is on, and when: at most one line a second.
    private var beamSaid: String?
    private var beamSaidAt = Date.distantPast
    /// Nobody sees the light move (the window is hidden or covered), or the user is not in Orca (it is at half then): its ball,
    /// spots and lasers hold where they are.
    private var hushed = false
    /// Whether anyone can see the window: walking where nobody looks only costs.
    var onScreen: Bool { window?.occlusionState.contains(.visible) ?? false }

    var room = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: [])
    /// The first room with anyone in it has been set out. Until then nobody walks in: at launch the
    /// view can come up a moment before the sessions are read.
    var loaded = false
    private var roomKey = ""
    var figures: [String: Figure] = [:]
    /// Each desk's walkers (one holder layer, a layer for each walker) and what they were made from, by seat.
    var walkerHolders: [Int: (holder: CALayer, key: String)] = [:]
    /// Who was visiting whom at the last look.
    private var visits = OfficeVisits()
    /// What each open session had done at the last look, so a change of place can be told to be its own doing.
    var events: [String: String] = [:]
    private var pressed: Target?
    private let wall = CALayer(), skirting = CALayer(), underSkirting = CALayer()
    let stage = CALayer(), roomLayer = CALayer(), ring = CALayer()
    /// The chips, painted with the room but over everyone in it.
    let chipLayer = CALayer()
    /// Whatever an extension's scene keeps on this view (`SceneExtension`): an extension cannot add stored properties.
    var sceneState: AnyObject?
    /// The restart spinners' carriers in a scene that moves its figures itself: over every figure and piece of
    /// scenery, under the chips.
    static let restartDepth:CGFloat=9_000

    /// While the pointer is on one who talks: lines to its partners, those of talk over ten minutes ago fainter.
    private let links = CAShapeLayer(), older = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The room in its own coordinates, scaled as a whole to the size it is shown at.
        stage.name = "stage"
        stage.anchorPoint = .zero
        roomLayer.name = "room"
        stage.addSublayer(roomLayer)
        chipLayer.name = "chips"
        chipLayer.zPosition = 10_000  // over every pet, whose depth is where its feet are
        stage.addSublayer(chipLayer)
        ring.name = "ring"
        ring.borderWidth = 1.5
        ring.cornerRadius = 10
        ring.borderColor = CGColor(gray: 1, alpha: 0.5)  // as a board card's edge when pointed at
        ring.isHidden = true
        // In the view's own points, as the ring is, so a line is as fine at any size.
        links.name = "links"
        older.name = "older"
        for line in [links, older] {
            line.fillColor = nil
            line.lineWidth = 1.5
            line.lineDashPattern = [4, 4]
        }
        older.opacity = 0.4
        links.addSublayer(older)
        for sublayer in [wall, skirting, underSkirting, stage, links, ring] { layer?.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { fatalError("made in code only") }

    override var isFlipped: Bool { true }
    // The panel is never the active window; without this the first click would only focus it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A click on a pet is a click, not the start of a window drag.
    override var mouseDownCanMoveWindow: Bool { false }

    var fit: OfficeFit { OfficeFit(bounds.size) }

    /// The light's colour on this floor: a pale warm white on a dark one; on a light one, where white would not show, a
    /// deeper warm tone.
    static func lightTone(on floor: UInt32) -> UInt32 { OfficePalette.luminance(floor) > 0.5 ? 0xE0A040 : 0xFFF1D8 }

    /// How far above the pet's head the light starts: it shines down on it from over its head, not from the ceiling.
    static let lightAbove: CGFloat = 72
    /// How wide the light is at the feet, in the pet's widths; the pool on the floor is as wide.
    static let lightWide: CGFloat = 1.8
    /// How wide the light is at its top, as a share of its width at the feet: about a third of the pet's there, so that at
    /// head height, some 72 pt down a cone about 120 pt long, it is about 1.2 times the pet's width and shows round it.
    static let lightTop: CGFloat = 0.17

    /// The light's two pictures in a tone, painted once a tone and stretched to size: the cone, narrow and fainter at its
    /// top, soft at its sides and both ends; and the pool on the floor, an ellipse evenly lit in its middle. The 35% and 45%
    /// are in them; how strong the light is (Orca in front or not) is its layer's.
    private static var lights: [UInt32: (cone: CGImage, pool: CGImage)] = [:]

    static func lightPictures(_ tone: UInt32) -> (cone: CGImage, pool: CGImage)? {
        if let made = lights[tone] { return made }
        func smooth(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
            let t = max(0, min(1, (x - a) / (b - a)))
            return t * t * (3 - 2 * t)
        }
        // Across from -1 to 1, down from 0 at the top to 1 at the bottom.
        func paint(_ w: Int, _ h: Int, _ alpha: (CGFloat, CGFloat) -> CGFloat) -> CGImage? {
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            let rgb = [16, 8, 0].map { CGFloat((tone >> UInt32($0)) & 255) }
            for y in 0..<h {
                for x in 0..<w {
                    let a = alpha((CGFloat(x) + 0.5) / CGFloat(w) * 2 - 1, (CGFloat(y) + 0.5) / CGFloat(h)), i = (y * w + x) * 4
                    for c in 0..<3 { bytes[i + c] = UInt8((rgb[c] * a).rounded()) }
                    bytes[i + 3] = UInt8((255 * a).rounded())
                }
            }
            guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
            return CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent)
        }
        let cone = paint(64, 256) { u, v in
            let across = 1 - smooth(0.3, 1, abs(u) / (Self.lightTop + (1 - Self.lightTop) * v))
            return 0.35 * across * (0.55 + 0.45 * v) * smooth(0, 0.15, v) * (1 - smooth(0.94, 1, v))
        }
        let pool = paint(96, 32) { u, v in 0.45 * (1 - smooth(0.5, 1, hypot(u, v * 2 - 1))) }
        guard let cone, let pool else { return nil }
        lights[tone] = (cone, pool)
        return (cone, pool)
    }

    /// The mirror ball over the light: 14 pt across, its 2-pt facets in seven rows, on a 1-pt line `ballLine` long that fades
    /// out upwards, so it hangs from nowhere in particular. Its picture's foot is the top of the cone.
    static let ballLine: CGFloat = 12
    static let ballSize = CGSize(width: 16, height: ballLine + 17)
    /// It turns one facet's width every `ballBeats` beats (seven twelfths of a second), round in `ballFrames` steps: slow
    /// enough to read as a ball turning, not as a flicker.
    static let ballFrames = 8
    static let ballBeats = 7
    /// The beat the light moves on: everything in it steps together, twelve times a second.
    static let discoBeat = 1.0 / 12
    /// Its lit facets, by the column of its turning pattern they are in and their row: three in the rows of seven, where at
    /// most one at a time is round the back, so two or three always show.
    static let ballGlints: [(column: Int, row: Int)] = [(0, 2), (3, 4), (5, 3)]

    private static var balls: [String: [CGImage]] = [:]

    /// The ball's turning pictures in a look, painted once a look: lit from the top left in the furniture's graphite and white,
    /// each facet a shade off its neighbour so the facets read, outlined as the furniture is, and on each picture the lit
    /// facets one column further round.
    static func ballPictures(_ theme: OfficeTheme) -> [CGImage] {
        if let made = balls[theme.key] { return made }
        let look = theme.palette
        let ramp = [look.graphite.base, look.graphite.front, look.graphite.top, look.white.base, look.white.front, look.white.top]
        let top: CGFloat = ballLine + 2  // the facets' first row; the outline and the cap above it
        func facet(_ i: Int, _ j: Int) -> Bool {
            guard (0..<7).contains(i), (0..<7).contains(j) else { return false }
            return hypot(CGFloat(i) - 3, CGFloat(j) - 3) <= 3.5
        }
        /// Whether a 1-pt cell of the picture is on the ball.
        func on(_ x: Int, _ y: Int) -> Bool { x >= 1 && y >= Int(top) && facet((x - 1) / 2, (y - Int(top)) / 2) }
        let frames: [CGImage] = (0..<ballFrames).compactMap { frame in
            let c = OfficeCanvas(ballSize)
            for y in 0..<Int(ballLine) {
                c.fill(7.5, CGFloat(y), 1, 1, look.graphite.top, 0.9 * CGFloat(y + 1) / ballLine)
            }
            for y in Int(top) - 1...Int(top) + 14 {
                for x in 0...15 where !on(x, y) && (on(x - 1, y) || on(x + 1, y) || on(x, y - 1) || on(x, y + 1)) {
                    c.fill(CGFloat(x), CGFloat(y), 1, 1, look.line)
                }
            }
            let glints = Set(ballGlints.map { ($0.column + frame) % 8 * 10 + $0.row })
            for j in 0..<7 {
                for i in 0..<7 where facet(i, j) {
                    let x = (CGFloat(i) - 3) / 3.5, y = (CGFloat(j) - 3) / 3.5, z = sqrt(max(0, 1 - x * x - y * y))
                    let lit = max(0, -0.45 * x - 0.55 * y + 0.7 * z)
                    // The facets beside a glint catch some of it.
                    let beside = (i > 0 && glints.contains((i - 1) * 10 + j)) || (i < 6 && glints.contains((i + 1) * 10 + j))
                        || glints.contains(i * 10 + j - 1) || glints.contains(i * 10 + j + 1)
                    let shade: Int = beside ? 5 : min(5, max(0, Int(lit * 6) - (i + j) % 2))
                    c.fill(1 + 2 * CGFloat(i), top + 2 * CGFloat(j), 2, 2, glints.contains(i * 10 + j) ? 0xFFFFFF : ramp[shade])
                }
            }
            c.fill(6, ballLine, 4, 2, look.graphite.front)  // where the line holds it
            return c.image()
        }
        guard frames.count == ballFrames else { return [] }
        balls[theme.key] = frames
        return frames
    }

    /// A spot of light the ball throws, going round its own loop in the light: in the cone's measure, `u` across it (-1 to 1
    /// at the cone's edges, the pool's below the feet) and `v` down it (0 at its top, 1 at the feet, more on the floor in
    /// front of them), round `u`, `v` by `ru`, `rv`, once in `seconds`, `turn` 1 one way and -1 the other, starting `phase`
    /// of the way round. Each has a loop and a time of its own, so they never line up. On a light floor, where a pastel
    /// would not show, as the light itself turns amber there, it takes a deeper tone of its colour.
    struct Spot {
        let colour: UInt32, deep: UInt32, size: CGFloat, opacity: Float, seconds: Double, phase: Double, turn: Double
        let u: CGFloat, v: CGFloat, ru: CGFloat, rv: CGFloat
    }

    /// Soft pink and butter round the body and legs, mint on the floor, sky and lilac in the cone over the head. Under the
    /// sprite, so one going behind the pet is hidden by it and none ever crosses its face.
    static let spots = [
        Spot(colour: 0xFFB3C7, deep: 0xFF7FA8, size: 17, opacity: 0.55, seconds: 13.6, phase: 0.12, turn: 1, u: 0, v: 0.78, ru: 0.75, rv: 0.14),
        Spot(colour: 0xA8EBCF, deep: 0x45C98F, size: 15.5, opacity: 0.55, seconds: 12.2, phase: 0.58, turn: -1, u: 0, v: 1, ru: 0.6, rv: 0.05),
        Spot(colour: 0xA8D8FF, deep: 0x5AA9EE, size: 14.5, opacity: 0.52, seconds: 8.7, phase: 0.33, turn: 1, u: 0, v: 0.34, ru: 0.45, rv: 0.1),
        Spot(colour: 0xFFE89A, deep: 0xEDB52A, size: 15.5, opacity: 0.55, seconds: 13.9, phase: 0.81, turn: -1, u: 0, v: 0.9, ru: 0.7, rv: 0.12),
        Spot(colour: 0xC9B6FF, deep: 0x9F86F2, size: 13, opacity: 0.58, seconds: 10.3, phase: 0.47, turn: -1, u: 0.05, v: 0.5, ru: 0.5, rv: 0.07),
    ]

    /// A spot's colour on this floor: its pastel on a dark one, its deeper tone on a light one.
    static func spotTone(_ spot: Spot, on floor: UInt32) -> UInt32 { OfficePalette.luminance(floor) > 0.5 ? spot.deep : spot.colour }

    /// Where a spot is, `at` of the way round its loop (its own phase included), on a pet drawn `wide` by `high`: in the pet's
    /// layer, from its feet.
    static func place(_ spot: Spot, at share: Double, wide: CGFloat, high: CGFloat) -> CGPoint {
        let angle = 2 * Double.pi * share * spot.turn
        let u = spot.u + spot.ru * CGFloat(cos(angle)), v = spot.v + spot.rv * CGFloat(sin(angle))
        let across = lightWide * wide * (lightTop + (1 - lightTop) * min(1, v)) / 2
        return CGPoint(x: u * across, y: (v - 1) * (high + lightAbove))
    }

    private static var spotPictures: [UInt32: CGImage] = [:]

    /// A spot's picture, painted once a colour: a round of it, even over most of it and soft at its rim.
    static func spotPicture(_ colour: UInt32) -> CGImage? {
        if let made = spotPictures[colour] { return made }
        let made = glow(32, 32) { x, y in
            let r = hypot(x * 2 - 1, y * 2 - 1), t = max(0, min(1, (r - 0.6) / 0.4))
            return (colour, 1 - t * t * (3 - 2 * t))
        }
        spotPictures[colour] = made
        return made
    }

    /// A picture of light, each pixel its colour and strength by where it is, across and down from 0 to 1.
    private static func glow(_ w: Int, _ h: Int, _ pixel: (CGFloat, CGFloat) -> (colour: UInt32, alpha: CGFloat)) -> CGImage? {
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (colour, a) = pixel((CGFloat(x) + 0.5) / CGFloat(w), (CGFloat(y) + 0.5) / CGFloat(h)), i = (y * w + x) * 4
                for (c, shift) in [16, 8, 0].enumerated() { bytes[i + c] = UInt8((CGFloat((colour >> UInt32(shift)) & 255) * a).rounded()) }
                bytes[i + 3] = UInt8((255 * a).rounded())
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A laser the ball throws: a thin bright ray from the ball down to the floor, swinging slowly from side to side across
    /// the cone and back, once there and back in `seconds`, eased at each end; `middle` is where it swings round and `swing`
    /// how far either way, as shares of how far the cone allows. It starts `phase` of the way through its swing: at 0.25 and
    /// 0.75 it is at its middle, which a still picture and Reduce Motion show. On a light floor it takes a deeper tone.
    struct Laser {
        let colour: UInt32, deep: UInt32, seconds: Double, phase: Double, middle: CGFloat, swing: CGFloat
    }

    /// Hot pink, cyan and lime, each at its own pace, fanned out when still.
    static let lasers = [
        Laser(colour: 0xFF4FB4, deep: 0xE0007A, seconds: 6.6, phase: 0.25, middle: -0.55, swing: 0.45),
        Laser(colour: 0x4FF0FF, deep: 0x00A8C8, seconds: 9.4, phase: 0.75, middle: 0, swing: 0.9),
        Laser(colour: 0xB8FF4F, deep: 0x5DB800, seconds: 8.0, phase: 0.25, middle: 0.55, swing: 0.45),
    ]
    /// A ray is 1.5 pt of bright core in 2 pt of soft glow either side; at 55%. The dot at its tip is 3 pt.
    static let laserWide: CGFloat = 5.5
    static let laserStrength: Float = 0.55

    /// How far a laser is turned from straight down, `at` of the way through its swing (its own phase included), when the cone
    /// allows `reach` either way: there and back, eased at each end as Core Animation eases it.
    static func angle(_ laser: Laser, at share: Double, reach: CGFloat) -> CGFloat {
        let x = share - share.rounded(.down), there = CGFloat(x < 0.5 ? 2 * x : 2 - 2 * x), eased = there * there * (3 - 2 * there)
        return (laser.middle + laser.swing * (2 * eased - 1)) * reach
    }

    private static var laserPictures: [UInt32: CGImage] = [:]

    /// A laser's ray, painted once a colour and stretched to its length: its core whitened, its glow soft, fading in where it
    /// leaves the ball.
    static func laserPicture(_ colour: UInt32) -> CGImage? {
        if let made = laserPictures[colour] { return made }
        let core = 0.75 / laserWide, edge = 0.5 - core
        let made = glow(22, 64) { x, y in
            let off = abs(x - 0.5), t = max(0, min(1, (off - core) / edge)), into = min(1, y / 0.1)
            let a = off <= core ? 1 : 0.5 * (1 - t * t * (3 - 2 * t))
            return (off <= core ? OfficePalette.mix(colour, 0xFFFFFF, 0.45) : colour, a * into * into * (3 - 2 * into))
        }
        laserPictures[colour] = made
        return made
    }

    /// The time the room is laid out for: how long one answered has stayed, how long one has been idle.
    var clock: Date { Date() }

    /// What a pet's sprite is drawn from: while this stays the same, so does its sprite. `ready`
    /// says whether a frame has been cut; by default it asks, which starts the cutting as drawing would.
    static func spriteKey(
        _ store: Store, _ s: Session, _ place: OfficeLayout.Pet, now: Date, ready: ((String, Int, Int) -> Bool)? = nil
    ) -> String {
        let ready = ready ?? { OfficePets.shared.has($0, row: $1, column: $2) }
        let pose = place.sceneSlot != nil && place.kind == .work ? Pose.standing.sheet : store.pose(of: s, now: now).sheet
        var key = "\(place.x) \(place.foot) \(place.tall) \(place.asleep) \(pose.row) \(pose.frames) \(pose.ms) \(pose.still) \(s.isGone)"
        // One who knocks (waiting for you) also goes by whether Reduce Motion has it lean or wear a ring.
        if WaitingNudge.enabled, !(place.sceneSlot != nil && place.kind == .work), store.pose(of: s, now: now) == .waiting {
            key += " knock \(WaitingNudge.calm())"
        }
        if let pet = store.displayPets[s.id] { key += " \(pet) \(ready(pet, pose.row, pose.still)) \(ready(pet, 0, 0))" }
        return key
    }

    /// What a pet's words are painted from. The scale counts in twentieths, and not at all above
    /// full size, where the words stop growing.
    static func wordsKey(_ store: Store, _ s: Session, _ place: OfficeLayout.Pet, _ layout: OfficeLayout, now: Date, scale: CGFloat) -> String {
        let box = place.words.offsetBy(dx: -place.x, dy: -place.foot)
        var key = "\(OfficeTheme.current.key) \(place.zone) \(box) \(OfficeLook.step(min(1, scale))) \(s.name) \(s.project) \(s.status) \(s.isWorking) \(s.bgTasks) \(s.isBackgroundHung) \(store.isUnread(s))"
        key += " \(String(describing: store.failTone(s))) \(failShortWords(s) ?? "")"
        key += " \(store.pinned.contains(s.id)) \(place.host ?? "") \(place.chats) \(place.markPlace) \(place.markLeft) \(s.kind)"
        // Only a queue card shows what it asks and how long it has waited.
        if place.zone == .queue && (place.kind == .waiting || place.sceneSlot == "queue-0") {
            key += " \(layout.asks) \(s.summary) \(ago(s.since, now: now)) \(timeLabel(s, now: now))"
        }
        return key
    }

    /// Follows the store: on its tick, and whenever the pointer moves to someone else.
    func update(_ store: Store) {
        self.store = store
        render()
    }

    /// A pet's frames have just been cut: put it in.
    func refresh() { render() }

    /// Repaint when this office is the one to tell that pets' frames have arrived. One listens at
    /// a time; one that goes away stops only its own listening, and its judging of overlaps.
    func listen() {
        OfficePets.shared.onReady = { [weak self] in self?.refresh() }
        OfficePets.shared.listener = self
    }

    func stopListening() {
        if OfficePets.shared.listener === self {
            OfficePets.shared.onReady = nil
            OfficePets.shared.listener = nil
        }
        if store?.tracker.resolver === self { store?.tracker.resolver = nil }
    }

    // A new size lays the view out again by itself; a new window changes where the pets are in it.
    // Layers can lose their animations on the way: whoever was walking is simply there, whoever was
    // leaving is gone, and the loops start again.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, figure) in figures {
            if figure.leaving {
                figure.layer.removeFromSuperlayer()
                figures[id] = nil
            } else {
                set(figure)
            }
        }
        // The walkers' animations went too: made again at the next look.
        for known in walkerHolders.values { known.holder.removeFromSuperlayer() }
        walkerHolders = [:]
        CATransaction.commit()
        // An extension's scene may have animations to put in again: they went with the old window's tree.
        Extensions.registered?.movedToWindow(self)
        needsLayout = true
        // The light's motion holds while the window is hidden or covered, and goes on when it shows again.
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window { NotificationCenter.default.addObserver(self, selector: #selector(seen), name: NSWindow.didChangeOcclusionStateNotification, object: window) }
    }

    @objc private func seen(_ note: Notification) { render() }

    override func layout() {
        super.layout()
        render()
    }

    // Dragging the window's edge changes the room's height with every point: what is there is
    // stretched meanwhile, and laid out and painted once when the drag ends.
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        render(dragEnded: true)  // whether or not AppKit still calls this a live resize
    }

    private func render(dragEnded: Bool = false) {
        guard let store else { return }
        let fit = self.fit
        if inLiveResize, !dragEnded, !roomKey.isEmpty {
            stretch(fit)
            return
        }
        // Words are painted for the exact size shown; only the keys round it.
        let now = clock
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bands(fit)
        if fit.scale > 0 {
            // From its own last room once it has one: another office drawn meanwhile (a snapshot, a
            // check) must not move anyone here. Visitors stand by their hosts, their seats kept.
            let seats = OfficePainter.layout(store, now: now, height: fit.height, scale: fit.scale, previous: loaded ? room : nil)
            visits = OfficeVisits.next(
                seats, peers: store.peers, rounds: store.rounds, previous: loaded ? visits : OfficeSeats.visits(for: store), now: now)
            let layout = seats.sceneMode ? seats : seats.visited(
                by: visits, talking: OfficeVisits.talking(store.peers, now: now), sizes: OfficePets.shared.sizes(store))
            OfficeSeats.remember(layout, visits: visits, for: store)
            stage.bounds = CGRect(origin: .zero, size: layout.size)
            stage.position = fit.offset
            stage.transform = CATransform3DMakeScale(fit.scale, fit.scale, 1)
            let key = OfficePainter.roomKey(store, layout, scale: fit.scale)
            if key != roomKey {
                roomLayer.contents = OfficePainter.room(store, layout, scale: fit.scale)
                let chips = OfficePainter.chips(store, layout, scale: fit.scale)
                chipLayer.contents = chips?.image
                chipLayer.frame = chips?.rect ?? .zero
                roomKey = key
            }
            roomLayer.frame = CGRect(origin: .zero, size: layout.size)
            // An extension's scene brings its own model up to now first, so the room is cast from where everyone really is.
            Extensions.registered?.prepareCast(self, layout, now: now)
            cast(store, layout, now: now, scale: fit.scale)
            spotlight(store)
            room = layout
            Extensions.registered?.afterCast(self)
        }
        placeRing(store, fit)
        relations(store, fit, now: now)
        publish(store, fit)
        CATransaction.commit()
        // The board's card is up where the user can see it: what is on it has been seen. Not from inside SwiftUI's update of this
        // view; not for a still picture, which only shows the card; not with the pointer left on the board while the
        // window is hidden or the display asleep.
        if !still, onScreen, store.hovered == OfficeLayout.boardKey, store.activity.unseen > 0 {
            DispatchQueue.main.async { [weak store] in store?.lookedAtBoard() }
        }
    }

    /// The ring round what the pointer is on. In a scene that moves its figures itself a figure is seldom at its place:
    /// there the ring hangs on the figure's own layer, round where it can be pointed at (`SceneExtension.hitRect`), and
    /// goes where it goes with no pass of this view. Anything else, and the office: in the view, round its
    /// place; on a row of the door's or the chip's list, round that door or chip.
    private func placeRing(_ store: Store, _ fit: OfficeFit) {
        if room.sceneDriven, let scene = Extensions.registered, let id = store.hovered, let f = figures[id], !f.leaving {
            // In the stage's points, which the view scales: the line comes out as fine as the view's ring.
            let unit = max(fit.scale, 0.01)
            ring.borderWidth = 1.5 / unit
            ring.cornerRadius = 10 / unit
            ring.frame = scene.hitRect(self, f)
            ring.isHidden = false
            // Over the figure's own parts; anything the scene put on it after, under it again here.
            if f.layer.sublayers?.last !== ring { f.layer.addSublayer(ring) }
            return
        }
        if ring.superlayer !== layer { layer?.addSublayer(ring) }
        ring.borderWidth = 1.5
        ring.cornerRadius = 10
        let ringed = store.hovered.flatMap { room.ring(for: OfficeList.open($0) ?? $0) }
        ring.isHidden = ringed == nil
        if let ringed { ring.frame = fit.rect(ringed) }
    }

    /// Where a figure can be pointed at now, in the room, in a scene that moves its figures itself; nil elsewhere.
    private func liveRect(_ id: String) -> CGRect? {
        guard room.sceneDriven, let scene = Extensions.registered, let f = figures[id], !f.leaving else { return nil }
        return scene.liveRect(self, f)
    }

    /// While the pointer is on one who has talked with others, as on the board: everyone else steps back, and a dashed
    /// line runs from its head to each partner's head, or to the door or chip a partner is counted on. Talk from the last
    /// ten minutes at full strength, older at 40%. Nothing is painted for it.
    private func relations(_ store: Store, _ fit: OfficeFit, now: Date) {
        for (id, figure) in figures where !figure.leaving {
            figure.layer.opacity = store.isDimmed(id) ? 0.35 : 1
            figure.plate.opacity = figure.layer.opacity  // a scene's plate is its own layer in the stage
        }
        func head(_ pet: OfficeLayout.Pet) -> CGPoint {
            CGPoint(x: fit.offset.x + pet.x * fit.scale, y: fit.offset.y + (pet.foot - pet.head) * fit.scale)
        }
        func middle(_ r: CGRect) -> CGPoint { CGPoint(x: fit.rect(r).midX, y: fit.rect(r).midY) }
        let recent = CGMutablePath(), old = CGMutablePath()
        if let id = store.hovered, let me = room.pets.first(where: { $0.id == id }) {
            for peer in store.peers[id] ?? [] {
                guard let key = room.pointed(at: peer.id) else { continue }
                guard let there = room.pets.first(where: { $0.id == key }).map(head) ?? room.ring(for: key).map(middle) else { continue }
                let path = peer.isRecent(now) ? recent : old
                path.move(to: head(me))
                path.addLine(to: there)
            }
        }
        links.frame = bounds
        older.frame = links.bounds
        links.path = recent.isEmpty ? nil : recent
        older.path = old.isEmpty ? nil : old
        links.isHidden = false
    }

    /// The light on the session the user is typing in, in Orca (`Store.focused`): on its pet wherever it goes, half as strong while
    /// Orca is not in front, its ball and spots with it, fading in and out in 0.3 s; the fade is too short for Reduce Motion
    /// to stop, the ball's turning and the spots' loops are not (`spin`). None for one behind the door or counted on a chip
    /// (no pet in the room), nor with the light switched off; once faded out it is taken away.
    private func spotlight(_ store: Store) {
        let lit = officeSpotlight() ? store.focused : nil
        let strength: Float = store.orcaInFront ? 1 : 0.5
        hushed = !store.orcaInFront || !onScreen
        for f in figures.values {
            let wanted: Float = f.place.id == lit && !f.leaving ? strength : 0
            guard wanted > 0 || f.beam != nil else { continue }
            let beam = light(f)
            guard beam.opacity != wanted else { continue }
            let from = beam.presentation()?.opacity ?? beam.opacity
            beam.opacity = wanted
            if still {
                if wanted == 0 { Self.unlight(f) }
                continue
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = wanted
            fade.duration = 0.3
            if wanted == 0 {
                fade.delegate = Departure { [weak f, weak beam] in
                    guard let f, let beam, f.beam === beam, beam.opacity == 0 else { return }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    Self.unlight(f)
                    CATransaction.commit()
                }
            }
            beam.add(fade, forKey: "fade")
        }
        tellBeam(store, lit)
    }

    /// The light as the store has it now, outside a pass (a click's).
    private func lightNow(_ store: Store) {
        guard !figures.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spotlight(store)
        CATransaction.commit()
    }

    /// The log says what the panel itself draws whenever the light goes to someone else: on whom, where in the view, how
    /// strong and how deep; or that the one it is for has no pet in the room. The reader's own lines say only what it
    /// resolved. At most one line a second; one held back is told at a later pass if it still holds. Never for a picture.
    private func tellBeam(_ store: Store, _ lit: String?) {
        guard !still else { return }
        let key = lit.map { "\($0) \(figures[$0]?.beam != nil)" } ?? (beamSaid == nil ? nil : "off")
        guard let key, key != beamSaid, clock.timeIntervalSince(beamSaidAt) >= 1 else { return }
        beamSaid = key
        beamSaidAt = clock
        guard let lit else { return note("focus: beam off") }
        let name = store.sessions.first { $0.id == lit }?.name ?? lit
        guard let f = figures[lit], let cone = f.beam.flatMap({ Self.part($0, "cone") }), let beam = f.beam, let view = layer else {
            return note("focus: beam on nobody: \(name) has no pet in the room (behind the door, or on a chip)")
        }
        let r = view.convert(cone.bounds, from: cone)
        note(
            String(
                format: "focus: beam on %@ at (%.0f, %.0f, %.0f×%.0f) alpha %.2f z %.0f", name, r.minX, r.minY, r.width, r.height, beam.opacity,
                f.layer.zPosition))
    }

    /// A pet's light, made when it is first lit: a cone from a little above its head down to its feet and a pool under its
    /// feet, the spots the ball throws over them and the ball over the cone's top, between its shadow and its sprite, so it
    /// goes wherever the pet's layer goes, walks too. Only the ball and the spots move of their own.
    private func light(_ f: Figure) -> CALayer {
        if let beam = f.beam {
            shape(f)  // the theme may have changed
            return beam
        }
        let beam = CALayer(), cone = CALayer(), pool = CALayer(), ball = CALayer()
        beam.name = "beam"
        cone.name = "cone"
        pool.name = "pool"
        ball.name = "ball"
        beam.bounds = .zero
        beam.opacity = 0
        cone.anchorPoint = CGPoint(x: 0.5, y: 1)  // its foot, at the pet's feet
        ball.anchorPoint = CGPoint(x: 0.5, y: 1)  // its foot, at the cone's top
        let spots = Self.spots.map { _ in CALayer() }
        for spot in spots { spot.name = "spot" }
        // A laser turns about its top, at the ball; its ray and the dot at its tip turn with it.
        let lasers = Self.lasers.map { _ -> CALayer in
            let laser = CALayer(), ray = CALayer(), tip = CALayer()
            laser.name = "laser"
            ray.name = "ray"
            tip.name = "tip"
            laser.anchorPoint = CGPoint(x: 0.5, y: 0)
            for part in [ray, tip] { laser.addSublayer(part) }
            return laser
        }
        for part in [cone, pool] + spots + lasers + [ball] { beam.addSublayer(part) }
        f.layer.insertSublayer(beam, above: f.shadow)
        f.beam = beam
        // What its last light was painted and drawn for went with that light: this one has no pictures and no loops yet.
        f.painted = nil
        f.spun = nil
        shape(f)
        return beam
    }

    /// Takes a pet's light away, and with it what its pictures and loops were made for: a new light starts with none.
    static func unlight(_ f: Figure) {
        f.beam?.removeFromSuperlayer()
        f.beam = nil
        f.painted = nil
        f.spun = nil
    }

    private static func part(_ beam: CALayer, _ name: String) -> CALayer? { beam.sublayers?.first { $0.name == name } }

    /// The light's size where the pet's layer is: the cone from `lightAbove` over the drawn pet's head down to its feet,
    /// `lightWide` times as wide as the pet at the feet; the pool as wide, a quarter of that deep, round its feet; the ball
    /// on the cone's top, or as near it as the room's top allows; the spots where their loops start, or where a still
    /// picture's phase has them. Its pictures are put in when the look is not the one they were put in for, or it has none.
    private func shape(_ f: Figure) {
        guard let beam = f.beam, let cone = Self.part(beam, "cone"), let pool = Self.part(beam, "pool"), let ball = Self.part(beam, "ball")
        else { return }
        let wide = Self.lightWide * f.wide, tall = f.high + Self.lightAbove
        let spots = beam.sublayers?.filter { $0.name == "spot" } ?? []
        cone.position = .zero
        cone.bounds = CGRect(x: 0, y: 0, width: wide, height: tall)
        pool.position = .zero
        pool.bounds = CGRect(x: 0, y: 0, width: wide, height: max(10, wide * 0.24))
        // On the couches at the back the cone's top is near the ceiling: the ball comes down over it rather than off the room.
        ball.position = CGPoint(x: 0, y: max(-tall, Self.ballSize.height - f.place.foot))
        ball.bounds = CGRect(origin: .zero, size: Self.ballSize)
        let phase = still ? Self.stillPhase : 0
        for (spot, layer) in zip(Self.spots, spots) {
            layer.position = Self.place(spot, at: spot.phase + phase, wide: f.wide, high: f.high)
            layer.bounds = CGRect(x: 0, y: 0, width: spot.size, height: spot.size)
            layer.opacity = spot.opacity
        }
        // The lasers from the ball's middle to just past the feet, onto the pool, swinging no further than eight tenths of the
        // way to the cone's edge there.
        let lasers = beam.sublayers?.filter { $0.name == "laser" } ?? [], from = ball.position.y - 8, length = -from * 1.02
        let reach = atan(0.8 * wide / 2 / -from)
        for (laser, layer) in zip(Self.lasers, lasers) {
            layer.position = CGPoint(x: 0, y: from)
            layer.bounds = CGRect(x: 0, y: 0, width: Self.laserWide, height: length)
            layer.transform = CATransform3DMakeRotation(Self.angle(laser, at: laser.phase + phase, reach: reach), 0, 0, 1)
            if let ray = Self.part(layer, "ray"), let tip = Self.part(layer, "tip") {
                ray.frame = layer.bounds
                ray.opacity = Self.laserStrength
                tip.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)  // a soft round, 3 pt of it bright
                tip.position = CGPoint(x: Self.laserWide / 2, y: length)
                tip.opacity = 0.9
            }
        }
        let theme = OfficeTheme.current, frames = Self.ballPictures(theme)
        if theme.key != f.painted || cone.contents == nil || ball.contents == nil,
            let pictures = Self.lightPictures(Self.lightTone(on: theme.palette.floor))
        {
            f.painted = theme.key
            cone.contents = pictures.cone
            pool.contents = pictures.pool
            for (spot, layer) in zip(Self.spots, spots) { layer.contents = Self.spotPicture(Self.spotTone(spot, on: theme.palette.floor)) }
            let light = OfficePalette.luminance(theme.palette.floor) > 0.5
            for (laser, layer) in zip(Self.lasers, lasers) {
                let tone = light ? laser.deep : laser.colour
                Self.part(layer, "ray")?.contents = Self.laserPicture(tone)
                Self.part(layer, "tip")?.contents = Self.spotPicture(OfficePalette.mix(tone, 0xFFFFFF, 0.5))
            }
            ball.removeAnimation(forKey: "turn")  // it turns through the last look's pictures
            ball.contents = frames.first
        }
        spin(f, ball: ball, frames: frames, spots: spots, lasers: lasers, reach: reach, phase: phase)
    }

    /// Sets the ball turning, the spots going round their loops and the lasers swinging, each forever, in Core Animation; puts
    /// in only what is missing, so a pet's change of pose or a walk does not start them again. All of it moves in steps, a
    /// twelfth of a second each, on one beat (`discoBeat`): the window server then draws the panel anew twelve times a second
    /// for the light, not at the display's rate. Still, out of a window, or with Reduce Motion, nothing moves: the ball shows
    /// its first picture (a still picture's phase's), the spots stay where they start, the lasers at their middles. Where
    /// nobody sees it, or with Orca not in front (`hushed`), it holds where it is, and goes on from there.
    private func spin(_ f: Figure, ball: CALayer, frames: [CGImage], spots: [CALayer], lasers: [CALayer], reach: CGFloat, phase: Double) {
        let moving = [ball] + spots + lasers
        guard !still, !calm, window != nil, !frames.isEmpty else {
            for layer in moving {
                layer.removeAllAnimations()
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
            }
            f.spun = nil
            let count = frames.count
            if count > 0 { ball.contents = frames[(Int((phase * Double(count)).rounded(.down)) % count + count) % count] }
            return
        }
        /// A loop of these values a beat each, starting at the one `first` along, from the next beat on.
        func stepped(_ path: String, _ values: [Any], first: Int, on layer: CALayer) -> CAKeyframeAnimation {
            let loop = CAKeyframeAnimation(keyPath: path)
            loop.values = values
            loop.calculationMode = .discrete
            loop.duration = Self.discoBeat * Double(values.count)
            loop.timeOffset = Self.discoBeat * Double(first)
            loop.beginTime = layer.convertTime((CACurrentMediaTime() / Self.discoBeat).rounded(.up) * Self.discoBeat, from: nil)
            loop.repeatCount = .infinity
            return loop
        }
        if ball.animation(forKey: "turn") == nil {
            // Each picture held for `ballBeats` beats.
            ball.add(stepped("contents", frames.flatMap { Array(repeating: $0, count: Self.ballBeats) }, first: 0, on: ball), forKey: "turn")
        }
        // Drawn round the pet's size: one that grows or shrinks (to the queue, say) gets its loops drawn again.
        let size = "\(f.wide) \(f.high) \(reach)"
        for (laser, layer) in zip(Self.lasers, lasers) where f.spun != size || layer.animation(forKey: "sweep") == nil {
            // Out either way from its middle, where it rests, and back, eased at each end.
            let steps = Self.beats(laser.seconds), middle = laser.middle * reach
            let angles = (0..<steps).map { NSNumber(value: Double(Self.angle(laser, at: Double($0) / Double(steps), reach: reach) - middle)) }
            let sweep = stepped("transform.rotation.z", angles, first: Self.first(laser.phase, of: steps), on: layer)
            sweep.isAdditive = true
            layer.add(sweep, forKey: "sweep")
        }
        for (spot, layer) in zip(Self.spots, spots) where f.spun != size || layer.animation(forKey: "drift") == nil {
            // From where it rests, which a still picture and Reduce Motion show, round and back there.
            let rest = Self.place(spot, at: spot.phase, wide: f.wide, high: f.high), steps = Self.beats(spot.seconds)
            let points = (0..<steps).map { i -> NSValue in
                let p = Self.place(spot, at: Double(i) / Double(steps), wide: f.wide, high: f.high)
                return NSValue(point: CGPoint(x: p.x - rest.x, y: p.y - rest.y))
            }
            let drift = stepped("position", points, first: Self.first(spot.phase, of: steps), on: layer)
            drift.isAdditive = true
            layer.add(drift, forKey: "drift")
        }
        f.spun = size
        for layer in moving { Self.hold(layer, hushed) }
    }

    /// How many beats a loop of so many seconds takes, and which of them a phase starts on.
    static func beats(_ seconds: Double) -> Int { max(1, Int((seconds / discoBeat).rounded())) }
    static func first(_ phase: Double, of steps: Int) -> Int { Int((phase * Double(steps)).rounded()) % steps }

    /// Holds a layer's animations where they are, or lets them go on from there, back on the beat.
    static func hold(_ layer: CALayer, _ held: Bool) {
        guard (layer.speed == 0) != held else { return }
        if held {
            let now = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.speed = 0
            layer.timeOffset = now
        } else {
            let held = layer.timeOffset
            layer.speed = 1
            layer.timeOffset = 0
            layer.beginTime = 0
            layer.beginTime = ((layer.convertTime(CACurrentMediaTime(), from: nil) - held) / discoBeat).rounded() * discoBeat
        }
    }

    /// The wall, the skirting and the shadow under it, across the whole view: beside and above the room it carries on,
    /// in its theme's colours, so no seam shows; the rest is floor.
    private func bands(_ fit: OfficeFit) {
        let look = OfficeTheme.current.palette
        layer?.backgroundColor = OfficeCanvas.rgb(look.floor)
        wall.backgroundColor = OfficeCanvas.rgb(look.wall)
        skirting.backgroundColor = OfficeCanvas.rgb(look.skirting)
        underSkirting.backgroundColor = OfficeCanvas.rgb(0x000000, OfficeLook.shade * look.wallShade)
        for line in [links, older] { line.strokeColor = OfficeCanvas.rgb(look.paper, 0.6) }
        let y = fit.offset.y, unit = fit.scale, wide = bounds.width
        wall.frame = CGRect(x: 0, y: 0, width: wide, height: y + 62 * unit)
        skirting.frame = CGRect(x: 0, y: y + 62 * unit, width: wide, height: 8 * unit)
        underSkirting.frame = CGRect(x: 0, y: y + 70 * unit, width: wide, height: 6 * unit)
    }

    /// The room as last painted, pulled to fill where the new size puts it.
    private func stretch(_ fit: OfficeFit) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bands(fit)
        let shown = fit.picture, painted = stage.bounds.size
        if painted.width > 0, painted.height > 0 {
            stage.position = shown.origin
            stage.transform = CATransform3DMakeScale(shown.width / painted.width, shown.height / painted.height, 1)
        }
        ring.isHidden = true
        links.isHidden = true
        CATransaction.commit()
    }

    /// Puts everyone where the room has them. At first, wherever nobody could watch, and with walking
    /// switched off, they are simply there. Otherwise only a session's own doing makes it walk: its state
    /// took it to another part of the room, its turn in the queue came, it leaves the queue (answered, its
    /// stay there over), it goes to stand by one it talks with or back, it has just opened (in through the
    /// door) or closed (out through it). Time alone is
    /// not its doing. Any other change of place (a seat someone freed, a place that opened or filled, six hours
    /// idle) fades out where it was and in where it now is. Those setting off together come onto each aisle one
    /// at a time, the one that matters most first; one moving along the queue glides there with its card on.
    private func cast(_ store: Store, _ layout: OfficeLayout, now: Date, scale: CGFloat) {
        // An extension's scene casts its own layouts (`SceneExtension.cast`).
        if layout.sceneMode, let scene = Extensions.registered { return scene.cast(self, store, layout, now: now, scale: scale) }
        let walks = loaded && room.sceneMode == layout.sceneMode && !still && (onScreen || Extensions.registered?.walksUnseen(self) == true)
            && officeWalks() && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var jumped = false
        let byID = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let here = Set(layout.pets.map(\.id))
        // Who sets off now, in the room's order of importance: waiting, with news, at work, looked at, resting, leaving.
        var setting: [(figure: Figure, walk: OfficeWalk, rank: Int, was: Look?, entering: Bool)] = []
        func rank(_ s: Session) -> Int {
            s.status == "waiting" ? 0 : store.isUnread(s) || store.isFailed(s) ? 1 : s.isWorking ? 2 : store.isResting(s, now: now) ? 4 : 3
        }
        // What a session has done, as far as the room goes: its state, whether it has news for you (finished, looked at,
        // pinned or unpinned), and where you sent it from its menu. Whose has changed since the last look; one not seen
        // before has just opened. The sending, not whether it rests: a desk's six hours running out is time's doing.
        func event(_ s: Session) -> String {
            let sent = store.parked[s.id].flatMap { $0.at >= s.finishedAt.timeIntervalSince1970 ? "\($0.zone) \($0.at)" : nil } ?? ""
            return "\(s.status) \(s.isWorking) \(store.isUnread(s)) \(store.isFailed(s)) \(s.isGone) \(sent)"
        }
        func ownDoing(_ s: Session) -> Bool { events[s.id].map { $0 != event(s) } ?? true }
        for place in layout.pets {
            guard let s = byID[place.id] else { continue }
            guard let known = figures[place.id] else {
                let figure = Figure(place)
                figures[place.id] = figure
                stage.addSublayer(figure.layer)
                set(figure)
                dress(figure, store, s, layout, now: now, scale: scale)
                if loaded && walks {
                    if ownDoing(s) {
                        let reach = body(figure, was: nil, tall: place.tall)
                        let way = layout.walk(from: OfficeLayout.doorSpot, to: layout.spot(of: place), body: reach)
                        setting.append((figure, way, rank(s), nil, true))
                    } else {
                        appear(figure)  // a place opened for it
                    }
                } else {
                    jumped = jumped || loaded
                }
                continue
            }
            // On its way until its walk's end: Core Animation takes a finished walk off the layer only at the next commit.
            let before = known.place, onTheWay = known.arrival > CACurrentMediaTime()
            // A new seat is a move; the same seat in a room of another height is not.
            let moved = known.leaving || before.zone != place.zone || before.seat != place.seat || before.x != place.x
            let was = Look(
                scale: known.scale, alpha: known.sprite.opacity, still: known.still, pet: known.pet, stillFrame: known.stillFrame)
            let from = position(of: known)
            known.place = place
            known.leaving = false
            if !moved && before.foot != place.foot { set(known) }
            dress(known, store, s, layout, now: now, scale: scale)
            guard moved else { continue }
            // One an extension's scene still holds where it stands goes on from there when the scene lets it.
            if Extensions.registered?.holds(self, place.id) == true { continue }
            // Going to stand by another, or back from it, is its own doing too.
            let mine =
                ownDoing(s) && before.zone != place.zone || (before.zone == .queue) != (place.zone == .queue) || before.host != place.host
            if !walks {
                set(known)
                jumped = true
            } else if before.zone == .queue && place.zone == .queue && !onTheWay {
                slide(known, from: from, was: was)
            } else if onTheWay || mine {
                let reach = body(known, was: was, tall: max(before.tall, place.tall))
                let way = layout.walk(from: OfficeSpot(point: from, lane: .row), to: layout.spot(of: place), body: reach)
                if onTheWay {
                    walk(known, along: way.route, departs: CACurrentMediaTime(), was: was)
                } else {
                    setting.append((known, way, rank(s), was, false))
                }
            } else {
                swap(known, from: from, was: was)
            }
        }
        // By id, so that which of two closing at once leaves first is the same from one launch to the next.
        for (id, figure) in figures.sorted(by: { $0.key < $1.key }) where !here.contains(id) && !figure.leaving {
            if walks {
                figure.leaving = true
                restartMark(figure, scale: scale)
                if byID[id] == nil {
                    let reach = body(figure, was: nil, tall: figure.place.tall)
                    let way = layout.walk(from: OfficeSpot(point: position(of: figure), lane: .row), to: OfficeLayout.doorSpot, body: reach)
                    setting.append((figure, way, 5, nil, false))
                } else {
                    vanish(figure)  // still open: the room filled, or it is counted on a chip
                }
            } else {
                figure.layer.removeFromSuperlayer()
                figures[id] = nil
                jumped = true
            }
        }
        // One at a time onto each aisle: a walker comes onto it at least 0.35 s after the one before it there, and is
        // never within 20 pt of it while both are on it (a faster one would catch up, one coming the other way would
        // meet it); until then it waits where it is. Who has just finished jumps first and is counted from the end of
        // its jump. The more important go first; of the equally important, the one that reaches its aisle first.
        let setOff = CACurrentMediaTime()
        var onAisles: [Int: [Passage]] = [:]
        let order = setting.enumerated().sorted {
            ($0.element.rank, $0.element.walk.reach, $0.offset) < ($1.element.rank, $1.element.walk.reach, $1.offset)
        }
        for walker in order.map(\.element) {
            let way = walker.walk
            var start = setOff + jumpSeconds(walker.figure, was: walker.was)
            let length = OfficeLayout.length(way.route), seconds = OfficeLayout.walkSeconds(way.route)
            if let aisle = way.aisle, let leg = way.leg, length > 0.5 {
                func passage(_ start: CFTimeInterval) -> Passage {
                    let enters = start + seconds * Double(way.reach / length), along = seconds * Double(abs(leg.to.y - leg.from.y) / length)
                    return Passage(enters: enters, leaves: enters + along, from: leg.from.y, to: leg.to.y)
                }
                let ahead = onAisles[aisle, default: []]
                if let last = ahead.map(\.enters).max() { start = max(start, last + 0.35 - (passage(start).enters - start)) }
                var tries = 0
                while tries < 500 && !ahead.allSatisfy({ $0.lets(passage(start)) }) {
                    start += 0.02
                    tries += 1
                }
                onAisles[aisle, default: []].append(passage(start))
            }
            walk(walker.figure, along: way.route, departs: start, was: walker.was, entering: walker.entering)
        }
        if jumped && loaded && !still {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            stage.add(fade, forKey: kCATransition)  // a transition's key is always this
        }
        // Nearer pets in front, as the still picture paints them.
        placeWalkers(store, layout)
        let layers = [roomLayer] + (figures.values.map(\.layer) + walkerHolders.values.map(\.holder)).sorted {
            ($0.zPosition, $0.position.x, $0.name ?? "") < ($1.zPosition, $1.position.x, $1.name ?? "")
        } + [chipLayer]
        if (stage.sublayers ?? []).map(ObjectIdentifier.init) != layers.map(ObjectIdentifier.init) { stage.sublayers = layers }
        events = Dictionary(store.sessions.map { ($0.id, event($0)) }, uniquingKeysWith: { first, _ in first })
        loaded = loaded || !layout.pets.isEmpty
    }

    /// The desks' walkers, one layer each, put in the stage beside the figures (by depth, in `cast`'s sort). Made again only
    /// when whose they are, how many, which pets or how they are shown change, or when the pets' frames come in; each walker
    /// is two repeating animations on its layer, which the render server runs: nothing here is redrawn or timed. A picture or
    /// Reduce Motion: standing in a row along the lane, not walking.
    private func placeWalkers(_ store: Store, _ layout: OfficeLayout) {
        let want = OfficePainter.walkers(store, layout)
        let mode: BGWalker.Mode = still ? .caught(BGWalker.stillTime) : calm ? .stands : .walks
        var keep = Set<Int>()
        for w in want {
            keep.insert(w.seat)
            let lane = OfficePainter.deskLane(seat: w.seat, layout: layout)
            let key = "\(w.id) \(w.pets) \(w.hung) \(mode) \(lane)"
            if let known = walkerHolders[w.seat], known.key == key { continue }
            walkerHolders[w.seat]?.holder.removeFromSuperlayer()
            guard let holder = OfficePainter.walkerLayer(w, layout: layout, mode: mode, caughtAt: BGWalker.stillTime) else {
                walkerHolders[w.seat] = nil  // not cut yet: tried again at the next look
                continue
            }
            walkerHolders[w.seat] = (holder, key)
        }
        for seat in Array(walkerHolders.keys) where !keep.contains(seat) {
            walkerHolders[seat]?.holder.removeFromSuperlayer()
            walkerHolders[seat] = nil
        }
    }

    /// Fades a pet out where it was and in where it now is, in 0.4 s: it moved, but not of its own doing.
    func swap(_ f: Figure, from start: CGPoint, was: Look) {
        set(f)
        let end = CGPoint(x: f.place.x, y: f.place.foot)
        let place = CAKeyframeAnimation(keyPath: "position")
        place.values = [NSValue(point: start), NSValue(point: end)]
        let depth = CAKeyframeAnimation(keyPath: "zPosition")
        depth.values = [start.y, end.y]
        let seen = CAKeyframeAnimation(keyPath: "opacity")
        seen.values = [1, 0, 1]
        let words = CAKeyframeAnimation(keyPath: "opacity")
        words.values = [0, 0, 1]
        for half in [place, depth] { half.calculationMode = .discrete }
        for fade in [place, depth, seen, words] {
            fade.keyTimes = [0, 0.5, 1]
            fade.duration = 0.4
        }
        f.layer.add(place, forKey: "swap")
        f.layer.add(depth, forKey: "swap-z")
        f.layer.add(seen, forKey: "door")
        f.words.add(words, forKey: "shown")
        if let old = was.still, old !== f.still {
            let hold = CAKeyframeAnimation(keyPath: "contents")
            hold.values = [old]
            hold.calculationMode = .discrete
            hold.duration = 0.2
            f.sprite.add(hold, forKey: "hold")
        }
        // Where it was it is as it was there, its size and strength too; where it now is, as it is now.
        guard was.pet != nil, f.pet != nil else { return }
        var halves: [(CALayer, String, String, [Any])] = []
        if abs(was.scale - f.scale) > 0.001 {
            halves += [f.sprite, f.shadow].map { ($0, "transform.scale", "grow", [was.scale / f.scale, 1]) }
        }
        if was.alpha != f.sprite.opacity { halves.append((f.sprite, "opacity", "fade", [was.alpha, f.sprite.opacity])) }
        for (part, path, key, values) in halves {
            let half = CAKeyframeAnimation(keyPath: path)
            half.values = values
            half.keyTimes = [0, 0.5, 1]
            half.calculationMode = .discrete
            half.duration = 0.4
            part.add(half, forKey: key)
        }
    }

    /// A walker on its aisle: from when it comes onto it to when it leaves it, and its height there meanwhile.
    struct Passage {
        let enters: CFTimeInterval, leaves: CFTimeInterval, from: CGFloat, to: CGFloat

        func y(_ t: CFTimeInterval) -> CGFloat { leaves > enters ? from + (to - from) * CGFloat((t - enters) / (leaves - enters)) : from }

        /// Whether `next` keeps its distance from this one: onto the aisle 0.35 s after it at the soonest, and never
        /// within 20 pt of it while both are on it. Both run straight, so the gap is least at one end of that time.
        func lets(_ next: Passage) -> Bool {
            guard next.enters >= enters + 0.35 - 0.000_1 else { return false }
            let from = max(enters, next.enters), to = min(leaves, next.leaves)
            guard from < to else { return true }
            let a = y(from) - next.y(from), b = y(to) - next.y(to)
            return abs(a) >= 20 && abs(b) >= 20 && (a > 0) == (b > 0)
        }
    }

    /// How long one that has just finished jumps where it stands before it sets off.
    func jumpSeconds(_ f: Figure, was: Look?) -> Double { was != nil && f.jumps ? min(1.2, f.jumpSeconds) : 0 }

    /// Fades a pet in where it now sits: a place opened for it.
    func appear(_ f: Figure) {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.4
        f.layer.add(fade, forKey: "door")
    }

    /// Fades a pet out where it sits, and takes it away: the room has no place for it now.
    func vanish(_ f: Figure) {
        let id = f.place.id
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        fade.delegate = Departure { [weak self, weak f] in
            guard let self, let f, f.leaving, self.figures[id] === f else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            f.layer.removeFromSuperlayer()
            CATransaction.commit()
            self.figures[id] = nil
        }
        f.layer.add(fade, forKey: "door")
    }

    /// How far its drawn pixels reach to either side of its feet on the way, so that a wall aisle keeps all
    /// of it inside the room: the frames it stands in, before and after, and every running frame, at the
    /// larger of the sizes it walks between (it changes size on the way, about its feet). A grey block, or
    /// a pet whose frames are not there, is taken as wide as a pet that tall is drawn standing.
    func body(_ f: Figure, was: Look?, tall: CGFloat) -> OfficeLayout.Body {
        let before = was.flatMap { $0.pet == f.pet ? [$0.stillFrame] : nil } ?? []
        guard let pet = f.pet, let extent = OfficePets.shared.extent(pet, stills: [f.stillFrame] + before) else {
            return OfficeLayout.body(tall: tall)
        }
        let body = OfficeLayout.body(spriteX: f.sprite.frame.minX, extent: extent, scale: f.scale)
        let grow = was.flatMap { $0.pet == nil ? nil : max(1, $0.scale / f.scale) } ?? 1
        return (body.left * grow, body.right * grow)
    }

    /// Where a pet is right now: along its walk, or at its place.
    func position(of figure: Figure) -> CGPoint {
        if room.sceneMode, let scene = Extensions.registered { return scene.position(self, figure) }
        return figure.layer.animation(forKey: "walk") != nil ? figure.layer.presentation()?.position ?? figure.layer.position : figure.layer.position
    }

    /// Gives a pet its pose and its words for where it is, painting only what changed. Its sprite and
    /// shadow are hung from its feet, so that it can grow or shrink standing where it is.
    func dress(_ f: Figure, _ store: Store, _ s: Session, _ layout: OfficeLayout, now: Date, scale: CGFloat) {
        let feet = CGPoint(x: f.place.x, y: f.place.foot)
        let spriteKey = Self.spriteKey(store, s, f.place, now: now)
        if spriteKey != f.spriteKey {
            let figure = OfficePainter.figure(store, s, f.place, now: now)
            // A grey block where a pet should be is not taken as drawn: its frames are being cut again.
            f.spriteKey = figure.pet == nil && store.displayPets[s.id] != nil ? "" : spriteKey
            hang(f.sprite, figure.sprite.rect.offsetBy(dx: -feet.x, dy: -feet.y))
            f.sprite.contents = figure.sprite.image
            f.sprite.opacity = Float(figure.sprite.alpha)
            hang(f.shadow, (figure.shadow?.rect ?? .zero).offsetBy(dx: -feet.x, dy: -feet.y))
            f.shadow.contents = figure.shadow?.image
            f.pet = figure.pet
            f.scale = figure.scale
            f.wide = figure.wide
            f.high = figure.high
            shape(f)
            f.still = figure.sprite.image
            let pose = f.place.sceneSlot != nil && f.place.kind == .work ? Pose.standing : store.pose(of: s, now: now)
            f.stillFrame = (pose.sheet.row, pose.sheet.still)
            f.loop = []
            f.frameSeconds = pose.sheet.ms / 1000
            f.jumps = pose == .celebrating
            f.knocks = pose == .waiting && WaitingNudge.enabled
            f.jumpSeconds = Double(pose.sheet.frames) * f.frameSeconds
            play(f)
            if let pet = figure.pet, pose.sheet.frames > 1, !still, !layout.sceneDriven {
                OfficePets.shared.scaled(pet, rows: [pose.sheet.row: pose.sheet.frames], scale: figure.scale) { [weak self, weak f] frames in
                    guard let self, let f, f.spriteKey == spriteKey else { return }
                    f.loop = frames[pose.sheet.row] ?? []
                    self.play(f)
                }
            }
        }
        let wordsKey = Self.wordsKey(store, s, f.place, layout, now: now, scale: scale)
        if wordsKey != f.wordsKey {
            f.wordsKey = wordsKey
            let words = OfficePainter.words(store, s, f.place, layout, now: now, scale: scale)
            f.words.contents = words?.image
            f.words.frame = (words?.rect ?? .zero).offsetBy(dx: -feet.x, dy: -feet.y)
        }
        f.restarting = s.restarting
        restartMark(f, scale: scale)
    }

    /// Puts the spinner on one whose session is being restarted, at its head and clear of every word shown near it (the
    /// queue head's bubble, cards, plates), and takes it off one that is back. It turns while the view is in a window and
    /// Reduce Motion is off; a scene that moves its figures itself places it again over the pose it sets.
    func restartMark(_ f: Figure, scale: CGFloat, plates: [CALayer]? = nil) {
        guard f.restarting, !f.leaving else {
            f.spinner?.removeFromSuperlayer()
            f.spinner = nil
            f.carrier.removeFromSuperlayer()
            return
        }
        let side = OfficeLook.type(RestartSpinner.side, scale: scale)
        if f.spinner?.bounds.width != side {
            f.spinner?.removeFromSuperlayer()
            f.spinner = RestartSpinner.layer(side: side)
        }
        guard let spinner = f.spinner else { return }
        // A scene that moves its figures itself may have scenery in front of whoever is behind it: there the spinner goes
        // on the figure's carrier, which the scene keeps with the figure (`SceneExtension.carry`).
        let carried = room.sceneDriven && Extensions.registered != nil
        let host = carried ? f.carrier : f.layer
        if spinner.superlayer !== host { host.addSublayer(spinner) }
        if carried {
            Extensions.registered?.carry(self, f)
        } else {
            f.carrier.removeFromSuperlayer()
        }
        let here = f.layer.position
        var avoid: [CGRect] = []
        for other in figures.values where !other.leaving && other.words.opacity > 0 && other.words.contents != nil {
            let there = other.layer.position
            avoid.append(other.words.frame.offsetBy(dx: there.x - here.x, dy: there.y - here.y))
        }
        // A scene's plates are the stage's own layers, those of this pass when it has them at hand.
        for plate in plates ?? figures.values.map(\.plate) where plate.superlayer != nil || plates != nil {
            avoid.append(plate.frame.offsetBy(dx: -here.x, dy: -here.y))
        }
        spinner.frame = RestartSpinner.spot(head: f.sprite.frame, side: side, avoid: avoid)
        RestartSpinner.spin(spinner, !still && !calm && window != nil)
    }

    /// Places a part of a pet in `rect` (round its feet), turning about the feet.
    private func hang(_ part: CALayer, _ rect: CGRect) {
        part.anchorPoint = rect.width > 0 && rect.height > 0 ? CGPoint(x: -rect.minX / rect.width, y: -rect.minY / rect.height) : .zero
        part.frame = rect
    }

    /// Loops the pose's frames on the sprite from when the pet arrives, the way `SpriteLoop` does on
    /// the board; a pose of one frame stays still. One that has just finished jumps until it sets off.
    /// Out of a window nothing is played: coming back to one starts it again.
    private func play(_ f: Figure) {
        f.sprite.removeAnimation(forKey: "loop")
        f.sprite.removeAnimation(forKey: "jump")
        knock(f)
        guard !still, !f.leaving, window != nil, f.loop.count > 1 else { return }
        let now = CACurrentMediaTime()
        let loop = CAKeyframeAnimation(keyPath: "contents")
        loop.values = f.loop
        loop.calculationMode = .discrete
        loop.duration = f.frameSeconds * Double(f.loop.count)
        loop.repeatCount = .infinity
        if f.arrival > now { loop.beginTime = f.sprite.convertTime(f.arrival, from: nil) }
        f.sprite.add(loop, forKey: "loop")
        if f.jumps, f.departs > now, let jump = loop.copy() as? CAKeyframeAnimation {
            jump.beginTime = 0
            jump.repeatCount = Float((f.departs - now) / loop.duration)
            f.sprite.add(jump, forKey: "jump")
        }
    }

    /// Waiting for you, a pet stands on one frame and knocks every three seconds, turning about its feet, from when it has
    /// arrived; with Reduce Motion it does not lean but wears a coral ring that fades between full and a quarter strength.
    /// Both run on Core Animation from here on; coming back to a window starts them again (`play`).
    private func knock(_ f: Figure) {
        f.sprite.removeAnimation(forKey: WaitingNudge.tiltKey)
        f.ring?.removeAnimation(forKey: WaitingNudge.ringKey)
        guard f.knocks, !still, !f.leaving, window != nil, f.sprite.bounds.width > 0 else {
            f.ring?.removeFromSuperlayer()
            f.ring = nil
            return
        }
        let phase = WaitingNudge.phase(of: f.place.id)
        let begin = f.arrival > CACurrentMediaTime() ? f.sprite.convertTime(f.arrival, from: nil) : 0
        if WaitingNudge.calm() {
            let rect = WaitingNudge.ringRect(wide: f.wide, high: f.high, down: WaitingNudge.flipped(f.sprite))
            if f.ring == nil || f.ring?.path?.boundingBox != rect {
                f.ring?.removeFromSuperlayer()
                let ring = WaitingNudge.ring(rect: rect, corner: min(rect.width, rect.height) * 0.3, width: 2)
                ring.opacity = 0  // shown only while its fade runs: not before it has arrived
                f.ring = ring
                f.layer.addSublayer(ring)
            }
            f.ring?.add(WaitingNudge.pulse(phase: phase, begin: begin), forKey: WaitingNudge.ringKey)
        } else {
            f.ring?.removeFromSuperlayer()
            f.ring = nil
            let pivot = WaitingNudge.feetPivot(of: f.sprite)
            f.sprite.add(WaitingNudge.tilt(pivot: pivot, flipped: WaitingNudge.flipped(f.sprite), phase: phase, begin: begin), forKey: WaitingNudge.tiltKey)
        }
    }

    /// Everything a walk or a slide puts on a pet.
    private static let travel = ["walk", "walk-z", "door", "swap", "swap-z"], partTravel = ["steps", "hold", "jump", "grow", "fade", "shown"]

    /// Puts a pet at its place at once.
    func set(_ f: Figure) {
        Extensions.registered?.willSet(self, f)
        for key in Self.travel { f.layer.removeAnimation(forKey: key) }
        for part in [f.sprite, f.shadow, f.words] {
            for key in Self.partTravel { part.removeAnimation(forKey: key) }
        }
        f.departs = 0
        f.arrival = 0
        f.walks += 1
        f.layer.position = CGPoint(x: f.place.x, y: f.place.foot)
        f.layer.zPosition = f.place.foot
        shape(f)
        f.words.opacity = 1
        play(f)
    }

    /// Moves a pet along the queue: a short glide with its card on, changing size on the way.
    func slide(_ f: Figure, from start: CGPoint, was: Look) {
        set(f)
        let now = CACurrentMediaTime(), end = CGPoint(x: f.place.x, y: f.place.foot)
        f.departs = now
        f.arrival = now  // its pose keeps going as it glides
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: start)
        move.toValue = NSValue(point: end)
        move.duration = 0.3
        move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        f.layer.add(move, forKey: "walk")
        change(f, from: was, begin: now, seconds: 0.3)
        play(f)
    }

    /// The size and the see-through of where it was, turning into those of where it goes.
    private func change(_ f: Figure, from was: Look?, begin: CFTimeInterval, seconds: Double) {
        guard let was, was.pet != nil, f.pet != nil else { return }
        if abs(was.scale - f.scale) > 0.001 {
            for part in [f.sprite, f.shadow] {
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = was.scale / f.scale
                grow.toValue = 1
                grow.beginTime = part.convertTime(begin, from: nil)
                grow.duration = seconds
                grow.fillMode = .backwards
                part.add(grow, forKey: "grow")
            }
        }
        if was.alpha != f.sprite.opacity {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = was.alpha
            fade.toValue = f.sprite.opacity
            fade.beginTime = f.sprite.convertTime(begin, from: nil)
            fade.duration = seconds
            fade.fillMode = .backwards
            f.sprite.add(fade, forKey: "fade")
        }
    }

    /// Sends a pet along a route at a walking pace in its running frames, its words hidden until it
    /// arrives and takes up its pose. It sets off at `departs`, or once the jump of one that has just
    /// finished is over; until then it stands as it was. A long way is walked faster: no walk takes
    /// over 2.5 s. One coming in fades in at the door; one leaving fades out there and is taken away.
    func walk(_ f: Figure, along route: [CGPoint], departs: CFTimeInterval, was: Look?, entering: Bool = false) {
        // In an extension's scene: the scene walks it itself (nil), or says where this walk really ends.
        var route = route
        if room.sceneMode, let scene = Extensions.registered {
            guard let ways = scene.walk(self, f, along: route, departs: departs) else { return }
            route = ways
        }

        let legs = zip(route, route.dropFirst()).map { (from: $0, to: $1, length: hypot($1.x - $0.x, $1.y - $0.y)) }
        let length = legs.reduce(0) { $0 + $1.length }
        guard length > 0.5, let end = route.last else { return set(f) }
        let jump = jumpSeconds(f, was: was)
        set(f)
        let now = CACurrentMediaTime(), seconds = OfficeLayout.walkSeconds(route), start = max(departs, now + jump)
        f.departs = start
        f.arrival = start + seconds
        let begin = f.layer.convertTime(start, from: nil)
        var walked: CGFloat = 0
        let times = [NSNumber(value: 0)] + legs.map { leg -> NSNumber in
            walked += leg.length
            return NSNumber(value: Double(walked / length))
        }
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = route.map { NSValue(point: $0) }
        // Nearer the front the further down the room, all the way; a walker passes in front of one
        // sitting on the line it walks along.
        let depth = CAKeyframeAnimation(keyPath: "zPosition")
        depth.values = route.dropLast().map { $0.y + 0.5 } + [end.y]
        for along in [move, depth] {
            along.keyTimes = times
            along.duration = seconds
            along.beginTime = begin
            along.fillMode = .backwards
        }
        if f.leaving {
            let id = f.place.id
            move.delegate = Departure { [weak self, weak f] in
                guard let self, let f, f.leaving, self.figures[id] === f else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                f.layer.removeFromSuperlayer()
                CATransaction.commit()
                self.figures[id] = nil
            }
        }
        f.layer.position = end
        f.layer.zPosition = end.y
        shape(f)
        f.layer.add(move, forKey: "walk")
        f.layer.add(depth, forKey: "walk-z")
        if entering || f.leaving {
            let door = CABasicAnimation(keyPath: "opacity")
            door.fromValue = entering ? 0 : 1
            door.toValue = entering ? 1 : 0
            door.duration = 0.15
            door.beginTime = entering ? begin : begin + seconds - 0.15
            door.fillMode = entering ? .backwards : .forwards
            door.isRemovedOnCompletion = entering
            f.layer.add(door, forKey: "door")
        }
        // Until it sets off it stands as it was (the jump is added by `play`); on the way it changes size.
        if let old = was?.still, old !== f.still, jump == 0 {
            let hold = CAKeyframeAnimation(keyPath: "contents")
            hold.values = [old]
            hold.calculationMode = .discrete
            hold.duration = start + seconds - now
            f.sprite.add(hold, forKey: "hold")
        }
        change(f, from: was, begin: start, seconds: seconds)
        // Its words are already those of where it goes: hidden from now until it arrives there.
        f.words.opacity = f.leaving ? 0 : 1
        if !f.leaving {
            let total = start - now + seconds + 0.2
            let shown = CAKeyframeAnimation(keyPath: "opacity")
            shown.values = [0, 0, 1]
            shown.keyTimes = [0, NSNumber(value: (total - 0.2) / total), 1]
            shown.duration = total
            f.words.add(shown, forKey: "shown")
        }
        // The running frames join in step with the walk whenever they are ready.
        if let pet = f.pet {
            let walk = f.walks, still = f.still
            let rows = Dictionary(Self.rows(for: legs).map { ($0, 8) }, uniquingKeysWith: { first, _ in first })
            // Through the facing table (a sheet whose row 1 runs left shows row 1 mirrored going right).
            OfficePets.shared.scaledRun(pet, facings: rows, scale: f.scale) { [weak f] frames in
                guard let f, f.walks == walk, CACurrentMediaTime() < f.arrival, let steps = Self.steps(frames, legs, seconds: seconds, still: still)
                else { return }
                steps.beginTime = begin
                f.sprite.add(steps, forKey: "steps")
            }
        }
        play(f)
    }

    /// Which running frames each leg of a walk takes: to the right or to the left (logical facings, `OfficePets.right` /
    /// `.left`, which the facing table turns into the sheet's rows). A leg up or down the room (across by less than a
    /// quarter of its length, straight up or down included) keeps the facing it had (the first, the next leg's; to the
    /// right when none goes across), as in the Seaview scene: the pets have no back or front view, and many sheets' row 7 is no run.
    nonisolated static func rows(for legs: [(from: CGPoint, to: CGPoint, length: CGFloat)]) -> [Int] {
        let raw = legs.map { leg -> Int in
            let dx = leg.to.x - leg.from.x
            if abs(dx) < 0.5 || abs(dx) < leg.length * ZoneWalk.nearlyUpright { return 0 }
            return dx > 0 ? OfficePets.right : OfficePets.left
        }
        var out: [Int] = []
        for (i, r) in raw.enumerated() {
            if r != 0 { out.append(r); continue }
            if let before = out.last { out.append(before); continue }
            out.append(raw[(i + 1)...].first { $0 != 0 } ?? OfficePets.right)
        }
        return out
    }

    /// The running frames along a walk, leg by leg, 0.1 s a frame. A row the sheet lacks shows the pet still.
    private static func steps(
        _ frames: [Int: [CGImage]], _ legs: [(from: CGPoint, to: CGPoint, length: CGFloat)], seconds: Double, still: CGImage?
    ) -> CAKeyframeAnimation? {
        let length = legs.reduce(0) { $0 + $1.length }
        var values: [CGImage] = [], times: [NSNumber] = []
        var start = 0.0
        for (leg, row) in zip(legs, Self.rows(for: legs)) where leg.length > 0 {
            let step = 0.1, span = seconds * Double(leg.length / length)
            guard let shown = frames[row].flatMap({ $0.isEmpty ? nil : $0 }) ?? still.map({ [$0] }) else { return nil }
            var t = 0.0
            repeat {
                values.append(shown[Int((t / step).rounded()) % shown.count])
                times.append(NSNumber(value: (start + t) / seconds))
                t += step
            } while t < span
            start += span
        }
        guard !values.isEmpty else { return nil }
        let steps = CAKeyframeAnimation(keyPath: "contents")
        steps.values = values
        steps.keyTimes = times + [1]
        steps.calculationMode = .discrete
        steps.duration = seconds
        return steps
    }

    /// Tells the pointer where everyone is, in the window's view's coordinates: where each pet is
    /// going, not where its sprite is on the way. In a scene that moves its figures itself, where each is now and can
    /// be pointed at, for it is seldom at its place there: its card goes beside that (`OfficeHover.cardTarget`).
    /// While the office shows, these are the only frames: the board is not there to report its cards.
    private func publish(_ store: Store, _ fit: OfficeFit) {
        let host = window?.contentView ?? self
        var frames = [OfficeLayout.doorKey: convert(fit.rect(room.loungeTarget), to: host)]
        if room.boardShown { frames[OfficeLayout.boardKey] = convert(fit.rect(OfficeLayout.boardArea), to: host) }
        for chip in room.chips { frames[chip.kind.key] = convert(fit.rect(chip.rect), to: host) }
        for place in room.pets { frames[place.id] = convert(fit.rect(liveRect(place.id) ?? place.frame), to: host) }
        // The list up by the door or the chip says itself where it and its rows are, as SwiftUI lays them out: kept.
        for (key, rect) in store.tracker.frames where OfficeList.entry(key) != nil { frames[key] = rect }
        if store.tracker.frames != frames { store.tracker.frames = frames }
        if store.tracker.resolver !== self { store.tracker.resolver = self }
    }

    /// The view's layers as one picture, as the window would show them at rest: for snapshots and checks.
    func image(presentation: Bool = false, pixelScale:CGFloat = 2) -> CGImage? {
        guard let layer, bounds.width > 0, bounds.height > 0, pixelScale > 0,
            let ctx = CGContext(
                data: nil, width: Int(bounds.width * pixelScale), height: Int(bounds.height * pixelScale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        if layer.isGeometryFlipped {
            ctx.translateBy(x: 0, y: bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        (presentation ? layer.presentation() ?? layer : layer).render(in: ctx)
        return ctx.makeImage()
    }

    /// For the pointer, in the window's view's coordinates: the same answer a click there gets, except on a row of the
    /// list up by the door or a chip, which is that row: it lights up, and a right-click there is for its session.
    func card(at point: CGPoint) -> String? {
        if let store, let listed = OfficeList.pointed(at: point, frames: store.tracker.frames, hovered: store.sceneListOpen ? OfficeLayout.doorKey:store.hovered) { return listed }
        switch target(at: convert(point, from: window?.contentView ?? self)) {
        case .pet(let id):
            // The card that comes up goes beside where it is as the pointer comes onto it, whichever of the card and this
            // view's pass that brings is drawn first.
            if let store, let now = liveRect(id) { store.tracker.frames[id] = convert(fit.rect(now), to: window?.contentView ?? self) }
            return id
        case .door: return OfficeLayout.doorKey
        case .chip(let kind): return kind.key
        case .board: return OfficeLayout.boardKey
        case nil: return nil
        }
    }

    /// What a click at this point of the view is for: the pet in front there, a chip, the notice board, or the door. While
    /// the list by the door or a chip is up, anywhere on it or in the gap to it is that door or chip, not a pet under it.
    func target(at point: CGPoint) -> Target? {
        let host = convert(point, to: window?.contentView ?? self)
        if let store, let pointed = OfficeList.pointed(at: host, frames: store.tracker.frames, hovered: store.sceneListOpen ? OfficeLayout.doorKey:store.hovered),
            let listed = OfficeList.open(pointed)
        {
            return OfficeLayout.ChipKind.allCases.first { $0.key == listed }.map { .chip($0) } ?? .door
        }
        let spot = fit.point(point)
        if room.sceneMode, let scene = Extensions.registered {
            if let id = scene.target(self, at: spot) { return .pet(id) }
        } else if let id = room.session(at: spot) { return .pet(id) }
        if let chip = room.chips.first(where: { $0.rect.contains(spot) }) { return .chip(chip.kind) }
        if room.boardShown && OfficeLayout.boardArea.contains(spot) { return .board }
        return room.loungeTarget.contains(spot) ? .door : nil
    }

    // Like a button: it counts when the pointer is still on the same thing as it lets go.
    override func mouseDown(with event: NSEvent) {
        pressed = target(at: convert(event.locationInWindow, from: nil))
        if let store,store.sceneListOpen,pressed != .door {store.sceneListOpen=false;pressed=nil}
    }

    override func mouseUp(with event: NSEvent) {
        let released = target(at: convert(event.locationInWindow, from: nil))
        defer { pressed = nil }
        guard let store, let pressed, pressed == released else { return }
        switch pressed {
        case .pet(let id):
            guard let s = store.sessions.first(where: { $0.id == id }) else { return }
            store.markSeen(s)
            // Lit at once, its fade begun on this click, not on SwiftUI's next pass nor on the next look at Orca.
            if store.expectFocus(s) { lightNow(store) }
            if let onClick { onClick(s) } else { jump(to: s, expect: false) }
        case .door where room.sceneDriven:
            store.sceneListOpen.toggle()  // the scene's own list of those behind its door (`SceneExtension.overlay`)
        case .door, .chip:
            showOffice(false, store: store)  // the ones behind the door, or counted on a chip, are on the board
        case .board:
            break  // its card is the whole of it: pointing shows it
        }
    }
}

/// The office view in the panel's SwiftUI content, following the store as the board does.
struct OfficeRoom: NSViewRepresentable {
    // Observed, not just held: the same store each time would otherwise look like nothing changed.
    @ObservedObject var store: Store

    func makeNSView(context: Context) -> OfficeView {
        let view = OfficeView(frame: .zero)
        view.listen()
        return view
    }

    func updateNSView(_ view: OfficeView, context: Context) { view.update(store) }

    static func dismantleNSView(_ view: OfficeView, coordinator: ()) {
        view.stopListening()
        // The board takes the pointer's frames over on its first layout; whoever was pointed at
        // here is not pointed at there.
        if let store = view.store { DispatchQueue.main.async { store.tracker.pointer(at: nil) } }
        view.store = nil
    }
}

/// The lists that come up by the lounge door and by the waiting chip, among the pointer's targets: each list's card, the
/// strip of gap between it and what it is beside, and each of its rows, under keys of their own; session ids are UUIDs, so
/// these meet none. While the pointer is on a row, `Store.hovered` is that row's key: it says which list is up and which row to light,
/// and nothing in the room dims or rings for it as it would for that session's pet.
enum OfficeList {
    #if TESTING
    @MainActor static var activateForTest:((Session)->Void)?
    #endif
    /// The door and the chip that have a list.
    static let keys = [OfficeLayout.doorKey, OfficeLayout.ChipKind.waiting.key]

    static func card(_ list: String) -> String { list + "/card" }
    static func gap(_ list: String) -> String { list + "/gap" }
    static func row(_ list: String, _ id: String) -> String { list + "/" + id }

    /// Which list a card's, a gap's or a row's key belongs to, and for a row its session; nil for any other key.
    static func entry(_ key: String) -> (list: String, id: String?)? {
        guard let slash = key.firstIndex(of: "/") else { return nil }
        let list = String(key[..<slash]), rest = String(key[key.index(after: slash)...])
        // A Seaview sign's list (`zoneListPrefix`) is one more: its rows go to their sessions, right-click included.
        guard keys.contains(list) || list.hasPrefix(zoneListPrefix), !rest.isEmpty else { return nil }
        return (list, rest == "card" || rest == "gap" || rest == "close" ? nil : rest)
    }

    /// The session a row's key is for.
    static func session(_ key: String) -> String? { entry(key)?.id }

    /// The list that is up while this is pointed at: the door or the chip itself, or a row of its list.
    static func open(_ hovered: String?) -> String? {
        guard let hovered else { return nil }
        return keys.contains(hovered) ? hovered : entry(hovered).flatMap { $0.id == nil ? nil : $0.list }
    }

    /// What the pointer is on at this point of the window while a list is up: the row there; else, anywhere on the card,
    /// on what it is beside (the room's own entry for it) or on the strip between the two, that door or chip. Nil off
    /// them, and with no list up: there the room answers, the corners of their bounding box included.
    static func pointed(at point: CGPoint, frames: [String: CGRect], hovered: String?) -> String? {
        guard let list = open(hovered), [list, card(list), gap(list)].contains(where: { frames[$0]?.contains(point) ?? false })
        else { return nil }
        let row = frames.first { key, rect in entry(key).map { $0.list == list && $0.id != nil } ?? false && rect.contains(point) }
        return row?.key ?? list
    }
}

/// The card that comes up beside what the pointer is on in the office: the office's own card for a pet, unfolding from
/// it; the list of who is behind the door, or waits beyond the queue, whose rows take clicks; or what happened lately,
/// for the notice board. The pet's card and the board's take no clicks: those belong to the room under them.
struct OfficeHover: View {
    let fit: OfficeFit  // from the picture into this view
    let origin: CGPoint  // this view's top-left in the window
    let window: CGSize
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z
    @Environment(\.accessibilityReduceMotion) private var calm
    @Environment(\.still) private var still

    /// Where a card goes, in the window: right of what is pointed at, left of it, below it or above it, each kept inside
    /// the window and clear of the title bar; the first that covers neither the pet nor any of `avoid` (the partners its
    /// lines point to). If each covers a partner, the one covering fewest. It never covers the pet it is about while any
    /// place clears it; only with room nowhere, the side with more of it.
    /// The pet's card: room on its name line for a long name with the time beside it.
    static let cardWidth: CGFloat = 320

    static func origin(beside target: CGRect, card: CGSize, window: CGSize, avoid: [CGRect] = []) -> CGPoint {
        let gap: CGFloat = 10, margin: CGFloat = 8, titleBar: CGFloat = 34
        func inside(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: max(margin, min(x, window.width - margin - card.width)), y: max(titleBar, min(y, window.height - margin - card.height)))
        }
        let level = target.midY - card.height / 2, middle = target.midX - card.width / 2
        let places = [
            inside(target.maxX + gap, level), inside(target.minX - gap - card.width, level), inside(middle, target.maxY + gap),
            inside(middle, target.minY - gap - card.height),
        ].filter { !CGRect(origin: $0, size: card).intersects(target) }
        func covered(_ p: CGPoint) -> Int { avoid.filter { CGRect(origin: p, size: card).intersects($0) }.count }
        if let best = places.min(by: { covered($0) < covered($1) }) { return best }  // the first of the fewest
        // Room nowhere: the side with more of it.
        let x = inside(middle, 0).x
        return CGPoint(x: x, y: target.minY - titleBar > window.height - target.maxY ? titleBar : window.height - margin - card.height)
    }

    /// The strip between what a list's card is beside and the card, on the side the card went: as wide as the gap, as
    /// long as their facing edges overlap (as long as both, should they not). With it the two are one target the pointer
    /// crosses without meeting the room, and the corners of their bounding box stay the room's. None where the card covers
    /// what it is beside: they already touch.
    nonisolated static func gap(between target: CGRect, _ card: CGRect) -> CGRect {
        func span(_ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) -> (CGFloat, CGFloat) {
            let shared = (max(a.0, b.0), min(a.1, b.1))
            return shared.1 > shared.0 ? shared : (min(a.0, b.0), max(a.1, b.1))
        }
        let rows = span((target.minY, target.maxY), (card.minY, card.maxY)), columns = span((target.minX, target.maxX), (card.minX, card.maxX))
        if card.minX >= target.maxX { return CGRect(x: target.maxX, y: rows.0, width: card.minX - target.maxX, height: rows.1 - rows.0) }
        if card.maxX <= target.minX { return CGRect(x: card.maxX, y: rows.0, width: target.minX - card.maxX, height: rows.1 - rows.0) }
        if card.minY >= target.maxY { return CGRect(x: columns.0, y: target.maxY, width: columns.1 - columns.0, height: card.minY - target.maxY) }
        if card.maxY <= target.minY { return CGRect(x: columns.0, y: card.maxY, width: columns.1 - columns.0, height: target.minY - card.maxY) }
        return .zero
    }

    /// Which way a card unfolds from what it is about, both in the window: from its edge nearest that, across when it is
    /// beside it, down or up when below or above it. Where it found room nowhere and covers the pet, by which half it is on.
    nonisolated static func unfold(card: CGRect, from target: CGRect) -> (anchor: UnitPoint, across: Bool) {
        if card.minX >= target.maxX { return (.leading, true) }
        if card.maxX <= target.minX { return (.trailing, true) }
        return card.midY >= target.midY ? (.top, false) : (.bottom, false)
    }

    /// What a pet's card goes beside, in the window: its place; in a scene that moves its figures itself, where the figure
    /// was when the view last told the pointer (`OfficeView.publish`, each pass, and as the pointer comes onto it), for it
    /// is seldom at its place there. So on a moving figure the card moves with the view's passes (a store tick, about
    /// every 2 s), at once, and stands still in between.
    nonisolated static func cardTarget(_ id: String, place: CGRect, live: Bool, frames: [String: CGRect]) -> CGRect {
        live ? frames[id] ?? place : place
    }

    var body: some View {
        OfficeCardSpot(window: window, origin: origin) { card }
            // The pet's card unfolds as the pointer comes and folds as it goes, at its transition's own pace; a list's row
            // lights up under the pointer. The other cards come and go at once, as they always have.
            .animation(.easeOut(duration: 0.16), value: store.hovered)
    }

    @ViewBuilder private var card: some View {
        if ZoneUI.active {
            zoneCard
        } else if store.sceneListOpen, let scene = Extensions.active, scene.drivesFigures {
            // The scene's own list of those behind its door, up until it is closed.
            let layout=OfficePainter.layout(store,now:Date(),height:fit.height,scale:fit.scale)
            listed(scene.doorList(ids:layout.restListIDs),key:OfficeLayout.doorKey,beside:spot(layout.loungeTarget),dismissToBoard:false)
        } else if store.hovered == OfficeLayout.boardKey {
            beside(spot(OfficeLayout.boardArea), backing(OfficeBoardCard(lines: OfficeBoardCard.lines(store))).allowsHitTesting(false))
                .transition(.identity)
        } else if let id = store.hovered {
            // A visitor's card goes beside it where it stands.
            let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
                .visited(
                    by: OfficeSeats.visits(for: store), talking: OfficeVisits.talking(store.peers, now: Date()),
                    sizes: OfficePets.shared.sizes(store))
            let list = OfficeList.open(id)
            if list == OfficeLayout.doorKey, layout.behindDoor > 0, !layout.sceneDriven {
                listed(OfficeDoorCard(ids: layout.behindDoorIDs), key: OfficeLayout.doorKey, beside: spot(layout.loungeTarget))
            } else if list == OfficeLayout.ChipKind.waiting.key, let chip = layout.chips.first(where: { $0.kind == .waiting }) {
                listed(OfficeWaitingCard(ids: layout.waitingElsewhere), key: chip.kind.key, beside: spot(chip.rect))
            } else if let place = layout.pets.first(where: { $0.id == id }), !(layout.sceneMode && place.zone == .queue), let s = store.sessions.first(where: { $0.id == id }) {
                // Clear of the partners its lines point to, where they are in the room.
                let partners = (store.peers[id] ?? []).compactMap { peer in layout.pets.first { $0.id == peer.id } }
                let target = Self.cardTarget(id, place: spot(place.frame), live: layout.sceneDriven, frames: store.tracker.frames)
                beside(target, avoid: partners.map { spot($0.body.union($0.mark)) }, OfficeCard(s: s).allowsHitTesting(false))
                    .transition(unfolding(from: target))
                    // Each pet its own card: moving straight to another, this one folds by its pet as that one's unfolds.
                    .id(id)
            }
        }
    }

    /// Seaview: its view tells the pointer where each figure and sign is, in the window; the card goes beside that.
    @ViewBuilder private var zoneCard: some View {
        if let open = ZoneUI.open {
            listed(ZoneListCard(key: open), key: open, beside: store.tracker.frames[open] ?? .zero, dismissToBoard: false)
        } else if let id = store.hovered, let target = store.tracker.frames[id], let s = store.sessions.first(where: { $0.id == id }) {
            beside(target, ZoneCard(s: s).allowsHitTesting(false))
                .transition(unfolding(from: target))
                .id(id)
        }
    }

    private func spot(_ r: CGRect) -> CGRect { fit.rect(r).offsetBy(dx: origin.x, dy: origin.y) }

    private func beside<V: View>(_ target: CGRect, avoid: [CGRect] = [], _ card: V) -> some View {
        card.layoutValue(key: OfficeCardSpot.Beside.self, value: (target, avoid))
    }

    // Out of the pet easing out, back into it easing in as it goes.
    private func unfolding(from target: CGRect) -> AnyTransition {
        .asymmetric(
            insertion: AnyTransition(OfficeUnfold(from: target, fades: calm)).animation(.easeOut(duration: 0.16)),
            removal: AnyTransition(OfficeUnfold(from: target, fades: calm)).animation(.easeIn(duration: 0.1)))
    }

    /// A list's card: its rows take clicks, and the rest of it is the door's or the chip's own ground, where a click shows
    /// the board as a click on them does. While it is up it tells the pointer where it is, and the strip of gap between it
    /// and what it is beside. A still picture of it tells the pointer nothing, and takes nothing back when it goes: the
    /// live card's entries stay.
    private func listed<V: View>(_ list: V, key: String, beside target: CGRect,dismissToBoard:Bool=true) -> some View {
        let card = backing(list).contentShape(Rectangle())
            .gesture(TapGesture().onEnded { [store] in showOffice(false,store:store) },including:dismissToBoard ? .all:.subviews)
            .onGeometryChange(for: [CGRect].self) { [$0.frame(in: .global), Self.gap(between: target, $0.frame(in: .global))] } action: {
                [store, still] in
                if !still {
                    store.tracker.frames[OfficeList.card(key)] = $0[0]
                    store.tracker.frames[OfficeList.gap(key)] = $0[1]
                }
            }
            .onDisappear { [store, still] in
                if !still { store.tracker.frames = store.tracker.frames.filter { OfficeList.entry($0.key)?.list != key } }
            }
        // Last: what the card goes beside does not reach its layout through the geometry watch.
        return beside(target, card).transition(.identity)
    }

    // Some of the list and board cards' fills are see-through: they sit on an opaque backing.
    private func backing<V: View>(_ card: V) -> some View {
        card.padding(8)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(night)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
            )
    }
}

/// Puts each card where `OfficeHover.origin` says, beside what it is about, once it knows how tall the card came out.
struct OfficeCardSpot: Layout {
    /// What a card goes beside and keeps clear of, in the window. Each card carries its own: one folding away stays by the
    /// pet the pointer left while the next unfolds by its own.
    struct Beside: LayoutValueKey {
        static let defaultValue: (target: CGRect, avoid: [CGRect]) = (.zero, [])
    }
    let window: CGSize
    let origin: CGPoint  // this layout's top-left in the window

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for card in subviews {
            let size = card.sizeThatFits(.unspecified), beside = card[Beside.self]
            let at = OfficeHover.origin(beside: beside.target, card: size, window: window, avoid: beside.avoid)
            card.place(at: CGPoint(x: bounds.minX + at.x - origin.x, y: bounds.minY + at.y - origin.y), proposal: ProposedViewSize(size))
        }
    }
}

/// A pet's card unfolding from the pet: from its edge nearest the pet, a quarter of its width (or height) growing to the
/// whole as it fades in; folding back the same way. With Reduce Motion, the fade alone.
struct OfficeUnfold: Transition {
    let from: CGRect  // the pet, in the window
    let fades: Bool

    func body(content: Content, phase: TransitionPhase) -> some View {
        let from = from, open = phase.isIdentity, folded: CGFloat = fades ? 1 : 0.25
        return content.visualEffect { effect, geometry in
            // Which of its edges faces the pet is known only once the card is placed.
            let way = OfficeHover.unfold(card: geometry.frame(in: .global), from: from), scale = open ? 1 : folded
            return effect.scaleEffect(x: way.across ? scale : 1, y: way.across ? 1 : scale, anchor: way.anchor).opacity(open ? 1 : 0)
        }
    }
}

/// The office's own card for a pet: the board's facts about the session without the board's pet, which stands right
/// there; light, so it reads at once against the dark room; a stripe down its left edge in the colour of what it is doing.
/// As wide as `OfficeHover.cardWidth`, as tall as its words.
struct OfficeCard: View {
    let s: Session
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    static let fill: UInt32 = 0xF4F1EA, edge: UInt32 = 0xD8D2C4, stone: UInt32 = 0xB9B2A4

    /// Coral while it waits for you, green while it works, a quiet stone otherwise. Not paper: that is the sofas' colour, and
    /// would vanish on this card.
    /// An error's brick red, a retry's or the limit's amber, an exit's grey (`tone`, the store's `failTone`) before all that.
    static func stripe(_ s: Session, tone: FailTone? = nil) -> UInt32 {
        if let tone { return tone.hex }
        return s.status == "waiting" ? OfficeLook.call : s.isWorking ? OfficeLook.work : stone
    }

    /// The project, after the model a Codex session runs on when its thread says: next to the tag it reads "Codex gpt-…", and
    /// on a long line it is the project that gives way, not the model.
    static func projectLine(_ s: Session, model: String?) -> String { model.map { $0 + " · " + s.project } ?? s.project }

    /// A line for each of a session's running subagents, as the desk shows three at most and then how many more:
    /// "Subagent · <what it was asked> · <its model>", either part left out when not known.
    static func agentLines(_ agents: [OfficeSubagents.Agent]) -> [String] {
        agents.prefix(3).map { agent in
            ([L10n.string("agent.label", table: "Office", zh: "子代理"), agent.description, OfficeSubagents.name(of: agent.model)].filter { !$0.isEmpty }).joined(separator: " · ")
        } + (agents.count > 3 ? [L10n.format("agents.more", table: "Office", zh: "还有 %lld 个", agents.count - 3)] : [])
    }

    /// The card's helper lines: the subagents, then how many background commands (those the dump gives no name).
    static func helperLines(_ s: Session, _ agents: [OfficeSubagents.Agent]) -> [String] {
        agentLines(agents) + (s.bgTasks - s.bgAgents > 0 ? [bgCommandsWords(s.bgTasks - s.bgAgents)] : [])
    }

    var body: some View {
        let now = Date(), waits = s.status == "waiting", corner = RoundedRectangle(cornerRadius: 10 * z, style: .continuous)
        // Words in coral itself are faint on this light card (2.5:1); the room's deeper pin coral reads (3.9:1). The stripe
        // keeps the coral: it is the signal, not the reading.
        let asks = Color(hex: OfficeLook.pin)
        VStack(alignment: .leading, spacing: 4 * z) {
            HStack(alignment: .firstTextBaseline, spacing: 6 * z) {
                Text(s.shownName).font(rounded(13 * z)).lineLimit(1)
                    .layoutPriority(1)  // The project gives way first, not the name
                if let tag = kindTag(s) { KindTag(text: tag, z: z) }
                Text(Self.projectLine(s, model: store.model(of: s))).font(.system(size: 10.5 * z)).opacity(0.6).lineLimit(1)
                Spacer(minLength: 0)
                if s.isWorking { WorkingDots(size: 5 * z) }
                if s.status == "idle" && store.pinned.contains(s.id) { PinMark(size: 10 * z) }
                Text(timeLabel(s, now: now)).font(rounded(10.5 * z, .medium)).foregroundStyle(waits ? asks : ink.opacity(0.6)).fixedSize()
            }
            if !s.summary.isEmpty {
                // A waiting one's summary is what it asks of you.
                Text(s.shownSummary).font(.system(size: 11.5 * z, weight: waits ? .medium : .regular)).lineSpacing(1.5 * z)
                    .foregroundStyle(waits ? asks : ink.opacity(0.9)).lineLimit(4).fixedSize(horizontal: false, vertical: true)
            }
            let helping = Self.helperLines(s, store.agents[s.id] ?? [])
            if !helping.isEmpty {
                // Its own doing, so quieter than its summary; a long ask gives way in its middle, keeping the model.
                VStack(alignment: .leading, spacing: 2 * z) {
                    ForEach(Array(helping.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(size: 10.5 * z)).foregroundStyle(ink.opacity(0.6)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            if let note = originNote(s) { Text(note).font(.system(size: 10.5 * z)).foregroundStyle(ink.opacity(0.5)).lineLimit(1) }
            if let peers = store.peers[s.id] { LinksRow(peers: peers, now: now) }
        }
        .foregroundStyle(ink)
        .padding(.vertical, 12 * z).padding(.leading, 16 * z).padding(.trailing, 12 * z)
        .frame(width: OfficeHover.cardWidth * z, alignment: .leading)
        .background(Color(hex: Self.fill))
        .overlay(corner.strokeBorder(Color(hex: Self.edge), lineWidth: 1))
        .overlay(alignment: .leading) { Color(hex: Self.stripe(s, tone: store.failTone(s))).frame(width: 4 * z) }  // over the edge: it is the edge there
        .clipShape(corner)
        // As one: otherwise each word and the stripe would cast its own shadow on the card, greying it.
        .compositingGroup()
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row on the list by the door or the waiting chip: a click goes to its session as a click on its pet would, a
/// right-click brings up its menu, and it lights up under the pointer. It tells the pointer where it is, under a key of
/// its own; a still picture of it neither tells nor takes back. `gap` is the room between rows at zoom 1, half of it
/// above and half below each, so the rows touch and the pointer passes from one to the next without falling through to
/// the card.
struct OfficeListRow<Label: View>: View {
    let list: String
    let s: Session
    let gap: CGFloat
    let clip: CGRect?
    let label: Label
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z
    @Environment(\.still) private var still

    init(list: String, s: Session, gap: CGFloat, clip: CGRect? = nil, @ViewBuilder label: () -> Label) {
        self.list = list
        self.s = s
        self.gap = gap
        self.clip = clip
        self.label = label()
    }

    var body: some View {
        let key = OfficeList.row(list, s.id)
        Button {
            store.markSeen(s)
            if list == OfficeLayout.doorKey && Extensions.active?.drivesFigures == true {store.sceneListOpen=false}
            #if TESTING
            if let observe=OfficeList.activateForTest {observe(s);return}
            #endif
            jump(to: s)
        } label: {
            label.padding(.horizontal, 6 * z).padding(.vertical, gap / 2 * z)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 5 * z, style: .continuous).fill(Color.white.opacity(store.hovered == key ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onGeometryChange(for: CGRect.self) { geometry in
            let rect=geometry.frame(in:.global)
            return clip.map{rect.intersection($0)} ?? rect
        } action: { [store, still] in
            if !still { store.tracker.frames[key] = $0.isEmpty || $0.isNull ? nil:$0 }
        }
        .onDisappear { [store, still] in if !still { store.tracker.frames[key] = nil } }
    }
}

struct OfficeDoorCard: View {
    let ids: [String]
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    /// How many it lists before it says "……": the room holds thirty, so more than this behind the door is rare.
    static let shows = 12

    /// Each name, and whether that session is resting.
    static func lines(_ store: Store, ids: [String]) -> [(name: String, resting: Bool)] {
        let resting = Set(Buckets(store, now: Date()).resting.map(\.id))
        return ids.map { id in (store.sessions.first { $0.id == id }?.shownName ?? "", resting.contains(id)) }
    }

    var body: some View {
        let shown = Array(ids.prefix(Self.shows)), lines = Self.lines(store, ids: shown)
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.format("list.door", table: "Office", zh: "休息室里还有 %lld 个", ids.count)).font(rounded(13 * z)).foregroundStyle(paper).padding(.horizontal, 6 * z).padding(.bottom, 2 * z)
            ForEach(Array(shown.enumerated()), id: \.element) { i, id in
                if let s = store.sessions.first(where: { $0.id == id }) {
                    OfficeListRow(list: OfficeLayout.doorKey, s: s, gap: 4) {
                        let asleep = Text(lines[i].resting ? "  z" : "").foregroundStyle(quiet.opacity(0.55))
                        (Text(lines[i].name).foregroundStyle(quiet) + asleep).font(rounded(11.5 * z, .medium)).lineLimit(1)
                    }
                }
            }
            if ids.count > Self.shows {
                Text("……").font(rounded(11.5 * z, .medium)).foregroundStyle(quiet).padding(.horizontal, 6 * z).padding(.vertical, 2 * z)
            }
        }
        .padding(.top, 4 * z).padding(.bottom, 2 * z)
        .frame(maxWidth: 220 * z, alignment: .leading)
    }
}

/// What happened lately, on the notice board's card: the latest eight, newest first.
struct OfficeBoardCard: View {
    static var title: String { L10n.string("noticeBoard.title", table: "Office", zh: "刚才发生了什么") }
    static var empty: String { L10n.string("noticeBoard.empty", table: "Office", zh: "还没有动静。") }
    struct Line: Equatable {
        let time: String
        let dot: UInt32
        let name: String
        let text: String
        var partner: String? = nil
    }
    let lines: [Line]
    @Environment(\.zoom) private var z

    /// How wide a line may be at zoom 1, inside the card's edge.
    static let lineWidth: CGFloat = 320

    private static let clock: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = "HH:mm"
        return format
    }()
    private static let day: DateFormatter = {
        let format = DateFormatter()
        format.dateFormat = L10n.string("date.monthDay", table: "Office", zh: "M月d日")
        format.locale = Locale(identifier: L10n.language)  // Month names in the screen's language
        return format
    }()

    /// When it happened: the time today; the log outlives the day, so Yesterday before yesterday's, and the date before older ones.
    static func time(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return clock.string(from: date) }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        return (yesterday ? L10n.string("date.yesterday", table: "Office", zh: "昨天") : day.string(from: date)) + " " + clock.string(from: date)
    }

    /// The card's lines for the panel's store, with the sessions waiting for the user now.
    @MainActor static func lines(_ store: Store, now: Date = Date()) -> [Line] {
        lines(store.activity, waiting: Set(store.sessions.filter { $0.status == "waiting" }.map(\.id)), now: now)
    }

    /// The latest eight, newest first. A line saying a session waits for the user is coral only while it still does: once it is
    /// answered, the line is history, and its dot is quiet.
    static func lines(_ activity: OfficeActivity, waiting: Set<String>, now: Date = Date()) -> [Line] {
        activity.events.suffix(8).reversed().map { event in
            let answered = event.kind.dot == OfficeLook.call && !waiting.contains(event.id)
            let quietDot = answered || event.origin != nil
            return Line(
                time: time(event.at, now: now), dot: quietDot ? OfficeActivity.Event.Kind.talk.dot : event.kind.dot, name: event.name,
                text: event.text, partner: event.kind == .talk ? event.partner : nil)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5 * z) {
            Text(Self.title).font(rounded(13 * z)).foregroundStyle(paper)
            if lines.isEmpty { Text(Self.empty).font(.system(size: 11.5 * z)).foregroundStyle(quiet) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in OfficeBoardRow(line: line) }
        }
        .padding(.horizontal, 6 * z).padding(.vertical, 4 * z)
        .frame(maxWidth: (Self.lineWidth + 12) * z, alignment: .leading)
    }
}

/// One line of the board's card: its time, the dot of its kind, the name, and what happened.
struct OfficeBoardRow: View {
    let line: OfficeBoardCard.Line
    @Environment(\.zoom) private var z

    var body: some View {
        OfficeBoardRowLayout(spacing: 6 * z) {
            Text(line.time).font(rounded(11.5 * z, .medium)).monospacedDigit().foregroundStyle(quiet).fixedSize()
            Circle().fill(Color(hex: line.dot)).frame(width: 6 * z, height: 6 * z)
            Text(line.name).font(rounded(13 * z)).foregroundStyle(paper).lineLimit(1)
            happened.font(.system(size: 11.5 * z)).foregroundStyle(paper.opacity(0.85))
        }
    }

    // A long partner's name is cut inside its words, so the talk word stays.
    @ViewBuilder private var happened: some View {
        if let partner = line.partner {
            HStack(spacing: 0) {
                Text(L10n.string("event.talk.before", table: "Office", zh: "找 ")).fixedSize()
                Text(partner).lineLimit(1)
                Text(L10n.string("event.talk.after", table: "Office", zh: " 说话")).fixedSize()
            }
        } else {
            Text(line.text).lineLimit(1)
        }
    }
}

/// Lays out a line of the board's card: the time and the dot as they are; the name and what happened whole while the
/// line has room for both, and when it has not, each keeps at least half of what is left, the longer giving way.
struct OfficeBoardRowLayout: Layout {
    let spacing: CGFloat

    /// How wide the name and what happened are drawn, out of `room`.
    static func split(name: CGFloat, what: CGFloat, room: CGFloat) -> (name: CGFloat, what: CGFloat) {
        guard name + what > room + 0.5 else { return (name, what) }
        let what = min(what, max(room / 2, room - name))
        return (room - what, what)
    }

    private func widths(_ subviews: Subviews, within width: CGFloat?) -> [CGFloat] {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard ideal.count == 4, let width else { return ideal }
        let room = max(0, width - ideal[0] - ideal[1] - 3 * spacing)
        let (name, what) = Self.split(name: ideal[2], what: ideal[3], room: room)
        return [ideal[0], ideal[1], name, what]
    }

    /// Each part at the width it is given, as it then comes out: a name cut at a character is a little narrower than its
    /// share, and the next part follows it, not the share.
    private func sizes(_ subviews: Subviews, within width: CGFloat?) -> [(given: CGFloat, size: CGSize)] {
        zip(subviews, widths(subviews, within: width)).map { view, wide in
            (wide, view.sizeThatFits(ProposedViewSize(width: wide, height: nil)))
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = sizes(subviews, within: proposal.width)
        let wide = sizes.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(max(0, sizes.count - 1))
        return CGSize(width: wide, height: sizes.map(\.size.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        // Shared out of the width offered, as when it was measured; the parts may have come out a little narrower.
        for (view, part) in zip(subviews, sizes(subviews, within: proposal.width ?? bounds.width)) {
            let at = CGPoint(x: x, y: bounds.midY - part.size.height / 2)
            view.place(at: at, proposal: ProposedViewSize(width: part.given, height: part.size.height))
            x += part.size.width + spacing
        }
    }
}

/// Who waits for you beyond the queue's seven, the longest first: each one's name and what it asks, each row going to its
/// session.
struct OfficeWaitingCard: View {
    let ids: [String]
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.format("list.waiting", table: "Office", zh: "还有 %lld 个在等你", ids.count)).font(rounded(13 * z)).foregroundStyle(paper).padding(.horizontal, 6 * z).padding(.bottom, 2.5 * z)
            ForEach(Array(ids.prefix(6)), id: \.self) { id in
                if let s = store.sessions.first(where: { $0.id == id }) {
                    OfficeListRow(list: OfficeLayout.ChipKind.waiting.key, s: s, gap: 5) {
                        VStack(alignment: .leading, spacing: 1 * z) {
                            Text(s.shownName).font(rounded(11.5 * z, .medium)).foregroundStyle(paper).lineLimit(1)
                            Text(s.summary.isEmpty ? timeLabel(s, now: Date()) : s.shownSummary).font(.system(size: 11 * z))
                                .foregroundStyle(quiet).lineLimit(1)
                        }
                    }
                }
            }
            if ids.count > 6 {
                Text("……").font(rounded(11.5 * z, .medium)).foregroundStyle(quiet).padding(.horizontal, 6 * z).padding(.vertical, 2.5 * z)
            }
        }
        .padding(.top, 4 * z).padding(.bottom, 1.5 * z)
        .frame(maxWidth: 260 * z, alignment: .leading)
    }
}

/// The title bar's switch: the three names, the one showing filled with paper beside the others' quiet grey.
struct OfficeSwitch: View {
    let mode: OfficeMode
    let z: CGFloat
    let pick: (OfficeMode) -> Void

    static func segments(mode: OfficeMode) -> [(title: String, on: Bool)] { OfficeMode.offered.map { ($0.title, $0 == mode) } }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(Self.segments(mode: mode).enumerated()), id: \.offset) { i, segment in
                Button(segment.title) { if !segment.on { pick(OfficeMode.offered[i]) } }
                    .buttonStyle(.plain).font(rounded(11.5 * z, .medium)).foregroundStyle(segment.on ? Color.white : quiet)
                    .padding(.horizontal, 7 * z).padding(.vertical, 2 * z)
                    .background(RoundedRectangle(cornerRadius: 5 * z, style: .continuous).fill(segment.on ? brandBlue : .clear))  // Brand blue
            }
        }
        .padding(1.5 * z)
        .background(RoundedRectangle(cornerRadius: 6.5 * z, style: .continuous).stroke(quiet.opacity(0.5), lineWidth: 1))
    }
}

/// Whether pets walk in the office; switched in the menu bar, on until switched off.
func officeWalks() -> Bool { UserDefaults.standard.object(forKey: "officeWalks") as? Bool ?? true }

func setOfficeWalks(_ on: Bool) { UserDefaults.standard.set(on, forKey: "officeWalks") }

/// `Soulgent --snapshot out.png --office [--width <w>] [--height <h>] [--hover <name>] [--theme <name>] [--floor <hex>]
/// [--focus <name> [--focus-phase <0…1>]]`: the office as it is now, as the panel shows it in a view that size (1194 x 764
/// unless given); with --hover, as if the pointer were on that session's pet, or on the door it waits behind, or with
/// `--hover notice board` on the notice board and `--hover Waiting for you` on the waiting chip; in that theme and on that floor, for this
/// picture only; with --focus, the light on that session as if the user were typing in it in Orca, its ball and spots where they
/// start, or that share of the way round their loops. `officeDemo`'s flags make up a room.
@MainActor func officeSnapshot(to path: String, size: CGSize = CGSize(width: 1194, height: 764), hover: String? = nil) {
    OfficeTheme.shown = OfficeTheme.chosen(arguments: CommandLine.arguments)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    let store = Store()
    store.readOnly = true
    store.loadOnce()
    store.scanLinksNow()  // who talks with whom: the chat marks, the card's links, the lines (a still is a first look: no visit)
    officeDemo(store, arguments: CommandLine.arguments)
    restartDemo(store, arguments: CommandLine.arguments)
    officeFocus(store, arguments: CommandLine.arguments)
    let arguments = CommandLine.arguments
    let phase = arguments.firstIndex(of: "--focus-phase").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil }
    OfficeView.stillPhase = phase.flatMap { $0.isFinite ? $0 - $0.rounded(.down) : nil } ?? 0  // round the loops: 1.25 is 0.25
    OfficeTheme.shown = OfficeTheme.chosen(arguments: CommandLine.arguments)
    // The roads picture is of the Seaview scene, whatever the setting.
    if arguments.contains("--zone-roads") { OfficeTheme.shown = OfficeTheme.zone }
    if ZoneUI.active {
        zoneSnapshot(store, to: path, size: size, hover: hover)
        return
    }
    let fit = OfficeFit(size)
    if let hover {
        let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
        if let key = officePointed(named: hover, store: store, layout: layout) {
            store.hovered = key
        } else {
            FileHandle.standardError.write(Data("no open session named \(hover); the picture shows nobody pointed at\n".utf8))
        }
    }
    guard let composed = officeStill(store, size: size),
        let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:])
    else { fatalError("could not draw the office") }
    try! png.write(to: URL(fileURLWithPath: path))
}

/// While its session is being restarted, a figure and its card wear a small spinner instead of moving: a soft
/// white disc with a ring of eight pastel dots, the first full and each after it fainter and smaller, the ring turning
/// on Core Animation. Still under Reduce Motion and in pictures. No words: the spinner says it.
enum RestartSpinner {
    static let name = "restart-spinner"
    /// Its side at full size, in points; in the room it grows as the plates' words do when the room is drawn smaller.
    static let side: CGFloat = 16
    /// Seconds a round.
    static let round = 1.2
    /// Pixels a point in its pictures: sharp on a Retina screen at the largest the room draws it.
    static let pixels: CGFloat = 3
    private static let dots: [UInt32] = [0xFF8FB1, 0xFFAD7A, 0xFFD166, 0x8FDDB0, 0x7FCBEA, 0x93A8FF, 0xBB9BFF, 0xF29AD8]
    @MainActor private static var drawn: [CGFloat: (disc: CGImage, ring: CGImage)] = [:]

    /// The disc and the ring for this side, drawn once.
    @MainActor static func pictures(_ side: CGFloat) -> (disc: CGImage, ring: CGImage)? {
        if let known = drawn[side] { return known }
        guard let disc = paint(side, ring: false), let ring = paint(side, ring: true) else { return nil }
        if drawn.count > 16 { drawn = [:] }  // a size per zoom and window: a handful at most
        drawn[side] = (disc, ring)
        return (disc, ring)
    }

    private static func paint(_ side: CGFloat, ring: Bool) -> CGImage? {
        let w = Int((side * pixels).rounded(.up))
        guard w > 0, let c = CGContext(
            data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let unit = CGFloat(w) / side, middle = CGFloat(w) / 2
        if !ring {
            let edge = 0.6 * unit
            c.setFillColor(OfficeCanvas.rgb(0xFFFDFB, 0.94))
            c.fillEllipse(in: CGRect(x: edge, y: edge, width: CGFloat(w) - 2 * edge, height: CGFloat(w) - 2 * edge))
            c.setStrokeColor(OfficeCanvas.rgb(0xB9A7D6, 0.9))
            c.setLineWidth(edge)
            c.strokeEllipse(in: CGRect(x: edge, y: edge, width: CGFloat(w) - 2 * edge, height: CGFloat(w) - 2 * edge))
            return c.makeImage()
        }
        let reach = side * 0.29 * unit
        for i in 0..<dots.count {
            let angle = CGFloat(i) * 2 * .pi / CGFloat(dots.count)
            let r = side * (0.1 - CGFloat(i) * 0.006) * unit
            let x = middle + cos(angle) * reach, y = middle + sin(angle) * reach
            c.setFillColor(OfficeCanvas.rgb(dots[i], 1 - CGFloat(i) * 0.09))
            c.fillEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return c.makeImage()
    }

    /// The spinner as a layer `side` points across: the disc, and over it the ring that turns.
    @MainActor static func layer(side: CGFloat) -> CALayer {
        let holder = CALayer()
        holder.name = name
        holder.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        let disc = CALayer(), ring = CALayer()
        disc.name = "disc"
        ring.name = "ring"
        let shown = pictures(side)
        disc.contents = shown?.disc
        ring.contents = shown?.ring
        for part in [disc, ring] {
            part.frame = holder.bounds
            holder.addSublayer(part)
        }
        return holder
    }

    /// Turns its ring, or holds it still.
    @MainActor static func spin(_ spinner: CALayer, _ on: Bool) {
        guard let ring = spinner.sublayers?.first(where: { $0.name == "ring" }) else { return }
        if !on {
            ring.removeAnimation(forKey: "spin")
            return
        }
        guard ring.animation(forKey: "spin") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = round
        turn.repeatCount = .infinity
        ring.add(turn, forKey: "spin")
    }

    /// The whole spinner still, for pictures.
    @MainActor static func picture(side: CGFloat) -> CGImage? {
        guard let shown = pictures(side) else { return nil }
        let w = shown.disc.width
        guard let c = CGContext(
            data: nil, width: w, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let all = CGRect(x: 0, y: 0, width: w, height: w)
        c.draw(shown.disc, in: all)
        c.draw(shown.ring, in: all)
        return c.makeImage()
    }

    /// Where it goes round a figure whose sprite is `head` (round its feet, y down): over the head; where that would
    /// cover words (the queue head's bubble, a card, a plate), beside the top of the head, right or left.
    static func spot(head: CGRect, side: CGFloat, avoid: [CGRect]) -> CGRect {
        let over = CGRect(x: head.midX - side / 2, y: head.minY - side * 1.25, width: side, height: side)
        let right = CGRect(x: head.maxX - side * 0.25, y: head.minY + side * 0.15, width: side, height: side)
        let left = CGRect(x: head.minX - side * 0.75, y: head.minY + side * 0.15, width: side, height: side)
        for place in [over, right, left] where !avoid.contains(where: { $0.intersects(place) }) { return place }
        return right
    }
}

/// For pictures, in memory and on a read-only store only: `--demo-waiting N`, `--demo-news N` and `--demo-work N` take
/// the first N sessions in the store's order, the next N and the next N, as waiting (each asking something), with news,
/// and at work. The rest are looked at, seen or resting by their own time. Names and pets stay; nothing is saved.
@MainActor func officeDemo(_ store: Store, arguments: [String]) {
    guard store.readOnly else { return }
    func count(_ flag: String) -> Int? { arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } }
    let waiting = count("--demo-waiting"), news = count("--demo-news"), work = count("--demo-work")
    guard waiting != nil || news != nil || work != nil else { return }
    let w = waiting ?? 0, n = news ?? 0, b = work ?? 0, now = Date()
    // As codes (not Chinese text), so the cards say them in the screen's language
    let asks: [SummaryLine] = [.approveRun(command: "npm test"), .ask(question: "端口用 8080 还是 9000？", count: 1), .approveRun(command: "git push origin main"), .approveRun(command: "docker compose up -d"),
                .ask(question: "先改哪一个？", count: 1), .approveRun(command: "rm -rf build"), .approveRun(command: "pip install -r requirements.txt"), .ask(question: "要不要重启服务？", count: 1),
                .approveRun(command: "ssh demo-host nvidia-smi")]
    store.sessions = store.sessions.enumerated().map { i, s in
        func with(_ status: String, since: Date, summary: String, waitingFor: String = "", tool: String = "", line: SummaryLine? = nil) -> Session {
            Session(id: s.id, pid: s.pid, project: s.project, name: s.name, status: status, since: since, summary: line?.rendered ?? summary,
                    waitingFor: waitingFor, registryName: s.registryName, cwd: s.cwd, kind: s.kind, tool: tool, summaryLine: line)
        }
        if i < w {  // the first waits longest
            return with("waiting", since: now - Double(w - i) * 240 - 30, summary: "", waitingFor: "permission prompt", line: asks[i % asks.count])
        }
        if i < w + n {
            store.seen[s.id] = 0
            return with("idle", since: now - Double(i - w + 1) * 300, summary: s.summary)
        }
        if i < w + n + b {
            // At work on something: each its own tool, so a picture shows the badges (Seaview).
            let tools = ["Bash", "Edit", "Read", "WebFetch", "Agent", ""]
            return with("busy", since: now - Double(i - w - n + 1) * 200, summary: s.summary, tool: tools[(i - w - n) % tools.count])
        }
        store.seen[s.id] = now.timeIntervalSince1970 + 1
        store.pinned.remove(s.id)
        return s.status == "idle" ? s : with("idle", since: s.since, summary: s.summary)
    }
}

/// For pictures, in memory and on a read-only store only: `--demo-restarting N` shows the first N sessions in the store's
/// order (after the other `--demo-*` flags have set them) as being restarted. Nothing is saved.
@MainActor func restartDemo(_ store: Store, arguments: [String]) {
    guard store.readOnly, let i = arguments.firstIndex(of: "--demo-restarting"), i + 1 < arguments.count,
        let n = Int(arguments[i + 1]), n > 0
    else { return }
    var shown: [Session] = []
    for (k, s) in store.sessions.enumerated() {
        var t = s
        t.restarting = k < n
        shown.append(t)
    }
    store.sessions = shown
}

/// The office for this store as the panel shows it in a view this size: its own view, drawn off screen and held
/// still, with the card for whatever `store.hovered` is over it.
@MainActor func officeStill(_ store: Store, size: CGSize) -> CGImage? {
    let view = OfficeView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    guard let room = view.image() else { return nil }
    let zoom = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1
    let scene = ZStack(alignment: .topLeading) {
        Image(decorative: room, scale: 2)
        OfficeHover(fit: OfficeFit(size), origin: .zero, window: size)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .environmentObject(store).environment(\.zoom, CGFloat(zoom)).environment(\.still, true).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    return renderer.cgImage
}
