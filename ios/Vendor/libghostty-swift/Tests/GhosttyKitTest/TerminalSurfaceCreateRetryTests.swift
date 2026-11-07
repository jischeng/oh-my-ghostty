@testable import GhosttyTerminal
import Foundation
import Testing

/// The debug-log sink is `@Sendable`, so attempts are counted behind a lock.
private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@MainActor
@Suite(.serialized)
struct TerminalSurfaceCreateRetryTests {
    /// Counts full surface-create attempts by watching the lifecycle log line
    /// emitted immediately before `createSurface` (a `TerminalController`
    /// without a ghostty app fails every create, standing in for the
    /// display-asleep `error.OutOfMemory` failure).
    private func withAttemptCounter(
        _ body: (TerminalSurfaceCoordinator, () -> Int) -> Void
    ) {
        let previousEnabled = TerminalDebugLog.isEnabled
        let previousCategories = TerminalDebugLog.categories
        let previousSink = TerminalDebugLog.sink
        defer {
            TerminalDebugLog.isEnabled = previousEnabled
            TerminalDebugLog.categories = previousCategories
            TerminalDebugLog.sink = previousSink
        }

        let attempts = AttemptCounter()
        TerminalDebugLog.enable(.lifecycle)
        TerminalDebugLog.sink = { message in
            if message.contains("surface rebuild scale=") { attempts.increment() }
        }

        let coordinator = TerminalSurfaceCoordinator()
        coordinator.isAttached = { true }
        coordinator.viewSize = { (800, 600) }
        body(coordinator, { attempts.count })
    }

    @Test
    func `fitToSize does not retry a failed surface create within the cooldown`() {
        withAttemptCounter { coordinator, attempts in
            coordinator.controller = TerminalController()
            #expect(coordinator.surface == nil)
            #expect(attempts() == 1)

            // The layout/settle-resync cadence funnels through fitToSize;
            // inside the cooldown it must not burn another full create.
            coordinator.fitToSize()
            coordinator.fitToSize()
            coordinator.fitToSize()
            #expect(attempts() == 1)
        }
    }

    @Test
    func `explicit rebuild bypasses the create cooldown`() {
        withAttemptCounter { coordinator, attempts in
            coordinator.controller = TerminalController()
            #expect(attempts() == 1)

            // A deliberate trigger (controller/configuration change, window
            // attach) still attempts immediately.
            coordinator.rebuildIfReady()
            #expect(attempts() == 2)
        }
    }

    @Test
    func `degenerate scale factors clamp to the retina default`() {
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.scaleFactor = { 0 }
        #expect(coordinator.sanitizedScaleFactor() == 2.0)

        coordinator.scaleFactor = { -1 }
        #expect(coordinator.sanitizedScaleFactor() == 2.0)

        coordinator.scaleFactor = { .nan }
        #expect(coordinator.sanitizedScaleFactor() == 2.0)

        coordinator.scaleFactor = { .infinity }
        #expect(coordinator.sanitizedScaleFactor() == 2.0)

        coordinator.scaleFactor = { 1.5 }
        #expect(coordinator.sanitizedScaleFactor() == 1.5)
    }
}
