import AppKit
import SwiftUI
import AVFoundation

/// Seaview. Checks of the zone rules (which zone, which desk, where a waiting one goes, what a desk shows) and of the
/// room drawn from the art. None passes on an empty scene: the art's checks insist on its 40 desks and its picture.

@MainActor func zoneTests() {
    let dir = NSTemporaryDirectory() + "zone-tests-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let fake = "/Users/tester"
    let fixture = """
        {"zones": {"Web": {"name": "Web", "color": "#E0A040", "order": 1, "lead": "Web-L"},
                   "Ops": {"name": "Ops", "color": "#40B0A0", "order": 2, "lead": "Ops-L"},
                   "AI": {"name": "Docs", "color": "#5080D0", "order": 3, "lead": null},
                   "Home": {"name": "Infra", "color": "#A070D0", "order": 4, "lead": "Home-L"}},
         "dirs": {"~/p/portal": "AI", "~/p/portal/8080": "Web", "~/p/model-Q*4": "AI", "~/p/Mac": "Home"},
         "default": null}
        """
    let config = ZoneConfig.parse(Data(fixture.utf8), home: fake)

    // ── Which zone ──
    check("zone: four zones read in their order, with display names and leads",
        config.zones.map(\.code) == ["Web", "Ops", "AI", "Home"] && config.zone("Ops")?.name == "Ops" && config.zone("Web")?.lead == "Web-L"
            && config.zone("AI")?.lead == nil)
    check("zone: a name's zone prefix wins over its folder",
        config.resolve(name: "Web-DEMO-追踪", cwd: fake + "/p/portal") == "Web" && config.resolve(name: "Home-lead", cwd: fake + "/p/portal/8080") == "Home")
    check("zone: without a prefix, the longest listed folder that holds the cwd (~ is home)",
        config.resolve(name: "x", cwd: fake + "/p/portal/8080/sub") == "Web" && config.resolve(name: "x", cwd: fake + "/p/portal") == "AI"
            && config.resolve(name: "x", cwd: fake + "/p/portal/other") == "AI")
    check("zone: a folder only holds its own subfolders: portal2 is not under portal",
        config.resolve(name: "x", cwd: fake + "/p/portal2") == nil)
    check("zone: a * in a folder is a literal character, not a pattern",
        config.resolve(name: "x", cwd: fake + "/p/model-Q*4/run") == "AI" && config.resolve(name: "x", cwd: fake + "/p/model-Qab4") == nil)
    check("zone: an unknown prefix and no listed folder leave a session unzoned",
        config.resolve(name: "Zzz-foo", cwd: "/tmp/elsewhere") == nil && config.resolve(name: "plain", cwd: "") == nil)
    let defaulted = ZoneConfig.parse(Data(fixture.replacingOccurrences(of: "\"default\": null", with: "\"default\": \"Home\"").utf8), home: fake)
    let badDefault = ZoneConfig.parse(Data(fixture.replacingOccurrences(of: "\"default\": null", with: "\"default\": \"Nope\"").utf8), home: fake)
    check("zone: `default` places the rest when it names a known zone, after prefix and folder",
        defaulted.resolve(name: "plain", cwd: "/tmp") == "Home" && defaulted.resolve(name: "x", cwd: fake + "/p/portal") == "AI"
            && badDefault.resolve(name: "plain", cwd: "/tmp") == nil)

    // The file is read again when it changes.
    let file = dir + "/workzones.json"
    let before = ZoneConfigFile.path
    ZoneConfigFile.path = file
    try? fixture.write(toFile: file, atomically: true, encoding: .utf8)
    let first = ZoneConfigFile.current().zones.count
    try? "{\"zones\": {\"Solo\": {\"name\": \"单\", \"order\": 1}}, \"dirs\": {}}".write(toFile: file, atomically: true, encoding: .utf8)
    let second = ZoneConfigFile.current().zones.map(\.code)
    ZoneConfigFile.path = before
    check("zone: workzones.json is read again once it changes", first == 4 && second == ["Solo"])

    // ── Plates ──
    check("zone: a plate drops the zone prefix and nothing more",
        config.plate("Web-DEMO-追踪") == "DEMO-追踪" && config.plate("Home-lead") == "lead" && config.plate("Ops-Demo-AI助手") == "Demo-AI助手")
    check("zone: a name without a zone prefix keeps all of it", config.plate("foo-bar") == "foo-bar" && config.plate("solo") == "solo")

    // ── Desks ──
    let t0 = Date()
    func m(_ name: String, _ state: ZoneState = .seen, ago: Double = 100, zone: String? = nil) -> ZoneMember {
        ZoneMember(id: "id-" + name, name: name, zone: zone ?? config.prefix(of: name), state: state, since: t0 - ago)
    }
    let crew = [m("Web-A"), m("Web-L"), m("Web-B"), m("Web-C")]
    let p1 = ZonePlan.make(crew, config: config, memory: [:], sofaSeats: [:])
    check("zone: the lead sits at desk 1, the others take desks 2, 3, 4 as they come",
        p1.desks["id-Web-L"] == ZoneDesk(zone: "Web", index: 1) && p1.desks["id-Web-A"]?.index == 2 && p1.desks["id-Web-B"]?.index == 3
            && p1.desks["id-Web-C"]?.index == 4)
    let noLead = ZonePlan.make([m("Web-A"), m("Web-B")], config: config, memory: [:], sofaSeats: [:])
    check("zone: with the lead closed desk 1 stays empty", noLead.desks.values.allSatisfy { $0.index != 1 } && noLead.desks.count == 2)
    let shuffled = ZonePlan.make([m("Web-C"), m("Web-B"), m("Web-A"), m("Web-L")], config: config, memory: p1.memory, sofaSeats: [:])
    check("zone: desks stick by name across passes, whatever order the sessions come in",
        shuffled.desks == p1.desks && p1.memory["Web-B"] == "Web#3")
    let comeback = ZonePlan.make([m("Web-New"), m("Web-B")], config: config, memory: ["Web-B": "Web#6"], sofaSeats: [:])
    check("zone: a remembered desk is kept, a newcomer takes the lowest free one of 2–12",
        comeback.desks["id-Web-B"]?.index == 6 && comeback.desks["id-Web-New"]?.index == 2)
    var many: [ZoneMember] = []
    for i in 0..<14 { many.append(m("Ops-w\(i)", ago: Double(100 + i))) }
    let full = ZonePlan.make(many, config: config, memory: [:], sofaSeats: [:])
    check("zone: eleven desks for the non-leads (twelve a zone); the rest have none and are counted for the sign's +N",
        full.desks.count == 11 && full.overflow["Ops"]?.count == 3 && Set(full.desks.values.map(\.index)) == Set(2...12) && ZonePlan.desksPerZone == 12)
    let visitors = ZonePlan.make([m("plain-a"), m("plain-b"), m("plain-c")], config: config, memory: [:], sofaSeats: [:])
    check("zone: an unzoned session takes the check-in seat, more than one are listed on its label",
        visitors.visitor == "id-plain-a" && visitors.visitorList == ["id-plain-b", "id-plain-c"] && visitors.desks.isEmpty)
    let visitorsAgain = ZonePlan.make([m("plain-c"), m("plain-b"), m("plain-a")], config: config, memory: visitors.memory, sofaSeats: [:])
    check("zone: the check-in seat sticks too", visitorsAgain.visitor == "id-plain-a")

    // ── Waiting ──
    let waiting = [m("Web-A", .waiting, ago: 900), m("plain-u", .waiting, ago: 800), m("Web-B", .waiting, ago: 700), m("Ops-X", .waiting, ago: 600),
                   m("Web-C", .waiting, ago: 500), m("Home-Y", .waiting, ago: 400), m("Web-D", .waiting, ago: 300), m("Web-E", .waiting, ago: 200),
                   m("Web-F", .waiting, ago: 100), m("Web-G", .waiting, ago: 90), m("plain-z", .waiting, ago: 10)]
    let routed = ZonePlan.make(waiting.shuffled(), config: config, memory: [:], sofaSeats: ["Web": 3, "Ops": 3], sofaSpots: ["Web": 3, "Ops": 3])
    check("zone: the one waiting longest stands at the boss's desk, at the head of the line", routed.queue == "id-Web-A" && routed.line.first == "id-Web-A")
    check("zone: the six waiting longest line up in front of you, longest first, whatever their zone",
        routed.line == ["id-Web-A", "id-plain-u", "id-Web-B", "id-Ops-X", "id-Web-C", "id-Home-Y"] && ZonePlan.lineLength == 6)
    check("zone: an unzoned waiting one joins the same line; only those beyond the line are left over",
        routed.line.contains("id-plain-u") && routed.lobby == ["id-plain-z"])
    check("zone: the 7th waiting and after stand at their zone's sofa (its spots, not its seats), longest waiting first",
        routed.sofaOverflow["Web"] == ["id-Web-D", "id-Web-E", "id-Web-F"] && routed.sofa.isEmpty
            && routed.sofaOverflow["Ops"] == nil && routed.sofaOverflow["Home"] == nil)
    let two = ZonePlan.make(waiting, config: config, memory: [:], sofaSeats: ["Web": 3], sofaSpots: ["Web": 2])
    check("zone: a sofa's spots are what the art has (2 here), not a fixed 3; the next waits at its desk",
        two.sofaOverflow["Web"] == ["id-Web-D", "id-Web-E"] && two.sofa.isEmpty && !two.sofaOverflow.values.joined().contains("id-Web-F"))
    check("zone: a waiting one keeps its desk, whose strip glows orange while it is away",
        routed.desks["id-Web-B"].map { routed.led($0) } == .orange && routed.desks["id-Web-E"].map { routed.led($0) } == .orange)
    var crowd = many
    crowd.append(m("Ops-late", .waiting, ago: 999))
    let crowded = ZonePlan.make(crowd, config: config, memory: [:], sofaSeats: [:])
    check("zone: one without a desk still comes to the boss area when it waits",
        crowded.queue == "id-Ops-late" && crowded.desks["id-Ops-late"] == nil)

    // ── Desks by state ──
    let states = ZonePlan.make([m("Home-busy", .busy), m("Home-news", .unread), m("Home-seen", .seen), m("Home-rest", .resting)], config: config, memory: [:], sofaSeats: [:])
    func look(_ name: String) -> (Bool, ZoneLED)? { states.desks["id-" + name].map { (states.screenOn($0), states.led($0)) } }
    check("zone: at work: screen on, strip ice blue", look("Home-busy").map { $0.0 && $0.1 == .ice } == true)
    check("zone: done and not yet looked at, still at its desk (no sofa in this plan): screen off, strip off", look("Home-news").map { !$0.0 && $0.1 == .off } == true)
    check("zone: looked at or resting: screen off, strip off",
        look("Home-seen").map { !$0.0 && $0.1 == .off } == true && look("Home-rest").map { !$0.0 && $0.1 == .off } == true)
    check("zone: an empty desk is dark", !states.screenOn(ZoneDesk(zone: "Home", index: 12)) && states.led(ZoneDesk(zone: "Home", index: 12)) == .off)

    // ── Check-in (workzone-pending.json) ──
    let pendingJSON = """
        {"sid-new": {"cwd": "/tmp", "title": "x", "zone": null, "suggest": "Home-新名字", "ts": \(Int(t0.timeIntervalSince1970) - 60)},
         "sid-old": {"cwd": "/tmp", "title": "y", "zone": "Ops", "suggest": "Ops-旧", "ts": \(Int(t0.timeIntervalSince1970) - 8 * 24 * 3600)}}
        """
    let pending = ZonePending.parse(Data(pendingJSON.utf8), now: t0)
    check("zone: a pending check-in is read with its suggested name; one older than 7 days is not",
        pending["sid-new"]?.suggest == "Home-新名字" && pending["sid-old"] == nil)
    let pendingFile = dir + "/pending.json"
    try? pendingJSON.write(toFile: pendingFile, atomically: true, encoding: .utf8)
    let pendingBefore = ZonePendingFile.path, zonesBefore = ZoneConfigFile.path
    ZonePendingFile.path = pendingFile
    try? fixture.write(toFile: file, atomically: true, encoding: .utf8)
    ZoneConfigFile.path = file
    // the checks never read the real off-duty roster (the watchdog writes it); the off-duty checks give their own.
    let rosterBefore = ZoneRosterFile.path
    ZoneRosterFile.path = dir + "/no-roster.json"
    ZoneRosterFile.reset()
    defer {
        ZoneRosterFile.path = rosterBefore
        ZoneRosterFile.reset()
    }
    var newcomer = session("sid-new")
    var named = Session(id: "sid-new", pid: 1, project: "p", name: "Home-已改名", status: "idle", since: t0, summary: "")
    newcomer.cwd = "/tmp"
    named.cwd = "/tmp"
    let shows = ZonePendingFile.entry(for: newcomer, config: ZoneConfigFile.current())?.suggest
    let ignored = ZonePendingFile.entry(for: named, config: ZoneConfigFile.current())
    ZonePendingFile.path = pendingBefore
    check("zone: an unzoned session listed as pending shows its suggestion; once its name has a prefix the entry is ignored",
        shows == "Home-新名字" && ignored == nil)

    // ── The art ──
    let scene = ZoneArt.scene
    var perZone: [String: Int] = [:]
    for d in scene?.desks ?? [] { perZone[d.zone, default: 0] += 1 }
    check("zone: the art's points: 49 desks (48 zone desks, 12 in each of the four zones, and the boss's), the queue line, 4 sofas, 4 signs",
        scene?.desks.count == 48 && scene?.bossDesk != nil && perZone.count == 4 && perZone.values.allSatisfy { $0 == 12 } && scene?.queue != nil
            && scene?.queueLine.count == 2
            && scene?.sofas.count == 4 && scene?.signs.count == 4)
    check("zone: the art's rest room has 6 seats in the top-left (4 sofa cushions, 2 armchairs)",
        scene.map { sc in sc.restSeats.count == 6 && sc.restSeats.allSatisfy { $0.x < sc.size.width * 0.3 && $0.y < sc.size.height * 0.3 } } == true)
    // one row along the picture's bottom, Web, Ops, Docs, Infra from left to right, all facing up (towards
    // the islands), read from the points only.
    let facings = scene?.sofas.compactMap(\.facing) ?? []
    check("zone: the 4 sofas stand in one row along the bottom, Web, Ops, Docs, Infra from the left, all facing up (from the points)",
        facings.count == 4 && facings.allSatisfy { $0.dy < -abs($0.dx) * 3 }
            && scene.map { sc in sc.sofas.allSatisfy { $0.seats.count == 3 && $0.seats.allSatisfy { $0.y > sc.size.height * 0.9 } }
                && sc.sofas.sorted { $0.center.x < $1.center.x }.map(\.zone) == ["Web", "Ops", "AI", "Home"] } == true)
    check("zone: each sofa's standing spots are in front of it (along its facing) and in the picture",
        scene.map { sc in sc.sofas.allSatisfy { sofa in
            guard let f = sofa.facing, !sofa.overflow.isEmpty else { return false }
            var mid = CGPoint.zero
            for p in sofa.seats { mid = CGPoint(x: mid.x + p.x / CGFloat(sofa.seats.count), y: mid.y + p.y / CGFloat(sofa.seats.count)) }
            return sofa.overflow.allSatisfy { ($0.x - mid.x) * f.dx + ($0.y - mid.y) * f.dy > 0 && $0.x > 0 && $0.y > 0 && $0.x < sc.size.width && $0.y < sc.size.height }
        } } == true)
    check("zone: check-in is a standing spot with no desk and no sign in the art",
        scene?.visitor != nil && scene?.visitorStanding == true && scene?.visitorSign == nil)
    check("zone: the base picture is there, 2400 × 1600 (3:2), as large as the points say",
        ZoneArt.picture("night_base").map { $0.width == 2400 && $0.height == 1600 && CGFloat($0.width) == scene?.size.width && CGFloat($0.height) == scene?.size.height } == true)
    check("zone: the lit screens and LEDs are there, the same size as the base",
        ["night_screens", "night_leds"].allSatisfy { ZoneArt.picture($0).map { $0.width == 2400 && $0.height == 1600 } == true })
    check("zone: every desk has its LED strip quad from the art", scene.map { !$0.desks.isEmpty && $0.desks.allSatisfy { ($0.led?.count ?? 0) >= 4 } } == true)

    // The line in front of the boss's desk: along the art's queue_line, from its start towards its end.
    if let scene, scene.queueLine.count == 2, let head = scene.queue {
        let n = scene.lineCapacity
        let spots = (0..<n).compactMap { scene.lineSpot($0) }
        let a = scene.queueLine[0], b = scene.queueLine[1], length = hypot(b.x - a.x, b.y - a.y)
        var steps: [CGFloat] = []
        for i in 1..<max(1, spots.count) { steps.append(hypot(spots[i].x - spots[i - 1].x, spots[i].y - spots[i - 1].y)) }
        // On the segment: each spot's distance off the line under a pixel, its run along it within the line's length.
        let onLine = spots.allSatisfy { p in
            let t = ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / (length * length)
            let off = abs((p.x - a.x) * (b.y - a.y) - (p.y - a.y) * (b.x - a.x)) / length
            return off < 1 && t >= -1e-6 && t <= 1 + 1e-6
        }
        // The line ends by the purple island's corner, its last spot 142 px from Docs desk 7's chair: 0.9 of a pet.
        let offDesks = scene.desks.allSatisfy { d in spots.allSatisfy { hypot($0.x - d.seat.x, $0.y - d.seat.y) > scene.petHeight * 0.9 } }
        print(String(format: "      zone line: %d spots, step %.0f–%.0f px over %.0f px, pet %.0f px", n, steps.min() ?? 0, steps.max() ?? 0, length, scene.petHeight))
        check("zone: the line starts in front of the boss's desk (queue_line's start) and runs towards its end, about 170 px apart",
            spots.first == head && head == a && steps.allSatisfy { abs($0 - 170) <= 17 } && onLine && offDesks && b.x > a.x + 600)
        check("zone: as many as fit stand in the line (7–8 along the line), not a fixed six", (7...8).contains(n) && spots.count == n)
        var clear = true
        let wide = scene.petHeight
        for s in scene.sofas { for p in s.seats + s.overflow { for q in spots where hypot(q.x - p.x, q.y - p.y) < wide * 0.5 { clear = false } } }
        if let v = scene.visitor { for q in spots where hypot(q.x - v.x, q.y - v.y) < wide * 0.5 { clear = false } }
        check("zone: the line stands on open floor, off every sofa seat and spot and the check-in spot, all inside the picture",
            clear && spots.allSatisfy { $0.x > 0 && $0.y > 0 && $0.x < scene.size.width && $0.y < scene.size.height })
    } else {
        check("zone: the line needs the art's queue_line", false)
    }
    check("zone: a pet is about 150 px tall in the 2400 px picture", scene.map { abs($0.petHeight - 150) < 150 * 0.1 } == true)
    var said: [String] = []
    let bare = ZoneScene.parse(Data("{\"resolution\": {\"width\": 100, \"height\": 50}}".utf8)) { said.append($0) }
    check("zone: points with only a resolution still load (no desks), and the gap is said once",
        bare?.desks.isEmpty == true && bare?.size == CGSize(width: 100, height: 50) && said.count == 1)
    let newSofa = """
        {"resolution": {"width": 100, "height": 100},
         "sofas": [{"zone": "Ops", "seats": [{"pixel": [10, 10]}, {"pixel": [20, 10]}, {"pixel": [30, 10]}], "overflow": [{"pixel": [20, 30]}]},
                   {"zone": "Home", "seats": [{"pixel": [50, 50]}, {"pixel": [60, 50]}]}],
         "visitor_desk": {"seat": {"pixel": [80, 80]}, "sign": {"face_quad": [[70, 60], [90, 60], [90, 66], [70, 66]]}}}
        """
    let sofaScene = ZoneScene.parse(Data(newSofa.utf8)) { _ in }
    let behind = sofaScene?.sofaOverflow("Home", slot: 0)
    check("zone: a sofa's seats and standing spots come from the art; without spots one stands off the sofa's seats",
        sofaScene?.sofas.first?.seats.count == 3 && sofaScene?.sofaOverflow("Ops", slot: 0) == CGPoint(x: 20, y: 30)
            && behind != nil && behind != CGPoint(x: 50, y: 50) && behind != CGPoint(x: 60, y: 50) && sofaScene?.visitorSign?.count == 4
            && sofaScene?.visitorStanding == false)
    let standing = """
        {"resolution": {"width": 300, "height": 200},
         "boss_desk": {"desk_id": "Boss_1", "chair_seat": {"pixel": [20, 180]}, "queue_spot": {"pixel": [60, 170]}},
         "sofas": [{"zone": "A", "row": 0, "column": 0, "center": {"pixel": [100, 60]}, "seats": [{"pixel": [90, 60]}]},
                   {"zone": "B", "row": 0, "column": 1, "center": {"pixel": [160, 120]}, "seats": [{"pixel": [150, 120]}]}],
         "visitor_desk": {"desk_id": null, "seat": {"pixel": [250, 190]}, "display_name": "报到中", "standing": true}}
        """
    let standScene = ZoneScene.parse(Data(standing.utf8)) { _ in }
    check("zone: a check-in with desk_id null, no sign and standing: true is read as a standing spot",
        standScene?.visitor == CGPoint(x: 250, y: 190) && standScene?.visitorStanding == true && standScene?.visitorSign == nil)
    let lineHead = standScene?.lineSpot(0), lineNext = standScene?.lineSpot(1)
    check("zone: without a queue_line (older art) the line runs from the queue spot towards the middle of the sofas, six long",
        lineHead == CGPoint(x: 60, y: 170) && lineNext.map { $0.x > 60 && $0.y < 170 } == true && standScene?.lineCapacity == 6)
    let lined = ZoneScene.parse(Data(standing.replacingOccurrences(of: "\"visitor_desk\"", with: "\"queue_line\": [{\"pixel\": [40, 190]}, {\"pixel\": [290, 190]}], \"visitor_desk\"").utf8)) { _ in }
    check("zone: with a queue_line the head stands on its start and the line runs straight towards its end",
        lined?.queue == CGPoint(x: 40, y: 190) && lined?.lineSpot(0) == CGPoint(x: 40, y: 190)
            && lined.map { sc in sc.lineSpot(1).map { abs($0.y - 190) < 1e-9 && abs($0.x - 40 - sc.lineStep) < 1e-9 } == true } == true)
    let fit = ZoneFit(scene: CGSize(width: 2400, height: 1600), view: CGSize(width: 1180, height: 790))
    check("zone: the 3:2 scene fills the 1180 × 790 window, centred, cropping almost nothing",
        abs(fit.scale - 790.0 / 1600) < 1e-9 && abs(fit.offset.x - (1180 - 2400 * 790.0 / 1600) / 2) < 1e-9 && fit.offset.y == 0
            && abs(fit.offset.x) < 4 && hypot(fit.back(fit.point(CGPoint(x: 300, y: 200))).x - 300, fit.back(fit.point(CGPoint(x: 300, y: 200))).y - 200) < 1e-6)

    // ── No timers ──
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    var text = ""
    for name in ["ZoneModel.swift", "ZoneView.swift"] {
        text += (try? String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
    check("zone: the zone's sources schedule no Timer, no CVDisplayLink, no TimelineView",
        text.count > 10_000 && !text.contains("Timer") && !text.contains("CVDisplayLink") && !text.contains("TimelineView"))

    // ── The mode ──
    check("zone: the sea room is the last mode and a theme of its own, not offered in the office's theme menu",
        OfficeMode.offered.map(\.title) == ["值班室", "办公室", "海景房"] && OfficeMode.allCases.last == .zone && OfficeTheme.named("海景房").name == "海景房"
            && !OfficeTheme.officeThemes.contains { $0.name == "海景房" })
    for key in ["office", "officeTheme", "officeThemeOffice"] { UserDefaults.standard.removeObject(forKey: key) }
    OfficeMode.zone.choose(store: Store())
    let chosen = (OfficeMode.current, UserDefaults.standard.string(forKey: "officeTheme"))
    OfficeMode.office.choose(store: Store())
    let after = UserDefaults.standard.string(forKey: "officeTheme")
    for key in ["office", "officeTheme", "officeThemeOffice"] { UserDefaults.standard.removeObject(forKey: key) }
    check("zone: choosing the sea room shows it, and the office goes back to the office theme", chosen == (.zone, "海景房") && after == "青灰")

    // ── The room ──
    zoneRoomTests(file: file)
    zoneOfficeTests(config: config)
    zoneWorkTests(config: config)
    zoneSofaTests(config: config)
    zonePlacementTests(config: config)
    zoneArtTests(config: config)
    zoneOpenRoomTests(config: config)
    zoneHitTestTests()
    zoneDragTests()
    zoneFigureSizeTests()
    zoneOutdoorsTests()
    zonePanelFitTests()
    zoneTitlebarMarginTests()
    zoneSpeciesTests()
    zoneBaseFitTests()
    zoneOffDutyTests()
    zoneIslandTests()
    zoneOrcaTests()
    zoneBeachTests()
    ZoneConfigFile.path = zonesBefore
}

/// The room drawn: who stands where, what each desk shows, and that a picture writes no settings.
@MainActor func zoneRoomTests(file: String) {
    guard let scene = ZoneArt.scene, ZoneArt.picture("night_base") != nil else {
        check("zone: the room needs the art", false)
        return
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let store = Store()
    store.readOnly = true
    let now = Date()
    func s(_ name: String, _ status: String, ago: Double, cwd: String = "/tmp") -> Session {
        var made = Session(id: "zid-" + name, pid: 1, project: "p", name: name, status: status, since: now - ago, summary: "要你批准：npm test")
        made.cwd = cwd
        return made
    }
    store.sessions = [s("Home-busy", "busy", ago: 100), s("Home-wait", "waiting", ago: 400), s("Ops-wait", "waiting", ago: 100),
                      s("Ops-news", "idle", ago: 50), s("plain", "busy", ago: 30)]
    for id in ["zid-Home-busy", "zid-Ops-wait"] { store.seen[id] = 0 }
    let size = CGSize(width: 1194, height: 900)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    let plan = view.plan
    let fit = ZoneFit(scene: scene.size, view: size)
    func near(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }
    let busyDesk = plan.desks["zid-Home-busy"]
    let busySeat = busyDesk.flatMap { scene.desk($0)?.seat }.map { fit.point($0) }
    check("zone: a working one stands at its desk's seat", near(view.foot(of: "zid-Home-busy"), busySeat))
    check("zone: the one waiting longest stands on the queue spot", plan.queue == "zid-Home-wait" && near(view.foot(of: "zid-Home-wait"), scene.queue.map { fit.point($0) }))
    check("zone: the next waiting one stands second in the line, not on a sofa", near(view.foot(of: "zid-Ops-wait"), scene.lineSpot(1).map { fit.point($0) }))
    check("zone: the unzoned one stands on the check-in spot, in its idle standing frame although it works",
        near(view.foot(of: "zid-plain"), scene.visitor.map { fit.point($0) }) && view.shownPose(of: "zid-plain") == .standing
            && view.shownPose(of: "zid-Home-busy") == .working)
    check("zone: a figure for each session, no more", view.figureIDs.sorted() == store.sessions.map(\.id).sorted())

    // One more waiting than the line holds (as many as fit along the art's line): the last at its zone's sofa (its
    // first spot); an unzoned one waiting joins the line.
    let queueStore = Store()
    queueStore.readOnly = true
    var queued: [Session] = []
    let room = scene.lineCapacity
    for i in 0..<room { queued.append(s("Ops-w\(i)", "waiting", ago: Double(9000 - i * 100))) }
    queued.insert(s("loose", "waiting", ago: 8950), at: 3)
    queueStore.sessions = queued
    let queueView = ZoneView(frame: CGRect(origin: .zero, size: size))
    queueView.still = true
    queueView.update(queueStore)
    let order = ["zid-Ops-w0", "zid-loose"] + (1..<(room - 1)).map { "zid-Ops-w\($0)" }
    var inLine = queueView.plan.line == order
    for (i, id) in order.enumerated() where !near(queueView.foot(of: id), scene.lineSpot(i).map { fit.point($0) }) { inLine = false }
    check("zone: in the room the line holds as many as fit by how long they wait, the unzoned one among them", inLine && order.count == room)
    let emSpot = scene.sofaOverflow("Ops", slot: 0).map { fit.point($0) }
    check("zone: in the room the one beyond the line stands at its zone's sofa, on its first spot", near(queueView.foot(of: "zid-Ops-w\(room - 1)"), emSpot))
    let heads = queueView.figureIDs.filter { queueView.asks($0) }
    check("zone: only the head of the line shows the ask bubble", heads == ["zid-Ops-w0"])

    // The pets' size: a real view, real pets, measured by their drawn pixels.
    Pets.shared.refresh(force: true)
    OfficePets.shared.synchronous = true
    let sizedStore = Store()
    sizedStore.readOnly = true
    sizedStore.sessions = [s("Home-busy", "busy", ago: 100), s("Web-x", "idle", ago: 120), s("Ops-y", "idle", ago: 130), s("AI-z", "idle", ago: 140),
                           s("plain", "busy", ago: 30)]
    for id in ["zid-Web-x", "zid-Ops-y", "zid-AI-z"] { sizedStore.seen[id] = Date().timeIntervalSince1970 }
    sizedStore.assignPets()
    let sized = ZoneView(frame: CGRect(origin: .zero, size: size))
    sized.still = true
    sized.update(sizedStore)
    // Opaque rows of each drawn pet, in the view's points, then in the picture's pixels.
    var tall: [CGFloat] = [], others: [CGFloat] = []
    var sameFactor = true
    for id in sized.figureIDs {
        guard let drawn = sized.sprite(of: id) else { continue }
        let px = Pixels(drawn.image)
        var top = px.height, bottom = -1, left = px.width, right = -1
        for y in 0..<px.height {
            for x in 0..<px.width where px.data[(y * px.width + x) * 4 + 3] > 16 {
                top = min(top, y)
                bottom = max(bottom, y)
                left = min(left, x)
                right = max(right, x)
            }
        }
        guard bottom >= top else { continue }
        // a pet is sized by its idle frame's opaque box, max(height, width × 0.85), so wide pets are not huge.
        let k = drawn.frame.height / CGFloat(px.height) / fit.scale
        let height = max(CGFloat(bottom - top + 1), CGFloat(right - left + 1) * 0.85) * k
        if let factor = sized.petFactor(of: id), abs(factor - drawn.frame.height / CGFloat(px.height)) > 0.001 { sameFactor = false }
        if sized.petFactor(of: id) == nil { sameFactor = false }
        // The size is set by the idle standing frame; other poses (typing, a hand up) may be a little shorter or taller.
        if sized.shownPose(of: id) == .standing { tall.append(height) } else { others.append(height) }
    }
    OfficePets.shared.synchronous = false
    if tall.isEmpty {
        skipped("no pet frames", "zone: a pet stands about 150 px tall in the 2400 px picture")
    } else {
        print(String(format: "      zone pets: standing %.0f–%.0f px, other poses %.0f–%.0f px tall in the picture", tall.min() ?? 0, tall.max() ?? 0,
                     others.min() ?? 0, others.max() ?? 0))
        check("zone: a pet's idle box, max(height, width × 0.85), is about 150 px in the 2400 px picture (±10%), measured in a real view",
            tall.allSatisfy { abs($0 - 150) <= 15 })
        check("zone: every pose of a pet is drawn at the factor its idle frame set", sameFactor && !others.isEmpty)
    }

    // What the desks show, in the layers and in the picture.
    let waitDesk = plan.desks["zid-Home-wait"]
    check("zone: the layers say it: busy desk lit and ice blue, the waiting one's desk orange",
        busyDesk.map { view.screenShown($0) && view.ledColor($0) == .ice } == true && waitDesk.map { view.ledColor($0) == .orange } == true)
    let lit = view.image()
    let empty = Store()
    empty.readOnly = true
    let dark = ZoneView(frame: CGRect(origin: .zero, size: size))
    dark.still = true
    dark.update(empty)
    let unlit = dark.image()
    func brightness(_ image: CGImage?, _ desk: ZoneDesk?) -> Double {
        guard let image, let desk, let quad = scene.desk(desk)?.screen, !quad.isEmpty else { return -1 }
        let px = Pixels(image), k = CGFloat(image.width) / size.width
        var sum = 0.0, n = 0
        var middle = CGPoint.zero
        for p in quad { middle = CGPoint(x: middle.x + p.x / CGFloat(quad.count), y: middle.y + p.y / CGFloat(quad.count)) }
        for p in quad + [middle] {
            let c = fit.point(CGPoint(x: middle.x + (p.x - middle.x) * 0.5, y: middle.y + (p.y - middle.y) * 0.5))
            let x = Int(c.x * k), y = Int(c.y * k)
            guard x >= 0, y >= 0, x < px.width, y < px.height else { continue }
            let i = (y * px.width + x) * 4
            sum += Double(px.data[i]) + Double(px.data[i + 1]) + Double(px.data[i + 2])
            n += 1
        }
        return n > 0 ? sum / Double(n) : -1
    }
    let on = brightness(lit, busyDesk), off = brightness(unlit, busyDesk)
    print(String(format: "      zone screen: lit %.0f, dark %.0f", on, off))
    check("zone: in the picture the working one's screen is clearly brighter than the same screen in an empty room",
        on > 0 && off >= 0 && on > off + 60)

    // A picture writes no settings.
    let still = zoneStill(store, size: size)
    check("zone: the still is drawn and writes no desk memory to the settings",
        still != nil && UserDefaults.standard.object(forKey: ZoneMemory.key) == nil && !ZoneMemory.remembered.isEmpty)
    ZoneMemory.remembered = [:]
}

/// the office's behaviours in the zone: visits, the spotlight, the awaiting-reply pin and the menu, the rest room, the card;
/// and the line's spacing and plates above every pet.
@MainActor func zoneOfficeTests(config: ZoneConfig) {
    guard let scene = ZoneArt.scene else {
        check("zone: the office's behaviours need the art", false)
        return
    }
    let now = Date()
    func s(_ name: String, _ status: String, ago: Double, cwd: String = "/tmp") -> Session {
        var made = Session(id: "zid-" + name, pid: 1, project: "p", name: name, status: status, since: now - ago, summary: "要你批准：npm test")
        made.cwd = cwd
        return made
    }
    func near(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }
    let size = CGSize(width: 1194, height: 900)
    let fit = ZoneFit(scene: scene.size, view: size)
    func room(_ store: Store) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        return view
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]

    // ── Rest room: only for those with no desk; nobody goes there for being old or put away ──
    let t0 = Date()
    func m(_ name: String, _ state: ZoneState, ago: Double) -> ZoneMember {
        ZoneMember(id: "id-" + name, name: name, zone: config.prefix(of: name), state: state, since: t0 - ago)
    }
    var resting: [ZoneMember] = []
    for i in 0..<8 { resting.append(m("Home-r\(i)", .resting, ago: Double(30000 + i * 100))) }
    let restPlan = ZonePlan.make(resting + [m("Home-busy", .busy, ago: 10)], config: config, memory: [:], sofaSeats: [:], restSeats: 6)
    check("zone: long-finished (resting) ones stay at their own desks, dark; the rest room stays empty",
        restPlan.rest.isEmpty && restPlan.restOverflow.isEmpty && resting.allSatisfy { r in restPlan.desks[r.id].map { restPlan.place[r.id] == .desk($0) && !restPlan.screenOn($0) && restPlan.led($0) == .off } == true })
    var crowd: [ZoneMember] = []
    for i in 0..<19 { crowd.append(m("Home-c\(i)", .seen, ago: Double(100 + i))) }
    let crowdPlan = ZonePlan.make(crowd, config: config, memory: [:], sofaSeats: [:], restSeats: 6)
    let noDesk = (11..<19).map { "id-Home-c\($0)" }
    check("zone: with twelve owners in a zone the rest have no desk and go to the rest room: six seats, the rest on its +N",
        crowdPlan.desks.count == 11 && Set(crowdPlan.rest + crowdPlan.restOverflow) == Set(noDesk) && crowdPlan.rest.count == 6 && crowdPlan.restOverflow.count == 2
            && crowdPlan.overflow["Home"].map(Set.init) == Set(noDesk))
    let unzonedRest = ZonePlan.make([ZoneMember(id: "id-u", name: "plain-u", zone: nil, state: .resting, since: t0 - 30000),
                                     ZoneMember(id: "id-v", name: "plain-v", zone: nil, state: .busy, since: t0)],
                                    config: config, memory: [:], sofaSeats: [:], restSeats: 6)
    check("zone: unzoned ones never rest: one on the check-in spot, the other listed on its label",
        unzonedRest.rest.isEmpty && unzonedRest.visitor != nil && unzonedRest.visitorList.count == 1)

    // In the room: seventeen in one zone, eight with no desk: six seated, a "+2" pill, the floor or the pill opens their list.
    let restStore = Store()
    restStore.readOnly = true
    var rs: [Session] = []
    for i in 0..<19 { rs.append(s("Home-c\(i)", "idle", ago: Double(8 * 3600 + i * 100))) }
    restStore.sessions = rs
    for x in rs { restStore.seen[x.id] = now.timeIntervalSince1970 }
    let restView = room(restStore)
    let seatedIDs = restView.plan.rest
    var seated = scene.restSeats.count == 6 && seatedIDs.count == 6
    for (i, id) in seatedIDs.enumerated() where i < scene.restSeats.count && !near(restView.foot(of: id), fit.point(scene.restSeats[i])) { seated = false }
    check("zone: in the room six of those with no desk sit on the rest room's seats", seated)
    check("zone: those beyond the seats are not drawn; a \"+2\" pill sits at the rest room",
        restView.plan.restOverflow.count == 2 && restView.plan.restOverflow.allSatisfy { !restView.figureIDs.contains($0) } && restView.restExtra == 2)
    let floor = scene.restArea.map { fit.point(CGPoint(x: $0.midX, y: $0.maxY - 4)) }
    let clicked = floor.flatMap { restView.target(at: $0) }
    check("zone: a click on the rest room's floor opens its list", clicked == .list(ZoneUI.restKey))
    let rows = ZoneListCard.rows(ZoneUI.restKey, store: restStore)
    check("zone: the rest room's list holds all eight with no desk, rows going to their sessions",
        rows.rows.count == 8 && Set(rows.rows.map(\.0.id)) == Set(restView.plan.rest + restView.plan.restOverflow) && rows.title.hasPrefix("休息室"))
    check("zone: the ones with desks sit at them, dark, however long ago they finished",
        restView.plan.desks.keys.allSatisfy { id in restView.plan.desks[id].map { !restView.screenShown($0) && restView.ledColor($0) == .off } == true }
            && restView.plan.desks.count == 11)

    // ── Visits: the pure rule, then the room ──
    var talk = OfficeRounds()
    talk.talk("A", "B", opened: now - 5, last: now - 5)
    let homes = ["A": CGPoint(x: 100, y: 100), "B": CGPoint(x: 600, y: 300)]
    let first = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds,
                                previous: ZoneVisits(), now: now, pace: 70)
    check("zone: what is going on at the first look sends nobody", first.visits.isEmpty && first.looked)
    var looked = ZoneVisits()
    looked.looked = true
    let started = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds,
                                  previous: looked, now: now, pace: 70)
    check("zone: a round opening sends its opener to the other's desk", started.visits["A"]?.host == "B" && started.visits["B"] == nil)
    let carried = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds,
                                  previous: started, now: now + 5, pace: 70)
    let ended = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds,
                                previous: started, now: (started.visits["A"]?.until ?? now) + 1, pace: 70)
    let again = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds,
                                previous: ended, now: (started.visits["A"]?.until ?? now) + 2, pace: 70)
    check("zone: the visit lasts its while, then ends, and the same round sends nobody again",
        carried.visits["A"]?.host == "B" && ended.visits.isEmpty && again.visits.isEmpty)
    let waitingOpener = ZoneVisits.next(homes: homes, free: ["B"], open: ["A", "B"], peers: talk.peers, rounds: talk.rounds,
                                        previous: looked, now: now, pace: 70)
    let queuedHost = ZoneVisits.next(homes: homes, free: ["A", "B"], open: ["A"], peers: talk.peers, rounds: talk.rounds,
                                     previous: looked, now: now, pace: 70)
    check("zone: one waiting for you does not go, and nobody visits one in the line", waitingOpener.visits.isEmpty && queuedHost.visits.isEmpty)

    let visitStore = Store()
    visitStore.readOnly = true
    visitStore.sessions = [s("Home-a", "busy", ago: 30), s("Ops-b", "busy", ago: 40)]
    let visitView = room(visitStore)
    let home = visitView.foot(of: "zid-Home-a")
    let hostFoot = visitView.foot(of: "zid-Ops-b")
    visitView.visit("zid-Home-a", to: "zid-Ops-b", words: "测试一下端口", until: now + 30)
    visitView.update(visitStore)
    let there = visitView.foot(of: "zid-Home-a")
    let besideHost = visitView.plan.desks["zid-Ops-b"].flatMap { scene.desk($0)?.seat }.map { fit.point(scene.visitSpot($0)) }
    check("zone: in the room the visitor stands beside the other's desk and says something there",
        near(there, besideHost) && !near(there, home) && visitView.says("zid-Home-a") && near(visitView.foot(of: "zid-Ops-b"), hostFoot))
    visitView.visit("zid-Home-a", to: "zid-Ops-b", words: "", until: now - 1)
    visitView.update(visitStore)
    check("zone: once the visit is over the visitor is back at its own desk, saying nothing",
        near(visitView.foot(of: "zid-Home-a"), home) && !visitView.says("zid-Home-a"))

    // ── Spotlight ──
    let wasLight = UserDefaults.standard.object(forKey: "officeSpotlight")
    setOfficeSpotlight(true)
    visitStore.focused = "zid-Home-a"
    visitStore.orcaInFront = true
    visitView.update(visitStore)
    let litA = visitView.lit("zid-Home-a"), litB0 = visitView.lit("zid-Ops-b")
    // In the picture: the floor round its feet is brighter with the light than without.
    func glow(_ image: CGImage?) -> Double {
        guard let image, let foot = visitView.foot(of: "zid-Home-a") else { return -1 }
        let px = Pixels(image), k = CGFloat(image.width) / size.width
        var sum = 0.0
        // the disco light's pool and cone are the office's, as wide as 1.8 pets at the feet: sampled beside the legs.
        for (dx, dy) in [(-0.4, -0.15), (0.4, -0.15), (-0.3, -0.05), (0.3, -0.05)] as [(CGFloat, CGFloat)] {
            let x = Int((foot.x + dx * scene.petHeight * fit.scale) * k), y = Int((foot.y + dy * scene.petHeight * fit.scale) * k)
            guard x >= 0, y >= 0, x < px.width, y < px.height else { continue }
            let i = (y * px.width + x) * 4
            sum += Double(px.data[i]) + Double(px.data[i + 1]) + Double(px.data[i + 2])
        }
        return sum
    }
    let withLight = glow(visitView.image())
    visitStore.focused = nil
    visitView.update(visitStore)
    let withoutLight = glow(visitView.image())
    visitStore.focused = "zid-Home-a"
    visitView.update(visitStore)
    print(String(format: "      zone light: floor %.0f with, %.0f without", withLight, withoutLight))
    check("zone: in the picture the spotlight brightens the floor round the focused one's feet", withLight > withoutLight + 40)
    visitStore.focused = "zid-Ops-b"
    visitStore.orcaInFront = false
    visitView.update(visitStore)
    let litB = visitView.lit("zid-Ops-b"), litA1 = visitView.lit("zid-Home-a")
    setOfficeSpotlight(false)
    visitView.update(visitStore)
    let litOff = visitView.lit("zid-Ops-b")
    if let wasLight { UserDefaults.standard.set(wasLight, forKey: "officeSpotlight") } else { UserDefaults.standard.removeObject(forKey: "officeSpotlight") }
    visitStore.focused = nil
    check("zone: the spotlight follows the session focused in Orca, half as strong while Orca is behind, off when switched off",
        litA == 1 && litB0 == 0 && litB == 0.5 && litA1 == 0 && litOff == 0)

    // ── awaiting-reply pin and the menu ──
    let pinStore = Store()
    pinStore.readOnly = true
    pinStore.sessions = [s("Home-news", "idle", ago: 60), s("Home-work", "busy", ago: 60), s("Home-old", "idle", ago: 8 * 3600)]
    pinStore.seen["zid-Home-old"] = now.timeIntervalSince1970
    pinStore.pinned = ["zid-Home-news", "zid-Home-work"]
    let pinView = room(pinStore)
    check("zone: a pinned finished one shows the pin on its plate; a working one (whose pin means nothing) does not",
        pinView.pinShown("zid-Home-news") && !pinView.pinShown("zid-Home-work") && !pinView.pinShown("zid-Home-old"))
    pinStore.pinned = []
    pinView.update(pinStore)
    check("zone: unpinned, the plate loses its pin", !pinView.pinShown("zid-Home-news"))
    pinStore.pinned = ["zid-Home-news"]
    func menu(_ id: String) -> [String: Bool] {
        guard let x = pinStore.sessions.first(where: { $0.id == id }) else { return [:] }
        var result: [String: Bool] = [:]
        for line in sessionMenu(pinStore, x) where line.action != .separator { result[line.title] = line.enabled }
        return result
    }
    let pinnedMenu = menu("zid-Home-news"), workMenu = menu("zid-Home-work"), oldMenu = menu("zid-Home-old")
    check("zone: the menu is the office's, greyed as there: pinned → unpin awaiting-reply, no go to desk; working → only jump and folder; resting → no move to rest room",
        pinnedMenu["取消待回复"] == true && pinnedMenu["转到工位（算看过）"] == false && pinnedMenu["转到休息区（不需要了）"] == true
            && workMenu["跳到会话"] == true && workMenu["标记待回复（留在「有话说」）"] == false && workMenu["转到休息区（不需要了）"] == false
            && oldMenu["转到休息区（不需要了）"] == false && oldMenu["转到工位（算看过）"] == true)
    let pinFoot = pinView.foot(of: "zid-Home-news").map { CGPoint(x: $0.x, y: $0.y - 10) }
    check("zone: a right-click on a figure finds its session, so the menu opens for it",
        pinFoot.flatMap { pinView.card(at: $0) } == "zid-Home-news")

    // ── Card ──
    let cardStore = Store()
    cardStore.readOnly = true
    var worker = s("Home-work", "busy", ago: 60)
    worker.cwd = "/tmp/proj"
    cardStore.sessions = [worker]
    cardStore.agents = ["zid-Home-work": [OfficeSubagents.Agent(description: "查日志", model: "claude-sonnet-5")]]
    let lines = ZoneCard.lines(worker, store: cardStore)
    check("zone: the hover card says its progress, its sub-agent rows and its folder",
        lines.contains("要你批准：npm test") && lines.contains { $0.hasPrefix("子代理") && $0.contains("查日志") } && lines.contains("目录：/tmp/proj"))

    // ── The line's plates, above every pet and clear of each other ──
    let lineStore = Store()
    lineStore.readOnly = true
    var queued: [Session] = []
    for i in 0..<6 { queued.append(s("Ops-岛-风铃同步\(i)", "waiting", ago: Double(900 - i * 100))) }
    lineStore.sessions = queued
    let lineView = room(lineStore)
    let plates = queued.compactMap { lineView.plateFrame(of: $0.id) }
    var apart = plates.count == 6
    for i in 0..<plates.count { for j in (i + 1)..<plates.count where plates[i].intersects(plates[j]) { apart = false } }
    check("zone: in a line of six no name plate overlaps another", apart)
    check("zone: the plates are drawn in a layer above every pet", lineView.platesAbovePets)
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// the working parts wired into the room (code screen, breathing LED, tool badge, sub-agents' figures), the data they
/// need (a busy session's tool, a sub-agent's kind), the disco light, the check-in label, where a visitor stands, running walks
/// and the poses on arrival.
@MainActor func zoneWorkTests(config: ZoneConfig) {
    guard let scene = ZoneArt.scene else {
        check("zone: the working parts need the art", false)
        return
    }
    let now = Date()
    func s(_ name: String, _ status: String, ago: Double, tool: String = "") -> Session {
        var made = Session(id: "zid-" + name, pid: 1, project: "p", name: name, status: status, since: now - ago, summary: "在做事")
        made.cwd = "/tmp"
        made.tool = tool
        return made
    }
    let size = CGSize(width: 1194, height: 900)
    let fit = ZoneFit(scene: scene.size, view: size)
    func room(_ store: Store, still: Bool = true) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = still
        view.update(store)
        return view
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]

    // ── Data: a busy session's tool, from its last tool call with no result; a sub-agent's kind, from its meta file ──
    let bench = RestartBench("z3c-tool")
    let files = FileManager.default
    let use = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"看看"},{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"x"}}]}}"#
    let result = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    func transcript(_ id: String, _ lines: [String]) {
        let path = bench.dir + "/" + id + ".jsonl"
        files.createFile(atPath: path, contents: Data(lines.map { $0 + "\n" }.joined().utf8))
        bench.loader.remember(transcript: path, for: id)
    }
    bench.open("busy-in", "busy", since: now - 30)
    bench.open("busy-out", "busy", since: now - 30)
    bench.open("wait-in", "waiting", since: now - 30)
    transcript("busy-in", [use])
    transcript("busy-out", [use, result])
    transcript("wait-in", [use])
    let loaded = Dictionary(bench.loader.load().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    check("zone: a busy session's tool is its last tool call with no result yet; none once the result is in; a waiting one has none",
        loaded["busy-in"]?.tool == "Grep" && loaded["busy-out"]?.tool == "" && loaded["wait-in"]?.tool == ""
            && loaded["wait-in"]?.summary.contains("Grep") == true)
    try? files.removeItem(atPath: bench.dir)
    let metaPath = NSTemporaryDirectory() + "z3c-meta-\(getpid()).meta.json"
    files.createFile(atPath: metaPath, contents: Data(#"{"agentType":"codex:codex-rescue","description":"写脚本","model":"inherit"}"#.utf8))
    let asked = OfficeSubagents.asked(at: metaPath)
    try? files.removeItem(atPath: metaPath)
    check("zone: a sub-agent's kind is read from its meta file's agentType, beside what it was asked",
        asked?.type == "codex:codex-rescue" && asked?.description == "写脚本" && asked?.model == "")

    // ── The room: busy desks show code, breathe and wear the badge; others do not ──
    Pets.shared.refresh(force: true)
    OfficePets.shared.synchronous = true
    let store = Store()
    store.readOnly = true
    store.sessions = [s("Home-run", "busy", ago: 60, tool: "Bash"), s("Home-read", "busy", ago: 70, tool: "Read"), s("Ops-ask", "waiting", ago: 80),
                      s("Web-done", "idle", ago: 90)]
    store.seen["zid-Web-done"] = now.timeIntervalSince1970
    store.assignPets()
    store.agents = ["zid-Home-run": [OfficeSubagents.Agent(description: "查日志", model: "claude-sonnet-5", agentType: "Explore"),
                                   OfficeSubagents.Agent(description: "写脚本", model: "", agentType: "codex:codex-rescue"),
                                   OfficeSubagents.Agent(description: "改样式", model: "claude-opus-5-5", agentType: "general-purpose")]]
    let live = room(store, still: false)
    let run = live.plan.desks["zid-Home-run"], read = live.plan.desks["zid-Home-read"], idleDesk = live.plan.desks["zid-Web-done"]
    check("zone: a code screen shows only on the busy desks, and the LED breathes there (CA), steady or off elsewhere",
        run.map { live.codeShown($0) && live.ledBreathes($0) } == true && read.map { live.codeShown($0) && live.ledBreathes($0) } == true
            && live.codeScreenCount == 2 && idleDesk.map { !live.codeShown($0) && !live.ledBreathes($0) } == true
            && run.flatMap { live.codeLayer($0) }.map { ($0.sublayers?.first?.sublayers?.first?.animationKeys() ?? []).contains(ZoneCodeScreen.key) } == true)
    let runFoot = live.foot(of: "zid-Home-run")
    let badge = live.badge(of: "zid-Home-run")
    check("zone: a busy one wears its tool's badge over its head (terminal for Bash, magnifier for Read); waiting and idle ones none",
        badge?.family == .terminal && live.badge(of: "zid-Home-read")?.family == .magnifier && live.badge(of: "zid-Ops-ask") == nil
            && live.badge(of: "zid-Web-done") == nil && runFoot.map { badge!.frame.maxY < $0.y - scene.petHeight * fit.scale * 0.6 } == true)
    store.sessions[0].tool = "Edit"
    live.update(store)
    check("zone: the badge changes when the tool does", live.badge(of: "zid-Home-run")?.family == .pencil)
    store.sessions[0].tool = "Bash"
    live.update(store)
    // The sub-agents: three (the helpers' pets, the flame unless set), on the near edge, clear of the screen and of each other.
    let minis = live.agentFigures(of: "zid-Home-run")
    let deskArt = run.flatMap { scene.desk($0) }
    let quad = deskArt?.screen.map(fit.point) ?? []
    let figs = minis.filter { $0.name != "more" }
    let names = figs.map(\.name).sorted()
    let expected = Array([ZoneSubagentFigures.claudePet, ZoneSubagentFigures.codexPet, ZoneSubagentFigures.claudePet].prefix(figs.count)).sorted()
    let pillShown = minis.contains { $0.name == "more" }
    let readable = figs.allSatisfy { $0.frame.height > 0 } && (figs.count == 3 || pillShown)
    var apart = true
    // the figures are walkers now (a layer of the pet's whole cell each): what they cover is what is drawn of the cell.
    let inked = minis.compactMap { m -> CGRect? in
        guard let idle = OfficePets.shared.frame(m.name, row: 0, column: 0) else { return nil }
        let kx = m.frame.width / CGFloat(idle.image.width), ky = m.frame.height / CGFloat(idle.image.height)
        return CGRect(x: m.frame.minX + CGFloat(idle.left) * kx, y: m.frame.minY + CGFloat(idle.top) * ky, width: CGFloat(idle.wide) * kx, height: CGFloat(idle.tall) * ky)
    }
    let clearOfScreen = ZoneSubagentFigures.hidden(quad, by: inked) <= 0.25
    let near = deskArt?.near.map { (fit.point($0.0), fit.point($0.1)) }
    let feetNear = near.map { e in figs.allSatisfy { m in abs(m.frame.maxY - (e.0.y + (e.1.y - e.0.y) * (m.frame.midX - e.0.x) / max(1, e.1.x - e.0.x))) < scene.petHeight * fit.scale * 0.25 } } ?? false
    let placed = ZoneSubagentFigures.place(store.agents["zid-Home-run"]!.map { ZoneSubagentFigures.Member(agent: $0, type: $0.agentType) },
                                           from: CGPoint(x: 0, y: 0), to: CGPoint(x: 1000, y: 0), petHeight: 100, scale: 1) {
        OfficePets.shared.frame($0, row: 0, column: 0)
    }
    for i in placed.indices { for j in placed.indices where j > i && placed[i].drawn.intersects(placed[j].drawn) { apart = false } }
    check("zone: a busy one's sub-agents stand on its desk's near edge as mini figures (Codex → its own helper pet)",
        !figs.isEmpty && names == expected && readable && feetNear && apart && !quad.isEmpty)
    check("zone: ...clear of the screen: at rest they cover at most 25% of it (now \(String(format: "%.2f", ZoneSubagentFigures.hidden(quad, by: inked))), helpers \(names))",
        clearOfScreen)
    print("      zone minis cover \(ZoneSubagentFigures.hidden(quad, by: inked)) of the screen at rest")
    print("      zone minis: \(figs.count) figures\(pillShown ? " and a pill" : ""), \(figs.map { String(format: "%.0f", $0.frame.height / fit.scale) }) px tall in the picture")
    store.agents = [:]
    live.update(store)
    check("zone: with no sub-agents running the mini figures go", live.agentFigures(of: "zid-Home-run").isEmpty)

    // ── Poses: the office's loops ──
    let waitLoop = live.spriteAnimation(of: "zid-Ops-ask", "loop") as? CAKeyframeAnimation
    let workLoop = live.spriteAnimation(of: "zid-Home-run", "loop") as? CAKeyframeAnimation
    // NUDGE: one waiting in the line does not play the row-6 loop: it stands on its first frame and knocks (WaitingNudge).
    check("zone: one waiting in the line stands still on row 6's first frame and knocks (no waiting loop) and a busy one works (its working loop)",
        live.shownPose(of: "zid-Ops-ask") == .waiting && waitLoop == nil && Pose.waiting.sheet.frames == 1
            && live.spriteAnimation(of: "zid-Ops-ask", WaitingNudge.tiltKey) != nil
            && live.shownPose(of: "zid-Home-run") == .working && (workLoop?.values?.count ?? 0) == Pose.working.sheet.frames)
    store.celebrating["zid-Web-done"] = now + 1.8
    store.seen["zid-Web-done"] = nil
    store.sessions[3] = s("Web-done", "idle", ago: 1)
    live.update(store)
    let jumped = live.shownPose(of: "zid-Web-done")
    store.celebrating["zid-Web-done"] = now - 1
    live.update(store)
    check("zone: one just done jumps, then waves, as in the office", jumped == .celebrating && live.shownPose(of: "zid-Web-done") == .waving)

    // ── Walking: running frames by direction, the pose on arrival ──
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = live
    store.sessions[1] = s("Home-read", "waiting", ago: 1)
    live.update(store)
    let steps = live.spriteAnimation(of: "zid-Home-read", "steps") as? CAKeyframeAnimation
    let pet = store.displayPets["zid-Home-read"] ?? ""
    let rightRow = (0..<8).compactMap { OfficePets.shared.runFrame(pet, facing: ZoneWalk.right, column: $0)?.image }
    let leftRow = (0..<8).compactMap { OfficePets.shared.runFrame(pet, facing: ZoneWalk.left, column: $0)?.image }
    let fromRows = (steps?.values ?? []).allSatisfy { v in (rightRow + leftRow).contains { $0 === (v as AnyObject) } }
    check("zone: walking to the line it runs in its sheet's running frames (CA keyframes), and stands knocking there on arrival (NUDGE: no waiting loop)",
        steps != nil && !(rightRow + leftRow).isEmpty && fromRows && steps?.calculationMode == .discrete
            && live.shownPose(of: "zid-Home-read") == .waiting && live.spriteAnimation(of: "zid-Home-read", "loop") == nil
            && live.spriteAnimation(of: "zid-Home-read", WaitingNudge.tiltKey) != nil)
    window.contentView = nil

    // ── The disco light on the focused one ──
    let wasLight = UserDefaults.standard.object(forKey: "officeSpotlight")
    setOfficeSpotlight(true)
    store.focused = "zid-Home-run"
    store.orcaInFront = true
    let lit = room(store)
    let beam = lit.beam(of: "zid-Home-run")
    check("zone: the focused one gets the office's disco light: mirror ball, lasers and spots over its cone",
        beam.map { ZoneDisco.parts($0, "ball").count == 1 && ZoneDisco.parts($0, "laser").count == 3 && ZoneDisco.parts($0, "spot").count == 5 } == true
            && lit.lit("zid-Home-run") == 1)
    if let wasLight { UserDefaults.standard.set(wasLight, forKey: "officeSpotlight") } else { UserDefaults.standard.removeObject(forKey: "officeSpotlight") }
    store.focused = nil

    // ── check-in shows only while someone is checking in ──
    check("zone: with nobody checking in, no check-in label stands on the floor", !lit.checkInShown)
    let checkIn = Store()
    checkIn.readOnly = true
    checkIn.sessions = [s("plain-new", "busy", ago: 10)]
    check("zone: the check-in label shows while one is checking in", room(checkIn).checkInShown)

    // ── Where a visitor stands ──
    var offDesks = true, offHost = true
    for desk in scene.desks {
        let spot = scene.visitSpot(desk.seat)
        if scene.desks.contains(where: { $0.covers(spot) }) { offDesks = false }
        if hypot(spot.x - desk.seat.x, spot.y - desk.seat.y) < scene.petHeight * 0.45 { offHost = false }
    }
    let one = scene.desks.first.map { scene.visitSpot($0.seat) }, two = scene.desks.first.map { scene.visitSpot($0.seat, taken: [one!]) }
    check("zone: a visitor stands on the floor beside its host, never on a desk, a pet's width on along the aisle when the spot is taken",
        offDesks && offHost && scene.desks.allSatisfy { !$0.footprint.isEmpty && $0.stand != nil }
            && one != nil && two != nil && hypot(one!.x - two!.x, one!.y - two!.y) > scene.petHeight * 0.6)
    let visitStore = Store()
    visitStore.readOnly = true
    visitStore.sessions = [s("Home-a", "busy", ago: 30), s("Ops-b", "busy", ago: 40)]
    OfficePets.shared.synchronous = true
    visitStore.assignPets()
    let visitView = room(visitStore)
    visitView.visit("zid-Home-a", to: "zid-Ops-b", words: "测试一下端口", until: now + 30)
    visitView.update(visitStore)
    let at = visitView.foot(of: "zid-Home-a").map { fit.back($0) }
    check("zone: in the room the visitor's feet are on the floor, off every desk",
        at.map { p in !scene.desks.contains { $0.covers(p) } } == true && visitView.says("zid-Home-a"))
    let hostX = visitView.foot(of: "zid-Ops-b")?.x ?? 0, guestX = visitView.foot(of: "zid-Home-a")?.x ?? 0
    let guestPet = visitStore.displayPets["zid-Home-a"] ?? ""
    let turned = visitView.facing(of: "zid-Home-a").flatMap { OfficePets.shared.runFrame(guestPet, facing: $0, column: 0)?.image }  // by the facing table
    let shownFrame = visitView.sprite(of: "zid-Home-a")?.image
    print("      zone visit: host x \(Int(hostX)), guest x \(Int(guestX)), facing \(visitView.facing(of: "zid-Home-a") ?? 0), pet \(guestPet), shown is turned frame: \(turned != nil && shownFrame === turned)")
    check("zone: the visitor turns to its host (its running frame that way, held)",
        visitView.facing(of: "zid-Home-a") == (hostX >= guestX ? ZoneWalk.right : ZoneWalk.left) && visitView.facing(of: "zid-Ops-b") == nil
            && (guestPet.isEmpty || (turned != nil && shownFrame === turned)))
    OfficePets.shared.synchronous = false
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// the finished ones not yet looked at (has-news, pinned ones too) walk to their own zone's sofa and sit there in finish
/// order, the rest standing at its spots; the waiting ones beyond the line take only the spots; the desks stay theirs.
@MainActor func zoneSofaTests(config: ZoneConfig) {
    let t0 = Date()
    func m(_ name: String, _ state: ZoneState = .seen, ago: Double = 100) -> ZoneMember {
        ZoneMember(id: "id-" + name, name: name, zone: config.prefix(of: name), state: state, since: t0 - ago)
    }
    let seats = ["Web": 3, "Ops": 3, "AI": 3, "Home": 3], spots = ["Web": 3, "Ops": 3, "AI": 3, "Home": 3]
    func ids(_ names: [String]) -> [String] { names.map { "id-" + $0 } }

    // ── The plan ──
    let news = [m("Web-n3", .unread, ago: 300), m("Web-n1", .unread, ago: 500), m("Ops-n1", .unread, ago: 50), m("Web-n2", .unread, ago: 400),
                m("Web-n4", .unread, ago: 200), m("Web-n5", .unread, ago: 100), m("Web-busy", .busy)]
    let p = ZonePlan.make(news.shuffled(), config: config, memory: [:], sofaSeats: seats, sofaSpots: spots)
    check("zone: the finished ones not looked at sit on their own zone's sofa, first finished first",
        p.sofa["Web"] == ids(["Web-n1", "Web-n2", "Web-n3"]) && p.sofa["Ops"] == ids(["Ops-n1"]) && p.sofa["Home"] == nil)
    check("zone: more than its seats: the next stand at that sofa's spots",
        p.sofaOverflow["Web"] == ids(["Web-n4", "Web-n5"]) && p.sofaOverflow["Ops"] == nil)
    let away = ["Web-n1", "Web-n4", "Ops-n1"].compactMap { p.desks["id-" + $0] }
    check("zone: one on the sofa keeps its desk, screen and strip off there",
        away.count == 3 && away.allSatisfy { !p.screenOn($0) && p.led($0) == .off } && p.desks["id-Web-busy"].map { p.screenOn($0) && p.led($0) == .ice } == true)

    var many: [ZoneMember] = []
    for i in 0..<7 { many.append(m("Ops-u\(i)", .unread, ago: Double(900 - i * 10))) }  // desks 2–8 of 2–12
    let full = ZonePlan.make(many, config: config, memory: [:], sofaSeats: seats, sofaSpots: spots)
    let left = ["Ops-u6"]
    check("zone: beyond the seats and the spots they stay at their desks, screen and strip off",
        full.sofa["Ops"] == ids(["Ops-u0", "Ops-u1", "Ops-u2"]) && full.sofaOverflow["Ops"] == ids(["Ops-u3", "Ops-u4", "Ops-u5"])
            && left.allSatisfy { n in full.desks["id-" + n].map { !full.screenOn($0) && full.led($0) == .off && full.place["id-" + n] == .desk($0) } == true })

    // Waiting: six in the line; after them the sofa's spots, never its seats; then their desks, strip orange.
    var crowd: [ZoneMember] = []
    for i in 0..<6 { crowd.append(m("Home-w\(i)", .waiting, ago: Double(2000 - i * 10))) }
    crowd += [m("Web-w7", .waiting, ago: 900), m("Web-w8", .waiting, ago: 800), m("Web-w9", .waiting, ago: 700),
              m("Web-u1", .unread, ago: 600), m("Web-u2", .unread, ago: 500), m("Web-u3", .unread, ago: 400), m("Web-u4", .unread, ago: 300),
              m("plain-w", .waiting, ago: 100)]
    let q = ZonePlan.make(crowd, config: config, memory: [:], sofaSeats: seats, sofaSpots: spots)
    check("zone: waiting beyond the line stand at their sofa's spots (the seats are for the finished), after the finished who spill over",
        q.line == ids((0..<6).map { "Home-w\($0)" }) && q.sofa["Web"] == ids(["Web-u1", "Web-u2", "Web-u3"])
            && q.sofaOverflow["Web"] == ids(["Web-u4", "Web-w7", "Web-w8"]))
    check("zone: with the spots full a waiting one stays at its desk, strip orange",
        !q.sofaOverflow.values.joined().contains("id-Web-w9") && !q.sofa.values.joined().contains("id-Web-w9")
            && q.desks["id-Web-w9"].map { q.led($0) == .orange } == true)
    check("zone: an unzoned one waiting beyond the line still carries the line on", q.lobby == ["id-plain-w"])

    // Unzoned news stay at check-in; one with no desk ("+N") sits only when a seat is free.
    let loose = ZonePlan.make([m("plain-news", .unread, ago: 50)], config: config, memory: [:], sofaSeats: seats, sofaSpots: spots)
    check("zone: an unzoned one with news stays at the check-in spot", loose.visitor == "id-plain-news" && loose.sofa.isEmpty && loose.sofaOverflow.isEmpty)
    var packed = [m("AI-a")]
    for i in 0..<10 { packed.append(m("AI-d\(i)", .seen)) }
    packed.append(m("AI-extra", .unread, ago: 40))
    let roomy = ZonePlan.make(packed, config: config, memory: [:], sofaSeats: seats, sofaSpots: spots)
    check("zone: one with no desk (behind \"+N\") sits on its sofa while a seat is free",
        roomy.desks["id-AI-extra"] == nil && roomy.overflow["AI"]?.contains("id-AI-extra") == true && roomy.sofa["AI"] == ["id-AI-extra"])
    var tight = packed.filter { $0.name != "AI-extra" }.map { ZoneMember(id: $0.id, name: $0.name, zone: $0.zone, state: .unread, since: $0.since) }
    tight.append(m("AI-extra", .unread, ago: 999))
    let noSeat = ZonePlan.make(tight, config: config, memory: [:], sofaSeats: seats, sofaSpots: spots)
    check("zone: one with no desk does not take a seat its zone's desk holders fill, nor a standing spot",
        noSeat.sofa["AI"]?.count == 3 && noSeat.sofa["AI"]?.contains("id-AI-extra") == false
            && noSeat.sofaOverflow["AI"]?.contains("id-AI-extra") == false && noSeat.overflow["AI"]?.contains("id-AI-extra") == true)

    // Looked at (or at work again): back at its own desk.
    let seenAgain = ZonePlan.make(news.map { ZoneMember(id: $0.id, name: $0.name, zone: $0.zone, state: $0.name == "Web-n1" ? .seen : .busy, since: $0.since) },
                                  config: config, memory: p.memory, sofaSeats: seats, sofaSpots: spots)
    check("zone: once looked at or at work again it is off the sofa, at the same desk",
        seenAgain.sofa.isEmpty && seenAgain.sofaOverflow.isEmpty && seenAgain.desks["id-Web-n1"] == p.desks["id-Web-n1"]
            && seenAgain.desks["id-Web-n4"] == p.desks["id-Web-n4"])

    // ── The room ──
    guard let scene = ZoneArt.scene else {
        check("zone: the sofa needs the art", false)
        return
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let now = Date()
    func s(_ name: String, _ status: String, ago: Double) -> Session {
        var made = Session(id: "zid-" + name, pid: 1, project: "p", name: name, status: status, since: now - ago, summary: "做完了")
        made.cwd = "/tmp"
        return made
    }
    let size = CGSize(width: 1194, height: 900)
    let fit = ZoneFit(scene: scene.size, view: size)
    func near(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }
    let store = Store()
    store.readOnly = true
    store.sessions = [s("Web-a", "idle", ago: 600), s("Web-b", "idle", ago: 500), s("Web-c", "idle", ago: 400), s("Web-d", "idle", ago: 300),
                      s("Home-pin", "idle", ago: 9 * 3600), s("Ops-run", "busy", ago: 60)]
    store.pinned = ["zid-Home-pin"]
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    let admin = scene.sofas.first { $0.zone == "Web" }, my = scene.sofas.first { $0.zone == "Home" }
    let seated = ["zid-Web-a", "zid-Web-b", "zid-Web-c"].enumerated().allSatisfy { i, id in
        near(view.foot(of: id), admin.flatMap { i < $0.seats.count ? fit.point($0.seats[i]) : nil })
    }
    check("zone: in the room the finished ones sit on their zone's sofa seats, the fourth at its first spot",
        seated && near(view.foot(of: "zid-Web-d"), admin.flatMap { $0.overflow.first }.map { fit.point($0) }))
    check("zone: a awaiting-reply-pinned one sits on its zone's sofa, its pin on the plate",
        near(view.foot(of: "zid-Home-pin"), my.flatMap { $0.seats.first }.map { fit.point($0) }) && view.pinShown("zid-Home-pin"))
    check("zone: on the sofa it keeps the raised hand and the unread bubble",
        view.shownPose(of: "zid-Web-a") == .handUp && view.dotShown("zid-Web-a") && view.dotShown("zid-Home-pin"))
    let deskA = view.plan.desks["zid-Web-a"]
    check("zone: its desk stays its own, dark while it is on the sofa",
        deskA.map { !view.plan.screenOn($0) && view.plan.led($0) == .off && !view.screenShown($0) } == true)
    store.celebrating["zid-Web-a"] = now + 1.8
    store.sessions[0] = s("Web-a", "idle", ago: 1)
    view.update(store)
    let jumped = view.shownPose(of: "zid-Web-a")
    store.celebrating["zid-Web-a"] = now - 1
    view.update(store)
    check("zone: just done on the sofa it jumps, then waves (the office's poses)", jumped == .celebrating && view.shownPose(of: "zid-Web-a") == .waving)
    store.markSeen(store.sessions[0])
    store.sessions[1] = s("Web-b", "busy", ago: 1)
    view.update(store)
    check("zone: looked at, or at work again, it goes back to its own desk",
        near(view.foot(of: "zid-Web-a"), deskA.flatMap { scene.desk($0)?.seat }.map { fit.point($0) })
            && near(view.foot(of: "zid-Web-b"), view.plan.desks["zid-Web-b"].flatMap { scene.desk($0)?.seat }.map { fit.point($0) }))
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// The placement table, one check per row, and the rules round it (the rest room, the menu, looking
/// at one); twelve desks a zone; search in the title bar; walking round the islands, twice as fast, running.
@MainActor func zonePlacementTests(config: ZoneConfig) {
    let t0 = Date()
    func m(_ name: String, _ state: ZoneState, ago: Double = 100) -> ZoneMember {
        ZoneMember(id: "id-" + name, name: name, zone: config.prefix(of: name), state: state, since: t0 - ago)
    }
    let seats = ["Web": 3, "Ops": 3, "AI": 3, "Home": 3], spots = ["Web": 3, "Ops": 3, "AI": 3, "Home": 3]
    // Shuffled where the order they come in must not matter; as they came where it hands out the desks.
    func plan(_ members: [ZoneMember], memory: [String: String] = [:], shuffle: Bool = true, spots: [String: Int] = spots) -> ZonePlan {
        ZonePlan.make(shuffle ? members.shuffled() : members, config: config, memory: memory, sofaSeats: seats, sofaSpots: spots, restSeats: 6)
    }
    func dark(_ p: ZonePlan, _ id: String) -> Bool { p.desks[id].map { !p.screenOn($0) && p.led($0) == .off } == true }
    func atDesk(_ p: ZonePlan, _ id: String) -> Bool { p.desks[id].map { p.place[id] == .desk($0) } == true }

    // ── The table, row by row ──
    let busy = plan([m("Web-b1", .busy), m("Web-b2", .busy, ago: 9000)])
    check("zone row busy: at its own desk, screen on, LED ice",
        ["id-Web-b1", "id-Web-b2"].allSatisfy { id in atDesk(busy, id) && busy.desks[id].map { busy.screenOn($0) && busy.led($0) == .ice } == true })

    var news: [ZoneMember] = []
    for i in 0..<8 { news.append(m("Ops-n\(i)", .unread, ago: Double(1000 - i * 10))) }
    let unread = plan(news)
    check("zone row unread: own zone's sofa, its 3 seats in finish order, then its 3 spots, then its own desk",
        unread.place["id-Ops-n0"] == .sofaSeat("Ops", 0) && unread.place["id-Ops-n1"] == .sofaSeat("Ops", 1) && unread.place["id-Ops-n2"] == .sofaSeat("Ops", 2)
            && unread.place["id-Ops-n3"] == .sofaSpot("Ops", 0) && unread.place["id-Ops-n5"] == .sofaSpot("Ops", 2)
            && atDesk(unread, "id-Ops-n6") && atDesk(unread, "id-Ops-n7"))
    check("zone row unread: its desk's screen and LED are off wherever it is (sofa, spot or desk)", news.allSatisfy { dark(unread, $0.id) })

    let seen = plan([m("AI-s1", .seen, ago: 60), m("AI-s2", .seen, ago: 30000), m("AI-s3", .resting, ago: 90000)])
    check("zone row seen: at its own desk always, however long ago (resting too), screen and LED off",
        ["id-AI-s1", "id-AI-s2", "id-AI-s3"].allSatisfy { atDesk(seen, $0) && dark(seen, $0) } && seen.rest.isEmpty)

    var asking: [ZoneMember] = []
    for i in 0..<9 { asking.append(m("Home-w\(i)", .waiting, ago: Double(2000 - i * 10))) }
    var twoSpots = spots
    twoSpots["Home"] = 2
    let waiting = plan(asking, spots: twoSpots)
    check("zone row waiting: the line in front of the boss desk holds 6, longest first",
        waiting.line == (0..<6).map { "id-Home-w\($0)" } && (0..<6).allSatisfy { waiting.place["id-Home-w\($0)"] == .line($0) })
    check("zone row waiting: beyond 6, its zone's sofa spots, then its own desk",
        waiting.place["id-Home-w6"] == .sofaSpot("Home", 0) && waiting.place["id-Home-w7"] == .sofaSpot("Home", 1) && atDesk(waiting, "id-Home-w8"))
    check("zone row waiting: its own desk shows the orange LED (screen off), away or not",
        asking.allSatisfy { a in waiting.desks[a.id].map { waiting.led($0) == .orange && !waiting.screenOn($0) } == true })

    var packed: [ZoneMember] = []
    for i in 0..<11 { packed.append(m("Web-d\(i)", .seen, ago: Double(500 + i))) }
    packed.append(m("Web-L", .seen))
    for i in 0..<8 { packed.append(m("Web-x\(i)", .seen, ago: Double(50 + i))) }
    let noDesk = plan(packed, shuffle: false)
    check("zone row no desk: twelve owners (lead on 1); the rest go to the rest room, 6 seats, more on its +N",
        noDesk.desks.count == 12 && noDesk.desks["id-Web-L"]?.index == 1 && noDesk.rest.count == 6 && noDesk.restOverflow.count == 2
            && (0..<8).allSatisfy { noDesk.desks["id-Web-x\($0)"] == nil } && noDesk.overflow["Web"]?.count == 8
            && noDesk.restOverflow.allSatisfy { noDesk.place[$0] == .restListed })
    let loose = plan([m("plain-a", .busy), m("plain-b", .seen), m("plain-c", .unread)])
    check("zone row unzoned: one on the check-in spot, the others listed on its label",
        loose.visitor != nil && loose.visitorList.count == 2 && loose.place[loose.visitor!] == .checkIn
            && loose.visitorList.allSatisfy { loose.place[$0] == .checkInListed } && loose.rest.isEmpty)

    // No desk, but busy / unread / waiting.
    var full: [ZoneMember] = []
    for i in 0..<11 { full.append(m("Home-o\(i)", .seen, ago: Double(400 + i))) }
    let extra = plan(full + [m("Home-xb", .busy), m("Home-xu", .unread, ago: 20), m("Home-xw", .waiting, ago: 30)], shuffle: false)
    check("zone row no desk & busy: stays in the rest room (its working loop shows there)",
        extra.desks["id-Home-xb"] == nil && extra.rest.contains("id-Home-xb"))
    check("zone row no desk & unread: a sofa seat while one is free", extra.place["id-Home-xu"] == .sofaSeat("Home", 0))
    check("zone row no desk & waiting: in the line as usual", extra.place["id-Home-xw"] == .line(0))
    var sofaFull = full.map { ZoneMember(id: $0.id, name: $0.name, zone: $0.zone, state: .unread, since: $0.since) }
    sofaFull.append(m("Home-xu", .unread, ago: 1))
    let noSeat = plan(sofaFull, shuffle: false)
    check("zone row no desk & unread with the seats taken: the rest room, not a spot",
        noSeat.desks["id-Home-xu"] == nil && noSeat.rest.contains("id-Home-xu") && !noSeat.sofaOverflow.values.joined().contains("id-Home-xu"))

    // ── The store: put away to rest, or long finished, it is still at its desk; the menu has no move to rest room here ──
    let now = Date()
    func s(_ name: String, _ status: String, ago: Double) -> Session {
        var made = Session(id: "zid-" + name, pid: 1, project: "proj-" + name, name: name, status: status, since: now - ago, summary: "做完了")
        made.cwd = "/tmp/zone-search/" + name
        return made
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let store = Store()
    store.readOnly = true
    store.sessions = [s("Web-old", "idle", ago: 9 * 3600), s("Web-parked", "idle", ago: 60), s("Web-news", "idle", ago: 30),
                      s("Web-run", "busy", ago: 40), s("Web-ask", "waiting", ago: 50), s("Web-fresh", "idle", ago: 20)]
    for id in ["zid-Web-old", "zid-Web-parked", "zid-Web-run", "zid-Web-ask", "zid-Web-fresh"] { store.seen[id] = now.timeIntervalSince1970 }
    store.rest(store.sessions[1])
    let resting = Buckets(store, now: now).resting.map(\.id)
    let size = CGSize(width: 1194, height: 900)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    check("zone place: sent to rest from the menu, or finished 9 h ago (the office's resting), it stays at its own desk in still pose",
        Set(resting) == ["zid-Web-old", "zid-Web-parked"] && resting.allSatisfy { id in view.plan.desks[id].map { view.plan.place[id] == .desk($0) } == true }
            && view.plan.rest.isEmpty && resting.allSatisfy { view.shownPose(of: $0) == .standing })
    let wasOffice = UserDefaults.standard.object(forKey: "office"), wasTheme = UserDefaults.standard.object(forKey: "officeTheme")
    func titles() -> [String] { sessionMenu(store, store.sessions[5]).map(\.title) }
    UserDefaults.standard.set(true, forKey: "office")
    UserDefaults.standard.set(OfficeTheme.zone.name, forKey: "officeTheme")
    let zoneMenu = titles()
    UserDefaults.standard.set(OfficeTheme.studio.name, forKey: "officeTheme")
    let officeMenu = titles()
    UserDefaults.standard.set(false, forKey: "office")
    UserDefaults.standard.set(OfficeTheme.zone.name, forKey: "officeTheme")
    let boardMenu = titles()
    for (key, value) in [("office", wasOffice), ("officeTheme", wasTheme)] {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    check("zone place: the right-click menu has no move to rest room in Seaview; the office (and the board) keep it",
        !zoneMenu.contains("转到休息区（不需要了）") && zoneMenu.contains("跳到会话") && officeMenu.contains("转到休息区（不需要了）")
            && boardMenu.contains("转到休息区（不需要了）"))

    // Looking at one moves nobody, except one on the sofa back to its own desk.
    let before = view.plan.place
    for x in store.sessions { store.markSeen(x) }
    view.update(store)
    let after = view.plan.place
    let newsDesk = view.plan.desks["zid-Web-news"]
    check("zone place: marking seen moves only the one on the sofa, back to its own desk",
        before["zid-Web-news"] == .sofaSeat("Web", 0) && newsDesk.map { after["zid-Web-news"] == .desk($0) } == true
            && ["zid-Web-old", "zid-Web-parked", "zid-Web-run", "zid-Web-ask", "zid-Web-fresh"].allSatisfy { before[$0] == after[$0] })

    // ── Art twelve desks a zone ──
    guard let scene = ZoneArt.scene else {
        check("zone place: the art", false)
        return
    }
    var grid = true
    for zone in ["Web", "Ops", "AI", "Home"] {
        let desks = scene.desks.filter { $0.zone == zone }
        if desks.map(\.index).sorted() != Array(1...12) { grid = false }
        // Row 0 (1–6) and row 1 (7–12) each run in a line, side by side; desk 1 the south-most (lowest in the picture of its row).
        let far = (1...6).compactMap { i in desks.first { $0.index == i }?.seat }, near = (7...12).compactMap { i in desks.first { $0.index == i }?.seat }
        if far.count != 6 || near.count != 6 || !zip(far, near).allSatisfy({ $0.x < $1.x }) || far.first.map({ f in far.allSatisfy { $0.y <= f.y } }) != true { grid = false }
    }
    let lead = scene.desk(ZoneDesk(zone: "Web", index: 1))?.seat
    check("zone layout: the art has 12 desks in each zone, 1–6 one row and 7–12 the other; desk 1 (the lead's) the south-most",
        grid && lead.map { abs($0.x - 372.3126) < 0.01 && abs($0.y - 751.1581) < 0.01 } == true && scene.desks.count == 48)
    let twelfth = ZonePlan.make((0..<12).map { m("AI-t\($0)", .busy, ago: Double(100 - $0)) }, config: config, memory: [:], sofaSeats: [:])
    check("zone layout: a zone with no lead fills desks 2–12 in turn; the twelfth newcomer has none",
        Set(twelfth.desks.values.map(\.index)) == Set(2...12) && twelfth.overflow["AI"] == ["id-AI-t11"])
    check("zone layout: every desk of 1–12 has its art (seat, screen, LED)",
        ["Web", "Ops", "AI", "Home"].allSatisfy { z in (1...12).allSatisfy { i in scene.desk(ZoneDesk(zone: z, index: i)).map { $0.screen.count >= 4 && ($0.led?.count ?? 0) >= 4 } == true } })

    // ── Search ──
    let found = SessionSearch.results("WEB", in: store.sessions)
    let byProject = SessionSearch.results("proj-web-RUN", in: store.sessions)
    let byFolder = SessionSearch.results("/tmp/zone-search/web-ask", in: store.sessions)
    check("zone search: matches name, project and folder, case-insensitive; nothing for an empty query or a miss",
        found.count == 6 && byProject.map(\.id) == ["zid-Web-run"] && byFolder.map(\.id) == ["zid-Web-ask"]
            && SessionSearch.results("  ", in: store.sessions).isEmpty && SessionSearch.results("zzz", in: store.sessions).isEmpty)
    check("zone search: a name hit comes before a project or folder hit; the waiting one first among equals",
        found.first?.id == "zid-Web-ask" && SessionSearch.results("run", in: [s("x-run", "idle", ago: 1), s("run-y", "idle", ago: 1)]).first?.name == "run-y")
    check("zone search: ↑↓ move through the list, round its ends",
        SessionSearch.step(0, by: -1, count: 4) == 3 && SessionSearch.step(3, by: 1, count: 4) == 0 && SessionSearch.step(1, by: 1, count: 4) == 2
            && SessionSearch.step(0, by: 1, count: 0) == 0)
    store.sessions[2] = s("Web-news", "idle", ago: 5)
    store.seen["zid-Web-news"] = nil
    store.searchOpen = true
    var jumped: [String] = []
    SessionSearch.go(store.sessions[2], store: store) { jumped.append($0.id) }
    check("zone search: Enter or a click jumps to it as a card click does (looked at) and closes the search",
        jumped == ["zid-Web-news"] && !store.isUnread(store.sessions[2]) && !store.searchOpen)
    let panel = ImageRenderer(content: SearchPanel(store: store, query: "web").environment(\.colorScheme, .dark))
    panel.scale = 1
    let shown = panel.cgImage
    check("zone search: the popup draws its field and one row per hit", shown.map { $0.height > 6 * 30 } == true)

    // ── Walking: round the islands, by the aisles ──
    guard let map = scene.walkMap else {
        check("zone walk: the art gives a floor map", false)
        return
    }
    let islands = map.boxes.filter { ["Web", "Ops", "AI", "Home", "boss"].contains($0.name) || $0.name.hasPrefix("sofa_") }
    func seat(_ z: String, _ i: Int) -> CGPoint { scene.desk(ZoneDesk(zone: z, index: i))!.seat }
    let pairs: [(String, CGPoint, CGPoint)] = [
        ("Web 1 → Home sofa", seat("Web", 1), scene.sofas.first { $0.zone == "Home" }!.seats[1]),
        ("Home 12 → queue", seat("Home", 12), scene.queue!),
        ("line 5 → AI 4", scene.lineSpot(5)!, seat("AI", 4)),
        ("rest seat → Ops 7", scene.restSeats[2], seat("Ops", 7)),
        ("Ops 3 → AI 8", seat("Ops", 3), seat("AI", 8)),
        ("Web sofa → Web 9", scene.sofas.first { $0.zone == "Web" }!.seats[0], seat("Web", 9)),
        ("check-in → Web 5", scene.visitor!, seat("Web", 5)),
    ]
    var clean = true, bent = 0
    for (label, a, b) in pairs {
        let way = ZoneView.walkRoute(from: a, to: b, scene: scene).map(map.world)
        let ends = Set(islands.indices.filter { islands[$0].contains(map.world(a), grow: ZoneWalkMap.clearance) || islands[$0].contains(map.world(b), grow: ZoneWalkMap.clearance) })
        for (i, (p, q)) in zip(way, way.dropFirst()).enumerated() {
            for (k, box) in islands.enumerated() where box.blocks(p, q, grow: ZoneWalkMap.clearance * 0.5) {
                // Only the first leg (out of its own island or sofa) and the last (into it) may touch that one.
                let ownEnd = ends.contains(k) && (i == 0 || i == way.count - 2)
                if !ownEnd {
                    clean = false
                    print("      zone walk: \(label) leg \(i) crosses \(box.name)")
                }
            }
        }
        if way.count > 2 { bent += 1 }
        print("      zone walk: \(label): \(way.count - 1) legs")
    }
    let straight = islands.contains { $0.blocks(map.world(seat("Web", 1)), map.world(scene.sofas.first { $0.zone == "Home" }!.seats[1]), grow: 0) }
    check("zone walk: a path from spot to spot goes round the islands, the boss's desk and the sofas, never through them",
        clean && bent >= 5 && straight)
    let restDoor = ZoneView.walkRoute(from: scene.restSeats[0], to: seat("Web", 3), scene: scene).map(map.world)
    // the rest room is an open corner: no wall at x −9.5 and no opening in it.
    check("zone walk: out of the rest corner it walks across x −9.5 to an Web desk with no wall to go round (the wall is gone)",
        zip(restDoor, restDoor.dropFirst()).contains { p, q in (p.x + 9.5) * (q.x + 9.5) <= 0 } && !map.boxes.contains { $0.name.hasPrefix("wall_") })
    check("zone walk: pace 224 px a second in the picture (1.6 × 140)", ZoneView.pace == 224)

    // ── Walking live: in a window, the running row by each leg's direction, its frame changing as it goes ──
    Pets.shared.refresh(force: true)
    OfficePets.shared.synchronous = true
    let walkStore = Store()
    walkStore.readOnly = true
    walkStore.sessions = [s("Home-walker", "busy", ago: 30), s("Web-other", "busy", ago: 40)]
    walkStore.assignPets()
    let live = ZoneView(frame: CGRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    live.update(walkStore)
    walkStore.sessions[0] = s("Home-walker", "waiting", ago: 1)
    let started = CACurrentMediaTime()
    live.update(walkStore)
    let samples = zoneWalkSamples(live, "zid-Home-walker", count: 6, every: 0.1)
    let pet = live.pet(of: "zid-Home-walker") ?? ""
    let rows = [ZoneWalk.right, ZoneWalk.left].map { r in Set((0..<ZoneWalk.frames).compactMap { OfficePets.shared.runFrame(pet, facing: r, column: $0)?.image }.map(ObjectIdentifier.init)) }
    let route = live.route(of: "zid-Home-walker"), legRows = ZoneWalk.rows(route)
    var rightRow = true
    for sample in samples {
        guard let frame = sample.frame, let leg = zoneLeg(route, at: sample.foot) else { rightRow = false; continue }
        let want = legRows[leg] == ZoneWalk.right ? rows[0] : rows[1]
        if !want.contains(ObjectIdentifier(frame)) { rightRow = false }
    }
    let distinct = Set(samples.compactMap { $0.frame.map(ObjectIdentifier.init) }).count
    let loopWaits = (live.spriteAnimation(of: "zid-Home-walker", WaitingNudge.tiltKey)?.beginTime ?? 0) > CACurrentMediaTime() - 1
    print("      zone walk live: pet \(pet), \(route.count - 1) legs, rows \(legRows), \(distinct) distinct frames in \(samples.count) samples, loop waits \(loopWaits)")
    check("zone walk live: while it walks, the shown frame is its running row for the leg's direction (not the pose's loop)",
        !pet.isEmpty && samples.count == 6 && rightRow && !rows[0].isEmpty && !rows[1].isEmpty && loopWaits)
    check("zone walk live: the frame changes as it runs (at least 3 different frames in 6 samples 0.1 s apart)", distinct >= 3)
    let walkSeconds = live.walkEnds(of: "zid-Home-walker") - started
    var length: CGFloat = 0
    for (p, q) in zip(route, route.dropFirst()) { length += hypot(q.x - p.x, q.y - p.y) }
    let fit = ZoneFit(scene: scene.size, view: size)
    check("zone walk live: it takes its route's length at 224 px a second in the picture",
        abs((walkSeconds + 0.0) - Double(length / (224 * fit.scale))) < 0.3 && route.count > 2)
    window.orderOut(nil)
    window.contentView = nil
    OfficePets.shared.synchronous = false
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// The art with twelve desks a zone, the L of sofas, the waiting line along the bottom, the iMac boss desk), the zone labels
/// redesigned as one set, walking 1.6 × faster. The placement table is unchanged; only its inputs (desks, the line's length) move.
@MainActor func zoneArtTests(config: ZoneConfig) {
    guard let scene = ZoneArt.scene, let map = scene.walkMap else {
        check("zone layout: the art with its floor map", false)
        return
    }
    let t0 = Date()
    func m(_ name: String, _ state: ZoneState, ago: Double = 100) -> ZoneMember {
        ZoneMember(id: "id-" + name, name: name, zone: config.prefix(of: name), state: state, since: t0 - ago)
    }
    let seats = ["Web": 3, "Ops": 3, "AI": 3, "Home": 3], spots = ["Web": 3, "Ops": 3, "AI": 3, "Home": 3]

    // ── Twelve desks; the 13th of a zone to the rest room ──
    var thirteen = [m("Ops-L", .seen)]
    for i in 0..<12 { thirteen.append(m("Ops-d\(i)", .seen, ago: Double(500 + i))) }
    let p13 = ZonePlan.make(thirteen, config: config, memory: [:], sofaSeats: seats, sofaSpots: spots, restSeats: 6, lineLength: scene.lineCapacity)
    check("zone layout: twelve desks a zone (lead on 1, the others 2–12); the 13th has none and goes to the rest room",
        ZonePlan.desksPerZone == 12 && p13.desks.count == 12 && p13.desks["id-Ops-L"]?.index == 1 && Set(p13.desks.values.map(\.index)) == Set(1...12)
            && p13.desks["id-Ops-d11"] == nil && p13.rest == ["id-Ops-d11"] && p13.overflow["Ops"] == ["id-Ops-d11"])

    // ── The line: as many as fit along the art's queue_line, then (the placement order) the sofa spots, then the own desk ──
    let room = scene.lineCapacity
    var asking: [ZoneMember] = []
    for i in 0..<(room + 3) { asking.append(m("Home-w\(i)", .waiting, ago: Double(5000 - i * 10))) }
    var twoSpots = spots
    twoSpots["Home"] = 2
    let lined = ZonePlan.make(asking.shuffled(), config: config, memory: [:], sofaSeats: seats, sofaSpots: twoSpots, restSeats: 6, lineLength: room)
    check("zone layout: the line holds as many as fit along the art's line (\(room)), longest waiting first",
        (7...8).contains(room) && lined.line == (0..<room).map { "id-Home-w\($0)" } && (0..<room).allSatisfy { lined.place["id-Home-w\($0)"] == .line($0) })
    check("zone layout: beyond the line: its zone's sofa spots, then its own desk (orange LED) — the placement order unchanged",
        lined.place["id-Home-w\(room)"] == .sofaSpot("Home", 0) && lined.place["id-Home-w\(room + 1)"] == .sofaSpot("Home", 1)
            && lined.desks["id-Home-w\(room + 2)"].map { lined.place["id-Home-w\(room + 2)"] == .desk($0) && lined.led($0) == .orange } == true)
    check("zone layout: the line's start is the queue spot used, not boss_desk.queue_spot", scene.queue == scene.queueLine.first && scene.lineSpot(0) == scene.queueLine.first)
    let loose = ZonePlan.make((0..<(room + 2)).map { ZoneMember(id: "u\($0)", name: "plain-\($0)", zone: nil, state: .waiting, since: t0 - Double(900 - $0)) },
                              config: config, memory: [:], sofaSeats: seats, sofaSpots: spots, lineLength: room)
    let lobby = loose.lobby.compactMap { id -> CGPoint? in loose.place[id].flatMap { ZoneView.point(of: $0, scene) } }
    let lineSpots = (0..<room).compactMap { scene.lineSpot($0) }
    check("zone layout: unzoned ones beyond the line stand in a second row just in front of it, in the picture, off the line's spots",
        loose.line.count == room && lobby.count == 2
            && lobby.allSatisfy { p in p.y < scene.size.height - 20 && p.x > 0 && lineSpots.allSatisfy { hypot($0.x - p.x, $0.y - p.y) > scene.petHeight * 0.45 } })

    // ── In the room: the plan takes the art's capacity ──
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let now = Date()
    func s(_ name: String, _ status: String, ago: Double) -> Session {
        var made = Session(id: "line-" + name, pid: 1, project: "p", name: name, status: status, since: now - ago, summary: "要你批准：npm test")
        made.cwd = "/tmp"
        return made
    }
    let store = Store()
    store.readOnly = true
    store.sessions = (0..<(room + 1)).map { s("AI-q\($0)", "waiting", ago: Double(3000 - $0 * 10)) }
    let size = CGSize(width: 1194, height: 900)
    let fit = ZoneFit(scene: scene.size, view: size)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    func near(_ a: CGPoint?, _ b: CGPoint?) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5
    }
    check("zone layout: in the room \(room) stand along the line, the next at its sofa's first spot",
        view.plan.line.count == room && (0..<room).allSatisfy { near(view.foot(of: "line-AI-q\($0)"), scene.lineSpot($0).map(fit.point)) }
            && near(view.foot(of: "line-AI-q\(room)"), scene.sofaOverflow("AI", slot: 0).map(fit.point)))

    // ── The sofas: walks to and from every seat and spot keep off the other obstacles ──
    let obstacles = map.boxes.filter { ["Web", "Ops", "AI", "Home", "boss"].contains($0.name) || $0.name.hasPrefix("sofa_") || $0.name.hasPrefix("wall_")
        || $0.name == "railing" || $0.name.hasPrefix("pantry_") }
    var clean = true, tried = 0
    let from = [scene.queue!, scene.desk(ZoneDesk(zone: "Web", index: 1))!.seat, scene.desk(ZoneDesk(zone: "Home", index: 7))!.seat]
    for sofa in scene.sofas {
        for p in sofa.seats + sofa.overflow {
            for a in from {
                tried += 1
                let way = ZoneView.walkRoute(from: a, to: p, scene: scene).map(map.world)
                let ends = Set(obstacles.indices.filter { obstacles[$0].contains(map.world(a), grow: ZoneWalkMap.clearance) || obstacles[$0].contains(map.world(p), grow: ZoneWalkMap.clearance) })
                for (i, (u, v)) in zip(way, way.dropFirst()).enumerated() {
                    for (k, box) in obstacles.enumerated() where box.blocks(u, v, grow: ZoneWalkMap.clearance * 0.5) {
                        if ends.contains(k) && (i == 0 || i == way.count - 2) { continue }
                        clean = false
                        print("      zone walk: to \(sofa.zone) \(Int(p.x)),\(Int(p.y)) leg \(i) crosses \(box.name)")
                    }
                }
            }
        }
    }
    check("zone walk: to every seat and standing spot of the sofas the way keeps off the islands, the boss's desk, the other sofas, the railing and the pantry (\(tried) walks)",
        clean && tried == 3 * 24)
    let wallFree = scene.sofas.allSatisfy { sofa in (sofa.seats + sofa.overflow).allSatisfy { p in
        !map.boxes.contains { ($0.name == "railing" || $0.name.hasPrefix("pantry_")) && $0.contains(map.world(p), grow: ZoneWalkMap.clearance) } } }
    check("zone walk: no sofa seat or spot lies in the railing or the pantry's furniture", wallFree)
    check("zone layout: the boss's desk (the iMac) has its one screen in the art, in the picture's lower left (moved up-left)",
        scene.bossDesk.map { $0.screen.count == 4 && $0.seat.x < scene.size.width * 0.1 && $0.seat.y > scene.size.height * 0.75 } == true)

    // ── The zone labels: one designed set ──
    let names = [("Web", 7, 0, false), ("Ops", 12, 0, true), ("Docs", 19, 7, true), ("Infra", 3, 0, false), ("报到", 2, 1, false)]
    let h = ZoneGlow.signHeight(scale: fit.scale)
    let layouts = names.map { ZoneGlow.signLayout($0.0, count: $0.1, extra: $0.2, calling: $0.3, height: h) }
    let measure = OfficeCanvas(CGSize(width: 1, height: 1))
    var centred = true, inside = true
    for (l, n) in zip(layouts, names) {
        let mid = l.pill.midY
        for r in [l.bar, l.name] + [l.chip, l.plus].compactMap({ $0 }) where abs(r.midY - mid) > 0.25 { centred = false }
        for r in [l.chip, l.plus].compactMap({ $0 }) where !l.pill.contains(r) { inside = false }
        if l.name.width < measure.width(of: n.0, size: l.font, weight: .semibold) || l.name.maxX > (l.chip ?? l.plus ?? l.pill).minX { inside = false }
        if let dot = l.dot, !(CGRect(origin: .zero, size: l.size).contains(dot)) { inside = false }
    }
    let chips = layouts.compactMap(\.chip)
    check("zone signs: every label the same height and font; its count chip one size for 1 or 2 digits",
        Set(layouts.map(\.pill.height)) == [h] && Set(layouts.map(\.font)) == [layouts[0].font] && Set(chips.map { "\($0.width)x\($0.height)" }).count == 1 && chips.count == 5)
    check("zone signs: bar, name, count chip and +N chip all centred on the pill's middle line; chips inside the pill; no name cut; the dot in the picture",
        centred && inside && layouts[2].plus != nil && layouts[1].dot != nil && layouts[0].dot == nil && layouts[0].plus == nil)
    let drawn = ZoneGlow.sign("Docs", count: 19, extra: 7, calling: true, color: 0x5080D0, height: h)
    check("zone signs: drawn at two pixels a point (retina)",
        drawn.image.map { CGFloat($0.width) == (drawn.size.width * 2).rounded() && CGFloat($0.height) == (drawn.size.height * 2).rounded() } == true)

    // In the room: on each zone's anchor, screen-aligned, the same height.
    let signStore = Store()
    signStore.readOnly = true
    signStore.sessions = [s("Web-a", "busy", ago: 10), s("Ops-b", "waiting", ago: 20), s("AI-c", "idle", ago: 30), s("Home-d", "busy", ago: 40), s("plain-e", "busy", ago: 50)]
    let signView = ZoneView(frame: CGRect(origin: .zero, size: size))
    signView.still = true
    signView.update(signStore)
    let pills = scene.signs.map { (sign: $0, pill: signView.signPill($0.zone)) }
    check("zone signs: in the room each zone's label is centred on its sign's anchor (±0.5 pt), upright, all four the same height",
        pills.count == 4 && pills.allSatisfy { p in p.pill.map { abs($0.midX - fit.point(p.sign.center).x) <= 0.5 && abs($0.midY - fit.point(p.sign.center).y) <= 0.5 } == true }
            && Set(pills.compactMap { $0.pill?.height }) == [h]
            && scene.signs.allSatisfy { signView.signTransform($0.zone).map(CATransform3DIsIdentity) == true })
    check("zone signs: the check-in label is the same kind and height", signView.signPill(ZonePlan.visitorKey)?.height == h)
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// The four sofas in one row along the bottom, facing up, their standing spots in front of them; the boss's desk
/// up-left and the line from it towards the purple island; the rest room and the pantry open (no walls left in the walk map,
/// the pantry's cabinets and high table as obstacles, the railing as the back boundary); sofa sitters' plates never cut by
/// the picture's bottom edge. The placement table and rules are unchanged.
@MainActor func zoneOpenRoomTests(config: ZoneConfig) {
    guard let scene = ZoneArt.scene, let map = scene.walkMap else {
        check("zone sofas: the art with its floor map", false)
        return
    }
    let unit = scene.size.width / 1200   // one pixel of the 1200 px wide picture
    let seatsY = scene.sofas.flatMap(\.seats).map(\.y)
    check("zone sofas: the art's four sofas stand level in one row along the bottom (seats within 6 px), Web, Ops, Docs, Infra from the left",
        scene.sofas.count == 4 && seatsY.count == 12 && (seatsY.max()! - seatsY.min()!) < 6 * unit && seatsY.allSatisfy { $0 > scene.size.height * 0.9 }
            && scene.sofas.sorted { $0.center.x < $1.center.x }.map(\.zone) == ["Web", "Ops", "AI", "Home"]
            && scene.sofas.allSatisfy { s in s.facing.map { $0.dy < -abs($0.dx) * 3 } == true })
    // The line's height at a given x (carried on past its ends).
    func lineY(_ x: CGFloat) -> CGFloat {
        let a = scene.queueLine[0], b = scene.queueLine[1]
        return a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x)
    }
    let front = scene.queueLine.count == 2 && scene.sofas.allSatisfy { s in
        guard let top = s.seats.map(\.y).min(), s.overflow.count == 3 else { return false }
        return s.overflow.allSatisfy { o in (25...45).contains((top - o.y) / unit) && o.y > lineY(o.x) + scene.petHeight * 0.3 }
    }
    check("zone sofas: each sofa's three standing spots are in front of it (25–45 px above its seats at 1200 wide), between the sofa row and the line", front)
    let spots = (0..<scene.lineCapacity).compactMap { scene.lineSpot($0) }
    let lowestSpot = scene.sofas.flatMap(\.overflow).map(\.y).min() ?? 0
    check("zone sofas: the line holds 7–8 at the line's spacing, every place above the sofas' standing spots, from in front of the boss's desk towards the purple island",
        (7...8).contains(scene.lineCapacity) && spots.count == scene.lineCapacity && spots.allSatisfy { $0.y < lowestSpot - scene.petHeight * 0.3 }
            && scene.queueLine[1].x > scene.queueLine[0].x + 300 * unit && scene.queueLine[1].y < scene.queueLine[0].y)
    check("zone sofas: the boss's desk is up-left in the picture, its chair facing picture-right",
        scene.bossDesk.map { d in d.seat.x < scene.size.width * 0.1 && d.seat.y < scene.size.height * 0.85 && (d.facing.map { $0.dx > 0 } ?? false) } == true)

    // ── The walk map: no rest-room walls, the railing behind, the pantry's furniture in the way ──
    let names = Set(map.boxes.map(\.name))
    func extent(_ name: String) -> (x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat)? {
        guard let b = map.boxes.first(where: { $0.name == name }) else { return nil }
        let c = b.corners(grow: 0)
        return (c.map(\.x).min()!, c.map(\.x).max()!, c.map(\.y).min()!, c.map(\.y).max()!)
    }
    func near(_ e: (x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat)?, _ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat) -> Bool {
        guard let e else { return false }
        return abs(e.x0 - x0) < 0.02 && abs(e.x1 - x1) < 0.02 && abs(e.y0 - y0) < 0.02 && abs(e.y1 - y1) < 0.02
    }
    check("zone walk: the rest room's walls are gone from the walk map (no wall_glass, no wall_partition, no other wall)",
        !names.contains("wall_glass") && !names.contains("wall_partition") && !names.contains { $0.hasPrefix("wall_") })
    let railing = extent("railing")
    check("zone walk: a back boundary at the railing (from y ≈ 9.1 m back, across the whole room)",
        railing.map { abs($0.y0 - 9.1) < 0.05 && $0.x0 <= -16 && $0.x1 >= 16.5 } == true
            && scene.restSeats.allSatisfy { p in !map.boxes.contains { $0.name == "railing" && $0.contains(map.world(p), grow: ZoneWalkMap.clearance) } })
    check("zone walk: the pantry's cabinet run (x 11.45…12.15, y −4.70…0.95) and high table (x 9.45…10.60, y −3.90…−0.30) are obstacles",
        near(extent("pantry_cabinets"), 11.45, 12.15, -4.70, 0.95) && near(extent("pantry_table"), 9.45, 10.60, -3.90, -0.30))

    // A way's length after it has left its start's obstacle, against the straight line from there.
    func detour(_ way: [CGPoint]) -> CGFloat {
        guard way.count >= 3 else { return 1 }
        let w = way.map(map.world)
        let from = w[1], to = w[w.count - 1]
        var run: CGFloat = 0
        for i in 1..<(w.count - 1) { run += hypot(w[i + 1].x - w[i].x, w[i + 1].y - w[i].y) }
        return run / max(0.001, hypot(to.x - from.x, to.y - from.y))
    }
    var straight = true
    for index in 1...6 {   // the row facing the open floor; 7–12 sit on the island's far side and go round it first
        guard let desk = scene.desk(ZoneDesk(zone: "Web", index: index)) else { straight = false; continue }
        for seat in scene.restSeats {
            for way in [ZoneView.walkRoute(from: desk.seat, to: seat, scene: scene), ZoneView.walkRoute(from: seat, to: desk.seat, scene: scene)] {
                let ratio = way.count > 2 ? detour(way.first == desk.seat ? way : Array(way.reversed())) : 1
                // by the roads now (out to the left aisle, along it, into the rest corner's ways): at most 1.7×.
                if ratio > 1.7 {
                    straight = false
                    print(String(format: "      zone walk: Web %d ↔ rest %.0f,%.0f goes %.2f× the straight line (%d points)", index, seat.x, seat.y, ratio, way.count))
                }
            }
        }
    }
    check("zone walk: from an Web desk (1–6) to every rest seat (and back) the way goes across the open floor by the roads (≤ 1.7× the straight line)", straight)

    let pantry = map.boxes.filter { $0.name.hasPrefix("pantry_") }
    var avoids = !pantry.isEmpty, walks = 0
    guard let visitor = scene.visitor else {
        check("zone walk: the check-in spot", false)
        return
    }
    let behind = map.pixel(CGPoint(x: 10.3, y: 1.6))   // north of the high table: straight to check-in would cross it
    let behindFree = !map.boxes.contains { $0.contains(CGPoint(x: 10.3, y: 1.6), grow: ZoneWalkMap.clearance) }
        && behind.x > 0 && behind.y > 0 && behind.x < scene.size.width && behind.y < scene.size.height
    var starts = [behind, scene.queue!, scene.restSeats[0]]
    for d in [ZoneDesk(zone: "Home", index: 1), ZoneDesk(zone: "Home", index: 6), ZoneDesk(zone: "Home", index: 12), ZoneDesk(zone: "AI", index: 7)] {
        if let desk = scene.desk(d) { starts.append(desk.seat) }
    }
    for a in starts {
        for way in [ZoneView.walkRoute(from: a, to: visitor, scene: scene), ZoneView.walkRoute(from: visitor, to: a, scene: scene)] {
            walks += 1
            let w = way.map(map.world)
            for (u, v) in zip(w, w.dropFirst()) where pantry.contains(where: { $0.blocks(u, v, grow: ZoneWalkMap.clearance * 0.5) }) {
                avoids = false
                print(String(format: "      zone walk: %.1f,%.1f → %.1f,%.1f crosses the pantry", u.x, u.y, v.x, v.y))
            }
        }
    }
    check("zone walk: to and from the check-in spot (unchanged) every way keeps off the pantry's cabinets and high table (\(walks) walks)",
        avoids && behindFree && walks == 14 && !pantry.contains { $0.contains(map.world(visitor), grow: ZoneWalkMap.clearance) })

    // ── In the room: the sofa sitters' plates are never cut by the bottom edge ──
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let store = zoneOpenRoomCrowd()
    var inside = true, consistent = true, under = false, above = false, apart = true
    for (size, wantUnder) in [(CGSize(width: 1180, height: 790), true), (CGSize(width: 1180, height: 690), false)] {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        let sitters = view.plan.sofa.values.flatMap { $0 }
        var modes = Set<Bool>()
        for id in sitters {
            guard let plate = view.plateFrame(of: id), let foot = view.foot(of: id) else { inside = false; continue }
            if plate.minY < 0 || plate.maxY > size.height - 1 { inside = false; print("      zone sofas: \(id)'s plate \(plate) cut at \(size)") }
            // Under the feet (a neighbour's plate may have stepped it up a little) or over the head, well above the feet.
            modes.insert(plate.maxY > foot.y - 30 * view.bounds.height / 790)
        }
        if modes.count != 1 || sitters.count != 12 || view.sofaPlatesLifted == wantUnder { consistent = false; print("      zone sofas: \(sitters.count) sitters, modes \(modes) at \(size)") }
        if wantUnder { under = modes == [true] } else { above = modes == [false] }
        if wantUnder {
            // Nobody's plate on another's: the line, the standing ones and the sitters.
            let plates = store.sessions.compactMap { view.plateFrame(of: $0.id) }
            for i in plates.indices { for j in plates.indices where j > i && plates[i].insetBy(dx: 1, dy: 0.5).intersects(plates[j].insetBy(dx: 1, dy: 0.5)) { apart = false } }
            // Nor any one's unread dots on another's plate or dots.
            let dots = store.sessions.compactMap { s in view.dotFrame(of: s.id).map { (s.id, $0) } }
            for (id, d) in dots {
                for s in store.sessions where s.id != id {
                    if let plate = view.plateFrame(of: s.id), plate.insetBy(dx: 1, dy: 0.5).intersects(d.insetBy(dx: 1, dy: 1)) { apart = false; print("      zone sofas: \(id)'s dots on \(s.id)'s plate") }
                }
                for (other, e) in dots where other > id && e.insetBy(dx: 1, dy: 1).intersects(d.insetBy(dx: 1, dy: 1)) { apart = false; print("      zone sofas: \(id)'s dots on \(other)'s") }
            }
            if dots.count < 16 { apart = false }
            let checkIn = view.signPill(ZonePlan.visitorKey), mine = view.signPill("Home")
            check("zone sofas: the check-in label and the Infra label stay apart (2 pt at least) and both in the picture",
                checkIn.map { a in mine.map { b in !a.insetBy(dx: -2, dy: -2).intersects(b) && view.bounds.contains(a) && view.bounds.contains(b) } == true } == true)
        }
    }
    check("zone sofas: with all four sofas full, every sitter's plate is inside the picture, at 3:2 and in a wider window", inside && consistent)
    check("zone sofas: sitters' plates under their feet when they fit (3:2), all lifted over their heads together when the bottom is cut (wider)", under && above)
    check("zone sofas: in the crowded bottom (a full line, full sofas and their standing spots) no plate lies on another, and no unread dots on a plate or other dots", apart)
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// the pointer picks the figure actually drawn under it: a pet's opaque pixel or its plate, the front one first;
/// only where none is drawn, the nearest whose box holds the point. "Opaque" is read here straight from the frame's
/// pixels, and the view's own picture of the figure proves the frame is shown the way round the hit test assumes.
@MainActor func zoneHitTestTests() {
    guard let scene = ZoneArt.scene else {
        check("zone hit: the art", false)
        return
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    OfficePets.shared.synchronous = true
    defer {
        OfficePets.shared.synchronous = false
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    let now = Date()
    func s(_ name: String) -> Session {
        var made = Session(id: "pair-" + name, pid: 1, project: "p", name: name, status: "busy", since: now - 30, summary: "在做事")
        made.cwd = "/tmp"
        return made
    }
    let size = CGSize(width: 1180, height: 790)
    let fit = ZoneFit(scene: scene.size, view: size)
    func room(_ store: Store) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        return view
    }
    // A frame's alpha, rows from the top as the picture is seen.
    var alphas: [ObjectIdentifier: [UInt8]] = [:]
    func alpha(_ image: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < image.width, y < image.height else { return 0 }
        if alphas[ObjectIdentifier(image)] == nil {
            var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
            px.withUnsafeMutableBytes { raw in
                let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            alphas[ObjectIdentifier(image)] = stride(from: 3, to: px.count, by: 4).map { px[$0] }
        }
        return alphas[ObjectIdentifier(image)]![y * image.width + x]
    }
    // Solid (every pixel round it opaque) or clear (every pixel round it empty), so a rounding never decides a check.
    func solid(_ image: CGImage, _ x: Int, _ y: Int) -> Bool { (-1...1).allSatisfy { dx in (-1...1).allSatisfy { dy in alpha(image, x + dx, y + dy) > 200 } } }
    func clear(_ image: CGImage, _ x: Int, _ y: Int) -> Bool { (-2...2).allSatisfy { dx in (-2...2).allSatisfy { dy in alpha(image, x + dx, y + dy) < 10 } } }
    // A figure's frame in the view, and a view point's pixel in it.
    func shown(_ view: ZoneView, _ id: String) -> (image: CGImage, frame: CGRect)? {
        guard let sprite = view.sprite(of: id), let foot = view.foot(of: id) else { return nil }
        return (sprite.image, sprite.frame.offsetBy(dx: foot.x, dy: foot.y))
    }
    func pixel(_ s: (image: CGImage, frame: CGRect), _ p: CGPoint) -> (Int, Int) {
        (Int(floor((p.x - s.frame.minX) / s.frame.width * CGFloat(s.image.width))), Int(floor((p.y - s.frame.minY) / s.frame.height * CGFloat(s.image.height))))
    }
    func point(_ s: (image: CGImage, frame: CGRect), _ x: Int, _ y: Int) -> CGPoint {
        CGPoint(x: s.frame.minX + (CGFloat(x) + 0.5) / CGFloat(s.image.width) * s.frame.width,
                y: s.frame.minY + (CGFloat(y) + 0.5) / CGFloat(s.image.height) * s.frame.height)
    }
    func onPlate(_ view: ZoneView, _ ids: [String], _ p: CGPoint) -> Bool { ids.contains { view.plateFrame(of: $0)?.insetBy(dx: -2, dy: -2).contains(p) == true } }

    // ── Two overlapping: the back one's body seen through the front one's empty corner ──
    let pair = Store()
    pair.readOnly = true
    pair.sessions = [s("Home-a"), s("Home-b")]
    pair.assignPets()
    let view = room(pair)
    let a = "pair-Home-a", b = "pair-Home-b"
    var back: CGPoint?, front: CGPoint?, placed = ""
    if let footA = view.foot(of: a), let sa = shown(view, a) {
        search: for (kx, dy) in [(0.35, 6.0), (-0.35, 6.0), (0.25, 12.0), (-0.25, 12.0), (0.45, 4.0), (-0.45, 4.0)] {
            view.probeWalk(b, to: fit.back(CGPoint(x: footA.x + sa.frame.width * kx, y: footA.y + dy)))
            guard let sb = shown(view, b), (view.foot(of: b)?.y ?? 0) > footA.y else { continue }
            back = nil; front = nil
            for y in stride(from: sa.frame.minY, to: sa.frame.maxY, by: 1) {
                for x in stride(from: sa.frame.minX, to: sa.frame.maxX, by: 1) {
                    let p = CGPoint(x: x + 0.5, y: y + 0.5)
                    guard sb.frame.insetBy(dx: 2, dy: 2).contains(p), !onPlate(view, [a, b], p) else { continue }
                    let (ax, ay) = pixel(sa, p), (bx, by) = pixel(sb, p)
                    if back == nil, solid(sa.image, ax, ay), clear(sb.image, bx, by) { back = p }
                    if front == nil, solid(sb.image, bx, by) { front = p }
                    if back != nil && front != nil { placed = "b at \(kx) × wide, \(dy) pt lower"; break search }
                }
            }
        }
    }
    print("      zone hit: overlap \(placed.isEmpty ? "not found" : placed), back point \(back.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-"), front point \(front.map { "\(Int($0.x)),\(Int($0.y))" } ?? "-")")
    check("zone hit: both figures show a pet picture (not the token), so the checks below are about pixels",
        view.sprite(of: a) != nil && view.sprite(of: b) != nil)
    check("zone hit: on the back one's opaque pixel inside the front one's empty rectangle, the pointer picks the back one (hover and click)",
        back.map { view.target(at: $0) == .pet(a) && view.card(at: $0) == a } == true)
    check("zone hit: on the front one's opaque pixel (over the back one's box), the front one",
        front.map { view.target(at: $0) == .pet(b) && view.card(at: $0) == b } == true)

    // ── Orientation: a pixel drawn where its mirror images are empty, facing either way ──
    let walkers = Store()
    walkers.readOnly = true
    walkers.sessions = [s("Home-a"), s("Ops-b"), s("Web-c"), s("AI-d")] + (1...9).map { s("Home-x\($0)") }   // desks on both sides of an island
    walkers.assignPets()
    var proved: [Int: Bool] = [:]
    let ids = walkers.sessions.map(\.id)
    pairs: for guest in ids {
        for host in ids where host != guest {
            let v = room(walkers)
            v.visit(guest, to: host, words: "看一下", until: now + 30)
            v.update(walkers)
            guard let facing = v.facing(of: guest), proved[facing] == nil, let sg = shown(v, guest), let picture = v.figureImage(only: guest) else { continue }
            let w = sg.image.width, h = sg.image.height
            let others = ids.filter { $0 != guest }.compactMap { shown(v, $0)?.frame }
            var found: (CGPoint, CGPoint, CGPoint)?
            find: for y in 2..<(h - 2) {
                for x in 2..<(w - 2) where solid(sg.image, x, y) && clear(sg.image, w - 1 - x, y) && clear(sg.image, x, h - 1 - y) {
                    let p = point(sg, x, y), mh = point(sg, w - 1 - x, y), mv = point(sg, x, h - 1 - y)
                    if onPlate(v, ids, p) || onPlate(v, ids, mh) || onPlate(v, ids, mv) { continue }
                    // Off everyone else's picture, so only this figure's pixels decide.
                    if others.contains(where: { $0.contains(p) || $0.contains(mh) || $0.contains(mv) }) { continue }
                    found = (p, mh, mv)
                    break find
                }
            }
            guard let lone = found else { continue }
            let (p, mh, mv) = lone
            // The view's own picture of just this figure (one point a pixel): drawn at p, empty at both mirror points.
            func drawn(_ q: CGPoint) -> UInt8 {
                let x = Int(q.x), y = Int(q.y)
                return x >= 0 && y >= 0 && x < picture.width && y < picture.height ? alpha(picture, x, y) : 0
            }
            let shownRight = drawn(p) > 128 && drawn(mh) < 20 && drawn(mv) < 20
            let hits = v.drawnPet(at: p) == guest && v.drawnPet(at: mh) != guest && v.drawnPet(at: mv) != guest
            print("      zone hit: \(guest) visiting \(host), facing \(facing == ZoneWalk.right ? "right" : "left"): drawn \(drawn(p))/\(drawn(mh))/\(drawn(mv)), hit \(v.drawnPet(at: p) ?? "-")/\(v.drawnPet(at: mh) ?? "-")/\(v.drawnPet(at: mv) ?? "-")")
            proved[facing] = shownRight && hits
            if proved.count == 2 { break pairs }
        }
    }
    check("zone hit: facing right and facing left, a frame's pixel drawn where its left-right and up-down mirror images are empty is hit exactly where the view draws it",
        proved[ZoneWalk.right] == true && proved[ZoneWalk.left] == true)

    // ── Nothing drawn under the point: beside a lone figure still hits it ──
    let lone = Store()
    lone.readOnly = true
    lone.sessions = [s("Home-a")]
    lone.assignPets()
    let alone = room(lone)
    var beside: CGPoint?
    if let sa = shown(alone, a) {
        search: for y in stride(from: sa.frame.minY + 2, to: sa.frame.maxY - 2, by: 1) {
            for x in [sa.frame.minX + 2, sa.frame.maxX - 3] {
                let p = CGPoint(x: x + 0.5, y: y + 0.5), (px, py) = pixel(sa, p)
                if clear(sa.image, px, py), !onPlate(alone, [a], p) { beside = p; break search }
            }
        }
    }
    check("zone hit: in the empty air beside a lone figure (inside its box, no pixel drawn), the pointer still finds it, and nothing hits it there by pixels",
        beside.map { alone.target(at: $0) == .pet(a) && alone.drawnPet(at: $0) == nil } == true)
}

/// long-press a figure for 2 s, drag it to another desk of its zone: a swap with its owner, or a move to a free one;
/// desk 1, another zone or the floor cancels. The desks are the sticky by-name memory, on disk.
@MainActor func zoneDragTests() {
    guard let scene = ZoneArt.scene else {
        check("zone drag: the art", false)
        return
    }
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    OfficePets.shared.synchronous = true
    defer {
        OfficePets.shared.synchronous = false
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    let now = Date()
    func s(_ name: String, _ status: String = "busy", id: String? = nil) -> Session {
        var made = Session(id: id ?? "lift-" + name, pid: 1, project: "p", name: name, status: status, since: now - 30, summary: "在做事")
        made.cwd = "/tmp"
        return made
    }
    let size = CGSize(width: 1180, height: 790)
    let fit = ZoneFit(scene: scene.size, view: size)
    let store = Store()   // not read-only: the desks are written to disk
    store.sessions = [s("Web-L"), s("Web-a"), s("Web-b"), s("Web-c"), s("Ops-x"), s("新会话", id: "lift-guest")]
    store.seen = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, now.timeIntervalSince1970) })
    store.assignPets()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    var clicked: [String] = []
    view.onClick = { clicked.append($0.id) }
    view.update(store)
    let a = "lift-Web-a", b = "lift-Web-b", lead = "lift-Web-L"
    func handle(_ id: String) -> CGPoint {
        guard let plate = view.plateFrame(of: id) else { return CGPoint(x: -100, y: -100) }
        return CGPoint(x: plate.midX, y: plate.midY)
    }
    func seat(_ desk: ZoneDesk) -> CGPoint { scene.desk(desk).map { fit.point($0.seat) } ?? CGPoint(x: -100, y: -100) }
    let deskA = view.plan.desks[a], deskB = view.plan.desks[b]
    check("zone drag: the setup: Web-L on desk 1, the others on 2–4, the plates clickable",
        view.plan.desks[lead]?.index == 1 && deskA != nil && deskB != nil && view.target(at: handle(a)) == .pet(a))
    check("zone drag: a zoned figure that owns a desk can be lifted; the lead, an unzoned one and an unknown one cannot",
        view.canLift(a) && view.canLift(b) && !view.canLift(lead) && !view.canLift("lift-guest") && !view.canLift("nobody"))

    // Under 2 s: an ordinary click.
    view.press(at: handle(a))
    let wasClick = view.release(at: handle(a))
    check("zone drag: released before 2 s, it is a click (jumps to the session), nothing lifted", wasClick && clicked == [a] && view.liftedID == nil)
    // Moved more than a few points before 2 s: no lift.
    view.press(at: handle(a))
    view.drag(to: CGPoint(x: handle(a).x + 20, y: handle(a).y))
    view.holdNow()
    let liftedAfterMove = view.liftedID
    view.release(at: CGPoint(x: handle(a).x + 20, y: handle(a).y))
    check("zone drag: moved more than a few points during the hold, it does not lift", liftedAfterMove == nil && view.liftedID == nil)
    // The lead cannot be lifted.
    view.press(at: handle(lead))
    view.holdNow()
    let leadLifted = view.liftedID
    view.release(at: handle(lead))
    check("zone drag: the lead (desk 1) is never lifted", leadLifted == nil)

    // 2 s: lifted.
    store.hovered = a
    clicked = []
    view.press(at: handle(a))
    view.holdNow()
    let allowed = Set(scene.desks.filter { $0.zone == "Web" && $0.index >= 2 && $0.index != deskA?.index }.map { ZoneDesk(zone: $0.zone, index: $0.index) })
    check("zone drag: held 2 s, it lifts: bigger, its hover card gone", view.liftedID == a && view.liftScale > 1.05 && store.hovered == nil)
    check("zone drag: lifted, its zone's other desks are highlighted (never desk 1, never another zone's)",
        Set(view.highlightedDesks) == allowed && !allowed.isEmpty && view.strongDesk == nil)
    view.drag(to: seat(deskB!))
    let strong = view.strongDesk
    let followed = view.foot(of: a).map { hypot($0.x - seat(deskB!).x, $0.y - seat(deskB!).y) < 60 } ?? false
    view.drag(to: CGPoint(x: seat(deskB!).x + 6, y: seat(deskB!).y - 4))
    let strongNear = view.strongDesk
    check("zone drag: dragged over a desk's spot (or near it), that desk is highlighted strongly, and the figure follows the pointer",
        strong == deskB && strongNear == deskB && followed)
    let swapClick = view.release(at: CGPoint(x: seat(deskB!).x + 6, y: seat(deskB!).y - 4))
    check("zone drag: dropped on an owned desk, the two swap desks (plan and memory, on disk), and it is not a click",
        !swapClick && clicked.isEmpty && view.liftedID == nil && view.plan.desks[a] == deskB && view.plan.desks[b] == deskA
            && ZoneMemory.remembered["Web-a"] == deskB?.key && ZoneMemory.remembered["Web-b"] == deskA?.key
            && (UserDefaults.standard.dictionary(forKey: ZoneMemory.key) as? [String: String])?["Web-a"] == deskB?.key
            && (UserDefaults.standard.dictionary(forKey: ZoneMemory.key) as? [String: String])?["Web-b"] == deskA?.key
            && view.highlightedDesks.isEmpty && view.liftScale == 1)
    check("zone drag: ...and each stands at its new desk", view.foot(of: a) == seat(deskB!) && view.foot(of: b) == seat(deskA!))

    // A free desk: it takes it, its old desk is free.
    let owned = Set(view.plan.desks.values)
    let freeDesk = allowed.filter { !owned.contains($0) }.sorted { $0.index > $1.index }.first
    let fromDesk = view.plan.desks[a]
    view.press(at: handle(a))
    view.holdNow()
    if let freeDesk { view.drag(to: seat(freeDesk)) }
    view.release(at: freeDesk.map(seat) ?? .zero)
    check("zone drag: dropped on a free desk, it takes it and its old desk is free",
        freeDesk != nil && view.plan.desks[a] == freeDesk && !view.plan.desks.values.contains(fromDesk!)
            && ZoneMemory.remembered["Web-a"] == freeDesk?.key)

    // Cancels: desk 1, another zone's desk, the empty floor, Esc.
    func tryDrop(_ at: CGPoint, esc: Bool = false) -> Bool {
        let before = view.plan.desks, memory = ZoneMemory.remembered, home = view.foot(of: a)
        view.press(at: handle(a))
        view.holdNow()
        guard view.liftedID == a else { return false }
        view.drag(to: at)
        let target = view.strongDesk
        if esc { view.cancelLift() } else { view.release(at: at) }
        return (esc ? target != nil : target == nil) && view.liftedID == nil && view.plan.desks == before && ZoneMemory.remembered == memory && view.foot(of: a) == home
    }
    let emDesk = view.plan.desks["lift-Ops-x"]
    check("zone drag: dropped on desk 1 it settles back (no swap with the lead)", tryDrop(seat(ZoneDesk(zone: "Web", index: 1))))
    check("zone drag: dropped on another zone's desk it settles back", emDesk != nil && tryDrop(seat(emDesk!)))
    check("zone drag: dropped on the empty floor it settles back", tryDrop(CGPoint(x: 8, y: 8)))
    check("zone drag: Esc while lifted over a desk it may take: it settles back, nothing changes", tryDrop(seat(deskA!), esc: true))

    // Remembered by name: after a restart and window swap (a new id), the desk it was moved to.
    let reopened = Store()
    reopened.readOnly = true
    reopened.sessions = [s("Web-L"), s("Web-a", id: "lift-new-a"), s("Web-b"), s("Web-c"), s("Ops-x")]
    ZoneMemory.remembered = UserDefaults.standard.dictionary(forKey: ZoneMemory.key) as? [String: String] ?? [:]
    let plan = ZonePlan.current(reopened, scene: scene)
    check("zone drag: the desks moved to are read back from disk and kept by name (window swap: a new id)",
        plan.desks["lift-new-a"] == freeDesk && plan.desks["lift-Web-b"] == deskA)

    // One away (on its zone's sofa, unread) may be lifted; dropped on a desk, its desk changes and it stays on the sofa.
    store.sessions = store.sessions.map { $0.id == b ? s("Web-b", "idle") : $0 }
    store.seen[b] = nil
    view.update(store)
    let away = view.plan.place[b]
    var sofa = false
    if case .sofaSeat? = away { sofa = true }
    let sofaFoot = view.foot(of: b)
    let target = allowed.first { !Set(view.plan.desks.values).contains($0) && $0 != view.plan.desks[b] }
    view.press(at: handle(b))
    view.holdNow()
    let liftedAway = view.liftedID
    if let target { view.drag(to: seat(target)) }
    view.release(at: target.map(seat) ?? .zero)
    check("zone drag: one on its sofa can be lifted; dropped on a desk, its desk changes and it keeps its sofa seat",
        sofa && liftedAway == b && view.plan.desks[b] == target && view.plan.place[b] == away && view.foot(of: b) == sofaFoot)

    // The hold is 0.8 s, a trackpad's jitter does not end it, it shows itself coming, and a late timer is caught up.
    check("zone hold: 0.8 s to lift, up to 10 pt of wander", ZoneView.holdSeconds == 0.8 && ZoneView.holdSlop >= 10)
    var clock: CFTimeInterval = 1000
    view.pressClock = { clock }
    defer { view.pressClock = { CACurrentMediaTime() } }
    let ha = handle(a)
    view.press(at: ha)
    view.drag(to: CGPoint(x: ha.x + 5, y: ha.y - 4))
    view.drag(to: CGPoint(x: ha.x - 6, y: ha.y + 3))
    view.holdNow()
    let jitterLift = view.liftedID
    view.cancelLift()
    view.release(at: ha)
    check("zone hold: a few points of jitter during the hold still lift", jitterLift == a)
    view.press(at: ha)
    view.drag(to: CGPoint(x: ha.x + 14, y: ha.y))
    view.holdNow()
    let farLift = view.liftedID
    view.release(at: CGPoint(x: ha.x + 14, y: ha.y))
    check("zone hold: moved more than 10 pt, no lift", farLift == nil && view.liftedID == nil)
    // Feedback: from 0.3 s it grows toward the lifted size; released before 0.8 s it is a click and snaps back.
    clicked = []
    let pressMedia = CACurrentMediaTime()
    view.press(at: ha)
    let grow = view.preliftAnimation
    let growTo = (grow?.toValue as? NSValue).map { CATransform3DGetAffineTransform($0.caTransform3DValue).a } ?? 0
    check("zone hold: pressed, it starts growing after 0.3 s, until the lift",
        grow != nil && abs((grow?.beginTime ?? 0) - pressMedia - 0.3) < 0.05 && abs((grow?.duration ?? 0) - 0.5) < 0.001
            && growTo > 1.02 && growTo < ZoneView.liftGrow)
    clock += 0.5
    let quick = view.release(at: ha)
    check("zone hold: released at 0.5 s, it is a click, the grow is gone and it is its own size",
        quick && clicked == [a] && view.preliftAnimation == nil && view.liftScale == 1 && view.liftedID == nil)
    // A main queue too busy to run the hold on time: the first drag after 0.8 s lifts it.
    view.press(at: ha)
    clock += 1.0
    view.drag(to: CGPoint(x: ha.x + 2, y: ha.y))
    let caught = view.liftedID
    check("zone hold: the timer late, a drag after 0.8 s lifts at once", caught == a && view.preliftAnimation == nil)
    view.cancelLift()
    view.release(at: ha)
    // Released after 0.8 s with the timer late: not a click (the user held it), nothing lifted, its own size.
    clicked = []
    view.press(at: ha)
    clock += 1.2
    let late = view.release(at: ha)
    check("zone hold: released after 0.8 s with the timer late, no click, nothing lifted",
        !late && clicked.isEmpty && view.liftedID == nil && view.liftScale == 1)
    // The real timer, on the main queue: it lifts within the hold.
    view.pressClock = { CACurrentMediaTime() }
    view.press(at: ha)
    RunLoop.main.run(until: Date().addingTimeInterval(1.0))
    let timed = view.liftedID
    view.cancelLift()
    view.release(at: ha)
    check("zone hold: on the main queue's own timer it lifts after 0.8 s", timed == a)
}

/// `--zone-drag-stills <dir>`: `zone-drag.png` (the crowded room, an Web figure lifted and carried over another Web desk:
/// its zone's desks soft, the one under the pointer strong), `zone-drag-zoom.png` (the same area at 2×), `zone-menu.png` (a
/// figure's right-click menu in Seaview with change pet and never use this pet, drawn from `sessionMenu`'s lines: a real NSMenu cannot
/// be drawn off the screen).
@MainActor func zoneDragStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    defer {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    guard let scene = ZoneArt.scene else { return }
    let store = zoneOpenRoomCrowd()
    let size = CGSize(width: 1180, height: 790)
    let fit = ZoneFit(scene: scene.size, view: size)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    // An Web figure at its desk, carried to a spot near another Web desk.
    guard let mover = store.sessions.first(where: { $0.name == "Web-UX-星图" })?.id, let from = view.plan.desks[mover],
        let plate = view.plateFrame(of: mover)
    else { return print("zone stills: no mover") }
    let owned = Set(view.plan.desks.values)
    let goal = scene.desks.filter { $0.zone == "Web" && $0.index >= 2 && $0.index != from.index }
        .map { ZoneDesk(zone: $0.zone, index: $0.index) }.first { !owned.contains($0) && abs($0.index - from.index) >= 2 }
        ?? ZoneDesk(zone: "Web", index: from.index == 8 ? 9 : 8)
    let grab = CGPoint(x: plate.midX, y: plate.midY)
    view.press(at: grab)
    view.holdNow()
    let seat = scene.desk(goal).map { fit.point($0.seat) } ?? .zero
    view.drag(to: CGPoint(x: seat.x + 4, y: seat.y - 3))
    print("zone stills: lifted \(view.liftedID ?? "-") from \(from.key), over \(view.strongDesk?.key ?? "-"), soft \(view.highlightedDesks.count) desks")
    let picture = view.image()
    write(picture, "zone-drag.png")
    if let picture {
        let box = CGRect(x: min(seat.x, fit.point(scene.desk(from)?.seat ?? .zero).x) - 160, y: seat.y - 230, width: 520, height: 360)
        let crop = picture.cropping(to: CGRect(x: box.minX * 2, y: box.minY * 2, width: box.width * 2, height: box.height * 2))
        write(crop, "zone-drag-zoom.png")
    }
    view.cancelLift()

    // The menu, as Seaview shows it, by a figure.
    let wasOffice = UserDefaults.standard.object(forKey: "office"), wasTheme = UserDefaults.standard.object(forKey: "officeTheme")
    UserDefaults.standard.set(true, forKey: "office")
    UserDefaults.standard.set(OfficeTheme.zone.name, forKey: "officeTheme")
    let target = store.sessions.first { $0.name == "Web-ABC-银河" } ?? store.sessions[0]
    let lines = sessionMenu(store, target)
    for (key, value) in [("office", wasOffice), ("officeTheme", wasTheme)] {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
    }
    print("zone stills: menu \(lines.map { $0.action == .separator ? "—" : $0.title + ($0.enabled ? " ✓" : " ✗") })")
    guard let room = view.image(), let foot = view.foot(of: target.id) else { return }
    let canvas = OfficeCanvas(size)
    canvas.ctx.saveGState()
    canvas.ctx.translateBy(x: 0, y: size.height)
    canvas.ctx.scaleBy(x: 1, y: -1)
    canvas.ctx.draw(room, in: CGRect(origin: .zero, size: size))
    canvas.ctx.restoreGState()
    let rowH: CGFloat = 22, sepH: CGFloat = 11, width: CGFloat = 250
    let height = lines.reduce(CGFloat(10)) { $0 + ($1.action == .separator ? sepH : rowH) }
    let origin = CGPoint(x: min(foot.x + 14, size.width - width - 8), y: max(8, min(foot.y - height * 0.6, size.height - height - 8)))
    let panel = CGRect(origin: origin, size: CGSize(width: width, height: height))
    canvas.ctx.setShadow(offset: CGSize(width: 0, height: 6), blur: 18, color: OfficeCanvas.rgb(0x000000, 0.55))
    canvas.ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 8, cornerHeight: 8, transform: nil))
    canvas.ctx.setFillColor(OfficeCanvas.rgb(0x2A2A2E, 0.97))
    canvas.ctx.fillPath()
    canvas.ctx.setShadow(offset: .zero, blur: 0, color: nil)
    canvas.ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
    canvas.ctx.setStrokeColor(OfficeCanvas.rgb(0xFFFFFF, 0.14))
    canvas.ctx.setLineWidth(1)
    canvas.ctx.strokePath()
    var y = panel.minY + 5
    for line in lines {
        if line.action == .separator {
            canvas.ctx.setFillColor(OfficeCanvas.rgb(0xFFFFFF, 0.12))
            canvas.ctx.fill(CGRect(x: panel.minX + 10, y: y + sepH / 2, width: width - 20, height: 1))
            y += sepH
            continue
        }
        if line.action == .changePet {
            canvas.ctx.addPath(CGPath(roundedRect: CGRect(x: panel.minX + 5, y: y, width: width - 10, height: rowH), cornerWidth: 5, cornerHeight: 5, transform: nil))
            canvas.ctx.setFillColor(OfficeCanvas.rgb(0x2F6FE4))
            canvas.ctx.fillPath()
        }
        canvas.text(line.title, in: CGRect(x: panel.minX + 16, y: y + 3, width: width - 28, height: rowH), size: 13, weight: .regular,
                    0xFFFFFF, line.enabled ? 0.92 : 0.32)
        y += rowH
    }
    write(canvas.image(), "zone-menu.png")
}

/// a crowded room for the checks and the stills: every state, a long line (the line full and three beyond it), all four
/// sofas full with one or two standing in front of each, Docs over twelve (its rest room), one checked in and one listed.
@MainActor func zoneOpenRoomCrowd() -> Store {
    let now = Date()
    let store = Store()
    store.readOnly = true
    var list: [Session] = []
    func add(_ name: String, _ status: String, ago: Double, seen: Bool = true, tool: String = "", asks: String = "", cwd: String? = nil) {
        var s = Session(id: "crowd-\(list.count)", pid: 1, project: name.split(separator: "-").dropFirst().first.map(String.init) ?? name, name: name, status: status,
                        since: now - ago, summary: asks.isEmpty ? "整理完了，结果在 report.md" : asks, waitingFor: status == "waiting" ? "permission prompt" : "")
        s.cwd = cwd ?? NSHomeDirectory() + "/Projects/" + name
        s.tool = tool
        list.append(s)
        if seen { store.seen[s.id] = now.timeIntervalSince1970 }
    }
    // Web: three at work, five done and not looked at (3 on the sofa, 2 standing in front), one seen, one long finished.
    add("Web-DEMO-应用", "busy", ago: 300, tool: "Bash")
    add("Web-UX-星图", "busy", ago: 200, tool: "Edit")
    add("Web-对星-九月", "busy", ago: 100, tool: "Read")
    for (i, n) in ["ABC-银河", "星门图册", "风铃历", "云端茶会", "萤火库"].enumerated() { add("Web-" + n, "idle", ago: Double(600 + i * 300), seen: false) }
    add("Web-星球漫游", "idle", ago: 1800)
    add("Web-旧任务", "idle", ago: 9 * 3600)
    // Ops: the lead at work, four done (3 seated, 1 standing), one seen.
    add("Ops-Demo-协同", "busy", ago: 400, tool: "Agent")
    for (i, n) in ["Demo-AI助手", "岛-风铃同步", "彩虹桥", "贝壳图鉴"].enumerated() { add("Ops-" + n, "idle", ago: Double(500 + i * 200), seen: false) }
    add("Ops-月影", "idle", ago: 3000)
    // Docs: twelve owners, eight more with no desk (rest room: six seated, "+2"); four done (3 seated, 1 standing).
    add("AI-lead", "busy", ago: 100, tool: "WebFetch")
    for i in 1...4 { add("AI-ML-服务\(i)", "busy", ago: Double(100 + i * 50), tool: ["Bash", "Edit", "Read", "Grep"][i % 4]) }
    for (i, n) in ["QA-风车塔", "QA-ORB", "QA-摆渡船", "ML-星环"].enumerated() { add("AI-" + n, "idle", ago: Double(800 + i * 100), seen: false) }
    for i in 1...3 { add("AI-QA-松果\(i)", "idle", ago: Double(4000 + i * 100)) }
    for i in 1...8 { add("AI-QA-云杉\(i)", i <= 2 ? "busy" : "idle", ago: Double(9000 + i * 100)) }
    // Infra: the lead seen, one at work, four done (3 seated, 1 standing).
    add("Home-lead", "idle", ago: 2000)
    add("Home-XR-萤火虫", "busy", ago: 150, tool: "Bash")
    for (i, n) in ["云朵", "星星收集", "数星", "听风"].enumerated() { add("Home-" + n, "idle", ago: Double(400 + i * 150), seen: false) }
    // Waiting: ten across the zones (the line full, three beyond it at their sofas' spots or desks).
    let asks = ["要你批准：npm test", "要你回答：端口用 8080 还是 9000？", "要你批准：git push origin main", "要你批准：docker compose up -d",
                "要你回答：先改哪一个？", "要你批准：rm -rf build", "要你批准：pip install -r requirements.txt", "要你回答：要不要重启服务？",
                "要你批准：brew upgrade", "要你回答：用哪个模型？"]
    for (i, name) in ["Home-demo-layout", "Web-DEMO-追踪", "Ops-Demo-清单", "Home-风向标", "AI-ML-星轨库", "Home-demo-network", "Home-星罐", "Ops-潮汐", "Home-彩虹小镇", "Ops-星报"].enumerated() {
        add(name, "waiting", ago: Double(4000 - i * 240), asks: asks[i])
    }
    // Unzoned: one on the check-in spot, one listed on its label.
    add("新会话1", "busy", ago: 60, cwd: "/tmp/新项目")
    add("新会话2", "idle", ago: 90, cwd: "/tmp/另一个")
    store.sessions = list
    store.assignPets()
    return store
}

/// `--zone-open-room-stills <dir>`: `zone-demo.png` (the crowded room at 3:2: a long line, all four sofas full with standing ones in
/// front, Docs over twelve and its rest room, check-in), `zone-demo-wide.png` (the same in a wider window, the bottom cut:
/// the sitters' plates over their heads), `zone-walk-strip.png` (a desk on an island to the rest corner and back, six
/// samples 0.1 s apart each).
@MainActor func zoneOpenRoomStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    let store = zoneOpenRoomCrowd()
    let size = CGSize(width: 1180, height: 790)
    write(zoneStill(store, size: size), "zone-demo.png")
    write(zoneStill(store, size: CGSize(width: 1180, height: 690)), "zone-demo-wide.png")
    let plan = ZonePlan.current(store, scene: ZoneArt.scene)
    print("zone stills: line \(plan.line.count) of \(ZoneArt.scene?.lineCapacity ?? 0), sofa \(plan.sofa.mapValues(\.count)), spots \(plan.sofaOverflow.mapValues(\.count)), rest \(plan.rest.count) + \(plan.restOverflow.count), check-in \(plan.visitor != nil ? 1 : 0) + \(plan.visitorList.count), +N \(plan.overflow.mapValues(\.count))")

    // A live walk, sampled from the presentation in a window: an Ops desk across the floor to the rest corner, then back.
    guard let scene = ZoneArt.scene, scene.restSeats.count >= 5 else { return }
    let now = Date()
    let walkStore = Store()
    walkStore.readOnly = true
    var walker = Session(id: "walker", pid: 1, project: "p", name: "Ops-Demo-协同", status: "busy", since: now - 30, summary: "")
    walker.cwd = "/tmp"
    walkStore.sessions = [walker]
    walkStore.assignPets()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    view.update(walkStore)
    let pet = view.pet(of: "walker") ?? ""
    let fit = ZoneFit(scene: scene.size, view: size)
    var cells: [(CGImage?, String)] = []
    func run(_ label: String, to target: CGPoint, lead: Double = 0) {
        view.probeWalk("walker", to: target)
        // A walk set off right after the last one ended shows its first frames a moment late; start sampling then.
        if lead > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: lead)) }
        let route = view.route(of: "walker"), rows = ZoneWalk.rows(route)
        let seconds = view.walkEnds(of: "walker") - CACurrentMediaTime()
        print(String(format: "zone stills: walk %@: %d legs, %.1f s, via %@", label, route.count - 1, seconds,
                     route.map { p -> String in let w = scene.walkMap?.world(fit.back(p)) ?? .zero; return String(format: "(%.1f,%.1f)", w.x, w.y) }.joined(separator: " ")))
        for sample in zoneWalkSamples(view, "walker", count: 6, every: 0.1) {
            var got = "?"
            for row in [0, 1, 2, 3, 6, 7] {
                for column in 0..<8 where OfficePets.shared.frame(pet, row: row, column: column)?.image === sample.frame { got = "\(row)-\(column)" }
            }
            // running frames by the facing they are for (the table may take them from another row, mirrored).
            for facing in [ZoneWalk.right, ZoneWalk.left] {
                for column in 0..<8 where OfficePets.shared.runFrame(pet, facing: facing, column: column)?.image === sample.frame { got = "\(facing)-\(column)" }
            }
            let leg = zoneLeg(route, at: sample.foot).map { rows[$0] } ?? -1
            cells.append((view.presentedCrop(around: sample.foot, side: 150), "\(label) row \(got) leg \(leg == ZoneWalk.right ? "→" : "←")"))
        }
    }
    let home = view.foot(of: "walker").map { fit.back($0) } ?? .zero
    run("to the rest room", to: scene.restSeats[4])
    // Back only once it has sat down, so the way back is the whole way.
    RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0.2, view.walkEnds(of: "walker") - CACurrentMediaTime() + 0.3)))
    run("back to desk", to: home, lead: 0.3)
    let cell: CGFloat = 150
    let canvas = OfficeCanvas(CGSize(width: cell * 6, height: (cell + 16) * 2))
    canvas.ctx.setFillColor(OfficeCanvas.rgb(0x15192B))
    canvas.ctx.fill(CGRect(x: 0, y: 0, width: cell * 6, height: (cell + 16) * 2))
    for (i, c) in cells.enumerated() {
        let x = CGFloat(i % 6) * cell, y = CGFloat(i / 6) * (cell + 16)
        if let image = c.0 {
            canvas.ctx.saveGState()
            canvas.ctx.translateBy(x: x, y: y + cell)
            canvas.ctx.scaleBy(x: 1, y: -1)
            canvas.ctx.draw(image, in: CGRect(x: 0, y: 0, width: cell, height: cell))
            canvas.ctx.restoreGState()
        }
        canvas.text(c.1, in: CGRect(x: x, y: y + cell + 1, width: cell, height: 14), size: 9, weight: .semibold, 0xFFFFFF, align: .center)
    }
    write(canvas.image(), "zone-walk-strip.png")
    print("zone stills: walk cells \(cells.map(\.1))")
    window.orderOut(nil)
    window.contentView = nil
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// `--zone-art-stills <dir>`: `zone-demo.png` (every state, a long line along the bottom, the L of sofas with unread sitters
/// and standing ones, a zone over twelve and its rest room, check-in), `zone-signs-2x.png` (the four labels at 2×, plain and
/// busy variants), `zone-walk-strip.png` (two live walks, six samples 0.1 s apart each).
@MainActor func zoneArtStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let now = Date()
    let store = Store()
    store.readOnly = true
    var list: [Session] = []
    func add(_ name: String, _ status: String, ago: Double, seen: Bool = true, tool: String = "", asks: String = "", cwd: String? = nil) {
        var s = Session(id: "demo-\(list.count)", pid: 1, project: name.split(separator: "-").dropFirst().first.map(String.init) ?? name, name: name, status: status,
                        since: now - ago, summary: asks.isEmpty ? "整理完了，结果在 report.md" : asks, waitingFor: status == "waiting" ? "permission prompt" : "")
        s.cwd = cwd ?? NSHomeDirectory() + "/Projects/" + name
        s.tool = tool
        list.append(s)
        if seen { store.seen[s.id] = now.timeIntervalSince1970 }
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    // Web: three at work, four done and not looked at (3 on the sofa, one standing in front), one seen, one long finished.
    add("Web-DEMO-应用", "busy", ago: 300, tool: "Bash")
    add("Web-UX-星图", "busy", ago: 200, tool: "Edit")
    add("Web-对星-九月", "busy", ago: 100, tool: "Read")
    add("Web-ABC-银河", "idle", ago: 900, seen: false)
    add("Web-星门图册", "idle", ago: 600, seen: false)
    add("Web-风铃历", "idle", ago: 1200, seen: false)
    add("Web-云端茶会", "idle", ago: 1500, seen: false)
    add("Web-星球漫游", "idle", ago: 1800)
    add("Web-旧任务", "idle", ago: 9 * 3600)
    // Ops: the lead at work, two done (sofa), two seen.
    add("Ops-Demo-协同", "busy", ago: 400, tool: "Agent")
    add("Ops-Demo-AI助手", "idle", ago: 500, seen: false)
    add("Ops-岛-风铃同步", "idle", ago: 700, seen: false)
    add("Ops-彩虹桥", "idle", ago: 3000)
    add("Ops-贝壳图鉴", "idle", ago: 20 * 3600)
    // Docs: twelve owners, then eight more with no desk (rest room: six seated, "+2"); one done (its sofa).
    add("AI-lead", "busy", ago: 100, tool: "WebFetch")
    for i in 1...6 { add("AI-ML-服务\(i)", "busy", ago: Double(100 + i * 50), tool: ["Bash", "Edit", "Read", "Grep", "", "Bash"][i % 6]) }
    for i in 1...4 { add("AI-QA-松果\(i)", "idle", ago: Double(4000 + i * 100)) }
    add("AI-QA-风车塔", "idle", ago: 800, seen: false)
    for i in 1...8 { add("AI-QA-云杉\(i)", i <= 2 ? "busy" : "idle", ago: Double(9000 + i * 100)) }
    // Infra: the lead seen, one at work, one done; and the waiting ones, eleven across the zones (the line full, the rest beyond it).
    add("Home-lead", "idle", ago: 2000)
    add("Home-XR-萤火虫", "busy", ago: 150, tool: "Bash")
    add("Home-云朵", "idle", ago: 400, seen: false)
    let asks = ["要你批准：npm test", "要你回答：端口用 8080 还是 9000？", "要你批准：git push origin main", "要你批准：docker compose up -d",
                "要你回答：先改哪一个？", "要你批准：rm -rf build", "要你批准：pip install -r requirements.txt", "要你回答：要不要重启服务？",
                "要你批准：brew upgrade", "要你回答：用哪个模型？", "要你批准：ssh demo-b"]
    for (i, name) in ["Home-demo-plan", "Web-DEMO-追踪", "Ops-Demo-清单", "Home-风向标", "AI-ML-星轨库", "Home-demo-network", "Home-星罐", "Ops-潮汐", "Home-星星", "Ops-星报", "Home-彩虹小镇"].enumerated() {
        add(name, "waiting", ago: Double(4000 - i * 240), asks: asks[i])
    }
    // Unzoned: one on the check-in spot, one listed on its label.
    add("新会话1", "busy", ago: 60, cwd: "/tmp/新项目")
    add("新会话2", "idle", ago: 90, cwd: "/tmp/另一个")
    store.sessions = list
    store.assignPets()
    let size = CGSize(width: 1180, height: 790)
    write(zoneStill(store, size: size), "zone-demo.png")
    let plan = ZonePlan.current(store, scene: ZoneArt.scene)
    print("zone stills: line \(plan.line.count) of \(ZoneArt.scene?.lineCapacity ?? 0), sofa \(plan.sofa.mapValues(\.count)), spots \(plan.sofaOverflow.mapValues(\.count)), rest \(plan.rest.count) + \(plan.restOverflow.count), check-in \(plan.visitor != nil ? 1 : 0) + \(plan.visitorList.count), +N \(plan.overflow.mapValues(\.count))")

    // The labels at 2×: the four zones as the demo shows them, then the same with other counts, on the room's floor colour.
    let config = ZoneConfigFile.current()
    let h = ZoneGlow.signHeight(scale: 0.49)
    let rows: [[(String, Int, Int, Bool, UInt32)]] = [
        [("Web", 10, 0, true, 0xE0A040), ("Ops", 8, 0, true, 0x40B0A0), ("Docs", 21, 8, true, 0x5080D0), ("Infra", 9, 0, true, 0xA070D0)],
        [("Web", 3, 0, false, 0xE0A040), ("Ops", 12, 0, false, 0x40B0A0), ("Docs", 12, 0, false, 0x5080D0), ("Infra", 1, 0, false, 0xA070D0)],
        [("报到", 2, 1, false, 0x9AA7BC), ("Web", 0, 0, false, config.zone("Web")?.color ?? 0xE0A040), ("Ops", 13, 1, true, 0x40B0A0), ("Docs", 104, 92, false, 0x5080D0)],
    ]
    let cellW: CGFloat = 170, cellH: CGFloat = h * 2.4
    let sheet = OfficeCanvas(CGSize(width: cellW * 4 + 20, height: cellH * CGFloat(rows.count) + 20))
    sheet.ctx.setFillColor(OfficeCanvas.rgb(0x6B4A33))
    sheet.ctx.fill(CGRect(x: 0, y: 0, width: cellW * 4 + 20, height: cellH * CGFloat(rows.count) + 20))
    for (r, row) in rows.enumerated() {
        for (c, item) in row.enumerated() {
            let drawn = ZoneGlow.sign(item.0, count: item.1, extra: item.2, calling: item.3, color: item.4, height: h)
            let midX = 10 + cellW * (CGFloat(c) + 0.5), midY = 10 + cellH * (CGFloat(r) + 0.5)
            if r == 0 {
                sheet.ctx.setFillColor(OfficeCanvas.rgb(0xFFFFFF, 0.25))
                sheet.ctx.fill(CGRect(x: midX - 0.25, y: midY - h, width: 0.5, height: h * 2))
            }
            if let image = drawn.image {
                let at = CGRect(x: midX - drawn.layout.pill.midX, y: midY - drawn.layout.pill.midY, width: drawn.size.width, height: drawn.size.height)
                sheet.image(image, in: at)
            }
        }
    }
    if let image = sheet.image() {
        // Twice again, so a pixel of the labels is plain to see.
        let big = CGContext(data: nil, width: image.width * 2, height: image.height * 2, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        big?.interpolationQuality = .none
        big?.draw(image, in: CGRect(x: 0, y: 0, width: image.width * 2, height: image.height * 2))
        write(big?.makeImage(), "zone-signs-2x.png")
    }

    // Two live walks, sampled from the presentation in a window: a desk on the right to the head of the line, then back.
    guard let scene = ZoneArt.scene else { return }
    let walkStore = Store()
    walkStore.readOnly = true
    var walker = Session(id: "walker", pid: 1, project: "p", name: "Home-XR-萤火虫", status: "busy", since: now - 30, summary: "")
    walker.cwd = "/tmp"
    walkStore.sessions = [walker]
    walkStore.assignPets()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    view.update(walkStore)
    let pet = view.pet(of: "walker") ?? ""
    var cells: [(CGImage?, String)] = []
    func run(_ label: String, to target: CGPoint) {
        view.probeWalk("walker", to: target)
        let route = view.route(of: "walker"), rows = ZoneWalk.rows(route)
        let seconds = view.walkEnds(of: "walker") - CACurrentMediaTime()
        print(String(format: "zone stills: walk %@: %d legs, %.1f s", label, route.count - 1, seconds))
        for sample in zoneWalkSamples(view, "walker", count: 6, every: 0.1) {
            var got = "?"
            for row in [0, 1, 2, 3, 6, 7] {
                for column in 0..<8 where OfficePets.shared.frame(pet, row: row, column: column)?.image === sample.frame { got = "\(row)-\(column)" }
            }
            // running frames by the facing they are for (the table may take them from another row, mirrored).
            for facing in [ZoneWalk.right, ZoneWalk.left] {
                for column in 0..<8 where OfficePets.shared.runFrame(pet, facing: facing, column: column)?.image === sample.frame { got = "\(facing)-\(column)" }
            }
            let leg = zoneLeg(route, at: sample.foot).map { rows[$0] } ?? -1
            cells.append((view.presentedCrop(around: sample.foot, side: 150), "\(label) row \(got) leg \(leg == ZoneWalk.right ? "→" : "←")"))
        }
    }
    let home = view.foot(of: "walker").map { ZoneFit(scene: scene.size, view: size).back($0) } ?? .zero
    if let queue = scene.queue {
        run("to the queue", to: queue)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        run("back to desk", to: home)
    }
    let cell: CGFloat = 150
    let canvas = OfficeCanvas(CGSize(width: cell * 6, height: (cell + 16) * 2))
    canvas.ctx.setFillColor(OfficeCanvas.rgb(0x15192B))
    canvas.ctx.fill(CGRect(x: 0, y: 0, width: cell * 6, height: (cell + 16) * 2))
    for (i, c) in cells.enumerated() {
        let x = CGFloat(i % 6) * cell, y = CGFloat(i / 6) * (cell + 16)
        if let image = c.0 {
            canvas.ctx.saveGState()
            canvas.ctx.translateBy(x: x, y: y + cell)
            canvas.ctx.scaleBy(x: 1, y: -1)
            canvas.ctx.draw(image, in: CGRect(x: 0, y: 0, width: cell, height: cell))
            canvas.ctx.restoreGState()
        }
        canvas.text(c.1, in: CGRect(x: x, y: y + cell + 1, width: cell, height: 14), size: 9, weight: .semibold, 0xFFFFFF, align: .center)
    }
    write(canvas.image(), "zone-walk-strip.png")
    print("zone stills: walk cells \(cells.map(\.1))")
    window.orderOut(nil)
    window.contentView = nil
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// A walk's frames as Core Animation shows them: `count` samples `every` seconds apart, each the sprite's frame, the
/// figure's foot and the media time.
@MainActor func zoneWalkSamples(_ view: ZoneView, _ id: String, count: Int, every: Double) -> [(frame: CGImage?, foot: CGPoint, at: CFTimeInterval)] {
    CATransaction.flush()
    var samples: [(frame: CGImage?, foot: CGPoint, at: CFTimeInterval)] = []
    let first = CACurrentMediaTime()
    for i in 0..<count {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, first + Double(i) * every + 0.05 - CACurrentMediaTime())))
        samples.append((view.shownFrame(of: id), view.shownFoot(of: id) ?? .zero, CACurrentMediaTime()))
    }
    return samples
}

