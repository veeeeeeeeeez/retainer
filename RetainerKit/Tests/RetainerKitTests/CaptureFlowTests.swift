import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import RetainerKit

// MARK: - Stand-ins for the outside world

private final class FakeGestureControl: GestureControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _enabled: Bool?
    private var _sessionEnded = 0
    private var _suspended = 0
    private var _stopped = false

    func setEnabled(_ enabled: Bool) { lock.withLock { _enabled = enabled } }
    func sessionEnded() { lock.withLock { _sessionEnded += 1 } }
    func suspend() { lock.withLock { _suspended += 1 } }
    func verifyActiveGesture() {}
    func stop() { lock.withLock { _stopped = true } }

    var enabled: Bool? { lock.withLock { _enabled } }
    var sessionEndedCount: Int { lock.withLock { _sessionEnded } }
    var suspendCount: Int { lock.withLock { _suspended } }
}

private struct FakeCapturer: ScreenCapturing {
    var delay: Duration = .zero
    var fails = false

    struct Failure: LocalizedError {
        var errorDescription: String? { "screen recording is not permitted" }
    }

    func prefetch() async {}

    func capture(rect: CGRect, displayID: CGDirectDisplayID) async throws -> CapturedImage {
        if delay > .zero { try await Task.sleep(for: delay) }
        if fails { throw Failure() }
        // Two pixels per point, like a Retina display.
        let width = Int(rect.width * 2)
        let height = Int(rect.height * 2)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return CapturedImage(cgImage: context.makeImage()!, scale: 2)
    }
}

private final class FakeRecorder: AudioRecording, @unchecked Sendable {
    let meter = LevelMeter()
    private let lock = NSLock()
    private let failure: RecorderError?
    private var _started = false
    private var _stopped = false

    init(failure: RecorderError? = nil) {
        self.failure = failure
    }

    func start(sink: @escaping @Sendable ([Float]) -> Void) async throws {
        if let failure { throw failure }
        lock.withLock { _started = true }
        // Three tenths of a second of "speech".
        for _ in 0..<3 { sink([Float](repeating: 0.1, count: 1600)) }
    }

    func stop() async -> TimeInterval {
        lock.withLock { _stopped = true }
        return 0.3
    }

    var started: Bool { lock.withLock { _started } }
    var stopped: Bool { lock.withLock { _stopped } }
}

@MainActor
private final class FakeOverlay: OverlayPresenting {
    var keyHandler: ((Int64, Bool, Bool) -> Bool)?
    var presentedOn: [CGDirectDisplayID] = []
    var mouseCaptured = false
    var keyboardTaken = 0
    var dismissed = 0

    func present(model: CaptureSessionModel, displayID: CGDirectDisplayID) { presentedOn.append(displayID) }
    func captureMouse() { mouseCaptured = true }
    func takeKeyboard() { keyboardTaken += 1 }
    func dismiss() { dismissed += 1 }
}

private actor FakeEngine: TranscriptionEngine {
    nonisolated let id = EngineID.parakeet
    let transcript: String
    let finishDelay: Duration
    private(set) var samplesReceived = 0
    private(set) var cancelled = 0

    init(transcript: String, finishDelay: Duration = .zero) {
        self.transcript = transcript
        self.finishDelay = finishDelay
    }

    func prepare(onState: @escaping @Sendable (EngineState) -> Void) async {
        onState(.ready)
    }

    func startSession(onInterim: @escaping @Sendable (String) -> Void) async throws -> any TranscriptionSession {
        FakeSession(engine: self, onInterim: onInterim)
    }

    func received(_ count: Int) { samplesReceived += count }
    func noteCancelled() { cancelled += 1 }
}

private actor FakeSession: TranscriptionSession {
    let engine: FakeEngine
    let onInterim: @Sendable (String) -> Void

    init(engine: FakeEngine, onInterim: @escaping @Sendable (String) -> Void) {
        self.engine = engine
        self.onInterim = onInterim
    }

    func append(_ samples: [Float]) async {
        await engine.received(samples.count)
        onInterim("words so far")
    }

    func finish() async throws -> String {
        let delay = engine.finishDelay
        if delay > .zero { try await Task.sleep(for: delay) }
        return engine.transcript
    }

    func cancel() async {
        await engine.noteCancelled()
    }
}

private struct StubTidier: TextTidier {
    var output: @Sendable (String) -> String
    func availability() async -> TidyAvailability { .available }
    func prewarm() async {}
    func tidy(_ transcript: String) async throws -> String { output(transcript) }
}

// MARK: - Harness

