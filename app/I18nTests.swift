// I18N: the localization groundwork (`L10n`, the tables, the language switch) and the places that judged
// a state by the words on screen, split from them. `--i18n-only` runs these alone; `--i18n-theme-legacy-stills <dir>` draws
// the office and the room from each theme value an earlier version saved. Nothing here ships in the app.
//
// Baseline: the `i18nOld…` functions are a word-for-word copy of the decision code that judged by the words on screen; the
// localized code is held against them in simplified Chinese, and against a made-up English table to show that what it decides
// does not follow the words.

import AppKit
import SwiftUI

private func i18nOldAgo(_ date: Date, now: Date) -> String {
    let s = Int(now.timeIntervalSince(date))
    if s < 60 { return "刚刚" }
    if s < 3600 { return "\(s / 60) 分钟" }
    if s < 86400 { return "\(s / 3600) 小时" }
    return "\(s / 86400) 天"
}

private func i18nOldTimeLabel(_ s: Session, now: Date) -> String {
    let t = i18nOldAgo(s.since, now: now)
    if s.status == "waiting" {
        let asks = ["permission prompt": "等你批准 ", "input needed": "等你回答 ", "permission request": "等你批准 "]
        return (asks[s.waitingFor] ?? "等你 ") + t
    }
    if s.status == "busy" || t == "刚刚" { return t }
    return t + "前"
}

/// The zone list's state words before localization (`ZoneListCard.rows`: a dictionary of words).
private func i18nOldZoneWords(_ b: Buckets) -> [String: String] {
    var state: [String: String] = [:]
    for s in b.waiting { state[s.id] = "在等你" }
    for s in b.busy { state[s.id] = "在干活" }
    for s in b.unread { state[s.id] = "有话说" }
    for s in b.seen { state[s.id] = "看过了" }
    for s in b.resting { state[s.id] = "看过了" }
    return state
}

/// What `--hover <word>` opened on a seaview room still before localization: the rest room's list, check-in's, or nil (a session or a zone).
@MainActor private func i18nOldZoneHover(_ hover: String) -> String? {
    if hover == "休息室" { return ZoneUI.restKey }
    if hover == "报到" { return ZoneUI.visitorKey }
    return nil
}

/// The menu's mode lookup before localization: by its title.
@MainActor private func i18nOldMode(_ represented: String?) -> OfficeMode? { OfficeMode.offered.first { $0.title == represented } }

/// A scratch copy of the tables with a made-up English for the split keys: shows that
/// the logic does not read the words. Returns the folder; the caller removes it.
private func i18nFakeTables(emptyEnglish: [String]? = nil) -> String {
    let fm = FileManager.default
    let dir = NSTemporaryDirectory() + "i18n-fake-\(emptyEnglish == nil ? "" : "hollow-")\(getpid())"
    try? fm.removeItem(atPath: dir)
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for lang in L10n.languages {
        if let real = L10n.lproj(lang) { try? fm.copyItem(atPath: real.path, toPath: dir + "/" + lang + ".lproj") }
    }
    let fake: [String: [String: String]] = [
        "Board": ["time.justNow": "just now", "time.minutes": "%lldm", "time.hours": "%lldh", "time.days": "%lldd", "time.ago": "%@ ago",
                  "time.waitingApproval": "Needs approval · %@", "time.waitingAnswer": "Needs your answer · %@", "time.waiting": "Waiting · %@"],
        "Office": ["theme.studio": "Slate", "theme.night": "Warm night", "theme.zone": "Seaview"],
        "Zone": ["zone.row.waiting": "Waiting", "zone.row.busy": "Working", "zone.row.news": "News", "zone.row.seen": "Seen"],
    ]
    if let emptyEnglish {
        for table in emptyEnglish {
            try? fm.removeItem(atPath: dir + "/en.lproj/\(table).strings")
            try? "".write(toFile: dir + "/en.lproj/\(table).strings", atomically: true, encoding: .utf8)
        }
        return dir
    }
    for (table, words) in fake {
        let text = words.map { "\"\($0.key)\" = \"\($0.value)\";" }.joined(separator: "\n") + "\n"
        try? fm.removeItem(atPath: dir + "/en.lproj/\(table).strings")
        try? text.write(toFile: dir + "/en.lproj/\(table).strings", atomically: true, encoding: .utf8)
    }
    return dir
}

/// Runs `body` with the tables of `dir` (nil: the real ones) in `lang`, then back to the checks' simplified Chinese.
@MainActor private func i18nWith<T>(_ lang: String, tables dir: String? = nil, _ body: () -> T) -> T {
    L10n.directoryOverride = dir
    L10n.reset()
    L10n.pin(lang)
    defer {
        L10n.directoryOverride = nil
        L10n.reset()
        L10n.pin(L10n.source)
    }
    return body()
}

/// The placeholders of a format, in order (`%@`, `%lld`, `%1$@` …), `%%` left out.
private func i18nPlaceholders(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(?:@|lld|ld|d|f|\\.\\d+f|s)|%#@[a-z]+@")
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }
}

private func i18nHasCJK(_ text: String) -> Bool {
    text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) || (0x3000...0x303F).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
}

