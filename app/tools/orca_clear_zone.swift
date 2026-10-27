// Where an orca clip really goes, as a few rectangles for orca.json `clear_zone` (the crabs there step aside).
//
//   swift tools/orca_clear_zone.swift <folder with orca.json and the clips> [--clips C] [--alpha 240] [--margin 30] [--dry]
//
// For each named clip it decodes every frame of its film (AVFoundation, with alpha), keeps the pixels whose alpha is at
// least --alpha (the orca's body and solid splash; its soft shadow, 55–85 %, stays out), and of those only each frame's
// largest connected blob (on an 8 px grid), so flying droplets do not widen it. The union over all frames is cut into
// 32 px bands; each band's run from its leftmost to its rightmost cell becomes a rectangle, grown by --margin px and
// clipped to the picture, and touching rectangles of the same width-ish are merged. Rectangles are in the base picture's
// pixels (2400×1600, top-left origin), like `box`. It writes them into orca.json as the clip's "clear_zone" (a copy of the
// old file is kept as orca.json.bak), or with --dry only prints them.
import AVFoundation
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String, _ fallback: String) -> String {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return fallback }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let clipIDs = option("--clips", "C").split(separator: ",").map(String.init)
let alphaMin = Int(option("--alpha", "240")) ?? 240
let margin = Double(option("--margin", "30")) ?? 30
let dry = args.contains("--dry")
args.removeAll { $0 == "--dry" }
guard let folder = args.first else {
    print("usage: swift tools/orca_clear_zone.swift <folder> [--clips C] [--alpha 240] [--margin 30] [--dry]")
    exit(2)
}
let jsonURL = URL(fileURLWithPath: folder).appendingPathComponent("orca.json")
guard let data = try? Data(contentsOf: jsonURL), var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    var clips = root["clips"] as? [[String: Any]], let picture = root["picture"] as? [Double], picture.count == 2
else {
    print("no readable orca.json in \(folder)")
    exit(1)
}

let cell = 8, band = 32

/// The union, over all frames, of each frame's largest solid blob, as cells (cell-x, cell-y) of the clip's own frame.
func solidCells(_ url: URL) -> (cells: Set<Int>, columns: Int, rows: Int, frames: Int)? {
    final class Box: @unchecked Sendable { var value: (Set<Int>, Int, Int, Int)? }
    let box = Box(), done = DispatchSemaphore(value: 0)
    Task.detached {
        defer { done.signal() }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { return }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(out)
        guard reader.startReading() else { return }
        var union = Set<Int>(), cols = 0, rows = 0, frames = 0
        while let sample = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
            let p = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            cols = (w + cell - 1) / cell
            rows = (h + cell - 1) / cell
            var on = [Bool](repeating: false, count: cols * rows)
            for y in 0..<h {
                for x in 0..<w where Int(p[y * row + x * 4 + 3]) >= alphaMin { on[(y / cell) * cols + x / cell] = true }
            }
            CVPixelBufferUnlockBaseAddress(pb, .readOnly)
            // The largest 4-connected blob of solid cells.
            var seen = [Bool](repeating: false, count: on.count), best: [Int] = []
            for start in on.indices where on[start] && !seen[start] {
                var blob: [Int] = [], stack = [start]
                seen[start] = true
                while let c = stack.popLast() {
                    blob.append(c)
                    let cx = c % cols, cy = c / cols
                    for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] where nx >= 0 && ny >= 0 && nx < cols && ny < rows {
                        let n = ny * cols + nx
                        if on[n] && !seen[n] {
                            seen[n] = true
                            stack.append(n)
                        }
                    }
                }
                if blob.count > best.count { best = blob }
            }
            union.formUnion(best)
            frames += 1
        }
        box.value = (union, cols, rows, frames)
    }
    _ = done.wait(timeout: .now() + 120)
    guard let v = box.value else { return nil }
    return (v.0, v.1, v.2, v.3)
}

var changed = false
for (i, clip) in clips.enumerated() {
    guard let id = clip["id"] as? String, clipIDs.contains(id), let file = clip["file"] as? String, let b = clip["box"] as? [Double], b.count == 4 else { continue }
    guard let solid = solidCells(URL(fileURLWithPath: folder).appendingPathComponent(file)) else {
        print("\(id): could not read \(file)")
        exit(1)
    }
    // Bands of `band` px: leftmost to rightmost solid cell in each (picture pixels); neighbouring bands whose runs nearly
    // match (within 3 cells each side) merge; then every rectangle grows by the margin, clipped to the picture.
    var runs: [[Double]] = []
    let per = band / cell
    for bandIndex in 0..<((solid.rows + per - 1) / per) {
        let ys = (bandIndex * per)..<min(solid.rows, (bandIndex + 1) * per)
        let xs = solid.cells.filter { ys.contains($0 / solid.columns) }.map { $0 % solid.columns }
        guard let lo = xs.min(), let hi = xs.max() else { continue }
        let x0 = b[0] + Double(lo * cell), x1 = b[0] + Double((hi + 1) * cell)
        let y0 = b[1] + Double(ys.lowerBound * cell), y1 = b[1] + Double(ys.upperBound * cell)
        if let last = runs.last, abs(last[0] - x0) <= Double(3 * cell), abs(last[2] - x1) <= Double(3 * cell), y0 <= last[3] {
            runs[runs.count - 1] = [min(last[0], x0), last[1], max(last[2], x1), max(last[3], y1)]
        } else {
            runs.append([x0, y0, x1, y1])
        }
    }
    let rects = runs.map { [max(0, $0[0] - margin), max(0, $0[1] - margin), min(picture[0], $0[2] + margin), min(picture[1], $0[3] + margin)] }
    // The rectangles' union, counted on a 4 px grid, against the box.
    var covered = 0
    for y in stride(from: b[1], to: b[3], by: 4) {
        for x in stride(from: b[0], to: b[2], by: 4) where rects.contains(where: { x + 2 >= $0[0] && x + 2 < $0[2] && y + 2 >= $0[1] && y + 2 < $0[3] }) { covered += 1 }
    }
    let share = Double(covered * 16) / ((b[2] - b[0]) * (b[3] - b[1]))
    print("\(id): \(solid.frames) frames, \(solid.cells.count) solid cells → \(rects.count) rectangles covering \(Int((100 * share).rounded())) % of its box \(b.map { Int($0) })")
    for r in rects { print("   [\(Int(r[0])), \(Int(r[1])), \(Int(r[2])), \(Int(r[3]))]") }
    var c = clip
    c["clear_zone"] = rects.map { $0.map { Int($0.rounded()) } }
    c["clear_zone_rule"] = "alpha >= \(alphaMin), largest blob a frame on an \(cell) px grid, \(band) px bands, + \(Int(margin)) px (app/tools/orca_clear_zone.swift)"
    clips[i] = c
    changed = true
}
guard changed else {
    print("no clip named \(clipIDs) in orca.json")
    exit(1)
}
if dry { exit(0) }
root["clips"] = clips
try? FileManager.default.removeItem(at: jsonURL.appendingPathExtension("bak"))
try FileManager.default.copyItem(at: jsonURL, to: jsonURL.appendingPathExtension("bak"))
let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
try out.write(to: jsonURL)
print("wrote \(jsonURL.path) (old one at orca.json.bak)")