@MainActor
private final class Harness {
    static let display = DisplayInfo(id: 7, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
    static let selection = CGRect(x: 100, y: 120, width: 400, height: 300)

    let directory: URL
    let defaults: UserDefaults
    let suiteName: String
    let store: NoteStore
    let images = ImageCache()
    let canvas: CanvasModel
    let settings: AppSettings
    let engines: EngineManager
    let engine: FakeEngine
    let overlay = FakeOverlay()
    let gesture = FakeGestureControl()
    let coordinator: CaptureCoordinator
    private(set) var recorders: [FakeRecorder] = []
    private(set) var notices: [String] = []
    var missingPermissions: [Permission] = []
    /// What the app in front says its window is showing.
    var sourceLink: String? = "https://example.com/an-article"

    init(
        transcript: String = "um I think this is uh worth reading twice",
        tidier: (any TextTidier)? = nil,
        tidyEnabled: Bool = true,
        microphoneFailure: RecorderError? = nil,
        capturer: FakeCapturer = FakeCapturer(),
        finishDelay: Duration = .zero
    ) {
        suiteName = "retainer-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName, isDirectory: true)
        store = NoteStore(directory: directory)
        canvas = CanvasModel(defaults: defaults)
        settings = AppSettings(defaults: defaults)
        settings.tidyEnabled = tidyEnabled
        engine = FakeEngine(transcript: transcript, finishDelay: finishDelay)
        engines = EngineManager(defaults: defaults, engines: [.parakeet: engine], selected: .parakeet)

        // The environment's closures reach back into this object.
        let box = WeakBox()
        let overlay = self.overlay
        let gesture = self.gesture
        let environment = CaptureEnvironment(
            makeGestureControl: { _, _ in gesture },
            capturer: capturer,
            makeRecorder: {
                let recorder = FakeRecorder(failure: microphoneFailure)
                box.harness?.recorders.append(recorder)
                return recorder
            },
            overlay: overlay,
            screenMetrics: { _ in ScreenMetrics(size: CGSize(width: 1440, height: 900), dockHeight: 70) },
            mainDisplayID: { 7 },
            sourceContext: { SourceContext(appName: "Safari", windowTitle: "An article", processID: 1) },
            sourceLink: { _ in box.harness?.sourceLink },
            frontmostApplication: { nil },
            showNotice: { box.harness?.notices.append($0) },
            missingPermissions: { box.harness?.missingPermissions ?? [] },
            reportTapFailure: { _ in })
        coordinator = CaptureCoordinator(
            engines: engines, settings: settings, store: store, images: images, canvas: canvas,
            tidy: TidyService(tidier: tidier), environment: environment)
        box.harness = self
    }

    private final class WeakBox {
        weak var harness: Harness?
    }

    func cleanUp() {
        store.flush()
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Loads the engine and switches capture on, as the app does at launch.
    func makeReady() async {
        engines.prepareSelected()
        _ = await waitUntil { self.engines.selectedState.isReady }
        coordinator.sync()
    }

    var model: CaptureSessionModel? { coordinator.currentModel }

    /// Hold, drag, release the mouse: ends with the capture lifted and recording.
    func dragSelection() async {
        coordinator.handle([.selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Self.display)])
        coordinator.handle([.selectionChanged(rect: Self.selection)])
        coordinator.handle([.selectionEnded(rect: Self.selection)])
        _ = await waitUntil { self.model?.phase == .speaking }
    }

    /// Release the trigger and wait for the editor.
    func releaseAndWaitForEditor() async {
        coordinator.handle([.holdEnded])
        _ = await waitUntil { self.model?.phase == .editing }
    }

    @discardableResult
    func waitUntil(timeout: Duration = .seconds(4), _ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }
}

// MARK: - Tests

/// The whole capture, hold to saved note, driven by the same actions the
/// event tap produces, with stand-ins for the screen, microphone and engine.
@Suite("Capture flow")
@MainActor
struct CaptureFlowTests {

    @Test("Capture is off until permissions and the engine are ready, then on")
    func availability() async {
        let h = Harness()
        defer { h.cleanUp() }

        h.missingPermissions = [.screenRecording, .accessibility]
        h.coordinator.sync()
        #expect(h.coordinator.availability == .blocked("needs permission: screen recording, accessibility"))

        h.missingPermissions = []
        h.coordinator.sync()
        #expect(h.coordinator.availability == .blocked("speech engine not loaded"))
        #expect(h.gesture.enabled == false)

        await h.makeReady()
        #expect(h.coordinator.availability == .ready)
        #expect(h.gesture.enabled == true)
    }

