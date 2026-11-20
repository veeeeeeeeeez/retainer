import Foundation
import Observation

/// What the bar at the top of the board is showing, and the moves made from
/// it: between the timeline and the projects, into a project and back out,
/// and making, renaming and deleting projects and canvases.
///
/// The bar is one strip with two modes. In timeline mode its tiles are days
/// (or weeks, or months). In projects mode they are the projects, and once a
/// project has been opened, that project's canvases. What is in front of the
/// user is `CanvasModel.board`; the bar only chooses it. Looking through the
/// list of projects does not change the board until a canvas is picked.
@MainActor
@Observable
public final class Navigation {

    public enum Mode: String, CaseIterable, Sendable {
        case timeline
        case projects

        /// The word on the switch.
        public var title: String { rawValue }

        /// The small symbol before the word: a calendar for the days, a
        /// folder for the projects.
        public var symbol: String {
            switch self {
            case .timeline: "calendar"
            case .projects: "folder"
            }
        }
    }

    public private(set) var mode: Mode = .timeline
    /// The project whose canvases the strip is showing. `nil` while it is
    /// showing the list of projects.
    public private(set) var browsingProjectID: UUID?
    /// The project or canvas whose name is being typed.
    public private(set) var renamingID: UUID?
    /// The project or canvas whose "delete" has been chosen once and is
    /// waiting to be chosen again.
    public private(set) var confirmingDeleteID: UUID?

    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let canvas: CanvasModel
    /// The canvas each project was last looked at on.
    @ObservationIgnored private var lastCanvas: [UUID: UUID] = [:]

    public init(store: NoteStore, canvas: CanvasModel) {
        self.store = store
        self.canvas = canvas
    }

    // MARK: Switching

    /// Switches the bar between the timeline and the projects.
    ///
    /// Going to the timeline puts the last day (or week, or month) looked at
    /// back in front. Going to the projects goes back into the project of
    /// the canvas last looked at, if there is one; otherwise it shows the
    /// list, and the board stays as it is until a canvas is picked.
    public func setMode(_ newMode: Mode) {
        settle()
        switch newMode {
        case .timeline:
            mode = .timeline
            canvas.show(canvas.period)
        case .projects:
            mode = .projects
            if let project = store.project(store.canvas(canvas.canvasID)?.projectID) {
                browsingProjectID = project.id
            } else if let browsing = browsingProjectID, store.project(browsing) != nil {
                openProject(browsing)
            } else {
                browsingProjectID = nil
            }
        }
    }

    /// The timeline was used (a day picked, the scale changed, a new note
    /// gone to): the bar follows.
    public func timelineUsed() {
        settle()
        mode = .timeline
    }

    /// Shows a project's canvases in the strip, and puts the one last looked
    /// at (or its first) in front. A project with no canvases leaves the
    /// board as it is.
    public func openProject(_ id: UUID) {
        guard store.project(id) != nil else { return }
        settle()
        mode = .projects
        browsingProjectID = id
        let canvases = store.canvases(in: id)
        let target = canvases.first { $0.id == lastCanvas[id] } ?? canvases.first
        if let target { show(target) }
    }

    /// Puts a canvas in front, with the strip showing its project.
    public func openCanvas(_ id: UUID) {
        guard let target = store.canvas(id) else { return }
        settle()
        mode = .projects
        browsingProjectID = target.projectID
        show(target)
    }

    /// Back out of a project to the list of projects. The board stays.
    public func back() {
        settle()
        browsingProjectID = nil
    }

    private func show(_ target: ProjectCanvas) {
        lastCanvas[target.projectID] = target.id
        canvas.show(.canvas(target.id))
    }

    // MARK: Making

    /// Makes a project with one canvas in it, opens that canvas, and starts
    /// the project's name being typed.
    @discardableResult
    public func newProject() -> Project {
        settle()
        let project = store.addProject(name: Self.nextName("Project", among: store.projects.map(\.name)))
        mode = .projects
        browsingProjectID = project.id
        if let first = store.addCanvas(in: project.id, name: "Canvas 1") { show(first) }
        renamingID = project.id
        return project
    }

    /// The project a new canvas would go in: the one being looked through,
    /// or the one whose canvas is in front.
    public var projectForNewCanvas: UUID? {
        if mode == .projects, let browsing = browsingProjectID, store.project(browsing) != nil { return browsing }
        return store.canvas(canvas.canvasID)?.projectID
    }

    /// Makes a canvas in the project being looked at, opens it, and starts
    /// its name being typed.
    @discardableResult
    public func newCanvas() -> ProjectCanvas? {
        guard let projectID = projectForNewCanvas else { return nil }
        settle()
        let names = store.canvases(in: projectID).map(\.name)
        guard let made = store.addCanvas(in: projectID, name: Self.nextName("Canvas", among: names)) else { return nil }
        mode = .projects
        browsingProjectID = projectID
        show(made)
        renamingID = made.id
        return made
    }

    /// "Canvas 3" when there are already a "Canvas 1" and a "Canvas 2":
    /// the first number not taken.
    static func nextName(_ word: String, among names: [String]) -> String {
        var number = 1
        while names.contains("\(word) \(number)") { number += 1 }
        return "\(word) \(number)"
    }

    // MARK: Renaming

    public func startRenaming(_ id: UUID) {
        confirmingDeleteID = nil
        renamingID = id
    }

    /// Ends the typing and keeps the name, for whichever of a project or a
    /// canvas `id` is. An empty name leaves the old one.
    public func rename(_ id: UUID, to name: String) {
        if store.project(id) != nil {
            store.renameProject(id: id, to: name)
        } else {
            store.renameCanvas(id: id, to: name)
        }
        if renamingID == id { renamingID = nil }
    }

    public func cancelRename() {
        renamingID = nil
    }

    // MARK: Deleting

    /// The first of the two clicks it takes to delete a project or a canvas.
    public func requestDelete(_ id: UUID) {
        renamingID = nil
        confirmingDeleteID = id
    }

    public func cancelDelete() {
        confirmingDeleteID = nil
    }

    /// The second click. Deletes the project (and its canvases) or the
    /// canvas that is waiting. The notes that were on them are untouched.
    /// If the canvas in front goes, its neighbour takes its place, or the
    /// last day looked at when there is none.
    public func confirmDelete() {
        guard let id = confirmingDeleteID else { return }
        confirmingDeleteID = nil
        renamingID = nil

        if store.project(id) != nil {
            let gone = store.canvases(in: id).map(\.id)
            if let front = canvas.canvasID, gone.contains(front) { canvas.show(canvas.period) }
            store.deleteProject(id: id)
            for canvasID in gone { canvas.forgetViewport(of: .canvas(canvasID)) }
            lastCanvas[id] = nil
            if browsingProjectID == id { browsingProjectID = nil }
        } else if let target = store.canvas(id) {
            let siblings = store.canvases(in: target.projectID)
            if canvas.canvasID == id {
                let index = siblings.firstIndex { $0.id == id } ?? 0
                let neighbour = index > 0 ? siblings[index - 1] : siblings.dropFirst().first
                if let neighbour {
                    show(neighbour)
                } else {
                    canvas.show(canvas.period)
                }
            }
            store.deleteCanvas(id: id)
            canvas.forgetViewport(of: .canvas(id))
            if lastCanvas[target.projectID] == id { lastCanvas[target.projectID] = nil }
        }
    }

    /// Any other move ends a name being typed or a delete waiting.
    private func settle() {
        renamingID = nil
        confirmingDeleteID = nil
    }
}
