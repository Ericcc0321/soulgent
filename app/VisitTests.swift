import AppKit
import QuartzCore

// Visit standing spots in the sea room: where a visitor stands at the one it came to see, for every desk, over two seaview arts
// (a reference art folder and the current one). `--visit-stills <dir>` writes crops and `visit-metrics.tsv` (variants before / now /
// fixed: reference art with the legacy search, current art with it, current art with the default); `visitTests()` (`--visit-only`,
// and in `--zone-only`) the checks.

/// One walk to a host's desk: who from where to where, and whether the room round them is full.
struct VisitCase {
    let id: String
    let from: (zone: String, index: Int)
    let to: (zone: String, index: Int)
    let dense: Bool
    var half = false
}

/// What a visit came to, in the picture's pixels (2400 × 1600).
struct VisitMeasure {
    var visitor = CGPoint.zero
    var host = CGPoint.zero
    var pixels: CGFloat = 0
    var metres: CGFloat = 0
    var onDesk = false
    var overlapped = 0
    var bubbleOff: CGFloat? = nil  // bubble centre − host, across, in view points
    var seatKnown = false
}

let visitZones = ["Web", "Ops", "AI", "Home"]
let visitWords = "端口改成 9000 了，你那边也改一下"

/// 12 invented sessions in each of the four zones, all at work; the lead of each is named as `seaSweepZonesJSON` has it.
@MainActor func visitRoom() -> Store {
    let now = Date()
    let store = Store()
    store.readOnly = true
    let leads = ["Web": "Web-DEMO-应用", "Ops": "Ops-Demo-协同", "AI": "AI-lead", "Home": "Home-lead"]
    let topics = ["星图", "云朵", "彩虹", "风筝", "月亮", "流星", "银河", "星座", "海浪", "童话", "晚霞"]
    var list: [Session] = []
    for zone in visitZones {
        for k in 0..<12 {
            let name = k == 0 ? leads[zone]! : "\(zone)-\(topics[k - 1])\(k)"
            var s = Session(id: "v-\(zone)-\(k)", pid: 1, project: name, name: name, status: "busy", since: now - Double(600 - k * 20 - list.count),
                            summary: "进行中", waitingFor: "")
            s.cwd = "/tmp/visit/" + name
            s.registryName = name
            s.tool = "Edit"
            list.append(s)
            store.seen[s.id] = now.timeIntervalSince1970
        }
    }
    store.sessions = list
    store.assignPets()
    return store
}

/// The cases: every desk as a host, with the room full and with only the two of them in it.
func visitCases() -> [VisitCase] {
    var cases: [VisitCase] = []
    for dense in [true, false] {
        for zone in visitZones {
            for index in 1...12 {
                let from: (String, Int) = zone == "Web" ? ("Web", index <= 6 ? 12 : 4) : ("Web", 5)
                cases.append(VisitCase(id: "\(dense ? "dense" : "sparse")-\(from.0)\(from.1)-to-\(zone)\(index)", from: from, to: (zone, index), dense: dense))
            }
        }
    }
    return cases
}

/// A fresh still view of the room with the case's visit under way; its measure, the view and the ids.
@MainActor func visitRun(_ c: VisitCase, size: CGSize, words: String = visitWords) -> (VisitMeasure, ZoneView, Store, String, String)? {
    guard let scene = ZoneArt.scene else { return nil }
    let store = visitRoom()
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    func id(_ k: (zone: String, index: Int)) -> String? { store.sessions.first { view.plan.desks[$0.id].map { $0.zone == k.zone && $0.index == k.index } ?? false }?.id }
    guard let guest = id(c.from), let host = id(c.to), guest != host else { return nil }
    if c.half {
        // About half the desks taken: every other desk of each row.
        store.sessions = store.sessions.filter { s in s.id == guest || s.id == host || (view.plan.desks[s.id].map { $0.index % 2 == 0 } ?? false) }
        view.update(store)
    } else if !c.dense {
        store.sessions = store.sessions.filter { $0.id == guest || $0.id == host }
        view.update(store)
    }
    view.visit(guest, to: host, words: words, until: Date() + 60)
    view.update(store)
    let fit = ZoneFit(scene: scene.size, view: size)
    guard let vf = view.foot(of: guest), let hf = view.foot(of: host) else { return nil }
    var m = VisitMeasure()
    m.visitor = fit.back(vf)
    m.host = fit.back(hf)
    m.pixels = hypot(m.visitor.x - m.host.x, m.visitor.y - m.host.y)
    if let map = scene.walkMap {
        let a = map.world(m.visitor), b = map.world(m.host)
        m.metres = hypot(a.x - b.x, a.y - b.y)
    }
    m.onDesk = scene.desks.contains { $0.covers(m.visitor) } || scene.bossDesk?.covers(m.visitor) == true
    let tall = scene.petHeight
    for s in store.sessions where s.id != guest && s.id != host {
        guard let f = view.foot(of: s.id) else { continue }
        let p = fit.back(f)
        if abs(p.x - m.visitor.x) < tall * 0.55 && abs(p.y - m.visitor.y) < tall * 1.05 { m.overlapped += 1 }
    }
    if let b = view.bubbleFrame(of: guest) { m.bubbleOff = b.midX - hf.x }
    return (m, view, store, guest, host)
}

