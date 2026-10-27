// The checks of `--demo-crowd` (`--demo-only`) and the README's pictures taken on it
// (`--demo-stills <dir> [--lang <code>] [--pets-dir <folder>] [--demo-extra N]`; tools: shots/readme-shots.sh).

import AppKit
import SwiftUI

/// Words nothing in the crowd may carry beyond the general checks (a home folder other than /Users/demo, a pet off the
/// list): one per line in the file `SOULGENT_LEAK_WORDS` names (lines starting with # left out), kept outside the
/// repository by whoever runs the checks. None set, none.
func demoLeakWords() -> [String] {
    guard let path = ProcessInfo.processInfo.environment["SOULGENT_LEAK_WORDS"], !path.isEmpty,
        let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

/// A home folder in the text that is not the made-up one.
func demoOtherHome(_ text: String) -> Bool {
    text.range(of: #"/Users/(?!demo(/|$))"#, options: .regularExpression) != nil
}

@MainActor func demoText(_ crowd: DemoCrowd) -> [String] {
    var all: [String] = []
    for s in crowd.sessions { all += [s.name, s.project, s.cwd, s.registryName, s.waitingFor, s.errorText ?? "", s.line.displayText] + s.bgList.map(\.desc) }
    for list in crowd.agents.values { all += list.map(\.description) }
    for list in crowd.peers.values { all += list.map(\.note) }
    all += crowd.activity.events.map(\.name)
    return all
}

func demoHasCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x2E80...0x9FFF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) || (0x3000...0x303F).contains($0.value) }
}

@MainActor func demoTests() {
    demoGifArgTests()
    let defaults = UserDefaults.standard
    let domain = ProcessInfo.processInfo.processName
    defaults.set("real", forKey: "demoProbe")
    let before = defaults.persistentDomain(forName: domain) ?? [:]
    let languagePinned = L10n.language
    defer {
        DemoMode.leave()
        defaults.removeObject(forKey: "demoProbe")
        L10n.pin(languagePinned == L10n.source ? L10n.source : languagePinned)
    }

    // ── the pet list ──
    let scratch = NSTemporaryDirectory() + "demo-pool-\(getpid())"
    try? FileManager.default.removeItem(atPath: scratch)
    for id in ["boxcat", "whaley", "evil-ip-pet", "soulflame-clone"] {
        try? FileManager.default.createDirectory(atPath: scratch + "/" + id, withIntermediateDirectories: true)
        try? "{\"id\": \"\(id)\", \"spritesheetPath\": \"spritesheet.webp\"}".write(toFile: scratch + "/" + id + "/pet.json", atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: scratch + "/" + id + "/spritesheet.webp", contents: Data([0]))
    }
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    check("demo: the list is the flame and nineteen from Petdex, no repeats", DemoMode.pets.count == 20 && Set(DemoMode.pets).count == 20 && DemoMode.pets[0] == "soulflame")
    check("demo: outside the crowd every pet is allowed; in it only the listed ones", DemoMode.allows("evil-ip-pet") && DemoMode.allows("nobody") && !DemoMode.active)

    // ── the settings (an own domain) and the files ──
    DemoMode.enter(arguments: ["--demo-crowd", "--pets-dir", scratch])
    check("demo: on after enter, the pet folder is the one given", DemoMode.active && DemoMode.petDirs == [scratch])
    check("demo: the real settings are not read (the probe set before is not seen)", UserDefaults.standard.object(forKey: "demoProbe") == nil)
    UserDefaults.standard.set("demo", forKey: "demoProbe")
    check("demo: and a setting written goes to the crowd's domain, not the real one",
        UserDefaults(suiteName: DemoMode.domain)?.string(forKey: "demoProbe") == "demo"
            && (UserDefaults.standard.persistentDomain(forName: domain) ?? [:])["demoProbe"] as? String != "demo")
    check("demo: the zones, the roster and the notice board are scratch files of the crowd's own",
        ZoneConfigFile.path.hasPrefix(DemoMode.scratch) && ZoneRosterFile.path.hasPrefix(DemoMode.scratch) && ZonePendingFile.path.hasPrefix(DemoMode.scratch)
            && OfficeActivity.file.hasPrefix(DemoMode.scratch) && !appSessionsLive)
    check("demo: the pet pools are the crowd's folder only (no petdex folder, no app/pets)",
        PetSources.outside == [scratch] && !PetSources.outside.contains { $0.contains(".petdex") })
    let pool = Pets(dirs: PetSources.outside, builtIn: [])
    pool.refresh(force: true)
    check("demo: a pet folder holding others than the list gives the listed ones only (\(pool.ids))", pool.ids == ["boxcat", "whaley"])
    DemoMode.petDirs = []
    check("demo: with no folder there is no pool at all (everyone is the flame), not the real one", PetSources.outside.isEmpty)
    DemoMode.petDirs = [scratch]

    // ── the crowd, in each language ──
    var names: [[String]] = []
    var problems: [String] = []
    let leakWords = demoLeakWords()
    check("demo: the general leak checks catch a real home folder and pass the made-up one",
        demoOtherHome("/Users/someone/x") && demoOtherHome("cd /Users/x") && !demoOtherHome("/Users/demo/web") && !demoOtherHome("/Users/demo"))
    if leakWords.isEmpty { skipped("no SOULGENT_LEAK_WORDS file", "demo: no listed word in the crowd") }
    for lang in DemoCrowd.languages {
        L10n.pin(lang)
        let crowd = DemoCrowd.make(lang: lang, installed: DemoMode.pets)
        names.append(crowd.sessions.map(\.name))
        let all = demoText(crowd)
        if !crowd.sessions.allSatisfy({ $0.cwd.hasPrefix("/Users/demo/") }) { problems.append("\(lang): a cwd outside /Users/demo") }
        if let hit = all.first(where: demoOtherHome) { problems.append("\(lang): a home folder not /Users/demo in \(hit)") }
        if let hit = all.first(where: { text in leakWords.contains { text.contains($0) } }) { problems.append("\(lang): a listed word in \(hit)") }
        if Set(crowd.sessions.map(\.name)).count != crowd.sessions.count { problems.append("\(lang): names repeat") }
        if lang == "en", let hit = all.first(where: demoHasCJK) { problems.append("en: Chinese in \(hit)") }
        if lang != "en", !crowd.sessions.contains(where: { demoHasCJK($0.name) }) { problems.append("\(lang): no Chinese name") }
        if !crowd.pets.values.allSatisfy(DemoMode.pets.contains) { problems.append("\(lang): a pet off the list") }
        if lang == "zh-Hant", crowd.sessions.contains(where: { $0.name.contains("设") || $0.name.contains("务") || $0.name.contains("线") }) { problems.append("zh-Hant: a simplified character in a name") }
    }
    check("demo: made-up names, folders under /Users/demo, no real word, English with no Chinese, pets on the list in all three languages (\(problems))", problems.isEmpty)
    check("demo: three languages, three sets of names over the same zones",
        Set(names.map { Set($0) }).count == 3 && names[0].count == names[1].count && names[1].count == names[2].count
            && zip(names[0], names[1]).allSatisfy { $0.prefix(while: { $0 != "-" }) == $1.prefix(while: { $0 != "-" }) })
    let none = DemoCrowd.make(lang: "en", installed: [])
    check("demo: pets not installed are the flame, never another", none.pets.values.allSatisfy { $0 == "soulflame" })
    let some = DemoCrowd.make(lang: "en", installed: ["boxcat", "soulflame"])
    check("demo: some installed: the listed ones that are, the flame for the rest", Set(some.pets.values).isSubset(of: ["boxcat", "soulflame"]) && some.pets.values.contains("boxcat"))
    check("demo: the same pet for the same row in every language", DemoCrowd.make(lang: "zh-Hans", installed: DemoMode.pets).pets == DemoCrowd.make(lang: "en", installed: DemoMode.pets).pets)

    // ── a store on it: nothing real, every state ──
    L10n.pin("en")
    try? DemoCrowd.zonesJSON(lang: "en").write(toFile: ZoneConfigFile.path, atomically: true, encoding: .utf8)
    let store = Store()
    store.readOnly = true
    store.loadOnce()
    store.scanLinksNow()
    let crowd = DemoCrowd.make(lang: "en", installed: Pets.shared.ids + ["soulflame"])
    check("demo: the store holds the crowd and nothing else", store.sessions.map(\.id) == crowd.sessions.map(\.id) && store.sessions.count == 30)
    check("demo: every session is Claude Code's, in a made-up folder", store.sessions.allSatisfy { $0.kind == "claude" && $0.cwd.hasPrefix("/Users/demo/") })
    let b = Buckets(store, now: Date())
    check("demo: every group of the board has someone (waiting \(b.waiting.count), news \(b.unread.count), working \(b.busy.count), seen \(b.seen.count), resting \(b.resting.count), failed \(b.failed.count), gone \(b.gone.count))",
        b.waiting.count >= 4 && b.unread.count >= 3 && b.busy.count >= 6 && b.seen.count >= 4 && b.resting.count >= 4 && b.failed.count == 2 && b.gone.count == 1)
    check("demo: the waiting ones ask all three things: a command, a file, a question",
        b.waiting.contains { if case .approveRun = $0.line { return true } else { return false } }
            && b.waiting.contains { if case .approveEdit = $0.line { return true } else { return false } }
            && b.waiting.contains { if case .answer = $0.line { return true } else { return false } })
    check("demo: one on Fable at work, one on Fable idle, one on Opus lit in Orca",
        store.sessions.first { $0.id == crowd.fable }.map { $0.isFable && $0.isWorking } == true && store.sessions.contains { $0.isFable && !$0.isWorking }
            && store.focused == crowd.lit && store.sessions.first { $0.id == crowd.lit }?.model.contains("opus") == true)
    check("demo: background work (one counted at work), a red error, an amber one, an unexpected exit, retry not needed",
        store.sessions.contains { $0.isBackgroundWorking } && store.sessions.contains { $0.isRed } && store.sessions.contains { $0.isAmber } && store.sessions.contains { $0.isGone })
    check("demo: subagent figures at several desks", store.agentCounts.count >= 4 && store.agentCounts.values.max() ?? 0 >= 3)
    check("demo: two sessions that talk, and the notice board has lines",
        store.peers[crowd.talker]?.first?.id == crowd.listener && store.activity.events.count >= 10)
    check("demo: the helpers' figures are on the list too", DemoMode.pets.contains(ZoneSubagentFigures.claudePet) && DemoMode.pets.contains(ZoneSubagentFigures.codexPet))
    check("demo: the pets are the listed ones, set by hand", store.displayPets.values.allSatisfy(DemoMode.pets.contains) && store.displayPets.count == 30)
    check("demo: the zones file is the crowd's: four zones, each lead its first session",
        ZoneConfigFile.current().zones.map(\.code) == ["Web", "Ops", "AI", "Home"] && ZoneConfigFile.current().zones.allSatisfy { z in store.sessions.contains { $0.name == z.lead } })
    check("demo: the real settings domain is as it was before (only the probe, set by this check)",
        (defaults.persistentDomain(forName: domain) ?? [:]).filter { $0.key != "demoProbe" }.keys.sorted() == before.filter { $0.key != "demoProbe" }.keys.sorted())

    // ── --demo-extra: more on the Web island ──
    DemoMode.extra = 8
    check("demo: --demo-extra 8 puts eight more on the Web island", DemoCrowd.rows(lang: 0).filter { $0.zone == "Web" }.count == 15 && DemoCrowd.make(lang: "en", installed: DemoMode.pets).sessions.count == 38)
    DemoMode.extra = 0

    DemoMode.leave()
    check("demo: off again, the real settings are read again and the probe is as it was", !DemoMode.active && UserDefaults.standard.string(forKey: "demoProbe") == "real")
    check("demo: and the crowd's domain is gone", (UserDefaults.standard.persistentDomain(forName: DemoMode.domain) ?? [:]).isEmpty)
}

// ───────── The README's pictures, on the crowd ─────────

@MainActor func demoWrite(_ image: CGImage?, _ path: String) {
    guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("demo stills: \(path) NOT written") }
    try? png.write(to: URL(fileURLWithPath: path))
    print("demo stills: \((path as NSString).lastPathComponent) written (\(image.width) x \(image.height))")
}

@MainActor func demoStore() -> Store {
    let store = Store()
    store.readOnly = true
    store.loadOnce()
    return store
}

/// The panel as the app makes it (the title bar with the counts, the search and the switch), offscreen, the room settled.
@MainActor func demoPanel(_ store: Store, _ size: CGSize) -> ZoneOffscreenPanel {
    let panel = ZoneOffscreenPanel(contentRect: CGRect(x: -8000, y: -8000, width: size.width, height: size.height),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
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
    for _ in 0..<60 {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for host in hosts { host.setFrameSize(host.fittingSize) }
    }
    if let view = panel.contentView.flatMap(zonePanelFitFind) { view.still = true; view.update(store) }
    for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return panel
}

/// The window's own layers (title bar, buttons), then the room over them as the window composites it, at 2x.
@MainActor func demoGrab(_ panel: NSPanel) -> CGImage? {
    guard let frame = panel.contentView?.superview, let top = frame.layer, let room = zonePanelFitFind(frame) else { return nil }
    let size = top.bounds.size, k: CGFloat = 2
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * k), pixelsHigh: Int(size.height * k), bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
    ctx.scaleBy(x: k, y: k)
    ctx.setFillColor(OfficeCanvas.rgb(0x1B1830))
    ctx.fill(CGRect(origin: .zero, size: size))
    top.render(in: ctx)
    if let picture = room.image(pixelScale: k) { ctx.draw(picture, in: room.convert(room.bounds, to: nil)) }
    return rep.cgImage
}

