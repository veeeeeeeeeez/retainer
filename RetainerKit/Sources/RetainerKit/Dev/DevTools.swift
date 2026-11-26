import AppKit
import FluidAudio
import SwiftUI

/// Command-line switches for checking parts of the app without a full
/// interactive session. None of them install the event tap or ask for a
/// permission.
///
/// ```
/// Retainer --snapshot <directory>      render the main screens to PNG files
///          [--scale 1|2]               pixels per point (default 2)
/// Retainer --maps <directory>          render the mini map alone, in each of
///          [--scale 1|2|3|4]           its states (default 3)
/// Retainer --edges <directory>         render a wide window with the cards
///          [--scale 1|2]               out of view each way (default 1)
/// Retainer --search "<query>"          search the real notes and print what
///          [--words]                   is found (by words only with --words)
/// Retainer --read <picture>            print the text read from a picture
/// Retainer --set-search-key            keep the key given on standard input
/// Retainer --transcribe <audio file>   run an engine over a recording
///          [--engine parakeet-tdt-v2|apple-speechanalyzer] [--realtime]
/// Retainer --tidy "<text>"             run the tidy pass on some text
/// Retainer --glass <picture> <output>  draw the selection glass over a picture
///          [--rect x,y,width,height] [--scale 1|2]
/// Retainer --source-link <bundle id>   print the link a capture of that app's
///                                      front window would be saved with
/// ```
enum DevTools {

    @MainActor
    static func runIfRequested(arguments: [String]) -> Bool {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }

        if let directory = value(after: "--snapshot") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.appearance = NSAppearance(named: .darkAqua)
            do {
                Snapshots.pixelsPerPoint = value(after: "--scale").flatMap(Int.init) ?? 2
                try Snapshots.renderAll(to: URL(fileURLWithPath: directory, isDirectory: true))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }

        if let directory = value(after: "--maps") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.appearance = NSAppearance(named: .darkAqua)
            do {
                Snapshots.pixelsPerPoint = value(after: "--scale").flatMap(Int.init) ?? 3
                try Snapshots.renderMaps(to: URL(fileURLWithPath: directory, isDirectory: true))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("map render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        if let directory = value(after: "--edges") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.appearance = NSAppearance(named: .darkAqua)
            do {
                Snapshots.pixelsPerPoint = value(after: "--scale").flatMap(Int.init) ?? 1
                try Snapshots.renderEdges(to: URL(fileURLWithPath: directory, isDirectory: true))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("edge render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        if let directory = value(after: "--motion") {
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.appearance = NSAppearance(named: .darkAqua)
            do {
                try Snapshots.renderMotion(to: URL(fileURLWithPath: directory, isDirectory: true))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("motion check failed: \(error)\n".utf8))
                exit(1)
            }
        }

        if let index = arguments.firstIndex(of: "--glass") {
            guard index + 2 < arguments.count else {
                FileHandle.standardError.write(Data("usage: --glass <picture> <output.png> [--rect x,y,width,height] [--scale 1|2]\n".utf8))
                exit(2)
            }
            let application = NSApplication.shared
            application.setActivationPolicy(.prohibited)
            application.appearance = NSAppearance(named: .darkAqua)
            let numbers = (value(after: "--rect") ?? "").split(separator: ",").compactMap { Double($0) }
            let rect = numbers.count == 4
                ? CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3]) : nil
            do {
                Snapshots.pixelsPerPoint = value(after: "--scale").flatMap(Int.init) ?? 2
                try Snapshots.renderGlass(
                    over: URL(fileURLWithPath: arguments[index + 1]), rect: rect,
                    to: URL(fileURLWithPath: arguments[index + 2]))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("glass render failed: \(error)\n".utf8))
                exit(1)
            }
        }

        if let bundleID = value(after: "--source-link") {
            guard
                let target = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })
            else {
                print("\(bundleID) is not running")
                exit(1)
            }
            let isBrowser = SourceLink.isBrowser(target)
            let started = Date()
            let link = SourceLink.lookUp(processID: target.processIdentifier, isBrowser: isBrowser, timeout: 1)
            print("browser: \(isBrowser)")
            print(String(format: "took: %.0f ms", Date().timeIntervalSince(started) * 1000))
            print("link: \(link ?? "none")")
            if let link { print("shown as: \(SourceLink.displayText(for: link))") }
            exit(0)
        }

        if let query = value(after: "--search") {
            let wordsOnly = arguments.contains("--words")
            Task { @MainActor in exit(await search(query, wordsOnly: wordsOnly)) }
            RunLoop.main.run()
            return true
        }
        if let path = value(after: "--read") {
            Task {
                print(await PictureText.recognize(URL(fileURLWithPath: path)) ?? "could not read \(path)")
                exit(0)
            }
            RunLoop.main.run()
            return true
        }
        if arguments.contains("--set-search-key") {
            // From standard input, so the key is never an argument or in a file.
            let key = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let saved = SearchKey.save(key) && (key.isEmpty || SearchKey.read() != nil)
            print(saved ? "search key saved to the keychain" : "the search key could not be saved")
            exit(saved ? 0 : 1)
        }
        if let path = value(after: "--transcribe") {
            let engine = value(after: "--engine").flatMap(EngineID.init(rawValue:)) ?? .parakeet
            let realtime = arguments.contains("--realtime")
            Task.detached {
                let code = await transcribe(path: path, engineID: engine, realtime: realtime)
                exit(code)
            }
            RunLoop.main.run()
            return true
        }

        if let text = value(after: "--tidy") {
            Task.detached {
                let service = TidyService()
                print("availability: \(await service.availability())")
                let started = Date()
                let result = await service.run(raw: text, enabled: true)
                print("outcome: \(result.outcome.rawValue)" + (result.detail.map { " (\($0))" } ?? ""))
                print(String(format: "elapsed: %.2f s", Date().timeIntervalSince(started)))
                print("---\n\(result.text)")
                exit(0)
            }
            RunLoop.main.run()
            return true
        }

        return false
    }

    // MARK: Transcription self-test

    /// Searches the real notes as the search box would and prints what is
    /// found. The notes are only read; pictures not read yet are read first.
    @MainActor
    private static func search(_ query: String, wordsOnly: Bool) async -> Int32 {
        let store = NoteStore()
        let pictures = PictureText(directory: store.directory)
        pictures.catchUp(with: store.notes) { store.imageURL(for: $0) }
        await pictures.waitUntilIdle()
        let documents = store.notes.map { SearchDocument($0, picture: pictures.text(for: $0)) }
        var hits = NoteSearch.hits(for: query, in: documents)
        print("\(documents.count) notes; \(hits.count) by words")
        if !wordsOnly, let key = SearchKey.read() {
            let started = Date()
            do {
                let found = try await MeaningSearch.find(query, in: documents, key: key)
                print(String(format: "%d by meaning (%@, %.1f s)", found.count, MeaningSearch.model, Date().timeIntervalSince(started)))
                let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
                let named = Set(found)
                hits = found.compactMap { id in
                    hits.first { $0.id == id } ?? byID[id].map { NoteSearch.hit(for: $0, place: .meaning) }
                } + hits.filter { !named.contains($0.id) }
            } catch {
                print("by meaning failed: \(error)")
            }
        } else if !wordsOnly {
            print("no search key: by words only")
        }
        for hit in hits.prefix(12) {
            let note = store.note(hit.id)
            print("- [\(hit.place)] \(SourceLabel.timestamp.string(from: note?.timestamp ?? Date()))  \(hit.snippet.prefix(110))")
        }
        return 0
    }

    private static func transcribe(path: String, engineID: EngineID, realtime: Bool) async -> Int32 {
        let engine: any TranscriptionEngine
        switch engineID {
        case .parakeet:
            engine = ParakeetEngine()
        case .speechAnalyzer:
            guard #available(macOS 26.0, *) else {
                print("apple-speechanalyzer requires macOS 26")
                return 2
            }
            engine = SpeechAnalyzerEngine()
        }

        let samples: [Float]
        do {
            samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
        } catch {
            print("could not read \(path): \(error.localizedDescription)")
            return 1
        }
        print(String(format: "audio: %.2f s", Double(samples.count) / AudioRecorder.sampleRate))

        let ready = OSAllocatedUnfairLockBox(false)
        let prepareStarted = Date()
        await engine.prepare { state in
            print("engine: \(state.summary)")
            if state.isReady { ready.set(true) }
        }
        guard ready.get() else {
            print("engine did not become ready")
            return 1
        }
        print(String(format: "prepared in %.2f s", Date().timeIntervalSince(prepareStarted)))

        do {
            let session = try await engine.startSession { interim in
                print("interim: \(interim)")
            }
            // Feed in 100 ms chunks, as the recorder does.
            let chunk = Int(AudioRecorder.sampleRate / 10)
            var index = 0
            while index < samples.count {
                let end = min(index + chunk, samples.count)
                await session.append(Array(samples[index..<end]))
                index = end
                if realtime { try? await Task.sleep(for: .milliseconds(100)) }
            }
            let started = Date()
            let text = try await session.finish()
            print(String(format: "finalised in %.2f s", Date().timeIntervalSince(started)))
            print("---\n\(text)")
            return 0
        } catch {
            print("transcription failed: \(error.localizedDescription)")
            return 1
        }
    }
}

/// A tiny thread-safe value holder for the self-tests.
private final class OSAllocatedUnfairLockBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

// MARK: - Offscreen renders

/// Renders the app's screens with sample content, so the design can be
/// reviewed without granting permissions or making a capture.
@MainActor
private enum Snapshots {

    /// 2 renders as a Retina display would; 1 as an ordinary external display.
    static var pixelsPerPoint = 2

    /// Says whether the app being rendered is still reading screenshots, so
    /// a render can wait for them rather than catch a screen half filled in.
    static var isReading: (() -> Bool)?

    static func renderAll(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Sample data lives in a throwaway store and its own defaults domain,
        // never in the real ones.
        let suite = "blog.terminal.app.snapshot"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retainer-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let windowSize = CGSize(width: 1280, height: 800)
        // What is left for the board above the status bar.
        let boardSize = CGSize(width: windowSize.width, height: windowSize.height - 26)

        // 1. First launch: nothing saved yet, the permission checklist showing.
        let empty = AppModel(defaults: defaults, storeDirectory: storeDirectory.appendingPathComponent("empty"))
        empty.canvas.setViewSize(boardSize)
        try render(RootView(app: empty), size: windowSize, to: directory.appendingPathComponent("01-first-launch.png"))

        // 2. An empty Today, alone.
        empty.hideChecklist()
        try render(RootView(app: empty), size: windowSize, to: directory.appendingPathComponent("02-empty-today.png"))

        // 3. Today's board with a few notes, and a timeline of made-up past days.
        let app = try sampleApp(
            defaults: defaults, storeDirectory: storeDirectory.appendingPathComponent("notes"), boardSize: boardSize)
        isReading = { app.images.isReading }
        defer { isReading = nil }
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("03-today.png"))

