import CoreGraphics
import Foundation
import Observation

/// The persisted switches from the menu bar.
@MainActor
@Observable
public final class AppSettings {

    /// Whether transcripts get the tidy pass. On by default.
    public var tidyEnabled: Bool {
        didSet { defaults.set(tidyEnabled, forKey: Self.tidyKey) }
    }

    /// Whether the app window uses the light palette. Off by default: the
    /// app is dark unless asked otherwise.
    public var lightMode: Bool {
        didSet {
            guard lightMode != oldValue else { return }
            defaults.set(lightMode, forKey: Self.lightModeKey)
            onLightModeChange?(lightMode)
        }
    }

    /// Called when `lightMode` changes, so the app can switch its appearance.
    @ObservationIgnored public var onLightModeChange: ((Bool) -> Void)?

    /// Whether the timeline is filled out with made-up past days. On for
    /// now, while there are few real days to look at.
    public var sampleDays: Bool {
        didSet {
            guard sampleDays != oldValue else { return }
            defaults.set(sampleDays, forKey: Self.sampleDaysKey)
            onSampleDaysChange?(sampleDays)
        }
    }

    /// Called when `sampleDays` changes, so the app can add or remove them.
    @ObservationIgnored public var onSampleDaysChange: ((Bool) -> Void)?

    /// How the board shows where its cards are: the window's own edges lit
    /// towards them, unless the orb in the corner has been asked for.
    public var miniMapStyle: MiniMapStyle {
        didSet { defaults.set(miniMapStyle.rawValue, forKey: Self.miniMapStyleKey) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private static let tidyKey = "tidyEnabled"
    private static let lightModeKey = "lightMode"
    private static let sampleDaysKey = "sampleDays"
    private static let miniMapStyleKey = "miniMapStyle"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tidyEnabled = defaults.object(forKey: Self.tidyKey) as? Bool ?? true
        self.lightMode = defaults.bool(forKey: Self.lightModeKey)
        self.sampleDays = defaults.object(forKey: Self.sampleDaysKey) as? Bool ?? true
        self.miniMapStyle = defaults.string(forKey: Self.miniMapStyleKey).flatMap(MiniMapStyle.init(rawValue:)) ?? .edges
    }
}

/// Which board is on screen and how it is panned and zoomed, which card is
/// open or being edited, where cards go, and which of them have been looked
/// at.
///
/// A board is the notes of one `Period`: a day, a week, a month, or all
/// time. A day's board is where its cards really live, each at the position
/// saved with its note. A wider board shows the same cards with every day
/// moved as a block to a place of its own (`ClusterLayout`). Each board
/// keeps its own pan and zoom.
///
/// Board coordinates are points at 100% zoom with an arbitrary origin; the
/// view shows them scaled by `scale` and shifted by `offset`.
@MainActor
@Observable
public final class CanvasModel {

    public nonisolated static let minScale: CGFloat = 0.1
    public nonisolated static let maxScale: CGFloat = 2.0
    /// Width of every card at 100% zoom.
    public nonisolated static let nodeWidth: CGFloat = 400
    /// The tallest a card's screenshot is shown at 100% zoom.
    public nonisolated static let maxImageHeight: CGFloat = 440
    /// How long a card has to be in view before it counts as seen.
    public nonisolated static let seenAfter: TimeInterval = 1.2
    /// Room left clear when a board is fitted to the window: at the top for
    /// the title bar and the timeline that floats under it, at the bottom
    /// for the input box.
    public nonisolated static let topClearance: CGFloat = 162
    public nonisolated static let inputClearance: CGFloat = 124

    /// What is on screen: a stretch of time's board, or a project's canvas.
    public private(set) var board: Board
    /// The day, week, month or all time whose board is on screen, or was
    /// the last time one was: what the timeline goes back to.
    public private(set) var period: Period

    /// Where the board's origin sits in the view, in points.
    public private(set) var offset: CGSize
    public private(set) var scale: CGFloat
    public private(set) var viewSize: CGSize = .zero

