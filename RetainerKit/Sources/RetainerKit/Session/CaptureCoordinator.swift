import AppKit
import Foundation
import Observation
import SwiftUI
import os

/// Runs the capture gesture from end to end: selection, screenshot, recording,
/// transcription, tidy, the editor, and finally the saved note.
///
/// The event tap reports what the user did; this class decides what happens
/// next and keeps the overlay model in step. Everything here is on the main
/// actor. Slow work (the microphone, the screenshot, the speech engines, the
/// language model) is awaited, never blocked on.
///
/// A picture or a link that was pasted or dropped (`StagedItem`) comes in
/// half way: there is no selection and no screenshot, it is already the
/// picture. From there it is the same capture, except that no key is being
/// held, so Return says the talking is done where letting go of the trigger
/// would.
@MainActor
@Observable
public final class CaptureCoordinator {

    public enum Availability: Equatable, Sendable {
        case ready
        /// Capture is switched off; the string says why, in a few words.
        case blocked(String)
    }

    /// Whether an Option-drag will currently start a capture.
    public private(set) var availability: Availability = .blocked("starting up")

    /// True while a capture is on screen in any phase.
    public var isCapturing: Bool { session != nil }

    /// True while the microphone is on for the input box.
    public private(set) var isDictating = false
    /// How loud the microphone is while dictating, for the pill.
    var dictationMeter: LevelMeter? { dictation?.recorder.meter }
    @ObservationIgnored private var dictation: Dictation?

    /// The microphone and the engine at work for the input box.
    @MainActor
    private final class Dictation {
        let recorder: any AudioRecording
        var audio: AsyncStream<[Float]>.Continuation?
        var transcription: Task<String, any Error>?
        init(recorder: any AudioRecording) { self.recorder = recorder }
    }

    /// The overlay state of the capture in progress, if any.
    var currentModel: CaptureSessionModel? { session?.model }

    @ObservationIgnored private let config: CaptureConfig
    @ObservationIgnored private let engines: EngineManager
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: NoteStore
    @ObservationIgnored private let images: ImageCache
    @ObservationIgnored private let canvas: CanvasModel
    @ObservationIgnored private let tidy: TidyService
    @ObservationIgnored private let environment: CaptureEnvironment

    @ObservationIgnored private var tap: (any GestureControlling)?
    @ObservationIgnored private var session: Session?
    /// Pasted or dropped things waiting their turn: one is spoken about at a time.
    @ObservationIgnored private var waiting: [StagedItem] = []
    @ObservationIgnored private var closingToken: UUID?
    @ObservationIgnored private var watchdog: Timer?

    private static let log = Logger(subsystem: "blog.terminal.app", category: "capture")

    /// State of one capture, from the start of the drag until its card closes.
    @MainActor
    private final class Session {
        let model: CaptureSessionModel
        let display: DisplayInfo
        let source: SourceContext
        let previousApp: NSRunningApplication?
        let engineID: EngineID
        let tidyEnabled: Bool
        /// Each session records with its own recorder so a late stop from one
        /// capture can never cut off the next.
        let recorder: any AudioRecording

        var audio: AsyncStream<[Float]>.Continuation?
        var transcription: Task<String, any Error>?
        /// Screenshot, then the lift to the centre of the screen.
        var stage: Task<Void, Never>?
        var image: CapturedImage?
        var microphoneError: String?
        var holdEnded = false
        var editorShown = false
        var finished = false
        var rawTranscript = ""
        var tidyResult: TidyResult?
        /// A link to what the source app was showing, once it has been found.
        var sourceLink: String?
        /// What this capture is of, when it is not of the screen.
        var staged: StagedItem?
        /// Why there is no voice, when it is not the microphone's doing.
        var voiceNotice: String?

