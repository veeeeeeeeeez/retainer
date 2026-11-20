import Foundation
import Observation

/// Owns the two engines, remembers which one is selected, and tracks whether
/// each is ready to use.
@MainActor
@Observable
public final class EngineManager {

    public private(set) var states: [EngineID: EngineState]

    /// The engine used for new captures. Persisted across launches.
    public private(set) var selected: EngineID

    /// Called whenever a state or the selection changes.
    @ObservationIgnored public var onChange: (() -> Void)?

    @ObservationIgnored private let engines: [EngineID: any TranscriptionEngine]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var lastFailure: Date?
    private static let selectionKey = "selectedEngine"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var engines: [EngineID: any TranscriptionEngine] = [.parakeet: ParakeetEngine()]
        var states: [EngineID: EngineState] = [.parakeet: .idle]
        if #available(macOS 26.0, *) {
            engines[.speechAnalyzer] = SpeechAnalyzerEngine()
            states[.speechAnalyzer] = .idle
        } else {
            states[.speechAnalyzer] = .unavailable("requires macOS 26")
        }

        let stored = defaults.string(forKey: Self.selectionKey).flatMap(EngineID.init(rawValue:))
        if let stored, engines[stored] != nil {
            self.selected = stored
        } else {
            self.selected = .default
        }
        self.engines = engines
        self.states = states
    }

    /// For tests: a manager over the given engines instead of the real ones.
    init(defaults: UserDefaults, engines: [EngineID: any TranscriptionEngine], selected: EngineID) {
        self.defaults = defaults
        self.engines = engines
        self.states = engines.mapValues { _ in .idle }
        self.selected = selected
    }

    public func state(of id: EngineID) -> EngineState { states[id] ?? .idle }

    public var selectedState: EngineState { state(of: selected) }

    /// The selected engine, if it can be used right now.
    public var readyEngine: (any TranscriptionEngine)? {
        selectedState.isReady ? engines[selected] : nil
    }

    public func isSelectable(_ id: EngineID) -> Bool { engines[id] != nil }

    public func select(_ id: EngineID) {
        guard engines[id] != nil else { return }
        guard id != selected else {
            // Choosing the current engine again retries a failed load.
            if case .failed = state(of: id) { prepare(id) }
            return
        }
        selected = id
        defaults.set(id.rawValue, forKey: Self.selectionKey)
        onChange?()
        prepareSelected()
    }

    /// Downloads and loads the selected engine if that has not happened yet.
    public func prepareSelected() {
        prepare(selected)
    }

    public func prepare(_ id: EngineID) {
        guard let engine = engines[id] else { return }
        switch state(of: id) {
        case .ready, .downloading, .loading: return
        case .idle, .failed, .unavailable: break
        }
        setState(.loading, for: id)
        Task {
            await engine.prepare { [weak self] state in
                Task { @MainActor in self?.setState(state, for: id) }
            }
        }
    }

    /// Tries the selected engine again if its last load failed (no network
    /// during the model download, say) and `interval` has passed since.
    public func retrySelectedIfFailed(after interval: TimeInterval = 30) {
        guard case .failed = selectedState, let lastFailure,
            Date().timeIntervalSince(lastFailure) >= interval
        else { return }
        prepareSelected()
    }

    private func setState(_ state: EngineState, for id: EngineID) {
        guard states[id] != state else { return }
        if case .failed = state { lastFailure = Date() }
        // Progress callbacks arrive on arbitrary threads and can land out of
        // order; never step back from ready to an earlier progress value.
        if states[id] == .ready, case .downloading = state { return }
        if states[id] == .ready, state == .loading { return }
        states[id] = state
        onChange?()
    }
}
