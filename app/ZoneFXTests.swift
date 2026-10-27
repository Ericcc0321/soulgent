import AppKit

/// Seaview's "working" parts on their own (ZoneFX.swift): the code on a busy screen, the breathing LED, the tool
/// badge and the sub-agents' mini figures. Checked through their small APIs, before any of them is in the room.

@MainActor func zoneFXTests() {
    // ── Tool icon: from the tool call's own name, as `pendingRequest` reads it ──
    let table: [(String?, ZoneToolFamily)] = [
        ("Bash", .terminal), ("BashOutput", .terminal), ("KillShell", .terminal),
        ("Edit", .pencil), ("Write", .pencil), ("MultiEdit", .pencil), ("NotebookEdit", .pencil),
        ("Read", .magnifier), ("Grep", .magnifier), ("Glob", .magnifier), ("LS", .magnifier),
        ("WebFetch", .globe), ("WebSearch", .globe),
        ("Task", .agents), ("Agent", .agents),
        ("mcp__netbox__netbox_get_objects", .thinking), ("AskUserQuestion", .thinking), ("SomethingNew", .thinking),
        ("", .thinking), (nil, .thinking),
    ]
    let wrong = table.filter { ZoneToolIcon.family(tool: $0.0) != $0.1 }.map { "\($0.0 ?? "nil")" }
    check("zone-fx: tool names map to their families, anything else or no tool is the thinking dots (wrong: \(wrong))", wrong.isEmpty)
    let line = Data(#"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"ok"},{"type":"tool_use","id":"t1","name":"Grep","input":{"pattern":"x"}}]}}"#.utf8)
    check("zone-fx: the tool's name is read from a transcript's tool_use line the way the card reads it",
        ZoneToolIcon.toolName(line) == "Grep" && ZoneToolIcon.toolName(Data("{}".utf8)) == nil)

    // ── Tool badge ──
    var badges: [ZoneToolFamily: [UInt8]] = [:]
    var badgeOK = true
    for family in ZoneToolFamily.allCases {
        guard let image = ZoneToolIcon.badge(family, size: 22, scale: 2), image.width == 44, image.height == 44,
            let px = zoneFXPixels(image)
        else { badgeOK = false; continue }
        let solid = stride(from: 3, to: px.count, by: 4).filter { px[$0] > 200 }.count
        let bright = stride(from: 0, to: px.count, by: 4).filter { px[$0] > 200 && px[$0 + 1] > 200 && px[$0 + 2] > 200 }.count
        if solid < 900 || bright < 25 { badgeOK = false }
        badges[family] = px
    }
    let families = ZoneToolFamily.allCases
    var distinct = true
    for i in families.indices { for j in families.indices where j > i { if badges[families[i]] == badges[families[j]] { distinct = false } } }
    check("zone-fx: every family's badge is a filled 22-point disc with a light glyph on it", badgeOK && badges.count == families.count)
    check("zone-fx: no two families draw the same badge", distinct && badges.count == families.count)

    // ── Code on a screen ──
    // Web_5's screen in the 2400 × 1600 render, top left, top right, bottom right, bottom left.
    let quad = [CGPoint(x: 582.456, y: 624.1171), CGPoint(x: 605.6301, y: 597.2839), CGPoint(x: 626.3234, y: 620.6868), CGPoint(x: 603.1492, y: 647.52)]
    let box = zoneFXBounds(quad)
    let screen = ZoneCodeScreen(quad: quad, deskID: "Web_5")
    let mask = screen.layer.mask as? CAShapeLayer
    let local = quad.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
    let middle = CGPoint(x: local.map(\.x).reduce(0, +) / 4, y: local.map(\.y).reduce(0, +) / 4)
    let pathBox = mask?.path?.boundingBoxOfPath ?? .null
    check("zone-fx: a code screen sits on its quad's bounds and is clipped to the quad itself",
        abs(screen.layer.frame.minX - box.minX) < 0.01 && abs(screen.layer.frame.minY - box.minY) < 0.01
            && abs(screen.layer.frame.width - box.width) < 0.01 && abs(screen.layer.frame.height - box.height) < 0.01
            && abs(pathBox.width - box.width) < 0.01 && abs(pathBox.height - box.height) < 0.01
            && mask?.path?.contains(middle) == true && mask?.path?.contains(CGPoint(x: 1, y: 1)) == false
            && mask?.path?.contains(CGPoint(x: box.width - 1, y: box.height - 1)) == false)
    let scroll = zoneFXAnimations(screen.layer)
    check("zone-fx: the code scrolls in one repeating Core Animation loop of 6 to 10 s",
        scroll.count == 1 && scroll.first.map { $0.repeatCount == .infinity && $0.duration >= 6 && $0.duration <= 10 } == true
            && zoneFXLines(screen.layer) >= 4)
    let other = ZoneCodeScreen(quad: quad, deskID: "Web_6")
    let ids = ["Web", "Ops", "AI", "Home"].flatMap { z in (1...8).map { "\(z)_\($0)" } }
    let phases = Set(ids.map { (ZoneCodeScreen.phase($0) * 1000).rounded() })
    check("zone-fx: each desk's screen starts at its own point of the loop, the same on every launch",
        ZoneCodeScreen.phase("Web_5") != ZoneCodeScreen.phase("Web_6") && phases.count >= 30
            && ZoneCodeScreen.phase("Web_5") == ZoneCodeScreen.phase("Web_5")
            && zoneFXAnimations(other.layer).first?.timeOffset != scroll.first?.timeOffset
            && ids.allSatisfy { (0..<1).contains(ZoneCodeScreen.phase($0)) })
    let same = screen.layer
    screen.isOn = false
    let offOK = screen.layer.isHidden && zoneFXAnimations(screen.layer).isEmpty
    screen.isOn = true
    check("zone-fx: a screen switches off and on again without being rebuilt",
        offOK && screen.layer === same && !screen.layer.isHidden && zoneFXAnimations(screen.layer).count == 1)
    let frozen = ZoneCodeScreen(quad: quad, deskID: "Web_5", animated: false)
    check("zone-fx: a still (or Reduce Motion) screen shows its code without any animation",
        zoneFXAnimations(frozen.layer).isEmpty && zoneFXLines(frozen.layer) >= 4 && !frozen.layer.isHidden)

    // ── Breathing LED ──
    let led = CALayer()
    led.opacity = 1
    ZoneBreath.apply(to: led, deskID: "Web_5", waiting: false)
    let breath = led.animation(forKey: ZoneBreath.key) as? CABasicAnimation
    check("zone-fx: a busy desk's LED breathes between 1 and about 0.55 over about 3 s, round and round",
        breath.map {
            $0.keyPath == "opacity" && ($0.fromValue as? Float) == 1 && abs(($0.toValue as? Float ?? 0) - 0.55) < 0.01 && $0.autoreverses
                && abs($0.duration * 2 - 3) < 0.01 && $0.repeatCount == .infinity
        } == true && ZoneBreath.isBreathing(led))
    let led2 = CALayer()
    ZoneBreath.apply(to: led2, deskID: "Ops_3", waiting: false)
    check("zone-fx: desks breathe out of step", led2.animation(forKey: ZoneBreath.key)?.timeOffset != breath?.timeOffset)
    ZoneBreath.apply(to: led, deskID: "Web_5", waiting: true)
    let steady = !ZoneBreath.isBreathing(led) && led.opacity == 1
    ZoneBreath.apply(to: led2, deskID: "Ops_3", waiting: false)
    ZoneBreath.remove(from: led2)
    check("zone-fx: a waiting desk's LED is steady, and the breathing comes off when asked", steady && !ZoneBreath.isBreathing(led2))

    // ── Sub-agent mini figures ──
    // The helpers' pets as set in the two settings (unset they are both the flame).
    let helperKeys = ["helperPetClaude", "helperPetCodex"], helperWere = helperKeys.map { UserDefaults.standard.object(forKey: $0) }
    UserDefaults.standard.set("test-pet-claude", forKey: "helperPetClaude")
    UserDefaults.standard.set("test-pet-codex", forKey: "helperPetCodex")
    func member(_ description: String, _ type: String) -> ZoneSubagentFigures.Member {
        ZoneSubagentFigures.Member(agent: OfficeSubagents.Agent(description: description, model: "claude-sonnet-5"), type: type)
    }
    check("zone-fx: a Codex sub-agent gets the pet set for Codex helpers, any other the one set for the rest",
        ZoneSubagentFigures.pet(for: member("x", "codex:codex-rescue")) == "test-pet-codex"
            && ZoneSubagentFigures.pet(for: member("x", "Codex-Helper")) == "test-pet-codex"
            && ZoneSubagentFigures.pet(for: member("Codex writes it", "general-purpose")) == "test-pet-claude"
            && ZoneSubagentFigures.pet(for: member("x", "")) == "test-pet-claude")
    let a = CGPoint(x: 100, y: 200), b = CGPoint(x: 160, y: 140)
    let five = (0..<5).map { member("a\($0)", $0 == 1 ? "codex:codex-rescue" : "general-purpose") }
    let spots5 = ZoneSubagentFigures.spots(five, from: a, to: b)
    let spots3 = ZoneSubagentFigures.spots(Array(five.prefix(3)), from: a, to: b)
    let spots4 = ZoneSubagentFigures.spots(Array(five.prefix(4)), from: a, to: b)
    check("zone-fx: three figures at most, then a +N pill for the rest",
        spots5.filter { $0.pet != nil }.count == 3 && spots5.last?.more == 2 && spots5.map(\.pet) == ["test-pet-claude", "test-pet-codex", "test-pet-claude", nil]
            && spots3.count == 3 && spots3.allSatisfy { $0.more == 0 } && spots4.last?.more == 1 && spots4.count == 4
            && ZoneSubagentFigures.spots([], from: a, to: b).isEmpty)
    func onSegment(_ p: CGPoint) -> Bool {
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y), len2 = d.dx * d.dx + d.dy * d.dy
        let t = ((p.x - a.x) * d.dx + (p.y - a.y) * d.dy) / len2
        let q = CGPoint(x: a.x + t * d.dx, y: a.y + t * d.dy)
        return t >= 0 && t <= 1 && hypot(p.x - q.x, p.y - q.y) < 0.01
    }
    let feet = spots5.map(\.foot)
    check("zone-fx: the figures and the pill stand on the desk edge, spread along it in order",
        feet.allSatisfy(onSegment) && Set(feet.map { "\($0)" }).count == feet.count
            && zip(feet, feet.dropFirst()).allSatisfy { hypot($0.x - a.x, $0.y - a.y) < hypot($1.x - a.x, $1.y - a.y) })
    // Pets drawn 40 pixels tall in a 96 × 104 frame, a different picture for each.
    func fakeFrame(_ shade: UInt8) -> OfficePets.Frame? {
        let c = CGContext(data: nil, width: 96, height: 104, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: CGFloat(shade) / 255, green: 0.5, blue: 0.5, alpha: 1))
        c.fill(CGRect(x: 30, y: 4, width: 36, height: 40))
        return c.makeImage().map { OfficePets.Frame(image: $0, left: 30, top: 60, right: 65, bottom: 99) }
    }
    let crab = fakeFrame(10), hacker = fakeFrame(250)
    let petHeight: CGFloat = 114
    let k35 = ZoneSubagentFigures.height
    // A long edge: room for all of them at full size.
    let la = CGPoint(x: 100, y: 200), lb = CGPoint(x: 340, y: 160)
    let figures = ZoneSubagentFigures.layer(Array(five.prefix(3)), from: la, to: lb, petHeight: petHeight, scale: 1) {
        $0 == "test-pet-claude" ? crab : $0 == "test-pet-codex" ? hacker : nil
    }
    let placed3 = ZoneSubagentFigures.place(Array(five.prefix(3)), from: la, to: lb, petHeight: petHeight, scale: 1) {
        $0 == "test-pet-claude" ? crab : $0 == "test-pet-codex" ? hacker : nil
    }
    let drawn = figures.sublayers ?? []
    let tallOK = drawn.allSatisfy { abs($0.frame.height * 40 / 104 - petHeight * k35) < 0.5 }
    func onEdge(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Bool {
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y), len2 = d.dx * d.dx + d.dy * d.dy
        let t = ((p.x - a.x) * d.dx + (p.y - a.y) * d.dy) / len2
        return t >= 0 && t <= 1 && hypot(p.x - (a.x + t * d.dx), p.y - (a.y + t * d.dy)) < 0.01
    }
    check("zone-fx: mini figures are half of 35% of a pet's height, each its own pet's picture, feet on the edge, the lower one in front",
        abs(k35 - 0.35 / 2) < 0.001 && drawn.count == 3 && tallOK && drawn.map(\.name) == placed3.sorted { $0.foot.y < $1.foot.y }.map(\.pet)
            && drawn.allSatisfy { ($0.contents as! CGImage) === ($0.name == "test-pet-codex" ? hacker : crab)!.image }
            && placed3.allSatisfy { onEdge($0.foot, la, lb) }
            && zip(drawn, placed3.sorted { $0.foot.y < $1.foot.y }).allSatisfy { abs($0.frame.minY + $0.frame.height * 100 / 104 - $1.foot.y) < 0.5 })
    // A wide pet (the crab is about 86 × 57) fits the same square: no wider than a figure is tall.
    let wideFrame: OfficePets.Frame? = crab.map { OfficePets.Frame(image: $0.image, left: 5, top: 26, right: 90, bottom: 82) }
    let wideOne = ZoneSubagentFigures.layer([member("w", "")], from: la, to: lb, petHeight: petHeight, scale: 1) { _ in wideFrame }
    check("zone-fx: a wide pet's figure is fitted by its width, so it is no wider than a figure is tall",
        wideOne.sublayers.map { $0.count == 1 && abs($0[0].frame.width * 86 / 96 - petHeight * k35) < 0.5 } == true)
    let withPill = ZoneSubagentFigures.layer(five, from: la, to: lb, petHeight: petHeight, scale: 1) { _ in crab }
    check("zone-fx: with more than three running, the layer holds three figures and a +N pill",
        withPill.sublayers?.count == 4 && withPill.sublayers?.filter { $0.name == "more" }.count == 1)
    // A short edge (a desk's, 73 px) with three wide crabs and a pill: smaller, side by side, none over another.
    let sa = CGPoint(x: 559, y: 666), sb = CGPoint(x: 629, y: 688)
    let tight = ZoneSubagentFigures.place(five, from: sa, to: sb, petHeight: petHeight, scale: 1) { _ in wideFrame }
    var apart = tight.count >= 2
    for i in tight.indices { for j in tight.indices where j > i && tight[i].drawn.insetBy(dx: 0.01, dy: 0.01).intersects(tight[j].drawn) { apart = false } }
    let tightFigures = tight.filter { $0.pet != nil }
    check("zone-fx: on a short edge the figures stand side by side, none overlapping, on the edge, 45–100% of the figure size across; the rest go in the +N pill",
        apart && tight.allSatisfy { onEdge($0.foot, sa, sb) } && !tightFigures.isEmpty
            && tightFigures.allSatisfy { max($0.drawn.height, $0.drawn.width) <= petHeight * k35 + 0.01 && max($0.drawn.height, $0.drawn.width) >= petHeight * k35 * ZoneSubagentFigures.smallest - 0.01 }
            && tight.last?.pet == nil && tight.last?.more == 5 - tightFigures.count)
    // The screen right over the edge's middle: they slide or shrink so none covers it.
    let screenQuad = [CGPoint(x: 582, y: 624), CGPoint(x: 605, y: 597), CGPoint(x: 626, y: 620), CGPoint(x: 603, y: 647)]
    let clear = ZoneSubagentFigures.place(Array(five.prefix(3)), from: sa, to: sb, petHeight: petHeight, scale: 1, avoid: screenQuad) {
        $0 == "test-pet-claude" ? crab : hacker
    }
    let covered = ZoneSubagentFigures.hidden(screenQuad, by: clear.map(\.drawn)) > ZoneSubagentFigures.screenHidden
    check("zone-fx: the mini figures hide at most 12% of the screen's quad, so the screen stays visible", !clear.isEmpty && !covered)
    for (key, was) in zip(helperKeys, helperWere) { if let was { UserDefaults.standard.set(was, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    check("zone-fx: with neither helper setting set, every helper is the built-in flame",
        ZoneSubagentFigures.pet(for: member("x", "codex:codex-rescue")) == PetSources.builtInID && ZoneSubagentFigures.pet(for: member("x", "")) == PetSources.builtInID)

    // On a desk's edge: a box as wide as the square and `deskTall` of it tall. The flame (about square) stands lower than
    // the square; every pet fits the box and fills it one way or the other.
    let sq: CGFloat = 60, flat = sq * ZoneSubagentFigures.deskTall
    let flameCut = ZoneSubagentFigures.deskCut(PetSources.builtInID, square: sq)
    check("zone-fx: on a desk's edge the flame is cut to the flat box's height (\(String(format: "%.1f", (flameCut?.inkWide ?? 0))) wide, \(String(format: "%.1f", flameCut.map { CGFloat($0.idle.tall) * $0.k } ?? 0)) tall in a \(Int(sq)) square)",
        flameCut.map { abs(CGFloat($0.idle.tall) * $0.k - flat) < 0.5 && $0.inkWide <= sq + 0.01 } == true)
    let deskPets = Array(Set(Pets.shared.ids + [PetSources.builtInID])).sorted().prefix(30)
    let fits = deskPets.compactMap { ZoneSubagentFigures.deskCut($0, square: sq) }.allSatisfy { c in
        let w = c.inkWide, t = CGFloat(c.idle.tall) * c.k
        return w <= sq + 0.01 && t <= flat + 0.01 && (abs(w - sq) < 0.5 || abs(t - flat) < 0.5)
    }
    check("zone-fx: on a desk's edge every pet fits the flat box and fills it (\(deskPets.count) pets): a wide one as wide as the square, a tall one as tall as the box", fits)

    // ── Walking frames ──
    let route = [CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 130), CGPoint(x: 300, y: 130), CGPoint(x: 300, y: 90), CGPoint(x: 200, y: 90)]
    // a leg up or down keeps the facing it had (the first, the next leg's), rather than turn ahead of the next leg.
    check("zone-fx: a walk runs right on a leg going right, left on one going left, and a straight up or down leg keeps the way it faced (the first: the next leg's)",
        ZoneWalk.rows(route) == [1, 1, 1, 2] && ZoneWalk.rows([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 50)]) == [1]
            && ZoneWalk.rows([CGPoint(x: 9, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 40)]) == [2, 2])
    func frameImage(_ v: UInt8) -> CGImage {
        let c = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(red: CGFloat(v) / 255, green: 0, blue: 0, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return c.makeImage()!
    }
    let runRight = (0..<8).map { frameImage(UInt8(10 + $0)) }, runLeft = (0..<8).map { frameImage(UInt8(100 + $0)) }
    let walkSteps = ZoneWalk.steps([1: runRight, 2: runLeft], route: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 0, y: 0)], seconds: 2)
    let firstHalf = (walkSteps?.values ?? []).prefix(10).allSatisfy { v in runRight.contains { $0 === (v as AnyObject) } }
    let secondHalf = (walkSteps?.values ?? []).suffix(10).allSatisfy { v in runLeft.contains { $0 === (v as AnyObject) } }
    check("zone-fx: the running frames go a tenth of a second each, the right-running row out and the left-running row back, in CA keyframes",
        walkSteps.map { $0.calculationMode == .discrete && $0.duration == 2 && $0.keyPath == "contents" && ($0.values?.count ?? 0) >= 20 } == true
            && firstHalf && secondHalf)

    // ── The office's disco light ──
    let disco = ZoneDisco.make()
    ZoneDisco.shape(disco, wide: 60, high: 96, ceiling: 400, moving: true)
    let rig = ZoneDisco.rig(disco)
    let kinds = ["cone", "pool", "spot", "laser", "ball"].map { ZoneDisco.parts(disco, $0).count }
    let loops = ZoneDisco.moving(disco).compactMap { $0.animationKeys()?.first.flatMap($0.animation(forKey:)) as? CAKeyframeAnimation }
    check("zone-fx: the spotlight is the office's disco light: ball, five spots, three lasers, cone and pool, scaled to the pet",
        kinds == [2, 2, OfficeView.spots.count, OfficeView.lasers.count, 1] && abs((rig?.affineTransform().a ?? 0) - 2) < 0.001
            && ZoneDisco.parts(disco, "ball").first?.contents != nil && ZoneDisco.parts(disco, "laser").first?.sublayers?.first?.contents != nil)
    check("zone-fx: its ball, spots and lasers move in CA steps on the office's beat, twelve a second",
        loops.count == 1 + OfficeView.spots.count + OfficeView.lasers.count
            && loops.allSatisfy { $0.calculationMode == .discrete && $0.repeatCount == .infinity && abs($0.duration / Double($0.values?.count ?? 1) - 1.0 / 12) < 1e-9 })
    ZoneDisco.hold(disco, true)
    let held = ZoneDisco.moving(disco).allSatisfy { $0.speed == 0 }
    ZoneDisco.hold(disco, false)
    let still = ZoneDisco.make()
    ZoneDisco.shape(still, wide: 60, high: 96, ceiling: 400, moving: false)
    check("zone-fx: the light holds still while Orca is behind, and a picture's light has no loops",
        held && ZoneDisco.moving(disco).allSatisfy { $0.speed == 1 } && ZoneDisco.moving(still).allSatisfy { ($0.animationKeys() ?? []).isEmpty })

    // ── No timers ──
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let text = (try? String(contentsOf: sources.appendingPathComponent("ZoneFX.swift"), encoding: .utf8)) ?? ""
    check("zone-fx: ZoneFX.swift schedules no Timer, no CVDisplayLink, no TimelineView",
        text.count > 2_000 && !text.contains("Timer") && !text.contains("CVDisplayLink") && !text.contains("TimelineView"))
}

