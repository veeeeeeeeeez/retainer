import Foundation

/// What is on screen: the board of a stretch of time, or a canvas someone
/// made in a project.
public enum Board: Hashable, Sendable {

    case period(Period)
    /// A `ProjectCanvas`, by its id.
    case canvas(UUID)

    /// Stable across launches. A board's pan and zoom are kept under it, and
    /// it is what tells one board's view from another's.
    public var id: String {
        switch self {
        case .period(let period): period.id
        case .canvas(let id): "canvas:\(id.uuidString)"
        }
    }

    public var canvasID: UUID? {
        if case .canvas(let id) = self { return id }
        return nil
    }

    public var isCanvas: Bool { canvasID != nil }
}