@MainActor func i18nTests() {
    let fm = FileManager.default
    let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    var logged: [String] = []
    let keptSink = L10n.logSink
    L10n.logSink = { logged.append($0) }
    defer { L10n.logSink = keptSink }

    // ── 1. The tables: three languages, every table in each, all readable ──
    let lprojs = L10n.languages.compactMap { L10n.lproj($0) }
    check("i18n tables: en, zh-Hans and zh-Hant each have a .lproj beside the checks (build/i18n)", lprojs.count == 3)
    let tableNames = ["Common", "Board", "Office", "Zone", "Settings"]
    var allRead = true
    for lang in L10n.languages {
        for table in tableNames where L10n.keys(table, in: lang) == nil { allRead = false; print("i18n: \(lang)/\(table).strings unreadable or missing") }
        if L10n.keys("Plurals", in: lang) == nil { allRead = false; print("i18n: \(lang)/Plurals.stringsdict unreadable or missing") }
    }
    check("i18n tables: Common, Board, Office, Zone, Settings (.strings) and Plurals (.stringsdict) are there and parse, in all three", allRead)
    let source = Dictionary(uniqueKeysWithValues: tableNames.map { ($0, L10n.keys($0, in: L10n.source) ?? [:]) })
    var pending: [String] = []
    var strays: [String] = [], placeholdersDiffer: [String] = [], cjkInEnglish: [String] = []
    for lang in ["zh-Hant", "en"] {
        for table in tableNames {
            let theirs = L10n.keys(table, in: lang) ?? [:], ours = source[table] ?? [:]
            strays += theirs.keys.filter { ours[$0] == nil }.map { "\(lang)/\(table).\($0)" }
            pending += ours.keys.filter { theirs[$0] == nil }.map { "\(lang)/\(table).\($0)" }
            for (key, value) in theirs where ours[key].map(i18nPlaceholders) != i18nPlaceholders(value) && ours[key] != nil {
                placeholdersDiffer.append("\(lang)/\(table).\(key)")
            }
            if lang == "en" { cjkInEnglish += theirs.filter { i18nHasCJK($0.value) }.map { "en/\(table).\($0.key)" } }
        }
    }
    check("i18n tables: no key in zh-Hant or en that the simplified table lacks (\(strays.joined(separator: ", ")))", strays.isEmpty)
    check("i18n tables: a key's placeholders (%@, %lld, %1$@ …) are the same in every language (\(placeholdersDiffer.joined(separator: ", ")))",
        placeholdersDiffer.isEmpty)
    check("i18n tables: the English table has no Chinese, Japanese or Korean characters (\(cjkInEnglish.joined(separator: ", ")))", cjkInEnglish.isEmpty)
    let commonKeys = L10n.languages.map { Set((L10n.keys("Common", in: $0) ?? [:]).keys) }
    check("i18n tables: Common has the same keys in all three (glossary words only, all decided)", commonKeys.allSatisfy { $0 == commonKeys[0] } && !commonKeys[0].isEmpty)
    // Keys that have no traditional / English words yet; the list is printed for information.
    print("i18n: \(pending.count) keys wait for their traditional / English words (shown in simplified meanwhile): \(pending.sorted().joined(separator: ", "))")

    // Common holds glossary words only: each value is in the glossary, when SOULGENT_GLOSSARY names it (kept outside the repository).
    let glossaryPath = ProcessInfo.processInfo.environment["SOULGENT_GLOSSARY"] ?? ""
    if !glossaryPath.isEmpty, let glossary = try? String(contentsOfFile: glossaryPath, encoding: .utf8) {
        var outside: [String] = []
        for lang in L10n.languages {
            for (key, value) in L10n.keys("Common", in: lang) ?? [:] {
                let written = value.replacingOccurrences(of: "%@", with: "{name}").replacingOccurrences(of: "%lld", with: "{n}")
                if !glossary.contains(written) { outside.append("\(lang)/\(key)=\(value)") }
            }
        }
        check("i18n Common: every word in it is the glossary's, in each language (\(outside.joined(separator: ", ")))", outside.isEmpty)
    } else {
        skipped(glossaryPath.isEmpty ? "no SOULGENT_GLOSSARY" : "no glossary at \(glossaryPath)", "i18n Common: every word in it is the glossary's")
    }

    // Every `L10n.string/format(…, zh: "…")` in the sources: its key is in the simplified table, with the same words.
    let call = try! NSRegularExpression(pattern: "L10n\\.(?:string|format)\\(\"([^\"]+)\", table: \"([A-Za-z]+)\", zh: \"((?:[^\"\\\\]|\\\\.)*)\"")
    var calls = 0
    var unlike: [String] = []
    for file in ["Panel.swift"] + dataSourceFiles + ["Office.swift", "ZoneView.swift", "ZoneModel.swift", "Settings.swift", "SessionSearch.swift", "JumpMark.swift", "ZoneFX.swift"] {
        guard let text = try? String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8) else { continue }
        for m in call.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let ns = text as NSString
            let key = ns.substring(with: m.range(at: 1)), table = ns.substring(with: m.range(at: 2)), zh = ns.substring(with: m.range(at: 3))
            calls += 1
            // A Plurals key (the background-work count has the first in the code): Chinese has the one form, the words themselves.
            let simplified = table == "Plurals" ? L10n.keys("Plurals", in: L10n.source) : source[table]
            if simplified?[key] != zh { unlike.append("\(file): \(table).\(key)") }
        }
    }
    check("i18n sources: each of the \(calls) lookups in the code names a key of the simplified table, its zh: words the table's (\(unlike.joined(separator: ", ")))",
        calls >= 15 && unlike.isEmpty)

    // Plurals (the skeleton's one): English picks one / other; Chinese has one form.
    let options = (1, 3)
    let pluralEN = i18nWith("en") { (L10n.format("common.answerOptions", table: "Plurals", zh: "等你回答（%lld 个选项）", options.0),
                                      L10n.format("common.answerOptions", table: "Plurals", zh: "等你回答（%lld 个选项）", options.1)) }
    let pluralHans = L10n.format("common.answerOptions", table: "Plurals", zh: "等你回答（%lld 个选项）", 3)
    let pluralHant = i18nWith("zh-Hant") { L10n.format("common.answerOptions", table: "Plurals", zh: "等你回答（%lld 个选项）", 3) }
    check("i18n plurals: Needs your answer (1 option) / (3 options); the Simplified and Traditional equivalents",
        pluralEN.0 == "Needs your answer (1 option)" && pluralEN.1 == "Needs your answer (3 options)" && pluralHans == "等你回答（3 个选项）"
            && pluralHant == "等你回答（3 個選項）")
    let common = i18nWith("zh-Hant") { (L10n.string("common.session", table: "Common", zh: "会话"), L10n.format("common.talkingWith", table: "Common", zh: "与 %@ 往来", "Docs")) }
    let commonEN = i18nWith("en") { (L10n.string("common.replyLater", table: "Common", zh: "稍后回复"), L10n.string("common.blazeMode", table: "Common", zh: "火焰与闪电附身")) }
    check("i18n Common: two Traditional Chinese strings in zh-Hant; Reply later, Blaze Mode in English", common == ("會話", "與 Docs 往來") && commonEN == ("Reply later", "Blaze Mode"))

    // ── 2. The language: matched as the system does, pinned, --lang ──
    let matched = [["zh-Hans-HK"], ["zh-Hans-CN"], ["zh-Hant-TW"], ["zh-TW"], ["zh-HK"], ["en-GB"], ["ja-JP"], ["fr-FR"], ["de", "zh-Hant-TW"]].map(L10n.resolve)
    check("i18n language: zh-Hans-HK, zh-Hans-CN → zh-Hans; zh-Hant-TW, zh-TW, zh-HK → zh-Hant; en-GB, ja, fr → en; de then zh-Hant-TW → zh-Hant",
        matched == ["zh-Hans", "zh-Hans", "zh-Hant", "zh-Hant", "zh-Hant", "en", "en", "en", "zh-Hant"])
    check("i18n language: the checks run pinned to zh-Hans", L10n.language == "zh-Hans")
    logged = []
    let refused = !L10n.pin("fr") && L10n.language == "zh-Hans"
    L10n.applyArguments(["x", "--lang", "en"])
    let byArgument = L10n.language
    L10n.applyArguments(["x", "--lang", "ja"])
    let afterBad = L10n.language
    L10n.pin(L10n.source)
    check("i18n language: --lang en pins English; a language with no tables (fr, ja) is refused, logged, and changes nothing",
        refused && byArgument == "en" && afterBad == "en" && logged.count == 2 && logged.allSatisfy { $0.hasPrefix("i18n: no tables for language") })

    // ── 3. A missing key: the simplified original, one log line however often it is asked ──
    let fake = i18nFakeTables()
    defer { try? fm.removeItem(atPath: fake) }
    logged = []
    // The English table is whole, so the key is taken out of a scratch copy of it.
    let hollow = i18nFakeTables(emptyEnglish: ["Board"])
    defer { try? fm.removeItem(atPath: hollow) }
    let missingEN = i18nWith("en", tables: hollow) { (0..<5).map { _ in Elapsed.justNow.words } }
    check("i18n missing: a key the English table lacks shows the simplified table's words (the Chinese for \"just now\"), logged once for five asks",
        missingEN.allSatisfy { $0 == "刚刚" } && logged.count == 1 && logged[0].contains("Board.time.justNow missing in en.lproj"))
    logged = []
    let nowhere = i18nWith("en") { (0..<3).map { _ in L10n.string("i18n.check.nowhere", table: "Board", zh: "原文") } }
    check("i18n missing: a key no table has shows the original written at the call, logged once", nowhere == ["原文", "原文", "原文"] && logged.count == 1)
    logged = []
    let empty = NSTemporaryDirectory() + "i18n-none-\(getpid())"
    try? fm.createDirectory(atPath: empty, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: empty) }
    let noTables = i18nWith("en", tables: empty) { (0..<3).map { _ in Elapsed.minutes(5).words } }
    check("i18n missing: no tables at all still shows the simplified minutes text (never a key), and says so once per thing missing, not per word",
        noTables == ["5 分钟", "5 分钟", "5 分钟"] && logged.count == 3 && logged[0].contains("no en.lproj found"))
    logged = []
    let hans = (0..<3).map { _ in Elapsed.hours(2).words }
    check("i18n missing: in simplified Chinese with its table nothing is logged", hans == ["2 小时", "2 小时", "2 小时"] && logged.isEmpty)

    // ── 4. ago / timeLabel: the same bytes as the baseline in simplified Chinese; the decision reads seconds, not words ──
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let seconds: [Double] = [-30, 0, 1, 59, 59.9, 60, 61, 119, 120, 3599, 3600, 3601, 7199, 86399, 86400, 86401, 172_800, 30 * 86400, 1234 * 86400]
    let statuses: [(String, String)] = [("waiting", "permission prompt"), ("waiting", "input needed"), ("waiting", "permission request"), ("waiting", ""),
                                        ("waiting", "something new"), ("busy", ""), ("idle", ""), ("idle", "permission prompt")]
    var differ: [String] = []
    for back in seconds {
        if ago(now - back, now: now) != i18nOldAgo(now - back, now: now) { differ.append("ago \(back)") }
        for (status, waitingFor) in statuses {
            let s = boardSweepSession("t", status, ago: 0, name: "t", waitingFor: waitingFor)
            var at = s
            at.since = now - back
            if timeLabel(at, now: now) != i18nOldTimeLabel(at, now: now) { differ.append("\(status)/\(waitingFor)/\(back)") }
        }
    }
    check("i18n ago/timeLabel: \(seconds.count) times × \(statuses.count) states, byte for byte as the baseline in simplified Chinese (\(differ.joined(separator: ", ")))",
        differ.isEmpty)
    check("i18n ago: the step is read from the seconds (59 s just now, 60 s a minute, 3600 s an hour, 86400 s a day)",
        Elapsed.of(now - 59, now: now) == .justNow && Elapsed.of(now - 60, now: now) == .minutes(1) && Elapsed.of(now - 3600, now: now) == .hours(1)
            && Elapsed.of(now - 86400, now: now) == .days(1) && Elapsed.of(now + 30, now: now) == .justNow)
    func at(_ status: String, _ waitingFor: String, _ ago: Double) -> Session {
        var s = boardSweepSession("t", status, ago: 0, name: "t", waitingFor: waitingFor)
        s.since = now - ago
        return s
    }
    let english = i18nWith("en", tables: fake) {
        [timeLabel(at("idle", "", 10), now: now), timeLabel(at("idle", "", 300), now: now), timeLabel(at("busy", "", 300), now: now),
         timeLabel(at("waiting", "permission prompt", 10), now: now), timeLabel(at("waiting", "input needed", 7200), now: now),
         timeLabel(at("waiting", "", 2 * 86400), now: now), ago(now - 300, now: now)]
    }
    // A just-now idle session in English reads "just now" with no Chinese suffix: the baseline only knew the Chinese words.
    check("i18n timeLabel: in a made-up English the same decisions, whole-sentence templates: just now (no 'ago'), 5m ago, 5m, Needs approval · just now, Needs your answer · 2h, Waiting · 2d",
        english == ["just now", "5m ago", "5m", "Needs approval · just now", "Needs your answer · 2h", "Waiting · 2d", "5m"])
    check("i18n inboxTime: unchanged (the bare time for a waiting row)",
        inboxTime(at("waiting", "permission prompt", 300), now: now) == "5 分钟" && inboxTime(at("idle", "", 300), now: now) == "5 分钟前")

    // ── 5. theme: id stored and compared, display name shown ──
    check("i18n theme: the ids stay the Chinese names saved settings hold: slate, warm-night, seaview room",
        OfficeTheme.studio.name == "青灰" && OfficeTheme.night.name == "暖夜" && OfficeTheme.zone.name == "海景房")
    check("i18n theme: in simplified Chinese the names shown are the ones shown before (the id itself)",
        [OfficeTheme.studio, OfficeTheme.night, OfficeTheme.zone].allSatisfy { $0.displayName == $0.name })
    let shownEN = i18nWith("en", tables: fake) { [OfficeTheme.studio, .night, .zone].map(\.displayName) }
    let foundEN = i18nWith("en", tables: fake) { ["青灰", "暖夜", "海景房", "Slate"].map { OfficeTheme.named($0).name } }
    check("i18n theme: in a made-up English the names shown change (Slate, Warm night, Seaview); the saved ids still find their themes, a shown name finds none",
        shownEN == ["Slate", "Warm night", "Seaview"] && foundEN == ["青灰", "暖夜", "海景房", "青灰"])
    let defaults = UserDefaults.standard
    let themeKeys = ["office", "officeTheme", "officeThemeOffice"]
    let keptTheme = themeKeys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(themeKeys, keptTheme) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    var legacy: [String] = []
    for lang in ["zh-Hans", "zh-Hant", "en"] {
        for (saved, kept, theme, mode) in [("青灰", "青灰", "青灰", OfficeMode.office), ("暖夜", "暖夜", "暖夜", .office), ("海景房", "海景房", "海景房", .zone)] {
            let ok: Bool = i18nWith(lang, tables: lang == "en" ? fake : nil) {
                defaults.set(true, forKey: "office")
                defaults.set(saved, forKey: "officeTheme")
                OfficeTheme.shown = nil
                settleOfficeTheme()  // as at launch
                return defaults.string(forKey: "officeTheme") == kept && OfficeTheme.current.name == theme && OfficeMode.current == mode
            }
            if !ok { legacy.append("\(lang): \(saved)") }
        }
    }
    check("i18n theme: a saved slate / warm-night / seaview name is kept byte for byte at launch and still means its theme, in all three languages (\(legacy.joined(separator: ", ")))",
        legacy.isEmpty)
    defaults.set("暖夜", forKey: "officeThemeOffice")
    defaults.set(OfficeTheme.zone.name, forKey: "officeTheme")
    let back = i18nWith("en", tables: fake) { () -> String? in
        OfficeMode.office.choose(store: Store())
        return defaults.string(forKey: "officeTheme")
    }
    check("i18n theme: office goes back to the office theme saved (warm-night) in English too", back == "暖夜")

    // ── 6. the zone list's state: a value, its words the table's ──
    let zoneSessions = [boardSweepSession("zw", "waiting", ago: 60, name: "Web-等", waitingFor: "permission prompt"), boardSweepSession("zb", "busy", ago: 60, name: "Web-忙"),
                        boardSweepSession("u-zu", "idle", ago: 60, name: "Web-新"), boardSweepSession("zs", "idle", ago: 1500, name: "Web-看"),
                        boardSweepSession("zr", "idle", ago: 9 * 3600, name: "Web-歇"), boardSweepSession("zv", "busy", ago: 60, name: "无工区会话")]
    let zoneStore = boardSweepStore(zoneSessions)  // u-zu unread; zs, zr looked at
    let oldWords = i18nOldZoneWords(Buckets(zoneStore, now: Date()))
    let keys = [ZoneUI.key("Web"), ZoneUI.visitorKey, ZoneUI.restKey]
    let hansRows = keys.map { ZoneListCard.rows($0, store: zoneStore) }
    let wordsAsBefore = hansRows.allSatisfy { $0.rows.allSatisfy { row in row.1 == (oldWords[row.0.id] ?? "") } }
    let enRows = i18nWith("en", tables: fake) { keys.map { ZoneListCard.rows($0, store: zoneStore) } }
    let sameRows = zip(hansRows, enRows).allSatisfy { a, b in a.rows.map { "\($0.0.id) \($0.2)" } == b.rows.map { "\($0.0.id) \($0.2)" } }
    let enWords = Dictionary(enRows.flatMap { $0.rows.map { ($0.0.id, $0.1) } }, uniquingKeysWith: { a, _ in a })
    check("i18n zone list: rows say what they said before (waiting / working / unread / seen), for a zone, check-in and the rest room",
        wordsAsBefore && hansRows[0].rows.count == 5 && hansRows[1].rows.contains { $0.0.id == "zv" })
    check("i18n zone list: in a made-up English the same rows in the same order and marks, the words the table's (Waiting, Working, News, Seen)",
        sameRows && enWords["zw"] == "Waiting" && enWords["zb"] == "Working" && enWords["u-zu"] == "News" && enWords["zs"] == "Seen" && enWords["zr"] == "Seen")

    // ── 7. --hover's words: command-line tokens ──
    var hoverDiffer: [String] = []
    for word in ["休息室", "报到", "rest", "visitor", "Web", "", "休息室 ", "休息"] {
        if ZoneUI.HoverToken(rawValue: word)?.listKey != i18nOldZoneHover(word) { hoverDiffer.append(word) }
    }
    let officeTokens = ["动态板", "在等你", "动态", "board"].map { OfficeLayout.HoverToken(rawValue: $0) }
    check("i18n --hover: the rest-room and visitor tokens open their lists, nothing else does; the board and waiting tokens are the office's two tokens (\(hoverDiffer.joined(separator: ", ")))",
        hoverDiffer.isEmpty && officeTokens == [.board, .waitingChip, nil, nil])
    let hoverEN = i18nWith("en", tables: fake) { ZoneUI.HoverToken(rawValue: "休息室")?.listKey }
    check("i18n --hover: the tokens do not follow the language", hoverEN == ZoneUI.restKey)

    // ── 8. the menu's modes: found by code, not by title ──
    let modes = OfficeMode.offered
    check("i18n menu: each offered mode has its own code and is found by it, as the lookup by title finds it",
        Set(modes.map(\.code)).count == modes.count && modes.allSatisfy { OfficeMode.coded($0.code) == $0 && i18nOldMode($0.title) == $0 }
            && OfficeMode.coded("海景房") == nil && OfficeMode.coded(nil) == nil)
    let delegate = AppDelegate()
    delegate.store.readOnly = true
    let menu = delegate.makeStatusMenu()
    let represented = menu.items.compactMap { $0.representedObject as? String }
    check("i18n menu: the menu-bar menu's mode items carry their codes (\(represented.joined(separator: ", ")))", represented == modes.map(\.code))

    // ── 9. --dump: the same bytes in every language ──
    let bench = RestartBench("i18n-dump")
    defer { bench.done() }
    let ms = 1_792_746_000.0 * 1000
    func put(_ id: String, _ status: String, _ name: String?, _ lines: [[String: Any]]) {
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.map { String(decoding: try! JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n")
            .write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        var o: [String: Any] = ["pid": 1, "sessionId": id, "status": status, "statusUpdatedAt": ms, "startedAt": ms, "cwd": "/tmp/demo-i18n/" + id, "nameSource": "user"]
        if let name { o["name"] = name }
        if status == "waiting" { o["waitingFor"] = "permission prompt" }
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: bench.registry + "/\(id).json"))
    }
    func said(_ content: [[String: Any]], _ stamp: String) -> [String: Any] {
        ["type": "assistant", "isSidechain": false, "timestamp": stamp, "message": ["role": "assistant", "model": "claude-demo-1", "content": content]]
    }
    func user(_ text: String, _ stamp: String) -> [String: Any] { ["type": "user", "isSidechain": false, "timestamp": stamp, "message": ["role": "user", "content": text]] }
    func tool(_ name: String, _ input: [String: Any], _ stamp: String) -> [String: Any] { said([["type": "tool_use", "id": "toolu_demo", "name": name, "input": input]], stamp) }
    let t0 = "2026-10-23T02:00:00.000Z", t1 = "2026-10-23T02:00:01.000Z"
    put("00000000-demo-wait", "waiting", "Demo-shop-tests", [said([["type": "text", "text": "我来跑一遍单元测试"]], t0),
        tool("Bash", ["command": "swift test", "description": "Run the unit tests"], t1)])
    put("00000000-demo-reply", "idle", "Demo-shop-docs", [user("把 README 的安装步骤补全", t0),
        said([["type": "text", "text": "README 的安装步骤补好了，共 4 步。\n细节见提交说明。"]], "2026-10-23T02:00:30.000Z")])
    put("i18n-ask", "waiting", "Demo-ask", [said([["type": "text", "text": "问"]], t0), tool("AskUserQuestion", ["questions": [["question": "先备份？"], ["question": "哪个分支？"]]], t1)])
    put("i18n-edit", "waiting", "Demo-edit", [said([["type": "text", "text": "改"]], t0), tool("Edit", [:], t1)])
    put("i18n-tool", "waiting", "Demo-tool", [said([["type": "text", "text": "查"]], t0), tool("WebFetch", ["url": "https://example.com"], t1)])
    put("i18n-plan", "waiting", "Demo-plan", [said([["type": "text", "text": "计划"]], t0), tool("ExitPlanMode", ["plan": "1"], t1)])
    put("i18n-you", "busy", "Demo-you", [said([["type": "text", "text": "上一轮"]], t0), user("把按钮改成蓝色", t1)])
    put("i18n-untitled", "idle", nil, [said([["type": "text", "text": "没有名字"]], t0)])
    put("i18n-none", "idle", "Demo-none", [])
    func dump() -> Data {
        let rows = bench.load().map { dumpRow($0, model: "claude-demo-1") }.sorted { ($0["id"] as? String ?? "") < ($1["id"] as? String ?? "") }
        return try! JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    }
    let dumps = [i18nWith("zh-Hans") { dump() }, i18nWith("zh-Hant") { dump() }, i18nWith("en") { dump() }, i18nWith("en", tables: fake) { dump() }]
    let dumped = String(decoding: dumps[0], as: UTF8.self)
    check("i18n dump: the --dump rows of 9 made-up sessions are byte for byte the same in zh-Hans, zh-Hant, English and a made-up English (\(dumps.map(\.count)) bytes)",
        dumps.allSatisfy { $0 == dumps[0] } && dumps[0].count > 2000)
    check("i18n dump: they hold the simplified summaries and names (approve-to-run, question and approve-to-edit lines, and the untitled default), and no word of the tables' English",
        dumped.contains("等你批准运行：Run the unit tests") && dumped.contains("问你：先备份？（共 2 个问题）") && dumped.contains("等你批准修改：文件")
            && dumped.contains("\"name\" : \"未命名\"") && dumped.contains("计划写好了，等你批准") && dumped.contains("你：把按钮改成蓝色")
            && !["Needs", "Waiting", "just now", "Slate", "Seaview"].contains { dumped.contains($0) })
    // The golden: two sample rows, with the seven background keys a session with no background task has, and the ten error fields a session with no trouble has.
    let golden = """
        {
          "bgAgents" : 0,
          "bgEndedAt" : null,
          "bgList" : [

          ],
          "bgOwned" : false,
          "bgSince" : null,
          "bgStale" : false,
          "bgTasks" : 0,
          "compactedAt" : null,
          "disconnected" : false,
          "disconnectedSince" : null,
          "errorKind" : null,
          "errorSince" : null,
          "errorStatus" : null,
          "errorText" : null,
          "helpers" : 0,
          "id" : "00000000-demo-wait",
          "kind" : "claude",
          "model" : "claude-demo-1",
          "name" : "Demo-shop-tests",
          "nameUntitled" : false,
          "origin" : "user",
          "peer" : "",
          "project" : "00000000-demo-wait",
          "retryAttempt" : null,
          "retryMax" : null,
          "since" : 1792746000,
          "status" : "waiting",
          "summary" : "等你批准运行：Run the unit tests",
          "summaryArgs" : {
            "command" : "Run the unit tests"
          },
          "summaryCode" : "wait.approve.run",
          "waitingFor" : "permission prompt"
        }
        """
    let english2 = i18nWith("en") { () -> String? in
        bench.load().first { $0.id == "00000000-demo-wait" }.map { String(decoding: try! JSONSerialization.data(withJSONObject: dumpRow($0, model: "claude-demo-1"), options: [.prettyPrinted, .sortedKeys]), as: UTF8.self) }
    }
    check("i18n dump: the waiting sample row, in English, is the sample row's byte for byte", english2 == golden)
    let panelText = panelSources(sources)
    let renderBody = panelText.range(of: "static func render(code: String, args: [String: Any]) -> String?").map { String(panelText[$0.lowerBound...].prefix(2200)) } ?? ""
    check("i18n dump: SummaryLine.render (the dump's templates) never reads the tables, and --dump pins zh-Hans",
        !renderBody.isEmpty && !renderBody.contains("L10n") && panelText.contains("if args.contains(\"--dump\") {") && panelText.contains("L10n.pin(L10n.source)\n            let loader = Loader()"))

    // ── 10. The language switch (Settings > General): AppleLanguages in this app's domain, nothing else ──
    let domain = LanguageChoice.domain
    let keptLanguage = defaults.persistentDomain(forName: domain)?[L10n.languageKey]
    defaults.set(1.15, forKey: "zoom")
    let before = (defaults.persistentDomain(forName: domain) ?? [:]).filter { $0.key != L10n.languageKey }
    LanguageChoice.set(nil)
    let none = LanguageChoice.current()
    LanguageChoice.set("zh-Hant")
    let hant = (LanguageChoice.current(), defaults.persistentDomain(forName: domain)?[L10n.languageKey] as? [String])
    LanguageChoice.set("en")
    let en = LanguageChoice.current()
    LanguageChoice.set("fr")
    let refusedChoice = LanguageChoice.current()
    LanguageChoice.set("zh-Hans")
    let after = (defaults.persistentDomain(forName: domain) ?? [:]).filter { $0.key != L10n.languageKey }
    let pinnedStill = L10n.language
    LanguageChoice.set(nil)
    let cleared = defaults.persistentDomain(forName: domain)?[L10n.languageKey] == nil
    if let keptLanguage { defaults.set(keptLanguage, forKey: L10n.languageKey) }
    defaults.removeObject(forKey: "zoom")
    check("i18n switch: follow system writes nothing; Traditional writes AppleLanguages = (zh-Hant) in the app's own domain; English (en); anything else is the system's again",
        none == nil && hant.0 == "zh-Hant" && hant.1 == ["zh-Hant"] && en == "en" && refusedChoice == nil && cleared)
    check("i18n switch: no other setting is touched, and the words do not change before the next launch",
        NSDictionary(dictionary: before).isEqual(to: after) && pinnedStill == "zh-Hans")
    check("i18n switch: the system's languages (the global domain) never read as a choice made here",
        defaults.persistentDomain(forName: domain)?[L10n.languageKey] == nil && LanguageChoice.current() == nil)

    // ── 11. defaults keys: the same names as the baseline, AppleLanguages the only addition ──
    // The keys this scan found in the sources; keys read through a variable are not in it.
    let known: Set<String> = ["bannedPets", "bgCountsAsWorking", "favoritePets", "helperPetClaude", "helperPetCodex", "homePlace", "homeScreen", "office", "officeFloor", "officeSpotlight", "officeTheme",
                              "officeThemeOffice", "officeWalks", "parked", "petByName", "petByNameOrder", "petByPane", "petByPaneOrder", "petBySession",
                              "pinned", "projectContainers", "seenAt", "seenBaseline", "showFailed", "showOlder", "visitSpotLegacy", "waitingNudge", "zoneAura", "zoneFigureSize", "zoneFigureSizeOrder",
                              "zoneLightning", "zoneOrca", "zoom"]
    let keyPattern = try! NSRegularExpression(pattern: "(?:UserDefaults[^\\n]*|defaults\\.[^\\n]*)forKey: \"([A-Za-z0-9.]+)\"|@AppStorage\\(\"([A-Za-z0-9.]+)\"")
    var found = Set<String>()
    for file in ["Panel.swift"] + dataSourceFiles + ["Office.swift", "ZoneView.swift", "ZoneModel.swift", "ZoneFX.swift", "Settings.swift", "SessionSearch.swift", "JumpMark.swift", "Extensions.swift", "L10n.swift"] {
        guard let text = try? String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8) else { continue }
        for m in keyPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for g in [1, 2] where m.range(at: g).location != NSNotFound { found.insert((text as NSString).substring(with: m.range(at: g))) }
        }
    }
    let unknown = found.subtracting(known)
    check("i18n defaults: every settings key the code reads or writes is one it had before localization (new: \(unknown.sorted().joined(separator: ", ")))",
        unknown.isEmpty && found == known && L10n.languageKey == "AppleLanguages")

    // ── 12. build.sh: lint, three lproj in the app, the two Info.plist keys ──
    let build = (try? String(contentsOf: sources.appendingPathComponent("build.sh"), encoding: .utf8)) ?? ""
    let tests = (try? String(contentsOf: sources.appendingPathComponent("test.sh"), encoding: .utf8)) ?? ""
    check("i18n build: build.sh lints every table, copies the three .lproj into Resources, says CFBundleDevelopmentRegion en and CFBundleLocalizations en / zh-Hans / zh-Hant",
        build.contains("plutil -lint -s") && build.contains("I18N_LANGS=(en zh-Hans zh-Hant)") && build.contains("cp -R \"i18n/$lang.lproj\" \"$APP/Contents/Resources/\"")
            && build.contains("<key>CFBundleDevelopmentRegion</key>\n    <string>en</string>")
            && build.contains("<key>CFBundleLocalizations</key>\n    <array>\n        <string>en</string>\n        <string>zh-Hans</string>\n        <string>zh-Hant</string>\n    </array>")
            && build.contains(" L10n.swift ") && tests.contains(" L10n.swift ") && tests.contains("I18nTests.swift") && tests.contains("ln -sfn ../i18n build/i18n"))

    // ── 13. the card's line says the same as --dump's in simplified Chinese; in English no Chinese is left of the board's own words ──
    let sampleLines: [SummaryLine] = [
        .empty, .text("done", kind: .reply), .ask(question: "Which?", count: 1), .ask(question: "Which?", count: 3), .askGeneric, .plan,
        .approveRun(command: "ls -l"), .approveEdit(file: "a.txt"), .approveEdit(file: nil), .approveTool(tool: "Bash"), .approve,
        .answer(options: nil), .answer(options: 1), .answer(options: 3), .paused, .stopped, .error, .you("go"), .relayAgent, .relayPeer,
        .relayFrom(peer: "docs"), .apiError(kind: "api", status: 529, text: "overloaded"), .apiError(kind: "api", status: nil, text: "overloaded"),
        .apiError(kind: "auth", status: nil, text: "login"), .apiError(kind: "rate_limit", status: nil, text: "limit"), .retrying(attempt: 1, max: 3),
        .disconnected,
    ]
    let unequal = sampleLines.filter { $0.displayText != $0.rendered }.map(\.code)
    check("i18n card line: in simplified Chinese displayText is the same bytes as rendered, for all \(sampleLines.count) forms (\(unequal.joined(separator: ", ")))", unequal.isEmpty)
    let englishLines = i18nWith("en") { sampleLines.map(\.displayText) }
    check("i18n card line: in English none of the \(sampleLines.count) forms has Chinese left (\(englishLines.filter(i18nHasCJK).joined(separator: " | ")))",
        !englishLines.contains(where: i18nHasCJK) && englishLines[sampleLines.firstIndex(of: .approve)!] == "Needs approval"
            && englishLines[sampleLines.firstIndex(of: .answer(options: 1))!] == "Needs your answer (1 option)")
    check("i18n tables: no key still waits for its traditional or English words", pending.isEmpty)

    // ── 14. untitled is shown in the screen's language; the name itself (--dump, matching) never changes ──
    var untitled = Session(id: "u1", pid: 1, project: "p", name: "未命名", status: "idle", since: Date(), summary: "")
    untitled.nameUntitled = true
    let named = Session(id: "u2", pid: 1, project: "p", name: "未命名", status: "idle", since: Date(), summary: "")  // one the user really called that
    let shown = ["zh-Hans", "zh-Hant", "en"].map { lang in i18nWith(lang) { (untitled.shownName, named.shownName, dumpRow(untitled, model: "")["name"] as? String ?? "") } }
    check("i18n untitled: the default name shows as Simplified / Traditional / Untitled on screen, a chosen name equal to it stays, --dump's name is the Simplified default in all three",
        shown.map(\.0) == ["未命名", "未命名", "Untitled"] && shown.allSatisfy { $0.1 == "未命名" && $0.2 == "未命名" })
    let fixed: [(String, String)] = [("出错", "Error"), ("要你批准：docker compose up -d", "Approve to run: docker compose up -d"), ("要你回答：先改哪一个？", "Asks: 先改哪一个？")]
    let fixedShown = i18nWith("en") { fixed.map { boardSweepSession("f", "waiting", ago: 1, name: "n", summary: $0.0).shownSummary } }
    check("i18n fixtures: the made-up cards' error, approval and question lines become codes, so English shows Error / Approve to run: ... / Asks: ... (\(fixedShown))",
        fixedShown == fixed.map(\.1) && fixed.allSatisfy { boardSweepSession("f", "waiting", ago: 1, name: "n", summary: $0.0).summary == fixtureLine($0.0)?.rendered })
}

