import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

@Suite("Note store")
@MainActor
struct NoteStoreTests {

    /// A fresh, empty store directory under the system temp folder.
    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("retainer-tests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A calendar that does not depend on where the tests run: UTC, weeks
    /// starting on Monday.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()

    /// Noon on a given day, in the test calendar.
    static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func sampleNote(text: String, on date: Date, at point: CGPoint = .zero) -> Note {
        var note = sampleNote(text: text, position: CanvasPoint(point))
        note.timestamp = date
        return note
    }

    static func sampleNote(text: String = "A note.", position: CanvasPoint = CanvasPoint(x: 10, y: 20)) -> Note {
        let id = UUID()
        return Note(
            id: id,
            imagePath: NoteStore.imagePath(for: id),
            imagePixelSize: PixelSize(width: 800, height: 600),
            imageScale: 2,
            note: text,
            rawTranscript: "um a note",
            engine: EngineID.parakeet.rawValue,
            tidy: true,
            tidyOutcome: .applied,
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            sourceApp: "Safari",
            windowTitle: "An article",
            position: position)
    }

    @Test("A new store creates its directory and starts empty")
    func startsEmpty() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        #expect(store.notes.isEmpty)
        #expect(store.allNotes.isEmpty)
        #expect(store.loadError == nil)
        #expect(FileManager.default.fileExists(atPath: store.imagesDirectory.path))
        // Nothing is written until there is something to keep.
        store.flush()
        #expect(!FileManager.default.fileExists(atPath: store.indexURL.path))
    }

    @Test("A note belongs to the day it was saved on, and so to that week and month")
    func notesByPeriod() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Self.calendar
        let store = NoteStore(directory: directory, calendar: calendar)

        // Wednesday 18 November 2026 and the days round it.
        let wednesday = Self.date(2026, 11, 18)
        store.add(Self.sampleNote(text: "wed morning", on: Self.date(2026, 11, 18, hour: 9)))
        store.add(Self.sampleNote(text: "wed night", on: Self.date(2026, 11, 18, hour: 23, minute: 59)))
        store.add(Self.sampleNote(text: "monday", on: Self.date(2026, 11, 16)))
        store.add(Self.sampleNote(text: "last sunday", on: Self.date(2026, 11, 15)))
        store.add(Self.sampleNote(text: "october", on: Self.date(2026, 10, 30)))
        var fresh = Self.sampleNote(text: "thursday, new", on: Self.date(2026, 11, 19, hour: 0, minute: 1))
        fresh.seen = false
        store.add(fresh)

        let day = Period.containing(wednesday, scale: .day, calendar: calendar)
        let week = Period.containing(wednesday, scale: .week, calendar: calendar)
        let month = Period.containing(wednesday, scale: .month, calendar: calendar)
        let all = Period.containing(wednesday, scale: .all, calendar: calendar)
        #expect(store.notes(in: day).map(\.note) == ["wed morning", "wed night"])
        // The week runs Monday to Sunday: last Sunday is not in it.
        #expect(store.notes(in: week).map(\.note) == ["monday", "wed morning", "wed night", "thursday, new"])
        #expect(store.notes(in: month).map(\.note) == ["last sunday", "monday", "wed morning", "wed night", "thursday, new"])
        #expect(store.notes(in: all).count == 6)
        #expect(store.notes(onDayOf: Self.date(2026, 11, 16, hour: 3)).map(\.note) == ["monday"])

        #expect(store.unseenNotes(in: day).isEmpty)
        #expect(store.unseenNotes(in: week).map(\.note) == ["thursday, new"])

        // An archived note leaves its day's board for that day's archive.
        let morning = store.notes(in: day)[0]
        store.archive(id: morning.id)
        #expect(store.notes(in: day).map(\.note) == ["wed night"])
        #expect(store.notes(in: day, archived: true).map(\.note) == ["wed morning"])
        #expect(store.notes(in: month, archived: true).map(\.note) == ["wed morning"])
        store.flush()

