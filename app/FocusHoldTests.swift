import AppKit
import QuartzCore

// Focus hold: a click on a pet lights it at once (`Store.expectFocus`), ahead of the look at Orca, which can bring the light up to
// 2 s later; for 1.5 s a look that names someone else is not taken, a look that agrees ends the hold. `focusHoldTests()` is in
// `--focus-only`, `--focus-hold-only` and the full run.

@MainActor func focusHoldTests() {
    focusHoldStoreTests()
    focusHoldZoneClickTests()
    focusHoldOfficeClickTests()
}

/// The store's side, everything it asks of the system replaced, as `officeFocusTests` does it: Orca in front showing
/// Alpha's tab ("claude", "claude", plus a Chinese-titled tab → f-a) or Bravo's (a Chinese-titled tab → f-b).
@MainActor func focusHoldStoreTests() {
    let t0 = Date()
    let store = Store()
    store.readOnly = true
    func person(_ id: String, _ pid: Int32, _ name: String, kind: String = "") -> Session {
        var s = Session(id: id, pid: pid, project: "项目", name: name, status: "idle", since: t0 - 600, summary: "")
        if !kind.isEmpty { s.kind = kind }
        return s
    }
    let a = person("f-a", 101, "Alpha"), b = person("f-b", 102, "Bravo"), c = person("f-c", 103, "Charlie"), d = person("f-d", 104, "Delta")
    let app = person("f-app", 105, "应用", kind: "codexApp")
    store.sessions = [a, b, c, d, app]
    func tabs(_ titles: String...) -> [OfficeFocus.BarTab] { titles.map { OfficeFocus.BarTab(title: $0, depth: 1) } }
    let showsA = OfficeFocus.Bar.tabs(tabs("claude", "claude", "风筝脚本")), showsB = OfficeFocus.Bar.tabs(tabs("彗星表巡游"))
    var front: (bundle: String, pid: pid_t)? = (OfficeFocus.orca, 42)
    var allowed = true, running = true, bar = showsA, reads = 0
    var asked: [Double] = [], work: [@MainActor () -> Void] = []
    let element = AXUIElementCreateApplication(getpid())
    let focus = store.focus
    focus.queue = nil
    focus.frontmost = { front }
    focus.trusted = { allowed }
    focus.running = { running }
    focus.enhance = { _, _ in "made up" }
    focus.watch = { _, _ in (nil, "made up") }
    focus.findBar = { _ in ([element], 600) }
    focus.readBar = { _ in
        reads += 1
        return bar
    }
    focus.list = { officeFocusListing() }
    // f-a in h2, f-b under a stale handle found by its pane; f-c known to run outside Orca; f-d not yet looked up.
    focus.tab = { pid in pid == 101 ? ("h2", "t2:l2") : pid == 102 ? ("h-old", "t4:l4b") : nil }
    focus.pane = { pid in pid == 101 ? "t2:l2" : pid == 102 ? "t4:l4b" : pid == 103 ? "" : nil }
    focus.note = { _ in }
    store.later = { seconds, job in
        asked.append(seconds)
        work.append(job)
    }
    let switchKey = "officeSpotlight", switchWas = UserDefaults.standard.object(forKey: switchKey)
    UserDefaults.standard.removeObject(forKey: switchKey)  // on, as it is by default
    defer {
        if let switchWas { UserDefaults.standard.set(switchWas, forKey: switchKey) } else { UserDefaults.standard.removeObject(forKey: switchKey) }
    }

    store.readFocus(at: t0)
    check("focus hold: the setup: Orca in front showing Alpha's tab lights Alpha, nothing held", store.focused == "f-a" && store.expected == nil)

    // The click: lit at once, before any look at Orca.
    let readsBefore = reads
    let took = store.expectFocus(b, at: t0 + 1)
    check(
        "focus hold: a click on Bravo lights Bravo at once, no look at Orca needed; a confirming look is asked for in 0.25 s and once more as the 1.5 s hold runs out",
        took && store.focused == "f-b" && reads == readsBefore && store.expected?.id == "f-b"
            && abs((store.expected?.until.timeIntervalSince(t0) ?? 0) - 2.5) < 0.001 && asked == [0.25, 1.6] && store.orcaInFront)
    work.first?()
    check("focus hold: ...the confirming look asked for is the store's own look at Orca", reads == readsBefore + 1)

    // In the hold Orca still shows Alpha's tab (not switched yet, or a look begun before the click answering late).
    store.readFocus(at: t0 + 1.25)
    let heldOld = store.focused == "f-b"
    store.take(.noSession, at: t0 + 1.3)
    let heldNone = store.focused == "f-b"
    store.take(.nothing, at: t0 + 1.35)
    check(
        "focus hold: in the hold a look that names Alpha (Orca not switched yet), or a terminal no session runs in, is not taken: the light stays on Bravo",
        heldOld && heldNone && store.focused == "f-b" && store.expected?.id == "f-b")
    // A look begun inside the hold that answers after it is still held to the time it began.
    store.take(.session("f-a"), at: t0 + 2.4)
    check("focus hold: ...held to the time the look began, however late it answers", store.focused == "f-b")

    // Orca switches: the look agrees, the hold ends early, and from then on every look is taken as before.
    bar = showsB
    store.readFocus(at: t0 + 1.5)
    let confirmed = store.focused == "f-b" && store.expected == nil
    bar = showsA
    store.readFocus(at: t0 + 1.7)
    check(
        "focus hold: a look that names Bravo confirms it and ends the hold early; a look after that (he went back to Alpha in Orca) is taken at once",
        confirmed && store.focused == "f-a")

    // No look ever agrees (the jump went nowhere): once the hold is over the light goes back to what Orca shows.
    store.expectFocus(b, at: t0 + 10)
    store.readFocus(at: t0 + 11)
    let stillB = store.focused == "f-b"
    store.readFocus(at: t0 + 11.6)
    check(
        "focus hold: never confirmed, the light stays on Bravo through the hold and goes back to Alpha on the first look after it (1.5 s)",
        stillB && store.focused == "f-a" && store.expected == nil)

    // A second click inside the hold moves it.
    store.expectFocus(b, at: t0 + 20)
    store.expectFocus(d, at: t0 + 20.5)
    let movedTo = store.focused
    store.take(.session("f-b"), at: t0 + 20.8)
    let notBack = store.focused == "f-d"
    store.take(.session("f-d"), at: t0 + 21)
    check(
        "focus hold: a second click inside the hold moves the light and the hold to the new one; a look naming the first is not taken; one naming it confirms",
        movedTo == "f-d" && notBack && store.focused == "f-d" && store.expected == nil)

    // Orca still behind while it comes forward: not dimmed in the hold; behind after it, dimmed as before.
    bar = showsA
    store.readFocus(at: t0 + 30)
    front = ("com.apple.finder", 7)
    store.readFocus(at: t0 + 31)
    let dimmedBefore = !store.orcaInFront
    store.expectFocus(b, at: t0 + 32)
    let fullAtClick = store.orcaInFront
    store.readFocus(at: t0 + 32.3)
    let fullInHold = store.orcaInFront && store.focused == "f-b"
    store.readFocus(at: t0 + 34)
    check(
        "focus hold: from another app, the click's light is at full strength (Orca is coming forward); a look in the hold finding Orca still behind does not dim it; after the hold it dims as before",
        dimmedBefore && fullAtClick && fullInHold && !store.orcaInFront && store.focused == "f-b")
    front = (OfficeFocus.orca, 42)
    store.readFocus(at: t0 + 35)

    // Where there was no light to follow the jump, nothing changes: no light, no hold, no look asked for.
    func untouched(_ s: Session, _ what: String, at t: Double) {
        let was = store.focused, wasFront = store.orcaInFront, count = asked.count
        let took = store.expectFocus(s, at: t0 + t)
        check("focus hold: unchanged where the light would not follow: \(what)", !took && store.focused == was && store.orcaInFront == wasFront && store.expected == nil && asked.count == count)
    }
    UserDefaults.standard.set(false, forKey: switchKey)
    untouched(b, "the light switched off (menu: Spotlight)", at: 40)
    UserDefaults.standard.removeObject(forKey: switchKey)
    allowed = false
    untouched(b, "no Accessibility permission (nothing is ever lit)", at: 41)
    store.readFocus(at: t0 + 41.5)
    check("focus hold: ...and without the permission a look still puts the light out, as before", store.focused == nil)
    allowed = true
    store.readFocus(at: t0 + 42)
    untouched(app, "a Codex app session (its jump leaves Orca)", at: 43)
    untouched(c, "a session known to run outside Orca", at: 44)
    running = false
    untouched(b, "Orca not running", at: 45)
    running = true
    // The permission withdrawn in a hold: the light goes out all the same.
    store.expectFocus(b, at: t0 + 50)
    allowed = false
    store.readFocus(at: t0 + 50.3)
    check("focus hold: the permission withdrawn inside a hold: the light goes out and the hold with it", store.focused == nil && store.expected == nil)
    allowed = true
}

