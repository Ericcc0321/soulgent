// `--demo-crowd`, the made-up crowd for the README's pictures and for recording. Soulgent.app and the checks'
// binary both know it. With it on, nothing real is read or written: the sessions are made up here (names, folders under
// /Users/demo, summaries, in the language of the run: `--lang`), the zones, the notice board and the settings are the
// crowd's own, and the pets come from a short list only.
//
//   --demo-crowd                 the crowd (30 sessions over the room's four islands)
//   --demo-extra N               N more sessions on the Web island (the island has 12 desks: the rest go to the lounge)
//   --pets-dir <folder>          where the listed pets are installed (else SOULGENT_DEMO_PETS, else app/tmp/demo-pets)
//
// The settings: `UserDefaults.standard` is swapped for a domain of the crowd's own (`<bundle id>.demo`, emptied at every
// start) for the length of the run, so no setting of the real panel is read, and none is written.

import AppKit

enum DemoMode {
    /// Whether this run shows the made-up crowd. Read from the pet pools (any thread) and the one-panel rule.
    nonisolated(unsafe) static var active = false
    /// The folders the listed pets are looked for in (empty: none installed, everyone is the built-in flame).
    nonisolated(unsafe) static var petDirs: [String] = []

    /// The demonstration pets (listed below): the built-in flame and nineteen from Petdex. No other pet is ever shown.
    nonisolated static let pets = [
        "soulflame", "little-deer", "blue-boba-axolotl", "milk-tea-koala", "whaley", "byte-bunny", "boxcat", "prompt-penguin",
        "scarf-hamster", "octopus", "penguin-chick", "terminal-ghost-2", "red-panda", "acorn-squirrel", "wave-whale", "cloudlet",
        "cream-cat", "lint-sprout", "sea-lion", "cloudy",
    ]

    /// Whether a pet may be shown: always outside the demonstration, only the listed ones in it.
    nonisolated static func allows(_ pet: String) -> Bool { !active || pets.contains(pet) }

    nonisolated static func requested(_ arguments: [String]) -> Bool { arguments.contains("--demo-crowd") }

    static func value(_ flag: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: flag).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    }

    /// How many more sessions the Web island gets (`--demo-extra`, 0…20).
    nonisolated(unsafe) static var extra = 0

    private nonisolated(unsafe) static var swapped: (method: Method, original: IMP)?
    private nonisolated(unsafe) static var saved: (zones: String, roster: String, pending: String, activity: String, live: Bool)?
    nonisolated(unsafe) static var scratch = ""
    nonisolated static let domain = (Bundle.main.bundleIdentifier ?? "io.github.ericcc0321.soulgent") + ".demo"

    /// Turns the crowd on: the settings, the files and the pet pools of the run. Before anything reads a setting or a pet.
    @MainActor static func enter(arguments: [String] = CommandLine.arguments) {
        guard !active else { return }
        extra = max(0, min(20, value("--demo-extra", in: arguments).flatMap { Int($0) } ?? 0))
        // The pets: --pets-dir, else the environment, else the folder beside the sources (app/tmp/demo-pets).
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let chosen = value("--pets-dir", in: arguments) ?? ProcessInfo.processInfo.environment["SOULGENT_DEMO_PETS"]
            ?? exe.deletingLastPathComponent().appendingPathComponent("tmp/demo-pets").path
        petDirs = FileManager.default.fileExists(atPath: chosen) ? [chosen] : []
        // The settings: a domain of the crowd's own, emptied now.
        if let demo = UserDefaults(suiteName: domain) {
            demo.removePersistentDomain(forName: domain)
            let selector = NSSelectorFromString("standardUserDefaults")
            if let method = class_getClassMethod(UserDefaults.self, selector) {
                let block: @convention(block) (AnyObject) -> AnyObject = { _ in demo }
                swapped = (method, method_setImplementation(method, imp_implementationWithBlock(block)))
            }
        }
        // The files the panel reads or writes: scratch ones of the crowd's own.
        scratch = NSTemporaryDirectory() + "soulgent-demo-\(getpid())"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        saved = (ZoneConfigFile.path, ZoneRosterFile.path, ZonePendingFile.path, OfficeActivity.file, appSessionsLive)
        ZoneConfigFile.path = scratch + "/workzones.json"
        ZoneRosterFile.path = scratch + "/roster.json"
        ZonePendingFile.path = scratch + "/no-pending.json"
        OfficeActivity.file = scratch + "/activity.json"
        try? DemoCrowd.zonesJSON(lang: L10n.language).write(toFile: ZoneConfigFile.path, atomically: true, encoding: .utf8)
        try? "{}".write(toFile: ZoneRosterFile.path, atomically: true, encoding: .utf8)
        ZoneRosterFile.reset()
        appSessionsLive = false  // the Codex app and WorkBuddy are never read
        active = true
        Pets.shared = Pets()
        OfficePets.shared = OfficePets()
    }

    /// Turns it off again (the checks run on in one process).
    @MainActor static func leave() {
        guard active else { return }
        active = false
        if let swapped { method_setImplementation(swapped.method, swapped.original) }
        swapped = nil
        UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
        if let saved {
            ZoneConfigFile.path = saved.zones
            ZoneRosterFile.path = saved.roster
            ZonePendingFile.path = saved.pending
            OfficeActivity.file = saved.activity
            appSessionsLive = saved.live
        }
        saved = nil
        ZoneRosterFile.reset()
        if !scratch.isEmpty { try? FileManager.default.removeItem(atPath: scratch) }
        scratch = ""
        petDirs = []
        extra = 0
        Pets.shared = Pets()
        OfficePets.shared = OfficePets()
    }
}

