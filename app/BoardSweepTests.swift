// The board and office sweep. Stills of every state from made-up sessions
// (`--board-stills <dir>`), and the checks for the board and office states (`--board-sweep-only`). Nothing here ships in the app.

import AppKit
import SwiftUI

/// A made-up card's approval line, question line or error as the code a real session would carry, so a picture in another language
/// says it in that language (the text alone would stay Chinese: a session's own words are never translated).
func fixtureLine(_ text: String) -> SummaryLine? {
    if text == "出错" { return .error }
    if text.hasPrefix("要你批准：") { return .approveRun(command: String(text.dropFirst(5))) }
    if text.hasPrefix("要你回答：") { return .ask(question: String(text.dropFirst(5)), count: 1) }
    return nil
}

@MainActor func boardSweepSession(_ id: String, _ status: String, ago: TimeInterval, name: String, project: String = "demo-panel",
    summary: String = "", waitingFor: String = "", kind: String = "claude", tool: String = "", restarting: Bool = false) -> Session
{
    let fixed = fixtureLine(summary)
    var s = Session(
        id: id, pid: 1, project: project, name: name, status: status, since: Date().addingTimeInterval(-ago), summary: fixed?.rendered ?? summary,
        waitingFor: waitingFor, kind: kind, tool: tool)
    s.summaryLine = fixed
    s.restarting = restarting
    return s
}

/// Every state the brief lists, once each.
@MainActor func boardSweepAllStates() -> [Session] {
    [
        boardSweepSession("w-perm", "waiting", ago: 420, name: "风筝 Web MCP", project: "demo-a", summary: "要你批准：docker compose up -d",
            waitingFor: "permission prompt"),
        boardSweepSession("w-input", "waiting", ago: 200, name: "月球漫步", project: "demo-c", summary: "端口用 8080 还是 9000？", waitingFor: "input needed"),
        boardSweepSession("w-wb", "waiting", ago: 90, name: "星图整理", project: "WorkBuddy", summary: "要你批准：读取 ~/Documents", waitingFor: "permission request",
            kind: "workbuddy"),
        boardSweepSession("u-news", "idle", ago: 120, name: "星座脚本", project: "Ops-星座", summary: "比完了，差 3 处，清单放在 out/差异.xlsx"),
        boardSweepSession("u-pin", "idle", ago: 3000, name: "云端地图梳理", project: "AI-童话", summary: "编码表已更新，等你确认第 4 类"),
        boardSweepSession("b-tool", "busy", ago: 60, name: "星舰起航", project: "demo-b", summary: "在拉取 demo 镜像", tool: "Bash"),
        boardSweepSession("b-1", "busy", ago: 300, name: "风车巡游", project: "panel", summary: "在出截图", tool: "Agent"),
        boardSweepSession("b-3", "busy", ago: 500, name: "星桥流程整理", project: "Web-UX", summary: "三个子代理在读文件"),
        boardSweepSession("b-5", "busy", ago: 700, name: "童话文件转文本", project: "sky2md", summary: "五个子代理在转 PDF", tool: "Agent"),
        boardSweepSession("s-seen", "idle", ago: 1500, name: "备份检查", project: "demo-d", summary: "备份都在，最近一次昨晚 3 点"),
        boardSweepSession("r-rest", "idle", ago: 9 * 3600, name: "风车修理", project: "fw", summary: "已升到 7.18"),
        boardSweepSession("r-rest2", "idle", ago: 30 * 3600, name: "旧星清理", project: "Mac"),
        boardSweepSession("x-restart", "idle", ago: 900, name: "Mer Maid", project: "mermaid", summary: "重启中", restarting: true),
        boardSweepSession("k-codex", "busy", ago: 240, name: "改一下风车", project: "panel", summary: "在改 CardView", kind: "codex"),
        boardSweepSession("k-app", "idle", ago: 400, name: "Codex 星空版问答", project: "codex-app", summary: "答完了", kind: "codexApp"),
        boardSweepSession("long", "idle", ago: 1800, name: "Nova 像素风格 Comet 星图整理以及夜间巡游航线与灯塔海湾配色说明",
            project: "demo-workspace-demo-panel-demo-project-panel-长项目名", summary: String(repeating: "很长的一段总结文字，", count: 12)),
    ]
}

