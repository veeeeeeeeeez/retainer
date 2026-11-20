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

/// What is behind a view, blurred: the frosted part of a floating glass
/// panel.
///
/// This is AppKit's own backdrop blur. It is the one glass effect an app can
/// have without sampling the picture behind it itself, and it costs nothing
/// when nothing under it moves.
///
/// In the main window it frosts the board, which is in the same window. The
/// capture overlay is a clear window over the whole screen with nothing of
/// its own behind the glass, so there it frosts what is behind the window:
/// the screen itself.
private struct BackdropBlur: NSViewRepresentable {

    /// Frost what is behind the window, not what is behind the view in it.
    var behindWindow = false
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.state = .active
        view.isEmphasized = false
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSVisualEffectView) {
        view.blendingMode = behindWindow ? .behindWindow : .withinWindow
        // The window server draws this kind of blur itself and does not see
        // the shape SwiftUI clips the view to, so it is given the shape as
        // a mask: a rounded square that stretches from its middle.
        view.maskImage = behindWindow && cornerRadius > 0 ? Self.mask(cornerRadius: cornerRadius) : nil
    }

    private static func mask(cornerRadius: CGFloat) -> NSImage {
        let side = 2 * cornerRadius + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        return image
    }
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
    /// Frost the screen behind the window (the capture overlay) and not the
    /// window's own contents (the board).
    var behindWindow = false

    func body(content: Content) -> some View {
        var style = GlassStyle.floating
        style.cornerRadius = cornerRadius
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        return content
            .background {
                ZStack {
                    BackdropBlur(behindWindow: behindWindow, cornerRadius: cornerRadius)
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
    func floatingGlass(
        cornerRadius: CGFloat = GlassStyle.floating.cornerRadius, tint: Double = 0.72, behindWindow: Bool = false
    ) -> some View {
        modifier(FloatingGlass(cornerRadius: cornerRadius, tint: tint, behindWindow: behindWindow))
    }
}
