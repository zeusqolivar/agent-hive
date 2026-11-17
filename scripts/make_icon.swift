// Draws the app icon, a classroom character's hexagon face in honey on a navy tile, at every macOS icon
// size, and turns it into Sources/HiveApp/Resources/AppIcon.icns. Also writes docs/icon.png (256 px) for
// the README.
//
// Usage, from the repository root: swift scripts/make_icon.swift
import AppKit

let root = URL(filePath: FileManager.default.currentDirectoryPath, directoryHint: .isDirectory)

let honey = NSColor(srgbRed: 0.96, green: 0.72, blue: 0.0, alpha: 1)
let honeyDeep = NSColor(srgbRed: 0.85, green: 0.55, blue: 0.0, alpha: 1)
let navy = NSColor(srgbRed: 0.10, green: 0.13, blue: 0.21, alpha: 1)
let navy2 = NSColor(srgbRed: 0.17, green: 0.21, blue: 0.33, alpha: 1)
let cream = NSColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1)
let ink = NSColor(srgbRed: 0.11, green: 0.13, blue: 0.19, alpha: 1)

/// A hexagon with a point at the top, centred on `c`.
func hexPath(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    for i in 0..<6 {
        let a = CGFloat.pi / 3 * CGFloat(i) - CGFloat.pi / 2
        let pt = CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a))
        i == 0 ? p.move(to: pt) : p.line(to: pt)
    }
    p.close()
    return p
}

/// The icon in a 1024-point space: the macOS grid's 824-point rounded tile with a soft shadow, then the face.
func drawIcon() {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185).addClip()
    NSGradient(starting: navy2, ending: navy)!.draw(in: tile, angle: -90)
    let c = CGPoint(x: tile.midX, y: tile.midY - 10)
    NSGradient(starting: honey, ending: honeyDeep)!.draw(in: hexPath(c, 300), angle: -90)
    cream.setFill()
    hexPath(c, 228).fill()
    ink.setFill()
    NSBezierPath(ovalIn: CGRect(x: c.x - 110, y: c.y + 10, width: 56, height: 56)).fill()
    NSBezierPath(ovalIn: CGRect(x: c.x + 54, y: c.y + 10, width: 56, height: 56)).fill()
    let smile = NSBezierPath()
    smile.lineWidth = 26
    smile.lineCapStyle = .round
    smile.appendArc(withCenter: CGPoint(x: c.x, y: c.y - 20), radius: 70, startAngle: 200, endAngle: 340)
    ink.setStroke()
    smile.stroke()
    let stalk = NSBezierPath()
    stalk.lineWidth = 22
    stalk.lineCapStyle = .round
    stalk.move(to: CGPoint(x: c.x, y: c.y + 300))
    stalk.line(to: CGPoint(x: c.x, y: c.y + 360))
    honeyDeep.setStroke()
    stalk.stroke()
    honey.setFill()
    NSBezierPath(ovalIn: CGRect(x: c.x - 34, y: c.y + 340, width: 68, height: 68)).fill()
    NSGraphicsContext.restoreGraphicsState()
}

/// The icon as a PNG `pixels` wide.
func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(pixels) / 1024)
    scale.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let work = fm.temporaryDirectory.appending(path: "agent-hive-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
let iconset = work.appending(path: "AppIcon.iconset", directoryHint: .isDirectory)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: work) }

for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}

let icns = root.appending(path: "Sources/HiveApp/Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(filePath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

let docs = root.appending(path: "docs", directoryHint: .isDirectory)
try fm.createDirectory(at: docs, withIntermediateDirectories: true)
try png(pixels: 256).write(to: docs.appending(path: "icon.png"))
print(icns.path)
