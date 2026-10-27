import AppKit
import SwiftUI

/// The keys a zone sign's list goes by among the pointer's targets: "zone-Web", and "zone-visitor" for the check-in
/// label. No "/" in them: `OfficeList.entry` splits its row keys at the first one.
let zoneListPrefix = "zone-"

/// Which list is up: a sign was clicked. Here, not on the store, so the board and the other themes never see it.
@MainActor enum ZoneUI {
    static var open: String?
    static let visitorKey = zoneListPrefix + ZonePlan.visitorKey
    /// The rest room's list: everyone resting, seated or not.
    static let restKey = zoneListPrefix + "rest"

    static func key(_ zone: String) -> String { zoneListPrefix + zone }
    static var active: Bool { OfficeTheme.current.name == OfficeTheme.zone.name }

    /// what `--hover` takes for the rest room's list and check-in's. Command-line words (scripts and checks pass them),
    /// fixed whatever language the room shows; never shown, never translated.
    enum HoverToken: String {
        case rest = "休息室", visitor = "报到"

        @MainActor var listKey: String { self == .rest ? ZoneUI.restKey : ZoneUI.visitorKey }
    }
}

/// Seaview's room: the rendered office at night with every session at its desk, drawn in Core Animation layers over the
/// Blender picture. Points come from `points.json` through `ZoneFit`, so a new render moves everything with it.
@MainActor final class ZoneView: NSView, HoverResolver {
    enum Target: Equatable { case pet(String), list(String) }

    private final class Figure {
        let layer = CALayer()
        let sprite = CALayer()
        /// The plate lives in its own holder in the plates layer, over every pet, moving with the figure.
        let tag = CALayer()
        let plate = CALayer()
        /// Its bubbles (the queue head's ask, a visitor's word, the unread dots) in the speech layer over the plates.
        let voice = CALayer()
        let bubble = CALayer()
        var spinner: CALayer?
        /// The spotlight's cone and pool, under the pet, while it is the one focused in Orca.
        var beam: CALayer?
        /// a Fable session's gold aura (`ZoneAura`), behind its pet, over the beam.
        var aura: CALayer?
        /// its lightning (`ZoneAura.makeBolts`), over its pet: bolts crawl on the body.
        var bolts: CALayer?
        /// The pet's size factor, from its idle frame; nil while it shows the token.
        var factor: CGFloat?
        /// How far its plate is moved up to clear a neighbour's, in view points.
        var nudge: CGFloat = 0
        /// a sofa sitter's plate over its head instead of under its feet (the picture's bottom edge would cut it).
        var lifted = false
        var pinned = false
        var saying = false
        /// Where it is meant to be, in the picture's pixels.
        var spot = CGPoint(x: -1, y: -1)
        var spriteKey = ""
        var plateKey = ""
        var bubbleKey = ""
        /// What it shows: the pose, whether a pet is drawn (not the token), whether it wears the ask bubble.
        var pose: Pose?
        /// Waiting for you it stands still and knocks (`WaitingNudge`), or with Reduce Motion wears `ring`.
        var ring: CAShapeLayer?
        var hasPet = false
        var asking = false
        /// the tool badge over a busy one's head (in `voice`), the family it shows; its sub-agents' mini figures (in
        /// the stage, beside it) and what they were drawn for; how far above its feet the drawn head is.
        let badge = CALayer()
        var badgeFamily: ZoneToolFamily?
        var agents: CALayer?
        var agentsKey = ""
        var headTop: CGFloat = 0
        var drawnWide: CGFloat = 0
        /// The pet whose running frames a walk shows.
        var pet: String?
        /// Which way a visitor turns to its host (`ZoneWalk.right` / `.left`); nil when not visiting.
        var facing: Int?
        /// when its walk ends (media time), 0 when not walking; the route it walks, in the view.
        var walkEnds: CFTimeInterval = 0
        var route: [CGPoint] = []
    }

