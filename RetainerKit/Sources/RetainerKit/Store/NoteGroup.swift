import CoreGraphics
import Foundation

/// Several cards put together on one board and shown there as one tile.
///
/// A group belongs to the board it was made on: a day's board, or a canvas.
/// The notes in it are not changed, only shown differently on that board: in
/// place of their cards there is one tile made of their pictures. On any
/// other board they are on (their day, another canvas) they are as they were.
public struct NoteGroup: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Which board it is on, as `Board.id`: "day:2026-11-19" or "canvas:…".
    public var board: String
    /// The notes in it, in the order they were added.
    public var noteIDs: [UUID]
    /// Top-left corner of its tile on that board.
    public var position: CanvasPoint
    public var createdAt: Date

    public init(
        id: UUID = UUID(), name: String, board: String, noteIDs: [UUID], position: CanvasPoint,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.board = board
        self.noteIDs = noteIDs
        self.position = position
        self.createdAt = createdAt
    }
}

/// Sets several pictures out as one: rows of them, each row as wide as the
/// whole, with no picture squeezed out of its shape more than a little.
///
/// The pictures are taken in order and split into rows so that every row
/// holds about the same amount of width. A row's natural height is whatever
/// makes its pictures, side by side at their own shapes, exactly fill the
/// width. The number of rows is whichever brings the natural height of the
/// whole closest to the space there is, and what is left over is taken up by
/// stretching the rows a little (each picture then fills its cell, cropped).
public enum GroupMosaic {

    /// The most pictures shown; a group with more shows these and says how
    /// many are left.
    public static let most = 9

    /// A cell for each picture (the first `most` of them), tiling `size`.
    /// `aspects` are width over height.
    public static func layout(aspects: [CGFloat], in size: CGSize, gap: CGFloat = 3) -> [CGRect] {
        let shown = Array(aspects.prefix(most)).map { min(max($0, 0.4), 3.2) }
        guard !shown.isEmpty, size.width > 0, size.height > 0 else { return [] }

        var best: (rows: [[CGFloat]], distance: CGFloat)?
        for count in 1...min(shown.count, 4) {
            let rows = split(shown, into: count)
            let natural = rows.reduce(CGFloat(0)) { total, row in
                let width = size.width - gap * CGFloat(row.count - 1)
                return total + width / row.reduce(0, +)
            } + gap * CGFloat(rows.count - 1)
            let distance = abs(log(natural / size.height))
            if best == nil || distance < best!.distance { best = (rows, distance) }
        }
        guard let rows = best?.rows else { return [] }

        // Natural heights, scaled to fill the height exactly.
        let naturals = rows.map { row in
            (size.width - gap * CGFloat(row.count - 1)) / row.reduce(0, +)
        }
        let available = size.height - gap * CGFloat(rows.count - 1)
        let stretch = available / naturals.reduce(0, +)

        var cells: [CGRect] = []
        var y: CGFloat = 0
        for (row, natural) in zip(rows, naturals) {
            let height = natural * stretch
            let width = size.width - gap * CGFloat(row.count - 1)
            let total = row.reduce(0, +)
            var x: CGFloat = 0
            for aspect in row {
                let share = width * aspect / total
                cells.append(CGRect(x: x, y: y, width: share, height: height))
                x += share + gap
            }
            y += height + gap
        }
        return cells
    }

    /// A tile for a group that has cards of words in it as well as, or in
    /// place of, pictures. A card of words has no picture to show, so it is
    /// a small square chip. The pictures tile the space as `layout` has
    /// them, less a slim strip along the bottom where the chips sit in a
    /// row; with no pictures at all the chips are in the middle. As many
    /// chips as fit across are shown.
    public static func arrange(
        pictures aspects: [CGFloat], words: Int, in size: CGSize, gap: CGFloat = 3, chip: CGFloat = 34
    ) -> (pictures: [CGRect], chips: [CGRect]) {
        guard words > 0, size.width > 0, size.height > 0, chip > 0 else {
            return (layout(aspects: aspects, in: size, gap: gap), [])
        }
        let side = min(chip, size.width, size.height)
        let between = max(gap, (side * 0.16).rounded())
        let shown = min(words, max(1, Int((size.width + between) / (side + between))))
        let run = CGFloat(shown) * side + CGFloat(shown - 1) * between

        if aspects.isEmpty {
            let x = ((size.width - run) / 2).rounded()
            let y = ((size.height - side) / 2).rounded()
            return ([], (0..<shown).map { CGRect(x: x + CGFloat($0) * (side + between), y: y, width: side, height: side) })
        }
        let above = CGSize(width: size.width, height: max(1, size.height - side - between))
        return (
            layout(aspects: aspects, in: above, gap: gap),
            (0..<shown).map {
                CGRect(x: CGFloat($0) * (side + between), y: size.height - side, width: side, height: side)
            }
        )
    }

    /// Splits values, in order, into `count` runs of about equal total.
    static func split(_ values: [CGFloat], into count: Int) -> [[CGFloat]] {
        guard count > 1 else { return [values] }
        let target = values.reduce(0, +) / CGFloat(count)
        var rows: [[CGFloat]] = [[]]
        var running: CGFloat = 0
        for (index, value) in values.enumerated() {
            let left = values.count - index
            let rowsLeft = count - rows.count
            // Start a new row once this one has its share, as long as there
            // is enough left to give every later row something.
            if !rows[rows.count - 1].isEmpty, rowsLeft > 0,
                running + value / 2 > target || left <= rowsLeft
            {
                rows.append([])
                running = 0
            }
            rows[rows.count - 1].append(value)
            running += value
        }
        return rows
    }
}
