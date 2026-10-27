import AppKit
import AVFoundation

/// what makes a busy desk in Seaview look busy, as small parts the room puts in place: code scrolling on the screen,
/// the LED breathing, a badge for the tool in use and the sub-agents' mini figures. Layers and values go in, layers and
/// pictures come out; none of them reads the store. Core Animation only: every motion is one repeating animation that
/// the render server runs, nothing here wakes up per frame.
///
/// Points are in the parent layer's coordinates, y down (the room's root is geometry-flipped), the way `ZoneFit` gives
/// them.

/// A number from 0 up to 1 that a desk keeps from launch to launch (Swift's own string hash changes every launch): where
/// in a loop that desk's screen and LED start, so neighbours do not move in step.
func zoneFXSeed(_ id: String, salt: UInt64 = 0) -> Double {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ salt
    for b in id.utf8 {
        h ^= UInt64(b)
        h &*= 0x0000_0100_0000_01B3
    }
    // Mix the bits once more so ids that differ only at the end land far apart.
    h ^= h >> 33
    h &*= 0xff51_afd7_ed55_8ccd
    h ^= h >> 33
    return Double(h % 1_000_003) / 1_000_003
}

// ───────── Tool badge ─────────

/// What a busy session is doing right now, as one small picture over its head.
enum ZoneToolFamily: String, CaseIterable {
    case terminal  // running a command
    case pencil  // editing or writing a file
    case magnifier  // reading or searching
    case globe  // on the web
    case agents  // handing work to a sub-agent
    case thinking  // anything else, or no tool: three dots
}

@MainActor enum ZoneToolIcon {
    /// The family of a tool call, by the name its `tool_use` block carries (`use["name"]` in `pendingRequest`): Claude
    /// Code's own tools, and Codex's names for the same jobs. MCP tools and anything new are the thinking dots.
    static func family(tool: String?) -> ZoneToolFamily {
        switch tool ?? "" {
        case "Bash", "BashOutput", "KillShell", "KillBash", "PowerShell", "shell", "local_shell", "exec_command", "unified_exec":
            return .terminal
        case "Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch":
            return .pencil
        case "Read", "Grep", "Glob", "LS", "NotebookRead", "view_image":
            return .magnifier
        case "WebFetch", "WebSearch", "web_search", "web_fetch":
            return .globe
        case "Task", "Agent":
            return .agents
        default:
            return .thinking
        }
    }

    /// The name of the last tool call on a transcript line (an assistant entry with `tool_use` blocks), read the way
    /// `pendingRequest` reads it; nil when the line has none.
    static func toolName(_ line: Data) -> String? { toolUseName(line) }

    private static var drawn: [String: CGImage] = [:]

    /// A round badge for a family, `size` points across at `scale` pixels a point: a dark disc with a thin light rim and
    /// the family's glyph in light strokes. Drawn once per family and size.
    static func badge(_ family: ZoneToolFamily, size: CGFloat = 22, scale: CGFloat = 2) -> CGImage? {
        let key = "\(family.rawValue) \(size) \(scale)"
        if let known = drawn[key] { return known }
        let side = Int((size * scale).rounded())
        guard side > 0,
            let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Drawn on a 22-unit square, y down.
        let unit = CGFloat(side) / 22
        c.translateBy(x: 0, y: CGFloat(side))
        c.scaleBy(x: unit, y: -unit)
        c.setShouldAntialias(true)
        c.setAllowsAntialiasing(true)
        let disc = CGRect(x: 1, y: 1, width: 20, height: 20)
        c.setFillColor(OfficeCanvas.rgb(0x18223A, 0.94))
        c.fillEllipse(in: disc)
        c.setStrokeColor(OfficeCanvas.rgb(0x9FD4FF, 0.95))
        c.setLineWidth(1.1)
        c.strokeEllipse(in: disc.insetBy(dx: 0.55, dy: 0.55))
        let ink = OfficeCanvas.rgb(0xF2F7FF)
        c.setStrokeColor(ink)
        c.setFillColor(ink)
        c.setLineCap(.round)
        c.setLineJoin(.round)
        switch family {
        case .terminal:
            c.setLineWidth(1.3)
            c.addPath(CGPath(roundedRect: CGRect(x: 5, y: 6.5, width: 12, height: 9), cornerWidth: 1.6, cornerHeight: 1.6, transform: nil))
            c.strokePath()
            c.setLineWidth(1.5)
            c.move(to: CGPoint(x: 7.4, y: 9))
            c.addLine(to: CGPoint(x: 9.6, y: 11))
            c.addLine(to: CGPoint(x: 7.4, y: 13))
            c.move(to: CGPoint(x: 11, y: 13.2))
            c.addLine(to: CGPoint(x: 14.4, y: 13.2))
            c.strokePath()
        case .pencil:
            // A pencil lying from the top right down to the bottom left: body, ferrule line and tip.
            c.saveGState()
            c.translateBy(x: 11, y: 11)
            c.rotate(by: .pi / 4)
            c.setLineWidth(1.3)
            c.addPath(CGPath(roundedRect: CGRect(x: -1.9, y: -7, width: 3.8, height: 10), cornerWidth: 0.8, cornerHeight: 0.8, transform: nil))
            c.strokePath()
            c.move(to: CGPoint(x: -1.9, y: -4.6))
            c.addLine(to: CGPoint(x: 1.9, y: -4.6))
            c.strokePath()
            c.move(to: CGPoint(x: -1.9, y: 3))
            c.addLine(to: CGPoint(x: 0, y: 6.6))
            c.addLine(to: CGPoint(x: 1.9, y: 3))
            c.closePath()
            c.fillPath()
            c.restoreGState()
        case .magnifier:
            c.setLineWidth(1.6)
            c.strokeEllipse(in: CGRect(x: 5.4, y: 5.4, width: 8.4, height: 8.4))
            c.setLineWidth(2.4)
            c.move(to: CGPoint(x: 12.6, y: 12.6))
            c.addLine(to: CGPoint(x: 16.2, y: 16.2))
            c.strokePath()
        case .globe:
            let g = CGRect(x: 5, y: 5, width: 12, height: 12)
            c.setLineWidth(1.25)
            c.strokeEllipse(in: g)
            c.strokeEllipse(in: CGRect(x: 8.3, y: 5, width: 5.4, height: 12))
            c.setLineWidth(1.0)
            c.move(to: CGPoint(x: 5, y: 11))
            c.addLine(to: CGPoint(x: 17, y: 11))
            c.move(to: CGPoint(x: 6.4, y: 8))
            c.addLine(to: CGPoint(x: 15.6, y: 8))
            c.move(to: CGPoint(x: 6.4, y: 14))
            c.addLine(to: CGPoint(x: 15.6, y: 14))
            c.strokePath()
        case .agents:
            // Two small figures, the one behind a little dimmer.
            func person(_ x: CGFloat, _ y: CGFloat, _ alpha: CGFloat) {
                c.setFillColor(OfficeCanvas.rgb(0xF2F7FF, alpha))
                c.fillEllipse(in: CGRect(x: x - 2.2, y: y - 2.2, width: 4.4, height: 4.4))
                let body = CGMutablePath()
                body.move(to: CGPoint(x: x - 3.8, y: y + 8.2))
                body.addCurve(to: CGPoint(x: x + 3.8, y: y + 8.2), control1: CGPoint(x: x - 3.8, y: y + 2.4), control2: CGPoint(x: x + 3.8, y: y + 2.4))
                body.closeSubpath()
                c.addPath(body)
                c.fillPath()
            }
            person(13.6, 7.6, 0.62)
            c.setFillColor(OfficeCanvas.rgb(0x18223A))
            c.fillEllipse(in: CGRect(x: 4.6, y: 7.4, width: 8.8, height: 11))  // a gap between the two
            person(9, 9.4, 1)
        case .thinking:
            for x in [6.6, 11.0, 15.4] as [CGFloat] { c.fillEllipse(in: CGRect(x: x - 1.6, y: 9.4, width: 3.2, height: 3.2)) }
        }
        drawn[key] = c.makeImage()
        return drawn[key]
    }
}

// ───────── Code on a screen ─────────

/// A busy screen's code: a few short pale lines on a dark editor, scrolling slowly up inside the screen's quad. One
/// repeating animation moves a strip of lines (drawn twice, one under the other) up by one strip and starts over, so the
/// loop has no seam. Built once per desk; `isOn` hides it and takes the animation off, and puts both back.
@MainActor final class ZoneCodeScreen {
    /// On the parent: the quad's bounds, masked to the quad.
    let layer = CALayer()
    /// The screen's own rectangle, mapped onto the quad (top left, top right, bottom left).
    private let face = CALayer()
    /// The lines, two strips tall, moving.
    private let strip = CALayer()
    private let animated: Bool
    private let period: CFTimeInterval
    private let offset: CFTimeInterval
    private let travel: CGFloat
    static let key = "zone.code"

    /// Where in its loop a desk's screen starts, 0 up to 1.
    static func phase(_ id: String) -> Double { zoneFXSeed(id) }
    /// How long a desk's loop runs: 6 to 10 s, its own.
    static func period(_ id: String) -> CFTimeInterval { 6 + 4 * zoneFXSeed(id, salt: 0x51) }

    var isOn = true {
        didSet {
            guard isOn != oldValue else { return }
            layer.isHidden = !isOn
            if isOn { start() } else { strip.removeAnimation(forKey: Self.key) }
        }
    }

    /// `quad`: the screen's corners on the parent, top left, top right, bottom right, bottom left (`screen_quad`'s order,
    /// through `ZoneFit`). `scale`: pixels a point for the lines' picture. Not `animated` (a still, Reduce Motion): the
    /// lines stand where the desk's phase puts them.
    init(quad: [CGPoint], deskID: String, scale: CGFloat = 2, animated: Bool = true) {
        self.animated = animated
        period = Self.period(deskID)
        offset = Self.phase(deskID) * period
        let corners = quad.count >= 4 ? Array(quad.prefix(4)) : [CGPoint](repeating: .zero, count: 4)
        var box = CGRect.null
        for p in corners { box = box.union(CGRect(origin: p, size: .zero)) }
        layer.frame = box
        layer.name = "codeScreen"
        let local = corners.map { CGPoint(x: $0.x - box.minX, y: $0.y - box.minY) }
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        path.addLines(between: local)
        path.closeSubpath()
        mask.path = path
        mask.frame = CGRect(origin: .zero, size: box.size)
        layer.mask = mask

        // The screen's own width and height, and the map from its rectangle onto the quad.
        let across = CGVector(dx: local[1].x - local[0].x, dy: local[1].y - local[0].y)
        let down = CGVector(dx: local[3].x - local[0].x, dy: local[3].y - local[0].y)
        let wide = max(1, hypot(across.dx, across.dy)), high = max(1, hypot(down.dx, down.dy))
        face.anchorPoint = .zero
        face.bounds = CGRect(x: 0, y: 0, width: wide, height: high)
        face.position = local[0]
        face.setAffineTransform(CGAffineTransform(a: across.dx / wide, b: across.dy / wide, c: down.dx / high, d: down.dy / high, tx: 0, ty: 0))
        // a tint over the lit screen, not a dark panel: the screen still glows through behind the code.
        face.backgroundColor = OfficeCanvas.rgb(0x1E3A66, 0.3)
        face.masksToBounds = true
        layer.addSublayer(face)

        // One strip: a little taller than the screen, so a loop shows more than one screenful.
        let drawn = Self.lines(width: wide, height: high, deskID: deskID, scale: scale)
        travel = drawn.size.height
        strip.anchorPoint = .zero
        strip.bounds = CGRect(x: 0, y: 0, width: wide, height: travel * 2)
        strip.position = .zero
        strip.name = "code"
        strip.setValue(drawn.count * 2, forKey: "lines")
        for copy in 0..<2 {
            let part = CALayer()
            part.contents = drawn.image
            part.contentsScale = scale
            part.frame = CGRect(x: 0, y: CGFloat(copy) * travel, width: wide, height: travel)
            strip.addSublayer(part)
        }
        face.addSublayer(strip)
        if animated {
            start()
        } else {
            strip.position = CGPoint(x: 0, y: -travel * CGFloat(Self.phase(deskID)))
        }
    }

    private func start() {
        guard animated, strip.animation(forKey: Self.key) == nil else { return }
        let move = CABasicAnimation(keyPath: "position.y")
        move.fromValue = 0
        move.toValue = -travel
        move.duration = period
        move.repeatCount = .infinity
        move.timeOffset = offset
        move.timingFunction = CAMediaTimingFunction(name: .linear)
        move.isRemovedOnCompletion = false
        strip.add(move, forKey: Self.key)
    }

    #if TESTING
    /// For the README's moving pictures only: the lines where the live loop has them `t` seconds after it started
    /// (`start`: from 0 to -travel over `period`, begun `offset` in), on a still screen.
    func demoPose(at t: Double) {
        let u = ((t + offset) / period).truncatingRemainder(dividingBy: 1)
        strip.position = CGPoint(x: 0, y: -travel * CGFloat(u < 0 ? u + 1 : u))
    }
    var demoPeriod: Double { period }
    #endif

    /// The colours of the lines: ice, lavender, mint, all pale.
    static let inks: [UInt32] = [0xBFE6FF, 0xE3D6FF, 0xC8F2D2]

    /// A strip of code lines for a screen `width` × `height` points: rows of short dashes (words) at a fixed pitch, some
    /// indented, with gaps, in two or three soft colours. The pattern comes from the desk's id, so each screen has its own.
    static func lines(width: CGFloat, height: CGFloat, deskID: String, scale: CGFloat) -> (image: CGImage?, size: CGSize, count: Int) {
        let pitch = max(1.6, height / 6.5)  // about six lines a screenful
        let rows = 10
        let size = CGSize(width: width, height: pitch * CGFloat(rows))
        let wPx = max(1, Int((size.width * scale).rounded(.up))), hPx = max(1, Int((size.height * scale).rounded(.up)))
        guard let c = CGContext(data: nil, width: wPx, height: hPx, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return (nil, size, 0) }
        c.translateBy(x: 0, y: CGFloat(hPx))
        c.scaleBy(x: scale, y: -scale)
        let thick = max(0.6, pitch * 0.42)
        let cell = max(0.9, width / 22)  // one character, in a monospace grid
        var count = 0
        for row in 0..<rows {
            let r = zoneFXSeed(deskID, salt: UInt64(row + 1) * 0x9E37)
            if r < 0.12 { continue }  // a blank line now and then
            let indent = CGFloat(Int(r * 7) % 3) * 2 * cell + cell
            var x = indent
            let words = 1 + Int(r * 37) % 3
            let y = CGFloat(row) * pitch + (pitch - thick) / 2
            for w in 0..<words {
                let k = zoneFXSeed(deskID, salt: UInt64(row * 7 + w + 3) * 0x7F4A)
                let len = CGFloat(2 + Int(k * 6)) * cell
                guard x + len < width - cell else { break }
                let ink = inks[(row + w + Int(r * 5)) % inks.count]
                c.setFillColor(OfficeCanvas.rgb(ink, w == 0 ? 0.9 : 0.72))
                c.addPath(CGPath(roundedRect: CGRect(x: x, y: y, width: len, height: thick), cornerWidth: thick / 2, cornerHeight: thick / 2, transform: nil))
                c.fillPath()
                x += len + cell
            }
            count += 1
        }
        return (c.makeImage(), size, count)
    }
}

// ───────── Breathing LED ─────────

/// A busy desk's ice LED breathes: its opacity goes from 1 down to 0.55 and back, 3 s a breath, each desk from its own
/// point in the breath. A waiting desk's stays steady.
@MainActor enum ZoneBreath {
    static let key = "zone.breath"
    static let low: Float = 0.55
    static let breath: CFTimeInterval = 3

    /// Breathes `layer` for a busy desk; for a waiting one (or not `animated`: a still, Reduce Motion) takes the breathing
    /// off and leaves the layer's own opacity as it is. Again on a breathing layer, it is left running in step.
    static func apply(to layer: CALayer, deskID: String, waiting: Bool, animated: Bool = true) {
        guard !waiting, animated else {
            remove(from: layer)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = Float(1)
        fade.toValue = low
        fade.duration = breath / 2
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timeOffset = zoneFXSeed(deskID, salt: 0xB4) * breath
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.isRemovedOnCompletion = false
        layer.add(fade, forKey: key)
    }

    static func remove(from layer: CALayer) { layer.removeAnimation(forKey: key) }

    static func isBreathing(_ layer: CALayer) -> Bool { layer.animation(forKey: key) != nil }

    /// The opacity a desk's LED has `t` seconds into its breathing, for a still that wants a frame of it.
    static func opacity(at t: CFTimeInterval, deskID: String) -> Float {
        let x = (t + zoneFXSeed(deskID, salt: 0xB4) * breath).truncatingRemainder(dividingBy: breath) / (breath / 2)
        let leg = x <= 1 ? x : 2 - x  // 0 → 1 → 0 over a breath
        let eased = leg * leg * (3 - 2 * leg)
        return 1 - Float(eased) * (1 - low)
    }
}

// ───────── the walkers of work in the background ─────────

/// A session whose work runs in the background (`Session.isWorking` while idle) has a little figure for each helper walking
/// beside its pet: the pet's own running frames (row 1 to the right, row 2 to the left, eight of 0.1 s each) while it goes
/// along a lane and back. One layer for each walker with two animations that repeat for ever, the render server's: a position
/// (there and back, linear) and the frames (`ZoneWalk.steps` along the same route). Nothing here draws, or wakes, per frame.
/// A hung one (`bgStale`) stands grey in the middle, with no animation; so does any, in a still picture or with Reduce Motion.
@MainActor enum BGWalker {
    /// How fast it goes along its lane, points a second.
    static let speed: CGFloat = 34
    static let step = ZoneWalk.step
    /// The grey one's opacity.
    static let hungOpacity: Float = 0.55
    /// For snapshots: how far into its walk a picture catches every walker, in seconds (every walker has its own phase besides).
    static var stillTime: Double = 1.0

    /// A pet's standing frame cut to what is drawn, scaled so the drawn part is `tall` points high.
    struct Cut {
        let pet: String
        let idle: OfficePets.Frame
        let k: CGFloat
        var cell: CGSize { CGSize(width: CGFloat(idle.image.width) * k, height: CGFloat(idle.image.height) * k) }
        /// How wide the drawn part is, how far its middle is from the cell's left, and how far its feet are below the cell's top.
        var inkWide: CGFloat { CGFloat(idle.wide) * k }
        var centre: CGFloat { CGFloat(idle.left + idle.right + 1) / 2 * k }
        var feetBelowTop: CGFloat { CGFloat(idle.bottom + 1) * k }
    }

    static func cut(_ pet: String, tall: CGFloat) -> Cut? {
        guard let idle = OfficePets.shared.frame(pet, row: 0, column: 0) else { return nil }
        return Cut(pet: pet, idle: idle, k: tall / CGFloat(max(idle.tall, 1)))
    }

    /// The same, scaled so that the pet's drawn part fits a square `square` points on a side (as the sub-agents' figures are).
    static func cut(_ pet: String, square: CGFloat) -> Cut? {
        guard let idle = OfficePets.shared.frame(pet, row: 0, column: 0) else { return nil }
        return Cut(pet: pet, idle: idle, k: square / CGFloat(max(idle.tall, idle.wide, 1)))
    }

    /// The seconds one trip there and back takes: whole steps, at least two seconds.
    static func cycle(lane: CGFloat) -> Double {
        let seconds = Double(2 * max(lane, 1) / speed)
        return min(14, max(2, (seconds / (2 * step)).rounded() * 2 * step))
    }

    /// Where a walker is `t` seconds into its trip: how far along (0...1), which way, and which of the eight frames shows.
    static func state(at t: Double, cycle: Double) -> (u: CGFloat, right: Bool, column: Int) {
        var p = t.truncatingRemainder(dividingBy: cycle)
        if p < 0 { p += cycle }
        let half = cycle / 2, right = p < half
        return (CGFloat(right ? p / half : 2 - p / half), right, Int((p / step + 1e-6).rounded(.down)) % ZoneWalk.frames)
    }

    /// The eight running frames each way (nil while the pet is not cut).
    static func runFrames(_ pet: String) -> [Int: [CGImage]]? {
        var out: [Int: [CGImage]] = [:]
        for facing in [ZoneWalk.right, ZoneWalk.left] {
            var row: [CGImage] = []
            for column in 0..<ZoneWalk.frames {
                guard let f = OfficePets.shared.runFrame(pet, facing: facing, column: column) else { return nil }
                row.append(f.image)
            }
            out[facing] = row
        }
        return out
    }

    /// One running frame as a still picture catches it, with its pet's cell scaled by `cut`.
    static func runFrame(_ cut: Cut, right: Bool, column: Int) -> CGImage? {
        OfficePets.shared.runFrame(cut.pet, facing: right ? ZoneWalk.right : ZoneWalk.left, column: column)?.image
    }

    private static var grays: [String: CGImage] = [:]
    /// A frame without its colour (the hung one), made once for each pet.
    static func gray(_ image: CGImage, pet: String) -> CGImage {
        if let kept = grays[pet] { return kept }
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let made: CGImage? = data.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            let p = raw.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: w * h * 4, by: 4) {
                let luma = UInt8((Int(p[i]) * 30 + Int(p[i + 1]) * 59 + Int(p[i + 2]) * 11) / 100)
                p[i] = luma; p[i + 1] = luma; p[i + 2] = luma
            }
            return ctx.makeImage()
        }
        let out = made ?? image
        grays[pet] = out
        return out
    }

    /// The centre a layer of `cut`'s cell has when the walker's feet are at `foot` (its drawn part's middle at the foot's x).
    static func centre(_ cut: Cut, foot: CGPoint, yDown: Bool) -> CGPoint {
        let cell = cut.cell
        let y = yDown ? foot.y - cut.feetBelowTop + cell.height / 2 : foot.y - (cell.height - cut.feetBelowTop) + cell.height / 2
        return CGPoint(x: foot.x - cut.centre + cell.width / 2, y: y)
    }

    /// How a walker is shown: walking (live), standing at a place along its lane (Reduce Motion), caught `t` seconds into its
    /// walk (a picture), or hung (grey, standing).
    enum Mode: Equatable { case walks, stands, caught(Double), hung }

    /// Where along its lane (0...1) the walker of phase `phase` is, and which frame, in a picture at `t`: the same numbers the
    /// live animations go through, so a picture shows what the screen would.
    static func caught(_ t: Double, phase: Double, lane: CGFloat) -> (u: CGFloat, right: Bool, column: Int) {
        let round = cycle(lane: lane)
        return state(at: t + phase * round, cycle: round)
    }

    /// A walker: one layer, its feet along the lane from `from` to `to`, `yDown`: the parent's y goes down. `phase` (0..<1):
    /// how far round its trip it is at the start. `rest` (0...1 along the lane): where it stands when it stands. Nil while the
    /// pet's frames are not cut.
    static func layer(_ cut: Cut, from: CGPoint, to: CGPoint, yDown: Bool, mode: Mode, phase: Double, rest: CGFloat, smooth: Bool = true) -> CALayer? {
        let cell = cut.cell
        let layer = CALayer()
        layer.name = cut.pet
        layer.bounds = CGRect(origin: .zero, size: cell)
        layer.magnificationFilter = smooth ? .linear : .nearest
        layer.minificationFilter = .trilinear
        func foot(_ u: CGFloat) -> CGPoint { CGPoint(x: from.x + (to.x - from.x) * u, y: from.y + (to.y - from.y) * u) }
        let length = hypot(to.x - from.x, to.y - from.y)
        switch mode {
        case .hung:
            layer.position = centre(cut, foot: foot(rest), yDown: yDown)
            layer.contents = gray(cut.idle.image, pet: cut.pet)
            layer.opacity = hungOpacity
        case .stands:
            layer.position = centre(cut, foot: foot(rest), yDown: yDown)
            layer.contents = cut.idle.image
        case .caught(let t):
            let c = caught(t, phase: phase, lane: length)
            layer.position = centre(cut, foot: foot(c.u), yDown: yDown)
            layer.contents = runFrame(cut, right: c.right, column: c.column) ?? cut.idle.image
        case .walks:
            layer.position = centre(cut, foot: foot(rest), yDown: yDown)
            layer.contents = cut.idle.image
            guard let frames = runFrames(cut.pet) else { return layer }
            let seconds = cycle(lane: length)
            let a = centre(cut, foot: foot(0), yDown: yDown), b = centre(cut, foot: foot(1), yDown: yDown)
            let go = CAKeyframeAnimation(keyPath: "position")
            go.values = [NSValue(point: a), NSValue(point: b), NSValue(point: a)]
            go.keyTimes = [0, 0.5, 1]
            go.calculationMode = .linear
            go.duration = seconds
            go.repeatCount = .infinity
            go.timeOffset = seconds * phase
            go.isRemovedOnCompletion = false
            layer.add(go, forKey: "bgwalk")
            if let legs = ZoneWalk.steps(frames, route: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)], seconds: seconds) {
                legs.repeatCount = .infinity
                legs.timeOffset = seconds * phase
                legs.isRemovedOnCompletion = false
                layer.add(legs, forKey: "bgsteps")
            }
        }
        return layer
    }

    /// Whose phase: every walker of a session has its own, spread over the trip.
    static func phase(_ id: String, _ i: Int) -> Double {
        let p = zoneFXSeed(id, salt: 0xB6) + Double(i) / 3
        return p - p.rounded(.down)
    }
}

// ───────── Sub-agents' mini figures ─────────

/// A session's running sub-agents as mini figures on its desk: up to three, side by side along a desk edge, and a "+N"
/// pill over the last one's head for the rest.
/// A Codex sub-agent is `codexPet`, any other `claudePet` (the flame unless set), each fitting a square `height` of a pet's height (half of 35%)
/// (on a desk's edge no taller than `deskTall` of it), smaller when the edge is too short for them side by side or they would cover the screen.
@MainActor enum ZoneSubagentFigures {
    /// A running sub-agent as the office reads it (`OfficeSubagents.Agent`), and its `agentType` from its meta file
    /// ("general-purpose", "codex:codex-rescue"…), which the office's reader does not keep yet; empty when unknown.
    struct Member {
        let agent: OfficeSubagents.Agent
        var type = ""
    }

    /// One place on the edge: a figure (its pet) or the pill (how many more), and where its feet / its middle are.
    struct Spot: Equatable {
        let pet: String?
        let more: Int
        let foot: CGPoint
    }

