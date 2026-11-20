import SwiftUI

/// The window as its own map: a card that is out of view lights the edge of
/// the window it lies beyond, at the place along that edge where it is.
///
/// A card above the window lights the top edge, over where the card is; a
/// card off to the left lights the left edge, level with it. One beyond a
/// corner lights the two edges that meet there, close to the corner, each by
/// as much as the card lies that way. An edge with nothing beyond it stays
/// dark, and a card any part of which can be seen gives no light.
///
/// The light comes up as a card goes out of sight, then fades the further
/// off the card is without ever going out. It is as wide as the card and a
/// quarter as much again either side, and stops there: several cards in one
/// place are brighter than one, never wider.
struct EdgeGlow: View {

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas
    @Environment(ImageCache.self) private var images
    @Environment(\.colorScheme) private var colorScheme

    @State private var swatches: [UUID: MapSwatch] = [:]

    /// One side of the window. Samples along the top and bottom run left to
    /// right; along the left and right, top to bottom.
    enum Side: CaseIterable, Sendable {
        case top, right, bottom, left
    }

    /// How far in from the edge the light reaches: a quiet band, not a wash.
    private static let depth: CGFloat = 54
    /// The light at its very brightest, at the edge itself, however many
    /// cards lie that way. One card close by is three quarters of it. On a
    /// light board it is a stain, not a glow, and a stain has to be laid on
    /// much more heavily to be seen as well.
    private static func ceiling(onDark: Bool) -> Double { onDark ? 0.34 : 0.62 }
    /// One sample of light for about every this many points of an edge.
    private static let pitch: CGFloat = 10
    private static let unread = RGBColour(red: 0.54, green: 0.52, blue: 0.51)

    var body: some View {
        let notes = canvas.notes(in: store)
        let onDark = colorScheme == .dark
        let drawn = canvas.drawnFrames(
            of: notes, layout: canvas.showsDays ? canvas.layout(of: notes) : nil, groups: canvas.groups(in: store))
        let cards = drawn.map { card in
            (frame: card.frame, colour: (swatches[card.id]?.colour ?? Self.unread).asLight(onDark: onDark))
        }
        let viewport = canvas.visibleRect

        Canvas { context, size in
            let light = Self.light(
                cards: cards, viewport: viewport,
                samples: (Self.samples(along: size.width), Self.samples(along: size.height)))
            guard let light else { return }
            draw(light, in: &context, size: size, onDark: onDark)
        }
        .allowsHitTesting(false)
        .task(id: notes.map(\.id)) {
            let wanted = Set(notes.map(\.id))
            if swatches.keys.contains(where: { !wanted.contains($0) }) {
                swatches = swatches.filter { wanted.contains($0.key) }
            }
            // A card whose colour is not known yet gives a plain light. The
            // colours come in a few at a time, not all at once at the end.
            var arrived: [UUID: MapSwatch] = [:]
            for note in notes where swatches[note.id] == nil {
                if let swatch = await images.swatch(id: note.id, url: store.imageURL(for: note)) {
                    arrived[note.id] = swatch
                }
                if Task.isCancelled { return }
                if arrived.count >= 8 {
                    swatches.merge(arrived) { _, new in new }
                    arrived = [:]
                }
            }
            if !arrived.isEmpty { swatches.merge(arrived) { _, new in new } }
        }
        .accessibilityHidden(true)
    }

    /// How many samples of light an edge this long is drawn with.
    private static func samples(along length: CGFloat) -> Int {
        max(24, min(400, Int(length / pitch) + 1))
    }

