import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Groups of cards")
@MainActor
struct GroupTests {

    @MainActor
    private final class Fixture {
        let suite: String
        let directory: URL
        let defaults: UserDefaults
        let store: NoteStore
        let canvas: CanvasModel

        init() {
            suite = "retainer-tests-\(UUID().uuidString)"
            directory = NoteStoreTests.temporaryDirectory()
            defaults = UserDefaults(suiteName: suite)!
            store = NoteStore(directory: directory, calendar: NoteStoreTests.calendar)
            // The model's "now" is the day the test notes are saved on.
            canvas = CanvasModel(
                defaults: defaults, calendar: NoteStoreTests.calendar, now: { GroupTests.day.addingTimeInterval(3600) })
            canvas.setViewSize(CGSize(width: 1400, height: 900))
        }

        /// A note saved on the test day, at a place on its board.
        func note(_ text: String, at point: CGPoint) -> Note {
            let note = NoteStoreTests.sampleNote(text: text, on: GroupTests.day, at: point)
            store.add(note)
            return note
        }

        func cleanUp() {
            store.flush()
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    static let day = NoteStoreTests.date(2026, 11, 19)
    private var dayKey: String { "day:2026-11-19" }

    // MARK: The picture of a group

    @Test("A group's pictures tile its space exactly: every one shown, none overlapping, nothing left over")
    func mosaicTiles() {
        let size = CGSize(width: 448, height: 288)
        let gap: CGFloat = 3
        for aspects: [CGFloat] in [
            [1.6], [1.6, 1.6], [2.1, 1.0, 0.7], [1.0, 1.0, 1.0, 1.0], [3.2, 0.5, 1.4, 1.4, 2.0],
            [1.3, 1.3, 1.3, 1.3, 1.3, 1.3, 1.3], [0.6, 0.6, 2.4, 1.0, 1.8, 0.9, 1.2, 1.5, 2.0],
        ] {
            let cells = GroupMosaic.layout(aspects: aspects, in: size, gap: gap)
            #expect(cells.count == aspects.count)
            let whole = CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01)
            #expect(cells.allSatisfy { whole.contains($0) && $0.width > 8 && $0.height > 8 })
            for (index, cell) in cells.enumerated() {
                for other in cells.dropFirst(index + 1) {
                    let overlap = cell.intersection(other)
                    #expect(overlap.isNull || overlap.width < 0.01 || overlap.height < 0.01)
                }
            }
            // Rows reach both sides and the last one reaches the bottom.
            #expect(abs((cells.map(\.maxX).max() ?? 0) - size.width) < 0.01)
            #expect(abs((cells.map(\.maxY).max() ?? 0) - size.height) < 0.01)
            #expect(cells.map(\.minX).min() == 0 && cells.map(\.minY).min() == 0)
        }
    }

    @Test("No picture is squeezed far out of its own shape, and a big group shows its first nine")
    func mosaicKeepsShapes() {
        let size = CGSize(width: 448, height: 288)
        let aspects: [CGFloat] = [1.9, 1.0, 1.5, 2.1, 0.8, 1.2]
        let cells = GroupMosaic.layout(aspects: aspects, in: size)
        for (cell, aspect) in zip(cells, aspects) {
            let shown = cell.width / cell.height
            #expect(shown / aspect > 0.55 && shown / aspect < 1.8)
        }
        #expect(GroupMosaic.layout(aspects: Array(repeating: 1.5, count: 14), in: size).count == GroupMosaic.most)
        #expect(GroupMosaic.layout(aspects: [], in: size).isEmpty)
        let alone = GroupMosaic.layout(aspects: [0.7], in: size)
        #expect(alone == [CGRect(origin: .zero, size: size)])
    }

