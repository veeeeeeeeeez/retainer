import Foundation
import Security

/// Finding notes by what they mean, not only by their words: the question
/// and a plain listing of the notes go to Claude, which answers with the
/// notes that fit, best first.
///
/// This is the one part of search that leaves the Mac, and only when a key
/// has been given (`SearchKey`). Without one, search is by words alone.
public enum MeaningSearch {

    /// The model asked. One place to change it.
    public static let model = "claude-opus-5-5"

    public enum Failure: Error, Equatable {
        /// The key was refused.
        case key
        /// Claude declined, or answered with something other than a list.
        case answer
        /// No answer: offline, rate limited, or the service is down.
        case unreachable
    }

    /// As much of the picture's text as goes with each note, and of the
    /// whole listing. Beyond the second, the oldest notes are left out and
    /// can still be found by their words.
    static let pictureLimit = 700
    static let listingLimit = 600_000

    static let instructions = """
        You are the search of a personal notes app. Each note is a screenshot the person took of something \
        they were reading, with what they said about it. Below is every note: its number, when it was saved, \
        where it came from, what the person said ("said"), and the text read from the screenshot ("picture").

        Given a search, answer with the numbers of the notes that fit it, best first. Go by meaning as well \
        as words: a search may describe the subject, the source, the time ("last Thursday", "this morning"), \
        or something only the picture says. Leave out notes that do not fit; an empty list is a fine answer. \
        At most 20.
        """

    /// The notes as Claude is shown them, newest first, and which note each number is.
    static func listing(of documents: [SearchDocument], calendar: Calendar) -> (text: String, ids: [UUID]) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE d MMM yyyy HH:mm"
        func oneLine(_ text: String) -> String {
            text.split(whereSeparator: \.isNewline).joined(separator: " ")
        }
        var text = ""
        var ids: [UUID] = []
        for document in documents.sorted(by: { $0.timestamp > $1.timestamp }) {
            var entry = "[\(ids.count + 1)] \(formatter.string(from: document.timestamp))"
            if !document.source.isEmpty { entry += " · \(oneLine(document.source))" }
            if !document.note.isEmpty { entry += "\nsaid: \(oneLine(document.note))" }
            if !document.picture.isEmpty {
                entry += "\npicture: \(oneLine(document.picture).prefix(pictureLimit))"
            }
            entry += "\n\n"
            guard text.count + entry.count <= listingLimit else { break }
            text += entry
            ids.append(document.id)
        }
        return (text, ids)
    }

    /// The request, as JSON. The listing is the same from one search to the
    /// next, so it is marked to be cached; the search itself comes after it.
    static func body(query: String, listing: String, now: Date, calendar: Calendar) -> [String: Any] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE d MMMM yyyy, HH:mm"
        return [
            "model": model,
            "max_tokens": 4000,
            // Declined by a safeguard: answered by the model the service picks instead.
            "fallbacks": "default",
            "system": [
                ["type": "text", "text": instructions],
                ["type": "text", "text": listing, "cache_control": ["type": "ephemeral"]],
            ],
            "messages": [
                ["role": "user", "content": "It is \(formatter.string(from: now)).\n\nSearch: \(query)"]
            ],
            "output_config": [
                "effort": "low",
                "format": [
                    "type": "json_schema",
                    "schema": [
                        "type": "object",
                        "properties": ["notes": ["type": "array", "items": ["type": "integer"]]],
                        "required": ["notes"],
                        "additionalProperties": false,
                    ] as [String: Any],
                ] as [String: Any],
            ] as [String: Any],
        ]
    }

    /// The note numbers in Claude's reply.
    static func numbers(in response: Data) throws -> [Int] {
        struct Reply: Decodable {
            struct Block: Decodable {
                let type: String
                let text: String?
            }
            let content: [Block]
            let stop_reason: String?
        }
        struct Answer: Decodable { let notes: [Int] }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: response), reply.stop_reason != "refusal",
            let text = reply.content.first(where: { $0.type == "text" })?.text,
            let answer = try? JSONDecoder().decode(Answer.self, from: Data(text.utf8))
        else { throw Failure.answer }
        return answer.notes
    }

    /// Asks Claude which notes fit `query`. The notes come back best first.
    public static func find(
        _ query: String, in documents: [SearchDocument], key: String, now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [UUID] {
        let (listing, ids) = listing(of: documents, calendar: calendar)
        guard !ids.isEmpty else { return [] }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2026-10-21", forHTTPHeaderField: "anthropic-version")
        request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: body(query: query, listing: listing, now: now, calendar: calendar),
            // Byte for byte the same from one search to the next, or nothing is cached.
            options: [.sortedKeys])
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure.unreachable
        }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403: throw Failure.key
        case 400, 404, 413, 422: throw Failure.answer
        default: throw Failure.unreachable
        }
        var seen: Set<Int> = []
        return try numbers(in: data).compactMap { number in
            guard number >= 1, number <= ids.count, seen.insert(number).inserted else { return nil }
            return ids[number - 1]
        }
    }
}

/// The Anthropic key that search by meaning is asked with. It is kept in
/// the Mac's keychain: never in the notes' folder, the settings, or the app.
public enum SearchKey {

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "blog.terminal.app.search",
            kSecAttrAccount as String: "anthropic",
        ]
    }

    public static func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
            let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    /// Keeps a key, replacing the one there. An empty key removes it.
    @discardableResult
    public static func save(_ key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrLabel as String] = "Retainer search"
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }
}
