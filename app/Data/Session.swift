import AppKit
import Combine
import ImageIO
import SQLite3
import SwiftUI

struct Session: Identifiable, Equatable {
    let id: String
    let pid: Int32
    let project: String
    let name: String
    let status: String  // waiting | busy | idle
    var since: Date  // when it entered that status
    let summary: String
    var waitingFor = ""  // Claude Code's own word for what a waiting session waits on
    var registryName = ""  // the name other sessions address this one by
    var cwd = ""  // its working directory, which its menu opens in Finder
    var kind = "claude"  // which agent it is: "claude" (Claude Code), "codex" (Codex CLI), "codexApp" (the Codex desktop app), "workbuddy"
    /// Being restarted by the restart script (`restartingFile`): shown as it was last read, with a spinner over it.
    var restarting = false
    /// For a busy session: the name of the tool call it is in (its last `tool_use` with no result after it), the one its
    /// badge in the Seaview scene shows; empty when it is thinking or writing, and for agents whose transcript says nothing of it.
    var tool = ""
    /// Who started its last turn (the Duty Room WebApp's rule too): "user" (the user did), "peer" (another
    /// session's message), "agent" (a subagent's or background task's report). Only Claude Code's say; the others are "user".
    var origin = "user"
    /// For a peer turn: the sender's `from-name`, "" when not given.
    var peer = ""
    /// For Claude Code's: the model its last reply in the tail named ("claude-fable-5-1"), kept across reads that find none;
    /// "" until one is seen. The others' come from their own stores (`Loader.model(of:)`).
    var model = ""
    /// What `summary` says as a code and its arguments, set where the line is made; nil for a session made with a bare
    /// line (the checks' own), which `line` then reads as `none` or `text`/`raw`.
    var summaryLine: SummaryLine? = nil
    /// Its name is the default untitled name given for want of any (not one the user chose, whatever it says).
    var nameUntitled = false
    /// `name` as the screen shows it: the default untitled name in the screen's language (`name` itself stays, for `--dump` and every match).
    var shownName: String { nameUntitled && name == "未命名" ? L10n.string("common.untitled", table: "Common", zh: "未命名") : name }
    /// What it has running in the background, as `--dump`'s bgTasks / bgAgents / bgSince / bgStale say: the
    /// background commands and background subagents not yet finished, the subagents among them, and when the earliest began.
    /// Only Claude Code's say; the others, and a session whose process is gone, have none.
    var bgTasks = 0
    var bgAgents = 0
    var bgSince: Date? = nil
    /// The earliest of them began more than `bgStaleAfter` ago: likely hung, not at work.
    var bgStale = false
    /// When the last of its background tasks ended, if any has; and whether one was begun since the last turn the user started.
    var bgEndedAt: Date? = nil
    var bgOwned = false
    /// What is running, one by one (`--dump`'s bgList): as many as `bgTasks`, earliest first.
    var bgList: [BGItem] = []
    /// What has gone wrong, as `--dump`'s errorKind / errorStatus / errorText / errorSince / retryAttempt / retryMax /
    /// disconnected / disconnectedSince / compactedAt say. `errorKind`: api, rate_limit, auth (Claude Code's last
    /// turn ended in an error of the API that nothing has answered), wb_error, wb_stopped (WorkBuddy's); nil for none. The
    /// retry fields are set while Claude Code is retrying a call (busy, its last line the retry's note). `disconnected`: its
    /// process died while its registry file stayed (nobody asked it to go), shown for 10 minutes from `disconnectedSince`.
    var errorKind: String? = nil
    var errorStatus: Int? = nil
    var errorText: String? = nil
    var errorSince: Date? = nil
    var retryAttempt: Int? = nil
    var retryMax: Int? = nil
    var disconnected = false
    var disconnectedSince: Date? = nil
    /// When Claude Code last finished compacting the conversation, as far back as the part of the transcript read goes.
    var compactedAt: Date? = nil
    /// The helpers it has, as the board counts them: its running subagents (`Store.agentCounts`, `OfficeSubagents`) or its
    /// background subagents, whichever are more (they are partly the same ones), and the background commands besides.
    func helpers(subagents: Int) -> Int { max(subagents, bgAgents) + max(0, bgTasks - bgAgents) }
    /// At work: busy, or idle with background work running that is not hung (`bgStale` is not at work). The one reading
    /// the groups, the pose, the celebration, the unread rule and the lamps share; `status` and the dump's status stay as they
    /// were. `bgCountsAsWorking` off: busy only.
    var isWorking: Bool { status == "busy" || isBackgroundWorking }
    /// Idle, its work in the background: what the little walker beside the pet shows.
    var isBackgroundWorking: Bool { status == "idle" && bgTasks > 0 && !bgStale && bgCountsAsWorking() }
    /// Hung background work (`bgStale`): the grey walker stands and the card says so. Not at work.
    var isBackgroundHung: Bool { status == "idle" && bgTasks > 0 && bgStale && bgCountsAsWorking() }
    /// When it finished, as unread and rest count it: the last turn's end or the last background task's, the
    /// later. Without `bgCountsAsWorking` the last turn's, as it was.
    var finishedAt: Date { bgCountsAsWorking() ? max(since, bgEndedAt ?? .distantPast) : since }
    /// Exited unexpectedly (`disconnected`), drawn as such: a grey card, its pet faint at its own desk; no count, no
    /// celebration, no pin. `showFailed` off: never (those sessions are left off the board).
    var isGone: Bool { disconnected && showFailed() }
    /// Its last turn ended in an error nothing has answered (`errorKind`: Claude Code's api / auth / rate_limit,
    /// WorkBuddy's wb_error / wb_stopped). Idle, not gone. `showFailed` off: never.
    var hasError: Bool { errorKind != nil && status == "idle" && !disconnected && showFailed() }
    /// Claude Code is retrying a call (busy; still at work, in amber).
    var isRetrying: Bool { status == "busy" && retryAttempt != nil && !disconnected && showFailed() }
    /// Drawn amber rather than red: the usage limit (not a fault) and a retry.
    var isAmber: Bool { isRetrying || (hasError && errorKind == "rate_limit") }
    /// Drawn brick red: an error that is a fault (the API's, the login's, WorkBuddy's error or stop).
    var isRed: Bool { hasError && errorKind != "rate_limit" }
    /// `summary` as a code and its arguments (`--dump`'s summaryCode / summaryArgs): `summaryLine` while it renders to
    /// `summary` exactly, else the line as it stands, `none` when empty, `text`/`raw` otherwise.
    var line: SummaryLine { summaryLine.flatMap { $0.rendered == summary ? $0 : nil } ?? .said(summary, .raw) }
    /// Whether it runs on Fable, any version (its pet glows gold in the Seaview scene).
    var isFable: Bool { Session.isFable(model) }
    /// The one rule for that: "fable" anywhere in the model's name, in any case.
    static func isFable(_ model: String) -> Bool { model.lowercased().contains("fable") }
}

