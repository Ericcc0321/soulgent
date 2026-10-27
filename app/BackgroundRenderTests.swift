// Background work rendering. Work running in the background (`--dump`'s bgTasks > 0, idle) counts as at work on every
// screen: the board's groups, the celebration, the unread rule, the rest, the notice board, the menu bar's count, and the
// little walkers beside the pet (a layer each, two repeating Core Animation animations, no timer, no per-frame drawing).
// `--bg-render-only` runs the checks; `--bg-render-stills <dir>` draws the pictures.

import AppKit
import SwiftUI

@MainActor func bgRenderSession(_ id: String, _ status: String, ago: TimeInterval = 60, origin: String = "user", bg: Int = 0, agents: Int = 0, stale: Bool = false,
                           owned: Bool = false, endedAgo: TimeInterval? = nil, name: String? = nil, summary: String = "", project: String = "demo-bg") -> Session {
    var s = boardSweepSession(id, status, ago: ago, name: name ?? id, project: project, summary: summary)
    s.origin = origin
    s.bgTasks = bg
    s.bgAgents = agents
    s.bgSince = bg > 0 ? Date().addingTimeInterval(-(stale ? 3 * 3600 : 23 * 60)) : nil
    s.bgStale = stale
    s.bgOwned = owned
    s.bgEndedAt = endedAgo.map { Date().addingTimeInterval(-$0) }
    return s
}

