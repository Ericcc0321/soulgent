import AppKit
import QuartzCore
import SwiftUI

// The sea room sweep: the room driven through time with fixtures in an offscreen window, stills of the key moments
// and the behaviour checks (places, walks, plates, flips, layer counts, CPU). `--sea-sweep-stills <dir>` writes the stills
// and prints what it found; `--sea-sweep-perf` the CPU run; `seaSweepTests()` (in `--zone-only`) the checks for what the sweep covers.

/// Made-up zones as a `workzones.json` has them (codes, names, colours, leads), no folders: a fixture of its own.
let seaSweepZonesJSON = """
    {"zones": {"Web": {"name": "Web", "color": "#E0A040", "order": 1, "lead": "Web-DEMO-应用"},
               "Ops": {"name": "Ops", "color": "#40B0A0", "order": 2, "lead": "Ops-Demo-协同"},
               "AI": {"name": "AI", "color": "#5080D0", "order": 3, "lead": "AI-lead"},
               "Home": {"name": "Home", "color": "#A070D0", "order": 4, "lead": "Home-lead"}},
     "dirs": {}, "default": null}
    """

/// Points the zone files at fixtures of their own (zones, an off-duty roster, no pending check-ins) and clears the desk
/// memory; the returned closure puts everything back.
@MainActor func seaSweepSetup(_ dir: String, roster: String = "{}") -> () -> Void {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let zones = ZoneConfigFile.path, rosterPath = ZoneRosterFile.path, pending = ZonePendingFile.path
    try? seaSweepZonesJSON.write(toFile: dir + "/workzones.json", atomically: true, encoding: .utf8)
    try? roster.write(toFile: dir + "/roster.json", atomically: true, encoding: .utf8)
    ZoneConfigFile.path = dir + "/workzones.json"
    ZoneRosterFile.path = dir + "/roster.json"
    ZoneRosterFile.reset()
    ZonePendingFile.path = dir + "/no-pending.json"
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    ZoneMemory.holders = [:]
    ZoneMemory.names = [:]
    return {
        ZoneConfigFile.path = zones
        ZoneRosterFile.path = rosterPath
        ZoneRosterFile.reset()
        ZonePendingFile.path = pending
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
        ZoneMemory.holders = [:]
        ZoneMemory.names = [:]
    }
}

/// A session as another: a new name, status, since or summary, the rest kept.
func seaSweepRemake(_ s: Session, name: String? = nil, status: String? = nil, since: Date? = nil, summary: String? = nil) -> Session {
    let st = status ?? s.status
    let fixed = summary.flatMap(fixtureLine)
    var n = Session(id: s.id, pid: s.pid, project: s.project, name: name ?? s.name, status: st, since: since ?? s.since, summary: fixed?.rendered ?? summary ?? s.summary,
                    waitingFor: st == "waiting" ? "permission prompt" : "")
    n.summaryLine = fixed
    n.registryName = s.registryName
    n.cwd = s.cwd
    n.tool = s.tool
    n.model = s.model
    n.origin = s.origin
    return n
}

/// A small room: a few in each zone at work, done or waiting, and the one the sweep follows (a Home-<board>-<sweep> session, busy).
@MainActor func seaSweepRoom(extra: Int = 0) -> (store: Store, subject: String) {
    let now = Date()
    let store = Store()
    store.readOnly = true
    var list: [Session] = []
    func add(_ name: String, _ status: String, ago: Double, seen: Bool = true, tool: String = "", asks: String = "") {
        var s = Session(id: "sea-\(list.count)", pid: 1, project: name, name: name, status: status, since: now - ago,
                        summary: asks.isEmpty ? "整理完了，结果在 report.md" : asks, waitingFor: status == "waiting" ? "permission prompt" : "")
        s.cwd = "/tmp/sea/" + name
        s.registryName = name
        s.tool = tool
        list.append(s)
        if seen { store.seen[s.id] = now.timeIntervalSince1970 }
    }
    add("Home-风车-巡游", "busy", ago: 120, tool: "Edit")
    add("Home-lead", "idle", ago: 2000)
    add("Home-XR-萤火虫", "busy", ago: 150, tool: "Bash")
    add("Home-云朵", "idle", ago: 400, seen: false)
    add("Web-DEMO-应用", "busy", ago: 300, tool: "Bash")
    add("Web-UX-星图", "idle", ago: 900, seen: false)
    add("Web-星球漫游", "idle", ago: 1800)
    add("Ops-Demo-协同", "busy", ago: 400, tool: "Agent")
    add("Ops-彩虹桥", "idle", ago: 700, seen: false)
    add("AI-lead", "busy", ago: 100, tool: "WebFetch")
    add("AI-QA-风车塔", "idle", ago: 3000)
    for i in 0..<extra { add("AI-QA-云杉\(i + 1)", i % 3 == 0 ? "busy" : "idle", ago: Double(5000 + i * 60), tool: "Read") }
    store.sessions = list
    store.assignPets()
    return (store, "sea-0")
}

