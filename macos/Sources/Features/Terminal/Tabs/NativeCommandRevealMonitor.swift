import AppKit

/// Shared single-slot trailing priority across both `.tabs` (`NativeTabCell`) and `.inbox` (`NativeInboxRowView`).
enum NativeTabTrailingAccessory: Equatable, Sendable {
    static let renamingSpinnerSize: CGFloat = 12

    case none
    case status
    case renaming
    case shortcut
    case close

    static func resolve(
        isHovered: Bool,
        isCloseHovered: Bool = false,
        canClose: Bool,
        isCommandHeld: Bool,
        hasShortcut: Bool,
        isRenaming: Bool = false,
        isManualRenaming: Bool = false,
        hasStatus: Bool
    ) -> Self {
        if isHovered && canClose && (!isManualRenaming || isCloseHovered) {
            return .close
        }
        if isCommandHeld && hasShortcut {
            return .shortcut
        }
        if isRenaming || isManualRenaming {
            return .renaming
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

    /// Injectable environment hooks for deterministic unit testing.
    var currentModifiersProvider: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }
    var isAppActiveProvider: () -> Bool = { NSApp.isActive }
    var keyWindowProvider: () -> NSWindow? = { NSApp.keyWindow }

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
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: nil
        ) { [weak self] note in
            let becomingWindow = note.object as? NSWindow
            let handle: () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleWindowDidBecomeKey(becomingWindow)
                }
            }
            if Thread.isMainThread {
                handle()
            } else {
                DispatchQueue.main.async(execute: handle)
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Defer to the next main runloop tick so native tab switches (where
            // the old tab's window resigns key right before the new tab's window
            // becomes key) preserve an already-held ⌘ without a new .flagsChanged.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleWindowDidResignKeyDeferred()
                }
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            let handle: () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.setLiveCommandHeld(false)
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
            let handle: () -> Void = { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.publishIfNeeded()
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

    /// Synchronizes live `⌘` reveal state from current modifier flags when the
    /// sidebar activates, refreshes, or moves into a newly focused tab window.
    func syncFromCurrentModifiers() {
        guard isAppActiveProvider() else {
            setLiveCommandHeld(false)
            return
        }
        if let hostView {
            guard let window = hostView.window, window.isVisible, window.isKeyWindow else {
                setLiveCommandHeld(false)
                return
            }
        } else if keyWindowProvider() == nil {
            setLiveCommandHeld(false)
            return
        }
        setLiveCommandHeld(Self.shouldRevealShortcuts(for: currentModifiersProvider()))
    }

    func reconcileWindowFocus() {
        syncFromCurrentModifiers()
    }

    private func handleWindowDidBecomeKey(_ becomingWindow: NSWindow?) {
        guard isAppActiveProvider() else {
            setLiveCommandHeld(false)
            return
        }
        if let window = hostView?.window {
            if window === becomingWindow || window.isKeyWindow {
                setLiveCommandHeld(Self.shouldRevealShortcuts(for: currentModifiersProvider()))
            } else {
                setLiveCommandHeld(false)
            }
        } else if becomingWindow != nil || keyWindowProvider() != nil {
            setLiveCommandHeld(Self.shouldRevealShortcuts(for: currentModifiersProvider()))
        } else {
            setLiveCommandHeld(false)
        }
    }

    private func handleWindowDidResignKeyDeferred() {
        guard isAppActiveProvider(), let activeKeyWindow = keyWindowProvider() else {
            setLiveCommandHeld(false)
            return
        }
        if let window = hostView?.window, window !== activeKeyWindow, !window.isKeyWindow {
            setLiveCommandHeld(false)
            return
        }
        setLiveCommandHeld(Self.shouldRevealShortcuts(for: currentModifiersProvider()))
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
