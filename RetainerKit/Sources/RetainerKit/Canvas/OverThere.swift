import SwiftUI

/// Which way the cards of a board are when none of them is in view.
enum Whereabouts {

    /// Directions further apart than this, with nothing between them, are
    /// pointed at separately.
    private static let apart = Double.pi / 6

    /// The ways to the cards when every one of them is out of view: angles
    /// on screen, 0 to the right and a quarter turn (π/2) downwards, the way
    /// with most to be found first, `most` of them at the most. Empty when
    /// any part of any card can be seen, and when there are no cards.
    ///
    /// Cards that lie the same way are one direction, however many they are
    /// and however widely they are spread, so long as there is no gap among
    /// them: the way to the middle of them, leaning towards the nearer ones.
    /// Cards with a gap between them (some off to the left, some to the
    /// right) are a direction each.
    static func directions(to cards: [CGRect], from viewport: CGRect?, most: Int = 3) -> [Double] {
        guard let viewport, viewport.width > 0, viewport.height > 0, !cards.isEmpty, most > 0 else { return [] }
        let centre = CGPoint(x: viewport.midX, y: viewport.midY)
        let reach = hypot(viewport.width, viewport.height) / 2

        var ways: [(angle: Double, weight: Double, distance: Double)] = []
        ways.reserveCapacity(cards.count)
        for frame in cards {
            let across = max(viewport.minX - frame.maxX, frame.minX - viewport.maxX, 0)
            let down = max(viewport.minY - frame.maxY, frame.minY - viewport.maxY, 0)
            let distance = Double(hypot(across, down))
            // Not beyond the view either way: some of this card can be seen.
            guard distance > 0 else { return [] }
            // Towards the nearest part of the card from the middle of the view.
            let nearest = CGPoint(
                x: min(max(centre.x, frame.minX), frame.maxX), y: min(max(centre.y, frame.minY), frame.maxY))
            let angle = Double(atan2(nearest.y - centre.y, nearest.x - centre.x))
            ways.append((angle, 1 / (1 + distance / Double(reach)), distance))
        }
        ways.sort { $0.angle < $1.angle }

        // Start just after the widest gap round the circle, so that no group
        // is cut in two where the angles wrap. No gap wide enough anywhere:
        // the cards are all one group.
        var widest = (gap: ways[0].angle + 2 * .pi - ways[ways.count - 1].angle, start: 0)
        for index in 1..<max(ways.count, 1) where ways[index].angle - ways[index - 1].angle > widest.gap {
            widest = (ways[index].angle - ways[index - 1].angle, index)
        }
        let ordered = Array(ways[widest.start...] + ways[..<widest.start])

        var groups: [[(angle: Double, weight: Double, distance: Double)]] = [[]]
        for (index, way) in ordered.enumerated() {
            if index > 0 {
                var step = way.angle - ordered[index - 1].angle
                if step < 0 { step += 2 * .pi }
                if step > apart { groups.append([]) }
            }
            groups[groups.count - 1].append(way)
        }

        let found = groups.map { group -> (angle: Double, weight: Double) in
            let weight = group.reduce(0) { $0 + $1.weight }
            let x = group.reduce(0) { $0 + $1.weight * cos($1.angle) }
            let y = group.reduce(0) { $0 + $1.weight * sin($1.angle) }
            // Cards nearly all the way round have no middle to point at:
            // the nearest of them, then.
            if hypot(x, y) < 0.35 * weight, let nearest = group.min(by: { $0.distance < $1.distance }) {
                return (nearest.angle, weight)
            }
            return (atan2(y, x), weight)
        }
        return found.sorted { $0.weight > $1.weight }.prefix(most).map(\.angle)
    }

    /// A direction in a word or two, for VoiceOver.
    static func name(of angle: Double) -> String {
        let names = ["to the right", "below and to the right", "below", "below and to the left", "to the left",
            "above and to the left", "above", "above and to the right"]
        let eighth = Int((angle / (.pi / 4)).rounded())
        return names[((eighth % 8) + 8) % 8]
    }
}

/// What a board says when every card on it has been scrolled out of view:
/// that they are somewhere, a thin chevron on the side they are, pointing
/// that way (one for each way there are cards), and under the words a link
/// that brings them back.
///
/// It is words in the middle of an empty view, like the prompt on an empty
/// board, and like it the only thing that moves: the chevrons come and go as
/// that prompt's tiles do. It fades in a moment after the last card has
/// gone, so that passing over a gap between cards does not flash it, and
/// goes quickly when one comes back.
struct OverThere: View {

