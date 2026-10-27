// Error / disconnect rendering. An error nothing has answered (`--dump`'s errorKind, idle) has a group of its own,
// error, after the waiting ones: brick red (0xC4392B), or amber (0xF0B429) for the usage limit; looked at, it is looked-at like
// any other. A retry (busy, retryAttempt) stays at work, in amber. A session that exited unexpectedly (`disconnected`) is a grey
// card under the looked-at ones, its pet faint (45%) at its own desk in the office and the sea room, counted nowhere, never
// celebrated, never pinned. The menu bar's badge is waiting + error + unread. `showFailed` (defaults, on) off: the pictures without error display.
// `--error-render-only` runs the checks; `--error-render-stills <dir>` draws the pictures (with `--lang` for another language).

import AppKit
import SwiftUI

@MainActor func errorRenderSession(_ id: String, _ status: String, ago: TimeInterval = 60, origin: String = "user", kind: String? = nil, errorStatus: Int? = nil,
                           retry: (Int, Int)? = nil, gone: Bool = false, name: String? = nil, project: String = "demo-errs", summary: String? = nil,
                           agent: String = "claude") -> Session {
    let line: SummaryLine? = gone ? .disconnected
        : retry.map { .retrying(attempt: $0.0, max: $0.1) }
        ?? kind.flatMap { k in k.hasPrefix("wb_") ? nil : .apiError(kind: k, status: errorStatus, text: k == "rate_limit" ? "You've hit your weekly limit · resets 1pm (UTC)" : "Overloaded") }
    var s = boardSweepSession(id, status, ago: ago, name: name ?? id, project: project, summary: summary ?? line?.rendered ?? "改好了", kind: agent)
    s.summaryLine = summary == nil ? line : s.summaryLine  // a made-up error or approval line keeps the code boardSweepSession gave it
    s.origin = origin
    s.errorKind = kind
    s.errorStatus = errorStatus
    s.errorSince = kind == nil ? nil : Date().addingTimeInterval(-ago)
    s.retryAttempt = retry?.0
    s.retryMax = retry?.1
    s.disconnected = gone
    s.disconnectedSince = gone ? Date().addingTimeInterval(-ago) : nil
    s.registryName = name ?? id
    s.cwd = "/tmp/errrender/" + (name ?? id)
    return s
}

/// The same session without error fields: no error, retry or exit fields.
func errorRenderPlain(_ s: Session) -> Session {
    var t = s
    t.errorKind = nil; t.errorStatus = nil; t.errorText = nil; t.errorSince = nil; t.retryAttempt = nil; t.retryMax = nil
    t.disconnected = false; t.disconnectedSince = nil
    return t
}