@MainActor func boardSweepAgents(_ n: Int) -> [OfficeSubagents.Agent] {
    let made = [("查日志", "claude-sonnet-5", "Explore"), ("Codex 写脚本", "", "codex:codex-rescue"), ("改样式", "claude-opus-5-5", "general-purpose"),
                ("写说明", "sonnet", "general-purpose"), ("把 120 页说明文档逐页转成 Markdown 并核对表格", "haiku", "general-purpose")]
    return made.prefix(n).map { OfficeSubagents.Agent(description: $0.0, model: $0.1, agentType: $0.2) }
}

/// A store over these sessions: news unread, the seen ones looked at, the pinned one pinned, the subagents given.
@MainActor func boardSweepStore(_ sessions: [Session], pinned: Set<String> = [], agents: [String: Int] = [:]) -> Store {
    let store = Store()
    store.readOnly = true
    store.sessions = sessions
    store.pinned = pinned
    store.hovered = nil
    let now = Date().timeIntervalSince1970
    for s in sessions where s.status == "idle" {
        store.seen[s.id] = s.id.hasPrefix("u-") || s.id.hasPrefix("k-app") || s.id.hasPrefix("n") ? 0 : now
    }
    store.agents = agents.mapValues { boardSweepAgents($0) }
    store.agentCounts = agents
    if !officeDealCutPets(store) { store.assignPets() }
    return store
}

/// A crowd: so many waiting, with news, at work, looked at, resting.
@MainActor func boardSweepCrowd(_ w: Int, _ n: Int, _ b: Int, _ s: Int, _ r: Int) -> [Session] {
    let projects = ["demo-a", "Ops-星座", "AI-Sky", "demo-b", "panel", "demo-c", "demo-d", "sky2md"]
    var all: [Session] = []
    let groups: [(String, String, Int, TimeInterval)] = [("w", "waiting", w, 300), ("n", "idle", n, 200), ("b", "busy", b, 100), ("s", "idle", s, 1200), ("r", "idle", r, 9 * 3600)]
    for (prefix, status, count, ago) in groups {
        for i in 0..<count {
            all.append(
                boardSweepSession("\(prefix)\(i)", status, ago: ago + Double(i) * 37, name: "\(["等批准", "有话说", "干活中", "看过的", "休息的"][["w", "n", "b", "s", "r"].firstIndex(of: prefix)!])会话\(i + 1)",
                    project: projects[i % projects.count], summary: status == "waiting" ? "要你批准：npm test" : "做完了第 \(i + 1) 步",
                    waitingFor: status == "waiting" ? "permission prompt" : "", tool: status == "busy" ? "Bash" : ""))
        }
    }
    return all
}

@MainActor func boardSweepBoard(_ store: Store, width: CGFloat, zoom: CGFloat, _ path: String) {
    store.narrow = width < 520 * zoom
    let board = Board(width: width)
        .environmentObject(store).environment(\.zoom, zoom).environment(\.still, true)
        .background(night).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: board)
    renderer.scale = 2
    save(renderer.cgImage, path)
}

@MainActor func boardSweepOffice(_ store: Store, size: CGSize = CGSize(width: 1194, height: 764), zoom: Double, hover: String? = nil, _ path: String) {
    UserDefaults.standard.set(zoom, forKey: "zoom")
    defer { UserDefaults.standard.removeObject(forKey: "zoom") }
    store.hovered = hover
    save(officeStill(store, size: size), path)
    store.hovered = nil
}

