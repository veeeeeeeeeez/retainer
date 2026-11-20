import CoreGraphics
import Foundation

/// How much time one board covers.
public enum TimeScale: String, CaseIterable, Sendable {
    case day, week, month, all

    /// The word on the switch.
    public var title: String {
        switch self {
        case .day: "day"
        case .week: "week"
        case .month: "month"
        case .all: "all"
        }
    }
}

/// One stretch of time whose notes share a board: a day, a week, a month, or
/// everything there is.
///
/// Notes are not filed anywhere. A note belongs to the day it was saved on,
/// and so to the week and month that day falls in.
public struct Period: Hashable, Sendable, Identifiable {

    public let scale: TimeScale
    /// The first moment of the period.
    public let start: Date
    /// The first moment after it.
    public let end: Date
    /// Stable across launches: the scale and the date the period starts on.
    public let id: String

    /// The day, week or month that `date` falls in, or all time.
    public static func containing(_ date: Date, scale: TimeScale, calendar: Calendar) -> Period {
        let component: Calendar.Component
        switch scale {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .all:
            return Period(scale: .all, start: .distantPast, end: .distantFuture, id: "all")
        }
        let interval =
            calendar.dateInterval(of: component, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
        let parts = calendar.dateComponents([.year, .month, .day], from: interval.start)
        let stamp = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        return Period(scale: scale, start: interval.start, end: interval.end, id: "\(scale.rawValue):\(stamp)")
    }

    public func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// The period `count` days, weeks or months later (earlier, if negative).
    public func stepped(by count: Int, calendar: Calendar) -> Period {
        let component: Calendar.Component
        switch scale {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        case .all: return self
        }
        // From the middle of the period, so a change of clocks cannot land on the boundary.
        let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let moved = calendar.date(byAdding: component, value: count, to: middle) ?? middle
        return Period.containing(moved, scale: scale, calendar: calendar)
    }

    // MARK: Names

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// The period in full, for the status bar and the headers on a board:
    /// "Today", "Yesterday", "Monday 16 November"; "This week", "9 – 15
    /// November"; "November 2026"; "All time".
    public func title(now: Date, calendar: Calendar) -> String {
        switch scale {
        case .day:
            if contains(now) { return "Today" }
            if stepped(by: 1, calendar: calendar).contains(now) { return "Yesterday" }
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            return Self.formatter(sameYear ? "EEEE d MMMM" : "EEEE d MMMM yyyy", calendar).string(from: start)
        case .week:
            if contains(now) { return "This week" }
            if stepped(by: 1, calendar: calendar).contains(now) { return "Last week" }
            return Self.range(start, end.addingTimeInterval(-1), calendar: calendar, long: true)
        case .month:
            return Self.formatter("MMMM yyyy", calendar).string(from: start)
        case .all:
            return "All time"
        }
    }

    /// The period in a few characters, for a tile of the timeline: "Today",
    /// "Mon 16"; "This week", "9–15 Nov"; "Nov", "Dec ’25"; "All time".
    public func shortTitle(now: Date, calendar: Calendar) -> String {
        switch scale {
        case .day:
            if contains(now) { return "Today" }
            return Self.formatter("EEE d", calendar).string(from: start)
        case .week:
            if contains(now) { return "This week" }
            return Self.range(start, end.addingTimeInterval(-1), calendar: calendar, long: false)
        case .month:
            let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
            return Self.formatter(sameYear ? "MMM" : "MMM ’yy", calendar).string(from: start)
        case .all:
            return "All time"
        }
    }

    /// A day in the fewest characters that still say which: "Today",
    /// "16 Nov", "31 Dec ’25". For a header with very little room.
    public func compactDayTitle(now: Date, calendar: Calendar) -> String {
        if scale == .day, contains(now) { return "Today" }
        let sameYear = calendar.component(.year, from: start) == calendar.component(.year, from: now)
        return Self.formatter(sameYear ? "d MMM" : "d MMM ’yy", calendar).string(from: start)
    }

    /// "9 – 15 November", or "30 November – 6 December" across a month end.
    private static func range(_ first: Date, _ last: Date, calendar: Calendar, long: Bool) -> String {
        let month = long ? "MMMM" : "MMM"
        let dash = long ? " – " : "–"
        let sameMonth = calendar.component(.month, from: first) == calendar.component(.month, from: last)
        let head = formatter(sameMonth ? "d" : "d \(month)", calendar).string(from: first)
        let tail = formatter("d \(month)", calendar).string(from: last)
        return head + dash + tail
    }
}

/// One tile of the timeline: a period and the notes on its board.
public struct TimelineEntry: Identifiable, Equatable, Sendable {
    public let period: Period
    /// The period's notes that are on the board, newest first.
    public let notes: [Note]

    public var id: String { period.id }
    public var count: Int { notes.count }
    public var unseenCount: Int { notes.filter { !$0.seen }.count }
    /// The newest few, for the tile's collage.
    public var cover: [Note] { Array(notes.prefix(3)) }
}

public enum Timeline {

