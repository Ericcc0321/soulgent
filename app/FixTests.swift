import AppKit
import QuartzCore

// Behaviours kept by these checks: the spotlight reads no app but Orca, a pet sheet that will not decode (or is too small
// for its cells) is not decoded again and again, a crowd larger than the pool keeps its pets, seaview room builds its lights
// and labels again when the workzones change, `--capture-live` writes only a regular file and only once the picture is
// there, and a transcript's long lines are read within bounds. `fixTests()` is in `--fix-only` and the full run.

@MainActor func fixTests() {
    fixSpotlightTests()
    fixPetDealTests()
    fixBrokenPetTests()
    fixZoneRebuildTests()
    fixStaleWaitingTests()
    fixCaptureLiveTests()
    fixLongLineTests()
    fixSmallSheetTests()  // last: a sheet too small for its cells can stop the run where it is not refused
}

/// No Orca running and another app in front: the light stays full, and that app is never opened to readers or looked at.
@MainActor func fixSpotlightTests() {
    let store = Store()
    store.readOnly = true
    store.sessions = [Session(id: "fx-a", pid: 501, project: "demo", name: "Demo-a", status: "idle", since: Date() - 60, summary: "")]
    var front: (bundle: String, pid: pid_t)? = ("com.example.editor", 77)
    var running = false, opened: [pid_t] = [], looked: [pid_t] = []
    let focus = store.focus
    focus.queue = nil
    focus.frontmost = { front }
    focus.running = { running }
    focus.trusted = { true }
    focus.enhance = { pid, _ in opened.append(pid); return "made up" }
    focus.watch = { pid, _ in opened.append(pid); return (nil, "made up") }
    focus.findBar = { pid in looked.append(pid); return ([], 0) }
    focus.readBar = { _ in .gone }
    focus.list = { nil }
    focus.tab = { _ in nil }
    focus.pane = { _ in nil }
    focus.note = { _ in }
    let switchKey = "officeSpotlight", switchWas = UserDefaults.standard.object(forKey: switchKey)
    UserDefaults.standard.removeObject(forKey: switchKey)  // on, as by default
    defer { if let switchWas { UserDefaults.standard.set(switchWas, forKey: switchKey) } else { UserDefaults.standard.removeObject(forKey: switchKey) } }

    store.readFocus()
    check("fix spotlight: no Orca running, another app in front: the light stays full", store.orcaInFront)
    check("fix spotlight: ...and that app is not opened to readers, watched or looked through", opened.isEmpty && looked.isEmpty)
    running = true
    front = (OfficeFocus.orca, 42)
    store.readFocus()
    check("fix spotlight: Orca in front is still read as before", opened.contains(42) && looked == [42])
}

/// Three sessions, two pets: the two who have their own keep them, the third keeps the one it shares, round after round.
@MainActor func fixPetDealTests() {
    let defaults = UserDefaults.standard
    let keys = ["petBySession", "petByPane", "petByPaneOrder", "favoritePets", "petByName", "petByNameOrder", "bannedPets"]
    let kept = keys.map { defaults.object(forKey: $0) }
    let shared = Pets.shared, registered = Extensions.registered
    Extensions.registered = nil
    let fm = FileManager.default
    let scratch = NSTemporaryDirectory() + "fix-deal-\(getpid())"
    defer {
        Pets.shared = shared
        Extensions.registered = registered
        for (key, value) in zip(keys, kept) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
        try? fm.removeItem(atPath: scratch)
    }
    for key in keys { defaults.removeObject(forKey: key) }
    guard let sheet = flameSheet() else { return check("fix deal: the built-in flame's sheet to copy", false) }
    for id in ["test-pet-a", "test-pet-b"] {
        try? fm.createDirectory(atPath: "\(scratch)/\(id)", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: sheet, toPath: "\(scratch)/\(id)/spritesheet.webp")
        try? #"{"id":"\#(id)"}"#.write(toFile: "\(scratch)/\(id)/pet.json", atomically: true, encoding: .utf8)
    }
    Pets.shared = Pets(dirs: [scratch], builtIn: [])
    Pets.shared.refresh(force: true)
    for outOfPanes in [false, true] {
        let store = Store()
        store.paneOf = { pid in outOfPanes ? nil : "tab-\(pid):leaf-1" }
        store.sessions = flameSessions(3)
        for _ in 0..<5 { store.assignPets() }  // past the rounds one out of a pane waits for its pane's pet
        let first = store.petBySession
        var same = true
        for _ in 0..<30 {
            store.assignPets()
            same = same && store.petBySession == first
        }
        let dealt = store.sessions.compactMap { first[$0.id] }
        check("fix deal: 3 sessions, 2 pets (\(outOfPanes ? "out of panes" : "in panes")): every one has a pet, both pets dealt",
            dealt.count == 3 && Set(dealt) == ["test-pet-a", "test-pet-b"])
        check("fix deal: ...and 30 more rounds change nobody's pet (\(outOfPanes ? "out of panes" : "in panes"))", same)
    }
    // A pet added to the pool: the one sharing is dealt it at the next round.
    try? fm.createDirectory(atPath: "\(scratch)/test-pet-c", withIntermediateDirectories: true)
    try? fm.copyItem(atPath: sheet, toPath: "\(scratch)/test-pet-c/spritesheet.webp")
    try? #"{"id":"test-pet-c"}"#.write(toFile: "\(scratch)/test-pet-c/pet.json", atomically: true, encoding: .utf8)
    let store = Store()
    store.paneOf = { pid in "tab-\(pid):leaf-1" }
    store.sessions = flameSessions(3)
    store.assignPets()
    Pets.shared.refresh(force: true)
    store.assignPets()
    check("fix deal: a third pet installed: the three sessions have three different pets",
        Set(store.sessions.compactMap { store.petBySession[$0.id] }).count == 3)
}