/// `--board-stills <dir>`: the board and the office in every state, at zoom 0.75, 1 and 1.3; writes `<dir>/board` and `<dir>/office`.
@MainActor func boardSweepStills(_ dir: String) {
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    OfficeTheme.shown = OfficeTheme.studio
    defer { OfficeTheme.shown = nil }
    let fm = FileManager.default
    for sub in ["board", "office"] { try? fm.createDirectory(atPath: dir + "/" + sub, withIntermediateDirectories: true) }
    // The notice board's log: a few of each kind, one long name.
    var log = OfficeActivity()
    let t = Date()
    log.add([
        .init(at: t - 3000, id: "u-news", name: "星座脚本", kind: .finished),
        .init(at: t - 2400, id: "b-3", name: "星桥流程整理", kind: .talk, partner: "星座脚本"),
        .init(at: t - 1800, id: "long", name: "Nova 像素风格 Comet 星图整理以及夜间巡游航线与灯塔海湾配色说明", kind: .finished, origin: "agent"),
        .init(at: t - 420, id: "w-perm", name: "风筝 Web MCP", kind: .approve),
        .init(at: t - 200, id: "w-input", name: "月球漫步", kind: .answer),
        .init(at: t - 90, id: "w-wb", name: "星图整理", kind: .waiting),
    ])
    log.save()
    defer { try? fm.removeItem(atPath: OfficeActivity.file) }

    let agents = ["b-1": 1, "b-3": 3, "b-5": 5]
    let all = boardSweepStore(boardSweepAllStates(), pinned: ["u-pin"], agents: agents)
    let one = boardSweepStore([boardSweepAllStates()[3]])
    let twelve = boardSweepStore(boardSweepCrowd(2, 3, 4, 2, 1), agents: ["b0": 2])
    let forty = boardSweepStore(boardSweepCrowd(9, 6, 8, 7, 10), agents: ["b0": 1, "b1": 3, "b2": 5])
    let b = dir + "/board/", o = dir + "/office/"
    for z in [0.75, 1, 1.3] {
        boardSweepBoard(all, width: 640, zoom: z, b + "all-640-z\(z).png")
        boardSweepBoard(all, width: 980, zoom: z, b + "all-980-z\(z).png")
        boardSweepBoard(all, width: 420, zoom: z, b + "all-narrow420-z\(z).png")
        boardSweepOffice(all, zoom: z, o + "all-z\(z).png")
    }
    boardSweepBoard(one, width: 640, zoom: 1, b + "one-640.png")
    boardSweepBoard(twelve, width: 640, zoom: 1, b + "twelve-640.png")
    boardSweepBoard(forty, width: 640, zoom: 1, b + "forty-640.png")
    boardSweepBoard(forty, width: 420, zoom: 1, b + "forty-narrow420.png")
    all.hovered = "u-pin"
    boardSweepBoard(all, width: 640, zoom: 1, b + "all-640-hover-pin.png")
    all.hovered = nil
    // The counts in the title bar, both widths, at each zoom.
    for z in [0.75, 1, 1.3] {
        UserDefaults.standard.set(z, forKey: "zoom")
        for narrow in [false, true] {
            all.narrow = narrow
            let renderer = ImageRenderer(content: CountsBar(store: all).padding(6).background(night).environment(\.colorScheme, .dark))
            renderer.scale = 2
            save(renderer.cgImage, b + "counts-\(narrow ? "narrow" : "wide")-z\(z).png")
        }
        UserDefaults.standard.removeObject(forKey: "zoom")
    }

    boardSweepOffice(one, zoom: 1, o + "one.png")
    boardSweepOffice(twelve, zoom: 1, o + "twelve.png")
    boardSweepOffice(forty, zoom: 1, o + "forty.png")
    boardSweepOffice(all, size: CGSize(width: 860, height: 551), zoom: 1, o + "all-small860.png")
    for (key, name) in [("w-perm", "waiting-perm"), ("w-input", "waiting-input"), ("w-wb", "workbuddy"), ("u-news", "unread"), ("u-pin", "pinned"),
                        ("b-tool", "busy-tool"), ("b-1", "agents1"), ("b-3", "agents3"), ("b-5", "agents5"), ("s-seen", "seen"),
                        ("x-restart", "restarting"), ("k-codex", "codex"), ("k-app", "codexapp"), ("long", "long"), (OfficeLayout.boardKey, "board"),
                        (OfficeLayout.doorKey, "door")]
    {
        for z in [1.0, 1.3] { boardSweepOffice(all, zoom: z, hover: key, o + "hover-\(name)-z\(z).png") }
    }
    boardSweepOffice(forty, zoom: 1, hover: OfficeLayout.ChipKind.waiting.key, o + "forty-hover-chip.png")
    boardSweepOffice(forty, zoom: 1, hover: OfficeLayout.doorKey, o + "forty-hover-door.png")
    boardSweepOffice(forty, zoom: 1.3, hover: OfficeLayout.doorKey, o + "forty-hover-door-z1.3.png")
    // The menus, as words.
    var menus = ""
    for s in all.sessions {
        menus += s.name + "\n"
        for line in sessionMenu(all, s) where line.action != .separator { menus += "  \(line.enabled ? "  " : "× ")\(line.title)\n" }
        menus += "  help: " + cardHelp(s, all).replacingOccurrences(of: "\n", with: " / ") + "\n"
    }
    // The same in the office (its pet lines).
    UserDefaults.standard.set(true, forKey: "office")
    UserDefaults.standard.set(OfficeTheme.studio.name, forKey: "officeTheme")
    menus += "\n── Office ──\n"
    for s in all.sessions.prefix(5) {
        menus += s.name + "\n"
        for line in sessionMenu(all, s) where line.action != .separator { menus += "  \(line.enabled ? "  " : "× ")\(line.title)\n" }
    }
    UserDefaults.standard.removeObject(forKey: "office")
    UserDefaults.standard.removeObject(forKey: "officeTheme")
    try? menus.write(toFile: dir + "/menus.txt", atomically: true, encoding: .utf8)
    print("sweep stills in \(dir)")
}

