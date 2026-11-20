import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// What has been pasted into the input box and is waiting there: links and
/// pictures, in the order they came. Return sends them on, one at a time, to
/// be shown in the middle of the screen and spoken about, as a screenshot is.
@MainActor
@Observable
public final class StagingModel {

    private(set) var items: [StagedItem] = []
    /// What has been typed in the box.
    var text = ""
    /// A word about what just happened, or could not.
    private(set) var hint: String?
    /// Whether the box has the keyboard.
    var isFocused = false

    /// Called with everything that was waiting when Return is pressed with
    /// nothing typed: those things go on to be spoken about.
    @ObservationIgnored var onSubmit: ([StagedItem]) -> Void = { _ in }
    /// Called when Return is pressed with something typed: the words are
    /// the note, for each thing waiting or on their own.
    @ObservationIgnored var onSave: (String, [StagedItem]) -> Void = { _, _ in }

    public init() {}

    /// Takes the links and pictures on a pasteboard. False when it holds
    /// neither, so that it can be pasted as ordinary text instead.
    @discardableResult
    func take(from pasteboard: NSPasteboard) -> Bool {
        switch StagedItem.read(from: pasteboard) {
        case .items(let found):
            add(found)
            return true
        case .unsupported:
            hint = "only links and pictures can go here"
            return true
        case .nothing:
            return false
        }
    }

    func add(_ new: [StagedItem]) {
        guard !new.isEmpty else { return }
        items.append(contentsOf: new)
        hint = nil
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
    }

    func removeLast() {
        if !items.isEmpty { items.removeLast() }
    }

    func say(_ hint: String) {
        self.hint = hint
    }

    /// Whether Return would do anything.
    var canSubmit: Bool {
        !items.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Return. A link typed on its own joins what is waiting. Then, with
    /// words in the box, they are saved as the note: of each thing waiting,
    /// or by themselves. With no words, what is waiting goes on to be shown
    /// and spoken about.
    func submit() {
        var ready = items
        if let url = StagedItem.webURL(from: text), let link = StagedItem.link(url) {
            ready.append(link)
            text = ""
        }
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ready.isEmpty || !words.isEmpty else { return }
        items = []
        hint = nil
        text = ""
        if words.isEmpty {
            onSubmit(ready)
        } else {
            onSave(words, ready)
        }
    }
}

/// The box floating at the bottom of the board. Links and pictures pasted
/// here (or anywhere in the window, when no note is being written) wait in
/// it as small pictures; Return takes them on to be spoken about.
struct InputBar: View {

    let staging: StagingModel
    /// The microphone is on for the box.
    var isDictating = false
    /// How loud it is, for the pill over the box.
    var meter: LevelMeter?
    var onMicrophone: () -> Void = {}
    var onAttach: () -> Void = {}

    @FocusState private var focused: Bool

    static let height: CGFloat = 96
    private static let stagedHeight: CGFloat = 52

    var body: some View {
        @Bindable var staging = staging
        VStack(alignment: .leading, spacing: 0) {
            if !staging.items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(staging.items) { item in
                            StagedThumbnail(item: item) { staging.remove(item.id) }
                        }
                    }
                    .padding(.horizontal, 14)
                }
                .frame(height: Self.stagedHeight)
                .padding(.top, 12)
            }
            TextField(
                staging.items.isEmpty ? "Write a note, or paste a link or a picture…" : "Say something about it…",
                text: $staging.text)
                .textFieldStyle(.plain)
                .font(Theme.noteFont(size: 15))
                .foregroundStyle(Theme.text)
                .focused($focused)
                .onSubmit { staging.submit() }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                barButton("paperclip", help: "Attach files", action: onAttach)
                Text(staging.hint ?? quietHint)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
                Spacer()
                barButton(
                    isDictating ? "stop.fill" : "mic", help: isDictating ? "Stop dictating" : "Dictate",
                    lit: isDictating, action: onMicrophone)
                Button {
                    staging.submit()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 26, height: 26)
                        .background(
                            staging.canSubmit ? Theme.text : Theme.textFaint, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .disabled(!staging.canSubmit)
                .help("Show it and talk about it")
                .accessibilityLabel("Talk about it")
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
        }
        .frame(height: Self.height + (staging.items.isEmpty ? 0 : Self.stagedHeight - 6))
        .floatingGlass(cornerRadius: 14, tint: 0.78)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture { focused = true }
        .onChange(of: focused) { _, now in staging.isFocused = now }
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            Task {
                let pictures = await StagedItem.pictures(from: providers)
                if pictures.isEmpty {
                    staging.say("only pictures can be dropped here")
                } else {
                    staging.add(pictures)
                }
            }
            return true
        }
        .background { PasteMonitor(staging: staging) }
        // While dictating, the same pill a capture has, over the box.
        .overlay(alignment: .top) {
            if isDictating, let meter {
                RecordingPill(meter: meter)
                    .offset(y: -(RecordingPill.height + 10))
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: staging.items.count)
        .animation(.easeOut(duration: 0.15), value: isDictating)
    }

    private var quietHint: String {
        if isDictating { return "listening: what you say is written here  ·  click the square to stop" }
        if staging.items.isEmpty { return "return saves what you write as a note" }
        let hasWords = !staging.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasWords ? "return saves it with your note" : "return to say what you think, or write it first"
    }

    /// One of the small buttons along the bottom of the box.
    private func barButton(_ symbol: String, help: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(lit ? Theme.background : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .background(lit ? Theme.text : Theme.panelRaised, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// One thing waiting in the input box: its picture, small, with a cross to
/// take it out again.
private struct StagedThumbnail: View {

    let item: StagedItem
    var onRemove: () -> Void

    static let height: CGFloat = 48

    var body: some View {
        // The whole picture, as wide as its shape makes it at this height,
        // within reason for something very wide or very tall.
        let natural = item.image.pointSize
        let width = min(max(Self.height * natural.width / max(natural.height, 1), 36), 120)
        return Image(decorative: item.image.cgImage, scale: item.image.scale)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fill)
            .frame(width: width.rounded(), height: Self.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 15, height: 15)
                        .background(Theme.background.opacity(0.85), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(3)
                .help("Take it out")
                .accessibilityLabel("Take it out")
            }
            .help(item.title ?? item.sourceURL ?? item.origin)
            .accessibilityLabel(item.title ?? item.origin)
    }
}

/// Watches the keyboard for the two things a text field cannot be asked to
/// do: paste a picture, and take back the last thing pasted.
///
/// ⌘V goes to staging when the clipboard holds a link or a picture, from the
/// input box or from anywhere in the window where no note is being written.
/// Plain text is left to be pasted as text. Backspace in the empty box takes
/// out the last thing that is waiting.
private struct PasteMonitor: NSViewRepresentable {

    let staging: StagingModel

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.staging = staging
        view.install()
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.staging = staging
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.uninstall()
    }

    final class MonitorView: NSView {
        var staging: StagingModel?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// Returns true when the key was used.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, let staging else { return false }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])

            if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" {
                // A note is being written somewhere else in the window:
                // what is pasted there is that note's.
                if window.firstResponder is NSTextView, !staging.isFocused { return false }
                return staging.take(from: .general)
            }

            let backspace: UInt16 = 51
            if event.keyCode == backspace, flags.isEmpty, staging.isFocused, staging.text.isEmpty,
                !staging.items.isEmpty
            {
                staging.removeLast()
                return true
            }
            return false
        }
    }
}