        // 4. A card opened out, and its note being edited there.
        if let first = app.store.notes.first {
            app.canvas.expand(first.id, in: app.store)
            try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("04-card-opened.png"))
            app.canvas.expand(first.id, in: app.store, editing: true)
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("04b-card-editing.png"))
            app.canvas.collapse()
        }

        // Scrolled away from the cards, a little and then a long way: the
        // window's edges light up towards them. Then the far place again
        // with the orb instead.
        app.canvas.pan(by: CGSize(width: -2600, height: -1500))
        try render(
            RootView(app: app), size: windowSize, to: directory.appendingPathComponent("04d-cards-at-the-orbs-edge.png"))
        app.canvas.pan(by: CGSize(width: -1900, height: -1100))
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("04c-far-from-the-cards.png"))
        app.settings.miniMapStyle = .orb
        try render(
            RootView(app: app), size: windowSize, to: directory.appendingPathComponent("04f-far-from-the-cards-orb.png"))
        app.settings.miniMapStyle = .edges
        app.canvas.pan(by: CGSize(width: 4500, height: 2600))

        // 5. Along the timeline: yesterday, then this week, this month and all time.
        app.step(by: -1)
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("05-an-earlier-day.png"))
        app.showPresent()
        app.setTimeScale(.week)
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("06a-week.png"))
        app.setTimeScale(.month)
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("06b-month.png"))
        app.setTimeScale(.all)
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("06c-all-time.png"))
        app.setTimeScale(.day)

        // The settings panel, the light palette, and the archive.
        app.showsSettings = true
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("16-settings.png"))
        app.settings.lightMode = true
        try render(
            RootView(app: app), size: windowSize, to: directory.appendingPathComponent("17-settings-light.png"),
            light: true)
        app.showsSettings = false
        try render(
            RootView(app: app), size: windowSize, to: directory.appendingPathComponent("18-today-light.png"),
            light: true)
        app.setTimeScale(.week)
        try render(
            RootView(app: app), size: windowSize, to: directory.appendingPathComponent("18b-week-light.png"),
            light: true)
        app.setTimeScale(.day)
        if let second = app.store.notes.dropFirst().first {
            app.canvas.expand(second.id, in: app.store)
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("20-card-opened-light.png"),
                light: true)
            app.canvas.collapse()
        }
        app.settings.lightMode = false
        app.setShowingArchive(true)
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("19-archive.png"))
        app.setShowingArchive(false)

        // A small card as it looks with the pointer over it: the screenshot
        // dimmed a touch, the link under it a little brighter.
        if let first = app.store.notes.first {
            let card = NodeView(note: first, scale: 1, showsHover: true)
                .padding(40)
                .background(Theme.background)
                .environment(app.store)
                .environment(app.canvas)
                .environment(app.images)
                .preferredColorScheme(.dark)
            try render(card, size: CGSize(width: 480, height: 400), to: directory.appendingPathComponent("23-card-hover.png"))
        }

        // The input box with a link and a picture pasted into it, waiting.
        let pastedLink = StagedItem.link(URL(string: "https://www.example.org/essays/the-economics-of-attention?ref=reading-list")!)
        let pastedPicture = StagedItem(
            kind: .image, image: CapturedImage(cgImage: SampleContent.article(size: CGSize(width: 520, height: 340), scale: 2, seed: 4), scale: 2),
            sourceURL: nil, origin: "Picture", title: "chart.png")
        app.staging.add([pastedLink, pastedPicture].compactMap { $0 })
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("24-pasted-and-waiting.png"))
        // Taken out again, not sent on: sending them on would put the real
        // overlay on the real screen.
        for item in app.staging.items { app.staging.remove(item.id) }

        // Search, opened from the round button beside the switch. By words
        // only: no key is read and nothing is sent anywhere from a render.
        app.search.key = { nil }
        app.search.open()
        app.search.query = "the method"
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("24c-search.png"))
        app.search.query = "nothing has these words in it"
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("24d-search-nothing.png"))
        app.search.close()

        // A note typed into the box: a card of words alone.
        app.coordinator.saveDirectly(
            [], text: "Compare the two pricing tables before Thursday. The older one has the per-seat numbers we need.")
        try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("24b-a-typed-note.png"))

        // Projects: the list, a project's canvases with one in front, a name
        // being typed, a delete waiting for its second click, an empty canvas.
        let today = app.store.notes(in: app.canvas.today)
        let earlier = app.store.sampleNotes.suffix(40)
        let reading = app.store.addProject(name: "Reading")
        let thesis = app.store.addProject(name: "Thesis")
        _ = app.store.addProject(name: "Side project")
        if let toRead = app.store.addCanvas(in: reading.id, name: "To read"),
            let outline = app.store.addCanvas(in: thesis.id, name: "Outline"),
            let chapter = app.store.addCanvas(in: thesis.id, name: "Chapter 1"),
            let sources = app.store.addCanvas(in: thesis.id, name: "Sources")
        {
            // Cards from different days, set out afresh on each canvas.
            func put(_ notes: [Note], on canvasID: UUID) {
                for (index, note) in notes.enumerated() {
                    let column = index % 3
                    let row = index / 3
                    app.store.place(
                        noteID: note.id, on: canvasID,
                        at: CGPoint(x: -620 + Double(column) * 430, y: -210 + Double(row) * 560))
                }
            }
            put(Array(earlier.prefix(4)), on: toRead.id)
            put(Array(earlier.dropFirst(4).prefix(2)), on: outline.id)
            put(Array(today.prefix(2)) + Array(earlier.dropFirst(8).prefix(3)), on: chapter.id)
            put(Array(earlier.dropFirst(12).prefix(6)), on: sources.id)

            app.setMode(.projects)
            try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("26-projects.png"))
            app.navigation.openCanvas(chapter.id)
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("27-a-canvas-in-front.png"))
            app.settings.lightMode = true
            try render(
                RootView(app: app), size: windowSize,
                to: directory.appendingPathComponent("27b-a-canvas-in-front-light.png"), light: true)
            app.settings.lightMode = false
            // A project whose name does not fit on one row.
            app.store.renameProject(id: thesis.id, to: "Outstanding questions for the thesis committee")
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("27c-a-long-project-name.png"))
            app.store.renameProject(id: thesis.id, to: "Thesis")
            app.navigation.requestDelete(sources.id)
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("28-canvas-delete-waiting.png"))
            app.navigation.cancelDelete()
            _ = app.navigation.newCanvas()
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("29-new-canvas-being-named.png"))
            app.navigation.cancelRename()
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent("30-an-empty-canvas.png"))

            // Groups: five cards put together on a canvas, a sixth held over
            // them about to join, and the group opened out.
            app.navigation.openCanvas(sources.id)
            let cards = app.store.notes(on: sources.id)
            if cards.count >= 6,
                let group = app.store.makeGroup(
                    on: Board.canvas(sources.id).id, of: cards.prefix(5).map(\.id), at: CGPoint(x: -540, y: -170),
                    name: "Retry queue reading")
            {
                app.store.place(noteID: cards[5].id, on: sources.id, at: CGPoint(x: 60, y: -170))
                try render(RootView(app: app), size: windowSize, to: directory.appendingPathComponent("31-a-group.png"))

                // Two cards of words join it: they have no picture to add to
                // the tile, so each is a small chip under the pictures.
                app.coordinator.saveDirectly([], text: "Ask about the retry budget before Thursday.")
                app.coordinator.saveDirectly([], text: "Second thought: the queue depth matters more than the rate.")
                for note in app.store.notes(on: sources.id) where note.isTextOnly {
                    app.store.addToGroup(noteID: note.id, groupID: group.id)
                }
                try render(
                    RootView(app: app), size: windowSize,
                    to: directory.appendingPathComponent("31b-a-group-with-words.png"))

                app.store.place(noteID: cards[5].id, on: sources.id, at: CGPoint(x: -470, y: -100))
                let held = CanvasView(shownGroupTarget: (cards[5].id, .group(group.id)))
                    .environment(app.store)
                    .environment(app.canvas)
                    .environment(app.images)
                    .preferredColorScheme(.dark)
                try render(held, size: boardSize, to: directory.appendingPathComponent("32-held-over-a-group.png"))
                app.store.place(noteID: cards[5].id, on: sources.id, at: CGPoint(x: 60, y: -170))

                app.canvas.expandedGroupID = group.id
                try render(
                    RootView(app: app), size: windowSize, to: directory.appendingPathComponent("33-a-group-opened.png"))
                app.canvas.expandedGroupID = nil
            }
        }
        app.setMode(.timeline)

        // The overlay, drawn over a stand-in for whatever was on screen.
        let screen = CGSize(width: 1440, height: 900)
        let desktop = SampleContent.article(size: screen, scale: 2)
        let selection = CGRect(x: 250, y: 150, width: 760, height: 360)

        func overlay(on background: CGImage? = nil, _ configure: (CaptureSessionModel) -> Void) -> some View {
            let meter = LevelMeter()
            meter.set(0.62)
            let model = CaptureSessionModel(
                screenSize: screen, selection: selection, pillBottomInset: 96, meter: meter)
            configure(model)
            return ZStack(alignment: .topLeading) {
                Image(decorative: background ?? desktop, scale: 2)
                OverlayRootView(model: model, staticLevel: 0.62)
            }
            .frame(width: screen.width, height: screen.height)
        }
        let captured = CapturedImage(cgImage: SampleContent.crop(desktop, rect: selection, scale: 2), scale: 2)

        try render(overlay { _ in }, size: screen, to: directory.appendingPathComponent("06-selecting.png"))
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .speaking
            }, size: screen, to: directory.appendingPathComponent("07-speaking.png"))
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .speaking
                model.interimText = "I think the second paragraph is the one that actually matters, because it"
            }, size: screen, to: directory.appendingPathComponent("08-speaking-live-words.png"))
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .processing
                model.processingLabel = "transcribing"
            }, size: screen, to: directory.appendingPathComponent("09-processing.png"))
        // A pasted link in the same place: its card, the pill, and what ends the talking.
        if let pastedLink {
            try render(
                overlay { model in
                    model.image = pastedLink.image
                    model.lifted = true
                    model.phase = .speaking
                    model.speakingHint = "return when you have said it  ·  esc to drop it"
                }, size: screen, to: directory.appendingPathComponent("25-pasted-link-speaking.png"))
        }
        let note =
            "I think the second paragraph is the one that actually matters, because it admits the sample was small.\n\nWorth comparing with the earlier study before quoting any of this."
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .editing
                model.initialText = note
                model.editorText = note
            }, size: screen, to: directory.appendingPathComponent("10-editing.png"))
        // With a canvas in front, the editor says where the card is going.
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .editing
                model.initialText = note
                model.editorText = note
                model.destination = "to Thesis / Outline"
            }, size: screen, to: directory.appendingPathComponent("10b-editing-for-a-canvas.png"))
        // The microphone switched back on from the editor, to add to the note.
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .editing
                model.initialText = note
                model.editorText = note + " And the follow-up had"
                model.addedVoice = .listening
            }, size: screen, to: directory.appendingPathComponent("10c-editing-adding-voice.png"))
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .editing
                model.initialText = note
                model.editorText = note + " Changed."
                model.discardArmed = true
            }, size: screen, to: directory.appendingPathComponent("11-discard-confirm.png"))
        try render(
            overlay { model in
                model.image = captured
                model.lifted = true
                model.phase = .editing
                model.notice = "Microphone unavailable. No microphone is connected. Type your note instead."
            }, size: screen, to: directory.appendingPathComponent("12-no-microphone.png"))

        // The same selection over dark content, and dragged up and to the left.
        let darkDesktop = SampleContent.article(size: screen, scale: 2, dark: true)
        try render(
            overlay(on: darkDesktop) { _ in }, size: screen,
            to: directory.appendingPathComponent("13-selecting-dark.png"))
        try render(
            overlay(on: darkDesktop) { model in
                model.updateSelection(CGRect(x: 560, y: 300, width: 176, height: 88))
            }, size: screen, to: directory.appendingPathComponent("14-selecting-dark-small.png"))
        let darkCaptured = CapturedImage(cgImage: SampleContent.crop(darkDesktop, rect: selection, scale: 2), scale: 2)
        try render(
            overlay(on: darkDesktop) { model in
                model.image = darkCaptured
                model.lifted = true
                model.phase = .speaking
            }, size: screen, to: directory.appendingPathComponent("15-speaking-dark.png"))

        print("wrote snapshots to \(directory.path)")
    }

    /// An app with sample content: a few notes on today's board and a
    /// timeline of made-up past days.
    private static func sampleApp(defaults: UserDefaults, storeDirectory: URL, boardSize: CGSize) throws -> AppModel {
        let app = AppModel(defaults: defaults, storeDirectory: storeDirectory)
        app.hideChecklist()
        app.canvas.setViewSize(boardSize)
        let samples = SampleDays.samples(now: app.canvas.currentDate, calendar: app.store.calendar)
        SampleDays.writeMissingImages(for: samples, to: SampleDays.imagesDirectory)
        app.store.setSampleNotes(samples.map(\.note), imagesIn: SampleDays.imagesDirectory)
        for sample in SampleContent.notes(now: app.canvas.currentDate, calendar: app.store.calendar) {
            // On disk as well as in memory, as a real capture is.
            try ImageFiles.writePNG(sample.image, scale: 2, to: app.store.imageURL(for: sample.note))
            app.images.insert(sample.image, for: sample.note.id)
            app.store.add(sample.note)
        }
        return app
    }

    /// The mini map alone, in each of its states, large enough to judge:
    /// the orb with everything in view, with cards at its edge, with cards
    /// far off one way and the other, in the middle and at the corner of a
    /// month, and in light mode.
    static func renderMaps(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suite = "blog.terminal.app.snapshot.maps"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retainer-maps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let app = try sampleApp(
            defaults: defaults, storeDirectory: storeDirectory, boardSize: CGSize(width: 1280, height: 774))
        isReading = { app.images.isReading }
        defer { isReading = nil }

        func map(_ name: String, light: Bool = false) throws {
            let view = ZStack {
                Theme.background
                MiniMap()
            }
            .environment(app.store)
            .environment(app.canvas)
            .environment(app.images)
            .preferredColorScheme(light ? .light : .dark)
            try render(
                view, size: CGSize(width: 200, height: 200), to: directory.appendingPathComponent(name + ".png"),
                light: light)
        }

        /// The board in front fitted to the window, or shown at 100% round
        /// one point of it (given as fractions of the way across and down).
        func look(at place: CGPoint?) {
            let notes = app.store.notes(in: app.canvas.period, archived: false)
            let bounds = app.canvas.layout(of: notes).bounds
            guard !bounds.isNull else { return }
            app.canvas.fit(bounds)
            guard let place else { return }
            app.canvas.resetZoom()
            let point = CGPoint(x: bounds.minX + bounds.width * place.x, y: bounds.minY + bounds.height * place.y)
            app.canvas.centre(on: CGRect(origin: point, size: .zero))
        }

        try map("01-today")
        app.canvas.pan(by: CGSize(width: -2600, height: -1500))
        try map("02-cards-at-the-edge")
        app.canvas.pan(by: CGSize(width: -1900, height: -1100))
        try map("03-far")
        try map("03-far-light", light: true)
        // Far off the other way: the cards are now to the right, a little up.
        app.canvas.pan(by: CGSize(width: 8700, height: 2300))
        try map("04-far-the-other-way")
        app.canvas.pan(by: CGSize(width: -4200, height: 300))

        app.setTimeScale(.week)
        look(at: nil)
        try map("05-week")
        look(at: CGPoint(x: 0.5, y: 0.5))
        try map("06-week-in-the-middle")
        app.setTimeScale(.month)
        look(at: nil)
        try map("07-month")
        look(at: CGPoint(x: 0.5, y: 0.5))
        try map("08-month-in-the-middle")
        try map("08-month-in-the-middle-light", light: true)
        look(at: CGPoint(x: 0, y: 0))
        try map("09-month-at-the-corner")
        app.setTimeScale(.all)
        look(at: CGPoint(x: 0.5, y: 0.5))
        try map("10-all-time-in-the-middle")
        try map("10-all-time-in-the-middle-light", light: true)
    }

    /// The light on the window's edges, on a wide window, with the cards
    /// out of view each way they can be: above, beyond a corner, off to one
    /// side, all round; and in view, when there is none.
    static func renderEdges(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let suite = "blog.terminal.app.snapshot.edges"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("retainer-edges-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let windowSize = CGSize(width: 1720, height: 760)
        let boardSize = CGSize(width: windowSize.width, height: windowSize.height - 26)
        let app = try sampleApp(defaults: defaults, storeDirectory: storeDirectory, boardSize: boardSize)
        app.settings.miniMapStyle = .edges
        isReading = { app.images.isReading }
        defer { isReading = nil }

        /// The part of the board in front that its cards cover.
        func cards() -> CGRect {
            let notes = app.canvas.notes(in: app.store)
            if app.canvas.showsDays { return app.canvas.layout(of: notes).bounds }
            return notes.reduce(CGRect.null) { $0.union(app.canvas.frame(of: $1)) }
        }
        /// Shows the board at 100% with the window's top left corner at a point of it.
        func look(from corner: CGPoint) {
            app.canvas.resetZoom()
            app.canvas.centre(on: CGRect(origin: corner, size: boardSize))
        }
        func shot(_ name: String, light: Bool = false) throws {
            app.settings.lightMode = light
            try render(
                RootView(app: app), size: windowSize, to: directory.appendingPathComponent(name + ".png"), light: light)
            app.settings.lightMode = false
        }

        let today = cards()
        guard !today.isNull else { return }
        app.canvas.fit(today)
        try shot("01-everything-in-view")
        // The cards above the window, starting a little way in from its left.
        look(from: CGPoint(x: today.minX - 330, y: today.maxY + 120))
        try shot("02-cards-above")
        try shot("02-cards-above-light", light: true)
        // Only just out of sight, where the light is still coming up.
        look(from: CGPoint(x: today.minX - 330, y: today.maxY + 24))
        try shot("03-cards-just-above")
        // Beyond the top left corner, and far beyond it.
        look(from: CGPoint(x: today.maxX + 160, y: today.maxY + 120))
        try shot("04-cards-beyond-the-corner")
        look(from: CGPoint(x: today.maxX + 2400, y: today.maxY + 1500))
        try shot("05-cards-far-beyond-the-corner")
        // Off to the left, level with the window; then off to the right.
        look(from: CGPoint(x: today.maxX + 160, y: today.midY - boardSize.height / 2))
        try shot("06-cards-to-the-left")
        look(from: CGPoint(x: today.minX - boardSize.width - 160, y: today.midY - boardSize.height / 2))
        try shot("07-cards-to-the-right")
        // Below.
        look(from: CGPoint(x: today.midX - boardSize.width / 2, y: today.minY - boardSize.height - 120))
        try shot("08-cards-below")
        // In the middle of a month: cards all round, and cards in view.
        app.setTimeScale(.month)
        let month = cards()
        look(from: CGPoint(x: month.midX - boardSize.width / 2, y: month.midY - boardSize.height / 2))
        try shot("09-in-the-middle-of-a-month")
        try shot("09-in-the-middle-of-a-month-light", light: true)
        // At the month's left-hand end: cards above, below and to the right,
        // and nothing to the left.
        look(from: CGPoint(x: month.minX - 330, y: month.midY - boardSize.height / 2))
        try shot("10-at-the-left-of-a-month")

        // Cards three ways at once, on a canvas of their own: to the left,
        // to the right and below, with the window in the gap between them.
        let project = app.store.addProject(name: "Scattered")
        if let canvas = app.store.addCanvas(in: project.id, name: "Three ways") {
            let places = [
                CGPoint(x: -2600, y: -260), CGPoint(x: -2600, y: 200), CGPoint(x: 2300, y: -120),
                CGPoint(x: -160, y: 1500), CGPoint(x: 290, y: 1500),
            ]
            for (note, place) in zip(app.store.sampleNotes.suffix(places.count), places) {
                app.store.place(noteID: note.id, on: canvas.id, at: place)
            }
            app.navigation.openCanvas(canvas.id)
            look(from: CGPoint(x: -boardSize.width / 2, y: -boardSize.height / 2))
            try shot("11-cards-three-ways")
            try shot("11-cards-three-ways-light", light: true)
        }
    }

    /// What moves of its own accord, measured as it moves: the words that
    /// say the cards are out of view fading in and out, and their chevrons
    /// taking turns. A still cannot show either. The view is kept in one
    /// window and looked at again and again; what is printed is how bright
    /// the words and each chevron are at each moment, from 0 (the board) to
    /// 1 (as bright as they get).
    static func renderMotion(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = CGSize(width: 420, height: 180)
        let ways = MotionWays()
        let hosting = NSHostingView(
            rootView: MotionProbe(ways: ways).frame(width: size.width, height: size.height)
                .environment(\.displayScale, 2))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.nsBackground
        window.contentView = hosting
        window.orderBack(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }

        func wait(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }
        func look() throws -> NSBitmapImageRep {
            hosting.layoutSubtreeIfNeeded()
            guard
                let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { throw CocoaError(.fileWriteUnknown) }
            bitmap.size = size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            return bitmap
        }
        /// The brightest thing in a part of the view (in points, from its
        /// middle), against the board: 0 for nothing, 1 for full white.
        func brightest(_ bitmap: NSBitmapImageRep, dx: ClosedRange<CGFloat>, dy: ClosedRange<CGFloat>) -> Double {
            guard let data = bitmap.bitmapData else { return 0 }
            var most = 0
            for y in Int((size.height / 2 + dy.lowerBound) * 2)...Int((size.height / 2 + dy.upperBound) * 2) {
                for x in Int((size.width / 2 + dx.lowerBound) * 2)...Int((size.width / 2 + dx.upperBound) * 2) {
                    most = max(most, Int(data[y * bitmap.bytesPerRow + x * 4]))
                }
            }
            return Double(most - 21) / 234
        }
        func line(_ moment: String, _ bitmap: NSBitmapImageRep) -> String {
            // The words are the upper line of two, the link the lower; the
            // chevrons are round both.
            let words = brightest(bitmap, dx: -70...70, dy: -22...(-3))
            let link = brightest(bitmap, dx: -26...26, dy: 4...21)
            let right = brightest(bitmap, dx: 100...124, dy: -9...9)
            let left = brightest(bitmap, dx: -124...(-100), dy: -9...9)
            let below = brightest(bitmap, dx: -8...8, dy: 48...72)
            return String(
                format: "%@  words %.2f  link %.2f   chevrons: left %.2f  right %.2f  below %.2f", moment, words, link,
                left, right, below)
        }
        func save(_ bitmap: NSBitmapImageRep, _ name: String) throws {
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
            try data.write(to: directory.appendingPathComponent(name + ".png"))
        }

        // Nothing to say, then cards one way: the words fade in.
        wait(0.6)
        print(line("in view        ", try look()))
        var began = Date()
        ways.directions = [0]
        for moment in [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.8, 1.0] {
            wait(max(0, moment - Date().timeIntervalSince(began)))
            let seen = try look()
            print(line(String(format: "out of view +%.2f", Date().timeIntervalSince(began)), seen))
            // Three moments of the fade, to be looked at side by side.
            if [0.25, 0.45, 0.8].contains(moment) { try save(seen, String(format: "fading-in-%.2f", moment)) }
        }
        // One chevron, coming up and fading back by turns.
        for _ in 0..<16 {
            wait(0.24)
            print(line(String(format: "one way      +%.2f", Date().timeIntervalSince(began)), try look()))
        }
        try save(try look(), "one-way")
        // The board is scrolled and the cards are below instead: the chevron
        // is there at once, not on its way there.
        ways.directions = [.pi / 2]
        began = Date()
        for moment in [0.04, 0.12, 0.3] {
            wait(max(0, moment - Date().timeIntervalSince(began)))
            print(line(String(format: "now below    +%.2f", Date().timeIntervalSince(began)), try look()))
        }
        // Three ways: each chevron in its turn.
        ways.directions = [.pi, 0, .pi / 2]
        began = Date()
        for moment in [0.04, 0.12] {
            wait(max(0, moment - Date().timeIntervalSince(began)))
            print(line(String(format: "three ways   +%.2f", Date().timeIntervalSince(began)), try look()))
        }
        for count in 0..<26 {
            wait(0.24)
            let seen = try look()
            print(line(String(format: "three ways   +%.2f", Date().timeIntervalSince(began)), seen))
            // Each chevron at about its brightest, a second apart.
            if [3, 7, 11].contains(count) { try save(seen, "three-ways-turn-\((count + 1) / 4)") }
        }
        try save(try look(), "three-ways")
        // A card comes back into view: the words go.
        ways.directions = []
        began = Date()
        for moment in [0.03, 0.08, 0.13, 0.2, 0.3] {
            wait(max(0, moment - Date().timeIntervalSince(began)))
            print(line(String(format: "in view again +%.2f", Date().timeIntervalSince(began)), try look()))
        }
    }

    /// The selection glass over a picture, one point per pixel of the
    /// picture: for judging the glass against something other than the
    /// sample page.
    static func renderGlass(over picture: URL, rect: CGRect?, to output: URL) throws {
        guard
            let source = CGImageSourceCreateWithURL(picture as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let size = CGSize(width: image.width, height: image.height)
        let panel =
            rect
            ?? CGRect(x: size.width / 4, y: size.height / 4, width: size.width / 2, height: size.height / 2).integral
        let view = ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: size.width, height: size.height)
            GlassPanel(rect: panel)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        try render(view, size: size, to: output)
    }

    /// Draws a SwiftUI view into a PNG by hosting it in an offscreen window.
    private static func render(
        _ view: some View, size: CGSize, to url: URL, light: Bool = false, settle: TimeInterval = 0.9
    ) throws {
        let hosting = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height)
                .environment(\.displayScale, CGFloat(pixelsPerPoint))
                .environment(\.rendersStill, true))
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -20000, y: -20000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        window.backgroundColor = Theme.nsBackground
        window.contentView = hosting
        window.orderBack(nil)
        defer {
            // Nothing of this screen may outlive it. A hosting view left in a
            // window goes on following the app's state, so every later change
            // is worked out again for every screen already drawn: by the
            // twentieth screen that was seconds of stalling, and screens
            // caught before their pictures had been asked for.
            window.orderOut(nil)
            window.contentView = nil
        }

        // Let layout, image loading and text measurement settle.
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        // Screenshots are read off the main thread. Wait, within reason,
        // until none has been on its way for a moment: a screen that takes
        // long to build asks for its pictures late, and the views need a
        // moment to take them in.
        let patience = Date().addingTimeInterval(12)
        var quietSince = Date()
        while Date() < patience, Date().timeIntervalSince(quietSince) < 0.3 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if isReading?() == true { quietSince = Date() }
        }
        hosting.layoutSubtreeIfNeeded()

        // At a fixed density, whatever display happens to be attached.
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width) * pixelsPerPoint,
                pixelsHigh: Int(size.height) * pixelsPerPoint,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url)
    }
}