    var still = false
    /// the moment of the aura's loops a still or Reduce Motion holds (a check or a contact sheet picks others).
    var auraPhase = ZoneAura.stillPhase
    weak var store: Store?
    private(set) var plan = ZonePlan()
    /// A check can say Reduce Motion is on or off; else the system's setting.
    var calmOverride: Bool?
    private var calm: Bool { calmOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// the sea, the crabs and the gulls (ZoneFX.swift).
    let outdoor = ZoneOutdoor()
    /// Whether the outdoors was laid out live (nil: not yet).
    private var outdoorLive: Bool?
    /// A check can say the window is seen or not; else the window's own state.
    var onScreenOverride: Bool?
    private var watching: [NSObjectProtocol] = []
    private var watchingWorkspace: [NSObjectProtocol] = []
    private var watchingOrca: [NSObjectProtocol] = []

    private let root = CALayer()
    private let base = CALayer()
    private let lights = CALayer()
    /// the desks a lifted figure may be dropped on, on the floor under the pets.
    private let marksLayer = CALayer()
    private let stage = CALayer()
    private let plates = CALayer()
    private let speech = CALayer()
    private let boards = CALayer()
    /// Under the title bar a soft fall from its colour, so the bar's lower edge reads the same over the dark floor on the
    /// left and the bright beach on the right.
    private let titleShade = CAGradientLayer()
    private let restPill = CALayer()
    private var restPillKey = ""
    /// Who is visiting whom, carried from one look to the next.
    private var visits = ZoneVisits()
    private var visitWake: Date?
    private var screens: [ZoneDesk: CALayer] = [:]
    /// a busy desk's code, made on its first busy look and kept (off while it is not busy).
    private var codeScreens: [ZoneDesk: ZoneCodeScreen] = [:]
    private var leds: [ZoneDesk: CALayer] = [:]
    private var ledShown: [ZoneDesk: ZoneLED] = [:]
    /// each desk's foreground layer, in the stage with the figures (`ZoneDeskLayers`); the boss's under its own key.
    private var deskLayers: [ZoneDesk: ZoneDeskLayers] = [:]
    /// what `depth` needs from the art, kept from the last build (asking `ZoneArt.scene` each time reads the
    /// workzones file's stamp): the desk layers, the camera's floor direction, the floor; nil without desk layers.
    private var occluders: (desks: [ZoneDeskLayer], forward: CGVector, map: ZoneWalkMap, petHeight: CGFloat)?
    static let bossDeskKey = ZoneDesk(zone: "boss", index: 1)
    private var signs: [String: CALayer] = [:]
    private var signKeys: [String: String] = [:]
    /// each label's pill in the view (its layer has a margin round it for the shadow).
    private var signPills: [String: CGRect] = [:]
    /// each label's off-duty badge (how many of its zone are off duty), and what it was drawn for.
    private var offBadges: [String: CALayer] = [:]
    private var offBadgeKeys: [String: String] = [:]
    private var offCounts: [String: Int] = [:]
    private var figures: [String: Figure] = [:]
    private var fit = ZoneFit(scene: .zero, view: .zero)
    private var builtFor = CGSize.zero
    /// The zone codes the desks and labels were built for: a change of the workzones moves them, and they are built again.
    private var builtZones: [String] = []
    private var pressed: Target?
    private var saidNoArt = false

    /// Scene pixels a second when walking (224).
    static let pace: CGFloat = 224

    override init(frame: NSRect) {
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.backgroundColor = OfficeCanvas.rgb(0x15192B)
        root.masksToBounds = true
        layer = root
        wantsLayer = true
        // the picture fills the view and runs past it (the sea's loop and the gulls too). AppKit sets a view's layer's
        // masksToBounds from `clipsToBounds` (false by default since macOS 14), so the line above alone is not enough and the
        // room would draw into the title bar; the view itself must clip.
        clipsToBounds = true
        // the sea over the picture, the crabs over the sea, both under the screens and the figures; the gulls over all.
        // the orca clips over the crabs, under the screens (and so under the gulls and the title bar's shade).
        for part in [base, outdoor.sea, outdoor.beach, outdoor.orca, lights, marksLayer, stage, plates, speech, boards, outdoor.gulls, titleShade] { root.addSublayer(part) }
        let bar = NSColor(red: 0x1A / 255.0, green: 0x17 / 255.0, blue: 0x2A / 255.0, alpha: 1)
        titleShade.colors = [bar.withAlphaComponent(0.6).cgColor, bar.withAlphaComponent(0.25).cgColor, bar.withAlphaComponent(0).cgColor]
        titleShade.locations = [0, 0.35, 1]
        titleShade.name = "titleShade"
        for (part, name) in [(base, "base"), (lights, "lights"), (marksLayer, "marks"), (stage, "stage"), (plates, "plates"), (speech, "speech"), (boards, "boards")] {
            part.name = name
        }
        boards.addSublayer(restPill)
        base.contentsGravity = .resize
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // ───────── Following the store ─────────

    func listen() {
        OfficePets.shared.onReady = { [weak self] in self?.refresh() }
        OfficePets.shared.listener = self
    }

    func stopListening() {
        if OfficePets.shared.listener === self {
            OfficePets.shared.onReady = nil
            OfficePets.shared.listener = nil
        }
        if store?.tracker.resolver === self { store?.tracker.resolver = nil }
        outdoor.setRunning(false)
    }

    // ───────── The outdoors ─────────

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for f in figures.values { f.agentsKey = "" }  // the helpers' walkers lost their animations with the old window: made again
        for token in watching { NotificationCenter.default.removeObserver(token) }
        for token in watchingWorkspace { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        for token in watchingOrca { DistributedNotificationCenter.default().removeObserver(token) }
        watching = []
        watchingWorkspace = []
        watchingOrca = []
        if let window {
            // `--orca A|B|C` (a debug hook): that clip at the loop's next frame 0, if the outdoors is playing.
            watchingOrca.append(DistributedNotificationCenter.default().addObserver(forName: zoneOrcaNote, object: nil, queue: .main) { [weak self] note in
                let id = note.object as? String
                MainActor.assumeIsolated {
                    guard let self, let id else { return }
                    let started = self.outdoorSeen && self.outdoor.playOrca(id)
                    log("Seaview: orca \(id) asked for: \(started ? "at the loop's next frame 0" : "not now (hidden, still, calm or one already on)")")
                }
            })
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                watching.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncOutdoor() }
                })
            }
            watchingWorkspace.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.syncOutdoor() }
                })
        }
        syncOutdoor()
    }

    /// Whether anyone can see the room: its window shown, not minimised, not covered, and Seaview the theme.
    var outdoorSeen: Bool {
        if let onScreenOverride { return onScreenOverride }
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return ZoneUI.active
    }

    /// Lays the outdoors out again when Reduce Motion or a still picture changes what it shows; plays it only while seen.
    func syncOutdoor() {
        let live = !still && !calm
        if let was = outdoorLive, was != live {
            outdoor.configure(live: live, fit: fit, bounds: bounds, seeded: still)
            outdoorLive = live
        }
        outdoor.setRunning(live && store != nil && outdoorLive != nil && outdoorSeen)
    }

    private func refresh() {
        for f in figures.values { f.spriteKey = "" }
        if let store { update(store) }
    }

    override func layout() {
        super.layout()
        if let store, bounds.size != builtFor { update(store) }
    }

    func update(_ store: Store) {
        self.store = store
        guard let scene = ZoneArt.scene else {
            if !saidNoArt { log("Seaview: no points.json found; the room stays empty") }
            saidNoArt = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        root.frame = bounds
        for part in [lights, marksLayer, stage, plates, speech, boards, outdoor.beach, outdoor.orca, outdoor.gulls] { part.frame = bounds }
        titleShade.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 24)
        fit = ZoneFit(scene: scene.size, view: bounds.size)
        // the picture is aspect-filled through the same fit as the sea, the desks and the figures on every update (it is not stretched to the view, or it would slide off them).
        base.frame = fit.rect(CGRect(origin: .zero, size: scene.size))
        if bounds.size != builtFor || Self.zoneCodes(scene) != builtZones { build(scene) }
        ZoneOffDuty.shared.settle(awake: Set(store.sessions.map(\.registryName).filter { !$0.isEmpty }))
        plan = ZonePlan.current(store, scene: scene)
        let config = ZoneConfigFile.current()
        var owner: [ZoneDesk: String] = [:]
        for (id, desk) in plan.desks { owner[desk] = id }
        for desk in scene.desks {
            let id = ZoneDesk(zone: desk.zone, index: desk.index)
            screens[id]?.opacity = plan.screenOn(id) ? 1 : 0
            paintLED(id, desk, plan.led(id))
            deskLayers[id]?.paint(screen: plan.screenOn(id), led: plan.led(id), disc: ledDisc(desk, plan.led(id)), deskID: "\(id.zone)_\(id.index)", animated: !still && !calm)
            if plan.led(id) == .ice {
                updateFX(desk: id, session: owner[id].flatMap { o in store.sessions.first { $0.id == o } })
            } else {
                codeScreens[id]?.isOn = false
            }
        }
        placeSigns(scene, store, config)
        placeFigures(scene, store, config)
        // after the figures, so the "+N" keeps clear of their heads.
        placeRest(scene)
        // the carried one gone, or no longer with a desk it may leave: it settles back.
        if let id = liftedID, !canLift(id) { cancelLift() }
        spotlight(store, scene)
        publish(store)
        syncOutdoor()
    }

    /// A busy desk's screen shows code scrolling (`ZoneCodeScreen`, over its lit crop, made on the desk's
    /// first busy look and kept); its LED breathes (`paintLED`); the tool badge and the sub-agents' figures go with the
    /// figure (`dress`, `placeAgents`).
    private func updateFX(desk: ZoneDesk, session: Session?) {
        if let code = codeScreens[desk] {
            code.isOn = true
            return
        }
        guard let art = ZoneArt.scene?.desk(desk), art.screen.count >= 4 else { return }
        let code = ZoneCodeScreen(quad: art.screen.map(fit.point), deskID: "\(desk.zone)_\(desk.index)", scale: 2, animated: !still && !calm)
        if let layers = deskLayers[desk] {
            // over the desk's lit screen, in its layer, so a figure behind the desk does not cover it.
            layers.holder.insertSublayer(code.layer, above: layers.screen)
        } else if let lit = screens[desk] {
            lights.insertSublayer(code.layer, above: lit)
        } else {
            lights.addSublayer(code.layer)
        }
        codeScreens[desk] = code
    }

    /// The picture and every desk's lights, laid out for this size.
    private func build(_ scene: ZoneScene) {
        builtFor = bounds.size
        builtZones = Self.zoneCodes(scene)
        base.frame = fit.rect(CGRect(origin: .zero, size: scene.size))
        base.contents = ZoneArt.picture("night_base")
        outdoor.configure(live: !still && !calm, fit: fit, bounds: bounds, seeded: still)
        outdoorLive = !still && !calm
        lights.sublayers = nil
        screens = [:]
        codeScreens = [:]
        leds = [:]
        ledShown = [:]
        let lit = ZoneArt.picture("night_screens")
        for desk in scene.desks {
            let id = ZoneDesk(zone: desk.zone, index: desk.index)
            let led = CALayer()
            led.opacity = 0
            lights.addSublayer(led)
            leds[id] = led
            let screen = screenLayer(desk, scene: scene, picture: lit)
            screen.opacity = 0
            lights.addSublayer(screen)
            screens[id] = screen
        }
        buildDesks(scene)
        for sign in signs.values { sign.removeFromSuperlayer() }
        for badge in offBadges.values { badge.removeFromSuperlayer() }
        signs = [:]
        signKeys = [:]
        signPills = [:]
        offBadges = [:]
        offBadgeKeys = [:]
        restPillKey = ""
        for f in figures.values {
            f.spriteKey = ""
            f.plateKey = ""
            f.bubbleKey = ""
        }
    }

    /// every desk's foreground layer in the stage, as deep as its centre, so the figures and the desks are drawn front
    /// to back together (a desk nearer the camera covers the one behind it). Only the desks: the stage's figures stay.
    private func buildDesks(_ scene: ZoneScene) {
        for layers in deskLayers.values { layers.holder.removeFromSuperlayer() }
        deskLayers = [:]
        occluders = nil
        if let forward = scene.forward, let map = scene.walkMap, !scene.deskLayers.isEmpty {
            occluders = (scene.deskLayers, forward, map, scene.petHeight)
        }
        var all = scene.desks.map { (ZoneDesk(zone: $0.zone, index: $0.index), $0) }
        if let boss = scene.bossDesk { all.append((Self.bossDeskKey, boss)) }
        for (id, desk) in all {
            guard let art = desk.layer, let made = ZoneDeskLayers(art, fit: fit, bounds: bounds) else { continue }
            stage.addSublayer(made.holder)
            deskLayers[id] = made
        }
    }

    /// A screen lit: the lit render's own pixels over the screen's quad (a little round it, not the neighbours') when there
    /// is one; else the screen's quad in a cool white with a soft halo, so the room works without the lit render.
    private func screenLayer(_ desk: ZoneScene.Desk, scene: ZoneScene, picture: CGImage?) -> CALayer {
        let holder = CALayer()
        holder.frame = bounds
        if let picture, desk.screen.count >= 3 {
            let margin = scene.upright * 0.1
            let box = ZoneGlow.bounds(desk.screen).insetBy(dx: -margin, dy: -margin).intersection(CGRect(origin: .zero, size: scene.size))
            let lit = CALayer()
            lit.contents = picture
            lit.contentsRect = CGRect(x: box.minX / scene.size.width, y: box.minY / scene.size.height,
                                      width: box.width / scene.size.width, height: box.height / scene.size.height)
            lit.frame = fit.rect(box)
            holder.addSublayer(lit)
            return holder
        }
        guard desk.screen.count >= 3 else { return holder }
        var middle = CGPoint.zero
        for p in desk.screen { middle = CGPoint(x: middle.x + p.x / CGFloat(desk.screen.count), y: middle.y + p.y / CGFloat(desk.screen.count)) }
        let halo = CALayer()
        let reach = scene.upright * 1.1
        halo.frame = fit.rect(CGRect(x: middle.x - reach, y: middle.y - reach, width: reach * 2, height: reach * 2))
        halo.contents = ZoneGlow.disc(0x9FD4FF)
        halo.opacity = 0.55
        holder.addSublayer(halo)
        let face = CAShapeLayer()
        let path = CGMutablePath()
        path.move(to: fit.point(desk.screen[0]))
        for p in desk.screen.dropFirst() { path.addLine(to: fit.point(p)) }
        path.closeSubpath()
        face.path = path
        face.fillColor = OfficeCanvas.rgb(0xCFEAFF, 0.92)
        face.strokeColor = OfficeCanvas.rgb(0x7FC4FF, 0.9)
        face.lineWidth = 0.8
        holder.addSublayer(face)
        return holder
    }

    /// The strip under a desk: a soft pool of its colour on the floor below the desk top (ice from the lit-LED render when
    /// there is one).
    private func paintLED(_ id: ZoneDesk, _ desk: ZoneScene.Desk, _ led: ZoneLED) {
        guard let layer = leds[id], ledShown[id] != led else { return }
        ledShown[id] = led
        layer.sublayers = nil
        // off first, or the breathing would hold an LED that is going dark; on again below for a busy one.
        ZoneBreath.remove(from: layer)
        guard led != .off, let scene = ZoneArt.scene else {
            layer.opacity = 0
            return
        }
        let ledPicture = ZoneArt.picture("night_leds")
        if led == .ice, let ledPicture, let quad = desk.led {
            let box = ZoneGlow.bounds(quad).insetBy(dx: -scene.upright * 0.4, dy: -scene.upright * 0.4)
            layer.contents = ledPicture
            layer.contentsRect = CGRect(x: box.minX / scene.size.width, y: box.minY / scene.size.height,
                                        width: box.width / scene.size.width, height: box.height / scene.size.height)
            layer.frame = fit.rect(box)
            layer.opacity = 1
            ZoneBreath.apply(to: layer, deskID: "\(id.zone)_\(id.index)", waiting: false, animated: !still && !calm)
            return
        }
        let floor = desk.floor ?? CGPoint(x: desk.seat.x - scene.upright, y: desk.seat.y + scene.upright * 0.2)
        let wide = scene.upright * 2.3, high = scene.upright * 1.0
        layer.frame = fit.rect(CGRect(x: floor.x - wide / 2, y: floor.y - high * 0.35, width: wide, height: high))
        layer.contents = ZoneGlow.disc(led == .ice ? 0x7FDBFF : 0xFFA24A)
        layer.opacity = led == .ice ? 0.85 : 0.95
        if led == .ice { ZoneBreath.apply(to: layer, deskID: "\(id.zone)_\(id.index)", waiting: false, animated: !still && !calm) }
    }

    /// the glow disc `paintLED` lays on the floor for a lit LED with no lit-LED picture (orange; ice without the
    /// render): its picture, its frame in the view and its opacity; nil for an LED off.
    private func ledDisc(_ desk: ZoneScene.Desk, _ led: ZoneLED) -> (image: CGImage, frame: CGRect, opacity: Float)? {
        guard led != .off, let scene = ZoneArt.scene, let image = ZoneGlow.disc(led == .ice ? 0x7FDBFF : 0xFFA24A) else { return nil }
        let floor = desk.floor ?? CGPoint(x: desk.seat.x - scene.upright, y: desk.seat.y + scene.upright * 0.2)
        let wide = scene.upright * 2.3, high = scene.upright * 1.0
        return (image, fit.rect(CGRect(x: floor.x - wide / 2, y: floor.y - high * 0.35, width: wide, height: high)), led == .ice ? 0.85 : 0.95)
    }

    // ───────── Signs ─────────

    private func placeSigns(_ scene: ZoneScene, _ store: Store, _ config: ZoneConfig) {
        var counts: [String: Int] = [:], calling = Set<String>()
        var byID: [String: Session] = [:]
        for s in store.sessions { byID[s.id] = s }
        var zoneOf: [String: String] = [:]
        for s in store.sessions {
            guard let code = config.resolve(name: s.name, cwd: s.cwd), config.zone(code) != nil else { continue }
            zoneOf[s.id] = code
            counts[code, default: 0] += 1
            if s.status == "waiting" { calling.insert(code) }
        }
        let high = ZoneGlow.signHeight(scale: fit.scale)
        // how many of each sign's are off duty (being woken counted too); the rest go to check-in's.
        offCounts = ZoneListCard.offDuty(store, scene: scene).mapValues(\.count)
        for sign in scene.signs {
            let name = config.zone(sign.zone)?.name ?? sign.zone
            let extra = plan.overflow[sign.zone]?.count ?? 0
            let color = config.zone(sign.zone)?.color ?? 0x8A9BB0
            let at = fit.point(sign.center)
            let key = "\(name) \(counts[sign.zone] ?? 0) \(extra) \(calling.contains(sign.zone)) \(at) \(high) \(color)"
            let layer = signs[sign.zone] ?? CALayer()
            if layer.superlayer == nil { boards.addSublayer(layer) }
            signs[sign.zone] = layer
            guard signKeys[sign.zone] != key else { continue }
            signKeys[sign.zone] = key
            let drawn = ZoneGlow.sign(name, count: counts[sign.zone] ?? 0, extra: extra, calling: calling.contains(sign.zone), color: color, height: high)
            hang(layer, drawn, at: at, key: sign.zone)
        }
        defer { for sign in scene.signs { badgeSign(sign.zone, high: high) }; badgeSign(ZonePlan.visitorKey, high: high) }
        // The check-in spot: the check-in label, and how many wait to be placed when more than its one spot; the same label as the zones'.
        let unzoned = (plan.visitor == nil ? 0 : 1) + plan.visitorList.count
        let label = signs[ZonePlan.visitorKey] ?? CALayer()
        if label.superlayer == nil { boards.addSublayer(label) }
        signs[ZonePlan.visitorKey] = label
        var anchor: CGPoint?
        if let quad = scene.visitorSign {
            let face = fit.rect(ZoneGlow.bounds(quad))
            anchor = CGPoint(x: face.midX, y: face.midY)
        } else if let seat = scene.visitor {
            // No sign in the art: the label floats just over the head of the one standing there.
            anchor = fit.point(CGPoint(x: seat.x, y: seat.y - scene.petHeight - scene.upright * 0.5))
        }
        let key = "报到 \(unzoned) \(String(describing: anchor)) \(high)"
        // nobody checking in, no label standing alone on the floor (unless it lists some off duty).
        if (unzoned == 0 && (offCounts[ZonePlan.visitorKey] ?? 0) == 0) || anchor == nil {
            label.contents = nil
            signKeys[ZonePlan.visitorKey] = nil
            signPills[ZonePlan.visitorKey] = nil
        } else if signKeys[ZonePlan.visitorKey] != key, let anchor {
            signKeys[ZonePlan.visitorKey] = key
            let drawn = ZoneGlow.sign(L10n.string("zone.visitor", table: "Zone", zh: "报到"), count: unzoned, extra: max(0, unzoned - 1), calling: false, color: 0x9AA7BC, height: high)
            hang(label, drawn, at: anchor, key: ZonePlan.visitorKey)
        }
    }

    /// the off-duty badge on a label's pill, its top right corner; none at 0 or with no label shown.
    private func badgeSign(_ key: String, high: CGFloat) {
        let count = offCounts[key] ?? 0
        guard count > 0, let pill = signPills[key], signs[key]?.contents != nil else {
            offBadges[key]?.removeFromSuperlayer()
            offBadges[key] = nil
            offBadgeKeys[key] = nil
            return
        }
        let layer = offBadges[key] ?? CALayer()
        if layer.superlayer == nil { boards.addSublayer(layer) }
        offBadges[key] = layer
        let drawKey = "\(count) \(pill) \(high)"
        guard offBadgeKeys[key] != drawKey else { return }
        offBadgeKeys[key] = drawKey
        let drawn = ZoneGlow.offBadge(count, height: high)
        layer.contents = drawn.image
        layer.name = "offBadge-" + key
        let x = ((pill.maxX - drawn.size.width * 0.55) * 2).rounded() / 2, y = ((pill.minY - drawn.size.height * 0.45) * 2).rounded() / 2
        layer.frame = CGRect(x: x, y: y, width: drawn.size.width, height: drawn.size.height)
    }

    /// A label drawn, hung with its pill's middle on `at`, on whole half-points so it stays crisp.
    private func hang(_ layer: CALayer, _ drawn: (image: CGImage?, size: CGSize, layout: ZoneGlow.SignLayout), at: CGPoint, key: String) {
        let pill = drawn.layout.pill
        let x = ((at.x - pill.midX) * 2).rounded() / 2, y = ((at.y - pill.midY) * 2).rounded() / 2
        layer.contents = drawn.image
        layer.frame = CGRect(x: x, y: y, width: drawn.size.width, height: drawn.size.height)
        signPills[key] = pill.offsetBy(dx: x, dy: y)
    }

    // ───────── Figures ─────────

    /// Where a session is meant to be now, in the picture's pixels: its place (`ZonePlan.place`, the table's answer) on the
    /// art; nil for one not drawn (beyond the rest room's seats or the check-in spot).
    private func spot(_ id: String, _ scene: ZoneScene) -> CGPoint? {
        guard let place = plan.place[id] else { return nil }
        return Self.point(of: place, scene)
    }

    /// A place on the art, in the picture's pixels.
    static func point(of place: ZonePlace, _ scene: ZoneScene) -> CGPoint? {
        switch place {
        case .desk(let desk): return scene.desk(desk)?.seat
        case .sofaSeat(let zone, let i):
            guard let sofa = scene.sofas.first(where: { $0.zone == zone }), i < sofa.seats.count else { return nil }
            return sofa.seats[i]
        case .sofaSpot(let zone, let i): return scene.sofaOverflow(zone, slot: i)
        case .line(let i): return scene.lineSpot(i) ?? scene.boss
        case .lobby(let i): return scene.lobby(slot: i)
        case .rest(let i): return i < scene.restSeats.count ? scene.restSeats[i] : nil
        case .checkIn: return scene.visitor
        case .restListed, .checkInListed: return nil
        }
    }

    /// Whether a session is at its own desk this pass (not away on the sofa, in the line or in the rest room).
    private func atDesk(_ id: String) -> Bool {
        if case .desk? = plan.place[id] { return true }
        return false
    }

    private func placeFigures(_ scene: ZoneScene, _ store: Store, _ config: ZoneConfig) {
        sofaPlatesLifted = sofaPlatesCut(scene)
        var keep = Set<String>()
        let now = Date()
        // Where each would be by its own state; then the visits move their visitors beside their hosts.
        var homes: [String: CGPoint] = [:]
        for s in store.sessions { if let home = spot(s.id, scene) { homes[s.id] = home } }
        let inLine = Set(plan.line + plan.lobby)
        var free = Set<String>(), open = Set<String>()
        for s in store.sessions where homes[s.id] != nil {
            if !inLine.contains(s.id) { open.insert(s.id) }
            var resting = false
            if case .rest? = plan.place[s.id] { resting = true }
            if s.status != "waiting", !s.restarting, !inLine.contains(s.id), atDesk(s.id) || resting {
                free.insert(s.id)
            }
        }
        visits = ZoneVisits.next(homes: homes, free: free, open: open, peers: store.peers, rounds: store.rounds, previous: visits, now: now,
                                 pace: Self.pace, length: { Self.visitLength(from: $0, to: $1, scene: scene) })
        wakeForVisits(store)
        // A visitor stands on the floor beside its host's chair, a second one a pet's width on along the aisle.
        var standing: [String: CGPoint] = [:]
        for id in visits.visits.keys.sorted() {
            guard let visit = visits.visits[id], let host = homes[visit.host] else { continue }
            // clear of the figures round about too (not its host, nor itself).
            let others = homes.filter { $0.key != id && $0.key != visit.host && standing[$0.key] == nil }.map(\.value)
            standing[id] = scene.visitSpot(host, taken: Array(standing.values), others: others)
        }
        for s in store.sessions {
            guard let home = homes[s.id] else { continue }
            let target = standing[s.id] ?? home
            keep.insert(s.id)
            let f = figures[s.id] ?? Figure()
            if figures[s.id] == nil {
                figures[s.id] = f
                f.layer.name = s.id
                f.tag.name = s.id
                f.layer.addSublayer(f.sprite)
                f.tag.addSublayer(f.plate)
                f.voice.addSublayer(f.bubble)
                f.voice.addSublayer(f.badge)
                f.badge.name = "badge"
                speech.addSublayer(f.voice)
                f.sprite.magnificationFilter = .nearest
                f.sprite.contentsGravity = .resize
                stage.addSublayer(f.layer)
                plates.addSublayer(f.tag)
            }
            f.pet = store.displayPets[s.id]
            // a carried figure stays under the pointer; its place is taken up on the drop.
            if s.id != liftedID { move(f, to: target, scene: scene) }
            dress(f, s, store, scene, config, now: now)
            // again with the pet as dressed (its frame decides which desks it overlaps).
            if s.id != liftedID {
                let z = depth(f, at: fit.point(f.spot))
                for part in [f.layer, f.tag, f.voice] where part.zPosition != z { part.zPosition = z }
            }
            placeAgents(f, s, store, scene, at: target == home && visits.visits[s.id] == nil)
        }
        for (id, f) in figures where !keep.contains(id) {
            // one that has just gone off duty (or simply closed) fades from where it stood rather than blinking out.
            let parts = [f.agents, f.layer, f.tag, f.voice].compactMap { $0 }
            figures[id] = nil
            if still || calm {
                for part in parts { part.removeFromSuperlayer() }
            } else {
                CATransaction.begin()
                CATransaction.setCompletionBlock { for part in parts { part.removeFromSuperlayer() } }
                for part in parts {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = part.presentation()?.opacity ?? part.opacity
                    fade.toValue = 0
                    fade.duration = 0.6
                    part.opacity = 0
                    part.add(fade, forKey: "zone.leave")
                }
                CATransaction.commit()
            }
        }
        staggerPlates()
        clearDots()
        clearSayings()
        // A picture is drawn in layer order, not by zPosition: put the front ones last, as the window shows them.
        if still {
            for holder in [stage, plates, speech] {
                if let order = holder.sublayers { holder.sublayers = order.sorted { $0.zPosition < $1.zPosition } }
            }
        }
    }

    /// Once the visits in hand are due to end, a look again, so the visitor walks back even if nothing else changes.
    private func wakeForVisits(_ store: Store) {
        guard !still, let end = visits.visits.values.map(\.until).min(), end > Date() else { return }
        if let visitWake, visitWake <= end, visitWake > Date() { return }
        visitWake = end
        DispatchQueue.main.asyncAfter(deadline: .now() + end.timeIntervalSinceNow + 0.2) { [weak self, weak store] in
            guard let self, let store, self.store === store else { return }
            self.visitWake = nil
            self.update(store)
        }
    }

    /// Plates that would overlap a neighbour's (in a line, say) step up out of its way, the back one moving, a few times
    /// at most; each one's place is its figure's, so walking takes it along.
    private func staggerPlates() {
        let order = figures.values.sorted { $0.layer.zPosition > $1.layer.zPosition }
        var placed: [CGRect] = []
        for f in order {
            let base = plateBox(f, nudge: 0)
            var nudge: CGFloat = 0
            // Under the feet a plate in the way steps up; over the head (lifted) too, away from the head.
            for _ in 0..<4 {
                let box = base.offsetBy(dx: 0, dy: -nudge)
                guard let hit = placed.first(where: { $0.insetBy(dx: 1, dy: 0.5).intersects(box) }) else { break }
                nudge += box.maxY - hit.minY + 1
            }
            if nudge != f.nudge {
                f.nudge = nudge
                f.plate.frame.origin.y = plateBase(f) - nudge
                dotsBesidePlate(f)
            }
            placed.append(base.offsetBy(dx: 0, dy: -nudge))
        }
    }

    /// in the crowded bottom of the current art (the line, the standing spots and the sofas close together), a done-and-unread
    /// one's dots never lie on anyone else's plate or another's dots: at their usual place (by the head, or beside a lifted
    /// plate), else by the other side of the head, else one to three bubbles' heights higher on either side.
    private func clearDots() {
        var taken: [CGRect] = figures.values.filter { $0.plate.contents != nil }.map { plateBox($0, nudge: $0.nudge) }
        let order = figures.values.filter { $0.bubbleKey.hasPrefix("dot") && $0.bubble.contents != nil }.sorted { $0.layer.zPosition > $1.layer.zPosition }
        for f in order {
            let at = fit.point(f.spot), size = f.bubble.frame.size, head = f.sprite.frame
            let top = f.hasPet ? f.headTop : head.minY
            let own = plateBox(f, nudge: f.nudge)
            let right: CGPoint, left: CGPoint
            if f.lifted {
                right = CGPoint(x: f.plate.frame.maxX - size.width * 0.3, y: f.plate.frame.minY - size.height * 0.6)
                left = CGPoint(x: f.plate.frame.minX - size.width * 0.7, y: f.plate.frame.minY - size.height * 0.6)
            } else {
                right = CGPoint(x: head.maxX - size.width * 0.4, y: top - size.height * 0.8)
                left = CGPoint(x: head.minX - size.width * 0.6, y: top - size.height * 0.8)
            }
            let up = size.height + 2 * fit.scale
            // last, lower beside its own head (only taken when the higher ones all lie on another pet).
            var tries = [right, left] + [1, 2, 3].flatMap { k in [CGPoint(x: right.x, y: right.y - up * k), CGPoint(x: left.x, y: left.y - up * k)] }
            for k: CGFloat in [1, 2] {
                tries.append(CGPoint(x: right.x + size.width * 0.3, y: right.y + up * k))
                tries.append(CGPoint(x: left.x - size.width * 0.3, y: left.y + up * k))
            }
            let others = taken.filter { $0 != own }
            // and, where it can, off the other pets (on one, the dots read as that one's).
            let pets = figures.values.filter { $0 !== f }.map { g -> CGRect in
                let p = fit.point(g.spot)
                return CGRect(x: p.x - g.drawnWide * 0.4, y: p.y + g.headTop, width: g.drawnWide * 0.8, height: -g.headTop)
            }
            func clear(_ o: CGPoint, of boxes: [CGRect]) -> Bool {
                let r = CGRect(origin: CGPoint(x: at.x + o.x, y: at.y + o.y), size: size).insetBy(dx: 1, dy: 1)
                return !boxes.contains { $0.intersects(r) }
            }
            let pick = tries.first { clear($0, of: others + pets) } ?? tries.first { clear($0, of: others) } ?? right
            if f.bubble.frame.origin != pick { f.bubble.frame.origin = pick }
            taken.append(CGRect(origin: CGPoint(x: at.x + pick.x, y: at.y + pick.y), size: size))
        }
    }

    /// a visitor's word bubble steps up, a few times at most, off any other figure's tool badge or plate under it.
    private func clearSayings() {
        for f in figures.values where f.saying && f.bubble.contents != nil {
            let at = fit.point(f.spot)
            // From its usual height each time (what was in its way may have gone).
            f.bubble.frame.origin.y = (f.hasPet ? f.headTop : f.sprite.frame.minY) - f.bubble.frame.height - 2 * fit.scale
            var marks: [CGRect] = []
            for g in figures.values where g !== f {
                let p = fit.point(g.spot)
                if g.badge.contents != nil { marks.append(g.badge.frame.offsetBy(dx: p.x, dy: p.y)) }
                if g.plate.contents != nil { marks.append(plateBox(g, nudge: g.nudge)) }
            }
            for _ in 0..<3 {
                let box = f.bubble.frame.offsetBy(dx: at.x, dy: at.y)
                guard let hit = marks.first(where: { $0.intersects(box) }) else { break }
                f.bubble.frame.origin.y -= box.maxY - hit.minY + 1
            }
        }
    }

    /// The plate's top under the feet, in view points.
    private var plateTop: CGFloat { 2 * fit.scale }

    /// With the sofas in a row along the picture's bottom: whether a plate under the feet of one on the lowest sofa
    /// seat would be cut by the view's bottom edge (a window wider than the picture's 3:2 crops its bottom). Then every sofa
    /// sitter's plate goes over its head, all of them alike.
    private(set) var sofaPlatesLifted = false
    private func sofaPlatesCut(_ scene: ZoneScene) -> Bool {
        guard let lowest = scene.sofas.flatMap(\.seats).map(\.y).max() else { return false }
        let tall = ZoneGlow.plate("名", scale: fit.scale, gold: false).size.height
        return fit.point(CGPoint(x: 0, y: lowest)).y + plateTop + tall > bounds.height - 1
    }

    /// Where a figure's plate's top is with no nudge, from its feet: under them, or (a lifted sofa sitter) over its head.
    private func plateBase(_ f: Figure) -> CGFloat {
        f.lifted ? f.headTop - f.plate.frame.height - 2 * fit.scale : plateTop
    }

    /// a lifted sitter's unread dots ride at its plate's right end, a little above it, so the two do not cover each other.
    private func dotsBesidePlate(_ f: Figure) {
        guard f.lifted, f.bubbleKey.hasPrefix("dot") else { return }
        let size = f.bubble.frame.size
        f.bubble.frame.origin = CGPoint(x: f.plate.frame.maxX - size.width * 0.3, y: f.plate.frame.minY - size.height * 0.6)
    }

    /// A figure's plate where it will stand, in the view.
    private func plateBox(_ f: Figure, nudge: CGFloat) -> CGRect {
        let at = fit.point(f.spot)
        return CGRect(x: at.x + f.plate.frame.minX, y: at.y + plateBase(f) - nudge, width: f.plate.frame.width, height: f.plate.frame.height)
    }

    /// To its new place: walking there along the aisles (`ZoneWalkMap`, round the islands, the boss's desk and the
    /// sofas), or there at once in a picture, out of a window, or with Reduce Motion.
    private func move(_ f: Figure, to target: CGPoint, scene: ZoneScene) {
        let end = fit.point(target)
        defer {
            f.spot = target
            let z = depth(f, at: end)
            for part in [f.layer, f.tag, f.voice] {
                part.position = end
                part.zPosition = z
            }
        }
        guard f.spot.x >= 0, f.spot != target, !still, !calm, window != nil else {
            if f.spot != target {
                for part in [f.layer, f.tag, f.voice] {
                    part.removeAnimation(forKey: "walk")
                    part.removeAnimation(forKey: Self.walkDepthKey)
                }
                f.sprite.removeAnimation(forKey: "steps")
                f.walkEnds = 0
                f.route = []
            }
            return
        }
        let start = f.layer.presentation()?.position ?? f.layer.position
        let points = Self.walkRoute(from: fit.back(start), to: target, scene: scene).map(fit.point)
        walk(f, along: points)
    }

    /// how far a visitor walks from its place to beside its host, in picture pixels: the way it walks (by the roads).
    static func visitLength(from a: CGPoint, to host: CGPoint, scene: ZoneScene) -> CGFloat {
        let way = walkRoute(from: a, to: scene.visitSpot(host), scene: scene)
        var length: CGFloat = 0
        for (p, q) in zip(way, way.dropFirst()) { length += hypot(q.x - p.x, q.y - p.y) }
        return length
    }

    /// The way between two picture points, in picture points: round the obstacles when the art has its map, else straight.
    static func walkRoute(from a: CGPoint, to b: CGPoint, scene: ZoneScene) -> [CGPoint] {
        scene.walkMap?.route(from: a, to: b) ?? [a, b]
    }

    /// a figure's place in the front-to-back order standing at `at` (view points), as a zPosition: its feet's y, held
    /// behind the desks it stands behind and in front of those it stands in front of (`ZoneOcclusion.key`).
    private func depth(_ f: Figure, at: CGPoint) -> CGFloat {
        guard let art = occluders, fit.scale > 0 else { return at.y }
        let feet = fit.back(at)
        var box: CGRect
        if f.sprite.frame.width > 0, f.sprite.frame.height > 0 {
            let r = f.sprite.frame
            box = CGRect(x: feet.x + r.minX / fit.scale, y: feet.y + r.minY / fit.scale, width: r.width / fit.scale, height: r.height / fit.scale)
        } else {
            let tall = art.petHeight
            box = CGRect(x: feet.x - tall * 0.4, y: feet.y - tall, width: tall * 0.8, height: tall)
        }
        // A little wider than the pet, for its aura.
        box = box.insetBy(dx: -box.width * 0.1, dy: 0)
        let key = ZoneOcclusion.key(feet: feet, box: box, desks: art.desks, forward: art.forward, map: art.map)
        return fit.point(CGPoint(x: feet.x, y: key)).y
    }

    /// a walk's zPosition, worked out once as it sets off: the order at a point every `depthStep` picture pixels along
    /// the route (`depth`), held from one to the next (discrete), on the same clock as the position's keyframes.
    static let walkDepthKey = "walk.depth"
    static let depthStep: CGFloat = 8
    private func walkDepth(_ f: Figure, along points: [CGPoint], lengths: [CGFloat], duration: Double) -> CAKeyframeAnimation? {
        guard let total = lengths.last, total > 0 else { return nil }
        let step = Self.depthStep * max(fit.scale, 0.05)
        var values: [NSNumber] = [], times: [NSNumber] = []
        for i in 1..<points.count {
            let a = points[i - 1], b = points[i], leg = lengths[i] - lengths[i - 1]
            var d: CGFloat = 0
            repeat {
                let t = leg > 0 ? d / leg : 0
                let z = depth(f, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                values.append(NSNumber(value: Double(z)))
                times.append(NSNumber(value: Double((lengths[i - 1] + d) / total)))
                d += step
            } while d < leg
        }
        values.append(NSNumber(value: Double(depth(f, at: points[points.count - 1]))))
        times.append(1)
        let walk = CAKeyframeAnimation(keyPath: "zPosition")
        walk.values = values
        walk.keyTimes = times + [1]
        walk.calculationMode = .discrete
        walk.duration = duration
        return walk
    }

    /// A walk along view points at `pace`: position keyframes for the figure, its plate and its bubbles, and the running
    /// frames leg by leg on its sprite. and its place in the order along the way (`walkDepth`).
    private func walk(_ f: Figure, along points: [CGPoint]) {
        var lengths: [CGFloat] = [0]
        for i in 1..<max(1, points.count) { lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)) }
        let total = lengths.last ?? 0
        guard points.count > 1, total > 1 else { return }
        let walk = CAKeyframeAnimation(keyPath: "position")
        walk.values = points.map { NSValue(point: $0) }
        walk.keyTimes = lengths.map { NSNumber(value: Double($0 / total)) }
        walk.duration = Double(total / (Self.pace * max(fit.scale, 0.1)))
        walk.calculationMode = .linear
        f.layer.add(walk, forKey: "walk")
        f.tag.add(walk, forKey: "walk")
        f.voice.add(walk, forKey: "walk")
        // not the end's zPosition from the start: the order along the way, so two crossing are right.
        if let depth = walkDepth(f, along: points, lengths: lengths, duration: walk.duration) {
            for part in [f.layer, f.tag, f.voice] { part.add(depth, forKey: Self.walkDepthKey) }
        } else {
            for part in [f.layer, f.tag, f.voice] { part.removeAnimation(forKey: Self.walkDepthKey) }
        }
        f.route = points
        f.walkEnds = CACurrentMediaTime() + walk.duration
        // running as it goes, the office's rows and pace, leg by leg; its pose's loop shows again on arrival (the
        // loop waits for the walk's end, so it never covers the running frames).
        f.sprite.removeAnimation(forKey: "steps")
        if let steps = Self.runningSteps(f.pet, route: points, seconds: walk.duration) { f.sprite.add(steps, forKey: "steps") }
        if let loop = f.sprite.animation(forKey: "loop")?.copy() as? CAAnimation {
            f.sprite.removeAnimation(forKey: "loop")
            loop.beginTime = f.sprite.convertTime(f.walkEnds, from: nil)
            f.sprite.add(loop, forKey: "loop")
        }
        // Waiting for you, it starts to knock on arrival, as the loop does.
        if let id = figures.first(where: { $0.value === f })?.key { knock(f, id: id) }
    }

    /// Waiting for you, a figure stands on one frame and knocks every three seconds, turning about its feet, from the end
    /// of its walk; with Reduce Motion it does not lean but wears a coral ring that fades between full and a quarter
    /// strength. Core Animation, put in once; a still picture shows neither.
    private func knock(_ f: Figure, id: String) {
        f.sprite.removeAnimation(forKey: WaitingNudge.tiltKey)
        f.ring?.removeAnimation(forKey: WaitingNudge.ringKey)
        guard f.pose == .waiting, f.hasPet, WaitingNudge.enabled, !still, f.facing == nil else {
            f.ring?.removeFromSuperlayer()
            f.ring = nil
            return
        }
        let phase = WaitingNudge.phase(of: id)
        let begin = f.walkEnds > CACurrentMediaTime() ? f.sprite.convertTime(f.walkEnds, from: nil) : 0
        if calm {
            let rect = WaitingNudge.ringRect(wide: f.drawnWide, high: -f.headTop, down: WaitingNudge.flipped(f.sprite))
            if f.ring == nil || f.ring?.path?.boundingBox != rect {
                f.ring?.removeFromSuperlayer()
                let ring = WaitingNudge.ring(rect: rect, corner: min(rect.width, rect.height) * 0.3, width: 2 * max(fit.scale, 0.8))
                ring.opacity = 0  // shown only while its fade runs
                f.ring = ring
                f.layer.addSublayer(ring)
            }
            f.ring?.add(WaitingNudge.pulse(phase: phase, begin: begin), forKey: WaitingNudge.ringKey)
        } else {
            f.ring?.removeFromSuperlayer()
            f.ring = nil
            f.sprite.add(WaitingNudge.tilt(pivot: WaitingNudge.feetPivot(of: f.sprite), flipped: WaitingNudge.flipped(f.sprite), phase: phase, begin: begin),
                         forKey: WaitingNudge.tiltKey)
        }
    }

    /// The running frames for a walk along `route` (view points), from the pet's sheet; nil without a pet or frames.
    static func runningSteps(_ pet: String?, route: [CGPoint], seconds: Double) -> CAKeyframeAnimation? {
        guard let pet else { return nil }
        var frames: [Int: [CGImage]] = [:]
        for row in Set(ZoneWalk.rows(route)) {
            frames[row] = (0..<ZoneWalk.frames).compactMap { OfficePets.shared.runFrame(pet, facing: row, column: $0)?.image }
        }
        return ZoneWalk.steps(frames, route: route, seconds: seconds)
    }

    private func dress(_ f: Figure, _ s: Session, _ store: Store, _ scene: ZoneScene, _ config: ZoneConfig, now: Date) {
        let pet = store.displayPets[s.id]
        // At check-in it stands and waits to be placed: the idle standing frame, whatever it is doing.
        let checkIn = plan.place[s.id] == .checkIn
        let visit = visits.visits[s.id]
        // A visitor stands by its host, as one does to say a word.
        // seen, however long ago, is the still standing frame here (the office's sleeping one is for its rest area).
        let own = store.pose(of: s, now: now)
        let pose = checkIn || visit != nil || own == .sleeping ? Pose.standing : own
        f.pose = pose
        let tone = store.failTone(s)
        f.asking = plan.queue == s.id
        // times its own size step (right-click → bigger / smaller); the plate, bubbles, badge, spinner, beam and hit test
        // all go by the sprite's frame and head drawn from this.
        // And times its pet's own size (pet.json `"scale"`, `OfficePets.size`; 1 for nearly every pet), the same way.
        let tall = scene.petHeight * fit.scale * store.figureSize(s) * (pet.map { OfficePets.shared.size($0) } ?? 1)
        // a visitor turns to its host: its sheet's running frame that way, held (1 to the right, 2 to the left; by
        // the facing table, `OfficePets.runFrame`).
        let facing = visit.map { $0.hostAt.x >= f.spot.x ? ZoneWalk.right : ZoneWalk.left }
        f.facing = facing
        let spriteKey = "\(pet ?? "-") \(pose) \(tall) \(still) \(calm) \(facing ?? 0) \(WaitingNudge.enabled) \(tone == .gone)"
        var head = CGRect(x: -tall * 0.35, y: -tall, width: tall * 0.7, height: tall)
        if spriteKey != f.spriteKey {
            f.spriteKey = spriteKey
            f.sprite.removeAnimation(forKey: "loop")
            defer { knock(f, id: s.id) }
            if let pet, let idle = OfficePets.shared.frame(pet, row: 0, column: 0),
                let shown = facing.flatMap({ OfficePets.shared.runFrame(pet, facing: $0, column: 0) })
                    ?? OfficePets.shared.frame(pet, row: pose.sheet.row, column: pose.sheet.still) ?? Optional(idle)
            {
                let k = ZoneScene.petFactor(tall: idle.tall, wide: idle.wide, target: tall)
                f.factor = k
                f.headTop = -CGFloat(idle.bottom + 1 - idle.top) * k
                f.drawnWide = CGFloat(idle.wide) * k
                let middle = CGFloat(idle.left + idle.right + 1) / 2
                f.sprite.frame = CGRect(x: -middle * k, y: -CGFloat(idle.bottom + 1) * k,
                                        width: CGFloat(shown.image.width) * k, height: CGFloat(shown.image.height) * k)
                f.sprite.contents = shown.image
                f.hasPet = true
                f.sprite.opacity = tone == .gone ? 0.45 : pose == .sleeping ? 0.8 : 1  // an exit stands faint
                if pose.sheet.frames > 1, !still, facing == nil {
                    // while it walks, its running frames show (`steps`); the pose's loop starts on arrival, not over them.
                    var frames: [CGImage] = []
                    for column in 0..<pose.sheet.frames {
                        if let frame = OfficePets.shared.frame(pet, row: pose.sheet.row, column: column) { frames.append(frame.image) }
                    }
                    if frames.count > 1 {
                        let loop = CAKeyframeAnimation(keyPath: "contents")
                        loop.values = frames
                        loop.calculationMode = .discrete
                        loop.duration = pose.sheet.ms / 1000 * Double(frames.count)
                        loop.repeatCount = .infinity
                        if f.walkEnds > CACurrentMediaTime() { loop.beginTime = f.sprite.convertTime(f.walkEnds, from: nil) }
                        f.sprite.add(loop, forKey: "loop")
                    }
                }
            } else {
                // No pet to draw (yet): a soft token in its place, so the seat still reads as taken.
                f.sprite.frame = CGRect(x: -tall * 0.3, y: -tall * 0.75, width: tall * 0.6, height: tall * 0.75)
                f.sprite.contents = ZoneGlow.disc(0xC9D6E8)
                f.headTop = -tall * 0.75
                f.drawnWide = tall * 0.6
                f.hasPet = false
                f.factor = nil
                f.sprite.opacity = 0.9
            }
        }
        if f.sprite.contents != nil { head = f.sprite.frame }

        // The plate under its feet: the name without its zone prefix, ★ for the lead, checking in while being checked in, and the
        // awaiting-reply pin's coral dot on a finished one the user pinned (as the office's plate has it).
        let lead = config.prefix(of: s.name).flatMap { config.zone($0)?.lead } == s.name
        let checking = ZonePendingFile.entry(for: s, config: config) != nil && config.resolve(name: s.name, cwd: s.cwd) == nil
        // an error, a retry, the limit or an exit says so after the name (e.g. "reconcile-script · API error 529"), the plate in its tone.
        let words = (lead ? "★ " : "") + config.plate(s.shownName) + (checking ? " · " + L10n.string("checkin.active", table: "Zone", zh: "报到中") : "") + (tone != nil ? failShortWords(s).map { " · " + $0 } ?? "" : "")
        let pinned = s.status == "idle" && store.pinned.contains(s.id)
        f.pinned = pinned
        // on a sofa seat, over its head when the view's bottom edge would cut the plate (`sofaPlatesLifted`).
        var seated = false
        if case .sofaSeat? = plan.place[s.id], visit == nil { seated = true }
        let lifted = seated && sofaPlatesLifted
        let plateKey = "\(words) \(fit.scale) \(pinned) \(lifted) \(f.headTop) \(String(describing: tone))"
        if plateKey != f.plateKey {
            f.plateKey = plateKey
            f.lifted = lifted
            let drawn = ZoneGlow.plate(words, scale: fit.scale, gold: lead, pin: pinned, tone: tone)
            f.plate.contents = drawn.image
            f.plate.frame = CGRect(x: -drawn.size.width / 2, y: 0, width: drawn.size.width, height: drawn.size.height)
            f.plate.frame.origin.y = plateBase(f) - f.nudge
        }

        // bubbles go by the drawn head's top, not the sheet cell's (a 150 px pet's cell reaches far above its head).
        let top = f.hasPet ? f.headTop : head.minY
        // Over the head: the queue head says what it wants; a visitor says its word; one done and not looked at shows a
        // small bubble.
        let unread = s.status == "idle" && store.isUnread(s)
        let asks = plan.queue == s.id ? (s.summary.isEmpty ? s.waitingFor : s.shownSummary) : ""
        // a send-off-duty the script refused says so over the head for a while.
        let refused = plan.queue != s.id && !s.registryName.isEmpty && ZoneOffDuty.shared.refused(s.registryName)
        f.saying = visit != nil && plan.queue != s.id && !refused
        let bubbleKey = plan.queue == s.id ? "ask \(s.name) \(asks) \(fit.scale) \(top)"
            : refused ? "refused \(fit.scale) \(top)"
            : f.saying ? "say \(visit?.words ?? "") \(fit.scale) \(top) \(facing ?? 0)" : unread ? "dot \(fit.scale) \(top) \(f.lifted)" : ""
        if bubbleKey != f.bubbleKey {
            f.bubbleKey = bubbleKey
            if refused {
                let drawn = ZoneGlow.say(Self.refusedWords, scale: fit.scale)
                f.bubble.contents = drawn.image
                f.bubble.frame = CGRect(x: -drawn.size.width * 0.3, y: top - drawn.size.height - 2 * fit.scale,
                                        width: drawn.size.width, height: drawn.size.height)
            } else if f.saying, let visit {
                // it leans away from its host, so it does not cover the host's head and tool badge.
                let tail: CGFloat = facing == ZoneWalk.right ? 0.9 : 0.3
                let drawn = ZoneGlow.say(visit.words, scale: fit.scale, tail: tail)
                f.bubble.contents = drawn.image
                f.bubble.frame = CGRect(x: -drawn.size.width * tail, y: top - drawn.size.height - 2 * fit.scale,
                                        width: drawn.size.width, height: drawn.size.height)
            } else if plan.queue == s.id {
                // The line runs on to the right behind the head: the bubble leans left, its tail over the head.
                let drawn = ZoneGlow.ask(config.plate(s.shownName), asks.isEmpty ? L10n.string("zone.row.waiting", table: "Zone", zh: "在等你") : asks, scale: fit.scale, tail: 0.78)
                f.bubble.contents = drawn.image
                f.bubble.frame = CGRect(x: -drawn.size.width * 0.78, y: top - drawn.size.height - 3 * fit.scale,
                                        width: drawn.size.width, height: drawn.size.height)
            } else if unread {
                let drawn = ZoneGlow.dots(scale: fit.scale)
                f.bubble.contents = drawn.image
                f.bubble.frame = CGRect(x: head.maxX - drawn.size.width * 0.4, y: top - drawn.size.height * 0.8,
                                        width: drawn.size.width, height: drawn.size.height)
                dotsBesidePlate(f)
            } else {
                f.bubble.contents = nil
            }
        }
        toolBadge(f, s, busy: s.status == "busy" && atDesk(s.id) && visit == nil)
        restartMark(f, s, head: f.hasPet ? CGRect(x: head.minX, y: top, width: head.width, height: max(1, -top)) : head)
        wearAura(f, s, tall: tall)
    }

    /// a Fable session wears the aura wherever it is, in the figure's own layer under its pet (walks carry
    /// it); full flames while busy, a calm glow otherwise. Shaped again only when its size, busy-ness or motion changes.
    private func wearAura(_ f: Figure, _ s: Session, tall: CGFloat) {
        // Settings > sea room > flame-and-lightning possession off: no aura (nor its lightning), read at each refresh.
        guard s.isFable, zoneAuraOn() else {
            f.aura?.removeFromSuperlayer()
            f.aura = nil
            f.bolts?.removeFromSuperlayer()
            f.bolts = nil
            return
        }
        let aura = f.aura ?? ZoneAura.make()
        if aura.superlayer !== f.layer {
            f.layer.insertSublayer(aura, below: f.sprite)
            f.aura = aura
        }
        // Settings > sea room > lightning off: the aura without its lightning holder. Either way round, the aura is shaped again.
        var bolts: CALayer? = nil
        if zoneLightningOn() {
            let holder = f.bolts ?? ZoneAura.makeBolts()
            if holder.superlayer !== f.layer {
                f.layer.insertSublayer(holder, above: f.sprite)
                f.bolts = holder
                aura.setValue(nil, forKey: "shaped")
            }
            bolts = holder
        } else if f.bolts != nil {
            f.bolts?.removeFromSuperlayer()
            f.bolts = nil
            aura.setValue(nil, forKey: "shaped")
        }
        let wide = f.drawnWide > 0 ? f.drawnWide : tall * 0.6, high = f.headTop < 0 ? -f.headTop : tall * 0.75
        // it hugs the frame the pet shows in this pose (its still frame; the loop's and the run's frames are its kin).
        let shown = f.sprite.contents.map { $0 as AnyObject }.flatMap { CFGetTypeID($0) == CGImage.typeID ? ($0 as! CGImage) : nil }
        ZoneAura.shape(aura, sprite: shown, frame: f.sprite.frame, wide: wide, high: high, busy: s.status == "busy", moving: !still && !calm,
                         seed: s.id, phase: auraPhase, bolts: bolts)
    }

    /// over a busy one's head at its desk, what it is doing (`Session.tool`): a small round badge, set again only when
    /// the tool's family changes.
    private func toolBadge(_ f: Figure, _ s: Session, busy: Bool) {
        guard busy else {
            f.badge.contents = nil
            f.badgeFamily = nil
            return
        }
        let family = ZoneToolIcon.family(tool: s.tool)
        let side = 18 * max(0.8, fit.scale / 0.494)
        let frame = CGRect(x: -side / 2, y: f.headTop - side - 3 * max(fit.scale, 0.5), width: side, height: side)
        if f.badgeFamily != family || f.badge.frame != frame {
            f.badgeFamily = family
            f.badge.contents = ZoneToolIcon.badge(family, size: 18, scale: 2 * side / 18)
            f.badge.frame = frame
        }
    }

    /// a session's helpers (`Store.walkerPets`: its running subagents and its work in the background, counted once)
    /// as mini figures walking its desk's near edge and back, clear of the screen; up to three, a "+N" pill over the rest. Each
    /// is one layer with two repeating animations (`BGWalker`), the render server's; a picture or Reduce Motion shows them
    /// standing. Hung work stands grey. In the stage, as deep as the desk's own foreground layer: in front of it, where the
    /// figures stand on its edge, and behind whoever stands in front of the desk (their order is a hair above the desk's).
    /// Made again only when the helpers, their state or the room's size change.
    private func placeAgents(_ f: Figure, _ s: Session, _ store: Store, _ scene: ZoneScene, at desk: Bool) {
        let pets = store.walkerPets(of: s)
        let hung = s.isBackgroundHung
        guard desk, s.isWorking || hung, !pets.isEmpty, atDesk(s.id), let id = plan.desks[s.id], let art = scene.desk(id), let near = art.near
        else {
            f.agents?.removeFromSuperlayer()
            f.agents = nil
            f.agentsKey = ""
            return
        }
        let edge = agentEdge(art, near)
        let mode: BGWalker.Mode = hung ? .hung : still ? .caught(BGWalker.stillTime) : calm ? .stands : .walks
        let deskZ = deskLayers[id]?.holder.zPosition
        let key = "\(pets) \(mode) \(edge) \(fit.scale) \(scene.petHeight) \(deskZ ?? -1)"
        guard key != f.agentsKey || f.agents?.superlayer == nil else { return }
        let holder = CALayer()
        holder.frame = .zero
        holder.masksToBounds = false
        holder.name = "subagents"
        let ph = scene.petHeight * fit.scale * ZoneSubagentFigures.height
        // The lane: the near edge, a little past its ends, left end first (they run right first).
        var a = edge.0, b = edge.1
        if a.x > b.x { swap(&a, &b) }
        func along(_ u: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u) }
        let shown = pets.prefix(ZoneSubagentFigures.shown)
        for (i, pet) in shown.enumerated() {
            guard let cut = ZoneSubagentFigures.deskCut(pet, square: ph) else { return }  // not cut yet: tried again at the next look
            let rest = shown.count > 1 ? 0.2 + 0.6 * CGFloat(i) / CGFloat(shown.count - 1) : 0.5
            guard let walker = BGWalker.layer(cut, from: along(-0.15), to: along(1.15), yDown: true, mode: mode, phase: BGWalker.phase(s.id, i), rest: rest, smooth: false)
            else { return }
            holder.addSublayer(walker)
        }
        if pets.count > shown.count {
            let pill = ZoneSubagentFigures.pill("+\(pets.count - shown.count)", scale: fit.scale)
            let part = CALayer()
            let m = along(0.5)
            part.name = "more"
            part.contents = pill.image
            part.frame = CGRect(x: m.x - pill.size.width / 2, y: m.y - ph - pill.size.height, width: pill.size.width, height: pill.size.height)
            holder.addSublayer(part)
        }
        f.agentsKey = key
        f.agents?.removeFromSuperlayer()
        holder.zPosition = deskZ.map { $0 + 0.005 * max(fit.scale, 0.1) } ?? max(edge.0.y, edge.1.y)
        stage.addSublayer(holder)
        f.agents = holder
    }

    /// The near edge the mini figures stand on, in the view: a little in from the corners and from the rim, on the top.
    private func agentEdge(_ art: ZoneScene.Desk, _ near: (CGPoint, CGPoint)) -> (CGPoint, CGPoint) {
        var middle = CGPoint.zero
        for p in art.top { middle = CGPoint(x: middle.x + p.x / CGFloat(art.top.count), y: middle.y + p.y / CGFloat(art.top.count)) }
        func pull(_ p: CGPoint, _ toward: CGPoint, _ t: CGFloat) -> CGPoint { CGPoint(x: p.x + (toward.x - p.x) * t, y: p.y + (toward.y - p.y) * t) }
        let a = pull(near.0, middle, 0.05), b = pull(near.1, middle, 0.05)
        return (fit.point(a), fit.point(b))
    }

    /// The rest room's "+N" pill (those resting beyond its seats, not drawn), just right of its sofa.
    private func placeRest(_ scene: ZoneScene) {
        let extra = plan.restOverflow.count
        guard extra > 0, let area = scene.restArea else {
            restPill.contents = nil
            restPillKey = ""
            return
        }
        // On the rest room's floor right of the armchairs, clear of the top edge (the sofa's sitters reach it).
        let low = scene.restSeats.max { $0.y < $1.y } ?? CGPoint(x: area.midX, y: area.maxY)
        let drawn = ZoneGlow.pill("+\(extra)", scale: fit.scale)
        // 12 pt clear of every head (the top 40 % of each pet as drawn): right of the armchairs, else on their left,
        // else raised a pill's height or two at a time on either side; else where it was.
        let heads = figures.values.map { f -> CGRect in
            let p = fit.point(f.spot)
            return CGRect(x: p.x - f.drawnWide / 2, y: p.y + f.headTop, width: f.drawnWide, height: -f.headTop * 0.4).insetBy(dx: -12, dy: -12)
        }
        let leftmost = scene.restSeats.min { $0.x < $1.x } ?? low
        let right = fit.point(CGPoint(x: low.x + scene.petHeight * 1.15, y: low.y - scene.petHeight * 0.15))
        let left = fit.point(CGPoint(x: leftmost.x - scene.petHeight * 0.9, y: low.y - scene.petHeight * 0.15))
        let rise = drawn.size.height * 1.5
        var tries = [right, left]
        for k in 1...4 { tries += [CGPoint(x: right.x, y: right.y - rise * CGFloat(k)), CGPoint(x: left.x, y: left.y - rise * CGFloat(k))] }
        func box(_ c: CGPoint) -> CGRect { CGRect(x: c.x - drawn.size.width / 2, y: c.y - drawn.size.height / 2, width: drawn.size.width, height: drawn.size.height) }
        let at = tries.first { c in bounds.insetBy(dx: 2, dy: 26).contains(box(c)) && !heads.contains { $0.intersects(box(c)) } } ?? right
        let key = "\(extra) \(at) \(fit.scale)"
        guard key != restPillKey else { return }
        restPillKey = key
        restPill.contents = drawn.image
        restPill.frame = CGRect(x: at.x - drawn.size.width / 2, y: at.y - drawn.size.height / 2, width: drawn.size.width, height: drawn.size.height)
    }

    /// The office's spotlight on the session the user types in, in Orca (`Store.focused`, the office's switch): the office's disco
    /// light (`ZoneDisco`: ball, spots, lasers, cone and pool) round its pet, half as strong while Orca is behind and
    /// then held still, fading in and out in 0.3 s; taken away once faded out.
    private func spotlight(_ store: Store, _ scene: ZoneScene) {
        let lit = officeSpotlight() ? store.focused : nil
        let strength: Float = store.orcaInFront ? 1 : 0.5
        let tall = scene.petHeight * fit.scale
        let moving = !still && !calm && window != nil
        for (id, f) in figures {
            let wanted: Float = id == lit ? strength : 0
            guard wanted > 0 || f.beam != nil else { continue }
            let beam = f.beam ?? ZoneDisco.make()
            if f.beam == nil {
                f.beam = beam
                f.layer.insertSublayer(beam, at: 0)
            }
            let wide = f.drawnWide > 0 ? f.drawnWide : tall * 0.7, high = f.headTop < 0 ? -f.headTop : tall
            ZoneDisco.shape(beam, wide: wide, high: high, ceiling: fit.point(f.spot).y, moving: moving, phase: still ? OfficeView.stillPhase : 0)
            ZoneDisco.hold(beam, moving && (!store.orcaInFront || wanted == 0))
            guard beam.opacity != wanted else { continue }
            let from = beam.presentation()?.opacity ?? beam.opacity
            beam.opacity = wanted
            guard !still, window != nil else {
                if wanted == 0 {
                    beam.removeFromSuperlayer()
                    f.beam = nil
                }
                continue
            }
            CATransaction.begin()
            if wanted == 0 {
                CATransaction.setCompletionBlock { [weak f, weak beam] in
                    guard let f, let beam, f.beam === beam, beam.opacity == 0 else { return }
                    beam.removeFromSuperlayer()
                    f.beam = nil
                }
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = from
            fade.toValue = wanted
            fade.duration = 0.3
            beam.add(fade, forKey: "fade")
            CATransaction.commit()
        }
    }

    /// The light as the store has it now, outside an update (a click's).
    private func lightNow(_ store: Store) {
        guard let scene = ZoneArt.scene, !figures.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spotlight(store, scene)
        CATransaction.commit()
    }

    /// one being restarted wears the spinner by its head and stays where it is.
    private func restartMark(_ f: Figure, _ s: Session, head: CGRect) {
        guard s.restarting else {
            f.spinner?.removeFromSuperlayer()
            f.spinner = nil
            return
        }
        let side = RestartSpinner.side * max(fit.scale, 0.8)
        if f.spinner?.bounds.width != side {
            f.spinner?.removeFromSuperlayer()
            f.spinner = RestartSpinner.layer(side: side)
        }
        guard let spinner = f.spinner else { return }
        if spinner.superlayer !== f.layer { f.layer.addSublayer(spinner) }
        var avoid: [CGRect] = []
        if f.bubble.contents != nil { avoid.append(f.bubble.frame) }
        if f.badge.contents != nil { avoid.append(f.badge.frame) }
        spinner.frame = RestartSpinner.spot(head: head, side: side, avoid: avoid)
        RestartSpinner.spin(spinner, !still && !calm && window != nil)
    }

    // ───────── The pointer ─────────

    /// A figure's body and plate, in this view, where it is now.
    private func body(_ f: Figure) -> CGRect {
        let at = shownAt(f)
        return f.sprite.frame.union(f.plate.frame).offsetBy(dx: at.x, dy: at.y)
    }

    /// Where a figure is now: its place, or mid-walk where Core Animation shows it.
    private func shownAt(_ f: Figure) -> CGPoint { still ? f.layer.position : f.layer.presentation()?.position ?? f.layer.position }

    /// the pet frame on screen right now (a loop or a walk changes `contents` over time), with its mask; nil for the token.
    private func shownMask(_ f: Figure) -> ZoneHitMask.Mask? {
        guard f.hasPet else { return nil }
        let contents = still ? f.sprite.contents : f.sprite.presentation()?.contents ?? f.sprite.contents
        guard let contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return ZoneHitMask.mask(contents as! CGImage)
    }

    private func frontToBack() -> [Figure] { figures.values.sorted { $0.layer.zPosition > $1.layer.zPosition } }

    /// what is drawn at this point, front first. The plates are over every pet, so a plate first; then a pet's opaque
    /// pixel (the sprite is stretched to its frame, `contentsGravity` .resize, no mirroring: a facing is its own sheet row),
    /// or the token's rectangle.
    private func drawn(at point: CGPoint, front: [Figure]) -> Figure? {
        for f in front where f.plate.contents != nil && f.plate.frame.offsetBy(dx: shownAt(f).x, dy: shownAt(f).y).contains(point) { return f }
        for f in front {
            let at = shownAt(f), frame = f.sprite.frame.offsetBy(dx: at.x, dy: at.y)
            guard f.sprite.contents != nil, frame.contains(point), frame.width > 0, frame.height > 0 else { continue }
            guard f.hasPet else { return f }
            if let mask = shownMask(f), mask.opaque(u: (point.x - frame.minX) / frame.width, v: (point.y - frame.minY) / frame.height) { return f }
        }
        return nil
    }

    /// with nothing drawn at the point, the one whose box holds it and whose drawn part's middle is nearest.
    private func nearest(at point: CGPoint, front: [Figure]) -> Figure? {
        func middle(_ f: Figure) -> CGPoint {
            let at = shownAt(f), frame = f.sprite.frame.offsetBy(dx: at.x, dy: at.y)
            guard let solid = shownMask(f)?.solid else { return CGPoint(x: frame.midX, y: frame.midY) }
            return CGPoint(x: frame.minX + solid.midX * frame.width, y: frame.minY + solid.midY * frame.height)
        }
        return front.filter { body($0).contains(point) }.min { a, b in
            let p = middle(a), q = middle(b)
            return hypot(p.x - point.x, p.y - point.y) < hypot(q.x - point.x, q.y - point.y)
        }
    }

    private func publish(_ store: Store) {
        let host = window?.contentView ?? self
        var frames: [String: CGRect] = [:]
        for (id, f) in figures { frames[id] = convert(body(f), to: host) }
        for (key, sign) in signs where sign.contents != nil { frames[zoneListPrefix + key] = convert(sign.frame, to: host) }
        if let area = restTarget() { frames[ZoneUI.restKey] = convert(area, to: host) }
        for (key, rect) in store.tracker.frames where key.hasPrefix(zoneListPrefix) && key.contains("/") { frames[key] = rect }
        if store.tracker.frames != frames { store.tracker.frames = frames }
        if store.tracker.resolver !== self { store.tracker.resolver = self }
    }

    /// What a click here is for: the figure drawn there (its plate or an opaque pixel of its pet, the front one first;
    /// else the nearest whose box holds the point), or a sign (its list).
    func target(at point: CGPoint) -> Target? {
        let front = frontToBack()
        if let f = drawn(at: point, front: front) ?? nearest(at: point, front: front) { return .pet(f.layer.name ?? "") }
        for (key, sign) in signs where sign.contents != nil && sign.frame.insetBy(dx: -3, dy: -3).contains(point) {
            return .list(zoneListPrefix + key)
        }
        if restPill.contents != nil, restPill.frame.insetBy(dx: -3, dy: -3).contains(point) { return .list(ZoneUI.restKey) }
        if let area = restFloor(), area.contains(point) { return .list(ZoneUI.restKey) }
        return nil
    }

    /// The rest room's floor in the view, while anyone rests there.
    private func restFloor() -> CGRect? {
        guard !plan.rest.isEmpty || !plan.restOverflow.isEmpty, let area = ZoneArt.scene?.restArea else { return nil }
        return fit.rect(area)
    }

    /// What the rest room's list goes beside: the pill when it shows, else the floor.
    private func restTarget() -> CGRect? {
        guard let floor = restFloor() else { return nil }
        return restPill.contents != nil ? restPill.frame : floor
    }

    /// For the pointer, in the window's view: a row of the open list, the list itself, else what a click would hit.
    func card(at point: CGPoint) -> String? {
        if liftedID != nil { return nil }  // no hover card while a figure is carried
        if let open = ZoneUI.open, let store {
            for (key, rect) in store.tracker.frames where key.hasPrefix(open + "/") && rect.contains(point) {
                if !key.hasSuffix("/card") && !key.hasSuffix("/gap") && !key.hasSuffix("/close") { return key }
            }
            for suffix in ["/card", "/gap"] where store.tracker.frames[open + suffix]?.contains(point) == true { return open }
        }
        switch target(at: convert(point, from: window?.contentView ?? self)) {
        case .pet(let id): return id
        case .list(let key): return key
        case nil: return nil
        }
    }

    // a press may become a long-press (`press`, `drag`, `release`); a short one is the click it always was. The view
    // takes the first mouse, so the drag reaches it in the panel that is never key, as the clicks do.
    override func mouseDown(with event: NSEvent) { press(at: convert(event.locationInWindow, from: nil)) }

    override func mouseDragged(with event: NSEvent) { drag(to: convert(event.locationInWindow, from: nil)) }

    override func mouseUp(with event: NSEvent) { release(at: convert(event.locationInWindow, from: nil)) }

    // ───────── long-press a figure, drag it to another desk of its zone ─────────

    /// How long a press must be held, still, before the figure lifts; how far the pointer may wander meanwhile. 0.8 s,
    /// and 10 pt, since a trackpad press drifts a few points and 4 ended the hold unseen.
    static let holdSeconds: Double = 0.8
    static let holdSlop: CGFloat = 10
    /// from this far into the hold the figure grows toward its lifted size, so the user sees it is about to lift.
    static let growAfter: Double = 0.3
    static let preliftGrow: CGFloat = 1.08
    static let preliftKey = "jumpMark.prelift"
    /// The one lifted now, nil when none.
    private(set) var liftedID: String?
    /// For checks: instead of jumping to the session on a click.
    var onClick: ((Session) -> Void)?
    private var hold: DispatchWorkItem?
    private var holding: String?
    private var downAt: CGPoint?
    /// when the press began, by `pressClock` (a check's own clock): the hold is judged by it too, not only by its work
    /// item, so a main queue busy past the hold still lifts on the next drag.
    var pressClock: () -> CFTimeInterval = { CACurrentMediaTime() }
    private(set) var pressedAt: CFTimeInterval = 0
    /// The grow during the hold on the held figure, nil when none.
    var preliftAnimation: CABasicAnimation? {
        holding.flatMap { figures[$0]?.layer.animation(forKey: Self.preliftKey) as? CABasicAnimation }
    }
    private var holdOver: Bool { hold != nil && pressClock() - pressedAt >= Self.holdSeconds }
    /// The figure's feet from the pointer, as it was picked up.
    private var liftOffset = CGVector.zero
    /// The lifted one's zone's desks it may go to (2–12, not its own), their spots in the view, the desk pitch there.
    private var targets: [ZoneDesk: CGPoint] = [:]
    private var pitch: CGFloat = 0
    private var marks: [ZoneDesk: CAShapeLayer] = [:]
    private var strong: ZoneDesk?
    private var escWatchers: [Any] = []

    /// Whether this figure may be picked up: drawn, zoned, owning a desk that is not desk 1 (so not its zone's lead).
    /// One away from its desk (sofa, line) may: its desk is what moves.
    func canLift(_ id: String) -> Bool {
        guard figures[id] != nil, let desk = plan.desks[id], desk.index >= 2, store?.sessions.contains(where: { $0.id == id }) == true else { return false }
        switch plan.place[id] {
        case .rest?, .restListed?, .checkIn?, .checkInListed?, nil: return false
        default: return true
        }
    }

    /// Mouse down: what it is on; on a figure that may be lifted, the 2 s hold starts (one work item, no timer per frame).
    func press(at point: CGPoint) {
        endHold()
        pressed = target(at: point)
        downAt = point
        guard case .pet(let id)? = pressed, canLift(id) else { return }
        let work = DispatchWorkItem { [weak self] in self?.holdNow() }
        hold = work
        holding = id
        pressedAt = pressClock()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds, execute: work)
        // growing a little from 0.3 s until the lift; one animation, none with Reduce Motion.
        if !calm, let f = figures[id] {
            let grow = CABasicAnimation(keyPath: "transform")
            grow.fromValue = NSValue(caTransform3D: f.layer.transform)
            grow.toValue = NSValue(caTransform3D: CATransform3DScale(f.layer.transform, Self.preliftGrow, Self.preliftGrow, 1))
            grow.beginTime = f.layer.convertTime(CACurrentMediaTime(), from: nil) + Self.growAfter
            grow.duration = Self.holdSeconds - Self.growAfter
            grow.fillMode = .forwards
            grow.isRemovedOnCompletion = false
            f.layer.add(grow, forKey: Self.preliftKey)
        }
    }

    /// The hold has lasted (the work item, or a check at once).
    func holdNow() {
        guard hold != nil, let id = holding else { return }
        endHold()
        lift(id)
    }

    private func endHold() {
        if let id = holding { figures[id]?.layer.removeAnimation(forKey: Self.preliftKey) }
        hold?.cancel()
        hold = nil
        holding = nil
    }

    /// The pointer moved with the button down: before the lift, too far ends the hold; lifted, the figure follows.
    func drag(to point: CGPoint) {
        if let id = liftedID, let f = figures[id] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let at = CGPoint(x: point.x + liftOffset.dx, y: point.y + liftOffset.dy)
            for part in [f.layer, f.tag, f.voice] { part.position = at }
            CATransaction.commit()
            light(deskAt(point))
            return
        }
        if hold != nil, let downAt, hypot(point.x - downAt.x, point.y - downAt.y) > Self.holdSlop { return endHold() }
        // the hold is over but its work item has not run (the main queue busy): lift now, then follow the pointer.
        if holdOver {
            holdNow()
            if liftedID != nil { drag(to: point) }
        }
    }

    /// Mouse up: lifted, a drop (a swap, a move, or back where it was); else the click it always was. True for a click.
    @discardableResult func release(at point: CGPoint) -> Bool {
        // held past the hold with its work item late: the user held it, so it is no click; nothing was lifted to drop.
        let heldLong = holdOver
        endHold()
        defer {
            pressed = nil
            downAt = nil
        }
        if let id = liftedID {
            drop(id, at: point)
            return false
        }
        if heldLong { return false }
        let released = target(at: point)
        guard let store else { return false }
        guard let pressed, pressed == released else {
            if ZoneUI.open != nil && released == nil {
                ZoneUI.open = nil
                store.objectWillChange.send()
            }
            return false
        }
        switch pressed {
        case .pet(let id):
            guard let s = store.sessions.first(where: { $0.id == id }) else { return false }
            store.markSeen(s)
            // Lit at once, its fade begun on this click, not on SwiftUI's next pass nor on the next look at Orca.
            if store.expectFocus(s) { lightNow(store) }
            if let onClick { onClick(s) } else { jump(to: s, expect: false) }
        case .list(let key):
            ZoneUI.open = ZoneUI.open == key ? nil : key
            store.objectWillChange.send()
        }
        return true
    }

    /// Esc, or the figure gone from under it: it settles back where it was.
    func cancelLift() {
        guard let id = liftedID, let f = figures[id] else {
            endLift()
            return
        }
        let from = f.layer.position
        endLift()
        settle(f, from: from, home: true)
    }

    private func lift(_ id: String) {
        guard let f = figures[id], canLift(id), let desk = plan.desks[id], let scene = ZoneArt.scene, let downAt else { return }
        liftedID = id
        let foot = f.layer.position
        liftOffset = CGVector(dx: foot.x - downAt.x, dy: foot.y - downAt.y)
        if store?.hovered != nil { store?.hovered = nil }
        targets = [:]
        for art in scene.desks where art.zone == desk.zone && art.index >= 2 && art.index <= ZonePlan.desksPerZone && art.index != desk.index {
            targets[ZoneDesk(zone: art.zone, index: art.index)] = fit.point(art.seat)
        }
        let seats = scene.desks.filter { $0.zone == desk.zone }.map { fit.point($0.seat) }
        var nearest = CGFloat.greatestFiniteMagnitude
        for (i, p) in seats.enumerated() {
            for q in seats[(i + 1)...] where hypot(p.x - q.x, p.y - q.y) > 1 { nearest = min(nearest, hypot(p.x - q.x, p.y - q.y)) }
        }
        pitch = nearest < .greatestFiniteMagnitude ? nearest : 60 * fit.scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for part in [f.layer, f.tag, f.voice] {
            part.removeAnimation(forKey: "walk")
            part.removeAnimation(forKey: Self.walkDepthKey)
            part.position = foot
            part.zPosition = 1_000_000
        }
        f.sprite.removeAnimation(forKey: "steps")
        f.walkEnds = 0
        // Bigger and off the floor a little, so the desk mark under it shows.
        f.layer.transform = CATransform3DTranslate(CATransform3DMakeScale(Self.liftGrow, Self.liftGrow, 1), 0, -14 * fit.scale, 0)
        f.sprite.shadowColor = NSColor.black.cgColor
        f.sprite.shadowOpacity = 0.55
        f.sprite.shadowRadius = max(3, 9 * fit.scale)
        f.sprite.shadowOffset = CGSize(width: 0, height: max(6, 20 * fit.scale))
        let color = ZoneConfigFile.current().zone(desk.zone)?.color ?? 0xFFFFFF
        for (key, at) in targets {
            let mark = CAShapeLayer()
            let w = pitch * 0.9, h = w * 0.46
            mark.path = CGPath(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h), transform: nil)
            mark.position = at
            mark.name = key.key
            mark.setValue(color, forKey: "zoneColor")
            marksLayer.addSublayer(mark)
            marks[key] = mark
        }
        strong = nil
        paintMarks()
        CATransaction.commit()
        if !still && !calm {
            let jiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            jiggle.values = [0, 0.035, 0, -0.035, 0]
            jiggle.duration = 0.36
            jiggle.repeatCount = .infinity
            f.sprite.add(jiggle, forKey: "jiggle")
        }
        // The panel is never the key window: Esc reaches a local watcher only while the app is in front, a global one only
        // with the Accessibility permission. Dropping off a desk always cancels.
        let esc: (NSEvent) -> Void = { [weak self] e in if e.keyCode == 53 { DispatchQueue.main.async { self?.cancelLift() } } }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in
            esc(e)
            return e.keyCode == 53 ? nil : e
        }) { escWatchers.append(local) }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: esc) { escWatchers.append(global) }
    }

    /// How much bigger a lifted figure is.
    static let liftGrow: CGFloat = 1.14

    /// The desk under the pointer: the nearest of the targets' spots within half a desk pitch; nil elsewhere (desk 1, another
    /// zone, its own desk, the floor).
    private func deskAt(_ point: CGPoint) -> ZoneDesk? {
        guard liftedID != nil else { return nil }
        let best = targets.min { hypot($0.value.x - point.x, $0.value.y - point.y) < hypot($1.value.x - point.x, $1.value.y - point.y) }
        guard let best, hypot(best.value.x - point.x, best.value.y - point.y) <= pitch / 2 else { return nil }
        return best.key
    }

    private func light(_ desk: ZoneDesk?) {
        guard desk != strong else { return }
        strong = desk
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paintMarks()
        CATransaction.commit()
    }

    /// The targets soft in their zone's colour; the one under the pointer strong, ringed in white.
    private func paintMarks() {
        for (key, mark) in marks {
            let hex = (mark.value(forKey: "zoneColor") as? UInt32) ?? 0xFFFFFF
            let on = key == strong
            mark.fillColor = OfficeCanvas.rgb(hex, on ? 0.6 : 0.3)
            mark.strokeColor = on ? OfficeCanvas.rgb(0xFFFFFF, 0.95) : OfficeCanvas.rgb(0xFFFFFF, 0.55)
            mark.lineWidth = on ? max(2.5, 5 * fit.scale) : max(1.2, 2.5 * fit.scale)
            mark.transform = on ? CATransform3DMakeScale(1.15, 1.15, 1) : CATransform3DIdentity
            mark.shadowColor = OfficeCanvas.rgb(hex)
            mark.shadowOpacity = on ? 0.9 : 0
            mark.shadowRadius = max(3, 10 * fit.scale)
            mark.shadowOffset = .zero
        }
    }

    /// Back to normal size, no shadow, no marks, no Esc watchers.
    private func endLift() {
        if let id = liftedID, let f = figures[id] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            f.layer.transform = CATransform3DIdentity
            f.sprite.shadowOpacity = 0
            f.sprite.removeAnimation(forKey: "jiggle")
            let z = depth(f, at: fit.point(f.spot))
            for part in [f.layer, f.tag, f.voice] { part.zPosition = z }
            CATransaction.commit()
        }
        liftedID = nil
        strong = nil
        for mark in marks.values { mark.removeFromSuperlayer() }
        marks = [:]
        targets = [:]
        for watcher in escWatchers { NSEvent.removeMonitor(watcher) }
        escWatchers = []
    }

    /// Dropped: on a target desk the desks change (swap or move, kept by name) and everyone goes where the table now says
    /// (`move` walks one at its desk from where it was dropped); anywhere else it settles back.
    private func drop(_ id: String, at point: CGPoint) {
        guard let f = figures[id] else {
            endLift()
            return
        }
        let target = deskAt(point), from = f.layer.position
        endLift()
        guard let target, let store, ZoneMemory.move(store, plan: plan, mover: id, to: target) else {
            settle(f, from: from, home: true)
            return
        }
        update(store)
        // Not walking (away on a sofa or in the line, or a picture): it glides back to its place.
        if f.walkEnds <= CACurrentMediaTime() { settle(f, from: from, home: false) }
    }

    /// From where it was let go to its place: a short glide, or at once in a picture or with Reduce Motion.
    private func settle(_ f: Figure, from: CGPoint, home: Bool) {
        let end = fit.point(f.spot)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let z = depth(f, at: end)
        for part in [f.layer, f.tag, f.voice] {
            part.position = end
            part.zPosition = z
        }
        CATransaction.commit()
        guard !still, !calm, window != nil, hypot(end.x - from.x, end.y - from.y) > 1 else { return }
        let glide = CABasicAnimation(keyPath: "position")
        glide.fromValue = NSValue(point: from)
        glide.toValue = NSValue(point: end)
        glide.duration = 0.28
        glide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        for part in [f.layer, f.tag, f.voice] { part.add(glide, forKey: "settle") }
    }

    var highlightedDesks: [ZoneDesk] { Array(marks.keys) }
    var strongDesk: ZoneDesk? { strong }
    /// The largest figure scale shown (1 when none is lifted).
    var liftScale: CGFloat { figures.values.map { $0.layer.transform.m11 }.max() ?? 1 }

    // ───────── For checks and pictures ─────────

    var figureIDs: [String] { Array(figures.keys) }
    func shownPose(of id: String) -> Pose? { figures[id]?.pose }
    func asks(_ id: String) -> Bool { figures[id]?.asking ?? false }
    /// The pet's picture as drawn and its frame in the view, for measuring; nil while it shows the token.
    func sprite(of id: String) -> (image: CGImage, frame: CGRect)? {
        guard let f = figures[id], f.hasPet, let contents = f.sprite.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage, f.sprite.frame)
    }
    func foot(of id: String) -> CGPoint? { figures[id]?.layer.position }
    /// for checks and the live probe: a walk's route (view points) and end (media time); the sprite's frame and the
    /// figure's place as Core Animation shows them right now.
    func route(of id: String) -> [CGPoint] { figures[id]?.route ?? [] }
    func walkEnds(of id: String) -> CFTimeInterval { figures[id]?.walkEnds ?? 0 }
    func shownFrame(of id: String) -> CGImage? {
        guard let contents = figures[id]?.sprite.presentation()?.contents, CFGetTypeID(contents as CFTypeRef) == CGImage.typeID else { return nil }
        return (contents as! CGImage)
    }
    func shownFoot(of id: String) -> CGPoint? { figures[id].map { $0.layer.presentation()?.position ?? $0.layer.position } }
    func pet(of id: String) -> String? { figures[id]?.pet }
    var restExtra: Int { restPill.contents == nil ? 0 : plan.restOverflow.count }
    func petFactor(of id: String) -> CGFloat? { figures[id]?.factor }
    func says(_ id: String) -> Bool { figures[id]?.saying ?? false }
    func lit(_ id: String) -> Float { figures[id]?.beam?.opacity ?? 0 }
    func pinShown(_ id: String) -> Bool { figures[id]?.pinned ?? false }
    /// whether one done and not looked at wears its small unread bubble.
    func dotShown(_ id: String) -> Bool { figures[id]?.bubbleKey.hasPrefix("dot") ?? false }
    /// a done-and-unread one's dots, in this view; nil when it wears none.
    func dotFrame(of id: String) -> CGRect? {
        guard let f = figures[id], f.bubbleKey.hasPrefix("dot"), f.bubble.contents != nil else { return nil }
        return f.bubble.frame.offsetBy(dx: f.voice.position.x, dy: f.voice.position.y)
    }
    /// VISIT, for the user-facing stills: every figure but these drawn at this opacity (its plate and bubble too).
    func fadeFigures(except keep: Set<String>, to opacity: Float) {
        for (id, f) in figures where !keep.contains(id) {
            f.layer.opacity = opacity
            f.tag.opacity = opacity
            f.voice.opacity = opacity
        }
    }
    /// for checks: any bubble over it (the ask, a visitor's word, "refused", the dots), in this view; nil without one.
    func bubbleFrame(of id: String) -> CGRect? {
        guard let f = figures[id], f.bubble.contents != nil, !f.bubbleKey.hasPrefix("dot") else { return nil }
        return f.bubble.frame.offsetBy(dx: f.voice.position.x, dy: f.voice.position.y)
    }
    /// for checks: the pet as drawn (its drawn width, feet to head top) where it stands, in this view.
    func drawnBox(of id: String) -> CGRect? {
        guard let f = figures[id] else { return nil }
        let at = f.layer.position, wide = f.drawnWide
        return CGRect(x: at.x - wide / 2, y: at.y + f.headTop, width: wide, height: -f.headTop)
    }
    /// for checks: the rest room's "+N" pill in this view; nil when it shows none.
    var restPillFrame: CGRect? { restPill.contents == nil ? nil : restPill.frame }
    /// for checks: just this figure as the window would show it (one point a pixel), every other layer hidden.
    func figureImage(only id: String) -> CGImage? {
        guard let keep = figures[id] else { return nil }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let parts = [base, lights, plates, speech, boards, outdoor.sea, outdoor.beach, outdoor.orca, outdoor.gulls] + (stage.sublayers ?? []).filter { $0 !== keep.layer }
        let was = parts.map(\.isHidden), color = root.backgroundColor
        for part in parts { part.isHidden = true }
        root.backgroundColor = nil
        let picture = image(pixelScale: 1)
        for (part, hidden) in zip(parts, was) { part.isHidden = hidden }
        root.backgroundColor = color
        CATransaction.commit()
        return picture
    }
    /// for checks: the figure drawn at this point (a plate, a pet's opaque pixel, a token), without the nearest-box rule.
    func drawnPet(at point: CGPoint) -> String? { drawn(at: point, front: frontToBack()).map { $0.layer.name ?? "" } }
    func plateFrame(of id: String) -> CGRect? {
        guard let f = figures[id] else { return nil }
        return f.plate.frame.offsetBy(dx: f.tag.position.x, dy: f.tag.position.y)
    }
    /// Every plate holder sits in the plates layer, which is over the pets' stage.
    var platesAbovePets: Bool {
        guard let parts = root.sublayers, let a = parts.firstIndex(of: stage), let b = parts.firstIndex(of: plates) else { return false }
        return b > a && figures.values.allSatisfy { $0.tag.superlayer === plates && $0.plate.superlayer === $0.tag }
    }

    /// A visit set by hand, for a picture or a check: `id` stands by `host` saying `words` until then (a past date ends it).
    func visit(_ id: String, to host: String, words: String, until: Date) {
        visits.looked = true
        guard until > Date(), let scene = ZoneArt.scene, let at = spot(host, scene) else {
            visits.visits[id] = nil
            return
        }
        visits.visits[id] = ZoneVisits.Visit(host: host, round: "", words: words.isEmpty ? ZoneVisits.plainWords : words, hostAt: at, until: until)
    }
    func screenShown(_ desk: ZoneDesk) -> Bool { (screens[desk]?.opacity ?? 0) > 0 }
    /// for checks: whether a desk has a code screen showing, and whether its LED breathes.
    func codeShown(_ desk: ZoneDesk) -> Bool { codeScreens[desk].map { $0.isOn && !$0.layer.isHidden && $0.layer.superlayer != nil } ?? false }
    var codeScreenCount: Int { codeScreens.count }
    func codeLayer(_ desk: ZoneDesk) -> CALayer? { codeScreens[desk]?.layer }
    func ledBreathes(_ desk: ZoneDesk) -> Bool { leds[desk].map(ZoneBreath.isBreathing) ?? false }
    /// for checks: a desk's foreground layer (`bossDeskKey` for the boss's), its parts, and where the stage, plates
    /// and speech layers are among the room's.
    func deskLayer(_ desk: ZoneDesk) -> ZoneDeskLayers? { deskLayers[desk] }
    var deskLayerCount: Int { deskLayers.count }
    var stageLayer: CALayer { stage }
    var overStage: [CALayer] { [plates, speech] }
    /// for checks: a figure walks these view points now, as `move` would set it off (its place is not changed).
    func walkForCheck(_ id: String, along points: [CGPoint]) { if let f = figures[id] { walk(f, along: points) } }
    /// The badge's family over a figure, and its frame in the view; nil without one.
    func badge(of id: String) -> (family: ZoneToolFamily, frame: CGRect)? {
        guard let f = figures[id], f.badge.contents != nil, let family = f.badgeFamily else { return nil }
        return (family, f.badge.frame.offsetBy(dx: f.voice.position.x, dy: f.voice.position.y))
    }
    /// The mini figures by a figure: their names (pets, "more") and frames, in the view.
    func agentFigures(of id: String) -> [(name: String, frame: CGRect)] {
        (figures[id]?.agents?.sublayers ?? []).map { ($0.name ?? "", $0.frame) }
    }
    /// for checks: the layer that holds a figure's helpers (its walkers), in the stage.
    func agentHolder(of id: String) -> CALayer? { figures[id]?.agents }
    /// The figure's sprite animations, by key (the pose's "loop", a walk's "steps").
    func spriteAnimation(of id: String, _ key: String) -> CAAnimation? { figures[id]?.sprite.animation(forKey: key) }
    /// For checks and the probe: a figure's sprite layer, and the ring it wears waiting with Reduce Motion (`WaitingNudge`).
    func spriteLayer(of id: String) -> CALayer? { figures[id]?.sprite }
    func ringLayer(of id: String) -> CALayer? { figures[id]?.ring }
    /// The light on a figure, for checks: its layer.
    func beam(of id: String) -> CALayer? { figures[id]?.beam }
    func aura(of id: String) -> CALayer? { figures[id]?.aura }
    func bolts(of id: String) -> CALayer? { figures[id]?.bolts }
    func figureLayer(of id: String) -> CALayer? { figures[id]?.layer }
    /// for checks: the figure's plate holder (in the plates layer) and its bubbles' and badge's (in the speech layer).
    func tagLayer(of id: String) -> CALayer? { figures[id]?.tag }
    func voiceLayer(of id: String) -> CALayer? { figures[id]?.voice }
    /// Which way a visitor is turned (`ZoneWalk.right` / `.left`), nil for one not visiting.
    func facing(of id: String) -> Int? { figures[id]?.facing }
    /// Each desk's and label's zone code, in the scene's order: what `build` lays the lights and labels out by.
    static func zoneCodes(_ scene: ZoneScene) -> [String] {
        scene.desks.map { "\($0.zone)_\($0.index)" } + scene.signs.map(\.zone)
    }
    /// For checks: the zones whose label hangs in the room (the check-in label among them), and the desks with a light.
    var hungSigns: Set<String> { Set(signs.filter { $0.value.superlayer != nil }.map(\.key)) }
    var litDesks: Set<String> { Set(leds.keys.map { "\($0.zone)_\($0.index)" }) }
    /// Whether the check-in label shows.
    var checkInShown: Bool { signs[ZonePlan.visitorKey]?.contents != nil }
    /// a label's pill in the view (a zone code, or `ZonePlan.visitorKey`), and its layer's transform.
    func signPill(_ key: String) -> CGRect? { signs[key]?.contents == nil ? nil : signPills[key] }
    /// a label's off-duty badge: the count it shows and where it is; nil when none.
    func offBadge(_ key: String) -> (count: Int, frame: CGRect)? {
        guard let layer = offBadges[key], layer.contents != nil, layer.superlayer != nil else { return nil }
        return (offCounts[key] ?? 0, layer.frame)
    }
    func bubbleKey(of id: String) -> String { figures[id]?.bubbleKey ?? "" }
    static var refusedWords: String { L10n.string("say.refused", table: "Zone", zh: "没送走") }
    func signTransform(_ key: String) -> CATransform3D? { signs[key]?.transform }
    func ledColor(_ desk: ZoneDesk) -> ZoneLED { (leds[desk]?.opacity ?? 0) > 0 ? ledShown[desk] ?? .off : .off }

    /// The view's layers as one picture, as the window would show them at rest. a Fable aura is light, composited by
    /// screen in the window, which `render(in:)` does not do; so the room is drawn without the auras, and each aura is then
    /// added by screen as the window adds it: its parts screened together, cut where things in front of it (its own pet,
    /// figures nearer the camera, the plates and bubbles) cover it.
    func image(pixelScale: CGFloat = 2) -> CGImage? {
        let lit = figures.values.filter { f in f.aura.map { $0.superlayer != nil && !$0.isHidden } ?? false }
            .sorted { $0.layer.zPosition < $1.layer.zPosition }
        guard !lit.isEmpty else { return renderedImage(pixelScale: pixelScale) }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for f in lit { f.aura?.isHidden = true }
        let room = renderedImage(pixelScale: pixelScale)
        for f in lit { f.aura?.isHidden = false }
        let pw = Int(bounds.width * pixelScale), ph = Int(bounds.height * pixelScale)
        func canvas() -> CGContext? {
            CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let room, let out = canvas() else { return room }
        let full = CGRect(x: 0, y: 0, width: pw, height: ph)
        out.draw(room, in: full)
        // The room's points, y down, as `renderedImage` draws them.
        let room2view = CGAffineTransform(scaleX: pixelScale, y: pixelScale).translatedBy(x: 0, y: bounds.height).scaledBy(x: 1, y: -1)
        // A picture in a layer's bounds, drawn where the room shows it (the layer's transform and its ancestors' included).
        func draw(_ picture: CGImage, in box: CGRect, of layer: CALayer, into ctx: CGContext, alpha: CGFloat) {
            let bl = root.convert(CGPoint(x: box.minX, y: box.maxY), from: layer), br = root.convert(CGPoint(x: box.maxX, y: box.maxY), from: layer)
            let tl = root.convert(CGPoint(x: box.minX, y: box.minY), from: layer)
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: br.x - bl.x, b: br.y - bl.y, c: tl.x - bl.x, d: tl.y - bl.y, tx: bl.x, ty: bl.y))
            ctx.setAlpha(alpha)
            ctx.draw(picture, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.restoreGState()
        }
        func image(of layer: CALayer) -> CGImage? {
            guard let contents = layer.contents.map({ $0 as AnyObject }), CFGetTypeID(contents) == CGImage.typeID else { return nil }
            return (contents as! CGImage)
        }
        // A layer as the window composites it: its picture and its sublayers (each added by screen or drawn over, as its
        // filter says), cut to its mask if it has one, at its opacity.
        func paint(_ layer: CALayer, into ctx: CGContext, alpha: CGFloat) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            let a = alpha * CGFloat(layer.opacity)
            if let mask = layer.mask, let maskPicture = image(of: mask) {
                guard let group = canvas() else { return }
                group.concatenate(room2view)
                // Nothing shows outside the mask's own box (a texture taller than it scrolls through it).
                let bl = root.convert(CGPoint(x: mask.frame.minX, y: mask.frame.maxY), from: layer), br = root.convert(CGPoint(x: mask.frame.maxX, y: mask.frame.maxY), from: layer)
                let tl = root.convert(CGPoint(x: mask.frame.minX, y: mask.frame.minY), from: layer)
                let box = CGAffineTransform(a: br.x - bl.x, b: br.y - bl.y, c: tl.x - bl.x, d: tl.y - bl.y, tx: bl.x, ty: bl.y)
                group.concatenate(box)
                group.clip(to: CGRect(x: 0, y: 0, width: 1, height: 1))
                group.concatenate(box.inverted())
                if let picture = image(of: layer) { draw(picture, in: layer.bounds, of: layer, into: group, alpha: 1) }
                for child in layer.sublayers ?? [] {
                    group.setBlendMode(child.compositingFilter == nil ? .normal : .screen)
                    paint(child, into: group, alpha: 1)
                }
                // The mask over the whole canvas (clear outside its box), applied unclipped as `--aura-sheet` does:
                // cut inside the clip, the clip's soft edge kept part of the pixels there, a faint frame round the box.
                guard let cut = canvas() else { return }
                cut.concatenate(room2view)
                draw(maskPicture, in: mask.frame, of: layer, into: cut, alpha: 1)
                guard let cutPicture = cut.makeImage() else { return }
                group.saveGState()
                group.resetClip()
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
        for f in lit {
            guard let aura = f.aura else { continue }
            let front = frontImage(of: f, pixelScale: pixelScale)
            // Part by part in the window's order, each added by screen or drawn over as its filter says, cut where things
            // in front cover it (the colour pass: the orange under the fire is drawn over, the fire on it added).
            for part in aura.sublayers ?? [] where !part.isHidden && part.opacity > 0 {
                guard let light = canvas() else { continue }
                let added = part.compositingFilter != nil
                light.concatenate(room2view)
                light.setBlendMode(added ? .screen : .normal)
                paint(part, into: light, alpha: CGFloat(aura.opacity))
                if let front {
                    light.saveGState()
                    light.concatenate(light.ctm.inverted())
                    light.setBlendMode(.destinationOut)
                    light.draw(front, in: full)
                    light.restoreGState()
                }
                if let made = light.makeImage() {
                    out.setBlendMode(added ? .screen : .normal)
                    out.draw(made, in: full)
                }
            }
        }
        return out.makeImage()
    }

    /// For `image`: only what is drawn over a figure's aura in the window: its own pet (and spinner), the figures and
    /// sub-agents nearer the camera (their auras are light, and cover nothing), and every layer over the stage.
    private func frontImage(of f: Figure, pixelScale: CGFloat) -> CGImage? {
        var hidden: [(CALayer, Bool)] = []
        func hide(_ layer: CALayer) {
            hidden.append((layer, layer.isHidden))
            layer.isHidden = true
        }
        let colour = root.backgroundColor
        root.backgroundColor = nil
        for part in [base, outdoor.sea, outdoor.beach, outdoor.orca, lights, marksLayer] { hide(part) }
        for layer in stage.sublayers ?? [] {
            if layer === f.layer {
                // its lightning too, which lies over its pet (drawn over, so the room's picture already has it).
                for part in layer.sublayers ?? [] where part !== f.sprite && part !== f.spinner && part !== f.bolts { hide(part) }
            } else if layer.zPosition > f.layer.zPosition {
                for part in layer.sublayers ?? [] where part.name == "aura" { hide(part) }
            } else {
                hide(layer)
            }
        }
        let picture = renderedImage(pixelScale: pixelScale)
        for (layer, was) in hidden.reversed() { layer.isHidden = was }
        root.backgroundColor = colour
        return picture
    }

    /// The layers as `render(in:)` draws them.
    private func renderedImage(pixelScale: CGFloat) -> CGImage? {
        guard bounds.width > 0, bounds.height > 0,
            let ctx = CGContext(
                data: nil, width: Int(bounds.width * pixelScale), height: Int(bounds.height * pixelScale), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: pixelScale, y: pixelScale)
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        root.render(in: ctx)
        return ctx.makeImage()
    }
}