/// A sheet that will not decode: tried once, then not again until its wait is over; never a "ready"; not dealt meanwhile,
/// so that a pool of only that pet shows the flame.
@MainActor func fixBrokenPetTests() {
    let fm = FileManager.default
    let shared = Pets.shared, registered = Extensions.registered
    Extensions.registered = nil
    let scratch = NSTemporaryDirectory() + "fix-broken-\(getpid())"
    defer {
        Pets.shared = shared
        Extensions.registered = registered
        try? fm.removeItem(atPath: scratch)
    }
    guard let good = flameSheet() else { return check("fix broken pet: the built-in flame's sheet to copy", false) }
    func pet(_ pool: String, _ id: String, sheet: String?) {
        try? fm.createDirectory(atPath: "\(scratch)/\(pool)/\(id)", withIntermediateDirectories: true)
        if let sheet { try? fm.copyItem(atPath: sheet, toPath: "\(scratch)/\(pool)/\(id)/spritesheet.webp") }
        else { fm.createFile(atPath: "\(scratch)/\(pool)/\(id)/spritesheet.webp", contents: Data("not a picture".utf8)) }
        try? #"{"id":"\#(id)"}"#.write(toFile: "\(scratch)/\(pool)/\(id)/pet.json", atomically: true, encoding: .utf8)
    }
    pet("mixed", "test-pet-good", sheet: good)
    pet("mixed", "test-pet-bad", sheet: nil)
    pet("lone", "test-pet-bad", sheet: nil)

    var clock = Date()
    let mixed = Pets(dirs: [scratch + "/mixed"], builtIn: PetSources.builtIn)
    mixed.now = { clock }
    mixed.synchronous = true
    mixed.refresh(force: true)
    check("fix broken pet: the setup: both pets in the pool at first", mixed.ids == ["test-pet-bad", "test-pet-good"])
    let none = mixed.frame("test-pet-bad", row: 0, column: 0, head: false)
    let again = mixed.frame("test-pet-bad", row: 0, column: 1, head: true)
    check("fix broken pet: a sheet that will not decode gives no frame and is decoded once, not on every frame asked for",
        none == nil && again == nil && mixed.cuts == 1)
    mixed.refresh(force: true)
    check("fix broken pet: ...and while it waits it is not dealt; the good one still is", mixed.ids == ["test-pet-good"] && mixed.fallback == nil)
    clock += Pets.retryAfter(tries: 1) + 1
    _ = mixed.frame("test-pet-bad", row: 0, column: 0, head: false)
    _ = mixed.frame("test-pet-bad", row: 0, column: 0, head: false)
    check("fix broken pet: its wait over it is tried once more, then waits longer (1 min, 2 min, ... at most 1 h)",
        mixed.cuts == 2 && Pets.retryAfter(tries: 2) == 120 && Pets.retryAfter(tries: 30) == 3600)

    let lone = Pets(dirs: [scratch + "/lone"], builtIn: PetSources.builtIn)
    var ready = 0
    lone.onReady = { ready += 1 }
    lone.refresh(force: true)
    _ = lone.frame("test-pet-bad", row: 0, column: 0, head: false)  // in the background, as the panel does
    let deadline = Date() + 5
    while lone.cuts == 1 && !lone.broken("\(scratch)/lone/test-pet-bad/spritesheet.webp") && Date() < deadline {
        RunLoop.current.run(until: Date() + 0.02)
    }
    check("fix broken pet: a failed decode in the background is not told as ready", lone.broken("\(scratch)/lone/test-pet-bad/spritesheet.webp") && ready == 0)
    lone.refresh(force: true)
    check("fix broken pet: a pool whose only pet will not decode deals the flame", lone.ids.isEmpty && lone.fallback == PetSources.builtInID)
    // A new download under the same path is tried at once.
    let path = "\(scratch)/lone/test-pet-bad/spritesheet.webp"
    try? fm.removeItem(atPath: path)
    try? fm.copyItem(atPath: good, toPath: path)
    try? fm.setAttributes([.modificationDate: Date() + 5], ofItemAtPath: path)
    lone.refresh(force: true)
    check("fix broken pet: the sheet replaced, the pet is in the pool again at once", lone.ids == ["test-pet-bad"] && !lone.broken(path))
}