    @Test("Hold, drag, speak, release, save: a node with the image and the note")
    func fullFlow() async throws {
        let h = Harness(tidier: StubTidier(output: { _ in "I think this is worth reading twice." }))
        defer { h.cleanUp() }
        await h.makeReady()

        // Phase 1: selection.
        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        let model = try #require(h.model)
        #expect(model.phase == .selecting)
        #expect(h.overlay.presentedOn == [7])
        #expect(model.pillBottomInset == 94)  // clears the 70 pt Dock

        h.coordinator.handle([.selectionChanged(rect: Harness.selection)])
        #expect(model.selection == Harness.selection)
        #expect(model.dimensionsLabel == "400 × 300")

        // Recording began with the drag.
        #expect(await h.waitUntil { h.recorders.first?.started == true })

        // Phase 2: mouse released, capture lifts to the centre.
        h.coordinator.handle([.selectionEnded(rect: Harness.selection)])
        #expect(await h.waitUntil { model.phase == .speaking })
        #expect(model.lifted)
        #expect(model.image?.cgImage.width == 800)
        #expect(h.overlay.mouseCaptured)
        #expect(await h.waitUntil { model.interimText == "words so far" })

        // The lifted image is centred and within 60% of the display.
        let frame = model.liftedImageFrame
        #expect(frame.midX == 720)
        #expect(frame.width <= 1440 * 0.6 && frame.height <= 900 * 0.6)

        // Phase 3: trigger released, transcript tidied, editor shown.
        h.coordinator.handle([.holdEnded])
        #expect(await h.waitUntil { model.phase == .editing })
        #expect(model.editorText == "I think this is worth reading twice.")
        #expect(model.statusLine == "parakeet-tdt-v2  ·  tidied")
        #expect(h.overlay.keyboardTaken >= 1)
        #expect(h.recorders.first?.stopped == true)
        #expect(await h.engine.samplesReceived == 4800)

        // Edit a word, then Command-Return.
        model.editorText = "I think this is worth reading again."
        #expect(h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true))

        let note = try #require(h.store.notes.first)
        #expect(h.store.notes.count == 1)
        #expect(note.note == "I think this is worth reading again.")
        #expect(note.rawTranscript == "um I think this is uh worth reading twice")
        #expect(note.engine == "parakeet-tdt-v2")
        #expect(note.tidy)
        #expect(note.tidyOutcome == .applied)
        #expect(note.sourceApp == "Safari")
        #expect(note.windowTitle == "An article")
        #expect(note.sourceURL == "https://example.com/an-article")
        #expect(note.imagePixelSize == PixelSize(width: 800, height: 600))
        #expect(note.imageScale == 2)
        #expect(h.images.image(for: note.id) != nil)

        // The card closes, the tap is told capturing may resume, and the PNG lands on disk.
        #expect(!h.coordinator.isCapturing)
        #expect(h.gesture.sessionEndedCount == 1)
        #expect(await h.waitUntil { h.overlay.dismissed == 1 })
        h.store.flush()
        #expect(FileManager.default.fileExists(atPath: h.store.imageURL(for: note).path))
    }

    @Test("With tidy off, the saved note equals the raw transcript")
    func tidyOff() async throws {
        // A tidier is present and would rewrite the text if it were consulted.
        let h = Harness(tidier: StubTidier(output: { _ in "Something else." }), tidyEnabled: false)
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        let model = try #require(h.model)
        #expect(model.editorText == "um I think this is uh worth reading twice")
        #expect(model.statusLine == "parakeet-tdt-v2  ·  tidy off")

        model.onSave()
        let note = try #require(h.store.notes.first)
        #expect(note.note == note.rawTranscript)
        #expect(note.note == "um I think this is uh worth reading twice")
        #expect(!note.tidy)
        #expect(note.tidyOutcome == .off)
    }

    @Test("When the model is unavailable the editor gets the raw transcript and says why")
    func tidyUnavailable() async throws {
        let h = Harness(tidier: nil)
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        let model = try #require(h.model)
        #expect(model.editorText == "um I think this is uh worth reading twice")
        #expect(model.statusLine == "parakeet-tdt-v2  ·  tidy unavailable: requires macOS 26")
    }

    @Test("A rewrite from the model is rejected in favour of the raw transcript")
    func tidyRejected() async throws {
        let h = Harness(tidier: StubTidier(output: { _ in "This text is recommended for a second reading." }))
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        let model = try #require(h.model)
        #expect(model.editorText == "um I think this is uh worth reading twice")
        #expect(model.statusLine.contains("tidy rejected"))
    }

