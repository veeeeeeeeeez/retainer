import SwiftUI

/// The bar floating at the top of the board: a switch between the timeline
/// and the projects, and under it one slim strip of frosted glass whose
/// tiles are whichever of those is chosen.
///
/// - **Timeline:** a tile for every day (or week, or month) that has notes,
///   oldest on the left, the present on the right, with the day / week /
///   month / all switch under the strip.
/// - **Projects:** a tile for every project and one to make another. Opening
///   a project shows its canvases in the same strip, with the project's name
///   at the left as the way back.
///
/// A tile is a small collage of the newest screenshots in it. Clicking one
/// puts its board on screen. The window opens on Today.
struct TopBar: View {

    let app: AppModel

    /// Room the bar takes at the top of the board at its tallest (the
    /// timeline, with its second switch), so things can be kept clear of it.
    static let clearance: CGFloat = 150

    var body: some View {
        let navigation = app.navigation
        VStack(spacing: 7) {
            SegmentedPill(
                options: Navigation.Mode.allCases, selection: navigation.mode, title: \.title,
                symbol: { $0.symbol }, large: true
            ) { mode in
                withAnimation(.easeOut(duration: 0.18)) { app.setMode(mode) }
            }
            switch navigation.mode {
            case .timeline:
                TimelineStrip(app: app)
                    // Another scale is another row of tiles, starting at the present.
                    .id(app.canvas.timeScale)
                SegmentedPill(
                    options: TimeScale.allCases, selection: app.canvas.timeScale, title: \.title, large: true
                ) { scale in
                    withAnimation(.easeOut(duration: 0.18)) { app.setTimeScale(scale) }
                }
            case .projects:
                ProjectsStrip(app: app)
                    // The list, and each project, scroll on their own.
                    .id(navigation.browsingProjectID)
            }
        }
    }
}

/// The timeline's tiles: one for every period that has notes.
private struct TimelineStrip: View {

    let app: AppModel

    var body: some View {
        let now = app.canvas.currentDate
        let calendar = app.store.calendar
        let entries = Timeline.entries(
            notes: app.store.allNotes, scale: app.canvas.timeScale, now: now, calendar: calendar)
        // A period's tile is lit only while its board is the one in front.
        let front: Period? = app.canvas.board.isCanvas ? nil : app.canvas.period

        TileStrip(
            ids: entries.map(\.id), tileWidth: Self.tileWidth(for: app.canvas.timeScale), selectedID: front?.id,
            windowWidth: app.canvas.viewSize.width, pageHelp: ("Earlier", "Later")
        ) {
            EmptyView()
        } tile: { index in
            let entry = entries[index]
            let title = entry.period.shortTitle(now: now, calendar: calendar)
            StripTile(
                notes: entry.cover, title: title, width: Self.tileWidth(for: app.canvas.timeScale),
                selected: entry.period == front, marked: entry.unseenCount > 0,
                help: entry.count == 1 ? "\(title): 1 note" : "\(title): \(entry.count) notes"
            ) {
                withAnimation(.easeOut(duration: 0.18)) { app.select(entry.period) }
            }
        }
    }

    /// Wide enough for the longest name at each scale: "Wed 18", "27 Sep–3 Oct".
    static func tileWidth(for scale: TimeScale) -> CGFloat {
        switch scale {
        case .day, .month: 70
        case .week: 102
        case .all: 84
        }
    }
}

/// The projects' tiles, or one project's canvases, each with a last tile
/// that makes another.
private struct ProjectsStrip: View {

    let app: AppModel

    static let tileWidth: CGFloat = 102
    private static let newID = "new"

    var body: some View {
        if let project = app.store.project(app.navigation.browsingProjectID) {
            canvases(of: project)
        } else {
            projects
        }
    }

    /// The newest few of some notes, for a tile's collage.
    private func cover(_ notes: [Note]) -> [Note] {
        var seen = Set<UUID>()
        return Array(
            notes.sorted { $0.timestamp > $1.timestamp }.filter { seen.insert($0.id).inserted }.prefix(3))
    }