/// seaview room built with one set of workzones, then the file changes (a zone renamed, Home → Docs) at the same size: the labels
/// and the desks' lights follow the new codes, no label of the old zone left hanging.
@MainActor func fixZoneRebuildTests() {
    let restore = seaSweepSetup(NSTemporaryDirectory() + "fix-zones-\(getpid())")
    defer { restore() }
    guard ZoneArt.scene != nil else { return skipped("no art", "fix seaview room: the room built again when the workzones change") }
    let store = Store()
    store.readOnly = true
    store.sessions = []
    let view = ZoneView(frame: CGRect(x: 0, y: 0, width: 1194, height: 900))
    view.update(store)
    guard let before = ZoneArt.scene else { return check("fix seaview room: the setup: the room", false) }
    let docs = seaSweepZonesJSON.replacingOccurrences(of: #""Home": {"name""#, with: #""Docs": {"name""#) + "\n"
    try? docs.write(toFile: ZoneConfigFile.path, atomically: true, encoding: .utf8)
    view.update(store)
    guard let after = ZoneArt.scene else { return check("fix seaview room: the room after the change", false) }
    let signsNow = Set(after.signs.map(\.zone)).union([ZonePlan.visitorKey])
    let desksNow = Set(after.desks.map { "\($0.zone)_\($0.index)" })
    check("fix seaview room: the setup: the change moves the codes (Home before, Docs after)",
        before.signs.contains { $0.zone == "Home" } && after.signs.contains { $0.zone == "Docs" } && !after.signs.contains { $0.zone == "Home" })
    check("fix seaview room: a label for each zone now, none left of the old one", view.hungSigns == signsNow)
    check("fix seaview room: a light for each desk by its zone now", view.litDesks == desksNow)
}

/// Claude Code's file can be left saying "waiting" after the session went on (a peer's message held for the user's approval,
/// approved, then the turn ran with the file never written again). The transcript decides then: lines of the session's own
/// written more than 5 s after the file's status is not waiting; still being written (2 minutes) is busy, else idle. A real
/// wait (its last line, the tool call, older than the status) stays waiting.
@MainActor func fixStaleWaitingTests() {
    let bench = RestartBench("fix-stale-wait")
    defer { bench.done() }
    let now = Date()
    let fmt = ISO8601DateFormatter()
    fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func line(_ type: String, _ content: [[String: Any]], at: Date) -> String {
        let o: [String: Any] = ["type": type, "isSidechain": false, "timestamp": fmt.string(from: at), "message": ["role": type, "content": content]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    func ask(_ at: Date) -> String { line("assistant", [["type": "tool_use", "id": "toolu_1", "name": "Bash", "input": ["command": "ls", "description": "List files"]]], at: at) }
    func said(_ text: String, _ at: Date) -> String { line("assistant", [["type": "text", "text": text]], at: at) }
    func typed(_ text: String, _ at: Date) -> String { line("user", [["type": "text", "text": text]], at: at) }
    /// The registry says waiting since `status`; the transcript has `lines`, last written `written`.
    func put(_ id: String, status: Date, _ lines: [String], written: Date) {
        let path = bench.dir + "/\(id).jsonl"
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: path)
        bench.loader.remember(transcript: path, for: id)
        let ms = status.timeIntervalSince1970 * 1000
        let o: [String: Any] = ["pid": 1, "sessionId": id, "status": "waiting", "waitingFor": "permission prompt", "statusUpdatedAt": ms,
                                "startedAt": ms - 60_000, "cwd": "/tmp/" + id, "name": "name-" + id, "nameSource": "user"]
        try? JSONSerialization.data(withJSONObject: o).write(to: URL(fileURLWithPath: bench.registry + "/\(id).json"))
    }
    let held = now - 900  // the file last written 15 minutes ago
    put("stale-busy", status: held, [ask(held - 60), typed("go on", now - 120), said("working on it", now - 30)], written: now - 30)
    put("stale-quiet", status: now - 3600, [ask(now - 3660), typed("go on", now - 3000), said("done", now - 2990)], written: now - 2990)
    put("real-wait", status: now - 30, [said("I will list the files", now - 40), ask(now - 31)], written: now - 31)
    put("near-wait", status: now - 30, [ask(now - 31), said("a note", now - 27)], written: now - 27)
    let list = bench.loader.load(now: now)
    func find(_ id: String) -> Session? { list.first { $0.id == id } }
    check("fix stale waiting: the file says waiting, the transcript went on after it and is still being written: busy, waiting for nothing",
        find("stale-busy")?.status == "busy" && find("stale-busy")?.waitingFor == "")
    check("fix stale waiting: ...went on after it, then nothing for a long while: idle",
        find("stale-quiet")?.status == "idle" && find("stale-quiet")?.waitingFor == "")
    check("fix stale waiting: a real wait (the tool call older than the status) stays waiting, with its permission prompt and the call it waits on",
        find("real-wait")?.status == "waiting" && find("real-wait")?.waitingFor == "permission prompt" && find("real-wait")?.line.code == "wait.approve.run")
    check("fix stale waiting: a line within 5 s of the status does not count: still waiting", find("near-wait")?.status == "waiting")
    let rows = dumpRows(bench.loader, now: now)
    let row = rows.first { $0["id"] as? String == "stale-busy" }
    check("fix stale waiting: --dump gives the stale one as busy with an empty waitingFor",
        row?["status"] as? String == "busy" && row?["waitingFor"] as? String == "")
}

/// `--capture-live <path>`: a folder or a symlink as the target is refused and left as it is; the picture is written to
/// another file in the same folder and put in place only once it is there; no picture, the old file stays.
@MainActor func fixCaptureLiveTests() {
    let fm = FileManager.default
    let scratch = NSTemporaryDirectory() + "fix-capture-\(getpid())"
    try? fm.removeItem(atPath: scratch)
    try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: scratch) }
    func text(_ path: String) -> String? { fm.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) } }
    func put(_ path: String, _ words: String) { fm.createFile(atPath: path, contents: Data(words.utf8)) }

    let folder = scratch + "/folder"
    try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
    put(folder + "/keep.txt", "keep")
    let d = LiveCapture.prepare(folder)
    check("fix capture: a folder as the target is refused, with a message, and what is in it stays",
        d.writeTo == nil && !(d.refusal ?? "").isEmpty && text(folder + "/keep.txt") == "keep")

    let real = scratch + "/real.png", link = scratch + "/link.png"
    put(real, "old")
    try? fm.createSymbolicLink(atPath: link, withDestinationPath: real)
    let l = LiveCapture.prepare(link)
    check("fix capture: a symlink as the target is refused, and the link and the file it points to stay",
        l.writeTo == nil && !(l.refusal ?? "").isEmpty && text(real) == "old" && (try? fm.destinationOfSymbolicLink(atPath: link)) == real)

    let shot = scratch + "/shot.png"
    put(shot, "old")
    let p = LiveCapture.prepare(shot)
    let writeTo = p.writeTo ?? shot
    check("fix capture: a regular file is taken; the picture goes to another file in the same folder, the old one kept meanwhile",
        p.refusal == nil && p.writeTo != nil && writeTo != shot
            && (writeTo as NSString).deletingLastPathComponent == scratch && text(shot) == "old")
    check("fix capture: no picture written: no success, and the old file is as it was", !LiveCapture.finish(writeTo: writeTo, target: shot) && text(shot) == "old")
    let q = LiveCapture.prepare(shot)
    if let w = q.writeTo { put(w, "new") }
    let done = LiveCapture.finish(writeTo: q.writeTo ?? shot, target: shot)
    let left = ((try? fm.contentsOfDirectory(atPath: scratch)) ?? []).sorted()
    check("fix capture: the picture written: it replaces the old file, and no other file is left beside it",
        done && text(shot) == "new" && left == ["folder", "link.png", "real.png", "shot.png"])
    let fresh = scratch + "/fresh.png"
    let f = LiveCapture.prepare(fresh)
    if let w = f.writeTo { put(w, "new") }
    check("fix capture: a path with no file yet gets the picture", f.refusal == nil && LiveCapture.finish(writeTo: f.writeTo ?? fresh, target: fresh) && text(fresh) == "new")
}