/// All cases for one art and one algorithm; `visitSpotLegacy` picked here.
@MainActor func visitMeasureAll(art: String?, legacy: Bool, size: CGSize) -> [String: VisitMeasure] {
    let keep = ZoneArt.folder
    if let art { ZoneArt.folder = art }
    UserDefaults.standard.set(legacy, forKey: "visitSpotLegacy")
    defer {
        ZoneArt.folder = keep
        UserDefaults.standard.removeObject(forKey: "visitSpotLegacy")
    }
    var out: [String: VisitMeasure] = [:]
    for c in visitCases() { if let r = visitRun(c, size: size) { out[c.id] = r.0 } }
    return out
}

@MainActor func visitSetup() -> () -> Void {
    let restore = seaSweepSetup(NSTemporaryDirectory() + "visit-\(getpid())")
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    return restore
}

/// `--visit-stills <dir> [--visit-before-art <folder>]`.
@MainActor func visitStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let restore = visitSetup()
    defer { restore() }
    let args = CommandLine.arguments
    let before = args.firstIndex(of: "--visit-before-art").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    let size = CGSize(width: 1500, height: 1000)
    let now = ZoneArt.folder
    let variants: [(String, String?, Bool)] = [("before", before, true), ("now", now, true), ("fixed", now, false)]
    let stillIDs = Set(["dense-Web12-to-Web1", "dense-Web12-to-Web3", "dense-Web12-to-Web6", "dense-Web4-to-Web7", "dense-Web4-to-Web9", "dense-Web4-to-Web12",
                        "dense-Web5-to-Ops1", "dense-Web5-to-Ops3", "dense-Web5-to-AI2", "dense-Web5-to-AI5", "dense-Web5-to-Home1", "dense-Web5-to-Home4",
                        "dense-Web5-to-Ops9", "dense-Web5-to-Home10", "sparse-Web12-to-Web1", "sparse-Web12-to-Web4", "sparse-Web4-to-Web8", "sparse-Web5-to-Ops2",
                        "sparse-Web5-to-AI1", "sparse-Web5-to-Home3"])
    var lines = ["variant\tcase\tvisitor_x\tvisitor_y\thost_x\thost_y\tpx\tmetres\tonDesk\toverlap\tbubbleOff"]
    for (name, art, legacy) in variants {
        let keep = ZoneArt.folder
        if let art { ZoneArt.folder = art }
        UserDefaults.standard.set(legacy, forKey: "visitSpotLegacy")
        guard let scene = ZoneArt.scene else { continue }
        let fit = ZoneFit(scene: scene.size, view: size)
        try? FileManager.default.createDirectory(atPath: dir + "/" + name, withIntermediateDirectories: true)
        for c in visitCases() {
            guard let (m, view, _, guest, host) = visitRun(c, size: size) else { continue }
            lines.append(String(format: "%@\t%@\t%.1f\t%.1f\t%.1f\t%.1f\t%.1f\t%.3f\t%d\t%d\t%@", name, c.id, m.visitor.x, m.visitor.y, m.host.x, m.host.y, m.pixels, m.metres,
                                m.onDesk ? 1 : 0, m.overlapped, m.bubbleOff.map { String(format: "%.1f", $0) } ?? "-"))
            guard stillIDs.contains(c.id), let image = view.image(), let hf = view.foot(of: host), let vf = view.foot(of: guest) else { continue }
            _ = fit
            let k = CGFloat(image.width) / size.width
            let mid = CGPoint(x: (hf.x + vf.x) / 2, y: (hf.y + vf.y) / 2)
            let w: CGFloat = 330, h: CGFloat = 280
            let r = CGRect(x: (mid.x - w / 2) * k, y: (mid.y - h * 0.62) * k, width: w * k, height: h * k).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let crop = image.cropping(to: r), let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name)/\(c.id).png"))
                // Where the host and the visitor stand in the crop (pixels), for the sheet's marks.
                let meta = String(format: "{\"host\": [%.1f, %.1f], \"visitor\": [%.1f, %.1f], \"px\": %.1f, \"m\": %.3f}", hf.x * k - r.minX, (image.height > 0 ? hf.y * k : 0) - r.minY, vf.x * k - r.minX, vf.y * k - r.minY, m.pixels, m.metres)
                try? meta.write(toFile: "\(dir)/\(name)/\(c.id).json", atomically: true, encoding: .utf8)
            }
        }
        ZoneArt.folder = keep
        UserDefaults.standard.removeObject(forKey: "visitSpotLegacy")
    }
    try? lines.joined(separator: "\n").write(toFile: dir + "/visit-metrics.tsv", atomically: true, encoding: .utf8)
    print("visit stills: wrote \(dir) (\(lines.count - 1) rows)")
}

