import SwiftUI

/// How a board shows where its cards are when they are out of view, chosen
/// in the settings.
public enum MiniMapStyle: String, CaseIterable, Sendable {

    /// No map at all: the window is the map. Cards out of view light the
    /// window's own edges, on the side they lie.
    case edges
    /// A glass ball centred on where the window is looking. Cards within its
    /// range are drawn round the middle; cards beyond it light the rim, in
    /// their own colours, on the side they lie.
    case orb

    /// The word on the switch.
    public var title: String {
        switch self {
        case .edges: "edges"
        case .orb: "orb"
        }
    }
}

/// How points of the board fall on a mini map: one point of the board at the
/// middle of the circle, and so many map points to each board point.
struct MapProjection: Equatable {

    /// The point of the board at the middle of the map.
    var focus: CGPoint
    /// Map points per board point.
    var scale: CGFloat
    /// The middle of the circle, in the map view's own coordinates.
    var centre: CGPoint

    /// Where a point of the board is on the map.
    func point(_ board: CGPoint) -> CGPoint {
        CGPoint(
            x: centre.x + (board.x - focus.x) * scale,
            y: centre.y + (board.y - focus.y) * scale)
    }

    /// Where a rectangle of the board is on the map.
    func rect(_ board: CGRect) -> CGRect {
        let origin = point(board.origin)
        return CGRect(x: origin.x, y: origin.y, width: board.width * scale, height: board.height * scale)
    }

    /// The point of the board under a point of the map.
    func boardPoint(for map: CGPoint) -> CGPoint {
        CGPoint(
            x: focus.x + (map.x - centre.x) / scale,
            y: focus.y + (map.y - centre.y) / scale)
    }
}

/// A small round map of the board, floating on frosted glass in the top
/// right-hand corner.
///
/// A board has no edges, so it is possible to scroll away from everything
/// and not know which way it went. The map is there to say: an orb, centred
/// on the window's view, that shows the cards round it as a few blocks of
/// their screenshots' colours. It only sees so far. A card beyond that
/// lights the rim of the glass, in its own colour, on the side it lies.
///
/// Clicking or dragging on it moves the window there.
struct MiniMap: View {

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas
    @Environment(ImageCache.self) private var images

    /// What is known of each card's screenshot: a few pixels and a colour.
    @State private var swatches: [UUID: MapSwatch] = [:]
    /// The fit in use when a drag began, kept until it ends: the map must
    /// not move under the pointer while the pointer is steering by it.
    @State private var held: MapProjection?

    static let diameter: CGFloat = 132
    static let inset: CGFloat = 14
    /// Clear space between the map and the right-hand edge of the window.
    static let edgeSpace: CGFloat = 28

    /// One card of the board in front, and where it is on that board.
    typealias Card = (id: UUID, frame: CGRect)

    var body: some View {
        let notes = canvas.notes(in: store)
        let cards = cardFrames(of: notes)
        let viewport = canvas.visibleRect ?? CGRect(x: -590, y: -380, width: 1180, height: 760)
        let projection = held ?? fit(cards.map(\.frame), viewport: viewport)

        MapFace(projection: projection, cards: cards, viewport: viewport, swatches: swatches)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if held == nil { held = projection }
                        let target = (held ?? projection).boardPoint(for: value.location)
                        canvas.centre(on: CGRect(origin: target, size: .zero))
                    }
                    .onEnded { _ in
                        // The map settles round the new view rather than jumping to it.
                        withAnimation(.easeOut(duration: 0.26)) { held = nil }
                    }
            )
            .task(id: notes.map(\.id)) {
                await loadSwatches(for: notes)
            }
            .help("Where you are on this board. A lit edge is cards out that way. Click or drag to move.")
            .accessibilityLabel("Map of the board")
    }

    private func fit(_ frames: [CGRect], viewport: CGRect) -> MapProjection {
        OrbGeometry(frames: frames, viewport: viewport, diameter: Self.diameter, inset: Self.inset).projection
    }

    /// Where each card is drawn on the board in front: at its own place on a
    /// day's board, in its day's block on a wider one.
    private func cardFrames(of notes: [Note]) -> [Card] {
        if !canvas.showsDays {
            return notes.map { ($0.id, canvas.frame(of: $0)) }
        }
        let layout = canvas.layout(of: notes)
        return notes.compactMap { note in
            guard let origin = layout.positions[note.id] else { return nil }
            return (note.id, CGRect(origin: origin, size: canvas.frame(of: note).size))
        }
    }

    private func loadSwatches(for notes: [Note]) async {
        let wanted = Set(notes.map(\.id))
        var loaded = swatches.filter { wanted.contains($0.key) }
        var unshown = 0
        for note in notes where loaded[note.id] == nil {
            if let swatch = await images.swatch(id: note.id, url: store.imageURL(for: note)) {
                loaded[note.id] = swatch
                unshown += 1
            }
            if Task.isCancelled { return }
            // A board of hundreds takes a while: show what there is so far.
            if unshown >= 24 {
                swatches = loaded
                unshown = 0
            }
        }
        swatches = loaded
    }
}

