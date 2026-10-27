import AppKit
import SwiftUI

// ───────── Extensions ─────────
//
// An optional extension point for extra scenes that are not part of this repository: when `build.sh` is pointed at an
// extension directory (see build.sh) it compiles that directory's Swift files with the app, and `NoExtensions.swift` when
// it is not, in which case nothing extra is built.
// Either defines `registerExtensions()`, which the app calls first thing at launch; an extension registers its scene there.
// The panel itself only ever talks to the scene through `SceneExtension`: without one, nothing below does anything.

/// What an extension's scene does in the panel. Every member has a default that leaves the panel as it is.
protocol SceneExtension: AnyObject {
    // ── What it is
    /// Whether its art came with this build. A scene that cannot be shown is offered nowhere, and a theme saved under it
    /// is Seaview instead.
    var available: Bool { get }
    /// The theme the office is in while the scene shows (the name the `officeTheme` setting holds for it).
    @MainActor var theme: OfficeTheme { get }
    /// Its line in the scene switch and the status-bar menu.
    var modeTitle: String { get }
    /// A differently-labelled copy of the app that it builds, by that copy's bundle id; nil for this app itself.
    func variant(bundleID: String?) -> AppVariant?

    // ── Settings
    /// Its page in Settings, if it has one: the tab's title and SF Symbol, and the page.
    var settingsTitle: String? { get }
    var settingsSymbol: String? { get }
    @MainActor func settingsPage(store: Store) -> AnyView?

    // ── Its cast
    /// It deals its own characters to the sessions while it shows (not the shared pool's pets).
    var dealsCast: Bool { get }
    /// Its characters' ids: they are not in the shared pool.
    @MainActor var castIDs: [String] { get }
    /// Folders its characters' sheets are in, searched before the shared pool's.
    @MainActor var petRoots: [String] { get }
    /// Who has which of its characters, by session id.
    @MainActor func petAssignments(_ store: Store) -> [String: String]
    /// Deals its characters afresh.
    @MainActor func redeal(_ store: Store)
    /// One of its characters' frames for the board (`Pets.frame`), or nil for anyone else's.
    @MainActor func petFrame(_ id: String, row: Int, column: Int, head: Bool) -> CGImage?

    // ── Its layout
    /// It moves its figures itself (on programs of its own): the view leaves their walks, its stage's order and their
    /// hit areas to it, and the scene fills the view edge to edge (`OfficeFit`).
    var drivesFigures: Bool { get }
    /// The office's groups laid out in its own places (`OfficeLayout.sceneMode`), or nil to show the office.
    @MainActor func project(_ layout: OfficeLayout, previous: OfficeLayout?) -> OfficeLayout?
    /// The way between two of its places.
    func walk(_ layout: OfficeLayout, from a: OfficeSpot, to b: OfficeSpot) -> OfficeWalk
    /// Where those behind its door are pointed at, in a room this tall.
    func loungeRect(height: CGFloat) -> CGRect

    // ── Its pictures
    /// More of what the room's picture is painted from (a light that changes with the hour, say).
    @MainActor var roomKey: String { get }
    /// Paints its room; false to leave it to the office.
    @MainActor func drawRoom(_ c: OfficeCanvas, _ store: Store, _ layout: OfficeLayout, scale: CGFloat) -> Bool
    /// Paints its chips.
    @MainActor func drawChips(_ c: OfficeCanvas, _ layout: OfficeLayout, scale: CGFloat)
    /// A figure of its own for this session, or nil for the shared pool's pet.
    @MainActor func figure(_ store: Store, _ s: Session, _ place: OfficeLayout.Pet) -> OfficeFigure?
    /// How strongly one resting is drawn there (the office's 0.4 if nil).
    var sleeperAlpha: CGFloat? { get }
    /// A place's words, through `piece` (which adds a chat mark).
    @MainActor func words(
        _ store: Store, _ s: Session, _ place: OfficeLayout.Pet, scale: CGFloat, now: Date,
        piece: (CGRect, (OfficeCanvas) -> Void) -> OfficePiece?) -> OfficePiece?
    /// Its own list of those behind its door, up while `Store.sceneListOpen`.
    @MainActor func doorList(ids: [String]) -> AnyView

    // ── In the view (`OfficeView`), when it moves its figures itself
    /// Before a pass casts the room: brings its own model up to now.
    @MainActor func prepareCast(_ view: OfficeView, _ layout: OfficeLayout, now: Date)
    /// Casts one of its layouts (`OfficeView.cast` does the office's).
    @MainActor func cast(_ view: OfficeView, _ store: Store, _ layout: OfficeLayout, now: Date, scale: CGFloat)
    /// After a pass cast the room, its layout now the view's.
    @MainActor func afterCast(_ view: OfficeView)
    /// The view is in another window (or none): its animations went with the old one.
    @MainActor func movedToWindow(_ view: OfficeView)
    /// Whether figures walk though nobody can see the window (a check's clock of its own).
    @MainActor func walksUnseen(_ view: OfficeView) -> Bool
    /// Whether it still holds this figure where it stands, though its place changed.
    @MainActor func holds(_ view: OfficeView, _ id: String) -> Bool
    /// Where a figure is right now.
    @MainActor func position(_ view: OfficeView, _ f: OfficeView.Figure) -> CGPoint
    /// Puts a figure's restart spinner carrier (`Figure.carrier`) where the figure is, moving with it.
    @MainActor func carry(_ view: OfficeView, _ f: OfficeView.Figure)
    /// A figure is about to be put at its place at once.
    @MainActor func willSet(_ view: OfficeView, _ f: OfficeView.Figure)
    /// A figure sets off along a route: nil when the scene walks it itself, else the route to walk.
    @MainActor func walk(_ view: OfficeView, _ f: OfficeView.Figure, along route: [CGPoint], departs: CFTimeInterval) -> [CGPoint]?
    /// Where a figure can be pointed at, round its feet; and where that is now, in the room.
    @MainActor func hitRect(_ view: OfficeView, _ f: OfficeView.Figure) -> CGRect
    @MainActor func liveRect(_ view: OfficeView, _ f: OfficeView.Figure) -> CGRect
    /// The session whose figure is at this point of its room, if any.
    @MainActor func target(_ view: OfficeView, at spot: CGPoint) -> String?
}

