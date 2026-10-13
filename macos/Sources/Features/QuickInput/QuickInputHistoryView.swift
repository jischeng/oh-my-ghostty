import SwiftUI

private struct QuickInputHistoryHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 88
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct QuickInputHistoryView: View {
    @ObservedObject var model: AgentQuickInputModel
    @ObservedObject var store: QuickInputHistoryStore
    @ObservedObject var settings: OhMyGhosttySettings
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var contentHeight: CGFloat = 88
    @State private var measuredEntryIDs: [UUID] = []
    @FocusState private var isSearchFocused: Bool

    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }
    private var entries: [QuickInputHistoryEntry] {
        store.visibleEntries(paneID: model.targetSurfaceID, tabID: model.historyTabID,
                             scope: settings.quickInputHistoryScope, query: query)
    }

    var body: some View {
        // Filter once per render, not once again for every row's divider.
        let matches = entries
        let entryIDs = matches.map(\.id)
        // Use a count-based first layout until SwiftUI has measured this exact
        // result set. Never reuse a previous search's (or one-row) tiny height.
        let listHeight = measuredEntryIDs == entryIDs ? contentHeight : CGFloat(matches.count) * 88
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label(strings.quickInputHistoryTitle, systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                Text(strings.quickInputHistoryScopeName(settings.quickInputHistoryScope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(matches.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(strings.quickInputHistorySearch, text: $query)
                    .textFieldStyle(.plain)
                    .focused($isSearchFocused)
                if !query.isEmpty {
                    Button {
                        query = ""
                        isSearchFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(strings.quickInputHistoryClearSearch)
                }
            }
            .padding(9)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            Divider()

            if matches.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: query.isEmpty ? "clock" : "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                    Text(query.isEmpty ? strings.quickInputHistoryEmpty : strings.quickInputHistoryNoMatches)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 96)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(matches) { entry in
                            QuickInputHistoryRow(entry: entry) { onSelect(entry.text) }
                            if entry.id != matches.last?.id {
                                Divider().padding(.horizontal, 12)
                            }
                        }
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: QuickInputHistoryHeightKey.self,
                                                   value: geometry.size.height)
                        }
                    }
                }
                .frame(height: min(max(listHeight, 60), 340))
                .onPreferenceChange(QuickInputHistoryHeightKey.self) { height in
                    if measuredEntryIDs != entryIDs || abs(contentHeight - height) > 0.5 {
                        measuredEntryIDs = entryIDs
                        contentHeight = height
                    }
                }
            }

            Divider()
            Text(strings.quickInputHistoryAppendHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            if store.storageError != nil {
                Label(strings.quickInputHistoryStorageError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .frame(width: 400)
        .environment(\.locale, Locale(identifier: strings.languageCode))
        .onAppear {
            store.pruneExpired()
            isSearchFocused = true
        }
    }
}

private struct QuickInputHistoryRow: View {
    let entry: QuickInputHistoryEntry
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.sentAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Rendering a whole 1 MiB submitted prompt in every row would
                // make search and scrolling expensive. Selection uses full text.
                Text(String(entry.text.prefix(400)))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovered ? Color.primary.opacity(0.06) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { isHovered = $0 }
        .help(String(entry.text.prefix(1_000)))
    }
}
