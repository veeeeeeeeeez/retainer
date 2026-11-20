import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A board: a faint dot grid with a card for every capture of the period on
/// screen. Scroll to pan, pinch (or Command-scroll) to zoom.
///
/// A day's board shows that day's cards where their notes say they are, and
/// a card can be dragged to move it. A week's, a month's or all time's board
/// shows the same cards with each day moved as a block to a place of its
/// own, under a header with its date; there the cards stay put, and a click
/// on a header opens that day.
///
/// It shows either the notes or the archive, never both. While it is showing
/// the notes in the window the user is working in, it also keeps track of
/// which new cards have been in view long enough to count as seen.
struct CanvasView: View {

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas
    @Environment(\.controlActiveState) private var controlActiveState

    /// Message under the gesture hint while capture is unavailable.
    var statusMessage: String?
    /// Off while something else (the permission checklist) occupies the centre.
    var showsEmptyState = true
    /// Called with a day when its header is clicked on a board of several days.
    var onOpenDay: (Date) -> Void = { _ in }
    /// Called when something is dropped on the board, with where on the
    /// board that was.
    var onDropPictures: ([NSItemProvider], CGPoint) -> Void = { _, _ in }

    @State private var draggingID: UUID?
    /// What the card being dragged is over, to be grouped with if let go.
    /// Set here, or handed in for a still picture of it.
    @State private var groupTarget: CanvasModel.GroupTarget?
    var shownGroupTarget: (dragging: UUID, over: CanvasModel.GroupTarget)?
    /// Something is being dragged over the board from outside.
    @State private var dropTargeted = false
    @State private var dragTranslation: CGSize = .zero
    @State private var panStart: CGSize?

    private static let space = "canvas"

    /// The cards of the board in front: a period's notes or its archive, or
    /// what has been put on a canvas.
    private var shownNotes: [Note] { canvas.notes(in: store) }

    private var unseenHere: [Note] { canvas.unseenNotes(in: store) }

    /// Whether new cards can be seen right now: there are some, the notes
    /// are showing with nothing over them, and this is the active window.
    private var isWatchingForSeen: Bool {
        controlActiveState != .inactive && !canvas.showingArchive && canvas.viewingNoteID == nil
            && canvas.expandedNoteID == nil && showsEmptyState && !unseenHere.isEmpty
    }