        init(
            model: CaptureSessionModel, display: DisplayInfo, source: SourceContext,
            previousApp: NSRunningApplication?, engineID: EngineID, tidyEnabled: Bool,
            recorder: any AudioRecording
        ) {
            self.model = model
            self.display = display
            self.source = source
            self.previousApp = previousApp
            self.engineID = engineID
            self.tidyEnabled = tidyEnabled
            self.recorder = recorder
        }
    }

    public convenience init(
        config: CaptureConfig = .standard,
        engines: EngineManager,
        settings: AppSettings,
        store: NoteStore,
        images: ImageCache,
        canvas: CanvasModel,
        permissions: PermissionsModel,
        tidy: TidyService
    ) {
        self.init(
            config: config, engines: engines, settings: settings, store: store, images: images,
            canvas: canvas, tidy: tidy, environment: .live(permissions: permissions))
    }

    init(
        config: CaptureConfig = .standard,
        engines: EngineManager,
        settings: AppSettings,
        store: NoteStore,
        images: ImageCache,
        canvas: CanvasModel,
        tidy: TidyService,
        environment: CaptureEnvironment
    ) {
        self.config = config
        self.engines = engines
        self.settings = settings
        self.store = store
        self.images = images
        self.canvas = canvas
        self.tidy = tidy
        self.environment = environment
        environment.overlay.keyHandler = { [weak self] keyCode, command, isRepeat in
            self?.handleKey(keyCode: keyCode, command: command, isRepeat: isRepeat) ?? false
        }
    }

    // MARK: Availability

    /// Brings the event tap and the enabled state in line with the current
    /// permissions and engine. Cheap; called on a timer and on every change.
    public func sync() {
        let accessibility = !environment.missingPermissions().contains(.accessibility)
        if accessibility, tap == nil {
            installTap()
        } else if !accessibility, let tap {
            // An active tap whose permission has been revoked stalls input
            // system-wide, so remove it at once.
            tap.stop()
            self.tap = nil
        }

        let current = computeAvailability()
        // The gesture is off while something pasted or dropped is on screen:
        // a drag then must not start a capture over the top of it.
        tap?.setEnabled(current == .ready && session?.staged == nil)
        if current != availability { availability = current }
    }

