import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import RetainerKit

/// The selection glass is meant to look like the LiquidGlass playground
/// (https://liquid-glass.ybouane.com) at these settings:
///
///     Edge Highlight 1, Corner Radius 7, Z-Radius 54, Opacity 0.94,
///     Shadow Opacity 0.5, Shadow Spread 20, everything else 0
///
/// These tests hold it to that in three ways: against brightness measured
/// from a screenshot of the playground, against the library's own shader
/// arithmetic, and against what actually gets drawn.
@Suite("Glass panel")
struct GlassPanelTests {

    private let style = GlassStyle.capture

    /// What a pixel of the page comes out as once the glass's black and
    /// white are laid over it. `page` and the result are 0…1.
    private func covered(page: Double, distance: CGFloat, bias: Double, glowReach: CGFloat) -> Double {
        let white = style.highlightOpacity(at: distance, bias: bias, glowReach: glowReach)
        return page * (1 - style.veil(at: distance)) * (1 - white) + white
    }

    // MARK: Against the playground screenshot

    /// Mean brightness (0…255) of rows of pixels in the playground
    /// screenshot, across the straight part of the sample panel's top and
    /// bottom edges, beside the brightness of the same rows of the plain
    /// photograph behind it. The panel there is 180 × 90 px at 1x.
    @Test("matches brightness measured from the playground", arguments: [
        // distance in from the edge, top or bottom edge, photograph, with glass
        (0.5, true, 116.1, 116.9),
        (1.5, true, 115.2, 226.9),
        (2.5, true, 110.1, 160.2),
        (3.5, true, 108.4, 150.4),
        (5.5, true, 109.9, 135.9),
        (8.5, true, 113.1, 126.0),
        (12.5, true, 103.7, 99.9),
        (0.5, false, 89.9, 93.2),
        (1.5, false, 89.6, 196.2),
        (2.5, false, 84.9, 141.2),
        (4.5, false, 84.0, 119.4),
        (8.5, false, 81.1, 97.1),
    ])
    func matchesMeasuredHighlight(distance: Double, top: Bool, photograph: Double, measured: Double) {
        let panel = CGSize(width: 180, height: 90)
        let reach = panel.height / 2 * 0.35
        let bias = top ? 1 - distance / 90 : distance / 90
        let drawn = covered(page: photograph / 255, distance: distance, bias: bias, glowReach: reach) * 255
        // Within 12 of 255. What is left is the difference between adding
        // light, as the shader does, and laying white over the picture.
        #expect(abs(drawn - measured) < 12, "drew \(drawn), the playground shows \(measured)")
    }

    @Test("shadow matches the playground", arguments: [
        // distance out from the edge of the shadow, photograph, with shadow
        (0.0, 84.5, 64.8),
        (0.5, 81.2, 62.8),
        (1.5, 114.5, 90.7),
        (5.5, 76.5, 63.3),
        (6.5, 116.8, 102.5),
        (10.5, 72.8, 65.5),
        (11.5, 125.9, 117.5),
    ])
    func matchesMeasuredShadow(distance: Double, photograph: Double, measured: Double) {
        let drawn = photograph * (1 - style.shadow(at: distance))
        #expect(abs(drawn - measured) < 6, "drew \(drawn), the playground shows \(measured)")
    }

    // MARK: Against the library's arithmetic

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The library's fragment shader at these settings, followed by the way
    /// its canvas reaches the page: it blends with (SRC_ALPHA,
    /// ONE_MINUS_SRC_ALPHA) into a cleared buffer, which leaves colour × alpha
    /// and alpha², and the browser then reads that buffer as straight alpha.
    private func library(page: Double, distance: Double, bias: Double, glowReach: Double) -> Double {
        let sdf = -distance
        let mask = 1 - smoothstep(-1.5, 0.5, sdf)
        let edge = smoothstep(glowReach, 0, distance)
        let depth = smoothstep(0, 54, distance)
        var stroke = smoothstep(-2.5, -1.5, sdf) * (1 - smoothstep(-1, 0, sdf))
        stroke *= 0.4 + 0.6 * bias
        let light = edge * 0.22 + smoothstep(5, 0, distance) * 0.15 + stroke * 0.55
        let colour = min(1, page * (1 + 0.06 * depth) + light)
        let alpha = mask * 0.94
        return colour * alpha * alpha * alpha + page * (1 - alpha * alpha)
    }

