import AppKit
import CoreGraphics
import Foundation

/// Finds room for a card on the canvas.
///
/// A card that is being added (a new capture, or one coming back from the
/// archive) is put as close as possible to where it is wanted without
/// touching any other card, and by preference next to one, lined up with it,
/// so cards fall into rows and columns instead of a scatter.
public enum CanvasLayout {

    /// Clear space kept between cards: one step of the canvas's dot grid.
    public static let gap: CGFloat = 24

    /// How much further away a place lined up with a neighbour may be before
    /// a nearer, unaligned one is taken instead.
    static let alignmentAllowance: CGFloat = 48

    /// Whether two cards overlap or sit closer than `gap`.
    public static func crowds(_ a: CGRect, _ b: CGRect, gap: CGFloat = CanvasLayout.gap) -> Bool {
        // Half a point of slack, so cards exactly `gap` apart are not crowding.
        let reach = gap - 0.5
        return a.minX < b.maxX + reach && b.minX < a.maxX + reach
            && a.minY < b.maxY + reach && b.minY < a.maxY + reach
    }

    /// The top-left corner for a card of `size` whose middle should be as
    /// near `target` as it can be without crowding any rectangle in
    /// `occupied`.
    ///
    /// If the spot centred on `target` is clear, that is the answer.
    /// Otherwise the places tried are the ones directly beside each occupied
    /// rectangle (right, left, below, above), both lined up with that
    /// rectangle's edge and level with the target. A place wholly inside
    /// `viewport` beats one that is not; after that the nearest wins, with
    /// lined-up places given a head start.
    public static func freeOrigin(
        for size: CGSize,
        near target: CGPoint,
        avoiding occupied: [CGRect],
        preferring viewport: CGRect? = nil,
        gap: CGFloat = CanvasLayout.gap
    ) -> CGPoint {
        let ideal = CGPoint(
            x: (target.x - size.width / 2).rounded(),
            y: (target.y - size.height / 2).rounded())

        func isFree(_ origin: CGPoint) -> Bool {
            let frame = CGRect(origin: origin, size: size)
            return !occupied.contains { crowds(frame, $0, gap: gap) }
        }
        if isFree(ideal) { return ideal }

        struct Candidate {
            var origin: CGPoint
            var outsideViewport: Bool
            var cost: CGFloat
        }
        var best: Candidate?

        func consider(_ point: CGPoint, aligned: Bool, direction: CGFloat) {
            let origin = CGPoint(x: point.x.rounded(), y: point.y.rounded())
            guard isFree(origin) else { return }
            let frame = CGRect(origin: origin, size: size)
            let distance = hypot(frame.midX - target.x, frame.midY - target.y)
            let candidate = Candidate(
                origin: origin,
                outsideViewport: !(viewport?.contains(frame) ?? true),
                // `direction` only settles near-ties: right, then below, left, above.
                cost: distance + (aligned ? 0 : alignmentAllowance) + direction)
            guard let current = best else {
                best = candidate
                return
            }
            let better: Bool
            if candidate.outsideViewport != current.outsideViewport {
                better = !candidate.outsideViewport
            } else if candidate.cost != current.cost {
                better = candidate.cost < current.cost
            } else if candidate.origin.y != current.origin.y {
                better = candidate.origin.y < current.origin.y
            } else {
                better = candidate.origin.x < current.origin.x
            }
            if better { best = candidate }
        }

        for rect in occupied {
            let right = rect.maxX + gap
            let left = rect.minX - gap - size.width
            let below = rect.maxY + gap
            let above = rect.minY - gap - size.height
            // Lined up with the card it would sit beside.
            consider(CGPoint(x: right, y: rect.minY), aligned: true, direction: 0)
            consider(CGPoint(x: rect.minX, y: below), aligned: true, direction: 1)
            consider(CGPoint(x: left, y: rect.minY), aligned: true, direction: 2)
            consider(CGPoint(x: rect.minX, y: above), aligned: true, direction: 3)
            // Level with where it was aiming.
            consider(CGPoint(x: right, y: ideal.y), aligned: false, direction: 0)
            consider(CGPoint(x: ideal.x, y: below), aligned: false, direction: 1)
            consider(CGPoint(x: left, y: ideal.y), aligned: false, direction: 2)
            consider(CGPoint(x: ideal.x, y: above), aligned: false, direction: 3)
        }
        // There is always room to the right of the rightmost card, so `best`
        // is only missing when nothing was in the way to begin with.
        return best?.origin ?? ideal
    }
}

