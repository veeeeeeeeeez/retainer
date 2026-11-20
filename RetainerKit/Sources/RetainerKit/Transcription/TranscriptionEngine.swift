import Foundation

/// The on-device speech engines. The raw value is what gets stored with each
/// note, so the two can be compared later.
public enum EngineID: String, Codable, Sendable, CaseIterable, Identifiable {
    case parakeet = "parakeet-tdt-v2"
    case speechAnalyzer = "apple-speechanalyzer"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeet: "Parakeet TDT v2"
        case .speechAnalyzer: "Apple SpeechAnalyzer"
        }
    }

    public static let `default` = EngineID.parakeet
}

/// Where an engine is on the way to being usable.
public enum EngineState: Sendable, Equatable {
    /// Nothing has been attempted yet.
    case idle
    /// Cannot be used on this Mac; the string says why.
    case unavailable(String)
    /// Fetching the speech model. The value is 0…1.
    case downloading(Double)
    /// The model is on disk and being loaded.
    case loading
    case ready
    case failed(String)

    public var isReady: Bool { self == .ready }

    /// A short lowercase description for status lines and the menu.
    public var summary: String {
        switch self {
        case .idle: "not loaded"
        case .unavailable(let reason): "unavailable: \(reason)"
        case .downloading(let fraction): "downloading model \(Int((fraction * 100).rounded()))%"
        case .loading: "loading model"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }
}

public enum EngineError: LocalizedError {
    case notReady
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notReady: "The speech model is not loaded yet."
        case .unavailable(let reason): reason
        }
    }
}

/// One way of turning speech into text. Both engines sit behind this, so the
/// capture flow never knows which is in use.
public protocol TranscriptionEngine: Sendable {
    var id: EngineID { get }

    /// Downloads the model if needed and loads it, reporting progress.
    /// Safe to call again; it returns quickly once the engine is ready.
    func prepare(onState: @escaping @Sendable (EngineState) -> Void) async

    /// Opens a session for one capture.
    ///
    /// - Parameter onInterim: Called with the full text so far whenever the
    ///   engine has a new interim result. Engines without interim results
    ///   never call it.
    func startSession(onInterim: @escaping @Sendable (String) -> Void) async throws -> any TranscriptionSession
}

/// The transcription of a single capture.
public protocol TranscriptionSession: Sendable {
    /// Feeds 16 kHz mono Float32 samples, in order.
    func append(_ samples: [Float]) async
    /// Ends the input and returns the final transcript.
    func finish() async throws -> String
    /// Abandons the session.
    func cancel() async
}
