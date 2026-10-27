// The ones waiting for you stand still and knock. Checks (`--nudge-only`), stills of the three screens on
// made-up sessions (`--nudge-stills <dir>`) and the 5-second burst that shows the stillness between knocks
// (`--nudge-burst <dir>`). Nothing here ships in the app.

import AppKit
import SwiftUI

// ───────── Helpers ─────────

@MainActor func nudgeWindow(_ view: NSView) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: view.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    return window
}

@MainActor func nudgeSpin(_ seconds: Double) {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
}

@MainActor func nudgeFind<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    var found: [T] = []
    if let me = view as? T { found.append(me) }
    for sub in view.subviews { found += nudgeFind(type, in: sub) }
    return found
}

func nudgeRed(_ c: CGColor?) -> CGFloat { c.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB)?.redComponent } ?? -1 }

/// A transform's lean in degrees as a page writes it (clockwise plus), for a layer whose coordinates run `flipped` or not.
func nudgeDegrees(_ t: CATransform3D, flipped: Bool) -> Double {
    atan2(Double(t.m12), Double(t.m11)) * 180 / .pi * (flipped ? 1 : -1)
}

func nudgeApply(_ t: CATransform3D, _ p: CGPoint) -> CGPoint {
    CGPoint(x: t.m11 * p.x + t.m21 * p.y + t.m41, y: t.m12 * p.x + t.m22 * p.y + t.m42)
}

func nudgeGroup(_ layer: CALayer?, _ key: String = WaitingNudge.tiltKey) -> CAAnimationGroup? { layer?.animation(forKey: key) as? CAAnimationGroup }

func nudgeSame(_ a: Any?, _ b: CGImage?) -> Bool {
    guard let a, let b, CFGetTypeID(a as CFTypeRef) == CGImage.typeID else { return false }
    let image = a as! CGImage
    if image === b { return true }
    guard image.width == b.width, image.height == b.height else { return false }
    return Pixels(image).data == Pixels(b).data
}

/// Made-up sessions: so many waiting (w0…), a few of the others.
@MainActor func nudgeStore(waiting: Int) -> Store { boardSweepStore(boardSweepCrowd(waiting, 2, 3, 2, 1)) }

@MainActor func nudgeOffice(_ store: Store) -> (view: OfficeTestView, window: NSWindow) {
    let view = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    let window = nudgeWindow(view)
    view.update(store)
    CATransaction.flush()
    nudgeSpin(0.15)
    return (view, window)
}

// ───────── Checks ─────────

