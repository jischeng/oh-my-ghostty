import AppKit
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct InspectorShortcutTests {
    private func paneDescriptor(
        id: String,
        source: InspectorPaneDescriptor.Source = .coreFeature("test"),
        title: String
    ) -> InspectorPaneDescriptor {
        .init(
            id: id,
            title: title,
            systemImage: "sidebar.trailing",
            source: source,
            preferredWidth: 320,
            minimumWidth: 220
        )
    }

    @Test func defaultInspectorShortcutsFormatAndValues() {
        let slot1 = OMGKeyboardShortcut.defaultInspectorPanel(slot: 1)
        let slot2 = OMGKeyboardShortcut.defaultInspectorPanel(slot: 2)
        let slot3 = OMGKeyboardShortcut.defaultInspectorPanel(slot: 3)
        let slot4 = OMGKeyboardShortcut.defaultInspectorPanel(slot: 4)

        #expect(slot1.key == "1")
        #expect(slot1.modifiers == [.option])
        #expect(slot1.storageValue == "option+1")
        #expect(slot1.displayValue == "⌥1")

        #expect(slot2.key == "2")
        #expect(slot2.modifiers == [.option])
        #expect(slot2.storageValue == "option+2")
        #expect(slot2.displayValue == "⌥2")

        #expect(slot3.key == "3")
        #expect(slot3.modifiers == [.option])
        #expect(slot3.storageValue == "option+3")
        #expect(slot3.displayValue == "⌥3")

        #expect(slot4.key == "4")
        #expect(slot4.modifiers == [.option])
        #expect(slot4.storageValue == "option+4")
        #expect(slot4.displayValue == "⌥4")
    }

    @Test func slotToggleOpensSwitchesAndHidesCorrectly() throws {
        let registry = InspectorRegistry()
        try registry.registerCorePane(
            paneDescriptor(id: "pane.first", title: "First"),
            content: { _ in .fields([]) }
        )
        try registry.registerCorePane(
            paneDescriptor(id: "pane.second", title: "Second"),
            content: { _ in .fields([]) }
        )
        try registry.registerCorePane(
            paneDescriptor(id: "pane.third", title: "Third"),
            content: { _ in .fields([]) }
        )

        let presentation = InspectorPresentationStore(
            defaults: UserDefaults(suiteName: "test.inspector.shortcuts.\(UUID().uuidString)")!
        )
        let layoutState = VerticalTabWindowLayoutState(
            isSidebarVisible: true,
            isInspectorVisible: false,
            inspectorPresentation: presentation
        )

        // 1. Initially hidden. Pressing slot 1 opens Inspector at pane 1.
        #expect(!layoutState.isInspectorVisible)
        layoutState.toggleInspectorPane(atSlot: 1, registry: registry)
        #expect(layoutState.isInspectorVisible)
        #expect(layoutState.selectedInspectorPaneID == "pane.first")

        // 2. Currently visible at slot 1. Pressing slot 1 again hides Inspector.
        layoutState.toggleInspectorPane(atSlot: 1, registry: registry)
        #expect(!layoutState.isInspectorVisible)

        // 3. Currently hidden. Pressing slot 2 opens Inspector at pane 2.
        layoutState.toggleInspectorPane(atSlot: 2, registry: registry)
        #expect(layoutState.isInspectorVisible)
        #expect(layoutState.selectedInspectorPaneID == "pane.second")

        // 4. Currently visible at slot 2. Pressing slot 1 switches to pane 1 and keeps Inspector visible.
        layoutState.toggleInspectorPane(atSlot: 1, registry: registry)
        #expect(layoutState.isInspectorVisible)
        #expect(layoutState.selectedInspectorPaneID == "pane.first")

        // 5. Currently visible at slot 1. Pressing slot 3 switches to pane 3 and keeps Inspector visible.
        layoutState.toggleInspectorPane(atSlot: 3, registry: registry)
        #expect(layoutState.isInspectorVisible)
        #expect(layoutState.selectedInspectorPaneID == "pane.third")

        // 6. Currently visible at slot 3. Pressing slot 3 again hides Inspector.
        layoutState.toggleInspectorPane(atSlot: 3, registry: registry)
        #expect(!layoutState.isInspectorVisible)

        // 7. Invalid slots (0, negative, or beyond entries count) do nothing.
        layoutState.toggleInspectorPane(atSlot: 0, registry: registry)
        #expect(!layoutState.isInspectorVisible)
        layoutState.toggleInspectorPane(atSlot: 4, registry: registry)
        #expect(!layoutState.isInspectorVisible)
    }

    @Test func settingsStringsContainInspectorShortcuts() {
        let en = SettingsStrings(language: .english)
        #expect(en.rightSidebarShortcutsSection == "Right Sidebar Shortcuts")
        #expect(en.inspectorPanelSlotLabel(slot: 1) == "Panel 1")
        #expect(en.inspectorPanelSlotLabel(slot: 4) == "Panel 4")

        let zh = SettingsStrings(language: .simplifiedChinese)
        #expect(zh.rightSidebarShortcutsSection == "右侧边栏快捷键")
        #expect(zh.inspectorPanelSlotLabel(slot: 1) == "面板 1")
        #expect(zh.inspectorPanelSlotLabel(slot: 4) == "面板 4")
    }
}
