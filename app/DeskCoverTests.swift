import AppKit
import QuartzCore

// ───────── Desk cover: the desks cover the figures behind them (the sea room) ─────────
//
// Each desk is a foreground layer in the stage (`ZoneDeskLayers`), as deep as its centre; a figure's place in the order
// is `ZoneOcclusion.key` (feet against the desk's footprint, seen along the camera), worked out once when it stands and,
// along a walk, as zPosition keyframes when it sets off. `deskCoverTests()` (in the full run, alone with `--desk-cover-only`) checks the
// order where they stand, sit, queue and visit, along walks and when two cross, that plates, bubbles and badges stay over
// every desk, and that a desk's screen and LED pictures follow its state. `--desk-cover-still <dir>` writes the panorama.

/// An RGBA picture's bytes, rows from the top.
private struct deskCoverPixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage?) {
        guard let image else { return nil }
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let drew = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drew else { return nil }
        bytes = data
    }

    func alpha(_ x: Int, _ y: Int) -> UInt8 {
        guard x >= 0, y >= 0, x < width, y < height else { return 0 }
        return bytes[(y * width + x) * 4 + 3]
    }

    /// Whether two pictures the same size show the same colour here (within `slack` on every channel).
    func same(as other: deskCoverPixels, _ x: Int, _ y: Int, slack: Int = 3) -> Bool {
        let i = (y * width + x) * 4
        for c in 0..<3 where abs(Int(bytes[i + c]) - Int(other.bytes[i + c])) > slack { return false }
        return true
    }
}

/// The value a discrete keyframe animation holds `t` (0…1) into it.
private func deskCoverDiscrete(_ a: CAKeyframeAnimation, _ t: Double) -> CGFloat? {
    guard let values = a.values as? [NSNumber], let times = a.keyTimes, !values.isEmpty else { return nil }
    var pick = 0
    for i in values.indices where i < times.count && times[i].doubleValue <= t { pick = i }
    return CGFloat(values[pick].doubleValue)
}

/// Where a linear position keyframe animation is `t` (0…1) into it.
private func deskCoverPosition(_ a: CAKeyframeAnimation, _ t: Double) -> CGPoint? {
    guard let values = a.values as? [NSValue], let times = a.keyTimes, values.count == times.count, values.count > 1 else { return nil }
    let points = values.map { $0.pointValue }
    for i in 1..<points.count where t <= times[i].doubleValue {
        let t0 = times[i - 1].doubleValue, t1 = times[i].doubleValue
        let k = t1 > t0 ? CGFloat((t - t0) / (t1 - t0)) : 1
        return CGPoint(x: points[i - 1].x + (points[i].x - points[i - 1].x) * k, y: points[i - 1].y + (points[i].y - points[i - 1].y) * k)
    }
    return points.last
}

/// The room with someone at the near-row desks too: `seaSweepRoom(extra: 10)` (AI's desks 1–12 taken), and one waiting.
@MainActor private func deskCoverRoom() -> Store {
    let (store, _) = seaSweepRoom(extra: 10)
    store.sessions = store.sessions.map { $0.name == "Ops-彩虹桥" ? seaSweepRemake($0, status: "waiting", since: Date() - 300) : $0 }
    return store
}

/// Every place's figure against every desk its picture overlaps: behind a desk it is under the desk, in front over it.
/// The wrong ones, by name.
@MainActor private func deskCoverMisordered(_ view: ZoneView, _ store: Store, _ scene: ZoneScene, _ fit: ZoneFit) -> [String] {
    guard let forward = scene.forward, let map = scene.walkMap else { return ["no floor model"] }
    var wrong: [String] = []
    for s in store.sessions {
        guard let layer = view.figureLayer(of: s.id), let foot = view.foot(of: s.id), let sprite = view.sprite(of: s.id) else { continue }
        let box = sprite.frame.offsetBy(dx: foot.x, dy: foot.y)
        let w = map.world(fit.back(foot))
        for art in scene.deskLayers where fit.rect(art.box).intersects(box) {
            let deskZ = fit.point(CGPoint(x: 0, y: art.sortY)).y
            switch ZoneOcclusion.side(of: w, art, forward: forward) {
            case .behind?: if layer.zPosition >= deskZ { wrong.append("\(s.name) over \(art.id) it stands behind") }
            case .front?: if layer.zPosition <= deskZ { wrong.append("\(s.name) under \(art.id) it stands in front of") }
            case nil: break
            }
        }
    }
    return wrong
}

