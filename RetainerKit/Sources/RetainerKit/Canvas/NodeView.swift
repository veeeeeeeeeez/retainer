import AppKit
import SwiftUI

/// Sizes for a card at a given zoom. The canvas zooms by scaling these
/// (and the type) rather than by applying a transform, so text stays sharp
/// at every zoom level.
struct NodeMetrics {
    let scale: CGFloat

    var width: CGFloat { (CanvasModel.nodeWidth * scale).rounded() }
    var maxImageHeight: CGFloat { (CanvasModel.maxImageHeight * scale).rounded() }
    var padding: CGFloat { NodeLayout.padding * scale }
    var captionFontSize: CGFloat { NodeLayout.captionFontSize * scale }
    var captionLineSpacing: CGFloat { NodeLayout.captionLineSpacing * scale }
    var metaFontSize: CGFloat { 10.5 * scale }
    var radius: CGFloat { max(2, Theme.radius * scale) }

    /// Too small to read: the card is drawn as its screenshot alone.
    var isMiniature: Bool { width < 110 }
    /// Close enough to full size for the card's height to be worth recording.
    var isMeasurable: Bool { scale >= 0.75 }

    func imageHeight(aspectRatio: Double) -> CGFloat {
        min(width / CGFloat(max(aspectRatio, 0.05)), maxImageHeight).rounded()
    }
}

/// One capture on the canvas, kept small: the screenshot, the first lines of
/// the note, and where and when it came from.
///
/// A click opens the card out (`ExpandedCardView`), where the whole note can
/// be read and edited and everything that can be done to it is laid out.
/// If the capture has a link back to its source, it sits directly under the
/// screenshot as one quiet line, and a click on it goes there. Pointing at
/// the card dims the screenshot a touch. A card that has not been looked at
/// since it was saved carries a "new" marker and a brighter edge. The
/// right-click menu has every action too.
///
/// On a board zoomed so far out that the words could not be read (a month,
/// all time), the card is drawn as its screenshot alone, in the space the
/// whole card would take. It still opens on a click.
struct NodeView: View {

    let note: Note
    let scale: CGFloat
    /// Draws the card as it looks under the pointer, for the offscreen renders.
    var showsHover = false

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas
    @Environment(ImageCache.self) private var images

    @State private var image: CGImage?
    @State private var pointerInside = false

    private var hovering: Bool { pointerInside || showsHover }
    private var metrics: NodeMetrics { NodeMetrics(scale: scale) }

    /// Saved since the window was last looked at, and still on the canvas.
    private var isNew: Bool { !note.seen && !note.isArchived }

