import CoreGraphics
import Foundation

// MARK: - Inputs

/// Which modifier keys are down, reduced to what the gesture needs.
public struct ModifierState: Sendable, Equatable {
    /// The trigger key itself (Left Option by default).
    public var trigger: Bool
    /// Any other modifier: Right Option, Shift, Control, Command or Fn.
    public var others: Bool
    /// Option on either side, from the device-independent flag. Unlike the
    /// sided bits this is present on every event, so its absence is proof
    /// that the trigger is up.
    public var option: Bool

    public init(trigger: Bool, others: Bool, option: Bool? = nil) {
        self.trigger = trigger
        self.others = others
        self.option = option ?? trigger
    }

    public static let none = ModifierState(trigger: false, others: false)

    /// Decodes raw `CGEventFlags` bits.
    ///
    /// Sided keys are read from the device-dependent bits in the low word
    /// (`NX_DEVICE…KEYMASK`), which is the only place Left and Right Option differ.
    public init(rawFlags: UInt64, triggerDeviceMask: UInt64) {
        // NX_DEVICE masks: LCTL 0x1, LSHIFT 0x2, RSHIFT 0x4, LCMD 0x8, RCMD 0x10,
        // LALT 0x20, RALT 0x40, RCTL 0x2000.
        let sidedMasks: UInt64 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000
        // Device-independent masks: Shift, Control, Command, Fn.
        let genericOthers: UInt64 = 0x0002_0000 | 0x0004_0000 | 0x0010_0000 | 0x0080_0000
        let genericOption: UInt64 = 0x0008_0000
        trigger = rawFlags & triggerDeviceMask != 0
        others = rawFlags & genericOthers != 0 || rawFlags & sidedMasks & ~triggerDeviceMask != 0
        option = rawFlags & genericOption != 0 || trigger
    }

    /// Decodes a modifier-change event.
    ///
    /// Normally the sided bits say whether the trigger is down. A few event
    /// sources (some remote-control and remapping tools) set only the
    /// device-independent flags. Then the key code of the key that changed
    /// decides: if it is the trigger's (58, Left Option), the trigger toggled;
    /// if it is any other key, the trigger is where it was.
    public static func decode(
        rawFlags: UInt64, changedKeyCode: Int64, previousTrigger: Bool, config: CaptureConfig
    ) -> ModifierState {
        var state = ModifierState(rawFlags: rawFlags, triggerDeviceMask: config.triggerDeviceMask)
        let sidedMasks: UInt64 = 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x40 | 0x2000
        guard state.option, rawFlags & sidedMasks == 0 else { return state }

        if changedKeyCode == config.triggerKeyCode {
            state.trigger = !previousTrigger
        } else {
            state.trigger = previousTrigger
            // Some Option key went down that is not the trigger.
            if !previousTrigger { state.others = true }
        }
        return state
    }
}

/// The display a selection lives on, in global display coordinates
/// (origin at the top-left of the main display, y increasing downwards).
public struct DisplayInfo: Sendable, Equatable {
    public var id: UInt32
    public var bounds: CGRect

    public init(id: UInt32, bounds: CGRect) {
        self.id = id
        self.bounds = bounds
    }
}

/// A hardware event, stripped down to what the gesture needs.
public enum InputEvent: Sendable, Equatable {
    case flagsChanged(ModifierState)
    case keyDown(keyCode: Int64)
    case keyUp(keyCode: Int64)
    case leftMouseDown(CGPoint)
    case leftMouseDragged(CGPoint)
    case leftMouseUp(CGPoint)
}

// MARK: - Outputs

public enum CancelReason: Sendable, Equatable {
    /// The trigger key was released before the mouse button.
    case triggerReleased
    case escape
    /// The selection was smaller than `CaptureConfig.minimumSelectionSize`.
    case tooSmall
    /// The event tap lost events and the gesture could not be trusted.
    case interrupted
}

/// What the rest of the app should do in response to input.
public enum GestureAction: Sendable, Equatable {
    /// The drag passed the threshold. Recording starts here.
    case selectionBegan(rect: CGRect, display: DisplayInfo)
    case selectionChanged(rect: CGRect)
    /// The mouse was released on a valid selection; the trigger is still held.
    case selectionEnded(rect: CGRect)
    case selectionCancelled(CancelReason)
    /// The trigger was released after a capture: stop recording and transcribe.
    case holdEnded
    /// Escape was pressed while the capture card was up and the trigger held.
    case escapePressed
    /// A capture gesture was made while capture is switched off.
    case attemptedWhileDisabled
}

