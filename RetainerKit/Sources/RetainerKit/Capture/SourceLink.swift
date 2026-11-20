import AppKit
import ApplicationServices
import Foundation

/// A link back to what a capture was taken from: the page a browser window
/// was showing, or the file a document window had open.
///
/// It is read from the app in front through the Accessibility API, which
/// this app already holds permission for. Nothing is fetched and nothing
/// leaves the Mac: the link is only ever stored with the note and opened
/// when its card is clicked.
public enum SourceLink {

    // MARK: Looking it up

    /// The link for an app's front window, or `nil` if it has none worth
    /// keeping.
    ///
    /// This talks to the other app and waits for its answers, which a busy
    /// app can be slow to give, so it must not be called on the main thread.
    /// It gives up after `timeout` seconds in total.
    public static func lookUp(processID: pid_t, isBrowser: Bool, timeout: TimeInterval = 0.4) -> String? {
        guard AXIsProcessTrusted(), processID != ProcessInfo.processInfo.processIdentifier else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        let app = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(app, Float(timeout))

        guard let window = element(app, kAXFocusedWindowAttribute) ?? element(app, kAXMainWindowAttribute) else {
            return nil
        }
        // Document windows say which file they have open, and Safari and
        // Chrome say which page, as the window's document.
        if let link = accepted(string(window, kAXDocumentAttribute), fromBrowser: isBrowser) {
            return link
        }
        // Other browsers: the page is a web area somewhere inside the
        // window, and the web area carries its address.
        guard isBrowser else { return nil }
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 400, Date() < deadline {
            let (current, depth) = queue.removeFirst()
            visited += 1
            if string(current, kAXRoleAttribute) == "AXWebArea" {
                return accepted(string(current, "AXURL"), fromBrowser: true)
            }
            if depth < 12 {
                queue.append(contentsOf: children(of: current).map { ($0, depth + 1) })
            }
        }
        return nil
    }

    /// Whether an app is one the system would open web links with. Only
    /// those are believed about web addresses: many other apps are built
    /// from web pages and report an internal address that links to nothing.
    @MainActor
    public static func isBrowser(_ application: NSRunningApplication?) -> Bool {
        guard let bundle = application?.bundleURL?.standardizedFileURL,
            let example = URL(string: "https://example.com")
        else { return false }
        return NSWorkspace.shared.urlsForApplications(toOpen: example)
            .contains { $0.standardizedFileURL == bundle }
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func element(_ parent: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(parent, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        switch attribute(element, name) {
        case let text as String: text
        case let url as URL: url.absoluteString
        default: nil
        }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    // MARK: Deciding what to keep

    /// Turns what a window reports about itself into a link, or `nil` if it
    /// is not one a person could follow:
    ///
    /// - a web address, from a browser only;
    /// - a file, unless it is part of an app (apps built from web pages
    ///   report their own insides) or is not really a path.
    static func accepted(_ raw: String?, fromBrowser: Bool) -> String? {
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
            let url = URL(string: text), let scheme = url.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "http", "https":
            guard fromBrowser, let host = url.host, !host.isEmpty else { return nil }
            return url.absoluteString
        case "file":
            let path = url.path
            guard path.hasPrefix("/"), path.count > 1, !path.contains(".app/") else { return nil }
            return url.standardizedFileURL.absoluteString
        default:
            return nil
        }
    }

    // MARK: Showing it

    public static func isFile(_ link: String) -> Bool {
        URL(string: link)?.isFileURL ?? false
    }

    /// The link as shown on a card: a file as its path with the home folder
    /// shortened to `~`; a page as its address without the scheme, `www.`
    /// or a trailing slash.
    public static func displayText(for link: String) -> String {
        guard let url = URL(string: link) else { return link }
        if url.isFileURL {
            let path = url.path
            let home = NSHomeDirectory()
            if path == home { return "~" }
            return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
        }
        var text = link
        if let range = text.range(of: "://") { text = String(text[range.upperBound...]) }
        if text.hasPrefix("www.") { text = String(text.dropFirst(4)) }
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        return text.removingPercentEncoding ?? text
    }

    /// Opens the page in the default browser, or the file in its own app.
    /// Returns false if there was nothing to open (a file that has gone).
    @MainActor
    @discardableResult
    public static func open(_ link: String) -> Bool {
        guard let url = URL(string: link) else { return false }
        if url.isFileURL, !FileManager.default.fileExists(atPath: url.path) { return false }
        return NSWorkspace.shared.open(url)
    }

    /// Puts the link on the clipboard: a page's address, or a file's path.
    @MainActor
    public static func copy(_ link: String) {
        let text = isFile(link) ? (URL(string: link)?.path ?? link) : link
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Shows a file in the Finder.
    @MainActor
    public static func revealInFinder(_ link: String) {
        guard let url = URL(string: link), url.isFileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