/// one desk's foreground in the stage, as deep as the desk's centre (`ZoneDeskLayer.sortY`), so it covers the figures
/// behind it and the figures in front cover it. From the bottom: the desk with its screens and LEDs off; its LED strip
/// lit (breathing as the floor's pool under it does); an orange or plain glow cut to the desk; its screen lit; and, put
/// in by the view, the code a busy desk's screen shows. The lit pictures are read the first time they are wanted. The
/// lights layer under the stage keeps its own copies: where the desk is drawn this covers them, round it (the floor's
/// pool, the screen's spill on the wall) they show.
@MainActor final class ZoneDeskLayers {
    let art: ZoneDeskLayer
    let holder = CALayer()
    let off = CALayer()
    let led = CALayer()
    let glow = CALayer()
    let screen = CALayer()
    private var shownScreen: Bool?
    private var shownLED: ZoneLED?

    init?(_ art: ZoneDeskLayer, fit: ZoneFit, bounds: CGRect) {
        guard let picture = ZoneArt.picture("desks/" + art.id) else { return nil }
        self.art = art
        holder.frame = bounds
        holder.name = "desk-" + art.id
        holder.zPosition = fit.point(CGPoint(x: 0, y: art.sortY)).y
        off.contents = picture
        off.frame = fit.rect(art.box)
        led.frame = fit.rect(art.ledBox ?? art.box)
        screen.frame = fit.rect(art.screenBox ?? art.box)
        glow.frame = off.frame
        for (layer, name) in [(off, "off"), (led, "led"), (glow, "glow"), (screen, "screen")] {
            layer.name = name
            layer.contentsGravity = .resize
            if layer !== off { layer.opacity = 0 }
            holder.addSublayer(layer)
        }
    }

