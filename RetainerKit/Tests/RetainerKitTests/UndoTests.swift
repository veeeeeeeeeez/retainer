import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Undo and redo")
@MainActor
struct UndoTests {

    @MainActor
    private final class Fixture {
        let directory = NoteStoreTests.temporaryDirectory()
        let store: NoteStore
        var undo: UndoManager { store.undoManager }

        init() {
            store = NoteStore(directory: directory, calendar: NoteStoreTests.calendar)
            // In the app a step is whatever happens in one turn of the run
            // loop; here each `step` is one.
            store.undoManager.groupsByEvent = false
        }

        func step(_ change: () -> Void) {
            undo.beginUndoGrouping()
            change()
            undo.endUndoGrouping()
        }

        func note(_ text: String, at point: CGPoint = .zero) -> Note {
            let note = NoteStoreTests.sampleNote(text: text, on: NoteStoreTests.date(2026, 11, 19), at: point)
            step { store.add(note) }
            return note
        }

        func cleanUp() {
            store.flush()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    @Test("A deleted card comes back with undo, on its canvas and in its group, and goes again with redo")
    func deleteAndBack() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a"), b = f.note("b")
        var canvasID: UUID!
        f.step {
            let project = f.store.addProject(name: "P")
            canvasID = f.store.addCanvas(in: project.id, name: "C")!.id
            f.store.place(noteID: a.id, on: canvasID, at: CGPoint(x: 5, y: 5))
            f.store.place(noteID: b.id, on: canvasID, at: CGPoint(x: 500, y: 5))
        }
        let board = Board.canvas(canvasID).id
        f.step { _ = f.store.makeGroup(on: board, of: [a.id, b.id], at: .zero) }

        f.step { f.store.delete(id: a.id) }
        #expect(f.store.note(a.id) == nil)
        #expect(f.store.groups.isEmpty)
        #expect(f.undo.undoActionName == "Delete Card")

        f.undo.undo()
        #expect(f.store.note(a.id)?.note == "a")
        #expect(f.store.isPlaced(a.id, on: canvasID))
        #expect(f.store.group(holding: a.id, on: board) != nil)
        #expect(f.undo.redoActionName == "Delete Card")

        f.undo.redo()
        #expect(f.store.note(a.id) == nil)
        f.undo.undo()
        #expect(f.store.note(a.id) != nil)
    }

    @Test("Undoing a delete keeps the picture; it stays on disk through a quit while the note exists")
    func pictureKept() throws {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a")
        let url = f.directory.appendingPathComponent(a.imagePath)
        try Data([0]).write(to: url)

        f.step { f.store.delete(id: a.id) }
        #expect(FileManager.default.fileExists(atPath: url.path))
        f.undo.undo()
        f.store.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(NoteStore(directory: f.directory, calendar: NoteStoreTests.calendar).note(a.id) != nil)
    }

    @Test("Moves, archive and restore, renames and project deletion each undo one at a time, newest first")
    func stepsInOrder() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a", at: CGPoint(x: 10, y: 10))
        var project: Project!
        f.step { project = f.store.addProject(name: "Thesis") }
        f.step { f.store.move(id: a.id, to: CGPoint(x: 300, y: 40)) }
        f.step { f.store.archive(id: a.id) }
        f.step { f.store.renameProject(id: project.id, to: "Book") }
        f.step { f.store.deleteProject(id: project.id) }

        f.undo.undo()
        #expect(f.store.project(project.id)?.name == "Book")
        f.undo.undo()
        #expect(f.store.project(project.id)?.name == "Thesis")
        f.undo.undo()
        #expect(f.store.note(a.id)?.isArchived == false)
        f.undo.undo()
        #expect(f.store.note(a.id)?.position == CanvasPoint(x: 10, y: 10))
    }

    @Test("A change that changes nothing is not a step")
    func noOpsNotRecorded() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a", at: CGPoint(x: 10, y: 10))
        f.undo.removeAllActions()
        // Not wrapped in a step: registering anything outside one would trap.
        f.store.move(id: a.id, to: CGPoint(x: 10, y: 10))
        f.store.restore(id: a.id)
        f.store.markSeen([a.id])
        #expect(!f.undo.canUndo)
    }

    @Test("Typing into a note is one step however many keys, and other changes meanwhile stay their own")
    func typingIsOneStep() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("hello", at: .zero)
        let b = f.note("other", at: CGPoint(x: 500, y: 0))
        f.undo.removeAllActions()

        f.store.beginTextEdit(id: a.id)
        for text in ["hello ", "hello w", "hello wo", "hello world"] {
            // Each key records nothing (outside a step, anything recorded would trap).
            f.store.updateText(id: a.id, text: text)
        }
        f.step { f.store.move(id: b.id, to: CGPoint(x: 900, y: 0)) }
        f.step { f.store.endTextEdit(id: a.id) }

        #expect(f.undo.undoActionName == "Edit Note")
        f.undo.undo()
        #expect(f.store.note(a.id)?.note == "hello")
        // The move made while typing is not taken back with the typing.
        #expect(f.store.note(b.id)?.position == CanvasPoint(x: 900, y: 0))
        f.undo.undo()
        #expect(f.store.note(b.id)?.position == CanvasPoint(x: 500, y: 0))
        #expect(!f.undo.canUndo)
        f.undo.redo()
        f.undo.redo()
        #expect(f.store.note(a.id)?.note == "hello world")
    }

    @Test("Undo does not bring back a card's new marker or an old picture size")
    func keepsWhatHappenedOnItsOwn() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a")
        f.step { f.store.move(id: a.id, to: CGPoint(x: 99, y: 0)) }
        f.store.markSeen([a.id])
        f.store.updateImage(id: a.id, pixelSize: PixelSize(width: 1200, height: 630), scale: 1)
        f.undo.undo()
        #expect(f.store.note(a.id)?.seen == true)
        #expect(f.store.note(a.id)?.imagePixelSize == PixelSize(width: 1200, height: 630))
        #expect(f.store.note(a.id)?.position == a.position)
    }

    @Test("What an undo puts back is saved")
    func undoPersists() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a"), b = f.note("b")
        f.step { f.store.delete(id: a.id) }
        f.undo.undo()
        f.step { f.store.updateText(id: b.id, text: "b2") }
        f.undo.undo()
        f.store.flush()
        let reopened = NoteStore(directory: f.directory, calendar: NoteStoreTests.calendar)
        #expect(reopened.notes.map(\.note) == ["a", "b"])
    }

    @Test("The undo and redo buttons' names follow what there is to undo and redo")
    func namesFollow() {
        let f = Fixture()
        defer { f.cleanUp() }
        let a = f.note("a")
        #expect(f.store.undoName == "New Note")
        #expect(f.store.redoName == nil)
        f.step { f.store.archive(id: a.id) }
        #expect(f.store.undoName == "Archive")
        f.undo.undo()
        #expect(f.store.undoName == "New Note")
        #expect(f.store.redoName == "Archive")
        f.undo.undo()
        #expect(f.store.undoName == nil)
        #expect(f.store.redoName == "New Note")
    }
}