    /// The shader adds light; an overlay window can only lay white over what
    /// is behind it, and no one strength of white equals added light on every
    /// background. `overlayGain` splits the difference between a dark
    /// interface and a mid-toned photograph, which leaves the stroke up to a
    /// tenth of full scale brighter than the shader's on the first and
    /// dimmer on the second. Everywhere else it is much closer.
    @Test("stays close to the shader on dark and mid-toned pictures", arguments: [0.12, 0.35])
    func followsShader(page: Double) {
        let reach: CGFloat = 16
        for bias in [0.0, 0.5, 1.0] {
            for step in 0..<120 {
                let distance = 0.25 + Double(step) * 0.5
                let expected = library(page: page, distance: distance, bias: bias, glowReach: Double(reach))
                let drawn = covered(page: page, distance: distance, bias: bias, glowReach: reach)
                // The stroke band, then the glow, then the clear middle.
                let tolerance = distance < 3 ? 0.1 : distance < 16 ? 0.04 : 0.006
                #expect(
                    abs(drawn - expected) < tolerance,
                    "page \(page), \(distance) pt in, bias \(bias): drew \(drawn), shader gives \(expected)")
            }
        }
    }

    @Test("shadow is the shader's, squared")
    func shadowFollowsShader() {
        // Up to where the tail starts easing it out.
        for step in 0..<15 {
            let distance = Double(step)
            let d = max(distance - 1, 0)
            let alpha = 0.5 * (0.65 * exp(-d * d / 400) + 0.35 * exp(-d * 0.08 / 0.8))
            #expect(abs(style.shadow(at: distance) - alpha * alpha) < 0.0001)
        }
        #expect(abs(style.shadow(at: 0) - 0.25) < 0.0001)
        #expect(style.shadow(at: style.shadowReach) == 0)
        #expect(style.shadow(at: style.shadowReach + 10) == 0)
    }

    // MARK: The look

    @Test("the middle is left alone")
    func middleIsClear() {
        let reach = style.glowReach(for: CGSize(width: 760, height: 360))
        #expect(reach == 16)
        for distance in stride(from: CGFloat(16), through: 180, by: 4) {
            #expect(style.highlightOpacity(at: distance, bias: 1, glowReach: reach) == 0)
        }
        // Nothing at all past the bevel, and never more than a faint tint before it.
        #expect(style.veil(at: 54) < 0.004)
        #expect(style.veil(at: 120) < 0.004)
        for distance in stride(from: CGFloat(1.5), through: 54, by: 0.5) {
            #expect(style.veil(at: distance) < 0.06)
        }
    }

    @Test("the stroke is a hairline, brightest along the top")
    func strokeShape() {
        let reach: CGFloat = 16
        let peakTop = style.highlightOpacity(at: 1.5, bias: 1, glowReach: reach)
        let peakBottom = style.highlightOpacity(at: 1.5, bias: 0, glowReach: reach)
        // Capped at the cube of the opacity, as on the playground.
        #expect(abs(peakTop - 0.94 * 0.94 * 0.94) < 0.0001)
        #expect(peakBottom < peakTop - 0.15)
        #expect(peakBottom > 0.5)
        // One point either side it has fallen well away.
        #expect(style.highlightOpacity(at: 0.5, bias: 1, glowReach: reach) < 0.15)
        #expect(style.highlightOpacity(at: 2.5, bias: 1, glowReach: reach) < 0.35)
        // And from there it only fades.
        var previous = style.highlightOpacity(at: 2.5, bias: 1, glowReach: reach)
        for distance in stride(from: CGFloat(3.5), through: 20, by: 1) {
            let next = style.highlightOpacity(at: distance, bias: 1, glowReach: reach)
            #expect(next <= previous)
            previous = next
        }
    }

    @Test("small panels get a shorter glow")
    func glowReachScalesDown() {
        #expect(abs(style.glowReach(for: CGSize(width: 180, height: 90)) - 15.75) < 0.0001)
        #expect(style.glowReach(for: CGSize(width: 40, height: 20)) == 3.5)
        #expect(style.glowReach(for: CGSize(width: 3440, height: 1440)) == 16)
    }

    // MARK: What is drawn

    /// The panel as SwiftUI draws it, over a flat grey, at one pixel per point.
    @MainActor
    private func render(panel: CGRect, in size: CGSize, grey: Double, scale: CGFloat = 1) throws -> Raster {
        let view = ZStack(alignment: .topLeading) {
            Color(white: grey)
            GlassPanel(rect: panel)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.displayScale, scale)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        return try Raster(#require(renderer.cgImage))
    }

    @Test("draws a clear middle, a bright top edge and a soft shadow")
    @MainActor
    func drawsTheLook() throws {
        let panel = CGRect(x: 60, y: 50, width: 300, height: 200)
        let raster = try render(panel: panel, in: CGSize(width: 420, height: 300), grey: 0.35)
        let page = raster.value(x: 5, y: 5)
        #expect(abs(page - 0.35) < 0.03)

        // Far from the panel, and in its middle, the page is untouched.
        #expect(raster.value(x: 210, y: 10) == page)
        #expect(raster.value(x: 210, y: 150) == page)
        #expect(raster.value(x: 150, y: 120) == page)

        // The stroke: the second row of pixels in from each edge.
        let top = raster.value(x: 210, y: 51)
        let bottom = raster.value(x: 210, y: 248)
        let reach = style.glowReach(for: panel.size)
        #expect(abs(top - covered(page: page, distance: 1.5, bias: 1 - 1.5 / 200, glowReach: reach)) < 0.02)
        #expect(abs(bottom - covered(page: page, distance: 1.5, bias: 1.5 / 200, glowReach: reach)) < 0.02)
        #expect(top > 0.85)
        #expect(bottom < top - 0.1)
        // Brighter than the rows either side of it.
        #expect(raster.value(x: 210, y: 50) < top - 0.3)
        #expect(raster.value(x: 210, y: 52) < top - 0.3)
        // The same on the sides, between the two.
        let left = raster.value(x: 61, y: 150)
        #expect(left < top + 0.01)
        #expect(left > bottom - 0.01)
        #expect(abs(left - raster.value(x: 358, y: 150)) < 0.01)

        // The shadow: a quarter black against the edge, gone by its reach.
        #expect(abs(raster.value(x: 210, y: 250) - page * 0.75) < 0.02)
        #expect(abs(raster.value(x: 210, y: 49) - page * (1 - style.shadow(at: 1.5))) < 0.02)
        #expect(raster.value(x: 210, y: 262) > raster.value(x: 210, y: 252))
        #expect(raster.value(x: 210, y: 250 + Int(style.shadowReach) + 3) == page)
        #expect(raster.value(x: 60 - Int(style.shadowReach) - 3, y: 150) == page)
        // Smooth round the corner: no brighter or darker than the sides it joins.
        let diagonal = raster.value(x: 60 - 4, y: 250 + 4)
        #expect(diagonal > page * 0.74)
        #expect(diagonal < page)
    }

    @Test("draws the same thing at Retina density")
    @MainActor
    func drawsAtTwoPixelsPerPoint() throws {
        let panel = CGRect(x: 60, y: 50, width: 300, height: 200)
        let raster = try render(panel: panel, in: CGSize(width: 420, height: 300), grey: 0.35, scale: 2)
        #expect(raster.width == 840)
        let page = raster.value(x: 10, y: 10)
        #expect(raster.value(x: 420, y: 300) == page)
        // The stroke is still one point wide: the two rows of pixels from 1 to 2 pt in.
        let reach = style.glowReach(for: panel.size)
        for (row, distance) in [(102, 1.25), (103, 1.75)] {
            let expected = covered(page: page, distance: distance, bias: 1, glowReach: reach)
            #expect(abs(raster.value(x: 420, y: row) - expected) < 0.03)
        }
        #expect(raster.value(x: 420, y: 100) < 0.5)
        #expect(abs(raster.value(x: 420, y: 501) - page * 0.75) < 0.02)
    }

    @Test("a selection too small for its corners still draws")
    @MainActor
    func drawsTinySelections() throws {
        // The first frame of a drag is a few points across.
        for size in [CGSize(width: 4, height: 1), CGSize(width: 6, height: 6), CGSize(width: 0, height: 0)] {
            let panel = CGRect(origin: CGPoint(x: 80, y: 80), size: size)
            let raster = try render(panel: panel, in: CGSize(width: 200, height: 200), grey: 0.35)
            #expect(raster.value(x: 5, y: 5) == raster.value(x: 195, y: 195))
        }
    }
}

/// The pixels of a rendered image, as grey levels 0…1, origin top-left.
private struct Raster {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) throws {
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
            CGContext(
                data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = data
    }

    func value(x: Int, y: Int) -> Double {
        Double(bytes[(y * width + x) * 4 + 1]) / 255
    }
}