/// A crop of a picture drawn at `k` pixels a point, `rect` in points from the top left.
func demoCrop(_ image: CGImage?, _ rect: CGRect, k: CGFloat) -> CGImage? {
    guard let image else { return nil }
    let r = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return image.cropping(to: r)
}

/// A crop of a picture drawn at `k` pixels a point of exactly `w` x `h` pixels: `rect`'s top left rounded to a pixel and
/// moved back inside the picture when the rounding takes it over an edge.
func demoCrop(_ image: CGImage?, _ rect: CGRect, k: CGFloat, w: Int, h: Int) -> CGImage? {
    guard let image, image.width >= w, image.height >= h else { return nil }
    let x = min(max(0, Int((rect.minX * k).rounded())), image.width - w), y = min(max(0, Int((rect.minY * k).rounded())), image.height - h)
    return image.cropping(to: CGRect(x: x, y: y, width: w, height: h))
}

/// `box` grown about its centre to 16:9 (the shorter side lengthened), shrunk about its centre when larger than `bounds`,
/// and moved back inside them.
func demoWide(_ box: CGRect, in bounds: CGRect) -> CGRect {
    var w = box.width, h = box.height
    if w * 9 < h * 16 { w = h * 16 / 9 } else { h = w * 9 / 16 }
    if w > bounds.width { w = bounds.width; h = w * 9 / 16 }
    if h > bounds.height { h = bounds.height; w = h * 16 / 9 }
    let x = min(max(box.midX - w / 2, bounds.minX), bounds.maxX - w), y = min(max(box.midY - h / 2, bounds.minY), bounds.maxY - h)
    return CGRect(x: x, y: y, width: w, height: h)
}

/// The smallest 16:9 box inside `bounds`, at least `minWidth` wide, that holds `need` (cut to `bounds`) and leaves each of
/// `keep` (plates, labels) wholly in or wholly out, never cut by an edge; of those of one width the one centred nearest on
/// `need`. Searched on a 2-point grid, widths 4 points apart; `demoWide(need)` when none is clear.
func demoClear(_ need: CGRect, keep: [CGRect], in bounds: CGRect, minWidth: CGFloat = 0) -> CGRect {
    let n = need.intersection(bounds)
    guard !n.isNull else { return demoWide(need, in: bounds) }
    var w = max(minWidth, n.width, n.height * 16 / 9).rounded(.up)
    while w <= bounds.width {
        let h = w * 9 / 16
        let x0 = max(bounds.minX, n.maxX - w), x1 = min(n.minX, bounds.maxX - w)
        let y0 = max(bounds.minY, n.maxY - h), y1 = min(n.minY, bounds.maxY - h)
        if h <= bounds.height, x0 <= x1, y0 <= y1 {
            var best: CGRect?, near = CGFloat.infinity
            var x = x0
            while x <= x1 {
                var y = y0
                while y <= y1 {
                    let b = CGRect(x: x, y: y, width: w, height: h)
                    let d = abs(b.midX - n.midX) + abs(b.midY - n.midY)
                    if d < near, keep.allSatisfy({ !$0.intersects(b) || b.contains($0) }) { best = b; near = d }
                    y += 2
                }
                x += 2
            }
            if let best { return best }
        }
        w += 4
    }
    return demoWide(need, in: bounds)
}

/// Every plate and label the room shows (the zones', check-in's and their off-duty badges), for `demoClear`.
@MainActor func demoKeep(_ view: ZoneView, _ store: Store) -> [CGRect] {
    let signs = Array(DemoCrowd.zoneColours.keys) + [ZonePlan.visitorKey]
    return store.sessions.compactMap { view.plateFrame(of: $0.id) } + signs.compactMap { view.signPill($0) } + signs.compactMap { view.offBadge($0)?.frame }
}

/// The box round some of the room's people (their feet, view points), widened by margins (left, up, right, down).
@MainActor func demoBox(_ view: ZoneView, _ ids: [String], left: CGFloat, up: CGFloat, right: CGFloat, down: CGFloat) -> CGRect? {
    let feet = ids.compactMap { view.foot(of: $0) }
    guard let first = feet.first else { return nil }
    var box = CGRect(origin: first, size: .zero)
    for p in feet { box = box.union(CGRect(origin: p, size: .zero)) }
    return CGRect(x: box.minX - left, y: box.minY - up, width: box.width + left + right, height: box.height + up + down)
}

@MainActor func demoStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let args = CommandLine.arguments
    let only = DemoMode.value("--only", in: args).map { Set($0.split(separator: ",").map(String.init)) }
    func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }
    DemoMode.enter(arguments: args)
    let defaults = UserDefaults.standard
    let registered = Extensions.registered
    Extensions.registered = nil
    defaults.set(true, forKey: "office")
    defaults.set(OfficeTheme.zone.name, forKey: "officeTheme")
    defaults.set(true, forKey: "officeSpotlight")
    defer {
        DemoMode.leave()
        Extensions.registered = registered
        OfficeTheme.shown = nil
    }
    L10n.reset()
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    guard ZoneArt.scene != nil else { return print("demo stills: no seaview art") }
    OfficeTheme.shown = OfficeTheme.zone
    print("demo stills: language \(L10n.language), pets \(Pets.shared.ids)")

    let store = demoStore()
    let sessionID: (String) -> String = { key in store.sessions.first { $0.id.hasSuffix("-" + key) }?.id ?? "" }
    let crowdSize = CGSize(width: 1180, height: 790)

    // hero-seaview: the whole room with the title bar.
    if wanted("hero-seaview") {
        let p = demoPanel(store, CGSize(width: 1400, height: 900))
        demoWrite(demoGrab(p), dir + "/hero-seaview.png")
        p.orderOut(nil)
        p.contentView = nil
    }
    // spotlight: the Opus session in Orca's front tab, lit.
    if wanted("spotlight") {
        let p = demoPanel(store, CGSize(width: 1400, height: 936))
        demoWrite(demoGrab(p), dir + "/spotlight.png")
        p.orderOut(nil)
        p.contentView = nil
    }

    // The room alone, held still, for the crops.
    func room(_ store: Store) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: crowdSize))
        view.still = true
        view.update(store)
        return view
    }
    let k: CGFloat = 3
    let view = room(store)
    let whole = view.image(pixelScale: k)
    // seaview-seats: the Web and Ops islands, each lead at desk 1 with its ★ plate, the Web island full (12 desks) so its
    // label counts the rest (+N) who sit in the lounge; 1600 x 900, 16:9 round the desks, the lounge and both labels.
    if wanted("seaview-seats") {
        DemoMode.extra = 7
        let big = demoStore()
        DemoMode.extra = 0
        big.focused = nil
        let v = room(big)
        let team = big.sessions.filter { $0.name.hasPrefix("Web-") || $0.name.hasPrefix("Ops-") }
        // At its desk: a desk of its own and standing above its island's label (one in the line or on a sofa keeps its desk).
        func onIsland(_ s: Session) -> Bool {
            guard v.demoDeskID(s.id) != nil, let foot = v.foot(of: s.id), let pill = v.signPill(s.name.hasPrefix("Web-") ? "Web" : "Ops") else { return false }
            return foot.y < pill.maxY
        }
        let seated = team.filter(onIsland).map(\.id)
        // In the lounge: no desk, and up in the top-left corner (above the Web label; the sofas of those with news are below it).
        let lounge = team.filter { s in
            s.name.hasPrefix("Web-") && v.demoDeskID(s.id) == nil && (v.foot(of: s.id).map { $0.y < (v.signPill("Web")?.minY ?? 0) } ?? false)
        }.map(\.id)
        print("demo stills: seats \(seated.count) at desks, lounge \(lounge.map { "\($0) \(v.foot(of: $0).map { "\($0)" } ?? "-")" })")
        let tall = (ZoneArt.scene.map { $0.petHeight * ZoneFit(scene: $0.size, view: crowdSize).scale } ?? 70)
        if var box = demoBox(v, seated + lounge, left: 45, up: tall + 8, right: 45, down: 30) {
            for code in ["Web", "Ops"] { if let pill = v.signPill(code) { box = box.union(pill.insetBy(dx: -12, dy: -8)) } }
            // 16:9 round them, no plate or label cut at the edges.
            let wide = demoClear(box, keep: demoKeep(v, big), in: CGRect(origin: .zero, size: crowdSize)), s = 1600 / wide.width
            print("demo stills: seats box \(wide), scale \(s), Web label \(v.signPill("Web").map { "\($0)" } ?? "-")")
            demoWrite(demoCrop(v.image(pixelScale: s), wide, k: s, w: 1600, h: 900), dir + "/seaview-seats.png")
        }
    }
    // seaview-queue: the ones that need the user, in the line at their desk.
    if wanted("seaview-queue") {
        let ids = store.sessions.filter { $0.status == "waiting" }.map(\.id)
        if let box = demoBox(view, ids, left: 200, up: 260, right: 200, down: 110) { demoWrite(demoCrop(whole, box, k: k), dir + "/seaview-queue.png") }
    }
    // seaview-desk: a busy desk with its screen, its lamp, its badge and its subagent figures.
    if wanted("seaview-desk") {
        if let box = demoBox(view, [sessionID("web-storefront")], left: 190, up: 230, right: 230, down: 90) { demoWrite(demoCrop(whole, box, k: k), dir + "/seaview-desk.png") }
    }
    // seaview-blaze: the Fable session at work, and the one on Fable resting beside the sofas.
    if wanted("seaview-blaze") {
        if let box = demoBox(view, [sessionID("ai-rag")], left: 190, up: 230, right: 190, down: 90) { demoWrite(demoCrop(whole, box, k: k), dir + "/seaview-blaze.png") }
    }
    // seaview-visit: one of the two that talk, at the other's desk, the first line of its message over its head.
    let calm = demoStore()
    calm.focused = nil  // no light over anybody in the pictures that are not about the light
    if wanted("seaview-visit") {
        let v = room(calm)
        let visitor = sessionID("web-checkout"), host = sessionID("web-storefront")
        v.visit(visitor, to: host, words: DemoCrowd.visitWords(DemoCrowd.index(L10n.language)), until: Date() + 60)
        v.update(calm)
        for _ in 0..<40 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let box = demoBox(v, [visitor, host], left: 220, up: 250, right: 220, down: 90) { demoWrite(demoCrop(v.image(pixelScale: k), box, k: k), dir + "/seaview-visit.png") }
    }
    // The sea and the beach, with the panel as the app has it (the loop plays in a layer of its own).
    if wanted("seaview-orca") || wanted("seaview-beach"), let spec = ZoneOutdoorArt.spec, let orca = ZoneOutdoorArt.orca,
       let (panel, ov, top) = zoneOrcaPanel(crowdSize, calm) {
        ov.still = true
        ov.update(calm)
        let fit = ZoneFit(scene: spec.picture, view: ov.bounds.size)
        let inWindow = ov.convert(ov.bounds, to: nil)
        let titleTop = top.bounds.height - inWindow.maxY
        func sea() -> CGRect {
            let r = fit.rect(spec.loopBox).offsetBy(dx: inWindow.minX, dy: titleTop).intersection(CGRect(origin: .zero, size: top.bounds.size))
            return CGRect(x: r.minX + r.width * 0.36, y: r.minY + 34, width: r.width * 0.64, height: r.height * 0.52)  // the beach, below the title bar
        }
        func shoot(_ name: String) {
            guard let rep = zonePanelFitRender(top), let image = rep.cgImage else { return }
            let sx = CGFloat(image.width) / top.bounds.width
            demoWrite(demoCrop(image, sea(), k: sx), dir + "/" + name + ".png")
        }
        if wanted("seaview-beach") {
            ov.outdoor.pose(at: 4.5)
            shoot("seaview-beach")
        }
        if wanted("seaview-orca"), let clip = orca.clip("C") {
            ov.outdoor.pose(at: 3.3)
            ov.outdoor.poseOrcaForCheck("C", frame: 80)
            if let strike = clip.strike { ov.outdoor.poseStrikeForCheck(strike, burst: nil) }
            shoot("seaview-orca")
        }
        ov.stopListening()
        panel.orderOut(nil)
    }
    // office: the second scene, the same people at desks, on the sofa and in the line.
    if wanted("office") {
        OfficeTheme.shown = OfficeTheme.studio
        let size = CGSize(width: 1194, height: 764)
        let o = calm
        if let composed = officeStill(o, size: size) { demoWrite(composed, dir + "/office.png") }
        OfficeTheme.shown = OfficeTheme.zone
    }
    // duty-room: the board, one card to a session.
    if wanted("duty-room") {
        let path = dir + "/duty-room.png"
        snapshot(to: path, width: 980)
        print("demo stills: duty-room.png written")
    }
    if wanted("jump") { demoJump(dir + "/jump.png", store: store) }
    if wanted("seaview-desk-menu") { demoDeskMenu(dir + "/seaview-desk-menu.png", size: crowdSize) }
}

