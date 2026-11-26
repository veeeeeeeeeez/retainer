import CoreGraphics
import Foundation
import Synchronization
import Testing

@testable import RetainerKit

@Suite("Search")
@MainActor
struct SearchTests {

    private static func document(
        _ note: String, source: String = "", picture: String = "", day: Int = 19, id: UUID = UUID()
    ) -> SearchDocument {
        SearchDocument(
            id: id, timestamp: NoteStoreTests.date(2026, 11, day), note: note, source: source, picture: picture)
    }

    // MARK: By words

    @Test("Every word has to be in the note; case and accents do not count; words may be in different parts")
    func wordsMatch() {
        let cafe = Self.document("A café in Montréal", source: "Safari  Places to eat")
        let other = Self.document("Notes on decision theory", picture: "Newcomb's problem and Omega")
        let documents = [cafe, other]
        #expect(NoteSearch.hits(for: "CAFE montreal", in: documents).map(\.id) == [cafe.id])
        #expect(NoteSearch.hits(for: "safari café", in: documents).map(\.id) == [cafe.id])
        #expect(NoteSearch.hits(for: "omega decision", in: documents).map(\.id) == [other.id])
        #expect(NoteSearch.hits(for: "omega café", in: documents).isEmpty)
        #expect(NoteSearch.hits(for: "   ", in: documents).isEmpty)
        // Written as a sentence: the small words are not asked of the note.
        #expect(NoteSearch.hits(for: "the café in the Montreal", in: documents).map(\.id) == [cafe.id])
        #expect(NoteSearch.terms(of: "the painting of mountains") == ["painting", "mountains"])
        #expect(NoteSearch.terms(of: "the of") == ["the", "of"])
    }

    @Test("Words in what was said come before words only in the source or the picture; then newest first")
    func order() {
        let picture = Self.document("Look at this", picture: "Bayesian updating", day: 20)
        let source = Self.document("Keep for later", source: "Chrome  Bayesian methods", day: 20)
        let old = Self.document("Bayesian reasoning is hard", day: 12)
        let new = Self.document("More on Bayesian priors", day: 18)
        let hits = NoteSearch.hits(for: "bayesian", in: [picture, source, old, new])
        #expect(hits.map(\.id) == [new.id, old.id, source.id, picture.id])
        #expect(hits.map(\.place) == [.note, .note, .source, .picture])
    }

    @Test("The line shown is round the match, from the picture when that is where the word is, with the word marked")
    func snippets() {
        let long = String(repeating: "filler words here ", count: 12) + "then the Bierstadt canvas appears " +
            String(repeating: "and more after ", count: 20)
        let said = Self.document(long)
        let hit = NoteSearch.hits(for: "bierstadt", in: [said])[0]
        #expect(hit.snippet.hasPrefix("…"))
        #expect(hit.snippet.hasSuffix("…"))
        #expect(hit.snippet.count <= 182)
        let marks = NoteSearch.marks(of: "bierstadt", in: hit.snippet)
        #expect(marks.map { String(hit.snippet[$0]) } == ["Bierstadt"])

        let seen = Self.document("I like this", picture: "Line one\nLander's Peak, 1863")
        let fromPicture = NoteSearch.hits(for: "peak", in: [seen])[0]
        #expect(fromPicture.place == .picture)
        #expect(fromPicture.snippet == "Line one Lander's Peak, 1863")
        #expect(NoteSearch.marks(of: "e", in: "eve").count == 2)
        // Markdown's marks are not shown in the line.
        let marked = Self.document("The **retry path** is in `queue.swift`")
        #expect(NoteSearch.hits(for: "retry", in: [marked])[0].snippet == "The retry path is in queue.swift")
    }

    // MARK: Pictures