@MainActor func errorRenderTests() {
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "showFailed")
    defaults.removeObject(forKey: "bgCountsAsWorking")
    defer { defaults.removeObject(forKey: "showFailed") }
    let now = Date()
    let panelText0 = panelSources(URL(fileURLWithPath: #filePath).deletingLastPathComponent())

    // ── 1. The reading ──
    let api = errorRenderSession("f-api", "idle", kind: "api", errorStatus: 529), auth = errorRenderSession("f-auth", "idle", kind: "auth", errorStatus: 403)
    let rate = errorRenderSession("f-rate", "idle", kind: "rate_limit", errorStatus: 429)
    let wbErr = errorRenderSession("f-wbe", "idle", kind: "wb_error", agent: "workbuddy"), wbStop = errorRenderSession("f-wbs", "idle", kind: "wb_stopped", agent: "workbuddy")
    let retry = errorRenderSession("b-retry", "busy", retry: (3, 10)), gone = errorRenderSession("x-gone", "idle", ago: 240, gone: true)
    let plain = errorRenderSession("s-plain", "idle"), busy = errorRenderSession("b-busy", "busy")
    check("error render: showFailed is on by default", showFailed())
    check("error render: an error — api, auth, WorkBuddy's error and stop are red; the usage limit amber; none of them a retry or an exit",
        [api, auth, wbErr, wbStop].allSatisfy { $0.hasError && $0.isRed && !$0.isAmber && !$0.isGone && !$0.isRetrying }
            && rate.hasError && rate.isAmber && !rate.isRed)
    check("error render: a retry is busy, amber, at work (no errorKind)", retry.isRetrying && retry.isAmber && !retry.hasError && retry.isWorking)
    check("error render: an unexpected exit is gone, not an error, not at work; a plain one is none of these",
        gone.isGone && !gone.hasError && !gone.isWorking && !plain.hasError && !plain.isGone && !plain.isRetrying && !busy.isAmber)
    let busyError = errorRenderSession("f-busy", "busy", kind: "api", errorStatus: 529)
    check("error render: an errorKind while busy (a new turn under way) is not drawn as an error", !busyError.hasError)

    // ── 2. Groups ──
    let store = Store()
    store.readOnly = true
    let restingGone = errorRenderSession("x-old", "idle", ago: 9 * 3600, gone: true)
    let waiting = errorRenderSession("w-wait", "waiting")
    store.sessions = [api, auth, rate, wbErr, wbStop, retry, gone, restingGone, plain, busy, waiting]
    store.seen["s-plain"] = now.timeIntervalSince1970
    let b = Buckets(store, now: now)
    check("error render: error holds the five errors not looked at (the usage limit with them, in amber)", Set(b.failed.map(\.id)) == ["f-api", "f-auth", "f-rate", "f-wbe", "f-wbs"])
    check("error render: the retry stays in busy; the waiting one waits", Set(b.busy.map(\.id)) == ["b-retry", "b-busy"] && b.waiting.map(\.id) == ["w-wait"])
    check("error render: exited unexpectedly holds the two exits (nine hours on, still not resting); not news, not seen, not resting",
        Set(b.gone.map(\.id)) == ["x-gone", "x-old"] && b.unread.isEmpty && b.seen.map(\.id) == ["s-plain"] && b.resting.isEmpty)
    check("error render: an error or an exit is not unread, not fresh (unread does not hold them)",
        [api, rate, wbStop, gone].allSatisfy { !store.isUnread($0) && !store.isFresh($0) })
    check("error render: the tones — red, amber (limit and retry), grey for the exit, none for the rest",
        store.failTone(api) == .red && store.failTone(wbStop) == .red && store.failTone(rate) == .amber && store.failTone(retry) == .amber
            && store.failTone(gone) == .gone && store.failTone(plain) == nil && store.failTone(busy) == nil
            && FailTone.red.hex == 0xC4392B && FailTone.amber.hex == 0xF0B429)
    // Looked at: back with the looked-at ones, no colour.
    store.seen["f-api"] = now.timeIntervalSince1970 + 1
    let looked = Buckets(store, now: now)
    check("error render: an error looked at falls to seen and loses its red (but it still says its error in its summary)",
        looked.seen.map(\.id).contains("f-api") && !looked.failed.map(\.id).contains("f-api") && store.failTone(api) == nil && api.summary.contains("529"))
    // An error of a turn another session began is shown too (it is how it stands); one the pin holds is under error till looked at.
    let peerError = errorRenderSession("f-peer", "idle", origin: "peer", kind: "api", errorStatus: 500)
    store.sessions = [peerError]
    store.seen = [:]
    check("error render: an error at the end of a peer's turn is under error too (an error is not news, it is a state)", Buckets(store, now: now).failed.map(\.id) == ["f-peer"])
    store.pinned = ["f-peer"]
    check("error render: pinned and an error not looked at: under error, not twice", Buckets(store, now: now).failed.map(\.id) == ["f-peer"] && Buckets(store, now: now).unread.isEmpty)
    store.seen["f-peer"] = now.timeIntervalSince1970 + 1
    check("error render: …looked at, the pin holds it under unread", Buckets(store, now: now).unread.map(\.id) == ["f-peer"])
    store.pinned = []
    check("error render: Mark All Seen shows with only an error not looked at (it takes it out of error)",
        panelText0.contains("store.sessions.contains(where: { store.isFresh($0) || store.isFailed($0) })"))

    // ── 3. Counts, the badge, the menu ──
    store.sessions = [api, auth, rate, retry, gone, waiting, errorRenderSession("u-news", "idle", ago: 30)]
    store.seen = ["u-news": 0]
    let c = Buckets(store, now: now)
    check("error render: the counts — 1 waiting, 3 error (the usage limit counted, as the group has it), 1 unread, 1 working; the exit nowhere",
        c.waiting.count == 1 && c.failed.count == 3 && c.unread.count == 1 && c.busy.count == 1 && c.gone.count == 1)
    check("error render: the badge is waiting + error + unread, red with an error",
        statusBadge(waiting: c.waiting.count, unread: c.unread.count, failed: c.failed.count) == StatusBadge(text: "5", red: true)
            && statusBadge(waiting: 0, unread: 0, failed: 2) == StatusBadge(text: "2", red: true)
            && statusBadge(waiting: 0, unread: 2, failed: 0) == StatusBadge(text: "2", red: false))
    check("error render: the menu's first line has the error count after the waiting; none at zero",
        menuCountsTitle(waiting: 1, unread: 1, busy: 1, failed: 3) == "1 在等你 · 3 出错 · 1 有话说 · 1 在干活"
            && menuCountsTitle(waiting: 2, unread: 1, busy: 4) == "2 在等你 · 1 有话说 · 4 在干活")
    let goneOnly = Store()
    goneOnly.readOnly = true
    goneOnly.sessions = [gone, errorRenderSession("b-bg", "busy")]
    let g = Buckets(goneOnly, now: now)
    check("error render: an exit alone: no badge, the icon a template (unchanged)",
        statusBadge(waiting: g.waiting.count, unread: g.unread.count, failed: g.failed.count) == nil
            && statusIcon(waiting: g.waiting.count, unread: g.unread.count, failed: g.failed.count).isTemplate)
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let panelText = panelSources(sources)
    check("error render: the menu-bar icon is set again only when its key changes, and the key has the error count",
        panelText.contains("let key = \"\\(b.waiting.count) \\(b.failed.count) \\(b.unread.count)") && panelText.contains("if key != shownCounts {"))

    // ── 4. The celebration ──
    func cheered(_ readings: [[Session]]) -> Bool {
        let s = Store()
        s.readOnly = true
        var t = now
        for r in readings { s.take(r, at: t); t = t.addingTimeInterval(2) }
        return !s.celebrating.isEmpty
    }
    let work = errorRenderSession("c1", "busy"), done = errorRenderSession("c1", "idle", ago: 0)
    let failedDone = errorRenderSession("c1", "idle", ago: 0, kind: "api", errorStatus: 529)
    let goneDone = errorRenderSession("c1", "idle", ago: 0, gone: true)
    check("error render: a clean finish is celebrated, a tick after it shows (not at once)", !cheered([[work], [done]]) && cheered([[work], [done], [done]]))
    check("error render: a finish in an error is not celebrated", !cheered([[work], [failedDone], [failedDone], [failedDone]]))
    check("error render: the race — idle first, the error's line a tick later: not celebrated", !cheered([[work], [done], [failedDone], [failedDone]]))
    check("error render: an exit while at work is not celebrated", !cheered([[work], [goneDone], [goneDone]]))
    check("error render: a finish that goes away before the tick is not celebrated", !cheered([[work], [done], []]))
    let reportOld = Store()
    reportOld.readOnly = true
    defaults.set(false, forKey: "showFailed")
    reportOld.take([work], at: now)
    reportOld.take([done], at: now.addingTimeInterval(2))
    let offAtOnce = !reportOld.celebrating.isEmpty
    defaults.removeObject(forKey: "showFailed")
    check("error render: showFailed off: celebrated at once", offAtOnce)
    check("error render: the notice board says nothing of an exit (no done line)",
        OfficeActivity.events(from: [work], to: [goneDone], at: now).isEmpty && OfficeActivity.events(from: [work], to: [done], at: now).count == 1)
    let failedEvents = OfficeActivity.events(from: [work], to: [failedDone], at: now)
    check("error render: the notice board logs an error as an error (red dot), not as done",
        failedEvents.map(\.kind) == [.failed] && failedEvents.first?.text == "出错" && OfficeActivity.Event.Kind.failed.dot == failRedHex)
    var late = OfficeActivity()
    late.add(OfficeActivity.events(from: [work], to: [done], at: now))
    late.add(OfficeActivity.events(from: [done], to: [failedDone], at: now.addingTimeInterval(2)))
    check("error render: the error's line a tick late: the done just logged becomes error, once (\(late.events.map(\.text)), unseen \(late.unseen))",
        late.events.map(\.kind) == [.failed] && late.unseen == 1)

    // ── 5. The exit: not pinned, not moved, kept on the board ──
    let pins = Store()
    pins.readOnly = true
    pins.sessions = [gone]
    pins.togglePin(gone)
    let menu = sessionMenu(pins, gone)
    check("error render: an exit cannot be pinned (the toggle does nothing; the menu's pin, desk and rest are off; jump stays)",
        pins.pinned.isEmpty && menu.filter { [.pin, .desk, .rest].contains($0.action) }.allSatisfy { !$0.enabled }
            && menu.first { $0.action == .jump }?.enabled == true)
    let listed = [plain, gone]
    check("error render: the board keeps the loader's exits (showFailed on)", Store.shown(listed).map(\.id) == ["s-plain", "x-gone"])
    defaults.set(false, forKey: "showFailed")
    check("error render: showFailed off: left off", Store.shown(listed).map(\.id) == ["s-plain"])
    defaults.removeObject(forKey: "showFailed")

    // ── 6. showFailed off: the reading without error display ──
    defaults.set(false, forKey: "showFailed")
    let off = Store()
    off.readOnly = true
    off.sessions = [api, rate, retry, plain]
    off.seen = ["s-plain": now.timeIntervalSince1970]
    let ob = Buckets(off, now: now)
    check("error render off: no error group, no tone; the errors are news, the retry at work",
        ob.failed.isEmpty && ob.gone.isEmpty && Set(ob.unread.map(\.id)) == ["f-api", "f-rate"] && ob.busy.map(\.id) == ["b-retry"]
            && [api, rate, retry].allSatisfy { off.failTone($0) == nil && !$0.hasError && !$0.isRetrying })
    check("error render off: the badge is unchanged (no error counted)", statusBadge(waiting: ob.waiting.count, unread: ob.unread.count, failed: ob.failed.count) == StatusBadge(text: "2", red: false))
    defaults.removeObject(forKey: "showFailed")

    // ── 7. Pictures: off is the plain look, on differs where it should ──
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = nil }
    let cast = errorRenderCast()
    let castPlain = cast.filter { !$0.disconnected }.map(errorRenderPlain)
    defaults.set(false, forKey: "showFailed")
    // One store (its pets dealt once), the same sessions read twice: with the error fields, and without them.
    let offStore = errorRenderStore(Store.shown(cast))  // as the panel takes them with it off: the exits left off
    let withFields = offStore.sessions
    func shots() -> [[UInt8]] {
        // Each drawn twice, the second kept: the first after a change may still be catching up (a pet's frames, a walker).
        [{ bgRenderBoard(offStore, width: 640) }, { bgRenderBoard(offStore, width: 420) }, { officeStill(offStore, size: CGSize(width: 1194, height: 764)) }]
            .map { draw in
                var last = errorRenderPixels(draw())
                for _ in 0..<4 {
                    RunLoop.main.run(until: Date().addingTimeInterval(0.3))  // what a first drawing set going (frames cut, pets dealt) lands
                    let next = errorRenderPixels(draw())
                    if next == last { break }
                    last = next
                }
                return last
            }
    }
    _ = shots()  // the process's first drawing of these words; text drawn the first time may differ by a shade
    let offShots = shots()
    offStore.sessions = castPlain
    let plainShots = shots()
    check("error render off: the board (wide, narrow) and the office are pixel for pixel the plain look for the same sessions without the error fields",
        offShots == plainShots && offShots.allSatisfy { !$0.isEmpty })
    let restore = seaSweepSetup(NSTemporaryDirectory() + "errrender-zones-\(getpid())")
    let plainZone = bgRenderZone(offStore).image
    offStore.sessions = withFields
    let offZone = bgRenderZone(offStore).image
    check("error render off: the sea room is the plain look too", errorRenderPixels(offZone) == errorRenderPixels(plainZone) && !errorRenderPixels(offZone).isEmpty)
    defaults.removeObject(forKey: "showFailed")
    let onStore = errorRenderStore(cast)
    offStore.sessions = cast
    check("error render on: the pictures differ (the red group, the grey card)", errorRenderPixels(bgRenderBoard(offStore, width: 640)) != offShots[0])

    // ── 8. The office ──
    let layout = OfficePainter.layout(onStore, now: Date())
    func place(_ id: String) -> OfficeLayout.Pet? { layout.pets.first { $0.id == id } }
    check("error render office: the errors not looked at sit on the sofas (with the news); the exit at a desk; the retry at a desk",
        ["f-api", "f-auth", "f-rate"].allSatisfy { place($0)?.zone == .sofa } && place("x-gone")?.zone == .desk && place("a-retry")?.zone == .desk)
    if let p = place("x-gone") {
        check("error render office: the exit's pet is faint (45%)", OfficePainter.figure(onStore, onStore.sessions.first { $0.id == "x-gone" }!, p, now: Date()).sprite.alpha == 0.45)
    } else {
        check("error render office: the exit's pet is faint (45%)", false)
    }
    let lit = Set(OfficePainter.lit(onStore, layout))
    check("error render office: the exit's screen is dark, the retry's lit", place("x-gone").map { !lit.contains($0.seat) } == true && place("a-retry").map { lit.contains($0.seat) } == true)
    let byID = Dictionary(onStore.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    check("error render office: the hover card's stripe — red, amber, grey; the rest unchanged",
        OfficeCard.stripe(byID["f-api"]!, tone: onStore.failTone(byID["f-api"]!)) == 0xC4392B
            && OfficeCard.stripe(byID["a-retry"]!, tone: onStore.failTone(byID["a-retry"]!)) == 0xF0B429
            && OfficeCard.stripe(byID["x-gone"]!, tone: onStore.failTone(byID["x-gone"]!)) == goneGreyHex
            && OfficeCard.stripe(byID["w-ref"]!, tone: onStore.failTone(byID["w-ref"]!)) == OfficeLook.call)
    if let p = place("f-api") {
        let k1 = OfficeView.wordsKey(onStore, byID["f-api"]!, p, layout, now: Date(), scale: 1)
        let k2 = OfficeView.wordsKey(onStore, errorRenderPlain(byID["f-api"]!), p, layout, now: Date(), scale: 1)
        check("error render office: a plate is painted again when its error comes or goes (its key has the tone)", k1 != k2)
    }
    check("error render: the short words — API error 529, re-login, usage limit, retrying 3/10, exited unexpectedly, aborted (Simplified); none for a plain one",
        failShortWords(byID["f-api"]!) == "API 出错 529" && failShortWords(byID["f-auth"]!) == "要重新登录" && failShortWords(byID["f-rate"]!) == "用量到顶"
            && failShortWords(byID["a-retry"]!) == "正在重试 3/10" && failShortWords(byID["x-gone"]!) == "意外退出"
            && failShortWords(wbStop) == "已中止" && failShortWords(wbErr) == "出错" && failShortWords(plain) == nil)

    // ── 9. The sea room ──
    let zone = bgRenderZone(onStore)
    let members = Dictionary(ZonePlan.members(onStore, config: ZoneConfigFile.current(), now: Date()).map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
    check("error render zone: the errors are with the news (sofas), the exit seen (its own desk)",
        members["f-api"] == .unread && members["f-rate"] == .unread && members["x-gone"] == .seen && members["a-retry"] == .busy)
    check("error render zone: the exit's pet faint (45%), the others' not", zone.view.spriteLayer(of: "x-gone")?.opacity == 0.45 && zone.view.spriteLayer(of: "f-api")?.opacity == 1)
    if let desk = zone.view.plan.desks["x-gone"] {
        check("error render zone: the exit's screen dark, its LED off", !zone.view.screenShown(desk) && zone.view.ledColor(desk) == .off)
    } else {
        check("error render zone: the exit has its desk", false)
    }
    let red = ZoneGlow.plate("月光邮差 · API 出错 529", scale: 1, gold: false, tone: .red), dark = ZoneGlow.plate("月光邮差 · API 出错 529", scale: 1, gold: false)
    check("error render zone: the red plate differs from the plain one, same size", red.size == dark.size && errorRenderPixels(red.image) != errorRenderPixels(dark.image))
    restore()

    // ── 10. Words in three languages ──
    let rateSession = byID["f-rate"]!
    func words(_ lang: String) -> [String] {
        let before = L10n.language
        L10n.pin(lang)
        defer { L10n.pin(before) }
        return [exitedWords(), failedWords(), failShortWords(rateSession) ?? ""]
    }
    let hans = words("zh-Hans"), hant = words("zh-Hant"), en = words("en")
    check("error render i18n: Exited unexpectedly in Simplified / Traditional / English (the glossary's)", hans[0] == "意外退出" && hant[0] == "意外結束" && en[0] == "Exited unexpectedly")
    let newWords = hans[1] == "出错" && hans[2] == "用量到顶" && hant[1] == "出錯" && hant[2] == "用量已達上限" && en[1] == "Error" && en[2] == "Usage limit reached"
    check("error render i18n: the error words in each language: Error and Usage limit reached in Simplified / Traditional / English", newWords)
    let hansBoard = L10n.keys("Board", in: "zh-Hans") ?? [:], hantBoard = L10n.keys("Board", in: "zh-Hant") ?? [:], enBoard = L10n.keys("Board", in: "en") ?? [:]
    check("error render i18n: all three tables have the seven error keys",
        ["board.failed", "board.fail.retrying", "board.fail.rateLimit", "board.fail.relogin", "board.fail.stopped", "board.fail.apiStatus", "board.fail.api"].allSatisfy { hansBoard[$0] != nil && hantBoard[$0] != nil && enBoard[$0] != nil }
            && L10n.languages.allSatisfy { L10n.keys("Common", in: $0)?["common.exitedUnexpectedly"] != nil })

    // ── 11. No timer, nothing animated for a still state ──
    let officeText = (try? String(contentsOf: sources.appendingPathComponent("Office.swift"), encoding: .utf8)) ?? ""
    let zoneText = ["ZoneView.swift", "ZoneFX.swift", "ZoneModel.swift"].map { (try? String(contentsOf: sources.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined()
    check("error render: still one timer in the panel, none in the office or the sea room",
        panelText.components(separatedBy: "Timer.scheduledTimer").count == 2 && !officeText.contains("Timer.scheduledTimer") && !zoneText.contains("Timer.scheduledTimer"))
    let badgeText = panelText.components(separatedBy: "struct FailBadge").dropFirst().first?.components(separatedBy: "/// Wide layout").first ?? ""
    check("error render: the corner badge is still (no animation in it)", !badgeText.isEmpty && !badgeText.contains("animation") && !badgeText.contains("repeatForever"))
}

/// An image's pixels, drawn into one plain RGBA buffer (a renderer's own rows may carry padding that differs run to run).
func errorRenderPixels(_ image: CGImage?) -> [UInt8] {
    guard let image, let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let _ = Optional(ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))), let data = ctx.data
    else { return [] }
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
}

/// Made-up sessions for the checks and the pictures (invented names).
@MainActor func errorRenderCast() -> [Session] {
    let n = Date()
    func mk(_ s: Session, _ more: (inout Session) -> Void = { _ in }) -> Session {
        var s = s
        more(&s)
        return s
    }
    return [
        mk(errorRenderSession("w-ref", "waiting", ago: 360, name: "Ops-Demo-协同", project: "demo-a", summary: "要你批准：kubectl apply -f deploy.yaml")) { $0.waitingFor = "permission prompt" },
        errorRenderSession("f-api", "idle", ago: 420, kind: "api", errorStatus: 529, name: "Ops-月光邮差", project: "Ops-月光"),
        errorRenderSession("f-auth", "idle", ago: 300, kind: "auth", errorStatus: 403, name: "Web-流星导出", project: "Web-流星"),
        errorRenderSession("f-rate", "idle", ago: 900, kind: "rate_limit", errorStatus: 429, name: "Home-星图整理", project: "Home-星图"),
        mk(errorRenderSession("a-retry", "busy", ago: 120, retry: (3, 10), name: "AI-星舰起航", project: "AI-起航")) { $0.tool = "Bash" },
        mk(errorRenderSession("bg-1", "idle", ago: 540, name: "AI-星尘收集", project: "AI-星尘", summary: "两个后台任务已经起好：压缩旧日志，同步到 NAS")) {
            $0.bgTasks = 2; $0.bgAgents = 1; $0.bgSince = n - 23 * 60; $0.bgOwned = true },
        mk(errorRenderSession("bg-hung", "idle", ago: 3 * 3600 + 600, name: "Home-魔法小城堡", project: "Home-sky", summary: "开发服务器已起在 3000 端口")) {
            $0.bgTasks = 1; $0.bgSince = n - 3 * 3600 - 600; $0.bgStale = true },
        errorRenderSession("x-gone", "idle", ago: 2400, gone: true, name: "Home-Mermaid", project: "mermaid"),
        mk(errorRenderSession("b-plain", "busy", ago: 200, name: "Web-DEMO-应用", project: "demo-b", summary: "在改接口")) { $0.tool = "Edit" },
        errorRenderSession("u-news", "idle", ago: 100, name: "Web-UX-星图", project: "Web-UX", summary: "检查完了，三处告警，详情在 out/ci.md"),
        errorRenderSession("s-seen", "idle", ago: 1800, name: "Home-云朵", project: "Home-云朵", summary: "整理完了，结果在 report.md"),
        errorRenderSession("r-rest", "idle", ago: 9 * 3600, name: "Home-风车修理", project: "fw", summary: "已升到 7.18"),
        errorRenderSession("k-wb", "idle", ago: 1700, kind: "wb_error", name: "Web-WB星报", project: "WorkBuddy", summary: "出错", agent: "workbuddy"),
    ]
}

/// A store of these, the errors not looked at, the news not looked at, the rest looked at.
@MainActor func errorRenderStore(_ sessions: [Session]) -> Store {
    let store = boardSweepStore(sessions, agents: [:])
    for s in sessions where s.id.hasPrefix("f-") || s.id.hasPrefix("k-wb") || s.id.hasPrefix("u-") { store.seen[s.id] = 0 }
    return store
}

// ───────── The pictures ─────────

@MainActor func errorRenderStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    OfficeTheme.shown = OfficeTheme.studio
    UserDefaults.standard.removeObject(forKey: "showFailed")
    defer { OfficeTheme.shown = nil; BGWalker.stillTime = 1.0 }
    BGWalker.stillTime = 1.0
    let restore = seaSweepSetup(NSTemporaryDirectory() + "errrender-zones-\(getpid())")
    defer { restore() }
    let p = { (n: String) in dir + "/" + n }
    let lang = L10n.language

    let all = errorRenderStore(errorRenderCast())
    bgRenderSheet(title: "Error render · duty room · wide card (\(lang))",
             note: "Errors (brick red): 月光邮差 (API error 529), 流星导出 (sign in again), WB 星报 (WorkBuddy error); usage limit (amber) in the same group; retrying (amber) in the working group; exited unexpectedly: grey card under the looked-at ones; the bar's error count = the group's size",
             panels: [("640 pt wide, 2x", bgRenderBoard(all, width: 640))], columns: 1, to: p("01-duty-room-wide-card.png"))
    bgRenderSheet(title: "Error render · duty room · narrow row (\(lang))", note: "Avatar top right: ! error · ↻ retry/usage · × exited unexpectedly; red/amber row tint stronger; exited-unexpectedly avatar at 45%",
             panels: [("420 pt wide, 2x", bgRenderBoard(all, width: 420))], columns: 1, to: p("02-duty-room-narrow-row.png"))
    // A narrower wide card: the project gives way, the name stays.
    let long = [errorRenderSession("f-api", "idle", ago: 420, kind: "api", errorStatus: 529, name: "Ops-月光邮差-月底批量重算", project: "Ops-月光"),
                errorRenderSession("f-auth", "idle", ago: 300, kind: "auth", errorStatus: 403, name: "Web-流星导出-季度汇总", project: "Web-流星"),
                errorRenderSession("x-gone", "idle", ago: 2400, gone: true, name: "Home-Mermaid-Family", project: "mermaid"),
                errorRenderSession("a-retry", "busy", ago: 120, retry: (3, 10), name: "AI-星舰起航-推理服务", project: "AI-起航")]
    bgRenderSheet(title: "Error render · name truncation (\(lang))", note: "Two-column wide card (640 pt), long session names: when they do not fit the project name goes first and the session name is kept; only then is the session name cut",
             panels: [("640 pt", bgRenderBoard(errorRenderStore(long), width: 640))], columns: 1, to: p("01b-duty-room-name-truncation.png"))
    bgRenderSheet(title: "Error render · office (\(lang))", note: "Error: red name plate (white text) on the sofa, amber plate = usage limit; retrying: dark name plate at the desk with an amber dot; exited unexpectedly: grey plate + semi-transparent figure standing by the desk, screen off",
             panels: [("1194 × 764 pt", officeStill(all, size: CGSize(width: 1194, height: 764)))], columns: 1, to: p("03-office.png"))
    let layout = OfficePainter.layout(all, now: Date())
    func hoverCrop(_ id: String) -> CGImage? {
        guard let me = layout.pets.first(where: { $0.id == id }) else { return nil }
        all.hovered = id
        defer { all.hovered = nil }
        let x = max(0, min(me.x - 220, 1194 - 640)), y = max(0, min(me.foot - 170, 764 - 260))
        return bgRenderCrop(officeStill(all, size: CGSize(width: 1194, height: 764)), CGRect(x: x, y: y, width: 640, height: 260))
    }
    bgRenderSheet(title: "Error render · office hover card (\(lang))", note: "Stripe: red = error, amber = retry / usage, grey = exited unexpectedly",
             panels: [("error", hoverCrop("f-api")), ("retrying", hoverCrop("a-retry")), ("usage limit", hoverCrop("f-rate")), ("exited unexpectedly", hoverCrop("x-gone"))],
             columns: 2, to: p("03b-office-hover-card.png"))
    let zone = bgRenderZone(errorRenderStore(errorRenderCast()))
    bgRenderSheet(title: "Error render · sea room (\(lang))", note: "Error: red name plate with white text (API error 529), seated on the sofa; amber edge: retry / usage; exited unexpectedly: semi-transparent figure standing by its own desk, grey-edged plate (exited unexpectedly), screen off",
             panels: [("1194 × 900 pt", zone.image)], columns: 1, to: p("04-sea-room.png"))

    // The menu bar and the title bar's counts.
    func bar(_ cases: [(Int, Int, Int)], dark isDark: Bool) -> CGImage? {
        let barHigh: CGFloat = 22, scale: CGFloat = 6, cell: CGFloat = 44
        let w = cell * CGFloat(cases.count) + 12
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w * scale), pixelsHigh: Int(barHigh * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        NSAppearance(named: isDark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            NSColor(white: isDark ? 0.16 : 0.93, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: w, height: barHigh).fill()
            for (i, c) in cases.enumerated() {
                var image = statusIcon(waiting: c.0, unread: c.1, failed: c.2)
                if image.isTemplate {
                    let base = image
                    image = NSImage(size: base.size, flipped: false) { b in
                        base.draw(in: b)
                        (isDark ? NSColor.white : NSColor.black.withAlphaComponent(0.85)).setFill()
                        b.fill(using: .sourceAtop)
                        return true
                    }
                }
                image.draw(in: NSRect(x: 6 + CGFloat(i) * cell + ((cell - image.size.width) / 2).rounded(), y: ((barHigh - image.size.height) / 2).rounded(),
                                      width: image.size.width, height: image.size.height))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.cgImage
    }
    let cases = [(0, 0, 0), (0, 0, 1), (1, 2, 2), (0, 2, 0)]
    let menuLines = cases.map { menuCountsTitle(waiting: $0.0, unread: $0.2, busy: 1, failed: $0.1) }
    let counts = { (narrow: Bool) -> CGImage? in
        all.narrow = narrow
        defer { all.narrow = false }
        let renderer = ImageRenderer(content: CountsBar(store: all).padding(6).background(night).environment(\.colorScheme, .dark))
        renderer.scale = 2
        return renderer.cgImage
    }
    bgRenderSheet(title: "Error render · menu bar and title bar (\(lang))",
             note: "Four cells, left to right: idle / error 1 / waiting 1 + error 2 + news 2 / news 2 only; badge = waiting + error + news, red when any waiting or error; exited-unexpectedly is not in the badge\nMenu first line: " + menuLines.joined(separator: "｜"),
             panels: [("dark menu bar", bar(cases, dark: true)), ("light menu bar", bar(cases, dark: false)), ("title bar counts (wide)", counts(false)), ("title bar counts (narrow)", counts(true))],
             columns: 1, to: p("05-menu-bar-and-title-bar.png"))

    // The exit alone, the three screens.
    let goneStore = errorRenderStore(errorRenderCast().filter { ["x-gone", "s-seen"].contains($0.id) })
    let goneLayout = OfficePainter.layout(goneStore, now: Date())
    let officeCrop: CGImage? = goneLayout.pets.first { $0.id == "x-gone" }.flatMap { me in
        bgRenderCrop(officeStill(goneStore, size: CGSize(width: 1194, height: 764)), CGRect(x: max(0, me.x - 140), y: max(0, me.foot - 120), width: 280, height: 170))
    }
    let gz = bgRenderZone(goneStore)
    let zoneCrop: CGImage? = gz.view.foot(of: "x-gone").flatMap { f in bgRenderCrop(gz.image, CGRect(x: f.x - 160, y: f.y - 150, width: 320, height: 200)) }
    bgRenderSheet(title: "Error render · exited unexpectedly (\(lang))", note: "Duty room: grey card, avatar at 45%, × badge, its own group under the looked-at ones; office / sea room: semi-transparent figure by its own desk, grey plate, screen off, counted nowhere",
             panels: [("duty room wide card", bgRenderBoard(goneStore, width: 640)), ("duty room narrow row", bgRenderBoard(goneStore, width: 420)), ("office", officeCrop), ("sea room", zoneCrop)],
             columns: 2, to: p("06-exited-unexpectedly.png"))

    // showFailed off: the plain look.
    UserDefaults.standard.set(false, forKey: "showFailed")
    let offStore = errorRenderStore(Store.shown(errorRenderCast()))
    bgRenderSheet(title: "Error render · error display off, showFailed=NO (\(lang))", note: "Matches the plain display: no error group, no colours, exited-unexpectedly sessions stay off the board",
             panels: [("640 pt", bgRenderBoard(offStore, width: 640))], columns: 1, to: p("07-showFailed-NO.png"))
    UserDefaults.standard.removeObject(forKey: "showFailed")
}
