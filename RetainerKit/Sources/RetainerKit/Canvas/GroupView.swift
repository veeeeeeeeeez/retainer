import SwiftUI

/// A group on the board: one tile, a little larger than a card, made of the
/// pictures of everything in it, with the group's name under them.
///
/// There are no captions on it. What a group is, at a glance, is what its
/// pictures look like together; the notes are a click away.
struct GroupTileView: View {

    let entry: CanvasModel.BoardGroup
    let scale: CGFloat

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas

    var body: some View {
        let width = (CanvasModel.groupSize.width * scale).rounded()
        let height = (CanvasModel.groupSize.height * scale).rounded()
        let radius = max(2, Theme.radius * scale)
        // Too small to read: the pictures alone.
        let showsName = width >= 110
        let footer = showsName ? (46 * scale).rounded() : 0
        let shape = RoundedRectangle(cornerRadius: radius)

        VStack(spacing: 0) {
            MosaicView(notes: entry.members, gap: max(1, (3 * scale).rounded()), chip: (34 * scale).rounded())
                .padding(max(2, (6 * scale).rounded()))
                .frame(height: height - footer)
            if showsName {
                HStack(spacing: 8 * scale) {
                    Image(systemName: "square.on.square")
                        .font(.system(size: 11 * scale, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    if canvas.namingGroupID == entry.group.id {
                        GroupNameField(size: 14 * scale) { name in
                            if let name { store.renameGroup(id: entry.group.id, to: name) }
                            if canvas.namingGroupID == entry.group.id { canvas.namingGroupID = nil }
                        }
                    } else {
                        Text(entry.group.name.isEmpty ? "Group" : entry.group.name)
                            .font(Theme.noteFont(size: 14 * scale).weight(.medium))
                            .foregroundStyle(entry.group.name.isEmpty ? Theme.textSecondary : Theme.text)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if entry.members.contains(where: { !$0.seen }) {
                        Circle().fill(Theme.text).frame(width: 5 * scale, height: 5 * scale)
                    }
                    Text(entry.members.count == 1 ? "1 card" : "\(entry.members.count) cards")
                        .font(Theme.mono(10 * scale))
                        .foregroundStyle(Theme.textMuted)
                        .fixedSize()
                }
                .padding(.horizontal, 12 * scale)
                .frame(height: footer)
            }
        }
        .frame(width: width, height: height)
        .background(Theme.panel)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth) }
        // The edge of another sheet showing behind: a pile, not a card.
        .background {
            shape.fill(Theme.panelRaised)
                .overlay { shape.strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth) }
                .offset(x: max(2, 5 * scale), y: max(2, 5 * scale))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Open Group") { canvas.expandedGroupID = entry.group.id }
            Button("Rename") { canvas.namingGroupID = entry.group.id }
            Divider()
            Button("Ungroup") {
                withAnimation(.easeOut(duration: 0.2)) { canvas.ungroup(entry.group, in: store) }
            }
        }
        .help(entry.group.name.isEmpty ? "A group of \(entry.members.count)" : entry.group.name)
        .accessibilityLabel(
            "\(entry.group.name.isEmpty ? "Group" : entry.group.name), \(entry.members.count) cards")
    }
}

/// The name of a group being typed on its tile: asked for as soon as the
/// group is made. Return keeps it, Escape leaves the group unnamed, and so
/// does doing something else.
private struct GroupNameField: View {

    let size: CGFloat
    /// Called once, with the name to keep, or `nil` to keep what there was.
    var onDone: (String?) -> Void

    @State private var name = ""
    @State private var settled = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name this group", text: $name)
            .textFieldStyle(.plain)
            .font(Theme.noteFont(size: size).weight(.medium))
            .foregroundStyle(Theme.text)
            .focused($focused)
            .onSubmit { finish(name) }
            .onExitCommand { finish(nil) }
            .onAppear { focused = true }
            .onDisappear { if !settled { finish(name.isEmpty ? nil : name) } }
            .accessibilityLabel("Group name")
    }

    private func finish(_ kept: String?) {
        guard !settled else { return }
        settled = true
        onDone(kept)
    }
}

