import AppKit

// Pets face the way they go in every scene (the facing table, `pet-facing.json`), and the sea room's walks keep
// to a road network. `tools/dev/run-tests.sh --walk-only` runs these alone.

@MainActor func walkTests() {
    walkFacingTests()
    walkRoadTests()
    walkFacingExtraTests()
}

/// The office's straight up-and-down legs keep their facing too (no row 7: many sheets' row 7 is
/// no run), and a visit's stay by its host is as long as the base stay however long the way there is by the roads.
@MainActor func walkFacingExtraTests() {
    func legs(_ route: [CGPoint]) -> [(from: CGPoint, to: CGPoint, length: CGFloat)] {
        zip(route, route.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
    }
    let office = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 80), CGPoint(x: 200, y: 80), CGPoint(x: 200, y: 160), CGPoint(x: 100, y: 160), CGPoint(x: 100, y: 300)]
    let rows = OfficeView.rows(for: legs(office))
    check("walk (office): straight up or down keeps the facing it had (the first leg: the next one's), never row 7",
        rows == [OfficePets.right, OfficePets.right, OfficePets.right, OfficePets.left, OfficePets.left]
            && OfficeView.rows(for: legs([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 100)])) == [OfficePets.right] && !rows.contains(7))

    var talk = OfficeRounds()
    let now = Date()
    talk.talk("A", "B", opened: now - 5, last: now - 5)
    var looked = ZoneVisits()
    looked.looked = true
    let homes = ["A": CGPoint(x: 100, y: 100), "B": CGPoint(x: 600, y: 300)]
    let byRoad = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds, previous: looked, now: now,
                                 pace: 70, length: { _, _ in 2000 })
    let until = byRoad.visits["A"]?.until.timeIntervalSince(now) ?? 0
    check("walk (sea room): a visit's time is the walk there by its real way (its length at the pace) and then the same base stay",
        abs(until - (2000.0 / 70 + ZoneVisits.stay)) < 0.01)
    if let scene = ZoneArt.scene, let a = scene.desk(ZoneDesk(zone: "Ops", index: 3))?.seat, let b = scene.desk(ZoneDesk(zone: "AI", index: 8))?.seat {
        let way = ZoneView.walkRoute(from: a, to: scene.visitSpot(b), scene: scene)
        var length: CGFloat = 0
        for (p, q) in zip(way, way.dropFirst()) { length += hypot(q.x - p.x, q.y - p.y) }
        check("walk (sea room): the room times a visit by the length of the way it walks (Ops 3 to beside AI 8, by the roads), not the straight line",
            abs(ZoneView.visitLength(from: a, to: b, scene: scene) - length) < 0.5 && length > hypot(b.x - a.x, b.y - a.y) * 1.3)
    }
}

/// Pixel for pixel the same picture (a mirrored frame is made afresh in a check).
@MainActor func walkSamePixels(_ a: CGImage?, _ b: CGImage?) -> Bool {
    guard let a, let b, a.width == b.width, a.height == b.height,
        let da = OfficePets.mirrored(OfficePets.mirrored(a) ?? a)?.dataProvider?.data, let db = OfficePets.mirrored(OfficePets.mirrored(b) ?? b)?.dataProvider?.data
    else { return false }
    return da == db
}

/// The pet the live walks below run: a demo pet (it need not be installed; where its frames are not cut the walks say so and
/// are skipped). The facing table is given it for the length of a run (`walkRunnerTable`): row 1 runs left in its sheet, as
/// the table's pets' rows do, so row 1 mirrored is right and row 1 as cut is left.
let walkRunnerPet = "blue-boba-axolotl"
@MainActor func walkRunnerTable<T>(_ body: () -> T) -> T {
    let kept = OfficePets.facingTable
    OfficePets.facingTable[walkRunnerPet] = ((row: 1, mirrored: true), (row: 1, mirrored: false))
    defer { OfficePets.facingTable = kept }
    return body()
}

@MainActor func walkFacingTests() {
    walkRunnerTable { walkFacingTestsRunning() }
}

