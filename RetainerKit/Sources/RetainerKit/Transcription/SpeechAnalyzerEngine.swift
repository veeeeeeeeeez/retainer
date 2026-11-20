import AVFoundation
import Foundation
import Speech
import os

/// Apple's on-device `SpeechAnalyzer` with a `SpeechTranscriber` module.
///
/// Requires macOS 26. The language model for the current locale is managed by
/// the system and downloaded through `AssetInventory` if it is not installed.
@available(macOS 26.0, *)
public actor SpeechAnalyzerEngine: TranscriptionEngine {

    public nonisolated let id = EngineID.speechAnalyzer

    private var locale: Locale?
    private static let log = Logger(subsystem: "blog.terminal.app", category: "speechanalyzer")

    public init() {}

    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        // Volatile results are the interim words shown while speaking.
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])
    }

    public func prepare(onState: @escaping @Sendable (EngineState) -> Void) async {
        guard SpeechTranscriber.isAvailable else {
            onState(.unavailable("SpeechTranscriber is not supported on this Mac"))
            return
        }
        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let resolved else {
            onState(.unavailable("no supported language"))
            return
        }
        locale = resolved

        let transcriber = Self.makeTranscriber(locale: resolved)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed:
            onState(.ready)
        case .unsupported:
            onState(.unavailable("\(resolved.identifier) is not supported"))
        case .supported, .downloading:
            onState(.downloading(0))
            do {
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                        onState(.downloading(progress.fractionCompleted))
                    }
                    defer { observation.invalidate() }
                    try await request.downloadAndInstall()
                }
                onState(.ready)
            } catch {
                Self.log.error("asset install failed: \(error.localizedDescription, privacy: .public)")
                onState(.failed(error.localizedDescription))
            }
        @unknown default:
            onState(.unavailable("unknown asset status"))
        }
    }

    public func startSession(onInterim: @escaping @Sendable (String) -> Void) async throws -> any TranscriptionSession {
        guard let locale else { throw EngineError.notReady }
        let transcriber = Self.makeTranscriber(locale: locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.unavailable("SpeechAnalyzer reported no usable audio format")
        }
        let (inputs, builder) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: inputs)

        let session = SpeechAnalyzerSession(
            analyzer: analyzer, transcriber: transcriber, format: format, builder: builder, onInterim: onInterim)
        await session.startCollecting()
        return session
    }
}

@available(macOS 26.0, *)
actor SpeechAnalyzerSession: TranscriptionSession {

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private let onInterim: @Sendable (String) -> Void

    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    private var finalized = ""
    private var volatile = ""
    private var failure: (any Error)?
    private var collector: Task<Void, Never>?

    init(
        analyzer: SpeechAnalyzer,
        transcriber: SpeechTranscriber,
        format: AVAudioFormat,
        builder: AsyncStream<AnalyzerInput>.Continuation,
        onInterim: @escaping @Sendable (String) -> Void
    ) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.builder = builder
        self.onInterim = onInterim
        self.analyzerFormat = format
        self.sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false)!
        // The analyzer does no conversion of its own; hand it exactly the format it asked for.
        self.converter = sourceFormat == format ? nil : AVAudioConverter(from: sourceFormat, to: format)
    }

    func startCollecting() {
        guard collector == nil else { return }
        let results = transcriber.results
        collector = Task { [weak self] in
            do {
                for try await result in results {
                    await self?.absorb(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {
                await self?.record(error)
            }
        }
    }

    /// Finalized results arrive in order and are appended. A volatile result
    /// is the engine's current guess for what follows them, and is replaced
    /// each time.
    private func absorb(text: String, isFinal: Bool) {
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        let combined = (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty { onInterim(combined) }
    }

    private func record(_ error: any Error) {
        if !(error is CancellationError) { failure = error }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty,
            let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = source.floatChannelData?[0]
        else { return }
        samples.withUnsafeBufferPointer { pointer in
            channel.update(from: pointer.baseAddress!, count: samples.count)
        }
        source.frameLength = AVAudioFrameCount(samples.count)

        guard let converter else {
            builder.yield(AnalyzerInput(buffer: source))
            return
        }
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }

        let input = UncheckedBox(source)
        let provided = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            let alreadyProvided = provided.withLock { flag -> Bool in
                defer { flag = true }
                return flag
            }
            if alreadyProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input.value
        }
        guard status != .error, output.frameLength > 0 else { return }
        builder.yield(AnalyzerInput(buffer: output))
    }

    func finish() async throws -> String {
        builder.finish()
        do {
            // Returns once the remaining audio is consumed and its results are final.
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            record(error)
        }
        // The result stream ends when the analyzer finishes.
        await collector?.value
        collector = nil

        let text = finalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty, let failure { throw failure }
        return text
    }

    func cancel() async {
        builder.finish()
        collector?.cancel()
        collector = nil
        await analyzer.cancelAndFinishNow()
    }
}
