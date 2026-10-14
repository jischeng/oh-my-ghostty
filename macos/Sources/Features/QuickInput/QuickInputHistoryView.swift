import AppKit
import SwiftUI

private enum QuickInputHistoryLayout {
    static func listHeight(_ entries: [QuickInputHistoryEntry]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        var height: CGFloat = 0
        for (index, entry) in entries.enumerated() {
            let text = NSAttributedString(string: String(entry.text.prefix(400)), attributes: [
                .font: font, .paragraphStyle: paragraph,
            ])
            let bounds = text.boundingRect(with: NSSize(width: 368, height: CGFloat.greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            height += 14 + 3 + 12 + min(max(ceil(bounds.height), lineHeight), lineHeight * 3)
            if index > 0 { height += 1 }
            // Once capped, there is no need to measure hundreds of offscreen
            // previews again on every keyboard-selection change.
            if height >= 480 { return 480 }
        }
        return height
    }
}

struct QuickInputHistoryView: View {
    @ObservedObject var model: AgentQuickInputModel
    @ObservedObject var store: QuickInputHistoryStore
    @ObservedObject var settings: OhMyGhosttySettings
    @ObservedObject var presentation: QuickInputHistoryPresentation
    let onSelect: (String) -> Void

    init(model: AgentQuickInputModel, store: QuickInputHistoryStore,
         settings: OhMyGhosttySettings, onSelect: @escaping (String) -> Void) {
        self.model = model
        self.store = store
        self.settings = settings
        self.presentation = model.historyPresentation
        self.onSelect = onSelect
    }

    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }
    private var entries: [QuickInputHistoryEntry] {
        store.visibleEntries(paneID: model.targetSurfaceID, tabID: model.historyTabID,
                             scope: settings.quickInputHistoryScope,
                             query: presentation.isSearching ? presentation.query : "")
    }

    var body: some View {
        let matches = entries
        let listHeight = QuickInputHistoryLayout.listHeight(matches)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label(strings.quickInputHistoryTitle, systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text(strings.quickInputHistoryScopeName(settings.quickInputHistoryScope))
                    .font(.caption).foregroundStyle(.secondary)
                Text("\(matches.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    if presentation.isSearching { presentation.endSearch() } else { presentation.beginSearch() }
                } label: {
                    Image(systemName: presentation.isSearching ? "xmark" : "magnifyingglass")
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(presentation.isSearching ? strings.quickInputHistoryExitSearch : strings.quickInputHistorySearch)
                .accessibilityLabel(presentation.isSearching ? strings.quickInputHistoryExitSearch : strings.quickInputHistorySearch)
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)

            // Keep the native input client mounted while collapsed, so the first
            // keystroke and IME composition survive entering search mode.
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                QuickInputHistorySearchEditor(
                    query: $presentation.query,
                    placeholder: strings.quickInputHistorySearch,
                    isSearching: presentation.isSearching,
                    focusRequestID: presentation.focusRequestID,
                    onBeginSearch: { presentation.beginSearch(clearQuery: true) },
                    onMove: { presentation.moveSelection(by: $0, entries: entries) },
                    onSelect: selectCurrent,
                    onEscape: {
                        if presentation.escape() { model.requestFocus() }
                    },
                    onToggle: {
                        presentation.close()
                        model.requestFocus()
                    },
                    canRequestFocus: { presentation.isPresented }
                )
                if !presentation.query.isEmpty {
                    Button {
                        presentation.query = ""
                        presentation.requestFocus()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strings.quickInputHistoryClearSearch)
                }
            }
            .frame(height: presentation.isSearching ? 32 : 0)
            .padding(.horizontal, presentation.isSearching ? 9 : 0)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14)
            .padding(.bottom, presentation.isSearching ? 10 : 0)
            .opacity(presentation.isSearching ? 1 : 0)
            .clipped()
            .accessibilityHidden(!presentation.isSearching)
            Divider()

            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: presentation.isSearching ? "magnifyingglass" : "clock")
                        .font(.title2).foregroundStyle(.tertiary)
                    Text(presentation.isSearching ? strings.quickInputHistoryNoMatches : strings.quickInputHistoryEmpty)
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).frame(height: 96)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(matches) { entry in
                                QuickInputHistoryRow(entry: entry, isSelected: presentation.selectedID == entry.id,
                                    onHover: { presentation.hover(entry.id) }, action: {
                                        presentation.select(entry.id)
                                        onSelect(entry.text)
                                    })
                                .id(entry.id)
                                if entry.id != matches.last?.id { Divider().padding(.horizontal, 12) }
                            }
                        }
                    }
                    .frame(height: min(max(listHeight, 40), 480))
                    .onAppear {
                        if let id = presentation.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                    // Hover updates selection but must not scroll the list out
                    // from under the pointer. Only keyboard navigation scrolls.
                    .onChange(of: presentation.keyboardSelectionRevision) { _ in
                        if let id = presentation.selectedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }

            Divider()
            Text(settings.quickInputHistoryInsertionMode == .append
                 ? strings.quickInputHistoryAppendHint : strings.quickInputHistoryReplaceHint)
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 14).padding(.vertical, 10)
            if store.storageError != nil {
                Label(strings.quickInputHistoryStorageError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
        }
        .frame(width: 400)
        .environment(\.locale, Locale(identifier: strings.languageCode))
        .onAppear {
            store.pruneExpired()
            presentation.reconcile(entries: entries)
            presentation.requestFocus()
        }
        .onChange(of: matches.map(\.id)) { _ in presentation.reconcile(entries: entries) }
    }

    private func selectCurrent() {
        guard let entry = entries.first(where: { $0.id == presentation.selectedID }) else { return }
        onSelect(entry.text)
    }
}

private struct QuickInputHistoryRow: View {
    let entry: QuickInputHistoryEntry
    let isSelected: Bool
    let onHover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.sentAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Text(String(entry.text.prefix(400)))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(1).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading).foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.primary.opacity(isSelected ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).padding(.horizontal, 4)
        .onHover { hovered in if hovered { onHover() } }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(String(entry.text.prefix(1_000)))
    }
}
