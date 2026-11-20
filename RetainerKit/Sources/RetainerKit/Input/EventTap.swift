import CoreGraphics
import Foundation
import os

/// Looks up the display under a point in global display coordinates.
public enum DisplayLookup {
    public static let live: @Sendable (CGPoint) -> DisplayInfo? = { point in
        var displayID: CGDirectDisplayID = 0
        var count: UInt32 = 0
        if CGGetDisplaysWithPoint(point, 1, &displayID, &count) == .success, count > 0 {
            return DisplayInfo(id: displayID, bounds: CGDisplayBounds(displayID))
        }
        // The pointer can sit a fraction outside every display at an edge.
        let main = CGMainDisplayID()
        return DisplayInfo(id: main, bounds: CGDisplayBounds(main))
    }
}

/// A global `CGEventTap` that feeds keyboard and mouse events to a
/// `GestureRecognizer` and applies its verdicts.
///
/// The tap is active (it can swallow events), so every event in the session
/// waits on its callback. The callback therefore runs on a dedicated thread
/// and does nothing but advance the state machine; all real work happens on
/// the main actor via `onActions`.
public final class EventTap: @unchecked Sendable {

    public typealias ActionHandler = @Sendable ([GestureAction]) -> Void

    /// Marks events this tap re-posts so it never handles them twice.
    private static let replayMarker: Int64 = 0x7465_726D  // "term"
    private static let maxHeldEvents = 64

    private struct State {
        var recognizer: GestureRecognizer
        var held: [CGEvent] = []
        var port: CFMachPort?
        var runLoop: CFRunLoop?
        /// Consecutive watchdog readings that found the trigger key up.
        var triggerUpReadings = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let onActions: ActionHandler
    private let config: CaptureConfig
    private let triggerDeviceMask: UInt64
    private let triggerKeyCode: CGKeyCode
    private static let log = Logger(subsystem: "blog.terminal.app", category: "event-tap")

    public init(
        config: CaptureConfig = .standard,
        displayLookup: @escaping @Sendable (CGPoint) -> DisplayInfo? = DisplayLookup.live,
        onActions: @escaping ActionHandler
    ) {
        self.config = config
        self.triggerDeviceMask = config.triggerDeviceMask
        self.triggerKeyCode = CGKeyCode(config.triggerKeyCode)
        self.onActions = onActions
        self.state = OSAllocatedUnfairLock(
            uncheckedState: State(recognizer: GestureRecognizer(config: config, displayLookup: displayLookup)))
    }

    public var isRunning: Bool {
        state.withLockUnchecked { $0.port != nil }
    }

