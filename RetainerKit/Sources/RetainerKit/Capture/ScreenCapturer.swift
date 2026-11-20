import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

/// A screenshot of the selected rectangle at the display's native resolution.
public struct CapturedImage: @unchecked Sendable {
    public let cgImage: CGImage
    /// Pixels per point of the display it was taken from.
    public let scale: CGFloat

    public init(cgImage: CGImage, scale: CGFloat) {
        self.cgImage = cgImage
        self.scale = scale
    }

    public var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    public var pointSize: CGSize { CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale) }
}

public enum ScreenCaptureError: LocalizedError {
    case displayNotFound
    case emptySelection

    public var errorDescription: String? {
        switch self {
        case .displayNotFound: "The display the selection was made on is no longer available."
        case .emptySelection: "The selection is empty."
        }
    }
}

/// Captures a rectangle of one display with ScreenCaptureKit, leaving this
/// app's own windows (the selection overlay, the canvas) out of the picture.
public actor ScreenCapturer {

    private var cachedContent: SCShareableContent?
    private var cachedAt = Date.distantPast
    private var inFlight: Task<SCShareableContent, any Error>?
    private let ownProcessID = ProcessInfo.processInfo.processIdentifier

    public init() {}

    /// Fetches the list of shareable displays and apps ahead of time, so the
    /// capture at mouse-up does not have to wait for it. Call once the overlay
    /// is on screen: that guarantees this app appears in the list.
    public func prefetch() async {
        _ = try? await content(maxAge: 0)
    }

    /// - Parameters:
    ///   - rect: The selection in points, relative to the display's top-left corner.
    ///   - displayID: The display the drag started on.
    public func capture(rect: CGRect, displayID: CGDirectDisplayID) async throws -> CapturedImage {
        guard rect.width >= 1, rect.height >= 1 else { throw ScreenCaptureError.emptySelection }

        var content = try await content(maxAge: 10)
        if ownApplication(in: content) == nil {
            // Fetched before any of our windows existed; look again.
            content = try await self.content(maxAge: 0)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let filter: SCContentFilter
        if let own = ownApplication(in: content) {
            filter = SCContentFilter(display: display, excludingApplications: [own], exceptingWindows: [])
        } else {
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownProcessID }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        }

        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rect
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedImage(cgImage: image, scale: scale)
    }

    private func ownApplication(in content: SCShareableContent) -> SCRunningApplication? {
        content.applications.first { $0.processID == ownProcessID }
    }

    private func content(maxAge: TimeInterval) async throws -> SCShareableContent {
        if let cachedContent, Date().timeIntervalSince(cachedAt) < maxAge {
            return cachedContent
        }
        // A capture that arrives while the prefetch is still running waits
        // for it instead of asking the system twice.
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        inFlight = task
        defer { inFlight = nil }
        let fresh = try await task.value
        cachedContent = fresh
        cachedAt = Date()
        return fresh
    }
}

/// Where a capture came from: the app in front and the title of its window.
public struct SourceContext: Sendable, Equatable {
    public var appName: String?
    public var windowTitle: String?
    public var processID: pid_t?

    public init(appName: String? = nil, windowTitle: String? = nil, processID: pid_t? = nil) {
        self.appName = appName
        self.windowTitle = windowTitle
        self.processID = processID
    }

    /// Reads the frontmost app and the title of its frontmost window.
    ///
    /// The title comes from the window list rather than the Accessibility API
    /// so that an unresponsive app can never stall the gesture. Window names
    /// are only visible once Screen Recording has been granted.
    @MainActor
    public static func current() -> SourceContext {
        guard let app = NSWorkspace.shared.frontmostApplication else { return SourceContext() }
        let pid = app.processIdentifier
        var title: String?
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        if let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] {
            // The list is ordered front to back; take the app's first normal window.
            for window in windows {
                guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                    (window[kCGWindowLayer as String] as? Int) == 0
                else { continue }
                let name = (window[kCGWindowName as String] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let name, !name.isEmpty { title = name }
                break
            }
        }
        return SourceContext(appName: app.localizedName, windowTitle: title, processID: pid)
    }
}

/// Conversions between the three coordinate spaces the capture touches.
public enum ScreenGeometry {

    /// The `NSScreen` backing a Core Graphics display.
    @MainActor
    public static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return number?.uint32Value == displayID
        }
    }

    /// Converts a rect from global display coordinates (top-left origin) to
    /// coordinates relative to its display's top-left corner. This is the
    /// space ScreenCaptureKit's `sourceRect` and the overlay's SwiftUI layout share.
    public static func localRect(_ global: CGRect, in displayBounds: CGRect) -> CGRect {
        global.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
    }

    /// The largest size with `size`'s aspect ratio that fits `bounds` without
    /// being scaled up.
    public static func fit(_ size: CGSize, within bounds: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        let factor = min(1, bounds.width / size.width, bounds.height / size.height)
        return CGSize(width: (size.width * factor).rounded(), height: (size.height * factor).rounded())
    }
}