func zoneLeg(_ route: [CGPoint], at p: CGPoint) -> Int? { zoneProbeLeg(route, at: p) }

/// `--zone-placement-stills <dir>`: the pictures for review. `zone-demo.png`, every row of the table at once (busy at desks, unread
/// on the sofas, seen and long-finished at their desks, a line of six and more waiting, a zone with no desks left and its
/// rest room, two unzoned); `zone-search.png`, the title bar's search open over it; `zone-walk-strip.png`, two live walks
/// (left, then right) sampled six times 0.1 s apart from Core Animation's presentation in a window.
@MainActor func zonePlacementStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let now = Date()
    let store = Store()
    store.readOnly = true
    var list: [Session] = []
    func add(_ name: String, _ status: String, ago: Double, seen: Bool = true, tool: String = "", asks: String = "", cwd: String? = nil) {
        var s = Session(id: "demo-\(list.count)", pid: 1, project: name.split(separator: "-").dropFirst().first.map(String.init) ?? name, name: name, status: status,
                        since: now - ago, summary: asks.isEmpty ? "整理完了，结果在 report.md" : asks, waitingFor: status == "waiting" ? "permission prompt" : "")
        s.cwd = cwd ?? NSHomeDirectory() + "/Projects/" + name
        s.tool = tool
        list.append(s)
        if seen { store.seen[s.id] = now.timeIntervalSince1970 }
    }
    // Web: the lead and two at work, three done and not looked at (sofa), one seen, one finished long ago.
    add("Web-DEMO-应用", "busy", ago: 300, tool: "Bash")
    add("Web-UX-星图", "busy", ago: 200, tool: "Edit")
    add("Web-对星-九月", "busy", ago: 100, tool: "Read")
    add("Web-ABC-银河", "idle", ago: 900, seen: false)
    add("Web-星门图册", "idle", ago: 600, seen: false)
    add("Web-风铃历", "idle", ago: 1200, seen: false)
    add("Web-星球漫游", "idle", ago: 1800)
    add("Web-旧任务", "idle", ago: 9 * 3600)
    // Ops: the lead at work, two done (sofa), two seen.
    add("Ops-Demo-协同", "busy", ago: 400, tool: "Agent")
    add("Ops-Demo-AI助手", "idle", ago: 500, seen: false)
    add("Ops-岛-风铃同步", "idle", ago: 700, seen: false)
    add("Ops-彩虹桥", "idle", ago: 3000)
    add("Ops-贝壳图鉴", "idle", ago: 20 * 3600)
    // Docs: ten owners, then eight more with no desk (rest room: six seated, "+2").
    add("AI-lead", "busy", ago: 100, tool: "WebFetch")
    for i in 1...5 { add("AI-ML-服务\(i)", "busy", ago: Double(100 + i * 50), tool: ["Bash", "Edit", "Read", "Grep", ""][i % 5]) }
    for i in 1...4 { add("AI-QA-松果\(i)", "idle", ago: Double(4000 + i * 100)) }
    for i in 1...8 { add("AI-QA-云杉\(i)", i <= 2 ? "busy" : "idle", ago: Double(9000 + i * 100)) }
    // Infra: the lead seen, one at work; and the waiting ones, eight across the zones (six in the line, two beyond it).
    add("Home-lead", "idle", ago: 2000)
    add("Home-XR-萤火虫", "busy", ago: 150, tool: "Bash")
    let asks = ["要你批准：npm test", "要你回答：端口用 8080 还是 9000？", "要你批准：git push origin main", "要你批准：docker compose up -d",
                "要你回答：先改哪一个？", "要你批准：rm -rf build", "要你批准：pip install -r requirements.txt", "要你回答：要不要重启服务？"]
    for (i, name) in ["Home-demo-floor", "Web-DEMO-追踪", "Ops-Demo-清单", "Home-风向标", "AI-ML-星轨库", "Home-demo-network", "Home-星罐", "Ops-潮汐"].enumerated() {
        add(name, "waiting", ago: Double(2400 - i * 240), asks: asks[i])
    }
    // Unzoned: one on the check-in spot, one listed on its label.
    add("新会话1", "busy", ago: 60, cwd: "/tmp/新项目")
    add("新会话2", "idle", ago: 90, cwd: "/tmp/另一个")
    store.sessions = list
    store.assignPets()
    let size = CGSize(width: 1180, height: 790)
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    write(zoneStill(store, size: size), "zone-demo.png")
    let plan = ZonePlan.current(store, scene: ZoneArt.scene)
    print("zone stills: line \(plan.line.count), sofa \(plan.sofa.mapValues(\.count)), spots \(plan.sofaOverflow.mapValues(\.count)), rest \(plan.rest.count) + \(plan.restOverflow.count), check-in \(plan.visitor != nil ? 1 : 0) + \(plan.visitorList.count)")

    // The search, open over the room, the title strip above as the window shows it.
    if let room = zoneStill(store, size: size) {
        store.officeFits = true
        let wasOffice = UserDefaults.standard.object(forKey: "office"), wasTheme = UserDefaults.standard.object(forKey: "officeTheme")
        UserDefaults.standard.set(true, forKey: "office")
        UserDefaults.standard.set(OfficeTheme.zone.name, forKey: "officeTheme")
        store.searchOpen = true
        let shot = VStack(spacing: 0) {
            HStack { CountsBar(store: store).padding(.leading, 70); Spacer(); ActionsBar(store: store) }
                .frame(width: size.width, height: 28).background(night)
            ZStack(alignment: .topTrailing) {
                Image(decorative: room, scale: 2)
                SearchPanel(store: store, query: "ai").padding(.top, 6).padding(.trailing, 10)
            }
            .frame(width: size.width, height: size.height)
        }
        .environmentObject(store).environment(\.zoom, 1).environment(\.still, true).environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: shot)
        renderer.scale = 2
        write(renderer.cgImage, "zone-search.png")
        for (key, value) in [("office", wasOffice), ("officeTheme", wasTheme)] {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        store.searchOpen = false
    }

    // Two live walks, sampled from the presentation in a window: a desk on the right to the queue (left), then back (right).
    guard let scene = ZoneArt.scene else { return }
    let walkStore = Store()
    walkStore.readOnly = true
    var walker = Session(id: "walker", pid: 1, project: "p", name: "Home-XR-萤火虫", status: "busy", since: now - 30, summary: "")
    walker.cwd = "/tmp"
    walkStore.sessions = [walker]
    walkStore.assignPets()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    view.update(walkStore)
    let pet = view.pet(of: "walker") ?? ""
    var cells: [(CGImage?, String)] = []
    func run(_ label: String, to target: CGPoint) {
        view.probeWalk("walker", to: target)
        let route = view.route(of: "walker"), rows = ZoneWalk.rows(route)
        for sample in zoneWalkSamples(view, "walker", count: 6, every: 0.1) {
            var got = "?"
            for row in [0, 1, 2, 3, 6, 7] {
                for column in 0..<8 where OfficePets.shared.frame(pet, row: row, column: column)?.image === sample.frame { got = "\(row)-\(column)" }
            }
            // running frames by the facing they are for (the table may take them from another row, mirrored).
            for facing in [ZoneWalk.right, ZoneWalk.left] {
                for column in 0..<8 where OfficePets.shared.runFrame(pet, facing: facing, column: column)?.image === sample.frame { got = "\(facing)-\(column)" }
            }
            let leg = zoneLeg(route, at: sample.foot).map { rows[$0] } ?? -1
            cells.append((view.presentedCrop(around: sample.foot, side: 150), "\(label) row \(got) leg \(leg == ZoneWalk.right ? "→" : "←")"))
        }
    }
    let home = view.foot(of: "walker").map { ZoneFit(scene: scene.size, view: size).back($0) } ?? .zero
    if let queue = scene.queue {
        run("to the queue", to: queue)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        run("back to desk", to: home)
    }
    let cell: CGFloat = 150
    let canvas = OfficeCanvas(CGSize(width: cell * 6, height: (cell + 16) * 2))
    canvas.ctx.setFillColor(OfficeCanvas.rgb(0x15192B))
    canvas.ctx.fill(CGRect(x: 0, y: 0, width: cell * 6, height: (cell + 16) * 2))
    for (i, c) in cells.enumerated() {
        let x = CGFloat(i % 6) * cell, y = CGFloat(i / 6) * (cell + 16)
        if let image = c.0 {
            canvas.ctx.saveGState()
            canvas.ctx.translateBy(x: x, y: y + cell)
            canvas.ctx.scaleBy(x: 1, y: -1)
            canvas.ctx.draw(image, in: CGRect(x: 0, y: 0, width: cell, height: cell))
            canvas.ctx.restoreGState()
        }
        canvas.text(c.1, in: CGRect(x: x, y: y + cell + 1, width: cell, height: 14), size: 9, weight: .semibold, 0xFFFFFF, align: .center)
    }
    write(canvas.image(), "zone-walk-strip.png")
    print("zone stills: walk cells \(cells.map(\.1))")
    window.orderOut(nil)
    window.contentView = nil
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
}