/// The sea room click: the pet lit, its fade already begun, before any update of the view or look at Orca.
@MainActor func focusHoldZoneClickTests() {
    guard ZoneArt.scene != nil else { return check("focus hold zone: the art", false) }
    let restore = seaSweepSetup(NSTemporaryDirectory() + "focus-zone-\(getpid())")
    OfficePets.shared.synchronous = true
    defer {
        OfficePets.shared.synchronous = false
        restore()
    }
    let now = Date()
    func s(_ name: String) -> Session {
        var made = Session(id: "focus-" + name, pid: 1, project: "p", name: name, status: "busy", since: now - 30, summary: "在做事")
        made.cwd = "/tmp"
        return made
    }
    let size = CGSize(width: 1180, height: 790)
    let store = Store()
    store.readOnly = true
    store.sessions = [s("Web-L"), s("Web-a"), s("Ops-x")]
    store.seen = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, now.timeIntervalSince1970) })
    store.assignPets()
    store.focus.trusted = { true }
    store.focus.running = { true }
    store.focus.pane = { _ in nil }
    store.focus.frontmost = { (OfficeFocus.orca, 42) }
    store.later = { _, _ in }
    store.focused = "focus-Web-L"
    NSApplication.shared.setActivationPolicy(.accessory)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    var clicked: [String] = []
    view.onClick = { clicked.append($0.id) }
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    view.update(store)
    let deadline = Date().addingTimeInterval(0.6)
    while view.beam(of: "focus-Web-L")?.animation(forKey: "fade") != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let target = "focus-Web-a"
    guard let plate = view.plateFrame(of: target) else { return check("focus hold zone: the setup: Web-a's plate to click", false) }
    let leadBefore = view.lit("focus-Web-L")
    view.press(at: CGPoint(x: plate.midX, y: plate.midY))
    let wasClick = view.release(at: CGPoint(x: plate.midX, y: plate.midY))
    // No `update` here: what the click itself did.
    let fade = view.beam(of: target)?.animation(forKey: "fade") as? CABasicAnimation
    check(
        "focus hold zone: a click on a pet lights it at once: in the click itself its light is set on and its 0.3 s fade-in has begun, the one lit before fading out; no update of the view, no look at Orca needed",
        wasClick && clicked == [target] && store.focused == target && leadBefore == 1 && view.lit(target) == 1
            && fade?.duration == 0.3 && (fade?.toValue as? Float) == 1 && view.lit("focus-Web-L") == 0)
    view.update(store)
    check("focus hold zone: ...the next update keeps it so (the fade not started again)", view.lit(target) == 1 && view.lit("focus-Web-L") == 0)
}