@MainActor func visitTests() {
    let restore = visitSetup()
    defer {
        UserDefaults.standard.removeObject(forKey: "visitSpotLegacy")
        restore()
    }
    guard let scene = ZoneArt.scene else { return skipped("no seaview art", "visit: stand beside the host") }
    let size = CGSize(width: 1500, height: 1000)
    let pet = scene.petHeight
    let all = visitCases()
    func run(_ id: String) -> VisitMeasure? { all.first { $0.id == id }.flatMap { visitRun($0, size: size)?.0 } }

    // The room with only the two of them: the left row, the right row, the lead's desk and other islands alike, a metre or so
    // from the host, on the floor, not on anyone.
    UserDefaults.standard.set(false, forKey: "visitSpotLegacy")
    let sparse = all.filter { !$0.dense }.compactMap { c in visitRun(c, size: size).map { (c, $0.0) } }
    check("visit: every desk of the four islands has a visit measured (\(sparse.count) of 48)", sparse.count == 48)
    let near = sparse.allSatisfy { $0.1.pixels > pet * 0.5 && $0.1.pixels <= pet * 0.8 && $0.1.metres > 0.7 && $0.1.metres < 1.4 }
    check("visit: alone with its host, a visitor stands 0.7–1.4 m (a half to four fifths of a pet) from it at every desk, left row, right row and cross-island", near)
    let left = sparse.filter { $0.0.to.index <= 6 }.map(\.1.pixels), right = sparse.filter { $0.0.to.index > 6 }.map(\.1.pixels)
    check("visit: left-row and right-row hosts get the same distance, to within 12 px (the left row's 0.22 m move does not show)",
        abs((left.max() ?? 0) - (right.max() ?? 0)) <= 12 && abs((left.min() ?? 0) - (right.min() ?? 0)) <= 12)
    check("visit: none of them stands on a desk or on another figure", sparse.allSatisfy { !$0.1.onDesk && $0.1.overlapped == 0 })
    check("visit: the bubble's middle is within two pets of the host at every desk", sparse.allSatisfy { ($0.1.bubbleOff.map { abs($0) } ?? 0) < pet * 2 * 0.625 })

    // The room full: the visitor is on the aisle beside its host's row (the stand spot, or a body's width along it), within 1.5 m
    // of the host, and not on a desk.
    let picks = ["dense-Web12-to-Web1", "dense-Web12-to-Web2", "dense-Web12-to-Web6", "dense-Web4-to-Web7", "dense-Web4-to-Web8", "dense-Web4-to-Web12",
                 "dense-Web5-to-Ops1", "dense-Web5-to-Ops2", "dense-Web5-to-Ops3", "dense-Web5-to-AI9", "dense-Web5-to-AI2", "dense-Web5-to-Home4"]
    let dense = picks.compactMap { id in run(id).map { (id, $0) } }
    check("visit: with the room full, \(dense.count) of 12 sampled visits found a spot", dense.count == picks.count)
    func onAisle(_ p: CGPoint, _ d: ZoneScene.Desk) -> Bool {
        guard let stand = d.stand, let aisle = d.aisle else { return false }
        let len = max(0.001, hypot(aisle.dx, aisle.dy))
        let ux = aisle.dx / len, uy = aisle.dy / len
        let along = (p.x - stand.x) * ux + (p.y - stand.y) * uy, across = (p.x - stand.x) * uy - (p.y - stand.y) * ux
        return abs(across) < 2 && abs(along) < pet * ZoneScene.visitBody + 2
    }
    var aisleOK = true, metresOK = true
    for (id, m) in dense {
        guard let c = all.first(where: { $0.id == id }), let d = scene.desks.first(where: { $0.zone == c.to.zone && $0.index == c.to.index }) else { aisleOK = false; continue }
        if !onAisle(m.visitor, d) || m.onDesk { aisleOK = false }
        if m.metres > 1.5 { metresOK = false; print("      visit: \(id) \(m.metres) m") }
    }
    check("visit: with the room full, every sampled visitor is on its host's aisle (the stand spot or a body's width along it) and not on a desk", aisleOK)
    check("visit: with the room full, every sampled visitor is within 1.5 m of its host (the legacy search left some up to 4.2 m away)", metresOK)
    check("visit: the same for the sparse room: on the aisle, within 1.5 m, left row, right row, cross-island alike",
        sparse.allSatisfy { r in scene.desks.first { $0.zone == r.0.to.zone && $0.index == r.0.to.index }.map { onAisle(r.1.visitor, $0) } == true && r.1.metres <= 1.5 })

    // The rule itself: crowd the stand spot, and the spot a body's width along the aisle is taken if clear; never across the aisle.
    if let d = scene.desks.first(where: { $0.zone == scene.desks[0].zone && $0.index == 2 }), let stand = d.stand {
        let free = scene.visitSpot(d.seat)
        check("visit: with no one round about the visitor stands on the desk's own stand spot", hypot(free.x - stand.x, free.y - stand.y) < 1)
        let crowd = [CGPoint(x: stand.x, y: stand.y + pet * 0.9)]
        let moved = scene.visitSpot(d.seat, others: crowd)
        let clear = crowd.allSatisfy { abs($0.x - moved.x) >= pet * 0.55 || abs($0.y - moved.y) >= pet * 1.05 }
        check("visit: with a figure on the stand spot the visitor steps along the aisle (not across it) to a clear spot, within 1.5 m of the host",
            hypot(moved.x - stand.x, moved.y - stand.y) > 20 && onAisle(moved, d) && clear && !scene.desks.contains { $0.covers(moved) })
        var ring: [CGPoint] = []
        for a in -3...3 {
            for b in -3...3 { ring.append(CGPoint(x: stand.x + CGFloat(a) * pet * 0.5, y: stand.y + CGFloat(b) * pet * 0.5)) }
        }
        let packed = scene.visitSpot(d.seat, others: ring)
        check("visit: with nowhere clear on the aisle it stays on the stand spot, the nearest, overlapping a little", hypot(packed.x - stand.x, packed.y - stand.y) < 1)
    } else { check("visit: a desk 2 with a stand spot is in the art", false) }
    UserDefaults.standard.set(true, forKey: "visitSpotLegacy")
    let legacyFar = run("dense-Web5-to-Ops2")
    UserDefaults.standard.set(false, forKey: "visitSpotLegacy")
    let fixedFar = run("dense-Web5-to-Ops2")
    check("visit: visitSpotLegacy = YES gives the legacy 3.65 m for a crowded host, the default within 1.5 m",
        (legacyFar?.metres ?? 0) > 3 && (fixedFar?.metres ?? 9) <= 1.5)
}

