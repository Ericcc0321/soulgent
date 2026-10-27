// The built-in flame (soulflame), dealt only when no pet is installed (`--flame-only`), and its stills (`--flame-stills <dir>`).
// Nothing here ships in the app.
import AppKit
import SwiftUI

/// The flame's source folder (app/brand/soulgent/pet/soulflame), found the way the checks' binary finds it.
@MainActor func flameSheet() -> String? {
    PetSources.builtIn.first.flatMap { PetSources.sheet(in: $0, PetSources.builtInID)?.path }
}

/// The drawn part of a picture (alpha at least 16), in its pixels from the top left, and how many pixels are drawn.
func flameDrawn(_ image: CGImage) -> (box: CGRect, count: Int)? {
    let alpha = Pets.alpha(of: image)
    var left = Int.max, top = Int.max, right = -1, bottom = -1, count = 0
    for y in 0..<image.height {
        for x in 0..<image.width where alpha[y * image.width + x] >= 16 {
            left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y); count += 1
        }
    }
    return right < 0 ? nil : (CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1), count)
}

/// Sessions for the deal checks: some in panes, one without, named and not.
@MainActor func flameSessions(_ n: Int) -> [Session] {
    (0..<n).map { i in
        var s = Session(id: "flame-\(i)", pid: Int32(800 + i), project: "demo", name: "Demo-\(i)", status: ["idle", "busy", "waiting"][i % 3],
                        since: Date() - 600, summary: "")
        if i % 2 == 0 { s.registryName = "Demo-\(i)" }
        return s
    }
}

