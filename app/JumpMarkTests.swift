// Jump mark checks: the session's name as a fading watermark over the pane a jump lands on. Nothing here ships in the app.

import AppKit

@MainActor func jumpMarkTests() {
    // Off every screen, as the zone checks' own windows: a check never puts a window where the user can see it.
    let pane = CGRect(x: -6000, y: -6000, width: 900, height: 600)
    JumpMarkOverlay.calm = { false }
    JumpMarkOverlay.timingOverride = nil
    defer {
        JumpMarkOverlay.close()
        JumpMarkOverlay.calm = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        JumpMarkOverlay.timingOverride = nil
    }

    // The window.
    JumpMarkOverlay.show("Home-lead", over: pane)
    // Without a window the checks below run on a stand-in, so each says what is missing.
    let w = JumpMarkOverlay.current ?? NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
    check("jump mark: a window is shown", JumpMarkOverlay.current != nil)
    check("jump mark: click-through", w.ignoresMouseEvents)
    check("jump mark: never key, never main (does not take focus from Orca)", !w.canBecomeKey && !w.canBecomeMain)
    check("jump mark: borderless, non-activating", w.styleMask.contains(.nonactivatingPanel) && !w.styleMask.contains(.titled))
    check("jump mark: transparent", !w.isOpaque && w.backgroundColor.alphaComponent == 0 && !w.hasShadow)
    check("jump mark: above Orca's windows", w.level.rawValue > NSWindow.Level.normal.rawValue)
    check(
        "jump mark: on the active Space only, out of the window cycle",
        !w.collectionBehavior.contains(.canJoinAllSpaces) && w.collectionBehavior.contains(.ignoresCycle))
    check("jump mark: not released on close (kept by the overlay)", !w.isReleasedWhenClosed)

    // The text: the full name, the zone prefix with it.
    check("jump mark: says the full name", JumpMarkOverlay.shownText == "Home-lead")
    check("jump mark: a short name at 72 pt", JumpMark.fontSize("Home-lead", paneWidth: 900) == 72)
    let long = "AI-ML-童话小模型-云朵库检索"
    let longSize = JumpMark.fontSize(long, paneWidth: 900)
    let longWidth = JumpMark.textSize(long, fontSize: longSize).width
    check("jump mark: a long name shrinks below 72 pt", longSize < 72 && longSize >= 36)
    check("jump mark: a long name fits 80 % of the pane", longWidth <= 900 * 0.8 + 1)
    check("jump mark: never below 36 pt", JumpMark.fontSize(long + long + long, paneWidth: 300) == 36)

    // Where it sits: centred on the pane.
    let frame = w.frame
    check("jump mark: centred on the pane", abs(frame.midX - pane.midX) < 1 && abs(frame.midY - pane.midY) < 1)
    let centred = JumpMark.centred(CGSize(width: 200, height: 80), on: CGRect(x: 100, y: 50, width: 1000, height: 400))
    check("jump mark: centring sums", centred == CGRect(x: 500, y: 210, width: 200, height: 80))
    // AX and the window list give top-left screen points; a window wants bottom-left. A display left of the main one
    // (a window at a negative x) keeps its x.
    let flipped = JumpMark.flip(CGRect(x: -1920, y: -60, width: 1920, height: 1080), primaryHeight: 1200)
    check("jump mark: top-left to bottom-left, a display to the left", flipped == CGRect(x: -1920, y: 180, width: 1920, height: 1080))

    // Timing: hold 0.5 s, fade 2.5 s; Reduce Motion: hold 2 s, no fade.
    check("jump mark: timing (10-17: 10 s, then a 2.5 s fade)", JumpMark.timing(calm: false) == JumpMark.Timing(hold: 10, fade: 2.5))
    check("jump mark: timing with Reduce Motion: 10 s, no fade", JumpMark.timing(calm: true) == JumpMark.Timing(hold: 10, fade: 0))
    let fade = JumpMarkOverlay.textLayer?.animation(forKey: JumpMarkOverlay.fadeKey) as? CABasicAnimation
    check("jump mark: one opacity animation on the layer", fade?.keyPath == "opacity")
    check("jump mark: fades over 2.5 s", abs((fade?.duration ?? 0) - 2.5) < 0.001)
    check("jump mark: after 10 s at full", abs((fade?.beginTime ?? 0) - JumpMarkOverlay.shownAt - 10) < 0.05)
    check("jump mark: from full to nothing", (fade?.fromValue as? Double) == 1 && (fade?.toValue as? Double) == 0)
    check("jump mark: closes when the fade is done", abs((JumpMarkOverlay.closeAfter ?? 0) - 12.5) < 0.001)

    // 10-17: two lines, the zone over the name; the zone line smaller; one line when no zone.
    let two = JumpMark.textSize("Lab\nlead", fontSize: 72), one = JumpMark.textSize("lead", fontSize: 72)
    check("jump mark: zone over name is two lines, taller than one, no wider than the name line",
        two.height > one.height * 1.8 && two.width <= one.width + 2)
    var zc = ZoneConfig()
    zc.zones = [ZoneConfig.Zone(code: "Home", name: "Lab", color: nil, order: 3, lead: nil)]
    check("jump mark: label = zone name over the plate name", zc.resolve(name: "Home-lead", cwd: "").flatMap { c in zc.zones.first { $0.code == c } }.map { $0.name + "\n" + zc.plate("Home-lead") } == "Lab\nlead")

    // A second jump replaces it.
    let first = w
    JumpMarkOverlay.show("Ops-Demo-Helper", over: pane.offsetBy(dx: 100, dy: 0))
    check("jump mark: a second jump replaces the first", JumpMarkOverlay.current !== first && !first.isVisible)
    check("jump mark: the second says its own name", JumpMarkOverlay.shownText == "Ops-Demo-Helper")

    // Reduce Motion: no animation, closes after 2 s.
    JumpMarkOverlay.calm = { true }
    JumpMarkOverlay.show("Home-lead", over: pane)
    check("jump mark: Reduce Motion, no animation", JumpMarkOverlay.textLayer?.animation(forKey: JumpMarkOverlay.fadeKey) == nil)
    check("jump mark: Reduce Motion, full opacity", (JumpMarkOverlay.textLayer?.opacity ?? 0) == 1)
    check("jump mark: Reduce Motion, closes after 10 s", abs((JumpMarkOverlay.closeAfter ?? 0) - 10.0) < 0.001)
    JumpMarkOverlay.calm = { false }

    // It does close on its own, and the window goes.
    JumpMarkOverlay.timingOverride = JumpMark.Timing(hold: 0.05, fade: 0.1)
    JumpMarkOverlay.show("Home-lead", over: pane)
    let shown = JumpMarkOverlay.current
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    check("jump mark: closed after hold and fade", JumpMarkOverlay.current == nil && shown?.isVisible == false)
    // A replaced mark's close does not close the one after it.
    JumpMarkOverlay.show("A", over: pane)
    JumpMarkOverlay.timingOverride = JumpMark.Timing(hold: 5, fade: 5)
    JumpMarkOverlay.show("B", over: pane)
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    check("jump mark: the first's close leaves the second on", JumpMarkOverlay.current != nil && JumpMarkOverlay.shownText == "B")
    JumpMarkOverlay.close()
    JumpMarkOverlay.timingOverride = nil

    // When it shows at all: only a jump that went, and only with a frame.
    var presented: [(String, CGRect)] = []
    let present: (String, CGRect) -> Void = { presented.append(($0, $1)) }
    let some = CGRect(x: 10, y: 20, width: 800, height: 500)
    JumpMark.follow(outcome: "ok", name: "Home-lead", measure: { some }, present: present)
    check("jump mark: a jump that went is followed by its name over the frame", presented.count == 1 && presented.first?.0 == "Home-lead")
    for outcome in ["ok (handle refreshed)", "ok (via command line)", "ok (via url codex://threads/x)", "ok (via activate)"] {
        presented = []
        JumpMark.follow(outcome: outcome, name: "x", measure: { some }, present: present)
        check("jump mark: shown after \"\(outcome)\"", presented.count == 1)
    }
    var measured = 0
    for outcome in ["failed: refused", "this session was not started from Orca", "failed: Orca is not reachable", ""] {
        presented = []
        JumpMark.follow(outcome: outcome, name: "x", measure: { measured += 1; return some }, present: present)
        check("jump mark: nothing after \"\(outcome)\"", presented.isEmpty)
    }
    check("jump mark: a failed jump is not even measured", measured == 0)
    presented = []
    JumpMark.follow(outcome: "ok", name: "x", measure: { nil }, present: present)
    check("jump mark: nothing when no frame can be read", presented.isEmpty)
    presented = []
    JumpMark.follow(outcome: "ok", name: "x", measure: { CGRect(x: 0, y: 0, width: 0, height: 0) }, present: present)
    check("jump mark: nothing for an empty frame", presented.isEmpty)

    // The pane from Orca's focused element up: the xterm box when there is one; else the smallest pane-sized box under the
    // window; else the window; else nothing.
    let window = CGRect(x: 0, y: 25, width: 1800, height: 1000)
    let chain: [JumpMark.Box] = [
        .init(classes: ["xterm-helper-textarea"], frame: CGRect(x: 950, y: 600, width: 1, height: 1)),
        .init(classes: ["xterm-helpers"], frame: CGRect(x: 920, y: 80, width: 0, height: 0)),
        .init(classes: ["xterm", "focus"], frame: CGRect(x: 920, y: 80, width: 860, height: 920)),
        .init(classes: ["pane"], frame: CGRect(x: 910, y: 60, width: 880, height: 950)),
        .init(classes: ["split"], frame: CGRect(x: 240, y: 60, width: 1560, height: 950)),
        .init(classes: [], frame: window),
    ]
    check("jump mark: the focused pane is the xterm box", JumpMark.paneFrame(chain: chain, window: window) == chain[2].frame)
    let noClasses = chain.map { JumpMark.Box(classes: [], frame: $0.frame) }
    check(
        "jump mark: without classes, the smallest pane-sized box", JumpMark.paneFrame(chain: noClasses, window: window) == chain[2].frame)
    check(
        "jump mark: a shallow tree falls back to the window",
        JumpMark.paneFrame(chain: [.init(classes: [], frame: window)], window: window) == window)
    check("jump mark: nothing read falls back to the window", JumpMark.paneFrame(chain: [], window: window) == window)
    check("jump mark: no window and no pane is nothing", JumpMark.paneFrame(chain: [], window: nil) == nil)
    check(
        "jump mark: a box outside the window is not the pane",
        JumpMark.paneFrame(chain: [.init(classes: ["xterm"], frame: CGRect(x: 3000, y: 0, width: 800, height: 600))], window: window)
            == window)

    // Without the Accessibility permission: the app's front window from the window list (its first normal-layer window).
    let list: [[String: Any]] = [
        [kCGWindowOwnerPID as String: Int32(7), kCGWindowLayer as String: 25, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 300, "Height": 24]],
        [kCGWindowOwnerPID as String: Int32(9), kCGWindowLayer as String: 0, kCGWindowBounds as String: ["X": 5, "Y": 5, "Width": 500, "Height": 400]],
        [kCGWindowOwnerPID as String: Int32(7), kCGWindowLayer as String: 0, kCGWindowBounds as String: ["X": 2, "Y": 3, "Width": 40, "Height": 30]],
        [kCGWindowOwnerPID as String: Int32(7), kCGWindowLayer as String: 0, kCGWindowBounds as String: ["X": -1877, "Y": -67, "Width": 1876, "Height": 1050]],
        [kCGWindowOwnerPID as String: Int32(7), kCGWindowLayer as String: 0, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 900, "Height": 700]],
    ]
    check("jump mark: the front window from the list", JumpMark.frontWindow(in: list, pid: 7) == CGRect(x: -1877, y: -67, width: 1876, height: 1050))
    check("jump mark: no window of that app is nothing", JumpMark.frontWindow(in: list, pid: 8) == nil)

    // The jump path itself never puts one up in the checks.
    check("jump mark: the checks' jumps show nothing (not live)", !JumpMark.live)
}