@MainActor func nudgeTests() {
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    NSApplication.shared.setActivationPolicy(.accessory)
    let savedOverride = WaitingNudge.override, savedCalm = WaitingNudge.calm
    let defaults = UserDefaults.standard
    defer {
        WaitingNudge.override = savedOverride
        WaitingNudge.calm = savedCalm
        defaults.removeObject(forKey: "waitingNudge")
    }
    WaitingNudge.override = true
    WaitingNudge.calm = { false }

    // ── The numbers ──
    check("nudge: one knock every 3 s, 0.45 s long; the lean 0, -6, +5, -3, +1.5, 0 degrees at 0, 18, 38, 58, 78 and 100 percent of it",
        WaitingNudge.period == 3 && WaitingNudge.knock == 0.45 && WaitingNudge.degrees == [0, -6, 5, -3, 1.5, 0]
            && WaitingNudge.shares == [0, 0.18, 0.38, 0.58, 0.78, 1])
    var c1 = [Float](repeating: 0, count: 2), c2 = [Float](repeating: 0, count: 2)
    WaitingNudge.easing.getControlPoint(at: 1, values: &c1)
    WaitingNudge.easing.getControlPoint(at: 2, values: &c2)
    check("nudge: eased by cubic-bezier(.36, .07, .19, .97)", c1 == [0.36, 0.07] && c2 == [0.19, 0.97])

    WaitingNudge.override = nil
    defaults.removeObject(forKey: "waitingNudge")
    let byDefault = WaitingNudge.enabled
    defaults.set(false, forKey: "waitingNudge")
    let asBool = WaitingNudge.enabled
    defaults.set("NO", forKey: "waitingNudge")
    let asWord = WaitingNudge.enabled
    defaults.set(true, forKey: "waitingNudge")
    let asYes = WaitingNudge.enabled
    defaults.removeObject(forKey: "waitingNudge")
    WaitingNudge.override = true
    check("nudge: the default `waitingNudge` is on when it is not there; NO (as a boolean or as the word) turns it off",
        byDefault && !asBool && !asWord && asYes)

    let poses: [(String, Pose)] = [("working", .working), ("celebrating", .celebrating), ("waving", .waving), ("handUp", .handUp),
                                   ("standing", .standing), ("sleeping", .sleeping)]
    func tuple(_ p: Pose) -> String { "\(p.sheet.row) \(p.sheet.frames) \(p.sheet.ms) \(p.sheet.still)" }
    WaitingNudge.override = true
    let onWaiting = Pose.waiting.sheet, onOthers = poses.map { tuple($0.1) }
    WaitingNudge.override = false
    let offWaiting = Pose.waiting.sheet, offOthers = poses.map { tuple($0.1) }
    WaitingNudge.override = true
    check("nudge: waiting is row 6, one frame, the first one (column 0), no loop; switched off it is the old row-6 loop (6 frames, 150 ms, still column 2)",
        onWaiting.row == 6 && onWaiting.frames == 1 && onWaiting.ms == 0 && onWaiting.still == 0
            && offWaiting.row == 6 && offWaiting.frames == 6 && offWaiting.ms == 150 && offWaiting.still == 2)
    check("nudge: working (row 7), celebrating, waving, hand up, standing and sleeping are the same with the switch on or off",
        onOthers == offOthers && tuple(.working) == "7 6 120.0 1" && tuple(.celebrating) == "4 5 140.0 2" && tuple(.waving) == "3 4 160.0 2"
            && tuple(.standing) == "0 1 0.0 0" && tuple(.sleeping) == "0 1 0.0 1")

    // ── The animations ──
    let group = WaitingNudge.tilt(pivot: CGPoint(x: 0, y: 10), flipped: false)
    let lean = group.animations?.first as? CAKeyframeAnimation
    check("nudge: the knock is one group of three seconds, for ever, round a 0.45 s keyframe lean (no timer, no per-frame drawing)",
        group.duration == 3 && group.repeatCount == .infinity && group.animations?.count == 1 && lean?.keyPath == "transform"
            && lean?.duration == 0.45 && lean?.values?.count == 6)
    check("nudge: its keys are at 0, 18, 38, 58, 78, 100 percent and each stretch has the easing; it adds to what a slide or walk does",
        lean?.keyTimes?.map(\.doubleValue) == [0, 0.18, 0.38, 0.58, 0.78, 1] && lean?.timingFunctions?.count == 5
            && (lean?.timingFunctions ?? []).allSatisfy { f in
                var a = [Float](repeating: 0, count: 2), b = [Float](repeating: 0, count: 2)
                f.getControlPoint(at: 1, values: &a); f.getControlPoint(at: 2, values: &b)
                return a == [0.36, 0.07] && b == [0.19, 0.97]
            } && lean?.isAdditive == true)
    func angles(_ flipped: Bool) -> [Double] {
        let g = WaitingNudge.tilt(pivot: CGPoint(x: 0, y: 10), flipped: flipped).animations?.first as? CAKeyframeAnimation
        return (g?.values ?? []).map { nudgeDegrees(($0 as! NSValue).caTransform3DValue, flipped: flipped) }
    }
    check("nudge: the keys lean 0, -6, +5, -3, +1.5, 0 degrees, clockwise plus, on layers whose y runs up and on those whose y runs down",
        zip(angles(false), WaitingNudge.degrees).allSatisfy { abs($0 - $1) < 0.001 } && zip(angles(true), WaitingNudge.degrees).allSatisfy { abs($0 - $1) < 0.001 })
    let pivot = CGPoint(x: 3, y: -12)
    let keys = (WaitingNudge.tilt(pivot: pivot, flipped: false).animations?.first as? CAKeyframeAnimation)?.values ?? []
    let fixed = keys.allSatisfy { v in
        let moved = nudgeApply((v as! NSValue).caTransform3DValue, pivot)
        return abs(moved.x - pivot.x) < 0.001 && abs(moved.y - pivot.y) < 0.001
    }
    let head = nudgeApply((keys[1] as! NSValue).caTransform3DValue, CGPoint(x: 3, y: 38))
    check("nudge: it turns about the pivot (the feet): the pivot stays put at every key, a point 50 above it swings sideways",
        fixed && abs(head.x - 3) > 4)

    // On a bare layer, played from 0 and scrubbed: a lean in the first 0.45 s of every 3, nothing in between.
    let bareView = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
    bareView.wantsLayer = true
    let bareWindow = nudgeWindow(bareView)
    defer { bareWindow.orderOut(nil) }
    let bare = CALayer()
    bare.bounds = CGRect(x: 0, y: 0, width: 50, height: 50)
    bareView.layer?.addSublayer(bare)
    bare.speed = 0  // the layer's own clock is the offset, and the animation starts at 0 on it
    bare.timeOffset = 0
    bare.add(WaitingNudge.tilt(pivot: .zero, flipped: false), forKey: "nudge")
    CATransaction.flush()
    func leanAt(_ t: Double) -> Double? {
        bare.timeOffset = t
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        return bare.presentation().map { nudgeDegrees($0.transform, flipped: false) }
    }
    let during = [0.081, 0.171, 0.261, 0.351, 0.45].compactMap(leanAt)
    let between = stride(from: 0.46, to: 3.0, by: 0.2).compactMap(leanAt)
    check("nudge: scrubbed, it leans -6, +5, -3, +1.5 and is back at 0 at 0.081 … 0.45 s, then stays at exactly 0 from 0.46 s to 3 s",
        during.count == 5 && abs(during[0] + 6) < 0.05 && abs(during[1] - 5) < 0.05 && abs(during[2] + 3) < 0.05 && abs(during[3] - 1.5) < 0.05
            && abs(during[4]) < 0.001 && between.count >= 12 && between.allSatisfy { abs($0) < 0.0001 })
    check("nudge: and it comes again every 3 s (leaning -6 at 3.081 and at 6.081 s)",
        abs((leanAt(3.081) ?? 0) + 6) < 0.05 && abs((leanAt(6.081) ?? 0) + 6) < 0.05 && abs(leanAt(5.0) ?? 1) < 0.0001)
    let ids = (0..<9).map { "w\($0)" }
    let phases = ids.map(WaitingNudge.phase(of:))
    check("nudge: the knocks of those waiting together are staggered by half-second steps from their ids (the same every run), not in step",
        phases.allSatisfy { $0 >= 0 && $0 <= 2.5 && $0.truncatingRemainder(dividingBy: 0.5) == 0 } && Set(phases).count >= 4
            && phases == ids.map(WaitingNudge.phase(of:)))
    let pulse = WaitingNudge.pulse()
    let ring = WaitingNudge.ring(rect: CGRect(x: 0, y: 0, width: 40, height: 60), corner: 10, width: 2)
    let stroke = ring.strokeColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
    let coral = NSColor(call).usingColorSpace(.sRGB)
    check("nudge: Reduce Motion: no lean but a ring whose opacity goes 1 to 0.25 and back, 1 s each way (2 s a round), for ever; only opacity",
        pulse.keyPath == "opacity" && (pulse.fromValue as? NSNumber)?.floatValue == 1 && (pulse.toValue as? NSNumber)?.floatValue == 0.25
            && pulse.duration == 1 && pulse.autoreverses && pulse.repeatCount == .infinity)
    check("nudge: the ring is stroked in the board's waiting coral (0xFF6B4A, the office's `OfficeLook.call` too), not filled",
        ring.fillColor == nil && OfficeLook.call == 0xFF6B4A && stroke != nil && coral != nil
            && abs(stroke!.redComponent - coral!.redComponent) < 0.003 && abs(stroke!.greenComponent - coral!.greenComponent) < 0.003
            && abs(stroke!.blueComponent - coral!.blueComponent) < 0.003)

    // ── The board ──
    let store = nudgeStore(waiting: 9)
    let petW = store.displayPets["w2"] ?? ""
    let petB = store.displayPets["b0"] ?? ""
    let framesCut = !petW.isEmpty && Pets.shared.frame(petW, row: 6, column: 0, head: false) != nil && !petB.isEmpty
    func hosted(_ pose: Pose, head: Bool = false, pet: String, picture: Bool = false) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: PetSprite(pet: pet, pose: pose, size: 50, head: head, knockID: "w2").environment(\.still, picture))
        host.frame = CGRect(x: 0, y: 0, width: 80, height: 90)
        let window = nudgeWindow(host)
        nudgeSpin(0.3)
        return (window, host)
    }
    if framesCut {
        let (w1, wide) = hosted(.waiting, pet: petW)
        let knock = nudgeFind(SpriteLoop.LoopView.self, in: wide)
        let knockers = nudgeFind(WaitingNudge.Sprite.KnockView.self, in: wide)
        let frame0 = Pets.shared.frame(petW, row: 6, column: 0, head: false)
        check("board: a waiting card's pet is the first frame of row 6 on a layer that knocks, and plays no loop",
            knockers.count == 1 && knock.isEmpty && nudgeGroup(knockers.first?.art)?.duration == 3 && nudgeSame(knockers.first?.art.contents, frame0))
        check("board: it knocks round its feet: the pivot is near the bottom of the sprite, in whichever way its layer's y runs",
            knockers.first.map { k in
                let p = (nudgeGroup(k.art)?.animations?.first as? CAKeyframeAnimation)?.values?[1] as? NSValue
                let foot = CGPoint(x: k.bounds.midX, y: WaitingNudge.flipped(k.art) ? k.bounds.height * 0.94 : k.bounds.height * 0.06)
                let local = CGPoint(x: foot.x - k.bounds.midX, y: foot.y - k.bounds.midY)
                let moved = p.map { nudgeApply($0.caTransform3DValue, local) }
                return moved.map { abs($0.x - local.x) < 0.01 && abs($0.y - local.y) < 0.01 } ?? false
            } ?? false)
        w1.orderOut(nil)
        let (w2, narrow) = hosted(.waiting, head: true, pet: petW)
        let rowKnock = nudgeFind(WaitingNudge.Sprite.KnockView.self, in: narrow)
        check("board: the narrow row's round avatar is the row-6 first frame's head, knocking the same way",
            rowKnock.count == 1 && nudgeGroup(rowKnock.first?.art) != nil && nudgeSame(rowKnock.first?.art.contents, Pets.shared.frame(petW, row: 6, column: 0, head: true)))
        w2.orderOut(nil)

        WaitingNudge.override = false
        let (w3, old) = hosted(.waiting, pet: petW)
        let loops = nudgeFind(SpriteLoop.LoopView.self, in: old)
        check("board: with the switch off a waiting pet plays the row-6 loop (six frames) again and nobody knocks",
            nudgeFind(WaitingNudge.Sprite.KnockView.self, in: old).isEmpty && loops.count == 1 && (loops.first?.layer?.animation(forKey: "loop") as? CAKeyframeAnimation)?.values?.count == 6)
        w3.orderOut(nil)
        WaitingNudge.override = true

        let (w4, work) = hosted(.working, pet: petW)
        let (w5, wave) = hosted(.waving, pet: petW)
        let (w6, stand) = hosted(.standing, pet: petW)
        check("board: at work it plays its row-7 loop, news waves in its row-3 loop and a seen one stands: none of them knocks",
            nudgeFind(WaitingNudge.Sprite.KnockView.self, in: work).isEmpty && nudgeFind(WaitingNudge.Sprite.KnockView.self, in: wave).isEmpty
                && nudgeFind(WaitingNudge.Sprite.KnockView.self, in: stand).isEmpty
                && (nudgeFind(SpriteLoop.LoopView.self, in: work).first?.layer?.animation(forKey: "loop") as? CAKeyframeAnimation)?.values?.count == 6
                && (nudgeFind(SpriteLoop.LoopView.self, in: wave).first?.layer?.animation(forKey: "loop") as? CAKeyframeAnimation)?.values?.count == 4
                && nudgeFind(SpriteLoop.LoopView.self, in: stand).isEmpty)
        for w in [w4, w5, w6] { w.orderOut(nil) }

        WaitingNudge.calm = { true }
        let (w7, calm) = hosted(.waiting, pet: petW)
        let calmed = nudgeFind(WaitingNudge.Sprite.KnockView.self, in: calm).first
        let fade = calmed?.ring.animation(forKey: WaitingNudge.ringKey) as? CABasicAnimation
        check("board: with Reduce Motion it does not lean: the still frame, a visible coral ring fading 1 to 0.25 and back in 2 s, only opacity",
            calmed != nil && calmed?.art.animationKeys() == nil && calmed?.ring.isHidden == false && fade?.keyPath == "opacity"
                && fade?.duration == 1 && fade?.autoreverses == true && fade?.repeatCount == .infinity
                && abs(nudgeRed(calmed?.ring.strokeColor) - (coral?.redComponent ?? 0)) < 0.003)
        w7.orderOut(nil)
        WaitingNudge.calm = { false }
        let (w8, picture) = hosted(.waiting, pet: petW, picture: true)
        check("board: in a picture (still) it is the plain frame: nothing to knock",
            nudgeFind(WaitingNudge.Sprite.KnockView.self, in: picture).isEmpty && nudgeFind(SpriteLoop.LoopView.self, in: picture).isEmpty)
        w8.orderOut(nil)
    } else {
        skipped("no cut pet frames", "nudge: the board's checks")
    }

    // ── The office ──
    if officeDealCutPets(store) {
        let (view, window) = nudgeOffice(store)
        defer { window.orderOut(nil) }
        let layout = OfficePainter.layout(store, now: Date())
        let waiting = layout.pets.filter { $0.kind == .waiting }
        let beyond = waiting.filter { $0.zone != .queue }
        func sprite(_ id: String) -> CALayer? { officePart(view, id, "sprite") }
        check("nudge office: nine waiting: seven in the queue and two standing where they are beyond it (the eighth and the ninth)",
            waiting.count == 9 && waiting.filter { $0.zone == .queue }.count == 7 && beyond.count == 2)
        check("nudge office: all nine (the queue and the two beyond it) knock: a 3 s group on the sprite, with the stagger's phase, and no loop",
            waiting.allSatisfy { p in
                let g = nudgeGroup(sprite(p.id))
                return g?.duration == 3 && g?.repeatCount == .infinity && g?.timeOffset == WaitingNudge.phase(of: p.id)
                    && sprite(p.id)?.animation(forKey: "loop") == nil && sprite(p.id)?.animation(forKey: "jump") == nil
            })
        check("nudge office: they turn about their feet (the sprite is hung from them)",
            waiting.allSatisfy { p in sprite(p.id).map { abs(WaitingNudge.feetPivot(of: $0).x) < 0.6 && abs(WaitingNudge.feetPivot(of: $0).y) < 0.6 } ?? false })
        // The first frame of row 6, as the office draws it.
        let session = store.sessions.first { $0.id == "w2" }!
        let place = layout.pets.first { $0.id == "w2" }!
        let figure = OfficePainter.figure(store, session, place, now: Date())
        let want = figure.pet.flatMap { OfficePets.shared.scaled($0, row: 6, column: 0, scale: figure.scale) }
        check("nudge office: the figure is row 6, column 0 (not the old still, column 2), and that is what its sprite layer holds",
            Pose.waiting.sheet.row == 6 && Pose.waiting.sheet.still == 0 && want != nil && nudgeSame(figure.sprite.image, want) && nudgeSame(sprite("w2")?.contents, want))
        let others = layout.pets.filter { $0.kind != .waiting }
        check("nudge office: at work, with news, seen and resting do not knock and wear no ring; at work and news keep their loops",
            others.allSatisfy { sprite($0.id)?.animation(forKey: WaitingNudge.tiltKey) == nil && officeFigure(view, $0.id)?.sublayers?.contains { $0.name == WaitingNudge.ringKey } != true }
                && others.filter { o in store.sessions.first(where: { $0.id == o.id })?.status == "busy" }.allSatisfy { sprite($0.id)?.animation(forKey: "loop") != nil })
        // The sampling: the one with phase 0 leans at once and is back at 0 by 0.45 s, and holds.
        if let early = ids.first(where: { WaitingNudge.phase(of: $0) == 0 }) {
            let layer = sprite(early)
            var peak = 0.0
            var after = 0.0
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < 0.9 {
                RunLoop.main.run(until: Date().addingTimeInterval(0.02))
                if let m = layer?.presentation()?.transform {
                    let a = abs(nudgeDegrees(m, flipped: WaitingNudge.flipped(layer!)))
                    if CACurrentMediaTime() - t0 < 0.4 { peak = max(peak, a) } else if CACurrentMediaTime() - t0 > 0.6 { after = max(after, a) }
                }
            }
            check("nudge office: live, the phase-0 one leans (over 2 degrees within its first 0.4 s) and then holds still (under 0.001 degree from 0.6 s)",
                peak > 2 && after < 0.001)
        } else {
            skipped("no id with phase 0 in the set", "nudge office: the live lean")
        }

        WaitingNudge.override = false
        view.update(store)
        CATransaction.flush()
        nudgeSpin(0.4)  // the loops' frames are scaled in the background
        check("nudge office: switched off, the waiting play their row-6 loop (six frames) again and nobody knocks",
            waiting.allSatisfy { p in
                (sprite(p.id)?.animation(forKey: "loop") as? CAKeyframeAnimation)?.values?.count == 6 && sprite(p.id)?.animation(forKey: WaitingNudge.tiltKey) == nil
            })
        WaitingNudge.override = true
        view.update(store)
        CATransaction.flush()
        check("nudge office: switched on again, they knock and the loop is gone",
            waiting.allSatisfy { p in nudgeGroup(sprite(p.id)) != nil && sprite(p.id)?.animation(forKey: "loop") == nil })

        WaitingNudge.calm = { true }
        view.update(store)
        CATransaction.flush()
        func rings(_ id: String) -> [CALayer] { officeFigure(view, id)?.sublayers?.filter { $0.name == WaitingNudge.ringKey } ?? [] }
        let someRing = rings("w2").first as? CAShapeLayer
        check("nudge office: with Reduce Motion nobody leans; each waiting one has one coral ring fading between 1 and 0.25; the others have none",
            waiting.allSatisfy { p in
                sprite(p.id)?.animation(forKey: WaitingNudge.tiltKey) == nil && rings(p.id).count == 1
                    && (rings(p.id).first?.animation(forKey: WaitingNudge.ringKey) as? CABasicAnimation)?.duration == 1
            } && others.allSatisfy { rings($0.id).isEmpty } && someRing?.fillColor == nil && someRing?.strokeColor != nil)
        let ringBox = someRing?.path?.boundingBox ?? .zero
        let body = sprite("w2")?.frame ?? .zero
        check("nudge office: the ring lies round the figure, feet at its edge: it spans the figure's width and height with room, around the origin",
            ringBox.width >= figure.wide && ringBox.height >= figure.high && ringBox.minX < 0 && ringBox.maxX > 0 && ringBox.minY <= 0 && ringBox.maxY >= 0 && body.width > 0)
        WaitingNudge.calm = { false }
        view.update(store)
        CATransaction.flush()
        check("nudge office: Reduce Motion off again: the rings go and the knocks come back",
            waiting.allSatisfy { p in rings(p.id).isEmpty && nudgeGroup(sprite(p.id)) != nil })

        // Answered: the one waiting is looked at now, and stops.
        if let i = store.sessions.firstIndex(where: { $0.id == "w2" }) {
            store.sessions[i] = boardSweepSession("w2", "idle", ago: 5, name: "等批准会话3", summary: "好了")
            store.seen["w2"] = Date().timeIntervalSince1970
            view.update(store)
            CATransaction.flush()
            check("nudge office: once answered, it knocks no more",
                sprite("w2")?.animation(forKey: WaitingNudge.tiltKey) == nil && rings("w2").isEmpty)
        }
        let stillView = OfficeView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
        stillView.still = true
        stillView.update(nudgeStore(waiting: 3))
        let anyKnock = ["w0", "w1", "w2"].contains { officePart(stillView, $0, "sprite")?.animation(forKey: WaitingNudge.tiltKey) != nil || officeFigure(stillView, $0)?.sublayers?.contains { $0.name == WaitingNudge.ringKey } == true }
        check("nudge office: in a picture (still) nobody knocks and no ring is drawn", !anyKnock)
    } else {
        skipped("no cut pet frames", "nudge: the office's checks")
    }

    // ── the sea room ──
    nudgeZoneTests()
}

