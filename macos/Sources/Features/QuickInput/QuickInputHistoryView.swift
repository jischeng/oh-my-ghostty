import AppKit
import SwiftUI

private enum QuickInputHistoryLayout {
    static func listHeight(_ entries: [QuickInputHistoryEntry]) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let height = entries.reduce(CGFloat(0)) { height, entry in
            let text = NSAttributedString(string: String(entry.text.prefix(400)), attributes: [
                .font: font, .paragraphStyle: paragraph,
            ])
            let bounds = text.boundingRect(with: NSSize(width: 368, height: CGFloat.greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
            // Date, 3pt gap, 6pt vertical padding, and at most three text lines.
            return height + 14 + 3 + 12 + min(max(ceil(bounds.height), lineHeight), lineHeight * 3)
        }
        return min(height + CGFloat(max(entries.count - 1, 0)), 480)
    }
}

struct QuickInputHistoryView: View {
    @ObservedObject var model: AgentQuickInputModel
    @ObservedObject var store: QuickInputHistoryStore
    @ObservedObject var settings: OhMyGhosttySettings
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var isSearchExpanded = false
    @FocusState private var isSearchFocused: Bool

    private var strings: SettingsStrings { SettingsStrings(language: settings.language) }
    private var entries: [QuickInputHistoryEntry] {
        store.visibleEntries(paneID: model.targetSurfaceID, tabID: model.historyTabID,
                             scope: settings.quickInputHistoryScope, query: query)
    }

    var body: some View {
        // Filter once per render, not once again for every row's divider.
        let matches = entries
        // Compute from bounded previews rather than measuring inside a scroll
        // viewport, which can report clipped content and leave only one row visible.
        let listHeight = QuickInputHistoryLayout.listHeight(matches)
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
                Button {
                    isSearchExpanded.toggle()
                    if isSearchExpanded {
                        isSearchFocused = true
                    } else {
                        query = ""
                        isSearchFocused = false
                    }
                } label: {
                    Image(systemName: isSearchExpanded ? "xmark" : "magnifyingglass")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isSearchExpanded ? strings.quickInputHistoryClearSearch : strings.quickInputHistorySearch)
                .accessibilityLabel(isSearchExpanded ? strings.quickInputHistoryClearSearch : strings.quickInputHistorySearch)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if isSearchExpanded {
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
                .padding(.bottom, 10)
            }
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
                    // Measure the complete intrinsic list, not a VStack
                    // compressed to the previous popover viewport height.
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(height: min(max(listHeight, 40), 480))
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
        }
    }
}

private struct QuickInputHistoryRow: View {
    let entry: QuickInputHistoryEntry
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.sentAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Rendering a whole 1 MiB submitted prompt in every row would
                // make search and scrolling expensive. Selection uses full text.
                Text(String(entry.text.prefix(400)))
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(1)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
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
