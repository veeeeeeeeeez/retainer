import CoreGraphics
import Foundation

/// A colour as three sRGB components, each from 0 to 1.
struct RGBColour: Equatable, Sendable {

    var red: Double
    var green: Double
    var blue: Double

    /// Hue (0 to 1, once round the wheel), saturation and brightness.
    var hsb: (hue: Double, saturation: Double, brightness: Double) {
        let high = max(red, green, blue)
        let low = min(red, green, blue)
        let span = high - low
        guard span > 0.0001, high > 0 else { return (0, 0, high) }
        var hue: Double
        if high == red {
            hue = (green - blue) / span
        } else if high == green {
            hue = 2 + (blue - red) / span
        } else {
            hue = 4 + (red - green) / span
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, span / high, high)
    }

    /// The colour as light: what a card of this colour puts on the rim of
    /// the orb.
    ///
    /// On dark glass a light has to be bright whatever the picture was, so
    /// the hue and saturation are kept and the brightness brought up: a
    /// black page with an orange chart glows orange, a page of plain text
    /// glows white. On light glass there is nothing to glow against, so the
    /// colour is deepened into a stain instead, and a colourless one into
    /// smoke.
    func asLight(onDark: Bool) -> RGBColour {
        let (hue, saturation, brightness) = hsb
        if onDark {
            return RGBColour(hue: hue, saturation: saturation, brightness: max(brightness, 0.94))
        }
        let deepened = min(1, saturation * 1.5)
        let ceiling = 0.52 + 0.36 * min(1, deepened / 0.5)
        return RGBColour(hue: hue, saturation: deepened, brightness: min(brightness, ceiling))
    }
}

extension RGBColour {

    init(hue: Double, saturation: Double, brightness: Double) {
        let sector = (hue - hue.rounded(.down)) * 6
        let whole = sector.rounded(.down)
        let fraction = sector - whole
        let low = brightness * (1 - saturation)
        let falling = brightness * (1 - saturation * fraction)
        let rising = brightness * (1 - saturation * (1 - fraction))
        switch Int(whole) % 6 {
        case 0: self.init(red: brightness, green: rising, blue: low)
        case 1: self.init(red: falling, green: brightness, blue: low)
        case 2: self.init(red: low, green: brightness, blue: rising)
        case 3: self.init(red: low, green: falling, blue: brightness)
        case 4: self.init(red: rising, green: low, blue: brightness)
        default: self.init(red: brightness, green: low, blue: falling)
        }
    }
}

/// How the board is fitted into the orb: the mini map that is centred on
/// where the window is looking.
///
/// The middle of the orb is always the middle of the window's view. The orb
/// zooms out to take in every card of the board, but only so far: no further
/// than `sight` times the size of the view. A card beyond that is not drawn.
/// It is light on the rim instead (`RimLight`), on the side it lies.
struct OrbGeometry: Equatable {

    /// The point of the board at the middle of the orb: the middle of the
    /// window's view.
    let focus: CGPoint
    /// How far from `focus`, on the board, a card can be and still be drawn
    /// in full.
    let reach: CGFloat
    /// Map points per board point.
    let scale: CGFloat
    /// The middle of the circle, in the map view's own coordinates.
    let centre: CGPoint
    /// How far from `centre`, on the map, `reach` falls: the glass less the
    /// clear space kept inside its edge.
    let radius: CGFloat
    /// The edge of the glass itself.
    let rim: CGFloat

    /// The furthest the orb sees, as a multiple of the distance from the
    /// middle of the window's view to its corner. At this limit the view is
    /// a quarter of the orb across, and a card at 100% is a few points wide:
    /// any further out and neither would say much.
    static let sight: CGFloat = 4