/// The pictures of several notes set out as one (`GroupMosaic`).
struct MosaicView: View {

    let notes: [Note]
    var gap: CGFloat = 3
    /// The side of the small square that stands for a card of words.
    var chip: CGFloat = 34

    var body: some View {
        GeometryReader { geometry in
            // A card of words has no picture: it is a chip, not a cell.
            let pictures = notes.filter { !$0.isTextOnly }
            let words = notes.count - pictures.count
            let cells = GroupMosaic.arrange(
                pictures: pictures.map { CGFloat($0.imageAspectRatio) }, words: words, in: geometry.size, gap: gap,
                chip: chip)
            ZStack(alignment: .topLeading) {
                ForEach(Array(cells.pictures.enumerated()), id: \.offset) { index, cell in
                    MosaicCell(
                        note: pictures[index],
                        // The last cell says how many more there are than fit.
                        more: index == cells.pictures.count - 1 ? pictures.count - cells.pictures.count : 0
                    )
                    .frame(width: cell.width, height: cell.height)
                    .offset(x: cell.minX, y: cell.minY)
                }
                ForEach(Array(cells.chips.enumerated()), id: \.offset) { index, cell in
                    WordsChip(more: index == cells.chips.count - 1 ? words - cells.chips.count : 0)
                        .frame(width: cell.width, height: cell.height)
                        .offset(x: cell.minX, y: cell.minY)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
}

/// A card of words in a group's tile: a small square that says "writing",
/// in the system's own face. The last of a row too long to show says how
/// many more there are.
private struct WordsChip: View {

    let more: Int

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let shape = RoundedRectangle(cornerRadius: side * 0.22, style: .continuous)
            Text(more > 0 ? "+\(more)" : "Aa")
                .font(.system(size: side * (more > 0 ? 0.34 : 0.4), weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(Theme.panelRaised, in: shape)
                .overlay { shape.strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth) }
        }
        .accessibilityHidden(true)
    }
}

private struct MosaicCell: View {

    let note: Note
    let more: Int

    @Environment(NoteStore.self) private var store
    @Environment(ImageCache.self) private var images
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            // Sharp when the cell is large; a thumbnail is plenty when small.
            let tier: ImageTier = geometry.size.width > 200 ? .card : .thumbnail
            ZStack {
                Theme.panelRaised
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                if more > 0 {
                    Theme.background.opacity(0.72)
                    Text("+\(more)")
                        .font(Theme.mono(max(8, min(16, geometry.size.height * 0.22)), weight: .medium))
                        .foregroundStyle(Theme.text)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .task(id: MosaicRequest(id: note.id, tier: tier)) {
                image = await images.load(id: note.id, url: store.imageURL(for: note), tier: tier)
            }
        }
    }

    private struct MosaicRequest: Hashable {
        let id: UUID
        let tier: ImageTier
    }
}

/// What a card looks like while it is held over another to be grouped with
/// it, and what the other looks like too: greyed and a little faint. Not
/// blurred: both can still be read.
struct Greyed: ViewModifier {

    let active: Bool

    func body(content: Content) -> some View {
        content
            .saturation(active ? 0.1 : 1)
            // A grey veil as well as the colour being taken out: the veil is
            // plain drawing, so it is there wherever the card is drawn.
            .overlay {
                Theme.textMuted.opacity(active ? 0.3 : 0)
                    .allowsHitTesting(false)
            }
            .opacity(active ? 0.86 : 1)
            .animation(.easeOut(duration: 0.12), value: active)
    }
}

/// The sign over two cards about to be grouped: says what letting go will do.
struct GroupBadge: View {

    /// "Group", or "Add to group" over one that exists.
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "square.on.square")
                .font(.system(size: 12, weight: .semibold))
            Text(label)
                .font(Theme.mono(12, weight: .medium))
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Theme.text, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
        .fixedSize()
        .allowsHitTesting(false)
        .accessibilityLabel(label)
    }
}

/// A group opened out over the board: its name, to be typed or changed, and
/// every card in it. A card can be opened from here or taken out of the
/// group; the group can be ended.
struct ExpandedGroupView: View {