/// Made-up sessions over the sea room's four islands: two waiting in the line (`nz5` has phase 0), one at work, one with news.
@MainActor func nudgeZoneStore() -> Store {
    let now = Date()
    let store = Store()
    store.readOnly = true
    var list: [Session] = []
    func add(_ id: String, _ name: String, _ status: String, ago: Double, ask: String = "", seen: Bool = true, tool: String = "") {
        var s = Session(id: id, pid: 1, project: name, name: name, status: status, since: now - ago,
                        summary: ask.isEmpty ? "整理完了，结果在 report.md" : ask, waitingFor: status == "waiting" ? "permission prompt" : "")
        s.cwd = "/tmp/nudge/" + name
        s.registryName = name
        s.tool = tool
        list.append(s)
        if seen { store.seen[s.id] = now.timeIntervalSince1970 }
    }
    add("nz0", "Web-DEMO-应用", "busy", ago: 300, tool: "Bash")
    add("nz1", "Web-UX-星图", "idle", ago: 900, seen: false)
    add("nz2", "Ops-彩虹桥", "idle", ago: 1800)
    add("nz3", "AI-lead", "busy", ago: 100, tool: "Edit")
    add("nz4", "Home-云朵", "idle", ago: 2400)
    add("nz5", "Ops-Demo-协同", "waiting", ago: 360, ask: "要你批准：kubectl apply -f deploy.yaml")
    add("nz6", "Home-lead", "waiting", ago: 200, ask: "端口用 8080 还是 9000？")
    add("nz7", "AI-QA-风车塔", "waiting", ago: 90, ask: "要你批准：lpadmin -p office")
    store.sessions = list
    store.assignPets()
    return store
}