/// What to do with the event that was just handled.
public enum EventDisposition: Sendable, Equatable {
    /// Deliver the event to the system unchanged.
    case pass
    /// Swallow the event.
    case consume
    /// Swallow the event for now but keep it, so it can be replayed if the
    /// press turns out to be an ordinary click.
    case hold
}

/// What to do with events that were held earlier.
public enum HeldEvents: Sendable, Equatable {
    case keep
    /// Deliver them, in order, ahead of the current event.
    case replay
    case drop
}

public struct GestureOutput: Sendable, Equatable {
    public var disposition: EventDisposition
    public var held: HeldEvents
    public var actions: [GestureAction]

    public init(_ disposition: EventDisposition = .pass, held: HeldEvents = .keep, actions: [GestureAction] = []) {
        self.disposition = disposition
        self.held = held
        self.actions = actions
    }

    public static let pass = GestureOutput(.pass)
}

// MARK: - Recognizer

/// The hold-and-drag gesture as a pure state machine.
///
/// It decides, for every keyboard and mouse event, whether the event belongs
/// to a capture or must reach the app underneath untouched. It owns no system
/// resources, which is what makes the pass-through rules testable:
///
/// * The trigger must go down alone and stay alone. Any other modifier, or any
///   key press, disqualifies the hold until the trigger is released.
/// * A mouse press while armed is held back, not consumed. If the pointer
///   travels past the drag threshold the press becomes a selection and the
///   held events are dropped. If the button comes up first, the held events
///   are replayed and the app underneath sees an ordinary Option-click.
/// * Once a selection starts, mouse events are consumed until the button is
///   released, even if the gesture is cancelled part-way.
public struct GestureRecognizer: Sendable {

    public enum Phase: Sendable, Equatable {
        /// Trigger up.
        case idle
        /// Trigger down, alone. Waiting for a mouse press.
        case armed
        /// Trigger down but disqualified. Everything passes until it is released.
        case tainted
        /// Mouse down while armed. `holding` is false when capture is disabled,
        /// in which case events pass and the press is only being watched.
        case pressed(start: CGPoint, display: DisplayInfo, holding: Bool)
        /// Dragging out a selection. Mouse events are consumed.
        case selecting(start: CGPoint, display: DisplayInfo)
        /// A selection was cancelled while the button is still down.
        case swallowing
        /// A capture was taken and the trigger is still held.
        case speaking
        /// A capture card is open on the main side. Everything passes.
        case suspended
    }

    public let config: CaptureConfig
    public private(set) var phase: Phase = .idle
    public private(set) var triggerDown = false

    /// False while permissions or the speech model are missing. Gestures are
    /// then observed but never intercepted.
    public var isEnabled = true

    private var swallowEscapeKeyUp = false
    private let displayLookup: @Sendable (CGPoint) -> DisplayInfo?

    public init(config: CaptureConfig = .standard, displayLookup: @escaping @Sendable (CGPoint) -> DisplayInfo?) {
        self.config = config
        self.displayLookup = displayLookup
    }

    // MARK: Event handling

    /// - Parameter carried: The modifier flags on the event itself, when it is
    ///   a mouse event. They are a second opinion on the tracked state: if a
    ///   modifier change was never delivered (secure input, a tap that was
    ///   briefly disabled), the next mouse event still tells the truth.
    public mutating func handle(_ event: InputEvent, carrying carried: ModifierState? = nil) -> GestureOutput {
        var missed: GestureOutput?
        if let carried, isMouse(event) {
            missed = reconcile(with: carried)
        }

        let output: GestureOutput
        switch event {
        case .flagsChanged(let modifiers): output = handleFlags(modifiers)
        case .keyDown(let keyCode): output = handleKeyDown(keyCode)
        case .keyUp(let keyCode): output = handleKeyUp(keyCode)
        case .leftMouseDown(let point): output = handleMouseDown(point)
        case .leftMouseDragged(let point): output = handleMouseDragged(point)
        case .leftMouseUp(let point): output = handleMouseUp(point)
        }

        guard let missed else { return output }
        // The missed change is applied first; its held-event verdict and
        // actions come ahead of this event's own.
        return GestureOutput(
            output.disposition,
            held: missed.held != .keep ? missed.held : output.held,
            actions: missed.actions + output.actions)
    }

    private func isMouse(_ event: InputEvent) -> Bool {
        switch event {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: true
        case .flagsChanged, .keyDown, .keyUp: false
        }
    }

