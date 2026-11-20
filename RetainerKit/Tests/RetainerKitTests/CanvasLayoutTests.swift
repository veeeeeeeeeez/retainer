import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import RetainerKit

@Suite("Finding room on the canvas")
@MainActor
struct CanvasLayoutTests {

    private let card = CGSize(width: 400, height: 300)

    private func frame(at origin: CGPoint, _ size: CGSize? = nil) -> CGRect {
        CGRect(origin: origin, size: size ?? card)
    }

    // MARK: The rule

    @Test("An empty spot is used as it is")
    func idealWhenFree() {
        let origin = CanvasLayout.freeOrigin(for: card, near: CGPoint(x: 100, y: 50), avoiding: [])
        #expect(origin == CGPoint(x: -100, y: -100))

        // Something far away changes nothing.
        let far = [CGRect(x: 2000, y: 2000, width: 400, height: 300)]
        #expect(CanvasLayout.freeOrigin(for: card, near: CGPoint(x: 100, y: 50), avoiding: far) == origin)
    }

    @Test("A taken spot sends the card to the nearest side of what is there, lined up with it")
    func besideWhenTaken() {
        // A card wider than it is tall: the nearest clear place is underneath.
        let existing = CGRect(x: -200, y: -150, width: 400, height: 300)
        let origin = CanvasLayout.freeOrigin(for: card, near: .zero, avoiding: [existing])
        #expect(!CanvasLayout.crowds(frame(at: origin), existing))
        #expect(origin == CGPoint(x: existing.minX, y: existing.maxY + CanvasLayout.gap))

        // A card taller than it is wide: the nearest clear place is alongside,
        // to the right before the left, tops level.
        let tall = CGSize(width: 400, height: 560)
        let column = CGRect(x: -200, y: -280, width: 400, height: 560)
        let beside = CanvasLayout.freeOrigin(for: tall, near: .zero, avoiding: [column])
        #expect(beside == CGPoint(x: column.maxX + CanvasLayout.gap, y: column.minY))
    }

    @Test("Cards exactly one gap apart are not crowding; any closer and they are")
    func gapIsRespected() {
        let a = CGRect(x: 0, y: 0, width: 400, height: 300)
        #expect(!CanvasLayout.crowds(a, a.offsetBy(dx: 400 + CanvasLayout.gap, dy: 0)))
        #expect(CanvasLayout.crowds(a, a.offsetBy(dx: 400 + CanvasLayout.gap - 2, dy: 0)))
        #expect(!CanvasLayout.crowds(a, a.offsetBy(dx: 0, dy: 300 + CanvasLayout.gap)))
        #expect(CanvasLayout.crowds(a, a.offsetBy(dx: 30, dy: 30)))
    }

    @Test("A place inside the window is preferred to a nearer one outside it")
    func prefersTheViewport() {
        // A wide, short window with a card in the middle. The nearest clear
        // place is underneath it, but that is below the bottom of the window.
        let viewport = CGRect(x: 0, y: 0, width: 1400, height: 700)
        let existing = CGRect(x: 500, y: 200, width: 400, height: 300)
        let target = CGPoint(x: 700, y: 350)
        let origin = CanvasLayout.freeOrigin(for: card, near: target, avoiding: [existing], preferring: viewport)
        #expect(viewport.contains(frame(at: origin)))
        #expect(origin == CGPoint(x: existing.maxX + CanvasLayout.gap, y: existing.minY))

        // Without the window to respect, underneath wins.
        let unconstrained = CanvasLayout.freeOrigin(for: card, near: target, avoiding: [existing])
        #expect(unconstrained == CGPoint(x: existing.minX, y: existing.maxY + CanvasLayout.gap))
    }

    @Test("With no room in the window, the nearest place outside it is used")
    func fallsBackOutsideTheViewport() {
        let viewport = CGRect(x: 0, y: 0, width: 500, height: 400)
        let existing = CGRect(x: 50, y: 50, width: 400, height: 300)
        let origin = CanvasLayout.freeOrigin(
            for: card, near: CGPoint(x: 250, y: 200), avoiding: [existing], preferring: viewport)
        #expect(!CanvasLayout.crowds(frame(at: origin), existing))
    }