@MainActor func nudgeZoneTests() {
    let restore = seaSweepSetup(NSTemporaryDirectory() + "nudge-zones-\(getpid())")
    defer { restore() }
    guard let scene = ZoneArt.scene else {
        skipped("no sea room art", "nudge: the sea room's checks")
        return
    }
    _ = scene
    let store = nudgeZoneStore()
    guard officeDealCutPets(store) || !store.displayPets.isEmpty else {
        skipped("no cut pet frames", "nudge: the sea room's checks")
        return
    }
    let size = CGSize(width: 1194, height: 900)
    func live(_ store: Store, calm: Bool = false, still: Bool = false) -> (ZoneView, NSWindow) {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.calmOverride = calm
        view.still = still
        let window = nudgeWindow(view)
        view.update(store)
        CATransaction.flush()
        nudgeSpin(0.15)
        return (view, window)
    }
    let waiting = ["nz5", "nz6", "nz7"]
    let (view, window) = live(store)
    defer { window.orderOut(nil) }
    check("nudge sea room: those waiting in the line stand on the first frame of row 6 (no loop) and knock: a 3 s group on the sprite, staggered by id",
        waiting.allSatisfy { id in
            let g = nudgeGroup(view.spriteLayer(of: id))
            return view.shownPose(of: id) == .waiting && view.spriteAnimation(of: id, "loop") == nil && g?.duration == 3 && g?.repeatCount == .infinity
                && g?.timeOffset == WaitingNudge.phase(of: id)
        })
    let pet = store.displayPets["nz5"] ?? ""
    check("nudge sea room: the frame is row 6, column 0 of the pet's sheet",
        !pet.isEmpty && view.shownFrame(of: "nz5") === OfficePets.shared.frame(pet, row: 6, column: 0)?.image)
    check("nudge sea room: they turn about their feet: the sprite's pivot is where its figure stands",
        waiting.allSatisfy { id in
            guard let sprite = view.spriteLayer(of: id) else { return false }
            let f = sprite.frame
            return f.minX < 0 && f.maxX > 0 && f.minY < 0 && f.maxY > 0  // the figure's origin (its feet) lies on the sprite
        })
    check("nudge sea room: at work it plays its row-7 loop, with news and seen it does not knock, and none of them wears a ring",
        ["nz0", "nz3"].allSatisfy { view.spriteAnimation(of: $0, "loop") != nil && view.spriteLayer(of: $0)?.animation(forKey: WaitingNudge.tiltKey) == nil }
            && ["nz1", "nz2", "nz4", "nz0", "nz3"].allSatisfy { view.spriteLayer(of: $0)?.animation(forKey: WaitingNudge.tiltKey) == nil && view.ringLayer(of: $0) == nil })
    window.orderOut(nil)

    WaitingNudge.override = false
    let (off, offWindow) = live(store)
    check("nudge sea room: switched off, they play the row-6 loop (six frames) again and nobody knocks",
        waiting.allSatisfy { id in (off.spriteAnimation(of: id, "loop") as? CAKeyframeAnimation)?.values?.count == 6 && off.spriteLayer(of: id)?.animation(forKey: WaitingNudge.tiltKey) == nil })
    offWindow.orderOut(nil)
    WaitingNudge.override = true

    let (calm, calmWindow) = live(store, calm: true)
    let coralRing = calm.ringLayer(of: "nz5") as? CAShapeLayer
    check("nudge sea room: with Reduce Motion they do not lean or loop; each wears a coral ring whose opacity goes 1 to 0.25 and back in 2 s",
        waiting.allSatisfy { id in
            calm.spriteLayer(of: id)?.animation(forKey: WaitingNudge.tiltKey) == nil && calm.spriteAnimation(of: id, "loop") == nil
                && (calm.ringLayer(of: id)?.animation(forKey: WaitingNudge.ringKey) as? CABasicAnimation)?.duration == 1
        } && coralRing?.fillColor == nil && coralRing?.strokeColor != nil)
    calmWindow.orderOut(nil)
    let (picture, pictureWindow) = live(store, still: true)
    check("nudge sea room: in a picture (still) nobody knocks and no ring is drawn",
        waiting.allSatisfy { picture.spriteLayer(of: $0)?.animation(forKey: WaitingNudge.tiltKey) == nil && picture.ringLayer(of: $0) == nil })
    pictureWindow.orderOut(nil)

    // Arriving: a busy one starts to wait; it runs to the line and starts to knock when it gets there.
    let fresh = store
    let (walk, walkWindow) = live(fresh)
    defer { walkWindow.orderOut(nil) }
    if let i = fresh.sessions.firstIndex(where: { $0.id == "nz4" }) {
        fresh.sessions[i] = seaSweepRemake(fresh.sessions[i], status: "waiting", since: Date())
        walk.update(fresh)
        CATransaction.flush()
        let g = nudgeGroup(walk.spriteLayer(of: "nz4"))
        let ends = walk.walkEnds(of: "nz4")
        let begins = g.flatMap { g in walk.spriteLayer(of: "nz4").map { $0.convertTime(g.beginTime, to: nil) } }
        check("nudge sea room: one that starts to wait runs to the line (running frames) and knocks from the end of its walk, not before",
            walk.spriteAnimation(of: "nz4", "steps") != nil && g != nil && ends > CACurrentMediaTime() && begins.map { abs($0 - ends) < 0.05 } == true)
    }
}