    /// - Parameters:
    ///   - frames: every card of the board.
    ///   - viewport: the part of the board the window is showing.
    ///   - diameter: of the circle.
    ///   - inset: clear space kept inside the circle's edge.
    init(frames: [CGRect], viewport: CGRect, diameter: CGFloat, inset: CGFloat) {
        var view = viewport
        if view.isNull || view.isInfinite || view.width <= 0 || view.height <= 0 {
            view = CGRect(x: -1, y: -1, width: 2, height: 2)
        }
        let focus = CGPoint(x: view.midX, y: view.midY)
        let corner = hypot(view.width, view.height) / 2

        // Far enough to take in the far corner of the furthest card, and
        // always the whole of the view.
        var furthest = corner
        for frame in frames where !frame.isNull && !frame.isInfinite {
            let across = max(abs(frame.minX - focus.x), abs(frame.maxX - focus.x))
            let down = max(abs(frame.minY - focus.y), abs(frame.maxY - focus.y))
            furthest = max(furthest, hypot(across, down))
        }

        self.focus = focus
        reach = min(furthest, corner * Self.sight)
        rim = diameter / 2
        radius = max(1, diameter / 2 - inset)
        scale = radius / reach
        centre = CGPoint(x: diameter / 2, y: diameter / 2)
    }

    var projection: MapProjection {
        MapProjection(focus: focus, scale: scale, centre: centre)
    }
}

/// The light on the rim of the orb: which way the cards that are out of its
/// range lie, and what colour they are.
///
/// Every card too far off to be drawn lights the rim on its own side, in its
/// own colour. Cards that lie the same way add up, so a cluster is brighter
/// than one card. A card near the edge of the range gives a wide, strong
/// light; one a long way off a narrower, fainter one, but never none:
/// however far the window has been scrolled, the rim still says which way
/// back.
///
/// Seen from far enough away, every card of a cluster lies in the same
/// direction, and their colours laid on top of one another would come to
/// white. So the orb does what a glass ball does to light and fans them out
/// by hue, red at one end and violet at the other, round the direction the
/// cluster lies in. A card on its own is not moved at all, and cards of one
/// hue stay together.
struct RimLight: Equatable {

    /// One card, as the orb sees it.
    struct Source: Equatable {
        /// Where the middle of the card falls in the orb's own coordinates:
        /// inside the glass, or any distance outside it.
        var position: CGPoint
        /// Its light (`RGBColour.asLight`).
        var colour: RGBColour
    }

    /// The light at one point of the rim.
    struct Sample: Equatable {
        var colour: RGBColour
        /// 0 is unlit, 1 as bright as the rim gets.
        var strength: Double
    }

    /// Evenly spaced round the rim. The first is at three o'clock and they
    /// go clockwise, as angles do on screen.
    let samples: [Sample]

    /// How wide one card's light is, as an angle either side of where the
    /// card lies: for a card just out of range, and for one a very long way off.
    static let nearSpread = 0.32
    static let farSpread = 0.17
    /// How strong the light of a card a very long way off is, next to that
    /// of one just out of range.
    static let farStrength = 0.6
    /// The furthest a card's light is moved along the rim to keep its hue
    /// apart from the others', either way.
    static let fan = 0.3
    /// How short the stretch is over which one card's colour runs into the
    /// next one's.
    static let colourSpread = 0.14
    /// How far along the rim cards count as lying the same way, when
    /// working out what to fan a card's light out from.
    private static let neighbourhood = 0.26
    /// How quickly light adds up: one card a long way off comes to about
    /// `farStrength`, three to nearly full.
    private static let gain = 1.5

    /// Whether there is no light worth drawing.
    var isDark: Bool {
        !samples.contains { $0.strength > 0.004 }
    }

    /// The angle of the sample at `index`, in radians.
    func angle(at index: Int) -> Double {
        2 * .pi * Double(index) / Double(max(samples.count, 1))
    }