        let reopened = NoteStore(directory: directory, calendar: calendar)
        #expect(reopened.notes(in: day).map(\.note) == ["wed night"])
        #expect(reopened.notes(in: day, archived: true).map(\.note) == ["wed morning"])
        #expect(reopened.notes(in: all).count == 5)
    }

    @Test("Sample notes behave like notes and are never written to disk")
    func sampleNotesAreNotSaved() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Self.calendar
        let store = NoteStore(directory: directory, calendar: calendar)
        let real = Self.sampleNote(text: "real", on: Self.date(2026, 11, 18))
        store.add(real)

        var made = Self.sampleNote(text: "made up", on: Self.date(2026, 11, 17))
        made.imagePath = "samples/\(made.id.uuidString).png"
        let pictures = directory.appendingPathComponent("pictures", isDirectory: true)
        store.setSampleNotes([made], imagesIn: pictures)

        #expect(store.allNotes.map(\.note) == ["made up", "real"])
        #expect(store.isSample(made.id))
        #expect(!store.isSample(real.id))
        #expect(store.note(made.id)?.note == "made up")
        #expect(store.notes(onDayOf: Self.date(2026, 11, 17)).map(\.note) == ["made up"])
        // Its picture is looked for in the samples' folder, not among the real ones.
        #expect(store.imageURL(for: made) == pictures.appendingPathComponent("\(made.id.uuidString).png"))
        #expect(store.imageURL(for: real).path.hasPrefix(directory.appendingPathComponent("images").path))

        // It can be edited, moved and archived like any other…
        store.updateText(id: made.id, text: "made up, edited")
        store.move(id: made.id, to: CGPoint(x: 50, y: 60))
        store.archive(id: made.id)
        #expect(store.note(made.id)?.note == "made up, edited")
        #expect(store.note(made.id)?.position == CanvasPoint(x: 50, y: 60))
        #expect(store.note(made.id)?.isArchived == true)
        store.flush()

        // …but only the real note is in the file.
        let reopened = NoteStore(directory: directory, calendar: calendar)
        #expect(reopened.allNotes.map(\.note) == ["real"])

        store.delete(id: made.id)
        #expect(store.allNotes.map(\.note) == ["real"])
        store.setSampleNotes([made], imagesIn: pictures)
        store.setSampleNotes([], imagesIn: nil)
        #expect(store.sampleNotes.isEmpty)
    }

    @Test("Notes survive a relaunch with every field intact")
    func roundTrip() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Self.sampleNote()

        let store = NoteStore(directory: directory)
        store.add(note)
        store.flush()

        let reopened = NoteStore(directory: directory)
        #expect(reopened.notes == [note])
    }

    @Test("An edited note and a moved node persist")
    func editsPersist() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Self.sampleNote()

        let store = NoteStore(directory: directory)
        store.add(note)
        store.updateText(id: note.id, text: "An edited note.")
        store.move(id: note.id, to: CGPoint(x: 320, y: -40))
        store.flush()

        let reopened = NoteStore(directory: directory)
        #expect(reopened.notes.first?.note == "An edited note.")
        #expect(reopened.notes.first?.position == CanvasPoint(x: 320, y: -40))
        // Editing the note never touches what the engine originally heard.
        #expect(reopened.notes.first?.rawTranscript == "um a note")
    }

    @Test("Deleting removes the note from the index")
    func deletePersists() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = Self.sampleNote(text: "one")
        let second = Self.sampleNote(text: "two")

        let store = NoteStore(directory: directory)
        store.add(first)
        store.add(second)
        store.delete(id: first.id)
        store.flush()

        #expect(NoteStore(directory: directory).notes.map(\.note) == ["two"])
    }

    @Test("The index is one JSON file with the documented fields")
    func indexShape() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let note = Self.sampleNote()
        let store = NoteStore(directory: directory)
        store.add(note)
        store.flush()

        let data = try Data(contentsOf: store.indexURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["version"] as? Int == 4)
        #expect(Set(root.keys) == ["version", "notes", "projects", "canvases", "groups"])

        let entry = try #require((root["notes"] as? [[String: Any]])?.first)
        // `archivedAt` and `sourceURL` are written only for notes that have them.
        let expectedKeys: Set<String> = [
            "id", "imagePath", "imagePixelSize", "imageScale", "note", "rawTranscript", "engine",
            "tidy", "tidyOutcome", "timestamp", "sourceApp", "windowTitle", "position", "seen",
        ]
        #expect(Set(entry.keys) == expectedKeys)
        #expect(entry["seen"] as? Bool == true)
        #expect(entry["imagePath"] as? String == "images/\(note.id.uuidString).png")
        #expect(entry["engine"] as? String == "parakeet-tdt-v2")
        #expect(entry["timestamp"] as? String == "2027-01-15T08:00:00Z")
    }

    @Test("Archiving, restoring and being seen all persist")
    func archiveAndSeenPersist() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fresh = Self.sampleNote(text: "new")
        fresh.seen = false
        let kept = Self.sampleNote(text: "kept")
        let put = Self.sampleNote(text: "put away")

        let store = NoteStore(directory: directory)
        store.add(fresh)
        store.add(kept)
        store.add(put)
        #expect(store.unseenNotes.map(\.note) == ["new"])

        let when = Date(timeIntervalSince1970: 1_800_000_600)
        store.archive(id: put.id, position: CGPoint(x: 900, y: 40), date: when)
        #expect(store.activeNotes.map(\.note) == ["new", "kept"])
        #expect(store.archivedNotes.map(\.note) == ["put away"])
        store.flush()

        let reopened = NoteStore(directory: directory)
        #expect(reopened.activeNotes.map(\.note) == ["new", "kept"])
        #expect(reopened.unseenNotes.map(\.note) == ["new"])
        let archived = reopened.archivedNotes.first
        #expect(archived?.archivedAt == when)
        #expect(archived?.position == CanvasPoint(x: 900, y: 40))
        // The text and image of an archived note are untouched.
        #expect(archived?.note == "put away")
        #expect(archived?.imagePath == put.imagePath)

        reopened.markSeen([fresh.id])
        reopened.restore(id: put.id)
        reopened.flush()

        let again = NoteStore(directory: directory)
        #expect(again.unseenNotes.isEmpty)
        #expect(again.archivedNotes.isEmpty)
        #expect(again.activeNotes.count == 3)
        #expect(again.notes.first { $0.id == put.id }?.position == CanvasPoint(x: 900, y: 40))
    }

    @Test("Archiving a note that had not been seen clears its new marker")
    func archivingMarksSeen() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var fresh = Self.sampleNote()
        fresh.seen = false
        let store = NoteStore(directory: directory)
        store.add(fresh)
        store.archive(id: fresh.id)
        store.restore(id: fresh.id)
        #expect(store.unseenNotes.isEmpty)
        #expect(store.notes.first?.seen == true)
    }

    @Test("An index written before archiving existed still loads: every note on the canvas, none new")
    func readsOlderIndex() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let older = """
            {
              "version" : 1,
              "notes" : [
                {
                  "engine" : "parakeet-tdt-v2",
                  "id" : "0E2C0F4E-6B1B-4C0E-9B55-3A1F1C1D2E3F",
                  "imagePath" : "images/0E2C0F4E-6B1B-4C0E-9B55-3A1F1C1D2E3F.png",
                  "imagePixelSize" : { "height" : 600, "width" : 800 },
                  "imageScale" : 2,
                  "note" : "From an earlier build.",
                  "position" : { "x" : 10, "y" : 20 },
                  "rawTranscript" : "from an earlier build",
                  "tidy" : true,
                  "tidyOutcome" : "applied",
                  "timestamp" : "2027-01-15T08:00:00Z"
                }
              ]
            }
            """
        try Data(older.utf8).write(to: directory.appendingPathComponent("index.json"))

        let store = NoteStore(directory: directory)
        #expect(store.loadError == nil)
        let note = try #require(store.notes.first)
        #expect(note.note == "From an earlier build.")
        #expect(note.seen)
        #expect(!note.isArchived)
        #expect(note.sourceApp == nil)
        #expect(note.sourceURL == nil)
        #expect(store.activeNotes.count == 1)

        // And the file is brought up to today's shape.
        store.flush()
        let data = try Data(contentsOf: store.indexURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["version"] as? Int == 4)
        #expect(NoteStore(directory: directory).notes.first?.note == "From an earlier build.")
    }

    /// For a short while notes were filed into projects and canvases. An
    /// index from then names both, and can have two notes of the same day at
    /// the same place on different canvases.
    @Test("An index with projects and canvases loads: every note kept, on its day, none on top of another")
    func readsIndexWithProjects() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        func entry(_ id: String, _ text: String, canvas: String, day: String, x: Int, y: Int) -> String {
            """
                {
                  "canvasID" : "\(canvas)",
                  "engine" : "parakeet-tdt-v2",
                  "id" : "\(id)",
                  "imagePath" : "images/\(id).png",
                  "imagePixelSize" : { "height" : 600, "width" : 800 },
                  "imageScale" : 2,
                  "note" : "\(text)",
                  "position" : { "x" : \(x), "y" : \(y) },
                  "rawTranscript" : "\(text)",
                  "seen" : true,
                  "tidy" : false,
                  "timestamp" : "\(day)"
                }
            """
        }
        let first = "11111111-1111-4111-8111-111111111111"
        let second = "22222222-2222-4222-8222-222222222222"
        let older = """
            {
              "version" : 2,
              "projects" : [ { "id" : "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "name" : "Notes", "createdAt" : "2026-11-18T08:00:00Z" } ],
              "canvases" : [
                { "id" : "\(first)", "projectID" : "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "name" : "Canvas 1", "createdAt" : "2026-11-18T08:00:00Z" },
                { "id" : "\(second)", "projectID" : "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", "name" : "Canvas 2", "createdAt" : "2026-11-18T09:00:00Z" }
              ],
              "notes" : [
            \(entry("0E2C0F4E-6B1B-4C0E-9B55-3A1F1C1D2E01", "one", canvas: first, day: "2026-11-18T10:00:00Z", x: -200, y: -150)),
            \(entry("0E2C0F4E-6B1B-4C0E-9B55-3A1F1C1D2E02", "two", canvas: second, day: "2026-11-18T11:00:00Z", x: -200, y: -150)),
            \(entry("0E2C0F4E-6B1B-4C0E-9B55-3A1F1C1D2E03", "three", canvas: second, day: "2026-11-17T11:00:00Z", x: -200, y: -150))
              ]
            }
            """
        try Data(older.utf8).write(to: directory.appendingPathComponent("index.json"))

        let calendar = Self.calendar
        let store = NoteStore(directory: directory, calendar: calendar)
        #expect(store.loadError == nil)
        #expect(store.notes.map(\.note) == ["one", "two", "three"])

        // The two saved on the 18th were in the same place on different
        // canvases. On one board, the later of them has stepped aside.
        func frame(_ note: Note) -> CGRect {
            CGRect(
                origin: note.position.cgPoint,
                size: CGSize(
                    width: CanvasModel.nodeWidth,
                    height: NodeLayout.estimatedHeight(imageAspectRatio: note.imageAspectRatio, note: note.note)))
        }
        let eighteenth = store.notes(onDayOf: Self.date(2026, 11, 18))
        #expect(eighteenth.map(\.note) == ["one", "two"])
        #expect(eighteenth[0].position == CanvasPoint(x: -200, y: -150))
        #expect(!CanvasLayout.crowds(frame(eighteenth[0]), frame(eighteenth[1])))
        // The one on the 17th had the place to itself and has not moved.
        #expect(store.notes(onDayOf: Self.date(2026, 11, 17)).first?.position == CanvasPoint(x: -200, y: -150))

        // What that version called projects and canvases is not what those
        // words mean now, and none of it is read as if it were.
        #expect(store.projects.isEmpty && store.canvases.isEmpty)

        // Rewritten without them, and stable from then on.
        store.flush()
        let data = try Data(contentsOf: store.indexURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(root.keys) == ["version", "notes", "projects", "canvases", "groups"])
        #expect(root["version"] as? Int == 4)
        #expect((root["projects"] as? [Any])?.isEmpty == true && (root["canvases"] as? [Any])?.isEmpty == true)
        let again = NoteStore(directory: directory, calendar: calendar)
        #expect(again.notes == store.notes)
        #expect(again.projects.isEmpty && again.canvases.isEmpty)
    }

    @Test("A file from the version before projects is left as it was: cards put close together are not moved")
    func versionThreeIsNotTidiedAgain() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let calendar = Self.calendar
        let day = Self.date(2026, 11, 18)

        // Two cards on one day, overlapping: where the user dragged them.
        let first = Self.sampleNote(text: "one", on: day, at: CGPoint(x: 0, y: 0))
        let second = Self.sampleNote(text: "two", on: day.addingTimeInterval(60), at: CGPoint(x: 30, y: 20))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = try NoteStore.encoder.encode(NoteIndex(version: 3, notes: [first, second]))
        try old.write(to: directory.appendingPathComponent("index.json"))

        let store = NoteStore(directory: directory, calendar: calendar)
        #expect(store.notes.map(\.position) == [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 30, y: 20)])
        // It is still brought up to the current shape on disk.
        store.flush()
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: store.indexURL)) as? [String: Any])
        #expect(root["version"] as? Int == 4)
        #expect(NoteStore(directory: directory, calendar: calendar).notes.map(\.position) == store.notes.map(\.position))
    }

    // MARK: Projects and canvases

    @Test("Projects, their canvases and what is on them survive a relaunch")
    func projectsRoundTrip() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let note = Self.sampleNote(text: "on a canvas", position: CanvasPoint(x: 10, y: 20))
        store.add(note)

        let project = store.addProject(name: "  Thesis  ")
        #expect(project.name == "Thesis")
        let outline = try #require(store.addCanvas(in: project.id, name: "Outline"))
        let chapter = try #require(store.addCanvas(in: project.id, name: "Chapter 1"))
        #expect(store.addCanvas(in: UUID(), name: "Nowhere") == nil)
        store.place(noteID: note.id, on: chapter.id, at: CGPoint(x: 300, y: -40))
        store.flush()

        let again = NoteStore(directory: directory)
        #expect(again.projects.map(\.name) == ["Thesis"])
        #expect(again.canvases(in: project.id).map(\.name) == ["Outline", "Chapter 1"])
        #expect(again.notes(on: outline.id).isEmpty)
        let placed = try #require(again.notes(on: chapter.id).first)
        #expect(placed.id == note.id)
        // On the canvas it is where it was put there; on its day, where it always was.
        #expect(placed.position == CanvasPoint(x: 300, y: -40))
        #expect(again.note(note.id)?.position == CanvasPoint(x: 10, y: 20))
    }

    @Test("A note has one place on its day and another on each canvas, and moving one leaves the others")
    func twoPositions() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let note = Self.sampleNote(position: CanvasPoint(x: 10, y: 20))
        store.add(note)
        let project = store.addProject(name: "Reading")
        let first = try #require(store.addCanvas(in: project.id, name: "A"))
        let second = try #require(store.addCanvas(in: project.id, name: "B"))

        store.place(noteID: note.id, on: first.id, at: CGPoint(x: 100, y: 100))
        store.place(noteID: note.id, on: second.id, at: CGPoint(x: -500, y: 0))
        #expect(store.isPlaced(note.id, on: first.id) && store.isPlaced(note.id, on: second.id))
        #expect(store.canvases(holding: note.id).map(\.name) == ["A", "B"])

        // Dragged on its day.
        store.move(id: note.id, to: CGPoint(x: 77, y: 88))
        // Dragged on the first canvas: placing again moves it, it is not there twice.
        store.place(noteID: note.id, on: first.id, at: CGPoint(x: 150, y: 160))
        #expect(store.note(note.id)?.position == CanvasPoint(x: 77, y: 88))
        #expect(store.notes(on: first.id).map(\.position) == [CanvasPoint(x: 150, y: 160)])
        #expect(store.notes(on: second.id).map(\.position) == [CanvasPoint(x: -500, y: 0)])

        // Taken off one canvas, it is still on the other and on its day.
        store.remove(noteID: note.id, from: first.id)
        #expect(store.notes(on: first.id).isEmpty)
        #expect(store.notes(on: second.id).count == 1)
        #expect(store.note(note.id) != nil)
    }

    @Test("Archiving hides a card on its canvases and restoring brings it back in place; deleting takes it off them all")
    func archiveAndDeleteOnCanvases() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let kept = Self.sampleNote(text: "kept")
        let gone = Self.sampleNote(text: "gone")
        store.add(kept)
        store.add(gone)
        let project = store.addProject(name: "Reading")
        let canvas = try #require(store.addCanvas(in: project.id, name: "A"))
        store.place(noteID: kept.id, on: canvas.id, at: CGPoint(x: 1, y: 2))
        store.place(noteID: gone.id, on: canvas.id, at: CGPoint(x: 600, y: 2))
        #expect(store.unseenNotes(on: canvas.id).isEmpty)

        store.archive(id: kept.id)
        #expect(store.notes(on: canvas.id).map(\.note) == ["gone"])
        store.restore(id: kept.id)
        #expect(store.notes(on: canvas.id).map(\.note) == ["kept", "gone"])
        #expect(store.notes(on: canvas.id).first?.position == CanvasPoint(x: 1, y: 2))

        store.delete(id: gone.id)
        #expect(store.notes(on: canvas.id).map(\.note) == ["kept"])
        #expect(store.canvas(canvas.id)?.cards.count == 1)
    }

    @Test("Deleting a canvas or a project leaves the notes; renaming needs a name")
    func deletingAndRenaming() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let note = Self.sampleNote()
        store.add(note)
        let thesis = store.addProject(name: "Thesis")
        let reading = store.addProject(name: "Reading")
        let outline = try #require(store.addCanvas(in: thesis.id, name: "Outline"))
        let refs = try #require(store.addCanvas(in: thesis.id, name: "Refs"))
        let list = try #require(store.addCanvas(in: reading.id, name: "List"))
        for canvas in [outline, refs, list] { store.place(noteID: note.id, on: canvas.id, at: .zero) }

        store.renameProject(id: thesis.id, to: "  Dissertation ")
        store.renameProject(id: reading.id, to: "   ")
        store.renameCanvas(id: outline.id, to: "Plan")
        store.renameCanvas(id: refs.id, to: "")
        #expect(store.projects.map(\.name) == ["Dissertation", "Reading"])
        #expect(store.canvases(in: thesis.id).map(\.name) == ["Plan", "Refs"])

        store.deleteCanvas(id: outline.id)
        #expect(store.canvases(in: thesis.id).map(\.name) == ["Refs"])
        store.deleteProject(id: thesis.id)
        #expect(store.projects.map(\.name) == ["Reading"])
        #expect(store.canvases.map(\.name) == ["List"])
        // The note is where it always was, and still on the canvas that is left.
        #expect(store.notes.count == 1)
        #expect(store.notes(on: list.id).count == 1)

        store.flush()
        let again = NoteStore(directory: directory)
        #expect(again.projects.map(\.name) == ["Reading"] && again.canvases.map(\.name) == ["List"])
    }

    @Test("A made-up note can be put on a canvas, but its place there is not written to disk")
    func samplePlacementsStayInMemory() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NoteStore(directory: directory)
        let real = Self.sampleNote(text: "real")
        let madeUp = Self.sampleNote(text: "made up")
        store.add(real)
        store.setSampleNotes([madeUp], imagesIn: nil)
        let project = store.addProject(name: "Reading")
        let canvas = try #require(store.addCanvas(in: project.id, name: "A"))
        store.place(noteID: real.id, on: canvas.id, at: .zero)
        store.place(noteID: madeUp.id, on: canvas.id, at: CGPoint(x: 600, y: 0))
        #expect(store.notes(on: canvas.id).map(\.note) == ["real", "made up"])

        store.flush()
        let again = NoteStore(directory: directory)
        #expect(again.canvas(canvas.id)?.cards.map(\.noteID) == [real.id])

        // With the made-up days switched off, the canvas simply does not show it.
        store.setSampleNotes([], imagesIn: nil)
        #expect(store.notes(on: canvas.id).map(\.note) == ["real"])
    }

    @Test("A link to the source is kept with the note")
    func sourceLinkPersists() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var note = Self.sampleNote()
        note.sourceURL = "https://www.youtube.com/watch?v=abc123"
        let store = NoteStore(directory: directory)
        store.add(note)
        store.flush()
        #expect(NoteStore(directory: directory).notes.first?.sourceURL == "https://www.youtube.com/watch?v=abc123")
    }

    @Test("An unreadable index is set aside, never overwritten")
    func corruptIndexIsPreserved() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let garbage = Data("{ not json".utf8)
        try garbage.write(to: directory.appendingPathComponent("index.json"))

        let store = NoteStore(directory: directory)
        #expect(store.notes.isEmpty)
        #expect(store.loadError != nil)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let backup = try #require(files.first { $0.hasPrefix("index.unreadable-") })
        #expect(try Data(contentsOf: directory.appendingPathComponent(backup)) == garbage)
    }

    @Test("A screenshot written as PNG reads back at the same pixel size")
    func imageRoundTrip() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        let image = try #require(context.makeImage())

        let url = directory.appendingPathComponent("test.png")
        try ImageFiles.writePNG(image, scale: 2, to: url)

        let full = try #require(ImageFiles.load(url, maxPixelSize: nil))
        #expect(full.width == 64 && full.height == 48)
        let thumbnail = try #require(ImageFiles.load(url, maxPixelSize: 32))
        #expect(max(thumbnail.width, thumbnail.height) == 32)
    }
}