/// All the layers under one, itself included; for the room's root, only its own parts (the outdoors' crabs and gulls come
/// and go on their own).
func seaSweepLayerCount(_ layer: CALayer) -> Int {
    let parts: Set<String> = ["base", "lights", "marks", "stage", "plates", "speech", "boards"]
    if layer.superlayer == nil || layer.sublayers?.contains(where: { $0.name == "stage" }) == true {
        return (layer.sublayers ?? []).filter { parts.contains($0.name ?? "") }.reduce(0) { $0 + seaSweepLayerCount($1) }
    }
    return 1 + (layer.sublayers ?? []).reduce(0) { $0 + seaSweepLayerCount($1) }
}

/// What looks wrong in the room as it stands: figures in furniture or on each other, plates over plates or bubbles, a
/// figure not where its place says, two on one place.
@MainActor func seaSweepAudit(_ view: ZoneView, _ store: Store, _ scene: ZoneScene, _ fit: ZoneFit) -> [String] {
    var found: [String] = []
    let plan = view.plan
    let name = Dictionary(store.sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    // Two on one place.
    var byPlace: [ZonePlace: [String]] = [:]
    for (id, p) in plan.place {
        switch p {
        case .restListed, .checkInListed: continue
        default: byPlace[p, default: []].append(id)
        }
    }
    for (p, ids) in byPlace where ids.count > 1 { found.append("double-booked \(p): \(ids.compactMap { name[$0] })") }
    // The line, longest waiting first.
    let since = Dictionary(store.sessions.map { ($0.id, $0.since) }, uniquingKeysWith: { a, _ in a })
    let line = plan.line.compactMap { since[$0] }
    if line != line.sorted() { found.append("line out of order: \(plan.line.compactMap { name[$0] })") }
    // Feet: standing ones not in furniture; nobody on top of another.
    let tall = scene.petHeight * fit.scale
    var feet: [(String, CGPoint)] = []
    for s in store.sessions {
        guard let foot = view.foot(of: s.id) else { continue }
        feet.append((s.id, foot))
        let p = fit.back(foot)
        var standing = true
        switch plan.place[s.id] {
        case .desk?, .sofaSeat?, .rest?: standing = view.facing(of: s.id) != nil  // a visitor stands even from a desk
        default: break
        }
        if standing, let map = scene.walkMap {
            let w = map.world(p)
            if let box = map.boxes.first(where: { $0.contains(w, grow: 0) }) { found.append("\(name[s.id] ?? s.id) stands inside \(box.name.isEmpty ? "an obstacle" : box.name)") }
        }
        if standing, let desk = scene.desks.first(where: { $0.covers(p) }) { found.append("\(name[s.id] ?? s.id) stands on desk \(desk.zone)#\(desk.index)") }
    }
    for (i, a) in feet.enumerated() {
        for b in feet[(i + 1)...] where abs(a.1.x - b.1.x) < tall * 0.3 && abs(a.1.y - b.1.y) < tall * 0.12 {
            found.append("figures on each other: \(name[a.0] ?? a.0) / \(name[b.0] ?? b.0)")
        }
    }
    // Plates over plates; badges and bubbles over others' plates.
    var plates: [(String, CGRect)] = store.sessions.compactMap { s in view.plateFrame(of: s.id).map { (s.id, $0) } }
    plates = plates.filter { $0.1.width > 0 }
    for (i, a) in plates.enumerated() {
        for b in plates[(i + 1)...] where a.1.insetBy(dx: 1, dy: 1).intersects(b.1.insetBy(dx: 1, dy: 1)) {
            found.append("plates overlap: \(name[a.0] ?? a.0) / \(name[b.0] ?? b.0)")
        }
    }
    for s in store.sessions {
        var marks: [(String, CGRect)] = []
        if let badge = view.badge(of: s.id) { marks.append(("badge", badge.frame)) }
        if let dot = view.dotFrame(of: s.id) { marks.append(("dots", dot)) }
        if let bubble = view.bubbleFrame(of: s.id) { marks.append(("bubble", bubble)) }
        for (kind, r) in marks {
            for (other, plate) in plates where other != s.id && plate.insetBy(dx: 1, dy: 1).intersects(r.insetBy(dx: 1, dy: 1)) {
                found.append("\(name[s.id] ?? s.id)'s \(kind) over \(name[other] ?? other)'s plate")
            }
        }
    }
    return found
}

/// The floor points of a walk (view points) that lie in an obstacle other than the ones it starts or ends in, sampled
/// every few pixels: a walk through a desk or a sofa.
@MainActor func seaSweepCrossings(_ route: [CGPoint], _ scene: ZoneScene, _ fit: ZoneFit) -> [String] {
    guard let map = scene.walkMap, route.count > 1 else { return [] }
    let a = map.world(fit.back(route[0])), b = map.world(fit.back(route[route.count - 1]))
    let ends = map.boxes.filter { $0.contains(a, grow: 0.05) || $0.contains(b, grow: 0.05) }
    var hits = Set<String>()
    for (p, q) in zip(route, route.dropFirst()) {
        let n = max(1, Int(hypot(q.x - p.x, q.y - p.y) / 2))
        for k in 0...n {
            let t = CGFloat(k) / CGFloat(n)
            let w = map.world(fit.back(CGPoint(x: p.x + (q.x - p.x) * t, y: p.y + (q.y - p.y) * t)))
            for box in map.boxes where !ends.contains(box) && box.contains(w, grow: -0.02) { hits.insert(box.name.isEmpty ? "box" : box.name) }
        }
    }
    return hits.sorted()
}

/// `--sea-sweep-stills <dir>`: the stills and the findings of the sweep.
@MainActor func seaSweepStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let restore = seaSweepSetup(NSTemporaryDirectory() + "sea-\(getpid())")
    defer { restore() }
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    guard let scene = ZoneArt.scene else { return print("zone sweep: no art") }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("zone sweep: no \(name)") }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone sweep: wrote \(name)")
    }
    let size = CGSize(width: 1180, height: 790)
    let fit = ZoneFit(scene: scene.size, view: size)
    let (store, subject) = seaSweepRoom()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.onScreenOverride = true
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.update(store)
    var findings: [String] = []
    func note(_ s: String) {
        findings.append(s)
        print("zone sweep FINDING: " + s)
    }
    func settle(_ extra: Double = 0.3) {
        CATransaction.flush()
        var longest = 0.0
        for s in store.sessions { longest = max(longest, view.walkEnds(of: s.id) - CACurrentMediaTime()) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, longest) + extra))
    }
    /// A still of the room as it stands (the live view's layers are not in zPosition order: a still view over the same
    /// memory draws it as the window shows it), with a 2× crop round a point.
    func still(_ name: String, around: CGPoint? = nil, visit: (String, String)? = nil) {
        let image = zoneStill(store, size: size, visit: visit)
        write(image, name + ".png")
        if let around, let image {
            let side: CGFloat = 300
            let k = CGFloat(image.width) / size.width
            let r = CGRect(x: (around.x - side / 2) * k, y: (around.y - side * 0.6) * k, width: side * k, height: side * k)
                .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            write(image.cropping(to: r), name + "-zoom.png")
        }
    }
    func audit(_ label: String) {
        for f in seaSweepAudit(view, store, scene, fit) { note("\(label): \(f)") }
    }
    func set(_ id: String, _ change: (Session) -> Session) {
        store.sessions = store.sessions.map { $0.id == id ? change($0) : $0 }
        view.update(store)
        // Walks crossing furniture, as they set off.
        let route = view.route(of: id)
        let crossed = seaSweepCrossings(route, scene, fit)
        if !crossed.isEmpty { note("walk of \(store.sessions.first { $0.id == id }?.name ?? id) crosses \(crossed)") }
    }
    let name = { (id: String) in store.sessions.first { $0.id == id }?.name ?? id }
    settle()
    let desk = view.plan.desks[subject]
    let deskSeat = desk.flatMap { scene.desk($0)?.seat }
    print("zone sweep: subject's desk \(desk?.key ?? "-")")
    audit("start")
    still("sea-01-start", around: view.foot(of: subject))

    // ── Waiting: two already in the line, the subject joins it third. ──
    let now = Date()
    set("sea-4") { seaSweepRemake($0, status: "waiting", since: now - 300, summary: "要你批准：npm test") }
    set("sea-7") { seaSweepRemake($0, status: "waiting", since: now - 200, summary: "要你回答：端口用 8080 还是 9000？") }
    settle()
    set(subject) { seaSweepRemake($0, status: "waiting", since: Date(), summary: "要你批准：git push origin main") }
    let walkSeconds = view.walkEnds(of: subject) - CACurrentMediaTime()
    print(String(format: "zone sweep: to the line: %.1f s, %d legs", walkSeconds, max(0, view.route(of: subject).count - 1)))
    settle()
    print("zone sweep: line \(view.plan.line.map(name)) queue head \(view.plan.queue.map(name) ?? "-") subject at \(String(describing: view.plan.place[subject]))")
    if view.plan.place[subject] != .line(2) { note("joining third, the subject is at \(String(describing: view.plan.place[subject])), not line 2") }
    if let spot = scene.lineSpot(2), let foot = view.foot(of: subject), hypot(fit.back(foot).x - spot.x, fit.back(foot).y - spot.y) > 1 { note("in the line, not on its spot") }
    print("zone sweep: subject pose \(String(describing: view.shownPose(of: subject))) facing \(String(describing: view.facing(of: subject))) bubble '\(view.bubbleKey(of: subject))' head bubble '\(view.bubbleKey(of: "sea-4"))'")
    if !view.bubbleKey(of: subject).isEmpty { note("third in the line wears a bubble: \(view.bubbleKey(of: subject))") }
    audit("line of three")
    still("sea-02-line-joined", around: view.foot(of: subject))

    // ── The two ahead answered (busy again): the subject is the head, with its own words. ──
    set("sea-4") { seaSweepRemake($0, status: "busy", since: Date()) }
    set("sea-7") { seaSweepRemake($0, status: "busy", since: Date()) }
    settle()
    let ask = view.bubbleKey(of: subject)
    print("zone sweep: head now \(view.plan.queue.map(name) ?? "-"), bubble '\(ask)'")
    if view.plan.queue != subject || !ask.contains("git push") { note("the new head's bubble is not its own: '\(ask)'") }
    if let foot = view.foot(of: subject), let spot = scene.lineSpot(0), hypot(fit.back(foot).x - spot.x, fit.back(foot).y - spot.y) > 1 { note("the head is not on the head's spot") }
    audit("head of the line")
    still("sea-03-line-head", around: view.foot(of: subject))

    // ── Answered: back to its desk, bubble gone. ──
    set(subject) { seaSweepRemake($0, status: "busy", since: Date()) }
    settle()
    if let foot = view.foot(of: subject), let seat = deskSeat, hypot(fit.back(foot).x - seat.x, fit.back(foot).y - seat.y) > 1 { note("answered, not back at its own desk") }
    if !view.bubbleKey(of: subject).isEmpty || view.asks(subject) { note("answered, still wears '\(view.bubbleKey(of: subject))'") }
    if view.shownFoot(of: subject) != view.foot(of: subject) { note("answered: shown foot \(String(describing: view.shownFoot(of: subject))) is not its place") }
    audit("back at desk")
    still("sea-04-answered-desk", around: view.foot(of: subject))

    // ── Done, not looked at: the sofa; looked at: its desk. ──
    set(subject) { seaSweepRemake($0, status: "idle", since: Date()) }
    settle()
    print("zone sweep: unread subject at \(String(describing: view.plan.place[subject])) dots \(view.dotShown(subject))")
    if case .sofaSeat? = view.plan.place[subject] {} else if case .sofaSpot? = view.plan.place[subject] {} else { note("unread, not at the sofa: \(String(describing: view.plan.place[subject]))") }
    audit("unread on sofa")
    still("sea-05-unread-sofa", around: view.foot(of: subject))
    store.seen[subject] = Date().timeIntervalSince1970 + 1
    view.update(store)
    settle()
    if view.plan.place[subject] != desk.map({ .desk($0) }) { note("seen, not at its desk") }
    audit("seen at desk")
    still("sea-06-seen-desk", around: view.foot(of: subject))

    // ── Resting (seen six hours ago): at its desk by the table; the rest room is for a zone over twelve. ──
    set(subject) { seaSweepRemake($0, since: Date() - 7 * 3600) }
    store.seen[subject] = Date().timeIntervalSince1970
    view.update(store)
    settle()
    print("zone sweep: resting subject at \(String(describing: view.plan.place[subject])) pose \(String(describing: view.shownPose(of: subject)))")

    // ── A visitor beside its host. ──
    let host = "sea-2"  // the Home-XR session at its desk
    view.visit(subject, to: host, words: "端口改成 9000 了，你那边也改一下", until: Date() + 60)
    view.update(store)
    let visitRoute = view.route(of: subject)
    let crossed = seaSweepCrossings(visitRoute, scene, fit)
    if !crossed.isEmpty { note("visit walk crosses \(crossed)") }
    settle()
    if let v = view.foot(of: subject), let h = view.foot(of: host) {
        let faces = view.facing(of: subject)
        print(String(format: "zone sweep: visitor at (%.0f,%.0f), host at (%.0f,%.0f), facing %@", v.x, v.y, h.x, h.y, String(describing: faces)))
        if (faces == ZoneWalk.right) != (h.x >= v.x) { note("the visitor faces away from its host") }
    }
    audit("visit")
    still("sea-07-visitor", around: view.foot(of: host), visit: (subject, host))
    view.visit(subject, to: host, words: "", until: Date() - 1)
    view.update(store)
    settle()

    // ── Renamed: same session, a new name. ──
    let before = view.plan.desks[subject]
    set(subject) { seaSweepRemake($0, name: "Home-风车-巡游改名") }
    settle()
    let after = view.plan.desks[subject]
    print("zone sweep: renamed: desk \(before?.key ?? "-") → \(after?.key ?? "-")")
    if before != after { note("renamed, it moved desk \(before?.key ?? "-") → \(after?.key ?? "-")") }
    audit("renamed")
    still("sea-08-renamed", around: view.foot(of: subject))

    // ── Closed: the figure fades and its layers go. ──
    let layersBefore = seaSweepLayerCount(view.layer!)
    let closing = "sea-10"
    let closingFoot = view.foot(of: closing)
    store.sessions.removeAll { $0.id == closing }
    view.update(store)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.9))
    let layersAfter = seaSweepLayerCount(view.layer!)
    print("zone sweep: closed one: layers \(layersBefore) → \(layersAfter), figure \(view.figureLayer(of: closing) == nil ? "gone" : "still there")")
    if view.figureLayer(of: closing) != nil || layersAfter >= layersBefore { note("a closed session's layers stay") }
    still("sea-09-closed", around: closingFoot)

    // ── Busy ↔ idle every 3 s for 30 s: never stuck, always ends where its place is. ──
    var stuck: [String] = []
    for i in 0..<10 {
        set(subject) { seaSweepRemake($0, status: i % 2 == 0 ? "busy" : "idle", since: Date()) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
        if let shown = view.shownFoot(of: subject), let foot = view.foot(of: subject), view.walkEnds(of: subject) < CACurrentMediaTime(),
           hypot(shown.x - foot.x, shown.y - foot.y) > 1 {
            stuck.append(String(format: "flip %d: shown (%.0f,%.0f) place (%.0f,%.0f)", i, shown.x, shown.y, foot.x, foot.y))
        }
    }
    if !stuck.isEmpty { note("stuck after flips every 3 s: \(stuck)") }
    // Quicker: every 0.35 s for 7 s (a walk cut off near its start), then still.
    for i in 0..<20 {
        set(subject) { seaSweepRemake($0, status: i % 2 == 0 ? "busy" : "idle", since: Date()) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.35))
    }
    settle(0.5)
    if let shown = view.shownFoot(of: subject), let foot = view.foot(of: subject), hypot(shown.x - foot.x, shown.y - foot.y) > 1 {
        note(String(format: "stuck after quick flips: shown (%.0f,%.0f) place (%.0f,%.0f)", shown.x, shown.y, foot.x, foot.y))
    }
    if let steps = view.spriteAnimation(of: subject, "steps"), view.walkEnds(of: subject) < CACurrentMediaTime() {
        let sprite = view.figureLayer(of: subject)?.sublayers?.first { $0.animation(forKey: "steps") != nil }
        let local = sprite?.convertTime(CACurrentMediaTime(), from: nil) ?? 0
        note(String(format: "still running in place after quick flips (steps begin %.2f, %.2f s long, now %.2f; walk ends %.2f, now %.2f, walk anim %@)",
                    steps.beginTime, steps.duration, local, view.walkEnds(of: subject), CACurrentMediaTime(),
                    view.figureLayer(of: subject)?.animation(forKey: "walk") == nil ? "gone" : "kept"))
    }
    // A flip back to where it set off from a moment ago (a walk of under a pixel).
    set(subject) { seaSweepRemake($0, status: "busy", since: Date()) }
    settle()
    set(subject) { seaSweepRemake($0, status: "idle", since: Date()) }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    set(subject) { seaSweepRemake($0, status: "busy", since: Date()) }
    let endsAt = view.walkEnds(of: subject)
    settle(0.3)
    if let shown = view.shownFoot(of: subject), let foot = view.foot(of: subject), hypot(shown.x - foot.x, shown.y - foot.y) > 1 {
        note(String(format: "flip back within a frame: shown (%.0f,%.0f) place (%.0f,%.0f), walk ends %.1f s later", shown.x, shown.y, foot.x, foot.y, endsAt - CACurrentMediaTime()))
    }

    // ── Layers over many flips (a stand-in for 10 minutes of them). ──
    set(subject) { seaSweepRemake($0, status: "busy", since: Date()) }
    settle(0.8)
    let start = seaSweepLayerCount(view.layer!)
    for i in 0..<200 {
        set(subject) { seaSweepRemake($0, status: i % 2 == 0 ? "idle" : "busy", since: Date()) }
        set("sea-2") { seaSweepRemake($0, status: i % 3 == 0 ? "waiting" : "busy", since: Date()) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
    }
    set(subject) { seaSweepRemake($0, status: "busy", since: Date()) }
    set("sea-2") { seaSweepRemake($0, status: "busy", since: Date()) }
    settle(0.8)
    let end = seaSweepLayerCount(view.layer!)
    print("zone sweep: layers before 200 flips \(start), after \(end)")
    if end > start { note("layers grew over 200 flips: \(start) → \(end)") }

    // ── Off duty: the subject goes off (closed, on the roster) and comes back as a new session of the same name. ──
    let offDesk = view.plan.desks[subject]
    let subjectName = name(subject)
    let rosterJSON = "{\"\(subjectName)\": {\"cwd\": \"/tmp/sea/x\", \"sid\": \"old\", \"zone\": \"Home\", \"offAt\": \(Int(Date().timeIntervalSince1970))},"
        + " \"Web-星报\": {\"cwd\": \"/tmp/sea/y\", \"zone\": \"Web\", \"offAt\": \(Int(Date().timeIntervalSince1970) - 60)}}"
    try? rosterJSON.write(toFile: ZoneRosterFile.path, atomically: true, encoding: .utf8)
    store.sessions.removeAll { $0.id == subject }
    view.update(store)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.9))
    print("zone sweep: off duty: badges Home \(String(describing: view.offBadge("Home"))) Web \(String(describing: view.offBadge("Web")))")
    if view.offBadge("Home")?.count != 1 || view.offBadge("Web")?.count != 1 { note("off-duty badges not 1 and 1") }
    audit("off duty")
    still("sea-10-offduty", around: view.signPill("Home").map { CGPoint(x: $0.midX, y: $0.midY + 60) })
    try? "{}".write(toFile: ZoneRosterFile.path, atomically: true, encoding: .utf8)
    var back = Session(id: "sea-back", pid: 1, project: "p", name: subjectName, status: "busy", since: Date(), summary: "")
    back.cwd = "/tmp/sea/x"
    store.sessions.append(back)
    store.assignPets()
    view.update(store)
    settle()
    print("zone sweep: back from off duty: desk \(offDesk?.key ?? "-") → \(view.plan.desks["sea-back"]?.key ?? "-"), figure \(view.foot(of: "sea-back") != nil)")
    if view.plan.desks["sea-back"] != offDesk || view.foot(of: "sea-back") == nil { note("back from off duty, not at its desk") }

    // ── Thirty: one zone runs out of desks. ──
    window.orderOut(nil)
    let crowd = seaSweepRoom(extra: 19).store
    let crowdView = ZoneView(frame: CGRect(origin: .zero, size: size))
    crowdView.still = true
    crowdView.update(crowd)
    let plan = crowdView.plan
    print("zone sweep: thirty: \(crowd.sessions.count) sessions, AI +N \(plan.overflow["AI"]?.count ?? 0), rest \(plan.rest.count) + \(plan.restOverflow.count), badge \(String(describing: crowdView.signPill("AI")))")
    for f in seaSweepAudit(crowdView, crowd, scene, fit) { note("thirty: \(f)") }
    let crowdStore = store
    _ = crowdStore
    let thirty = zoneStill(crowd, size: size)
    write(thirty, "sea-11-thirty.png")
    print("zone sweep: \(findings.count) findings")
}