    /// The desk's lights as the plan has them; `disc` is the floor's glow disc for this desk's LED (`ZoneView.ledDisc`),
    /// used when there is no lit-LED picture. Only a change does anything.
    func paint(screen on: Bool, led state: ZoneLED, disc: (image: CGImage, frame: CGRect, opacity: Float)?, deskID: String, animated: Bool) {
        if shownScreen != on {
            shownScreen = on
            if on, screen.contents == nil { screen.contents = ZoneArt.picture("desks/\(art.id)_screen") }
            screen.opacity = on && screen.contents != nil ? 1 : 0
        }
        guard shownLED != state else { return }
        shownLED = state
        ZoneBreath.remove(from: led)
        ZoneBreath.remove(from: glow)
        led.opacity = 0
        glow.opacity = 0
        glow.contents = nil
        if state == .off { return }
        if state == .ice, art.ledBox != nil, ZoneArt.picture("night_leds") != nil, let lit = ZoneArt.picture("desks/\(art.id)_led") {
            led.contents = lit
            led.opacity = 1
            ZoneBreath.apply(to: led, deskID: deskID, waiting: false, animated: animated)
            return
        }
        // The pool is a glow disc (orange, or ice without the lit render): the same disc, only where the desk is drawn.
        guard let disc, let desk = off.contents, CFGetTypeID(desk as CFTypeRef) == CGImage.typeID else { return }
        glow.contents = Self.cut(disc.image, at: disc.frame, to: desk as! CGImage, at: off.frame)
        glow.opacity = disc.opacity
        if state == .ice { ZoneBreath.apply(to: glow, deskID: deskID, waiting: false, animated: animated) }
    }