/// The map itself: the glass and what is drawn on it, for one fit of the
/// board. The fit can be animated, so the map glides from one to the next.
private struct MapFace: View, Animatable {

    var projection: MapProjection
    let cards: [MiniMap.Card]
    let viewport: CGRect
    let swatches: [UUID: MapSwatch]

    @Environment(\.colorScheme) private var colorScheme

    // Not tied to the main actor: SwiftUI reads and writes this from wherever
    // it is working an animation out, and it only touches plain numbers.
    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get { AnimatablePair(AnimatablePair(projection.focus.x, projection.focus.y), projection.scale) }
        set {
            projection.focus = CGPoint(x: newValue.first.first, y: newValue.first.second)
            projection.scale = newValue.second
        }
    }

    /// How far past the glass the light on the orb's rim spills.
    private static let bloom: CGFloat = 14
    /// The light of a card whose screenshot has not been read yet.
    private static let unreadColour = RGBColour(red: 0.54, green: 0.52, blue: 0.51)

    var body: some View {
        let diameter = MiniMap.diameter
        let light = rimLight

        Canvas { context, size in
            drawOrb(in: &context, size: size, light: light)
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .floatingGlass(cornerRadius: diameter / 2, tint: 0.6)
        .overlay {
            // Light does not stop at the edge of the glass.
            if !light.isDark {
                Canvas { context, size in
                    drawBloom(light, in: &context, size: size)
                }
                .frame(width: diameter + 2 * Self.bloom, height: diameter + 2 * Self.bloom)
                .allowsHitTesting(false)
            }
        }
    }

    private var onDark: Bool { colorScheme == .dark }

    /// The part of the board in the window, on the map, never too small to see.
    private var frame: CGRect {
        var frame = projection.rect(viewport)
        if frame.width < 8 { frame = frame.insetBy(dx: (frame.width - 8) / 2, dy: 0) }
        if frame.height < 6 { frame = frame.insetBy(dx: 0, dy: (frame.height - 6) / 2) }
        return frame
    }

    // MARK: The cards and the view

    /// Every card as a few blocks of colour, never too small to see.
    private func drawCards(in context: inout GraphicsContext) {
        for card in cards {
            var rect = projection.rect(card.frame)
            if rect.width < 3 { rect = rect.insetBy(dx: (rect.width - 3) / 2, dy: 0) }
            if rect.height < 3 { rect = rect.insetBy(dx: 0, dy: (rect.height - 3) / 2) }
            if let swatch = swatches[card.id] {
                context.draw(Image(decorative: swatch.image, scale: 1).interpolation(.none), in: rect)
            } else {
                context.fill(Path(rect), with: .color(Theme.textMuted))
            }
        }
    }

    /// The part of the board in the window, as a frame.
    private func drawFrame(in context: inout GraphicsContext) {
        let outline = Path(roundedRect: frame, cornerRadius: 2)
        context.fill(outline, with: .color(Theme.text.opacity(0.10)))
        context.stroke(outline, with: .color(Theme.text), lineWidth: 1)
    }

    // MARK: The light

    /// The light every card that is out of the orb's range puts on its rim.
    private var rimLight: RimLight {
        let rim = MiniMap.diameter / 2
        return RimLight(
            sources: cards.map { card in
                RimLight.Source(
                    position: projection.point(CGPoint(x: card.frame.midX, y: card.frame.midY)),
                    colour: (swatches[card.id]?.colour ?? Self.unreadColour).asLight(onDark: onDark))
            },
            centre: projection.centre, radius: rim - MiniMap.inset, rim: rim)
    }

    /// The rim light as a paint that goes round `centre`: each sample's
    /// colour at its own angle, as strong as the sample is. Never quite
    /// opaque: it is light in glass, not a painted ring.
    private func shading(_ light: RimLight, centre: CGPoint) -> GraphicsContext.Shading {
        let count = light.samples.count
        let stops = (0...count).map { index in
            let sample = light.samples[index % count]
            return Gradient.Stop(
                color: Color(
                    .sRGB, red: sample.colour.red, green: sample.colour.green, blue: sample.colour.blue,
                    opacity: min(1, sample.strength) * 0.86),
                location: CGFloat(index) / CGFloat(count))
        }
        return .conicGradient(Gradient(stops: stops), center: centre, angle: .zero)
    }

    private func drawOrb(in context: inout GraphicsContext, size: CGSize, light: RimLight) {
        let rim = size.width / 2
        let centre = CGPoint(x: rim, y: rim)
        let disc = Path(ellipseIn: CGRect(origin: .zero, size: size))

        // The ball itself: darker towards the edge, where there is more
        // glass to look through. It has no highlight of its own. The only
        // light on the orb is the light of cards, so a bright patch on one
        // side would read as cards lying that way.
        context.fill(
            disc,
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0), location: 0.45),
                    .init(color: .black.opacity(onDark ? 0.12 : 0.03), location: 0.8),
                    .init(color: .black.opacity(onDark ? 0.34 : 0.09), location: 1),
                ]), center: centre, startRadius: 0, endRadius: rim))

        // The cards, melting into the glass as they near its edge.
        context.drawLayer { layer in
            layer.clipToLayer { mask in
                mask.fill(
                    disc,
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .white, location: (rim - MiniMap.inset - 2) / rim),
                            .init(color: .white.opacity(0), location: 1),
                        ]), center: centre, startRadius: 0, endRadius: rim))
            }
            drawCards(in: &layer)
        }

        drawFrame(in: &context)

        if !light.isDark {
            let paint = shading(light, centre: centre)
            // Light let into the glass: strongest at the edge, gone by half way in.
            context.drawLayer { layer in
                layer.clipToLayer { mask in
                    mask.fill(
                        disc,
                        with: .radialGradient(
                            Gradient(stops: [
                                .init(color: .white.opacity(0), location: 0.34),
                                .init(color: .white.opacity(0.07), location: 0.58),
                                .init(color: .white.opacity(0.24), location: 0.8),
                                .init(color: .white.opacity(0.62), location: 0.94),
                                .init(color: .white.opacity(0.95), location: 1),
                            ]), center: centre, startRadius: 0, endRadius: rim))
                }
                layer.fill(disc, with: paint)
            }
            // And the edge itself, lit.
            context.stroke(
                Path(ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75)), with: paint,
                lineWidth: 1.5)
        }
    }

    /// The rim light where it spills past the glass: a soft ring that is
    /// nothing inside the edge and fades out a little way beyond it.
    private func drawBloom(_ light: RimLight, in context: inout GraphicsContext, size: CGSize) {
        let outer = size.width / 2
        let rim = MiniMap.diameter / 2
        let centre = CGPoint(x: outer, y: outer)
        let whole = Path(ellipseIn: CGRect(origin: .zero, size: size))
        context.drawLayer { layer in
            layer.clipToLayer { mask in
                mask.fill(
                    whole,
                    with: .radialGradient(
                        Gradient(stops: [
                            .init(color: .white.opacity(0), location: (rim - 0.5) / outer),
                            .init(color: .white.opacity(onDark ? 0.42 : 0.36), location: rim / outer),
                            .init(color: .white.opacity(onDark ? 0.13 : 0.1), location: (rim + (outer - rim) * 0.45) / outer),
                            .init(color: .white.opacity(0), location: 1),
                        ]), center: centre, startRadius: 0, endRadius: outer))
            }
            layer.fill(whole, with: shading(light, centre: centre))
        }
    }
}