    /// - Parameters:
    ///   - sources: every card of the board.
    ///   - centre: the middle of the orb.
    ///   - radius: how far from the middle cards are drawn in full. A card
    ///     inside this gives no light: it can be seen.
    ///   - rim: the edge of the glass.
    ///   - count: how many samples to take round the rim.
    init(sources: [Source], centre: CGPoint, radius: CGFloat, rim: CGFloat, count: Int = 180) {
        struct Lamp {
            let bearing: Double
            let power: Double
            /// 1 just out of range, falling towards 0 with distance.
            let nearness: Double
            /// How far its hue would move its light along the rim.
            let nudge: Double
            let red: Double
            let green: Double
            let blue: Double
            let brightness: Double
        }

        // A card starts to light the rim as it leaves the part where it is
        // drawn in full, and is fully light a little way outside the glass,
        // so that it fades from one into the other as the board is scrolled.
        let fullyOut = rim + (rim - radius) / 2
        let lamps: [Lamp] = sources.compactMap { source in
            let across = Double(source.position.x - centre.x)
            let down = Double(source.position.y - centre.y)
            let distance = hypot(across, down)
            let presence = Self.smooth(Double(radius), Double(fullyOut), distance)
            guard presence > 0.001 else { return nil }
            let nearness = min(1, Double(rim) / max(distance, Double(rim)))
            // Where its hue puts it in the fan: red at one end, violet at
            // the other, a card with no colour in the middle. The wheel is
            // cut in the pinks, the hue screenshots have least of.
            let (hue, saturation, brightness) = source.colour.hsb
            let place = (hue + 0.1).truncatingRemainder(dividingBy: 1) * 2 - 1
            let nudge = Self.fan * place * min(1, saturation / 0.25)
            // Colours are mixed as light is, not as paint.
            return Lamp(
                bearing: atan2(down, across),
                power: presence * (Self.farStrength + (1 - Self.farStrength) * nearness),
                nearness: nearness, nudge: nudge,
                red: pow(source.colour.red, 2.2), green: pow(source.colour.green, 2.2),
                blue: pow(source.colour.blue, 2.2), brightness: brightness)
        }

        let count = max(count, 8)
        guard !lamps.isEmpty else {
            samples = Array(
                repeating: Sample(colour: RGBColour(red: 1, green: 1, blue: 1), strength: 0), count: count)
            return
        }
        // Everything below is sums round the rim, so the work does not grow
        // with the number of cards beyond putting each one in.
        let step = 2 * Double.pi / Double(count)
        let empty = [Double](repeating: 0, count: count)

        // Each card's light is moved by its own hue less the average of the
        // cards round it: one on its own stays exactly where it lies, and a
        // cluster's fan is centred on the cluster.
        var weightThere = empty
        var nudgeThere = empty
        for lamp in lamps {
            Self.put(lamp.power, at: lamp.bearing, into: &weightThere, step: step)
            Self.put(lamp.power * lamp.nudge, at: lamp.bearing, into: &nudgeThere, step: step)
        }
        weightThere = Self.spread(weightThere, by: Self.neighbourhood / step)
        nudgeThere = Self.spread(nudgeThere, by: Self.neighbourhood / step)

        var near = empty
        var far = empty
        var weight = empty
        var red = empty
        var green = empty
        var blue = empty
        var brightness = empty
        for lamp in lamps {
            let around = Self.value(of: weightThere, at: lamp.bearing, step: step)
            let usual = around > 0 ? Self.value(of: nudgeThere, at: lamp.bearing, step: step) / around : lamp.nudge
            let bearing = lamp.bearing + lamp.nudge - usual
            Self.put(lamp.power * lamp.nearness, at: bearing, into: &near, step: step)
            Self.put(lamp.power * (1 - lamp.nearness), at: bearing, into: &far, step: step)
            Self.put(lamp.power, at: bearing, into: &weight, step: step)
            Self.put(lamp.power * lamp.red, at: bearing, into: &red, step: step)
            Self.put(lamp.power * lamp.green, at: bearing, into: &green, step: step)
            Self.put(lamp.power * lamp.blue, at: bearing, into: &blue, step: step)
            Self.put(lamp.power * lamp.brightness, at: bearing, into: &brightness, step: step)
        }

        // How bright: a wide light from what is close, a narrower one from
        // what is far.
        near = Self.spread(near, by: Self.nearSpread / step)
        far = Self.spread(far, by: Self.farSpread / step)

        // What colour: at each point of the rim, mostly that of the card
        // whose light is centred nearest, running into its neighbours'
        // over a short stretch. The cards at the two ends of a fan colour
        // the light all the way out to where it fades.
        let reach = count / 2
        let fall = (-reach...reach).map { exp(-abs(Double($0)) * step / Self.colourSpread) }
        func blend(_ values: [Double]) -> [Double] {
            (0..<count).map { index in
                var total = 0.0
                for offset in -reach...reach {
                    total += values[((index + offset) % count + count) % count] * fall[offset + reach]
                }
                return total
            }
        }
        weight = blend(weight)
        red = blend(red)
        green = blend(green)
        blue = blend(blue)
        brightness = blend(brightness)

        samples = (0..<count).map { index in
            guard weight[index] > 0 else {
                return Sample(colour: RGBColour(red: 1, green: 1, blue: 1), strength: 0)
            }
            var colour = RGBColour(
                red: pow(red[index] / weight[index], 1 / 2.2), green: pow(green[index] / weight[index], 1 / 2.2),
                blue: pow(blue[index] / weight[index], 1 / 2.2))
            // Where two colours far apart on the wheel run into each other
            // they come to white, which would be duller than either. Light
            // that meets is not dimmer for it: keep it as bright as its parts.
            let peak = max(colour.red, colour.green, colour.blue)
            if peak > 0 {
                let lift = min(brightness[index] / weight[index], 1) / peak
                colour = RGBColour(
                    red: min(1, colour.red * lift), green: min(1, colour.green * lift),
                    blue: min(1, colour.blue * lift))
            }
            return Sample(colour: colour, strength: 1 - exp(-Self.gain * (near[index] + far[index])))
        }
    }

