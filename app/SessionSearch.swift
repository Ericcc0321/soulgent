import AppKit
import SwiftUI

/// Search in the title bar, in every scene (Duty Room, Office, Seaview, and an extension's). The magnifier beside the scene switch opens a
/// small field over the window's top-right corner; what is typed is looked for in each open session's name, project and
/// folder, case-insensitively, and the list follows as it is typed. Enter or a click on a row goes to that session as a
/// click on its card does (looked at, then Orca jumps to it); ↑↓ move through the list; Esc closes it.
@MainActor enum SessionSearch {
    /// Rows the list shows at most.
    static let shows = 8

    /// The sessions whose name, project or folder holds the words, in that order of weight: a name starting with them
    /// first, then the rest of the name hits, then project and folder hits; within each, those waiting for you, then the
    /// finished ones not looked at, then the busy, then the rest, each by name.
    static func results(_ query: String, in sessions: [Session], unread: (Session) -> Bool = { _ in false }) -> [Session] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !words.isEmpty else { return [] }
        func weight(_ s: Session) -> Int? {
            let name = s.name.lowercased()
            if name.hasPrefix(words) { return 0 }
            if name.contains(words) { return 1 }
            if s.project.lowercased().contains(words) { return 2 }
            if s.cwd.lowercased().contains(words) { return 3 }
            return nil
        }
        func urgency(_ s: Session) -> Int { s.status == "waiting" ? 0 : unread(s) ? 1 : s.isWorking ? 2 : 3 }
        return sessions.compactMap { s in weight(s).map { (s, $0) } }
            .sorted { a, b in (a.1, urgency(a.0), a.0.name, a.0.id) < (b.1, urgency(b.0), b.0.name, b.0.id) }
            .map(\.0)
    }

    /// The highlighted row after ↑ (-1) or ↓ (+1): round the ends.
    static func step(_ index: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + delta) % count + count) % count
    }

    /// The folder as it reads best: the home folder as ~.
    static func folder(_ cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        return cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
    }

    /// The status dot's colour, as the board's counts have them.
    static func dot(_ s: Session, store: Store) -> Color {
        if let tone = store.failTone(s), tone != .gone { return tone.color }  // An error's red, a retry's or the limit's amber
        return s.status == "waiting" ? call : s.isWorking ? work : store.isUnread(s) ? paper : quiet
    }

    /// Opens the field, with the window made key so the field takes the typing (the panel never activates the app).
    static func open(_ store: Store, in window: NSWindow? = nil) {
        store.searchQuery = ""
        store.searchIndex = 0
        store.searchOpen = true
        (window ?? NSApp.windows.first { $0 is NSPanel && $0.isVisible })?.makeKey()
    }

    static func close(_ store: Store) { store.searchOpen = false }

    /// To that session, as a click on its card: looked at, then the jump to Orca (`jumper`, for checks); the field closes.
    static func go(_ s: Session, store: Store, jumper: (Session) -> Void = { jump(to: $0) }) {
        store.markSeen(s)
        close(store)
        jumper(s)
    }
}

/// The magnifier in the title bar, beside the scene switch.
struct SearchButton: View {
    @ObservedObject var store: Store
    let z: CGFloat

    var body: some View {
        Button {
            if store.searchOpen { SessionSearch.close(store) } else { SessionSearch.open(store) }
        } label: {
            Image(systemName: "magnifyingglass").font(.system(size: 11.5 * z, weight: .semibold))
                .foregroundStyle(store.searchOpen ? paper : quiet).frame(width: 22 * z, height: 20 * z).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(L10n.string("search.help", table: "Board", zh: "搜索会话（名字、项目、目录）")).accessibilityLabel(L10n.string("search.label", table: "Board", zh: "搜索会话"))
    }
}

/// The field and its list, over the window's top-right corner while the search is open.
struct SearchPanel: View {
    @ObservedObject var store: Store
    @FocusState private var focused: Bool
    @Environment(\.zoom) private var z
    @Environment(\.still) private var still

    /// `query`: words to start with (the checks' pictures); none, the field as `SessionSearch.open` left it.
    init(store: Store, query: String? = nil) {
        self.store = store
        if let query {
            store.searchQuery = query
            store.searchIndex = 0
        }
    }

    private var query: String { store.searchQuery }
    private var index: Int {
        get { store.searchIndex }
        nonmutating set { store.searchIndex = newValue }
    }

    var body: some View {
        let found = Array(SessionSearch.results(query, in: store.sessions, unread: store.isUnread).prefix(SessionSearch.shows))
        VStack(alignment: .leading, spacing: 4 * z) {
            HStack(spacing: 6 * z) {
                Image(systemName: "magnifyingglass").font(.system(size: 11 * z, weight: .semibold)).foregroundStyle(quiet)
                if still {
                    // A picture: ImageRenderer cannot draw AppKit's field, so the words as text.
                    Text(query.isEmpty ? L10n.string("search.placeholder", table: "Board", zh: "搜索会话：名字、项目、目录") : query).font(rounded(12.5 * z, .medium)).foregroundStyle(query.isEmpty ? quiet : paper)
                    Spacer(minLength: 0)
                } else {
                TextField(L10n.string("search.placeholder", table: "Board", zh: "搜索会话：名字、项目、目录"), text: $store.searchQuery)
                    .textFieldStyle(.plain).font(rounded(12.5 * z, .medium)).foregroundStyle(paper)
                    .focused($focused)
                    .onSubmit { if index < found.count { SessionSearch.go(found[index], store: store) } }
                    .onKeyPress(.upArrow) {
                        index = SessionSearch.step(index, by: -1, count: found.count)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        index = SessionSearch.step(index, by: 1, count: found.count)
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        SessionSearch.close(store)
                        return .handled
                    }
                    .onExitCommand { SessionSearch.close(store) }
                }
                Button { SessionSearch.close(store) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(quiet).frame(width: 18 * z, height: 18 * z).contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityLabel(L10n.string("search.close", table: "Board", zh: "关闭搜索"))
            }
            .padding(.horizontal, 8 * z).padding(.vertical, 6 * z)
            .background(RoundedRectangle(cornerRadius: 7 * z, style: .continuous).fill(Color.white.opacity(0.07)))
            if !query.trimmingCharacters(in: .whitespaces).isEmpty && found.isEmpty {
                Text(L10n.string("search.none", table: "Board", zh: "没有找到")).font(rounded(11 * z, .medium)).foregroundStyle(quiet).padding(.horizontal, 8 * z).padding(.vertical, 4 * z)
            }
            ForEach(Array(found.enumerated()), id: \.element.id) { i, s in
                Button { SessionSearch.go(s, store: store) } label: {
                    HStack(spacing: 8 * z) {
                        Circle().fill(SessionSearch.dot(s, store: store)).frame(width: 7 * z, height: 7 * z)
                        VStack(alignment: .leading, spacing: 1 * z) {
                            Text(s.shownName).font(rounded(12 * z)).foregroundStyle(paper).lineLimit(1)
                            Text([s.project, SessionSearch.folder(s.cwd)].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(rounded(10 * z, .medium)).foregroundStyle(quiet).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8 * z).padding(.vertical, 4 * z)
                    .background(RoundedRectangle(cornerRadius: 6 * z, style: .continuous).fill(i == index ? Color.white.opacity(0.13) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { if $0 { index = i } }
            }
        }
        .padding(6 * z)
        .frame(width: 320 * z, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10 * z, style: .continuous).fill(night.opacity(0.97)))
        .overlay(RoundedRectangle(cornerRadius: 10 * z, style: .continuous).stroke(quiet.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8 * z, y: 3 * z)
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
    }
}