/// Who a string user record's text comes from, by the turn-origin rule: agent before peer (a subagent's hand-back starts
/// with the peer line too), then peer with its `from-name`, else user.
func classifyTurnText(_ text: String) -> (origin: String, peer: String) {
    let t = text.drop(while: { $0.isWhitespace })
    if text.contains("<agent-message") || t.hasPrefix("<task-notification") { return ("agent", "") }
    if t.hasPrefix("Another Claude session sent a message:") || text.contains("<cross-session-message") {
        var peer = ""
        if let tag = text.range(of: "<cross-session-message"), let end = text[tag.upperBound...].firstIndex(of: ">"),
            let key = text[tag.upperBound..<end].range(of: " from-name=\""),
            let close = text[key.upperBound..<end].firstIndex(of: "\"")
        {
            peer = text[key.upperBound..<close].trimmingCharacters(in: .whitespaces)
        }
        return ("peer", peer)
    }
    return ("user", "")
}

/// The origin one transcript record gives, or nil when it does not count: not a user record, a sidechain's, content not a
/// string (tool results), or an `isMeta` one that is neither peer nor agent (system injected).
func turnOrigin(_ record: [String: Any]) -> (origin: String, peer: String)? {
    guard (record["type"] as? String) == "user", (record["isSidechain"] as? Bool) != true,
        let text = (record["message"] as? [String: Any])?["content"] as? String
    else { return nil }
    let o = classifyTurnText(text)
    if (record["isMeta"] as? Bool) == true && o.origin == "user" { return nil }
    return o
}