/// The first lines of a note as plain text, for the small card on the canvas.
public enum NotePreview {

    /// The note's blocks run together on one line: paragraphs, headings and
    /// list items (with their markers) separated by spaces. Emphasis and
    /// other Markdown marks are dropped.
    public static func text(for source: String) -> String {
        var parts: [String] = []
        for block in MarkdownParser.blocks(from: source) {
            let text = String(block.text.characters)
                .split(whereSeparator: \.isNewline).joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if case .listItem(let marker?, _) = block.kind {
                parts.append("\(marker) \(text)")
            } else if block.kind != .rule {
                parts.append(text)
            }
        }
        return parts.joined(separator: " ")
    }
}

/// How tall a card will be at 100% zoom, worked out from the same sizes
/// `NodeView` lays out with. Used to find room for a card before it has been
/// drawn; once it has, the canvas uses its real height instead.
public enum NodeLayout {

    static let padding: CGFloat = 14
    static let captionFontSize: CGFloat = 15
    static let captionLineSpacing: CGFloat = 4
    /// The card shows this many lines of the note; the rest is in the opened card.
    static let captionLines = 3
    /// How many lines of a typed note its card shows: it has no picture to make room for.
    static let textOnlyLines = 9
    static let captionTop: CGFloat = 12
    static let captionToFooter: CGFloat = 8
    static let footerBottom: CGFloat = 11
    /// The link line that sits under the screenshot when a capture has one.
    static let linkFontSize: CGFloat = 10
    static let linkTop: CGFloat = 9
    static let linkToCaption: CGFloat = 6
    private static let metaFontSize: CGFloat = 10.5

    public static func estimatedHeight(
        imageAspectRatio: Double, note: String, hasSourceLink: Bool = false, textOnly: Bool = false
    ) -> CGFloat {
        // A typed note has no picture and no hairline under one, and room
        // for more of its words.
        let imageHeight =
            textOnly
            ? -1
            : min(CanvasModel.nodeWidth / CGFloat(max(imageAspectRatio, 0.05)), CanvasModel.maxImageHeight).rounded()
        let preview = NotePreview.text(for: note)
        let font = Theme.noteNSFont(size: captionFontSize)
        let lines = min(
            textOnly ? textOnlyLines : captionLines,
            lineCount(preview.isEmpty ? "No note" : preview, font: font, width: CanvasModel.nodeWidth - 2 * padding))
        let caption = CGFloat(lines) * lineHeight(font) + CGFloat(lines - 1) * captionLineSpacing
        let footer = lineHeight(Theme.monoNSFont(metaFontSize))
        // With a link, its line comes first and the gap above is a little tighter.
        let top =
            hasSourceLink
            ? linkTop + lineHeight(Theme.monoNSFont(linkFontSize)) + linkToCaption : captionTop
        // Screenshot, hairline, (link,) caption, footer, and the space round them.
        return (imageHeight + 1 + top + caption + captionToFooter + footer + footerBottom).rounded(.up)
    }

    /// SwiftUI gives each line of text a whole number of points.
    private static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender) + ceil(-font.descender) + ceil(font.leading)
    }

    /// How many lines text wraps onto at a width.
    private static func lineCount(_ string: String, font: NSFont, width: CGFloat) -> Int {
        let storage = NSTextStorage(string: string, attributes: [.font: font])
        // A shade narrower than the real column: if a word only just fits,
        // better to allow for the extra line than to come up short.
        let container = NSTextContainer(size: CGSize(width: max(20, width - 2), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        var lines = 0
        var glyph = 0
        let count = layout.numberOfGlyphs
        while glyph < count {
            var range = NSRange()
            layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
            glyph = max(NSMaxRange(range), glyph + 1)
            lines += 1
        }
        return max(lines, 1)
    }
}