/// `--i18n-theme-legacy-stills <dir>`: for each theme value a setting an earlier version saved holds (slate, warm-night, seaview room), the launch
/// step (`settleOfficeTheme`) and then the office or the room as it draws: `<n>-<value>.png`, and what was stored and found
/// in `result.txt`. In the language `--lang` asks for (the checks' zh-Hans without).
@MainActor func i18nThemeLegacyStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    let defaults = UserDefaults.standard
    let store = boardSweepStore(boardSweepAllStates(), pinned: ["u-pin"], agents: ["b-1": 1, "b-3": 3])
    var lines = ["language \(L10n.language)", "saved → stored after launch | theme found (shown as) | mode"]
    for (n, saved) in ["青灰", "暖夜", "海景房"].enumerated() {
        defaults.set(true, forKey: "office")
        defaults.set(saved, forKey: "officeTheme")
        OfficeTheme.shown = nil
        settleOfficeTheme()
        let stored = defaults.string(forKey: "officeTheme") ?? "(none)"
        let theme = OfficeTheme.current
        lines.append("\(saved) → \(stored) | \(theme.name) (\(theme.displayName)) | \(OfficeMode.current.code)")
        let path = dir + "/\(n + 1)-\(saved).png"
        let size = CGSize(width: 1194, height: 764)
        save(ZoneUI.active ? zoneStill(store, size: size) : officeStill(store, size: size), path)
        print(path)
    }
    for key in ["office", "officeTheme"] { defaults.removeObject(forKey: key) }
    try? (lines.joined(separator: "\n") + "\n").write(toFile: dir + "/result.txt", atomically: true, encoding: .utf8)
    print(lines.joined(separator: "\n"))
}