/// The made-up sessions, in the language asked for. Pure data: a `Store` takes it in `Store.takeDemo`.
struct DemoCrowd {
    var sessions: [Session] = []
    var seen: [String: Double] = [:]
    var pinned: Set<String> = []
    var agents: [String: [OfficeSubagents.Agent]] = [:]
    var peers: [String: [Peer]] = [:]
    var pets: [String: String] = [:]
    var activity = OfficeActivity()
    /// The session on Fable (the blaze), the one Orca has in front (the light), and a pair that talk (the visit).
    var fable = "", lit = ""
    var talker = "", listener = ""

    enum State {
        case busy(tool: String, agents: Int = 0)
        case waiting(SummaryLine)
        case news, seen, rest
        case background(tasks: Int, agents: Int, stale: Bool = false)
        case apiError, rateLimit, gone
    }

    struct Row {
        let zone: String
        let key: String
        let names: [String]  // en, zh-Hans, zh-Hant
        let said: [String]  // the same order: its last reply, or what it works on
        let state: State
        var model = ""
        var ago: Double = 600
        func name(_ lang: Int) -> String { zone + "-" + names[lang] }
    }

    nonisolated static let languages = ["en", "zh-Hans", "zh-Hant"]
    nonisolated static func index(_ lang: String) -> Int { languages.firstIndex(of: lang) ?? 0 }

