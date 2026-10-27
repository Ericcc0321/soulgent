// After a jump, the session's full name as a big watermark over the pane it landed on, fading out in a few seconds.
//
// The frame is measured after the jump has gone through (the focus call has returned, then 0.2 s), off the main thread:
//   1. with the Accessibility permission: from Orca's focused element up, the xterm box (else the smallest pane-sized box
//      inside the window); else its focused window;
//   2. without it, or when that reads nothing: the app's front window from the window list (needs no permission);
//   3. nothing read: no watermark.
// Codex / WorkBuddy sessions open in their own app: the same over that app's front window.

import AppKit
import ApplicationServices

enum JumpMark {
    struct Timing: Equatable {
        let hold: Double
        let fade: Double
        var total: Double { hold + fade }
    }
    /// An element on the way up from Orca's focused one: its page's classes and its frame (top-left screen points).
    struct Box {
        let classes: [String]
        let frame: CGRect?
    }

    static let points: CGFloat = 72
    static let minPoints: CGFloat = 36
    static let widthShare: CGFloat = 0.8
    /// How long after the focus call returns the frame is measured: Orca has moved its focus by then.
    static let settle: Double = 0.2
    /// An app opened by a link takes a moment longer to come forward.
    static let appSettle: Double = 0.4

    /// The real jump path puts one up; the checks' never do (they measure and show through the functions here instead).
    #if TESTING
        static var live = false
    #else
        static var live = true
    #endif

    static func timing(calm: Bool) -> Timing { calm ? Timing(hold: 10, fade: 0) : Timing(hold: 10, fade: 2.5) }  // 10-17: 10 s, then fade

    static func font(_ size: CGFloat) -> NSFont { NSFont.systemFont(ofSize: size, weight: .bold) }