    private var projects: some View {
        let store = app.store
        let navigation = app.navigation
        let all = store.projects
        return TileStrip(
            ids: all.map(\.id.uuidString) + [Self.newID], tileWidth: Self.tileWidth, selectedID: nil,
            windowWidth: app.canvas.viewSize.width, pageHelp: ("Earlier projects", "Later projects")
        ) {
            EmptyView()
        } tile: { index in
            if index < all.count {
                let project = all[index]
                let canvases = store.canvases(in: project.id)
                let notes = canvases.flatMap { store.notes(on: $0.id) }
                StripTile(
                    notes: cover(notes), title: project.name, width: Self.tileWidth,
                    selected: store.canvas(app.canvas.canvasID)?.projectID == project.id,
                    marked: notes.contains { !$0.seen },
                    help: "\(project.name): \(canvases.count == 1 ? "1 canvas" : "\(canvases.count) canvases")",
                    renaming: navigation.renamingID == project.id,
                    confirmingDelete: navigation.confirmingDeleteID == project.id,
                    onRename: { navigation.rename(project.id, to: $0) },
                    onCancelRename: { navigation.cancelRename() },
                    onConfirmDelete: { withAnimation(.easeOut(duration: 0.18)) { navigation.confirmDelete() } }
                ) {
                    withAnimation(.easeOut(duration: 0.18)) { navigation.openProject(project.id) }
                }
                .contextMenu {
                    Button("Rename") { navigation.startRenaming(project.id) }
                    Button("Delete…") { navigation.requestDelete(project.id) }
                }
            } else {
                AddTile(width: Self.tileWidth, help: "New project") {
                    withAnimation(.easeOut(duration: 0.18)) { _ = navigation.newProject() }
                }
            }
        }
    }

    private func canvases(of project: Project) -> some View {
        let store = app.store
        let navigation = app.navigation
        let all = store.canvases(in: project.id)
        return TileStrip(
            ids: all.map(\.id.uuidString) + [Self.newID], tileWidth: Self.tileWidth,
            selectedID: app.canvas.canvasID?.uuidString, windowWidth: app.canvas.viewSize.width,
            leadingWidth: ProjectBack.width, pageHelp: ("Earlier canvases", "Later canvases")
        ) {
            ProjectBack(
                name: project.name, renaming: navigation.renamingID == project.id,
                confirmingDelete: navigation.confirmingDeleteID == project.id,
                onRename: { navigation.rename(project.id, to: $0) },
                onCancelRename: { navigation.cancelRename() },
                onConfirmDelete: { withAnimation(.easeOut(duration: 0.18)) { navigation.confirmDelete() } }
            ) {
                withAnimation(.easeOut(duration: 0.18)) { navigation.back() }
            }
            .contextMenu {
                Button("Rename Project") { navigation.startRenaming(project.id) }
                Button("Delete Project…") { navigation.requestDelete(project.id) }
            }
        } tile: { index in
            if index < all.count {
                let target = all[index]
                let notes = store.notes(on: target.id)
                StripTile(
                    notes: cover(notes), title: target.name, width: Self.tileWidth,
                    selected: app.canvas.canvasID == target.id, marked: notes.contains { !$0.seen },
                    help: "\(target.name): \(notes.count == 1 ? "1 card" : "\(notes.count) cards")",
                    renaming: navigation.renamingID == target.id,
                    confirmingDelete: navigation.confirmingDeleteID == target.id,
                    onRename: { navigation.rename(target.id, to: $0) },
                    onCancelRename: { navigation.cancelRename() },
                    onConfirmDelete: { withAnimation(.easeOut(duration: 0.18)) { navigation.confirmDelete() } }
                ) {
                    withAnimation(.easeOut(duration: 0.18)) { navigation.openCanvas(target.id) }
                }
                .contextMenu {
                    Button("Rename") { navigation.startRenaming(target.id) }
                    Button("Delete…") { navigation.requestDelete(target.id) }
                }
            } else {
                AddTile(width: Self.tileWidth, help: "New canvas in \(project.name)") {
                    withAnimation(.easeOut(duration: 0.18)) { _ = navigation.newCanvas() }
                }
            }
        }
    }
}