    /// The tiles for one scale: a tile for every period that has notes on
    /// its board, oldest first, and always one for the period `now` is in,
    /// which comes last. Archived notes are not counted.
    public static func entries(
        notes: [Note], scale: TimeScale, now: Date, calendar: Calendar
    ) -> [TimelineEntry] {
        let current = Period.containing(now, scale: scale, calendar: calendar)
        var byPeriod: [Period: [Note]] = [current: []]
        for note in notes where !note.isArchived {
            byPeriod[Period.containing(note.timestamp, scale: scale, calendar: calendar), default: []].append(note)
        }
        return byPeriod
            .map { TimelineEntry(period: $0.key, notes: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.period.start < $1.period.start }
    }

    /// The notes grouped by the day they were saved on, oldest day first,
    /// each day's notes in the order they were saved.
    public static func days(of notes: [Note], calendar: Calendar) -> [(day: Date, notes: [Note])] {
        var byDay: [Date: [Note]] = [:]
        for note in notes {
            byDay[calendar.startOfDay(for: note.timestamp), default: []].append(note)
        }
        return byDay.keys.sorted().map { day in
            (day, byDay[day]!.sorted { $0.timestamp < $1.timestamp })
        }
    }
}

/// Where everything goes on a board that shows several days at once.
public struct BoardLayout: Equatable, Sendable {

    /// The date over one day's cards.
    public struct Header: Identifiable, Equatable, Sendable {
        public let day: Date
        /// Top-left corner of the header, on the board.
        public let origin: CGPoint
        /// How wide the day's cluster is.
        public let width: CGFloat
        public let count: Int

        public var id: Date { day }
    }

    /// Top-left corner of each card on the board.
    public var positions: [UUID: CGPoint] = [:]
    public var headers: [Header] = []
    /// The rectangle everything fits in, or `.null` when the board is empty.
    public var bounds: CGRect = .null

    public init() {}
}

/// Sets several days' boards out on one board.
///
/// Each day keeps its own arrangement: its cards stay where they are in
/// relation to one another, moved as a block. The blocks are laid out in
/// reading order, oldest first, in rows, each under a header with its date,
/// so every day sits in a place of its own.
public enum ClusterLayout {

    /// Room above each day's cards for its date.
    public static let headerHeight: CGFloat = 64
    /// Clear space between one day's block and the next.
    public static let gap: CGFloat = 140
    /// A day with one narrow card still gets a block this wide, so its header fits.
    static let minimumWidth: CGFloat = 400

    /// The shape the whole arrangement aims for: wider than tall, like a window.
    static let targetAspect: CGFloat = 1.6

    /// - Parameters:
    ///   - days: each day with the frames of its cards on that day's own board.
    ///   - rowWidth: how wide a row may grow before the next day starts a new
    ///     one. Left out, the width is chosen that brings the whole closest
    ///     to `targetAspect`.
    public static func arrange(
        days: [(day: Date, frames: [(id: UUID, frame: CGRect)])], rowWidth: CGFloat? = nil
    ) -> BoardLayout {
        let blocks: [Block] = days.compactMap { entry in
            guard !entry.frames.isEmpty else { return nil }
            let bounds = entry.frames.reduce(CGRect.null) { $0.union($1.frame) }
            return Block(day: entry.day, frames: entry.frames, bounds: bounds)
        }
        guard !blocks.isEmpty else { return BoardLayout() }
        if let rowWidth { return flow(blocks, limit: rowWidth) }

        // Try a first row of one day, of two, of three, and so on, and keep
        // whichever comes out closest to the shape wanted.
        var best: (layout: BoardLayout, distance: CGFloat)?
        var limit: CGFloat = 0
        for block in blocks {
            limit += block.width
            let candidate = flow(blocks, limit: limit)
            let aspect = candidate.bounds.width / max(candidate.bounds.height, 1)
            let distance = abs(log(aspect / targetAspect))
            if best == nil || distance < best!.distance { best = (candidate, distance) }
            limit += gap
        }
        return best?.layout ?? BoardLayout()
    }

    /// One day's cards as a block: the header's room, then the cards.
    private struct Block {
        let day: Date
        let frames: [(id: UUID, frame: CGRect)]
        let bounds: CGRect
        var width: CGFloat { max(bounds.width, ClusterLayout.minimumWidth) }
        var height: CGFloat { ClusterLayout.headerHeight + bounds.height }
    }

    /// Lays blocks out left to right, starting a new row whenever the next
    /// would pass `limit`.
    private static func flow(_ blocks: [Block], limit: CGFloat) -> BoardLayout {
        var layout = BoardLayout()
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for block in blocks {
            if x > 0, x + block.width > limit + 0.5 {
                x = 0
                y += rowHeight + gap
                rowHeight = 0
            }
            let origin = CGPoint(x: x.rounded(), y: y.rounded())
            layout.headers.append(
                BoardLayout.Header(day: block.day, origin: origin, width: block.width, count: block.frames.count))
            for item in block.frames {
                layout.positions[item.id] = CGPoint(
                    x: (origin.x + item.frame.minX - block.bounds.minX).rounded(),
                    y: (origin.y + headerHeight + item.frame.minY - block.bounds.minY).rounded())
            }
            layout.bounds = layout.bounds.union(
                CGRect(x: origin.x, y: origin.y, width: block.width, height: block.height))
            x += block.width + gap
            rowHeight = max(rowHeight, block.height)
        }
        return layout
    }
}
