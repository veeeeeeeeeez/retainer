import CoreGraphics
import Foundation

/// Every tunable for the capture gesture lives in this one file:
/// the trigger key, the drag and size thresholds, the lift animation and
/// the tidy pass limits. Change a value here and rebuild.
public struct CaptureConfig: Sendable, Equatable {

    // MARK: Trigger

    /// Virtual key code of the trigger key. 58 is Left Option (`kVK_Option`).
    /// Right Option is 61 and is never treated as the trigger.
    public var triggerKeyCode: Int64 = 58

    /// Device-dependent modifier bit that is set while the trigger key is down.
    /// `0x20` is `NX_DEVICELALTKEYMASK` (Left Option); Right Option is `0x40`.
    public var triggerDeviceMask: UInt64 = 0x20

    // MARK: Selection thresholds

    /// How far (in points) the pointer must travel after mouse-down, with the
    /// trigger held, before the press becomes a selection. Anything shorter
    /// is delivered to the app underneath as an ordinary Option-click.
    public var dragThreshold: CGFloat = 4

    /// Selections smaller than this in either dimension (points) are ignored.
    public var minimumSelectionSize = CGSize(width: 20, height: 20)

    // MARK: Capture card

    /// Duration of the lift from the selection to the centre of the display.
    public var liftDuration: Double = 0.30

    /// The lifted capture is scaled to fit within this fraction of the display.
    public var cardMaxScreenFraction: CGFloat = 0.60

    // MARK: Tidy

    /// If the on-device model takes longer than this, the raw transcript is used.
    public var tidyTimeout: Double = 3.0

    /// The tidied text may not drop below this fraction of the raw transcript's
    /// word count once known fillers are discounted.
    public var tidyMinimumLengthRatio: Double = 0.70

    /// The tidied text may not exceed the raw word count by more than this fraction.
    public var tidyMaximumLengthRatio: Double = 1.05

    /// Share of words in the tidied text that may be absent from the raw
    /// transcript before the result is rejected as a rewrite.
    public var tidyMaximumNovelWordRatio: Double = 0.08

    public init() {}

    public static let standard = CaptureConfig()
}

/// Key codes the gesture cares about besides the trigger.
public enum KeyCode {
    public static let escape: Int64 = 53
    public static let returnKey: Int64 = 36
    public static let keypadEnter: Int64 = 76
}
