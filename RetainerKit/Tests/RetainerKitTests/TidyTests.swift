import Foundation
import Testing

@testable import RetainerKit

@Suite("Tidy guard")
struct TidyGuardTests {

    @Test("Removing fillers and fixing punctuation is accepted")
    func acceptsFillerRemoval() {
        let raw = "um so I think this article is uh really about incentives and um not about technology"
        let tidied = "So I think this article is really about incentives and not about technology."
        #expect(TidyGuard.evaluate(raw: raw, tidied: tidied).accepted)
    }

    @Test("Removing a false start is accepted")
    func acceptsFalseStartRemoval() {
        let raw = "the main the main point here is that the the chart is misleading"
        let tidied = "The main point here is that the chart is misleading."
        #expect(TidyGuard.evaluate(raw: raw, tidied: tidied).accepted)
    }

    @Test("Formatting a spoken list as Markdown is accepted")
    func acceptsListFormatting() {
        let raw = "three things to check first the pricing second the latency and third the license terms"
        let tidied = "Three things to check:\n\n- First, the pricing.\n- Second, the latency.\n- And third, the license terms."
        #expect(TidyGuard.evaluate(raw: raw, tidied: tidied).accepted)
    }

    @Test("Paragraph breaks alone are accepted")
    func acceptsParagraphBreaks() {
        let raw = "this part is about cost. this other part is about speed."
        let tidied = "This part is about cost.\n\nThis other part is about speed."
        #expect(TidyGuard.evaluate(raw: raw, tidied: tidied).accepted)
    }

    @Test("A summary is rejected as too short")
    func rejectsSummary() {
        let raw =
            "I think the author is overstating the case because the sample is tiny and the effect disappears once you control for age and income which they mention only in a footnote"
        let tidied = "The author overstates the case."
        let verdict = TidyGuard.evaluate(raw: raw, tidied: tidied)
        #expect(!verdict.accepted)
        #expect(verdict.reason?.contains("too short") == true)
    }

    @Test("Added commentary is rejected as too long")
    func rejectsAdditions() {
        let raw = "this chart is misleading"
        let tidied = "This chart is misleading. It would be better to show the full axis so that readers can judge the trend."
        let verdict = TidyGuard.evaluate(raw: raw, tidied: tidied)
        #expect(!verdict.accepted)
        #expect(verdict.reason?.contains("too long") == true)
    }

    @Test("A same-length rewrite in different words is rejected")
    func rejectsParaphrase() {
        let raw = "I reckon the writer has got this badly wrong and nobody checked the numbers"
        let tidied = "I believe the author made serious errors and no one verified the figures."
        let verdict = TidyGuard.evaluate(raw: raw, tidied: tidied)
        #expect(!verdict.accepted)
        #expect(verdict.reason?.contains("changed wording") == true)
    }

    @Test("Answering a question the speaker asked is rejected")
    func rejectsAnsweringTheTranscript() {
        let raw = "what do you think is the strongest argument against this"
        let tidied = "The strongest argument against this is that the data is too limited."
        #expect(!TidyGuard.evaluate(raw: raw, tidied: tidied).accepted)
    }

    @Test("An added heading is rejected")
    func rejectsHeading() {
        let raw = "the pricing section buries the real cost in a footnote"
        let tidied = "# Pricing\n\nThe pricing section buries the real cost in a footnote."
        let verdict = TidyGuard.evaluate(raw: raw, tidied: tidied)
        #expect(!verdict.accepted)
        #expect(verdict.reason == "added a heading")
    }

    @Test("An empty result is rejected when something was said")
    func rejectsEmpty() {
        #expect(!TidyGuard.evaluate(raw: "this matters", tidied: "").accepted)
        // Nothing but fillers may legitimately tidy to nothing.
        #expect(TidyGuard.evaluate(raw: "um uh", tidied: "").accepted)
    }

    @Test("Unchanged text is accepted")
    func acceptsIdentity() {
        let text = "Nothing to fix here."
        #expect(TidyGuard.evaluate(raw: text, tidied: text).accepted)
    }

    @Test("Words are compared without case, punctuation or list markers")
    func tokenisation() {
        #expect(TidyGuard.words(in: "- First, the PRICE; don't—stop.") == ["first", "the", "price", "don't", "stop"])
        #expect(TidyGuard.words(in: "1. One\n2. Two") == ["1", "one", "2", "two"])
        #expect(TidyGuard.words(in: "it\u{2019}s") == ["it's"])
    }

