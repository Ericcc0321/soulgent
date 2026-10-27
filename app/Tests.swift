// Checks for the board's rules: what counts as unread, which way a link runs, where its line
// goes, what the usage figures say. Run with ./test.sh. Nothing here ships in the app.

import AppKit
import Combine
import SQLite3
import SwiftUI

@MainActor var failed = 0

@MainActor func check(_ what: String, _ ok: Bool) {
    print((ok ? "ok    " : "FAIL  ") + what)
    if !ok { failed += 1 }
}

/// The sources that moved out of Panel.swift: the data layer (Data/) and the readers of other programs' formats (Adapters/).
let dataSourceFiles = ["Data/Session.swift", "Data/Dump.swift", "Adapters/ClaudeCode.swift", "Data/Loader.swift", "Adapters/Codex.swift", "Adapters/WorkBuddy.swift", "Adapters/Orca.swift"]

/// Panel.swift together with the data layer's files, as the one text Panel.swift used to be (the data layer first, as it was).
func panelSources(_ dir: URL) -> String {
    (dataSourceFiles + ["Panel.swift"]).map { (try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) ?? "" }.joined(separator: "\n")
}

@MainActor var skips = 0

/// A check that cannot run here, and why (no cut pet frames, no fixtures): said on its own line, not a failure.
@MainActor func skipped(_ why: String, _ what: String) {
    print("skipped: \(why) — \(what)")
    skips += 1
}

func session(_ id: String, _ status: String = "idle", finished secondsAgo: TimeInterval = 100) -> Session {
    Session(
        id: id, pid: 1, project: "p", name: id, status: status, since: Date().addingTimeInterval(-secondsAgo), summary: "")
}

@MainActor func usageTests() {
    let dir = NSTemporaryDirectory() + "panel-tests-\(getpid())"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    func publish(_ window: String, _ line: String) {
        try? line.write(toFile: dir + "/shared." + window, atomically: true, encoding: .utf8)
    }
    let now = Date(timeIntervalSince1970: 1_791_185_847)

    publish("five_hour", "38 1791192600\n")
    check(
        "usage: reads the percentage and the reset time the status line published",
        readUsage("five_hour", in: dir, now: now) == Usage(percent: 38, resets: Date(timeIntervalSince1970: 1_791_192_600)))
    publish("seven_day", "55 1791100000\n")
    check("usage: a window that has already reset shows nothing", readUsage("seven_day", in: dir, now: now) == nil)
    check("usage: nothing published, nothing shown", readUsage("one_day", in: dir, now: now) == nil)
    publish("five_hour", "\n")
    check("usage: an empty file shows nothing", readUsage("five_hour", in: dir, now: now) == nil)
    publish("five_hour", "lots 1791192600\n")
    check("usage: a line that is not two numbers shows nothing", readUsage("five_hour", in: dir, now: now) == nil)

    // The same steps as the status line: calm below 50, then 50, 70 and 90.
    check("usage: 49% is still calm", usageColor(49) == work)
    check("usage: 50% is no longer calm", usageColor(50) != work)
    check("usage: 70% looks different from 69%", usageColor(70) != usageColor(69))
    check("usage: 89% is not yet the alarm colour", usageColor(89) != call)
    check("usage: 90% is the alarm colour", usageColor(90) == call)
}

/// The phone's marks (board WebApp): written into the settings from outside, taken in on the next tick.
@MainActor func phoneSyncTests() {
    let store = Store()
    let a = session("a", finished: 100), b = session("b", finished: 100)
    store.sessions = [a, b]
    store.markAllSeen()
    let mine = store.seen["a"] ?? 0
    // The phone looks at b later than the panel did, and has an older look at a.
    var stored = UserDefaults.standard.dictionary(forKey: "seenAt") ?? [:]
    stored["b"] = mine + 50
    stored["a"] = mine - 500
    UserDefaults.standard.set(stored, forKey: "seenAt")
    store.takeStored()
    check("phone sync: a later look from the phone is taken in", store.seen["b"] == mine + 50)
    check("phone sync: an older look written on the phone (mark as unread) wins too, and the session is unread again",
        store.seen["a"] == mine - 500 && store.isUnread(a))
    check("phone sync: only entries changed outside are taken over, and numbers of any kind are read",
        Store.adopted(["x": 5, "y": 9, "w": 4], stored: Store.numbers(["x": NSNumber(value: 7), "y": NSNumber(value: Float(3)), "z": 1, "w": 2]),
            before: ["y": 3, "w": 1]) == ["x": 7, "y": 9, "z": 1, "w": 2])
    // A phone look arriving between two ticks survives the panel's own save.
    stored = UserDefaults.standard.dictionary(forKey: "seenAt") ?? [:]
    stored["b"] = mine + 90
    UserDefaults.standard.set(stored, forKey: "seenAt")
    store.markSeen(a)
    check("phone sync: the panel's own later look is kept after the phone's mark as unread", (store.seen["a"] ?? 0) > mine - 500 && !store.isUnread(a))
    check("phone sync: the panel's save does not write over a look the phone just made",
        ((UserDefaults.standard.dictionary(forKey: "seenAt")?["b"]) as? NSNumber)?.doubleValue == mine + 90)
    // Pins: the stored list is the truth.
    UserDefaults.standard.set(["b"], forKey: "pinned")
    store.takeStored()
    check("phone sync: a pin set on the phone shows", store.pinned == ["b"])
    UserDefaults.standard.set([String](), forKey: "pinned")
    store.takeStored()
    check("phone sync: a pin taken off on the phone goes", store.pinned.isEmpty)
    // Nothing changed outside: nothing is published.
    var told = 0
    let watch = store.objectWillChange.sink { told += 1 }
    store.takeStored()
    check("phone sync: a tick with nothing new from the phone publishes nothing", told == 0)
    watch.cancel()
}

@MainActor func pinTests() {
    let store = Store()
    let a = session("a"), b = session("b")
    store.sessions = [a, b]
    store.markAllSeen()

    store.togglePin(a)
    check("pins: pinning puts a looked-at session back under unread", store.isUnread(a))
    store.markSeen(a)
    check("pins: opening a pinned session leaves it there", store.isUnread(a))
    store.markAllSeen()
    check("pins: Mark All Seen leaves pinned sessions alone", store.isUnread(a) && !store.isUnread(b))
    check("pins: with only pins left, Mark All Seen has nothing to do", !store.sessions.contains(where: store.isFresh))
    check("pins: are remembered across a restart", Store().pinned.contains("a"))

    let fresh = session("fresh", finished: 10)
    store.sessions = [fresh, a, b]
    check("pins: a session that just finished is fresh news", store.isFresh(fresh))
    check("pins: a pinned session leads its group", Buckets(store, now: Date()).unread.map(\.id) == ["a", "fresh"])

    let old = session("old", finished: 9 * 3600)
    store.sessions = [a, b, old]
    store.togglePin(old)
    check("pins: a session from the rest area can be pinned too", Buckets(store, now: Date()).unread.map(\.id).contains("old"))

    store.togglePin(b)
    store.togglePin(b)
    check("pins: pinning twice takes the pin off again", !store.isUnread(b))

    store.sessions = [session("a", "busy"), b, old]
    store.unpinAnswered()
    check("pins: once the session is working again, its pin is gone", !store.pinned.contains("a"))
    check("pins: ...and the others keep theirs", store.pinned.contains("old"))
}

@MainActor func trailTests() {
    // Pets are 50 wide and 54 tall; the gaps between cards are 10, so a route runs 5 off a pet.
    func pet(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x, y: y, width: 50, height: 54) }
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    check(
        "route: pets in one column are joined through the gap on their left",
        Trail.corners(pet(16, 100), pet(16, 300), gap: 5) == [at(16, 127), at(11, 127), at(11, 327), at(16, 327)])
    check(
        "route: neighbours in one row are joined through the gap under the row",
        Trail.corners(pet(16, 100), pet(346, 100), gap: 5) == [at(41, 154), at(41, 159), at(341, 159), at(341, 127), at(346, 127)])
    check(
        "route: to a pet up and to the left it runs under its own row, then up beside the other's column",
        Trail.corners(pet(346, 300), pet(16, 100), gap: 5) == [at(371, 354), at(371, 359), at(11, 359), at(11, 127), at(16, 127)])

    // 5 + 200 + 5 long: halfway is 100 down the long stretch, heading down the board.
    let column = Trail.halfway(Trail.corners(pet(16, 100), pet(16, 300), gap: 5))
    check("route: the parked plane sits halfway, on the long stretch", column.point == at(11, 227))
    check("route: ...with its nose the way the message went", abs(column.heading - .pi / 2) < 0.001)
    // 5 + 300 + 32 + 5 long: halfway is 166 along the stretch under the row.
    let row = Trail.halfway(Trail.corners(pet(16, 100), pet(346, 100), gap: 5))
    check("route: under a row the parked plane points along the row", row.point == at(207, 159) && abs(row.heading) < 0.001)

    let direct = Trail.direct(pet(0, 0), pet(400, 0))
    check("route: the straight fallback stops at the pets' edges", direct == [at(50, 27), at(400, 27)])
    check("route: ...unless they are too close to leave a gap", Trail.direct(pet(0, 0), pet(40, 0)) == [at(25, 27), at(65, 27)])
}

@MainActor func linkTests() {
    let store = Store()
    store.sessions = [session("A"), session("B"), session("C")]
    func message(to peer: String, minute: Int) -> LinkScanner.Message {
        LinkScanner.Message(peer: peer, at: "2026-10-05T07:0\(minute):00.000Z", note: "", address: nil)
    }
    store.applyLinks([
        "A": LinkScanner.Record(offset: 0, sent: [message(to: "B", minute: 0)], received: []),
        "B": LinkScanner.Record(offset: 0, sent: [message(to: "A", minute: 5), message(to: "C", minute: 1)], received: []),
    ])
    func link(_ from: String, _ to: String) -> Peer? { store.peers[from]?.first(where: { $0.id == to }) }
    check("links: B answered A last, so on A's card the latest message came in", link("A", "B")?.outgoing == false)
    check("links: ...and on B's card it went out", link("B", "A")?.outgoing == true)
    check("links: a message nobody answered runs from its sender", link("B", "C")?.outgoing == true && link("C", "B")?.outgoing == false)

    let now = Date()
    check("links: talk from nine minutes ago is still going on", Peer(id: "x", last: now.addingTimeInterval(-540)).isRecent(now))
    check("links: talk from eleven minutes ago is over", !Peer(id: "x", last: now.addingTimeInterval(-660)).isRecent(now))
}

/// A snapshot's store only looks at the board. (Saving from one once reshuffled every pet.)
@MainActor func readOnlyTests() {
    let a = session("viewer-a")
    let viewer = Store()
    viewer.readOnly = true
    viewer.sessions = [a]
    Pets.shared.refresh(force: true)
    viewer.assignPets()
    check("read-only: every session still gets a pet to draw", viewer.petBySession[a.id] != nil)
    check(
        "read-only: ...but who got which is not saved",
        UserDefaults.standard.dictionary(forKey: "petBySession")?[a.id] == nil)
    viewer.togglePin(a)
    check("read-only: a pin made while only looking is not saved", !Store().pinned.contains(a.id))
}

/// The pet stays with the Orca pane a session runs in: /clear starts a new session, with a new id, in the same pane, and it
/// keeps the pane's pet. Each fixture is a process of its own here; `panes` is what reading its environment found, by pid:
/// its pane, "" for none, nothing while the read is still under way.
@MainActor func officePaneTests() {
    Pets.shared.refresh(force: true)
    let pool = Pets.shared.ids
    guard pool.count >= 6 else {
        print("      NOT CHECKED (panes): fewer than 6 pets in the pool")
        return
    }
    let defaults = UserDefaults.standard
    func forget() { for key in ["petByPane", "petByPaneOrder", "favoritePets", "petByName", "petByNameOrder"] { defaults.removeObject(forKey: key) } }
    forget()
    // The checks after these count the pets a new store reads back: leave them what was there.
    let dealtBefore = defaults.dictionary(forKey: "petBySession")
    defer {
        forget()
        defaults.set(dealtBefore, forKey: "petBySession")
    }
    var panes: [Int32: String] = [:]
    func store(readOnly: Bool = false) -> Store {
        let store = Store()
        store.readOnly = readOnly
        store.paneOf = { panes[$0] }
        return store
    }
    func open(_ id: String, _ pid: Int32, kind: String = "claude") -> Session {
        var s = Session(id: id, pid: pid, project: "项目", name: id, status: "idle", since: Date() - 600, summary: "")
        s.kind = kind
        return s
    }
    /// Deals with these pets drawn first: a check that steers a draw off the pane's pet fails if the pet is drawn, not kept.
    func favouring(_ pets: [String?], _ deal: () -> Void) {
        defaults.set(pets.compactMap { $0 }, forKey: "favoritePets")
        deal()
        defaults.removeObject(forKey: "favoritePets")
    }
    func except(_ pet: String?) -> [String?] { pool.filter { $0 != pet } }

    OrcaTabs.shared.learn(99_000_001, terminal: "term-x", pane: "tab-9:leaf-2")
    check(
        "office: Orca's lookup gives a process's pane once its environment is read, \"\" for one not from Orca, nothing before",
        OrcaTabs.shared.pane(of: 99_000_001) == "tab-9:leaf-2" && OrcaTabs.shared.pane(of: 1) == ""
            && OrcaTabs.shared.pane(of: 99_000_002) == nil && Store().paneOf(99_000_001) == "tab-9:leaf-2")

    // At most 400 panes are kept. A read-only store, so that nothing is written on the way.
    let many = store(readOnly: true)
    panes[150] = "keep"
    for i in 0..<400 { panes[Int32(3000 + i)] = "pane-\(i)" }
    many.sessions = [open("keep", 150)]
    many.assignPets()
    for i in 0..<400 {
        many.sessions = [open("keep", 150), open("visit-\(i)", Int32(3000 + i))]
        many.assignPets()
    }
    check(
        "office: at most 400 panes keep their pet; over that, the one noted first goes",
        many.petByPane.count == 400 && many.petByPane["pane-0"] == nil && many.petByPane["pane-1"] != nil
            && many.petByPane["pane-399"] == many.petBySession["visit-399"])
    check("office: ...but never the pane of a session still open, however long ago it was noted", many.petByPane["keep"] != nil)

    // /clear: the same process starts a new session, with a new id, in the same pane.
    let p = "tab-1:leaf-1"
    panes[101] = p
    let clear = store()
    clear.sessions = [open("pane-a", 101)]
    clear.assignPets()
    let x = clear.petBySession["pane-a"]
    favouring(except(x)) {
        clear.sessions = [open("pane-b", 101)]
        clear.assignPets()
    }
    check("office: after /clear the new session in the same Orca pane keeps the pane's pet", x != nil && clear.petBySession["pane-b"] == x)
    check("office: ...and the pane remembers it", clear.petByPane[p] == x)
    // Claude Code quit and started again in that pane: another process, the same pane.
    panes[102] = p
    favouring(except(x)) {
        clear.sessions = [open("pane-c", 102)]
        clear.assignPets()
    }
    check("office: a new process in the same pane takes the pane's pet over too", x != nil && clear.petBySession["pane-c"] == x)
    panes[103] = p
    favouring(except(x)) {
        clear.sessions = [open("pane-d", 103, kind: "codex")]
        clear.assignPets()
    }
    check("office: so does a Codex session started in that pane", x != nil && clear.petBySession["pane-d"] == x)

    // Two sessions in one pane at once does not happen, but must not break the rule.
    panes[104] = p
    clear.sessions = [open("pane-d", 103, kind: "codex"), open("pane-e", 104)]
    clear.assignPets()
    let e = clear.petBySession["pane-e"]
    check(
        "office: a second session in a pane whose session is still open gets a pet of its own",
        x != nil && e != nil && e != x && clear.petBySession["pane-d"] == x)
    check("office: ...and the pane's pet stays with the one that had it", clear.petByPane[p] == x)
    clear.sessions = [open("pane-e", 104), open("pane-d", 103, kind: "codex")]
    clear.assignPets()
    check(
        "office: ...on the next round too, in either order: nobody's pet changes",
        e != nil && clear.petBySession["pane-e"] == e && clear.petBySession["pane-d"] == x && clear.petByPane[p] == x)
    // The session from before the /clear resumed in another pane: it still has the pet by its id, as does the one now in
    // the old pane. Its id sorts first.
    panes[107] = "tab-2:leaf-9"
    clear.sessions = [open("pane-a", 107), open("pane-d", 103, kind: "codex")]
    clear.assignPets()
    check(
        "office: an old session resumed in another pane does not take the pet from the session now in its old pane",
        x != nil && clear.petBySession["pane-d"] == x && clear.petBySession["pane-a"] != x && clear.petBySession["pane-a"] != nil
            && clear.petByPane[p] == x && clear.petByPane["tab-2:leaf-9"] == clear.petBySession["pane-a"])

    // Not started from Orca: as before.
    panes[105] = ""
    let noted = clear.petByPane
    clear.sessions = [open("pane-none", 105)]
    clear.assignPets()
    check(
        "office: a session not started from Orca draws its pet at once, and no pane is noted for it",
        clear.petBySession["pane-none"] != nil && !noted.isEmpty && clear.petByPane == noted)

    // The panes' pets are kept across a restart.
    let restarted = store()
    check(
        "office: the panes' pets are kept across a restart",
        !clear.petByPane.isEmpty && restarted.petByPane == clear.petByPane
            && defaults.stringArray(forKey: "petByPaneOrder")?.contains(p) == true)
    panes[106] = p
    favouring(except(x)) {
        restarted.sessions = [open("pane-f", 106)]
        restarted.assignPets()
    }
    check("office: ...so /clear after a restart keeps the pane's pet too", x != nil && restarted.petBySession["pane-f"] == x)

    // The pane's pet drawn by another pane's session while its own pane stood empty.
    let r = "tab-3:leaf-1", t = "tab-4:leaf-1"
    panes[111] = r
    panes[112] = t
    panes[113] = r
    let taken = store()
    taken.sessions = [open("taken-a", 111)]
    taken.assignPets()
    let y = taken.petBySession["taken-a"]
    favouring([y]) {
        taken.sessions = [open("taken-c", 112)]
        taken.assignPets()
        taken.sessions = [open("taken-c", 112), open("taken-b", 113)]
        taken.assignPets()
    }
    let b = taken.petBySession["taken-b"]
    check(
        "office: a pane whose pet another pane's session has taken meanwhile draws a new one, and notes it",
        y != nil && taken.petBySession["taken-c"] == y && b != nil && b != y && taken.petByPane[r] == b
            && taken.petByPane[t] == y)

    // Every pet in the pool taken.
    let u = "tab-5:leaf-1", v = "tab-6:leaf-1"
    panes[121] = u
    panes[122] = v
    panes[123] = u
    let fillers = (0..<pool.count - 1).map { open("fill-\($0)", 2000 + Int32($0)) }
    for s in fillers { panes[s.pid] = "" }
    let full = store(readOnly: true)
    full.sessions = [open("full-a", 121)]
    full.assignPets()
    let z = full.petBySession["full-a"]
    favouring(except(z)) {
        full.sessions = fillers
        full.assignPets()
    }
    favouring([z]) {
        full.sessions = fillers + [open("full-c", 122)]
        full.assignPets()
    }
    let before = full.petBySession
    full.sessions = fillers + [open("full-c", 122), open("full-b", 123)]
    full.assignPets()
    let last = full.petBySession["full-b"]
    check(
        "office: with every pet taken, a newcomer to a pane whose pet another pane's session has still gets one, and the pane notes it",
        z != nil && full.petBySession["full-c"] == z && last != nil && full.petByPane[u] == last)
    check(
        "office: ...and nobody already in the room loses theirs to it",
        (fillers.map(\.id) + ["full-c"]).allSatisfy { before[$0] != nil && full.petBySession[$0] == before[$0] })

    // The lookup of a new process's pane is under way: no pet is drawn for it until it is known.
    let w = "tab-7:leaf-1"
    panes[131] = w
    panes[133] = ""
    let waiting = store()
    waiting.sessions = [open("wait-a", 131)]
    waiting.assignPets()
    let pet = waiting.petBySession["wait-a"]
    favouring(except(pet)) {
        waiting.sessions = [open("wait-b", 132), open("wait-n", 133)]
        waiting.assignPets()
    }
    let early = waiting.petBySession["wait-b"]
    panes[132] = w
    favouring(except(pet)) { waiting.assignPets() }
    check(
        "office: a new session waits, with no pet, while its pane is still being looked up; the others are dealt as usual",
        pet != nil && early == nil && waiting.petBySession["wait-n"] != nil)
    check(
        "office: ...and once the pane is known it has the pane's pet, never another one first",
        pet != nil && waiting.petBySession["wait-b"] == pet)
    waiting.sessions = [open("wait-b", 132), open("slow", 134)]
    var rounds: [Bool] = []
    for _ in 0..<4 {
        waiting.assignPets()
        rounds.append(waiting.petBySession["slow"] != nil)
    }
    check(
        "office: a lookup that never ends holds a new session's pet back three rounds at most, then it draws as before",
        rounds == [false, false, false, true])
    panes[132] = nil
    let relaunched = store()
    relaunched.sessions = [open("wait-b", 132)]
    relaunched.assignPets()
    check(
        "office: a session that has its pet shows it at once while its pane is still being looked up (the panel just started)",
        pet != nil && relaunched.petBySession["wait-b"] == pet)

    // A snapshot: nothing to wait for, nothing written.
    let still = store(readOnly: true)
    still.sessions = [open("still-a", 141)]
    still.assignPets()
    check("office: a snapshot waits for no lookup: every session has a pet to draw", still.petBySession["still-a"] != nil)
    let s = "tab-8:leaf-1"
    panes[142] = s
    let savedPanes = defaults.dictionary(forKey: "petByPane") as NSDictionary?
    let savedOrder = defaults.stringArray(forKey: "petByPaneOrder")
    let savedPets = defaults.dictionary(forKey: "petBySession") as NSDictionary?
    still.sessions = [open("still-b", 142)]
    still.assignPets()
    check(
        "office: a snapshot notes a pane's pet for itself, but writes neither map nor the panes' order",
        still.petByPane[s] != nil && still.petByPane[s] == still.petBySession["still-b"] && savedPanes != nil
            && defaults.dictionary(forKey: "petByPane") as NSDictionary? == savedPanes
            && defaults.stringArray(forKey: "petByPaneOrder") == savedOrder
            && defaults.dictionary(forKey: "petBySession") as NSDictionary? == savedPets)

    // ── window swap (/window) ends a session and opens one with the same name, a new id and usually a new pane ──
    func named(_ id: String, _ pid: Int32, _ name: String) -> Session {
        var made = open(id, pid)
        made.registryName = name
        return made
    }
    let q1 = "tab-20:leaf-1", q2 = "tab-21:leaf-1", q3 = "tab-22:leaf-1"
    panes[201] = q1
    panes[202] = q2
    panes[203] = q3
    panes[204] = ""
    panes[206] = ""
    panes[207] = q3
    panes[208] = ""
    let win = store()
    win.sessions = [named("win-a", 201, "Home-星星")]
    win.assignPets()
    let mine = win.petBySession["win-a"]
    // Pane q2 last held another session's pet: window swap opens the new one there.
    favouring(except(mine)) {
        win.sessions = [open("prev-q2", 202)]
        win.assignPets()
    }
    let other = win.petByPane[q2]
    favouring(except(mine)) {
        win.sessions = [named("win-b", 202, "Home-星星")]
        win.assignPets()
    }
    check("pets: after window swap (same name, new id, a new pane that held another pet) the session takes its name's pet back",
        mine != nil && other != nil && other != mine && win.petBySession["win-b"] == mine && win.petByName["Home-星星"] == mine)
    favouring(except(mine)) {
        win.sessions = [named("win-c", 204, "Home-星星")]
        win.assignPets()
    }
    check("pets: ...so does one opened outside Orca (no pane)", win.petBySession["win-c"] == mine)
    favouring(except(mine)) {
        win.sessions = [named("win-d", 205, "Home-星星")]
        win.assignPets()
    }
    check("pets: ...and one whose pane is still being looked up has it at once (no waiting round)", win.petBySession["win-d"] == mine)
    favouring([mine]) {
        win.sessions = [named("win-d", 205, "Home-星星"), named("win-e", 206, "Home-星星")]
        win.assignPets()
    }
    check("pets: a second open session with the same name does not take the pet the first holds; it draws its own",
        win.petBySession["win-d"] == mine && win.petBySession["win-e"] != nil && win.petBySession["win-e"] != mine && win.petByName["Home-星星"] == mine)
    // off-duty rule: while a session is off duty (in the roster, gone from the registry) nobody draws its pet, and
    // woken it has it back.
    panes[209] = ""
    panes[210] = ""
    let rosterBefore = ZoneRosterFile.path
    let rosterPath = NSTemporaryDirectory() + "pets-roster-\(getpid()).json"
    ZoneRosterFile.path = rosterPath
    ZoneRosterFile.reset()
    win.sessions = [named("off-a", 209, "Web-离开")]
    win.assignPets()
    let away = win.petBySession["off-a"]
    try? #"{"Web-离开": {"cwd": "/tmp", "sid": "off-a", "lastActive": 1, "offAt": 2, "zone": "Web"}}"#
        .write(toFile: rosterPath, atomically: true, encoding: .utf8)
    favouring(away.map { [$0] } ?? []) {
        win.sessions = [open("new-x", 210)]
        win.assignPets()
    }
    check("pets: an off-duty session's pet is not drawn by a new one while it is away",
        away != nil && win.petBySession["new-x"] != nil && win.petBySession["new-x"] != away)
    try? "{}".write(toFile: rosterPath, atomically: true, encoding: .utf8)
    win.sessions = [open("new-x", 210), named("off-a", 209, "Web-离开")]
    win.assignPets()
    check("pets: ...and woken it has the same pet", win.petBySession["off-a"] == away)
    try? FileManager.default.removeItem(atPath: rosterPath)
    ZoneRosterFile.path = rosterBefore
    ZoneRosterFile.reset()
    win.sessions = [named("clr-a", 203, "Ops-x")]
    win.assignPets()
    let cleared = win.petBySession["clr-a"]
    favouring(except(cleared)) {
        win.sessions = [open("clr-b", 207)]
        win.assignPets()
    }
    check("pets: /clear in the same pane keeps the pane's pet as before (no name needed)", cleared != nil && win.petBySession["clr-b"] == cleared)
    let back = store()
    favouring(except(mine)) {
        back.sessions = [named("win-f", 208, "Home-星星")]
        back.assignPets()
    }
    check("pets: the names' pets are kept across a restart, in their own settings",
        back.petBySession["win-f"] == mine && (defaults.dictionary(forKey: "petByName") as? [String: String])?["Home-星星"] == mine
            && defaults.stringArray(forKey: "petByNameOrder")?.contains("Home-星星") == true)
    let crowdOfNames = store(readOnly: true)
    for i in 0..<401 {
        panes[Int32(6000 + i)] = ""
        crowdOfNames.sessions = [named("nm-\(i)", Int32(6000 + i), "名-\(i)")]
        crowdOfNames.assignPets()
    }
    check("pets: at most 400 names keep their pet; over that, the one noted first goes, never an open one",
        crowdOfNames.petByName.count == 400 && crowdOfNames.petByName["名-400"] != nil && crowdOfNames.petByName["Home-星星"] == nil
            && (defaults.dictionary(forKey: "petByName") as? [String: String])?["名-400"] == nil)

    // Reshuffle Pets forgets both maps.
    let dealing = store()
    dealing.sessions = [open("deal-a", 101)]
    dealing.assignPets()
    let held = dealing.petByPane.count
    dealing.redealPets()
    check(
        "office: dealing the pets out again forgets the panes' pets too: only the open session's pane is noted again",
        held > 1 && Set(dealing.petByPane.keys) == [p] && Set((defaults.dictionary(forKey: "petByPane") ?? [:]).keys) == [p]
            && dealing.petByPane[p] == dealing.petBySession["deal-a"])
    check("pets: Reshuffle Pets forgets the names' pets too", dealing.petByName.isEmpty && (defaults.dictionary(forKey: "petByName") ?? [:]).isEmpty)
}

/// Right-click → Change Pet / Never Use This Pet, and the menubar's Restore Banned Pets. The shared pool only (board, office, the sea room); a
/// scene's own cast is its own and must not move (an extension's checks).
@MainActor func petChangeTests() {
    Pets.shared.refresh(force: true)
    let pool = Pets.shared.ids
    guard pool.count >= 8 else {
        skipped("fewer than 8 pets in the pool", "pets: Change Pet and Never Use This Pet")
        return
    }
    let defaults = UserDefaults.standard
    let keys = ["petBySession", "petByPane", "petByPaneOrder", "favoritePets", "petByName", "petByNameOrder", "bannedPets"]
    let kept = keys.map { defaults.object(forKey: $0) }
    func forget() { for key in keys { defaults.removeObject(forKey: key) } }
    forget()
    defer { for (key, value) in zip(keys, kept) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    let panes: [Int32: String] = [701: "tab-70:leaf-1", 702: "tab-71:leaf-1", 703: "tab-72:leaf-1", 704: "tab-73:leaf-1", 705: ""]
    func store() -> Store {
        let store = Store()
        store.paneOf = { panes[$0] }
        return store
    }
    func named(_ id: String, _ pid: Int32, _ name: String) -> Session {
        var s = Session(id: id, pid: pid, project: "项目", name: name, status: "idle", since: Date() - 600, summary: "")
        s.registryName = name
        return s
    }
    let a = named("swap-a", 701, "Home-Alpha"), b = named("swap-b", 702, "Ops-Bravo"), c = named("swap-c", 703, "Web-Charlie")
    let main = store()
    main.sessions = [a, b, c]
    main.assignPets()
    let first = main.petBySession[a.id]
    let others = Set([b, c].compactMap { main.petBySession[$0.id] })
    main.bannedPets = [pool.first { $0 != first && !others.contains($0) } ?? ""]
    let free = main.freePets(for: a)
    check("pets: the free pets are the pool less the banned, those the other open sessions hold, and its own",
        first != nil && others.count == 2 && !free.isEmpty && Set(free) == Set(pool).subtracting(others).subtracting(main.bannedPets).subtracting([first ?? ""]))
    main.bannedPets = []
    // Many changes in a row: never one held, banned or the current one; more than one pet comes up (random).
    var picks = Set<String>(), bad = 0, previous = first
    for _ in 0..<30 {
        guard let pick = main.changePet(a) else { bad += 1; continue }
        if pick == previous || others.contains(pick) { bad += 1 }
        picks.insert(pick)
        previous = pick
    }
    check("pets: Change Pet picks a random pet nobody else holds, never the current one (30 changes)", bad == 0 && picks.count >= 3)
    let mine = main.petBySession[a.id]
    main.assignPets()
    main.assignPets()
    check("pets: the change holds through the next assignPets rounds, and is remembered by id, pane and name, on disk too",
        mine != nil && main.petBySession[a.id] == mine && main.petByPane["tab-70:leaf-1"] == mine && main.petByName["Home-Alpha"] == mine
            && (defaults.dictionary(forKey: "petBySession") as? [String: String])?[a.id] == mine
            && (defaults.dictionary(forKey: "petByPane") as? [String: String])?["tab-70:leaf-1"] == mine
            && (defaults.dictionary(forKey: "petByName") as? [String: String])?["Home-Alpha"] == mine)
    // window swap: the same name in a new pane, a new id.
    let reopened = store()
    reopened.sessions = [named("swap-a2", 704, "Home-Alpha"), b, c]
    reopened.assignPets()
    check("pets: after a restart and window swap (same name, new id and pane) it has the pet it changed to", reopened.petBySession["swap-a2"] == mine)

    // Never Use This Pet.
    let held = main.petBySession[b.id]
    let after = main.banPet(b)
    check("pets: Never Use This Pet bans the pet (on disk) and gives the session another free one",
        held != nil && main.bannedPets == [held!] && defaults.stringArray(forKey: "bannedPets") == [held!] && after != nil && after != held
            && main.petBySession[b.id] == after && !others.subtracting([held!]).contains(after!) && after != main.petBySession[a.id])
    // A holder of a banned pet gets a new one on the next round; no new session is dealt one.
    let ban = main.petBySession[c.id]!
    main.bannedPets.append(ban)
    main.assignPets()
    let crowd = store()
    crowd.bannedPets = main.bannedPets
    crowd.sessions = (0..<min(pool.count - 3, 30)).map { named("swap-n\($0)", 705, "名\($0)") }
    for _ in 0..<4 { crowd.assignPets() }
    let dealt = crowd.sessions.compactMap { crowd.petBySession[$0.id] }
    check("pets: a session holding a banned pet gets another on the next round, and no session is ever dealt a banned one",
        main.petBySession[c.id] != nil && main.petBySession[c.id] != ban && dealt.count == crowd.sessions.count
            && dealt.allSatisfy { !main.bannedPets.contains($0) })
    // Also by name: a name that last had a banned pet does not take it back.
    let banned = store()
    banned.bannedPets = [mine!]
    banned.sessions = [named("swap-a3", 705, "Home-Alpha")]
    banned.assignPets()
    check("pets: a name whose pet was banned since does not take it back", banned.petBySession["swap-a3"] != nil && banned.petBySession["swap-a3"] != mine)

    // Nothing free: both lines greyed (no change, no ban without something to change to).
    let wasOffice = defaults.object(forKey: "office"), wasTheme = defaults.object(forKey: "officeTheme")
    defer {
        for (key, value) in [("office", wasOffice), ("officeTheme", wasTheme)] {
            if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }
    func lines(_ store: Store, _ s: Session, mode: String?) -> [String: Bool] {
        defaults.set(mode != nil, forKey: "office")
        if let mode { defaults.set(mode, forKey: "officeTheme") }
        var result: [String: Bool] = [:]
        for line in sessionMenu(store, s) where line.action == .changePet || line.action == .banPet { result[line.title] = line.enabled }
        return result
    }
    let zoneLines = lines(main, a, mode: OfficeTheme.zone.name), officeLines = lines(main, a, mode: OfficeTheme.studio.name)
    let boardLines = lines(main, a, mode: nil)
    check("pets: the right-click menu has Change Pet and Never Use This Pet in the sea room and office (one menu), not on the board",
        zoneLines == ["换个角色": true, "以后不用这个角色": true] && officeLines == zoneLines && boardLines.isEmpty)
    let full = main.bannedPets
    main.bannedPets = pool.filter { pet in !main.sessions.contains { main.petBySession[$0.id] == pet } }
    let none = main.freePets(for: a).isEmpty, greyed = lines(main, a, mode: OfficeTheme.zone.name)
    let unchanged = main.petBySession[a.id], tried = main.changePet(a)
    check("pets: with no pet free both lines are greyed, and a change does nothing",
        none && greyed == ["换个角色": false, "以后不用这个角色": false] && tried == nil && main.petBySession[a.id] == unchanged)
    main.bannedPets = full

    // Reshuffle Pets keeps the bans; Restore Banned Pets clears them.
    let bans = main.bannedPets
    main.redealPets()
    let redealt = main.bannedPets
    main.unbanPets()
    check("pets: Reshuffle Pets keeps the ban list; Restore Banned Pets (N) clears it, on disk too",
        !bans.isEmpty && redealt == bans && main.bannedPets.isEmpty && (defaults.stringArray(forKey: "bannedPets") ?? []).isEmpty
            && unbanMenuTitle(3) == "恢复拉黑的角色（3）")
}

/// The planes are moved by Core Animation, which no snapshot shows. Put the real view in a
/// window off the screen, let it fly, and ask the layer twice where the plane is: after
/// 0.45 s and after 0.95 s, in the board's coordinates.
@MainActor func watchPlane<V: View>(in view: V) -> [(at: CGPoint, opacity: Float)?] {
    NSApplication.shared.setActivationPolicy(.accessory)
    let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 600), styleMask: .borderless, backing: .buffered,
        defer: false)
    window.contentView = NSHostingView(rootView: view.frame(width: 400, height: 600))
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }

    func plane(under view: NSView?) -> (at: CGPoint, opacity: Float)? {
        guard let view else { return nil }
        if let layer = view.layer?.sublayers?.first(where: { $0.name == "plane" })?.presentation() {
            return (view.convertFromLayer(layer.position), layer.opacity)
        }
        return view.subviews.lazy.compactMap { plane(under: $0) }.first
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.45))
    let early = plane(under: window.contentView)
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let later = plane(under: window.contentView)
    print("      plane at \(early.map { "\($0.at)" } ?? "nowhere"), then at \(later.map { "\($0.at)" } ?? "nowhere")")
    return [early, later]
}

@MainActor func flightTests() {
    // Down the gap left of a column, top pet to bottom pet. 410 long, so both kinds of flight
    // are on the long stretch at both looks.
    let route = [CGPoint(x: 16, y: 127), CGPoint(x: 11, y: 127), CGPoint(x: 11, y: 527), CGPoint(x: 16, y: 527)]
    func checks(_ kind: String, _ seen: [(at: CGPoint, opacity: Float)?]) {
        let early = seen[0], later = seen[1]
        check("\(kind): a plane is in the air", early != nil && later != nil && (early?.opacity ?? 0) > 0.5)
        check(
            "\(kind): it keeps to the gap its route runs through",
            seen.allSatisfy { p in p.map { abs($0.at.x - 11) < 1.5 && $0.at.y > 127 && $0.at.y < 527 } ?? false })
        check("\(kind): it flies from the sender toward the receiver", (later?.at.y ?? 0) > (early?.at.y ?? .infinity) + 20)
    }
    checks("hover flight", watchPlane(in: PlaneLoops(routes: [route], radius: 4, size: 13)))
    checks("message flight", watchPlane(in: FlightLayer(trips: [FlightLayer.Trip(id: UUID(), corners: route)], z: 1)))
}

/// The office view's rules: who is in the room, where each one stands, how large.
@MainActor func officeTests() {
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    func office(_ waiting: Int, _ unread: Int, _ busy: Int, _ seen: Int, _ resting: Int) -> OfficeLayout {
        OfficeLayout(
            waiting: ids("w", waiting), unread: ids("u", unread), busy: ids("b", busy), seen: ids("s", seen),
            resting: ids("r", resting))
    }
    func zone(_ layout: OfficeLayout, _ zone: OfficeLayout.Zone) -> [OfficeLayout.Pet] { layout.pets.filter { $0.zone == zone } }

    let usual = office(2, 5, 4, 9, 10)
    check("office: thirty sessions all fit in the room", usual.pets.count == 30 && usual.behindDoor == 0)
    let two = office(2, 5, 4, 9, 12)
    check("office: the thirty-first and after wait behind the door", two.pets.count == 30 && two.behindDoor == 2)
    let crowd = office(1, 0, 0, 0, 100)
    check(
        "office: a session waiting for you is in the room however many are resting",
        crowd.pets.contains { $0.id == "w0" && $0.zone == .queue })

    let seven = zone(office(7, 0, 0, 0, 0), .queue), nine = office(9, 0, 0, 0, 0)
    check("office: one to seven waiting stand in the queue along the bottom, as tall as at a desk", seven.count == 7 && seven.allSatisfy { $0.tall == 70 })
    check(
        "office: the queue holds seven, always 70 tall; the eighth and ninth wait seated, flagged, none behind the door",
        zone(nine, .queue).count == 7 && zone(nine, .queue).allSatisfy { $0.tall == 70 } && nine.pets.filter(\.flagged).map(\.id) == ["w7", "w8"]
            && nine.behindDoor == 0 && nine.waitingElsewhere == ["w7", "w8"])
    func xs(_ pets: [OfficeLayout.Pet]) -> [CGFloat] { pets.sorted { $0.seat < $1.seat }.map(\.x) }
    check(
        "office: the waiting stand in fixed places 125 apart from your desk's right, on the bottom edge, however many there are",
        xs(zone(office(2, 0, 0, 0, 0), .queue)) == [244, 369] && xs(seven) == [244, 369, 494, 619, 744, 869, 994]
            && office(7, 0, 0, 0, 0).pets.allSatisfy { $0.foot == 758 })

    check(
        "office: with news they sit on the sofas in the band over the queue",
        zone(usual, .sofa).count == 5 && zone(usual, .sofa).allSatisfy { $0.foot == 565 })
    let twelve = zone(office(0, 12, 0, 0, 0), .sofa)
    check(
        "office: four sofas seat twelve, three a sofa, filled left to right",
        xs(twelve) == [92, 167, 242, 379, 454, 529, 666, 741, 816, 953, 1028, 1103] && twelve.allSatisfy { $0.foot == 565 && $0.tall == 70 })
    let thirteen = office(0, 13, 0, 0, 0)
    check(
        "office: the thirteenth with news takes a desk",
        zone(thirteen, .sofa).count == 12 && zone(thirteen, .desk).map(\.id) == ["u12"] && thirteen.behindDoor == 0)
    let today = office(0, 16, 2, 0, 15)
    check(
        "office: with 16 with news, 2 at work and 15 resting, nobody with news is behind the door",
        today.pets.count == 30 && !today.behindDoorIDs.isEmpty && !today.behindDoorIDs.contains { $0.hasPrefix("u") })
    let newsFirst = office(0, 28, 1, 1, 0)
    check(
        "office: news has first right to a desk; then those at work and looked at sit at the back, awake, nobody behind the door",
        newsFirst.behindDoor == 0 && zone(newsFirst, .desk).count == 16 && Set(zone(newsFirst, .lounge).map(\.id)) == ["b0", "s0"]
            && zone(newsFirst, .lounge).allSatisfy { !$0.asleep })
    check("office: with seven waiting, twelve with news sit on the sofas", zone(office(7, 12, 0, 0, 0), .sofa).count == 12)
    let eightWaiting = office(8, 12, 0, 0, 0)
    check(
        "office: with eight waiting the sofas are still those with news",
        Set(zone(eightWaiting, .sofa).map(\.id)) == Set(ids("u", 12)) && zone(eightWaiting, .queue).count == 7)
    let mixed = zone(office(0, 14, 2, 3, 0), .desk).sorted { $0.seat < $1.seat }.map(\.id)
    check(
        "office: from the aisle outward: at work, then with news, then looked at",
        mixed == ["b0", "b1", "u12", "u13", "s0", "s1", "s2"])

    let desks = zone(usual, .desk)
    check(
        "office: at work or looked at, they are at the desks",
        Set(desks.map(\.id)) == Set(ids("b", 4) + ids("s", 9)))
    check("office: the ones at work take the first desks", Set(desks.sorted { $0.seat < $1.seat }.prefix(4).map(\.id)) == Set(ids("b", 4)))
    let full = office(0, 0, 10, 10, 0)
    check("office: sixteen desks, in two rows of eight", zone(full, .desk).count == 16 && Set(zone(full, .desk).map(\.foot)) == [320, 442])
    check("office: looked at and without a desk, they sit at the back", full.behindDoor == 0 && zone(full, .lounge).count == 4)

    check("office: only the resting are at the back, asleep", zone(usual, .lounge).count == 10 && zone(usual, .lounge).allSatisfy(\.asleep))
    let awake = usual.pets.filter { $0.zone != .lounge }
    check("office: nobody awake is drawn asleep", awake.count == 20 && awake.allSatisfy { !$0.asleep })
    let ten = zone(office(0, 0, 0, 0, 10), .lounge)
    check("office: ten at the back sit in the first row", ten.count == 10 && ten.allSatisfy { $0.foot == 129 })
    let eleven = zone(office(0, 0, 0, 0, 11), .lounge)
    check("office: the eleventh starts the second row", eleven.count == 11 && Set(eleven.map(\.foot)) == [129, 213])
    check("office: the back seats twenty", zone(office(0, 0, 0, 0, 30), .lounge).count == 20 && office(0, 0, 0, 0, 30).behindDoor == 10)
    let row = xs(zone(office(0, 0, 0, 0, 10), .lounge))
    check(
        "office: at the back they sit 102 apart or more, five a couch, so a 96-wide name leaves a gap",
        row == [106, 208, 310, 412, 514, 680, 782, 884, 986, 1088])

    let packed = office(6, 6, 8, 8, 10)
    let room = CGRect(origin: .zero, size: packed.size)
    check(
        "office: everyone and their words are inside the 1194x764 room",
        packed.size == CGSize(width: 1194, height: 764) && !packed.pets.isEmpty && packed.pets.allSatisfy { room.contains($0.frame) }
            && packed.pets.allSatisfy { $0.frame.contains($0.words) && $0.frame.contains($0.body) })
    let apart = packed.pets.allSatisfy { a in
        packed.pets.allSatisfy { b in a.id == b.id || a.foot != b.foot || abs(a.x - b.x) >= 40 }
    }
    check("office: no two stand on the same spot", packed.pets.count == 30 && apart)
    check(
        "office: pointing at a pet finds its session",
        !usual.pets.isEmpty && usual.pets.allSatisfy { usual.session(at: CGPoint(x: $0.x, y: $0.foot - $0.tall / 2)) == $0.id })
    check("office: pointing at the floor finds nobody", usual.session(at: CGPoint(x: 600, y: 300)) == nil)

    // Words are where the painter writes them; pointing at them counts.
    let busy = office(3, 8, 3, 3, 13)
    let words = busy.pets.allSatisfy { pet in
        busy.session(at: officeNameSpot(pet, busy)) == pet.id && officeProjectSpot(pet).map { busy.session(at: $0) == pet.id } ?? true
    }
    check("office: the middle of every name, plate and card finds its session", busy.pets.count == 30 && words)
    check(
        "office: where a back-row name lies under the pet behind it, the one standing in front wins",
        office(0, 0, 0, 0, 20).session(at: CGPoint(x: 98, y: 159)) == "r10")
    check(
        "office: the ring goes round the body, the door, or nothing",
        busy.ring(for: "b0") == busy.pets.first { $0.id == "b0" }?.body && busy.ring(for: OfficeLayout.doorKey) == OfficeLayout.door
            && busy.ring(for: "nobody") == nil)
    check(
        "office: the door is 1000...1084 by 4...70",
        OfficeLayout.door == CGRect(x: 1000, y: 4, width: 84, height: 66))

    // The room as tall as the window lets it be: the back, the desks and your corner spread down.
    let low = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: [], height: 764)
    check(
        "office: at 764 high the bands stack as tight as their words allow, the queue on the bottom edge",
        low.queueFoot == 758 && low.sofaFloor == 569 && low.deskFloors == [310, 432] && low.loungeFloors == [132, 216] && low.rugTop == 608
            && office(3, 8, 3, 3, 13).pets == OfficeLayout(
                waiting: ids("w", 3), unread: ids("u", 8), busy: ids("b", 3), seen: ids("s", 3), resting: ids("r", 13), height: 764).pets)
    let tall = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: [], height: 979)
    check(
        "office: at 979 high the spare height is shared out between the bands, the queue still on the bottom edge",
        tall.loungeFloors == [165, 283] && tall.deskFloors == [410, 565] && tall.rugTop == 802 && tall.sofaFloor == 735
            && tall.queueFoot == 973 && tall.size == CGSize(width: 1194, height: 979))
    for (height, scale) in [(CGFloat(979), CGFloat(0.95)), (1000, 0.72)] {
        let grown = OfficeLayout(
            waiting: ids("w", 3), unread: ids("u", 6), busy: ids("b", 6), seen: ids("s", 4), resting: ids("r", 11), height: height, scale: scale)
        let at = "office \(Int(height)) high at \(scale)"
        let inside = CGRect(origin: .zero, size: grown.size)
        let spread = grown.pets.allSatisfy { a in
            grown.pets.allSatisfy { b in a.id == b.id || a.foot != b.foot || abs(a.x - b.x) >= 40 }
        }
        check("\(at): everyone and their words are inside, no two on one spot", grown.pets.count == 30 && spread
            && grown.pets.allSatisfy { inside.contains($0.frame) })
        let screens = grown.deskFloors[0] - 66
        check("\(at): every back-row name is above the first row of screens", zone(grown, .lounge).allSatisfy { $0.words.maxY < screens })
        let cards = zone(grown, .queue).map(\.words.minY).min() ?? 0
        let second = zone(grown, .desk).filter { $0.foot == grown.deskFloors[1] + 10 }
        check("\(at): the second desk row's words are above the waiting cards", !second.isEmpty && second.allSatisfy { $0.words.maxY < cards })
        let found = grown.pets.allSatisfy { pet in
            grown.session(at: CGPoint(x: pet.x, y: pet.foot - pet.tall / 2)) == pet.id && grown.session(at: officeNameSpot(pet, grown)) == pet.id
                && (officeProjectSpot(pet).map { grown.session(at: $0) == pet.id } ?? true)
        }
        check("\(at): pointing still finds every pet and every word", found)
    }

    // The waiting card: the name alone on its line, so it survives (every card is 116 wide).
    let sixSmall = OfficeLayout(waiting: ids("w", 3), unread: [], busy: [], seen: [], resting: [], height: 764, scale: 0.75)
    let card = sixSmall.pets[0].words
    let lines = OfficeLayout.cardLines(card, scale: 0.75, asks: sixSmall.asks)
    let nameWidth = OfficeCanvas(CGSize(width: 1, height: 1)).width(of: "云朵风车彩虹", size: OfficeLook.type(12.5, scale: 0.75))
    check(
        "office: at 75% a six-character name fits its 116-wide card uncut",
        card.width == 116 && nameWidth <= lines.name.width)
    let ordered = lines.second.minY >= lines.name.maxY && lines.ask.minY >= lines.second.maxY
    let askLine = OfficeLookHeight(10.5, 0.75)
    check(
        "office: ...under it the project and the wait, then one line of what it asks, all inside the card",
        sixSmall.asks == 1 && ordered && lines.ask.height >= askLine && lines.ask.maxY <= card.maxY)
    let few = OfficeLayout(waiting: ids("w", 3), unread: [], busy: [], seen: [], resting: [], height: 979, scale: 0.95)
    let fewLines = OfficeLayout.cardLines(few.pets[0].words, scale: 0.95, asks: few.asks)
    check(
        "office: with three waiting the card holds two lines of what it asks",
        few.asks == 2 && fewLines.ask.height >= 2 * OfficeLookHeight(10.5, 0.95) && fewLines.ask.maxY <= few.pets[0].words.maxY)
    check(
        "office: the card grows with its words",
        OfficeLayout.cardLines(.zero, scale: 0.75, asks: 1).ask.maxY > OfficeLayout.cardLines(.zero, scale: 1, asks: 1).ask.maxY)

    check("office: the one left outside is known by name", office(0, 0, 0, 0, 21).behindDoorIDs == ["r20"])
    check(
        "office: behind the door only the looked-at and the resting, the looked-at first",
        office(0, 0, 0, 40, 5).behindDoorIDs == Array(ids("s", 40).suffix(10)) + ids("r", 5) && office(7, 17, 0, 0, 0).behindDoor == 0)
    check("office: nobody behind the door, nobody listed", usual.behindDoorIDs.isEmpty)
    let outside = office(1, 0, 0, 0, 25)
    check(
        "office: pointing at a session behind the door points at the door",
        outside.pointed(at: "r24") == OfficeLayout.doorKey && outside.pointed(at: "w0") == "w0" && outside.pointed(at: "nobody") == nil)
}

/// Everything the office view shows, in words: the room's inputs, and each pet's place, sprite and
/// words. The checks from before the room was split into pieces describe what is drawn with it.
extension OfficeView {
    /// Where the pointer is does not belong here; the ring shows that.
    static func signature(
        _ store: Store, _ layout: OfficeLayout, now: Date, scale: CGFloat = 1,
        ready: ((String, Int, Int) -> Bool)? = nil
    ) -> [String] {
        let byID = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return [OfficePainter.roomKey(store, layout, scale: scale)]
            + layout.pets.map { place in
                guard let s = byID[place.id] else { return "\(place.id) \(place.zone) \(place.seat)" }
                return "\(place.id) \(place.zone) \(place.seat) | \(spriteKey(store, s, place, now: now, ready: ready))"
                    + " | \(wordsKey(store, s, place, layout, now: now, scale: scale))"
            }
    }
}

/// Where the painter writes a pet's name (or its card's middle, for one waiting), worked out
/// from the painter's own numbers rather than from the layout's frames.
/// A line of a word of this base size, painted for this scale.
func OfficeLookHeight(_ base: CGFloat, _ scale: CGFloat) -> CGFloat { OfficeLook.lineHeight(OfficeLook.type(base, scale: scale)) }

func officeNameSpot(_ pet: OfficeLayout.Pet, _ layout: OfficeLayout) -> CGPoint {
    switch pet.zone {
    case .lounge: return CGPoint(x: pet.x, y: pet.foot + 15)
    case .desk: return CGPoint(x: pet.x - 26, y: pet.foot + 17)
    case .sofa: return CGPoint(x: pet.x, y: pet.foot + 17)
    case .queue:
        // A card in each of the queue's fixed places, 125 apart from 186, its tail ending 86 over the feet; its height
        // follows its words.
        let bottom = pet.foot - 77 - 9
        return CGPoint(x: 186 + 58 + 125 * CGFloat(pet.seat), y: bottom - 20)
    }
}

/// Where the project line under a sitter is, when it has one: under a sofa sitter only where the picture is shown at
/// 90% or more, which its words' box tells.
func officeProjectSpot(_ pet: OfficeLayout.Pet) -> CGPoint? {
    switch pet.zone {
    case .desk: return CGPoint(x: pet.x - 26, y: pet.foot + 36)
    case .sofa: return pet.words.maxY >= pet.foot + 40 ? CGPoint(x: pet.x, y: pet.foot + 36) : nil
    default: return nil
    }
}

func officeSession(_ id: String, _ status: String, finished secondsAgo: TimeInterval, name: String? = nil) -> Session {
    Session(
        id: id, pid: 1, project: "项目", name: name ?? id, status: status, since: Date().addingTimeInterval(-secondsAgo),
        summary: status == "waiting" ? "要不要接着做？" : "")
}

/// One of each: waiting, with news, at work, looked at, resting.
@MainActor func officeStore() -> Store {
    let store = Store()
    store.readOnly = true
    store.sessions = [
        officeSession("o-wait", "waiting", finished: 120), officeSession("o-news", "idle", finished: 30),
        officeSession("o-busy", "busy", finished: 60), officeSession("o-seen", "idle", finished: 600),
        officeSession("o-rest", "idle", finished: 9 * 3600),
    ]
    store.seen["o-seen"] = Date().timeIntervalSince1970
    store.pinned = []
    store.hovered = nil
    return store
}

/// A picture's colour at a point, as 0xRRGGBB; pictures are two pixels to the point.
struct Pixels {
    let data: [UInt8]
    let width: Int, height: Int

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        width = w
        height = h
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?
                .draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        self.data = data
    }

    func at(_ x: CGFloat, _ y: CGFloat) -> UInt32 {
        let i = (min(height - 1, Int(y * 2)) * width + min(width - 1, Int(x * 2))) * 4
        return UInt32(data[i]) << 16 | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2])
    }

    func brightest(in r: CGRect) -> UInt8 {
        var most: UInt8 = 0
        for y in Int(r.minY * 2)..<Int(r.maxY * 2) {
            for x in Int(r.minX * 2)..<Int(r.maxX * 2) { most = max(most, data[(y * width + x) * 4]) }
        }
        return most
    }
}

/// Two colours a rounding step apart are the same colour.
func same(_ a: UInt32, _ b: UInt32) -> Bool {
    let shifts: [UInt32] = [16, 8, 0]
    return shifts.allSatisfy { abs(Int((a >> $0) & 255) - Int((b >> $0) & 255)) <= 3 }
}

func near(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
}

@MainActor func save(_ image: CGImage?, _ path: String) {
    guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
    try? png.write(to: URL(fileURLWithPath: path))
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// The office in the panel: when it shows, what redraws it, where the pointer finds whom.
@MainActor func officeViewTests() {
    // Shown only where it can be drawn at 72% or more: about 860 by 550.
    check(
        "office: shown at 860 wide and 551 high, the edges of 72%",
        showsOffice(setting: true, size: CGSize(width: 860, height: 600)) && showsOffice(setting: true, size: CGSize(width: 1000, height: 551)))
    check(
        "office: not at 859 wide or 550 high",
        !showsOffice(setting: true, size: CGSize(width: 859, height: 600)) && !showsOffice(setting: true, size: CGSize(width: 1000, height: 550)))
    check("office: not with the setting off, however large", !showsOffice(setting: false, size: CGSize(width: 1600, height: 1000)))
    check(
        "office: the status-bar lines for the office and the seaview room work where the office fits",
        officeMenuItem(.office, fits: true) == ("办公室", true) && officeMenuItem(.zone, fits: true) == ("海景房", true))
    check(
        "office: ...and in a smaller window they are off and say why",
        officeMenuItem(.office, fits: false) == ("办公室（窗口再大一些才显示）", false) && officeMenuItem(.zone, fits: false) == ("海景房（窗口再大一些才显示）", false))

    // The picture fitted into a view: 1194 wide, as tall as the view lets it be (764 to 1000),
    // centred across and standing on the bottom.
    let exact = OfficeFit(CGSize(width: 1194, height: 764)), boxed = OfficeFit(CGSize(width: 1000, height: 764))
    check("office: at its own size the picture fills the view", exact.scale == 1 && exact.offset == .zero && exact.height == 764)
    check("office: the user's window, 1134 by 930, gets a room 979 high", OfficeFit(CGSize(width: 1134, height: 930)).height == 979)
    check("office: the iPad's 1135 by 764 gets 803 or 804", [803, 804].contains(OfficeFit(CGSize(width: 1135, height: 764)).height))
    check("office: 1194 by 834 gets 834", OfficeFit(CGSize(width: 1194, height: 834)).height == 834)
    check(
        "office: in a narrower view it fills the width and grows taller, standing on the bottom",
        abs(boxed.scale - 1000 / 1194) < 0.0001 && boxed.offset.x == 0 && boxed.height == 912
            && abs(boxed.offset.y + 912 * boxed.scale - 764) < 0.0001)
    let tall = OfficeFit(CGSize(width: 900, height: 1200))
    check(
        "office: in a very tall view the room stops at 1000 and the rest above it is wall",
        tall.height == 1000 && abs(tall.offset.y - (1200 - 1000 * 900 / 1194)) < 0.0001 && tall.offset.x == 0
            && abs(tall.scale - 900 / 1194) < 0.0001)
    let desk = CGRect(x: 491, y: 282, width: 63, height: 84)
    let there = boxed.rect(desk), back = boxed.point(CGPoint(x: there.midX, y: there.midY))
    check(
        "office: a spot in the picture maps into the view and back to the same spot",
        abs(there.minY - (boxed.offset.y + 282 * boxed.scale)) < 0.0001 && abs(back.x - desk.midX) < 0.0001
            && abs(back.y - desk.midY) < 0.0001)
    let wide = OfficeFit(CGSize(width: 1600, height: 764))
    check(
        "office: in a wider view the bands are at the sides",
        wide.scale == 1 && wide.offset == CGPoint(x: 203, y: 0) && wide.height == 764)

    // The hover card: beside the pet, inside the window, under the title bar.
    let card = CGSize(width: 346, height: 120), window = CGSize(width: 1194, height: 866)
    let left = OfficeHover.origin(beside: CGRect(x: 100, y: 400, width: 63, height: 84), card: card, window: window)
    check("office: the card goes right of the pet when it fits", left.x >= 163 && left.x < 180 && abs(left.y + 60 - 442) < 1)
    let right = OfficeHover.origin(beside: CGRect(x: 1000, y: 400, width: 63, height: 84), card: card, window: window)
    check("office: near the right edge it goes left of the pet", right.x + 346 <= 1000 && right.x + 346 > 980)
    let low = OfficeHover.origin(beside: CGRect(x: 100, y: 800, width: 63, height: 60), card: card, window: window)
    check("office: near the bottom it stays inside the window", low.y + 120 <= 866 && low.y + 120 > 850)
    let high = OfficeHover.origin(beside: OfficeLayout.door, card: card, window: window)
    check("office: next to the door it stays below the title bar", high.y == 34)
    // At a large zoom in a narrow window neither side has room: below the pet, or else above it.
    let big = CGSize(width: 445, height: 200), narrow = CGSize(width: 900, height: 800)
    let middle = CGRect(x: 410, y: 400, width: 80, height: 100), bottom = CGRect(x: 410, y: 600, width: 80, height: 100)
    let under = OfficeHover.origin(beside: middle, card: big, window: narrow)
    let over = OfficeHover.origin(beside: bottom, card: big, window: narrow)
    check(
        "office: with no room beside it the card goes below the pet, not over it",
        !CGRect(origin: under, size: big).intersects(middle) && under.y >= 510 && under.y + 200 <= 792)
    check(
        "office: ...or above it when below would leave the window",
        !CGRect(origin: over, size: big).intersects(bottom) && over.y + 200 <= 600 && over.y >= 34)

    // Words keep their size on the screen: never smaller than their base size.
    check(
        "office: words are painted larger when the picture is shown smaller, never smaller when larger",
        OfficeLook.type(12, scale: 0.75) == 16 && abs(OfficeLook.type(12, scale: 0.95) - 12 / 0.95) < 0.0001
            && OfficeLook.type(12, scale: 1) == 12 && OfficeLook.type(12, scale: 1.3) == 12)
    check(
        "office: the scale steps down by twentieths, so on screen a word is never under its size",
        OfficeLook.step(1135 / 1194) == 0.95 && OfficeLook.step(0.872) == 0.85 && OfficeLook.step(1.3) == 1.3 && OfficeLook.step(0.95) == 0.95)

    // What the picture depends on, and what it does not.
    let store = officeStore()
    let now = Date()
    let layout = OfficePainter.layout(store, now: now)
    let base = OfficeView.signature(store, layout, now: now)
    check(
        "office: the same room twice paints the same",
        layout.pets.count == 5 && !base.isEmpty && base == OfficeView.signature(store, layout, now: now))
    store.hovered = "o-busy"
    check("office: pointing at a pet does not repaint", base == OfficeView.signature(store, OfficePainter.layout(store, now: now), now: now))
    store.hovered = nil
    store.pinned = ["o-news"]
    check("office: pinning repaints", base != OfficeView.signature(store, OfficePainter.layout(store, now: now), now: now))
    store.pinned = []
    let named = store.sessions
    store.sessions = named.map { $0.id == "o-busy" ? officeSession("o-busy", "busy", finished: 60, name: "新名字") : $0 }
    check("office: a new name repaints", base != OfficeView.signature(store, OfficePainter.layout(store, now: now), now: now))
    store.sessions = named
    check(
        "office: shown at another size it repaints",
        OfficeView.signature(store, layout, now: now, scale: 0.95) != OfficeView.signature(store, layout, now: now, scale: 0.75))
    check(
        "office: ...but not for a small change of size, nor above full size, where nothing painted changes",
        OfficeView.signature(store, layout, now: now, scale: 0.951) == OfficeView.signature(store, layout, now: now, scale: 0.96)
            && OfficeView.signature(store, layout, now: now, scale: 1.3) == OfficeView.signature(store, layout, now: now, scale: 1.35))
    let taller = OfficePainter.layout(store, now: now, height: 979)
    check(
        "office: a taller room repaints",
        OfficeView.signature(store, layout, now: now, scale: 0.95) != OfficeView.signature(store, taller, now: now, scale: 0.95))

    // Whether a pet's frames have been cut is part of what is painted.
    let dealt = officeStore()
    Pets.shared.refresh(force: true)
    dealt.assignPets()
    let dealtRoom = OfficePainter.layout(dealt, now: now)
    check(
        "office: a pet whose frames have just been cut repaints",
        dealt.petBySession.count == 5
            && OfficeView.signature(dealt, dealtRoom, now: now, ready: { _, _, _ in false })
                != OfficeView.signature(dealt, dealtRoom, now: now, ready: { _, _, _ in true }))

    // The project line under a desk sitter only where it has room.
    if let roomy = OfficePainter.picture(store, layout, now: now, scale: 0.95),
        let cramped = OfficePainter.picture(store, layout, now: now, scale: 0.85)
    {
        let line = CGRect(x: 470, y: 351, width: 68, height: 10)
        check("office: at 95% the project line is under the name", Pixels(roomy).brightest(in: line) > 0x70)
        check("office: at 85% it is left out", Pixels(cramped).brightest(in: line) < 0x50)
    }
    if let user = OfficePainter.picture(store, layout, now: now, scale: 1134 / 1194) {
        check(
            "office: in the user's 1134-wide window the project line is there",
            Pixels(user).brightest(in: CGRect(x: 470, y: 351, width: 68, height: 10)) > 0x70)
    }

    // Thirteen with news: the thirteenth sits at a desk, on paper.
    let waiting = Store()
    waiting.readOnly = true
    waiting.sessions = (0..<4).map { officeSession("ww\($0)", "waiting", finished: 300 - Double($0)) }
        + (0..<13).map { officeSession("nn\($0)", "idle", finished: 30 + Double($0)) }
    let waitingRoom = OfficePainter.layout(waiting, now: now)
    if let picture = OfficePainter.picture(waiting, waitingRoom, now: now), let first = waitingRoom.pets.first(where: { $0.id == "nn12" }) {
        // Sampled just inside the plate's left edge, clear of the name.
        let wide = OfficeCanvas(CGSize(width: 1, height: 1)).width(of: "nn12", size: 12) + 12
        check(
            "office: a session with news at a desk has the paper plate",
            first.zone == .desk && same(Pixels(picture).at(first.x - 26 - wide / 2 + 3, first.foot + 17), OfficeLook.paper))
    } else {
        check("office: a session with news at a desk has the paper plate", false)
    }
    // The card's second line is painted at every size: the project at its left, the wait at its right.
    let small = OfficePainter.layout(waiting, now: now, scale: 0.75)
    if let card = small.pets.first(where: { $0.zone == .queue })?.words, let shrunk = OfficePainter.picture(waiting, small, now: now, scale: 0.75) {
        let second = OfficeLayout.cardLines(card, scale: 0.75, asks: small.asks).second, pixels = Pixels(shrunk)
        func darkest(from left: CGFloat) -> UInt32 {
            var least: UInt32 = 0xFF
            for y in stride(from: second.minY + 2, to: second.maxY - 2, by: 0.5) {
                for x in stride(from: left, to: left + 24, by: 0.5) { least = min(least, pixels.at(x, y) >> 16) }
            }
            return least
        }
        check(
            "office: at 75% the card's second line shows the project and the wait",
            darkest(from: second.minX) < 0xB0 && darkest(from: second.maxX - 24) < 0xB0)
        check("office: ...in ink at 85%, readable on coral", darkest(from: second.minX) < 0x50 && darkest(from: second.maxX - 24) < 0x50)
        // The floor says what each part of the room is: "unread N" on the left margin over the first sofa, faint; at half
        // strength with nobody of that kind.
        let label = CGRect(x: 4, y: small.sofaFloor - 61, width: 56, height: 18)
        let floor = OfficePainter.room(waiting, small, scale: 0.75).map { Pixels($0).brightest(in: label) } ?? 0
        let none = Store()
        none.readOnly = true
        none.sessions = [officeSession("solo", "busy", finished: 60)]
        let bare = OfficePainter.layout(none, now: now, scale: 0.75)
        let faint = OfficePainter.room(none, bare, scale: 0.75).map { Pixels($0).brightest(in: label) } ?? 0
        check("office: the floor labels are painted in the room, a count of zero at half strength", floor > 0x70 && faint > 0x38 && faint < floor - 0x18)
    } else {
        check("office: at 75% the card's second line shows the project and the wait", false)
    }

    // A pet that stops work keeps its desk, but its screen goes dark.
    let one = Store()
    one.readOnly = true
    one.sessions = [officeSession("o-desk", "busy", finished: 60)]
    let working = OfficePainter.layout(one, now: now), workingLook = OfficeView.signature(one, working, now: now)
    one.sessions = [officeSession("o-desk", "idle", finished: 60)]
    one.seen["o-desk"] = Date().timeIntervalSince1970
    let resting = OfficePainter.layout(one, now: now)
    check(
        "office: a change of state repaints, even in the same seat",
        working.pets.map(\.seat) == resting.pets.map(\.seat) && working.pets.map(\.zone) == resting.pets.map(\.zone) && !working.pets.isEmpty
            && workingLook != OfficeView.signature(one, resting, now: now))

    // Nobody here: the room still stands, with a line on the rug where the queue would be.
    let empty = Store()
    empty.readOnly = true
    empty.sessions = []
    if let image = OfficePainter.picture(empty, OfficePainter.layout(empty, now: now), now: now) {
        let pixels = Pixels(image)
        check("office: with nobody in it the room is still drawn", pixels.at(1006, 60) == 0x26323D)
        check("office: ...and a quiet line on the rug says why", pixels.brightest(in: CGRect(x: 560, y: 650, width: 250, height: 12)) > 0x70)
    } else {
        check("office: with nobody in it the room is still drawn", false)
    }
}

/// The live view: where it says each pet is, the ring, when it repaints, what a click hits.
@MainActor func officeLiveTests() {
    for size in [CGSize(width: 1194, height: 764), CGSize(width: 1000, height: 764), CGSize(width: 900, height: 1200)] {
        let store = officeStore()
        let view = OfficeView(frame: CGRect(origin: .zero, size: size))
        view.update(store)
        // Narrower than 1194:764, so the room fills the width and is as tall as the view lets it be.
        let scale = size.width / 1194, high = min(1000, (size.height * 1194 / size.width).rounded(.down))
        let layout = OfficePainter.layout(store, now: Date(), height: high, scale: scale)
        let dx: CGFloat = 0, dy = size.height - high * scale
        func mapped(_ r: CGRect) -> CGRect {
            CGRect(x: dx + r.minX * scale, y: dy + r.minY * scale, width: r.width * scale, height: r.height * scale)
        }
        func mapped(_ p: CGPoint) -> CGPoint { CGPoint(x: dx + p.x * scale, y: dy + p.y * scale) }
        let at = "office \(Int(size.width))x\(Int(size.height))"
        let found = layout.pets.allSatisfy { pet in
            let r = mapped(pet.body)
            return store.tracker.card(at: CGPoint(x: r.midX, y: r.midY)) == pet.id
        }
        check("\(at): the middle of each pet points at that pet", layout.pets.count == 5 && found)
        let named = layout.pets.allSatisfy { pet in
            store.tracker.card(at: mapped(officeNameSpot(pet, layout))) == pet.id
                && (officeProjectSpot(pet).map { store.tracker.card(at: mapped($0)) == pet.id } ?? true)
        }
        check("\(at): pointing at a name, a plate or a card points at its session", named)
        let floor = CGPoint(x: dx + 600 * scale, y: dy + 300 * scale)
        check("\(at): the floor points at nobody", !store.tracker.frames.isEmpty && store.tracker.card(at: floor) == nil)
        let door = mapped(OfficeLayout.door), waiting = mapped(layout.pets.first { $0.id == "o-wait" }!.body)
        check(
            "\(at): a click on a pet is for its session, on the door for the door, elsewhere for nothing",
            view.target(at: CGPoint(x: waiting.midX, y: waiting.midY)) == .pet("o-wait")
                && view.target(at: CGPoint(x: door.midX, y: door.midY)) == .door && view.target(at: floor) == nil)
        if dy > 1 {
            check("\(at): the wall above the picture is nobody", view.target(at: CGPoint(x: door.midX, y: dy / 2)) == nil)
        }
    }

    // The first click lands even though the panel is never the active window.
    check("office: takes the first click", OfficeView(frame: .zero).acceptsFirstMouse(for: nil))

    // Placed below a 32-point title bar, it reports pets where the window has them.
    let store = officeStore()
    let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 1194, height: 796), styleMask: .borderless, backing: .buffered, defer: false)
    let holder = FlippedView(frame: NSRect(x: 0, y: 0, width: 1194, height: 796))
    window.contentView = holder
    let view = OfficeView(frame: NSRect(x: 0, y: 32, width: 1194, height: 764))
    holder.addSubview(view)
    view.update(store)
    let busy = OfficePainter.layout(store, now: Date()).pets.first { $0.id == "o-busy" }!
    check(
        "office: the pointer's frames are in the window's top-left coordinates",
        store.tracker.frames["o-busy"].map { near($0, busy.frame.offsetBy(dx: 0, dy: 32)) } ?? false)
    view.setFrameSize(NSSize(width: 1000, height: 764))
    holder.layoutSubtreeIfNeeded()
    let resized = OfficeFit(CGSize(width: 1000, height: 764))
    let moved = OfficePainter.layout(store, now: Date(), height: resized.height, scale: resized.scale).pets.first { $0.id == "o-busy" }!
    let narrower = resized.rect(moved.frame).offsetBy(dx: 0, dy: 32)
    check("office: resized, it tells the pointer where everyone is now", store.tracker.frames["o-busy"].map { near($0, narrower) } ?? false)
    view.setFrameSize(NSSize(width: 1194, height: 764))
    holder.layoutSubtreeIfNeeded()

    // Pointing moves a ring round the pet's body; it does not repaint the room or anyone's words.
    func layer(_ name: String) -> CALayer? { view.layer?.sublayers?.first { $0.name == name } }
    let painted = officeRoomLayer(view)?.contents as AnyObject?
    let busyWords = officePart(view, "o-busy", "words")?.contents as AnyObject?
    store.hovered = "o-busy"
    view.update(store)
    check("office: a ring goes round the body of the pet pointed at", layer("ring").map { !$0.isHidden && near($0.frame, busy.body) } ?? false)
    check(
        "office: ...without repainting the room or the words",
        painted != nil && officeRoomLayer(view)?.contents as AnyObject? === painted && busyWords != nil
            && officePart(view, "o-busy", "words")?.contents as AnyObject? === busyWords)
    store.hovered = OfficeLayout.doorKey
    view.update(store)
    check("office: pointing at the door rings the door", layer("ring").map { !$0.isHidden && near($0.frame, OfficeLayout.door) } ?? false)
    store.hovered = nil
    view.update(store)
    check("office: pointing at nothing, no ring", layer("ring")?.isHidden ?? false)
    store.sessions = store.sessions.map { $0.id == "o-busy" ? officeSession("o-busy", "busy", finished: 60, name: "新名字") : $0 }
    view.update(store)
    check(
        "office: a new name is painted under that pet, and the room is left as it was",
        busyWords != nil && officePart(view, "o-busy", "words")?.contents as AnyObject? !== busyWords
            && officeRoomLayer(view)?.contents as AnyObject? === painted)

    // Where a back-row name lies under the pet behind it, the pointer always finds the one in front.
    let crowd = Store()
    crowd.readOnly = true
    crowd.sessions = (0..<20).map { officeSession("r\($0)", "idle", finished: 9 * 3600 + Double($0)) }
    let crowded = OfficeView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    let front = (0..<100).allSatisfy { _ in
        crowded.update(crowd)
        return crowd.tracker.card(at: CGPoint(x: 98, y: 159)) == "r10" && crowd.tracker.card(at: CGPoint(x: 98, y: 150)) == "r0"
    }
    check("office: an overlap resolves to the pet in front, a hundred times in a row", front)

    // The user's own window: 1134 by 930, a room 979 high, words painted for exactly 1134/1194.
    let user = officeStore()
    let userView = OfficeView(frame: CGRect(x: 0, y: 0, width: 1134, height: 930))
    userView.update(user)
    let exact = OfficePainter.layout(user, now: Date(), height: 979, scale: 1134 / 1194)
    if let shown = officeRoomLayer(userView)?.contents as! CGImage?, let expected = OfficePainter.room(user, exact, scale: 1134 / 1194) {
        check(
            "office: the user's window shows a room 979 high, painted for its exact size",
            shown.height == 979 * 2 && Pixels(shown).data == Pixels(expected).data)
    } else {
        check("office: the user's window shows a room 979 high, painted for its exact size", false)
    }

    // One office at a time listens for pets; one going away does not deafen the next.
    let first = OfficeView(frame: .zero), second = OfficeView(frame: .zero)
    first.listen()
    second.listen()
    first.stopListening()
    check("office: an office leaving after the next one came leaves it listening", OfficePets.shared.onReady != nil)
    second.stopListening()
    check("office: ...and when that one leaves, nobody listens", OfficePets.shared.onReady == nil)

    officeBrokenSheetTests()
    officeRenderTests()
}

/// A sprite sheet eight tiny frames across, which cuts in no time: for checks about who gets cut, and when.
func officeTinySheet() -> Data? {
    let sheet = CGContext(
        data: nil, width: 16, height: 18, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    sheet?.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
    sheet?.fill(CGRect(x: 0, y: 0, width: 16, height: 18))
    return sheet?.makeImage().flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
}

/// A sheet that cannot be cut is not tried again on every refresh; a replaced one is.
@MainActor func officeBrokenSheetTests() {
    let scratch = NSTemporaryDirectory() + "office-pets-\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let files = FileManager.default
    let sheet = scratch + "/pool/broken/spritesheet.webp"
    try? files.createDirectory(atPath: scratch + "/pool/broken", withIntermediateDirectories: true)
    files.createFile(atPath: sheet, contents: Data("not a picture".utf8))
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    try? files.setAttributes([.modificationDate: stamp], ofItemAtPath: sheet)
    let pets = OfficePets(folder: scratch + "/cache", pools: [scratch + "/pool"])
    var calls = 0
    pets.onReady = { calls += 1 }
    func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    _ = pets.frame("broken", row: 0, column: 0)
    wait(0.5)
    check("office: a sheet that cannot be cut asks for no repaint", calls == 0 && pets.frame("broken", row: 0, column: 0) == nil)
    wait(0.5)  // any cut that look started has finished

    // Mended in place with the same date, then looked at on the spot: a retry would cut it now
    // and leave its folder behind. Remembered as failed, it is not touched.
    guard let mended = officeTinySheet() else {
        check("office: a sheet is there to mend the broken one with", false)
        return
    }
    try? files.removeItem(atPath: sheet)
    files.createFile(atPath: sheet, contents: mended)
    try? files.setAttributes([.modificationDate: stamp], ofItemAtPath: sheet)
    pets.synchronous = true
    let again = pets.frame("broken", row: 0, column: 0)
    check(
        "office: ...nor is it cut again on the next look",
        again == nil && !files.fileExists(atPath: scratch + "/cache/broken-\(Int(stamp.timeIntervalSince1970))"))

    // Replaced for real (a new date): it is cut.
    try? files.setAttributes([.modificationDate: Date()], ofItemAtPath: sheet)
    check("office: a sheet replaced later is cut", pets.frame("broken", row: 0, column: 0) != nil)
}

/// The live layers drawn as the window would show them. With OFFICE_PNGS set, the pictures are
/// also saved to /tmp for review, with real pets; otherwise the checks leave nothing behind.
@MainActor func officeRenderTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    let shown = officeStore()
    if review {
        Pets.shared.refresh(force: true)
        UserDefaults.standard.set(Array(Pets.shared.ids.prefix(5)), forKey: "favoritePets")
        shown.assignPets()
        UserDefaults.standard.removeObject(forKey: "favoritePets")
        OfficePets.shared.synchronous = true
    }
    defer { OfficePets.shared.synchronous = false }
    let sizes = [
        (CGSize(width: 1000, height: 700), "/tmp/office-view.png"), (CGSize(width: 1600, height: 764), "/tmp/office-wide.png"),
        (CGSize(width: 900, height: 1200), "/tmp/office-tall.png"),
    ]
    for (size, file) in sizes {
        let live = OfficeView(frame: CGRect(origin: .zero, size: size))
        shown.hovered = "o-news"
        live.update(shown)
        let fit = OfficeFit(size)
        let news = fit.rect(OfficePainter.layout(shown, now: Date(), height: fit.height, scale: fit.scale).pets.first { $0.id == "o-news" }!.body)
        let at = "office \(Int(size.width))x\(Int(size.height))"
        guard let image = live.image() else {
            check("\(at): the live view can be drawn", false)
            continue
        }
        if review { save(image, file) }
        let pixels = Pixels(image)
        check(
            "\(at): the ring shows round the pet pointed at",
            pixels.brightest(in: CGRect(x: news.minX, y: news.midY, width: 1.5, height: 2)) > 0x90)
        check(
            "\(at): the room's wall is at the top of the picture",
            same(pixels.at(fit.offset.x + 2, fit.offset.y + 30 * fit.scale), OfficeTheme.current.palette.wall))
        if fit.offset.x > 4 {
            // Band, wall, skirting, the shadow under it, floor: each carries on past the picture's edge.
            let seamless = [4, 30, 66, 73, 400].allSatisfy { (y: CGFloat) in
                same(pixels.at(2, y * fit.scale), pixels.at(fit.offset.x + 2 * fit.scale, y * fit.scale))
            }
            check("\(at): beside the picture, the room carries on without a seam", seamless)
        }
        if fit.offset.y > 4 {
            check("\(at): above the picture is wall", same(pixels.at(size.width / 2, fit.offset.y / 2), OfficeTheme.current.palette.wall))
            check(
                "\(at): ...and the room stands on the bottom edge: the rug under the queue to 4 pt over it, then floor",
                same(pixels.at(fit.offset.x + 600 * fit.scale, size.height - 6 * fit.scale), 0x394957)
                    && same(pixels.at(fit.offset.x + 600 * fit.scale, size.height - 1), 0x303B46))
        }
    }

    guard review else { return }
    // Made-up offices with three and with six waiting, at the user's window and near the smallest.
    let asks = ["要不要把首页从旧模板换成新模板？", "可以删掉旧的备份吗", "批准运行 docker compose up", "选哪个方案：A 还是 B", "继续部署到测试机吗", "这个端口要开放吗"]
    let names = ["云朵风车彩虹生成流程梳理", "Nova 像素风格 Comet 演示界面", "cloudsort 自动化方案", "月球漫步", "绘制星图 UV 排版风铃服务", "Owl"]
    let projects = ["demo-server", "Mac", "notify", "demo-network", "demo-mail", "demo-lighting"]
    for count in [3, 6] {
        let made = Store()
        made.readOnly = true
        // A part at a time: Swift 6.4 gives up type-checking these as one sum.
        var people: [Session] = (0..<count).map { i in
            Session(
                id: "wait\(i)", pid: 1, project: projects[i], name: names[i], status: "waiting",
                since: Date().addingTimeInterval(-Double(1000 - i * 120)), summary: asks[i])
        }
        people += (0..<6).map { officeSession("news\($0)", "idle", finished: 30 + Double($0) * 10, name: "有话说 \($0)") }
        people += (0..<3).map { officeSession("work\($0)", "busy", finished: 60, name: "干活 \($0)") }
        people += (0..<12).map { officeSession("rest\($0)", "idle", finished: 9 * 3600 + Double($0), name: "休息 \($0)") }
        made.sessions = people
        made.assignPets()
        for size in [CGSize(width: 1134, height: 930), CGSize(width: 900, height: 560)] {
            let view = OfficeView(frame: CGRect(origin: .zero, size: size))
            view.update(made)
            save(view.image(), "/tmp/office-\(count == 3 ? "three" : "six")-\(Int(size.width))x\(Int(size.height)).png")
        }
    }
}

/// Switching the panel's content between the board and the office, in a real hosting view.
@MainActor func officeSwitchTests() {
    let store = officeStore()
    store.tracker.store = store
    UserDefaults.standard.set(false, forKey: "office")
    let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 1194, height: 834), styleMask: .borderless, backing: .buffered, defer: false)
    let host = FirstClickHostingView(rootView: Root(store: store))
    var menuAt: CGPoint?
    host.onPointer = { [weak store] in store?.tracker.pointer(at: $0) }
    host.onMenu = { point in
        menuAt = point
        return nil
    }
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
    settle()
    let ids = Set(store.sessions.map(\.id))
    let board = store.tracker.frames
    check("switch: with the setting off, the board's cards are what the pointer finds", Set(board.keys) == ids)

    UserDefaults.standard.set(true, forKey: "office")
    settle()
    let fit = OfficeFit(CGSize(width: 1194, height: 834))
    let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
    check(
        "switch: with it on, the room's pets are what the pointer finds",
        layout.pets.count == 5 && layout.pets.allSatisfy { pet in store.tracker.frames[pet.id].map { near($0, fit.rect(pet.frame)) } ?? false }
            && store.tracker.frames[OfficeLayout.doorKey] != nil)
    func office(in view: NSView) -> OfficeView? { view as? OfficeView ?? view.subviews.lazy.compactMap(office(in:)).first }
    let ring = office(in: host)?.layer?.sublayers?.first { $0.name == "ring" }

    // A pet's frames arriving refreshes the office at once, before SwiftUI's own update comes round.
    store.hovered = "o-busy"
    OfficePets.shared.onReady?()
    let busy = fit.rect(layout.pets.first { $0.id == "o-busy" }!.body)
    check("switch: when a pet's frames are ready the office refreshes at once", ring.map { !$0.isHidden && near($0.frame, busy) } ?? false)
    store.hovered = nil
    settle()

    // The store changing reaches the view: pointing through the window's own tracker moves the ring.
    let seen = fit.rect(layout.pets.first { $0.id == "o-seen" }!.frame)
    store.tracker.pointer(at: CGPoint(x: seen.midX, y: seen.midY))
    settle()
    let seenBody = fit.rect(layout.pets.first { $0.id == "o-seen" }!.body)
    check(
        "switch: pointing at a pet in the panel rings it",
        store.hovered == "o-seen" && ring.map { !$0.isHidden && near($0.frame, seenBody) } ?? false)
    store.tracker.pointer(at: nil)
    settle()

    // A right-click goes up from the office to the window's view, which asks for the menu there.
    let news = fit.rect(layout.pets.first { $0.id == "o-news" }!.frame)
    let spot = host.convert(CGPoint(x: news.midX, y: news.midY), to: nil)
    if let click = NSEvent.mouseEvent(
        with: .rightMouseDown, location: spot, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)
    {
        window.sendEvent(click)
    }
    check("switch: a right-click on a pet asks for that session's menu", menuAt.flatMap(store.tracker.card(at:)) == "o-news")

    UserDefaults.standard.set(false, forKey: "office")
    settle()
    check(
        "switch: back on the board, its cards are what the pointer finds again",
        Set(store.tracker.frames.keys) == ids && store.tracker.frames == board)
    check("switch: the office no longer listens for pets", OfficePets.shared.onReady == nil)
    check("switch: ...and the board's pointer is back to its own frames", store.tracker.resolver == nil)
}

// ───────── The office moving ─────────

/// The room's layers as the live view holds them: the room, then one layer per pet.
/// The colour of the wall band the view runs beside and above the picture.
@MainActor func officeWallColour(_ view: NSView) -> CGColor? {
    view.layer?.sublayers?.first { $0 !== officeStage(view) && $0.frame.minY == 0 && $0.backgroundColor != nil && $0.frame.height > 40 }?.backgroundColor
}
@MainActor func officeStage(_ view: NSView) -> CALayer? { view.layer?.sublayers?.first { $0.name == "stage" } }
@MainActor func officeRoomLayer(_ view: NSView) -> CALayer? { officeStage(view)?.sublayers?.first { $0.name == "room" } }
@MainActor func officeFigure(_ view: NSView, _ id: String) -> CALayer? { officeStage(view)?.sublayers?.first { $0.name == id } }
@MainActor func officePart(_ view: NSView, _ id: String, _ part: String) -> CALayer? {
    officeFigure(view, id)?.sublayers?.first { $0.name == part }
}

/// An office that counts as seen on screen, and can be told it is being resized: off the screen,
/// a real one would neither walk nor know about a drag.
final class OfficeTestView: OfficeView {
    var shownOnScreen = true
    var resizing = false
    /// How far its clock is ahead of the real one, so that a check need not wait 45 s.
    var shift: TimeInterval = 0
    /// Reduce Motion, as a check sets it, whatever this Mac's is.
    var calmed = false
    override var onScreen: Bool { shownOnScreen }
    override var inLiveResize: Bool { resizing }
    override var clock: Date { Date().addingTimeInterval(shift) }
    override var calm: Bool { calmed }
}

/// Deals cut pets as `officeDealCutPets(_:)` does, giving this pet (when it is cut) to this session.
@MainActor func officeDealCutPets(_ store: Store, giving pet: String, to id: String) -> Bool {
    officeDealCutPets(store, giving: [id: pet])
}

/// The same, giving each of these sessions the pet named for it, when all of those are cut: a check whose walks
/// depend on how far each pet reaches then comes out the same every time.
@MainActor func officeDealCutPets(_ store: Store, giving fixed: [String: String]) -> Bool {
    Pets.shared.refresh(force: true)
    let cut = Pets.shared.ids.filter { OfficePets.shared.isCut($0) }
    guard fixed.values.allSatisfy(cut.contains), cut.count >= store.sessions.count else { return officeDealCutPets(store) }
    let all = store.sessions
    store.sessions = all.filter { fixed[$0.id] == nil }
    UserDefaults.standard.set(cut.filter { !fixed.values.contains($0) }, forKey: "favoritePets")
    store.assignPets()
    for s in all where fixed[s.id] != nil {
        store.sessions.append(s)
        UserDefaults.standard.set([fixed[s.id]!], forKey: "favoritePets")
        store.assignPets()
    }
    store.sessions = all
    UserDefaults.standard.removeObject(forKey: "favoritePets")
    return store.sessions.allSatisfy { s in store.petBySession[s.id].map(cut.contains) ?? false }
        && fixed.allSatisfy { store.petBySession[$0.key] == $0.value }
}

/// The first cut pets by name: the same ones every run.
@MainActor func officeFixedPets(_ count: Int) -> [String] {
    Pets.shared.refresh(force: true)
    return Array(Pets.shared.ids.filter { OfficePets.shared.isCut($0) }.sorted().prefix(count))
}

/// When a walk is on its aisle (its leg up or down the room by the centre or a wall): which aisle (0 the centre, 1 the
/// left wall, 2 the right), its x, and from when to when, from the walk's own keyframes.
func officePassage(_ walk: CAAnimation?) -> (aisle: Int, x: CGFloat, enters: CFTimeInterval, leaves: CFTimeInterval)? {
    guard let move = walk as? CAKeyframeAnimation, let values = move.values?.compactMap({ ($0 as? NSValue)?.pointValue }),
        let times = move.keyTimes?.map(\.doubleValue), values.count == times.count, values.count > 1
    else { return nil }
    let leg = (0..<values.count - 1).first { i in
        values[i].x == values[i + 1].x && values[i].y != values[i + 1].y && (values[i].x == 597 || values[i].x < 120 || values[i].x > 1074)
    }
    guard let i = leg else { return nil }
    let x = values[i].x
    return (x == 597 ? 0 : x < 597 ? 1 : 2, x, move.beginTime + times[i] * move.duration, move.beginTime + times[i + 1] * move.duration)
}

/// Whether two of these walkers on one aisle come within 20 pt of each other while both are on it, every 10 ms.
@MainActor func officeCrowded(_ view: NSView, _ ids: [String]) -> Bool {
    let on = ids.compactMap { id in officePassage(officeFigure(view, id)?.animation(forKey: "walk")).map { (id: id, passage: $0) } }
    for (i, a) in on.enumerated() {
        for b in on.dropFirst(i + 1) where a.passage.aisle == b.passage.aisle {
            let from = max(a.passage.enters, b.passage.enters), to = min(a.passage.leaves, b.passage.leaves)
            for t in stride(from: from, through: to, by: 0.01) {
                guard let p = officeWalkPoint(officeFigure(view, a.id), at: t), let q = officeWalkPoint(officeFigure(view, b.id), at: t)
                else { continue }
                if abs(p.y - q.y) < 19.9 { return true }
            }
        }
    }
    return false
}

/// Whether, on each aisle, these walkers come onto it one at a time, at least 0.35 s apart; and how many share one.
@MainActor func officeSpaced(_ view: NSView, _ ids: [String]) -> (spaced: Bool, sharing: Int) {
    let on = ids.compactMap { officePassage(officeFigure(view, $0)?.animation(forKey: "walk")) }
    let groups = Dictionary(grouping: on, by: \.aisle).values
    let spaced = groups.allSatisfy { group in
        let enters = group.map(\.enters).sorted()
        return zip(enters, enters.dropFirst()).allSatisfy { $1 - $0 >= 0.349 }
    }
    return (spaced, groups.filter { $0.count > 1 }.map(\.count).reduce(0, +))
}

/// The aisle a walk goes up or down the room by (0 the centre, 1 the left wall, 2 the right) and its x.
func officeAisle(_ walk: CAAnimation?) -> (index: Int, x: CGFloat)? {
    let values = (walk as? CAKeyframeAnimation)?.values?.compactMap { ($0 as? NSValue)?.pointValue } ?? []
    let up = zip(values, values.dropFirst()).first { $0.x == $1.x && $0.y != $1.y && ($0.x == 597 || $0.x < 120 || $0.x > 1074) }
    guard let leg = up else { return nil }
    return (leg.0.x == 597 ? 0 : leg.0.x < 597 ? 1 : 2, leg.0.x)
}

/// Deals pets from the real pool, but only ones whose true-size frames are already cut, so the
/// checks write nothing into the caches. False when there are not enough of them.
@MainActor func officeDealCutPets(_ store: Store) -> Bool {
    Pets.shared.refresh(force: true)
    let cut = Pets.shared.ids.filter { OfficePets.shared.isCut($0) }
    guard cut.count >= store.sessions.count else { return false }
    UserDefaults.standard.set(cut, forKey: "favoritePets")
    store.assignPets()
    UserDefaults.standard.removeObject(forKey: "favoritePets")
    return store.sessions.allSatisfy { s in store.petBySession[s.id].map(cut.contains) ?? false }
}

/// The share of pixels where two equal-sized pictures differ by more than `by` in any channel,
/// counting only inside `area` (in points).
func officeDifference(_ a: CGImage, _ b: CGImage, by: Int = 24, in area: CGRect? = nil) -> Double {
    officeDifference(Pixels(a), Pixels(b), by: by, in: area)
}

func officeDifference(_ pa: Pixels, _ pb: Pixels, by: Int = 24, in area: CGRect? = nil) -> Double {
    guard pa.width == pb.width, pa.height == pb.height else { return 1 }
    let r = area ?? CGRect(x: 0, y: 0, width: CGFloat(pa.width) / 2, height: CGFloat(pa.height) / 2)
    let rows = max(0, Int(r.minY * 2))..<min(pa.height, max(0, Int(r.maxY * 2)))
    let columns = max(0, Int(r.minX * 2))..<min(pa.width, max(0, Int(r.maxX * 2)))
    guard !rows.isEmpty, !columns.isEmpty else { return 1 }
    var differing = 0
    pa.data.withUnsafeBufferPointer { a in
        pb.data.withUnsafeBufferPointer { b in
            for y in rows {
                for x in columns {
                    let i = (y * pa.width + x) * 4
                    if abs(Int(a[i]) - Int(b[i])) > by || abs(Int(a[i + 1]) - Int(b[i + 1])) > by || abs(Int(a[i + 2]) - Int(b[i + 2])) > by {
                        differing += 1
                    }
                }
            }
        }
    }
    return Double(differing) / Double(rows.count * columns.count)
}

/// A picture drawn into a bitmap of the view's size at the spot the view shows it, as a window would.
func officeFitted(_ picture: CGImage, size: CGSize, at r: CGRect) -> CGImage? {
    guard
        let ctx = CGContext(
            data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .medium
    ctx.draw(picture, in: CGRect(x: r.minX * 2, y: (size.height - r.maxY) * 2, width: r.width * 2, height: r.height * 2))
    return ctx.makeImage()
}

/// The layers as they are on screen at this moment, animations and all.
@MainActor func officeMoment(_ view: NSView, pixels: CGFloat = 2) -> CGImage? {
    // `render(in:)` goes by the order of the layers, not their depth: order the pets by where their
    // feet are at this moment, as the window server does. The view puts them back on its next pass.
    if let stage = officeStage(view), let layers = stage.sublayers {
        let deep = layers.enumerated().sorted { a, b in
            let za = a.element.presentation()?.zPosition ?? a.element.zPosition, zb = b.element.presentation()?.zPosition ?? b.element.zPosition
            return za != zb ? za < zb : a.offset < b.offset
        }.map(\.element)
        // Layers just put back in another order are drawn without their animations until that is handed over.
        if deep.map(ObjectIdentifier.init) != layers.map(ObjectIdentifier.init) {
            stage.sublayers = deep
            CATransaction.flush()
        }
    }
    guard let layer = view.layer?.presentation() ?? view.layer,
        let ctx = CGContext(
            data: nil, width: Int(view.bounds.width * pixels), height: Int(view.bounds.height * pixels), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.scaleBy(x: pixels, y: pixels)
    if view.layer?.isGeometryFlipped ?? false {
        ctx.translateBy(x: 0, y: view.bounds.height)
        ctx.scaleBy(x: 1, y: -1)
    }
    layer.render(in: ctx)
    return ctx.makeImage()
}

/// Whether a point lies on a route of straight legs, and how far along it is (0 at the start).
func officeAlong(_ p: CGPoint, _ route: [CGPoint]) -> CGFloat? {
    var walked: CGFloat = 0
    for (a, b) in zip(route, route.dropFirst()) {
        let length = hypot(b.x - a.x, b.y - a.y)
        let t = length > 0 ? max(0, min(1, ((p.x - a.x) * (b.x - a.x) + (p.y - a.y) * (b.y - a.y)) / (length * length))) : 0
        let foot = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        if hypot(p.x - foot.x, p.y - foot.y) < 1 { return walked + length * t }
        walked += length
    }
    return nil
}

func officeLength(_ route: [CGPoint]) -> CGFloat { zip(route, route.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) } }

/// Made-up sessions: of each kind, so many, the i-th finished a second earlier than the one before.
func officeSessions(_ kinds: [(prefix: String, status: String, count: Int, ago: TimeInterval)]) -> [Session] {
    kinds.flatMap { kind in (0..<kind.count).map { officeSession("\(kind.prefix)\($0)", kind.status, finished: kind.ago + Double($0)) } }
}

/// The process's resident memory, in megabytes.
func officeResident() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
}

/// Seats that stay put: a session keeps its place while it stays in the same part of the room.
@MainActor func officeSeatTests() {
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    func seat(_ layout: OfficeLayout, _ id: String) -> (zone: OfficeLayout.Zone, seat: Int, x: CGFloat)? {
        layout.pets.first { $0.id == id }.map { ($0.zone, $0.seat, $0.x) }
    }
    let first = OfficeLayout(waiting: [], unread: [], busy: [], seen: ["s0", "s1", "s2"], resting: [])
    let gone = OfficeLayout(waiting: [], unread: [], busy: [], seen: ["s0", "s2"], resting: [], previous: first)
    check(
        "office: when a neighbour leaves, I keep my seat",
        seat(gone, "s2")?.seat == 2 && seat(gone, "s2")?.x == seat(first, "s2")?.x && seat(gone, "s0")?.seat == 0)
    // Desk seats from the aisle outward: 0..7 along the first row at x 530, 708, 398, 840, 266, 972,
    // 134, 1104; 8..15 the same along the second.
    let firstRow = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("s", 8), resting: [])
    let oneGone = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("s", 7), resting: [], previous: firstRow)
    let hole = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("s", 7) + ["n0"], resting: [], previous: oneGone)
    check(
        "office: a newcomer through the door takes the free seat its way is shortest to, here the hole by the right wall",
        seat(hole, "n0")?.seat == 7 && seat(hole, "s6")?.seat == 6)
    let moved = OfficeLayout(waiting: [], unread: [], busy: [], seen: ["s1", "s2"], resting: ["s0"], previous: first)
    let desksAgain = OfficeLayout(waiting: [], unread: [], busy: [], seen: ["s0", "s1", "s2"], resting: [], previous: moved)
    check(
        "office: a change of zone takes the nearest seat in the new zone and frees the old one",
        seat(moved, "s0")?.zone == .lounge && seat(moved, "s0")?.x == 514 && !moved.pets.contains { $0.zone == .desk && $0.seat == 0 }
            && seat(desksAgain, "s0")?.seat == 0 && seat(moved, "s2")?.seat == 2)

    // A desk of one's own: kept while its session waits or has news, given up only when no other is free.
    let six = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("s", 6), resting: ["ra", "rb", "rc", "r3"])
    let away = OfficeLayout(
        waiting: ["s2"], unread: [], busy: [], seen: ["s1", "s3", "s4", "s5"], resting: ["s0", "ra", "rb", "rc", "r3"], previous: six)
    let awayAgain = OfficeLayout(
        waiting: ["s2"], unread: [], busy: [], seen: ["s1", "s3", "s4", "s5"], resting: ["s0", "ra", "rb", "rc", "r3"], previous: away)
    let home = OfficeLayout(
        waiting: [], unread: [], busy: [], seen: ["s1", "s2", "s3", "s4", "s5"], resting: ["s0", "ra", "rb", "rc", "r3"], previous: awayAgain)
    check(
        "office: a session back from waiting returns to the desk it left, though a free one is nearer",
        seat(away, "s2")?.zone == .queue && seat(home, "s2")?.seat == 2 && !home.pets.contains { $0.zone == .desk && $0.seat == 0 })
    let keeping = OfficeLayout(waiting: ["s7"], unread: [], busy: [], seen: ids("s", 7) + ["n0"], resting: [], previous: firstRow)
    check(
        "office: a newcomer takes a desk nobody keeps while there is one, even if a kept one is nearer",
        seat(keeping, "s7")?.zone == .queue && seat(keeping, "n0")?.seat == 15)

    // The nearest seat is the one with the shortest way there, along the legs it would walk.
    let sofa = OfficeLayout(waiting: [], unread: ["u0"], busy: [], seen: ids("s", 7), resting: [])
    let looked = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("s", 7) + ["u0"], resting: [], previous: sofa)
    check(
        "office: from the first sofa, a pet looked at takes the free desk its way is shortest to: by the left wall, on the nearer row",
        seat(sofa, "u0")?.x == 92 && seat(looked, "u0")?.seat == 14)
    let news = OfficeLayout(waiting: [], unread: ["s7"], busy: [], seen: ids("s", 7), resting: [], previous: firstRow)
    check(
        "office: from the far-right desk, a pet with news takes the last sofa, at its seat nearest the wall it walks down",
        seat(news, "s7")?.x == 1103)
    let door = OfficeLayout(waiting: [], unread: [], busy: [], seen: ["s0", "s1", "n0"], resting: [], previous: OfficeLayout(
        waiting: [], unread: [], busy: [], seen: ["s0", "s1"], resting: []))
    check(
        "office: one coming in through the door takes the free desk its way is shortest to: down the right wall",
        seat(door, "n0")?.seat == 7)
    let queue = OfficeLayout(waiting: ["w0", "w1", "w2"], unread: [], busy: [], seen: [], resting: [])
    let closed = OfficeLayout(waiting: ["w1", "w2"], unread: [], busy: [], seen: [], resting: [], previous: queue)
    check(
        "office: the queue closes ranks in waiting order",
        seat(closed, "w1")?.seat == 0 && seat(closed, "w2")?.seat == 1 && seat(closed, "w1")?.x == 244 && seat(closed, "w2")?.x == 369)
    let busy = OfficeLayout(waiting: ids("w", 2), unread: ids("u", 8), busy: ids("b", 4), seen: ids("s", 9), resting: ids("r", 14))
    let again = OfficeLayout(
        waiting: ids("w", 2), unread: ids("u", 8), busy: ids("b", 4), seen: ids("s", 9), resting: ids("r", 14), previous: busy)
    check(
        "office: who is in the room is still decided first, by priority and capacity",
        again.behindDoorIDs == busy.behindDoorIDs && Set(again.pets.map(\.id)) == Set(busy.pets.map(\.id)) && !busy.behindDoorIDs.isEmpty)
    let holey = OfficeLayout(waiting: ["w1"], unread: ["u0"], busy: ["b1"], seen: ["s0", "s5"], resting: ["r3", "r12"], previous: again)
    let same = OfficeLayout(waiting: ["w1"], unread: ["u0"], busy: ["b1"], seen: ["s0", "s5"], resting: ["r3", "r12"], previous: holey)
    check("office: laid out again from itself, nobody moves", !holey.pets.isEmpty && same.pets == holey.pets)

    // With holes, everyone keeps their seat (the couches at the back are always there, both rows of them), and a lit
    // screen is the seat of whoever works there.
    let back = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: ids("r", 8))
    let left = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: ["r0", "r7"], previous: back)
    check(
        "office: with only the first and the eighth left at the back, both keep their seats on their couches",
        left.pets.map { "\($0.id) \($0.seat) \($0.x)" } == ["r0 0 106.0", "r7 7 884.0"])
    let row2 = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: ["r12"], previous: OfficeLayout(
        waiting: [], unread: [], busy: [], seen: [], resting: ids("r", 13)))
    check("office: one left on the second row at the back keeps its seat there", row2.pets.map { "\($0.seat) \($0.foot)" } == ["12 213.0"])
    let store = Store()
    store.readOnly = true
    store.sessions = (0..<4).map { officeSession("d\($0)", $0 == 3 ? "busy" : "idle", finished: 600) }
    for s in store.sessions { store.seen[s.id] = Date().timeIntervalSince1970 }
    let dealt = OfficeLayout(waiting: [], unread: [], busy: ["d3"], seen: ["d0", "d1", "d2"], resting: [])
    let kept = OfficeLayout(waiting: [], unread: [], busy: ["d3"], seen: ["d1"], resting: [], previous: OfficeLayout(
        waiting: [], unread: [], busy: [], seen: ["d0", "d1", "d2", "d3"], resting: []))
    check(
        "office: the lit screen is the one at the working session's own seat",
        OfficePainter.lit(store, dealt) == [0] && OfficePainter.lit(store, kept) == [3])
    // Laid out over and over while its session waits (the view does so on every tick), a desk stays kept.
    let often = (0..<5).reduce(away) { previous, _ in
        OfficeLayout(
            waiting: ["s2"], unread: [], busy: [], seen: ["s1", "s3", "s4", "s5"], resting: ["s0", "ra", "rb", "rc", "r3"], previous: previous)
    }
    check("office: a kept desk stays kept however often the room is laid out", often.reserved["s2"] == 2)

    // A walk goes at 240 pt/s up to 2.5 s; a longer one takes 2.5 s up to 800 pt, then goes at 320 pt/s, 3.5 s at most.
    func seconds(_ length: CGFloat) -> Double { OfficeLayout.walkSeconds([.zero, CGPoint(x: 0, y: length)]) }
    check(
        "office: a walk goes at 240 pt/s, takes 2.5 s up to 800 pt, then goes at 320 pt/s, and takes 3.5 s at most",
        seconds(240) == 1 && seconds(600) == 2.5 && seconds(800) == 2.5 && abs(seconds(1000) - 3.125) < 0.001 && seconds(1151) == 3.5
            && seconds(2000) == 3.5)
    check("office: ...so the 1151-pt walk from a desk to the queue in a 979-high room takes 3.5 s, at 330 pt/s or less", 1151 / seconds(1151) <= 330)
    officeWalkTimes()
}

/// How long the usual walks take in rooms 764 and 979 high (the user's window), with seats as given now.
@MainActor func officeWalkTimes() {
    for height in [CGFloat(764), 979] { officeWalkTimes(height) }
}

@MainActor func officeWalkTimes(_ height: CGFloat) {
    func layout(_ waiting: [String], _ unread: [String], _ seen: [String], _ previous: OfficeLayout?) -> OfficeLayout {
        OfficeLayout(waiting: waiting, unread: unread, busy: [], seen: seen, resting: [], height: height, scale: 1134 / 1194, previous: previous)
    }
    let seated = (0..<8).map { "s\($0)" }
    let start = layout([], ["u0", "u1"], seated, nil)
    func spot(_ l: OfficeLayout, _ id: String) -> OfficeSpot { l.spot(of: l.pets.first { $0.id == id }!) }
    func time(_ route: [CGPoint]) -> String {
        let length = officeLength(route), seconds = OfficeLayout.walkSeconds(route)
        return String(format: "%.0f pt, %.1f s, %.0f pt/s", length, seconds, length / seconds)
    }
    func time(_ from: OfficeLayout, _ a: String, _ to: OfficeLayout, _ b: String, tall: CGFloat = 70) -> String {
        time(to.route(from: spot(from, a), to: spot(to, b), tall: tall))
    }
    let toQueue = layout(["s3"], ["u0", "u1"], seated.filter { $0 != "s3" }, start)
    let toSofa = layout([], ["u0", "u1", "s3"], seated.filter { $0 != "s3" }, start)
    let toDesk = layout([], ["u1"], seated + ["u0"], start)
    let inDoor = layout([], ["u0", "u1"], seated + ["n0"], start)
    let walks = [
        "desk→queue " + time(start, "s3", toQueue, "s3"), "desk→sofa " + time(start, "s3", toSofa, "s3"),
        "sofa→desk " + time(start, "u0", toDesk, "u0"),
        "door→desk " + time(inDoor.route(from: OfficeLayout.doorSpot, to: spot(inDoor, "n0"))),
    ]
    print("      walks in a room \(Int(height)) high: " + walks.joined(separator: ", "))
}

/// Nobody who needs you, or works, is hidden; the room says what it is.
@MainActor func officeRoomRulesTests() {
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    func office(_ waiting: Int, _ unread: Int, _ busy: Int, _ seen: Int, _ resting: Int, previous: OfficeLayout? = nil) -> OfficeLayout {
        OfficeLayout(
            waiting: ids("w", waiting), unread: ids("u", unread), busy: ids("b", busy), seen: ids("s", seen), resting: ids("r", resting),
            previous: previous)
    }
    func zone(_ layout: OfficeLayout, _ zone: OfficeLayout.Zone) -> [OfficeLayout.Pet] { layout.pets.filter { $0.zone == zone } }
    func pet(_ layout: OfficeLayout, _ id: String) -> OfficeLayout.Pet? { layout.pets.first { $0.id == id } }

    // Thirty in the room, each kind in its own zone first; the door only for the looked-at and resting.
    let today = office(0, 2, 3, 8, 20)
    check(
        "office: 33 sessions, 20 resting: thirty in the room, the three behind the door all resting",
        today.pets.count == 30 && today.behindDoorIDs == ["r17", "r18", "r19"])
    let thirteen = office(0, 13, 0, 0, 0)
    check("office: thirteen with news: twelve on the sofas, one at a desk", zone(thirteen, .sofa).count == 12 && zone(thirteen, .desk).count == 1)
    let working = office(0, 0, 18, 0, 0)
    let back = zone(working, .lounge)
    check(
        "office: eighteen at work: sixteen at desks, two at the back, awake and on their plates, none behind the door",
        zone(working, .desk).count == 16 && back.count == 2 && back.allSatisfy { $0.kind == .work && !$0.asleep } && working.behindDoor == 0)

    // Seven in the queue; an eighth waits where it sits, flagged, and the chip in the queue's eighth place says so.
    let before = office(7, 4, 0, 4, 0)
    let eighth = OfficeLayout(
        waiting: ids("w", 7) + ["s1"], unread: ids("u", 4), busy: [], seen: ["s0", "s2", "s3"], resting: [], previous: before)
    let chip = eighth.chips.first { $0.kind == .waiting }
    check(
        "office: an eighth starting to wait stays at its desk, flagged, the queue seven at 70, the chip in the eighth place says 1",
        zone(eighth, .queue).map(\.id) == ids("w", 7) && zone(eighth, .queue).allSatisfy { $0.tall == 70 }
            && pet(eighth, "s1").map { $0.flagged && $0.zone == .desk && $0.seat == pet(before, "s1")?.seat } ?? false && chip?.count == 1
            && chip?.rect == CGRect(x: 1061, y: 610.5, width: 116, height: 61.5))
    check(
        "office: ...and nobody on the sofas moved",
        !zone(before, .sofa).isEmpty
            && zone(before, .sofa).allSatisfy { sitter in pet(eighth, sitter.id).map { $0.zone == .sofa && $0.seat == sitter.seat } ?? false })
    let fromSofa = OfficeLayout(
        waiting: ids("w", 7) + ["u0"], unread: ["u1", "u2", "u3"], busy: [], seen: ids("s", 4), resting: [], previous: before)
    check(
        "office: one with news on a sofa that starts waiting while seven wait stays on its sofa, flagged",
        pet(fromSofa, "u0").map { $0.flagged && $0.zone == .sofa && $0.seat == pet(before, "u0")?.seat } ?? false)
    let answered = OfficeLayout(
        waiting: Array(ids("w", 7).dropFirst()) + ["s1"], unread: ids("u", 4), busy: [], seen: ["s0", "s2", "s3", "w0"], resting: [],
        previous: eighth)
    check(
        "office: when a place in the queue frees, the one that has waited longest comes forward",
        zone(answered, .queue).map(\.id) == Array(ids("w", 7).dropFirst()) + ["s1"] && answered.chips.isEmpty)

    // A flagged plate shows no time: it is not painted again as the minutes pass; a queue card, which shows the wait, is.
    let waitingStore = Store()
    waitingStore.readOnly = true
    waitingStore.sessions = officeSessions([("w", "waiting", 8, 300)])
    let waits = OfficePainter.layout(waitingStore, now: Date())
    let flaggedPet = waits.pets.first(where: \.flagged), queuedPet = waits.pets.first { $0.zone == .queue }
    func key(_ place: OfficeLayout.Pet?, _ later: TimeInterval) -> String? {
        place.flatMap { p in waitingStore.sessions.first { $0.id == p.id }.map {
            OfficeView.wordsKey(waitingStore, $0, p, waits, now: Date().addingTimeInterval(later), scale: 1)
        } }
    }
    check(
        "office: a flagged plate is not painted again as the minutes pass; a queue card is",
        flaggedPet != nil && key(flaggedPet, 0) == key(flaggedPet, 120) && key(queuedPet, 0) != key(queuedPet, 120))

    // More than thirty need you or work: the surplus is counted on chips, never on the door.
    let crowd = office(11, 14, 15, 0, 64)
    let counts = Dictionary(crowd.chips.map { ($0.kind, $0.count) }, uniquingKeysWith: { first, _ in first })
    check(
        "office: a crowd of 11 waiting, 14 with news, 15 at work, 64 resting: chips say 4 waiting and 10 at work, the door 64",
        crowd.pets.count == 30 && counts[.waiting] == 4 && counts[.news] == nil && counts[.work] == 10 && crowd.behindDoor == 64
            && crowd.behindDoorIDs.allSatisfy { $0.hasPrefix("r") })
    let more = office(9, 25, 0, 0, 0)
    check(
        "office: ...and with news beyond the room, a chip for them too",
        Dictionary(more.chips.map { ($0.kind, $0.count) }, uniquingKeysWith: { first, _ in first })[.news] == 4)
    let room = CGRect(origin: .zero, size: crowd.size)
    check(
        "office: the chips are inside the room, apart from each other and from the door",
        crowd.chips.count == 2 && crowd.chips.allSatisfy { room.contains($0.rect) && !$0.rect.intersects(OfficeLayout.door) }
            && !crowd.chips[0].rect.intersects(crowd.chips[1].rect))
    check(
        "office: pointing at a session counted on a chip points at the chip",
        crowd.pointed(at: "b14") == OfficeLayout.ChipKind.work.key && crowd.pointed(at: "w10") == "w10" && crowd.pointed(at: "r60") == OfficeLayout.doorKey)

    // The floor labels' counts; the door's card; the switch.
    check(
        "office: the floor labels count who is in the queue, on the sofas, at the desks and on the back couches (by seat)",
        crowd.counts == OfficeLayout.Counts(
            waiting: crowd.pets.filter { $0.zone == .queue }.count, news: crowd.pets.filter { $0.zone == .sofa }.count,
            desks: crowd.pets.filter { $0.zone == .desk }.count, resting: crowd.pets.filter { $0.zone == .lounge }.count)
            && crowd.counts.waiting == 7)
    let store = Store()
    store.readOnly = true
    store.sessions = officeSessions([("s", "idle", 2, 900), ("r", "idle", 2, 9 * 3600.0)])
    for s in store.sessions { store.seen[s.id] = Date().timeIntervalSince1970 }
    check(
        "office: the door's card marks the resting with a z",
        OfficeDoorCard.lines(store, ids: ["s0", "s1", "r0", "r1"]).map(\.resting) == [false, false, true, true])
    check(
        "office: the title bar's switch shows the three names, the current one filled",
        OfficeSwitch.segments(mode: .office).map(\.title) == ["值班室", "办公室", "海景房"] && OfficeSwitch.segments(mode: .office).map(\.on) == [false, true, false]
            && OfficeSwitch.segments(mode: .board).map(\.on) == [true, false, false] && OfficeSwitch.segments(mode: .zone).map(\.on) == [false, false, true])

    // Walking can be switched off in the panel itself, and is on until it is.
    UserDefaults.standard.removeObject(forKey: "officeWalks")
    let fresh = officeWalks()
    setOfficeWalks(false)
    let off = officeWalks()
    UserDefaults.standard.removeObject(forKey: "officeWalks")
    check("office: walking is on until switched off, and the switch is kept", fresh && !off)
}

/// What a session keeps while it is away, and what makes it move: its desk, its place in the queue just after an
/// answer, its turn, and the counts on the floor.
@MainActor func officeKeepingTests() {
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    func pet(_ layout: OfficeLayout, _ id: String) -> OfficeLayout.Pet? { layout.pets.first { $0.id == id } }
    func queue(_ layout: OfficeLayout) -> [String] { layout.pets.filter { $0.zone == .queue }.sorted { $0.seat < $1.seat }.map(\.id) }
    let t0 = Date()

    // A desk kept for one that waits is let go when it closes.
    let desks = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("d", 4), resting: [])
    let asking = OfficeLayout(waiting: ["d1"], unread: [], busy: [], seen: ["d0", "d2", "d3"], resting: [], previous: desks)
    let closed = OfficeLayout(waiting: [], unread: [], busy: [], seen: ["d0", "d2", "d3"], resting: [], previous: asking)
    check("office: a desk kept for one that waits is let go when it closes", asking.reserved == ["d1": 1] && closed.reserved.isEmpty)
    // With two flagged, the one that has waited longer comes forward.
    let nine = OfficeLayout(waiting: ids("q", 7) + ["f7", "f8"], unread: [], busy: [], seen: [], resting: [])
    let next = OfficeLayout(waiting: Array(ids("q", 7).dropFirst()) + ["f7", "f8"], unread: [], busy: [], seen: ["q0"], resting: [], previous: nine)
    check(
        "office: with two flagged, the one that has waited longer comes forward when a place frees",
        queue(next) == Array(ids("q", 7).dropFirst()) + ["f7"] && pet(next, "f8")?.flagged == true)
    // The waiting chip counts those outside the room as well as those flagged in it.
    let many = OfficeLayout(waiting: ids("w", 34), unread: [], busy: [], seen: [], resting: [])
    check(
        "office: 34 waiting: seven in the queue, the chip says 27, four of them outside the room",
        many.chips.first { $0.kind == .waiting }?.count == 27 && many.outside[.waiting]?.count == 4 && many.pets.count == 30)
    // "Desks N" counts those at work and those looked at.
    let mixed = OfficeLayout(waiting: [], unread: [], busy: ids("b", 2), seen: ids("s", 5), resting: [])
    check("office: the desks' label counts those at work and those looked at", mixed.counts.desks == 7)

    // Answered from the queue (waiting → at work), it stays at its place there, at work and without its card,
    // for 45 s; then it goes home to the desk it left.
    let start = OfficeLayout(waiting: ["w1"], unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0)
    let asked = OfficeLayout(waiting: ["w1", "w0"], unread: [], busy: [], seen: ids("s", 3), resting: [], now: t0, previous: start)
    let answered = OfficeLayout(waiting: ["w1"], unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0 + 1, previous: asked)
    let later = OfficeLayout(waiting: ["w1"], unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0 + 44, previous: answered)
    let done = OfficeLayout(waiting: ["w1"], unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0 + 46, previous: later)
    let stays = [answered, later].allSatisfy { layout in
        pet(layout, "w0").map {
            $0.zone == .queue && $0.seat == 1 && $0.x == pet(asked, "w0")?.x && $0.kind == .work && $0.words.maxY < $0.foot - $0.tall
                && $0.words.height < 30
        } ?? false
    }
    check(
        "office: one answered from the queue stays at its place there for 45 s, at work, its card gone; then it goes to its own desk",
        pet(asked, "w0")?.zone == .queue && stays && pet(done, "w0").map { $0.zone == .desk && $0.seat == pet(start, "w0")?.seat } ?? false
            && queue(done) == ["w1"])
    let store = Store()
    store.readOnly = true
    store.sessions = [officeSession("w0", "busy", finished: 1), officeSession("w1", "waiting", finished: 60)]
        + ids("s", 3).map { officeSession($0, "idle", finished: 900) }
    check(
        "office: ...meanwhile the screen at its desk is lit: it is working",
        pet(start, "w0").map { OfficePainter.lit(store, answered).contains($0.seat) } ?? false)
    let again = OfficeLayout(waiting: ["w1", "w0"], unread: [], busy: [], seen: ids("s", 3), resting: [], now: t0 + 20, previous: answered)
    check(
        "office: ...asked again meanwhile, it has simply stayed: the same place, its card back",
        pet(again, "w0").map { $0.zone == .queue && $0.seat == 1 && $0.x == pet(asked, "w0")?.x && $0.kind == .waiting } ?? false
            && again.lingering.isEmpty)
    let three = OfficeLayout(
        waiting: ["w1", "x2"], unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0 + 5, previous: answered)
    let more = ["x2", "x3", "x4", "x5", "x6", "x7"]
    let due = OfficeLayout(
        waiting: ["w1"] + more, unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0 + 6, previous: three)
    check(
        "office: ...one more waiting takes the free place beside it; a seventh due for its place sends it home at once and comes forward",
        queue(three) == ["w1", "w0", "x2"] && queue(due) == ["w1"] + more
            && pet(due, "w0").map { $0.zone == .desk && $0.seat == pet(start, "w0")?.seat } ?? false)
    let after = OfficeLayout(
        waiting: ["w1", "x2"], unread: [], busy: ["w0"], seen: ids("s", 3), resting: [], now: t0 + 7, previous: due)
    check("office: ...and once gone home it does not come back to the queue", pet(after, "w0")?.zone == .desk)

    // Sixteen desks full and two looked at spilled to the back row. One goes to the queue: its desk stays empty,
    // kept, and nobody else moves; it comes back to the same desk, and still nobody else moves.
    let busy = ids("b", 6), seen = ids("s", 12), resting = ids("r", 4)
    let sixteen = OfficeLayout(waiting: [], unread: [], busy: busy, seen: seen, resting: resting, now: t0)
    let out = OfficeLayout(
        waiting: ["b2"], unread: [], busy: busy.filter { $0 != "b2" }, seen: seen, resting: resting, now: t0 + 1, previous: sixteen)
    let lingering = OfficeLayout(
        waiting: [], unread: [], busy: busy, seen: seen, resting: resting, now: t0 + 30, previous: out)
    let back = OfficeLayout(waiting: [], unread: [], busy: busy, seen: seen, resting: resting, now: t0 + 80, previous: lingering)
    func others(_ layout: OfficeLayout) -> Bool {
        sixteen.pets.filter { $0.id != "b2" }.allSatisfy { was in
            pet(layout, was.id).map { $0.zone == was.zone && $0.seat == was.seat } ?? false
        }
    }
    let deskOf = pet(sixteen, "b2")?.seat
    check(
        "office: sixteen desks full, one goes to the queue: its desk is kept empty, and nobody else moves",
        pet(sixteen, "s10")?.zone == .lounge && pet(out, "b2")?.zone == .queue && out.reserved["b2"] == deskOf && others(out)
            && !out.pets.contains { $0.zone == .desk && $0.seat == deskOf })
    check(
        "office: ...it comes back to the same desk, and nobody else has moved",
        pet(lingering, "b2")?.zone == .queue && pet(back, "b2").map { $0.zone == .desk && $0.seat == deskOf } ?? false && others(back))
    // With all sixteen taken or kept, one more looked at sits at the back rather than in a kept desk.
    let full = OfficeLayout(waiting: [], unread: [], busy: [], seen: ids("d", 16), resting: [])
    let first0 = OfficeLayout(waiting: ["d0"], unread: [], busy: [], seen: ids("d", 16).filter { $0 != "d0" }, resting: [], previous: full)
    let rest = ids("d", 16).filter { $0 != "d0" && $0 != "d7" }
    let then7 = OfficeLayout(waiting: ["d0", "d7"], unread: [], busy: [], seen: rest, resting: [], previous: first0)
    let crowded = OfficeLayout(waiting: ["d0", "d7"], unread: [], busy: [], seen: rest + ["n0"], resting: [], previous: then7)
    let returned = OfficeLayout(waiting: ["d0"], unread: [], busy: [], seen: rest + ["n0", "d7"], resting: [], previous: crowded)
    check(
        "office: with all sixteen desks taken or kept, a newcomer sits at the back, and the kept desks wait for their own",
        pet(crowded, "n0")?.zone == .lounge && crowded.reserved == ["d0": 0, "d7": 7] && pet(returned, "d7")?.seat == 7
            && pet(returned, "d7")?.zone == .desk)
}

/// Rooms laid out in long chains, each from the one before after a few random changes and some seconds: nobody is in
/// two places or none, and what is kept (a desk while away, a place in the queue just after an answer) holds.
@MainActor func officeChainTests() {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func random(_ n: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(n))
    }
    struct Open {
        var status: String
        var unread = false
        var old = false
        var since: Double
    }
    var broken: [String] = []
    var rooms = 0, lingered = 0, kept = 0
    for _ in 0..<40 {
        var open: [String: Open] = [:]
        var made = 0, clock = 1_000_000.0
        func add() {
            let status = ["waiting", "busy", "idle", "idle"][random(4)]
            let idle = status == "idle"
            open["p\(made)"] = Open(status: status, unread: idle && random(2) == 0, old: idle && random(3) == 0, since: clock)
            made += 1
            clock += 0.001
        }
        for _ in 0..<(20 + random(40)) { add() }
        var previous: OfficeLayout?
        for _ in 0..<150 {
            for _ in 0..<(1 + random(3)) {
                let keys = open.keys.sorted(), asking = keys.filter { open[$0]?.status == "waiting" }
                guard !keys.isEmpty else { add(); continue }
                let id = keys[random(keys.count)]
                switch random(9) {
                case 0: add()
                case 1: open[id] = nil
                case 2: open[id] = Open(status: "waiting", since: clock)
                case 3, 4: if !asking.isEmpty { open[asking[random(asking.count)]] = Open(status: "busy", since: clock) }  // answered
                case 5: if open[id]?.status == "busy" { open[id] = Open(status: "idle", unread: true, since: clock) }
                case 6: if open[id]?.unread == true { open[id]?.unread = false }
                case 7: if open[id]?.status == "idle" && open[id]?.unread == false { open[id]?.old = true }
                default: break
                }
            }
            clock += Double(random(25))
            let byAge = open.sorted { ($0.value.since, $0.key) < ($1.value.since, $1.key) }
            let waiting = byAge.filter { $0.value.status == "waiting" }.map(\.key)
            let unread = byAge.filter { $0.value.status == "idle" && $0.value.unread }.map(\.key)
            let busy = byAge.filter { $0.value.status == "busy" }.map(\.key)
            let seen = byAge.filter { $0.value.status == "idle" && !$0.value.unread && !$0.value.old }.map(\.key)
            let resting = byAge.filter { $0.value.status == "idle" && !$0.value.unread && $0.value.old }.map(\.key)
            let now = Date(timeIntervalSince1970: clock)
            let layout = OfficeLayout(
                waiting: waiting, unread: unread, busy: busy, seen: seen, resting: resting, now: now, previous: previous)
            rooms += 1
            func fail(_ what: String) { if broken.count < 8 { broken.append("room \(rooms): \(what)") } }
            let inRoom = layout.pets.map(\.id), outside = layout.outside.values.flatMap { $0 }
            if Set(inRoom).count != inRoom.count { fail("someone drawn twice") }
            for id in open.keys {
                let places = (inRoom.contains(id) ? 1 : 0) + (layout.behindDoorIDs.contains(id) ? 1 : 0) + outside.filter { $0 == id }.count
                if places != 1 { fail("\(id) is in \(places) places") }
            }
            if (inRoom + layout.behindDoorIDs).contains(where: { open[$0] == nil }) { fail("a closed one shown") }
            if layout.behindDoorIDs.contains(where: { !(seen + resting).contains($0) }) { fail("someone needy behind the door") }
            if layout.pets.count != min(30, open.count) { fail("\(layout.pets.count) in the room of \(open.count)") }
            let limits: [OfficeLayout.Zone: Int] = [.queue: 7, .sofa: 12, .desk: 16, .lounge: 20]
            for (zone, limit) in limits {
                let seats = layout.pets.filter { $0.zone == zone }.map(\.seat)
                if Set(seats).count != seats.count || seats.contains(where: { $0 < 0 || $0 >= limit }) { fail("seats in \(zone)") }
            }
            if Set(layout.pets.map { "\($0.x) \($0.foot)" }).count != layout.pets.count { fail("two on one spot") }
            // Desks kept: only for those now in the queue or on a sofa, one each, and nobody else sits at one.
            let away = Set(layout.pets.filter { $0.zone == .queue || $0.zone == .sofa }.map(\.id))
            if !Set(layout.reserved.keys).isSubset(of: away) { fail("a desk kept for one not away") }
            if Set(layout.reserved.values).count != layout.reserved.count { fail("two keep one desk") }
            if layout.pets.contains(where: { $0.zone == .desk && layout.reserved.values.contains($0.seat) }) {
                fail("someone at a kept desk")
            }
            for (id, seat) in previous?.reserved ?? [:] where away.contains(id) && layout.reserved[id] != seat {
                fail("\(id)'s desk let go while away")
            }
            for p in layout.pets where p.zone == .desk {
                if let owner = previous?.reserved.first(where: { $0.value == p.seat })?.key, owner != p.id, away.contains(owner) {
                    fail("\(p.id) took \(owner)'s desk")
                }
            }
            kept += layout.reserved.count
            // The queue: the first seven waiting, and besides them only those just answered there.
            let queued = layout.pets.filter { $0.zone == .queue }
            if Set(queued.filter { $0.kind == .waiting }.map(\.id)) != Set(waiting.prefix(7)) {
                fail("the queue is not the first seven waiting")
            }
            for p in queued where p.kind != .waiting {
                let since = layout.lingering[p.id]
                let wasThere = previous?.pets.contains { $0.id == p.id && $0.zone == .queue } ?? false
                if since == nil || !busy.contains(p.id) || !wasThere || now.timeIntervalSince(since!) >= OfficeLayout.linger {
                    fail("\(p.id) lingers wrongly")
                }
                lingered += 1
            }
            if Set(layout.lingering.keys) != Set(queued.filter { $0.kind != .waiting }.map(\.id)) {
                fail("lingering not the same as in the queue")
            }
            if let previous {
                for p in layout.pets {
                    guard let was = previous.pets.first(where: { $0.id == p.id }) else { continue }
                    if was.zone == p.zone && p.zone != .queue && was.seat != p.seat { fail("\(p.id) changed seat in its zone") }
                    if p.zone == .desk, was.zone != .desk, let mine = previous.reserved[p.id], p.seat != mine {
                        fail("\(p.id) not back at its desk")
                    }
                }
            }
            previous = layout
        }
    }
    print("      \(rooms) rooms in chains: \(lingered) times one answered stayed in the queue, \(kept) desks kept")
    check(
        "office: \(rooms) rooms laid out in chains: nobody twice or nowhere, kept desks kept, answered ones stay only as long as they may",
        broken.isEmpty && lingered > 0 && kept > 0)
    for line in broken { print("      " + line) }
}

/// The way a pet walks: straight legs across and down the room, through the aisle.
@MainActor func officeRouteTests() {
    func legsStraight(_ route: [CGPoint]) -> Bool { zip(route, route.dropFirst()).allSatisfy { $0.x == $1.x || $0.y == $1.y } }
    for height in [CGFloat(764), 979] {
        let layout = OfficeLayout(
            waiting: ["w0", "w1"], unread: ["u0", "u1"], busy: ["b0", "b1"], seen: (0..<10).map { "s\($0)" },
            resting: (0..<12).map { "r\($0)" }, height: height)
        let spots = layout.pets.map { layout.spot(of: $0) } + [OfficeLayout.doorSpot]
        var straight = true, ends = true
        for a in spots {
            for b in spots {
                let route = layout.route(from: a, to: b)
                straight = straight && legsStraight(route)
                ends = ends && route.first == a.point && route.last == b.point
            }
        }
        let at = "office \(Int(height)) high"
        check("\(at): every route is made of straight legs, across or down", straight)
        check("\(at): ...and runs from one place to the other", ends)
        // Three aisles: along each wall and down the centre; a route takes whichever makes it shortest.
        var inside = true
        for tall in [CGFloat(50), 70, 90] {
            for a in spots {
                for b in spots { inside = inside && layout.route(from: a, to: b, tall: tall).allSatisfy { $0.x >= 0 && $0.x <= 1194 } }
            }
        }
        check("\(at): no route leaves the room", inside)
        let row = layout.deskFloors[0] + 10, right = OfficeLayout.aisles(tall: 70)[2], left = OfficeLayout.aisles(tall: 70)[1]
        let outer = OfficeSpot(point: CGPoint(x: OfficeLayout.deskLeft(7) + 88, y: row), lane: .row)
        let inDoor = layout.route(from: OfficeLayout.doorSpot, to: outer)
        check(
            "\(at): from the door to the right block's outer desk it goes down the right wall",
            inDoor.contains(CGPoint(x: right, y: OfficeLayout.doorLane)) && inDoor.contains(CGPoint(x: right, y: row)))
        let centreDesk = OfficeSpot(point: CGPoint(x: OfficeLayout.deskLeft(3) + 88, y: row), lane: .row)
        check(
            "\(at): from a centre desk to the queue it still goes down the centre",
            layout.route(from: centreDesk, to: layout.spot(of: layout.pets.first { $0.id == "w1" }!)).contains { $0.x == 597 })
        // From the first sofa's last seat to two desks of the left block: the left wall or the centre, whichever is
        // shorter, worked out here leg by leg. A sofa seat is reached along the sofas' own floor, as a desk is.
        let sofa = OfficeSpot(point: CGPoint(x: 242, y: layout.sofaFloor - 4), lane: .row)
        let shorter = [0, 2].allSatisfy { column in
            let desk = OfficeSpot(point: CGPoint(x: OfficeLayout.deskLeft(column) + 88, y: row), lane: .row)
            let down = sofa.point.y - row
            let viaLeft = abs(sofa.point.x - left) + down + abs(desk.point.x - left)
            let viaCentre = abs(sofa.point.x - 597) + down + abs(desk.point.x - 597)
            let route = layout.route(from: sofa, to: desk)
            return route.contains(CGPoint(x: viaLeft < viaCentre ? left : 597, y: row))
                && abs(OfficeLayout.length(route) - min(viaLeft, viaCentre)) < 0.01
        }
        check("\(at): from the first sofa to a left-block desk: the left wall or the centre, whichever is shorter", shorter)
        let desk = layout.pets.first { $0.id == "s0" }!, queue = layout.pets.first { $0.id == "w1" }!
        let toQueue = layout.route(from: layout.spot(of: desk), to: layout.spot(of: queue))
        check(
            "\(at): from a desk to the queue it goes down the centre aisle, between the sofas, and along the queue's own floor",
            toQueue == [CGPoint(x: desk.x, y: desk.foot), CGPoint(x: 597, y: desk.foot), CGPoint(x: 597, y: queue.foot), CGPoint(x: queue.x, y: queue.foot)])
        let neighbour = layout.pets.first { $0.id == "s1" }!
        let r0 = layout.spot(of: layout.pets.first { $0.id == "r0" }!), r3 = layout.spot(of: layout.pets.first { $0.id == "r3" }!)
        check(
            "\(at): to a seat in the same row it is one leg",
            layout.route(from: layout.spot(of: desk), to: layout.spot(of: neighbour)).count == 2 && layout.route(from: r0, to: r3).count == 2)
        let out = layout.route(from: layout.spot(of: desk), to: OfficeLayout.doorSpot)
        check(
            "\(at): out through the door along y 92, in front of it at 1042, 84",
            out.last == CGPoint(x: 1042, y: 84) && out.dropLast().last == CGPoint(x: 1042, y: 92) && out.contains(CGPoint(x: 597, y: 92)))
        let comeIn = layout.route(from: OfficeLayout.doorSpot, to: layout.spot(of: desk))
        check(
            "\(at): in through the door it steps down to y 92 and goes along it to the aisle",
            Array(comeIn.prefix(3)) == [CGPoint(x: 1042, y: 84), CGPoint(x: 1042, y: 92), CGPoint(x: 597, y: 92)])
        let back = layout.pets.first { $0.id == "r11" }!
        let toBack = layout.route(from: layout.spot(of: queue), to: layout.spot(of: back))
        check(
            "\(at): to a seat at the back it walks up the aisle and along that row's floor",
            toBack.contains(CGPoint(x: 597, y: back.foot)) && toBack.dropLast().last == CGPoint(x: 597, y: back.foot))
        // On a wall aisle a pet keeps its whole body inside the room: the aisle moves in for a big one.
        check(
            "\(at): the wall aisles keep each size of pet inside the room, close to the walls",
            [CGFloat(50), 70, 90].allSatisfy { tall in
                let aisles = OfficeLayout.aisles(tall: tall)
                return aisles[0] == 597 && aisles[1] - tall * 0.55 >= 0 && aisles[2] + tall * 0.55 <= 1194
                    && aisles[1] <= 60 && aisles[2] >= 1134
            })
        // Somewhere in the middle of a walk, changing its mind: from where it is, still in straight legs.
        let midway = OfficeSpot(point: CGPoint(x: 597, y: 400), lane: .row)
        let rerouted = layout.route(from: midway, to: layout.spot(of: neighbour))
        check(
            "\(at): changing its mind half way, it sets off from where it is",
            rerouted.first == midway.point && rerouted.last == layout.spot(of: neighbour).point && legsStraight(rerouted))
    }
    // A pet that reaches no further than 27 pt from its feet walks right by the walls; a wider one keeps
    // a point clear of them.
    check(
        "office: the wall aisles are at 28 and 1166, moved in only as far as a pet reaches past them",
        OfficeLayout.aisles(body: (left: 20, right: 27)) == [597, 28, 1166]
            && OfficeLayout.aisles(body: (left: 40, right: 30)) == [597, 41, 1163])
    officeWallAisleTests()
}

/// Every pet that is cut, at each size the room draws pets, in each pose it may set off in: placed as
/// the office places it (scaled by the pose's still frame, centred on its drawn part), on the wall
/// aisles the office gives that pet, every running frame (and the still one) is drawn within 0...1194.
/// Only cut frames can say: on a machine where the panel has never shown the office there are none.
@MainActor func officeWallAisleTests() {
    let what = "office: on a wall aisle no pet, at any size, in any running frame, crosses the room's edge"
    let cut = Pets.shared.ids.filter { OfficePets.shared.isCut($0) }
    guard cut.count >= 3 else { return skipped("no pet frames", what) }
    // The running frames are row 7 as cut and the facing table's frames each way (`turned` below), not rows 1 and 2 as cut.
    let stills = [(7, 1), (6, 2), (6, 0), (4, 2), (3, 2), (0, 0), (0, 1)], running = [7].flatMap { row in (0..<8).map { (row, $0) } }
    var worst = (left: CGFloat.infinity, right: -CGFloat.infinity), furthest = (left: CGFloat(0), right: CGFloat(1194))
    for pet in cut {
        guard let idle = OfficePets.shared.frame(pet, row: 0, column: 0) else { continue }
        for tall in [CGFloat(50), 70, 90] {
            for (row, column) in stills {
                guard let still = OfficePets.shared.frame(pet, row: row, column: column),
                    let extent = OfficePets.shared.extent(pet, stills: [(row, column)])
                else { continue }
                let small = still.tall * 5 < idle.tall * 4
                let scale = min(tall / CGFloat(small ? still.tall : idle.tall), tall * 1.1 / CGFloat(small ? still.wide : idle.wide))
                let centre = CGFloat(still.left + still.right + 1) / 2, spriteX = (-centre * scale * 2).rounded() / 2
                let aisles = OfficeLayout.aisles(body: OfficeLayout.body(spriteX: spriteX, extent: extent, scale: scale))
                furthest = (max(furthest.left, aisles[1]), min(furthest.right, aisles[2]))
                // And the running frames as the facing table gives them (a mirrored row reaches the other way).
                let turned = [OfficePets.right, OfficePets.left].flatMap { facing in (0..<8).compactMap { OfficePets.shared.runFrame(pet, facing: facing, column: $0) } }
                for f in (running + [(row, column)]).compactMap({ OfficePets.shared.frame(pet, row: $0.0, column: $0.1) }) + turned {
                    let left = aisles[1] + spriteX + CGFloat(f.left) * scale - 0.5
                    let right = aisles[2] + spriteX + CGFloat(f.right + 1) * scale + 0.5
                    worst = (min(worst.left, left), max(worst.right, right))
                }
            }
        }
    }
    print(
        String(
            format: "      on the wall aisles, %d pets: drawn from %.1f to %.1f; aisles moved in as far as %.0f and %.0f",
            cut.count, worst.left, worst.right, furthest.left, furthest.right))
    check(what, worst.left >= 0 && worst.right <= 1194)
}

/// The still picture and the live view are made of the same pieces, and look the same at rest.
@MainActor func officePieceTests() {
    let now = Date()
    let store = officeStore()
    let layout = OfficePainter.layout(store, now: now)
    // The picture is the room with each pet's shadow, sprite and words on it, front ones last.
    if let picture = OfficePainter.picture(store, layout, now: now), let room = OfficePainter.room(store, layout, scale: 1) {
        let c = OfficeCanvas(layout.size)
        c.image(room, in: CGRect(origin: .zero, size: layout.size))
        for place in layout.pets.sorted(by: { ($0.foot, $0.x) < ($1.foot, $1.x) }) {
            guard let s = store.sessions.first(where: { $0.id == place.id }) else { continue }
            let figure = OfficePainter.figure(store, s, place, now: now)
            if let shadow = figure.shadow { c.image(shadow.image, in: shadow.rect) }
            c.image(figure.sprite.image, in: figure.sprite.rect, alpha: figure.sprite.alpha)
            if let words = OfficePainter.words(store, s, place, layout, now: now, scale: 1) { c.image(words.image, in: words.rect) }
        }
        check(
            "office: the still picture is the room with each pet's pieces on it, and nothing else",
            c.image().map { Pixels($0).data == Pixels(picture).data } ?? false && officeDifference(picture, room) > 0.005)
    } else {
        check("office: the still picture is the room with each pet's pieces on it, and nothing else", false)
    }

    // The live view: the room, and over it one layer per pet holding its shadow, sprite and words,
    // the nearer ones in front.
    let view = OfficeView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    view.still = true
    view.update(store)
    let layers = officeStage(view)?.sublayers ?? []
    let figures = layers.dropFirst().dropLast()
    check(
        "office: live, the room is one layer, each pet one more, holding its shadow, sprite and words, and the chips one over them",
        layers.first?.name == "room" && layers.last?.name == "chips" && figures.count == layout.pets.count
            && figures.allSatisfy { $0.sublayers?.map(\.name) == ["shadow", "sprite", "words"] }
            && Set(figures.compactMap(\.name)) == Set(layout.pets.map(\.id)))
    let feet = figures.compactMap { f in layout.pets.first { $0.id == f.name }?.foot }
    check(
        "office: ...ordered by where their feet are, further down in front",
        !feet.isEmpty && feet.count == figures.count && zip(feet, feet.dropFirst()).allSatisfy { $0 <= $1 }
            && figures.allSatisfy { f in layout.pets.first { $0.id == f.name }.map { $0.foot == f.zPosition } ?? false })

    // The room is painted again only for what it shows: lit screens, couches, the door's number, the
    // floor's counts. Pointing changes none of them.
    let painted = officeRoomLayer(view)?.contents as AnyObject?
    store.hovered = "o-seen"
    view.update(store)
    let pointed = officeRoomLayer(view)?.contents as AnyObject?
    store.hovered = nil
    store.seen["o-seen"] = 0  // news again: from its desk to the sofa
    view.update(store)
    let walked = OfficePainter.layout(store, now: Date()).pets.first { $0.id == "o-seen" }?.zone == .sofa
    check(
        "office: being pointed at leaves the room unpainted; a change of state repaints it for its floor's counts",
        walked && painted != nil && pointed === painted && officeRoomLayer(view)?.contents as AnyObject? !== painted)
    store.sessions = store.sessions.map { $0.id == "o-seen" ? officeSession("o-seen", "busy", finished: 5) : $0 }
    view.update(store)
    check("office: a screen lighting up paints the room again", officeRoomLayer(view)?.contents as AnyObject? !== painted)

    // Furniture follows the room's height: probes in a room 979 high, at spots the five pets leave clear.
    let tall = OfficePainter.layout(officeStore(), now: now, height: 979, scale: 1134 / 1194)
    if let picture = OfficePainter.picture(officeStore(), tall, now: now, scale: 1134 / 1194) {
        let pixels = Pixels(picture)
        check(
            "office: 979 high, the back couch, a second-row desk, the rug and the sofa are where that room has them",
            same(pixels.at(60, 161 - 3), 0x708491) && same(pixels.at(60, 564 - 31), 0xD5C8B3)
                && same(pixels.at(345, 800 + 60), 0x394957) && same(pixels.at(60, 729 - 7), 0x91ACBF))
    } else {
        check("office: 979 high, the back couch, a second-row desk, the rug and the sofa are where that room has them", false)
    }

    // The waiting card's name as painted: a six-character name reaches the end of its width, uncut.
    let six = Store()
    six.readOnly = true
    six.sessions = (0..<6).map { i in
        Session(
            id: "c\(i)", pid: 1, project: "demo-server", name: i == 0 ? "云朵风车彩虹" : "等 \(i)", status: "waiting",
            since: now.addingTimeInterval(-Double(600 - i)), summary: "要不要接着做？")
    }
    let sixRoom = OfficePainter.layout(six, now: now, scale: 0.75)
    if let card = sixRoom.pets.first(where: { $0.id == "c0" })?.words, let shrunk = OfficePainter.picture(six, sixRoom, now: now, scale: 0.75) {
        let name = OfficeLayout.cardLines(card, scale: 0.75, asks: sixRoom.asks).name, pixels = Pixels(shrunk)
        let wide = OfficeCanvas(CGSize(width: 1, height: 1)).width(of: "云朵风车彩虹", size: OfficeLook.type(12.5, scale: 0.75))
        var darkest: UInt32 = 0xFF
        for y in stride(from: name.minY + 2, to: name.maxY - 2, by: 0.5) {
            for x in stride(from: name.minX + wide - 12, to: name.minX + wide, by: 0.5) { darkest = min(darkest, pixels.at(x, y) >> 16) }
        }
        check("office: at 75% with six waiting, the six-character name is painted to its last character", darkest < 0xB0)
    } else {
        check("office: at 75% with six waiting, the six-character name is painted to its last character", false)
    }

    // Two lines of what it asks wherever the room's height, shared out over its six gaps, keeps 3 pt in each with them;
    // one otherwise. The gap under the wall is one of the six: a pose 1.1 times as tall as a back-row place (55) under
    // the wall's 70.
    func room(_ height: CGFloat) -> OfficeLayout {
        OfficeLayout(waiting: ["w0", "w1", "w2"], unread: [], busy: [], seen: [], resting: [], height: height, scale: 1)
    }
    let first = (764...1000).first { room(CGFloat($0)).asks == 2 }.map { CGFloat($0) } ?? 0
    let underWall = { (r: OfficeLayout) in r.loungeFloors[0] - 3 - 55 - 70 }
    check(
        "office: two lines of what it asks where the gaps keep 3 pt each with them",
        first > 764 && underWall(room(first)) >= 3 && (Int(first)...1000).allSatisfy { room(CGFloat($0)).asks == 2 })
    check("office: ...one a point lower, and at 764", room(first - 1).asks == 1 && room(764).asks == 1)
    check("office: ...and two in the user's 979-high room", OfficeLayout(waiting: ["w0"], unread: [], busy: [], seen: [], resting: [], height: 979, scale: 1134 / 1194).asks == 2)

    officeParityTests()
}

/// With motion off, the live view at rest shows what the still picture shows, real pets and all.
@MainActor func officeParityTests() {
    let now = Date()
    let store = Store()
    store.readOnly = true
    store.sessions = officeSessions([
        ("pw", "waiting", 3, 300), ("pn", "idle", 4, 120), ("pb", "busy", 3, 60), ("ps", "idle", 4, 900), ("pr", "idle", 6, 9 * 3600.0),
    ])
    for s in store.sessions where s.id.hasPrefix("ps") || s.id.hasPrefix("pr") { store.seen[s.id] = now.timeIntervalSince1970 }
    guard officeDealCutPets(store) else {
        return skipped("no pet frames", "the live view is not compared with the still picture")
    }
    for size in [CGSize(width: 1194, height: 764), CGSize(width: 1134, height: 930)] {
        let at = "office \(Int(size.width))x\(Int(size.height))"
        let fit = OfficeFit(size)
        let layout = OfficePainter.layout(store, now: now, height: fit.height, scale: fit.scale)
        let view = OfficeView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        let real = layout.pets.allSatisfy { place in
            store.sessions.first { $0.id == place.id }.map { OfficePainter.figure(store, $0, place, now: now).pet != nil } ?? false
        }
        guard let live = view.image(), let still = OfficePainter.picture(store, layout, now: now, scale: fit.scale),
            let room = OfficePainter.room(store, layout, scale: fit.scale), let shown = officeFitted(still, size: size, at: fit.picture),
            let bare = officeFitted(room, size: size, at: fit.picture)
        else {
            check("\(at): at rest the live view is the still picture", false)
            continue
        }
        let inside = fit.picture.insetBy(dx: 1, dy: 1)
        let seen = Pixels(live), meant = Pixels(shown), empty = Pixels(bare)
        let apart = officeDifference(seen, meant, in: inside)
        // Each pet on its own too: one drawn wrong is a small part of the whole picture.
        let each = layout.pets.map { officeDifference(seen, meant, in: fit.rect($0.frame).intersection(inside)) }
        let there = layout.pets.map { officeDifference(seen, empty, in: fit.rect($0.body).intersection(inside)) }
        let share = { (part: Double, digits: Int) in String(format: "%.\(digits)f", part * 100) }
        print(
            "      \(at): \(share(apart, 3))% of pixels differ from the still picture, at most \(share(each.max() ?? 1, 2))% of one pet's;"
                + " each pet changes at least \(share(there.min() ?? 0, 1))% of its body's box")
        check("\(at): at rest the live view is the still picture, to within 1% of its pixels", layout.pets.count == 20 && real && apart <= 0.01)
        check("\(at): ...and every pet is drawn as in the still picture, to within 5% of its own box", each.count == 20 && each.allSatisfy { $0 < 0.05 })
        check("\(at): ...and there are real pets in it, not just the room", there.count == 20 && there.allSatisfy { $0 > 0.05 })
    }
}

/// Where a picture has anything drawn, in its pixels.
func officeInkBox(_ image: CGImage) -> CGRect? {
    let pixels = Pixels(image)
    var left = pixels.width, right = -1, top = pixels.height, bottom = -1
    for y in 0..<pixels.height {
        for x in 0..<pixels.width where pixels.data[(y * pixels.width + x) * 4 + 3] > 0 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
        }
    }
    return right >= left ? CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1) : nil
}

/// Whether two frames are the same picture: the cache may have let one go and scaled it again.
/// A pet's running frames one way at `scale`, as the office's walk shows them: the facing table's row, mirrored where it
/// says so (made here afresh; `officeSameFrame` compares the pixels).
@MainActor func officeRunScaled(_ pet: String, facing: Int, scale: CGFloat) -> [CGImage] {
    let how = OfficePets.runRow(pet, facing: facing)
    let frames = (0..<8).compactMap { OfficePets.shared.scaled(pet, row: how.row, column: $0, scale: scale) }
    return how.mirrored ? frames.compactMap(OfficePets.mirrored) : frames
}

func officeSameFrame(_ a: Any?, _ b: CGImage) -> Bool {
    guard let a = a.map({ $0 as AnyObject }), CFGetTypeID(a) == CGImage.typeID else { return false }
    let image = a as! CGImage
    return image === b || (image.width == b.width && image.height == b.height && image.dataProvider?.data == b.dataProvider?.data)
}

/// Where a layer's walk puts it at a moment, from the walk's own keyframes: before it sets off it is
/// at the start, after it arrives at the end.
@MainActor func officeWalkPoint(_ layer: CALayer?, at time: CFTimeInterval) -> CGPoint? {
    guard let walk = layer?.animation(forKey: "walk") else { return layer?.position }
    let t = max(0, min(1, (time - walk.beginTime) / walk.duration))
    if let move = walk as? CAKeyframeAnimation, let values = move.values?.compactMap({ ($0 as? NSValue)?.pointValue }),
        let times = move.keyTimes?.map(\.doubleValue), values.count == times.count
    {
        for i in 1..<values.count where t <= times[i] {
            let part = times[i] > times[i - 1] ? (t - times[i - 1]) / (times[i] - times[i - 1]) : 1
            return CGPoint(x: values[i - 1].x + (values[i].x - values[i - 1].x) * part, y: values[i - 1].y + (values[i].y - values[i - 1].y) * part)
        }
        return values.last
    }
    return layer?.position
}

/// The moving room recorded every so often, for reading by eye: a sheet of small pictures, each with its time.
@MainActor func officeSheet(_ view: NSView, seconds: Double, every: Double, to path: String) {
    officeSaveSheet(officeRecord(view, seconds: seconds, every: every), size: view.bounds.size, to: path)
}

/// Pictures of the moving room every so often for so long, each labelled with its time and `label`.
@MainActor func officeRecord(_ view: NSView, seconds: Double, every: Double, label: String = "") -> [(CGImage, String)] {
    var frames: [(CGImage, String)] = []
    let start = Date()
    RunLoop.current.run(until: start.addingTimeInterval(0.02))  // the whole tree's picture of this moment catches up
    while Date().timeIntervalSince(start) <= seconds {
        if let image = officeMoment(view, pixels: 1) {
            frames.append((image, String(format: "%.2f s", Date().timeIntervalSince(start)) + label))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(every))
    }
    return frames
}

@MainActor func officeSaveSheet(_ frames: [(CGImage, String)], size: CGSize, to path: String) {
    let cell = CGSize(width: size.width * 0.3, height: size.height * 0.3 + 14), columns = 4
    let c = OfficeCanvas(CGSize(width: cell.width * CGFloat(columns), height: cell.height * CGFloat((frames.count + columns - 1) / columns)))
    c.fill(0, 0, cell.width * CGFloat(columns), cell.height * CGFloat((frames.count + columns - 1) / columns), 0x101010)
    for (i, frame) in frames.enumerated() {
        let x = CGFloat(i % columns) * cell.width, y = CGFloat(i / columns) * cell.height
        c.ctx.interpolationQuality = .medium
        c.ctx.saveGState()
        c.ctx.translateBy(x: x, y: y + cell.height)
        c.ctx.scaleBy(x: 1, y: -1)
        c.ctx.draw(frame.0, in: CGRect(x: 1, y: 1, width: cell.width - 2, height: cell.height - 16))
        c.ctx.restoreGState()
        c.text(frame.1, in: CGRect(x: x + 4, y: y, width: cell.width - 8, height: 14), size: 10, 0xFFFFFF)
    }
    save(c.image(), path)
}

/// Pose loops, walking, the door, when nothing moves, and dragging the window's edge.
@MainActor func officeMotionTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func until(_ seconds: Double, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    }
    func animated(_ layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        return (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animated)
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: view.frame.size), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }
    let frame = CGRect(x: 0, y: 0, width: 1194, height: 764)
    func sprite(_ view: NSView, _ id: String) -> CALayer? { officePart(view, id, "sprite") }

    // A pose that loops plays on the sprite's contents, frame by frame; one frame does not move.
    check("office: the scaled frames are kept within 48 MB", OfficePets.shared.costLimit == 48 * 1024 * 1024)
    let posing = officeStore()
    if officeDealCutPets(posing) {
        let view = OfficeView(frame: frame)
        let shown = window(view)
        defer { shown.orderOut(nil) }
        // NUDGE: a waiting pet stands and knocks now; its row-6 loop is what `waitingNudge` = NO brings back, so this checks that.
        WaitingNudge.override = false
        defer { WaitingNudge.override = nil }
        view.update(posing)
        until(2) { sprite(view, "o-wait")?.animation(forKey: "loop") != nil }  // frames not scaled yet come from the background
        let loop = sprite(view, "o-wait")?.animation(forKey: "loop") as? CAKeyframeAnimation
        let pose = posing.pose(of: posing.sessions[0]).sheet
        check(
            "office: one waiting loops its pose on the sprite, frame by frame",
            loop?.keyPath == "contents" && loop?.calculationMode == .discrete && loop?.values?.count == pose.frames
                && abs((loop?.duration ?? 0) - Double(pose.frames) * pose.ms / 1000) < 0.001 && loop?.repeatCount == .infinity)
        check("office: ...one resting does not move at all", animated(officeFigure(view, "o-rest")).isEmpty)
        // A window can take its layers' animations with it: the loop must come back on its own.
        sprite(view, "o-wait")?.removeAllAnimations()
        view.removeFromSuperview()
        let away = sprite(view, "o-wait")?.animation(forKey: "loop") == nil
        shown.contentView = view
        check(
            "office: ...not looping while out of its window, and looping again when the office comes back to it",
            away && sprite(view, "o-wait")?.animation(forKey: "loop") != nil)
        shown.contentView = nil
    } else {
        skipped("no pet frames", "pose loops are not checked")
    }

    // Nobody waiting, working or just finished: nothing runs at all, motion or not.
    let calm = Store()
    calm.readOnly = true
    calm.sessions = officeSessions([("c", "idle", 4, 900), ("z", "idle", 4, 9 * 3600.0), ("h", "idle", 1, 300)])
    for s in calm.sessions where s.id != "h0" { calm.seen[s.id] = Date().timeIntervalSince1970 }
    _ = officeDealCutPets(calm)
    let calmView = OfficeTestView(frame: frame)
    let calmWindow = window(calmView)
    calmView.update(calm)
    check(
        "office: with nobody waiting, working or just finished, no layer has an animation",
        officeStage(calmView)?.sublayers?.count == 11 && animated(officeStage(calmView)).isEmpty)
    calmWindow.orderOut(nil)
    calmWindow.contentView = nil
    let stillView = OfficeView(frame: frame)
    stillView.still = true
    let busy = officeStore()
    _ = officeDealCutPets(busy)
    stillView.update(busy)
    check(
        "office: held still, even the ones waiting and working do not move",
        (officeStage(stillView)?.sublayers?.count ?? 0) == 7 && animated(officeStage(stillView)).isEmpty)

    // Off the screen nobody walks: places are just set, with a short cross-fade.
    let unseen = officeStore()
    let hidden = OfficeView(frame: frame)
    let hiddenWindow = window(hidden)
    hidden.update(unseen)
    unseen.sessions = unseen.sessions.map { $0.id == "o-seen" ? officeSession("o-seen", "waiting", finished: 1) : $0 }
    hidden.update(unseen)
    let target = OfficePainter.layout(unseen, now: Date()).pets.first { $0.id == "o-seen" }
    let fade = officeStage(hidden)?.animation(forKey: kCATransition) as? CATransition
    check(
        "office: where nobody can see it, a pet changing place is just set there, with a 0.2 s cross-fade",
        hidden.onScreen == false && officeFigure(hidden, "o-seen")?.animation(forKey: "walk") == nil
            && officeFigure(hidden, "o-seen")?.position == target.map { CGPoint(x: $0.x, y: $0.foot) } && fade?.duration == 0.2)
    hiddenWindow.orderOut(nil)
    hiddenWindow.contentView = nil  // left in a window, a commit would lay it out again and it would remember its own room

    // Walking: four in the queue, ten at desks and sixteen at the back fill the room. Then two at desks start waiting
    // (desk to the queue), two new ones arrive waiting (in through the door; the eighth waiting takes a desk, flagged),
    // one closes (out through the door), and the oldest at the back is pushed out by the limit of thirty (it fades where
    // it sat: that is not its own doing).
    let walking = Store()
    walking.readOnly = true
    walking.sessions = officeSessions([("q", "waiting", 4, 900), ("s", "idle", 10, 600), ("r", "idle", 16, 9 * 3600.0)])
    for s in walking.sessions where !s.id.hasPrefix("q") { walking.seen[s.id] = Date().timeIntervalSince1970 }
    walking.sessions += [officeSession("w1", "waiting", finished: 3), officeSession("w2", "waiting", finished: 2)]
    // The walkers get the same pets every run: which wall aisle a pet takes, and so who goes when, depends on its reach.
    let fixed = officeFixedPets(5)
    let giving = Dictionary(uniqueKeysWithValues: zip(["s0", "s1", "s2", "w1", "w2"], fixed))
    let dealt = fixed.count == 5 && officeDealCutPets(walking, giving: giving)
    walking.sessions.removeLast(2)
    let view = OfficeTestView(frame: frame)
    let shown = window(view)
    defer { shown.orderOut(nil) }
    view.update(walking)
    let before = OfficePainter.layout(walking, now: Date())
    func spot(_ layout: OfficeLayout, _ id: String) -> OfficeSpot { layout.spot(of: layout.pets.first { $0.id == id }!) }
    check(
        "office: on first load everyone is simply in place",
        before.pets.count == 30 && before.pets.allSatisfy { officeFigure(view, $0.id)?.animation(forKey: "walk") == nil }
            && officeFigure(view, "s0")?.position == spot(before, "s0").point)
    // Another office drawn meanwhile, for another store (a snapshot, say), moves nobody here.
    OfficeView(frame: frame).update(officeStore())
    let leaving = walking.sessions.first { $0.id == "s1" }!
    walking.sessions = walking.sessions.compactMap { s in
        switch s.id {
        case "s0": return officeSession("s0", "waiting", finished: 5)
        case "s2": return officeSession("s2", "waiting", finished: 4)
        case "s1": return nil
        default: return s
        }
    } + [officeSession("w1", "waiting", finished: 3), officeSession("w2", "waiting", finished: 2)]
    let started = CACurrentMediaTime()
    view.update(walking)
    // In the panel the store's tick reaches the view inside a pass of the run loop, which hands the
    // new animations to Core Animation at its end; called from here, that has to be asked for.
    CATransaction.flush()
    let updating = CACurrentMediaTime() - started
    let after = OfficePainter.layout(walking, now: Date())
    func at(_ id: String) -> CGPoint? { officeFigure(view, id)?.presentation()?.position }
    func walk(_ id: String) -> CAKeyframeAnimation? { officeFigure(view, id)?.animation(forKey: "walk") as? CAKeyframeAnimation }
    // Each one's route, from its walk: a wall aisle is that pet's own.
    var routes: [String: [CGPoint]] = [:]
    for id in ["s0", "s1", "s2", "w1", "w2"] { routes[id] = walk(id)?.values?.compactMap { ($0 as? NSValue)?.pointValue } }
    print("      six set off walking in \(String(format: "%.0f", updating * 1000)) ms (this build is not optimised)")
    // One at a time onto each aisle, at least 0.35 s apart, the waiting before the one leaving; the first on each
    // aisle sets off at once; none comes within 20 pt of another there.
    let walkers = ["s0", "s2", "s1", "w1", "w2"]
    let passages = Dictionary(uniqueKeysWithValues: walkers.compactMap { id in officePassage(walk(id)).map { (id, $0) } })
    let firsts = Dictionary(grouping: passages.values, by: \.aisle).values.compactMap { $0.min { $0.enters < $1.enters } }
    let leaverLast = passages["s1"].map { leaver in
        passages.filter { $0.key != "s1" && $0.value.aisle == leaver.aisle }.allSatisfy { $0.value.enters < leaver.enters }
    } ?? false
    // "At once" is within the update that set them off: the stagger counts from there. Unwarmed (this suite's motion checks
    // run alone) that update reads every walker's frames from disk and takes a few hundred milliseconds.
    let atOnce = firsts.allSatisfy { first in
        passages.first { $0.value.enters == first.enters }.map { (walk($0.key)?.beginTime ?? 0) - started < updating + 0.05 } ?? false
    }
    check(
        "office: onto each aisle one at a time, 0.35 s apart or more, the waiting before the one leaving; the first sets off at once",
        passages.count == 5 && officeSpaced(view, walkers).spaced && officeSpaced(view, walkers).sharing >= 2 && leaverLast && atOnce
            && !officeCrowded(view, walkers))
    let pushed = officeFigure(view, "r15")
    check(
        "office: one pushed behind the door by the limit of thirty does not walk: it fades out where it sat",
        after.behindDoorIDs == ["r15"] && pushed?.animation(forKey: "walk") == nil && pushed?.animation(forKey: "door") != nil
            && pushed?.position == spot(before, "r15").point)
    check(
        "office: the eighth waiting, new, walks in to a desk and waits there flagged",
        after.pets.first { $0.id == "w2" }.map { $0.zone == .desk && $0.flagged } ?? false && walk("w2") != nil)
    let first = started
    until(1.4) { CACurrentMediaTime() - first > 1.4 }
    func midway(_ id: String) -> Bool {
        guard let route = routes[id], let p = at(id), let along = officeAlong(p, route) else { return false }
        return along > 2 && along < officeLength(route) - 2
    }
    check(
        "office: after a change of state the pet is on its way, strictly between its desk and its place in the queue",
        after.pets.first { $0.id == "s0" }?.zone == .queue && midway("s0"))
    check(
        "office: ...in steps of its running frames, its words hidden",
        !dealt || (sprite(view, "s0")?.animation(forKey: "steps") != nil && (officePart(view, "s0", "words")?.presentation()?.opacity ?? 1) < 0.05))
    // The running frames by leg: to the right where its first leg goes right, to the left where it goes left.
    func steps(_ id: String, _ session: Session, _ place: OfficeLayout.Pet) -> Bool {
        guard let pet = walking.petBySession[id], let steps = sprite(view, id)?.animation(forKey: "steps") as? CAKeyframeAnimation,
            let values = steps.values, let times = steps.keyTimes?.map(\.doubleValue), let route = routes[id], route.count > 1,
            route[1].x != route[0].x
        else { return false }
        let row = route[1].x > route[0].x ? 1 : 2
        let scale = OfficePainter.figure(walking, session, place, now: Date()).scale
        let frames = officeRunScaled(pet, facing: row, scale: scale)
        let firstLeg = Double(hypot(route[1].x - route[0].x, route[1].y - route[0].y) / officeLength(route))
        let early = zip(values, times).filter { $0.1 < firstLeg - 0.001 }.map(\.0)  // the next leg starts right at its end
        return !early.isEmpty && early.allSatisfy { value in frames.contains { officeSameFrame(value, $0) } }
    }
    let s0 = walking.sessions.first { $0.id == "s0" }!
    check(
        "office: running right where x grows, running left where it shrinks",
        !dealt || (steps("s0", s0, after.pets.first { $0.id == "s0" }!) && steps("s1", leaving, before.pets.first { $0.id == "s1" }!)))
    let depth = (officeFigure(view, "s0")?.animation(forKey: "walk-z") as? CAKeyframeAnimation)?.values?.compactMap { ($0 as? NSNumber)?.doubleValue }
    check(
        "office: a walking pet's depth follows its feet",
        depth.map { $0.count == (routes["s0"] ?? []).count && zip($0, routes["s0"] ?? []).allSatisfy { abs($0 - Double($1.y)) <= 1 } }
            ?? false)
    check(
        "office: the others stay where they are, and do not walk",
        (3...9).allSatisfy { i in
            officeFigure(view, "s\(i)").map { $0.animation(forKey: "walk") == nil && $0.position == spot(before, "s\(i)").point } ?? false
        })
    check("office: a session that appears walks in from the door", after.pets.contains { $0.id == "w1" } && midway("w1"))
    check("office: one that closes walks out through the door", midway("s1"))
    // While they walk, the pointer finds each where it is going.
    let goal = after.pets.first { $0.id == "s0" }!
    let fit = OfficeFit(frame.size)
    let aim = fit.rect(goal.body)
    check(
        "office: while it walks, pointing and clicking find it where it is going",
        view.target(at: CGPoint(x: aim.midX, y: aim.midY)) == .pet("s0")
            && walking.tracker.frames["s0"].map { near($0, fit.rect(goal.frame)) } ?? false)
    if review { save(officeMoment(view), "/tmp/office-walk.png") }

    // Changing its mind on the way: it sets off again from where it is, at once, back to its own desk.
    let turning = at("s2")
    walking.sessions = walking.sessions.map { $0.id == "s2" ? officeSession("s2", "idle", finished: 600) : $0 }
    view.update(walking)
    CATransaction.flush()
    let back = walk("s2")
    let restart = (back?.values?.first as? NSValue)?.pointValue
    let home = OfficePainter.layout(walking, now: Date()).pets.first { $0.id == "s2" }!
    check(
        "office: when its place changes again mid-walk, it re-routes from where it is, back to the desk it left",
        turning != nil && restart.map { hypot($0.x - turning!.x, $0.y - turning!.y) < 3 } ?? false && home.zone == .desk
            && home.seat == before.pets.first { $0.id == "s2" }?.seat && (back?.values?.last as? NSValue)?.pointValue == CGPoint(x: home.x, y: home.foot))

    // With s2 back at a desk seven wait: w1 moves along, and w2's turn has come.
    let final = OfficePainter.layout(walking, now: Date())
    check(
        "office: when a place in the queue frees, the flagged one walks up to it",
        final.pets.first { $0.id == "w2" }?.zone == .queue && (walk("w2")?.values?.last as? NSValue)?.pointValue == spot(final, "w2").point)
    let rerouted: [(id: String, route: [CGPoint])] = ["s0", "w1"].compactMap { id in
        guard let values = walk(id)?.values else { return nil }
        return (id, values.compactMap { ($0 as? NSValue)?.pointValue })
    }
    wait(0.3)
    let onTheirWay = rerouted.count == 2 && rerouted.allSatisfy { walker in
        at(walker.id).flatMap { officeAlong($0, walker.route) }.map { $0 > 2 && $0 < officeLength(walker.route) - 2 } ?? false
    }
    check("office: walking on after the others changed their minds and the layers were reordered", onTheirWay && midway("s1"))
    check(
        "office: no walk takes more than 3.5 s, however far",
        ["s0", "w1", "s2", "s1"].allSatisfy { (walk($0)?.duration ?? 9) <= 3.5 } && officeLength(routes["w1"] ?? []) / 240 > 3.5)
    until(6) { ["s0", "w1", "w2", "s2"].allSatisfy { walk($0) == nil } && officeFigure(view, "s1") == nil && officeFigure(view, "r15") == nil }
    wait(0.25)  // the words' fade-in after the last arrival
    let end = final.pets.first { $0.id == "s0" }!, arrived = final.pets.first { $0.id == "w1" }!
    check(
        "office: after the walk it is at its place in the queue, its words back",
        at("s0").map { hypot($0.x - end.x, $0.y - end.foot) < 0.5 } ?? false && (officePart(view, "s0", "words")?.presentation()?.opacity ?? 0) > 0.95)
    check("office: ...the newcomer at its place", at("w1").map { hypot($0.x - arrived.x, $0.y - arrived.foot) < 0.5 } ?? false)
    check("office: ...and the ones that left are gone", officeFigure(view, "s1") == nil && officeFigure(view, "r15") == nil)
    check(
        "office: ...waiting, it knocks (NUDGE: no waiting loop) once it has arrived",
        !dealt || sprite(view, "s0")?.animation(forKey: WaitingNudge.tiltKey) != nil && sprite(view, "s0")?.animation(forKey: "loop") == nil && sprite(view, "s0")?.animation(forKey: "steps") == nil)
    if review { save(officeMoment(view), "/tmp/office-live.png") }
    shown.contentView = nil

    officeCalmTests(review: review, window: window)
    officeQuietTests(review: review, window: window)
    officeVisitViewTests(review: review, window: window)

    // Dragging the window's edge stretches what is there; one paint when the drag ends.
    let resized = officeStore()
    let dragged = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1134, height: 930))
    dragged.update(resized)
    let room = officeRoomLayer(dragged)?.contents as AnyObject?
    let words = officePart(dragged, "o-busy", "words")?.contents as AnyObject?
    dragged.resizing = true
    for height in stride(from: CGFloat(929), through: 880, by: -1) {
        dragged.setFrameSize(NSSize(width: 1134, height: height))
        dragged.layoutSubtreeIfNeeded()
        dragged.update(resized)
    }
    check(
        "office: while the window's edge is dragged, nothing is painted",
        room != nil && officeRoomLayer(dragged)?.contents as AnyObject? === room
            && officePart(dragged, "o-busy", "words")?.contents as AnyObject? === words)
    // AppKit may still say it is resizing when it says the drag ended: the paint must not wait for that.
    dragged.viewDidEndLiveResize()
    let ended = officeRoomLayer(dragged)?.contents as AnyObject?
    dragged.resizing = false
    dragged.layoutSubtreeIfNeeded()
    dragged.update(resized)
    let settled = OfficeFit(CGSize(width: 1134, height: 880))
    check(
        "office: ...and when it ends, the room is laid out and painted once, for the new size",
        ended !== room && officeRoomLayer(dragged)?.contents as AnyObject? === ended
            && (officeRoomLayer(dragged)?.contents as! CGImage?)?.height == Int(settled.height) * 2)
}

/// Calm walking: one at a time down the aisle, the queue sliding with its cards on, the jump seen.
@MainActor func officeCalmTests(review: Bool, window: (NSView) -> NSWindow) {
    func until(_ seconds: Double, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
    }
    let size = CGRect(x: 0, y: 0, width: 1134, height: 930)
    func walk(_ view: NSView, _ id: String) -> CAAnimation? { officeFigure(view, id)?.animation(forKey: "walk") }

    // Mark All Seen with three on the sofas: all three go to desks, one after another up the aisle.
    let marked = Store()
    marked.readOnly = true
    marked.sessions = officeSessions([("n", "idle", 3, 120), ("s", "idle", 6, 900), ("r", "idle", 6, 9 * 3600.0)])
    for s in marked.sessions where !s.id.hasPrefix("n") { marked.seen[s.id] = Date().timeIntervalSince1970 }
    if officeDealCutPets(marked) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(marked)
        for s in marked.sessions { marked.seen[s.id] = Date().timeIntervalSince1970 }
        view.update(marked)
        CATransaction.flush()
        let ids = ["n0", "n1", "n2"], passages = ids.map { officePassage(walk(view, $0)) }
        // All three sit on the first sofa, by the left wall. Those that take the same aisle up to their desks come onto
        // it one after another, the one sitting nearer it first, at least 0.35 s apart; which aisle each takes follows
        // from the desk its way is shortest to.
        func start(_ id: String) -> CGPoint? { ((walk(view, id) as? CAKeyframeAnimation)?.values?.first as? NSValue)?.pointValue }
        let onAisles = Dictionary(grouping: zip(ids, passages).compactMap { id, p in p.map { (id: id, passage: $0) } }, by: \.passage.aisle)
        let shared = onAisles.values.filter { $0.count >= 2 }
        let inTurn = shared.allSatisfy { group in
            let ordered = group.sorted { abs((start($0.id)?.x ?? 0) - $0.passage.x) < abs((start($1.id)?.x ?? 0) - $1.passage.x) }
            return zip(ordered, ordered.dropFirst()).allSatisfy { $1.passage.enters - $0.passage.enters >= 0.349 }
        }
        check(
            "office: three setting off together: two on one aisle come onto it 0.35 s apart or more, nearer the aisle first",
            passages.allSatisfy { $0 != nil } && !shared.isEmpty && inTurn && officeSpaced(view, ids).spaced)
        check("office: ...and no two are within 20 pt of each other on an aisle", passages[0] != nil && !officeCrowded(view, ids))
        if review { officeSheet(view, seconds: 3.9, every: 0.15, to: "/tmp/office-sheet-markall.png") }
        shown.contentView = nil
    }

    func moving(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { $0.animation(forKey: "walk") != nil }.compactMap(\.name).sorted()
    }
    func changing(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { layer in
            ["walk", "swap", "door"].contains { layer.animation(forKey: $0) != nil }
        }.compactMap(\.name).sorted()
    }

    // Seven wait (the longest first: w6 to w0); an eighth starts waiting at its desk: nobody moves, its plate turns coral.
    // Then w2, fifth in the queue, is answered: it walks to a desk, the two after it slide along with their cards on, the
    // four before it stay, and the flagged one walks up to the last place. For the pictures each is done again and
    // recorded from the moment of the change.
    for recording in review ? [false, true] : [false] {
        let queue = Store()
        queue.readOnly = true
        queue.sessions = officeSessions([("w", "waiting", 7, 300), ("d", "idle", 4, 900), ("r", "idle", 4, 9 * 3600.0)])
        for s in queue.sessions where s.status == "idle" { queue.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(queue) else { break }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(queue)
        let plate = officePart(view, "d0", "words")?.contents as AnyObject?, at = officeFigure(view, "d0")?.position
        queue.sessions = queue.sessions.map { $0.id == "d0" ? officeSession("d0", "waiting", finished: 1) : $0 }
        view.update(queue)
        CATransaction.flush()
        if recording {
            officeSheet(view, seconds: 1.2, every: 0.15, to: "/tmp/office-sheet-fourth.png")
        } else {
            check(
                "office: an eighth starting to wait: nobody moves, its plate turns coral where it sits",
                changing(view).isEmpty && officePart(view, "d0", "words")?.contents as AnyObject? !== plate && officeFigure(view, "d0")?.position == at)
        }
        let answer = Date().addingTimeInterval(-0.5)
        queue.sessions = queue.sessions.map { $0.id == "w2" ? Session(id: "w2", pid: 1, project: "项目", name: "w2", status: "idle", since: answer, summary: "") : $0 }
        queue.seen["w2"] = Date().timeIntervalSince1970
        view.update(queue)
        CATransaction.flush()
        if recording {
            officeSheet(view, seconds: 3.4, every: 0.15, to: "/tmp/office-sheet-answered.png")
            continue
        }
        let stayers = ["w1", "w0"]
        let slides = stayers.map { walk(view, $0)?.duration ?? 0 }
        var cards = true
        let begun = CACurrentMediaTime()
        while CACurrentMediaTime() - begun < 0.3 {
            cards = cards && stayers.allSatisfy { (officePart(view, $0, "words")?.presentation()?.opacity ?? 0) > 0.99 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        let up = OfficePainter.layout(queue, now: Date(), height: OfficeFit(size.size).height, scale: OfficeFit(size.size).scale)
        check(
            "office: one of seven answered: the two after it slide along over 0.3 s, their cards on throughout; those before stay",
            cards && slides.allSatisfy { abs($0 - 0.3) < 0.001 } && ["w6", "w5", "w4", "w3"].allSatisfy { walk(view, $0) == nil })
        check(
            "office: ...the flagged one walks up to the queue, and the answered one walks to a desk",
            up.pets.first { $0.id == "d0" }?.zone == .queue && moving(view).contains("d0") && moving(view).contains("w2")
                && up.pets.first { $0.id == "w2" }?.zone == .desk)
    }

    // The back row full and one more behind the door: one resting starts working. It walks; the one
    // that takes its place at the back fades in; nobody else moves. Then one looked at gets news and
    // walks to a sofa, and its neighbours stay put.
    for recording in review ? [false, true] : [false] {
        let full = Store()
        full.readOnly = true
        full.sessions = officeSessions([("s", "idle", 4, 900), ("r", "idle", 21, 9 * 3600.0)])
        for s in full.sessions { full.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(full) else { break }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(full)
        let behind = OfficePainter.layout(full, now: Date()).behindDoorIDs
        full.sessions = full.sessions.map { $0.id == "r5" ? officeSession("r5", "busy", finished: 1) : $0 }
        view.update(full)
        CATransaction.flush()
        if recording {
            officeSheet(view, seconds: 2.9, every: 0.15, to: "/tmp/office-sheet-waking.png")
            continue
        }
        let entering = officeFigure(view, "r20")
        check(
            "office: the back row full, one waking to work: exactly one pet walks, the one taking its place fades in",
            behind == ["r20"] && moving(view) == ["r5"] && changing(view) == ["r20", "r5"]
                && entering?.animation(forKey: "door") != nil && entering?.animation(forKey: "walk") == nil)
        let still = full.sessions.filter { $0.id.hasPrefix("s") && $0.id != "s1" }.map(\.id)
        full.seen["s1"] = 0  // news again
        view.update(full)
        CATransaction.flush()
        check(
            "office: one looked at leaving for the sofa: its neighbours do not move at all",
            moving(view).contains("s1") && still.allSatisfy { id in
                ["walk", "swap", "door"].allSatisfy { officeFigure(view, id)?.animation(forKey: $0) == nil }
            })
    }

    // Stills for the pictures: five waiting (three cards, two flagged at desks, the chip, and its card when
    // pointed at), and the crowd of thirty; the title bar's switch both ways.
    if review {
        let names = ["云朵风车彩虹生成流程梳理", "Nova 像素风格 Comet 演示界面", "cloudsort 自动化方案", "月球漫步", "绘制星图 UV 排版风铃服务"]
        let asks = ["要不要把首页从旧模板换成新模板？", "可以删掉旧的备份吗", "批准运行 docker compose up", "选哪个方案：A 还是 B", "继续部署到测试机吗"]
        let five = Store()
        five.readOnly = true
        five.sessions = (0..<5).map { i in
            Session(id: "wait\(i)", pid: 1, project: "项目", name: names[i], status: "waiting", since: Date().addingTimeInterval(-Double(1000 - i * 120)), summary: asks[i])
        } + officeSessions([("n", "idle", 3, 120), ("b", "busy", 2, 60), ("s", "idle", 6, 900), ("r", "idle", 12, 9 * 3600.0)])
        for s in five.sessions where s.id.hasPrefix("s") || s.id.hasPrefix("r") { five.seen[s.id] = Date().timeIntervalSince1970 }
        let crowd = Store()
        crowd.readOnly = true
        crowd.sessions = officeSessions([("w", "waiting", 7, 300), ("n", "idle", 14, 120), ("b", "busy", 15, 60), ("r", "idle", 64, 9 * 3600.0)])
        for s in crowd.sessions where s.id.hasPrefix("r") { crowd.seen[s.id] = Date().timeIntervalSince1970 }
        for (store, file) in [(five, "/tmp/office-five.png"), (crowd, "/tmp/office-crowd.png")] {
            _ = officeDealCutPets(store)
            let view = OfficeView(frame: size)
            view.still = true
            view.update(store)
            save(view.image(), file)
        }
        // The chip pointed at, with its card over the room, as the panel shows it.
        let view = OfficeView(frame: size)
        view.still = true
        five.hovered = OfficeLayout.ChipKind.waiting.key
        view.update(five)
        if let room = view.image() {
            let fit = OfficeFit(size.size)
            let scene = ZStack(alignment: .topLeading) {
                Image(decorative: room, scale: 2)
                OfficeHover(fit: fit, origin: .zero, window: size.size)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .environmentObject(five).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 2
            save(renderer.cgImage, "/tmp/office-five-chip.png")
        }
        for office in [false, true] {
            let renderer = ImageRenderer(content: OfficeSwitch(mode: office ? .office : .board, z: 1) { _ in }.padding(8).background(night).environment(\.colorScheme, .dark))
            renderer.scale = 3
            save(renderer.cgImage, "/tmp/office-switch-\(office ? "office" : "board").png")
        }
    }

    // A session opens: in through the door and down the right wall to the desk its way is shortest to. On that wall
    // aisle every frame it shows keeps its drawn pixels inside the room; a pet whose running frames reach too far for the
    // strip between the furniture's ends and the wall comes down the centre instead, never through the furniture.
    // The wide one is named by SOULGENT_WIDE_PET (an extension's test.inc.sh may set it; then it must be wide and cut), else a
    // demo pet, which is taken only if it is cut here and reaches that far.
    let widePet = ProcessInfo.processInfo.environment["SOULGENT_WIDE_PET"]
    for (pet, wide) in [(officeFixedPets(1).first ?? "", false), (widePet ?? "wave-whale", true)] {
        if wide && !OfficePets.shared.isCut(pet) {
            skipped("\(pet) is not cut here", "office: one just opened whose running frames reach too far for the right wall's strip comes down the centre")
            continue
        }
        for recording in review && !wide ? [false, true] : [false] {
            let opening = Store()
            opening.readOnly = true
            opening.sessions = officeSessions([("s", "idle", 6, 900), ("r", "idle", 4, 9 * 3600.0), ("n", "busy", 1, 1)])
            for s in opening.sessions where s.status == "idle" { opening.seen[s.id] = Date().timeIntervalSince1970 }
            guard officeDealCutPets(opening, giving: pet, to: "n0") else { break }
            let newcomer = opening.sessions.removeLast()
            let view = OfficeTestView(frame: size)
            let shown = window(view)
            defer { shown.contentView = nil }
            view.update(opening)
            opening.sessions.append(newcomer)
            view.update(opening)
            CATransaction.flush()
            if recording {
                officeSheet(view, seconds: 2.9, every: 0.15, to: "/tmp/office-sheet-door.png")
                continue
            }
            let way = walk(view, "n0").flatMap { ($0 as? CAKeyframeAnimation)?.values?.compactMap { ($0 as? NSValue)?.pointValue } } ?? []
            let aisle = officeAisle(walk(view, "n0")), right = aisle.flatMap { $0.index == 2 ? $0.x : nil } ?? -1000
            print("      the newcomer is \(opening.petBySession["n0"] ?? "?"), down the \(aisle?.index == 2 ? "right wall" : "centre") at x \(aisle?.x ?? -1)")
            if wide {
                if widePet == nil && aisle?.index != 0 {
                    skipped("\(pet) does not reach too far for the right wall's strip", "office: one just opened whose running frames reach too far for the right wall's strip comes down the centre")
                    continue
                }
                check(
                    "office: one just opened whose running frames reach too far for the right wall's strip comes down the centre",
                    way.first == OfficeLayout.doorSpot.point && aisle?.index == 0 && aisle?.x == 597)
                continue
            }
            check(
                "office: one just opened comes in through the door and down the right wall, past the furniture's ends",
                way.first == OfficeLayout.doorSpot.point && right > 1148 && right <= 1166)
            until(2) { officePart(view, "n0", "sprite")?.animation(forKey: "steps") != nil }
            let sprite = officePart(view, "n0", "sprite")
            let frames = ((sprite?.animation(forKey: "steps") as? CAKeyframeAnimation)?.values ?? []) + [sprite?.contents as Any]
            let inside = !frames.isEmpty && frames.allSatisfy { frame in
                guard let image = frame as AnyObject as? CGImage?, let image, let box = officeInkBox(image), let r = sprite?.frame
                else { return false }
                return right + r.minX + box.minX / 2 >= 0 && right + r.minX + box.maxX / 2 <= 1194
            }
            check("office: ...and on that wall aisle every frame it shows stays inside the room", frames.count > 1 && inside)
        }
    }

    // Walking switched off in the menu: places change by a cross-fade, poses still loop.
    let quiet = officeStore()
    if officeDealCutPets(quiet) {
        setOfficeWalks(false)
        defer { UserDefaults.standard.removeObject(forKey: "officeWalks") }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(quiet)
        quiet.sessions = quiet.sessions.map { $0.id == "o-seen" ? officeSession("o-seen", "waiting", finished: 1) : $0 }
        view.update(quiet)
        CATransaction.flush()
        let place = OfficePainter.layout(quiet, now: Date(), height: OfficeFit(size.size).height, scale: OfficeFit(size.size).scale).pets.first { $0.id == "o-seen" }
        check(
            "office: with walking switched off, a pet changing place is set there with a cross-fade, and nobody walks",
            moving(view).isEmpty && officeFigure(view, "o-seen")?.position == place.map { CGPoint(x: $0.x, y: $0.foot) }
                && officeStage(view)?.animation(forKey: kCATransition) != nil)
        until(2) { officePart(view, "o-wait", "sprite")?.animation(forKey: WaitingNudge.tiltKey) != nil }
        check("office: ...and poses still animate (NUDGE: a waiting one knocks, not loops)", officePart(view, "o-wait", "sprite")?.animation(forKey: WaitingNudge.tiltKey) != nil)
    }

    // A session finishing at its desk jumps there, and only then walks to the sofa.
    for recording in review ? [false, true] : [false] {
        let finishing = Store()
        finishing.readOnly = true
        finishing.sessions = officeSessions([("b", "busy", 1, 60), ("s", "idle", 5, 900), ("r", "idle", 4, 9 * 3600.0)])
        for s in finishing.sessions where s.status == "idle" { finishing.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(finishing) else { break }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(finishing)
        let fit = OfficeFit(size.size)
        func layout() -> OfficeLayout { OfficePainter.layout(finishing, now: Date(), height: fit.height, scale: fit.scale) }
        let desk = layout().pets.first { $0.id == "b0" }!
        finishing.sessions = finishing.sessions.map { $0.id == "b0" ? officeSession("b0", "idle", finished: 0.5) : $0 }
        finishing.celebrating["b0"] = Date().addingTimeInterval(1.8)  // as the store's tick does on busy → idle
        let changed = CACurrentMediaTime()
        view.update(finishing)
        CATransaction.flush()
        if recording {
            officeSheet(view, seconds: 3.6, every: 0.15, to: "/tmp/office-sheet-finish.png")
            continue
        }
        let place = layout().pets.first { $0.id == "b0" }!
        let session = finishing.sessions.first { $0.id == "b0" }!
        let pose = finishing.pose(of: session).sheet, scale = OfficePainter.figure(finishing, session, place, now: Date()).scale
        let jump = (0..<pose.frames).compactMap { OfficePets.shared.scaled(finishing.petBySession["b0"]!, row: pose.row, column: $0, scale: scale) }
        let leaves = (walk(view, "b0")?.beginTime ?? 0) - changed
        until(0.45) { CACurrentMediaTime() - changed > 0.45 }
        let shows = officePart(view, "b0", "sprite")?.presentation()?.contents
        let still = officeFigure(view, "b0")?.presentation()?.position
        check(
            "office: a session that has just finished jumps where it stands",
            pose.row == 4 && place.zone == .sofa && jump.contains { officeSameFrame(shows, $0) } && still == CGPoint(x: desk.x, y: desk.foot))
        check(
            "office: ...and sets off when the jump is over, within 1.2 s",
            leaves >= Double(pose.frames) * pose.ms / 1000 - 0.02 && leaves <= 1.2 + 0.02)
    }
}

/// Round four: whether a pet is on its way is told by the clock; walkers keep their distance on an aisle; time alone
/// moves nobody on foot; an answered one stays a while at your desk; a kept desk is kept.
/// Two at different paces on one aisle never come within 20 pt of each other while both are on it: a sweep of
/// pairs at desks, one starting to wait, the other getting news or finishing. Fourteen cut pets needed, else skipped.
@MainActor func officePairsTests(window: (NSView) -> NSWindow) {
    let what = "office: pairs setting off together at different paces: on a shared aisle they come on 0.35 s apart and never within 20 pt"
    let size = CGRect(x: 0, y: 0, width: 1134, height: 930)
    func set(_ store: Store, _ id: String, _ status: String, ago: TimeInterval = 0.5) {
        store.sessions = store.sessions.map { $0.id == id ? officeSession(id, status, finished: ago) : $0 }
    }
    var shared = 0, apart = true
    let pairs: [(String, String, String, String)] = [
        ("b2", "wait", "b0", "news"), ("b0", "wait", "b1", "done"), ("b8", "wait", "b0", "news"), ("b1", "news", "b9", "wait"),
        ("b0", "done", "b8", "done"), ("b3", "wait", "b1", "news"), ("b2", "news", "b8", "wait"),
    ]
    for (a, first, b, second) in pairs {
        let store = Store()
        store.readOnly = true
        store.sessions = officeSessions([("b", "busy", 10, 60), ("s", "idle", 4, 900)])
        for s in store.sessions where s.status == "idle" { store.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(store) else { return skipped("no pet frames", what) }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(store)
        for (id, change) in [(a, first), (b, second)] {
            switch change {
            case "wait": set(store, id, "waiting", ago: 0.2)
            case "news":
                set(store, id, "idle", ago: 0.3)  // finished unseen by the tick: news, no jump
            default:
                set(store, id, "idle", ago: 0.3)
                store.celebrating[id] = Date().addingTimeInterval(1.8)
            }
        }
        view.update(store)
        CATransaction.flush()
        let spaced = officeSpaced(view, [a, b])
        shared += spaced.sharing > 0 ? 1 : 0
        apart = apart && spaced.spaced && !officeCrowded(view, [a, b])
        shown.contentView = nil
    }
    check(what, apart && shared >= 4)
}

@MainActor func officeQuietTests(review: Bool, window: (NSView) -> NSWindow) {
    let size = CGRect(x: 0, y: 0, width: 1134, height: 930), fit = OfficeFit(size.size)
    func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func walk(_ view: NSView, _ id: String) -> CAAnimation? { officeFigure(view, id)?.animation(forKey: "walk") }
    /// Who is on foot: a walk in running frames, not a glide along the queue.
    func walking(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { $0.animation(forKey: "walk") is CAKeyframeAnimation }.compactMap(\.name).sorted()
    }
    func changing(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { layer in ["walk", "swap", "door"].contains { layer.animation(forKey: $0) != nil } }
            .compactMap(\.name).sorted()
    }
    func layout(_ store: Store, _ view: OfficeTestView) -> OfficeLayout {
        OfficePainter.layout(store, now: view.clock, height: fit.height, scale: fit.scale)
    }
    func set(_ store: Store, _ id: String, _ status: String, ago: TimeInterval = 0.5) {
        store.sessions = store.sessions.map { $0.id == id ? officeSession(id, status, finished: ago) : $0 }
    }
    func end(_ view: NSView, _ id: String) -> CGPoint? { ((walk(view, id) as? CAKeyframeAnimation)?.values?.last as? NSValue)?.pointValue }
    func settle(_ view: NSView, _ ids: [String]) {
        let last = ids.compactMap { walk(view, $0) }.map { $0.beginTime + $0.duration }.max() ?? 0
        while CACurrentMediaTime() < last + 0.1 { wait(0.05) }
    }

    // A walk that is over but still attached to its layer does not make the next queue move a walk: the two behind
    // the one that closes glide along with their cards on. Core Animation takes a finished walk off only at the next
    // commit; in the panel nothing may commit for 30 s, here something always does, so the finished walks are put back on.
    let stale = Store()
    stale.readOnly = true
    stale.sessions = officeSessions([("w", "waiting", 2, 300), ("b", "busy", 4, 60), ("s", "idle", 6, 900), ("r", "idle", 8, 9 * 3600.0)])
    for s in stale.sessions where s.status == "idle" { stale.seen[s.id] = Date().timeIntervalSince1970 }
    if officeDealCutPets(stale) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(stale)
        set(stale, "b0", "waiting")
        view.update(stale)
        CATransaction.flush()
        settle(view, ["b0"])
        for id in ["b0", "w0"] {
            guard let layer = officeFigure(view, id) else { continue }
            let over = CAKeyframeAnimation(keyPath: "position")
            over.values = [NSValue(point: layer.position), NSValue(point: layer.position)]
            over.beginTime = CACurrentMediaTime() - 3
            over.duration = 2.5
            layer.add(over, forKey: "walk")
        }
        let left = walk(view, "b0") != nil && walk(view, "w0") != nil
        stale.sessions.removeAll { $0.id == "w1" }  // the first in the queue (it waits longest) closes: the two behind it move up
        view.update(stale)
        CATransaction.flush()
        let glide = ["w0", "b0"].allSatisfy { (walk(view, $0) as? CABasicAnimation)?.duration == 0.3 }
        let cards = ["w0", "b0"].allSatisfy { officePart(view, $0, "words")?.animation(forKey: "shown") == nil }
        check(
            "office: a walk over but not yet taken off its layer does not turn the next queue move into a walk: they glide, cards on",
            left && glide && cards)
        shown.contentView = nil
    }

    // Three finishing in one tick at desks by the centre aisle jump, then come onto the aisle one at a time, at
    // least 0.35 s apart; the first sets off as soon as its jump is over, the others wait their turn with no words.
    let done = Store()
    done.readOnly = true
    done.sessions = officeSessions([("b", "busy", 10, 60), ("s", "idle", 4, 900), ("r", "idle", 4, 9 * 3600.0)])
    for s in done.sessions where s.status == "idle" { done.seen[s.id] = Date().timeIntervalSince1970 }
    if officeDealCutPets(done) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(done)
        // At the desks either side of the centre aisle: the first finisher (newest) takes the right sofa's inner seat,
        // the others the left sofa's two inner seats; all three go down the centre.
        let seated = layout(done, view).pets.filter { $0.zone == .desk }
        let finishers = [1, 0, 8].compactMap { seat in seated.first { $0.seat == seat }?.id }
        for (i, id) in finishers.enumerated() {
            set(done, id, "idle", ago: 0.3 + Double(i) * 0.01)
            done.celebrating[id] = Date().addingTimeInterval(1.8)
        }
        let changed = CACurrentMediaTime()
        view.update(done)
        CATransaction.flush()
        let took = CACurrentMediaTime() - changed
        let passages = finishers.compactMap { officePassage(walk(view, $0)) }
        let enters = passages.map(\.enters).sorted(), starts = finishers.compactMap { walk(view, $0)?.beginTime }.sorted()
        let times = enters.map { String(format: "%.2f", $0 - changed) }
        print("      three finishing: onto the aisle at " + times.joined(separator: ", ") + " s")
        check(
            "office: three finishing at once jump, then come onto their aisle one at a time, at least 0.35 s apart",
            passages.count == 3 && Set(passages.map(\.aisle)).count == 1 && officeSpaced(view, finishers).spaced
                && !officeCrowded(view, finishers) && (starts.first ?? 0) - changed - 0.7 > -0.05
                && (starts.first ?? 0) - changed - 0.7 < took + 0.05)  // its jump, counted from within the update
        let late = finishers.first { (walk(view, $0)?.beginTime ?? 0) > changed + 0.85 }
        while CACurrentMediaTime() < changed + 0.8 { wait(0.02) }
        check(
            "office: ...one waiting its turn after its jump shows no words, which are already those of where it goes",
            late.map { id in
                let words = officePart(view, id, "words")?.presentation()?.opacity ?? 1
                return words < 0.05 && (walk(view, id)?.beginTime ?? 0) > CACurrentMediaTime()
            } ?? false)
        shown.contentView = nil
    }

    officePairsTests(window: window)

    // A looked-at session passing six hours idle moves to the back row by a fade where it is, not on foot; for the
    // first half of the fade it still shows its size and strength at the desk.
    for recording in review ? [false, true] : [false] {
        let aging = Store()
        aging.readOnly = true
        aging.sessions = officeSessions([("s", "idle", 6, 900), ("r", "idle", 4, 9 * 3600.0)])
            + [officeSession("a0", "idle", finished: 6 * 3600 - 30)]
        for s in aging.sessions { aging.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(aging) else { break }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(aging)
        let desk = layout(aging, view).pets.first { $0.id == "a0" }
        aging.sessions = aging.sessions.map { $0.id == "a0" ? officeSession("a0", "idle", finished: 6 * 3600 + 30) : $0 }
        view.update(aging)
        CATransaction.flush()
        if recording {
            officeSheet(view, seconds: 0.9, every: 0.1, to: "/tmp/office-sheet-aging.png")
            continue
        }
        let now = layout(aging, view).pets.first { $0.id == "a0" }
        let grow = officePart(view, "a0", "sprite")?.animation(forKey: "grow") as? CAKeyframeAnimation
        let first = (grow?.values?.first as? NSNumber)?.doubleValue ?? 0
        check(
            "office: one looked at passing six hours idle goes to the back row by a fade where it is: nobody walks",
            desk?.zone == .desk && now?.zone == .lounge && walking(view).isEmpty && changing(view) == ["a0"]
                && officeFigure(view, "a0")?.animation(forKey: "swap") != nil)
        check(
            "office: ...fading out at its desk at the size it had there, and in at the back at its new size",
            grow?.calculationMode == .discrete && abs(first - 70.0 / 50.0) < 0.15 && (grow?.values?.last as? NSNumber)?.doubleValue == 1)
    }

    // Question and answer, five times within 45 s: it walks to your desk once, then stays there, at work and without
    // its card while answered, its card back when it asks again. Nothing walks. Left working, after 45 s it walks home
    // once, to the desk it left.
    for recording in review ? [false, true] : [false] {
        let qa = Store()
        qa.readOnly = true
        qa.sessions = officeSessions([("q", "busy", 1, 60), ("s", "idle", 5, 900), ("r", "idle", 4, 9 * 3600.0)])
        for s in qa.sessions where s.status == "idle" { qa.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(qa) else { break }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(qa)
        let desk = layout(qa, view).pets.first { $0.id == "q0" }!
        set(qa, "q0", "waiting")
        view.update(qa)
        CATransaction.flush()
        let asked = walking(view) == ["q0"]
        settle(view, ["q0"])
        var walks = 0, words = true, lit = true, frames: [(CGImage, String)] = []
        for round in 1...5 {
            for status in ["busy", "waiting"] {
                set(qa, "q0", status, ago: 0.1)
                view.update(qa)
                CATransaction.flush()
                walks += walking(view).count
                // Answered, a one-line plate where its card's tail was, over its head (under its feet is the room's edge);
                // asking again, the card.
                let box = officePart(view, "q0", "words")?.frame ?? .zero
                words = words && box.maxY < 0 && (status == "busy" ? box.height < 30 : box.height > 50)
                if status == "busy" { lit = lit && OfficePainter.lit(qa, layout(qa, view)).contains(desk.seat) }
                if recording {
                    frames += officeRecord(view, seconds: 0.3, every: 0.15, label: " \(round) \(status == "busy" ? "answered" : "asked again")")
                } else {
                    wait(0.2)
                }
            }
        }
        if recording {
            officeSaveSheet(frames, size: size.size, to: "/tmp/office-sheet-qa.png")
            continue
        }
        check(
            "office: asked and answered five times within 45 s: it walked to your desk once and then stays; nothing walks",
            asked && walks == 0 && layout(qa, view).pets.first { $0.id == "q0" }?.zone == .queue)
        check("office: ...answered, its name plate over its head and no card; asking again, its card; its desk's screen lit meanwhile", words && lit)
        set(qa, "q0", "busy", ago: 0.1)
        view.update(qa)
        CATransaction.flush()
        view.shift = 46
        view.update(qa)
        CATransaction.flush()
        let home = walk(view, "q0")
        check(
            "office: answered and working for 45 s, it walks home to the desk it left, and only it moves",
            home is CAKeyframeAnimation && end(view, "q0") == CGPoint(x: desk.x, y: desk.foot) && changing(view) == ["q0"])
        view.shift = 50
        view.update(qa)
        CATransaction.flush()
        check("office: ...once", walk(view, "q0") === home)
    }

    // A waiting one due for the place of one just answered in a full queue: the answered one walks home at once, the
    // waiting one comes forward.
    let due = Store()
    due.readOnly = true
    due.sessions = officeSessions([("w", "waiting", 6, 300), ("q", "busy", 1, 60), ("d", "idle", 4, 900), ("r", "idle", 4, 9 * 3600.0)])
    for s in due.sessions where s.status == "idle" { due.seen[s.id] = Date().timeIntervalSince1970 }
    if officeDealCutPets(due) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(due)
        let desk = layout(due, view).pets.first { $0.id == "q0" }!
        set(due, "q0", "waiting", ago: 30)
        view.update(due)
        CATransaction.flush()
        settle(view, ["q0"])
        set(due, "q0", "busy", ago: 0.2)
        view.update(due)
        CATransaction.flush()
        let staying = walking(view).isEmpty && layout(due, view).pets.first { $0.id == "q0" }?.zone == .queue
        set(due, "d0", "waiting", ago: 0.1)
        view.update(due)
        CATransaction.flush()
        let now = layout(due, view)
        check(
            "office: a waiting one due for the place of one just answered: the answered one walks home at once, the other comes forward",
            staying && walking(view) == ["d0", "q0"] && end(view, "q0") == CGPoint(x: desk.x, y: desk.foot)
                && now.pets.first { $0.id == "d0" }?.zone == .queue)
        shown.contentView = nil
    }

    // Sixteen desks full, two looked at at the back. One goes to the queue: only it moves, its desk stays empty.
    // Answered, it stays a while; then it walks back to the same desk, and still only it moves.
    for recording in review ? [false, true] : [false] {
        let full = Store()
        full.readOnly = true
        full.sessions = officeSessions([("b", "busy", 6, 60), ("s", "idle", 12, 900), ("r", "idle", 4, 9 * 3600.0)])
        for s in full.sessions where s.status == "idle" { full.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(full) else { break }
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        defer { shown.contentView = nil }
        view.update(full)
        let before = layout(full, view)
        let desk = before.pets.first { $0.id == "b2" }!
        func others(_ layout: OfficeLayout) -> Bool {
            before.pets.filter { $0.id != "b2" }.allSatisfy { was in
                layout.pets.first { $0.id == was.id }.map { $0.zone == was.zone && $0.seat == was.seat } ?? false
            }
        }
        set(full, "b2", "waiting", ago: 0.2)
        view.update(full)
        CATransaction.flush()
        let out = changing(view) == ["b2"] && others(layout(full, view)) && layout(full, view).pets.first { $0.id == "b2" }?.zone == .queue
        var frames = recording ? officeRecord(view, seconds: 2.7, every: 0.3, label: " to the queue") : []
        settle(view, ["b2"])
        set(full, "b2", "busy", ago: 0.2)
        view.update(full)
        CATransaction.flush()
        let stays = changing(view).isEmpty
        view.shift = 46
        view.update(full)
        CATransaction.flush()
        let back = changing(view) == ["b2"] && end(view, "b2") == CGPoint(x: desk.x, y: desk.foot) && others(layout(full, view))
        if recording {
            frames += officeRecord(view, seconds: 2.7, every: 0.3, label: " back to desk")
            officeSaveSheet(frames, size: size.size, to: "/tmp/office-sheet-desks.png")
            continue
        }
        check("office: sixteen desks full: one going to the queue is the only one to move", out && desk.zone == .desk)
        check("office: ...answered it stays a while; then it walks back to the same desk, and still nobody else moves", stays && back)
    }
}

/// The cost of a full room: the process's resident memory before and after a thirty-pet office is
/// built and shown, measured first thing, before the other checks have filled the process.
@MainActor func officeMemoryTests() {
    let thirty = Store()
    thirty.readOnly = true
    thirty.sessions = officeSessions([("tw", "waiting", 6, 300), ("tb", "busy", 4, 60), ("ts", "idle", 10, 900), ("tr", "idle", 10, 9 * 3600.0)])
    for s in thirty.sessions where s.status == "idle" { thirty.seen[s.id] = Date().timeIntervalSince1970 }
    guard officeDealCutPets(thirty) else {
        print("      (no cut pets in the pool: the cost of a full room is not measured)")
        return
    }
    NSApplication.shared.setActivationPolicy(.accessory)
    let before = officeResident()
    let full = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1134, height: 930))
    let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 1134, height: 930), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = full
    window.orderFrontRegardless()
    full.update(thirty)
    CATransaction.flush()
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    let after = officeResident()
    print("      resident memory: \(String(format: "%.1f", before)) MB before a thirty-pet office, \(String(format: "%.1f", after)) MB after")
    check("office: a thirty-pet office is built", officeStage(full)?.sublayers?.count == 32)
    window.orderOut(nil)
}

/// Every assigned pet's frames are cut in the background, before the office is first shown.
@MainActor func officePrepareTests() {
    let scratch = NSTemporaryDirectory() + "office-prepare-\(getpid())"
    defer { try? FileManager.default.removeItem(atPath: scratch) }
    let files = FileManager.default
    guard let png = officeTinySheet() else {
        check("office: a sheet is there to prepare", false)
        return
    }
    for pet in ["alpha", "beta", "gamma"] {
        try? files.createDirectory(atPath: "\(scratch)/pool/\(pet)", withIntermediateDirectories: true)
        files.createFile(atPath: "\(scratch)/pool/\(pet)/spritesheet.webp", contents: png)
    }
    let pets = OfficePets(folder: scratch + "/cache", pools: [scratch + "/pool"])
    var ready = 0
    pets.onReady = { ready += 1 }
    pets.synchronous = true
    _ = pets.frame("alpha", row: 0, column: 0)
    pets.synchronous = false
    check(
        "office: asking to prepare a pet that is already cut starts nothing",
        pets.isCut("alpha") && pets.prepare(["alpha"]) == 0 && pets.cuttingNow == 0)
    check(
        "office: the others are cut in the background, one at a time",
        pets.prepare(["alpha", "beta", "gamma"]) == 2 && pets.cuttingNow == 1 && pets.prepare(["beta", "gamma"]) == 0)
    let deadline = Date().addingTimeInterval(10)
    while ready < 2 && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check(
        "office: ...and then they are ready, and asking again starts nothing",
        ready == 2 && pets.isCut("beta") && pets.isCut("gamma") && pets.prepare(["alpha", "beta", "gamma"]) == 0)

    // The system clears caches when the disk runs short: a pet whose cut frames are gone is cut again.
    // A cache of one byte keeps nothing, so every look goes to the disk.
    let vanishing = OfficePets(folder: scratch + "/cache2", pools: [scratch + "/pool"], cacheLimit: 1)
    vanishing.synchronous = true
    let had = vanishing.frame("alpha", row: 0, column: 0) != nil
    try? files.removeItem(atPath: scratch + "/cache2")
    check(
        "office: a pet whose cut frames vanished is cut again on the next look",
        had && vanishing.frame("alpha", row: 0, column: 0) != nil && files.fileExists(atPath: scratch + "/cache2"))
    vanishing.synchronous = false
    try? files.removeItem(atPath: scratch + "/cache2")
    var recut = 0
    vanishing.onReady = { recut += 1 }
    check("office: ...and the store's next tick puts it in line again", !vanishing.isCut("alpha") && vanishing.prepare(["alpha"]) == 1)
    let again = Date().addingTimeInterval(10)
    while recut < 1 && Date() < again { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    check("office: ...which cuts it", recut == 1 && vanishing.isCut("alpha"))
}

// ───────── Visits ─────────

/// A time as the transcripts write it.
func officeStamp(_ date: Date) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.string(from: date)
}

/// Made-up messages between sessions, as the link scanner finds them: each in its sender's transcript, naming the
/// other by its name.
struct OfficeTalk {
    var records: [String: LinkScanner.Record] = [:]

    mutating func say(_ from: String, to name: String, at date: Date) {
        records[from, default: LinkScanner.Record()].sent.append(
            LinkScanner.Message(peer: name, at: officeStamp(date), note: "要不要一起看看这个", address: nil))
    }
}

/// Made-up rounds for the visit rule: who opened each and when, and when the pair last spoke.
struct OfficeRounds {
    var peers: [String: [Peer]] = [:]
    var rounds: [String: Store.Round] = [:]

    mutating func talk(_ opener: String, _ partner: String, opened: Date, last: Date) {
        rounds[OfficeVisits.pair(opener, partner)] = Store.Round(opener: opener, since: opened)
        peers[opener, default: []].removeAll { $0.id == partner }
        peers[partner, default: []].removeAll { $0.id == opener }
        peers[opener, default: []].append(Peer(id: partner, sent: 1, received: 1, last: last, note: "", outgoing: true))
        peers[partner, default: []].append(Peer(id: opener, sent: 1, received: 1, last: last, note: "", outgoing: false))
    }
}

/// A round of talk as the store keeps it. It opens when a pair speaks after ten quiet minutes, or for the first time
/// while the panel watches; whoever sent the first of those messages opened it; it lasts while the talk is recent.
@MainActor func officeRoundTests() {
    let base = Date() - 4000
    let store = Store()
    store.readOnly = true
    store.sessions = ["A", "B", "C"].map { officeSession($0, "idle", finished: 900) }
    var talk = OfficeTalk()
    talk.say("A", to: "B", at: base - 3600)
    store.applyLinks(talk.records, scanned: base)
    let launch = store.rounds.isEmpty
    // A asks and B answers between two scans.
    talk.say("A", to: "B", at: base + 2)
    talk.say("B", to: "A", at: base + 7)
    store.applyLinks(talk.records, scanned: base + 10)
    let asked = store.rounds[OfficeVisits.pair("A", "B")]
    check(
        "office: a question and its answer seen by one scan: the one who asked opened the round; the board's plane is as before",
        launch && asked?.opener == "A" && abs((asked?.since ?? .distantPast).timeIntervalSince(base + 2)) < 0.01 && store.flights.count == 1
            && store.flights.last?.from == "B")
    // A answers seven minutes after B's last word: the same round, though the board flies a plane for it.
    talk.say("A", to: "B", at: base + 427)
    store.applyLinks(talk.records, scanned: base + 430)
    check(
        "office: a reply seven minutes after the last message is the same round, with the same opener",
        store.rounds[OfficeVisits.pair("A", "B")] == asked && asked != nil && store.flights.count == 2)
    // B answers twelve minutes after: a new round, opened by B.
    talk.say("B", to: "A", at: base + 1147)
    store.applyLinks(talk.records, scanned: base + 1150)
    let twelve = store.rounds[OfficeVisits.pair("A", "B")]
    check(
        "office: a reply twelve minutes after the last message opens a new round, opened by the one who replied",
        twelve?.opener == "B" && abs((twelve?.since ?? .distantPast).timeIntervalSince(base + 1147)) < 0.01)
    // Ten quiet minutes, or one of the pair closing, and the round is gone.
    store.applyLinks(talk.records, scanned: base + 1147 + 601)
    let quiet = store.rounds.isEmpty
    talk.say("C", to: "A", at: base + 1800)
    store.applyLinks(talk.records, scanned: base + 1805)
    let opened = store.rounds[OfficeVisits.pair("A", "C")]?.opener == "C"
    store.sessions = store.sessions.filter { $0.id != "C" }
    store.applyLinks(talk.records, scanned: base + 1810)
    check(
        "office: a round is dropped after ten quiet minutes, and when one of its pair has closed",
        quiet && opened && store.rounds.isEmpty)
    // At launch nothing is opening, even for a pair that spoke half a minute before: their talk shows, no round.
    let launched = Store()
    launched.readOnly = true
    launched.sessions = ["A", "B"].map { officeSession($0, "idle", finished: 900) }
    var lately = OfficeTalk()
    lately.say("A", to: "B", at: Date() - 30)
    launched.applyLinks(lately.records)
    check(
        "office: at launch no round opens, though the pair spoke half a minute before",
        launched.rounds.isEmpty && launched.peers["A"]?.first?.isRecent(Date()) == true)
}

/// Pure: who visits whom when a round opens, for how long, where it stands, who carries a chat mark, where
/// the hover card goes.
@MainActor func officeVisitRuleTests() {
    let now = Date()
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    // One waiting, one with news, two at work, four looked at, two resting: b0 b1 s0 s1 s2 s3 at desk seats 0 to 5.
    func room(
        waiting: [String] = ["w0"], unread: [String] = ["n0"], busy: [String] = ["b0", "b1"], seen: [String] = ["s0", "s1", "s2", "s3"],
        resting: [String] = ["r0", "r1"], previous: OfficeLayout? = nil
    ) -> OfficeLayout {
        OfficeLayout(waiting: waiting, unread: unread, busy: busy, seen: seen, resting: resting, now: now, previous: previous)
    }
    func pet(_ layout: OfficeLayout, _ id: String) -> OfficeLayout.Pet? { layout.pets.first { $0.id == id } }
    /// Rounds opened this many seconds ago, each pair last speaking then, seen by an office that has looked before.
    func plan(_ layout: OfficeLayout, _ talks: [(String, String, TimeInterval)], previous: OfficeVisits? = nil, at: Date? = nil) -> OfficeVisits {
        var made = OfficeRounds()
        for (opener, partner, ago) in talks { made.talk(opener, partner, opened: now - ago, last: now - ago) }
        var before = previous ?? OfficeVisits()
        if previous == nil { before.looked = true }
        return OfficeVisits.next(layout, peers: made.peers, rounds: made.rounds, previous: before, now: at ?? now)
    }

    // Who may go, and to whom.
    let usual = room()
    let allowed = plan(usual, [("s0", "b0", 5), ("r0", "s1", 5), ("s2", "n0", 5), ("b1", "r1", 5)])
    check(
        "office: a round opening sends its opener, at a desk or at the back, to the other, at a desk, on a sofa or at the back",
        allowed.hosts == ["s0": "b0", "r0": "s1", "s2": "n0", "b1": "r1"] && pet(usual, "n0")?.zone == .sofa
            && pet(usual, "r1")?.zone == .lounge && pet(usual, "r0")?.zone == .lounge)
    let bySofa = pet(usual.visited(by: allowed), "s2"), byDesk = pet(usual.visited(by: allowed), "s0")
    check(
        "office: one standing by a sofa is reached as the sofa is, down the aisle and along the sofas' floor; one by a desk along the row",
        bySofa.map { usual.spot(of: $0).lane == .row } ?? false && byDesk.map { usual.spot(of: $0).lane == .row } ?? false
            && bySofa.map { guest in
                usual.route(from: OfficeSpot(point: CGPoint(x: 597, y: 300), lane: .row), to: usual.spot(of: guest))
                    == [CGPoint(x: 597, y: 300), CGPoint(x: 597, y: guest.foot), CGPoint(x: guest.x, y: guest.foot)]
            } ?? false)
    let flaggedRoom = room(waiting: ids("w", 8))
    let asked = room(waiting: ["q0", "w0"], busy: ["b0", "b1"])
    let answered = room(waiting: ["w0"], busy: ["q0", "b0", "b1"], previous: asked)
    let crowded = room(resting: ids("r", 30))
    let outside = crowded.behindDoorIDs.first ?? "nobody"
    let homebound = [
        plan(usual, [("w0", "s3", 5)]), plan(usual, [("n0", "s3", 5)]), plan(flaggedRoom, [("w7", "s3", 5)]),
        plan(answered, [("q0", "s3", 5)]), plan(usual, [("s3", "w0", 5)]), plan(crowded, [("s3", outside, 5)]),
    ]
    check(
        "office: one in the queue, flagged, staying at your desk or on a sofa does not go; nobody visits one in the queue or outside",
        homebound.allSatisfy { $0.visits.isEmpty } && pet(flaggedRoom, "w7").map { $0.flagged && $0.zone == .desk } ?? false
            && pet(answered, "q0").map { $0.zone == .queue && $0.kind == .work } ?? false && pet(crowded, outside) == nil
            && pet(crowded, "s3")?.zone == .desk && plan(crowded, [("s3", "s1", 5)]).hosts == ["s3": "s1"])
    // Nobody goes for a round already going on when the office first looks, or one that opened over 30 s before it looks.
    var talking = OfficeRounds()
    talking.talk("s0", "b0", opened: now - 5, last: now - 5)
    let firstLook = OfficeVisits.next(usual, peers: talking.peers, rounds: talking.rounds, previous: OfficeVisits(), now: now)
    let lookAgain = OfficeVisits.next(usual, peers: talking.peers, rounds: talking.rounds, previous: firstLook, now: now + 5)
    check(
        "office: at the first look nobody goes, nor later for a round going on then; nor for a round opened over 30 s before",
        firstLook.visits.isEmpty && firstLook.looked && lookAgain.visits.isEmpty && plan(usual, [("s0", "b0", 31)]).visits.isEmpty
            && plan(usual, [("s0", "b0", 29)]).hosts == ["s0": "b0"])
    let two = plan(usual, [("s0", "b0", 6), ("s1", "b0", 5)])
    let openSofa = room(unread: ["n0"])  // n0 on the first sofa's first seat, free on both sides
    check(
        "office: one visitor at a host at a time: a second opener does not walk, then or when the first has gone home",
        two.hosts == ["s0": "b0"] && plan(usual, [("s0", "b0", 6), ("s1", "b0", 5)], previous: two, at: now + 25).visits.isEmpty
            && plan(openSofa, [("s0", "n0", 6), ("s1", "n0", 5)]).hosts == ["s0": "n0"])
    check(
        "office: one session goes to one host; nobody visits and is visited at once, so two never visit each other",
        plan(usual, [("s0", "b0", 6), ("s0", "s1", 5)]).hosts == ["s0": "b0"]
            && plan(usual, [("s0", "b0", 6), ("b0", "s1", 5)]).hosts == ["s0": "b0"]
            && plan(usual, [("b0", "s1", 6), ("s0", "b0", 5)]).hosts == ["b0": "s1"])

    // A visit is short: about 20 s after it arrives it goes home, and that round sends it no more.
    let going = plan(usual, [("s0", "b0", 5)])
    let stay = going.visits["s0"].map { $0.until.timeIntervalSince(now) } ?? 0
    let over = plan(usual, [("s0", "b0", 5)], previous: going, at: now + stay + 1)
    check(
        "office: a visit stands about 20 s after the visitor arrives, then ends, and its round sends it no more",
        stay >= 20 && stay <= 22.5 && plan(usual, [("s0", "b0", 5)], previous: going, at: now + stay - 1).hosts == ["s0": "b0"]
            && over.visits.isEmpty && plan(usual, [("s0", "b0", 5)], previous: over, at: now + stay + 20).visits.isEmpty)
    let workNow = room(busy: ["b0", "b1", "s0"], seen: ["s1", "s2", "s3"], previous: usual.visited(by: going))
    let newsNow = room(unread: ["n0", "s0"], seen: ["s1", "s2", "s3"], previous: usual.visited(by: going))
    check(
        "office: a visitor whose own state changes leaves at once for its place, at its desk or on a sofa",
        pet(workNow, "s0")?.zone == .desk && plan(workNow, [("s0", "b0", 5)], previous: going, at: now + 3).visits.isEmpty
            && pet(newsNow, "s0")?.zone == .sofa && plan(newsNow, [("s0", "b0", 5)], previous: going, at: now + 3).visits.isEmpty
            && plan(usual, [("s0", "b0", 5)], previous: going, at: now + 3).hosts == ["s0": "b0"])
    let hostWaits = room(waiting: ["w0", "b0"], busy: ["b1"], previous: usual.visited(by: going))
    let hostNews = room(unread: ["n0", "b0"], busy: ["b1"], previous: usual.visited(by: going))
    let afterNews = plan(hostNews, [("s0", "b0", 5)], previous: going, at: now + 3)
    check(
        "office: the host leaving its place sends its visitor home, from your desk or anywhere else, not to come back that round",
        pet(hostWaits, "b0")?.zone == .queue && plan(hostWaits, [("s0", "b0", 5)], previous: going, at: now + 3).visits.isEmpty
            && pet(hostNews, "b0")?.zone == .sofa && afterNews.visits.isEmpty
            && plan(usual, [("s0", "b0", 5)], previous: afterNews, at: now + 6).visits.isEmpty)
    check("office: ...and a new round between them sends it over again", plan(hostNews, [("s0", "b0", 2)], previous: afterNews).hosts == ["s0": "b0"])

    // Where it stands: away from its host's plate, on the host's foot line 4 pt in front.
    let host = pet(usual, "b0")!
    if let guest = pet(usual.visited(by: going), "s0"), let home = pet(usual, "s0") {
        check(
            "office: by one at a desk the visitor stands 46 pt to its right, away from its plate, 4 pt in front of its foot line",
            guest.x == host.x + 46 && guest.foot == host.foot + 4 && going.visits["s0"]?.side == 1)
        check(
            "office: ...it keeps its size and its seat, its words hidden",
            guest.tall == home.tall && guest.zone == .desk && guest.seat == home.seat && guest.words.isNull && guest.host == "b0"
                && guest.hostZone == .desk)
        let back = usual.visited(by: plan(usual, [("r0", "b0", 5)]))
        check(
            "office: ...one from the back row keeps its back-row size by a desk",
            pet(back, "r0").map { $0.tall == 50 && $0.x == host.x + 46 } ?? false)
        let seat = home.body, there = usual.visited(by: going)
        check(
            "office: pointing finds the visitor where it stands, ringed there; its empty seat is nobody",
            there.session(at: CGPoint(x: guest.x + 25, y: guest.foot - 30)) == "s0" && there.ring(for: "s0") == guest.body
                && guest.frame == guest.body && there.session(at: CGPoint(x: seat.midX, y: seat.midY)) == nil && there.pointed(at: "s0") == "s0")
    } else {
        check("office: by one at a desk the visitor stands 46 pt to its right, away from its plate, 4 pt in front of its foot line", false)
    }
    // By a sofa or at the back: the right if free, else the left. The sofas seat three each, 75 apart, filled from the
    // left: n2 sits at the first sofa's right end, with the gap to the next sofa at its right; n3 at the second's left
    // end, with n4 beside it.
    let sofas = room(unread: ids("n", 5))  // n0 92, n1 167, n2 242 | n3 379, n4 454
    let toN3 = plan(sofas, [("s0", "n3", 5)]), toN2 = plan(sofas, [("s1", "n2", 5)]), toR1 = plan(usual, [("s1", "r1", 5)])
    check(
        "office: by one on a sofa or at the back it stands on the right if that is free, else on the left",
        pet(sofas, "n2")?.x == 242 && pet(sofas, "n3")?.x == 379 && toN3.visits["s0"]?.side == -1
            && pet(sofas.visited(by: toN3), "s0")?.x == 333 && toN2.visits["s1"]?.side == 1 && pet(sofas.visited(by: toN2), "s1")?.x == 288
            && toR1.visits["s1"]?.side == 1)
    // In the middle of a full sofa neither side is free; with the seat beside it freed the visitor stands there.
    let threeOn = room(unread: ids("n", 3))
    let twoOn = room(unread: ["n0", "n1"], seen: ids("s", 4) + ["n2"], previous: threeOn)
    let byGap = plan(twoOn, [("s0", "n1", 5)]), shut = plan(threeOn, [("s0", "n1", 5)])
    check(
        "office: with neither side free, or one outside the room, there is no walk",
        pet(threeOn, "n1")?.x == 167 && pet(twoOn, "n2")?.zone == .desk && byGap.visits["s0"]?.side == 1
            && pet(twoOn.visited(by: byGap), "s0")?.x == 213 && shut.visits.isEmpty)
    // Never under a waiting card: with the queue full and the sofas full, whoever visits a sofa sitter (only those at a
    // sofa's end, beside a gap, have room) stands clear of every card along the bottom.
    let cards = room(waiting: ids("w", 7), unread: ids("n", 12), busy: ["b0", "b1"], seen: ["s0", "s1", "s2", "s3"])
    let cardRects = cards.pets.filter { $0.zone == .queue }.map(\.words)
    let sofaVisits = cards.pets.filter { $0.zone == .sofa }.compactMap { host -> CGRect? in
        guard let guest = pet(cards.visited(by: plan(cards, [("s0", host.id, 5)])), "s0"), guest.host == host.id else { return nil }
        return CGRect(x: guest.x - 31.5, y: guest.foot - 78.4, width: 63, height: 78.4 + 6)
    }
    check(
        "office: no visitor is placed under a waiting card",
        cardRects.count == 7 && sofaVisits.count >= 2 && sofaVisits.allSatisfy { figure in !cardRects.contains { $0.intersects(figure) } })
    // In every part of the room the visitor's figure stays off its host's plate, and its feet clear of the plate's ends
    // where the plate is as wide as the seat's words.
    func plate(_ p: OfficeLayout.Pet) -> CGRect {
        let high = OfficeLook.lineHeight(12) + 3
        switch p.zone {
        case .desk: return OfficeLayout.deskWords(foot: p.foot, middle: p.x - 26, scale: 1).plate
        case .sofa: return CGRect(x: p.x - 34.5, y: p.foot + 8, width: 69, height: high)
        default: return CGRect(x: p.x - 48, y: p.foot + 8, width: 96, height: high)
        }
    }
    let zones = [(usual, going, "b0"), (sofas, toN2, "n2"), (sofas, toN3, "n3"), (usual, toR1, "r1")]
    let offPlates = zones.allSatisfy { layout, made, hostID in
        guard let visitor = made.visits.first?.key, let guest = pet(layout.visited(by: made), visitor), let host = pet(layout, hostID)
        else { return false }
        let figure = CGRect(x: guest.x - guest.tall * 0.45, y: guest.foot - guest.tall * 1.12, width: guest.tall * 0.9, height: guest.tall * 1.12)
        let feetClear = host.zone == .lounge || guest.x < plate(host).minX || guest.x > plate(host).maxX
        return !figure.intersects(plate(host)) && feetClear
    }
    check("office: in every part of the room the visitor's figure is off its host's plate", offPlates)

    // Its seat is its own while it is away; at work, its screen stays lit there.
    let away = usual.visited(by: plan(usual, [("b1", "s0", 5)]))
    let next = room(busy: ["b0", "b1", "x0"], previous: away)
    let lights = Store()
    lights.readOnly = true
    lights.sessions = [officeSession("b1", "busy", finished: 60), officeSession("s0", "idle", finished: 900)]
    check(
        "office: a visitor's own seat is given to nobody while it is away, and its screen stays lit if it is at work",
        pet(away, "b1")?.host == "s0" && pet(next, "b1")?.seat == pet(usual, "b1")?.seat && pet(next, "b1")?.zone == .desk
            && pet(next, "x0").map { $0.zone != .desk || $0.seat != pet(usual, "b1")?.seat } ?? false
            && OfficePainter.lit(lights, away).contains(pet(usual, "b1")?.seat ?? -1))

    // Chat marks follow the talk: both of a pair whose talk is recent, wherever they sit, whoever walked.
    var long = OfficeRounds()
    long.talk("s0", "n0", opened: now - 900, last: now - 30)
    long.talk("w0", "s1", opened: now - 100, last: now - 30)
    let marked = usual.visited(by: OfficeVisits(), talking: OfficeVisits.talking(long.peers, now: now))
    let quiet = usual.visited(by: OfficeVisits(), talking: OfficeVisits.talking(long.peers, now: now + 600))
    check(
        "office: both of a pair whose talk is recent carry the mark, on a sofa and at a desk, nobody having walked; quiet, neither",
        pet(marked, "s0")?.chats == true && pet(marked, "n0")?.chats == true && pet(marked, "s0")?.x == pet(usual, "s0")?.x
            && pet(marked, "s2")?.chats == false && quiet.pets.allSatisfy { !$0.chats })
    check(
        "office: one under its own waiting card carries no mark; its partner does",
        pet(marked, "w0").map { $0.zone == .queue && !$0.chats } ?? false && pet(marked, "s1")?.chats == true)

    // The mark is painted with the words: paper, three dark dots, over the head; a visitor's name is not.
    let painted = Store()
    painted.readOnly = true
    painted.sessions = [officeSession("b0", "busy", finished: 60)] + (0..<4).map { officeSession("s\($0)", "idle", finished: 900) }
    for s in painted.sessions where s.status == "idle" { painted.seen[s.id] = Date().timeIntervalSince1970 }
    let paintedRoom = OfficePainter.layout(painted, now: now)
    var paintedTalk = OfficeRounds()
    paintedTalk.talk("s0", "b0", opened: now - 5, last: now - 5)
    var seen = OfficeVisits()
    seen.looked = true
    let paintedPlan = OfficeVisits.next(paintedRoom, peers: paintedTalk.peers, rounds: paintedTalk.rounds, previous: seen, now: now)
    let paintedVisit = paintedRoom.visited(by: paintedPlan, talking: OfficeVisits.talking(paintedTalk.peers, now: now))
    if let picture = OfficePainter.picture(painted, paintedVisit, now: now), let guest = pet(paintedVisit, "s0"),
        let owner = pet(paintedVisit, "b0"), let other = pet(paintedVisit, "s1"), let s0 = painted.sessions.first(where: { $0.id == "s0" })
    {
        let px = Pixels(picture)
        func shows(_ p: OfficeLayout.Pet) -> Bool {
            let r = p.mark
            return same(px.at(r.minX + 1.5, r.minY + 3.5), OfficeLook.paper) && same(px.at(r.minX + 16, r.maxY - 3.5), OfficeLook.paper)
                && px.at(r.minX + 8.75, r.midY - 0.25) >> 16 < 0x40
        }
        let words = OfficePainter.words(painted, s0, guest, paintedVisit, now: now, scale: 1)
        check(
            "office: the two talking carry a paper chat mark with three dark dots by their heads, in the still picture too",
            guest.host == "b0" && shows(guest) && shows(owner) && !shows(other))
        check(
            "office: ...and of a visitor's words only the mark is painted",
            words.map { $0.rect.height < 24 && $0.rect.width < 30 && $0.rect.contains(guest.mark) } ?? false)
    } else {
        check("office: the two talking carry a paper chat mark with three dark dots by their heads, in the still picture too", false)
    }

    // The hover card covers neither the pet pointed at nor any partner a line points to.
    let window = CGSize(width: 1134, height: 930), size = CGSize(width: 346, height: 120)
    func clear(_ at: CGPoint, _ rects: [CGRect]) -> Bool {
        let r = CGRect(origin: at, size: size)
        return rects.allSatisfy { !r.intersects($0) } && r.minX >= 8 && r.maxX <= window.width - 8 && r.minY >= 34 && r.maxY <= window.height - 8
    }
    func body(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - 31, y: y, width: 62, height: 84) }
    let owner = body(530, 400), visitor = body(576, 404)
    let byOwner = OfficeHover.origin(beside: owner, card: size, window: window, avoid: [visitor])
    let byVisitor = OfficeHover.origin(beside: visitor, card: size, window: window, avoid: [owner])
    check(
        "office: pointing at a host or at its visitor, the card covers neither",
        clear(byOwner, [owner, visitor]) && clear(byVisitor, [owner, visitor]) && byOwner.x + size.width <= owner.minX
            && byVisitor.x >= visitor.maxX)
    let middle = body(530, 300), row = [body(398, 300), body(708, 300), body(840, 300)]
    let three = OfficeHover.origin(beside: middle, card: size, window: window, avoid: row)
    check("office: ...with three partners in its row it goes below, clear of them all", clear(three, row + [middle]) && three.y >= middle.maxY)
    let edges = [
        (body(40, 400), body(140, 400)), (body(1100, 400), body(990, 400)), (body(530, 40), body(530, 140)), (body(530, 840), body(640, 840)),
    ]
    check(
        "office: ...and at each edge of the window it stays inside, clear of the pet and its partner",
        edges.allSatisfy { target, partner in clear(OfficeHover.origin(beside: target, card: size, window: window, avoid: [partner]), [target, partner]) })
    let around = [body(700, 400), body(360, 400), body(530, 520), body(530, 280), body(530, 600)]
    let fewest = OfficeHover.origin(beside: body(530, 400), card: size, window: window, avoid: around)
    let covering = around.filter { CGRect(origin: fewest, size: size).intersects($0) }.count
    check(
        "office: ...when every place covers a partner, the one covering the fewest, never the pet itself",
        !CGRect(origin: fewest, size: size).intersects(body(530, 400)) && covering == 1)
}

/// Visits over chains of rooms: sessions coming and going and changing, rounds of talk opening and going on, each room
/// laid out from the last as the view lays it out.
@MainActor func officeVisitChainTests() {
    var seed: UInt64 = 0x2545_F491_4F6C_DD1D
    func random(_ n: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((seed >> 33) % UInt64(n))
    }
    var broken: [String] = []
    var rooms = 0, standing = 0, started = 0, ended = 0
    for _ in 0..<20 {
        var kinds: [String: Int] = [:]  // 0 waiting, 1 with news, 2 at work, 3 looked at, 4 resting
        var made = 0, clock = 1_000_000.0
        var rounds: [String: Store.Round] = [:], last: [String: Date] = [:]
        var begun: [String: Date] = [:]  // when each round's visit set off
        func add() {
            kinds["p\(made)"] = [0, 1, 2, 2, 3, 3, 3, 4, 4, 4][random(10)]
            made += 1
        }
        for _ in 0..<(10 + random(30)) { add() }
        var previous: OfficeLayout?
        var plan = OfficeVisits()
        for _ in 0..<100 {
            let now = Date(timeIntervalSince1970: clock)
            for _ in 0..<(1 + random(4)) {
                let keys = kinds.keys.sorted()
                guard keys.count > 2 else { add(); continue }
                let a = keys[random(keys.count)], b = keys[random(keys.count)]
                switch random(8) {
                case 0: add()
                case 1: kinds[a] = nil
                case 2: kinds[a] = random(5)
                case 3, 4, 5:  // a speaks to b: a new round after ten quiet minutes, else the same one going on
                    guard a != b else { break }
                    let pair = OfficeVisits.pair(a, b)
                    if last[pair].map({ now.timeIntervalSince($0) >= 600 }) ?? true { rounds[pair] = Store.Round(opener: a, since: now) }
                    last[pair] = now
                default: break
                }
            }
            for (pair, round) in rounds {
                let ids = pair.split(separator: "|").map(String.init)
                if ids.contains(where: { kinds[$0] == nil }) || now.timeIntervalSince(last[pair] ?? round.since) >= 600 { rounds[pair] = nil }
            }
            var peers: [String: [Peer]] = [:]
            for (pair, when) in last {
                let ids = pair.split(separator: "|").map(String.init)
                guard ids.allSatisfy({ kinds[$0] != nil }) else { continue }
                peers[ids[0], default: []].append(Peer(id: ids[1], last: when))
                peers[ids[1], default: []].append(Peer(id: ids[0], last: when))
            }
            func ids(_ kind: Int) -> [String] { kinds.filter { $0.value == kind }.keys.sorted() }
            let layout = OfficeLayout(waiting: ids(0), unread: ids(1), busy: ids(2), seen: ids(3), resting: ids(4), now: now, previous: previous)
            let before = plan
            plan = OfficeVisits.next(layout, peers: peers, rounds: rounds, previous: plan, now: now)
            let talking = OfficeVisits.talking(peers, now: now)
            let shown = layout.visited(by: plan, talking: talking)
            rooms += 1
            func fail(_ what: String) { if broken.count < 8 { broken.append("room \(rooms): \(what)") } }
            let at = Dictionary(uniqueKeysWithValues: layout.pets.map { ($0.id, $0) })
            let here = Dictionary(uniqueKeysWithValues: shown.pets.map { ($0.id, $0) })
            for (v, visit) in plan.visits {
                guard let seat = at[v], let host = at[visit.host], let stands = here[v] else {
                    fail("\(v) or its host not in the room")
                    continue
                }
                if !(seat.zone == .desk || seat.zone == .lounge) || seat.kind == .waiting { fail("\(v) may not go") }
                if host.zone == .queue { fail("\(v) visits one in the queue") }
                let pair = OfficeVisits.pair(v, visit.host)
                guard let round = rounds[pair], round.opener == v else {
                    fail("\(v) did not open a round going on")
                    continue
                }
                if before.visits[v] == nil {
                    if !before.looked { fail("\(v) set off at the first look") }
                    if now.timeIntervalSince(round.since) >= 30 { fail("\(v) set off for an old round") }
                    if begun[visit.round] != nil { fail("\(v) set off twice in one round") }
                    begun[visit.round] = now
                    started += 1
                }
                // The walk there (3.5 s at most) and 20 s by its host.
                if now >= visit.until || visit.until.timeIntervalSince(begun[visit.round] ?? now) > 23.5 { fail("\(v) stays too long") }
                if host.zone == .desk && visit.side != 1 { fail("\(v) on the plate's side of a desk") }
                let reach = OfficeLayout.body(tall: seat.tall)
                if stands.x - reach.left < 0 || stands.x + reach.right > OfficeLayout.width { fail("\(v) stands outside") }
                if stands.x != host.x + visit.side * 46 || stands.foot != host.foot + 4 { fail("\(v) not beside its host") }
                if stands.zone != seat.zone || stands.seat != seat.seat || !stands.words.isNull { fail("\(v) lost its seat") }
                if let was = previous?.pets.first(where: { $0.id == v }), was.zone == seat.zone, was.seat != seat.seat {
                    fail("\(v)'s seat was given away")
                }
                if let was = before.visits[v], was.round == visit.round, was.hostZone != host.zone || was.hostSeat != host.seat || was.kind != seat.kind {
                    fail("\(v) stayed when its host or its own state moved")
                }
                let figure = CGRect(x: stands.x - seat.tall * 0.45, y: stands.foot - seat.tall * 1.12, width: seat.tall * 0.9, height: seat.tall * 1.12)
                if layout.pets.contains(where: { $0.zone == .queue && $0.kind == .waiting && $0.words.intersects(figure) }) { fail("\(v) under a card") }
                standing += 1
            }
            let hosts = plan.visits.values.map(\.host)
            if Set(hosts).count != hosts.count { fail("a host with two visitors") }
            if hosts.contains(where: { plan.visits[$0] != nil }) { fail("one visits and is visited") }
            for (i, a) in shown.pets.enumerated() {
                for b in shown.pets.dropFirst(i + 1) where abs(a.foot - b.foot) <= 10 && abs(a.x - b.x) < (a.tall + b.tall) * 0.45 {
                    if a.host != b.id && b.host != a.id { fail("\(a.id) on \(b.id)") }
                }
            }
            let marked = Set(shown.pets.filter(\.chats).map(\.id))
            let meant = Set(shown.pets.filter { talking.contains($0.id) && !($0.zone == .queue && $0.kind == .waiting) }.map(\.id))
            if marked != meant { fail("chat marks on the wrong pets") }
            ended += before.visits.keys.filter { plan.visits[$0] == nil }.count
            previous = shown
            clock += Double(random(40))
        }
    }
    print("      \(rooms) rooms in chains: \(started) visits set off, \(ended) ended, \(standing) visitor-rooms")
    check(
        "office: \(rooms) rooms in chains: one short visit a round at most, by the rules, beside its host, nobody on anybody, seats kept",
        broken.isEmpty && started > 50 && ended > 40)
    for line in broken { print("      " + line) }
}

/// In the live view: a round opening, its visit, replies, the switch to the board and back, hovering, stills.
@MainActor func officeVisitViewTests(review: Bool, window: (NSView) -> NSWindow) {
    let size = CGRect(x: 0, y: 0, width: 1134, height: 930), fit = OfficeFit(size.size)
    func wait(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func walk(_ view: NSView, _ id: String) -> CAKeyframeAnimation? {
        officeFigure(view, id)?.animation(forKey: "walk") as? CAKeyframeAnimation
    }
    func route(_ view: NSView, _ id: String) -> [CGPoint] { walk(view, id)?.values?.compactMap { ($0 as? NSValue)?.pointValue } ?? [] }
    /// Until the walks now on these pets have run their length.
    func walked(_ view: NSView, _ ids: [String]) {
        let end = ids.compactMap { walk(view, $0) }.map { $0.beginTime + $0.duration }.max() ?? 0
        if end > CACurrentMediaTime() { wait(end - CACurrentMediaTime() + 0.3) }
    }
    func changing(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { layer in ["walk", "swap", "door"].contains { layer.animation(forKey: $0) != nil } }
            .compactMap(\.name).sorted()
    }
    /// Each pet's walks and fades as they are now: a finished one stays on its layer until something commits, so who
    /// moved is told by what is new.
    func motion(_ view: NSView) -> [String: [ObjectIdentifier]] {
        var all: [String: [ObjectIdentifier]] = [:]
        for layer in officeStage(view)?.sublayers ?? [] {
            if let name = layer.name { all[name] = ["walk", "swap", "door"].compactMap { layer.animation(forKey: $0).map(ObjectIdentifier.init) } }
        }
        return all
    }
    func moved(_ view: NSView, since before: [String: [ObjectIdentifier]]) -> [String] {
        motion(view).filter { !$0.value.isEmpty && $0.value != before[$0.key] }.keys.sorted()
    }
    func seats(_ store: Store, _ view: OfficeTestView) -> OfficeLayout {
        OfficePainter.layout(store, now: view.clock, height: fit.height, scale: fit.scale)
    }
    func pet(_ layout: OfficeLayout, _ id: String) -> OfficeLayout.Pet { layout.pets.first { $0.id == id }! }
    func feet(_ p: OfficeLayout.Pet) -> CGPoint { CGPoint(x: p.x, y: p.foot) }
    func near(_ a: CGPoint?, _ b: CGPoint) -> Bool { a.map { hypot($0.x - b.x, $0.y - b.y) < 1 } ?? false }
    func set(_ store: Store, _ id: String, _ status: String, ago: TimeInterval = 0.5) {
        store.sessions = store.sessions.map { $0.id == id ? officeSession(id, status, finished: ago) : $0 }
    }
    /// Two at work, four looked at, four resting; s0 and b0 talked an hour ago, or are talking now.
    func office(talking: Bool) -> (Store, OfficeTalk)? {
        let store = Store()
        store.readOnly = true
        store.sessions = officeSessions([("b", "busy", 2, 60), ("s", "idle", 4, 900), ("r", "idle", 4, 9 * 3600.0)])
        for s in store.sessions where s.status == "idle" { store.seen[s.id] = Date().timeIntervalSince1970 }
        guard officeDealCutPets(store) else { return nil }
        var talk = OfficeTalk()
        talk.say("s0", to: "b0", at: Date() - (talking ? 30 : 3600))
        store.applyLinks(talk.records)
        return (store, talk)
    }
    /// One looks at the room, then s0 speaks to b0 after an hour's quiet.
    func opened(_ view: OfficeTestView, _ made: (Store, OfficeTalk)) -> OfficeTalk {
        var talk = made.1
        view.update(made.0)
        talk.say("s0", to: "b0", at: view.clock)
        made.0.applyLinks(talk.records, scanned: view.clock)
        view.update(made.0)
        CATransaction.flush()
        return talk
    }
    guard let made = office(talking: false) else {
        return skipped("no pet frames", "visits: not checked in the view")
    }
    let store = made.0

    // s0 opens a round with b0: it walks over along its row to b0's right; nothing else moves.
    let view = OfficeTestView(frame: size)
    let shown = window(view)
    view.update(store)
    let room = seats(store, view), s0 = pet(room, "s0"), b0 = pet(room, "b0")
    let spot = CGPoint(x: b0.x + 46, y: b0.foot + 4)
    var talk = opened(view, made)
    let over = walk(view, "s0"), way = route(view, "s0")
    check(
        "office: one opening a round walks over along its own row to stand by the other; nothing else moves",
        over != nil && way == [feet(s0), CGPoint(x: spot.x, y: s0.foot), spot] && officeAisle(over) == nil && changing(view) == ["s0"]
            && s0.foot == b0.foot)
    let start = view.clock
    for i in 1...10 {
        let speaker = i % 2 == 0 ? "s0" : "b0"
        talk.say(speaker, to: speaker == "s0" ? "b0" : "s0", at: start + Double(i) * 0.5)
        store.applyLinks(talk.records, scanned: start + Double(i) * 0.5)
        view.update(store)
        CATransaction.flush()
    }
    check("office: ten messages back and forth within the round: no second walk, nobody else moves", over != nil && walk(view, "s0") === over && changing(view) == ["s0"])
    walked(view, ["s0"])
    let guestWords = officePart(view, "s0", "words")?.frame ?? .zero, hostWords = officePart(view, "b0", "words")?.frame ?? .zero
    check(
        "office: there, its own words are hidden, only its chat mark over its head; the host keeps its words, and its mark",
        near(officeFigure(view, "s0")?.presentation()?.position, spot) && guestWords.maxY <= -s0.tall + 2 && guestWords.height < 24
            && hostWords.minY < -b0.tall && hostWords.maxY > 10)
    let body = CGRect(x: spot.x - s0.tall * 0.45, y: spot.y - s0.tall * 1.12, width: s0.tall * 0.9, height: s0.tall * 1.12 + 6)
    store.hovered = "s0"
    view.update(store)
    let ring = view.layer?.sublayers?.first { $0.name == "ring" }
    let aim = fit.rect(body)
    let tracked = store.tracker.frames["s0"].map { abs($0.minX - aim.minX) < 0.5 && abs($0.minY - aim.minY) < 0.5 && abs($0.width - aim.width) < 0.5 }
    check(
        "office: its card is a hover away where it stands: the pointer finds it there and the ring goes round it there",
        tracked ?? false && view.target(at: CGPoint(x: aim.maxX - 4, y: aim.midY)) == .pet("s0")
            && ring.map { !$0.isHidden && abs($0.frame.minX - aim.minX) < 0.5 } ?? false)
    store.hovered = nil
    view.update(store)
    // About 20 s after it arrived it walks home, once; the marks stay, for the talk goes on.
    var before = motion(view)
    view.shift = 25
    view.update(store)
    CATransaction.flush()
    let home = walk(view, "s0")
    check(
        "office: about 20 s after it arrived it walks home to its own seat, and only it moves; both keep their marks",
        home != nil && near(route(view, "s0").first, spot) && route(view, "s0").last == feet(s0) && moved(view, since: before) == ["s0"]
            && (officePart(view, "b0", "words")?.frame.minY ?? 0) < -b0.tall)
    view.shift = 30
    view.update(store)
    CATransaction.flush()
    check("office: ...once", home != nil && walk(view, "s0") === home)
    // A reply seven minutes after the last message: the same round; nothing moves.
    before = motion(view)
    view.shift = (start + 5 + 420).timeIntervalSince(Date())
    talk.say("b0", to: "s0", at: view.clock)
    store.applyLinks(talk.records, scanned: view.clock)
    view.update(store)
    CATransaction.flush()
    check(
        "office: a reply seven minutes after the last message moves nobody",
        moved(view, since: before).isEmpty && store.rounds[OfficeVisits.pair("s0", "b0")]?.opener == "s0")
    // Twelve quiet minutes later b0 speaks: a new round, and b0 walks over to s0, which stays at its desk.
    before = motion(view)
    view.shift += 720
    talk.say("b0", to: "s0", at: view.clock)
    store.applyLinks(talk.records, scanned: view.clock)
    view.update(store)
    CATransaction.flush()
    check(
        "office: twelve minutes later the one who replies opens a new round and walks over; the other stays at its seat",
        moved(view, since: before) == ["b0"] && route(view, "b0").last == CGPoint(x: s0.x + 46, y: s0.foot + 4)
            && officeFigure(view, "s0")?.position == feet(s0) && store.rounds[OfficeVisits.pair("s0", "b0")]?.opener == "b0")
    shown.contentView = nil

    // Talking at first load: nobody walks; both carry their marks at their seats.
    if let talking = office(talking: true)?.0 {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(talking)
        CATransaction.flush()
        let room = seats(talking, view)
        check(
            "office: at first load nobody visits; the two talking carry their marks where they sit",
            changing(view).isEmpty && officeFigure(view, "s0")?.position == feet(pet(room, "s0"))
                && ["s0", "b0"].allSatisfy { (officePart(view, $0, "words")?.frame.minY ?? 0) < -pet(room, $0).tall }
                && (officePart(view, "s1", "words")?.frame.minY ?? -99) > 0)
        shown.contentView = nil
    }
    // The host starts waiting during the visit: it goes to your desk, the visitor home.
    if let hosted = office(talking: false) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        _ = opened(view, hosted)
        let home = feet(pet(seats(hosted.0, view), "s0"))
        set(hosted.0, "b0", "waiting")
        view.update(hosted.0)
        CATransaction.flush()
        check(
            "office: a host going to your desk sends its visitor home: both walk, the visitor to its own seat",
            walk(view, "b0") != nil && route(view, "s0").last == home)
        shown.contentView = nil
    }
    // The visitor itself starts waiting: it goes to your desk from where it is, not home first.
    if let asking = office(talking: false) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        _ = opened(view, asking)
        let home = feet(pet(seats(asking.0, view), "s0"))
        walked(view, ["s0"])
        let there = officeFigure(view, "s0")?.position
        set(asking.0, "s0", "waiting")
        view.update(asking.0)
        CATransaction.flush()
        let queue = seats(asking.0, view).pets.first { $0.id == "s0" }
        let way = route(view, "s0")
        check(
            "office: a visitor that starts waiting goes to your desk from where it stands, not home first",
            queue?.zone == .queue && there.map { near(way.first, $0) } ?? false && way.last == queue.map(feet) && !way.contains(home))
        shown.contentView = nil
    }
    // With walking switched off it does not walk over: it is simply there, the room cross-fading.
    if let still = office(talking: false) {
        setOfficeWalks(false)
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        _ = opened(view, still)
        let b0 = pet(seats(still.0, view), "b0")
        check(
            "office: with walking switched off a visitor does not walk over: it is there, the room cross-fading",
            walk(view, "s0") == nil && officeFigure(view, "s0")?.position == CGPoint(x: b0.x + 46, y: b0.foot + 4)
                && (officeStage(view)?.animation(forKey: kCATransition) as? CATransition)?.duration == 0.2)
        UserDefaults.standard.removeObject(forKey: "officeWalks")
        shown.contentView = nil
    }
    // Two at the back open rounds with the two at work at once: both come down the centre aisle, one at a time.
    if let pair = office(talking: false) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        view.update(pair.0)
        let room = seats(pair.0, view)
        let back = room.pets.filter { $0.zone == .lounge }.sorted { $0.x < $1.x }.prefix(2).map(\.id)
        var both = pair.1
        both.say(back[0], to: "b0", at: view.clock - 1)
        both.say(back[1], to: "b1", at: view.clock)
        pair.0.applyLinks(both.records, scanned: view.clock)
        view.update(pair.0)
        CATransaction.flush()
        let spaced = officeSpaced(view, back)
        check(
            "office: two setting off to visit at once come onto their aisle one at a time",
            back.count == 2 && back.allSatisfy { walk(view, $0) != nil } && spaced.spaced && spaced.sharing == 2 && !officeCrowded(view, back))
        shown.contentView = nil
    }
    // Switching to the board and back keeps what the office knew: a visit going on is still there, and one over is not made again.
    if let switched = office(talking: false) {
        let first = OfficeTestView(frame: size)
        let shown = window(first)
        _ = opened(first, switched)
        let b0 = pet(seats(switched.0, first), "b0"), s0 = pet(seats(switched.0, first), "s0")
        shown.contentView = nil
        let again = OfficeTestView(frame: size)
        let back = window(again)
        again.update(switched.0)
        CATransaction.flush()
        let kept = officeFigure(again, "s0")?.position == CGPoint(x: b0.x + 46, y: b0.foot + 4) && walk(again, "s0") == nil
        back.contentView = nil
        let later = OfficeTestView(frame: size)
        later.shift = 25
        let third = window(later)
        later.update(switched.0)
        CATransaction.flush()
        check(
            "office: switching to the board and back keeps a visit going on, and one that is over is not made again",
            kept && officeFigure(later, "s0")?.position == feet(s0) && changing(later).isEmpty)
        third.contentView = nil
    }

    // Hovering one who talks. A room of thirty-two: five resting are behind the door, one of whom talks with s0; s0 has
    // just walked over to b0; s2 and s3 talk between themselves.
    let talking = Store()
    talking.readOnly = true
    let names = ["b0": "Nova 像素风格 Comet 演示界面", "s0": "Sky协同", "s1": "CloudDemo", "s2": "月球漫步", "s3": "Moth", "n0": "Starfish"]
    talking.sessions = [
        officeSession("b0", "busy", finished: 60, name: names["b0"]), officeSession("n0", "idle", finished: 40, name: names["n0"]),
        Session(
            id: "w0", pid: 1, project: "demo-lighting", name: "Owl", status: "waiting", since: Date() - 200,
            summary: "可以重启 Image Service 吗？"),
    ] + (0..<4).map { officeSession("s\($0)", "idle", finished: 900 + Double($0), name: names["s\($0)"]) }
        + (0..<25).map { officeSession("r\($0)", "idle", finished: 9 * 3600 + Double($0), name: "休息 \($0)") }
    for s in talking.sessions where s.id.hasPrefix("s") || s.id.hasPrefix("r") { talking.seen[s.id] = Date().timeIntervalSince1970 }
    guard officeDealCutPets(talking) else { return }
    let crowd = OfficePainter.layout(talking, now: Date(), height: fit.height, scale: fit.scale)
    guard let door = crowd.behindDoorIDs.first else {
        check("office: hovering one who talks dims every other pet to 35%; it and its partners stay bright", false)
        return
    }
    var chatter = OfficeTalk()
    chatter.say("s1", to: names["s0"]!, at: Date() - 1200)  // twenty minutes ago: older talk
    talking.applyLinks(chatter.records)
    let hovering = OfficeTestView(frame: size)
    let hoverWindow = window(hovering)
    hovering.update(talking)
    chatter.say(door, to: names["s0"]!, at: Date() - 2)
    chatter.say("s0", to: names["b0"]!, at: Date() - 1)
    chatter.say("s2", to: names["s3"]!, at: Date())
    talking.applyLinks(chatter.records)
    hovering.update(talking)
    CATransaction.flush()
    let painted = officeRoomLayer(hovering)?.contents as AnyObject?
    let words = Dictionary(uniqueKeysWithValues: crowd.pets.map { ($0.id, officePart(hovering, $0.id, "words")?.contents as AnyObject?) })
    talking.hovered = "s0"
    hovering.update(talking)
    let shownRoom = crowd.visited(by: OfficeSeats.visits(for: talking))
    func head(_ id: String) -> CGPoint {
        let p = shownRoom.pets.first { $0.id == id }!
        return CGPoint(x: fit.offset.x + p.x * fit.scale, y: fit.offset.y + (p.foot - p.tall) * fit.scale)
    }
    let doorMiddle = fit.rect(OfficeLayout.door)
    func lines(_ layer: CALayer?) -> [[CGPoint]] {
        var found: [[CGPoint]] = []
        (layer as? CAShapeLayer)?.path?.applyWithBlock { element in
            let e = element.pointee
            if e.type == .moveToPoint {
                found.append([e.points[0]])
            } else if e.type == .addLineToPoint {
                found[found.count - 1].append(e.points[0])
            }
        }
        return found
    }
    func joins(_ found: [[CGPoint]], _ a: CGPoint, _ b: CGPoint) -> Bool {
        found.contains { line in line.count == 2 && (near(line[0], a) && near(line[1], b) || near(line[0], b) && near(line[1], a)) }
    }
    let root = hovering.layer?.sublayers ?? []
    let links = root.first { $0.name == "links" } as? CAShapeLayer, older = links?.sublayers?.first { $0.name == "older" } as? CAShapeLayer
    let dimmed = crowd.pets.filter { !["s0", "s1", "b0"].contains($0.id) }
    let visits = OfficeSeats.visits(for: talking).hosts
    check(
        "office: hovering one who talks dims every other pet to 35%; it and its partners stay bright",
        visits["s0"] == "b0" && talking.isDimmed("s2") && !talking.isDimmed("s1") && crowd.pets.count == 27 && dimmed.count == 24
            && dimmed.allSatisfy { officeFigure(hovering, $0.id)?.opacity == 0.35 } && ["s0", "s1", "b0"].allSatisfy { officeFigure(hovering, $0)?.opacity == 1 })
    let recent = lines(links), old = lines(older)
    check(
        "office: ...a dashed line joins its head to each partner's head, or to the door for one behind it; older talk at 40%",
        joins(recent, head("s0"), head("b0")) && joins(recent, head("s0"), CGPoint(x: doorMiddle.midX, y: doorMiddle.midY))
            && joins(old, head("s0"), head("s1")) && older?.opacity == 0.4)
    check(
        "office: ...only to its own partners, though another pair talks too: those two are dimmed",
        recent.count == 2 && old.count == 1 && visits["s2"] == "s3" && talking.isDimmed("s2") && talking.isDimmed("s3"))
    let paper = OfficeCanvas.rgb(OfficeLook.paper, 0.6)
    let styled = [links, older].allSatisfy { line in
        line?.strokeColor == paper && line?.lineWidth == 1.5 && line?.lineDashPattern == [4, 4] && line?.fillColor == nil
    }
    let order = ["stage", "links", "ring"].map { name in root.firstIndex { $0.name == name } ?? -1 }
    check("office: ...paper at 60%, 1.5 pt, dashed 4 on 4 off, one layer above the pets and below the ring", styled && order == order.sorted() && !order.contains(-1))
    check(
        "office: ...and nothing is painted again for it",
        painted != nil && officeRoomLayer(hovering)?.contents as AnyObject? === painted
            && crowd.pets.allSatisfy { officePart(hovering, $0.id, "words")?.contents as AnyObject? === words[$0.id] ?? nil })
    talking.hovered = nil
    hovering.update(talking)
    check(
        "office: pointing away, everyone is bright again and the lines are gone",
        crowd.pets.allSatisfy { officeFigure(hovering, $0.id)?.opacity == 1 } && lines(links).isEmpty && lines(older).isEmpty)
    hoverWindow.contentView = nil

    // The still picture, during the visit: the marks, and with the pointer on s0 the dimming, the lines and its card.
    let shifts: [UInt32] = [16, 8, 0]
    func close(_ a: UInt32, _ b: UInt32) -> Bool { shifts.allSatisfy { abs(Int((a >> $0) & 255) - Int((b >> $0) & 255)) <= 12 } }
    for (picture, file) in [(size.size, "/tmp/office.png"), (CGSize(width: 1135, height: 764), "/tmp/office-ipad.png")] {
        let fit = OfficeFit(picture)
        talking.hovered = nil
        let plain = officeStill(talking, size: picture)
        talking.hovered = "s0"
        let hovered = officeStill(talking, size: picture)
        talking.hovered = nil
        let layout = OfficePainter.layout(talking, now: Date(), height: fit.height, scale: fit.scale)
            .visited(by: OfficeSeats.visits(for: talking), talking: OfficeVisits.talking(talking.peers, now: Date()))
        // n0 on the sofa is far from where the card comes up.
        guard let plain, let hovered, let guest = layout.pets.first(where: { $0.id == "s0" }), let host = layout.pets.first(where: { $0.id == "b0" }),
            let n0 = layout.pets.first(where: { $0.id == "n0" })
        else {
            check("office \(Int(picture.width))x\(Int(picture.height)): the still picture shows the visit and its marks", false)
            continue
        }
        if review {
            save(hovered, file)
            save(plain, file.replacingOccurrences(of: ".png", with: "-plain.png"))
        }
        let marks = [guest, host].map { fit.rect($0.mark) }, other = fit.rect(n0.frame), standing = fit.rect(guest.frame)
        let tag = "office \(Int(picture.width))x\(Int(picture.height))"
        check(
            "\(tag): the still picture shows the visitor by its host and both marks; hovered, the others dim",
            guest.host == "b0" && marks.allSatisfy { close(Pixels(plain).at($0.minX + 1.5 * fit.scale, $0.minY + 3.5 * fit.scale), OfficeLook.paper) }
                && officeDifference(plain, hovered, by: 12, in: other) > 0.15)
        // The card comes up right of the visitor, clear of its host on the left: its left edge is the stripe, the stone of
        // one finished and looked at, which nothing else on the card covers.
        let card = CGRect(x: standing.maxX + 11, y: standing.midY - 5, width: 2, height: 10)
        check(
            "\(tag): ...and its card comes up beside it where it stands, clear of its host",
            same(Pixels(hovered).at(card.midX, card.midY), OfficeCard.stone) && officeDifference(plain, hovered, by: 12, in: card) > 0.5
                && officeDifference(plain, hovered, by: 12, in: fit.rect(host.body).insetBy(dx: 8, dy: 8)) < 0.6)
        // The view's half of the rule: pointed at the host, whose first choice (its right) is where its visitor stands, the
        // card goes to its left and leaves the visitor in sight.
        talking.hovered = "b0"
        let atHost = officeStill(talking, size: picture)
        talking.hovered = nil
        let hostFrame = fit.rect(host.frame)
        check(
            "\(tag): pointed at the host, its card keeps clear of the partner standing at its right",
            atHost.map {
                officeDifference(plain, $0, by: 12, in: fit.rect(guest.body).insetBy(dx: 4, dy: 4)) < 0.2
                    && same(Pixels($0).at(hostFrame.minX - 14, hostFrame.midY), OfficeCard.fill)
            } ?? false)
    }

    guard review else { return }
    // For review only: contact sheets of a round opening (over, standing, home), a reply seven minutes later, and one
    // twelve minutes later; a still with the pointer on one whose partner sits beside it on the sofa.
    if let sheet = office(talking: false) {
        let view = OfficeTestView(frame: size)
        let shown = window(view)
        var talk = opened(view, sheet)
        var frames = officeRecord(view, seconds: 1.8, every: 0.3, label: " speaks, walks over")
        view.shift = 12
        view.update(sheet.0)
        frames += officeRecord(view, seconds: 0.6, every: 0.3, label: " stands")
        view.shift = 25
        view.update(sheet.0)
        CATransaction.flush()
        frames += officeRecord(view, seconds: 1.8, every: 0.3, label: " goes back, the mark stays")
        officeSaveSheet(frames, size: size.size, to: "/tmp/office-sheet-open.png")
        view.shift = 25 + 420
        talk.say("b0", to: "s0", at: view.clock)
        sheet.0.applyLinks(talk.records, scanned: view.clock)
        view.update(sheet.0)
        CATransaction.flush()
        officeSaveSheet(officeRecord(view, seconds: 1.2, every: 0.3, label: " replies after 7 minutes"), size: size.size, to: "/tmp/office-sheet-seven.png")
        view.shift += 720
        talk.say("b0", to: "s0", at: view.clock)
        sheet.0.applyLinks(talk.records, scanned: view.clock)
        view.update(sheet.0)
        CATransaction.flush()
        officeSaveSheet(officeRecord(view, seconds: 2.1, every: 0.3, label: " replies after 12 minutes"), size: size.size, to: "/tmp/office-sheet-twelve.png")
        shown.contentView = nil
    }
    officeReplayYesterday()
    let sofa = Store()
    sofa.readOnly = true
    sofa.sessions = officeSessions([("b", "busy", 2, 60), ("s", "idle", 4, 900), ("n", "idle", 3, 30), ("r", "idle", 6, 9 * 3600.0)])
    for s in sofa.sessions where s.id.hasPrefix("s") || s.id.hasPrefix("r") { sofa.seen[s.id] = Date().timeIntervalSince1970 }
    if officeDealCutPets(sofa) {
        var talk = OfficeTalk()
        talk.say("n0", to: "n2", at: Date() - 40)
        talk.say("n2", to: "n0", at: Date() - 20)
        talk.say("n0", to: "s1", at: Date() - 1500)
        sofa.applyLinks(talk.records)
        sofa.hovered = "n0"
        save(officeStill(sofa, size: size.size), "/tmp/office-sofa-hover.png")
    }
}

/// Sample messages from the links cache, when present (read, never written), replayed as the store scans
/// them every 10 s, with every session that talked at a desk. How many rounds open, and so how many walks.
@MainActor func officeReplayYesterday() {
    let file = cacheFolder + "/links-v3.json"
    guard let data = FileManager.default.contents(atPath: file),
        let records = try? JSONDecoder().decode([String: LinkScanner.Record].self, from: data)
    else {
        print("      replay: no links cache")
        return
    }
    let sessions = Loader().load()
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let times = records.values.flatMap { $0.sent.map(\.at) + $0.received.map(\.at) }.compactMap { iso.date(from: $0) }
    guard let lastTime = times.max() else { return }
    let from = lastTime - 24 * 3600
    func upTo(_ t: Date) -> [String: LinkScanner.Record] {
        records.mapValues { r in
            var cut = r
            cut.sent = r.sent.filter { iso.date(from: $0.at).map { $0 <= t } ?? false }
            cut.received = r.received.filter { iso.date(from: $0.at).map { $0 <= t } ?? false }
            return cut
        }
    }
    let store = Store()
    store.readOnly = true
    store.sessions = sessions
    store.applyLinks(upTo(from), scanned: from)
    // Each scan that could see something new: 10 s after each message, on the 10 s grid; and once more 30 s later.
    let scans = Set(times.filter { $0 > from }.flatMap { t -> [Date] in
        let grid = (t.timeIntervalSince1970 / 10).rounded(.up) * 10
        return [Date(timeIntervalSince1970: grid), Date(timeIntervalSince1970: grid + 30)]
    }).sorted()
    var opened: [(pair: String, round: Store.Round)] = []
    var known = Set<String>()
    for scan in scans {
        store.applyLinks(upTo(scan), scanned: scan)
        for (pair, round) in store.rounds.sorted(by: { $0.key < $1.key }) where known.insert("\(pair) \(round.since)").inserted {
            opened.append((pair, round))
        }
    }
    let talkers = Set(opened.flatMap { $0.pair.split(separator: "|").map(String.init) })
    // Who could go: at a desk (the talkers looked at), nobody waiting; one visitor at a host at a time.
    let layout = OfficeLayout(
        waiting: [], unread: [], busy: [], seen: sessions.map(\.id).filter(talkers.contains), resting: sessions.map(\.id).filter { !talkers.contains($0) })
    var plan = OfficeVisits()
    plan.looked = true
    var walks = 0
    let names = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    var lines: [String] = []
    for (pair, round) in opened.sorted(by: { $0.round.since < $1.round.since }) {
        let now = round.since + 5
        let partner = pair.split(separator: "|").map(String.init).first { $0 != round.opener } ?? ""
        let peers = [round.opener: [Peer(id: partner, last: now)], partner: [Peer(id: round.opener, last: now)]]
        plan = OfficeVisits.next(layout, peers: peers, rounds: [pair: round], previous: plan, now: now)
        let goes = plan.visits[round.opener] != nil
        walks += goes ? 2 : 0
        lines.append("        \(round.since): \(names[round.opener] ?? round.opener) → \(names[partner] ?? partner)\(goes ? "" : " (marks only)")")
        plan = OfficeVisits.next(layout, peers: peers, rounds: [pair: round], previous: plan, now: now + 60)
    }
    print("      replay of the 24 h to \(lastTime): \(scans.count) scans, \(opened.count) rounds opened, \(walks) walks with everyone talking at a desk")
    for line in lines { print(line) }
}

// ───────── What just happened ─────────

/// The log behind the notice board, of what is news to the user; the board on the wall with its mark; its card.
/// Everything here keeps the log in the checks' scratch file; the panel's own is never touched.
@MainActor func officeActivityTests() {
    let t = Date()
    let file = FileManager.default
    func s(_ id: String, _ status: String, name: String? = nil, summary: String = "", waitingFor: String = "") -> Session {
        Session(id: id, pid: 1, project: "p", name: name ?? id, status: status, since: t - 60, summary: summary, waitingFor: waitingFor)
    }
    func said(_ events: [OfficeActivity.Event]) -> [String] { events.map { "\($0.name) \($0.text)" } }
    func said(_ before: [Session], _ after: [Session]) -> [String] { said(OfficeActivity.events(from: before, to: after, at: t)) }
    func event(_ i: Int, _ kind: OfficeActivity.Event.Kind, _ name: String, partner: String? = nil) -> OfficeActivity.Event {
        OfficeActivity.Event(at: t - 3600 + Double(i) * 300, id: "e\(i)", name: name, kind: kind, partner: partner)
    }
    let path = OfficeActivity.file
    check("activity: the checks keep the log in a scratch file", !path.hasPrefix(home + "/Library/Caches/") && path.hasSuffix(".json"))
    guard !path.hasPrefix(home + "/Library/Caches/") else { return }  // never write, or remove, the panel's own log
    check("activity: no check before these wrote to it", !file.fileExists(atPath: path))
    try? file.removeItem(atPath: path)

    // Pure: two readings of the sessions, and what in between is news to the user.
    check("activity: busy to idle has finished (the done line)", said([s("a", "busy")], [s("a", "idle")]) == ["a 干完了"])
    check(
        "activity: entering waiting says what for: waiting for approval, waiting for an answer, else just waiting",
        said(
            [s("a", "idle"), s("b", "busy"), s("c", "busy")],
            [
                s("a", "waiting", waitingFor: "permission prompt"), s("b", "waiting", waitingFor: "input needed"),
                s("c", "waiting", waitingFor: "x"),
            ])
            == ["a 在等你批准", "b 在等你回答", "c 在等你"])
    check(
        "activity: what he does himself is not news: one opening, closing, or starting to work logs nothing",
        said([s("a", "idle"), s("b", "waiting"), s("c", "idle")], [s("a", "busy"), s("b", "busy"), s("d", "busy", name: "新会话")]).isEmpty)
    check(
        "activity: a session that only changes its summary logs nothing",
        said([s("a", "busy", summary: "一"), s("b", "idle", summary: "旧")], [s("a", "busy", summary: "二"), s("b", "idle", summary: "新")]).isEmpty)
    check(
        "activity: waiting to idle, and a state read again, log nothing",
        said([s("a", "waiting"), s("b", "busy")], [s("a", "idle"), s("b", "busy")]).isEmpty && said([s("a", "busy")], [s("a", "busy")]).isEmpty)
    let one = OfficeActivity.events(from: [s("a", "busy", name: "那时的名字")], to: [s("a", "idle", name: "那时的名字")], at: t).first
    check(
        "activity: an event holds its time, the session's id, its name at that moment and its kind",
        one.map { $0.at == t && $0.id == "a" && $0.name == "那时的名字" && $0.kind == .finished } ?? false)

    // An older log file keeps what is still news and drops the rest; its count is held to what is kept.
    let earlier = """
        {"events":[{"at":1,"id":"a","name":"Alpha","kind":"opened"},{"at":2,"id":"a","name":"Alpha","kind":"started"},\
        {"at":3,"id":"a","name":"Alpha","kind":"finished"},{"at":4,"id":"b","name":"Bravo","kind":"closed"},\
        {"at":5,"id":"a","name":"Alpha","kind":"talk","partner":"Bravo"}],"unseen":9}
        """
    try? earlier.write(toFile: path, atomically: true, encoding: .utf8)
    let older = OfficeActivity.load()
    try? #"{"events":[{"at":3,"id":"a","name":"Alpha","kind":"finished"}],"unseen":-3}"#.write(toFile: path, atomically: true, encoding: .utf8)
    let negative = OfficeActivity.load()
    try? file.removeItem(atPath: path)
    check(
        "activity: an older log loads, keeping the finished and talk lines, dropping the opened, started-work and closed ones; its count stays within what is kept",
        said(older.events) == ["Alpha 干完了", "Alpha 找 Bravo 说话"] && older.unseen == 2 && negative.events.count == 1 && negative.unseen == 0)

    // Talk: a round opening, for its opener, with the other one's name; old talk is never news.
    let base = Date() - 4000
    let talkers = Store()
    talkers.readOnly = true
    talkers.sessions = [officeSession("A", "idle", finished: 900, name: "Alpha"), officeSession("B", "idle", finished: 900, name: "Bravo")]
    talkers.noteChanges(to: talkers.sessions, at: base - 120)  // the panel first saw them two minutes before
    var talk = OfficeTalk()
    talk.say("A", to: "Bravo", at: base - 3600)
    talkers.applyLinks(talk.records, scanned: base)
    let launch = talkers.activity.events.isEmpty
    talk.say("A", to: "Bravo", at: base + 2)
    talk.say("B", to: "Alpha", at: base + 7)
    talkers.applyLinks(talk.records, scanned: base + 10)
    let opened = talkers.activity.events
    check(
        "activity: a round of talk opening reads \"goes to talk to <the other's name>\", for the one who opened it; nothing at launch",
        launch && said(opened) == ["Alpha 找 Bravo 说话"] && opened.first?.id == "A" && opened.first?.kind == .talk)
    talk.say("A", to: "Bravo", at: base + 427)
    talkers.applyLinks(talk.records, scanned: base + 430)
    check(
        "activity: a reply within the round logs nothing more, though the board flies a plane for it",
        !opened.isEmpty && talkers.activity.events == opened && talkers.flights.count == 2)
    talk.say("A", to: "Charlie", at: base - 3 * 86400)
    talkers.sessions.append(officeSession("C", "idle", finished: 900, name: "Charlie"))
    talkers.applyLinks(talk.records, scanned: base + 440)
    let stale = talkers.activity.events == opened
    talkers.sessions.append(officeSession("D", "idle", finished: 900, name: "Delta"))
    talk.say("D", to: "Alpha", at: base + 445)
    talkers.applyLinks(talk.records, scanned: base + 450)
    check(
        "activity: talk from three days ago, seen for the first time, logs nothing; a pair first seen talking now does",
        stale && said(talkers.activity.events) == ["Alpha 找 Bravo 说话", "Delta 找 Alpha 说话"])

    // Nothing in the first minute after the panel first sees anyone: a restart, or Orca restoring the sessions at
    // login, is not news.
    let loaded = Store()
    loaded.readOnly = true
    loaded.noteChanges(to: [], at: t)  // the launch found nobody
    loaded.noteChanges(to: [s("a", "busy"), s("b", "busy")], at: t + 4)  // first sight
    loaded.sessions = [s("a", "busy"), s("b", "busy")]
    loaded.noteChanges(to: [s("a", "idle"), s("b", "busy"), s("c", "waiting")], at: t + 50)
    let settling = loaded.activity.events.isEmpty
    loaded.sessions = [s("a", "idle"), s("b", "busy"), s("c", "waiting")]
    loaded.noteChanges(to: [s("a", "idle"), s("b", "idle"), s("c", "waiting")], at: t + 70)
    let early = Store()
    early.readOnly = true
    early.sessions = [officeSession("A", "idle", finished: 900, name: "Alpha"), officeSession("B", "idle", finished: 900, name: "Bravo")]
    early.noteChanges(to: early.sessions, at: base)
    var hello = OfficeTalk()
    hello.say("A", to: "Bravo", at: base - 7200)
    early.applyLinks(hello.records, scanned: base + 2)
    hello.say("A", to: "Bravo", at: base + 20)
    early.applyLinks(hello.records, scanned: base + 30)
    check(
        "activity: nothing is logged in the first minute after the panel first sees anyone, not even a round of talk; after it, news is",
        settling && said(loaded.activity.events) == ["b 干完了"] && early.activity.events.isEmpty)

    // The tick's own line that records changes, driven with readings of the checks' own.
    let ticking = Store()
    ticking.readOnly = true
    ticking.take([s("a", "busy"), s("b", "idle")], at: t)
    ticking.take([s("a", "busy"), s("b", "idle")], at: t + 30)
    ticking.take([s("a", "idle"), s("b", "idle")], at: t + 90)
    ticking.take([s("a", "idle"), s("b", "idle", summary: "新的进度")], at: t + 92)
    check(
        "activity: each tick's reading of the sessions goes through the log: a session finishing after the first minute is logged once",
        said(ticking.activity.events) == ["a 干完了"] && ticking.sessions.map(\.status) == ["idle", "idle"])

    // The latest fifty; the count of what the user has not seen, cleared by pointing, the lines kept.
    var log = OfficeActivity()
    for i in 0..<60 { log.add([event(i, .finished, "s\(i)")]) }
    check(
        "activity: the latest 50 are kept, oldest first",
        log.events.count == 50 && log.events.first?.id == "e10" && log.events.last?.id == "e59")
    var counted = OfficeActivity()
    counted.add([event(0, .finished, "a"), event(1, .approve, "b"), event(2, .talk, "c", partner: "d")])
    let three = counted.unseen
    counted.looked()
    check(
        "activity: it counts what came since the board was last pointed at; pointing clears the count, not the lines",
        three == 3 && counted.unseen == 0 && counted.events.count == 3)

    // The lines: the latest eight, newest first, each its time, the colour of its kind, the name and what happened.
    var dozen = OfficeActivity()
    let names = ["Owl", "月球漫步", "Moth", "Sky协同"]
    let kinds: [OfficeActivity.Event.Kind] = [
        .finished, .approve, .talk, .answer, .waiting, .finished, .talk, .approve, .finished, .waiting, .talk, .approve,
    ]
    dozen.add(kinds.enumerated().map { i, kind in event(i, kind, names[i % 4], partner: kind == .talk ? "Nova 像素风格 Comet" : nil) })
    let lines = OfficeBoardCard.lines(dozen, waiting: Set(dozen.events.map(\.id)))
    check(
        "activity: the card lists the latest eight, newest first, each with its time, name and what happened",
        lines.count == 8 && lines.map(\.name) == (4..<12).reversed().map { names[$0 % 4] }
            && lines.first?.time == OfficeBoardCard.time(t - 3600 + 11 * 300, now: Date()) && lines.first?.text == "在等你批准"
            && lines.contains { $0.text == "找 Nova 像素风格 Comet 说话" && $0.partner == "Nova 像素风格 Comet" })
    let dots: [(OfficeActivity.Event.Kind, UInt32)] = [
        (.approve, 0xFF6B4A), (.answer, 0xFF6B4A), (.waiting, 0xFF6B4A), (.finished, 0xE9E6F7), (.talk, 0x9A96B8),
    ]
    check(
        "activity: dots are coral for waiting, paper for finished, quiet for talk",
        dots.allSatisfy { $0.0.dot == $0.1 }
            && lines.allSatisfy { line in dozen.events.contains { $0.name == line.name && $0.kind.dot == line.dot } })
    check(
        "activity: the card has its fixed title; with nothing logged it shows its empty line",
        OfficeBoardCard.title == "刚才发生了什么" && OfficeBoardCard.empty == "还没有动静。" && OfficeBoardCard.lines(OfficeActivity(), waiting: []).isEmpty)
    var calendar = Calendar.current
    calendar.timeZone = TimeZone.current
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    let lateLastNight = calendar.date(byAdding: .minute, value: -(12 * 60 + 20), to: noon)!
    let days = calendar.date(byAdding: .day, value: -3, to: calendar.date(bySettingHour: 9, minute: 5, second: 0, of: Date())!)!
    let monthDay = DateFormatter()
    monthDay.dateFormat = "M月d日"
    check(
        "activity: a line's time is HH:mm today, \"yesterday\" and HH:mm for yesterday, and with its date before that",
        OfficeBoardCard.time(noon, now: noon + 3600) == "12:00" && OfficeBoardCard.time(lateLastNight, now: noon) == "昨天 23:40"
            && OfficeBoardCard.time(days, now: noon) == monthDay.string(from: days) + " 09:05")

    // On a talk line the names are whole while the line has room, and are cut only when it has none, each then
    // keeping at least half of what is left.
    func shown(_ row: OfficeBoardRow, width: CGFloat?) -> CGImage? {
        let renderer = ImageRenderer(content: row.environment(\.zoom, 1).environment(\.colorScheme, .dark))
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        renderer.scale = 2
        return renderer.cgImage
    }
    let room = OfficeBoardCard.lineWidth
    let whole = [("CloudDemo", "Sky协同"), ("helper-agent-31", "Sparrow kite调试")].allSatisfy { name, partner in
        let row = OfficeBoardRow(line: .init(time: "14:03", dot: 0x9A96B8, name: name, text: "找 \(partner) 说话", partner: partner))
        guard let ideal = shown(row, width: nil), let fitted = shown(row, width: room) else { return false }
        return CGFloat(ideal.width) / 2 <= room && ideal.width == fitted.width && Pixels(ideal).data == Pixels(fitted).data
    }
    let long = OfficeBoardRow(
        line: .init(
            time: "14:03", dot: 0x9A96B8, name: "装点 Star Shop 的 CSS 和 Fonts", text: "找 Nova 像素风格 Comet 演示界面 说话",
            partner: "Nova 像素风格 Comet 演示界面"))
    let cut = shown(long, width: nil).map { CGFloat($0.width) / 2 > room } ?? false
        && shown(long, width: room).map { CGFloat($0.width) / 2 <= room + 0.5 } ?? false
    let split = OfficeBoardRowLayout.self
    check(
        "activity: a talk line's names are whole when the line has room (CloudDemo, helper-agent-31), and cut only when it has none",
        whole && cut && split.split(name: 60, what: 90, room: 200) == (60, 90) && split.split(name: 40, what: 300, room: 200) == (40, 160)
            && split.split(name: 200, what: 180, room: 200) == (100, 100) && split.split(name: 250, what: 50, room: 200) == (150, 50))

    // Kept in the cache file: read back after a restart, never written by a read-only store, written only when an event
    // is added or the count changes.
    let looker = Store()
    looker.readOnly = true
    looker.sessions = [s("a", "busy")]
    looker.noteChanges(to: [s("a", "busy")], at: t)
    looker.noteChanges(to: [s("a", "idle")], at: t + 90)
    let remembered = looker.activity.events.count == 1 && looker.activity.unseen == 1
    looker.lookedAtBoard()
    check(
        "activity: a read-only store keeps what happened in memory but never writes the file",
        remembered && looker.activity.unseen == 0 && !file.fileExists(atPath: path))
    let writer = Store()
    writer.sessions = [s("a", "busy")]
    writer.noteChanges(to: [s("a", "busy")], at: t)
    writer.noteChanges(to: [s("a", "idle")], at: t + 90)
    let written = file.fileExists(atPath: path)
    let reborn = Store()
    check(
        "activity: what was logged is kept in the cache file and read back after a restart, count and all",
        written && reborn.activity == writer.activity && reborn.activity.events.count == 1 && reborn.activity.unseen == 1)
    try? file.removeItem(atPath: path)
    writer.sessions = [s("a", "idle")]
    var published = 0
    let watch = writer.objectWillChange.sink { _ in published += 1 }
    writer.noteChanges(to: [s("a", "idle", summary: "新的进度")], at: t + 94)
    let quiet = !file.fileExists(atPath: path) && published == 0
    writer.lookedAtBoard()
    let cleared = file.fileExists(atPath: path) && writer.activity.unseen == 0 && published > 0
    try? file.removeItem(atPath: path)
    published = 0
    writer.lookedAtBoard()
    check(
        "activity: a quiet reading, or pointing at a board with nothing new, writes and publishes nothing; clearing the count writes",
        quiet && cleared && !file.fileExists(atPath: path) && published == 0)
    watch.cancel()
    try? file.removeItem(atPath: path)

    // The board on the wall, part of the room piece; a paper dot at its corner while the user has not seen it all.
    let board = OfficeLayout.board
    check(
        "office: the notice board hangs on the wall between the right-hand window and the door, clear of both",
        board.width >= 60 && board.minX >= 766 + 20 && OfficeLayout.boardArea.maxX + 20 <= 1000 && board.minY >= 8 && board.maxY <= 62)
    func store(logged count: Int) -> Store {
        let store = officeStore()
        store.log((0..<count).map { event($0, .finished, "n\($0)") })
        return store
    }
    for (height, scale) in [(CGFloat(764), CGFloat(1)), (979, 1134 / 1194)] {
        let plain = store(logged: 0), news = store(logged: 3), more = store(logged: 12)
        let layout = OfficePainter.layout(plain, now: t, height: height, scale: scale)
        guard let bare = OfficePainter.room(plain, layout, scale: scale), let marked = OfficePainter.room(news, layout, scale: scale),
            let many = OfficePainter.room(more, layout, scale: scale)
        else {
            check("office: the room is painted with its notice board", false)
            continue
        }
        let a = Pixels(bare), b = Pixels(marked)
        check(
            "office: in a room \(Int(height)) high the board is a dark panel in its frame, three note lines pinned on it",
            same(a.at(801.5, 30), 0x647785) && same(a.at(806, 50), 0x26323D) && same(a.at(810, 21), 0xAC9574) && same(a.at(820, 19.5), 0xACA699))
        check(
            "office: ...a paper dot, outlined like the furniture, at its top-right corner while he has not seen it all; none when he has",
            same(b.at(880.5, 12.5), OfficeLook.paper) && same(b.at(875.5, 12.5), OfficeTheme.current.palette.line) && same(a.at(880.5, 12.5), OfficeTheme.current.palette.wall)
                && !(0..<8).contains { same(b.at(876.5 + CGFloat($0), 8.5 + CGFloat($0)), OfficeLook.call) })
        check("office: ...the same dot for three things as for twelve: no number", Pixels(many).data == b.data)
    }
    let roomLayout = OfficePainter.layout(officeStore(), now: t)
    func key(_ count: Int) -> String { OfficePainter.roomKey(store(logged: count), roomLayout, scale: 1) }
    check(
        "office: the room is painted again when the dot comes or goes, not as more arrive",
        key(0) != key(1) && key(1) == key(4) && key(4) == key(12))

    // Pointing at it, its ring and its card; only pointing at it in a live office that can be seen clears the dot.
    for size in [CGSize(width: 1134, height: 930), CGSize(width: 1135, height: 764)] {
        let at = "office \(Int(size.width))x\(Int(size.height))"
        let shown = store(logged: 3)
        let view = OfficeView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(shown)
        let fit = OfficeFit(size), r = fit.rect(OfficeLayout.board), middle = CGPoint(x: r.midX, y: r.midY)
        let dot = fit.rect(CGRect(x: 882, y: 9, width: 0, height: 0)).origin
        check(
            "\(at): pointing at the notice board, or at its dot, points at it, through the pointer's tracker as the door does",
            view.target(at: middle) == .board && shown.tracker.card(at: middle) == OfficeLayout.boardKey && view.target(at: dot) == .board
                && shown.tracker.card(at: dot) == OfficeLayout.boardKey
                && shown.tracker.frames[OfficeLayout.boardKey].map { near($0, fit.rect(OfficeLayout.boardArea)) } ?? false)
        shown.hovered = OfficeLayout.boardKey
        view.update(shown)
        let ring = view.layer?.sublayers?.first { $0.name == "ring" }
        check(
            "\(at): ...a ring goes round it and its dot",
            ring.map { !$0.isHidden && near($0.frame, fit.rect(OfficeLayout.boardArea)) } ?? false)
        // Left of it or right of it, as there is room: a few points into the card's edge, below the title bar.
        func backed(_ image: CGImage?) -> Bool {
            let sides = [r.minX - 14, fit.rect(OfficeLayout.boardArea).maxX + 14]
            return image.map { p in sides.contains { same(Pixels(p).at($0, 100), 0x1B1830) } } ?? false
        }
        let hovered = officeStill(shown, size: size)
        shown.hovered = nil
        let unhovered = officeStill(shown, size: size)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        check(
            "\(at): its card comes up beside it, on the hover cards' backing; a still picture leaves the dot alone",
            backed(hovered) && unhovered != nil && !backed(unhovered) && shown.activity.unseen == 3)
        let live = OfficeTestView(frame: CGRect(origin: .zero, size: size))
        var kept = true
        for pointed in [nil, "o-busy", OfficeLayout.doorKey] {
            shown.hovered = pointed
            live.update(shown)
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            kept = kept && shown.activity.unseen == 3
        }
        live.shownOnScreen = false
        shown.hovered = OfficeLayout.boardKey
        live.update(shown)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        check(
            "\(at): a live office pointed at nobody, at a pet or at the door, or that nobody can see, leaves the dot",
            kept && shown.activity.unseen == 3)
        live.shownOnScreen = true
        live.update(shown)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        live.update(shown)
        let painted = (officeRoomLayer(live)?.contents as! CGImage?).map(Pixels.init)
        check(
            "\(at): pointing at the board in a live office clears the dot, and the board is painted without it",
            shown.activity.unseen == 0 && painted.map { same($0.at(880.5, 12.5), OfficeTheme.current.palette.wall) } ?? false)
    }
    let named = officeStore()
    let namedLayout = OfficePainter.layout(named, now: t)
    check(
        "office: --hover with the board token points the still picture at the notice board; a session's name still points at its pet",
        officePointed(named: "动态板", store: named, layout: namedLayout) == OfficeLayout.boardKey
            && officePointed(named: "o-busy", store: named, layout: namedLayout) == "o-busy")
    // The tooltip came slowly and said what both names already say: the switch has none, on either name.
    let source = String(decoding: FileManager.default.contents(atPath: "Office.swift") ?? Data(), as: UTF8.self)
    let switchCode = source.components(separatedBy: "struct OfficeSwitch: View {").dropFirst().first?.components(separatedBy: "\n}\n").first ?? ""
    check("office: the title bar's switch has no tooltip on any name", switchCode.contains("segments(mode:") && !switchCode.contains(".help("))

    // For reading: a made-up office with a dozen things logged, names long and short, with and without the board pointed at.
    if ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil {
        let office = Store()
        office.readOnly = true
        let who = [
            "Owl", "月球漫步", "Moth", "Sky协同", "CloudDemo", "Starfish", "Nova 像素风格 Comet 演示界面", "装点 Star Shop 的 CSS 和 Fonts",
            "helper-agent-31", "Sparrow kite调试",
        ]
        office.sessions = [
            Session(
                id: "w0", pid: 1, project: "demo-lighting", name: who[0], status: "waiting", since: t - 200,
                summary: "可以重启 Image Service 吗？"),
            officeSession("n0", "idle", finished: 40, name: who[5]), officeSession("b0", "busy", finished: 60, name: who[6]),
            officeSession("b1", "busy", finished: 300, name: who[1]),
        ] + [2, 3, 4, 7, 8, 9].map { officeSession("s\($0)", "idle", finished: 900 + Double($0), name: who[$0]) }
            + (0..<14).map { officeSession("r\($0)", "idle", finished: 9 * 3600 + Double($0), name: "休息 \($0)") }
        for s in office.sessions where s.id.hasPrefix("s") || s.id.hasPrefix("r") { office.seen[s.id] = t.timeIntervalSince1970 }
        _ = officeDealCutPets(office)
        let story: [(OfficeActivity.Event.Kind, Int, Int?)] = [
            (.finished, 2, nil), (.talk, 4, 3), (.approve, 0, nil), (.finished, 3, nil), (.answer, 5, nil), (.talk, 8, 9),
            (.finished, 1, nil), (.waiting, 7, nil), (.talk, 6, 7), (.finished, 5, nil), (.approve, 9, nil), (.talk, 7, 6),
        ]
        func logged(_ store: Store) {
            store.log(story.enumerated().map { i, line in
                OfficeActivity.Event(
                    at: t - 3300 + Double(i) * 280, id: "x\(line.1)", name: who[line.1], kind: line.0, partner: line.2.map { who[$0] })
            })
        }
        let size = CGSize(width: 1134, height: 930)
        save(officeStill(office, size: size), "/tmp/office-1134x930-plain.png")
        logged(office)
        save(officeStill(office, size: size), "/tmp/office-1134x930-dot.png")
        office.hovered = OfficeLayout.boardKey
        save(officeStill(office, size: size), "/tmp/office-1134x930-hover.png")
        save(officeStill(office, size: CGSize(width: 1135, height: 764)), "/tmp/office-1135x764-hover.png")
    }
}

// ───────── The card, the menu and the lists ─────────

/// The right-click menu every session has, on the board and in the office alike; and what a pin does to one at the back.
@MainActor func officeMenuTests() {
    let now = Date()
    let store = Store()
    store.readOnly = true
    func kept(_ s: Session, in cwd: String = NSTemporaryDirectory()) -> Session {
        var s = s
        s.cwd = cwd
        return s
    }
    let waiting = kept(officeSession("m-wait", "waiting", finished: 60)), busy = kept(officeSession("m-busy", "busy", finished: 60))
    let news = kept(officeSession("m-news", "idle", finished: 30)), seen = kept(officeSession("m-seen", "idle", finished: 600))
    let pinned = kept(officeSession("m-pin", "idle", finished: 600)), resting = kept(officeSession("m-rest", "idle", finished: 9 * 3600))
    store.sessions = [waiting, busy, news, seen, pinned, resting]
    for s in [seen, pinned, resting] { store.seen[s.id] = now.timeIntervalSince1970 }
    store.pinned = [pinned.id]
    /// Each line as its title and whether it can be chosen; the separator as a dash.
    func menu(_ s: Session) -> [String] {
        sessionMenu(store, s).map { $0.action == .separator ? "—" : $0.title + ($0.enabled ? " ✓" : " ✗") }
    }
    let mark = "标记待回复（留在「有话说」）", folder = "在访达里打开项目目录", desk = "转到工位（算看过）", rest = "转到休息区（不需要了）"
    check(
        "menu: waiting, it can be jumped to and its folder opened; not pinned, not moved between the quiet zones",
        menu(waiting) == ["跳到会话 ✓", "\(mark) ✗", "\(desk) ✗", "\(rest) ✗", "—", "\(folder) ✓"])
    check(
        "menu: at work, the same: a pin would come off by itself, and it is at a desk anyway",
        menu(busy) == ["跳到会话 ✓", "\(mark) ✗", "\(desk) ✗", "\(rest) ✗", "—", "\(folder) ✓"])
    check(
        "menu: finished with news, every line: it can go to a desk or to the rest area",
        menu(news) == ["跳到会话 ✓", "\(mark) ✓", "\(desk) ✓", "\(rest) ✓", "—", "\(folder) ✓"])
    check(
        "menu: finished and looked at, at a desk already: it can be pinned or sent to rest",
        menu(seen) == ["跳到会话 ✓", "\(mark) ✓", "\(desk) ✗", "\(rest) ✓", "—", "\(folder) ✓"])
    check(
        "menu: pinned, the pin is the way out of the news group: no desk; it can still be sent to rest",
        menu(pinned) == ["跳到会话 ✓", "取消待回复 ✓", "\(desk) ✗", "\(rest) ✓", "—", "\(folder) ✓"])
    check(
        "menu: resting at the back, it can be pinned or brought to a desk; it is resting already",
        menu(resting) == ["跳到会话 ✓", "\(mark) ✓", "\(desk) ✓", "\(rest) ✗", "—", "\(folder) ✓"])
    // Sent somewhere by hand: the menu follows where it now is, not its age.
    let sentToRest = kept(officeSession("m-sent-rest", "idle", finished: 600))
    let sentToDesk = kept(officeSession("m-sent-desk", "idle", finished: 7 * 3600))
    store.sessions += [sentToRest, sentToDesk]
    store.seen[sentToRest.id] = now.timeIntervalSince1970
    store.seen[sentToDesk.id] = now.timeIntervalSince1970
    store.parked = [sentToRest.id: Store.Parking(zone: .rest, at: now.timeIntervalSince1970),
                    sentToDesk.id: Store.Parking(zone: .desk, at: now.timeIntervalSince1970)]
    check(
        "menu: one sent to rest an hour after it finished is resting: to a desk yes, to rest no",
        menu(sentToRest) == ["跳到会话 ✓", "\(mark) ✓", "\(desk) ✓", "\(rest) ✗", "—", "\(folder) ✓"])
    check(
        "menu: one seven hours old sent to a desk is at a desk: to rest yes, to a desk no",
        menu(sentToDesk) == ["跳到会话 ✓", "\(mark) ✓", "\(desk) ✗", "\(rest) ✓", "—", "\(folder) ✓"])
    check(
        "menu: each line does what it says", sessionMenu(store, news).map(\.action) == [.jump, .pin, .desk, .rest, .separator, .openFolder])
    // The board's tooltip says so for every card, not only for one that has finished.
    check(
        "menu: on the board every card's tooltip says a right-click opens its menu, and names the moves",
        [waiting, busy, news, seen, pinned, resting].allSatisfy {
            let help = cardHelp($0, store)
            return help.hasPrefix("点一下跳到 Orca 里的这个会话") && help.hasSuffix("\n右键打开菜单：跳到会话、标记或取消待回复、转到工位或休息区、在访达里打开项目目录")
        })
    check(
        "menu: with no folder known, or one that is gone, it cannot be opened",
        menu(kept(news, in: "")).last == "\(folder) ✗"
            && menu(kept(news, in: NSTemporaryDirectory() + "no-such-folder-\(getpid())")).last == "\(folder) ✗")

    // Pinned at the back, it joins those with news on a sofa; unpinned, it goes back to the back row by its age.
    let back = Store()
    back.readOnly = true
    back.sessions = [officeSession("m-r0", "idle", finished: 9 * 3600), officeSession("m-s0", "idle", finished: 900)]
    for s in back.sessions { back.seen[s.id] = now.timeIntervalSince1970 }
    back.pinned = []
    func zone(_ id: String) -> OfficeLayout.Zone? { OfficePainter.layout(back, now: now).pets.first { $0.id == id }?.zone }
    let before = zone("m-r0")
    back.togglePin(back.sessions[0])
    let onSofa = Buckets(back, now: now).unread.map(\.id) == ["m-r0"] && zone("m-r0") == .sofa
    back.togglePin(back.sessions[0])
    check("menu: pinning one resting at the back puts it among those with news, on a sofa", before == .lounge && onSofa)
    check(
        "menu: ...and taking the pin off sends it back to the back row",
        zone("m-r0") == .lounge && Buckets(back, now: now).resting.map(\.id) == ["m-r0"])
}

/// The darkest red in a part of a picture: where text in ink is, it is dark.
func officeDarkest(_ pixels: Pixels, in r: CGRect) -> UInt8 {
    var least: UInt8 = 255
    for y in Int(r.minY * 2)..<Int(r.maxY * 2) {
        for x in Int(r.minX * 2)..<Int(r.maxX * 2) { least = min(least, pixels.data[(y * pixels.width + x) * 4]) }
    }
    return least
}

/// Whether a part of a picture has a pixel this colour, to within so much on each channel.
func officeHas(_ pixels: Pixels, _ colour: UInt32, within: Int, in r: CGRect) -> Bool {
    for y in Int(r.minY * 2)..<Int(r.maxY * 2) {
        for x in Int(r.minX * 2)..<Int(r.maxX * 2) {
            let i = (y * pixels.width + x) * 4
            let here = [Int(pixels.data[i]), Int(pixels.data[i + 1]), Int(pixels.data[i + 2])]
            let wanted = [Int(colour >> 16 & 255), Int(colour >> 8 & 255), Int(colour & 255)]
            if zip(here, wanted).allSatisfy({ abs($0 - $1) <= within }) { return true }
        }
    }
    return false
}

/// The office's own card for a pet: light on the room, no pet in it, a stripe for what it is doing, unfolding from the
/// pet; and the lists by the door and the waiting chip as targets, worked out without a window.
@MainActor func officeCardTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    // Which way a card unfolds: from its edge nearest the pet.
    let pet = CGRect(x: 400, y: 300, width: 80, height: 100)
    func way(_ x: CGFloat, _ y: CGFloat) -> (anchor: UnitPoint, across: Bool) {
        OfficeHover.unfold(card: CGRect(x: x, y: y, width: 320, height: 200), from: pet)
    }
    check(
        "office: a pet's card unfolds from its edge nearest the pet: across from its left or right edge, down from its top, up from its bottom",
        way(490, 250) == (.leading, true) && way(70, 250) == (.trailing, true) && way(280, 410) == (.top, false) && way(280, 90) == (.bottom, false))
    let window = CGSize(width: 1194, height: 866), size = CGSize(width: 320, height: 200)
    func placed(_ target: CGRect, _ card: CGSize, in window: CGSize) -> (anchor: UnitPoint, across: Bool) {
        OfficeHover.unfold(card: CGRect(origin: OfficeHover.origin(beside: target, card: card, window: window), size: card), from: target)
    }
    let big = CGSize(width: 445, height: 200), narrow = CGSize(width: 900, height: 800)
    check(
        "office: ...which is the side the card was placed on: right, left, below, above",
        placed(CGRect(x: 100, y: 400, width: 63, height: 84), size, in: window) == (.leading, true)
            && placed(CGRect(x: 1000, y: 400, width: 63, height: 84), size, in: window) == (.trailing, true)
            && placed(CGRect(x: 410, y: 400, width: 80, height: 100), big, in: narrow) == (.top, false)
            && placed(CGRect(x: 410, y: 600, width: 80, height: 100), big, in: narrow) == (.bottom, false))

    // The stripe, and the card as the still picture shows it beside one waiting, one at work and one with news.
    let store = officeStore()
    let byID = Dictionary(uniqueKeysWithValues: store.sessions.map { ($0.id, $0) })
    check(
        "office: the card's stripe is coral while it waits, green at work, a quiet stone otherwise",
        OfficeCard.stripe(byID["o-wait"]!) == OfficeLook.call && OfficeCard.stripe(byID["o-busy"]!) == OfficeLook.work
            && ["o-news", "o-seen", "o-rest"].allSatisfy { OfficeCard.stripe(byID[$0]!) == 0xB9B2A4 } && OfficeCard.stone == 0xB9B2A4
            && OfficeCard.fill == 0xF4F1EA && OfficeCard.edge == 0xD8D2C4)
    let picture = CGSize(width: 1194, height: 764), fit = OfficeFit(picture)
    let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
    for id in ["o-wait", "o-busy", "o-news"] {
        let s = byID[id]!
        let measured = NSHostingView(rootView: OfficeCard(s: s).environmentObject(store)).fittingSize
        guard let place = layout.pets.first(where: { $0.id == id }), measured.height > 0 else {
            check("office: pointed at \(id), its card can be measured", false)
            continue
        }
        store.hovered = id
        let shown = officeStill(store, size: picture)
        store.hovered = nil
        if review { save(shown, "/tmp/office-card-card-\(id).png") }
        let card = CGRect(origin: OfficeHover.origin(beside: fit.rect(place.frame), card: measured, window: picture), size: measured)
        let words = CGRect(x: card.minX + 16, y: card.minY + 12, width: card.width - 28, height: card.height - 24)
        let light = shown.map { image in
            let p = Pixels(image)
            return same(p.at(card.minX + 8, card.minY + 5), OfficeCard.fill) && same(p.at(card.minX + 2, card.midY), OfficeCard.stripe(s))
                && same(p.at(card.maxX - 5, card.maxY - 5), OfficeCard.fill)
                && officeHas(p, 0x1E1A33, within: 2, in: CGRect(x: card.minX + 16, y: card.minY + 12, width: 60, height: 14))
        } ?? false
        check(
            "office: pointed at one \(s.status == "idle" ? "with news" : s.status), a light card 320 wide beside it: fill, ink #1E1A33, stripe",
            measured.width == 320 && light)
        if s.status == "waiting" {
            // Coral words on the light card are the room's deeper pin coral; coral itself is kept for the stripe.
            check(
                "office: on a waiting one's card its wait and its ask are in the deeper coral #D8432B, no word in the stripe's coral",
                shown.map { image in
                    let p = Pixels(image)
                    return officeHas(p, OfficeLook.pin, within: 6, in: words) && !officeHas(p, OfficeLook.call, within: 24, in: words)
                } ?? false)
        }
    }

    // The door, its list's card and the strip of gap between them are one target; a row is its own; elsewhere, the corners
    // of their bounding box included, the room answers.
    let door = CGRect(x: 1000, y: 40, width: 84, height: 66), beside = CGRect(x: 754, y: 34, width: 236, height: 180)
    let strip = OfficeHover.gap(between: door, beside)
    let target = CGRect(x: 100, y: 100, width: 50, height: 80)
    func between(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        OfficeHover.gap(between: target, CGRect(x: x, y: y, width: w, height: h))
    }
    check(
        "office: between a list's card and what it is beside, a strip the width of the gap, as long as their facing edges overlap",
        strip == CGRect(x: 990, y: 40, width: 10, height: 66) && between(160, 60, 200, 100) == CGRect(x: 150, y: 100, width: 10, height: 60)
            && between(20, 190, 300, 100) == CGRect(x: 100, y: 180, width: 50, height: 10)
            && between(120, 0, 300, 90) == CGRect(x: 120, y: 90, width: 30, height: 10))
    check(
        "office: ...as long as both where the facing edges do not overlap, and none where the card covers it",
        OfficeHover.gap(between: CGRect(x: 0, y: 0, width: 50, height: 20), CGRect(x: 60, y: 40, width: 100, height: 60))
            == CGRect(x: 50, y: 0, width: 10, height: 100)
            && between(80, 120, 300, 100) == .zero)
    let doorKey = OfficeLayout.doorKey, rowA = OfficeList.row(doorKey, "aaaa"), rowB = OfficeList.row(doorKey, "bbbb")
    let frames: [String: CGRect] = [
        doorKey: door, OfficeList.card(doorKey): beside, OfficeList.gap(doorKey): strip,
        rowA: CGRect(x: 762, y: 60, width: 220, height: 20), rowB: CGRect(x: 762, y: 80, width: 220, height: 20),
        "pet": CGRect(x: 800, y: 120, width: 60, height: 60),
    ]
    func on(_ x: CGFloat, _ y: CGFloat, _ hovered: String?) -> String? {
        OfficeList.pointed(at: CGPoint(x: x, y: y), frames: frames, hovered: hovered)
    }
    check(
        "office: with the door's list up, a row points at that row; the gap and the card's ground (over a pet too) at the door; past them, nothing",
        on(800, 70, doorKey) == rowA && on(800, 90, rowA) == rowB && on(995, 73, rowB) == doorKey && on(830, 150, rowA) == doorKey
            && on(1040, 80, rowA) == doorKey && on(1100, 300, doorKey) == nil)
    check(
        "office: ...and the corner of their bounding box under the door, beside the card, is the room's again",
        on(995, 73, doorKey) == doorKey && on(1040, 150, doorKey) == nil && on(995, 150, rowA) == nil && door.union(beside).contains(CGPoint(x: 1040, y: 150)))
    check(
        "office: ...with the pointer elsewhere, the same row counts for nothing",
        on(800, 70, doorKey) == rowA && on(800, 70, "pet") == nil && on(800, 70, nil) == nil)
    check(
        "office: a row's entry tells its list and its session; the list's own does neither",
        OfficeList.session(rowA) == "aaaa" && OfficeList.open(rowA) == doorKey && OfficeList.open(doorKey) == doorKey
            && OfficeList.open(OfficeLayout.ChipKind.waiting.key) == OfficeLayout.ChipKind.waiting.key && OfficeList.session(doorKey) == nil
            && OfficeList.open("pet") == nil && OfficeList.open(nil) == nil && OfficeList.session(OfficeList.card(doorKey)) == nil
            && OfficeList.entry(OfficeList.card(doorKey))?.list == doorKey && OfficeList.entry("pet") == nil && OfficeList.entry(doorKey) == nil
            && OfficeList.entry(OfficeList.gap(doorKey)).map { $0.list == doorKey && $0.id == nil } ?? false
            && OfficeList.session(OfficeList.gap(doorKey)) == nil)
    check("office: the door's card lists twelve before it says ……", OfficeDoorCard.shows == 12)
}

/// The little people on the desks are the sessions' real subagents, read from the folder beside each transcript:
/// only the end of an agent's transcript, and only when it changed.
@MainActor func officeSubagentTests() {
    typealias Agent = OfficeSubagents.Agent
    let files = FileManager.default
    let scratch = NSTemporaryDirectory() + "office-agents-\(getpid())"
    try? files.removeItem(atPath: scratch)
    defer { try? files.removeItem(atPath: scratch) }
    let now = Date()
    // A session's transcript, and its subagents' folder beside it; the transcript itself need not be there.
    func transcript(_ sid: String) -> String { "\(scratch)/proj/\(sid).jsonl" }
    func folder(_ sid: String) -> String {
        let path = "\(scratch)/proj/\(sid)/subagents"
        try? files.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
    // Lines as an agent's transcript has them: its reply names its model right after "message"; an advisor's usage names
    // another model, which is not the agent's; the hook's stop line is some 3.7 KB, most of it the hook's command.
    let reply = #"{"parentUuid":"p","isSidechain":true,"agentId":"a","message":{"model":"claude-opus-5-5","id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"好"}]},"type":"assistant","advisorModel":"claude-fable-5-1"}"#
    let result = #"{"parentUuid":"p","isSidechain":true,"agentId":"a","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"type":"user","toolUseResult":{"stdout":"ok"}}"#
    let advised = #"{"parentUuid":"p","isSidechain":true,"agentId":"a","attachment":{"usage":[{"type":"advisor_message","model":"claude-fable-5-1"}]},"type":"attachment"}"#
    let stop = #"{"parentUuid":"p","isSidechain":true,"agentId":"a","attachment":{"type":"hook_success","hookName":"SubagentStop","toolUseID":"t","hookEvent":"SubagentStop","content":"","stdout":"{}\n","stderr":"","exitCode":0,"command":""#
        + String(repeating: "x", count: 3400) + #""},"type":"attachment"}"#
    func agent(_ dir: String, _ id: String, _ lines: [String], meta: String? = nil, quiet: TimeInterval = 5, started: TimeInterval = 600) {
        let path = "\(dir)/agent-\(id).jsonl"
        files.createFile(atPath: path, contents: Data(lines.map { $0 + "\n" }.joined().utf8))
        try? files.setAttributes([.creationDate: now - started, .modificationDate: now - quiet], ofItemAtPath: path)
        if let meta { files.createFile(atPath: "\(dir)/agent-\(id).meta.json", contents: Data(meta.utf8)) }
    }
    func append(_ dir: String, _ id: String, _ line: String) {
        guard let handle = FileHandle(forWritingAtPath: "\(dir)/agent-\(id).jsonl") else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }
    func meta(_ description: String, _ model: String?) -> String {
        #"{"agentType":"general-purpose","description":"\#(description)","toolUseId":"toolu_1","spawnDepth":1"# + (model.map { #","model":"\#($0)""# } ?? "")
            + "}"
    }

    // One running, one finished, one quiet for 31 minutes without a stop: one runs.
    let one = folder("s1")
    agent(one, "arun", [result, reply, result], meta: meta("跑测试", "opus"))
    agent(one, "adone", [reply, result, stop], meta: meta("查日志", "sonnet"))
    agent(one, "astale", [reply, result], meta: meta("改样式", "haiku"), quiet: 31 * 60)
    let scan = OfficeSubagents()
    let first = scan.running(in: one, now: now)
    check("office: of one subagent running, one finished (its last line the SubagentStop hook's) and one quiet for 31 minutes, one runs", first.count == 1)
    check(
        "office: ...what it was asked comes from its meta file, its model from its own reply: not the alias asked for, not the advisor's",
        first == [Agent(description: "跑测试", model: "claude-opus-5-5", agentType: "general-purpose")])
    let readOnce = scan.read
    let again = scan.running(in: one, now: now)
    check("office: a second look with nothing changed reads no transcript again, and finds the same", readOnce > 0 && scan.read == readOnce && again == first)
    // Resumed, the finished one writes on: running again, read again from its end only; stopped again, finished.
    append(one, "adone", result)
    let resumed = scan.running(in: one, now: now)
    let reread = scan.read - readOnce
    append(one, "adone", stop)
    let stopped = scan.running(in: one, now: now)
    check(
        "office: one resumed after its stop runs again, read again from its end only, until its next stop",
        resumed.count == 2 && reread > 0 && reread <= OfficeSubagents.window && stopped == first)

    // Until a reply of its own is read, the model the Agent call asked for; on the session's own model, none.
    let two = folder("s2")
    agent(two, "a1", [result, advised], meta: meta("审代码", "sonnet"), started: 300)
    agent(two, "a2", [advised], meta: meta("写说明", "inherit"), started: 900)
    agent(two, "a3", [result], meta: meta("找文件", nil), started: 60)
    agent(two, "a4", [result])  // its meta file not written yet
    check(
        "office: ...until a reply names it, the model the Agent call asked; 'inherit' or none says nothing; the longest-running first",
        OfficeSubagents().running(in: two, now: now) == [
            Agent(description: "写说明", model: "", agentType: "general-purpose"), Agent(description: "", model: ""), Agent(description: "审代码", model: "sonnet", agentType: "general-purpose"),
            Agent(description: "找文件", model: "", agentType: "general-purpose"),
        ])

    // Of a 1 MB transcript only its end is read, whether its last line is the stop or a single line of 1 MB.
    let big = folder("s3")
    agent(big, "abig", Array(repeating: result, count: 1_000_000 / (result.utf8.count + 1)) + [stop])
    let sizer = OfficeSubagents()
    let bigRunning = sizer.running(in: big, now: now)
    let bigRead = sizer.read
    agent(big, "ahuge", [#"{"type":"user","toolUseResult":""# + String(repeating: "y", count: 1_000_000) + #""}"#])
    let hugeRunning = sizer.running(in: big, now: now)
    let hugeRead = sizer.read - bigRead
    func size(_ id: String) -> Int { ((try? files.attributesOfItem(atPath: "\(big)/agent-\(id).jsonl"))?[.size] as? NSNumber)?.intValue ?? 0 }
    check(
        "office: of a 1 MB transcript ending in the stop line, under 8 KB is read, and it is finished",
        size("abig") > 1_000_000 && bigRead > 3_000 && bigRead < 8 * 1024 && bigRunning.isEmpty)
    check(
        "office: ...of one whose last line alone is 1 MB, under 8 KB too: a line that long is the agent's own, running",
        size("ahuge") > 1_000_000 && hugeRead > 0 && hugeRead < 8 * 1024 && hugeRunning.count == 1)
    let old = folder("s4")
    agent(old, "aold", [reply, result], quiet: 31 * 60)
    agent(old, "aolder", [reply, stop], quiet: 3 * 3600)
    agent(old, "afresh", [reply, result])
    let looker = OfficeSubagents()
    let fresh = looker.running(in: old, now: now)
    check(
        "office: a transcript quiet for half an hour is not read at all, whatever its end: of three, only the fresh one's bytes are read",
        fresh.count == 1 && looker.read == reply.utf8.count + result.utf8.count + 2)

    // The short model names, as the status line shows them.
    let names = [
        "claude-opus-5-5": "Opus 5.5", "claude-haiku-4-5-20251001": "Haiku 4.5", "claude-sonnet-5": "Sonnet 5", "claude-opus-5-5[1m]": "Opus 5.5",
        "claude-fable-5-1": "Fable 5.1", "opus": "Opus", "inherit": "", "": "",
    ]
    check(
        "office: a model goes by its short name: claude-opus-5-5 is Opus 5.5, claude-haiku-4-5-20251001 Haiku 4.5, the alias opus Opus",
        names.allSatisfy { OfficeSubagents.name(of: $0.key) == $0.value })

    // On the card: a line each, three at most, then how many more.
    let five = [
        Agent(description: "跑测试", model: "claude-opus-5-5"), Agent(description: "查日志", model: "claude-haiku-4-5-20251001"),
        Agent(description: "写说明", model: ""), Agent(description: "改样式", model: "sonnet"), Agent(description: "", model: ""),
    ]
    check(
        "office: the card gives each running subagent a line, subagent · what it was asked · its model, three at most, then how many more",
        OfficeCard.agentLines(five) == ["子代理 · 跑测试 · Opus 5.5", "子代理 · 查日志 · Haiku 4.5", "子代理 · 写说明", "还有 2 个"]
            && OfficeCard.agentLines(Array(five.prefix(3))).count == 3 && OfficeCard.agentLines([five[4]]) == ["子代理"]
            && OfficeCard.agentLines([]).isEmpty)
    let carded = officeStateStore(0, 0, 4, 2, 0)
    if let s = carded.sessions.first(where: { $0.id == "b0" }) {
        func tall() -> CGFloat { NSHostingView(rootView: OfficeCard(s: s).environmentObject(carded)).fittingSize.height }
        let bare = tall()
        carded.agents = ["b0": five]
        let lined = tall()
        check("office: ...and shows them: the card of one with five running grows by four short lines", lined > bare + 40 && lined < bare + 90)
    } else {
        check("office: ...and shows them: the card of one with five running grows by four short lines", false)
    }

    // A tick hands the store the open sessions' transcripts: only theirs are looked at, and the notice board hears nothing.
    let open = officeStateStore(0, 0, 4, 2, 0)
    let desks = OfficePainter.layout(open, now: now)
    let board = open.activity
    var published = 0
    let watch = open.objectWillChange.sink { _ in published += 1 }
    open.readAgents([("b0", transcript("s1")), ("b1", transcript("nobody"))], at: now)
    let told = published
    open.readAgents([("b0", transcript("s1")), ("b1", transcript("nobody"))], at: now)
    watch.cancel()
    check(
        "office: the store counts the open sessions' running subagents, theirs only, none running no entry; the notice board hears nothing",
        open.agentCounts == ["b0": 1] && open.agents == ["b0": [Agent(description: "跑测试", model: "claude-opus-5-5", agentType: "general-purpose")]] && open.activity == board
            && told > 0)
    check("office: ...read again with nothing changed, it tells nobody", told > 0 && published == told)
    check("office: ...and the one at its own desk has its little person there", OfficePainter.helpers(open, desks).map(\.count) == [1])

    // Thirty open sessions with a dozen subagents each, two of them running, all written within the half hour.
    let many = (0..<30).map { i -> (String, String) in
        let dir = folder("m\(i)")
        for j in 0..<12 { agent(dir, "a\(j)", j < 2 ? [reply, result] : [reply, stop], meta: meta("第\(j)个", "opus"), quiet: 60) }
        return ("m\(i)", transcript("m\(i)"))
    }
    let timer = OfficeSubagents()
    var started = Date()
    let found = timer.running(many, now: now)
    let cold = Date().timeIntervalSince(started)
    var warm: [TimeInterval] = []
    for _ in 0..<5 {
        started = Date()
        _ = timer.running(many, now: now)
        warm.append(Date().timeIntervalSince(started))
    }
    print(String(format: "      thirty sessions, 360 subagents: the first look took %.1f ms, the next five %@ ms", cold * 1000,
                 warm.map { String(format: "%.2f", $0 * 1000) }.joined(separator: ", ")))
    // The middle of five: one look held up by a machine short of memory (9 ms once) says nothing about the scan.
    check(
        "office: thirty sessions with twelve subagents each, nothing changed: the whole look takes under 10 ms (the middle of five)",
        found.count == 30 && found.values.allSatisfy { $0.count == 2 } && warm.sorted()[warm.count / 2] < 0.010)
    // And the sessions open now, for the record.
    let loader = Loader()
    let opened = loader.load()
    let paths = opened.compactMap { s in loader.transcript(of: s.id).map { (s.id, $0) } }
    let real = OfficeSubagents()
    started = Date()
    let live = real.running(paths, now: Date())
    let liveCold = Date().timeIntervalSince(started)
    started = Date()
    _ = real.running(paths, now: Date())
    let liveWarm = Date().timeIntervalSince(started)
    print(String(format: "      now: %d open sessions, %d subagents running; the first look took %.1f ms (%d bytes read), the next %.2f ms", paths.count,
                 live.values.map(\.count).reduce(0, +), liveCold * 1000, real.read, liveWarm * 1000))
}

/// The door's and the waiting chip's lists in a real hosting view: the pointer stays on them across the gap, each row is
/// its own target for both clicks, SwiftUI and not the room takes a click on a row, and a click on the card's own ground
/// is the door's.
@MainActor func officeListTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    let store = Store()
    store.readOnly = true
    store.tracker.store = store
    // Nine waiting (two beyond the queue, seated in the room), four looked at, thirty-one resting: fourteen behind the door.
    store.sessions = officeSessions([("w", "waiting", 9, 300), ("s", "idle", 4, 900), ("r", "idle", 31, 9 * 3600.0)])
    for s in store.sessions where s.status == "idle" { store.seen[s.id] = Date().timeIntervalSince1970 }
    UserDefaults.standard.set(true, forKey: "office")
    defer { UserDefaults.standard.set(false, forKey: "office") }
    let window = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 1194, height: 834), styleMask: .borderless, backing: .buffered, defer: false)
    let host = FirstClickHostingView(rootView: Root(store: store))
    var menuAt: CGPoint?
    host.onPointer = { [weak store] in store?.tracker.pointer(at: $0) }
    host.onMenu = { point in
        menuAt = point
        return nil
    }
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
    func middle(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: r.midY) }
    func office(in view: NSView) -> OfficeView? { view as? OfficeView ?? view.subviews.lazy.compactMap(office(in:)).first }
    settle()
    let fit = OfficeFit(CGSize(width: 1194, height: 834))
    let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
    let door = fit.rect(OfficeLayout.door), doorKey = OfficeLayout.doorKey
    store.tracker.pointer(at: middle(door))
    settle()
    let rows = layout.behindDoorIDs.prefix(12).map { OfficeList.row(doorKey, $0) }
    let reach = store.tracker.frames[OfficeList.card(doorKey)] ?? .zero, strip = store.tracker.frames[OfficeList.gap(doorKey)] ?? .zero
    check(
        "lists: pointed at, the door's card tells the pointer where it is, the strip to the door, and where each of its twelve rows is",
        store.hovered == doorKey && layout.behindDoor == 14 && reach.width > 100 && !reach.intersects(door)
            && strip.width > 0 && strip.height > 0 && rows.allSatisfy { store.tracker.frames[$0].map { reach.contains($0) } ?? false })
    // Beside the door, 10 points off it: the two together no wider than the door, the gap and the widest card (220 and
    // the 8-point backing each side); the strip touches both.
    let together = door.union(reach)
    check(
        "lists: the door's card comes up beside the door, as before, the strip between them touching both",
        together.width <= door.width + 10 + 236 + 1 && together.minX >= door.minX - 10 - 236 - 1
            && strip.insetBy(dx: -0.5, dy: -0.5).intersects(door) && strip.insetBy(dx: -0.5, dy: -0.5).intersects(reach))
    // Fourteen behind the door: twelve rows, the thirteenth not among the pointer's targets, and "……" drawn under the last.
    func drawn(_ r: CGRect) -> Pixels? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        host.cacheDisplay(in: r, to: rep)
        return rep.cgImage.map(Pixels.init)
    }
    let last = store.tracker.frames[rows[11]] ?? .zero
    let dots = drawn(CGRect(x: last.minX + 6, y: last.maxY + 1, width: 30, height: 14))
        .map { $0.brightest(in: CGRect(x: 0, y: 0, width: 30, height: 14)) }
    check(
        "lists: with fourteen behind the door the card lists twelve, not the thirteenth, and says …… under them",
        store.tracker.frames[OfficeList.row(doorKey, layout.behindDoorIDs[12])] == nil && last != .zero && (dots ?? 0) > 0x70)

    // Across the gap to the card, and on a row over a pet sitting at the back.
    let first = store.tracker.frames[rows[0]] ?? .zero
    let gap = middle(strip)
    store.tracker.pointer(at: gap)
    let acrossGap = store.hovered
    let under = layout.pets.filter { reach.contains(middle(fit.rect($0.body))) }
    // Neither the door, its card nor the strip between them counts, over a pet, as the door's whole bounding box.
    let room = office(in: host)
    var corner: (point: CGPoint, id: String)?
    for pet in layout.pets where corner == nil {
        let body = fit.rect(pet.body)
        for y in stride(from: body.minY + 2, to: body.maxY - 2, by: 3) {
            for x in stride(from: body.minX + 2, to: body.maxX - 2, by: 3) {
                let p = CGPoint(x: x, y: y)
                if corner == nil, together.contains(p), !door.contains(p), !reach.contains(p), !strip.contains(p),
                    let id = layout.session(at: fit.point(p))
                {
                    corner = (p, id)
                }
            }
        }
    }
    store.tracker.pointer(at: middle(first))
    settle()
    check(
        "lists: across the gap the door stays pointed at; on a row, that row, and the card stays up",
        acrossGap == doorKey && store.hovered == rows[0] && store.tracker.frames[OfficeList.card(doorKey)] != nil)
    check(
        "lists: a pet sitting under the card is not what the pointer finds there",
        !under.isEmpty && under.allSatisfy { store.tracker.card(at: middle(fit.rect($0.body))) != $0.id })

    // The click on a row is SwiftUI's, which takes the first click too; a right-click there asks for that session's menu.
    let onRow = host.hitTest(host.convert(middle(first), to: host.superview))
    let onFloor = host.hitTest(host.convert(CGPoint(x: 600, y: 760), to: host.superview))
    check(
        "lists: a click on a row goes to the card, not the room under it, and the panel takes it as a first click",
        room != nil && onFloor === room && onRow != nil && !(onRow is OfficeView) && onRow?.acceptsFirstMouse(for: nil) == true)
    if let click = NSEvent.mouseEvent(
        with: .rightMouseDown, location: host.convert(middle(first), to: nil), modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    {
        window.sendEvent(click)
    }
    check(
        "lists: a right-click on a row asks for that row's session's menu",
        menuAt.flatMap(store.tracker.card(at:)).flatMap(OfficeList.session) == layout.behindDoorIDs.first)
    if review {
        store.hovered = rows[1]
        save(officeStill(store, size: CGSize(width: 1194, height: 834)), "/tmp/office-card-door-row.png")
        store.hovered = rows[0]
    }

    // A pet at the back under the door, in the old dead corner, is clicked and pointed at while the door's list is up.
    let cornerClick = corner.flatMap { c in room.flatMap { $0.target(at: $0.convert(c.point, from: host)) } }
    if let corner { store.tracker.pointer(at: corner.point) }
    settle()
    check(
        "lists: with the door's list up, a pet sitting under the door, beside the card, is clicked and pointed at again",
        corner != nil && cornerClick == corner.map { OfficeView.Target.pet($0.id) } && store.hovered == corner?.id)
    store.tracker.pointer(at: middle(door))
    settle()

    // The waiting chip's list: its rows are sessions also seated in the room. On one, the list stays, not that pet's card.
    let chipKey = OfficeLayout.ChipKind.waiting.key
    store.tracker.pointer(at: nil)
    settle()
    let chip = layout.chips.first { $0.kind == .waiting }
    store.tracker.pointer(at: chip.map { middle(fit.rect($0.rect)) } ?? .zero)
    settle()
    let chipRow = OfficeList.row(chipKey, layout.waitingElsewhere.first ?? "")
    if let row = store.tracker.frames[chipRow] { store.tracker.pointer(at: middle(row)) }
    settle()
    check(
        "lists: on a row of the waiting chip's card that row is pointed at, though its session sits in the room, and the card stays",
        layout.waitingElsewhere.count == 2 && layout.pets.contains { $0.id == layout.waitingElsewhere[0] } && store.hovered == chipRow
            && store.tracker.frames[OfficeList.card(chipKey)] != nil)
    let chipCard = store.tracker.frames[OfficeList.card(chipKey)] ?? .zero, chipRect = chip.map { fit.rect($0.rect) } ?? .zero
    let chipStrip = store.tracker.frames[OfficeList.gap(chipKey)] ?? .zero, chipReach = chipRect.union(chipCard)
    check(
        "lists: the chip's card comes up beside the chip, as before, the strip between them touching both",
        chipCard.width > 0 && chipReach.width <= chipRect.width + 10 + 276 + 1 && chipReach.height <= chipRect.height + 10 + 400
            && chipStrip.insetBy(dx: -0.5, dy: -0.5).intersects(chipRect) && chipStrip.insetBy(dx: -0.5, dy: -0.5).intersects(chipCard))
    if review { save(officeStill(store, size: CGSize(width: 1194, height: 834)), "/tmp/office-card-chip-row.png") }

    // Off it all: nothing pointed at, and the lists' entries gone.
    let listed = store.tracker.frames.keys.contains { OfficeList.entry($0) != nil }
    store.tracker.pointer(at: nil)
    settle()
    check(
        "lists: off the card and its chip nothing is pointed at, and the list's entries, there a moment ago, are gone",
        listed && store.hovered == nil && !store.tracker.frames.keys.contains { OfficeList.entry($0) != nil })

    // The card layer is always there now, over the whole room: with nothing pointed at, and with a pet's card up (on the pet
    // and on its card), a click still goes to the room.
    let seated = layout.pets.first { $0.zone == .desk }.map { fit.rect($0.frame) } ?? .zero
    func roomTakes(_ p: CGPoint) -> Bool { host.hitTest(host.convert(p, to: host.superview)) === room }
    let idleRoom = roomTakes(middle(seated))
    store.tracker.pointer(at: middle(seated))
    settle()
    check(
        "lists: with nothing pointed at, or a pet's card up, a click on the pet or on its card is still the room's",
        seated != .zero && store.hovered != nil && idleRoom && roomTakes(middle(seated))
            && roomTakes(CGPoint(x: seated.maxX + 40, y: seated.midY)))
    store.tracker.pointer(at: nil)
    settle()

    // A click on the card's own ground, its title line, is the door's: the board. Never on a row: that would jump to Orca.
    store.tracker.pointer(at: middle(door))
    settle()
    let top = store.tracker.frames[rows[0]] ?? .zero
    let title = CGPoint(x: top.minX + 30, y: top.minY - 8)
    let clear = top != .zero && !rows.contains { store.tracker.frames[$0]?.contains(title) ?? true }
        && (store.tracker.frames[OfficeList.card(doorKey)]?.contains(title) ?? false)
    if clear {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let click = NSEvent.mouseEvent(
                with: type, location: host.convert(title, to: nil), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            {
                window.sendEvent(click)
            }
        }
        settle()
    }
    check(
        "lists: a click on the card's title line shows the board, as a click on the door does", clear && !UserDefaults.standard.bool(forKey: "office"))

    // A row's button and the card's own ground both take clicks, the ground's tap round the rows. Built as the list is
    // (a button in that style inside a ground that taps) and clicked for real, since a real row would jump to Orca: on the
    // button only the button counts, so a row never shows the board; on the ground only the ground.
    var rowTaps = 0, groundTaps = 0, rowFrame = CGRect.zero
    let probe = FirstClickHostingView(
        rootView: VStack(alignment: .leading, spacing: 0) {
            Text("休息室里还有 1 个").padding(10)
            Button {
                rowTaps += 1
            } label: {
                Text("一行").padding(6).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrame = $0 }
        }
        .padding(8).frame(width: 220, height: 140, alignment: .topLeading).background(night)
        .contentShape(Rectangle()).onTapGesture { groundTaps += 1 })
    let probeWindow = NSWindow(
        contentRect: NSRect(x: -4000, y: -4000, width: 220, height: 140), styleMask: .borderless, backing: .buffered, defer: false)
    probeWindow.contentView = probe
    probeWindow.orderFrontRegardless()
    defer { probeWindow.orderOut(nil) }
    settle()
    func click(_ p: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: type, location: probe.convert(p, to: nil), modifierFlags: [], timestamp: 0, windowNumber: probeWindow.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
            {
                probeWindow.sendEvent(event)
            }
        }
        settle()
    }
    click(middle(rowFrame))
    let tapsOnRow = (rowTaps, groundTaps)
    click(CGPoint(x: 110, y: 128))
    check(
        "lists: a click on a row's button is the row's alone, never the card's (which would show the board); on the ground, the ground's",
        rowFrame != .zero && !rowFrame.contains(CGPoint(x: 110, y: 128)) && tapsOnRow == (1, 0) && (rowTaps, groundTaps) == (1, 1))
}

/// A pet's card in the panel itself, where SwiftUI moves it: it unfolds from its edge by the pet and folds back into it;
/// moving straight to another pet, it folds where it was while the other's unfolds by its own pet. Watched along a line
/// through the card's top margin, right of the pet, against the floor as it was without it.
@MainActor func officeUnfoldTests() {
    let store = officeStore()
    store.tracker.store = store
    UserDefaults.standard.set(true, forKey: "office")
    defer { UserDefaults.standard.set(false, forKey: "office") }
    let size = CGSize(width: 1194, height: 764)
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    let host = FirstClickHostingView(rootView: Root(store: store))
    window.contentView = host
    window.orderFrontRegardless()
    defer { window.orderOut(nil) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let fit = OfficeFit(size), layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
    func frame(_ id: String) -> CGRect { fit.rect(layout.pets.first { $0.id == id }?.frame ?? .zero) }
    let busy = frame("o-busy"), news = frame("o-news")
    func line(_ pet: CGRect) -> CGRect { CGRect(x: pet.maxX, y: pet.midY - 15, width: size.width - pet.maxX, height: 2) }
    func capture(_ r: CGRect) -> Pixels? {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: r) else { return nil }
        host.cacheDisplay(in: r, to: rep)
        return rep.cgImage.map(Pixels.init)
    }
    let floors = Dictionary(uniqueKeysWithValues: [busy, news].map { ($0.minX, capture(line($0))) })
    /// How far right of the pet the card's left and right edges are now; nil with no card there.
    func edges(_ pet: CGRect) -> (left: CGFloat, right: CGFloat)? {
        guard let now = capture(line(pet)), let floor = floors[pet.minX] ?? nil else { return nil }
        var left: CGFloat?, right: CGFloat = 0, x: CGFloat = 0
        while x < line(pet).width - 1 {
            if abs(Int(now.at(x, 0.5) >> 16) - Int(floor.at(x, 0.5) >> 16)) > 24 {
                left = left ?? x
                right = x
            }
            x += 1
        }
        return left.map { ($0, right) }
    }
    func watch(_ pet: CGRect, for seconds: Double) -> [(at: Int, edges: (left: CGFloat, right: CGFloat)?)] {
        let start = Date()
        var seen: [(at: Int, edges: (left: CGFloat, right: CGFloat)?)] = []
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.current.run(until: Date().addingTimeInterval(0.005))
            seen.append((Int(Date().timeIntervalSince(start) * 1000), edges(pet)))
        }
        return seen
    }
    func told(_ seen: [(at: Int, edges: (left: CGFloat, right: CGFloat)?)]) -> String {
        seen.map { "\($0.at)ms:\($0.edges.map { "\(Int($0.right - $0.left))" } ?? "-")" }.joined(separator: " ")
    }
    typealias Seen = [(at: Int, edges: (left: CGFloat, right: CGFloat)?)]
    /// Some sample caught it part of the way: strictly between folded away (nothing there) and open (as wide as it ends
    /// up), its edge by the pet where it ends up.
    func midway(_ seen: Seen, left: CGFloat, full: CGFloat) -> Bool {
        seen.contains { $0.edges.map { abs($0.left - left) <= 2 && $0.right - $0.left > 0 && $0.right - $0.left < full - 4 } ?? false }
    }
    func opened(_ e: (left: CGFloat, right: CGFloat)?) -> Bool { e.map { abs($0.left - 10) <= 2 && $0.right - $0.left > 310 } ?? false }
    /// Pointed at the pet for 0.4 s, then away for 0.3 s.
    func look() -> (opening: Seen, closing: Seen) {
        store.tracker.pointer(at: CGPoint(x: busy.midX, y: busy.midY))
        let opening = watch(busy, for: 0.4)
        store.tracker.pointer(at: nil)
        return (opening, watch(busy, for: 0.3))
    }
    // Where it ends must hold on every look. The middle, and that folding is the quicker way, have to be caught on one of
    // up to three: a main thread stalled for a moment (the machine short of memory) can skip a transition to its end, and
    // that alone must not fail the suite.
    func middle(_ l: (opening: Seen, closing: Seen)) -> (out: Bool, back: Bool) {
        let open = l.opening.last?.edges, full = open.map { $0.right - $0.left } ?? 0
        let quick = (l.closing.first { $0.edges == nil }?.at ?? 1000) < (l.opening.first { opened($0.edges) }?.at ?? 0) + 40
        return (midway(l.opening, left: open?.left ?? 0, full: full), midway(l.closing, left: open?.left ?? 0, full: full) && quick)
    }
    var looks = [look()]
    while looks.count < 3, !(middle(looks.last!).out && middle(looks.last!).back) { looks.append(look()) }
    print("      unfolding: " + told(looks.last!.opening))
    print("      folding: " + told(looks.last!.closing) + " (looks: \(looks.count))")
    check(
        "office: in the panel, a pet's card unfolds from its edge by the pet: caught part of the way out, that edge still, then 320 wide",
        looks.allSatisfy { opened($0.opening.last?.edges) } && looks.contains { middle($0).out })
    check(
        "office: ...and folds back into it, the quicker way, and is gone",
        looks.allSatisfy { $0.closing.last.map { $0.edges == nil } ?? false } && looks.contains { middle($0).back })

    // Straight from one pet to another far off: the first card folds where it is, the other's unfolds by its own pet.
    func move() -> (leaving: Seen, arrived: (left: CGFloat, right: CGFloat)?) {
        store.tracker.pointer(at: CGPoint(x: busy.midX, y: busy.midY))
        _ = watch(busy, for: 0.3)
        store.tracker.pointer(at: CGPoint(x: news.midX, y: news.midY))
        let leaving = watch(busy, for: 0.3), arrived = edges(news)
        store.tracker.pointer(at: nil)
        _ = watch(news, for: 0.3)
        return (leaving, arrived)
    }
    let width = looks[0].opening.last?.edges.map { $0.right - $0.left } ?? 0
    var moves = [move()]
    while moves.count < 3, !midway(moves.last!.leaving, left: 10, full: width) { moves.append(move()) }
    check(
        "office: moving straight to another pet, the first card folds where it was and the other's comes up by its own pet",
        moves.allSatisfy { $0.leaving.last.map { $0.edges == nil } ?? false && opened($0.arrived) }
            && moves.contains { midway($0.leaving, left: 10, full: width) })
}

// ───────── Before hand-over ─────────

/// Small items: answered lines on the board's card, the hover card's width, word wrapping in the
/// waiting card, the contrast of names and project lines.
@MainActor func officeFinalTests() {
    let now = Date()

    // A "waiting for you" line whose session no longer waits has the quiet dot; the store's waiting sessions decide.
    let board = Store()
    board.readOnly = true
    board.sessions = [officeSession("w0", "waiting", finished: 30, name: "还在等"), officeSession("b0", "busy", finished: 20, name: "答过了")]
    board.log([
        OfficeActivity.Event(at: now - 300, id: "b0", name: "答过了", kind: .approve),
        OfficeActivity.Event(at: now - 200, id: "w0", name: "还在等", kind: .answer),
        OfficeActivity.Event(at: now - 100, id: "gone", name: "关掉了", kind: .waiting),
        OfficeActivity.Event(at: now - 50, id: "b0", name: "答过了", kind: .finished),
    ])
    let dots = OfficeBoardCard.lines(board).map(\.dot)
    check(
        "office: on the board's card a waiting line whose session no longer waits has the quiet dot; one still waiting stays coral",
        dots == [OfficeLook.paper, 0x9A96B8, OfficeLook.call, 0x9A96B8])

    // The hover card is 320 wide, a card of the office's own, and still opens inside
    // the window and off its pet.
    let crowd = Store()
    crowd.readOnly = true
    crowd.sessions = officeSessions([
        ("w", "waiting", 3, 120), ("n", "idle", 6, 30), ("b", "busy", 8, 60), ("s", "idle", 8, 900), ("r", "idle", 20, 9 * 3600.0),
    ])
    for s in crowd.sessions where s.id.hasPrefix("s") || s.id.hasPrefix("r") { crowd.seen[s.id] = now.timeIntervalSince1970 }
    var placed = 0, inside = true
    for size in [CGSize(width: 1134, height: 930), CGSize(width: 1135, height: 764)] {
        let fit = OfficeFit(size), layout = OfficePainter.layout(crowd, now: now, height: fit.height, scale: fit.scale)
        let card = CGSize(width: OfficeHover.cardWidth, height: 170)
        for pet in layout.pets {
            let r = CGRect(origin: OfficeHover.origin(beside: fit.rect(pet.frame), card: card, window: size), size: card)
            inside = inside && r.minX >= 8 - 0.01 && r.maxX <= size.width - 8 + 0.01 && r.minY >= 34 - 0.01
                && r.maxY <= size.height - 8 + 0.01 && !r.intersects(fit.rect(pet.body))
            placed += 1
        }
    }
    check(
        "office: the hover card is 320 wide, and for all thirty in the room it opens inside the window and off its pet",
        OfficeHover.cardWidth == 320 && placed == 60 && inside)

    // What a waiting session asks wraps by word: Latin words stay whole, Chinese still breaks between characters, and
    // a token longer than the line still breaks.
    func broken(_ text: String, width: CGFloat) -> [(text: String, wide: CGFloat)] {
        let storage = NSTextStorage(attributedString: OfficeCanvas.line(text, 12.5, .regular, 0, 1, .left, wraps: true))
        let manager = NSLayoutManager()
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: width, height: 10_000))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        var lines: [(String, CGFloat)] = []
        manager.enumerateLineFragments(forGlyphRange: manager.glyphRange(for: container)) { _, used, _, glyphs, _ in
            let characters = manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            lines.append(((text as NSString).substring(with: characters), used.width))
        }
        return lines
    }
    func letter(_ c: Character?) -> Bool { c.map { $0.isASCII && $0.isLetter } ?? false }
    let asks = "批准运行 docker compose up -d 然后重启 nginx 服务吗"
    let whole = stride(from: 70, through: 226, by: 4).allSatisfy { width in
        let lines = broken(asks, width: CGFloat(width)).map(\.text)
        return zip(lines, lines.dropFirst()).allSatisfy { !(letter($0.last) && letter($1.first)) }
    }
    let chinese = broken("这是一段很长的中文句子用来测试按字换行是否依然成立", width: 100)
    let token = String(repeating: "abcdefghij", count: 6)
    let long = broken(token, width: 120)
    check(
        "office: a waiting card's ask wraps by word; Chinese still breaks between characters; a token longer than the line still breaks",
        whole && chinese.count >= 3 && chinese.dropLast().allSatisfy { $0.wide > 100 - 14 } && long.count >= 3
            && long.allSatisfy { $0.wide <= 120.5 } && long.map(\.text).joined() == token)

    officeBackRowTests(now: now)
}

/// Names and project lines a little louder; the pets at the back stay faint. Needs a cut pet, else skipped.
@MainActor func officeBackRowTests(now: Date) {
    let what = "office: a back-row name is the faint colour 0xA3A0C4 at full strength; its pet is still drawn at 40%"
    let resting = Store()
    resting.readOnly = true
    resting.sessions = [officeSession("r0", "idle", finished: 9 * 3600, name: "休息的名字")]
    resting.seen["r0"] = now.timeIntervalSince1970
    guard officeDealCutPets(resting) else { return skipped("no pet frames", what) }
    let back = OfficePainter.layout(resting, now: now)
    if let pet = back.pets.first, let picture = OfficePainter.picture(resting, back, now: now) {
        let name = Pixels(picture).brightest(in: CGRect(x: pet.x - 48, y: pet.foot + 8, width: 96, height: 16))
        check(
            what,
            OfficeTheme.current.palette.faint == 0xA3A0C4 && abs(Int(name) - 0xA3) <= 4 && pet.asleep
                && OfficePainter.figure(resting, resting.sessions[0], pet, now: now).sprite.alpha == 0.4)
    } else {
        check(what, false)
    }
}

// ───────── The room ─────────

/// The cut pets, by name, that keep to the places the room is laid out for at their poses' own scale: each pose the office
/// shows them in at most 1.1 times as tall as its place and no wider than a sofa seat is apart from the next (75). The
/// office shows the others a share smaller (`OfficePets.fit`); this is for the record of which.
@MainActor func officePetsFitting() -> [String] {
    Pets.shared.refresh(force: true)
    let stills = [(7, 1), (6, 2), (4, 2), (3, 2), (0, 0), (0, 1)]
    return Pets.shared.ids.filter { OfficePets.shared.isCut($0) }.sorted().filter { pet in
        guard let idle = OfficePets.shared.frame(pet, row: 0, column: 0) else { return false }
        return [CGFloat(50), 70].allSatisfy { tall in
            stills.allSatisfy { row, column in
                guard let frame = OfficePets.shared.frame(pet, row: row, column: column) else { return true }
                let small = frame.tall * 5 < idle.tall * 4
                let scale = min(tall / CGFloat(small ? frame.tall : idle.tall), tall * 1.1 / CGFloat(small ? frame.wide : idle.wide))
                return CGFloat(frame.tall) * scale <= tall * 1.1 + 0.01 && CGFloat(frame.wide) * scale <= 75
            }
        }
    }
}

/// A made-up room of thirty: this many waiting (each asking something), with news, at work, looked at and resting, in
/// the store's order, each with a pet dealt the same way every run: the cut pets by name, or with `pool`, those.
@MainActor func officeStateStore(_ waiting: Int, _ news: Int, _ work: Int, _ seen: Int, _ resting: Int, pool: [String]? = nil) -> Store {
    let store = Store()
    store.readOnly = true
    store.sessions = officeSessions([
        ("w", "waiting", waiting, 900), ("n", "idle", news, 120), ("b", "busy", work, 60), ("s", "idle", seen, 900),
        ("r", "idle", resting, 9 * 3600.0),
    ])
    for s in store.sessions where s.id.hasPrefix("s") || s.id.hasPrefix("r") { store.seen[s.id] = Date().timeIntervalSince1970 }
    let pets = pool ?? officeFixedPets(200)
    _ = officeDealCutPets(store, giving: Dictionary(uniqueKeysWithValues: zip(store.sessions.map(\.id), pets)))
    return store
}

/// Every two things in this store's room, shown at this size, that are drawn over each other and should not be: pets
/// (the box of their drawn pixels), their words, cards and chat marks, the chips, the floor labels and each piece of
/// furniture as the painter tallies it. A pet may stand on or at its own seat's furniture, the little people sit on their
/// own desk, and a chat mark goes with its own pet, touching it beside its head; the rug and shadows are floor. Everyone
/// in `talking` carries a chat mark.
@MainActor func officeOverlaps(_ store: Store, size: CGSize, talking: Set<String>) -> (found: [String], things: Int, marks: Int) {
    let now = Date(), fit = OfficeFit(size), scale = fit.scale, H = fit.height
    let layout = OfficePainter.layout(store, now: now, height: H, scale: scale, previous: OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: []))
        .visited(by: OfficeVisits(), talking: talking)
    func line(_ base: CGFloat) -> CGFloat { OfficeLook.lineHeight(OfficeLook.type(base, scale: scale)) }
    struct Item {
        let name: String
        let rects: [CGRect]
        var seat: String? = nil  // the furniture a pet may overlap
    }
    var items: [Item] = []
    OfficePainter.parts = [:]
    _ = OfficePainter.room(store, layout, scale: scale)
    for (name, rects) in (OfficePainter.parts ?? [:]).sorted(by: { $0.key < $1.key }) { items.append(Item(name: name, rects: rects)) }
    OfficePainter.parts = nil
    let byID = Dictionary(store.sessions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var marks = 0
    for place in layout.pets {
        guard let s = byID[place.id] else { continue }
        let figure = OfficePainter.figure(store, s, place, now: now), pose = store.pose(of: s, now: now).sheet
        var body = figure.sprite.rect
        if let pet = figure.pet, let frame = OfficePets.shared.frame(pet, row: pose.row, column: pose.still) {
            body = CGRect(
                x: body.minX + CGFloat(frame.left) * figure.scale, y: body.minY + CGFloat(frame.top) * figure.scale,
                width: CGFloat(frame.wide) * figure.scale, height: CGFloat(frame.tall) * figure.scale)
        }
        let seat: String? =
            switch place.zone {
            case .lounge: "couch \(place.seat / 10)-\(place.seat % 10 < 5 ? 0 : 1)"
            case .desk: "desk \(place.seat)"
            case .sofa: "sofa \(place.seat / 3)"
            case .queue: nil
            }
        items.append(Item(name: "pet \(s.id)", rects: [body], seat: seat))
        let words: CGRect
        switch place.zone {
        case .lounge: words = CGRect(x: place.x - 48, y: place.foot + 8, width: 96, height: place.asleep ? line(11) : line(12) + 3)
        case .desk:
            let w = OfficeLayout.deskWords(foot: place.foot, middle: place.x - 26, scale: scale)
            words = w.plate.union(w.project ?? w.plate)
        case .sofa:
            let w = OfficeLayout.sofaWords(foot: place.foot, middle: place.x, scale: scale)
            words = w.plate.union(w.project ?? w.plate)
        case .queue:
            words = place.kind == .work ? place.words : place.words.union(CGRect(x: place.x - 7, y: place.words.maxY - 1, width: 14, height: 9))
        }
        if place.host == nil { items.append(Item(name: (place.zone == .queue && place.kind == .waiting ? "card " : "words ") + s.id, rects: [words])) }
        if place.chats {
            items.append(Item(name: "mark \(s.id)", rects: [place.markArea]))
            marks += 1
        }
    }
    for chip in layout.chips {
        let r = chip.rect
        items.append(Item(name: "chip \(chip.kind)", rects: [chip.kind == .waiting ? r.union(r.offsetBy(dx: 8, dy: 6)).insetBy(dx: -0.5, dy: -0.5) : r]))
    }
    for label in OfficePainter.floorLabels(layout, scale: scale) {
        items.append(Item(name: "label \(label.text)", rects: [label.rect, CGRect(x: label.rect.minX, y: label.rect.maxY + 2, width: 26, height: 2)]))
    }
    var found: [String] = []
    for i in items.indices {
        for j in items.indices where j > i {
            let a = items[i], b = items[j]
            if let seat = a.seat, seat == b.name { continue }
            if let seat = b.seat, seat == a.name { continue }
            let ends = Set([a.name, b.name].map { String($0.split(separator: " ").last ?? "") })
            let kinds = Set([a.name, b.name].map { String($0.split(separator: " ").first ?? "") })
            if ends.count == 1 && (kinds == ["agents", "desk"] || kinds == ["pet", "mark"]) { continue }
            var both = CGRect.null
            for p in a.rects {
                for q in b.rects {
                    let r = p.intersection(q)
                    if !r.isNull, r.width > 0.01, r.height > 0.01 { both = both.union(r) }
                }
            }
            if !both.isNull {
                found.append("\(Int(H)): \(a.name) × \(b.name): \(Int(both.width.rounded(.up)))x\(Int(both.height.rounded(.up))) at (\(Int(both.minX)), \(Int(both.minY)))")
            }
        }
    }
    return (found, items.count, marks)
}

/// The new room's places, its chip, its little people and its floor labels.
@MainActor func officeNewRoomTests() {
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    check(
        "office: seven queue places, the eighth for the chip, cards 116 wide every 125 from your desk's right",
        OfficeLayout.queueHolds == 7 && (0...7).map { OfficeLayout.queueX($0) } == [244, 369, 494, 619, 744, 869, 994, 1119]
            && OfficeLayout.cardWidth == 116 && OfficeLayout.queueLeft >= OfficeLayout.yourDesk.maxX + 8
            && OfficeLayout.queueX(7) + 58 <= 1194 - 10)
    check(
        "office: twelve sofa seats, three on each of four sofas that line up with the desks' blocks",
        OfficeLayout.sofaSeats.count == 12 && OfficeLayout.sofaLefts == [47, 334, 621, 908] && OfficeLayout.blockLefts == [46, 620])
    let low = OfficeLayout(waiting: ids("w", 3), unread: [], busy: [], seen: [], resting: [], height: 764)
    let tall = OfficeLayout(waiting: ids("w", 3), unread: [], busy: [], seen: [], resting: [], height: 979, scale: 1134 / 1194)
    check(
        "office: the cards' top is where the rug's band begins: 610.5 at 764, 808 at 979, one line of what it asks, then two",
        low.cardTop == 610.5 && low.asks == 1 && tall.cardTop == 808 && tall.asks == 2 && low.rugTop <= low.cardTop && tall.rugTop <= tall.cardTop)

    // The room as painted: both rows of couches whole with nobody at the back, four sofas, sixteen desks, your desk.
    let empty = Store()
    empty.readOnly = true
    empty.sessions = officeSessions([("b", "busy", 1, 60)])
    let bare = OfficePainter.layout(empty, now: Date())
    OfficePainter.parts = [:]
    _ = OfficePainter.room(empty, bare, scale: 1)
    let parts = OfficePainter.parts ?? [:]
    OfficePainter.parts = nil
    let wanted = ["couch 0-0", "couch 0-1", "couch 1-0", "couch 1-1", "sofa 0", "sofa 1", "sofa 2", "sofa 3", "your desk", "door", "board"]
        + (0..<16).map { "desk \($0)" }
    check(
        "office: with nobody at the back both rows of couches are drawn whole, with the four sofas, sixteen desks and your desk",
        !bare.pets.contains { $0.zone == .lounge } && wanted.allSatisfy { !(parts[$0] ?? []).isEmpty })
    let couches = (0..<2).flatMap { row in (0..<2).map { side in (parts["couch \(row)-\(side)"] ?? []).reduce(CGRect.null) { $0.union($1) } } }
    check(
        "office: the couches run from block edge to block edge, 47 to 573 and 621 to 1147",
        couches.count == 4 && couches.allSatisfy { [47, 621].contains($0.minX) && [573, 1147].contains($0.maxX) })

    // The waiting chip is the queue's eighth card: coral, its words in ink like the other cards'.
    let nine = officeStateStore(9, 5, 6, 5, 5)
    let nineRoom = OfficePainter.layout(nine, now: Date())
    if let chip = nineRoom.chips.first(where: { $0.kind == .waiting }), let room = OfficePainter.picture(nine, nineRoom, now: Date(), scale: 1) {
        let pixels = Pixels(room), pad = OfficeLayout.cardPad
        let title = CGRect(x: chip.rect.minX + pad, y: chip.rect.minY + pad + 2, width: chip.rect.width - 2 * pad, height: 11)
        let names = CGRect(x: chip.rect.minX + pad, y: chip.rect.minY + pad + 20, width: chip.rect.width - 2 * pad, height: 9)
        func darkest(_ r: CGRect) -> UInt32 {
            var least: UInt32 = 0xFF
            for y in stride(from: r.minY, to: r.maxY, by: 0.5) {
                for x in stride(from: r.minX, to: r.maxX, by: 0.5) { least = min(least, pixels.at(x, y) >> 16) }
            }
            return least
        }
        check(
            "office: nine waiting: the chip in the queue's eighth place is coral with its title and names in ink, as the cards are",
            chip.count == 2 && chip.rect == CGRect(x: 1061, y: 610.5, width: 116, height: 61.5)
                && same(pixels.at(chip.rect.maxX - 4, chip.rect.minY + 4), OfficeLook.call) && darkest(title) < 0x50 && darkest(names) < 0x50)
    } else {
        check("office: nine waiting: the chip in the queue's eighth place is coral with its title and names in ink, as the cards are", false)
    }
    let crowd = OfficeLayout(waiting: ids("w", 9), unread: ids("u", 25), busy: ids("b", 4), seen: [], resting: [])
    let wall = crowd.chips.filter { $0.kind != .waiting }
    // The chips are drawn above the pets, so one walking down the right wall into the queue passes behind the waiting chip.
    let chipView = OfficeView(frame: CGRect(x: 0, y: 0, width: 1194, height: 764))
    chipView.update(nine)
    let chipLayer = officeStage(chipView)?.sublayers?.first { $0.name == "chips" }
    let sprites = (officeStage(chipView)?.sublayers ?? []).filter { $0.name != "chips" && $0.name != "room" }
    let waitingChip = OfficePainter.layout(nine, now: Date()).chips.first { $0.kind == .waiting }?.rect ?? .zero
    check(
        "office: with nine waiting the chips are a layer of their own above every pet and walker, holding the waiting chip",
        chipLayer?.contents != nil && officeStage(chipView)?.sublayers?.last === chipLayer && sprites.count == 30
            && sprites.allSatisfy { ($0.zPosition) < (chipLayer?.zPosition ?? 0) && (chipLayer?.zPosition ?? 0) > 1000 }
            && (chipLayer?.frame.contains(waitingChip) ?? false))
    check(
        "office: those with news or at work the room has no place for are counted on the back wall's left end, one chip over the other",
        wall.map(\.kind) == [.news, .work] && wall[0].rect.origin == CGPoint(x: 10, y: 10) && wall[1].rect.minX == 10
            && wall[1].rect.minY >= wall[0].rect.maxY + 6 && wall.allSatisfy { $0.rect.maxY <= 62 && $0.rect.maxX < 166 })

    // Subagents. Nobody's for now; given, as little people on their session's desk.
    check("office: the store's subagent counts start empty", Store().agentCounts.isEmpty)
    let working = officeStateStore(0, 0, 4, 2, 0)
    let desks = OfficePainter.layout(working, now: Date())
    let before = OfficePainter.roomKey(working, desks, scale: 1)
    working.agentCounts = ["b0": 1, "b1": 5]
    func agents(_ store: Store) -> [String: [CGRect]] {
        OfficePainter.parts = [:]
        _ = OfficePainter.room(store, desks, scale: 1)
        defer { OfficePainter.parts = nil }
        return (OfficePainter.parts ?? [:]).filter { $0.key.hasPrefix("agents ") }
    }
    let drawn = agents(working)
    let seat0 = desks.pets.first { $0.id == "b0" }?.seat ?? -1, seat1 = desks.pets.first { $0.id == "b1" }?.seat ?? -1
    let width = { (rects: [CGRect]?) in (rects ?? []).reduce(CGRect.null) { $0.union($1) }.width }
    check(
        "office: subagents sit on their session's desk as little people, three at most and then how many more (tags \(drawn.keys.sorted()), walkers \(OfficePainter.walkers(working, desks).map { "\($0.seat) \($0.pets.count)" }), seats \(seat0) \(seat1))",
        // The little people walk, as layers of their own (`walkers`); the room draws only the tag of how many more.
        drawn.count == 2 && width(drawn["agents \(seat0)"]) == 0 && width(drawn["agents \(seat1)"]) > 0
            && OfficePainter.walkers(working, desks).map { "\($0.seat) \($0.pets.count)" } == [seat0, seat1].sorted().map { "\($0) \($0 == seat0 ? 1 : 3)" }
            && OfficePainter.helpers(working, desks).map(\.count).sorted() == [1, 5] && before != OfficePainter.roomKey(working, desks, scale: 1))
    // The floor labels on the left margin, each over the first piece of its band, the waiting one on the rug, a short
    // line under each.
    for (height, scale) in [(CGFloat(764), CGFloat(1)), (979, 1134 / 1194)] {
        let layout = OfficePainter.layout(nine, now: Date(), height: height, scale: scale)
        let labels = OfficePainter.floorLabels(layout, scale: scale)
        OfficePainter.parts = [:]
        let room = OfficePainter.room(nine, layout, scale: scale)
        let pieces = (OfficePainter.parts ?? [:]).values.flatMap { $0 }
        OfficePainter.parts = nil
        let byText = Dictionary(labels.map { (String($0.text.split(separator: " ").first ?? ""), $0.rect) }, uniquingKeysWith: { first, _ in first })
        let sofaTop = layout.sofaFloor - 4 - OfficePainter.sofaDeep - OfficePainter.sofaBack - 1
        let placed = labels.count == 4 && labels.allSatisfy { $0.rect.minX == 4 } && (byText["在等你"].map { $0.minY >= layout.rugTop } ?? false)
            && (byText["有话说"].map { $0.maxY + 2 <= sofaTop } ?? false) && (byText["工位"].map { $0.maxY <= layout.deskFloors[0] - 66 } ?? false)
            && (byText["休息"].map { $0.maxY <= layout.loungeFloors[0] - 3 - 25 } ?? false)
            && labels.allSatisfy { label in !pieces.contains { $0.intersects(label.rect) } }
        let underlined = room.map { image in
            let pixels = Pixels(image)
            return labels.allSatisfy { same(pixels.at($0.rect.minX + 12, $0.rect.maxY + 3), OfficeTheme.current.palette.rugEdge) }
        } ?? false
        check("office \(Int(height)) high: the four floor labels on the left margin, each over its band, clear of the furniture", placed)
        check("office \(Int(height)) high: ...with the short line under each that the slate room draws", underlined)
    }
}

/// The way a pet walks in the new room: it crosses the sofa band only by the centre gap or a wall aisle, and no
/// route crosses a sofa, a couch, a desk or your desk, for every size of pet, in both rooms' heights and both themes.
/// `themes`: the office's own by default; an extension's checks try its theme the same way.
@MainActor func officeWalkClearTests(themes: [OfficeTheme]? = nil) {
    func ids(_ prefix: String, _ count: Int) -> [String] { (0..<count).map { "\(prefix)\($0)" } }
    for theme in themes ?? OfficeTheme.all {
        OfficeTheme.shown = theme
        defer { OfficeTheme.shown = nil }
        for (height, scale) in [(CGFloat(764), CGFloat(1)), (979, 1134 / 1194)] {
            let layout = OfficeLayout(
                waiting: ids("w", 7), unread: ids("u", 7), busy: ids("b", 4), seen: ids("s", 6), resting: ids("r", 6), height: height, scale: scale)
            // Visitors stand beside hosts in every part of the room a visit may go to.
            let hosts = ["u0", "u2", "b0", "s5", "r0", "r5"].compactMap { id in layout.pets.first { $0.id == id } }
            let guests = hosts.flatMap { host in [1, -1].map { side in OfficeSpot(point: CGPoint(x: host.x + side * OfficeVisits.apart, y: host.foot + 4), lane: .row) } }
            let spots = layout.pets.map { layout.spot(of: $0) } + guests + [OfficeLayout.doorSpot]
            let store = Store()
            store.readOnly = true
            OfficePainter.parts = [:]
            _ = OfficePainter.room(store, layout, scale: scale)
            let parts = OfficePainter.parts ?? [:]
            OfficePainter.parts = nil
            // What a pet may not walk through: each piece of furniture above the line its sitters' feet are on (below it,
            // the seat's front and its legs, is where a sitter's feet are and a walker passes in front); desks and your
            // desk whole.
            var solid: [(name: String, rect: CGRect)] = []
            for (name, rects) in parts {
                let feet: CGFloat? =
                    name.hasPrefix("couch ") ? layout.loungeFloors[Int(String(name.dropFirst(6).prefix(1))) ?? 0] - 3
                    : name.hasPrefix("sofa ") ? layout.sofaFloor - 4 : name.hasPrefix("desk ") || name == "your desk" ? .infinity : nil
                guard let feet else { continue }
                for r in rects where r.minY < feet { solid.append((name, CGRect(x: r.minX, y: r.minY, width: r.width, height: min(r.maxY, feet) - r.minY))) }
            }
            var routes = 0, crossing: [String] = [], bandCrossings: Set<CGFloat> = []
            let band = (top: layout.sofaFloor - 4 - 40, bottom: layout.sofaFloor - 4)
            for tall in [CGFloat(50), 70] {
                for body in [OfficeLayout.body(tall: tall), (left: CGFloat(60), right: CGFloat(60))] {
                    for a in spots {
                        for b in spots where a != b {
                            let route = layout.walk(from: a, to: b, tall: tall, body: body).route
                            routes += 1
                            for (p, q) in zip(route, route.dropFirst()) {
                                let leg = CGRect(x: min(p.x, q.x), y: min(p.y, q.y), width: abs(q.x - p.x), height: abs(q.y - p.y))
                                if p.x == q.x, min(p.y, q.y) < band.top, max(p.y, q.y) > band.bottom { bandCrossings.insert(p.x) }
                                for piece in solid {
                                    // A leg along a line is a rectangle of no width or height: it crosses what it runs inside.
                                    let inside = leg.width == 0
                                        ? piece.rect.minX < leg.minX && leg.minX < piece.rect.maxX && max(piece.rect.minY, leg.minY) < min(piece.rect.maxY, leg.maxY)
                                        : piece.rect.minY < leg.minY && leg.minY < piece.rect.maxY && max(piece.rect.minX, leg.minX) < min(piece.rect.maxX, leg.maxX)
                                    if inside && crossing.count < 6 { crossing.append("\(piece.name) by \(p)→\(q)") }
                                }
                            }
                        }
                    }
                }
            }
            let at = "office \(theme.name) \(Int(height)) high"
            let aisles = Set(bandCrossings.map { $0 == 597 ? "centre" : $0 < 46 ? "left" : $0 > 1148 ? "right" : "\($0)" })
            check("\(at): \(routes) routes cross no sofa, couch, desk or your desk, wide pets and visitors' spots included", routes > 1000 && crossing.isEmpty)
            for line in crossing { print("      " + line) }
            check("\(at): ...and cross the sofa band only by the centre gap and the wall aisles", !aisles.isEmpty && aisles.isSubset(of: ["centre", "left", "right"]))
            let queue = layout.pets.filter { $0.zone == .queue }.map { layout.spot(of: $0) }
            let fromLeft = OfficeSpot(point: CGPoint(x: OfficeLayout.deskLeft(0) + 88, y: layout.deskFloors[1] + 10), lane: .row)
            check(
                "\(at): ...to the queue even from the left wall's desks it goes by the centre, not past your desk",
                queue.count == 7 && queue.allSatisfy { layout.route(from: fromLeft, to: $0).contains { $0.x == 597 } })
        }
    }
}

/// Nothing in the room is drawn over anything else, chat marks included, at 764 and 979, in both themes, for the
/// states the user looked at, with everyone not waiting in the queue talking. With OFFICE_OVERLAPS set, also measured
/// (not checked) with other pets dealt and for the sessions open now, read-only.
@MainActor func officeOverlapTests() {
    OfficePets.shared.synchronous = true
    defer { OfficePets.shared.synchronous = false }
    func states(_ pool: [String]? = nil) -> [(name: String, store: Store)] {
        [
            ("usual", officeStateStore(2, 3, 4, 6, 15, pool: pool)), ("9 waiting", officeStateStore(9, 5, 6, 5, 5, pool: pool)),
            ("12 with news", officeStateStore(0, 12, 4, 6, 8, pool: pool)), ("iPad", officeStateStore(4, 6, 8, 6, 6, pool: pool)),
        ]
    }
    let fitting = officePetsFitting(), cut = officeFixedPets(200)
    // Thirty to a room, from at least fifty cut pets: with none cut there is no room to look at (and no `states[1]`).
    guard cut.count >= 50 else { return skipped("no pet frames", "office: no two things drawn over each other, in each theme; chat marks beside or over the head") }
    print("      \(fitting.count) of the \(cut.count) cut pets fit their places before the office shrinks any: the others " + cut.filter { !fitting.contains($0) }.joined(separator: ", "))
    let shrunk = cut.compactMap { pet -> String? in
        let shares = [("desk/queue", CGFloat(70), CGFloat?.none), ("sofa", 70, 75), ("back row", 50, 75)].compactMap { place, tall, wide -> String? in
            let share = OfficePets.shared.fit(pet, tall: tall, wide: wide)
            return share < 0.999 ? "\(place) \(Int((share * 100).rounded()))%" : nil
        }
        return shares.isEmpty ? nil : "\(pet) (" + shares.joined(separator: ", ") + ")"
    }
    print("      shown smaller so every pose fits: " + shrunk.joined(separator: "; "))
    if ProcessInfo.processInfo.environment["OFFICE_OVERLAPS"] != nil {
        let real = Store()
        real.readOnly = true
        real.loadOnce()
        real.scanLinksNow()
        _ = officeDealCutPets(real)
        let dealt = (0..<4).flatMap { round in states(Array(cut.dropFirst(round * 25)) + Array(cut.prefix(round * 25))).map { ("\($0.name) pool+\(round * 25)", $0.store) } }
        for (name, store) in [("now", real)] + dealt {
            for size in [CGSize(width: 1194, height: 764), CGSize(width: 1134, height: 930)] {
                let talking = name == "now" ? OfficeVisits.talking(store.peers, now: Date()) : Set(store.sessions.map(\.id))
                let result = officeOverlaps(store, size: size, talking: talking)
                print("      measured \(name) \(Int(OfficeFit(size).height)): \(result.found.count) of \(result.things) things, \(result.marks) marks " + result.found.joined(separator: "; "))
            }
        }
    }
    // Every cut pet in the pool, thirty at a time: the four states dealt from the pool turned by 25 each round.
    let rounds = stride(from: 0, to: cut.count, by: 25).map { turn in (turn, states(Array(cut.dropFirst(turn) + cut.prefix(turn)))) }
    var dealt = Set<String>()
    for (_, stores) in rounds {
        for (_, store) in stores {
            dealt.formUnion(store.petBySession.values)
            let busy = Buckets(store, now: Date()).busy.map(\.id)
            store.agentCounts = Dictionary(zip(busy, [1, 2, 4]).map { ($0, $1) }, uniquingKeysWith: { first, _ in first })
        }
    }
    let states = rounds.first?.1 ?? []
    // This test counts office furniture parts; an extension's scene has its own geometry checks.
    for theme in OfficeTheme.officeThemes {
        OfficeTheme.shown = theme
        defer { OfficeTheme.shown = nil }
        var summary: [String] = [], found: [String] = [], things = 0, marks = 0
        for (turn, stores) in rounds {
            for (name, store) in stores {
                let all = Set(store.sessions.map(\.id))
                for size in [CGSize(width: 1194, height: 764), CGSize(width: 1134, height: 930)] {
                    let result = officeOverlaps(store, size: size, talking: all)
                    found += result.found.map { "\(name) pool+\(turn) \($0)" }
                    things += result.things
                    marks += result.marks
                    summary.append("\(name) +\(turn) \(Int(OfficeFit(size).height)): \(result.found.count)")
                }
            }
        }
        print("      overlaps in the \(theme.name) room, everyone talking, every pet dealt: " + summary.joined(separator: ", "))
        for line in found.prefix(12) { print("      " + line) }
        check(
            "office \(theme.name): no two things drawn over each other at 764 and 979 in four states, chat marks included, all \(cut.count) pets dealt",
            found.isEmpty && cut.count >= 50 && dealt == Set(cut) && things > rounds.count * 8 * 80 && marks > rounds.count * 8 * 15)
    }
    // Where a row's gap is too small for a mark over the head, it goes beside the head, on the right; with room, over it.
    let nine = states[1].store, all = Set(nine.sessions.map(\.id))
    let low = OfficePainter.layout(nine, now: Date(), height: 764).visited(by: OfficeVisits(), talking: all)
    let high = OfficePainter.layout(nine, now: Date(), height: 979, scale: 1134 / 1194).visited(by: OfficeVisits(), talking: all)
    let seated = { (layout: OfficeLayout) in layout.pets.filter { $0.chats && $0.zone != .queue } }
    check(
        "office: at 764 a chat mark sits beside its pet's head, at 979 over it",
        seated(low).count > 15 && seated(low).allSatisfy { $0.mark.minX > $0.x && $0.mark.maxY > $0.foot - $0.tall }
            && seated(high).count > 15 && seated(high).allSatisfy { $0.mark.maxY <= $0.foot - $0.tall && $0.mark.midX == $0.x })
}

/// The hover cards in the new room land inside the window and clear of what they are about.
@MainActor func officeHoverSpotTests() {
    let store = officeStateStore(9, 5, 6, 5, 25)
    store.log((0..<4).map { OfficeActivity.Event(at: Date().addingTimeInterval(-Double($0) * 60), id: "n\($0)", name: "n\($0)", kind: .finished) })
    func measured<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view.environmentObject(store).environment(\.zoom, 1).environment(\.colorScheme, .dark))
        let size = host.fittingSize
        return CGSize(width: size.width, height: size.height)
    }
    for window in [CGSize(width: 1134, height: 930), CGSize(width: 1194, height: 764)] {
        let fit = OfficeFit(window)
        let layout = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale)
        func pet(_ zone: OfficeLayout.Zone, last: Bool = false) -> OfficeLayout.Pet? {
            let pets = layout.pets.filter { $0.zone == zone }.sorted { $0.x < $1.x }
            return last ? pets.last : pets.first
        }
        var targets: [(String, CGRect, CGSize)] = []
        for (name, place) in [("first queue pet", pet(.queue)), ("last queue pet", pet(.queue, last: true)), ("sofa pet", pet(.sofa)), ("lounge pet", pet(.lounge))] {
            if let place, let s = store.sessions.first(where: { $0.id == place.id }) { targets.append((name, place.frame, measured(OfficeCard(s: s)))) }
        }
        if let chip = layout.chips.first(where: { $0.kind == .waiting }) {
            targets.append(("chip", chip.rect, measured(OfficeWaitingCard(ids: layout.waitingElsewhere).padding(8))))
        }
        targets.append(("door", OfficeLayout.door, measured(OfficeDoorCard(ids: layout.behindDoorIDs).padding(8))))
        targets.append(("board", OfficeLayout.boardArea, measured(OfficeBoardCard(lines: OfficeBoardCard.lines(store)).padding(8))))
        let inside = CGRect(x: 8, y: 34, width: window.width - 16, height: window.height - 42)
        let placed = targets.map { name, target, card -> (String, Bool) in
            let spot = fit.rect(target), at = OfficeHover.origin(beside: spot, card: card, window: window)
            let r = CGRect(origin: at, size: card)
            return (name, card.width > 100 && card.height > 30 && inside.insetBy(dx: -0.5, dy: -0.5).contains(r) && !r.intersects(spot))
        }
        for (name, ok) in placed where !ok { print("      \(Int(window.width))x\(Int(window.height)): the \(name)'s card is out of place") }
        check(
            "office \(Int(window.width))x\(Int(window.height)): the cards of a queue pet, a sofa pet, a lounge pet, the chip, the door and the board land inside the window, clear of them",
            placed.count == 7 && placed.allSatisfy(\.1))
    }
}

/// Of each theme's light and dark inks, on each of these floors of their own: where the names, faint words and labels do not
/// take the one that reads better ("<theme> <floor>"). An extension's checks sweep its theme the same way.
@MainActor func officeInkSweep(_ themes: [OfficeTheme], floors: [UInt32]) -> [String] {
    var worse: [String] = []
    let sweep = OfficeLayout(waiting: [], unread: [], busy: [], seen: [], resting: ["r0"])
    for theme in themes {
        for hex in floors {
            let p = theme.palette, q = theme.floored(hex).palette
            let dark = OfficePalette.contrast(p.darkName, hex) > OfficePalette.contrast(p.name, hex)
            OfficeTheme.shown = theme.floored(hex)
            let labels = OfficePainter.floorLabels(sweep, scale: 1).filter { $0.hex != OfficeLook.call }
            OfficeTheme.shown = nil
            if q.name != (dark ? p.darkName : p.name) || q.faint != (dark ? p.darkFaint : p.faint) || !labels.allSatisfy({ $0.hex == q.faint }) {
                worse.append("\(theme.name) \(String(format: "%06X", hex))")
            }
        }
    }
    return worse
}

/// Themes. The room's look is a theme's: its colours and how its furniture is drawn; the layout is the same in every
/// one. A floor colour of their own overrides the theme's, and the wall, skirting and rug follow it.
@MainActor func officeThemeTests() {
    check("office: three themes, slate first, seaview room last, and slate is what an unknown name gets", OfficeTheme.all.map(\.name) == ["青灰", "暖夜", "海景房"]
        && OfficeTheme.named("青灰").name == "青灰" && OfficeTheme.named("暖夜").name == "暖夜" && OfficeTheme.named("粉红").name == "青灰"
        && OfficeTheme.named(nil).name == "青灰")
    // The theme menu offers the office's two; seaview room (and an extension's scene) is a mode.
    check("office: the theme menu lists only slate and warm-night", OfficeTheme.officeThemes.map(\.name) == ["青灰", "暖夜"]
        && !OfficeTheme.officeThemes.contains { $0.name == OfficeTheme.zone.name })
    UserDefaults.standard.set("暖夜", forKey: "officeTheme")
    settleOfficeTheme()
    let kept = UserDefaults.standard.string(forKey: "officeTheme")
    check("office: at launch an office theme is left alone", kept == "暖夜")
    // The modes: seaview room is the office on in its theme; office the office on in the theme last chosen (slate until one is);
    // board the office off, the theme kept.
    let modes = Store()
    modes.readOnly = true
    for key in ["office", "officeTheme", "officeThemeOffice"] { UserDefaults.standard.removeObject(forKey: key) }
    let untouched = OfficeMode.current
    OfficeMode.zone.choose(store: modes)
    let zone = (OfficeMode.current, UserDefaults.standard.bool(forKey: "office"), UserDefaults.standard.string(forKey: "officeTheme"))
    OfficeMode.office.choose(store: modes)
    let office = (OfficeMode.current, UserDefaults.standard.bool(forKey: "office"), UserDefaults.standard.string(forKey: "officeTheme"))
    setOfficeTheme("暖夜")
    OfficeMode.zone.choose(store: modes)
    OfficeMode.office.choose(store: modes)
    let back = (OfficeMode.current, UserDefaults.standard.string(forKey: "officeTheme"))
    OfficeMode.board.choose(store: modes)
    let board = (OfficeMode.current, UserDefaults.standard.bool(forKey: "office"), UserDefaults.standard.string(forKey: "officeTheme"))
    for key in ["office", "officeTheme", "officeThemeOffice"] { UserDefaults.standard.removeObject(forKey: key) }
    check("office: choosing the seaview room turns the office on in it, the office mode in the theme last chosen (slate until one is, warm-night after), the board mode turns it off and keeps the theme",
        untouched == .board && zone == (.zone, true, "海景房") && office == (.office, true, "青灰") && back == (.office, "暖夜") && board == (.board, false, "暖夜"))
    check("office: the menu's lines for the office and the seaview room say why they are off in a window too small, the board never",
        officeMenuItem(.office, fits: true) == ("办公室", true) && officeMenuItem(.zone, fits: false) == ("海景房（窗口再大一些才显示）", false) && officeMenuItem(.board, fits: false) == ("值班室", true))
    check(
        "office: slate and warm-night each have their own palette",
        OfficeTheme.studio.palette.floor == 0x303B46 && OfficeTheme.studio.palette.wall == 0x26313B && OfficeTheme.studio.palette.mustard.top == 0x91ACBF
            && OfficeTheme.night.palette.floor == 0x2C2849 && OfficeTheme.night.palette.wall == 0x242140 && OfficeTheme.night.palette.mustard.top == 0xDDB766)
    UserDefaults.standard.removeObject(forKey: "officeTheme")
    UserDefaults.standard.removeObject(forKey: "officeFloor")
    let fresh = OfficeTheme.current
    setOfficeTheme("暖夜")
    let night = OfficeTheme.current
    setOfficeFloor(0x1F2A24)
    let floored = OfficeTheme.current
    setOfficeFloor(nil)
    let following = OfficeTheme.current
    UserDefaults.standard.set("没有这个", forKey: "officeTheme")
    let unknown = OfficeTheme.current
    UserDefaults.standard.removeObject(forKey: "officeTheme")
    check(
        "office: the setting picks the theme (slate until set, and for a name it does not know); a floor of its own until the theme's is let back",
        fresh.name == "青灰" && night.name == "暖夜" && floored.name == "暖夜" && floored.palette.floor == 0x1F2A24
            && following.palette.floor == OfficeTheme.night.palette.floor && unknown.name == "青灰" && UserDefaults.standard.string(forKey: "officeFloor") == nil)
    // The floor's own colour: wall and skirting darker by fixed steps, the rug and its edge lighter, the same every time.
    let dark = OfficeTheme.studio.floored(0x1F2A24), again = OfficeTheme.studio.floored(0x1F2A24)
    func luma(_ hex: UInt32) -> Int { Int((hex >> 16) & 255) * 3 + Int((hex >> 8) & 255) * 6 + Int(hex & 255) }
    let p = dark.palette
    check(
        "office: a floor of his own derives the wall, skirting, rug and rug edge from it, the same every time",
        p.floor == 0x1F2A24 && [p.wall, p.skirting, p.rug, p.rugEdge] == [again.palette.wall, again.palette.skirting, again.palette.rug, again.palette.rugEdge]
            && luma(p.skirting) < luma(p.wall) && luma(p.wall) < luma(p.floor) && luma(p.floor) < luma(p.rug) && luma(p.rug) < luma(p.rugEdge)
            && p.name == OfficeTheme.studio.palette.name && OfficePalette.contrast(p.name, p.floor) >= 4.5)
    // Of the theme's light and dark inks, the one that reads better on their floor; the floor's labels and the projects follow.
    let floors = stride(from: 0, through: 0xFF, by: 0x11).map { UInt32($0) * 0x010101 } + [0x606060, 0x3A6EA5, 0xE8E2D4, 0x1F2A24]
    let worse = officeInkSweep(OfficeTheme.all, floors: floors)
    for line in worse { print("      the worse ink on " + line) }
    check(
        "office: on any floor of his own (greys 000000 to FFFFFF, 606060, 3A6EA5, E8E2D4, 1F2A24) the names take whichever ink reads better, the labels and projects with them",
        worse.isEmpty)
    let light = OfficeTheme.studio.floored(0xE8E2D4).palette
    check(
        "office: on a light floor of his own the names and faint words turn to the theme's dark ink, 4.5:1 or more",
        light.name == OfficeTheme.studio.palette.darkName && light.faint == OfficeTheme.studio.palette.darkFaint
            && OfficePalette.contrast(light.name, light.floor) >= 4.5 && OfficePalette.contrast(light.faint, light.floor) >= 4.5
            && OfficeTheme.night.floored(0xE8E2D4).palette.name == OfficeTheme.night.palette.darkName)
    // The rug and its edge toward contrast: darker than a light floor, lighter than a dark one.
    let dim = OfficeTheme.studio.floored(0x1F2A24).palette
    check(
        "office: on a light floor of his own the rug and its edge are darker than the floor, on a dark one lighter; the edge reads 1.5:1 on either",
        luma(light.rugEdge) < luma(light.rug) && luma(light.rug) < luma(light.floor) && luma(dim.floor) < luma(dim.rug) && luma(dim.rug) < luma(dim.rugEdge)
            && OfficePalette.contrast(light.rugEdge, light.floor) >= 1.5 && OfficePalette.contrast(dim.rugEdge, dim.floor) >= 1.5)
    check(
        "office: both themes keep their names 4.5:1 or more on their own floor",
        OfficeTheme.all.allSatisfy { OfficePalette.contrast($0.palette.name, $0.palette.floor) >= 4.5 })
    setOfficeTheme("暖夜")
    let floorOnly = OfficeTheme.chosen(arguments: ["x", "--floor", "1F2A24"])
    UserDefaults.standard.removeObject(forKey: "officeTheme")
    check(
        "office: a snapshot's --floor alone keeps the theme he has set",
        floorOnly?.name == "暖夜" && floorOnly?.palette.floor == 0x1F2A24 && OfficeTheme.chosen(arguments: ["x", "--floor", "1F2A24"])?.name == "青灰")
    check(
        "office: a snapshot takes --theme and --floor, in memory",
        OfficeTheme.chosen(arguments: ["x", "--theme", "暖夜", "--floor", "1F2A24"]).map { $0.name == "暖夜" && $0.palette.floor == 0x1F2A24 } ?? false
            && OfficeTheme.chosen(arguments: ["x", "--floor", "#E8E2D4"]).map { $0.name == "青灰" && $0.palette.floor == 0xE8E2D4 } ?? false
            && OfficeTheme.chosen(arguments: ["x"]) == nil && OfficeTheme.hex("zz") == nil)

    // The theme never moves anything; the room and the words repaint when it or the floor changes.
    let store = officeStateStore(2, 3, 4, 6, 15)
    let layout = OfficePainter.layout(store, now: Date())
    func keys() -> (room: String, words: [String]) {
        (OfficePainter.roomKey(store, layout, scale: 1), layout.pets.compactMap { place in
            store.sessions.first { $0.id == place.id }.map { OfficeView.wordsKey(store, $0, place, layout, now: Date(), scale: 1) }
        })
    }
    var pictures: [CGImage] = []
    var sets: [(room: String, words: [String])] = []
    for theme in [OfficeTheme.studio, OfficeTheme.night, OfficeTheme.studio.floored(0xE8E2D4)] {
        OfficeTheme.shown = theme
        sets.append(keys())
        if let image = OfficePainter.room(store, layout, scale: 1) { pictures.append(image) }
    }
    OfficeTheme.shown = nil
    check(
        "office: another theme or floor repaints the room and every pet's words; the places stay",
        pictures.count == 3 && sets[0].room != sets[1].room && sets[0].room != sets[2].room && sets[0].words != sets[2].words
            && sets[0].words.count == 30 && OfficePainter.layout(store, now: Date()).pets == layout.pets
            && same(Pixels(pictures[0]).at(600, 300), 0x303B46) && same(Pixels(pictures[1]).at(600, 300), 0x2C2849)
            && same(Pixels(pictures[2]).at(600, 300), 0xE8E2D4))
    // Where a mark goes is painted with the words: a room grown taller moves it over the head, a visitor arriving moves
    // its host's to the other side, and the words are painted again for it.
    let talkers = Set(store.sessions.map(\.id)), sitter = layout.pets.first { $0.zone == .desk }
    func wordsKey(_ room: OfficeLayout, _ id: String) -> String? {
        room.pets.first { $0.id == id }.flatMap { place in
            store.sessions.first { $0.id == id }.map { OfficeView.wordsKey(store, $0, place, room, now: Date(), scale: 1134 / 1194) }
        }
    }
    let short = OfficePainter.layout(store, now: Date(), height: 764, scale: 1134 / 1194)
    let tall = OfficePainter.layout(store, now: Date(), height: 979, scale: 1134 / 1194)
    let host = sitter?.id ?? "", guest = layout.pets.first { $0.zone == .desk && $0.id != host }?.id ?? ""
    var rounds = OfficeRounds()
    rounds.talk(guest, host, opened: Date() - 5, last: Date() - 5)
    var looked = OfficeVisits()
    looked.looked = true
    let plan = OfficeVisits.next(short, peers: rounds.peers, rounds: rounds.rounds, previous: looked, now: Date())
    check(
        "office: the words are painted again when the mark moves: over the head in a taller room, to the side away from a visitor",
        sitter != nil && plan.hosts[guest] == host
            && wordsKey(short.visited(by: OfficeVisits(), talking: talkers), host) != wordsKey(tall.visited(by: OfficeVisits(), talking: talkers), host)
            && wordsKey(short.visited(by: OfficeVisits(), talking: talkers), host) != wordsKey(short.visited(by: plan, talking: talkers), host))
    // Switched in the menu: the live view repaints its room, every pet's words and the wall beside the picture.
    let live = OfficeView(frame: CGRect(x: 0, y: 0, width: 1600, height: 764))
    UserDefaults.standard.removeObject(forKey: "officeTheme")
    live.update(store)
    let before = (room: officeRoomLayer(live)?.contents as AnyObject?, words: officePart(live, "n0", "words")?.contents as AnyObject?,
        wall: officeWallColour(live))
    setOfficeTheme("暖夜")
    live.update(store)
    let after = (room: officeRoomLayer(live)?.contents as AnyObject?, words: officePart(live, "n0", "words")?.contents as AnyObject?,
        wall: officeWallColour(live))
    UserDefaults.standard.removeObject(forKey: "officeTheme")
    check(
        "office: a theme chosen in the menu repaints the live room, the pets' words and the wall beside it",
        before.room != nil && before.words != nil && after.room !== before.room && after.words !== before.words
            && before.wall != after.wall && after.wall == OfficeCanvas.rgb(OfficeTheme.night.palette.wall))
    // The live view beside the picture carries the theme's wall and floor too.
    OfficeTheme.shown = OfficeTheme.night
    let view = OfficeView(frame: CGRect(x: 0, y: 0, width: 1600, height: 764))
    view.update(officeStore())
    let shown = view.image().map(Pixels.init)
    OfficeTheme.shown = nil
    check(
        "office: in a wide window the warm-night wall and floor carry on beside the picture",
        shown.map { same($0.at(2, 30), 0x242140) && same($0.at(2, 400), 0x2C2849) } ?? false)
}

/// Move to Desk and Move to Rest Area: where each puts a session, how long that holds, that it is kept, and that in the office the
/// session walks there.
@MainActor func officeRestDeskTests() {
    let now = Date()
    let store = Store()
    store.readOnly = true
    let news = officeSession("k-news", "idle", finished: 30), atDesk = officeSession("k-desk", "idle", finished: 600)
    let pinned = officeSession("k-pin", "idle", finished: 1200), old = officeSession("k-old", "idle", finished: 7 * 3600)
    store.sessions = [news, atDesk, pinned, old]
    for s in [atDesk, pinned, old] { store.seen[s.id] = now.timeIntervalSince1970 }
    store.pinned = [pinned.id]
    store.parked = [:]
    func zone(_ store: Store, _ id: String, at time: Date = Date()) -> OfficeLayout.Zone? {
        OfficePainter.layout(store, now: time).pets.first { $0.id == id }?.zone
    }
    func group(_ store: Store, _ id: String, at time: Date = Date()) -> String {
        let b = Buckets(store, now: time)
        return b.unread.contains { $0.id == id } ? "unread" : b.seen.contains { $0.id == id } ? "seen"
            : b.resting.contains { $0.id == id } ? "resting" : "elsewhere"
    }
    let before = [news, atDesk, pinned, old].map { zone(store, $0.id) }

    store.rest(news)
    check(
        "rest/desk: one with news sent to rest leaves the sofa for the rest area, though it finished half a minute ago",
        before[0] == .sofa && group(store, news.id) == "resting" && zone(store, news.id) == .lounge && !store.isUnread(news))
    store.rest(atDesk)
    check(
        "rest/desk: one at a desk sent to rest goes to the rest area, not onto a sofa",
        before[1] == .desk && group(store, atDesk.id) == "resting" && zone(store, atDesk.id) == .lounge)
    store.rest(pinned)
    check(
        "rest/desk: a pinned one sent to rest loses its pin and rests",
        before[2] == .sofa && !store.pinned.contains(pinned.id) && group(store, pinned.id) == "resting"
            && zone(store, pinned.id) == .lounge)
    check(
        "rest/desk: on the board those sent to rest sleep like the old ones at the back",
        [news, atDesk, pinned].allSatisfy { store.pose(of: $0, now: Date()) == .sleeping })

    store.desk(old)
    check(
        "rest/desk: one finished seven hours ago sent to a desk sits at a desk, standing",
        before[3] == .lounge && group(store, old.id) == "seen" && zone(store, old.id) == .desk
            && store.pose(of: old, now: Date()) == .standing)
    check(
        "rest/desk: ...for six hours; after that it rests again, as it would six hours after a finish",
        group(store, old.id, at: now + recentIdle - 60) == "seen" && group(store, old.id, at: now + recentIdle + 60) == "resting")

    // The pin wins while it is on; the parking is still there when it comes off.
    store.togglePin(atDesk)
    let pinnedBack = group(store, atDesk.id) == "unread" && zone(store, atDesk.id) == .sofa
    store.togglePin(atDesk)
    check(
        "rest/desk: one sent to rest and then pinned sits on a sofa; unpinned, it goes back to rest",
        pinnedBack && group(store, atDesk.id) == "resting")

    // Sent to rest an hour ago; it has worked since and finished a minute ago.
    let later = Store()
    later.readOnly = true
    let again = officeSession("k-again", "idle", finished: 60)
    later.sessions = [again]
    later.seen[again.id] = now.timeIntervalSince1970 - 3600
    later.parked = [again.id: Store.Parking(zone: .rest, at: now.timeIntervalSince1970 - 3600)]
    let newsAgain = later.isUnread(again) && group(later, again.id) == "unread" && zone(later, again.id) == .sofa
    later.markSeen(again)
    check(
        "rest/desk: one sent to rest that finishes a newer turn has news again, on a sofa; looked at, it sits at a desk: "
            + "the old parking no longer counts", newsAgain && group(later, again.id) == "seen" && !later.isResting(again, now: Date()))

    // Kept like the pins: across a restart, for open sessions only, and never by a read-only store.
    let kept = Store()
    let k = officeSession("k-kept-rest", "idle", finished: 600), d = officeSession("k-kept-desk", "idle", finished: 7 * 3600)
    kept.sessions = [k, d]
    kept.rest(k)
    kept.desk(d)
    let reloaded = Store()
    check(
        "rest/desk: where each was sent is remembered across a restart",
        reloaded.parked[k.id]?.zone == .rest && reloaded.parked[d.id]?.zone == .desk && reloaded.parked == kept.parked)
    kept.sessions = [k]
    kept.rest(k)
    check(
        "rest/desk: a session that has gone is forgotten the next time it is saved", Store().parked[d.id] == nil && Store().parked[k.id] != nil)
    let viewer = Store()
    viewer.readOnly = true
    let v = officeSession("k-viewer", "idle", finished: 600)
    viewer.sessions = [v]
    viewer.rest(v)
    check(
        "rest/desk: sent to rest by a read-only store (a snapshot), nothing is saved", viewer.parked[v.id] != nil && Store().parked[v.id] == nil)
    UserDefaults.standard.removeObject(forKey: "parked")

    // In the office being sent somewhere is its own doing: it walks there. Six hours passing is not: it fades.
    let room = Store()
    room.readOnly = true
    room.sessions = officeSessions([("s", "idle", 3, 900), ("r", "idle", 2, 9 * 3600.0), ("o", "idle", 1, 7 * 3600.0)])
    for s in room.sessions { room.seen[s.id] = Date().timeIntervalSince1970 }
    func moving(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { $0.animation(forKey: "walk") != nil }.compactMap(\.name).sorted()
    }
    func changing(_ view: NSView) -> [String] {
        (officeStage(view)?.sublayers ?? []).filter { layer in
            ["walk", "swap", "door"].contains { layer.animation(forKey: $0) != nil }
        }.compactMap(\.name).sorted()
    }
    let walks = "rest/desk: in the office, one sent to rest walks from its desk to the back, one sent to a desk walks there; nobody else moves"
    guard officeDealCutPets(room) else {
        skipped("no pet frames", walks)
        return skipped("no pet frames", "rest/desk: ...and when the desk's six hours are up, it fades back to the rest area")
    }
    var walked = false, fadedWithTime = false
    do {
        NSApplication.shared.setActivationPolicy(.accessory)
        let view = OfficeTestView(frame: CGRect(x: 0, y: 0, width: 1134, height: 930))
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: view.frame.size), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.contentView = nil }
        view.update(room)
        let fromDesk = zone(room, "s1") == .desk, fromBack = zone(room, "o0") == .lounge
        room.rest(room.sessions.first { $0.id == "s1" }!)
        room.desk(room.sessions.first { $0.id == "o0" }!)
        view.update(room)
        CATransaction.flush()
        walked = fromDesk && fromBack && moving(view) == ["o0", "s1"] && changing(view) == ["o0", "s1"]
            && zone(room, "s1") == .lounge && zone(room, "o0") == .desk
        RunLoop.current.run(until: Date().addingTimeInterval(4))  // let the walks end
        view.shift = recentIdle + 60
        view.update(room)
        CATransaction.flush()
        fadedWithTime =
            zone(room, "o0", at: Date() + recentIdle + 60) == .lounge && changing(view).contains("o0") && !moving(view).contains("o0")
    }
    check(walks, walked)
    check("rest/desk: ...and when the desk's six hours are up, it fades back to the rest area: time alone is not its doing", fadedWithTime)
}

// ───────── A light on the session the user types in ─────────

/// A pane as Orca's `terminal.list` lists it inside a tab.
func officeFocusPane(_ tab: String, _ leaf: String, _ handle: String, _ title: String) -> [String: Any] {
    ["type": "terminal", "handle": handle, "tabId": tab, "leafId": leaf, "title": title, "connected": true, "active": true]
}

/// A worktree's layout as `terminal.list` gives it with `includeVisualLayouts`: one group of tabs, `active` the one shown.
func officeFocusWorktree(_ path: String, active: String, _ tabs: [(id: String, title: String, leaf: String, panes: Any)]) -> [String: Any] {
    [
        "worktreeId": "w::" + path, "worktreePath": path,
        "root": [
            "type": "group", "groupId": "g::" + path, "activeTabId": active,
            "tabs": tabs.map { ["tabId": $0.id, "title": $0.title, "activeLeafId": $0.leaf, "panes": $0.panes] as [String: Any] },
        ] as [String: Any],
    ]
}

/// A worktree split into two groups of tabs side by side, as `terminal.list` gives it: "left" in one, "right" in the other.
func officeFocusSplit(_ path: String) -> [String: Any] {
    func group(_ id: String, _ tab: String, _ title: String) -> [String: Any] {
        [
            "type": "group", "groupId": id, "activeTabId": tab,
            "tabs": [["tabId": tab, "title": title, "activeLeafId": "l-" + tab, "panes": officeFocusPane(tab, "l-" + tab, "h-" + tab, title)]],
        ]
    }
    return [
        "worktreeId": "w::" + path, "worktreePath": path,
        "root": ["type": "split", "direction": "horizontal", "first": group("g1", "s1", "左边"), "second": group("g2", "s2", "右边")] as [String: Any],
    ]
}

/// What `terminal.list` answers, cut down to what the light reads, made up. Worktree alpha: two tabs both called "claude",
/// the second the one shown, and a third; beta: one tab split in two, its second pane the active one; gamma: one tab, "Sky".
func officeFocusListing(extra: [[String: Any]] = []) -> [String: Any] {
    let p = officeFocusPane
    let layouts = [
        officeFocusWorktree(
            "/u/p/alpha", active: "t2",
            [("t1", "claude", "l1", p("t1", "l1", "h1", "✳ claude")), ("t2", "claude", "l2", p("t2", "l2", "h2", "✳ claude")),
             ("t3", "风筝脚本", "l3", p("t3", "l3", "h3", "风筝脚本"))]),
        officeFocusWorktree(
            "/u/p/beta", active: "t4",
            [("t4", "彗星表巡游", "l4b", ["type": "split", "children": [p("t4", "l4a", "h4a", "zsh"), p("t4", "l4b", "h4b", "⠂ 彗星表巡游")]] as [String: Any])]),
        officeFocusWorktree("/u/p/gamma", active: "t5", [("t5", "Sky", "l5", p("t5", "l5", "h5", "✳ Sky"))]),
    ] + extra
    return ["terminals": [], "visualLayouts": layouts, "totalCount": 6, "truncated": false]
}

/// A worktree in a folder called Mac: Cloudhouse (handle term_office) and a tab with a long Chinese title (the fixture below)
/// (term_read), `active` the tab Orca's list calls active.
func officeFocusMac(active: String) -> [String: Any] {
    officeFocusWorktree(
        "/Users/x/projects/Mac", active: active,
        [("o1", "Cloudhouse", "ol1", officeFocusPane("o1", "ol1", "term_office", "◐ Cloudhouse")),
         ("o2", "整理星星图片目录说明", "ol2", officeFocusPane("o2", "ol2", "term_read", "⠹ 整理星星图片目录说明 | panel"))])
}

/// A made-up element of Orca's window for the bar's finder and reader: what it is, what it says, what it holds; `gone` once
/// Orca has let it go, `failed` while it does not answer. Each read is counted.
final class OfficeFakeElement {
    let role: String, title: String
    var children: [OfficeFakeElement]
    var gone = false, failed = false
    var reads = 0

    init(_ role: String, _ title: String = "", _ children: [OfficeFakeElement] = []) {
        self.role = role
        self.title = title
        self.children = children
    }

    /// `levels` groups one inside the other round `inner`, as Orca's page nests its divs.
    static func nested(_ levels: Int, _ inner: [OfficeFakeElement]) -> OfficeFakeElement {
        var outer = OfficeFakeElement("AXGroup", "", inner)
        for _ in 1..<levels { outer = OfficeFakeElement("AXGroup", "", [outer]) }
        return outer
    }

    static func read(_ e: OfficeFakeElement) -> OfficeFocus.Element<OfficeFakeElement> {
        e.reads += 1
        var read = OfficeFocus.Element<OfficeFakeElement>()
        guard !e.gone, !e.failed else {
            read.gone = e.gone
            read.failed = e.failed
            return read
        }
        read.role = e.role
        read.title = e.title
        read.children = e.children
        return read
    }

    /// How many reads this element and all it holds have had.
    var readsBelow: Int { reads + children.map(\.readsBelow).reduce(0, +) }
}

/// A tab's button as Orca's page has it: named by its status, its title and its close button's label, and holding the
/// title's text and the close button.
func officeFakeTab(_ title: String) -> OfficeFakeElement {
    OfficeFakeElement(
        "AXButton", "Working \(title) 关闭选项卡 \(title)", [OfficeFakeElement("AXGroup", "", [OfficeFakeElement("AXStaticText")]), OfficeFakeElement("AXButton")])
}

/// Orca's window as the probe saw it, cut down: the sidebar's list of worktrees, the tab bar 15 levels down with
/// the active tab docked in a group of its own, a terminal, and two buttons that are not tabs. `bars` side by side, each with
/// these tabs.
func officeFakeWindow(_ tabs: [(title: String, docked: Bool)], bars count: Int = 1) -> (window: OfficeFakeElement, bars: [OfficeFakeElement]) {
    let bars = (0..<count).map { _ in
        OfficeFakeElement("AXGroup", "", tabs.map { $0.docked ? OfficeFakeElement("AXGroup", "", [officeFakeTab($0.title)]) : officeFakeTab($0.title) })
    }
    let sidebar = OfficeFakeElement.nested(
        4, [OfficeFakeElement("AXList", "", [OfficeFakeElement("AXMenuItem", "", [OfficeFakeElement.nested(3, [OfficeFakeElement("AXStaticText")])])])])
    let terminal = OfficeFakeElement.nested(13, [OfficeFakeElement("AXTextField")])
    let others = OfficeFakeElement.nested(9, [OfficeFakeElement("AXButton", "panel"), OfficeFakeElement("AXButton", "海景主题")])
    let page = OfficeFakeElement("AXWebArea", "Orca", [sidebar] + bars.map { OfficeFakeElement.nested(7, [$0]) } + [terminal, others])
    return (OfficeFakeElement("AXWindow", "Orca", [OfficeFakeElement.nested(6, [page])]), bars)
}

/// Orca's tab bar found, read and matched to the worktrees Orca lays out, and the store's reader of it, with hooks for all
/// it asks the system: which app is in front, whether the panel may read it, Orca's page opened and watched, the bar looked
/// for and read, Orca's list, a session's terminal.
@MainActor func officeFocusTests() {
    // ── A tab's button, by its title.
    let parse = OfficeFocus.tabTitle
    check(
        "office: a button of Orca's tab bar is a tab by its title, with Orca's status word in front or without, a Chinese title with spaces too",
        parse("Working Sky 关闭选项卡 Sky") == "Sky" && parse("Sky 关闭选项卡 Sky") == "Sky"
            && parse("Working Demo 相机快门和 ISO 配置 关闭选项卡 Demo 相机快门和 ISO 配置") == "Demo 相机快门和 ISO 配置"
            && parse("整理星星图片目录说明 关闭选项卡 整理星星图片目录说明") == "整理星星图片目录说明")
    check(
        "office: ...a status of more than one word, the collapse-pane label before the close button, Orca in English, a title like a status: all read",
        parse("未读的代理完成 Owl 关闭选项卡 Owl") == "Owl" && parse("Needs input Sky 关闭选项卡 Sky") == "Sky"
            && parse("Working Sky 折叠窗格 关闭选项卡 Sky") == "Sky" && parse("Working Sky Close tab Sky") == "Sky"
            && parse("Working Working 关闭选项卡 Working") == "Working")
    check(
        "office: ...a button that is not a tab is not one: another button, a file's tab, a close button, two titles that differ",
        parse("panel") == nil && parse("") == nil && parse("Package.swift 关闭选项卡") == nil && parse("关闭选项卡 Sky") == nil
            && parse("Working Sky 关闭选项卡 Sea") == nil)

    // ── The bar, found and read in a made-up window like Orca's.
    let same: (OfficeFakeElement, OfficeFakeElement) -> Bool = { $0 === $1 }
    let orca = officeFakeWindow([("Cloudhouse", true), ("整理星星图片目录说明", false)])
    let found = OfficeFocus.bars(under: orca.window, read: OfficeFakeElement.read, same: same)
    let parts = orca.bars[0].children.flatMap { $0.role == "AXButton" ? $0.children : $0.children.flatMap(\.children) }
    check(
        "office: Orca's tab bar is found: the element its tabs sit in, the active one docked a level down as Orca has it; a tab's parts are not looked into",
        found.bars.count == 1 && found.bars.first === orca.bars[0] && parts.count == 4 && parts.allSatisfy { $0.readsBelow == 0 })
    let readSoFar = orca.window.readsBelow
    let read = OfficeFocus.tabs(in: found.bars, read: OfficeFakeElement.read)
    check(
        "office: ...read, it gives its tabs in order, the docked one a level deeper, in one read per tab and two more",
        read == .tabs([.init(title: "Cloudhouse", depth: 2), .init(title: "整理星星图片目录说明", depth: 1)]) && orca.window.readsBelow - readSoFar == 4)
    let alone = officeFakeWindow([("Sky", true)]), split = officeFakeWindow([("左边", true), ("右边", false)], bars: 2)
    let one = OfficeFocus.bars(under: alone.window, read: OfficeFakeElement.read, same: same)
    let two = OfficeFocus.bars(under: split.window, read: OfficeFakeElement.read, same: same)
    check(
        "office: ...with one tab only, docked, the bar is still the element above the dock; two groups of tabs side by side are two bars",
        one.bars.count == 1 && one.bars.first === alone.bars[0] && OfficeFocus.tabs(in: one.bars, read: OfficeFakeElement.read) == .tabs([.init(title: "Sky", depth: 2)])
            && two.bars.count == 2 && two.bars[0] === split.bars[0] && two.bars[1] === split.bars[1])
    func low() -> OfficeFakeElement { OfficeFakeElement("AXGroup", "", [officeFakeTab("Sky"), OfficeFakeElement("AXGroup", "", [officeFakeTab("Owl")])]) }
    func window(_ inside: [OfficeFakeElement]) -> OfficeFakeElement { OfficeFakeElement("AXWindow", "Orca", inside) }
    let reach = OfficeFocus.bars(under: window([OfficeFakeElement.nested(23, [low()])]), read: OfficeFakeElement.read, same: same)
    let beyond = OfficeFocus.bars(under: window([OfficeFakeElement.nested(24, [low()])]), read: OfficeFakeElement.read, same: same)
    let crowd = window([OfficeFakeElement("AXGroup", "", (0..<4100).map { _ in OfficeFakeElement("AXStaticText") }), OfficeFakeElement.nested(1, [low()])])
    let stopped = OfficeFocus.bars(under: crowd, read: OfficeFakeElement.read, same: same)
    let further = OfficeFocus.bars(under: crowd, most: 5000, read: OfficeFakeElement.read, same: same)
    check(
        "office: ...the look goes 25 levels down and no further, and stops after 4000 elements",
        reach.bars.count == 1 && beyond.bars.isEmpty && stopped.bars.isEmpty && stopped.looked == 4000 && further.bars.count == 1)
    let lost = officeFakeWindow([("Sky", true), ("Owl", false)]).bars[0], quiet = officeFakeWindow([("Sky", true)]).bars[0]
    lost.gone = true
    quiet.failed = true
    let bare = window([OfficeFakeElement.nested(5, [OfficeFakeElement("AXButton", "panel"), OfficeFakeElement("AXButton", "Package.swift 关闭选项卡")])])
    check(
        "office: ...a bar Orca has let go reads as gone, one that does not answer as failed; a window with no tabs has no bar",
        OfficeFocus.tabs(in: [lost], read: OfficeFakeElement.read) == .gone && OfficeFocus.tabs(in: [quiet], read: OfficeFakeElement.read) == .failed
            && OfficeFocus.bars(under: bare, read: OfficeFakeElement.read, same: same).bars.isEmpty)

    // ── The bar's tabs, matched to the worktrees Orca lays out.
    func tabs(_ titles: String...) -> [OfficeFocus.BarTab] { titles.map { OfficeFocus.BarTab(title: $0, depth: 1) } }
    let worktrees = OfficeFocus.worktrees(officeFocusListing())
    func hit(_ bar: [OfficeFocus.BarTab], _ among: [OfficeFocus.Worktree] = worktrees) -> String? { OfficeFocus.match(bar, among).terminal?.handle }
    let shown = OfficeFocus.shown(officeFocusListing())
    check(
        "office: the light's candidates are the pane shown in each worktree, the active leaf of its active tab, in a split too",
        shown.map(\.handle) == ["h2", "h4b", "h5"] && shown.map(\.pane) == ["t2:l2", "t4:l4b", "t5:l5"]
            && shown.map(\.worktree) == ["alpha", "beta", "gamma"] && shown.map(\.tab) == ["claude", "彗星表巡游", "Sky"])
    check(
        "office: Orca's worktrees are read with their tabs' titles in order, one group of tabs each",
        worktrees.map(\.name) == ["alpha", "beta", "gamma"] && worktrees.map { $0.groups.map(\.titles) } == [[["claude", "claude", "风筝脚本"]], [["彗星表巡游"]], [["Sky"]]])
    check(
        "office: the bar's tabs are the worktree with just those tabs, as many of each: the active leaf of its active tab, in a split too",
        hit(tabs("claude", "claude", "风筝脚本")) == "h2" && hit(tabs("彗星表巡游")) == "h4b" && hit(tabs("Sky")) == "h5")
    check(
        "office: ...in any order, and a terminal's ✳ or spinner in front of a title makes no difference",
        hit(tabs("风筝脚本", "claude", "claude")) == "h2" && hit(tabs("✳ Sky")) == "h5" && hit(tabs("⠂ 彗星表巡游")) == "h4b")
    let twin = OfficeFocus.worktrees(
        officeFocusListing(extra: [officeFocusWorktree("/u/p/delta", active: "t6", [("t6", "Sky", "l6", officeFocusPane("t6", "l6", "h6", "Sky"))])]))
    check("office: two worktrees with just those tabs are no match, and the light stays where it was", OfficeFocus.match(tabs("Sky"), twin) == .several(2))
    check(
        "office: no worktree with just those tabs: the one that has them all and more, if only one has (a pinned tab is not read)",
        hit(tabs("风筝脚本")) == "h2" && hit(tabs("claude")) == "h2" && hit(tabs("claude", "风筝脚本")) == "h2")
    let echo = OfficeFocus.worktrees(
        officeFocusListing(extra: [officeFocusWorktree("/u/p/echo", active: "t7", [("t7", "claude", "l7", officeFocusPane("t7", "l7", "h7", "claude"))])]))
    check("office: ...a worktree with just those tabs comes before one with more", hit(tabs("claude"), echo) == "h7")
    check(
        "office: tabs no worktree has, or none at all, are no match",
        OfficeFocus.match(tabs("设置"), worktrees) == .none && OfficeFocus.match([], worktrees) == .none && OfficeFocus.match(tabs("✳"), worktrees) == .none)
    let halves = OfficeFocus.worktrees(officeFocusListing(extra: [officeFocusSplit("/u/p/split")]))
    check(
        "office: a worktree split into two groups of tabs is no match: the bar does not say which group he types in",
        halves.last?.groups.count == 2 && Set(halves.last?.groups.flatMap(\.titles) ?? []) == ["左边", "右边"]
            && OfficeFocus.match(tabs("左边", "右边"), halves) == .split(2))
    // Orca as it was probed: two worktrees in folders called Mac, one with the tab MAC, one with Cloudhouse and
    // The long Chinese title.
    let mac = OfficeFocus.worktrees([
        "visualLayouts": [
            officeFocusWorktree("/Users/x/projects/Mac", active: "m1", [("m1", "MAC", "ml1", officeFocusPane("m1", "ml1", "term_mac", "✳ MAC"))]),
            officeFocusWorktree(
                "/Users/x/projects/Mac", active: "o1",
                [("o1", "Cloudhouse", "ol1", officeFocusPane("o1", "ol1", "term_office", "◐ Cloudhouse")),
                 ("o2", "整理星星图片目录说明", "ol2", officeFocusPane("o2", "ol2", "term_read", "⠹ 整理星星图片目录说明 | panel"))]),
        ]
    ])
    var fromWindow: String?
    if case .tabs(let seen) = read { fromWindow = hit(seen, mac) }
    check(
        "office: two worktrees in folders of the same name are told apart by their tabs; the window's bar, read, leads to the terminal he sees",
        hit(tabs("Cloudhouse", "整理星星图片目录说明"), mac) == "term_office" && hit(tabs("MAC"), mac) == "term_mac" && fromWindow == "term_office")

    // ── Which tab the bar shows as active (Orca's list can lag a switch, or be wrong).
    // Orca's own classes for its active tab and the others (SortableTab).
    let lit = ["group", "relative", "flex", "border-t", "border-r", "border-border", "bg-[color-mix(in_srgb,var(--foreground)_6%,var(--card))]", "text-foreground"]
    let unlit = ["group", "relative", "flex", "border-t", "border-border", "bg-card", "text-muted-foreground", "hover:text-foreground"]
    typealias Shown = OfficeFocus.BarTab
    check(
        "office: the bar tells the active tab by its one selected button, else by the one docked a level down, else by a class that marks it",
        OfficeFocus.active(in: [Shown(title: "a", depth: 1), Shown(title: "b", depth: 1, selected: true)]) == "b"
            && OfficeFocus.active(in: [Shown(title: "a", depth: 1, classes: lit), Shown(title: "b", depth: 1, classes: unlit)]) == "a"
            && OfficeFocus.active(in: [Shown(title: "a", depth: 1, classes: ["tab", "is-active"]), Shown(title: "b", depth: 1, classes: ["tab"])]) == "a"
            && OfficeFocus.active(in: [Shown(title: "a", depth: 1), Shown(title: "b", depth: 2), Shown(title: "c", depth: 1)]) == "b"
            && OfficeFocus.active(in: [Shown(title: "solo", depth: 2, classes: lit)]) == "solo")
    check(
        "office: ...and tells none when nothing marks one tab only: all alike, a class every tab has, two docked (two groups), a tab alone unmarked",
        OfficeFocus.active(in: tabs("a", "b")) == nil && OfficeFocus.active(in: [Shown(title: "solo", depth: 2)]) == nil
            && OfficeFocus.active(in: [Shown(title: "a", depth: 1, classes: ["tab", "is-inactive"]), Shown(title: "b", depth: 1, classes: ["tab"])]) == nil
            && OfficeFocus.active(in: [Shown(title: "a", depth: 1, classes: ["data-[active=true]:bg-card"]), Shown(title: "b", depth: 1, classes: ["data-[active=true]:bg-card"])]) == nil
            && OfficeFocus.active(in: [Shown(title: "a", depth: 2), Shown(title: "b", depth: 2), Shown(title: "c", depth: 1), Shown(title: "d", depth: 1)]) == nil)
    let stale = OfficeFocus.worktrees(["visualLayouts": [officeFocusMac(active: "o2")]])
    let docked = OfficeFocus.pick([Shown(title: "Cloudhouse", depth: 2), Shown(title: "整理星星图片目录说明", depth: 1)], stale)
    let undocked = OfficeFocus.pick(tabs("Cloudhouse", "整理星星图片目录说明"), stale)
    check(
        "office: the tab the bar shows as active wins over Orca's list; when the bar does not tell, the list's answer is marked as needing a fresh list",
        docked.match.terminal?.handle == "term_office" && !docked.byList && undocked.match.terminal?.handle == "term_read" && undocked.byList
            && OfficeFocus.pick(tabs("Sky"), worktrees).byList == false)
    let twins = OfficeFocus.worktrees([
        "visualLayouts": [
            officeFocusWorktree("/u/p/one", active: "a2", [("a1", "Alpha", "x1", officeFocusPane("a1", "x1", "h-1-Alpha", "Alpha")), ("a2", "Bravo", "x2", officeFocusPane("a2", "x2", "h-1-Bravo", "Bravo"))]),
            officeFocusWorktree("/u/p/two", active: "b1", [("b1", "Alpha", "y1", officeFocusPane("b1", "y1", "h-2-Alpha", "Alpha")), ("b2", "Bravo", "y2", officeFocusPane("b2", "y2", "h-2-Bravo", "Bravo"))]),
        ]
    ])
    check(
        "office: of two worktrees with the same tabs, the one whose active tab by Orca's list is the one the bar shows as active",
        OfficeFocus.match([Shown(title: "Alpha", depth: 2), Shown(title: "Bravo", depth: 1)], twins).terminal?.handle == "h-2-Alpha"
            && OfficeFocus.match([Shown(title: "Alpha", depth: 1), Shown(title: "Bravo", depth: 2)], twins).terminal?.handle == "h-1-Bravo"
            && OfficeFocus.match(tabs("Alpha", "Bravo"), twins) == .several(2))

    // ── The store's reader, everything it asks of the system replaced.
    let t0 = Date()
    let store = Store()
    store.readOnly = true
    func person(_ id: String, _ pid: Int32, _ name: String) -> Session {
        Session(id: id, pid: pid, project: "项目", name: name, status: "idle", since: t0 - 600, summary: "")
    }
    store.sessions = [person("f-a", 101, "Alpha"), person("f-b", 102, "Bravo"), person("f-c", 103, "Charlie")]
    var front: (bundle: String, pid: pid_t)? = ("com.apple.finder", 7)
    var allowed = true, finds = true, slow = 0.0
    var bar = OfficeFocus.Bar.tabs(tabs("claude", "claude", "风筝脚本")), answers: [OfficeFocus.Bar] = []
    var opened: [String] = [], watched: [pid_t] = [], looks = 0, reads = 0, lists = 0, lines: [String] = []
    // Stands for the bar in Orca's page: never asked anything, the hooks answer for it.
    let element = AXUIElementCreateApplication(getpid())
    let focus = store.focus
    focus.queue = nil
    focus.frontmost = { front }
    focus.trusted = { allowed }
    focus.enhance = { pid, on in
        opened.append("\(pid) \(on ? "on" : "off")")
        return "made up"
    }
    focus.watch = { pid, _ in
        watched.append(pid)
        return (nil, "made up")
    }
    focus.findBar = { _ in
        looks += 1
        return (finds ? [element] : [], 600)
    }
    focus.readBar = { _ in
        reads += 1
        if slow > 0 { Thread.sleep(forTimeInterval: slow) }
        return answers.isEmpty ? bar : answers.removeFirst()
    }
    focus.list = {
        lists += 1
        return officeFocusListing()
    }
    // f-a was started in h2; f-b in beta's second pane, under a handle that has since gone stale; f-c outside Orca.
    focus.tab = { pid in pid == 101 ? ("h2", "t2:l2") : pid == 102 ? ("h-old", "t4:l4b") : nil }
    focus.note = { lines.append($0) }
    func asked() -> Int { opened.count + watched.count + looks + reads + lists }

    store.readFocus(at: t0)
    check("office: with another app in front, Orca is asked nothing and nothing is lit", asked() == 0 && store.focused == nil && !store.orcaInFront)
    front = (OfficeFocus.orca, 42)
    store.readFocus(at: t0 + 1)
    check(
        "office: with Orca in front, its page is opened to readers and watched, its tab bar found and read: the session in the terminal it shows is lit",
        opened == ["42 on"] && watched == [42] && looks == 1 && reads == 1 && lists == 1 && store.focused == "f-a" && store.orcaInFront)
    check("office: ...the log says the bar was found, with how many tabs, once", lines.filter { $0.hasPrefix("focus: tab bar found (3 tabs)") }.count == 1)
    store.readFocus(at: t0 + 3)
    check(
        "office: ...on the next look the bar is only read: not looked for again, Orca's page not opened again",
        opened.count == 1 && watched.count == 1 && looks == 1 && reads == 2 && store.focused == "f-a")
    answers = [.gone]
    bar = .tabs(tabs("彗星表巡游"))
    store.readFocus(at: t0 + 5)
    check(
        "office: a bar Orca has let go (another worktree shown) is looked for again at once; a session whose handle went stale is found by its pane",
        looks == 2 && reads == 4 && opened.count == 1 && store.focused == "f-b")
    answers = [.gone]
    finds = false
    store.readFocus(at: t0 + 7)
    let missed = looks
    store.readFocus(at: t0 + 9)
    store.readFocus(at: t0 + 15)
    let waited = looks
    finds = true
    store.readFocus(at: t0 + 17)
    check(
        "office: a look that finds no bar is not made again for 10 s, Orca's page is opened to readers again meanwhile, and the light stays",
        missed == 3 && waited == 3 && looks == 4 && opened == ["42 on", "42 on"] && store.focused == "f-b"
            && lines.filter { $0.hasPrefix("focus: no tab bar in Orca's window") }.count == 1)
    bar = .tabs(tabs("设置"))
    store.readFocus(at: t0 + 19)
    store.readFocus(at: t0 + 21)
    check(
        "office: tabs that match nothing leave the light where it was, and are logged once",
        store.focused == "f-b" && lines.filter { $0 == "focus: no match for tabs [\"设置\"]" }.count == 1)
    let listsThen = lists
    store.readFocus(at: t0 + 23)
    let steady = lists - listsThen
    store.readFocus(at: t0 + 31.5)
    let aged = lists - listsThen
    bar = .tabs(tabs("彗星表巡游"))
    store.readFocus(at: t0 + 32)
    let changed = lists - listsThen
    store.readFocus(at: t0 + 33.5)
    let settled = lists - listsThen
    store.readFocus(at: t0 + 35)
    let still = lists - listsThen
    // The same tab, docked now: the bar's shape changed, as a switch of tabs changes it.
    bar = .tabs([.init(title: "彗星表巡游", depth: 2)])
    store.readFocus(at: t0 + 36)
    check(
        "office: Orca's layouts are asked for when the bar changes (its shape too) and once more a second later; else once they are 10 s old",
        steady == 0 && aged == 1 && changed == 2 && settled == 3 && still == 3 && lists - listsThen == 4 && store.focused == "f-b")
    front = ("com.apple.Terminal", 9)
    var soFar = asked()
    store.readFocus(at: t0 + 37)
    check(
        "office: with Orca gone to the background it is asked nothing, and the light stays where it was",
        asked() == soFar && store.focused == "f-b" && !store.orcaInFront)
    front = (OfficeFocus.orca, 42)
    bar = .tabs(tabs("Sky"))
    let litBefore = store.focused
    store.readFocus(at: t0 + 38)
    check("office: tabs that show a terminal no open session runs in (a shell, say) put the light out", litBefore == "f-b" && store.focused == nil)
    bar = .tabs(tabs("claude", "claude", "风筝脚本"))
    store.readFocus(at: t0 + 39)
    var published = 0
    let watch = store.objectWillChange.sink { _ in published += 1 }
    store.readFocus(at: t0 + 40)
    store.readFocus(at: t0 + 41)
    let quiet2 = published
    front = ("com.apple.finder", 7)
    store.readFocus(at: t0 + 42)
    let dimmed = published
    front = (OfficeFocus.orca, 42)
    store.readFocus(at: t0 + 43)
    watch.cancel()
    check(
        "office: the same session read again tells nobody; Orca going to the back and coming forward again repaints the light",
        store.focused == "f-a" && quiet2 == 0 && dimmed == 1 && published == 2)

    soFar = asked()
    allowed = false
    store.readFocus(at: t0 + 44)
    check("office: without the Accessibility permission nothing is lit and Orca is asked nothing", soFar > 0 && store.focused == nil && asked() == soFar)
    lines = []
    focus.launched()
    for i in 0..<5 { store.readFocus(at: t0 + 45 + Double(i)) }
    check("office: ...the log says so in one line, at launch, however many ticks go by", lines.count == 1 && lines.allSatisfy { $0.hasPrefix("focus: ") })
    allowed = true
    store.readFocus(at: t0 + 51)
    check("office: ...and in one more once it is granted, when the light comes on", lines.count == 2 && store.focused == "f-a")
    lines = []
    slow = 0.06
    store.readFocus(at: t0 + 52)
    slow = 0
    store.readFocus(at: t0 + 53)
    check(
        "office: a read of Orca's tab bar that takes over 50 ms is logged with how long it took; a quick one is not",
        lines.count == 1 && lines.first?.hasPrefix("focus: Orca's tab bar read in ") == true && lines.first?.contains(" ms") == true)
    let readsBefore = reads
    setOfficeSpotlight(false)
    store.readFocus(at: t0 + 54)
    let whileOff = reads - readsBefore
    focus.switchOff()
    let closed = opened.last
    UserDefaults.standard.removeObject(forKey: "officeSpotlight")
    store.readFocus(at: t0 + 55)
    check(
        "office: switched off in the menu bar, Orca is not read and its page is closed to readers again; switched on, it is opened again and read",
        whileOff == 0 && closed == "42 off" && opened.last == "42 on" && reads - readsBefore == 1 && officeSpotlight() && store.focused == "f-a")
    let looksBefore = looks
    front = (OfficeFocus.orca, 43)
    store.readFocus(at: t0 + 56)
    check(
        "office: a new Orca (a new process) has its page opened and watched, and its bar looked for",
        opened.last == "43 on" && watched.last == 43 && looks == looksBefore + 1 && store.focused == "f-a")
    let untouched = OfficeFocus()
    var asks = 0
    untouched.queue = nil
    untouched.enhance = { _, _ in
        asks += 1
        return ""
    }
    untouched.note = { _ in }
    untouched.switchOff(waiting: 0.3)
    check("office: quitting closes only what the light opened: with nothing opened, Orca is asked nothing", asks == 0)

    // Orca telling of a change: the look comes a moment later, once for a burst.
    var nudges = 0
    lines = []
    focus.nudge = { nudges += 1 }
    for _ in 0..<3 { focus.noticed("AXFocusedUIElementChanged") }
    let atOnce = nudges
    var until = Date().addingTimeInterval(0.6)
    while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    let burst = nudges
    focus.noticed("AXTitleChanged")
    until = Date().addingTimeInterval(0.6)
    while Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    check(
        "office: Orca telling of a change brings the look forward a moment later, once for a burst; the first of each kind is logged",
        atOnce == 0 && burst == 1 && nudges == 2 && lines.filter { $0.hasPrefix("focus: Orca tells of ") }.count == 2)

    // In the panel Orca is asked off the main thread, and the answer comes back on it.
    var onMain: [String: Bool] = [:]
    let threaded = Store()
    threaded.readOnly = true
    threaded.sessions = store.sessions
    let off = threaded.focus
    off.queue = DispatchQueue(label: "office-focus-check")
    off.frontmost = { (OfficeFocus.orca, 44) }
    off.trusted = { true }
    off.enhance = { _, on in
        onMain[on ? "open" : "close"] = Thread.isMainThread
        return "made up"
    }
    off.watch = { _, _ in (nil, "made up") }
    off.findBar = { _ in
        onMain["look"] = Thread.isMainThread
        return ([element], 600)
    }
    off.readBar = { _ in
        onMain["read"] = Thread.isMainThread
        return .tabs(tabs("彗星表巡游"))
    }
    off.list = {
        onMain["list"] = Thread.isMainThread
        return officeFocusListing()
    }
    off.tab = focus.tab
    off.note = { _ in }
    var answeredOnMain: Bool?
    let told = threaded.objectWillChange.sink { _ in answeredOnMain = Thread.isMainThread }
    threaded.readFocus(at: t0 + 60)
    let deadline = Date().addingTimeInterval(2)
    while threaded.focused != "f-b" && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    told.cancel()
    off.switchOff(waiting: 1)
    check(
        "office: in the panel Orca is opened, looked at, read and listed off the main thread, and the session is lit from the main thread",
        threaded.focused == "f-b" && onMain["open"] == false && onMain["look"] == false && onMain["read"] == false && onMain["list"] == false
            && answeredOnMain == true)
    check("office: ...quitting waits a moment for Orca's page to be closed to readers again, off the main thread too", onMain["close"] == false)

    // ── The user switches between the two tabs of the worktree shown, and back; Orca's list names the other tab all
    // along. Then a bar that does not tell, and a notice from Orca.
    let t1 = Date()
    let pair = Store()
    pair.readOnly = true
    pair.sessions = [person("f-o", 105, "Cloudhouse"), person("f-r", 106, "整理星星图片目录说明"), person("f-a", 101, "Alpha")]
    var listActive = "o2", pairLists = 0, said: [String] = []
    var shownBar = OfficeFocus.Bar.tabs([Shown(title: "Cloudhouse", depth: 2), Shown(title: "整理星星图片目录说明", depth: 1)])
    let paired = pair.focus
    paired.queue = nil
    paired.frontmost = { (OfficeFocus.orca, 42) }
    paired.trusted = { true }
    paired.enhance = { _, _ in "made up" }
    paired.watch = { _, _ in (nil, "made up") }
    paired.findBar = { _ in ([element], 600) }
    paired.readBar = { _ in shownBar }
    paired.list = {
        pairLists += 1
        return officeFocusListing(extra: [officeFocusMac(active: listActive)])
    }
    paired.tab = { pid in pid == 105 ? ("term_office", "o1:ol1") : pid == 106 ? ("term_read", "o2:ol2") : pid == 101 ? ("h2", "t2:l2") : nil }
    paired.note = { said.append($0) }
    var path: [String?] = []
    func switchTo(_ docked: String, at time: TimeInterval) {
        shownBar = .tabs([Shown(title: "Cloudhouse", depth: docked == "Cloudhouse" ? 2 : 1), Shown(title: "整理星星图片目录说明", depth: docked == "Cloudhouse" ? 1 : 2)])
        pair.readFocus(at: t1 + time)
        path.append(pair.focused)
    }
    switchTo("Cloudhouse", at: 0)
    switchTo("整理星星图片目录说明", at: 0.5)
    switchTo("整理星星图片目录说明", at: 1.5)
    switchTo("Cloudhouse", at: 2)
    switchTo("Cloudhouse", at: 3.5)
    check(
        "office: switching between two tabs of the worktree shown moves the light each time, by the tab the bar shows, though Orca's list names the other",
        path == ["f-o", "f-r", "f-r", "f-o", "f-o"] && listActive == "o2")
    let nows = said.filter { $0.hasPrefix("focus: now ") }
    check(
        "office: ...each change of the light is logged with the session, its tab and worktree, at most one line a second; a change it skipped comes next",
        nows == ["focus: now Cloudhouse (tab \"Cloudhouse\" in Mac)", "focus: now 整理星星图片目录说明 (tab \"整理星星图片目录说明\" in Mac)",
                 "focus: now Cloudhouse (tab \"Cloudhouse\" in Mac)"])
    // A bar that does not tell which tab is active: Orca's list decides, and is asked afresh on each look over a second old.
    listActive = "o1"
    shownBar = .tabs(tabs("Cloudhouse", "整理星星图片目录说明"))
    pair.readFocus(at: t1 + 10)
    pair.readFocus(at: t1 + 12)
    let before = (lists: pairLists, lit: pair.focused)
    listActive = "o2"
    pair.readFocus(at: t1 + 14)
    let afresh = (lists: pairLists, lit: pair.focused)
    pair.readFocus(at: t1 + 14.5)
    check(
        "office: when the bar does not tell which of a worktree's tabs is active, Orca's list is asked afresh on each look once over a second old",
        before.lit == "f-o" && afresh.lists == before.lists + 1 && afresh.lit == "f-r" && pairLists == afresh.lists)
    // One tab, a terminal no session runs in; then Orca tells of a change.
    shownBar = .tabs(tabs("彗星表巡游"))
    pair.readFocus(at: t1 + 20)
    pair.readFocus(at: t1 + 22)
    pair.readFocus(at: t1 + 24)
    let quietLists = pairLists
    pair.readFocus(at: t1 + 26)
    let unasked = pairLists - quietLists
    paired.noticed("AXFocusedUIElementChanged")
    pair.readFocus(at: t1 + 28)
    check(
        "office: after Orca tells of a change the next look asks for its list afresh, though under 10 s old; without a notice it is not",
        unasked == 0 && pairLists == quietLists + 1 && pair.focused == nil
            && said.contains("focus: none (tab \"彗星表巡游\" in beta runs no open session)"))
    // A bar that gives no answer (Orca busy) is said once when that starts and once when it ends.
    let quietFrom = said.count
    shownBar = .failed
    pair.readFocus(at: t1 + 30)
    pair.readFocus(at: t1 + 32)
    shownBar = .tabs(tabs("彗星表巡游"))
    pair.readFocus(at: t1 + 34)
    check(
        "office: a tab bar that gives no answer is logged once when that starts and once when it answers again, with how many looks went without",
        Array(said[quietFrom...]) == ["focus: Orca's tab bar gave no answer: the light stays where it is until it does",
                                      "focus: Orca's tab bar answers again, after 2 looks without"])

    // ── The menu bar's item.
    let denied = spotlightMenuItem(trusted: false, on: true), on = spotlightMenuItem(trusted: true, on: true)
    let paused = spotlightMenuItem(trusted: true, on: false)
    check(
        "office: the menu bar's spotlight item is ticked while the light follows Orca, unticked when switched off",
        on.title == "聚光灯：跟着 Orca 里的会话" && on.checked && paused.title == on.title && !paused.checked)
    check(
        "office: ...without the permission it is not ticked, says it needs the accessibility permission, and where that is granted",
        denied.title.hasPrefix("聚光灯：跟着 Orca 里的会话") && denied.title.contains("辅助功能") && !denied.checked && denied.help.contains("隐私与安全性"))

    // ── `--focus` for pictures.
    let domain = ProcessInfo.processInfo.processName
    let settings = UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary?
    let picture = officeStore(), running = officeStore(), nobody = officeStore()
    running.readOnly = false
    picture.orcaInFront = false
    officeFocus(running, arguments: ["--focus", "o-busy"])
    officeFocus(picture, arguments: ["--snapshot", "/tmp/x.png", "--office", "--focus", "o-busy"])
    officeFocus(nobody, arguments: ["--focus", "没有这个"])
    let drawn = officeStill(picture, size: CGSize(width: 1194, height: 764)) != nil
    check(
        "office: --focus lights that session in a picture, on a read-only store only, Orca as if in front; nothing is written",
        running.focused == nil && picture.focused == "o-busy" && picture.orcaInFront && nobody.focused == nil && drawn
            && UserDefaults.standard.persistentDomain(forName: domain) as NSDictionary? == settings)
}

/// A terminal Orca lists but lays out in no tab, shaped as `terminal.list` gave it: orphaned, untitled, its
/// tab and leaf ids "pty:<worktreeId>@@…", and the pane key it was recorded under. `worktreeId` as `officeFocusWorktree` has it.
func officeFocusOrphan(_ path: String, _ handle: String, _ paneKey: String, worktreeId: String? = nil) -> [String: Any] {
    let id = worktreeId ?? "w::" + path, pty = "pty:\(id)@@\(handle.suffix(8))"
    return [
        "handle": handle, "ptyId": "\(id)@@\(handle.suffix(8))", "orphaned": true, "recordedPaneKey": paneKey, "worktreeId": id,
        "worktreePath": path, "branch": "", "tabId": pty, "leafId": pty, "title": NSNull(), "connected": true, "writable": true,
        "preview": "", "executionHostId": "local",
    ]
}

/// Tabs Orca lays out in no layout. The bar of a worktree showed two tabs, Orca's layout only one, the
/// other's terminal orphaned; no worktree fitted and nothing was lit. Two ways orphans come: the shell a woken session left in
/// its old tab (a worktree with one orphan beside its laid-out tab), and an Orca restarted under live sessions (every tab
/// of a worktree orphaned, no layout of it at all).
@MainActor func officeFocusOrphanTests() {
    typealias Shown = OfficeFocus.BarTab
    let p = officeFocusPane
    // As demo-lighting was: the layout has the Home-Moon-<suffix> session only; Home-Moon runs in the one orphaned terminal. demo-network the same, with
    // its orphan a shell left behind. Mac (two worktrees in one folder): every tab orphaned after a restart, no layout.
    let macId = "w::/u/p/Mac::workspace:2f44"
    let listing: [String: Any] = [
        "terminals": [
            officeFocusOrphan("/u/p/demo-lighting", "term_ha", "pk-ha"),
            officeFocusOrphan("/u/p/demo-network", "term_nb_shell", "pk-nb"),
            officeFocusOrphan("/u/p/Mac", "term_m1", "pk-m1", worktreeId: macId),
            officeFocusOrphan("/u/p/Mac", "term_m2", "pk-m2", worktreeId: macId),
            officeFocusOrphan("/u/p/Mac", "term_m3", "pk-m3", worktreeId: macId),
        ],
        "visualLayouts": [
            officeFocusWorktree("/u/p/demo-lighting", active: "t-sx", [("t-sx", "Home-Moon-月光", "l-sx", p("t-sx", "l-sx", "h-sx", "✳ Home-Moon-月光"))]),
            officeFocusWorktree("/u/p/demo-network", active: "t-nb", [("t-nb", "月球漫步", "l-nb", p("t-nb", "l-nb", "h-nb", "月球漫步"))]),
            officeFocusWorktree("/u/p/Mac", active: "t-mac", [("t-mac", "MAC", "l-mac", p("t-mac", "l-mac", "h-mac", "✳ MAC"))]),
        ],
        "totalCount": 8, "truncated": false,
    ]
    let worktrees = OfficeFocus.worktrees(listing)
    let ha = [Shown(title: "✳ Home-Moon", depth: 2), Shown(title: "Home-Moon-月光", depth: 1)]
    let sx = [Shown(title: "Home-Moon", depth: 1), Shown(title: "Home-Moon-月光", depth: 2)]
    check(
        "office: Orca's layouts with only one of the bar's two tabs: the active one laid out is matched by the worktree that has some of the tabs and no others",
        OfficeFocus.match(sx, worktrees).terminal?.handle == "h-sx"
            && OfficeFocus.match([Shown(title: "Home-Kite", depth: 1), Shown(title: "月球漫步", depth: 2)], worktrees).terminal?.handle == "h-nb")
    check(
        "office: ...no terminal from that fallback when the bar does not tell its active tab, nor for tabs of two worktrees at once",
        OfficeFocus.match([Shown(title: "Home-Moon", depth: 1), Shown(title: "Home-Moon-月光", depth: 1)], worktrees).terminal == nil
            && OfficeFocus.match([Shown(title: "Home-Moon-月光", depth: 1), Shown(title: "月球漫步", depth: 1), Shown(title: "某会话", depth: 2)], worktrees).terminal == nil)

    // After a restart: a worktree with no layout shows "claude" and a Chinese-titled tab, both orphaned; another worktree lays out a
    // tab "claude" alone and has no orphans. Its "claude" is not the one the user looks at.
    let restarted = OfficeFocus.worktrees([
        "terminals": [officeFocusOrphan("/u/p/重启", "term_r1", "pk-r1"), officeFocusOrphan("/u/p/重启", "term_r2", "pk-r2")],
        "visualLayouts": [officeFocusWorktree("/u/p/别处", active: "t-c", [("t-c", "claude", "l-c", p("t-c", "l-c", "h-c", "✳ claude"))])],
    ])
    check(
        "office: ...a worktree whose orphans cannot be the bar's other tabs is no subset fit: another worktree's \"claude\" is not lit",
        OfficeFocus.match([Shown(title: "claude", depth: 2), Shown(title: "风筝脚本", depth: 1)], restarted).terminal == nil
            && restarted.count == 2 && restarted.last?.orphans.count == 2)

    // After a Mac restart: the bar keeps tabs of sessions gone (a duplicate, an off-duty one) and Orca has no
    // orphans at all; the worktree lays out only the live one. The match goes by the active tab's name.
    let rebooted = OfficeFocus.worktrees([
        "terminals": [] as [[String: Any]],
        "visualLayouts": [officeFocusWorktree("/u/p/helper-agent", active: "t-h", [("t-h", "Ops-Demo-Helper", "l-h", p("t-h", "l-h", "h-h", "✳ Ops-Demo-Helper"))])],
    ])
    let stale = [Shown(title: "AI-Pixie-Queen", depth: 1), Shown(title: "Ops-Demo-Helper", depth: 1), Shown(title: "✳ Ops-Demo-Helper", depth: 2)]
    if case .orphan(let title, _, _) = OfficeFocus.match(stale, rebooted) {
        check("office: a bar with stale tabs and no orphans falls back to the active tab's name", title == "Ops-Demo-Helper")
    } else {
        check("office: a bar with stale tabs and no orphans falls back to the active tab's name", false)
    }

    // The store's reader, as in `officeFocusTests`.
    let t0 = Date()
    let store = Store()
    store.readOnly = true
    func person(_ id: String, _ pid: Int32, _ name: String) -> Session {
        Session(id: id, pid: pid, project: "项目", name: name, status: "idle", since: t0 - 600, summary: "")
    }
    // Home-Moon started in the orphan; Home-Moon-<suffix> in the laid-out tab; Alpha-session in a Mac orphan, and another Alpha-session started
    // outside Orca; Bravo-session started outside Orca too (its terminal unknown); Charlie-session twice, neither in an orphan.
    store.sessions = [
        person("s-ha", 201, "Home-Moon"), person("s-sx", 202, "Home-Moon-月光"), person("s-jia", 203, "Alpha-session"), person("s-jia2", 204, "Alpha-session"),
        person("s-yi", 205, "Bravo-session"), person("s-bing", 206, "Charlie-session"), person("s-bing2", 207, "Charlie-session"), person("s-surge", 208, "Home-Kite"),
    ]
    var bar = OfficeFocus.Bar.tabs(ha), lines: [String] = []
    let element = AXUIElementCreateApplication(getpid())
    let focus = store.focus
    focus.queue = nil
    focus.frontmost = { (OfficeFocus.orca, 42) }
    focus.trusted = { true }
    focus.enhance = { _, _ in "made up" }
    focus.watch = { _, _ in (nil, "made up") }
    focus.findBar = { _ in ([element], 600) }
    focus.readBar = { _ in bar }
    focus.list = { listing }
    // Home-Moon's handle is the orphan's; Home-Kite's handle went stale, its pane is not the demo-network shell's either.
    focus.tab = { pid in
        switch pid {
        case 201: return ("term_ha", "pk-ha")
        case 202: return ("h-sx", "t-sx:l-sx")
        case 203: return ("term-old", "pk-m2")
        case 208: return ("term-surge-old", "pk-surge-old")
        default: return nil
        }
    }
    focus.note = { lines.append($0) }
    store.readFocus(at: t0)
    store.readFocus(at: t0 + 2)
    check(
        "office: the bar's active tab an orphaned terminal (source: a woken session's old tab): the session started in it is lit, by its handle",
        store.focused == "s-ha" && lines.filter { $0.contains("\"Home-Moon\" is in no layout") && $0.hasSuffix("found by its terminal's handle") }.count == 1)
    bar = .tabs(sx)
    store.readFocus(at: t0 + 4)
    store.readFocus(at: t0 + 6)
    check(
        "office: ...its laid-out neighbour clicked: that one is lit, and the subset fallback is logged once",
        store.focused == "s-sx" && lines.filter { $0.hasPrefix("focus: tabs [\"Home-Moon\", \"Home-Moon-月光\"]: no worktree has them all; demo-lighting has some") }.count == 1)
    // After an Orca restart: Mac's tabs, all orphaned. Alpha-session is found by its pane among the orphans, though another
    // session has that name too.
    bar = .tabs([Shown(title: "✳ Alpha-session", depth: 2), Shown(title: "Bravo-session", depth: 1), Shown(title: "MAC", depth: 1)])
    store.readFocus(at: t0 + 8)
    check(
        "office: every tab of a worktree orphaned by an Orca restart (live sessions, no layout of them): the one of that name in an orphan is lit",
        store.focused == "s-jia" && worktrees.last?.groups.isEmpty == true && worktrees.last?.orphans.map(\.handle) == ["term_m1", "term_m2", "term_m3"]
            && worktrees.first { $0.name == "Mac" && !$0.groups.isEmpty }?.orphans.isEmpty == true
            && lines.contains { $0.hasSuffix("found by its name, among the sessions in Orca's orphaned terminals") })
    bar = .tabs([Shown(title: "Alpha-session", depth: 1), Shown(title: "Bravo-session", depth: 2)])
    store.readFocus(at: t0 + 10)
    check(
        "office: ...a session whose terminal is not known, the only one of the active tab's name: lit by its name",
        store.focused == "s-yi" && lines.contains { $0.contains("\"Bravo-session\" is in no layout") && $0.hasSuffix("found by its name") })
    bar = .tabs([Shown(title: "Charlie-session", depth: 2), Shown(title: "Bravo-session", depth: 1)])
    store.readFocus(at: t0 + 12)
    store.readFocus(at: t0 + 14)
    check(
        "office: ...two sessions of that name, neither in an orphan: no light moves, and the miss is logged once",
        store.focused == "s-yi" && lines.filter { $0.hasPrefix("focus: no match for tabs [\"Charlie-session\", \"Bravo-session\"]") }.count == 1)
    // demo-network: the orphan is the shell a woken session left; Home-Kite's own handle is stale, so the name finds it.
    bar = .tabs([Shown(title: "Home-Kite", depth: 2), Shown(title: "月球漫步", depth: 1)])
    store.readFocus(at: t0 + 16)
    check("office: ...an orphan that runs no session (a shell left behind) under a tab of a session's name: that session by its name", store.focused == "s-surge")
    // Bravo-session is /rename'd to Bravo-session-new while Orca's tab keeps the old title: the old name, seen before, still finds it.
    store.sessions = store.sessions.map { $0.id == "s-yi" ? person("s-yi", 205, "Bravo-session-new") : $0 }
    bar = .tabs([Shown(title: "Charlie-session", depth: 1), Shown(title: "✳ Bravo-session", depth: 2)])
    store.readFocus(at: t0 + 18)
    check("office: a session renamed while its orphaned tab keeps the old title: still lit by its previous name", store.focused == "s-yi")
    // ...but a session whose current name is the title wins over one that had it before.
    store.sessions.append(person("s-yi2", 209, "Bravo-session"))
    bar = .tabs([Shown(title: "Home-Kite", depth: 2), Shown(title: "月球漫步", depth: 1)])
    store.readFocus(at: t0 + 20)
    bar = .tabs([Shown(title: "Charlie-session", depth: 1), Shown(title: "✳ Bravo-session", depth: 2)])
    store.readFocus(at: t0 + 22)
    check("office: ...the session that has that name now goes before one that had it", store.focused == "s-yi2")
}

/// The light in the office: on whose pet, between which of its layers, where, how it comes and goes, and that it walks with
/// the pet.
@MainActor func officeSpotlightTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    let size = CGSize(width: 1194, height: 764), fit = OfficeFit(size), now = Date()
    let store = officeStore()
    let dealt = officeDealCutPets(store)
    let layout = OfficePainter.layout(store, now: now, height: fit.height, scale: fit.scale)
    func place(_ id: String) -> OfficeLayout.Pet? { layout.pets.first { $0.id == id } }
    func parts(_ view: NSView, _ id: String) -> [String] { officeFigure(view, id)?.sublayers?.compactMap(\.name) ?? [] }
    func piece(_ view: NSView, _ id: String, _ name: String) -> CALayer? {
        officePart(view, id, "beam")?.sublayers?.first { $0.name == name }
    }
    let bare = ["shadow", "sprite", "words"], lit = ["shadow", "beam", "sprite", "words"]
    func until(_ seconds: Double, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    let view = OfficeView(frame: CGRect(origin: .zero, size: size))
    view.still = true
    store.focused = "o-busy"
    view.update(store)
    check(
        "office: the session he types in has a light on its pet, over its shadow and under its sprite and words",
        parts(view, "o-busy") == lit && officePart(view, "o-busy", "beam")?.opacity == 1)
    check(
        "office: ...nobody else has one, and the chips stay over everyone",
        ["o-wait", "o-news", "o-seen", "o-rest"].allSatisfy { parts(view, $0) == bare } && officeStage(view)?.sublayers?.last?.name == "chips")
    if let stage = officeStage(view), let cone = piece(view, "o-busy", "cone"), let pool = piece(view, "o-busy", "pool"), let p = place("o-busy"),
        let s = store.sessions.first(where: { $0.id == "o-busy" })
    {
        let figure = OfficePainter.figure(store, s, p, now: now)
        let c = stage.convert(cone.bounds, from: cone), q = stage.convert(pool.bounds, from: pool)
        let what = "office: the light runs from 72 pt above the pet's head down to its feet, 1.8 times as wide as the pet there, with a pool under its feet"
        if !dealt { skipped("no pet frames", what) } else { check(
            what,
            OfficeView.lightAbove == 72 && OfficeView.lightWide == 1.8 && abs(c.minY - (p.foot - figure.high - 72)) < 0.5 && abs(c.maxY - p.foot) < 0.5
                && abs(c.midX - p.x) < 0.5 && abs(c.width - 1.8 * figure.wide) < 0.5 && figure.wide > 20 && figure.high > 20 && abs(q.midX - p.x) < 0.5 && abs(q.midY - p.foot) < 1
                && abs(q.width - c.width) < 0.5) }
    } else {
        check("office: the light runs from 72 pt above the pet's head down to its feet, 1.8 times as wide as the pet there, with a pool under its feet", false)
    }
    // The pictures it is drawn from: how far across each row is lit, as a share of the picture's width, and how strong.
    func alphas(_ image: CGImage) -> (width: Int, height: Int, at: (Int, Int) -> Int) {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { raw in
            let c = CGContext(
                data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            c?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (w, h, { x, y in Int(bytes[(y * w + x) * 4 + 3]) })  // a bitmap's memory runs from its top row down
    }
    if let pictures = OfficeView.lightPictures(OfficeView.lightTone(on: OfficeTheme.studio.palette.floor)) {
        let cone = alphas(pictures.cone), pool = alphas(pictures.pool)
        func lit(_ v: Double) -> Double {
            let y = Int(v * Double(cone.height))
            return Double((0..<cone.width).filter { cone.at($0, y) > 0 }.count) / Double(cone.width)
        }
        let coneMost = (0..<cone.height).flatMap { y in (0..<cone.width).map { cone.at($0, y) } }.max() ?? 0
        let poolMost = (0..<pool.height).flatMap { y in (0..<pool.width).map { pool.at($0, y) } }.max() ?? 0
        // In the pet's widths (the cone is 1.8 of them wide): at its top, at the head of o-busy (72 pt down a cone its height and
        // 72 long), near the feet.
        let tall = place("o-busy").flatMap { p in store.sessions.first { $0.id == "o-busy" }.map { OfficePainter.figure(store, $0, p, now: now).high } } ?? 48
        // The picture is stretched to each cone, so how wide it is at the head goes with how tall the pet is drawn: about 1.2
        // of its widths for a pet 48 pt tall at a desk.
        func atHead(_ high: CGFloat) -> Double { Double(1.8 * (OfficeView.lightTop + (1 - OfficeView.lightTop) * 72 / (high + 72))) }
        let top = lit(0.06) * 1.8, head = lit(Double(72 / (tall + 72))) * 1.8, foot = lit(0.9) * 1.8
        print(
            String(
                format: "      the light's cone lit across %.2f of the pet's width at its top, %.2f at the head of this one (%.0f pt tall; %.2f drawn), %.2f near the feet; at most %d and %d of 255",
                top, head, tall, atHead(tall), foot, coneMost, poolMost))
        check(
            "office: the light is narrow at its top, about 1.2 times the pet's width at its head and 1.8 times at the feet; 35% in the cone, 45% in the pool",
            top > 0.25 && top < 0.55 && abs(atHead(48) - 1.2) < 0.05 && abs(head - atHead(tall)) < 0.1 && foot > 1.5 && foot <= 1.8
                && abs(coneMost - 87) <= 4 && abs(poolMost - 115) <= 3)
    } else {
        check("office: the light is narrow at its top, about 1.2 times the pet's width at its head and 1.8 times at the feet; 35% in the cone, 45% in the pool", false)
    }

    // Seen in the picture: lighter in the cone over the pet's head and on the floor at its feet, in every look; not beside it,
    // nor higher than its top.
    func picture(_ focused: String?, _ theme: OfficeTheme?) -> Pixels? {
        OfficeTheme.shown = theme
        defer { OfficeTheme.shown = nil }
        store.focused = focused
        let still = OfficeView(frame: CGRect(origin: .zero, size: size))
        still.still = true
        still.update(store)
        return still.image().map(Pixels.init)
    }
    /// How much lighter, at the most in any channel, the lit picture is than the dark one over a small box round a point.
    func lighter(_ a: Pixels, _ b: Pixels, at x: CGFloat, _ y: CGFloat) -> Int {
        var most = 0
        for dy in stride(from: CGFloat(-2), through: 2, by: 1) {
            for dx in stride(from: CGFloat(-2), through: 2, by: 1) {
                let u = a.at(x + dx, y + dy), v = b.at(x + dx, y + dy)
                for shift: UInt32 in [16, 8, 0] {
                    let one = Int((u >> shift) & 255), other = Int((v >> shift) & 255)
                    most = max(most, abs(one - other))
                }
            }
        }
        return most
    }
    let looks: [(String, OfficeTheme)] = [("青灰", OfficeTheme.studio), ("暖夜", OfficeTheme.night), ("E8E2D4", OfficeTheme.studio.floored(0xE8E2D4))]
    var seen: [String] = []
    var everywhere = true
    if let p = place("o-busy"), let s = store.sessions.first(where: { $0.id == "o-busy" }) {
        let figure = OfficePainter.figure(store, s, p, now: now), wide = figure.wide, head = p.foot - figure.high
        for (name, theme) in looks {
            guard let on = picture("o-busy", theme), let dark = picture(nil, theme) else {
                everywhere = false
                continue
            }
            // Above its top hangs the ball on its line : nothing above that.
            let over = lighter(on, dark, at: p.x, head - 18), floor = lighter(on, dark, at: p.x + wide * 0.6, p.foot + 1)
            let beside = lighter(on, dark, at: p.x + wide * 1.3, head - 18)
            let above = lighter(on, dark, at: p.x, head - 72 - OfficeView.ballSize.height - 6)
            seen.append("\(name): over the head +\(over), on the floor +\(floor), beside +\(beside), above its ball +\(above)")
            everywhere = everywhere && over >= 12 && floor >= 12 && beside <= 2 && above <= 2
        }
    }
    print("      the light, lighter by (out of 255): " + seen.joined(separator: "; "))
    check(
        "office: the light shows over the pet's head and on the floor at its feet in both themes and on E8E2D4; not beside it, nor above its ball",
        seen.count == 3 && everywhere)
    let pale = OfficeView.lightTone(on: OfficeTheme.studio.palette.floor), deep = OfficeView.lightTone(on: 0xE8E2D4)
    check(
        "office: on a dark floor the light is a pale warm white; on a light floor a deeper warm tone, so that it still shows",
        OfficeView.lightTone(on: OfficeTheme.night.palette.floor) == pale && OfficePalette.luminance(pale) > 0.8 && pale >> 16 & 255 > pale & 255
            && OfficePalette.luminance(deep) < OfficePalette.luminance(pale) - 0.2 && deep >> 16 & 255 > deep & 255)
    if review {
        for (name, theme) in looks {
            OfficeTheme.shown = theme
            store.focused = "o-busy"
            let still = OfficeView(frame: CGRect(origin: .zero, size: size))
            still.still = true
            still.update(store)
            save(still.image(), "/tmp/office-focus-\(name).png")
        }
        OfficeTheme.shown = nil
    }

    // Behind the door, or counted on a chip: no light anywhere.
    let crowd = officeStateStore(12, 14, 16, 0, 0), resting = officeStateStore(0, 0, 0, 4, 31)
    let chipped = OfficePainter.layout(crowd, now: now, height: fit.height, scale: fit.scale).outside.values.flatMap { $0 }.first
    let behind = OfficePainter.layout(resting, now: now, height: fit.height, scale: fit.scale).behindDoorIDs.first
    func anyLight(_ s: Store, _ id: String?) -> Bool {
        s.focused = id
        let v = OfficeView(frame: CGRect(origin: .zero, size: size))
        v.still = true
        v.update(s)
        return (officeStage(v)?.sublayers ?? []).contains { $0.sublayers?.contains { $0.name == "beam" } ?? false }
    }
    check(
        "office: one behind the lounge door or counted on a chip has no light, and nobody else gets it",
        chipped != nil && behind != nil && !anyLight(crowd, chipped) && !anyLight(resting, behind) && anyLight(resting, resting.sessions.first?.id))

    // Live, in a window: it fades, it dims, it goes, it walks.
    NSApplication.shared.setActivationPolicy(.accessory)
    let live = OfficeTestView(frame: CGRect(origin: .zero, size: size))
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    store.focused = nil
    live.update(store)
    let none = layout.pets.allSatisfy { parts(live, $0.id) == bare }
    store.focused = "o-news"
    live.update(store)
    let rising = officePart(live, "o-news", "beam")?.animation(forKey: "fade") as? CABasicAnimation
    check(
        "office: when he starts typing in a session, the light fades in on its pet over 0.3 s",
        none && parts(live, "o-news") == lit && officePart(live, "o-news", "beam")?.opacity == 1 && rising?.duration == 0.3
            && (rising?.toValue as? NSNumber)?.floatValue == 1)
    until(0.4) { officePart(live, "o-news", "beam")?.animation(forKey: "fade") == nil }
    store.focused = "o-seen"
    live.update(store)
    let falling = officePart(live, "o-news", "beam")?.animation(forKey: "fade") as? CABasicAnimation
    let next = officePart(live, "o-seen", "beam")?.animation(forKey: "fade") as? CABasicAnimation
    until(1) { parts(live, "o-news") == bare }
    check(
        "office: moving to another, the light fades off the first over 0.3 s and onto the other, and the first's is taken away",
        (falling?.toValue as? NSNumber)?.floatValue == 0 && falling?.duration == 0.3 && next?.duration == 0.3 && parts(live, "o-news") == bare
            && parts(live, "o-seen") == lit)
    store.orcaInFront = false
    live.update(store)
    check("office: with Orca in the background the light stays, at half strength", officePart(live, "o-seen", "beam")?.opacity == 0.5)
    store.orcaInFront = true
    live.update(store)
    setOfficeSpotlight(false)
    live.update(store)
    until(1) { parts(live, "o-seen") == bare }
    let gone = parts(live, "o-seen") == bare
    UserDefaults.standard.removeObject(forKey: "officeSpotlight")
    live.update(store)
    check(
        "office: switched off in the menu bar the light goes; switched on, it is back, with its pictures in",
        gone && parts(live, "o-seen") == lit && piece(live, "o-seen", "cone")?.contents != nil && piece(live, "o-seen", "pool")?.contents != nil)
    until(0.4) { officePart(live, "o-seen", "beam")?.animation(forKey: "fade") == nil }

    // It walks with the pet: o-seen, lit at its desk, starts waiting and walks to the queue.
    store.sessions = store.sessions.map { $0.id == "o-seen" ? officeSession("o-seen", "waiting", finished: 1) : $0 }
    live.update(store)
    CATransaction.flush()
    let walk = officeFigure(live, "o-seen")?.animation(forKey: "walk") as? CAKeyframeAnimation
    let walking = piece(live, "o-seen", "cone")
    check(
        "office: as it walks, the light goes with it in its layer, with nothing of its own to animate: its height stays the pet's and 72 pt more",
        walk != nil && walking?.animationKeys() == nil && officePart(live, "o-seen", "beam")?.superlayer === officeFigure(live, "o-seen")
            && (walking?.bounds.height ?? 0) > 72 + 20)
    var heights: [CGFloat] = [], ys: [CGFloat] = [], feet: [CGPoint] = []
    let walkEnds = Date().addingTimeInterval((walk?.duration ?? 0) + 0.6)
    while Date() < walkEnds {
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        guard let f = officeFigure(live, "o-seen")?.presentation(), let c = piece(live, "o-seen", "cone")?.presentation() else { continue }
        heights.append(c.bounds.height)
        ys.append(f.position.y)
        feet.append(c.position)
    }
    let travelled = (ys.max() ?? 0) - (ys.min() ?? 0)
    print(String(format: "      the light's height over a walk of %.0f pt down the room: %@", travelled, heights.map { String(format: "%.1f", $0) }.joined(separator: " ")))
    check(
        "office: ...seen on the way, its height stays the same and its foot at the pet's feet",
        heights.count >= 5 && travelled > 100 && heights.allSatisfy { abs($0 - heights[0]) < 0.01 } && feet.allSatisfy { $0 == .zero })
    let arrived = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale).pets.first { $0.id == "o-seen" }
    if let stage = officeStage(live), let cone = piece(live, "o-seen", "cone"), let figure = officeFigure(live, "o-seen"), let arrived,
        let s = store.sessions.first(where: { $0.id == "o-seen" })
    {
        let foot = stage.convert(cone.position, from: cone.superlayer)
        let high = OfficePainter.figure(store, s, arrived, now: Date()).high
        check(
            "office: ...and where it stands now the light's foot is the pet's position, its top 72 pt over the pet's head",
            arrived.zone == .queue && foot == figure.position && abs(cone.bounds.height - (high + 72)) < 0.01)
    } else {
        check("office: ...and where it stands now the light's foot is the pet's position, its top 72 pt over the pet's head", false)
    }
    // Lit on its way: one that sets off unlit and is lit while it walks takes the rest of the walk with it.
    store.sessions = store.sessions.map { $0.id == "o-news" ? officeSession("o-news", "busy", finished: 1) : $0 }
    live.update(store)
    CATransaction.flush()
    store.focused = "o-news"
    live.update(store)
    let going = officeFigure(live, "o-news")?.animation(forKey: "walk") as? CAKeyframeAnimation
    check(
        "office: one lit on its way takes the light along the rest of its walk",
        going != nil && officePart(live, "o-news", "beam")?.superlayer === officeFigure(live, "o-news")
            && piece(live, "o-news", "cone")?.animationKeys() == nil)
    if !dealt { print("      (pets in these checks are grey blocks: too few cut frames)") }
}

/// The light as the panel itself draws it, live, in a window the size of the user's (1180×790, the room drawn a little
/// smaller than its own points), through what the room does while it is on: a new look, someone arriving, the lit pet's
/// own change and walk, Orca going to the back. And what the panel's log says it draws.
@MainActor func officeSpotlightLiveTests() {
    let size = CGSize(width: 1180, height: 790), fit = OfficeFit(size)
    let store = officeStore()
    let dealt = officeDealCutPets(store)
    NSApplication.shared.setActivationPolicy(.accessory)
    let live = OfficeTestView(frame: CGRect(origin: .zero, size: size))
    var lines: [String] = []
    live.note = { lines.append($0) }
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    func until(_ seconds: Double, _ done: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    func beam(_ id: String) -> CALayer? { officePart(live, id, "beam") }
    func cone(_ id: String) -> CALayer? { beam(id)?.sublayers?.first { $0.name == "cone" } }
    /// Whether the light is there as it should be: in the pet's figure between its shadow and its sprite, the figure on the
    /// stage under the chips, on at this strength in the model and on screen.
    func attached(_ id: String, _ strength: Float = 1) -> Bool {
        guard let b = beam(id), let figure = officeFigure(live, id), let stage = officeStage(live) else { return false }
        return b.superlayer === figure && figure.superlayer === stage && figure.sublayers?.compactMap(\.name) == ["shadow", "beam", "sprite", "words"]
            && b.opacity == strength && abs((b.presentation()?.opacity ?? b.opacity) - strength) < 0.01 && figure.zPosition > 0
            && figure.zPosition < (stage.sublayers?.last?.zPosition ?? 0) && stage.sublayers?.last?.name == "chips"
    }
    func place(_ id: String) -> OfficeLayout.Pet? {
        OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale).pets.first { $0.id == id }
    }
    func high(_ id: String) -> CGFloat {
        guard let p = place(id), let s = store.sessions.first(where: { $0.id == id }) else { return 0 }
        return OfficePainter.figure(store, s, p, now: Date()).high
    }

    live.update(store)
    until(0.3) { false }
    let dark = officeMoment(live).map(Pixels.init)
    store.focused = "o-busy"
    live.update(store)
    until(0.6) { beam("o-busy")?.animation(forKey: "fade") == nil }
    check("office: live in a 1180×790 window, the lit pet's light is in its figure between shadow and sprite, fully on, under the chips", attached("o-busy"))
    // Where: the room's points taken into the view by OfficeFit, as everything else in the room is.
    if let p = place("o-busy"), let c = cone("o-busy"), let view = live.layer {
        let r = view.convert(c.bounds, from: c), feet = CGPoint(x: fit.offset.x + p.x * fit.scale, y: fit.offset.y + p.foot * fit.scale)
        let top = feet.y - (high("o-busy") + 72) * fit.scale
        check(
            "office: ...at the window's scale (under 1) its cone stands on the pet's feet as OfficeFit puts them, its top 72 pt (scaled) over the head",
            fit.scale < 1 && abs(r.midX - feet.x) < 1 && abs(r.maxY - feet.y) < 1 && abs(r.minY - top) < 1 && live.bounds.contains(r) && r.height > 40)
        // And seen: what the layers show, lit against unlit, over the head and at the feet; nothing beside.
        if let dark, let lit = officeMoment(live).map(Pixels.init) {
            func lighter(_ x: CGFloat, _ y: CGFloat) -> Int {
                var most = 0
                for dy in stride(from: CGFloat(-2), through: 2, by: 1) {
                    for dx in stride(from: CGFloat(-2), through: 2, by: 1) {
                        let u = lit.at(x + dx, y + dy), v = dark.at(x + dx, y + dy)
                        for shift: UInt32 in [16, 8, 0] { most = max(most, abs(Int((u >> shift) & 255) - Int((v >> shift) & 255))) }
                    }
                }
                return most
            }
            let over = lighter(feet.x, top + 18 * fit.scale), floor = lighter(feet.x + r.width * 0.35, feet.y + 1)
            let beside = lighter(feet.x + r.width * 0.9, top + 18 * fit.scale)
            print("      live at 1180×790, lighter by (out of 255): over the head +\(over), at the feet +\(floor), beside +\(beside)")
            check("office: ...and on screen its layers are lighter over the head and at the feet, not beside", over >= 12 && floor >= 12 && beside <= 2)
        } else {
            check("office: ...and on screen its layers are lighter over the head and at the feet, not beside", false)
        }
    } else {
        check("office: ...at the window's scale (under 1) its cone stands on the pet's feet as OfficeFit puts them, its top 72 pt (scaled) over the head", false)
    }
    // Through the room's own changes.
    OfficeTheme.shown = OfficeTheme.night
    live.update(store)
    let newLook = attached("o-busy")
    OfficeTheme.shown = nil
    live.update(store)
    store.sessions.append(officeSession("o-late", "busy", finished: 5))
    live.update(store)
    until(1.5) { officeFigure(live, "o-late")?.animation(forKey: "walk") == nil && officeFigure(live, "o-late") != nil }
    check("office: ...it stays on through the room repainted in another look and someone new walking in", newLook && attached("o-busy"))
    // Its own pet changes: o-busy finishes (news: it jumps, then walks to the sofas), and arrives.
    store.sessions = store.sessions.map { $0.id == "o-busy" ? officeSession("o-busy", "idle", finished: 1) : $0 }
    live.update(store)
    until(0.2) { false }
    let moving = attached("o-busy") && officeFigure(live, "o-busy")?.animation(forKey: "walk") != nil
    until(6) { officeFigure(live, "o-busy")?.animation(forKey: "walk") == nil }
    live.update(store)
    let arrivedHeight = cone("o-busy")?.bounds.height ?? 0
    check(
        "office: ...and through the lit pet's own change of pose and its walk: on the way and where it arrives, its top 72 pt over the head",
        moving && attached("o-busy") && abs(arrivedHeight - (high("o-busy") + 72)) < 0.01 && place("o-busy")?.zone == .sofa)
    // Orca to the back: half, not none; forward again: whole.
    store.orcaInFront = false
    live.update(store)
    until(0.5) { beam("o-busy")?.animation(forKey: "fade") == nil }
    let half = attached("o-busy", 0.5)
    store.orcaInFront = true
    live.update(store)
    until(0.5) { beam("o-busy")?.animation(forKey: "fade") == nil }
    check("office: with Orca in the background the live light is at half strength, not gone; with Orca in front again, whole", half && attached("o-busy"))
    // The panel's log: what it draws when the light goes to someone else, at most a line a second; never for a picture.
    let said = lines.filter { $0.hasPrefix("focus: beam on o-busy at (") && $0.contains(" alpha ") && $0.contains(" z ") }
    lines = []
    store.focused = "o-wait"
    live.update(store)
    store.focused = "o-seen"
    live.update(store)
    let soon = lines.count
    live.shift = 1.5
    live.update(store)
    let later = lines
    store.focused = "nobody-here"
    live.shift = 3
    live.update(store)
    let nobody = lines.last
    store.focused = nil
    live.shift = 4.5
    live.update(store)
    let off = lines.last
    let picture = OfficeView(frame: CGRect(origin: .zero, size: size))
    var pictureSaid = 0
    picture.note = { _ in pictureSaid += 1 }
    picture.still = true
    store.focused = "o-seen"
    picture.update(store)
    check(
        "office: the panel's log says where it draws the light, its strength and depth, when it goes to someone else: at most a line a second",
        said.count == 1 && soon == 1 && later.count == 2 && later.last?.hasPrefix("focus: beam on o-seen at (") == true)
    check(
        "office: ...that the one lit has no pet in the room, and that the light is off; and nothing for a picture",
        nobody == "focus: beam on nobody: nobody-here has no pet in the room (behind the door, or on a chip)" && off == "focus: beam off"
            && pictureSaid == 0)
    store.focused = nil
    if !dealt { print("      (pets in these checks are grey blocks: too few cut frames)") }
}

/// The light as the screen shows it, by pixels: the panel's own view (not a check's subclass), listening for
/// frames and with its pets' sprite loops running, in a window the size of the user's (1180×790), rendered as the snapshot renders it.
/// The mean brightness of a 10×10 patch 20 pt over the lit pet's head and a 30×6 patch just under its feet, against the
/// same patches with nobody lit: lit at first, and lit again after the user went to another session and came back, as the user does.
@MainActor func officeSpotlightSeenTests() {
    let size = CGSize(width: 1180, height: 790), fit = OfficeFit(size)
    let store = officeStore()
    let dealt = officeDealCutPets(store)
    NSApplication.shared.setActivationPolicy(.accessory)
    let live = OfficeView(frame: CGRect(origin: .zero, size: size))
    live.note = { _ in }
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    live.listen()
    defer {
        live.stopListening()
        window.orderOut(nil)
        window.contentView = nil
    }
    func wait(_ seconds: Double, _ done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    live.update(store)
    wait(2) { officePart(live, "o-busy", "sprite")?.animation(forKey: "loop") != nil }
    let looping = officePart(live, "o-busy", "sprite")?.animation(forKey: "loop") != nil
    guard let p = OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale).pets.first(where: { $0.id == "o-busy" }),
        let s = store.sessions.first(where: { $0.id == "o-busy" })
    else { return check("office: on screen the lit pet is lighter 20 pt over its head and just under its feet, lit at first and lit again", false) }
    let high = OfficePainter.figure(store, s, p, now: Date()).high
    /// The mean brightness, out of 255, of a patch of the room given in its own points, as the view shows it.
    func mean(_ picture: Pixels, _ r: CGRect) -> Double {
        let v = fit.rect(r)
        var sum = 0.0, count = 0.0
        for y in stride(from: v.minY, to: v.maxY, by: 0.5) {
            for x in stride(from: v.minX, to: v.maxX, by: 0.5) {
                let c = picture.at(x, y)
                let red = Double((c >> 16) & 255), green = Double((c >> 8) & 255), blue = Double(c & 255)
                sum += (red + green + blue) / 3
                count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }
    let overHead = CGRect(x: p.x - 5, y: p.foot - high - 20 - 5, width: 10, height: 10)
    let underFeet = CGRect(x: p.x - 15, y: p.foot + 0.5, width: 30, height: 6)
    // The ball's middle, 8 pt over the beam's top: how far it is from the ideal position, on average.
    let ballMiddle = CGRect(x: p.x - 4, y: p.foot - high - 72 - 8 - 4, width: 8, height: 8)
    func apart(_ a: Pixels, _ b: Pixels, _ r: CGRect) -> Double {
        let v = fit.rect(r)
        var sum = 0.0, count = 0.0
        for y in stride(from: v.minY, to: v.maxY, by: 0.5) {
            for x in stride(from: v.minX, to: v.maxX, by: 0.5) {
                let c = a.at(x, y), d = b.at(x, y)
                sum += Double([16, 8, 0].map { abs(Int((c >> UInt32($0)) & 255) - Int((d >> UInt32($0)) & 255)) }.max() ?? 0)
                count += 1
            }
        }
        return count > 0 ? sum / count : 0
    }
    var darkPicture: Pixels?
    var balls: [Double] = []
    func shown() -> (head: Double, feet: Double)? {
        guard let image = live.image() else { return nil }
        let picture = Pixels(image)
        if let darkPicture { balls.append(apart(picture, darkPicture, ballMiddle)) } else { darkPicture = picture }
        return (mean(picture, overHead), mean(picture, underFeet))
    }
    guard let dark = shown() else { return check("office: on screen the lit pet is lighter 20 pt over its head and just under its feet, lit at first and lit again", false) }
    store.focused = "o-busy"
    live.update(store)
    wait(0.5)
    let first = shown()
    store.focused = "o-seen"
    live.update(store)
    wait(0.8) { officePart(live, "o-busy", "beam") == nil }
    let left = officePart(live, "o-busy", "beam") == nil
    store.focused = "o-busy"
    live.update(store)
    wait(0.5)
    let again = shown()
    let spotsAgain = officePart(live, "o-busy", "beam")?.sublayers?.filter { $0.name == "spot" } ?? []
    func gain(_ lit: (head: Double, feet: Double)?) -> (head: Double, feet: Double) {
        (lit.map { $0.head - dark.head } ?? 0, lit.map { $0.feet - dark.feet } ?? 0)
    }
    let a = gain(first), b = gain(again)
    print(
        String(
            format: "      on screen, mean brightness gained (out of 255): lit at first: over the head +%.1f, under the feet +%.1f; lit again: +%.1f, +%.1f",
            a.head, a.feet, b.head, b.feet))
    let lighter = "office: on screen (the panel's own view, sprite loops running, 1180×790) the lit pet is lighter 20 pt over its head and under its feet by 12 or more"
    if dealt { check(lighter, looping && a.head >= 12 && a.feet >= 12) } else { skipped("no pet frames", lighter) }
    check(
        "office: ...and so it is again when he went to another session and came back, after its light had gone",
        left && b.head >= 12 && b.feet >= 12)
    print("      on screen, the ball's middle differs from what was there by (out of 255, on average): " + balls.map { String(format: "%.1f", $0) }.joined(separator: ", "))
    check(
        "office: ...its mirror ball shows over the beam's top lit at first and lit again, and the light lit again has its spots painted too",
        balls.count == 2 && balls.allSatisfy { $0 >= 20 } && spotsAgain.count == OfficeView.spots.count && spotsAgain.allSatisfy { $0.contents != nil })
    store.focused = nil
    if !dealt { print("      (pets in these checks are grey blocks: too few cut frames)") }
}

/// The mirror ball over the light and the spots it throws: their pictures and loops, where they are in the beam, how
/// they move live, that a still picture, Reduce Motion and another look are kept, and that a light lit again has them too.
@MainActor func officeDiscoTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    let size = CGSize(width: 1194, height: 764), fit = OfficeFit(size)
    let store = officeStore()
    let dealt = officeDealCutPets(store)
    func beam(_ view: NSView, _ id: String) -> CALayer? { officePart(view, id, "beam") }
    func piece(_ view: NSView, _ id: String, _ name: String) -> CALayer? { beam(view, id)?.sublayers?.first { $0.name == name } }
    func spots(_ view: NSView, _ id: String) -> [CALayer] { beam(view, id)?.sublayers?.filter { $0.name == "spot" } ?? [] }
    func place(_ id: String) -> OfficeLayout.Pet? {
        OfficePainter.layout(store, now: Date(), height: fit.height, scale: fit.scale).pets.first { $0.id == id }
    }
    func drawn(_ id: String) -> (wide: CGFloat, high: CGFloat)? {
        guard let p = place(id), let s = store.sessions.first(where: { $0.id == id }) else { return nil }
        let figure = OfficePainter.figure(store, s, p, now: Date())
        return (figure.wide, figure.high)
    }
    func until(_ seconds: Double, _ done: () -> Bool = { false }) {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }
    func animated(_ layer: CALayer?) -> [String] {
        guard let layer else { return [] }
        return (layer.animationKeys() ?? []) + (layer.sublayers ?? []).flatMap(animated)
    }
    func near(_ a: CGPoint, _ b: CGPoint, _ by: CGFloat = 0.01) -> Bool { abs(a.x - b.x) <= by && abs(a.y - b.y) <= by }
    let studio = OfficeView.ballPictures(OfficeTheme.studio), night = OfficeView.ballPictures(OfficeTheme.night)

    // The ball's pictures: which facets are lit white on each, and whether the rest are the look's own graphite and white.
    let top = OfficeView.ballLine + 2
    /// A facet's colour, by its column and row.
    func facet(_ pixels: Pixels, _ i: Int, _ j: Int) -> UInt32 {
        let x: CGFloat = 2 + 2 * CGFloat(i), y: CGFloat = top + 1 + 2 * CGFloat(j)
        return pixels.at(x, y)
    }
    func glints(_ image: CGImage) -> Set<Int> {
        let pixels = Pixels(image)
        var found = Set<Int>()
        for j in 0..<7 {
            for i in 0..<7 where facet(pixels, i, j) == 0xFFFFFF { found.insert(i * 10 + j) }
        }
        return found
    }
    func ownTones(_ image: CGImage, _ theme: OfficeTheme) -> Bool {
        let pixels = Pixels(image), p = theme.palette
        let ramp: [UInt32] = [p.graphite.base, p.graphite.front, p.graphite.top, p.white.base, p.white.front, p.white.top, 0xFFFFFF]
        for j in 0..<7 {
            for i in 0..<7 where hypot(CGFloat(i) - 3, CGFloat(j) - 3) <= 3.5 {
                let colour = facet(pixels, i, j)
                if !ramp.contains(where: { same($0, colour) }) { return false }
            }
        }
        return true
    }
    let lit = studio.map(glints)
    let stepping = (0..<lit.count).allSatisfy { k in
        let next = lit[(k + 1) % lit.count]
        return lit[k].filter { $0 / 10 < 6 }.allSatisfy { next.contains($0 + 10) } && lit[k] != next
    }
    print("      the ball's lit facets (column·10+row), picture by picture: " + lit.map { $0.sorted().map(String.init).joined(separator: " ") }.joined(separator: " | "))
    check(
        "office: the mirror ball turns through 8 pictures, 16×29 pt with its line, painted once a look; on each 2 or 3 facets are lit, one column further round than on the one before",
        studio.count == 8 && OfficeView.ballFrames == 8 && studio.allSatisfy { $0.width == 32 && $0.height == Int(OfficeView.ballSize.height * 2) }
            && OfficeView.ballSize.width == 16 && zip(studio, OfficeView.ballPictures(OfficeTheme.studio)).allSatisfy { $0 === $1 }
            && lit.allSatisfy { (2...3).contains($0.count) } && stepping)
    check(
        "office: ...the rest of its facets are the look's own graphite and white tones, so slate and warm-night each have a ball of their own",
        !studio.isEmpty && !night.isEmpty && studio.allSatisfy { ownTones($0, OfficeTheme.studio) } && night.allSatisfy { ownTones($0, OfficeTheme.night) }
            && officeDifference(studio[0], night[0], by: 8) > 0.1)

    // The spots: a cute palette, small and soft, each on a loop and a time of its own.
    let pastel: Set<UInt32> = [0xFFB3C7, 0xA8EBCF, 0xA8D8FF, 0xFFE89A, 0xC9B6FF]
    let warm: Set<UInt32> = [OfficeView.lightTone(on: OfficeTheme.studio.palette.floor), OfficeView.lightTone(on: 0xE8E2D4)]
    let table = OfficeView.spots
    check(
        "office: 4 or 5 spots of light in soft pink, mint, sky, butter and lilac (at most 2 the beam's warm white), 12–19 pt, at 50–60%, each round its loop in 8–14 s, no two alike in time or start",
        (4...5).contains(table.count) && table.allSatisfy { pastel.contains($0.colour) || warm.contains($0.colour) }
            && table.filter { warm.contains($0.colour) }.count <= 2 && table.allSatisfy { (12...19.2).contains($0.size) && (0.5...0.6).contains($0.opacity) }
            && table.allSatisfy { (8...14).contains($0.seconds) } && Set(table.map(\.seconds)).count == table.count
            && Set(table.map(\.phase)).count == table.count && table.allSatisfy { (0..<1).contains($0.phase) })
    // Their loops, for a pet drawn as a desk pet is and one drawn larger: inside the cone below its faint top, or on the pool.
    var inLight = true, fastest: CGFloat = 0, overHead = false, onFloor = false, beside = false
    for (wide, high) in [(CGFloat(40), CGFloat(48)), (60, 70)] {
        let tall = high + OfficeView.lightAbove, poolWide = OfficeView.lightWide * wide / 2, poolDeep = max(10, OfficeView.lightWide * wide * 0.24) / 2
        for spot in table {
            let steps = 96
            let points = (0...steps).map { OfficeView.place(spot, at: Double($0) / Double(steps), wide: wide, high: high) }
            for (a, b) in zip(points, points.dropFirst()) { fastest = max(fastest, hypot(b.x - a.x, b.y - a.y) / CGFloat(spot.seconds / Double(steps))) }
            for q in points {
                let v = (q.y + tall) / tall
                let coneHalf = OfficeView.lightWide * wide * (OfficeView.lightTop + (1 - OfficeView.lightTop) * v) / 2
                let ok = q.y <= 0 ? v >= 0.15 && abs(q.x) <= coneHalf * 0.85 : pow(q.x / poolWide, 2) + pow(q.y / poolDeep, 2) <= 1
                inLight = inLight && ok
                overHead = overHead || q.y < -high - 6
                onFloor = onFloor || q.y > 1
                beside = beside || (q.y < -4 && q.y > -high && abs(q.x) > wide * 0.45)
            }
        }
    }
    print(String(format: "      the spots' loops: fastest %.1f pt a second", fastest))
    check(
        "office: ...their loops stay in the light, over the head, beside the body and on the floor at its feet, slowly: under 20 pt a second",
        inLight && overHead && onFloor && beside && fastest > 1 && fastest < 20)
    if let pink = OfficeView.spotPicture(0xFFB3C7) {
        let pixels = Pixels(pink)
        // Two pixels to the point in `Pixels`: the picture is 32 pixels across, so its middle is at 8 points, half way out at 4.
        let middle = pixels.at(8, 8), halfway = pixels.at(4, 8), rim = pixels.at(0.3, 8), corner = pixels.at(0.3, 0.3)
        check(
            "office: ...each a soft round of its colour: even over most of it, fading to nothing at its rim, painted once",
            pink.width == 32 && same(middle, 0xFFB3C7) && same(halfway, 0xFFB3C7) && [16, 8, 0].allSatisfy { (rim >> UInt32($0)) & 255 < 12 }
                && corner == 0 && OfficeView.spotPicture(0xFFB3C7) === pink)
    } else {
        check("office: ...each a soft round of its colour: even over most of it, fading to nothing at its rim, painted once", false)
    }
    // On a light floor a pastel all but vanishes, as the light's pale white would: each takes a deeper tone of its colour.
    func strongest(_ c: UInt32) -> Int { [16, 8, 0].max { (c >> UInt32($0)) & 255 < (c >> UInt32($1)) & 255 } ?? 0 }
    check(
        "office: ...on a light floor (E8E2D4) each takes a deeper tone of its own colour, so it still shows; on both themes' dark floors, its pastel",
        !table.isEmpty && table.allSatisfy { spot in
            OfficeView.spotTone(spot, on: OfficeTheme.studio.palette.floor) == spot.colour && OfficeView.spotTone(spot, on: OfficeTheme.night.palette.floor) == spot.colour
                && OfficeView.spotTone(spot, on: 0xE8E2D4) == spot.deep && strongest(spot.deep) == strongest(spot.colour)
                && OfficePalette.contrast(spot.deep, 0xE8E2D4) >= 1.4 && OfficePalette.contrast(spot.deep, 0xE8E2D4) > OfficePalette.contrast(spot.colour, 0xE8E2D4) + 0.3
        })

    // A still picture: the ball on the beam's top in its first picture, the spots where they start; nothing turns.
    func still(_ phase: Double = 0, theme: OfficeTheme? = nil) -> OfficeView {
        OfficeView.stillPhase = phase
        OfficeTheme.shown = theme
        defer {
            OfficeView.stillPhase = 0
            OfficeTheme.shown = nil
        }
        let view = OfficeView(frame: CGRect(origin: .zero, size: size))
        view.still = true
        view.update(store)
        return view
    }
    store.focused = "o-busy"
    let picture = still()
    let names = beam(picture, "o-busy")?.sublayers?.compactMap(\.name) ?? []
    if let stage = officeStage(picture), let cone = piece(picture, "o-busy", "cone"), let ball = piece(picture, "o-busy", "ball"), let p = place("o-busy"),
        let d = drawn("o-busy")
    {
        let c = stage.convert(cone.bounds, from: cone), r = stage.convert(ball.bounds, from: ball)
        let shown = spots(picture, "o-busy")
        let starts = zip(table, shown).allSatisfy { spot, layer in
            near(layer.position, OfficeView.place(spot, at: spot.phase, wide: d.wide, high: d.high)) && layer.bounds.width == spot.size
                && layer.opacity == spot.opacity && layer.contents as AnyObject? === OfficeView.spotPicture(spot.colour)
        }
        check(
            "office: in a still picture a mirror ball hangs over the light, its foot on the beam's top (72 pt over the head), in its first picture",
            abs(r.maxY - c.minY) < 0.5 && abs(r.midX - p.x) < 0.5 && abs(r.width - 16) < 0.01 && abs(r.height - OfficeView.ballSize.height) < 0.01
                && abs(c.minY - (p.foot - d.high - 72)) < 0.5 && ball.contents as AnyObject? === studio.first)
        check(
            "office: ...and the spots in the beam over its cone and pool, under the sprite, each where its loop starts; nothing turns",
            names == ["cone", "pool"] + Array(repeating: "spot", count: table.count) + Array(repeating: "laser", count: 3) + ["ball"] && starts
                && officeFigure(picture, "o-busy")?.sublayers?.compactMap(\.name) == ["shadow", "beam", "sprite", "words"]
                && animated(officeStage(picture)).isEmpty)
    } else {
        check("office: in a still picture a mirror ball hangs over the light, its foot on the beam's top (72 pt over the head), in its first picture", false)
        check("office: ...and the spots in the beam over its cone and pool, under the sprite, each where its loop starts; nothing turns", false)
    }
    // `--focus-phase 0.5`: half way round every loop.
    let half = still(0.5)
    if let d = drawn("o-busy") {
        let shown = spots(half, "o-busy")
        let moved = zip(table, shown).allSatisfy { spot, layer in near(layer.position, OfficeView.place(spot, at: spot.phase + 0.5, wide: d.wide, high: d.high)) }
        let a = picture.image(), b = half.image()
        check(
            "office: a still picture half way round its loops (`--focus-phase 0.5`) shows the ball's fifth picture and every spot half its loop on",
            studio.count == 8 && piece(half, "o-busy", "ball")?.contents as AnyObject? === studio[4] && shown.count == table.count && moved
                && a != nil && b != nil && officeDifference(a!, b!, by: 8) > 0.0005 && OfficeView.stillPhase == 0)
        if review, let a, let b {
            save(a, "/tmp/office-ball-phase0.png")
            save(b, "/tmp/office-ball-phase05.png")
        }
    } else {
        check("office: a still picture half way round its loops (`--focus-phase 0.5`) shows the ball's fifth picture and every spot half its loop on", false)
    }
    // On the couches at the back the cone's top is near the room's: the ball comes down over the cone's top, line and all
    // inside the room, rather than off its top edge.
    store.focused = "o-rest"
    let back = still()
    if let stage = officeStage(back), let cone = piece(back, "o-rest", "cone"), let ball = piece(back, "o-rest", "ball"), let p = place("o-rest") {
        let c = stage.convert(cone.bounds, from: cone), r = stage.convert(ball.bounds, from: ball)
        print(String(format: "      on the back couch: the cone's top at %.1f pt, the ball's picture from %.1f to %.1f", c.minY, r.minY, r.maxY))
        let hangs = "office: lit on a couch at the back, the ball hangs inside the room, its line from the room's top, down over the cone's top"
        if !dealt { skipped("no pet frames", hangs) } else { check(
            hangs,
            p.zone == .lounge && c.minY < OfficeView.ballSize.height && abs(r.minY) < 0.01 && r.maxY > c.minY
                && r.maxY - c.minY <= OfficeView.ballSize.height && abs(r.midX - p.x) < 0.5) }
    } else {
        check("office: lit on a couch at the back, the ball hangs inside the room, its line from the room's top, down over the cone's top", false)
    }
    store.focused = "o-busy"
    // Lit again in a still view: what was painted for the last light is not taken for this one's.
    store.focused = nil
    picture.update(store)
    let gone = beam(picture, "o-busy") == nil
    store.focused = "o-busy"
    picture.update(store)
    check(
        "office: in a still view lit, put out and lit again, the new light has its ball and spots painted",
        gone && piece(picture, "o-busy", "ball")?.contents != nil && spots(picture, "o-busy").count == table.count
            && spots(picture, "o-busy").allSatisfy { $0.contents != nil })

    // Live, in a window.
    NSApplication.shared.setActivationPolicy(.accessory)
    let live = OfficeTestView(frame: CGRect(origin: .zero, size: size))
    live.note = { _ in }
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    defer {
        window.orderOut(nil)
        window.contentView = nil
    }
    store.focused = nil
    live.update(store)
    store.focused = "o-busy"
    live.update(store)
    func turning(_ view: NSView, _ id: String) -> CAKeyframeAnimation? { piece(view, id, "ball")?.animation(forKey: "turn") as? CAKeyframeAnimation }
    func drifts(_ view: NSView, _ id: String) -> [CAKeyframeAnimation] {
        spots(view, id).compactMap { $0.animation(forKey: "drift") as? CAKeyframeAnimation }
    }
    func lasers(_ view: NSView, _ id: String) -> [CALayer] { beam(view, id)?.sublayers?.filter { $0.name == "laser" } ?? [] }
    func sweeps(_ view: NSView, _ id: String) -> [CAKeyframeAnimation] {
        lasers(view, id).compactMap { $0.animation(forKey: "sweep") as? CAKeyframeAnimation }
    }
    /// A loop that steps a twelfth of a second a value, from a beat of the clock, forever.
    func onBeat(_ loop: CAKeyframeAnimation) -> Bool {
        let count = Double(loop.values?.count ?? 0), start = loop.beginTime * 12
        return loop.calculationMode == .discrete && count > 0 && abs(loop.duration / count - 1.0 / 12) < 0.000_1
            && abs(start - start.rounded()) < 0.001 && abs(loop.timeOffset * 12 - (loop.timeOffset * 12).rounded()) < 0.001 && loop.repeatCount == .infinity
    }
    func moving(_ view: NSView, _ id: String) -> Bool {
        turning(view, id) != nil && drifts(view, id).count == table.count && sweeps(view, id).count == OfficeView.lasers.count
    }
    let turn = turning(live, "o-busy")
    check(
        "office: live, the ball turns: its 8 pictures one after another, 7 beats (about 0.6 s) each, on the light's beat, round and round",
        turn?.keyPath == "contents" && turn.map(onBeat) == true && turn?.values?.count == 8 * OfficeView.ballBeats
            && (0..<8).allSatisfy { (turn?.values?[$0 * OfficeView.ballBeats] as AnyObject?) === studio[$0] } && abs((turn?.duration ?? 0) - 56.0 / 12) < 0.001)
    // Three lasers from the ball's middle to the floor, a dot at each tip, swinging there and back, eased, forever.
    let rays = lasers(live, "o-busy"), swings = sweeps(live, "o-busy")
    let ball = piece(live, "o-busy", "ball")
    check(
        "office: ...three laser rays in hot pink, cyan and lime run from the ball's middle to the floor at 55%, a dot at each tip, each swinging there and back in its own 6–10 s",
        OfficeView.lasers.count == 3 && rays.count == 3 && swings.count == 3 && Set(OfficeView.lasers.map(\.seconds)).count == 3
            && OfficeView.lasers.allSatisfy { (6...10).contains($0.seconds) } && Set(OfficeView.lasers.map(\.colour)) == [0xFF4FB4, 0x4FF0FF, 0xB8FF4F]
            && rays.allSatisfy { ray in
                let line = ray.sublayers?.first { $0.name == "ray" }, tip = ray.sublayers?.first { $0.name == "tip" }
                return line?.contents != nil && line?.opacity == 0.55 && tip?.contents != nil && abs(ray.bounds.width - 5.5) < 0.01
                    && abs(ray.position.y - ((ball?.position.y ?? 0) - 8)) < 0.01 && ray.position.x == 0 && ray.bounds.height > 40
            }
            && zip(swings, OfficeView.lasers).allSatisfy { sweep, laser in
                // There and back in its period, in steps on the beat, eased at each end (a middle step is the largest).
                let steps = sweep.values?.compactMap { ($0 as? NSNumber)?.doubleValue } ?? []
                let moves = zip(steps, steps.dropFirst()).map { abs($1 - $0) }
                return sweep.keyPath == "transform.rotation.z" && sweep.isAdditive && onBeat(sweep) && abs(sweep.duration - laser.seconds) <= 1.0 / 24
                    && steps.count > 12 && (moves.max() ?? 0) > 2 * (moves.first ?? 1)
            })
    let loops = drifts(live, "o-busy")
    // Added to where it rests, the values are its loop: closed, and through its resting place at its own start.
    let closed = drawn("o-busy").map { d in
        zip(zip(loops, table), spots(live, "o-busy")).allSatisfy { pair, layer in
            let (loop, spot) = pair
            let values = loop.values?.compactMap { ($0 as? NSValue)?.pointValue } ?? []
            return values.count == OfficeView.beats(spot.seconds) && near(layer.position, OfficeView.place(spot, at: spot.phase, wide: d.wide, high: d.high))
                && values.enumerated().allSatisfy { k, v in
                    near(CGPoint(x: layer.position.x + v.x, y: layer.position.y + v.y),
                         OfficeView.place(spot, at: Double(k) / Double(values.count), wide: d.wide, high: d.high), 0.01)
                }
        }
    } ?? false
    check(
        "office: ...and each spot goes round its loop a twelfth of a second a step on the beat, from where it rests and back, round and round, each in its own time from its own start",
        (4...5).contains(table.count) && loops.count == table.count && closed && loops.allSatisfy { $0.keyPath == "position" && onBeat($0) && $0.isAdditive }
            && zip(loops, table).allSatisfy { abs($0.duration - $1.seconds) <= 1.0 / 24 && abs($0.timeOffset - $1.phase * $1.seconds) <= 1.0 / 24 }
            && Set(loops.map(\.duration)).count == table.count && Set(loops.map(\.timeOffset)).count == table.count)
    // Seen moving: where the spots and the ball are now, and a moment later.
    until(0.1)
    let ballThen = piece(live, "o-busy", "ball")?.presentation()?.contents as AnyObject?
    let then = spots(live, "o-busy").map { $0.presentation()?.position ?? .zero }, thenAt = Date()
    until(1.3)
    let ballNow = piece(live, "o-busy", "ball")?.presentation()?.contents as AnyObject?
    let now = spots(live, "o-busy").map { $0.presentation()?.position ?? .zero }, elapsed = CGFloat(Date().timeIntervalSince(thenAt))
    let shifts = zip(then, now).map { hypot($1.x - $0.x, $1.y - $0.y) }
    // No further than its loop's fastest pace for this pet's size allows in the time that really passed (a busy machine can
    // run the loop long): however large the pet dealt, and however slow the machine.
    let paces = drawn("o-busy").map { d in
        table.map { spot -> CGFloat in
            let points = (0...96).map { OfficeView.place(spot, at: Double($0) / 96, wide: d.wide, high: d.high) }
            return zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }.max().map { $0 / CGFloat(spot.seconds / 96) } ?? 0
        }
    } ?? []
    print(
        String(format: "      in %.2f s the spots moved by ", elapsed) + shifts.map { String(format: "%.1f", $0) }.joined(separator: ", ")
            + " pt (at most " + paces.map { String(format: "%.0f", $0 * elapsed) }.joined(separator: ", ") + ")")
    check(
        "office: ...on screen they move: 1.2 s later every spot is somewhere else, no faster than its loop allows, and the ball shows another picture",
        shifts.count == table.count && paces.count == table.count && zip(shifts, paces).allSatisfy { shift, pace in
            let most: CGFloat = pace * 1.15 * (elapsed + 1.0 / 12) + 1  // one step more: it moves a beat at a time
            return shift > 0.5 && shift <= most
        }
            && ballThen != nil && ballNow != nil && ballThen !== ballNow)
    // Orca to the back: all of it at half, and held where it is (the window server need not draw it anew); forward
    // again, it goes on. The same while the window is hidden or covered.
    func held(_ view: NSView, _ id: String) -> Bool {
        let parts = [piece(view, id, "ball")].compactMap { $0 } + spots(view, id) + lasers(view, id)
        return parts.count == 1 + table.count + 3 && parts.allSatisfy { $0.speed == 0 }
    }
    func going(_ view: NSView, _ id: String) -> Bool {
        let parts = [piece(view, id, "ball")].compactMap { $0 } + spots(view, id) + lasers(view, id)
        return parts.count == 1 + table.count + 3 && parts.allSatisfy { $0.speed == 1 && abs($0.beginTime * 12 - ($0.beginTime * 12).rounded()) < 0.001 }
    }
    let goingFirst = going(live, "o-busy")
    store.orcaInFront = false
    live.update(store)
    until(0.5) { beam(live, "o-busy")?.animation(forKey: "fade") == nil }
    let backHeld = held(live, "o-busy"), heldAt = spots(live, "o-busy").map { $0.presentation()?.position ?? .zero }
    until(0.4)
    let stayed = zip(heldAt, spots(live, "o-busy").map { $0.presentation()?.position ?? .zero }).allSatisfy { $0 == $1 }
    check(
        "office: with Orca in the background the ball, spots and lasers are at half strength with the beam, held where they are, their loops kept",
        goingFirst && beam(live, "o-busy")?.opacity == 0.5 && backHeld && stayed && moving(live, "o-busy") && turning(live, "o-busy") === turn)
    store.orcaInFront = true
    live.update(store)
    let frontAgain = going(live, "o-busy") && turning(live, "o-busy") === turn
    live.shownOnScreen = false
    live.update(store)
    let hidden = held(live, "o-busy")
    live.shownOnScreen = true
    live.update(store)
    check(
        "office: ...with Orca in front again they go on from there, on the beat; held while the window is hidden or covered, going on when it shows",
        frontAgain && hidden && going(live, "o-busy") && moving(live, "o-busy"))
    // Every pass of the room puts the light's size in again: that must not start the loops again.
    until(0.5) { beam(live, "o-busy")?.animation(forKey: "fade") == nil }
    let before = drifts(live, "o-busy")
    live.update(store)
    check(
        "office: ...a pass of the room with nothing new for the light leaves its loops as they are",
        before.count == table.count && !before.isEmpty && zip(before, drifts(live, "o-busy")).allSatisfy { $0 === $1 } && turn != nil
            && turning(live, "o-busy") === turn)
    // Reduce Motion: the ball on its first picture, the spots where they rest; off again, they go on.
    live.calmed = true
    live.update(store)
    let calmBall = piece(live, "o-busy", "ball")?.contents as AnyObject?
    let calmSpots = drawn("o-busy").map { d in
        zip(table, spots(live, "o-busy")).allSatisfy { near($1.position, OfficeView.place($0, at: $0.phase, wide: d.wide, high: d.high)) }
    } ?? false
    let calmStill = animated(beam(live, "o-busy")).filter { $0 != "fade" }.isEmpty
    let calmRays = lasers(live, "o-busy").map { ($0.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? .nan }
    // Each at its middle: that share of the turn that would take it eight tenths of the way to the cone's edge at the feet.
    let calmMiddle = drawn("o-busy").map { d in
        let from = Double(-((piece(live, "o-busy", "ball")?.position.y ?? 0) - 8)), reach = atan(0.8 * Double(OfficeView.lightWide * d.wide) / 2 / from)
        return zip(calmRays, OfficeView.lasers).allSatisfy { abs($0 - Double($1.middle) * reach) < 0.0001 } && reach > 0.1
    } ?? false
    live.calmed = false
    live.update(store)
    check(
        "office: with Reduce Motion the ball shows its first picture, the spots stay where they start and the lasers at their middles, nothing turning; without it again, they go on",
        calmStill && calmBall === studio.first && calmSpots && calmRays.count == 3 && calmMiddle && moving(live, "o-busy"))
    // Another look while lit: its own ball, turning through its own pictures.
    OfficeTheme.shown = OfficeTheme.night
    live.update(store)
    let nightBall = piece(live, "o-busy", "ball")?.contents as AnyObject?, nightTurn = turning(live, "o-busy")
    OfficeTheme.shown = nil
    live.update(store)
    check(
        "office: switched to warm-night while lit, the ball is warm-night's and turns through warm-night's pictures; back in slate, slate's",
        nightBall != nil && nightBall === night.first && (nightTurn?.values?.first as AnyObject?) === night.first
            && (turning(live, "o-busy")?.values?.first as AnyObject?) === studio.first)
    // Put out and lit again: the new light has its ball and spots, painted and turning.
    store.focused = "o-seen"
    live.update(store)
    until(1) { beam(live, "o-busy") == nil }
    let out = beam(live, "o-busy") == nil
    store.focused = "o-busy"
    live.update(store)
    check(
        "office: lit again after its light had gone, the new light has its ball and spots painted, and they turn",
        out && piece(live, "o-busy", "ball")?.contents != nil && spots(live, "o-busy").allSatisfy { $0.contents != nil }
            && lasers(live, "o-busy").allSatisfy { $0.sublayers?.allSatisfy { $0.contents != nil } ?? false } && moving(live, "o-busy"))
    // Out of the window and back: the loops come back with it.
    live.removeFromSuperview()
    let away = !moving(live, "o-busy")
    window.contentView = live
    live.update(store)
    check("office: taken out of its window the ball and spots stop; back in it they turn again", away && moving(live, "o-busy"))
    if review, let p = place("o-busy"), let d = drawn("o-busy") {
        // Six moments, 2 s apart, cut round the lit pet as the layers show it: how the ball and the spots move.
        until(3)
        let box = fit.rect(CGRect(x: p.x - 70, y: p.foot - d.high - 72 - 40, width: 140, height: d.high + 72 + 70))
        var cuts: [CGImage] = []
        for i in 0..<6 {
            if i > 0 { until(2) }
            if let moment = officeMoment(live, pixels: 2),
                let cut = moment.cropping(to: CGRect(x: box.minX * 2, y: box.minY * 2, width: box.width * 2, height: box.height * 2))
            {
                cuts.append(cut)
            }
        }
        let strip = OfficeCanvas(CGSize(width: box.width * 6 + 25, height: box.height + 18))
        strip.fill(0, 0, box.width * 6 + 25, box.height + 18, 0x101010)
        for (i, cut) in cuts.enumerated() {
            let x = CGFloat(i) * (box.width + 5)
            strip.ctx.saveGState()
            strip.ctx.translateBy(x: x, y: 18 + box.height)
            strip.ctx.scaleBy(x: 1, y: -1)
            strip.ctx.draw(cut, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
            strip.ctx.restoreGState()
            strip.text("\(i * 2) s", in: CGRect(x: x + 4, y: 1, width: 60, height: 14), size: 10, 0xFFFFFF)
        }
        save(strip.image(), "/tmp/office-ball-strip.png")
    }
    // Its pet drawn another size (o-busy starts waiting and walks to the queue, in another pose there): loops drawn round its size
    // there, new ones if the size changed, the same ones if it did not.
    let wasLoops = drifts(live, "o-busy"), atDesk = drawn("o-busy")
    store.sessions = store.sessions.map { $0.id == "o-busy" ? officeSession("o-busy", "waiting", finished: 1) : $0 }
    live.update(store)
    if let d = drawn("o-busy"), let was = atDesk, let spot = table.first, let loop = drifts(live, "o-busy").first, let p = place("o-busy"), p.zone == .queue {
        let steps = loop.values?.count ?? 0, k = steps / 4
        let rest = OfficeView.place(spot, at: spot.phase, wide: d.wide, high: d.high)
        let quarter = OfficeView.place(spot, at: Double(k) / Double(max(1, steps)), wide: d.wide, high: d.high)
        let value = (steps > k ? loop.values?[k] as? NSValue : nil)?.pointValue ?? .zero, resized = was.wide != d.wide || was.high != d.high
        print(String(format: "      the lit pet drawn %.1f×%.1f pt at its desk, %.1f×%.1f in the queue", was.wide, was.high, d.wide, d.high))
        check(
            "office: one lit that walks to the queue has its spots' loops drawn round the size it is drawn there (new ones only if that changed)",
            resized == (loop !== wasLoops.first) && near(value, CGPoint(x: quarter.x - rest.x, y: quarter.y - rest.y), 0.01) && moving(live, "o-busy"))
    } else {
        check("office: one lit that walks to the queue has its spots' loops drawn round the size it is drawn there (new ones only if that changed)", false)
    }
    store.focused = nil
    if !dealt { print("      (pets in these checks are grey blocks: too few cut frames)") }
}

/// Not a check: what the light costs this process at rest. With `OFFICE_CPU` set the checks are skipped; the panel's own
/// view, in a window the size of the user's off the screen, sits 20 s with the light on its pet (ball turning, spots going round) and 20 s
/// with it off, while `top` watches the process once a second. Prints `top`'s readings and the process's own CPU time.
@MainActor func officeDiscoCost() {
    let size = CGSize(width: 1180, height: 790)
    let store = officeStore()
    _ = officeDealCutPets(store)
    NSApplication.shared.setActivationPolicy(.accessory)
    let live = OfficeView(frame: CGRect(origin: .zero, size: size))
    live.note = { _ in }
    let window = NSWindow(
        contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = live
    window.orderFrontRegardless()
    live.listen()
    defer {
        live.stopListening()
        window.orderOut(nil)
        window.contentView = nil
    }
    func rest(_ seconds: Double) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.current.run(until: until) }
    }
    func used() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
    func measure(_ what: String) {
        let top = Process(), out = Pipe()
        top.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        top.arguments = ["-pid", "\(getpid())", "-l", "21", "-s", "1", "-stats", "pid,cpu"]
        top.standardOutput = out
        let cpu = used(), start = Date()
        try? top.run()
        while top.isRunning { rest(0.5) }
        let seconds = Date().timeIntervalSince(start), spent = used() - cpu
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        // The first reading has nothing before it to compare with.
        let readings = text.split(separator: "\n").compactMap { line -> Double? in
            let parts = line.split(separator: " ")
            return parts.count == 2 && parts[0] == "\(getpid())" ? Double(parts[1]) : nil
        }.dropFirst()
        let mean = readings.isEmpty ? 0 : readings.reduce(0, +) / Double(readings.count)
        print(
            String(
                format: "%@: top -pid over %.0f s: mean %.2f%%, highest %.1f%% (%d readings: %@); own CPU time %.3f s = %.2f%%", what, seconds, mean,
                readings.max() ?? 0, readings.count, readings.map { String(format: "%.1f", $0) }.joined(separator: " "), spent, 100 * spent / seconds))
    }
    print("pid \(getpid()); Reduce Motion \(live.calm ? "on: nothing turns" : "off")")
    live.update(store)
    rest(3)
    store.focused = "o-busy"
    live.update(store)
    rest(2)
    let ball = officePart(live, "o-busy", "beam")?.sublayers?.first { $0.name == "ball" }
    print("light on: the ball \(ball?.animation(forKey: "turn") != nil ? "turns" : "does not turn")")
    measure("light on ")
    store.focused = nil
    live.update(store)
    rest(2)
    print("light off: beam \(officePart(live, "o-busy", "beam") == nil ? "gone" : "still there")")
    measure("light off")
}

// ───────── Codex CLI sessions ─────────

/// One line of a Codex rollout as Codex writes it: when, what kind, and its payload, the payload's own kind first.
func codexLine(_ at: String, _ type: String, _ payload: String) -> String {
    "{\"timestamp\":\"\(at)\",\"ordinal\":1,\"type\":\"\(type)\",\"payload\":{\(payload)}}\n"
}

func codexMeta(_ at: String) -> String {
    codexLine(at, "session_meta", "\"session_id\":\"s\",\"cwd\":\"/tmp\",\"originator\":\"codex-tui\",\"cli_version\":\"0.160.1\"")
}

func codexStarted(_ at: String) -> String { codexLine(at, "event_msg", "\"type\":\"task_started\",\"turn_id\":\"turn-\(at)\"") }

func codexComplete(_ at: String) -> String {
    codexLine(at, "event_msg", "\"type\":\"task_complete\",\"turn_id\":\"turn\",\"last_agent_message\":\"做完了\"")
}

func codexAborted(_ at: String) -> String { codexLine(at, "event_msg", "\"type\":\"turn_aborted\",\"turn_id\":\"turn\",\"reason\":\"interrupted\"") }

/// A message in the conversation; `text` is written into the JSON as it is (a newline is `\\n`).
func codexSaid(_ at: String, _ text: String, role: String = "assistant") -> String {
    let kind = role == "assistant" ? "output_text" : "input_text"
    return codexLine(
        at, "response_item", "\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"\(role)\",\"content\":[{\"type\":\"\(kind)\",\"text\":\"\(text)\"}]")
}

/// A tool's output, the bulk of a rollout: one line of `bytes` filler.
func codexToolOutput(_ at: String, bytes: Int) -> String {
    codexLine(at, "response_item", "\"type\":\"custom_tool_call_output\",\"call_id\":\"call_1\",\"output\":\"" + String(repeating: "x", count: bytes) + "\"")
}

/// The path the kernel names a file by: the temporary folders are under /private.
func codexRealPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Codex's thread table made for a check: the columns the panel reads, by their real names, in WAL mode as Codex keeps it.
/// The connection stays open, writing, while the panel reads.
final class CodexFixtureDatabase {
    let db: OpaquePointer

    init?(_ path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { return nil }
        db = handle
        run("PRAGMA journal_mode=WAL")
        run(
            "CREATE TABLE threads (id TEXT PRIMARY KEY, rollout_path TEXT NOT NULL, created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL, "
                + "source TEXT NOT NULL, cwd TEXT NOT NULL, title TEXT NOT NULL, archived INTEGER NOT NULL DEFAULT 0, model TEXT, name TEXT)")
    }

    deinit { sqlite3_close(db) }

    func run(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// `source` as Codex writes it: "cli" for the terminal's own threads, "exec" for one-shot runs, "vscode" for those an
    /// app or a plugin (Claude Code's) drives.
    func add(
        _ id: String, rollout: String, cwd: String, title: String, name: String? = nil, model: String? = nil, updated: Double, archived: Bool = false,
        source: String = "cli"
    ) {
        func quoted(_ s: String?) -> String { s.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" } ?? "NULL" }
        run(
            "INSERT INTO threads (id, rollout_path, created_at, updated_at, source, cwd, title, archived, model, name) VALUES (\(quoted(id)), "
                + "\(quoted(rollout)), \(Int(updated) - 600), \(Int(updated)), \(quoted(source)), \(quoted(cwd)), \(quoted(title)), \(archived ? 1 : 0), "
                + "\(quoted(model)), \(quoted(name)))")
    }
}

/// Codex CLI sessions in Orca's panes are sessions here too: which processes count, what a thread is called, where
/// its rollout stands, which thread a process is on, the tag that says it is Codex's, and what all that costs a tick.
@MainActor func codexTests() {
    let review = ProcessInfo.processInfo.environment["OFFICE_PNGS"] != nil
    let files = FileManager.default
    let scratch = codexRealPath(NSTemporaryDirectory()) + "/codex-tests-\(getpid())"
    try? files.removeItem(atPath: scratch)
    try? files.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(atPath: scratch) }
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func write(_ path: String, _ text: String) { files.createFile(atPath: path, contents: Data(text.utf8)) }
    func append(_ path: String, _ text: String) {
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }

    // Which processes are sessions the user types in.
    let vendor = "/u/.nvm/versions/node/v22.0.0/lib/node_modules/@openai/codex/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/bin/"
    let app = "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
    let table: [([String], Bool)] = [
        ([vendor + "codex", "--no-daemon", "resume"], true), ([vendor + "codex"], true), ([vendor + "codex", "改一下风车"], true),
        ([vendor + "codex", "-m", "gpt-6-astra", "resume", "--last"], true),
        ([vendor + "codex", "app-server"], false), ([app, "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"], false),
        ([app, "exec-server", "--remote", "https://example.com/api"], false), ([vendor + "codex", "exec", "--json", "跑测试"], false),
        ([vendor + "codex", "e", "跑测试"], false), ([vendor + "codex", "mcp-server"], false), ([vendor + "codex", "mcp", "list"], false),
        ([vendor + "codex-code-mode-host"], false), (["node", "/u/.nvm/versions/node/v22.0.0/bin/codex", "--no-daemon", "resume"], false),
    ]
    let misjudged = table.filter { codexInteractive($0.0) != $0.1 }.map { $0.0.joined(separator: " ") }
    check(
        "codex: a codex process he types in counts, bare, resumed or with a prompt; app-server, exec-server, exec, mcp, the code-mode host and "
            + "the node wrapper do not" + (misjudged.isEmpty ? "" : " (wrong: \(misjudged))"),
        misjudged.isEmpty)

    // What a thread is called.
    check("codex: a thread he named goes by that name", codexName(name: "摘星星", title: "读下交接\n然后改") == "摘星星")
    check(
        "codex: otherwise by the first line of its first message",
        codexName(name: nil, title: "读下交接文档\n然后继续") == "读下交接文档" && codexName(name: "", title: "\n  读下  \n后面") == "读下")
    check("codex: ...cut at 24 characters", codexName(name: nil, title: String(repeating: "长", count: 30) + "\n第二行") == String(repeating: "长", count: 24))
    check("codex: with neither, the untitled default name", codexName(name: nil, title: "") == "未命名")

    // Where a rollout stands: the last turn event says busy or idle, and since when; the agent's last words are its summary.
    let rollout = scratch + "/rollout-status.jsonl"
    let t1 = "2026-10-08T03:43:35.780Z", t2 = "2026-10-08T03:43:39.920Z", t3 = "2026-10-08T03:46:58.100Z", t4 = "2026-10-08T03:47:00.004Z"
    write(
        rollout,
        codexMeta(t1) + codexStarted(t1) + codexSaid(t2, "先看看交接文档") + codexToolOutput(t2, bytes: 120_000)
            + codexSaid(t3, "## 改好了\\n**三处**都改了，`build` 通过\\n\\n细节在下面") + codexComplete(t4))
    var tail = CodexTail.read(rollout, after: nil, now: Date())
    check(
        "codex: a turn that ended is idle since its task_complete, and says the first line of the agent's last words",
        tail.status == "idle" && tail.since == iso.date(from: t4) && tail.summary == "改好了")
    let t5 = "2026-10-08T04:28:42.778Z", t6 = "2026-10-08T04:28:51.383Z", t7 = "2026-10-08T04:30:30.863Z"
    append(
        rollout,
        codexStarted(t5) + codexSaid(t5, "接着改第二处", role: "user") + codexSaid(t6, "我先改第二处") + codexToolOutput(t6, bytes: 450_000)
            + codexSaid(t7, "他又说了一句", role: "user") + codexToolOutput(t7, bytes: 300_000))
    tail = CodexTail.read(rollout, after: tail, now: Date())
    check(
        "codex: a turn started more than 400 KB of tool output ago is busy since its task_started: the rollout is read back past a fixed tail",
        tail.status == "busy" && tail.since == iso.date(from: t5))
    check("codex: ...its words are the agent's latest, not his", tail.summary == "我先改第二处")
    let whole = CodexTail.read(rollout, after: nil, now: Date())
    check(
        "codex: ...the same on a first look at the whole file",
        whole.status == "busy" && whole.since == iso.date(from: t5) && whole.summary == "我先改第二处")
    let t8 = "2026-10-08T04:31:48.124Z", t9 = "2026-10-08T04:31:48.289Z"
    append(rollout, codexSaid(t8, "第二处也好了") + codexComplete(t9))
    let soon = CodexTail.read(rollout, after: tail, now: tail.parsedAt.addingTimeInterval(3))
    let later = CodexTail.read(rollout, after: tail, now: tail.parsedAt.addingTimeInterval(11))
    check(
        "codex: a busy rollout is read again at most every 10 s: still busy 3 s on, idle since its task_complete 11 s on",
        soon.status == "busy" && later.status == "idle" && later.since == iso.date(from: t9) && later.summary == "第二处也好了")
    let t10 = "2026-10-08T04:35:05.228Z", t11 = "2026-10-08T04:35:39.956Z"
    append(rollout, codexStarted(t10) + codexToolOutput(t10, bytes: 20_000) + codexAborted(t11))
    let stopped = CodexTail.read(rollout, after: later, now: Date())
    check(
        "codex: a turn he interrupted is idle since its turn_aborted, and keeps the last words said before it",
        stopped.status == "idle" && stopped.since == iso.date(from: t11) && stopped.summary == "第二处也好了")
    let t12 = "2026-10-08T04:47:53.929Z"
    append(rollout, String(codexStarted(t12).dropLast()))
    let writing = CodexTail.read(rollout, after: stopped, now: Date())
    append(rollout, "\n")
    let written = CodexTail.read(rollout, after: writing, now: Date())
    check(
        "codex: a line still being written counts once its newline is there",
        writing.status == "idle" && written.status == "busy" && written.since == iso.date(from: t12))
    let marked = scratch + "/rollout-marked.jsonl"
    write(marked, codexMeta(t1) + codexStarted(t1) + codexSaid(t2, "〔进度〕说明改到第三处\\n别的先不管") + codexComplete(t4))
    check(
        "codex: a progress line in the agent's words, marked in 〔 〕 brackets, is its summary, as with Claude Code",
        CodexTail.read(marked, after: nil, now: Date()).summary == "说明改到第三处")
    let quiet = scratch + "/rollout-quiet.jsonl"
    write(quiet, codexMeta(t1))
    let nothing = CodexTail.read(quiet, after: nil, now: Date())
    append(quiet, codexStarted(t2))
    let begun = CodexTail.read(quiet, after: nothing, now: Date())
    check(
        "codex: a rollout with no turn yet is idle, with nothing to say and no time of its own; its first task_started makes it busy",
        nothing.status == "idle" && nothing.since == nil && nothing.summary.isEmpty && begun.status == "busy" && begun.since == iso.date(from: t2))

    // Which thread a process is on: the rollout it has open, by the kernel's list of its files (this process opens the
    // fixtures itself); without one, its folder's newest thread used since it started. Codex's database stays as it was.
    let codexHome = scratch + "/home", day = codexHome + "/sessions/2026/10/08"
    try? files.createDirectory(atPath: day, withIntermediateDirectories: true)
    let ids = [
        "01a10006-0000-7000-8000-000000000006", "01a10003-0000-7000-8000-000000000003", "01a10005-0000-7000-8000-000000000005",
        "01a10004-0000-7000-8000-000000000004", "01a10002-0000-7000-8000-000000000002", "01a10001-0000-7000-8000-000000000001",
    ]
    func rolloutOf(_ id: String) -> String { day + "/rollout-2026-10-08T11-43-02-\(id).jsonl" }
    for id in ids { write(rolloutOf(id), codexMeta(t1) + codexStarted(t1) + codexSaid(t2, "在 \(id.prefix(8)) 上干活") + codexComplete(t4)) }
    let here = processCwd(getpid()) ?? codexRealPath(files.currentDirectoryPath)
    // A folder that only holds projects (`projectContainers`) is left out of the project's name.
    let containersBefore = projectContainers
    projectContainers = ["containers"]
    defer { projectContainers = containersBefore }
    let now = Date(), started = now.timeIntervalSince1970 - 60, project = home + "/Projects/containers/demo-a/demo-b"
    guard let database = CodexFixtureDatabase(codexHome + "/state_5.sqlite") else {
        check("codex: a fixture database can be made", false)
        return
    }
    database.add(ids[0], rollout: rolloutOf(ids[0]), cwd: project, title: "读交接\n然后改", name: "摘星星", model: "gpt-6-astra", updated: now.timeIntervalSince1970)
    database.add(ids[1], rollout: rolloutOf(ids[1]), cwd: here, title: "第一句\n第二句", updated: now.timeIntervalSince1970 - 30)
    database.add(ids[2], rollout: rolloutOf(ids[2]), cwd: here, title: "归档了", updated: now.timeIntervalSince1970 - 5, archived: true)
    database.add(ids[3], rollout: rolloutOf(ids[3]), cwd: here, title: "更早的", updated: now.timeIntervalSince1970 - 3000)
    let me = getpid()
    let reader = CodexSessions()
    reader.processes = { [CodexProcess(pid: me, start: started, home: codexHome)] }
    var held = FileHandle(forReadingAtPath: rolloutOf(ids[0]))
    var found = reader.load(now: now)
    let first = found.first
    check(
        "codex: a process with a rollout open is that rollout's thread: its id and pid, the name he gave it, its folder's project, kind codex",
        found.count == 1 && first?.id == ids[0] && first?.pid == me && first?.name == "摘星星" && first?.project == "demo-a/demo-b"
            && projectName(home + "/Projects/demo-c/x") == "demo-c/x" && projectName(home + "/Projects/other/x") == "other/x"
            && first?.cwd == project && first?.kind == "codex")
    check(
        "codex: ...idle since its turn ended, saying the agent's last words, never waiting; its model kept for the office card",
        first?.status == "idle" && first?.since == iso.date(from: t4) && first?.summary == "在 01a10006 上干活" && first?.waitingFor == ""
            && reader.model(of: ids[0]) == "gpt-6-astra")
    try? held?.close()
    found = reader.load(now: now)
    check(
        "codex: with no rollout open, the newest thread in its folder that is not archived and was used since it started",
        found.map(\.id) == [ids[1]] && found.first?.name == "第一句" && reader.model(of: ids[1]) == nil)
    let newcomer = CodexSessions(), oldtimer = CodexSessions()
    newcomer.processes = { [CodexProcess(pid: me, start: now.timeIntervalSince1970, home: codexHome)] }
    oldtimer.processes = { [CodexProcess(pid: me, start: now.timeIntervalSince1970 - 40, home: codexHome)] }
    check(
        "codex: ...and none for one started after its folder's threads were last used: it has not said anything yet",
        newcomer.load(now: now).isEmpty && oldtimer.load(now: now).map(\.id) == [ids[1]])
    // Not in this process's folder: only the rollout it has open can find this one, once its files are listed again.
    database.add(ids[4], rollout: rolloutOf(ids[4]), cwd: project, title: "后来的", updated: now.timeIntervalSince1970)
    held = FileHandle(forReadingAtPath: rolloutOf(ids[4]))
    found = reader.load(now: now.addingTimeInterval(11))
    check(
        "codex: a thread Codex adds while its database is open is found by the rollout the process opens next",
        found.map(\.id) == [ids[4]] && found.first?.name == "后来的")
    try? held?.close()
    // The database may spell a rollout's path another way (/var for /private/var): the thread id in the file's name finds it.
    database.add(
        ids[5], rollout: rolloutOf(ids[5]).replacingOccurrences(of: "/private/var/", with: "/var/"), cwd: project, title: "换个路径",
        updated: now.timeIntervalSince1970)
    func stamp(_ path: String) -> String {
        let a = try? files.attributesOfItem(atPath: path)
        return "\((a?[.size] as? NSNumber)?.intValue ?? -1) \((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }
    let before = (["/state_5.sqlite", "/state_5.sqlite-wal"].map { stamp(codexHome + $0) }, (try? files.contentsOfDirectory(atPath: codexHome)) ?? [])
    held = FileHandle(forReadingAtPath: rolloutOf(ids[5]))
    found = reader.load(now: now)
    _ = reader.load(now: now.addingTimeInterval(12))
    check("codex: ...or by the thread id in the rollout's file name", found.map(\.id) == [ids[5]])
    try? held?.close()
    let after = (["/state_5.sqlite", "/state_5.sqlite-wal"].map { stamp(codexHome + $0) }, (try? files.contentsOfDirectory(atPath: codexHome)) ?? [])
    check(
        "codex: reading leaves Codex's database and its log as they were, and adds no file to its home",
        found.count == 1 && before.0 == after.0 && before.1.sorted() == after.1.sorted() && !before.0.contains { $0.hasPrefix("-1") })
    let nowhere = CodexSessions()
    nowhere.processes = { [CodexProcess(pid: me, start: started, home: scratch + "/nowhere"), CodexProcess(pid: me, start: started, home: codexHome)] }
    check(
        "codex: a CODEX_HOME without a database gives nothing, and none is made; the same process under another home is found",
        nowhere.load(now: now).map(\.id) == [ids[1]] && !files.fileExists(atPath: scratch + "/nowhere"))
    held = FileHandle(forReadingAtPath: rolloutOf(ids[0]))
    let stillThere = reader.load(now: now).map(\.id) == [ids[0]] && reader.model(of: ids[0]) == "gpt-6-astra"
    try? held?.close()
    reader.processes = { [] }
    check("codex: when its process has gone, so has the session, and its model", stillThere && reader.load(now: now).isEmpty && reader.model(of: ids[0]) == nil)

    // Two panes in one folder: A works in its thread, B has just been opened (listed first, as the kernel lists
    // the newest first). The folder also holds a thread Claude Code's Codex plugin drives and a `codex exec` run's.
    let panes = scratch + "/panes", paneDay = panes + "/sessions/2026/10/08"
    try? files.createDirectory(atPath: paneDay, withIntermediateDirectories: true)
    guard let paneBase = CodexFixtureDatabase(panes + "/state_5.sqlite") else {
        check("codex: a fixture database can be made", false)
        return
    }
    let paneIDs = [
        "01a2000a-0000-7000-8000-00000000000a", "01a2000b-0000-7000-8000-00000000000b", "01a2000c-0000-7000-8000-00000000000c",
        "01a2000d-0000-7000-8000-00000000000d", "01a2000e-0000-7000-8000-00000000000e",
    ]
    func paneRollout(_ id: String) -> String { paneDay + "/rollout-2026-10-08T12-00-00-\(id).jsonl" }
    for id in paneIDs { write(paneRollout(id), codexMeta(t1) + codexStarted(t5) + codexSaid(t6, "在 \(id.prefix(8)) 上干活")) }
    paneBase.add(paneIDs[0], rollout: paneRollout(paneIDs[0]), cwd: here, title: "A 在干活", updated: now.timeIntervalSince1970)
    paneBase.add(paneIDs[1], rollout: paneRollout(paneIDs[1]), cwd: here, title: "插件的", updated: now.timeIntervalSince1970, source: "vscode")
    paneBase.add(paneIDs[2], rollout: paneRollout(paneIDs[2]), cwd: here, title: "exec 的", updated: now.timeIntervalSince1970, source: "exec")
    let paneA: Int32 = 900_100
    let twoPanes = CodexSessions()
    twoPanes.processes = { [CodexProcess(pid: me, start: started, home: panes), CodexProcess(pid: paneA, start: started, home: panes)] }
    twoPanes.rollout = { $0 == paneA ? paneRollout(paneIDs[0]) : nil }
    let pair = twoPanes.load(now: now)
    check(
        "codex: two panes in one folder: the one with its rollout open keeps its own thread under its own pid; the new one, with "
            + "only a plugin's and an exec run's threads left, is nobody",
        pair.count == 1 && pair.first?.id == paneIDs[0] && pair.first?.pid == paneA && pair.first?.status == "busy")
    paneBase.add(paneIDs[3], rollout: paneRollout(paneIDs[3]), cwd: here, title: "B 的新线程", updated: now.timeIntervalSince1970)
    let pairLater = twoPanes.load(now: now.addingTimeInterval(11)).sorted { $0.pid < $1.pid }
    check(
        "codex: ...and once there is a terminal thread in the folder nobody holds, the new one takes it",
        pairLater.map(\.id) == [paneIDs[3], paneIDs[0]] && pairLater.map(\.pid) == [me, paneA])
    // A rollout open whose row is not in the index yet: nothing until it is, not a thread from the folder.
    let unindexed = CodexSessions()
    unindexed.processes = { [CodexProcess(pid: me, start: started, home: panes)] }
    held = FileHandle(forReadingAtPath: paneRollout(paneIDs[4]))
    let early = unindexed.load(now: now)
    try? held?.close()
    check("codex: a process whose open rollout has no row yet is nobody until it has: it never borrows a thread from its folder", early.isEmpty)
    // The index cannot be asked for a while (here its table is renamed away): the thread known stays, for up to 5 minutes.
    let steady = CodexSessions()
    steady.processes = { [CodexProcess(pid: paneA, start: started, home: panes)] }
    steady.rollout = { $0 == paneA ? paneRollout(paneIDs[0]) : nil }
    let known = steady.load(now: now).map(\.id)
    paneBase.run("ALTER TABLE threads RENAME TO threads_away")
    let failing = steady.load(now: now.addingTimeInterval(11)).map(\.id), longFailing = steady.load(now: now.addingTimeInterval(400)).map(\.id)
    paneBase.run("ALTER TABLE threads_away RENAME TO threads")
    let back = steady.load(now: now.addingTimeInterval(401)).map(\.id)
    check(
        "codex: when its index cannot be read, a session keeps its thread rather than blinking out; after 5 minutes it goes; it comes back with the index",
        known == [paneIDs[0]] && failing == [paneIDs[0]] && longFailing.isEmpty && back == [paneIDs[0]])
    // A turn whose output since its start is longer than a first look reads back: still running, not finished.
    let long = scratch + "/rollout-long.jsonl"
    write(long, codexMeta(t1) + codexStarted(t1) + codexSaid(t2, "开始了") + codexToolOutput(t2, bytes: 300_000) + codexToolOutput(t3, bytes: 300_000))
    let capped = CodexTail.read(long, after: nil, now: Date(), farthest: 200_000)
    let uncapped = CodexTail.read(long, after: nil, now: Date(), farthest: 2_000_000)
    check(
        "codex: a turn running longer than a first look reads back is busy, not idle",
        capped.status == "busy" && uncapped.status == "busy" && uncapped.since == iso.date(from: t1))

    // The tag: Codex after the name on the board's card, the office's card and the office's plates; never for Claude Code.
    let claude = officeSession("k-tag", "busy", finished: 60, name: "摘星星")
    var codex = claude
    codex.kind = "codex"
    check(
        "codex: the kind tag says Codex for a Codex session, >_ on a name plate, and nothing for Claude Code's",
        kindTag(codex) == "Codex" && kindTag(codex, short: true) == ">_" && kindTag(claude) == nil && kindTag(claude, short: true) == nil
            && claude.kind == "claude")
    let board = Store()
    board.readOnly = true
    board.sessions = [claude]
    board.pinned = []
    func render<V: View>(_ view: V) -> CGImage? {
        let renderer = ImageRenderer(
            content: view.fixedSize(horizontal: false, vertical: true).environmentObject(board).environment(\.zoom, 1).environment(\.still, true)
                .environment(\.colorScheme, .dark).background(night))
        renderer.scale = 2
        return renderer.cgImage
    }
    // The board's bubble starts 67 in (pet 50, tail 7, padding 10); the office card's words 16 in. a short Chinese name is under 40 wide.
    for (label, left, a, b) in [
        ("board's card", CGFloat(67), render(AgentCard(s: claude).frame(width: 380)), render(AgentCard(s: codex).frame(width: 380))),
        ("office's card", 16, render(OfficeCard(s: claude)), render(OfficeCard(s: codex))),
    ] {
        if review {
            save(a, "/tmp/codex-\(label.prefix(5))-claude.png")
            save(b, "/tmp/codex-\(label.prefix(5))-codex.png")
        }
        guard let a, let b, a.width == b.width, a.height == b.height else {
            check("codex: on the \(label), Codex after the name; the name unchanged", false)
            continue
        }
        let height = CGFloat(a.height) / 2
        check(
            "codex: on the \(label), Codex after the name; the name unchanged",
            officeDifference(a, b, in: CGRect(x: 0, y: 0, width: left + 40, height: height)) == 0
                && officeDifference(a, b, in: CGRect(x: left + 44, y: 0, width: CGFloat(a.width) / 2 - left - 44, height: 26)) > 0.01)
    }
    let cardNote = "\n右键打开菜单：跳到会话、标记或取消待回复、转到工位或休息区、在访达里打开项目目录"
    check(
        "codex: its tooltip says it is a Codex CLI session, and still how to jump and what the right-click menu holds",
        cardHelp(codex, board).contains("Codex CLI") && cardHelp(codex, board).hasPrefix("点一下跳到 Orca 里的这个会话")
            && cardHelp(codex, board).hasSuffix(cardNote) && !cardHelp(claude, board).contains("Codex"))
    check(
        "codex: the office card's project line names the model when it is known",
        OfficeCard.projectLine(codex, model: "gpt-6-astra") == "gpt-6-astra · 项目" && OfficeCard.projectLine(codex, model: nil) == "项目"
            && OfficeCard.projectLine(claude, model: nil) == "项目")
    // A plate in each place: at a desk at work, on a sofa with news, written plain at a desk once looked at, faint at the back.
    func plate(_ s: Session, seen: Bool) -> (CGRect, CGImage)? {
        let room = Store()
        room.readOnly = true
        room.sessions = [s]
        room.pinned = []
        if seen { room.seen[s.id] = now.timeIntervalSince1970 }
        let layout = OfficePainter.layout(room, now: now)
        guard let place = layout.pets.first(where: { $0.id == s.id }),
            let words = OfficePainter.words(room, s, place, layout, now: now, scale: 1), let box = officeInkBox(words.image)
        else { return nil }
        return (box, words.image)
    }
    for (label, status, ago, seen) in [("at a desk", "busy", 60.0, false), ("on a sofa", "idle", 30, false), ("looked at", "idle", 600, true), ("at the back", "idle", 9 * 3600, true)] {
        let a = officeSession("k-\(status)-\(Int(ago))", status, finished: ago, name: "摘星星")
        var b = a
        b.kind = "codex"
        let plain = plate(a, seen: seen), tagged = plate(b, seen: seen)
        if review, let plain, let tagged {
            save(plain.1, "/tmp/codex-plate-\(Int(ago))-claude.png")
            save(tagged.1, "/tmp/codex-plate-\(Int(ago))-codex.png")
        }
        // Two pixels to the point: the mark adds at least 15 points.
        check(
            "codex: in the office, the plate \(label) carries the >_ mark after the name",
            plain != nil && tagged != nil && (tagged?.0.width ?? 0) >= (plain?.0.width ?? .infinity) + 30)
    }

    // What it costs a tick: every process on the machine listed, and five Codex sessions whose rollouts run to 11 MB, each one
    // busy since a turn started 3 MB back.
    let bench = scratch + "/bench"
    try? files.createDirectory(atPath: bench + "/sessions", withIntermediateDirectories: true)
    guard let benchBase = CodexFixtureDatabase(bench + "/state_5.sqlite") else {
        check("codex: a fixture database can be made", false)
        return
    }
    let megabyte = codexToolOutput(t2, bytes: 1_000_000)
    var benchPaths: [Int32: String] = [:]
    for i in 0..<5 {
        let id = "01a10006-0000-7000-8000-0000000000\(50 + i)", path = bench + "/sessions/rollout-2026-10-08T11-43-02-\(id).jsonl"
        var text = codexMeta(t1)
        for _ in 0..<4 { text += codexStarted(t1) + codexSaid(t2, "第 \(i) 个") + megabyte + megabyte + codexComplete(t4) }
        write(path, text + codexStarted(t5) + codexSaid(t6, "还在干") + megabyte + megabyte + megabyte)
        benchBase.add(id, rollout: path, cwd: project, title: "第 \(i) 个", model: "gpt-6-astra", updated: now.timeIntervalSince1970)
        benchPaths[900_000 + Int32(i)] = path
    }
    let live = CodexProcesses()
    let costly = CodexSessions()
    // Every process listed each tick, as the panel does; only the five fixtures mapped, so what any other Codex sessions happen
    // to be writing does not move the figure (they are measured on their own below).
    costly.processes = {
        _ = live.list()
        return (0..<5).map { CodexProcess(pid: 900_000 + Int32($0), start: started, home: bench) }
    }
    costly.rollout = { benchPaths[$0] }
    var clock = Date()
    var timer = Date()
    let opened = costly.load(now: clock)
    let firstLook = Date().timeIntervalSince(timer)
    var ticks: [TimeInterval] = []
    for _ in 0..<20 {
        clock += 2
        timer = Date()
        _ = costly.load(now: clock)
        ticks.append(Date().timeIntervalSince(timer))
    }
    if let path = benchPaths[900_000] { append(path, megabyte) }
    clock += 11
    timer = Date()
    _ = costly.load(now: clock)
    let catchUp = Date().timeIntervalSince(timer)
    let quietTick = ticks.sorted()[ticks.count / 2]
    let listing = (0..<20).map { _ in
        let t = Date()
        _ = live.list()
        return Date().timeIntervalSince(t)
    }.sorted()[10]
    let benchIDs = Set((0..<5).map { "01a10006-0000-7000-8000-0000000000\(50 + $0)" })
    print(
        String(
            format: "      codex cost: first look %.1f ms; a quiet tick %.2f ms (of it, listing every process %.2f ms); a tick reading 1 MB new %.2f ms",
            firstLook * 1000, quietTick * 1000, listing * 1000, catchUp * 1000))
    check(
        "codex: with five sessions a tick costs under 5 ms (the middle of twenty), and so does one that reads a megabyte of new rollout",
        opened.count == 5 && Set(opened.map(\.id)) == benchIDs && opened.allSatisfy { $0.status == "busy" && $0.summary == "还在干" }
            && quietTick < 0.005 && catchUp < 0.005)
    // Any Codex sessions found on this system now, for the record.
    let real = CodexSessions()
    timer = Date()
    let mapped = real.load()
    let realFirst = Date().timeIntervalSince(timer)
    timer = Date()
    _ = real.load()
    print(String(format: "      codex now: %d session(s); first look %.1f ms, the next tick %.2f ms", mapped.count, realFirst * 1000, Date().timeIntervalSince(timer) * 1000))
    for s in mapped {
        print("      codex now: \(s.name) · \(s.project) · \(s.status) since \(s.since) · Orca tab \(OrcaTabs.shared.tab(of: s.pid)?.terminal ?? "none") · \(s.summary.prefix(40))")
    }
    let loader = Loader()
    _ = loader.load()
    timer = Date()
    let everyone = loader.load()
    print(String(format: "      the loader now: %d sessions, %d of them Codex, %.2f ms a tick", everyone.count, everyone.filter { $0.kind == "codex" }.count, Date().timeIntervalSince(timer) * 1000))
}

// ───────── The Codex desktop app's threads and WorkBuddy's sessions ─────────

/// Sample transcripts and databases, beside this file, when present: where they are missing, the checks that need them say they were skipped.
let appFixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path + "/fixtures"

/// Runs SQL on a check's own copy of a fixture database (never on the fixture itself).
func fixtureSQL(_ path: String, _ sql: String) -> Bool {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else {
        sqlite3_close(db)
        return false
    }
    defer { sqlite3_close(db) }
    return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
}

/// The first column of the first row an SQL query on a fixture copy gives, as text.
func fixtureValue(_ path: String, _ sql: String) -> String? {
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        sqlite3_close(db)
        return nil
    }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return nil }
    return String(cString: text)
}

/// A file's lines, without their newlines.
/// The files under `dir` whose names end with `suffix`, as paths from `dir`, in order.
func fixtureFiles(_ dir: String, ending suffix: String) -> [String] {
    ((FileManager.default.enumerator(atPath: dir)?.allObjects as? [String]) ?? []).filter { $0.hasSuffix(suffix) }.sorted()
}

func fixtureLines(_ path: String) -> [String] {
    let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    return text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter { !$0.isEmpty }
}

/// A message in a Codex app rollout, with the kinds of content the app marks it with (nil: no mark, as the CLI writes).
func codexAppSaid(_ at: String, _ text: String, kinds: [String]?, role: String = "user") -> String {
    let kind = role == "assistant" ? "output_text" : "input_text"
    let listed = (kinds ?? []).map { "\"" + $0 + "\"" }.joined(separator: ",")
    let mark = kinds == nil ? "" : ",\"internal_chat_message_metadata_passthrough\":{\"turn_id\":\"t\",\"content_item_kinds\":[" + listed + "]}"
    let content = "\"content\":[{\"type\":\"\(kind)\",\"text\":\"\(text)\"}]"
    return codexLine(at, "response_item", "\"type\":\"message\",\"id\":\"msg_1\",\"role\":\"\(role)\"," + content + mark)
}

/// The checks of `appTests` that need the samples, as each is named there: listed as skipped where the samples are not.
let appFixtureChecks = [
    "codex app: the vscode threads of the fixture are listed, exec threads are not",
    "codex app: ...by the name the app gave it, its folder, and its model with the reasoning effort",
    "codex app: a source='vscode' thread of another originator (Claude Code's Codex plugin) is not listed; the desktop's own still are",
    "codex app: ...within the last 24 hours only: the thread from three days back is not, nor today's a day after it finished",
    "codex app: a thread whose rollout file is missing is listed as idle with no progress, not an error",
    "codex app: the fixture thread with request_user_input_async in its last turn is waiting (question)",
    "codex app: ...once its card is answered (the whole rollout) it is not waiting",
    "codex app: ...and an answer read in a later look clears the wait",
    "codex app: a card is no longer waited on once a later turn starts, whatever started it; in a turn still running it is busy, not waiting",
    "codex app: the in-progress thread_turns fixture marks the thread busy",
    "codex app: ...not with the turn finished in the table, nor when the rollout ended that turn after it started",
    "codex app: a request_permissions call with no output yet in a running turn is waiting (approval); the whole rollout is not",
    "codex app: ...and the second card of the live tests is waiting (question) from when it came up",
    "codex app: ...a live script that only mentions request_permissions leaves its turn busy",
    "codex app: the first look at a 20 MB rollout is off the main thread: Loader.load() returns in under 50 ms, idle with no progress; the next tick has its state",
    "workbuddy: the fixture session is listed with its title, cwd and done status",
    "workbuddy: ...within the last 24 hours only",
    "workbuddy: progress is the last assistant output_text",
    "workbuddy: a pending session with ask-user-question in its log is waiting (question); a pending with permission in bypass mode is busy; in default mode it is waiting (permission)",
    "wal: a read-only open of a copied database without -wal/-shm still returns rows",
    "wal: a read-only look leaves -shm as it was, bytes and time; with only an empty -wal it makes no -shm",
    "sources: with neither app running, both sources return no sessions and read no files",
]

/// The checks of `appTests` that read the live-test recordings (`fixtures/live-*`): skipped on their own where those are not.
let appLiveFixtureChecks = [
    "codex app: a request_permissions call with no output yet in a running turn is waiting (approval); the whole rollout is not",
    "codex app: ...a live script that only mentions request_permissions leaves its turn busy",
    "codex app: ...and the second card of the live tests is waiting (question) from when it came up",
    "workbuddy: a pending session with ask-user-question in its log is waiting (question); a pending with permission in bypass mode is busy; in default mode it is waiting (permission)",
]

/// The Codex desktop app (in ChatGPT.app) and WorkBuddy keep their conversations in files of their own; while
/// each app runs, its recent ones are sessions here, with a state, a line of progress and a way back into the app.
@MainActor func appTests() {
    let files = FileManager.default
    let scratch = codexRealPath(NSTemporaryDirectory()) + "/app-tests-\(getpid())"
    try? files.removeItem(atPath: scratch)
    try? files.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? files.removeItem(atPath: scratch) }

    // Jump links and tags need no fixture.
    var thread = officeSession("01a20000-0000-7000-8000-000000000001", "idle", finished: 60, name: "线程")
    thread.kind = "codexApp"
    var task = officeSession("40a00000-0000-4000-8000-000000000001", "idle", finished: 60, name: "任务")
    task.kind = "workbuddy"
    var odd = Session(id: "a b/c?d", pid: 1, project: "p", name: "n", status: "idle", since: Date(), summary: "")
    odd.kind = "workbuddy"
    var cli = thread
    cli.kind = "codex"
    let claude = officeSession("k-claude", "idle", finished: 60, name: "摘星星")
    let threadURL = jumpURL(thread)?.absoluteString
    let taskURL = jumpURL(task)?.absoluteString
    let oddURL = jumpURL(odd)?.absoluteString
    let orcaKinds = jumpURL(cli) == nil && jumpURL(claude) == nil
    check(
        "jump: codexApp and workbuddy sessions produce the expected URLs",
        threadURL == "codex://threads/01a20000-0000-7000-8000-000000000001"
            && taskURL == "workbuddy://chat/40a00000-0000-4000-8000-000000000001" && oddURL == "workbuddy://chat/a%20b%2Fc%3Fd" && orcaKinds)
    let tags = [kindTag(thread), kindTag(thread, short: true), kindTag(task), kindTag(task, short: true)]
    check("kinds: the Codex app's sessions are tagged Codex App (>_ on a plate), WorkBuddy's WorkBuddy (WB)", tags == ["Codex App", ">_", "WorkBuddy", "WB"])
    let board = Store()
    board.readOnly = true
    let threadHelp = cardHelp(thread, board), taskHelp = cardHelp(task, board)
    check(
        "kinds: their tooltips send him to the app, not to Orca",
        threadHelp.hasPrefix("点一下跳到 Codex App 里的这个会话") && taskHelp.hasPrefix("点一下跳到 WorkBuddy 里的这个会话")
            && !threadHelp.contains("Orca") && !taskHelp.contains("Orca"))
    var allowing = Session(id: task.id, pid: 1, project: "p", name: "n", status: "waiting", since: Date().addingTimeInterval(-300), summary: "等你批准")
    allowing.waitingFor = "permission request"
    var asking = allowing
    asking.waitingFor = "input needed"
    check(
        "kinds: a session waiting for a permission says it waits for approval, one waiting for an answer says it waits for an answer",
        timeLabel(allowing, now: Date()) == "等你批准 5 分钟" && timeLabel(asking, now: Date()) == "等你回答 5 分钟")

    // A synthetic rollout: their words only from the items the app marks user.text.
    let said = scratch + "/rollout-said.jsonl"
    let a1 = "2026-10-09T09:31:18.342Z", a2 = "2026-10-09T09:31:48.047Z", a3 = "2026-10-09T09:31:48.191Z"
    let a4 = "2026-10-09T09:43:57.764Z", a5 = "2026-10-09T09:43:57.776Z"
    var text = codexMeta(a1) + codexStarted(a1)
    text += codexAppSaid(a1, "<environment_context>机器</environment_context>", kinds: ["environments.environment_context"])
    text += codexAppSaid(a1, "第一句话", kinds: ["user.text"]) + codexSaid(a2, "好的，我先看看") + codexComplete(a3)
    text += codexStarted(a4) + codexAppSaid(a4, "第二句话\\n细节", kinds: ["user.text"])
    text += codexAppSaid(a5, "打开的页面", kinds: ["additional_content.codex_apps_open_page"])
    text += codexAppSaid(a5, "没有标记的", kinds: nil) + codexAppSaid(a5, "开发者的", kinds: ["user.text"], role: "developer")
    files.createFile(atPath: said, contents: Data(text.utf8))
    let appTail = CodexTail.read(said, after: nil, now: Date(), app: true)
    let cliTail = CodexTail.read(said, after: nil, now: Date())
    check(
        "codex app: user text is read only from user.text items",
        appTail.status == "busy" && appTail.summary == "你：第二句话" && cliTail.summary == "好的，我先看看")

    // An `exec` script that only mentions request_permissions (in a string, say) is not a request for it.
    let mentioning = scratch + "/rollout-mentioning.jsonl"
    let m1 = "2026-10-09T09:45:30.000Z", m2 = "2026-10-09T09:45:34.049Z"
    let mention = codexLine(
        m2, "response_item",
        "\"type\":\"custom_tool_call\",\"id\":\"ctc_2\",\"status\":\"completed\",\"call_id\":\"call_m\",\"name\":\"exec\",\"input\":\"for k in ['thread/status/changed','request_permissions']: print(k)\"")
    files.createFile(atPath: mentioning, contents: Data((codexMeta(m1) + codexStarted(m1) + mention).utf8))
    let mentioned = CodexTail.read(mentioning, after: nil, now: Date(), app: true)
    check("codex app: a script that only mentions request_permissions is not a request for approval", mentioned.busy && mentioned.approvals.isEmpty)

    // Not checked against a real run: a turn the user stops. Codex writes turn_aborted (as the CLI does); what it waited for goes.
    let stopped = scratch + "/rollout-stopped.jsonl"
    let s1 = "2026-10-09T10:06:48.723Z", s2 = "2026-10-09T10:06:56.678Z", s3 = "2026-10-09T10:07:10.000Z"
    let permitting = codexLine(s2, "response_item", "\"type\":\"custom_tool_call\",\"id\":\"ctc_1\",\"status\":\"completed\",\"call_id\":\"call_p\",\"name\":\"exec\",\"input\":\"tools.request_permissions({})\"")
    files.createFile(atPath: stopped, contents: Data((codexMeta(s1) + codexStarted(s1) + permitting).utf8))
    let before = CodexTail.read(stopped, after: nil, now: Date(), app: true)
    if let handle = FileHandle(forWritingAtPath: stopped) {
        handle.seekToEndOfFile()
        handle.write(Data(codexAborted(s3).utf8))
        try? handle.close()
    }
    let after = CodexTail.read(stopped, after: before, now: Date().addingTimeInterval(11), app: true)
    check(
        "codex app: (synthetic, not checked against a real run) a turn the user stops is done, and the approval it waited for goes with it",
        before.approvals.count == 1 && after.status == "idle" && after.approvals.isEmpty)

    // Not checked against a real run: a permission wait outside bypass mode, a stopped turn, a failed one. On the mapping alone.
    let allow = WorkBuddySessions.state("pending", wait: .permission, mode: "default")
    let unknown = WorkBuddySessions.state("pending", wait: nil, mode: "acceptEdits")
    let stopTerminated = WorkBuddySessions.state("terminated", wait: nil, mode: "bypassPermissions")
    let stopCancelled = WorkBuddySessions.state("cancelled", wait: nil, mode: "bypassPermissions")
    let failure = WorkBuddySessions.state("error", wait: nil, mode: "bypassPermissions")
    let failed2 = WorkBuddySessions.state("failed", wait: nil, mode: "bypassPermissions")
    let working = WorkBuddySessions.state("planning", wait: nil, mode: "default")
    check(
        "workbuddy: (mapping only, not checked against a real run) a permission wait outside bypass mode is a wait for approval; stopped is done with the aborted word, failed with the error word",
        allow.status == "waiting" && allow.waitingFor == "permission request" && allow.summary == "等你批准" && unknown.status == "waiting"
            && unknown.waitingFor == "permission request" && stopTerminated.status == "idle" && stopTerminated.summary == "已中止"
            && stopCancelled.summary == "已中止" && failure.status == "idle" && failure.summary == "出错" && failed2.summary == "出错"
            && working.status == "busy" && working.summary == nil)

    // Checks below need the samples; where they are missing each says it was skipped.
    let needed = ["/codex-app/state_5.sqlite", "/workbuddy/workbuddy.db"]
    guard needed.allSatisfy({ files.fileExists(atPath: appFixtures + $0) }) else {
        for what in appFixtureChecks { skipped("no fixtures", what) }
        return
    }
    // The recordings of the live tests (fixtures/live-*) are not in the public repository: only the
    // checks that read them say they were skipped.
    let liveRoot = "/" + (((try? files.contentsOfDirectory(atPath: appFixtures)) ?? []).filter { $0.hasPrefix("live-") }.sorted().last ?? "live")
    let haveLive = [liveRoot + "/codex-app/state_5.sqlite", liveRoot + "/workbuddy/workbuddy.db"]
        .allSatisfy { files.fileExists(atPath: appFixtures + $0) }

    // ── The Codex app. Three threads: today's (four turns, one of them a question card the user answered), one from an earlier day whose
    // rollout was left out on purpose, and a `codex exec` run's.
    // The samples' ids are read from them (the index: the thread updated last is today's), not written here.
    let source = appFixtures + "/codex-app"
    let indexed = fixtureLines(source + "/session_index.jsonl").compactMap { line -> (id: String, at: String)? in
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], let id = o["id"] as? String else { return nil }
        return (id, o["updated_at"] as? String ?? "")
    }.sorted { $0.at < $1.at }
    let today = indexed.last?.id ?? "", older = indexed.first?.id ?? ""
    let todayFile = "/" + (fixtureFiles(source, ending: "-\(today).jsonl").first ?? "")
    let todayLines = fixtureLines(source + todayFile)
    /// A copy of the app's home: its index, a turn table, the rollouts (today's cut after `keep` lines), the paths in the
    /// index pointed at the copy.
    func codexHome(_ name: String, history: String = "thread_history_1.sqlite", keep: Int? = nil) -> String {
        let dir = scratch + "/" + name
        try? files.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? files.copyItem(atPath: source + "/state_5.sqlite", toPath: dir + "/state_5.sqlite")
        try? files.copyItem(atPath: source + "/" + history, toPath: dir + "/thread_history_1.sqlite")
        try? files.copyItem(atPath: source + "/sessions", toPath: dir + "/sessions")
        if let keep {
            let cut = todayLines.prefix(keep).joined(separator: "\n") + "\n"
            try? cut.write(toFile: dir + todayFile, atomically: true, encoding: .utf8)
        }
        _ = fixtureSQL(dir + "/state_5.sqlite", "UPDATE threads SET rollout_path = '\(dir)' || substr(rollout_path, instr(rollout_path, '/.codex/') + 7) WHERE instr(rollout_path, '/.codex/') > 0")
        return dir
    }
    func app(_ home: String, recent: TimeInterval = 86_400) -> CodexAppSessions {
        let made = CodexAppSessions(home: home)
        made.running = { 4242 }
        made.recent = recent
        made.readsFirstInline = true
        return made
    }
    let lastUpdate = 1_791_539_284.404
    let tenLater = Date(timeIntervalSince1970: lastUpdate + 600)
    let month: TimeInterval = 30 * 86_400
    let full = codexHome("full")
    let index = full + "/state_5.sqlite"
    let wide = app(full, recent: month)
    let listed = wide.load(now: tenLater)
    let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    check(
        "codex app: the vscode threads of the fixture are listed, exec threads are not",
        listed.count == 2 && Set(listed.map(\.id)) == [today, older] && listed.allSatisfy { $0.kind == "codexApp" && $0.pid == 4242 })
    let name = fixtureValue(index, "SELECT name FROM threads WHERE id = '\(today)'")
    let title = fixtureValue(index, "SELECT title FROM threads WHERE id = '\(today)'") ?? ""
    let cwd = fixtureValue(index, "SELECT cwd FROM threads WHERE id = '\(today)'") ?? "?"
    let model = fixtureValue(index, "SELECT model || ' · ' || reasoning_effort FROM threads WHERE id = '\(today)'")
    let first = byID[today]
    check(
        "codex app: ...by the name the app gave it, its folder, and its model with the reasoning effort",
        first?.name == codexName(name: name, title: title) && first?.cwd == cwd && first?.project == (cwd as NSString).lastPathComponent
            && model != nil && wide.model(of: today) == model)
    // Claude Code's Codex plugin writes its threads into ~/.codex as source 'vscode' too; only the desktop app's own
    // (originator "Codex Desktop") are the app's sessions.
    let plugin = "01a12000-0000-7000-8000-00000000c0de"
    let withPlugin = codexHome("plugin")
    let added = fixtureSQL(
        withPlugin + "/state_5.sqlite",
        "CREATE TEMP TABLE copied AS SELECT * FROM threads WHERE id = '\(today)'; UPDATE copied SET id = '\(plugin)', originator = 'codex_cli'; "
            + "INSERT INTO threads SELECT * FROM copied;")
    let pluginRows = fixtureValue(withPlugin + "/state_5.sqlite", "SELECT count(*) FROM threads WHERE source = 'vscode' AND originator <> 'Codex Desktop'")
    let desktopOnly = app(withPlugin, recent: month).load(now: tenLater).map(\.id).sorted()
    check(
        "codex app: a source='vscode' thread of another originator (Claude Code's Codex plugin) is not listed; the desktop's own still are",
        added && pluginRows == "1" && desktopOnly == [older, today].sorted())
    // The Windows app's threads (originator "codex_work_desktop") moved to a Mac: the app lists them
    // in its sidebar and carries on with them there, so they are its sessions too.
    let fromWindows = "01a12000-0000-7000-8000-0000000be11e"
    let withWindowsHome = codexHome("from-windows")
    let windowsIn = fixtureSQL(
        withWindowsHome + "/state_5.sqlite",
        "CREATE TEMP TABLE copied AS SELECT * FROM threads WHERE id = '\(today)'; UPDATE copied SET id = '\(fromWindows)', originator = 'codex_work_desktop'; "
            + "INSERT INTO threads SELECT * FROM copied;")
    let withWindows = app(withWindowsHome, recent: month).load(now: tenLater).map(\.id).sorted()
    check(
        "codex app: a thread the Windows app started (originator 'codex_work_desktop', moved to the Mac) is listed beside the desktop's own",
        windowsIn && withWindows == [older, today, fromWindows].sorted())
    let daily = app(full).load(now: tenLater).map(\.id)
    let dayAfter = app(full).load(now: Date(timeIntervalSince1970: lastUpdate + 25 * 3600)).map(\.id)
    check(
        "codex app: ...within the last 24 hours only: the thread from three days back is not, nor today's a day after it finished",
        daily == [today] && dayAfter.isEmpty)
    let lost = byID[older]
    check(
        "codex app: a thread whose rollout file is missing is listed as idle with no progress, not an error",
        lost?.status == "idle" && lost?.summary == "" && lost?.waitingFor == "")

    // Today's thread cut just after the turn whose question card it put up: the turn is over, the card is not answered.
    let stamps = ISO8601DateFormatter()
    stamps.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let cardAt = stamps.date(from: "2026-10-09T09:32:11.713Z")
    let asked = app(codexHome("asked", keep: 52), recent: month)
    let waiting = asked.load(now: tenLater).first { $0.id == today }
    check(
        "codex app: the fixture thread with request_user_input_async in its last turn is waiting (question)",
        waiting?.status == "waiting" && waiting?.waitingFor == "input needed" && (waiting?.summary.hasPrefix("问你：") ?? false)
            && (waiting?.summary.count ?? 0) > 3 && waiting?.since == cardAt)
    let answered = byID[today]
    check(
        "codex app: ...once its card is answered (the whole rollout) it is not waiting",
        answered?.status == "idle" && answered?.waitingFor == "" && !(answered?.summary.hasPrefix("问你：") ?? true))
    let rest = todayLines.dropFirst(52).joined(separator: "\n") + "\n"
    if let handle = FileHandle(forWritingAtPath: scratch + "/asked" + todayFile) {
        handle.seekToEndOfFile()
        handle.write(Data(rest.utf8))
        try? handle.close()
    }
    let later = asked.load(now: tenLater).first { $0.id == today }
    check("codex app: ...and an answer read in a later look clears the wait", later?.status == "idle" && later?.waitingFor == "")
    // The user types into the box instead of choosing (a new turn from the composer); or the card's own turn still runs.
    let typed = codexHome("typed", keep: 52)
    let composer = codexLine(
        "2026-10-09T09:35:00.000Z", "event_msg",
        "\"type\":\"task_started\",\"turn_attribution\":{\"turn_id\":\"t9\",\"turn_trigger\":\"composer\"},\"turn_id\":\"t9\"")
    if let handle = FileHandle(forWritingAtPath: typed + todayFile) {
        handle.seekToEndOfFile()
        handle.write(Data(composer.utf8))
        try? handle.close()
    }
    let moved = app(typed, recent: month).load(now: tenLater).first { $0.id == today }
    let cardTurn = app(codexHome("card-turn", keep: 49), recent: month).load(now: tenLater).first { $0.id == today }
    check(
        "codex app: a card is no longer waited on once a later turn starts, whatever started it; in a turn still running it is busy, not waiting",
        moved?.status == "busy" && moved?.waitingFor == "" && cardTurn?.status == "busy" && cardTurn?.waitingFor == "")

    // The fourth turn as the turn table had it, with the rollout silent since the third ended.
    let started = Date(timeIntervalSince1970: 1_791_539_037)
    let running = app(codexHome("running", history: "thread_history_1-inprogress.sqlite", keep: 63), recent: month)
    let busy = running.load(now: tenLater).first { $0.id == today }
    let finished = app(codexHome("finished", keep: 63), recent: month).load(now: tenLater).first { $0.id == today }
    let stale = app(codexHome("stale", history: "thread_history_1-inprogress.sqlite"), recent: month).load(now: tenLater).first { $0.id == today }
    check("codex app: the in-progress thread_turns fixture marks the thread busy", busy?.status == "busy" && busy?.since == started)
    check(
        "codex app: ...not with the turn finished in the table, nor when the rollout ended that turn after it started",
        finished?.status == "idle" && stale?.status == "idle")

    // The live recording: an approval in a running turn, then a second question card.
    if !haveLive {
        for what in appLiveFixtureChecks where what.hasPrefix("codex app") { skipped("no live fixtures (fixtures/live-*)", what) }
    } else {
    let live = appFixtures + liveRoot + "/codex-app"
    let liveLines = fixtureLines(live + todayFile)
    func liveHome(_ name: String, keep: Int? = nil) -> String {
        let dir = scratch + "/" + name
        try? files.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for item in ["state_5.sqlite", "thread_history_1.sqlite", "sessions"] {
            try? files.copyItem(atPath: live + "/" + item, toPath: dir + "/" + item)
        }
        if let keep {
            let cut = liveLines.prefix(keep).joined(separator: "\n") + "\n"
            try? cut.write(toFile: dir + todayFile, atomically: true, encoding: .utf8)
        }
        _ = fixtureSQL(dir + "/state_5.sqlite", "UPDATE threads SET rollout_path = '\(dir)' || substr(rollout_path, instr(rollout_path, '/.codex/') + 7) WHERE instr(rollout_path, '/.codex/') > 0")
        return dir
    }
    let liveNow = Date(timeIntervalSince1970: 1_791_540_639.947 + 600)
    let approving = app(liveHome("approving", keep: 142), recent: month).load(now: liveNow).first { $0.id == today }
    let approved = app(liveHome("approved"), recent: month).load(now: liveNow).first { $0.id == today }
    check(
        "codex app: a request_permissions call with no output yet in a running turn is waiting (approval); the whole rollout is not",
        liveLines.count == 204 && approving?.status == "waiting" && approving?.waitingFor == "permission prompt"
            && approving?.summary == "等你批准" && approving?.since == stamps.date(from: "2026-10-09T10:06:56.678Z")
            && approved?.status == "idle" && approved?.waitingFor == "")
    let mentionedLive = app(liveHome("mentioning", keep: 101), recent: month).load(now: liveNow).first { $0.id == today }
    check("codex app: ...a live script that only mentions request_permissions leaves its turn busy", mentionedLive?.status == "busy" && mentionedLive?.waitingFor == "")
    let choosing = app(liveHome("choosing", keep: 173), recent: month).load(now: liveNow).first { $0.id == today }
    check(
        "codex app: ...and the second card of the live tests is waiting (question) from when it came up",
        choosing?.status == "waiting" && choosing?.waitingFor == "input needed" && choosing?.since == stamps.date(from: "2026-10-09T10:08:17.483Z"))
    }

    // The card's turn with 20 MB of tool output between the card and its end, read by the panel's own loader on the
    // main thread: the first tick hands the rollout to a background read and lists the thread at once; the next has its state.
    let padded = codexHome("padded")
    var paddedText = todayLines.prefix(49).joined(separator: "\n") + "\n"
    for _ in 0..<20 { paddedText += codexToolOutput("2026-10-09T09:32:15.200Z", bytes: 1_000_000) }
    paddedText += todayLines[49..<52].joined(separator: "\n") + "\n"
    try? paddedText.write(toFile: padded + todayFile, atomically: true, encoding: .utf8)
    let paddedSize = (try? files.attributesOfItem(atPath: padded + todayFile))?[.size] as? Int ?? 0
    let deferred = CodexAppSessions(home: padded)
    deferred.running = { 4242 }
    deferred.recent = 1e10
    let noCLI = CodexSessions()
    noCLI.processes = { [] }
    let noWB = WorkBuddySessions(home: scratch + "/no-workbuddy")
    let quick = Loader(registry: scratch + "/no-registry", codex: noCLI, codexApp: deferred, workbuddy: noWB)
    let tickStart = Date()
    let firstTick = quick.load().first { $0.id == today }
    let firstTook = Date().timeIntervalSince(tickStart)
    let waitUntil = Date().addingTimeInterval(20)
    while deferred.firstReadsPending > 0 && Date() < waitUntil { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    let secondTick = quick.load().first { $0.id == today }
    print(String(format: "      codex app: first tick over a %.1f MB rollout %.1f ms on the main thread", Double(paddedSize) / 1e6, firstTook * 1000))
    check(
        "codex app: the first look at a 20 MB rollout is off the main thread: Loader.load() returns in under 50 ms, idle with no progress; the next tick has its state",
        paddedSize > 20_000_000 && firstTook < 0.05 && firstTick?.status == "idle" && firstTick?.summary == "" && secondTick?.status == "waiting"
            && secondTick?.waitingFor == "input needed")

    // ── WorkBuddy. One session, two turns: a question in the first, six permission requests in the second.
    let wbSource = appFixtures + "/workbuddy"
    let logFile = "/" + (fixtureFiles(wbSource, ending: ".log").first { $0.contains("/sdk/conversations/") } ?? "")
    let wbID = ((logFile as NSString).lastPathComponent as NSString).deletingPathExtension
    let wbLog = fixtureLines(wbSource + logFile)
    func workbuddyHome(_ name: String, logLines: Int? = nil, status: String? = nil, mode: String? = nil) -> String {
        let dir = scratch + "/" + name
        try? files.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for item in ["workbuddy.db", "workbuddy.db-shm", "workbuddy.db-wal", "projects", "logs", "sessions"] {
            try? files.copyItem(atPath: wbSource + "/" + item, toPath: dir + "/" + item)
        }
        if let logLines {
            let cut = wbLog.prefix(logLines).joined(separator: "\n") + "\n"
            try? cut.write(toFile: dir + logFile, atomically: true, encoding: .utf8)
        }
        if let status { _ = fixtureSQL(dir + "/workbuddy.db", "UPDATE sessions SET status = '\(status)'") }
        if let mode { _ = fixtureSQL(dir + "/workbuddy.db", "UPDATE sessions SET permission_mode = '\(mode)'") }
        return dir
    }
    func workbuddy(_ home: String) -> WorkBuddySessions {
        let made = WorkBuddySessions(home: home)
        made.running = { 4343 }
        return made
    }
    let wbHome = workbuddyHome("wb")
    let wbDB = wbHome + "/workbuddy.db"
    let updated = Double(fixtureValue(wbDB, "SELECT updated_at FROM sessions") ?? "0") ?? 0
    let wbNow = Date(timeIntervalSince1970: updated / 1000 + 600)
    let wbReader = workbuddy(wbHome)
    let wbListed = wbReader.load(now: wbNow)
    let wbTitle = fixtureValue(wbDB, "SELECT title FROM sessions")
    let wbCwd = fixtureValue(wbDB, "SELECT cwd FROM sessions") ?? "?"
    let done = wbListed.first
    check(
        "workbuddy: the fixture session is listed with its title, cwd and done status",
        wbListed.count == 1 && done?.id == wbID && done?.name == wbTitle && done?.cwd == wbCwd && done?.kind == "workbuddy"
            && done?.status == "idle" && done?.pid == 4343 && done?.since == Date(timeIntervalSince1970: updated / 1000)
            && done?.project == (wbCwd as NSString).lastPathComponent)
    check(
        "workbuddy: ...within the last 24 hours only",
        workbuddy(wbHome).load(now: Date(timeIntervalSince1970: updated / 1000 + 25 * 3600)).isEmpty)

    // The record's last assistant message, found here the slow way, and its model.
    let record = ((try? files.contentsOfDirectory(atPath: wbHome + "/projects")) ?? []).sorted().map { wbHome + "/projects/" + $0 + "/\(wbID).jsonl" }.first { files.fileExists(atPath: $0) } ?? ""
    var lastReply = "", realModel = ""
    for line in fixtureLines(record) {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any], (o["type"] as? String) == "message",
            (o["role"] as? String) == "assistant", (o["status"] as? String) == "completed",
            let blocks = o["content"] as? [[String: Any]]
        else { continue }
        let words = blocks.filter { ($0["type"] as? String) == "output_text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        if !words.isEmpty {
            lastReply = words
            realModel = (o["providerData"] as? [String: Any])?["model"] as? String ?? ""
        }
    }
    let progress = pickSummary(recap: nil, reply: ("", lastReply), asked: nil)
    check(
        "workbuddy: progress is the last assistant output_text",
        !lastReply.isEmpty && done?.summary == progress && !realModel.isEmpty && wbReader.model(of: wbID) == realModel)

    // Pending, as the log had it at the first turn's question (cut after its status was written), and at the second turn's
    // first permission request; in bypass mode, as the fixture is, and in the default one.
    let pendingAt = Date(timeIntervalSince1970: (updated / 1000).rounded(.down) + 5)
    func pending(_ name: String, lines: Int, mode: String? = nil) -> Session? {
        let home = workbuddyHome(name, logLines: lines, status: "pending", mode: mode)
        _ = fixtureSQL(home + "/workbuddy.db", "UPDATE sessions SET updated_at = \(Int64(pendingAt.timeIntervalSince1970 * 1000))")
        return workbuddy(home).load(now: wbNow).first
    }
    let bypassed = pending("bypassed", lines: 440)
    // The live question: its log cut after its pending status was written, the row as it was then.
    if !haveLive {
        for what in appLiveFixtureChecks where what.hasPrefix("workbuddy") { skipped("no live fixtures (fixtures/live-*)", what) }
    } else {
    let liveWB = appFixtures + liveRoot + "/workbuddy"
    let liveLog = "/" + (fixtureFiles(liveWB, ending: ".log").first { $0.contains("/sdk/conversations/") } ?? "")
    let liveID = ((liveLog as NSString).lastPathComponent as NSString).deletingPathExtension
    let liveDir = scratch + "/wb-live"
    try? files.createDirectory(atPath: liveDir, withIntermediateDirectories: true)
    for item in ["workbuddy.db", "projects", "logs", "sessions"] { try? files.copyItem(atPath: liveWB + "/" + item, toPath: liveDir + "/" + item) }
    let liveCut = fixtureLines(liveWB + liveLog).prefix(172).joined(separator: "\n") + "\n"
    try? liveCut.write(toFile: liveDir + liveLog, atomically: true, encoding: .utf8)
    let askedAt: Int64 = 1_791_540_505_807
    _ = fixtureSQL(liveDir + "/workbuddy.db", "UPDATE sessions SET status = 'pending', updated_at = \(askedAt) WHERE id = '\(liveID)'")
    let question = workbuddy(liveDir).load(now: Date(timeIntervalSince1970: Double(askedAt) / 1000 + 30)).first { $0.id == liveID }
    check(
        "workbuddy: a pending session with ask-user-question in its log is waiting (question); a pending with permission in bypass mode is busy; in default mode it is waiting (permission)",
        question?.status == "waiting" && question?.waitingFor == "input needed" && (question?.summary.hasPrefix("等你回答") ?? false)
            && question?.since == Date(timeIntervalSince1970: Double(askedAt) / 1000) && bypassed?.status == "busy"
            && bypassed?.since == pendingAt && WorkBuddySessions.state("pending", wait: .permission, mode: "default").status == "waiting")
    }

    // ── Databases in WAL mode with their log folded back and removed: a read-only open alone cannot read them.
    let bare = scratch + "/bare"
    try? files.createDirectory(atPath: bare, withIntermediateDirectories: true)
    try? files.copyItem(atPath: wbSource + "/workbuddy.db", toPath: bare + "/workbuddy.db")
    let ids = ReadOnlyDatabase(bare + "/workbuddy.db")?.rows("SELECT id FROM sessions") { row in
        sqlite3_column_text(row, 0).map { String(cString: $0) }
    }
    let threadsHome = scratch + "/threads-wal"
    try? files.createDirectory(atPath: threadsHome, withIntermediateDirectories: true)
    try? files.copyItem(atPath: source + "/state_5.sqlite", toPath: threadsHome + "/state_5.sqlite")
    let walMode = fixtureSQL(threadsHome + "/state_5.sqlite", "PRAGMA journal_mode=WAL")
    let rolloutPath = fixtureValue(source + "/state_5.sqlite", "SELECT rollout_path FROM threads WHERE rollout_path LIKE '%/.codex\(todayFile)'") ?? ""
    var orcaFound = false
    if case .found(let t)? = CodexThreads(home: threadsHome)?.thread(rollout: rolloutPath) { orcaFound = t.id == today }
    let left = ((try? files.contentsOfDirectory(atPath: bare)) ?? []).sorted() + ((try? files.contentsOfDirectory(atPath: threadsHome)) ?? []).sorted()
    check(
        "wal: a read-only open of a copied database without -wal/-shm still returns rows",
        ids == [wbID] && walMode && orcaFound && left == ["workbuddy.db", "state_5.sqlite"])
    // With the app's -wal and -shm there (it has the database open, or left them), the -shm is not written; with
    // only an empty -wal none is made.
    let both = scratch + "/shm-both", walOnly = scratch + "/shm-wal-only"
    for (dir, items) in [(both, ["workbuddy.db", "workbuddy.db-wal", "workbuddy.db-shm"]), (walOnly, ["workbuddy.db", "workbuddy.db-wal"])] {
        try? files.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for item in items { try? files.copyItem(atPath: wbSource + "/" + item, toPath: dir + "/" + item) }
    }
    let shm = both + "/workbuddy.db-shm"
    let shmBytes = files.contents(atPath: shm), shmStamp = FileStamp(shm)
    let bothIDs = ReadOnlyDatabase(both + "/workbuddy.db")?.rows("SELECT id FROM sessions") { sqliteText($0, 0) }
    let shmKept = shmBytes != nil && files.contents(atPath: shm) == shmBytes && FileStamp(shm) == shmStamp
    let walIDs = ReadOnlyDatabase(walOnly + "/workbuddy.db")?.rows("SELECT id FROM sessions") { sqliteText($0, 0) }
    let walLeft = ((try? files.contentsOfDirectory(atPath: walOnly)) ?? []).sorted()
    check(
        "wal: a read-only look leaves -shm as it was, bytes and time; with only an empty -wal it makes no -shm",
        bothIDs == [wbID] && shmKept && walIDs == [wbID] && walLeft == ["workbuddy.db", "workbuddy.db-wal"])

    // ── Neither app running: nothing listed, nothing read.
    let idleApp = CodexAppSessions(home: full)
    idleApp.running = { nil }
    let idleWB = WorkBuddySessions(home: wbHome)
    idleWB.running = { nil }
    let none = idleApp.load(now: tenLater).isEmpty && idleWB.load(now: wbNow).isEmpty
    let untouched = idleApp.touched == 0 && idleWB.touched == 0
    let reads = wide.touched
    wide.running = { nil }
    let closing = wide.load(now: tenLater).isEmpty && wide.touched == reads && wide.model(of: today) == nil
    check("sources: with neither app running, both sources return no sessions and read no files", none && untouched && closing && reads > 0)
}

/// With a panel that has never shown the office: the checks that need cut pet frames say they are
/// skipped instead of failing or crashing. Run here against an empty cache of the checks' own.
@MainActor func petFrameSkipTests() {
    let files = FileManager.default
    let empty = codexRealPath(NSTemporaryDirectory()) + "/no-frames-\(getpid())"
    try? files.createDirectory(atPath: empty, withIntermediateDirectories: true)
    defer { try? files.removeItem(atPath: empty) }
    let real = OfficePets.shared
    OfficePets.shared = OfficePets(folder: empty)
    let before = (failed: failed, skips: skips)
    func window(_ view: NSView) -> NSWindow {
        let made = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10), styleMask: .borderless, backing: .buffered, defer: false)
        made.contentView = view
        return made
    }
    officeWallAisleTests()
    officePairsTests(window: window)
    officeBackRowTests(now: Date())
    officeOverlapTests()
    let store = officeStateStore(1, 1, 1, 1, 1)
    let none = !officeDealCutPets(store)
    OfficePets.shared = real
    let skippedHere = skips - before.skips
    skips = before.skips  // skipped on purpose, not for want of frames
    let made = (try? files.contentsOfDirectory(atPath: empty)) ?? ["?"]
    check(
        "tests: the pet-frame-dependent checks skip cleanly when no frames are cut",
        failed == before.failed && skippedHere == 4 && none && made.isEmpty)
}

// ───────── A session being restarted stays put ─────────

/// A scratch Claude Code registry and restart list, read by a loader of the checks' own that sees no Codex and no app.
@MainActor final class RestartBench {
    let dir: String
    let registry: String
    let list: String
    let loader: Loader

    init(_ name: String) {
        dir = NSTemporaryDirectory() + "restart-\(name)-\(getpid())"
        registry = dir + "/sessions"
        list = dir + "/restarting.json"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: registry, withIntermediateDirectories: true)
        let noCLI = CodexSessions()
        noCLI.processes = { [] }
        loader = Loader(registry: registry, codex: noCLI, restarting: list)
    }

    /// Claude Code's file for a session, as `file`.json: pid 1 (launchd) counts as alive, as in the other fixtures.
    func open(_ id: String, _ status: String, since: Date, file: String? = nil, name: String? = nil) {
        let ms = since.timeIntervalSince1970 * 1000
        let o: [String: Any] = [
            "pid": 1, "sessionId": id, "status": status, "statusUpdatedAt": ms, "startedAt": ms, "name": name ?? "名-" + id,
            "nameSource": "user", "cwd": "/tmp/" + id,
        ]
        let data = try! JSONSerialization.data(withJSONObject: o)
        try? data.write(to: URL(fileURLWithPath: registry + "/" + (file ?? id) + ".json"))
    }

    func close(_ id: String, file: String? = nil) { try? FileManager.default.removeItem(atPath: registry + "/" + (file ?? id) + ".json") }

    /// The list as the restart script writes it: each id with how many seconds ago its restart began.
    func restarting(_ entries: [(String, TimeInterval)]) {
        let now = Date().timeIntervalSince1970
        var sessions: [[String: Any]] = []
        for (id, ago) in entries { sessions.append(["sessionId": id, "name": "名-" + id, "oldPid": 1, "since": (now - ago) * 1000]) }
        let data = try! JSONSerialization.data(withJSONObject: ["updatedAt": now * 1000, "sessions": sessions] as [String: Any])
        try? data.write(to: URL(fileURLWithPath: list), options: .atomic)
    }

    func load() -> [Session] { loader.load() }
    func done() { try? FileManager.default.removeItem(atPath: dir) }
}

func restartFind(_ list: [Session], _ id: String) -> Session? { list.first { $0.id == id } }

func restartSame(_ a: Date?, _ b: Date) -> Bool { a.map { abs($0.timeIntervalSince(b)) < 0.01 } ?? false }

/// The spinner on a figure of the office or an extension's scene, if it has one.
@MainActor func restartSpinner(_ view: NSView, _ id: String) -> CALayer? {
    if let carrier = officeStage(view)?.sublayers?.first(where: { $0.name == "restart-" + id }) {
        return carrier.sublayers?.first { $0.name == RestartSpinner.name }
    }
    return officePart(view, id, RestartSpinner.name)
}

/// Whether a layer, or anything in it, is animated.
@MainActor func restartTurning(_ layer: CALayer?) -> Bool {
    guard let layer else { return false }
    if !(layer.animationKeys() ?? []).isEmpty { return true }
    return (layer.sublayers ?? []).contains { restartTurning($0) }
}

/// Where two renderings of the same card differ, in the picture's pixels; nil when they do not.
func restartDifference(_ a: CGImage?, _ b: CGImage?) -> CGRect? {
    guard let a, let b, a.width == b.width, a.height == b.height else { return nil }
    let pa = Pixels(a), pb = Pixels(b)
    var box = CGRect.null
    for y in 0..<pa.height {
        for x in 0..<pa.width {
            let i = (y * pa.width + x) * 4
            if pa.data[i] != pb.data[i] || pa.data[i + 1] != pb.data[i + 1] || pa.data[i + 2] != pb.data[i + 2] {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
    }
    return box.isNull ? nil : box
}

/// Claude Code's background copies: the original handed to a copy is hidden while the copy lives; spares never show.
@MainActor func backgroundCopyTests() {
    let bench = RestartBench("bgcopy")
    defer { bench.done() }
    func write(_ file: String, _ extra: [String: Any]) {
        var o: [String: Any] = ["pid": 1, "status": "idle", "statusUpdatedAt": 1_000, "startedAt": 1_000, "cwd": "/tmp/bg", "nameSource": "user"]
        o.merge(extra) { _, new in new }
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: bench.registry + "/" + file + ".json"))
    }
    write("orig", ["sessionId": "61d4ed6a-orig", "name": "Home-星星-demo", "kind": "interactive", "status": "busy", "parkedJobId": "a8780d26"])
    write("copy", ["sessionId": "a8780d26-copy", "name": "Home-星星-demo", "kind": "bg", "jobId": "a8780d26"])
    write("spare", ["sessionId": "850c83b3-spare", "kind": "bg", "spare": true])
    write("plain", ["sessionId": "plain-1", "name": "Home-别的", "kind": "interactive"])
    let both = bench.load().map(\.id)
    check("background copy: the original handed to a live copy is hidden, the copy shown", !both.contains("61d4ed6a-orig") && both.contains("a8780d26-copy"))
    check("background copy: a spare background process is never shown", !both.contains("850c83b3-spare"))
    check("background copy: other sessions are untouched", both.contains("plain-1"))
    try? FileManager.default.removeItem(atPath: bench.registry + "/copy.json")
    let back = bench.load().map(\.id)
    check("background copy: once the copy is gone the original shows again", back.contains("61d4ed6a-orig"))
}

@MainActor func restartTests() {
    let now = Date()
    let t0 = now.addingTimeInterval(-600)

    // ── The loader.
    let bench = RestartBench("loader")
    defer { bench.done() }
    bench.open("ra", "idle", since: t0)
    bench.open("rb", "idle", since: now.addingTimeInterval(-300))
    bench.open("rc", "busy", since: now.addingTimeInterval(-60))
    let first = bench.load()
    let was = restartFind(first, "ra")
    // ra's restart begins and its file goes; rb is closed for real.
    bench.restarting([("ra", 5)])
    bench.close("ra")
    bench.close("rb")
    let gap = bench.load()
    let held = restartFind(gap, "ra")
    check(
        "restart: a listed session whose registry file vanished is still loaded with its last state, marked as restarting",
        first.count == 3 && was?.restarting == false && held?.restarting == true && held?.status == "idle" && held?.since == was?.since
            && held?.name == was?.name && held?.cwd == was?.cwd && held?.project == was?.project)
    check("restart: one not listed vanishes as today", restartFind(first, "rb") != nil && restartFind(gap, "rb") == nil
        && restartFind(gap, "rc")?.restarting == false)
    // The new process has written its file; the script has not taken the entry off yet.
    bench.open("ra", "idle", since: now.addingTimeInterval(-1), file: "ra-new")
    let early = bench.load()
    check(
        "restart: ...while it is listed a new file of it changes nothing: still its last state, one card",
        early.count == 2 && restartFind(early, "ra")?.restarting == true && restartFind(early, "ra")?.since == was?.since)

    // window swap: the old window is listed as restarting; the new one comes under the same name with a new id.
    let swap = RestartBench("swap")
    defer { swap.done() }
    swap.open("wa", "idle", since: t0, name: "Home-窗")
    _ = swap.load()
    swap.restarting([("wa", 5)])
    swap.close("wa")
    let between = swap.load()
    swap.open("wb", "idle", since: now, name: "Home-窗")
    let after = swap.load()
    check("restart: window swap — the old window is held while nothing of its name is listed",
        restartFind(between, "wa")?.restarting == true)
    check("restart: window swap — once the new window of the same name is listed, the old one is let go at once (one card, the new one)",
        restartFind(after, "wa") == nil && restartFind(after, "wb")?.restarting == false && after.count == 1)

    let stale = RestartBench("stale")
    defer { stale.done() }
    stale.open("rd", "idle", since: t0)
    let staleFirst = stale.load()
    stale.close("rd")
    stale.restarting([("rd", 121)])
    let expired = stale.load()
    check("restart: an entry older than 120 s is ignored: the session is gone as today",
        restartFind(staleFirst, "rd") != nil && restartFind(expired, "rd") == nil)
    stale.restarting([("re", 3), ("rf", 3)])
    stale.open("rf", "busy", since: now)
    let unseen = stale.load()
    check(
        "restart: an entry for a session whose file the panel never saw is ignored: nothing made up, a new file shown as it is",
        restartFind(unseen, "re") == nil && restartFind(unseen, "rf")?.restarting == false && restartFind(unseen, "rf")?.status == "busy")
    try? "not json".write(toFile: stale.list, atomically: true, encoding: .utf8)
    stale.close("rf")
    check("restart: an unreadable list means nobody is restarting", stale.load().isEmpty)

    // ── What the user marked survives, and coming back is not news.
    let kept = RestartBench("store")
    defer { kept.done() }
    kept.open("ra", "idle", since: t0)
    kept.open("rb", "idle", since: t0)
    kept.open("rc", "busy", since: now.addingTimeInterval(-60))
    let store = Store()
    store.readOnly = true
    store.take(kept.load(), at: now)
    let looked = t0.timeIntervalSince1970 + 30
    for id in ["ra", "rb"] {
        store.seen[id] = looked
        store.parked[id] = Store.Parking(zone: .rest, at: looked)
    }
    kept.restarting([("ra", 4)])
    kept.close("ra")
    kept.close("rb")
    store.take(kept.load(), at: now.addingTimeInterval(2))
    // Sending another to rest writes seen and parked, forgetting the sessions that are gone.
    if let other = restartFind(store.sessions, "rc") { store.rest(other) }
    check(
        "restart: seen and parked of a restarting session survive the gap; a session really gone loses them as today",
        store.seen["ra"] == looked && store.parked["ra"]?.zone == .rest && store.seen["rb"] == nil && store.parked["rb"] == nil
            && store.parked["rc"] != nil)
    kept.open("ra", "idle", since: now.addingTimeInterval(3), file: "ra-new")
    store.take(kept.load(), at: now.addingTimeInterval(4))
    kept.restarting([])
    store.take(kept.load(), at: now.addingTimeInterval(6))
    let back = restartFind(store.sessions, "ra")
    check(
        "restart: coming back idle with a newer since stays seen and resting: the since from before the restart is kept, the mark goes",
        back?.restarting == false && restartSame(back?.since, t0) && back.map { !store.isUnread($0) && !store.isFresh($0) } == true
            && back.map { store.isResting($0, now: now) } == true && store.parked["ra"] != nil)
    kept.open("ra", "busy", since: now.addingTimeInterval(8), file: "ra-new")
    store.take(kept.load(), at: now.addingTimeInterval(8))
    kept.open("ra", "idle", since: now.addingTimeInterval(10), file: "ra-new")
    store.take(kept.load(), at: now.addingTimeInterval(10))
    let later = restartFind(store.sessions, "ra")
    check(
        "restart: ...a real new turn afterwards behaves as always: news again",
        restartSame(later?.since, now.addingTimeInterval(10)) && later.map { store.isUnread($0) } == true)

    // ── A restarted session's new process rewrites its idle file a second after starting, and may be busy
    // while it starts up; neither is news. Only a new reply, or a turn after it was back idle, is.
    let again = RestartBench("rewrite")
    defer { again.done() }
    let note = again.dir + "/ra.jsonl"
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func reply(_ at: Date) -> String { reply(iso.string(from: at)) }
    func reply(_ stamp: String) -> String {
        "{\"type\":\"assistant\",\"timestamp\":\"\(stamp)\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"好了\"}]}}\n"
    }
    let said = t0.addingTimeInterval(-5)
    try? reply(said).write(toFile: note, atomically: true, encoding: .utf8)
    again.loader.remember(transcript: note, for: "ra")
    again.loader.remember(transcript: again.dir + "/rb.jsonl", for: "rb")
    again.open("ra", "idle", since: t0)
    again.open("rb", "idle", since: t0)
    let s2 = Store()
    s2.readOnly = true
    s2.take(again.load(), at: now)
    s2.seen["ra"] = t0.timeIntervalSince1970 + 30
    s2.seen["rb"] = t0.timeIntervalSince1970 + 30
    again.restarting([("ra", 4), ("rb", 4)])
    again.close("ra")
    again.close("rb")
    s2.take(again.load(), at: now.addingTimeInterval(2))
    again.open("ra", "idle", since: now.addingTimeInterval(3), file: "ra-new")
    again.open("rb", "busy", since: now.addingTimeInterval(3), file: "rb-new")
    again.restarting([])
    s2.take(again.load(), at: now.addingTimeInterval(4))
    again.open("ra", "idle", since: now.addingTimeInterval(5), file: "ra-new")
    again.open("rb", "idle", since: now.addingTimeInterval(6), file: "rb-new")
    s2.take(again.load(), at: now.addingTimeInterval(7))
    let ra2 = restartFind(s2.sessions, "ra"), rb2 = restartFind(s2.sessions, "rb")
    check(
        "restart: back idle and its file rewritten a moment later, or busy while starting up then idle: still not news",
        ra2.map { $0.since <= t0 } == true && restartSame(rb2?.since, t0) && ra2.map { !s2.isUnread($0) } == true
            && rb2.map { !s2.isUnread($0) } == true)
    try? (reply(said) + reply(now.addingTimeInterval(9))).write(toFile: note, atomically: true, encoding: .utf8)
    again.open("ra", "idle", since: now.addingTimeInterval(9), file: "ra-new")
    s2.take(again.load(), at: now.addingTimeInterval(10))
    let ra3 = restartFind(s2.sessions, "ra")
    check("restart: ...a new reply in its transcript is news again",
        restartSame(ra3?.since, now.addingTimeInterval(9)) && ra3.map { s2.isUnread($0) } == true)

    // The panel itself restarted after such a round: it never saw the session before. The idle file's moment is the
    // restart; its last reply is older than what the user looked at, so it is not news. One whose last reply is new is.
    let cold = RestartBench("cold")
    defer { cold.done() }
    for (id, ago) in [("rg", 3600.0), ("rh", 20.0)] {
        let path = cold.dir + "/\(id).jsonl"
        try? reply(now.addingTimeInterval(-ago)).write(toFile: path, atomically: true, encoding: .utf8)
        cold.loader.remember(transcript: path, for: id)
        cold.open(id, "idle", since: now.addingTimeInterval(-10))
    }
    let s3 = Store()
    s3.readOnly = true
    s3.seen["rg"] = now.addingTimeInterval(-1800).timeIntervalSince1970
    s3.seen["rh"] = now.addingTimeInterval(-1800).timeIntervalSince1970
    s3.take(cold.load(), at: now)
    let rg = restartFind(s3.sessions, "rg"), rh = restartFind(s3.sessions, "rh")
    check(
        "restart: after the panel restarts, an idle session whose file is newer but whose last reply he has seen is not news; one with a new reply is",
        rg.map { !s3.isUnread($0) && abs($0.since.timeIntervalSince(now.addingTimeInterval(-3600))) < 1 } == true
            && rh.map { s3.isUnread($0) } == true)

    // ── The office, in both its themes: nobody moves for a restart; the spinner shows over the one restarting.
    NSApplication.shared.setActivationPolicy(.accessory)
    let size = CGRect(x: 0, y: 0, width: 1194, height: 764)
    for theme in OfficeTheme.officeThemes {
        OfficeTheme.shown = theme
        let room = RestartBench("office")
        room.open("ra", "idle", since: t0)
        room.open("rb", "idle", since: t0)
        room.open("rc", "busy", since: now.addingTimeInterval(-60))
        let office = Store()
        office.readOnly = true
        office.take(room.load(), at: now)
        for id in ["ra", "rb"] { office.seen[id] = now.timeIntervalSince1970 }
        let view = OfficeTestView(frame: size)
        let window = NSWindow(
            contentRect: NSRect(origin: CGPoint(x: -4000, y: -4000), size: size.size), styleMask: .borderless, backing: .buffered,
            defer: false)
        window.contentView = view
        window.orderFrontRegardless()
        view.update(office)
        CATransaction.flush()
        let before = officeFigure(view, "ra")?.position
        func calm(_ id: String) -> Bool { ["walk", "swap", "door"].allSatisfy { officeFigure(view, id)?.animation(forKey: $0) == nil } }
        room.restarting([("ra", 3)])
        room.close("ra")
        office.take(room.load(), at: now.addingTimeInterval(2))
        view.update(office)
        CATransaction.flush()
        room.open("ra", "idle", since: now.addingTimeInterval(3), file: "ra-new")
        office.take(room.load(), at: now.addingTimeInterval(4))
        view.update(office)
        CATransaction.flush()
        let spinner = restartSpinner(view, "ra")
        check(
            "restart: office (\(theme.name)): the restarting one keeps its place and does not walk; a spinner over it, none on the others",
            before != nil && officeFigure(view, "ra")?.position == before && calm("ra") && spinner != nil && restartSpinner(view, "rb") == nil
                && restartSpinner(view, "rc") == nil)
        let head = officePart(view, "ra", "sprite")?.frame ?? .null, words = officePart(view, "ra", "words")?.frame ?? .null
        let shown = (spinner?.bounds.width ?? 0) * OfficeFit(size.size).scale
        let box = spinner?.frame ?? .null
        print(String(format: "      restart office %@: spinner %@ (%.1f pt on screen), head %@, words %@", theme.name, NSStringFromRect(box), shown, NSStringFromRect(head), NSStringFromRect(words)))
        check(
            "restart: office (\(theme.name)): the spinner sits at the head, clear of its words, 14–18 pt on screen, and turns",
            !box.isNull && !head.isNull && box.midY < head.minY + head.height * 0.25 && !box.intersects(words) && shown >= 14 && shown <= 18
                && restartTurning(spinner))
        view.calmed = true
        view.update(office)
        check("restart: office (\(theme.name)): with Reduce Motion the spinner is shown still", restartSpinner(view, "ra") != nil && !restartTurning(restartSpinner(view, "ra")))
        view.calmed = false
        // Closed for real meanwhile: rb leaves at once.
        room.close("rb")
        office.take(room.load(), at: now.addingTimeInterval(6))
        view.update(office)
        CATransaction.flush()
        check(
            "restart: office (\(theme.name)): one really closed walks out at once while the restarting one stands",
            officeFigure(view, "rb")?.animation(forKey: "walk") != nil && calm("ra") && officeFigure(view, "ra")?.position == before)
        room.restarting([])
        office.take(room.load(), at: now.addingTimeInterval(8))
        view.update(office)
        CATransaction.flush()
        check(
            "restart: office (\(theme.name)): back, the spinner goes and it carries on from where it stood",
            restartSpinner(view, "ra") == nil && calm("ra") && officeFigure(view, "ra")?.position == before)
        window.contentView = nil
        room.done()
    }
    OfficeTheme.shown = nil

    // ── The board: a small spinner on its card (wide and narrow), at the pet, and nothing else changes.
    let plain = Session(id: "bd", pid: 1, project: "项目", name: "重启中", status: "idle", since: t0, summary: "做完了，等你看。")
    var turning = plain
    turning.restarting = true
    let board = Store()
    board.readOnly = true
    board.sessions = [plain]
    board.seen["bd"] = now.timeIntervalSince1970
    func card(_ s: Session) -> CGImage? {
        let content = AgentCard(s: s).frame(width: 320).environmentObject(board).environment(\.zoom, 1).environment(\.still, true)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.cgImage
    }
    func row(_ s: Session) -> CGImage? {
        let content = InboxRow(s: s).frame(width: 320).environmentObject(board).environment(\.zoom, 1).environment(\.still, true)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        return renderer.cgImage
    }
    let wide = restartDifference(card(plain), card(turning)), narrow = restartDifference(row(plain), row(turning))
    print("      restart board: card differs in \(wide.map(NSStringFromRect) ?? "nothing"), row in \(narrow.map(NSStringFromRect) ?? "nothing") (pixels at 2x)")
    check(
        "restart: board: a restarting session's card and row show a spinner at the pet, and nothing beside it changes",
        wide != nil && narrow != nil && (wide?.maxX ?? .infinity) <= 64 * 2 && (narrow?.maxX ?? .infinity) <= 52 * 2
            && restartDifference(card(plain), card(plain)) == nil)

    // ── No timer for it: the store's tick is the only one, and nothing draws frame by frame.
    let sources = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
    func count(_ file: String, _ word: String) -> Int {
        let text = file == "Panel.swift" ? panelSources(sources) : (try? String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)) ?? ""
        return text.count > 100_000 ? text.components(separatedBy: word).count - 1 : -1
    }
    // No @State: a Command Line Tools install without SwiftUI's macro plugin cannot expand it (build.sh refuses it too).
    let stateUses = (["Panel.swift"] + dataSourceFiles + ["Office.swift", "Extensions.swift", "ZoneModel.swift", "ZoneView.swift", "ZoneFX.swift", "SessionSearch.swift",
                     "JumpMark.swift", "Settings.swift", "L10n.swift"]).filter { file in
        let text = (try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(file), encoding: .utf8)) ?? "@State"
        return text.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).range(of: #"^@State(\s|\(|$)"#, options: .regularExpression) != nil }
    }
    check("restart: no @State in the app's sources (\(stateUses.joined(separator: ", ")))", stateUses.isEmpty)
    // Package.swift (swift build, Xcode) lists the same sources as build.sh's swiftc line, the extension's stand-in included.
    let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let buildLine = ((try? String(contentsOf: here.appendingPathComponent("build.sh"), encoding: .utf8)) ?? "")
        .split(separator: "\n").first { $0.hasPrefix("swiftc ") }.map(String.init) ?? ""
    let built = buildLine.split(separator: " ").map(String.init).filter { $0.hasSuffix(".swift") } + ["NoExtensions.swift"]
    let manifest = (try? String(contentsOf: here.appendingPathComponent("Package.swift"), encoding: .utf8)) ?? ""
    let listed = manifest.components(separatedBy: "sources: [").dropFirst().first?.components(separatedBy: "]").first?
        .split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) } ?? []
    check("restart: Package.swift lists the sources build.sh compiles (\(Set(built).symmetricDifference(listed).sorted().joined(separator: ", ")))",
          built.count > 10 && Set(built) == Set(listed) && listed.count == Set(listed).count)
    check(
        "restart: no Timer added: Panel.swift schedules only the store's tick, Office.swift none, neither draws frame by frame",
        count("Panel.swift", "scheduledTimer") == 1 && count("Office.swift", "scheduledTimer") == 0
            && ["Panel.swift", "Office.swift"].allSatisfy { count($0, "TimelineView") == 0 && count($0, "CVDisplayLink") == 0 })
}

// ───────── Who started the turn (shared with the board WebApp) ─────────

@MainActor func originTests() {
    func rec(_ content: Any, meta: Bool = false, sidechain: Bool = false, type: String = "user", stamp: String = "2026-10-19T01:00:00.000Z") -> String {
        var o: [String: Any] = ["type": type, "isSidechain": sidechain, "timestamp": stamp, "message": ["role": type, "content": content]]
        if meta { o["isMeta"] = true }
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    func reply(_ text: String) -> String {
        rec([["type": "text", "text": text]], type: "assistant", stamp: "2026-10-19T01:00:05.000Z")
    }
    let peerText = "Another Claude session sent a message:\n<cross-session-message from=\"uds:/tmp/cc-socks/1.sock\" from-name=\"Sky\" from-mode=\"bypass\">\nSD 回复：打印件已出</cross-session-message>"
    let agentText = "Another Claude session sent a message:\n<agent-message from=\"a0f56c1a777ee25b3\">\n[Subagent hand-back] report</agent-message>"
    let taskText = "<task-notification>\n<task-id>a2d</task-id>\n</task-notification>"

    // Pure: the text of one string user record.
    func classify(_ t: String) -> String { let o = classifyTurnText(t); return o.origin + "|" + o.peer }
    check("origin: a peer message is peer, with its from-name", classify(peerText) == "peer|Sky")
    check("origin: a subagent hand-back that also starts with the peer line is agent (agent before peer)", classify(agentText) == "agent|")
    check("origin: a bare <agent-message is agent", classify("<agent-message from=\"x\">ok</agent-message>") == "agent|")
    check("origin: <task-notification is agent, also after leading blanks", classify("  \n" + taskText) == "agent|")
    check("origin: a cross-session tag without from-name is peer with no name",
        classify("<cross-session-message from=\"uds:x\">hi</cross-session-message>") == "peer|")
    check("origin: plain text he typed is user", classify("帮我看看这个") == "user|")

    // Through the loader, on transcript tails shaped like real ones.
    let bench = RestartBench("origin")
    defer { bench.done() }
    let now = Date()
    func origin(_ lines: [String], _ id: String) -> Session? {
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        bench.loader.remember(transcript: path, for: id)
        bench.open(id, "idle", since: now)
        return bench.load().first { $0.id == id }
    }
    let toolResult = rec([["type": "tool_result", "tool_use_id": "t1", "content": "ok"]])
    let peer = origin([rec("先做 A"), reply("好"), rec(peerText, meta: true), reply("收到")], "o-peer")
    check("origin: loader — last string user record a peer message (isMeta): peer Sky", peer?.origin == "peer" && peer?.peer == "Sky")
    let agent = origin([rec("先做 A"), rec(agentText), toolResult, reply("看完了")], "o-agent")
    check("origin: loader — a subagent hand-back, tool results after it skipped: agent", agent?.origin == "agent" && agent?.peer == "")
    let task = origin([rec("先做 A"), rec(taskText), reply("后台跑完了")], "o-task")
    check("origin: loader — a task notification: agent", task?.origin == "agent")
    let side = origin([rec(peerText, meta: true), rec("子代理内部", sidechain: true), reply("x")], "o-side")
    check("origin: loader — a sidechain record is skipped: the peer before it counts", side?.origin == "peer")
    let array = origin([rec(agentText), rec([["type": "text", "text": "数组内容"]]), reply("x")], "o-array")
    check("origin: loader — a user record with array content is skipped", array?.origin == "agent")
    let meta = origin([rec(peerText, meta: true), rec("<command-name>/clear</command-name>", meta: true), reply("x")], "o-meta")
    check("origin: loader — another isMeta record (system injected) is skipped", meta?.origin == "peer")
    let typed = origin([rec(peerText, meta: true), reply("x"), rec("接着做 B"), reply("好")], "o-user")
    check("origin: loader — his own text after a peer message: user", typed?.origin == "user" && typed?.peer == "")
    let empty = origin([reply("只有回复")], "o-empty")
    check("origin: loader — no user record at all: user", empty?.origin == "user")

    // The card's summary never shows a peer's or a subagent's wrapper as a "You: ..." line.
    let later = "2026-10-19T01:00:10.000Z"
    let handing = origin([rec("先做 A"), reply("好"), rec(agentText, stamp: later)], "o-sum-agent")
    check("origin summary: a hand-back newer than the reply is not a \"You: ...\" line, it reports handling a subagent hand-back",
        handing?.summary == "处理子代理回报…")
    let peering = origin([rec("先做 A"), reply("好"), rec(peerText, stamp: later)], "o-sum-peer")
    check("origin summary: a peer message newer than the reply reports handling that peer's report", peering?.summary == "处理 Sky 的回报…")
    let handled = origin([rec("先做 A", stamp: "2026-10-19T00:59:00.000Z"), rec(agentText), reply("看完了")], "o-sum-done")
    check("origin summary: a hand-back answered shows the reply", handled?.summary == "看完了")
    let typedAfter = origin([rec(agentText), reply("看完了"), rec("接着做 B", stamp: later)], "o-sum-typed")
    check("origin summary: his own words newer than all: a \"You: ...\" line", typedAfter?.summary == "你：接着做 B")
    let noReply = origin([rec("先做 A"), rec(agentText, stamp: later)], "o-sum-noreply")
    check("origin summary: with no reply yet the wrapper is never shown", noReply?.summary.contains("Another Claude") == false)
    // A content-free reply ("No response requested.", "Got it.", "OK.") is passed over for the one before it.
    func said(_ text: String, _ stamp: String) -> String { rec([["type": "text", "text": text]], type: "assistant", stamp: stamp) }
    let filler = origin([rec("先做 A"), said("A 做完了，结果在 out/", "2026-10-19T01:00:02.000Z"), rec(peerText, meta: true),
        said("No response requested.", "2026-10-19T01:00:08.000Z")], "o-sum-filler")
    check("origin summary: \"No response requested.\" after a peer note: the informative reply before it", filler?.summary == "A 做完了，结果在 out/")
    let ack = origin([said("报告已发", "2026-10-19T01:00:02.000Z"), rec(agentText, stamp: "2026-10-19T01:00:04.000Z"), said("收到。", "2026-10-19T01:00:08.000Z")], "o-sum-ack")
    check("origin summary: a bare acknowledgement after a hand-back: falls back to the subagent hand-back line (newer than the informative reply)", ack?.summary == "处理子代理回报…")
    let okay = origin([rec("先做 A"), said("好的。", "2026-10-19T01:00:08.000Z")], "o-sum-ok")
    check("origin summary: a bare OK alone, nothing before it: the \"You: ...\" line", okay?.summary == "你：先做 A")
    let short = origin([rec("Owl 正常吗"), said("正常。", "2026-10-19T01:00:08.000Z")], "o-sum-short")
    check("origin summary: a short reply that says something (a short status word) is kept", short?.summary == "正常。")
    let none = Loader(registry: bench.dir + "/none").load()
    check("origin: a session never read is user by default", session("x").origin == "user" && none.isEmpty)

    // Unread: a peer or agent turn finished is not news; the user's own is, as before; pins and waiting unchanged.
    let store = Store()
    store.readOnly = true
    func s(_ id: String, _ status: String, _ origin: String, peer: String = "") -> Session {
        var x = session(id, status, finished: 10)
        x.origin = origin
        x.peer = peer
        return x
    }
    let u = s("t1-u", "idle", "user"), p = s("t1-p", "idle", "peer", peer: "Sky"), a = s("t1-a", "idle", "agent"), w = s("t1-w", "waiting", "peer")
    store.sessions = [u, p, a, w]
    check("origin unread: a user turn finished is fresh and unread", store.isFresh(u) && store.isUnread(u))
    check("origin unread: a peer turn finished is not fresh, not unread", !store.isFresh(p) && !store.isUnread(p))
    check("origin unread: an agent turn finished is not fresh, not unread", !store.isFresh(a) && !store.isUnread(a))
    let b = Buckets(store, now: Date())
    check("origin unread: the unread group holds only the user turn; waiting stays waiting whatever its origin",
        b.unread.map(\.id) == ["t1-u"] && b.waiting.map(\.id) == ["t1-w"])
    check("origin unread: the peer and agent turns sit with the looked-at ones", Set(b.seen.map(\.id)) == ["t1-p", "t1-a"])
    store.togglePin(p)
    check("origin unread: a pinned peer turn stays under unread", store.isUnread(p) && Buckets(store, now: Date()).unread.count == 2)
    store.togglePin(p)
    check("origin unread: a peer turn raises no hand", store.pose(of: p, now: Date()) != .handUp && store.pose(of: p, now: Date()) != .waving)
    check("origin unread: the user turn does", [.waving, .handUp].contains(store.pose(of: u, now: Date())))

    // No jump for one that finished a peer or agent turn; one that finished their own still jumps.
    let jump = Store()
    jump.readOnly = true
    let t = Date()
    jump.take([s("j-u", "busy", "user"), s("j-p", "busy", "peer")], at: t)
    jump.take([s("j-u", "idle", "user"), s("j-p", "idle", "peer")], at: t.addingTimeInterval(1))
    jump.take([s("j-u", "idle", "user"), s("j-p", "idle", "peer")], at: t.addingTimeInterval(3))  // the celebration is decided a tick later
    check("origin: a finished user turn celebrates, a finished peer turn does not",
        jump.celebrating["j-u"] != nil && jump.celebrating["j-p"] == nil)

    // The faint card line.
    check("origin note: peer → a two-way arrow with the peer's name", originNote(p) == "↔ 与 Sky 往来")
    check("origin note: peer without a name", originNote(s("n", "idle", "peer")) == "↔ 与其他会话往来")
    check("origin note: agent → a gear and the subagent hand-back words", originNote(a) == "⚙ 处理了子代理回报")
    check("origin note: none for a user turn, nor while waiting or busy",
        originNote(u) == nil && originNote(w) == nil && originNote(s("bz", "busy", "peer")) == nil)

    // The notice board: logged, but marked and not counted as unseen.
    let before = [s("b-u", "busy", "user"), s("b-p", "busy", "peer", peer: "Sky"), s("b-a", "busy", "agent")]
    let after = [s("b-u", "idle", "user"), s("b-p", "idle", "peer", peer: "Sky"), s("b-a", "idle", "agent")]
    let events = OfficeActivity.events(from: before, to: after, at: t)
    check("origin board: all three finished are logged, the peer and agent ones marked",
        events.map(\.text) == ["干完了", "↔ 干完了（与 Sky 往来）", "⚙ 干完了（子代理回报）"])
    var log = OfficeActivity()
    log.add(events)
    check("origin board: only the user turn counts as unseen", log.unseen == 1 && log.events.count == 3)
    let lines = OfficeBoardCard.lines(log, waiting: [], now: t)
    check("origin board: the marked lines have the quiet dot",
        lines.filter { $0.dot == OfficeActivity.Event.Kind.talk.dot }.count == 2)
    let coded = (try? JSONEncoder().encode(log)).flatMap { try? JSONDecoder().decode(OfficeActivity.self, from: $0) }
    check("origin board: the marks survive a save and load", coded?.events.map(\.text) == events.map(\.text))
}


/// The workzones every check and picture sees unless it writes its own (`Tests.main`): made-up zones, one on each of the
/// room's islands by name.
let checksZonesJSON = """
    {"zones": {"Web": {"name": "Web", "color": "#E0A040", "order": 1, "lead": "Web-SKY-飞船"},
               "Ops": {"name": "Ops", "color": "#40B0A0", "order": 2, "lead": "Ops-SEA-海螺"},
               "AI": {"name": "AI", "color": "#5080D0", "order": 3, "lead": "AI-lead"},
               "Home": {"name": "Home", "color": "#A070D0", "order": 4, "lead": "Home-lead"}},
     "dirs": {}, "default": null,
     "offduty": {"resident": ["Home-Moon", "Home-Moon-月光", "Home-星星", "AI-Teacup", "AI-Pixie-Queen"], "resident_zones": ["Ops"]}}
    """

@main struct Tests {
    @MainActor static func main() {
        // The checks read the simplified words (their expectations are written in them), whatever the machine's language;
        // `--lang <code>` asks for another, for pictures.
        L10n.pin(L10n.source)
        L10n.applyArguments(CommandLine.arguments)
        // The checks' made-up sessions work in ~/Projects/…: that is their projects folder, whatever this Mac's setting.
        projectsRoot = home + "/Projects/"
        // The notice board's log goes to a scratch file of the checks' own: the panel's is never touched.
        OfficeActivity.file = NSTemporaryDirectory() + "office-activity-\(getpid()).json"
        defer { try? FileManager.default.removeItem(atPath: OfficeActivity.file) }
        // Unread marks and pins are kept in the defaults; start from none and leave none behind.
        let domain = ProcessInfo.processInfo.processName
        UserDefaults.standard.removePersistentDomain(forName: domain)
        defer {
            UserDefaults.standard.removePersistentDomain(forName: domain)
            UserDefaults.standard.synchronize()
        }
        // The fixtures all run as pid 1, launchd, which Orca did not start: read its environment once now, so that no check
        // waits a round for its pane to be looked up.
        _ = OrcaTabs.shared.tab(of: 1)
        // The Codex app and WorkBuddy of the machine running the checks are never read: only copies of the fixtures,
        // handed to sources of the checks' own.
        appSessionsLive = false
        // Nor are its workzones: the checks and pictures see four made-up zones on the room's four islands, whatever the
        // machine's ~/.claude/workzones.json says (checks that need others write their own).
        let zonesFile = NSTemporaryDirectory() + "checks-workzones-\(getpid()).json"
        try? checksZonesJSON.write(toFile: zonesFile, atomically: true, encoding: .utf8)
        ZoneConfigFile.path = zonesFile
        defer { try? FileManager.default.removeItem(atPath: zonesFile) }
        if ProcessInfo.processInfo.environment["OFFICE_CPU"] != nil { return officeDiscoCost() }

        // An extension's scene (`Extensions`): its own runs of the checks binary first; the panel's checks and pictures then
        // see the panel as it is here, with no extension; its own checks run after them, its scene registered again.
        registerExtensions()
        if extensionRun() { return }
        let extensionScene = Extensions.registered
        Extensions.registered = nil
        if CommandLine.arguments.contains("--aura-cpu") {
            auraCPU()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--aura-sheet"), i + 1 < CommandLine.arguments.count {
            auraSheet(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--aura-stills"), i + 1 < CommandLine.arguments.count {
            auraStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-walk-strip"), i + 1 < CommandLine.arguments.count {
            zoneWalkStrip(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--jump-mark-still"), i + 1 < CommandLine.arguments.count {
            jumpMarkStill(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-orca-stills"), i + 1 < CommandLine.arguments.count {
            zoneOrcaStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-outdoors-stills"), i + 1 < CommandLine.arguments.count {
            zoneOutdoorsStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-off-duty-stills"), i + 1 < CommandLine.arguments.count {
            zoneOffDutyStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-figure-size-stills"), i + 1 < CommandLine.arguments.count {
            zoneFigureSizeStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-drag-stills"), i + 1 < CommandLine.arguments.count {
            zoneDragStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-open-room-stills"), i + 1 < CommandLine.arguments.count {
            zoneOpenRoomStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-art-stills"), i + 1 < CommandLine.arguments.count {
            zoneArtStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-placement-stills"), i + 1 < CommandLine.arguments.count {
            zonePlacementStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--walk-facing-stills"), i + 1 < CommandLine.arguments.count {
            walkFacingStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--sea-sweep-stills"), i + 1 < CommandLine.arguments.count {
            seaSweepStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--sea-sweep-perf") {
            seaSweepPerf()
            return
        }
        if CommandLine.arguments.contains("--nudge-only") {
            nudgeTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--nudge-stills"), i + 1 < CommandLine.arguments.count {
            nudgeStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--nudge-burst"), i + 1 < CommandLine.arguments.count {
            nudgeBurst(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--demo-only") {
            demoTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo-gif-frames"), i + 1 < CommandLine.arguments.count {
            demoGifFrames(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--demo-stills"), i + 1 < CommandLine.arguments.count {
            demoStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--codex-only") {
            codexTests()
            appTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--fix-only") {
            fixTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--focus-hold-only") {
            focusHoldTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--visit-stills"), i + 1 < CommandLine.arguments.count {
            visitStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--visit-probe"), i + 1 < CommandLine.arguments.count {
            visitProbe(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--visit-live"), i + 1 < CommandLine.arguments.count {
            visitLive(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--visit-user"), i + 1 < CommandLine.arguments.count {
            visitUserStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--visit-only") {
            visitTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--sea-sweep-only") {
            seaSweepTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--scene-stills"), i + 1 < CommandLine.arguments.count {
            sceneExtStills(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--zone-fx-still"), i + 1 < CommandLine.arguments.count {
            zoneFXStill(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--jump-mark-only") {
            jumpMarkTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--origin-only") {
            originTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--sync-only") {
            phoneSyncTests(); pinTests(); officePaneTests(); restartTests(); backgroundCopyTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--focus-only") {
            officeFocusTests(); officeFocusOrphanTests(); officeSpotlightTests(); officeSpotlightLiveTests(); officeSpotlightSeenTests(); officeDiscoTests()
            focusHoldTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--board-stills"), i + 1 < CommandLine.arguments.count {
            boardSweepStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--newroom-only") {
            officeNewRoomTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--board-sweep-only") || CommandLine.arguments.contains("--office-only") {
            officeMenuTests(); boardSweepTests(); officeCardTests(); officeListTests(); officeActivityTests(); officeSubagentTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--fl-icon-stills"), i + 1 < CommandLine.arguments.count {
            flIconStills(CommandLine.arguments[i + 1], oldFin: i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : nil)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--settings-stills"), i + 1 < CommandLine.arguments.count {
            settingsStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--zone-only") {
            zoneTests()
            zoneFXTests()
            menuBarTests()
            seaSweepTests()
            visitTests()
            deskCoverTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--scene-only") {
            sceneExtTests(); menuBarTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--aura-only") {
            auraTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--i18n-only") {
            i18nTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--i18n-theme-legacy-stills"), i + 1 < CommandLine.arguments.count {
            i18nThemeLegacyStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--flame-only") {
            flameTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--flame-stills"), i + 1 < CommandLine.arguments.count {
            flameStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--summary-only") {
            summaryCodeTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--error-only") {
            errorFieldTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--format-only") {
            formatWarningTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--dumplog-only") {
            dumpLogTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--bg-render-only") {
            bgRenderTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--bg-render-stills"), i + 1 < CommandLine.arguments.count {
            bgRenderStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--error-render-only") {
            errorRenderTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--error-render-stills"), i + 1 < CommandLine.arguments.count {
            errorRenderStills(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--bg-only") {
            bgTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--desk-cover-only") {
            deskCoverTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--desk-cover-still"), i + 1 < CommandLine.arguments.count {
            deskCoverStill(CommandLine.arguments[i + 1])
            return
        }
        if CommandLine.arguments.contains("--summary-sample") {
            summaryCodeSample()
            return
        }
        if CommandLine.arguments.contains("--walk-only") {
            walkTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        if CommandLine.arguments.contains("--cards-only") {
            officeCardTests(); officeSubagentTests(); officeListTests(); officeHoverSpotTests(); officeThemeTests()
            print(failed == 0 ? "all passed" : "\(failed) failed")
            if failed > 0 { exit(1) }
            return
        }
        officeMemoryTests()
        codexTests()
        appTests()
        petFrameSkipTests()
        usageTests()
        pinTests()
        phoneSyncTests()
        backgroundCopyTests()
        trailTests()
        linkTests()
        readOnlyTests()
        restartTests()
        originTests()
        summaryCodeTests()
        bgTests()
        bgRenderTests()
        errorRenderTests()
        errorFieldTests()
        officePaneTests()
        petChangeTests()
        jumpMarkTests()
        flightTests()
        officeTests()
        officeViewTests()
        officeLiveTests()
        officeSwitchTests()
        officeSeatTests()
        officeRoomRulesTests()
        officeKeepingTests()
        officeChainTests()
        officeRoundTests()
        officeVisitRuleTests()
        officeVisitChainTests()
        officeRouteTests()
        officePieceTests()
        officeMotionTests()
        officePrepareTests()
        officeActivityTests()
        officeFinalTests()
        officeMenuTests()
        officeCardTests()
        officeSubagentTests()
        officeListTests()
        officeUnfoldTests()
        officeNewRoomTests()
        officeWalkClearTests()
        officeOverlapTests()
        officeHoverSpotTests()
        officeThemeTests()
        officeRestDeskTests()
        officeFocusTests()
        officeFocusOrphanTests()
        officeSpotlightTests()
        officeSpotlightLiveTests()
        officeSpotlightSeenTests()
        officeDiscoTests()
        focusHoldTests()
        zoneTests()
        zoneFXTests()
        walkTests()
        auraTests()
        menuBarTests()
        seaSweepTests()
        visitTests()
        deskCoverTests()
        boardSweepTests()
        sceneExtTests()
        i18nTests()
        flameTests()
        nudgeTests()
        dumpLogTests()
        formatWarningTests()
        demoTests()
        fixTests()
        Extensions.registered = extensionScene
        extensionChecks()
        let skippedNote = skips == 0 ? "" : " (\(skips) skipped)"
        print(failed == 0 ? "all passed" + skippedNote : "\(failed) failed" + skippedNote)
        if failed > 0 {
            try? FileManager.default.removeItem(atPath: OfficeActivity.file)  // `exit` skips the `defer` above
            exit(1)
        }
    }
}