    /// The helpers' figures: the pet set in `helperPetClaude` (any helper but Codex's) or `helperPetCodex` (a pet's id, from
    /// `defaults write`); unset or empty, the built-in flame. In the demonstration always the flame (the crowd shows
    /// listed pets only).
    static var claudePet: String { helperPet(UserDefaults.standard.string(forKey: "helperPetClaude")) }
    static var codexPet: String { helperPet(UserDefaults.standard.string(forKey: "helperPetCodex")) }
    private static func helperPet(_ set: String?) -> String {
        guard !DemoMode.active, let id = set?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return PetSources.builtInID }
        return id
    }
    static let shown = 3
    /// How small the desk-edge figures (sub-agents and background walkers) are drawn: a token beside the pet, not a second pet.
    /// One knob: the side as a share of the full-size figure's (35% of a pet's height).
    static let shrink: CGFloat = 1.0 / 2
    static let height: CGFloat = 0.35 * shrink
    /// On a desk's edge a figure fits a box as wide as the square but only this share of it tall: a wide pet (a crab)
    /// stands as large as ever, a tall or square one (the flame) is made smaller, so it does not stand up over the screen.
    static let deskTall: CGFloat = 0.67

    /// A pet cut for a desk's edge: its drawn part fits `square` points wide and `square * deskTall` points tall.
    static func deskCut(_ pet: String, square: CGFloat) -> BGWalker.Cut? {
        guard let idle = OfficePets.shared.frame(pet, row: 0, column: 0) else { return nil }
        let k = min(square / CGFloat(max(idle.wide, idle.tall, 1)), square * deskTall / CGFloat(max(idle.tall, 1)))
        return BGWalker.Cut(pet: pet, idle: idle, k: k)
    }

    static func pet(for member: Member) -> String {
        member.type.lowercased().contains("codex") ? codexPet : claudePet
    }

    /// Where each figure stands (and the pill sits) on the edge from `a` to `b`, in order: evenly spaced, none at the
    /// very ends.
    static func spots(_ members: [Member], from a: CGPoint, to b: CGPoint) -> [Spot] {
        guard !members.isEmpty else { return [] }
        let figures = members.prefix(shown).map { pet(for: $0) }
        let more = max(0, members.count - shown)
        let slots = figures.count + (more > 0 ? 1 : 0)
        func at(_ i: Int) -> CGPoint {
            let t = (CGFloat(i) + 0.5) / CGFloat(slots)
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
        var out = figures.enumerated().map { Spot(pet: $0.element, more: 0, foot: at($0.offset)) }
        if more > 0 { out.append(Spot(pet: nil, more: more, foot: at(figures.count))) }
        return out
    }

    /// One figure or the pill, placed: its feet (the pill's foot), its layer's frame and the box of what is drawn in it.
    struct Placed {
        let pet: String?
        let more: Int
        let foot: CGPoint
        let frame: CGRect
        let drawn: CGRect
        let idle: OfficePets.Frame?
    }

    /// Where the figures (up to three) and the "+N" pill go on the edge from `a` to `b`: side by side in order, a
    /// little apart and never overlapping, each a square `height` of a pet tall; all made smaller when the edge is too short
    /// for them, and slid along it, or made smaller still, so none covers `avoid` (the screen's quad). Points on the parent.
    static func place(_ members: [Member], from a: CGPoint, to b: CGPoint, petHeight: CGFloat, scale: CGFloat, avoid: [CGPoint] = [],
                      frame: (String) -> OfficePets.Frame?) -> [Placed] {
        guard !members.isEmpty else { return [] }
        // As many as stand at a readable size (at least `smallest` of `height`), three at most; the rest are the pill.
        var last: [Placed] = []
        for count in stride(from: min(shown, members.count), through: 1, by: -1) {
            let (placed, size) = place(members, count: count, from: a, to: b, petHeight: petHeight, scale: scale, avoid: avoid, frame: frame)
            last = placed
            if size >= height * smallest { break }
        }
        return last
    }

    /// How much of the screen the figures may hide (its lower tip, say) and the screen still reads as a screen.
    static let screenHidden: CGFloat = 0.12

    /// The share of a quad (top left, top right, bottom right, bottom left) that these boxes cover, from a 10 × 10 grid of
    /// points spread over it; 0 for no quad.
    static func hidden(_ quad: [CGPoint], by boxes: [CGRect]) -> CGFloat {
        guard quad.count >= 4 else { return 0 }
        var n = 0
        for i in 0..<10 {
            for j in 0..<10 {
                let u = (CGFloat(i) + 0.5) / 10, v = (CGFloat(j) + 0.5) / 10
                let top = CGPoint(x: quad[0].x + (quad[1].x - quad[0].x) * u, y: quad[0].y + (quad[1].y - quad[0].y) * u)
                let bottom = CGPoint(x: quad[3].x + (quad[2].x - quad[3].x) * u, y: quad[3].y + (quad[2].y - quad[3].y) * u)
                let p = CGPoint(x: top.x + (bottom.x - top.x) * v, y: top.y + (bottom.y - top.y) * v)
                if boxes.contains(where: { $0.contains(p) }) { n += 1 }
            }
        }
        return CGFloat(n) / 100
    }

    /// The smallest a mini figure is drawn before one fewer stands on the edge, as a share of `height`.
    static let smallest: CGFloat = 0.45

    private static func place(_ members: [Member], count: Int, from a: CGPoint, to b: CGPoint, petHeight: CGFloat, scale: CGFloat,
                              avoid: [CGPoint], frame: (String) -> OfficePets.Frame?) -> ([Placed], CGFloat) {
        let pets = members.prefix(count).map { pet(for: $0) }
        let more = max(0, members.count - count)
        let length = hypot(b.x - a.x, b.y - a.y)
        let along = length > 0 ? CGVector(dx: (b.x - a.x) / length, dy: (b.y - a.y) / length) : CGVector(dx: 1, dy: 0)
        let pill = more > 0 ? Self.pill("+\(more)", scale: scale).size : .zero
        let idles = pets.map { frame($0) }
        func layout(_ size: CGFloat, _ offset: CGFloat) -> [Placed] {
            let tall = petHeight * size
            var widths: [CGFloat] = idles.map { idle in
                guard let idle else { return tall * 0.5 }
                return CGFloat(idle.wide) * tall / CGFloat(max(idle.tall, idle.wide, 1))
            }
            let gap = tall * 0.08
            var at = offset
            var out: [Placed] = []
            for (i, w) in widths.enumerated() {
                let middle = at + w / 2
                at += w + gap
                let foot = CGPoint(x: a.x + along.dx * middle, y: a.y + along.dy * middle)
                if i < pets.count {
                    if let idle = idles[i] {
                        let k = tall / CGFloat(max(idle.tall, idle.wide, 1))
                        let centre = CGFloat(idle.left + idle.right + 1) / 2
                        let box = CGRect(x: foot.x - centre * k, y: foot.y - CGFloat(idle.bottom + 1) * k,
                                         width: CGFloat(idle.image.width) * k, height: CGFloat(idle.image.height) * k)
                        let drawn = CGRect(x: box.minX + CGFloat(idle.left) * k, y: box.minY + CGFloat(idle.top) * k,
                                           width: CGFloat(idle.wide) * k, height: CGFloat(idle.tall) * k)
                        out.append(Placed(pet: pets[i], more: 0, foot: foot, frame: box, drawn: drawn, idle: idle))
                    } else {
                        let box = CGRect(x: foot.x - tall * 0.25, y: foot.y - tall * 0.7, width: tall * 0.5, height: tall * 0.7)
                        out.append(Placed(pet: pets[i], more: 0, foot: foot, frame: box, drawn: box, idle: nil))
                    }
                }
            }
            // The pill takes no room on the edge (a desk's is short): it sits just over the last figure's head.
            if more > 0, let last = out.last {
                let box = CGRect(x: last.drawn.midX - pill.width * 0.2, y: last.drawn.minY - pill.height - 1, width: pill.width, height: pill.height)
                out.append(Placed(pet: nil, more: more, foot: last.foot, frame: box, drawn: box, idle: nil))
            }
            return out
        }
        func span(_ placed: [Placed]) -> CGFloat {
            let row = placed.filter { $0.pet != nil }
            guard let first = row.first, let last = row.last else { return 0 }
            let p0 = first.drawn.width / 2, p1 = last.drawn.width / 2
            return hypot(last.foot.x - first.foot.x, last.foot.y - first.foot.y) + p0 + p1
        }
        /// How much of the screen the drawn boxes hide, past what is allowed (`screenHidden`): 0 while it stays visible.
        func cover(_ placed: [Placed]) -> Int {
            let hidden = Self.hidden(avoid, by: placed.map(\.drawn))
            return hidden <= screenHidden ? 0 : Int((hidden - screenHidden) * 1000) + 1
        }
        var size = height
        // The pill keeps its size: shrink the figures until the whole row fits the edge.
        for _ in 0..<12 {
            let natural = span(layout(size, 0))
            guard natural > length, natural > 0, size > height * 0.2 else { break }
            size *= max(0.5, min(0.98, length / natural))
        }
        var best: [Placed] = []
        for _ in 0..<6 {
            let room = max(0, length - span(layout(size, 0)))
            // Slide along the edge: the middle first, then out either way; the first that leaves the screen clear wins.
            var tries: [CGFloat] = [room / 2]
            for k in 1...6 { tries += [room / 2 - room / 12 * CGFloat(k), room / 2 + room / 12 * CGFloat(k)] }
            var pick: (Int, [Placed])?
            for offset in tries {
                let placed = layout(size, offset)
                let c = cover(placed)
                if pick == nil || c < pick!.0 { pick = (c, placed) }
                if c == 0 { break }
            }
            best = pick?.1 ?? []
            if (pick?.0 ?? 0) == 0 { break }
            size *= 0.88
        }
        return (best, size)
    }

    /// The figures and the pill as layers on a holder at the parent's origin (so their frames are the parent's points),
    /// placed by `place`. `petHeight`: a main pet's height on the parent (`scene.petHeight * fit.scale`). `scale`: the
    /// room's `fit.scale`, for the pill's text. `avoid`: the screen's quad on the parent. `frame`: a pet's idle frame
    /// (`OfficePets.shared.frame(pet, row: 0, column: 0)`); while a pet's frames are not cut yet its figure is a small soft
    /// token.
    static func layer(_ members: [Member], from a: CGPoint, to b: CGPoint, petHeight: CGFloat, scale: CGFloat, avoid: [CGPoint] = [],
                      frame: (String) -> OfficePets.Frame?) -> CALayer {
        let holder = CALayer()
        holder.frame = .zero
        holder.masksToBounds = false
        holder.name = "subagents"
        // The one nearer the bottom of the picture is nearer the camera: drawn last, in front.
        for spot in place(members, from: a, to: b, petHeight: petHeight, scale: scale, avoid: avoid, frame: frame).sorted(by: { $0.foot.y < $1.foot.y }) {
            let part = CALayer()
            part.frame = spot.frame
            if let pet = spot.pet {
                part.name = pet
                if let idle = spot.idle {
                    part.contents = idle.image
                    part.magnificationFilter = .nearest
                } else {
                    part.backgroundColor = OfficeCanvas.rgb(0xC9D6E8, 0.75)
                    part.cornerRadius = spot.frame.width / 2
                }
            } else {
                part.name = "more"
                part.contents = Self.pill("+\(spot.more)", scale: scale).image
            }
            holder.addSublayer(part)
        }
        return holder
    }

    /// "+N": a small dark capsule with light text, the room's plate look.
    static func pill(_ words: String, scale: CGFloat) -> (image: CGImage?, size: CGSize) {
        let size = max(7.5, 8 * min(scale, 1.4))
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        let wide = (measure.width(of: words, size: size, weight: .semibold) + size * 0.9).rounded(.up)
        let high = (size * 1.4).rounded(.up)
        let c = OfficeCanvas(CGSize(width: wide + 1, height: high + 1))
        c.card(CGRect(x: 0.5, y: 0.5, width: wide, height: high), radius: high / 2, 0x172033, 0.88, edge: 0x7FB8E6)
        c.text(words, in: CGRect(x: 0, y: (high - size * 1.25) / 2 + 0.5, width: wide + 1, height: size * 1.3), size: size, weight: .semibold,
               0xE9F3FF, align: .center)
        return (c.image(), CGSize(width: wide + 1, height: high + 1))
    }
}

// ───────── The office's disco light, in the room ─────────

/// The light on the session the user types in, in Orca: the office's disco light (a mirror ball turning, five spots
/// of colour going round, three lasers swinging, a cone and a pool of light), built from the office's own pieces
/// (`OfficeView`'s pictures, loops and numbers) and drawn round the room's bigger pet: the office's light is made for a
/// pet about `reference` points tall, and the whole rig is scaled to this one. On the night render its dark-floor tones.
/// Everything moves in steps on the office's beat, twelve a second; held where it is while Orca is behind, and still in a
/// picture, out of a window or with Reduce Motion.
@MainActor enum ZoneDisco {
    static let reference: CGFloat = 48
    /// The office paints its light for its pale floors; on the night render one cone and pool are faint, so twice.
    static let layers = 2

    /// A light, not yet shaped: its rig (scaled), and in it the cones, pools, spots, lasers and the ball, named as the
    /// office names them.
    static func make() -> CALayer {
        let beam = CALayer(), rig = CALayer()
        beam.name = "beam"
        rig.name = "rig"
        beam.bounds = .zero
        rig.bounds = .zero
        beam.opacity = 0
        beam.addSublayer(rig)
        for _ in 0..<layers {
            let cone = CALayer(), pool = CALayer()
            cone.name = "cone"
            pool.name = "pool"
            cone.anchorPoint = CGPoint(x: 0.5, y: 1)
            rig.addSublayer(cone)
            rig.addSublayer(pool)
        }
        for _ in OfficeView.spots {
            let spot = CALayer()
            spot.name = "spot"
            rig.addSublayer(spot)
        }
        for _ in OfficeView.lasers {
            let laser = CALayer(), ray = CALayer(), tip = CALayer()
            laser.name = "laser"
            ray.name = "ray"
            tip.name = "tip"
            laser.anchorPoint = CGPoint(x: 0.5, y: 0)
            laser.addSublayer(ray)
            laser.addSublayer(tip)
            rig.addSublayer(laser)
        }
        let ball = CALayer()
        ball.name = "ball"
        ball.anchorPoint = CGPoint(x: 0.5, y: 1)
        rig.addSublayer(ball)
        return beam
    }

    static func rig(_ beam: CALayer) -> CALayer? { beam.sublayers?.first { $0.name == "rig" } }
    static func parts(_ beam: CALayer, _ name: String) -> [CALayer] { rig(beam)?.sublayers?.filter { $0.name == name } ?? [] }

    /// Shapes a light round a pet drawn `wide` × `high` points with its feet at the beam's origin, `ceiling` points below the
    /// top of the view (the ball comes down rather than off it). `moving`: its loops run; else it stands at `phase`.
    static func shape(_ beam: CALayer, wide: CGFloat, high: CGFloat, ceiling: CGFloat, moving: Bool, phase: Double = 0) {
        guard let rig = rig(beam) else { return }
        let k = max(0.2, high / reference)
        let w = wide / k, h = high / k
        let key = "\(w) \(h) \(ceiling) \(moving)"
        guard rig.value(forKey: "shaped") as? String != key else { return }
        rig.setValue(key, forKey: "shaped")
        rig.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
        let across = OfficeView.lightWide * w, tall = h + OfficeView.lightAbove
        let pictures = OfficeView.lightPictures(OfficeView.lightTone(on: 0x000000))
        for cone in parts(beam, "cone") {
            cone.position = .zero
            cone.bounds = CGRect(x: 0, y: 0, width: across, height: tall)
            cone.contents = pictures?.cone
        }
        for pool in parts(beam, "pool") {
            pool.position = .zero
            pool.bounds = CGRect(x: 0, y: 0, width: across, height: max(10, across * 0.24))
            pool.contents = pictures?.pool
        }
        let ball = parts(beam, "ball").first
        let frames = OfficeView.ballPictures(OfficeTheme.night)
        ball?.position = CGPoint(x: 0, y: max(-tall, OfficeView.ballSize.height - ceiling / k))
        ball?.bounds = CGRect(origin: .zero, size: OfficeView.ballSize)
        let spots = parts(beam, "spot")
        for (spot, layer) in zip(OfficeView.spots, spots) {
            layer.position = OfficeView.place(spot, at: spot.phase + phase, wide: w, high: h)
            layer.bounds = CGRect(x: 0, y: 0, width: spot.size, height: spot.size)
            layer.opacity = spot.opacity
            layer.contents = OfficeView.spotPicture(spot.colour)
        }
        let lasers = parts(beam, "laser")
        let from = (ball?.position.y ?? -tall) - 8, length = -from * 1.02
        let reach = atan(0.8 * across / 2 / max(1, -from))
        for (laser, layer) in zip(OfficeView.lasers, lasers) {
            layer.position = CGPoint(x: 0, y: from)
            layer.bounds = CGRect(x: 0, y: 0, width: OfficeView.laserWide, height: length)
            layer.transform = CATransform3DMakeRotation(OfficeView.angle(laser, at: laser.phase + phase, reach: reach), 0, 0, 1)
            if let ray = layer.sublayers?.first(where: { $0.name == "ray" }), let tip = layer.sublayers?.first(where: { $0.name == "tip" }) {
                ray.frame = layer.bounds
                ray.opacity = OfficeView.laserStrength
                ray.contents = OfficeView.laserPicture(laser.colour)
                tip.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
                tip.position = CGPoint(x: OfficeView.laserWide / 2, y: length)
                tip.opacity = 0.9
                tip.contents = OfficeView.spotPicture(OfficePalette.mix(laser.colour, 0xFFFFFF, 0.5))
            }
        }
        let moving = moving && !frames.isEmpty
        for layer in [ball].compactMap({ $0 }) + spots + lasers { layer.removeAllAnimations() }
        guard moving, let ball else {
            let count = frames.count
            if count > 0 { ball?.contents = frames[(Int((phase * Double(count)).rounded(.down)) % count + count) % count] }
            return
        }
        ball.contents = frames.first
        func stepped(_ path: String, _ values: [Any], first: Int, on layer: CALayer) -> CAKeyframeAnimation {
            let loop = CAKeyframeAnimation(keyPath: path)
            loop.values = values
            loop.calculationMode = .discrete
            loop.duration = OfficeView.discoBeat * Double(values.count)
            loop.timeOffset = OfficeView.discoBeat * Double(first)
            loop.beginTime = layer.convertTime((CACurrentMediaTime() / OfficeView.discoBeat).rounded(.up) * OfficeView.discoBeat, from: nil)
            loop.repeatCount = .infinity
            return loop
        }
        ball.add(stepped("contents", frames.flatMap { Array(repeating: $0, count: OfficeView.ballBeats) }, first: 0, on: ball), forKey: "turn")
        for (laser, layer) in zip(OfficeView.lasers, lasers) {
            let steps = OfficeView.beats(laser.seconds), middle = laser.middle * reach
            let angles = (0..<steps).map { NSNumber(value: Double(OfficeView.angle(laser, at: Double($0) / Double(steps), reach: reach) - middle)) }
            let sweep = stepped("transform.rotation.z", angles, first: OfficeView.first(laser.phase, of: steps), on: layer)
            sweep.isAdditive = true
            layer.add(sweep, forKey: "sweep")
        }
        for (spot, layer) in zip(OfficeView.spots, spots) {
            let rest = OfficeView.place(spot, at: spot.phase, wide: w, high: h), steps = OfficeView.beats(spot.seconds)
            let points = (0..<steps).map { i -> NSValue in
                let p = OfficeView.place(spot, at: Double(i) / Double(steps), wide: w, high: h)
                return NSValue(point: CGPoint(x: p.x - rest.x, y: p.y - rest.y))
            }
            let drift = stepped("position", points, first: OfficeView.first(spot.phase, of: steps), on: layer)
            drift.isAdditive = true
            layer.add(drift, forKey: "drift")
        }
    }

    /// Every layer of the light that moves of its own.
    static func moving(_ beam: CALayer) -> [CALayer] { parts(beam, "ball") + parts(beam, "spot") + parts(beam, "laser") }

    /// Holds the light's loops where they are (Orca behind, nobody looking), or lets them go on from there, on the beat.
    static func hold(_ beam: CALayer, _ held: Bool) {
        for layer in moving(beam) where (layer.speed == 0) != held {
            if held {
                let now = layer.convertTime(CACurrentMediaTime(), from: nil)
                layer.speed = 0
                layer.timeOffset = now
            } else {
                let was = layer.timeOffset
                layer.speed = 1
                layer.timeOffset = 0
                layer.beginTime = 0
                layer.beginTime = ((layer.convertTime(CACurrentMediaTime(), from: nil) - was) / OfficeView.discoBeat).rounded() * OfficeView.discoBeat
            }
        }
    }
}

// ───────── Walking frames ─────────

/// A figure walking to its new place runs as the office's pets do: the sheet's running rows (1 to the right, 2 to the
/// left; through `OfficePets.runFrame`, which applies `pet-facing.json` to the sheets that do not keep to that), eight
/// frames of 0.1 s, chosen leg by leg by which way the leg goes across. a leg nearly straight up or down (across by
/// less than a quarter of its length) keeps the facing of the leg before (the first one, of the next leg that goes across;
/// to the right when none does), so a figure does not flip on a sliver of sideways step. On arrival the running comes off
/// and its pose's own loop shows.
enum ZoneWalk {
    static let right = 1
    static let left = 2
    static let frames = 8
    static let step = 0.1
    /// a leg across by less than this share of its length counts as up or down and keeps its facing.
    nonisolated static let nearlyUpright: CGFloat = 0.25

    /// The running facing for each leg of a route.
    static func rows(_ route: [CGPoint]) -> [Int] {
        let across = zip(route, route.dropFirst()).map { a, b -> Int in
            let dx = b.x - a.x, length = hypot(dx, b.y - a.y)
            return abs(dx) < 0.5 || abs(dx) < length * nearlyUpright ? 0 : (dx > 0 ? right : left)
        }
        var out: [Int] = []
        for i in across.indices {
            if across[i] != 0 { out.append(across[i]); continue }
            if let before = out.last { out.append(before); continue }
            out.append(across[i...].first(where: { $0 != 0 }) ?? right)
        }
        return out
    }

    /// The running frames along a walk, leg by leg, a frame each `step`, as one discrete animation of `seconds`; nil when no
    /// leg has frames.
    static func steps(_ frames: [Int: [CGImage]], route: [CGPoint], seconds: Double) -> CAKeyframeAnimation? {
        let rows = rows(route)
        let lengths = zip(route, route.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let total = lengths.reduce(0, +)
        guard total > 0, seconds > 0 else { return nil }
        var values: [CGImage] = [], times: [NSNumber] = []
        var start = 0.0
        for (row, length) in zip(rows, lengths) where length > 0 {
            let span = seconds * Double(length / total)
            guard let shown = frames[row], !shown.isEmpty else { return nil }
            var t = 0.0
            repeat {
                // SEAT: counted along the whole walk, not from each leg, so a run of short legs still runs.
                values.append(shown[Int(((start + t) / step).rounded()) % shown.count])
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
}

// ───────── Outdoors ─────────
//
// The sea, the crabs and the gulls past the railing: a pre-rendered loop (`outdoor_loop.mov`, HEVC with alpha) over the
// picture's outdoor rectangle, played by AVFoundation (decoded in hardware); crabs and gulls as cut sprites moved by Core
// Animation. Between events one `DispatchWorkItem` waits for the next; nothing here wakes up per frame. All points are in
// the picture's pixels (top-left origin) until `ZoneFit` takes them to the view.

/// a random source a check can replay (SplitMix64).
struct ZoneRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// one crab species from `outdoor.json` `crabs` (its own sprite set, size, foot, walk and pace), with the picture's
/// rectangle and the loop's box it keeps to.
struct ZoneCrabSpec {
    let kind: String
    let frames: Int
    let size: CGSize
    /// The crab's ground point inside its frame.
    let foot: CGPoint
    /// Picture pixels for a metre of its walk (along the beach).
    let walk: CGVector
    /// The beach it keeps to, as the render gives it (it runs past the picture).
    let zone: [CGPoint]
    /// Its pace, metres a second.
    let speed: CGFloat
    /// The way it is drawn heading along `walk`: 1 the sideways crabs (and any drawn heading `walk`), -1 the hermit, whose
    /// sprite heads picture-left (against `walk`); it is flipped to walk the other way.
    let drawn: CGFloat
    let picture: CGSize
    let loopBox: CGRect
    /// beach walkers (the crabs, and `outdoor.json` `walkers`: the sandpiper, the turtle, the clam) share this spec.
    /// How it lives: `scuttle` (a crab: short walks, short rests), `shoreRun` (the sandpiper: quick runs, pecks between),
    /// `crawlRest` (the turtle: slow crawls, long rests with its head in), `stationary` (the clam: never moves).
    enum Behavior: String { case scuttle, shoreRun, crawlRest, stationary }
    /// what it does when the orca comes up on the sand: `scatter` (runs off, each its own way, and comes back),
    /// `outside` (lives where the orca never comes), `fixed` (stays put; the clip may cover it).
    enum Threat: String { case scatter, outside, fixed }
    var behavior: Behavior = .scuttle
    var threat: Threat = .scatter
    /// its own frame rate, and the frames (1-based) it walks with and those it shows resting (none: frame 1).
    var fps: Double = 24
    var walkFrames: ClosedRange<Int>? = nil
    var idleFrames: ClosedRange<Int>? = nil

    /// The sprite files' stem: `sprites/crab_<kind>_NN`.
    var stem: String { "sprites/crab_\(kind)_" }

    /// The beach clipped to the picture and to the loop's rectangle.
    var clippedZone: [CGPoint] { ZoneOutdoorGeometry.clip(zone, to: CGRect(origin: .zero, size: picture).intersection(loopBox)) }

    /// Where its foot may be: the clipped beach, pulled in so its whole frame stays inside the picture and the loop.
    var beach: [CGPoint] {
        let r = CGRect(origin: .zero, size: picture).intersection(loopBox)
        let inner = CGRect(x: r.minX + foot.x, y: r.minY + foot.y, width: r.width - size.width, height: r.height - size.height)
        return ZoneOutdoorGeometry.clip(zone, to: inner)
    }

    /// The layer's x scale for walking `facing` (1 along `walk`, -1 back).
    func flip(_ facing: CGFloat) -> CGFloat { facing * drawn }
}

/// one gull species from `outdoor.json` `gulls` (its own sprite set and speed).
struct ZoneGullSpec {
    let kind: String
    let frames: Int
    let size: CGSize
    /// The gull's middle inside its frame.
    let centre: CGPoint
    let shadowPerMetre: CGFloat
    let speed: CGFloat
    let pixelsPerMetre: CGFloat

    var stem: String { "sprites/gull_\(kind)_" }
    var pixelsPerSecond: CGFloat { speed * pixelsPerMetre }
    /// The soft shadow's size on the ground under it.
    var shadowSize: CGSize { CGSize(width: size.width * 0.55, height: size.width * 0.2) }
    /// How far from its middle its frame reaches, whichever way it is turned.
    var reach: CGFloat {
        [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
            .map { hypot($0.x - centre.x, $0.y - centre.y) }.max() ?? 0
    }
    /// How often a flight is this species. herring 40 %, black-headed 30 %, tern 30 % (a 50/30/20 split left the
    /// other two hard to notice; any other kind 1 share in 10).
    var weight: Double { ["herring": 4, "blackhead": 3, "tern": 3][kind] ?? 1 }
}

/// a gull standing on the sand (`outdoor.json` `gull_stands`): its sprite pair (still, head bob), size and foot. Drawn
/// heading picture-right.
struct ZoneGullStandSpec {
    let kind: String
    let frames: Int
    let size: CGSize
    let foot: CGPoint
    var stem: String { "sprites/gullstand_\(kind)_" }
}

/// what `outdoor.json` says (with the picture's pixels a metre from points.json), and what follows from it. a
/// list of crab species and a list of gull species.
struct ZoneOutdoorSpec {
    let picture: CGSize
    /// The loop's rectangle in the picture.
    let loopBox: CGRect
    let loopFrames: Int
    let fps: Double
    let crabs: [ZoneCrabSpec]
    let gulls: [ZoneGullSpec]
    /// Picture pixels a metre across the camera (points.json `pixel_scale.pixels_per_meter`).
    let pixelsPerMetre: CGFloat
    /// the other beach dwellers (`walkers`), handled like the crabs, and the gulls' standing sprites.
    var walkers: [ZoneCrabSpec] = []
    var gullStands: [ZoneGullStandSpec] = []
    /// the balcony rail's top edge in the picture (`deck_line`, two points). An animal whose foot is below it is on
    /// the deck behind the railing (they may wander there): safe from the orca, it does not run.
    var deckLine: (CGPoint, CGPoint)?
    func onDeck(_ p: CGPoint) -> Bool {
        guard let (a, b) = deckLine, abs(b.x - a.x) > 1e-6 else { return false }
        return p.y > a.y + (b.y - a.y) * (p.x - a.x) / (b.x - a.x)
    }

    /// every beach dweller, crabs first: a `Crab`'s `species` indexes this (so under `crabs.count` it is a crab).
    var dwellers: [ZoneCrabSpec] { crabs + walkers }
    func dweller(_ i: Int) -> ZoneCrabSpec? { i >= 0 && i < crabs.count ? crabs[i] : (i >= crabs.count && i - crabs.count < walkers.count ? walkers[i - crabs.count] : nil) }
    func stand(_ kind: String) -> ZoneGullStandSpec? { gullStands.first { $0.kind == kind } }

    /// Crab kinds drawn heading against `walk` (picture-left).
    static let drawnBackwards: Set<String> = ["hermit"]

    static func parse(_ data: Data, pixelsPerMetre: CGFloat) -> ZoneOutdoorSpec? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let crabList = o["crabs"] as? [[String: Any]],
            let gullList = o["gulls"] as? [[String: Any]], let loop = o["loop"] as? [String: Any], pixelsPerMetre > 0
        else { return nil }
        func nums(_ v: Any?) -> [CGFloat] { (v as? [Any])?.compactMap { ($0 as? NSNumber).map { CGFloat($0.doubleValue) } } ?? [] }
        func num(_ v: Any?) -> CGFloat? { (v as? NSNumber).map { CGFloat($0.doubleValue) } }
        let pic = nums(o["picture"]), box = nums(loop["box"])
        guard pic.count == 2, box.count == 4 else { return nil }
        let picture = CGSize(width: pic[0], height: pic[1])
        let loopBox = CGRect(x: box[0], y: box[1], width: box[2] - box[0], height: box[3] - box[1])
        func dweller(_ crab: [String: Any]) -> ZoneCrabSpec? {
            let cc = nums(crab["crop"]), cf = nums(crab["foot"]), w = nums(crab["walk_px_per_m"])
            let zone: [[CGFloat]] = ((crab["zone"] as? [Any]) ?? []).map { nums($0) }
            let behavior = (crab["behavior"] as? String).flatMap(ZoneCrabSpec.Behavior.init(rawValue:)) ?? .scuttle
            guard let kind = crab["kind"] as? String, !kind.isEmpty, cc.count == 4, cf.count == 2, w.count == 2, zone.count >= 3,
                zone.allSatisfy({ $0.count == 2 }), let speed = num(crab["speed_m_per_s"]), speed > 0 || behavior == .stationary
            else { return nil }
            let frames = Int(num(crab["frames"]) ?? 6)
            func range(_ v: Any?) -> ClosedRange<Int>? {
                let r = nums(v).map { Int($0) }
                return r.count == 2 && 1 <= r[0] && r[0] <= r[1] && r[1] <= frames ? r[0]...r[1] : nil
            }
            var spec = ZoneCrabSpec(
                kind: kind, frames: frames, size: CGSize(width: cc[2] - cc[0], height: cc[3] - cc[1]),
                foot: CGPoint(x: cf[0] - cc[0], y: cf[1] - cc[1]), walk: CGVector(dx: w[0], dy: w[1]), zone: zone.map { CGPoint(x: $0[0], y: $0[1]) },
                speed: speed, drawn: drawnBackwards.contains(kind) ? -1 : 1, picture: picture, loopBox: loopBox)
            spec.behavior = behavior
            spec.threat = (crab["threat"] as? String).flatMap(ZoneCrabSpec.Threat.init(rawValue:)) ?? .scatter
            spec.fps = Double(num(crab["fps"]) ?? 24)
            spec.walkFrames = range(crab["walk_frames"])
            spec.idleFrames = range(crab["idle_frames"])
            return spec
        }
        var crabs: [ZoneCrabSpec] = []
        for crab in crabList {
            guard let c = dweller(crab) else { return nil }
            crabs.append(c)
        }
        var walkers: [ZoneCrabSpec] = []
        for w in (o["walkers"] as? [[String: Any]]) ?? [] {
            if let c = dweller(w) { walkers.append(c) }
        }
        var stands: [ZoneGullStandSpec] = []
        for g in (o["gull_stands"] as? [[String: Any]]) ?? [] {
            let gc = nums(g["crop"]), gf = nums(g["foot"])
            guard let kind = g["kind"] as? String, gc.count == 4, gf.count == 2 else { continue }
            stands.append(ZoneGullStandSpec(kind: kind, frames: Int(num(g["frames"]) ?? 2), size: CGSize(width: gc[2] - gc[0], height: gc[3] - gc[1]),
                                            foot: CGPoint(x: gf[0] - gc[0], y: gf[1] - gc[1])))
        }
        var gulls: [ZoneGullSpec] = []
        for gull in gullList {
            let gc = nums(gull["crop"]), gm = nums(gull["centre"])
            guard let kind = gull["kind"] as? String, !kind.isEmpty, gc.count == 4, gm.count == 2,
                let shadow = num(gull["shadow_offset_px_per_m_height"]), let speed = num(gull["speed_m_per_s"]), speed > 0
            else { return nil }
            gulls.append(ZoneGullSpec(
                kind: kind, frames: Int(num(gull["frames"]) ?? 48), size: CGSize(width: gc[2] - gc[0], height: gc[3] - gc[1]),
                centre: CGPoint(x: gm[0] - gc[0], y: gm[1] - gc[1]), shadowPerMetre: shadow, speed: speed, pixelsPerMetre: pixelsPerMetre))
        }
        guard !crabs.isEmpty, !gulls.isEmpty else { return nil }
        let deck: [[CGFloat]] = ((o["deck_line"] as? [Any]) ?? []).map { nums($0) }
        return ZoneOutdoorSpec(picture: picture, loopBox: loopBox, loopFrames: Int(num(loop["frames"]) ?? 288), fps: Double(num(loop["fps"]) ?? 24),
                               crabs: crabs, gulls: gulls, pixelsPerMetre: pixelsPerMetre, walkers: walkers, gullStands: stands,
                               deckLine: deck.count == 2 && deck.allSatisfy { $0.count == 2 } ? (CGPoint(x: deck[0][0], y: deck[0][1]), CGPoint(x: deck[1][0], y: deck[1][1])) : nil)
    }

    /// A gull species for a flight, by the species' weights.
    func gullSpecies<R: RandomNumberGenerator>(using rng: inout R) -> Int {
        let total = gulls.reduce(0) { $0 + $1.weight }
        var roll = Double.random(in: 0..<max(total, 1e-9), using: &rng)
        for (i, g) in gulls.enumerated() {
            roll -= g.weight
            if roll < 0 { return i }
        }
        return gulls.count - 1
    }
}

/// one orca clip from `orca.json` (a short HEVC-with-alpha film laid over the sea loop at `box`).
struct ZoneOrcaClip: Equatable {
    let id: String
    let file: String
    /// Where it lies on the picture (pixels, top-left origin).
    let box: CGRect
    let frames: Int
    let fps: Double
    /// The sea loop's frame its first frame belongs to (its waterline matches only from there).
    let startLoopFrame: Int
    /// where the orca really goes on the picture (`clear_zone`, from app/tools/orca_clear_zone.swift):
    /// the crabs whose frame meets it step aside while it plays. Empty: none do (unless it is a landing clip without one).
    var clearZone: [CGRect] = []
    /// a landing clip's strike (orca.json `strike`): where gulls come to rest before it (their feet, picture pixels),
    /// the clip frames at which each takes off, and the orca's way in (`path`: from out at sea to its nose on the sand),
    /// which the beach animals run away from.
    var strike: ZoneOrcaStrike?
    var seconds: Double { Double(frames) / max(1, fps) }
}

/// see `ZoneOrcaClip.strike`.
struct ZoneOrcaStrike: Equatable {
    var gullSpots: [CGPoint]
    var takeoffFrames: [Int]
    var from: CGPoint
    var to: CGPoint
    /// The way in, a unit vector in the picture.
    var heading: CGVector {
        let l = max(1e-9, hypot(to.x - from.x, to.y - from.y))
        return CGVector(dx: (to.x - from.x) / l, dy: (to.y - from.y) / l)
    }
    /// Which side of the way in `p` is on (1 or -1), and how far from it (pixels).
    func side(_ p: CGPoint) -> (CGFloat, CGFloat) {
        let h = heading, c = (p.x - from.x) * h.dy - (p.y - from.y) * h.dx
        return (c >= 0 ? 1 : -1, abs(c))
    }
}

/// what `orca.json` says: the clips and the loop they are rendered against.
struct ZoneOrcaSpec: Equatable {
    let picture: CGSize
    let loopFrames: Int
    let loopFPS: Double
    let clips: [ZoneOrcaClip]

    var ids: [String] { clips.map(\.id) }
    func clip(_ id: String) -> ZoneOrcaClip? { clips.first { $0.id == id } }
    /// The loop's length, seconds.
    var loopSeconds: Double { Double(loopFrames) / max(1, loopFPS) }

    static func parse(_ data: Data) -> ZoneOrcaSpec? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let list = o["clips"] as? [[String: Any]] else { return nil }
        func nums(_ v: Any?) -> [Double] { (v as? [Any])?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? [] }
        let pic = nums(o["picture"])
        let loop = o["loop"] as? [String: Any] ?? [:]
        guard pic.count == 2 else { return nil }
        let fps = (o["fps"] as? NSNumber)?.doubleValue ?? 24
        var clips: [ZoneOrcaClip] = []
        for c in list {
            let b = nums(c["box"])
            guard let id = c["id"] as? String, !id.isEmpty, let file = c["file"] as? String, !file.isEmpty, b.count == 4, b[2] > b[0], b[3] > b[1],
                let frames = (c["frames"] as? NSNumber)?.intValue, frames > 0
            else { return nil }
            var zone: [CGRect] = []
            for entry in (c["clear_zone"] as? [Any]) ?? [] {
                let r: [Double] = nums(entry)
                if r.count == 4, r[2] > r[0], r[3] > r[1] { zone.append(CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1])) }
            }
            var strike: ZoneOrcaStrike?
            if let st = c["strike"] as? [String: Any] {
                let spots = ((st["gull_spots"] as? [Any]) ?? []).map { nums($0) }.filter { $0.count == 2 }.map { CGPoint(x: $0[0], y: $0[1]) }
                let takeoff = ((st["takeoff_frames"] as? [Any]) ?? []).compactMap { ($0 as? NSNumber)?.intValue }
                let path = ((st["path"] as? [Any]) ?? []).map { nums($0) }
                if path.count == 2, path.allSatisfy({ $0.count == 2 }) {
                    strike = ZoneOrcaStrike(gullSpots: spots, takeoffFrames: takeoff, from: CGPoint(x: path[0][0], y: path[0][1]),
                                            to: CGPoint(x: path[1][0], y: path[1][1]))
                }
            }
            clips.append(ZoneOrcaClip(id: id, file: file, box: CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1]), frames: frames,
                                      fps: (c["fps"] as? NSNumber)?.doubleValue ?? fps, startLoopFrame: (c["start_loop_frame"] as? NSNumber)?.intValue ?? 0,
                                      clearZone: zone, strike: strike))
        }
        guard !clips.isEmpty else { return nil }
        return ZoneOrcaSpec(picture: CGSize(width: pic[0], height: pic[1]), loopFrames: (loop["frames"] as? NSNumber)?.intValue ?? 288,
                            loopFPS: (loop["fps"] as? NSNumber)?.doubleValue ?? fps, clips: clips)
    }

    /// the clips that come up on the sand (C): the crabs where they land step aside for them. Where the orca
    /// really goes is the clip's `clear_zone`; only a landing clip with no zone written falls back to its whole box.
    static let landing: Set<String> = ["C"]

    /// Where the crabs step aside for a clip (empty: they do not).
    static func stepAside(_ clip: ZoneOrcaClip) -> [CGRect] {
        !clip.clearZone.isEmpty ? clip.clearZone : landing.contains(clip.id) ? [clip.box] : []
    }

    /// The wait before the next clip: 3–8 min, uniform.
    static func interval<R: RandomNumberGenerator>(using rng: inout R) -> Double { Double.random(in: 180...480, using: &rng) }

    /// Which clip comes next: any but the last one shown (when there is more than one).
    static func pick<R: RandomNumberGenerator>(after last: String?, ids: [String], using rng: inout R) -> String? {
        (ids.count > 1 ? ids.filter { $0 != last } : ids).randomElement(using: &rng)
    }

    /// Seconds from a loop time `t` to the next time the loop is at `frame` (its start, frame 0, by default), never less
    /// than `lead` (else one loop later).
    static func untilLoopFrame(_ frame: Int = 0, at t: Double, loopSeconds: Double, fps: Double, lead: Double = 0.25) -> Double {
        guard loopSeconds > 0 else { return 0 }
        let target = Double(frame) / max(1, fps)
        var wait = (target - t).truncatingRemainder(dividingBy: loopSeconds)
        if wait < 0 { wait += loopSeconds }
        if wait < lead { wait += loopSeconds }
        return wait
    }
}

