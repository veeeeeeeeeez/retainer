import AppKit
import SwiftUI

/// A handle on a live editor, for the things SwiftUI state cannot express:
/// taking keyboard focus and asking whether an input method is mid-composition.
@MainActor
final class EditorHandle {
    fileprivate weak var textView: NSTextView?

    /// Makes the editor first responder, optionally moving the cursor to the end.
    func focus(atEnd: Bool) {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        if atEnd {
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    /// True while an input method has uncommitted text; Escape belongs to it then.
    var hasMarkedText: Bool { textView?.hasMarkedText() ?? false }

    var isFocused: Bool {
        guard let textView else { return false }
        return textView.window?.firstResponder === textView
    }
}

/// A plain-text editor for Markdown source, set in the note typeface.
///
/// It wraps `NSTextView` rather than SwiftUI's `TextEditor` because the card
/// needs things `TextEditor` does not offer: cursor placement, a height that
/// follows the text, and focus that can be taken programmatically.
struct MarkdownEditor: NSViewRepresentable {

    @Binding var text: String
    var fontSize: CGFloat = 16
    var handle: EditorHandle?
    /// Reports the height the text needs at the current width.
    var onHeightChange: (CGFloat) -> Void = { _ in }
    /// Escape or Command-Return, when the host does not intercept them itself.
    var onCommit: (() -> Void)?
    /// Called when the editor loses keyboard focus.
    var onEndEditing: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, built explicitly: its layout manager gives a dependable
        // measure of how tall the text is.
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)

        let textView = EditorTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.insertionPointColor = Theme.nsText
        textView.selectedTextAttributes = [.backgroundColor: Theme.nsSelection, .foregroundColor: Theme.nsText]

        // Markdown is typed literally: no smart quotes, dashes or replacements,
        // and no coloured squiggles under names and jargon.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false

        textView.onCommit = { [weak coordinator = context.coordinator] in coordinator?.parent.onCommit?() }
        applyTypography(to: textView)
        textView.string = text

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = textView

        context.coordinator.textView = textView
        handle?.textView = textView

        textView.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: textView, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            MainActor.assumeIsolated { coordinator?.reportHeight() }
        }
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in coordinator?.reportHeight() }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        handle?.textView = textView

        if textView.font?.pointSize != fontSize {
            applyTypography(to: textView)
            context.coordinator.reportHeight()
        }
        if textView.string != text {
            textView.string = text
            applyTypography(to: textView)
            context.coordinator.reportHeight()
        }
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func applyTypography(to textView: NSTextView) {
        let font = Theme.noteNSFont(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = Theme.noteLineSpacing(size: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: Theme.nsText,
            .paragraphStyle: paragraph,
        ]
        textView.font = font
        textView.textColor = Theme.nsText
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = attributes
        if let storage = textView.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        weak var textView: NSTextView?
        var frameObserver: NSObjectProtocol?
        private var lastReportedHeight: CGFloat = -1
        /// The typing's own undo, apart from the window's: there, ⌘Z takes
        /// back whole steps on the board, and the editor's keystrokes would
        /// outlive the editor.
        private let typingUndo = UndoManager()

        func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

        init(_ parent: MarkdownEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            if parent.text != textView.string {
                parent.text = textView.string
            }
            reportHeight()
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onEndEditing?()
        }

        func reportHeight() {
            guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer
            else { return }
            layoutManager.ensureLayout(for: container)
            var height = layoutManager.usedRect(for: container).height
            if height <= 0 {
                // Empty text still occupies one line.
                height = layoutManager.defaultLineHeight(for: textView.font ?? Theme.noteNSFont())
            }
            height = ceil(height)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            let report = parent.onHeightChange
            // Reported after the current layout pass; changing SwiftUI state
            // from inside one is not allowed.
            DispatchQueue.main.async { report(height) }
        }
    }
}

/// `NSTextView` with the two keys an inline editor needs.
final class EditorTextView: NSTextView {

    var onCommit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let isReturn = event.keyCode == UInt16(KeyCode.returnKey) || event.keyCode == UInt16(KeyCode.keypadEnter)
        if isReturn && event.modifierFlags.contains(.command), let onCommit {
            onCommit()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() {
            super.cancelOperation(sender)
        } else if let onCommit {
            onCommit()
        } else {
            super.cancelOperation(sender)
        }
    }
}