/// The strip itself: frosted glass as wide as its tiles, up to seven of
/// them, centred. Past seven it stays that width and scrolls: with two
/// fingers, or with the arrows that appear at its ends. It starts at its
/// far end, where the newest things are, and keeps the chosen tile in sight.
struct TileStrip<Leading: View, Tile: View>: View {

    /// One for each tile, in order.
    let ids: [String]
    let tileWidth: CGFloat
    /// The tile whose board is on screen, to keep in sight.
    let selectedID: String?
    /// How wide the board the strip floats over is.
    let windowWidth: CGFloat
    /// The width of whatever is fixed at the strip's left end.
    var leadingWidth: CGFloat = 0
    var pageHelp: (earlier: String, later: String) = ("Earlier", "Later")
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var tile: (Int) -> Tile

    /// The tile at the right-hand edge of what the strip is showing.
    @State private var trailingID: String?

    /// The most tiles shown at once; the rest are reached by scrolling.
    static var visibleTiles: Int { 7 }
    static var spacing: CGFloat { 4 }
    static var inset: CGFloat { 8 }
    /// A tile (collage, name, a little padding) and the strip's own padding.
    static var height: CGFloat { 72 }

    var body: some View {
        let shown = visibleCount
        let stripWidth = CGFloat(shown) * tileWidth + CGFloat(max(shown - 1, 0)) * Self.spacing + 2 * Self.inset
        let overflows = ids.count > shown
        let trailing = ids.firstIndex { $0 == trailingID } ?? (ids.count - 1)

        HStack(spacing: 0) {
            leading()
            if overflows {
                PageButton(symbol: "chevron.left", help: pageHelp.earlier, enabled: trailing > shown - 1) {
                    page(by: -(shown - 1), shown: shown)
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(Array(ids.enumerated()), id: \.element) { index, _ in
                        tile(index)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 6)
            }
            .contentMargins(.horizontal, Self.inset, for: .scrollContent)
            .scrollIndicators(.never)
            .scrollPosition(id: $trailingID, anchor: .trailing)
            .frame(width: stripWidth, height: Self.height)
            if overflows {
                PageButton(symbol: "chevron.right", help: pageHelp.later, enabled: trailing < ids.count - 1) {
                    page(by: shown - 1, shown: shown)
                }
            }
        }
        // The arrows fill the strip's height and no more.
        .frame(height: Self.height)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .floatingGlass(cornerRadius: 14)
        .onAppear { trailingID = ids.last }
        .onChange(of: selectedID) { _, selected in
            if let selected { reveal(selected, shown: shown) }
        }
        // A tile added at the end (a new day, a new canvas) is brought into view.
        .onChange(of: ids.count) { old, new in
            if new > old { withAnimation(.easeOut(duration: 0.2)) { trailingID = ids.last } }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
    }

    /// How many tiles the strip shows: all of them up to seven, and fewer
    /// than that if the window is too narrow for seven.
    private var visibleCount: Int {
        // The strip is centred, with the mini map to its right: what it may
        // take is the window less the map's width on both sides.
        let window = windowWidth > 0 ? windowWidth : 1180
        let room = window - 2 * (MiniMap.diameter + MiniMap.edgeSpace + 14) - leadingWidth
        let fits = Int((room - 2 * Self.inset - 2 * PageButton.width + Self.spacing) / (tileWidth + Self.spacing))
        return max(1, min(ids.count, Self.visibleTiles, max(fits, 3)))
    }

    /// Scrolls the strip a page one way or the other without changing the board.
    private func page(by count: Int, shown: Int) {
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex { $0 == trailingID } ?? (ids.count - 1)
        let target = min(max(current + count, min(shown, ids.count) - 1), ids.count - 1)
        withAnimation(.easeOut(duration: 0.22)) { trailingID = ids[target] }
    }

    /// Scrolls just far enough to show a tile.
    private func reveal(_ id: String, shown: Int) {
        guard let index = ids.firstIndex(of: id) else { return }
        let trailing = ids.firstIndex { $0 == trailingID } ?? (ids.count - 1)
        if index > trailing {
            withAnimation(.easeOut(duration: 0.2)) { trailingID = ids[index] }
        } else if index < trailing - (shown - 1) {
            let target = min(index + shown - 1, ids.count - 1)
            withAnimation(.easeOut(duration: 0.2)) { trailingID = ids[target] }
        }
    }
}

/// The click area at either end of a strip that scrolls it by a page.
private struct PageButton: View {

    let symbol: String
    let help: String
    let enabled: Bool
    var action: () -> Void

    @State private var hovering = false

    static let width: CGFloat = 26

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering && enabled ? Theme.text : Theme.textMuted)
                .frame(width: Self.width)
                .frame(maxHeight: .infinity)
                .background(hovering && enabled ? Theme.panelRaised.opacity(0.6) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One tile of a strip: a collage of the newest screenshots in something,
/// over its name. A period, a project or a canvas.
///
/// A project's or a canvas's tile can also be having its name typed, or be
/// waiting for the second click that deletes it.
struct StripTile: View {

    let notes: [Note]
    let title: String
    let width: CGFloat
    let selected: Bool
    /// A dot by the name: something in it has not been looked at.
    var marked = false
    let help: String
    var renaming = false
    var confirmingDelete = false
    var onRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onConfirmDelete: () -> Void = {}
    var onSelect: () -> Void

    @State private var hovering = false

    static let collageSize = CGSize(width: 56, height: 34)

    var body: some View {
        Group {
            if renaming {
                // Not a button while its name is being typed: the field needs the clicks.
                face
            } else {
                Button(action: confirmingDelete ? onConfirmDelete : onSelect) { face }
                    .buttonStyle(.plain)
            }
        }
        .onHover { hovering = $0 }
        .help(confirmingDelete ? "Click again to delete \(title)" : help)
        .accessibilityLabel(confirmingDelete ? "Delete \(title)?" : help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var face: some View {
        VStack(spacing: 3) {
            Collage(notes: notes)
                .frame(width: Self.collageSize.width, height: Self.collageSize.height)
            if renaming {
                NameField(name: title, onCommit: onRename, onCancel: onCancelRename)
                    .frame(width: width - 8)
            } else {
                HStack(spacing: 3) {
                    if marked && !confirmingDelete {
                        Circle().fill(Theme.text).frame(width: 4, height: 4)
                    }
                    Text(confirmingDelete ? "delete?" : title)
                        .foregroundStyle(
                            selected || confirmingDelete ? Theme.text : (hovering ? Theme.textSecondary : Theme.textMuted))
                }
                .font(Theme.mono(10, weight: selected || confirmingDelete ? .medium : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 3)
            }
        }
        .frame(width: width)
        .padding(.vertical, 3)
        .background(
            selected || confirmingDelete
                ? Theme.selected.opacity(0.9) : (hovering ? Theme.panelRaised.opacity(0.7) : Color.clear),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .contentShape(Rectangle())
    }
}

/// The last tile of the projects' strips: makes another project, or another
/// canvas. A dashed frame with a plus in it, so it is not taken for a tile
/// with nothing in it yet.
private struct AddTile: View {

    let width: CGFloat
    let help: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            hovering ? Theme.textMuted : Theme.hairlineStrong,
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(hovering ? Theme.text : Theme.textMuted)
                }
                .frame(width: StripTile.collageSize.width * 0.74, height: StripTile.collageSize.height * 0.8)
                .frame(width: StripTile.collageSize.width, height: StripTile.collageSize.height)
                Text("new")
                    .font(Theme.mono(10))
                    .foregroundStyle(hovering ? Theme.textSecondary : Theme.textFaint)
                    .lineLimit(1)
            }
            .frame(width: width)
            .padding(.vertical, 3)
            .background(hovering ? Theme.panelRaised.opacity(0.7) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// At the left end of a project's canvases: the project's name, which is
/// also the way back to the list of projects.
private struct ProjectBack: View {

    let name: String
    var renaming = false
    var confirmingDelete = false
    var onRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}
    var onConfirmDelete: () -> Void = {}
    var onBack: () -> Void

    @State private var hovering = false

    static let width: CGFloat = 116
    /// The most rows the project's name is given.
    static let titleRows = 3

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if renaming {
                    NameField(name: name, onCommit: onRename, onCancel: onCancelRename)
                        .padding(.horizontal, 8)
                } else {
                    Button(action: confirmingDelete ? onConfirmDelete : onBack) {
                        HStack(spacing: 5) {
                            if !confirmingDelete {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 10, weight: .semibold))
                            }
                            // A long name wraps, up to three rows, before it is cut short.
                            Text(confirmingDelete ? "delete?" : name)
                                .font(Theme.mono(11, weight: .medium))
                                .lineLimit(Self.titleRows)
                                .multilineTextAlignment(.leading)
                                .truncationMode(.tail)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(hovering || confirmingDelete ? Theme.text : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                        .background(hovering ? Theme.panelRaised.opacity(0.6) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: Self.width - 1)
            Rectangle().fill(Theme.hairline).frame(width: 1).padding(.vertical, 10)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .onHover { hovering = $0 }
        .help(confirmingDelete ? "Click again to delete \(name) and its canvases" : "\(name): back to all projects")
        .accessibilityLabel(confirmingDelete ? "Delete \(name)?" : "Back to all projects, from \(name)")
    }
}

/// A name being typed in place. Return keeps it, and so does moving on to
/// something else in the bar; Escape leaves the old one.
///
/// Losing the keyboard does not end it. A field asks for the keyboard as it
/// appears and does not always get it at once, and a name that ended itself
/// then could never be typed.
private struct NameField: View {

    let name: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    @State private var text = ""
    /// Return or Escape has already said what to do with what was typed.
    @State private var settled = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("name", text: $text)
            .textFieldStyle(.plain)
            .font(Theme.mono(10, weight: .medium))
            .foregroundStyle(Theme.text)
            .multilineTextAlignment(.center)
            .padding(.vertical, 1)
            .padding(.horizontal, 3)
            .background(Theme.background.opacity(0.8), in: RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
            }
            .focused($focused)
            .onSubmit {
                settled = true
                onCommit(text)
            }
            .onExitCommand {
                settled = true
                onCancel()
            }
            .onAppear {
                text = name
                focused = true
            }
            .onDisappear {
                // Taken away by something else being done in the bar: keep
                // what had been typed.
                if !settled { onCommit(text) }
            }
            .accessibilityLabel("Name")
    }
}

/// Up to three screenshots, fanned like prints dropped on a table. A period
/// with nothing in it yet is an empty frame.
struct Collage: View {

    let notes: [Note]

    /// Tilt and nudge for each print, back to front.
    private static let fan: [[(angle: Double, x: CGFloat, y: CGFloat)]] = [
        [],
        [(0, 0, 0)],
        [(-7, -5, 1), (4, 4, -1)],
        [(-9, -7, 1), (7, 7, 0), (0, 0, -1)],
    ]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if notes.isEmpty {
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Theme.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: size.width * 0.74, height: size.height * 0.8)
                } else {
                    // Oldest of the few at the back, newest on top.
                    let prints = Array(notes.prefix(3).reversed())
                    let fan = Self.fan[min(prints.count, 3)]
                    ForEach(Array(prints.enumerated()), id: \.element.id) { index, note in
                        Thumbnail(note: note)
                            .frame(
                                width: size.width * (prints.count == 1 ? 0.86 : 0.7),
                                height: size.height * (prints.count == 1 ? 0.9 : 0.8)
                            )
                            .rotationEffect(.degrees(fan[index].angle))
                            .offset(x: fan[index].x, y: fan[index].y)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

/// A note's screenshot, cropped to fill a small frame.
struct Thumbnail: View {

    let note: Note

    @Environment(NoteStore.self) private var store
    @Environment(ImageCache.self) private var images
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.panelRaised
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
            }
        }
        .task(id: note.id) {
            image = await images.load(id: note.id, url: store.imageURL(for: note), tier: .thumbnail)
        }
    }
}