    /// `picture` drawn over `frame` (view points, y down), kept only where `desk` (over `deskFrame`) is drawn: a picture
    /// the desk's size.
    static func cut(_ picture: CGImage, at frame: CGRect, to desk: CGImage, at deskFrame: CGRect) -> CGImage? {
        let w = desk.width, h = desk.height
        guard deskFrame.width > 0, deskFrame.height > 0,
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let kx = CGFloat(w) / deskFrame.width, ky = CGFloat(h) / deskFrame.height
        let top = (frame.minY - deskFrame.minY) * ky, height = frame.height * ky
        ctx.draw(picture, in: CGRect(x: (frame.minX - deskFrame.minX) * kx, y: CGFloat(h) - top - height, width: frame.width * kx, height: height))
        ctx.setBlendMode(.destinationIn)
        ctx.draw(desk, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

/// which pixels of a pet frame are drawn (alpha over 0.3), one byte a pixel at most 256 on a side, made once a frame
/// and kept, so the pointer's moves decode nothing. Rows from the top, as the frame is seen.
@MainActor enum ZoneHitMask {
    final class Mask {
        let image: CGImage   // held so its identity, the cache's key, is not reused
        let width: Int, height: Int
        let alpha: [UInt8]
        /// The drawn part's box, in shares of the frame (0…1), from the top-left.
        let solid: CGRect?
        init(image: CGImage, width: Int, height: Int, alpha: [UInt8], solid: CGRect?) {
            self.image = image; self.width = width; self.height = height; self.alpha = alpha; self.solid = solid
        }
        /// At a share of the frame's width and height from its top-left.
        func opaque(u: CGFloat, v: CGFloat) -> Bool {
            guard u >= 0, v >= 0, u < 1, v < 1 else { return false }
            return alpha[min(height - 1, Int(v * CGFloat(height))) * width + min(width - 1, Int(u * CGFloat(width)))] > ZoneHitMask.threshold
        }
    }
    nonisolated static let threshold: UInt8 = 77
    private static var cache: [ObjectIdentifier: Mask] = [:]

    static func mask(_ image: CGImage) -> Mask? {
        if let known = cache[ObjectIdentifier(image)], known.image === image { return known }
        guard image.width > 0, image.height > 0 else { return nil }
        let k = min(1, 256 / CGFloat(max(image.width, image.height)))
        let w = max(1, Int((CGFloat(image.width) * k).rounded())), h = max(1, Int((CGFloat(image.height) * k).rounded()))
        var alpha = [UInt8](repeating: 0, count: w * h)
        let drew = alpha.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return false }
            ctx.interpolationQuality = .none
            // A bitmap context's first row is the top of what is drawn in it: the rows come out top-down.
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var minX = w, maxX = -1, minY = h, maxY = -1
        for y in 0..<h { for x in 0..<w where alpha[y * w + x] > threshold { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        let solid = maxX >= minX ? CGRect(x: CGFloat(minX) / CGFloat(w), y: CGFloat(minY) / CGFloat(h),
                                          width: CGFloat(maxX - minX + 1) / CGFloat(w), height: CGFloat(maxY - minY + 1) / CGFloat(h)) : nil
        if cache.count > 600 { cache.removeAll() }
        let mask = Mask(image: image, width: w, height: h, alpha: alpha, solid: solid)
        cache[ObjectIdentifier(image)] = mask
        return mask
    }
}

/// The pictures the room paints for itself: soft glows, the signs, the plates and the bubbles. Drawn at two pixels a
/// point, sized in points.
@MainActor enum ZoneGlow {
    private static var discs: [UInt32: CGImage] = [:]

    static func bounds(_ quad: [CGPoint]) -> CGRect {
        var r = CGRect.null
        for p in quad { r = r.union(CGRect(origin: p, size: .zero)) }
        return r.isNull ? .zero : r
    }

    /// A round glow of one colour, full in the middle and fading to nothing at its rim.
    static func disc(_ hex: UInt32) -> CGImage? {
        if let known = discs[hex] { return known }
        let side = 128
        guard let c = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [OfficeCanvas.rgb(hex, 0.9), OfficeCanvas.rgb(hex, 0.35), OfficeCanvas.rgb(hex, 0)] as CFArray,
                                      locations: [0, 0.45, 1])
        else { return nil }
        let middle = CGPoint(x: side / 2, y: side / 2)
        c.drawRadialGradient(gradient, startCenter: middle, startRadius: 0, endCenter: middle, endRadius: CGFloat(side) / 2, options: [])
        discs[hex] = c.makeImage()
        return discs[hex]
    }

    /// a zone's label, as a set: one screen-aligned pill, the same height and font for every zone. From the left: the
    /// zone's colour as a bar (the pill's rounded left end), the name, the count in a chip of one size, then "+N" for those
    /// with no desk in a chip of the same height; a red dot on the count chip while one of the zone waits for you. Every
    /// part centred on the pill's middle line; the width follows the words, so nothing is cut. In points, drawn at two
    /// pixels a point; `margin` round the pill for its shadow and the dot.
    struct SignLayout: Equatable {
        var size: CGSize
        var pill: CGRect
        var bar: CGRect
        var name: CGRect
        var nameWidth: CGFloat
        var chip: CGRect?
        var plus: CGRect?
        var dot: CGRect?
        var font: CGFloat
        var chipFont: CGFloat
        var margin: CGFloat
    }

    /// The label's height in the view for a picture shown at `scale`: 44 px of the 2400 px picture, 18 points at least.
    static func signHeight(scale: CGFloat) -> CGFloat { max(18, (44 * scale).rounded()) }

    static func signLayout(_ name: String, count: Int, extra: Int, calling: Bool, height h: CGFloat) -> SignLayout {
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        let font = (h * 0.46 * 2).rounded() / 2, chipFont = (h * 0.4 * 2).rounded() / 2
        let margin = (h * 0.4).rounded(.up)
        let bar = (h * 0.4).rounded()
        let chipHigh = (h * 0.68).rounded()
        let inset = (h - chipHigh) / 2
        let nameWidth = measure.width(of: name, size: font, weight: .semibold)
        let x0 = margin
        let nameX = x0 + bar + (h * 0.3).rounded()
        var x = nameX + nameWidth
        var chip: CGRect?, plus: CGRect?, dot: CGRect?
        // One chip size for one or two digits (room for "00"); a third digit widens it.
        let twoDigits = max((chipHigh * 1.25).rounded(), (measure.width(of: "00", size: chipFont, weight: .bold) + chipHigh * 0.6).rounded(.up))
        if count > 0 {
            let digits = measure.width(of: "\(count)", size: chipFont, weight: .bold)
            let wide = max(twoDigits, (digits + chipHigh * 0.6).rounded(.up))
            x += (h * 0.3).rounded()
            chip = CGRect(x: x, y: margin + inset, width: wide, height: chipHigh)
            x += wide
        }
        if extra > 0 {
            let words = measure.width(of: "+\(extra)", size: chipFont, weight: .bold)
            let wide = max(twoDigits, (words + chipHigh * 0.7).rounded(.up))
            x += (h * 0.16).rounded()
            plus = CGRect(x: x, y: margin + inset, width: wide, height: chipHigh)
            x += wide
        }
        x += chip == nil && plus == nil ? (h * 0.42).rounded() : inset
        let pill = CGRect(x: x0, y: margin, width: x - x0, height: h)
        if calling {
            let r = (h * 0.15).rounded(), at = chip ?? CGRect(x: pill.maxX - h * 0.5, y: pill.minY, width: 0, height: 0)
            dot = CGRect(x: at.maxX - r * 1.1, y: at.minY - r * 0.9, width: r * 2, height: r * 2)
        }
        return SignLayout(size: CGSize(width: pill.maxX + margin, height: h + margin * 2), pill: pill,
                          bar: CGRect(x: x0, y: margin, width: bar, height: h), name: CGRect(x: nameX, y: margin, width: nameWidth, height: h),
                          nameWidth: nameWidth, chip: chip, plus: plus, dot: dot, font: font, chipFont: chipFont, margin: margin)
    }

    /// One line of text centred on `midY` by its font's cap height, so names and numbers of any size share one middle line.
    static func centred(_ c: OfficeCanvas, _ s: String, x: CGFloat, width: CGFloat, midY: CGFloat, size: CGFloat, weight: NSFont.Weight, _ hex: UInt32,
                        align: NSTextAlignment) {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let baseline = midY + font.capHeight / 2
        let top = baseline - font.ascender
        c.text(s, in: CGRect(x: x, y: top, width: width, height: font.ascender - font.descender + 2), size: size, weight: weight, hex, align: align)
    }

    static func sign(_ name: String, count: Int, extra: Int, calling: Bool, color: UInt32, height: CGFloat) -> (image: CGImage?, size: CGSize, layout: SignLayout) {
        let l = signLayout(name, count: count, extra: extra, calling: calling, height: height)
        let c = OfficeCanvas(l.size)
        let h = l.pill.height, mid = l.pill.midY
        let shape = CGPath(roundedRect: l.pill, cornerWidth: h / 2, cornerHeight: h / 2, transform: nil)
        // A soft shadow under it, so it reads on the rugs and the floor alike.
        c.ctx.saveGState()
        c.ctx.setShadow(offset: CGSize(width: 0, height: -h * 0.12 * 2), blur: h * 0.5 * 2, color: OfficeCanvas.rgb(0x05070D, 0.55))
        c.ctx.addPath(shape)
        c.ctx.setFillColor(OfficeCanvas.rgb(0xF6F3EC))
        c.ctx.fillPath()
        c.ctx.restoreGState()
        // The zone's colour: the pill's left end, cut straight on its right; a faint wash of it over the rest.
        c.ctx.saveGState()
        c.ctx.addPath(shape)
        c.ctx.clip()
        c.ctx.setFillColor(OfficeCanvas.rgb(color, 0.10))
        c.ctx.fill(l.pill)
        c.ctx.setFillColor(OfficeCanvas.rgb(color))
        c.ctx.fill(l.bar)
        c.ctx.restoreGState()
        c.ctx.addPath(CGPath(roundedRect: l.pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: h / 2 - 0.5, cornerHeight: h / 2 - 0.5, transform: nil))
        c.ctx.setStrokeColor(OfficeCanvas.rgb(color, 0.55))
        c.ctx.setLineWidth(1)
        c.ctx.strokePath()
        centred(c, name, x: l.name.minX, width: l.nameWidth + 2, midY: mid, size: l.font, weight: .semibold, 0x1E2A3A, align: .left)
        if let chip = l.chip {
            c.card(chip, radius: chip.height / 2, color)
            centred(c, "\(count)", x: chip.minX, width: chip.width, midY: mid, size: l.chipFont, weight: .bold, 0xFFFFFF, align: .center)
        }
        if let plus = l.plus {
            c.card(plus, radius: plus.height / 2, 0x1E2A3A)
            centred(c, "+\(extra)", x: plus.minX, width: plus.width, midY: mid, size: l.chipFont, weight: .bold, 0xF6F3EC, align: .center)
        }
        if let dot = l.dot {
            c.card(dot.insetBy(dx: -1.2, dy: -1.2), radius: dot.width / 2 + 1.2, 0xFFFFFF)
            c.card(dot, radius: dot.width / 2, OfficeLook.call)
        }
        return (c.image(), l.size, l)
    }

    /// the off-duty badge on a sign: a small night-blue disc ringed in white with a crescent and the count, in a
    /// colour no zone uses, so it does not read as the sign's own count.
    static func offBadge(_ count: Int, height h: CGFloat) -> (image: CGImage?, size: CGSize) {
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        let font = (h * 0.36 * 2).rounded() / 2, high = (h * 0.62).rounded()
        let digits = measure.width(of: "\(count)", size: font, weight: .bold)
        let moon = (high * 0.42).rounded()
        let wide = max(high, (moon + digits + high * 0.5).rounded(.up))
        let margin: CGFloat = 2
        let size = CGSize(width: wide + margin * 2, height: high + margin * 2)
        let c = OfficeCanvas(size)
        let body = CGRect(x: margin, y: margin, width: wide, height: high)
        c.card(body.insetBy(dx: -1.2, dy: -1.2), radius: high / 2 + 1.2, 0xFFFFFF)
        c.card(body, radius: high / 2, 0x3B3F78)
        // The crescent: a pale disc with a disc of the badge's colour over its right side.
        let mx = body.minX + high * 0.28, my = body.midY - moon / 2
        c.card(CGRect(x: mx, y: my, width: moon, height: moon), radius: moon / 2, 0xFFE7A8)
        c.card(CGRect(x: mx + moon * 0.36, y: my - moon * 0.12, width: moon, height: moon), radius: moon / 2, 0x3B3F78)
        centred(c, "\(count)", x: mx + moon + high * 0.04, width: digits + 2, midY: body.midY, size: font, weight: .bold, 0xFFFFFF, align: .left)
        return (c.image(), size)
    }

    /// A name plate: the name in paper on a dark rounded strip; the lead's edged in gold.
    /// `tone`: an error's plate brick red with white words, an amber or grey one keeps the dark plate with an edge of its
    /// colour.
    static func plate(_ words: String, scale: CGFloat, gold: Bool, pin: Bool = false, tone: FailTone? = nil) -> (image: CGImage?, size: CGSize) {
        let size = max(8, 8.5 * min(scale, 1.4))
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        let dot = (size * 0.62).rounded(), room = pin ? dot + size * 0.4 : 0
        let wide = (measure.width(of: words, size: size, weight: .medium) + size + room).rounded(.up)
        let high = (size * 1.45).rounded(.up)
        let c = OfficeCanvas(CGSize(width: wide + 1, height: high + 1))
        c.card(CGRect(x: 0.5, y: 0.5, width: wide, height: high), radius: high / 2, tone == .red ? failRedHex : 0x172033, tone == .red ? 1 : 0.82,
               edge: tone?.hex ?? (pin ? OfficeLook.pin : gold ? 0xE8C15A : 0x3F5470))
        if pin { c.card(CGRect(x: size * 0.55, y: (high - dot) / 2 + 0.5, width: dot, height: dot), radius: dot / 2, OfficeLook.pin, 1, edge: 0xFFFFFF) }
        c.text(words, in: CGRect(x: room, y: (high - size * 1.25) / 2 + 0.5, width: wide + 1 - room, height: size * 1.3), size: size, weight: .medium,
               tone == .red ? 0xFFFFFF : tone == .gone ? 0xB9B6CC : gold ? 0xFFE7A8 : 0xE9EEF7, align: .center)
        return (c.image(), CGSize(width: wide + 1, height: high + 1))
    }

    /// A visitor's speech bubble: what it came to say, on paper, its tail at the left over its head.
    static func say(_ words: String, scale: CGFloat, tail: CGFloat = 0.3) -> (image: CGImage?, size: CGSize) {
        let size = max(8.5, 9 * min(scale, 1.4))
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        var shown = words
        while shown.count > 4, measure.width(of: shown, size: size) > 170 { shown = String(shown.dropLast(2)) + "…" }
        let wide = (measure.width(of: shown, size: size) + 16).rounded(.up)
        let high = (size * 1.6 + 6).rounded(.up)
        let c = OfficeCanvas(CGSize(width: wide + 1, height: high + 6))
        c.card(CGRect(x: 0.5, y: 0.5, width: wide, height: high), radius: high / 2, 0xF4F1EA, 1, edge: OfficeLook.work)
        c.ctx.setFillColor(OfficeCanvas.rgb(0xF4F1EA))
        let at = min(wide - 9, max(9, wide * tail))
        c.ctx.move(to: CGPoint(x: at - 4, y: high))
        c.ctx.addLine(to: CGPoint(x: at, y: high + 5.5))
        c.ctx.addLine(to: CGPoint(x: at + 5, y: high))
        c.ctx.fillPath()
        c.text(shown, in: CGRect(x: 0, y: (high - size * 1.25) / 2 + 0.5, width: wide + 1, height: size * 1.3), size: size, 0x1E2A3A, align: .center)
        return (c.image(), CGSize(width: wide + 1, height: high + 6))
    }

    /// A small dark pill with a count on it: the rest room's "+N".
    static func pill(_ words: String, scale: CGFloat) -> (image: CGImage?, size: CGSize) {
        let size = max(9, 9.5 * min(scale, 1.4))
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        let wide = (measure.width(of: words, size: size, weight: .medium) + size * 1.2).rounded(.up), high = (size * 1.6).rounded(.up)
        let c = OfficeCanvas(CGSize(width: wide + 1, height: high + 1))
        c.card(CGRect(x: 0.5, y: 0.5, width: wide, height: high), radius: high / 2, 0x1E2A3A, 0.9, edge: 0x9FC7B8)
        c.text(words, in: CGRect(x: 0, y: (high - size * 1.25) / 2 + 0.5, width: wide + 1, height: size * 1.3), size: size, weight: .medium,
               0xF4F1EA, align: .center)
        return (c.image(), CGSize(width: wide + 1, height: high + 1))
    }

    /// The queue head's bubble: its name, and what it asks of you in the coral the room uses for that.
    static func ask(_ name: String, _ asks: String, scale: CGFloat, tail: CGFloat = 0.5) -> (image: CGImage?, size: CGSize) {
        let size = max(9, 9.5 * min(scale, 1.4))
        let measure = OfficeCanvas(CGSize(width: 1, height: 1))
        let wide = min(220, max(measure.width(of: name, size: size), measure.width(of: asks, size: size * 0.95, weight: .medium)) + 16).rounded(.up)
        let high = (size * 3.1 + 8).rounded(.up)
        let c = OfficeCanvas(CGSize(width: wide + 1, height: high + 6))
        c.card(CGRect(x: 0.5, y: 0.5, width: wide, height: high), radius: 8, 0xF4F1EA, 1, edge: OfficeLook.call)
        c.ctx.setFillColor(OfficeCanvas.rgb(0xF4F1EA))
        let at = min(wide - 10, max(10, wide * tail))
        c.ctx.move(to: CGPoint(x: at - 5, y: high))
        c.ctx.addLine(to: CGPoint(x: at + 0.5, y: high + 5.5))
        c.ctx.addLine(to: CGPoint(x: at + 6, y: high))
        c.ctx.fillPath()
        c.text(name, in: CGRect(x: 8, y: 4, width: wide - 16, height: size * 1.3), size: size, 0x1E2A3A)
        c.text(asks, in: CGRect(x: 8, y: 4 + size * 1.45, width: wide - 16, height: size * 1.3), size: size * 0.95, weight: .medium, OfficeLook.pin)
        return (c.image(), CGSize(width: wide + 1, height: high + 6))
    }

    /// A small bubble with three dots: done, and not looked at yet.
    static func dots(scale: CGFloat) -> (image: CGImage?, size: CGSize) {
        let w = (16 * max(0.9, min(scale, 1.4))).rounded(.up), h = (w * 0.72).rounded(.up)
        let c = OfficeCanvas(CGSize(width: w + 1, height: h + 4))
        c.card(CGRect(x: 0.5, y: 0.5, width: w, height: h), radius: h / 2, 0xF4F1EA, 1, edge: OfficeLook.work)
        c.ctx.setFillColor(OfficeCanvas.rgb(0xF4F1EA))
        c.ctx.move(to: CGPoint(x: w * 0.3, y: h))
        c.ctx.addLine(to: CGPoint(x: w * 0.25, y: h + 3.5))
        c.ctx.addLine(to: CGPoint(x: w * 0.45, y: h))
        c.ctx.fillPath()
        let r = h * 0.13
        for i in 0..<3 {
            let x = w * (0.3 + 0.2 * CGFloat(i))
            c.card(CGRect(x: x - r, y: h / 2 - r + 0.5, width: r * 2, height: r * 2), radius: r, 0x2E7D57)
        }
        return (c.image(), CGSize(width: w + 1, height: h + 4))
    }
}

// ───────── The live walk probe ─────────

extension ZoneView {
    /// For the live probe: walk a figure to a picture point now, as a change of place would (it walks back on the next look).
    func probeWalk(_ id: String, to target: CGPoint) {
        guard let f = figures[id], let scene = ZoneArt.scene else { return }
        move(f, to: target, scene: scene)
    }

    /// The figures at their own desks, for the probe to pick from.
    var probeCandidates: [String] { figures.keys.filter { atDesk($0) }.sorted() }

    /// The room as Core Animation shows it right now (presentation values), cropped round a view point, for the probe.
    func presentedCrop(around p: CGPoint, side: CGFloat) -> CGImage? {
        let shown = root.presentation() ?? root
        let k: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(side * k), height: Int(side * k), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: 0, y: side)
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: side / 2 - p.x, y: side * 0.75 - p.y)
        shown.render(in: ctx)
        return ctx.makeImage()
    }
}

/// `-office YES -officeTheme <sea room theme id> --zone-walk-probe <dir>` on a read-only review copy (`AppVariant`): five seconds
/// after the window shows, one figure at a desk walks to the queue spot and then to a desk on the right; each walk is
/// sampled six times 0.1 s apart from Core Animation's presentation (the sprite's frame, which sheet row and column it is,
/// the leg's direction, a crop of the window's layers there), written to `<dir>/walk-probe.json` and `<dir>/walk-live-strip.png`,
/// and the app quits.
@MainActor func zoneWalkProbe(_ window: NSWindow?, dir: String) {
    func find(_ view: NSView?) -> ZoneView? {
        guard let view else { return nil }
        if let zone = view as? ZoneView { return zone }
        for sub in view.subviews { if let found = find(sub) { return found } }
        return nil
    }
    guard let view = find(window?.contentView), let scene = ZoneArt.scene, let id = view.probeCandidates.first,
        let queue = scene.queue, let right = scene.islands.last.flatMap({ scene.desk(ZoneDesk(zone: $0, index: 12))?.seat })
    else {
        try? "no zone view or figure\n".write(toFile: dir + "/walk-probe.json", atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
        return
    }
    let pet = view.pet(of: id) ?? ""
    func whichFrame(_ image: CGImage?) -> String {
        guard let image else { return "none" }
        // a running frame is named by the facing it is for (the facing table may take it from another row, mirrored).
        for facing in [ZoneWalk.right, ZoneWalk.left] {
            for column in 0..<8 where OfficePets.shared.runFrame(pet, facing: facing, column: column)?.image === image { return "\(facing)-\(column)" }
        }
        for row in 0..<9 {
            for column in 0..<8 where OfficePets.shared.frame(pet, row: row, column: column)?.image === image { return "\(row)-\(column)" }
        }
        return "other"
    }
    var lines: [[String: Any]] = []
    var crops: [(CGImage?, String)] = []
    func sample(_ label: String, to target: CGPoint, then: @escaping () -> Void) {
        view.probeWalk(id, to: target)
        CATransaction.flush()
        let route = view.route(of: id), rows = ZoneWalk.rows(route)
        let start = CACurrentMediaTime()
        for i in 0..<6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 + Double(i) * 0.1) {
                let frame = view.shownFrame(of: id), foot = view.shownFoot(of: id) ?? .zero
                let leg = zoneProbeLeg(route, at: foot)
                let want = leg.map { rows[$0] }
                let got = whichFrame(frame)
                lines.append(["walk": label, "t": String(format: "%.3f", CACurrentMediaTime() - start), "foot": [foot.x, foot.y], "frame": got,
                              "leg": leg ?? -1, "legRow": want ?? -1, "rowMatches": got.hasPrefix("\(want ?? -9)-")])
                crops.append((view.presentedCrop(around: foot, side: 150), "\(label) \(got)"))
                if i == 5 { then() }
            }
        }
    }
    sample("to queue", to: queue) {
        sample("to the last island's 12", to: right) {
            let data = try? JSONSerialization.data(withJSONObject: ["pet": pet, "id": id, "samples": lines], options: [.prettyPrinted, .sortedKeys])
            try? data?.write(to: URL(fileURLWithPath: dir + "/walk-probe.json"))
            let cell: CGFloat = 150
            let canvas = OfficeCanvas(CGSize(width: cell * 6, height: (cell + 16) * 2))
            for (i, crop) in crops.enumerated() {
                let x = CGFloat(i % 6) * cell, y = CGFloat(i / 6) * (cell + 16)
                if let image = crop.0 {
                    canvas.ctx.saveGState()
                    canvas.ctx.translateBy(x: x, y: y + cell)
                    canvas.ctx.scaleBy(x: 1, y: -1)
                    canvas.ctx.draw(image, in: CGRect(x: 0, y: 0, width: cell, height: cell))
                    canvas.ctx.restoreGState()
                }
                canvas.text(crop.1, in: CGRect(x: x, y: y + cell, width: cell, height: 14), size: 9, weight: .semibold, 0xFFFFFF, align: .center)
            }
            if let image = canvas.image(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir + "/walk-live-strip.png"))
            }
            NSApp.terminate(nil)
        }
    }
}