/// jump: a window of Orca (tabs of the crowd's sessions, a dark pane and a light one) with the name stamped across the pane it
/// jumped to, as the overlay draws it (`JumpMark`).
@MainActor func demoJump(_ path: String, store: Store) {
    let l = DemoCrowd.index(L10n.language)
    let size = CGSize(width: 1600, height: 900)
    guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSColor(white: 0.16, alpha: 1).setFill()
    CGRect(origin: .zero, size: size).fill()
    NSColor(white: 0.22, alpha: 1).setFill()
    CGRect(x: 0, y: size.height - 44, width: size.width, height: 44).fill()
    let tabFont = NSFont.systemFont(ofSize: 13)
    let tabs = ["AI-rag", "AI-eval", "Web-storefront", "Ops-k8s"].compactMap { key in store.sessions.first { $0.id.hasSuffix(key.lowercased().replacingOccurrences(of: "-", with: "-")) || $0.id.hasPrefix("demo-" + key.lowercased()) } }
    for (i, t) in tabs.enumerated() {
        (t.name as NSString).draw(at: CGPoint(x: CGFloat(90 + i * 190), y: size.height - 30), withAttributes: [.font: tabFont, .foregroundColor: NSColor(white: i == 0 ? 1 : 0.7, alpha: 1)])
    }
    let left = CGRect(x: 8, y: 8, width: size.width / 2 - 12, height: size.height - 60)
    let right = CGRect(x: size.width / 2 + 4, y: 8, width: size.width / 2 - 12, height: size.height - 60)
    NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
    left.fill()
    NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
    right.fill()
    let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let lines = [["$ claude --resume", "* Reading README.md ...", "  Re-indexing docs/ (12,000 files)", "> batch 41 of 120 done", "  ok    chunker: 2,048 tokens", "  ok    embeddings: cached", "* Next: write index-report.md", "$ npm test | tail -1", "all passed"],
                 ["$ claude --resume", "* 读取 README.md ……", "  正在重建 docs/ 的索引（1.2 万个文件）", "> 第 41 批，共 120 批", "  ok    分块：2048 个 token", "  ok    向量：命中缓存", "* 下一步：写 index-report.md", "$ npm test | tail -1", "all passed"],
                 ["$ claude --resume", "* 讀取 README.md ……", "  正在重建 docs/ 的索引（1.2 萬個檔案）", "> 第 41 批，共 120 批", "  ok    分塊：2048 個 token", "  ok    向量：命中快取", "* 下一步：寫 index-report.md", "$ npm test | tail -1", "all passed"]][l]
    for (pane, colour) in [(left, NSColor(red: 0.75, green: 0.85, blue: 0.75, alpha: 1)), (right, NSColor(white: 0.18, alpha: 1))] {
        for n in 0..<38 { (lines[n % lines.count] as NSString).draw(at: CGPoint(x: pane.minX + 14, y: pane.maxY - 26 - CGFloat(n) * 21), withAttributes: [.font: mono, .foregroundColor: colour]) }
    }
    NSGraphicsContext.restoreGraphicsState()
    if let s = store.sessions.first(where: { $0.id.hasSuffix("ai-rag") }) {
        let name = JumpMark.label(name: s.name, cwd: s.cwd)
        let points = JumpMark.fontSize(name, paneWidth: left.width)
        if let mark = JumpMark.image(name, fontSize: points, scale: 1, zoneColor: JumpMark.zoneColor(of: name)) { ctx.draw(mark.image, in: JumpMark.centred(mark.size, on: left)) }
    }
    demoWrite(ctx.makeImage(), path)
}

/// seaview-desk-menu: the right-click menu over a figure at its desk near the check-in spot (one session of no zone
/// standing there, under the check-in label), and the zone label nearest that spot with its off-duty badge (three of that
/// zone on the roster);
/// 1600 x 900, the crop grown to 16:9 round all three. The newcomer and the roster are this picture's own: a copy of the
/// crowd with one more session, and a roster written to the crowd's scratch roster file. A menu is the system's and cannot
/// be drawn offscreen, so its lines (`sessionMenu`, the real ones, in this language) are laid over the crop in the
/// system's dark look, Change Character highlighted as under the pointer.
@MainActor func demoDeskMenu(_ path: String, size: CGSize) {
    guard let scene = ZoneArt.scene else { return }
    let l = DemoCrowd.index(L10n.language)
    var crowd = DemoCrowd.make(lang: L10n.language)
    guard let template = crowd.sessions.first(where: { $0.name.hasPrefix("Ops-") }) else { return }
    let newcomer = "demo-sandbox"
    crowd.sessions.append(Session(id: newcomer, pid: template.pid + 900, project: template.project, name: ["sandbox", "沙盒试验", "沙盒試驗"][l],
                                  status: "idle", since: Date().addingTimeInterval(-120), summary: "", registryName: "", cwd: "", kind: "claude",
                                  tool: "", origin: "user", model: template.model))
    crowd.seen[newcomer] = Date().timeIntervalSince1970 + 5
    let used = Dictionary(crowd.pets.values.map { ($0, 1) }, uniquingKeysWith: +)
    let helpers: Set<String> = [ZoneSubagentFigures.claudePet, ZoneSubagentFigures.codexPet]
    crowd.pets[newcomer] = DemoMode.pets.filter { !helpers.contains($0) }.min { used[$0, default: 0] < used[$1, default: 0] } ?? DemoMode.pets[0]
    let store = demoStore()
    store.takeDemo(crowd)
    store.focused = nil
    func room() -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        return view
    }
    // Where the check-in spot is, and the zone label nearest it: that zone gets the off-duty roster.
    let first = room()
    guard let spot = first.foot(of: newcomer) else { return print("demo stills: nobody at check-in") }
    func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - spot.x, r.midY - spot.y) }
    guard let zone = scene.signs.map(\.zone).filter({ first.signPill($0) != nil }).min(by: { distance(first.signPill($0)!) < distance(first.signPill($1)!) }) else { return }
    let now = Date().timeIntervalSince1970
    let roster = ["legacy-cron", "log-rotate", "cert-renew"].enumerated().map { i, n in
        "\"\(zone)-\(n)\": {\"zone\": \"\(zone)\", \"cwd\": \"\", \"lastActive\": \(Int(now) - 7200 * (i + 1)), \"offAt\": \(Int(now) - 3600 * (i + 1))}"
    }
    try? ("{" + roster.joined(separator: ", ") + "}").write(toFile: ZoneRosterFile.path, atomically: true, encoding: .utf8)
    ZoneRosterFile.reset()
    defer {
        try? "{}".write(toFile: ZoneRosterFile.path, atomically: true, encoding: .utf8)
        ZoneRosterFile.reset()
    }
    let view = room()
    guard let spotFoot = view.foot(of: newcomer), let label = view.signPill(zone), let badge = view.offBadge(zone),
          let checkIn = view.signPill(ZonePlan.visitorKey)
    else { return print("demo stills: desk menu: the newcomer, a label, the badge or the check-in label is missing") }
    let tall = scene.petHeight * ZoneFit(scene: scene.size, view: size).scale
    let newcomerBox = CGRect(x: spotFoot.x - 45, y: spotFoot.y - tall - 10, width: 90, height: tall + 30)
    func menuView(_ s: Session) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(sessionMenu(store, s).enumerated()), id: \.offset) { _, line in
                if case .separator = line.action { Divider().padding(.vertical, 4).padding(.horizontal, 8) } else {
                    let hot = line.action == .changePet
                    Text(line.title).font(.system(size: 13)).foregroundColor(line.enabled || hot ? .white : Color(white: 1, opacity: 0.35))
                        .padding(.vertical, 3).padding(.horizontal, 9).frame(width: 240, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(hot ? Color(red: 0.04, green: 0.42, blue: 0.95) : .clear))
                        .padding(.horizontal, 5)
                }
            }
        }
        .padding(.vertical, 6).frame(width: 250, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.17, opacity: 0.96)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 1, opacity: 0.18), lineWidth: 0.5))
    }
    func menuSize(_ s: Session) -> CGSize {
        let measure = ImageRenderer(content: menuView(s))
        measure.scale = 1
        return measure.cgImage.map { CGSize(width: $0.width, height: $0.height) } ?? CGSize(width: 250, height: 260)
    }
    // The menu opens at the pointer on a figure's body, its top left corner there, moved up from the room's bottom edge as a
    // menu is from the screen's. The figure: one at its desk (above its island's label) nearest the check-in spot whose
    // menu fits in the room and leaves the labels, the badge and the newcomer clear.
    func menuAt(_ s: Session) -> CGRect? {
        guard let foot = view.foot(of: s.id) else { return nil }
        let size0 = menuSize(s)
        var r = CGRect(origin: CGPoint(x: foot.x + tall * 0.1, y: foot.y - tall * 0.55), size: size0)
        if r.maxY > size.height - 8 { r.origin.y = size.height - 8 - size0.height }
        return r.maxX <= size.width - 4 ? r : nil
    }
    let clear = [label, badge.frame, checkIn, newcomerBox].map { $0.insetBy(dx: -6, dy: -6) }
    let candidates = store.sessions.filter { s in
        guard s.id != newcomer, view.demoDeskID(s.id) != nil, let foot = view.foot(of: s.id), let code = s.name.split(separator: "-").first,
              let pill = view.signPill(String(code)) else { return false }
        return foot.y < pill.maxY
    }.sorted { a, b in
        let p = view.foot(of: a.id) ?? .zero, q = view.foot(of: b.id) ?? .zero
        return hypot(p.x - spotFoot.x, p.y - spotFoot.y) < hypot(q.x - spotFoot.x, q.y - spotFoot.y)
    }
    guard let s = candidates.first(where: { c in menuAt(c).map { m in !clear.contains { $0.intersects(m) } } ?? false }),
          let foot = view.foot(of: s.id), let menuRect = menuAt(s)
    else { return print("demo stills: desk menu: no figure whose menu leaves the labels clear") }
    let menu = menuView(s)
    print("demo stills: desk menu on \(s.id) at \(foot); check-in \(spotFoot), its label \(checkIn); \(zone) label \(label), \(badge.count) off duty at \(badge.frame)")
    var box = menuRect.union(CGRect(x: foot.x - 45, y: foot.y - tall - 10, width: 90, height: tall + 30))
    for r in [label, badge.frame, checkIn, newcomerBox] { box = box.union(r) }
    box = box.insetBy(dx: -24, dy: -20)
    // 16:9, at least 640 points wide (2.5 pixels a point at most), no plate or label cut at the edges (those under the menu
    // do not show).
    let keep = demoKeep(view, store).filter { !$0.intersects(menuRect) }
    let wide = demoClear(box, keep: keep, in: CGRect(origin: .zero, size: size), minWidth: 640), k = 1600 / wide.width
    print("demo stills: desk menu box \(wide), menu \(menuRect), scale \(k)")
    let shot = ImageRenderer(content: menu)
    shot.scale = k
    guard let whole = view.image(pixelScale: k), let crop = demoCrop(whole, wide, k: k, w: 1600, h: 900), let menuImage = shot.cgImage,
          let ctx = CGContext(data: nil, width: 1600, height: 900, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    // The crop's own top left in pixels (as `demoCrop` rounds and clamps it), so the menu lands where the figure is.
    let ox = CGFloat(min(max(0, Int((wide.minX * k).rounded())), whole.width - 1600))
    let oy = CGFloat(min(max(0, Int((wide.minY * k).rounded())), whole.height - 900))
    ctx.draw(crop, in: CGRect(x: 0, y: 0, width: 1600, height: 900))
    let mx = (menuRect.minX * k - ox).rounded(), my = (menuRect.minY * k - oy).rounded()
    ctx.draw(menuImage, in: CGRect(x: mx, y: 900 - my - CGFloat(menuImage.height), width: CGFloat(menuImage.width), height: CGFloat(menuImage.height)))
    demoWrite(ctx.makeImage(), path)
}

// ───────── The README's moving pictures ─────────

/// The knock's lean in degrees `local` seconds into a three-second round (`WaitingNudge`: its keys, shares and easing,
/// worked out here as Core Animation would play them).
func demoLean(_ local: Double) -> Double {
    let d = WaitingNudge.degrees, s = WaitingNudge.shares
    guard local >= 0, local < WaitingNudge.knock else { return 0 }
    let u = local / WaitingNudge.knock
    guard let i = (0..<(s.count - 1)).last(where: { s[$0] <= u }) else { return 0 }
    let x = (u - s[i]) / (s[i + 1] - s[i])
    // cubic-bezier(.36, .07, .19, .97): the curve's t for this x, then its y.
    func bez(_ a: Double, _ b: Double, _ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
    var lo = 0.0, hi = 1.0
    for _ in 0..<40 { let m = (lo + hi) / 2; if bez(0.36, 0.19, m) < x { lo = m } else { hi = m } }
    return d[i] + (d[i + 1] - d[i]) * bez(0.07, 0.97, (lo + hi) / 2)
}

/// The numbers `--demo-gif-frames` runs on: frames a second, the loop's length, the picture's width in pixels.
struct DemoGifArgs {
    var fps = 15.0, seconds = 6.0, width = 800.0
}

extension DemoGifArgs {
    /// Frames in the loop: `seconds` x `fps`, rounded.
    var count: Int { Int((seconds * fps).rounded()) }
}

/// The numbers read from the arguments, or what is wrong with them. Each must be a finite number within its range:
/// `--fps` above 0 up to 60, `--seconds` above 0 up to 60, `--width` 16 to 4096, `--slow` above 0 up to 100, `--hold`
/// `--fly` `--finish` `--back` `--start` `--switch` `--dwell` `--gap` 0 to 600, `--board` 100 to 4096, `--crab` 0 to 64; the loop 1
/// to 999 frames (they are named f000 to f998).
func demoGifArgs(_ args: [String]) -> (args: DemoGifArgs?, error: String?) {
    /// The flag's number, its default when it is not given; nil when it is not a finite number in `range`.
    func number(_ flag: String, _ fallback: Double, _ range: ClosedRange<Double>, above low: Bool = false) -> Double? {
        guard let given = DemoMode.value(flag, in: args) else { return fallback }
        guard let v = Double(given), v.isFinite, range.contains(v), !(low && v == range.lowerBound) else { return nil }
        return v
    }
    let ranges: [(String, Double, ClosedRange<Double>, Bool)] = [
        ("--fps", 15, 0...60, true), ("--seconds", 6, 0...60, true), ("--width", 800, 16...4096, false), ("--slow", 6, 0...100, true),
        ("--hold", 1, 0...600, false), ("--fly", 0.5, 0...600, false), ("--finish", 2.75, 0...600, false), ("--back", 5.4, 0...600, false),
        ("--board", 980, 100...4096, false), ("--start", 0, 0...600, false), ("--switch", 0, 0...600, false), ("--dwell", 1.2, 0...600, false),
        ("--gap", 1.2, 0...600, false), ("--crab", 0, 0...64, false),
    ]
    var got: [String: Double] = [:]
    for (flag, fallback, range, low) in ranges {
        guard let v = number(flag, fallback, range, above: low) else {
            return (nil, "\(flag) \(DemoMode.value(flag, in: args) ?? "") is not a number \(low ? "above" : "from") \(range.lowerBound) up to \(range.upperBound)")
        }
        got[flag] = v
    }
    if let seed = DemoMode.value("--seed", in: args), UInt64(seed) == nil { return (nil, "--seed \(seed) is not a whole number") }
    var a = DemoGifArgs()
    a.fps = got["--fps"]!
    a.seconds = got["--seconds"]!
    a.width = got["--width"]!
    guard (1...999).contains(a.count) else { return (nil, "\(a.seconds) s at \(a.fps) fps is \(a.count) frames, not 1 to 999") }
    return (a, nil)
}

/// The frames' folder made; nil, or why it could not be.
func demoGifPrepare(_ dir: String) -> String? {
    do {
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return nil
    } catch {
        return "cannot make \(dir): \(error.localizedDescription)"
    }
}

/// One frame written as PNG; nil, or why it could not be.
func demoGifWrite(_ image: CGImage, to path: String) -> String? {
    guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return "cannot encode \(path) as PNG" }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        return nil
    } catch {
        return "cannot write \(path): \(error.localizedDescription)"
    }
}

