import AppKit
import Foundation
import Observation

/// The app's long-lived objects, created once at launch and shared by the
/// window, the menu bar item and the capture flow.
@MainActor
@Observable
public final class AppModel {

    public let config: CaptureConfig
    public let settings: AppSettings
    public let permissions: PermissionsModel
    public let engines: EngineManager
    public let store: NoteStore
    public let images: ImageCache
    public let canvas: CanvasModel
    public let tidy: TidyService
    public let coordinator: CaptureCoordinator
    /// Links and pictures pasted into the input box, waiting to be spoken about.
    public let staging = StagingModel()
    /// What the bar at the top is showing: the timeline, or the projects.
    public let navigation: Navigation
    /// The words in each note's picture, read in the background.
    public let pictureText: PictureText
    /// The search box.
    public let search = SearchModel()
    /// Who is signed in.
    public let account: Account
    /// Cloud mode: the notes kept the same here and in the account's cloud copy.
    public let cloud: CloudSync

    /// Whether the on-device language model can be used for tidying.
    public private(set) var tidyAvailability: TidyAvailability = .unavailable("checking")

    /// Whether the settings panel is open over the canvas.
    public var showsSettings = false


    /// The checklist was hidden by hand. It comes back if what is missing changes.
    private var checklistHiddenFor: [Permission]?

    @ObservationIgnored private var refreshCount = 0

    public init(
        config: CaptureConfig = .standard, defaults: UserDefaults = .standard, storeDirectory: URL? = nil,
        cloudService: any CloudService = SupabaseService()
    ) {
        self.config = config
        settings = AppSettings(defaults: defaults)
        permissions = PermissionsModel()
        engines = EngineManager(defaults: defaults)
        store = NoteStore(directory: storeDirectory ?? NoteStore.defaultDirectory)
        images = ImageCache()
        canvas = CanvasModel(defaults: defaults, calendar: store.calendar)
        tidy = TidyService(config: config)
        navigation = Navigation(store: store, canvas: canvas)
        pictureText = PictureText(directory: store.directory)
        account = Account(directory: store.directory, service: cloudService, defaults: defaults)
        cloud = CloudSync(store: store, account: account, service: cloudService, defaults: defaults)
        coordinator = CaptureCoordinator(
            config: config, engines: engines, settings: settings, store: store, images: images,
            canvas: canvas, permissions: permissions, tidy: tidy)
        engines.onChange = { [weak self] in self?.coordinator.sync() }
        settings.onSampleDaysChange = { [weak self] _ in self?.applySampleDays() }
        staging.onSubmit = { [weak self] items in self?.coordinator.stage(items) }
        staging.onSave = { [weak self] text, items in self?.coordinator.saveDirectly(items, text: text) }
        search.documents = { [weak self] in self?.searchDocuments() ?? [] }
        store.onChange = { [weak self] in self?.cloud.storeChanged() }
        cloud.onPictureChange = { [weak self] id in self?.images.remove(id) }
        // Nothing is captured until someone is signed in.
        coordinator.isLocked = !account.isSignedIn
        account.onChange = { [weak self] in
            guard let self else { return }
            self.coordinator.isLocked = !self.account.isSignedIn
            self.coordinator.sync()
            if !self.account.isSignedIn { self.showsSettings = false }
        }
    }

    // MARK: Search

    /// Every note as search sees it, with what has been read of its picture.
    public func searchDocuments() -> [SearchDocument] {
        store.allNotes.map { SearchDocument($0, picture: pictureText.text(for: $0)) }
    }

    /// Opens the search box, or closes it if it is open.
    public func toggleSearch() {
        if search.isOpen { search.close() } else { search.open() }
    }

    /// Return in the search box: goes to the chosen note and opens it.
    public func openChosenSearchHit() {
        guard let id = search.chosen else { return }
        search.close()
        showsSettings = false
        canvas.show(id, in: store)
        // It went to the note's day, unless the note was on the canvas in front.
        if !canvas.board.isCanvas { navigation.timelineUsed() }
    }