/// right-click → bigger / smaller / reset size on a Seaview figure: five steps (0.75…1.3), kept by name on disk; the
/// plate, the hit test and the rest follow the sprite.
@MainActor func zoneFigureSizeTests() {
    guard let scene = ZoneArt.scene else {
        check("zone pet size: the art", false)
        return
    }
    let defaults = UserDefaults.standard
    let keys = ["zoneFigureSize", "zoneFigureSizeOrder", "office", "officeTheme", ZoneMemory.key]
    let kept = keys.map { defaults.object(forKey: $0) }
    for key in keys { defaults.removeObject(forKey: key) }
    ZoneMemory.remembered = [:]
    OfficePets.shared.synchronous = true
    defer {
        OfficePets.shared.synchronous = false
        for (key, value) in zip(keys, kept) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        ZoneMemory.remembered = [:]
    }
    let now = Date()
    func s(_ name: String, id: String? = nil, named: Bool = true) -> Session {
        var made = Session(id: id ?? "size-" + name, pid: 1, project: "p", name: name, status: "busy", since: now - 30, summary: "在做事")
        made.cwd = "/tmp"
        if named { made.registryName = name }
        return made
    }
    func menu(_ store: Store, _ x: Session, theme: String?) -> [String: Bool] {
        defaults.set(theme != nil, forKey: "office")
        if let theme { defaults.set(theme, forKey: "officeTheme") }
        var result: [String: Bool] = [:]
        for line in sessionMenu(store, x) where [.sizeUp, .sizeDown, .sizeReset].contains(line.action) { result[line.title] = line.enabled }
        return result
    }
    let zone = OfficeTheme.zone.name
    let store = Store()   // not read-only: the sizes are written to disk
    let a = s("Web-a"), b = s("Web-b"), c = s("Web-c"), lead = s("Web-L"), guest = s("新会话", id: "size-guest", named: false)
    store.sessions = [lead, a, b, c, guest]
    store.seen = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, now.timeIntervalSince1970) })
    store.assignPets()

    // The steps and their ends.
    let fresh = menu(store, a, theme: zone)
    check("zone pet size: at the default size the menu has bigger and smaller, both on, and no reset size",
        fresh == ["放大一点": true, "缩小一点": true] && store.figureSize(a) == 1)
    let ups = (1...3).map { _ in store.resizeFigure(a, by: 1) }
    let top = menu(store, a, theme: zone)
    check("zone pet size: bigger goes 1.15 then 1.3, and stops there; at the top it is greyed and reset size shows",
        ups == [true, true, false] && store.figureSize(a) == 1.3 && top == ["放大一点": false, "缩小一点": true, "恢复默认大小": true])
    let downs = (1...5).map { _ in store.resizeFigure(a, by: -1) }
    let bottom = menu(store, a, theme: zone)
    check("zone pet size: smaller steps down through 1.15, 1, 0.85 to 0.75, and stops there; at the bottom it is greyed",
        downs == [true, true, true, true, false] && store.figureSize(a) == 0.75
            && bottom == ["放大一点": true, "缩小一点": false, "恢复默认大小": true])
    store.resetFigureSize(a)
    let saved = defaults.dictionary(forKey: "zoneFigureSize") as? [String: Int]
    check("zone pet size: reset size sets it back to 1, the line goes, and nothing is kept for it",
        store.figureSize(a) == 1 && menu(store, a, theme: zone) == ["放大一点": true, "缩小一点": true] && saved?["Web-a"] == nil)
    check("zone pet size: the size lines are in Seaview only (not the office or the board)",
        menu(store, a, theme: OfficeTheme.studio.name).isEmpty && menu(store, a, theme: nil).isEmpty)
    defaults.set(true, forKey: "office")
    defaults.set(zone, forKey: "officeTheme")
    let order = sessionMenu(store, a).map(\.action).suffix(3)
    check("zone pet size: the size lines come last, after a separator", Array(order) == [.separator, .sizeUp, .sizeDown])

    // Kept on disk by name (window swap: a new id), else by id.
    store.resizeFigure(a, by: 1)
    store.resizeFigure(a, by: 1)
    store.resizeFigure(guest, by: -1)
    let reopened = Store()
    reopened.readOnly = true
    let a2 = s("Web-a", id: "size-new-a")
    reopened.sessions = [a2, guest]
    check("zone pet size: the size is kept on disk by session name, so after a restart and window swap (a new id) it is the same",
        reopened.figureSize(a2) == 1.3 && (defaults.dictionary(forKey: "zoneFigureSize") as? [String: Int])?["Web-a"] == 2)
    check("zone pet size: a session with no name keeps its size by id", reopened.figureSize(guest) == 0.85 && reopened.figureSize(s("新会话", id: "size-other", named: false)) == 1)

    // The view: the sprite scales; the plate stays under the feet as at the default; the hit test uses the scaled frame.
    store.resetFigureSize(a)
    store.resetFigureSize(guest)
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    func box(_ id: String) -> CGRect? {
        guard let sprite = view.sprite(of: id), let foot = view.foot(of: id) else { return nil }
        return sprite.frame.offsetBy(dx: foot.x, dy: foot.y)
    }
    func plateGap(_ id: String) -> CGFloat? {
        guard let plate = view.plateFrame(of: id), let foot = view.foot(of: id) else { return nil }
        return plate.minY - foot.y
    }
    let before = [a.id: box(a.id), b.id: box(b.id), c.id: box(c.id)], gaps = [a.id: plateGap(a.id), b.id: plateGap(b.id)]
    let aBox = before[a.id] ?? nil
    let probe = aBox.map { CGPoint(x: $0.midX, y: $0.minY - $0.height * 0.12) } ?? CGPoint(x: -100, y: -100)
    let probeBefore = view.card(at: probe)
    store.resizeFigure(a, by: 1)
    store.resizeFigure(a, by: 1)
    store.resizeFigure(b, by: -1)
    store.resizeFigure(b, by: -1)
    view.update(store)
    func ratio(_ id: String) -> CGFloat {
        guard let old = before[id] ?? nil, let new = box(id), old.height > 0 else { return 0 }
        return new.height / old.height
    }
    check("zone pet size: in the room the sprite is drawn 1.3× and 0.75× the default; another figure is unchanged",
        abs(ratio(a.id) - 1.3) < 0.01 && abs(ratio(b.id) - 0.75) < 0.01 && abs(ratio(c.id) - 1) < 0.001)
    let footA = view.foot(of: a.id), spriteA = box(a.id)
    check("zone pet size: the scaled sprite still stands on its feet (its spot unchanged), its plate under the feet as at the default",
        plateGap(a.id) == gaps[a.id] && plateGap(b.id) == gaps[b.id] && plateGap(a.id) != nil
            && view.plateFrame(of: a.id).map { p in spriteA.map { p.minY >= $0.maxY - $0.height * 0.2 } ?? false } == true
            && footA != nil)
    check("zone pet size: the hit test uses the scaled frame: a point just over its default head now finds it",
        probeBefore != a.id && view.card(at: probe) == a.id && spriteA.map { $0.contains(probe) } == true)
    let shrunk = box(b.id)
    let gone = shrunk.map { CGPoint(x: $0.midX, y: $0.minY - 3) } ?? CGPoint(x: -100, y: -100)
    let bBox = before[b.id] ?? nil
    check("zone pet size: shrunk, the point just over its smaller head does not find it (it is only inside the default frame)",
        bBox.map { $0.contains(gone) } == true && view.drawnPet(at: gone) != b.id)

    // The cap: 400 names at most, the one changed first goes, never one still open.
    for key in ["zoneFigureSize", "zoneFigureSizeOrder"] { defaults.removeObject(forKey: key) }
    let capped = Store()
    let first = s("cap-0")
    capped.sessions = [first]
    capped.resizeFigure(first, by: 1)
    for i in 1...404 { capped.resizeFigure(s("cap-\(i)"), by: 1) }
    let held = defaults.dictionary(forKey: "zoneFigureSize") as? [String: Int] ?? [:]
    check("zone pet size: at most 400 sizes are kept; the oldest closed ones go, an open one stays",
        held.count == 400 && held["cap-0"] == 1 && held["cap-1"] == nil && held["cap-404"] == 1)
}