    /// Applies a modifier change that the flags on a mouse event prove must
    /// have happened without being seen. Only ever moves towards "not a
    /// capture": a missed release ends the hold, a missed extra modifier
    /// disqualifies it. A missed press is ignored.
    private mutating func reconcile(with carried: ModifierState) -> GestureOutput? {
        if triggerDown && !carried.option {
            return handleFlags(ModifierState(trigger: false, others: carried.others, option: false))
        }
        if triggerDown && carried.others {
            switch phase {
            case .armed, .pressed:
                return handleFlags(ModifierState(trigger: true, others: true))
            default:
                break
            }
        }
        return nil
    }

    private mutating func handleFlags(_ modifiers: ModifierState) -> GestureOutput {
        let wasDown = triggerDown
        triggerDown = modifiers.trigger

        if !wasDown && triggerDown {
            // Trigger pressed. It only arms when nothing else is held.
            if phase == .idle {
                phase = modifiers.others ? .tainted : .armed
            }
            return .pass
        }

        if wasDown && !triggerDown {
            // Trigger released. Modifier events themselves always pass.
            switch phase {
            case .idle, .suspended, .swallowing:
                return .pass
            case .armed, .tainted:
                phase = .idle
                return .pass
            case .pressed(_, _, let holding):
                phase = .idle
                return GestureOutput(.pass, held: holding ? .replay : .keep)
            case .selecting:
                phase = .swallowing
                return GestureOutput(.pass, actions: [.selectionCancelled(.triggerReleased)])
            case .speaking:
                phase = .suspended
                return GestureOutput(.pass, actions: [.holdEnded])
            }
        }

        // Trigger unchanged: some other modifier went down or up.
        if triggerDown && modifiers.others {
            switch phase {
            case .armed:
                phase = .tainted
            case .pressed(_, _, let holding):
                phase = .tainted
                return GestureOutput(.pass, held: holding ? .replay : .keep)
            default:
                break
            }
        }
        return .pass
    }

    private mutating func handleKeyDown(_ keyCode: Int64) -> GestureOutput {
        switch phase {
        case .armed:
            // Option used as a modifier for a shortcut or a special character.
            phase = .tainted
            return .pass
        case .pressed(_, _, let holding):
            phase = .tainted
            return GestureOutput(.pass, held: holding ? .replay : .keep)
        case .selecting:
            guard keyCode == KeyCode.escape else { return .pass }
            phase = .swallowing
            swallowEscapeKeyUp = true
            return GestureOutput(.consume, actions: [.selectionCancelled(.escape)])
        case .speaking:
            guard keyCode == KeyCode.escape else { return .pass }
            // The trigger is still down; require a fresh press for the next capture.
            phase = .tainted
            swallowEscapeKeyUp = true
            return GestureOutput(.consume, actions: [.escapePressed])
        case .idle, .tainted, .swallowing, .suspended:
            return .pass
        }
    }

    private mutating func handleKeyUp(_ keyCode: Int64) -> GestureOutput {
        if keyCode == KeyCode.escape && swallowEscapeKeyUp {
            swallowEscapeKeyUp = false
            return GestureOutput(.consume)
        }
        return .pass
    }

    private mutating func handleMouseDown(_ point: CGPoint) -> GestureOutput {
        switch phase {
        case .armed:
            guard let display = displayLookup(point) else { return .pass }
            phase = .pressed(start: point, display: display, holding: isEnabled)
            return GestureOutput(isEnabled ? .hold : .pass)
        case .swallowing:
            // A button-up went missing. Recover rather than eat a fresh click.
            phase = triggerDown ? .tainted : .idle
            return .pass
        default:
            return .pass
        }
    }

    private mutating func handleMouseDragged(_ point: CGPoint) -> GestureOutput {
        switch phase {
        case .pressed(let start, let display, let holding):
            let distance = hypot(point.x - start.x, point.y - start.y)
            guard distance > config.dragThreshold else {
                return GestureOutput(holding ? .hold : .pass)
            }
            guard holding else {
                phase = .tainted
                return GestureOutput(.pass, actions: [.attemptedWhileDisabled])
            }
            phase = .selecting(start: start, display: display)
            let rect = Self.selectionRect(from: start, to: point, in: display.bounds)
            return GestureOutput(.consume, held: .drop, actions: [.selectionBegan(rect: rect, display: display)])
        case .selecting(let start, let display):
            let rect = Self.selectionRect(from: start, to: point, in: display.bounds)
            return GestureOutput(.consume, actions: [.selectionChanged(rect: rect)])
        case .swallowing:
            return GestureOutput(.consume)
        default:
            return .pass
        }
    }