/// one crab's walk, from where it stands to where it stops.
struct ZoneCrabWalk: Equatable {
    var from: CGPoint
    var to: CGPoint
    var seconds: Double
    /// 1 walking the way `walk` points (the sprite as drawn), -1 the other way (the sprite flipped).
    var facing: CGFloat
    func at(_ t: Double) -> CGPoint {
        let k = seconds > 0 ? CGFloat(max(0, min(1, t / seconds))) : 1
        return CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
    }
}

/// one gull's flight, a straight line from off the picture to off the picture.
struct ZoneGullFlight: Equatable {
    var from: CGPoint
    var to: CGPoint
    /// Metres above the ground: how far its shadow falls below it.
    var height: CGFloat
    var seconds: Double
    /// Seconds after the flight is called that it sets off (the second of a pair follows a little behind).
    var delay: Double
    var shadowDrop: CGFloat
    /// which of `outdoor.json`'s gull species flies it (its sprites).
    var species: Int = 0
    var heading: CGVector {
        let l = max(1e-9, hypot(to.x - from.x, to.y - from.y))
        return CGVector(dx: (to.x - from.x) / l, dy: (to.y - from.y) / l)
    }
    func at(_ t: Double) -> CGPoint {
        let k = seconds > 0 ? CGFloat(t / seconds) : 1
        return CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)
    }
}

enum ZoneOutdoorGeometry {
    /// A polygon cut to a rectangle (Sutherland–Hodgman).
    static func clip(_ polygon: [CGPoint], to r: CGRect) -> [CGPoint] {
        guard !r.isNull, r.width > 0, r.height > 0 else { return [] }
        let sides: [(CGPoint) -> CGFloat] = [{ $0.x - r.minX }, { r.maxX - $0.x }, { $0.y - r.minY }, { r.maxY - $0.y }]
        var out = polygon
        for inside in sides {
            let input = out
            out = []
            guard var s = input.last else { break }
            for e in input {
                let de = inside(e), ds = inside(s)
                func cut() -> CGPoint {
                    let t = ds / (ds - de)
                    return CGPoint(x: s.x + (e.x - s.x) * t, y: s.y + (e.y - s.y) * t)
                }
                if de >= 0 {
                    if ds < 0 { out.append(cut()) }
                    out.append(e)
                } else if ds >= 0 {
                    out.append(cut())
                }
                s = e
            }
        }
        return out
    }

    /// Whether a convex polygon holds a point (its edges count as inside).
    static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        guard polygon.count >= 3 else { return false }
        var sign: CGFloat = 0
        for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) {
            let c = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if abs(c) <= 1e-6 * max(1, hypot(b.x - a.x, b.y - a.y)) { continue }
            if sign == 0 { sign = c } else if (c > 0) != (sign > 0) { return false }
        }
        return true
    }

    static func randomPoint<R: RandomNumberGenerator>(in polygon: [CGPoint], using rng: inout R) -> CGPoint? {
        guard polygon.count >= 3 else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let box = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard box.width > 0, box.height > 0 else { return nil }
        for _ in 0..<20_000 {
            let p = CGPoint(x: CGFloat.random(in: box.minX...box.maxX, using: &rng), y: CGFloat.random(in: box.minY...box.maxY, using: &rng))
            if contains(polygon, p) { return p }
        }
        return nil
    }

    /// How many metres from `p` along `d` (pixels a metre) stay inside the polygon, up to `limit`.
    static func reach(from p: CGPoint, along d: CGVector, in polygon: [CGPoint], limit: CGFloat = 12) -> CGFloat {
        func inside(_ m: CGFloat) -> Bool { contains(polygon, CGPoint(x: p.x + d.dx * m, y: p.y + d.dy * m)) }
        guard inside(0) else { return 0 }
        if inside(limit) { return limit }
        var lo: CGFloat = 0, hi = limit
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if inside(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// A crab's next walk: 1–3 m along the beach (its own walk vector), either way, kept on its beach (the other way when
    /// the first does not fit, else as far as the roomier way goes), at its species' pace.
    static func crabStep<R: RandomNumberGenerator>(from p: CGPoint, crab: ZoneCrabSpec, using rng: inout R) -> ZoneCrabWalk {
        let beach = crab.beach, w = crab.walk
        var metres = CGFloat.random(in: 1...3, using: &rng)
        let first: CGFloat = Bool.random(using: &rng) ? 1 : -1
        var facing = first
        if !contains(beach, CGPoint(x: p.x + w.dx * metres * first, y: p.y + w.dy * metres * first)) {
            if contains(beach, CGPoint(x: p.x - w.dx * metres * first, y: p.y - w.dy * metres * first)) {
                facing = -first
            } else {
                let ahead = reach(from: p, along: w, in: beach), back = reach(from: p, along: CGVector(dx: -w.dx, dy: -w.dy), in: beach)
                facing = ahead >= back ? 1 : -1
                metres = min(metres, max(ahead, back) * 0.98)
            }
        }
        let to = CGPoint(x: p.x + w.dx * metres * facing, y: p.y + w.dy * metres * facing)
        return ZoneCrabWalk(from: p, to: to, seconds: Double(metres / crab.speed), facing: facing)
    }

    /// The walk off the beach: along the beach to its nearer end.
    static func crabExit(from p: CGPoint, crab: ZoneCrabSpec) -> ZoneCrabWalk {
        let beach = crab.beach, w = crab.walk
        let ahead = reach(from: p, along: w, in: beach), back = reach(from: p, along: CGVector(dx: -w.dx, dy: -w.dy), in: beach)
        let facing: CGFloat = ahead <= back ? 1 : -1, metres = min(ahead, back)
        return ZoneCrabWalk(from: p, to: CGPoint(x: p.x + w.dx * metres * facing, y: p.y + w.dy * metres * facing),
                            seconds: Double(max(metres, 0.2) / crab.speed), facing: facing)
    }

    /// One or two gulls across the whole picture: a straight line between two different edges, any way, each flight drawn
    /// out at both ends until the gull and its shadow are off the picture. the flight's species is picked by weight
    /// (a pair is one species), and flies at its own speed.
    static func gullFlights<R: RandomNumberGenerator>(spec: ZoneOutdoorSpec, using rng: inout R) -> [ZoneGullFlight] {
        let W = spec.picture.width, H = spec.picture.height
        func onEdge(_ e: Int) -> CGPoint {
            switch e {
            case 0: return CGPoint(x: CGFloat.random(in: 0...W, using: &rng), y: 0)
            case 1: return CGPoint(x: W, y: CGFloat.random(in: 0...H, using: &rng))
            case 2: return CGPoint(x: CGFloat.random(in: 0...W, using: &rng), y: H)
            default: return CGPoint(x: 0, y: CGFloat.random(in: 0...H, using: &rng))
            }
        }
        // Long enough, and through the picture rather than across a corner or along an edge (its middle well inside).
        let inner = CGRect(origin: .zero, size: spec.picture).insetBy(dx: W * 0.15, dy: H * 0.15)
        var a = CGPoint(x: 0, y: H / 2), b = CGPoint(x: W, y: H / 2)
        for _ in 0..<200 {
            let e1 = Int.random(in: 0..<4, using: &rng)
            let e2 = (e1 + Int.random(in: 1..<4, using: &rng)) % 4
            let p = onEdge(e1), q = onEdge(e2)
            if hypot(q.x - p.x, q.y - p.y) >= W * 0.45, inner.contains(CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)) {
                a = p
                b = q
                break
            }
        }
        let height = CGFloat.random(in: 1.5...6, using: &rng)
        let species = spec.gullSpecies(using: &rng)
        var flights = [flight(a, b, height: height, delay: 0, spec: spec, species: species)]
        if Bool.random(using: &rng) {
            let l = max(1e-9, hypot(b.x - a.x, b.y - a.y))
            let n = CGVector(dx: -(b.y - a.y) / l, dy: (b.x - a.x) / l)
            let off = CGFloat.random(in: 50...120, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
            let second = max(1.5, min(6, height + CGFloat.random(in: -0.8...0.8, using: &rng)))
            flights.append(flight(CGPoint(x: a.x + n.dx * off, y: a.y + n.dy * off), CGPoint(x: b.x + n.dx * off, y: b.y + n.dy * off),
                                  height: second, delay: Double.random(in: 0.3...1.2, using: &rng), spec: spec, species: species))
        }
        return flights
    }

    /// The line a…b drawn out at both ends until the gull (its frame turned any way) and its shadow are off the picture.
    static func flight(_ a: CGPoint, _ b: CGPoint, height: CGFloat, delay: Double, spec: ZoneOutdoorSpec, species: Int = 0) -> ZoneGullFlight {
        let picture = CGRect(origin: .zero, size: spec.picture), gull = spec.gulls[max(0, min(spec.gulls.count - 1, species))]
        let l = max(1e-9, hypot(b.x - a.x, b.y - a.y)), d = CGVector(dx: (b.x - a.x) / l, dy: (b.y - a.y) / l)
        let drop = height * gull.shadowPerMetre, r = gull.reach, rs = max(gull.shadowSize.width, gull.shadowSize.height) / 2
        func off(_ p: CGPoint) -> Bool {
            !picture.insetBy(dx: -r, dy: -r).contains(p) && !picture.insetBy(dx: -rs, dy: -rs).contains(CGPoint(x: p.x, y: p.y + drop))
        }
        var from = a, to = b
        for _ in 0..<4000 where !off(from) { from = CGPoint(x: from.x - d.dx * 8, y: from.y - d.dy * 8) }
        for _ in 0..<4000 where !off(to) { to = CGPoint(x: to.x + d.dx * 8, y: to.y + d.dy * 8) }
        let seconds = Double(hypot(to.x - from.x, to.y - from.y) / max(1, gull.pixelsPerSecond))
        return ZoneGullFlight(from: from, to: to, height: height, seconds: seconds, delay: delay, shadowDrop: drop,
                              species: max(0, min(spec.gulls.count - 1, species)))
    }

    /// a frightened animal's own escape: away from the orca's way in (to the side of it the animal is on), turned by
    /// its own random spread (up to ±55°, never back towards the incoming orca), at its own speed (2.2–3.4 times its pace),
    /// to a random distance clear of `keepOut`, kept on its beach; half of them stop once on the way (0.2–0.7 s) and run on.
    /// Returns the legs and the pause before each.
    static func scatter<R: RandomNumberGenerator>(from p: CGPoint, crab: ZoneCrabSpec, strike: ZoneOrcaStrike, keepOut: [CGRect],
                                                  frame: (CGPoint) -> CGRect, using rng: inout R) -> [(walk: ZoneCrabWalk, pause: Double)] {
        let beach = crab.beach, h = strike.heading
        let (side, _) = strike.side(p)
        let normal = CGVector(dx: h.dy * side, dy: -h.dx * side)          // away from the line of the way in
        let perMetre = max(1, hypot(crab.walk.dx, crab.walk.dy))
        let pace = max(crab.speed, 0.25) * perMetre * CGFloat.random(in: 2.2...3.4, using: &rng)
        func clear(_ q: CGPoint) -> Bool { !keepOut.contains { frame(q).insetBy(dx: -14, dy: -14).intersects($0) } }
        // Up to 6 clear ways (random turns of the side's normal, wider after 30 tries, never within 50° of back at the
        // orca coming in), one of them picked at random; else the reachable spot farthest from the way in.
        var ways: [(CGPoint, CGFloat)] = [], fallback: (CGPoint, CGFloat, CGFloat)?
        for attempt in 0..<140 where ways.count < 6 {
            let limit: CGFloat = attempt < 30 ? 75 : 180
            let spread = CGFloat.random(in: -limit...limit, using: &rng) * .pi / 180
            let d = CGVector(dx: normal.dx * cos(spread) - normal.dy * sin(spread), dy: normal.dx * sin(spread) + normal.dy * cos(spread))
            if d.dx * -h.dx + d.dy * -h.dy > 0.64 { continue }
            var reach: CGFloat = 0
            var clearAt: CGFloat?
            while reach < 900 {
                let q = CGPoint(x: p.x + d.dx * (reach + 8), y: p.y + d.dy * (reach + 8))
                if !ZoneOutdoorGeometry.contains(beach, q) { break }
                reach += 8
                if clearAt == nil && clear(q) { clearAt = reach }
            }
            if let c = clearAt {
                let want = min(reach, c + CGFloat.random(in: 40...150, using: &rng))
                ways.append((CGPoint(x: p.x + d.dx * want, y: p.y + d.dy * want), want))
            } else if reach > 8 {
                let q = CGPoint(x: p.x + d.dx * reach, y: p.y + d.dy * reach)
                let off = strike.side(q).1
                if fallback == nil || off > fallback!.2 { fallback = (q, reach, off) }
            }
        }
        let best: (CGPoint, CGFloat)? = ways.randomElement(using: &rng) ?? fallback.map { ($0.0, $0.1) }
        guard var (to, _) = best else { return [] }
        // Its own end and its own zigzag: the end shifted across the way by up to ±70 px, the route bent at a random point
        // by up to ±60 px (where the beach allows), and half of them stop there a moment.
        func across(_ q: CGPoint, _ from: CGPoint, _ by: CGFloat) -> CGPoint {
            let l = max(1e-6, hypot(q.x - from.x, q.y - from.y))
            return CGPoint(x: q.x - (q.y - from.y) / l * by, y: q.y + (q.x - from.x) / l * by)
        }
        for _ in 0..<6 {
            let q = across(to, p, CGFloat.random(in: -70...70, using: &rng))
            if ZoneOutdoorGeometry.contains(beach, q) && (clear(q) || !clear(to)) { to = q; break }
        }
        let dist = hypot(to.x - p.x, to.y - p.y)
        guard dist > 1 else { return [] }
        func facing(_ a: CGPoint, _ b: CGPoint) -> CGFloat { (b.x - a.x) * crab.walk.dx + (b.y - a.y) * crab.walk.dy >= 0 ? 1 : -1 }
        func leg(_ a: CGPoint, _ b: CGPoint) -> ZoneCrabWalk {
            ZoneCrabWalk(from: a, to: b, seconds: Double(hypot(b.x - a.x, b.y - a.y) / (pace * CGFloat.random(in: 0.85...1.15, using: &rng))), facing: facing(a, b))
        }
        if dist > 50 {
            let k = CGFloat.random(in: 0.3...0.7, using: &rng)
            var mid = CGPoint(x: p.x + (to.x - p.x) * k, y: p.y + (to.y - p.y) * k)
            for _ in 0..<6 {
                let q = across(mid, p, CGFloat.random(in: -60...60, using: &rng))
                if ZoneOutdoorGeometry.contains(beach, q) { mid = q; break }
            }
            let pause = Bool.random(using: &rng) ? Double.random(in: 0.2...0.7, using: &rng) : 0
            return [(leg(p, mid), 0), (leg(mid, to), pause)]
        }
        return [(leg(p, to), 0)]
    }

    /// a gull gliding in to stand at `foot`: from off the picture on the sea side, coming down from 3–5 m, at a little
    /// under its flying speed. `track` gives (ground point, height m) at a fraction 0…1 of the way.
    struct GullPath {
        var start: CGPoint, end: CGPoint
        var h0: CGFloat, h1: CGFloat
        var seconds: Double
        var delay: Double
        var species: Int
        /// Height easing: landing comes down and flares (h0 → 0, slowing), a take-off climbs fast then levels (0 → h1).
        var landing: Bool
        var heading: CGVector {
            let l = max(1e-9, hypot(end.x - start.x, end.y - start.y))
            return CGVector(dx: (end.x - start.x) / l, dy: (end.y - start.y) / l)
        }
        func at(_ k: CGFloat) -> (ground: CGPoint, height: CGFloat) {
            let e = landing ? 1 - (1 - k) * (1 - k) : k
            let g = CGPoint(x: start.x + (end.x - start.x) * e, y: start.y + (end.y - start.y) * e)
            let h = landing ? h0 * (1 - k) * (1 - k) : h1 * (1 - (1 - k) * (1 - k) * (1 - k))
            return (g, h)
        }
    }

    static func gullLanding<R: RandomNumberGenerator>(at foot: CGPoint, spec: ZoneOutdoorSpec, species: Int, delay: Double, using rng: inout R) -> GullPath {
        let gull = spec.gulls[max(0, min(spec.gulls.count - 1, species))]
        // From the sea side (picture up), any way between up-left and up-right.
        let a = CGFloat.random(in: -150 ... -30, using: &rng) * .pi / 180
        let d = CGVector(dx: cos(a), dy: sin(a))
        let picture = CGRect(origin: .zero, size: spec.picture).insetBy(dx: -gull.reach, dy: -gull.reach)
        var dist: CGFloat = 200
        while picture.contains(CGPoint(x: foot.x + d.dx * dist, y: foot.y + d.dy * dist)) && dist < 5000 { dist += 40 }
        dist += 80
        let h0 = CGFloat.random(in: 3...5, using: &rng)
        let start = CGPoint(x: foot.x + d.dx * dist, y: foot.y + d.dy * dist)
        return GullPath(start: start, end: foot, h0: h0, h1: 0, seconds: Double(dist / (gull.pixelsPerSecond * 0.75)), delay: delay,
                        species: species, landing: true)
    }

    /// the gulls standing at the strike spot burst into the air at once, all different ways: their headings fanned
    /// round the whole circle (an even share each, jittered ±25°), each its own climb (2.5–7 m) and speed (0.8–1.3 times
    /// its species' pace), out to off the picture.
    static func gullBurst<R: RandomNumberGenerator>(from feet: [CGPoint], species: [Int], delays: [Double], spec: ZoneOutdoorSpec,
                                                    using rng: inout R) -> [GullPath] {
        let n = feet.count
        guard n > 0 else { return [] }
        let base = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
        var out: [GullPath] = []
        for i in 0..<n {
            let gull = spec.gulls[max(0, min(spec.gulls.count - 1, species[i]))]
            let a = base + CGFloat(i) * 2 * .pi / CGFloat(n) + CGFloat.random(in: -25...25, using: &rng) * .pi / 180
            let d = CGVector(dx: cos(a), dy: sin(a))
            let h1 = CGFloat.random(in: 2.5...7, using: &rng)
            let pace = gull.pixelsPerSecond * CGFloat.random(in: 0.8...1.3, using: &rng)
            let picture = CGRect(origin: .zero, size: spec.picture).insetBy(dx: -gull.reach, dy: -gull.reach - h1 * gull.shadowPerMetre)
            var dist: CGFloat = 200
            while picture.contains(CGPoint(x: feet[i].x + d.dx * dist, y: feet[i].y + d.dy * dist)) && dist < 6000 { dist += 40 }
            out.append(GullPath(start: feet[i], end: CGPoint(x: feet[i].x + d.dx * (dist + 120), y: feet[i].y + d.dy * (dist + 120)), h0: 0, h1: h1,
                                seconds: Double((dist + 120) / pace), delay: i < delays.count ? delays[i] : 0, species: species[i], landing: false))
        }
        return out
    }

    /// The gull's turn to its heading (it is drawn heading picture-right); heading left it is flipped top to bottom as well,
    /// so it is not upside down.
    static func gullTransform(_ heading: CGVector) -> CATransform3D {
        let turn = CATransform3DMakeRotation(atan2(heading.dy, heading.dx), 0, 0, 1)
        return heading.dx < 0 ? CATransform3DConcat(CATransform3DMakeScale(1, -1, 1), turn) : turn
    }
}

/// the outdoor art, read once per art folder.
@MainActor enum ZoneOutdoorArt {
    private static var loadedFor: String?
    private static var cached: ZoneOutdoorSpec?
    private static var crabs: [String: [CGImage]] = [:]
    private static var gulls: [String: [CGImage]] = [:]
    private static var stands: [String: [CGImage]] = [:]
    private static var frames: [Int: CGImage] = [:]
    private static var shade: CGImage?
    private static var orcaCached: ZoneOrcaSpec?
    private static var orcaFrames: [String: CGImage] = [:]

    private static func fresh() {
        guard loadedFor != ZoneArt.folder else { return }
        loadedFor = ZoneArt.folder
        cached = nil
        orcaCached = ZoneArt.folder.flatMap { FileManager.default.contents(atPath: $0 + "/orca.json") }.flatMap(ZoneOrcaSpec.parse)
        orcaFrames = [:]
        crabs = [:]
        gulls = [:]
        stands = [:]
        frames = [:]
        guard let folder = ZoneArt.folder, let data = FileManager.default.contents(atPath: folder + "/outdoor.json") else { return }
        var perMetre: CGFloat = 0
        if let points = FileManager.default.contents(atPath: folder + "/points.json"),
            let o = (try? JSONSerialization.jsonObject(with: points)) as? [String: Any], let scale = o["pixel_scale"] as? [String: Any],
            let m = scale["pixels_per_meter"] as? NSNumber
        {
            perMetre = CGFloat(m.doubleValue)
        }
        cached = ZoneOutdoorSpec.parse(data, pixelsPerMetre: perMetre > 0 ? perMetre : 105)
    }

    static var spec: ZoneOutdoorSpec? {
        fresh()
        return cached
    }

    static var movie: URL? {
        guard let folder = ZoneArt.folder, FileManager.default.fileExists(atPath: folder + "/outdoor_loop.mov") else { return nil }
        return URL(fileURLWithPath: folder + "/outdoor_loop.mov")
    }

    /// `orca.json` (nil when the clips are not there: no orca, nothing else changes).
    static var orca: ZoneOrcaSpec? {
        fresh()
        return orcaCached
    }

    /// a clip's film, when it is there.
    static func orcaMovie(_ id: String) -> URL? {
        guard let folder = ZoneArt.folder, let clip = orca?.clip(id), FileManager.default.fileExists(atPath: folder + "/" + clip.file) else { return nil }
        return URL(fileURLWithPath: folder + "/" + clip.file)
    }

    /// frame `index` of a clip, with its alpha (for a check's still picture only: a still panel never shows a clip).
    static func orcaFrame(_ id: String, _ index: Int) -> CGImage? {
        guard let clip = orca?.clip(id), let movie = orcaMovie(id) else { return nil }
        let key = "\(id) \(index)"
        if let known = orcaFrames[key] { return known }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: CMTime(value: CMTimeValue(max(0, min(clip.frames - 1, index))), timescale: CMTimeScale(clip.fps.rounded()))) { image, _, _ in
            box.image = image
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        orcaFrames[key] = box.image
        return box.image
    }

    /// A crab species' leg cycle (`sprites/crab_<kind>_01…`), frame 1 first (its still frame); empty when the sprites are
    /// not there.
    static func crabFrames(_ species: Int) -> [CGImage] {
        fresh()
        guard let spec, let crab = spec.dweller(species) else { return [] }
        if let known = crabs[crab.kind] { return known }
        let loaded = (1...max(1, crab.frames)).compactMap { ZoneArt.picture(crab.stem + String(format: "%02d", $0)) }
        crabs[crab.kind] = loaded
        return loaded
    }

    /// a gull species' standing pair (`sprites/gullstand_<kind>_01…`), empty when not there.
    static func standFrames(_ kind: String) -> [CGImage] {
        fresh()
        guard let spec, let stand = spec.stand(kind) else { return [] }
        if let known = stands[kind] { return known }
        let loaded = (1...max(1, stand.frames)).compactMap { ZoneArt.picture(stand.stem + String(format: "%02d", $0)) }
        stands[kind] = loaded
        return loaded
    }

    /// A gull species' wing beat (`sprites/gull_<kind>_01…`).
    static func gullFrames(_ species: Int) -> [CGImage] {
        fresh()
        guard let spec, spec.gulls.indices.contains(species) else { return [] }
        let gull = spec.gulls[species]
        if let known = gulls[gull.kind] { return known }
        let loaded = (1...max(1, gull.frames)).compactMap { ZoneArt.picture(gull.stem + String(format: "%02d", $0)) }
        gulls[gull.kind] = loaded
        return loaded
    }

    /// The loop's frame at `seconds` (wrapped to the loop), with its alpha; for a still picture and Reduce Motion.
    static func frame(at seconds: Double) -> CGImage? {
        guard let spec, let movie else { return nil }
        let count = max(1, spec.loopFrames)
        let index = ((Int((seconds * spec.fps).rounded(.down)) % count) + count) % count
        if let known = frames[index] { return known }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        final class Box: @unchecked Sendable { var image: CGImage? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        generator.generateCGImageAsynchronously(for: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(spec.fps.rounded()))) { image, _, _ in
            box.image = image
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        frames[index] = box.image
        return box.image
    }

    #if TESTING
    /// For the README's moving pictures only: lets go of the decoded loop and clip frames (each frame of a run is
    /// decoded once and then not needed again; kept, a run would hold hundreds of MB).
    static func demoForget() {
        frames = [:]
        orcaFrames = [:]
    }
    #endif

    /// A soft dark ellipse (stretched by its layer) for a gull's shadow.
    static var shadow: CGImage? {
        if let shade { return shade }
        let side = 96
        guard let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [OfficeCanvas.rgb(0x101418, 1), OfficeCanvas.rgb(0x101418, 0.55), OfficeCanvas.rgb(0x101418, 0)] as CFArray,
                                      locations: [0, 0.5, 1])
        else { return nil }
        let middle = CGPoint(x: side / 2, y: side / 2)
        c.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: CGFloat(side) / 2, options: [])
        shade = c.makeImage()
        return shade
    }
}