    /// The card whose note is being edited.
    public var editingNoteID: UUID?
    /// The note whose screenshot is shown at full size.
    public var viewingNoteID: UUID?
    /// The note whose card is opened out over the board.
    public private(set) var expandedNoteID: UUID?
    /// The note whose "delete" has had its first click and waits for the second.
    public var confirmingDeleteID: UUID?
    /// The group that is opened out over the board, to see what is in it.
    public var expandedGroupID: UUID?
    /// The group that has just been made and is having its name typed, on its tile.
    public var namingGroupID: UUID?
    /// Whether the board is showing the period's archive instead of its notes.
    public var showingArchive = false {
        didSet {
            guard showingArchive != oldValue else { return }
            collapse()
            resetSeenTracking()
            displayedOrigins = [:]
            if showsDays { needsFit = true }
        }
    }
    /// A board of several days has no pan and zoom of its own until it has
    /// been looked at once; until then it is fitted to the window as soon as
    /// its layout is known.
    public private(set) var needsFit = false

    @ObservationIgnored public let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var hasViewport: Bool
    @ObservationIgnored private var pendingPersist: DispatchWorkItem?
    /// Heights of cards as actually laid out, at 100% zoom.
    @ObservationIgnored private var measuredHeights: [UUID: CGFloat] = [:]
    /// Heights worked out for cards that have not been laid out, each with
    /// what it was worked out from. Estimating means setting the note's text
    /// to count its lines, and a wide board asks for every card's frame
    /// each time it is drawn: once per card is enough.
    @ObservationIgnored private var estimatedHeights: [UUID: (signature: Int, height: CGFloat)] = [:]
    /// Where cards are drawn on a board of several days.
    @ObservationIgnored private var displayedOrigins: [UUID: CGPoint] = [:]
    /// When each unseen card came into view.
    @ObservationIgnored private var visibleSince: [UUID: Date] = [:]
    @ObservationIgnored private var lastUnseenShown: UUID?
    /// Pan and zoom of every board that has been shown: x, y, scale.
    @ObservationIgnored private var viewports: [String: [Double]]
    private static let viewportsKey = "boardViewports"
    private static let fallbackViewSize = CGSize(width: 1180, height: 760)

    /// Starts on today's board.
    public init(
        defaults: UserDefaults = .standard, calendar: Calendar = .current, now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        viewports = (defaults.dictionary(forKey: Self.viewportsKey) as? [String: [Double]]) ?? [:]
        let today = Period.containing(now(), scale: .day, calendar: calendar)
        period = today
        board = .period(today)
        if let saved = Self.viewport(from: viewports[today.id]) {
            offset = saved.offset
            scale = saved.scale
            hasViewport = true
        } else {
            offset = .zero
            scale = 1
            hasViewport = false
        }
    }

    // MARK: Which board

    public var timeScale: TimeScale { period.scale }

    /// The current moment, as this model sees it.
    public var currentDate: Date { now() }

    /// Today's own board, where new captures go, is the one on screen.
    public var isShowingToday: Bool {
        guard case .period(let period) = board else { return false }
        return period.scale == .day && period.contains(now())
    }

    /// The canvas on screen, if it is one.
    public var canvasID: UUID? { board.canvasID }

    /// The board on screen is of several days at once, each set out as a
    /// block under its date.
    public var showsDays: Bool {
        guard case .period(let period) = board else { return false }
        return period.scale != .day
    }

    /// The cards of the board on screen: a period's notes or its archive,
    /// or what has been put on a canvas, each where it sits there. A card
    /// that is in a group on this board sits where the group is.
    public func notes(in store: NoteStore) -> [Note] {
        var notes: [Note]
        switch board {
        case .period(let period): notes = store.notes(in: period, archived: showingArchive)
        case .canvas(let id): notes = store.notes(on: id)
        }
        let lookup = groupLookup(in: store)
        guard !lookup.isEmpty else { return notes }
        for index in notes.indices {
            if let group = lookup[notes[index].id] { notes[index].position = group.position }
        }
        return notes
    }

    // MARK: Groups

    /// How large a group's tile is at 100% zoom: a little larger than a card.
    public nonisolated static let groupSize = CGSize(width: 460, height: 346)

    /// A group on the board in front, with those of its notes that can be seen.
    public struct BoardGroup: Identifiable {
        public let group: NoteGroup
        public let members: [Note]
        public var id: UUID { group.id }
    }