private func zoneFXBounds(_ quad: [CGPoint]) -> CGRect {
    var r = CGRect.null
    for p in quad { r = r.union(CGRect(origin: p, size: .zero)) }
    return r
}

/// Every animation in a layer tree.
@MainActor private func zoneFXAnimations(_ layer: CALayer) -> [CAAnimation] {
    (layer.animationKeys() ?? []).compactMap { layer.animation(forKey: $0) } + (layer.sublayers ?? []).flatMap(zoneFXAnimations)
}

/// How many code lines a screen's layers hold.
@MainActor private func zoneFXLines(_ layer: CALayer) -> Int {
    (layer.name == "code" ? (layer.value(forKey: "lines") as? Int ?? 0) : 0) + (layer.sublayers ?? []).reduce(0) { $0 + zoneFXLines($1) }
}

private func zoneFXPixels(_ image: CGImage) -> [UInt8]? {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let ok = data.withUnsafeMutableBytes { buffer -> Bool in
        guard let c = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        c.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    return ok ? data : nil
}

/// `--zone-fx-still <png>`: one busy desk (Web_5) of the night render with lit screens, at twice the render's pixels:
/// the code screen, the LED at a moment of its breath, a terminal badge over its pet, two Claude and one Codex sub-agent.
/// Read from the room's own art, `themes/seaview/assets/`.
@MainActor func zoneFXStill(_ path: String) {
    let panel = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let out = panel.appendingPathComponent("themes/seaview/assets")  // the room's own art
    func picture(_ name: String) -> CGImage? {
        CGImageSourceCreateWithURL(out.appendingPathComponent(name) as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }
    guard let data = FileManager.default.contents(atPath: out.appendingPathComponent("points.json").path),
        let scene = ZoneScene.parse(data), let desk = scene.desks.first(where: { $0.zone == "Web" && $0.index == 5 }),
        let lit = picture("night_screens.png")
    else { print("zone-fx still: no render or points in \(out.path)"); return }
    let id = "Web_5"
    let crop = CGRect(x: 520, y: 540, width: 240, height: 200)
    let zoom: CGFloat = 2
    let root = CALayer()
    root.isGeometryFlipped = true
    root.frame = CGRect(x: 0, y: 0, width: crop.width * zoom, height: crop.height * zoom)
    let world = CALayer()  // scene pixels inside: its bounds start at the crop's corner
    world.anchorPoint = .zero
    world.bounds = crop
    world.position = .zero
    world.setAffineTransform(CGAffineTransform(scaleX: zoom, y: zoom))
    root.addSublayer(world)
    let base = CALayer()
    base.frame = CGRect(origin: .zero, size: scene.size)
    base.contents = lit
    world.addSublayer(base)
    // The LED: the lit-LED render's pixels round the strip, as the room paints it, at a moment of its breath.
    if let leds = picture("night_leds.png"), let quad = desk.led {
        var box = CGRect.null
        for p in quad { box = box.union(CGRect(origin: p, size: .zero)) }
        box = box.insetBy(dx: -scene.upright * 0.4, dy: -scene.upright * 0.4)
        let led = CALayer()
        led.contents = leds
        led.contentsRect = CGRect(x: box.minX / scene.size.width, y: box.minY / scene.size.height,
                                  width: box.width / scene.size.width, height: box.height / scene.size.height)
        led.frame = box
        led.opacity = ZoneBreath.opacity(at: 0.6, deskID: id)
        world.addSublayer(led)
    }
    let screen = ZoneCodeScreen(quad: desk.screen, deskID: id, scale: 2 * zoom, animated: false)
    world.addSublayer(screen.layer)
    // Its pet, at its spot, as the room sizes pets (standing, 150 px, by its idle box).
    OfficePets.shared.synchronous = true
    let tall = scene.petHeight
    var head = CGPoint(x: desk.seat.x, y: desk.seat.y - tall)
    if let idle = OfficePets.shared.frame(PetSources.builtInID, row: 0, column: 0) {
        let k = ZoneScene.petFactor(tall: idle.tall, wide: idle.wide, target: tall)
        let middle = CGFloat(idle.left + idle.right + 1) / 2
        let pet = CALayer()
        pet.frame = CGRect(x: desk.seat.x - middle * k, y: desk.seat.y - CGFloat(idle.bottom + 1) * k,
                           width: CGFloat(idle.image.width) * k, height: CGFloat(idle.image.height) * k)
        pet.contents = idle.image
        world.addSublayer(pet)
        head = CGPoint(x: desk.seat.x, y: pet.frame.minY + CGFloat(idle.top) * k)
    }
    // The badge: 18 points in the 1180-point window, where a scene pixel is about half a point.
    let side: CGFloat = 18 / 0.494
    let badge = CALayer()
    badge.contents = ZoneToolIcon.badge(.terminal, size: 18, scale: 0.494 * 2 * zoom)
    badge.frame = CGRect(x: head.x - side / 2, y: head.y - side - 3, width: side, height: side)
    world.addSublayer(badge)
    // Sub-agents on the desk's near edge (the room's own edge, a little in from the rim), clear of the screen.
    if let near = desk.near, !desk.top.isEmpty {
        var middle = CGPoint.zero
        for p in desk.top { middle = CGPoint(x: middle.x + p.x / CGFloat(desk.top.count), y: middle.y + p.y / CGFloat(desk.top.count)) }
        func pull(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + (middle.x - p.x) * 0.05, y: p.y + (middle.y - p.y) * 0.05) }
        let members = [("general-purpose", "改样式"), ("codex:codex-rescue", "Codex 写脚本"), ("Explore", "查代码")].map {
            ZoneSubagentFigures.Member(agent: OfficeSubagents.Agent(description: $0.1, model: ""), type: $0.0)
        }
        world.addSublayer(ZoneSubagentFigures.layer(members, from: pull(near.0), to: pull(near.1), petHeight: tall, scale: 0.494, avoid: desk.screen) {
            OfficePets.shared.frame($0, row: 0, column: 0)
        })
    }
    let px = root.frame.size
    guard let ctx = CGContext(data: nil, width: Int(px.width), height: Int(px.height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    ctx.translateBy(x: 0, y: root.frame.height)
    ctx.scaleBy(x: 1, y: -1)
    root.render(in: ctx)
    guard let image = ctx.makeImage(),
        let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(file, image, nil)
    print(CGImageDestinationFinalize(file) ? "zone-fx still: wrote \(path)" : "zone-fx still: could not write \(path)")
}

/// `--zone-walk-strip <png>`: a walk's running frames as the room plays them, one cell a twelfth of a second, for a pet
/// going right and then left (two legs), each cell marked with the row it shows (→ 1, ← 2).
@MainActor func zoneWalkStrip(_ path: String, pet: String = PetSources.builtInID) {
    OfficePets.shared.synchronous = true
    let route = [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 300, y: 40), CGPoint(x: 0, y: 40)]
    guard let steps = ZoneView.runningSteps(pet, route: route, seconds: 2.4), let values = steps.values as? [CGImage], !values.isEmpty
    else { print("zone walk strip: no running frames for \(pet)"); return }
    let right = Set((0..<8).compactMap { OfficePets.shared.runFrame(pet, facing: ZoneWalk.right, column: $0)?.image }.map { ObjectIdentifier($0) })
    let cell = 64, count = min(values.count, 24)
    let canvas = OfficeCanvas(CGSize(width: cell * 12, height: (cell + 14) * ((count + 11) / 12)))
    for i in 0..<count {
        let x = CGFloat(i % 12 * cell), y = CGFloat(i / 12 * (cell + 14))
        canvas.card(CGRect(x: x + 1, y: y + 1, width: CGFloat(cell - 2), height: CGFloat(cell + 12)), radius: 4, 0x172033, 1, edge: 0x3A4A66)
        let goingRight = right.contains(ObjectIdentifier(values[i]))
        canvas.text(goingRight ? "→ 1" : "← 2", in: CGRect(x: x, y: y + CGFloat(cell) - 1, width: CGFloat(cell), height: 13), size: 9, weight: .semibold,
                    goingRight ? 0x9FD4FF : 0xFFB3C7, align: .center)
        canvas.ctx.saveGState()
        canvas.ctx.translateBy(x: x + 4, y: y + CGFloat(cell) - 4)
        canvas.ctx.scaleBy(x: 1, y: -1)
        canvas.ctx.interpolationQuality = .none
        canvas.ctx.draw(values[i], in: CGRect(x: 0, y: 0, width: CGFloat(cell - 8), height: CGFloat(cell - 8)))
        canvas.ctx.restoreGState()
    }
    guard let image = canvas.image(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
    print("zone walk strip: wrote \(path), \(values.count) frames over 2.4 s")
}

// ───────── Fable sessions' aura (Blaze Mode) ─────────

/// A Claude Code session's model read from its transcript's tail, and the gold aura a Fable session's pet
/// wears in Seaview (busy: full flames and arcs; else a calm glow). `tools/dev/run-tests.sh --aura-only` runs these alone.
@MainActor func auraTests() {
    auraModelTests()
    auraRoomTests()
}

/// Every animation on a layer and the layers in it.
@MainActor func auraAnimations(_ layer: CALayer) -> [String] {
    (layer.animationKeys() ?? []) + (layer.mask.map(auraAnimations) ?? []) + (layer.sublayers ?? []).flatMap(auraAnimations)
}

/// Whether any layer in this tree is named so.
@MainActor func auraNamed(_ layer: CALayer, _ name: String) -> Bool {
    layer.name == name || (layer.sublayers ?? []).contains { auraNamed($0, name) }
}

@MainActor func auraRoomTests() {
    guard ZoneArt.scene != nil else { return check("aura: the Seaview art", false) }
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    defer {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    let crowd = auraCrowd()
    let store = crowd.store
    let size = CGSize(width: 1180, height: 790)
    // In a window, as the panel's is: without one Core Animation has nowhere to commit the loops to, and drops them.
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.calmOverride = false
    let roomWindow = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    roomWindow.contentView = view
    roomWindow.orderFrontRegardless()
    defer {
        roomWindow.orderOut(nil)
        roomWindow.contentView = nil
    }
    view.update(store)
    let busy = view.aura(of: crowd.busy), calm = view.aura(of: crowd.calm)
    check("aura: a Fable session's figure wears the aura, under its pet, in its own layer; an Opus one and the others none",
        busy != nil && calm != nil && busy?.superlayer === view.figureLayer(of: crowd.busy)
            && busy.map { a in (view.figureLayer(of: crowd.busy)?.sublayers ?? []).firstIndex { $0 === a } ?? 99 } ?? 99
                < (view.figureLayer(of: crowd.busy)?.sublayers?.firstIndex { $0.contents != nil && $0.name == nil } ?? -1)
            && view.aura(of: crowd.opus) == nil && store.sessions.filter { !$0.isFable }.allSatisfy { view.aura(of: $0.id) == nil })
    check("aura: on the sofa and in the line too", view.aura(of: crowd.sofa) != nil && view.aura(of: crowd.line) != nil)
    func high(_ a: CALayer?) -> CGFloat { a.flatMap { ZoneAura.part($0, "flame") }?.bounds.height ?? 0 }
    // the lightning lives in the figure's own `bolts` holder, over its pet.
    func boltsOf(_ a: CALayer?) -> CALayer? { a === busy ? view.bolts(of: crowd.busy) : a === calm ? view.bolts(of: crowd.calm) : nil }
    func pool(_ a: CALayer?, _ name: String) -> [CALayer] { (boltsOf(a).flatMap { ZoneAura.part($0, name) }?.sublayers ?? []).filter { $0.name == "bolt" } }
    func sparks(_ a: CALayer?) -> [CALayer] { (boltsOf(a).flatMap { ZoneAura.part($0, "arc") }?.sublayers ?? []).filter { $0.name == "spark" } }
    func arcs(_ a: CALayer?) -> Bool { pool(a, "arc").contains { $0.animation(forKey: "arcs") != nil } }
    func flares(_ a: CALayer?) -> Bool { a.flatMap { ZoneAura.part($0, "arcFlare") }?.animation(forKey: "flare") != nil }
    check("aura: busy it has arcs and the big bursts' flare, idle rare sparks and no flare",
        arcs(busy) && arcs(calm) && flares(busy) && !flares(calm) && busy.map(ZoneAura.isBusy) == true && calm.map(ZoneAura.isBusy) == false)
    let busyHigh = high(busy)
    // crackling all the time, busy; a rare spark idle.
    let storm = ZoneAura.storm(seed: crowd.busy, busy: true), idleStorm = ZoneAura.storm(seed: crowd.calm, busy: false)
    func spans(_ st: ZoneAura.Storm) -> [Double] { zip(st.bursts, st.bursts.dropFirst()).map { $1 - $0 } + [st.period + (st.bursts.first ?? 0) - (st.bursts.last ?? 0)] }
    func boltsIn(_ st: ZoneAura.Storm, _ at: Double) -> Int {
        Dictionary(grouping: st.flickers, by: \.bolt).values.filter { fs in (fs[0].at - at + st.period).truncatingRemainder(dividingBy: st.period) < 0.25 }.count
    }
    let byBolt = Dictionary(grouping: storm.flickers + idleStorm.flickers.map { f in
        ZoneAura.Flicker(bolt: 10_000 + f.bolt, slot: f.slot, at: f.at, on: f.on, art: f.art, alpha: f.alpha, fade: f.fade) }) { $0.bolt }
    var storms: [String] = []
    if !spans(storm).allSatisfy({ $0 >= 0.35 && $0 <= 0.8 }) { storms.append("busy gaps \(spans(storm).map { Int($0 * 100) })") }
    let bigSpans = zip(storm.bigs, storm.bigs.dropFirst()).map { $1 - $0 } + [storm.period + (storm.bigs.first ?? 0) - (storm.bigs.last ?? 0)]
    if storm.bigs.count < 3 || !bigSpans.dropLast().allSatisfy({ $0 >= 4 && $0 <= 7 }) || !(4...7.5).contains(bigSpans.last ?? 0) { storms.append("strike gaps \(bigSpans)") }
    if !storm.bursts.allSatisfy({ b in storm.bigs.contains(b) ? boltsIn(storm, b) == 1 : (1...2).contains(boltsIn(storm, b)) }) { storms.append("trees a discharge") }
    if !spans(idleStorm).allSatisfy({ $0 >= 8 && $0 <= 14 }) || !idleStorm.bursts.allSatisfy({ boltsIn(idleStorm, $0) == 1 }) || !idleStorm.bigs.isEmpty { storms.append("idle sparks") }
    for (_, fs) in byBolt where fs.count < 2 || fs.count > 4 || zip(fs, fs.dropFirst()).contains(where: { $0.art == $1.art }) || fs.dropFirst().contains(where: { $0.alpha >= fs[0].alpha }) {
        storms.append("a bolt's flickers"); break
    }
    let spanned = byBolt.values.filter { fs in fs.allSatisfy { $0.at + $0.on <= storm.period - 0.01 && $0.at > 0.01 } }.map { fs in (fs.map { $0.at + $0.on }.max() ?? 0) - fs[0].at }
    if !spanned.allSatisfy({ $0 >= 0.195 && $0 <= 0.305 }) { storms.append("a tree's length \(spanned.map { Int($0 * 1000) }.filter { $0 < 195 || $0 > 305 })") }
    if !byBolt.values.allSatisfy({ fs in fs.last.map { $0.fade >= 0.15 && $0.fade <= 0.25 } == true && fs.dropLast().allSatisfy { $0.fade == 0 }
        && Set(fs.map { $0.art / ZoneAura.boltVariants }).count == 1 }) { storms.append("a tree's afterglow or trunk") }
    let lives = byBolt.filter { $0.key < 10_000 }.values.map { fs in (fs[0].at, fs.last!.at + fs.last!.on + fs.last!.fade) }
    if lives.contains(where: { l in lives.filter { $0.0 <= l.0 && $0.1 > l.0 }.count > 3 }) { storms.append("over three trees at once") }
    if ZoneAura.lit(ZoneAura.stillPhase, storm: storm).isEmpty || ZoneAura.lit(ZoneAura.stillPhase, storm: idleStorm).isEmpty { storms.append("still") }
    check("aura: busy, a tree (often two) every 0.35–0.8 s and a strike every 4–7 s; idle, one small tree every 8–14 s; each tree 2–4 flickers over 200–300 ms, the same trunk, a fresh shape each, the first the brightest, then a 150–250 ms afterglow; never over three at once; one in the still\(storms.isEmpty ? "" : ": " + storms.joined(separator: ", "))",
        storms.isEmpty)
    // the crawling arcs: busy, never under `arcsLitBusy` lit; across a loop each layer visits ≥ 20 perimeter points (idle, hopping slower, ≥ 10).
    var crackle: [String] = []
    let busyArcs = ZoneAura.arcLoops(seed: crowd.busy, busy: true), idleArcs = ZoneAura.arcLoops(seed: crowd.calm, busy: false)
    let litNow = stride(from: 0.0, to: busyArcs.first?.period ?? 0, by: 0.005).map { ZoneAura.arcsLit($0, seed: crowd.busy, busy: true) }
    if (litNow.min() ?? 0) < ZoneAura.arcsLitBusy { crackle.append("busy arcs lit \(litNow.min() ?? 0)–\(litNow.max() ?? 0)") }
    if busyArcs.count < 8 || idleArcs.count != ZoneAura.idleArcs { crackle.append("\(busyArcs.count) busy, \(idleArcs.count) idle layers") }
    if busyArcs.contains(where: { Set($0.hops.map(\.spot)).count < 20 }) || idleArcs.contains(where: { Set($0.hops.map(\.spot)).count < 10 }) { crackle.append("a layer stuck to few spots") }
    check("aura: crawling arcs hop round the whole outline, busy ≥ \(ZoneAura.arcsLitBusy) lit at every moment, every layer ≥ 20 spots a loop\(crackle.isEmpty ? "" : ": " + crackle.joined(separator: ", "))",
        crackle.isEmpty)
    // the bolts lie on the body: drawn on the busy pet's own frame, every line inside its drawn box grown to 1.08×,
    // each 0.15–0.5 body heights from end to end; their holder over the pet's sprite.
    var onBody: [String] = []
    let busyFigure = view.figureLayer(of: crowd.busy), busySprite = busyFigure?.sublayers?.first { $0.contents != nil && $0.name == nil }
    if let sprite = busySprite?.contents.map({ $0 as AnyObject }).flatMap({ CFGetTypeID($0) == CGImage.typeID ? ($0 as! CGImage) : nil }),
       let box = ZoneAura.drawnBox(sprite)?.rect {
        let pictures = ZoneAura.boltPictures(for: sprite, pointsHigh: box.height * (busySprite?.frame.height ?? 0) / CGFloat(sprite.height))
        let limit = box.insetBy(dx: -box.width * 0.04 - 0.5, dy: -box.height * 0.04 - 0.5)
        if pictures.count < 24 { onBody.append("\(pictures.count) pictures") }
        for p in pictures {
            if !p.lines.joined().allSatisfy({ limit.contains($0) }) { onBody.append("a bolt beyond 1.08×"); break }
            let main = p.lines[0], reach = hypot(main.last!.x - main[0].x, main.last!.y - main[0].y) / box.height
            if reach < 0.25 || reach > 1.05 { onBody.append("a tree \(Int(reach * 100))% long"); break }
        }
        // the trees start on both sides of the body; the arcs lie on it too, 0.06–0.3 body heights end to end.
        let starts = pictures.prefix(6 * ZoneAura.boltVariants).map { $0.lines[0][0].x }
        if !(starts.contains { $0 < box.midX } && starts.contains { $0 > box.midX }) { onBody.append("trees on one side only") }
        // every crawling arc's ends, as placed in its loop, inside the drawn box ×1.08 (in the figure's points).
        let brushes = ZoneAura.arcBrushes(for: sprite, pointsHigh: box.height * (busySprite?.frame.height ?? 0) / CGFloat(sprite.height))
        if let f = busySprite?.frame, brushes.count >= ZoneAura.brushCount {
            let kx = f.width / CGFloat(sprite.width), ky = f.height / CGFloat(sprite.height)
            let pts = CGRect(x: f.minX + limit.minX * kx, y: f.minY + limit.minY * ky, width: limit.width * kx, height: limit.height * ky).insetBy(dx: -0.5, dy: -0.5)
            var placed = 0
            outer: for spark in sparks(busy) {
                guard let group = spark.animation(forKey: "arcs") as? CAAnimationGroup else { continue }
                let tracks = Dictionary(uniqueKeysWithValues: (group.animations ?? []).compactMap { $0 as? CAKeyframeAnimation }.map { ($0.keyPath ?? "", $0.values ?? []) })
                let spots = (tracks["position"] as? [NSValue] ?? []).map(\.pointValue), turns = (tracks["transform"] as? [NSValue] ?? []).map(\.caTransform3DValue)
                let shown = tracks["contents"] ?? []
                for (i, c) in spots.enumerated() where i < turns.count && i < shown.count {
                    guard let b = brushes.first(where: { ($0.core as AnyObject) === (shown[i] as AnyObject) || ($0.glow as AnyObject) === (shown[i] as AnyObject) }) else { continue }
                    let line = b.lines[0], half = abs(line.last!.x - line[0].x) / 2 * kx
                    let a = atan2(turns[i].m12, turns[i].m11), e = CGPoint(x: cos(a) * half, y: sin(a) * half)
                    placed += 1
                    if !pts.contains(CGPoint(x: c.x + e.x, y: c.y + e.y)) || !pts.contains(CGPoint(x: c.x - e.x, y: c.y - e.y)) { onBody.append("an arc beyond 1.08× at \(c)"); break outer }
                }
            }
            if placed < 100 { onBody.append("only \(placed) arcs placed") }
        } else { onBody.append("\(brushes.count) brushes") }
    } else { onBody.append("no busy sprite") }
    let holder = view.bolts(of: crowd.busy)
    let holderAt = busyFigure?.sublayers?.firstIndex { $0 === holder } ?? -1, spriteAt = busyFigure?.sublayers?.firstIndex { $0 === busySprite } ?? 99
    if holder == nil || holderAt <= spriteAt { onBody.append("the bolts' holder not over the sprite (\(holderAt) vs \(spriteAt))") }
    check("aura: the bolts lie on the pet's body (inside its drawn box ×1.08, 0.25–1.05 heights long), over its sprite\(onBody.isEmpty ? "" : ": " + onBody.joined(separator: ", "))",
        onBody.isEmpty)
    check("aura: its bolts' white cores and their blue glow, a pool of \(ZoneAura.slots) layers each, flicker together",
        pool(busy, "arcGlow").count == ZoneAura.slots && pool(busy, "arc").count == ZoneAura.slots
            && pool(busy, "arcGlow").contains { $0.animation(forKey: "arcs") != nil } && pool(calm, "arcGlow").contains { $0.animation(forKey: "arcs") != nil }
            && sparks(busy).count == ZoneAura.arcSlots && sparks(busy).filter { $0.animation(forKey: "arcs") != nil }.count >= 8
            && sparks(calm).filter { $0.animation(forKey: "arcs") != nil }.count == ZoneAura.idleArcs)
    // the fire flows. Two textures scroll up inside the envelope (a position loop each, the near one faster), tongues
    // are born at the shoulders more often busy than idle, the rim's light ripples up it; idle moves too, slowly.
    func flows(_ a: CALayer?) -> [CAKeyframeAnimation] {
        (a.flatMap { ZoneAura.part($0, "flame") }?.sublayers ?? []).filter { $0.name == "flow" }.compactMap { $0.animation(forKey: "scroll") as? CAKeyframeAnimation }
    }
    let busyFlows = flows(busy), calmFlows = flows(calm)
    func travel(_ a: CAKeyframeAnimation) -> CGFloat {
        let points = (a.values as? [NSValue])?.map(\.pointValue) ?? []
        return abs((points.last?.y ?? 0) - (points.first?.y ?? 0))
    }
    var scroll: [String] = []
    if busyFlows.count != 2 || calmFlows.count != 2 { scroll.append("\(busyFlows.count) busy and \(calmFlows.count) idle loops") }
    if busyFlows.count == 2, !(busyFlows[0].duration < busyFlows[1].duration) { scroll.append("the near one is not faster") }
    if busyFlows.count == 2, calmFlows.count == 2, !(busyFlows[1].duration < calmFlows[0].duration) { scroll.append("busy is not faster than idle") }
    for a in busyFlows where !(a.keyPath == "position" && a.repeatCount == .infinity && a.calculationMode == .linear) { scroll.append("not a linear position loop: \(a.keyPath ?? "-")") }
    for a in busyFlows where travel(a) <= 20 { scroll.append("travels only \(travel(a)) points") }
    if busy.flatMap({ ZoneAura.part($0, "flame")?.mask?.contents }) == nil { scroll.append("no envelope mask") }
    check("aura: two flame textures scroll upward inside the envelope in linear loops, the near one faster than the far one, both faster busy than idle (busy \(busyFlows.map { Int($0.duration * 100) }) cs, idle \(calmFlows.map { Int($0.duration * 100) }) cs; \(scroll))",
        scroll.isEmpty)
    // one body. Nothing detaches: no tongues, streaks or sparks; the outline is a loop of frames on the masks of the
    // rim, the orange and the fire alike, busy faster than idle; busy surges, idle only breathes.
    let detached = [busy, calm].compactMap { $0 }.flatMap { ZoneAura.parts($0, "tongue") + ZoneAura.parts($0, "streak") + ZoneAura.parts($0, "spark") }
    check("aura: nothing detaches from the aura: no tongue, streak or spark layers, busy or idle", detached.isEmpty)
    func outlineLoop(_ a: CALayer?, _ part: String) -> CAKeyframeAnimation? {
        a.flatMap { ZoneAura.part($0, part)?.mask?.animation(forKey: "outline") as? CAKeyframeAnimation }
    }
    let busyLoops = ["hug", "ember", "flame"].compactMap { outlineLoop(busy, $0) }, calmLoops = ["hug", "ember", "flame"].compactMap { outlineLoop(calm, $0) }
    check("aura: the outline is a discrete contents loop of \(ZoneAura.outlineFrames) frames on the rim's, the orange's and the fire's masks alike, busy \(Int((busyLoops.first?.duration ?? 0) * 100)) cs a turn, idle \(Int((calmLoops.first?.duration ?? 0) * 100)) cs",
        busyLoops.count == 3 && calmLoops.count == 3 && busyLoops.allSatisfy { $0.keyPath == "contents" && $0.calculationMode == .discrete && $0.values?.count == ZoneAura.outlineFrames && $0.repeatCount == .infinity }
            && Set(busyLoops.map(\.duration)).count == 1 && Set(busyLoops.map(\.timeOffset)).count == 1
            && (busyLoops.first?.duration ?? 9) < (calmLoops.first?.duration ?? 0)
            && abs((busyLoops.first?.duration ?? 0) - Double(ZoneAura.outlineFrames) / 12) < 0.01 && abs((calmLoops.first?.duration ?? 0) - Double(ZoneAura.outlineFrames) / 5) < 0.01)
    let surge = busy.flatMap { ZoneAura.part($0, "flame")?.animation(forKey: "surge") as? CAKeyframeAnimation }
    let surgeGaps = zip(ZoneAura.surges(seed: crowd.busy).at, ZoneAura.surges(seed: crowd.busy).at.dropFirst()).map { $1 - $0 }
    check("aura: busy the whole envelope surges up from the feet every 3 to 6 s (scale.y to 1.25 in 0.25 s, settled 0.5 s later) with a brightness bump; idle only breathes",
        surge.map { $0.keyPath == "transform.scale.y" && ($0.values as? [Double])?.max() == 1.25 && $0.repeatCount == .infinity } == true
            && !surgeGaps.isEmpty && surgeGaps.allSatisfy { $0 >= 3 && $0 <= 6 } && ZoneAura.surgeUp == 0.25 && ZoneAura.surgeDown == 0.5
            && busy.flatMap { ZoneAura.part($0, "ember") }?.animation(forKey: "surgeLight") != nil
            && calm.flatMap { ZoneAura.part($0, "flame") }?.animation(forKey: "surge").map { $0.duration > 2 } == true
            && (busy.flatMap { ZoneAura.part($0, "flame") }?.anchorPoint.y ?? 0) == 1)
    let ripple = calm.flatMap { ZoneAura.part($0, "hug") }?.sublayers?.first { $0.name == "ripple" }?.animation(forKey: "scroll")
    check("aura: the rim's light ripples up it (a scrolling band cut to the rim) rather than breathing as one piece; idle flows too",
        ripple != nil && calm.flatMap { ZoneAura.part($0, "hug")?.mask?.contents } != nil && calm.flatMap { ZoneAura.part($0, "hug") }?.animation(forKey: "breath") == nil
            && calm.map { auraAnimations($0).count } ?? 0 > 4)

    // light, not paint.
    let everyPart = [busy, calm].compactMap { $0 }.flatMap { $0.sublayers ?? [] }.filter { !($0.name ?? "").hasPrefix("arc") && $0.name != "ember" }
    check("aura: every part of the aura but the lightning and the thin orange under the fire (both drawn over: light added to a pale desk only brightens) is composited additively (\(ZoneAura.additive))",
        everyPart.count >= 6 && everyPart.allSatisfy { ($0.compositingFilter as? String) == ZoneAura.additive }
            && boltsOf(busy).map { h in h.compositingFilter == nil && (h.sublayers ?? []).count == 2 && (h.sublayers ?? []).allSatisfy { $0.compositingFilter == nil } } == true
            && busy.flatMap { ZoneAura.part($0, "ember") }.map { $0.compositingFilter == nil && $0.opacity >= 0.26 && $0.opacity <= 0.34 && $0.contents != nil } == true
            && calm.flatMap { ZoneAura.part($0, "ember") }.map { $0.opacity >= 0.1 && $0.opacity <= 0.18 } == true
            && (busy?.sublayers?.firstIndex { $0.name == "ember" } ?? 9) < (busy?.sublayers?.firstIndex { $0.name == "flame" } ?? 0))
    // It is the body's own glow: a rim all round the silhouette, from the feet up, no edge line.
    let dummy: CGImage? = {
        guard let c = CGContext(data: nil, width: 100, height: 140, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.setFillColor(OfficeCanvas.rgb(0x3060A0))
        c.fill(CGRect(x: 20, y: 10, width: 60, height: 110))  // y up: from 10 to 120 px from the bottom, so 20 to 130 from the top
        return c.makeImage()
    }()
    var rim: [String] = []
    if let dummy, let hug = ZoneAura.hug(for: dummy), let px = zoneFXPixels(hug.picture) {
        func at(_ x: CGFloat, _ y: CGFloat) -> Double {
            let cx = Int((x + hug.pad) * hug.scale), cy = Int((y + hug.pad) * hug.scale)
            guard cx >= 0, cy >= 0, cx < hug.picture.width, cy < hug.picture.height else { return 0 }
            return Double(px[(cy * hug.picture.width + cx) * 4 + 3]) / 255
        }
        for (name, x, y) in [("by the feet", 16.0, 124.0), ("by the legs", 16.0, 110.0), ("by the torso", 16.0, 70.0), ("right of the torso", 84.0, 70.0),
                             ("over the head", 50.0, 16.0)] where at(x, y) < 0.35 {
            rim.append("\(name) only \(at(x, y))")
        }
        if at(20 - 34, 70) > 0.15 { rim.append("still \(at(20 - 34, 70)) far out") }
        let out = stride(from: 19.0, through: 0, by: -1).map { at($0, 70) }
        if zip(out, out.dropFirst()).contains(where: { $1 > $0 + 0.01 }) { rim.append("a line out from the side") }
    } else {
        rim.append("no rim made")
    }
    check("aura: the rim hugs the whole silhouette (feet, legs, torso, both sides, over the head), fades out with no edge line (\(rim))",
        rim.isEmpty)
    // The envelope: a broad egg wider than the body, and over the head a dense fringe of short licks: many, low, a soft
    // jagged dome, not a few tall spikes.
    // The crown: a jagged edge over the head that flares as one shape with the loop's phase; the tallest spike at
    // `Look.crown`, no needle; the egg a little wider than the body, not more; open at the top.
    var fringe: [String] = []
    for b in [true, false] {
        let pet = ZoneAura.petIn(busy: b), crown = b ? Double(ZoneAura.look(busy: b).crown) : 0.2  // idle's low dome measures about 0.2 at phase 0
        let us = stride(from: -pet.half, through: pet.half, by: 0.01).map { $0 }
        func tops(_ phase: Double) -> [Double] {
            us.map { u -> Double in
                var top = pet.head
                for v in stride(from: pet.head, through: 1, by: 0.002) where ZoneAura.envelopeAlpha(u, v, busy: b, phase: phase) > 0.5 { top = v }
                return (top - pet.head) / pet.head
            }
        }
        let now = tops(0), later = tops(Double.pi / 2)
        let tallest = now.max() ?? 0
        var peaks = 0
        for i in 1..<(now.count - 1) where now[i] > now[i - 1] && now[i] >= now[i + 1] && now[i] > 0.03 { peaks += 1 }
        let steps = zip(now, now.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        let moved = zip(now, later).filter { abs($0 - $1) > 0.015 }.count
        let wideAtShoulder = ZoneAura.envelopeAlpha(pet.half * 1.02, pet.head * 0.7, busy: b) > 0.4
            && ZoneAura.envelopeAlpha(pet.half * 1.24, pet.head * 0.7, busy: b) < 0.15
        let name = b ? "busy" : "idle"
        if !(tallest <= crown * 1.08 && tallest >= crown * 0.85) { fringe.append("\(name): tallest spike \(tallest) of the pet over its head, wanted \(crown)") }
        if peaks < (b ? 4 : 2) { fringe.append("\(name): only \(peaks) spikes") }
        if steps > 0.15 { fringe.append("\(name): a neighbour steps \(steps) higher: a needle") }
        if moved < us.count / 3 { fringe.append("\(name): the edge barely moves with the phase (\(moved) of \(us.count))") }
        if !wideAtShoulder { fringe.append("\(name): not a little wider than the body at the shoulders, or too much wider") }
        if ZoneAura.envelopeAlpha(0, 0.995, busy: b) > 0.1 { fringe.append("\(name): closed at the top") }
        if ZoneAura.envelopeFrames(busy: b).count != ZoneAura.outlineFrames { fringe.append("\(name): \(ZoneAura.envelopeFrames(busy: b).count) frames") }
    }
    check("aura: the envelope is a soft egg a little wider than the body with one jagged crown over the head that flares as a whole with the loop's phase, the tallest spike at Look.crown, no needle, open at the top (\(fringe))",
        fringe.isEmpty)
    // The textures tile top to bottom: the same light at the tile's bottom as past its top.
    let seam = [0.0, 0.3, -0.6].allSatisfy { u in abs(ZoneAura.flowAlpha(u, 0, 0) - ZoneAura.flowAlpha(u, 1, 0)) < 0.001 && abs(ZoneAura.flowAlpha(u, 0, 1) - ZoneAura.flowAlpha(u, 1, 1)) < 0.001 }
    check("aura: the flame texture is seamless top to bottom", seam && ZoneAura.flowTiles(0) != nil && ZoneAura.flowTiles(1) != nil)
    // On the pet as drawn in its pose: the rim's box centred on the sprite's, the crown over its head.
    if let aura = busy, let sprite = view.figureLayer(of: crowd.busy)?.sublayers?.first(where: { $0.contents != nil && $0.name == nil }),
        let hugLayer = ZoneAura.part(aura, "hug"), let crown = ZoneAura.part(aura, "flame")
    {
        let image = sprite.contents as! CGImage
        let box = ZoneAura.drawnBox(image)?.rect ?? .zero, k = sprite.frame.width / CGFloat(image.width)
        let drawnX = (sprite.frame.minX + box.minX * k)...(sprite.frame.minX + box.maxX * k)
        let headTop = sprite.frame.minY + box.minY * k
        check("aura: the rim sits on the pet's frame and the fire's box stands on its feet, a little wider than it, reaching over its head (rim centre \(Int(hugLayer.frame.midX)) vs \(Int(sprite.frame.midX)), fire at \(Int(crown.position.x)) in \(Int(drawnX.lowerBound))…\(Int(drawnX.upperBound)))",
            abs(hugLayer.frame.midX - sprite.frame.midX) < 0.5 && abs(hugLayer.frame.midY - sprite.frame.midY) < 0.5 && drawnX.contains(crown.position.x)
                && abs(crown.position.y - (headTop + box.height * k)) < 0.5 && crown.frame.minY < headTop - box.height * k * 0.3
                && crown.frame.width > box.width * k * 1.05 && crown.frame.width < box.width * k * 1.3)
    }

    // The room looks again every 2 s: nothing changed, nothing restarted.
    CATransaction.flush()
    let began = busyFlows.first?.beginTime
    let outlineBegan = outlineLoop(busy, "flame")?.beginTime  // read after the commit, as `began` is
    let figure = view.figureLayer(of: crowd.busy)
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
    view.update(store)
    CATransaction.flush()
    check("aura: a look with nothing changed leaves its loops running as they were (began \(began ?? -1) then \(flows(busy).first?.beginTime ?? -1); outline \(outlineBegan ?? -1) then \(outlineLoop(busy, "flame")?.beginTime ?? -1))",
        view.aura(of: crowd.busy) === busy && flows(busy).first?.beginTime == began && outlineLoop(busy, "flame")?.beginTime == outlineBegan)
    // Busy to idle, then off Fable: the same figure, the aura shaped again or taken off.
    func set(_ id: String, status: String? = nil, model: String? = nil) {
        store.sessions = store.sessions.map { s in
            guard s.id == id else { return s }
            var t = Session(id: s.id, pid: s.pid, project: s.project, name: s.name, status: status ?? s.status, since: s.since, summary: s.summary,
                            waitingFor: s.waitingFor, registryName: s.registryName, cwd: s.cwd, kind: s.kind, tool: s.tool)
            t.model = model ?? s.model
            return t
        }
    }
    set(crowd.busy, status: "idle")
    view.update(store)
    let calmed = view.aura(of: crowd.busy)
    check("aura: busy to idle shapes the same aura calm on the same figure: no big flare, well lower (\(Int(busyHigh)) to \(Int(high(calmed))) points)",
        calmed === busy && view.figureLayer(of: crowd.busy) === figure && !flares(calmed) && calmed.map(ZoneAura.isBusy) == false
            && busyHigh > high(calmed) * 1.1)
    set(crowd.busy, model: "claude-opus-5-5")
    view.update(store)
    let gone = view.aura(of: crowd.busy) == nil && busy?.superlayer == nil && view.figureLayer(of: crowd.busy) === figure
    set(crowd.opus, model: "claude-fable-6")
    view.update(store)
    check("aura: switching the model takes the aura off or puts it on, the figure kept", gone && view.aura(of: crowd.opus) != nil)

    // Still pictures and Reduce Motion: a glow held still.
    let still = ZoneView(frame: CGRect(origin: .zero, size: size))
    still.still = true
    still.update(crowd.store)
    let calmView = ZoneView(frame: CGRect(origin: .zero, size: size))
    calmView.calmOverride = true
    calmView.update(crowd.store)
    let held = [still.aura(of: crowd.calm), still.aura(of: crowd.line), calmView.aura(of: crowd.calm), calmView.aura(of: crowd.line)]
    check("aura: in a still picture and with Reduce Motion the aura is there with no animation on it",
        held.allSatisfy { $0 != nil && auraAnimations($0!).isEmpty && ZoneAura.part($0!, "flame")?.sublayers?.contains { $0.name == "flow" && $0.contents != nil } == true })

    // A still adds the aura as the window does: by screen, never darker than the room under it.
    // (Service1 is Opus by now; Demo-sync is still busy on Fable.)
    // (The thin orange under the fire is drawn over, so it is left out here: it may take a little blue off a white highlight.)
    let emberPart = still.aura(of: crowd.fire).flatMap { ZoneAura.part($0, "ember") }
    emberPart?.isHidden = true
    // the desks out of the way (a desk in front rightly covers the fire's lower part; that is checked in deskCoverTests).
    let desks = (still.stageLayer.sublayers ?? []).filter { ($0.name ?? "").hasPrefix("desk-") }
    for d in desks { d.isHidden = true }
    defer { for d in desks { d.isHidden = false } }
    if let p = still.foot(of: crowd.fire), let lit = still.image(pixelScale: 1) {
        let aura = still.aura(of: crowd.fire)
        aura?.isHidden = true
        let bare = still.image(pixelScale: 1)
        aura?.isHidden = false
        emberPart?.isHidden = false
        let box = CGRect(x: p.x - 50, y: p.y - 140, width: 100, height: 150).integral
        var darker = 0, brighter = 0
        if let bare, let a = zoneFXPixels(lit), let b = zoneFXPixels(bare) {
            for y in Int(box.minY)..<Int(box.maxY) {
                for x in Int(box.minX)..<Int(box.maxX) {
                    let i = (y * lit.width + x) * 4
                    for c in 0..<3 { if Int(a[i + c]) < Int(b[i + c]) - 2 { darker += 1 } }
                    if Int(a[i]) + Int(a[i + 1]) > Int(b[i]) + Int(b[i + 1]) + 20 { brighter += 1 }
                }
            }
        }
        check("aura: a still adds the busy aura by screen: round the pet the room only gets brighter (\(brighter) px brighter, \(darker) channels darker)",
            darker == 0 && brighter > 1500)
    }

    // No faint frame round a masked part's box in a still: the pixels on and just outside each mask's box are the room's.
    // Only the masked parts are drawn (the floor pool and the flare have no box), and a ring pixel inside another box is skipped.
    let unmasked = still.aura(of: crowd.fire)?.sublayers?.filter { $0.mask == nil && !$0.isHidden } ?? []
    unmasked.forEach { $0.isHidden = true }
    defer { unmasked.forEach { $0.isHidden = false } }
    if let aura = still.aura(of: crowd.fire), let lit = still.image(pixelScale: 1) {
        aura.isHidden = true
        let bare = still.image(pixelScale: 1)
        aura.isHidden = false
        var boxes: [CGRect] = []
        func masked(_ layer: CALayer) {
            if let mask = layer.mask, !layer.isHidden {
                let f = mask.frame
                let corners = [CGPoint(x: f.minX, y: f.minY), CGPoint(x: f.maxX, y: f.minY), CGPoint(x: f.minX, y: f.maxY), CGPoint(x: f.maxX, y: f.maxY)]
                    .map { still.layer!.convert($0, from: layer) }
                let xs = corners.map(\.x), ys = corners.map(\.y)
                boxes.append(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            }
            for child in layer.sublayers ?? [] { masked(child) }
        }
        masked(aura)
        var off = 0, worst = 0
        if let bare, let a = zoneFXPixels(lit), let b = zoneFXPixels(bare) {
            for box in boxes {
                // The pixels the box's edge runs through and the line just outside it. Not the bottom edge's own pixels: the
                // fire's outline reaches down to the box there (its feet), which is the aura, not a frame.
                let x0 = Int(box.minX.rounded(.down)), x1 = Int(box.maxX.rounded(.down)), y0 = Int(box.minY.rounded(.down)), y1 = Int(box.maxY.rounded(.down))
                var ring: [(Int, Int)] = []
                for x in (x0 - 1)...(x1 + 1) { for y in [y0 - 1, y0, y1 + 1] { ring.append((x, y)) } }
                for y in (y0 - 1)...(y1 - 4) { for x in [x0 - 1, x0, x1, x1 + 1] { ring.append((x, y)) } }
                let others = boxes.filter { $0 != box }.map { $0.insetBy(dx: -2, dy: -2) }
                for (x, y) in ring where x >= 0 && y >= 0 && x < lit.width && y < lit.height
                    && !others.contains(where: { $0.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) }) {
                    let i = (y * lit.width + x) * 4
                    let d = (0..<3).map { abs(Int(a[i + $0]) - Int(b[i + $0])) }.max()!
                    worst = max(worst, d)
                    if d > 3 { off += 1 }
                }
            }
        }
        check("aura: a still leaves no frame round the aura's masked boxes (\(boxes.count) boxes, \(off) ring pixels off, worst \(worst))",
            !boxes.isEmpty && off == 0)
    }

    // It rides along a walk: the walking figure's own tree.
    let walker = ZoneView(frame: CGRect(origin: .zero, size: size))
    walker.calmOverride = false
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = walker
    window.orderFrontRegardless()
    let fresh = auraCrowd()
    walker.update(fresh.store)
    if let scene = ZoneArt.scene, let to = scene.visitor {
        walker.probeWalk(fresh.calm, to: to)
        check("aura: walking, the aura is in the walking figure's layer, which carries the walk",
            walker.figureLayer(of: fresh.calm)?.animation(forKey: "walk") != nil && walker.aura(of: fresh.calm)?.superlayer === walker.figureLayer(of: fresh.calm))
    }
    window.orderOut(nil)
    window.contentView = nil

    // Other themes never get it: the office's view has no aura with the same sessions, and only Seaview's view uses it.
    let office = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    office.update(crowd.store)
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    let users = (["Office.swift", "Panel.swift"] + dataSourceFiles + ["Extensions.swift"])
        .filter { ((try? String(contentsOf: sources.appendingPathComponent($0), encoding: .utf8)) ?? "").contains("ZoneAura") }
    check("aura: the office and the board never show it (no aura in the office's layers; only ZoneView uses it: \(users))",
        !auraNamed(office.layer ?? CALayer(), "aura") && users.isEmpty)
}

@MainActor func auraModelTests() {
    func reply(_ model: String, text: String = "好") -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"assistant","timestamp":"2026-10-21T01:00:05.000Z","message":{"model":"\#(model)","id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"#
    }
    func toolCall(_ model: String) -> String {
        #"{"parentUuid":"p","isSidechain":false,"type":"assistant","timestamp":"2026-10-21T01:00:06.000Z","message":{"model":"\#(model)","id":"m","type":"message","role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}"#
    }
    let asked = #"{"type":"user","isSidechain":false,"timestamp":"2026-10-21T01:00:00.000Z","message":{"role":"user","content":"接着做"}}"#
    let bench = RestartBench("aura")
    defer { bench.done() }
    let now = Date()
    func read(_ lines: [String], _ id: String, status: String = "idle", at: Date? = nil) -> Session? {
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        bench.open(id, status, since: at ?? now)
        return bench.load().first { $0.id == id }
    }
    let fable = read([asked, reply("claude-opus-5-5"), asked, reply("claude-fable-5-1")], "m-fable")
    check("aura: the last assistant line's model is the session's (opus, then fable: claude-fable-5-1), shown by Loader.model(of:)",
        fable?.model == "claude-fable-5-1" && fable?.isFable == true && bench.loader.model(of: "m-fable") == "claude-fable-5-1")
    let opus = read([asked, reply("claude-fable-5"), asked, reply("claude-opus-5-5")], "m-opus")
    check("aura: fable earlier, opus last: opus, not fable", opus?.model == "claude-opus-5-5" && opus?.isFable == false)
    let tool = read([asked, reply("claude-opus-5-5"), toolCall("claude-fable-5")], "m-tool", status: "busy")
    check("aura: a tool call with no text names its model too (the last assistant line, whatever it carries)", tool?.model == "claude-fable-5")
    let synthetic = read([asked, reply("claude-fable-5-1"), reply("<synthetic>", text: "No response requested.")], "m-synth")
    check("aura: a <synthetic> last reply keeps the real model before it", synthetic?.model == "claude-fable-5-1")
    // Read again with only a prompt in the tail (a new file moment, so the tail is parsed again): the model stays.
    let again = read([asked], "m-fable", at: now + 5)
    check("aura: a re-read tail with no assistant line keeps the model it had", again?.model == "claude-fable-5-1" && again?.isFable == true)
    let none = read([asked], "m-none")
    check("aura: never a reply: no model, not fable", none?.model == "" && none?.isFable == false && bench.loader.model(of: "m-none") == nil)
    let rule = ["claude-fable-5": true, "claude-fable-6": true, "FABLE": true, "claude-opus-5-5": false, "claude-haiku-5-5": false, "": false]
    let wrong = rule.filter { Session.isFable($0.key) != $0.value }.map(\.key)
    check("aura: isFable is \"fable\" in the name in any case (wrong: \(wrong))", wrong.isEmpty)
}

/// The crowded room (`zoneOpenRoomCrowd`) with Fable on a few: Service1 busy and Misc1 done (looked at) at their desks with Misc2
/// (Opus, busy, the one focused in Orca: the disco light) between them, Demo-sync busy (a pet with fire art of its own), one on a
/// sofa (PPT-weekly, done) and one in the line (demo-layout, waiting). The pets are pinned, so stills compare from run to run.
@MainActor func auraCrowd() -> (store: Store, busy: String, calm: String, opus: String, sofa: String, line: String, fire: String) {
    let names = (busy: "AI-ML-服务1", calm: "AI-QA-云杉1", opus: "AI-QA-云杉2", sofa: "Web-ABC-银河", line: "Home-demo-layout", fire: "Ops-Demo-协同")
    // The crowd's ids are its order: read once, pin the pets by id in the store's memory, then make it again.
    let first = zoneOpenRoomCrowd()
    func id(_ store: Store, _ name: String) -> String { store.sessions.first { $0.name == name }?.id ?? "" }
    let pinned = [id(first, names.busy): "whaley", id(first, names.calm): "boxcat", id(first, names.opus): "octopus",
                  id(first, names.fire): "red-panda", id(first, names.sofa): "cream-cat", id(first, names.line): "cloudy"]
    UserDefaults.standard.set(pinned, forKey: "petBySession")
    defer { UserDefaults.standard.removeObject(forKey: "petBySession") }
    let store = zoneOpenRoomCrowd()
    let picks = (busy: id(store, names.busy), calm: id(store, names.calm), opus: id(store, names.opus), sofa: id(store, names.sofa),
                 line: id(store, names.line), fire: id(store, names.fire))
    let fable: Set<String> = [picks.busy, picks.calm, picks.sofa, picks.line, picks.fire]
    store.sessions = store.sessions.map { s in
        var s = s.id != picks.calm ? s
            : Session(id: s.id, pid: s.pid, project: s.project, name: s.name, status: "idle", since: Date() - 1200, summary: s.summary,
                      registryName: s.registryName, cwd: s.cwd)
        s.model = fable.contains(s.id) ? "claude-fable-5-1" : s.id == picks.opus ? "claude-opus-5-5" : ""
        return s
    }
    store.focused = picks.opus
    return (store, picks.busy, picks.calm, picks.opus, picks.sofa, picks.line, picks.fire)
}

/// `--aura-stills <dir>`: the room held still, its auras added by screen as the window adds them
/// (`ZoneView.image`): `aura-room.png`; `aura-zoom.png`, 3× round the busy Fable, the idle one and the disco-lit Opus
/// one; `aura-fire.png`, the fire-art pet busy; `aura-calm.png`, the idle one alone; `frames/fNNN.png`, six moments of the busy
/// aura 0.18 s apart round its first arc (for `tools/dev/contact_sheet.py`); `aura-flames.png`, the flame pictures.
@MainActor func auraStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir + "/frames", withIntermediateDirectories: true)
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
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("aura stills: no \(name)") }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
        print("aura stills: wrote \(dir)/\(name)")
    }
    // The fire's pictures on the night floor's colour: the envelopes (busy, idle) and the two textures' tiles.
    let pictures = [ZoneAura.envelope(busy: true), ZoneAura.envelope(busy: false), ZoneAura.flowTiles(0), ZoneAura.flowTiles(1)].compactMap { $0 }
    let sheet = CGContext(data: nil, width: 220 * 2 + 128 * 2, height: 768, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    sheet.setFillColor(OfficeCanvas.rgb(0x2A2633))
    sheet.fill(CGRect(x: 0, y: 0, width: 696, height: 768))
    sheet.setBlendMode(.screen)
    var x = 0
    for image in pictures {
        sheet.draw(image, in: CGRect(x: x, y: 768 - image.height, width: image.width, height: image.height))
        x += image.width
    }
    write(sheet.makeImage(), "aura-flames.png")
    guard ZoneArt.scene != nil else { return print("aura stills: no art") }
    let crowd = auraCrowd()
    print("aura stills: pets \([crowd.busy, crowd.calm, crowd.opus, crowd.fire].map { crowd.store.displayPets[$0] ?? "-" })")
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(crowd.store)
    // the tree art itself: each family's first tree at 3× its points on a dark blue, glow then core, over the busy
    // pet faintly (`bolt-sheet.png`); `--bolts-only` stops there.
    if let spriteLayer = view.figureLayer(of: crowd.busy)?.sublayers?.first(where: { $0.contents != nil && $0.name == nil }),
       let contents = spriteLayer.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID, spriteLayer.frame.height > 0 {
        let sprite = contents as! CGImage
        let ppp = CGFloat(sprite.height) / spriteLayer.frame.height, s = 3 / ppp
        let box = ZoneAura.drawnBox(sprite)?.rect ?? .zero
        let started = Date()
        _ = ZoneAura.boltPictures(for: sprite, pointsHigh: box.height / ppp + 3)  // a size not drawn yet
        print("aura stills: the trees drawn in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let pictures = ZoneAura.boltPictures(for: sprite, pointsHigh: box.height / ppp)
        let chosen = (0..<8).compactMap { i in pictures.indices.contains(i * ZoneAura.boltVariants) ? pictures[i * ZoneAura.boltVariants] : nil }
        let cw = (chosen.map(\.rect.width).max() ?? 1) * s, ch = (chosen.map(\.rect.height).max() ?? 1) * s
        let sheetW = Int(cw * 4), sheetH = Int(ch * 2)
        if let c = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.setFillColor(OfficeCanvas.rgb(0x0B1630))
            c.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))
            c.interpolationQuality = .high
            for (i, p) in chosen.enumerated() {
                let ox = CGFloat(i % 4) * cw, top = CGFloat(sheetH) - CGFloat(i / 4) * ch
                func dest(_ fr: CGRect) -> CGRect { CGRect(x: ox + (fr.minX - p.rect.minX) * s, y: top - (fr.maxY - p.rect.minY) * s, width: fr.width * s, height: fr.height * s) }
                c.saveGState()
                c.clip(to: CGRect(x: ox, y: top - ch, width: cw, height: ch))
                c.setAlpha(0.3)
                c.draw(sprite, in: dest(CGRect(x: 0, y: 0, width: sprite.width, height: sprite.height)))
                c.setAlpha(1)
                c.draw(p.glow, in: dest(p.rect))
                c.draw(p.core, in: dest(p.rect))
                c.restoreGState()
            }
            write(c.makeImage(), "bolt-sheet.png")
        }
        print("aura stills: \(pictures.count) trees, the pet \(Int(box.height / ppp)) points tall")
    }
    if CommandLine.arguments.contains("--bolts-only") { return }
    let k: CGFloat = 3
    write(view.image(pixelScale: 2), "aura-room.png")
    guard let room = view.image(pixelScale: k) else { return }
    func crop(_ ids: [String], _ name: String, margin: (CGFloat, CGFloat, CGFloat) = (90, 170, 30)) {
        let feet = ids.compactMap { view.foot(of: $0) }
        guard let minX = feet.map(\.x).min(), let maxX = feet.map(\.x).max(), let minY = feet.map(\.y).min(), let maxY = feet.map(\.y).max() else { return }
        let box = CGRect(x: minX - margin.0, y: minY - margin.1, width: maxX - minX + 2 * margin.0, height: maxY - minY + margin.1 + margin.2)
            .intersection(CGRect(origin: .zero, size: size))
        write(room.cropping(to: CGRect(x: box.minX * k, y: box.minY * k, width: box.width * k, height: box.height * k)), name)
    }
    crop([crowd.busy, crowd.calm, crowd.opus], "aura-zoom.png")
    crop([crowd.fire], "aura-fire.png", margin: (75, 150, 30))
    crop([crowd.calm], "aura-calm.png", margin: (70, 120, 30))
    // On the dark floor: the Fable one waiting in the line.
    crop([crowd.line], "aura-floor.png", margin: (75, 150, 30))
    // 24 moments 50 ms apart round the second big burst (its moment at the eleventh), each posed from the same loops the window runs.
    // 30 moments 50 ms apart from just before a strike (the one with the next tree soonest after it), so it and the
    // tree after it rise, flicker and fade inside them.
    let storm = ZoneAura.storm(seed: crowd.busy, busy: true)
    let first = storm.bigs.min { a, b in
        func next(_ t: Double) -> Double { (storm.bursts.first { $0 > t + 0.01 } ?? t + 9) - t }
        return next(a) < next(b)
    } ?? 1
    func pose(_ t: Double, _ name: String, side: CGFloat = 150, scale: CGFloat = 2) {
        view.auraPhase = t
        view.update(crowd.store)
        guard let shot = view.image(pixelScale: scale), let p = view.foot(of: crowd.busy) else { return }
        write(shot.cropping(to: CGRect(x: (p.x - side / 2) * scale, y: (p.y - side * 0.82) * scale, width: side * scale, height: side * scale)), name)
    }
    try? FileManager.default.createDirectory(atPath: dir + "/frames", withIntermediateDirectories: true)
    for i in 0..<30 { pose(first - 0.05 + 0.001 + Double(i) * 0.05, String(format: "frames/f%03d.png", i), side: 170, scale: 3) }
    // per frame, the trees up (their core above 0.25) and the arcs on.
    print("aura stills: frames' trees/arcs " + (0..<30).map { i -> String in
        let t = first - 0.05 + 0.001 + Double(i) * 0.05
        let trees = (0..<ZoneAura.slots).filter { ZoneAura.level(ZoneAura.track(storm, slot: $0, glow: false), at: t, period: storm.period) > 0.25 }.count
        return "\(trees)/\(ZoneAura.arcsLit(t, seed: crowd.busy, busy: true))"
    }.joined(separator: " "))
    // The burst up close: six moments 0.05 s apart from just before it, at three times the points.
    try? FileManager.default.createDirectory(atPath: dir + "/arc-frames", withIntermediateDirectories: true)
    for i in 0..<6 { pose(first - 0.03 + Double(i) * 0.05, String(format: "arc-frames/f%03d.png", i), side: 120, scale: 3) }
    // the flow. Busy, twelve moments 65 ms apart (no burst among them); idle, six over 3 s.
    for name in ["flow-frames", "idle-frames"] { try? FileManager.default.createDirectory(atPath: dir + "/" + name, withIntermediateDirectories: true) }
    // twelve moments 90 ms apart round the first surge (from 0.15 s before it: the whole envelope flares up as one and
    // settles), the outline loop running through them; no lightning among them.
    let surge = ZoneAura.surges(seed: crowd.busy).at.first ?? 2
    for i in 0..<12 { pose(surge - 0.15 + Double(i) * 0.09, String(format: "flow-frames/f%03d.png", i), side: 170, scale: 3) }
    for i in 0..<6 {
        view.auraPhase = 1 + Double(i) * 0.6
        view.update(crowd.store)
        guard let shot = view.image(pixelScale: 3), let p = view.foot(of: crowd.calm) else { continue }
        write(shot.cropping(to: CGRect(x: (p.x - 75) * 3, y: (p.y - 150 * 0.82) * 3, width: 150 * 3, height: 150 * 3)), String(format: "idle-frames/f%03d.png", i))
    }
}

/// `--aura-sheet <dir>`: the aura alone, for use outside the panel: no pet, no lightning, no badge, no room, on a
/// transparent canvas, its parts composited as the window composites them (`ZoneView.image`: pool, rim and fire added by
/// screen, the thin orange drawn over), shaped round a stand-in figure (a capsule 26 × 48 pt, feet 8 pt over the bottom
/// edge, centred) in a 96 × 120 pt frame. Busy: 12 frames 90 ms apart round a surge; idle: 6 frames 500 ms apart. At 1×
/// and 2×: `busy-NN.png`, `idle-NN.png`, `busy@2x-NN.png`, `idle@2x-NN.png`, strips `busy.png`, `idle.png`, `busy@2x.png`,
/// `idle@2x.png`, and `README.txt`.
@MainActor func auraSheet(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let canvasW: CGFloat = 96, canvasH: CGFloat = 120, bodyW: CGFloat = 26, bodyH: CGFloat = 48, feetUp: CGFloat = 8
    let seed = "aura-sheet", space = CGColorSpace(name: CGColorSpace.sRGB)!
    // The stand-in: a capsule (round top for the head, round feet), 4 px a point.
    let ppp: CGFloat = 4
    let standIn: CGImage = {
        let c = CGContext(data: nil, width: Int(bodyW * ppp), height: Int(bodyH * ppp), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: bodyW * ppp, height: bodyH * ppp), cornerWidth: bodyW * ppp / 2, cornerHeight: bodyW * ppp / 2, transform: nil))
        c.fillPath()
        return c.makeImage()!
    }()
    // A figure's own points, y down, its feet at its origin (as `ZoneView` shapes the aura), in a root of the canvas's points.
    let root = CALayer(), figure = CALayer()
    root.bounds = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
    root.anchorPoint = .zero
    root.position = .zero
    figure.bounds = .zero
    figure.position = CGPoint(x: canvasW / 2, y: canvasH - feetUp)
    root.addSublayer(figure)
    let aura = ZoneAura.make()
    figure.addSublayer(aura)
    let frame = CGRect(x: -bodyW / 2, y: -bodyH, width: bodyW, height: bodyH)

    func render(busy: Bool, phase: Double, scale: CGFloat) -> CGImage? {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        ZoneAura.shape(aura, sprite: standIn, frame: frame, wide: bodyW, high: bodyH, busy: busy, moving: false, seed: seed, phase: phase, bolts: nil)
        let pw = Int(canvasW * scale), ph = Int(canvasH * scale), full = CGRect(x: 0, y: 0, width: pw, height: ph)
        func canvas() -> CGContext? {
            CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let out = canvas() else { return nil }
        let toPixels = CGAffineTransform(scaleX: scale, y: scale).translatedBy(x: 0, y: canvasH).scaledBy(x: 1, y: -1)
        func unitBox(_ box: CGRect, of layer: CALayer) -> CGAffineTransform {
            let bl = root.convert(CGPoint(x: box.minX, y: box.maxY), from: layer), br = root.convert(CGPoint(x: box.maxX, y: box.maxY), from: layer)
            let tl = root.convert(CGPoint(x: box.minX, y: box.minY), from: layer)
            return CGAffineTransform(a: br.x - bl.x, b: br.y - bl.y, c: tl.x - bl.x, d: tl.y - bl.y, tx: bl.x, ty: bl.y)
        }
        func draw(_ picture: CGImage, in box: CGRect, of layer: CALayer, into ctx: CGContext, alpha: CGFloat) {
            ctx.saveGState()
            ctx.concatenate(unitBox(box, of: layer))
            ctx.setAlpha(alpha)
            ctx.draw(picture, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        }
        func image(of layer: CALayer) -> CGImage? {
            guard let contents = layer.contents.map({ $0 as AnyObject }), CFGetTypeID(contents) == CGImage.typeID else { return nil }
            return (contents as! CGImage)
        }
        // As `ZoneView.image` paints a layer: its picture, its sublayers added or drawn over as their filters say, cut to its mask.
        func paint(_ layer: CALayer, into ctx: CGContext, alpha: CGFloat) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            let a = alpha * CGFloat(layer.opacity)
            if let mask = layer.mask, let maskPicture = image(of: mask) {
                guard let group = canvas() else { return }
                group.concatenate(toPixels)
                let box = unitBox(mask.frame, of: layer)
                group.concatenate(box)
                group.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                group.concatenate(box.inverted())
                if let picture = image(of: layer) { draw(picture, in: layer.bounds, of: layer, into: group, alpha: 1) }
                for child in layer.sublayers ?? [] {
                    group.setBlendMode(child.compositingFilter == nil ? .normal : .screen)
                    paint(child, into: group, alpha: 1)
                }
                // The mask over the whole canvas (clear outside its box), applied unclipped, so no faint line is left round the box.
                guard let cut = canvas() else { return }
                cut.concatenate(toPixels)
                draw(maskPicture, in: mask.frame, of: layer, into: cut, alpha: 1)
                guard let cutPicture = cut.makeImage() else { return }
                group.saveGState()
                group.resetClip()  // else the cut works only inside the clip's soft edge and leaves part of the edge pixels
                group.concatenate(group.ctm.inverted())
                group.setBlendMode(.destinationIn)
                group.draw(cutPicture, in: full)
                group.restoreGState()
                guard let made = group.makeImage() else { return }
                ctx.saveGState()
                ctx.concatenate(ctx.ctm.inverted())
                ctx.setAlpha(a)
                ctx.draw(made, in: full)
                ctx.restoreGState()
                return
            }
            if let picture = image(of: layer) { draw(picture, in: layer.bounds, of: layer, into: ctx, alpha: a) }
            for child in layer.sublayers ?? [] {
                ctx.setBlendMode(child.compositingFilter == nil ? .normal : .screen)
                paint(child, into: ctx, alpha: a)
            }
        }
        // Part by part in the window's order; the strike's flash (`arcFlare`) is the lightning's, so left out.
        for part in aura.sublayers ?? [] where part.name != "arcFlare" && !part.isHidden && part.opacity > 0 {
            guard let light = canvas() else { continue }
            let added = part.compositingFilter != nil
            light.concatenate(toPixels)
            light.setBlendMode(added ? .screen : .normal)
            paint(part, into: light, alpha: CGFloat(aura.opacity))
            if let made = light.makeImage() {
                out.setBlendMode(added ? .screen : .normal)
                out.draw(made, in: full)
            }
        }
        return out.makeImage()
    }
    func write(_ image: CGImage?, _ name: String) {
        guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return print("aura sheet: no \(name)") }
        try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
    }
    func strip(_ frames: [CGImage]) -> CGImage? {
        guard let first = frames.first,
              let c = CGContext(data: nil, width: first.width * frames.count, height: first.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (i, f) in frames.enumerated() { c.draw(f, in: CGRect(x: i * first.width, y: 0, width: first.width, height: first.height)) }
        return c.makeImage()
    }
    // Busy: from 0.15 s before the first surge (it flares up and settles inside the twelve); idle: from 1 s in.
    let surge = ZoneAura.surges(seed: seed).at.first ?? 2
    let busyStart = max(0, surge - 0.15), idleStart = 1.0
    let sets: [(name: String, busy: Bool, start: Double, step: Double, count: Int)] = [
        ("busy", true, busyStart, 0.09, 12), ("idle", false, idleStart, 0.5, 6)]
    for set in sets {
        for (scale, suffix) in [(CGFloat(1), ""), (CGFloat(2), "@2x")] {
            let frames = (0..<set.count).compactMap { i in render(busy: set.busy, phase: set.start + Double(i) * set.step, scale: scale) }
            for (i, f) in frames.enumerated() { write(f, String(format: "%@%@-%02d.png", set.name, suffix, i)) }
            write(strip(frames), "\(set.name)\(suffix).png")
        }
    }
    let readme = """
    The Blaze Mode aura (ZoneAura), exported alone by `SoulgentTests --aura-sheet <dir>` (ZoneFXTests.swift, auraSheet).

    What it is: the aura only - no pet, no lightning/arcs or strike flash, no tool badge, no room. Transparent background
    (premultiplied sRGB PNG). Parts composited as the live panel does (ZoneView.image): floor pool, rim (hug) and fire (flame)
    added by screen, the thin orange under the fire (ember) drawn normally; screen over transparency leaves each part as is.
    Shaped round a stand-in figure: a capsule 26 pt wide x 48 pt tall (round top = head). The stand-in itself is not drawn;
    the rim is brightest over where the body would be, so draw your own figure on top.

    Frame: 96 x 120 pt. 1x = 96 x 120 px; @2x = 192 x 240 px.
    Feet: horizontally centred (x = 48 pt), 8 pt above the bottom edge (y = 112 pt from the top); figure 48 pt tall, so its
    head top is at y = 64 pt. Place the frame so that point sits under your figure's feet; scale the frame by (figure height / 48).
    Crown: busy reaches ~0.42 of the body height over the head (higher while a surge stretches the fire 1.25x up from the feet), idle ~0.25.

    Busy: 12 frames, 90 ms apart (1.08 s), busy-00..11.png; starts 0.15 s before a surge (scale-up 0.25 s, settles 0.5 s),
          so the surge is in frames ~01-08. Phases \(String(format: "%.2f", busyStart))-\(String(format: "%.2f", busyStart + 0.99)) s of the aura's loops.
    Idle: 6 frames, 500 ms apart (3 s), idle-00..05.png. Phases \(String(format: "%.1f", idleStart))-\(String(format: "%.1f", idleStart + 2.5)) s.
    Note: these are samples of the live loops, not a seamless period; when looped, frame 11 -> 00 (and 05 -> 00) jumps a little.

    Files: busy-NN.png, idle-NN.png (1x); busy@2x-NN.png, idle@2x-NN.png (2x);
           strips busy.png (1152 x 120), idle.png (576 x 120), busy@2x.png (2304 x 240), idle@2x.png (1152 x 240),
           frames left to right in order.
    """
    try? readme.write(toFile: dir + "/README.txt", atomically: true, encoding: .utf8)
    print("aura sheet: wrote \(dir) (surge at \(String(format: "%.2f", surge)) s)")
}

