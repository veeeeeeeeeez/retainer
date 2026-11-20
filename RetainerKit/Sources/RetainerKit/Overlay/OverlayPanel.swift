import AppKit
import SwiftUI

/// The borderless, non-activating window the capture is drawn in.
///
/// It never activates this app. During the drag and while speaking it does
/// not take keyboard focus either, so the app underneath stays exactly as it
/// was. For the editor it becomes key (and only key), which is what lets
/// focus fall straight back to the previous app when it closes.
final class OverlayPanel: NSPanel {

    /// Whether the panel may take keyboard focus. Off until recording ends.
    var allowsKey = false
    /// Sees every key press first. Return true to swallow the event.
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        ignoresMouseEvents = true
        appearance = NSAppearance(named: .darkAqua)
        // Visible on every Space and over full-screen apps, and kept out of
        // window cycling and Mission Control.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    /// The standard editing shortcuts normally come from the main menu of the
    /// active app. This panel is key while another app is active, so route
    /// them to the first responder directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift],
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return false }

        let action: Selector? =
            switch (key, flags.contains(.shift)) {
            case ("x", false): #selector(NSText.cut(_:))
            case ("c", false): #selector(NSText.copy(_:))
            case ("v", false): #selector(NSText.paste(_:))
            case ("a", false): #selector(NSText.selectAll(_:))
            case ("z", false): Selector(("undo:"))
            case ("z", true): Selector(("redo:"))
            default: nil
            }
        guard let action else { return false }
        return NSApp.sendAction(action, to: nil, from: self)
    }
}

/// Shows and hides the overlay for a capture session.
@MainActor
final class OverlayController: OverlayPresenting {

    private var panel: OverlayPanel?

    /// Above the menu bar, the Dock and any open menu.
    private static let coveringLevel = NSWindow.Level.screenSaver
    /// Still above the menu bar and Dock, but level with pop-up menus, so the
    /// editor's own menus and input-method windows are not hidden behind it.
    private static let editingLevel = NSWindow.Level.popUpMenu

    var keyHandler: ((_ keyCode: Int64, _ command: Bool, _ isRepeat: Bool) -> Bool)?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Puts the overlay on the given display, covering it edge to edge,
    /// without taking focus or activating the app.
    func present(model: CaptureSessionModel, displayID: CGDirectDisplayID) {
        guard let screen = ScreenGeometry.screen(for: displayID) else { return }
        let panel = self.panel ?? OverlayPanel()
        self.panel = panel
        panel.keyHandler = { [weak self] event in
            self?.keyHandler?(Int64(event.keyCode), event.modifierFlags.contains(.command), event.isARepeat) ?? false
        }
        panel.allowsKey = false
        panel.ignoresMouseEvents = true
        panel.level = Self.coveringLevel

        let hosting = NSHostingView(rootView: OverlayRootView(model: model))
        // The view is laid out in screen coordinates: no safe-area insets
        // (the notch) and no say over the window's size.
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        panel.contentView = hosting
        panel.setFrame(screen.frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Once the capture has lifted, clicks on the backdrop stop here instead
    /// of reaching the windows underneath.
    func captureMouse() {
        panel?.ignoresMouseEvents = false
    }

    /// Gives the panel keyboard focus without activating the app.
    func takeKeyboard() {
        guard let panel else { return }
        panel.allowsKey = true
        panel.ignoresMouseEvents = false
        panel.level = Self.editingLevel
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        guard let panel else { return }
        panel.allowsKey = false
        panel.orderOut(nil)
        panel.contentView = nil
    }
}

/// A short message at the bottom of the screen for the moments a gesture
/// cannot be honoured: capture is off, or the screenshot failed.
@MainActor
final class NoticeController {

    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var lastShown = Date.distantPast

    func show(_ message: String, on screen: NSScreen? = nil, duration: TimeInterval = 2.2) {
        // An Option-drag in another app while capture is off should not
        // produce a stream of notices.
        guard Date().timeIntervalSince(lastShown) > 0.8 else { return }
        lastShown = Date()

        let screen = screen ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let screen else { return }

        let panel = self.panel ?? makePanel()
        self.panel = panel

        let hosting = NSHostingView(rootView: NoticeView(message: message))
        hosting.sizingOptions = []
        let size = hosting.fittingSize
        panel.contentView = hosting
        let origin = NSPoint(
            x: (screen.frame.midX - size.width / 2).rounded(),
            y: screen.visibleFrame.minY + 24)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Like the capture overlay, dark whatever the app's own appearance.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }
}

private struct NoticeView: View {
    let message: String

    var body: some View {
        Text(message)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(height: RecordingPill.height)
            .background { PillBackground() }
            .fixedSize()
    }
}