    @Test("A card of words in a group is a small square chip under the pictures, or in the middle when there are none")
    func mosaicWithWords() {
        let size = CGSize(width: 448, height: 288)
        let whole = CGRect(origin: .zero, size: size).insetBy(dx: -0.01, dy: -0.01)

        // Nothing but pictures: exactly as before.
        let plain = GroupMosaic.arrange(pictures: [1.6, 1.0, 2.0], words: 0, in: size)
        #expect(plain.pictures == GroupMosaic.layout(aspects: [1.6, 1.0, 2.0], in: size) && plain.chips.isEmpty)

        // Pictures and three cards of words: three chips, small and square, in a row along the bottom,
        // and the pictures tiling everything above them without touching them.
        let mixed = GroupMosaic.arrange(pictures: [1.6, 1.0, 2.0, 1.3], words: 3, in: size)
        #expect(mixed.pictures.count == 4 && mixed.chips.count == 3)
        #expect(mixed.chips.allSatisfy { $0.width == 34 && $0.height == 34 && whole.contains($0) })
        #expect(mixed.chips.allSatisfy { $0.maxY == size.height })
        #expect(mixed.chips[0].minX == 0 && mixed.chips[1].minX > mixed.chips[0].maxX)
        let top = mixed.chips[0].minY
        #expect(mixed.pictures.allSatisfy { whole.contains($0) && $0.maxY < top })
        #expect(abs((mixed.pictures.map(\.maxX).max() ?? 0) - size.width) < 0.01)

        // Only words: the chips are a row in the middle.
        let words = GroupMosaic.arrange(pictures: [], words: 2, in: size)
        #expect(words.pictures.isEmpty && words.chips.count == 2)
        #expect(abs((words.chips[0].minX + words.chips[1].maxX) / 2 - size.width / 2) <= 1)
        #expect(abs(words.chips[0].midY - size.height / 2) <= 1)

        // More than fit across: as many as do, for the last to say how many more.
        let many = GroupMosaic.arrange(pictures: [1.5], words: 40, in: size)
        #expect(many.chips.count < 40 && many.chips.count >= 8)
        #expect(many.chips.allSatisfy { whole.contains($0) })

        // The chips grow and shrink with the tile.
        let small = GroupMosaic.arrange(pictures: [1.5], words: 1, in: CGSize(width: 224, height: 144), chip: 17)
        #expect(small.chips == [CGRect(x: 0, y: 127, width: 17, height: 17)])
    }

    // MARK: The store

    @Test("A group needs two notes, has a name and a place, and survives a relaunch")
    func makeAndReload() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let one = f.note("one", at: CGPoint(x: 0, y: 0))
        let two = f.note("two", at: CGPoint(x: 600, y: 0))

        #expect(f.store.makeGroup(on: dayKey, of: [one.id], at: .zero) == nil)
        #expect(f.store.makeGroup(on: dayKey, of: [one.id, one.id], at: .zero) == nil)
        let group = try #require(f.store.makeGroup(on: dayKey, of: [one.id, two.id], at: CGPoint(x: 40, y: 50)))
        f.store.renameGroup(id: group.id, to: "  Pricing pages ")
        f.store.moveGroup(id: group.id, to: CGPoint(x: 90, y: 10))
        f.store.flush()

        let again = NoteStore(directory: f.directory, calendar: NoteStoreTests.calendar)
        let loaded = try #require(again.groups.first)
        #expect(again.groups.count == 1)
        #expect(loaded.name == "Pricing pages" && loaded.board == dayKey)
        #expect(loaded.noteIDs == [one.id, two.id])
        #expect(loaded.position == CanvasPoint(x: 90, y: 10))
        // The notes themselves are as they were.
        #expect(again.note(one.id)?.position == CanvasPoint(x: 0, y: 0))
    }

    @Test("A note is in one group on a board; taken out, a group of one is no longer a group")
    func membership() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let notes = (0..<4).map { f.note("n\($0)", at: CGPoint(x: Double($0) * 600, y: 0)) }
        let first = try #require(f.store.makeGroup(on: dayKey, of: [notes[0].id, notes[1].id], at: .zero))
        let second = try #require(f.store.makeGroup(on: dayKey, of: [notes[2].id, notes[3].id], at: .zero))

        // Added to another group on the same board, it leaves the first, which then ends.
        f.store.addToGroup(noteID: notes[0].id, groupID: second.id)
        #expect(f.store.group(first.id) == nil)
        #expect(f.store.group(second.id)?.noteIDs == [notes[2].id, notes[3].id, notes[0].id])
        #expect(f.store.group(holding: notes[0].id, on: dayKey)?.id == second.id)
        #expect(f.store.group(holding: notes[1].id, on: dayKey) == nil)