    /// White at 85 % in a soft dark halo (a blurred shadow, drawn twice to thicken it), so it reads on light and dark
    /// terminals alike. No hard outline: on the strokes of CJK characters it looked hatched.
    static func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.7)
        shadow.shadowBlurRadius = max(4, size / 7)
        shadow.shadowOffset = .zero
        return [.font: font(size), .foregroundColor: NSColor(white: 1, alpha: 0.85), .shadow: shadow]
    }

    /// The zone line over the session line (10-17): "zone\nsession name", both the same size, the zone line in its zone's
    /// colour (a title bar for the team). One line is just the name.
    static let zoneShare: CGFloat = 1.0

    static func text(_ name: String, fontSize: CGFloat, halo: Bool = false, zoneColor: NSColor? = nil) -> NSAttributedString {
        let centre = NSMutableParagraphStyle()
        centre.alignment = .center
        let lines = name.components(separatedBy: "\n")
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let size = lines.count > 1 && i == 0 ? round(fontSize * zoneShare) : fontSize
            var a = attributes(size)
            a[.paragraphStyle] = centre
            if halo {
                a[.foregroundColor] = NSColor(white: 0, alpha: 0.35)
            } else if lines.count > 1 && i == 0, let zoneColor {
                a[.foregroundColor] = zoneColor
            }
            out.append(NSAttributedString(string: line + (i < lines.count - 1 ? "\n" : ""), attributes: a))
        }
        return out
    }

    static func textSize(_ name: String, fontSize: CGFloat) -> CGSize {
        let s = text(name, fontSize: fontSize).size()
        return CGSize(width: ceil(s.width), height: ceil(s.height))
    }

    /// The two lines a session's watermark says: its zone's name over its name without the zone prefix; just its name
    /// when it is in no zone.
    /// The zone colour for a two-line label's first line (the zone's name), from the workzones file.
    @MainActor static func zoneColor(of label: String) -> NSColor? {
        let lines = label.components(separatedBy: "\n")
        guard lines.count > 1, let hex = ZoneConfigFile.current().zones.first(where: { $0.name == lines[0] })?.color else { return nil }
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    @MainActor static func label(name: String, cwd: String) -> String {
        let config = ZoneConfigFile.current()
        guard let code = config.resolve(name: name, cwd: cwd), let zone = config.zones.first(where: { $0.code == code }) else { return name }
        return zone.name + "\n" + config.plate(name)
    }

    /// 72 pt, smaller for a long name so it fits 80 % of the pane's width, never under 36 pt.
    static func fontSize(_ name: String, paneWidth: CGFloat) -> CGFloat {
        let wide = textSize(name, fontSize: points).width
        guard wide > paneWidth * widthShare, wide > 0 else { return points }
        var size = max(minPoints, floor(points * paneWidth * widthShare / wide))
        // Text does not scale quite in proportion: step down until it fits.
        while size > minPoints, textSize(name, fontSize: size).width > paneWidth * widthShare { size -= 1 }
        return size
    }

    /// Top-left screen points (AX, the window list) to the bottom-left ones a window takes; `primaryHeight` is the height of
    /// the screen with the menu bar (`NSScreen.screens[0]`), whatever screen the frame is on.
    static func flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.minY - r.height, width: r.width, height: r.height)
    }

    static func centred(_ size: CGSize, on pane: CGRect) -> CGRect {
        CGRect(x: (pane.midX - size.width / 2).rounded(), y: (pane.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    /// The pane, from the focused element up: the first box of class `xterm`; else the smallest pane-sized box (240×120 or
    /// more) that is not the window itself; else the window; boxes outside the window do not count. Nil with neither.
    static func paneFrame(chain: [Box], window: CGRect?) -> CGRect? {
        func inside(_ r: CGRect) -> Bool { window.map { $0.insetBy(dx: -2, dy: -2).contains(r) } ?? true }
        let framed = chain.compactMap { box -> (classes: [String], frame: CGRect)? in
            guard let f = box.frame, f.width >= 1, f.height >= 1, inside(f) else { return nil }
            return (box.classes, f)
        }
        if let xterm = framed.first(where: { $0.classes.contains("xterm") && $0.frame.width >= 120 && $0.frame.height >= 60 }) {
            return xterm.frame
        }
        let panes = framed.map(\.frame).filter { f in f.width >= 240 && f.height >= 120 && window.map { f.size != $0.size } ?? true }
        if let smallest = panes.min(by: { $0.width * $0.height < $1.width * $1.height }) { return smallest }
        return window
    }

    /// The app's front window in the window list (front to back): its first normal-layer window of a real size.
    static func frontWindow(in list: [[String: Any]], pid: pid_t) -> CGRect? {
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid, (w[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary),
                r.width >= 100, r.height >= 100
            else { continue }
            return r
        }
        return nil
    }

    /// The watermark's picture: the name in the overlay's look, with room round it for the outline and shadow.
    static func image(_ name: String, fontSize: CGFloat, scale: CGFloat, zoneColor: NSColor? = nil) -> (image: CGImage, size: CGSize)? {
        let text = textSize(name, fontSize: fontSize)
        let pad = ceil(fontSize / 4)
        let size = CGSize(width: text.width + pad * 2, height: text.height + pad * 2)
        let px = (Int(size.width * scale), Int(size.height * scale))
        guard px.0 > 0, px.1 > 0,
            let ctx = CGContext(
                data: nil, width: px.0, height: px.1, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        // The halo twice, then the name once more on top at its own 85 %.
        let box = CGRect(x: pad, y: pad, width: text.width, height: text.height)
        for _ in 0..<2 { JumpMark.text(name, fontSize: fontSize, halo: true).draw(in: box) }
        JumpMark.text(name, fontSize: fontSize, zoneColor: zoneColor).draw(in: box)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage().map { ($0, size) }
    }

    /// After a jump: only one that went ("ok …"), and only with a frame of some size, is followed by the watermark.
    static func follow(outcome: String, name: String, measure: () -> CGRect?, present: (String, CGRect) -> Void) {
        guard outcome.hasPrefix("ok"), let frame = measure(), frame.width >= 1, frame.height >= 1 else { return }
        present(name, frame)
    }

    /// Called by `jump(to:)` on its background queue once the jump has an outcome. Measures after `settle`, shows on main.
    static func after(_ outcome: String, name: String, pid: @escaping () -> pid_t?, orca: Bool) {
        guard live, outcome.hasPrefix("ok") else { return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + (orca ? settle : appSettle)) {
            follow(outcome: outcome, name: name, measure: { pid().flatMap { measure(pid: $0, orca: orca) } }) { name, frame in
                DispatchQueue.main.async { MainActor.assumeIsolated { JumpMarkOverlay.show(name, overTopLeft: frame) } }
            }
        }
    }

    /// The frame to show over, top-left screen points: Orca's focused pane (else window) by AX; else the front window.
    static func measure(pid: pid_t, orca: Bool) -> CGRect? {
        if AXIsProcessTrusted(), let read = axFrame(pid: pid, pane: orca) { return read }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return frontWindow(in: list, pid: pid)
    }

    private static func axFrame(pid: pid_t, pane: Bool) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        func value(_ e: AXUIElement, _ name: String) -> CFTypeRef? {
            AXUIElementSetMessagingTimeout(e, 0.1)
            var v: CFTypeRef?
            return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
        }
        func element(_ v: CFTypeRef?) -> AXUIElement? {
            guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
            return (v as! AXUIElement)
        }
        func frame(_ e: AXUIElement) -> CGRect? {
            guard let p = value(e, kAXPositionAttribute), let s = value(e, kAXSizeAttribute),
                CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID()
            else { return nil }
            var point = CGPoint.zero, size = CGSize.zero
            AXValueGetValue(p as! AXValue, .cgPoint, &point)
            AXValueGetValue(s as! AXValue, .cgSize, &size)
            return CGRect(origin: point, size: size)
        }
        let window = element(value(app, kAXFocusedWindowAttribute)).flatMap(frame)
        guard pane else { return window }
        var chain: [Box] = []
        var at = element(value(app, kAXFocusedUIElementAttribute))
        // The page's tree is open to readers only while the office's light has it open (`OfficeFocus.enhance`); this never
        // opens it. A shallow tree gives no pane, and the window stands in.
        while let e = at, chain.count < 30 {
            if (value(e, kAXRoleAttribute) as? String) == (kAXWindowRole as String) { break }
            chain.append(Box(classes: value(e, "AXDOMClassList") as? [String] ?? [], frame: frame(e)))
            at = element(value(e, kAXParentAttribute))
        }
        return paneFrame(chain: chain, window: window)
    }
}

/// The overlay's window: never key or main, so Orca keeps the focus.
final class JumpMarkWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor enum JumpMarkOverlay {
    static let fadeKey = "jumpMark.fade"
    static var calm: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// For a check: shorter times.
    static var timingOverride: JumpMark.Timing?
    private(set) static var current: JumpMarkWindow?
    private(set) static var textLayer: CALayer?
    private(set) static var shownText = ""
    private(set) static var shownAt: CFTimeInterval = 0
    /// When the shown one closes, in seconds after it was shown.
    private(set) static var closeAfter: Double?
    private static var closing: DispatchWorkItem?

    /// Over a frame in top-left screen points (as measured).
    static func show(_ name: String, overTopLeft frame: CGRect) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        show(name, over: JumpMark.flip(frame, primaryHeight: primary))
    }

    /// Over a pane in window (bottom-left) points. A new one replaces the one showing.
    static func show(_ name: String, over pane: CGRect) {
        close()
        let screen = NSScreen.screens.first { $0.frame.intersects(pane) } ?? NSScreen.main
        let scale = screen?.backingScaleFactor ?? 2
        let points = JumpMark.fontSize(name, paneWidth: pane.width)
        guard let mark = JumpMark.image(name, fontSize: points, scale: scale, zoneColor: JumpMark.zoneColor(of: name)) else { return }
        let w = JumpMarkWindow(
            contentRect: JumpMark.centred(mark.size, on: pane), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .stationary, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.hidesOnDeactivate = false
        w.animationBehavior = .none
        let host = NSView(frame: CGRect(origin: .zero, size: mark.size))
        host.wantsLayer = true
        let layer = CALayer()
        layer.frame = host.bounds
        layer.contents = mark.image
        layer.contentsScale = scale
        host.layer?.addSublayer(layer)
        w.contentView = host

        let timing = timingOverride ?? JumpMark.timing(calm: calm())
        let now = CACurrentMediaTime()
        if timing.fade > 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.beginTime = now + timing.hold
            fade.duration = timing.fade
            fade.fillMode = .both
            fade.isRemovedOnCompletion = false
            layer.add(fade, forKey: fadeKey)
        }
        w.orderFrontRegardless()
        current = w
        textLayer = layer
        shownText = name
        shownAt = now
        closeAfter = timing.total
        // One close, cancelled when a new jump replaces this one.
        let work = DispatchWorkItem { close() }
        closing = work
        DispatchQueue.main.asyncAfter(deadline: .now() + timing.total, execute: work)
    }

    static func close() {
        closing?.cancel()
        closing = nil
        current?.orderOut(nil)
        current?.close()
        current = nil
        textLayer = nil
        closeAfter = nil
    }
}
