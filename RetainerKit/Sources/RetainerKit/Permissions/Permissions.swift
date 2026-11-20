import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import Observation
import Speech

/// The four privacy permissions a capture needs.
public enum Permission: String, CaseIterable, Identifiable, Sendable {
    case microphone
    case speechRecognition
    case screenRecording
    case accessibility

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .speechRecognition: "Speech Recognition"
        case .screenRecording: "Screen Recording"
        case .accessibility: "Accessibility"
        }
    }

    /// One line on what the permission is used for.
    public var purpose: String {
        switch self {
        case .microphone: "Records what you say while Left Option is held."
        case .speechRecognition: "Turns the recording into text on this Mac."
        case .screenRecording: "Captures the rectangle you drag over."
        case .accessibility: "Watches for Left Option and the drag, system-wide."
        }
    }

    /// The System Settings pane where the permission is granted.
    public var settingsURL: URL {
        let anchor =
            switch self {
            case .microphone: "Privacy_Microphone"
            case .speechRecognition: "Privacy_SpeechRecognition"
            case .screenRecording: "Privacy_ScreenCapture"
            case .accessibility: "Privacy_Accessibility"
            }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

public enum PermissionStatus: Sendable, Equatable {
    case granted
    /// Never asked. Asking shows the system prompt.
    case notDetermined
    /// Asked and refused, or switched off. Only System Settings can change it.
    case denied

    public var label: String {
        switch self {
        case .granted: "granted"
        case .notDetermined: "not granted"
        case .denied: "denied"
        }
    }
}

/// Live status of the four permissions. `refresh()` is cheap and is polled
/// while the app runs, so the checklist updates as soon as a switch is
/// flipped in System Settings.
@MainActor
@Observable
public final class PermissionsModel {

    public private(set) var statuses: [Permission: PermissionStatus] = [:]

    /// Set when Accessibility is granted but the event tap still could not be
    /// installed, which points at Input Monitoring.
    public var eventTapFailed = false

    @ObservationIgnored private var requestedScreenRecording = false
    @ObservationIgnored private var requestedAccessibility = false

    public init() {
        refresh()
    }

    public func status(of permission: Permission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    public var allGranted: Bool {
        Permission.allCases.allSatisfy { status(of: $0) == .granted }
    }

    public var missing: [Permission] {
        Permission.allCases.filter { status(of: $0) != .granted }
    }

    public func refresh() {
        let current: [Permission: PermissionStatus] = [
            .microphone: Self.microphoneStatus(),
            .speechRecognition: Self.speechStatus(),
            .screenRecording: CGPreflightScreenCaptureAccess()
                ? .granted : (requestedScreenRecording ? .denied : .notDetermined),
            .accessibility: AXIsProcessTrusted()
                ? .granted : (requestedAccessibility ? .denied : .notDetermined),
        ]
        if current != statuses { statuses = current }
    }

    private static func microphoneStatus() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    private static func speechStatus() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// The completion handler given to the system's permission prompts.
    ///
    /// The system calls it on a background queue once the prompt is answered.
    /// It is made here, in a nonisolated function, and is `@Sendable`, so that
    /// it carries no main-actor isolation of its own. A closure written inline
    /// in `request(_:)` would inherit that isolation, and Swift 6 stops the
    /// process when such a closure runs off the main thread.
    nonisolated func promptAnswered<Answer>() -> @Sendable (Answer) -> Void {
        { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Asks for a permission. Where the system has a prompt and it has not
    /// been shown yet, that is used; otherwise the right System Settings pane
    /// is opened.
    public func request(_ permission: Permission) {
        switch permission {
        case .microphone:
            if status(of: .microphone) == .notDetermined {
                AVCaptureDevice.requestAccess(for: .audio, completionHandler: promptAnswered())
            } else {
                openSettings(for: permission)
            }
        case .speechRecognition:
            if status(of: .speechRecognition) == .notDetermined {
                SFSpeechRecognizer.requestAuthorization(promptAnswered())
            } else {
                openSettings(for: permission)
            }
        case .screenRecording:
            // Registers the app in the Screen Recording list and, the first
            // time, shows the system prompt. Returns immediately.
            let firstRequest = !requestedScreenRecording
            requestedScreenRecording = true
            let granted = CGRequestScreenCaptureAccess()
            if !granted && !firstRequest { openSettings(for: permission) }
            refresh()
        case .accessibility:
            // Adds the app to the Accessibility list and shows the system prompt.
            let firstRequest = !requestedAccessibility
            requestedAccessibility = true
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            if !trusted && !firstRequest { openSettings(for: permission) }
            refresh()
        }
    }

    public func openSettings(for permission: Permission) {
        NSWorkspace.shared.open(permission.settingsURL)
    }

    public func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The status word shown beside a permission. macOS only reports a
    /// definite "denied" for the microphone and speech recognition; for the
    /// other two all the app can know is that access has not been granted.
    public func statusLabel(for permission: Permission) -> String {
        let status = status(of: permission)
        switch permission {
        case .microphone, .speechRecognition:
            return status.label
        case .screenRecording, .accessibility:
            return status == .granted ? "granted" : "not granted"
        }
    }

    /// The label for a permission's button in the checklist.
    public func actionTitle(for permission: Permission) -> String {
        switch status(of: permission) {
        case .granted: "open settings"
        case .notDetermined: "grant"
        case .denied: "open settings"
        }
    }
}