/// a still: one Web figure at 1.3, one at 0.75, the rest at the default.
@MainActor func zoneFigureSizeStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    defer {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    guard ZoneArt.scene != nil else { return }
    let store = zoneOpenRoomCrowd()   // read-only: the sizes stay in memory
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    let atDesks = store.sessions.filter { x in
        x.name.hasPrefix("Web-") && view.plan.desks[x.id].map { $0.index >= 2 && view.plan.place[x.id] == .desk($0) } == true
    }
        .sorted { (view.plan.desks[$0.id]?.index ?? 0) < (view.plan.desks[$1.id]?.index ?? 0) }
    guard atDesks.count >= 3 else { return print("zone stills: too few Web figures at desks") }
    let big = atDesks[0], small = atDesks[2]
    store.resizeFigure(big, by: 1)
    store.resizeFigure(big, by: 1)
    store.resizeFigure(small, by: -1)
    store.resizeFigure(small, by: -1)
    view.update(store)
    print("zone stills: \(big.name) at \(store.figureSize(big)) on \(view.plan.desks[big.id]?.key ?? "-"), \(small.name) at \(store.figureSize(small)) on \(view.plan.desks[small.id]?.key ?? "-"), between them \(atDesks[1].name) at \(store.figureSize(atDesks[1]))")
    let picture = view.image()
    write(picture, "zone-sizes.png")
    if let picture, let p = view.foot(of: big.id), let q = view.foot(of: small.id) {
        let box = CGRect(x: min(p.x, q.x) - 140, y: min(p.y, q.y) - 200, width: abs(p.x - q.x) + 280, height: abs(p.y - q.y) + 260)
            .intersection(CGRect(origin: .zero, size: size))
        write(picture.cropping(to: CGRect(x: box.minX * 2, y: box.minY * 2, width: box.width * 2, height: box.height * 2)), "zone-sizes-zoom.png")
    }
}

