import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Mini map: the orb")
struct OrbTests {

    private let diameter: CGFloat = 132
    private let inset: CGFloat = 14
    private var radius: CGFloat { diameter / 2 - inset }
    private var rim: CGFloat { diameter / 2 }
    private let middle = CGPoint(x: 66, y: 66)

    private func corners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ]
    }

    private func distance(_ point: CGPoint) -> CGFloat {
        hypot(point.x - middle.x, point.y - middle.y)
    }

    private func orb(_ frames: [CGRect], viewport: CGRect) -> OrbGeometry {
        OrbGeometry(frames: frames, viewport: viewport, diameter: diameter, inset: inset)
    }

    // MARK: What the orb takes in

    @Test("The window's view is at the middle of the orb, wherever it is on the board")
    func centredOnTheView() {
        let cards = [CGRect(x: -900, y: -400, width: 400, height: 300), CGRect(x: 700, y: 900, width: 400, height: 520)]
        for viewport in [
            CGRect(x: -640, y: -360, width: 1280, height: 720), CGRect(x: 300, y: -1100, width: 1280, height: 720),
            CGRect(x: 52_000, y: -31_000, width: 2560, height: 1440),
        ] {
            let map = orb(cards, viewport: viewport)
            #expect(map.focus == CGPoint(x: viewport.midX, y: viewport.midY))
            let frame = map.projection.rect(viewport)
            #expect(abs(frame.midX - 66) < 0.001 && abs(frame.midY - 66) < 0.001)
        }
    }

    @Test("Cards within sight are all drawn in full, and the orb is used right to its edge")
    func takesInNearbyCards() {
        let viewport = CGRect(x: 0, y: 0, width: 1280, height: 720)
        let cards = [CGRect(x: -700, y: -300, width: 400, height: 300), CGRect(x: 1500, y: 900, width: 400, height: 520)]
        let map = orb(cards, viewport: viewport)

        for corner in (cards + [viewport]).flatMap(corners) {
            #expect(distance(map.projection.point(corner)) <= radius + 0.001)
        }
        // The far corner of the furthest card is exactly as far out as cards go.
        let furthest = cards.flatMap(corners).map { distance(map.projection.point($0)) }.max() ?? 0
        #expect(abs(furthest - radius) < 0.001)
        #expect(abs(map.scale - radius / map.reach) < 0.000_001)
    }

    @Test("With every card in view, the view fills the orb")
    func everythingInView() {
        let viewport = CGRect(x: -640, y: -360, width: 1280, height: 720)
        let cards = [CGRect(x: -500, y: -200, width: 400, height: 300), CGRect(x: 100, y: -100, width: 400, height: 300)]
        let map = orb(cards, viewport: viewport)
        let half = hypot(viewport.width, viewport.height) / 2
        #expect(abs(map.reach - half) < 0.001)
        for corner in corners(viewport) {
            #expect(abs(distance(map.projection.point(corner)) - radius) < 0.001)
        }
        // The same with no cards at all.
        #expect(abs(orb([], viewport: viewport).reach - half) < 0.001)
    }

    @Test("The orb only sees so far: beyond that it stops zooming out and cards fall outside the glass")
    func sightIsLimited() {
        let card = CGRect(x: -200, y: -150, width: 400, height: 300)
        let far = CGRect(x: 9000, y: 6000, width: 1280, height: 720)
        let further = CGRect(x: 90_000, y: -60_000, width: 1280, height: 720)
        let half = hypot(far.width, far.height) / 2

        let first = orb([card], viewport: far)
        let second = orb([card], viewport: further)
        #expect(abs(first.reach - half * OrbGeometry.sight) < 0.001)
        // However much further, the orb is no more zoomed out.
        #expect(first.scale == second.scale)
        // The view is still a good size at the middle: a quarter of the way out.
        let frame = first.projection.rect(far)
        #expect(abs(hypot(frame.width, frame.height) / 2 - radius / OrbGeometry.sight) < 0.001)
        // And the card is off the glass altogether, up and to the left.
        let position = first.projection.point(CGPoint(x: card.midX, y: card.midY))
        #expect(distance(position) > rim)
        #expect(position.x < middle.x && position.y < middle.y)
    }

    @Test("Nothing to go on still gives an orb that can be drawn")
    func degenerate() {
        for viewport in [CGRect.null, .zero, .infinite] {
            let map = orb([.null], viewport: viewport)
            #expect(map.scale.isFinite && map.scale > 0)
            #expect(map.reach.isFinite && map.reach > 0)
        }
    }

    @Test("A point clicked on the orb is the point of the board under it")
    func roundTrip() {
        let viewport = CGRect(x: 4000, y: -2500, width: 1280, height: 720)
        let projection = orb([CGRect(x: 0, y: 0, width: 400, height: 300)], viewport: viewport).projection
        for board in [CGPoint(x: 4640, y: -2140), CGPoint(x: 0, y: 0), CGPoint(x: 6000, y: -1000)] {
            let back = projection.boardPoint(for: projection.point(board))
            #expect(abs(back.x - board.x) < 0.01 && abs(back.y - board.y) < 0.01)
        }
        let centre = projection.boardPoint(for: middle)
        #expect(abs(centre.x - viewport.midX) < 0.01 && abs(centre.y - viewport.midY) < 0.01)
    }

    // MARK: The light on the rim

    private let blue = RGBColour(red: 0.3, green: 0.55, blue: 0.95)
    private let amber = RGBColour(red: 0.96, green: 0.7, blue: 0.2)
    private let red = RGBColour(red: 0.95, green: 0.25, blue: 0.2)

    /// A card `distance` map points from the middle, `degrees` clockwise from three o'clock.
    private func source(_ colour: RGBColour, degrees: Double, distance: CGFloat) -> RimLight.Source {
        let angle = degrees * .pi / 180
        return RimLight.Source(
            position: CGPoint(x: middle.x + CGFloat(cos(angle)) * distance, y: middle.y + CGFloat(sin(angle)) * distance),
            colour: colour)
    }

    private func light(_ sources: [RimLight.Source]) -> RimLight {
        RimLight(sources: sources, centre: middle, radius: radius, rim: rim)
    }

    /// The sample nearest an angle given in degrees clockwise from three o'clock.
    private func sample(_ light: RimLight, at degrees: Double) -> RimLight.Sample {
        let count = light.samples.count
        let index = Int((degrees / 360 * Double(count)).rounded()) % count
        return light.samples[(index + count) % count]
    }

    /// Where the light is centred, in degrees: the middle of it by strength.
    /// Only for light that does not straddle three o'clock.
    private func middleOfLight(_ light: RimLight) -> Double {
        let total = light.samples.reduce(0) { $0 + $1.strength }
        let weighted = light.samples.indices.reduce(0.0) { $0 + light.angle(at: $1) * light.samples[$1].strength }
        return weighted / total * 180 / .pi
    }

    /// How many degrees of the rim are lit at all brightly.
    private func width(_ light: RimLight) -> Double {
        Double(light.samples.filter { $0.strength > 0.2 }.count) * 360 / Double(light.samples.count)
    }

    private func isClose(_ first: RGBColour, _ second: RGBColour, within tolerance: Double = 0.02) -> Bool {
        abs(first.red - second.red) < tolerance && abs(first.green - second.green) < tolerance
            && abs(first.blue - second.blue) < tolerance
    }

    @Test("Cards the orb can show give no light")
    func noLightFromCardsInSight() {
        let inSight = light([
            source(blue, degrees: 0, distance: 0), source(amber, degrees: 200, distance: 30),
            source(blue, degrees: 90, distance: radius),
        ])
        #expect(inSight.isDark)
        #expect(light([]).isDark)
        #expect(light([]).samples.count == 180)
    }

    @Test("A card out of sight lights the rim exactly on its own side, in its own colour")
    func lightsItsOwnSide() {
        // Up and to the left: 225 degrees clockwise from three o'clock.
        let rimLight = light([source(blue, degrees: 225, distance: 400)])
        #expect(!rimLight.isDark)

        let brightest = rimLight.samples.indices.max { rimLight.samples[$0].strength < rimLight.samples[$1].strength }!
        #expect(abs(rimLight.angle(at: brightest) * 180 / .pi - 225) < 2.1)
        #expect(abs(middleOfLight(rimLight) - 225) < 0.5)
        #expect(isClose(sample(rimLight, at: 225).colour, blue))
        #expect(sample(rimLight, at: 225).strength > 0.5)
        // It is one colour from end to end.
        #expect(isClose(sample(rimLight, at: 205).colour, blue) && isClose(sample(rimLight, at: 245).colour, blue))
        // A little to either side it is fainter; across the orb there is nothing.
        #expect(sample(rimLight, at: 245).strength < sample(rimLight, at: 225).strength)
        #expect(sample(rimLight, at: 205).strength < sample(rimLight, at: 225).strength)
        #expect(sample(rimLight, at: 45).strength < 0.001)
        #expect(sample(rimLight, at: 135).strength < 0.01)
    }

    @Test("The light comes up as a card leaves the part where it is drawn")
    func fadesIn() {
        let strengths = [radius, radius + 6, rim, rim + 10].map {
            sample(light([source(blue, degrees: 0, distance: $0)]), at: 0).strength
        }
        #expect(strengths[0] < 0.001)
        #expect(strengths[1] > 0.01 && strengths[1] < strengths[2])
        #expect(strengths[2] < strengths[3])
        #expect(strengths[3] > 0.7)
    }

    @Test("More cards the same way make a brighter light, never more than full")
    func cardsAddUp() {
        let one = light([source(blue, degrees: 90, distance: 2000)])
        let three = light((0..<3).map { source(blue, degrees: 88 + Double($0) * 2, distance: 2000) })
        let many = light((0..<200).map { source(blue, degrees: 80 + Double($0) / 10, distance: 2000) })
        #expect(sample(three, at: 90).strength > sample(one, at: 90).strength + 0.2)
        #expect(sample(many, at: 90).strength > 0.99)
        #expect(many.samples.allSatisfy { $0.strength <= 1 && $0.strength >= 0 })
    }

    @Test("Cards in different directions keep their own colours, and mix where their light meets")
    func coloursByDirection() {
        let rimLight = light([
            source(blue, degrees: 180, distance: 300), source(amber, degrees: 0, distance: 300),
            source(amber, degrees: 270, distance: 300), source(blue, degrees: 310, distance: 300),
        ])
        #expect(isClose(sample(rimLight, at: 180).colour, blue))
        #expect(isClose(sample(rimLight, at: 0).colour, amber, within: 0.05))
        // Half way between the amber card above and the blue one beside it:
        // neither colour, and something of both.
        let between = sample(rimLight, at: 290).colour
        #expect(!isClose(between, blue, within: 0.08) && !isClose(between, amber, within: 0.08))
        #expect(between.red > 0.6 && between.blue > 0.6)
    }

    @Test("Cards of different hues that lie the same way are fanned out round it, not mixed to white")
    func fannedByHue() {
        // A red card and a blue one, a long way off in exactly the same direction.
        let rimLight = light([source(red, degrees: 90, distance: 3000), source(blue, degrees: 90, distance: 3000)])

        // Red to one side, blue to the other, each very nearly itself.
        let before = sample(rimLight, at: 76).colour
        let after = sample(rimLight, at: 104).colour
        #expect(before.red > before.blue + 0.4)
        #expect(after.blue > after.red + 0.4)
        #expect(sample(rimLight, at: 76).strength > 0.3 && sample(rimLight, at: 104).strength > 0.3)
        // The fan is centred on the way the cards lie.
        #expect(abs(middleOfLight(rimLight) - 90) < 1)
        // And it is wider than the light of either card alone.
        #expect(width(rimLight) > width(light([source(red, degrees: 90, distance: 3000)])) + 8)

        // Where the two meet, the light is no duller than its parts.
        let meeting = sample(rimLight, at: 90).colour
        #expect(max(meeting.red, meeting.green, meeting.blue) > 0.9)
    }

    @Test("Cards of one hue that lie the same way stay together")
    func oneHueIsNotFanned() {
        let one = light([source(blue, degrees: 200, distance: 3000)])
        let three = light((0..<3).map { _ in source(blue, degrees: 200, distance: 3000) })
        #expect(abs(middleOfLight(three) - 200) < 0.5)
        // Brighter, so a little more of it shows, but not spread round the rim.
        #expect(width(three) < width(one) + 16)
        #expect(three.samples.filter { $0.strength > 0.05 }.allSatisfy { isClose($0.colour, blue) })
    }

    @Test("However far off, a card still lights the rim: more faintly, and more narrowly")
    func neverGoesOut() {
        let near = light([source(blue, degrees: 0, distance: rim + 12)])
        let far = light([source(blue, degrees: 0, distance: 1_000_000)])
        #expect(sample(far, at: 0).strength > 0.5)
        #expect(sample(far, at: 0).strength < sample(near, at: 0).strength)
        // Thirty degrees off, the far light has fallen away by more.
        let nearShare = sample(near, at: 30).strength / sample(near, at: 0).strength
        let farShare = sample(far, at: 30).strength / sample(far, at: 0).strength
        #expect(farShare < nearShare)
    }

    // MARK: Colours

    private func picture(width: Int = 400, height: Int = 300, _ draw: (CGContext) -> Void) throws -> CGImage {
        let context = try #require(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        draw(context)
        return try #require(context.makeImage())
    }

    @Test("A screenshot is remembered by its colourful part, not by the white round it")
    func dominantColour() throws {
        // A white page, a tenth of it a red chart.
        let page = try picture { context in
            context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 240, y: 150, width: 120, height: 100))
        }
        let colour = try #require(ImageFiles.dominantColour(of: page))
        #expect(colour.red > colour.green + 0.25 && colour.red > colour.blue + 0.25)
        #expect(colour.hsb.saturation > 0.4)

        // The same chart on a black page is the same hue.
        let dark = try picture { context in
            context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.09, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
            context.setFillColor(CGColor(srgbRed: 0.85, green: 0.2, blue: 0.15, alpha: 1))
            context.fill(CGRect(x: 240, y: 150, width: 120, height: 100))
        }
        let onDark = try #require(ImageFiles.dominantColour(of: dark))
        #expect(abs(onDark.hsb.hue - colour.hsb.hue) < 0.03 || abs(onDark.hsb.hue - colour.hsb.hue) > 0.97)

        // A picture with no colour in it comes out its plain average.
        let grey = try picture { context in
            context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        let plain = try #require(ImageFiles.dominantColour(of: grey))
        #expect(abs(plain.red - 0.5) < 0.02 && abs(plain.green - 0.5) < 0.02 && abs(plain.blue - 0.5) < 0.02)

        // And a swatch carries both: the blocks and the colour.
        let swatch = try #require(MapSwatch(reducing: page))
        #expect(swatch.image.width == 4 && swatch.image.height == 3)
        #expect(swatch.colour == colour)
    }

    @Test("A card's colour becomes a bright light on dark glass and a deeper stain on light")
    func asLight() {
        let dull = RGBColour(red: 0.35, green: 0.2, blue: 0.1)
        let glow = dull.asLight(onDark: true)
        #expect(glow.hsb.brightness > 0.9)
        #expect(abs(glow.hsb.hue - dull.hsb.hue) < 0.01)
        #expect(glow.hsb.saturation >= dull.hsb.saturation - 0.001)

        let pale = RGBColour(red: 0.7, green: 0.82, blue: 0.98)
        let stain = pale.asLight(onDark: false)
        #expect(stain.hsb.brightness < 0.9)
        #expect(stain.hsb.saturation > pale.hsb.saturation)
        #expect(abs(stain.hsb.hue - pale.hsb.hue) < 0.01)

        // No colour at all: white light on dark, smoke on light.
        let paper = RGBColour(red: 0.93, green: 0.93, blue: 0.93)
        #expect(paper.asLight(onDark: true).hsb.saturation < 0.01)
        #expect(paper.asLight(onDark: true).hsb.brightness > 0.9)
        #expect(paper.asLight(onDark: false).hsb.brightness < 0.6)
    }

    @Test("Hue, saturation and brightness go there and back")
    func hsbRoundTrip() {
        for colour in [
            RGBColour(red: 0.9, green: 0.2, blue: 0.1), RGBColour(red: 0.1, green: 0.8, blue: 0.3),
            RGBColour(red: 0.2, green: 0.3, blue: 0.95), RGBColour(red: 0.8, green: 0.1, blue: 0.7),
            RGBColour(red: 0.5, green: 0.5, blue: 0.5), RGBColour(red: 0, green: 0, blue: 0),
            RGBColour(red: 1, green: 1, blue: 0),
        ] {
            let (hue, saturation, brightness) = colour.hsb
            let back = RGBColour(hue: hue, saturation: saturation, brightness: brightness)
            #expect(isClose(back, colour, within: 0.000_1))
        }
    }

    @Test("A screenshot boils down to a few blocks of its own colours")
    func pixelatedSwatch() throws {
        // Left half red, right half blue.
        let context = try #require(
            CGContext(
                data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 120))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 120))
        let image = try #require(context.makeImage())

        let swatch = try #require(ImageFiles.pixelated(image, columns: 4, rows: 3))
        #expect(swatch.width == 4 && swatch.height == 3)

        var pixels = [UInt8](repeating: 0, count: 4 * 3 * 4)
        let reader = try #require(
            CGContext(
                data: &pixels, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        reader.draw(swatch, in: CGRect(x: 0, y: 0, width: 4, height: 3))
        // The leftmost block is red, the rightmost blue.
        #expect(pixels[0] > 200 && pixels[2] < 60)
        #expect(pixels[12] < 60 && pixels[14] > 200)
    }

    // MARK: The setting

    @Test("The window's edges are the map unless the orb is chosen, and the choice is kept")
    @MainActor
    func settingIsKept() throws {
        let suite = "blog.terminal.app.tests.minimap-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(AppSettings(defaults: defaults).miniMapStyle == .edges)
        AppSettings(defaults: defaults).miniMapStyle = .orb
        #expect(AppSettings(defaults: defaults).miniMapStyle == .orb)
        #expect(MiniMapStyle.allCases == [.edges, .orb])
        // A kind this version does not have (the overview there used to
        // be, or anything else) falls back to the edges.
        for unknown in ["overview", "globe"] {
            defaults.set(unknown, forKey: "miniMapStyle")
            #expect(AppSettings(defaults: defaults).miniMapStyle == .edges)
        }
    }

    @Test("With the window as the map, a card lights only the edges it lies beyond, where it is along them")
    func edgeLight() throws {
        let viewport = CGRect(x: 2000, y: 1500, width: 1400, height: 900)
        func strongest(_ samples: [RimLight.Sample]) -> (index: Int, strength: Double) {
            let index = samples.indices.max { samples[$0].strength < samples[$1].strength }!
            return (index, samples[index].strength)
        }
        func light(_ frame: CGRect) throws -> [EdgeGlow.Side: [RimLight.Sample]] {
            try #require(EdgeGlow.light(cards: [(frame, blue)], viewport: viewport))
        }

        // Straight above, towards the right: the top edge only, over where the card is.
        let above = CGRect(x: 2900, y: 600, width: 400, height: 300)
        let top = try light(above)
        let peak = strongest(try #require(top[.top]))
        #expect(peak.strength > 0.3)
        // The card's middle is 1100 of 1400 across: about 0.79 of the way along.
        #expect(abs(Double(peak.index) / 63 - 0.786) < 0.03)
        #expect(isClose(top[.top]![peak.index].colour, blue))
        for side in [EdgeGlow.Side.left, .right, .bottom] {
            #expect(top[side]!.allSatisfy { $0.strength == 0 })
        }
        // As wide as the card and a quarter as much again either side, and
        // then nothing. The card's ends are 9 samples from its middle: still
        // lit there, well down. A quarter of the card further out is 13.5.
        let atTheEnd = top[.top]![peak.index - 9].strength / peak.strength
        #expect(atTheEnd > 0.25 && atTheEnd < 0.5)
        #expect(top[.top]![peak.index - 15].strength == 0 && top[.top]![min(peak.index + 15, 63)].strength == 0)
        #expect(top[.top]![0].strength == 0)

        // More cards in the same place are a brighter light, not a wider one.
        let pile = try #require(
            EdgeGlow.light(cards: Array(repeating: (above, blue), count: 12), viewport: viewport))
        #expect(strongest(pile[.top]!).strength > 0.99)
        #expect(pile[.top]![peak.index - 15].strength == 0 && pile[.top]![min(peak.index + 15, 63)].strength == 0)

        // Beyond the top left corner: the two edges that meet there, near
        // the corner, and more on the one the card is further beyond.
        let corner = CGRect(x: 1000, y: 800, width: 400, height: 300)
        let both = try light(corner)
        #expect(strongest(both[.top]!).index == 0 && strongest(both[.left]!).index == 0)
        #expect(strongest(both[.left]!).strength > strongest(both[.top]!).strength)
        #expect(strongest(both[.top]!).strength > 0.15)
        #expect(both[.top]![40].strength < 0.01 && both[.left]![40].strength < 0.01)
        #expect(both[.right]!.allSatisfy { $0.strength == 0 } && both[.bottom]!.allSatisfy { $0.strength == 0 })

        // Far above and only just past the corner: a light on the top, and
        // next to none on the left.
        let mostlyAbove = try light(CGRect(x: 1500, y: 0, width: 400, height: 300))
        #expect(strongest(mostlyAbove[.top]!).strength > 0.3)
        #expect(strongest(mostlyAbove[.left]!).strength < strongest(mostlyAbove[.top]!).strength / 4)

        // The light comes up as the card goes out of sight, rather than all
        // at once; after that, nearer is brighter, and far off is never dark.
        let justGone = strongest(try light(CGRect(x: 2900, y: 1190, width: 400, height: 300))[.top]!).strength
        let wellGone = strongest(try light(CGRect(x: 2900, y: 1100, width: 400, height: 300))[.top]!).strength
        let far = strongest(try light(CGRect(x: 2900, y: -9000, width: 400, height: 300))[.top]!).strength
        #expect(justGone > 0 && justGone < 0.1)
        #expect(wellGone > peak.strength && peak.strength > far && far > 0.2)

        // A card that can be seen, even partly, gives none.
        for seen in [CGRect(x: 3300, y: 2300, width: 400, height: 300), CGRect(x: 2900, y: 1300, width: 400, height: 300)] {
            #expect(try light(seen).values.allSatisfy { $0.allSatisfy { $0.strength == 0 } })
        }
        #expect(EdgeGlow.light(cards: [(above, blue)], viewport: nil) == nil)

        // Drawn with as many samples as the edge is long: the light is in
        // the same place and as bright.
        let fine = try #require(EdgeGlow.light(cards: [(above, blue)], viewport: viewport, samples: (300, 120)))
        #expect(fine[.top]!.count == 300 && fine[.left]!.count == 120)
        let finePeak = strongest(fine[.top]!)
        #expect(abs(Double(finePeak.index) / 299 - 0.786) < 0.01)
        #expect(abs(finePeak.strength - peak.strength) < 0.01)
    }

}