/// Which leg of a route a point is on (the nearest).
func zoneProbeLeg(_ route: [CGPoint], at p: CGPoint) -> Int? {
    guard route.count > 1 else { return nil }
    var best: (Int, CGFloat)?
    for (i, (a, b)) in zip(route, route.dropFirst()).enumerated() {
        let d = CGVector(dx: b.x - a.x, dy: b.y - a.y), l = max(1e-6, d.dx * d.dx + d.dy * d.dy)
        let t = max(0, min(1, ((p.x - a.x) * d.dx + (p.y - a.y) * d.dy) / l))
        let e = hypot(a.x + d.dx * t - p.x, a.y + d.dy * t - p.y)
        if best == nil || e < best!.1 { best = (i, e) }
    }
    return best?.0
}

/// The zone room in the panel's SwiftUI content, following the store as the office does.
struct ZoneRoom: NSViewRepresentable {
    @ObservedObject var store: Store

    func makeNSView(context: Context) -> ZoneView {
        let view = ZoneView(frame: .zero)
        view.listen()
        return view
    }

    func updateNSView(_ view: ZoneView, context: Context) { view.update(store) }

    static func dismantleNSView(_ view: ZoneView, coordinator: ()) {
        view.stopListening()
        ZoneUI.open = nil
        if let store = view.store { DispatchQueue.main.async { store.tracker.pointer(at: nil) } }
        view.store = nil
    }
}

