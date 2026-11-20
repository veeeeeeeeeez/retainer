import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Projects and canvases in the bar")
@MainActor
struct NavigationTests {

    /// A store, a board model and the bar's state, with nothing in them, and
    /// what to throw away afterwards.
    @MainActor
    private final class Fixture {
        let suite: String
        let directory: URL
        let defaults: UserDefaults
        let store: NoteStore
        let canvas: CanvasModel
        let navigation: Navigation

        init() {
            suite = "retainer-tests-\(UUID().uuidString)"
            directory = NoteStoreTests.temporaryDirectory()
            defaults = UserDefaults(suiteName: suite)!
            store = NoteStore(directory: directory)
            canvas = CanvasModel(defaults: defaults)
            canvas.setViewSize(CGSize(width: 1200, height: 800))
            navigation = Navigation(store: store, canvas: canvas)
        }

        func cleanUp() {
            store.flush()
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
    }

    @Test("The bar starts on the timeline, and looking at the list of projects leaves the board alone")
    func startsOnTheTimeline() {
        let f = Fixture()
        defer { f.cleanUp() }
        let today = f.canvas.board
        #expect(f.navigation.mode == .timeline)
        #expect(f.canvas.isShowingToday)

        f.navigation.setMode(.projects)
        #expect(f.navigation.mode == .projects)
        #expect(f.navigation.browsingProjectID == nil)
        #expect(f.canvas.board == today)
        #expect(f.navigation.projectForNewCanvas == nil)
        #expect(f.navigation.newCanvas() == nil)
    }

    @Test("A new project comes with a canvas, which is put in front, and its name is being typed")
    func newProject() throws {
        let f = Fixture()
        defer { f.cleanUp() }

        let first = f.navigation.newProject()
        #expect(first.name == "Project 1")
        #expect(f.navigation.mode == .projects)
        #expect(f.navigation.browsingProjectID == first.id)
        #expect(f.navigation.renamingID == first.id)
        let canvas = try #require(f.store.canvases(in: first.id).first)
        #expect(canvas.name == "Canvas 1")
        #expect(f.canvas.board == .canvas(canvas.id))
        #expect(!f.canvas.isShowingToday)

        f.navigation.rename(first.id, to: "Thesis")
        #expect(f.store.project(first.id)?.name == "Thesis")
        #expect(f.navigation.renamingID == nil)

        // The next one takes the first number that is free.
        #expect(f.navigation.newProject().name == "Project 1")
        #expect(f.navigation.newProject().name == "Project 2")
    }

    @Test("A new canvas goes in the project being looked at, in front, with its name being typed")
    func newCanvas() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let project = f.navigation.newProject()
        f.navigation.cancelRename()

        let second = try #require(f.navigation.newCanvas())
        #expect(second.projectID == project.id)
        #expect(second.name == "Canvas 2")
        #expect(f.canvas.board == .canvas(second.id))
        #expect(f.navigation.renamingID == second.id)

        // An empty name leaves the one it had.
        f.navigation.rename(second.id, to: "   ")
        #expect(f.store.canvas(second.id)?.name == "Canvas 2")
        f.navigation.startRenaming(second.id)
        f.navigation.rename(second.id, to: "Sources")
        #expect(f.store.canvases(in: project.id).map(\.name) == ["Canvas 1", "Sources"])

        // From the list of projects there is no project to put one in,
        // unless a canvas is still in front: then it is that canvas's.
        f.navigation.back()
        #expect(f.navigation.browsingProjectID == nil)
        #expect(f.navigation.projectForNewCanvas == project.id)
        f.navigation.setMode(.timeline)
        #expect(f.navigation.projectForNewCanvas == nil)
    }

    @Test("Going to the timeline brings the day back, and going to the projects brings back the canvas that was open")
    func switchingBackAndForth() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let today = f.canvas.board
        let thesis = f.navigation.newProject()
        let outline = try #require(f.store.canvases(in: thesis.id).first)
        let chapter = try #require(f.navigation.newCanvas())
        let reading = f.navigation.newProject()
        let list = try #require(f.store.canvases(in: reading.id).first)
        #expect(f.canvas.board == .canvas(list.id))