    private mutating func handleMouseUp(_ point: CGPoint) -> GestureOutput {
        switch phase {
        case .pressed(_, _, let holding):
            // Never became a drag: an ordinary Option-click.
            phase = .armed
            return GestureOutput(.pass, held: holding ? .replay : .keep)
        case .selecting(let start, let display):
            let rect = Self.selectionRect(from: start, to: point, in: display.bounds)
            let minimum = config.minimumSelectionSize
            if rect.width >= minimum.width && rect.height >= minimum.height {
                phase = .speaking
                return GestureOutput(.consume, actions: [.selectionEnded(rect: rect)])
            }
            phase = .armed
            return GestureOutput(.consume, actions: [.selectionCancelled(.tooSmall)])
        case .swallowing:
            phase = triggerDown ? .tainted : .idle
            return GestureOutput(.consume)
        default:
            return .pass
        }
    }

    // MARK: Session control (called from the main side)

    /// The capture card closed. Capturing may resume once the trigger has been
    /// released and pressed again.
    public mutating func sessionEnded() {
        switch phase {
        case .speaking, .suspended:
            phase = triggerDown ? .tainted : .idle
        default:
            break
        }
    }

    /// The card went straight to the editor while the trigger is still held
    /// (microphone unavailable). Stop treating the hold as a recording.
    public mutating func suspend() {
        if phase == .speaking { phase = .suspended }
    }

    /// Ends a capture whose trigger release was never delivered.
    ///
    /// Called periodically while a capture is on screen, with the physical
    /// state of the trigger key. Ending the recording depends on seeing the
    /// trigger released; if that one event were lost, the overlay would stay
    /// up with the microphone on. This makes sure it cannot.
    ///
    /// It deliberately knows nothing about the mouse button. The button's
    /// state cannot be read back reliably while this app is swallowing the
    /// button's events, and a wrong reading here would cancel a drag that is
    /// still in progress.
    public mutating func verifyActive(triggerDown actualTrigger: Bool) -> GestureOutput {
        guard !actualTrigger else { return .pass }
        switch phase {
        case .selecting:
            triggerDown = false
            // The button is presumably still down; keep eating its events.
            phase = .swallowing
            return GestureOutput(.pass, actions: [.selectionCancelled(.triggerReleased)])
        case .speaking:
            triggerDown = false
            phase = .suspended
            return GestureOutput(.pass, actions: [.holdEnded])
        case .idle, .armed, .tainted, .pressed, .swallowing, .suspended:
            return .pass
        }
    }

    /// The event tap was disabled by the system and re-enabled, so events may
    /// have been missed. Reconcile with the real key and button state.
    public mutating func resync(triggerDown actualTrigger: Bool, mouseDown: Bool) -> GestureOutput {
        triggerDown = actualTrigger
        swallowEscapeKeyUp = false
        switch phase {
        case .idle, .armed, .tainted:
            phase = actualTrigger ? .tainted : .idle
            return .pass
        case .pressed:
            // Held events cannot be replayed from here; the click is lost.
            phase = actualTrigger ? .tainted : .idle
            return GestureOutput(.pass, held: .drop)
        case .selecting:
            if actualTrigger && mouseDown { return .pass }
            phase = mouseDown ? .swallowing : (actualTrigger ? .tainted : .idle)
            return GestureOutput(.pass, actions: [.selectionCancelled(.interrupted)])
        case .swallowing:
            if !mouseDown { phase = actualTrigger ? .tainted : .idle }
            return .pass
        case .speaking:
            guard !actualTrigger else { return .pass }
            phase = .suspended
            return GestureOutput(.pass, actions: [.holdEnded])
        case .suspended:
            return .pass
        }
    }

    // MARK: Geometry

    /// The rectangle between two points, snapped to whole points and clamped
    /// to the display the drag started on.
    public static func selectionRect(from start: CGPoint, to end: CGPoint, in bounds: CGRect) -> CGRect {
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x.rounded(), bounds.minX), bounds.maxX) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y.rounded(), bounds.minY), bounds.maxY) }
        let x0 = clampX(min(start.x, end.x))
        let x1 = clampX(max(start.x, end.x))
        let y0 = clampY(min(start.y, end.y))
        let y1 = clampY(max(start.y, end.y))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