/// Stand-in screenshots and notes for the offscreen renders.
@MainActor
private enum SampleContent {

    struct Sample {
        let note: Note
        let image: CGImage
    }

    /// A few notes saved earlier today, the last of them archived and the
    /// one before it not yet looked at.
    static func notes(now: Date, calendar: Calendar) -> [Sample] {
        let startOfDay = calendar.startOfDay(for: now)
        let texts: [(String, String, String, CGSize, CGPoint)] = [
            (
                "The claim in the second paragraph rests on a sample of forty people. I would not quote it without the follow-up study.\n\nThings to check:\n\n- who funded it\n- whether the effect survives controlling for age\n- the original survey wording",
                "Safari", "The Economics of Attention", CGSize(width: 760, height: 360), CGPoint(x: -490, y: -300)
            ),
            (
                "This is the clearest diagram of the pipeline I have seen. The **retry path** is the part we got wrong last quarter.",
                "Preview", "architecture-review.pdf", CGSize(width: 520, height: 520), CGPoint(x: -66, y: -300)
            ),
            (
                "Short one. Keep this number.",
                "Numbers", "Q3 forecast", CGSize(width: 640, height: 200), CGPoint(x: 358, y: -300)
            ),
            (
                "Put away for now. The pricing table is out of date but the structure is worth copying.",
                "Chrome", "Pricing – Example Co", CGSize(width: 700, height: 420), CGPoint(x: -200, y: -260)
            ),
        ]
        return texts.enumerated().map { index, entry in
            let (text, app, title, size, position) = entry
            let image = article(size: size, scale: 2, seed: index)
            let id = UUID()
            let note = Note(
                id: id,
                imagePath: NoteStore.imagePath(for: id),
                imagePixelSize: PixelSize(width: image.width, height: image.height),
                imageScale: 2,
                note: text,
                rawTranscript: text,
                engine: index == 2 ? EngineID.speechAnalyzer.rawValue : EngineID.parakeet.rawValue,
                tidy: true,
                tidyOutcome: .applied,
                // Spread over the day so far, never in the future.
                timestamp: startOfDay.addingTimeInterval(
                    now.timeIntervalSince(startOfDay) * Double(index + 1) / 5),
                sourceApp: app,
                windowTitle: title,
                // A page, a file, and one with no link.
                sourceURL: index == 0
                    ? "https://www.example.org/essays/the-economics-of-attention"
                    : index == 1
                        ? URL(fileURLWithPath: NSHomeDirectory() + "/Documents/architecture-review.pdf").absoluteString
                        : nil,
                position: CanvasPoint(position),
                // The last one is in the archive; the one before it has not been looked at yet.
                archivedAt: index == 3 ? now : nil,
                seen: index != 2)
            return Sample(note: note, image: image)
        }
    }

    static func article(size: CGSize, scale: CGFloat, seed: Int = 0, dark: Bool = false) -> CGImage {
        SampleArt.article(size: size, scale: scale, seed: seed, dark: dark)
    }

    static func crop(_ image: CGImage, rect: CGRect, scale: CGFloat) -> CGImage {
        SampleArt.crop(image, rect: rect, scale: scale)
    }
}


/// Which way the cards are, for the motion check to change as it watches.
@MainActor
@Observable
private final class MotionWays {
    var directions: [Double] = []
}

/// The words and chevrons on their own, as the board shows them.
private struct MotionProbe: View {
    let ways: MotionWays

    var body: some View {
        ZStack {
            Theme.background
            OverThere(directions: ways.directions)
        }
        .preferredColorScheme(.dark)
    }
}