@MainActor func walkFacingTestsRunning() {
    // ── The table ──
    let sample = Data(#"{"_note": "note", "blue-boba-axolotl": {"right": "1m", "left": "1"}, "cloudy": {"right": "1", "left": "1m"}, "odd": {"right": "x", "left": "2m"}}"#.utf8)
    let parsed = OfficePets.parseFacing(sample)
    check("walk: the facing table reads \"1m\" as row 1 mirrored and \"1\" as row 1, skips the _ notes, and a value it cannot read keeps the convention",
        parsed.count == 3 && parsed["_note"] == nil && parsed["blue-boba-axolotl"].map { $0.right == (1, true) && $0.left == (1, false) } == true
            && parsed["cloudy"].map { $0.right == (1, false) && $0.left == (1, true) } == true
            && parsed["odd"].map { $0.right == (1, false) && $0.left == (2, true) } == true)
    // The shipped pet-facing.json lists no pet (a private table, when there is one, is laid over it: pet-facing.private.json).
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let shipped = FileManager.default.contents(atPath: sources.appendingPathComponent("pet-facing.json").path)
    check("walk: pet-facing.json is there beside the sources, parses and lists no pet", shipped.map { OfficePets.parseFacing($0).isEmpty } == true)
    // The two tables: the private one's pets replace the public one's of the same name, and add to them. Here from a folder
    // of their own, the way the app's Resources and the checks' build/ hold them.
    let publicSample = Data(#"{"_note": "note", "cloudy": {"right": "1m", "left": "1"}, "octopus": {"right": "2m", "left": "2"}}"#.utf8)
    let privateSample = Data(#"{"cloudy": {"right": "0", "left": "0m"}, "whaley": {"right": "1", "left": "1m"}}"#.utf8)
    let merged = OfficePets.mergeFacing(OfficePets.parseFacing(publicSample), over: OfficePets.parseFacing(privateSample))
    check("walk: a private table is laid over the public one: its pets replace the same pets and add the others, the rest stay",
        merged.count == 3 && merged["cloudy"].map { $0.right == (0, false) && $0.left == (0, true) } == true
            && merged["octopus"].map { $0.right == (2, true) && $0.left == (2, false) } == true
            && merged["whaley"].map { $0.right == (1, false) && $0.left == (1, true) } == true)
    let scratch = NSTemporaryDirectory() + "walk-facing-\(getpid())"
    let both = scratch + "/both", onlyPublic = scratch + "/public", empty = scratch + "/empty"
    for dir in [both, onlyPublic, empty] { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    try? publicSample.write(to: URL(fileURLWithPath: both + "/pet-facing.json"))
    try? privateSample.write(to: URL(fileURLWithPath: both + "/pet-facing.private.json"))
    try? publicSample.write(to: URL(fileURLWithPath: onlyPublic + "/pet-facing.json"))
    let fromBoth = OfficePets.loadFacing(directories: [empty, both]), fromPublic = OfficePets.loadFacing(directories: [onlyPublic])
    check("walk: loadFacing reads both files from the first folder that has them and merges (private first); with no private file the public table as it is; with neither, none",
        fromBoth.count == 3 && fromBoth["cloudy"].map { $0.right == (0, false) } == true && fromBoth["whaley"] != nil
            && fromPublic.count == 2 && fromPublic["cloudy"].map { $0.right == (1, true) } == true && fromPublic["whaley"] == nil
            && OfficePets.loadFacing(directories: [empty]).isEmpty)
    let table = OfficePets.facingTable
    check("walk: a pet in the table runs as it says (given to the demo pet here: right in row 1 mirrored, left in row 1)",
        table[walkRunnerPet] != nil && OfficePets.runRow(walkRunnerPet, facing: OfficePets.right) == (1, true)
            && OfficePets.runRow(walkRunnerPet, facing: OfficePets.left) == (1, false))
    check("walk: a pet not in the table runs right in row 1 and left in row 2 as the sheets mean to; row 7 (on the spot) is row 7",
        OfficePets.runRow("test-pet", facing: OfficePets.right) == (1, false) && OfficePets.runRow("test-pet", facing: OfficePets.left) == (2, false)
            && OfficePets.runRow(walkRunnerPet, facing: 7) == (7, false))

    // ── The helper ──
    OfficePets.shared.synchronous = true
    defer { OfficePets.shared.synchronous = false }
    let runner = walkRunnerPet
    if let base = OfficePets.shared.frame(runner, row: 1, column: 3), let right = OfficePets.shared.runFrame(runner, facing: OfficePets.right, column: 3) {
        let again = OfficePets.shared.runFrame(runner, facing: OfficePets.right, column: 3)
        let left = OfficePets.shared.runFrame(runner, facing: OfficePets.left, column: 3)
        let w = base.image.width
        check("walk: the runner's frame running right is its row 1 mirrored (its drawn box mirrored too), made once and kept: the same image asked again",
            right.image !== base.image && walkSamePixels(right.image, OfficePets.mirrored(base.image)) && again?.image === right.image
                && right.left == w - 1 - base.right && right.right == w - 1 - base.left && right.top == base.top && right.bottom == base.bottom)
        check("walk: the runner's frame running left is its row 1 as cut", left?.image === base.image)
        let other = OfficePets.shared.runFrame("test-pet", facing: OfficePets.left, column: 2)?.image
        check("walk: a pet not listed gets its own row's frame from the helper, not a copy", other == nil || other === OfficePets.shared.frame("test-pet", row: 2, column: 2)?.image)
    } else {
        skipped("the runner pet's frames are not cut", "walk: the runner's frame running right is its row 1 mirrored")
    }

    // ── Facing per leg ──
    let nearly = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 90, y: 100), CGPoint(x: -50, y: 100)]
    let firstUp = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 100), CGPoint(x: -100, y: 100)]
    check("walk (sea room): a leg nearly up or down (across by under a quarter of its length) keeps the facing before it; the first such takes the next leg's",
        ZoneWalk.rows(nearly) == [1, 1, 2] && ZoneWalk.rows(firstUp) == [2, 2] && ZoneWalk.rows([CGPoint(x: 0, y: 0), CGPoint(x: 40, y: 100)]) == [1])
    func legs(_ route: [CGPoint]) -> [(from: CGPoint, to: CGPoint, length: CGFloat)] {
        zip(route, route.dropFirst()).map { ($0, $1, hypot($1.x - $0.x, $1.y - $0.y)) }
    }
    let office = [CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 80), CGPoint(x: 200, y: 80), CGPoint(x: 190, y: 160), CGPoint(x: 100, y: 160)]
    check("walk (office): up or down (straight, or nearly) keeps the facing it had; the first leg takes the next one's",
        OfficeView.rows(for: legs(office)) == [OfficePets.right, OfficePets.right, OfficePets.right, OfficePets.left]
            && OfficeView.rows(for: legs([CGPoint(x: 0, y: 0), CGPoint(x: -10, y: 100), CGPoint(x: 100, y: 100)])) == [OfficePets.right, OfficePets.right])

    guard OfficePets.shared.frame(runner, row: 1, column: 0) != nil else {
        return skipped("the runner pet's frames are not cut", "walk: a runner walk to the right shows mirrored frames in every scene")
    }
    let mirroredRight = Set((0..<8).compactMap { OfficePets.shared.runFrame(runner, facing: OfficePets.right, column: $0)?.image }.map(ObjectIdentifier.init))
    let rawRow1 = Set((0..<8).compactMap { OfficePets.shared.frame(runner, row: 1, column: $0)?.image }.map(ObjectIdentifier.init))

    // ── Sea room: its walk's running frames ──
    let rightward = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 10), CGPoint(x: 300, y: 60), CGPoint(x: 500, y: 70)]
    let steps = ZoneView.runningSteps(runner, route: rightward, seconds: 2)?.values?.map { ObjectIdentifier($0 as AnyObject) } ?? []
    check("walk (sea room): a runner walking right runs in its row 1 mirrored, never in row 1 as cut (which runs left)",
        !steps.isEmpty && steps.allSatisfy(mirroredRight.contains) && !steps.contains(where: rawRow1.contains))

    // Live, in a window: off to check-in on the right, the sprite's frames on its rightward legs are the mirrored ones.
    if let scene = ZoneArt.scene, let checkIn = scene.visitor {
        let now = Date()
        var made = Session(id: "zid-Home-sailor", pid: 1, project: "proj-sailor", name: "Home-sailor", status: "busy", since: now - 40, summary: "")
        made.cwd = "/tmp/walk/Home-sailor"
        let store = Store()
        store.readOnly = true
        store.sessions = [made]
        let dealt = officeDealCutPets(store, giving: ["zid-Home-sailor": runner])
        let size = CGSize(width: 1180, height: 790)
        let live = ZoneView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = live
        window.orderFrontRegardless()
        live.update(store)
        live.probeWalk("zid-Home-sailor", to: checkIn)
        let route = live.route(of: "zid-Home-sailor"), rows = ZoneWalk.rows(route)
        let shown = (live.spriteAnimation(of: "zid-Home-sailor", "steps") as? CAKeyframeAnimation)?.values?.map { ObjectIdentifier($0 as AnyObject) } ?? []
        let anyRight = rows.contains(ZoneWalk.right)
        print("      walk zone: pet \(live.pet(of: "zid-Home-sailor") ?? "-"), \(route.count - 1) legs, rows \(rows)")
        if dealt && live.pet(of: "zid-Home-sailor") == runner {
            check("walk (sea room, live): runner walking to check-in shows mirrored row-1 frames on its rightward legs and never row 1 as cut there",
                anyRight && shown.contains(where: mirroredRight.contains) && shown.allSatisfy { mirroredRight.contains($0) || rawRow1.contains($0) }
                    && (rows.contains(ZoneWalk.left) || !shown.contains(where: rawRow1.contains)))
        } else {
            skipped("no runner dealt", "walk (sea room, live): runner walking right shows mirrored frames")
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    // ── the office: its walk's running frames, live ──
    walkOfficeRunner(runner)

}

/// The office: a runner at a desk starts waiting and walks to the queue; on each leg its frames are the ones the facing
/// table gives for that leg's way (row 1 mirrored to the right).
@MainActor func walkOfficeRunner(_ runner: String) {
    let what = "walk (office, live): a runner walk shows, leg by leg, the facing table's frames: row 1 mirrored going right"
    let wasShown = OfficeTheme.shown
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = wasShown }
    let store = Store()
    store.readOnly = true
    store.sessions = officeSessions([("q", "waiting", 2, 900), ("s", "idle", 8, 600)])
    for s in store.sessions where !s.id.hasPrefix("q") { store.seen[s.id] = Date().timeIntervalSince1970 }
    var verdicts: [String: Bool] = [:]
    var sawRight = false, sawUpright = false
    for walker in ["s0", "s3", "s5", "s7"] {
        guard officeDealCutPets(store, giving: [walker: runner]) else { continue }
        let view = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1194, height: 764), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        view.update(store)
        let was = store.sessions
        store.sessions = store.sessions.map { $0.id == walker ? officeSession(walker, "waiting", finished: 1) : $0 }
        view.update(store)
        CATransaction.flush()
        let deadline = Date().addingTimeInterval(2)
        func sprite() -> CALayer? { officePart(view, walker, "sprite") }
        while sprite()?.animation(forKey: "steps") == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
        let move = officeFigure(view, walker)?.animation(forKey: "walk") as? CAKeyframeAnimation
        let route = move?.values?.compactMap { ($0 as? NSValue)?.pointValue } ?? []
        let steps = sprite()?.animation(forKey: "steps") as? CAKeyframeAnimation
        let layout = OfficePainter.layout(store, now: Date())
        if let steps, let values = steps.values, let times = steps.keyTimes?.map(\.doubleValue), route.count > 1,
            let place = layout.pets.first(where: { $0.id == walker }), let session = store.sessions.first(where: { $0.id == walker })
        {
            let legs = zip(route, route.dropFirst()).map { (from: $0, to: $1, length: hypot($1.x - $0.x, $1.y - $0.y)) }
            let rows = OfficeView.rows(for: legs), total = legs.reduce(0) { $0 + $1.length }
            let scale = OfficePainter.figure(store, session, place, now: Date()).scale
            var ok = true, start: CGFloat = 0
            for (leg, row) in zip(legs, rows) where leg.length > 0 {
                let a = Double(start / total), b = Double((start + leg.length) / total)
                start += leg.length
                // no row 7 (on the spot) on any leg.
                let seven = (0..<8).compactMap { OfficePets.shared.scaled(runner, row: 7, column: $0, scale: scale) }
                let during = zip(values, times).filter { $0.1 > a + 0.001 && $0.1 < b - 0.001 }.map(\.0)
                if during.contains(where: { value in seven.contains { officeSameFrame(value, $0) } }) { ok = false }
                if leg.to.x == leg.from.x { sawUpright = true }
                guard row == OfficePets.right || row == OfficePets.left else { ok = false; continue }
                if row == OfficePets.right { sawRight = true }
                let want = officeRunScaled(runner, facing: row, scale: scale)
                let shown = zip(values, times).filter { $0.1 > a + 0.001 && $0.1 < b - 0.001 }.map(\.0)
                if !shown.allSatisfy({ value in want.contains { officeSameFrame(value, $0) } }) { ok = false }
                // Going right it is never row 1 as cut (the runner's row 1 runs left).
                if row == OfficePets.right {
                    let raw = (0..<8).compactMap { OfficePets.shared.scaled(runner, row: 1, column: $0, scale: scale) }
                    if shown.contains(where: { value in raw.contains { officeSameFrame(value, $0) } }) { ok = false }
                }
            }
            print("      walk office: \(walker) rows \(rows), ok \(ok)")
            verdicts[walker] = ok
        }
        store.sessions = was
        window.orderOut(nil)
        window.contentView = nil
        if sawRight { break }
    }
    guard !verdicts.isEmpty else { return skipped("no runner walk in the office", what) }
    check(what + "; straight up or down it keeps its facing (no row 7)", sawRight && sawUpright && verdicts.values.allSatisfy { $0 })
}

