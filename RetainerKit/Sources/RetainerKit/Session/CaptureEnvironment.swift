import AppKit
import CoreGraphics
import Foundation

// The capture flow touches a global event tap, the screen, the microphone and
// a full-screen window. Each sits behind a small protocol here, so the flow
// itself (`CaptureCoordinator`) can be exercised end to end in tests with
// none of them present.

/// Control over the gesture recognizer from the main side.
protocol GestureControlling: AnyObject, Sendable {
    /// Switches interception on or off. While off, gestures are only observed.
    func setEnabled(_ enabled: Bool)
    /// The capture card has closed; a fresh press may start another capture.
    func sessionEnded()
    /// The card moved to the editor while the trigger is still held.
    func suspend()
    /// Compare the gesture in progress with the keys actually held down.
    func verifyActiveGesture()
    func stop()
}

extension EventTap: GestureControlling {}

protocol ScreenCapturing: Sendable {
    func prefetch() async
    func capture(rect: CGRect, displayID: CGDirectDisplayID) async throws -> CapturedImage
}

extension ScreenCapturer: ScreenCapturing {}

protocol AudioRecording: Sendable {
    var meter: LevelMeter { get }
    func start(sink: @escaping @Sendable ([Float]) -> Void) async throws
    @discardableResult func stop() async -> TimeInterval
}

extension AudioRecorder: AudioRecording {}

/// The window the capture is drawn in.
@MainActor
protocol OverlayPresenting: AnyObject {
    /// Sees key presses while the overlay has the keyboard, with whether each
    /// is the key repeating from being held. Returns true to swallow one.
    var keyHandler: ((_ keyCode: Int64, _ command: Bool, _ isRepeat: Bool) -> Bool)? { get set }
    func present(model: CaptureSessionModel, displayID: CGDirectDisplayID)
    /// Stop clicks on the backdrop from reaching the windows underneath.
    func captureMouse()
    /// Take keyboard focus without activating the app.
    func takeKeyboard()
    func dismiss()
}

/// What the overlay needs to know about the display it covers.
struct ScreenMetrics: Equatable {
    var size: CGSize
    /// Height of the Dock when it sits along the bottom of this display.
    var dockHeight: CGFloat
}

/// Everything outside the app that a capture depends on.
@MainActor
struct CaptureEnvironment {
    /// Installs the event tap. Returns `nil` when the system refuses.
    var makeGestureControl: (CaptureConfig, @escaping EventTap.ActionHandler) -> (any GestureControlling)?
    var capturer: any ScreenCapturing
    var makeRecorder: () -> any AudioRecording
    var overlay: any OverlayPresenting
    var screenMetrics: (CGDirectDisplayID) -> ScreenMetrics?
    /// The display to show something pasted or dropped on: the one the app's
    /// window is on.
    var mainDisplayID: () -> CGDirectDisplayID?
    var sourceContext: () -> SourceContext
    /// Finds a link to what the source app's front window is showing. Slow
    /// apps are slow to answer, so this runs to one side of the capture.
    var sourceLink: (SourceContext) async -> String?
    var frontmostApplication: () -> NSRunningApplication?
    var showNotice: (String) -> Void
    /// Permissions that have not been granted yet.
    var missingPermissions: () -> [Permission]
    var reportTapFailure: (Bool) -> Void
    /// A picture of the page a pasted link goes to, or `nil` if it cannot
    /// be had. The one thing here that loads anything from the network.
    var pageSnapshot: (URL) async -> CGImage? = { _ in nil }

    /// The real thing.
    static func live(permissions: PermissionsModel) -> CaptureEnvironment {
        let notices = NoticeController()
        return CaptureEnvironment(
            makeGestureControl: { config, handler in
                let tap = EventTap(config: config, onActions: handler)
                return tap.start() ? tap : nil
            },
            capturer: ScreenCapturer(),
            makeRecorder: { AudioRecorder() },
            overlay: OverlayController(),
            screenMetrics: { displayID in
                guard let screen = ScreenGeometry.screen(for: displayID) else { return nil }
                return ScreenMetrics(
                    size: screen.frame.size,
                    dockHeight: max(0, screen.visibleFrame.minY - screen.frame.minY))
            },
            mainDisplayID: {
                // A picture can be dragged in while another app is the active
                // one, and then this app has no key or main window to go by:
                // its board is still the window to follow.
                let window =
                    NSApp.keyWindow ?? NSApp.mainWindow
                    ?? NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain }
                let screen = window?.screen ?? NSScreen.main
                return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            },
            sourceContext: { SourceContext.current() },
            sourceLink: { source in
                guard let processID = source.processID else { return nil }
                let isBrowser = SourceLink.isBrowser(NSRunningApplication(processIdentifier: processID))
                return await Task.detached(priority: .userInitiated) {
                    SourceLink.lookUp(processID: processID, isBrowser: isBrowser)
                }.value
            },
            frontmostApplication: { NSWorkspace.shared.frontmostApplication },
            showNotice: { notices.show($0) },
            missingPermissions: { permissions.missing },
            reportTapFailure: { permissions.eventTapFailed = $0 },
            pageSnapshot: { await WebSnapshot.capture($0) })
    }
}