/// The frames written by this run (`demoGifWrite` succeeded), counted by both the line's run and the other scenes'.
@MainActor var demoGifWritten = 0

/// `--demo-gif-frames <dir> [--only seaview-queue] [--fps 15] [--seconds 6] [--width 800] [--lang <code>] [--pets-dir <folder>]`:
/// the frames of a looping picture, offscreen. seaview-queue: the last one waiting walks from its desk into the line at
/// the user's desk and knocks there with the others, then (answered) walks back to work. Each frame is the room held still
/// (`still`), the walker posed along its route with its running frames (`demoPose`) and each one waiting leaned as its
/// knock is at that moment.
/// The arguments are checked before anything is made; a bad one, a folder that cannot be made, no frame to make, or fewer
/// frames written than asked for prints why and exits 1 (after the crowd's own cleanup).
@MainActor func demoGifFrames(_ dir: String) {
    let args = CommandLine.arguments
    let parsed = demoGifArgs(args)
    guard let a = parsed.args else {
        print("demo gif: \(parsed.error ?? "bad arguments")")
        exit(1)
    }
    let only = DemoMode.value("--only", in: args) ?? "seaview-queue"
    guard ["seaview-queue", "seaview-queue-one", "seaview-beach-one", "seaview-desk", "seaview-blaze", "seaview-orca", "seaview-beach", "seaview-visit", "hero-seaview", "office", "duty-room", "seaview-spotlight"].contains(only)
    else {
        print("demo gif: no \(only)")
        exit(1)
    }
    // `--pick` (the other scenes only) writes just those frames.
    let pick = only.hasPrefix("seaview-queue") ? nil : DemoMode.value("--pick", in: args).map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    let expected = (0..<a.count).filter { pick?.contains($0) ?? true }.count
    guard expected > 0 else {
        print("demo gif: no frame to make")
        exit(1)
    }
    if let error = demoGifPrepare(dir) {
        print("demo gif: \(error)")
        exit(1)
    }
    demoGifWritten = 0
    demoGifRender(dir, a, only: only)
    guard demoGifWritten == expected else {
        print("demo gif: \(demoGifWritten) of \(expected) frames written")
        exit(1)
    }
}

/// `demoGifFrames` once its arguments and folder are good: the frames made and written, counted in `demoGifWritten`.
@MainActor private func demoGifRender(_ dir: String, _ a: DemoGifArgs, only: String) {
    let args = CommandLine.arguments
    let fps = a.fps, seconds = a.seconds, width = CGFloat(a.width)
    DemoMode.enter(arguments: args)
    let defaults = UserDefaults.standard
    let registered = Extensions.registered
    Extensions.registered = nil
    defaults.set(true, forKey: "office")
    defaults.set(OfficeTheme.zone.name, forKey: "officeTheme")
    defaults.set(true, forKey: "officeSpotlight")
    WaitingNudge.override = true
    defer {
        DemoMode.leave()
        Extensions.registered = registered
        OfficeTheme.shown = nil
        WaitingNudge.override = nil
    }
    L10n.reset()
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    guard ZoneArt.scene != nil else { return print("demo gif: no seaview art") }
    OfficeTheme.shown = OfficeTheme.zone

    let size = CGSize(width: 1180, height: 790)
    if only == "seaview-queue-one" { return demoGifQueueOne(dir, fps: fps, seconds: seconds, width: width, size: size) }
    if only != "seaview-queue" { return demoGifScene(only, dir: dir, fps: fps, seconds: seconds, width: width, size: size) }
    // The crowd as it is (the four waiting in the line), and the same with one more, at work till now, asking: it walks
    // from its desk to the end of the line (`--walker <key>`, a row's key in DemoCrowd; default the one nearest the line).
    let busyStore = demoStore()
    func asking(_ id: String) -> Store {
        let store = demoStore()
        if let i = store.sessions.firstIndex(where: { $0.id == id }) {
            let w = store.sessions[i]
            var s = Session(id: w.id, pid: w.pid, project: w.project, name: w.name, status: "waiting", since: Date(), summary: SummaryLine.answer(options: 2).rendered,
                            waitingFor: "permission prompt", registryName: w.registryName, cwd: w.cwd, kind: w.kind, origin: "user", model: w.model,
                            summaryLine: .answer(options: 2))
            store.sessions[i] = s
        }
        return store
    }
    func room(_ store: Store) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.calmOverride = false
        view.still = true
        view.update(store)
        return view
    }
    let busyView = room(busyStore)
    let walkerKey = DemoMode.value("--walker", in: args)
    var pick: (walker: Session, view: ZoneView, store: Store, desk: CGPoint, spot: CGPoint, seconds: Double)?
    for s in busyStore.sessions where s.status == "busy" && (walkerKey == nil || s.id.hasSuffix("-" + walkerKey!)) {
        let askingStore = asking(s.id)
        let view = room(askingStore)
        guard let desk = busyView.foot(of: s.id), let spot = view.foot(of: s.id), let walk = view.demoWalk(from: desk, to: spot) else { continue }
        print("demo gif: candidate \(s.id) \(String(format: "%.2f", walk.seconds)) s")
        if pick == nil || walk.seconds < pick!.seconds { pick = (s, view, askingStore, desk, spot, walk.seconds) }
    }
    guard let pick else { return print("demo gif: no walker") }
    let walker = pick.walker, waitingView = pick.view, waitingStore = pick.store, desk = pick.desk, spot = pick.spot
    let line = waitingView.figureIDs.compactMap { id in busyStore.sessions.first { $0.id == id } }.filter { $0.status == "waiting" || $0.id == walker.id }
    guard let into = waitingView.demoWalk(from: desk, to: spot), let back = busyView.demoWalk(from: spot, to: desk) else { return print("demo gif: no walk") }
    // The crop: the line, the walker's desk and the way between, as the still's margins.
    let ids = line.map(\.id)
    guard var box = demoBox(waitingView, ids, left: 200, up: 260, right: 200, down: 110) else { return }
    for p in into.route + back.route { box = box.union(CGRect(x: p.x - 90, y: p.y - 150, width: 180, height: 220)) }
    box = box.intersection(CGRect(origin: .zero, size: size))
    let k = width / box.width
    print("demo gif: walker \(walker.id), walk \(String(format: "%.2f", into.seconds)) s in, \(String(format: "%.2f", back.seconds)) s back; box \(box), scale \(k)")

    // The round: at its desk, the walk in, in the line, the walk back; the loop is whole knock rounds long so the others'
    // knocks run on across the seam.
    let hold = 0.6
    let arrive = hold + into.seconds
    let leave = seconds - back.seconds - 0.3
    for s in line { print("demo gif: \(s.id) knock phase \(WaitingNudge.phase(of: s.id))") }
    print("demo gif: arrives \(String(format: "%.2f", arrive)) s, leaves \(String(format: "%.2f", leave)) s")
    guard leave > arrive + 0.5 else { return print("demo gif: \(seconds) s is too short for the walks") }
    func steps(_ walk: (route: [CGPoint], seconds: Double)) -> (values: [CGImage], times: [Double]) {
        guard let a = ZoneView.runningSteps(waitingView.pet(of: walker.id), route: walk.route, seconds: walk.seconds) else { return ([], []) }
        return ((a.values as? [CGImage]) ?? [], (a.keyTimes ?? []).map(\.doubleValue))
    }
    let stepsIn = steps(into), stepsBack = steps(back)
    func at(_ walk: (route: [CGPoint], seconds: Double), _ t: Double) -> CGPoint {
        let r = walk.route
        var lengths: [CGFloat] = [0]
        for (p, q) in zip(r, r.dropFirst()) { lengths.append(lengths.last! + hypot(q.x - p.x, q.y - p.y)) }
        let d = lengths.last! * CGFloat(min(max(t / walk.seconds, 0), 1))
        guard let i = (1..<r.count).first(where: { lengths[$0] >= d }) else { return r.last! }
        let leg = lengths[i] - lengths[i - 1], u = leg > 0 ? (d - lengths[i - 1]) / leg : 0
        return CGPoint(x: r[i - 1].x + (r[i].x - r[i - 1].x) * u, y: r[i - 1].y + (r[i].y - r[i - 1].y) * u)
    }
    func frame(_ s: (values: [CGImage], times: [Double]), _ t: Double, of seconds: Double) -> CGImage? {
        guard !s.values.isEmpty else { return nil }
        let u = t / seconds
        let i = s.times.lastIndex(where: { $0 <= u }) ?? 0
        return s.values[min(i, s.values.count - 1)]
    }
    let standing = (waitingView.spriteLayer(of: walker.id)?.contents, busyView.spriteLayer(of: walker.id)?.contents)
    func lean(_ view: ZoneView, _ id: String, _ degrees: Double) {
        guard let sprite = view.spriteLayer(of: id) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.transform = CATransform3DIdentity
        if degrees != 0 {
            let pivot = WaitingNudge.feetPivot(of: sprite), flipped = WaitingNudge.flipped(sprite)
            var t = CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0)
            t = CATransform3DConcat(t, CATransform3DMakeRotation(CGFloat(degrees * .pi / 180) * (flipped ? 1 : -1), 0, 0, 1))
            sprite.transform = CATransform3DConcat(t, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        }
        CATransaction.commit()
    }
    func knockAt(_ id: String, _ t: Double) -> Double {
        let local = (t + WaitingNudge.phase(of: id)).truncatingRemainder(dividingBy: WaitingNudge.period)
        return demoLean(local)
    }
    let count = Int((seconds * fps).rounded())
    var written = 0
    for n in 0..<count {
        let t = Double(n) / fps
        let view: ZoneView
        // The room's own loops at t (screens, LEDs, auras, helpers); the walker's desk goes by its own clock, which restarts
        // when it is answered (at `leave`) and when it starts waiting (at `hold`).
        if t < hold || t >= leave {
            busyView.demoTick(t, store: busyStore, local: [walker.id: t >= leave ? t - leave : t + seconds - leave])
        } else {
            waitingView.demoTick(t, store: waitingStore, local: [walker.id: t - hold])
        }
        if t < hold || t >= leave {
            view = busyView
            if t >= leave {
                let w = t - leave
                busyView.demoPose(walker.id, at: at(back, w), frame: w < back.seconds ? frame(stepsBack, w, of: back.seconds) : nil)
                if w >= back.seconds { busyView.spriteLayer(of: walker.id)?.contents = standing.1 }
            } else {
                busyView.demoPose(walker.id, at: desk, frame: nil)
                busyView.spriteLayer(of: walker.id)?.contents = standing.1
            }
        } else {
            view = waitingView
            let w = t - hold
            if w < into.seconds {
                waitingView.demoPose(walker.id, at: at(into, w), frame: frame(stepsIn, w, of: into.seconds))
            } else {
                waitingView.demoPose(walker.id, at: spot, frame: nil)
                waitingView.spriteLayer(of: walker.id)?.contents = standing.0
            }
        }
        for s in line {
            if s.id == walker.id {
                // its knocks start on arrival (`ZoneView.knock`), not while walking or once back at work.
                lean(view, s.id, view === waitingView && t >= arrive ? knockAt(s.id, t - arrive) : 0)
            } else {
                lean(view, s.id, knockAt(s.id, t))
            }
        }
        guard let crop = demoCrop(view.image(pixelScale: k), box, k: k) else {
            print("demo gif: frame \(n) NOT made")
            continue
        }
        if let error = demoGifWrite(crop, to: dir + String(format: "/f%03d.png", n)) {
            print("demo gif: \(error)")
            continue
        }
        written += 1
        demoGifWritten += 1
        if n == 0 { print("demo gif: frame size \(crop.width) x \(crop.height)") }
    }
    print("demo gif: \(written) frames at \(fps) fps into \(dir)")
}

