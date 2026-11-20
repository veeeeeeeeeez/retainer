import AppKit
import SwiftUI

extension GlassStyle {
    /// The glass of the panels that float over the board (the timeline, the
    /// input box): the LiquidGlass library's own defaults for edge light and
    /// shadow rather than the hard-edged look dialled in for the selection.
    /// A gentle rim, strongest along the top, and a short soft shadow.
    static let floating = GlassStyle(
        cornerRadius: 14, edgeHighlight: 0.45, opacity: 1, zRadius: 40, shadowOpacity: 0.4, shadowSpread: 10,
        shadowOffsetY: 2, maximumGlowReach: 10, overlayGain: 1.0)
}

/// What is behind a view in the same window, blurred: the frosted part of a
/// floating glass panel.
///
/// This is AppKit's own backdrop blur. It is the one glass effect an app can
/// have without sampling the picture behind it itself, and it costs nothing
/// when nothing under it moves.
private struct BackdropBlur: NSViewRepresentable {

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.material = .hudWindow
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Puts a view on a pane of frosted glass: the board behind shows through
/// blurred and tinted, the edge catches the light as the LiquidGlass shader
/// draws it, and a soft shadow lifts it off the board.
///
/// The library also bends the picture behind its glass. That needs a shader
/// run over the window's own contents, which this build cannot compile, so
/// here the blur stands in for it. On glass this small the difference is in
/// the last few points at the edge.
struct FloatingGlass: ViewModifier {

    var cornerRadius: CGFloat = GlassStyle.floating.cornerRadius
    /// How much of the panel colour is laid over the blur. Enough that text
    /// on the glass stays readable when a white screenshot passes behind it.
    var tint: Double = 0.72

    func body(content: Content) -> some View {
        var style = GlassStyle.floating
        style.cornerRadius = cornerRadius
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return content
            .background {
                ZStack {
                    BackdropBlur()
                    Theme.panel.opacity(tint)
                }
                .clipShape(shape)
            }
            .overlay {
                shape.strokeBorder(Theme.hairlineStrong.opacity(0.7), lineWidth: Theme.hairlineWidth)
            }
            .overlay {
                // The lit edge and the shadow, from the shader's curves.
                GeometryReader { geometry in
                    GlassPanel(rect: CGRect(origin: .zero, size: geometry.size), style: style)
                }
                .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Floats the view on a pane of frosted glass.
    func floatingGlass(cornerRadius: CGFloat = GlassStyle.floating.cornerRadius, tint: Double = 0.72) -> some View {
        modifier(FloatingGlass(cornerRadius: cornerRadius, tint: tint))
    }
}