/// A view drawn at this width (2 pixels a point), dark, at zoom 1, still.
@MainActor func boardSweepRender<V: View>(_ view: V, width: CGFloat, store: Store) -> CGImage? {
    let renderer = ImageRenderer(
        content: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
            .environmentObject(store).environment(\.zoom, 1).environment(\.still, true).environment(\.colorScheme, .dark))
    renderer.scale = 2
    return renderer.cgImage
}

/// Whether two pictures agree in the top-left `width` by `height` points (both at least that big).
func boardSweepSameCorner(_ a: CGImage?, _ b: CGImage?, width: CGFloat, height: CGFloat) -> Bool {
    guard let a, let b else { return false }
    let p = Pixels(a), q = Pixels(b)
    guard p.width >= Int(width * 2), q.width >= Int(width * 2), p.height >= Int(height * 2), q.height >= Int(height * 2) else { return false }
    for y in 0..<Int(height * 2) {
        for x in 0..<Int(width * 2) {
            let i = (y * p.width + x) * 4, j = (y * q.width + x) * 4
            if abs(Int(p.data[i]) - Int(q.data[j])) > 8 || abs(Int(p.data[i + 1]) - Int(q.data[j + 1])) > 8 { return false }
        }
    }
    return true
}

/// The checks for card layout, time labels and hover text.
@MainActor func boardSweepTests() {
    let store = Store()
    store.readOnly = true
    func with(_ s: Session, project: String) -> Session {
        boardSweepSession(s.id, s.status, ago: Date().timeIntervalSince(s.since), name: s.name, project: project, summary: s.summary,
            waitingFor: s.waitingFor, kind: s.kind)
    }
    // on a card the name keeps its room and the project gives way (a clipped Chinese project beside a clipped tag would read badly).
    let short = boardSweepSession("board-wb", "waiting", ago: 90, name: "星图整理", project: "", summary: "要你批准：读取文件", waitingFor: "permission request",
        kind: "workbuddy")
    let long = with(short, project: "WorkBuddy 的一个特别长的项目名字")
    store.sessions = [short]
    check("board card: a long project gives way to the name (the Chinese project shows whole beside the WorkBuddy tag)",
        boardSweepSameCorner(boardSweepRender(AgentCard(s: short), width: 300, store: store), boardSweepRender(AgentCard(s: long), width: 300, store: store), width: 150, height: 30))
    let orca = boardSweepSession("board-long", "idle", ago: 1800, name: "Nova 像素风格 Comet 演示界面", project: "", summary: "做完了")
    let orcaLong = with(orca, project: "demo-workspace-demo-panel-demo-project-panel")
    store.sessions = [orca]
    check("office card: a long project gives way to the name (the mixed-language project shows whole)",
        boardSweepSameCorner(boardSweepRender(OfficeCard(s: orca), width: 320, store: store), boardSweepRender(OfficeCard(s: orcaLong), width: 320, store: store),
            width: 193, height: 34))
    store.sessions = [short]
    check("list row: a long project gives way to the name",
        boardSweepSameCorner(boardSweepRender(InboxRow(s: short), width: 300, store: store), boardSweepRender(InboxRow(s: long), width: 300, store: store), width: 115, height: 30))

    // the narrow list's time says "ago" for a finished one, as the wide cards do; a waiting one keeps the bare time.
    let now = Date()
    let done = boardSweepSession("board-done", "idle", ago: 330, name: "星座", summary: ""), busy = boardSweepSession("board-busy", "busy", ago: 330, name: "跑", summary: "")
    check("list row: a finished one's time has the ago suffix, a busy one's and a waiting one's are bare",
        inboxTime(done, now: now) == "5 分钟前" && inboxTime(busy, now: now) == "5 分钟"
            && inboxTime(boardSweepSession("board-w", "waiting", ago: 330, name: "等", waitingFor: "permission prompt"), now: now) == "5 分钟")

    // the narrow list shows which agent it is (Codex / Codex App / WorkBuddy), as the wide card and the office do.
    let claude = boardSweepSession("board-c", "idle", ago: 300, name: "风车", project: "p"), codex = boardSweepSession("board-c", "idle", ago: 300, name: "风车", project: "p", kind: "codex")
    store.sessions = [claude]
    let a = boardSweepRender(InboxRow(s: claude), width: 400, store: store), b = boardSweepRender(InboxRow(s: codex), width: 400, store: store)
    check("list row: a Codex session's row carries the Codex tag", a != nil && b != nil && !boardSweepSameCorner(a, b, width: 400, height: 30))

    // a pet on the rest bench says on hover what a card says (click, right-click), after its project and summary.
    let resting = boardSweepSession("board-r", "idle", ago: 9 * 3600, name: "风车修理", project: "fw", summary: "已升到 7.18")
    store.sessions = [resting]
    let benchWords = benchHelp(resting, store)
    check("rest bench: its tooltip has the project, the summary and the card's click and right-click words",
        benchWords.hasPrefix("fw\n已升到 7.18\n") && benchWords.hasSuffix(cardHelp(resting, store)))

    // a full sofa's plates show a six-character name whole at full size (a smaller type before any cut), and at
    // the smallest window at least three characters: a change in the sixth (the third) character shows in the picture.
    func sofaShows(_ index: Int, size: CGSize) -> Bool {
        OfficeTheme.shown = OfficeTheme.studio
        defer { OfficeTheme.shown = nil }
        Pets.shared.synchronous = true
        OfficePets.shared.synchronous = true
        func names(changing: Int?) -> [Session] {
            (0..<3).map { i in
                var chars = Array("有话说会话一")
                if i == changing { chars[index] = "窗" }
                return boardSweepSession("board-sofa\(i)", "idle", ago: 100 + Double(i), name: String(chars), project: "p")
            }
        }
        let sofa = Store()
        sofa.readOnly = true
        sofa.sessions = names(changing: nil)
        for s in sofa.sessions { sofa.seen[s.id] = 0 }
        sofa.pinned = ["board-sofa0"]
        if !officeDealCutPets(sofa) { sofa.assignPets() }
        guard let base = officeStill(sofa, size: size) else { return false }
        return (0..<3).allSatisfy { i in
            sofa.sessions = names(changing: i)
            return officeStill(sofa, size: size).map { officeDifference(base, $0) > 0 } ?? false
        }
    }
    check("sofa plates: on a full sofa a six-character name shows its sixth character (1194 x 764)",
        sofaShows(5, size: CGSize(width: 1194, height: 764)))
    check("sofa plates: at the smallest window (860 x 551) at least three characters show",
        sofaShows(2, size: CGSize(width: 860, height: 551)))

    // the floor labels count who is in each part of the room now, not the states: 40 open, nine waiting (seven in
    // the queue, two flagged at desks), seven looked at of whom one sits at the back, ten resting behind the door.
    func ids(_ p: String, _ n: Int) -> [String] { (0..<n).map { "\(p)\($0)" } }
    let forty = OfficeLayout(waiting: ids("w", 9), unread: ids("n", 6), busy: ids("b", 8), seen: ids("s", 7), resting: ids("r", 10))
    func tally(_ zone: OfficeLayout.Zone) -> Int { forty.pets.filter { $0.zone == zone }.count }
    print("      forty: counts \(forty.counts), queue \(tally(.queue)) sofa \(tally(.sofa)) desk \(tally(.desk)) lounge \(tally(.lounge)) door \(forty.behindDoor)")
    check("floor labels: each counts who is seated or standing there (queue, sofas, desks, back couches); the door keeps its +N",
        forty.counts == OfficeLayout.Counts(waiting: tally(.queue), news: tally(.sofa), desks: tally(.desk), resting: tally(.lounge))
            && forty.counts.waiting == 7 && forty.counts.resting == 1 && forty.behindDoor == 10)

    // a board card (and a list row) shows a gear and the count while its session has subagents running; none at 0.
    let helped = boardSweepSession("board-help", "busy", ago: 60, name: "童话文件转文本", project: "sky2md", summary: "在转")
    store.sessions = [helped]
    store.agentCounts = [:]
    let plainCard = boardSweepRender(AgentCard(s: helped), width: 300, store: store), plainRow = boardSweepRender(InboxRow(s: helped), width: 300, store: store)
    store.agentCounts = [helped.id: 0]
    let zeroCard = boardSweepRender(AgentCard(s: helped), width: 300, store: store)
    store.agentCounts = [helped.id: 3]
    let threeCard = boardSweepRender(AgentCard(s: helped), width: 300, store: store), threeRow = boardSweepRender(InboxRow(s: helped), width: 300, store: store)
    store.agentCounts = [:]
    check("board: a card and a list row carry a mark for running subagents, and none when there are none",
        !boardSweepSameCorner(plainCard, threeCard, width: 300, height: 30) && !boardSweepSameCorner(plainRow, threeRow, width: 300, height: 30)
            && boardSweepSameCorner(plainCard, zeroCard, width: 300, height: 30))

    // WorkBuddy's permission wait reads waiting for approval everywhere, as Claude Code's does: the card's time, its summary.
    let wbWait = boardSweepSession("board-wbw", "waiting", ago: 330, name: "星图", waitingFor: "permission request", kind: "workbuddy")
    check("WorkBuddy: a permission wait's card says waiting-for-approval with the time, and its summary says it too",
        timeLabel(wbWait, now: Date()) == "等你批准 5 分钟" && WorkBuddySessions.state("pending", wait: .permission, mode: "default").summary == "等你批准")

    // WorkBuddy's permission request is logged on the notice board as a waiting-for-approval line, like Claude Code's permission prompt.
    let before = [boardSweepSession("board-a", "busy", ago: 10, name: "星图整理", kind: "workbuddy")]
    let after = [boardSweepSession("board-a", "waiting", ago: 0, name: "星图整理", waitingFor: "permission request", kind: "workbuddy")]
    let logged = OfficeActivity.events(from: before, to: after, at: Date())
    check("notice board: WorkBuddy's permission request reads as the waiting-for-approval line", logged.first?.kind == .approve && logged.first?.text == "在等你批准")
}