    /// What a dragged card is over: another card to make a group with, or a
    /// group to join.
    public enum GroupTarget: Equatable, Sendable {
        case note(UUID)
        case group(UUID)

        public var isGroup: Bool {
            if case .group = self { return true }
            return false
        }
    }

    /// Which board a note's card is on, of the boards in front: the canvas,
    /// or the note's own day.
    public func boardKey(for note: Note) -> String {
        if board.isCanvas { return board.id }
        return Period.containing(note.timestamp, scale: .day, calendar: calendar).id
    }

    /// The group each grouped note of the board in front is in. Nothing is
    /// grouped in the archive.
    private func groupLookup(in store: NoteStore) -> [UUID: NoteGroup] {
        guard !showingArchive, !store.groups.isEmpty else { return [:] }
        var lookup: [UUID: NoteGroup] = [:]
        for group in store.groups where board.isCanvas ? group.board == board.id : group.board.hasPrefix("day:") {
            for id in group.noteIDs { lookup[id] = group }
        }
        return lookup
    }

    /// The groups to draw on the board in front, each with the notes of it
    /// that are on this board and not archived.
    public func groups(in store: NoteStore) -> [BoardGroup] {
        guard !showingArchive, !store.groups.isEmpty else { return [] }
        return store.groups.compactMap { group in
            var members = store.members(of: group)
            switch board {
            case .canvas: guard group.board == board.id else { return nil }
            case .period(let period):
                guard group.board.hasPrefix("day:") else { return nil }
                members = members.filter { period.contains($0.timestamp) }
            }
            return members.isEmpty ? nil : BoardGroup(group: group, members: members)
        }
    }

    /// The space a group's tile takes up on its board.
    public func frame(of group: NoteGroup) -> CGRect {
        CGRect(origin: group.position.cgPoint, size: Self.groupSize)
    }

    /// What a card being dragged is over, when its middle is inside another
    /// card or a group's tile. `translation` is how far it has been dragged,
    /// in board units. Only where cards can be dragged at all: a day's board
    /// or a canvas, not the archive.
    public func groupingTarget(for dragged: Note, movedBy translation: CGSize, in store: NoteStore) -> GroupTarget? {
        guard !showingArchive, !showsDays else { return nil }
        let frame = frame(of: dragged).offsetBy(dx: translation.width, dy: translation.height)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var best: (target: GroupTarget, distance: CGFloat)?
        func consider(_ target: GroupTarget, _ other: CGRect) {
            guard other.contains(centre) else { return }
            let distance = hypot(other.midX - centre.x, other.midY - centre.y)
            if best == nil || distance < best!.distance { best = (target, distance) }
        }
        let groups = groups(in: store)
        let grouped = Set(groups.flatMap { $0.group.noteIDs })
        for entry in groups { consider(.group(entry.group.id), self.frame(of: entry.group)) }
        for note in notes(in: store) where note.id != dragged.id && !grouped.contains(note.id) {
            consider(.note(note.id), self.frame(of: note))
        }
        return best?.target
    }

    /// A card was dropped on `target`: it joins that group, or makes one
    /// with that card, which takes the card's place on the board.
    public func group(_ dragged: Note, with target: GroupTarget, in store: NoteStore) {
        switch target {
        case .group(let id):
            store.addToGroup(noteID: dragged.id, groupID: id)
        case .note(let id):
            guard let other = notes(in: store).first(where: { $0.id == id }) else { return }
            let made = store.makeGroup(
                on: boardKey(for: other), of: [other.id, dragged.id], at: other.position.cgPoint)
            // A new group asks for its name straight away, on its tile.
            namingGroupID = made?.id
        }
    }

    /// Ends a group on the board in front: its cards are set down round
    /// where its tile was, clear of one another and of everything else.
    public func ungroup(_ group: NoteGroup, in store: NoteStore) {
        if expandedGroupID == group.id { expandedGroupID = nil }
        let centre = CGPoint(x: frame(of: group).midX, y: frame(of: group).midY)
        var taken = notes(in: store).filter { !group.noteIDs.contains($0.id) }.map { frame(of: $0) }
        for member in store.members(of: group) {
            let size = frame(of: member).size
            let origin = CanvasLayout.freeOrigin(for: size, near: centre, avoiding: taken)
            setPosition(of: member.id, to: origin, on: group.board, in: store)
            taken.append(CGRect(origin: origin, size: size))
        }
        store.ungroup(id: group.id)
    }