// ───────── the living outdoors ─────────

/// A pixel's alpha (0…255) in a picture, rows from the top.
@MainActor private func zoneOutdoorsAlpha(_ image: CGImage, _ x: Int, _ y: Int) -> Int {
    var pixel = [UInt8](repeating: 0, count: 4)
    guard let c = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return -1 }
    c.draw(image, in: CGRect(x: -CGFloat(x), y: -CGFloat(image.height - 1 - y), width: CGFloat(image.width), height: CGFloat(image.height)))
    return Int(pixel[3])
}

/// The way a layer's transform takes a vector (Core Animation's row-vector convention).
private func zoneOutdoorsApply(_ t: CATransform3D, _ v: CGVector) -> CGVector {
    CGVector(dx: v.dx * t.m11 + v.dy * t.m21, dy: v.dx * t.m12 + v.dy * t.m22)
}

@MainActor func zoneOutdoorsTests() {
    guard ZoneArt.scene != nil, let spec = ZoneOutdoorArt.spec else {
        check("zone outdoors: the outdoor art (outdoor.json)", false)
        return
    }
    let picture = CGRect(origin: .zero, size: spec.picture)

    // ── The art ──
    check("zone outdoors: outdoor.json reads: the loop over 460…2400 × 0…640 (288 frames at 24), 105 px a metre",
        spec.loopBox == CGRect(x: 460, y: 0, width: 1940, height: 640) && spec.loopFrames == 288 && spec.fps == 24 && abs(spec.pixelsPerMetre - 105.4748) < 0.01)
    let first = ZoneOutdoorArt.frame(at: 0)
    check("zone outdoors: the sprites (6 a crab species, 48 a gull species) and the loop are there; its first frame is 1940×640 with alpha, clear indoors and solid on the sea",
        spec.crabs.indices.allSatisfy { ZoneOutdoorArt.crabFrames($0).count == 6 } && spec.gulls.indices.allSatisfy { ZoneOutdoorArt.gullFrames($0).count == 48 }
            && ZoneOutdoorArt.movie != nil
            && first.map { $0.width == 1940 && $0.height == 640 && zoneOutdoorsAlpha($0, 20, 620) == 0 && zoneOutdoorsAlpha($0, 1800, 60) == 255 } == true)

    // ── The layers ──
    let size = CGSize(width: 1180, height: 790)
    let fit = ZoneFit(scene: spec.picture, view: size)
    let store = zoneOpenRoomCrowd()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.calmOverride = false
    view.onScreenOverride = false
    view.update(store)
    let names = view.layer?.sublayers?.map { $0.name ?? "" } ?? []
    func at(_ name: String) -> Int { names.firstIndex(of: name) ?? -1 }
    check("zone outdoors: the layers go base < sea < crabs < orca < screens/LEDs < figures < plates < speech < signs < gulls < the title bar's shade (the top one)",
        at("base") == 0 && at("base") < at("sea") && at("sea") < at("beach") && at("beach") < at("orca") && at("orca") < at("lights") && at("lights") < at("stage")
            && at("stage") < at("plates") && at("plates") < at("speech") && at("speech") < at("boards") && at("gulls") == names.count - 2
            && at("titleShade") == names.count - 1)
    let box = fit.rect(spec.loopBox), seaFrame = view.outdoor.sea.frame
    check("zone outdoors: the sea's layer covers the loop's box through the room's fit (the picture's pixels land on the picture)",
        abs(seaFrame.minX - box.minX) < 1e-6 && abs(seaFrame.minY - box.minY) < 1e-6 && abs(seaFrame.width - box.width) < 1e-6
            && abs(seaFrame.height - box.height) < 1e-6 && abs(box.width / 1940 - fit.scale) < 1e-9)
    check("zone outdoors: unseen, the loop is not playing and no player is made yet", !view.outdoor.running && !view.outdoor.playing && view.outdoor.player == nil)
    view.onScreenOverride = true
    view.syncOutdoor()
    let shown = view.outdoor.playerLayer
    check("zone outdoors: seen, the loop plays, muted, in an AVPlayerLayer filling the sea's layer (resized), looped by AVPlayerLooper",
        view.outdoor.running && view.outdoor.playing && view.outdoor.player?.isMuted == true && shown?.superlayer === view.outdoor.sea
            && shown?.frame == view.outdoor.sea.bounds && shown?.videoGravity == .resize
            && view.outdoor.player?.preventsDisplaySleepDuringVideoPlayback == false)
    view.onScreenOverride = false
    view.syncOutdoor()
    let hiddenPaused = !view.outdoor.running && !view.outdoor.playing && view.outdoor.player != nil
    view.onScreenOverride = true
    view.syncOutdoor()
    let againPlaying = view.outdoor.playing
    view.stopListening()
    check("zone outdoors: hidden it pauses (the player kept), seen again it plays on, and leaving the theme (stopListening) pauses it",
        hiddenPaused && againPlaying && !view.outdoor.playing)
    let windowless = ZoneView(frame: CGRect(origin: .zero, size: size))
    windowless.calmOverride = false
    windowless.update(store)
    check("zone outdoors: a room in no window does not play (nobody sees it)", !windowless.outdoorSeen && !windowless.outdoor.running && windowless.outdoor.player == nil)

    // ── Crabs (each species on its own beach, with its own walk and pace) ──
    var rng = ZoneRandom(seed: 7)
    var beachOK = true, inside = true, whole = true, facingMatches = true, lengths = true, facings = Set<CGFloat>()
    let room = picture.intersection(spec.loopBox)
    for crab in spec.crabs {
        let beach = crab.beach, clipped = crab.clippedZone
        if !(beach.count >= 3 && clipped.count >= 3 && beach.allSatisfy({ ZoneOutdoorGeometry.contains(clipped, $0) && room.insetBy(dx: -1e-6, dy: -1e-6).contains($0) })
            && crab.zone.contains { !picture.contains($0) }) { beachOK = false }
        func crabBox(_ p: CGPoint) -> CGRect { CGRect(x: p.x - crab.foot.x, y: p.y - crab.foot.y, width: crab.size.width, height: crab.size.height) }
        var p = ZoneOutdoorGeometry.randomPoint(in: beach, using: &rng) ?? .zero
        if !ZoneOutdoorGeometry.contains(beach, p) { inside = false }
        for i in 0..<2000 {
            let w = i % 97 == 96 ? ZoneOutdoorGeometry.crabExit(from: p, crab: crab) : ZoneOutdoorGeometry.crabStep(from: p, crab: crab, using: &rng)
            if !ZoneOutdoorGeometry.contains(beach, w.to) || !ZoneOutdoorGeometry.contains(clipped, w.to) { inside = false }
            if !room.insetBy(dx: -1e-3, dy: -1e-3).contains(crabBox(w.to)) { whole = false }
            let along = (w.to.x - w.from.x) * crab.walk.dx + (w.to.y - w.from.y) * crab.walk.dy
            if abs(along) > 1e-6, (along > 0) != (w.facing > 0) { facingMatches = false }
            let metres = hypot(w.to.x - w.from.x, w.to.y - w.from.y) / hypot(crab.walk.dx, crab.walk.dy)
            if i % 97 != 96, metres > 3.0001 || abs(w.seconds - Double(metres / crab.speed)) > 1e-6 { lengths = false }
            facings.insert(w.facing)
            p = w.to
            if i % 50 == 0, let fresh = ZoneOutdoorGeometry.randomPoint(in: beach, using: &rng) { p = fresh }
        }
    }
    check("zone outdoors: each crab species' beach is its zone clipped to the picture and the loop's box, pulled in so a whole crab of it stays inside",
        beachOK)
    check("zone outdoors: over 2000 random walks a species (and walks off the end) every crab stays on its clipped beach, its whole frame in the picture",
        inside && whole)
    check("zone outdoors: a walk is at most 3 m along the beach at the species' pace, and its facing is the way it goes; both ways occur",
        facingMatches && lengths && facings == [1, -1])
    view.onScreenOverride = true
    view.syncOutdoor()
    let crabs = view.outdoor.crabs
    check("zone outdoors: 2–3 crabs stand on the beach, in the crab layer, each at its species' frame 1 with its foot on its spot",
        (2...3).contains(crabs.count) && crabs.allSatisfy { $0.layer.superlayer === view.outdoor.beach && ZoneOutdoorGeometry.contains(spec.crabs[$0.species].beach, $0.at) }
            && crabs.allSatisfy { ($0.layer.contents as CFTypeRef?) === (ZoneOutdoorArt.crabFrames($0.species).first as CFTypeRef?) }
            && view.outdoor.crabFeet().enumerated().allSatisfy { hypot($0.element.x - crabs[$0.offset].at.x, $0.element.y - crabs[$0.offset].at.y) < 1e-6 })

    // ── Gulls ──
    var offBoth = true, crosses = true, turned = true, upright = true, speed = true, heights = true, ways = Set<Bool>()
    for _ in 0..<2000 {
        for f in ZoneOutdoorGeometry.gullFlights(spec: spec, using: &rng) {
            let g = spec.gulls[f.species]
            for q in [f.from, f.to] {
                if picture.insetBy(dx: -g.reach, dy: -g.reach).contains(q)
                    || picture.insetBy(dx: -g.shadowSize.width / 2, dy: -g.shadowSize.width / 2).contains(CGPoint(x: q.x, y: q.y + f.shadowDrop))
                { offBoth = false }
            }
            if !(0...40).contains(where: { picture.contains(f.at(f.seconds * Double($0) / 40)) }) { crosses = false }
            let h = f.heading, t = ZoneOutdoorGeometry.gullTransform(h)
            let nose = zoneOutdoorsApply(t, CGVector(dx: 1, dy: 0)), up = zoneOutdoorsApply(t, CGVector(dx: 0, dy: -1))
            if hypot(nose.dx - h.dx, nose.dy - h.dy) > 1e-6 { turned = false }
            if abs(h.dx) > 0.05 && up.dy >= 0 { upright = false }
            ways.insert(h.dx < 0)
            if abs(f.seconds - Double(hypot(f.to.x - f.from.x, f.to.y - f.from.y) / g.pixelsPerSecond)) > 1e-6 { speed = false }
            if !(1.5...6).contains(f.height) || abs(f.shadowDrop - f.height * g.shadowPerMetre) > 1e-6 { heights = false }
        }
    }
    check("zone outdoors: every gull flight starts and ends off the picture (the bird turned any way, and its shadow) and crosses the picture",
        offBoth && crosses)
    if !(offBoth && crosses) { print("  (off both ends: \(offBoth), crosses: \(crosses))") }
    check("zone outdoors: the gull is turned to its heading, and kept upright (flipped top to bottom) heading left; both ways occur",
        turned && upright && ways == [true, false])
    check("zone outdoors: a gull flies at its species' speed × 105 px a metre, 1.5–6 m up, its shadow straight down by height × 83 px", speed && heights)
    let flights = view.outdoor.flyNow()
    let flying = view.outdoor.flying
    check("zone outdoors: a gull flight live: 1–2 birds in the top layer, turned to the heading, flapping and moving in Core Animation, shadows at 0.18 under them",
        (1...2).contains(flights.count) && flying.count == flights.count
            && flying.allSatisfy { g in
                g.gull.superlayer === view.outdoor.gulls && g.shadow.superlayer === view.outdoor.gulls && abs(g.shadow.opacity - 0.18) < 1e-6
                    && CATransform3DEqualToTransform(g.gull.transform, ZoneOutdoorGeometry.gullTransform(g.flight.heading))
                    && g.gull.animation(forKey: "flap") != nil && g.gull.animation(forKey: "fly") != nil && g.shadow.animation(forKey: "fly") != nil
                    && (view.outdoor.gulls.sublayers?.firstIndex(of: g.shadow) ?? 99) < (view.outdoor.gulls.sublayers?.firstIndex(of: g.gull) ?? -1)
            })
    view.onScreenOverride = false
    view.syncOutdoor()
    check("zone outdoors: hidden, the gulls in the air are gone and nothing more is waiting to fly", view.outdoor.flying.isEmpty && view.outdoor.gulls.sublayers?.isEmpty != false)

    // ── Hit test ──
    OfficePets.shared.synchronous = true
    let room2 = ZoneView(frame: CGRect(origin: .zero, size: size))
    room2.still = true
    room2.update(store)
    OfficePets.shared.synchronous = false
    let someone = store.sessions.first { room2.sprite(of: $0.id) != nil && room2.foot(of: $0.id) != nil }
    if let someone, let foot = room2.foot(of: someone.id), let drawn = room2.sprite(of: someone.id) {
        let middle = CGPoint(x: foot.x + drawn.frame.midX, y: foot.y + drawn.frame.midY), at = fit.back(middle)
        let before = room2.target(at: middle)
        let sky = CGPoint(x: 2150, y: 90)
        let over = ZoneGullFlight(from: CGPoint(x: at.x - 400, y: at.y), to: CGPoint(x: at.x + 400, y: at.y), height: 2, seconds: 2, delay: 0, shadowDrop: 2 * spec.gulls[0].shadowPerMetre)
        let high = ZoneGullFlight(from: CGPoint(x: sky.x - 400, y: sky.y), to: CGPoint(x: sky.x + 400, y: sky.y), height: 2, seconds: 2, delay: 0, shadowDrop: 2 * spec.gulls[0].shadowPerMetre)
        room2.outdoor.pose(at: 1, gulls: [over, high])
        let gullAt = room2.outdoor.flying.map { $0.gull.position }
        check("zone outdoors: a gull right over a figure does not take its click or hover, and a gull in the empty sky takes nothing",
            before == .pet(someone.id) && room2.target(at: middle) == .pet(someone.id) && room2.target(at: fit.point(sky)) == nil
                && gullAt.count == 2 && hypot(gullAt[0].x - middle.x, gullAt[0].y - middle.y) < 1e-6)
    } else {
        check("zone outdoors: a figure to test the gulls' hit test against", false)
    }
    check("zone outdoors: a still picture shows one frame of the loop, the crabs standing (one of each species), and plays nothing",
        room2.outdoor.player == nil && !room2.outdoor.running && room2.outdoor.sea.sublayers?.first?.contents != nil
            && Set(room2.outdoor.crabs.map(\.species)) == Set(spec.crabs.indices) && room2.outdoor.crabs.count == spec.crabs.count)

    // ── Reduce Motion ──
    let calm = ZoneView(frame: CGRect(origin: .zero, size: size))
    calm.calmOverride = true
    calm.onScreenOverride = true
    calm.update(store)
    let calmFlights = calm.outdoor.flyNow()
    check("zone outdoors: Reduce Motion: the loop's first frame only (no player), the crabs standing still, no gulls",
        calm.outdoor.player == nil && !calm.outdoor.running && calm.outdoor.sea.sublayers?.first?.contents != nil
            && (calm.outdoor.sea.sublayers?.first?.contents as CFTypeRef?) === (ZoneOutdoorArt.frame(at: 0) as CFTypeRef?)
            && calm.outdoor.crabs.allSatisfy { ($0.layer.animationKeys() ?? []).isEmpty } && calmFlights.isEmpty && calm.outdoor.flying.isEmpty)
    calm.calmOverride = false
    calm.syncOutdoor()
    let liveAgain = calm.outdoor.playing && calm.outdoor.playerLayer != nil
    calm.calmOverride = true
    calm.syncOutdoor()
    check("zone outdoors: Reduce Motion turned off the loop plays; on again it stops and shows the still frame",
        liveAgain && calm.outdoor.player == nil && calm.outdoor.sea.sublayers?.first?.contents != nil && !calm.outdoor.running)
    calm.stopListening()

    // ── No timers ──
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let text = (try? String(contentsOf: sources.appendingPathComponent("ZoneFX.swift"), encoding: .utf8)) ?? ""
    check("zone outdoors: the outdoors schedule with DispatchWorkItem and Core Animation, no periodic time observer, no display link",
        text.contains("final class ZoneOutdoor") && text.contains("DispatchWorkItem") && !text.contains("addPeriodicTimeObserver") && !text.contains("DisplayLink"))
}

