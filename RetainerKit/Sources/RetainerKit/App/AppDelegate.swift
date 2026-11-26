import AppKit
import SwiftUI

/// Entry point for both the Xcode app target and the SwiftPM executable.
public enum RetainerApplication {

    @MainActor
    public static func main() {
        // Developer switches (offscreen renders, engine self-tests) run
        // without starting the app.
        if DevTools.runIfRequested(arguments: CommandLine.arguments) { return }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        // `run` never returns; the delegate lives for the life of the process.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {

    private var app: AppModel?
    private var windowController: MainWindowController?
    private var statusItem: StatusItemController?
    private var captureMenu: CaptureMenu?
    private var refreshTimer: Timer?
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitCleanlyOnTerminationSignals()

        let app = AppModel()
        self.app = app
        // Dark unless light mode is switched on in the settings. Menus and
        // the window follow; the capture overlay keeps its own dark windows.
        NSApp.appearance = MainWindowController.appearance(light: app.settings.lightMode)
        let windowController = MainWindowController(app: app)
        self.windowController = windowController
        app.settings.onLightModeChange = { [weak self] light in
            NSApp.appearance = MainWindowController.appearance(light: light)
            self?.windowController?.applyAppearance(light: light)
        }
        statusItem = StatusItemController(app: app) { [weak self] in self?.showWindow() }
        // The same controls again in the app's own menu bar, for when the
        // menu bar item is hidden behind the notch.
        let captureMenu = CaptureMenu(app: app, standalone: false) { [weak self] in self?.showWindow() }
        self.captureMenu = captureMenu
        NSApp.mainMenu = makeMainMenu(capture: captureMenu.makeMenu(title: "Capture"))

        app.start()
        // Permission switches are flipped in System Settings, outside the
        // app; polling is the only way to follow them live.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.app?.refresh()
                self?.updateDockBadge()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        showWindow()
    }

    private func showWindow() {
        windowController?.show()
    }

    /// The Dock icon carries the number of notes saved but not yet looked at.
    private func updateDockBadge() {
        let count = app?.unseenCount ?? 0
        let label = count > 0 ? String(count) : nil
        if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
    }