    /// The rows, in desk order: the first of a zone is its lead (desk 1).
    static func rows(lang: Int) -> [Row] {
        func q(_ en: String, _ hans: String, _ hant: String) -> String { [en, hans, hant][lang] }
        var list: [Row] = [
            // Web
            Row(zone: "Web", key: "storefront", names: ["storefront", "店铺前台", "店鋪前台"],
                said: ["Reworking the product page layout", "正在改商品页的排版", "正在改商品頁的排版"], state: .busy(tool: "Edit", agents: 2), ago: 420),
            Row(zone: "Web", key: "checkout", names: ["checkout", "结账流程", "結帳流程"],
                said: ["Running the checkout tests", "正在跑结账流程的测试", "正在跑結帳流程的測試"], state: .busy(tool: "Bash", agents: 1), ago: 260),
            Row(zone: "Web", key: "payments", names: ["payments", "支付对接", "支付串接"],
                said: ["", "", ""], state: .waiting(.approveEdit(file: "src/checkout/pay.ts")), ago: 540),
            Row(zone: "Web", key: "landing", names: ["landing-page", "落地页", "著陸頁"],
                said: ["Hero section done, screenshots are in out/", "首屏改完了，截图在 out/", "首屏改完了，截圖在 out/"], state: .news, ago: 180),
            Row(zone: "Web", key: "design", names: ["design-system", "设计规范", "設計規範"],
                said: ["Button states are unified", "按钮状态统一好了", "按鈕狀態統一好了"], state: .news, ago: 900),
            Row(zone: "Web", key: "blog", names: ["blog", "博客", "部落格"],
                said: ["Three drafts reviewed", "三篇草稿都过了一遍", "三篇草稿都過了一遍"], state: .seen, ago: 2400),
            Row(zone: "Web", key: "i18n", names: ["i18n", "多语言", "多語言"],
                said: ["Strings extracted, 214 keys", "文案已抽出，共 214 条", "文案已抽出，共 214 條"], state: .rest, ago: 8 * 3600),
            // Ops
            Row(zone: "Ops", key: "k8s", names: ["k8s-upgrade", "集群升级", "叢集升級"],
                said: ["Draining the second node pool", "正在排空第二组节点", "正在排空第二組節點"], state: .busy(tool: "Bash", agents: 3), ago: 500),
            Row(zone: "Ops", key: "ci", names: ["ci-pipeline", "持续集成", "持續整合"],
                said: ["Pipeline time down from 14 to 9 minutes", "流水线从 14 分钟缩到 9 分钟", "流水線從 14 分鐘縮到 9 分鐘"], state: .seen, ago: 1800),
            Row(zone: "Ops", key: "monitoring", names: ["monitoring", "监控告警", "監控告警"],
                said: ["Reading last night's alert history", "正在读昨晚的告警记录", "正在讀昨晚的告警記錄"], state: .busy(tool: "Read"), ago: 150),
            Row(zone: "Ops", key: "deploy", names: ["staging-deploy", "预发布部署", "預發佈部署"],
                said: ["", "", ""], state: .waiting(.approveRun(command: "kubectl apply -f staging.yaml")), ago: 300),
            Row(zone: "Ops", key: "dns", names: ["dns-migration", "域名迁移", "網域遷移"],
                said: ["", "", ""], state: .apiError, ago: 240),
            Row(zone: "Ops", key: "backups", names: ["backups", "备份检查", "備份檢查"],
                said: ["Last night's backup verified", "昨晚的备份校验通过", "昨晚的備份校驗通過"], state: .news, ago: 1200),
            Row(zone: "Ops", key: "terraform", names: ["terraform", "基础设施代码", "基礎設施程式碼"],
                said: ["The plan is clean, nothing to apply", "plan 没有变更，无需执行", "plan 沒有變更，無需執行"], state: .rest, ago: 9 * 3600),
            Row(zone: "Ops", key: "incident", names: ["incident-review", "故障复盘", "故障復盤"],
                said: ["Timeline written up in review.md", "时间线已写进 review.md", "時間線已寫進 review.md"], state: .rest, ago: 11 * 3600),
            // AI
            Row(zone: "AI", key: "rag", names: ["rag-index", "知识库检索", "知識庫檢索"],
                said: ["Re-indexing 12,000 documents", "正在重建 1.2 万篇文档的索引", "正在重建 1.2 萬篇文件的索引"], state: .busy(tool: "Bash", agents: 2),
                model: "claude-fable-5-1", ago: 120),
            Row(zone: "AI", key: "eval", names: ["eval-suite", "评测集", "評測集"],
                said: ["Adding 40 cases to the eval set", "正在给评测集补 40 个用例", "正在給評測集補 40 個用例"], state: .busy(tool: "Edit"),
                model: "claude-opus-5-5", ago: 280),
            Row(zone: "AI", key: "embeddings", names: ["embeddings", "向量化", "向量化"],
                said: ["All chunks embedded, 3 failures retried", "所有分块都已向量化，3 个失败的重试成功", "所有分塊都已向量化，3 個失敗的重試成功"], state: .seen,
                model: "claude-fable-5-1", ago: 1500),
            Row(zone: "AI", key: "chat", names: ["chat-agent", "对话助手", "對話助理"],
                said: ["", "", ""], state: .waiting(.answer(options: 3)), ago: 420),
            Row(zone: "AI", key: "finetune", names: ["fine-tune", "微调实验", "微調實驗"],
                said: ["Training run 3 of 5 started in the background", "第 3 轮训练已在后台启动", "第 3 輪訓練已在背景啟動"], state: .background(tasks: 2, agents: 1), ago: 700),
            Row(zone: "AI", key: "prompts", names: ["prompt-lab", "提示词实验", "提示詞實驗"],
                said: ["Variant B wins on 7 of 10 tasks", "方案 B 在 10 个任务里赢了 7 个", "方案 B 在 10 個任務裡贏了 7 個"], state: .seen, ago: 2800),
            Row(zone: "AI", key: "dataclean", names: ["data-clean", "数据清洗", "資料清洗"],
                said: ["", "", ""], state: .rateLimit, ago: 360),
            Row(zone: "AI", key: "vectordb", names: ["vector-db", "向量库", "向量庫"],
                said: ["Benchmarking three index settings", "正在对比三种索引参数", "正在對比三種索引參數"], state: .busy(tool: "Agent", agents: 2), ago: 340),
            // Home
            Row(zone: "Home", key: "dotfiles", names: ["dotfiles", "配置同步", "設定同步"],
                said: ["Shell config synced to both laptops", "终端配置已同步到两台笔记本", "終端設定已同步到兩台筆電"], state: .seen, ago: 2000),
            Row(zone: "Home", key: "homelab", names: ["home-lab", "家庭实验室", "家庭實驗室"],
                said: ["Pulling the new container images", "正在拉取新的容器镜像", "正在拉取新的容器映像"], state: .busy(tool: "Bash"), ago: 200),
            Row(zone: "Home", key: "notes", names: ["notes", "笔记整理", "筆記整理"],
                said: ["Weekly notes merged into one page", "本周笔记合成了一页", "本週筆記合成了一頁"], state: .news, ago: 600),
            Row(zone: "Home", key: "router", names: ["router", "路由器", "路由器"],
                said: ["", "", ""], state: .waiting(.approveRun(command: "ssh router reboot")), ago: 240),
            Row(zone: "Home", key: "photos", names: ["photo-sort", "照片归档", "照片歸檔"],
                said: ["2,310 photos sorted by month", "2310 张照片已按月归档", "2310 張照片已按月歸檔"], state: .rest, ago: 10 * 3600),
            Row(zone: "Home", key: "budget", names: ["budget", "记账", "記帳"],
                said: ["", "", ""], state: .gone, ago: 300),
            Row(zone: "Home", key: "recipes", names: ["recipes", "菜谱", "食譜"],
                said: ["Shopping list for the week is ready", "这周的购物清单列好了", "這週的購物清單列好了"], state: .rest, ago: 13 * 3600),
        ]
        // More on the Web island (--demo-extra): the island has 12 desks, the rest go to the lounge.
        let more = [("search", "站内搜索", "站內搜尋"), ("seo", "搜索优化", "搜尋優化"), ("cart", "购物车", "購物車"), ("emails", "邮件模板", "郵件範本"),
                    ("images", "图片压缩", "圖片壓縮"), ("a11y", "无障碍", "無障礙"), ("analytics", "数据统计", "資料統計"), ("sitemap", "站点地图", "網站地圖")]
        for i in 0..<DemoMode.extra {
            let m = more[i % more.count]
            let tag = i >= more.count ? "-\(i / more.count + 1)" : ""
            list.insert(Row(zone: "Web", key: m.0 + tag, names: [m.0 + tag, m.1 + tag, m.2 + tag],
                            said: ["Checked and merged", "检查完了，已合并", "檢查完了，已合併"], state: .seen, ago: 3000 + Double(i) * 60), at: 7 + i)
        }
        _ = q
        return list
    }

