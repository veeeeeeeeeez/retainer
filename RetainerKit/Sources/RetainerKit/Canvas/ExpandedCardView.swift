import AppKit
import SwiftUI

/// A card opened out over the canvas: the screenshot as large as fits, the
/// whole note (which can be edited here), where it came from, and everything
/// that can be done to it.
///
/// Clicking outside it, pressing Escape or "close" puts it away. The link
/// back to the source sits directly under the screenshot, as on the small
/// card.
struct ExpandedCardView: View {

    let note: Note

    @Environment(NoteStore.self) private var store
    @Environment(CanvasModel.self) private var canvas
    @Environment(ImageCache.self) private var images

    @State private var image: CGImage?
    @State private var draft = ""
    @State private var editorHeight: CGFloat = 0
    @State private var editor = EditorHandle()

    private static let noteFontSize: CGFloat = 16

    private var isEditing: Bool { canvas.editingNoteID == note.id }
    private var confirmingDelete: Bool { canvas.confirmingDeleteID == note.id }

    var body: some View {
        GeometryReader { geometry in
            let layout = Layout(note: note, available: geometry.size)
            ZStack {
                Theme.background.opacity(0.94)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                VStack(alignment: .leading, spacing: 0) {
                    // A typed note has no picture to show.
                    if !note.isTextOnly {
                        screenshot(layout)
                        rule
                    }
                    if let link = note.sourceURL {
                        SourceLine(link: link, fontSize: 11, cardHovered: true)
                            .padding(.horizontal, 18)
                            .padding(.top, 10)
                    }
                    noteArea(maxHeight: layout.noteMaxHeight)
                    rule
                    details
                    rule
                    actions
                }
                .frame(width: layout.width)
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.radius)
                        .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
                }
                // Clicks on the card itself must not fall through and close it.
                .contentShape(Rectangle())
                .onTapGesture {}
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background {
            // Escape closes the card when no editor has the keyboard, and
            // not while the full-size screenshot is open on top of it.
            Button("Close", action: close)
                .keyboardShortcut(.cancelAction)
                .disabled(canvas.viewingNoteID != nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: note.id) {
            image = images.image(for: note.id)
            let url = store.imageURL(for: note)
            let full = await Task.detached(priority: .userInitiated) {
                UncheckedBox(ImageFiles.load(url, maxPixelSize: nil))
            }.value.value
            if let full { image = full }
        }
        .onChange(of: isEditing) { _, editing in
            // However the editing ends, all of it is one step to undo.
            if editing { beginEditing() } else { store.endTextEdit(id: note.id) }
        }
        .onAppear {
            if isEditing { beginEditing() }
        }
        .onDisappear { store.endTextEdit(id: note.id) }
        .transition(.opacity)
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
    }

    // MARK: Layout

    /// Sizes for the card in the space the window gives it.
    struct Layout {
        let width: CGFloat
        let imageSize: CGSize
        let imageAreaHeight: CGFloat
        let noteMaxHeight: CGFloat

        init(note: Note, available: CGSize) {
            let margin: CGFloat = 40
            let maxWidth = max(320, min(available.width - 2 * margin, 1040))
            let maxHeight = max(320, available.height - 2 * margin)
            // The screenshot gets most of the height; the note and the lines
            // under it get the rest.
            let fitted = ScreenGeometry.fit(
                note.imagePointSize, within: CGSize(width: maxWidth, height: (maxHeight * 0.6).rounded()))
            imageSize = CGSize(width: max(1, fitted.width.rounded()), height: max(1, fitted.height.rounded()))
            width = min(maxWidth, max(imageSize.width, 620))
            imageAreaHeight = imageSize.height
            // What is left once the lines under the note have had theirs.
            noteMaxHeight = max(80, maxHeight - imageAreaHeight - (note.sourceURL == nil ? 106 : 132))
        }
    }

    // MARK: Screenshot

    private func screenshot(_ layout: Layout) -> some View {
        ZStack {
            Theme.background
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                } else {
                    Theme.panelRaised
                }
            }
            .frame(width: layout.imageSize.width, height: layout.imageSize.height)
        }
        .frame(width: layout.width, height: layout.imageAreaHeight)
        .accessibilityLabel("Screenshot")
    }

    // MARK: Note

    private func noteArea(maxHeight: CGFloat) -> some View {
        ScrollView(.vertical) {
            Group {
                if isEditing {
                    MarkdownEditor(
                        text: $draft,
                        fontSize: Self.noteFontSize,
                        handle: editor,
                        onHeightChange: { editorHeight = $0 },
                        onCommit: { endEditing() },
                        onEndEditing: { endEditing() }
                    )
                    .frame(height: max(editorHeight, Self.noteFontSize * 1.4))
                    .onChange(of: draft) { _, text in
                        // Saved as it is typed; the store batches the disk writes.
                        store.updateText(id: note.id, text: text)
                    }
                } else if note.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Click to add a note")
                        .font(Theme.noteFont(size: Self.noteFontSize))
                        .foregroundStyle(Theme.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownText(source: note.note, fontSize: Self.noteFontSize)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, note.sourceURL == nil ? 16 : 10)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if !isEditing { edit() }
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func edit() {
        canvas.confirmingDeleteID = nil
        canvas.editingNoteID = note.id
    }

    private func beginEditing() {
        draft = note.note
        store.beginTextEdit(id: note.id)
        Task {
            // The text view exists after the next layout pass.
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(16))
                guard canvas.editingNoteID == note.id else { return }
                editor.focus(atEnd: true)
                if editor.isFocused { return }
            }
        }
    }

    private func endEditing() {
        guard canvas.editingNoteID == note.id else { return }
        store.updateText(id: note.id, text: draft)
        store.endTextEdit(id: note.id)
        canvas.editingNoteID = nil
    }

    // MARK: Where it came from

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SourceLabel.text(for: note))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(facts)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(Theme.mono(11))
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// When, and how big the picture is. Which engine heard the note and
    /// what the tidy pass did are saved with it and shown nowhere: those
    /// belong to the settings.
    private var facts: String {
        var parts = [SourceLabel.timestamp.string(from: note.timestamp)]
        // A card of words has no picture to give the size of.
        if !note.isTextOnly {
            parts.append("\(note.imagePixelSize.width) × \(note.imagePixelSize.height) px")
        }
        if note.isArchived { parts.append("archived") }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 14) {
            if confirmingDelete {
                Button("click again to delete") { delete() }
                    .buttonStyle(CardActionStyle(emphasised: true))
                Button("cancel") { canvas.confirmingDeleteID = nil }
                    .buttonStyle(CardActionStyle())
            } else {
                Button(isEditing ? "done" : "edit") {
                    if isEditing { endEditing() } else { edit() }
                }
                .buttonStyle(CardActionStyle())
                Button(note.isArchived ? "restore" : "archive") { toggleArchive() }
                    .buttonStyle(CardActionStyle())
                Button("delete") {
                    if isEditing { endEditing() }
                    canvas.confirmingDeleteID = note.id
                }
                .buttonStyle(CardActionStyle())
                Button("full size") { canvas.viewingNoteID = note.id }
                    .buttonStyle(CardActionStyle())
                if let link = note.sourceURL {
                    Button(SourceLink.isFile(link) ? "open file" : "open page") {
                        if !SourceLink.open(link) { NSSound.beep() }
                    }
                    .buttonStyle(CardActionStyle())
                    Button(SourceLink.isFile(link) ? "copy path" : "copy link") { SourceLink.copy(link) }
                        .buttonStyle(CardActionStyle())
                    if SourceLink.isFile(link) {
                        Button("show in finder") { SourceLink.revealInFinder(link) }
                            .buttonStyle(CardActionStyle())
                    }
                }
            }
            Spacer(minLength: 16)
            Button("close", action: close)
                .buttonStyle(CardActionStyle())
        }
        .font(Theme.mono(11))
        .padding(.horizontal, 18)
        .frame(height: 40)
    }

    private func toggleArchive() {
        if isEditing { endEditing() }
        withAnimation(.easeOut(duration: 0.2)) {
            if note.isArchived {
                canvas.restore(note, in: store)
            } else {
                canvas.archive(note, in: store)
            }
        }
    }

    private func delete() {
        images.remove(note.id)
        withAnimation(.easeOut(duration: 0.18)) {
            canvas.forget(note.id)
            store.delete(id: note.id)
        }
    }

    private func close() {
        if isEditing { endEditing() }
        withAnimation(.easeOut(duration: 0.12)) { canvas.collapse() }
    }
}

/// A word-sized button on the opened card: quiet, bright under the pointer.
private struct CardActionStyle: ButtonStyle {
    var emphasised = false

    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration, emphasised: emphasised)
    }

    private struct Label: View {
        let configuration: Configuration
        let emphasised: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(emphasised || hovering || configuration.isPressed ? Theme.text : Theme.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