    /// Treats SIGTERM and SIGINT as a request to quit, not a kill.
    ///
    /// By default either signal ends the process on the spot, skipping
    /// `applicationWillTerminate` and with it the last write of the note
    /// index. `scripts/run.sh` stops the app this way, as does `kill`.
    private func quitCleanlyOnTerminationSignals() {
        for number in [SIGTERM, SIGINT] {
            // Ignore the default action so the dispatch source receives it instead.
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Closing the window leaves the app running: capture lives in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        app?.coordinator.shutdown()
        app?.store.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    // MARK: Main menu

    private func makeMainMenu(capture: NSMenu) -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Retainer", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(target(self, "Settings…", #selector(showSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Retainer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Retainer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu(appMenu, title: "Retainer"))

        // The Edit menu is what gives text fields their standard shortcuts.
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(target(self, "Search…", #selector(showSearch), "k"))
        // ⌘F does the same, without a second line in the menu.
        let find = target(self, "Find…", #selector(showSearch), "f")
        find.isHidden = true
        find.allowsKeyEquivalentWhenHidden = true
        edit.addItem(find)
        main.addItem(submenu(edit, title: "Edit"))

        let view = NSMenu(title: "View")
        // What the bar at the top shows.
        view.addItem(target(self, "Show Timeline", #selector(showTimeline), "5"))
        view.addItem(target(self, "Show Projects", #selector(showProjects), "6"))
        let newProject = target(self, "New Project", #selector(newProject), "n")
        newProject.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(newProject)
        view.addItem(target(self, "New Canvas", #selector(newCanvas), "n"))
        view.addItem(.separator())
        view.addItem(target(self, "Recenter", #selector(recenter), "9"))
        view.addItem(target(self, "Actual Size", #selector(zoomActualSize), "0"))
        view.addItem(target(self, "Zoom In", #selector(zoomIn), "="))
        view.addItem(target(self, "Zoom Out", #selector(zoomOut), "-"))
        view.addItem(.separator())
        // How much time one board covers.
        for (index, scale) in TimeScale.allCases.enumerated() {
            let titles: [TimeScale: String] = [.day: "Day", .week: "Week", .month: "Month", .all: "All Time"]
            let item = target(self, titles[scale] ?? scale.title, #selector(chooseTimeScale(_:)), "\(index + 1)")
            item.representedObject = scale.rawValue
            view.addItem(item)
        }
        view.addItem(.separator())
        view.addItem(target(self, "Today", #selector(showPresent), "t"))
        view.addItem(target(self, "Earlier", #selector(showEarlier), "["))
        view.addItem(target(self, "Later", #selector(showLater), "]"))
        view.addItem(target(self, "Next New Note", #selector(showNextNewNote), "j"))
        let archive = target(self, "Show Archive", #selector(toggleArchive), "a")
        archive.keyEquivalentModifierMask = [.command, .shift]
        view.addItem(archive)
        main.addItem(submenu(view, title: "View"))
        main.addItem(submenu(capture, title: "Capture"))

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(.separator())
        window.addItem(target(self, "Board", #selector(showCanvas), ""))
        main.addItem(submenu(window, title: "Window"))
        NSApp.windowsMenu = window

        return main
    }

    private func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func target(_ target: AnyObject, _ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @objc private func showCanvas() {
        showWindow()
    }

    @objc private func chooseTimeScale(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let scale = TimeScale(rawValue: raw) else { return }
        showWindow()
        withAnimation(.easeOut(duration: 0.18)) { app?.setTimeScale(scale) }
    }

    @objc private func showPresent() {
        showWindow()
        withAnimation(.easeOut(duration: 0.18)) { app?.showPresent() }
    }

    @objc private func showTimeline() {
        showWindow()
        withAnimation(.easeOut(duration: 0.18)) { app?.setMode(.timeline) }
    }

    @objc private func showProjects() {
        showWindow()
        withAnimation(.easeOut(duration: 0.18)) { app?.setMode(.projects) }
    }

    @objc private func newProject() {
        showWindow()
        withAnimation(.easeOut(duration: 0.18)) { _ = app?.navigation.newProject() }
    }

    @objc private func newCanvas() {
        showWindow()
        withAnimation(.easeOut(duration: 0.18)) { _ = app?.navigation.newCanvas() }
    }

    @objc private func showEarlier() {
        withAnimation(.easeOut(duration: 0.18)) { app?.step(by: -1) }
    }

    @objc private func showLater() {
        withAnimation(.easeOut(duration: 0.18)) { app?.step(by: 1) }
    }

    @objc private func showSettings() {
        showWindow()
        app?.showsSettings = true
    }

    @objc private func showSearch() {
        showWindow()
        app?.toggleSearch()
    }

    @objc private func showNextNewNote() {
        showWindow()
        withAnimation(.easeOut(duration: 0.25)) { app?.showNextUnseen() }
    }

    @objc private func toggleArchive() {
        guard let app else { return }
        showWindow()
        app.setShowingArchive(!app.canvas.showingArchive)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showNextNewNote):
            return (app?.unseenCount ?? 0) > 0
        case #selector(showTimeline):
            menuItem.state = app?.navigation.mode == .timeline ? .on : .off
            return true
        case #selector(showProjects):
            menuItem.state = app?.navigation.mode == .projects ? .on : .off
            return true
        case #selector(newCanvas):
            // A canvas goes in a project: one has to be open.
            return app?.navigation.projectForNewCanvas != nil
        case #selector(toggleArchive):
            menuItem.title = app?.canvas.showingArchive == true ? "Show Notes" : "Show Archive"
            // A canvas has no archive of its own.
            return app?.canvas.board.isCanvas != true
        case #selector(chooseTimeScale(_:)):
            let chosen = (menuItem.representedObject as? String) == app?.canvas.timeScale.rawValue
            menuItem.state = chosen ? .on : .off
            return true
        case #selector(showEarlier), #selector(showLater):
            // Earlier and later are along the timeline, not among canvases.
            return app?.canvas.timeScale != .all && app?.canvas.board.isCanvas != true
        case #selector(showPresent):
            return app?.canvas.timeScale != .all || app?.canvas.board.isCanvas == true
        default:
            return true
        }
    }

    private var viewCentre: CGPoint {
        let size = app?.canvas.viewSize ?? .zero
        return CGPoint(x: size.width / 2, y: size.height / 2)
    }

    @objc private func recenter() {
        guard let app else { return }
        showWindow()
        withAnimation(.easeOut(duration: 0.3)) { app.canvas.recenter(in: app.store) }
    }

    @objc private func zoomActualSize() {
        withAnimation(.easeOut(duration: 0.18)) { app?.canvas.resetZoom() }
    }

    @objc private func zoomIn() {
        withAnimation(.easeOut(duration: 0.18)) { app?.canvas.zoom(by: 1.25, around: viewCentre) }
    }

    @objc private func zoomOut() {
        withAnimation(.easeOut(duration: 0.18)) { app?.canvas.zoom(by: 0.8, around: viewCentre) }
    }
}
