import AppKit
import SwiftUI

/// Retain visited pane views so selection does not synchronously tear down and
/// rebuild large file/history trees. Providers still receive Core lifecycle.
struct InspectorPaneDeck: NSViewRepresentable {
    let paneID: String
    let tabID: UUID
    let availableIDs: Set<String>
    let content: AnyView
    var updatesEnabled = true

    final class Container: NSView {
        private(set) var hosts: [String: NSHostingView<AnyView>] = [:]
        private var tabID: UUID?
        private var selectedID: String?
        func show(_ content: AnyView, paneID: String, tabID: UUID, availableIDs: Set<String>) {
            if self.tabID != tabID {
                hosts.values.forEach { $0.removeFromSuperview() }
                hosts.removeAll(); self.tabID = tabID
            }
            for id in hosts.keys where !availableIDs.contains(id) {
                hosts.removeValue(forKey: id)?.removeFromSuperview()
            }
            if selectedID != paneID, let old = selectedID.flatMap({ hosts[$0] }),
               let responder = window?.firstResponder as? NSView, responder.isDescendant(of: old) {
                window?.makeFirstResponder(nil)
            }
            if let host = hosts[paneID] { host.rootView = content } else {
                let host = NSHostingView(rootView: content)
                host.sizingOptions = []
                host.frame = bounds
                host.autoresizingMask = [.width, .height]
                hosts[paneID] = host
                addSubview(host)
            }
            for (id, host) in hosts { host.isHidden = id != paneID }
            selectedID = paneID
        }
    }
    func makeNSView(context: Context) -> Container { Container() }
    func updateNSView(_ view: Container, context: Context) {
        guard updatesEnabled else { return }
        view.show(AnyView(content
            .environment(\.gitCollectionColors, context.environment.gitCollectionColors)
            .environment(\.colorScheme, context.environment.colorScheme)
            .environment(\.locale, context.environment.locale)),
            paneID: paneID, tabID: tabID, availableIDs: availableIDs)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Container, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
