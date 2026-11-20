import CoreGraphics
import Testing

@testable import RetainerKit

/// The gesture rules, exercised without a real event tap.
///
/// The tests feed the recognizer the same sequence of events the system would
/// deliver and assert, event by event, what happens to each one: passed
/// through, consumed, or held and later replayed.
@Suite("Gesture recognizer")
struct GestureRecognizerTests {

    // MARK: Fixtures

    static let display = DisplayInfo(id: 1, bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
    static let secondDisplay = DisplayInfo(id: 2, bounds: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

    static func lookup(_ point: CGPoint) -> DisplayInfo? {
        secondDisplay.bounds.contains(point) ? secondDisplay : display
    }

    func makeRecognizer(enabled: Bool = true) -> GestureRecognizer {
        var recognizer = GestureRecognizer(config: .standard, displayLookup: Self.lookup)
        recognizer.isEnabled = enabled
        return recognizer
    }

    static let optionDown = InputEvent.flagsChanged(ModifierState(trigger: true, others: false))
    static let allUp = InputEvent.flagsChanged(.none)

    /// A stand-in for the event tap: applies each verdict to a fake event
    /// stream so tests can assert on exactly what the app underneath receives.
    struct Harness {
        var recognizer: GestureRecognizer
        /// Events delivered to the system, in delivery order.
        var delivered: [InputEvent] = []
        var held: [InputEvent] = []
        var actions: [GestureAction] = []

        mutating func send(_ event: InputEvent) {
            let output = recognizer.handle(event)
            switch output.held {
            case .keep: break
            case .replay:
                delivered.append(contentsOf: held)
                held.removeAll()
            case .drop:
                held.removeAll()
            }
            switch output.disposition {
            case .pass: delivered.append(event)
            case .consume: break
            case .hold: held.append(event)
            }
            actions.append(contentsOf: output.actions)
        }

        mutating func send(_ events: [InputEvent]) {
            for event in events { send(event) }
        }
    }

    func harness(enabled: Bool = true) -> Harness {
        Harness(recognizer: makeRecognizer(enabled: enabled))
    }

    // MARK: Pass-through: Option-click

    @Test("An Option-click that never becomes a drag reaches the app unchanged")
    func optionClickPassesThrough() {
        var h = harness()
        let events: [InputEvent] = [
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 200, y: 200)),
            .leftMouseUp(CGPoint(x: 200, y: 200)),
            Self.allUp,
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
        #expect(h.held.isEmpty)
        #expect(h.recognizer.phase == .idle)
    }

    @Test("A click with jitter inside the drag threshold is still a click, with every event delivered in order")
    func jitteryOptionClickPassesThrough() {
        var h = harness()
        let events: [InputEvent] = [
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 200, y: 200)),
            .leftMouseDragged(CGPoint(x: 202, y: 201)),
            .leftMouseDragged(CGPoint(x: 203, y: 202)),  // 3.6 pt from the start
            .leftMouseUp(CGPoint(x: 203, y: 202)),
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("The mouse-down is held back, not delivered, until the click is known to be a click")
    func mouseDownIsDeferredWhilePending() {
        var h = harness()
        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 50, y: 50))])
        #expect(h.delivered == [Self.optionDown])
        #expect(h.held == [.leftMouseDown(CGPoint(x: 50, y: 50))])
        h.send(.leftMouseUp(CGPoint(x: 50, y: 50)))
        #expect(h.delivered == [Self.optionDown, .leftMouseDown(CGPoint(x: 50, y: 50)), .leftMouseUp(CGPoint(x: 50, y: 50))])
    }

    @Test("Several Option-clicks in one hold all pass through")
    func repeatedOptionClicks() {
        var h = harness()
        var expected: [InputEvent] = [Self.optionDown]
        h.send(Self.optionDown)
        for x in [100.0, 300.0, 500.0] {
            let pair: [InputEvent] = [.leftMouseDown(CGPoint(x: x, y: 80)), .leftMouseUp(CGPoint(x: x, y: 80))]
            h.send(pair)
            expected.append(contentsOf: pair)
        }
        #expect(h.delivered == expected)
        #expect(h.actions.isEmpty)
    }

    @Test("Releasing Option while the button is still down hands the press to the app")
    func optionReleasedBeforeThreshold() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 10, y: 10)),
            Self.allUp,
            .leftMouseDragged(CGPoint(x: 80, y: 80)),
            .leftMouseUp(CGPoint(x: 80, y: 80)),
        ])
        // The held mouse-down is replayed ahead of the Option release.
        #expect(
            h.delivered == [
                Self.optionDown,
                .leftMouseDown(CGPoint(x: 10, y: 10)),
                Self.allUp,
                .leftMouseDragged(CGPoint(x: 80, y: 80)),
                .leftMouseUp(CGPoint(x: 80, y: 80)),
            ])
        #expect(h.actions.isEmpty)
    }

    // MARK: Pass-through: Option with keys and other modifiers

    @Test("Option plus a key (a shortcut or a special character) passes and disarms the hold")
    func optionWithKeyPassesThrough() {
        var h = harness()
        let events: [InputEvent] = [
            Self.optionDown,
            .keyDown(keyCode: 14),  // Option-E, the acute accent dead key
            .keyUp(keyCode: 14),
            // A drag later in the same hold must not start a capture.
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
            Self.allUp,
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Typing a run of Option characters is untouched")
    func optionCharactersPassThrough() {
        var h = harness()
        var events: [InputEvent] = [Self.optionDown]
        for keyCode in [Int64(0), 1, 2, 3, 35] {
            events.append(.keyDown(keyCode: keyCode))
            events.append(.keyUp(keyCode: keyCode))
        }
        events.append(Self.allUp)
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Escape with Option held but no capture in progress passes through")
    func escapeWhileArmedPassesThrough() {
        var h = harness()
        let events: [InputEvent] = [Self.optionDown, .keyDown(keyCode: KeyCode.escape), .keyUp(keyCode: KeyCode.escape), Self.allUp]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Option with another modifier already down never arms", arguments: [true, false])
    func otherModifierBlocksArming(otherFirst: Bool) {
        var h = harness()
        let otherOnly = InputEvent.flagsChanged(ModifierState(trigger: false, others: true))
        let both = InputEvent.flagsChanged(ModifierState(trigger: true, others: true))
        var events: [InputEvent] = otherFirst ? [otherOnly, both] : [Self.optionDown, both]
        events += [
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 400, y: 400)),
            .leftMouseUp(CGPoint(x: 400, y: 400)),
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Adding a modifier after the press but before the drag threshold releases the press to the app")
    func modifierAddedWhilePressed() {
        var h = harness()
        let both = InputEvent.flagsChanged(ModifierState(trigger: true, others: true))
        let events: [InputEvent] = [
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            both,
            .leftMouseDragged(CGPoint(x: 400, y: 400)),
            .leftMouseUp(CGPoint(x: 400, y: 400)),
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Releasing the extra modifier does not re-arm a disqualified hold")
    func taintPersistsUntilTriggerReleased() {
        var h = harness()
        let both = InputEvent.flagsChanged(ModifierState(trigger: true, others: true))
        let events: [InputEvent] = [
            Self.optionDown, both, Self.optionDown,  // Shift pressed and released; Option still held
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 400, y: 400)),
            .leftMouseUp(CGPoint(x: 400, y: 400)),
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Right Option alone is never the trigger")
    func rightOptionIgnored() {
        var h = harness()
        // Right Option sets the generic Option flag but not the Left Option device bit.
        let rightOption = InputEvent.flagsChanged(ModifierState(rawFlags: 0x0008_0000 | 0x40, triggerDeviceMask: 0x20))
        let events: [InputEvent] = [
            rightOption,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 400, y: 400)),
            .leftMouseUp(CGPoint(x: 400, y: 400)),
            Self.allUp,
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
        #expect(h.recognizer.phase == .idle)
    }

    @Test("A drag with no modifier held is ignored entirely")
    func plainDragIgnored() {
        var h = harness()
        let events: [InputEvent] = [
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 400, y: 400)),
            .leftMouseUp(CGPoint(x: 400, y: 400)),
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions.isEmpty)
    }

    @Test("Holding Option without dragging does nothing")
    func holdWithoutDrag() {
        var h = harness()
        h.send([Self.optionDown, Self.allUp])
        #expect(h.actions.isEmpty)
        #expect(h.delivered.count == 2)
    }

    // MARK: Flag decoding

    @Test("Raw event flags decode to the right trigger and other-modifier state")
    func modifierDecoding() {
        let option: UInt64 = 0x0008_0000
        let left = ModifierState(rawFlags: option | 0x20, triggerDeviceMask: 0x20)
        #expect(left == ModifierState(trigger: true, others: false))

        // Right Option: not the trigger, counted as another modifier, but
        // still "some Option key" as far as the device-independent flag goes.
        let right = ModifierState(rawFlags: option | 0x40, triggerDeviceMask: 0x20)
        #expect(right == ModifierState(trigger: false, others: true, option: true))

        #expect(ModifierState(rawFlags: 0, triggerDeviceMask: 0x20) == ModifierState(trigger: false, others: false, option: false))

        let both = ModifierState(rawFlags: option | 0x20 | 0x40, triggerDeviceMask: 0x20)
        #expect(both == ModifierState(trigger: true, others: true))

        let withShift = ModifierState(rawFlags: option | 0x20 | 0x0002_0000 | 0x2, triggerDeviceMask: 0x20)
        #expect(withShift == ModifierState(trigger: true, others: true))

        let withCommand = ModifierState(rawFlags: option | 0x20 | 0x0010_0000 | 0x8, triggerDeviceMask: 0x20)
        #expect(withCommand.others)

        // Caps Lock is a state, not a held modifier, and must not block the gesture.
        let capsLock = ModifierState(rawFlags: option | 0x20 | 0x0001_0000, triggerDeviceMask: 0x20)
        #expect(capsLock == ModifierState(trigger: true, others: false))
    }

    @Test("Key code 58 identifies Left Option when the flags do not say which side")
    func decodeFallsBackToKeyCode() {
        let config = CaptureConfig.standard
        let genericOption: UInt64 = 0x0008_0000

        // Left Option (58) goes down, reported without sided bits.
        let leftDown = ModifierState.decode(
            rawFlags: genericOption, changedKeyCode: 58, previousTrigger: false, config: config)
        #expect(leftDown.trigger && !leftDown.others)

        // Right Option (61) goes down the same way: not the trigger.
        let rightDown = ModifierState.decode(
            rawFlags: genericOption, changedKeyCode: 61, previousTrigger: false, config: config)
        #expect(!rightDown.trigger && rightDown.others)

        // Left Option released while Right Option keeps the generic flag set.
        let leftUp = ModifierState.decode(
            rawFlags: genericOption, changedKeyCode: 58, previousTrigger: true, config: config)
        #expect(!leftUp.trigger)

        // Everything released.
        let allUp = ModifierState.decode(rawFlags: 0, changedKeyCode: 58, previousTrigger: true, config: config)
        #expect(allUp == ModifierState(trigger: false, others: false, option: false))

        // When the sided bits are present they are authoritative, whatever the key code.
        let sided = ModifierState.decode(
            rawFlags: genericOption | 0x40, changedKeyCode: 58, previousTrigger: false, config: config)
        #expect(!sided.trigger && sided.others)
    }

    // MARK: Selection

    @Test("Dragging past the threshold starts a selection and consumes the mouse")
    func dragStartsSelection() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 103, y: 100)),  // still within 4 pt
            .leftMouseDragged(CGPoint(x: 160, y: 140)),
            .leftMouseDragged(CGPoint(x: 300, y: 260)),
        ])
        // Only the modifier event reached the system; the app saw no mouse activity.
        #expect(h.delivered == [Self.optionDown])
        #expect(h.held.isEmpty)
        #expect(
            h.actions == [
                .selectionBegan(rect: CGRect(x: 100, y: 100, width: 60, height: 40), display: Self.display),
                .selectionChanged(rect: CGRect(x: 100, y: 100, width: 200, height: 160)),
            ])
    }

    @Test("Exactly the threshold distance is not yet a drag")
    func thresholdIsExclusive() {
        var h = harness()
        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 100, y: 100)), .leftMouseDragged(CGPoint(x: 104, y: 100))])
        #expect(h.actions.isEmpty)
        h.send(.leftMouseDragged(CGPoint(x: 104.5, y: 100)))
        #expect(h.actions.count == 1)
    }

    @Test("Releasing the mouse on a valid selection ends it and keeps listening for the hold")
    func mouseUpEndsSelection() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 400, y: 300)),
            .leftMouseUp(CGPoint(x: 420, y: 320)),
        ])
        #expect(h.actions.last == .selectionEnded(rect: CGRect(x: 100, y: 100, width: 320, height: 220)))
        #expect(h.recognizer.phase == .speaking)
        #expect(h.delivered == [Self.optionDown])

        h.send(Self.allUp)
        #expect(h.actions.last == .holdEnded)
        #expect(h.recognizer.phase == .suspended)
    }

    @Test("A selection can be dragged in any direction")
    func selectionNormalised() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 500, y: 400)),
            .leftMouseDragged(CGPoint(x: 200, y: 100)),
            .leftMouseUp(CGPoint(x: 200, y: 100)),
        ])
        #expect(h.actions.last == .selectionEnded(rect: CGRect(x: 200, y: 100, width: 300, height: 300)))
    }

    @Test("Selections under the minimum size are ignored")
    func tooSmallSelection() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 119, y: 160)),
            .leftMouseUp(CGPoint(x: 119, y: 160)),  // 19 pt wide
        ])
        #expect(h.actions.last == .selectionCancelled(.tooSmall))
        // Option is still held, so another attempt is allowed straight away.
        #expect(h.recognizer.phase == .armed)

        h.send([
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 200, y: 200)),
            .leftMouseUp(CGPoint(x: 200, y: 200)),
        ])
        #expect(h.actions.last == .selectionEnded(rect: CGRect(x: 100, y: 100, width: 100, height: 100)))
    }

    @Test("A selection stays on the display where the drag started")
    func selectionClampedToStartDisplay() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 1300, y: 100)),
            .leftMouseDragged(CGPoint(x: 1700, y: 400)),  // pointer has crossed onto the second display
            .leftMouseUp(CGPoint(x: 1700, y: 400)),
        ])
        #expect(
            h.actions.first
                == .selectionBegan(rect: CGRect(x: 1300, y: 100, width: 140, height: 300), display: Self.display))
        #expect(h.actions.last == .selectionEnded(rect: CGRect(x: 1300, y: 100, width: 140, height: 300)))
    }

    @Test("A drag that starts on a secondary display reports that display")
    func selectionOnSecondaryDisplay() {
        var h = harness()
        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 1500, y: 100)), .leftMouseDragged(CGPoint(x: 1800, y: 500))])
        #expect(
            h.actions
                == [.selectionBegan(rect: CGRect(x: 1500, y: 100, width: 300, height: 400), display: Self.secondDisplay)])
    }

    @Test("Fractional pointer positions snap to whole points")
    func selectionSnapsToPoints() {
        let rect = GestureRecognizer.selectionRect(
            from: CGPoint(x: 10.4, y: 20.6), to: CGPoint(x: 110.5, y: 80.2), in: Self.display.bounds)
        #expect(rect == CGRect(x: 10, y: 21, width: 101, height: 59))
    }

    // MARK: Cancelling

    @Test("Releasing Option before the mouse cancels, and the rest of the drag is swallowed")
    func optionReleasedMidDrag() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            Self.allUp,
            .leftMouseDragged(CGPoint(x: 320, y: 320)),
            .leftMouseUp(CGPoint(x: 320, y: 320)),
        ])
        #expect(h.actions.last == .selectionCancelled(.triggerReleased))
        // The app never saw the mouse-down, so it must not see the tail of the drag either.
        #expect(h.delivered == [Self.optionDown, Self.allUp])
        #expect(h.recognizer.phase == .idle)
    }

    @Test("Escape during a drag cancels and is not delivered to the app")
    func escapeMidDrag() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .keyDown(keyCode: KeyCode.escape),
            .keyUp(keyCode: KeyCode.escape),
            .leftMouseDragged(CGPoint(x: 320, y: 320)),
            .leftMouseUp(CGPoint(x: 320, y: 320)),
        ])
        #expect(h.actions.last == .selectionCancelled(.escape))
        #expect(h.delivered == [Self.optionDown])
        // Option is still down: a new capture needs a fresh press.
        #expect(h.recognizer.phase == .tainted)
    }

    @Test("Escape while speaking discards the capture")
    func escapeWhileSpeaking() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
            .keyDown(keyCode: KeyCode.escape),
            .keyUp(keyCode: KeyCode.escape),
            Self.allUp,
        ])
        #expect(h.actions.last == .escapePressed)
        #expect(!h.actions.contains(.holdEnded))
        #expect(h.delivered == [Self.optionDown, Self.allUp])
        #expect(h.recognizer.phase == .idle)
    }

    @Test("Other keys pressed while speaking pass through and do not end the recording")
    func keysWhileSpeakingPass() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
            .keyDown(keyCode: 0),
            .keyUp(keyCode: 0),
        ])
        #expect(h.recognizer.phase == .speaking)
        #expect(h.delivered.suffix(2) == [.keyDown(keyCode: 0), .keyUp(keyCode: 0)])
    }

    // MARK: While a card is open

    @Test("A new Option-drag while a capture card is open is ignored and passes through")
    func dragWhileCardOpen() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
            Self.allUp,
        ])
        #expect(h.recognizer.phase == .suspended)
        let before = h.actions

        let second: [InputEvent] = [
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 500, y: 500)),
            .leftMouseDragged(CGPoint(x: 700, y: 700)),
            .leftMouseUp(CGPoint(x: 700, y: 700)),
            Self.allUp,
        ]
        let deliveredBefore = h.delivered.count
        h.send(second)
        #expect(h.actions == before)
        #expect(Array(h.delivered.dropFirst(deliveredBefore)) == second)
    }

    @Test("After the card closes, capturing resumes")
    func resumesAfterSessionEnds() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
            Self.allUp,
        ])
        h.recognizer.sessionEnded()
        #expect(h.recognizer.phase == .idle)

        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 100, y: 100)), .leftMouseDragged(CGPoint(x: 300, y: 300))])
        if case .selectionBegan = h.actions.last {
        } else {
            Issue.record("expected a new selection to begin")
        }
    }

    @Test("If the card closes while Option is still held, that hold cannot start another capture")
    func sessionEndedWhileTriggerHeld() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
        ])
        h.recognizer.suspend()  // the editor opened with Option still down
        #expect(h.recognizer.phase == .suspended)
        h.recognizer.sessionEnded()
        #expect(h.recognizer.phase == .tainted)
    }

    // MARK: Disabled

    @Test("With capture switched off, an Option-drag passes through and is only reported")
    func disabledPassesEverything() {
        var h = harness(enabled: false)
        let events: [InputEvent] = [
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseDragged(CGPoint(x: 400, y: 400)),
            .leftMouseUp(CGPoint(x: 400, y: 400)),
            Self.allUp,
        ]
        h.send(events)
        #expect(h.delivered == events)
        #expect(h.actions == [.attemptedWhileDisabled])
    }

    // MARK: Lost modifier events

    /// The flags a mouse event carries when no modifier is down.
    static let noModifiers = ModifierState.none
    static let optionOnly = ModifierState(trigger: true, others: false)

    @Test("If the Option release was never seen, an ordinary drag is still not hijacked")
    func missedReleaseDoesNotHijackPlainDrag() {
        var recognizer = makeRecognizer()
        _ = recognizer.handle(Self.optionDown)
        #expect(recognizer.phase == .armed)

        // Option was released, but that event never reached the tap (secure
        // input, for example). The mouse events themselves say no Option.
        let down = recognizer.handle(.leftMouseDown(CGPoint(x: 100, y: 100)), carrying: Self.noModifiers)
        #expect(down == .pass)
        #expect(recognizer.phase == .idle)
        #expect(!recognizer.triggerDown)

        let drag = recognizer.handle(.leftMouseDragged(CGPoint(x: 400, y: 400)), carrying: Self.noModifiers)
        let up = recognizer.handle(.leftMouseUp(CGPoint(x: 400, y: 400)), carrying: Self.noModifiers)
        #expect(drag == .pass)
        #expect(up == .pass)
    }

    @Test("If the release is missed while a press is pending, the held click is handed back")
    func missedReleaseWhilePressed() {
        var recognizer = makeRecognizer()
        _ = recognizer.handle(Self.optionDown)
        let down = recognizer.handle(.leftMouseDown(CGPoint(x: 100, y: 100)), carrying: Self.optionOnly)
        #expect(down.disposition == .hold)

        let drag = recognizer.handle(.leftMouseDragged(CGPoint(x: 300, y: 300)), carrying: Self.noModifiers)
        #expect(drag == GestureOutput(.pass, held: .replay))
        #expect(recognizer.phase == .idle)
    }

    @Test("If the release is missed mid-drag, the next mouse event cancels the selection")
    func missedReleaseMidDrag() {
        var recognizer = makeRecognizer()
        _ = recognizer.handle(Self.optionDown)
        _ = recognizer.handle(.leftMouseDown(CGPoint(x: 100, y: 100)), carrying: Self.optionOnly)
        _ = recognizer.handle(.leftMouseDragged(CGPoint(x: 300, y: 300)), carrying: Self.optionOnly)

        let drag = recognizer.handle(.leftMouseDragged(CGPoint(x: 320, y: 320)), carrying: Self.noModifiers)
        #expect(drag == GestureOutput(.consume, actions: [.selectionCancelled(.triggerReleased)]))
        // The app never saw the button go down, so the rest stays swallowed.
        let up = recognizer.handle(.leftMouseUp(CGPoint(x: 320, y: 320)), carrying: Self.noModifiers)
        #expect(up == GestureOutput(.consume))
        #expect(recognizer.phase == .idle)
    }

    @Test("A modifier added unseen disqualifies the hold at mouse-down")
    func missedExtraModifier() {
        var recognizer = makeRecognizer()
        _ = recognizer.handle(Self.optionDown)
        let withShift = ModifierState(trigger: true, others: true)
        let down = recognizer.handle(.leftMouseDown(CGPoint(x: 100, y: 100)), carrying: withShift)
        #expect(down == .pass)
        #expect(recognizer.phase == .tainted)
    }

    @Test("Mouse flags that agree with the tracked state change nothing")
    func agreeingFlagsAreNeutral() {
        var plain = harness()
        var carrying = makeRecognizer()
        let events: [InputEvent] = [
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 260)),
            .leftMouseUp(CGPoint(x: 300, y: 260)),
        ]
        plain.send(Self.optionDown)
        _ = carrying.handle(Self.optionDown)
        for event in events {
            let expected = plain.recognizer.handle(event)
            #expect(carrying.handle(event, carrying: Self.optionOnly) == expected)
        }
        #expect(carrying.phase == .speaking)
    }

    @Test("Option reported without a side is trusted once a gesture is under way")
    func unsidedOptionFlag() {
        var recognizer = makeRecognizer()
        _ = recognizer.handle(Self.optionDown)
        _ = recognizer.handle(.leftMouseDown(CGPoint(x: 100, y: 100)), carrying: Self.optionOnly)
        // Some event sources set only the device-independent Option flag.
        let unsided = ModifierState(rawFlags: 0x0008_0000, triggerDeviceMask: 0x20)
        #expect(unsided.option && !unsided.trigger && !unsided.others)
        let drag = recognizer.handle(.leftMouseDragged(CGPoint(x: 300, y: 300)), carrying: unsided)
        #expect(drag.actions.count == 1)
        if case .selecting = recognizer.phase {
        } else {
            Issue.record("the selection should have started")
        }
    }

    // MARK: Watchdog

    @Test("The watchdog ends a recording whose Option release was lost")
    func watchdogEndsHold() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
        ])
        #expect(h.recognizer.verifyActive(triggerDown: true) == .pass)
        #expect(h.recognizer.phase == .speaking)

        let output = h.recognizer.verifyActive(triggerDown: false)
        #expect(output.actions == [.holdEnded])
        #expect(h.recognizer.phase == .suspended)

        // The real release arriving late does not end it twice.
        h.send(Self.allUp)
        #expect(!h.actions.contains(.holdEnded))
    }

    @Test("A drag in progress survives the watchdog for as long as Option is held")
    func watchdogNeverInterruptsALongDrag() {
        var h = harness()
        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 100, y: 100)), .leftMouseDragged(CGPoint(x: 300, y: 300))])

        // A slow drag: many watchdog ticks pass with Option held. Whatever the
        // system reports about the mouse button is not consulted.
        for step in 0..<40 {
            #expect(h.recognizer.verifyActive(triggerDown: true) == .pass)
            h.send(.leftMouseDragged(CGPoint(x: 300 + Double(step), y: 300)))
        }
        if case .selecting = h.recognizer.phase {
        } else {
            Issue.record("the selection should still be in progress")
        }
        #expect(!h.actions.contains { if case .selectionCancelled = $0 { true } else { false } })

        h.send(.leftMouseUp(CGPoint(x: 400, y: 320)))
        #expect(h.actions.last == .selectionEnded(rect: CGRect(x: 100, y: 100, width: 300, height: 220)))
    }

    @Test("The watchdog cancels a selection whose Option release was lost")
    func watchdogCancelsSelection() {
        var h = harness()
        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 100, y: 100)), .leftMouseDragged(CGPoint(x: 300, y: 300))])

        let output = h.recognizer.verifyActive(triggerDown: false)
        #expect(output.actions == [.selectionCancelled(.triggerReleased)])
        // The button is still down: the rest of the drag stays swallowed.
        #expect(h.recognizer.phase == .swallowing)
        h.send([.leftMouseDragged(CGPoint(x: 320, y: 320)), .leftMouseUp(CGPoint(x: 320, y: 320))])
        #expect(h.delivered == [Self.optionDown])
        #expect(h.recognizer.phase == .idle)
    }

    @Test("The watchdog leaves everything else alone")
    func watchdogIsInertOutsideAGesture() {
        var recognizer = makeRecognizer()
        #expect(recognizer.verifyActive(triggerDown: false) == .pass)
        #expect(recognizer.phase == .idle)

        _ = recognizer.handle(Self.optionDown)
        // Even a contradictory reading must not disturb an armed hold: only
        // real events arm and disarm.
        #expect(recognizer.verifyActive(triggerDown: false) == .pass)
        #expect(recognizer.phase == .armed)

        // A press that has not become a drag yet is not the watchdog's business either.
        _ = recognizer.handle(.leftMouseDown(CGPoint(x: 10, y: 10)))
        #expect(recognizer.verifyActive(triggerDown: false) == .pass)
        if case .pressed = recognizer.phase {
        } else {
            Issue.record("the press should still be pending")
        }
    }

    // MARK: Recovery

    @Test("If the tap missed the Option release, resync ends the recording")
    func resyncEndsHold() {
        var h = harness()
        h.send([
            Self.optionDown,
            .leftMouseDown(CGPoint(x: 100, y: 100)),
            .leftMouseDragged(CGPoint(x: 300, y: 300)),
            .leftMouseUp(CGPoint(x: 300, y: 300)),
        ])
        let output = h.recognizer.resync(triggerDown: false, mouseDown: false)
        #expect(output.actions == [.holdEnded])
        #expect(h.recognizer.phase == .suspended)
    }

    @Test("If the tap missed the mouse release mid-drag, resync cancels the selection")
    func resyncCancelsSelection() {
        var h = harness()
        h.send([Self.optionDown, .leftMouseDown(CGPoint(x: 100, y: 100)), .leftMouseDragged(CGPoint(x: 300, y: 300))])
        let output = h.recognizer.resync(triggerDown: true, mouseDown: false)
        #expect(output.actions == [.selectionCancelled(.interrupted)])
        #expect(h.recognizer.phase == .tainted)
    }
}
