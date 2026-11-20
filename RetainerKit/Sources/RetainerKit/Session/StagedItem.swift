import AppKit
import CoreGraphics
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Something brought into the app by hand, not captured from the screen: a
/// picture or a link, pasted into the input box or dropped on the board.
///
/// It goes through the same steps as a capture from the point where the
/// screenshot would have lifted to the middle of the screen: it is shown
/// there, the microphone is on, and what is said becomes its note.
struct StagedItem: Identifiable, @unchecked Sendable {

    enum Kind: Equatable, Sendable {
        case image
        case link
        /// A file that is not a picture: shown by its preview, kept by its path.
        case file
        /// Words typed with nothing attached.
        case text
    }

    let id: UUID
    let kind: Kind
    /// The card's picture: the picture itself, or for a link a card drawn
    /// from its address.
    let image: CapturedImage
    /// The link, or where the picture came from when that is known. It goes
    /// on the card as its source.
    let sourceURL: String?
    /// What the card says it is, where a capture names the app it was taken from.
    let origin: String
    /// The site's name or the file's, where a capture has a window's title.
    let title: String?
    /// Where on the board it was dropped, if it was.
    var boardPoint: CGPoint?

    init(
        id: UUID = UUID(), kind: Kind, image: CapturedImage, sourceURL: String?, origin: String, title: String?,
        boardPoint: CGPoint? = nil
    ) {
        self.id = id
        self.kind = kind
        self.image = image
        self.sourceURL = sourceURL
        self.origin = origin
        self.title = title
        self.boardPoint = boardPoint
    }

    // MARK: Making one

    /// A picture read from a file.
    static func picture(at file: URL) -> StagedItem? {
        guard isPicture(file), let image = PictureReader.image(at: file) else { return nil }
        return StagedItem(
            kind: .image, image: image, sourceURL: file.absoluteString, origin: "Picture",
            title: file.lastPathComponent)
    }

    /// A picture from its bytes, with the page it was copied from if known.
    static func picture(from data: Data, page: URL? = nil) -> StagedItem? {
        guard let image = PictureReader.image(from: data) else { return nil }
        return StagedItem(
            kind: .image, image: image, sourceURL: page?.absoluteString, origin: "Picture",
            title: page.flatMap(siteName))
    }

    /// A link, as a card drawn from its address. Nothing is fetched: the app
    /// makes no network calls, so there is no title or preview to show, only
    /// what the address itself says.
    @MainActor
    static func link(_ url: URL) -> StagedItem? {
        guard let image = LinkCard.draw(for: url) else { return nil }
        return StagedItem(
            kind: .link, image: image, sourceURL: url.absoluteString, origin: "Link", title: siteName(of: url))
    }

    /// Words on their own. A card has a picture, so a typed note gets a slim
    /// band at its top that says what it is; the words are its note.
    @MainActor
    static func typedNote() -> StagedItem? {
        guard let image = LinkCard.drawBand() else { return nil }
        return StagedItem(kind: .text, image: image, sourceURL: nil, origin: "Typed", title: nil)
    }