    @Test("Twenty cards saved at the same spot fill in around it without touching")
    func manyCardsNeverCrowd() {
        var placed: [CGRect] = []
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<20 {
            // Cards differ in height, as real ones do.
            let size = CGSize(width: 400, height: CGFloat(Int.random(in: 180...620, using: &generator)))
            let origin = CanvasLayout.freeOrigin(for: size, near: .zero, avoiding: placed)
            let frame = CGRect(origin: origin, size: size)
            for other in placed {
                #expect(!CanvasLayout.crowds(frame, other), "\(frame) crowds \(other)")
            }
            placed.append(frame)
        }
        // They stay together rather than marching off in one direction.
        let bounds = placed.reduce(CGRect.null) { $0.union($1) }
        #expect(bounds.width < 3200)
        #expect(bounds.height < 3200)
    }

    @Test("The same cards always go to the same places")
    func deterministic() {
        let occupied = [
            CGRect(x: -200, y: -150, width: 400, height: 300),
            CGRect(x: 224, y: -150, width: 400, height: 420),
            CGRect(x: -200, y: 174, width: 400, height: 260),
        ]
        let first = CanvasLayout.freeOrigin(for: card, near: .zero, avoiding: occupied)
        #expect(CanvasLayout.freeOrigin(for: card, near: .zero, avoiding: occupied.reversed()) == first)
        #expect(CanvasLayout.freeOrigin(for: card, near: .zero, avoiding: occupied.shuffled()) == first)
    }

    // MARK: The canvas

    /// The moment the sample notes are dated: 15 January 2027, 08:00 UTC.
    private static let noteTime = Date(timeIntervalSince1970: 1_800_000_000)
    private static let calendar = NoteStoreTests.calendar

    /// A canvas model that believes it is `now` (by default, later on the
    /// day the sample notes are dated), in the fixed test calendar.
    private func makeCanvas(now: Date = CanvasLayoutTests.noteTime.addingTimeInterval(4 * 3600))
        -> (CanvasModel, UserDefaults, String)
    {
        let suite = "retainer-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (CanvasModel(defaults: defaults, calendar: Self.calendar, now: { now }), defaults, suite)
    }

    private func makeStore(_ directory: URL) -> NoteStore {
        NoteStore(directory: directory, calendar: Self.calendar)
    }

    private func note(at point: CGPoint, text: String = "A note.", seen: Bool = true) -> Note {
        var note = NoteStoreTests.sampleNote(text: text, position: CanvasPoint(point))
        note.seen = seen
        return note
    }