/// `--visit-probe <before-art>`: random occupancy, every host, the spot's distance by the reference art and the current art.
@MainActor func visitProbe(_ beforeArt: String) {
    let restore = visitSetup()
    defer { restore() }
    let keep = ZoneArt.folder
    guard let now = ZoneArt.scene else { return }
    ZoneArt.folder = beforeArt
    guard let old = ZoneArt.scene else { return }
    ZoneArt.folder = keep
    var rng = SystemRandomNumberGenerator()
    var worse = 0, total = 0, better = 0
    var byIdx: [String: (Int, Int)] = [:]
    var examples: [String] = []
    var rowStats: [String: (Double, Double, Int)] = [:]
    var far: [String: (Int, Int, Int)] = [:]
    for trial in 0..<400 {
        let p = [0.15, 0.3, 0.5, 0.8][trial % 4]
        var present = Set<String>()
        for d in now.desks where Double.random(in: 0..<1, using: &rng) < p { present.insert("\(d.zone)#\(d.index)") }
        for host in now.desks where present.contains("\(host.zone)#\(host.index)") {
            func spot(_ s: ZoneScene) -> (CGPoint, CGPoint) {
                let h = s.desks.first { $0.zone == host.zone && $0.index == host.index }!
                let others = s.desks.filter { present.contains("\($0.zone)#\($0.index)") && !($0.zone == host.zone && $0.index == host.index) }.map(\.seat)
                return (s.visitSpot(h.seat, taken: [], others: others), h.seat)
            }
            let (a, ha) = spot(old), (b, hb) = spot(now)
            let da = Double(hypot(a.x - ha.x, a.y - ha.y)), db = Double(hypot(b.x - hb.x, b.y - hb.y))
            total += 1
            let row = host.index <= 6 ? "left" : "right"
            let st = rowStats[row] ?? (0, 0, 0)
            rowStats[row] = (st.0 + da, st.1 + db, st.2 + 1)
            if db > 130, host.zone == "Web" { let k = "Web#\(host.index)"; let v = byIdx["far " + k] ?? (0, 0); byIdx["far " + k] = (v.0 + 1, Int(db)) }
            let fk = "\(host.zone)-\(row)"
            let f0 = far[fk] ?? (0, 0, 0)
            far[fk] = (f0.0 + (da > 130 ? 1 : 0), f0.1 + (db > 130 ? 1 : 0), f0.2 + 1)
            if da > db + 40 { better += 1 }
            if abs(da - db) > 40 { let k = "\(host.zone)#\(host.index)"; let v = byIdx[k] ?? (0, 0); byIdx[k] = (v.0 + (db > da ? 1 : 0), v.1 + (da > db ? 1 : 0)) }
            if db > da + 40 {
                worse += 1
                if examples.count < 8 { examples.append("\(host.zone)#\(host.index) p=\(p) old \(Int(da)) px now \(Int(db)) px") }
            }
        }
    }
    for (k, v) in far.sorted(by: { $0.key < $1.key }) { print(String(format: "probe: far(>130px) %@: old %.1f%% now %.1f%% of %d", k, 100 * Double(v.0) / Double(v.2), 100 * Double(v.1) / Double(v.2), v.2)) }
    print("probe: \(total) hosts, \(worse) farther by 40+ px now, \(better) nearer")
    for (k, v) in byIdx.sorted(by: { $0.key < $1.key }) { print("probe: changed \(k) farther \(v.0) nearer \(v.1)") }
    for (k, v) in rowStats { print(String(format: "probe: %@ row mean old %.0f px, now %.0f px (%d)", k, v.0 / Double(v.2), v.1 / Double(v.2), v.2)) }
    examples.forEach { print("probe: " + $0) }
}