// ───────── Stills ─────────

/// `--nudge-stills <dir>`: the board (wide and narrow), the office (seven in the queue, and nine with two beyond it) and the
/// sea room, each with sessions waiting, with news, at work and seen, all made up. `board-*`, `office-*`, `sea-room.png`.
@MainActor func nudgeStills(_ dir: String) {
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = nil }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let few = boardSweepStore(boardSweepAllStates().filter { ["w-perm", "w-input", "w-wb", "u-news", "u-pin", "b-tool", "b-1", "s-seen", "r-rest"].contains($0.id) })
    boardSweepBoard(few, width: 640, zoom: 1, dir + "/board-wide.png")
    boardSweepBoard(few, width: 420, zoom: 1, dir + "/board-narrow.png")
    boardSweepOffice(few, zoom: 1, dir + "/office-queue.png")
    let nine = nudgeStore(waiting: 9)
    boardSweepOffice(nine, zoom: 1, dir + "/office-nine-waiting.png")
    // the sea room
    let restore = seaSweepSetup(NSTemporaryDirectory() + "nudge-zones-\(getpid())")
    defer { restore() }
    if ZoneArt.scene != nil {
        let zone = nudgeZoneStore()
        let view = ZoneView(frame: CGRect(x: 0, y: 0, width: 1194, height: 900))
        view.still = true
        view.update(zone)
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        save(view.image(pixelScale: 2), dir + "/sea-room.png")
    } else {
        print("nudge stills: no sea room art, sea-room.png not written")
    }
    print("nudge stills in \(dir)")
}