    /// Any file: its preview as the picture (the first page of a document,
    /// the icon when there is nothing better), and its path as the source,
    /// so the card leads back to the file itself.
    @MainActor
    static func file(at url: URL) async -> StagedItem? {
        guard url.isFileURL else { return nil }
        if isPicture(url), let picture = picture(at: url) { return picture }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 640, height: 480), scale: 2, representationTypes: .all)
        let preview: CGImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
                continuation.resume(returning: thumbnail?.cgImage)
            }
        }
        let image =
            preview
            ?? NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: nil, context: nil, hints: nil)
        guard let image else { return nil }
        return StagedItem(
            kind: .file, image: CapturedImage(cgImage: image, scale: 2), sourceURL: url.absoluteString,
            origin: "File", title: url.lastPathComponent)
    }

    /// Whether a file is a picture, going by its kind.
    static func isPicture(_ file: URL) -> Bool {
        guard file.isFileURL else { return false }
        if let type = try? file.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .image)
        }
        return UTType(filenameExtension: file.pathExtension)?.conforms(to: .image) ?? false
    }

    /// The web address in a piece of text, if the text is one and nothing
    /// else: `https://…`, `http://…`, or something starting `www.`.
    static func webURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        let lowered = trimmed.lowercased()
        let candidate: String
        if lowered.hasPrefix("http://") || lowered.hasPrefix("https://") {
            candidate = trimmed
        } else if lowered.hasPrefix("www.") {
            candidate = "https://" + trimmed
        } else {
            return nil
        }
        guard let url = URL(string: candidate), let host = url.host, host.contains("."), !host.hasSuffix(".")
        else { return nil }
        return url
    }

    /// A site's name as people say it: the host without `www.`.
    static func siteName(of url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    // MARK: From the clipboard

    /// What a pasteboard holds, as far as staging is concerned.
    enum Reading {
        /// Links and pictures.
        case items([StagedItem])
        /// Files that are not pictures: nothing to stage, and not text either.
        case unsupported
        /// Plain text or nothing: not for staging.
        case nothing
    }

    /// Reads the links and pictures on a pasteboard: copied files first, then
    /// a copied picture, then a link.
    @MainActor
    static func read(from pasteboard: NSPasteboard) -> Reading {
        let urls =
            (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        let files = urls.filter(\.isFileURL)
        if !files.isEmpty {
            let pictures = files.compactMap(picture(at:))
            return pictures.isEmpty ? .unsupported : .items(pictures)
        }

        let page = urls.first { $0.scheme == "http" || $0.scheme == "https" }
        for type in pasteboard.types ?? [] {
            guard let kind = UTType(type.rawValue), kind.conforms(to: .image),
                let data = pasteboard.data(forType: type), let item = picture(from: data, page: page)
            else { continue }
            return .items([item])
        }

        let address = page ?? pasteboard.string(forType: .string).flatMap(webURL(from:))
        if let address, let item = link(address) { return .items([item]) }
        return .nothing
    }

    // MARK: From a drop

    /// Reads the pictures in a drop: picture files, or a picture dragged out
    /// of another app. Anything else in the drop is left out.
    @MainActor
    static func pictures(from providers: [NSItemProvider]) async -> [StagedItem] {
        var items: [StagedItem] = []
        for provider in providers {
            let url = await loadURL(from: provider)
            if let url, url.isFileURL {
                let item = await Task.detached(priority: .userInitiated) { picture(at: url) }.value
                if let item { items.append(item) }
                continue
            }
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                let data = await loadData(from: provider, type: .image)
            else { continue }
            let page = url.flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil }
            let item = await Task.detached(priority: .userInitiated) { picture(from: data, page: page) }.value
            if let item { items.append(item) }
        }
        return items
    }

    @MainActor
    private static func loadURL(from provider: NSItemProvider) async -> URL? {
        guard provider.canLoadObject(ofClass: URL.self) else { return nil }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
    }

    @MainActor
    private static func loadData(from provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Decodes a picture that came from outside: turned the right way up, never
/// larger than a card can use, at the density the file says it has.
enum PictureReader {

    /// The longest side kept, in pixels. A photograph straight off a camera
    /// is several times this, and every card would carry all of it.
    static let longestSide = 4096

    static func image(at file: URL) -> CapturedImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        return image(from: source)
    }

    static func image(from data: Data) -> CapturedImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return image(from: source)
    }

    private static func image(from source: CGImageSource) -> CapturedImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        // A screenshot says 144 dots to the inch: two pixels to the point.
        // Most other pictures say 72, or nothing.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = min(max((dpi / 72).rounded(), 1), 3)
        return CapturedImage(cgImage: image, scale: CGFloat(scale))
    }
}