    /// The light along each side of the view, `samples.across` of it along
    /// the top and the bottom and `samples.down` along the left and right.
    /// `nil` with no view; a side with nothing beyond it is unlit.
    ///
    /// A card lights a side only if all of it is beyond that side, and
    /// lights it where the card is: its middle brought straight in to the
    /// edge, a little wider than the card and no more. A card beyond a
    /// corner is beyond two sides, and its light is shared between them by
    /// how far beyond each it is, so one far above and only just to the left
    /// is a light on the top.
    nonisolated static func light(
        cards: [(frame: CGRect, colour: RGBColour)], viewport: CGRect?,
        samples: (across: Int, down: Int) = (64, 64)
    ) -> [Side: [RimLight.Sample]]? {
        guard let viewport, viewport.width > 0, viewport.height > 0 else { return nil }
        let reach = hypot(viewport.width, viewport.height) / 2
        var top = [Sum](repeating: Sum(), count: max(samples.across, 2))
        var bottom = top
        var left = [Sum](repeating: Sum(), count: max(samples.down, 2))
        var right = left

        for card in cards {
            let frame = card.frame
            // How far the card is beyond the view each way. Not beyond it
            // either way: some of the card can be seen.
            let leftward = viewport.minX - frame.maxX
            let rightward = frame.minX - viewport.maxX
            let upward = viewport.minY - frame.maxY
            let downward = frame.minY - viewport.maxY
            let gap = CGSize(width: max(leftward, rightward, 0), height: max(upward, downward, 0))
            let distance = hypot(gap.width, gap.height)
            guard distance > 0 else { continue }

            // Comes up as the card leaves, over a quarter of its own size,
            // so that nothing appears all at once. Then fainter the further
            // off it is, but never gone.
            let rise = Double(min(1, distance / (0.25 * min(frame.width, frame.height))))
            let power = rise * rise * (3 - 2 * rise) * (0.45 + 0.55 / Double(1 + distance / (0.6 * reach)))
            let colour = (pow(card.colour.red, 2.2), pow(card.colour.green, 2.2), pow(card.colour.blue, 2.2))

            if gap.height > 0 {
                let across = (frame.midX - viewport.minX) / viewport.width
                let wide = frame.width * spread / viewport.width
                let share = power * Double(gap.height / distance)
                if upward > 0 {
                    add(to: &top, weight: share, at: across, spread: wide, colour: colour)
                } else {
                    add(to: &bottom, weight: share, at: across, spread: wide, colour: colour)
                }
            }
            if gap.width > 0 {
                let down = (frame.midY - viewport.minY) / viewport.height
                let tall = frame.height * spread / viewport.height
                let share = power * Double(gap.width / distance)
                if leftward > 0 {
                    add(to: &left, weight: share, at: down, spread: tall, colour: colour)
                } else {
                    add(to: &right, weight: share, at: down, spread: tall, colour: colour)
                }
            }
        }
        return [.top: top.map(\.sample), .bottom: bottom.map(\.sample), .left: left.map(\.sample), .right: right.map(\.sample)]
    }

    /// How far either side of a card's middle its light reaches along the
    /// edge, as a share of the card's own width: a quarter of the card past
    /// each of its ends, and nothing beyond that.
    private nonisolated static let spread: CGFloat = 0.75

    /// The light gathered at one place along an edge, in linear light.
    private struct Sum {
        var weight = 0.0
        var red = 0.0
        var green = 0.0
        var blue = 0.0

        var sample: RimLight.Sample {
            guard weight > 0 else {
                return RimLight.Sample(colour: RGBColour(red: 1, green: 1, blue: 1), strength: 0)
            }
            return RimLight.Sample(
                colour: RGBColour(
                    red: pow(red / weight, 1 / 2.2), green: pow(green / weight, 1 / 2.2), blue: pow(blue / weight, 1 / 2.2)),
                strength: 1 - exp(-1.4 * weight))
        }
    }