// ───────── The burst ─────────

/// Samples five seconds at 0.1 s: `sample` gives the lean in degrees, the frame it shows and the ring's opacity.
@MainActor func nudgeBurstRun(_ title: String, _ note: String, _ sample: () -> (angle: Double, frame: String, opacity: Double), each: ((Int, Double) -> Void)? = nil) -> String {
    var lines = ["\(title)", note, "", "  t(s)   lean(deg)  frame   ring-opacity"]
    var tilting: [(Double, Double)] = []
    var frames = Set<String>()
    var open: Double?
    var last = 0.0
    let t0 = CACurrentMediaTime()
    for i in 0...50 {
        let target = t0 + Double(i) * 0.1
        while CACurrentMediaTime() < target { RunLoop.main.run(until: Date().addingTimeInterval(0.004)) }
        let t = CACurrentMediaTime() - t0
        let s = sample()
        each?(i, t)
        frames.insert(s.frame)
        if abs(s.angle) > 0.001 { if open == nil { open = t }; last = t } else if let o = open { tilting.append((o, last)); open = nil }
        lines.append(String(format: "  %4.1f   %+8.2f   %@   %.2f", t, s.angle, s.frame, s.opacity))
    }
    if let o = open { tilting.append((o, last)) }
    lines.append("")
    lines.append("leaning in: " + (tilting.isEmpty ? "(never)" : tilting.map { String(format: "%.1f–%.1f s", $0.0, $0.1) }.joined(separator: ", ")) + "; frames shown: \(frames.sorted())")
    return lines.joined(separator: "\n")
}