/// `--sea-sweep-perf`: 26 sessions, three of them Fable and busy, the room live for 60 s in an offscreen window seen as on
/// screen: this process's CPU (user + system) over the minute, and how long one `update` takes.
@MainActor func seaSweepPerf(seconds: Double = 60) {
    let restore = seaSweepSetup(NSTemporaryDirectory() + "seap-\(getpid())")
    defer { restore() }
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    let (store, _) = seaSweepRoom(extra: 15)
    var fable = 0
    store.sessions = store.sessions.map { s in
        var s = s
        if s.status == "busy", fable < 3 {
            s.model = "claude-fable-5-1"
            fable += 1
        }
        return s
    }
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.onScreenOverride = true
    view.calmOverride = false
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    view.update(store)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 3))
    func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }
    // One update as the store's poll makes it (nothing changed), timed.
    var times: [Double] = []
    for _ in 0..<20 {
        let t = CACurrentMediaTime()
        view.update(store)
        times.append((CACurrentMediaTime() - t) * 1000)
    }
    times.sort()
    print(String(format: "zone sweep perf: %d sessions, %d Fable busy; update() median %.1f ms, max %.1f ms", store.sessions.count, fable, times[times.count / 2], times.last ?? 0))
    let c0 = cpu(), w0 = Date()
    // The store polls every 2 s or so; each poll updates the room.
    var polls = 0
    while Date().timeIntervalSince(w0) < seconds {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        view.update(store)
        polls += 1
    }
    let used = cpu() - c0, wall = Date().timeIntervalSince(w0)
    print(String(format: "zone sweep perf: %.1f s wall, %.2f s CPU (%.1f %% of a core), %d polls", wall, used, used / wall * 100, polls))
    // The same minute with nobody updating it: what runs on its own (timers, the outdoors).
    let c1 = cpu(), w1 = Date()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: min(20, seconds)))
    let idle = cpu() - c1, idleWall = Date().timeIntervalSince(w1)
    print(String(format: "zone sweep perf: no polls: %.2f s CPU over %.1f s (%.1f %%)", idle, idleWall, idle / idleWall * 100))
    window.orderOut(nil)
    window.contentView = nil
}