@MainActor func bgRenderTests() {
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    let defaults = UserDefaults.standard
    defaults.removeObject(forKey: "bgCountsAsWorking")
    let now = Date()

    // ── 1. The reading: busy, or idle with background work that is not hung ──
    let busy = bgRenderSession("a-busy", "busy"), bg = bgRenderSession("a-bg", "idle", bg: 2), hung = bgRenderSession("a-hung", "idle", ago: 3 * 3600 + 60, bg: 1, stale: true)
    let plain = bgRenderSession("a-plain", "idle"), wait = bgRenderSession("a-wait", "waiting", bg: 1)
    check("background work: isWorking — busy yes; idle with background work yes; idle with it hung no; idle with none no; waiting no",
        busy.isWorking && bg.isWorking && bg.isBackgroundWorking && !hung.isWorking && hung.isBackgroundHung && !plain.isWorking && !wait.isWorking)
    check("background work: the dump's status is untouched (idle stays idle) and the helpers stay the contract's",
        bg.status == "idle" && bgRenderSession("h", "idle", bg: 3, agents: 2).helpers(subagents: 1) == 3 && bgRenderSession("h", "idle", bg: 3, agents: 2).helpers(subagents: 4) == 5)

    // ── 2. Groups, the blue badge, rest, pose ──
    let store = Store()
    store.readOnly = true
    let longBg = bgRenderSession("a-long", "idle", ago: 9 * 3600, bg: 1)  // its turn ended nine hours ago, its task still runs
    store.sessions = [busy, bg, hung, plain, longBg]
    store.seen["a-hung"] = now.timeIntervalSince1970
    store.seen["a-plain"] = now.timeIntervalSince1970
    let b = Buckets(store, now: now)
    check("background work: busy holds the busy one and the two with background work; the hung one is looked-at, the plain one looked-at",
        Set(b.busy.map(\.id)) == ["a-busy", "a-bg", "a-long"] && Set(b.seen.map(\.id)) == ["a-hung", "a-plain"])
    check("background work: background work is not news, not resting: nothing under unread, nobody in the rest area (nine hours on)", b.unread.isEmpty && b.resting.isEmpty)
    check("background work: no blue badge for it (the badge counts waiting + unread)", statusBadge(waiting: b.waiting.count, unread: b.unread.count) == nil
        && menuCountsTitle(waiting: 0, unread: 0, busy: b.busy.count).contains("3 在干活"))
    check("background work: its pet stands (the idle frame, the walker beside it works); busy keeps the working pose; the hung one stands too",
        store.pose(of: bg, now: now) == .standing && store.pose(of: busy, now: now) == .working && store.pose(of: hung, now: now) == .standing
            && !store.isFresh(bg) && !store.isUnread(bg))

    // ── 3. Finished: the time, the unread rule ──
    let u1 = bgRenderSession("u-user", "idle", ago: 3600, origin: "user", bg: 0, endedAgo: 30)        // a user turn, its task ended 30 s ago
    let u2 = bgRenderSession("u-agent-owned", "idle", ago: 20, origin: "agent", owned: true, endedAgo: 25)  // the report of work the user started
    let u3 = bgRenderSession("u-agent-plain", "idle", ago: 20, origin: "agent", owned: false)             // a subagent's report on nothing of theirs
    let u4 = bgRenderSession("u-old", "idle", ago: 3600, origin: "user", bg: 0, endedAgo: 7200)          // ended before the turn
    store.sessions = [u1, u2, u3, u4]
    for id in ["u-user", "u-agent-owned", "u-agent-plain", "u-old"] { store.seen[id] = now.timeIntervalSince1970 - 600 }
    check("background work: finishedAt = max(since, bgEndedAt)", u1.finishedAt == u1.bgEndedAt && u4.finishedAt == u4.since && u2.finishedAt == u2.since)
    check("background work: the end of background work makes a session unread after a look (its turn was older than the look)", store.isFresh(u1) && store.isUnread(u1))
    check("background work: a task-notification turn (origin agent) is news when bgOwned, and not when it is not", store.isFresh(u2) && !store.isFresh(u3))
    check("background work: a task that ended before the look is nothing new", !store.isFresh(u4))
    defaults.set(false, forKey: "bgCountsAsWorking")
    check("background work: with bgCountsAsWorking off the old reading: the agent report is no news, the task's end moves nothing",
        !store.isFresh(u2) && u1.finishedAt == u1.since && !store.isFresh(u1) && !bg.isWorking && !hung.isBackgroundHung)
    store.sessions = [bg, longBg, busy]
    let off = Buckets(store, now: now)
    check("background work: with it off, idle with background work is idle again: unread when fresh, resting when old; busy stays busy",
        off.busy.map(\.id) == ["a-busy"] && off.unread.map(\.id) == ["a-bg"] && off.resting.map(\.id) == ["a-long"])
    defaults.removeObject(forKey: "bgCountsAsWorking")

    // ── 4. Hung: back to looked-at ──
    store.sessions = [hung, bgRenderSession("a-hung2", "idle", ago: 3 * 3600 + 60, bg: 1, stale: true)]
    store.seen["a-hung2"] = nil
    let hb = Buckets(store, now: now)
    check("background work: hung background work is not at work: looked at when its last turn was looked at (a grey walker stands, the card says so)",
        hb.busy.isEmpty && hb.seen.map(\.id) == ["a-hung"] && store.pose(of: hung, now: now) == .standing)
    check("background work: …and a result never looked at is let through once, as the contract says (the hung one it belongs to is unread)", hb.unread.map(\.id) == ["a-hung2"])

    // ── 5. The celebration, once, when the work is truly done ──
    let c = Store()
    c.readOnly = true
    let t0 = now
    c.take([bgRenderSession("c1", "busy", origin: "user", bg: 0)], at: t0)
    c.take([bgRenderSession("c1", "idle", ago: 0, origin: "user", bg: 2, owned: true)], at: t0.addingTimeInterval(2))
    check("background work: busy → idle with background work: no celebration (it is still at work)", c.celebrating["c1"] == nil)
    c.take([bgRenderSession("c1", "idle", ago: 0, origin: "user", bg: 1, owned: true)], at: t0.addingTimeInterval(4))
    check("background work: one task of two ended: still none", c.celebrating["c1"] == nil)
    c.take([bgRenderSession("c1", "busy", ago: 0, origin: "agent", bg: 0, owned: true, endedAgo: 0)], at: t0.addingTimeInterval(6))
    check("background work: the last ended and the report turn begins (busy): still at work, none", c.celebrating["c1"] == nil)
    c.take([bgRenderSession("c1", "idle", ago: 0, origin: "agent", bg: 0, owned: true, endedAgo: 3)], at: t0.addingTimeInterval(8))
    // The celebration is decided a tick later (an error's line may land after the registry says idle).
    c.take([bgRenderSession("c1", "idle", ago: 0, origin: "agent", bg: 0, owned: true, endedAgo: 3)], at: t0.addingTimeInterval(10))
    check("background work: the report turn done: the celebration, now", c.celebrating["c1"] != nil)
    c.celebrating = [:]
    c.take([bgRenderSession("c1", "idle", ago: 0, origin: "agent", bg: 0, owned: true, endedAgo: 3)], at: t0.addingTimeInterval(12))
    check("background work: and not again while it stays idle", c.celebrating["c1"] == nil)
    // The last task's end shows (idle, none left) and a moment later the report turn runs: one celebration for the finish.
    let d = Store()
    d.readOnly = true
    d.take([bgRenderSession("d1", "idle", origin: "user", bg: 1, owned: true)], at: t0)
    d.take([bgRenderSession("d1", "idle", ago: 0, origin: "user", bg: 0, owned: true, endedAgo: 0)], at: t0.addingTimeInterval(2))
    d.take([bgRenderSession("d1", "idle", ago: 0, origin: "user", bg: 0, owned: true, endedAgo: 0)], at: t0.addingTimeInterval(3))  // a tick later
    check("background work: the end of the last task with no turn after it celebrates", d.celebrating["d1"] != nil)
    d.celebrating = [:]
    d.take([bgRenderSession("d1", "busy", ago: 0, origin: "agent", owned: true)], at: t0.addingTimeInterval(4))
    d.take([bgRenderSession("d1", "idle", ago: 0, origin: "agent", owned: true, endedAgo: 6)], at: t0.addingTimeInterval(7))
    d.take([bgRenderSession("d1", "idle", ago: 0, origin: "agent", owned: true, endedAgo: 6)], at: t0.addingTimeInterval(9))  // a tick later
    check("background work: the report turn right after it does not celebrate a second time (inside the gap)", d.celebrating["d1"] == nil)
    let e = Store()
    e.readOnly = true
    e.take([bgRenderSession("e1", "busy", origin: "agent", owned: false)], at: t0)
    e.take([bgRenderSession("e1", "idle", origin: "agent", owned: false)], at: t0.addingTimeInterval(2))
    e.take([bgRenderSession("e2", "busy", origin: "user")], at: t0.addingTimeInterval(3))
    e.take([bgRenderSession("e2", "idle", origin: "user")], at: t0.addingTimeInterval(5))
    e.take([bgRenderSession("e2", "idle", origin: "user")], at: t0.addingTimeInterval(7))  // a tick later
    check("background work: a plain user turn still celebrates; an agent turn with no background work of his does not", e.celebrating["e1"] == nil && e.celebrating["e2"] != nil)

    // ── 6. The notice board: no "done" line while it works in the background ──
    let began = OfficeActivity.events(from: [bgRenderSession("n1", "busy")], to: [bgRenderSession("n1", "idle", bg: 2)], at: now)
    let ended = OfficeActivity.events(from: [bgRenderSession("n1", "idle", bg: 1)], to: [bgRenderSession("n1", "idle", bg: 0, owned: true, endedAgo: 0)], at: now)
    let report = OfficeActivity.events(from: [bgRenderSession("n2", "busy", origin: "agent", owned: true)], to: [bgRenderSession("n2", "idle", origin: "agent", owned: true)], at: now)
    let plainReport = OfficeActivity.events(from: [bgRenderSession("n3", "busy", origin: "agent")], to: [bgRenderSession("n3", "idle", origin: "agent")], at: now)
    check("background work: the board says nothing when busy turns into idle with background work", began.isEmpty)
    check("background work: it says done (news) when the background work ends, and when the report of work he started finishes",
        ended.first?.kind == .finished && ended.first?.origin == nil && report.first?.kind == .finished && report.first?.origin == nil)
    check("background work: a subagent's report on nothing of his is logged normally (marked, not news)", plainReport.first?.origin == "agent")

    // ── 7. One count of helpers ──
    let hs = Store()
    hs.readOnly = true
    let hb2 = bgRenderSession("hh", "idle", bg: 3, agents: 2)
    hs.sessions = [hb2]
    hs.agentCounts = ["hh": 2]
    hs.agents = ["hh": [OfficeSubagents.Agent(description: "查日志", model: "", agentType: "codex:codex-rescue"), OfficeSubagents.Agent(description: "写", model: "", agentType: "Explore")]]
    let helperKeys = ["helperPetClaude", "helperPetCodex"], helperWere = helperKeys.map { UserDefaults.standard.object(forKey: $0) }
    UserDefaults.standard.set("test-pet-claude", forKey: "helperPetClaude")
    UserDefaults.standard.set("test-pet-codex", forKey: "helperPetCodex")
    check("background work: helpers merges (two subagents counted once, one command besides): 3, and a walker pet for each (the Codex one the Codex helpers' pet, the command the others')",
        hs.helpers(of: hb2) == 3 && hs.walkerPets(of: hb2) == ["test-pet-codex", "test-pet-claude", "test-pet-claude"])
    for (key, was) in zip(helperKeys, helperWere) { if let was { UserDefaults.standard.set(was, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }
    hs.agentCounts = [:]
    check("background work: with no subagent directory the background ones still count: 3", hs.helpers(of: hb2) == 3)

    // ── 8. The words ──
    check("background work: the words are in the table: BG N, the suspected-hung words (and the tables carry them in all three languages)",
        bgCountWords(2) == "BG 2" && bgHungWords() == "后台任务疑似挂住" && (L10n.keys("Board", in: "en")?["bg.count"] != nil) && (L10n.keys("Common", in: "zh-Hant")?["common.bg.hung"] != nil))
    // The count is BG N in all three, the card's command line each language's own, none written in the code.
    var words: [String] = []
    for lang in ["zh-Hans", "zh-Hant", "en"] {
        L10n.reset(); L10n.pin(lang)
        words += [bgCountWords(3), bgCommandsWords(1), bgCommandsWords(2)]
    }
    L10n.reset(); L10n.pin(L10n.source)
    check("background work: BG N in all three; the Simplified, Traditional and English background-command words from the tables (\(words.joined(separator: " | ")))",
        words == ["BG 3", "后台命令 1 个", "后台命令 2 个", "BG 3", "背景指令 1 個", "背景指令 2 個", "BG 3", "1 background command", "2 background commands"])
    let commandHelper = bgRenderSession("hc", "idle", bg: 3, agents: 1)
    check("background work: the card's helper line reads the table: the Simplified count of 2 commands", OfficeCard.helperLines(commandHelper, []) == ["后台命令 2 个"])

    // ── 8b. bg-scan.json: a Bash call unanswered for more than a day leaves the table ──
    var scan = BGScan()
    scan.asked = ["old": "ancient", "fresh": "recent"]
    scan.askedAt = ["old": now.addingTimeInterval(-25 * 3600), "fresh": now.addingTimeInterval(-3600)]
    let dropped = scan.dropOldAsked(now: now)
    check("background work: bg-scan: a call asked 25 hours ago and never answered is dropped, one asked an hour ago stays", dropped && scan.asked == ["fresh": "recent"] && scan.askedAt.keys.sorted() == ["fresh"])
    var written = BGScan()
    written.path = "/x"; written.inode = 1; written.offset = 1
    written.asked = ["k": "d"]; written.askedAt = ["k": now.addingTimeInterval(-26 * 3600)]
    var loaded = BGScan.decode(BGScan.encode(["s": written]))["s"]
    check("background work: bg-scan: the stamps go through the file, and a loaded table drops what is a day old at its next look", loaded?.askedAt["k"] != nil && loaded?.dropOldAsked(now: now) == true && loaded?.asked.isEmpty == true)
    var oldFile = written
    oldFile.askedAt = [:]
    let reread = BGScan.decode(BGScan.encode(["s": oldFile]))["s"]
    check("background work: bg-scan: a file from before the stamps is read still (its calls are stamped from now on)", reread?.asked == ["k": "d"])

    // ── 9. The walkers: layers, animations, no timers ──
    Pets.shared.refresh(force: true)
    guard let cut = BGWalker.cut(PetSources.builtInID, tall: 19) else {
        check("background work: the walker's pet (the built-in flame) is cut", false)
        return
    }
    let from = CGPoint(x: 10, y: 40), to = CGPoint(x: 80, y: 40)
    let walking = BGWalker.layer(cut, from: from, to: to, yDown: true, mode: .walks, phase: 0.3, rest: 0.5)
    let keys = Set(walking?.animationKeys() ?? [])
    let go = walking?.animation(forKey: "bgwalk") as? CAKeyframeAnimation, steps = walking?.animation(forKey: "bgsteps") as? CAKeyframeAnimation
    check("background work: a walking walker is one layer with two animations (position, frames), both repeating for ever, no sublayers",
        keys == ["bgwalk", "bgsteps"] && (walking?.sublayers ?? []).isEmpty && go?.repeatCount == .infinity && steps?.repeatCount == .infinity && go?.keyPath == "position"
            && steps?.keyPath == "contents" && go?.duration == steps?.duration)
    check("background work: the position goes there and back linearly along the lane, the frames are the pet's eight running frames each way, in 0.1 s steps",
        go?.values?.count == 3 && go?.calculationMode == .linear && steps?.calculationMode == .discrete && (steps?.values?.count ?? 0) >= 16
            && abs(((steps?.duration ?? 0) / 0.1).rounded() * 0.1 - (steps?.duration ?? 0)) < 1e-9)
    let standing = BGWalker.layer(cut, from: from, to: to, yDown: true, mode: .stands, phase: 0, rest: 0.5)
    let grey = BGWalker.layer(cut, from: from, to: to, yDown: true, mode: .hung, phase: 0, rest: 0.5)
    let catching = BGWalker.layer(cut, from: from, to: to, yDown: true, mode: .caught(1.3), phase: 0.3, rest: 0.5)
    check("background work: standing (Reduce Motion), hung (grey, 55%) and a picture's walker have no animation at all",
        (standing?.animationKeys() ?? []).isEmpty && (grey?.animationKeys() ?? []).isEmpty && (catching?.animationKeys() ?? []).isEmpty && grey?.opacity == BGWalker.hungOpacity)
    let sourcesDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    var noClock = true
    for file in ["ZoneFX.swift", "ZoneView.swift"] {
        let text = (try? String(contentsOf: sourcesDir.appendingPathComponent(file), encoding: .utf8)) ?? ""
        if text.count < 10_000 || text.contains("Timer") || text.contains("CVDisplayLink") || text.contains("CADisplayLink") || text.contains("TimelineView") { noClock = false }
    }
    let panelText = panelSources(sourcesDir)
    let officeText = (try? String(contentsOf: sourcesDir.appendingPathComponent("Office.swift"), encoding: .utf8)) ?? ""
    check("background work: no clock added: the walkers' sources schedule no Timer, display link or TimelineView; Panel keeps its one tick, Office none",
        noClock && panelText.components(separatedBy: "scheduledTimer").count - 1 == 1 && !officeText.contains("scheduledTimer") && !officeText.contains("CADisplayLink")
            && !panelText.contains("CADisplayLink"))
    // The walk of the picture is the walk of the screen: at the same time, the same place.
    let a = BGWalker.caught(1.3, phase: 0.3, lane: 70), s0 = BGWalker.state(at: 1.3 + 0.3 * BGWalker.cycle(lane: 70), cycle: BGWalker.cycle(lane: 70))
    check("background work: a picture catches the walker where its animation would have it", a.u == s0.u && a.right == s0.right && a.column == s0.column)

    // ── 10. The office: ten sessions at work in the background, one layer each walker ──
    var tens: [Session] = []
    for i in 0..<10 { tens.append(bgRenderSession("w\(i)", "idle", ago: 100, bg: 2, agents: 2, name: "Home-任务\(i)")) }
    let big = Store()
    big.readOnly = true
    big.sessions = tens
    _ = officeDealCutPets(big)
    let view = OfficeView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    view.update(big)
    let holders = (view.stage.sublayers ?? []).filter { ($0.name ?? "").hasPrefix("walkers") }
    let layers = holders.flatMap { $0.sublayers ?? [] }
    let animations = layers.reduce(0) { $0 + ($1.animationKeys() ?? []).count }
    check("background work: office: ten sessions with background work: ten desks each with its walkers (2 each): \(holders.count) holders, \(layers.count) layers, \(animations) animations",
        holders.count == 10 && layers.count == 20 && animations == 40)
    check("background work: office: every walker's animations are the two repeating ones; none has any other (no per-frame callbacks)",
        layers.allSatisfy { Set($0.animationKeys() ?? []) == ["bgwalk", "bgsteps"] })
    check("background work: office: the desks' lit screens are on and nobody sits at the sofas (at work, not news)",
        OfficePainter.lit(big, OfficePainter.layout(big, now: Date())).count == 10)
    let seatedIDs = Set(OfficePainter.layout(big, now: Date()).pets.filter { $0.zone == .desk }.map(\.id))
    check("background work: office: all ten sit at their desks", seatedIDs.count == 10)
    // Back to idle: the walkers go.
    var ended10 = tens
    for i in ended10.indices { ended10[i].bgTasks = 0; ended10[i].bgAgents = 0; ended10[i].bgSince = nil }
    big.sessions = ended10
    view.update(big)
    check("background work: office: with the background work done the walkers are gone", ((view.stage.sublayers ?? []).filter { ($0.name ?? "").hasPrefix("walkers") }).isEmpty)

    // ── 11. The sea room: the walkers on the desk's edge, the desk-cover order ──
    guard ZoneArt.scene != nil else { return check("background work: sea room: needs the art", false) }
    let zs = Store()
    zs.readOnly = true
    var zsess = [bgRenderSession("Home-bg1", "idle", bg: 2, agents: 1, name: "Home-bg1"), bgRenderSession("Home-bg2", "idle", ago: 3 * 3600 + 60, bg: 1, stale: true, name: "Home-bg2"),
                 bgRenderSession("Home-run", "busy", name: "Home-run")]
    for i in zsess.indices { zsess[i] = { var x = zsess[i]; x.cwd = "/tmp"; x.model = i == 0 || i == 2 ? "claude-fable-5-1" : ""; return x }() }
    zs.sessions = zsess
    zs.seen["Home-bg2"] = now.timeIntervalSince1970
    zs.assignPets()
    zs.agentCounts = ["Home-bg1": 1]
    let zview = ZoneView(frame: CGRect(x: 0, y: 0, width: 1194, height: 900))
    zview.update(zs)
    for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    let zh = zview.agentHolder(of: "Home-bg1"), zg = zview.agentHolder(of: "Home-bg2")
    let zl = zh?.sublayers ?? []
    check("background work: sea room: the working one has its walkers on the desk (two helpers → two layers, two animations each); the hung one has grey ones standing; busy with none has none",
        zl.count == 2 && zl.allSatisfy { Set($0.animationKeys() ?? []) == ["bgwalk", "bgsteps"] } && (zg?.sublayers ?? []).count == 1
            && (zg?.sublayers ?? []).allSatisfy { ($0.animationKeys() ?? []).isEmpty && $0.opacity == BGWalker.hungOpacity } && zview.agentHolder(of: "Home-run") == nil)
    if let desk = zview.plan.desks["Home-bg1"], let layer = zview.deskLayer(desk), let holder = zh {
        check("background work: sea room: the walkers are in the stage just in front of their own desk's layer, not raised above everything: z \(holder.zPosition) over the desk's \(layer.holder.zPosition)",
            holder.zPosition > layer.holder.zPosition && holder.zPosition - layer.holder.zPosition < 0.5 && holder.superlayer === zview.stageLayer)
    } else {
        check("background work: sea room: the working one has a desk with a foreground layer", false)
    }
    // The Fable aura has two looks (`ZoneAura.busyLook`, `calmLook`): the busy one only for a really busy session; one that works in
    // the background wears the weak one (effects stay at the weak level while it works in the background).
    check("background work: sea room: a Fable session with background work wears the aura's weak look, a busy one the strong look",
        zview.aura(of: "Home-bg1").map { !ZoneAura.isBusy($0) } == true && zview.aura(of: "Home-run").map { ZoneAura.isBusy($0) } == true)
    defaults.removeObject(forKey: "bgCountsAsWorking")
}

// ───────── The stills ─────────

@MainActor func bgRenderDrawText(_ ctx: CGContext, _ text: String, x: CGFloat, top: CGFloat, height: CGFloat, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
    let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attributed.draw(at: NSPoint(x: x, y: height - top - size * 1.25))
    NSGraphicsContext.restoreGraphicsState()
}

/// A sheet: a title, a note, the panels in a grid under their labels.
@MainActor func bgRenderSheet(title: String, note: String, panels: [(label: String, image: CGImage?)], columns: Int, to path: String) {
    let items = panels.compactMap { p in p.image.map { (p.label, $0) } }
    guard !items.isEmpty else { return print("background work: nothing for \(path)") }
    let margin: CGFloat = 48, gap: CGFloat = 36, labelHigh: CGFloat = panels.allSatisfy { $0.label.isEmpty } ? 0 : 52
    let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
    var colWide = [CGFloat](repeating: 0, count: columns)
    for row in rows { for (i, item) in row.enumerated() { colWide[i] = max(colWide[i], CGFloat(item.1.width)) } }
    let rowHigh = rows.map { row in row.map { CGFloat($0.1.height) }.max() ?? 0 }
    let width = margin * 2 + colWide.reduce(0, +) + gap * CGFloat(max(0, columns - 1))
    let perLine = max(20, Int((width - 2 * margin) / 29))
    var noteLines: [String] = []
    for raw in (note.isEmpty ? [] : note.components(separatedBy: "\n")) {
        var rest = Substring(raw)
        while rest.count > perLine { noteLines.append(String(rest.prefix(perLine))); rest = rest.dropFirst(perLine) }
        noteLines.append(String(rest))
    }
    let head: CGFloat = 96 + CGFloat(noteLines.count) * 40 + 20
    let height = head + rowHigh.reduce(0, +) + labelHigh * CGFloat(rows.count) + gap * CGFloat(rows.count) + margin
    guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.setFillColor(OfficeCanvas.rgb(0x0B0A14))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    bgRenderDrawText(ctx, title, x: margin, top: 34, height: height, size: 60, weight: .heavy, color: .white)
    for (i, line) in noteLines.enumerated() {
        bgRenderDrawText(ctx, line, x: margin, top: 112 + CGFloat(i) * 40, height: height, size: 28, weight: .regular, color: NSColor(white: 0.78, alpha: 1))
    }
    var y = head
    for (r, row) in rows.enumerated() {
        var x = margin
        for (i, item) in row.enumerated() {
            if !item.0.isEmpty { bgRenderDrawText(ctx, item.0, x: x, top: y, height: height, size: 30, weight: .semibold, color: NSColor(0xFFC27A)) }
            let img = item.1
            ctx.interpolationQuality = .none
            ctx.draw(img, in: CGRect(x: x, y: height - (y + labelHigh) - CGFloat(img.height), width: CGFloat(img.width), height: CGFloat(img.height)))
            x += colWide[i] + gap
        }
        y += labelHigh + rowHigh[r] + gap
    }
    save(ctx.makeImage(), path)
    print("background work: \(path)")
}

func bgRenderCrop(_ image: CGImage?, _ r: CGRect, scale k: CGFloat = 2) -> CGImage? {
    guard let image else { return nil }
    let box = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return image.cropping(to: box.integral)
}

/// Made-up sessions for the pictures (invented names).
@MainActor func bgRenderCast() -> [Session] {
    let n = Date()
    func mk(_ id: String, _ status: String, ago: TimeInterval, name: String, project: String, summary: String, _ more: (inout Session) -> Void = { _ in }) -> Session {
        var s = bgRenderSession(id, status, ago: ago, name: name, summary: summary, project: project)
        s.cwd = "/tmp/bgrender/" + name
        s.registryName = name
        more(&s)
        return s
    }
    return [
        mk("w-ref", "waiting", ago: 360, name: "Ops-Demo-协同", project: "demo-a", summary: "要你批准：kubectl apply -f deploy.yaml") { $0.waitingFor = "permission prompt" },
        mk("bg-1", "idle", ago: 540, name: "AI-星尘收集", project: "AI-星尘", summary: "两个后台任务已经起好：压缩旧日志，同步到 NAS") {
            $0.bgTasks = 2; $0.bgAgents = 1; $0.bgSince = n - 23 * 60; $0.bgOwned = true },
        mk("bg-3", "idle", ago: 1500, name: "Ops-云海整理", project: "Ops-云海", summary: "三个转换脚本在后台跑，完成后我再汇总") {
            $0.bgTasks = 3; $0.bgSince = n - 50 * 60; $0.bgOwned = true },
        mk("bg-hung", "idle", ago: 3 * 3600 + 600, name: "Home-魔法小城堡", project: "Home-sky", summary: "开发服务器已起在 3000 端口") {
            $0.bgTasks = 1; $0.bgSince = n - 3 * 3600 - 600; $0.bgStale = true },
        mk("b-plain", "busy", ago: 200, name: "Web-DEMO-应用", project: "demo-b", summary: "在改接口") { $0.tool = "Edit" },
        mk("u-news", "idle", ago: 100, name: "Web-UX-星图", project: "Web-UX", summary: "检查完了，三处告警，详情在 out/ci.md"),
        mk("s-seen", "idle", ago: 1800, name: "Home-云朵", project: "Home-云朵", summary: "整理完了，结果在 report.md"),
        mk("r-rest", "idle", ago: 9 * 3600, name: "Home-风车修理", project: "fw", summary: "已升到 7.18"),
    ]
}

@MainActor func bgRenderStore(_ only: [String]? = nil) -> Store {
    let all = bgRenderCast().filter { only == nil || only!.contains($0.id) }
    let store = boardSweepStore(all, agents: [:])
    store.seen["u-news"] = 0
    return store
}

@MainActor func bgRenderBoard(_ store: Store, width: CGFloat) -> CGImage? {
    store.narrow = width < 520
    let board = Board(width: width).environmentObject(store).environment(\.zoom, 1).environment(\.still, true).background(night).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: board)
    renderer.scale = 2
    return renderer.cgImage
}

@MainActor func bgRenderZone(_ store: Store) -> (view: ZoneView, image: CGImage?) {
    UserDefaults.standard.removeObject(forKey: ZoneMemory.key)
    ZoneMemory.remembered = [:]; ZoneMemory.holders = [:]; ZoneMemory.names = [:]
    let view = ZoneView(frame: CGRect(x: 0, y: 0, width: 1194, height: 900))
    view.still = true
    view.update(store)
    for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return (view, view.image(pixelScale: 2))
}

@MainActor func bgRenderStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = nil; BGWalker.stillTime = 1.0 }
    let restore = seaSweepSetup(NSTemporaryDirectory() + "bgrender-zones-\(getpid())")
    defer { restore() }
    let p = { (n: String) in dir + "/" + n }
    let times: [Double] = [0.4, 1.2, 2.0, 2.8]

    let all = bgRenderStore()
    BGWalker.stillTime = 1.0
    bgRenderSheet(title: "Background work · duty room · wide card", note: "Running in the background: AI-星尘收集 (BG 2), Ops-云海整理 (BG 3), avatar standing, walker strolling right of the name; hung in the background: Home-魔法小城堡 (grey walker standing + a hint line); for contrast: waiting, working, has news, looked at, resting",
             panels: [("640 pt wide, 2x", bgRenderBoard(all, width: 640))], columns: 1, to: p("01-duty-room-wide-card.png"))
    bgRenderSheet(title: "Background work · duty room · narrow row", note: "A row running in the background: walker + \"BG N\", three green dots left of the summary; hung: grey walker + hint line",
             panels: [("420 pt wide, 2x", bgRenderBoard(all, width: 420))], columns: 1, to: p("02-duty-room-narrow-row.png"))
    let office = bgRenderStore()
    bgRenderSheet(title: "Background work · office", note: "Running in the background: seated at their own desk (screen lit), walker strolling on the desk edge, the name plate says \"BG N\"; hung: grey walker standing on the desk edge, the name plate says the suspected-hung words",
             panels: [("1194 × 764 pt", officeStill(office, size: CGSize(width: 1194, height: 764)))], columns: 1, to: p("03-office.png"))
    let zone = bgRenderZone(bgRenderStore())
    bgRenderSheet(title: "Background work · sea room", note: "Running in the background: seated at their own desk (screen lit, ice-blue LED), walker strolling on the desk edge, layered by desk: in front of its own desk's foreground layer, behind anyone standing at the desk; hung: grey walker standing",
             panels: [("1194 × 900 pt", zone.image)], columns: 1, to: p("04-sea-room.png"))

    // The walk, every 0.2 s for five seconds: a crop of the card, the row, the office desk and the sea-room desk.
    var cardFrames: [CGImage?] = [], rowFrames: [CGImage?] = [], officeFrames: [CGImage?] = [], zoneFrames: [CGImage?] = []
    let one = bgRenderStore(["bg-1"]), oneRow = bgRenderStore(["bg-1"])
    let officeLayout = OfficePainter.layout(office, now: Date())
    let seat = officeLayout.pets.first { $0.id == "bg-1" }
    let zoneStore = bgRenderStore(["bg-1", "bg-3", "bg-hung", "b-plain"])
    for k in 0..<26 {
        BGWalker.stillTime = Double(k) * 0.2
        cardFrames.append(bgRenderCrop(bgRenderBoard(one, width: 640), CGRect(x: 0, y: 28, width: 330, height: 90)))
        rowFrames.append(bgRenderCrop(bgRenderBoard(oneRow, width: 420), CGRect(x: 0, y: 28, width: 420, height: 70)))
        if let seat {
            officeFrames.append(bgRenderCrop(officeStill(office, size: CGSize(width: 1194, height: 764)), CGRect(x: max(0, seat.x - 110), y: max(0, seat.foot - 130), width: 220, height: 150), scale: 2))
        }
        if k % 5 == 0 || true { zoneFrames.append(nil) }
    }
    func strip(_ frames: [CGImage?], columns: Int) -> CGImage? {
        let imgs = frames.compactMap { $0 }
        guard let first = imgs.first else { return nil }
        let w = first.width, h = first.height, rows = (imgs.count + columns - 1) / columns
        guard let ctx = CGContext(data: nil, width: w * columns, height: h * rows, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(OfficeCanvas.rgb(0x15132A)); ctx.fill(CGRect(x: 0, y: 0, width: w * columns, height: h * rows))
        for (i, img) in imgs.enumerated() {
            ctx.draw(img, in: CGRect(x: (i % columns) * w, y: (rows - 1 - i / columns) * h, width: w, height: h))
        }
        return ctx.makeImage()
    }
    BGWalker.stillTime = 1.0
    bgRenderSheet(title: "Background work · stroll burst (5 s, one frame per 0.2 s)", note: "One frame per 0.2 s, left to right, top to bottom. The same walker: strolls back and forth, facing its direction of travel, cycling through the eight running frames.",
             panels: [("duty room wide card (right of the name)", strip(cardFrames, columns: 3)), ("duty room narrow row", strip(rowFrames, columns: 3)), ("office desk edge", strip(officeFrames, columns: 4))],
             columns: 1, to: p("05-burst-stroll.png"))
    // Sea room: whole-room renders at five instants, cropped at the bg-1 desk.
    var zoneCrops: [CGImage?] = []
    for k in 0..<13 {
        BGWalker.stillTime = Double(k) * 0.4
        let z = bgRenderZone(zoneStore)
        if let desk = z.view.plan.desks["bg-1"], let layer = z.view.deskLayer(desk) {
            let b = layer.art.box
            _ = b
        }
        if let h = z.view.agentHolder(of: "bg-1"), let first = h.sublayers?.first {
            zoneCrops.append(bgRenderCrop(z.image, CGRect(x: first.position.x - 120, y: first.position.y - 100, width: 240, height: 160)))
        }
    }
    BGWalker.stillTime = 1.0
    bgRenderSheet(title: "Background work · sea room stroll burst (one frame per 0.4 s, 5 s)", note: "The walker goes back and forth along the near edge of the desk; the desk's foreground layer covers the walker, anyone standing at the desk is in front of it.",
             panels: [("desk edge", strip(zoneCrops, columns: 4))], columns: 1, to: p("06-burst-sea-room.png"))
    _ = times
}
