import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Timeline: boards by day, week, month and all time")
@MainActor
struct TimelineTests {

    private let calendar = NoteStoreTests.calendar
    /// Wednesday 18 November 2026, mid-afternoon.
    private let now = NoteStoreTests.date(2026, 11, 18, hour: 15)

    private func note(_ text: String, _ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Note {
        NoteStoreTests.sampleNote(text: text, on: NoteStoreTests.date(year, month, day, hour: hour))
    }

    // MARK: Periods

    @Test("A day, a week and a month each start and end where the calendar says")
    func periodBounds() {
        let day = Period.containing(now, scale: .day, calendar: calendar)
        #expect(day.id == "day:2026-11-18")
        #expect(day.start == NoteStoreTests.date(2026, 11, 18, hour: 0))
        #expect(day.end == NoteStoreTests.date(2026, 11, 19, hour: 0))
        #expect(day.contains(NoteStoreTests.date(2026, 11, 18, hour: 23, minute: 59)))
        #expect(!day.contains(day.end))

        // Weeks run Monday to Sunday in this calendar.
        let week = Period.containing(now, scale: .week, calendar: calendar)
        #expect(week.id == "week:2026-11-16")
        #expect(week.contains(NoteStoreTests.date(2026, 11, 22, hour: 23)))
        #expect(!week.contains(NoteStoreTests.date(2026, 11, 15, hour: 23)))

        let month = Period.containing(now, scale: .month, calendar: calendar)
        #expect(month.id == "month:2026-11-01")
        #expect(month.contains(NoteStoreTests.date(2026, 11, 30, hour: 23)))
        #expect(!month.contains(NoteStoreTests.date(2026, 12, 1, hour: 0)))

        let all = Period.containing(now, scale: .all, calendar: calendar)
        #expect(all.id == "all")
        #expect(all.contains(.distantPast.addingTimeInterval(1)))
        #expect(all.contains(NoteStoreTests.date(2031, 1, 1)))

        // Any moment of a period names the same period.
        #expect(Period.containing(NoteStoreTests.date(2026, 11, 18, hour: 1), scale: .day, calendar: calendar) == day)
        #expect(Period.containing(NoteStoreTests.date(2026, 11, 20), scale: .week, calendar: calendar) == week)
    }

    @Test("Stepping moves a whole day, week or month at a time, across month and year ends")
    func stepping() {
        let day = Period.containing(now, scale: .day, calendar: calendar)
        #expect(day.stepped(by: -1, calendar: calendar).id == "day:2026-11-17")
        #expect(day.stepped(by: 13, calendar: calendar).id == "day:2026-12-01")
        #expect(day.stepped(by: -18, calendar: calendar).id == "day:2026-10-31")

        let week = Period.containing(now, scale: .week, calendar: calendar)
        #expect(week.stepped(by: -1, calendar: calendar).id == "week:2026-11-09")
        #expect(week.stepped(by: 7, calendar: calendar).id == "week:2027-01-04")

        let month = Period.containing(now, scale: .month, calendar: calendar)
        #expect(month.stepped(by: -1, calendar: calendar).id == "month:2026-10-01")
        #expect(month.stepped(by: 2, calendar: calendar).id == "month:2027-01-01")

        let all = Period.containing(now, scale: .all, calendar: calendar)
        #expect(all.stepped(by: -3, calendar: calendar) == all)
    }

    @Test("Periods are named the way one would say them")
    func names() {
        func period(_ year: Int, _ month: Int, _ day: Int, _ scale: TimeScale) -> Period {
            Period.containing(NoteStoreTests.date(year, month, day), scale: scale, calendar: calendar)
        }
        func title(_ period: Period) -> String { period.title(now: now, calendar: calendar) }
        func short(_ period: Period) -> String { period.shortTitle(now: now, calendar: calendar) }

        #expect(title(period(2026, 11, 18, .day)) == "Today")
        #expect(title(period(2026, 11, 17, .day)) == "Yesterday")
        #expect(title(period(2026, 11, 16, .day)) == "Monday 16 November")
        #expect(title(period(2025, 12, 31, .day)) == "Wednesday 31 December 2025")
        #expect(short(period(2026, 11, 18, .day)) == "Today")
        #expect(short(period(2026, 11, 16, .day)) == "Mon 16")

        #expect(title(period(2026, 11, 18, .week)) == "This week")
        #expect(title(period(2026, 11, 11, .week)) == "Last week")
        #expect(title(period(2026, 11, 4, .week)) == "2 – 8 November")
        // A week that straddles two months names both.
        #expect(title(period(2026, 10, 28, .week)) == "26 October – 1 November")
        #expect(short(period(2026, 11, 4, .week)) == "2–8 Nov")
        #expect(short(period(2026, 10, 28, .week)) == "26 Oct–1 Nov")
        #expect(short(period(2026, 11, 18, .week)) == "This week")

        #expect(title(period(2026, 11, 18, .month)) == "November 2026")
        #expect(short(period(2026, 10, 18, .month)) == "Oct")
        #expect(short(period(2025, 12, 18, .month)) == "Dec ’25")

        #expect(title(period(2026, 11, 18, .all)) == "All time")
        #expect(short(period(2026, 11, 18, .all)) == "All time")
    }

    // MARK: Tiles

    @Test("The timeline has a tile for every day with notes, oldest first, and always one for today")
    func dayTiles() {
        var fresh = note("yesterday, new", 2026, 11, 17, hour: 20)
        fresh.seen = false
        var put = note("yesterday, archived", 2026, 11, 17, hour: 9)
        put.archivedAt = now
        let notes = [
            note("monday a", 2026, 11, 16, hour: 9), fresh, note("october", 2026, 10, 30),
            note("monday b", 2026, 11, 16, hour: 18), put,
        ]
        let entries = Timeline.entries(notes: notes, scale: .day, now: now, calendar: calendar)

        #expect(entries.map(\.id) == ["day:2026-10-30", "day:2026-11-16", "day:2026-11-17", "day:2026-11-18"])
        // Today is there with nothing on it yet.
        #expect(entries.last?.count == 0)
        #expect(entries.last?.cover.isEmpty == true)
        // A day's notes are newest first; archived ones are not on the board.
        #expect(entries[1].notes.map(\.note) == ["monday b", "monday a"])
        #expect(entries[2].notes.map(\.note) == ["yesterday, new"])
        #expect(entries[2].unseenCount == 1)
        #expect(entries[1].unseenCount == 0)
    }

    @Test("Weeks, months and all time gather the same notes into fewer tiles")
    func widerTiles() {
        let notes = [
            note("monday", 2026, 11, 16), note("last sunday", 2026, 11, 15), note("early november", 2026, 11, 3),
            note("october a", 2026, 10, 30), note("october b", 2026, 10, 2), note("last year", 2025, 12, 31),
        ]
        let weeks = Timeline.entries(notes: notes, scale: .week, now: now, calendar: calendar)
        #expect(
            weeks.map(\.id) == [
                "week:2025-12-29", "week:2026-09-28", "week:2026-10-26", "week:2026-11-02", "week:2026-11-09",
                "week:2026-11-16",
            ])
        #expect(weeks.last?.notes.map(\.note) == ["monday"])

        let months = Timeline.entries(notes: notes, scale: .month, now: now, calendar: calendar)
        #expect(months.map(\.id) == ["month:2025-12-01", "month:2026-10-01", "month:2026-11-01"])
        #expect(months.last?.count == 3)
        // The collage is the newest three.
        #expect(months.last?.cover.map(\.note) == ["monday", "last sunday", "early november"])

        let all = Timeline.entries(notes: notes, scale: .all, now: now, calendar: calendar)
        #expect(all.map(\.id) == ["all"])
        #expect(all[0].count == 6)
        #expect(all[0].cover.map(\.note) == ["monday", "last sunday", "early november"])

        // With nothing saved at all there is still the present to stand on.
        #expect(Timeline.entries(notes: [], scale: .week, now: now, calendar: calendar).map(\.id) == ["week:2026-11-16"])
    }

