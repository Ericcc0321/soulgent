import AppKit
import SwiftUI

/// The status-bar menu as an app menu, the scene called seaview room (a setting saved under an earlier name still read), seaview room's three
/// switches (on until switched off, and the room honours off), the badge on the menu-bar icon.
@MainActor func menuBarTests() {
    // These are the menu and the settings of the panel as it is here, with no extension's scene (`Extensions`).
    // ── The menu ──
    let lines = appMenuLines()
    let titles = lines.map { $0 == .separator ? "─" : appMenuTitle($0) }
    check("menu: counts, show/hide, the three scenes, mark-all-seen + spotlight, settings + about, quit, separators between (\(titles))",
        titles == ["0 在等你 · 0 有话说 · 0 在干活", "─", "显示 / 隐藏 Soulgent", "─", "值班室", "办公室", "海景房", "─", "全部标为看过",
                   "聚光灯：跟着 Orca 里的会话", "─", "设置…", "关于 Soulgent", "─", "退出 Soulgent"])
    let copy = AppVariant(title: "Review copy", quitTitle: "Quit the review copy")
    let review = appMenuLines(variant: copy)
    check("menu: a review copy an extension builds keeps its title first, and quits under its own name",
        review.first == .variant && appMenuTitle(.variant, variant: copy) == "Review copy" && appMenuTitle(.quit, variant: copy) == "Quit the review copy"
            && !lines.contains(.variant))
    let delegate = AppDelegate()
    let menu = delegate.makeStatusMenu()
    let settings = menu.items.first { $0.title == "设置…" }, quit = menu.items.first { $0.title == "退出 Soulgent" }
    check("menu: the NSMenu built from it has the same lines; Settings is ⌘, and Quit is ⌘Q; the counts line can't be chosen",
        menu.items.map { $0.isSeparatorItem ? "─" : $0.title } == titles && settings?.keyEquivalent == "," && quit?.keyEquivalent == "q"
            && menu.items.first?.action == nil)
    check("menu: has no office walking / office theme / reshuffle pets / restore banned pets / demo / font size (all in Settings)",
        !menu.items.contains { ["办公室里走动", "办公室主题", "重新分配宠物", "演示：消息飞一次"].contains($0.title) || $0.title.hasPrefix("恢复拉黑") || $0.title.hasPrefix("字号") })
    check("menu: the first line reads like the board's header", menuCountsTitle(waiting: 2, unread: 1, busy: 4) == "2 在等你 · 1 有话说 · 4 在干活")

    // ── seaview room ──
    check("menu and settings: the fourth scene is called the seaview room (the code keeps .zone), in the mode, the theme and the title-bar switch",
        OfficeMode.zone.title == "海景房" && OfficeTheme.zone.name == "海景房" && OfficeSwitch.segments(mode: .zone).last?.title == "海景房")
    let before = (UserDefaults.standard.object(forKey: "office"), UserDefaults.standard.string(forKey: "officeTheme"))
    UserDefaults.standard.set(true, forKey: "office")
    UserDefaults.standard.set("海景房", forKey: "officeTheme")
    let readSea = OfficeMode.current == .zone && OfficeTheme.named("海景房").name == "海景房"
    settleOfficeTheme()
    let settled = UserDefaults.standard.string(forKey: "officeTheme")
    UserDefaults.standard.set(OfficeTheme.night.name, forKey: "officeTheme")
    settleOfficeTheme()
    let otherKept = UserDefaults.standard.string(forKey: "officeTheme") == OfficeTheme.night.name
    if let office = before.0 { UserDefaults.standard.set(office, forKey: "office") } else { UserDefaults.standard.removeObject(forKey: "office") }
    if let theme = before.1 { UserDefaults.standard.set(theme, forKey: "officeTheme") } else { UserDefaults.standard.removeObject(forKey: "officeTheme") }
    check("menu and settings: a setting saved as the seaview room shows it, and the launch leaves it as it is (\(settled ?? "nil")); others are left alone",
        readSea && settled == "海景房" && otherKept)

    // ── seaview room's three switches ──
    for key in ["zoneAura", "zoneLightning", "zoneOrca"] { UserDefaults.standard.removeObject(forKey: key) }
    check("menu and settings: flame and lightning aura, lightning and orca clip are on until switched off", zoneAuraOn() && zoneLightningOn() && zoneOrcaOn())
    defer { for key in ["zoneAura", "zoneLightning", "zoneOrca"] { UserDefaults.standard.removeObject(forKey: key) } }
    let crowd = auraCrowd()
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.calmOverride = false
    let window = NSWindow(contentRect: CGRect(x: -6000, y: -6000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    if ZoneArt.scene == nil {
        skipped("no 海景房 art", "menu and settings: the room honours flame and lightning aura / lightning off")
    } else {
        view.update(crowd.store)
        let onAura = view.aura(of: crowd.busy) != nil, onBolts = view.bolts(of: crowd.busy) != nil
        UserDefaults.standard.set(false, forKey: "zoneAura")
        view.update(crowd.store)
        let offAura = view.aura(of: crowd.busy) == nil && view.aura(of: crowd.calm) == nil && view.bolts(of: crowd.busy) == nil
        UserDefaults.standard.set(true, forKey: "zoneAura")
        UserDefaults.standard.set(false, forKey: "zoneLightning")
        view.update(crowd.store)
        let noBolts = view.aura(of: crowd.busy)?.superlayer != nil && view.bolts(of: crowd.busy) == nil
        UserDefaults.standard.set(true, forKey: "zoneLightning")
        view.update(crowd.store)
        let back = view.aura(of: crowd.busy) != nil && view.bolts(of: crowd.busy)?.superlayer != nil
            && !(view.bolts(of: crowd.busy)?.sublayers ?? []).isEmpty
        check("menu and settings: flame and lightning aura off, a Fable pet has no aura and no lightning; on again, both come back at the next refresh",
            onAura && onBolts && offAura && back)
        check("menu and settings: lightning off, the aura stays without its lightning; on again, the lightning holder is back and filled", noBolts && back)
    }
    // The orca: refused while off, the countdown going on (so switching it on again needs nothing).
    if ZoneOutdoorArt.orca == nil {
        skipped("no orca clips", "menu and settings: orca clip off refuses a clip")
    } else if let (panel, room, _) = zoneOrcaPanel(size, crowd.store) {
        let themeBefore = OfficeTheme.shown
        OfficeTheme.shown = OfficeTheme.zone
        room.calmOverride = false
        room.onScreenOverride = true
        room.update(crowd.store)
        UserDefaults.standard.set(false, forKey: "zoneOrca")
        let refused = !room.outdoor.playOrca("A") && room.outdoor.orcaPlayer == nil
        let counting = room.outdoor.orcaCountdown != nil
        check("menu and settings: orca clip off, no clip starts (asked for or due); the countdown keeps going", refused && counting)
        UserDefaults.standard.removeObject(forKey: "zoneOrca")
        room.stopListening()
        panel.orderOut(nil)
        OfficeTheme.shown = themeBefore
    }

    // ── The menu-bar icon ──
    check("icon: one badge, waiting + unread; red while one waits, else brand blue; none at zero; busy not counted",
        statusBadge(waiting: 0, unread: 0) == nil && statusBadge(waiting: 2, unread: 3) == StatusBadge(text: "5", red: true)
            && statusBadge(waiting: 0, unread: 4) == StatusBadge(text: "4", red: false) && statusBadge(waiting: 120, unread: 0)?.text == "99+")
    check("icon: the flame is found (brand/soulgent/flame-mono.pdf), the plain icon is a template, the badged one is not",
        Brand.flame != nil && statusIcon(waiting: 0, unread: 0).isTemplate && !statusIcon(waiting: 1, unread: 0).isTemplate)
    // The flame is a vector PDF cropped to its ink (taller than wide), and the icon fits the 22 pt bar.
    let plain = statusIcon(waiting: 0, unread: 0)
    check("flame icon: the flame is a PDF about 70 × 74 (its ink box); the plain icon is 16 × 20 pt, the flame 17 pt high",
        Brand.flame?.representations.contains { $0 is NSPDFImageRep } == true
            && (Brand.flame.map { $0.size.height > $0.size.width && $0.size.width > 60 } ?? false)
            && plain.size == NSSize(width: 16, height: 20))
    check("flame: the About window's picture is the app icon's 1024 (brand/soulgent/app-icon-macos-1024.png)",
        Brand.logo.map { $0.representations.first.map { $0.pixelsWide == 1024 } ?? false } ?? false)
    check("menu and settings: brandBlue is #1F8FFF, one constant", brandBlueHex == 0x1F8FFF)
    // The badged icon is drawn for the bar it is on: dark and light give different pictures (the fin's tint).
    func drawn(_ name: NSAppearance.Name) -> Data? {
        let image = statusIcon(waiting: 1, unread: 0)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2), pixelsHigh: Int(image.size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance { image.draw(in: NSRect(x: 0, y: 0, width: image.size.width * 2, height: image.size.height * 2)) }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
    let dark = drawn(.darkAqua), light = drawn(.aqua)
    check("icon: with a badge, the picture drawn on a dark menu bar differs from the one on a light bar (it follows the bar)",
        dark != nil && light != nil && dark != light)
}

/// `--settings-stills <dir>`: each tab of the Settings window as it is on screen (`settings-<tab>.png`), the status-bar menu
/// popped up (`menu.png`), and the menu-bar icon at a few counts on a dark and a light bar (`icon.png`).
@MainActor func settingsStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    let store = Store()
    store.readOnly = true
    store.loadOnce()
    let settings = SettingsWindow.shared
    settings.show(store: store, tab: .general, activate: false)
    guard let window = settings.window else { return print("no settings window") }
    window.setFrameOrigin(NSPoint(x: 80, y: 120))
    window.orderFrontRegardless()
    pump(0.8)
    for tab in SettingsTab.offered {
        settings.model.tab = tab
        pump(0.6)
        let path = dir + "/settings-\(tab.rawValue).png"
        print(captureWindow(window.windowNumber, to: path) ? path : "could not capture \(tab.rawValue)")
    }
    window.orderOut(nil)

    // The title bar's right end (ActionsBar): the scene switch, its chosen segment brand blue, and the gear.
    store.officeFits = true
    let bar = ImageRenderer(content: ActionsBar(store: store).padding(6).background(night).environment(\.colorScheme, .dark))
    bar.scale = 2
    if let tiff = bar.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir + "/titlebar.png"))
        print(dir + "/titlebar.png")
    }

    // The menu, popped up where it can be seen, grabbed while it tracks, then closed.
    let delegate = AppDelegate()
    delegate.store.readOnly = true
    delegate.store.loadOnce()
    delegate.store.officeFits = true
    let menu = delegate.makeStatusMenu()
    let path = dir + "/menu.png"
    let timer = Timer(timeInterval: 0.8, repeats: false) { _ in
        MainActor.assumeIsolated {
            let infos = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            let mine = infos.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == getpid() && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
            let number = mine.compactMap { $0[kCGWindowNumber as String] as? Int }.first
            print(number.map { captureWindow($0, to: path) } == true ? path : "could not capture the menu (\(mine.count) windows)")
            menu.cancelTracking()
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    menu.popUp(positioning: nil, at: NSPoint(x: 700, y: 700), in: nil)

    // The icon at 0, 3 unread, 1 waiting + 2 unread, 12 waiting; on a dark bar and a light one, 4× size.
    let counts = [(0, 0), (0, 3), (1, 2), (12, 0)]
    let scale: CGFloat = 4, cell = NSSize(width: 44, height: 24)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(cell.width * CGFloat(counts.count) * scale), pixelsHigh: Int(cell.height * 2 * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
    for (row, name) in [NSAppearance.Name.darkAqua, .aqua].enumerated() {
        let y = CGFloat(1 - row) * cell.height
        (name == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(x: 0, y: y, width: cell.width * CGFloat(counts.count), height: cell.height).fill()
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            for (i, c) in counts.enumerated() {
                let image = statusIcon(waiting: c.0, unread: c.1)
                let r = NSRect(x: CGFloat(i) * cell.width + (cell.width - image.size.width) / 2, y: y + (cell.height - image.size.height) / 2,
                               width: image.size.width, height: image.size.height)
                if image.isTemplate {
                    // As the menu bar tints a template: the bar's text colour.
                    let tinted = NSImage(size: image.size, flipped: false) { b in
                        image.draw(in: b)
                        (name == .darkAqua ? NSColor.white : NSColor.black.withAlphaComponent(0.85)).setFill()
                        b.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: r)
                } else {
                    image.draw(in: r)
                }
            }
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    let icon = dir + "/icon.png"
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: icon))
    print(icon)
}

/// `--fl-icon-stills <dir> [old fin png]`: the menu-bar flame on a dark and a light 22 pt bar, with no badge, 3 unread
/// (brand blue) and 5 waiting (red), at 2× (as on a Retina bar) and 6× (`fl-menubar-{dark,light}@{2,6}x.png`); with the
/// old fin's file, the old fin and the new flame side by side on both bars (`fl-compare-fin@{2,6}x.png`). A system
/// symbol (wifi) sits at the right end of each bar for scale.
@MainActor func flIconStills(_ dir: String, oldFin: String?) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let barHigh: CGFloat = 22
    let dark = NSColor(white: 0.16, alpha: 1), light = NSColor(white: 0.93, alpha: 1)
    /// As the menu bar tints a template: the bar's text colour.
    func tinted(_ image: NSImage, _ isDark: Bool) -> NSImage {
        guard image.isTemplate else { return image }
        return NSImage(size: image.size, flipped: false) { b in
            image.draw(in: b)
            (isDark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)).setFill()
            b.fill(using: .sourceAtop)
            return true
        }
    }
    let wifi: NSImage? = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .regular))
    func strip(_ images: [NSImage], width cell: CGFloat, isDark: Bool, scale: CGFloat, to path: String) {
        let w = cell * CGFloat(images.count + 1)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(barHigh * scale), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        NSAppearance(named: isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            (isDark ? dark : light).setFill()
            NSRect(x: 0, y: 0, width: w, height: barHigh).fill()
            for (i, image) in (images + [wifi.map { i -> NSImage in let c = i.copy() as! NSImage; c.isTemplate = true; return c }].compactMap { $0 }).enumerated() {
                let shown = tinted(image, isDark)
                let r = NSRect(x: CGFloat(i) * cell + ((cell - image.size.width) / 2).rounded(), y: ((barHigh - image.size.height) / 2).rounded(),
                               width: image.size.width, height: image.size.height)
                shown.draw(in: r)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path)
    }
    for isDark in [true, false] {
        // Drawn inside the bar's appearance, as the status item draws them.
        var icons: [NSImage] = []
        NSAppearance(named: isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            icons = [statusIcon(waiting: 0, unread: 0), statusIcon(waiting: 0, unread: 3), statusIcon(waiting: 5, unread: 0)]
        }
        for scale: CGFloat in [2, 6] {
            strip(icons, width: 34, isDark: isDark, scale: scale, to: dir + "/fl-menubar-\(isDark ? "dark" : "light")@\(Int(scale))x.png")
        }
    }
    // The earlier fin icon: the 635 px white PNG in a 24 × 16 box, 20 pt high, a template.
    guard let oldFin, let fin = NSImage(contentsOf: URL(fileURLWithPath: oldFin)) else { return }
    let old = NSImage(size: NSSize(width: 24, height: 20), flipped: false) { _ in
        fin.draw(in: NSRect(x: 0, y: 1, width: 24, height: 16), from: .zero, operation: .sourceOver, fraction: 1)
        return true
    }
    old.isTemplate = true
    for scale: CGFloat in [2, 6] {
        let rows = [true, false].map { isDark -> NSImage in
            let path = dir + "/.fl-compare-\(isDark)-\(Int(scale)).png"
            strip([old, statusIcon(waiting: 0, unread: 0)], width: 34, isDark: isDark, scale: scale, to: path)
            let image = NSImage(contentsOf: URL(fileURLWithPath: path))!
            try? FileManager.default.removeItem(atPath: path)
            return image
        }
        let w = 34 * 3 * scale, h = barHigh * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        rows[0].draw(in: NSRect(x: 0, y: h, width: w, height: h))
        rows[1].draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        let path = dir + "/fl-compare-fin@\(Int(scale))x.png"
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}
