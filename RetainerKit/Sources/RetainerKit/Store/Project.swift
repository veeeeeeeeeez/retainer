import CoreGraphics
import Foundation

/// A named group of canvases: a way of keeping cards together that is not
/// about when they were saved.
public struct Project: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var createdAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A board the user made and named, inside a project.
///
/// It is a second arrangement of notes. A note put on a canvas has a
/// position there of its own, and is still on the board of the day it was
/// saved, where it has another. Taking it off the canvas does not delete it.
///
/// (Not called `Canvas`: that is SwiftUI's drawing view, which the board,
/// the mini map and the glass all use.)
public struct ProjectCanvas: Codable, Sendable, Equatable, Identifiable {

    /// One note on the canvas, and where.
    public struct Placement: Codable, Sendable, Equatable {
        public var noteID: UUID
        /// Top-left corner of the card, on this canvas.
        public var position: CanvasPoint

        public init(noteID: UUID, position: CanvasPoint) {
            self.noteID = noteID
            self.position = position
        }
    }

    public var id: UUID
    public var projectID: UUID
    public var name: String
    public var createdAt: Date
    /// The notes on it, in the order they were put there.
    public var cards: [Placement]

    public init(
        id: UUID = UUID(), projectID: UUID, name: String, createdAt: Date = Date(), cards: [Placement] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.createdAt = createdAt
        self.cards = cards
    }
}