    /// The ways to the cards (`Whereabouts.directions`). Empty when there is
    /// a card in view, and nothing is said.
    let directions: [Double]
    /// What the link under the words does.
    var onRecenter: () -> Void = {}

    var body: some View {
        let lost = !directions.isEmpty
        ZStack {
            if lost {
                // Put in afresh each time, so the chevrons arrive where they
                // belong; taken out, it fades as it last was.
                Words(directions: directions, onRecenter: onRecenter)
                    .transition(.opacity)
            }
        }
        .animation(lost ? .easeOut(duration: 0.5).delay(0.15) : .easeOut(duration: 0.18), value: lost)
    }

    /// The sentence and the link under it, with the chevrons round both.
    ///
    /// The chevrons come and go as the tiles of the empty board's prompt do,
    /// at the same pace and to the same dimness: one is lit, then the next,
    /// each fading back as the following one comes up. One on its own comes
    /// up and fades back by turns.
    private struct Words: View {

        let directions: [Double]
        var onRecenter: () -> Void

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.rendersStill) private var rendersStill

        /// Steps enough for one, two or three chevrons to take turns evenly.
        private static let steps = Array(0..<6)

        var body: some View {
            VStack(spacing: 5) {
                // Only the link takes clicks: the board can still be dragged
                // by the words.
                Text("Stuff's over there.")
                    .font(Theme.noteFont(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .allowsHitTesting(false)
                    .accessibilityLabel(
                        "No cards in view. They are "
                            + directions.map(Whereabouts.name(of:)).joined(separator: ", and ") + ".")
                Button("recenter", action: onRecenter)
                    .buttonStyle(LinkStyle())
                    .help("Bring the cards back into view")
                    .accessibilityLabel("Recenter")
            }
            .fixedSize()
            .background {
                GeometryReader { geometry in
                    if reduceMotion || rendersStill {
                        chevrons(lit: nil, round: geometry.size)
                    } else {
                        // Only the chevrons are inside what moves, so that
                        // nothing else is slowed to their pace.
                        PhaseAnimator(Self.steps) { step in
                            chevrons(lit: step % max(directions.count, 2), round: geometry.size)
                        } animation: { _ in
                            .easeInOut(duration: Invitation.pace)
                        }
                    }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }

        /// The chevrons, with one of them lit, or all of them when nothing
        /// moves.
        private func chevrons(lit: Int?, round block: CGSize) -> some View {
            ZStack {
                ForEach(Array(directions.enumerated()), id: \.offset) { place, angle in
                    chevron(angle, round: block)
                        // Where a chevron is follows the board at once. Only
                        // how bright it is takes its time.
                        .animation(nil, value: angle)
                        .opacity(lit == nil || lit == place ? 1 : Invitation.resting)
                }
            }
            .frame(width: block.width, height: block.height)
        }

        /// How far outside the words and link a chevron stands, whichever
        /// way it points.
        private static let clearance = 38.0

        /// A chevron on the way out from the middle of the words and link in
        /// one direction, well clear of them, pointing along it.
        private func chevron(_ angle: Double, round block: CGSize) -> some View {
            // Out along this direction to where the line leaves the words
            // and link, and then the same distance beyond that every time:
            // as far from their corners as from their sides.
            let edge = min(
                Double(block.width / 2) / max(abs(cos(angle)), 1e-6),
                Double(block.height / 2) / max(abs(sin(angle)), 1e-6))
            let out = edge + Self.clearance
            return Chevron()
                .stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                .frame(width: 6.5, height: 12)
                .rotationEffect(.radians(angle))
                .foregroundStyle(Theme.text)
                .position(x: block.width / 2 + cos(angle) * out, y: block.height / 2 + sin(angle) * out)
        }
    }

    /// A link in a line of its own: small, underlined, brighter under the
    /// pointer.
    private struct LinkStyle: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            Label(configuration: configuration)
        }

        private struct Label: View {
            let configuration: Configuration
            @State private var hovering = false

            var body: some View {
                configuration.label
                    .font(Theme.noteFont(size: 13))
                    .underline()
                    .foregroundStyle(hovering || configuration.isPressed ? Theme.text : Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onHover { hovering = $0 }
            }
        }
    }
}

/// A chevron pointing to the right: two short lines meeting at a point.
private struct Chevron: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return path
    }
}
