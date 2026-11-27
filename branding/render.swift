import AppKit
// Aufruf: swift render.swift <in.svg> <out.png> <breite> <höhe> [rand in %]   (0 = aus Seitenverhältnis)
// Rendert das SVG, schneidet den transparenten Rand ab und zentriert den
// Inhalt mit dem angegebenen Rand im Zielformat (Seitenverhältnis bleibt).
let a = CommandLine.arguments
guard let img = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("SVG nicht lesbar") }
var w = Int(a[3])!   // 0 = Breite aus Seitenverhältnis des Inhalts
var h = Int(a[4])!   // 0 = Höhe aus Seitenverhältnis des Inhalts
let pad = a.count > 5 ? Double(a[5])! / 100 : 0

func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// 1. groß rendern und Inhaltsrahmen bestimmen
let big = 2048.0
let sw = img.size.width, sh = img.size.height
let k = big / max(sw, sh)
let bw = Int(sw * k), bh = Int(sh * k)
let full = bitmap(bw, bh) { img.draw(in: NSRect(x: 0, y: 0, width: bw, height: bh)) }
var minX = bw, minY = bh, maxX = 0, maxY = 0
let data = full.bitmapData!, bpr = full.bytesPerRow
for y in 0..<bh { for x in 0..<bw where data[y * bpr + x * 4 + 3] > 8 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
// Bitmap-Zeilen laufen von oben nach unten, Zeichenkoordinaten von unten nach oben
let crop = NSRect(x: Double(minX), y: Double(bh - 1 - maxY), width: Double(maxX - minX + 1), height: Double(maxY - minY + 1))

// 2. zugeschnitten ins Zielformat einpassen
if h == 0 { h = Int((Double(w) * crop.height / crop.width).rounded()) }
if w == 0 { w = Int((Double(h) * crop.width / crop.height).rounded()) }
let availW = Double(w) * (1 - 2 * pad), availH = Double(h) * (1 - 2 * pad)
let f = min(availW / crop.width, availH / crop.height)
let dw = crop.width * f, dh = crop.height * f
let fullImg = NSImage(size: NSSize(width: bw, height: bh)); fullImg.addRepresentation(full)
let out = bitmap(w, h) {
    fullImg.draw(in: NSRect(x: (Double(w) - dw) / 2, y: (Double(h) - dh) / 2, width: dw, height: dh),
                 from: crop, operation: .sourceOver, fraction: 1)
}
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