@MainActor func flameTests() {
    let defaults = UserDefaults.standard
    let keys = ["petBySession", "petByPane", "petByPaneOrder", "favoritePets", "petByName", "petByNameOrder", "bannedPets"]
    let kept = keys.map { defaults.object(forKey: $0) }
    let shared = Pets.shared
    let registered = Extensions.registered
    Extensions.registered = nil  // the shared pool as it is with no extension's cast
    defer {
        Pets.shared = shared
        Extensions.registered = registered
        for (key, value) in zip(keys, kept) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } }
    }
    func forget() { for key in keys { defaults.removeObject(forKey: key) } }
    // Not read-only, so that whatever is dealt is written down as the panel would. Without `someOutOfPanes` every session is
    // in a pane (one out of a pane waits a few rounds for its pane's pet before a draw).
    func store(_ sessions: [Session], someOutOfPanes: Bool = false) -> Store {
        let store = Store()
        store.paneOf = { pid in someOutOfPanes && pid % 3 == 0 ? nil : "tab-\(pid):leaf-1" }
        store.sessions = sessions
        return store
    }
    let flame = PetSources.builtInID
    let fm = FileManager.default
    let scratch = NSTemporaryDirectory() + "flame-checks-\(getpid())"
    try? fm.removeItem(atPath: scratch)
    try? fm.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    defer { try? fm.removeItem(atPath: scratch) }
    guard let sheet = flameSheet() else {
        check("flame: the built-in flame's source is at app/brand/soulgent/pet/soulflame (pet.json and its sheet)", false)
        return
    }

    // ── SOULGENT_PET_DIRS: set and empty is no outside pool; a list is that list; unset is the two usual pools.
    let env = ProcessInfo.processInfo.environment["SOULGENT_PET_DIRS"]
    setenv("SOULGENT_PET_DIRS", "", 1)
    let none = PetSources.outside
    setenv("SOULGENT_PET_DIRS", "/a/pets:/b/pets", 1)
    let two = PetSources.outside
    unsetenv("SOULGENT_PET_DIRS")
    let usual = PetSources.outside
    if let env { setenv("SOULGENT_PET_DIRS", env, 1) }
    check("flame: SOULGENT_PET_DIRS set but empty means no outside pool; a colon list is that list; unset, petdex's and the app's own",
        none.isEmpty && two == ["/a/pets", "/b/pets"] && usual.count == 2 && usual[0].hasSuffix("/.petdex/pets") && usual[1].hasSuffix("/pets"))
    check("flame: OfficePets looks for the flame after every other pool", {
        let probe = OfficePets(folder: scratch + "/true-frames", pools: [])
        return Mirror(reflecting: probe).children.first { $0.label == "pools" }.flatMap { $0.value as? [String] } == PetSources.builtIn
    }())

    // ── 1. An empty pool: every session is dealt the flame, the same one for all; nothing written down for it.
    forget()
    let empty = Pets(dirs: [scratch + "/no-pets"])
    Pets.shared = empty
    empty.refresh(force: true)
    check("flame: no pet installed: the pool is empty and the flame stands in", empty.ids.isEmpty && empty.fallback == flame)
    let lonely = store(flameSessions(7), someOutOfPanes: true)
    lonely.assignPets()
    lonely.assignPets()
    check("flame: no pet installed: every session (in a pane or not, named or not) is dealt the flame, 7 of 7",
        lonely.sessions.allSatisfy { lonely.petBySession[$0.id] == flame && lonely.displayPets[$0.id] == flame })
    check("flame: the flame is not written down (by session, pane or name): the phone's list and the pets kept for later stay as they were",
        defaults.dictionary(forKey: "petBySession") == nil && defaults.dictionary(forKey: "petByPane") == nil
            && defaults.dictionary(forKey: "petByName") == nil && lonely.petByPane.isEmpty && lonely.petByName.isEmpty)
    check("flame: with the flame only, change pet has nothing to change to and the flame cannot be banned",
        lonely.freePets(for: lonely.sessions[0]).isEmpty && lonely.changePet(lonely.sessions[0]) == nil && lonely.banPet(lonely.sessions[0]) == nil
            && lonely.petBySession[lonely.sessions[0].id] == flame)

    // ── 2. A pool with pets: the flame is never dealt, nor offered.
    let pool = scratch + "/pool"
    for id in ["flame-alpha", "flame-beta", "flame-gamma"] {
        try? fm.createDirectory(atPath: "\(pool)/\(id)", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: sheet, toPath: "\(pool)/\(id)/spritesheet.webp")
        try? #"{"id":"\#(id)","spritesheetPath":"spritesheet.webp"}"#.write(toFile: "\(pool)/\(id)/pet.json", atomically: true, encoding: .utf8)
    }
    let three = Pets(dirs: [scratch + "/no-pets", pool])
    Pets.shared = three
    three.refresh(force: true)
    check("flame: with pets installed the pool is just those, no flame and no stand-in", three.ids == ["flame-alpha", "flame-beta", "flame-gamma"] && three.fallback == nil)
    var dealt = Set<String>()
    for round in 0..<20 {
        forget()
        let crowd = store(flameSessions(round % 2 == 0 ? 2 : 8))  // fewer sessions than pets, and more (pets repeat)
        crowd.assignPets()
        dealt.formUnion(crowd.sessions.compactMap { crowd.petBySession[$0.id] })
        for s in crowd.sessions { dealt.formUnion(crowd.freePets(for: s)) }
        if round == 0, let first = crowd.sessions.first { _ = crowd.changePet(first).map { dealt.insert($0) } }
    }
    check("flame: with 3 pets installed, 20 deals of 2 and of 8 sessions, the free lists and change pet never give the flame (\(dealt.sorted()))",
        !dealt.contains(flame) && dealt == Set(three.ids))
    forget()
    let banned = store(flameSessions(4))
    banned.bannedPets = three.ids
    banned.assignPets()
    check("flame: every installed pet banned: still dealt from the pool (as before), not the flame",
        banned.sessions.allSatisfy { banned.petBySession[$0.id].map(three.ids.contains) ?? false })
    // From none to some: those holding the flame are dealt an installed pet at the next round.
    forget()
    Pets.shared = empty
    let later = store(flameSessions(5))
    later.assignPets()
    let before = later.sessions.allSatisfy { later.petBySession[$0.id] == flame }
    Pets.shared = three
    later.assignPets()
    check("flame: once a pet is installed, the sessions that had the flame are dealt installed pets at the next round",
        before && later.sessions.allSatisfy { later.petBySession[$0.id].map(three.ids.contains) ?? false })
    // The real pools, when any pets are installed: no flame either.
    let real = Pets()
    real.refresh(force: true)
    if real.ids.isEmpty {
        skipped("no pet installed", "flame: the real pools deal no flame")
    } else {
        forget()
        Pets.shared = real
        let mine = store(flameSessions(12))
        mine.assignPets()
        check("flame: the real pools (\(real.ids.count) pets): 12 sessions, none dealt the flame, no stand-in",
            real.fallback == nil && !real.ids.contains(flame) && mine.sessions.allSatisfy { mine.petBySession[$0.id].map { $0 != flame } ?? false })
    }
    Pets.shared = shared

    // ── 3. avatar whole: the whole flame, fitted and centred; other pets' avatars as before.
    let wholeDir = scratch + "/whole", headDir = scratch + "/head"
    Pets.cut(sheet, into: wholeDir, wholeAvatar: true)
    Pets.cut(sheet, into: headDir, wholeAvatar: false)
    func png(_ path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    guard let file = NSImage(contentsOfFile: sheet)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        check("flame: the flame's sheet decodes", false)
        return
    }
    let fw = file.width / 8, fh = fw * 208 / 192
    var wholeOK: [String] = [], centred: [String] = []
    for (row, column) in [(0, 0), (0, 1), (6, 0), (6, 2), (6, 3), (7, 0), (7, 1), (7, 2), (3, 1), (3, 2), (4, 2)] {
        guard let cell = file.cropping(to: CGRect(x: column * fw, y: row * fh, width: fw, height: fh)), let source = flameDrawn(cell),
            let avatar = png("\(wholeDir)/\(row)-\(column)h.png"), let shown = flameDrawn(avatar)
        else {
            wholeOK.append("\(row)-\(column): missing")
            continue
        }
        // The whole flame: off every edge, inside the circle the board clips to, its shape's proportions kept and as many
        // pixels as the frame's scaled down (within 12 %).
        let side = CGFloat(avatar.width), alpha = Pets.alpha(of: avatar)
        var outside = 0
        for y in 0..<avatar.height {
            for x in 0..<avatar.width where alpha[y * avatar.width + x] >= 16 {
                let dx = CGFloat(x) + 0.5 - side / 2, dy = CGFloat(y) + 0.5 - side / 2
                if (dx * dx + dy * dy).squareRoot() > side / 2 { outside += 1 }
            }
        }
        let k = shown.box.height / source.box.height
        let ratio = (shown.box.width / shown.box.height) / (source.box.width / source.box.height)
        let expected = Double(source.count) * Double(k * k)
        let ok = avatar.width == 96 && avatar.height == 96 && shown.box.minX >= 1 && shown.box.minY >= 1 && shown.box.maxX <= side - 1
            && shown.box.maxY <= side - 1 && outside == 0 && abs(ratio - 1) < 0.06 && abs(Double(shown.count) / expected - 1) < 0.12
            && shown.box.height > side * 0.6
        if !ok { wholeOK.append("\(row)-\(column): box \(shown.box) outside \(outside) ratio \(ratio) count \(shown.count)/\(Int(expected))") }
        // Centred: stand and sleep (seen, rest) sit on the middle, within 3 % of the side. (Every row is centred as a whole
        // below: its frames share one fit, so the flame still sways and bobs inside the avatar as it does in the row.)
        if [(0, 0), (0, 1)].contains(where: { $0 == (row, column) })
            && (abs(shown.box.midX - side / 2) > side * 0.03 || abs(shown.box.midY - side / 2) > side * 0.03)
        {
            centred.append("\(row)-\(column): centre \(shown.box.midX),\(shown.box.midY)")
        }
    }
    check("flame: avatar whole: each avatar has the whole flame, fitted (off the edges, inside the round avatar, its shape kept) \(wholeOK)",
        wholeOK.isEmpty)
    for row in [0, 3, 4, 6, 7] {
        let boxes = (0..<8).compactMap { png("\(wholeDir)/\(row)-\($0)h.png").flatMap(flameDrawn)?.box }
        let all = boxes.reduce(CGRect.null) { $0.union($1) }
        if boxes.isEmpty || abs(all.midX - 48) > 1.5 || abs(all.midY - 48) > 1.5 { centred.append("row \(row): \(all)") }
    }
    check("flame: avatar whole: the flame is centred in the avatar (stand and sleep each; every row's frames together) \(centred)", centred.isEmpty)
    let oldHead = png("\(headDir)/0-0h.png").flatMap(flameDrawn)
    check("flame: without the field the avatar is the top of the frame as before (the flame's face would be cut off at the bottom)",
        oldHead.map { $0.box.maxY >= 95 } ?? false)
    let fields = PetSources.builtIn.first.flatMap { PetSources.sheet(in: $0, flame) }
    let plain = PetSources.sheet(in: pool, "flame-alpha")
    check("flame: pet.json \"avatar\": \"whole\" is read for the flame; a pet without it keeps the usual avatar", fields?.whole == true && plain?.whole == false)
    // Through the board's own path: the flame's avatar from Pets.frame, cut into a folder of its own (`-whole`), so a pet.json
    // gaining the field has its avatars cut afresh.
    let viaBoard = Pets(dirs: [])
    viaBoard.synchronous = true
    viaBoard.refresh(force: true)
    let head = viaBoard.frame(flame, row: 6, column: 0, head: true)
    let stamp = ((try? fm.attributesOfItem(atPath: sheet))?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let cacheDir = cacheFolder + "/frames/\(flame)-\(Int(stamp))-whole"
    check("flame: the board's avatar for the flame is the whole-pet one, from a cache folder of its own (…-whole)",
        head.flatMap(flameDrawn).map { $0.box.minY >= 1 && $0.box.maxY <= 95 } == true && fm.fileExists(atPath: cacheDir + "/done")
            && (try? fm.contentsOfDirectory(atPath: cacheDir))?.contains("6-0h.png") == true)

    // ── 4. The app has the flame: build.sh copies it into Contents/Resources/pets/soulflame; the source is there.
    let build = (try? String(contentsOfFile: "build.sh", encoding: .utf8)) ?? ""
    let sourceDir = URL(fileURLWithPath: sheet).deletingLastPathComponent().path
    let json = fm.contents(atPath: sourceDir + "/pet.json").flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    check("flame: build.sh copies the flame (pet.json and its sheet) into the app's Resources/pets/soulflame",
        build.contains(#"mkdir -p "$APP/Contents/Resources/pets/soulflame""#)
            && build.contains(#"cp brand/soulgent/pet/soulflame/pet.json brand/soulgent/pet/soulflame/spritesheet.webp "$APP/Contents/Resources/pets/soulflame/""#))
    check("flame: the flame's source: pet.json (id soulflame, its sheet, avatar whole) and a 1536 × 1872 sheet",
        sourceDir.hasSuffix("brand/soulgent/pet/soulflame") && json?["id"] as? String == flame
            && json?["spritesheetPath"] as? String == "spritesheet.webp" && json?["avatar"] as? String == "whole"
            && file.width == 1536 && file.height == 1872)
    // An app built from here (SOULGENT_FLAME_APP names one): the flame in it, the same bytes, and found there as the built-in.
    if let app = ProcessInfo.processInfo.environment["SOULGENT_FLAME_APP"] {
        let inApp = app + "/Contents/Resources/pets/soulflame"
        check("flame: the built app (\(app)) has Resources/pets/soulflame, the same files as the source",
            fm.contentsEqual(atPath: inApp + "/spritesheet.webp", andPath: sheet) && fm.contentsEqual(atPath: inApp + "/pet.json", andPath: sourceDir + "/pet.json"))
    }

    // ── 5. The sheet's rows: as many frames as the format says, from the first column on, none after.
    // Row 0: stand (0) and sleep (1) are what the panel uses; Petdex's idle row has 6 (the flame's has 6, frames 2–5 unused).
    // Rows 1/2 run right/left (8), 3 waves (4), 4 jumps for joy (5), 6 waits for you (6), 7 works (6); rows 5 and 8 unused.
    var rows: [Int: [Bool]] = [:]
    for row in 0..<9 {
        rows[row] = (0..<8).map { column in
            file.cropping(to: CGRect(x: column * fw, y: row * fh, width: fw, height: fh)).flatMap(flameDrawn) != nil
        }
    }
    func frames(_ row: Int) -> Int? {  // the run of drawn frames from column 0, nil if one is drawn after a gap
        guard let drawn = rows[row] else { return nil }
        let n = drawn.prefix { $0 }.count
        return drawn[n...].contains(true) ? nil : n
    }
    let want: [Int: Int] = [1: 8, 2: 8, 3: 4, 4: 5, 6: 6, 7: 6]
    let got = (0..<9).map { "\($0):\(frames($0).map(String.init) ?? "gap")" }
    check("flame: the flame's rows have the format's frames: 1/2 run 8, 3 waves 4, 4 jumps 5, 6 waits 6, 7 works 6, 0 at least stand and sleep (\(got))",
        want.allSatisfy { frames($0.key) == $0.value } && (frames(0) ?? 0) >= 2)
    // NUDGE: waiting for you is the first frame of row 6, not its loop; with `waitingNudge` off it is the row's six frames again.
    let nudgeWas = WaitingNudge.override
    WaitingNudge.override = false
    let legacyWaiting = Pose.waiting.sheet
    WaitingNudge.override = true
    let stillWaiting = Pose.waiting.sheet
    WaitingNudge.override = nudgeWas
    check("flame: the board's poses take those rows and counts (working 7×6, waiting 6×6 — row 6's first frame alone, 6×6 with the switch off —, celebrate 4×5, wave 3×4, raise-hand 3, stand 0-0, sleep 0-1)",
        Pose.working.sheet.row == 7 && Pose.working.sheet.frames == frames(7) && legacyWaiting.row == 6 && legacyWaiting.frames == frames(6)
            && stillWaiting.row == 6 && stillWaiting.frames == 1 && stillWaiting.still == 0
            && Pose.celebrating.sheet.row == 4 && Pose.celebrating.sheet.frames == frames(4) && Pose.waving.sheet.row == 3
            && Pose.waving.sheet.frames == frames(3) && Pose.handUp.sheet.row == 3 && Pose.standing.sheet == (0, 1, 0, 0)
            && Pose.sleeping.sheet == (0, 1, 0, 1) && OfficePets.rows == [0, 1, 2, 3, 4, 6, 7])
    let standing = file.cropping(to: CGRect(x: 0, y: 0, width: fw, height: fh)).map(Pets.alpha(of:))
    let sleeping = file.cropping(to: CGRect(x: fw, y: 0, width: fw, height: fh)).map(Pets.alpha(of:))
    check("flame: stand (0-0) and sleep (0-1) are different frames", standing != nil && standing != sleeping)
    check("flame: the flame runs the usual way (row 1 right, row 2 left: row 2 is row 1 mirrored), so pet-facing.json has no entry for it",
        OfficePets.facingTable[flame] == nil && {
            guard let r1 = file.cropping(to: CGRect(x: 0, y: fh, width: fw, height: fh)).flatMap(flameDrawn),
                let r2 = file.cropping(to: CGRect(x: 0, y: 2 * fh, width: fw, height: fh)).flatMap(flameDrawn)
            else { return false }
            return abs((CGFloat(fw) - r1.box.maxX) - r2.box.minX) <= 1 && r1.box.midX > CGFloat(fw) / 2 && r2.box.midX < CGFloat(fw) / 2
        }())
    // The office and the sea room cut every row they use from it, the true-size frames of the flame.
    let office = OfficePets(folder: scratch + "/true-frames", pools: [])
    office.synchronous = true
    let cut = OfficePets.rows.map { row in (0..<8).filter { office.frame(flame, row: row, column: $0) != nil }.count }
    check("flame: the office (and the sea room) cut the flame's rows with the same frames (\(cut))",
        cut == OfficePets.rows.map { frames($0) ?? -1 })

    flameScaleTests()
}

/// `--flame-stills <dir>`: the board's round avatars of the pets dealt here, large (waiting, working, seen), one board and the pets
/// dealt (`dealt.txt`). Run once with `SOULGENT_PET_DIRS=` (no pet: the flame) and once without (the pets installed).
@MainActor func flameStills(_ dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    Pets.shared.synchronous = true
    OfficePets.shared.synchronous = true
    Pets.shared.refresh(force: true)
    let defaults = UserDefaults.standard
    let keys = ["petBySession", "petByPane", "petByPaneOrder", "favoritePets", "petByName", "petByNameOrder", "bannedPets"]
    let kept = keys.map { defaults.object(forKey: $0) }
    defer { for (key, value) in zip(keys, kept) { if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
    let all = boardSweepStore(boardSweepAllStates())
    boardSweepBoard(all, width: 640, zoom: 1, dir + "/board-640.png")
    var lines = "pool: \(Pets.shared.ids.count) pets; stand-in: \(Pets.shared.fallback ?? "none")\n"
    for s in all.sessions { lines += "\(s.id)\t\(all.displayPets[s.id] ?? "—")\n" }
    try? lines.write(toFile: dir + "/dealt.txt", atomically: true, encoding: .utf8)
    // The avatars as the cards draw them (the floor-coloured disc, the pet clipped round), at 4×: waiting, working, seen.
    let pet = all.displayPets["w-perm"]
    let avatars = HStack(spacing: 24) {
        ForEach([("waiting", Pose.waiting), ("working", Pose.working), ("seen", Pose.standing)], id: \.0) { title, pose in
            VStack(spacing: 8) {
                ZStack {
                    Circle().fill(floorLine)
                    PetSprite(pet: pet, pose: pose, size: 152, head: true).clipShape(Circle())
                }
                .frame(width: 152, height: 152)
                Text(title).font(.system(size: 18)).foregroundStyle(.white)
            }
        }
    }
    .padding(24).background(night).environment(\.still, true).environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: avatars)
    renderer.scale = 2
    save(renderer.cgImage, dir + "/avatars-x4.png")
    print("flame stills in \(dir) (pet: \(pet ?? "none"))")
}

// ───────── A pet's own size (pet.json "scale") ─────────

/// A pet's own size (run at the end of `flameTests`): pet.json's optional `"scale"` multiplies the size the office and the sea room give a pet by
/// its height, and nothing else changes: the flame with it is that share of the flame without it, wherever it stands, its
/// chat mark and bubbles go by its head at that size, its plate stays under its feet, and every other pet is as it was.
@MainActor func flameScaleTests() {
    let fm = FileManager.default
    let flame = PetSources.builtInID
    guard let sheet = flameSheet(), let home = PetSources.builtIn.first else {
        check("pet scale: the flame's source is there", false)
        return
    }
    // ── 1. Reading the field.
    func parsed(_ text: String) -> CGFloat {
        PetSources.scale(of: (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any])
    }
    check("pet scale: pet.json scale: a number above 0 (up to 4) is taken; none, 0, below 0, text, true or above 4 give 1",
        parsed(#"{"scale": 0.6}"#) == CGFloat(0.6) && parsed(#"{"scale": 2}"#) == 2 && parsed("{}") == 1 && parsed(#"{"scale": 0}"#) == 1
            && parsed(#"{"scale": -0.5}"#) == 1 && parsed(#"{"scale": "0.6"}"#) == 1 && parsed(#"{"scale": true}"#) == 1
            && parsed(#"{"scale": 9}"#) == 1)
    let shipped = PetSources.scale(in: home, flame)
    check("pet scale: the flame's pet.json has a scale below 1 (\(shipped)), and the office reads the same", shipped < 1 && OfficePets(folder: NSTemporaryDirectory() + "flame2-none", pools: []).size(flame) == shipped)

    // Two pools with the flame: its sheet with and without the field.
    let scratch = NSTemporaryDirectory() + "flame2-checks-\(getpid())"
    try? fm.removeItem(atPath: scratch)
    defer { try? fm.removeItem(atPath: scratch) }
    let share: CGFloat = 0.6
    for (pool, field) in [("plain", ""), ("scaled", ", \"scale\": \(share)")] {
        let dir = "\(scratch)/\(pool)/\(flame)"
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: sheet, toPath: dir + "/spritesheet.webp")
        try? #"{"id": "soulflame", "spritesheetPath": "spritesheet.webp", "avatar": "whole"\#(field)}"#.write(toFile: dir + "/pet.json", atomically: true, encoding: .utf8)
    }
    let officeShared = OfficePets.shared, petsShared = Pets.shared
    defer {
        OfficePets.shared = officeShared
        Pets.shared = petsShared
    }
    func office(_ pool: String) -> OfficePets {
        let pets = OfficePets(folder: "\(scratch)/frames-\(pool)", pools: ["\(scratch)/\(pool)"])
        pets.synchronous = true
        return pets
    }
    let plain = office("plain"), scaled = office("scaled")
    check("pet scale: the two pools read as they should (1 and \(share))", plain.size(flame) == 1 && scaled.size(flame) == share)

    // No pet installed: every session has the flame.
    Pets.shared = Pets(dirs: [], builtIn: PetSources.builtIn)
    Pets.shared.refresh(force: true)
    let now = Date()

    // ── 2. The office: each place's figure is `share` of the one without the field; plates under the feet as before.
    let store = officeStore()
    store.sessions += [officeSession("o-busy2", "busy", finished: 70), officeSession("o-news2", "idle", finished: 40)]
    store.assignPets()
    check("pet scale office: with no pet installed every session has the flame", store.sessions.allSatisfy { store.displayPets[$0.id] == flame })
    func measure(_ pets: OfficePets) -> (layout: OfficeLayout, figures: [String: OfficeFigure], words: [String: CGRect]) {
        OfficePets.shared = pets
        let layout = OfficePainter.layout(store, now: now)
        var figures: [String: OfficeFigure] = [:], words: [String: CGRect] = [:]
        for place in layout.pets {
            guard let s = store.sessions.first(where: { $0.id == place.id }) else { continue }
            figures[place.id] = OfficePainter.figure(store, s, place, now: now)
            words[place.id] = OfficePainter.words(store, s, place, layout, now: now, scale: 1)?.rect
        }
        return (layout, figures, words)
    }
    let without = measure(plain), with = measure(scaled)
    var ratios: [String] = [], zones = Set<String>()
    var sized = !without.figures.isEmpty && without.figures.count == with.figures.count
    for (id, a) in without.figures {
        guard let b = with.figures[id], a.pet == flame, b.pet == flame else { sized = false; continue }
        let r = b.high / a.high
        ratios.append(String(format: "%@ %.3f", id, r))
        if abs(r - share) > 0.001 || abs(b.scale / a.scale - share) > 0.001 || abs(b.wide / a.wide - share) > 0.001 { sized = false }
        // The sprite as drawn (prescaled to whole pixels): the same share, give or take a pixel; its feet where they were.
        if abs(b.sprite.rect.height / a.sprite.rect.height - share) > 0.03 { sized = false }
        if let place = with.layout.pets.first(where: { $0.id == id }) {
            zones.insert("\(place.zone)")
            if let sa = a.shadow?.rect, let sb = b.shadow?.rect, abs(sa.midX - sb.midX) > 0.6 || abs(sa.midY - sb.midY) > 0.6 { sized = false }
        }
    }
    check("pet scale office: in every part of the room (\(zones.sorted())) the flame with scale \(share) is \(share) of its size without it: height, width, its sprite (\(ratios.sorted()))",
        sized && zones.count >= 3)
    check("pet scale office: the places and the plates under the feet are the same with and without the field",
        without.layout.pets.map(\.id) == with.layout.pets.map(\.id) && without.layout.pets.map(\.foot) == with.layout.pets.map(\.foot)
            && without.words == with.words)
    // The chat mark goes by its head at that size; the hover lines' head too (`Pet.head`).
    OfficePets.shared = scaled
    let talking = Set(store.sessions.map(\.id))
    let markPlain = with.layout.visited(by: OfficeVisits(), talking: talking)
    let markScaled = with.layout.visited(by: OfficeVisits(), talking: talking, sizes: scaled.sizes(store))
    var marks: [String] = []
    var markOK = scaled.sizes(store).count == store.sessions.count && scaled.sizes(store).values.allSatisfy { $0 == share }
    // Near the head as drawn (its pose's height at its size): the mark's middle within 20 points of the head's top, with
    // the field as without it; the marks laid out without the sizes would float over the smaller flame.
    var floating = 0
    for (a, b) in zip(markPlain.pets, markScaled.pets) where a.chats {
        guard let small = with.figures[b.id], let large = without.figures[a.id] else { markOK = false; continue }
        if abs(b.head - b.tall * share) > 0.001 || a.head != a.tall { markOK = false }
        let near = abs(b.mark.midY - (b.foot - small.high)), was = abs(a.mark.midY - (a.foot - large.high))
        let stale = abs(a.mark.midY - (a.foot - small.high))
        marks.append(String(format: "%@ %@→%@ %.0f/%.0f", b.id, "\(a.markPlace)", "\(b.markPlace)", was, near))
        if near > 20 || was > 20 { markOK = false }
        if stale > 20 { floating += 1 }
    }
    check("pet scale office: the chat mark sits by the flame's head at its size, as by a full-size one (\(marks.sorted())), where without the sizes \(floating) would float",
        markOK && !marks.isEmpty && floating > 0)
    check("pet scale office: without the field (`sizes` empty) the layout's marks are as before",
        with.layout.visited(by: OfficeVisits(), talking: talking, sizes: [:]).pets == markPlain.pets && plain.sizes(store).isEmpty)

    // ── 3. the sea room: the flame's drawn height is that share; the bubbles over its head follow it; the plate under its feet stays.
    let restore = seaSweepSetup(NSTemporaryDirectory() + "flame2-zone-\(getpid())")
    defer { restore() }
    if let scene = ZoneArt.scene {
        let size = CGSize(width: 1180, height: 790)
        let fit = ZoneFit(scene: scene.size, view: size)
        let room = Store()
        room.readOnly = true
        var list: [Session] = []
        func add(_ name: String, _ status: String, ago: Double, seen: Bool = true) {
            var s = Session(id: "flame2-\(list.count)", pid: 1, project: name, name: name, status: status, since: now - ago,
                            summary: status == "waiting" ? "要不要接着做？" : "做完了", waitingFor: status == "waiting" ? "permission prompt" : "")
            s.cwd = "/tmp/flame2/" + name
            s.registryName = name
            list.append(s)
            if seen { room.seen[s.id] = now.timeIntervalSince1970 }
        }
        add("Home-等你", "waiting", ago: 300)
        add("Home-干活", "busy", ago: 120)
        add("Web-新消息", "idle", ago: 400, seen: false)
        add("Ops-看过", "idle", ago: 900)
        add("AI-干活", "busy", ago: 200)
        room.sessions = list
        room.assignPets()
        func look(_ pets: OfficePets) -> [String: (foot: CGPoint, drawn: CGRect, sprite: CGRect, plate: CGRect?, bubble: CGRect?, dots: CGRect?)] {
            OfficePets.shared = pets
            let view = ZoneView(frame: CGRect(origin: .zero, size: size))
            view.still = true
            view.update(room)
            var out: [String: (foot: CGPoint, drawn: CGRect, sprite: CGRect, plate: CGRect?, bubble: CGRect?, dots: CGRect?)] = [:]
            for id in view.figureIDs {
                guard let foot = view.foot(of: id), let drawn = view.drawnBox(of: id), let sprite = view.sprite(of: id)?.frame else { continue }
                out[id] = (foot, drawn, sprite, view.plateFrame(of: id), view.bubbleFrame(of: id), view.dotFrame(of: id))
            }
            return out
        }
        let a = look(plain), b = look(scaled)
        var zoneOK = a.count == list.count && b.count == list.count
        var seen: [String] = [], asked = false, dotted = false
        for (id, x) in a {
            guard let y = b[id] else { zoneOK = false; continue }
            let r = y.drawn.height / x.drawn.height
            seen.append(String(format: "%.3f", r))
            if abs(r - share) > 0.002 || abs(y.sprite.height / x.sprite.height - share) > 0.002 || abs(y.drawn.width / x.drawn.width - share) > 0.002 { zoneOK = false }
            // Plates under the feet: where they were, as far under the feet.
            if let pa = x.plate, let pb = y.plate, abs((pa.minY - x.foot.y) - (pb.minY - y.foot.y)) > 0.5 { zoneOK = false }
        }
        check("pet scale sea room: the flame with scale \(share) stands \(share) as tall and wide as without it, in every pose here (\(seen.sorted())); plates under the feet as before",
            zoneOK)
        // The queue head's ask hangs over its head, its tail 3 points above it; the unread dots sit on its head's top.
        var follows = true
        for (id, x) in a {
            guard let y = b[id] else { continue }
            if let ba = x.bubble, let bb = y.bubble {
                asked = true
                let gapA = x.foot.y - x.drawn.height - ba.maxY, gapB = y.foot.y - y.drawn.height - bb.maxY
                if abs(gapA - gapB) > 0.5 || abs((bb.maxY - ba.maxY) - (x.drawn.height - y.drawn.height)) > 0.5 { follows = false }
            }
            if let da = x.dots, let db = y.dots {
                dotted = true
                let headA = x.foot.y - x.drawn.height, headB = y.foot.y - y.drawn.height
                if abs((da.minY + da.height * 0.8 - headA) - (db.minY + db.height * 0.8 - headB)) > 0.5 { follows = false }
            }
        }
        check("pet scale sea room: the ask bubble and the unread dots stay on the flame's head at its size (lower by what it lost)", follows && asked && dotted)
        _ = fit
    } else {
        skipped("no art", "pet scale sea room: the flame's size")
    }

    // ── 4. Every other pet: no field, so the same size as before, one by one (the office's formula without the field).
    OfficePets.shared = officeShared
    let real = Pets(dirs: PetSources.outside, builtIn: [])
    real.refresh(force: true)
    var changed: [String] = []
    var measured = 0
    let lone = "\(scratch)/lone"
    for pet in real.ids {
        if officeShared.size(pet) != 1 { changed.append(pet); continue }
        // That pet alone in a pool: every session has it; its figure at a desk is as the formula without the field gives.
        try? fm.removeItem(atPath: lone)
        try? fm.createDirectory(atPath: lone, withIntermediateDirectories: true)
        guard let source = PetSources.outside.first(where: { fm.fileExists(atPath: "\($0)/\(pet)/pet.json") }) else { continue }
        try? fm.createSymbolicLink(atPath: "\(lone)/\(pet)", withDestinationPath: "\(source)/\(pet)")
        Pets.shared = Pets(dirs: [lone], builtIn: [])
        Pets.shared.refresh(force: true)
        let one = officeStore()
        one.assignPets()
        let layout = OfficePainter.layout(one, now: now)
        guard let place = layout.pets.first(where: { $0.zone == .desk }), let s = one.sessions.first(where: { $0.id == place.id }),
            one.displayPets[s.id] == pet, let frame = officeShared.frame(pet, row: one.pose(of: s, now: now).sheet.row, column: one.pose(of: s, now: now).sheet.still),
            let idle = officeShared.frame(pet, row: 0, column: 0)
        else { continue }
        let before = OfficePets.scale((frame.tall, frame.wide), idle: (idle.tall, idle.wide), tall: place.tall) * officeShared.fit(pet, tall: place.tall, wide: nil)
        if OfficePainter.figure(one, s, place, now: now).scale != before { changed.append(pet) }
        measured += 1
    }
    if measured == 0 {
        skipped("no pet frames", "pet scale: every other pet keeps its size")
    } else {
        check("pet scale: every other pet (\(real.ids.count) in the pools, \(measured) measured at a desk) has no scale and keeps its size, one by one (\(changed))",
            changed.isEmpty && real.ids.allSatisfy { officeShared.size($0) == 1 })
    }
}