/// The checks for what the sweep covers (in `--zone-only`).
@MainActor func seaSweepTests() {
    let restore = seaSweepSetup(NSTemporaryDirectory() + "seat-\(getpid())")
    defer { restore() }

    // A renamed session (same id, a new name) keeps its desk, even when a lower desk of its zone has come free meanwhile.
    do {
        let now = Date()
        let store = Store()
        store.readOnly = true
        func make(_ id: String, _ name: String) -> Session {
            var s = Session(id: id, pid: 1, project: "p", name: name, status: "busy", since: now - 60, summary: "")
            s.cwd = "/tmp/sea"
            return s
        }
        store.sessions = [make("a", "Home-lead"), make("b", "Home-Alpha"), make("c", "Home-Bravo")]
        let first = ZonePlan.current(store, scene: nil)
        store.sessions = [make("a", "Home-lead"), make("c", "Home-Bravo-renamed")]
        let second = ZonePlan.current(store, scene: nil)
        store.sessions = [make("a", "Home-lead"), make("c", "Home-Bravo-renamed"), make("d", "Home-Bravo")]
        let third = ZonePlan.current(store, scene: nil)
        check("zone sweep: a renamed session keeps its desk (Home#3), though desk 2 came free (was \(first.desks["c"]?.key ?? "-") → \(second.desks["c"]?.key ?? "-"))",
              first.desks["c"]?.key == "Home#3" && second.desks["c"]?.key == "Home#3")
        check("zone sweep: its old name is not kept for it: a new session of that old name takes a free desk (\(third.desks["d"]?.key ?? "-"))",
              third.desks["c"]?.key == "Home#3" && third.desks["d"]?.key == "Home#2")
    }

    guard let scene = ZoneArt.scene else { return }
    let size = CGSize(width: 1180, height: 790)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true

    // A walk turned back before it has gone a pixel (two changes in one moment): it does not carry on to the old place.
    do {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
        ZoneMemory.holders = [:]
        let (store, subject) = seaSweepRoom()
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.calmOverride = false
        let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        view.update(store)
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        let home = view.foot(of: subject)
        store.sessions = store.sessions.map { $0.id == subject ? seaSweepRemake($0, status: "idle", since: Date()) : $0 }
        view.update(store)
        CATransaction.flush()
        store.sessions = store.sessions.map { $0.id == subject ? seaSweepRemake($0, status: "busy", since: Date()) : $0 }
        view.update(store)
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.8))
        let shown = view.shownFoot(of: subject) ?? .zero, at = view.foot(of: subject) ?? .zero
        check(String(format: "zone sweep: turned back at once, it stays home (shown %.0f,%.0f; home %.0f,%.0f)", shown.x, shown.y, at.x, at.y),
              home == at && hypot(shown.x - at.x, shown.y - at.y) < 1)
        window.orderOut(nil)
        window.contentView = nil
    }

    // Thirty, one zone past its twelve desks: the rest room's "+N" lies on no one's pet or plate.
    do {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
        ZoneMemory.holders = [:]
        let crowd = seaSweepRoom(extra: 19).store
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(crowd)
        let pill = view.restPillFrame
        let hit = crowd.sessions.filter { s in
            guard let pill else { return false }
            let boxes = [view.drawnBox(of: s.id), view.plateFrame(of: s.id), view.badge(of: s.id)?.frame, view.dotFrame(of: s.id)].compactMap { $0 }
            return boxes.contains { $0.insetBy(dx: 1, dy: 1).intersects(pill) }
        }.map(\.name)
        check("zone sweep: the rest room's +N pill (\(pill.map { "\(Int($0.minX)),\(Int($0.minY))" } ?? "none")) covers no figure (on \(hit))", pill != nil && hit.isEmpty)
        // nor within 12 pt of anyone's head (the top 40 % of the pet as drawn).
        let near = crowd.sessions.filter { s in
            guard let pill, let box = view.drawnBox(of: s.id) else { return false }
            return CGRect(x: box.minX, y: box.minY, width: box.width, height: box.height * 0.4).insetBy(dx: -12, dy: -12).intersects(pill)
        }.map(\.name)
        check("zone sweep: the +N pill is 12 pt clear of every head (near \(near)) and inside the view",
              pill != nil && near.isEmpty && view.bounds.contains(pill ?? .zero))
        _ = scene
        if let dir = ProcessInfo.processInfo.environment["SEA_SWEEP_STILLS"], let image = view.image() {
            let k = CGFloat(image.width) / size.width
            if let crop = image.cropping(to: CGRect(x: 0, y: 0, width: 420 * k, height: 360 * k)),
               let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/seab-rest-pill-zoom.png"))
            }
        }
    }

    // In the line by the sofas: one's unread dots never sit on another's pet (they read as that one's).
    do {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
        ZoneMemory.holders = [:]
        let (store, subject) = seaSweepRoom()
        let now = Date()
        store.sessions = store.sessions.map { s in
            switch s.id {
            case "sea-4": return seaSweepRemake(s, status: "waiting", since: now - 300, summary: "要你批准：npm test")
            case "sea-7": return seaSweepRemake(s, status: "waiting", since: now - 200, summary: "要你回答：端口")
            case subject: return seaSweepRemake(s, status: "waiting", since: now, summary: "要你批准：git push")
            default: return s
            }
        }
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        var on: [String] = []
        for s in store.sessions {
            guard let dots = view.dotFrame(of: s.id) else { continue }
            for o in store.sessions where o.id != s.id {
                if let box = view.drawnBox(of: o.id), box.insetBy(dx: box.width * 0.1, dy: 0).intersects(dots) { on.append("\(s.name) on \(o.name)") }
            }
        }
        check("zone sweep: unread dots sit on no other pet (\(on))", on.isEmpty)
    }

    // a visitor by a busy host: its bubble is off the host's tool badge, and it stands clear of the figures nearby.
    do {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
        ZoneMemory.holders = [:]
        ZoneMemory.names = [:]
        let (store, subject) = seaSweepRoom()
        let host = "sea-2"  // the Home-XR session, busy at Home#2, beside the lead's desk 1
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        view.visit(subject, to: host, words: "端口改成 9000 了，你那边也改一下", until: Date() + 60)
        view.update(store)
        let bubble = view.bubbleFrame(of: subject), badge = view.badge(of: host)?.frame
        check("zone sweep: the visitor's bubble (\(bubble.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "-")) is off the host's badge (\(badge.map { "\(Int($0.minX))…\(Int($0.maxX))" } ?? "-"))",
              bubble != nil && badge != nil && !(bubble!.intersects(badge!)))
        var over: [String] = []
        if let mine = view.drawnBox(of: subject) {
            for o in store.sessions where o.id != subject && o.id != host {
                guard let box = view.drawnBox(of: o.id) else { continue }
                let a = mine.insetBy(dx: mine.width * 0.15, dy: 0), b = box.insetBy(dx: box.width * 0.15, dy: 0)
                if a.intersects(b) { over.append("\(o.name) \(Int(a.minX))…\(Int(a.maxX)),\(Int(a.minY))…\(Int(a.maxY)) vs \(Int(b.minX))…\(Int(b.maxX)),\(Int(b.minY))…\(Int(b.maxY))") }
            }
        }
        check("zone sweep: the visitor stands clear of the other figures (over \(over))", view.facing(of: subject) != nil && over.isEmpty)
        if let dir = ProcessInfo.processInfo.environment["SEA_SWEEP_STILLS"], let image = view.image(), let foot = view.foot(of: host) {
            let k = CGFloat(image.width) / size.width
            let crop = image.cropping(to: CGRect(x: (foot.x - 150) * k, y: (foot.y - 180) * k, width: 300 * k, height: 300 * k))
            if let crop, let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/seab-visitor-zoom.png"))
            }
        }
    }
}
