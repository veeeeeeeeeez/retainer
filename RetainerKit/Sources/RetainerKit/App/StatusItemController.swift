import AppKit

/// The controls that live in the menu bar: open the window, pick the engine,
/// toggle tidy, see permission status, quit.
///
/// The same menu is offered twice: from the menu bar item, and as the
/// "Capture" menu in the app's own menu bar. On a Mac whose menu bar is full,
/// macOS hides the newest items behind the display notch, and the engine and
/// tidy switches must not become unreachable when that happens.
@MainActor
final class CaptureMenu: NSObject, NSMenuDelegate {

    private let app: AppModel
    private let openWindow: () -> Void
    /// The menu bar item's copy also offers "Open Retainer" and "Quit".
    private let standalone: Bool

    init(app: AppModel, standalone: Bool, openWindow: @escaping () -> Void) {
        self.app = app
        self.standalone = standalone
        self.openWindow = openWindow
    }

    func makeMenu(title: String = "") -> NSMenu {
        let menu = NSMenu(title: title)
        menu.delegate = self
        menu.autoenablesItems = false
        return menu
    }

    /// Rebuilt each time it opens, so it always shows the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        app.refresh()
        menu.removeAllItems()

        if standalone {
            let unseen = app.unseenCount
            menu.addItem(
                item(unseen > 0 ? "Open Retainer  (\(unseen) new)" : "Open Retainer", action: #selector(openMainWindow)))
        }
        menu.addItem(info(app.captureStatus))
        menu.addItem(.separator())

        let missing = app.permissions.missing
        menu.addItem(
            info(missing.isEmpty ? "Permissions: all granted" : "Permissions: \(missing.count) missing"))
        for permission in Permission.allCases {
            let label = app.permissions.statusLabel(for: permission)
            let entry = item("\(permission.title)  (\(label))", action: #selector(openPermission(_:)))
            entry.representedObject = permission.rawValue
            entry.state = app.permissions.status(of: permission) == .granted ? .on : .off
            entry.indentationLevel = 1
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        menu.addItem(item("Settings…", action: #selector(openSettings)))

        if standalone {
            menu.addItem(.separator())
            let quit = item("Quit Retainer", action: #selector(quit))
            quit.keyEquivalent = "q"
            menu.addItem(quit)
        }
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    /// A disabled line of text: a heading or a status.
    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func openMainWindow() {
        openWindow()
    }

    /// The speech engine and the tidy pass are chosen in the settings and
    /// nowhere else; the menu only leads there.
    @objc private func openSettings() {
        openWindow()
        app.showsSettings = true
    }

    @objc private func openPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let permission = Permission(rawValue: raw) else {
            return
        }
        if app.permissions.status(of: permission) == .granted {
            app.permissions.openSettings(for: permission)
        } else {
            // Show the checklist too, so the remaining steps are visible.
            app.showChecklist()
            openWindow()
            app.permissions.request(permission)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// The item in the system menu bar.
@MainActor
final class StatusItemController {

    private let statusItem: NSStatusItem
    private let menu: CaptureMenu

    init(app: AppModel, openWindow: @escaping () -> Void) {
        menu = CaptureMenu(app: app, standalone: true, openWindow: openWindow)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.icon
        statusItem.button?.toolTip = "Retainer"
        statusItem.menu = menu.makeMenu()
    }

    /// A selection frame with a cursor inside it, drawn as a template so the
    /// menu bar tints it.
    static let icon: NSImage = {
        // AppKit may call a drawing handler on whatever thread draws the
        // image, so the handler must not be tied to the main actor.
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { @Sendable _ in
            drawIcon()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Retainer"
        return image
    }()

    private nonisolated static func drawIcon() {
        NSColor.black.setStroke()
        let frame = NSRect(x: 2.75, y: 3.75, width: 12.5, height: 10.5)
        let arm: CGFloat = 3.5
        let corners = NSBezierPath()
        corners.lineWidth = 1.5
        corners.lineCapStyle = .square
        for (x, dx) in [(frame.minX, arm), (frame.maxX, -arm)] {
            for (y, dy) in [(frame.minY, arm), (frame.maxY, -arm)] {
                corners.move(to: NSPoint(x: x + dx, y: y))
                corners.line(to: NSPoint(x: x, y: y))
                corners.line(to: NSPoint(x: x, y: y + dy))
            }
        }
        corners.stroke()
        NSColor.black.setFill()
        NSRect(x: 6.5, y: 6.5, width: 5, height: 1.5).fill()
    }
}
