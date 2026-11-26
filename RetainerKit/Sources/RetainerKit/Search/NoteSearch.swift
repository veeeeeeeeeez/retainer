import Foundation

/// What of a note can be searched: what was said or typed, where it came
/// from, and the words read out of its picture.
public struct SearchDocument: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    /// The note itself.
    public let note: String
    /// The app, the window's title and the link.
    public let source: String
    /// Text read from the screenshot (`PictureText`). Empty until it has been read.
    public let picture: String

    // The same three with case and accents taken off, for matching.
    let foldedNote: String
    let foldedSource: String
    let foldedPicture: String

    public init(id: UUID, timestamp: Date, note: String, source: String, picture: String) {
        self.id = id
        self.timestamp = timestamp
        self.note = note
        self.source = source
        self.picture = picture
        foldedNote = NoteSearch.fold(note)
        foldedSource = NoteSearch.fold(source)
        foldedPicture = NoteSearch.fold(picture)
    }

    public init(_ note: Note, picture: String) {
        let source = [note.sourceApp, note.windowTitle, note.sourceURL].compactMap { $0 }.joined(separator: "  ")
        self.init(id: note.id, timestamp: note.timestamp, note: note.note, source: source, picture: picture)
    }
}

/// One note found, and the line of it to show.
public struct SearchHit: Sendable, Equatable, Identifiable {
    public enum Place: Sendable, Equatable {
        /// The words are in the note, in where it came from, or in its picture.
        case note, source, picture
        /// None of the words are in it: it was found by what it means.
        case meaning
    }

    public let id: UUID
    public let place: Place
    /// A line of the note (or of its picture's text) round the first match.
    public let snippet: String
}

/// Finding notes by their words. Every word of the query has to be
/// somewhere in the note; case and accents do not count. Notes with the
/// words in what was said come before those with them only in the source,
/// and those before ones with them only in the picture; newest first within
/// each.
public enum NoteSearch {

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Words that say nothing about what is being looked for. A search
    /// written as a sentence ("the painting of mountains") is matched and
    /// marked by its other words.
    private static let small: Set<String> = [
        "a", "an", "and", "the", "of", "in", "on", "at", "to", "for", "with", "is", "it", "that", "this", "my",
        "i", "about", "from",
    ]

    /// The words of a query, folded, without the small ones (unless there are no others).
    public static func terms(of query: String) -> [String] {
        let all = fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        let telling = all.filter { !small.contains($0) }
        return telling.isEmpty ? all : telling
    }

    public static func hits(for query: String, in documents: [SearchDocument], limit: Int = 50) -> [SearchHit] {
        let terms = terms(of: query)
        guard !terms.isEmpty else { return [] }
        var found: [(hit: SearchHit, score: Int, date: Date)] = []
        for document in documents {
            var score = 0
            var weakest = 3
            var matchedAll = true
            for term in terms {
                let weight =
                    document.foldedNote.contains(term) ? 3
                    : document.foldedSource.contains(term) ? 2
                    : document.foldedPicture.contains(term) ? 1 : 0
                if weight == 0 {
                    matchedAll = false
                    break
                }
                score += weight
                weakest = min(weakest, weight)
            }
            guard matchedAll else { continue }
            // The line shown is from where the hardest-to-find word is.
            let place: SearchHit.Place = weakest == 3 ? .note : weakest == 2 ? .source : .picture
            found.append((hit(for: document, place: place, terms: terms), score, document.timestamp))
        }
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.date > $1.date }
        return found.prefix(limit).map(\.hit)
    }

    /// A hit for a note found some other way than by its words.
    public static func hit(for document: SearchDocument, place: SearchHit.Place, terms: [String] = []) -> SearchHit {
        let text: String
        switch place {
        case .picture: text = document.picture
        case .note, .source, .meaning: text = document.note.isEmpty ? document.picture : document.note
        }
        return SearchHit(id: document.id, place: place, snippet: snippet(of: text, around: terms))
    }

    /// One line of `text`, starting a little before the first of `terms`.
    static func snippet(of text: String, around terms: [String], length: Int = 180) -> String {
        // Read as a line of words: without the marks that make Markdown bold or code.
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        var start = line.startIndex
        let first = terms.compactMap { range(of: $0, in: line)?.lowerBound }.min()
        if let first, line.distance(from: line.startIndex, to: first) > 40 {
            // Back to the start of a word, some way before the match.
            start = line.index(first, offsetBy: -30)
            if let space = line[start..<first].firstIndex(of: " ") { start = line.index(after: space) }
        }
        let end = line.index(start, offsetBy: length, limitedBy: line.endIndex) ?? line.endIndex
        return (start > line.startIndex ? "…" : "") + line[start..<end] + (end < line.endIndex ? "…" : "")
    }

    /// Where a folded term is in text as it is written.
    static func range(of term: String, in text: String) -> Range<String.Index>? {
        text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive])
    }

    /// Every place the words of a query are in a line, to mark them there.
    public static func marks(of query: String, in text: String) -> [Range<String.Index>] {
        var marks: [Range<String.Index>] = []
        for term in terms(of: query) {
            var from = text.startIndex
            while from < text.endIndex,
                let found = text.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    range: from..<text.endIndex), !found.isEmpty
            {
                marks.append(found)
                from = found.upperBound
            }
        }
        return marks
    }
}