    @Test("Notes group by the day they were saved on")
    func daysOfNotes() {
        let notes = [
            note("b", 2026, 11, 16, hour: 18), note("c", 2026, 11, 17), note("a", 2026, 11, 16, hour: 9),
        ]
        let days = Timeline.days(of: notes, calendar: calendar)
        #expect(days.map(\.day) == [NoteStoreTests.date(2026, 11, 16, hour: 0), NoteStoreTests.date(2026, 11, 17, hour: 0)])
        #expect(days[0].notes.map(\.note) == ["a", "b"])
        #expect(days[1].notes.map(\.note) == ["c"])
    }

    // MARK: Several days on one board

    private func frames(_ rects: [CGRect]) -> [(id: UUID, frame: CGRect)] {
        rects.map { (UUID(), $0) }
    }

    @Test("Each day keeps its own arrangement and gets a place of its own under its date")
    func clustersKeepTheirShape() {
        let monday = NoteStoreTests.date(2026, 11, 16, hour: 0)
        let tuesday = NoteStoreTests.date(2026, 11, 17, hour: 0)
        // Monday: two cards side by side, far from the origin of its own board.
        let mondayFrames = frames([
            CGRect(x: 3000, y: -500, width: 400, height: 300), CGRect(x: 3424, y: -500, width: 400, height: 420),
        ])
        let tuesdayFrames = frames([CGRect(x: -200, y: -150, width: 400, height: 360)])
        let layout = ClusterLayout.arrange(days: [(monday, mondayFrames), (tuesday, tuesdayFrames)])

        #expect(layout.headers.map(\.day) == [monday, tuesday])
        #expect(layout.headers.map(\.count) == [2, 1])
        // The first block starts at the board's origin, cards under the header.
        let first = try! #require(layout.positions[mondayFrames[0].id])
        let second = try! #require(layout.positions[mondayFrames[1].id])
        #expect(first == CGPoint(x: 0, y: ClusterLayout.headerHeight))
        // The two cards are still side by side, the same distance apart.
        #expect(second.x - first.x == 424)
        #expect(second.y == first.y)

        // Tuesday's block is to the right, clear of Monday's.
        let third = try! #require(layout.positions[tuesdayFrames[0].id])
        #expect(third.x == 824 + ClusterLayout.gap)
        #expect(layout.headers[1].origin == CGPoint(x: 824 + ClusterLayout.gap, y: 0))
        #expect(layout.bounds == CGRect(x: 0, y: 0, width: 824 + ClusterLayout.gap + 400, height: ClusterLayout.headerHeight + 420))
    }

