import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

/// The most recent microphone level, shared between the audio thread that
/// measures it and the UI that draws the waveform.
public final class LevelMeter: Sendable {
    private let storage = OSAllocatedUnfairLock<Float>(initialState: 0)

    public init() {}

    /// 0 is silence, 1 is full scale.
    public var level: Float { storage.withLock { $0 } }

    public func set(_ level: Float) {
        storage.withLock { $0 = min(max(level, 0), 1) }
    }

    /// Maps an RMS amplitude onto 0…1 over a 50 dB range, which is roughly
    /// the span between room noise and close speech on a laptop microphone.
    public func push(rms: Float) {
        let decibels = 20 * log10(max(rms, 1e-7))
        set((decibels + 55) / 50)
    }

    public func reset() { set(0) }
}

public enum RecorderError: LocalizedError, Equatable {
    case notAuthorized
    case noInputDevice
    case unsupportedFormat
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .notAuthorized: "Microphone access has not been granted."
        case .noInputDevice: "No microphone is connected."
        case .unsupportedFormat: "The microphone's audio format is not supported."
        case .engine(let message): "The microphone could not be started: \(message)"
        }
    }
}

/// Records the default microphone and delivers it as 16 kHz mono Float32,
/// the format both transcription engines are fed from.
///
/// Recording never stops on its own: there is no silence detection and no
/// time limit. It runs from `start` until `stop`.
public final class AudioRecorder: @unchecked Sendable {

    public typealias Sink = @Sendable ([Float]) -> Void

    public static let sampleRate: Double = 16_000

    public let meter = LevelMeter()

    private struct TapState {
        var converter: AVAudioConverter?
        var sink: Sink?
        var sampleCount = 0
    }

    private let queue = DispatchQueue(label: "blog.terminal.audio", qos: .userInteractive)
    private let tapState = OSAllocatedUnfairLock<TapState>(uncheckedState: TapState())
    private let targetFormat: AVAudioFormat
    private static let log = Logger(subsystem: "blog.terminal.app", category: "audio")

    // Confined to `queue`.
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?

    public init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false)!
    }

    /// Starts recording. Throws when there is no usable microphone, in which
    /// case the caller should fall back to a typed note.
    public func start(sink: @escaping Sink) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(sink: sink)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Stops recording and returns how many seconds of audio were delivered.
    @discardableResult
    public func stop() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.stopOnQueue()) }
        }
    }

    // MARK: Queue-confined

    private func startOnQueue(sink: @escaping Sink) throws {
        if engine != nil { _ = stopOnQueue() }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.notAuthorized
        }
        guard Self.hasInputDevice() else { throw RecorderError.noInputDevice }

        // A fresh engine each time binds to whatever the default input is now.
        let engine = AVAudioEngine()
        meter.reset()
        tapState.withLockUnchecked { $0 = TapState(converter: nil, sink: sink, sampleCount: 0) }
        try installTap(on: engine)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            tapState.withLockUnchecked { $0 = TapState() }
            throw RecorderError.engine(error.localizedDescription)
        }
        self.engine = engine

        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.handleConfigurationChange() }
        }
    }

    private func installTap(on engine: AVAudioEngine) throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noInputDevice }
        guard let converter = Self.makeConverter(from: format, to: targetFormat) else {
            throw RecorderError.unsupportedFormat
        }
        tapState.withLockUnchecked { $0.converter = converter }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.process(buffer)
        }
    }

    private func stopOnQueue() -> TimeInterval {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        // Drain what the resampler is still holding, then detach the sink.
        let (tail, sink, count) = tapState.withLockUnchecked { state -> ([Float], Sink?, Int) in
            var tail: [Float] = []
            if let converter = state.converter {
                tail = Self.convert(nil, with: converter, to: targetFormat)
            }
            let result = (tail, state.sink, state.sampleCount + tail.count)
            state = TapState()
            return result
        }
        if !tail.isEmpty { sink?(tail) }
        meter.reset()
        return Double(count) / Self.sampleRate
    }

    /// The input device or its format changed mid-recording (headphones
    /// plugged in, for example). The engine has stopped; carry on with the new device.
    private func handleConfigurationChange() {
        guard let engine else { return }
        Self.log.notice("audio configuration changed; restarting input")
        do {
            try installTap(on: engine)
            engine.prepare()
            try engine.start()
        } catch {
            Self.log.error("could not restart audio input: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Audio thread

    private func process(_ input: AVAudioPCMBuffer) {
        if let channel = input.floatChannelData?[0], input.frameLength > 0 {
            var rms: Float = 0
            vDSP_rmsqv(channel, 1, &rms, vDSP_Length(input.frameLength))
            meter.push(rms: rms)
        }
        let (chunk, sink) = tapState.withLockUnchecked { state -> ([Float], Sink?) in
            guard let converter = state.converter else { return ([], nil) }
            let chunk = Self.convert(input, with: converter, to: targetFormat)
            state.sampleCount += chunk.count
            return (chunk, state.sink)
        }
        if !chunk.isEmpty { sink?(chunk) }
    }

    /// A converter from the microphone's format to the 16 kHz mono target.
    static func makeConverter(from format: AVAudioFormat, to target: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: format, to: target) else { return nil }
        if format.channelCount > 1 {
            // Take the first input channel instead of relying on a default downmix,
            // which is undefined for interfaces with many inputs.
            converter.channelMap = [0]
        }
        return converter
    }

    /// Runs one buffer through the converter. Passing `nil` signals the end
    /// of the stream and returns whatever the resampler still holds.
    static func convert(_ input: AVAudioPCMBuffer?, with converter: AVAudioConverter, to format: AVAudioFormat)
        -> [Float]
    {
        let ratio = format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }

        let source = UncheckedBox(input)
        let provided = OSAllocatedUnfairLock(initialState: false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            guard let buffer = source.value else {
                outStatus.pointee = .endOfStream
                return nil
            }
            let alreadyProvided = provided.withLock { flag -> Bool in
                defer { flag = true }
                return flag
            }
            if alreadyProvided {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let data = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    // MARK: Devices

    /// Whether the system currently has a default input device.
    public static func hasInputDevice() -> Bool {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return status == noErr && deviceID != kAudioObjectUnknown
    }
}