    /// Adds one card's light to an edge: brightest at `place` (0 at one end
    /// of the edge, 1 at the other; a card past the end lights the end),
    /// falling away smoothly to nothing `spread` either side of it. Light
    /// that ends, rather than tailing off for ever, cannot be made wider by
    /// more cards in the same place.
    private nonisolated static func add(
        to row: inout [Sum], weight: Double, at place: CGFloat, spread: CGFloat,
        colour: (red: Double, green: Double, blue: Double)
    ) {
        guard weight > 0.0005 else { return }
        let last = Double(row.count - 1)
        let centre = Double(min(max(place, 0), 1)) * last
        // Never narrower than the samples can draw without flickering.
        let reach = min(max(Double(spread) * last, 3), 1e6)
        let lower = max(0, Int((centre - reach).rounded(.up)))
        let upper = min(row.count - 1, Int((centre + reach).rounded(.down)))
        guard lower <= upper else { return }
        for index in lower...upper {
            let apart = (Double(index) - centre) / reach
            let fall = 1 - apart * apart
            guard fall > 0 else { continue }
            let share = weight * fall * fall
            row[index].weight += share
            row[index].red += share * colour.red
            row[index].green += share * colour.green
            row[index].blue += share * colour.blue
        }
    }

    private func draw(
        _ light: [Side: [RimLight.Sample]], in context: inout GraphicsContext, size: CGSize, onDark: Bool
    ) {
        let depth = min(Self.depth, min(size.width, size.height) / 4)
        let ceiling = Self.ceiling(onDark: onDark)
        // Each side: where it starts and ends in the order its samples run, and which way is in.
        let sides: [(Side, CGPoint, CGPoint, CGVector)] = [
            (.top, CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0), CGVector(dx: 0, dy: 1)),
            (.bottom, CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height), CGVector(dx: 0, dy: -1)),
            (.left, CGPoint(x: 0, y: 0), CGPoint(x: 0, y: size.height), CGVector(dx: 1, dy: 0)),
            (.right, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGVector(dx: -1, dy: 0)),
        ]
        for (side, start, end, inward) in sides {
            // Only the stretch of the edge that is lit is drawn.
            guard let samples = light[side], samples.count > 1,
                let first = samples.firstIndex(where: { $0.strength > 0.004 }),
                let final = samples.lastIndex(where: { $0.strength > 0.004 })
            else { continue }
            let lower = max(first - 1, 0)
            let upper = min(final + 1, samples.count - 1)
            guard upper > lower else { continue }
            func point(_ index: Int) -> CGPoint {
                let along = CGFloat(index) / CGFloat(samples.count - 1)
                return CGPoint(x: start.x + (end.x - start.x) * along, y: start.y + (end.y - start.y) * along)
            }
            let from = point(lower)
            let to = point(upper)
            let stops = (lower...upper).map { index in
                let sample = samples[index]
                return Gradient.Stop(
                    color: Color(
                        .sRGB, red: sample.colour.red, green: sample.colour.green, blue: sample.colour.blue,
                        opacity: min(1, sample.strength) * ceiling),
                    location: CGFloat(index - lower) / CGFloat(upper - lower))
            }
            let along = GraphicsContext.Shading.linearGradient(Gradient(stops: stops), startPoint: from, endPoint: to)
            let inner = CGPoint(x: from.x + inward.dx * depth, y: from.y + inward.dy * depth)
            let strip = CGRect(
                x: min(from.x, to.x, inner.x), y: min(from.y, to.y, inner.y),
                width: abs(to.x - from.x) + abs(inward.dx) * depth, height: abs(to.y - from.y) + abs(inward.dy) * depth)
            // Brightest at the very edge, fading smoothly inwards: no line.
            context.drawLayer { layer in
                layer.clipToLayer { mask in
                    mask.fill(
                        Path(strip),
                        with: .linearGradient(
                            Gradient(stops: [
                                .init(color: .white, location: 0), .init(color: .white.opacity(0.42), location: 0.22),
                                .init(color: .white.opacity(0.12), location: 0.55), .init(color: .white.opacity(0), location: 1),
                            ]), startPoint: from, endPoint: inner))
                }
                layer.fill(Path(strip), with: along)
            }
        }
    }
}