/// `--only seaview-queue-one`: nobody else waiting (the crowd's waiting ones made idle), one at work asks: the last
/// `--hold` seconds of its walk to the head of the line at the user's desk, a knock as it arrives, `--dwell` seconds there,
/// then (answered) it walks back to its desk while the next one (`--next <key>`; default the one with the next shortest
/// walk) comes and arrives `--gap` seconds later and knocks. `--walker <key>` picks the first (default the shortest walk).
/// The crop is round the head of the line, 16:9, `--box x,y,w,h` (view points, made 16:9) to set it; each frame is exactly
/// `--width` by 9/16 of it. The picture just restarts at its end.
@MainActor private func demoGifQueueOne(_ dir: String, fps: Double, seconds: Double, width: CGFloat, size: CGSize) {
    let args = CommandLine.arguments
    func idle(_ store: Store, _ id: String) {
        guard let i = store.sessions.firstIndex(where: { $0.id == id }) else { return }
        let w = store.sessions[i]
        let line = w.summaryLine ?? .said(w.summary, .reply)
        store.sessions[i] = Session(id: w.id, pid: w.pid, project: w.project, name: w.name, status: "idle", since: Date(), summary: line.rendered,
                                    waitingFor: "", registryName: w.registryName, cwd: w.cwd, kind: w.kind, tool: "", origin: "user", model: w.model,
                                    summaryLine: line)
        store.seen[id] = Date().timeIntervalSince1970 + 5
    }
    let waiting = demoStore().sessions.filter { $0.status == "waiting" }.map(\.id)
    func calmStore() -> Store {
        let store = demoStore()
        for id in waiting { idle(store, id) }
        return store
    }
    func asking(_ id: String) -> Store {
        let store = calmStore()
        if let i = store.sessions.firstIndex(where: { $0.id == id }) {
            let w = store.sessions[i]
            store.sessions[i] = Session(id: w.id, pid: w.pid, project: w.project, name: w.name, status: "waiting", since: Date(), summary: SummaryLine.answer(options: 2).rendered,
                                        waitingFor: "permission prompt", registryName: w.registryName, cwd: w.cwd, kind: w.kind, origin: "user", model: w.model,
                                        summaryLine: .answer(options: 2))
        }
        return store
    }
    func room(_ store: Store) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.calmOverride = false
        view.still = true
        view.update(store)
        return view
    }
    let base = calmStore(), baseView = room(base)
    // The busy ones by their walk to the head of the line.
    var walks: [(id: String, desk: CGPoint, spot: CGPoint, seconds: Double)] = []
    for s in base.sessions where s.status == "busy" {
        let view = room(asking(s.id))
        guard let desk = baseView.foot(of: s.id), let spot = view.foot(of: s.id), let walk = view.demoWalk(from: desk, to: spot) else { continue }
        walks.append((s.id, desk, spot, walk.seconds))
    }
    walks.sort { $0.seconds < $1.seconds }
    for w in walks.prefix(6) { print("demo gif: candidate \(w.id) \(String(format: "%.2f", w.seconds)) s") }
    func chosen(_ flag: String, besides: String?) -> (id: String, desk: CGPoint, spot: CGPoint, seconds: Double)? {
        if let key = DemoMode.value(flag, in: args) { return walks.first { $0.id.hasSuffix("-" + key) } }
        return walks.first { $0.id != besides }
    }
    guard let first = chosen("--walker", besides: nil), let second = chosen("--next", besides: first.id), first.id != second.id else { return print("demo gif: no walkers") }
    let storeA = asking(first.id), viewA = room(storeA), storeB = asking(second.id), viewB = room(storeB)
    guard let inA = viewA.demoWalk(from: first.desk, to: first.spot), let backA = viewB.demoWalk(from: first.spot, to: first.desk),
          let inB = viewB.demoWalk(from: second.desk, to: second.spot) else { return print("demo gif: no walk") }
    let hold = min(Double(DemoMode.value("--hold", in: args) ?? "") ?? 0.8, inA.seconds)
    let dwell = Double(DemoMode.value("--dwell", in: args) ?? "") ?? 1.2, gap = Double(DemoMode.value("--gap", in: args) ?? "") ?? 1.2
    let arriveA = hold, leaveA = arriveA + dwell, arriveB = leaveA + gap, setOffB = arriveB - inB.seconds
    print("demo gif: \(first.id) walks in \(String(format: "%.2f", inA.seconds)) s (the last \(hold) s shown), back \(String(format: "%.2f", backA.seconds)) s; \(second.id) walks in \(String(format: "%.2f", inB.seconds)) s, sets off at \(String(format: "%.2f", setOffB)) s, arrives \(String(format: "%.2f", arriveB)) s")
    // The crop: round the head of the line (the user's desk beside it).
    var box = CGRect(x: first.spot.x - 180, y: first.spot.y - 180, width: 360, height: 202)
    if let b = DemoMode.value("--box", in: args).map({ $0.split(separator: ",").compactMap { Double($0) } }), b.count == 4 { box = CGRect(x: b[0], y: b[1], width: b[2], height: b[3]) }
    box = demoWide(box, in: CGRect(origin: .zero, size: size))
    let k = width / box.width, tall = Int((width * 9 / 16).rounded())
    print("demo gif: box \(box), scale \(k)")
    func steps(_ view: ZoneView, _ id: String, _ walk: (route: [CGPoint], seconds: Double)) -> (values: [CGImage], times: [Double]) {
        guard let a = ZoneView.runningSteps(view.pet(of: id), route: walk.route, seconds: walk.seconds) else { return ([], []) }
        return ((a.values as? [CGImage]) ?? [], (a.keyTimes ?? []).map(\.doubleValue))
    }
    func at(_ walk: (route: [CGPoint], seconds: Double), _ t: Double) -> CGPoint {
        let r = walk.route
        var lengths: [CGFloat] = [0]
        for (p, q) in zip(r, r.dropFirst()) { lengths.append(lengths.last! + hypot(q.x - p.x, q.y - p.y)) }
        let d = lengths.last! * CGFloat(min(max(t / walk.seconds, 0), 1))
        guard let i = (1..<r.count).first(where: { lengths[$0] >= d }) else { return r.last! }
        let leg = lengths[i] - lengths[i - 1], u = leg > 0 ? (d - lengths[i - 1]) / leg : 0
        return CGPoint(x: r[i - 1].x + (r[i].x - r[i - 1].x) * u, y: r[i - 1].y + (r[i].y - r[i - 1].y) * u)
    }
    func frame(_ s: (values: [CGImage], times: [Double]), _ t: Double, of seconds: Double) -> CGImage? {
        guard !s.values.isEmpty, t < seconds else { return nil }
        let i = s.times.lastIndex(where: { $0 <= t / seconds }) ?? 0
        return s.values[min(i, s.values.count - 1)]
    }
    let stepsInA = steps(viewA, first.id, inA), stepsBackA = steps(viewB, first.id, backA), stepsInB = steps(viewB, second.id, inB)
    let stepsInBEarly = steps(viewA, second.id, inB)
    let standingA = (viewA.spriteLayer(of: first.id)?.contents, viewB.spriteLayer(of: first.id)?.contents)
    let standingB = (viewA.spriteLayer(of: second.id)?.contents, viewB.spriteLayer(of: second.id)?.contents)
    let standingBase = (baseView.spriteLayer(of: first.id)?.contents, baseView.spriteLayer(of: second.id)?.contents)
    var asks = false
    func lean(_ view: ZoneView, _ id: String, _ degrees: Double) {
        guard let sprite = view.spriteLayer(of: id) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.transform = CATransform3DIdentity
        if degrees != 0 {
            let pivot = WaitingNudge.feetPivot(of: sprite), flipped = WaitingNudge.flipped(sprite)
            var t = CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0)
            t = CATransform3DConcat(t, CATransform3DMakeRotation(CGFloat(degrees * .pi / 180) * (flipped ? 1 : -1), 0, 0, 1))
            sprite.transform = CATransform3DConcat(t, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
        }
        CATransaction.commit()
    }
    // One knock 0.15 s after arriving.
    func knock(_ since: Double) -> Double { demoLean(since - 0.15) }
    var written = 0
    for n in 0..<Int((seconds * fps).rounded()) {
        let t = Double(n) / fps
        let view: ZoneView
        if t < leaveA {
            // The first one walking in or at the head of the line; the next one at its desk, or (out of the crop) setting off.
            view = viewA
            viewA.demoTick(t, store: storeA, local: [first.id: t, second.id: t])
            let w = t + inA.seconds - hold
            if w < inA.seconds {
                viewA.demoPose(first.id, at: at(inA, w), frame: frame(stepsInA, w, of: inA.seconds))
            } else {
                viewA.demoPose(first.id, at: first.spot, frame: nil)
                viewA.spriteLayer(of: first.id)?.contents = standingA.0
            }
            lean(viewA, first.id, t >= arriveA ? knock(t - arriveA) : 0)
            if t >= setOffB {
                viewA.demoPose(second.id, at: at(inB, t - setOffB), frame: frame(stepsInBEarly, t - setOffB, of: inB.seconds))
            } else {
                viewA.demoPose(second.id, at: second.desk, frame: nil)
                viewA.spriteLayer(of: second.id)?.contents = standingB.0
            }
        } else {
            // Answered: the first walks back to its desk (at work again), the next one walks in, arrives and knocks. Until
            // the next one's feet come into the crop the room is the one with nobody waiting (its words would show at the
            // edge before it does).
            let v = t - setOffB
            if !asks { asks = box.insetBy(dx: -20, dy: -20).contains(at(inB, max(0, v))) }
            view = asks ? viewB : baseView
            view.demoTick(t, store: asks ? storeB : base, local: [first.id: t - leaveA, second.id: t])
            let w = t - leaveA
            if w < backA.seconds {
                view.demoPose(first.id, at: at(backA, w), frame: frame(stepsBackA, w, of: backA.seconds))
            } else {
                view.demoPose(first.id, at: first.desk, frame: nil)
                view.spriteLayer(of: first.id)?.contents = asks ? standingA.1 : standingBase.0
            }
            lean(view, first.id, 0)
            if v < inB.seconds {
                view.demoPose(second.id, at: at(inB, max(0, v)), frame: v >= 0 ? frame(stepsInB, v, of: inB.seconds) : nil)
            } else {
                view.demoPose(second.id, at: second.spot, frame: nil)
                view.spriteLayer(of: second.id)?.contents = asks ? standingB.1 : standingBase.1
            }
            lean(view, second.id, t >= arriveB ? knock(t - arriveB) : 0)
        }
        guard let crop = demoCrop(view.image(pixelScale: k), box, k: k, w: Int(width.rounded()), h: tall) else {
            print("demo gif: frame \(n) NOT made")
            continue
        }
        if let error = demoGifWrite(crop, to: dir + String(format: "/f%03d.png", n)) {
            print("demo gif: \(error)")
            continue
        }
        written += 1
        demoGifWritten += 1
        if n == 0 { print("demo gif: frame size \(crop.width) x \(crop.height)") }
    }
    print("demo gif: \(written) frames at \(fps) fps into \(dir)")
}

/// The top `rows` pixel rows of a picture, as bytes (to tell two pictures' tops apart).
func demoStrip(_ image: CGImage?, rows: Int) -> [UInt8] {
    guard let image else { return [] }
    let w = image.width, h = min(rows, image.height)
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { buf in
        guard let c = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        c.draw(image, in: CGRect(x: 0, y: h - image.height, width: w, height: image.height))
    }
    return bytes
}