/// the living outdoors. `sea` goes over the base picture (under the screens, the LEDs and the figures), `beach` (the
/// crabs) over the sea, `gulls` over everything; none of them takes a click (the room's hit test reads its figures and signs
/// only). Live, the loop plays muted for ever while `setRunning(true)`: the crabs walk and rest, now and then one leaves and
/// another comes, and every 20–60 s one or two gulls fly over. A still picture or Reduce Motion shows one frame of the loop,
/// the crabs standing and no gull. at most one crab of each species at once (so 1–3, never two alike); a still picture
/// has one of each; each gull flight is one species.
@MainActor final class ZoneOutdoor {
    final class Crab {
        let layer = CALayer()
        /// its species, an index into `outdoor.json` `crabs`.
        let species: Int
        /// Its foot in the picture: where it stands, or where it is walking to.
        var at: CGPoint
        var facing: CGFloat = 1
        var walking = false
        var leaving = false
        /// running from (or waiting out) an orca on the sand; `home` is where it was, it walks back there after.
        var fleeing = false
        var home: CGPoint?
        /// where its escape ends (its last leg's end).
        var refuge: CGPoint?
        /// What it does next (the end of its walk, or of its rest).
        var next: DispatchWorkItem?
        /// A still picture's walk for it (`pose`).
        var stillWalk: ZoneCrabWalk?
        init(species: Int, at: CGPoint) {
            self.species = species
            self.at = at
        }
    }

    let sea = CALayer()
    let beach = CALayer()
    /// the orca clips, over the sea and the crabs, under the gulls.
    let orca = CALayer()
    let gulls = CALayer()
    private let poster = CALayer()
    private(set) var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private(set) var playerLayer: AVPlayerLayer?
    private(set) var crabs: [Crab] = []
    /// the other beach dwellers (sandpiper, turtle, clam), the same kind of `Crab` (species ≥ `spec.crabs.count`).
    private(set) var walkers: [Crab] = []
    /// the gulls of a strike (landed at the spot, or bursting away): sprite, shadow, foot, species, standing.
    final class StrikeGull {
        let gull = CALayer(), shadow = CALayer()
        var foot: CGPoint
        let species: Int
        var standing = false
        var path: ZoneOutdoorGeometry.GullPath?
        init(foot: CGPoint, species: Int) {
            self.foot = foot
            self.species = species
        }
    }
    private(set) var strikeGulls: [StrikeGull] = []
    /// The gulls in the air (sprite, shadow).
    private(set) var flying: [(gull: CALayer, shadow: CALayer, flight: ZoneGullFlight)] = []
    private(set) var running = false
    private(set) var live = false
    private var fit = ZoneFit(scene: .zero, view: .zero)
    var rng: ZoneRandom
    /// What is waiting to happen, by a token (the item does not hold itself, so none is kept once run or cancelled).
    private var pending: [UUID: DispatchWorkItem] = [:]
    /// A still picture's seed: the same crabs on every picture.
    static let stillSeed: UInt64 = 11
    /// the clip on its way or showing (one player at a most, made for it and dropped after it), its layer, and when
    /// (host time) it starts: the loop's next frame 0.
    private(set) var orcaPlayer: AVPlayer?
    private(set) var orcaLayer: AVPlayerLayer?
    private(set) var orcaClip: String?
    private(set) var orcaStart: CMTime?
    /// the last clip shown (the next is another), and how long the countdown to the next one is.
    private(set) var lastOrca: String?
    private(set) var orcaCountdown: Double?
    private var orcaWait: DispatchWorkItem?
    /// while a landing clip (C) is on, its box (no crab walks into it) and the crabs faded out for it.
    private(set) var orcaKeepOut: [CGRect]?
    #if TESTING
    /// the README's moving pictures only: a run worked out ahead (`demoStrike`), posed by `demoPose(at:)`.
    var demoScript: DemoScript?
    #endif

    init(seed: UInt64 = UInt64.random(in: 0...UInt64.max)) {
        rng = ZoneRandom(seed: seed)
        sea.name = "sea"
        beach.name = "beach"
        gulls.name = "gulls"
        orca.name = "orca"
        poster.contentsGravity = .resize
        sea.addSublayer(poster)
    }

    var spec: ZoneOutdoorSpec? { ZoneOutdoorArt.spec }
    var playing: Bool { (player?.rate ?? 0) > 0 }

    /// Lays the outdoors out for this fit; `live` plays the loop (when running), else one frame of it shows.
    func configure(live: Bool, fit: ZoneFit, bounds: CGRect, seeded: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let wasRunning = running
        if wasRunning { setRunning(false) }
        self.fit = fit
        self.live = live
        beach.frame = bounds
        orca.frame = bounds
        gulls.frame = bounds
        dropOrca()
        guard let spec else {
            sea.frame = .zero
            return
        }
        sea.frame = fit.rect(spec.loopBox)
        poster.frame = sea.bounds
        playerLayer?.frame = sea.bounds
        if live {
            poster.contents = nil
            poster.isHidden = true
        } else {
            dropPlayer()
            poster.isHidden = false
            poster.contents = ZoneOutdoorArt.frame(at: 0)
        }
        if crabs.isEmpty {
            if seeded { rng = ZoneRandom(seed: Self.stillSeed) }
            // A still picture shows one of each species; live, 2–3 of them (turnover keeps the count, never two alike).
            let count = seeded ? spec.crabs.count : Int.random(in: 2...3, using: &rng)
            for _ in 0..<count { if let c = newCrab() { crabs.append(c) } }
        }
        if walkers.isEmpty {
            // one of each other dweller; live, the turtle only now and then (6 in 10).
            for i in spec.walkers.indices {
                if !seeded && spec.walkers[i].behavior == .crawlRest && Double.random(in: 0..<1, using: &rng) > 0.6 { continue }
                if let w = newDweller(spec.crabs.count + i) { walkers.append(w) }
            }
        }
        for c in crabs + walkers { place(c) }
        for g in flying {
            g.gull.removeFromSuperlayer()
            g.shadow.removeFromSuperlayer()
        }
        flying = []
        if wasRunning && live { setRunning(true) }
    }

    /// Plays or holds the outdoors: the loop, the crabs' walks and the gulls. Holding drops what is waiting and puts every
    /// crab where it was going (nobody sees it then).
    func setRunning(_ on: Bool) {
        let on = on && live && spec != nil
        guard on != running else { return }
        running = on
        if on {
            makePlayer()
            player?.play()
            for c in crabs + walkers { rest(c) }
            scheduleGulls()
            scheduleTurnover()
            scheduleOrca()
        } else {
            player?.pause()
            for item in pending.values { item.cancel() }
            pending = [:]
            dropOrca()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            crabs.removeAll { c in
                c.next = nil
                c.walking = false
                c.layer.removeAllAnimations()
                if c.leaving { c.layer.removeFromSuperlayer() }
                return c.leaving
            }
            while crabs.count < 1, let c = newCrab() { crabs.append(c) }
            for c in walkers {
                c.next = nil
                c.walking = false
                c.layer.removeAllAnimations()
            }
            for c in crabs + walkers {
                c.fleeing = false
                c.home = nil
                c.layer.opacity = 1
                place(c)
            }
            for g in flying {
                g.gull.removeFromSuperlayer()
                g.shadow.removeFromSuperlayer()
            }
            flying = []
            CATransaction.commit()
        }
    }

    // ───────── The loop ─────────