@MainActor func walkRoadTests() {
    guard let scene = ZoneArt.scene, let map = scene.walkMap, let roads = map.roads else {
        return check("walk roads: the art gives a road network", false)
    }
    check("walk roads: the network has the aisles, the outer aisles, front and back walkways, the sofa walkway, the line, the boss's link, check-in and the rest corner",
        Set(roads.roads.map(\.name)).isSuperset(of: ["aisle", "aisle-left", "aisle-right", "front", "back", "sofa", "queue", "boss", "aisle-down", "check-in", "rest"]))
    // No road crosses an obstacle (with the clearance a walker keeps).
    let crossing = roads.edges.filter { e in map.boxes.contains { $0.blocks(roads.nodes[e.a], roads.nodes[e.b], grow: ZoneWalkMap.clearance) } }
    for e in crossing.prefix(5) { print("      walk roads: \(e.road) \(roads.nodes[e.a]) → \(roads.nodes[e.b]) crosses \(map.boxes.filter { $0.blocks(roads.nodes[e.a], roads.nodes[e.b], grow: ZoneWalkMap.clearance) }.map(\.name))") }
    check("walk roads: no road segment crosses an island, the boss's desk, a sofa, the railing, the pantry, the rest table or a plant", crossing.isEmpty && !roads.edges.isEmpty)
    // One graph: every node reaches every other.
    var seen: Set<Int> = [0], todo = [0]
    while let i = todo.popLast() { for (j, _) in roads.links[i] where seen.insert(j).inserted { todo.append(j) } }
    check("walk roads: the roads are one network (every junction reaches every other)", seen.count == roads.nodes.count)

    // Every destination joins a road by a short clear spur.
    func seat(_ z: String, _ i: Int) -> CGPoint? { scene.desk(ZoneDesk(zone: z, index: i))?.seat }
    var spots: [(String, CGPoint)] = []
    for d in scene.desks { spots.append(("desk \(d.zone) \(d.index)", d.seat)); spots.append(("visit at \(d.zone) \(d.index)", scene.visitSpot(d.seat))) }
    for s in scene.sofas {
        for (i, p) in s.seats.enumerated() { spots.append(("sofa \(s.zone) \(i)", p)) }
        for i in 0..<3 { if let p = scene.sofaOverflow(s.zone, slot: i) { spots.append(("by sofa \(s.zone) \(i)", p)) } }
    }
    for i in 0..<scene.lineCapacity { if let p = scene.lineSpot(i) { spots.append(("line \(i)", p)) } }
    for i in 0..<4 { if let p = scene.lobby(slot: i) { spots.append(("lobby \(i)", p)) } }
    for (i, p) in scene.restSeats.enumerated() { spots.append(("rest \(i)", p)) }
    if let p = scene.visitor { spots.append(("check-in", p)) }
    var lacking: [String] = []
    for (label, p) in spots where roads.spur(map.outside(map.world(p)), clear: map.clear) == nil { lacking.append(label) }
    let entrance = CGPoint(x: 9.41, y: -7.1)
    if roads.spur(entrance, clear: map.clear) == nil { lacking.append("entrance") }
    print("      walk roads: \(spots.count + 1) destinations, without a spur: \(lacking)")
    check("walk roads: every destination (desks, visit spots, sofa seats and standing spots, the line, the lobby, rest seats, check-in, the entrance) has a clear spur ≤ 3.2 m",
        lacking.isEmpty && spots.count > 120)

    // Routes between all pairs of a sample: they exist, keep to the roads between their spurs, and (as walked) cross nothing
    // but their own ends' obstacles.
    let sample: [CGPoint] = [seat("Web", 1), seat("Web", 9), seat("Ops", 3), seat("Ops", 12), seat("AI", 4), seat("AI", 8), seat("Home", 2), seat("Home", 12),
                             scene.sofas.first?.seats.first, scene.sofas.last?.seats.last, scene.sofaOverflow("AI", slot: 1), scene.lineSpot(0), scene.lineSpot(5),
                             scene.lobby(slot: 1), scene.restSeats.first, scene.restSeats.last, scene.visitor, seat("Ops", 7).map { scene.visitSpot($0) }].compactMap { $0 }
    var missing = 0, offRoad = 0, crossed = 0, worst: (CGFloat, String) = (0, "")
    let named = map.boxes
    for (i, a) in sample.enumerated() {
        for (j, b) in sample.enumerated() where i != j {
            guard let road = map.roadRoute(from: a, to: b) else { missing += 1; continue }
            if road.count > 5 {
                // Between the spurs' feet (indices 2 … count - 3) each piece runs along one edge.
                for k in 2..<(road.count - 3) {
                    let p = road[k], q = road[k + 1]
                    let onOne = roads.edges.contains { e in
                        let u = roads.nodes[e.a], v = roads.nodes[e.b]
                        func near(_ x: CGPoint) -> Bool { let f = ZoneRoads.project(x, u, v).1; return hypot(f.x - x.x, f.y - x.y) < 1e-3 }
                        return near(p) && near(q)
                    }
                    if !onOne { offRoad += 1 }
                }
            }
            let walked = map.route(from: a, to: b).map(map.world)
            let ends = Set(named.indices.filter { named[$0].contains(map.world(a), grow: ZoneWalkMap.clearance) || named[$0].contains(map.world(b), grow: ZoneWalkMap.clearance) })
            for (k, (p, q)) in zip(walked, walked.dropFirst()).enumerated() {
                for (n, box) in named.enumerated() where box.blocks(p, q, grow: ZoneWalkMap.clearance * 0.5) {
                    if !(ends.contains(n) && (k == 0 || k == walked.count - 2)) { crossed += 1; print("      walk roads: pair \(i)→\(j) leg \(k) crosses \(box.name)") }
                }
            }
            var length: CGFloat = 0
            for (p, q) in zip(road, road.dropFirst()) { length += hypot(q.x - p.x, q.y - p.y) }
            let wa = map.world(a), wb = map.world(b), straight = hypot(wb.x - wa.x, wb.y - wa.y)
            if straight > 4, length / straight > worst.0 { worst = (length / straight, "\(i)→\(j)") }
        }
    }
    print(String(format: "      walk roads: %d pairs; longest against the straight line (over 4 m apart): %.2f× (%@)", sample.count * (sample.count - 1), worst.0, worst.1))
    check("walk roads: a route exists between every pair of 18 sample spots, keeps to the roads between its spurs, and crosses nothing but its own ends' obstacles",
        missing == 0 && offRoad == 0 && crossed == 0)
    // The typical walks the picture shows: no more than 2.5 × the straight line.
    var ratios: [String] = [], tooLong = false
    for s in ZoneRoadsPicture.samples(scene) {
        guard let road = map.roadRoute(from: s.from, to: s.to) else { tooLong = true; continue }
        var length: CGFloat = 0
        for (p, q) in zip(road, road.dropFirst()) { length += hypot(q.x - p.x, q.y - p.y) }
        let a = map.world(s.from), b = map.world(s.to), r = length / max(0.01, hypot(b.x - a.x, b.y - a.y))
        ratios.append(String(format: "%.2f", r))
        if r > 2.5 { tooLong = true }
    }
    print("      walk roads: the picture's walks, against the straight line: \(ratios)")
    check("walk roads: the typical walks (desk → line, desk → sofa, a visit across the islands, check-in → desk, rest → desk, sofa → desk) are at most 2.5 × the straight line",
        !tooLong && ratios.count >= 5)
    // A sidestep (the next sofa seat) goes straight across.
    if let sofa = scene.sofas.first, sofa.seats.count >= 2 {
        let step = map.route(from: sofa.seats[0], to: sofa.seats[1])
        check("walk roads: a sidestep to the next sofa seat goes straight there, not out to the walkway and back", step.count <= 4)
    }
    let soft = ZoneRoads.soften([CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 5)], clear: { _, _ in true })
    check("walk roads: a corner is cut by a short chamfer (0.3 m back along each leg), the ends kept",
        soft.count == 4 && soft[1] == CGPoint(x: 4.7, y: 0) && abs(soft[2].y - 0.3) < 1e-9 && soft.first == CGPoint(x: 0, y: 0) && soft.last == CGPoint(x: 5, y: 5))
}

