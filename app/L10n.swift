import Foundation

// ───────── i18n: the one way words reach the screen ─────────
//
// Tables: `app/i18n/<lang>.lproj/<Table>.strings` (and `Plurals.stringsdict`), one table per screen: Common (only words of the three-language glossary, the three-language glossary), Board, Office, Zone,
// Settings. Keys are stable English ids (`time.justNow`), never the Chinese.
//
// Languages: simplified Chinese (`zh-Hans`, the source), traditional Chinese (`zh-Hant`) and English (`en`). The system's
// choice picks one (also a per-app language set in System Settings, or Settings > General > Language, which writes `AppleLanguages`
// into this app's own defaults); any other language falls back to English. `pin` fixes one: the checks run in zh-Hans,
// `--lang <code>` asks for one for pictures.
//
// A key missing in the chosen language shows the simplified original (the zh-Hans table, else the `zh:` given at the call)
// and logs one line per key, once: never a key on screen, never a silent fall back.
//
// Not for data: `--dump`, defaults keys and values, logs and anything compared or stored keep their own
// fixed strings and never come through here.
enum L10n {
    /// The languages the app has tables for. English first: preferences matching none of them fall back to it.
    static let languages = ["en", "zh-Hans", "zh-Hant"]
    /// The language the words are written in first; what a missing key shows.
    static let source = "zh-Hans"
    static let tables = ["Common", "Board", "Office", "Zone", "Settings", "Plurals"]
    /// The standard key the language chosen for this app is kept under, in its own defaults domain.
    static let languageKey = "AppleLanguages"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pinned: String?
    nonisolated(unsafe) private static var resolved: String?
    nonisolated(unsafe) private static var bundles: [String: Bundle?] = [:]
    nonisolated(unsafe) private static var reported = Set<String>()
    /// Where a missing key or table is reported (panel.log); a check catches it.
    nonisolated(unsafe) static var logSink: (String) -> Void = { log($0) }
    /// For the checks: tables read from here instead of the app's.
    nonisolated(unsafe) static var directoryOverride: String?

    /// The language the words are shown in: the pinned one, else the one the preferences pick (once per run: a language
    /// chosen in Settings takes effect at the next launch).
    static var language: String {
        lock.lock()
        defer { lock.unlock() }
        if let pinned { return pinned }
        if let resolved { return resolved }
        let chosen = resolve(preferences: UserDefaults.standard.stringArray(forKey: languageKey) ?? Locale.preferredLanguages)
        resolved = chosen
        return chosen
    }

    /// The table language for a list of preferred languages, as the system matches them (zh-Hans-HK → zh-Hans, zh-TW and
    /// zh-HK → zh-Hant, ja → en).
    static func resolve(preferences: [String]) -> String {
        Bundle.preferredLocalizations(from: languages, forPreferences: preferences).first ?? "en"
    }

    /// Fixes the language (nil: the preferences' again). One the app has no tables for is refused, and said so.
    @discardableResult static func pin(_ code: String?) -> Bool {
        if let code, !languages.contains(code) {
            report("lang:\(code)", "i18n: no tables for language \(code) (have \(languages.joined(separator: ", "))); the language stays \(language)")
            return false
        }
        lock.lock()
        pinned = code
        lock.unlock()
        return true
    }

    /// `--lang <code>` on the command line pins that language (pictures in another language); anything else is left.
    static func applyArguments(_ arguments: [String]) {
        guard let i = arguments.firstIndex(of: "--lang") else { return }
        guard i + 1 < arguments.count else {
            report("lang:", "i18n: --lang without a language; the language stays \(language)")
            return
        }
        pin(arguments[i + 1])
    }

    /// The words for `key` in `table`, in the chosen language; `zh` is the simplified original, shown when no table has it.
    static func string(_ key: String, table: String, zh: String) -> String {
        let lang = language
        if let found = lookup(key, table: table, in: lang) { return found }
        if lang != source, let found = lookup(key, table: table, in: source) {
            report("\(lang)/\(table)/\(key)", "i18n: \(table).\(key) missing in \(lang).lproj; showing the simplified original")
            return found
        }
        report("\(source)/\(table)/\(key)", "i18n: \(table).\(key) missing in \(source).lproj too; showing the original written at the call")
        return zh
    }

    /// As `string`, with `%@` / `%lld` (or `%1$@` …) filled in; a `Plurals` key picks its plural form by the number.
    /// Numbers are written as `"\(n)"` writes them (1234, never 1,234): only a plural, which needs the language's rules,
    /// is formatted under its locale.
    static func format(_ key: String, table: String, zh: String, _ args: CVarArg...) -> String {
        String(format: string(key, table: table, zh: zh), locale: table == "Plurals" ? Locale(identifier: language) : nil, arguments: args)
    }

    /// The keys of a table in a language, as the file holds them (nil: no such file). For the checks.
    static func keys(_ table: String, in lang: String) -> [String: String]? {
        guard let dir = lproj(lang) else { return nil }
        let base = dir.appendingPathComponent(table)
        if let strings = NSDictionary(contentsOf: base.appendingPathExtension("strings")) as? [String: String] { return strings }
        if let dict = NSDictionary(contentsOf: base.appendingPathExtension("stringsdict")) as? [String: Any] {
            return dict.mapValues { (($0 as? [String: Any])?["NSStringLocalizedFormatKey"] as? String) ?? "" }
        }
        return nil
    }

    /// The `<lang>.lproj` folder the tables are read from: the app's Resources, else `i18n/` beside the binary (the checks
    /// run from `app/build/`, where test.sh links `build/i18n -> ../i18n`), else beside its folder.
    static func lproj(_ lang: String) -> URL? {
        let name = lang + ".lproj"
        if let directoryOverride { return URL(fileURLWithPath: directoryOverride).appendingPathComponent(name) }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        let places = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            exe.appendingPathComponent("i18n/" + name),
            exe.deletingLastPathComponent().appendingPathComponent("i18n/" + name),
        ]
        return places.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Forgets the tables read and the lines logged (the checks swap tables).
    static func reset() {
        lock.lock()
        bundles = [:]
        reported = []
        resolved = nil
        lock.unlock()
    }

    private static let absent = "\u{1}absent\u{1}"

    private static func lookup(_ key: String, table: String, in lang: String) -> String? {
        guard let bundle = bundle(lang) else { return nil }
        let found = bundle.localizedString(forKey: key, value: absent, table: table)
        return found == absent ? nil : found
    }

    /// One `.lproj` folder read as a bundle of its own, so the language is ours and not `Bundle.main`'s choice.
    private static func bundle(_ lang: String) -> Bundle? {
        lock.lock()
        if let known = bundles[lang] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let made = lproj(lang).flatMap { Bundle(path: $0.path) }
        lock.lock()
        bundles[lang] = made
        lock.unlock()
        if made == nil { report("dir:\(lang)", "i18n: no \(lang).lproj found (app Resources or i18n/ beside the binary)") }
        return made
    }

    /// One line in the log per thing, the first time only.
    private static func report(_ what: String, _ line: String) {
        lock.lock()
        let first = reported.insert(what).inserted
        lock.unlock()
        if first { logSink(line) }
    }
}