    private func makePlayer() {
        guard player == nil, let movie = ZoneOutdoorArt.movie else { return }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false
        queue.allowsExternalPlayback = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(asset: AVURLAsset(url: movie)))
        let shown = AVPlayerLayer(player: queue)
        shown.videoGravity = .resize
        shown.frame = sea.bounds
        shown.name = "loop"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sea.addSublayer(shown)
        CATransaction.commit()
        player = queue
        playerLayer = shown
    }

    private func dropPlayer() {
        player?.pause()
        looper?.disableLooping()
        looper = nil
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
    }

    // ───────── Crabs ─────────

    /// A new crab of a species not on the beach now (none when every species is out), somewhere on its beach.
    private func newCrab() -> Crab? {
        guard let spec else { return nil }
        let out = Set(crabs.map(\.species))
        let free = spec.crabs.indices.filter { !out.contains($0) }
        guard let species = free.randomElement(using: &rng) else { return nil }
        return newDweller(species)
    }

    /// a beach dweller of `species` (an index into `spec.dwellers`) somewhere on its beach, its layer in `beach`.
    private func newDweller(_ species: Int) -> Crab? {
        guard let spec, let kind = spec.dweller(species), let spot = ZoneOutdoorGeometry.randomPoint(in: kind.beach, using: &rng) else { return nil }
        let c = Crab(species: species, at: spot)
        c.facing = Bool.random(using: &rng) ? 1 : -1
        c.layer.name = (species < spec.crabs.count ? "crab-" : "walker-") + kind.kind
        c.layer.contentsGravity = .resize
        beach.addSublayer(c.layer)
        place(c)
        return c
    }

    private func place(_ c: Crab) {
        guard let spec, let crab = spec.dweller(c.species) else { return }
        c.layer.bounds = CGRect(x: 0, y: 0, width: crab.size.width * fit.scale, height: crab.size.height * fit.scale)
        c.layer.anchorPoint = CGPoint(x: crab.foot.x / crab.size.width, y: crab.foot.y / crab.size.height)
        c.layer.position = fit.point(c.at)
        c.layer.transform = CATransform3DMakeScale(crab.flip(c.facing), 1, 1)
        c.layer.contents = ZoneOutdoorArt.crabFrames(c.species).first
    }

    /// a crab's species spec.
    func species(of c: Crab) -> ZoneCrabSpec? { spec?.dweller(c.species) }

    /// Runs `body` in `seconds`, unless the outdoors is held first.
    @discardableResult private func after(_ seconds: Double, _ body: @escaping () -> Void) -> DispatchWorkItem {
        let token = UUID()
        let item = DispatchWorkItem { [weak self] in
            self?.pending[token] = nil
            body()
        }
        pending[token] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    /// Rests, then takes its next walk. by its kind: a crab rests 2–8 s, the sandpiper 1.5–4 s pecking (its idle
    /// frames), the turtle 20–40 s with its head drawn in (idle frames, then breathing); the clam never moves.
    private func rest(_ c: Crab) {
        guard running, !c.leaving, !c.fleeing, let kind = species(of: c), kind.behavior != .stationary else { return }
        let pause: Double
        switch kind.behavior {
        case .shoreRun: pause = Double.random(in: 1.5...4, using: &rng)
        case .crawlRest: pause = Double.random(in: 20...40, using: &rng)
        default: pause = Double.random(in: 2...8, using: &rng)
        }
        idle(c, kind, for: pause)
        c.next = after(pause) { [weak self, weak c] in
            guard let self, let c, let crab = self.species(of: c) else { return }
            let step = ZoneOutdoorGeometry.crabStep(from: c.at, crab: crab, using: &self.rng)
            // no walking into where a landing orca is.
            if let keep = self.orcaKeepOut, keep.contains(where: { self.crabFrame(c, at: step.to).intersects($0) }) {
                self.rest(c)
                return
            }
            self.go(c, step) { [weak self, weak c] in
                if let self, let c { self.rest(c) }
            }
        }
    }

    /// its idle frames while it rests: the sandpiper pecks now and then; the turtle draws its head in, then breathes.
    private func idle(_ c: Crab, _ kind: ZoneCrabSpec, for seconds: Double) {
        guard let range = kind.idleFrames else { return }
        let frames = ZoneOutdoorArt.crabFrames(c.species)
        guard frames.count >= range.upperBound, let first = frames.first else { return }
        let own = range.map { frames[$0 - 1] }
        var values: [CGImage] = []
        switch kind.behavior {
        case .crawlRest:
            values = Array(own.prefix(2))
            let tail = own.count > 2 ? Array(own.suffix(2)) : own
            while Double(values.count) / kind.fps < seconds { values += tail }
        default:
            while Double(values.count) / kind.fps < seconds {
                values += [first, first, first] + own + [first]
            }
        }
        let anim = CAKeyframeAnimation(keyPath: "contents")
        anim.values = values
        anim.calculationMode = .discrete
        anim.duration = Double(values.count) / kind.fps
        anim.isRemovedOnCompletion = true
        c.layer.add(anim, forKey: "idle")
    }

    /// Walks a crab: its frame flipped for the way it goes, moved along the beach, its legs going at its own frame rate
    /// (through its walk frames; `rate` faster when it runs for it); stopped, it shows frame 1.
    private func go(_ c: Crab, _ walk: ZoneCrabWalk, rate: Double = 1, then: @escaping () -> Void) {
        guard running, let crab = species(of: c) else { return }
        let all = ZoneOutdoorArt.crabFrames(c.species)
        let frames = crab.walkFrames.map { r in r.compactMap { all.indices.contains($0 - 1) ? all[$0 - 1] : nil } } ?? all
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.layer.removeAnimation(forKey: "idle")
        c.facing = walk.facing
        c.layer.transform = CATransform3DMakeScale(crab.flip(c.facing), 1, 1)
        c.at = walk.to
        c.layer.position = fit.point(walk.to)
        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: fit.point(walk.from))
        move.toValue = NSValue(point: fit.point(walk.to))
        move.duration = walk.seconds
        c.layer.add(move, forKey: "walk")
        if frames.count > 1 {
            let legs = CAKeyframeAnimation(keyPath: "contents")
            legs.values = frames
            legs.calculationMode = .discrete
            legs.duration = Double(frames.count) / (crab.fps * rate)
            legs.repeatCount = Float(walk.seconds / legs.duration)
            c.layer.add(legs, forKey: "legs")
        }
        CATransaction.commit()
        c.walking = true
        c.next = after(walk.seconds) { [weak c] in
            c?.walking = false
            then()
        }
    }

    /// Every 1–3 min one resting crab walks off the end of the beach and fades, and a new one fades in elsewhere.
    private func scheduleTurnover() {
        after(Double.random(in: 60...180, using: &rng)) { [weak self] in
            guard let self else { return }
            self.turnover()
            self.scheduleTurnover()
        }
    }

    func turnover() {
        guard running, orcaClip == nil, let c = crabs.filter({ !$0.walking && !$0.leaving && !$0.fleeing }).randomElement(using: &rng), let crab = species(of: c) else { return }
        c.next?.cancel()
        c.leaving = true
        go(c, ZoneOutdoorGeometry.crabExit(from: c.at, crab: crab)) { [weak self, weak c] in
            guard let self, let c else { return }
            Self.fade(c.layer, to: 0)
            c.next = self.after(0.5) { [weak self, weak c] in
                guard let self, let c, let fresh = self.replace(c) else { return }
                fresh.layer.opacity = 0
                Self.fade(fresh.layer, to: 1)
                self.rest(fresh)
            }
        }
    }

    /// Takes a crab off the beach and brings a new one (of a species not out now, so never two alike); the new one, if any.
    @discardableResult func replace(_ c: Crab) -> Crab? {
        c.layer.removeFromSuperlayer()
        crabs.removeAll { $0 === c }
        guard let fresh = newCrab() else { return nil }
        crabs.append(fresh)
        return fresh
    }

    private static func fade(_ layer: CALayer, to value: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = layer.opacity
        fade.toValue = value
        fade.duration = 0.5
        layer.opacity = value
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // ───────── Gulls ─────────

    private func scheduleGulls() {
        after(Double.random(in: 20...60, using: &rng)) { [weak self] in
            guard let self else { return }
            if self.strikeGulls.isEmpty && self.orcaKeepOut == nil { self.flyNow() }   // none over a strike
            self.scheduleGulls()
        }
    }

    /// One or two gulls set off now (for the schedule, and for a check).
    @discardableResult func flyNow() -> [ZoneGullFlight] {
        guard running, let spec else { return [] }
        let flights = ZoneOutdoorGeometry.gullFlights(spec: spec, using: &rng)
        guard flights.allSatisfy({ !ZoneOutdoorArt.gullFrames($0.species).isEmpty }) else { return [] }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for f in flights {
            let (gull, shadow) = gullLayers(f)
            let now = gulls.convertTime(CACurrentMediaTime(), from: nil)
            for (layer, drop) in [(shadow, f.shadowDrop), (gull, CGFloat(0))] {
                let move = CABasicAnimation(keyPath: "position")
                move.fromValue = NSValue(point: fit.point(CGPoint(x: f.from.x, y: f.from.y + drop)))
                move.toValue = NSValue(point: fit.point(CGPoint(x: f.to.x, y: f.to.y + drop)))
                move.duration = f.seconds
                move.beginTime = now + f.delay
                move.fillMode = .backwards
                layer.position = fit.point(CGPoint(x: f.to.x, y: f.to.y + drop))
                layer.add(move, forKey: "fly")
            }
            let frames = ZoneOutdoorArt.gullFrames(f.species)
            let flap = CAKeyframeAnimation(keyPath: "contents")
            flap.values = frames
            flap.calculationMode = .discrete
            flap.duration = Double(frames.count) / spec.fps
            flap.timeOffset = Double.random(in: 0..<flap.duration, using: &rng)
            flap.repeatCount = .infinity
            gull.add(flap, forKey: "flap")
            flying.append((gull, shadow, f))
            after(f.delay + f.seconds + 0.2) { [weak self, weak gull, weak shadow] in
                gull?.removeFromSuperlayer()
                shadow?.removeFromSuperlayer()
                self?.flying.removeAll { $0.gull === gull }
            }
        }
        CATransaction.commit()
        return flights
    }

    /// A gull's sprite (turned to its heading) and its shadow, at the flight's start, in the gulls' layer.
    private func gullLayers(_ f: ZoneGullFlight) -> (CALayer, CALayer) {
        let spec = spec!.gulls[max(0, min(spec!.gulls.count - 1, f.species))]
        let shadow = CALayer()
        shadow.name = "gull-shadow"
        shadow.contents = ZoneOutdoorArt.shadow
        shadow.contentsGravity = .resize
        shadow.bounds = CGRect(x: 0, y: 0, width: spec.shadowSize.width * fit.scale, height: spec.shadowSize.height * fit.scale)
        shadow.opacity = 0.18
        shadow.position = fit.point(CGPoint(x: f.from.x, y: f.from.y + f.shadowDrop))
        let gull = CALayer()
        gull.name = "gull"
        gull.contentsGravity = .resize
        gull.contents = ZoneOutdoorArt.gullFrames(f.species).first
        gull.bounds = CGRect(x: 0, y: 0, width: spec.size.width * fit.scale, height: spec.size.height * fit.scale)
        gull.anchorPoint = CGPoint(x: spec.centre.x / spec.size.width, y: spec.centre.y / spec.size.height)
        gull.transform = ZoneOutdoorGeometry.gullTransform(f.heading)
        gull.position = fit.point(f.from)
        // Shadows under every gull: all shadows first, then the birds.
        gulls.insertSublayer(shadow, at: 0)
        gulls.addSublayer(gull)
        return (gull, shadow)
    }

    // ───────── The orca ─────────

    /// The next clip in 3–8 min (a new countdown each time the outdoors plays again, and after each clip).
    private func scheduleOrca() {
        orcaWait?.cancel()
        orcaWait = nil
        orcaCountdown = nil
        guard running, ZoneOutdoorArt.orca != nil else { return }
        let wait = ZoneOrcaSpec.interval(using: &rng)
        orcaCountdown = wait
        orcaWait = after(wait) { [weak self] in
            guard let self, let o = ZoneOutdoorArt.orca, let id = ZoneOrcaSpec.pick(after: self.lastOrca, ids: o.ids, using: &self.rng) else { return }
            if !self.playOrca(id) { self.scheduleOrca() }
        }
    }

    /// Plays clip `id` from the loop's next frame 0 (the schedule, the debug notification, a check). Only while the
    /// outdoors plays and no clip is on; false when it does not. Its player and layer are made now, the layer hidden until
    /// the clip starts.
    @discardableResult func playOrca(_ id: String) -> Bool {
        // Settings > sea room > orca clip off: no clip (the countdown keeps going, so switching it on again needs nothing).
        guard running, live, orcaClip == nil, zoneOrcaOn(), let clip = ZoneOutdoorArt.orca?.clip(id), let movie = ZoneOutdoorArt.orcaMovie(id) else { return false }
        orcaWait?.cancel()
        orcaWait = nil
        orcaCountdown = nil
        let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: movie)))
        p.isMuted = true
        p.preventsDisplaySleepDuringVideoPlayback = false
        p.allowsExternalPlayback = false
        // A start at a host time (the loop's frame 0) needs this off.
        p.automaticallyWaitsToMinimizeStalling = false
        let shown = AVPlayerLayer(player: p)
        shown.name = "orca-clip"
        shown.videoGravity = .resize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shown.frame = fit.rect(clip.box)
        shown.isHidden = true
        orca.addSublayer(shown)
        CATransaction.commit()
        orcaPlayer = p
        orcaLayer = shown
        orcaClip = clip.id
        lastOrca = clip.id
        armOrca(clip, tries: 0)
        return true
    }

    /// Once the clip's player is ready (and the loop's clock known), starts it at the loop's next frame 0 by the loop's own
    /// timebase, shows it then, and drops it when it ends.
    private func armOrca(_ clip: ZoneOrcaClip, tries: Int) {
        guard running, let p = orcaPlayer, orcaClip == clip.id, let o = ZoneOutdoorArt.orca else { return }
        guard p.status == .readyToPlay, let loop = player, loop.rate > 0, let tb = loop.currentItem?.timebase else {
            if p.status == .failed || tries > 80 {
                dropOrca()
                scheduleOrca()
                return
            }
            after(0.05) { [weak self] in self?.armOrca(clip, tries: tries + 1) }
            return
        }
        let host = CMClockGetHostTimeClock()
        let loopNow = CMTimebaseGetTime(tb).seconds
        let aside = ZoneOrcaSpec.stepAside(clip)
        let strike = aside.isEmpty ? nil : (clip.strike ?? Self.fallbackStrike(clip))
        // At least 0.6 s ahead; a strike needs 5 s (gulls glide in and settle, the beach animals run 1.2 s before).
        let wait = ZoneOrcaSpec.untilLoopFrame(clip.startLoopFrame, at: loopNow, loopSeconds: o.loopSeconds, fps: o.loopFPS,
                                               lead: strike == nil ? 0.6 : Self.strikeLead)
        let start = CMSyncConvertTime(CMTime(seconds: loopNow + wait, preferredTimescale: 1_000_000), from: tb, to: host)
        p.setRate(1, time: .zero, atHostTime: start)
        orcaStart = start
        let lead = max(0, CMTimeGetSeconds(CMTimeSubtract(start, CMClockGetTime(host))))
        if let strike {
            orcaKeepOut = aside
            after(max(0, lead - 4.6)) { [weak self] in
                guard let self, self.orcaClip == clip.id else { return }
                self.landGulls(strike)
            }
            after(max(0, lead - Self.scatterLead)) { [weak self] in
                guard let self, self.orcaClip == clip.id else { return }
                self.scatter(from: aside, strike: strike)
            }
            for (i, f) in strike.takeoffFrames.enumerated() {
                after(lead + Double(max(1, f) - 1) / max(1, clip.fps)) { [weak self] in
                    guard let self, self.orcaClip == clip.id else { return }
                    self.burst(i, delays: strike.takeoffFrames.map { _ in 0 })
                }
            }
        }
        after(lead) { [weak self] in
            guard let self, self.orcaClip == clip.id else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.orcaLayer?.isHidden = false
            CATransaction.commit()
        }
        after(lead + clip.seconds + 0.3) { [weak self] in
            guard let self, self.orcaClip == clip.id else { return }
            self.dropOrca(restoringCrabs: false)
            self.scheduleOrca()
            // the ones that ran wait a while, then wander back, each in its own time.
            self.orcaKeepOut = nil
            self.comeBack()
        }
    }

    /// how long before a strike's start the clip is armed, and before it the beach animals run.
    static let strikeLead = 5.0, scatterLead = 1.2

    /// a landing clip without `strike` in orca.json: its way in from its box's top-right corner to the box's middle.
    static func fallbackStrike(_ clip: ZoneOrcaClip) -> ZoneOrcaStrike {
        ZoneOrcaStrike(gullSpots: [], takeoffFrames: [], from: CGPoint(x: clip.box.maxX, y: clip.box.minY), to: CGPoint(x: clip.box.midX, y: clip.box.midY))
    }

    /// A crab's frame in the picture, standing at `p`.
    func crabFrame(_ c: Crab, at p: CGPoint) -> CGRect {
        guard let crab = species(of: c) else { return .null }
        return CGRect(x: p.x - crab.foot.x, y: p.y - crab.foot.y, width: crab.size.width, height: crab.size.height)
    }

    /// every beach animal whose frame (where it is shown now, or where it is going) meets `zone` or comes near it runs
    /// off its own way (`ZoneOutdoorGeometry.scatter`), fast, and waits there; none fades. The turtle lives outside the
    /// strike and the clam stays put (the clip may cover it).
    private func scatter(from zone: [CGRect], strike: ZoneOrcaStrike) {
        for c in crabs + walkers where !c.leaving && !c.fleeing {
            guard let kind = species(of: c), kind.threat == .scatter else { continue }
            let shown = fit.back(c.layer.presentation()?.position ?? c.layer.position)
            if spec?.onDeck(shown) == true { continue }   // on the deck behind the railing: safe, it stays
            let now = crabFrame(c, at: shown), going = crabFrame(c, at: c.at)
            guard zone.contains(where: { now.insetBy(dx: -30, dy: -30).intersects($0) || going.intersects($0) }) else { continue }
            c.next?.cancel()
            c.next = nil
            c.walking = false
            c.fleeing = true
            c.home = shown
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in ["walk", "legs", "idle", "fade"] { c.layer.removeAnimation(forKey: key) }
            c.layer.opacity = 1
            c.at = shown
            place(c)
            CATransaction.commit()
            let legs = ZoneOutdoorGeometry.scatter(from: shown, crab: kind, strike: strike, keepOut: zone,
                                                   frame: { [weak self, weak c] p in (self != nil && c != nil) ? self!.crabFrame(c!, at: p) : .null }, using: &rng)
            c.refuge = legs.last?.walk.to
            run(c, legs[...])
        }
    }

    private func run(_ c: Crab, _ legs: ArraySlice<(walk: ZoneCrabWalk, pause: Double)>) {
        guard let leg = legs.first else { return }
        let go = { [weak self, weak c] in
            guard let self, let c, c.fleeing else { return }
            self.go(c, leg.walk, rate: 1.6) { [weak self, weak c] in
                if let self, let c { self.run(c, legs.dropFirst()) }
            }
        }
        if leg.pause > 0 { c.next = after(leg.pause, go) } else { go() }
    }

    /// after a strike, each one that ran waits 2–6 s more, then walks back to where it was at its own pace.
    private func comeBack() {
        for c in crabs + walkers where c.fleeing {
            c.next?.cancel()
            c.next = after(Double.random(in: 2...6, using: &rng)) { [weak self, weak c] in
                guard let self, let c, let kind = self.species(of: c) else { return }
                let from = c.at, to = c.home ?? c.at
                c.home = nil
                let metres = hypot(to.x - from.x, to.y - from.y) / max(1, hypot(kind.walk.dx, kind.walk.dy))
                let facing: CGFloat = (to.x - from.x) * kind.walk.dx + (to.y - from.y) * kind.walk.dy >= 0 ? 1 : -1
                c.fleeing = false
                guard metres > 0.05 else {
                    self.rest(c)
                    return
                }
                self.go(c, ZoneCrabWalk(from: from, to: to, seconds: Double(metres / max(kind.speed, 0.2)), facing: facing)) { [weak self, weak c] in
                    if let self, let c { self.rest(c) }
                }
            }
        }
    }

    // ───────── the gulls of a strike ─────────

    /// 2–3 gulls (each its own species) glide in and stand at the strike's spots.
    private func landGulls(_ strike: ZoneOrcaStrike) {
        guard let spec, !strike.gullSpots.isEmpty else { return }
        let n = min(strike.gullSpots.count, Int.random(in: 2...3, using: &rng))
        for i in 0..<n {
            let species = spec.gullSpecies(using: &rng)
            guard !ZoneOutdoorArt.gullFrames(species).isEmpty, !ZoneOutdoorArt.standFrames(spec.gulls[species].kind).isEmpty else { continue }
            let g = StrikeGull(foot: strike.gullSpots[i], species: species)
            let path = ZoneOutdoorGeometry.gullLanding(at: g.foot, spec: spec, species: species, delay: Double(i) * 0.35, using: &rng)
            g.path = path
            strikeGulls.append(g)
            fly(g, path)
            after(path.delay + path.seconds) { [weak self, weak g] in
                guard let self, let g else { return }
                self.stand(g)
            }
        }
    }

    /// A strike gull along its path: the flight sprite turned to its heading, the shadow on the ground under it.
    private func fly(_ g: StrikeGull, _ path: ZoneOutdoorGeometry.GullPath) {
        guard let spec else { return }
        let gs = spec.gulls[max(0, min(spec.gulls.count - 1, g.species))]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.gull.removeAllAnimations()
        g.shadow.removeAllAnimations()
        g.gull.name = "strike-gull"
        g.gull.contentsGravity = .resize
        g.gull.bounds = CGRect(x: 0, y: 0, width: gs.size.width * fit.scale, height: gs.size.height * fit.scale)
        g.gull.anchorPoint = CGPoint(x: gs.centre.x / gs.size.width, y: gs.centre.y / gs.size.height)
        g.gull.transform = ZoneOutdoorGeometry.gullTransform(path.heading)
        let frames = ZoneOutdoorArt.gullFrames(g.species)
        g.gull.contents = frames.first
        g.shadow.name = "strike-gull-shadow"
        g.shadow.contents = ZoneOutdoorArt.shadow
        g.shadow.contentsGravity = .resize
        g.shadow.bounds = CGRect(x: 0, y: 0, width: gs.shadowSize.width * fit.scale, height: gs.shadowSize.height * fit.scale)
        g.shadow.opacity = 0.18
        if g.gull.superlayer == nil {
            gulls.insertSublayer(g.shadow, at: 0)
            gulls.addSublayer(g.gull)
        }
        let now = gulls.convertTime(CACurrentMediaTime(), from: nil)
        var gp: [NSValue] = [], sp: [NSValue] = []
        for k in 0...16 {
            let (ground, h) = path.at(CGFloat(k) / 16)
            gp.append(NSValue(point: fit.point(CGPoint(x: ground.x, y: ground.y - h * gs.shadowPerMetre))))
            sp.append(NSValue(point: fit.point(ground)))
        }
        for (layer, values) in [(g.gull, gp), (g.shadow, sp)] {
            let move = CAKeyframeAnimation(keyPath: "position")
            move.values = values
            move.duration = path.seconds
            move.beginTime = now + path.delay
            move.fillMode = .backwards
            layer.position = values.last!.pointValue
            layer.add(move, forKey: "fly")
        }
        let flap = CAKeyframeAnimation(keyPath: "contents")
        flap.values = frames
        flap.calculationMode = .discrete
        flap.duration = Double(frames.count) / spec.fps
        flap.timeOffset = Double.random(in: 0..<flap.duration, using: &rng)
        flap.repeatCount = .infinity
        g.gull.add(flap, forKey: "flap")
        CATransaction.commit()
    }

    /// Down: the standing sprite at its foot (facing the way it came in), bobbing its head now and then.
    private func stand(_ g: StrikeGull) {
        guard let spec, g.path?.landing == true, strikeGulls.contains(where: { $0 === g }), let st = spec.stand(spec.gulls[g.species].kind) else { return }
        let frames = ZoneOutdoorArt.standFrames(st.kind)
        guard let first = frames.first else { return }
        let right = (g.path?.heading.dx ?? 1) >= 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        g.gull.removeAllAnimations()
        g.shadow.removeAllAnimations()
        g.shadow.opacity = 0     // the standing sprite has its own contact shadow
        g.gull.contents = first
        g.gull.bounds = CGRect(x: 0, y: 0, width: st.size.width * fit.scale, height: st.size.height * fit.scale)
        g.gull.anchorPoint = CGPoint(x: st.foot.x / st.size.width, y: st.foot.y / st.size.height)
        g.gull.transform = CATransform3DMakeScale(right ? 1 : -1, 1, 1)
        g.gull.position = fit.point(g.foot)
        if frames.count > 1 {
            let bob = CAKeyframeAnimation(keyPath: "contents")
            bob.values = [first, first, first, first, frames[1], frames[1], first, first]
            bob.calculationMode = .discrete
            bob.duration = Double.random(in: 1.6...2.4, using: &rng)
            bob.repeatCount = .infinity
            g.gull.add(bob, forKey: "bob")
        }
        CATransaction.commit()
        g.standing = true
    }

    /// The strike: gull `i` (if it is there) bursts up its own way; with the last one, every one still standing goes too.
    private func burst(_ i: Int, delays: [Double]) {
        guard let spec, strikeGulls.indices.contains(i) else { return }
        if burstPaths.isEmpty {
            burstPaths = ZoneOutdoorGeometry.gullBurst(from: strikeGulls.map(\.foot), species: strikeGulls.map(\.species),
                                                       delays: strikeGulls.map { _ in 0 }, spec: spec, using: &rng)
        }
        let g = strikeGulls[i]
        guard g.standing || g.path?.landing == true, burstPaths.indices.contains(i) else { return }
        let path = burstPaths[i]
        g.standing = false
        g.path = path
        g.shadow.opacity = 0.18
        fly(g, path)
        after(path.seconds + 0.2) { [weak self, weak g] in
            g?.gull.removeFromSuperlayer()
            g?.shadow.removeFromSuperlayer()
            self?.strikeGulls.removeAll { $0 === g }
            if self?.strikeGulls.isEmpty == true { self?.burstPaths = [] }
        }
    }
    private var burstPaths: [ZoneOutdoorGeometry.GullPath] = []

    private func dropStrikeGulls() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for g in strikeGulls {
            g.gull.removeFromSuperlayer()
            g.shadow.removeFromSuperlayer()
        }
        CATransaction.commit()
        strikeGulls = []
        burstPaths = []
    }

    /// Stops and lets go of the clip (its player, item and layer). The animals that ran stand where they got to and go on
    /// at once unless `restoringCrabs` is false (the clip's own end: they come back later, `comeBack`).
    private func dropOrca(restoringCrabs: Bool = true) {
        if restoringCrabs {
            orcaKeepOut = nil
            dropStrikeGulls()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for c in crabs + walkers where c.fleeing {
                c.fleeing = false
                c.home = nil
                c.next?.cancel()
                c.next = nil
                c.walking = false
                c.layer.removeAllAnimations()
                c.layer.opacity = 1
                place(c)
                if running { rest(c) }
            }
            CATransaction.commit()
        }
        orcaPlayer?.pause()
        orcaPlayer?.replaceCurrentItem(with: nil)
        orcaPlayer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orcaLayer?.removeFromSuperlayer()
        orca.sublayers = nil
        CATransaction.commit()
        orcaLayer = nil
        orcaClip = nil
        orcaStart = nil
    }

    #if TESTING
    /// For a check: a crab stood still at `p` (its walk and its next step cancelled), shown there.
    func standForCheck(_ c: Crab, at p: CGPoint) {
        c.next?.cancel()
        c.next = nil
        c.walking = false
        c.leaving = false
        c.fleeing = false
        c.home = nil
        c.layer.removeAllAnimations()
        c.at = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        c.layer.opacity = 1
        place(c)
        CATransaction.commit()
    }

    /// for a check's still picture: the strike's gulls standing at their spots (`burst` nil), or `burst` of the way
    /// along their burst paths (the flight sprite, its shadow on the ground under it).
    func poseStrikeForCheck(_ strike: ZoneOrcaStrike, burst: CGFloat?) {
        guard let spec else { return }
        dropStrikeGulls()
        var r = ZoneRandom(seed: 5)
        let species = strike.gullSpots.indices.map { [0, 1, 2][$0 % 3] % spec.gulls.count }
        let paths = ZoneOutdoorGeometry.gullBurst(from: strike.gullSpots, species: species, delays: species.map { _ in 0 }, spec: spec, using: &r)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, foot) in strike.gullSpots.enumerated() {
            let g = StrikeGull(foot: foot, species: species[i])
            strikeGulls.append(g)
            g.path = ZoneOutdoorGeometry.GullPath(start: CGPoint(x: foot.x - 300, y: foot.y - 200), end: foot, h0: 3, h1: 0, seconds: 1, delay: 0,
                                                  species: species[i], landing: true)
            fly(g, g.path!)
            g.gull.removeAllAnimations()
            g.shadow.removeAllAnimations()
            if let k = burst {
                fly(g, paths[i])
                g.gull.removeAllAnimations()
                g.shadow.removeAllAnimations()
                let gs = spec.gulls[species[i]], (ground, h) = paths[i].at(k)
                g.gull.position = fit.point(CGPoint(x: ground.x, y: ground.y - h * gs.shadowPerMetre))
                g.shadow.position = fit.point(ground)
                g.gull.contents = ZoneOutdoorArt.gullFrames(species[i]).dropFirst(6 + 9 * i).first
            } else {
                stand(g)
                g.gull.removeAllAnimations()
            }
        }
        CATransaction.commit()
    }

    /// For a check's still picture only (a still panel never shows a clip): frame `index` of clip `id` laid in its box.
    func poseOrcaForCheck(_ id: String, frame index: Int) {
        guard let clip = ZoneOutdoorArt.orca?.clip(id) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orca.sublayers = nil
        let l = CALayer()
        l.name = "orca-still"
        l.contentsGravity = .resize
        l.frame = fit.rect(clip.box)
        l.contents = ZoneOutdoorArt.orcaFrame(id, index)
        orca.addSublayer(l)
        CATransaction.commit()
    }

    // ───────── The README's moving pictures only (`--demo-gif-frames`) ─────────
    //
    // A still room cannot play the live outdoors (timers, Core Animation, AVPlayer), so a run of the live outdoors with a
    // clip is worked out ahead here, with the live functions, numbers and order (`rest`/`go` and their pauses, `armOrca`:
    // gulls in at 4.6 s before the clip, the animals running 1.2 s before, the clip from the loop's frame 0, the gulls'
    // take-off at its frames, `comeBack` 2-6 s after it), and then posed at any moment by `demoPose(at:)`.

    /// One stretch of an animal's run: standing (with its rest's idle frames from `t0` when `idle`, else frame 1), or
    /// walking `from` → `to` in `seconds` (its legs at `rate` times its frame rate).
    struct DemoSeg {
        var t0: Double, t1: Double
        var from: CGPoint, to: CGPoint
        var facing: CGFloat
        var walk = false
        var seconds = 0.0
        var rate = 1.0
        var idle = false
    }

    /// A strike gull: its landing, its standing bob, its burst away.
    final class DemoGull {
        let species: Int
        let foot: CGPoint
        let landing: ZoneOutdoorGeometry.GullPath
        let landAt: Double
        let bob: Double
        let flap: Double
        var burst: ZoneOutdoorGeometry.GullPath?
        var burstAt = Double.infinity
        var burstFlap = 0.0
        let gull = CALayer(), shadow = CALayer()
        init(species: Int, foot: CGPoint, landing: ZoneOutdoorGeometry.GullPath, landAt: Double, bob: Double, flap: Double) {
            self.species = species
            self.foot = foot
            self.landing = landing
            self.landAt = landAt
            self.bob = bob
            self.flap = flap
        }
        var standsAt: Double { landAt + landing.seconds }
    }

    final class DemoScript {
        var tracks: [ObjectIdentifier: [DemoSeg]] = [:]
        var gulls: [DemoGull] = []
        let clip: ZoneOrcaClip
        /// when the clip starts (the loop's frame `startLoopFrame` there), in the run's seconds.
        let orcaAt: Double
        /// what ran, for the log.
        var notes: [String] = []
        init(clip: ZoneOrcaClip, orcaAt: Double) {
            self.clip = clip
            self.orcaAt = orcaAt
        }
    }

    /// Works out a run with clip `id` starting at `orcaAt` (the run's seconds), the animals living from `start` on, up
    /// to `end`; `seed` picks the run's random draws (live they are random too).
    func demoStrike(_ id: String, orcaAt T: Double, from start: Double, to end: Double, seed: UInt64) -> DemoScript? {
        guard let spec, let clip = ZoneOutdoorArt.orca?.clip(id) else { return nil }
        var rng = ZoneRandom(seed: seed)
        let script = DemoScript(clip: clip, orcaAt: T)
        let aside = ZoneOrcaSpec.stepAside(clip)
        let strike = aside.isEmpty ? nil : (clip.strike ?? Self.fallbackStrike(clip))
        // armed `wait` before the clip: at least `strikeLead`, up to a loop more (`untilLoopFrame`); the keep-out from then.
        let lead = strike == nil ? 0.6 : Self.strikeLead
        let o = ZoneOutdoorArt.orca
        let armAt = T - (lead + Double.random(in: 0..<(o?.loopSeconds ?? 12), using: &rng))
        let dropAt = T + clip.seconds + 0.3
        func keptOut(_ t: Double) -> Bool { strike != nil && t >= armAt && t < dropAt }

        // Its rests and walks (`rest`, `go`) from `t` at `p` until `until`.
        func live(_ c: Crab, _ kind: ZoneCrabSpec, from t0: Double, at p0: CGPoint, facing f0: CGFloat, until: Double) -> [DemoSeg] {
            var out: [DemoSeg] = [], t = t0, p = p0, facing = f0
            while t < until {
                let pause: Double
                switch kind.behavior {
                case .shoreRun: pause = Double.random(in: 1.5...4, using: &rng)
                case .crawlRest: pause = Double.random(in: 20...40, using: &rng)
                default: pause = Double.random(in: 2...8, using: &rng)
                }
                out.append(DemoSeg(t0: t, t1: t + pause, from: p, to: p, facing: facing, idle: true))
                t += pause
                let step = ZoneOutdoorGeometry.crabStep(from: p, crab: kind, using: &rng)
                if keptOut(t), aside.contains(where: { crabFrame(c, at: step.to).intersects($0) }) { continue }
                out.append(DemoSeg(t0: t, t1: t + step.seconds, from: p, to: step.to, facing: step.facing, walk: true, seconds: step.seconds))
                t += step.seconds
                p = step.to
                facing = step.facing
            }
            return out
        }
        func shown(_ segs: [DemoSeg], at t: Double) -> (CGPoint, CGPoint, Int)? {
            guard let i = segs.lastIndex(where: { $0.t0 <= t }) else { return nil }
            let s = segs[i]
            let k = s.walk && s.seconds > 0 ? CGFloat(min(1, (t - s.t0) / s.seconds)) : 1
            return (CGPoint(x: s.from.x + (s.to.x - s.from.x) * k, y: s.from.y + (s.to.y - s.from.y) * k), s.to, i)
        }

        let scatterAt = T - Self.scatterLead
        for c in crabs + walkers {
            guard let kind = species(of: c) else { continue }
            guard kind.behavior != .stationary else {
                script.tracks[ObjectIdentifier(c)] = [DemoSeg(t0: start, t1: .infinity, from: c.at, to: c.at, facing: c.facing)]
                continue
            }
            var segs = live(c, kind, from: start, at: c.at, facing: c.facing, until: end)
            // `scatter`: those near where the orca comes run off their own way, fast, and wait.
            if let strike, kind.threat == .scatter, let (now, going, i) = shown(segs, at: scatterAt), spec.onDeck(now) == false {
                let nearNow = crabFrame(c, at: now), nearGoing = crabFrame(c, at: going)
                if aside.contains(where: { nearNow.insetBy(dx: -30, dy: -30).intersects($0) || nearGoing.intersects($0) }) {
                    segs = Array(segs.prefix(i + 1))
                    segs[i].t1 = scatterAt
                    let legs = ZoneOutdoorGeometry.scatter(from: now, crab: kind, strike: strike, keepOut: aside,
                                                           frame: { [weak self, weak c] p in (self != nil && c != nil) ? self!.crabFrame(c!, at: p) : .null }, using: &rng)
                    var t = scatterAt, p = now, facing = segs[i].facing
                    for leg in legs {
                        if leg.pause > 0 {
                            segs.append(DemoSeg(t0: t, t1: t + leg.pause, from: p, to: p, facing: facing))
                            t += leg.pause
                        }
                        segs.append(DemoSeg(t0: t, t1: t + leg.walk.seconds, from: leg.walk.from, to: leg.walk.to, facing: leg.walk.facing, walk: true,
                                            seconds: leg.walk.seconds, rate: 1.6))
                        t += leg.walk.seconds
                        p = leg.walk.to
                        facing = leg.walk.facing
                    }
                    // `comeBack`: 2-6 s after the clip is dropped, back to where it was, at its own pace; then its life again.
                    let back = max(t, dropAt + Double.random(in: 2...6, using: &rng))
                    segs.append(DemoSeg(t0: t, t1: back, from: p, to: p, facing: facing))
                    let metres = hypot(now.x - p.x, now.y - p.y) / max(1, hypot(kind.walk.dx, kind.walk.dy))
                    let way: CGFloat = (now.x - p.x) * kind.walk.dx + (now.y - p.y) * kind.walk.dy >= 0 ? 1 : -1
                    var after = back
                    if metres > 0.05 {
                        let seconds = Double(metres / max(kind.speed, 0.2))
                        segs.append(DemoSeg(t0: back, t1: back + seconds, from: p, to: now, facing: way, walk: true, seconds: seconds))
                        after += seconds
                        facing = way
                    }
                    segs += live(c, kind, from: after, at: now, facing: facing, until: end)
                    script.notes.append("\(kind.kind) runs \(Int(hypot(p.x - now.x, p.y - now.y))) px at \(String(format: "%.1f", scatterAt)) s, back home at \(String(format: "%.1f", after)) s")
                }
            }
            script.tracks[ObjectIdentifier(c)] = segs
        }

        // `landGulls`: 2-3 gulls glide in, 0.35 s apart, from 4.6 s before the clip; `burst` at the clip's take-off frames.
        if let strike, !strike.gullSpots.isEmpty {
            let n = min(strike.gullSpots.count, Int.random(in: 2...3, using: &rng))
            for i in 0..<n {
                let species = spec.gullSpecies(using: &rng)
                guard !ZoneOutdoorArt.gullFrames(species).isEmpty, !ZoneOutdoorArt.standFrames(spec.gulls[species].kind).isEmpty else { continue }
                let path = ZoneOutdoorGeometry.gullLanding(at: strike.gullSpots[i], spec: spec, species: species, delay: Double(i) * 0.35, using: &rng)
                let flapLength = Double(ZoneOutdoorArt.gullFrames(species).count) / spec.fps
                let g = DemoGull(species: species, foot: strike.gullSpots[i], landing: path, landAt: T - 4.6 + path.delay,
                                 bob: Double.random(in: 1.6...2.4, using: &rng), flap: Double.random(in: 0..<flapLength, using: &rng))
                script.gulls.append(g)
                gulls.insertSublayer(g.shadow, at: 0)
                gulls.addSublayer(g.gull)
            }
            let paths = ZoneOutdoorGeometry.gullBurst(from: script.gulls.map(\.foot), species: script.gulls.map(\.species),
                                                      delays: script.gulls.map { _ in 0 }, spec: spec, using: &rng)
            for (i, f) in strike.takeoffFrames.enumerated() where script.gulls.indices.contains(i) && paths.indices.contains(i) {
                let g = script.gulls[i]
                g.burst = paths[i]
                g.burstAt = T + Double(max(1, f) - 1) / max(1, clip.fps)
                g.burstFlap = Double.random(in: 0..<(Double(ZoneOutdoorArt.gullFrames(g.species).count) / spec.fps), using: &rng)
            }
            script.notes.append("\(script.gulls.count) gulls land from \(String(format: "%.2f", T - 4.6)) s, take off at " +
                                script.gulls.map { String(format: "%.2f", $0.burstAt) }.joined(separator: ", ") + " s")
        }
        demoScript = script
        return script
    }

    /// The run at `t`: the loop's frame (frame 0 at the clip's start), each animal where its run has it with the frame it
    /// shows, the strike gulls, and the clip's frame while it plays (held at its last until it is dropped, 0.3 s on).
    func demoPose(at t: Double) {
        guard let spec, let script = demoScript else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let clip = script.clip
        poster.contents = ZoneOutdoorArt.frame(at: t - script.orcaAt + Double(clip.startLoopFrame) / spec.fps)
        for c in crabs + walkers {
            guard let kind = species(of: c), let segs = script.tracks[ObjectIdentifier(c)], let s = segs.last(where: { $0.t0 <= t }) else { continue }
            let all = ZoneOutdoorArt.crabFrames(c.species)
            guard let first = all.first else { continue }
            c.layer.opacity = 1
            c.layer.transform = CATransform3DMakeScale(kind.flip(s.facing), 1, 1)
            if s.walk {
                let k = s.seconds > 0 ? CGFloat(min(1, (t - s.t0) / s.seconds)) : 1
                c.layer.position = fit.point(CGPoint(x: s.from.x + (s.to.x - s.from.x) * k, y: s.from.y + (s.to.y - s.from.y) * k))
                let frames = kind.walkFrames.map { r in r.compactMap { all.indices.contains($0 - 1) ? all[$0 - 1] : nil } } ?? all
                let i = Int((t - s.t0) * kind.fps * s.rate)
                c.layer.contents = frames.count > 1 && Double(i) < s.seconds * kind.fps * s.rate ? frames[i % frames.count] : first
            } else {
                c.layer.position = fit.point(s.from)
                c.layer.contents = first
                if s.idle, let range = kind.idleFrames, all.count >= range.upperBound {
                    // `idle`'s keyframes for this rest.
                    let own = range.map { all[$0 - 1] }, seconds = s.t1 - s.t0
                    var values: [CGImage] = []
                    if kind.behavior == .crawlRest {
                        values = Array(own.prefix(2))
                        let tail = own.count > 2 ? Array(own.suffix(2)) : own
                        while Double(values.count) / kind.fps < seconds { values += tail }
                    } else {
                        while Double(values.count) / kind.fps < seconds { values += [first, first, first] + own + [first] }
                    }
                    let i = Int((t - s.t0) * kind.fps)
                    if values.indices.contains(i) { c.layer.contents = values[i] }
                }
            }
        }
        for g in script.gulls {
            let gs = spec.gulls[max(0, min(spec.gulls.count - 1, g.species))]
            let flight = ZoneOutdoorArt.gullFrames(g.species)
            func fly(_ path: ZoneOutdoorGeometry.GullPath, _ since: Double, flap: Double) {
                let k = CGFloat(max(0, min(1, since / path.seconds)))
                let (ground, h) = path.at(k)
                g.gull.bounds = CGRect(x: 0, y: 0, width: gs.size.width * fit.scale, height: gs.size.height * fit.scale)
                g.gull.anchorPoint = CGPoint(x: gs.centre.x / gs.size.width, y: gs.centre.y / gs.size.height)
                g.gull.transform = ZoneOutdoorGeometry.gullTransform(path.heading)
                g.gull.position = fit.point(CGPoint(x: ground.x, y: ground.y - h * gs.shadowPerMetre))
                g.gull.contents = flight.isEmpty ? nil : flight[Int((since + flap) * spec.fps) % flight.count]
                g.shadow.contents = ZoneOutdoorArt.shadow
                g.shadow.contentsGravity = .resize
                g.shadow.bounds = CGRect(x: 0, y: 0, width: gs.shadowSize.width * fit.scale, height: gs.shadowSize.height * fit.scale)
                g.shadow.position = fit.point(ground)
                g.shadow.opacity = 0.18
            }
            g.gull.contentsGravity = .resize
            let gone = g.burst.map { t >= g.burstAt + $0.seconds + 0.2 } ?? false
            g.gull.isHidden = t < g.landAt || gone
            g.shadow.isHidden = g.gull.isHidden
            guard !g.gull.isHidden else { continue }
            if let burst = g.burst, t >= g.burstAt {
                fly(burst, t - g.burstAt, flap: g.burstFlap)
            } else if t < g.standsAt {
                fly(g.landing, t - g.landAt, flap: g.flap)
            } else if let st = spec.stand(gs.kind) {
                let frames = ZoneOutdoorArt.standFrames(st.kind)
                guard let f0 = frames.first else { continue }
                let bob = frames.count > 1 ? [f0, f0, f0, f0, frames[1], frames[1], f0, f0] : [f0]
                let u = ((t - g.standsAt) / g.bob).truncatingRemainder(dividingBy: 1)
                g.gull.contents = bob[min(bob.count - 1, Int(u * Double(bob.count)))]
                g.gull.bounds = CGRect(x: 0, y: 0, width: st.size.width * fit.scale, height: st.size.height * fit.scale)
                g.gull.anchorPoint = CGPoint(x: st.foot.x / st.size.width, y: st.foot.y / st.size.height)
                g.gull.transform = CATransform3DMakeScale(g.landing.heading.dx >= 0 ? 1 : -1, 1, 1)
                g.gull.position = fit.point(g.foot)
                g.shadow.opacity = 0
            }
        }
        let on = t >= script.orcaAt && t < script.orcaAt + clip.seconds + 0.3
        if on {
            let l = orca.sublayers?.first { $0.name == "orca-demo" } ?? {
                let l = CALayer()
                l.name = "orca-demo"
                l.contentsGravity = .resize
                orca.addSublayer(l)
                return l
            }()
            l.frame = fit.rect(clip.box)
            l.contents = ZoneOutdoorArt.orcaFrame(clip.id, min(clip.frames - 1, Int((t - script.orcaAt) * clip.fps)))
        } else {
            orca.sublayers = nil
        }
    }
    #endif

    // ───────── A still picture ─────────

    /// For a still picture (not live): the loop's frame at `t` seconds, each crab `t` seconds into a walk of its own (frame
    /// 1 when standing), and the given flights where they are at `t` (none: no gull).
    func pose(at t: Double, gulls flights: [ZoneGullFlight] = [], crabsWalk: Bool = true) {
        guard !live, let spec else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        poster.contents = ZoneOutdoorArt.frame(at: t)
        for c in crabs {
            guard let crab = species(of: c) else { continue }
            let crabFrames = ZoneOutdoorArt.crabFrames(c.species)
            if c.stillWalk == nil { c.stillWalk = ZoneOutdoorGeometry.crabStep(from: c.at, crab: crab, using: &rng) }
            guard crabsWalk, let walk = c.stillWalk else {
                place(c)
                continue
            }
            let moving = t > 0 && t < walk.seconds
            c.layer.position = fit.point(walk.at(t))
            c.layer.transform = CATransform3DMakeScale(crab.flip(walk.facing), 1, 1)
            if !crabFrames.isEmpty { c.layer.contents = crabFrames[moving ? Int(t * spec.fps) % crabFrames.count : 0] }
        }
        for g in flying {
            g.gull.removeFromSuperlayer()
            g.shadow.removeFromSuperlayer()
        }
        flying = []
        for (i, flight) in flights.enumerated() {
            let frames = ZoneOutdoorArt.gullFrames(flight.species)
            let (gull, shadow) = gullLayers(flight)
            let p = flight.at(t - flight.delay)
            gull.position = fit.point(p)
            shadow.position = fit.point(CGPoint(x: p.x, y: p.y + flight.shadowDrop))
            if !frames.isEmpty { gull.contents = frames[(Int(max(0, t) * spec.fps) + i * 17) % frames.count] }
            flying.append((gull, shadow, flight))
        }
    }

    /// Where each crab's foot is shown (presentation while walking), in the picture.
    func crabFeet() -> [CGPoint] { crabs.map { fit.back($0.layer.presentation()?.position ?? $0.layer.position) } }
}

// ───────── a Fable session's aura (Blaze Mode, flame-and-lightning possession) ─────────

/// The gold aura a Fable session's pet wears in Seaview (an anime power-up's energy, one continuous mass round the pet. A gold rim hugs the pet's own
/// silhouette in the pose it shows (white-hot only in a thin band at the body, then saturated gold, amber further out),
/// its brightness rippling upward along the edge. Round the pet one soft egg of fire, a little wider than the body, with a
/// jagged crown over the head: its outline is a loop of frames (`envelopeFrames`, the mask) whose spikes flare and shift
/// upward as one shape, anime-style, while two seamless flame textures scroll upward inside at different speeds. The rim,
/// the orange laid under the fire and the textures are all cut by that same loop, so nothing detaches: no tongues, no
/// clumps. A pool on the floor. Busy, it powers up: brighter, a faster loop, a taller and spikier crown, every 3 to 6 s a
/// surge (the whole envelope stretches up from the feet and brightens, then settles), and every 3 to 8 s a burst of
/// power-up lightning. Idle it flows slowly: a low smooth crown, about 60% as bright, a gentle breathing of its height.
///
/// Light, not paint: every part but the lightning and the thin orange under the fire is composited additively
/// (`additive`), so it brightens what is under it and never covers it; those two are drawn over (white added to a pale
/// desk would not show, blue added to the gold would turn white, and screen cannot saturate a pale ground). Its pictures
/// are smooth, drawn once and cached (the rim once for each pet frame it hugs); every motion is a repeating Core Animation
/// loop sampled from one function of time, the same function a still picture is posed by (`phase`), so a still shows a
/// real moment of the live loop. One holder in the figure's own layer, under its sprite, so walks carry it and the pet
/// stays on top. Points as the figure's: feet at the origin, y down.
@MainActor enum ZoneAura {
    /// The compositing every part but the lightning uses: screen, light added and never past white.
    static let additive = "screenBlendMode"
    /// The moment a still or Reduce Motion shows, seconds into the loops (no lightning then).
    nonisolated static let stillPhase = 0.37