    /// Installs the tap. Returns false when the system refuses, which means
    /// Accessibility (or Input Monitoring) has not been granted.
    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }

        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }

        guard
            let port = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: mask,
                callback: eventTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return false
        }

        state.withLockUnchecked { $0.port = port }

        let box = UncheckedBox((port, source))
        // The thread holds the tap strongly: the callback receives an
        // unretained pointer to it, so it must outlive the run loop.
        let thread = Thread { [self] in
            let (port, source) = box.value
            let runLoop = CFRunLoopGetCurrent()
            state.withLockUnchecked { $0.runLoop = runLoop }
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "blog.terminal.event-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    public func stop() {
        let (port, runLoop) = state.withLockUnchecked { state -> (CFMachPort?, CFRunLoop?) in
            let result = (state.port, state.runLoop)
            state.port = nil
            state.runLoop = nil
            state.held.removeAll()
            return result
        }
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    // MARK: Control from the main side

    /// Switches interception on or off. While off, gestures are only observed.
    public func setEnabled(_ enabled: Bool) {
        state.withLockUnchecked { $0.recognizer.isEnabled = enabled }
    }

    /// The capture card has closed.
    public func sessionEnded() {
        state.withLockUnchecked { $0.recognizer.sessionEnded() }
    }

    /// The card moved to the editor while the trigger is still held.
    public func suspend() {
        state.withLockUnchecked { $0.recognizer.suspend() }
    }

    /// Ends a capture in progress if the trigger key is no longer held and its
    /// release was never delivered to the tap.
    public func verifyActiveGesture() {
        let triggerDown = isTriggerDown()
        let output = state.withLockUnchecked { state -> GestureOutput in
            guard !triggerDown else {
                state.triggerUpReadings = 0
                return .pass
            }
            // One reading can land in the instant between the key coming up
            // and its event arriving. Two in a row cannot.
            state.triggerUpReadings += 1
            guard state.triggerUpReadings >= 2 else { return .pass }
            state.triggerUpReadings = 0
            return state.recognizer.verifyActive(triggerDown: false)
        }
        if !output.actions.isEmpty { onActions(output.actions) }
    }

    /// Whether the trigger key is held. Modifier events are never swallowed
    /// by this tap, so the session's key state is accurate.
    private func isTriggerDown() -> Bool {
        CGEventSource.keyState(.combinedSessionState, key: triggerKeyCode)
    }

    /// Whether the left mouse button is physically held. This has to come
    /// from the hardware state: the session's own button state never sees a
    /// press that this tap swallowed, and reports the button as up.
    private func isMouseDown() -> Bool {
        CGEventSource.buttonState(.hidSystemState, button: .left)
    }

    // MARK: Callback

    fileprivate func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            recover(type: type)
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.replayMarker {
            return Unmanaged.passUnretained(event)
        }
        guard var input = inputEvent(type: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }
        let rawFlags = event.flags.rawValue
        let changedKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // Mouse events carry the modifier flags current when they were made.
        let carried: ModifierState? =
            type == .flagsChanged || type == .keyDown || type == .keyUp
            ? nil : ModifierState(rawFlags: rawFlags, triggerDeviceMask: triggerDeviceMask)
        let config = self.config

        // Decide under the lock, then post and notify outside it.
        let (output, replay) = state.withLockUnchecked { state -> (GestureOutput, [CGEvent]) in
            if type == .flagsChanged {
                // Needs the tracked state, so it is decoded here.
                input = .flagsChanged(
                    ModifierState.decode(
                        rawFlags: rawFlags, changedKeyCode: changedKeyCode,
                        previousTrigger: state.recognizer.triggerDown, config: config))
            }
            let output = state.recognizer.handle(input, carrying: carried)
            var replay: [CGEvent] = []
            switch output.held {
            case .keep: break
            case .replay:
                replay = state.held
                state.held.removeAll()
            case .drop:
                state.held.removeAll()
            }
            if output.disposition == .hold, state.held.count < Self.maxHeldEvents, let copy = event.copy() {
                copy.setIntegerValueField(.eventSourceUserData, value: Self.replayMarker)
                state.held.append(copy)
            }
            return (output, replay)
        }

        // Events posted here enter the stream ahead of the one being returned,
        // so a replayed mouse-down still arrives before its mouse-up.
        for heldEvent in replay {
            heldEvent.tapPostEvent(proxy)
        }
        if !output.actions.isEmpty {
            onActions(output.actions)
        }
        return output.disposition == .pass ? Unmanaged.passUnretained(event) : nil
    }

    private func inputEvent(type: CGEventType, event: CGEvent) -> InputEvent? {
        switch type {
        case .flagsChanged:
            return .flagsChanged(ModifierState(rawFlags: event.flags.rawValue, triggerDeviceMask: triggerDeviceMask))
        case .keyDown:
            return .keyDown(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        case .keyUp:
            return .keyUp(keyCode: event.getIntegerValueField(.keyboardEventKeycode))
        case .leftMouseDown:
            return .leftMouseDown(event.location)
        case .leftMouseDragged:
            return .leftMouseDragged(event.location)
        case .leftMouseUp:
            return .leftMouseUp(event.location)
        default:
            return nil
        }
    }

    /// The system disables a tap whose callback is slow, or on secure input.
    /// Turn it back on and reconcile the state machine with reality.
    private func recover(type: CGEventType) {
        Self.log.notice("event tap disabled (type \(type.rawValue, privacy: .public)); re-enabling")
        let triggerDown = isTriggerDown()
        let mouseDown = isMouseDown()

        let (port, output) = state.withLockUnchecked { state -> (CFMachPort?, GestureOutput) in
            let output = state.recognizer.resync(triggerDown: triggerDown, mouseDown: mouseDown)
            if output.held == .drop { state.held.removeAll() }
            return (state.port, output)
        }
        if let port { CGEvent.tapEnable(tap: port, enable: true) }
        if !output.actions.isEmpty { onActions(output.actions) }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.handle(proxy: proxy, type: type, event: event)
}

/// Carries a non-Sendable value across a concurrency boundary when the caller
/// guarantees exclusive access.
struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
