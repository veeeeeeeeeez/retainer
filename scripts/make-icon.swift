// Draws the app icon and writes App/AppIcon.icns.
//
//   swift scripts/make-icon.swift            (run from the repository root)
//
// The icon is generated rather than hand-drawn so it can be reproduced and
// changed in code: a warm black tile with a low warm light in it, and
// over that the capture square as one large pane of glass: a tile in a tile.
import AppKit
import Foundation

func drawIcon(pixels: Int) -> Data {
    let size = CGFloat(pixels)
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // Apple's macOS icon grid: an 824 pt tile inside a 1024 pt canvas.
    let unit = size / 1024
    let tile = NSRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185 * unit, yRadius: 185 * unit)
    // The app's dark palette: background 151110, strong hairline 373533,
    // accent DDC1B1, text EAE8E6 (see Theme.swift).
    NSColor(srgbRed: 0x15 / 255.0, green: 0x11 / 255.0, blue: 0x10 / 255.0, alpha: 1).setFill()
    shape.fill()
    NSColor(srgbRed: 0x37 / 255.0, green: 0x35 / 255.0, blue: 0x33 / 255.0, alpha: 1).setStroke()
    shape.lineWidth = max(1, 6 * unit)
    shape.stroke()

    let cg = NSGraphicsContext.current!.cgContext
    let space = CGColorSpace(name: CGColorSpace.sRGB)
    func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    func sand(_ alpha: CGFloat) -> CGColor {
        CGColor(srgbRed: 0xDD / 255.0, green: 0xC1 / 255.0, blue: 0xB1 / 255.0, alpha: alpha)
    }
    func gradient(_ colours: [CGColor]) -> CGGradient {
        CGGradient(colorsSpace: space, colors: colours as CFArray, locations: nil)!
    }

    // The tile is not flat: a warm light low behind where the glass sits,
    // for the glass to have something to bend.
    let glow = CGPoint(x: tile.midX + 70 * unit, y: tile.midY - 110 * unit)
    cg.saveGState()
    shape.addClip()
    cg.drawRadialGradient(
        gradient([sand(0.30), sand(0)]), startCenter: glow, startRadius: 0, endCenter: glow,
        endRadius: 470 * unit, options: [])
    cg.restoreGState()

    // The capture square: one pane of glass, large, its corners only
    // slightly rounded. A tile in a tile.
    let side = 540 * unit
    let glass = CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
    let corner = 84 * unit
    let pane = CGPath(roundedRect: glass, cornerWidth: corner, cornerHeight: corner, transform: nil)
    let topLeft = CGPoint(x: glass.minX, y: glass.maxY)
    let bottomRight = CGPoint(x: glass.maxX, y: glass.minY)

    // Its shadow on the tile.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -30 * unit), blur: 90 * unit, color: CGColor(gray: 0, alpha: 0.8))
    cg.addPath(pane)
    cg.setFillColor(CGColor(srgbRed: 0x1C / 255.0, green: 0x19 / 255.0, blue: 0x17 / 255.0, alpha: 1))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(pane)
    cg.clip()
    // The light behind, gathered and brightened by the glass.
    let caught = CGPoint(x: glass.midX + 120 * unit, y: glass.midY - 150 * unit)
    cg.drawRadialGradient(
        gradient([sand(0.55), sand(0.12), sand(0)]), startCenter: caught, startRadius: 0, endCenter: caught,
        endRadius: 420 * unit, options: [])
    // A sheen from the top left, gone by the middle.
    cg.drawLinearGradient(
        gradient([white(0.30), white(0.04), white(0)]), start: topLeft,
        end: CGPoint(x: glass.midX + 60 * unit, y: glass.midY - 60 * unit), options: [])
    // One glint across the upper corner.
    cg.saveGState()
    cg.translateBy(x: glass.minX + 150 * unit, y: glass.maxY - 150 * unit)
    cg.rotate(by: .pi / 4)
    cg.drawLinearGradient(
        gradient([white(0), white(0.11), white(0)]), start: CGPoint(x: 0, y: -70 * unit),
        end: CGPoint(x: 0, y: 70 * unit), options: [])
    cg.restoreGState()
    cg.restoreGState()

    // Its edge is not drawn. Light gathers just inside it and fades away
    // inwards: cast as a shadow, in white, by a frame lying round the pane,
    // so there is no line anywhere, only a glow that blends into the glass.
    // Brightest along the top left; warm along the bottom right, where the
    // light behind comes through.
    let surround = CGMutablePath()
    surround.addRect(glass.insetBy(dx: -260 * unit, dy: -260 * unit))
    surround.addPath(pane)
    func innerGlow(_ colour: CGColor, towards offset: CGSize, blur: CGFloat) {
        cg.saveGState()
        cg.addPath(pane)
        cg.clip()
        cg.setShadow(offset: offset, blur: blur, color: colour)
        cg.addPath(surround)
        cg.setFillColor(white(1))
        cg.fillPath(using: .evenOdd)
        cg.restoreGState()
    }
    innerGlow(white(0.34), towards: .zero, blur: 34 * unit)
    innerGlow(white(0.62), towards: CGSize(width: 16 * unit, height: -16 * unit), blur: 54 * unit)
    innerGlow(sand(0.42), towards: CGSize(width: -14 * unit, height: 14 * unit), blur: 48 * unit)

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    try drawIcon(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try drawIcon(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("App/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
