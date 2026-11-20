import SwiftUI

/// The glass look, as numbers.
///
/// These are the settings dialled in on the LiquidGlass playground
/// (https://liquid-glass.ybouane.com, `@ybouane/liquidglass`). The property
/// names follow the playground's sliders, and the curves below follow that
/// library's fragment shader, and the way its canvas is laid over the page,
/// for everything these settings switch on: the edge highlight, the corner
/// radius, the opacity, the bevel depth and the drop shadow.
///
/// The playground's other sliders were left at zero (blur, refraction,
/// distortion, specular, fresnel, saturation, brightness) or at a value too
/// small to see (chromatic aberration 0.005, under a fifth of a pixel). Those
/// bend or resample the picture behind the glass, which an overlay window
/// cannot do without recording the screen continuously, so they are not
/// implemented. With these settings nothing visible is lost: the middle of
/// the panel shows what is behind it untouched.
///
/// `GlassPanelTests` holds these curves to brightness measurements taken
/// from a screenshot of the playground at these settings.
struct GlassStyle: Equatable, Sendable {
    /// "Corner Radius", in points.
    var cornerRadius: CGFloat = 7
    /// "Edge Highlight", 0…1: the bright stroke just inside the edge and the
    /// glow that falls away from it.
    var edgeHighlight: Double = 1
    /// "Opacity", 0…1. Below 1 the glass dims what is behind it a little,
    /// most at the edge, and caps how white the stroke can get.
    var opacity: Double = 0.94
    /// "Z-Radius", in points: how far in from the edge the glass goes on
    /// thinning out. Past this depth the picture behind is left alone.
    var zRadius: CGFloat = 54
    /// "Shadow Opacity", 0…1. The library's shadow comes out at the square
    /// of this on the page (0.5 gives a quarter black at the edge); so does
    /// this one.
    var shadowOpacity: Double = 0.5
    /// "Shadow Spread", in points.
    var shadowSpread: CGFloat = 20
    /// The library's default downward shadow offset, in points.
    var shadowOffsetY: CGFloat = 1

    /// The shader lets the glow reach 35% of the way to the middle of the
    /// panel. On a selection that fills a display that is a wide haze, so
    /// the reach is capped at what the playground's own sample panel shows.
    var maximumGlowReach: CGFloat = 16

    /// The shader adds light to the picture behind it. An overlay window can
    /// only lay white over it, which is weaker the brighter the picture is.
    /// This factor makes up the difference: 1.0 matches the shader over
    /// black, 1.45 over a mid-toned photograph, and 1.3 sits between.
    var overlayGain: Double = 1.3

    static let capture = GlassStyle()
}

// MARK: - The shader's curves

extension GlassStyle {

