import AppKit
import SwiftUI

/// The visual language, in one place: a flat warm-dark dashboard (or its
/// light counterpart), a near-monochrome palette, one accent, and the Mac's
/// own two typefaces: SF Mono for metadata and SF Pro for everything read as
/// prose.
///
/// Every colour has a dark and a light value and picks between them by the
/// appearance of the window it is drawn in. Switching the app between dark
/// and light therefore re-colours everything without any view having to ask
/// which it is. The capture overlay pins its windows to dark, so it always
/// gets the dark values.
///
/// The dark values were taken from a screenshot the palette was asked to
/// match: warm blacks stepping up from the background, warm off-white text,
/// and a sand accent. The light values are the same hues turned over.
public enum Theme {

    // MARK: Colour

    private static func adaptive(dark: UInt32, light: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? NSColor(hex: light) : NSColor(hex: dark)
        }
    }

    public static let nsBackground = adaptive(dark: 0x151110, light: 0xF6F4F1)
    public static let nsPanel = adaptive(dark: 0x1B1917, light: 0xFDFCFA)
    public static let nsPanelRaised = adaptive(dark: 0x201E1C, light: 0xEFECE8)
    public static let nsSelected = adaptive(dark: 0x272523, light: 0xE7E3DE)
    public static let nsHairline = adaptive(dark: 0x2C2826, light: 0xE4E0DB)
    public static let nsHairlineStrong = adaptive(dark: 0x373533, light: 0xCDC7C0)
    public static let nsText = adaptive(dark: 0xEAE8E6, light: 0x1B1917)
    public static let nsTextSecondary = adaptive(dark: 0xA5A09D, light: 0x5C5753)
    public static let nsTextMuted = adaptive(dark: 0x898582, light: 0x7D7772)
    public static let nsTextFaint = adaptive(dark: 0x5F5A57, light: 0xADA7A1)
    public static let nsAccent = adaptive(dark: 0xDDC1B1, light: 0xA8735A)
    /// Behind selected text in an editor.
    public static let nsSelection = adaptive(dark: 0x45413E, light: 0xDCD5CC)

    /// Window and canvas background.
    public static let background = Color(nsColor: nsBackground)
    /// Fill of node panels and the capture card's editor: a step off the background.
    public static let panel = Color(nsColor: nsPanel)
    /// A step above `panel`, for hover and pressed states.
    public static let panelRaised = Color(nsColor: nsPanelRaised)
    /// Behind the chosen row of a list.
    public static let selected = Color(nsColor: nsSelected)
    /// 1 px borders and rules.
    public static let hairline = Color(nsColor: nsHairline)
    /// Borders that need to read over arbitrary screen content.
    public static let hairlineStrong = Color(nsColor: nsHairlineStrong)

    /// Primary text.
    public static let text = Color(nsColor: nsText)
    /// Secondary text.
    public static let textSecondary = Color(nsColor: nsTextSecondary)
    /// Metadata, hints and placeholders.
    public static let textMuted = Color(nsColor: nsTextMuted)
    /// Disabled text and the canvas dot grid.
    public static let textFaint = Color(nsColor: nsTextFaint)

    /// The one accent. Used for the recording state and its waveform, and
    /// nowhere else. (The selection is glass, not colour: see `GlassPanel`.)
    public static let accent = Color(nsColor: nsAccent)

    /// Dim laid over the screen outside the selection rectangle.
    public static let selectionDim = 0.30
    /// Backdrop behind the lifted capture card.
    public static let cardBackdrop = 0.90

    // MARK: Metrics

    public static let radius: CGFloat = 6
    public static let radiusSmall: CGFloat = 4
    public static let hairlineWidth: CGFloat = 1

    public enum Space {
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
    }

    // MARK: Type

    // Two faces, both the Mac's own: SF Pro for anything read as prose (the
    // notes, the prompt, names in the left bar) and SF Mono for metadata,
    // labels, buttons and status. Nothing else is used anywhere.

    /// The note itself, and other prose: SF Pro.
    public static func noteFont(size: CGFloat = 16) -> Font {
        .system(size: size)
    }

    public static func noteNSFont(size: CGFloat = 16) -> NSFont {
        .systemFont(ofSize: size)
    }

    /// Extra space between lines of the note, proportional to its size.
    public static func noteLineSpacing(size: CGFloat = 16) -> CGFloat { (size * 0.36).rounded() }

    /// Metadata, labels, buttons and status. The same face as everything
    /// else, the system's own (SF Pro): the app has one typeface. (The name
    /// is from when these were set in SF Mono.)
    public static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    public static func monoNSFont(_ size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

// MARK: - Shared controls

/// A flat button with a mono label. `prominent` inverts it (off-white fill)
/// for the single primary action on a surface; nothing is ever coloured.
public struct FlatButtonStyle: ButtonStyle {
    public var prominent = false

    public init(prominent: Bool = false) {
        self.prominent = prominent
    }

    public func makeBody(configuration: Configuration) -> some View {
        FlatButtonBody(configuration: configuration, prominent: prominent)
    }

    private struct FlatButtonBody: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(background, in: RoundedRectangle(cornerRadius: Theme.radiusSmall))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .strokeBorder(prominent ? Color.clear : Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
                }
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }

        private var foreground: Color {
            prominent ? Theme.background : Theme.text
        }

        private var background: Color {
            if prominent {
                return configuration.isPressed ? Theme.textSecondary : Theme.text
            }
            if configuration.isPressed { return Theme.hairline }
            return hovering ? Theme.panelRaised : Color.clear
        }
    }
}

/// A text-only button for quiet secondary actions.
public struct QuietButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        QuietBody(configuration: configuration)
    }

    private struct QuietBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(Theme.mono(11))
                .foregroundStyle(hovering || configuration.isPressed ? Theme.text : Theme.textMuted)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