/// `--jump-mark-still <dir>`: `jump-mark.png`, a sample Orca window (a dark pane and a light pane) with the watermark drawn over each
/// pane's centre at the same size and look the overlay uses (left: a short name; right: a long one, shrunk to fit).
@MainActor func jumpMarkStill(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let size = CGSize(width: 1600, height: 900)
    guard
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return }
    let gc = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    // The window: a title bar with tabs, a dark pane on the left, a light one on the right.
    NSColor(white: 0.16, alpha: 1).setFill()
    CGRect(origin: .zero, size: size).fill()
    NSColor(white: 0.22, alpha: 1).setFill()
    CGRect(x: 0, y: size.height - 44, width: size.width, height: 44).fill()
    let tabFont = NSFont.systemFont(ofSize: 13)
    for (i, t) in ["AI-SkyApp", "Home-lead", "Ops-Demo-Helper"].enumerated() {
        (t as NSString).draw(at: CGPoint(x: CGFloat(90 + i * 170), y: size.height - 30), withAttributes: [.font: tabFont, .foregroundColor: NSColor(white: 0.8, alpha: 1)])
    }
    let left = CGRect(x: 8, y: 8, width: size.width / 2 - 12, height: size.height - 60)
    let right = CGRect(x: size.width / 2 + 4, y: 8, width: size.width / 2 - 12, height: size.height - 60)
    NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1).setFill()
    left.fill()
    NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1).setFill()
    right.fill()
    let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let lines = [
        "$ claude --resume", "✳ 整理菜谱图片 …", "  photos/ 已按日期分好", "> 跳到会话：已聚焦 tab",
        "  ok    jump mark: centred on the pane", "  ok    jump mark: timing", "⏺ 下一步：生成缩略图",
        "$ bash test.sh | tail -1", "all passed", "$ ls /Users/demo/out", "tests-red.log  tests-full.log  jump-mark.png",
    ]
    for (pane, colour) in [(left, NSColor(red: 0.75, green: 0.85, blue: 0.75, alpha: 1)), (right, NSColor(white: 0.18, alpha: 1))] {
        for k in 0..<38 {
            let line = lines[k % lines.count]
            (line as NSString).draw(at: CGPoint(x: pane.minX + 14, y: pane.maxY - 26 - CGFloat(k) * 21), withAttributes: [.font: mono, .foregroundColor: colour])
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    // The watermarks, as the overlay makes them.
    for (name, pane) in [("Lab\nlead", left), ("Docs\nAI-童话模型-云朵检索服务", right)] {
        let points = JumpMark.fontSize(name, paneWidth: pane.width)
        let colour = name.hasPrefix("Lab") ? NSColor(srgbRed: 0xA0 / 255.0, green: 0x70 / 255.0, blue: 0xD0 / 255.0, alpha: 1)
            : NSColor(srgbRed: 0x50 / 255.0, green: 0x80 / 255.0, blue: 0xD0 / 255.0, alpha: 1)
        guard let mark = JumpMark.image(name, fontSize: points, scale: 1, zoneColor: colour) else { continue }
        ctx.draw(mark.image, in: JumpMark.centred(mark.size, on: pane))
        print("jump mark still: \(name) at \(Int(points)) pt over a \(Int(pane.width)) pt pane")
    }
    guard let image = ctx.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: dir + "/jump-mark.png"))
    print("jump mark still: wrote \(dir)/jump-mark.png")
}
