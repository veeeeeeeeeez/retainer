import CoreGraphics
import Foundation

/// Draws stand-in screenshots: a page with a headline, lines of text and a
/// coloured figure. Enough to judge the interface against real-looking
/// content without any.
enum SampleArt {

    static func article(size: CGSize, scale: CGFloat, seed: Int = 0, dark: Bool = false) -> CGImage {
        let width = Int(size.width * scale)
        let height = Int(size.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: scale, y: scale)
        // Flip so drawing runs top-down.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)

        context.setFillColor(
            dark
                ? CGColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
                : CGColor(srgbRed: 0.98, green: 0.975, blue: 0.96, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let margin: CGFloat = 36
        let palette: [CGColor] = [
            CGColor(srgbRed: 0.16, green: 0.42, blue: 0.78, alpha: 1),
            CGColor(srgbRed: 0.82, green: 0.30, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.18, green: 0.58, blue: 0.42, alpha: 1),
            CGColor(srgbRed: 0.80, green: 0.56, blue: 0.16, alpha: 1),
            CGColor(srgbRed: 0.46, green: 0.34, blue: 0.72, alpha: 1),
        ]
        // Headline.
        context.setFillColor(CGColor(gray: dark ? 0.92 : 0.12, alpha: 1))
        context.fill(CGRect(x: margin, y: margin, width: min(size.width * 0.55, 420), height: 16))
        context.fill(CGRect(x: margin, y: margin + 26, width: min(size.width * 0.38, 300), height: 16))

        // A figure on the right.
        let figure = CGRect(
            x: size.width - margin - min(220, size.width * 0.3), y: margin,
            width: min(220, size.width * 0.3), height: min(140, size.height * 0.45))
        context.setFillColor(palette[abs(seed) % palette.count])
        context.fill(figure)
        context.setFillColor(CGColor(gray: 1, alpha: 0.35))
        for bar in 0..<5 {
            let barHeight = figure.height * CGFloat([0.35, 0.6, 0.45, 0.8, 0.55][(bar + abs(seed)) % 5])
            context.fill(
                CGRect(
                    x: figure.minX + 16 + CGFloat(bar) * (figure.width - 32) / 5,
                    y: figure.maxY - 12 - barHeight, width: (figure.width - 32) / 5 - 8, height: barHeight))
        }

        // Body text lines.
        context.setFillColor(CGColor(gray: dark ? 0.45 : 0.55, alpha: 1))
        var y = margin + 70
        var line = 0
        let textWidth = size.width - margin * 2 - (y < figure.maxY ? figure.width + 24 : 0)
        while y < size.height - margin {
            let available = y < figure.maxY + 8 ? textWidth : size.width - margin * 2
            let fraction: CGFloat = [1.0, 0.96, 0.99, 0.72, 1.0, 0.94, 0.6][(line + abs(seed)) % 7]
            context.fill(CGRect(x: margin, y: y, width: available * fraction, height: 7))
            y += (line + abs(seed)) % 7 == 3 ? 30 : 16
            line += 1
        }
        return context.makeImage()!
    }

    static func crop(_ image: CGImage, rect: CGRect, scale: CGFloat) -> CGImage {
        let pixels = CGRect(
            x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        return image.cropping(to: pixels) ?? image
    }
}

/// Made-up captures on past days, so the timeline has something to show
/// while there are few real days to look at.
///
/// They are generated, not stored: the same days and the same notes every
/// time, worked out from the date, with pictures drawn by `SampleArt` and
/// kept in a cache folder apart from the real notes. They can be opened,
/// edited, archived and deleted like any note, but nothing done to them is
/// saved, and they come back as they were at the next launch. Today never
/// gets any: today's board is for real captures.
public enum SampleDays {

    struct Sample: Sendable {
        var note: Note
        let size: CGSize
        let seed: Int
        let dark: Bool
    }

    /// How far back the made-up days go.
    static let reach = 60

    /// Where the samples' pictures are kept.
    public static var imagesDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("blog.terminal.app/sample-days-1", isDirectory: true)
    }

    private static let texts: [String] = [
        "The claim in the second paragraph rests on a sample of forty people. I would not quote it without the follow-up study.",
        "This is the clearest diagram of the pipeline I have seen. The **retry path** is the part we got wrong last quarter.",
        "Short one. Keep this number.",
        "The pricing table is out of date but the structure is worth copying.",
        "Good framing of the trade-off. Things to check:\n\n- who funded it\n- whether it holds for small teams\n- the original wording",
        "Come back to this when planning the next release. The second chart is the one that matters.",
        "I disagree with the conclusion, but the method section is careful and worth borrowing.",
        "Ask about this on Thursday. It contradicts what we were told in the review.",
        "A nice example of saying a hard thing plainly.",
        "The layout here solves the problem we have with long tables.",
        "Worth comparing with the earlier study before quoting any of this.",
        "Two ideas in here: the first is obvious, the second is the reason to keep it.",
        "Send this to the team. It explains the migration better than our own notes do.",
        "The numbers in the footnote do not add up. Check the source.",
        "Reference for the colour work: note how little contrast the secondary text needs.",
        "Not sure yet what I think. Leaving it here to look at again.",
    ]

    private static let sources: [(app: String, title: String, link: String?)] = [
        ("Safari", "The Economics of Attention", "https://www.example.org/essays/the-economics-of-attention"),
        ("Chrome", "How the retry queue works – Engineering Blog", "https://engineering.example.com/retry-queue"),
        ("Chrome", "A talk on interface density – YouTube", "https://www.youtube.com/watch?v=sample0001"),
        ("Preview", "architecture-review.pdf", "file:///Users/Shared/Documents/architecture-review.pdf"),
        ("Numbers", "Q3 forecast", nil),
        ("Safari", "Pricing – Example Co", "https://www.example.com/pricing"),
        ("Chrome", "Designing for long tables", "https://www.example.net/articles/long-tables"),
        ("Preview", "survey-results.pdf", "file:///Users/Shared/Documents/survey-results.pdf"),
        ("Safari", "What we learned migrating the index", "https://blog.example.io/migrating-the-index"),
        ("Notes", "Meeting notes", nil),
        ("Chrome", "Typography on the Mac – YouTube", "https://www.youtube.com/watch?v=sample0002"),
        ("Safari", "A field guide to contrast", "https://www.example.org/guides/contrast"),
    ]

    private static let sizes: [CGSize] = [
        CGSize(width: 760, height: 360), CGSize(width: 520, height: 520), CGSize(width: 640, height: 220),
        CGSize(width: 700, height: 420), CGSize(width: 480, height: 600), CGSize(width: 800, height: 300),
    ]

    /// A small repeatable generator: the same seed gives the same days.
    private struct Generator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }

        mutating func below(_ bound: Int) -> Int {
            Int(next() % UInt64(max(bound, 1)))
        }
    }