    @Test("Many days wrap into rows, in order, and no day's block touches another's")
    func clustersWrapIntoRows() {
        var days: [(day: Date, frames: [(id: UUID, frame: CGRect)])] = []
        for index in 0..<12 {
            let day = NoteStoreTests.date(2026, 11, 1 + index, hour: 0)
            // One to three cards in a row, of varying height.
            let cards = (0...(index % 3)).map { column in
                CGRect(x: CGFloat(column) * 424, y: 0, width: 400, height: CGFloat(260 + (index * 37) % 240))
            }
            days.append((day, frames(cards)))
        }
        let layout = ClusterLayout.arrange(days: days)
        #expect(layout.headers.count == 12)
        #expect(layout.positions.count == days.reduce(0) { $0 + $1.frames.count })

        // Blocks, from their headers and the cards under them.
        var blocks: [CGRect] = []
        for (header, day) in zip(layout.headers, days) {
            var block = CGRect(origin: header.origin, size: CGSize(width: header.width, height: ClusterLayout.headerHeight))
            for item in day.frames {
                let origin = try! #require(layout.positions[item.id])
                block = block.union(CGRect(origin: origin, size: item.frame.size))
                // Every card is under its own day's header.
                #expect(origin.y >= header.origin.y + ClusterLayout.headerHeight)
                #expect(origin.x >= header.origin.x)
            }
            blocks.append(block)
        }
        for (index, block) in blocks.enumerated() {
            for other in blocks[(index + 1)...] {
                #expect(!block.insetBy(dx: -40, dy: -40).intersects(other), "\(block) is too close to \(other)")
            }
        }
        // More than one row, each row read left to right, rows read top to bottom.
        let rows = Set(layout.headers.map(\.origin.y)).sorted()
        #expect(rows.count > 1)
        for (earlier, later) in zip(layout.headers, layout.headers.dropFirst()) {
            #expect(later.origin.y > earlier.origin.y || later.origin.x > earlier.origin.x)
        }
        // Wider than it is tall, as a window is.
        #expect(layout.bounds.width > layout.bounds.height)

        // A row width can be asked for: narrow enough, and every day gets its own row.
        let column = ClusterLayout.arrange(days: days, rowWidth: 100)
        #expect(Set(column.headers.map(\.origin.x)) == [0])
        #expect(Set(column.headers.map(\.origin.y)).count == 12)
    }

    @Test("A board with nothing on it has no layout")
    func emptyLayout() {
        let layout = ClusterLayout.arrange(days: [])
        #expect(layout.headers.isEmpty)
        #expect(layout.positions.isEmpty)
        #expect(layout.bounds.isNull)
        // A day with no cards is skipped rather than given an empty block.
        let skipped = ClusterLayout.arrange(days: [(now, [])])
        #expect(skipped.headers.isEmpty)
    }

