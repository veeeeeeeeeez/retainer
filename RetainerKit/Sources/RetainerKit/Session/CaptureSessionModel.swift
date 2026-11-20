import CoreGraphics
import Foundation
import Observation

/// Everything the overlay draws for one capture, from the first pixel of the
/// drag to the card closing. The coordinator mutates it; the views observe it.
///
/// All geometry is in the overlay's own space: points, origin at the top-left
/// of the display the drag started on.
@MainActor
@Observable
final class CaptureSessionModel {

    enum Phase: Equatable {
        /// Dragging out the rectangle.
        case selecting
        /// Mouse released; waiting for the screenshot.
        case capturing
        /// The capture is centred and recording continues while the trigger is held.
        case speaking
        /// The trigger was released; the transcript is being finalised and tidied.
        case processing
        case editing
        case closing
    }

    var phase: Phase = .selecting

    let screenSize: CGSize
    /// Distance from the bottom of the display to the pill during the drag,
    /// enough to clear the Dock.
    let pillBottomInset: CGFloat
    let config: CaptureConfig
    let meter: LevelMeter
    let editor = EditorHandle()

    private(set) var selection: CGRect
    var image: CapturedImage?
    /// False while the screenshot still sits where it was taken; true once it
    /// has been sent to the centre.
    var lifted = false

    /// Words heard so far, when the engine reports them.
    var interimText = ""
    var processingLabel = "transcribing"

    /// A message shown with the editor (microphone unavailable, and the like).
    var notice: String?
    /// Quiet metadata under the editor: engine and what tidy did.
    var statusLine = ""
    var editorText = ""
    var initialText = ""
    var editorHeight: CGFloat = 0
    /// Escape was pressed on an edited note; one more press discards it.
    var discardArmed = false

    /// A line under the pill while speaking, for a capture that no key is
    /// being held for: how to say the talking is done.
    var speakingHint: String?

    @ObservationIgnored var onSave: () -> Void = {}
    @ObservationIgnored var onDiscard: () -> Void = {}
    /// Ends the talking, for a capture that no key is being held for.
    @ObservationIgnored var onFinishSpeaking: (() -> Void)?

    init(
        screenSize: CGSize,
        selection: CGRect,
        pillBottomInset: CGFloat,
        meter: LevelMeter,
        config: CaptureConfig = .standard
    ) {
        self.screenSize = screenSize
        self.selection = selection
        self.pillBottomInset = pillBottomInset
        self.meter = meter
        self.config = config
    }

    var hasEdits: Bool { editorText != initialText }

    func updateSelection(_ rect: CGRect) {
        selection = rect
    }

    // MARK: Layout

    static let promptHeight: CGFloat = 22
    static let gapBelowImage: CGFloat = 16
    static let gapAbovePill: CGFloat = 12
    /// Vertical room kept free under the image for the prompt, pill and editor.
    private static let reservedBelow: CGFloat = 190
    private static let minimumContentWidth: CGFloat = 460
    private static let maximumContentWidth: CGFloat = 760

    /// Where the capture rests once lifted: centred, fitted within the
    /// configured fraction of the display, never scaled up.
    var liftedImageFrame: CGRect {
        let natural = image?.pointSize ?? selection.size
        let limit = CGSize(
            width: screenSize.width * config.cardMaxScreenFraction,
            height: screenSize.height * config.cardMaxScreenFraction)
        let fitted = ScreenGeometry.fit(natural, within: limit)
        // Whole points, so the glass over it lands on whole pixels.
        let size = CGSize(width: max(1, fitted.width.rounded()), height: max(1, fitted.height.rounded()))
        let centreY = max((screenSize.height - Self.reservedBelow) / 2, size.height / 2 + 32)
        return CGRect(
            x: ((screenSize.width - size.width) / 2).rounded(),
            y: (centreY - size.height / 2).rounded(),
            width: size.width,
            height: size.height)
    }

    var imageFrame: CGRect { lifted ? liftedImageFrame : selection }

    /// Width of the column under the image (prompt, live words, editor).
    var contentWidth: CGFloat {
        let available = max(240, screenSize.width - 80)
        return min(max(liftedImageFrame.width, Self.minimumContentWidth), Self.maximumContentWidth, available)
    }

    var contentOrigin: CGPoint {
        CGPoint(
            x: ((screenSize.width - contentWidth) / 2).rounded(),
            y: liftedImageFrame.maxY + Self.gapBelowImage)
    }

    /// Centre of the pill: bottom of the display during the drag, directly
    /// under the prompt once the capture has lifted.
    var pillCentre: CGPoint {
        if lifted {
            let y = contentOrigin.y + Self.promptHeight + Self.gapAbovePill + RecordingPill.height / 2
            return CGPoint(x: screenSize.width / 2, y: y)
        }
        return CGPoint(x: screenSize.width / 2, y: screenSize.height - pillBottomInset - RecordingPill.height / 2)
    }

    /// The tallest the editor may grow before it scrolls.
    var editorMaxHeight: CGFloat {
        max(96, screenSize.height - contentOrigin.y - 120)
    }

    /// Selection size as shown in the readout: whole points, like the system tool.
    var dimensionsLabel: String {
        "\(Int(selection.width)) × \(Int(selection.height))"
    }

    /// The end of the interim transcript, cut at a word so it fits a few lines.
    var interimTail: String {
        let limit = 220
        guard interimText.count > limit else { return interimText }
        let tail = interimText.suffix(limit)
        if let space = tail.firstIndex(of: " ") {
            return "…" + tail[space...]
        }
        return "…" + tail
    }
}
