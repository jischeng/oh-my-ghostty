import Foundation
import Cocoa
import SwiftUI

class AboutController: NSWindowController, NSWindowDelegate {
    static let shared: AboutController = AboutController()

    private let viewModel = AboutViewModel()
    private var appearanceObservations: [NSObjectProtocol] = []
    private var spaceObservation: NSObjectProtocol?
    override var windowNibName: NSNib.Name? { "About" }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.delegate = self
        window.center()
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: AboutView().environmentObject(viewModel))
        window.titlebarAppearsTransparent = true
        installAppearanceObservers(for: window)
        syncWindowAppearance()
    }

    deinit {
        appearanceObservations.forEach(NotificationCenter.default.removeObserver)
        if let spaceObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObservation)
        }
    }

    // MARK: - Functions

    func show() {
        window?.makeKeyAndOrderFront(nil)
        if let window {
            MissionControlPresentationMonitor.shared.updateWindowEligibility(
                window,
                wantsBehindWindowBlur: !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
                owner: "about"
            )
        }
        syncWindowAppearance()
        viewModel.startCyclingIcons()
    }

    func hide() {
        window?.close()
    }

    private func installAppearanceObservers(for window: NSWindow) {
        appearanceObservations.forEach(NotificationCenter.default.removeObserver)
        appearanceObservations.removeAll()
        if let spaceObservation {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObservation)
            self.spaceObservation = nil
        }
        appearanceObservations.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                MissionControlPresentationMonitor.shared.refreshBeforeWindowAppearanceSync(for: self?.window)
                self?.syncWindowAppearance()
            }
        })
        for name in [
            MissionControlPresentationMonitor.didChangeNotification,
            MissionControlPresentationMonitor.windowSpaceOrStateDidSettleNotification,
        ] {
            appearanceObservations.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncWindowAppearance() }
            })
        }
        spaceObservation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                MissionControlPresentationMonitor.shared.refreshBeforeWindowAppearanceSync(for: self?.window)
                self?.syncWindowAppearance()
            }
        }
    }

    private func syncWindowAppearance() {
        guard let window else { return }
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        if window.isVisible {
            MissionControlPresentationMonitor.shared.updateWindowEligibility(
                window,
                wantsBehindWindowBlur: !reduceTransparency,
                owner: "about"
            )
        }
        let forceOpaque = reduceTransparency ||
            MissionControlPresentationMonitor.shared.shouldSuppressBehindWindowBlur(for: window)
        window.isOpaque = forceOpaque
        window.setAutoFlattenLayerTreeEnabled(forceOpaque)
        window.backgroundColor = forceOpaque
            ? .windowBackgroundColor
            : NSColor.windowBackgroundColor.withAlphaComponent(0.001)
        viewModel.suppressBlur = forceOpaque
    }

    // MARK: - First Responder

    @IBAction func close(_ sender: Any) {
        self.window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        self.window?.performClose(sender)
    }

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if let window {
            MissionControlPresentationMonitor.shared.unregisterWindow(window, owner: "about")
        }
        viewModel.stopCyclingIcons()
    }
}