@MainActor func deskCoverTests() {
    let restore = seaSweepSetup(NSTemporaryDirectory() + "desk-cover-t-\(getpid())")
    defer { restore() }
    guard let scene = ZoneArt.scene else { return skipped("no seaview art", "desk cover") }
    guard scene.deskLayers.count == scene.desks.count + 1, let forward = scene.forward, let map = scene.walkMap else {
        return check("desk cover: every desk has its layer (\(scene.deskLayers.count) of \(scene.desks.count + 1)) and the floor model is there", false)
    }
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    let size = CGSize(width: 1180, height: 790)
    let fit = ZoneFit(scene: scene.size, view: size)
    func near(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height) < 0.01 }
    func desk(_ zone: String, _ index: Int) -> ZoneScene.Desk? { scene.desk(ZoneDesk(zone: zone, index: index)) }

    // ── The layers: one per desk (the boss's too), in the stage, as deep as the desk's centre; three pictures each. ──
    do {
        let view = ZoneView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(deskCoverRoom())
        var ok = view.deskLayerCount == 49
        var lit = 0
        for d in scene.desks {
            guard let layers = view.deskLayer(ZoneDesk(zone: d.zone, index: d.index)), let art = d.layer else { ok = false; continue }
            ok = ok && layers.holder.superlayer === view.stageLayer && abs(layers.holder.zPosition - fit.point(CGPoint(x: 0, y: art.sortY)).y) < 0.001
                && layers.off.contents != nil && near(layers.off.frame, fit.rect(art.box))
            if ZoneArt.picture("desks/\(art.id)_screen") != nil && ZoneArt.picture("desks/\(art.id)_led") != nil { lit += 1 }
        }
        let boss = view.deskLayer(ZoneView.bossDeskKey)
        check("desk cover: 49 desk layers in the stage (48 desks and the boss's), each as deep as its desk's centre, its picture over its box", ok && boss?.off.contents != nil)
        check("desk cover: each of the 48 desks has its screen-lit and LED-lit pictures (\(lit))", lit == 48)
    }

    // ── 1. At their desks: the far row (row 0) behind its desk, covered by it; the near row in front, over it. ──
    let room = deskCoverRoom()
    let still = ZoneView(frame: CGRect(origin: .zero, size: size))
    still.still = true
    still.update(room)
    var far = 0, near = 0, farOK = 0, nearOK = 0
    var farCovered: [Double] = [], nearShown: [Double] = []
    let all = deskCoverPixels(still.image(pixelScale: 1))
    // For the pets alone: the plates, bubbles and badges (over everything, checked in 4) out of the way.
    func bare() -> deskCoverPixels? {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in still.overStage { l.isHidden = true }
        let picture = deskCoverPixels(still.image(pixelScale: 1))
        for l in still.overStage { l.isHidden = false }
        CATransaction.commit()
        return picture
    }
    for s in room.sessions {
        guard case .desk(let d)? = still.plan.place[s.id], let art = scene.desk(d)?.layer, let row = art.row,
            let figure = still.figureLayer(of: s.id), let layers = still.deskLayer(d) else { continue }
        if row == 0 {
            far += 1
            if figure.zPosition < layers.holder.zPosition { farOK += 1 }
        } else {
            near += 1
            if figure.zPosition > layers.holder.zPosition { nearOK += 1 }
        }
        // The pixels where both the pet and its desk are drawn: the desk's (as the picture without the pet) or the pet's.
        guard let only = deskCoverPixels(still.figureImage(only: s.id)), let deskPicture = layers.off.contents,
            CFGetTypeID(deskPicture as CFTypeRef) == CGImage.typeID, let deskPixels = deskCoverPixels((deskPicture as! CGImage)) else { continue }
        // Only it and its own desk in the stage (another nearer desk or pet may rightly cover it too), with and without the pet.
        let others = (still.stageLayer.sublayers ?? []).filter { $0 !== layers.holder && $0 !== figure }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in others { l.isHidden = true }
        let shown = bare()
        figure.isHidden = true
        let hidden = bare()
        figure.isHidden = false
        for l in others { l.isHidden = false }
        CATransaction.commit()
        guard let all = shown, let without = hidden else { continue }
        let frame = layers.off.frame
        let kx = CGFloat(deskPixels.width) / frame.width, ky = CGFloat(deskPixels.height) / frame.height
        // Whether the desk's picture is solid all over this view pixel and a texel round it (not its anti-aliased rim).
        func solid(_ x: Int, _ y: Int) -> Bool {
            let u0 = Int(((CGFloat(x) - frame.minX) * kx).rounded(.down)) - 1, u1 = Int(((CGFloat(x + 1) - frame.minX) * kx).rounded(.up)) + 1
            let v0 = Int(((CGFloat(y) - frame.minY) * ky).rounded(.down)) - 1, v1 = Int(((CGFloat(y + 1) - frame.minY) * ky).rounded(.up)) + 1
            for v in v0...v1 { for u in u0...u1 where deskPixels.alpha(u, v) < 250 { return false } }
            return true
        }
        var both = 0, coveredCount = 0
        for y in max(0, Int(frame.minY))..<min(all.height, Int(frame.maxY)) {
            for x in max(0, Int(frame.minX))..<min(all.width, Int(frame.maxX)) where only.alpha(x, y) > 200 {
                guard solid(x, y) else { continue }
                both += 1
                if all.same(as: without, x, y) { coveredCount += 1 }
            }
        }
        guard both >= 20 else { continue }
        if row == 0 { farCovered.append(Double(coveredCount) / Double(both)) } else { nearShown.append(1 - Double(coveredCount) / Double(both)) }
    }
    check("desk cover 1: the far row's figures at their desks are under their own desk's layer (\(farOK) of \(far)), the near row's over it (\(nearOK) of \(near))",
          far >= 4 && near >= 3 && farOK == far && nearOK == near)
    check(String(format: "desk cover 1: in the picture the far row's pets are covered where their desk is drawn (%d pets, least %.2f), the near row's show over it (%d pets, least %.2f)",
                 farCovered.count, farCovered.min() ?? 0, nearShown.count, nearShown.min() ?? 0),
          farCovered.count >= 4 && nearShown.count >= 3 && (farCovered.min() ?? 0) > 0.97 && (nearShown.min() ?? 0) > 0.97)

    // Standing, sitting, in the line, at check-in and visiting: every figure against every desk it overlaps.
    let host = room.sessions.first { $0.name == "AI-QA-云杉8" }?.id
    let guest = room.sessions.first { $0.name == "Web-星球漫游" }?.id
    if let host, let guest {
        still.visit(guest, to: host, words: "看一下", until: Date() + 60)
        still.update(room)
    }
    let places = Set(room.sessions.compactMap { still.plan.place[$0.id].map { "\($0)".components(separatedBy: "(").first ?? "" } })
    let misordered = deskCoverMisordered(still, room, scene, fit)
    check("desk cover: at desks, sofas, in the line and visiting (\(places.sorted().joined(separator: " "))), each figure is under the desks it stands behind and over those it stands in front of \(misordered.prefix(4))",
          misordered.isEmpty && places.contains("desk") && places.contains("sofaSeat") && places.contains("line") && guest.map { still.says($0) } == true)

    // ── 2. Walking: behind the far row's desks (along its chairs) covered all the way, in front of the near row's not. ──
    do {
        func lane(_ zone: String, _ indexes: ClosedRange<Int>) -> [CGPoint] {
            let seats = indexes.compactMap { desk(zone, $0)?.seat }.map { map.world($0) }
            guard let a = seats.first, let b = seats.last else { return [] }
            let along = CGVector(dx: b.x - a.x, dy: b.y - a.y), n = 60
            return (0...n).map { k in
                let t = -0.15 + 1.3 * CGFloat(k) / CGFloat(n)
                return map.pixel(CGPoint(x: a.x + along.dx * t, y: a.y + along.dy * t))
            }
        }
        let tall = scene.petHeight
        func box(_ feet: CGPoint) -> CGRect { CGRect(x: feet.x - tall * 0.4, y: feet.y - tall, width: tall * 0.8, height: tall) }
        var behindSteps = 0, behindWrong = 0, depthWouldErr = 0
        for zone in ["Web", "Ops", "AI", "Home"] {
            for feet in lane(zone, 1...6) {
                let key = ZoneOcclusion.key(feet: feet, box: box(feet), scene: scene)
                for art in scene.deskLayers where art.row == 0 && art.box.intersects(box(feet)) && art.id.hasPrefix(zone + "_") {
                    guard ZoneOcclusion.side(of: map.world(feet), art, forward: forward) == .behind else { continue }
                    behindSteps += 1
                    if key >= art.sortY { behindWrong += 1 }
                    if feet.y > art.sortY { depthWouldErr += 1 }
                }
            }
        }
        check("desk cover 2: walking along the far row's chairs, behind its desks: under every desk it overlaps (\(behindSteps - behindWrong) of \(behindSteps) steps; \(depthWouldErr) of them the feet are past the desk centre's depth, where a plain depth sort puts it in front)",
              behindSteps > 100 && behindWrong == 0 && depthWouldErr > 10)
        var frontSteps = 0, frontWrong = 0
        for zone in ["Web", "Ops", "AI", "Home"] {
            // The near row's chairs are in front of its desks; a little further out, the aisle.
            for feet in lane(zone, 7...12) {
                let key = ZoneOcclusion.key(feet: feet, box: box(feet), scene: scene)
                for art in scene.deskLayers where art.row == 1 && art.box.intersects(box(feet)) && art.id.hasPrefix(zone + "_") {
                    guard ZoneOcclusion.side(of: map.world(feet), art, forward: forward) == .front else { continue }
                    frontSteps += 1
                    if key <= art.sortY { frontWrong += 1 }
                }
            }
        }
        check("desk cover 2: walking along the near row's chairs, in front of its desks: over every desk it overlaps (\(frontSteps - frontWrong) of \(frontSteps) steps)",
              frontSteps > 100 && frontWrong == 0)
    }

    // Real walks in a live room: out of a far-row desk to the sofa, back to it, to the line. The zPosition keyframes, at
    // each one's point on the way, against every desk layer the pet overlaps there.
    let liveStore = deskCoverRoom()
    let live = ZoneView(frame: CGRect(origin: .zero, size: size))
    live.onScreenOverride = true
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    live.update(liveStore)
    func settle() {
        CATransaction.flush()
        var longest = 0.0
        for s in liveStore.sessions { longest = max(longest, live.walkEnds(of: s.id) - CACurrentMediaTime()) }
        RunLoop.main.run(until: Date(timeIntervalSinceNow: max(0, longest) + 0.3))
    }
    settle()
    func audit(_ id: String) -> (samples: Int, behind: Int, front: Int, wrong: [String], gap: CGFloat) {
        guard let layer = live.figureLayer(of: id), let depth = layer.animation(forKey: ZoneView.walkDepthKey) as? CAKeyframeAnimation,
            let walk = layer.animation(forKey: "walk") as? CAKeyframeAnimation, let sprite = live.sprite(of: id), let times = depth.keyTimes
        else { return (0, 0, 0, ["no walk keyframes"], 0) }
        var behind = 0, front = 0, wrong: [String] = [], gap: CGFloat = 0
        var last: CGPoint?
        for (i, time) in times.enumerated() where i < (depth.values?.count ?? 0) - 1 {
            let t = time.doubleValue
            guard let at = deskCoverPosition(walk, t + 1e-9), let z = deskCoverDiscrete(depth, t + 1e-9) else { continue }
            if let last { gap = max(gap, hypot(at.x - last.x, at.y - last.y)) }
            last = at
            let box = sprite.frame.offsetBy(dx: at.x, dy: at.y)
            let w = map.world(fit.back(at))
            for art in scene.deskLayers where fit.rect(art.box).intersects(box) {
                let deskZ = fit.point(CGPoint(x: 0, y: art.sortY)).y
                switch ZoneOcclusion.side(of: w, art, forward: forward) {
                case .behind?:
                    behind += 1
                    if z >= deskZ { wrong.append(String(format: "over %@ at %.2f", art.id, t)) }
                case .front?:
                    front += 1
                    if z <= deskZ { wrong.append(String(format: "under %@ at %.2f", art.id, t)) }
                case nil: break
                }
            }
        }
        return (times.count, behind, front, wrong, gap)
    }
    func change(_ name: String, _ make: (Session) -> Session) -> String? {
        guard let s = liveStore.sessions.first(where: { $0.name == name }) else { return nil }
        liveStore.sessions = liveStore.sessions.map { $0.id == s.id ? make($0) : $0 }
        live.update(liveStore)
        return s.id
    }
    var walked: [String] = [], walkWrong: [String] = [], behindSeen = 0, frontSeen = 0, widest: CGFloat = 0
    // Done and unread: from its desk (Web#2, the far row) to the sofa; looked at: back to its desk; waiting: to the line.
    let moves: [(String, String, (Session) -> Session)] = [
        ("Web-星球漫游", "desk → sofa", { seaSweepRemake($0, status: "idle", since: Date()) }),
        ("AI-QA-云杉8", "desk → line", { seaSweepRemake($0, status: "waiting", since: Date()) }),
        ("Home-云朵", "sofa → desk", { seaSweepRemake($0, status: "busy", since: Date()) }),
    ]
    for (name, what, make) in moves {
        if name == "Web-星球漫游", let s = liveStore.sessions.first(where: { $0.name == name }) { liveStore.seen[s.id] = nil }
        guard let id = change(name, make) else { continue }
        CATransaction.flush()
        let result = audit(id)
        walked.append("\(what) \(result.samples)")
        walkWrong += result.wrong.map { "\(name) \($0)" }
        behindSeen += result.behind
        frontSeen += result.front
        widest = max(widest, result.gap)
        settle()
    }
    check("desk cover 2: real walks (\(walked.joined(separator: ", ")) keyframes): under every desk it passes behind (\(behindSeen)), over every one it passes in front of (\(frontSeen)) \(walkWrong.prefix(3))",
          walked.count == 3 && walkWrong.isEmpty && behindSeen > 0 && frontSeen > 0)
    check(String(format: "desk cover 2: the walk's order is sampled every %.0f picture px or closer (widest step %.1f view pt at scale %.3f)", ZoneView.depthStep, widest, fit.scale),
          widest > 0 && widest <= ZoneView.depthStep * fit.scale + 0.5)
    let settledWrong = deskCoverMisordered(live, liveStore, scene, fit)
    check("desk cover 2: back at their places after the walks, the order is the standing one \(settledWrong.prefix(3))", settledWrong.isEmpty)

    // ── 3. Two crossing: the nearer one (lower feet) drawn over the other at every moment they overlap. ──
    do {
        let ids = liveStore.sessions.filter { $0.name == "Web-DEMO-应用" || $0.name == "Ops-Demo-协同" }.map(\.id)
        if ids.count == 2, let line = scene.queueLine.first {
            // Open floor by the line: A walks down the picture past B walking up it, side by side a little apart.
            let a0 = fit.point(CGPoint(x: line.x - 30, y: line.y - 260)), a1 = fit.point(CGPoint(x: line.x - 30, y: line.y + 40))
            let b0 = fit.point(CGPoint(x: line.x + 30, y: line.y + 40)), b1 = fit.point(CGPoint(x: line.x + 30, y: line.y - 260))
            live.walkForCheck(ids[0], along: [a0, a1])
            live.walkForCheck(ids[1], along: [b0, b1])
            let la = live.figureLayer(of: ids[0]), lb = live.figureLayer(of: ids[1])
            if let da = la?.animation(forKey: ZoneView.walkDepthKey) as? CAKeyframeAnimation, let db = lb?.animation(forKey: ZoneView.walkDepthKey) as? CAKeyframeAnimation,
                let wa = la?.animation(forKey: "walk") as? CAKeyframeAnimation, let wb = lb?.animation(forKey: "walk") as? CAKeyframeAnimation {
                var right = 0, wrongAt: [Double] = [], oldWrong = 0, aFront = 0, bFront = 0
                for k in 0...200 {
                    let t = Double(k) / 200
                    guard let pa = deskCoverPosition(wa, t), let pb = deskCoverPosition(wb, t), let za = deskCoverDiscrete(da, t), let zb = deskCoverDiscrete(db, t) else { continue }
                    // Within a step of each other the order may go either way.
                    guard abs(pa.y - pb.y) > ZoneView.depthStep * fit.scale * 1.5 else { continue }
                    if (pa.y > pb.y) == (za > zb) { right += 1 } else { wrongAt.append(t) }
                    // Counts the moments where holding each figure at its end's y the whole way would give the wrong order.
                    if (pa.y > pb.y) != (a1.y > b1.y) { oldWrong += 1 }
                    if pa.y > pb.y { aFront += 1 } else { bFront += 1 }
                }
                check("desk cover 3: two crossing: the nearer drawn over the other all the way (\(right) moments right, wrong at \(wrongAt.prefix(3)); with the end's zPosition from the start \(oldWrong) would be wrong)",
                      wrongAt.isEmpty && right > 150 && oldWrong > 50 && aFront > 20 && bFront > 20)
            } else {
                check("desk cover 3: two crossing: both walks have their zPosition keyframes", false)
            }
            settle()
        } else {
            check("desk cover 3: two crossing: the room has its two walkers and its line", false)
        }
    }

    // ── 4. Plates, bubbles and badges over every desk layer. ──
    do {
        let root = still.layer?.sublayers ?? []
        let at = { (l: CALayer) in root.firstIndex { $0 === l } ?? -1 }
        let order = at(still.stageLayer) >= 0 && still.overStage.allSatisfy { at($0) > at(still.stageLayer) }
        let flat = root.allSatisfy { $0.zPosition == 0 }
        var desksInStage = true
        for d in scene.desks { desksInStage = desksInStage && still.deskLayer(ZoneDesk(zone: d.zone, index: d.index))?.holder.superlayer === still.stageLayer }
        let inPlates = still.platesAbovePets
        var marks = 0, marksOK = 0
        for s in room.sessions {
            guard let figure = still.figureLayer(of: s.id) else { continue }
            if still.badge(of: s.id) != nil || still.dotShown(s.id) || still.bubbleFrame(of: s.id) != nil {
                marks += 1
                // The badge and bubble live in the figure's voice, in the speech layer.
                if let voice = still.voiceLayer(of: s.id), voice.superlayer === still.overStage[1], figure.superlayer === still.stageLayer { marksOK += 1 }
            }
        }
        check("desk cover 4: the plates and the speech layer (bubbles, dots, badges: \(marksOK) of \(marks)) are over the stage, where every desk layer is; nothing lifts the stage over them",
              order && flat && desksInStage && inPlates && marks >= 3 && marksOK == marks)
        // In the picture: a far-row figure's plate lies on its desk and shows whole.
        var plates = 0, platesShown = 0
        if let all {
            for s in room.sessions {
                guard case .desk(let d)? = still.plan.place[s.id], scene.desk(d)?.layer?.row == 0, let plate = still.plateFrame(of: s.id),
                    let layers = still.deskLayer(d), plate.intersects(layers.off.frame), let tag = still.tagLayer(of: s.id), tag.superlayer === still.overStage[0] else { continue }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                tag.isHidden = true
                let without = deskCoverPixels(still.image(pixelScale: 1))
                tag.isHidden = false
                CATransaction.commit()
                guard let without else { continue }
                var inside = 0, differ = 0
                let r = plate.insetBy(dx: 2, dy: 2)
                for y in Int(r.minY)..<Int(r.maxY) {
                    for x in Int(r.minX)..<Int(r.maxX) where x >= 0 && y >= 0 && x < all.width && y < all.height {
                        inside += 1
                        if !all.same(as: without, x, y, slack: 1) { differ += 1 }
                    }
                }
                plates += 1
                if inside > 0 && Double(differ) / Double(inside) > 0.9 { platesShown += 1 }
            }
        }
        check("desk cover 4: in the picture, the far row's plates on their desks show whole (\(platesShown) of \(plates))", plates >= 3 && platesShown == plates)
        // Over a covered pet, its aura is cut by the desk too (it is in the figure's layer), the plate not.
        check("desk cover 4: the aura and its lightning are in the figure's own layer (covered with it), not over the stage",
              room.sessions.allSatisfy { s in still.aura(of: s.id).map { $0.superlayer === still.figureLayer(of: s.id) } ?? true })
    }

    // ── 5. A desk's lights: busy → its screen and LED pictures; waiting → its orange glow cut to the desk; seen → dark. ──
    do {
        guard let id = change("Web-DEMO-应用", { seaSweepRemake($0, status: "busy", since: Date()) }), let d = live.plan.desks[id], let layers = live.deskLayer(d)
        else { return check("desk cover 5: the desk's layers are there", false) }
        settle()
        let art = layers.art
        func shows(_ layer: CALayer, _ name: String) -> Bool {
            guard layer.opacity > 0, let c = layer.contents, CFGetTypeID(c as CFTypeRef) == CGImage.typeID else { return false }
            return (c as! CGImage) === ZoneArt.picture(name)
        }
        let busyOK = shows(layers.screen, "desks/\(art.id)_screen") && shows(layers.led, "desks/\(art.id)_led") && ZoneBreath.isBreathing(layers.led)
            && layers.glow.opacity == 0 && live.codeLayer(d)?.superlayer === layers.holder
            && (layers.holder.sublayers ?? []).firstIndex { $0 === live.codeLayer(d) } ?? -1 > (layers.holder.sublayers ?? []).firstIndex { $0 === layers.screen } ?? 99
        check("desk cover 5: busy: its desk layer shows the screen-lit and LED-lit pictures (the LED breathing with the floor's), the code over the lit screen in the desk's layer",
              busyOK && live.screenShown(d) && live.ledBreathes(d))
        _ = change("Web-DEMO-应用", { seaSweepRemake($0, status: "waiting", since: Date()) })
        settle()
        let waitOK = layers.screen.opacity == 0 && layers.led.opacity == 0 && !ZoneBreath.isBreathing(layers.led) && layers.glow.opacity > 0
            && layers.glow.contents != nil && live.ledColor(d) == .orange
        check("desk cover 5: waiting: the desk's screen and LED pictures off, its orange glow (cut to the desk) on", waitOK)
        let sid = liveStore.sessions.first { $0.id == id }
        if let sid { liveStore.seen[sid.id] = Date().timeIntervalSince1970 + 5 }
        _ = change("Web-DEMO-应用", { seaSweepRemake($0, status: "idle", since: Date() - 30) })
        settle()
        check("desk cover 5: seen: dark again (screen, LED and glow off on its desk layer)",
              layers.screen.opacity == 0 && layers.led.opacity == 0 && layers.glow.opacity == 0 && live.ledColor(d) == .off && !live.codeShown(d))
        // And in a still: lit, the screen's box shows the lit picture over the pet behind it.
        let picture = deskCoverRoom()
        picture.sessions = picture.sessions.map { $0.name == "Web-DEMO-应用" ? seaSweepRemake($0, status: "busy") : $0 }
        let lit = ZoneView(frame: CGRect(origin: .zero, size: size))
        lit.still = true
        lit.update(picture)
        let litPixels = deskCoverPixels(lit.image(pixelScale: 1))
        picture.sessions = picture.sessions.map { $0.name == "Web-DEMO-应用" ? seaSweepRemake($0, status: "idle", since: Date() - 3000) : $0 }
        for s in picture.sessions where s.name == "Web-DEMO-应用" { picture.seen[s.id] = Date().timeIntervalSince1970 + 5 }
        lit.update(picture)
        let darkPixels = deskCoverPixels(lit.image(pixelScale: 1))
        var changed = 0
        if let litPixels, let darkPixels, let box = art.screenBox.map(fit.rect) {
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) where x >= 0 && y >= 0 && x < litPixels.width && y < litPixels.height {
                    if !litPixels.same(as: darkPixels, x, y, slack: 6) { changed += 1 }
                }
            }
        }
        check("desk cover 5: in a still, the desk's screen box changes between lit and dark (\(changed) px)", changed > 20)
    }
}

