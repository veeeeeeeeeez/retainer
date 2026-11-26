import Foundation
import Observation
import Vision

/// The words in each note's screenshot, read on this Mac (Vision) so that a
/// note can be found by what its picture says. Reading happens in the
/// background, one picture at a time, and is kept beside the notes:
///
/// ```
/// ~/Library/Application Support/Terminal/picture-text.json
/// ```
///
/// The file only saves reading the pictures again: it can be deleted.
@MainActor
@Observable
public final class PictureText {

    struct Entry: Codable, Equatable {
        /// The picture's size when it was read, "800x600": a link's card
        /// gets a new picture once its page has been pictured.
        var size: String
        var text: String
    }

    private(set) var entries: [UUID: Entry] = [:]
    /// How many pictures are still to be read.
    public private(set) var remaining = 0

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let read: @Sendable (URL) async -> String?
    @ObservationIgnored private var queue: [(id: UUID, url: URL, size: String)] = []
    @ObservationIgnored private var attempts: [UUID: Int] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?

    public init(directory: URL, read: @escaping @Sendable (URL) async -> String? = PictureText.recognize) {
        fileURL = directory.appendingPathComponent("picture-text.json")
        self.read = read
        if let data = try? Data(contentsOf: fileURL),
            let saved = try? JSONDecoder().decode([UUID: Entry].self, from: data)
        {
            entries = saved
        }
    }

    private static func size(of note: Note) -> String {
        "\(note.imagePixelSize.width)x\(note.imagePixelSize.height)"
    }

    /// The words in a note's picture, or nothing if it has not been read yet.
    public func text(for note: Note) -> String {
        guard let entry = entries[note.id], entry.size == Self.size(of: note) else { return "" }
        return entry.text
    }

    /// Reads the pictures that have not been read. Cheap to call when there
    /// is nothing to do. A picture that cannot be read (its file is not
    /// written yet) is tried again on a later call, three times at most.
    public func catchUp(with notes: [Note], imageURL: (Note) -> URL) {
        let waiting = Set(queue.map(\.id))
        for note in notes where !note.isTextOnly {
            let size = Self.size(of: note)
            guard entries[note.id]?.size != size, !waiting.contains(note.id), attempts[note.id, default: 0] < 3
            else { continue }
            queue.append((note.id, imageURL(note), size))
        }
        remaining = queue.count
        guard worker == nil, !queue.isEmpty else { return }
        worker = Task { [weak self] in
            while let self, let next = self.queue.first {
                let text = await self.read(next.url)
                self.queue.removeFirst()
                if let text {
                    self.entries[next.id] = Entry(size: next.size, text: text)
                } else {
                    self.attempts[next.id, default: 0] += 1
                }
                self.remaining = self.queue.count
                if self.queue.isEmpty || self.queue.count % 10 == 0 { self.save() }
            }
            self?.worker = nil
        }
    }

    /// Waits until every picture queued so far has been read.
    func waitUntilIdle() async {
        await worker?.value
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        let url = fileURL
        Task.detached(priority: .utility) { try? data.write(to: url, options: .atomic) }
    }

    /// Reads the text in a picture file with Vision. `nil` if the file
    /// could not be read; an empty string if it has no text.
    public nonisolated static func recognize(_ url: URL) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continuation.resume(returning: nil)
                    return
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                do {
                    try VNImageRequestHandler(url: url).perform([request])
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}