    /// GLSL `smoothstep(0, 1, t)`.
    static func smooth(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    /// How far in from the edge the glow reaches on a panel of this size.
    func glowReach(for size: CGSize) -> CGFloat {
        max(1, min(min(size.width, size.height) / 2 * 0.35, maximumGlowReach))
    }

    /// How far beyond the panel the shadow is drawn, in whole points. (The
    /// library stops 20 px out, where there is next to nothing left of it.)
    var shadowReach: CGFloat { (shadowSpread * 1.25).rounded(.up) }

    /// How much glass there is `distance` points in from the edge: the
    /// shader's anti-aliasing of the edge, times "Opacity".
    func coverage(at distance: CGFloat) -> Double {
        guard distance >= 0 else { return 0 }
        return opacity * Double(1 - Self.smooth((1.5 - distance) / 2))
    }

    /// The light the shader adds `distance` points in from the edge:
    ///
    ///     rim     0.22 at the edge, easing to nothing at the glow's reach
    ///     glow    0.15 at the edge, gone five points in
    ///     stroke  a band one to two and a half points in, 0.55 strong
    ///
    /// `even` is the rim and glow, the same all the way round. `stroke` is
    /// the band level with the top of the panel; it falls linearly to 40% of
    /// that level with the bottom.
    func light(at distance: CGFloat, glowReach: CGFloat) -> (even: Double, stroke: Double) {
        guard distance >= 0 else { return (0, 0) }
        let rim = 0.22 * Self.smooth(1 - distance / max(glowReach, 0.001))
        let glow = 0.15 * Self.smooth(1 - distance / 5)
        let band = Self.smooth(2.5 - distance) * (1 - Self.smooth(1 - distance))
        return (Double(rim + glow) * edgeHighlight, Double(0.55 * band) * edgeHighlight)
    }

    /// The white laid over the picture at a point `distance` in from the
    /// edge. `bias` is 1 level with the top of the panel and 0 level with
    /// the bottom.
    ///
    /// The library draws with straight alpha into a canvas the browser then
    /// reads as straight alpha again, so its glass lands on the page at the
    /// cube of its coverage. That is why the stroke stops at 83% white.
    func highlightOpacity(at distance: CGFloat, bias: Double, glowReach: CGFloat) -> Double {
        let amount = light(at: distance, glowReach: glowReach)
        let cover = coverage(at: distance)
        return cover * cover * cover * min(1, overlayGain * (amount.even + amount.stroke * (0.4 + 0.6 * bias)))
    }

    /// The black laid over the picture `distance` points in from the edge.
    /// For the same reason as above, glass at less than full opacity lets
    /// through a little less of the picture than it should: 5% less at the
    /// edge with "Opacity" at 0.94. The shader brightens the picture by up
    /// to 6% as the glass thins out over "Z-Radius", which cancels that in
    /// the middle. What is left is a faint darkening towards the edge.
    func veil(at distance: CGFloat) -> Double {
        let cover = coverage(at: distance)
        let depth = Double(Self.smooth(distance / max(zRadius, 0.001)))
        return max(0, cover * cover * (1 - cover * (1 + 0.06 * depth)))
    }

    /// The black laid under the panel `distance` points out from the edge of
    /// its shadow: the shader's wide Gaussian plus a tighter contact shadow,
    /// squared as the library's canvas squares it.
    func shadow(at distance: CGFloat) -> Double {
        let reach = shadowReach
        guard shadowOpacity > 0, distance < reach else { return 0 }
        let spread = max(shadowSpread, 1)
        let d = max(distance - 1, 0)
        let wide = exp(-d * d / (spread * spread)) * 0.65
        let contact = exp(-d * 0.08 / max(spread * 0.04, 0.01)) * 0.35
        let alpha = Double(wide + contact) * shadowOpacity
        // Ease the last part to nothing, so the shadow has no outer edge of its own.
        let tail = Double(1 - Self.smooth((distance - reach * 0.6) / (reach * 0.4)))
        return alpha * alpha * tail
    }
}

// MARK: - The panel

/// A panel of clear glass over a rectangle: untouched in the middle, with a
/// bright stroke just inside the edge that is strongest along the top, a soft
/// glow falling away from it, and a drop shadow underneath.
///
/// It marks the selection while it is dragged and stays on the screenshot
/// when it lifts. It is drawn in this app's overlay window, which is left out
/// of the capture, so none of it ends up in the saved image.
///
/// There are no blur or shadow filters. The inside is drawn as concentric
/// hairlines, one per screen pixel near the edge, each taking its colour from
/// the shader's curves at that depth, just as the shader samples once per
/// pixel; the shadow is eight gradients. Redrawing on every mouse movement
/// costs about the same whatever the size of the selection.
struct GlassPanel: View {

    /// The rectangle the glass covers, in the parent's coordinates.
    let rect: CGRect
    var style: GlassStyle = .capture

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let scale = max(displayScale, 1)
        // On whole pixels, so every hairline lands on exactly one row of them.
        let panel = Self.snapped(rect, scale: scale)
        let margin = style.shadowReach + abs(style.shadowOffsetY).rounded(.up)
        Canvas { context, size in
            let local = CGRect(
                x: margin, y: margin,
                width: max(0, size.width - 2 * margin), height: max(0, size.height - 2 * margin))
            Self.drawShadow(in: context, around: local, canvas: size, style: style, pixel: 1 / scale)
            Self.drawGlass(in: context, inside: local, style: style, pixel: 1 / scale)
        }
        .frame(width: panel.width + 2 * margin, height: panel.height + 2 * margin)
        .position(x: panel.midX, y: panel.midY)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func snapped(_ rect: CGRect, scale: CGFloat) -> CGRect {
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let minX = snap(rect.minX)
        let minY = snap(rect.minY)
        return CGRect(
            x: minX, y: minY,
            width: max(0, snap(rect.maxX) - minX), height: max(0, snap(rect.maxY) - minY))
    }