    nonisolated static let zoneColours = ["Web": "#E0A040", "Ops": "#40B0A0", "AI": "#5080D0", "Home": "#A070D0"]

    /// The workzones file of the crowd: the room's four islands by name, each zone's lead its first row.
    static func zonesJSON(lang: String) -> String {
        let i = index(lang), all = rows(lang: i)
        var parts: [String] = []
        for (order, code) in ["Web", "Ops", "AI", "Home"].enumerated() {
            let lead = all.first { $0.zone == code }?.name(i) ?? code
            parts.append("\"\(code)\": {\"name\": \"\(code)\", \"color\": \"\(zoneColours[code] ?? "#888888")\", \"order\": \(order + 1), \"lead\": \"\(lead)\"}")
        }
        return "{\"zones\": {\(parts.joined(separator: ", "))}, \"dirs\": {}, \"default\": null}"
    }

    /// The crowd for a language (`en`, `zh-Hans`, `zh-Hant`), its times counted back from `now`.
    @MainActor static func make(lang: String, now: Date = Date(), installed: [String]? = nil) -> DemoCrowd {
        let l = index(lang)
        var crowd = DemoCrowd()
        let have = installed ?? (Pets.shared.ids + [PetSources.builtInID])
        let order = DemoMode.pets.filter { have.contains($0) }
        let all = rows(lang: l)
        let cwdOf: (Row) -> String = { "/Users/demo/projects/" + $0.zone.lowercased() + "/" + $0.key }
        for (n, row) in all.enumerated() {
            let id = "demo-\(row.zone.lowercased())-\(row.key)"
            let name = row.name(l)
            var line: SummaryLine = .said(row.said[l], .reply)
            var status = "idle", waitingFor = ""
            var s: Session
            func make() -> Session {
                Session(id: id, pid: Int32(41000 + n), project: row.zone + "-" + row.key, name: name, status: status, since: now - row.ago,
                        summary: line.rendered, waitingFor: waitingFor, registryName: name, cwd: cwdOf(row), kind: "claude",
                        tool: "", origin: "user", model: row.model, summaryLine: line)
            }
            switch row.state {
            case .busy(let tool, let helpers):
                status = "busy"
                s = make()
                s.tool = tool
                if helpers > 0 {
                    let kinds = agentKinds(l)
                    let made = (0..<helpers).map { kinds[($0 + n) % kinds.count] }
                    crowd.agents[id] = made
                }
            case .waiting(let asked):
                status = "waiting"; waitingFor = "permission prompt"
                line = asked
                if case .answer = asked { line = .answer(options: 3) }
                s = make()
            case .news:
                s = make()
            case .seen:
                s = make()
                crowd.seen[id] = now.timeIntervalSince1970
            case .rest:
                s = make()
                crowd.seen[id] = now.timeIntervalSince1970
            case .background(let tasks, let helpers, let stale):
                s = make()
                s.bgTasks = tasks; s.bgAgents = helpers; s.bgSince = now - 23 * 60; s.bgOwned = true; s.bgStale = stale
                s.bgList = bgItems(l, tasks: tasks, agents: helpers, now: now, id: id)
                crowd.seen[id] = now.timeIntervalSince1970
            case .apiError:
                line = .apiError(kind: "api", status: 529, text: "Overloaded")
                s = make()
                s.errorKind = "api"; s.errorStatus = 529; s.errorText = "Overloaded"; s.errorSince = now - row.ago
            case .rateLimit:
                let words = "You've hit your limit · resets 1pm (UTC)"
                line = .apiError(kind: "rate_limit", status: 429, text: words)
                s = make()
                s.errorKind = "rate_limit"; s.errorStatus = 429; s.errorText = words; s.errorSince = now - row.ago
            case .gone:
                line = .disconnected
                s = make()
                s.disconnected = true; s.disconnectedSince = now - row.ago
            }
            crowd.sessions.append(s)
            // The same pet for the same row, in every language and every run: the listed ones in order, the flame for a pet not
            // installed (and for all when none is).
            let wanted = DemoMode.pets[(n + 1) % DemoMode.pets.count]
            crowd.pets[id] = order.contains(wanted) ? wanted : PetSources.builtInID
            if row.key == "rag" { crowd.fable = id }
            if row.key == "eval" { crowd.lit = id }
        }
        // Two that talk: the visit, the dotted lines, the notice board.
        let words = visitWords(l)
        crowd.talker = "demo-ai-eval"; crowd.listener = "demo-ai-rag"
        crowd.peers[crowd.talker] = [Peer(id: crowd.listener, sent: 2, received: 1, last: now - 90, note: words, outgoing: true)]
        crowd.peers[crowd.listener] = [Peer(id: crowd.talker, sent: 1, received: 2, last: now - 90, note: words, outgoing: false)]
        crowd.peers["demo-web-checkout"] = [Peer(id: "demo-web-payments", sent: 3, received: 2, last: now - 400, note: ["Which gateway does the sandbox use?", "沙盒环境用哪个支付网关？", "沙盒環境用哪個支付閘道？"][l], outgoing: true)]
        crowd.peers["demo-web-payments"] = [Peer(id: "demo-web-checkout", sent: 2, received: 3, last: now - 400, note: ["Which gateway does the sandbox use?", "沙盒环境用哪个支付网关？", "沙盒環境用哪個支付閘道？"][l], outgoing: false)]
        crowd.activity = activityLog(crowd, now: now)
        return crowd
    }

    /// What the one on a visit says (short: the bubble holds one line).
    static func visitWords(_ l: Int) -> String { ["I moved the port to 9000", "端口改成 9000 了", "埠號改成 9000 了"][l] }

    static func agentKinds(_ l: Int) -> [OfficeSubagents.Agent] {
        let d = [["Explore the product schema", "Check the cart API", "Write the migration", "Review the diff"],
                 ["查商品表结构", "核对购物车接口", "写迁移脚本", "审一遍改动"],
                 ["查商品表結構", "核對購物車介面", "寫遷移腳本", "審一遍改動"]][l]
        return [OfficeSubagents.Agent(description: d[0], model: "claude-sonnet-5", agentType: "Explore"),
                OfficeSubagents.Agent(description: d[1], model: "claude-sonnet-5", agentType: "general-purpose"),
                OfficeSubagents.Agent(description: d[2], model: "claude-opus-5-5", agentType: "general-purpose"),
                OfficeSubagents.Agent(description: d[3], model: "claude-sonnet-5", agentType: "general-purpose")]
    }

    static func bgItems(_ l: Int, tasks: Int, agents: Int, now: Date, id: String) -> [BGItem] {
        let cmds = [["Training run 3 of 5", "Sync checkpoints to the NAS"], ["第 3 轮训练", "把检查点同步到 NAS"], ["第 3 輪訓練", "把檢查點同步到 NAS"]][l]
        var list: [BGItem] = []
        for i in 0..<tasks {
            list.append(BGItem(kind: i < agents ? "agent" : "cmd", desc: cmds[i % cmds.count], since: now - Double(23 - i * 4) * 60, id: "\(id)-bg\(i)", toolUseId: "toolu_demo\(i)"))
        }
        return list
    }

    /// What the office's notice board says: a few finishes, two questions, a talk.
    static func activityLog(_ crowd: DemoCrowd, now: Date) -> OfficeActivity {
        func name(_ id: String) -> String { crowd.sessions.first { $0.id == id }?.name ?? id }
        var log = OfficeActivity()
        var events: [OfficeActivity.Event] = []
        func add(_ ago: Double, _ id: String, _ kind: OfficeActivity.Event.Kind, partner: String? = nil) {
            events.append(OfficeActivity.Event(at: now - ago, id: id, name: name(id), kind: kind, partner: partner.map(name)))
        }
        add(3000, "demo-web-blog", .finished)
        add(2400, "demo-ops-ci", .finished)
        add(1700, "demo-ops-backups", .finished)
        add(1200, "demo-web-design", .finished)
        add(900, "demo-ai-chat", .answer)
        add(700, "demo-home-notes", .finished)
        add(540, "demo-web-payments", .approve)
        add(400, "demo-web-checkout", .talk, partner: "demo-web-payments")
        add(300, "demo-ops-deploy", .approve)
        add(240, "demo-home-router", .approve)
        add(180, "demo-web-landing", .finished)
        add(90, "demo-ai-eval", .talk, partner: "demo-ai-rag")
        log.add(events)
        return log
    }

    /// The crowd into a store (the sessions, what the user has seen, the helpers, the talk, the pets, the board and the light).
    @MainActor static func fill(_ store: Store, lang: String = L10n.language) {
        store.takeDemo(make(lang: lang))
    }
}
