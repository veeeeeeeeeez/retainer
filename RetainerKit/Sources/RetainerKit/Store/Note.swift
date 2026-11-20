import CoreGraphics
import Foundation

public struct CanvasPoint: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public init(_ point: CGPoint) {
        self.init(x: point.x, y: point.y)
    }

    public var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

public struct PixelSize: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// One capture: a screenshot and what was said about it. This is the record
/// stored in `index.json`.
public struct Note: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    /// Path of the PNG, relative to the store directory.
    public var imagePath: String
    public var imagePixelSize: PixelSize
    /// Pixels per point of the display the capture came from.
    public var imageScale: Double
    /// The note as saved and since edited, in Markdown.
    public var note: String
    /// What the speech engine heard, before tidying and before any edits.
    public var rawTranscript: String
    /// `EngineID` raw value, or "none" when the note was typed.
    public var engine: String
    /// Whether tidy was switched on for this capture.
    public var tidy: Bool
    /// What the tidy pass actually did. Absent in records written without it.
    public var tidyOutcome: TidyOutcome?
    public var timestamp: Date
    public var sourceApp: String?
    public var windowTitle: String?
    /// A link back to what the capture was taken from, when the app in
    /// front offered one: the page's address for a browser, a `file:` URL
    /// for a document.
    public var sourceURL: String?
    /// Top-left corner of the card on the board of the day it was saved.
    public var position: CanvasPoint
    /// When the note was put away in the archive. `nil` while it is on the canvas.
    public var archivedAt: Date?
    /// False from the moment a capture is saved until its card has been
    /// looked at in the window.
    public var seen: Bool

    public init(
        id: UUID = UUID(),
        imagePath: String,
        imagePixelSize: PixelSize,
        imageScale: Double,
        note: String,
        rawTranscript: String,
        engine: String,
        tidy: Bool,
        tidyOutcome: TidyOutcome? = nil,
        timestamp: Date = Date(),
        sourceApp: String? = nil,
        windowTitle: String? = nil,
        sourceURL: String? = nil,
        position: CanvasPoint = CanvasPoint(x: 0, y: 0),
        archivedAt: Date? = nil,
        seen: Bool = true
    ) {
        self.id = id
        self.imagePath = imagePath
        self.imagePixelSize = imagePixelSize
        self.imageScale = imageScale
        self.note = note
        self.rawTranscript = rawTranscript
        self.engine = engine
        self.tidy = tidy
        self.tidyOutcome = tidyOutcome
        self.timestamp = timestamp
        self.sourceApp = sourceApp
        self.windowTitle = windowTitle
        self.sourceURL = sourceURL
        self.position = position
        self.archivedAt = archivedAt
        self.seen = seen
    }

    /// Reads a record, including ones written before `archivedAt` and `seen`
    /// existed: those notes are on the canvas and count as seen.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        imagePath = try container.decode(String.self, forKey: .imagePath)
        imagePixelSize = try container.decode(PixelSize.self, forKey: .imagePixelSize)
        imageScale = try container.decode(Double.self, forKey: .imageScale)
        note = try container.decode(String.self, forKey: .note)
        rawTranscript = try container.decode(String.self, forKey: .rawTranscript)
        engine = try container.decode(String.self, forKey: .engine)
        tidy = try container.decode(Bool.self, forKey: .tidy)
        tidyOutcome = try container.decodeIfPresent(TidyOutcome.self, forKey: .tidyOutcome)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        windowTitle = try container.decodeIfPresent(String.self, forKey: .windowTitle)
        sourceURL = try container.decodeIfPresent(String.self, forKey: .sourceURL)
        position = try container.decode(CanvasPoint.self, forKey: .position)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        seen = try container.decodeIfPresent(Bool.self, forKey: .seen) ?? true
    }

    /// Words typed into the input box with nothing attached. Its card is
    /// the words alone; the small picture kept for it is only for the
    /// places that show nothing but pictures (the timeline, a group's tile).
    public var isTextOnly: Bool { sourceApp == "Typed" && sourceURL == nil }

    public var isArchived: Bool { archivedAt != nil }

    /// Width divided by height of the screenshot.
    public var imageAspectRatio: Double {
        guard imagePixelSize.height > 0 else { return 1 }
        return Double(imagePixelSize.width) / Double(imagePixelSize.height)
    }

    /// Size of the screenshot in points on the display it was taken from.
    public var imagePointSize: CGSize {
        let scale = imageScale > 0 ? imageScale : 1
        return CGSize(width: Double(imagePixelSize.width) / scale, height: Double(imagePixelSize.height) / scale)
    }
}

/// The on-disk shape of `index.json`.
struct NoteIndex: Codable {
    var version: Int
    var notes: [Note]
    var projects: [Project]
    var canvases: [ProjectCanvas]
    /// Cards put together on a board. Added without a new version: no
    /// earlier file has a key of this name, and a file without it has none.
    var groups: [NoteGroup]

    /// Version 1 was notes only. Version 2 filed them into projects and
    /// canvases, which did not last. Version 3 was notes only again: a note
    /// belongs to the day it was saved on, and that is in its timestamp.
    /// Version 4 adds projects and canvases beside that: a canvas is a
    /// second arrangement of notes that are still on their days.
    static let currentVersion = 4
    /// From this version on, cards on a day's board were kept from landing
    /// on top of one another. Files older than it have theirs moved apart.
    static let firstTidyVersion = 3

    init(
        version: Int, notes: [Note], projects: [Project] = [], canvases: [ProjectCanvas] = [],
        groups: [NoteGroup] = []
    ) {
        self.version = version
        self.notes = notes
        self.projects = projects
        self.canvases = canvases
        self.groups = groups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        notes = try container.decode([Note].self, forKey: .notes)
        // Only a file of this version or later has projects and canvases in
        // this shape. Version 2 used the same two names for something
        // else: read as these, its projects would come back to life and its
        // canvases would fail to parse and take the whole file with them.
        if version >= 4 {
            projects = try container.decodeIfPresent([Project].self, forKey: .projects) ?? []
            canvases = try container.decodeIfPresent([ProjectCanvas].self, forKey: .canvases) ?? []
        } else {
            projects = []
            canvases = []
        }
        groups = try container.decodeIfPresent([NoteGroup].self, forKey: .groups) ?? []
    }
}