    @Test("The canvas lays a week out from the cards' real frames")
    func canvasLayout() {
        let suite = "retainer-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let canvas = CanvasModel(defaults: defaults, calendar: calendar, now: { self.now })

        var monday = note("monday", 2026, 11, 16)
        monday.position = CanvasPoint(x: 900, y: 900)
        var tuesday = note("tuesday", 2026, 11, 17)
        tuesday.position = CanvasPoint(x: -50, y: 40)
        canvas.setMeasuredHeight(500, for: monday.id)

        let layout = canvas.layout(of: [tuesday, monday])
        #expect(layout.headers.count == 2)
        #expect(layout.positions[monday.id] == CGPoint(x: 0, y: ClusterLayout.headerHeight))
        #expect(layout.positions[tuesday.id] == CGPoint(x: 400 + ClusterLayout.gap, y: ClusterLayout.headerHeight))
        // Monday's block is as tall as its card was measured to be.
        #expect(layout.bounds.height == ClusterLayout.headerHeight + 500)
    }

    // MARK: Sample days

    @Test("Sample days are the same every time, never today, and tidy")
    func sampleDays() {
        let samples = SampleDays.samples(now: now, calendar: calendar)
        let again = SampleDays.samples(now: now, calendar: calendar)
        #expect(samples.map(\.note) == again.map(\.note))
        #expect(samples.count > 30)
        #expect(Set(samples.map(\.note.id)).count == samples.count)

        let today = Period.containing(now, scale: .day, calendar: calendar)
        let yesterday = today.stepped(by: -1, calendar: calendar)
        #expect(!samples.contains { today.contains($0.note.timestamp) })
        #expect(samples.filter { yesterday.contains($0.note.timestamp) }.count >= 3)
        // All in the past, none further back than they are meant to go.
        let earliest = today.stepped(by: -SampleDays.reach, calendar: calendar).start
        #expect(samples.allSatisfy { $0.note.timestamp < today.start && $0.note.timestamp >= earliest })
        #expect(samples.allSatisfy { $0.note.seen && !$0.note.isArchived })

        // Within a day no card is on top of another.
        for (_, notes) in Timeline.days(of: samples.map(\.note), calendar: calendar) {
            let frames = notes.map { note in
                CGRect(
                    origin: note.position.cgPoint,
                    size: CGSize(
                        width: CanvasModel.nodeWidth,
                        height: NodeLayout.estimatedHeight(
                            imageAspectRatio: note.imageAspectRatio, note: note.note,
                            hasSourceLink: note.sourceURL != nil)))
            }
            for (index, frame) in frames.enumerated() {
                for other in frames[(index + 1)...] {
                    #expect(!CanvasLayout.crowds(frame, other))
                }
            }
        }
        // Some days are quiet: there are gaps in the timeline, as there would be.
        let days = Timeline.days(of: samples.map(\.note), calendar: calendar).count
        #expect(days < SampleDays.reach)
        #expect(days > SampleDays.reach / 3)
    }

    @Test("A day's samples do not change as the day recedes")
    func sampleDaysAreStable() {
        let tomorrow = now.addingTimeInterval(86_400)
        let monday = Period.containing(NoteStoreTests.date(2026, 11, 16), scale: .day, calendar: calendar)
        let seenToday = SampleDays.samples(now: now, calendar: calendar).filter { monday.contains($0.note.timestamp) }
        let seenTomorrow = SampleDays.samples(now: tomorrow, calendar: calendar)
            .filter { monday.contains($0.note.timestamp) }
        #expect(seenToday.map(\.note) == seenTomorrow.map(\.note))
        // What was today has, by tomorrow, become a sample day like any other... or a quiet one.
        let today = Period.containing(now, scale: .day, calendar: calendar)
        #expect(SampleDays.samples(now: now, calendar: calendar).filter { today.contains($0.note.timestamp) }.isEmpty)
    }

    @Test("Sample pictures are drawn once, and the samples load into a store with them")
    func sampleImages() async throws {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pictures = directory.appendingPathComponent("pictures", isDirectory: true)
        let samples = Array(SampleDays.samples(now: now, calendar: calendar).prefix(3))

        SampleDays.writeMissingImages(for: samples, to: pictures)
        for sample in samples {
            let url = pictures.appendingPathComponent("\(sample.note.id.uuidString).png")
            let image = try #require(ImageFiles.load(url, maxPixelSize: nil))
            #expect(image.width == sample.note.imagePixelSize.width)
            #expect(image.height == sample.note.imagePixelSize.height)
        }
        // A second call leaves the files alone.
        let url = pictures.appendingPathComponent("\(samples[0].note.id.uuidString).png")
        let written = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        SampleDays.writeMissingImages(for: samples, to: pictures)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == written)

        let store = NoteStore(directory: directory.appendingPathComponent("store"), calendar: calendar)
        store.setSampleNotes(samples.map(\.note), imagesIn: pictures)
        #expect(store.imageURL(for: samples[0].note) == url)
        SampleDays.remove(from: store)
        #expect(store.allNotes.isEmpty)
    }
}