        // Opening a project shows the canvas last looked at in it.
        f.navigation.openProject(thesis.id)
        #expect(f.canvas.board == .canvas(chapter.id))
        f.navigation.openCanvas(outline.id)
        #expect(f.canvas.board == .canvas(outline.id))
        f.navigation.openProject(reading.id)
        f.navigation.openProject(thesis.id)
        #expect(f.canvas.board == .canvas(outline.id))

        f.navigation.setMode(.timeline)
        #expect(f.navigation.mode == .timeline)
        #expect(f.canvas.board == today)

        f.navigation.setMode(.projects)
        #expect(f.navigation.browsingProjectID == thesis.id)
        #expect(f.canvas.board == .canvas(outline.id))

        // Looking through the list does not move the board.
        f.navigation.back()
        #expect(f.navigation.browsingProjectID == nil)
        #expect(f.canvas.board == .canvas(outline.id))

        // Using the timeline itself (a day picked, say) takes the bar with it.
        f.navigation.timelineUsed()
        #expect(f.navigation.mode == .timeline)
    }

    @Test("Deleting takes two clicks; the canvas in front gives way to its neighbour, the last one to the day")
    func deletingCanvases() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let today = f.canvas.board
        let project = f.navigation.newProject()
        let first = try #require(f.store.canvases(in: project.id).first)
        let second = try #require(f.navigation.newCanvas())
        let third = try #require(f.navigation.newCanvas())
        f.navigation.cancelRename()
        let note = NoteStoreTests.sampleNote()
        f.store.add(note)
        f.store.place(noteID: note.id, on: third.id, at: .zero)

        // One click only asks; anything else calls it off.
        f.navigation.requestDelete(third.id)
        #expect(f.navigation.confirmingDeleteID == third.id)
        #expect(f.store.canvas(third.id) != nil)
        f.navigation.openCanvas(second.id)
        #expect(f.navigation.confirmingDeleteID == nil)
        f.navigation.confirmDelete()
        #expect(f.store.canvases(in: project.id).count == 3)

        // The one in front: its neighbour takes its place.
        f.navigation.openCanvas(third.id)
        f.navigation.requestDelete(third.id)
        f.navigation.confirmDelete()
        #expect(f.store.canvas(third.id) == nil)
        #expect(f.canvas.board == .canvas(second.id))
        // The note that was on it is untouched.
        #expect(f.store.note(note.id) != nil)

        // One that is not in front: the board stays.
        f.navigation.requestDelete(first.id)
        f.navigation.confirmDelete()
        #expect(f.canvas.board == .canvas(second.id))

        // The last one: back to the day.
        f.navigation.requestDelete(second.id)
        f.navigation.confirmDelete()
        #expect(f.store.canvases(in: project.id).isEmpty)
        #expect(f.canvas.board == today)
        // The project is still there, empty, and can have a canvas made in it.
        #expect(f.navigation.browsingProjectID == project.id)
        #expect(f.navigation.newCanvas()?.name == "Canvas 1")
    }

    @Test("Deleting a project takes its canvases with it and goes back to the day and the list")
    func deletingAProject() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let today = f.canvas.board
        let kept = f.navigation.newProject()
        let gone = f.navigation.newProject()
        _ = f.navigation.newCanvas()
        #expect(f.store.canvases(in: gone.id).count == 2)

        f.navigation.requestDelete(gone.id)
        f.navigation.confirmDelete()
        #expect(f.store.projects.map(\.id) == [kept.id])
        #expect(f.store.canvases.allSatisfy { $0.projectID == kept.id })
        #expect(f.canvas.board == today)
        #expect(f.navigation.browsingProjectID == nil)
        #expect(f.navigation.mode == .projects)
    }

    // MARK: The board model with canvases

    @Test("Each canvas keeps its own pan and zoom, and moving about on one does not disturb a day's")
    func viewportPerCanvas() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let project = f.store.addProject(name: "Thesis")
        let one = try #require(f.store.addCanvas(in: project.id, name: "One"))
        let two = try #require(f.store.addCanvas(in: project.id, name: "Two"))

        f.canvas.pan(by: CGSize(width: 40, height: -25))
        let dayOffset = f.canvas.offset

        f.canvas.show(.canvas(one.id))
        // A canvas never shown before starts at 100% with its origin in the middle.
        #expect(f.canvas.offset == CGSize(width: 600, height: 400) && f.canvas.scale == 1)
        f.canvas.pan(by: CGSize(width: -300, height: 120))
        f.canvas.zoom(by: 0.5, around: CGPoint(x: 600, y: 400))
        let oneOffset = f.canvas.offset

        f.canvas.show(.canvas(two.id))
        #expect(f.canvas.offset == CGSize(width: 600, height: 400) && f.canvas.scale == 1)

        f.canvas.show(f.canvas.period)
        #expect(f.canvas.offset == dayOffset && f.canvas.scale == 1)
        f.canvas.show(.canvas(one.id))
        #expect(f.canvas.offset == oneOffset && f.canvas.scale == 0.5)

        // A canvas is never "today", never a board of several days, and has no archive to show.
        #expect(!f.canvas.isShowingToday && !f.canvas.showsDays)
        #expect(f.canvas.canvasID == one.id)
    }

    @Test("A card added to a canvas goes clear of the ones there, and keeps its place on its day")
    func addingExistingCards() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let project = f.store.addProject(name: "Thesis")
        let target = try #require(f.store.addCanvas(in: project.id, name: "One"))
        let first = NoteStoreTests.sampleNote(text: "one", position: CanvasPoint(x: 10, y: 20))
        let second = NoteStoreTests.sampleNote(text: "two", position: CanvasPoint(x: 900, y: 20))
        f.store.add(first)
        f.store.add(second)

        // While another board is on screen.
        f.canvas.add(first, to: target.id, in: f.store)
        f.canvas.add(second, to: target.id, in: f.store)
        // Adding one that is already there changes nothing.
        f.canvas.add(first, to: target.id, in: f.store)
        let placed = f.store.notes(on: target.id)
        #expect(placed.map(\.note) == ["one", "two"])
        #expect(!CanvasLayout.crowds(f.canvas.frame(of: placed[0]), f.canvas.frame(of: placed[1])))
        #expect(f.store.note(first.id)?.position == CanvasPoint(x: 10, y: 20))

        // The board shows them where they are on the canvas.
        f.canvas.show(.canvas(target.id))
        #expect(f.canvas.notes(in: f.store).map(\.position) == placed.map(\.position))
        // Archived, a card leaves the canvas; restored, it is back where it was there.
        f.canvas.archive(placed[0], in: f.store)
        #expect(f.canvas.notes(in: f.store).map(\.note) == ["two"])
        f.canvas.restore(placed[0], in: f.store)
        #expect(f.canvas.notes(in: f.store).first?.position == placed[0].position)
        #expect(f.store.note(first.id)?.position == CanvasPoint(x: 10, y: 20))
    }

    @Test("The next new note is looked for on the canvas in front first")
    func nextUnseenOnACanvas() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let project = f.store.addProject(name: "Thesis")
        let target = try #require(f.store.addCanvas(in: project.id, name: "One"))
        var here = NoteStoreTests.sampleNote(text: "here")
        here.seen = false
        var elsewhere = NoteStoreTests.sampleNote(text: "elsewhere")
        elsewhere.seen = false
        f.store.add(here)
        f.store.add(elsewhere)
        f.store.place(noteID: here.id, on: target.id, at: CGPoint(x: 5000, y: 3000))
        f.canvas.show(.canvas(target.id))
        #expect(f.canvas.unseenNotes(in: f.store).map(\.note) == ["here"])

        // It is shown where it is on the canvas, and the canvas stays in front.
        let found = f.canvas.showNextUnseen(in: f.store)
        #expect(found?.id == here.id)
        #expect(f.canvas.board == .canvas(target.id))
        let centre = f.canvas.visibleCentre
        let frame = f.canvas.frame(of: try #require(f.canvas.notes(in: f.store).first))
        #expect(abs(centre.x - frame.midX) < 1 && abs(centre.y - frame.midY) < 1)

        // With nothing new left on the canvas, it goes to the note's day.
        f.store.markSeen([here.id])
        #expect(f.canvas.showNextUnseen(in: f.store)?.id == elsewhere.id)
        #expect(!f.canvas.board.isCanvas)
    }
}