/// Draws the card that stands for a link: the site's name large, the rest of
/// the address under it, and a tile in a colour of the site's own.
///
/// The colour is worked out from the site's name, so one site is always the
/// same colour and different sites mostly differ. It is what the card is
/// remembered by on the mini map.
@MainActor
enum LinkCard {

    static let size = CGSize(width: 640, height: 320)
    static let scale: CGFloat = 2

    static func draw(for url: URL) -> CapturedImage? {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous }

        // The card is always the dark panel, whichever way the window is
        // set: it is a picture, like a screenshot, and keeps its look.
        let paper = NSColor(srgbRed: 0x1B / 255, green: 0x19 / 255, blue: 0x17 / 255, alpha: 1)
        let ink = NSColor(srgbRed: 0xEA / 255, green: 0xE8 / 255, blue: 0xE6 / 255, alpha: 1)
        let quiet = NSColor(srgbRed: 0xA5 / 255, green: 0xA0 / 255, blue: 0x9D / 255, alpha: 1)
        paper.setFill()
        NSRect(origin: .zero, size: size).fill()

        let site = StagedItem.siteName(of: url) ?? url.absoluteString
        let margin: CGFloat = 40
        let room = size.width - 2 * margin

        // Words and nothing else: the site on one line, and under it the
        // rest of the address on up to three, the two set in the middle of
        // the card together.
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let name = NSAttributedString(
            string: site,
            attributes: [
                .font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: ink,
                .paragraphStyle: truncating,
            ])
        let nameHeight: CGFloat = 54

        var rest = url.path
        if rest == "/" { rest = "" }
        if let query = url.query, !query.isEmpty { rest += "?" + query }
        let wrapping = NSMutableParagraphStyle()
        wrapping.lineBreakMode = .byCharWrapping
        wrapping.lineSpacing = 3
        let address = NSAttributedString(
            string: rest,
            attributes: [
                .font: NSFont.systemFont(ofSize: 17, weight: .regular), .foregroundColor: quiet,
                .paragraphStyle: wrapping,
            ])
        let addressHeight =
            rest.isEmpty
            ? 0
            : min(
                72,
                ceil(
                    address.boundingRect(
                        with: NSSize(width: room, height: 72), options: [.usesLineFragmentOrigin]
                    ).height))
        let gap: CGFloat = rest.isEmpty ? 0 : 10
        let top = ((size.height + nameHeight + gap + addressHeight) / 2).rounded()

        name.draw(
            with: NSRect(x: margin, y: top - nameHeight, width: room, height: nameHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if !rest.isEmpty {
            address.draw(
                with: NSRect(x: margin, y: top - nameHeight - gap - addressHeight, width: room, height: addressHeight),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }

        guard let image = context.makeImage() else { return nil }
        return CapturedImage(cgImage: image, scale: scale)
    }

    /// The slim band at the top of a note that was typed: the panel's own
    /// colour with a small mark in the accent, three lines of writing.
    static func drawBand() -> CapturedImage? {
        let band = CGSize(width: 640, height: 84)
        guard
            let context = CGContext(
                data: nil, width: Int(band.width * scale), height: Int(band.height * scale), bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(srgbRed: 0x1B / 255, green: 0x19 / 255, blue: 0x17 / 255, alpha: 1))
        context.fill(CGRect(origin: .zero, size: band))
        // Lines of writing, in the app's sand.
        context.setFillColor(CGColor(srgbRed: 0xDD / 255, green: 0xC1 / 255, blue: 0xB1 / 255, alpha: 1))
        for (index, width) in [CGFloat(150), 210, 110].enumerated() {
            let line = CGRect(x: 32, y: band.height - 26 - CGFloat(index) * 16, width: width, height: 5)
            context.addPath(CGPath(roundedRect: line, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        }
        context.fillPath()
        guard let image = context.makeImage() else { return nil }
        return CapturedImage(cgImage: image, scale: scale)
    }
}
