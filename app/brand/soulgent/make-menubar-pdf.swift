import AppKit

// make-menubar-pdf <in.svg> <out.pdf>: the SVG drawn into a one-page PDF cropped to its ink (plus a hair of margin).
// The ink box is found on a 1024 px raster of the SVG; the PDF itself stays vector (no image inside).
let args = CommandLine.arguments
guard args.count == 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("usage: make-menubar-pdf <in.svg> <out.pdf>\n".data(using: .utf8)!)
    exit(1)
}
let box = NSRect(origin: .zero, size: svg.size)

// 1. The ink's bounds, in the SVG's units (y up).
let n = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
svg.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
NSGraphicsContext.restoreGraphicsState()
var minX = n, minY = n, maxX = -1, maxY = -1
for y in 0..<n { for x in 0..<n where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
guard maxX >= 0 else { FileHandle.standardError.write("no ink\n".data(using: .utf8)!); exit(1) }
let unit = box.width / CGFloat(n), margin: CGFloat = 0.5
// colorAt's y runs down; flip into the SVG box's y-up.
let ink = NSRect(x: CGFloat(minX) * unit - margin, y: CGFloat(n - 1 - maxY) * unit - margin,
                 width: CGFloat(maxX - minX + 1) * unit + 2 * margin, height: CGFloat(maxY - minY + 1) * unit + 2 * margin)

// 2. The PDF: its media box is the ink box, the SVG drawn shifted so the ink sits at the origin.
var media = CGRect(origin: .zero, size: ink.size)
let out = URL(fileURLWithPath: args[2]) as CFURL
guard let pdf = CGContext(out, mediaBox: &media, nil) else { exit(1) }
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
svg.draw(in: box.offsetBy(dx: -ink.minX, dy: -ink.minY))
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()
print(String(format: "%@  %.1f x %.1f (ink of the %.0f x %.0f SVG)", args[2], ink.width, ink.height, box.width, box.height))