/// `--visit-live <before-art>`: the live path (window, walks) for some visits, by both arts.
@MainActor func visitLive(_ beforeArt: String) {
    let restore = visitSetup()
    defer { restore() }
    let keep = ZoneArt.folder
    let size = CGSize(width: 1500, height: 1000)
    let cases: [(String, Int, String, Int)] = [("Web", 12, "Web", 1), ("Web", 5, "Ops", 1), ("Ops", 9, "Ops", 1), ("Ops", 9, "Ops", 3), ("Web", 9, "Web", 7), ("AI", 7, "Ops", 4), ("Home", 10, "AI", 2)]
    for (name, art) in [("before", beforeArt), ("now", keep ?? "")] {
        ZoneArt.folder = art
        guard let scene = ZoneArt.scene else { continue }
        let fit = ZoneFit(scene: scene.size, view: size)
        for c in cases {
            let store = visitRoom()
            let view = ZoneView(frame: CGRect(origin: .zero, size: size))
            view.onScreenOverride = true
            let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = view
            window.orderFrontRegardless()
            view.update(store)
            func id(_ z: String, _ i: Int) -> String? { store.sessions.first { view.plan.desks[$0.id].map { $0.zone == z && $0.index == i } ?? false }?.id }
            guard let g = id(c.0, c.1), let h = id(c.2, c.3) else { window.orderOut(nil); continue }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
            view.visit(g, to: h, words: visitWords, until: Date() + 60)
            view.update(store)
            let route = view.route(of: g)
            let crossed = seaSweepCrossings(route, scene, fit)
            let legs = route.count
            let t = view.walkEnds(of: g) - CACurrentMediaTime()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, t) + 0.4))
            let foot = view.foot(of: g), shown = view.shownFoot(of: g), hf = view.foot(of: h)
            let bf = view.bubbleFrame(of: g)
            func s(_ p: CGPoint?) -> String { p.map { let q = fit.back($0); return "(\(Int(q.x)),\(Int(q.y)))" } ?? "-" }
            let last = route.last.map { fit.back($0) }
            print("live \(name) \(c.0)\(c.1)->\(c.2)\(c.3): legs \(legs) walk \(String(format: "%.1f", t))s crossed \(crossed.count) last \(last.map { "(\(Int($0.x)),\(Int($0.y)))" } ?? "-") foot \(s(foot)) shown \(s(shown)) host \(s(hf)) bubbleMidX-host \(bf.map { Int($0.midX - (hf?.x ?? 0)) } ?? 0) says \(view.says(g))")
            window.orderOut(nil)
            window.contentView = nil
        }
    }
    ZoneArt.folder = keep
}