    /// The colours (burning, not misty): white-yellow only in a thin band at the pet's edge, then saturated
    /// gold, orange towards the edges, a deep amber at the outer rim; the lightning's white core and its cyan to blue glow.
    static let core: UInt32 = 0xFFF6C8, gold: UInt32 = 0xFFC72C, amber: UInt32 = 0xFF9A1F, ember: UInt32 = 0xF07A14
    static let arcWhite: UInt32 = 0xFFFFFF, arcCyan: UInt32 = 0x7FDBFF, arcDeep: UInt32 = 0x3AA0FF

    /// How a state looks. `crown`: how far the crown's tallest spike reaches over the head, in the pet's drawn heights;
    /// `bright`: the fire's strength; `scroll`: seconds the near texture takes to travel one tile up (the far one takes
    /// 1.6 times that); `fps`: how many outline frames a second the mask loop plays; `jag`: how spiky the crown is (0: a
    /// smooth low dome, 1: flaring spikes); `surges`: whether it power-ups; `pool`: the floor pool's strength; `ripple`:
    /// seconds the rim's ripple takes to travel the body. Busy is only a little wider and taller than idle (`envelopeWide`,
    /// `crown`); its intensity is in the brightness, the speed, the spikes, the surges and the lightning, not in the area.
    struct Look {
        let crown: CGFloat
        let bright: Double, scroll: Double
        let fps: Double, jag: Double, surges: Bool
        let pool: Float
        let ripple: Double
    }

    static let busyLook = Look(crown: 0.42, bright: 1, scroll: 0.45, fps: 12, jag: 1, surges: true, pool: 0.9, ripple: 0.8)
    static let calmLook = Look(crown: 0.25, bright: 0.6, scroll: 1.6, fps: 5, jag: 0.35, surges: false, pool: 0.25, ripple: 2.8)
    static func look(busy: Bool) -> Look { busy ? busyLook : calmLook }
    /// The strength of the orange laid under the fire by normal compositing (`ember` part): screen can only brighten, and on a
    /// pale desk the gold would wash out to mist without it. Busy: dense, so every busy frame reads as solid
    /// gold-orange, not only the surges; idle at its `bright` times 0.22.
    static let emberAlpha: Float = 0.335  // +12%
    static func emberAlpha(busy: Bool) -> Double { busy ? Double(emberAlpha) : 0.22 * calmLook.bright }
    /// How many outline frames the loop has (18, so the cycling reads smooth).
    static let outlineFrames = 18
    /// A surge: how much the envelope stretches up (of its height), how much it brightens, and its timing: up in 0.25 s,
    /// settled 0.5 s later.
    static let surgeStretch = 0.25, surgeBrighten = 0.4, surgeUp = 0.25, surgeDown = 0.5

    /// The holder with its parts named, back to front: the floor pool, the rim (`hug`: its picture and the ripple over it),
    /// a thin orange of the fire's shape drawn over, not added (`ember`), the fire (`flame`: its tint and the two scrolling
    /// textures), the lightning's glow and cores. The rim, the orange and the fire each wear a mask that plays the same
    /// outline loop (`outline`), so they move as one body.
    static func make() -> CALayer {
        let aura = CALayer()
        aura.name = "aura"
        aura.bounds = .zero
        for name in ["pool", "hug", "ember", "flame", "arcFlare"] {
            let part = CALayer()
            part.name = name
            if name != "ember" { part.compositingFilter = additive }
            if name == "hug" || name == "flame" || name == "ember" {
                let mask = CALayer()
                mask.name = "mask"
                mask.contentsGravity = .resize
                part.mask = mask
                for child in name == "hug" ? ["rim", "ripple"] : name == "flame" ? ["base", "flow", "flow"] : [] {
                    let layer = CALayer()
                    layer.name = child
                    layer.compositingFilter = additive
                    part.addSublayer(layer)
                }
            }
            aura.addSublayer(part)
        }
        return aura
    }

    /// the lightning's own holder, which the figure puts over its pet (thin lines: they hide little of it): the blue
    /// glows (`arcGlow`) under the white cores (`arc`), each a pool of `slots` bolt layers (`bolt`), all drawn over.
    static func makeBolts() -> CALayer {
        let host = CALayer()
        host.name = "bolts"
        host.bounds = .zero
        for name in ["arcGlow", "arc"] {
            let part = CALayer()
            part.name = name
            // then the jumping arcs' pool (`spark`), over the trees.
            for i in 0..<(slots + arcSlots) {
                let bolt = CALayer()
                bolt.name = i < slots ? "bolt" : "spark"
                bolt.opacity = 0
                part.addSublayer(bolt)
            }
            host.addSublayer(part)
        }
        return host
    }

    static func parts(_ aura: CALayer, _ name: String) -> [CALayer] { aura.sublayers?.filter { $0.name == name } ?? [] }
    static func part(_ aura: CALayer, _ name: String) -> CALayer? { parts(aura, name).first }
    /// Whether it is shown busy, as last shaped.
    static func isBusy(_ aura: CALayer) -> Bool { (aura.value(forKey: "busy") as? Bool) ?? false }

    /// Runs `f` (a value at a time, in seconds) on `layer`'s `key` as a smooth loop of `period`, started `offset` into it;
    /// or, not `moving`, sets the value it has at `phase`.
    private static func drive(_ layer: CALayer, _ key: String, name: String, period: Double, offset: Double, moving: Bool, phase: Double,
                              _ f: (Double) -> CGFloat) {
        let held = f(phase + offset)
        if key == "opacity" { layer.opacity = Float(moving ? f(offset) : held) } else { layer.setValue(moving ? f(offset) : held, forKeyPath: key) }
        guard moving else { return }
        let steps = 24
        let loop = CAKeyframeAnimation(keyPath: key)
        loop.values = (0...steps).map { NSNumber(value: Double(f(Double($0) / Double(steps) * period))) }
        loop.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        loop.calculationMode = .linear
        loop.duration = period
        loop.repeatCount = .infinity
        loop.timeOffset = offset.truncatingRemainder(dividingBy: period)
        layer.add(loop, forKey: name)
    }

    /// Where a loop of `period` is at `t`, 0 up to 1: at the loop's own end 1, not 0 again (a scroll's last keyframe must
    /// land a whole tile on, or the texture snaps back over the last step).
    private static func turn(_ t: Double, _ period: Double) -> Double {
        let s = (t / period).truncatingRemainder(dividingBy: 1)
        return s == 0 && t > 0 ? 1 : s
    }

    /// The same for a position.
    private static func drivePoint(_ layer: CALayer, name: String, period: Double, offset: Double, moving: Bool, phase: Double,
                                   _ f: (Double) -> CGPoint) {
        layer.position = f(moving ? offset : phase + offset)
        guard moving else { return }
        let steps = 24
        let loop = CAKeyframeAnimation(keyPath: "position")
        loop.values = (0...steps).map { NSValue(point: f(Double($0) / Double(steps) * period)) }
        loop.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        loop.calculationMode = .linear
        loop.duration = period
        loop.repeatCount = .infinity
        loop.timeOffset = offset.truncatingRemainder(dividingBy: period)
        layer.add(loop, forKey: name)
    }

    /// Shapes the aura round the pet's frame as shown: `sprite`, drawn in `frame` (the figure's points); `wide` × `high`
    /// for a figure with no picture yet. `moving`: its loops run, each started at a point of its own by `seed` (the
    /// session), so two Fable pets never flicker in step; else it holds the moment `phase` seconds in. Again with the same,
    /// it is left as it is (the room looks every 2 s).
    static func shape(_ aura: CALayer, sprite: CGImage?, frame: CGRect, wide: CGFloat, high: CGFloat, busy: Bool, moving: Bool, seed: String,
                      phase: Double = stillPhase, bolts: CALayer? = nil) {
        let pictureKey = sprite.map { "\(ObjectIdentifier($0).hashValue)" } ?? "-"
        let key = "\(pictureKey) \(frame) \(Int(wide * 4)) \(Int(high * 4)) \(busy) \(moving)" + (moving ? "" : " \(phase)")
        guard aura.value(forKey: "shaped") as? String != key else { return }
        aura.setValue(key, forKey: "shaped")
        aura.setValue(busy, forKey: "busy")
        let look = look(busy: busy)
        let pi2 = 2 * Double.pi
        // Every loop off, the hug's and the fire's children's too; the parts made a shape at a time go.
        for part in (aura.sublayers ?? []) + (bolts?.sublayers ?? []) {
            part.removeAllAnimations()
            for child in part.sublayers ?? [] { child.removeAllAnimations() }
        }
        for part in aura.sublayers ?? [] { part.mask?.removeAllAnimations() }
        func seeded(_ salt: UInt64, _ i: Int = 0) -> Double { zoneFXSeed(seed + "\(i)", salt: salt) }

        // The pet as drawn: its picture's opaque box in the figure's points, and where its head is across.
        var drawn = CGRect(x: -wide / 2, y: -high, width: wide, height: high)
        if let sprite, let box = drawnBox(sprite), frame.width > 0 {
            let kx = frame.width / CGFloat(sprite.width), ky = frame.height / CGFloat(sprite.height)
            drawn = CGRect(x: frame.minX + box.rect.minX * kx, y: frame.minY + box.rect.minY * ky, width: box.rect.width * kx, height: box.rect.height * ky)
        }

        // The fire's box: the envelope round the body and over its head. Its outline is a loop of frames on the masks of
        // the rim, the orange under the fire and the fire itself, the same loop at the same moment on each, so all of it
        // flares as one body; inside the fire the two textures scroll up.
        let box = CGSize(width: drawn.width * envelopeWide(busy: busy), height: drawn.height * (1 + look.crown + envelopeOver))
        let boxOrigin = CGPoint(x: drawn.midX - box.width / 2, y: drawn.maxY - box.height)
        let frames = Self.envelopeFrames(busy: busy)
        let loopSeconds = Double(frames.count) / look.fps, loopStart = seeded(0x56) * loopSeconds
        func frameAt(_ t: Double) -> CGImage? {
            guard !frames.isEmpty else { return nil }
            return frames[Int((t / loopSeconds).truncatingRemainder(dividingBy: 1) * Double(frames.count)) % frames.count]
        }
        func outline(_ mask: CALayer?, in rect: CGRect) {
            guard let mask else { return }
            mask.frame = rect
            mask.contents = moving ? frames.first : frameAt(phase + loopStart)
            guard moving, frames.count > 1 else { return }
            let loop = CAKeyframeAnimation(keyPath: "contents")
            loop.values = frames
            loop.calculationMode = .discrete
            loop.duration = loopSeconds
            loop.repeatCount = .infinity
            loop.timeOffset = loopStart
            mask.add(loop, forKey: "outline")
        }
        // The power-up (busy): at the surges' moments the value goes from `base` up by `amount` in 0.25 s and settles in
        // 0.5 s; idle, it breathes gently instead. Held, the value it has at `phase`.
        let surges = Self.surges(seed: seed)
        func pulse(_ layer: CALayer, _ key: String, name: String, base: Double, amount: Double) {
            if look.surges {
                guard moving else { return layer.setValue(base + amount * Self.surgeAt(phase, seed: seed), forKeyPath: key) }
                var times: [NSNumber] = [0], values: [Double] = [base]
                for at in surges.at {
                    for (dt, x) in Self.surgeShape {
                        times.append(NSNumber(value: (at + dt) / surges.period))
                        values.append(base + amount * x)
                    }
                }
                times.append(1)
                values.append(base)
                let loop = CAKeyframeAnimation(keyPath: key)
                loop.values = values
                loop.keyTimes = times
                loop.calculationMode = .linear
                loop.duration = surges.period
                loop.repeatCount = .infinity
                layer.setValue(base, forKeyPath: key)
                layer.add(loop, forKey: name)
            } else {
                let breath = 2.5
                drive(layer, key, name: name, period: breath, offset: seeded(0x57) * breath, moving: moving, phase: phase) { t in
                    CGFloat(base + amount * 0.12 * (0.5 + 0.5 * sin(pi2 * t / breath)))
                }
            }
        }

        // The rim round the body: its picture with a band of light rippling up it, cut by the outline.
        if let hugLayer = part(aura, "hug") {
            let rim = hugLayer.sublayers?.first { $0.name == "rim" }, ripple = hugLayer.sublayers?.first { $0.name == "ripple" }
            if let sprite, let hug = hug(for: sprite), frame.width > 0 {
                let kx = frame.width / CGFloat(sprite.width), ky = frame.height / CGFloat(sprite.height)
                hugLayer.frame = frame.insetBy(dx: -hug.pad * kx, dy: -hug.pad * ky)
                outline(hugLayer.mask, in: CGRect(x: boxOrigin.x - hugLayer.frame.minX, y: boxOrigin.y - hugLayer.frame.minY, width: box.width, height: box.height))
                rim?.contents = hug.picture
                rim?.frame = hugLayer.bounds
                rim?.opacity = Float(busy ? 1 : look.bright * 0.72)  // busy brighter, idle dimmer
                if let ripple {
                    // Three tiles stacked, travelling up one tile a loop: the rim's box is always covered.
                    let tile = hugLayer.bounds.height
                    ripple.contents = Self.rippleTiles
                    ripple.anchorPoint = CGPoint(x: 0.5, y: 0)
                    ripple.bounds = CGRect(x: 0, y: 0, width: hugLayer.bounds.width, height: tile * 3)
                    ripple.opacity = Float(look.bright * 0.9)
                    let start = seeded(0x50) * look.ripple
                    drivePoint(ripple, name: "scroll", period: look.ripple, offset: start, moving: moving, phase: phase) { t in
                        CGPoint(x: hugLayer.bounds.midX, y: -tile * (1 + CGFloat(turn(t, look.ripple))))
                    }
                }
            } else {
                hugLayer.mask?.contents = nil
                rim?.contents = nil
                ripple?.contents = nil
            }
        }
        // The orange under the fire, drawn over: the fire's tint, fading out well inside its edge, cut by the outline.
        if let ember = part(aura, "ember") {
            ember.anchorPoint = CGPoint(x: 0.5, y: 1)
            ember.bounds = CGRect(origin: .zero, size: box)
            ember.position = CGPoint(x: drawn.midX, y: drawn.maxY)
            ember.contents = Self.envelopeTint(busy: busy, under: true)
            outline(ember.mask, in: ember.bounds)
            pulse(ember, "transform.scale.y", name: "surge", base: 1, amount: surgeStretch)
            pulse(ember, "opacity", name: "surgeLight", base: emberAlpha(busy: busy), amount: Double(emberAlpha) * surgeBrighten)
        }
        // The fire: its tint under the two textures scrolling up, cut by the outline; it surges from the feet.
        if let flame = part(aura, "flame") {
            flame.anchorPoint = CGPoint(x: 0.5, y: 1)
            flame.bounds = CGRect(origin: .zero, size: box)
            flame.position = CGPoint(x: drawn.midX, y: drawn.maxY)
            flame.opacity = Float(look.bright)
            outline(flame.mask, in: flame.bounds)
            pulse(flame, "transform.scale.y", name: "surge", base: 1, amount: surgeStretch)
            if let base = flame.sublayers?.first(where: { $0.name == "base" }) {
                base.contents = Self.envelopeTint(busy: busy)
                base.frame = flame.bounds
                pulse(base, "opacity", name: "surgeLight", base: busy ? 0.62 : 0.4, amount: 0.38 * surgeBrighten)
            }
            for (k, flow) in (flame.sublayers ?? []).filter({ $0.name == "flow" }).enumerated() {
                // The near texture at the box's height, the far one smaller and slower; three tiles each, one tile a loop.
                let tile = k == 0 ? box.height : box.height * 0.7, seconds = k == 0 ? look.scroll : look.scroll * 1.6
                flow.contents = Self.flowTiles(k, busy: busy)
                flow.anchorPoint = CGPoint(x: 0.5, y: 0)
                flow.bounds = CGRect(x: 0, y: 0, width: box.width, height: tile * 3)
                flow.opacity = k == 0 ? 1 : busy ? 0.95 : 0.65
                let start = seeded(0x51, k) * seconds
                drivePoint(flow, name: "scroll", period: seconds, offset: start, moving: moving, phase: phase) { t in
                    CGPoint(x: box.width / 2, y: box.height - tile * (2 + CGFloat(turn(t, seconds))))
                }
            }
        }
        if let pool = part(aura, "pool") {
            pool.contents = Self.glow(round: false)
            let across = drawn.width * (busy ? 1.9 : 1.6)
            pool.bounds = CGRect(x: 0, y: 0, width: across, height: across * 0.3)
            pool.position = CGPoint(x: drawn.midX, y: drawn.maxY + high * 0.01)
            let period = busy ? 0.7 : 2.5
            drive(pool, "opacity", name: "breath", period: period, offset: seeded(0x54) * period, moving: moving, phase: phase) { t in
                CGFloat(Double(look.pool) * (0.85 + 0.15 * sin(pi2 * t / period)))
            }
        }
        // the lightning crawls on the body, over the pet, from the session's `storm`: a pool of tree layers (`bolt`: the
        // cores under `arc`, over their glow under `arcGlow`, in the figure's `bolts` holder over the sprite), each on one
        // keyframe loop of its own (picture, box and place stepping at each flicker; opacity joined straight, so the
        // afterglow dies smoothly, the glow after the core), no timers. The trees are drawn on this frame's silhouette
        // (`boltPictures`). Busy, a discharge every 0.35–0.8 s and a strike every 4–7 s with a flash over the whole aura
        // (`arcFlare`); idle, a small tree every 8–14 s. Held, as they are at `phase` (a tree at `stillPhase`).
        let storm = Self.storm(seed: seed, busy: busy)
        var pictures: [BoltPicture] = [], brushes: [BoltPicture] = [], rim: [RimPoint] = [], kx: CGFloat = 1, ky: CGFloat = 1
        if let sprite, frame.width > 0, drawn.height > 0 {
            kx = frame.width / CGFloat(sprite.width)
            ky = frame.height / CGFloat(sprite.height)
            pictures = Self.boltPictures(for: sprite, pointsHigh: drawn.height)
            brushes = Self.arcBrushes(for: sprite, pointsHigh: drawn.height)
            rim = Self.perimeter(for: sprite, pointsHigh: drawn.height)
        }
        func placed(_ r: CGRect) -> CGRect {
            CGRect(x: frame.minX + r.minX * kx, y: frame.minY + r.minY * ky, width: r.width * kx, height: r.height * ky)
        }
        // One pool layer's loop: the pictures it shows (`steps`: from when, which), stepping discretely, and its opacity
        // (`levels`, joined straight); held, as at `phase`.
        func run(_ bolt: CALayer, _ steps: [(at: Double, art: Int)], _ levels: [(Double, Float)], _ art: [BoltPicture], glowing: Bool) {
            bolt.opacity = 0
            bolt.contents = nil
            guard !art.isEmpty, let first = steps.first, let latest = steps.last else { return }
            func picture(_ i: Int) -> CGImage { glowing ? art[i % art.count].glow : art[i % art.count].core }
            func put(_ i: Int) {
                let r = placed(art[i % art.count].rect)
                bolt.bounds = CGRect(origin: .zero, size: r.size)
                bolt.position = CGPoint(x: r.midX, y: r.midY)
                bolt.contents = picture(i)
            }
            guard moving else {
                let at = phase.truncatingRemainder(dividingBy: storm.period)
                put((steps.last(where: { $0.at <= at }) ?? latest).art)
                bolt.opacity = Self.level(levels, at: phase, period: storm.period)
                return
            }
            var times: [NSNumber] = [0], shown: [CGImage] = [picture(first.art)], boxes: [NSValue] = [], spots: [NSValue] = []
            let r0 = placed(art[first.art % art.count].rect)
            boxes.append(NSValue(rect: CGRect(origin: .zero, size: r0.size)))
            spots.append(NSValue(point: CGPoint(x: r0.midX, y: r0.midY)))
            for step in steps {
                let r = placed(art[step.art % art.count].rect)
                times.append(NSNumber(value: step.at / storm.period))
                shown.append(picture(step.art))
                boxes.append(NSValue(rect: CGRect(origin: .zero, size: r.size)))
                spots.append(NSValue(point: CGPoint(x: r.midX, y: r.midY)))
            }
            func track(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values
                a.keyTimes = times
                a.calculationMode = .discrete
                return a
            }
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = levels.map { NSNumber(value: $0.1) }
            fade.keyTimes = levels.map { NSNumber(value: $0.0 / storm.period) }
            fade.calculationMode = .linear
            let group = CAAnimationGroup()
            group.animations = [fade, track("contents", shown), track("bounds", boxes), track("position", spots)]
            group.duration = storm.period
            group.repeatCount = .infinity
            put(first.art)
            bolt.opacity = 0
            bolt.add(group, forKey: "arcs")
        }
        // a crawling arc layer's loop (`arcLoops`): at each hop its brush, turn and spot step discretely (`contents`,
        // `transform`, `position`), lit at full strength for `arcPop`, then 0.8, dark in its gaps; held, as at `phase` (an
        // idle still shows its few arcs lit). The spot: the outline point pushed `out` outward, then moved in so the
        // brush's ends stay inside the body's drawn box ×1.08.
        let arcLoops = Self.arcLoops(seed: seed, busy: busy)
        let limit = drawn.insetBy(dx: -drawn.width * (boltReach - 1) / 2, dy: -drawn.height * (boltReach - 1) / 2)
        func crawl(_ spark: CALayer, _ slot: Int, glowing: Bool) {
            spark.opacity = 0
            spark.contents = nil
            spark.transform = CATransform3DIdentity
            guard slot < arcLoops.count, !brushes.isEmpty, !rim.isEmpty else { return }
            let loop = arcLoops[slot]
            let r0 = brushes[0].rect
            spark.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            spark.bounds = CGRect(x: 0, y: 0, width: r0.width * kx, height: r0.height * ky)
            func picture(_ h: Hop) -> CGImage { glowing ? brushes[h.brush % brushes.count].glow : brushes[h.brush % brushes.count].core }
            func spot(_ h: Hop) -> (CGPoint, CATransform3D) {
                // On the head's outline the arc keeps closer along it (±14°), so it never reaches over the face.
                let p = rim[h.spot % rim.count], onHead = frame.minY + p.point.y * ky < drawn.minY + drawn.height * 0.5
                let a = p.angle + (h.turn.magnitude > Double.pi / 2 ? Double.pi + (h.turn - Double.pi) * (onHead ? 0.4 : 1) : h.turn * (onHead ? 0.4 : 1))
                let line = brushes[h.brush % brushes.count].lines[0]
                let half = Double(abs(line.last!.x - line[0].x)) / 2 * Double(kx)
                let push = h.out * Double(drawn.width)
                var c = CGPoint(x: frame.minX + p.point.x * kx + p.normal.dx * push, y: frame.minY + p.point.y * ky + p.normal.dy * push)
                let ex = abs(cos(a)) * half, ey = abs(sin(a)) * half
                c.x = limit.width > 2 * ex ? min(max(c.x, limit.minX + ex), limit.maxX - ex) : limit.midX
                c.y = limit.height > 2 * ey ? min(max(c.y, limit.minY + ey), limit.maxY - ey) : limit.midY
                var t = CATransform3DMakeRotation(a, 0, 0, 1)
                if h.flip { t = CATransform3DScale(t, 1, -1, 1) }
                return (c, t)
            }
            let lit: Float = glowing ? 0.85 : 1, held: Float = glowing ? 0.65 : 0.8
            guard moving else {
                guard let h = Self.hop(loop, at: phase) else { return }
                let (c, t) = spot(h)
                spark.position = c
                spark.transform = t
                spark.contents = picture(h)
                spark.opacity = h.shown || !busy ? (phase.truncatingRemainder(dividingBy: loop.period) - h.at < arcPop ? lit : held) : 0
                return
            }
            var times: [NSNumber] = [], shown: [CGImage] = [], spots: [NSValue] = [], turns: [NSValue] = []
            var fadeTimes: [NSNumber] = [], levels: [NSNumber] = []
            for h in loop.hops {
                let (c, t) = spot(h)
                times.append(NSNumber(value: h.at / loop.period))
                shown.append(picture(h))
                spots.append(NSValue(point: c))
                turns.append(NSValue(caTransform3D: t))
                fadeTimes.append(NSNumber(value: h.at / loop.period))
                levels.append(NSNumber(value: h.shown ? lit : 0))
                if h.shown, h.on > arcPop {
                    fadeTimes.append(NSNumber(value: (h.at + arcPop) / loop.period))
                    levels.append(NSNumber(value: held))
                }
            }
            func track(_ key: String, _ values: [Any], _ keyTimes: [NSNumber]) -> CAKeyframeAnimation {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values
                a.keyTimes = keyTimes
                a.calculationMode = .discrete
                return a
            }
            let group = CAAnimationGroup()
            group.animations = [track("opacity", levels, fadeTimes), track("contents", shown, times), track("position", spots, times), track("transform", turns, times)]
            group.duration = loop.period
            group.repeatCount = .infinity
            if let first = loop.hops.first {
                let (c, t) = spot(first)
                spark.position = c
                spark.transform = t
                spark.contents = picture(first)
            }
            spark.add(group, forKey: "arcs")
        }
        for holder in bolts?.sublayers ?? [] {
            holder.bounds = .zero
            holder.anchorPoint = CGPoint(x: 0.5, y: 0.5)
            holder.position = .zero
            holder.opacity = 1
            holder.contents = nil
            let glowing = holder.name == "arcGlow"
            for (slot, bolt) in (holder.sublayers ?? []).filter({ $0.name == "bolt" }).enumerated() {
                let mine = storm.flickers.filter { $0.slot == slot }.map { (at: $0.at, art: $0.art) }
                run(bolt, mine, Self.track(storm, slot: slot, glow: glowing), pictures, glowing: glowing)
            }
            // the crawling arcs, each pool layer hopping round the whole outline on its own loop.
            for (slot, spark) in (holder.sublayers ?? []).filter({ $0.name == "spark" }).enumerated() {
                crawl(spark, slot, glowing: glowing)
            }
        }
        if let flare = part(aura, "arcFlare") {
            flare.contents = Self.glow(round: true)
            flare.bounds = CGRect(x: 0, y: 0, width: drawn.width * 1.7, height: drawn.height * 1.5)
            flare.position = CGPoint(x: drawn.midX, y: drawn.maxY - drawn.height * 0.55)
            flare.opacity = moving ? 0 : Float(Self.flareAt(phase, storm: storm))
            if moving, !storm.bigs.isEmpty {
                var times: [NSNumber] = [0], values: [Double] = [0]
                for big in storm.bigs {
                    for (dt, x) in Self.flareShape {
                        times.append(NSNumber(value: min(1, (big + dt) / storm.period)))
                        values.append(x)
                    }
                }
                times.append(1)
                values.append(0)
                let loop = CAKeyframeAnimation(keyPath: "opacity")
                loop.values = values
                loop.keyTimes = times
                loop.calculationMode = .linear
                loop.duration = storm.period
                loop.repeatCount = .infinity
                flare.add(loop, forKey: "flare")
            }
        }
    }

    /// A busy aura's surges: five, 3 to 6 s apart (seeded by the session), and the loop's length.
    static func surges(seed: String) -> (at: [Double], period: Double) {
        var at = 1.5 + 1.5 * zoneFXSeed(seed, salt: 0xB0), out: [Double] = []
        for i in 0..<5 {
            out.append(at)
            at += 3 + 3 * zoneFXSeed(seed + "\(i)", salt: 0xB1)
        }
        return (out, at)
    }

    /// A surge's shape: seconds after its moment, and how far up it is (0…1): up fast, settling slower.
    static let surgeShape: [(Double, Double)] = [(0, 0), (0.08, 0.48), (0.17, 0.88), (0.25, 1), (0.37, 0.72), (0.52, 0.3), (0.75, 0)]

    /// How far up a busy aura's surge is at `t` seconds into its loop (0 between surges).
    static func surgeAt(_ t: Double, seed: String) -> Double {
        let schedule = surges(seed: seed), at = t.truncatingRemainder(dividingBy: schedule.period)
        for start in schedule.at {
            let dt = at - start
            guard dt >= 0, dt <= surgeUp + surgeDown else { continue }
            for (a, b) in zip(surgeShape, surgeShape.dropFirst()) where dt >= a.0 && dt <= b.0 {
                return a.1 + (b.1 - a.1) * (dt - a.0) / (b.0 - a.0)
            }
        }
        return 0
    }
    // ── the lightning's schedule ──