        f.store.removeFromGroup(noteID: notes[0].id, groupID: second.id)
        #expect(f.store.group(second.id)?.noteIDs.count == 2)
        // Deleting a note takes it out of its group, and that can end the group.
        f.store.delete(id: notes[2].id)
        #expect(f.store.groups.isEmpty)
        #expect(f.store.note(notes[3].id) != nil)
    }

    @Test("A group on a canvas is that canvas's own, and goes when the canvas does or the card leaves it")
    func canvasGroups() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let one = f.note("one", at: .zero)
        let two = f.note("two", at: CGPoint(x: 600, y: 0))
        let three = f.note("three", at: CGPoint(x: 1200, y: 0))
        let project = f.store.addProject(name: "Thesis")
        let target = try #require(f.store.addCanvas(in: project.id, name: "Outline"))
        for note in [one, two, three] { f.store.place(noteID: note.id, on: target.id, at: .zero) }
        let key = Board.canvas(target.id).id
        let group = try #require(f.store.makeGroup(on: key, of: [one.id, two.id, three.id], at: CGPoint(x: 5, y: 6)))

        // On the canvas they are together; on their day they are not.
        f.canvas.show(.canvas(target.id))
        #expect(f.canvas.groups(in: f.store).map(\.id) == [group.id])
        #expect(f.canvas.notes(in: f.store).allSatisfy { $0.position == CanvasPoint(x: 5, y: 6) })
        f.canvas.show(f.canvas.period)
        #expect(f.canvas.groups(in: f.store).isEmpty)
        #expect(f.canvas.notes(in: f.store).map(\.position.x) == [0, 600, 1200])

        // Taken off the canvas, a card is out of the group there.
        f.store.remove(noteID: three.id, from: target.id)
        #expect(f.store.group(group.id)?.noteIDs == [one.id, two.id])
        f.store.deleteCanvas(id: target.id)
        #expect(f.store.groups.isEmpty)
    }

    // MARK: On the board

    @Test("Grouped cards sit where their group is, on their day's board and on the week's")
    func groupedCardsOnBoards() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let one = f.note("one", at: CGPoint(x: 0, y: 0))
        let two = f.note("two", at: CGPoint(x: 600, y: 0))
        let apart = f.note("apart", at: CGPoint(x: 1300, y: 0))
        let group = try #require(f.store.makeGroup(on: dayKey, of: [one.id, two.id], at: CGPoint(x: 200, y: 80)))

        let shown = f.canvas.notes(in: f.store)
        #expect(shown.first { $0.id == one.id }?.position == CanvasPoint(x: 200, y: 80))
        #expect(shown.first { $0.id == two.id }?.position == CanvasPoint(x: 200, y: 80))
        #expect(shown.first { $0.id == apart.id }?.position == CanvasPoint(x: 1300, y: 0))
        let entry = try #require(f.canvas.groups(in: f.store).first)
        #expect(entry.members.map(\.id) == [one.id, two.id])
        #expect(f.canvas.frame(of: group).size == CanvasModel.groupSize)

        // The week that day is in shows the group too; another day does not.
        f.canvas.show(Period.containing(Self.day, scale: .week, calendar: NoteStoreTests.calendar))
        #expect(f.canvas.groups(in: f.store).map(\.id) == [group.id])
        f.canvas.show(Period.containing(Self.day.addingTimeInterval(-3 * 86_400), scale: .day, calendar: NoteStoreTests.calendar))
        #expect(f.canvas.groups(in: f.store).isEmpty)

        // An archived card is out of sight; the group shows what is left.
        f.canvas.show(Period.containing(Self.day, scale: .day, calendar: NoteStoreTests.calendar))
        f.store.archive(id: two.id)
        #expect(f.canvas.groups(in: f.store).first?.members.map(\.id) == [one.id])
        f.canvas.showingArchive = true
        #expect(f.canvas.groups(in: f.store).isEmpty)
    }

    @Test("A card dragged so that its middle is over another card or a group is about to be grouped with it")
    func groupingTarget() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let dragged = f.note("dragged", at: CGPoint(x: 0, y: 0))
        let other = f.note("other", at: CGPoint(x: 600, y: 0))
        let third = f.note("third", at: CGPoint(x: 600, y: 900))
        let fourth = f.note("fourth", at: CGPoint(x: 1300, y: 900))

        // Not far enough: its middle is still outside the other card.
        #expect(f.canvas.groupingTarget(for: dragged, movedBy: CGSize(width: 350, height: 0), in: f.store) == nil)
        // Its middle inside the other card.
        #expect(
            f.canvas.groupingTarget(for: dragged, movedBy: CGSize(width: 560, height: 10), in: f.store)
                == .note(other.id))
        // Never itself.
        #expect(f.canvas.groupingTarget(for: dragged, movedBy: .zero, in: f.store) == nil)

        // Over a group's tile it joins the group, not one of the cards in it.
        let group = try #require(f.store.makeGroup(on: dayKey, of: [third.id, fourth.id], at: CGPoint(x: 600, y: 900)))
        #expect(
            f.canvas.groupingTarget(for: dragged, movedBy: CGSize(width: 640, height: 930), in: f.store)
                == .group(group.id))

        // Nothing is grouped by dragging on a board of several days, or in the archive.
        f.canvas.show(Period.containing(Self.day, scale: .week, calendar: NoteStoreTests.calendar))
        #expect(f.canvas.groupingTarget(for: dragged, movedBy: CGSize(width: 560, height: 10), in: f.store) == nil)
    }

    @Test("Letting go over a card makes a group in that card's place; over a group, joins it")
    func dropping() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let dragged = f.note("dragged", at: CGPoint(x: 0, y: 0))
        let other = f.note("other", at: CGPoint(x: 600, y: 40))
        let late = f.note("late", at: CGPoint(x: 0, y: 900))

        f.canvas.group(dragged, with: .note(other.id), in: f.store)
        let group = try #require(f.store.groups.first)
        #expect(group.board == dayKey)
        #expect(group.noteIDs == [other.id, dragged.id])
        #expect(group.position == CanvasPoint(x: 600, y: 40))
        #expect(group.name.isEmpty)
        // A new group asks for its name on its tile straight away.
        #expect(f.canvas.namingGroupID == group.id)
        f.canvas.namingGroupID = nil

        f.canvas.group(late, with: .group(group.id), in: f.store)
        #expect(f.store.group(group.id)?.noteIDs == [other.id, dragged.id, late.id])
        // Joining a group that exists asks for nothing.
        #expect(f.canvas.namingGroupID == nil)
    }

    @Test("Ungrouping sets the cards down round where the tile was, clear of one another and of the rest")
    func ungrouping() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let bystander = f.note("bystander", at: CGPoint(x: 700, y: 0))
        let members = (0..<3).map { f.note("m\($0)", at: CGPoint(x: -3000, y: Double($0) * 10)) }
        let group = try #require(f.store.makeGroup(on: dayKey, of: members.map(\.id), at: CGPoint(x: 100, y: 0)))
        f.canvas.expandedGroupID = group.id

        f.canvas.ungroup(group, in: f.store)
        #expect(f.store.groups.isEmpty)
        #expect(f.canvas.expandedGroupID == nil)
        let frames = f.canvas.notes(in: f.store).map { f.canvas.frame(of: $0) }
        #expect(frames.count == 4)
        for (index, frame) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) { #expect(!CanvasLayout.crowds(frame, other)) }
        }
        // They are near where the tile was, not back where they came from.
        let tile = f.canvas.frame(of: group)
        for member in members {
            let frame = f.canvas.frame(of: try #require(f.store.note(member.id)))
            #expect(abs(frame.midX - tile.midX) < 1200 && abs(frame.midY - tile.midY) < 1200)
        }
        #expect(f.store.note(bystander.id)?.position == CanvasPoint(x: 700, y: 0))
    }

    @Test("A card taken out is set down beside the tile; taken from a group of two, the other takes the tile's place")
    func takingOut() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let notes = (0..<3).map { f.note("n\($0)", at: CGPoint(x: -3000, y: Double($0) * 10)) }
        let group = try #require(f.store.makeGroup(on: dayKey, of: notes.map(\.id), at: CGPoint(x: 100, y: 0)))
        let tile = f.canvas.frame(of: group)

        f.canvas.remove(notes[0], from: group, in: f.store)
        let out = f.canvas.frame(of: try #require(f.store.note(notes[0].id)))
        #expect(!CanvasLayout.crowds(out, tile))
        #expect(out.minX >= tile.maxX)
        #expect(f.store.group(group.id)?.noteIDs == [notes[1].id, notes[2].id])

        let left = try #require(f.store.group(group.id))
        f.canvas.remove(notes[1], from: left, in: f.store)
        #expect(f.store.groups.isEmpty)
        #expect(f.store.note(notes[2].id)?.position == CanvasPoint(x: 100, y: 0))
        let frames = f.canvas.notes(in: f.store).map { f.canvas.frame(of: $0) }
        for (index, frame) in frames.enumerated() {
            for other in frames.dropFirst(index + 1) { #expect(!CanvasLayout.crowds(frame, other)) }
        }
    }
}