/// The hover card for a session in the zone: the office's own card, and under it the folder it runs in and, while it is
/// being checked in, the name the hook suggests.
struct ZoneCard: View {
    let s: Session
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z

    static func folder(_ s: Session) -> String { L10n.format("card.folder", table: "Zone", zh: "目录：%@", s.cwd.isEmpty ? L10n.string("card.folder.unknown", table: "Zone", zh: "未知") : s.cwd) }

    /// What the card says, as lines: the office card's progress line (its summary: [progress], the away summary or the first
    /// sentence, a "You: ..." line when the user's words are newer), its sub-agent rows, and the folder.
    @MainActor static func lines(_ s: Session, store: Store) -> [String] {
        (s.summary.isEmpty ? [] : [s.shownSummary]) + OfficeCard.helperLines(s, store.agents[s.id] ?? []) + [folder(s)]
    }

    var body: some View {
        let config = ZoneConfigFile.current()
        let pending = ZonePendingFile.entry(for: s, config: config)
        VStack(alignment: .leading, spacing: 4 * z) {
            OfficeCard(s: s)
            VStack(alignment: .leading, spacing: 2 * z) {
                Text(Self.folder(s)).lineLimit(1).truncationMode(.middle)
                if let pending, config.resolve(name: s.name, cwd: s.cwd) == nil {
                    Text(L10n.string("checkin.active", table: "Zone", zh: "报到中") + (pending.suggest.isEmpty ? "" : L10n.format("checkin.suggest", table: "Zone", zh: " · 建议名：%@", pending.suggest))).foregroundStyle(Color(hex: 0xFFC27A))
                }
            }
            .font(rounded(10.5 * z, .medium)).foregroundStyle(paper)
            .padding(.horizontal, 10 * z).padding(.vertical, 6 * z)
            .frame(width: OfficeHover.cardWidth * z, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8 * z, style: .continuous).fill(night.opacity(0.92)))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The list a zone sign (or the check-in label) opens: everyone of that zone, those with no desk marked, each row going
/// to its session.
struct ZoneListCard: View {
    let key: String
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z
    @Environment(\.still) private var still

    static let shows = 14

    /// What a row says of its session (a value; the words come from the table as the row is drawn).
    enum RowState: Equatable {
        case waiting, busy, news, seen, failed, gone

        var words: String {
            switch self {
            case .waiting: return L10n.string("zone.row.waiting", table: "Zone", zh: "在等你")
            case .busy: return L10n.string("zone.row.busy", table: "Zone", zh: "在干活")
            case .news: return L10n.string("zone.row.news", table: "Zone", zh: "有话说")
            case .seen: return L10n.string("zone.row.seen", table: "Zone", zh: "看过了")
            case .failed: return failedWords()
            case .gone: return exitedWords()
            }
        }
    }

    /// The title and the rows: (session, words on its right, whether it has no desk).
    @MainActor static func rows(_ key: String, store: Store) -> (title: String, rows: [(Session, String, Bool)]) {
        let config = ZoneConfigFile.current()
        let plan = ZonePlan.current(store, scene: ZoneArt.scene)
        let b = Buckets(store, now: Date())
        // the state is a value; its words are the table's, put on the row only as it is shown.
        var state: [String: RowState] = [:]
        for s in b.waiting { state[s.id] = .waiting }
        for s in b.busy { state[s.id] = .busy }
        for s in b.unread { state[s.id] = .news }
        for s in b.seen { state[s.id] = .seen }
        for s in b.resting { state[s.id] = .seen }  // resting is the office's; here it is seen, at its desk
        for s in b.failed { state[s.id] = .failed }
        for s in b.gone { state[s.id] = .gone }
        func words(_ s: Session) -> String { state[s.id]?.words ?? "" }
        var result: [(Session, String, Bool)] = []
        if key == ZoneUI.restKey {
            // those with no desk (their zone's `ZonePlan.desksPerZone` desks are taken), seated first; those without a seat marked.
            for id in plan.rest + plan.restOverflow {
                if let s = store.sessions.first(where: { $0.id == id }) { result.append((s, words(s), plan.restOverflow.contains(id))) }
            }
            return (L10n.format("list.rest", table: "Zone", zh: "休息室 · %lld", result.count), result)
        }
        if key == ZoneUI.visitorKey {
            for s in store.sessions where config.resolve(name: s.name, cwd: s.cwd) == nil {
                result.append((s, words(s), s.id != plan.visitor))
            }
            return (L10n.format("list.visitor", table: "Zone", zh: "报到 · %lld", result.count), result)
        }
        let code = String(key.dropFirst(zoneListPrefix.count))
        var overflow = Set<String>()
        for id in plan.overflow[code] ?? [] { overflow.insert(id) }
        for s in store.sessions where config.resolve(name: s.name, cwd: s.cwd) == code {
            result.append((s, words(s), overflow.contains(s.id)))
        }
        result.sort { a, b in a.2 != b.2 ? !a.2 : (plan.desks[a.0.id]?.index ?? 99) < (plan.desks[b.0.id]?.index ?? 99) }
        return ((config.zone(code)?.name ?? code) + " · \(result.count)", result)
    }

    /// the off-duty (and those being woken) by sign: zone code, or `ZonePlan.visitorKey` for those of no sign's zone.
    @MainActor static func offDuty(_ store: Store, scene: ZoneScene?) -> [String: [ZoneRosterEntry]] {
        let awake = Set(store.sessions.map(\.registryName).filter { !$0.isEmpty })
        let entries = ZoneOffDuty.shared.shown(roster: ZoneRosterFile.current(), awake: awake)
        return ZoneRoster.bySign(entries, signs: Set((scene?.signs ?? []).map(\.zone)))
    }

    /// this list's off-duty rows, latest gone first; none for the rest room's list.
    @MainActor static func offRows(_ key: String, store: Store) -> [ZoneRosterEntry] {
        guard key != ZoneUI.restKey, key.hasPrefix(zoneListPrefix) else { return [] }
        let code = key == ZoneUI.visitorKey ? ZonePlan.visitorKey : String(key.dropFirst(zoneListPrefix.count))
        return offDuty(store, scene: ZoneArt.scene)[code] ?? []
    }

    /// the words on an off-duty row's right: being woken, failed, or when it last worked and went off.
    @MainActor static func offWords(_ e: ZoneRosterEntry, now: Date) -> [String] {
        switch ZoneOffDuty.shared.state(of: e.name, now: now) {
        case .waking: return [L10n.string("off.waking", table: "Zone", zh: "唤醒中…")]
        case .failed: return [L10n.string("off.failed", table: "Zone", zh: "唤醒失败")]
        case .off: return [ZoneRoster.lastActive(e.lastActive, now: now), ZoneRoster.offAt(e.offAt, now: now)]
        }
    }

    static let offShows = 10

    var body: some View {
        let made = Self.rows(key, store: store)
        let off = Self.offRows(key, store: store)
        let shownOff = Array(off.prefix(Self.offShows))
        let shown = Array(made.rows.prefix(Self.shows))
        VStack(alignment: .leading, spacing: 6 * z) {
            HStack {
                Text(made.title).font(rounded(13 * z)).foregroundStyle(paper)
                Spacer()
                Button {
                    ZoneUI.open = nil
                    store.objectWillChange.send()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(quiet).frame(width: 24 * z, height: 24 * z).contentShape(Rectangle())
                }
                .buttonStyle(PressStyle()).accessibilityLabel(L10n.string("list.close", table: "Zone", zh: "关闭列表"))
            }
            if shown.isEmpty && off.isEmpty {
                Text(L10n.string("list.none", table: "Zone", zh: "这里现在没有会话")).font(rounded(11.5 * z)).foregroundStyle(quiet).padding(.vertical, 8 * z)
            }
            ForEach(shown, id: \.0.id) { row in
                OfficeListRow(list: key, s: row.0, gap: 6) {
                    HStack(spacing: 6 * z) {
                        if row.0.status == "waiting" { Circle().fill(call).frame(width: 7 * z, height: 7 * z) }
                        Text(row.0.name).lineLimit(1)
                        if row.2 { Text(key == ZoneUI.restKey ? L10n.string("list.noSeat", table: "Zone", zh: "没座位") : L10n.string("list.noDesk", table: "Zone", zh: "未上桌")).font(rounded(9.5 * z)).foregroundStyle(Color(hex: 0xFFC27A)) }
                        Spacer()
                        Text(row.1).font(rounded(10 * z)).foregroundStyle(row.0.status == "waiting" ? call : quiet)
                    }
                    .font(rounded(12 * z)).foregroundStyle(paper)
                }
            }
            if made.rows.count > shown.count {
                Text(L10n.format("list.more", table: "Zone", zh: "还有 %lld 个", made.rows.count - shown.count)).font(rounded(10 * z)).foregroundStyle(quiet)
            }
            if !off.isEmpty {
                // those off duty: a click wakes one at once (no asking: it can be sent off again).
                Rectangle().fill(quiet.opacity(0.25)).frame(height: 1)
                Text(L10n.format("list.off", table: "Zone", zh: "下班了 · %lld（点一下唤醒）", off.count)).font(rounded(11 * z)).foregroundStyle(quiet)
                ForEach(shownOff, id: \.name) { e in ZoneOffRow(list: key, entry: e) }
                if off.count > shownOff.count {
                    Text(L10n.format("list.more", table: "Zone", zh: "还有 %lld 个", off.count - shownOff.count)).font(rounded(10 * z)).foregroundStyle(quiet)
                }
            }
        }
        .padding(6 * z).frame(width: 270 * z)
    }
}

/// one off-duty session on a sign's list: its pet (the one its name had), its name, when it last worked and when it
/// went off; a click wakes it. While being woken it says so, and after a failed wake "wake failed" for a while.
struct ZoneOffRow: View {
    let list: String
    let entry: ZoneRosterEntry
    @EnvironmentObject private var store: Store
    @Environment(\.zoom) private var z
    @Environment(\.still) private var still

    static func key(_ list: String, _ name: String) -> String { OfficeList.row(list, "off:" + name) }

    var body: some View {
        let key = Self.key(list, entry.name)
        let state = ZoneOffDuty.shared.state(of: entry.name)
        let words = ZoneListCard.offWords(entry, now: Date())
        Button {
            #if TESTING
            if let observe = Self.activateForTest { observe(entry); return }
            #endif
            ZoneOffDuty.shared.wake(entry, store: store)
            store.objectWillChange.send()
        } label: {
            HStack(spacing: 6 * z) {
                PetSprite(pet: store.petByName[entry.name], pose: .sleeping, size: 22 * z, head: true)
                    .frame(width: 22 * z, height: 22 * z).opacity(state == .off ? 0.85 : 1)
                VStack(alignment: .leading, spacing: 1 * z) {
                    Text(entry.name).lineLimit(1).font(rounded(12 * z)).foregroundStyle(paper)
                    Text(words.joined(separator: " · ")).lineLimit(1).font(rounded(9.5 * z))
                        .foregroundStyle(state == .failed ? call : state == .waking ? Color(hex: 0xFFC27A) : quiet)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6 * z).padding(.vertical, 3 * z)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5 * z, style: .continuous).fill(Color.white.opacity(store.hovered == key ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .disabled(state == .waking)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [store, still] in
            if !still { store.tracker.frames[key] = $0.isEmpty || $0.isNull ? nil : $0 }
        }
        .onDisappear { [store, still] in if !still { store.tracker.frames[key] = nil } }
    }

    #if TESTING
    static var activateForTest: ((ZoneRosterEntry) -> Void)?
    #endif
}

/// The zone room for this store in a view this size, held still, with the card or list over it: for snapshots and checks.
@MainActor func zoneStill(_ store: Store, size: CGSize, visit: (String, String)? = nil) -> CGImage? {
    let view = ZoneView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    view.update(store)
    if let visit {
        // A visit with no note of its own says the demo crowd's line, in the language shown.
        let words = store.peers[visit.0]?.first { $0.id == visit.1 }?.note ?? ""
        view.visit(visit.0, to: visit.1, words: words.isEmpty ? DemoCrowd.visitWords(DemoCrowd.index(L10n.language)) : words, until: Date() + 60)
        view.update(store)
    }
    guard let room = view.image() else { return nil }
    let zoom = UserDefaults.standard.object(forKey: "zoom") as? Double ?? 1
    let scene = ZStack(alignment: .topLeading) {
        Image(decorative: room, scale: 2)
        OfficeHover(fit: OfficeFit(size), origin: .zero, window: size)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .environmentObject(store).environment(\.zoom, CGFloat(zoom)).environment(\.still, true).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: scene)
    renderer.scale = 2
    return renderer.cgImage
}

/// `--snapshot … --office --theme <sea room theme id>`: the room as the panel shows it; `--hover <name>` points at that session, or
/// at a zone's display name (or check-in) to open its list.
@MainActor func zoneSnapshot(_ store: Store, to path: String, size: CGSize, hover: String?) {
    let arguments = CommandLine.arguments
    // Snapshot-only, on the read-only store in memory: `--demo-rest N` makes the last N sessions finished seven hours
    // ago and looked at (they stay at their desks; the rest room is for those with no desk); `--pin <name>` pins one.
    if store.readOnly, let i = arguments.firstIndex(of: "--demo-rest"), i + 1 < arguments.count, let n = Int(arguments[i + 1]), n > 0 {
        let first = max(0, store.sessions.count - n), now = Date()
        store.sessions = store.sessions.enumerated().map { k, s in
            guard k >= first else { return s }
            store.seen[s.id] = now.timeIntervalSince1970
            store.pinned.remove(s.id)
            return Session(id: s.id, pid: s.pid, project: s.project, name: s.name, status: "idle", since: now - 7 * 3600 - Double(k) * 60,
                           summary: s.summary, registryName: s.registryName, cwd: s.cwd, kind: s.kind)
        }
    }
    if store.readOnly, let i = arguments.firstIndex(of: "--pin"), i + 1 < arguments.count,
        let s = store.sessions.first(where: { $0.name == arguments[i + 1] })
    {
        store.pinned.insert(s.id)
    }
    if let hover {
        let config = ZoneConfigFile.current()
        let token = ZoneUI.HoverToken(rawValue: hover)
        if token == .rest {
            ZoneUI.open = ZoneUI.HoverToken.rest.listKey
        } else if let s = store.sessions.first(where: { $0.name == hover }) {
            store.hovered = s.id
        } else if token == .visitor {
            ZoneUI.open = ZoneUI.HoverToken.visitor.listKey
        } else if let zone = config.zones.first(where: { $0.name == hover || $0.code == hover }) {
            ZoneUI.open = ZoneUI.key(zone.code)
        } else {
            FileHandle.standardError.write(Data("no open session or zone named \(hover); the picture shows nobody pointed at\n".utf8))
        }
    }
    // the roads picture shows the floor bare, so the roads and walks can be seen.
    if arguments.contains("--zone-roads") { store.sessions = [] }
    guard var composed = zoneStill(store, size: size) else { fatalError("could not draw Seaview") }
    // `--zone-roads` draws the road network and a few typical walks over the picture, for review.
    if arguments.contains("--zone-roads"), let scene = ZoneArt.scene, let over = ZoneRoadsPicture.draw(over: composed, scene: scene, view: size) {
        composed = over
    }
    guard let png = NSBitmapImageRep(cgImage: composed).representation(using: .png, properties: [:]) else { fatalError("could not draw Seaview") }
    try! png.write(to: URL(fileURLWithPath: path))
}

/// the roads over the Seaview picture (`--snapshot … --office --zone-roads`): the obstacles in faint red, the roads in
/// white with their junctions, each typical walk's spurs and way in its colour (as walked, corners cut) with a legend.
@MainActor enum ZoneRoadsPicture {
    /// The typical walks drawn: desk → line, desk → sofa (has-news), a visit across the islands, check-in → desk, rest → desk, and
    /// sofa → desk on the far side.
    static func samples(_ scene: ZoneScene) -> [(label: String, from: CGPoint, to: CGPoint, color: UInt32)] {
        // The islands left to right, by the names the room goes by (an art with fewer than four draws fewer walks).
        let z = (0..<4).map { $0 < scene.islands.count ? scene.islands[$0] : "" }
        func seat(_ z: String, _ i: Int) -> CGPoint? { scene.desk(ZoneDesk(zone: z, index: i))?.seat }
        var list: [(String, CGPoint?, CGPoint?, UInt32)] = [
            ("desk \(z[3]) 12 → queue spot 4", seat(z[3], 12), scene.lineSpot(3), 0xFF5D8F),
            ("desk \(z[2]) 4 → own-island sofa (has news)", seat(z[2], 4), scene.sofas.first { $0.zone == z[2] }?.seats[1], 0x4FD1FF),
            ("visit \(z[1]) 3 → beside \(z[2]) 8", seat(z[1], 3), seat(z[2], 8).map { scene.visitSpot($0) }, 0xFFD23F),
            ("check-in → desk \(z[0]) 5", scene.visitor, seat(z[0], 5), 0x7CFF6B),
            ("rest area → desk \(z[1]) 7", scene.restSeats.count > 2 ? scene.restSeats[2] : nil, seat(z[1], 7), 0xC38BFF),
            ("\(z[0]) sofa → desk \(z[3]) 2", scene.sofas.first { $0.zone == z[0] }?.seats[0], seat(z[3], 2), 0xFF9F43),
        ]
        list = list.filter { $0.1 != nil && $0.2 != nil }
        return list.map { ($0.0, $0.1!, $0.2!, $0.3) }
    }

    static func draw(over image: CGImage, scene: ZoneScene, view: CGSize) -> CGImage? {
        guard let map = scene.walkMap, let roads = map.roads else { return nil }
        let w = image.width, h = image.height, k = CGFloat(w) / view.width
        guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        c.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: 1, y: -1)
        let fit = ZoneFit(scene: scene.size, view: view)
        func at(_ world: CGPoint) -> CGPoint { let p = fit.point(map.pixel(world)); return CGPoint(x: p.x * k, y: p.y * k) }
        func line(_ points: [CGPoint], _ color: CGColor, _ width: CGFloat, dash: [CGFloat] = []) {
            guard points.count > 1 else { return }
            c.setStrokeColor(color)
            c.setLineWidth(width * k)
            c.setLineDash(phase: 0, lengths: dash.map { $0 * k })
            c.setLineCap(.round)
            c.setLineJoin(.round)
            c.addLines(between: points)
            c.strokePath()
            c.setLineDash(phase: 0, lengths: [])
        }
        func dot(_ p: CGPoint, _ r: CGFloat, _ color: CGColor) {
            c.setFillColor(color)
            c.fillEllipse(in: CGRect(x: p.x - r * k, y: p.y - r * k, width: 2 * r * k, height: 2 * r * k))
        }
        // The obstacles as the walks keep off them (grown by the clearance), faint.
        for box in map.boxes {
            let g = ZoneWalkMap.clearance
            let corners = box.corners(grow: 0).map(at), grown = box.corners(grow: g).map(at)
            line(corners + [corners[0]], OfficeCanvas.rgb(0xFF4040, 0.55), 1.2)
            line(grown + [grown[0]], OfficeCanvas.rgb(0xFF4040, 0.3), 0.8, dash: [3, 3])
        }
        // The roads, then their junctions.
        for e in roads.edges { line([at(roads.nodes[e.a]), at(roads.nodes[e.b])], OfficeCanvas.rgb(0x101820, 0.65), 4.2) }
        for e in roads.edges { line([at(roads.nodes[e.a]), at(roads.nodes[e.b])], OfficeCanvas.rgb(0xFFFFFF, 0.9), 2) }
        for (i, n) in roads.nodes.enumerated() where roads.links[i].count != 2 { dot(at(n), 2.6, OfficeCanvas.rgb(0xFFFFFF, 1)) }
        // The walks: the spurs dashed, the way as walked solid, the ends ringed.
        var legend: [(String, UInt32, CGFloat, CGFloat)] = []
        for sample in samples(scene) {
            guard let road = map.roadRoute(from: sample.from, to: sample.to) else { legend.append((sample.label + " (not on the road network)", sample.color, 0, 0)); continue }
            let walked = map.route(from: sample.from, to: sample.to).map { p -> CGPoint in let q = fit.point(p); return CGPoint(x: q.x * k, y: q.y * k) }
            let color = OfficeCanvas.rgb(sample.color, 0.95)
            line(walked, OfficeCanvas.rgb(0x000000, 0.5), 5.5)
            line(walked, color, 3)
            line(Array(road.prefix(3)).map(at), color, 1.4, dash: [2, 2])
            line(Array(road.suffix(3)).map(at), color, 1.4, dash: [2, 2])
            for p in [walked.first!, walked.last!] {
                dot(p, 5, OfficeCanvas.rgb(0x000000, 0.6))
                dot(p, 3.6, color)
            }
            var length: CGFloat = 0
            for (p, q) in zip(road, road.dropFirst()) { length += hypot(q.x - p.x, q.y - p.y) }
            let a = map.world(sample.from), b = map.world(sample.to)
            print(sample.label + ": " + road.map { String(format: "(%.2f,%.2f)", $0.x, $0.y) }.joined(separator: " "))
            legend.append((sample.label, sample.color, length, hypot(b.x - a.x, b.y - a.y)))
        }
        // The legend, top left.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        let font = NSFont.systemFont(ofSize: 11 * k, weight: .semibold)
        let box = CGRect(x: 10 * k, y: 10 * k, width: 330 * k, height: (22 + CGFloat(legend.count) * 16) * k)
        c.setFillColor(OfficeCanvas.rgb(0x0E1420, 0.82))
        c.fill(box)
        ("Roads (white) · obstacles (red box, dashed = clearance) · dashed = spurs" as NSString).draw(at: CGPoint(x: 18 * k, y: 15 * k), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        for (i, item) in legend.enumerated() {
            let y = (33 + CGFloat(i) * 16) * k
            c.setFillColor(OfficeCanvas.rgb(item.1, 1))
            c.fill(CGRect(x: 18 * k, y: y + 3 * k, width: 14 * k, height: 6 * k))
            let words = item.2 > 0 ? String(format: "%@  path %.1f m / straight %.1f m (%.1f×)", item.0, item.2, item.3, item.2 / max(item.3, 0.01)) : item.0
            (words as NSString).draw(at: CGPoint(x: 38 * k, y: y - 2 * k), withAttributes: [.font: font, .foregroundColor: NSColor.white])
        }
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()
    }
}

#if TESTING
/// For the README's moving pictures only (`--demo-gif-frames`, DemoTests.swift): a still room posed at a moment by hand,
/// since a still holds every figure where it ends. Not in the app's build.
extension ZoneView {
    /// The way a figure walks between two view points (along the aisles, as `move` lays it), in view points, and its
    /// seconds at `pace`.
    func demoWalk(from a: CGPoint, to b: CGPoint) -> (route: [CGPoint], seconds: Double)? {
        guard let scene = ZoneArt.scene, fit.scale > 0 else { return nil }
        let points = Self.walkRoute(from: fit.back(a), to: fit.back(b), scene: scene).map(fit.point)
        var total: CGFloat = 0
        for (p, q) in zip(points, points.dropFirst()) { total += hypot(q.x - p.x, q.y - p.y) }
        return (points, Double(total / (Self.pace * fit.scale)))
    }

    /// A figure held at a view point with its plate and bubbles, showing `frame` when given, in the order a figure there
    /// takes (`depth`, as a walk's keyframes do); the layers are drawn in that order again, as `update` does for a still.
    func demoPose(_ id: String, at p: CGPoint, frame: CGImage?) {
        guard let f = figures[id] else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let z = depth(f, at: p)
        for part in [f.layer, f.tag, f.voice] {
            part.position = p
            part.zPosition = z
        }
        if let frame { f.sprite.contents = frame }
        for holder in [stage, plates, speech] {
            if let order = holder.sublayers { holder.sublayers = order.sorted { $0.zPosition < $1.zPosition } }
        }
    }

    /// The still room `t` seconds into its live loops: the busy desks' code scrolling (`ZoneCodeScreen`) and LEDs breathing
    /// (`ZoneBreath`), the helpers walking their desk edges (`BGWalker`, caught at `t`) and the Fable auras (`ZoneAura`,
    /// held at `t`). Each of these starts when its state starts (a status change shapes the aura again, lights the LED,
    /// turns the screen on, makes the helpers again), so `local` gives a session's own seconds since then: its aura, its
    /// helpers and its desk's lights go by those (`helpers`: the helpers' own seconds, when they differ).
    func demoTick(_ t: Double, store: Store, local: [String: Double] = [:], helpers: [String: Double] = [:]) {
        auraPhase = t
        BGWalker.stillTime = t
        update(store)
        guard let scene = ZoneArt.scene else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var deskTime: [ZoneDesk: Double] = [:]
        for (id, own) in local {
            if let desk = plan.desks[id] { deskTime[desk] = own }
            guard let f = figures[id], let s = store.sessions.first(where: { $0.id == id }) else { continue }
            auraPhase = own
            BGWalker.stillTime = helpers[id] ?? own
            let pet = store.displayPets[s.id]
            let tall = scene.petHeight * fit.scale * store.figureSize(s) * (pet.map { OfficePets.shared.size($0) } ?? 1)
            wearAura(f, s, tall: tall)
            placeAgents(f, s, store, scene, at: true)
        }
        auraPhase = t
        BGWalker.stillTime = t
        for (desk, led) in leds where ledShown[desk] == .ice {
            let o = ZoneBreath.opacity(at: deskTime[desk] ?? t, deskID: "\(desk.zone)_\(desk.index)")
            led.opacity = o
            if let d = deskLayers[desk] {
                if d.led.contents != nil { d.led.opacity = o } else if d.glow.contents != nil { d.glow.opacity = o }
            }
        }
        for (desk, code) in codeScreens where code.isOn { code.demoPose(at: deskTime[desk] ?? t) }
    }

    /// The id a session's desk breathes by (`ZoneBreath.opacity`'s `deskID`), for choosing a loop's start.
    func demoDeskID(_ id: String) -> String? { plan.desks[id].map { "\($0.zone)_\($0.index)" } }

    /// For the log: each busy desk's code loop and the helpers' walk loop, seconds, by session.
    func demoLoops(_ store: Store) -> [(name: String, code: Double?, walk: Double?)] {
        store.sessions.compactMap { s in
            guard let desk = plan.desks[s.id] else { return nil }
            let code = codeScreens[desk].flatMap { $0.isOn ? $0.demoPeriod : nil }
            var walk: Double?
            if let art = ZoneArt.scene?.desk(desk), let near = art.near, figures[s.id]?.agents != nil {
                let edge = agentEdge(art, near)
                let a = edge.0, b = edge.1
                let l0 = CGPoint(x: a.x + (b.x - a.x) * -0.15, y: a.y + (b.y - a.y) * -0.15), l1 = CGPoint(x: a.x + (b.x - a.x) * 1.15, y: a.y + (b.y - a.y) * 1.15)
                walk = BGWalker.cycle(lane: hypot(l1.x - l0.x, l1.y - l0.y))
            }
            return code == nil && walk == nil ? nil : (s.name, code, walk)
        }
    }
}
#endif
