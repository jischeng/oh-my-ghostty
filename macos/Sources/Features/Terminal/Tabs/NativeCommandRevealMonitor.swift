import AppKit

/// Shared single-slot trailing priority across both `.tabs` (`NativeTabCell`) and `.inbox` (`NativeInboxRowView`).
enum NativeTabTrailingAccessory: Equatable, Sendable {
    case none
    case status
    case shortcut
    case close

    static func resolve(
        isHovered: Bool,
        canClose: Bool,
        isCommandHeld: Bool,
        hasShortcut: Bool,
        hasStatus: Bool
    ) -> Self {
        if isHovered && canClose {
            return .close
        }
        if isCommandHeld && hasShortcut {
            return .shortcut
        }
        if hasStatus {
            return .status
        }
        return .none
    }
}

/// Lightweight AppKit `.flagsChanged` monitor revealing `⌘1..9` shortcuts while `⌘` is held
/// in the key terminal window, with focus-loss cleanup so Command-Tab never leaves shortcuts stuck on.
@MainActor
final class NativeCommandRevealMonitor {
    private static let overrideDidChangeNotification = Notification.Name("OMGCommandRevealOverrideDidChange")
    private static var globalOverride: Bool?

    /// Process-wide test seam overriding live `⌘` modifier state across sidebar views.
    static func setCommandHeldForTesting(_ isHeld: Bool?) {
        guard globalOverride != isHeld else { return }
        globalOverride = isHeld
        NotificationCenter.default.post(name: overrideDidChangeNotification, object: nil)
    }

    static var commandHeldForTesting: Bool? { globalOverride }

    /// `true` when `.command` is pressed without `.control` or `.option` (Shift is allowed).
    static func shouldRevealShortcuts(for flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .control, .option]) == .command
    }

    weak var hostView: NSView? {
        didSet {
            guard hostView !== oldValue else { return }
            reconcileWindowFocus()
        }
    }

    /// Per-instance test seam overriding live `⌘` modifier state.
    var overrideValue: Bool? {
        didSet {
            guard oldValue != overrideValue else { return }
            publishIfNeeded()
        }
    }

    var onChange: ((Bool) -> Void)?

    private var liveCommandHeld = false
    private(set) var isCommandHeld = false
    private var localMonitor: Any?
    private var observers: [NSObjectProtocol] = []

    init() {
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: .flagsChanged,
            handler: WeakLocalEventMonitor.handler(for: self) { monitor, event in
                monitor.handleFlagsChanged(event)
                return event
            }
        )
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let handle = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let window = self.hostView?.window {
                        if (note.object as? NSWindow) === window || !window.isKeyWindow {
                            self.setLiveCommandHeld(false)
                        }
                    } else {
                        self.setLiveCommandHeld(false)
                    }
                }
            }
            if Thread.isMainThread {
                handle()
            } else {
                DispatchQueue.main.async(execute: handle)
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let handle = { [weak self] in
                MainActor.assumeIsolated {
                    self?.setLiveCommandHeld(false)
                }
            }
            if Thread.isMainThread {
                handle()
            } else {
                DispatchQueue.main.async(execute: handle)
            }
        })
        observers.append(center.addObserver(
            forName: Self.overrideDidChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let handle = { [weak self] in
                MainActor.assumeIsolated {
                    self?.publishIfNeeded()
                }
            }
            if Thread.isMainThread {
                handle()
            } else {
                DispatchQueue.main.async(execute: handle)
            }
        })
    }

    deinit {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func handleFlagsChanged(_ event: NSEvent) {
        guard let hostView,
              let window = hostView.window,
              window.isVisible,
              window.isKeyWindow,
              event.window == nil || event.window === window else {
            setLiveCommandHeld(false)
            return
        }
        setLiveCommandHeld(Self.shouldRevealShortcuts(for: event.modifierFlags))
    }

    func resetLiveState() {
        setLiveCommandHeld(false)
    }

    func reconcileWindowFocus() {
        guard let hostView,
              let window = hostView.window,
              window.isVisible,
              window.isKeyWindow else {
            setLiveCommandHeld(false)
            return
        }
    }

    private func setLiveCommandHeld(_ next: Bool) {
        guard liveCommandHeld != next else { return }
        liveCommandHeld = next
        publishIfNeeded()
    }

    private func publishIfNeeded() {
        let effective = overrideValue ?? Self.globalOverride ?? liveCommandHeld
        guard isCommandHeld != effective else { return }
        isCommandHeld = effective
        onChange?(effective)
    }
}