    @Test("A new card goes to the middle of the window, then beside what is already there")
    func placementOnTheCanvas() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1400, height: 1100))

        let size = CGSize(width: CanvasModel.nodeWidth, height: 320)
        let first = canvas.placementForNewNote(size: size, among: [])
        // Centred in the window.
        #expect(canvas.viewPoint(for: CGPoint(x: first.x + 200, y: first.y + 160)) == CGPoint(x: 700, y: 550))

        var notes = [note(at: first)]
        canvas.setMeasuredHeight(320, for: notes[0].id)
        for _ in 0..<5 {
            let origin = canvas.placementForNewNote(size: size, among: notes)
            let frame = CGRect(origin: origin, size: size)
            for other in notes {
                #expect(!CanvasLayout.crowds(frame, canvas.frame(of: other)))
            }
            let added = note(at: origin)
            canvas.setMeasuredHeight(320, for: added.id)
            notes.append(added)
        }
        // Nine cards of this size fit in the window round the first, so none
        // of these six was put out of sight.
        let visible = try! #require(canvas.visibleRect)
        for placed in notes {
            #expect(visible.contains(canvas.frame(of: placed)))
        }
    }

    @Test("A card's measured height replaces the estimate")
    func measuredHeightWins() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let sample = note(at: CGPoint(x: 10, y: 20))
        let estimated = canvas.frame(of: sample)
        #expect(estimated.origin == CGPoint(x: 10, y: 20))
        #expect(estimated.width == CanvasModel.nodeWidth)
        #expect(estimated.height == NodeLayout.estimatedHeight(imageAspectRatio: 800.0 / 600.0, note: "A note."))
        // A card with a link under its screenshot is one small line taller.
        var linked = sample
        linked.sourceURL = "https://example.com/an-article"
        let extra = canvas.frame(of: linked).height - estimated.height
        #expect(extra > 8 && extra < 24)

        canvas.setMeasuredHeight(512, for: sample.id)
        #expect(canvas.frame(of: sample).height == 512)
        canvas.forget(sample.id)
        #expect(canvas.frame(of: sample).height == estimated.height)
    }

    @Test("An estimated height is kept until the note it was worked out from changes")
    func estimateFollowsTheNote() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        var sample = note(at: .zero, text: "Short.")
        let short = canvas.frame(of: sample).height
        #expect(canvas.frame(of: sample).height == short)

        // The same card with a note that runs to three lines is taller.
        sample.note = String(repeating: "A good deal more to say about this. ", count: 6)
        let long = canvas.frame(of: sample).height
        #expect(long > short + 20)
        #expect(long == NodeLayout.estimatedHeight(imageAspectRatio: 800.0 / 600.0, note: sample.note))

        // And back again.
        sample.note = "Short."
        #expect(canvas.frame(of: sample).height == short)
    }

    // MARK: Estimated height

    /// The card as it is really laid out, measured by rendering it.
    private func renderedHeight(of note: Note) throws -> CGFloat {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let view = NodeView(note: note, scale: 1)
            .environment(makeStore(directory))
            .environment(canvas)
            .environment(ImageCache())
            .fixedSize()
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try #require(renderer.cgImage)
        #expect(image.width == Int(CanvasModel.nodeWidth))
        return CGFloat(image.height)
    }

    @Test("The estimate is within a few points of the real card", arguments: [
        "Short one. Keep this number.",
        "",
        "The claim in the second paragraph rests on a sample of forty people. I would not quote it without the follow-up study.\n\nThings to check:\n\n- who funded it\n- whether the effect survives controlling for age\n- the original survey wording",
        "This is the clearest diagram of the pipeline I have seen. The **retry path** is the part we got wrong last quarter.",
        String(repeating: "A longer thought that runs on for several lines so the paragraph has to wrap more than once. ", count: 6),
        "First paragraph.\n\nSecond paragraph, a little longer than the first so that it wraps onto another line.\n\n1. one\n2. two\n3. three",
    ])
    func estimateMatchesRendering(text: String) throws {
        for (link, seen) in [(nil, true), ("https://example.com/an-article", false)] {
            var sample = note(at: .zero, text: text)
            sample.imagePixelSize = PixelSize(width: 1520, height: 720)
            sample.sourceURL = link
            sample.seen = seen
            let estimate = NodeLayout.estimatedHeight(
                imageAspectRatio: sample.imageAspectRatio, note: text, hasSourceLink: link != nil)
            let real = try renderedHeight(of: sample)
            // The small card shows at most three lines of the note, so the
            // estimate can be close: never short, never more than a line over.
            #expect(estimate >= real - 3, "estimated \(estimate), really \(real)")
            #expect(estimate <= real + 24, "estimated \(estimate), really \(real)")
        }
    }

    @Test("However long the note, the small card stops at three lines of it")
    func longNotesDoNotGrowTheCard() throws {
        let short = "One line."
        let long = String(repeating: "A long note that goes on and on, far past what a small card should show. ", count: 30)
        let three = NodeLayout.estimatedHeight(imageAspectRatio: 2, note: long)
        let one = NodeLayout.estimatedHeight(imageAspectRatio: 2, note: short)
        #expect(three > one)
        #expect(three - one < 60)
        #expect(NodeLayout.estimatedHeight(imageAspectRatio: 2, note: long + long) == three)

        var sample = note(at: .zero, text: long)
        sample.imagePixelSize = PixelSize(width: 1600, height: 800)
        #expect(abs(try renderedHeight(of: sample) - three) <= 3)
    }

    @Test("The preview of a note is its text run together, without the Markdown")
    func previewText() {
        #expect(NotePreview.text(for: "") == "")
        #expect(NotePreview.text(for: "  \n ") == "")
        #expect(NotePreview.text(for: "Just a line.") == "Just a line.")
        #expect(NotePreview.text(for: "This is **bold** and *slanted*.") == "This is bold and slanted.")
        #expect(
            NotePreview.text(for: "First.\n\nSecond, on\nits own lines.\n\n- one\n- two\n\n1. first")
                == "First. Second, on its own lines. – one – two 1. first")
        #expect(NotePreview.text(for: "# A heading\n\nBody.") == "A heading Body.")
    }

    // MARK: Seen

    @Test("A new card counts as seen after it has been in view for a moment")
    func seenAfterDwell() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        // The window's middle is the canvas origin, so this card is in view…
        let inView = note(at: CGPoint(x: -200, y: -150), seen: false)
        // …and this one is far off to the right.
        let away = note(at: CGPoint(x: 5000, y: 0), seen: false)
        #expect(canvas.isInView(inView))
        #expect(!canvas.isInView(away))

        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(canvas.notesSeen(among: [inView, away], now: start).isEmpty)
        #expect(canvas.notesSeen(among: [inView, away], now: start.addingTimeInterval(0.6)).isEmpty)
        #expect(canvas.notesSeen(among: [inView, away], now: start.addingTimeInterval(1.3)) == [inView.id])
    }

    @Test("A card that scrolls out of view before then starts again from nothing")
    func dwellResets() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        let card = note(at: CGPoint(x: -200, y: -150), seen: false)
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(canvas.notesSeen(among: [card], now: start).isEmpty)
        canvas.pan(by: CGSize(width: 4000, height: 0))
        #expect(canvas.notesSeen(among: [card], now: start.addingTimeInterval(0.5)).isEmpty)
        canvas.pan(by: CGSize(width: -4000, height: 0))
        // Back in view at 1.0 s: the clock starts here, not at the beginning.
        #expect(canvas.notesSeen(among: [card], now: start.addingTimeInterval(1.0)).isEmpty)
        #expect(canvas.notesSeen(among: [card], now: start.addingTimeInterval(1.5)).isEmpty)
        #expect(canvas.notesSeen(among: [card], now: start.addingTimeInterval(2.3)) == [card.id])

        // Looking away (another window, the archive) also starts it again.
        let other = note(at: CGPoint(x: -200, y: -150), seen: false)
        #expect(canvas.notesSeen(among: [other], now: start).isEmpty)
        canvas.resetSeenTracking()
        #expect(canvas.notesSeen(among: [other], now: start.addingTimeInterval(2)).isEmpty)
    }

    @Test("A card only partly in the window is not seen; one larger than the window is")
    func partialVisibility() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        // Only its left quarter is inside the right-hand edge of the window.
        let sliver = note(at: CGPoint(x: 500, y: -150), seen: false)
        #expect(!canvas.isInView(sliver))
        // Zoomed right in, a card cannot fit, but it fills the window.
        canvas.zoom(by: 2, around: CGPoint(x: 600, y: 400))
        let filling = note(at: CGPoint(x: -200, y: -150), seen: false)
        canvas.setMeasuredHeight(700, for: filling.id)
        #expect(canvas.isInView(filling))
    }

    @Test("Next new note goes round the unseen cards and scrolls each into the middle")
    func nextUnseenCycles() {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        let store = makeStore(directory)

        var older = note(at: CGPoint(x: 3000, y: 0), seen: false)
        older.timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        var newer = note(at: CGPoint(x: -3000, y: 900), seen: false)
        newer.timestamp = Date(timeIntervalSince1970: 1_800_000_500)
        store.add(newer)
        store.add(older)
        store.add(note(at: .zero))

        canvas.showingArchive = true
        #expect(canvas.showNextUnseen(in: store)?.id == older.id)
        #expect(!canvas.showingArchive)
        let frame = canvas.frame(of: older)
        let middle = canvas.viewPoint(for: CGPoint(x: frame.midX, y: frame.midY))
        #expect(abs(middle.x - 600) <= 1 && abs(middle.y - 400) <= 1)
        #expect(canvas.isInView(older))

        #expect(canvas.showNextUnseen(in: store)?.id == newer.id)
        #expect(canvas.showNextUnseen(in: store)?.id == older.id)
        store.markSeen([older.id])
        #expect(canvas.showNextUnseen(in: store)?.id == newer.id)
        store.markSeen([newer.id])
        #expect(canvas.showNextUnseen(in: store) == nil)
    }

    // MARK: The opened card

    @Test("Opening a card counts as seeing it, and can go straight to editing or to confirming a delete")
    func openingACard() {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(directory)
        let fresh = note(at: .zero, seen: false)
        store.add(fresh)

        canvas.expand(fresh.id, in: store)
        #expect(canvas.expandedNoteID == fresh.id)
        #expect(canvas.editingNoteID == nil)
        #expect(canvas.confirmingDeleteID == nil)
        #expect(store.unseenNotes.isEmpty)

        canvas.expand(fresh.id, in: store, editing: true)
        #expect(canvas.editingNoteID == fresh.id)
        canvas.expand(fresh.id, in: store, confirmingDelete: true)
        #expect(canvas.editingNoteID == nil)
        #expect(canvas.confirmingDeleteID == fresh.id)

        canvas.collapse()
        #expect(canvas.expandedNoteID == nil)
        #expect(canvas.confirmingDeleteID == nil)

        // A note that does not exist cannot be opened.
        canvas.expand(UUID(), in: store)
        #expect(canvas.expandedNoteID == nil)
    }

    @Test("The opened card closes when its note is archived or deleted, or another board or the archive is shown")
    func openedCardCloses() throws {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(directory)
        let one = note(at: .zero)
        let two = note(at: CGPoint(x: 600, y: 0))
        store.add(one)
        store.add(two)

        canvas.expand(one.id, in: store, editing: true)
        canvas.archive(one, in: store)
        #expect(canvas.expandedNoteID == nil)
        #expect(canvas.editingNoteID == nil)

        canvas.expand(two.id, in: store)
        canvas.showingArchive = true
        #expect(canvas.expandedNoteID == nil)

        canvas.showingArchive = false
        canvas.expand(two.id, in: store)
        canvas.show(Period.containing(Self.noteTime, scale: .week, calendar: Self.calendar))
        #expect(canvas.expandedNoteID == nil)

        canvas.expand(two.id, in: store)
        canvas.viewingNoteID = two.id
        canvas.forget(two.id)
        #expect(canvas.expandedNoteID == nil)
        #expect(canvas.viewingNoteID == nil)
    }

    // MARK: Boards by day, week, month and all time

    @Test("The window opens on today's board")
    func startsOnToday() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(canvas.timeScale == .day)
        #expect(canvas.period == Period.containing(Self.noteTime, scale: .day, calendar: Self.calendar))
        #expect(canvas.period.id == "day:2027-01-15")
        #expect(canvas.isShowingToday)
        #expect(!canvas.needsFit)

        canvas.show(canvas.period.stepped(by: -1, calendar: Self.calendar))
        #expect(canvas.period.id == "day:2027-01-14")
        #expect(!canvas.isShowingToday)
        canvas.show(Period.containing(Self.noteTime, scale: .week, calendar: Self.calendar))
        #expect(!canvas.isShowingToday)
        #expect(canvas.timeScale == .week)
    }

    @Test("Each board keeps its own pan and zoom, across switches and relaunches")
    func viewportPerBoard() async throws {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let today = canvas.period
        let yesterday = today.stepped(by: -1, calendar: Self.calendar)
        canvas.setViewSize(CGSize(width: 1000, height: 600))

        canvas.pan(by: CGSize(width: -320, height: 90))
        canvas.zoom(by: 1.5, around: CGPoint(x: 500, y: 300))
        let todayOffset = canvas.offset
        let todayScale = canvas.scale

        // A day never shown before: 100%, origin in the middle of the window.
        canvas.showingArchive = true
        canvas.show(yesterday)
        #expect(canvas.scale == 1)
        #expect(canvas.offset == CGSize(width: 500, height: 300))
        #expect(!canvas.showingArchive)
        #expect(!canvas.needsFit)
        canvas.pan(by: CGSize(width: 40, height: 40))

        canvas.show(today)
        #expect(canvas.offset == todayOffset)
        #expect(canvas.scale == todayScale)
        canvas.show(yesterday)
        #expect(canvas.offset == CGSize(width: 540, height: 340))

        // Written a moment later; a new launch starts on today with today's own.
        try await Task.sleep(for: .milliseconds(600))
        let relaunched = CanvasModel(
            defaults: defaults, calendar: Self.calendar, now: { Self.noteTime.addingTimeInterval(4 * 3600) })
        #expect(relaunched.period == today)
        #expect(relaunched.offset == todayOffset)
        #expect(relaunched.scale == todayScale)
        relaunched.show(yesterday)
        #expect(relaunched.offset == CGSize(width: 540, height: 340))
    }

    @Test("A week's board is fitted to the window the first time, and is then left as it was put")
    func widerBoardsAreFitted() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        let week = Period.containing(Self.noteTime, scale: .week, calendar: Self.calendar)

        canvas.show(week)
        #expect(canvas.needsFit)
        let board = CGRect(x: 0, y: 0, width: 4000, height: 2400)
        canvas.fit(board)
        #expect(!canvas.needsFit)
        #expect(canvas.scale < 1)
        // All of it is inside the window, clear of the timeline at the top
        // and of the input box at the bottom.
        let topLeft = canvas.viewPoint(for: board.origin)
        let bottomRight = canvas.viewPoint(for: CGPoint(x: board.maxX, y: board.maxY))
        #expect(topLeft.x >= 0)
        #expect(topLeft.y >= CanvasModel.topClearance)
        #expect(bottomRight.x <= 1200)
        #expect(bottomRight.y <= 800 - CanvasModel.inputClearance)

        // A small board is not blown up past its real size.
        canvas.show(Period.containing(Self.noteTime, scale: .month, calendar: Self.calendar))
        canvas.fit(CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(canvas.scale == 1)

        // Panning a board is as good as having placed it: it is not fitted again.
        canvas.show(Period.containing(Self.noteTime, scale: .all, calendar: Self.calendar))
        #expect(canvas.needsFit)
        canvas.pan(by: CGSize(width: 10, height: 0))
        #expect(!canvas.needsFit)

        // Coming back to the week, it is where it was left.
        let fitted = canvas.scale
        canvas.show(week)
        #expect(!canvas.needsFit)
        #expect(canvas.scale != fitted || canvas.scale < 1)
    }

    @Test("Recenter brings the cards back into view from wherever the board has been left")
    func recenter() throws {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1400, height: 1100))
        let store = makeStore(directory)

        /// Whether every card is wholly in the window, clear of the timeline and the input box.
        func allInView(_ frames: [CGRect]) -> Bool {
            frames.allSatisfy { frame in
                let topLeft = canvas.viewPoint(for: frame.origin)
                let bottomRight = canvas.viewPoint(for: CGPoint(x: frame.maxX, y: frame.maxY))
                return topLeft.x >= 0 && bottomRight.x <= 1400 && topLeft.y >= CanvasModel.topClearance
                    && bottomRight.y <= 1100 - CanvasModel.inputClearance
            }
        }

        // An empty board goes back to how it starts: its own middle in the middle, at 100%.
        canvas.pan(by: CGSize(width: 5000, height: -3000))
        canvas.zoom(by: 0.5, around: CGPoint(x: 200, y: 100))
        canvas.recenter(in: store)
        #expect(canvas.scale == 1)
        #expect(canvas.visibleCentre == .zero)

        // Two cards side by side. Scrolled a long way off and zoomed out, none of them is in view.
        store.add(note(at: CGPoint(x: 300, y: 200)))
        store.add(note(at: CGPoint(x: 760, y: 260)))
        let cards = canvas.notes(in: store).map { canvas.frame(of: $0) }
        canvas.pan(by: CGSize(width: -9000, height: 7000))
        canvas.zoom(by: 0.3, around: CGPoint(x: 700, y: 550))
        #expect(Whereabouts.directions(to: cards, from: canvas.visibleRect).count == 1)

        // Back they come, at full size since they fit at that, and nothing points anywhere any more.
        canvas.recenter(in: store)
        #expect(canvas.scale == 1)
        #expect(allInView(cards))
        #expect(Whereabouts.directions(to: cards, from: canvas.visibleRect).isEmpty)
        // Doing it again changes nothing.
        let (offset, scale) = (canvas.offset, canvas.scale)
        canvas.recenter(in: store)
        #expect(canvas.offset == offset && canvas.scale == scale)

        // A third card too far from the others for all three to fit at full size: smaller, and all in view.
        store.add(note(at: CGPoint(x: 6000, y: 3000)))
        let spread = canvas.notes(in: store).map { canvas.frame(of: $0) }
        canvas.zoom(by: 2, around: CGPoint(x: 0, y: 0))
        canvas.recenter(in: store)
        #expect(canvas.scale < 1)
        #expect(allInView(spread))

        // A board of several days is fitted the way it is when it is first opened.
        var earlier = note(at: CGPoint(x: 100, y: 100))
        earlier.timestamp = Self.noteTime.addingTimeInterval(-2 * 86_400)
        store.add(earlier)
        canvas.show(Period.containing(Self.noteTime, scale: .month, calendar: Self.calendar))
        canvas.pan(by: CGSize(width: 40_000, height: -20_000))
        canvas.recenter(in: store)
        let month = canvas.notes(in: store)
        let drawn = canvas.drawnFrames(of: month, layout: canvas.layout(of: month), groups: canvas.groups(in: store))
        #expect(drawn.count == 4)
        #expect(allInView(drawn.map(\.frame)))
    }

    @Test("Next new note goes to the board of the day it was saved on")
    func nextUnseenGoesToItsDay() throws {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        let store = makeStore(directory)

        var earlier = note(at: CGPoint(x: 2000, y: 2000), seen: false)
        earlier.timestamp = Self.noteTime.addingTimeInterval(-3 * 86_400)
        let today = note(at: CGPoint(x: -900, y: 0), seen: false)
        store.add(earlier)
        store.add(today)

        // The one on the board in front comes first, though it is the newer.
        #expect(canvas.showNextUnseen(in: store)?.id == today.id)
        #expect(canvas.isShowingToday)
        #expect(canvas.showNextUnseen(in: store)?.id == earlier.id)
        #expect(canvas.period.id == "day:2027-01-12")
        #expect(canvas.isInView(earlier))

        // From a week's board it still lands on the day.
        canvas.show(Period.containing(Self.noteTime, scale: .week, calendar: Self.calendar))
        store.markSeen([earlier.id])
        #expect(canvas.showNextUnseen(in: store)?.id == today.id)
        #expect(canvas.timeScale == .day)
        #expect(canvas.isShowingToday)
    }

    @Test("A new note goes on today's board, even while another board is on screen")
    func placementWhileLookingElsewhere() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        let size = CGSize(width: CanvasModel.nodeWidth, height: 320)
        let existing = note(at: CGPoint(x: 1000, y: 1000))
        canvas.setMeasuredHeight(320, for: existing.id)

        // Looking at today: the middle of the window, which is clear.
        #expect(canvas.placementForNewNote(size: size, among: [existing]) == CGPoint(x: -200, y: -160))

        // Looking at another day, scrolled somewhere else entirely: beside
        // what is already on today's board, wherever this window is pointing.
        canvas.show(canvas.period.stepped(by: -1, calendar: Self.calendar))
        canvas.pan(by: CGSize(width: -5000, height: 0))
        let placed = CGRect(origin: canvas.placementForNewNote(size: size, among: [existing]), size: size)
        #expect(!CanvasLayout.crowds(placed, canvas.frame(of: existing)))
        #expect(abs(placed.midX - 1200) < 900 && abs(placed.midY - 1160) < 900)
        // With nothing on today's board yet: its origin.
        #expect(canvas.placementForNewNote(size: size, among: []) == CGPoint(x: -200, y: -160))
    }

    @Test("Cards drawn as day clusters are tracked where they are drawn")
    func displayedFrames() {
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        canvas.setViewSize(CGSize(width: 1200, height: 800))
        let card = note(at: CGPoint(x: 5000, y: 5000), seen: false)
        #expect(!canvas.isInView(card))
        // On a week's board the card is drawn in its day's block, near the origin.
        canvas.setDisplayedOrigins([card.id: CGPoint(x: -200, y: -150)])
        #expect(canvas.displayedFrame(of: card).origin == CGPoint(x: -200, y: -150))
        #expect(canvas.isInView(card))
        // Its own place on its day's board is untouched.
        #expect(canvas.frame(of: card).origin == CGPoint(x: 5000, y: 5000))
    }

    // MARK: Archive

    @Test("Archiving takes a card off the canvas; restoring puts it back where it was")
    func archiveAndRestore() {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(directory)
        let first = note(at: CGPoint(x: 0, y: 0))
        let second = note(at: CGPoint(x: 424, y: 0), seen: false)
        store.add(first)
        store.add(second)
        canvas.editingNoteID = second.id

        canvas.archive(second, in: store)
        #expect(store.activeNotes.map(\.id) == [first.id])
        #expect(store.archivedNotes.map(\.id) == [second.id])
        #expect(store.unseenNotes.isEmpty)
        #expect(canvas.editingNoteID == nil)
        #expect(store.archivedNotes[0].position == CanvasPoint(x: 424, y: 0))

        canvas.restore(store.archivedNotes[0], in: store)
        #expect(store.archivedNotes.isEmpty)
        #expect(store.notes.first { $0.id == second.id }?.position == CanvasPoint(x: 424, y: 0))
    }

    @Test("A card restored to a place that has been taken goes beside it instead")
    func restoreIntoOccupiedSpace() {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(directory)
        let archived = note(at: CGPoint(x: 0, y: 0))
        store.add(archived)
        canvas.archive(archived, in: store)

        // Something else is saved where it used to be.
        let squatter = note(at: CGPoint(x: 20, y: 30))
        store.add(squatter)

        canvas.restore(store.archivedNotes[0], in: store)
        let restored = try! #require(store.notes.first { $0.id == archived.id })
        #expect(!restored.isArchived)
        #expect(!CanvasLayout.crowds(canvas.frame(of: restored), canvas.frame(of: squatter)))
    }

    @Test("Two cards archived from the same place do not end up on top of each other")
    func archiveKeepsCardsApart() {
        let directory = NoteStoreTests.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (canvas, defaults, suite) = makeCanvas()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = makeStore(directory)
        let first = note(at: .zero)
        store.add(first)
        canvas.archive(first, in: store)
        let second = note(at: CGPoint(x: 12, y: 8))
        store.add(second)
        canvas.archive(second, in: store)

        let archived = store.archivedNotes
        #expect(archived.count == 2)
        #expect(!CanvasLayout.crowds(canvas.frame(of: archived[0]), canvas.frame(of: archived[1])))
    }
}

/// A small deterministic generator, so "random" layouts are the same every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        var value = state
        value ^= value >> 33
        value = value &* 0xFF51_AFD7_ED55_8CCD
        value ^= value >> 33
        return value
    }
}