/// `--visit-user <dir> [--visit-before-art <folder>]`: four visits, with the legacy search and with the default, the others
/// faded; crops and `user.json` for the sheet.
@MainActor func visitUserStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let restore = visitSetup()
    defer { restore() }
    guard let scene = ZoneArt.scene else { return }
    let size = CGSize(width: 1500, height: 1000)
    // The worst of each kind with the legacy search, in a room with half the desks taken, and in the full room.
    var pool: [(String, VisitCase, CGFloat)] = []
    UserDefaults.standard.set(true, forKey: "visitSpotLegacy")
    var cases: [VisitCase] = []
    for zone in visitZones {
        for index in 1...12 {
            let from: (String, Int) = zone == "Web" ? ("Web", index <= 6 ? 12 : 4) : ("Web", 5)
            // Half the desks are the even ones: the host must be taken, so odd hosts are kept by the filter's guest/host rule.
            cases.append(VisitCase(id: "half-\(from.0)\(from.1)-to-\(zone)\(index)", from: from, to: (zone, index), dense: true, half: true))
        }
    }
    cases += visitCases().filter { $0.dense }
    for c in cases { if let r = visitRun(c, size: size) { pool.append((c.id, c, r.0.metres)) } }
    func worst(_ kind: String, _ ok: (VisitCase) -> Bool) -> VisitCase? { pool.filter { $0.0.hasPrefix(kind) && ok($0.1) }.max { $0.2 < $1.2 }?.1 }
    let picks: [(String, VisitCase?)] = [
        ("Same island, host in the left row", worst("half") { $0.from.zone == $0.to.zone && $0.to.index <= 6 }),
        ("Same island, host in the right row", worst("half") { $0.from.zone == $0.to.zone && $0.to.index > 6 }),
        ("Across islands", worst("half") { $0.from.zone != $0.to.zone }),
        ("Full room", worst("dense") { $0.to.zone == "Ops" })]
    var meta: [[String: Any]] = []
    for (title, c) in picks {
        guard let c else { continue }
        for (variant, legacy) in [("before", true), ("after", false)] {
            UserDefaults.standard.set(legacy, forKey: "visitSpotLegacy")
            guard let (m, view, _, guest, host) = visitRun(c, size: size, words: "来问一句"), let hf = view.foot(of: host), let vf = view.foot(of: guest),
                  let hb = view.drawnBox(of: host), let vb = view.drawnBox(of: guest) else { continue }
            view.fadeFigures(except: [guest, host], to: 0.35)
            guard let image = view.image() else { continue }
            let k = CGFloat(image.width) / size.width
            let mid = CGPoint(x: (hf.x + vf.x) / 2, y: (hf.y + vf.y) / 2 - 20)
            let w: CGFloat = 340, h: CGFloat = 270
            let r = CGRect(x: (mid.x - w / 2) * k, y: (mid.y - h / 2) * k, width: w * k, height: h * k).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            guard let crop = image.cropping(to: r), let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) else { continue }
            let name = "\(meta.count / 2)-\(variant)"
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            func p(_ q: CGPoint) -> [Double] { [Double(q.x * k - r.minX), Double(q.y * k - r.minY)] }
            meta.append(["title": title, "variant": variant, "file": name + ".png", "host_foot": p(hf), "visitor_foot": p(vf), "host_head": p(CGPoint(x: hb.midX, y: hb.minY)),
                         "visitor_head": p(CGPoint(x: vb.midX, y: vb.minY)), "metres": Double(m.metres), "case": c.id])
        }
    }
    UserDefaults.standard.removeObject(forKey: "visitSpotLegacy")
    if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) { try? data.write(to: URL(fileURLWithPath: dir + "/user.json")) }
    print("visit user stills: \(meta.count) in \(dir)")
}