/// `--zone-outdoors-stills <dir>`: the crowded room with the outdoors: crabs on the beach and two gulls mid-flight (one heading
/// left), the whole picture and the outdoors zoomed; a strip of six moments half a second apart.
@MainActor func zoneOutdoorsStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    defer {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    guard ZoneArt.scene != nil, let spec = ZoneOutdoorArt.spec else { return print("zone stills: no outdoor art") }
    let store = zoneOpenRoomCrowd()
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    let fit = ZoneFit(scene: spec.picture, view: size)
    // Right and up over the room and its plates; and a second heading left over the beach.
    let across = ZoneOutdoorGeometry.flight(CGPoint(x: 0, y: 1250), CGPoint(x: 2400, y: 250), height: 3, delay: 0, spec: spec)
    // the second is another species (a tern, when there is one).
    let tern = spec.gulls.firstIndex { $0.kind == "tern" } ?? spec.gulls.count - 1
    let back = ZoneOutdoorGeometry.flight(CGPoint(x: 2400, y: 380), CGPoint(x: 0, y: 900), height: 5, delay: 0, spec: spec, species: tern)
    func mid(_ f: ZoneGullFlight, _ x: CGFloat) -> Double { f.seconds * Double((x - f.from.x) / (f.to.x - f.from.x)) }
    let t0 = mid(across, 1150)
    let backFlight = ZoneGullFlight(from: back.from, to: back.to, height: back.height, seconds: back.seconds, delay: t0 - mid(back, 1700), shadowDrop: back.shadowDrop, species: back.species)
    view.outdoor.pose(at: t0, gulls: [across, backFlight])
    print("zone stills: crabs at \(view.outdoor.crabs.map { "\(spec.crabs[$0.species].kind) (\(Int($0.at.x)), \(Int($0.at.y)))" }.joined(separator: " ")); gulls \([across, backFlight].map { spec.gulls[$0.species].kind }) at t \(String(format: "%.2f", t0)) s")
    let picture = view.image()
    write(picture, "zone-outdoor.png")
    let box = fit.rect(spec.loopBox).intersection(CGRect(origin: .zero, size: size))
    func crop(_ image: CGImage?) -> CGImage? { image?.cropping(to: CGRect(x: box.minX * 2, y: box.minY * 2, width: box.width * 2, height: box.height * 2)) }
    write(crop(picture), "zone-outdoor-zoom.png")
    // Six moments, 0.5 s apart: the sea's frames, the crabs walking, the gulls flapping and moving.
    var frames: [CGImage] = []
    for k in 0..<6 {
        view.outdoor.pose(at: t0 - 1.25 + Double(k) * 0.5, gulls: [across, backFlight])
        if let image = crop(view.image()) { frames.append(image) }
    }
    guard let one = frames.first else { return }
    let w = one.width / 2, h = one.height / 2
    guard let c = CGContext(data: nil, width: w * 2, height: h * 3, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    for (k, image) in frames.enumerated() {
        c.draw(image, in: CGRect(x: (k % 2) * w, y: (2 - k / 2) * h, width: w, height: h))
    }
    write(c.makeImage(), "zone-outdoor-strip.png")
}

// ───────── the room stays inside its own view ─────────

/// The part of `layer` that can show, in `top`'s coordinates: its frame cut by every masking layer above it up to `top`.
@MainActor func zonePanelFitVisible(_ layer: CALayer, in top: CALayer) -> CGRect {
    var shown = layer.convert(layer.bounds, to: top)
    var up = layer.superlayer
    while let l = up, l !== top {
        if l.masksToBounds { shown = shown.intersection(l.convert(l.bounds, to: top)) }
        up = l.superlayer
    }
    return shown
}

@MainActor func zonePanelFitFind(_ v: NSView) -> ZoneView? {
    if let z = v as? ZoneView { return z }
    for sub in v.subviews { if let z = zonePanelFitFind(sub) { return z } }
    return nil
}

/// The window's own layers drawn into an image (top-left first), the way Core Animation lays them.
@MainActor func zonePanelFitRender(_ top: CALayer) -> NSBitmapImageRep? {
    let size = top.bounds.size
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    top.render(in: context.cgContext)
    context.flushGraphics()
    return rep
}

/// The panel as the app makes it (a full-size content view under a clear title bar with the counts in it), the zone room
/// in its SwiftUI content; wider than the picture's 3:2, so the picture, filling the view, runs past its top and bottom.
@MainActor func zonePanelFitTests() {
    guard ZoneArt.scene != nil, ZoneOutdoorArt.spec != nil else {
        check("zone outdoors fit: the art", false)
        return
    }
    let themeBefore = OfficeTheme.shown
    OfficeTheme.shown = OfficeTheme.zone
    defer { OfficeTheme.shown = themeBefore }
    let store = zoneOpenRoomCrowd()
    for size in [CGSize(width: 1180, height: 790), CGSize(width: 1500, height: 640)] {
        let panel = ZoneOffscreenPanel(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: GeometryReader { _ in ZStack(alignment: .topLeading) { ZoneRoom(store: store) } })
        let counts = NSHostingView(rootView: CountsBar(store: store).environment(\.colorScheme, .dark))
        counts.frame.size = counts.fittingSize
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = counts
        panel.addTitlebarAccessoryViewController(accessory)
        panel.orderFrontRegardless()
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        defer {
            if let z = zonePanelFitFind(panel.contentView!) { z.stopListening() }
            panel.orderOut(nil)
        }
        let label = "\(Int(size.width))×\(Int(size.height))"
        guard let frame = panel.contentView?.superview, let top = frame.layer, let view = zonePanelFitFind(frame), let root = view.layer else {
            check("zone outdoors fit \(label): the room in the panel", false)
            continue
        }
        // Live: the loop playing, the crabs out, two gulls in the air.
        view.calmOverride = false
        view.onScreenOverride = true
        view.update(store)
        view.outdoor.flyNow()
        let inWindow = view.convert(view.bounds, to: nil)
        let zoneRect = root.convert(root.bounds, to: top)
        let fit = ZoneFit(scene: ZoneArt.scene!.size, view: view.bounds.size)
        let titleTop = frame.bounds.height - inWindow.maxY
        print("      zone outdoors fit \(label): room \(inWindow.integral), title bar \(Int(titleTop)) pt, picture from y \(Int(fit.offset.y)) pt, \(view.outdoor.flying.count) gulls")
        check("zone outdoors fit \(label): the picture runs past the room's top (the case that showed it in the title bar) and the room sits under the title bar",
            fit.offset.y < -1 && titleTop >= 20 && abs(zoneRect.minX - inWindow.minX) < 0.5 && abs(zoneRect.height - inWindow.height) < 0.5)
        check("zone outdoors fit \(label): in the window the room's own layer clips to the view (masksToBounds survives AppKit)", root.masksToBounds)
        var z11: [(String, CALayer)] = [("sea", view.outdoor.sea), ("beach", view.outdoor.beach), ("gulls", view.outdoor.gulls)]
        if let shown = view.outdoor.playerLayer { z11.append(("loop", shown)) }
        for c in view.outdoor.crabs { z11.append(("crab", c.layer)) }
        for g in view.outdoor.flying { z11 += [("gull", g.gull), ("gull shadow", g.shadow)] }
        for part in root.sublayers ?? [] { z11.append((part.name ?? "part", part)) }
        let outside = z11.filter { _, layer in
            let shown = zonePanelFitVisible(layer, in: top)
            return !shown.isNull && !shown.isEmpty && !zoneRect.insetBy(dx: -0.5, dy: -0.5).contains(shown)
        }.map(\.0)
        check("zone outdoors fit \(label): every layer of the room (the sea, its loop, the crabs, the gulls and their shadows, and the rest) shows only inside the room (\(outside))",
            view.outdoor.playerLayer != nil && view.outdoor.crabs.count >= 2 && !view.outdoor.flying.isEmpty && outside.isEmpty)
        // The title bar strip, with the room shown and with it hidden: the same pixels (no scene pixel above the room).
        let withRoom = zonePanelFitRender(top)
        view.isHidden = true
        let withoutRoom = zonePanelFitRender(top)
        view.isHidden = false
        var differ = 0
        if let a = withRoom, let b = withoutRoom {
            let strip = Int(titleTop.rounded(.down))
            for y in 0..<strip { for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.02 { differ += 1 }
            } }
        }
        check("zone outdoors fit \(label): the title bar gets no pixel of the room (its strip is the same with the room hidden; \(differ) differ)",
            withRoom != nil && withoutRoom != nil && differ == 0)
    }
}

/// The title bar as the app builds it (counts on the left, usage/search/switch on
/// the right, as `AppDelegate` adds them), in each scene, at 1180×790 and 1500×790. Its outer margins stay where they
/// have been since the first measurement: the first thing drawn, the close button, 9 pt from the left
/// edge; the last, the scene switch's frame, 12 pt from the right edge; the counts start at x 78 and the right group
/// ends at the window's edge. Rendered from the window's layer tree, the same strip the outdoors fit check reads.
/// `scenes`: the scenes to try, by default the panel's own; an extension's checks try its scene the same way.
@MainActor func zoneTitlebarMarginTests(scenes given: [(String, Bool, OfficeTheme)]? = nil) {
    let themeBefore = OfficeTheme.shown
    let officeBefore = UserDefaults.standard.object(forKey: "office")
    let themeNameBefore = UserDefaults.standard.object(forKey: "officeTheme")
    defer {
        OfficeTheme.shown = themeBefore
        UserDefaults.standard.set(officeBefore, forKey: "office")
        UserDefaults.standard.set(themeNameBefore, forKey: "officeTheme")
    }
    let scenes: [(String, Bool, OfficeTheme)] = given ?? [("海景房", true, OfficeTheme.zone), ("办公室", true, OfficeTheme.named("青灰")),
                                                          ("值班室", false, OfficeTheme.named("青灰"))]
    for (name, office, theme) in scenes {
        UserDefaults.standard.set(office, forKey: "office")
        UserDefaults.standard.set(theme.name, forKey: "officeTheme")
        OfficeTheme.shown = theme
        for size in [CGSize(width: 1180, height: 790), CGSize(width: 1500, height: 790)] {
            let label = "zone title bar \(name) \(Int(size.width))"
            let store = zoneOpenRoomCrowd()
            let panel = ZoneOffscreenPanel(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isReleasedWhenClosed = false
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.backgroundColor = NSColor(red: 0x1B / 255.0, green: 0x18 / 255.0, blue: 0x30 / 255.0, alpha: 1)
            panel.contentView = NSHostingView(rootView: Root(store: store))
            var hosts: [NSView] = []
            for (view, side) in [(AnyView(CountsBar(store: store)), NSLayoutConstraint.Attribute.leading), (AnyView(ActionsBar(store: store)), .trailing)] {
                let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
                host.frame.size = host.fittingSize
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = side
                accessory.view = host
                panel.addTitlebarAccessoryViewController(accessory)
                hosts.append(host)
            }
            panel.orderFrontRegardless()
            for _ in 0..<12 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.03))
                for host in hosts { host.setFrameSize(host.fittingSize) }
            }
            if let z = zonePanelFitFind(panel.contentView!) { z.update(store) }
            for _ in 0..<4 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
            defer {
                if let z = zonePanelFitFind(panel.contentView!) { z.stopListening() }
                panel.orderOut(nil)
            }
            guard let frame = panel.contentView?.superview, let top = frame.layer,
                  let close = panel.standardWindowButton(.closeButton) else {
                check("\(label): the panel", false)
                continue
            }
            check("\(label): the switch is shown", store.officeFits)
            let counts = hosts[0].convert(hosts[0].bounds, to: nil), actions = hosts[1].convert(hosts[1].bounds, to: nil)
            let closeX = close.convert(close.bounds, to: nil).minX
            check("\(label): close button 9 pt from the left (\(closeX))", abs(closeX - 9) <= 3)
            check("\(label): counts start at x 78 (\(counts.minX))", abs(counts.minX - 78) <= 3)
            check("\(label): the right group ends at the window edge (\(actions.maxX))", abs(actions.maxX - size.width) <= 3)
            // The strip: the first and last columns where something is drawn over the title bar's own colour.
            let scale = 2, height = 60
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: height * scale, bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
                check("\(label): the strip", false)
                continue
            }
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: 0, y: CGFloat(height) - top.bounds.height)
            top.render(in: ctx)
            func rgb(_ x: Int, _ y: Int) -> (Int, Int, Int) {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) ?? .black
                return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
            }
            let bg = rgb(Int(size.width) * scale / 2, 6 * scale)
            func drawn(_ x: Int) -> Bool {
                stride(from: 14 * scale, to: 26 * scale, by: 1).contains { y in
                    let p = rgb(x, y)
                    return abs(p.0 - bg.0) + abs(p.1 - bg.1) + abs(p.2 - bg.2) > 60
                }
            }
            let width = Int(size.width) * scale
            let first = (0..<width).first(where: drawn).map { CGFloat($0) / CGFloat(scale) } ?? -1
            let last = (0..<width).reversed().first(where: drawn).map { CGFloat($0 + 1) / CGFloat(scale) } ?? -1
            check("\(label): left outer margin 9 pt (\(first))", abs(first - 9) <= 3)
            check("\(label): right outer margin 12 pt (\(size.width - last))", abs(size.width - last - 12) <= 3)
        }
    }
}

// ───────── the base picture through the room's fit ─────────

/// Mean per-channel difference (0…255) of two same-size pictures, every third pixel.
@MainActor func zoneSpeciesDiff(_ a: CGImage, _ b: CGImage) -> Double {
    func rgba(_ image: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let c = CGContext(data: &px, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return [] }
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return px
    }
    guard a.width == b.width, a.height == b.height else { return 255 }
    let p = rgba(a), q = rgba(b)
    guard p.count == q.count, !p.isEmpty else { return 255 }
    var sum = 0.0, n = 0.0
    for i in stride(from: 0, to: p.count, by: 12) {
        for k in 0..<3 { sum += abs(Double(p[i + k]) - Double(q[i + k])) }
        n += 3
    }
    return sum / max(1, n)
}

/// The base picture is aspect-filled through the room's `ZoneFit` after every update (not stretched to the view), so the
/// base, the sea's loop and the points.json anchors (desks, sofas) coincide; at the panel's room size and at a wide one.
@MainActor func zoneBaseFitTests() {
    guard let scene = ZoneArt.scene, let picture = ZoneArt.picture("night_base") else {
        check("zone picture fit: the base picture", false)
        return
    }
    let store = zoneOpenRoomCrowd()
    for size in [CGSize(width: 1180, height: 758), CGSize(width: 1180, height: 790), CGSize(width: 1500, height: 640)] {
        let label = "\(Int(size.width))×\(Int(size.height))"
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        view.update(store)  // the second update must not stretch it
        let fit = ZoneFit(scene: scene.size, view: size)
        guard let root = view.layer, let base = root.sublayers?.first(where: { $0.name == "base" }) else {
            check("zone picture fit \(label): the base layer", false)
            continue
        }
        let want = fit.rect(CGRect(origin: .zero, size: scene.size))
        let f = base.frame
        check("zone picture fit \(label): after a store update the base picture is aspect-filled through the fit (\(f.integral) vs \(want.integral)), not stretched to the view",
            abs(f.minX - want.minX) < 0.01 && abs(f.minY - want.minY) < 0.01 && abs(f.width - want.width) < 0.01 && abs(f.height - want.height) < 0.01)
        // Where the base layer draws a points.json anchor, against where the figures and desks put it.
        var worst: CGFloat = 0
        let anchors = scene.desks.map(\.seat) + scene.sofas.map(\.center)
        for p in anchors {
            let drawn = CGPoint(x: f.minX + p.x * f.width / scene.size.width, y: f.minY + p.y * f.height / scene.size.height)
            let placed = fit.point(p)
            worst = max(worst, hypot(drawn.x - placed.x, drawn.y - placed.y))
        }
        check("zone picture fit \(label): every desk seat and sofa (\(anchors.count) anchors) is drawn by the base where the room places it (worst \(String(format: "%.2f", worst)) pt)",
            anchors.count > 10 && worst < 0.05)
        // The base (and the sea's first frame over it) as the view draws them, against the picture drawn straight through the fit.
        let others = (root.sublayers ?? []).filter { $0 !== base && $0.name != "sea" }
        let wasHidden = others.map(\.isHidden)
        for l in others { l.isHidden = true }
        let sea = root.sublayers?.first { $0.name == "sea" }
        sea?.isHidden = true
        let shownBase = view.image(pixelScale: 1)
        sea?.isHidden = false
        let shownSea = view.image(pixelScale: 1)
        for (l, h) in zip(others, wasHidden) { l.isHidden = h }
        func expected(withSea: Bool) -> CGImage? {
            guard let c = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            c.interpolationQuality = .high
            c.setFillColor(OfficeCanvas.rgb(0x15192B))
            c.fill(CGRect(origin: .zero, size: size))
            // Top-left picture rectangles into the context's bottom-left space.
            func flip(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height) }
            c.draw(picture, in: flip(want))
            if withSea, let spec = ZoneOutdoorArt.spec, let frame = ZoneOutdoorArt.frame(at: 0) { c.draw(frame, in: flip(fit.rect(spec.loopBox))) }
            return c.makeImage()
        }
        let dBase = shownBase.flatMap { s in expected(withSea: false).map { zoneSpeciesDiff(s, $0) } } ?? 255
        let dSea = shownSea.flatMap { s in expected(withSea: true).map { zoneSpeciesDiff(s, $0) } } ?? 255
        // The sea really draws something over the base (else the second comparison proves nothing).
        let seaShows = shownBase.flatMap { b in shownSea.map { zoneSpeciesDiff(b, $0) } } ?? 0
        print("      zone picture fit \(label): base drawn vs picture through the fit: \(String(format: "%.2f", dBase)); with the sea: \(String(format: "%.2f", dSea)) (the sea changes \(String(format: "%.2f", seaShows)))")
        check("zone picture fit \(label): the base as drawn matches the picture through the fit, and so does the sea's loop over it (mean diff < 2/255)",
            dBase < 2 && dSea < 2 && seaShows > 0.2)
    }
}

// ───────── crab and gull species ─────────