    private static func roundedPath(_ rect: CGRect, radius: CGFloat) -> Path {
        let limit = max(0, min(radius, min(rect.width, rect.height) / 2))
        return Path(roundedRect: rect, cornerRadius: limit, style: .circular)
    }

    // MARK: Shadow

    /// The shadow of the panel moved down by the offset, drawn only outside
    /// the panel: a strip of linear gradient along each side and a quarter
    /// of a radial gradient round each corner.
    private static func drawShadow(
        in context: GraphicsContext, around panel: CGRect, canvas: CGSize, style: GlassStyle, pixel: CGFloat
    ) {
        guard style.shadowOpacity > 0, panel.width > 0, panel.height > 0 else { return }
        let radius = min(style.cornerRadius, min(panel.width, panel.height) / 2)
        let reach = style.shadowReach
        let cast = panel.offsetBy(dx: 0, dy: style.shadowOffsetY)

        let steps = 32
        let falloff = Gradient(
            stops: (0...steps).map { step in
                let position = CGFloat(step) / CGFloat(steps)
                return Gradient.Stop(
                    color: .black.opacity(style.shadow(at: position * reach)), location: position)
            })

        // The glass itself stays clear: nothing is drawn under the panel.
        var outside = context
        var hole = Path(CGRect(origin: .zero, size: canvas))
        hole.addPath(roundedPath(panel, radius: radius))
        outside.clip(to: hole, style: FillStyle(eoFill: true))

        // The pieces meet on whole pixels, so there is no seam between them.
        // Each gradient starts at the edge of the shadow's shape and holds its
        // first colour before that, which fills the sliver the offset opens
        // up between the panel and its shadow.
        func snap(_ value: CGFloat) -> CGFloat { (value / pixel).rounded() * pixel }
        let x0 = cast.minX - reach
        let x1 = snap(cast.minX + radius)
        let x2 = max(x1, snap(cast.maxX - radius))
        let x3 = cast.maxX + reach
        let y0 = cast.minY - reach
        let y1 = snap(cast.minY + radius)
        let y2 = max(y1, snap(cast.maxY - radius))
        let y3 = cast.maxY + reach

        func strip(_ rect: CGRect, from start: CGPoint, to end: CGPoint) {
            guard rect.width > 0, rect.height > 0 else { return }
            outside.fill(Path(rect), with: .linearGradient(falloff, startPoint: start, endPoint: end))
        }
        strip(
            CGRect(x: x1, y: y0, width: x2 - x1, height: y1 - y0),
            from: CGPoint(x: x1, y: cast.minY), to: CGPoint(x: x1, y: y0))
        strip(
            CGRect(x: x1, y: y2, width: x2 - x1, height: y3 - y2),
            from: CGPoint(x: x1, y: cast.maxY), to: CGPoint(x: x1, y: y3))
        strip(
            CGRect(x: x0, y: y1, width: x1 - x0, height: y2 - y1),
            from: CGPoint(x: cast.minX, y: y1), to: CGPoint(x: x0, y: y1))
        strip(
            CGRect(x: x2, y: y1, width: x3 - x2, height: y2 - y1),
            from: CGPoint(x: cast.maxX, y: y1), to: CGPoint(x: x3, y: y1))

        func corner(_ rect: CGRect, centre: CGPoint) {
            guard rect.width > 0, rect.height > 0 else { return }
            outside.fill(
                Path(rect),
                with: .radialGradient(falloff, center: centre, startRadius: radius, endRadius: radius + reach))
        }
        let left = cast.minX + radius
        let right = cast.maxX - radius
        let top = cast.minY + radius
        let bottom = cast.maxY - radius
        corner(CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), centre: CGPoint(x: left, y: top))
        corner(CGRect(x: x2, y: y0, width: x3 - x2, height: y1 - y0), centre: CGPoint(x: right, y: top))
        corner(CGRect(x: x0, y: y2, width: x1 - x0, height: y3 - y2), centre: CGPoint(x: left, y: bottom))
        corner(CGRect(x: x2, y: y2, width: x3 - x2, height: y3 - y2), centre: CGPoint(x: right, y: bottom))
    }