    let entry: CanvasModel.BoardGroup

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas
    @State private var name = ""
    /// Choosing cards, to take several out at once.
    @State private var selecting = false
    @State private var selected: Set<UUID> = []

    private static let cardScale: CGFloat = 0.6

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.background.opacity(0.94)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                VStack(alignment: .leading, spacing: 0) {
                    header
                    Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
                    ScrollView {
                        LazyVGrid(
                            columns: [
                                GridItem(
                                    .adaptive(minimum: CanvasModel.nodeWidth * Self.cardScale), spacing: 16,
                                    alignment: .top)
                            ],
                            alignment: .leading, spacing: 18
                        ) {
                            ForEach(entry.members) { note in
                                member(note)
                            }
                        }
                        .padding(18)
                    }
                }
                .frame(
                    width: min(840, max(320, geometry.size.width - 120)),
                    height: min(640, max(240, geometry.size.height - 200))
                )
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
                }
                // Clicks on the panel itself must not fall through and close it.
                .contentShape(Rectangle())
                .onTapGesture {}
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            // Escape closes the group, unless a card from it is open on top.
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(canvas.expandedNoteID != nil || canvas.viewingNoteID != nil)
                .opacity(0)
        }
        .onAppear { name = entry.group.name }
        .onDisappear { store.renameGroup(id: entry.group.id, to: name) }
        .transition(.opacity)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "square.on.square")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            TextField("Name this group", text: $name)
                .textFieldStyle(.plain)
                .font(Theme.noteFont(size: 16).weight(.medium))
                .foregroundStyle(Theme.text)
                .onSubmit { store.renameGroup(id: entry.group.id, to: name) }
            Text(entry.members.count == 1 ? "1 card" : "\(entry.members.count) cards")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textMuted)
                .fixedSize()
            if selecting {
                Button(selected.isEmpty ? "remove from group" : "remove \(selected.count) from group") {
                    removeSelected()
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(selected.isEmpty)
                .opacity(selected.isEmpty ? 0.45 : 1)
                Button("cancel") {
                    withAnimation(.easeOut(duration: 0.12)) {
                        selecting = false
                        selected = []
                    }
                }
                .buttonStyle(QuietButtonStyle())
            } else {
                Button("edit") {
                    withAnimation(.easeOut(duration: 0.12)) { selecting = true }
                }
                .buttonStyle(QuietButtonStyle())
                .help("Choose cards to take out of the group")
                Button("ungroup") {
                    withAnimation(.easeOut(duration: 0.2)) { canvas.ungroup(entry.group, in: store) }
                }
                .buttonStyle(QuietButtonStyle())
                .help("End the group: its cards go back on the board")
                Button("done", action: close)
                    .buttonStyle(QuietButtonStyle())
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 48)
    }

    /// A card of the group. While choosing, a click chooses it, and it
    /// carries a round mark that is filled in when it is chosen.
    private func member(_ note: Note) -> some View {
        let chosen = selected.contains(note.id)
        return NodeView(note: note, scale: Self.cardScale)
            .allowsHitTesting(!selecting)
            .opacity(selecting && !chosen ? 0.7 : 1)
            .overlay(alignment: .topLeading) {
                if selecting {
                    ZStack {
                        Circle().fill(chosen ? Theme.text : Theme.background.opacity(0.7))
                        Circle().strokeBorder(Theme.text, lineWidth: 1.5)
                        if chosen {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Theme.background)
                        }
                    }
                    .frame(width: 22, height: 22)
                    .padding(8)
                    .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard selecting else { return }
                if chosen { selected.remove(note.id) } else { selected.insert(note.id) }
            }
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// Takes every chosen card out of the group. If that ends the group
    /// (one card or none left), this view goes with it.
    private func removeSelected() {
        withAnimation(.easeOut(duration: 0.2)) {
            for note in entry.members where selected.contains(note.id) {
                guard let group = store.group(entry.group.id) else { break }
                canvas.remove(note, from: group, in: store)
            }
            selected = []
            selecting = false
        }
    }

    private func close() {
        store.renameGroup(id: entry.group.id, to: name)
        withAnimation(.easeOut(duration: 0.15)) { canvas.expandedGroupID = nil }
    }
}