/// The faint extra line on a finished session's card when its last turn was not theirs.
func originNote(_ s: Session) -> String? {
    guard s.status == "idle" else { return nil }
    switch s.origin {
    case "peer": return s.peer.isEmpty ? "↔ " + L10n.string("origin.peer.other", table: "Board", zh: "与其他会话往来") : "↔ " + L10n.format("common.talkingWith", table: "Common", zh: "与 %@ 往来", s.peer)
    case "agent": return "⚙ " + L10n.string("common.agentReport.handled", table: "Common", zh: "处理了子代理回报")
    default: return nil
    }
}

// ───────── The card's line in the language of the screen ─────────

extension SummaryLine {
    /// The line as the screen says it. `rendered` is `--dump`'s (simplified Chinese) and stays so; in simplified
    /// Chinese the two are the same bytes (I18nTests). The session's own words (`text`, an API error's) are never translated.
    var displayText: String {
        switch self {
        case .empty: return ""
        case .text(let t, _): return t
        case .ask(let question, let count): return count > 1 ? L10n.format("line.ask.count", table: "Board", zh: "问你：%@（共 %lld 个问题）", question, count) : L10n.format("line.ask", table: "Board", zh: "问你：%@", question)
        case .askGeneric: return L10n.string("line.askGeneric", table: "Board", zh: "在等你回答问题")
        case .plan: return L10n.string("line.plan", table: "Board", zh: "计划写好了，等你批准")
        case .approveRun(let command): return L10n.format("line.approve.run", table: "Board", zh: "等你批准运行：%@", command)
        case .approveEdit(let file): return L10n.format("line.approve.edit", table: "Board", zh: "等你批准修改：%@", file ?? L10n.string("line.approve.edit.file", table: "Board", zh: "文件"))
        case .approveTool(let tool): return L10n.format("line.approve.tool", table: "Board", zh: "等你批准使用 %@", tool)
        case .approve: return L10n.string("line.approve", table: "Board", zh: "等你批准")
        case .answer(let options):
            return options.map { L10n.format("common.answerOptions", table: "Plurals", zh: "等你回答（%lld 个选项）", $0) } ?? L10n.string("line.answer", table: "Board", zh: "等你回答")
        case .paused: return L10n.string("line.paused", table: "Board", zh: "已暂停")
        case .stopped: return L10n.string("line.stopped", table: "Board", zh: "已中止")
        case .error: return L10n.string("line.error", table: "Board", zh: "出错")
        case .you(let t): return L10n.format("line.you", table: "Board", zh: "你：%@", t)
        case .relayAgent: return L10n.string("line.relay.agent", table: "Board", zh: "处理子代理回报…")
        case .relayPeer: return L10n.string("line.relay.peer", table: "Board", zh: "处理其他会话的消息…")
        case .relayFrom(let peer): return L10n.format("line.relay.from", table: "Board", zh: "处理 %@ 的回报…", peer)
        case .apiError(let kind, let status, let text):
            if kind == "rate_limit" { return text }  // Claude Code's own words (they say when it resets)
            if kind == "auth" { return L10n.string("line.apiError.auth", table: "Board", zh: "要重新登录") }
            if let status { return L10n.format("line.apiError.status", table: "Board", zh: "API 出错 %lld：%@", status, text) }
            return L10n.format("line.apiError", table: "Board", zh: "API 出错：%@", text)
        case .retrying(let attempt, let max): return L10n.format("line.retrying", table: "Board", zh: "正在重试 %lld/%lld", attempt, max)
        case .disconnected: return L10n.string("line.disconnected", table: "Board", zh: "意外退出")
        }
    }
}