    @Test("Wrappers around the model's answer are removed")
    func unwrap() {
        #expect(TidyGuard.unwrap("<transcript>\nHello there.\n</transcript>") == "Hello there.")
        #expect(TidyGuard.unwrap("```\nHello there.\n```") == "Hello there.")
        #expect(TidyGuard.unwrap("\"Hello there.\"") == "Hello there.")
        #expect(TidyGuard.unwrap("  Hello there.\n") == "Hello there.")
        // Quotes the speaker's transcript already had are kept.
        #expect(TidyGuard.unwrap("\"Hello,\" she said, \"there.\"", raw: "\"hello\" she said \"there\"") == "\"Hello,\" she said, \"there.\"")
    }
}

@Suite("Tidy service")
struct TidyServiceTests {

    struct StubTidier: TextTidier {
        var available: TidyAvailability = .available
        var delay: Duration = .zero
        var output: @Sendable (String) throws -> String

        func availability() async -> TidyAvailability { available }
        func prewarm() async {}
        func tidy(_ transcript: String) async throws -> String {
            if delay > .zero { try await Task.sleep(for: delay) }
            return try output(transcript)
        }
    }

    struct StubError: Error {}

    static let raw = "um I think this is uh worth reading twice"

    @Test("With tidy off the raw transcript comes back untouched")
    func offReturnsRaw() async {
        let service = TidyService(tidier: StubTidier(output: { _ in "something else entirely" }))
        let result = await service.run(raw: Self.raw, enabled: false)
        #expect(result == TidyResult(text: Self.raw, outcome: .off))
    }

    @Test("A good result is applied")
    func appliesGoodResult() async {
        let service = TidyService(tidier: StubTidier(output: { _ in "I think this is worth reading twice." }))
        let result = await service.run(raw: Self.raw, enabled: true)
        #expect(result.outcome == .applied)
        #expect(result.text == "I think this is worth reading twice.")
    }

    @Test("An unavailable model falls back to the raw transcript")
    func unavailableFallsBack() async {
        let tidier = StubTidier(available: .unavailable("Apple Intelligence is turned off"), output: { _ in "x" })
        let result = await TidyService(tidier: tidier).run(raw: Self.raw, enabled: true)
        #expect(result.outcome == .unavailable)
        #expect(result.text == Self.raw)
        #expect(result.detail == "Apple Intelligence is turned off")
    }

    @Test("No model at all (macOS 15) falls back to the raw transcript")
    func missingModelFallsBack() async {
        let result = await TidyService(tidier: nil).run(raw: Self.raw, enabled: true)
        #expect(result.outcome == .unavailable)
        #expect(result.text == Self.raw)
    }

    @Test("A slow model is abandoned at the deadline")
    func slowModelTimesOut() async {
        var config = CaptureConfig()
        config.tidyTimeout = 0.2
        let tidier = StubTidier(delay: .seconds(5), output: { _ in "I think this is worth reading twice." })
        let started = ContinuousClock.now
        let result = await TidyService(tidier: tidier, config: config).run(raw: Self.raw, enabled: true)
        let elapsed = ContinuousClock.now - started
        #expect(result.outcome == .timedOut)
        #expect(result.text == Self.raw)
        #expect(elapsed < .seconds(2))
    }

    @Test("A model error falls back to the raw transcript")
    func errorFallsBack() async {
        let result = await TidyService(tidier: StubTidier(output: { _ in throw StubError() }))
            .run(raw: Self.raw, enabled: true)
        #expect(result.outcome == .failed)
        #expect(result.text == Self.raw)
    }

    @Test("A result that fails the guard is rejected")
    func rejectedFallsBack() async {
        let result = await TidyService(tidier: StubTidier(output: { _ in "Worth reading." }))
            .run(raw: Self.raw, enabled: true)
        #expect(result.outcome == .rejected)
        #expect(result.text == Self.raw)
    }

    @Test("Silence is not sent to the model")
    func emptyTranscript() async {
        let result = await TidyService(tidier: StubTidier(output: { _ in "invented" })).run(raw: "  ", enabled: true)
        #expect(result.outcome == .empty)
        #expect(result.text == "  ")
    }
}