    /// Takes one card out of a group and sets it down beside the tile. If
    /// that leaves a single card, the group ends and the card takes its place.
    public func remove(_ note: Note, from group: NoteGroup, in store: NoteStore) {
        guard group.noteIDs.contains(note.id) else { return }
        let tile = frame(of: group)
        let size = frame(of: note).size
        let taken = notes(in: store).filter { $0.id != note.id }.map { frame(of: $0) } + [tile]
        let beside = CGPoint(x: tile.maxX + CanvasLayout.gap + size.width / 2, y: tile.minY + size.height / 2)
        setPosition(
            of: note.id, to: CanvasLayout.freeOrigin(for: size, near: beside, avoiding: taken), on: group.board,
            in: store)
        if let last = group.noteIDs.first(where: { $0 != note.id }), group.noteIDs.count == 2 {
            setPosition(of: last, to: tile.origin, on: group.board, in: store)
            if expandedGroupID == group.id { expandedGroupID = nil }
        }
        store.removeFromGroup(noteID: note.id, groupID: group.id)
    }

    /// Writes where a card is on a board given by its key: a canvas's own
    /// place for it, or the note's place on its day.
    private func setPosition(of noteID: UUID, to position: CGPoint, on board: String, in store: NoteStore) {
        if let canvas = store.canvases.first(where: { Board.canvas($0.id).id == board }) {
            store.place(noteID: noteID, on: canvas.id, at: position)
        } else {
            store.move(id: noteID, to: position)
        }
    }

    /// The cards of the board on screen that have not been looked at yet.
    public func unseenNotes(in store: NoteStore) -> [Note] {
        switch board {
        case .period(let period): store.unseenNotes(in: period)
        case .canvas(let id): store.unseenNotes(on: id)
        }
    }

    public var today: Period {
        Period.containing(now(), scale: .day, calendar: calendar)
    }

    private static func viewport(from stored: [Double]?) -> (offset: CGSize, scale: CGFloat)? {
        guard let stored, stored.count == 3, stored.allSatisfy(\.isFinite), stored[2] > 0 else { return nil }
        return (CGSize(width: stored[0], height: stored[1]), min(max(CGFloat(stored[2]), minScale), maxScale))
    }

    /// Puts another period's board on screen, with the pan and zoom it was
    /// last left at. A day never shown before starts at 100% with its origin
    /// in the middle of the window; a wider board never shown before is
    /// fitted to the window once its layout is known.
    public func show(_ newPeriod: Period) {
        show(.period(newPeriod))
    }

    /// Puts another board on screen: a period's, as above, or a canvas,
    /// which starts at 100% with its origin in the middle of the window.
    public func show(_ newBoard: Board) {
        guard newBoard != board else { return }
        if hasViewport, !needsFit {
            viewports[board.id] = [Double(offset.width), Double(offset.height), Double(scale)]
        }
        board = newBoard
        if case .period(let newPeriod) = newBoard { period = newPeriod }
        collapse()
        expandedGroupID = nil
        namingGroupID = nil
        viewingNoteID = nil
        showingArchive = false
        resetSeenTracking()
        displayedOrigins = [:]

        if let saved = Self.viewport(from: viewports[newBoard.id]) {
            offset = saved.offset
            scale = saved.scale
            hasViewport = true
            needsFit = false
        } else {
            scale = 1
            if viewSize.width > 0, viewSize.height > 0 {
                offset = CGSize(width: (viewSize.width / 2).rounded(), height: (viewSize.height / 2).rounded())
                hasViewport = true
            } else {
                offset = .zero
                hasViewport = false
            }
            needsFit = showsDays
        }
        persist()
    }

    /// Forgets the pan and zoom kept for a board that no longer exists.
    public func forgetViewport(of board: Board) {
        guard viewports[board.id] != nil else { return }
        viewports[board.id] = nil
        defaults.set(viewports, forKey: Self.viewportsKey)
    }

