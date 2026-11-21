import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers
import os

/// All notes, kept in memory and mirrored to a single JSON index next to
/// their PNG files. Local only: nothing here touches the network.
///
/// Notes are not filed into anything. A note belongs to the day it was saved
/// on, and a board is whatever notes fall in a day, a week, a month, or all
/// time (`Period`).
///
/// Besides the saved notes the store can hold sample notes (`SampleDays`):
/// made-up captures on past days, so the timeline has something to show.
/// They behave like notes while the app runs and are never written to disk.
///
/// ```
/// ~/Library/Application Support/Terminal/
///     index.json
///     images/<note id>.png
/// ```
///
/// The folder has the app's first name, Terminal. It was not renamed with
/// the app: the notes stay where they have always been.
@MainActor
@Observable
public final class NoteStore {

    /// The saved notes, in the order they were saved.
    public private(set) var notes: [Note] = []
    /// Made-up notes on past days. Never written to disk.
    public private(set) var sampleNotes: [Note] = []
    /// The projects, in the order they were made.
    public private(set) var projects: [Project] = []
    /// Every canvas of every project, in the order they were made.
    public private(set) var canvases: [ProjectCanvas] = []
    /// Cards put together on a board, shown there as one tile.
    public private(set) var groups: [NoteGroup] = []
    /// Set when the index on disk could not be read.
    public private(set) var loadError: String?
    /// The step undo would take back, by name, or `nil` if there is none.
    /// Kept in step with `undoManager` so buttons can follow it.
    public private(set) var undoName: String?
    /// The step redo would do again, by name, or `nil` if there is none.
    public private(set) var redoName: String?

    @ObservationIgnored public let directory: URL
    /// Which days and weeks notes fall in.
    @ObservationIgnored public let calendar: Calendar
    /// Where the sample notes' pictures are.
    @ObservationIgnored private var sampleImagesDirectory: URL?
    @ObservationIgnored private let writer: IndexWriter
    @ObservationIgnored private var pendingSave: DispatchWorkItem?
    /// Undo and redo for everything a person does to their notes, boards,
    /// projects and groups. The main window hands it to the Edit menu.
    @ObservationIgnored public let undoManager = UndoManager()
    /// Set while an undo or redo puts an earlier state back, so that doing
    /// so is not itself recorded as something to undo.
    @ObservationIgnored private var isRestoring = false
    /// A note whose text is being typed into, and everything as it was
    /// before the typing began: the whole edit is one step to undo.
    @ObservationIgnored private var textEdit: (id: UUID, before: String)?
    /// Pictures of notes that are gone but could come back with an undo.
    /// They go to the Trash when the app quits, if they are still gone.
    @ObservationIgnored private var unusedImagePaths: Set<String> = []
    private static let log = Logger(subsystem: "blog.terminal.app", category: "store")