    /// Adds `amount` at an angle, shared between the two samples it falls
    /// between, so that nothing jumps as a card's light moves round.
    private static func put(_ amount: Double, at angle: Double, into values: inout [Double], step: Double) {
        let count = values.count
        var position = (angle / step).truncatingRemainder(dividingBy: Double(count))
        if position < 0 { position += Double(count) }
        let lower = Int(position.rounded(.down)) % count
        let share = position - position.rounded(.down)
        values[lower] += amount * (1 - share)
        values[(lower + 1) % count] += amount * share
    }

    /// Reads a value at an angle, between the two samples it falls between.
    private static func value(of values: [Double], at angle: Double, step: Double) -> Double {
        let count = values.count
        var position = (angle / step).truncatingRemainder(dividingBy: Double(count))
        if position < 0 { position += Double(count) }
        let lower = Int(position.rounded(.down)) % count
        let share = position - position.rounded(.down)
        return values[lower] * (1 - share) + values[(lower + 1) % count] * share
    }

    /// Spreads each value round the rim in a bell `width` samples wide. The
    /// bell's top is 1, so a single value keeps its height.
    private static func spread(_ values: [Double], by width: Double) -> [Double] {
        let count = values.count
        let reach = min(Int((width * 3.5).rounded(.up)), count / 2)
        guard reach > 0, width > 0 else { return values }
        let bell = (-reach...reach).map { exp(-Double($0 * $0) / (2 * width * width)) }
        return (0..<count).map { index in
            var total = 0.0
            for offset in -reach...reach {
                total += values[((index + offset) % count + count) % count] * bell[offset + reach]
            }
            return total
        }
    }

    /// 0 at or below `low`, 1 at or above `high`, eased between.
    private static func smooth(_ low: Double, _ high: Double, _ value: Double) -> Double {
        guard high > low else { return value >= high ? 1 : 0 }
        let t = min(max((value - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
