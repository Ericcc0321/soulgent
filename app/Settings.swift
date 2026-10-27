import AppKit
import ApplicationServices
import SwiftUI

/// The status-bar menu as an app menu, the Settings window (the gear in the title bar opens it too), About,
/// the menu-bar icon (the Soulgent flame with one badge), and Seaview's three switches.

// ───────── Seaview's switches ─────────

/// Seaview: the Fable pets' aura (flame and lightning possession, Blaze Mode); on until switched off in Settings.
func zoneAuraOn() -> Bool { UserDefaults.standard.object(forKey: "zoneAura") as? Bool ?? true }
/// Seaview: the lightning on the aura (only while the aura itself is on); on until switched off.
func zoneLightningOn() -> Bool { UserDefaults.standard.object(forKey: "zoneLightning") as? Bool ?? true }
/// A session with work running in the background counts as at work (the board's groups, the unread rule, the pose, the
/// little walkers); on until `defaults write <app> bgCountsAsWorking -bool NO`, which brings back the old reading (background
/// work is idle, the finished time is the last turn's, a report from a background task is no news).
func bgCountsAsWorking() -> Bool { UserDefaults.standard.object(forKey: "bgCountsAsWorking") as? Bool ?? true }
/// The words for work in the background: how many tasks, and the hung kind's note (the glossary's background-running and suspected-hung wording).
func bgCountWords(_ n: Int) -> String { L10n.format("bg.count", table: "Board", zh: "BG %lld", n) }
/// The card's line for the background commands: N background commands (also in Traditional and Simplified Chinese).
func bgCommandsWords(_ n: Int) -> String { L10n.format("bg.commands", table: "Plurals", zh: "后台命令 %lld 个", n) }
func bgHungWords() -> String { L10n.string("common.bg.hung", table: "Common", zh: "后台任务疑似挂住") }
/// Errors and unexpected exits are drawn (the brick-red Error group, amber for a retry or the usage limit, the grey card of
/// one that exited unexpectedly); on until `defaults write <app> showFailed -bool NO`, which turns them off
/// (no Error group or badge, no colours, the sessions that exited unexpectedly left off the board).
func showFailed() -> Bool { UserDefaults.standard.object(forKey: "showFailed") as? Bool ?? true }
/// The brick red of an error (kin of the waiting coral, deeper) and the amber of a retry or the usage limit.
let failRedHex: UInt32 = 0xC4392B
let failAmberHex: UInt32 = 0xF0B429
/// The grey of a session that exited unexpectedly (its plate, its corner badge).
let goneGreyHex: UInt32 = 0x9A96B8
/// The Error group's title and count.
func failedWords() -> String { L10n.string("board.failed", table: "Board", zh: "出错") }
/// What an unexpected exit is called (also in Traditional and Simplified Chinese).
func exitedWords() -> String { L10n.string("common.exitedUnexpectedly", table: "Common", zh: "意外退出") }
/// The short words under a name in the office and the sea room for an error, a retry, the limit or an exit; nil for none.
/// The card itself says the longer line (`summary`, the dump's words).
func failShortWords(_ s: Session) -> String? {
    if s.isGone { return exitedWords() }
    if s.isRetrying, let a = s.retryAttempt, let m = s.retryMax { return L10n.format("board.fail.retrying", table: "Board", zh: "正在重试 %lld/%lld", a, m) }
    guard s.hasError else { return nil }
    switch s.errorKind {
    case "rate_limit": return L10n.string("board.fail.rateLimit", table: "Board", zh: "用量到顶")
    case "auth": return L10n.string("board.fail.relogin", table: "Board", zh: "要重新登录")
    case "wb_stopped": return L10n.string("board.fail.stopped", table: "Board", zh: "已中止")
    case "wb_error": return failedWords()
    default:
        if let status = s.errorStatus { return L10n.format("board.fail.apiStatus", table: "Board", zh: "API 出错 %lld", status) }
        return L10n.string("board.fail.api", table: "Board", zh: "API 出错")
    }
}
/// Seaview: the orca clips over the sea; on until switched off.
func zoneOrcaOn() -> Bool { UserDefaults.standard.object(forKey: "zoneOrca") as? Bool ?? true }