    var body: some View {
        Group {
            if metrics.isMiniature {
                miniature
            } else {
                card
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { canvas.expand(note.id, in: store) }
        .contextMenu { contextMenu }
        .onHover { pointerInside = $0 }
        // A card drawn small asks for a small picture.
        .task(id: ImageRequest(id: note.id, tier: metrics.width <= 180 ? .thumbnail : .card, pixels: note.imagePixelSize.width)) {
            let tier: ImageTier = metrics.width <= 180 ? .thumbnail : .card
            if let loaded = await images.load(id: note.id, url: store.imageURL(for: note), tier: tier) {
                image = loaded
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.35), value: isNew)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// The screenshot alone, for a board zoomed far out.
    private var miniature: some View {
        ZStack {
            Theme.panel
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            }
            Color.black.opacity(hovering ? 0.12 : 0)
        }
        .frame(width: metrics.width, height: metrics.imageHeight(aspectRatio: note.imageAspectRatio))
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay {
            RoundedRectangle(cornerRadius: 2)
                .strokeBorder(borderColour, lineWidth: Theme.hairlineWidth)
        }
        .overlay(alignment: .topLeading) {
            if isNew {
                Circle()
                    .fill(Theme.text)
                    .frame(width: 5, height: 5)
                    .offset(x: -2, y: -2)
            }
        }
        // Keeps the room the whole card has on the board.
        .frame(width: metrics.width, alignment: .topLeading)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A typed note has no picture: its card is its words.
            if !note.isTextOnly {
                if note.sourceApp == "Link", let link = note.sourceURL {
                    // A pasted link's picture is the way to the page itself.
                    screenshot
                        .onTapGesture {
                            store.markSeen([note.id])
                            _ = SourceLink.open(link)
                        }
                        .help("Open \(SourceLink.displayText(for: link))")
                } else {
                    screenshot
                }
            }
            if !note.isTextOnly {
                Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            }
            VStack(alignment: .leading, spacing: 0) {
                if let link = note.sourceURL {
                    SourceLine(link: link, fontSize: NodeLayout.linkFontSize * scale, cardHovered: hovering) {
                        store.markSeen([note.id])
                    }
                    .padding(.bottom, NodeLayout.linkToCaption * scale)
                }
                caption
                footer
                    .padding(.top, NodeLayout.captionToFooter * scale)
            }
            .padding(.horizontal, metrics.padding)
            .padding(.top, (note.sourceURL == nil ? NodeLayout.captionTop : NodeLayout.linkTop) * scale)
            .padding(.bottom, NodeLayout.footerBottom * scale)
        }
        .frame(width: metrics.width)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius))
        .overlay {
            RoundedRectangle(cornerRadius: metrics.radius)
                .strokeBorder(borderColour, lineWidth: Theme.hairlineWidth)
        }
        // The board finds room for other cards from how tall this one really
        // is. Only worth recording near full size: drawn small, lines of text
        // round up to whole points and the card comes out taller than scale.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            if metrics.isMeasurable {
                canvas.setMeasuredHeight(height / scale, for: note.id)
            }
        }
    }

    private var borderColour: Color {
        if isNew { return Theme.textMuted }
        return hovering ? Theme.hairlineStrong : Theme.hairline
    }

    // MARK: Screenshot

    private var screenshot: some View {
        ZStack {
            Theme.background
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            // Dims a touch under the pointer: the card can be opened.
            Color.black.opacity(hovering ? 0.12 : 0)
        }
        .frame(width: metrics.width, height: metrics.imageHeight(aspectRatio: note.imageAspectRatio))
    }

    // MARK: Caption and footer

    private var caption: some View {
        let preview = NotePreview.text(for: note.note)
        return Text(preview.isEmpty ? "No note" : preview)
            .font(Theme.noteFont(size: metrics.captionFontSize))
            .lineSpacing(metrics.captionLineSpacing)
            .foregroundStyle(preview.isEmpty ? Theme.textFaint : Theme.text)
            .lineLimit(note.isTextOnly ? NodeLayout.textOnlyLines : NodeLayout.captionLines)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 8 * scale) {
            if isNew {
                newMarker.transition(.opacity)
            }
            Text(SourceLabel.text(for: note))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8 * scale)
            Text(SourceLabel.timestamp.string(from: note.timestamp))
                .foregroundStyle(Theme.textFaint)
                .lineLimit(1)
                .fixedSize()
        }
        .font(Theme.mono(metrics.metaFontSize))
    }

    /// A dot and a word, on a card that has not been looked at yet.
    private var newMarker: some View {
        HStack(spacing: 4 * scale) {
            Circle()
                .fill(Theme.text)
                .frame(width: 5 * scale, height: 5 * scale)
            Text("new")
                .foregroundStyle(Theme.text)
        }
        .fixedSize()
        .accessibilityLabel("New")
    }

    // MARK: Right-click menu

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open") { canvas.expand(note.id, in: store) }
        Button("Edit Note") { canvas.expand(note.id, in: store, editing: true) }
        Button("View Full Size") {
            store.markSeen([note.id])
            canvas.viewingNoteID = note.id
        }
        if let link = note.sourceURL {
            Divider()
            SourceMenuItems(link: link)
        }
        if !note.isArchived, !store.projects.isEmpty {
            Divider()
            // A canvas is a second place for the card: it stays on its day.
            Menu("Add to Canvas") {
                ForEach(store.projects) { project in
                    let canvases = store.canvases(in: project.id)
                    if !canvases.isEmpty {
                        Section(project.name) {
                            ForEach(canvases) { target in
                                Button(target.name) {
                                    withAnimation(.easeOut(duration: 0.2)) { canvas.add(note, to: target.id, in: store) }
                                }
                                .disabled(store.isPlaced(note.id, on: target.id))
                            }
                        }
                    }
                }
            }
        }
        if let canvasID = canvas.canvasID {
            Button("Remove from Canvas") {
                withAnimation(.easeOut(duration: 0.2)) { store.remove(noteID: note.id, from: canvasID) }
            }
        }
        Divider()
        Button(note.isArchived ? "Restore to Board" : "Archive") {
            withAnimation(.easeOut(duration: 0.2)) {
                if note.isArchived {
                    canvas.restore(note, in: store)
                } else {
                    canvas.archive(note, in: store)
                }
            }
        }
        // Opens the card with "delete" waiting for its second click.
        Button("Delete…") { canvas.expand(note.id, in: store, confirmingDelete: true) }
    }
}

/// Which picture a card is waiting for.
private struct ImageRequest: Hashable {
    let id: UUID
    let tier: ImageTier
    /// The picture's width: it changes when the picture is replaced.
    let pixels: Int
}

/// The source line of a card: the app, and the window's title if it had one.
enum SourceLabel {

    static func text(for note: Note) -> String {
        switch (note.sourceApp, note.windowTitle) {
        case (let app?, let title?) where !title.isEmpty: "\(app)  /  \(title)"
        case (let app?, _): app
        case (nil, let title?): title
        default: "unknown source"
        }
    }

    static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// The link back to where a capture came from, as one quiet line for under
/// its screenshot: a small arrow (or a document, for a file) and the address
/// or path. Faint until the pointer is over the card, plain and underlined
/// when it is over the line itself. A click goes there.
struct SourceLine: View {

    let link: String
    var fontSize: CGFloat = 10
    /// The pointer is somewhere over the card this line is on.
    var cardHovered = false
    var onOpen: () -> Void = {}

    @State private var hovering = false

    var body: some View {
        Button {
            onOpen()
            if !SourceLink.open(link) { NSSound.beep() }
        } label: {
            HStack(spacing: fontSize * 0.45) {
                Image(systemName: SourceLink.isFile(link) ? "doc" : "arrow.up.right")
                    .font(.system(size: fontSize * 0.85, weight: .medium))
                Text(SourceLink.displayText(for: link))
                    .underline(hovering)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Theme.mono(fontSize))
            .foregroundStyle(colour)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(SourceLink.isFile(link) ? "Open the file this came from" : "Open the page this came from")
        .accessibilityLabel(SourceLink.isFile(link) ? "Open source file" : "Open source page")
    }

    private var colour: Color {
        if hovering { return Theme.text }
        return cardHovered ? Theme.textMuted : Theme.textFaint
    }
}

/// The menu items for a capture's link: open it, show a file in the Finder,
/// copy it.
struct SourceMenuItems: View {

    let link: String

    var body: some View {
        Button(SourceLink.isFile(link) ? "Open Source File" : "Open Source Page") {
            if !SourceLink.open(link) { NSSound.beep() }
        }
        if SourceLink.isFile(link) {
            Button("Show in Finder") { SourceLink.revealInFinder(link) }
        }
        Button(SourceLink.isFile(link) ? "Copy Path" : "Copy Link") { SourceLink.copy(link) }
    }
}