    /// One flicker of one tree (`bolt`, counted through the loop): in pool layer `slot` from `at`, lit at `alpha` for `on`
    /// seconds, showing tree picture `art` (of the frame's `boltPictures`). on a tree's last flicker, `fade`: the
    /// afterglow after it, the glow dying over `fade` seconds and the core over 0.7 of it.
    struct Flicker {
        let bolt: Int, slot: Int
        let at: Double, on: Double
        let art: Int
        let alpha: Float
        var fade: Double = 0
    }
    /// A loop of lightning: its length, every flicker in it (by time), its discharges' moments and the strikes'.
    struct Storm {
        let period: Double
        let flickers: [Flicker]
        let bursts: [Double], bigs: [Double]
    }
    /// one hop of a crawling arc layer: from `at` for `on` seconds at perimeter point `spot` (of the frame's
    /// `perimeter`), brush `brush`, turned `turn` off the outline's tangent (radians), mirrored across its axis when `flip`,
    /// `out` (0…0.06 of the body's width) off the outline outward; `shown`: lit (else a brief gap).
    struct Hop {
        let at: Double, on: Double
        let spot: Int, brush: Int
        let turn: Double, flip: Bool, out: Double
        let shown: Bool
    }
    /// one arc layer's loop: its hops, back to back over `period`.
    struct ArcLoop { let period: Double; let hops: [Hop] }
    /// How many tree layers each of `arc` and `arcGlow` pools (never more than three trees on at once).
    static let slots = 3
    /// how many crawling arc layers each pools (busy all of them, idle `idleArcs`), how many perimeter points a frame
    /// keeps, how many brushes, and how long an arc stays at full brightness after a hop.
    static let arcSlots = 14, idleArcs = 3, perimeterPoints = 64, brushCount = 12, arcPop = 0.025
    /// busy, never fewer than this many arcs lit at once.
    static let arcsLitBusy = 8

