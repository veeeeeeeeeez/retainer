import Foundation

/// What became of the tidy pass for one note.
public enum TidyOutcome: String, Codable, Sendable, Equatable {
    /// Tidy was switched off.
    case off
    /// The model's output passed the checks and was used.
    case applied
    /// There was nothing to tidy (no speech).
    case empty
    /// The on-device model is not available on this Mac right now.
    case unavailable
    /// The model took longer than the limit.
    case timedOut = "timed-out"
    /// The model's output failed the length or fidelity checks.
    case rejected
    /// The model returned an error.
    case failed
}

/// Decides whether a tidied transcript is safe to use in place of the raw one.
///
/// The tidy pass may only delete fillers and false starts, fix punctuation and
/// capitalisation, and add paragraph breaks or list markers. So a legitimate
/// result is made of the speaker's own words, in slightly smaller number.
/// Anything else (a summary, a rewrite, an answer to a question the speaker
/// asked) shows up as a change in length or as words that were never said,
/// and is rejected here without trusting the model's own judgement.
public enum TidyGuard {

    public struct Verdict: Sendable, Equatable {
        public var accepted: Bool
        public var reason: String?

        public static let ok = Verdict(accepted: true, reason: nil)
        public static func reject(_ reason: String) -> Verdict { Verdict(accepted: false, reason: reason) }
    }

    /// Sounds that carry no meaning and that the tidy pass is expected to remove.
    public static let fillers: Set<String> = [
        "um", "umm", "uhm", "uh", "uhh", "er", "erm", "ah", "ahh", "eh", "hmm", "hm", "mm", "mhm",
    ]

    public static func evaluate(raw: String, tidied: String, config: CaptureConfig = .standard) -> Verdict {
        let rawWords = words(in: raw)
        let tidiedWords = words(in: tidied)

        if tidiedWords.isEmpty {
            return rawWords.contains(where: { !fillers.contains($0) }) ? .reject("empty result") : .ok
        }

        if introducesHeading(raw: raw, tidied: tidied) {
            return .reject("added a heading")
        }

        // Shorter: more went missing than fillers and false starts can explain.
        let meaningful = rawWords.filter { !fillers.contains($0) }.count
        let minimum = Int((Double(meaningful) * config.tidyMinimumLengthRatio).rounded(.down))
        if tidiedWords.count < minimum {
            return .reject("too short (\(tidiedWords.count) of \(rawWords.count) words)")
        }

        // Longer: tidying never adds words. One word of slack covers a split compound.
        let maximum = Int((Double(rawWords.count) * config.tidyMaximumLengthRatio).rounded(.up)) + 1
        if tidiedWords.count > maximum {
            return .reject("too long (\(tidiedWords.count) of \(rawWords.count) words)")
        }

        // Fidelity: every word should be one the speaker used.
        var remaining: [String: Int] = [:]
        for word in rawWords { remaining[word, default: 0] += 1 }
        var novel = 0
        for word in tidiedWords {
            if let count = remaining[word], count > 0 {
                remaining[word] = count - 1
            } else {
                novel += 1
            }
        }
        let allowedNovel = max(1, Int((Double(tidiedWords.count) * config.tidyMaximumNovelWordRatio).rounded(.down)))
        if novel > allowedNovel {
            return .reject("changed wording (\(novel) new words)")
        }

        return .ok
    }

    /// Lowercased words with punctuation and Markdown markers removed.
    /// Apostrophes are kept inside words so "don't" stays one token.
    static func words(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if scalar == "'" || scalar == "\u{2019}" {
                current.unicodeScalars.append("'")
            } else {
                flush()
            }
        }
        flush()
        return result
    }

    private static func introducesHeading(raw: String, tidied: String) -> Bool {
        func hasHeading(_ text: String) -> Bool {
            text.split(whereSeparator: \.isNewline).contains { line in
                let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
                guard trimmed.hasPrefix("#") else { return false }
                let afterHashes = trimmed.drop(while: { $0 == "#" })
                return afterHashes.first == " "
            }
        }
        return hasHeading(tidied) && !hasHeading(raw)
    }

    /// Removes wrappers a model sometimes puts around its answer: the
    /// transcript tags from the prompt, a code fence, or surrounding quotes.
    public static func unwrap(_ output: String, raw: String = "") -> String {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        for tag in ["<transcript>", "</transcript>"] {
            text = text.replacingOccurrences(of: tag, with: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 {
            var lines = text.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces) == "```" { lines.removeLast() }
            text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rawIsQuoted = raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("\"")
        if !rawIsQuoted, text.count >= 2, text.hasPrefix("\""), text.hasSuffix("\"") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }
}