    // MARK: Coordinates

    public func viewPoint(for canvasPoint: CGPoint) -> CGPoint {
        CGPoint(x: canvasPoint.x * scale + offset.width, y: canvasPoint.y * scale + offset.height)
    }

    public func canvasPoint(for viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: (viewPoint.x - offset.width) / scale, y: (viewPoint.y - offset.height) / scale)
    }

    private var effectiveViewSize: CGSize {
        viewSize.width > 0 && viewSize.height > 0 ? viewSize : Self.fallbackViewSize
    }

    /// The board point at the middle of what is currently visible.
    public var visibleCentre: CGPoint {
        let size = effectiveViewSize
        if !hasViewport {
            // Never laid out: the origin will be centred when it is.
            return .zero
        }
        return canvasPoint(for: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// The part of the board the window is showing, or `nil` before the
    /// window has ever been laid out.
    public var visibleRect: CGRect? {
        guard hasViewport else { return nil }
        let size = effectiveViewSize
        return CGRect(
            origin: canvasPoint(for: .zero),
            size: CGSize(width: size.width / scale, height: size.height / scale))
    }

    // MARK: Viewport changes

    public func setViewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, size != viewSize else { return }
        viewSize = size
        if !hasViewport {
            // First layout: put the board's origin in the middle of the window.
            offset = CGSize(width: (size.width / 2).rounded(), height: (size.height / 2).rounded())
            hasViewport = true
            persist()
        }
    }

    public func pan(by delta: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        needsFit = false
        persist()
    }

    /// Zooms by `factor`, keeping the board point under `anchor` (a point in
    /// the view) where it is.
    public func zoom(by factor: CGFloat, around anchor: CGPoint) {
        let target = min(max(scale * factor, Self.minScale), Self.maxScale)
        guard target != scale else { return }
        let fixed = canvasPoint(for: anchor)
        scale = target
        offset = CGSize(width: anchor.x - fixed.x * target, height: anchor.y - fixed.y * target)
        needsFit = false
        persist()
    }

    public func resetZoom() {
        let size = effectiveViewSize
        zoom(by: 1 / scale, around: CGPoint(x: size.width / 2, y: size.height / 2))
    }

    /// Scrolls just enough to bring a board rectangle fully into view.
    public func reveal(_ rect: CGRect, margin: CGFloat = 32) {
        let size = effectiveViewSize
        let topLeft = viewPoint(for: rect.origin)
        let bottomRight = viewPoint(for: CGPoint(x: rect.maxX, y: rect.maxY))
        var delta = CGSize.zero
        if topLeft.x < margin {
            delta.width = margin - topLeft.x
        } else if bottomRight.x > size.width - margin {
            delta.width = max(size.width - margin - bottomRight.x, margin - topLeft.x)
        }
        if topLeft.y < margin {
            delta.height = margin - topLeft.y
        } else if bottomRight.y > size.height - margin {
            delta.height = max(size.height - margin - bottomRight.y, margin - topLeft.y)
        }
        if delta != .zero { pan(by: delta) }
    }

    /// Scrolls so that a board rectangle sits in the middle of the window.
    public func centre(on rect: CGRect) {
        let size = effectiveViewSize
        let target = CGSize(
            width: (size.width / 2 - rect.midX * scale).rounded(),
            height: (size.height / 2 - rect.midY * scale).rounded())
        hasViewport = true
        needsFit = false
        guard target != offset else { return }
        offset = target
        persist()
    }

    /// Zooms and scrolls so that a rectangle of the board fills the window
    /// between the timeline above and the input box below, with a margin
    /// round it. Never zooms in past 100%.
    public func fit(_ rect: CGRect, margin: CGFloat = 32) {
        guard !rect.isNull, rect.width > 0, rect.height > 0 else {
            needsFit = false
            return
        }
        let size = effectiveViewSize
        let top = Self.topClearance
        let bottom = Self.inputClearance
        let room = CGSize(
            width: max(1, size.width - 2 * margin),
            height: max(1, size.height - top - bottom - 2 * margin))
        scale = min(max(min(room.width / rect.width, room.height / rect.height, 1), Self.minScale), Self.maxScale)
        offset = CGSize(
            width: (size.width / 2 - rect.midX * scale).rounded(),
            height: (top + (size.height - top - bottom) / 2 - rect.midY * scale).rounded())
        hasViewport = true
        needsFit = false
        persist()
    }

    /// Brings the cards of the board in front back into view, wherever it
    /// has been scrolled and zoomed to: all of them between the timeline and
    /// the input box, at 100% if they fit at that and smaller if they do
    /// not. A board of several days is fitted as it is when first opened.
    /// With no cards, the board as it starts: its own middle in the middle
    /// of the window, at 100%.
    public func recenter(in store: NoteStore) {
        let notes = notes(in: store)
        let bounds: CGRect
        if showsDays {
            bounds = layout(of: notes).bounds
        } else {
            bounds = drawnFrames(of: notes, layout: nil, groups: groups(in: store))
                .reduce(CGRect.null) { $0.union($1.frame) }
        }
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0 else {
            let size = effectiveViewSize
            scale = 1
            offset = CGSize(width: (size.width / 2).rounded(), height: (size.height / 2).rounded())
            hasViewport = true
            needsFit = false
            persist()
            return
        }
        fit(bounds)
    }

    // MARK: Where cards are

    /// Records how tall a card turned out to be at 100% zoom, once laid out.
    public func setMeasuredHeight(_ height: CGFloat, for id: UUID) {
        guard height.isFinite, height > 0 else { return }
        measuredHeights[id] = height
    }

    /// Drops what is remembered about a card that no longer exists.
    public func forget(_ id: UUID) {
        measuredHeights[id] = nil
        estimatedHeights[id] = nil
        visibleSince[id] = nil
        displayedOrigins[id] = nil
        if expandedNoteID == id { collapse() }
        if viewingNoteID == id { viewingNoteID = nil }
    }

    /// The space a note's card takes up on its own day's board: its real
    /// height if it has been drawn, otherwise a close estimate.
    public func frame(of note: Note) -> CGRect {
        let height = measuredHeights[note.id] ?? estimatedHeight(of: note)
        return CGRect(origin: note.position.cgPoint, size: CGSize(width: Self.nodeWidth, height: height))
    }

    /// How tall a card that has not been laid out will be, remembered until
    /// something it depends on changes.
    private func estimatedHeight(of note: Note) -> CGFloat {
        let hasSourceLink = note.sourceURL != nil
        var hasher = Hasher()
        hasher.combine(note.note)
        hasher.combine(note.imageAspectRatio)
        hasher.combine(hasSourceLink)
        hasher.combine(note.isTextOnly)
        let signature = hasher.finalize()
        if let known = estimatedHeights[note.id], known.signature == signature { return known.height }
        let height = NodeLayout.estimatedHeight(
            imageAspectRatio: note.imageAspectRatio, note: note.note, hasSourceLink: hasSourceLink,
            textOnly: note.isTextOnly)
        estimatedHeights[note.id] = (signature, height)
        return height
    }

    /// Says where the cards of the board on screen are drawn, when that is
    /// not where they are saved: on a board of several days.
    public func setDisplayedOrigins(_ origins: [UUID: CGPoint]) {
        displayedOrigins = origins
    }

    /// The space a card takes up on the board that is on screen.
    public func displayedFrame(of note: Note) -> CGRect {
        var frame = frame(of: note)
        if let origin = displayedOrigins[note.id] { frame.origin = origin }
        return frame
    }

    /// Where each card of the board in front is drawn, in board
    /// coordinates: on a board of several days, where its day's block puts
    /// it (`layout`); a card in a group, where the group's tile is, and as
    /// large as the tile. `notes` are those of `notes(in:)`.
    public func drawnFrames(
        of notes: [Note], layout: BoardLayout?, groups: [BoardGroup]
    ) -> [(id: UUID, frame: CGRect)] {
        var grouped: Set<UUID> = []
        for entry in groups {
            for member in entry.members { grouped.insert(member.id) }
        }
        return notes.compactMap { note in
            var frame = frame(of: note)
            if let layout {
                guard let origin = layout.positions[note.id] else { return nil }
                frame.origin = origin
            }
            if grouped.contains(note.id) { frame.size = Self.groupSize }
            return (note.id, frame)
        }
    }

    /// Sets out the notes of a period that spans several days: each day's
    /// cards as a block under its date.
    public func layout(of notes: [Note]) -> BoardLayout {
        ClusterLayout.arrange(
            days: Timeline.days(of: notes, calendar: calendar).map { entry in
                (entry.day, entry.notes.map { ($0.id, frame(of: $0)) })
            })
    }

    // MARK: The opened card

    /// Opens a card out over the board, optionally straight into editing
    /// its note or with its delete button waiting for confirmation. Opening
    /// a card is looking at it.
    public func expand(_ id: UUID, in store: NoteStore, editing: Bool = false, confirmingDelete: Bool = false) {
        guard store.note(id) != nil else { return }
        store.markSeen([id])
        expandedNoteID = id
        editingNoteID = editing ? id : nil
        confirmingDeleteID = confirmingDelete ? id : nil
    }

    /// Closes the opened card.
    public func collapse() {
        expandedNoteID = nil
        editingNoteID = nil
        confirmingDeleteID = nil
    }

    // MARK: Finding room

    /// Top-left corner for a new card of `size` on today's board, given the
    /// notes already on it.
    ///
    /// With today's board on screen that is the middle of what the window is
    /// showing if it is clear, otherwise the nearest clear place to it beside
    /// the cards already there, kept inside the window when one can be found
    /// there. With another board on screen it is the nearest clear place to
    /// the middle of today's cards.
    ///
    /// `point` is where the card was dropped on the board, if it was. It only
    /// counts while today's board is the one on screen, since that is the
    /// board it was dropped on and the board the card belongs to.
    public func placementForNewNote(size: CGSize, among todayNotes: [Note], near point: CGPoint? = nil) -> CGPoint {
        if isShowingToday, !showingArchive {
            return placementOnScreen(size: size, among: todayNotes, near: point)
        }
        let frames = todayNotes.map { frame(of: $0) }
        let bounds = frames.reduce(CGRect.null) { $0.union($1) }
        let middle = bounds.isNull ? CGPoint.zero : CGPoint(x: bounds.midX, y: bounds.midY)
        return CanvasLayout.freeOrigin(for: size, near: middle, avoiding: frames)
    }

    /// Where a new card goes on the board that is on screen, among the
    /// cards already on it: at `point` if it was dropped somewhere, otherwise
    /// in the middle of the window; clear of the others, and inside the
    /// window when there is room there.
    public func placementOnScreen(size: CGSize, among notes: [Note], near point: CGPoint? = nil) -> CGPoint {
        // A little in from the window's edge, in board units.
        let inset = 16 / scale
        return CanvasLayout.freeOrigin(
            for: size, near: point ?? visibleCentre, avoiding: notes.map { frame(of: $0) },
            preferring: visibleRect?.insetBy(dx: inset, dy: inset))
    }

    /// Puts a note that already exists on a canvas, clear of the cards
    /// there: in the window if that canvas is the one on screen, otherwise
    /// beside what is already on it. Its place on its day is not touched.
    public func add(_ note: Note, to canvasID: UUID, in store: NoteStore) {
        guard let note = store.note(note.id), !store.isPlaced(note.id, on: canvasID) else { return }
        let size = frame(of: note).size
        let there = store.notes(on: canvasID)
        let position: CGPoint
        if self.canvasID == canvasID {
            position = placementOnScreen(size: size, among: there)
        } else {
            let frames = there.map { frame(of: $0) }
            let bounds = frames.reduce(CGRect.null) { $0.union($1) }
            let middle = bounds.isNull ? CGPoint.zero : CGPoint(x: bounds.midX, y: bounds.midY)
            position = CanvasLayout.freeOrigin(for: size, near: middle, avoiding: frames)
        }
        store.place(noteID: note.id, on: canvasID, at: position)
    }

    /// Where a card can go among `others` with the least movement: where it
    /// already is, if nothing there is in its way.
    public func nearestFreePosition(for note: Note, among others: [Note]) -> CGPoint {
        let frame = frame(of: note)
        return CanvasLayout.freeOrigin(
            for: frame.size, near: CGPoint(x: frame.midX, y: frame.midY),
            avoiding: others.filter { $0.id != note.id }.map { self.frame(of: $0) })
    }

    /// Puts a note away in its day's archive, clear of the cards already there.
    public func archive(_ note: Note, in store: NoteStore) {
        // The store's record is the one to go by.
        guard let note = store.note(note.id) else { return }
        if expandedNoteID == note.id { collapse() }
        if editingNoteID == note.id { editingNoteID = nil }
        visibleSince[note.id] = nil
        store.archive(
            id: note.id,
            position: nearestFreePosition(for: note, among: store.notes(onDayOf: note.timestamp, archived: true)))
    }

    /// Brings a note back from the archive to where it was on its day's
    /// board, or beside whatever has taken that place since.
    public func restore(_ note: Note, in store: NoteStore) {
        guard let note = store.note(note.id) else { return }
        if expandedNoteID == note.id { collapse() }
        if editingNoteID == note.id { editingNoteID = nil }
        store.restore(
            id: note.id,
            position: nearestFreePosition(for: note, among: store.notes(onDayOf: note.timestamp, archived: false)))
    }

    // MARK: Which cards have been seen

    /// Whether enough of a card is inside the window to be looked at: most
    /// of the card or, for a card larger than the window, most of the window.
    public func isInView(_ note: Note) -> Bool {
        guard viewSize.width > 0, viewSize.height > 0, let visible = visibleRect else { return false }
        let frame = displayedFrame(of: note)
        let overlap = frame.intersection(visible)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return false }
        let area = overlap.width * overlap.height
        return area >= 0.6 * frame.width * frame.height || area >= 0.5 * visible.width * visible.height
    }

