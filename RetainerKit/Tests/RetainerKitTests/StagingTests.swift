import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Pasted and dropped things")
@MainActor
struct StagingTests {

    /// A pasteboard of the test's own, so the real clipboard is never touched.
    private func pasteboard() -> NSPasteboard {
        let board = NSPasteboard.withUniqueName()
        board.clearContents()
        return board
    }

    private func png(width: Int = 320, height: Int = 200, scale: CGFloat = 1) throws -> Data {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("staging-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: file) }
        try ImageFiles.writePNG(image, scale: scale, to: file)
        return try Data(contentsOf: file)
    }

    private func items(_ reading: StagedItem.Reading) -> [StagedItem] {
        if case .items(let items) = reading { return items }
        return []
    }

    // MARK: What counts as a link

    @Test("A web address on its own is a link; anything else typed is not")
    func webAddresses() {
        #expect(StagedItem.webURL(from: "https://example.com/a/b?c=d")?.absoluteString == "https://example.com/a/b?c=d")
        #expect(StagedItem.webURL(from: "  http://example.org \n")?.host == "example.org")
        #expect(StagedItem.webURL(from: "www.example.com/page")?.absoluteString == "https://www.example.com/page")
        #expect(StagedItem.webURL(from: "HTTPS://Example.com")?.host?.lowercased() == "example.com")

        for text in [
            "", "hello", "example", "example.com", "see https://example.com now", "https://", "https://nodots",
            "ftp://example.com/file", "file:///Users/someone/a.png", "www.", "e.g.",
        ] {
            #expect(StagedItem.webURL(from: text) == nil, "\(text)")
        }
    }

    @Test("A site is named without its www")
    func siteNames() {
        #expect(StagedItem.siteName(of: URL(string: "https://www.youtube.com/watch?v=1")!) == "youtube.com")
        #expect(StagedItem.siteName(of: URL(string: "https://news.example.org")!) == "news.example.org")
    }

    // MARK: Reading the clipboard

    @Test("A copied link is staged as a link, with a card drawn for it")
    func copiedLink() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        board.setString("https://www.youtube.com/watch?v=abc123", forType: .string)

        let found = items(StagedItem.read(from: board))
        let link = try #require(found.first)
        #expect(found.count == 1)
        #expect(link.kind == .link)
        #expect(link.sourceURL == "https://www.youtube.com/watch?v=abc123")
        #expect(link.origin == "Link" && link.title == "youtube.com")
        // The card: 640 x 320 points at two pixels to the point.
        #expect(link.image.cgImage.width == 1280 && link.image.cgImage.height == 640)
        #expect(link.image.scale == 2)
    }

    @Test("A copied picture is staged as a picture, and remembers the page it was copied from")
    func copiedPicture() throws {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        board.declareTypes([.png, .URL, .string], owner: nil)
        board.setData(try png(), forType: .png)
        board.setString("https://example.com/gallery/3", forType: .URL)
        board.setString("https://example.com/gallery/3", forType: .string)

        let found = items(StagedItem.read(from: board))
        let picture = try #require(found.first)
        #expect(found.count == 1)
        #expect(picture.kind == .image)
        #expect(picture.image.cgImage.width == 320 && picture.image.cgImage.height == 200)
        #expect(picture.sourceURL == "https://example.com/gallery/3")
        #expect(picture.title == "example.com")
    }

    @Test("Copied picture files are staged, each with its own path; other files are not")
    func copiedFiles() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("one.png")
        let second = folder.appendingPathComponent("two.png")
        let text = folder.appendingPathComponent("notes.txt")
        try png().write(to: first)
        try png(width: 100, height: 80).write(to: second)
        try Data("not a picture".utf8).write(to: text)

        let board = pasteboard()
        defer { board.releaseGlobally() }
        board.writeObjects([first as NSURL, text as NSURL, second as NSURL])
        let found = items(StagedItem.read(from: board))
        #expect(found.map(\.title) == ["one.png", "two.png"])
        #expect(found.first?.sourceURL == first.absoluteString)
        #expect(found.last?.image.cgImage.width == 100)

