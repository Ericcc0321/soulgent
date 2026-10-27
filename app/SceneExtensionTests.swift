import AppKit
import SwiftUI

/// An extension's scene is optional (`Extensions`: offered nowhere when this
/// build cannot show it, a saved one shows the sea room), the data folder is ~/Library/Application Support/Soulgent (an older
/// checkout's state/ copied over once), and the app is called Soulgent where it is shown.
@MainActor func sceneExtTests() {
    let defaults = UserDefaults.standard
    let before = (defaults.object(forKey: "office"), defaults.string(forKey: "officeTheme")), registered = Extensions.registered
    defer {
        Extensions.registered = registered
        if let office = before.0 { defaults.set(office, forKey: "office") } else { defaults.removeObject(forKey: "office") }
        if let theme = before.1 { defaults.set(theme, forKey: "officeTheme") } else { defaults.removeObject(forKey: "officeTheme") }
    }

    // ── No extension ──
    Extensions.registered = nil
    let plain = appMenuLines().map { $0 == .separator ? "─" : appMenuTitle($0) }
    check("extension: with none, the switch, the menu-bar menu and Settings offer the panel's own three scenes and five pages",
        OfficeMode.offered == [.board, .office, .zone] && OfficeSwitch.segments(mode: .zone).map(\.title) == ["值班室", "办公室", "海景房"]
            && plain.contains("海景房") && SettingsTab.offered == [.general, .office, .zone, .pets, .advanced]
            && OfficeTheme.all.map(\.name) == ["青灰", "暖夜", "海景房"])

    // ── An extension whose scene this build cannot show ──
    let scene = SceneExtTestScene()
    Extensions.registered = scene
    scene.available = false
    let lines = appMenuLines().map { $0 == .separator ? "─" : appMenuTitle($0) }
    let menu = AppDelegate().makeStatusMenu().items.map(\.title)
    check("extension: a scene this build cannot show is in neither the title bar's switch, the menu-bar menu nor Settings's pages",
        OfficeMode.offered == [.board, .office, .zone] && OfficeSwitch.segments(mode: .zone).map(\.title) == ["值班室", "办公室", "海景房"]
            && !lines.contains(scene.modeTitle) && lines.contains("海景房") && !menu.contains(scene.modeTitle) && menu.contains("海景房")
            && SettingsTab.offered == [.general, .office, .zone, .pets, .advanced])
    defaults.set(true, forKey: "office")
    defaults.set(scene.theme.name, forKey: "officeTheme")
    let shownBefore = (OfficeMode.current, OfficeTheme.current.name)
    settleOfficeTheme()
    let saved = defaults.string(forKey: "officeTheme")
    defaults.set(OfficeTheme.night.name, forKey: "officeTheme")
    settleOfficeTheme()
    let otherKept = defaults.string(forKey: "officeTheme") == OfficeTheme.night.name
    check("extension: a scene this build cannot show, saved last time, shows the sea room (\(shownBefore.0), \(shownBefore.1)), and the launch saves the sea room instead (\(saved ?? "nil")); other themes are left alone",
        shownBefore.0 == .zone && shownBefore.1 == OfficeTheme.zone.name && saved == OfficeTheme.zone.name && otherKept)

    // ── ...and one it can show ──
    scene.available = true
    defaults.set(scene.theme.name, forKey: "officeTheme")
    settleOfficeTheme()
    check("extension: a scene it can show is offered everywhere, before the sea room, and the launch leaves its saved name",
        OfficeMode.offered == OfficeMode.allCases && SettingsTab.offered == SettingsTab.allCases && OfficeMode.current == .scene
            && OfficeMode.scene.title == scene.modeTitle && OfficeSwitch.segments(mode: .scene).map(\.title) == ["值班室", "办公室", scene.modeTitle, "海景房"]
            && defaults.string(forKey: "officeTheme") == scene.theme.name
            && OfficeTheme.all.map(\.name) == ["青灰", "暖夜", scene.theme.name, "海景房"]
            && appMenuLines().contains(.mode(.scene)))
    Extensions.registered = registered

    // ── build.sh and test.sh: an extension directory only when it is there ──
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let build = (try? String(contentsOf: sources.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
    let tests = (try? String(contentsOf: sources.appendingPathComponent("test.sh"), encoding: .utf8)) ?? ""
    func guarded(_ text: String, _ marker: String) -> Bool {
        // Every line reading the extension directory comes after the `if [[ -n "$EXTENSION_DIR" && -d "$EXTENSION_DIR" ]]` and before its `fi`.
        guard let start = text.range(of: "if [[ -n \"$EXTENSION_DIR\" && -d \"$EXTENSION_DIR\" ]]"), let end = text.range(of: "\nfi\n", range: start.upperBound..<text.endIndex) else { return false }
        return text.components(separatedBy: "\n").allSatisfy { line in
            guard line.contains(marker), !line.trimmingCharacters(in: .whitespaces).hasPrefix("#"), let at = text.range(of: line) else { return true }
            return at.lowerBound >= start.lowerBound && at.upperBound <= end.lowerBound
        }
    }
    check("build: build.sh and test.sh read an extension directory only inside `if [[ -n \"$EXTENSION_DIR\" && -d \"$EXTENSION_DIR\" ]]`, and build without one",
        guarded(build, "$EXTENSION_DIR/") && guarded(tests, "$EXTENSION_DIR/") && build.contains("cp pet-facing.json")
            && build.contains("EXTENSION_SOURCES=(NoExtensions.swift)") && tests.contains("EXTENSION_SOURCES=(NoExtensions.swift)"))
    // Only an extension named outright (SOULGENT_EXTENSION_DIR, or app/.extension-dir): no folder is looked for by default.
    let named = "EXTENSION_DIR=\"${SOULGENT_EXTENSION_DIR:-}\"\nif [[ -z \"$EXTENSION_DIR\" && -f .extension-dir ]]; then IFS= read -r EXTENSION_DIR < .extension-dir || true; fi"
    check("build: build.sh and test.sh take an extension only from SOULGENT_EXTENSION_DIR or app/.extension-dir, none by default",
        build.contains(named) && tests.contains(named))
    check("build: the app is called Soulgent (CFBundleName and CFBundleDisplayName), version 0.1.0; its bundle id stays and the program is Soulgent",
        build.contains("APP_NAME=\"${SOULGENT_APP_NAME:-Soulgent}\"") && build.contains("<key>CFBundleName</key>\n    <string>$APP_NAME</string>")
            && build.contains("<key>CFBundleDisplayName</key>\n    <string>$APP_NAME</string>")
            && build.contains("BUNDLE_ID=\"${SOULGENT_BUNDLE_ID:-io.github.ericcc0321.soulgent}\"") && build.contains("<string>$BUNDLE_ID</string>")
            && build.contains("<key>CFBundleExecutable</key>\n    <string>Soulgent</string>")
            && build.contains("<key>CFBundleShortVersionString</key>\n    <string>0.1.0</string>")
            && build.contains("APP=\"${SOULGENT_APP_PATH:-Soulgent.app}\""))
    check("build: swiftc writes build/Soulgent, the bundle holds only Contents/MacOS/Soulgent (no old-name link), and the signing identity is not written into build.sh",
        build.contains(" -o build/Soulgent\n") && build.contains("cp build/Soulgent \"$APP/Contents/MacOS/Soulgent\"")
            && !build.contains("ln -s") && !build.contains("Session" + "Panel") && !build.contains("PANEL" + "_SIGNING_IDENTITY")
            && build.contains("SOULGENT_SIGNING_IDENTITY") && build.contains(".signing-identity")
            && build.contains("codesign --force --sign \"$SIGNING_IDENTITY\" \"$APP\""))
    check("names: About and Quit in the menu-bar menu say Soulgent",
        appMenuTitle(.about) == "关于 Soulgent" && appMenuTitle(.quit) == "退出 Soulgent")
    // The bundle id and what hangs on it (kept from the checks of the earlier bundle id's move).
    check("names: the caches folder, notification and queue names hang on the bundle id",
        cacheFolder == home + "/Library/Caches/" + appID && liveCaptureNote.rawValue == appID + ".capture"
            && zoneOrcaNote.rawValue == appID + ".orca"
            && ((try? String(contentsOf: sources.appendingPathComponent("Office.swift"), encoding: .utf8)) ?? "").contains("DispatchQueue(label: appID + \".focus\""))
    check("names: the bundle id defaults to io.github.ericcc0321.soulgent",
        build.contains("BUNDLE_ID=\"${SOULGENT_BUNDLE_ID:-io.github.ericcc0321.soulgent}\""))
    let repo = sources.deletingLastPathComponent()
    let readRepo = { (path: String) in (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? "" }
    let panelJob = readRepo("launchd/io.github.ericcc0321.soulgent.plist.template"), finderJob = readRepo("launchd/io.github.ericcc0321.soulgent.finder.plist.template")
    let install = readRepo("tools/install.sh"), uninstall = readRepo("tools/uninstall.sh")
    check("names: the launchd templates' labels are io.github.ericcc0321.soulgent and .soulgent.finder; install.sh and uninstall.sh use them; the panel job starts Contents/MacOS/Soulgent",
        panelJob.contains("<string>io.github.ericcc0321.soulgent</string>") && finderJob.contains("<string>io.github.ericcc0321.soulgent.finder</string>")
            && install.contains("install_job io.github.ericcc0321.soulgent \"") && install.contains("install_job io.github.ericcc0321.soulgent.finder \"")
            && uninstall.contains("for label in io.github.ericcc0321.soulgent io.github.ericcc0321.soulgent.finder; do")
            && panelJob.contains("/Contents/MacOS/Soulgent</string>") && install.contains("$APP/Contents/MacOS/Soulgent"))

    // ── The data folder ──
    check("data: the log and data live in ~/Library/Application Support/Soulgent, not in a checkout",
        panelDataFolder == home + "/Library/Application Support/Soulgent" && panelLogFile == panelDataFolder + "/panel.log")
}

// ───────── README stills on made-up sessions ─────────

/// The zones of the README's pictures: made-up names over the room's four islands (their codes are the render's).
let sceneExtZonesJSON = """
    {"zones": {"Web": {"name": "Web", "color": "#E0A040", "order": 1, "lead": "Web-storefront"},
               "Ops": {"name": "Ops", "color": "#40B0A0", "order": 2, "lead": "Ops-k8s-upgrade"},
               "AI": {"name": "AI", "color": "#5080D0", "order": 3, "lead": "AI-rag-index"},
               "Home": {"name": "Home", "color": "#A070D0", "order": 4, "lead": "Home-dotfiles"}},
     "dirs": {}, "default": null}
    """

/// The README's crowd: 26 made-up sessions over the four zones, most at their desks, two done and unread on a sofa, one
/// waiting in the line, one Fable session at work (the aura) and one Opus session at work in Orca's front tab (the light).
@MainActor func sceneExtCrowd() -> (store: Store, fable: String, lit: String) {
    let now = Date()
    let store = Store()
    store.readOnly = true
    var list: [Session] = []
    func add(_ name: String, _ status: String, ago: Double, seen: Bool = true, tool: String = "", asks: String = "", model: String = "") {
        let fixed = fixtureLine(asks)
        var s = Session(id: "scene-\(list.count)", pid: 1, project: String(name.drop { $0 != "-" }.dropFirst()), name: name, status: status,
                        since: now - ago, summary: asks.isEmpty ? "Done: the summary is in report.md" : fixed?.rendered ?? asks,
                        waitingFor: status == "waiting" ? "permission prompt" : "")
        s.summaryLine = fixed
        s.cwd = NSHomeDirectory() + "/projects/" + name
        s.tool = tool
        s.model = model
        list.append(s)
        if seen { store.seen[s.id] = now.timeIntervalSince1970 }
    }
    add("Web-storefront", "busy", ago: 300, tool: "Edit")
    add("Web-checkout", "busy", ago: 200, tool: "Bash")
    add("Web-landing-page", "idle", ago: 1500)
    add("Web-blog", "idle", ago: 2400)
    add("Web-design-system", "idle", ago: 700, seen: false)
    add("Web-i18n", "idle", ago: 3000)
    add("Ops-k8s-upgrade", "busy", ago: 400, tool: "Bash")
    add("Ops-ci-pipeline", "idle", ago: 1800)
    add("Ops-monitoring", "busy", ago: 120, tool: "Read")
    add("Ops-terraform", "idle", ago: 2600)
    add("Ops-backups", "idle", ago: 900, seen: false)
    add("Ops-incident-review", "idle", ago: 4000)
    add("AI-rag-index", "busy", ago: 100, tool: "Bash", model: "claude-fable-5-1")
    add("AI-eval-suite", "busy", ago: 260, tool: "Edit", model: "claude-opus-5-5")
    add("AI-embeddings", "idle", ago: 1300)
    add("AI-chat-agent", "idle", ago: 2100)
    add("AI-fine-tune", "idle", ago: 3300)
    add("AI-prompt-lab", "idle", ago: 2800)
    add("AI-data-clean", "idle", ago: 5000)
    add("Home-dotfiles", "idle", ago: 2000)
    add("Home-home-lab", "busy", ago: 150, tool: "Bash")
    add("Home-clouds", "idle", ago: 1600)
    add("Home-photo-sort", "idle", ago: 3600)
    add("Home-nebula", "idle", ago: 4200)
    add("Home-rudder", "waiting", ago: 240, asks: "要你批准：ssh router reboot")
    add("Home-recipes", "idle", ago: 5200)
    store.sessions = list
    store.assignPets()
    let fable = list.first { $0.name == "AI-rag-index" }?.id ?? "", lit = list.first { $0.name == "AI-eval-suite" }?.id ?? ""
    store.focused = lit
    return (store, fable, lit)
}

/// `--scene-stills <dir>`: the README's three pictures of the sea room on `sceneExtCrowd`, in the panel as the app makes it (the title bar
/// with the counts, the search and the switch; with no extension's scene, so the switch has three names), offscreen:
/// `seaview.png` (1180 × 760 points), `spotlight.png` (1400 × 936) and `aura.png` (a 3× crop round the Fable session).
/// Each window is grabbed by its number (its own window needs no permission) at the screen's scale; resize afterwards.
@MainActor func sceneExtStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let restore = seaSweepSetup(NSTemporaryDirectory() + "scene-zones-\(getpid())")
    try? sceneExtZonesJSON.write(toFile: ZoneConfigFile.path, atomically: true, encoding: .utf8)
    let defaults = UserDefaults.standard
    let registered = Extensions.registered
    Extensions.registered = nil
    defaults.set(true, forKey: "office")
    defaults.set(OfficeTheme.zone.name, forKey: "officeTheme")
    defaults.set(true, forKey: "officeSpotlight")
    defer {
        restore()
        Extensions.registered = registered
        for key in ["office", "officeTheme", "officeSpotlight", "petBySession"] { defaults.removeObject(forKey: key) }
    }
    Pets.shared.refresh(force: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    guard ZoneArt.scene != nil else { return print("extension stills: no sea room art") }
    let crowd = sceneExtCrowd()

    func panel(_ size: CGSize) -> ZoneOffscreenPanel {
        let panel = ZoneOffscreenPanel(contentRect: CGRect(x: -8000, y: -8000, width: size.width, height: size.height),
                                       styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = NSColor(red: 0x1B / 255.0, green: 0x18 / 255.0, blue: 0x30 / 255.0, alpha: 1)
        panel.contentView = NSHostingView(rootView: Root(store: crowd.store))
        var hosts: [NSView] = []
        for (view, side) in [(AnyView(CountsBar(store: crowd.store)), NSLayoutConstraint.Attribute.leading), (AnyView(ActionsBar(store: crowd.store)), .trailing)] {
            let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
            host.frame.size = host.fittingSize
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = side
            accessory.view = host
            panel.addTitlebarAccessoryViewController(accessory)
            hosts.append(host)
        }
        panel.orderFrontRegardless()
        // The room places its people and the walks settle; the pets' sheets are cut synchronously. The title bar's groups
        // take their size once the store has been read (as `zoneTitlebarMarginTests` does it).
        for _ in 0..<60 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            for host in hosts { host.setFrameSize(host.fittingSize) }
        }
        if let view = panel.contentView.flatMap(zonePanelFitFind) { view.still = true; view.update(crowd.store) }
        for _ in 0..<20 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return panel
    }
    // The window's own layers (the title bar, its buttons and the panel's colour), then the room over them as the window
    // composites it (`ZoneView.image`: the sea's frame, the auras added by screen), at 2×.
    func grab(_ panel: NSPanel) -> CGImage? {
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
    for (name, size) in [("seaview.png", CGSize(width: 1180, height: 760)), ("spotlight.png", CGSize(width: 1400, height: 936))] {
        let p = panel(size)
        if let image = grab(p), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir + "/" + name))
            print("extension stills: \(name) written")
        } else {
            print("extension stills: \(name) NOT written")
        }
        p.orderOut(nil)
        p.contentView = nil
    }
    // The aura up close, from the room itself at 3×.
    let size = CGSize(width: 1180, height: 790)
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(crowd.store)
    let k: CGFloat = 3
    guard let room = view.image(pixelScale: k), let foot = view.foot(of: crowd.fable) else { return print("extension stills: no aura.png") }
    let box = CGRect(x: foot.x - 150, y: foot.y - 200, width: 300, height: 280).intersection(CGRect(origin: .zero, size: size))
    if let crop = room.cropping(to: CGRect(x: box.minX * k, y: box.minY * k, width: box.width * k, height: box.height * k)),
       let png = NSBitmapImageRep(cgImage: crop).representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: dir + "/aura.png"))
        print("extension stills: aura.png written")
    }
    print("extension stills: pets \(crowd.store.sessions.map { "\($0.name)=\(crowd.store.displayPets[$0.id] ?? "-")" })")
}

/// A scene for the checks of `Extensions`: nothing of its own but a name, and whether this build could show it.
final class SceneExtTestScene: SceneExtension {
    var available = true
    @MainActor var theme: OfficeTheme { OfficeTheme(name: "测试场景", palette: OfficeTheme.studio.palette, furniture: StudioFurniture()) }
    var modeTitle: String { "测试场景" }
    var settingsTitle: String? { "测试场景" }
    var settingsSymbol: String? { "square" }
    @MainActor func settingsPage(store: Store) -> AnyView? { AnyView(Text("测试场景")) }
}