@MainActor func zoneSpeciesTests() {
    guard let spec = ZoneOutdoorArt.spec else {
        check("zone picture fit: outdoor.json reads as lists of crab and gull species", false)
        return
    }
    // ── outdoor.json's lists ──
    let crabKinds = spec.crabs.map(\.kind), gullKinds = spec.gulls.map(\.kind)
    print("      zone picture fit: crabs \(crabKinds) speeds \(spec.crabs.map(\.speed)); gulls \(gullKinds) speeds \(spec.gulls.map(\.speed))")
    // the coconut crab's slot now holds the sand crab (ghost), 180×160 like the others.
    check("zone crabs: outdoor.json `crabs` reads as 3 species (cute 180×160 at 0.6 m/s, ghost 180×160 at 0.55, hermit 180×160 at 0.25), each with its foot in its frame and the beach's walk vector",
        crabKinds == ["cute", "ghost", "hermit"] && spec.crabs.map(\.size) == [CGSize(width: 180, height: 160), CGSize(width: 180, height: 160), CGSize(width: 180, height: 160)]
            && spec.crabs.map(\.speed) == [0.6, 0.55, 0.25] && spec.crabs.allSatisfy { $0.frames == 6 && $0.zone.count == 4 && abs($0.walk.dx - 93.129) < 1e-3 && abs($0.walk.dy - 30.486) < 1e-3 }
            && abs(spec.crabs[0].foot.x - 89.9621) < 1e-3 && abs(spec.crabs[1].foot.x - 89.9621) < 1e-3 && abs(spec.crabs[1].foot.y - 79.831) < 1e-3)
    check("zone picture fit: outdoor.json `gulls` reads as 3 species (herring 6 m/s, black-headed 5.5, tern 7), 300×230 with the middle in the frame, 48 frames each",
        gullKinds == ["herring", "blackhead", "tern"] && spec.gulls.map(\.speed) == [6, 5.5, 7]
            && spec.gulls.allSatisfy { $0.size == CGSize(width: 300, height: 230) && $0.frames == 48 && abs($0.centre.x - 149.6888) < 1e-3 && abs($0.shadowPerMetre - 83.115) < 1e-3 }
            && abs(spec.gulls[2].pixelsPerSecond - 7 * 105.4748) < 0.1)
    check("zone picture fit: an old single-crab/gull outdoor.json no longer reads (no silent fallback to one species)",
        ZoneOutdoorSpec.parse(Data(#"{"picture":[2400,1600],"crab":{},"gull":{},"loop":{"box":[460,0,2400,640]}}"#.utf8), pixelsPerMetre: 105) == nil)

    // ── Old sprite names gone ──
    let folder = ZoneArt.folder ?? ""
    let files = (try? FileManager.default.contentsOfDirectory(atPath: folder + "/sprites")) ?? []
    let old = files.filter { $0.range(of: #"^(crab|gull)_[0-9]+\.png$"#, options: .regularExpression) != nil }
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let fx = (try? String(contentsOf: sources.appendingPathComponent("ZoneFX.swift"), encoding: .utf8)) ?? ""
    let build = (try? String(contentsOf: sources.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
    check("zone picture fit: the old crab_NN/gull_NN sprites are gone (\(old.count) left of \(files.count)), nothing loads them, and build.sh empties the bundle's sprites before copying the new ones",
        !files.isEmpty && old.isEmpty && ZoneArt.picture("sprites/crab_01") == nil && ZoneArt.picture("sprites/gull_01") == nil
            && !fx.contains("\"sprites/crab_%02d\"") && !fx.contains("\"sprites/gull_%02d\"")
            && build.contains("rm -rf \"$APP/Contents/Resources/zone3d/sprites\"") && build.contains("cp themes/seaview/assets/sprites/*.png"))

    // ── Each species its own sprite set ──
    let firsts = spec.crabs.indices.map { ZoneOutdoorArt.crabFrames($0).first }, gullFirsts = spec.gulls.indices.map { ZoneOutdoorArt.gullFrames($0).first }
    func pixels(_ i: CGImage?) -> Data? { i?.dataProvider?.data as Data? }
    let crabSets = Set(firsts.compactMap(pixels)).count, gullSets = Set(gullFirsts.compactMap(pixels)).count
    check("zone crabs: each crab species loads its own sprite files (3 different pictures, ghost 180×160) and each gull species its own (3 different)",
        crabSets == 3 && gullSets == 3 && firsts[1]?.width == 180 && firsts[0]?.width == 180
            && spec.crabs.indices.allSatisfy { i in ZoneOutdoorArt.crabFrames(i).count == 6 } && spec.gulls.indices.allSatisfy { ZoneOutdoorArt.gullFrames($0).count == 48 })

    // ── Never two of one species at once ──
    let size = CGSize(width: 1180, height: 758)
    let fit = ZoneFit(scene: spec.picture, view: size)
    var distinct = true, counts = Set<Int>(), seen = Set<Int>(), onBeach = true
    for seed in 0..<60 {
        let o = ZoneOutdoor(seed: UInt64(seed))
        o.configure(live: true, fit: fit, bounds: CGRect(origin: .zero, size: size), seeded: false)
        var r = ZoneRandom(seed: UInt64(seed) &+ 1000)
        for _ in 0..<40 {
            let ids = o.crabs.map(\.species)
            if Set(ids).count != ids.count { distinct = false }
            counts.insert(ids.count)
            seen.formUnion(ids)
            if !o.crabs.allSatisfy({ ZoneOutdoorGeometry.contains(spec.crabs[$0.species].beach, $0.at) }) { onBeach = false }
            if let c = o.crabs.randomElement(using: &r) { o.replace(c) }
        }
    }
    check("zone picture fit: over 60 beaches × 40 turnovers there is never two crabs of one species at once (counts \(counts.sorted())), every species turns up, each on its own beach",
        distinct && counts.isSubset(of: [1, 2, 3]) && !counts.isEmpty && seen == Set(spec.crabs.indices) && onBeach)

    // ── Each crab: its sprites, its size, its walk vector and pace, the hermit drawn heading back ──
    let store = zoneOpenRoomCrowd()
    let still = ZoneView(frame: CGRect(origin: .zero, size: size))
    still.still = true
    still.update(store)
    var own = true, walks = true, flips = true
    for c in still.outdoor.crabs {
        let crab = spec.crabs[c.species]
        if (c.layer.contents as CFTypeRef?) !== (ZoneOutdoorArt.crabFrames(c.species).first as CFTypeRef?)
            || abs(c.layer.bounds.width - crab.size.width * fit.scale) > 1e-6 || abs(c.layer.bounds.height - crab.size.height * fit.scale) > 1e-6
            || c.layer.name != "crab-" + crab.kind { own = false }
        var r = ZoneRandom(seed: UInt64(c.species) + 5)
        for _ in 0..<200 {
            let w = ZoneOutdoorGeometry.crabStep(from: c.at, crab: crab, using: &r)
            let dx = w.to.x - w.from.x, dy = w.to.y - w.from.y
            let metres = hypot(dx, dy) / hypot(crab.walk.dx, crab.walk.dy)
            if abs(dx * crab.walk.dy - dy * crab.walk.dx) > 1e-6 * max(1, hypot(dx, dy)) * hypot(crab.walk.dx, crab.walk.dy)
                || abs(w.seconds - Double(metres / crab.speed)) > 1e-6 { walks = false }
        }
    }
    // Posed mid-walk: each layer is flipped by its walk's way times how its sprite is drawn.
    still.outdoor.pose(at: 0.5)
    for c in still.outdoor.crabs {
        guard let walk = c.stillWalk else {
            flips = false
            continue
        }
        if abs(c.layer.transform.m11 - walk.facing * spec.crabs[c.species].drawn) > 1e-6 { flips = false }
    }
    let hermit = spec.crabs.first { $0.kind == "hermit" }
    check("zone picture fit: a still picture's crabs (\(still.outdoor.crabs.map { spec.crabs[$0.species].kind })) each show their own species' frame at its own size",
        still.outdoor.crabs.count == 3 && Set(still.outdoor.crabs.map(\.species)).count == 3 && own)
    check("zone picture fit: each species walks along its own walk vector at its own pace; the hermit (drawn heading picture-left) walks forward, flipped like the others for the other way",
        walks && flips && hermit?.drawn == -1 && spec.crabs.filter { $0.kind != "hermit" }.allSatisfy { $0.drawn == 1 }
            && still.outdoor.crabs.contains { spec.crabs[$0.species].kind == "hermit" })

    // ── Gull species ──
    var tally = [Int](repeating: 0, count: spec.gulls.count), pairsAlike = true, speeds = true
    var rng = ZoneRandom(seed: 12)
    let draws = 4000
    for _ in 0..<draws {
        let flights = ZoneOutdoorGeometry.gullFlights(spec: spec, using: &rng)
        guard let s = flights.first?.species else { continue }
        tally[s] += 1
        if !flights.allSatisfy({ $0.species == s }) { pairsAlike = false }
        for f in flights where abs(f.seconds - Double(hypot(f.to.x - f.from.x, f.to.y - f.from.y) / spec.gulls[f.species].pixelsPerSecond)) > 1e-6 { speeds = false }
    }
    let share = tally.map { Double($0) / Double(draws) }
    print("      zone picture fit: gull species over \(draws) flights: \(zip(gullKinds, share).map { "\($0) \(String(format: "%.3f", $1))" })")
    check("zone crabs: each flight picks one of the three gull species (herring ~40 %, black-headed ~30 %, tern ~30 %), a pair is one species, each at its own speed",
        share.count == 3 && abs(share[0] - 0.4) < 0.04 && abs(share[1] - 0.3) < 0.04 && abs(share[2] - 0.3) < 0.04 && pairsAlike && speeds)
    let live = ZoneView(frame: CGRect(origin: .zero, size: size))
    live.calmOverride = false
    live.onScreenOverride = true
    live.update(store)
    var liveOwn = true, liveKinds = Set<Int>()
    for _ in 0..<30 {
        for f in live.outdoor.flyNow() { liveKinds.insert(f.species) }
        for g in live.outdoor.flying {
            let frames = ZoneOutdoorArt.gullFrames(g.flight.species)
            let flap = g.gull.animation(forKey: "flap") as? CAKeyframeAnimation
            if (g.gull.contents as CFTypeRef?) !== (frames.first as CFTypeRef?) || (flap?.values?.first as CFTypeRef?) !== (frames.first as CFTypeRef?)
                || flap?.values?.count != frames.count { liveOwn = false }
        }
    }
    live.stopListening()
    check("zone picture fit: live, each gull in the air flaps through its own species' frames (species seen: \(liveKinds.sorted().map { gullKinds[$0] }))",
        liveOwn && liveKinds.count >= 2)
}

// ───────── orca clips over the sea ─────────

/// The panel as the app makes it (the outdoors fit setup), offscreen, with the zone room in it; nil when it cannot be made.
@MainActor func zoneOrcaPanel(_ size: CGSize, _ store: Store) -> (panel: ZoneOffscreenPanel, view: ZoneView, top: CALayer)? {
    let panel = ZoneOffscreenPanel(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height),
                        styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.isReleasedWhenClosed = false
    panel.contentView = NSHostingView(rootView: GeometryReader { _ in ZStack(alignment: .topLeading) { ZoneRoom(store: store) } })
    let counts = NSHostingView(rootView: CountsBar(store: store).environment(\.colorScheme, .dark))
    counts.frame.size = counts.fittingSize
    let accessory = NSTitlebarAccessoryViewController()
    accessory.layoutAttribute = .leading
    accessory.view = counts
    panel.addTitlebarAccessoryViewController(accessory)
    panel.orderFrontRegardless()
    for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    guard let frame = panel.contentView?.superview, let top = frame.layer, let view = zonePanelFitFind(frame) else {
        panel.orderOut(nil)
        return nil
    }
    return (panel, view, top)
}

/// Spins the run loop until `done` or `seconds` pass; whether it came true.
@MainActor @discardableResult func zoneOrcaWait(_ seconds: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if done() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return done()
}

@MainActor func zoneOrcaTests() {
    guard ZoneArt.scene != nil, let spec = ZoneOutdoorArt.spec, let orca = ZoneOutdoorArt.orca else {
        check("zone orca: orca.json reads", false)
        return
    }
    // ── orca.json ──
    let boxes = orca.clips.map(\.box)
    // C re-rendered: 240 frames (10 s: the slow scrape back to the waterline), its box fitted to the new film.
    check("zone orca: orca.json reads: clips A, B, C at [1560,0,2400,480], [460,0,2400,480], [1624,0,2400,456], 120/120/240 frames at 24 fps, from loop frame 0; the loop 288 frames at 24; C has a strike (3 gull spots, take-off frames, the way in)",
        orca.ids == ["A", "B", "C"] && boxes == [CGRect(x: 1560, y: 0, width: 840, height: 480), CGRect(x: 460, y: 0, width: 1940, height: 480), CGRect(x: 1624, y: 0, width: 776, height: 456)]
            && orca.clips.map(\.frames) == [120, 120, 240] && orca.clips.allSatisfy { $0.fps == 24 && $0.startLoopFrame == 0 }
            && orca.loopFrames == spec.loopFrames && orca.loopFPS == spec.fps && orca.picture == spec.picture && abs(orca.loopSeconds - 12) < 1e-9
            && orca.clips.map(\.seconds) == [5, 5, 10] && orca.clip("C")?.strike?.gullSpots.count == 3 && orca.clip("C")?.strike?.takeoffFrames == [36, 32, 38]
            && orca.clip("A")?.strike == nil)
    let mids = orca.clips.map { ZoneOutdoorArt.orcaFrame($0.id, $0.frames / 2) }
    check("zone orca: the three films are in the art folder, each frame the size of its box, with alpha (clear corners)",
        orca.ids.allSatisfy { ZoneOutdoorArt.orcaMovie($0) != nil }
            && zip(mids, orca.clips).allSatisfy { m, c in m.map { $0.width == Int(c.box.width) && $0.height == Int(c.box.height) && ($0.alphaInfo != .none && $0.alphaInfo != .noneSkipFirst && $0.alphaInfo != .noneSkipLast) } == true })
    check("zone orca: a broken orca.json (no clips, a box without four numbers) reads as nothing",
        ZoneOrcaSpec.parse(Data(#"{"picture":[2400,1600],"clips":[]}"#.utf8)) == nil
            && ZoneOrcaSpec.parse(Data(#"{"picture":[2400,1600],"clips":[{"id":"A","file":"A.mov","box":[1,2,3],"frames":10}]}"#.utf8)) == nil)

    // ── The schedule (seeded) ──
    var rng = ZoneRandom(seed: 2)
    let waits = (0..<4000).map { _ in ZoneOrcaSpec.interval(using: &rng) }
    var last: String? = nil, repeats = 0, tally: [String: Int] = [:]
    for _ in 0..<4000 {
        guard let id = ZoneOrcaSpec.pick(after: last, ids: orca.ids, using: &rng) else {
            repeats += 1000
            break
        }
        if id == last { repeats += 1 }
        tally[id, default: 0] += 1
        last = id
    }
    let low = waits.filter { $0 < 255 }.count, high = waits.filter { $0 > 405 }.count
    print("      zone orca: waits \(String(format: "%.1f", waits.min() ?? 0))…\(String(format: "%.1f", waits.max() ?? 0)) s (\(low) under 255, \(high) over 405 of 4000); clips \(tally.sorted { $0.key < $1.key })")
    check("zone orca: the wait before a clip is 3–8 min, uniform (seeded: 4000 waits all in 180…480 s, a quarter at each end)",
        waits.allSatisfy { (180...480).contains($0) } && abs(Double(low) / 4000 - 0.25) < 0.03 && abs(Double(high) / 4000 - 0.25) < 0.03)
    check("zone orca: the clip is picked at random, never the one just shown (4000 picks: no repeat, each about a third)",
        repeats == 0 && orca.ids.allSatisfy { abs(Double(tally[$0] ?? 0) / 4000 - 1.0 / 3) < 0.04 })
    check("zone orca: the wait for the loop's frame 0 from loop time t: 12 − t, and one loop more when frame 0 is under 0.25 s away",
        abs(ZoneOrcaSpec.untilLoopFrame(at: 11.3, loopSeconds: 12, fps: 24) - 0.7) < 1e-9 && abs(ZoneOrcaSpec.untilLoopFrame(at: 0, loopSeconds: 12, fps: 24) - 12) < 1e-9
            && abs(ZoneOrcaSpec.untilLoopFrame(at: 11.9, loopSeconds: 12, fps: 24) - 12.1) < 1e-9 && abs(ZoneOrcaSpec.untilLoopFrame(at: 3, loopSeconds: 12, fps: 24) - 9) < 1e-9)

    // ── Not seen, still, calm: no clip ──
    let store = zoneOpenRoomCrowd()
    let size = CGSize(width: 1180, height: 790)
    let unseen = ZoneView(frame: CGRect(origin: .zero, size: size))
    unseen.calmOverride = false
    unseen.onScreenOverride = false
    unseen.update(store)
    let still = ZoneView(frame: CGRect(origin: .zero, size: size))
    still.still = true
    still.onScreenOverride = true
    still.update(store)
    let calm = ZoneView(frame: CGRect(origin: .zero, size: size))
    calm.calmOverride = true
    calm.onScreenOverride = true
    calm.update(store)
    check("zone orca: hidden, a still picture, or Reduce Motion: no clip starts, no player is made, no countdown runs",
        [unseen, still, calm].allSatisfy { v in !v.outdoor.playOrca("A") && v.outdoor.orcaPlayer == nil && v.outdoor.orcaCountdown == nil && (v.outdoor.orca.sublayers ?? []).isEmpty })
    let names = still.layer?.sublayers?.map { $0.name ?? "" } ?? []
    func at(_ n: String) -> Int { names.firstIndex(of: n) ?? -1 }
    check("zone orca: the orca layer goes base < sea < beach < orca < screens … < gulls < the title bar's shade",
        at("base") == 0 && at("sea") < at("beach") && at("beach") < at("orca") && at("orca") < at("lights") && at("orca") < at("gulls")
            && at("gulls") == names.count - 2 && at("titleShade") == names.count - 1)

    // ── Live, in the panel as the app makes it ──
    let themeBefore = OfficeTheme.shown
    OfficeTheme.shown = OfficeTheme.zone
    defer { OfficeTheme.shown = themeBefore }
    for (size, clips) in [(CGSize(width: 1180, height: 790), ["A", "B", "C"]), (CGSize(width: 1500, height: 640), ["B"])] {
        let label = "\(Int(size.width))×\(Int(size.height))"
        guard let (panel, view, top) = zoneOrcaPanel(size, store), let root = view.layer else {
            check("zone orca \(label): the room in the panel", false)
            continue
        }
        defer {
            view.stopListening()
            panel.orderOut(nil)
        }
        view.calmOverride = false
        view.onScreenOverride = true
        view.update(store)
        let fit = ZoneFit(scene: spec.picture, view: view.bounds.size)
        let countdown = view.outdoor.orcaCountdown
        check("zone orca \(label): seen, the next clip is counted down (\(countdown.map { String(format: "%.0f s", $0) } ?? "none"), 3–8 min) and nothing plays yet",
            countdown.map { (180...480).contains($0) } == true && view.outdoor.orcaPlayer == nil)
        let zoneRect = root.convert(root.bounds, to: top)
        for id in clips {
            guard let clip = orca.clip(id), let loop = view.outdoor.player else {
                check("zone orca \(label) \(id): the loop playing", false)
                continue
            }
            // A second from the loop's end, so the wait for frame 0 is short.
            zoneOrcaWait(3) { loop.currentItem?.status == .readyToPlay && loop.rate > 0 }
            var sought = false
            loop.seek(to: CMTime(value: 271, timescale: 24), toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought = true }
            zoneOrcaWait(2) { sought }
            zoneOrcaWait(0.3) { false }
            print("      zone orca \(label) \(id): loop at \(String(format: "%.2f", loop.currentTime().seconds)) s when asked (sought \(sought))")
            let asked = view.outdoor.playOrca(id)
            let second = view.outdoor.playOrca(orca.ids.first { $0 != id } ?? "A")
            let layer = view.outdoor.orcaLayer
            let hiddenFirst = layer?.isHidden == true
            let want = fit.rect(clip.box)
            check("zone orca \(label) \(id): asked for, its layer is made in the orca layer at its box through the fit (\(layer.map { "\($0.frame.integral)" } ?? "none") vs \(want.integral)), hidden until it starts; a second clip meanwhile is refused (one player)",
                asked && !second && layer?.superlayer === view.outdoor.orca && hiddenFirst && layer.map { abs($0.frame.minX - want.minX) < 0.01 && abs($0.frame.minY - want.minY) < 0.01 && abs($0.frame.width - want.width) < 0.01 && abs($0.frame.height - want.height) < 0.01 } == true
                    && layer?.videoGravity == .resize && view.outdoor.orcaPlayer?.isMuted == true && view.outdoor.orcaCountdown == nil)
            // Within a loop (12 s) and a little: whatever the seek did, frame 0 comes round by then.
            let started = zoneOrcaWait(14) { (view.outdoor.orcaPlayer?.currentTime().seconds ?? 0) > 0.4 && view.outdoor.orcaLayer?.isHidden == false }
            var worst = 1.0
            for _ in 0..<5 {
                guard let p = view.outdoor.orcaPlayer else { break }
                let o = p.currentTime().seconds, l = loop.currentTime().seconds
                var d = (l - o).truncatingRemainder(dividingBy: orca.loopSeconds)
                if d > orca.loopSeconds / 2 { d -= orca.loopSeconds }
                if d < -orca.loopSeconds / 2 { d += orca.loopSeconds }
                worst = worst == 1.0 ? abs(d) : max(worst, abs(d))
                zoneOrcaWait(0.1) { false }
            }
            print("      zone orca \(label) \(id): started \(started), clip vs loop time apart at most \(String(format: "%.4f", worst)) s")
            check("zone orca \(label) \(id): it starts at the loop's frame 0 by the loop's own clock (clip time = loop time within one frame, 1/24 s), and shows then",
                started && worst < 1.0 / 24)
            let shown = layer.map { zonePanelFitVisible($0, in: top) } ?? .null
            check("zone orca \(label) \(id): the clip shows only inside the room (clipped by it, never in the title bar)",
                !shown.isNull && !shown.isEmpty && zoneRect.insetBy(dx: -0.5, dy: -0.5).contains(shown))
            if id == clips.last, label.hasPrefix("1180") {
                // Played through: hidden and let go after its length, and the next one counted down.
                let ended = zoneOrcaWait(clip.seconds + 1.5) { view.outdoor.orcaPlayer == nil }
                check("zone orca \(label) \(id): played once, then hidden and its player let go, and the next clip counted down again (3–8 min)",
                    ended && view.outdoor.orcaLayer == nil && (view.outdoor.orca.sublayers ?? []).isEmpty && view.outdoor.orcaCountdown.map { (180...480).contains($0) } == true
                        && view.outdoor.lastOrca == id)
            } else {
                // Hidden mid-clip: stopped and dropped; seen again, a fresh countdown and no clip.
                view.onScreenOverride = false
                view.syncOutdoor()
                let dropped = view.outdoor.orcaPlayer == nil && view.outdoor.orcaLayer == nil && (view.outdoor.orca.sublayers ?? []).isEmpty && view.outdoor.orcaCountdown == nil
                view.onScreenOverride = true
                view.syncOutdoor()
                check("zone orca \(label) \(id): hidden while it plays, the clip stops and is dropped (no player, no layer); seen again, no clip, a new countdown",
                    dropped && view.outdoor.orcaPlayer == nil && view.outdoor.orcaCountdown.map { (180...480).contains($0) } == true)
            }
        }
        // the crabs where C comes up on the sand fade out for it and back after it.
        if label.hasPrefix("1180") { zoneOrcaCrabFade(view, fit: fit, spec: spec, orca: orca) }
        // Reduce Motion while a clip is on its way: dropped.
        if label.hasPrefix("1180") {
            view.outdoor.playOrca("A")
            view.calmOverride = true
            view.syncOutdoor()
            check("zone orca \(label): Reduce Motion turned on with a clip on its way: dropped, nothing counted down",
                view.outdoor.orcaPlayer == nil && (view.outdoor.orca.sublayers ?? []).isEmpty && view.outdoor.orcaCountdown == nil)
            view.calmOverride = false
            view.syncOutdoor()
        }
    }

    // ── C's clear zone ──
    if let cz = orca.clip("C")?.clearZone, let cBox = orca.clip("C")?.box {
        let pic = CGRect(origin: .zero, size: orca.picture)
        var covered = 0, total = 0
        for y in stride(from: cBox.minY + 2, to: cBox.maxY, by: 4) {
            for x in stride(from: cBox.minX + 2, to: cBox.maxX, by: 4) {
                total += 1
                if cz.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) { covered += 1 }
            }
        }
        let share = Double(covered) / Double(max(1, total))
        print("      zone orca: C clear zone \(cz.count) rectangles covering \(Int((share * 100).rounded())) % of its box")
        check("zone orca: orca.json gives C a clear zone (where the orca really goes, + margin) well inside the picture and smaller than its box (the box is fitted tight to the new film, so under 75 %); A and B have none",
            !cz.isEmpty && cz.allSatisfy { pic.contains($0) && cBox.insetBy(dx: -31, dy: -31).contains($0) } && share < 0.75 && share > 0.1
                && orca.clip("A")?.clearZone.isEmpty == true && orca.clip("B")?.clearZone.isEmpty == true
                && ZoneOrcaSpec.stepAside(orca.clip("C")!) == cz && ZoneOrcaSpec.stepAside(orca.clip("A")!).isEmpty)
    } else {
        check("zone orca: C's clear zone", false)
    }

    // ── the films' alpha is premultiplied, as they are tagged (else a light rim round the orca) ──
    // The sea loop too (and its last frame, 287, is there: still 288 frames). A pixel or two a frame may come out
    // brighter from the codec's own noise (alpha and colour are coded apart); straight alpha gives thousands.
    var straight: [String] = []
    var films = orca.clips.map { (name: $0.id, url: ZoneOutdoorArt.orcaMovie($0.id), frame: $0.frames / 4) }
    films += [("loop", ZoneOutdoorArt.movie, 30), ("loop", ZoneOutdoorArt.movie, 287)]
    for film in films {
        guard let url = film.url, let (partial, over) = zoneOrcaAlphaSample(url, frame: film.frame) else {
            straight.append("\(film.name) frame \(film.frame): unread")
            continue
        }
        print("      zone orca: \(film.name) frame \(film.frame): \(over) of \(partial) part-clear pixels brighter than their alpha")
        if partial < 100 || Double(over) > Double(partial) * 0.001 { straight.append("\(film.name) \(over)/\(partial)") }
    }
    check("zone orca: each film, the clips and the sea loop, is premultiplied by its alpha as its AlphaChannelMode says (under 0.1 % of part-clear pixels brighter than their alpha; \(straight)); the loop still has its frame 287",
        straight.isEmpty)

    // ── The bundle and the debug hook ──
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let build = (try? String(contentsOf: sources.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
    let panelText = panelSources(sources)
    let viewText = (try? String(contentsOf: sources.appendingPathComponent("ZoneView.swift"), encoding: .utf8)) ?? ""
    check("zone orca: app/tools/orca_clear_zone.swift (to work C's clear zone out again from a new C.mov) is there",
        FileManager.default.fileExists(atPath: sources.appendingPathComponent("tools/orca_clear_zone.swift").path))
    check("zone orca: build.sh copies A.mov, B.mov, C.mov and orca.json into the bundle's zone3d",
        build.contains("cp themes/seaview/assets/A.mov themes/seaview/assets/B.mov themes/seaview/assets/C.mov themes/seaview/assets/orca.json \"$APP/Contents/Resources/zone3d/\""))
    check("zone orca: `--orca A` posts <bundle id>.orca, and the room listens for it",
        panelText.contains("Notification.Name(appID + \".orca\")") && zoneOrcaNote.rawValue == appID + ".orca" && panelText.contains("args.firstIndex(of: \"--orca\")")
            && viewText.contains("addObserver(forName: zoneOrcaNote"))
}

/// `--zone-orca-stills <dir>`: the panel at 1180×790 (offscreen, as the app makes it) with a frame of each clip laid over
/// the sea loop's same frame (a clip's frame k goes with the loop's frame k); whole and zoomed on the sea.
@MainActor func zoneOrcaStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    guard let spec = ZoneOutdoorArt.spec, let orca = ZoneOutdoorArt.orca else { return print("zone stills: no orca art") }
    let themeBefore = OfficeTheme.shown
    OfficeTheme.shown = OfficeTheme.zone
    defer { OfficeTheme.shown = themeBefore }
    let store = zoneOpenRoomCrowd()
    guard let (panel, view, top) = zoneOrcaPanel(CGSize(width: 1180, height: 790), store) else { return print("zone stills: no panel") }
    defer {
        view.stopListening()
        panel.orderOut(nil)
    }
    view.still = true
    view.update(store)
    let fit = ZoneFit(scene: spec.picture, view: view.bounds.size)
    let roomInWindow = view.convert(view.bounds, to: nil)
    // also C's strike: frame 1 with the gulls standing at their spots, frame 40 with them bursting away (posed along their paths).
    for (id, k) in [("A", 44), ("A", 66), ("B", 60), ("C", 80), ("C", 140), ("C", 1), ("C", 40)] {
        guard let clip = orca.clip(id) else { continue }
        view.outdoor.pose(at: Double(k) / spec.fps)
        view.outdoor.poseOrcaForCheck(id, frame: k)
        if id == "C", k <= 40, let strike = clip.strike { view.outdoor.poseStrikeForCheck(strike, burst: k == 1 ? nil : 0.12) }
        guard let rep = zonePanelFitRender(top), let image = rep.cgImage else { continue }
        let name = "orca-\(id)-\(k)"
        if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("zone stills: wrote \(dir)/\(name).png")
        }
        // The sea, zoomed: the loop's box through the fit, in the window (top-left rows).
        let titleTop = top.bounds.height - roomInWindow.maxY
        let sea = fit.rect(spec.loopBox).offsetBy(dx: roomInWindow.minX, dy: titleTop).intersection(CGRect(origin: .zero, size: top.bounds.size))
        let sx = CGFloat(image.width) / top.bounds.width
        if let crop = image.cropping(to: CGRect(x: sea.minX * sx, y: sea.minY * sx, width: sea.width * sx, height: sea.height * sx)),
            let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)-sea.png"))
        }
    }
}

/// frame `frame` of a film decoded to BGRA as AVFoundation hands it to the screen: how many part-clear pixels
/// (alpha 9…239) there are, and how many have a colour above their alpha (impossible when premultiplied, as it is tagged).
func zoneOrcaAlphaSample(_ url: URL, frame: Int) -> (Int, Int)? {
    final class Box: @unchecked Sendable { var result: (Int, Int)? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        guard reader.startReading() else { return }
        var n = 0
        while let sample = out.copyNextSampleBuffer() {
            defer { n += 1 }
            guard n == frame, let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            let p = base.assumingMemoryBound(to: UInt8.self)
            var partial = 0, over = 0
            for y in 0..<h {
                for x in 0..<w {
                    let o = y * row + x * 4, a = Int(p[o + 3])
                    guard a > 8 && a < 240 else { continue }
                    partial += 1
                    if max(Int(p[o]), Int(p[o + 1]), Int(p[o + 2])) > a + 6 { over += 1 }
                }
            }
            box.result = (partial, over)
            reader.cancelReading()
            return
        }
    }
    _ = done.wait(timeout: .now() + 20)
    return box.result
}

/// with C on its way, the crabs whose frame meets C's box fade out 0.5 s before it starts and fade back 1 s
/// after it ends; the others are untouched. A fades nobody.
@MainActor func zoneOrcaCrabFade(_ view: ZoneView, fit: ZoneFit, spec: ZoneOutdoorSpec, orca: ZoneOrcaSpec) {
    // the crabs do not fade for C: they run off (each its own way) and come back; gulls land at the spot and burst.
    let o = view.outdoor
    guard let c = orca.clip("C"), let loop = o.player, o.crabs.count >= 2 else {
        check("zone crabs: the loop and two crabs", false)
        return
    }
    func frame(_ k: ZoneOutdoor.Crab, _ p: CGPoint) -> CGRect {
        let s = spec.dweller(k.species)!
        return CGRect(x: p.x - s.foot.x, y: p.y - s.foot.y, width: s.size.width, height: s.size.height)
    }
    var rng = ZoneRandom(seed: 21)
    let zone = ZoneOrcaSpec.stepAside(c)
    func spot(_ k: ZoneOutdoor.Crab, inBox: Bool) -> CGPoint? {
        for _ in 0..<4000 {
            guard let p = ZoneOutdoorGeometry.randomPoint(in: spec.dweller(k.species)!.beach, using: &rng) else { return nil }
            let r = frame(k, p)
            if inBox ? zone.contains(where: { $0.contains(CGPoint(x: r.midX, y: r.midY)) }) && !spec.onDeck(p) : !zone.contains(where: { r.insetBy(dx: -60, dy: -60).intersects($0) }) { return p }
        }
        return nil
    }
    zoneOrcaWait(1.6) { false }
    // One crab on the sand in C's zone; one on the deck just behind the railing below the strike (safe: it must not
    // run); the rest well outside it.
    let inside = Array(o.crabs.prefix(1)), deckCrab = o.crabs[1], outside = Array(o.crabs.dropFirst(2))
    var pins: [CGPoint] = []
    for k in inside {
        guard let p = spot(k, inBox: true) else { return check("zone crabs: a crab in C's zone", false) }
        o.standForCheck(k, at: p)
        pins.append(p)
    }
    let deckX: CGFloat = 1950
    let deckPin: CGPoint? = spec.deckLine.map { a, b in CGPoint(x: deckX, y: a.y + (b.y - a.y) * (deckX - a.x) / (b.x - a.x) + 30) }
    guard let deckPin, spec.onDeck(deckPin), zone.contains(where: { frame(deckCrab, deckPin).intersects($0) }) else {
        return check("zone crabs: outdoor.json has a deck line, and a spot on the deck just below the strike", false)
    }
    o.standForCheck(deckCrab, at: deckPin)
    for k in outside { if let p = spot(k, inBox: false) { o.standForCheck(k, at: p) } }
    for w in o.walkers { if let p = spot(w, inBox: false) { o.standForCheck(w, at: p) } }
    func seek(_ frame: Int) {
        zoneOrcaWait(3) { loop.currentItem?.status == .readyToPlay && loop.rate > 0 }
        var sought = false
        loop.seek(to: CMTime(value: CMTimeValue(frame), timescale: 24), toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought = true }
        zoneOrcaWait(2) { sought }
    }
    func hostNow() -> Double { CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())) }
    // A: nobody runs.
    seek(271)
    _ = o.playOrca("A")
    zoneOrcaWait(3) { o.orcaStart != nil }
    let aStart = o.orcaStart.map(CMTimeGetSeconds) ?? hostNow()
    zoneOrcaWait(max(0, aStart - hostNow()) + 0.3) { false }
    let aNobody = (o.crabs + o.walkers).allSatisfy { !$0.fleeing && $0.layer.opacity == 1 } && o.strikeGulls.isEmpty
    view.onScreenOverride = false
    view.syncOutdoor()
    view.onScreenOverride = true
    view.syncOutdoor()
    for (k, p) in zip(inside, pins) { o.standForCheck(k, at: p) }
    o.standForCheck(deckCrab, at: deckPin)
    for k in outside { o.standForCheck(k, at: k.at) }
    check("zone crabs: A (out at sea, no strike) sends nobody running and lands no gull", aNobody)

    // C: gulls land, the animals in the zone run 1.2 s before, each its own way; none fades.
    seek(150)
    let asked = o.playOrca("C")
    zoneOrcaWait(3) { o.orcaStart != nil }
    guard asked, let startTime = o.orcaStart else { return check("zone crabs: C armed", false) }
    let start = CMTimeGetSeconds(startTime), lead = start - hostNow()
    zoneOrcaWait(max(0, start - 1.6 - hostNow())) { false }
    let notYet = inside.allSatisfy { !$0.fleeing }
    let landed = o.strikeGulls.count >= 2 && o.strikeGulls.allSatisfy { $0.standing && $0.gull.superlayer === o.gulls }
    let gullFeet = o.strikeGulls.map(\.foot), spots = c.strike?.gullSpots ?? []
    zoneOrcaWait(max(0, start - 0.8 - hostNow())) { false }
    let running = inside.allSatisfy { $0.fleeing && $0.layer.opacity == 1 && $0.layer.animation(forKey: "walk") != nil }
    let clear = inside.allSatisfy { k in k.refuge.map { r in !zone.contains { frame(k, r).intersects($0) } } ?? false }
    let ways = inside.map { k -> CGFloat in atan2((k.refuge ?? k.at).y - (k.home?.y ?? 0), (k.refuge ?? k.at).x - (k.home?.x ?? 0)) }
    let othersKept = outside.allSatisfy { !$0.fleeing && $0.layer.opacity == 1 }
    let deckStays = !deckCrab.fleeing && deckCrab.layer.animation(forKey: "walk") == nil
    print("      zone orca strike: C armed \(String(format: "%.2f", lead)) s ahead; gulls \(o.strikeGulls.map { "\(spec.gulls[$0.species].kind) standing \($0.standing) at \(Int($0.foot.x)),\(Int($0.foot.y))" }); runners \(inside.map { "\(spec.crabs[$0.species].kind) from \(Int($0.home?.x ?? 0)),\(Int($0.home?.y ?? 0)) to \(Int($0.refuge?.x ?? 0)),\(Int($0.refuge?.y ?? 0))" }) ways \(ways.map { Int($0 * 180 / .pi) })°")
    check("zone orca strike: C is armed 5 s ahead; by 1.6 s before it 2–3 gulls stand at the strike spots (orca.json), nobody has run yet",
        lead >= 4.9 && notYet && landed && gullFeet.allSatisfy { f in spots.contains(f) })
    check("zone crabs: 0.8 s before C the crab on the sand in its zone is running (seen, opacity 1) to a spot clear of it; the others stay",
        running && clear && othersKept)
    check("zone crabs: a crab on the deck behind the railing, right below the strike, stays put (it is safe there; only those on the sand run)",
        deckStays)
    // The burst: every gull up and away, each its own way.
    zoneOrcaWait(max(0, start + 40.0 / 24 - hostNow())) { false }
    let heads = o.strikeGulls.compactMap { $0.path?.heading }.map { atan2($0.dy, $0.dx) }
    var minGap = CGFloat.pi
    for i in heads.indices { for j in heads.indices where j > i { var d = abs(heads[i] - heads[j]); if d > .pi { d = 2 * .pi - d }; minGap = min(minGap, d) } }
    let allUp = !o.strikeGulls.isEmpty && o.strikeGulls.allSatisfy { !$0.standing && $0.path?.landing == false && $0.gull.animation(forKey: "fly") != nil }
    print("      zone orca strike: burst headings \(heads.map { Int($0 * 180 / .pi) })° (closest pair \(Int(minGap * 180 / .pi))°)")
    check("zone orca strike: at the strike every standing gull bursts up, all different ways (headings at least 60° apart)", allUp && minGap >= .pi / 3)
    // After: still waiting just after the end, then back home.
    let end = start + c.seconds
    zoneOrcaWait(max(0, end + 0.6 - hostNow())) { false }
    let waiting = inside.allSatisfy { $0.fleeing && $0.layer.opacity == 1 } && o.orcaPlayer == nil
    zoneOrcaWait(max(0, end + 0.3 + 6.3 - hostNow())) { false }
    let home = zip(inside, pins).allSatisfy { k, p in !k.fleeing && hypot(k.at.x - p.x, k.at.y - p.y) < 1 }
    check("zone crabs: after C they wait where they ran to, then (2–6 s later) walk back to where they were", waiting && home)

    // Hidden while C plays with crabs running: everything settles at once, gulls gone.
    for (k, p) in zip(inside, pins) { o.standForCheck(k, at: p) }
    seek(150)
    _ = o.playOrca("C")
    zoneOrcaWait(3) { o.orcaStart != nil }
    let s2 = o.orcaStart.map(CMTimeGetSeconds) ?? hostNow()
    zoneOrcaWait(max(0, s2 - hostNow()) + 0.3) { false }
    let wasRunning = inside.contains { $0.fleeing }
    view.onScreenOverride = false
    view.syncOutdoor()
    let restored = (o.crabs + o.walkers).allSatisfy { !$0.fleeing && $0.layer.opacity == 1 } && o.strikeGulls.isEmpty
    view.onScreenOverride = true
    view.syncOutdoor()
    check("zone crabs: hidden while C plays with crabs running: the clip is dropped, nobody is left running, the strike gulls are gone", wasRunning && restored)
}

/// the beach walkers, scatter routes and the gull burst, as pure geometry and spec checks.
@MainActor func zoneBeachTests() {
    guard let spec = ZoneOutdoorArt.spec, let orca = ZoneOutdoorArt.orca, let c = orca.clip("C") else {
        return check("zone orca strike: outdoor.json and orca.json read", false)
    }
    let kinds = spec.walkers.map(\.kind)
    check("zone orca strike: outdoor.json `walkers`: sandpiper (6 frames, runs 1–4, pecks 5–6, scatters), turtle (8, crawls 1–4, rests 5–8, lives outside the strike), clam (1, stationary, fixed)",
        kinds == ["sandpiper", "turtle", "clam"] && spec.walkers.map(\.frames) == [6, 8, 1]
            && spec.walkers.map(\.behavior) == [.shoreRun, .crawlRest, .stationary] && spec.walkers.map(\.threat) == [.scatter, .outside, .fixed]
            && spec.walkers[0].walkFrames == 1...4 && spec.walkers[0].idleFrames == 5...6 && spec.walkers[1].idleFrames == 5...8 && spec.walkers[2].speed == 0)
    check("zone orca strike: each walker loads its own sprites (6 / 8 / 1), each gull species has a standing pair",
        spec.walkers.indices.map { ZoneOutdoorArt.crabFrames(spec.crabs.count + $0).count } == [6, 8, 1]
            && spec.gulls.allSatisfy { ZoneOutdoorArt.standFrames($0.kind).count == 2 })
    let turtle = spec.walkers[1], zone = ZoneOrcaSpec.stepAside(c)
    check("zone orca strike: the turtle's beach lies clear of C's strike zone", !zone.contains { r in turtle.beach.contains { r.contains($0) } })
    // Live: one sandpiper and one clam at least, on their own beaches, in the beach layer.
    let size = CGSize(width: 1180, height: 758), fit = ZoneFit(scene: spec.picture, view: size)
    var placed = true
    for seed in 0..<20 {
        let o = ZoneOutdoor(seed: UInt64(seed))
        o.configure(live: true, fit: fit, bounds: CGRect(origin: .zero, size: size), seeded: false)
        let ks = o.walkers.map { spec.dweller($0.species)!.kind }
        if !(ks.contains("sandpiper") && ks.contains("clam")) || !o.walkers.allSatisfy({ $0.layer.superlayer === o.beach && ZoneOutdoorGeometry.contains(spec.dweller($0.species)!.beach, $0.at) }) { placed = false }
    }
    check("zone orca strike: live, every beach has a sandpiper and a clam (the turtle now and then), each on its own beach, in the beach layer", placed)
    // Scatter: from one spot, many tries: different ways, all away from the way in, never back at the orca, clear of the zone, on the beach.
    guard let strike = c.strike, let crab = spec.crabs.first else { return check("zone orca strike: C has a strike in orca.json", false) }
    func frame(_ p: CGPoint) -> CGRect { CGRect(x: p.x - crab.foot.x, y: p.y - crab.foot.y, width: crab.size.width, height: crab.size.height) }
    var rng = ZoneRandom(seed: 3)
    var start: CGPoint?
    for _ in 0..<4000 {
        if let p = ZoneOutdoorGeometry.randomPoint(in: crab.beach, using: &rng), zone.contains(where: { $0.contains(CGPoint(x: frame(p).midX, y: frame(p).midY)) }) { start = p; break }
    }
    guard let from = start else { return check("zone orca strike: a spot in C's zone on the crab beach", false) }
    var angles: [CGFloat] = [], ok = true, speeds = Set<Int>(), ends: [CGPoint] = []
    for _ in 0..<12 {
        let legs = ZoneOutdoorGeometry.scatter(from: from, crab: crab, strike: strike, keepOut: zone, frame: frame, using: &rng)
        guard let last = legs.last?.walk, let first = legs.first?.walk else { ok = false; continue }
        let to = last.to
        angles.append(atan2(first.to.y - from.y, first.to.x - from.x))
        ends.append(to)
        speeds.insert(Int(hypot(first.to.x - first.from.x, first.to.y - first.from.y) / max(1e-6, first.seconds)))
        let h = strike.heading
        let d = CGVector(dx: to.x - from.x, dy: to.y - from.y), l = max(1e-6, hypot(d.dx, d.dy))
        if (d.dx * -h.dx + d.dy * -h.dy) / l > 0.64 + 1e-6 || zone.contains(where: { frame(to).intersects($0) })
            || !ZoneOutdoorGeometry.contains(crab.beach, to) { ok = false }
    }
    // Circular spread: the widest gap left open round the circle, subtracted from 360°.
    let sorted = angles.map { $0 < 0 ? $0 + 2 * .pi : $0 }.sorted()
    var gap: CGFloat = sorted.isEmpty ? 2 * .pi : sorted.first! + 2 * .pi - sorted.last!
    for (x, y) in zip(sorted, sorted.dropFirst()) { gap = max(gap, y - x) }
    let spreadDeg = (2 * .pi - gap) * 180 / .pi
    print("      zone orca strike: 12 escapes from \(Int(from.x)),\(Int(from.y)): ways \(angles.map { Int($0 * 180 / .pi) })°, speeds \(speeds.sorted()) px/s")
    let mx = ends.map(\.x).reduce(0, +) / CGFloat(max(1, ends.count)), my = ends.map(\.y).reduce(0, +) / CGFloat(max(1, ends.count))
    let endSpread = (ends.map { hypot($0.x - mx, $0.y - my) }.reduce(0, +) / CGFloat(max(1, ends.count)))
    print("      zone orca strike: escape ends spread \(Int(endSpread)) px round their middle, first legs over \(Int(spreadDeg))°")
    check("zone orca strike: escapes from one spot each take their own route (first legs over \(Int(spreadDeg))° ≥ 30°, ends \(Int(endSpread)) px apart on average ≥ 25) at different speeds, never back at the orca coming in (within 50°), clear of the zone, on the beach",
        ok && angles.count == 12 && spreadDeg >= 30 && endSpread >= 25 && speeds.count >= 6)
    // The burst.
    let feet = strike.gullSpots, species = feet.indices.map { $0 % spec.gulls.count }
    var allApart = true
    for seed in 0..<40 {
        var r = ZoneRandom(seed: UInt64(seed))
        let paths = ZoneOutdoorGeometry.gullBurst(from: feet, species: species, delays: feet.map { _ in 0 }, spec: spec, using: &r)
        let hs = paths.map { atan2($0.heading.dy, $0.heading.dx) }
        for i in hs.indices { for j in hs.indices where j > i { var d = abs(hs[i] - hs[j]); if d > .pi { d = 2 * .pi - d }; if d < .pi / 3 { allApart = false } } }
        if Set(paths.map { Int($0.h1 * 10) }).count < min(2, paths.count) { allApart = false }
    }
    check("zone orca strike: a burst sends each gull its own way (always ≥ 60° apart over 40 bursts), each its own climb", allApart && feet.count >= 2)
}

extension ZoneOutdoor {
    /// For the orca checks' log: whether a crab, standing where it is, meets a zone.
    func crabsMeeting(_ zone: [CGRect], _ c: Crab) -> Bool { let f = crabFrame(c, at: c.at); return zone.contains { f.intersects($0) } }
}

// ───────── off duty (off-duty mode) ─────────

/// Runs the main run loop until `ok` or the time is up (the script's runs come back on the main queue).
@MainActor func zoneOffDutyWait(_ seconds: Double, _ ok: () -> Bool) -> Bool {
    let end = Date() + seconds
    while !ok() && Date() < end { RunLoop.main.run(until: Date() + 0.05) }
    return ok()
}

/// A stand-in for offduty.py: writes its arguments to `log` (one line a run), waits `pause` seconds, and when `fail` is
/// "fail" writes two lines to stderr and exits 3. Nothing real is ever run.
@MainActor func zoneOffDutyStub(_ dir: String) -> String {
    let path = dir + "/offduty-stub.sh"
    let body = """
        #!/bin/bash
        log="$1"; mode="$2"; pause="$3"; shift 3
        echo "$*" >> "$log"
        sleep "$pause"
        if [ "$mode" = "fail" ]; then echo "Traceback: first line" >&2; echo "boom: $* refused" >&2; exit 3; fi
        exit 0
        """
    try? body.write(toFile: path, atomically: true, encoding: .utf8)
    return path
}

@MainActor func zoneOffDutyTests() {
    let dir = NSTemporaryDirectory() + "zone-duty-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let defaults = UserDefaults.standard
    let keys = ["office", "officeTheme", ZoneMemory.key]
    let kept = keys.map { defaults.object(forKey: $0) }
    let rosterBefore = ZoneRosterFile.path
    let duty = ZoneOffDuty.shared
    let launcherBefore = duty.launcher, sinkBefore = duty.logSink
    var logged: [String] = []
    duty.logSink = { logged.append($0) }
    defer {
        for (key, value) in zip(keys, kept) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        ZoneRosterFile.path = rosterBefore
        ZoneRosterFile.reset()
        duty.launcher = launcherBefore
        duty.logSink = sinkBefore
        duty.reset()
        ZoneMemory.remembered = [:]
        ZoneMemory.holders = [:]
        ZoneUI.open = nil
        try? FileManager.default.removeItem(atPath: dir)
    }
    ZoneMemory.remembered = [:]
    ZoneMemory.holders = [:]
    duty.reset()
    let now = Date()
    let t0 = now.timeIntervalSince1970

    // ── The roster file ──
    let valid = """
        {"Web-对星": {"cwd": "/tmp/a", "sid": "s1", "bypass": true, "argv": [], "lastActive": \(t0 - 5 * 3600), "offAt": \(t0 - 600), "terminal": "orca", "zone": "Web"},
         "未分区会话": {"cwd": "/tmp/b", "sid": "s2", "lastActive": \(t0 - 13 * 3600), "offAt": \(t0 - 60), "zone": "未分区"}}
        """
    let parsed = ZoneRoster.parse(Data(valid.utf8))
    check("zone off duty: a roster is read by name with its cwd, sid, zone and both times",
        parsed?.count == 2 && parsed?["Web-对星"]?.zone == "Web" && parsed?["Web-对星"]?.sid == "s1" && parsed?["Web-对星"]?.cwd == "/tmp/a"
            && parsed?["Web-对星"]?.lastActive.map { abs($0.timeIntervalSince1970 - (t0 - 5 * 3600)) < 0.01 } == true
            && parsed?["未分区会话"]?.offAt.map { abs($0.timeIntervalSince1970 - (t0 - 60)) < 0.01 } == true)
    check("zone off duty: an empty roster `{}` is empty; a half-written or broken one is no reading at all",
        ZoneRoster.parse(Data("{}".utf8)) == [:] && ZoneRoster.parse(Data("{\"Web-x\": {\"cwd\": ".utf8)) == nil
            && ZoneRoster.parse(Data("[1, 2]".utf8)) == nil && ZoneRoster.parse(Data()) == nil)
    let rosterPath = dir + "/roster.json"
    ZoneRosterFile.path = rosterPath
    ZoneRosterFile.reset()
    let missing = ZoneRosterFile.current().count
    try? valid.write(toFile: rosterPath, atomically: true, encoding: .utf8)
    let good = ZoneRosterFile.current().count
    try? "{\"Web-对星\": {\"cwd\": \"/tm".write(toFile: rosterPath, atomically: true, encoding: .utf8)
    let afterBroken = ZoneRosterFile.current().count
    try? FileManager.default.removeItem(atPath: rosterPath)
    let afterGone = ZoneRosterFile.current().count
    try? "{}".write(toFile: rosterPath, atomically: true, encoding: .utf8)
    let afterEmpty = ZoneRosterFile.current().count
    check("zone off duty: roster.json is read again when it changes; broken or missing keeps the last good reading; `{}` empties it",
        missing == 0 && good == 2 && afterBroken == 2 && afterGone == 2 && afterEmpty == 0)
    check("zone off duty: a row says last-active X hours ago and off-duty-since HH:mm",
        ZoneRoster.lastActive(now - 5 * 3600 - 100, now: now) == "最后活动 5 小时前" && ZoneRoster.lastActive(now - 1200, now: now) == "最后活动 20 分钟前"
            && ZoneRoster.offAt(now, now: now).range(of: #"^下班于 \d\d:\d\d$"#, options: .regularExpression) != nil)

    // ── Desks ──
    let plain = """
        {"zones": {"Web": {"name": "Web", "order": 1, "lead": "Web-L"}, "Ops": {"name": "Ops", "order": 2, "lead": "Ops-L"}},
         "dirs": {}, "default": null,
         "offduty": {"idle_hours": 12, "resident": ["Web-R"], "resident_zones": ["Ops"]}}
        """
    let config = ZoneConfig.parse(Data(plain.utf8), home: "/Users/tester")
    check("zone off duty: workzones.json's offduty gives the residents: the list, the whole zones, and every lead",
        config.isResident("Web-R", zone: "Web") && config.isResident("Ops-x", zone: "Ops") && config.isResident("Web-L", zone: "Web")
            && !config.isResident("Web-n", zone: "Web") && !config.isResident("Web-L", zone: "Nope") && !config.isResident("Ops-x", zone: "Web"))
    func m(_ name: String, _ zone: String, _ state: ZoneState = .busy) -> ZoneMember {
        ZoneMember(id: "duty-" + name, name: name, zone: zone, state: state, since: now - 60)
    }
    let memory = ["Web-L": "Web#1", "Web-R": "Web#3", "Web-n": "Web#4", "Ops-x": "Ops#2", "Web-m": "Web#7"]
    let offDuty = ["Web-L": "Web", "Web-R": "Web", "Web-n": "Web", "Ops-x": "Ops", "Web-m": "Web"]
    let newcomers = [m("Web-a", "Web"), m("Web-b", "Web"), m("Web-c", "Web"), m("Ops-new", "Ops")]
    let first = ZonePlan.make(newcomers, config: config, memory: memory, sofaSeats: [:], offDuty: offDuty)
    let firstKeys = Set(newcomers.prefix(3).compactMap { first.desks[$0.id]?.key })
    check("zone off duty: residents never lose desks: off duty, the lead's desk 1, a listed resident's and a resident zone's stay free",
        firstKeys == ["Web#2", "Web#4", "Web#5"] && first.desks[m("Ops-new", "Ops").id]?.key == "Ops#3")
    check("zone off duty: an off-duty non-resident frees its desk (a newcomer takes Web#4), and its desk stays remembered by name",
        first.desks[m("Web-b", "Web").id]?.key == "Web#4" && first.memory["Web-n"] == "Web#4" && first.memory["Web-R"] == "Web#3")
    // Web-n wakes up (listed first, so order alone would hand it Web#4); Web-m wakes up to its free old desk.
    var holders: [String: String] = [:]
    for x in newcomers { if let d = first.desks[x.id] { holders[d.key] = x.name } }
    var stillOff = offDuty
    stillOff["Web-n"] = nil
    stillOff["Web-m"] = nil
    let back = ZonePlan.make([m("Web-n", "Web"), m("Web-m", "Web")] + newcomers, config: config, memory: first.memory, sofaSeats: [:],
                             offDuty: stillOff, holders: holders)
    check("zone off duty: woken, one goes back to its old desk if free (Web-m to Web#7), else its zone's first free (Web-n to Web#6)",
        back.desks[m("Web-m", "Web").id]?.key == "Web#7" && back.desks[m("Web-n", "Web").id]?.key == "Web#6"
            && back.desks[m("Web-b", "Web").id]?.key == "Web#4" && back.memory["Web-n"] == "Web#6")
    let rWakes = ZonePlan.make([m("Web-R", "Web")] + newcomers, config: config, memory: first.memory, sofaSeats: [:],
                               offDuty: ["Web-n": "Web"], holders: holders)
    check("zone off duty: a resident woken (or back by hand) is on its own desk again", rWakes.desks[m("Web-R", "Web").id]?.key == "Web#3")
    var big: [String: String] = [:]
    for i in 0..<420 { big["closed-\(i)"] = "Web#\(2 + i % 11)" }
    big["Web-n"] = "Web#9"
    let pruned = ZonePlan.make([m("Web-a", "Web")], config: config, memory: big, sofaSeats: [:], offDuty: ["Web-n": "Web"])
    check("zone off duty: when the desk memory is cut back, the off-duty keep theirs", pruned.memory["Web-n"] == "Web#9" && pruned.memory["closed-1"] == nil)

    // ── Waking and sending off, through a stub ──
    let stub = zoneOffDutyStub(dir)
    let calls = dir + "/calls.log"
    func lines() -> [String] { ((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    duty.launcher = ["/bin/bash", stub, calls, "ok", "0.4"]
    let entry = ZoneRosterEntry(name: "Web-n", cwd: "/tmp/a", zone: "Web", lastActive: now - 13 * 3600, offAt: now - 600)
    let store = Store()
    store.readOnly = true
    let startedAt = Date()
    let one = duty.wake(entry, store: store)
    let mainFree = Date().timeIntervalSince(startedAt) < 0.2
    let two = duty.wake(entry, store: store)
    check("zone off duty: one wake per name at a time (a second click while it runs starts nothing); the UI is not held up",
        one && !two && duty.state(of: "Web-n") == .waking && mainFree)
    let exited = zoneOffDutyWait(5) { duty.waking["Web-n"]?.exited != nil }
    check("zone off duty: a wake runs `offduty.py --wake <name>` once", exited && lines() == ["--wake Web-n"])
    check("zone off duty: after the script says yes the row still says waking… and is counted until the session is in the registry",
        duty.state(of: "Web-n") == .waking && ZoneListCard.offWords(entry, now: Date()) == ["唤醒中…"]
            && duty.shown(roster: [:], awake: []).map(\.name) == ["Web-n"])
    duty.settle(awake: ["Web-n"])
    check("zone off duty: once in the registry it is no longer listed off duty", duty.state(of: "Web-n") == .off && duty.shown(roster: [:], awake: []).isEmpty)
    // A wake that fails.
    duty.launcher = ["/bin/bash", stub, calls, "fail", "0.1"]
    logged = []
    duty.wake(entry, store: store)
    _ = zoneOffDutyWait(5) { duty.state(of: "Web-n") != .waking }
    check("zone off duty: a failed wake shows wake failed and is logged with the end of its stderr",
        duty.state(of: "Web-n") == .failed && ZoneListCard.offWords(entry, now: Date()) == ["唤醒失败"]
            && logged.count == 1 && logged[0].contains("wake Web-n failed") && logged[0].contains("exit code 3") && logged[0].contains("boom: --wake Web-n refused"))
    check("zone off duty: wake failed goes after ten seconds", duty.state(of: "Web-n", now: Date() + 11) == .off)
    // Sending off.
    duty.launcher = ["/bin/bash", stub, calls, "ok", "0.1"]
    try? FileManager.default.removeItem(atPath: calls)
    let sent = duty.sendOff("Web-x", store: store), again = duty.sendOff("Web-x", store: store)
    _ = zoneOffDutyWait(5) { !duty.sending.contains("Web-x") }
    check("zone off duty: send-off-duty runs `offduty.py --off <name>` once", sent && !again && lines() == ["--off Web-x"] && !duty.refused("Web-x"))

    // ── The menu ──
    defaults.set(true, forKey: "office")
    defaults.set(OfficeTheme.zone.name, forKey: "officeTheme")
    func sess(_ name: String, _ status: String, kind: String = "claude") -> Session {
        var s = Session(id: "duty-" + name, pid: 1, project: "p", name: name, status: status, since: now - 30, summary: "在做事")
        s.cwd = "/tmp"
        s.registryName = name
        s.kind = kind
        return s
    }
    func offers(_ s: Session) -> Bool { sessionMenu(store, s).contains { $0.action == .sendOff && $0.title == "送下班" && $0.enabled } }
    let idle = sess("Web-idle", "idle"), busy = sess("Web-busy", "busy"), waiting = sess("Web-wait", "waiting")
    var restarting = sess("Web-rs", "idle")
    restarting.restarting = true
    var nameless = sess("新会话", "idle")
    nameless.registryName = ""
    check("zone off duty: send-off-duty is on an idle figure's menu in Seaview, not a busy, waiting, restarting, unnamed or Codex one",
        offers(idle) && !offers(busy) && !offers(waiting) && !offers(restarting) && !offers(nameless) && !offers(sess("Codex-x", "idle", kind: "codex")))
    duty.launcher = ["/bin/bash", stub, calls, "ok", "0.6"]
    duty.sendOff("Web-idle", store: store)
    let offeredWhile = offers(idle)
    _ = zoneOffDutyWait(5) { !duty.sending.contains("Web-idle") }
    check("zone off duty: while a send is under way send-off-duty is not offered again; after it, it is", !offeredWhile && offers(idle))
    var elsewhere: [Bool] = []
    for theme in [OfficeTheme.studio.name, OfficeTheme.night.name] {
        defaults.set(theme, forKey: "officeTheme")
        elsewhere.append(offers(idle))
    }
    defaults.set(false, forKey: "office")
    elsewhere.append(offers(idle))
    check("zone off duty: other scenes are unaffected: no send-off-duty in the office (either theme) or the board", elsewhere == [false, false, false])
    defaults.set(true, forKey: "office")
    defaults.set(OfficeTheme.zone.name, forKey: "officeTheme")

    // ── The room: the badges, check-in, the list, a refusal over the head ──
    guard ZoneArt.scene != nil else { return check("zone off duty: the art", false) }
    let roster = """
        {"Web-睡1": {"cwd": "/tmp", "lastActive": \(t0 - 14 * 3600), "offAt": \(t0 - 3000), "zone": "Web"},
         "Web-睡2": {"cwd": "/tmp", "lastActive": \(t0 - 20 * 3600), "offAt": \(t0 - 2000), "zone": "Web"},
         "Ops-睡": {"cwd": "/tmp", "lastActive": \(t0 - 13 * 3600), "offAt": \(t0 - 1000), "zone": "Ops"},
         "无前缀": {"cwd": "/tmp", "lastActive": \(t0 - 15 * 3600), "offAt": \(t0 - 500), "zone": "未分区"},
         "Zzz-奇怪": {"cwd": "/tmp", "lastActive": \(t0 - 16 * 3600), "offAt": \(t0 - 400), "zone": "Zzz"}}
        """
    try? roster.write(toFile: rosterPath, atomically: true, encoding: .utf8)
    let room = Store()
    room.readOnly = true
    room.sessions = [sess("Web-idle", "idle"), sess("Web-busy", "busy"), sess("Ops-做事", "busy")]
    room.seen = Dictionary(uniqueKeysWithValues: room.sessions.map { ($0.id, now.timeIntervalSince1970) })
    room.assignPets()
    let before = room.sessions
    let view = ZoneView(frame: CGRect(x: 0, y: 0, width: 1180, height: 790))
    view.still = true
    view.update(room)
    let signZones = Set((ZoneArt.scene?.signs ?? []).map(\.zone))
    check("zone off duty: each zone sign has a badge with its off-duty count (Web 2, Ops 1), none at 0",
        view.offBadge("Web")?.count == 2 && view.offBadge("Ops")?.count == 1 && signZones.contains("AI") && view.offBadge("AI") == nil)
    check("zone off duty: roster entries of no sign's zone (unsorted, an unknown one) go to check-in, whose label shows for them alone",
        view.offBadge(ZonePlan.visitorKey)?.count == 2 && view.signPill(ZonePlan.visitorKey) != nil
            && Set(ZoneListCard.offRows(ZoneUI.visitorKey, store: room).map(\.name)) == ["无前缀", "Zzz-奇怪"])
    let badge = view.offBadge("Web")?.frame, pill = view.signPill("Web")
    check("zone off duty: the badge sits on its sign's pill's top right corner",
        badge.map { b in pill.map { $0.insetBy(dx: -b.width, dy: -b.height).contains(CGPoint(x: b.midX, y: b.midY)) && b.midX > $0.midX } ?? false } == true)
    let adminRows = ZoneListCard.offRows(ZoneUI.key("Web"), store: room)
    check("zone off duty: the Web list's off-duty rows, the latest gone first; none on the rest room's list; the sessions are untouched",
        adminRows.map(\.name) == ["Web-睡2", "Web-睡1"] && ZoneListCard.offRows(ZoneUI.restKey, store: room).isEmpty
            && room.sessions == before && ZoneListCard.rows(ZoneUI.key("Web"), store: room).rows.count == 2)
    if let pill {
        check("zone off duty: a click on the sign opens its list", view.target(at: CGPoint(x: pill.midX, y: pill.midY)) == .list(ZoneUI.key("Web")))
    }
    // A click on a row wakes it (through the stub); while it runs the badge still counts it after the roster drops it.
    duty.launcher = ["/bin/bash", stub, calls, "ok", "0.2"]
    try? FileManager.default.removeItem(atPath: calls)
    guard let firstRow = adminRows.first else { return check("zone off duty: the Web list has its off-duty rows to click", false) }
    duty.wake(firstRow, store: room)
    var dropped = ZoneRoster.parse(Data(roster.utf8)) ?? [:]
    dropped["Web-睡2"] = nil
    let droppedJSON = try? JSONSerialization.data(withJSONObject: dropped.mapValues { ["cwd": $0.cwd, "zone": $0.zone, "lastActive": $0.lastActive!.timeIntervalSince1970, "offAt": $0.offAt!.timeIntervalSince1970] })
    try? droppedJSON?.write(to: URL(fileURLWithPath: rosterPath))
    _ = zoneOffDutyWait(5) { duty.waking["Web-睡2"]?.exited != nil }
    view.update(room)
    check("zone off duty: being woken (gone from the roster already) it is still counted on the badge and listed as waking…",
        lines() == ["--wake Web-睡2"] && view.offBadge("Web")?.count == 2 && ZoneListCard.offWords(firstRow, now: Date()) == ["唤醒中…"])
    room.sessions.append(sess("Web-睡2", "idle"))
    room.assignPets()
    view.update(room)
    check("zone off duty: back in the registry, it is at a desk and the badge counts one", view.offBadge("Web")?.count == 1 && view.plan.desks["duty-Web-睡2"] != nil)
    // A refused send-off-duty says not sent over the head, and is logged.
    duty.launcher = ["/bin/bash", stub, calls, "fail", "0.1"]
    logged = []
    duty.sendOff("Web-idle", store: room)
    _ = zoneOffDutyWait(5) { !duty.sending.contains("Web-idle") }
    view.update(room)
    check("zone off duty: a refused send-off-duty shows not sent over the figure and is logged with stderr",
        view.bubbleKey(of: "duty-Web-idle").hasPrefix("refused") && logged.count == 1 && logged[0].contains("Web-idle")
            && logged[0].contains("boom: --off Web-idle refused"))
    duty.reset()
    view.update(room)
    check("zone off duty: …and it goes when the refusal has lapsed", !view.bubbleKey(of: "duty-Web-idle").hasPrefix("refused"))
    try? "{}".write(toFile: rosterPath, atomically: true, encoding: .utf8)
    view.update(room)
    check("zone off duty: an empty roster shows no badges", view.offBadge("Web") == nil && view.offBadge("Ops") == nil && view.offBadge(ZonePlan.visitorKey) == nil)
}

/// `--zone-duty-stills <dir>`: the crowded room with a fake roster, the Web sign's badge, and its list open (zone-offduty.png),
/// and a crop of the sign (zone-offduty-sign.png).
@MainActor func zoneOffDutyStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    let rosterBefore = ZoneRosterFile.path
    let tmp = NSTemporaryDirectory() + "zone-duty-still-\(getpid())"
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    defer {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
        ZoneRosterFile.path = rosterBefore
        ZoneRosterFile.reset()
        ZoneOffDuty.shared.reset()
        ZoneUI.open = nil
        try? FileManager.default.removeItem(atPath: tmp)
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            print("zone stills: could not draw \(name)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("zone stills: wrote \(dir)/\(name)")
    }
    guard ZoneArt.scene != nil else { return }
    let store = zoneOpenRoomCrowd()
    // The off-duty were open once: their names took pets then.
    let t0 = Date().timeIntervalSince1970
    let names = ["Web-月牙-八月", "Web-流星-导出", "Web-ABC-星云", "Ops-Demo-旧图纸", "临时-测试"]
    let crowd = store.sessions
    store.sessions = crowd + names.enumerated().map { i, n in
        var s = Session(id: "duty-off-\(i)", pid: 1, project: "p", name: n, status: "idle", since: Date() - 3600, summary: "")
        s.registryName = n
        return s
    }
    store.assignPets()
    store.sessions = crowd
    store.assignPets()
    var roster: [String: Any] = [:]
    for (i, n) in names.enumerated() {
        roster[n] = ["cwd": "/tmp", "sid": "s\(i)", "lastActive": t0 - Double(13 + i * 3) * 3600, "offAt": t0 - Double(1 + i) * 1700,
                     "zone": n.hasPrefix("Web") ? "Web" : n.hasPrefix("Ops") ? "Ops" : "未分区"]
    }
    ZoneRosterFile.path = tmp + "/roster.json"
    ZoneRosterFile.reset()
    try? JSONSerialization.data(withJSONObject: roster).write(to: URL(fileURLWithPath: ZoneRosterFile.path))
    // One of them being woken, to show the row's word.
    ZoneOffDuty.shared.launcher = ["/bin/sleep", "30"]
    if let e = ZoneRosterFile.current()["Web-流星-导出"] { ZoneOffDuty.shared.wake(e, store: store) }
    let size = CGSize(width: 1180, height: 790)
    let themeKeys = ["office", "officeTheme"], themeKept = themeKeys.map { UserDefaults.standard.object(forKey: $0) }
    UserDefaults.standard.set(true, forKey: "office")
    UserDefaults.standard.set(OfficeTheme.zone.name, forKey: "officeTheme")
    defer { for (k, v) in zip(themeKeys, themeKept) { if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) } } }
    ZoneUI.open = ZoneUI.key("Web")
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    print("zone stills: badges Web \(view.offBadge("Web")?.count ?? 0), Ops \(view.offBadge("Ops")?.count ?? 0), visitors \(view.offBadge(ZonePlan.visitorKey)?.count ?? 0)")
    // The list goes beside the sign, as the live panel's tracker would say.
    if let pill = view.signPill("Web") { store.tracker.frames[ZoneUI.key("Web")] = pill }
    write(zoneStill(store, size: size), "zone-offduty.png")
    ZoneUI.open = nil
    if let image = view.image(), let pill = view.signPill("Web") {
        let box = pill.insetBy(dx: -60, dy: -40).intersection(CGRect(origin: .zero, size: size))
        write(image.cropping(to: CGRect(x: box.minX * 2, y: box.minY * 2, width: box.width * 2, height: box.height * 2)), "zone-offduty-sign.png")
    }
    ZoneOffDuty.shared.launcher = ["/usr/bin/true"]
}

/// A titled panel the system would move onto a screen when it is ordered front (the checks' panel would otherwise keep popping up
/// on the desktop); this one stays where it is put, off every screen.
final class ZoneOffscreenPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    // Its opening animation is drawn on a screen even when the panel is not.
    override var animationBehavior: NSWindow.AnimationBehavior {
        get { .none }
        set {}
    }
    // The window server still keeps part of a titled window on a screen whatever its frame: so it is never seen and never
    // in the way. The checks read its layers, not the screen.
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        alphaValue = 0
        ignoresMouseEvents = true
    }
}


/// Workzones and the art's islands (points.json's islands are named Web, Ops, AI and Home): a zone sits on the island its
/// `island` names, else the one of its own name, else the next one left in its `order`; the scene the room draws goes by
/// the zone codes. A machine whose workzones have other names, ordered 1 to 4, keeps one island each, left to right.
@MainActor func zoneIslandTests() {
    let islands = ["Web", "Ops", "AI", "Home"]
    func zones(_ json: String) -> [ZoneConfig.Zone] { ZoneConfig.parse(Data(json.utf8), home: "/Users/tester").zones }
    let ordered = zones(#"{"zones": {"Delta": {"order": 4}, "Beta": {"order": 2}, "Alpha": {"order": 1}, "Gamma": {"order": 3}}}"#)
    check("zone islands: workzones of other names, ordered 1 to 4, sit on the islands left to right in that order",
        ZoneScene.seating(ordered, islands: islands) == ["Web": "Alpha", "Ops": "Beta", "AI": "Gamma", "Home": "Delta"])
    let named = zones(#"{"zones": {"Alpha": {"order": 1, "island": "Home"}, "Beta": {"order": 2}, "AI": {"order": 3}, "Gamma": {"order": 4, "island": "Nowhere"}}}"#)
    check("zone islands: an `island` field wins, a zone named as an island takes it, the rest go in order; an unknown island is ignored",
        named.first { $0.code == "Alpha" }?.island == "Home"
            && ZoneScene.seating(named, islands: islands) == ["Home": "Alpha", "AI": "AI", "Web": "Beta", "Ops": "Gamma"])
    let loose = zones(#"{"zones": {"Zed": {}, "Ops": {}, "Kay": {}}}"#)
    check("zone islands: with neither field nor order, the zones of no island's name go by code, the island of its own name kept",
        ZoneScene.seating(loose, islands: islands) == ["Ops": "Ops", "Web": "Kay", "AI": "Zed"])
    let crowd = zones(#"{"zones": {"A1": {"order": 1}, "A2": {"order": 2}, "A3": {"order": 3}, "A4": {"order": 4}, "A5": {"order": 5}}}"#)
    check("zone islands: a fifth zone gets no island", Set(ZoneScene.seating(crowd, islands: islands).values) == ["A1", "A2", "A3", "A4"])
    guard let plain = ZoneArt.plainScene else { return check("zone islands: the art", false) }
    check("zone islands: points.json names its islands Web, Ops, AI and Home, left to right", plain.islands == islands)
    let seated = plain.seated(ordered)
    let byZone = Dictionary(grouping: seated.desks, by: \.zone).mapValues(\.count)
    let sameDesks = plain.desks.allSatisfy { d in
        seated.desks.contains { $0.index == d.index && $0.seat == d.seat && $0.zone == ["Web": "Alpha", "Ops": "Beta", "AI": "Gamma", "Home": "Delta"][d.zone] }
    }
    check("zone islands: the seated scene names each island's desks, sofa and sign by its zone, every desk where it was",
        byZone == ["Alpha": 12, "Beta": 12, "Gamma": 12, "Delta": 12] && sameDesks && seated.islands == ["Alpha", "Beta", "Gamma", "Delta"]
            && Set(seated.sofas.map(\.zone)) == ["Alpha", "Beta", "Gamma", "Delta"] && Set(seated.signs.map(\.zone)) == ["Alpha", "Beta", "Gamma", "Delta"])
    let few = plain.seated(zones(#"{"zones": {"Alpha": {"order": 1}, "Web": {"order": 2, "island": "Home"}}}"#))
    check("zone islands: an island nobody sits on keeps its name, unless a zone elsewhere has it",
        few.islands == ["Alpha", "Ops", "AI", "Web"] && Set(few.desks.map(\.zone)) == ["Alpha", "Ops", "AI", "Web"])
    // The scene the room draws follows the workzones file.
    let dir = NSTemporaryDirectory() + "zone-islands-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let before = ZoneConfigFile.path
    defer { ZoneConfigFile.path = before }
    ZoneConfigFile.path = dir + "/workzones.json"
    try? #"{"zones": {"Alpha": {"order": 1}, "Beta": {"order": 2}, "Gamma": {"order": 3}, "Delta": {"order": 4}}}"#
        .write(toFile: ZoneConfigFile.path, atomically: true, encoding: .utf8)
    let live = ZoneArt.scene
    let store = Store()
    store.readOnly = true
    var s = Session(id: "zid-Delta-x", pid: 1, project: "p", name: "Delta-x", status: "busy", since: Date() - 100, summary: "")
    s.cwd = "/tmp"
    store.sessions = [s]
    let plan = ZonePlan.current(store, scene: live)
    let homeSeats = Set(plain.desks.filter { $0.zone == "Home" }.map { "\($0.seat)" })
    let seat = plan.desks["zid-Delta-x"].flatMap { live?.desk($0)?.seat }
    check("zone islands: the room's scene follows the workzones file: a session of the fourth zone sits at a desk of the fourth island",
        live?.islands == ["Alpha", "Beta", "Gamma", "Delta"] && plan.desks["zid-Delta-x"]?.zone == "Delta" && seat.map { homeSeats.contains("\($0)") } == true)
    // No off-duty tool (the public default): no send-off-duty, nothing woken, nothing run.
    let duty = ZoneOffDuty.shared, launcherBefore = duty.launcher
    duty.launcher = []
    let entry = ZoneRosterEntry(name: "Delta-y", cwd: "/tmp", zone: "Delta")
    check("zone islands: without an off-duty tool there is nothing to send off or wake",
        !duty.available && !duty.sendOff("Delta-y", store: nil) && !duty.wake(entry, store: nil) && duty.state(of: "Delta-y") == .off)
    duty.launcher = launcherBefore
    check("zone islands: the panel's own off-duty tool, roster and check-in files are not set here (no such tools with the panel)",
        localPath("offDutyScript", env: "SOULGENT_TEST_UNSET") == "" && localPath("rosterFile", env: "SOULGENT_TEST_UNSET") == "")
}