/// The frame a layer's contents are, among the row-6 and standing frames of this pet, by pixels.
@MainActor func nudgeFrameName(_ contents: Any?, _ candidates: [(String, CGImage?)]) -> String {
    for (name, image) in candidates where nudgeSame(contents, image) { return name }
    return "?"
}

/// `--nudge-burst <dir>`: for one waiting session on each screen, five seconds at 0.1 s: the lean (the presentation layer's
/// transform), which frame it shows, the ring's opacity. Normal and with Reduce Motion: `burst-*.txt`; the office also as
/// contact sheets of the figure itself (`burst-office*.png`), the presentation layer drawn at each sample.
@MainActor func nudgeBurst(_ dir: String) {
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    NSApplication.shared.setActivationPolicy(.accessory)
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = nil; WaitingNudge.override = nil; WaitingNudge.calm = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion } }
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    WaitingNudge.override = true

    for calm in [false, true] {
        let tag = calm ? "reduce-motion" : "normal"
        WaitingNudge.calm = { calm }
        var text = ""

        // The board's card: a pet in a window.
        let store = nudgeStore(waiting: 9)
        if let pet = store.displayPets["w2"] {
            let host = NSHostingView(rootView: PetSprite(pet: pet, pose: .waiting, size: 100, knockID: "w2"))
            host.frame = CGRect(x: 0, y: 0, width: 140, height: 140)
            let window = nudgeWindow(host)
            nudgeSpin(0.05)
            if let knock = nudgeFind(WaitingNudge.Sprite.KnockView.self, in: host).first {
                let refs = (0..<8).map { ("6-\($0)", Pets.shared.frame(pet, row: 6, column: $0, head: false)) } + [("0-0 standing", Pets.shared.frame(pet, row: 0, column: 0, head: false))]
                let own = nudgeFrameName(knock.art.contents, refs)
                text += nudgeBurstRun("Board (card, wide), session w2 (phase 0.0 s), \(tag)", "pet \(pet); model frame is \(own)", {
                    let m = knock.art.presentation()?.transform ?? CATransform3DIdentity
                    let same = (knock.art.presentation()?.contents as AnyObject?) === (knock.art.contents as AnyObject?)
                    return (nudgeDegrees(m, flipped: WaitingNudge.flipped(knock.art)), same ? own : "changed", Double(knock.ring.presentation()?.opacity ?? 0) * (knock.ring.isHidden ? 0 : 1))
                }) + "\n\n"
            }
            window.orderOut(nil)
        }

        // The office.
        if officeDealCutPets(store) {
            let (view, window) = nudgeOffice(store)
            let layout = OfficePainter.layout(store, now: Date())
            let place = layout.pets.first { $0.id == "w2" }!
            let session = store.sessions.first { $0.id == "w2" }!
            let made = OfficePainter.figure(store, session, place, now: Date())
            let pet = made.pet ?? ""
            let refs = (0..<8).map { ("6-\($0)", OfficePets.shared.scaled(pet, row: 6, column: $0, scale: made.scale)) } + [("0-0 standing", OfficePets.shared.scaled(pet, row: 0, column: 0, scale: made.scale))]
            let layer = officePart(view, "w2", "sprite")
            let own = nudgeFrameName(layer?.contents, refs)
            var crops: [(String, CGImage)] = []
            let ringLayer: () -> CALayer? = { officeFigure(view, "w2")?.sublayers?.first { $0.name == WaitingNudge.ringKey } }
            text += nudgeBurstRun("Office queue (bottom queue), session w2 (phase 0.0 s), \(tag)", "pet \(pet); model frame is \(own)", {
                let m = layer?.presentation()?.transform ?? CATransform3DIdentity
                let same = (layer?.presentation()?.contents as AnyObject?) === (layer?.contents as AnyObject?)
                return (nudgeDegrees(m, flipped: layer.map(WaitingNudge.flipped) ?? false), same ? own : "changed", Double(ringLayer()?.presentation()?.opacity ?? 0))
            }, each: { _, t in
                // Just the figure (its sprite and ring) as the presentation layer shows it now, feet at (56, 118) from the top.
                guard let figureLayer = officeFigure(view, "w2")?.presentation(),
                    let ctx = CGContext(data: nil, width: 224, height: 280, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                ctx.setFillColor(CGColor(red: 0.22, green: 0.27, blue: 0.33, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 224, height: 280))
                ctx.scaleBy(x: 2, y: 2)
                ctx.translateBy(x: 56, y: 22)
                ctx.scaleBy(x: 1, y: -1)
                figureLayer.render(in: ctx)
                if let crop = ctx.makeImage() { crops.append((String(format: "%.1fs", t), crop)) }
            }) + "\n\n"
            save(nudgeSheet(crops, columns: 10, cell: CGSize(width: 112, height: 140)), dir + "/burst-office-\(tag).png")
            window.orderOut(nil)
        }

        // The sea room.
        let restore = seaSweepSetup(NSTemporaryDirectory() + "nudge-zones-\(getpid())")
        if ZoneArt.scene != nil {
            let zone = nudgeZoneStore()
            let view = ZoneView(frame: CGRect(x: 0, y: 0, width: 1194, height: 900))
            view.calmOverride = calm
            let window = nudgeWindow(view)
            view.update(zone)
            CATransaction.flush()
            nudgeSpin(0.05)
            let pet = zone.displayPets["nz5"] ?? ""
            let refs = (0..<8).map { ("6-\($0)", OfficePets.shared.frame(pet, row: 6, column: $0)?.image) } + [("0-0 standing", OfficePets.shared.frame(pet, row: 0, column: 0)?.image)]
            let sprite = view.spriteLayer(of: "nz5")
            let own = nudgeFrameName(sprite?.contents, refs)
            text += nudgeBurstRun("Sea room (line), session nz5 (phase 0.0 s), \(tag)", "pet \(pet); model frame is \(own)", {
                let m = sprite?.presentation()?.transform ?? CATransform3DIdentity
                let same = (sprite?.presentation()?.contents as AnyObject?) === (sprite?.contents as AnyObject?)
                return (nudgeDegrees(m, flipped: sprite.map(WaitingNudge.flipped) ?? true), same ? own : "changed", Double(view.ringLayer(of: "nz5")?.presentation()?.opacity ?? 0))
            }) + "\n"
            window.orderOut(nil)
        }
        restore()
        try? text.write(toFile: dir + "/burst-\(tag).txt", atomically: true, encoding: .utf8)
    }
    print("nudge burst in \(dir)")
}

/// A contact sheet: each crop under its label, `columns` across.
@MainActor func nudgeSheet(_ crops: [(String, CGImage)], columns: Int, cell: CGSize) -> CGImage? {
    guard !crops.isEmpty else { return nil }
    let rows = (crops.count + columns - 1) / columns, label: CGFloat = 16
    let w = Int(CGFloat(columns) * cell.width), h = Int(CGFloat(rows) * (cell.height + label))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(red: 0.1, green: 0.09, blue: 0.19, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    for (i, crop) in crops.enumerated() {
        let col = i % columns, row = i / columns
        let x = CGFloat(col) * cell.width, y = CGFloat(h) - CGFloat(row + 1) * (cell.height + label)
        ctx.draw(crop.1, in: CGRect(x: x, y: y, width: cell.width, height: cell.height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gc
        (crop.0 as NSString).draw(at: CGPoint(x: x + 4, y: y + cell.height + 1), withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
        ctx.stroke(CGRect(x: x, y: y, width: cell.width, height: cell.height + label))
    }
    return ctx.makeImage()
}
