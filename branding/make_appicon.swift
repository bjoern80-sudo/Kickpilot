import AppKit
// Aufruf: swift make_appicon.swift <icon.svg> <out.png>
// macOS-App-Icon 1024 × 1024: heller Squircle (Apple-Raster: 824 px Körper, 100 px Rand)
// mit dem Kickpilot-Emblem in der Mitte.
let a = CommandLine.arguments
guard let emblem = NSImage(contentsOf: URL(fileURLWithPath: a[1])) else { fatalError("SVG nicht lesbar") }
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: size, height: size)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current?.imageInterpolation = .high

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// leichter Schatten unter dem Körper
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -8)
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor.white.setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

// Körper: Weiß → kühles Hellgrau
let gradient = NSGradient(colors: [
    NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
    NSColor(srgbRed: 0.886, green: 0.910, blue: 0.945, alpha: 1),
])!
gradient.draw(in: squircle, angle: -90)

// Emblem zentriert, 86 % der Körperbreite
let ew = body.width * 0.86
let eh = ew * emblem.size.height / emblem.size.width
emblem.draw(in: NSRect(x: body.midX - ew / 2, y: body.midY - eh / 2 + 6, width: ew, height: eh))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