    /// What was in the input box before dictation began: what is said is added after it.
    @ObservationIgnored private var dictatedAfter = ""

    /// The microphone button in the input box: starts dictating into the
    /// box, or stops and leaves what was said there (tidied, if tidy is on).
    public func toggleDictation() {
        if coordinator.isDictating {
            Task {
                if let said = await coordinator.stopDictation() { staging.text = dictatedAfter + said }
            }
            return
        }
        let before = staging.text.trimmingCharacters(in: .whitespacesAndNewlines)
        dictatedAfter = before.isEmpty ? "" : before + " "
        let started = coordinator.startDictation { [weak self] heard in
            guard let self, self.coordinator.isDictating else { return }
            self.staging.text = self.dictatedAfter + heard
        }
        if !started { staging.say("the speech engine is not ready yet") }
    }

    /// The paperclip in the input box: choose files to put in. Pictures go
    /// in as pictures; anything else by its preview, with its path kept so
    /// the card leads back to the file.
    public func attachFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            var items: [StagedItem] = []
            for url in urls {
                if let item = await StagedItem.file(at: url) { items.append(item) }
            }
            if items.isEmpty { staging.say("that could not be attached") } else { staging.add(items) }
        }
    }

    /// Takes pictures dropped on the board straight on to be spoken about.
    /// `point` is where on the board they were dropped: the first goes
    /// there, the rest beside it.
    func stageDropped(_ providers: [NSItemProvider], at point: CGPoint) {
        Task {
            var pictures = await StagedItem.pictures(from: providers)
            guard !pictures.isEmpty else {
                staging.say("only pictures can be dropped on the board")
                return
            }
            for index in pictures.indices { pictures[index].boardPoint = point }
            coordinator.stage(pictures)
        }
    }

    /// Starts loading the speech model and brings capture state up to date.
    public func start() {
        engines.prepareSelected()
        applySampleDays()
        refresh()
    }

    /// Re-reads permission status and re-evaluates whether capture is on.
    /// Called about once a second so the UI follows System Settings live.
    public func refresh() {
        permissions.refresh()
        engines.retrySelectedIfFailed()
        coordinator.sync()
        cloud.tick()
        // Saved notes only: a made-up note's picture says nothing.
        let unread = pictureText.remaining
        pictureText.catchUp(with: store.notes) { store.imageURL(for: $0) }
        if unread > 0, pictureText.remaining == 0 { search.refresh() }
        if refreshCount % 5 == 0 {
            Task {
                let availability = await tidy.availability()
                if availability != tidyAvailability { tidyAvailability = availability }
            }
        }
        refreshCount += 1
    }

    // MARK: Checklist visibility

    public var showsChecklist: Bool {
        let missing = permissions.missing
        return !missing.isEmpty && checklistHiddenFor != missing
    }

    public func hideChecklist() {
        checklistHiddenFor = permissions.missing
    }

    public func showChecklist() {
        checklistHiddenFor = nil
    }

    // MARK: The bar at the top

    /// Switches the bar between the timeline and the projects.
    public func setMode(_ mode: Navigation.Mode) {
        navigation.setMode(mode)
    }

    // MARK: The timeline

    /// Puts a period's board on screen.
    public func select(_ period: Period) {
        navigation.timelineUsed()
        canvas.show(period)
    }

    /// Opens the board of one day.
    public func showDay(_ day: Date) {
        navigation.timelineUsed()
        canvas.show(Period.containing(day, scale: .day, calendar: store.calendar))
    }

    /// Switches between day, week, month and all time, staying with the
    /// stretch of time being looked at: the present if it is in view,
    /// otherwise the newest note of the period on screen.
    public func setTimeScale(_ scale: TimeScale) {
        // From a canvas, any scale is a change: back to the timeline at it.
        guard scale != canvas.timeScale || canvas.board.isCanvas else { return }
        navigation.timelineUsed()
        let now = canvas.currentDate
        var anchor = now
        if canvas.period.scale != .all, !canvas.period.contains(now) {
            anchor = store.notes(in: canvas.period).last?.timestamp ?? canvas.period.start
        }
        canvas.show(Period.containing(anchor, scale: scale, calendar: store.calendar))
    }

    /// Back to the present: today, this week or this month.
    public func showPresent() {
        navigation.timelineUsed()
        canvas.show(Period.containing(canvas.currentDate, scale: canvas.timeScale, calendar: store.calendar))
    }

    /// Moves along the timeline to the next period that has notes: earlier
    /// with a negative count, later with a positive one.
    public func step(by count: Int) {
        navigation.timelineUsed()
        let entries = Timeline.entries(
            notes: store.allNotes, scale: canvas.timeScale, now: canvas.currentDate, calendar: store.calendar)
        guard let index = entries.firstIndex(where: { $0.period == canvas.period }) else {
            // The period on screen has nothing in it: go to the nearest that has.
            let target = count < 0
                ? entries.last { $0.period.start < canvas.period.start }
                : entries.first { $0.period.start > canvas.period.start }
            if let target { canvas.show(target.period) }
            return
        }
        let target = min(max(index + count, 0), entries.count - 1)
        canvas.show(entries[target].period)
    }

    /// Fills the timeline with made-up past days, or clears them out.
    public func applySampleDays() {
        if settings.sampleDays {
            Task { await SampleDays.install(in: store, now: canvas.currentDate) }
        } else {
            if let open = canvas.expandedNoteID, store.isSample(open) { canvas.collapse() }
            SampleDays.remove(from: store)
        }
    }

    // MARK: Notes

    /// How many saved notes have not been looked at in the window yet.
    public var unseenCount: Int { store.unseenNotes.count }

    /// Scrolls the canvas to the next note that has not been looked at.
    public func showNextUnseen() {
        canvas.showNextUnseen(in: store)
        // It went to the note's day, unless the note was on the canvas in front.
        if !canvas.board.isCanvas { navigation.timelineUsed() }
    }

    /// Switches the canvas between the notes and the archive.
    public func setShowingArchive(_ showing: Bool) {
        // A canvas has no archive of its own.
        guard !canvas.board.isCanvas || !showing else { return }
        canvas.showingArchive = showing
    }

    // MARK: Status text

    /// One line describing whether capture is on, for the status bar.
    public var captureStatus: String {
        switch coordinator.availability {
        case .ready:
            // Which engine and whether tidy is on are in the settings.
            return "ready"
        case .blocked(let reason):
            return "capture off: \(reason)"
        }
    }

    /// A sentence for the empty canvas while capture is unavailable.
    public var captureHint: String? {
        switch coordinator.availability {
        case .ready:
            return nil
        case .blocked:
            if !permissions.allGranted {
                return "Capture is off until the missing permissions are granted. See the status bar below."
            }
            if case .downloading(let fraction) = engines.selectedState {
                return "Downloading the speech model (\(Int((fraction * 100).rounded()))%). Capture turns on when it finishes."
            }
            if case .failed(let message) = engines.selectedState {
                return "The speech model could not be loaded: \(message)"
            }
            return "Capture is getting ready."
        }
    }

    // MARK: Relaunch

    /// Whether the app is running from an app bundle (as opposed to a bare binary).
    public var canRelaunch: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Quits and starts again. Screen Recording is only picked up by a fresh process.
    ///
    /// Only one copy of the app may run at a time, so the new one cannot be
    /// started from here while this one is alive. A small shell process waits
    /// for this one to exit and then opens the bundle through LaunchServices.
    public func relaunch() {
        guard canRelaunch else { return }
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            #"while kill -0 "$0" 2>/dev/null; do sleep 0.1; done; exec /usr/bin/open "$1""#,
            String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path,
        ]
        do {
            try waiter.run()
        } catch {
            // Without the waiter, quitting would simply leave the app closed.
            return
        }
        NSApp.terminate(nil)
    }
}