    private func installTap() {
        tap = environment.makeGestureControl(config) { [weak self] actions in
            // The main queue preserves the order the events happened in.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.handle(actions) }
            }
        }
        environment.reportTapFailure(tap == nil)
    }

    private func computeAvailability() -> Availability {
        let missing = environment.missingPermissions()
        if !missing.isEmpty {
            let names = missing.map { $0.title.lowercased() }.joined(separator: ", ")
            return .blocked("needs permission: \(names)")
        }
        if tap == nil {
            return .blocked("the event tap could not be installed")
        }
        if !engines.selectedState.isReady {
            return .blocked("speech engine \(engines.selectedState.summary)")
        }
        return .ready
    }

    public func shutdown() {
        tap?.stop()
        tap = nil
    }

    // MARK: Gesture actions

    func handle(_ actions: [GestureAction]) {
        for action in actions {
            // Something pasted or dropped is on screen. The gesture is
            // switched off for as long as it is, and anything of a gesture
            // that still arrives has nothing to do with it.
            if session?.staged != nil {
                switch action {
                case .selectionEnded, .selectionCancelled, .holdEnded: tap?.sessionEnded()
                case .selectionBegan, .selectionChanged, .escapePressed, .attemptedWhileDisabled: break
                }
                continue
            }
            switch action {
            case .selectionBegan(let rect, let display):
                beginSession(rect: rect, display: display)
            case .selectionChanged(let rect):
                if let session, session.model.phase == .selecting {
                    session.model.updateSelection(ScreenGeometry.localRect(rect, in: session.display.bounds))
                }
            case .selectionEnded(let rect):
                endSelection(rect: rect)
            case .selectionCancelled:
                if let session { finish(session) }
            case .holdEnded:
                guard let session, !session.holdEnded else {
                    // Nothing to finalise; let the gesture start over.
                    if session == nil { tap?.sessionEnded() }
                    continue
                }
                endHold(session)
            case .escapePressed:
                if let session { finish(session) }
            case .attemptedWhileDisabled:
                if case .blocked(let reason) = availability {
                    environment.showNotice("capture is off: \(reason)")
                }
            }
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        self.session === session && !session.finished
    }

    /// The talking is over: the trigger was let go, or for something pasted
    /// or dropped, Return was pressed.
    private func endHold(_ session: Session) {
        guard isCurrent(session), !session.holdEnded else { return }
        session.holdEnded = true
        stopWatchdog()
        Task { await self.finalize(session) }
    }

    // MARK: Phase 1: selection

    private func beginSession(rect: CGRect, display: DisplayInfo) {
        if let stale = session { finish(stale) }
        // One microphone at a time: a capture takes over from the input box.
        cancelDictation()

        guard availability == .ready,
            let engine = engines.readyEngine,
            let screen = environment.screenMetrics(display.id)
        else {
            // The recognizer will still report the end of this drag; with no
            // session to attach to, those reports reset it.
            return
        }

        let recorder = environment.makeRecorder()
        let model = CaptureSessionModel(
            screenSize: screen.size,
            selection: ScreenGeometry.localRect(rect, in: display.bounds),
            // Clear the Dock when it sits at the bottom of this display.
            pillBottomInset: screen.dockHeight + 24,
            meter: recorder.meter,
            config: config)
        let session = Session(
            model: model,
            display: display,
            source: environment.sourceContext(),
            previousApp: environment.frontmostApplication(),
            engineID: engines.selected,
            tidyEnabled: settings.tidyEnabled,
            recorder: recorder)
        model.onSave = { [weak self, weak session] in
            if let session { self?.save(session) }
        }
        model.onDiscard = { [weak self, weak session] in
            if let session { self?.finish(session) }
        }
        self.session = session
        closingToken = nil
        startWatchdog()

        // What the source window was showing, asked for now while that
        // window is still the one in front. The answer arrives in its own
        // time and is kept if this capture is still the current one.
        let lookUp = environment.sourceLink
        let source = session.source
        Task { [weak session] in
            let link = await lookUp(source)
            session?.sourceLink = link
        }

        environment.overlay.present(model: model, displayID: display.id)

        // Recording starts now, at the first moment of the drag.
        startListening(session, engine: engine)
        // The overlay is on screen now, so this app is in the shareable list
        // and can be excluded from the screenshot.
        let capturer = environment.capturer
        Task { await capturer.prefetch() }
    }

    /// Switches the microphone on and starts turning what it hears into
    /// words. Audio is buffered in the stream until the engine's session is
    /// open, so nothing said in between is lost.
    private func startListening(_ session: Session, engine: any TranscriptionEngine) {
        let model = session.model
        let recorder = session.recorder
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        session.audio = continuation
        Task {
            do {
                try await recorder.start { continuation.yield($0) }
                if !self.isCurrent(session) { await recorder.stop() }
            } catch {
                self.microphoneFailed(session, error: error)
            }
        }
        session.transcription = Task {
            let live = try await engine.startSession { text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { model.interimText = text }
                }
            }
            for await chunk in stream {
                await live.append(chunk)
            }
            if Task.isCancelled {
                await live.cancel()
                throw CancellationError()
            }
            return try await live.finish()
        }

        if session.tidyEnabled {
            let tidy = self.tidy
            Task { await tidy.prewarm() }
        }
    }

    // MARK: Typed and dictated in the input box

    /// Saves notes straight from the input box, with no talking step: what
    /// was typed (or dictated into the box) is the note. Each attached
    /// thing becomes a card with that note; with nothing attached, the words
    /// alone are the card.
    func saveDirectly(_ items: [StagedItem], text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var items = items
        if items.isEmpty {
            guard !text.isEmpty, let typed = StagedItem.typedNote() else { return }
            items = [typed]
        }
        for item in items { add(item, note: text) }
    }

    private func add(_ item: StagedItem, note text: String) {
        let image = item.image
        let id = UUID()
        let pixelSize = PixelSize(width: image.cgImage.width, height: image.cgImage.height)
        let aspect = Double(pixelSize.width) / Double(max(pixelSize.height, 1))
        let size = CGSize(
            width: CanvasModel.nodeWidth,
            height: NodeLayout.estimatedHeight(
                imageAspectRatio: aspect, note: text, hasSourceLink: item.sourceURL != nil,
                textOnly: item.kind == .text))
        let position = canvas.placementForNewNote(
            size: size, among: store.notes(in: canvas.today), near: item.boardPoint)
        var onCanvas: (id: UUID, position: CGPoint)?
        if let canvasID = canvas.canvasID, store.canvas(canvasID) != nil {
            onCanvas = (
                canvasID,
                canvas.placementOnScreen(size: size, among: store.notes(on: canvasID), near: item.boardPoint)
            )
        }
        // It was written in the window, on the board it lands on: it has been seen.
        let inFront = onCanvas != nil || (canvas.isShowingToday && !canvas.showingArchive)
        let note = Note(
            id: id, imagePath: NoteStore.imagePath(for: id), imagePixelSize: pixelSize,
            imageScale: Double(image.scale), note: text, rawTranscript: "", engine: "none", tidy: false,
            tidyOutcome: .off, timestamp: Date(), sourceApp: item.origin, windowTitle: item.title,
            sourceURL: item.sourceURL, position: CanvasPoint(position), seen: inFront)
        images.insert(image.cgImage, for: id)
        ImageFiles.write(image, to: store.imageURL(for: note))
        withAnimation(.easeOut(duration: 0.26)) {
            store.add(note)
            if let onCanvas {
                store.place(noteID: id, on: onCanvas.id, at: onCanvas.position)
                canvas.reveal(CGRect(origin: onCanvas.position, size: size))
            } else if inFront {
                canvas.reveal(CGRect(origin: position, size: size))
            }
        }
        if item.kind == .link { picturePage(of: id, link: item.sourceURL) }
    }

    /// A link's card starts as its address drawn out. Once the page it goes
    /// to has been loaded and pictured, that picture takes its place:
    /// softened, with the link sign in its corner.
    private func picturePage(of noteID: UUID, link: String?) {
        guard let link, let url = URL(string: link), url.scheme == "http" || url.scheme == "https" else { return }
        let snapshot = environment.pageSnapshot
        Task {
            guard let page = await snapshot(url), let card = LinkCard.compose(page: page),
                let note = self.store.note(noteID)
            else { return }
            self.images.remove(noteID)
            self.images.insert(card.cgImage, for: noteID)
            ImageFiles.write(card, to: self.store.imageURL(for: note))
            self.store.updateImage(
                id: noteID, pixelSize: PixelSize(width: card.cgImage.width, height: card.cgImage.height),
                scale: Double(card.scale))
        }
    }

    /// Switches the microphone on for the input box. What is heard so far is
    /// handed to `onInterim` as it comes. False if there is no engine ready
    /// or a capture is on screen.
    @discardableResult
    func startDictation(onInterim: @escaping @MainActor (String) -> Void) -> Bool {
        guard !isDictating, session == nil, let engine = engines.readyEngine else { return false }
        let state = Dictation(recorder: environment.makeRecorder())
        dictation = state
        isDictating = true
        let (stream, continuation) = AsyncStream<[Float]>.makeStream()
        state.audio = continuation
        let recorder = state.recorder
        Task {
            do {
                try await recorder.start { continuation.yield($0) }
            } catch {
                self.environment.showNotice("microphone unavailable: \(error.localizedDescription)")
                self.cancelDictation()
            }
        }
        state.transcription = Task {
            let live = try await engine.startSession { text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { onInterim(text) }
                }
            }
            for await chunk in stream { await live.append(chunk) }
            if Task.isCancelled {
                await live.cancel()
                throw CancellationError()
            }
            return try await live.finish()
        }
        if settings.tidyEnabled {
            let tidy = self.tidy
            Task { await tidy.prewarm() }
        }
        return true
    }

    /// Switches the microphone off and returns everything that was said,
    /// tidied if tidy is on. `nil` if nothing was being dictated.
    func stopDictation() async -> String? {
        guard let state = dictation else { return nil }
        dictation = nil
        await state.recorder.stop()
        state.audio?.finish()
        let raw = (try? await state.transcription?.value) ?? ""
        let result = await tidy.run(raw: raw, enabled: settings.tidyEnabled)
        isDictating = false
        return result.text
    }

    /// Switches the microphone off and throws away what was said.
    func cancelDictation() {
        guard let state = dictation else { return }
        dictation = nil
        isDictating = false
        state.audio?.finish()
        state.transcription?.cancel()
        let recorder = state.recorder
        Task { await recorder.stop() }
    }

    // MARK: Pasted and dropped

    /// Takes pictures and links that were pasted or dropped through the rest
    /// of a capture, one after another: each is shown in the middle of the
    /// screen with the microphone on, then its note is edited and saved.
    func stage(_ items: [StagedItem]) {
        guard !items.isEmpty else { return }
        waiting.append(contentsOf: items)
        // One at a time. If a capture of any kind is on screen, the next
        // starts when that one closes.
        if session == nil { stageNext() }
    }

    /// How many pasted or dropped things have yet to be spoken about.
    var waitingCount: Int { waiting.count }

    private func stageNext() {
        guard session == nil, !waiting.isEmpty else { return }
        let item = waiting.removeFirst()
        cancelDictation()
        guard let displayID = environment.mainDisplayID(), let screen = environment.screenMetrics(displayID) else {
            environment.showNotice("nowhere to show that: no display was found")
            waiting.removeAll()
            return
        }

        let recorder = environment.makeRecorder()
        let model = CaptureSessionModel(
            screenSize: screen.size, selection: .zero, pillBottomInset: screen.dockHeight + 24,
            meter: recorder.meter, config: config)
        model.image = item.image
        // It comes up a little small in the middle and settles to its size,
        // where a screenshot travels there from where it was taken.
        let resting = model.liftedImageFrame
        model.updateSelection(resting.insetBy(dx: resting.width * 0.04, dy: resting.height * 0.04))
        model.phase = .capturing
        model.speakingHint = "return when you have said it  ·  esc to drop it"

        let session = Session(
            model: model,
            display: DisplayInfo(id: displayID, bounds: CGRect(origin: .zero, size: screen.size)),
            source: SourceContext(appName: item.origin, windowTitle: item.title),
            previousApp: environment.frontmostApplication(),
            engineID: engines.selected,
            tidyEnabled: settings.tidyEnabled,
            recorder: recorder)
        session.staged = item
        session.image = item.image
        session.sourceLink = item.sourceURL
        model.onSave = { [weak self, weak session] in
            if let session { self?.save(session) }
        }
        model.onDiscard = { [weak self, weak session] in
            if let session { self?.finish(session) }
        }
        model.onFinishSpeaking = { [weak self, weak session] in
            if let session { self?.endHold(session) }
        }
        self.session = session
        closingToken = nil
        tap?.setEnabled(false)

        environment.overlay.present(model: model, displayID: displayID)
        environment.overlay.captureMouse()
        // No key is held, so the keyboard is the overlay's from the start:
        // Return ends the talking and Escape drops the thing.
        environment.overlay.takeKeyboard()

        if let engine = engines.readyEngine {
            startListening(session, engine: engine)
        } else {
            // No voice to be had. Straight to the editor, to type instead.
            session.microphoneError = "speech engine \(engines.selectedState.summary)"
            session.voiceNotice = "The speech engine is not ready (\(engines.selectedState.summary)). Type your note instead."
        }

        Task {
            await self.nextMainTurn()
            guard self.isCurrent(session) else { return }
            withAnimation(.easeOut(duration: self.config.liftDuration)) {
                model.lifted = true
                if model.phase == .capturing { model.phase = .speaking }
            }
            if session.microphoneError != nil {
                self.showEditor(session, text: "")
            }
        }
    }

    private func endSelection(rect: CGRect) {
        guard let session, isCurrent(session) else {
            tap?.sessionEnded()
            return
        }
        let model = session.model
        model.updateSelection(ScreenGeometry.localRect(rect, in: session.display.bounds))
        model.phase = .capturing

        let capturer = environment.capturer
        let selection = model.selection
        let displayID = session.display.id
        session.stage = Task {
            do {
                let image = try await capturer.capture(rect: selection, displayID: displayID)
                await self.lift(session, image: image)
            } catch {
                self.captureFailed(session, error: error)
            }
        }
    }

    // MARK: Phase 2: lift and speak

    private func lift(_ session: Session, image: CapturedImage) async {
        guard isCurrent(session) else { return }
        session.image = image
        let model = session.model
        model.image = image
        environment.overlay.captureMouse()

        // One turn of the run loop with the screenshot drawn exactly where it
        // was taken; the move to the centre then animates from there.
        await nextMainTurn()
        guard isCurrent(session) else { return }
        withAnimation(.easeOut(duration: config.liftDuration)) {
            model.lifted = true
            if model.phase == .capturing { model.phase = .speaking }
        }

        if session.microphoneError != nil {
            showEditor(session, text: "")
        }
    }

    private func captureFailed(_ session: Session, error: any Error) {
        guard isCurrent(session) else { return }
        Self.log.error("capture failed: \(error.localizedDescription, privacy: .public)")
        environment.showNotice("capture failed: \(error.localizedDescription)")
        finish(session)
    }

    private func microphoneFailed(_ session: Session, error: any Error) {
        guard isCurrent(session) else { return }
        Self.log.error("microphone unavailable: \(error.localizedDescription, privacy: .public)")
        session.microphoneError = error.localizedDescription
        session.audio?.finish()
        session.transcription?.cancel()
        if session.model.lifted {
            showEditor(session, text: "")
        }
    }

    // MARK: Phase 3: finalise, edit, save

    private func finalize(_ session: Session) async {
        guard isCurrent(session) else { return }
        await session.recorder.stop()
        session.audio?.finish()

        // Option can be released a moment before the screenshot arrives.
        await session.stage?.value
        guard isCurrent(session), session.image != nil, !session.editorShown else { return }

        let model = session.model
        model.processingLabel = "transcribing"
        withAnimation(.easeOut(duration: 0.15)) { model.phase = .processing }
        // Take the keyboard now so Escape works while this runs.
        environment.overlay.takeKeyboard()

        var raw = ""
        var failure: String?
        do {
            raw = try await session.transcription?.value ?? ""
        } catch is CancellationError {
        } catch {
            Self.log.error("transcription failed: \(error.localizedDescription, privacy: .public)")
            failure = "Transcription failed: \(error.localizedDescription)"
        }
        guard isCurrent(session), !session.editorShown else { return }
        session.rawTranscript = raw

        if session.tidyEnabled && !raw.isEmpty {
            model.processingLabel = "tidying"
        }
        let result = await tidy.run(raw: raw, enabled: session.tidyEnabled)
        guard isCurrent(session), !session.editorShown else { return }
        session.tidyResult = result

        if let failure { model.notice = failure }
        showEditor(session, text: result.text)
    }

    private func showEditor(_ session: Session, text: String) {
        guard isCurrent(session), !session.editorShown else { return }
        session.editorShown = true

        let model = session.model
        model.initialText = text
        model.editorText = text
        model.statusLine = statusLine(for: session)
        if let reason = session.microphoneError {
            model.notice = session.voiceNotice ?? "Microphone unavailable. \(reason) Type your note instead."
        }
        withAnimation(.easeOut(duration: 0.15)) { model.phase = .editing }

        // The trigger may still be down (no microphone): stop treating the
        // hold as a recording.
        stopWatchdog()
        tap?.suspend()
        environment.overlay.takeKeyboard()

        Task {
            // The text view is created during the next layout pass.
            for _ in 0..<6 {
                await self.nextMainTurn()
                guard self.isCurrent(session) else { return }
                model.editor.focus(atEnd: true)
                if model.editor.isFocused { return }
            }
        }
    }

    /// Where the card will go besides today's board, when a canvas is in
    /// front: said under the editor, since the overlay hides the window.
    private var destinationNote: String? {
        guard let target = store.canvas(canvas.canvasID) else { return nil }
        let project = store.project(target.projectID)?.name ?? "Project"
        return "to \(project) / \(target.name)"
    }

    private func statusLine(for session: Session) -> String {
        let said = spokenStatus(for: session)
        guard let destination = destinationNote else { return said }
        return said.isEmpty ? destination : "\(said)  ·  \(destination)"
    }

    private func spokenStatus(for session: Session) -> String {
        guard session.microphoneError == nil else { return "" }
        let engine = session.engineID.rawValue
        guard let result = session.tidyResult else { return engine }
        let tidy: String =
            switch result.outcome {
            case .off: "tidy off"
            case .applied: "tidied"
            case .empty: "nothing heard"
            case .unavailable: "tidy unavailable" + (result.detail.map { ": \($0)" } ?? "")
            case .timedOut: "tidy timed out, raw transcript"
            case .rejected: "tidy rejected" + (result.detail.map { " (\($0))" } ?? "") + ", raw transcript"
            case .failed: "tidy failed, raw transcript"
            }
        return "\(engine)  ·  \(tidy)"
    }

    private func save(_ session: Session) {
        guard isCurrent(session), session.editorShown, let image = session.image else { return }
        let model = session.model

        let id = UUID()
        let pixelSize = PixelSize(width: image.cgImage.width, height: image.cgImage.height)
        let aspect = Double(pixelSize.width) / Double(max(pixelSize.height, 1))
        // In clear space, as near the middle of the canvas window as there is room.
        let size = CGSize(
            width: CanvasModel.nodeWidth,
            height: NodeLayout.estimatedHeight(
                imageAspectRatio: aspect, note: model.editorText, hasSourceLink: session.sourceLink != nil))
        // A capture belongs to today, whichever board happens to be on screen.
        // Something dropped on today's board goes where it was dropped, or as
        // near as there is room.
        let position = canvas.placementForNewNote(
            size: size, among: store.notes(in: canvas.today), near: session.staged?.boardPoint)
        // With a canvas in front, the card lands on it as well: where it was
        // dropped, or in the middle of the window. It is a note saved today
        // like any other, so it is on today's board too, in a place of its own.
        var onCanvas: (id: UUID, position: CGPoint)?
        if let canvasID = canvas.canvasID, store.canvas(canvasID) != nil {
            onCanvas = (
                canvasID,
                canvas.placementOnScreen(
                    size: size, among: store.notes(on: canvasID), near: session.staged?.boardPoint)
            )
        }

        let typed = session.microphoneError != nil
        let note = Note(
            id: id,
            imagePath: NoteStore.imagePath(for: id),
            imagePixelSize: pixelSize,
            imageScale: Double(image.scale),
            note: model.editorText,
            rawTranscript: session.rawTranscript,
            engine: typed ? "none" : session.engineID.rawValue,
            tidy: session.tidyEnabled,
            tidyOutcome: session.tidyResult?.outcome ?? (session.tidyEnabled ? .empty : .off),
            timestamp: Date(),
            sourceApp: session.source.appName,
            windowTitle: session.source.windowTitle,
            sourceURL: session.sourceLink,
            position: CanvasPoint(position),
            // New until its card has been looked at in the window.
            seen: false)

        // The node can draw immediately from memory while the PNG is written.
        images.insert(image.cgImage, for: id)
        ImageFiles.write(image, to: store.imageURL(for: note))
        withAnimation(.easeOut(duration: 0.26)) {
            store.add(note)
            // If the only room was outside the window, scroll just far enough to show it.
            if let onCanvas {
                store.place(noteID: id, on: onCanvas.id, at: onCanvas.position)
                canvas.reveal(CGRect(origin: onCanvas.position, size: size))
            } else if canvas.isShowingToday, !canvas.showingArchive {
                canvas.reveal(CGRect(origin: position, size: size))
            }
        }
        if session.staged?.kind == .link { picturePage(of: id, link: session.sourceLink) }
        finish(session)
    }

    // MARK: Keys while the card has the keyboard

    func handleKey(keyCode: Int64, command: Bool, isRepeat: Bool = false) -> Bool {
        guard let session, isCurrent(session) else { return false }
        let model = session.model

        if keyCode == KeyCode.escape {
            guard model.phase == .editing else {
                finish(session)
                return true
            }
            // Mid-composition, Escape belongs to the input method.
            if model.editor.hasMarkedText { return false }
            if model.hasEdits && !model.discardArmed {
                model.discardArmed = true
                return true
            }
            finish(session)
            return true
        }

        let isReturn = keyCode == KeyCode.returnKey || keyCode == KeyCode.keypadEnter
        // Nothing is being held for something pasted or dropped, so Return
        // is what says the talking is done.
        if session.staged != nil, isReturn, model.phase == .speaking || model.phase == .capturing {
            // A Return still held down from the input box is the press that
            // sent the thing here, repeating. Only a fresh press counts.
            if !isRepeat { endHold(session) }
            return true
        }

        guard model.phase == .editing else { return false }
        if isReturn && command {
            save(session)
            return true
        }
        // Any other key means "keep editing", and is still typed.
        if model.discardArmed { model.discardArmed = false }
        return false
    }

    // MARK: Ending a session

    /// Ends a capture in any phase, saved or not: stops the microphone and the
    /// engines, closes the card and hands focus back.
    private func finish(_ session: Session) {
        guard !session.finished else { return }
        session.finished = true
        if self.session === session {
            self.session = nil
            stopWatchdog()
        }

        session.audio?.finish()
        session.transcription?.cancel()
        session.stage?.cancel()
        let recorder = session.recorder
        Task { await recorder.stop() }

        // Capturing may resume as soon as the trigger is pressed afresh.
        tap?.sessionEnded()
        if session.staged != nil { tap?.setEnabled(availability == .ready) }

        let token = UUID()
        closingToken = token
        withAnimation(.easeOut(duration: 0.16)) { session.model.phase = .closing }
        let previousApp = session.previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            MainActor.assumeIsolated {
                // A new capture may have started during the fade.
                guard let self, self.closingToken == token, self.session == nil else { return }
                self.environment.overlay.dismiss()
                self.restoreFocus(to: previousApp)
                // Anything else that was pasted or dropped takes its turn.
                self.stageNext()
            }
        }
    }

    /// The panel never activated this app, so focus normally falls back to the
    /// previous app by itself. This covers the case where it did not.
    private func restoreFocus(to app: NSRunningApplication?) {
        guard let app, !app.isTerminated, app != NSRunningApplication.current else { return }
        guard NSRunningApplication.current.isActive else { return }
        NSApplication.shared.yieldActivation(to: app)
        app.activate()
    }

    // MARK: Watchdog

    /// While a capture is being selected or spoken, checks a few times a
    /// second that Left Option really is still down. Normally the event tap
    /// reports the release the instant it happens and this finds nothing to
    /// do; it exists so that a lost event can never leave the overlay up and
    /// the microphone on.
    private func startWatchdog() {
        stopWatchdog()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tap?.verifyActiveGesture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    private func nextMainTurn() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
