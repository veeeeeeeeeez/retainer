import AppKit
import Foundation
import Testing

@testable import RetainerKit

/// Callbacks the system delivers on threads other than the main one.
///
/// Swift 6 stops the process when a closure tied to the main actor runs off
/// the main thread, and the compiler cannot see that some Objective-C APIs
/// call back on a background queue. Each handler the app gives such an API is
/// invoked here the way the system invokes it. A regression does not fail an
/// expectation; it brings the whole test run down with a trap.
@Suite("Callbacks on other threads")
@MainActor
struct BackgroundCallbackTests {

    private func onBackgroundQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .utility).async {
                precondition(!Thread.isMainThread)
                continuation.resume(returning: work())
            }
        }
    }

    @Test("The answer to a permission prompt can arrive on a background queue")
    func permissionPromptAnswer() async {
        let permissions = PermissionsModel()
        // The two shapes the system uses: a Bool for the microphone, an
        // enumeration for speech recognition.
        let microphone: @Sendable (Bool) -> Void = permissions.promptAnswered()
        let speech: @Sendable (Int) -> Void = permissions.promptAnswered()

        let delivered = await onBackgroundQueue {
            microphone(true)
            speech(3)
            return true
        }
        #expect(delivered)

        // The handler's only job is to refresh on the main actor; let that run.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(Permission.allCases.allSatisfy { permissions.statuses[$0] != nil })
    }

    @Test("The menu bar icon can be drawn on any thread")
    func statusItemIconDrawsOffMain() async {
        let icon = UncheckedBox(StatusItemController.icon)
        let size = await onBackgroundQueue {
            // Asking for a bitmap runs the image's drawing handler right here.
            let image = icon.value.cgImage(forProposedRect: nil, context: nil, hints: nil)
            return image.map { CGSize(width: $0.width, height: $0.height) }
        }
        #expect(size != nil)
        #expect((size?.width ?? 0) >= 18)
    }
}