    var body: some View {
        let notes = shownNotes
        // Several days at once: each day's cards as a block under its date.
        let layout = canvas.showsDays ? canvas.layout(of: notes) : nil

        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                DotGrid(offset: canvas.offset, scale: canvas.scale)
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                if let layout {
                    ForEach(layout.headers) { header in
                        dayHeader(header)
                    }
                }

                // Cards in a group are not drawn one by one: their group is.
                let groups = canvas.groups(in: store)
                let grouped = Set(groups.flatMap { $0.group.noteIDs })
                ForEach(notes.filter { !grouped.contains($0.id) }) { note in
                    node(for: note, at: layout?.positions[note.id])
                }
                ForEach(groups) { entry in
                    groupNode(entry, at: entry.members.first.flatMap { layout?.positions[$0.id] })
                }
                if let over = activeTarget?.over, let frame = frame(of: over, among: notes, groups) {
                    let origin = canvas.viewPoint(for: frame.origin)
                    GroupBadge(label: over.isGroup ? "Add to group" : "Group")
                        .position(
                            x: origin.x + frame.width * canvas.scale / 2,
                            y: origin.y + frame.height * canvas.scale / 2
                        )
                        .zIndex(3)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                if notes.isEmpty && showsEmptyState {
                    emptyState
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .allowsHitTesting(false)
                } else if showsEmptyState {
                    // Cards, but every one of them scrolled out of view:
                    // which way they are. Always there, so that it can fade.
                    OverThere(
                        directions: Whereabouts.directions(
                            to: canvas.drawnFrames(of: notes, layout: layout, groups: groups).map(\.frame),
                            from: canvas.visibleRect)
                    ) {
                        withAnimation(.easeOut(duration: 0.3)) { canvas.recenter(in: store) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
            .clipped()
            // A picture dragged in from outside lands on the board. Not on
            // the archive: nothing new goes there.
            .onDrop(of: canvas.showingArchive ? [] : [.image, .fileURL], isTargeted: $dropTargeted) { providers, location in
                onDropPictures(providers, canvas.canvasPoint(for: location))
                return true
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.12), value: dropTargeted)
            .background {
                ScrollMonitor(isEnabled: canvas.viewingNoteID == nil && canvas.expandedNoteID == nil) { delta in
                    canvas.pan(by: delta)
                } onZoom: { factor, anchor in
                    canvas.zoom(by: factor, around: anchor)
                }
            }
            .onAppear {
                canvas.setViewSize(geometry.size)
                apply(layout)
            }
            .onChange(of: geometry.size) { _, size in
                canvas.setViewSize(size)
                apply(layout)
            }
            .onChange(of: layout) { _, layout in apply(layout) }
        }
        .background(Theme.background)
        // Runs only while there is something new that could be looked at, so
        // an idle window does no work.
        .task(id: isWatchingForSeen) {
            guard isWatchingForSeen else {
                canvas.resetSeenTracking()
                return
            }
            while !Task.isCancelled {
                markSeenNotes()
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// Tells the model where the cards are drawn on a board of several days,
    /// and fits such a board to the window the first time it is shown.
    private func apply(_ layout: BoardLayout?) {
        canvas.setDisplayedOrigins(layout?.positions ?? [:])
        if canvas.needsFit, let layout, canvas.viewSize.width > 0 {
            canvas.fit(layout.bounds)
        }
    }

    private func markSeenNotes() {
        let seen = canvas.notesSeen(among: unseenHere)
        guard !seen.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.35)) { store.markSeen(seen) }
    }

    // MARK: Cards

    /// A card at its own place on its day's board, where it can be dragged,
    /// or at `place` on a board of several days, where dragging it pans.
    @ViewBuilder
    private func node(for note: Note, at place: CGPoint?) -> some View {
        let isDragging = draggingID == note.id || activeTarget?.dragging == note.id
        let origin = canvas.viewPoint(for: place ?? note.position.cgPoint)
        // Held over another card to be grouped with it: both go grey.
        let greyed = activeTarget.map { $0.dragging == note.id || $0.over == .note(note.id) } ?? false
        let card = NodeView(note: note, scale: canvas.scale)
            .modifier(Greyed(active: greyed))
            .offset(
                x: origin.x + (isDragging ? dragTranslation.width : 0),
                y: origin.y + (isDragging ? dragTranslation.height : 0)
            )
            .zIndex(isDragging ? 1 : 0)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        if place == nil {
            card.gesture(moveGesture(for: note))
        } else {
            card.gesture(panGesture)
        }
    }

    /// Dragging anywhere on a card moves it. A press that does not travel
    /// is a click, which opens the card.
    private func moveGesture(for note: Note) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .onChanged { value in
                draggingID = note.id
                dragTranslation = value.translation
                let moved = CGSize(
                    width: value.translation.width / canvas.scale, height: value.translation.height / canvas.scale)
                let target = canvas.groupingTarget(for: note, movedBy: moved, in: store)
                if target != groupTarget {
                    withAnimation(.easeOut(duration: 0.12)) { groupTarget = target }
                }
            }
            .onEnded { value in
                defer {
                    draggingID = nil
                    dragTranslation = .zero
                    groupTarget = nil
                }
                guard draggingID == note.id else { return }
                // Let go over another card or a group: that is what it is
                // put with, and it does not move.
                if let target = groupTarget {
                    withAnimation(.easeOut(duration: 0.2)) { canvas.group(note, with: target, in: store) }
                    store.markSeen([note.id])
                    return
                }
                let position = CGPoint(
                    x: note.position.x + value.translation.width / canvas.scale,
                    y: note.position.y + value.translation.height / canvas.scale)
                // On a canvas the card has a place of its own, and that is
                // what moves; where it is on its day is left alone.
                if let canvasID = canvas.canvasID {
                    store.place(noteID: note.id, on: canvasID, at: position)
                } else {
                    store.move(id: note.id, to: position)
                }
                // Picking a card up is looking at it.
                store.markSeen([note.id])
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let previous = panStart ?? .zero
                canvas.pan(
                    by: CGSize(
                        width: value.translation.width - previous.width,
                        height: value.translation.height - previous.height))
                panStart = value.translation
            }
            .onEnded { _ in panStart = nil }
    }

    // MARK: Day headers

    /// The date over one day's cards on a board of several days. It stays
    /// readable however far out the board is zoomed, never runs into the
    /// next day's, and opens the day when clicked.
    private func dayHeader(_ header: BoardLayout.Header) -> some View {
        let origin = canvas.viewPoint(for: header.origin)
        let day = Period.containing(header.day, scale: .day, calendar: canvas.calendar)
        let band = ClusterLayout.headerHeight * canvas.scale
        // What the day's block and the gap after it leave room for.
        let room = (header.width + ClusterLayout.gap * 0.5) * canvas.scale
        let size = max(11, 22 * canvas.scale)
        let roomy = room >= 230
        let title =
            room >= 150
            ? day.title(now: canvas.currentDate, calendar: canvas.calendar)
            : day.compactDayTitle(now: canvas.currentDate, calendar: canvas.calendar)
        return Button {
            onOpenDay(header.day)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: max(6, 10 * canvas.scale)) {
                Text(title)
                    .font(Theme.noteFont(size: size).weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                if roomy {
                    Text(header.count == 1 ? "1 note" : "\(header.count) notes")
                        .font(Theme.mono(max(10, 11 * canvas.scale)))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            .frame(width: max(room, 30), alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(day.title(now: canvas.currentDate, calendar: canvas.calendar))")
        // Sitting just above the day's first row of cards.
        .offset(x: origin.x, y: origin.y + band - size * 1.3 - max(3, 8 * canvas.scale))
    }

    // MARK: Groups

    /// The pair being shown as about to be grouped: live from a drag, or the
    /// one handed in.
    private var activeTarget: (dragging: UUID, over: CanvasModel.GroupTarget)? {
        if let shownGroupTarget { return shownGroupTarget }
        if let draggingID, let groupTarget { return (draggingID, groupTarget) }
        return nil
    }

    /// Where on the board the thing a card is held over is.
    private func frame(
        of target: CanvasModel.GroupTarget, among notes: [Note], _ groups: [CanvasModel.BoardGroup]
    ) -> CGRect? {
        switch target {
        case .note(let id): notes.first { $0.id == id }.map { canvas.frame(of: $0) }
        case .group(let id): groups.first { $0.id == id }.map { canvas.frame(of: $0.group) }
        }
    }

    /// A group's tile: where its group is on a day's board or a canvas,
    /// where it can be dragged and clicked open, or at `place` on a board of
    /// several days, where dragging it pans.
    @ViewBuilder
    private func groupNode(_ entry: CanvasModel.BoardGroup, at place: CGPoint?) -> some View {
        let isDragging = draggingID == entry.id
        let origin = canvas.viewPoint(for: place ?? entry.group.position.cgPoint)
        let tile = GroupTileView(entry: entry, scale: canvas.scale)
            .modifier(Greyed(active: activeTarget?.over == .group(entry.id)))
            .offset(
                x: origin.x + (isDragging ? dragTranslation.width : 0),
                y: origin.y + (isDragging ? dragTranslation.height : 0)
            )
            .zIndex(isDragging ? 1 : 0)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { canvas.expandedGroupID = entry.id }
            }
        if place == nil {
            tile.gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        draggingID = entry.id
                        dragTranslation = value.translation
                    }
                    .onEnded { value in
                        defer {
                            draggingID = nil
                            dragTranslation = .zero
                        }
                        guard draggingID == entry.id else { return }
                        store.moveGroup(
                            id: entry.id,
                            to: CGPoint(
                                x: entry.group.position.x + value.translation.width / canvas.scale,
                                y: entry.group.position.y + value.translation.height / canvas.scale))
                    }
            )
        } else {
            tile.gesture(panGesture)
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Space.m) {
            if isInvitation {
                Invitation()
            } else {
                Text(emptyMessage)
                    .font(Theme.noteFont(size: 17))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            if canvas.canvasID != nil {
                Text("What you capture, paste or drop while this canvas is in front lands here.")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
            if let statusMessage, isInvitation {
                Text(statusMessage)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.Space.xl)
    }

    /// The board is one a capture could land on: a canvas, or a period that
    /// covers the present.
    private var isInvitation: Bool {
        if canvas.canvasID != nil { return true }
        return !canvas.showingArchive && canvas.period.contains(canvas.currentDate)
    }

    private var emptyMessage: String {
        canvas.showingArchive ? "Nothing is archived here." : "Nothing was saved then."
    }
}

/// A very faint grid of dots that moves and scales with the canvas.
private struct DotGrid: View {
    let offset: CGSize
    let scale: CGFloat

    private static let baseSpacing: CGFloat = 24

    var body: some View {
        Canvas { context, size in
            var spacing = Self.baseSpacing * scale
            // Keep the dots from crowding when zoomed far out.
            while spacing < 16 { spacing *= 2 }

            let startX = offset.width.truncatingRemainder(dividingBy: spacing)
            let startY = offset.height.truncatingRemainder(dividingBy: spacing)
            var path = Path()
            var y = startY < 0 ? startY + spacing : startY
            while y < size.height {
                var x = startX < 0 ? startX + spacing : startX
                while x < size.width {
                    path.addRect(CGRect(x: x.rounded() - 0.5, y: y.rounded() - 0.5, width: 1, height: 1))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(Theme.textFaint.opacity(0.55)))
        }
        .background(Theme.background)
    }
}

/// Feeds scroll-wheel and pinch events over the canvas to the model.
///
/// SwiftUI has no scroll-wheel handler, so this places an invisible AppKit
/// view behind the canvas and watches the window's events while the pointer
/// is over it. Using a monitor rather than overriding `scrollWheel` means
/// panning works wherever the pointer is, including over a node.
private struct ScrollMonitor: NSViewRepresentable {

    var isEnabled: Bool
    var onPan: (CGSize) -> Void
    var onZoom: (_ factor: CGFloat, _ anchor: CGPoint) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.install()
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.isEnabled = isEnabled
        view.onPan = onPan
        view.onZoom = onZoom
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.uninstall()
    }

    final class MonitorView: NSView {
        var isEnabled = true
        var onPan: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Whether the view under the pointer is, or is inside, a scroll view.
        private func isOverScrollView(_ event: NSEvent, in window: NSWindow) -> Bool {
            guard let content = window.contentView else { return false }
            let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
            guard let hit = content.hitTest(point) else { return false }
            return hit is NSScrollView || hit.enclosingScrollView != nil
        }

        /// Returns true when the event was used.
        private func handle(_ event: NSEvent) -> Bool {
            guard isEnabled, let window, event.window === window else { return false }
            let local = convert(event.locationInWindow, from: nil)
            guard bounds.contains(local) else { return false }
            // Something that scrolls by itself is floating over the board
            // here (the timeline, an editor): the scroll is meant for it.
            if event.type == .scrollWheel, isOverScrollView(event, in: window) { return false }
            // SwiftUI's origin is top-left; this view's is bottom-left.
            let anchor = CGPoint(x: local.x, y: bounds.height - local.y)

            switch event.type {
            case .magnify:
                onZoom?(1 + event.magnification, anchor)
                return true
            case .scrollWheel:
                // A mouse wheel reports whole lines; a trackpad reports points.
                let unit: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                if event.modifierFlags.contains(.command) {
                    onZoom?(exp(event.scrollingDeltaY * unit * 0.008), anchor)
                } else {
                    onPan?(CGSize(width: event.scrollingDeltaX * unit, height: event.scrollingDeltaY * unit))
                }
                return true
            default:
                return false
            }
        }
    }
}

/// The screenshot of one note at full size, over the canvas.
struct ImageViewer: View {

    let note: Note
    var onClose: () -> Void

    @Environment(NoteStore.self) private var store
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            let available = CGSize(
                width: max(1, geometry.size.width - 64),
                height: max(1, geometry.size.height - 96))
            let size = ScreenGeometry.fit(note.imagePointSize, within: available)

            ZStack {
                Theme.background.opacity(0.97)

                VStack(spacing: Theme.Space.m) {
                    Group {
                        if let image {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .interpolation(.high)
                        } else {
                            Theme.panel
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .overlay {
                        Rectangle().strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth)
                    }

                    Text("\(note.imagePixelSize.width) × \(note.imagePixelSize.height) px   ·   esc or click to close")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture { onClose() }
        }
        .background {
            // Escape closes the viewer.
            Button("Close", action: onClose)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: note.id) {
            let url = store.imageURL(for: note)
            image = await Task.detached(priority: .userInitiated) {
                UncheckedBox(ImageFiles.load(url, maxPixelSize: nil))
            }.value.value
        }
        .transition(.opacity)
    }
}