    /// The made-up notes for the days before `now`, each with what is needed
    /// to draw its picture. A given day always gets the same notes.
    static func samples(now: Date, calendar: Calendar) -> [Sample] {
        var samples: [Sample] = []
        let today = calendar.startOfDay(for: now)
        for daysAgo in 1...reach {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: today) else { continue }
            // The day's place in history, so its notes do not change as it recedes.
            let dayNumber = calendar.ordinality(of: .day, in: .era, for: day) ?? daysAgo
            var generator = Generator(state: UInt64(truncatingIfNeeded: dayNumber) &* 0x2545_F491_4F6C_DD1D)
            // About two days in five are quiet; yesterday always has something.
            let roll = generator.below(10)
            var count = roll < 4 ? 0 : 1 + generator.below(4)
            if daysAgo == 1 { count = max(count, 3) }

            var placed: [CGRect] = []
            var minute = 9 * 60 + generator.below(120)
            for index in 0..<count {
                let source = sources[generator.below(sources.count)]
                let text = texts[generator.below(texts.count)]
                let size = sizes[generator.below(sizes.count)]
                let dark = generator.below(10) < 3
                let seed = generator.below(1000)

                var bytes = [UInt8](repeating: 0, count: 16)
                var identity = Generator(state: UInt64(truncatingIfNeeded: dayNumber &* 1000 &+ index))
                for position in bytes.indices { bytes[position] = UInt8(truncatingIfNeeded: identity.next()) }
                let id = UUID(
                    uuid: (
                        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                        bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
                    ))

                let pixels = PixelSize(width: Int(size.width * 2), height: Int(size.height * 2))
                let height = NodeLayout.estimatedHeight(
                    imageAspectRatio: Double(size.width / size.height), note: text, hasSourceLink: source.link != nil)
                let frameSize = CGSize(width: CanvasModel.nodeWidth, height: height)
                let origin = CanvasLayout.freeOrigin(for: frameSize, near: .zero, avoiding: placed)
                placed.append(CGRect(origin: origin, size: frameSize))

                let note = Note(
                    id: id,
                    imagePath: "samples/\(id.uuidString).png",
                    imagePixelSize: pixels,
                    imageScale: 2,
                    note: text,
                    rawTranscript: text,
                    engine: EngineID.parakeet.rawValue,
                    tidy: true,
                    tidyOutcome: .applied,
                    timestamp: day.addingTimeInterval(TimeInterval(minute * 60)),
                    sourceApp: source.app,
                    windowTitle: source.title,
                    sourceURL: source.link,
                    position: CanvasPoint(origin),
                    seen: true)
                samples.append(Sample(note: note, size: size, seed: seed, dark: dark))
                minute = min(minute + 20 + generator.below(150), 23 * 60 + 30)
            }
        }
        return samples
    }

    /// Draws and writes any of the samples' pictures that are not in
    /// `directory` yet. Slow the first time: call it off the main thread.
    static func writeMissingImages(for samples: [Sample], to directory: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for sample in samples {
            let url = directory.appendingPathComponent("\(sample.note.id.uuidString).png")
            guard !fileManager.fileExists(atPath: url.path) else { continue }
            let image = SampleArt.article(size: sample.size, scale: 2, seed: sample.seed, dark: sample.dark)
            try? ImageFiles.writePNG(image, scale: 2, to: url)
        }
    }

    /// Puts the sample days into a store. Their pictures are drawn first, in
    /// the background, so the notes appear with them.
    @MainActor
    public static func install(in store: NoteStore, now: Date = Date()) async {
        let samples = samples(now: now, calendar: store.calendar)
        let directory = imagesDirectory
        await Task.detached(priority: .utility) {
            writeMissingImages(for: samples, to: directory)
        }.value
        store.setSampleNotes(samples.map(\.note), imagesIn: directory)
    }

    /// Takes the sample days out of a store again.
    @MainActor
    public static func remove(from store: NoteStore) {
        store.setSampleNotes([], imagesIn: nil)
    }
}