/// `a` with `b` laid over it at `alpha` (the same size): the seam's crossfade.
func demoBlend(_ a: CGImage, _ b: CGImage, _ alpha: CGFloat) -> CGImage? {
    guard let c = CGContext(data: nil, width: a.width, height: a.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let r = CGRect(x: 0, y: 0, width: a.width, height: a.height)
    c.draw(a, in: r)
    c.setAlpha(alpha)
    c.draw(b, in: r)
    return c.makeImage()
}

/// The other moving pictures (`--only`): seaview-desk, seaview-blaze, seaview-orca, seaview-beach. Each frame is the still
/// room posed at its moment (`demoTick`: screens, LEDs, auras, helpers; the outdoors by `demoPose(at:)`), cropped.
/// `--pick 0,40` writes only those frames (a probe); `--box x,y,w,h` (view points) overrides the crop; `--seed n` the run's draws.
/// `--wide`: the crop (theirs or `--box`) made 16:9 (`demoWide`) and each frame exactly `--width` by 9/16 of it.
/// `--cut`: the picture just restarts at its end: no crossfade into the start, the helpers at their own pace (not retimed to
/// whole trips in the loop). `--start s`: seaview-orca and seaview-beach begin `s` seconds later in their run.
@MainActor func demoGifScene(_ name: String, dir: String, fps: Double, seconds: Double, width: CGFloat, size: CGSize) {
    let args = CommandLine.arguments
    let pick = DemoMode.value("--pick", in: args).map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    let boxArg = DemoMode.value("--box", in: args).map { $0.split(separator: ",").compactMap { Double($0) } }
    let wide = args.contains("--wide"), cut = args.contains("--cut")
    let start = Double(DemoMode.value("--start", in: args) ?? "") ?? 0
    let tall = Int((width * 9 / 16).rounded())
    func cropped(_ image: CGImage?, _ box: CGRect, k: CGFloat) -> CGImage? {
        wide ? demoCrop(image, box, k: k, w: Int(width.rounded()), h: tall) : demoCrop(image, box, k: k)
    }
    func room(_ store: Store) -> ZoneView {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.calmOverride = false
        view.still = true
        view.update(store)
        return view
    }
    func sid(_ store: Store, _ key: String) -> String { store.sessions.first { $0.id.hasSuffix("-" + key) }?.id ?? "" }
    func boxed(_ box: CGRect) -> CGRect {
        let b = boxArg.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
        if wide { return demoWide(b ?? box, in: CGRect(origin: .zero, size: size)) }
        return b ?? box.intersection(CGRect(origin: .zero, size: size))
    }
    let count = Int((seconds * fps).rounded())
    let eps = 1e-4  // keeps n / fps off the loop's frame edges (its index is floored)
    var written = 0
    func save(_ image: CGImage?, _ n: Int) {
        guard let image else { return print("demo gif: frame \(n) NOT made") }
        if let error = demoGifWrite(image, to: dir + String(format: "/f%03d.png", n)) { return print("demo gif: \(error)") }
        written += 1
        demoGifWritten += 1
        if written == 1 { print("demo gif: frame size \(image.width) x \(image.height)") }
    }
    func wanted(_ n: Int) -> Bool { pick?.contains(n) ?? true }
    defer {
        ZoneOutdoorArt.demoForget()
        print("demo gif: \(written) frames at \(fps) fps, \(seconds) s into \(dir)")
    }

    switch name {
    case "seaview-desk":
        // A busy desk: its code scrolling, its LED breathing, its badge, its helpers on the desk edge.
        let store = demoStore()
        let view = room(store)
        let id = sid(store, "web-storefront")
        for l in view.demoLoops(store) {
            print("demo gif: loops \(store.sessions.first { $0.name == l.name }?.id ?? "-"): code \(l.code.map { String(format: "%.3f", $0) } ?? "-") s, walk \(l.walk.map { String(format: "%.3f", $0) } ?? "-") s")
        }
        print("demo gif: LED breath \(ZoneBreath.breath) s")
        guard let b = demoBox(view, [id], left: 85, up: 160, right: 155, down: 50) else { return }
        let box = boxed(b), k = width / box.width
        print("demo gif: box \(box), scale \(k)")
        // The desk's own clock starts where its LED is as bright at the loop's end as at its start (any start is a live one:
        // the breathing begins when the work does), so the LED, too, runs on across the seam.
        var t0 = 0.0
        if let deskID = view.demoDeskID(id) {
            var best = Double.infinity
            for i in 0..<600 {
                let c = Double(i) * ZoneBreath.breath / 600
                let d = abs(Double(ZoneBreath.opacity(at: c, deskID: deskID) - ZoneBreath.opacity(at: c + seconds, deskID: deskID)))
                    + abs(Double(ZoneBreath.opacity(at: c + 0.1, deskID: deskID) - ZoneBreath.opacity(at: c + seconds + 0.1, deskID: deskID)))
                if d < best { best = d; t0 = c }
            }
            print("demo gif: desk clock starts at \(String(format: "%.3f", t0)) s (LED seam \(String(format: "%.4f", best)))")
        }
        // The helpers' trips (`BGWalker.cycle`) do not divide the code's loop: they are timed to make whole trips in it.
        let name = store.sessions.first { $0.id == id }?.name, trip = view.demoLoops(store).first { $0.name == name }?.walk ?? seconds
        let trips = max(1, (seconds / trip).rounded())
        print("demo gif: helpers \(Int(trips)) trips of \(String(format: "%.3f", seconds / trips)) s (live \(String(format: "%.3f", trip)) s)")
        for n in 0..<count where wanted(n) {
            let t = Double(n) * seconds / Double(count) + eps
            view.demoTick(t, store: store, local: [id: t + t0], helpers: [id: cut ? t + t0 : (t - eps) * trips * trip / seconds + t0 + eps])
            save(cropped(view.image(pixelScale: k), box, k: k), n)
        }

    case "seaview-blaze":
        // rag-index (on Fable) at work, then done and read (it stays at its desk), and again: its aura flares and calms, each
        // shape starting over at the change as live; embeddings (on Fable too, done) beside it, calm.
        let busyStore = demoStore()
        let rag = sid(busyStore, "ai-rag"), emb = sid(busyStore, "ai-embeddings")
        let idleStore = demoStore()
        if let i = idleStore.sessions.firstIndex(where: { $0.id == rag }) {
            let w = idleStore.sessions[i]
            let line = w.summaryLine ?? .said(w.summary, .reply)
            idleStore.sessions[i] = Session(id: w.id, pid: w.pid, project: w.project, name: w.name, status: "idle", since: Date(), summary: line.rendered,
                                            waitingFor: "", registryName: w.registryName, cwd: w.cwd, kind: w.kind, tool: "", origin: "user", model: w.model,
                                            summaryLine: line)
            idleStore.agents[rag] = nil
            idleStore.agentCounts[rag] = nil
            idleStore.seen[rag] = Date().timeIntervalSince1970 + 5
        }
        let busyView = room(busyStore), idleView = room(idleStore)
        print("demo gif: rag \(busyView.foot(of: rag).map { "\($0)" } ?? "-") busy, \(idleView.foot(of: rag).map { "\($0)" } ?? "-") idle; embeddings \(idleView.foot(of: emb).map { "\($0)" } ?? "-")")
        guard let b = demoBox(busyView, [rag, emb], left: 120, up: 175, right: 110, down: 60) else { return }
        let box = boxed(b), k = width / box.width
        print("demo gif: box \(box), scale \(k)")
        // `--switch s`: it finishes s seconds in (half way when not given).
        let half = DemoMode.value("--switch", in: args) == nil ? seconds / 2 : Double(DemoMode.value("--switch", in: args)!) ?? seconds / 2
        // embeddings' glow held at one moment (`--hold`, its aura's seconds): one with no lightning tree on it.
        let hold = Double(DemoMode.value("--hold", in: args) ?? "") ?? 5
        for n in 0..<count where wanted(n) {
            let t = Double(n) * seconds / Double(count) + eps
            let busy = t < half
            let view = busy ? busyView : idleView
            view.demoTick(t, store: busy ? busyStore : idleStore, local: [rag: busy ? t : t - half, emb: hold])
            save(cropped(view.image(pixelScale: k), box, k: k), n)
        }

    case "seaview-orca", "seaview-beach":
        // A run of the live outdoors with the orca's landing (C) at T: orca from 0.5 s before the clip, beach from 6 s before.
        // No 12 s window round the clip has its animals at rest at both ends (the gulls land 4.6 s before it, the crabs come
        // back 2-6 s after it is dropped), so the seam is a crossfade (none with `--cut`): the last half second blends into the half second before
        // the start (the sea is the same loop frame on both sides).
        let calm = demoStore()
        calm.focused = nil
        let view = room(calm)
        guard let spec = ZoneOutdoorArt.spec, let clip = ZoneOutdoorArt.orca?.clip("C") else { return print("demo gif: no outdoor art") }
        let T = 20.0
        let a = (name == "seaview-orca" ? T - 0.5 : T - 6) + start
        let seed = UInt64(DemoMode.value("--seed", in: args) ?? "") ?? 7
        guard let script = view.outdoor.demoStrike("C", orcaAt: T, from: 0, to: a + seconds + 20, seed: seed) else { return print("demo gif: no strike") }
        for note in script.notes { print("demo gif: \(note)") }
        print("demo gif: loop \(spec.loopFrames) frames at \(spec.fps) fps; clip \(clip.frames) frames at \(clip.fps) fps, \(clip.seconds) s, starts at loop frame \(clip.startLoopFrame)")
        let fit = ZoneFit(scene: spec.picture, view: size)
        let r = fit.rect(spec.loopBox).intersection(CGRect(origin: .zero, size: size))
        let orcaBox = fit.rect(clip.box)
        print("demo gif: sea \(r), clip box \(orcaBox)")
        let b = name == "seaview-orca" ? orcaBox.insetBy(dx: -60, dy: -40)
            : CGRect(x: r.minX + r.width * 0.36, y: r.minY + 34, width: r.width * 0.64, height: r.height * 0.52)
        let box = boxed(b), k = width / box.width
        print("demo gif: box \(box), scale \(k)")
        func shot(_ t: Double) -> CGImage? {
            view.demoTick(t, store: calm)
            view.outdoor.demoPose(at: t)
            let image = cropped(view.image(pixelScale: k), box, k: k)
            ZoneOutdoorArt.demoForget()
            return image
        }
        let m = cut ? 0 : Int((0.5 * fps).rounded())
        var before: [CGImage] = []
        if pick == nil || pick!.contains(where: { $0 >= count - m }) {
            for j in 0..<m { if let i = shot(a - Double(m - j) / fps + eps) { before.append(i) } }
        }
        for n in 0..<count where wanted(n) {
            guard let image = shot(a + Double(n) / fps + eps) else { continue }
            let j = n - (count - m)
            if j >= 0, before.indices.contains(j) {
                save(demoBlend(image, before[j], CGFloat(j + 1) / CGFloat(m + 1)), n)
            } else {
                save(image, n)
            }
        }

    case "seaview-beach-one":
        // One crab (`--crab i`, its index in the beach's crabs) walks a step from the first frame on while one gull flies over
        // it (crossing the crop a little above its middle at `--switch` seconds, half way when not given); the other beach
        // animals are not shown, and the crop is round the walking one (`--box` to set it). The sea plays its loop.
        // `--seed n` picks the step and the gull.
        let calm = demoStore()
        calm.focused = nil
        let view = room(calm)
        guard let spec = ZoneOutdoorArt.spec else { return print("demo gif: no outdoor art") }
        let fit = ZoneFit(scene: spec.picture, view: size)
        let crabs = view.outdoor.crabs
        for (i, c) in crabs.enumerated() { print("demo gif: crab \(i) species \(c.species) at \(fit.point(c.at))") }
        let which = Int(DemoMode.value("--crab", in: args) ?? "") ?? 0
        guard crabs.indices.contains(which), let kind = view.outdoor.species(of: crabs[which]) else { return print("demo gif: no crab \(which)") }
        var rng = ZoneRandom(seed: UInt64(DemoMode.value("--seed", in: args) ?? "") ?? 7)
        let c = crabs[which]
        let step = ZoneOutdoorGeometry.crabStep(from: c.at, crab: kind, using: &rng)
        for (i, other) in crabs.enumerated() {
            other.stillWalk = i == which ? step : ZoneCrabWalk(from: other.at, to: other.at, seconds: 0, facing: other.facing)
        }
        let from = fit.point(step.from), to = fit.point(step.to)
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let reach = max(abs(to.x - from.x), 60) + 160
        let box = boxed(CGRect(x: mid.x - reach / 2, y: mid.y - reach * 9 / 32 - 20, width: reach, height: reach * 9 / 16)), k = width / box.width
        // The gull's line: through the crop a little above its middle (in the picture), from its upper right to its lower left.
        let centre = fit.back(CGPoint(x: box.midX, y: box.midY - box.height * 0.22))
        let a = CGPoint(x: centre.x + 400, y: centre.y - 160), b = CGPoint(x: centre.x - 400, y: centre.y + 160)
        let species = spec.gullSpecies(using: &rng)
        var flight = ZoneOutdoorGeometry.flight(a, b, height: 1.8, delay: 0, spec: spec, species: species)
        let along = CGVector(dx: flight.to.x - flight.from.x, dy: flight.to.y - flight.from.y)
        let u = ((centre.x - flight.from.x) * along.dx + (centre.y - flight.from.y) * along.dy) / max(1e-9, along.dx * along.dx + along.dy * along.dy)
        let over = DemoMode.value("--switch", in: args).flatMap(Double.init) ?? seconds / 2
        flight.delay = over - Double(u) * flight.seconds
        print("demo gif: crab \(which) walks \(from) to \(to) in \(String(format: "%.2f", step.seconds)) s; gull over the middle at \(over) s (flight \(String(format: "%.2f", flight.seconds)) s); box \(box), scale \(k)")
        for n in 0..<count where wanted(n) {
            let t = Double(n) / fps
            view.demoTick(t, store: calm)
            view.outdoor.pose(at: t, gulls: [flight])
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, other) in (crabs + view.outdoor.walkers).enumerated() { other.layer.isHidden = i != which }
            CATransaction.commit()
            save(cropped(view.image(pixelScale: k), box, k: k), n)
            ZoneOutdoorArt.demoForget()
        }

    case "seaview-visit":
        // checkout (busy) walks from its desk to storefront's and says its word there, the bubble on from the moment it
        // sets off (`dress` puts it on with the visit; the walk carries it). A visit lasts the walk and `ZoneVisits.stay`
        // (20 s) more: the way back is not in the loop, so the seam is a crossfade into the half second before the start
        // (none with `--cut`).
        let calm = demoStore()
        calm.focused = nil
        let busyView = room(calm)
        let visitor = sid(calm, "web-checkout"), host = sid(calm, "web-storefront")
        let visitStore = demoStore()
        visitStore.focused = nil
        let visitView = room(visitStore)
        visitView.visit(visitor, to: host, words: DemoCrowd.visitWords(DemoCrowd.index(L10n.language)), until: Date() + 3600)
        visitView.update(visitStore)
        guard let desk = busyView.foot(of: visitor), let spot = visitView.foot(of: visitor), let walk = visitView.demoWalk(from: desk, to: spot),
            let a = ZoneView.runningSteps(visitView.pet(of: visitor), route: walk.route, seconds: walk.seconds)
        else { return print("demo gif: no visit walk") }
        let values = (a.values as? [CGImage]) ?? [], times = (a.keyTimes ?? []).map(\.doubleValue)
        let standing = visitView.spriteLayer(of: visitor)?.contents
        guard var b = demoBox(visitView, [visitor, host], left: 220, up: 250, right: 220, down: 90) else { return }
        for p in walk.route { b = b.union(CGRect(x: p.x - 90, y: p.y - 150, width: 180, height: 220)) }
        let box = boxed(b), k = width / box.width
        if let spec = ZoneOutdoorArt.spec {
            let sea = ZoneFit(scene: spec.picture, view: size).rect(spec.loopBox)
            print("demo gif: sea \(sea), meets the box: \(sea.intersects(box))")
        }
        let hold = Double(DemoMode.value("--hold", in: args) ?? "") ?? 1.0
        print("demo gif: walk \(String(format: "%.2f", walk.seconds)) s from \(desk) to \(spot); sets off at \(hold) s; box \(box), scale \(k)")
        func at(_ t: Double) -> CGPoint {
            let r = walk.route
            var lengths: [CGFloat] = [0]
            for (p, q) in zip(r, r.dropFirst()) { lengths.append(lengths.last! + hypot(q.x - p.x, q.y - p.y)) }
            let d = lengths.last! * CGFloat(min(max(t / walk.seconds, 0), 1))
            guard let i = (1..<r.count).first(where: { lengths[$0] >= d }) else { return r.last! }
            let leg = lengths[i] - lengths[i - 1], u = leg > 0 ? (d - lengths[i - 1]) / leg : 0
            return CGPoint(x: r[i - 1].x + (r[i].x - r[i - 1].x) * u, y: r[i - 1].y + (r[i].y - r[i - 1].y) * u)
        }
        func shot(_ t: Double) -> CGImage? {
            if t < hold {
                busyView.demoTick(t, store: calm)
                return cropped(busyView.image(pixelScale: k), box, k: k)
            }
            let w = t - hold
            visitView.demoTick(t, store: visitStore)
            if w < walk.seconds {
                let u = w / walk.seconds
                let i = times.lastIndex(where: { $0 <= u }) ?? 0
                visitView.demoPose(visitor, at: at(w), frame: values.isEmpty ? nil : values[min(i, values.count - 1)])
            } else {
                visitView.demoPose(visitor, at: spot, frame: nil)
                visitView.spriteLayer(of: visitor)?.contents = standing
            }
            return cropped(visitView.image(pixelScale: k), box, k: k)
        }
        let m = cut ? 0 : Int((0.5 * fps).rounded())
        var before: [CGImage] = []
        if pick == nil || pick!.contains(where: { $0 >= count - m }) {
            for j in 0..<m { if let i = shot(-Double(m - j) / fps + eps) { before.append(i) } }
        }
        for n in 0..<count where wanted(n) {
            guard let image = shot(Double(n) / fps + eps) else { continue }
            let j = n - (count - m)
            if j >= 0, before.indices.contains(j) {
                save(demoBlend(image, before[j], CGFloat(j + 1) / CGFloat(m + 1)), n)
            } else {
                save(image, n)
            }
        }

    case "hero-seaview":
        // The whole room with the title bar, as the still: the sea's loop (12 s, the GIF's length), the busy desks' screens
        // and LEDs, the helpers on their desk edges, the line knocking. The crabs stand (`pose(at:crabsWalk: false)`).
        // Helpers whose trips do not divide 12 s are retimed to whole trips in it when within 5% (screens go with their desk's
        // clock, which the LED shares, and are not); the LEDs
        // breathe every 3 s and the knocks come every 3 s, so they close as they are.
        let store = demoStore()
        let p = demoPanel(store, CGSize(width: 1400, height: 900))
        guard let frameView = p.contentView?.superview, let top = frameView.layer, let live = zonePanelFitFind(frameView) else { return print("demo gif: no panel") }
        let whole = top.bounds.size, k = width / whole.width
        let roomRect = live.convert(live.bounds, to: nil)
        // The window's own layers (title bar, buttons) once; the room is drawn over them each frame.
        var chrome: CGImage?
        if let ctx = CGContext(data: nil, width: Int((whole.width * k).rounded()), height: Int((whole.height * k).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                               space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.scaleBy(x: k, y: k)
            ctx.setFillColor(OfficeCanvas.rgb(0x1B1830))
            ctx.fill(CGRect(origin: .zero, size: whole))
            top.render(in: ctx)
            chrome = ctx.makeImage()
        }
        p.orderOut(nil)
        p.contentView = nil
        let view = room(store)
        view.frame = CGRect(origin: .zero, size: roomRect.size)
        view.update(store)
        print("demo gif: window \(whole), room \(roomRect), scale \(k)")
        var local: [String: Double] = [:], helpers: [String: Double] = [:]
        var retimed: [String] = []
        for l in view.demoLoops(store) {
            guard let s = store.sessions.first(where: { $0.name == l.name }) else { continue }
            var line = "demo gif: loops \(s.id):"
            if let c = l.code {
                let n = max(1, (seconds / c).rounded()), f = n * c / seconds
                line += " code \(String(format: "%.3f", c)) s (\(Int(n)) in \(seconds) s, x\(String(format: "%.4f", f)))"
            }
            if let w = l.walk {
                let n = max(1, (seconds / w).rounded()), f = n * w / seconds
                if abs(f - 1) <= 0.05 { local[s.id] = 0; helpers[s.id] = f; if abs(f - 1) > 1e-6 { retimed.append("\(s.id) helpers \(String(format: "%.3f", w)) s -> \(String(format: "%.3f", seconds / n)) s") } }
                line += " walk \(String(format: "%.3f", w)) s (\(Int(n)) in \(seconds) s, x\(String(format: "%.4f", f)))"
            }
            print(line)
        }
        for r in retimed { print("demo gif: retimed \(r)") }
        let line = store.sessions.filter { $0.status == "waiting" }.map(\.id)
        func lean(_ id: String, _ degrees: Double) {
            guard let sprite = view.spriteLayer(of: id) else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sprite.transform = CATransform3DIdentity
            if degrees != 0 {
                let pivot = WaitingNudge.feetPivot(of: sprite), flipped = WaitingNudge.flipped(sprite)
                var tr = CATransform3DMakeTranslation(-pivot.x, -pivot.y, 0)
                tr = CATransform3DConcat(tr, CATransform3DMakeRotation(CGFloat(degrees * .pi / 180) * (flipped ? 1 : -1), 0, 0, 1))
                sprite.transform = CATransform3DConcat(tr, CATransform3DMakeTranslation(pivot.x, pivot.y, 0))
            }
            CATransaction.commit()
        }
        func shot(_ t: Double) -> CGImage? {
            view.demoTick(t, store: store, local: local.mapValues { _ in t }, helpers: helpers.mapValues { t * $0 })
            view.outdoor.pose(at: t, crabsWalk: false)
            for id in line { lean(id, demoLean((t + WaitingNudge.phase(of: id)).truncatingRemainder(dividingBy: WaitingNudge.period))) }
            guard let picture = view.image(pixelScale: k), let chrome,
                  let ctx = CGContext(data: nil, width: chrome.width, height: chrome.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.draw(chrome, in: CGRect(x: 0, y: 0, width: chrome.width, height: chrome.height))
            ctx.scaleBy(x: k, y: k)
            ctx.draw(picture, in: roomRect)
            ZoneOutdoorArt.demoForget()
            return ctx.makeImage()
        }
        for n in 0..<count where wanted(n) { save(shot(Double(n) / fps + eps), n) }
        // `--seam`: the frame one loop on from the first, to hold against it.
        if args.contains("--seam"), let image = shot(seconds + eps), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/seam.png"))
        }

    case "office":
        // The office as the panel plays it, live (its own Core Animation: pose loops, the helpers, the knocks), caught frame
        // by frame from the presentation tree. eval-suite (busy at its desk) finishes: the store marks it celebrating for
        // 1.8 s and the room looks again (`cast`): it jumps where it stands, then walks to the news sofa; at the next tick
        // (2 s on) the celebration is over and the room looks once more. Each frame is taken at its moment: the room's
        // clock is set to it while the picture is made (`timeOffset`, the lag of the capture taken back), so slow captures
        // do not stretch anything. It cannot walk back: the seam is a crossfade into the half second before the start (none
        // with `--cut`).
        OfficeTheme.shown = OfficeTheme.studio
        defer { OfficeTheme.shown = OfficeTheme.zone }
        let store = demoStore()
        store.focused = nil
        let key = DemoMode.value("--walker", in: args) ?? "ai-eval"
        let id = sid(store, key)
        guard let i = store.sessions.firstIndex(where: { $0.id == id }) else { return print("demo gif: no \(key)") }
        let osize = CGSize(width: 1194, height: 764)
        let view = OfficeTestView(frame: CGRect(origin: .zero, size: osize))
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: osize.width, height: osize.height), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        view.update(store)
        CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
        guard let root = view.layer else { return }
        let b = boxArg.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } ?? CGRect(origin: .zero, size: osize)
        let box = b, k = width / box.width
        let hold = Double(DemoMode.value("--hold", in: args) ?? "") ?? 1.0
        print("demo gif: \(store.sessions[i].id) finishes at \(hold) s; box \(box), scale \(k)")
        let m = cut ? 0 : Int((0.5 * fps).rounded())
        var times: [(t: Double, slot: Int)] = (0..<m).map { j in (-Double(m - j) / fps, -(m - j)) }
        for n in 0..<count { times.append((Double(n) / fps, n)) }
        var shots: [Int: CGImage] = [:]
        // The frames before it finishes are caught ahead of their moments (nothing happens in the room till then but its
        // loops), so it finishes on time; after that each waits for its moment.
        var T0 = CACurrentMediaTime() + 0.5 + Double(times.filter { $0.t < hold }.count) * 0.12 - times[0].t
        var changed = false, over = false
        var worst = 0.0
        func wait(_ until: CFTimeInterval) {
            let left = until - CACurrentMediaTime()
            if left > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: left)) }
        }
        for (t, slot) in times {
            if !changed && t >= hold {
                wait(T0 + hold)
                let late = CACurrentMediaTime() - (T0 + hold)
                if late > 0.01 { print("demo gif: finished \(String(format: "%.3f", late)) s late (the room's loops jump by that there)"); T0 += late }
                let w = store.sessions[i]
                let line = w.summaryLine ?? .said(w.summary, .reply)
                store.sessions[i] = Session(id: w.id, pid: w.pid, project: w.project, name: w.name, status: "idle", since: Date(), summary: line.rendered,
                                            waitingFor: "", registryName: w.registryName, cwd: w.cwd, kind: w.kind, tool: "", origin: "user", model: w.model,
                                            summaryLine: line)
                store.agents[id] = nil
                store.agentCounts[id] = nil
                store.celebrating[id] = Date().addingTimeInterval(1.8)
                view.update(store)
                CATransaction.flush()
                changed = true
                print("demo gif: unread \(store.isUnread(store.sessions[i])), pose \(store.pose(of: store.sessions[i], now: Date()))")
            }
            if changed && !over && t >= hold + 2 {
                wait(T0 + hold + 2)
                let late = CACurrentMediaTime() - (T0 + hold + 2)
                if late > 0.01 { print("demo gif: the tick after it came \(String(format: "%.3f", late)) s late") }
                store.celebrating[id] = nil
                view.update(store)
                CATransaction.flush()
                over = true
            }
            let target = T0 + t
            if changed { wait(target) }
            let lag = CACurrentMediaTime() - target
            if changed { worst = max(worst, lag) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.timeOffset = target - CACurrentMediaTime()
            CATransaction.commit()
            CATransaction.flush()
            // Just the box, as `OfficeView.image(presentation: true)` draws the whole view.
            if let c = CGContext(data: nil, width: Int((box.width * k).rounded()), height: Int((box.height * k).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                c.scaleBy(x: k, y: k)
                if root.isGeometryFlipped {
                    c.translateBy(x: 0, y: box.height)
                    c.scaleBy(x: 1, y: -1)
                    c.translateBy(x: -box.minX, y: -box.minY)
                } else {
                    c.translateBy(x: -box.minX, y: -(osize.height - box.maxY))
                }
                (root.presentation() ?? root).render(in: c)
                shots[slot] = c.makeImage()
            }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            root.timeOffset = 0
            CATransaction.commit()
            CATransaction.flush()
        }
        // One never caught after the change (SwiftUI had not drawn it in any pass) shows what the screen did then: the
        // frame before.
        for (_, slot) in times where shots[slot] == nil {
            if let earlier = (0..<slot).reversed().first(where: { shots[$0] != nil }) { shots[slot] = shots[earlier]; print("demo gif: frame \(slot) as frame \(earlier)") }
        }
        print("demo gif: worst capture lag \(String(format: "%.3f", worst)) s (taken back by the clock)")
        if let f = (view.figures[id]?.layer.animation(forKey: "walk") as? CAKeyframeAnimation) {
            print("demo gif: walk \(String(format: "%.2f", f.duration)) s, route \((f.values ?? []).compactMap { ($0 as? NSValue)?.pointValue })")
        }
        for n in 0..<count where wanted(n) {
            guard let image = shots[n] else { continue }
            let j = n - (count - m)
            if j >= 0, let before = shots[j - m] {
                save(demoBlend(image, before, CGFloat(j + 1) / CGFloat(m + 1)), n)
            } else {
                save(image, n)
            }
        }

    case "duty-room":
        // The board as the panel shows it (980 pt wide, as the still), live in a window: eval-suite's message flies to
        // rag-index (`FlightLayer`: the plane draws its dashed trail, a ring opens where it lands), then rag-index finishes:
        // celebrating for 1.8 s (over at the next tick, 2 s on), and the sessions change under the board's spring as `take`
        // changes them, its card leaving Working for "Done, with news". The board takes about 0.12 s to draw, more than a
        // frame, so from the flight on the run is played slowed `--slow` times (6) and caught frame by frame: Core
        // Animation's clock held (`speed` 0) and moved on by hand at 1/6 of the real one, and the spring the same spring
        // (response 0.5, damping 0.82) at `.speed(1/6)`; each frame is made at its own moment on that clock, so the picture
        // plays at the real speed. Then (`--back`, 5.4 s) rag-index starts a new turn: busy again as it was, with its helpers,
        // handed to the store's own tick (`Store.take`), whose spring moves the card back to Working (slowed the same way, by
        // the host's `.transaction`), so the last frame is the first and the loop closes with no crossfade.
        let fly = Double(DemoMode.value("--fly", in: args) ?? "") ?? 0.5
        let finish = Double(DemoMode.value("--finish", in: args) ?? "") ?? 2.75
        let tick = finish + 2.0
        let back = Double(DemoMode.value("--back", in: args) ?? "") ?? 5.4
        let slow = Double(DemoMode.value("--slow", in: args) ?? "") ?? 6
        let m = 0
        final class Pace { var k = 1.0 }
        let pace = Pace()
        var times: [(t: Double, slot: Int)] = (0..<m).map { j in (-Double(m - j) / fps, -(m - j)) }
        for n in 0..<count where wanted(n) || n >= count - m { times.append((Double(n) / fps, n)) }
        let boardWidth = CGFloat(Double(DemoMode.value("--board", in: args) ?? "") ?? 980)
        let zoom = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1
        var shots: [Int: CGImage] = [:]
        FlightLayer.demoStretch = slow
        defer { FlightLayer.demoStretch = 1 }
        var attempt = 0
        while shots.count < times.count && attempt < 3 {
            attempt += 1
            shots = [:]
            let store = demoStore()
            store.focused = nil
            store.scanLinksNow()
            let from = sid(store, DemoMode.value("--from", in: args) ?? "ai-eval"), to = sid(store, DemoMode.value("--to", in: args) ?? "ai-rag")
            guard let i = store.sessions.firstIndex(where: { $0.id == to }) else { return print("demo gif: no card") }
            let working = (session: store.sessions[i], agents: store.agents[to], counts: store.agentCounts[to])
            pace.k = 1
            let host = NSHostingView(rootView: AnyView(Board(width: boardWidth).environmentObject(store).environment(\.zoom, CGFloat(zoom))
                .background(night).environment(\.colorScheme, .dark)
                .transaction { t in if pace.k != 1 { t.animation = t.animation?.speed(pace.k) } }))
            host.frame.size = host.fittingSize
            let bsize = host.frame.size
            let window = NSWindow(contentRect: NSRect(x: -6000, y: -6000, width: bsize.width, height: bsize.height), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.orderFrontRegardless()
            defer {
                window.orderOut(nil)
                window.contentView = nil
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.5))
            guard let root = host.layer else { return }
            let box = boxArg.flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil } ?? CGRect(origin: .zero, size: bsize)
            let k = width / box.width
            print("demo gif: board \(bsize), flies at \(fly) s, \(store.sessions[i].id) finishes at \(finish) s; box \(box), scale \(k); \(slow)x slowed from the flight")
            // The picture's clock: the real one until the flight (its ring is set on the real clock: held there, the two
            // agree), then 1/slow of it. Before the flight frames are caught ahead of their moments with the clock set to them.
            let T0 = CACurrentMediaTime() + 0.5 + Double(times.filter { $0.t < fly }.count) * 0.15 - times[0].t
            var held: (real: CFTimeInterval, clock: CFTimeInterval)?
            // The cards' "4m" are read off the wall clock, which runs `slow` times ahead of the picture's: at each event
            // every session's moments are moved on by that lead, so the labels read as at the picture's moment.
            let base = (date: Date(), t: CACurrentMediaTime() - T0)
            var lead = 0.0
            func keepTime(_ at: Double) {
                let d = Date().timeIntervalSince(base.date) - (at - base.t) - lead
                lead += d
                store.sessions = store.sessions.map { var s = $0; s.since += d; s.bgSince = s.bgSince.map { $0 + d }; return s }
            }
            func clock() -> CFTimeInterval {
                guard let held else { return CACurrentMediaTime() }
                return held.clock + (CACurrentMediaTime() - held.real) / slow
            }
            func setClock(_ v: CFTimeInterval) {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if held == nil { root.timeOffset = v - CACurrentMediaTime() } else { root.timeOffset = v }
                CATransaction.commit()
            }
            // Runs the loop until the picture's clock reaches `v`, keeping the held layers' clock with it.
            func wait(_ v: CFTimeInterval) {
                while clock() < v {
                    if held != nil { setClock(clock()) }
                    let left = (v - clock()) * (held == nil ? 1 : slow)
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: min(0.004, max(0.0005, left))))
                }
                if held != nil { setClock(clock()) }
            }
            func happen(_ what: Int, at: Double) {
                keepTime(at)
                switch what {
                case 0:
                    store.demoFlight(from: from, to: to)
                case 1:
                    var fresh = store.sessions
                    let w = fresh[i]
                    let line = w.summaryLine ?? .said(w.summary, .reply)
                    fresh[i] = Session(id: w.id, pid: w.pid, project: w.project, name: w.name, status: "idle", since: Date(), summary: line.rendered,
                                       waitingFor: "", registryName: w.registryName, cwd: w.cwd, kind: w.kind, tool: "", origin: "user", model: w.model,
                                       summaryLine: line)
                    store.agents[to] = nil
                    store.agentCounts[to] = nil
                    store.celebrating[to] = Date().addingTimeInterval(1.8 * slow)
                    withAnimation(.spring(response: 0.5, dampingFraction: 0.82).speed(1 / slow)) { store.sessions = fresh }
                case 3:
                    var fresh = store.sessions
                    fresh[i] = working.session
                    fresh[i].since += lead
                    fresh[i].bgSince = fresh[i].bgSince.map { $0 + lead }
                    store.agents[to] = working.agents
                    store.agentCounts[to] = working.counts
                    pace.k = 1 / slow
                    store.take(fresh, at: Date())
                default:
                    store.celebrating[to] = nil
                }
                // SwiftUI takes the change up as the run loop turns: a picture made before that would lose it.
                host.needsLayout = true
                host.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            }
            func shoot(_ v: CFTimeInterval) -> CGImage? {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                root.timeOffset = held == nil ? v - CACurrentMediaTime() : v
                CATransaction.commit()
                CATransaction.flush()
                var image: CGImage?
                if let c = CGContext(data: nil, width: Int((box.width * k).rounded()), height: Int((box.height * k).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    c.scaleBy(x: k, y: k)
                    if root.isGeometryFlipped {
                        c.translateBy(x: 0, y: box.height)
                        c.scaleBy(x: 1, y: -1)
                        c.translateBy(x: -box.minX, y: -box.minY)
                    } else {
                        c.translateBy(x: -box.minX, y: -(bsize.height - box.maxY))
                    }
                    (root.presentation() ?? root).render(in: c)
                    image = c.makeImage()
                }
                setClock(clock())
                CATransaction.flush()
                return image
            }
            var events: [(at: Double, what: Int)] = [(fly, 0), (finish, 1), (tick, 2), (back, 3)]
            var worst = 0.0
            var before: [UInt8]?
            var stale = false
            for (t, slot) in times {
                while let e = events.first, e.at <= t {
                    events.removeFirst()
                    wait(T0 + e.at)
                    let late = clock() - (T0 + e.at)
                    if late > 0.01 { print("demo gif: event \(e.what) \(String(format: "%.3f", late)) s late on the picture's clock") }
                    if e.what == 0 {
                        // From the flight on the clock is held and moved by hand, slowed (its pieces stay as much longer).
                        let now = CACurrentMediaTime()
                        held = (now, root.convertTime(now, from: nil))
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        root.speed = 0
                        root.timeOffset = held!.clock
                        CATransaction.commit()
                        CATransaction.flush()
                    }
                    happen(e.what, at: e.at)
                }
                let target = T0 + t
                if held != nil { wait(target) }
                worst = max(worst, clock() - target)
                shots[slot] = shoot(target)
                let top = demoStrip(shots[slot], rows: 28)
                if t < finish { before = top } else if t >= finish + 0.3, t < back, let before, top == before, !stale {
                    stale = true
                    print("demo gif: the board had not drawn the change at \(String(format: "%.3f", t)) s: again")
                }
            }
            print("demo gif: worst lag \(String(format: "%.3f", worst)) s on the picture's clock")
            if stale { shots = [:] }
        }
        for n in 0..<count where wanted(n) {
            guard let image = shots[n] else { continue }
            let j = n - (count - m)
            if j >= 0, let before = shots[j - m] {
                save(demoBlend(image, before, CGFloat(j + 1) / CGFloat(m + 1)), n)
            } else {
                save(image, n)
            }
        }
    case "seaview-spotlight":
        // The user switches sessions in Orca twice: the light (`Store.focused`: ball, spots, lasers, cone and pool) is on
        // storefront for `--hold` seconds (0.4 when not given), then on eval-suite, then on home-lab, half the rest each,
        // and the picture starts over. Each switch is a cut (the still room has no fade); the light's ball, spots and lasers
        // go round by `OfficeView.stillPhase`, one share of their loop every 8 s. The whole room, its four islands, 16:9.
        let store = demoStore()
        store.orcaInFront = true
        let order = [sid(store, "web-storefront"), sid(store, "ai-eval"), sid(store, "home-homelab")]
        store.focused = order[0]
        let view = room(store)
        defer { OfficeView.stillPhase = 0 }
        // Those at their desks (above their island's label; one in the line or on a sofa keeps its desk), and the labels.
        let seated = store.sessions.filter { s in
            guard view.demoDeskID(s.id) != nil, let foot = view.foot(of: s.id), let code = s.name.split(separator: "-").first,
                  let pill = view.signPill(String(code)) else { return false }
            return foot.y < pill.maxY
        }.map(\.id)
        let pet = (ZoneArt.scene.map { $0.petHeight * ZoneFit(scene: $0.size, view: size).scale } ?? 70)
        guard var b = demoBox(view, seated, left: 45, up: pet + 8, right: 45, down: 30) else { return }
        for code in DemoCrowd.zoneColours.keys { if let pill = view.signPill(code) { b = b.union(pill.insetBy(dx: -12, dy: -8)) } }
        let box = demoClear(b, keep: demoKeep(view, store), in: CGRect(origin: .zero, size: size)), k = width / box.width
        print("demo gif: lights \(order), box \(box), scale \(k)")
        let hold = Double(DemoMode.value("--hold", in: args) ?? "") ?? 0.4
        let second = hold + (seconds - hold) / 2
        for n in 0..<count where wanted(n) {
            let t = Double(n) / fps + eps
            store.focused = t < hold ? order[0] : t < second ? order[1] : order[2]
            OfficeView.stillPhase = t / 8
            view.demoTick(t, store: store)
            save(demoCrop(view.image(pixelScale: k), box, k: k, w: Int(width.rounded()), h: tall), n)
        }

    default:
        print("demo gif: no \(name)")
    }
}