    // MARK: Glass

    /// Concentric hairlines from the edge of the panel inwards: the faint
    /// darkening of the glass itself, then the light on top of it.
    private static func drawGlass(
        in context: GraphicsContext, inside panel: CGRect, style: GlassStyle, pixel: CGFloat
    ) {
        guard panel.width > 1, panel.height > 1 else { return }
        let halfShort = min(panel.width, panel.height) / 2
        let radius = min(style.cornerRadius, halfShort)
        let glow = style.glowReach(for: panel.size)
        // One hairline per pixel where the light changes quickly; past the
        // glow only the darkening is left, and it changes by less than one
        // step of grey in two points.
        let fine = max(glow, 6).rounded(.up)
        let limit = min(max(fine, style.zRadius), halfShort)
        // The stroke is at full strength level with the top of the panel and
        // at 40% level with the bottom, whichever hairline it is on.
        let top = CGPoint(x: panel.midX, y: panel.minY)
        let bottom = CGPoint(x: panel.midX, y: panel.maxY)

        var start: CGFloat = 0
        while start < limit {
            let width = start < fine ? pixel : max(pixel, 2)
            // The middle of this hairline, where the shader would sample.
            let distance = start + width / 2
            start += width
            guard distance < halfShort else { break }
            let ring = roundedPath(panel.insetBy(dx: distance, dy: distance), radius: radius - distance)

            let veil = style.veil(at: distance)
            if veil > 0.002 {
                context.stroke(ring, with: .color(.black.opacity(veil)), lineWidth: width)
            }

            guard distance < glow, style.edgeHighlight > 0 else { continue }
            let atTop = style.highlightOpacity(at: distance, bias: 1, glowReach: glow)
            let atBottom = style.highlightOpacity(at: distance, bias: 0, glowReach: glow)
            if atTop - atBottom > 0.002 {
                context.stroke(
                    ring,
                    with: .linearGradient(
                        Gradient(stops: stops(at: distance, style: style, glowReach: glow)),
                        startPoint: top, endPoint: bottom),
                    lineWidth: width)
            } else if atTop > 0.002 {
                context.stroke(ring, with: .color(.white.opacity(atTop)), lineWidth: width)
            }
        }
    }

    /// White from the top of the panel to the bottom for one hairline. The
    /// stroke falls off linearly on the way down, but the total is capped,
    /// so where it starts above the cap it is held there down to the point
    /// it drops below.
    private static func stops(at distance: CGFloat, style: GlassStyle, glowReach: CGFloat) -> [Gradient.Stop] {
        let amount = style.light(at: distance, glowReach: glowReach)
        let uncappedTop = style.overlayGain * (amount.even + amount.stroke)
        let uncappedBottom = style.overlayGain * (amount.even + amount.stroke * 0.4)
        func white(_ bias: Double) -> Color {
            .white.opacity(style.highlightOpacity(at: distance, bias: bias, glowReach: glowReach))
        }
        var stops = [Gradient.Stop(color: white(1), location: 0)]
        if uncappedTop > 1, uncappedBottom < 1 {
            let location = (uncappedTop - 1) / (uncappedTop - uncappedBottom)
            stops.append(Gradient.Stop(color: white(1 - location), location: location))
        }
        stops.append(Gradient.Stop(color: white(0), location: 1))
        return stops
    }
}

/// The dimmed area around a selection: the whole screen with a hole the
/// shape of the glass panel, filled even-odd.
struct SelectionDim: Shape {
    var hole: CGRect
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let radius = max(0, min(cornerRadius, min(hole.width, hole.height) / 2))
        path.addPath(Path(roundedRect: hole, cornerRadius: radius, style: .circular))
        return path
    }
}