/// `--walk-facing-stills <dir>`: pictures for review. `walk-runner-frames.png`: the runner's row 1 as cut, its running-right frames from the
/// table (row 1 mirrored) and row 2; `walk-runner-zone.png` and `walk-runner-office.png`: a live runner walk sampled from Core
/// Animation's presentation in a window, each cell marked with the leg's way and which frames it shows.
@MainActor func walkFacingStills(_ dir: String) {
    walkRunnerTable { walkFacingStillsRunning(dir) }
}

@MainActor func walkFacingStillsRunning(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    OfficePets.shared.synchronous = true
    let runner = walkRunnerPet
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("walk stills: no \(name)") }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("walk stills: wrote \(dir)/\(name)")
    }
    func sheet(_ cells: [(CGImage?, String)], columns: Int, cell: CGFloat) -> CGImage? {
        let rows = (cells.count + columns - 1) / columns
        let canvas = OfficeCanvas(CGSize(width: cell * CGFloat(columns), height: (cell + 16) * CGFloat(rows)))
        canvas.ctx.setFillColor(OfficeCanvas.rgb(0x15192B))
        canvas.ctx.fill(CGRect(x: 0, y: 0, width: cell * CGFloat(columns), height: (cell + 16) * CGFloat(rows)))
        for (i, c) in cells.enumerated() {
            let x = CGFloat(i % columns) * cell, y = CGFloat(i / columns) * (cell + 16)
            if let image = c.0 {
                canvas.ctx.saveGState()
                canvas.ctx.translateBy(x: x, y: y + cell)
                canvas.ctx.scaleBy(x: 1, y: -1)
                canvas.ctx.interpolationQuality = .none
                let k = min(cell / CGFloat(image.width), cell / CGFloat(image.height))
                canvas.ctx.draw(image, in: CGRect(x: (cell - CGFloat(image.width) * k) / 2, y: 0, width: CGFloat(image.width) * k, height: CGFloat(image.height) * k))
                canvas.ctx.restoreGState()
            }
            canvas.text(c.1, in: CGRect(x: x, y: y + cell + 1, width: cell, height: 14), size: 9, weight: .semibold, 0xFFFFFF, align: .center)
        }
        return canvas.image()
    }
    let mirrored = Set((0..<8).compactMap { OfficePets.shared.runFrame(runner, facing: OfficePets.right, column: $0)?.image }.map(ObjectIdentifier.init))
    let raw = Set((0..<8).compactMap { OfficePets.shared.frame(runner, row: 1, column: $0)?.image }.map(ObjectIdentifier.init))
    func kind(_ image: CGImage?) -> String {
        guard let image else { return "none" }
        return mirrored.contains(ObjectIdentifier(image)) ? "row 1 mirrored" : raw.contains(ObjectIdentifier(image)) ? "row 1 as cut" : "other frame"
    }
    var frames: [(CGImage?, String)] = []
    for c in 0..<8 { frames.append((OfficePets.shared.frame(runner, row: 1, column: c)?.image, "row 1 as cut \(c)")) }
    for c in 0..<8 { frames.append((OfficePets.shared.runFrame(runner, facing: OfficePets.right, column: c)?.image, "right = row 1 mirrored \(c)")) }
    for c in 0..<8 { frames.append((OfficePets.shared.frame(runner, row: 2, column: c)?.image, "row 2 (left) \(c)")) }
    write(sheet(frames, columns: 8, cell: 96), "walk-runner-frames.png")

    // Sea room: from a Home desk to check-in (right, mostly), sampled.
    if let scene = ZoneArt.scene, let checkIn = scene.visitor {
        var made = Session(id: "zid-Home-sailor", pid: 1, project: "proj-sailor", name: "Home-sailor", status: "busy", since: Date() - 40, summary: "")
        made.cwd = "/tmp/walk/Home-sailor"
        let store = Store()
        store.readOnly = true
        store.sessions = [made]
        _ = officeDealCutPets(store, giving: ["zid-Home-sailor": runner])
        let size = CGSize(width: 1180, height: 790)
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        view.update(store)
        view.probeWalk("zid-Home-sailor", to: checkIn)
        let route = view.route(of: "zid-Home-sailor"), rows = ZoneWalk.rows(route)
        let seconds = view.walkEnds(of: "zid-Home-sailor") - CACurrentMediaTime()
        var cells: [(CGImage?, String)] = []
        for sample in zoneWalkSamples(view, "zid-Home-sailor", count: 12, every: max(0.1, seconds / 13)) {
            let leg = zoneLeg(route, at: sample.foot).map { rows[$0] }
            // The frame Core Animation shows at that moment (a presentation render puts the walker where it is going).
            cells.append((sample.frame, "\(leg == ZoneWalk.right ? "right →" : leg == ZoneWalk.left ? "left ←" : "?") \(kind(sample.frame))"))
        }
        write(sheet(cells, columns: 6, cell: 120), "walk-runner-zone.png")
        window.orderOut(nil)
        window.contentView = nil
    }

    // the office: s0 from its desk to the queue.
    let wasShown = OfficeTheme.shown
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = wasShown }
    let store = Store()
    store.readOnly = true
    store.sessions = officeSessions([("q", "waiting", 2, 900), ("s", "idle", 8, 600)])
    for s in store.sessions where !s.id.hasPrefix("q") { store.seen[s.id] = Date().timeIntervalSince1970 }
    guard officeDealCutPets(store, giving: ["s0": runner]) else { return print("walk stills: could not deal runner in the office") }
    let view = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1194, height: 764), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    view.update(store)
    store.sessions = store.sessions.map { $0.id == "s0" ? officeSession("s0", "waiting", finished: 1) : $0 }
    view.update(store)
    CATransaction.flush()
    let move = officeFigure(view, "s0")?.animation(forKey: "walk") as? CAKeyframeAnimation
    let route = move?.values?.compactMap { ($0 as? NSValue)?.pointValue } ?? []
    let legs = zip(route, route.dropFirst()).map { (from: $0, to: $1, length: hypot($1.x - $0.x, $1.y - $0.y)) }
    let rows = OfficeView.rows(for: legs)
    let end = (move?.beginTime ?? CACurrentMediaTime()) + (move?.duration ?? 1)
    let start = max(CACurrentMediaTime(), move?.beginTime ?? 0)
    var cells: [(CGImage?, String)] = []
    for i in 0..<12 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, start + Double(i) * (end - start) / 12 + 0.03 - CACurrentMediaTime())))
        guard let p = officeFigure(view, "s0")?.presentation()?.position, let shot = view.image(presentation: true) else { continue }
        let leg = zoneLeg(route, at: p).map { rows[$0] }
        let k: CGFloat = 2, side: CGFloat = 130
        let crop = shot.cropping(to: CGRect(x: (p.x - side / 2) * k, y: (p.y - side * 0.8) * k, width: side * k, height: side * k))
        cells.append((crop, "\(leg == OfficePets.right ? "right →" : leg == OfficePets.left ? "left ←" : leg == 7 ? "straight up/down (row 7)" : "?")"))
    }
    write(sheet(cells, columns: 6, cell: 150), "walk-runner-office.png")
    window.orderOut(nil)
    window.contentView = nil
}
