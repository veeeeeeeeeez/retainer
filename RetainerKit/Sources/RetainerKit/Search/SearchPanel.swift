import AppKit
import SwiftUI

/// The search box, floating over the board: one line to type in, and under
/// it the notes found. Up and down choose, Return goes to the note, Escape
/// (or a click anywhere else) closes.
struct SearchPanel: View {

    let app: AppModel

    static let width: CGFloat = 600
    private static let rowHeight: CGFloat = 58
    private static let visibleRows: CGFloat = 7

    private var search: SearchModel { app.search }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.34)
                .contentShape(Rectangle())
                .onTapGesture { search.close() }
            // Where the switch and the search button are: it opens out of them.
            panel
                .padding(.top, 8)
        }
        .transition(.opacity)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            field
            if !search.hits.isEmpty {
                rule
                results
            } else if isAsked, search.meaning != .asking {
                rule
                Text("Nothing found")
                    .font(Theme.noteFont(size: 13))
                    .foregroundStyle(Theme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
            }
            if let footnote {
                rule
                Text(footnote)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .frame(height: 26)
            }
        }
        .frame(width: Self.width)
        .floatingGlass(cornerRadius: 14, tint: 0.86)
        // Clicks on the panel itself must not fall through and close it.
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {}
    }

    private var isAsked: Bool {
        !search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textMuted)
            SearchField(
                text: Binding(get: { search.query }, set: { search.query = $0 }),
                onMove: { search.move(by: $0) },
                onSubmit: { app.openChosenSearchHit() },
                onCancel: { search.close() })
            if search.meaning == .asking {
                ProgressView()
                    .controlSize(.small)
                    .help("Asking Claude")
            }
            Button {
                search.close()
            } label: {
                Text("esc")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay {
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close search")
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(search.hits.enumerated()), id: \.element.id) { index, hit in
                        if let note = app.store.note(hit.id) {
                            SearchRow(
                                note: note, hit: hit, query: search.query, selected: index == search.selection,
                                today: app.canvas.currentDate, calendar: app.store.calendar
                            )
                            .frame(height: Self.rowHeight)
                            .id(hit.id)
                            .onTapGesture {
                                search.select(hit.id)
                                app.openChosenSearchHit()
                            }
                        }
                    }
                }
                .padding(6)
            }
            .frame(height: min(CGFloat(search.hits.count), Self.visibleRows) * Self.rowHeight + 12)
            .onChange(of: search.selection) { _, _ in
                if let id = search.chosen { proxy.scrollTo(id) }
            }
        }
    }

    /// One quiet line under the results, only when there is something to say.
    private var footnote: String? {
        if case .failed(let failure) = search.meaning {
            switch failure {
            case .key: return "by words only: the key in Settings was not accepted"
            case .unreachable: return "by words only: Claude could not be reached"
            case .answer: return "by words only: Claude gave no answer"
            }
        }
        if app.pictureText.remaining > 0 {
            let count = app.pictureText.remaining
            return count == 1 ? "still reading 1 picture" : "still reading \(count) pictures"
        }
        return nil
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
    }
}

/// One note found: its picture, the line that matched with the words
/// marked, and when and where it is from.
private struct SearchRow: View {

    let note: Note
    let hit: SearchHit
    let query: String
    let selected: Bool
    let today: Date
    let calendar: Calendar

    @Environment(NoteStore.self) private var store
    @Environment(ImageCache.self) private var images
    @State private var image: CGImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 4) {
                Text(line)
                    .font(Theme.noteFont(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .background(selected ? Theme.text.opacity(0.09) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .task(id: note.id) {
            guard !note.isTextOnly else { return }
            image = images.image(for: note.id, tier: .thumbnail)
            if image == nil {
                image = await images.load(id: note.id, url: store.imageURL(for: note), tier: .thumbnail)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.panelRaised.overlay {
                    Image(systemName: note.isTextOnly ? "text.alignleft" : "photo")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textFaint)
                }
            }
        }
        .frame(width: 52, height: 40)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth) }
    }

    /// The matching line, the words searched for brighter than the rest.
    private var line: AttributedString {
        let text = hit.snippet.isEmpty ? SourceLabel.text(for: note) : hit.snippet
        var line = AttributedString(text)
        let marks = NoteSearch.marks(of: query, in: text)
        line.foregroundColor = marks.isEmpty ? Theme.text : Theme.textSecondary
        for mark in marks {
            guard let lower = AttributedString.Index(mark.lowerBound, within: line),
                let upper = AttributedString.Index(mark.upperBound, within: line)
            else { continue }
            line[lower..<upper].foregroundColor = Theme.text
            line[lower..<upper].font = Theme.noteFont(size: 13).weight(.semibold)
        }
        return line
    }

    private var detail: String {
        var parts = [SearchDates.label(for: note.timestamp, today: today, calendar: calendar)]
        if hit.place == .picture { parts.append("in the picture") }
        if hit.place == .meaning { parts.append("found by meaning") }
        if note.isArchived { parts.append("archived") }
        parts.append(SourceLabel.text(for: note))
        return parts.joined(separator: "  ·  ")
    }
}

/// When a found note is from: "Today 15:08", "Yesterday 09:14", "Thu 19 Nov", "3 Mar 2025".
enum SearchDates {

    static func label(for date: Date, today: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: today)
        ).day ?? 0
        if days == 0 || days == 1 {
            formatter.dateFormat = "HH:mm"
            return (days == 0 ? "Today " : "Yesterday ") + formatter.string(from: date)
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: today)
        formatter.dateFormat = sameYear ? "EEE d MMM" : "d MMM yyyy"
        return formatter.string(from: date)
    }
}

/// The line typed into. An AppKit field, because up, down, Return and
/// Escape have to do something other than what a text field does with them,
/// and it has to take the keyboard the moment it appears.
private struct SearchField: NSViewRepresentable {

    @Binding var text: String
    var onMove: (Int) -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FocusingField {
        let field = FocusingField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Theme.noteNSFont(size: 17)
        field.textColor = Theme.nsText
        field.placeholderAttributedString = NSAttributedString(
            string: "Search your notes",
            attributes: [.font: Theme.noteNSFont(size: 17), .foregroundColor: Theme.nsTextFaint])
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.stringValue = text
        field.setAccessibilityLabel("Search your notes")
        return field
    }

    func updateNSView(_ field: FocusingField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class FocusingField: NSTextField {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // After the layout pass that put it there.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchField

        init(_ parent: SearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            if parent.text != field.stringValue { parent.text = field.stringValue }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}