/// A transcript's lines read within bounds: an unfinished line is not read again while the file has not grown, a line
/// longer than `BGScan.lineBytes` is passed over up to its newline (its task not counted), and one look reads at most
/// `BGScan.roundBytes`, the rest at the next.
@MainActor func fixLongLineTests() {
    let fm = FileManager.default
    let scratch = NSTemporaryDirectory() + "fix-long-line-\(getpid())"
    try? fm.removeItem(atPath: scratch)
    try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    let caps = (BGScan.roundBytes, BGScan.lineBytes)
    BGScan.roundBytes = 1 << 20
    BGScan.lineBytes = 4096
    defer {
        (BGScan.roundBytes, BGScan.lineBytes) = caps
        try? fm.removeItem(atPath: scratch)
    }
    func started(_ id: String, pad: Int = 0) -> String {
        let o: [String: Any] = ["type": "user", "isSidechain": false, "timestamp": codexStamps.string(from: Date() - 60),
            "toolUseResult": ["stdout": String(repeating: "x", count: pad), "stderr": "", "interrupted": false, "backgroundTaskId": id],
            "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "toolu_1", "content": "x"]]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self)
    }
    func size(_ path: String) -> UInt64 { ((try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.uint64Value ?? 0 }
    func append(_ path: String, _ words: String) {
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        h.seekToEndOfFile(); h.write(Data(words.utf8)); try? h.close()
    }

    // A short unfinished line: read once, not again while nothing is added.
    let short = scratch + "/short.jsonl"
    let half = started("s2")
    try? (started("s1") + "\n" + String(half.prefix(half.count / 2))).write(toFile: short, atomically: true, encoding: .utf8)
    var s = BGScan()
    s.advance(path: short)
    var bytes0 = bgBytesRead
    s.advance(path: short)
    check("fix bg scan: a short unfinished line is not read again while the file has not grown", bgBytesRead == bytes0 && s.state.tasks == 1)
    append(short, String(half.dropFirst(half.count / 2)) + "\n")
    s.advance(path: short)
    check("fix bg scan: ...once finished it is taken (2 tasks, read to the end)", s.state.tasks == 2 && s.offset == size(short))

    // A long unfinished line: passed over, not read again; once its newline comes, the lines after it are taken, it is not.
    let long = scratch + "/long.jsonl"
    let big = started("l3", pad: 10_000)
    try? (started("l1") + "\n" + String(big.prefix(6000))).write(toFile: long, atomically: true, encoding: .utf8)
    var g = BGScan()
    g.advance(path: long)
    bytes0 = bgBytesRead
    g.advance(path: long)
    check("fix bg scan: an unfinished line past the line cap is passed over (read to the end) and not read again",
        g.offset == size(long) && bgBytesRead == bytes0 && g.state.tasks == 1)
    append(long, String(big.dropFirst(6000)) + "\n" + started("l2") + "\n")
    g.advance(path: long)
    check("fix bg scan: ...when it ends, the line after it is taken and the long one is not (l1 and l2, no l3)",
        g.offset == size(long) && Set(g.state.list.map(\.id)) == ["l1", "l2"])
    var reread = BGScan.decode(BGScan.encode(["s": g]))["s"] ?? BGScan()
    reread.advance(path: long)
    check("fix bg scan: ...and the same through the cache file", Set(reread.state.list.map(\.id)) == ["l1", "l2"])

    // A whole long line read in one look: passed over as well.
    let whole = scratch + "/whole.jsonl"
    try? [started("w1"), started("w3", pad: 10_000), started("w2")].map { $0 + "\n" }.joined().write(toFile: whole, atomically: true, encoding: .utf8)
    var w = BGScan()
    w.advance(path: whole)
    check("fix bg scan: a whole line past the line cap is passed over; the lines around it are taken",
        w.offset == size(whole) && Set(w.state.list.map(\.id)) == ["w1", "w2"])

    // The round cap: a file larger than it takes more than one look, and every line is taken in the end.
    BGScan.roundBytes = 2048
    let many = scratch + "/many.jsonl"
    try? (0..<20).map { started("m\($0)") + "\n" }.joined().write(toFile: many, atomically: true, encoding: .utf8)
    var m = BGScan()
    m.advance(path: many)
    let first = m.offset
    for _ in 0..<40 where m.offset < size(many) { m.advance(path: many) }
    check("fix bg scan: one look reads at most the round cap; later looks read the rest, every task taken",
        first > 0 && first <= 2048 && m.offset == size(many) && m.state.tasks == 20)
}

/// A pet sheet that decodes but is too small for its cells (narrower than 8 pixels, shorter than one row) or larger than
/// the pixel cap is refused like one that will not decode: nothing cut, the pet waits and is not dealt.
@MainActor func fixSmallSheetTests() {
    let fm = FileManager.default
    let shared = Pets.shared, registered = Extensions.registered
    Extensions.registered = nil
    let scratch = NSTemporaryDirectory() + "fix-small-sheet-\(getpid())"
    try? fm.removeItem(atPath: scratch)
    defer {
        Pets.shared = shared
        Extensions.registered = registered
        try? fm.removeItem(atPath: scratch)
    }
    /// A pet `id` in `pool` whose sheet is a `w` x `h` PNG; the sheet's path.
    func pet(_ pool: String, _ id: String, _ w: Int, _ h: Int) -> String {
        let dir = "\(scratch)/\(pool)/\(id)", path = dir + "/spritesheet.webp"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: w, height: h))
            if let image = c.makeImage(), let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(file, image, nil)
                CGImageDestinationFinalize(file)
            }
        }
        try? #"{"id":"\#(id)"}"#.write(toFile: dir + "/pet.json", atomically: true, encoding: .utf8)
        return path
    }
    let flat = pet("flat", "test-pet-flat", 16, 1)
    check("fix small sheet: a sheet shorter than one row of its cells (16 x 1) is refused, nothing cut",
        !Pets.cut(flat, into: scratch + "/out-flat") && !fm.fileExists(atPath: scratch + "/out-flat/done"))
    let pool = Pets(dirs: [scratch + "/flat"], builtIn: PetSources.builtIn)
    pool.synchronous = true
    pool.refresh(force: true)
    let a = pool.frame("test-pet-flat", row: 0, column: 0, head: false)
    let b = pool.frame("test-pet-flat", row: 0, column: 1, head: true)
    pool.refresh(force: true)
    check("fix small sheet: ...in the pool it gives no frame, is tried once, waits, and the built-in pet is dealt instead",
        a == nil && b == nil && pool.cuts == 1 && pool.broken(flat) && pool.ids.isEmpty && pool.fallback == PetSources.builtInID)
    let huge = pet("huge", "test-pet-huge", 20_000, 8)
    check("fix small sheet: a sheet past the pixel cap (20000 x 8) is refused before it is decoded", !Pets.cut(huge, into: scratch + "/out-huge"))
    let narrow = pet("narrow", "test-pet-narrow", 1, 1)
    check("fix small sheet: a sheet narrower than 8 pixels (1 x 1) is refused, nothing cut",
        !Pets.cut(narrow, into: scratch + "/out-narrow") && !fm.fileExists(atPath: scratch + "/out-narrow/done"))
}