    /// the session's crawling arcs, all `arcSlots` layers on one loop (6.4–7.4 s, seeded by the session). Busy, each
    /// layer hops every 50–90 ms to a random spot round the whole outline, lit 70% of the hops (then gaps are filled where
    /// fewer than `arcsLitBusy` would be lit); idle, `idleArcs` layers hop every 150–250 ms, lit 30% of the hops.
    static func arcLoops(seed: String, busy: Bool) -> [ArcLoop] {
        let key = (busy ? "busy " : "idle ") + seed
        if let done = arcCache[key] { return done }
        var rng = ZoneRandom(seed: UInt64(zoneFXSeed(seed, salt: busy ? 0xC5 : 0xC6) * 4_294_967_296) &+ 0xA2C)
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a..<b, using: &rng) }
        let period = r(6.4, 7.4), layers = busy ? arcSlots : idleArcs
        var loops: [[Hop]] = []
        for _ in 0..<layers {
            var hops: [Hop] = [], t = 0.0, spot = Int(r(0, Double(perimeterPoints)))
            while t < period - 0.001 {
                var on = busy ? r(0.11, 0.18) : r(0.25, 0.4)
                if period - t < on + (busy ? 0.11 : 0.25) { on = period - t }
                // A new spot every hop, never the one just left.
                spot = (spot + 1 + Int(r(0, Double(perimeterPoints - 1)))) % perimeterPoints
                hops.append(Hop(at: t, on: on, spot: spot, brush: Int(r(0, Double(brushCount))), turn: r(-35, 35) * Double.pi / 180 + (r(0, 1) < 0.5 ? Double.pi : 0),
                                flip: r(0, 1) < 0.5, out: r(0, 1) < 0.35 ? r(0, 0.06) : 0, shown: r(0, 1) < (busy ? 0.7 : 0.3)))
                t += on
            }
            loops.append(hops)
        }
        if busy {
            // Fill the thin moments: where fewer than `arcsLitBusy` are lit, light a dark hop there.
            var t = 0.0
            while t < period {
                let here = loops.indices.compactMap { l in loops[l].firstIndex { t >= $0.at && t < $0.at + $0.on }.map { (l, $0) } }
                var dark = here.filter { !loops[$0.0][$0.1].shown }
                while here.count - dark.count < arcsLitBusy, let (l, i) = dark.first {
                    let h = loops[l][i]
                    loops[l][i] = Hop(at: h.at, on: h.on, spot: h.spot, brush: h.brush, turn: h.turn, flip: h.flip, out: h.out, shown: true)
                    dark.removeFirst()
                }
                // Spread round the whole outline: each quarter of it (by perimeter point) at least two lit; a dark hop is
                // lit there, else one from the fullest quarter moves there.
                let quarter = perimeterPoints / 4
                for q in 0..<4 {
                    func count(_ k: Int) -> Int { here.filter { loops[$0.0][$0.1].shown && loops[$0.0][$0.1].spot / quarter == k }.count }
                    while count(q) < 2 {
                        let fullest = (0..<4).max { count($0) < count($1) }!
                        guard let (l, i) = dark.first ?? (count(fullest) > 2 ? here.first { loops[$0.0][$0.1].shown && loops[$0.0][$0.1].spot / quarter == fullest } : nil) else { break }
                        dark.removeAll { $0 == (l, i) }
                        let h = loops[l][i]
                        loops[l][i] = Hop(at: h.at, on: h.on, spot: q * quarter + Int(r(0, Double(quarter))), brush: h.brush, turn: h.turn, flip: h.flip, out: h.out, shown: true)
                    }
                }
                t += 0.005
            }
        }
        let made = loops.map { ArcLoop(period: period, hops: $0) }
        arcCache[key] = made
        return made
    }
    private static var arcCache: [String: [ArcLoop]] = [:]

    /// the hop a layer's loop is on at `t` seconds.
    static func hop(_ loop: ArcLoop, at t: Double) -> Hop? {
        let at = t.truncatingRemainder(dividingBy: loop.period)
        return loop.hops.last { $0.at <= at } ?? loop.hops.first
    }
    /// how many arcs are lit at `t` seconds.
    static func arcsLit(_ t: Double, seed: String, busy: Bool) -> Int {
        arcLoops(seed: seed, busy: busy).filter { hop($0, at: t)?.shown == true }.count
    }
    /// The flash over the aura at a strike: seconds after its moment and its opacity (all over in 0.12 s).
    static let flareShape: [(Double, Double)] = [(0, 0), (0.02, 1), (0.06, 0.55), (0.12, 0)]

    /// The session's lightning (seeded by it, so two pets never crackle in step). Busy: a discharge every 0.35–0.8 s,
    /// a main tree (mostly a small one on the other side with it), and whenever 4–7 s have passed since the last, a strike
    /// instead (with the flash); the loop ends where its fifth strike would come. Idle: five small trees 8–14 s apart. Each
    /// tree flickers two to four times over 200–300 ms (the same trunk, its branches re-rolled each time, the first the
    /// brightest), dark between, then dies away over a 120–200 ms afterglow. The first tree comes just before `stillPhase`,
    /// so the still shows it.
    static func storm(seed: String, busy: Bool) -> Storm {
        let key = (busy ? "busy " : "idle ") + seed
        if let done = stormCache[key] { return done }
        var rng = ZoneRandom(seed: UInt64(zoneFXSeed(seed, salt: busy ? 0xA5 : 0xA6) * 4_294_967_296) &+ (busy ? 0xB5 : 0x1D))
        func r(_ a: Double, _ b: Double) -> Double { Double.random(in: a..<b, using: &rng) }
        func family(_ range: Range<Int>) -> Int { range.lowerBound + Int(r(0, Double(range.count))) }
        var flickers: [Flicker] = [], free = [Double](repeating: -1, count: slots), bolts = 0, side = 0
        func tree(_ start: Double, family: Int, bright: Float) {
            guard let slot = free.indices.first(where: { free[$0] < start - 0.02 }) else { return }
            // longer-lived (0.16–0.3 s, 2–4 flickers), so one to three trees are up most of the time.
            let span = r(0.2, 0.3), count = 2 + Int(r(0, 3)), step = span / Double(count), fade = r(0.15, 0.25)
            let order = Array(0..<boltVariants).shuffled(using: &rng)
            for n in 0..<count {
                let last = n == count - 1
                flickers.append(Flicker(bolt: bolts, slot: slot, at: start + Double(n) * step, on: last ? step - 0.004 : step * r(0.5, 0.7),
                                        art: family * boltVariants + order[n % boltVariants],
                                        alpha: n == 0 ? bright : bright * Float(r(0.6, 0.88)), fade: last ? fade : 0))
            }
            free[slot] = start + span + fade
            bolts += 1
        }
        let first = stillPhase - 0.006
        var t = first, due = t + r(1, 2.5), bursts: [Double] = [], bigs: [Double] = []
        while true {
            // The loop ends so that its first strike, come round again, is 5–11 s after its last.
            if busy, bigs.count >= 4, t + (bigs[0] - first) >= due { break }
            if !busy && bursts.count >= 5 { break }
            let strike = busy && !bursts.isEmpty && t >= due
            bursts.append(t)
            if !busy {
                tree(t, family: family(boltSmall), bright: 0.85)
                t += r(8, 14)
                continue
            }
            if strike {
                bigs.append(t)
                due = t + r(4, 6.5)
                tree(t, family: family(boltStrike), bright: 1)
            } else {
                // the sides take turns (main families 0, 2 on the left, 1, 3 on the right); a second tree, mostly, a small one on the other side (4 left, 5 right).
                side = 1 - side
                tree(t, family: side + 2 * Int(r(0, 2)), bright: 0.95)
                // It comes 0.1–0.22 s after the main one (so the two keep a tree up longer), and only when that still
                // leaves a layer free for the next discharge.
                if r(0, 1) < 0.85, free.filter({ $0 < t + 0.335 }).count >= 2 { tree(t + r(0.1, 0.22), family: 4 + (1 - side), bright: 0.75) }
            }
            // Never past a strike that is due: it comes 0.35 s after the last tree at the latest, 4–7 s after the last strike.
            t = max(t + 0.355, min(t + r(0.355, 0.65), due))
        }
        let period = t - first
        let made = Storm(period: period, flickers: flickers.sorted { $0.at < $1.at }, bursts: bursts, bigs: bigs)
        stormCache[key] = made
        return made
    }
    private static var stormCache: [String: Storm] = [:]

    /// How bright pool layer `slot`'s core (or, `glow`, its glow) is through a storm's loop: (seconds in, opacity) points
    /// to join straight. Each flicker jumps on at its alpha and sags a little; between a tree's flickers the core all but
    /// goes out and the glow halves; after its last, the core dies over 0.7 of its afterglow, the glow over all of it.
    static func track(_ storm: Storm, slot: Int, glow: Bool) -> [(Double, Float)] {
        var points: [(Double, Float)] = [(0, 0)], level: Float = 0
        func to(_ t: Double, _ v: Float) {
            let t = min(max(t, points.last!.0), storm.period)
            points.append((t, v))
            level = v
        }
        for f in storm.flickers where f.slot == slot {
            to(f.at - 0.0005, level)
            to(f.at, f.alpha)
            to(f.at + f.on, f.alpha * 0.82)
            if f.fade == 0 {
                to(f.at + f.on + 0.0005, f.alpha * (glow ? 0.6 : 0.3))
            } else if glow {
                to(f.at + f.on + f.fade * 0.3, f.alpha * 0.45)
                to(f.at + f.on + f.fade, 0)
            } else {
                to(f.at + f.on + f.fade * 0.7, 0)
            }
        }
        to(storm.period, 0)
        return points
    }

    /// A track's opacity at `t` seconds into its loop.
    static func level(_ track: [(Double, Float)], at t: Double, period: Double) -> Float {
        let at = t.truncatingRemainder(dividingBy: period)
        for (a, b) in zip(track, track.dropFirst()) where at >= a.0 && at <= b.0 {
            return b.0 - a.0 < 1e-9 ? b.1 : a.1 + (b.1 - a.1) * Float((at - a.0) / (b.0 - a.0))
        }
        return 0
    }

    /// The flickers on at `t` seconds into a storm's loop (not counting afterglows).
    static func lit(_ t: Double, storm: Storm) -> [Flicker] {
        let at = t.truncatingRemainder(dividingBy: storm.period)
        return storm.flickers.filter { at >= $0.at && at < $0.at + $0.on }
    }

    /// How bright the big bursts' flare is at `t` seconds into a storm's loop (0…1).
    static func flareAt(_ t: Double, storm: Storm) -> Double {
        let at = t.truncatingRemainder(dividingBy: storm.period)
        for big in storm.bigs {
            let dt = at - big
            for (a, b) in zip(flareShape, flareShape.dropFirst()) where dt >= a.0 && dt <= b.0 {
                return a.1 + (b.1 - a.1) * (dt - a.0) / (b.0 - a.0)
            }
        }
        return 0
    }

    static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // ── The body's own rim, made once a pet frame ──

    private static var boxes: [ObjectIdentifier: (image: CGImage, rect: CGRect, headX: CGFloat)] = [:]
    private static var hugs: [ObjectIdentifier: (image: CGImage, picture: CGImage, pad: CGFloat, scale: CGFloat)] = [:]

    /// A picture's alpha, rows from the top, at `scale` times its size inside a margin of `pad` of its pixels.
    private static func alpha(_ image: CGImage, scale: CGFloat, pad: CGFloat) -> (values: [Float], width: Int, height: Int)? {
        let w = Int((CGFloat(image.width) + 2 * pad) * scale), h = Int((CGFloat(image.height) + 2 * pad) * scale)
        guard w > 0, h > 0, let canvas = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                                   bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
            let data = canvas.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        canvas.interpolationQuality = .high
        canvas.draw(image, in: CGRect(x: pad * scale, y: pad * scale, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
        return ((0..<(w * h)).map { Float(data[$0]) / 255 }, w, h)
    }

    /// Where a pet frame is drawn (alpha over 0.3), in its pixels from the top left, and the middle of its head across (its
    /// top quarter's opaque pixels); nil for a blank frame.
    static func drawnBox(_ image: CGImage) -> (rect: CGRect, headX: CGFloat)? {
        let id = ObjectIdentifier(image)
        if let known = boxes[id], known.image === image { return (known.rect, known.headX) }
        guard let a = alpha(image, scale: 1, pad: 0) else { return nil }
        var minX = a.width, maxX = -1, minY = a.height, maxY = -1
        for y in 0..<a.height { for x in 0..<a.width where a.values[y * a.width + x] > 0.3 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        guard maxX >= minX else { return nil }
        let headRows = minY...(minY + max(1, (maxY - minY) / 4))
        var sum = 0.0, count = 0.0
        for y in headRows { for x in minX...maxX where a.values[y * a.width + x] > 0.3 { sum += Double(x); count += 1 } }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        let headX = count > 0 ? CGFloat(sum / count) + 0.5 : rect.midX
        boxes[id] = (image, rect, headX)
        return (rect, headX)
    }

    /// Blurs `v` (`w` × `h`) with a box of radius `r` three times across and down: near enough a Gaussian.
    private static func blur(_ v: [Float], _ w: Int, _ h: Int, _ r: Int) -> [Float] {
        var a = v, b = v
        let n = Float(2 * r + 1)
        for _ in 0..<3 {
            for y in 0..<h {
                var sum: Float = 0
                for x in -r...r { sum += a[y * w + min(max(x, 0), w - 1)] }
                for x in 0..<w {
                    b[y * w + x] = sum / n
                    sum += a[y * w + min(x + r + 1, w - 1)] - a[y * w + max(x - r, 0)]
                }
            }
            for x in 0..<w {
                var sum: Float = 0
                for y in -r...r { sum += b[min(max(y, 0), h - 1) * w + x] }
                for y in 0..<h {
                    a[y * w + x] = sum / n
                    sum += b[min(y + r + 1, h - 1) * w + x] - b[max(y - r, 0) * w + x]
                }
            }
        }
        return a
    }

    /// The rim a pet frame's silhouette gives off: its alpha blurred three ways and coloured, a thin white-hot band at the
    /// body, gold round it, amber further out and a little higher (it rises as it fades). The picture covers the frame and
    /// `pad` of its pixels round it, `scale` picture pixels a frame pixel; nil for a blank frame.
    static func hug(for image: CGImage) -> (picture: CGImage, pad: CGFloat, scale: CGFloat)? {
        let id = ObjectIdentifier(image)
        if let known = hugs[id], known.image === image { return (known.picture, known.pad, known.scale) }
        guard let box = drawnBox(image) else { return nil }
        let across = max(box.rect.width, 1)
        let scale = min(4, max(0.5, 140 / across)), pad = (0.5 * across).rounded()
        guard let a = alpha(image, scale: scale, pad: pad) else { return nil }
        let w = a.width, h = a.height
        let mask = a.values.map { Float(smooth(0.2, 0.6, Double($0))) }
        let near = blur(mask, w, h, 3), mid = blur(mask, w, h, 10), far = blur(mask, w, h, 16)
        let lift = 8  // rows the far glow is raised
        guard let canvas = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = canvas.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        func channel(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) / 255 }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let below = min(h - 1, y + lift) * w + x  // memory rows run top first: "below" a row is the next one
                let hot = smooth(0.3, 0.75, Double(near[i])) * 0.5
                let body = smooth(0.02, 0.38, Double(mid[i])) * 0.95
                let out = smooth(0, 0.35, Double(max(far[i], far[below]))) * 0.7
                var rgb = [0.0, 0.0, 0.0]
                for (c, shift) in [UInt32(16), 8, 0].enumerated() {
                    rgb[c] = 1 - (1 - hot * channel(core, shift)) * (1 - body * channel(gold, shift)) * (1 - out * channel(ember, shift))
                }
                let alpha = 1 - (1 - hot) * (1 - body) * (1 - out)
                data[i * 4] = UInt8(255 * min(rgb[0], alpha))
                data[i * 4 + 1] = UInt8(255 * min(rgb[1], alpha))
                data[i * 4 + 2] = UInt8(255 * min(rgb[2], alpha))
                data[i * 4 + 3] = UInt8(255 * alpha)
            }
        }
        guard let picture = canvas.makeImage() else { return nil }
        hugs[id] = (image, picture, pad, scale)
        return (picture, pad, scale)
    }

    // ── The fire's pictures, drawn once ──

    private static var envelopeCache: [Int: CGImage] = [:]
    private static var flowCache: [Int: CGImage] = [:]
    private static var glowCache: [Bool: CGImage] = [:]

    /// The fire's box: how much wider than the pet's drawn width (busy a little wider than idle, the fire's soft edge
    /// never more than about a tenth of the pet's width past its sides), and how much room over the fringe's tallest lick
    /// (of the pet's height).
    static func envelopeWide(busy: Bool) -> CGFloat { busy ? 1.22 : 1.17 }
    static let envelopeOver: CGFloat = 0.06
    /// Where the pet is in a state's envelope picture: its half width (of the picture's half width) and the top of its head
    /// (of the picture's height; its feet at the bottom).
    static func petIn(busy: Bool) -> (half: Double, head: Double) {
        (1 / Double(envelopeWide(busy: busy)), 1 / Double(1 + look(busy: busy).crown + envelopeOver))
    }

    /// The crown's licks, left to right: where each stands across (u), its half width, its height at full flare (of the
    /// crown's reach), how many times it flares in one turn of the loop (whole turns, so the loop closes), where in its own
    /// flare it starts, and how far it leans out (u) as it rises. Neighbours overlap, so the crown is one edge, never apart.
    static let licks: [(u: Double, half: Double, high: Double, turns: Double, start: Double, lean: Double)] = [
        (-0.60, 0.30, 0.60, 1, 0.10, -0.10), (-0.38, 0.32, 0.85, 2, 0.55, -0.06), (-0.16, 0.30, 0.95, 1, 0.80, -0.03),
        (0.03, 0.34, 1.00, 2, 0.25, 0), (0.22, 0.30, 0.90, 1, 0.45, 0.04), (0.42, 0.32, 0.80, 2, 0.90, 0.07), (0.62, 0.30, 0.60, 1, 0.65, 0.10),
    ]

    /// How high the crown's edge stands at `u` at `phase` (0 to 2π), 0…1 of its reach: the tallest lick there. Each lick
    /// shoots up fast (the first third of its flare), narrowing to a point, and sinks back slower into the body, leaning out
    /// a little as it goes; they flare out of step, so the edge is always spiky and never the same twice. With `jag` low the
    /// licks are rounder and barely flare: a slow breathing, but still a row of soft upward points in every frame,
    /// never a flat or hollow top: each lick keeps a higher floor and stays narrow enough to show its own peak.
    static func crownAt(_ u: Double, jag: Double, phase: Double) -> Double {
        var top = 0.0
        let pointed = max(smooth(0.3, 0.9, jag), 0.6), floor = 0.25 + 0.46 * (1 - jag)
        for lick in licks {
            let life = (phase / (2 * Double.pi) * lick.turns + lick.start).truncatingRemainder(dividingBy: 1)
            let flare = life < 0.35 ? smooth(0, 0.35, life) : 1 - smooth(0.35, 1, life)
            let half = lick.half * (1.25 - 0.45 * flare * jag) * (1 + 0.35 * (1 - jag))
            let d = abs(u - lick.u - lick.lean * life) / half
            guard d < 1 else { continue }
            let profile = pointed * pow(1 - d, 1.3) + (1 - pointed) * (0.5 + 0.5 * cos(Double.pi * d))
            top = max(top, lick.high * (floor + (1 - floor) * flare) * profile)
        }
        return top
    }

    /// The envelope's alpha at (u across, −1…1; v up, 0…1) at `phase` of its loop (0 to 2π; the loop closes): one soft egg
    /// round the body, a little wider than it (busy a touch more), widest at the shoulders and tapering gently to the feet,
    /// its sides wavering a little with waves running up; over the head one crown of overlapping licks (`crownAt`) flaring
    /// up and sinking back out of step, whose tallest reaches `Look.crown` over the head, the whole edge one shape that
    /// flares and shifts as a body. Soft at the edge, open at the top, down to the feet.
    static func envelopeAlpha(_ u: Double, _ v: Double, busy: Bool, phase: Double = 0) -> Double {
        let pet = petIn(busy: busy), head = pet.head, look = look(busy: busy)
        let s = max(0, v / head)
        let shape = s < 0.62 ? 0.72 + 0.28 * sin(Double.pi / 2 * s / 0.62) : sqrt(max(0, 1 - pow((s - 0.62) / 0.42, 2)))
        let wave1: Double = 0.035 * sin(6.3 * v - phase), wave2: Double = 0.025 * sin(11 * v - 2 * phase + 1)
        let waver: Double = 1 + look.jag * (wave1 + wave2)
        let eggHalf: Double = pet.half * (busy ? 1.03 : 1.0) * shape * waver
        // Soft but close: full to the body's own edge, gone a little past it (about a tenth of the pet's width), a little
        // ragged.
        let inner = 0.88 + 0.02 * sin(v * 47 - phase), outer = 1.16 + 0.02 * sin(u * 31 + v * 13 - phase)
        var light = eggHalf > 0.001 ? 1 - smooth(inner, outer, abs(u) / eggHalf) : 0
        // The crown, from a little under the head's top; rounded off at the shoulders, so it grows out of the egg.
        let span = pet.half, base = head * 0.8
        let reach = (1 - Double(envelopeOver) / Double(1 + look.crown + envelopeOver)) - base  // up to the tallest lick's tip
        let acrossDrop = max(0, 1 - 0.55 * pow(abs(u) / span, 2))
        let topAt = base + reach * min(1, 0.22 + 0.87 * crownAt(u, jag: look.jag, phase: phase)) * acrossDrop
        if v >= base - 0.03 {
            let soft = 0.035 + 0.05 * (1 - look.jag)
            let crown = (1 - smooth(topAt - soft, topAt + 0.005, v)) * (1 - smooth(span * 0.62, span * 0.92, abs(u)))
            light = max(light, crown)
        }
        // Down to the feet (the picture's bottom): the egg's sides already there at the ankles, only the last few
        // rows softening into the pool under the feet.
        light *= smooth(-0.04, 0.03, v)
        return max(0, min(1, light))
    }

    /// A state's envelope picture at a frame of its loop: the fire's mask (alpha only), or its tint (`coloured`: orange at
    /// the edge, gold inside; `under`: the same grade for the orange laid under the fire, its alpha falling off sooner, so it
    /// ends well inside the fire's soft edge and the two read as one mass): soft, 2 pixels a point at a usual pet's size.
    static func envelope(busy: Bool, frame: Int = 0, coloured: Bool = false, under: Bool = false) -> CGImage? {
        let key = (busy ? 1 : 0) + (coloured ? 2 : 0) + (under ? 4 : 0) + frame * 8
        if let done = envelopeCache[key] { return done }
        let width = 220, height = busy ? 300 : 250
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = canvas.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        func channel(_ hex: UInt32, _ shift: UInt32) -> Double { Double((hex >> shift) & 0xFF) }
        let phase = 2 * Double.pi * Double(frame) / Double(outlineFrames)
        for row in 0..<height {
            let v = 1 - (Double(row) + 0.5) / Double(height)
            for col in 0..<width {
                let u = (Double(col) + 0.5) / Double(width) * 2 - 1
                let a = envelopeAlpha(u, v, busy: busy, phase: phase), i = (row * width + col) * 4
                if coloured {
                    let t = smooth(0.2, 0.9, a), alpha = under ? pow(a, 1.7) : a
                    for (c, shift) in [UInt32(16), 8, 0].enumerated() {
                        data[i + c] = UInt8((channel(amber, shift) + (channel(gold, shift) - channel(amber, shift)) * t) * alpha)
                    }
                    data[i + 3] = UInt8(255 * alpha)
                } else {
                    let b = UInt8(255 * a)
                    data[i] = b; data[i + 1] = b; data[i + 2] = b; data[i + 3] = b
                }
            }
        }
        let image = canvas.makeImage()
        envelopeCache[key] = image
        return image
    }

    static func envelopeTint(busy: Bool, under: Bool = false) -> CGImage? { envelope(busy: busy, coloured: true, under: under) }

    private static var frameCache: [Bool: [CGImage]] = [:]

    /// The outline loop: `outlineFrames` masks of a state's envelope, one turn of the phase, made once.
    static func envelopeFrames(busy: Bool) -> [CGImage] {
        if let done = frameCache[busy] { return done }
        let made = (0..<outlineFrames).compactMap { envelope(busy: busy, frame: $0) }
        frameCache[busy] = made
        return made
    }

    /// The flame texture's alpha at (u across, −1…1; v up, 0…1), seamless top to bottom: wisps and licks of light, a few
    /// waves of whole periods in v laid over each other, each bent across by u, so rising they wind and part.
    static func flowAlpha(_ u: Double, _ v: Double, _ k: Int) -> Double {
        let pi2 = 2 * Double.pi
        var sum = 0.0, weight = 0.0
        // Few periods up the tile and more across: tall wisps, not blobs.
        let waves: [(m: Double, a: Double, p: Double, q: Double, r: Double, w: Double)] = k == 0
            ? [(3, 2.3, 1.2, 1.1, 1, 1), (5, -1.7, 0.9, 1.6, 2, 0.8), (2, 3.1, 1.5, 0.7, 3, 0.7), (7, 0.9, 0.5, 2.4, 1, 0.4)]
            : [(2, -2.7, 1.4, 0.9, 1, 1), (4, 1.9, 1.0, 1.3, 2, 0.8), (6, -1.1, 0.6, 2.0, 3, 0.4)]
        for wave in waves {
            // m whole periods up the tile; bent across by a·u and by a wave in u (and whole periods r in v) of strength p.
            let bend = wave.p * sin(pi2 * (u * wave.q + v * wave.r))
            sum += wave.w * (0.5 + 0.5 * sin(pi2 * (wave.m * v + wave.a * u) + bend))
            weight += wave.w
        }
        let n = sum / weight
        // Thinner at the sides, so the licks sit in the middle of the fire; soft threshold, so there are holes between them.
        let across = 1 - 0.35 * u * u
        return smooth(0.5, 0.78, n * across)  // a narrow threshold: wisps with readable edges
    }

    /// A texture's picture, three tiles stacked (a scrolling layer shows one tile's height and travels one tile a loop):
    /// deep amber at the edge of each wisp, orange, gold in its middle; no white (that is for the band at the pet's edge).
    /// `busy`: a higher floor of light between the wisps, so the fire is dense, not holey; idle keeps the lower floor.
    static func flowTiles(_ k: Int, busy: Bool = false) -> CGImage? {
        let key = k + (busy ? 2 : 0)
        if let done = flowCache[key] { return done }
        let floor = busy ? 0.32 : 0.1
        let width = 128, tile = 256, height = tile * 3
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = canvas.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> (Double, Double, Double) {
            func c(_ x: UInt32, _ s: UInt32) -> Double { Double((x >> s) & 0xFF) }
            return (c(a, 16) + (c(b, 16) - c(a, 16)) * t, c(a, 8) + (c(b, 8) - c(a, 8)) * t, c(a, 0) + (c(b, 0) - c(a, 0)) * t)
        }
        for row in 0..<tile {
            let v = 1 - (Double(row) + 0.5) / Double(tile)
            for col in 0..<width {
                let u = (Double(col) + 0.5) / Double(width) * 2 - 1
                let a = floor + (1 - floor) * flowAlpha(u, v, k)  // a floor of light, so the envelope always reads; the wisps over it
                var rgb = mix(ember, amber, smooth(0.1, 0.45, a))
                if a > 0.45 { rgb = mix(amber, gold, smooth(0.45, 0.9, a)) }
                for copy in 0..<3 {
                    let i = ((row + copy * tile) * width + col) * 4
                    data[i] = UInt8(rgb.0 * a)
                    data[i + 1] = UInt8(rgb.1 * a)
                    data[i + 2] = UInt8(rgb.2 * a)
                    data[i + 3] = UInt8(255 * a)
                }
            }
        }
        let image = canvas.makeImage()
        flowCache[key] = image
        return image
    }

    /// The rim's ripple: three tiles of soft bands of gold light travelling up the rim's picture (cut to it).
    static let rippleTiles: CGImage? = {
        let width = 16, tile = 128, height = tile * 3
        guard let canvas = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = canvas.data?.assumingMemoryBound(to: UInt8.self)
        else { return nil }
        for row in 0..<tile {
            let v = Double(row) / Double(tile)
            for col in 0..<width {
                let u = (Double(col) + 0.5) / Double(width) * 2 - 1
                // Two bands a tile, leaning a little, each a soft hump.
                let a = 0.55 * pow(0.5 + 0.5 * sin(2 * Double.pi * (2 * v + 0.08 * u)), 2.2)
                for copy in 0..<3 {
                    let i = ((row + copy * tile) * width + col) * 4
                    data[i] = UInt8(255 * a); data[i + 1] = UInt8(199 * a); data[i + 2] = UInt8(44 * a); data[i + 3] = UInt8(255 * a)
                }
            }
        }
        return canvas.makeImage()
    }()

    /// one lightning tree, drawn on a pet frame's silhouette: its white-to-pale-cyan core (`core`) and its blurred
    /// cyan-to-blue glow (`glow`), stretched over the same box; where it lies on the frame (`rect`, in the frame's pixels from
    /// the top left) and its channels there (`lines`: the trunk, then its branches, every level), also in the frame's pixels.
    struct BoltPicture {
        let core: CGImage, glow: CGImage
        let rect: CGRect
        let lines: [[CGPoint]]
    }
    /// The trees a frame gets: `boltFamilies` trunks, each in `boltVariants` re-strikes (the same trunk, its branches
    /// re-rolled), picture `family * boltVariants + variant`. Families 0–3: the main trees; 4–5: small ones; 6–7: strikes,
    /// from the top of the head down one side to the feet.
    static let boltFamilies = 8, boltVariants = 3
    static let boltPictureCount = boltFamilies * boltVariants
    static let boltMain = 0..<4, boltSmall = 4..<6, boltStrike = 6..<8
    /// Picture pixels a point: the crisp core's and the blurred glow's.
    static let boltPixelsPerPoint: CGFloat = 3, boltGlowPixelsPerPoint: CGFloat = 1.5
    /// In points: the trunk's width at its origin and at its tip; the finest a branch's tip may be.
    static let boltTrunk: CGFloat = 2.2, boltTip: CGFloat = 0.8, boltFilament: CGFloat = 0.5
    /// The glow's colours (#8FE3FF near the channel, #3AA0FF further out) and the core's tint at its tips.
    static let arcGlowCyan: UInt32 = 0x8FE3FF, arcPale: UInt32 = 0xC4F1FF
    /// How far a tree may reach: inside the body's drawn box grown to 1.08 times its width and height.
    static let boltReach: CGFloat = 1.08

    /// The lightning's trees for a pet frame shown `pointsHigh` points tall (drawn once a frame and size), like a photo's:
    /// one thick blinding trunk, irregular at every scale (a coarse path kept on the body, then recursive midpoint
    /// displacement, each offset 0.28× its segment), tapering 2.2 → 0.8 pt from its origin; three to six branches leaving it
    /// at 20–45°, 25–50% of the trunk still ahead, each with branches of its own, three levels deep, each level 0.55× as wide
    /// and 0.6× as bright, ending in filaments ≤ 0.6 pt; the glow strong round the trunk only. Main trees start on the
    /// silhouette up in the hair or at a shoulder and run down over the body 0.4–0.8 body heights; small ones 0.28–0.42;
    /// strikes run from the top of the head down one side to the feet. Nothing leaves the body (grown a little) or its
    /// 1.08× box.
    static func boltPictures(for sprite: CGImage, pointsHigh: CGFloat) -> [BoltPicture] { boltArt(for: sprite, pointsHigh: pointsHigh).trees }
    /// the crawling arcs' brushes for a frame shown `pointsHigh` points tall (`brushCount`, drawn with its trees): short
    /// jagged bolts with tiny forks, 0.10–0.22 body heights long, lying along x and centred on their own origin, all in one
    /// box (`rect`, centred on 0) so a layer showing one is centred on the spot it is put.
    static func arcBrushes(for sprite: CGImage, pointsHigh: CGFloat) -> [BoltPicture] { boltArt(for: sprite, pointsHigh: pointsHigh).arcs }
    /// a point on a frame's outer outline (picture pixels, rows from the top), the outline's direction there (radians,
    /// y down) and which way is out.
    struct RimPoint { let point: CGPoint; let angle: Double; let normal: CGVector }
    /// `perimeterPoints` points spread evenly round a frame's outer outline: each row's leftmost and rightmost pixel and
    /// each column's topmost (the sides, shoulders, hair, legs and feet; never the face inside), in turn round the body.
    static func perimeter(for sprite: CGImage, pointsHigh: CGFloat) -> [RimPoint] { boltArt(for: sprite, pointsHigh: pointsHigh).rim }
    private static func boltArt(for sprite: CGImage, pointsHigh: CGFloat) -> (trees: [BoltPicture], arcs: [BoltPicture], rim: [RimPoint]) {
        let id = ObjectIdentifier(sprite), bucket = Int(pointsHigh.rounded())
        if let known = boltCache[id], known.image === sprite, known.bucket == bucket { return (known.pictures, known.arcs, known.rim) }
        guard pointsHigh > 0, let box = drawnBox(sprite)?.rect, let a = alpha(sprite, scale: 1, pad: 0) else { return ([], [], []) }
        let w = a.width, h = a.height, H = Double(box.height)
        func at(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= w || y >= h ? 0 : a.values[y * w + x] }
        let near = blur(a.values.map { $0 > 0.3 ? Float(1) : 0 }, w, h, max(1, Int((0.03 * H).rounded())))
        let limit = box.insetBy(dx: -box.width * (boltReach - 1) / 2, dy: -box.height * (boltReach - 1) / 2)
        // Branches may stray a little further off the body than the trunk (still inside the 1.08× box).
        let loose = blur(a.values.map { $0 > 0.3 ? Float(1) : 0 }, w, h, max(1, Int((0.05 * H).rounded())))
        // The trees wrap round the body, skirting its outline: how deep inside it a point is (the body blurred 0.06
        // body heights: 1 deep inside, 0.5 at the edge). In the head's half nothing goes deeper than its outline's band (never
        // over the face); below it the trunk keeps near the outline too, the branches may cross.
        let inside = blur(a.values.map { $0 > 0.3 ? Float(1) : 0 }, w, h, max(1, Int((0.06 * H).rounded())))
        let headLine = Int(box.minY + 0.5 * box.height)
        var branching = false, free = false
        func keep(_ p: CGPoint) -> Bool {
            if free { return true }
            let x = Int(p.x), y = Int(p.y)
            guard x >= 0 && y >= 0 && x < w && y < h && (branching ? loose : near)[y * w + x] > 0.06 && limit.contains(p) else { return false }
            return inside[y * w + x] < (y < headLine ? 0.62 : branching ? 1.01 : 0.8)
        }
        var edge: [CGPoint] = [], upper: [CGPoint] = [], lower: [CGPoint] = [], inner: [CGPoint] = []
        for y in 0..<h {
            for x in 0..<w where at(x, y) > 0.3 {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if at(x - 1, y) <= 0.3 || at(x + 1, y) <= 0.3 || at(x, y - 1) <= 0.3 || at(x, y + 1) <= 0.3 {
                    edge.append(p)
                    if p.y < box.minY + 0.3 * box.height { upper.append(p) } else if p.y > box.minY + 0.45 * box.height { lower.append(p) }
                } else if at(x - 2, y) > 0.3 && at(x + 2, y) > 0.3 && at(x, y - 2) > 0.3 && at(x, y + 2) > 0.3 {
                    inner.append(p)
                }
            }
        }
        guard !edge.isEmpty, !upper.isEmpty, !lower.isEmpty else { return ([], [], []) }
        // the outer silhouette, row by row: its leftmost and rightmost pixel.
        var leftX = [Int?](repeating: nil, count: h), rightX = [Int?](repeating: nil, count: h)
        for y in 0..<h {
            leftX[y] = (0..<w).first { at($0, y) > 0.3 }
            rightX[y] = (0..<w).last { at($0, y) > 0.3 }
        }
        var seed: UInt64 = 0x5EED_B017 ^ UInt64(w * 7919 + h * 131 + Int(box.minY))
        func random() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        func pick(_ list: [CGPoint]) -> CGPoint { list[min(list.count - 1, Int(random() * Double(list.count)))] }
        func dist(_ p: CGPoint, _ q: CGPoint) -> Double { hypot(q.x - p.x, q.y - p.y) }
        let perPoint = CGFloat(H) / pointsHigh  // frame pixels a point
        // Recursive midpoint displacement: every segment longer than 0.7 pt split at its middle, pushed sideways by up to
        // `rough` times its length (back to the middle where that would leave the body), `levels` times over.
        func displace(_ line: [CGPoint], levels: Int, rough: Double) -> [CGPoint] {
            var points = line
            for level in 0..<levels {
                // Coarse kinks sharper than the fine ones.
                let rough = rough * (level < 2 ? 1.35 : 1)
                var out = [points[0]]
                for (p, q) in zip(points, points.dropFirst()) {
                    let l = dist(p, q)
                    if l > 0.7 * perPoint {
                        let d = (random() * 2 - 1) * rough * l
                        var m = CGPoint(x: (p.x + q.x) / 2 - (q.y - p.y) / l * d, y: (p.y + q.y) / 2 + (q.x - p.x) / l * d)
                        if !keep(m) { m = CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2) }
                        out.append(m)
                    }
                    out.append(q)
                }
                points = out
            }
            return points
        }
        func lengths(_ line: [CGPoint]) -> [Double] {
            var run = [0.0]
            for (p, q) in zip(line, line.dropFirst()) { run.append(run.last! + dist(p, q)) }
            return run
        }
        // A channel: its points, its width at its start and its end (points), its brightness, its level (0: the trunk).
        struct Channel { var points: [CGPoint]; var w0: CGFloat; var w1: CGFloat; var bright: CGFloat; var level: Int }
        // A coarse path from `start` to `end` kept on the body: legs of about 0.13 body heights, each aimed at the end and
        // turned off it a little.
        func walk(_ start: CGPoint, _ end: CGPoint) -> [CGPoint]? {
            let legs = max(3, Int(dist(start, end) / (H * 0.11)))
            var p = start, line = [start], side: Double = random() < 0.5 ? 1 : -1
            for leg in 1..<legs {
                let aim = atan2(end.y - p.y, end.x - p.x), step = dist(p, end) / Double(legs - leg + 1) * (0.8 + 0.4 * random())
                if random() < 0.7 { side = -side }
                var found: CGPoint?
                for tryTurn in 0..<5 {
                    let turn = tryTurn == 4 ? 0 : side * (0.3 + 0.45 * random())
                    let q = CGPoint(x: p.x + cos(aim + turn) * step, y: p.y + sin(aim + turn) * step)
                    if keep(q) && keep(CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2)) { found = q; break }
                    side = -side
                }
                guard let q = found else { return nil }
                line.append(q)
                p = q
            }
            line.append(end)
            return line
        }
        // A strike's coarse path: from the top of the head down the silhouette's outer edge on one side to the feet.
        func strikePath() -> [CGPoint]? {
            let left = random() < 0.5
            var line: [CGPoint] = []
            let rows = 6
            for i in 0...rows {
                // From the side of the head (outside the face) down the outline to the feet.
                let f = i == 0 ? 0.1 : i == rows ? 0.985 : 0.1 + 0.9 * (Double(i) + (random() - 0.5) * 0.5) / Double(rows)
                let y = Int(Double(box.minY) + f * H)
                let xs = (0..<w).filter { at($0, y) > 0.3 }
                guard let x = left ? xs.first : xs.last else { continue }
                let inset = (Double(y) < Double(headLine) ? -0.01 * H + 0.015 * H * random() : 0.005 * H + 0.02 * H * random()) * (left ? 1 : -1)
                line.append(CGPoint(x: Double(x) + 0.5 + inset, y: Double(y) + 0.5))
            }
            return line.count >= 4 && line.allSatisfy(keep) ? line : nil
        }
        // a coarse path along the outer silhouette: from `f0` of the body's height down (or `up`) its left (or right)
        // edge, `length` frame pixels along it, a point every `spacing`, each set in from the edge by `inset()`.
        func sidePath(left: Bool, from f0: Double, up: Bool, length: Double, spacing: Double, inset: () -> Double) -> [CGPoint]? {
            // Set in from the edge, less where that would leave the outline's band (in the hair) or the body.
            func moved(_ p: CGPoint) -> CGPoint? {
                let d = inset() * (Int(p.y) < headLine ? 0.4 : 1)
                for k in [1.0, 0.5, 0] {
                    let q = CGPoint(x: p.x + (left ? 1 : -1) * d * k, y: p.y)
                    if keep(q) { return q }
                }
                return nil
            }
            var y = Int(Double(box.minY) + f0 * H), raw: [CGPoint] = [], run = 0.0
            while y >= Int(box.minY) && y < Int(box.maxY) {
                if let x = left ? leftX[y] : rightX[y] {
                    let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                    if let q = raw.last { run += dist(p, q) }
                    raw.append(p)
                    if run >= length { break }
                }
                y += up ? -1 : 1
            }
            guard run >= length * 0.85, let end = raw.last else { return nil }
            var out = [raw[0]], since = 0.0
            for (p, q) in zip(raw, raw.dropFirst()) {
                since += dist(p, q)
                if since >= spacing { out.append(q); since = 0 }
            }
            if out.last != end { out.append(end) }
            let set = out.compactMap(moved)
            return set.count == out.count ? set : nil
        }
        // which way is out for the tree being grown (-1 left, 1 right, 0 either), and whether it is an arc (one level of
        // a few tiny branches).
        var outward: CGFloat = 0, twig = false
        // The branches off `parent`, recursively, three levels under the trunk.
        func grow(_ parent: Channel, _ out: inout [Channel]) {
            guard parent.level < (twig ? 1 : 3), parent.points.count > 3 else { return }
            let run = lengths(parent.points), total = run.last!
            let count = twig ? Int(random() * 3) : parent.level == 0 ? 3 + Int(random() * 4) : parent.level == 1 ? 1 + Int(random() * 3) : 1 + Int(random() * 2)
            for _ in 0..<count {
                let s = 0.1 + 0.7 * random(), want = s * total
                guard let i = run.firstIndex(where: { $0 >= want }), i > 0 else { continue }
                let i0 = max(0, i - 3), i1 = min(parent.points.count - 1, i + 3)
                let p = parent.points[i], heading = atan2(parent.points[i1].y - parent.points[i0].y, parent.points[i1].x - parent.points[i0].x)
                let length = total * (1 - s) * (0.25 + 0.25 * random())
                guard length > (twig ? 0.9 : 1.6) * Double(perPoint) else { continue }
                var turn = (random() < 0.5 ? -1.0 : 1.0) * (20 + 25 * random()) * Double.pi / 180
                // mostly outward (or along the edge), off a tree that follows the outline.
                if outward != 0, random() < 0.8, cos(heading + turn) * outward < cos(heading - turn) * outward { turn = -turn }
                let end = CGPoint(x: p.x + cos(heading + turn) * length, y: p.y + sin(heading + turn) * length)
                let bend = CGPoint(x: (p.x + end.x) / 2 + (random() - 0.5) * 0.3 * length, y: (p.y + end.y) / 2 + (random() - 0.5) * 0.3 * length)
                branching = true
                var points = displace([p, bend, end], levels: 4, rough: 0.3)
                branching = false
                if let out = points.firstIndex(where: { !keep($0) }) { points = Array(points.prefix(out)) }
                guard points.count >= 3, dist(points[0], points.last!) > (twig ? 0.7 : 1.2) * Double(perPoint) else { continue }
                let wAt = parent.w0 + (parent.w1 - parent.w0) * CGFloat(s)
                let w0 = wAt * 0.55, w1 = min(boltFilament, w0 * 0.45)
                let child = Channel(points: points, w0: w0, w1: w1, bright: parent.bright * 0.6, level: parent.level + 1)
                out.append(child)
                grow(child, &out)
            }
        }
        // The pictures: per pass, the channels' strokes into a bitmap; the glow's passes blurred and summed.
        func render(_ channels: [Channel], pad: CGFloat = 20 * perPoint, glowRef given: CGFloat? = nil, extent: CGSize? = nil) -> BoltPicture? {
            let glowRef = given ?? boltTrunk
            let all = channels.flatMap(\.points)
            var minX = (all.map(\.x).min() ?? 0) - pad, minY = (all.map(\.y).min() ?? 0) - pad
            var maxX = (all.map(\.x).max() ?? 0) + pad, maxY = (all.map(\.y).max() ?? 0) + pad
            // a brush's fixed box, centred on 0.
            if let extent { (minX, maxX, minY, maxY) = (-extent.width / 2, extent.width / 2, -extent.height / 2, extent.height / 2) }
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            func canvas(_ px: CGFloat) -> (CGContext, Int, Int)? {
                let pw = Int(ceil(rect.width / perPoint * px)), ph = Int(ceil(rect.height / perPoint * px))
                guard pw > 0, ph > 0, let c = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw * 4,
                                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                c.setLineCap(.round)
                c.setLineJoin(.round)
                return (c, pw, ph)
            }
            // Each channel's segments, `width(w, s)` picture pixels wide in `colour(w, s, level)` (w: its local width in
            // points, s: how far along it, 0…1).
            func strokes(_ c: CGContext, _ px: CGFloat, _ ph: Int, _ only: (Channel) -> Bool, width: (CGFloat) -> CGFloat,
                         colour: (CGFloat, CGFloat, Channel) -> CGColor) {
                let k = px / perPoint
                func pixel(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - minX) * k, y: CGFloat(ph) - (p.y - minY) * k) }
                for ch in channels.reversed() where only(ch) {
                    let run = lengths(ch.points), total = max(run.last!, 0.001)
                    for i in 1..<ch.points.count {
                        let s = CGFloat((run[i - 1] + run[i]) / 2 / total)
                        // The trunk grows out of a point over its first 7%, not from a blunt cap.
                        let lw = (ch.w1 + (ch.w0 - ch.w1) * pow(1 - s, 1.4)) * (ch.level == 0 ? max(0.45, min(1, s / 0.07)) : 1)
                        c.setStrokeColor(colour(lw, s, ch))
                        c.setLineWidth(max(0.35 * px, width(lw) * px))
                        c.move(to: pixel(ch.points[i - 1]))
                        c.addLine(to: pixel(ch.points[i]))
                        c.strokePath()
                    }
                }
            }
            // The core: each channel opaque in its own layer (no beads where its segments overlap), at its brightness;
            // white at the trunk's origin, paler cyan along it and on the finer levels.
            guard let coreCanvas = canvas(boltPixelsPerPoint) else { return nil }
            let (cc, _, ch) = coreCanvas
            for channel in channels.reversed() {
                cc.saveGState()
                cc.setAlpha(channel.bright)
                cc.beginTransparencyLayer(auxiliaryInfo: nil)
                strokes(cc, boltPixelsPerPoint, ch, { $0.points == channel.points }, width: { $0 }) { _, s, c in
                    let t = min(1, s * 0.75 + CGFloat(c.level) * 0.3)
                    return CGColor(srgbRed: 1 - t * 0.23, green: 1 - t * 0.055, blue: 1, alpha: 1)
                }
                cc.endTransparencyLayer()
                cc.restoreGState()
            }
            guard let core = cc.makeImage() else { return nil }
            // The glow, at a coarser grain: a tight white bloom on the trunk and first branches, the cyan glow and the
            // deeper blue one round every channel by its width (so the trunk's is the strong one), a faint wide halo round
            // the trunk alone.
            let gpx = boltGlowPixelsPerPoint
            guard let glowCanvas = canvas(gpx) else { return nil }
            let (_, gw, gh) = glowCanvas
            var sum = [Float](repeating: 0, count: gw * gh * 4)
            func pass(blurPoints: CGFloat, _ only: @escaping (Channel) -> Bool, width: (CGFloat) -> CGFloat, rgb: UInt32, alpha: @escaping (CGFloat) -> CGFloat) {
                guard let c = canvas(gpx)?.0, let data = c.data else { return }
                let r = CGFloat((rgb >> 16) & 0xFF) / 255, g = CGFloat((rgb >> 8) & 0xFF) / 255, b = CGFloat(rgb & 0xFF) / 255
                strokes(c, gpx, gh, only, width: width) { lw, _, ch in
                    CGColor(srgbRed: r, green: g, blue: b, alpha: min(1, alpha(lw) * ch.bright))
                }
                let bytes = data.bindMemory(to: UInt8.self, capacity: gw * gh * 4)
                let radius = max(1, Int((blurPoints * gpx).rounded()))
                for channel in 0..<4 {
                    let plane = blur((0..<(gw * gh)).map { Float(bytes[$0 * 4 + channel]) / 255 }, gw, gh, radius)
                    for i in 0..<(gw * gh) { sum[i * 4 + channel] += plane[i] }
                }
            }
            // an arc's glow measured by its own trunk (`glowRef`), so the thin arcs glow as strongly as a tree's trunk.
            pass(blurPoints: 7, { $0.level == 0 }, width: { _ in 3 }, rgb: arcDeep) { lw in 0.24 * lw / glowRef }
            pass(blurPoints: 3.6, { _ in true }, width: { $0 * 2.4 }, rgb: arcDeep) { lw in pow(lw / glowRef, 1.3) * 0.75 }
            pass(blurPoints: 2.4, { _ in true }, width: { $0 * 1.6 }, rgb: arcGlowCyan) { lw in pow(lw / glowRef, 1.5) * 0.95 }
            pass(blurPoints: 0.8, { $0.level <= 1 }, width: { $0 }, rgb: 0xE8FBFF) { lw in pow(lw / glowRef, 3) * 0.8 }
            var pixels = [UInt8](repeating: 0, count: gw * gh * 4)
            for i in 0..<(gw * gh) {
                let al = min(1, sum[i * 4 + 3])
                for c in 0..<3 { pixels[i * 4 + c] = UInt8(255 * min(al, sum[i * 4 + c])) }
                pixels[i * 4 + 3] = UInt8(255 * al)
            }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let glow = CGImage(width: gw, height: gh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: gw * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
            else { return nil }
            return BoltPicture(core: core, glow: glow, rect: rect, lines: channels.map(\.points))
        }
        var pictures: [BoltPicture] = [], byFamily: [[BoltPicture]] = []
        // the trees but the strikes follow the outer silhouette: each family from its own spot round it, the sides
        // taking turns (left, right, …), down or up its edge, 0.4–0.6 body heights (small ones 0.3–0.38).
        let along: [(left: Bool, from: Double, up: Bool)] = [(true, 0.26, false), (false, 0.3, false), (true, 0.86, true),
                                                            (false, 0.8, true), (true, 0.1, false), (false, 0.12, false)]
        for family in 0..<boltFamilies {
            let strike = boltStrike.contains(family), small = boltSmall.contains(family)
            var trunk: [CGPoint]?
            outward = 0
            for attempt in 0..<240 where trunk == nil {
                if strike {
                    trunk = strikePath()
                } else {
                    let spot = along[family % along.count], want = H * (small ? 0.3 + 0.08 * random() : 0.4 + 0.2 * random())
                    outward = spot.left ? -1 : 1
                    guard let path = sidePath(left: spot.left, from: spot.from + (random() - 0.5) * 0.08 + (attempt < 120 ? 0 : spot.up ? -0.12 : 0.12), up: spot.up, length: want,
                                              spacing: 0.07 * H, inset: { (0.012 + 0.018 * random()) * H }),
                          path.count >= 3, dist(path[0], path.last!) > 0.27 * H else { continue }
                    trunk = path
                }
            }
            guard let coarse = trunk else { byFamily.append([]); continue }
            let main = displace(coarse, levels: 6, rough: 0.28)
            let width: CGFloat = strike ? 1.1 : small ? 0.75 : 1
            let root = Channel(points: main, w0: boltTrunk * width, w1: boltTip * width, bright: 1, level: 0)
            let trunkSeed = seed
            var made: [BoltPicture] = []
            for variant in 0..<boltVariants {
                seed = trunkSeed ^ (UInt64(variant + 1) &* 0x9E37_79B9_7F4A_7C15)
                var channels = [root]
                grow(root, &channels)
                if let picture = render(channels) { made.append(picture) }
            }
            byFamily.append(made)
            seed = trunkSeed &+ 0x51
        }
        // a family that found no trunk borrows its mirror's trees (the other side's), else any family's, so every
        // picture number keeps its family.
        for family in 0..<boltFamilies {
            var own = byFamily[family]
            if own.isEmpty { own = !byFamily[family ^ 1].isEmpty ? byFamily[family ^ 1] : byFamily.first { !$0.isEmpty } ?? [] }
            guard !own.isEmpty else { continue }
            for variant in 0..<boltVariants { pictures.append(own[variant % own.count]) }
        }
        // the brushes: a bolt along x from -L/2 to L/2 (L 0.16–0.32 body heights), drawn anywhere (not kept on the body),
        // each in the same box centred on 0. A bolt, not a snake: 5–7 straight legs meeting at sharp kinks, only a little fine
        // jitter on them, a thin 1.1–1.4 pt trunk and a glow kept tight to it (thick, soft and wiggly read as a fire snake).
        var arcs: [BoltPicture] = []
        twig = true
        free = true
        outward = 0
        let brushBox = CGSize(width: 0.32 * H + 12 * Double(perPoint), height: 0.14 * H + 12 * Double(perPoint))
        for _ in 0..<brushCount {
            let half = H * (0.08 + 0.08 * random()), legs = 5 + Int(random() * 3)
            var coarse = [CGPoint(x: -half, y: 0)]
            for k in 1..<legs {
                let side: Double = k % 2 == 0 ? 1 : -1
                coarse.append(CGPoint(x: -half + 2 * half * (Double(k) + (random() - 0.5) * 0.5) / Double(legs),
                                      y: side * (0.08 + 0.22 * random()) * half))
            }
            coarse.append(CGPoint(x: half, y: (random() - 0.5) * 0.1 * half))
            let line = displace(coarse, levels: 2, rough: 0.12)
            let w0 = 1.1 + 0.3 * CGFloat(random())
            let root = Channel(points: line, w0: w0, w1: 0.5, bright: 1, level: 0)
            var channels = [root]
            grow(root, &channels)
            if let made = render(channels, glowRef: w0 * 1.1, extent: brushBox) { arcs.append(made) }
        }
        twig = false
        free = false
        // the outline: each row's leftmost and rightmost pixel, each column's topmost; out is down the body's blurred
        // alpha; then `perimeterPoints` of them, evenly by count, in turn round the box's middle.
        var onRim = Set<Int>()
        for y in Int(box.minY)..<Int(box.maxY) {
            if let x = leftX[y] { onRim.insert(y * w + x) }
            if let x = rightX[y] { onRim.insert(y * w + x) }
        }
        for x in Int(box.minX)..<Int(box.maxX) {
            if let y = (Int(box.minY)..<Int(box.maxY)).first(where: { at(x, $0) > 0.3 }) { onRim.insert(y * w + x) }
        }
        let centre = CGPoint(x: box.midX, y: box.minY + box.height * 0.55)
        // Half the points on each side of the body: up the left from the feet to the top of the head, then down the right,
        // so the perimeter's quarters are its left lower, left upper, right upper and right lower outline.
        func turnOf(_ p: CGPoint) -> Double { let a = atan2(p.y - centre.y, p.x - centre.x); return a < -Double.pi / 2 ? a + 2 * Double.pi : a }
        let all = onRim.map { CGPoint(x: Double($0 % w) + 0.5, y: Double($0 / w) + 0.5) }
        let halves = [all.filter { $0.x < centre.x }, all.filter { $0.x >= centre.x }].map { $0.sorted { turnOf($0) < turnOf($1) } }
        var rim: [RimPoint] = []
        if !halves[0].isEmpty, !halves[1].isEmpty {
            func depth(_ x: Int, _ y: Int) -> Float { x < 0 || y < 0 || x >= w || y >= h ? 0 : inside[y * w + x] }
            for i in 0..<perimeterPoints {
                let side = halves[i < perimeterPoints / 2 ? 0 : 1], j = i % (perimeterPoints / 2)
                let p = side[min(side.count - 1, Int((Double(j) + 0.5) * Double(side.count) / Double(perimeterPoints / 2)))]
                let x = Int(p.x), y = Int(p.y), r = 2
                var n = CGVector(dx: -Double(depth(x + r, y) - depth(x - r, y)), dy: -Double(depth(x, y + r) - depth(x, y - r)))
                let l = hypot(n.dx, n.dy)
                n = l > 1e-4 ? CGVector(dx: n.dx / l, dy: n.dy / l) : CGVector(dx: p.x < centre.x ? -1 : 1, dy: 0)
                // Two in five points are moved in onto the body (a strong one carries the lightning on it, not only
                // round it): along the inward normal, 12–30% of the body's width, kept off the face and on the sprite.
                var q = p
                if i % 5 == 1 || i % 5 == 3 {
                    let d = box.width * (0.12 + 0.18 * (Double(i) * 0.618).truncatingRemainder(dividingBy: 1))
                    let c = CGPoint(x: p.x - n.dx * d, y: p.y - n.dy * d)
                    let face = c.y > box.minY + box.height * 0.18 && c.y < box.minY + box.height * 0.5 && abs(c.x - box.midX) < box.width * 0.24
                    if !face, depth(Int(c.x), Int(c.y)) > 0.5 { q = c }
                }
                rim.append(RimPoint(point: q, angle: atan2(n.dy, n.dx) + Double.pi / 2, normal: n))
            }
        }
        if boltCache.count > 48 { boltCache.removeAll() }
        boltCache[id] = (sprite, bucket, pictures, arcs, rim)
        return (pictures, arcs, rim)
    }
    private static var boltCache: [ObjectIdentifier: (image: CGImage, bucket: Int, pictures: [BoltPicture], arcs: [BoltPicture], rim: [RimPoint])] = [:]

    /// A soft gold light, smooth: the wide glow round the aura (`round`, an oval) or the pool on the floor.
    static func glow(round: Bool) -> CGImage? {
        if let done = glowCache[round] { return done }
        let size = CGSize(width: 128, height: round ? 128 : 48)
        guard let canvas = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      colors: (round ? [OfficeCanvas.rgb(amber, 0.5), OfficeCanvas.rgb(ember, 0.2), OfficeCanvas.rgb(ember, 0)]
                                                     : [OfficeCanvas.rgb(gold, 0.75), OfficeCanvas.rgb(amber, 0.35), OfficeCanvas.rgb(ember, 0)]) as CFArray,
                                      locations: [0, 0.5, 1])
        else { return nil }
        canvas.scaleBy(x: 1, y: size.height / size.width)
        let c = CGPoint(x: size.width / 2, y: size.width / 2)
        canvas.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width / 2, options: [])
        let image = canvas.makeImage()
        glowCache[round] = image
        return image
    }
}