    @Test("Pictures are read once each, kept across a relaunch, and read again when a picture is replaced")
    func picturesRead() async {
        let directory = NoteStoreTests.temporaryDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let reads = Mutex<[String]>([])
        let read: @Sendable (URL) async -> String? = { url in
            reads.withLock { $0.append(url.lastPathComponent) }
            return url.lastPathComponent == "missing.png" ? nil : "words in \(url.lastPathComponent)"
        }
        var a = NoteStoreTests.sampleNote(text: "a")
        let missing = NoteStoreTests.sampleNote(text: "not written yet")
        var typed = NoteStoreTests.sampleNote(text: "typed")
        typed.sourceApp = "Typed"
        typed.sourceURL = nil
        func url(_ note: Note) -> URL {
            URL(fileURLWithPath: note.id == missing.id ? "/tmp/missing.png" : "/tmp/\(note.id == a.id ? "a" : "t").png")
        }

        let pictures = PictureText(directory: directory, read: read)
        #expect(pictures.text(for: a) == "")
        pictures.catchUp(with: [a, missing, typed], imageURL: url)
        #expect(pictures.remaining == 2)
        await pictures.waitUntilIdle()
        #expect(pictures.text(for: a) == "words in a.png")
        // A note of words alone has no picture to read; one that cannot be read has none yet.
        #expect(reads.withLock { $0 } == ["a.png", "missing.png"])
        #expect(pictures.remaining == 0)

        // Nothing is read twice; what could not be read is tried three times in all.
        for _ in 0..<4 {
            pictures.catchUp(with: [a, missing, typed], imageURL: url)
            await pictures.waitUntilIdle()
        }
        #expect(reads.withLock { $0 }.filter { $0 == "a.png" }.count == 1)
        #expect(reads.withLock { $0 }.filter { $0 == "missing.png" }.count == 3)

        // Kept on disk (written off the main thread: give it a moment).
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: directory.appendingPathComponent("picture-text.json").path) {
            try? await Task.sleep(for: .milliseconds(20))
        }
        let reopened = PictureText(directory: directory, read: read)
        #expect(reopened.text(for: a) == "words in a.png")

