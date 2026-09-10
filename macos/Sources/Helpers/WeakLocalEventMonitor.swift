import AppKit

/// An expired observer must not consume application-wide input. Keep the
/// owner's intentional nil (handled event) distinct from a missing owner.
@MainActor
enum WeakLocalEventMonitor {
    static func handler<Owner: AnyObject>(
        for owner: Owner,
        receive: @escaping (Owner, NSEvent) -> NSEvent?
    ) -> (NSEvent) -> NSEvent? {
        { [weak owner] event in
            guard let owner else { return event }
            return receive(owner, event)
        }
    }
}
