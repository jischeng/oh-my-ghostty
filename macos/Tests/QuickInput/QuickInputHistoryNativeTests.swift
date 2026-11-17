import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct QuickInputHistoryNativeTests {
    @Test func filteringRetainsSearchClientReconcilesSelectionAndMapsVerticalArrows() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)

        for index in 0..<50 {
            store.record("entry \(index)", paneID: pane, tabID: tab)
        }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let presentation = model.historyPresentation
        presentation.open(entries: entries)

        let host = NSHostingView(rootView: QuickInputHistoryView(
            model: model,
            store: store,
            settings: settings,
            onSelect: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        func refresh() async {
            host.layoutSubtreeIfNeeded()
            host.display()
            try? await Task.sleep(for: .milliseconds(40))
            host.layoutSubtreeIfNeeded()
        }

        await refresh()
        let input = try #require(find(QuickInputHistorySearchTextView.self, in: host))
        #expect(window.makeFirstResponder(input))
        #expect(presentation.selectedID == entries[0].id)

        // Bottom-up capsule stack: pressing Up Arrow (126) moves upward to older entries[1]; Down Arrow (125) returns.
        input.keyDown(with: try keyEvent(126, windowNumber: window.windowNumber))
        #expect(presentation.selectedID == entries[1].id)
        input.keyDown(with: try keyEvent(125, windowNumber: window.windowNumber))
        #expect(presentation.selectedID == entries[0].id)

        // Filtering 100 -> matching subset -> 0 -> 100 keeps the same mounted input client.
        presentation.beginSearch()
        presentation.query = "entry 4"
        await refresh()
        #expect(find(QuickInputHistorySearchTextView.self, in: host) === input)
        let filtered = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab, query: "entry 4")
        #expect(presentation.selectedID == filtered.first?.id)

        presentation.query = "no-such-match-xyz"
        await refresh()
        #expect(presentation.selectedID == nil)

        presentation.query = ""
        await refresh()
        #expect(find(QuickInputHistorySearchTextView.self, in: host) === input)
        #expect(presentation.selectedID == entries[0].id)
    }

    @Test func hoveringCapsuleUpdatesSelectionWithoutDisruptingMarkedText() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)

        for index in 0..<20 {
            store.record("entry \(index)", paneID: pane, tabID: tab)
        }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let presentation = model.historyPresentation
        presentation.open(entries: entries)

        let host = NSHostingView(rootView: QuickInputHistoryView(
            model: model,
            store: store,
            settings: settings,
            onSelect: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        host.layoutSubtreeIfNeeded()
        host.display()
        try await Task.sleep(for: .milliseconds(40))

        let input = try #require(find(QuickInputHistorySearchTextView.self, in: host))
        #expect(window.makeFirstResponder(input))
        input.setMarkedText(
            "拼",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        presentation.hover(entries[10].id)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))

        #expect(presentation.selectedID == entries[10].id)
        #expect(input.hasMarkedText())
        #expect(input.string == "拼")
    }

    @Test func scrollingHistoryCapsulesUnifyWidthAndIsolateOuterCutoutShadow() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)

        for index in 0..<7 {
            let text = index == 3
                ? "1234 slightly longer command prompt for unified width check"
                : "1234 item \(index)"
            store.record(text, paneID: pane, tabID: tab)
        }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let expectedWidth = QuickInputHistoryLayout.stackWidth(entries: entries, availableWidth: 500)
        #expect(expectedWidth > QuickInputHistoryLayout.controlCapsuleWidth)
        model.historyPresentation.open(entries: entries)

        let host = NSHostingView(rootView: QuickInputHistoryView(
            model: model,
            store: store,
            settings: settings,
            availableWidth: 500,
            onSelect: { _ in }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        host.layoutSubtreeIfNeeded()
        host.display()
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()

        let anchors = findAll(FloatingAccessoryAnchor.AnchorView.self, in: host)
        #expect(anchors.count >= 6)
        for anchor in anchors {
            #expect(abs(anchor.bounds.width - expectedWidth) < 0.5)
            let originInHost = anchor.convert(NSPoint.zero, to: host)
            #expect(abs(originInHost.x) < 0.5)
        }

        let scrollView = try #require(find(NSScrollView.self, in: host))
        #expect(scrollView.verticalScrollElasticity == .none)
        #expect(scrollView.horizontalScrollElasticity == .none)
        #expect(scrollView.frame.width > expectedWidth)
        #expect(
            abs(
                scrollView.frame.height
                    - QuickInputHistoryLayout.naturalEntriesHeight(entryCount: entries.count)
            ) < 0.5
        )
        #expect(
            scrollView.contentView.frame.width
                >= expectedWidth + QuickInputHistoryLayout.scrollHorizontalShadowOutset * 2 - 0.5
        )

        let shadowHosts = findAll(QuickInputOuterShadowView.HostView.self, in: host)
        #expect(shadowHosts.count == anchors.count)
        let rootLayer = try #require(host.layer)
        let shadowedLayers = collectShadowedLayers(in: rootLayer)
        let dedicatedLayers = Set(shadowHosts.map { ObjectIdentifier($0.shadowLayer) })
        #expect(!shadowedLayers.isEmpty)
        for layer in shadowedLayers {
            #expect(dedicatedLayers.contains(ObjectIdentifier(layer)))
            #expect(layer.mask != nil)
        }
    }

    @Test func dockContainerBridgesAllVerticalGapsOfScrollingHistoryStack() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let settings = OhMyGhosttySettings(fileURL: home.appendingPathComponent("settings.json"))
        let store = QuickInputHistoryStore()
        let model = AgentQuickInputModel(dockHeight: 252, historyStore: store)
        let pane = UUID()
        let tab = UUID()
        model.bindHistory(to: tab, paneIDs: [pane])
        model.present(for: pane, requestFocus: false)

        for index in 0..<8 {
            store.record("history item \(index)", paneID: pane, tabID: tab)
        }
        let entries = store.visibleEntries(paneID: pane, tabID: tab, scope: .tab)
        let stackWidth = QuickInputHistoryLayout.stackWidth(entries: entries, availableWidth: 800)
        let stackHeight = QuickInputHistoryLayout.stackHeight(entryCount: entries.count)
        model.historyPresentation.open(entries: entries)

        let historyView = QuickInputHistoryView(
            model: model,
            store: store,
            settings: settings,
            availableWidth: 800,
            onSelect: { _ in }
        )
        let container = AgentQuickInputDockContainer.Container(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.contentView = nil; window.close() }

        container.update(
            content: AnyView(Color.clear),
            composer: AnyView(Color.clear),
            queue: AnyView(historyView),
            composerHeight: 148,
            queueHeight: stackHeight,
            queueWidth: stackWidth,
            composerAccessoryOrigin: CGPoint(x: 40, y: 38)
        )
        container.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        container.layoutSubtreeIfNeeded()

        // insetX = 16 -> queueX = 56, composerY = 12 -> queueY = 50
        let queueX: CGFloat = 56
        let queueY: CGFloat = 50
        let sampleX = queueX + stackWidth * 0.5
        for offset in stride(from: CGFloat(4), through: stackHeight - 4, by: 3) {
            let pt = NSPoint(x: sampleX, y: queueY + offset)
            #expect(container.queueHost.hitTest(pt) != nil, "Gap or capsule at yOffset=\(offset) must stay hit-tested")
            #expect(container.occludesContentPoint(inWindow: pt))
        }
        #expect(container.queueHost.hitTest(NSPoint(x: queueX + stackWidth + 12, y: queueY + 130)) == nil)
        #expect(!container.occludesContentPoint(inWindow: NSPoint(x: queueX + stackWidth + 12, y: queueY + 130)))
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        (view as? T) ?? view.subviews.lazy.compactMap { find(type, in: $0) }.first
    }

    private func findAll<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        var results: [T] = []
        if let match = view as? T {
            results.append(match)
        }
        for subview in view.subviews {
            results.append(contentsOf: findAll(type, in: subview))
        }
        return results
    }

    private func collectShadowedLayers(in layer: CALayer) -> [CALayer] {
        var results: [CALayer] = []
        if layer.shadowOpacity > 0 {
            results.append(layer)
        }
        for sublayer in layer.sublayers ?? [] {
            results.append(contentsOf: collectShadowedLayers(in: sublayer))
        }
        return results
    }

    private func keyEvent(_ keyCode: UInt16, windowNumber: Int) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: windowNumber,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
