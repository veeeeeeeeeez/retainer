import Foundation
import Observation

/// The search box: what is typed, what it finds, and which line is chosen.
///
/// Notes with the words in them are found at once, on this Mac. When a key
/// has been given, a moment after the typing stops the same question goes to
/// Claude (`MeaningSearch`), and what it finds by meaning comes first, with
/// the rest of the word matches after it.
@MainActor
@Observable
public final class SearchModel {

    public enum Meaning: Equatable {
        /// No key: by words only.
        case off
        case idle
        case asking
        case failed(MeaningSearch.Failure)
    }

    public private(set) var isOpen = false
    public var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    public private(set) var hits: [SearchHit] = []
    /// The chosen line.
    public private(set) var selection = 0
    public private(set) var meaning: Meaning = .off

    /// The notes to search, as they are when the box opens.
    @ObservationIgnored var documents: () -> [SearchDocument] = { [] }
    @ObservationIgnored var key: () -> String? = { SearchKey.read() }
    @ObservationIgnored var find: @Sendable (String, [SearchDocument], String) async throws -> [UUID] = {
        try await MeaningSearch.find($0, in: $1, key: $2)
    }
    /// How long the typing has to stop before Claude is asked.
    @ObservationIgnored var pause: Duration = .milliseconds(350)

    @ObservationIgnored private var current: [SearchDocument] = []
    @ObservationIgnored private var currentKey: String?
    @ObservationIgnored private var asking: Task<Void, Never>?

    public init() {}

    public func open() {
        current = documents()
        currentKey = key()
        meaning = currentKey == nil ? .off : .idle
        isOpen = true
        queryChanged()
    }

    public func close() {
        asking?.cancel()
        isOpen = false
    }

    /// The notes changed while the box is open (a picture was read).
    public func refresh() {
        guard isOpen else { return }
        current = documents()
    }

    public func move(by step: Int) {
        guard !hits.isEmpty else { return }
        selection = min(max(selection + step, 0), hits.count - 1)
    }

    public func select(_ id: UUID) {
        if let index = hits.firstIndex(where: { $0.id == id }) { selection = index }
    }

    /// The note of the chosen line.
    public var chosen: UUID? {
        hits.indices.contains(selection) ? hits[selection].id : nil
    }

    private func queryChanged() {
        asking?.cancel()
        let asked = query.trimmingCharacters(in: .whitespacesAndNewlines)
        hits = NoteSearch.hits(for: asked, in: current)
        selection = 0
        guard let key = currentKey else { return }
        guard asked.count >= 3 else {
            meaning = .idle
            return
        }
        meaning = .asking
        let documents = current
        asking = Task { [weak self, find, pause] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            do {
                let found = try await find(asked, documents, key)
                guard !Task.isCancelled, let self else { return }
                self.merge(found, from: documents, terms: NoteSearch.terms(of: asked))
                self.meaning = .idle
            } catch let failure as MeaningSearch.Failure {
                guard !Task.isCancelled else { return }
                self?.meaning = .failed(failure)
            } catch {}
        }
    }

    /// What Claude found goes first, in its order; the word matches it did
    /// not name stay, after. The chosen line stays chosen if it was moved to.
    private func merge(_ found: [UUID], from documents: [SearchDocument], terms: [String]) {
        let kept = selection > 0 ? chosen : nil
        let byWords = Dictionary(hits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(documents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged: [SearchHit] = found.compactMap { id in
            byWords[id] ?? byID[id].map { NoteSearch.hit(for: $0, place: .meaning) }
        }
        let named = Set(found)
        merged += hits.filter { !named.contains($0.id) }
        hits = merged
        selection = kept.flatMap { id in merged.firstIndex { $0.id == id } } ?? 0
    }
}