// ───────── The brand's pictures ─────────

enum Brand {
    /// `brand/<name>` in the app's Resources, else beside the sources (the checks run from `app/build/`).
    static func url(_ name: String) -> URL? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let places = [
            Bundle.main.resourceURL?.appendingPathComponent("brand/" + name),
            exe.deletingLastPathComponent().appendingPathComponent("brand/" + name),
            exe.appendingPathComponent("brand/" + name),
        ]
        return places.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The menu-bar flame (FL): black silhouette, eyes cut out, a vector PDF cropped to the flame (made from
    /// flame-mono.svg by brand/soulgent/make-icns.sh). Drawn as a template: the system tints it for the bar.
    static let flame: NSImage? = url("soulgent/flame-mono.pdf").flatMap { NSImage(contentsOf: $0) }
    /// About's picture: the app icon's 1024 (the dark-backed plush flame).
    static let logo: NSImage? = url("soulgent/app-icon-macos-1024.png").flatMap { NSImage(contentsOf: $0) }
}

/// The badge on the menu-bar icon: the sessions that need the user (waiting + unread); red while one waits, else brand blue.
/// None at zero. Busy ones are not counted (the menu's first line says them).
struct StatusBadge: Equatable {
    let text: String
    let red: Bool
}

/// `failed` (the Error group) counts in it and makes it red as one waiting does.
func statusBadge(waiting: Int, unread: Int, failed: Int = 0) -> StatusBadge? {
    let n = waiting + failed + unread
    return n <= 0 ? nil : StatusBadge(text: n > 99 ? "99+" : "\(n)", red: waiting > 0 || failed > 0)
}

/// The menu's first line (disabled): what the board's header says. "N errors" after the waiting, when there is one.
func menuCountsTitle(waiting: Int, unread: Int, busy: Int, failed: Int = 0) -> String {
    failed > 0
        ? L10n.format("menu.counts.failed", table: "Board", zh: "%lld 在等你 · %lld %@ · %lld 有话说 · %lld 在干活", waiting, failed, failedWords(), unread, busy)
        : L10n.format("menu.counts", table: "Board", zh: "%lld 在等你 · %lld 有话说 · %lld 在干活", waiting, unread, busy)
}

/// The menu-bar icon: the flame, monochrome as the menu bar wants it, and the badge drawn into the same picture. Without a
/// badge it is a template image (the system tints it); with one the flame is tinted here, at draw time, from the menu
/// bar's own appearance (light or dark), and the badge keeps its colour.
@MainActor func statusIcon(waiting: Int, unread: Int, failed: Int = 0) -> NSImage {
    let badge = statusBadge(waiting: waiting, unread: unread, failed: failed)
    // The flame is taller than wide (the PDF is its ink box, about 70 × 74): 17 pt high on the 22 pt bar.
    let flameHigh: CGFloat = 17
    let flameSize = NSSize(width: (flameHigh * (Brand.flame.map { $0.size.width / max($0.size.height, 1) } ?? 0.95)).rounded(), height: flameHigh)
    let font = NSFont.systemFont(ofSize: 8.5, weight: .bold)
    let digits = badge.map { NSAttributedString(string: $0.text, attributes: [.font: font, .foregroundColor: NSColor.white]) }
    let badgeHigh: CGFloat = 11
    let badgeWide = digits.map { max(badgeHigh, ceil($0.size().width) + 5) } ?? 0
    let size = NSSize(width: badge == nil ? flameSize.width : flameSize.width - 4 + badgeWide, height: 20)
    let flameRect = NSRect(x: 0, y: (size.height - flameSize.height) / 2 - 1, width: flameSize.width, height: flameSize.height)
    func drawFlame() {
        if let flame = Brand.flame {
            flame.draw(in: flameRect, from: .zero, operation: .sourceOver, fraction: 1)
        } else {
            // Only if brand/soulgent/flame-mono.pdf is missing: a plain drop, so the item is never empty.
            let p = NSBezierPath()
            p.move(to: NSPoint(x: flameRect.midX, y: flameRect.maxY))
            p.curve(to: NSPoint(x: flameRect.midX, y: flameRect.minY), controlPoint1: NSPoint(x: flameRect.minX - 2, y: flameRect.midY),
                    controlPoint2: NSPoint(x: flameRect.minX, y: flameRect.minY))
            p.curve(to: NSPoint(x: flameRect.midX, y: flameRect.maxY), controlPoint1: NSPoint(x: flameRect.maxX, y: flameRect.minY),
                    controlPoint2: NSPoint(x: flameRect.maxX + 2, y: flameRect.midY))
            p.close()
            NSColor.black.setFill()
            p.fill()
        }
    }
    guard let badge, let digits else {
        let image = NSImage(size: size, flipped: false) { _ in drawFlame(); return true }
        image.isTemplate = true
        return image
    }
    let image = NSImage(size: size, flipped: false) { _ in
        let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        drawFlame()
        (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 1 : 0.85).setFill()
        flameRect.fill(using: .sourceAtop)
        let r = NSRect(x: size.width - badgeWide, y: size.height - badgeHigh, width: badgeWide, height: badgeHigh)
        let fill = badge.red ? NSColor(srgbRed: 1, green: 0x3B / 255, blue: 0x30 / 255, alpha: 1) : NSColor(brandBlueHex)
        fill.setFill()
        NSBezierPath(roundedRect: r, xRadius: badgeHigh / 2, yRadius: badgeHigh / 2).fill()
        let t = digits.size()
        digits.draw(at: NSPoint(x: r.midX - t.width / 2, y: r.midY - t.height / 2))
        return true
    }
    image.isTemplate = false
    return image
}

extension NSColor {
    convenience init(_ hex: UInt32) {
        self.init(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

// ───────── The status-bar menu ─────────

/// One line of the status-bar menu, top to bottom.
enum AppMenuLine: Equatable {
    case variant, counts, toggle, mode(OfficeMode), markAllSeen, spotlight, settings, about, quit, separator
}

/// The menu's lines; a review copy an extension builds (`AppVariant`) says so at the top.
@MainActor func appMenuLines(variant: AppVariant? = nil) -> [AppMenuLine] {
    (variant?.title == nil ? [] : [.variant, .separator]) + [.counts, .separator, .toggle, .separator]
        + OfficeMode.offered.map { .mode($0) }
        + [.separator, .markAllSeen, .spotlight, .separator, .settings, .about, .separator, .quit]
}

@MainActor func appMenuTitle(_ line: AppMenuLine, variant: AppVariant? = nil) -> String {
    switch line {
    case .variant: return variant?.title ?? ""
    case .counts: return menuCountsTitle(waiting: 0, unread: 0, busy: 0)
    case .toggle: return L10n.string("menu.toggle", table: "Board", zh: "显示 / 隐藏 Soulgent")
    case .mode(let m): return m.title
    case .markAllSeen: return L10n.string("menu.markAllSeen", table: "Board", zh: "全部标为看过")
    case .spotlight: return spotlightMenuItem(trusted: true, on: true).title
    case .settings: return L10n.string("menu.settings", table: "Board", zh: "设置…")
    case .about: return L10n.string("menu.about", table: "Board", zh: "关于 Soulgent")
    case .quit: return variant?.quitTitle ?? L10n.string("menu.quit", table: "Board", zh: "退出 Soulgent")
    case .separator: return ""
    }
}

/// The light on or off, as the menu's line and the Settings' switch both do it. Without the permission: the system's own
/// prompt (the only place the panel asks). Off, Orca's page is closed to readers again.
@MainActor func switchSpotlight(store: Store) {
    if AXIsProcessTrusted() {
        setOfficeSpotlight(!officeSpotlight())
        if !officeSpotlight() { store.focus.switchOff() }
        store.objectWillChange.send()
    } else {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
    }
}

// ───────── The language ─────────

/// The language chosen in Settings > General: `AppleLanguages` in this app's own defaults domain (the standard key, the one a
/// per-app language in System Settings writes too), read by `L10n` at the next launch. None there: the system's.
enum LanguageChoice {
    /// The languages offered, each in its own words (they never change with the panel's language).
    static let offered: [(code: String, name: String)] = [("zh-Hans", "简体"), ("zh-Hant", "繁體"), ("en", "English")]

    /// This app's own domain (the checks': their process name), never the global one the system's languages live in.
    static var domain: String { Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName }

    /// The language chosen for this app (one of `L10n.languages`, as the system would match what is there); nil: the
    /// system's.
    static func current(_ defaults: UserDefaults = .standard) -> String? {
        guard let chosen = defaults.persistentDomain(forName: domain)?[L10n.languageKey] as? [String], !chosen.isEmpty else { return nil }
        return L10n.resolve(preferences: chosen)
    }

    /// Chooses one (nil: the system's again). Only `AppleLanguages` is written; takes effect at the next launch.
    static func set(_ code: String?, _ defaults: UserDefaults = .standard) {
        let chosen = code.flatMap { L10n.languages.contains($0) ? $0 : nil }
        if let chosen {
            defaults.set([chosen], forKey: L10n.languageKey)
        } else {
            defaults.removeObject(forKey: L10n.languageKey)
        }
        log("settings: language \(chosen ?? "the system's") from the next launch" + (code != nil && chosen == nil ? " (no tables for \(code!))" : ""))
    }
}

// ───────── About ─────────

// ───────── Where its data lives ─────────

/// The panel's log (launchd's stderr for it) and data, shared with finder_sessions.py, which keeps its caches, the
/// folders' original comments and its own log here too.
let panelDataFolder = home + "/Library/Application Support/Soulgent"
let panelLogFile = panelDataFolder + "/panel.log"
/// The checkout the app was built in: `<repo>/app/Soulgent.app` → `<repo>`. Only a guess for an app moved elsewhere.
let repoFolder = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().path
/// Whether `repoFolder` really is the checkout (its build script is there): About offers to open it only then.
var repoFound: Bool { FileManager.default.fileExists(atPath: repoFolder + "/app/build.sh") }

@MainActor func showAbout() {
    let alert = NSAlert()
    alert.messageText = "Soulgent"
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? L10n.string("about.devBuild", table: "Board", zh: "开发版")
    alert.informativeText = L10n.format("about.version", table: "Board", zh: "版本 %@", version) + "\n\n" + L10n.string("about.blurb", table: "Board", zh: "在一个浮动小窗里看所有 Claude Code / Codex 会话：谁在等你、谁有话说、谁在干活。")
    if let logo = Brand.logo { alert.icon = logo }
    alert.addButton(withTitle: L10n.string("about.ok", table: "Board", zh: "好"))
    let repo = repoFound  // The checkout the app was built in, when it is still beside it
    if repo { alert.addButton(withTitle: L10n.string("about.openRepo", table: "Board", zh: "打开项目目录")) }
    alert.layout()
    alert.window.level = .floating  // over the panel, which floats
    NSApp.activate(ignoringOtherApps: true)
    if alert.runModal() == .alertSecondButtonReturn, repo { NSWorkspace.shared.open(URL(fileURLWithPath: repoFolder)) }
}

// ───────── Settings ─────────

enum SettingsTab: String, CaseIterable {
    case general, office, scene, zone, pets, advanced
    var title: String {
        switch self {
        case .general: return L10n.string("tab.general", table: "Settings", zh: "通用")
        case .office: return L10n.string("tab.office", table: "Settings", zh: "办公室")
        case .scene: return Extensions.registered?.settingsTitle ?? ""
        case .zone: return L10n.string("tab.zone", table: "Settings", zh: "海景房")
        case .pets: return L10n.string("tab.pets", table: "Settings", zh: "角色")
        case .advanced: return L10n.string("tab.advanced", table: "Settings", zh: "高级")
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .office: return "building.2"
        case .scene: return Extensions.registered?.settingsSymbol ?? "square.dashed"
        case .zone: return "water.waves"
        case .pets: return "pawprint"
        case .advanced: return "wrench.and.screwdriver"
        }
    }
}

extension SettingsTab {
    /// The pages this build shows: a scene's page only where an extension's scene can be shown.
    @MainActor static var offered: [SettingsTab] { allCases.filter { $0 != .scene || Extensions.scene?.settingsTitle != nil } }
}

@MainActor final class SettingsModel: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// The one Settings window: the menu's Settings… and the title bar's gear both bring it up; it keeps its place.
@MainActor final class SettingsWindow {
    static let shared = SettingsWindow()
    let model = SettingsModel()
    private(set) var window: NSWindow?

    func show(store: Store, tab: SettingsTab? = nil, activate: Bool = true) {
        if let tab { model.tab = tab }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460), styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = L10n.string("title", table: "Settings", zh: "设置")
            w.titleVisibility = .hidden  // the tabs sit in the title bar; the title stays for the Window menu and Mission Control
            w.isReleasedWhenClosed = false
            w.level = .floating  // the panel floats; this must not open behind it
            w.contentView = NSHostingView(rootView: SettingsView(store: store, model: model))
            w.center()
            w.setFrameAutosaveName("SettingsWindow")
            window = w
        }
        if activate { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var store: Store
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.tab) {
            SettingsGeneral(store: store).tabItem { Label(SettingsTab.general.title, systemImage: SettingsTab.general.symbol) }.tag(SettingsTab.general)
            SettingsOffice(store: store).tabItem { Label(SettingsTab.office.title, systemImage: SettingsTab.office.symbol) }.tag(SettingsTab.office)
            if let page = Extensions.scene?.settingsPage(store: store) {  // No page for a scene this build cannot show
                page.tabItem { Label(SettingsTab.scene.title, systemImage: SettingsTab.scene.symbol) }.tag(SettingsTab.scene)
            }
            SettingsZone(store: store).tabItem { Label(SettingsTab.zone.title, systemImage: SettingsTab.zone.symbol) }.tag(SettingsTab.zone)
            SettingsPets(store: store).tabItem { Label(SettingsTab.pets.title, systemImage: SettingsTab.pets.symbol) }.tag(SettingsTab.pets)
            SettingsAdvanced(store: store).tabItem { Label(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.symbol) }.tag(SettingsTab.advanced)
        }
        .padding(12)
        .frame(width: 520, height: 460)
    }
}

private struct SettingsGeneral: View {
    @ObservedObject var store: Store
    @AppStorage("zoom") private var zoom = 1.0
    @AppStorage("officeSpotlight") private var spotlight = true

    var body: some View {
        Form {
            // The language, at the next launch. The languages are named in their own words.
            Picker(L10n.string("general.language", table: "Settings", zh: "语言"), selection: Binding(get: { store.settingsLanguage ?? "" }, set: { code in
                store.settingsLanguage = code.isEmpty ? nil : code
                LanguageChoice.set(store.settingsLanguage)
            })) {
                Text(L10n.string("general.language.system", table: "Settings", zh: "跟随系统")).tag("")
                ForEach(LanguageChoice.offered, id: \.code) { Text($0.name).tag($0.code) }
            }
            Text(L10n.string("general.language.restart", table: "Settings", zh: "重启 Soulgent 后生效。")).font(.caption).foregroundStyle(.secondary)
            Picker(L10n.string("general.textSize", table: "Settings", zh: "字号"), selection: $zoom) {
                Text(L10n.string("general.textSize.small", table: "Settings", zh: "小")).tag(0.9)
                Text(L10n.string("general.textSize.standard", table: "Settings", zh: "标准")).tag(1.0)
                Text(L10n.string("general.textSize.large", table: "Settings", zh: "大")).tag(1.15)
                Text(L10n.string("general.textSize.extraLarge", table: "Settings", zh: "特大")).tag(1.3)
            }
            .pickerStyle(.segmented)
            Text(L10n.string("general.textSize.note", table: "Settings", zh: "值班室的卡片和标题栏跟着变；办公室和海景房不受影响。")).font(.caption).foregroundStyle(.secondary)
            let trusted = AXIsProcessTrusted()
            Toggle(L10n.string("menu.spotlight", table: "Board", zh: "聚光灯：跟着 Orca 里的会话"), isOn: Binding(get: { trusted && spotlight }, set: { _ in switchSpotlight(store: store) }))
            if !trusted {
                Text(L10n.string("general.accessibility", table: "Settings", zh: "需要在 系统设置 > 隐私与安全性 > 辅助功能 里允许「Soulgent」。打开开关会弹出系统的请求。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent(L10n.string("general.login", table: "Settings", zh: "开机自动启动")) {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(L10n.string("general.login.managed", table: "Settings", zh: "由 launchd 任务负责，这里不改")).foregroundStyle(.secondary)
                    Button(L10n.string("general.login.open", table: "Settings", zh: "打开 LaunchAgents 文件夹")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: home + "/Library/LaunchAgents"))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsOffice: View {
    @ObservedObject var store: Store
    @AppStorage("officeWalks") private var walks = true
    @AppStorage("officeThemeOffice") private var theme = OfficeTheme.studio.name
    @AppStorage("officeFloor") private var floor: String?

    /// The office theme's floor, their own if the user chose one.
    private var floorColor: Binding<Color> {
        Binding(
            get: {
                let hex = OfficeTheme.named(theme).floored(OfficeTheme.hex(floor)).palette.floor
                return Color(hex: hex)
            },
            set: { color in
                guard let c = NSColor(color).usingColorSpace(.sRGB) else { return }
                func byte(_ v: CGFloat) -> UInt32 { UInt32((max(0, min(1, v)) * 255).rounded()) }
                setOfficeFloor(byte(c.redComponent) << 16 | byte(c.greenComponent) << 8 | byte(c.blueComponent))
                store.objectWillChange.send()
            })
    }

    var body: some View {
        Form {
            Toggle(L10n.string("office.walks", table: "Settings", zh: "办公室里走动"), isOn: $walks).onChange(of: walks) { _, _ in store.objectWillChange.send() }
            Picker(L10n.string("office.theme", table: "Settings", zh: "主题"), selection: Binding(get: { theme }, set: { name in
                // Writing the shown theme would switch scenes: only while the office shows; else it is what Office goes back to.
                if OfficeMode.current == .office { setOfficeTheme(name) } else { theme = name }
                store.objectWillChange.send()
            })) {
                ForEach(OfficeTheme.officeThemes, id: \.name) { Text($0.displayName).tag($0.name) }  // Shows the name, stores the id
            }
            .pickerStyle(.radioGroup)
            ColorPicker(L10n.string("office.background", table: "Settings", zh: "背景色…"), selection: floorColor, supportsOpacity: false)
            LabeledContent(L10n.string("office.background.follows", table: "Settings", zh: "背景色跟随主题")) {
                Button(L10n.string("office.background.reset", table: "Settings", zh: "恢复主题的背景色")) {
                    setOfficeFloor(nil)
                    store.objectWillChange.send()
                }
                .disabled(floor == nil)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SettingsZone: View {
    @ObservedObject var store: Store
    @AppStorage("zoneAura") private var aura = true
    @AppStorage("zoneLightning") private var lightning = true
    @AppStorage("zoneOrca") private var orca = true

    var body: some View {
        Form {
            Toggle(L10n.string("common.blazeMode", table: "Common", zh: "火焰与闪电附身"), isOn: $aura)
            Text(L10n.string("zone.aura.note", table: "Settings", zh: "Fable 会话的宠物身上的金色光焰。")).font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.string("zone.lightning", table: "Settings", zh: "闪电"), isOn: $lightning).disabled(!aura)
            Text(L10n.string("zone.lightning.note", table: "Settings", zh: "光焰上的闪电；光效关掉时它也不显示。")).font(.caption).foregroundStyle(.secondary)
            Toggle(L10n.string("zone.orca", table: "Settings", zh: "虎鲸短片"), isOn: $orca)
            Text(L10n.string("zone.orca.note", table: "Settings", zh: "窗外海面上偶尔游过的虎鲸。")).font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: aura) { _, _ in store.objectWillChange.send() }
        .onChange(of: lightning) { _, _ in store.objectWillChange.send() }
        .onChange(of: orca) { _, _ in store.objectWillChange.send() }
    }
}

private struct SettingsPets: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            LabeledContent(L10n.string("pets.reshuffle", table: "Settings", zh: "重新分配宠物")) {
                Button(L10n.string("pets.reshuffle.button", table: "Settings", zh: "重新分配…")) { store.askingReassign = true }
            }
            LabeledContent(unbanMenuTitle(store.bannedPets.count)) {
                Button(L10n.string("pets.restore", table: "Settings", zh: "恢复")) { store.unbanPets() }.disabled(store.bannedPets.isEmpty)
            }
            Section(L10n.string("pets.open", table: "Settings", zh: "打开的会话")) {
                if store.sessions.isEmpty {
                    Text(L10n.string("pets.none", table: "Settings", zh: "现在没有打开的会话。")).foregroundStyle(.secondary)
                }
                ForEach(store.sessions.sorted { $0.name < $1.name }, id: \.id) { s in
                    LabeledContent(s.name.isEmpty ? s.project : s.shownName) {
                        let step = store.figureStep(s)
                        Text(L10n.format("pets.row", table: "Settings", zh: "%@  ·  大小 %@", store.petBySession[s.id] ?? "—", step > 0 ? "+\(step)" : "\(step)"))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L10n.string("pets.reshuffle.ask", table: "Settings", zh: "给所有会话重新分配宠物？"), isPresented: $store.askingReassign) {
            Button(L10n.string("pets.reshuffle.confirm", table: "Settings", zh: "重新分配")) { store.redealPets() }
            Button(L10n.string("pets.reshuffle.cancel", table: "Settings", zh: "取消"), role: .cancel) {}
        } message: {
            Text(L10n.string("pets.reshuffle.note", table: "Settings", zh: "每个会话会换一个新的宠物（拉黑的不会再出现）。"))
        }
    }
}

private struct SettingsAdvanced: View {
    @ObservedObject var store: Store

    var body: some View {
        Form {
            LabeledContent(L10n.string("advanced.demo", table: "Settings", zh: "演示：消息飞一次")) { Button(L10n.string("advanced.demo.button", table: "Settings", zh: "飞一次")) { store.demoFlight() } }
            LabeledContent(L10n.string("advanced.log", table: "Settings", zh: "日志")) { Button(L10n.string("advanced.log.open", table: "Settings", zh: "打开日志")) { NSWorkspace.shared.open(URL(fileURLWithPath: panelLogFile)) } }
            LabeledContent(L10n.string("advanced.data", table: "Settings", zh: "数据目录")) { Button(L10n.string("advanced.data.open", table: "Settings", zh: "打开数据目录")) { NSWorkspace.shared.open(URL(fileURLWithPath: panelDataFolder)) } }
        }
        .formStyle(.grouped)
    }
}

// ───────── A window as it is on screen ─────────

/// A window of this app as it is on screen, without its shadow (CGWindowListCreateImage is marked unavailable to Swift on
/// newer SDKs but still works, so it is looked up by name). Grabbing one's own window needs no permission.
@MainActor func captureWindow(_ number: Int, to path: String) -> Bool {
    typealias Grab = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"),
          let image = unsafeBitCast(symbol, to: Grab.self)(.null, 1 << 3, UInt32(number), 1 | 1 << 3)?.takeRetainedValue(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}