        // Only a file that is not a picture: nothing to stage, and not text.
        board.clearContents()
        board.writeObjects([text as NSURL])
        if case .unsupported = StagedItem.read(from: board) {} else { Issue.record("expected unsupported") }
    }

    @Test("Plain text is left to be pasted as text")
    func copiedText() {
        let board = pasteboard()
        defer { board.releaseGlobally() }
        board.setString("just a thought, not a link", forType: .string)
        if case .nothing = StagedItem.read(from: board) {} else { Issue.record("expected nothing") }
        board.clearContents()
        if case .nothing = StagedItem.read(from: board) {} else { Issue.record("expected nothing") }
    }

    // MARK: Pictures from outside

    @Test("A picture keeps its density and is never larger than a card can use")
    func pictureReading() throws {
        // A screenshot: two pixels to the point.
        let screenshot = try #require(PictureReader.image(from: try png(width: 800, height: 600, scale: 2)))
        #expect(screenshot.scale == 2)
        #expect(screenshot.pointSize == CGSize(width: 400, height: 300))

        // Something enormous is brought down to size, keeping its shape.
        let huge = try #require(PictureReader.image(from: try png(width: 9000, height: 3000)))
        #expect(huge.cgImage.width == PictureReader.longestSide)
        #expect(abs(Double(huge.cgImage.width) / Double(huge.cgImage.height) - 3) < 0.01)

        #expect(PictureReader.image(from: Data("not a picture".utf8)) == nil)
    }

    @Test("A link's card drawn from its address is words on the panel and nothing else")
    func linkCardIsWordsOnly() throws {
        let card = try #require(LinkCard.draw(for: URL(string: "https://example.org/a/long/path?with=query")!))
        let image = card.cgImage
        #expect(image.width == 1280 && image.height == 640)

        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let reader = try #require(
            CGContext(
                data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reader.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        // No coloured tile anywhere: every pixel is the panel, the words, or
        // a grey between them where a letter's edge is.
        var coloured = 0
        var written = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let (red, green, blue) = (Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2]))
            if max(red, green, blue) - min(red, green, blue) > 24 { coloured += 1 }
            if red > 120 { written += 1 }
        }
        #expect(coloured == 0)
        #expect(written > 2000)
        // The top left corner, where the tile with the site's first letter used to be, is bare.
        let corner = (80 * image.width + 80) * 4
        #expect(pixels[corner] == 0x1B && pixels[corner + 1] == 0x19 && pixels[corner + 2] == 0x17)
    }

    // MARK: The input box

    @Test("Pasted things wait in the box until Return sends them on together")
    func stagingModel() throws {
        let staging = StagingModel()
        var sent: [[StagedItem]] = []
        staging.onSubmit = { sent.append($0) }
        #expect(!staging.canSubmit)

        let board = pasteboard()
        defer { board.releaseGlobally() }
        board.setString("https://example.com/one", forType: .string)
        #expect(staging.take(from: board))
        board.clearContents()
        board.setData(try png(), forType: .png)
        #expect(staging.take(from: board))
        #expect(staging.items.map(\.kind) == [.link, .image])
        #expect(staging.canSubmit)

        // Plain text is not taken.
        board.clearContents()
        board.setString("a thought", forType: .string)
        #expect(!staging.take(from: board))
        #expect(staging.items.count == 2)

        staging.submit()
        #expect(sent.count == 1 && sent[0].map(\.kind) == [.link, .image])
        #expect(staging.items.isEmpty && !staging.canSubmit)
    }

    @Test("Words typed in the box are saved as a note; a link typed on its own goes on to be spoken about")
    func typedWords() throws {
        let staging = StagingModel()
        var spoken: [[StagedItem]] = []
        var saved: [(String, [StagedItem])] = []
        staging.onSubmit = { spoken.append($0) }
        staging.onSave = { saved.append(($0, $1)) }
        #expect(!staging.canSubmit)

        // Words alone: they are the note.
        staging.text = "  compare the two pricing tables  "
        #expect(staging.canSubmit)
        staging.submit()
        #expect(saved.count == 1 && saved[0].0 == "compare the two pricing tables" && saved[0].1.isEmpty)
        #expect(spoken.isEmpty && staging.text.isEmpty)

        // Words with something waiting: saved together, nothing spoken.
        let link = try #require(StagedItem.link(URL(string: "https://example.com/1")!))
        staging.add([link])
        staging.text = "worth a second read"
        staging.submit()
        #expect(saved.count == 2 && saved[1].0 == "worth a second read" && saved[1].1.map(\.id) == [link.id])
        #expect(staging.items.isEmpty && spoken.isEmpty)

        // A link on its own is not a note about nothing: it goes on to be spoken about.
        staging.text = "www.example.com/essay"
        staging.submit()
        #expect(saved.count == 2)
        #expect(spoken.count == 1 && spoken[0].first?.sourceURL == "https://www.example.com/essay")
        #expect(staging.text.isEmpty)

        // Nothing at all does nothing.
        staging.submit()
        #expect(saved.count == 2 && spoken.count == 1)
    }

    @Test("Something waiting can be taken out again, by its cross or with backspace")
    func removing() throws {
        let staging = StagingModel()
        let first = try #require(StagedItem.link(URL(string: "https://example.com/1")!))
        let second = try #require(StagedItem.link(URL(string: "https://example.com/2")!))
        let third = try #require(StagedItem.link(URL(string: "https://example.com/3")!))
        staging.add([first, second, third])
        staging.remove(second.id)
        #expect(staging.items.map(\.id) == [first.id, third.id])
        staging.removeLast()
        #expect(staging.items.map(\.id) == [first.id])
        staging.removeLast()
        staging.removeLast()
        #expect(staging.items.isEmpty)
    }
}