/// `--aura-cpu`: the crowd (six Fable pets, one busy, one disco-lit) live in a window off screen for 12 s, then this
/// process's CPU time over the last 10 of them, as `ps` would show it: what the auras cost the panel.
@MainActor func auraCPU() {
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]
    defer {
        UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
        ZoneMemory.remembered = [:]
    }
    guard ZoneArt.scene != nil else { return print("aura cpu: no art") }
    let crowd = auraCrowd()
    // Six Fable pets busy: everyone at a AI desk that is busy, and the two picked ones.
    let busyOnes = crowd.store.sessions.filter { $0.status == "busy" && $0.name.hasPrefix("AI-") }.prefix(6).map(\.id)
    crowd.store.sessions = crowd.store.sessions.map { s in
        var s = s
        if busyOnes.contains(s.id) { s.model = "claude-fable-5-1" }
        return s
    }
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.calmOverride = false
    view.onScreenOverride = true
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    view.update(crowd.store)
    let fable = crowd.store.sessions.filter(\.isFable).count
    func cpu() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
    let t0 = cpu(), wall = Date()
    // The room looks again every 2 s, as the panel does.
    for _ in 0..<5 {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 2))
        view.update(crowd.store)
    }
    let used = cpu() - t0, seconds = Date().timeIntervalSince(wall)
    print(String(format: "aura cpu: %d Fable pets (%d busy) live for %.1f s: %.2f s CPU in this process (%.1f%%)", fable, busyOnes.count, seconds, used, used / seconds * 100))
    window.orderOut(nil)
    window.contentView = nil
}
