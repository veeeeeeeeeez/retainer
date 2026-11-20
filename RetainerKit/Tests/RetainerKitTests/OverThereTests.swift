import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Every card out of view: which way they are")
struct OverThereTests {

    /// The part of the board in view. Its middle is at (2700, 1950).
    private let viewport = CGRect(x: 2000, y: 1500, width: 1400, height: 900)

    private func card(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 400, height: 300)
    }

    /// How far apart two directions are, the short way round.
    private func turn(_ a: Double, _ b: Double) -> Double {
        var difference = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if difference > .pi { difference -= 2 * .pi }
        if difference < -.pi { difference += 2 * .pi }
        return abs(difference)
    }

    @Test("Nothing is said while any part of a card can be seen, or with no cards at all")
    func onlyWhenNothingIsInView() {
        let far = card(-4000, -3000)
        #expect(Whereabouts.directions(to: [], from: viewport).isEmpty)
        #expect(Whereabouts.directions(to: [far], from: nil).isEmpty)
        // One card wholly in view, among others that are not.
        #expect(Whereabouts.directions(to: [far, card(2400, 1800)], from: viewport).isEmpty)
        // A sliver of one showing at the left edge is still a card in view.
        #expect(Whereabouts.directions(to: [far, card(1610, 1800)], from: viewport).isEmpty)
        // The same card moved just out says where it went.
        #expect(Whereabouts.directions(to: [card(1590, 1800)], from: viewport).count == 1)
    }

    @Test("One card is pointed at: straight up when it is above the middle, on the slant when it is off to one side")
    func oneCard() throws {
        // Above, over the middle of the view: straight up, which on screen is a quarter turn back.
        let above = try #require(Whereabouts.directions(to: [card(2500, 600)], from: viewport).first)
        #expect(turn(above, -.pi / 2) < 0.001)

        // Up and to the left: towards its nearest corner, (1400, 1100), from the middle.
        let corner = try #require(Whereabouts.directions(to: [card(1000, 800)], from: viewport).first)
        #expect(turn(corner, atan2(1100 - 1950, 1400 - 2700)) < 0.001)

        // Level with the view, off to the right.
        let right = try #require(Whereabouts.directions(to: [card(5000, 1800)], from: viewport).first)
        #expect(turn(right, 0) < 0.001)
    }

    @Test("Cards that lie the same way are one direction, towards the middle of them")
    func oneWay() throws {
        // A column of cards off to the left, from well above the view to well below it.
        let column = stride(from: CGFloat(600), through: 3000, by: 320).map { card(900, $0) }
        let ways = Whereabouts.directions(to: column, from: viewport)
        #expect(ways.count == 1)
        #expect(turn(try #require(ways.first), .pi) < 0.2)

        // A far-off cluster is one direction however many cards are in it.
        let cluster = (0..<30).map { card(-9000 + CGFloat($0 % 6) * 430, -7000 + CGFloat($0 / 6) * 330) }
        let far = Whereabouts.directions(to: cluster, from: viewport)
        #expect(far.count == 1)
        #expect(turn(try #require(far.first), atan2(-7000 - 1950, -9000 - 2700)) < 0.2)
    }

    @Test("Cards with a gap between them are a direction each, the way with most to find first")
    func severalWays() {
        // Three cards to the left, one to the right.
        let left = [card(600, 1500), card(600, 1850), card(600, 2200)]
        let ways = Whereabouts.directions(to: left + [card(4200, 1800)], from: viewport)
        #expect(ways.count == 2)
        #expect(turn(ways[0], .pi) < 0.15)
        #expect(turn(ways[1], 0) < 0.001)

        // A cluster that straddles the place where angles wrap round is not cut in two.
        #expect(Whereabouts.directions(to: [card(600, 1700), card(600, 2050)], from: viewport).count == 1)
    }

    @Test("Never more than three chevrons; ringed all round by cards, the nearest is pointed at")
    func manyWays() throws {
        // Six cards well apart, all round.
        let around = (0..<6).map { index -> CGRect in
            let angle = Double(index) * .pi / 3
            return card(2500 + 2600 * cos(angle), 1800 + 2600 * sin(angle))
        }
        #expect(Whereabouts.directions(to: around, from: viewport).count == 3)
        #expect(Whereabouts.directions(to: around, from: viewport, most: 1).count == 1)

        // A close ring with no gap in it, and one card nearer than the rest, to the right.
        var ring = (0..<48).map { index -> CGRect in
            let angle = Double(index) * .pi / 24
            return card(2500 + 3000 * cos(angle), 1800 + 3000 * sin(angle))
        }
        ring.append(card(3500, 1800))
        let ways = Whereabouts.directions(to: ring, from: viewport)
        #expect(ways.count == 1)
        #expect(turn(try #require(ways.first), 0) < 0.001)
    }

    @Test("A direction has a name to be read out")
    func names() {
        #expect(Whereabouts.name(of: 0) == "to the right")
        #expect(Whereabouts.name(of: .pi / 2) == "below")
        #expect(Whereabouts.name(of: -.pi / 2) == "above")
        #expect(Whereabouts.name(of: .pi) == "to the left" && Whereabouts.name(of: -.pi) == "to the left")
        #expect(Whereabouts.name(of: -3 * .pi / 4) == "above and to the left")
    }
}