    @Test("Saying nothing still opens an empty editor to type in")
    func silence() async throws {
        let h = Harness(transcript: "")
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        let model = try #require(h.model)
        #expect(model.editorText.isEmpty)

        model.editorText = "Typed from scratch."
        model.onSave()
        let note = try #require(h.store.notes.first)
        #expect(note.note == "Typed from scratch.")
        #expect(note.rawTranscript.isEmpty)
    }

    // MARK: Escape at every phase

    @Test("Releasing Option before the mouse cancels everything")
    func cancelDuringSelection() async {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        #expect(h.coordinator.isCapturing)
        h.coordinator.handle([.selectionCancelled(.triggerReleased)])

        #expect(!h.coordinator.isCapturing)
        #expect(h.store.notes.isEmpty)
        #expect(await h.waitUntil { h.overlay.dismissed == 1 })
        #expect(await h.waitUntil { h.recorders.first?.stopped == true })
        // The engine's session is abandoned, not finished.
        var cancelled = 0
        for _ in 0..<200 where cancelled == 0 {
            try? await Task.sleep(for: .milliseconds(5))
            cancelled = await h.engine.cancelled
        }
        #expect(cancelled == 1)
    }

    @Test("Escape while speaking discards the capture")
    func escapeWhileSpeaking() async {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        h.coordinator.handle([.escapePressed])

        #expect(!h.coordinator.isCapturing)
        #expect(await h.waitUntil { h.overlay.dismissed == 1 })
        #expect(await h.waitUntil { h.recorders.first?.stopped == true })
        // The Option release that follows must not revive anything.
        h.coordinator.handle([.holdEnded])
        try? await Task.sleep(for: .milliseconds(80))
        #expect(h.store.notes.isEmpty)
        #expect(!h.coordinator.isCapturing)
    }

    @Test("Escape while the transcript is being processed discards the capture")
    func escapeWhileProcessing() async {
        let h = Harness(finishDelay: .milliseconds(400))
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        h.coordinator.handle([.holdEnded])
        #expect(await h.waitUntil { h.model?.phase == .processing })
        #expect(h.coordinator.handleKey(keyCode: KeyCode.escape, command: false))

        #expect(!h.coordinator.isCapturing)
        try? await Task.sleep(for: .milliseconds(600))
        #expect(h.store.notes.isEmpty)
        #expect(h.overlay.dismissed == 1)
    }

    @Test("Escape in the editor discards at once when nothing was edited")
    func escapeInUntouchedEditor() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        #expect(h.coordinator.handleKey(keyCode: KeyCode.escape, command: false))

        #expect(!h.coordinator.isCapturing)
        #expect(h.store.notes.isEmpty)
    }

    @Test("Escape on an edited note asks first; a second Escape discards")
    func escapeInEditedEditor() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        let model = try #require(h.model)
        model.editorText += " More."

        #expect(h.coordinator.handleKey(keyCode: KeyCode.escape, command: false))
        #expect(model.discardArmed)
        #expect(h.coordinator.isCapturing)

        // Any other key keeps editing, and is passed on to the editor.
        #expect(!h.coordinator.handleKey(keyCode: 0, command: false))
        #expect(!model.discardArmed)
        #expect(h.coordinator.isCapturing)