/// `--desk-cover-still <dir>`: the room with the desk layers (and the same room without them), whole and two islands at 2×.
@MainActor func deskCoverStill(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let restore = seaSweepSetup(NSTemporaryDirectory() + "desk-cover-s-\(getpid())")
    defer { restore() }
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    guard let scene = ZoneArt.scene else { return print("desk cover: no art") }
    let store = deskCoverRoom()
    let size = CGSize(width: 1200, height: 800)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    if let host = store.sessions.first(where: { $0.name == "AI-QA-云杉8" })?.id, let guest = store.sessions.first(where: { $0.name == "Web-星球漫游" })?.id {
        view.visit(guest, to: host, words: "端口改成 9000 了", until: Date() + 60)
        view.update(store)
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("desk cover: no \(name)") }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("desk cover: wrote \(name) \(image.width)x\(image.height)")
    }
    let with = view.image(pixelScale: 2)
    var holders: [CALayer] = []
    for d in scene.desks { if let h = view.deskLayer(ZoneDesk(zone: d.zone, index: d.index))?.holder { holders.append(h) } }
    if let boss = view.deskLayer(ZoneView.bossDeskKey) { holders.append(boss.holder) }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    for h in holders { h.isHidden = true }
    let without = view.image(pixelScale: 2)
    for h in holders { h.isHidden = false }
    CATransaction.commit()
    write(with, "panorama.png")
    write(without, "panorama-no-desks.png")
    // The islands, as the sample cropped them (picture pixels), at 2× in the view's pixels.
    let fit = ZoneFit(scene: scene.size, view: size)
    for (name, r) in [("Web", CGRect(x: 300, y: 180, width: 700, height: 680)), ("Ops", CGRect(x: 700, y: 330, width: 700, height: 680)),
                      ("AI", CGRect(x: 1100, y: 480, width: 700, height: 680)), ("Home", CGRect(x: 1500, y: 630, width: 700, height: 680))] {
        let v = fit.rect(r)
        let px = CGRect(x: v.minX * 2, y: v.minY * 2, width: v.width * 2, height: v.height * 2)
        write(with?.cropping(to: px), "crop-\(name).png")
        write(without?.cropping(to: px), "crop-\(name)-no-desks.png")
    }
    for s in store.sessions {
        let place = view.plan.place[s.id].map { "\($0)" } ?? "-"
        print("desk cover: \(s.name) \(s.status) \(place) z \(String(format: "%.1f", view.figureLayer(of: s.id)?.zPosition ?? -1))")
    }
}
