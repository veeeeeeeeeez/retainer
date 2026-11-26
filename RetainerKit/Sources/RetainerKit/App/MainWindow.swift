import AppKit
import SwiftUI

/// The single window: the board of one period, with the timeline floating
/// over its top, a mini map in its top right-hand corner and a placeholder
/// input box over its bottom, a status bar
/// along the bottom, and over them the settings panel and (when anything is
/// missing) the permission checklist.
struct RootView: View {

    let app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                boardArea

                if app.showsSettings {
                    // A click anywhere else closes the panel.
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { app.showsSettings = false }
                    SettingsPanel(app: app) { app.showsSettings = false }
                        .padding(Theme.Space.m)
                        .transition(.opacity)
                }
            }
            StatusBar(app: app)
        }
        .background(Theme.background)
        .environment(app.store)
        .environment(app.canvas)
        .environment(app.images)
        .preferredColorScheme(app.settings.lightMode ? .light : .dark)
        .animation(.easeOut(duration: 0.12), value: app.showsSettings)
        .animation(.easeOut(duration: 0.12), value: app.search.isOpen)
        .animation(.easeOut(duration: 0.15), value: app.showsChecklist)
        .animation(.easeOut(duration: 0.12), value: app.canvas.viewingNoteID)
        .animation(.easeOut(duration: 0.12), value: app.canvas.expandedNoteID)
    }

    /// The board in front, and whatever is laid over it.
    private var boardArea: some View {
        ZStack {
            CanvasView(
                statusMessage: app.captureHint, showsEmptyState: !app.showsChecklist,
                onOpenDay: { day in
                    withAnimation(.easeOut(duration: 0.18)) { app.showDay(day) }
                },
                onDropPictures: { providers, point in
                    app.stageDropped(providers, at: point)
                }
            )
            .ignoresSafeArea()
            // Another period or canvas is another board: nothing is carried across.
            .id(app.canvas.board.id)

            if app.settings.miniMapStyle == .edges {
                // The window is the map: its own edges light up, over the
                // cards and under everything that floats above them.
                EdgeGlow()
                    .ignoresSafeArea()
            }

            if app.showsChecklist {
                PermissionsChecklist(app: app)
                    .transition(.opacity)
            }

            if app.canvas.showingArchive {
                ArchiveBanner(
                    count: app.store.notes(in: app.canvas.period, archived: true).count,
                    // Escape goes to whatever is open on top first.
                    escapeCloses: app.canvas.expandedNoteID == nil && app.canvas.viewingNoteID == nil
                        && !app.showsSettings
                ) {
                    app.setShowingArchive(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Under the timeline.
                .padding(.top, TopBar.clearance + 4)
                .transition(.opacity)
            }

            TopBar(app: app)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if app.settings.miniMapStyle != .edges {
                MiniMap()
                    .padding(.top, 8)
                    .padding(.trailing, MiniMap.edgeSpace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            InputBar(
                staging: app.staging, isDictating: app.coordinator.isDictating, meter: app.coordinator.dictationMeter,
                onMicrophone: { app.toggleDictation() }, onAttach: { app.attachFiles() })
                .frame(maxWidth: 720)
                .padding(.horizontal, 40)
                .padding(.bottom, Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if let group = app.canvas.groups(in: app.store).first(where: { $0.id == app.canvas.expandedGroupID }) {
                ExpandedGroupView(entry: group)
                    .ignoresSafeArea()
            }

            if let note = app.store.note(app.canvas.expandedNoteID) {
                ExpandedCardView(note: note)
                    .ignoresSafeArea()
            }

            if let note = app.store.note(app.canvas.viewingNoteID) {
                ImageViewer(note: note) {
                    withAnimation(.easeOut(duration: 0.12)) { app.canvas.viewingNoteID = nil }
                }
                .ignoresSafeArea()
            }

            if app.search.isOpen {
                SearchPanel(app: app)
                    .ignoresSafeArea()
            }
        }
    }
}

/// Says that the board is showing the archive, and how to get back.
private struct ArchiveBanner: View {

    let count: Int
    var escapeCloses = true
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Text(count == 1 ? "archive  ·  1 note" : "archive  ·  \(count) notes")
                .font(Theme.mono(11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Button("back to notes", action: onClose)
                .buttonStyle(FlatButtonStyle())
                .keyboardShortcut(escapeCloses ? .cancelAction : nil)
        }
        .padding(.leading, Theme.Space.m)
        .padding(.trailing, Theme.Space.xs)
        .frame(height: 32)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.hairlineStrong, lineWidth: Theme.hairlineWidth)
        }
    }
}

/// A single dense line along the bottom of the window.
private struct StatusBar: View {

    let app: AppModel

    var body: some View {
        HStack(spacing: Theme.Space.l) {
            Button {
                app.showsSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .regular))
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(QuietButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")

            Text(periodLabel)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
            Text(countLabel)
            if unseenCount > 0 && !app.canvas.showingArchive {
                // Takes you to the next card you have not looked at yet.
                Button {
                    withAnimation(.easeOut(duration: 0.25)) { app.showNextUnseen() }
                } label: {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.text).frame(width: 5, height: 5)
                        Text("\(unseenCount) new")
                    }
                    .foregroundStyle(Theme.text)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show the next note you have not seen yet")
            }
            if archivedCount > 0 || app.canvas.showingArchive {
                Button(app.canvas.showingArchive ? "back to notes" : "\(archivedCount) archived") {
                    app.setShowingArchive(!app.canvas.showingArchive)
                }
                .buttonStyle(QuietButtonStyle())
            }
            HStack(spacing: 4) {
                Text("\(Int((app.canvas.scale * 100).rounded()))%")
                    .monospacedDigit()
                // Back to the cards, however far the board has been scrolled
                // or zoomed.
                Button {
                    withAnimation(.easeOut(duration: 0.3)) { app.canvas.recenter(in: app.store) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(QuietButtonStyle())
                .help("Recenter: bring the cards back into view")
                .accessibilityLabel("Recenter")
            }

            if let error = app.store.loadError {
                Text(error).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }

            Spacer(minLength: Theme.Space.l)

            HStack(spacing: 2) {
                undoButton(
                    "arrow.uturn.backward", step: app.store.undoName, verb: "Undo", key: "⌘Z"
                ) { app.store.undoManager.undo() }
                undoButton(
                    "arrow.uturn.forward", step: app.store.redoName, verb: "Redo", key: "⇧⌘Z"
                ) { app.store.undoManager.redo() }
            }

            // This corner speaks only when capture is off and says why.
            // When everything is ready it says nothing; the engine and tidy
            // are in the settings.
            if isBlocked {
                if !app.permissions.allGranted && !app.showsChecklist {
                    Button(app.captureStatus) { app.showChecklist() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Text(app.captureStatus)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .font(Theme.mono(11))
        .foregroundStyle(Theme.textMuted)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .background(Theme.background)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
        }
    }

    /// Undo or redo, faint and inert when there is nothing to take back or
    /// do again. Its tip names the step: "Undo Delete Card  ⌘Z".
    private func undoButton(
        _ symbol: String, step: String?, verb: String, key: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 20, height: 18)
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(step == nil)
        .opacity(step == nil ? 0.35 : 1)
        .help(step.map { "\(verb) \($0)  \(key)" } ?? "Nothing to \(verb.lowercased())")
        .accessibilityLabel(step.map { "\(verb) \($0)" } ?? verb)
    }

    private var isBlocked: Bool {
        if case .blocked = app.coordinator.availability { return true }
        return false
    }

    /// New notes are counted everywhere, so none can be missed.
    private var unseenCount: Int { app.store.unseenNotes.count }
    /// A canvas has no archive of its own: archiving puts a note away on its day.
    private var archivedCount: Int {
        guard !app.canvas.board.isCanvas else { return 0 }
        return app.store.notes(in: app.canvas.period, archived: true).count
    }

    /// Which board is in front: "Today", "Monday 16 November", "This week",
    /// or a canvas by its project and name, "Thesis / Outline".
    private var periodLabel: String {
        if let canvas = app.store.canvas(app.canvas.canvasID) {
            let project = app.store.project(canvas.projectID)?.name ?? "Project"
            return "\(project)  /  \(canvas.name)"
        }
        let title = app.canvas.period.title(now: app.canvas.currentDate, calendar: app.store.calendar)
        return app.canvas.showingArchive ? "archive  ·  \(title)" : title
    }

    private var countLabel: String {
        let count = app.canvas.notes(in: app.store).count
        return count == 1 ? "1 note" : "\(count) notes"
    }
}

/// The first-launch checklist: four permissions with live status and a button
/// that requests each one or opens its pane in System Settings.
struct PermissionsChecklist: View {

    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("permissions")
                    .font(Theme.mono(11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("hide") { app.hideChecklist() }
                    .buttonStyle(QuietButtonStyle())
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(height: 36)

            rule

            ForEach(Permission.allCases) { permission in
                row(for: permission)
                rule
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Capture stays off until all four are granted.")
                    .font(Theme.noteFont(size: 14))
                    .foregroundStyle(Theme.text)

                if app.permissions.eventTapFailed && app.permissions.status(of: .accessibility) == .granted {
                    HStack(alignment: .firstTextBaseline) {
                        Text("The keyboard and mouse tap could not be installed. Enable Retainer under Input Monitoring as well.")
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Theme.Space.m)
                        Button("open settings") { app.permissions.openInputMonitoringSettings() }
                            .buttonStyle(FlatButtonStyle())
                    }
                }

                HStack(alignment: .firstTextBaseline) {
                    Text("Screen Recording takes effect after a relaunch.")
                    Spacer(minLength: Theme.Space.m)
                    if app.canRelaunch {
                        Button("relaunch") { app.relaunch() }
                            .buttonStyle(FlatButtonStyle())
                    }
                }

                Text("speech model: \(app.engines.selectedState.summary)")
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.textMuted)
            .padding(Theme.Space.l)
        }
        .frame(width: 640)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius)
                .strokeBorder(Theme.hairline, lineWidth: Theme.hairlineWidth)
        }
    }

    private var rule: some View {
        Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
    }

    private func row(for permission: Permission) -> some View {
        let status = app.permissions.status(of: permission)
        let granted = status == .granted
        return HStack(alignment: .center, spacing: Theme.Space.m) {
            // Filled when granted, hollow when not. No colour: state is carried by shape and words.
            Rectangle()
                .fill(granted ? Theme.text : Color.clear)
                .overlay { Rectangle().strokeBorder(granted ? Theme.text : Theme.textMuted, lineWidth: 1) }
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title)
                    .font(Theme.mono(12, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(permission.purpose)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(app.permissions.statusLabel(for: permission))
                .font(Theme.mono(11))
                .foregroundStyle(granted ? Theme.textMuted : Theme.text)
                .frame(width: 84, alignment: .trailing)

            Button {
                if granted {
                    app.permissions.openSettings(for: permission)
                } else {
                    app.permissions.request(permission)
                }
            } label: {
                Text(app.permissions.actionTitle(for: permission))
                    .frame(width: 92)
            }
            .buttonStyle(FlatButtonStyle())
        }
        .padding(.horizontal, Theme.Space.l)
        .frame(height: 56)
        .accessibilityElement(children: .combine)
    }
}

/// Creates and owns the main window.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {

    private let window: NSWindow
    private let store: NoteStore

    init(app: AppModel) {
        store = app.store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        super.init()

        window.title = "Retainer"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.nsBackground
        window.appearance = Self.appearance(light: app.settings.lightMode)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.tabbingMode = .disallowed
        window.delegate = self

        let hosting = NSHostingView(rootView: GateView(app: app))
        hosting.sizingOptions = []
        window.contentView = hosting

        window.center()
        // Remembers size and position between launches. The name is from
        // when the app was called Terminal, and is kept so the window stays
        // where it was left.
        window.setFrameAutosaveName("TerminalMainWindow")
    }

    /// Edit › Undo and Redo in this window take back steps on the board.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        store.undoManager
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    static func appearance(light: Bool) -> NSAppearance? {
        NSAppearance(named: light ? .aqua : .darkAqua)
    }

    /// Switches the window between the dark and the light palette.
    func applyAppearance(light: Bool) {
        window.appearance = Self.appearance(light: light)
        window.backgroundColor = Theme.nsBackground
    }

    var isVisible: Bool { window.isVisible }
}