    public nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Terminal", isDirectory: true)
    }

    public init(directory: URL = NoteStore.defaultDirectory, calendar: Calendar = .current) {
        self.directory = directory
        self.calendar = calendar
        self.writer = IndexWriter(url: directory.appendingPathComponent("index.json"))
        load()
        for name: Notification.Name in [
            .NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
        ] {
            NotificationCenter.default.addObserver(
                forName: name, object: undoManager, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUndoNames() }
            }
        }
    }

    private func refreshUndoNames() {
        undoName = undoManager.canUndo ? undoManager.undoActionName : nil
        redoName = undoManager.canRedo ? undoManager.redoActionName : nil
    }

    // MARK: Reading

    /// Saved and sample notes together.
    public var allNotes: [Note] { sampleNotes.isEmpty ? notes : sampleNotes + notes }

    public func note(_ id: UUID?) -> Note? {
        guard let id else { return nil }
        return notes.first { $0.id == id } ?? sampleNotes.first { $0.id == id }
    }

    public func isSample(_ id: UUID) -> Bool {
        sampleNotes.contains { $0.id == id }
    }

    /// The notes on boards, in the order they were saved.
    public var activeNotes: [Note] { allNotes.filter { !$0.isArchived } }

    /// The notes that have been put away, most recently archived first.
    public var archivedNotes: [Note] {
        allNotes.filter(\.isArchived).sorted { ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast) }
    }

    /// Notes on boards whose cards have not been looked at yet, oldest first.
    public var unseenNotes: [Note] {
        allNotes.filter { !$0.isArchived && !$0.seen }.sorted { $0.timestamp < $1.timestamp }
    }

    /// The notes of a day, week, month or all time: those on its board, or
    /// those archived from it. Oldest first.
    public func notes(in period: Period, archived: Bool = false) -> [Note] {
        allNotes
            .filter { $0.isArchived == archived && period.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// The notes of a period that have not been looked at yet, oldest first.
    public func unseenNotes(in period: Period) -> [Note] {
        unseenNotes.filter { period.contains($0.timestamp) }
    }

    /// The notes on the board of the day `date` falls on.
    public func notes(onDayOf date: Date, archived: Bool = false) -> [Note] {
        notes(in: Period.containing(date, scale: .day, calendar: calendar), archived: archived)
    }

    public var indexURL: URL { directory.appendingPathComponent("index.json") }
    public var imagesDirectory: URL { directory.appendingPathComponent("images", isDirectory: true) }

    public func imageURL(for note: Note) -> URL {
        if let sampleImagesDirectory, isSample(note.id) {
            return sampleImagesDirectory.appendingPathComponent((note.imagePath as NSString).lastPathComponent)
        }
        return directory.appendingPathComponent(note.imagePath)
    }

    /// The relative path a new note's image is stored under.
    public nonisolated static func imagePath(for id: UUID) -> String {
        "images/\(id.uuidString).png"
    }

    // MARK: Loading

    private func load() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        } catch {
            loadError = "Could not create \(directory.path): \(error.localizedDescription)"
            return
        }
        guard fileManager.fileExists(atPath: indexURL.path) else { return }
        do {
            let data = try Data(contentsOf: indexURL)
            let index = try Self.decoder.decode(NoteIndex.self, from: data)
            notes = index.notes
            // A canvas without its project, or a card without its note, is
            // of no use to anyone.
            let known = Set(index.notes.map(\.id))
            projects = index.projects
            canvases = index.canvases
                .filter { canvas in index.projects.contains { $0.id == canvas.projectID } }
                .map { canvas in
                    var canvas = canvas
                    canvas.cards.removeAll { !known.contains($0.noteID) }
                    return canvas
                }
            // A group needs its board (a canvas can have gone) and at least
            // two of its notes.
            groups = index.groups.compactMap { group in
                var group = group
                group.noteIDs.removeAll { !known.contains($0) }
                let boardExists =
                    group.board.hasPrefix("day:") || canvases.contains { Board.canvas($0.id).id == group.board }
                return boardExists && group.noteIDs.count >= 2 ? group : nil
            }
            if index.version < NoteIndex.firstTidyVersion {
                // The oldest files could have cards on top of one another:
                // they stepped a new card diagonally off the last, or kept
                // notes of one day on several canvases. Now that a day is
                // one board, move apart any that would overlap. Only those
                // files: in a newer one, cards that are close together are
                // where they were put.
                separateCrowdedNotes()
            }
            if index.version < NoteIndex.currentVersion {
                // Rewrite the file in today's shape.
                scheduleSave()
            }
        } catch {
            // Never overwrite an index that failed to parse: set it aside.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = directory.appendingPathComponent("index.unreadable-\(stamp).json")
            try? fileManager.moveItem(at: indexURL, to: backup)
            loadError = "The note index could not be read and was set aside as \(backup.lastPathComponent)."
            Self.log.error("index unreadable: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Within each day, moves any card that overlaps an earlier one to the
    /// nearest clear place beside it. Cards already clear are left alone.
    private func separateCrowdedNotes() {
        func frame(_ note: Note) -> CGRect {
            CGRect(
                origin: note.position.cgPoint,
                size: CGSize(
                    width: CanvasModel.nodeWidth,
                    height: NodeLayout.estimatedHeight(
                        imageAspectRatio: note.imageAspectRatio, note: note.note,
                        hasSourceLink: note.sourceURL != nil)))
        }
        for archived in [false, true] {
            let group = notes.filter { $0.isArchived == archived }
            for (_, dayNotes) in Timeline.days(of: group, calendar: calendar) {
                var placed: [CGRect] = []
                for note in dayNotes {
                    var rect = frame(note)
                    if placed.contains(where: { CanvasLayout.crowds(rect, $0) }) {
                        rect.origin = CanvasLayout.freeOrigin(
                            for: rect.size, near: CGPoint(x: rect.midX, y: rect.midY), avoiding: placed)
                        if let index = notes.firstIndex(where: { $0.id == note.id }) {
                            notes[index].position = CanvasPoint(rect.origin)
                        }
                    }
                    placed.append(rect)
                }
            }
        }
    }

    // MARK: Sample notes

    /// Puts made-up notes on past days, or takes them away again with an
    /// empty list. `imagesIn` is the folder their pictures were written to.
    public func setSampleNotes(_ samples: [Note], imagesIn directory: URL?) {
        sampleImagesDirectory = directory
        sampleNotes = samples
    }

    // MARK: Mutations

    public func add(_ note: Note) {
        undoable("New Note") {
            notes.append(note)
            scheduleSave()
        }
    }

    /// Changes a note wherever it lives. `change` says whether it changed
    /// anything; only changes to saved notes are written to disk.
    private func update(_ id: UUID, _ change: (inout Note) -> Bool) {
        if let index = notes.firstIndex(where: { $0.id == id }) {
            if change(&notes[index]) { scheduleSave() }
        } else if let index = sampleNotes.firstIndex(where: { $0.id == id }) {
            _ = change(&sampleNotes[index])
        }
    }

    /// Records that a note's picture has been replaced by another of a
    /// different size (a link's card, once its page has been pictured).
    public func updateImage(id: UUID, pixelSize: PixelSize, scale: Double) {
        update(id) { note in
            note.imagePixelSize = pixelSize
            note.imageScale = scale
            return true
        }
    }

    public func updateText(id: UUID, text: String) {
        let change = {
            self.update(id) { note in
                guard note.note != text else { return false }
                note.note = text
                return true
            }
        }
        // While it is being typed into, the edit is one step, recorded when it ends.
        if textEdit?.id == id { change() } else { undoable("Edit Note", change) }
    }

    public func move(id: UUID, to position: CGPoint) {
        undoable("Move Card") {
            let point = CanvasPoint(position)
            update(id) { note in
                guard note.position != point else { return false }
                note.position = point
                return true
            }
        }
    }

    /// Puts a note away. It leaves its board but keeps its text and image,
    /// and can be brought back with `restore`. `position` is where its card
    /// sits among the other archived ones of its day, if that has to change.
    public func archive(id: UUID, position: CGPoint? = nil, date: Date = Date()) {
        undoable("Archive") {
            update(id) { note in
                guard !note.isArchived else { return false }
                note.archivedAt = date
                // Putting it away is as good as having looked at it.
                note.seen = true
                if let position { note.position = CanvasPoint(position) }
                return true
            }
        }
    }

    /// Brings an archived note back to its day's board, at `position` if its
    /// old place has been taken since.
    public func restore(id: UUID, position: CGPoint? = nil) {
        undoable("Restore") {
            update(id) { note in
                guard note.isArchived else { return false }
                note.archivedAt = nil
                if let position { note.position = CanvasPoint(position) }
                return true
            }
        }
    }

    /// Records that these notes' cards have been looked at.
    public func markSeen(_ ids: some Sequence<UUID>) {
        for id in ids {
            update(id) { note in
                guard !note.seen else { return false }
                note.seen = true
                return true
            }
        }
    }

    /// Removes the note. Its image goes to the Trash, where it can still be
    /// recovered, when the app quits, unless an undo has brought it back by
    /// then. A sample note is simply dropped.
    public func delete(id: UUID) {
        undoable("Delete Card") {
            // Gone from every canvas it was on, too, and from every group.
            for index in canvases.indices {
                canvases[index].cards.removeAll { $0.noteID == id }
            }
            dropFromGroups(id) { _ in true }
            if let index = sampleNotes.firstIndex(where: { $0.id == id }) {
                sampleNotes.remove(at: index)
                return
            }
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
            let removed = notes.remove(at: index)
            // Kept until the app quits, so that undo can bring it back.
            unusedImagePaths.insert(removed.imagePath)
            scheduleSave()
        }
    }

    // MARK: Projects and canvases

    public func project(_ id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    public func canvas(_ id: UUID?) -> ProjectCanvas? {
        guard let id else { return nil }
        return canvases.first { $0.id == id }
    }

    /// A project's canvases, in the order they were made.
    public func canvases(in projectID: UUID) -> [ProjectCanvas] {
        canvases.filter { $0.projectID == projectID }
    }

    /// The canvases a note has been put on.
    public func canvases(holding noteID: UUID) -> [ProjectCanvas] {
        canvases.filter { canvas in canvas.cards.contains { $0.noteID == noteID } }
    }

    /// A name as it is kept: without the space round it. `nil` if nothing is left.
    private static func tidied(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    public func addProject(name: String, date: Date = Date()) -> Project {
        undoable("New Project") {
            let project = Project(name: Self.tidied(name) ?? "Project", createdAt: date)
            projects.append(project)
            scheduleSave()
            return project
        }
    }

    /// Renames a project. An empty name changes nothing.
    public func renameProject(id: UUID, to name: String) {
        undoable("Rename Project") {
            guard let name = Self.tidied(name), let index = projects.firstIndex(where: { $0.id == id }),
                projects[index].name != name
            else { return }
            projects[index].name = name
            scheduleSave()
        }
    }

    /// Removes a project and its canvases. The notes that were on them are
    /// untouched: they are still on their days.
    public func deleteProject(id: UUID) {
        undoable("Delete Project") {
            guard projects.contains(where: { $0.id == id }) else { return }
            let gone = Set(canvases.filter { $0.projectID == id }.map { Board.canvas($0.id).id })
            projects.removeAll { $0.id == id }
            canvases.removeAll { $0.projectID == id }
            groups.removeAll { gone.contains($0.board) }
            scheduleSave()
        }
    }

    /// Adds a canvas to a project, or `nil` if there is no such project.
    @discardableResult
    public func addCanvas(in projectID: UUID, name: String, date: Date = Date()) -> ProjectCanvas? {
        undoable("New Canvas") {
            guard projects.contains(where: { $0.id == projectID }) else { return nil }
            let canvas = ProjectCanvas(projectID: projectID, name: Self.tidied(name) ?? "Canvas", createdAt: date)
            canvases.append(canvas)
            scheduleSave()
            return canvas
        }
    }

    /// Renames a canvas. An empty name changes nothing.
    public func renameCanvas(id: UUID, to name: String) {
        undoable("Rename Canvas") {
            guard let name = Self.tidied(name), let index = canvases.firstIndex(where: { $0.id == id }),
                canvases[index].name != name
            else { return }
            canvases[index].name = name
            scheduleSave()
        }
    }

    /// Removes a canvas. The notes that were on it are untouched.
    public func deleteCanvas(id: UUID) {
        undoable("Delete Canvas") {
            guard canvases.contains(where: { $0.id == id }) else { return }
            canvases.removeAll { $0.id == id }
            groups.removeAll { $0.board == Board.canvas(id).id }
            scheduleSave()
        }
    }

    /// The notes on a canvas, in the order they were put there, each with
    /// `position` set to its place **on that canvas**, so that everything
    /// that draws and measures a day's board does the same for a canvas.
    /// A note that has been archived is not shown; its place is kept for
    /// when it comes back.
    public func notes(on canvasID: UUID) -> [Note] {
        guard let canvas = canvas(canvasID) else { return [] }
        return canvas.cards.compactMap { card in
            guard var note = note(card.noteID), !note.isArchived else { return nil }
            note.position = card.position
            return note
        }
    }

    /// The notes on a canvas that have not been looked at yet.
    public func unseenNotes(on canvasID: UUID) -> [Note] {
        notes(on: canvasID).filter { !$0.seen }
    }

    public func isPlaced(_ noteID: UUID, on canvasID: UUID) -> Bool {
        canvas(canvasID)?.cards.contains { $0.noteID == noteID } ?? false
    }

    /// Puts a note on a canvas at `position`, or moves it there if it is
    /// already on it. Its place on its day's board is not touched.
    public func place(noteID: UUID, on canvasID: UUID, at position: CGPoint) {
        undoable(isPlaced(noteID, on: canvasID) ? "Move Card" : "Add to Canvas") {
            guard note(noteID) != nil, let index = canvases.firstIndex(where: { $0.id == canvasID }) else { return }
            let point = CanvasPoint(position)
            if let card = canvases[index].cards.firstIndex(where: { $0.noteID == noteID }) {
                guard canvases[index].cards[card].position != point else { return }
                canvases[index].cards[card].position = point
            } else {
                canvases[index].cards.append(ProjectCanvas.Placement(noteID: noteID, position: point))
            }
            // A made-up note's place is kept only while the app is open.
            if !isSample(noteID) { scheduleSave() }
        }
    }

    /// Takes a note off a canvas. The note itself stays.
    public func remove(noteID: UUID, from canvasID: UUID) {
        undoable("Remove from Canvas") {
            guard let index = canvases.firstIndex(where: { $0.id == canvasID }),
                canvases[index].cards.contains(where: { $0.noteID == noteID })
            else { return }
            canvases[index].cards.removeAll { $0.noteID == noteID }
            // No longer on the canvas, so not in a group there either.
            let board = Board.canvas(canvasID).id
            dropFromGroups(noteID) { $0.board == board }
            if !isSample(noteID) { scheduleSave() }
        }
    }

    // MARK: Groups

    public func group(_ id: UUID?) -> NoteGroup? {
        guard let id else { return nil }
        return groups.first { $0.id == id }
    }

    /// The groups on a board (`Board.id`), in the order they were made.
    public func groups(on board: String) -> [NoteGroup] {
        groups.filter { $0.board == board }
    }

    /// The group a note is in on a board, if it is in one there.
    public func group(holding noteID: UUID, on board: String) -> NoteGroup? {
        groups.first { $0.board == board && $0.noteIDs.contains(noteID) }
    }

    /// The notes of a group that can be seen: those that still exist and
    /// have not been archived, in the order they were added.
    public func members(of group: NoteGroup) -> [Note] {
        group.noteIDs.compactMap { id in
            guard let note = note(id), !note.isArchived else { return nil }
            return note
        }
    }

    /// Puts notes together as a group on a board, at `position`. A note
    /// already in a group on that board leaves it first. Fewer than two
    /// notes make no group.
    @discardableResult
    public func makeGroup(
        on board: String, of noteIDs: [UUID], at position: CGPoint, name: String = "", date: Date = Date()
    ) -> NoteGroup? {
        undoable("Group") {
            var unique: [UUID] = []
            for id in noteIDs where note(id) != nil && !unique.contains(id) { unique.append(id) }
            guard unique.count >= 2 else { return nil }
            for id in unique { dropFromGroups(id) { $0.board == board } }
            let group = NoteGroup(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), board: board, noteIDs: unique,
                position: CanvasPoint(position), createdAt: date)
            groups.append(group)
            scheduleSave()
            return group
        }
    }

    /// Adds a note to a group. If it was in another group on that board, it
    /// leaves that one.
    public func addToGroup(noteID: UUID, groupID: UUID) {
        undoable("Add to Group") {
            guard note(noteID) != nil, let target = group(groupID), !target.noteIDs.contains(noteID) else { return }
            dropFromGroups(noteID) { $0.board == target.board }
            guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
            groups[index].noteIDs.append(noteID)
            scheduleSave()
        }
    }

    /// Takes a note out of a group. A group left with one note is no longer
    /// a group: it goes, and that note is a card again.
    public func removeFromGroup(noteID: UUID, groupID: UUID) {
        undoable("Remove from Group") {
            dropFromGroups(noteID) { $0.id == groupID }
            scheduleSave()
        }
    }

    /// A name for the group, or none: an empty name is allowed.
    public func renameGroup(id: UUID, to name: String) {
        undoable("Rename Group") {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].name != name else { return }
            groups[index].name = name
            scheduleSave()
        }
    }

    public func moveGroup(id: UUID, to position: CGPoint) {
        undoable("Move Group") {
            let point = CanvasPoint(position)
            guard let index = groups.firstIndex(where: { $0.id == id }), groups[index].position != point else { return }
            groups[index].position = point
            scheduleSave()
        }
    }

    /// Ends a group. Its notes are untouched and become cards again.
    public func ungroup(id: UUID) {
        undoable("Ungroup") {
            guard groups.contains(where: { $0.id == id }) else { return }
            groups.removeAll { $0.id == id }
            scheduleSave()
        }
    }

    /// Takes a note out of the groups that match, and ends any group that is
    /// left with fewer than two notes.
    private func dropFromGroups(_ noteID: UUID, where matches: (NoteGroup) -> Bool) {
        for index in groups.indices where matches(groups[index]) {
            groups[index].noteIDs.removeAll { $0 == noteID }
        }
        groups.removeAll { $0.noteIDs.count < 2 }
    }

    // MARK: Undo

    /// Everything that undo puts back.
    private struct Snapshot: Equatable {
        var notes: [Note]
        var sampleNotes: [Note]
        var projects: [Project]
        var canvases: [ProjectCanvas]
        var groups: [NoteGroup]
    }

    private var snapshot: Snapshot {
        Snapshot(notes: notes, sampleNotes: sampleNotes, projects: projects, canvases: canvases, groups: groups)
    }

    /// Runs a change and, if it changed anything, records it as one step
    /// to undo under `name` (shown as "Undo <name>" in the Edit menu).
    /// Changes made in the same turn of the run loop, such as the moves
    /// that set an ungrouped group's cards down, undo together.
    private func undoable<T>(_ name: @autoclosure () -> String, _ change: () -> T) -> T {
        guard !isRestoring else { return change() }
        let before = snapshot
        let label = name()
        let result = change()
        if snapshot != before { registerUndo(back: before, named: label) }
        return result
    }

    private func registerUndo(back state: Snapshot, named name: String) {
        undoManager.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated { store.put(back: state, named: name) }
        }
        undoManager.setActionName(name)
    }

    /// Puts an earlier state back, and records the state it replaces so the
    /// step can be redone (or undone again after a redo).
    private func put(back state: Snapshot, named name: String) {
        if textEdit != nil { finishTextEdit() }
        let current = snapshot
        registerUndo(back: current, named: name)
        isRestoring = true
        defer { isRestoring = false }
        // What happened on its own since is not taken back: a card that has
        // been looked at stays looked at, and a link's card keeps its picture.
        func merged(_ old: [Note], with now: [Note]) -> [Note] {
            let byID = Dictionary(now.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return old.map { note in
                guard let latest = byID[note.id] else { return note }
                var note = note
                note.seen = note.seen || latest.seen
                note.imagePixelSize = latest.imagePixelSize
                note.imageScale = latest.imageScale
                return note
            }
        }
        notes = merged(state.notes, with: current.notes)
        sampleNotes = merged(state.sampleNotes, with: current.sampleNotes)
        projects = state.projects
        canvases = state.canvases
        groups = state.groups
        // Pictures of notes that this takes away wait for the Trash; those
        // it brings back are no longer waiting.
        let kept = Set(notes.map(\.imagePath))
        unusedImagePaths.formUnion(current.notes.map(\.imagePath).filter { !kept.contains($0) })
        unusedImagePaths.subtract(kept)
        scheduleSave()
    }

    /// Starts typing into a note's text. Until `endTextEdit`, the text can
    /// change with every key; all of it is undone as one step.
    public func beginTextEdit(id: UUID) {
        if textEdit != nil { finishTextEdit() }
        guard let note = note(id) else { return }
        textEdit = (id, note.note)
    }

    /// Ends typing into a note's text, recording the edit as one step to undo
    /// if the text changed.
    public func endTextEdit(id: UUID) {
        guard textEdit?.id == id else { return }
        finishTextEdit()
    }

    private func finishTextEdit() {
        guard let edit = textEdit else { return }
        textEdit = nil
        // Everything as it is now, but with the note's text as it was before
        // the typing: other changes made meanwhile are steps of their own.
        var before = snapshot
        func revert(_ list: inout [Note]) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == edit.id }), list[index].note != edit.before
            else { return false }
            list[index].note = edit.before
            return true
        }
        if revert(&before.notes) || revert(&before.sampleNotes) {
            registerUndo(back: before, named: "Edit Note")
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let data = encodedIndex() else { return }
        writer.write(data)
    }

    /// Writes everything that is pending and waits for it to reach the disk.
    /// Called before the app exits.
    public func flush() {
        if textEdit != nil { finishTextEdit() }
        if pendingSave != nil { saveNow() }
        trashUnusedImages()
        writer.waitUntilIdle()
        ImageFiles.waitUntilIdle()
    }

    /// Sends the pictures of deleted notes to the Trash. Undo can no longer
    /// bring them back afterwards, so the steps that could are forgotten.
    private func trashUnusedImages() {
        let kept = Set(notes.map(\.imagePath))
        let urls = unusedImagePaths.subtracting(kept).map { directory.appendingPathComponent($0) }
        unusedImagePaths = []
        guard !urls.isEmpty else { return }
        undoManager.removeAllActions()
        refreshUndoNames()
        ImageFiles.queue.async {
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }

    private func encodedIndex() -> Data? {
        do {
            // Only what is saved is written: a made-up note's place on a
            // canvas would point at nothing the next time the file is read.
            let saved = Set(notes.map(\.id))
            let written = canvases.map { canvas in
                var canvas = canvas
                canvas.cards.removeAll { !saved.contains($0.noteID) }
                return canvas
            }
            // The same for groups: one left with fewer than two saved notes
            // is not a group on disk.
            let kept = groups.compactMap { group -> NoteGroup? in
                var group = group
                group.noteIDs.removeAll { !saved.contains($0) }
                return group.noteIDs.count >= 2 ? group : nil
            }
            return try Self.encoder.encode(
                NoteIndex(
                    version: NoteIndex.currentVersion, notes: notes, projects: projects, canvases: written,
                    groups: kept))
        } catch {
            Self.log.error("index encode failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Serialises index writes so a slow disk never blocks the main thread and
/// writes never overlap. Each write replaces the file atomically.
private final class IndexWriter: Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "blog.terminal.index-writer", qos: .utility)
    private static let log = Logger(subsystem: "blog.terminal.app", category: "store")

    init(url: URL) {
        self.url = url
    }

    func write(_ data: Data) {
        let url = self.url
        queue.async {
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                Self.log.error("index write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func waitUntilIdle() {
        queue.sync {}
    }
}

/// PNG encoding and decoding, off the main thread.
public enum ImageFiles {

    static let queue = DispatchQueue(label: "blog.terminal.image-files", qos: .userInitiated)
    private static let log = Logger(subsystem: "blog.terminal.app", category: "images")

    /// Encodes `image` as PNG at `url` in the background.
    public static func write(_ image: CapturedImage, to url: URL) {
        queue.async {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try writePNG(image.cgImage, scale: image.scale, to: url)
            } catch {
                log.error("image write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func waitUntilIdle() {
        queue.sync {}
    }

    static func writePNG(_ image: CGImage, scale: CGFloat, to url: URL) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        // Record the density so other apps show the image at its on-screen size.
        let dpi = 72 * scale
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// An image averaged down to a few pixels across and a few down.
    static func pixelated(_ image: CGImage, columns: Int, rows: Int) -> CGImage? {
        guard
            let context = CGContext(
                data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        return context.makeImage()
    }

    /// The colour a picture is remembered by: the hue there is most of in
    /// it, as it appears in the picture, not the average of everything.
    ///
    /// A plain average of a page with one chart on it is off-white whatever
    /// colour the chart is, and of a page with a red chart and a green one,
    /// mud. So the coloured parts are sorted by hue, the fullest family of
    /// hues is taken, and the answer is the average of that family alone.
    /// The less of the picture is coloured at all, the more the answer leans
    /// back towards the plain average: a page of nothing but text comes out
    /// the grey of its text and paper.
    static func dominantColour(of image: CGImage) -> RGBColour? {
        let columns = 32
        let rows = 24
        guard
            let context = CGContext(
                data: nil, width: columns, height: rows, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: columns, height: rows))
        guard let data = context.data else { return nil }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow

        // Twelve families of hue round the wheel.
        let families = 12
        var weights = [Double](repeating: 0, count: families)
        var reds = [Double](repeating: 0, count: families)
        var greens = [Double](repeating: 0, count: families)
        var blues = [Double](repeating: 0, count: families)
        var plain = (red: 0.0, green: 0.0, blue: 0.0)
        var colourfulness = 0.0
        for row in 0..<rows {
            for column in 0..<columns {
                let pixel = bytes + row * stride + column * 4
                let colour = RGBColour(
                    red: Double(pixel[0]) / 255, green: Double(pixel[1]) / 255, blue: Double(pixel[2]) / 255)
                plain.red += colour.red
                plain.green += colour.green
                plain.blue += colour.blue
                let chroma =
                    max(colour.red, colour.green, colour.blue) - min(colour.red, colour.green, colour.blue)
                let share = chroma * chroma
                colourfulness += share
                // Too little colour to say what hue it is.
                guard chroma > 0.08 else { continue }
                let family = min(Int(colour.hsb.hue * Double(families)), families - 1)
                weights[family] += share
                reds[family] += share * colour.red
                greens[family] += share * colour.green
                blues[family] += share * colour.blue
            }
        }
        let count = Double(columns * rows)
        let average = RGBColour(red: plain.red / count, green: plain.green / count, blue: plain.blue / count)

        // The fullest family, its neighbours on the wheel counting for half:
        // an orange is partly a red and partly a yellow.
        func neighbours(of family: Int) -> [Int] {
            [(family + families - 1) % families, family, (family + 1) % families]
        }
        func fullness(_ family: Int) -> Double {
            let around = neighbours(of: family)
            return weights[around[1]] + 0.5 * (weights[around[0]] + weights[around[2]])
        }
        let fullest = (0..<families).max { fullness($0) < fullness($1) } ?? 0
        let members = neighbours(of: fullest)
        let weight = members.reduce(0) { $0 + weights[$1] }
        guard weight > 0 else { return average }
        let vivid = RGBColour(
            red: members.reduce(0) { $0 + reds[$1] } / weight,
            green: members.reduce(0) { $0 + greens[$1] } / weight,
            blue: members.reduce(0) { $0 + blues[$1] } / weight)

        // From one part in a few thousand of the picture being coloured, the
        // colour starts to count; from about one part in a hundred, it is
        // the answer.
        let low = 0.0004
        let high = 0.004
        let t = min(max((colourfulness / count - low) / (high - low), 0), 1)
        let trust = t * t * (3 - 2 * t)
        return RGBColour(
            red: average.red + (vivid.red - average.red) * trust,
            green: average.green + (vivid.green - average.green) * trust,
            blue: average.blue + (vivid.blue - average.blue) * trust)
    }

    /// Decodes an image file, downsampled so its longest side is at most
    /// `maxPixelSize` pixels. Pass `nil` for full resolution.
    public static func load(_ url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// What the mini map knows of a card's screenshot.
struct MapSwatch {

    /// The screenshot as a few blocks of colour.
    let image: CGImage
    /// The colour the screenshot is remembered by.
    let colour: RGBColour

    init(image: CGImage, colour: RGBColour) {
        self.image = image
        self.colour = colour
    }

    /// Boils a screenshot down, or `nil` if it cannot be drawn.
    init?(reducing screenshot: CGImage) {
        guard
            let image = ImageFiles.pixelated(screenshot, columns: 4, rows: 3),
            let colour = ImageFiles.dominantColour(of: screenshot)
        else { return nil }
        self.init(image: image, colour: colour)
    }
}

/// How large a decoded screenshot is wanted.
public enum ImageTier: Sendable, Hashable {
    /// For a card at reading size.
    case card
    /// For a card on a board zoomed far out, and for the timeline's tiles.
    case thumbnail

    /// Longest side, in pixels.
    public var maxPixelSize: Int {
        switch self {
        case .card: 1600
        case .thumbnail: 400
        }
    }
}

/// Decoded screenshots, keyed by note, in two sizes.
///
/// A board of a month or of all time can show hundreds of cards, each a few
/// dozen points wide. Decoding every screenshot at reading size for that
/// would take hundreds of megabytes, so small cards and the timeline's tiles
/// ask for thumbnails instead.
@MainActor
@Observable
public final class ImageCache {

    /// Longest side, in pixels, of the images shown on cards at reading size.
    public nonisolated static let nodePixelSize = ImageTier.card.maxPixelSize

    @ObservationIgnored private let cards = NSCache<NSUUID, ImageBox>()
    @ObservationIgnored private let thumbnails = NSCache<NSUUID, ImageBox>()
    /// Each screenshot boiled down to a handful of pixels, for the mini map.
    @ObservationIgnored private let swatches = NSCache<NSUUID, SwatchBox>()

    private final class ImageBox {
        let image: CGImage
        init(_ image: CGImage) { self.image = image }
    }

    private final class SwatchBox {
        let swatch: MapSwatch
        init(_ swatch: MapSwatch) { self.swatch = swatch }
    }

    /// How many screenshots are being read from disk right now.
    @ObservationIgnored private var reading = 0

    /// Whether any screenshot that has been asked for is still on its way.
    /// For the offscreen renders, which have to know when a screen is complete.
    var isReading: Bool { reading > 0 }

    public init() {
        cards.countLimit = 200
        // Decoded bitmaps are large; cap what is held at roughly half a gigabyte.
        cards.totalCostLimit = 512 * 1024 * 1024
        thumbnails.countLimit = 2000
        thumbnails.totalCostLimit = 256 * 1024 * 1024
    }

    private func cache(_ tier: ImageTier) -> NSCache<NSUUID, ImageBox> {
        tier == .card ? cards : thumbnails
    }

    public func image(for id: UUID, tier: ImageTier = .card) -> CGImage? {
        cache(tier).object(forKey: id as NSUUID)?.image
    }

    /// Makes a just-captured image available before its file has been written.
    public func insert(_ image: CGImage, for id: UUID, tier: ImageTier = .card) {
        cache(tier).setObject(ImageBox(image), forKey: id as NSUUID, cost: image.bytesPerRow * image.height)
    }

    public func remove(_ id: UUID) {
        cards.removeObject(forKey: id as NSUUID)
        thumbnails.removeObject(forKey: id as NSUUID)
        swatches.removeObject(forKey: id as NSUUID)
    }

    /// A note's screenshot as the mini map knows it: a few blocks of colour
    /// to draw the card with, and the one colour it is remembered by.
    func swatch(id: UUID, url: URL) async -> MapSwatch? {
        if let cached = swatches.object(forKey: id as NSUUID)?.swatch { return cached }
        reading += 1
        defer { reading -= 1 }
        guard let thumbnail = await load(id: id, url: url, tier: .thumbnail) else { return nil }
        let reduced = await Task.detached(priority: .utility) {
            UncheckedBox(MapSwatch(reducing: thumbnail))
        }.value.value
        if let reduced { swatches.setObject(SwatchBox(reduced), forKey: id as NSUUID) }
        return reduced
    }

    /// Returns a note's image at the size asked for, decoding it if necessary.
    public func load(id: UUID, url: URL, tier: ImageTier = .card) async -> CGImage? {
        if let cached = image(for: id, tier: tier) { return cached }
        reading += 1
        defer { reading -= 1 }
        let limit = tier.maxPixelSize
        let decoded = await Task.detached(priority: .userInitiated) {
            UncheckedBox(ImageFiles.load(url, maxPixelSize: limit))
        }.value.value
        if let decoded {
            insert(decoded, for: id, tier: tier)
            return decoded
        }
        // A capture saved a moment ago may not be on disk yet: use what was
        // put in memory for it, whatever its size.
        return image(for: id, tier: .card)
    }
}
