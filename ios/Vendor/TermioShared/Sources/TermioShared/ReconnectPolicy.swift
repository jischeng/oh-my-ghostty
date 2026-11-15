import Foundation

/// The reconnect cadence every self-healing link in termio shares: the phone's
/// two companion links (roster + terminal) and the Mac's own attach channel to
/// a session in termiod.
///
/// Outages that look identical to a dead socket want opposite handling: an app
/// rebuild, a daemon restart or a Wi-Fi blip clears in seconds (retry fast,
/// notice the instant it's back), while a **closed laptop or a box that went
/// away** can be gone for hours (stop hammering the radio). So the cadence is
/// tiered — a fast burst for the first ~30s, then a slow 30s steady-state
/// heartbeat — rather than a retry-every-6s-forever loop.
///
/// It never gives up: a link self-heals instead of dead-ending in a
/// "disconnected" state that needs a manual tap. The event-driven wakeups
/// (app foreground, network path returning) are the *real* reconnect triggers
/// — they call `reset()` to drop back to the fast burst — and this backoff is
/// just the fallback for the case events miss (lid reopened on the same Wi-Fi
/// while the app is already foreground).
public struct ReconnectPolicy {
    /// Minimum healthy connection uptime (in seconds) required before a subsequent
    /// drop resets the backoff attempt counter. Prevents ~2 Hz reconnect/resync loops
    /// when HTTP 101 upgrades succeed (or a snapshot arrives) right before a stream error.
    public static let defaultMinimumHealthyUptime: TimeInterval = 5

    /// Failed attempts since the last `reset()`. Exposed for logging/tests.
    public private(set) var attempts = 0
    private var upgradedAt: TimeInterval?
    private var protocolReadyAt: TimeInterval?
    private var requiresProtocolReady = false

    public init() {}

    /// Initializes per-connection state before dialing a new WebSocket task so
    /// asynchronous open/read callbacks on the new task cannot clobber each other.
    public mutating func beginConnectAttempt(requiresProtocolReady: Bool = false) {
        upgradedAt = nil
        protocolReadyAt = nil
        self.requiresProtocolReady = requiresProtocolReady
    }

    /// Records an HTTP 101 WebSocket upgrade without resetting `attempts`, while
    /// preserving any `protocolReadyAt` or stricter `requiresProtocolReady` flag
    /// already recorded if protocol frames or `onOpen` raced ahead of upgrade bookkeeping.
    public mutating func noteSocketOpened(
        at uptime: TimeInterval,
        requiresProtocolReady: Bool = false
    ) {
        upgradedAt = uptime
        self.requiresProtocolReady = self.requiresProtocolReady || requiresProtocolReady
    }

    /// Records that the application protocol on the current socket reached a valid
    /// baseline state (e.g. session snapshot `'S'` applied, or `'L'` catalogue decoded
    /// when not attached to a session).
    public mutating func noteProtocolReady(at uptime: TimeInterval) {
        protocolReadyAt = uptime
    }

    /// Requires a fresh `noteProtocolReady(at:)` call before the current connection
    /// can qualify as healthy (e.g. when opening a session stream on an already-open link).
    public mutating func requireFreshProtocolReady() {
        protocolReadyAt = nil
        requiresProtocolReady = true
    }

    /// True only when the current connection reached readiness and stayed up without
    /// dropping or resynchronizing for at least `minimumHealthyUptime`.
    public func hasSustainedHealthyConnection(
        at uptime: TimeInterval,
        minimumHealthyUptime: TimeInterval = Self.defaultMinimumHealthyUptime
    ) -> Bool {
        let anchor = requiresProtocolReady ? protocolReadyAt : (protocolReadyAt ?? upgradedAt)
        guard let anchor else { return false }
        return uptime - anchor >= max(0, minimumHealthyUptime)
    }

    /// Computes the next backoff delay when a socket drops or resynchronizes.
    /// Resets `attempts` first ONLY if the dropped connection had sustained healthy
    /// operation; otherwise advances exponential backoff (`0.5 -> 1 -> 2 -> 4 -> 5 -> 30s`).
    public mutating func nextDelayAfterDrop(
        at uptime: TimeInterval,
        minimumHealthyUptime: TimeInterval = Self.defaultMinimumHealthyUptime,
        ceiling: Double = 30,
        jitter: ClosedRange<Double> = 0.8...1.2
    ) -> Double {
        if hasSustainedHealthyConnection(at: uptime, minimumHealthyUptime: minimumHealthyUptime) {
            attempts = 0
        }
        upgradedAt = nil
        protocolReadyAt = nil
        return nextDelay(ceiling: ceiling, jitter: jitter)
    }

    /// The next backoff delay in seconds, with ±20% jitter, advancing the
    /// attempt counter. `0.5 → 1 → 2 → 4 → 5` for the first six tries (~17s of
    /// failure), then a flat 30s heartbeat once the Mac is probably asleep, not
    /// rebuilding.
    public mutating func nextDelay(ceiling: Double = 30, jitter: ClosedRange<Double> = 0.8...1.2) -> Double {
        attempts += 1
        let base = attempts <= 6
            ? min(0.5 * pow(2.0, Double(attempts - 1)), 5)
            : ceiling
        return base * .random(in: jitter)
    }

    /// Back to the fast burst — called when an event says the Mac is likely
    /// reachable again (foreground, network path up, a manual "Try Again").
    public mutating func reset() {
        attempts = 0
        upgradedAt = nil
        protocolReadyAt = nil
    }
}