/// The office's click (an extension's scene and office share `OfficeView`): the same.
@MainActor func focusHoldOfficeClickTests() {
    let size = CGSize(width: 1180, height: 790), fit = OfficeFit(size)
    let store = officeStore()
    _ = officeDealCutPets(store)
    store.focus.trusted = { true }
    store.focus.running = { true }
    store.focus.pane = { _ in nil }
    store.focus.frontmost = { (OfficeFocus.orca, 42) }
    store.later = { _, _ in }
    store.focused = "o-busy"
    NSApplication.shared.setActivationPolicy(.accessory)
    let live = OfficeTestView(frame: CGRect(origin: .zero, size: size))
    live.note = { _ in }
    var clicked: [String] = []
    live.onClick = { clicked.append($0.id) }
    let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    live.update(store)
    let deadline = Date().addingTimeInterval(0.6)
    while officePart(live, "o-busy", "beam")?.animation(forKey: "fade") != nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
    let target = "o-seen"
    guard let pet = layout.pets.first(where: { $0.id == target }) else { return check("focus hold office: the setup: o-seen in the room", false) }
    let r = fit.rect(pet.frame), spot = live.convert(CGPoint(x: r.midX, y: r.midY), to: nil)
    let before = officePart(live, "o-busy", "beam")?.opacity
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        guard let event = NSEvent.mouseEvent(
            with: type, location: spot, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        else { continue }
        if type == .leftMouseDown { live.mouseDown(with: event) } else { live.mouseUp(with: event) }
    }
    let beam = officePart(live, target, "beam"), fade = beam?.animation(forKey: "fade") as? CABasicAnimation
    check(
        "focus hold office: a click on a pet lights it at once: in the click itself its light is on and its 0.3 s fade-in has begun, the one lit before fading out",
        clicked == [target] && store.focused == target && before == 1 && beam?.opacity == 1 && fade?.duration == 0.3
            && officePart(live, "o-busy", "beam")?.opacity ?? 0 == 0)
}