/// `--demo-gif-frames`: numbers that are not finite and positive, or past their caps, are refused before anything is made;
/// a folder that cannot be made and a frame that cannot be written are errors.
@MainActor func demoGifArgTests() {
    func refused(_ flag: String, _ value: String) -> Bool { demoGifArgs(["x", "--demo-gif-frames", "/tmp/x", flag, value]).error != nil }
    let plain = demoGifArgs(["x", "--demo-gif-frames", "/tmp/x"])
    check("demo gif args: none given: 15 fps, 6 s, 800 px, no error", plain.error == nil && plain.args?.fps == 15 && plain.args?.seconds == 6 && plain.args?.width == 800)
    let given = demoGifArgs(["x", "--fps", "12", "--seconds", "7.5", "--width", "640", "--slow", "4"])
    check("demo gif args: sane numbers are taken", given.error == nil && given.args?.fps == 12 && given.args?.seconds == 7.5 && given.args?.width == 640)
    check("demo gif args: --fps -1, 0, nan, inf, 1000 and words are refused",
        refused("--fps", "-1") && refused("--fps", "0") && refused("--fps", "nan") && refused("--fps", "inf") && refused("--fps", "1000") && refused("--fps", "fast"))
    check("demo gif args: --seconds -1, 0, nan and 100000 are refused",
        refused("--seconds", "-1") && refused("--seconds", "0") && refused("--seconds", "nan") && refused("--seconds", "100000"))
    check("demo gif args: --width 0, -800, inf and 100000 are refused",
        refused("--width", "0") && refused("--width", "-800") && refused("--width", "inf") && refused("--width", "100000"))
    check("demo gif args: --slow -1, 0 and nan are refused; --hold -1 and nan too",
        refused("--slow", "-1") && refused("--slow", "0") && refused("--slow", "nan") && refused("--hold", "-1") && refused("--hold", "nan"))
    check("demo gif args: a loop of no frames (0.01 s at 15 fps) is refused",
        demoGifArgs(["x", "--seconds", "0.01", "--fps", "15"]).error != nil)

    let fm = FileManager.default
    let scratch = NSTemporaryDirectory() + "demo-gif-args-\(getpid())"
    try? fm.removeItem(atPath: scratch)
    try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: scratch) }
    let file = scratch + "/a-file"
    fm.createFile(atPath: file, contents: Data("x".utf8))
    check("demo gif: a frames folder under a regular file is an error", demoGifPrepare(file + "/frames") != nil)
    check("demo gif: a frames folder that can be made is no error", demoGifPrepare(scratch + "/frames") == nil)
    let image = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
    if let image {
        check("demo gif: a frame written into a folder that is not there is an error", demoGifWrite(image, to: scratch + "/none/f000.png") != nil)
        check("demo gif: a frame written into the folder is no error, and is there",
            demoGifWrite(image, to: scratch + "/frames/f000.png") == nil && fm.fileExists(atPath: scratch + "/frames/f000.png"))
    } else {
        check("demo gif: the setup: a 4 x 4 picture", false)
    }
}