extension Session {
    /// `summary` as the screen shows it (its own words as they are, the board's in the screen's language).
    var shownSummary: String { line.displayText }
}

struct TailInfo {
    var size: UInt64 = 0
    var mtime = Date.distantPast
    var customTitle: String?
    var aiTitle: String?
    var summaryLine = SummaryLine.empty  // the card's line, as a code and its arguments
    var summary: String { summaryLine.rendered }
    var status = ""  // session status when the tail was last parsed
    var parsedAt = Date.distantPast
    var pendingLine: SummaryLine?  // for a waiting session: the question asked or the action to approve
    var pending: String { pendingLine?.rendered ?? "" }
    var tool = ""  // for a busy session: the name of the tool call it is in (no result after it yet)
    var replyStamp = ""  // the timestamp of the last assistant text reply in the tail ("" for none)
    var lastTurnStamp = ""  // the timestamp of the last assistant or user line of the session's own ("" for none)
    var origin = "user"  // who started the last turn, and the peer's name (Session.origin, .peer)
    var peer = ""
    var model = ""  // the model of the last assistant line that names one (Session.model), kept from the read before when none does
    // See Session.errorKind and the fields after it.
    var errorKind: String?
    var errorStatus: Int?
    var errorText: String?
    var errorSince: Date?
    var retryAttempt: Int?
    var retryMax: Int?
    var compactedAt: Date?
    /// The tail's whole lines were there and none of a kind known (`FormatCensus`): Claude Code's transcript format changed.
    var unknownLines = false
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
/// The app's bundle id: its caches folder, notification and queue names hang on it. A bare binary (the checks, a dev
/// build) has none and shares the app's.
let appID = Bundle.main.bundleIdentifier ?? "io.github.ericcc0321.soulgent"
/// ~/Library/Caches/<bundle id>: the links found, the pets' cut frames, the notice board's log. Rebuilt when deleted.
let cacheFolder = home + "/Library/Caches/" + appID
let registryDir = home + "/.claude/sessions"

/// Where this Mac keeps a file of a tool beside the panel (none of them comes with it): the environment's `env` first,
/// then the setting `key` (`defaults write <domain> <key> <path>`); a leading `~` is the home folder. "" when neither
/// says, and the panel then does without whatever that file gives, as on a Mac without the tool.
func localPath(_ key: String, env: String, defaults: UserDefaults = .standard) -> String {
    let given = ProcessInfo.processInfo.environment[env] ?? defaults.string(forKey: key) ?? ""
    let path = given.trimmingCharacters(in: .whitespaces)
    if path == "~" { return home }
    return path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
}

/// The sessions another tool is restarting right now (`/exit`, then `--resume` in the same terminal), written by it
/// atomically; missing on a Mac without that tool, which is the same as nobody restarting. Set by
/// `SOULGENT_RESTARTING_FILE` or the setting `restartingFile`.
let restartingFile = localPath("restartingFile", env: "SOULGENT_RESTARTING_FILE")
/// How long an entry there is believed after its `since`: a script that died must not hold a session forever.
let restartTrust: TimeInterval = 120
let transcriptsDir = home + "/.claude/projects"
/// The folder the projects are in, if there is one: a session working in it is named by its path there (`x/y`), else by its
/// folder's name. `SOULGENT_PROJECTS_ROOT` or the setting `projectsRoot` (`~/` allowed); none when neither says.
var projectsRoot: String = {
    let path = localPath("projectsRoot", env: "SOULGENT_PROJECTS_ROOT")
    return path.isEmpty || path.hasSuffix("/") ? path : path + "/"
}()
/// Folders in `projectsRoot` that only hold projects: a project in one is named without it (`<container>/x/y` → `x/y`).
/// `SOULGENT_PROJECT_CONTAINERS` (separated by ":") or the setting `projectContainers` (a list); none when neither says.
var projectContainers: [String] = {
    if let given = ProcessInfo.processInfo.environment["SOULGENT_PROJECT_CONTAINERS"] {
        return given.split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }
    return (UserDefaults.standard.stringArray(forKey: "projectContainers") ?? []).filter { !$0.isEmpty }
}()
let tailBytes: UInt64 = 400_000
let recentIdle: TimeInterval = 6 * 3600  // finished longer ago than this: the agent goes to the rest area
// A convention for users who want to write a progress line in their replies: a reply line that starts with this marker is
// taken as the card's one-line progress summary for that session.
let progressMark = "〔进度〕"
let recapSuffix = "(disable recaps in /config)"

func projectName(_ cwd: String) -> String {
    guard !projectsRoot.isEmpty, cwd.hasPrefix(projectsRoot) else { return (cwd as NSString).lastPathComponent }
    let rel = String(cwd.dropFirst(projectsRoot.count))
    for container in projectContainers where rel.hasPrefix(container + "/") { return String(rel.dropFirst(container.count + 1)) }
    return rel
}

func messageText(_ entry: [String: Any]) -> String? {
    guard let message = entry["message"] as? [String: Any] else { return nil }
    if let s = message["content"] as? String {
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let blocks = message["content"] as? [[String: Any]] else { return nil }
    let texts = blocks.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
    let joined = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    return joined.isEmpty ? nil : joined
}

/// Markdown emphasis and code ticks are noise on a card.
func plain(_ text: String) -> String {
    text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
}

func firstLine(_ text: String, limit: Int = 90) -> String {
    for raw in text.split(separator: "\n") {
        let line = plain(String(raw)).trimmingCharacters(in: CharacterSet(charactersIn: " #*->\t"))
        if !line.isEmpty { return String(line.prefix(limit)) }
    }
    return ""
}

/// A reply that says nothing ("No response requested.", "an acknowledgement", "an acknowledgement"): the card shows the one before it instead.
/// A small fixed list, compared without case, spaces and punctuation; a short reply that says something ("a status word") is kept.
let fillerReplies: Set<String> = ["noresponserequested", "noresponseneeded", "收到", "已收到", "好的", "好", "ok", "okay", "嗯", "明白", "知道了", "acknowledged", "noted"]
func isFillerReply(_ text: String) -> Bool {
    let bare = String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    return bare.count <= 24 && fillerReplies.contains(bare)
}

/// One line saying where a session stands. Each argument is (timestamp, text); the ISO
/// timestamps share one format, so comparing them as strings orders them by time.
func pickSummary(recap: (String, String)?, reply: (String, String)?, asked: (String, String)?) -> String {
    pickSummaryLine(recap: recap, reply: reply, asked: asked).rendered
}

/// `pickSummary` as a code and its arguments.
func pickSummaryLine(recap: (String, String)?, reply: (String, String)?, asked: (String, String)?) -> SummaryLine {
    // A prompt newer than the last reply means that turn is still running.
    if let a = asked, a.0 > (reply?.0 ?? "") { return .you(firstLine(a.1)) }
    func clean(_ s: String) -> String {
        plain(s.replacingOccurrences(of: recapSuffix, with: "")).trimmingCharacters(in: .whitespaces)
    }
    guard let r = reply else {
        if let c = recap { return .said(clean(c.1), .recap) }
        return asked.map { .you(firstLine($0.1)) } ?? .empty
    }
    let lines = r.1.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    if let marked = lines.last(where: { $0.hasPrefix(progressMark) }) {
        return .said(plain(String(marked.dropFirst(progressMark.count))).trimmingCharacters(in: .whitespaces), .progress)
    }
    // Claude Code writes a recap a few minutes after a turn ends if nobody is watching.
    if let c = recap, c.0 >= r.0 { return .said(clean(c.1), .recap) }
    return .said(firstLine(r.1), .reply)
}

// ───────── The summary as a code and its arguments ─────────

/// What a session's line (`Session.summary`) says, as `--dump` gives it besides the line itself: a code and
/// its arguments, from which the phone says it in its own language. The line itself is made from the two by `render`, the
/// one simplified-Chinese template of each code, so line and code never say different things. An argument is the very
/// text in the line, cut no further here (the phone cuts what it shows).
enum SummaryLine: Equatable {
    /// Which of the session's own words a `text` line is: its last reply's first line, its progress-marker line, Claude Code's
    /// recap, or a line made nowhere known (`raw`).
    enum Kind: String { case reply, progress, recap, raw }
    case empty  // code `none`: the line is empty
    case text(String, kind: Kind)
    case ask(question: String, count: Int)
    case askGeneric
    case plan
    case approveRun(command: String)
    case approveEdit(file: String?)  // nil: no file_path given
    case approveTool(tool: String)
    case approve
    case answer(options: Int?)  // nil: how many options is not known
    case paused, stopped, error
    case you(String)
    case relayAgent, relayPeer
    case relayFrom(peer: String)
    /// The last turn ended in an API error (`kind` api, rate_limit or auth; `status` the HTTP status if there was one; `text`
    /// Claude Code's own words, short of the leading "API Error: 529").
    case apiError(kind: String, status: Int?, text: String)
    case retrying(attempt: Int, max: Int)
    case disconnected

    /// The session's own words as a line: `none` when there are none (an empty summary is `none`).
    static func said(_ text: String, _ kind: Kind) -> SummaryLine { text.isEmpty ? .empty : .text(text, kind: kind) }

    var code: String {
        switch self {
        case .empty: return "none"
        case .text(let t, _): return t.isEmpty ? "none" : "text"
        case .ask: return "wait.ask"
        case .askGeneric: return "wait.ask.generic"
        case .plan: return "wait.plan"
        case .approveRun: return "wait.approve.run"
        case .approveEdit: return "wait.approve.edit"
        case .approveTool: return "wait.approve.tool"
        case .approve: return "wait.approve"
        case .answer: return "wait.answer"
        case .paused: return "state.paused"
        case .stopped: return "state.stopped"
        case .error: return "state.error"
        case .you: return "prompt.you"
        case .relayAgent: return "relay.agent"
        case .relayPeer: return "relay.peer"
        case .relayFrom: return "relay.from"
        case .apiError: return "state.apiError"
        case .retrying: return "state.retrying"
        case .disconnected: return "state.disconnected"
        }
    }

    /// Always an object, `[:]` for none; a value not known is null.
    var args: [String: Any] {
        switch self {
        case .text(let t, let kind): return t.isEmpty ? [:] : ["text": t, "kind": kind.rawValue]
        case .ask(let question, let count): return ["question": question, "count": count]
        case .approveRun(let command): return ["command": command]
        case .approveEdit(let file): return ["file": file.map { $0 as Any } ?? NSNull()]
        case .approveTool(let tool): return ["tool": tool]
        case .answer(let options): return ["options": options.map { $0 as Any } ?? NSNull()]
        case .you(let t): return ["text": t]
        case .relayFrom(let peer): return ["peer": peer]
        case .apiError(let kind, let status, let text): return ["kind": kind, "status": status.map { $0 as Any } ?? NSNull(), "text": text]
        case .retrying(let attempt, let max): return ["attempt": attempt, "max": max]
        default: return [:]
        }
    }

    /// The line as the card and `--dump`'s `summary` say it.
    var rendered: String { Self.render(code: code, args: args) ?? "" }

    /// A code and its arguments in simplified Chinese, by the code's template; nil for a code it does not know.
    static func render(code: String, args: [String: Any]) -> String? {
        func s(_ key: String) -> String { args[key] as? String ?? "" }
        switch code {
        case "none": return ""
        case "text": return s("text")
        case "wait.ask":
            let count = args["count"] as? Int ?? 1
            return "问你：" + s("question") + (count > 1 ? "（共 \(count) 个问题）" : "")
        case "wait.ask.generic": return "在等你回答问题"
        case "wait.plan": return "计划写好了，等你批准"
        case "wait.approve.run": return "等你批准运行：" + s("command")
        case "wait.approve.edit": return "等你批准修改：" + (args["file"] as? String ?? "文件")
        case "wait.approve.tool": return "等你批准使用 " + s("tool")
        case "wait.approve": return "等你批准"
        case "wait.answer": return (args["options"] as? Int).map { "等你回答（\($0) 个选项）" } ?? "等你回答"
        case "state.paused": return "已暂停"
        case "state.stopped": return "已中止"
        case "state.error": return "出错"
        case "prompt.you": return "你：" + s("text")
        case "relay.agent": return "处理子代理回报…"
        case "relay.peer": return "处理其他会话的消息…"
        case "relay.from": return "处理 \(s("peer")) 的回报…"
        case "state.apiError":
            if s("kind") == "rate_limit" { return s("text") }  // Claude Code's own words (they say when it resets)
            if s("kind") == "auth" { return "要重新登录" }
            if let status = args["status"] as? Int { return "API 出错 \(status)：" + s("text") }
            return "API 出错：" + s("text")
        case "state.retrying": return "正在重试 \(args["attempt"] as? Int ?? 0)/\(args["max"] as? Int ?? 0)"
        case "state.disconnected": return "意外退出"
        default: return nil
        }
    }
}

// ───────── Formats of the other programs no longer understood ─────────
//
// Every reader of another program's files (Claude Code's registry and transcripts, Codex's rollouts and index, WorkBuddy's
// database and log, Orca's runtime file and terminal list) says, at the point it already parses them, when what it read is
// there but of a shape it does not know: the program changed its format, and the board would otherwise go short of words
// without a sign. Only then: a file missing, a program not installed, an empty file, a last line still being written or a
// first one cut by the tail's start are no sign of anything, and too few lines to go by keep the verdict as it was.
// `--dump` gives each row the warnings of its source (`formatWarnings`); the title bar shows an amber dot while any stands.

/// One format not understood: whose (`claude`, `codex`, `workbuddy`, `orca`) and what of it (`registry`, `transcript`,
/// `rollout`, `threads`, `turns`, `database`, `log`, `runtime`, `terminals`).
struct FormatWarning: Hashable, Comparable {
    let source: String
    let reason: String
    static func < (a: FormatWarning, b: FormatWarning) -> Bool { (a.source, a.reason) < (b.source, b.reason) }
    var json: [String: String] { ["source": source, "reason": reason] }

    static let claudeRegistry = FormatWarning(source: "claude", reason: "registry")
    static let claudeTranscript = FormatWarning(source: "claude", reason: "transcript")
    static let codexRollout = FormatWarning(source: "codex", reason: "rollout")
    static let codexThreads = FormatWarning(source: "codex", reason: "threads")
    static let codexTurns = FormatWarning(source: "codex", reason: "turns")
    static let workbuddyDatabase = FormatWarning(source: "workbuddy", reason: "database")
    static let workbuddyLog = FormatWarning(source: "workbuddy", reason: "log")
    static let orcaRuntime = FormatWarning(source: "orca", reason: "runtime")
    static let orcaTerminals = FormatWarning(source: "orca", reason: "terminals")
}

/// The source a session's row is of, for its warnings: the Codex app's are Codex's (the same files).
func formatSource(of kind: String) -> String {
    switch kind {
    case "codex", "codexApp": return "codex"
    case "workbuddy": return "workbuddy"
    default: return "claude"
    }
}

/// What a reader found not understood at its last look: each warning with the sessions it is about ("" for all of its source's).
typealias FormatMarks = [FormatWarning: Set<String>]

func mergeFormatMarks(_ all: [FormatMarks]) -> FormatMarks {
    var merged: FormatMarks = [:]
    for marks in all { for (w, subjects) in marks where !subjects.isEmpty { merged[w, default: []].formUnion(subjects) } }
    return merged
}

/// The warnings of a row: its source's that are about it or about all of them, and Orca's (every jump goes through Orca); sorted, once each.
func rowFormatWarnings(_ marks: FormatMarks, for s: Session) -> [FormatWarning] {
    let source = formatSource(of: s.kind)
    return marks.filter { w, subjects in w.source == "orca" || (w.source == source && (subjects.contains("") || subjects.contains(s.id))) }
        .keys.sorted()
}

/// Lines counted for the verdict: those whole (not one still being written, not one cut by where the read began), and those
/// of a kind known. True: not understood; false: understood; nil: too few lines to say, the verdict stays as it was.
struct FormatCensus {
    /// Fewer whole lines than this, none of them known, say nothing.
    static let enough = 5
    var whole = 0
    var known = 0
    var verdict: Bool? { known > 0 ? false : whole >= Self.enough ? true : nil }
}

/// The kinds of line a Claude Code transcript is made of (2.1.3xx), looked for anywhere in a line, as bytes. Wide on purpose:
/// a new session's first lines are its mode and its prompt's, and any of these says the format is still the one read.
let claudeLineKinds = [
    "user", "assistant", "system", "attachment", "summary", "custom-title", "ai-title", "queue-operation", "file-history-", "last-prompt",
    "permission-mode", "mode", "atis-latch", "agent-name", "bridge-session", "cost-state", "api-request", "progress", "tag", "pr-link",
].map { Phrase("\"type\":\"" + $0) }

/// The kinds of line a Codex rollout is made of (0.160 and the app's 26.1007), looked for in a line's head (where Codex puts them).
let codexLineKinds = ["event_msg", "response_item", "turn_context", "session_meta", "compacted", "world_state", "token_usage_record"]
    .map { Phrase("\"type\":\"" + $0 + "\"") }

/// The warnings that stand, as the panel's log says them: one line when one appears, one when it goes, never one a tick.
struct FormatLog {
    private(set) var said = Set<FormatWarning>()
    /// Takes what stands now; what changed, as lines for the log.
    mutating func take(_ now: Set<FormatWarning>) -> [String] {
        let came = now.subtracting(said).sorted().map { "format: \($0.source) \($0.reason) no longer understood (its format may have changed)" }
        let went = said.subtracting(now).sorted().map { "format: \($0.source) \($0.reason) understood again" }
        said = now
        return came + went
    }
}

/// Orca's two: read wherever Orca is asked (a click's jump, the focus light's list, off the main thread), kept here for the panel.
final class OrcaFormat: @unchecked Sendable {
    static let shared = OrcaFormat()
    private let lock = NSLock()
    private var standing = Set<FormatWarning>()
    private var told = FormatLog()
    /// Where a change is told (panel.log); a check catches it.
    var note: (String) -> Void = { log($0) }

    var warnings: Set<FormatWarning> {
        lock.lock()
        defer { lock.unlock() }
        return standing
    }

    func set(_ w: FormatWarning, _ on: Bool) {
        lock.lock()
        if on { standing.insert(w) } else { standing.remove(w) }
        let lines = dumpProbe == nil ? told.take(standing) : []
        lock.unlock()
        lines.forEach(note)
    }

    /// For the checks: nothing stands, nothing said.
    func reset() {
        lock.lock()
        standing = []
        told = FormatLog()
        lock.unlock()
    }
}