extension SceneExtension {
    func variant(bundleID: String?) -> AppVariant? { nil }
    var settingsTitle: String? { nil }
    var settingsSymbol: String? { nil }
    @MainActor func settingsPage(store: Store) -> AnyView? { nil }
    var dealsCast: Bool { false }
    @MainActor var castIDs: [String] { [] }
    @MainActor var petRoots: [String] { [] }
    @MainActor func petAssignments(_ store: Store) -> [String: String] { store.petBySession }
    @MainActor func redeal(_ store: Store) {}
    @MainActor func petFrame(_ id: String, row: Int, column: Int, head: Bool) -> CGImage? { nil }
    var drivesFigures: Bool { false }
    @MainActor func project(_ layout: OfficeLayout, previous: OfficeLayout?) -> OfficeLayout? { nil }
    func walk(_ layout: OfficeLayout, from a: OfficeSpot, to b: OfficeSpot) -> OfficeWalk {
        OfficeLayout.walk(from: a, to: b, height: layout.height, tall: 70, body: nil)
    }
    func loungeRect(height: CGFloat) -> CGRect { OfficeLayout.door }
    @MainActor var roomKey: String { "" }
    @MainActor func drawRoom(_ c: OfficeCanvas, _ store: Store, _ layout: OfficeLayout, scale: CGFloat) -> Bool { false }
    @MainActor func drawChips(_ c: OfficeCanvas, _ layout: OfficeLayout, scale: CGFloat) {}
    @MainActor func figure(_ store: Store, _ s: Session, _ place: OfficeLayout.Pet) -> OfficeFigure? { nil }
    var sleeperAlpha: CGFloat? { nil }
    @MainActor func words(
        _ store: Store, _ s: Session, _ place: OfficeLayout.Pet, scale: CGFloat, now: Date,
        piece: (CGRect, (OfficeCanvas) -> Void) -> OfficePiece?
    ) -> OfficePiece? { nil }
    @MainActor func doorList(ids: [String]) -> AnyView { AnyView(EmptyView()) }
    @MainActor func prepareCast(_ view: OfficeView, _ layout: OfficeLayout, now: Date) {}
    @MainActor func cast(_ view: OfficeView, _ store: Store, _ layout: OfficeLayout, now: Date, scale: CGFloat) {}
    @MainActor func afterCast(_ view: OfficeView) {}
    @MainActor func movedToWindow(_ view: OfficeView) {}
    @MainActor func walksUnseen(_ view: OfficeView) -> Bool { false }
    @MainActor func holds(_ view: OfficeView, _ id: String) -> Bool { false }
    @MainActor func position(_ view: OfficeView, _ f: OfficeView.Figure) -> CGPoint { f.layer.position }
    @MainActor func carry(_ view: OfficeView, _ f: OfficeView.Figure) {}
    @MainActor func willSet(_ view: OfficeView, _ f: OfficeView.Figure) {}
    @MainActor func walk(_ view: OfficeView, _ f: OfficeView.Figure, along route: [CGPoint], departs: CFTimeInterval) -> [CGPoint]? { route }
    @MainActor func hitRect(_ view: OfficeView, _ f: OfficeView.Figure) -> CGRect { f.place.body.offsetBy(dx: -f.place.x, dy: -f.place.foot) }
    @MainActor func liveRect(_ view: OfficeView, _ f: OfficeView.Figure) -> CGRect { f.place.body }
    @MainActor func target(_ view: OfficeView, at spot: CGPoint) -> String? { nil }
}

/// A differently-labelled copy of the app an extension builds (a review copy, say): its window, its labels, and the
/// settings it starts from.
struct AppVariant {
    /// The window's title, and the line at the top of the status-bar menu.
    var title: String
    /// Before the counts in the menu bar.
    var statusPrefix = ""
    /// The menu's last line.
    var quitTitle: String
    var windowSize = CGSize(width: 640, height: 720)
    /// It only looks: nothing it does is saved.
    var readOnly = false
    /// Settings it starts from (`UserDefaults.register`).
    var defaults: [String: Any] = [:]
}

enum Extensions {
    /// The scene registered at launch (`registerExtensions`), if any; the checks set it to try either case.
    nonisolated(unsafe) static var registered: (any SceneExtension)?
    /// ...if this build can show it.
    static var scene: (any SceneExtension)? { registered.flatMap { $0.available ? $0 : nil } }
    /// ...if it is what the panel shows now.
    @MainActor static var active: (any SceneExtension)? { scene.flatMap { OfficeTheme.current.name == $0.theme.name ? $0 : nil } }
}

extension Store {
    /// Who has which pet as the panel shows them: the shared pool's, or an extension's scene's own cast while it shows.
    var displayPets: [String: String] {
        if let scene = Extensions.active, scene.dealsCast { return scene.petAssignments(self) }
        return petBySession
    }
}