        // A new picture of another size is read again.
        a.imagePixelSize = PixelSize(width: 1200, height: 630)
        #expect(reopened.text(for: a) == "")
        reopened.catchUp(with: [a], imageURL: url)
        await reopened.waitUntilIdle()
        #expect(reads.withLock { $0 }.filter { $0 == "a.png" }.count == 2)
        #expect(reopened.text(for: a) == "words in a.png")
    }

    // MARK: By meaning

    @Test("Claude is shown every note, newest first and numbered, and its numbers come back as notes")
    func listingAndAnswer() throws {
        let old = Self.document("Older note", source: "Chrome  A page", picture: "first line\nsecond line", day: 12)
        let new = Self.document("Newer note", day: 20)
        let (listing, ids) = MeaningSearch.listing(of: [old, new], calendar: NoteStoreTests.calendar)
        #expect(ids == [new.id, old.id])
        #expect(listing.contains("[1] Fri 20 Nov 2026 12:00\nsaid: Newer note"))
        #expect(listing.contains("[2] Thu 12 Nov 2026 12:00 · Chrome  A page\nsaid: Older note\npicture: first line second line"))

        let reply = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"{\"notes\":[2,1]}"}],"stop_reason":"end_turn"}"#
        #expect(try MeaningSearch.numbers(in: Data(reply.utf8)) == [2, 1])
        let refusal = #"{"content":[],"stop_reason":"refusal"}"#
        #expect(throws: MeaningSearch.Failure.answer) { try MeaningSearch.numbers(in: Data(refusal.utf8)) }
        #expect(throws: MeaningSearch.Failure.answer) { try MeaningSearch.numbers(in: Data("not json".utf8)) }
    }

    @Test("The request keeps the notes in a cached block ahead of the search, and is the same bytes each time")
    func request() throws {
        let now = NoteStoreTests.date(2026, 11, 20)
        func bytes(_ query: String) throws -> Data {
            try JSONSerialization.data(
                withJSONObject: MeaningSearch.body(
                    query: query, listing: "[1] a note", now: now, calendar: NoteStoreTests.calendar),
                options: [.sortedKeys])
        }
        #expect(try bytes("mountains") == bytes("mountains"))
        let body = try #require(JSONSerialization.jsonObject(with: bytes("mountains")) as? [String: Any])
        #expect(body["model"] as? String == MeaningSearch.model)
        let system = try #require(body["system"] as? [[String: Any]])
        #expect(system.last?["text"] as? String == "[1] a note")
        #expect(system.last?["cache_control"] != nil)
        // The search and the time are after the cached part, never in it.
        #expect(system.allSatisfy { !(($0["text"] as? String) ?? "").contains("mountains") })
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["content"] as? String == "It is Friday 20 November 2026, 12:00.\n\nSearch: mountains")
    }

    // MARK: The box

    @MainActor
    private final class Box {
        let model = SearchModel()
        var asked: [String] = []
        let words: SearchDocument
        let meant: SearchDocument
        let both: SearchDocument

        init(key: String? = "key", answer: @escaping @Sendable (String, [SearchDocument]) throws -> [UUID] = { _, _ in [] }) {
            words = SearchTests.document("Mountains in Wyoming", day: 18)
            meant = SearchTests.document("A big landscape painting", day: 19)
            both = SearchTests.document("Rocky Mountains by Bierstadt", day: 20)
            let documents = [words, meant, both]
            model.documents = { documents }
            model.key = { key }
            model.pause = .milliseconds(1)
            model.find = { query, documents, _ in try answer(query, documents) }
        }

        /// Waits for Claude's answer to have been taken in.
        func settle() async {
            for _ in 0..<200 where model.meaning == .asking { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    @Test("Word matches show at once; what Claude finds goes first, and the other word matches stay after it")
    func merges() async {
        let ids = Mutex<[UUID]>([])
        let box = Box { _, _ in ids.withLock { $0 } }
        ids.withLock { $0 = [box.meant.id, box.words.id] }
        box.model.open()
        box.model.query = "mountains"
        // At once, by words: newest first.
        #expect(box.model.hits.map(\.id) == [box.both.id, box.words.id])
        #expect(box.model.meaning == .asking)
        await box.settle()
        #expect(box.model.meaning == .idle)
        #expect(box.model.hits.map(\.id) == [box.meant.id, box.words.id, box.both.id])
        #expect(box.model.hits.map(\.place) == [.meaning, .note, .note])
        #expect(box.model.chosen == box.meant.id)
    }

    @Test("A line that was moved to stays chosen when Claude's answer reorders the list")
    func keepsChoice() async {
        let ids = Mutex<[UUID]>([])
        let box = Box { _, _ in ids.withLock { $0 } }
        ids.withLock { $0 = [box.meant.id] }
        box.model.pause = .milliseconds(60)
        box.model.open()
        box.model.query = "mountains"
        box.model.move(by: 1)
        #expect(box.model.chosen == box.words.id)
        await box.settle()
        #expect(box.model.hits.first?.id == box.meant.id)
        #expect(box.model.chosen == box.words.id)
        // Up and down stop at the ends.
        #expect(box.model.hits.map(\.id) == [box.meant.id, box.both.id, box.words.id])
        box.model.move(by: 10)
        #expect(box.model.chosen == box.words.id)
        box.model.move(by: -10)
        #expect(box.model.chosen == box.meant.id)
    }

    @Test("Without a key, or when Claude cannot be reached, search is by words and says which")
    func withoutClaude() async {
        let offline = Box(key: nil)
        offline.model.open()
        offline.model.query = "mountains"
        #expect(offline.model.meaning == .off)
        #expect(offline.model.hits.count == 2)

        let failing = Box { _, _ in throw MeaningSearch.Failure.unreachable }
        failing.model.open()
        failing.model.query = "mountains"
        await failing.settle()
        #expect(failing.model.meaning == .failed(.unreachable))
        #expect(failing.model.hits.count == 2)

        // Too little to ask about: nothing is sent.
        let short = Box { _, _ in
            Issue.record("asked about two letters")
            return []
        }
        short.model.open()
        short.model.query = "mo"
        try? await Task.sleep(for: .milliseconds(30))
        #expect(short.model.meaning == .idle)
    }

    @Test("Only the last thing typed is asked about")
    func asksOnce() async {
        let asked = Mutex<[String]>([])
        let box = Box { query, _ in
            asked.withLock { $0.append(query) }
            return []
        }
        box.model.pause = .milliseconds(40)
        box.model.open()
        for query in ["mou", "moun", "mount", "mountains"] { box.model.query = query }
        await box.settle()
        #expect(asked.withLock { $0 } == ["mountains"])
        box.model.close()
        #expect(!box.model.isOpen)
    }

    // MARK: Going to a note

    @Test("Choosing a note goes to its day and opens it there; an archived one in its day's archive; one on the canvas in front stays there")
    func goesToNote() {
        let directory = NoteStoreTests.temporaryDirectory()
        let suite = "retainer-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = NoteStore(directory: directory, calendar: NoteStoreTests.calendar)
        let canvas = CanvasModel(
            defaults: defaults, calendar: NoteStoreTests.calendar, now: { NoteStoreTests.date(2026, 11, 20) })
        canvas.setViewSize(CGSize(width: 1400, height: 900))
        let old = NoteStoreTests.sampleNote(text: "old", on: NoteStoreTests.date(2026, 11, 12), at: CGPoint(x: 3000, y: 2000))
        let put = NoteStoreTests.sampleNote(text: "put away", on: NoteStoreTests.date(2026, 11, 14))
        store.add(old)
        store.add(put)
        store.archive(id: put.id)

        canvas.show(old.id, in: store)
        #expect(canvas.period == Period.containing(old.timestamp, scale: .day, calendar: NoteStoreTests.calendar))
        #expect(canvas.expandedNoteID == old.id)
        #expect(!canvas.showingArchive)
        // In the middle of the window.
        let frame = canvas.frame(of: old)
        let middle = canvas.viewPoint(for: CGPoint(x: frame.midX, y: frame.midY))
        #expect(abs(middle.x - 700) <= 1 && abs(middle.y - 450) <= 1)

        canvas.show(put.id, in: store)
        #expect(canvas.showingArchive)
        #expect(canvas.expandedNoteID == put.id)

        let project = store.addProject(name: "P")
        let board = store.addCanvas(in: project.id, name: "C")!
        store.place(noteID: old.id, on: board.id, at: CGPoint(x: -900, y: 40))
        canvas.show(.canvas(board.id))
        canvas.show(old.id, in: store)
        #expect(canvas.canvasID == board.id)
        #expect(canvas.expandedNoteID == old.id)
        // A note that is not on that canvas takes it back to the note's day.
        canvas.show(put.id, in: store)
        #expect(canvas.canvasID == nil)
        store.flush()
    }

    @Test("When a found note is from, in a few words")
    func dates() {
        let today = NoteStoreTests.date(2026, 11, 20, hour: 17)
        let calendar = NoteStoreTests.calendar
        #expect(SearchDates.label(for: NoteStoreTests.date(2026, 11, 20, hour: 9, minute: 14), today: today, calendar: calendar) == "Today 09:14")
        #expect(SearchDates.label(for: NoteStoreTests.date(2026, 11, 19, hour: 23), today: today, calendar: calendar) == "Yesterday 23:00")
        #expect(SearchDates.label(for: NoteStoreTests.date(2026, 11, 12), today: today, calendar: calendar) == "Thu 12 Nov")
        #expect(SearchDates.label(for: NoteStoreTests.date(2025, 3, 3), today: today, calendar: calendar) == "3 Mar 2025")
    }
}