    /// Call a couple of times a second while the board is in the window the
    /// user is working in. Returns the notes among `unseen` that have now
    /// been in view for long enough to count as seen. A card that leaves the
    /// view starts again from nothing.
    public func notesSeen(among unseen: [Note], now: Date = Date()) -> [UUID] {
        var seen: [UUID] = []
        var inView: [UUID: Date] = [:]
        for note in unseen where isInView(note) {
            let since = visibleSince[note.id] ?? now
            if now.timeIntervalSince(since) >= Self.seenAfter {
                seen.append(note.id)
            } else {
                inView[note.id] = since
            }
        }
        visibleSince = inView
        return seen
    }

    /// Forgets how long anything has been in view: the window is no longer
    /// being looked at.
    public func resetSeenTracking() {
        visibleSince.removeAll()
    }

    /// Goes to the next card that has not been looked at yet: to the board
    /// of the day it was saved on, with the card in the middle of the
    /// window. Repeated calls go round all of them, those of the period on
    /// screen first.
    @discardableResult
    public func showNextUnseen(in store: NoteStore) -> Note? {
        // On a canvas, the cards not yet looked at there come first, and are
        // shown where they are on it.
        if case .canvas(let id) = board {
            let here = store.unseenNotes(on: id)
            if var next = here.first {
                if let last = lastUnseenShown, let index = here.firstIndex(where: { $0.id == last }) {
                    next = here[(index + 1) % here.count]
                }
                lastUnseenShown = next.id
                centre(on: frame(of: next))
                return next
            }
        }
        let all = store.unseenNotes
        let unseen = all.filter { period.contains($0.timestamp) } + all.filter { !period.contains($0.timestamp) }
        guard var next = unseen.first else { return nil }
        if let last = lastUnseenShown, let index = unseen.firstIndex(where: { $0.id == last }) {
            next = unseen[(index + 1) % unseen.count]
        }
        lastUnseenShown = next.id
        show(Period.containing(next.timestamp, scale: .day, calendar: calendar))
        showingArchive = false
        centre(on: frame(of: next))
        return next
    }

    // MARK: Persistence

    private func persist() {
        pendingPersist?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.hasViewport, !self.needsFit {
                    self.viewports[self.board.id] = [
                        Double(self.offset.width), Double(self.offset.height), Double(self.scale),
                    ]
                }
                self.defaults.set(self.viewports, forKey: Self.viewportsKey)
            }
        }
        pendingPersist = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
}
