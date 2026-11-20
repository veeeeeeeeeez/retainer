import FluidAudio
import Foundation
import os

/// Parakeet TDT v2 (English) running on-device through FluidAudio's Core ML models.
///
/// The model is fetched from Hugging Face the first time it is needed and
/// cached under `~/Library/Application Support/FluidAudio/Models`. That
/// download is the only network access the app makes for this engine.
public actor ParakeetEngine: TranscriptionEngine {

    public nonisolated let id = EngineID.parakeet

    private var manager: AsrManager?
    private var preparation: Task<EngineState, Never>?
    private static let log = Logger(subsystem: "blog.terminal.app", category: "parakeet")

    public init() {}

    /// Whether the model files are already on disk.
    public nonisolated static var isModelCached: Bool {
        AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2)
    }

    public func prepare(onState: @escaping @Sendable (EngineState) -> Void) async {
        if manager != nil {
            onState(.ready)
            return
        }
        // Concurrent callers share one download.
        if let preparation {
            onState(await preparation.value)
            return
        }
        let task = Task { await self.load(onState: onState) }
        preparation = task
        let result = await task.value
        preparation = nil
        onState(result)
    }

    private func load(onState: @escaping @Sendable (EngineState) -> Void) async -> EngineState {
        // With the files already on disk the same callbacks still fire; only
        // report a download when one is actually happening.
        let cached = Self.isModelCached
        onState(cached ? .loading : .downloading(0))
        do {
            let models = try await AsrModels.downloadAndLoad(version: .v2) { progress in
                switch progress.phase {
                case .listing:
                    if !cached { onState(.downloading(0)) }
                case .downloading:
                    // FluidAudio gives the download the first half of its overall
                    // fraction and the Core ML compile the second half.
                    if !cached { onState(.downloading(min(1, progress.fractionCompleted * 2))) }
                case .compiling:
                    onState(.loading)
                }
            }
            onState(.loading)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)

            // The first inference pays for Core ML's lazy setup. Spend that
            // now on a second of silence rather than on the first real note.
            var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            _ = try? await manager.transcribe(
                [Float](repeating: 0, count: ParakeetSession.sampleRate), decoderState: &state)

            self.manager = manager
            return .ready
        } catch {
            Self.log.error("parakeet load failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    public func startSession(onInterim: @escaping @Sendable (String) -> Void) async throws -> any TranscriptionSession {
        guard let manager else { throw EngineError.notReady }
        let session = ParakeetSession(manager: manager, onInterim: onInterim)
        await session.startInterimUpdates()
        return session
    }
}

/// One capture's worth of audio for Parakeet.
///
/// Parakeet is a batch model: the final transcript comes from a single pass
/// over everything that was said, run when the session finishes. While the
/// recording is still going, the most recent stretch is re-decoded about once
/// a second so there are words to show under the image. The model runs far
/// faster than real time, so that costs little.
actor ParakeetSession: TranscriptionSession {

    static let sampleRate = 16_000
    /// The model's single-window input length; interim passes never exceed it.
    private static let interimWindowSamples = 15 * sampleRate
    /// FluidAudio rejects anything under 0.3 s.
    private static let minimumSamples = Int(0.3 * Double(sampleRate)) + 1
    /// Below this there is nothing a person could have said.
    private static let negligibleSamples = Int(0.15 * Double(sampleRate))

    private let manager: AsrManager
    private let onInterim: @Sendable (String) -> Void
    private var samples: [Float] = []
    private var interimTask: Task<Void, Never>?
    private var samplesAtLastInterim = 0

    init(manager: AsrManager, onInterim: @escaping @Sendable (String) -> Void) {
        self.manager = manager
        self.onInterim = onInterim
    }

    func startInterimUpdates() {
        guard interimTask == nil else { return }
        interimTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard !Task.isCancelled, let self else { return }
                await self.publishInterim()
            }
        }
    }

    private func publishInterim() async {
        // Only decode when at least half a second of new audio has arrived.
        guard samples.count - samplesAtLastInterim >= Self.sampleRate / 2,
            samples.count >= Self.minimumSamples
        else { return }
        samplesAtLastInterim = samples.count

        let truncated = samples.count > Self.interimWindowSamples
        let window = truncated ? Array(samples.suffix(Self.interimWindowSamples)) : samples
        guard let text = try? await decode(window), !Task.isCancelled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onInterim(truncated ? "… " + trimmed : trimmed)
    }

    func append(_ chunk: [Float]) {
        samples.append(contentsOf: chunk)
    }

    func finish() async throws -> String {
        await stopInterimUpdates()
        guard samples.count > Self.negligibleSamples else { return "" }
        var audio = samples
        if audio.count < Self.minimumSamples {
            audio.append(contentsOf: [Float](repeating: 0, count: Self.minimumSamples - audio.count))
        }
        return try await decode(audio).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() async {
        await stopInterimUpdates()
        samples.removeAll()
    }

    /// Waits for any interim pass in flight, so the model is never asked to
    /// run two transcriptions at once.
    private func stopInterimUpdates() async {
        guard let task = interimTask else { return }
        interimTask = nil
        task.cancel()
        await task.value
    }

    private func decode(_ audio: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        return try await manager.transcribe(audio, decoderState: &state).text
    }
}
