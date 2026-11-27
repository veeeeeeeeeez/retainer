// Draws the picture behind the icons in the disk image's window and writes
// scripts/dmg/background.tiff.
//
//   swift scripts/make-dmg-background.swift     (run from the repository root)
//
// The window shows the app on the left and the Applications folder on the
// right; this is what lies under them: an arrow from the one to the other,
// and a line at the bottom about the first launch. It is white with grey on
// it, like the downloads page. The Finder draws a window that has a picture
// as a light one whatever the Mac is set to, with the names of the icons in
// black, so a dark picture would leave them unreadable.
//
// The picture is as large as the inside of the window. The sizes here, in
// points, are also in scripts/dmg/build.py: change them in both.
import AppKit
import Foundation

let width: CGFloat = 600
let height: CGFloat = 400
/// The middle of the two icons, measured from the top left as the Finder does.
let appCentre = CGPoint(x: 165, y: 160)
let applicationsCentre = CGPoint(x: 435, y: 160)
let noteHeight: CGFloat = 56
let note = "If macOS won’t open it: System Settings › Privacy & Security › Open Anyway"

func grey(_ value: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(value) / 255, green: CGFloat(value) / 255, blue: CGFloat(value) / 255, alpha: 1)
}

func draw(scale: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(width) * scale, pixelsHigh: Int(height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    // In points: this is what makes the larger picture the same drawing at
    // twice the detail and not a drawing twice the size.
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Everything below is placed from the top left, as the icons are.
    func fromTop(_ y: CGFloat) -> CGFloat { height - y }

    grey(255).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    // The arrow, level with the middles of the two icons and midway between
    // what can be seen of them: at 128 points the app's tile is 103 across
    // and the folder 118, so that is a little left of midway between centres.
    let middle = ((appCentre.x + 51.5) + (applicationsCentre.x - 59)) / 2
    let level = fromTop(appCentre.y)
    let halfLength: CGFloat = 30
    let head: CGFloat = 9
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: middle - halfLength, y: level))
    arrow.line(to: NSPoint(x: middle + halfLength, y: level))
    arrow.move(to: NSPoint(x: middle + halfLength - head, y: level + head))
    arrow.line(to: NSPoint(x: middle + halfLength, y: level))
    arrow.line(to: NSPoint(x: middle + halfLength - head, y: level - head))
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    grey(0xC4).setStroke()
    arrow.stroke()

    // The band along the bottom, in the greys of the page's table.
    grey(0xF7).setFill()
    NSRect(x: 0, y: 0, width: width, height: noteHeight).fill()
    grey(0xDD).setFill()
    NSRect(x: 0, y: noteHeight - 1, width: width, height: 1).fill()

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11.5),
        .foregroundColor: grey(0x99),
        .paragraphStyle: style,
    ]
    let line = NSAttributedString(string: note, attributes: attributes)
    let lineHeight = line.size().height
    line.draw(in: NSRect(x: 0, y: (noteHeight - lineHeight) / 2, width: width, height: lineHeight))

    return bitmap.representation(using: .png, properties: [:])!
}

// One file holding the picture at both sizes, which is what the Finder wants
// for a window that may be on a Retina display or not.
let work = FileManager.default.temporaryDirectory.appendingPathComponent("dmg-background-\(ProcessInfo.processInfo.processIdentifier)")
try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }
let single = work.appendingPathComponent("background.png")
let double = work.appendingPathComponent("background@2x.png")
try draw(scale: 1).write(to: single)
try draw(scale: 2).write(to: double)

let output = "scripts/dmg/background.tiff"
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", single.path, double.path, "-out", output]
try tiffutil.run()
tiffutil.waitUntilExit()
guard tiffutil.terminationStatus == 0 else {
    FileHandle.standardError.write("error: tiffutil could not write \(output)\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(output)")
