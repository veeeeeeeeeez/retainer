import SwiftUI

/// What an empty board says to do: hold the left Option key, drag over
/// something, and talk. Each of the three has a small tile in the sentence
/// in place of more words: the key itself, a crop for the capture, a
/// waveform for the voice.
///
/// The tiles are lit one after another, in the order the gesture goes, and
/// fade back in between. That is the only movement on an empty board, so it
/// is where the eye lands. They hold still when the Mac is set to reduce
/// motion.
struct Invitation: View {

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    /// How dim a tile is while it is another one's turn.
    static let resting = 0.38
    /// How long a tile takes to come up, and to go down again.
    static let pace = 0.95

    var body: some View {
        Group {
            if reduceMotion || rendersStill {
                line(lit: nil)
            } else {
                PhaseAnimator([0, 1, 2]) { step in
                    line(lit: step)
                } animation: { _ in
                    .easeInOut(duration: Self.pace)
                }
            }
        }
        .font(Theme.noteFont(size: 17))
        .foregroundStyle(Theme.textSecondary)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold Left Option, drag over anything on screen, and say what you think.")
    }

    /// The sentence, with one of its tiles lit, or all of them when nothing moves.
    private func line(lit: Int?) -> some View {
        HStack(alignment: .center, spacing: 0) {
            Text("Hold")
            tile(.symbol("option"), at: 0, lit: lit)
                .padding(.leading, 7)
                .padding(.trailing, 1)
            Text(", drag")
            tile(.crop, at: 1, lit: lit)
                .padding(.horizontal, 7)
            Text("over anything on screen, and say")
            tile(.symbol("waveform"), at: 2, lit: lit)
                .padding(.horizontal, 7)
            Text("what you think.")
        }
    }

    private func tile(_ sign: PromptTile.Sign, at place: Int, lit: Int?) -> some View {
        PromptTile(sign: sign)
            .opacity(lit == nil || lit == place ? 1 : Self.resting)
    }
}

/// A small flat tile with one sign on it, no taller than the line of text
/// it sits in: a key, or a stand-in for something to do.
struct PromptTile: View {

    /// What is on a tile.
    enum Sign {
        /// One of the system's symbols, by name.
        case symbol(String)
        /// Crop marks, drawn here (`CropMarks`).
        case crop
    }

    let sign: Sign

    private static let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)

    var body: some View {
        Group {
            switch sign {
            case .symbol(let name):
                Image(systemName: name)
                    .font(.system(size: 11, weight: .semibold))
            case .crop:
                // Lines as heavy as those of the symbols beside it.
                CropMarks(overhang: 2.25)
                    .stroke(style: StrokeStyle(lineWidth: 1.25, lineCap: .butt, lineJoin: .miter))
                    .frame(width: 12, height: 12)
            }
        }
        .foregroundStyle(Theme.text)
        .frame(width: 28, height: 22)
        .background(Theme.panelRaised, in: Self.shape)
        .overlay {
            Self.shape.strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
        }
        .accessibilityHidden(true)
    }
}

/// Crop marks: two right angles that cross to frame a square, the ends of
/// each sticking out a little past it.
///
/// The system has a symbol for this, but its square is half the width of
/// the whole, and at the size of a tile that reads as two separate corners.
/// Here the square is most of it and the ends are short, so the two angles
/// lock into one frame.
struct CropMarks: Shape {

    /// How far the ends stick out past the middle of the square's lines.
    var overhang: CGFloat

    func path(in rect: CGRect) -> Path {
        let left = rect.minX + overhang
        let right = rect.maxX - overhang
        let top = rect.minY + overhang
        let bottom = rect.maxY - overhang
        var path = Path()
        // Down the left of the square from above it, and along its bottom
        // to past the right.
        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom))
        // Along the top of the square from before it, and down its right to
        // past the bottom.
        path.move(to: CGPoint(x: rect.minX, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addLine(to: CGPoint(x: right, y: rect.maxY))
        return path
    }
}

private struct RendersStillKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the view is being drawn once, for a picture, not shown live.
    /// Anything that moves of its own accord holds still, so the picture
    /// does not catch it half way.
    var rendersStill: Bool {
        get { self[RendersStillKey.self] }
        set { self[RendersStillKey.self] = newValue }
    }
}