        #expect(h.coordinator.handleKey(keyCode: KeyCode.escape, command: false))
        #expect(model.discardArmed)
        #expect(h.coordinator.handleKey(keyCode: KeyCode.escape, command: false))
        #expect(!h.coordinator.isCapturing)
        #expect(h.store.notes.isEmpty)
    }

    @Test("Return without Command is left to the editor")
    func plainReturnIsNotSave() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        #expect(!h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: false))
        #expect(h.store.notes.isEmpty)
        #expect(h.coordinator.isCapturing)
    }

    // MARK: Edge cases

    @Test("With no microphone the card goes straight to the editor with a clear message")
    func microphoneUnavailable() async throws {
        let h = Harness(microphoneFailure: .noInputDevice)
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        h.coordinator.handle([.selectionEnded(rect: Harness.selection)])
        // No release needed: the editor appears while Option is still held.
        #expect(await h.waitUntil { h.model?.phase == .editing })
        let model = try #require(h.model)
        #expect(model.notice == "Microphone unavailable. No microphone is connected. Type your note instead.")
        #expect(model.editorText.isEmpty)
        #expect(h.gesture.suspendCount == 1)

        model.editorText = "Typed instead."
        model.onSave()
        let note = try #require(h.store.notes.first)
        #expect(note.note == "Typed instead.")
        #expect(note.engine == "none")
        #expect(note.rawTranscript.isEmpty)
    }

    @Test("Releasing Option before the screenshot arrives still reaches the editor")
    func earlyRelease() async throws {
        let h = Harness(capturer: FakeCapturer(delay: .milliseconds(200)))
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        h.coordinator.handle([.selectionEnded(rect: Harness.selection)])
        h.coordinator.handle([.holdEnded])
        #expect(h.model?.image == nil)

        #expect(await h.waitUntil { h.model?.phase == .editing })
        #expect(h.model?.image != nil)
        #expect(h.model?.lifted == true)
    }

    @Test("A failed screenshot ends the capture and says so")
    func captureFailure() async {
        let h = Harness(capturer: FakeCapturer(fails: true))
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        h.coordinator.handle([.selectionEnded(rect: Harness.selection)])

        #expect(await h.waitUntil { !h.coordinator.isCapturing })
        #expect(h.notices == ["capture failed: screen recording is not permitted"])
        #expect(h.store.notes.isEmpty)
        #expect(h.gesture.sessionEndedCount == 1)
    }

    @Test("While capture is off a drag starts nothing, and the tap is always released")
    func blockedGesture() async {
        let h = Harness()
        defer { h.cleanUp() }
        h.missingPermissions = [.microphone]
        h.coordinator.sync()

        h.coordinator.handle([.attemptedWhileDisabled])
        #expect(h.notices == ["capture is off: needs permission: microphone"])

        // Should the recognizer ever report a drag anyway, nothing is shown
        // and it is reset when the drag and the hold end.
        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        #expect(!h.coordinator.isCapturing)
        #expect(h.overlay.presentedOn.isEmpty)
        h.coordinator.handle([.selectionEnded(rect: Harness.selection)])
        h.coordinator.handle([.holdEnded])
        #expect(h.gesture.sessionEndedCount == 2)
    }

    @Test("A second capture works after the first, and its node does not land on top")
    func consecutiveCaptures() async throws {
        let h = Harness(tidier: nil)
        defer { h.cleanUp() }
        await h.makeReady()

        for _ in 0..<2 {
            await h.dragSelection()
            await h.releaseAndWaitForEditor()
            try #require(h.model).onSave()
            #expect(!h.coordinator.isCapturing)
        }

        #expect(h.store.notes.count == 2)
        #expect(h.recorders.count == 2)
        let allStopped = h.recorders.allSatisfy { $0.stopped }
        #expect(allStopped)
        // The second card sits beside the first, one gap away, not on it.
        let first = h.canvas.frame(of: h.store.notes[0])
        let second = h.canvas.frame(of: h.store.notes[1])
        #expect(!CanvasLayout.crowds(first, second))
        #expect(second.minX == first.minX || second.minY == first.minY)
        let apart = max(
            second.minX - first.maxX, first.minX - second.maxX, second.minY - first.maxY, first.minY - second.maxY)
        #expect(apart == CanvasLayout.gap)
        // Both are new until someone has looked at them.
        #expect(h.store.unseenNotes.count == 2)
        // Both overlays are gone once the last fade finishes.
        #expect(await h.waitUntil { h.overlay.dismissed >= 1 })
    }

    @Test("A capture is saved onto today's board, whichever board is on screen")
    func savesToToday() async throws {
        let h = Harness(tidier: nil)
        defer { h.cleanUp() }
        await h.makeReady()
        let today = h.canvas.today

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        try #require(h.model).onSave()
        #expect(h.store.notes(in: today).count == 1)

        // Looking at last month when the next one is saved.
        h.canvas.show(Period.containing(Date().addingTimeInterval(-40 * 86_400), scale: .month, calendar: h.store.calendar))
        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        try #require(h.model).onSave()

        let saved = h.store.notes(in: today)
        #expect(saved.count == 2)
        // Still looking at last month; the new card is beside the first on today's board.
        #expect(h.canvas.timeScale == .month)
        #expect(!CanvasLayout.crowds(h.canvas.frame(of: saved[0]), h.canvas.frame(of: saved[1])))
        #expect(h.store.unseenNotes.count == 2)
    }

    @Test("A capture with no link to offer is saved without one")
    func noSourceLink() async throws {
        let h = Harness(tidier: nil)
        defer { h.cleanUp() }
        h.sourceLink = nil
        await h.makeReady()
        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        try #require(h.model).onSave()
        #expect(h.store.notes.first?.sourceURL == nil)
        #expect(h.store.notes.first?.sourceApp == "Safari")
    }

    @Test("A new note lands in the middle of what the canvas is showing")
    func placementFollowsViewport() async throws {
        let h = Harness(tidier: nil)
        defer { h.cleanUp() }
        await h.makeReady()

        h.canvas.setViewSize(CGSize(width: 1000, height: 700))
        h.canvas.pan(by: CGSize(width: -300, height: 120))

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        try #require(h.model).onSave()

        let note = try #require(h.store.notes.first)
        let centre = h.canvas.visibleCentre
        let expectedX = Double((centre.x - CanvasModel.nodeWidth / 2).rounded())
        #expect(note.position.x == expectedX)
        // Horizontally centred: the node's middle is the view's middle.
        #expect(h.canvas.viewPoint(for: CGPoint(x: note.position.x + 200, y: 0)).x == 500)
    }

    // MARK: Pasted and dropped

    /// A picture as it comes off the clipboard or out of a drop.
    private func picture(width: Int = 600, height: Int = 400, droppedAt point: CGPoint? = nil) -> StagedItem {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.5, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return StagedItem(
            kind: .image, image: CapturedImage(cgImage: context.makeImage()!, scale: 2),
            sourceURL: "file:///Users/someone/Pictures/chart.png", origin: "Picture", title: "chart.png",
            boardPoint: point)
    }

    @Test("Something pasted is shown in the middle with the microphone on, Return ends the talking, and it is saved with where it came from")
    func stagedFlow() async throws {
        let h = Harness(tidier: StubTidier(output: { _ in "I think this is worth reading twice." }))
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.stage([picture()])
        let model = try #require(h.model)
        #expect(h.coordinator.isCapturing)
        #expect(h.overlay.presentedOn == [7])
        #expect(h.overlay.mouseCaptured)
        // No key is held, so the overlay has the keyboard from the start.
        #expect(h.overlay.keyboardTaken >= 1)
        // And the gesture is off while it is up.
        #expect(h.gesture.enabled == false)
        #expect(model.image?.cgImage.width == 600)
        #expect(await h.waitUntil { model.phase == .speaking && model.lifted })
        #expect(model.speakingHint != nil)
        #expect(model.liftedImageFrame.midX == 720)
        #expect(await h.waitUntil { h.recorders.first?.started == true })
        #expect(await h.waitUntil { model.interimText == "words so far" })

        // A Return still held down from the input box is swallowed and changes nothing.
        #expect(h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: false, isRepeat: true))
        #expect(model.phase == .speaking)
        #expect(h.recorders.first?.stopped == false)

        // A fresh Return ends the talking.
        #expect(h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: false))
        #expect(await h.waitUntil { model.phase == .editing })
        #expect(h.recorders.first?.stopped == true)
        #expect(model.editorText == "I think this is worth reading twice.")

        // Command-Return saves, as for any capture.
        #expect(h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true))
        #expect(!h.coordinator.isCapturing)
        let note = try #require(h.store.notes.first)
        #expect(h.store.notes.count == 1)
        #expect(note.note == "I think this is worth reading twice.")
        #expect(note.sourceURL == "file:///Users/someone/Pictures/chart.png")
        #expect(note.sourceApp == "Picture" && note.windowTitle == "chart.png")
        #expect(note.imagePixelSize == PixelSize(width: 600, height: 400))
        #expect(!note.seen)
        // The gesture is back.
        #expect(h.gesture.enabled == true)
        #expect(await h.waitUntil { h.overlay.dismissed == 1 })
    }

    @Test("Clicking the pill ends the talking too")
    func stagedPillClick() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.stage([picture()])
        let model = try #require(h.model)
        #expect(await h.waitUntil { model.phase == .speaking })
        let finish = try #require(model.onFinishSpeaking)
        finish()
        #expect(await h.waitUntil { model.phase == .editing })
    }

    @Test("Escape drops something pasted, and nothing is saved")
    func stagedEscape() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.stage([picture()])
        let model = try #require(h.model)
        #expect(await h.waitUntil { model.phase == .speaking })
        #expect(h.coordinator.handleKey(keyCode: KeyCode.escape, command: false))
        #expect(!h.coordinator.isCapturing)
        #expect(h.store.notes.isEmpty)
        #expect(await h.waitUntil { h.recorders.first?.stopped == true })
        #expect(h.gesture.enabled == true)
    }

    @Test("Several things pasted together are spoken about one after another")
    func stagedQueue() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.stage([picture(width: 600), picture(width: 900)])
        #expect(h.coordinator.waitingCount == 1)
        let first = try #require(h.model)
        #expect(first.image?.cgImage.width == 600)
        #expect(await h.waitUntil { first.phase == .speaking })
        _ = h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: false)
        #expect(await h.waitUntil { first.phase == .editing })
        _ = h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true)

        // The first has closed; the second takes its turn.
        #expect(await h.waitUntil { h.model != nil && h.model !== first })
        let second = try #require(h.model)
        #expect(second.image?.cgImage.width == 900)
        #expect(h.coordinator.waitingCount == 0)
        #expect(await h.waitUntil { second.phase == .speaking })
        // Dropping the second leaves the first saved and nothing waiting.
        _ = h.coordinator.handleKey(keyCode: KeyCode.escape, command: false)
        #expect(h.store.notes.count == 1)
        #expect(await h.waitUntil { h.overlay.dismissed == 2 })
        #expect(!h.coordinator.isCapturing)
    }

    @Test("A drag does not start a capture over something pasted")
    func stagedIgnoresTheGesture() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()

        h.coordinator.stage([picture()])
        let model = try #require(h.model)
        #expect(await h.waitUntil { model.phase == .speaking })

        h.coordinator.handle([
            .selectionBegan(rect: CGRect(x: 100, y: 120, width: 40, height: 30), display: Harness.display)
        ])
        h.coordinator.handle([.selectionChanged(rect: Harness.selection)])
        h.coordinator.handle([.selectionEnded(rect: Harness.selection)])
        h.coordinator.handle([.holdEnded])
        h.coordinator.handle([.escapePressed])

        // Still the same thing on screen, still being spoken about.
        #expect(h.model === model)
        #expect(model.phase == .speaking)
        #expect(model.image?.cgImage.width == 600)
        #expect(h.recorders.count == 1)
        // And the availability check on its timer does not switch the gesture back on.
        h.coordinator.sync()
        #expect(h.gesture.enabled == false)
    }

    @Test("With no speech engine ready, something pasted goes straight to the editor to be typed about")
    func stagedWithoutAnEngine() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        // The engine has not been loaded.
        h.coordinator.sync()

        h.coordinator.stage([picture()])
        let model = try #require(h.model)
        #expect(await h.waitUntil { model.phase == .editing })
        #expect(model.notice?.contains("speech engine") == true)
        #expect(h.recorders.first?.started != true)

        model.editorText = "Typed instead."
        #expect(h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true))
        let note = try #require(h.store.notes.first)
        #expect(note.note == "Typed instead.")
        #expect(note.engine == "none")
    }

    @Test("A picture dropped on today's board is saved where it was dropped")
    func stagedDropPlacement() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()
        h.canvas.setViewSize(CGSize(width: 1400, height: 900))

        // Well away from the middle of the window, which is where a capture would go.
        let point = CGPoint(x: -380, y: 240)
        h.coordinator.stage([picture(droppedAt: point)])
        let model = try #require(h.model)
        #expect(await h.waitUntil { model.phase == .speaking })
        _ = h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: false)
        #expect(await h.waitUntil { model.phase == .editing })
        _ = h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true)

        let note = try #require(h.store.notes.first)
        let frame = h.canvas.frame(of: note)
        #expect(frame.contains(point))
        #expect(abs(frame.midX - point.x) < 1 && abs(frame.midY - point.y) < 1)
    }

    // MARK: With a canvas in front

    @Test("With a canvas in front, a capture lands on it and on today's board, each in a place of its own")
    func captureOntoACanvas() async throws {
        let h = Harness(tidier: StubTidier(output: { _ in "I think this is worth reading twice." }))
        defer { h.cleanUp() }
        await h.makeReady()
        h.canvas.setViewSize(CGSize(width: 1400, height: 900))
        let project = h.store.addProject(name: "Thesis")
        let target = try #require(h.store.addCanvas(in: project.id, name: "Outline"))
        h.canvas.show(.canvas(target.id))
        h.canvas.pan(by: CGSize(width: -3000, height: -2000))

        await h.dragSelection()
        await h.releaseAndWaitForEditor()
        // The editor says where it is going, since the overlay hides the window.
        #expect(h.model?.statusLine == "parakeet-tdt-v2  ·  tidied  ·  to Thesis / Outline")
        #expect(h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true))

        let note = try #require(h.store.notes.first)
        // On the canvas, in the window that was showing it.
        let placed = try #require(h.store.notes(on: target.id).first)
        #expect(placed.id == note.id)
        let visible = try #require(h.canvas.visibleRect)
        #expect(visible.contains(h.canvas.frame(of: placed)))
        // And on today's board, somewhere else entirely.
        #expect(h.store.notes(in: h.canvas.today).map(\.id) == [note.id])
        #expect(note.position != placed.position)
        #expect(h.canvas.board == .canvas(target.id))
    }

    @Test("A picture dropped on a canvas is put where it was dropped on that canvas")
    func dropOntoACanvas() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()
        h.canvas.setViewSize(CGSize(width: 1400, height: 900))
        let project = h.store.addProject(name: "Thesis")
        let target = try #require(h.store.addCanvas(in: project.id, name: "Outline"))
        h.canvas.show(.canvas(target.id))

        let point = CGPoint(x: -420, y: 260)
        h.coordinator.stage([picture(droppedAt: point)])
        let model = try #require(h.model)
        #expect(await h.waitUntil { model.phase == .speaking })
        _ = h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: false)
        #expect(await h.waitUntil { model.phase == .editing })
        _ = h.coordinator.handleKey(keyCode: KeyCode.returnKey, command: true)

        let placed = try #require(h.store.notes(on: target.id).first)
        let frame = h.canvas.frame(of: placed)
        #expect(abs(frame.midX - point.x) < 1 && abs(frame.midY - point.y) < 1)
        // Its place on today's board was not taken from the drop.
        let onItsDay = try #require(h.store.notes(in: h.canvas.today).first)
        #expect(onItsDay.id == placed.id && onItsDay.position != placed.position)
    }

    // MARK: Typed and dictated in the input box

    @Test("Words from the input box are saved as a note on today's board, with nothing spoken")
    func typedNote() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()
        h.canvas.setViewSize(CGSize(width: 1400, height: 900))

        h.coordinator.saveDirectly([], text: "  compare the two pricing tables ")
        let note = try #require(h.store.notes.first)
        #expect(note.note == "compare the two pricing tables")
        #expect(note.sourceApp == "Typed" && note.engine == "none" && note.sourceURL == nil)
        // Written in the window on the board it landed on: nothing new about it.
        #expect(note.seen)
        // Its card is the words alone: no picture, so it is a short card.
        #expect(note.isTextOnly)
        #expect(h.canvas.frame(of: note).height < 90)
        let withPicture = NodeLayout.estimatedHeight(imageAspectRatio: 640.0 / 84.0, note: note.note)
        #expect(h.canvas.frame(of: note).height < withPicture - 40)
        #expect(h.store.notes(in: h.canvas.today).count == 1)
        #expect(!h.coordinator.isCapturing && h.overlay.presentedOn.isEmpty && h.recorders.isEmpty)
        // No words and nothing attached: no note.
        h.coordinator.saveDirectly([], text: "   ")
        #expect(h.store.notes.count == 1)
    }

    @Test("Things attached in the input box are saved with what was written, each keeping where it came from, on the canvas in front")
    func attachedWithWords() async throws {
        let h = Harness()
        defer { h.cleanUp() }
        await h.makeReady()
        h.canvas.setViewSize(CGSize(width: 1400, height: 900))
        let project = h.store.addProject(name: "Thesis")
        let target = try #require(h.store.addCanvas(in: project.id, name: "Outline"))
        h.canvas.show(.canvas(target.id))

        h.coordinator.saveDirectly([picture(), picture(width: 900)], text: "both of these")
        #expect(h.store.notes.count == 2)
        #expect(h.store.notes.allSatisfy { $0.note == "both of these" })
        #expect(h.store.notes.allSatisfy { $0.sourceURL == "file:///Users/someone/Pictures/chart.png" })
        let placed = h.store.notes(on: target.id)
        #expect(placed.count == 2)
        #expect(!CanvasLayout.crowds(h.canvas.frame(of: placed[0]), h.canvas.frame(of: placed[1])))
    }

    @Test("Dictating into the input box hands over what is heard as it comes, and the tidied whole at the end")
    func dictation() async throws {
        let h = Harness(tidier: StubTidier(output: { _ in "I think this is worth reading twice." }))
        defer { h.cleanUp() }
        // No engine yet: nothing starts.
        #expect(!h.coordinator.startDictation { _ in })
        await h.makeReady()

        var heard: [String] = []
        #expect(h.coordinator.startDictation { heard.append($0) })
        #expect(h.coordinator.isDictating)
        #expect(h.coordinator.dictationMeter != nil)
        // A second start while one is running does nothing.
        #expect(!h.coordinator.startDictation { _ in })
        #expect(await h.waitUntil { heard.last == "words so far" })

        let said = await h.coordinator.stopDictation()
        #expect(said == "I think this is worth reading twice.")
        #expect(!h.coordinator.isDictating)
        #expect(h.recorders.first?.stopped == true)
        #expect(await h.coordinator.stopDictation() == nil)

        // A capture takes the microphone over.
        #expect(h.coordinator.startDictation { _ in })
        await h.dragSelection()
        #expect(!h.coordinator.isDictating)
    }
}
