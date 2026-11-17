import AppKit
import SwiftUI

enum QuickInputHistoryLayout {
    static let entryCapsuleHeight: CGFloat = 34
    static let controlCapsuleHeight: CGFloat = 32
    static let capsuleSpacing: CGFloat = 7
    static let maxVisibleEntries = 5
    static let minimumCapsuleWidth: CGFloat = 248
    static let maximumCapsuleWidth: CGFloat = 430
    static let controlCapsuleWidth: CGFloat = 296
    static let scrollHorizontalShadowOutset: CGFloat = 14

    static func entryPreview(_ text: String) -> String {
        var collapsed = ""
        collapsed.reserveCapacity(min(text.count, 80))
        var lastWasNewline = false
        for scalar in text.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) {
                if !lastWasNewline {
                    collapsed.append(" ↵ ")
                    lastWasNewline = true
                }
            } else {
                collapsed.unicodeScalars.append(scalar)
                lastWasNewline = false
            }
        }
        let trimmed = collapsed.trimmingCharacters(in: .whitespaces)
        let source = trimmed.isEmpty ? text : trimmed
        return source.count > 52 ? String(source.prefix(52)) + "…" : source
    }

    static func naturalEntriesHeight(entryCount: Int) -> CGFloat {
        let count = min(max(entryCount, 1), maxVisibleEntries)
        return CGFloat(count) * entryCapsuleHeight + CGFloat(max(0, count - 1)) * capsuleSpacing
    }

    static func stackHeight(
        entryCount: Int,
        storageError: Bool = false,
        maxHeight: CGFloat = .greatestFiniteMagnitude
    ) -> CGFloat {
        let entriesHeight = naturalEntriesHeight(entryCount: entryCount)
        let errorHeight = storageError ? entryCapsuleHeight + capsuleSpacing : 0
        return min(maxHeight, entriesHeight + capsuleSpacing + controlCapsuleHeight + errorHeight)
    }

    static func capsuleWidth(
        previewCount: Int,
        hasDeliveryBadge: Bool,
        availableWidth: CGFloat
    ) -> CGFloat {
        let estimated = CGFloat(previewCount) * 7.3 + 118 + (hasDeliveryBadge ? 46 : 0)
        let maxAllowed = min(
            maximumCapsuleWidth,
            max(minimumCapsuleWidth, availableWidth - AgentQuickInputMetrics.floatingHorizontalInset * 2)
        )
        return min(max(estimated, minimumCapsuleWidth), maxAllowed)
    }

    static func stackWidth(
        entries: [QuickInputHistoryEntry],
        availableWidth: CGFloat
    ) -> CGFloat {
        let maxAllowed = min(
            maximumCapsuleWidth,
            max(minimumCapsuleWidth, availableWidth - AgentQuickInputMetrics.floatingHorizontalInset * 2)
        )
        let baseControl = min(controlCapsuleWidth, maxAllowed)
        let entriesMax = entries.prefix(20).map { entry in
            capsuleWidth(
                previewCount: AgentQuickInputMetrics.displayColumnCount(entryPreview(entry.text)),
                hasDeliveryBadge: entry.deliveryState != .sent,
                availableWidth: availableWidth
            )
        }.max() ?? minimumCapsuleWidth
        return max(baseControl, entriesMax)
    }
}

struct QuickInputHistoryView: View {
    @ObservedObject var model: AgentQuickInputModel
    @ObservedObject var store: QuickInputHistoryStore
    @ObservedObject var settings: OhMyGhosttySettings
    @ObservedObject var presentation: QuickInputHistoryPresentation
    let chromeBackground: Color
    let isExpanded: Bool
    let availableWidth: CGFloat
    let maxHeight: CGFloat
    let onSelect: (String) -> Void

    @State private var visualExpanded = false
    @State private var isLiveScrolling = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        model: AgentQuickInputModel,
        store: QuickInputHistoryStore,
        settings: OhMyGhosttySettings,
        chromeBackground: Color = Color(nsColor: .windowBackgroundColor),
        isExpanded: Bool = true,
        availableWidth: CGFloat = 1_000,
        maxHeight: CGFloat = .greatestFiniteMagnitude,
        onSelect: @escaping (String) -> Void
    ) {
        self.model = model
        self.store = store
        self.settings = settings
        self.presentation = model.historyPresentation
        self.chromeBackground = chromeBackground
        self.isExpanded = isExpanded
        self.availableWidth = availableWidth
        self.maxHeight = maxHeight
        self.onSelect = onSelect
    }

    private var entries: [QuickInputHistoryEntry] {
        store.visibleEntries(
            paneID: model.targetSurfaceID,
            tabID: model.historyTabID,
            scope: settings.quickInputHistoryScope,
            query: presentation.isSearching ? presentation.query : ""
        )
    }

    private var strings: SettingsStrings {
        SettingsStrings(language: settings.language)
    }

    var body: some View {
        let matches = entries
        let stackWidth = QuickInputHistoryLayout.stackWidth(entries: matches, availableWidth: availableWidth)
        let totalHeight = QuickInputHistoryLayout.stackHeight(
            entryCount: matches.count,
            storageError: store.storageError != nil,
            maxHeight: maxHeight
        )
        let nonEntryHeight = QuickInputHistoryLayout.capsuleSpacing
            + QuickInputHistoryLayout.controlCapsuleHeight
            + (store.storageError != nil
                ? QuickInputHistoryLayout.entryCapsuleHeight + QuickInputHistoryLayout.capsuleSpacing
                : 0)
        let entriesMaxHeight = max(
            QuickInputHistoryLayout.entryCapsuleHeight,
            totalHeight - nonEntryHeight
        )
        let needsScroll = matches.count > QuickInputHistoryLayout.maxVisibleEntries
            || entriesMaxHeight < QuickInputHistoryLayout.naturalEntriesHeight(entryCount: matches.count)
        let totalAnimatedCount = 1 + max(matches.count, 1) + (store.storageError != nil ? 1 : 0)

        VStack(alignment: .leading, spacing: QuickInputHistoryLayout.capsuleSpacing) {
            if store.storageError != nil {
                QuickInputHistoryErrorCapsule(
                    text: strings.quickInputHistoryStorageError,
                    width: stackWidth,
                    chromeBackground: chromeBackground,
                    isExpanded: isExpanded
                )
                .modifier(
                    HistoryCapsuleFanOutModifier(
                        visualExpanded: visualExpanded,
                        distanceFromSwitch: max(matches.count, 1) + 1,
                        totalCount: totalAnimatedCount,
                        reduceMotion: reduceMotion
                    )
                )
            }

            if matches.isEmpty {
                QuickInputHistoryEmptyCapsule(
                    text: presentation.isSearching
                        ? strings.quickInputHistoryNoMatches
                        : strings.quickInputHistoryEmpty,
                    width: stackWidth,
                    chromeBackground: chromeBackground,
                    isExpanded: isExpanded
                )
                .modifier(
                    HistoryCapsuleFanOutModifier(
                        visualExpanded: visualExpanded,
                        distanceFromSwitch: 1,
                        totalCount: totalAnimatedCount,
                        reduceMotion: reduceMotion
                    )
                )
            } else if needsScroll {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        entriesColumn(
                            matches: matches,
                            width: stackWidth,
                            totalAnimatedCount: totalAnimatedCount,
                            isScrollingContainer: true
                        )
                        .quickInputScrollTargetLayout()
                        .background(
                            QuickInputScrollViewConfigurator { live in
                                isLiveScrolling = live
                            }
                        )
                        .padding(.horizontal, QuickInputHistoryLayout.scrollHorizontalShadowOutset)
                    }
                    .quickInputViewAlignedScroll()
                    .frame(
                        width: stackWidth + QuickInputHistoryLayout.scrollHorizontalShadowOutset * 2,
                        height: entriesMaxHeight
                    )
                    .padding(.horizontal, -QuickInputHistoryLayout.scrollHorizontalShadowOutset)
                    .onAppear {
                        scrollToActiveSelection(proxy: proxy, matches: matches)
                    }
                    .onChange(of: matches.map(\.id)) { _ in
                        scrollToActiveSelection(proxy: proxy, matches: matches)
                    }
                    .onChange(of: presentation.keyboardSelectionRevision) { _ in
                        if let selectedID = presentation.selectedID {
                            proxy.scrollTo(selectedID)
                        }
                    }
                }
            } else {
                entriesColumn(
                    matches: matches,
                    width: stackWidth,
                    totalAnimatedCount: totalAnimatedCount,
                    isScrollingContainer: false
                )
            }

            QuickInputHistoryControlCapsule(
                presentation: presentation,
                settings: settings,
                strings: strings,
                companionSurfaceID: model.targetSurfaceID,
                entries: matches,
                width: stackWidth,
                chromeBackground: chromeBackground,
                isExpanded: isExpanded,
                onMove: { delta in
                    presentation.moveSelection(by: -delta, entries: matches)
                },
                onSelect: {
                    guard let entry = matches.first(where: { $0.id == presentation.selectedID })
                        ?? matches.first else {
                        return
                    }
                    onSelect(entry.text)
                },
                onEscape: {
                    if presentation.escape() {
                        model.requestFocus()
                    }
                },
                onToggle: {
                    presentation.close()
                    model.requestFocus()
                }
            )
            .modifier(
                HistoryCapsuleFanOutModifier(
                    visualExpanded: visualExpanded,
                    distanceFromSwitch: 0,
                    totalCount: totalAnimatedCount,
                    reduceMotion: reduceMotion
                )
            )
        }
        .frame(width: stackWidth, height: totalHeight, alignment: .bottomLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.quickInputHistoryTitle)
        .onAppear {
            store.pruneExpired()
            presentation.reconcile(entries: matches)
            if isExpanded {
                presentation.requestFocus()
                Task { @MainActor in
                    visualExpanded = true
                }
            } else {
                visualExpanded = false
            }
        }
        .onChange(of: isExpanded) { expanded in
            visualExpanded = expanded
            if expanded {
                presentation.reconcile(entries: matches)
                presentation.requestFocus()
            } else {
                isLiveScrolling = false
            }
        }
    }

    private func scrollToActiveSelection(
        proxy: ScrollViewProxy,
        matches: [QuickInputHistoryEntry]
    ) {
        let targetID = matches.first(where: { $0.id == presentation.selectedID })?.id ?? matches.first?.id
        guard let targetID else { return }
        if targetID == matches.first?.id {
            proxy.scrollTo(targetID, anchor: .bottom)
        } else {
            proxy.scrollTo(targetID)
        }
    }

    private func entriesColumn(
        matches: [QuickInputHistoryEntry],
        width: CGFloat,
        totalAnimatedCount: Int,
        isScrollingContainer: Bool
    ) -> some View {
        let bottomUpEntries = Array(matches.enumerated().reversed())
        return VStack(alignment: .leading, spacing: QuickInputHistoryLayout.capsuleSpacing) {
            ForEach(bottomUpEntries, id: \.element.id) { index, entry in
                QuickInputHistoryEntryCapsule(
                    entry: entry,
                    width: width,
                    isSelected: presentation.selectedID == entry.id,
                    isExpanded: isExpanded,
                    suppressHover: isLiveScrolling,
                    chromeBackground: chromeBackground,
                    strings: strings,
                    onHoverChanged: { hovered in
                        guard !isLiveScrolling else { return }
                        if hovered {
                            presentation.hover(entry.id)
                        }
                    },
                    onChoose: {
                        presentation.select(entry.id)
                        onSelect(entry.text)
                    }
                )
                .id(entry.id)
                .quickInputScrollCapsuleTransition(
                    enabled: isScrollingContainer,
                    anchor: .leading
                )
                .modifier(
                    HistoryCapsuleFanOutModifier(
                        visualExpanded: visualExpanded,
                        distanceFromSwitch: index + 1,
                        totalCount: totalAnimatedCount,
                        reduceMotion: reduceMotion
                    )
                )
            }
        }
    }
}

private struct HistoryCapsuleFanOutModifier: ViewModifier {
    let visualExpanded: Bool
    let distanceFromSwitch: Int
    let totalCount: Int
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        let travel = CGFloat(min(distanceFromSwitch + 1, 6)) * 22
        content
            .scaleEffect(visualExpanded ? 1.0 : 0.80, anchor: .bottomLeading)
            .offset(y: visualExpanded ? 0 : travel)
            .opacity(visualExpanded ? 1.0 : 0.0)
            .animation(animation, value: visualExpanded)
    }

    private var animation: Animation {
        if reduceMotion {
            return .linear(duration: 0.01)
        }
        if visualExpanded {
            let delay = Double(min(distanceFromSwitch, 6)) * 0.032
            return .spring(response: 0.30, dampingFraction: 0.76).delay(delay)
        }
        let reverseOrder = max(0, min(totalCount - 1 - distanceFromSwitch, 5))
        return .spring(response: 0.22, dampingFraction: 0.88).delay(Double(reverseOrder) * 0.020)
    }
}

private struct QuickInputHistoryEntryCapsule: View {
    let entry: QuickInputHistoryEntry
    let width: CGFloat
    let isSelected: Bool
    let isExpanded: Bool
    var suppressHover = false
    let chromeBackground: Color
    let strings: SettingsStrings
    let onHoverChanged: (Bool) -> Void
    let onChoose: () -> Void

    @State private var isHovered = false

    private var colorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    private var deliveryLabel: String? {
        switch entry.deliveryState {
        case .sent: nil
        case .queued: strings.t("Queued", "排队中")
        case .cancelled: strings.t("Cancelled", "已取消")
        }
    }

    private var compactTimestamp: String {
        Self.formatter(isToday: Calendar.current.isDateInToday(entry.sentAt))
            .string(from: entry.sentAt)
    }

    private var tooltipText: String {
        let dateText = Self.tooltipFormatter(locale: Locale(identifier: strings.languageCode))
            .string(from: entry.sentAt)
        let deliveryText: String = switch entry.deliveryState {
        case .sent: strings.t("Sent", "已发送")
        case .queued: strings.t("Queued", "排队中")
        case .cancelled: strings.t("Cancelled", "已取消")
        }
        let capped = entry.text.count > 2_000
            ? String(entry.text.prefix(2_000)) + "\n…"
            : entry.text
        return "\(dateText) · \(deliveryText)\n\n\(capped)"
    }

    private static func formatter(isToday: Bool) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = isToday ? "HH:mm" : "MM/dd HH:mm"
        return formatter
    }

    private static func tooltipFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }

    var body: some View {
        Button(action: onChoose) {
            HStack(spacing: 6) {
                Image(systemName: isSelected ? "return" : "clock")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .frame(width: 12)
                Text(QuickInputHistoryLayout.entryPreview(entry.text))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let deliveryLabel {
                    Text(deliveryLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(entry.deliveryState == .queued ? Color.accentColor : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            (entry.deliveryState == .queued ? Color.accentColor : Color.primary)
                                .opacity(0.14),
                            in: Capsule()
                        )
                        .fixedSize()
                }
                Text(compactTimestamp)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.horizontal, 11)
            .frame(width: width, height: QuickInputHistoryLayout.entryCapsuleHeight)
            .background(
                QuickInputGlassSurface(
                    cornerRadius: QuickInputHistoryLayout.entryCapsuleHeight * 0.5,
                    themeColor: chromeBackground,
                    tintOpacity: (isSelected || isHovered) ? 0.88 : 0.80,
                    colorScheme: colorScheme,
                    borderColor: isSelected ? Color.accentColor.opacity(0.82) : nil,
                    materialOverride: colorScheme == .light ? .popover : .hudWindow,
                    shadowOpacity: 0.18,
                    shadowRadius: 3.5,
                    shadowOffsetY: 1.5
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            guard !(suppressHover && hovering) else { return }
            isHovered = hovering
            onHoverChanged(hovering)
        }
        .pointingHandCursor()
        .help(tooltipText)
        .accessibilityLabel("\(compactTimestamp), \(entry.text)")
        .background(FloatingAccessoryAnchor(isActive: isExpanded))
        .allowsHitTesting(isExpanded)
        .environment(\.colorScheme, colorScheme)
    }
}

private struct QuickInputHistoryControlCapsule: View {
    @ObservedObject var presentation: QuickInputHistoryPresentation
    @ObservedObject var settings: OhMyGhosttySettings
    let strings: SettingsStrings
    let companionSurfaceID: UUID?
    let entries: [QuickInputHistoryEntry]
    let width: CGFloat
    let chromeBackground: Color
    let isExpanded: Bool
    let onMove: (Int) -> Void
    let onSelect: () -> Void
    let onEscape: () -> Void
    let onToggle: () -> Void

    private var colorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                if presentation.isSearching {
                    presentation.endSearch()
                } else {
                    presentation.beginSearch()
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(presentation.isSearching ? Color.accentColor : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(presentation.isSearching ? strings.quickInputHistoryExitSearch : strings.quickInputHistorySearch)
            .accessibilityLabel(
                presentation.isSearching ? strings.quickInputHistoryExitSearch : strings.quickInputHistorySearch
            )

            QuickInputHistorySearchEditor(
                query: $presentation.query,
                placeholder: strings.quickInputHistorySearch,
                isSearching: presentation.isSearching,
                focusRequestID: presentation.focusRequestID,
                onBeginSearch: { presentation.beginSearch(clearQuery: true) },
                onMove: onMove,
                onSelect: onSelect,
                onEscape: onEscape,
                onToggle: onToggle,
                entries: entries,
                onEntriesChanged: { presentation.reconcile(entries: $0) },
                companionSurfaceID: companionSurfaceID,
                canRequestFocus: { isExpanded && presentation.isPresented }
            )
            .frame(maxWidth: .infinity, maxHeight: 26)

            if !presentation.query.isEmpty {
                Button {
                    presentation.query = ""
                    presentation.requestFocus()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .help(strings.quickInputHistoryClearSearch)
                .accessibilityLabel(strings.quickInputHistoryClearSearch)
            }

            Button(action: cycleScope) {
                Text("\(strings.quickInputHistoryScopeName(settings.quickInputHistoryScope)) · \(entries.count)")
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .pointingHandCursor()
            .help(strings.quickInputHistoryScopeLabel)
            .accessibilityLabel(strings.quickInputHistoryScopeLabel)
        }
        .padding(.horizontal, 10)
        .frame(width: width, height: QuickInputHistoryLayout.controlCapsuleHeight)
        .background(
            QuickInputGlassSurface(
                cornerRadius: QuickInputHistoryLayout.controlCapsuleHeight * 0.5,
                themeColor: chromeBackground,
                tintOpacity: presentation.isSearching ? 0.88 : 0.80,
                colorScheme: colorScheme,
                borderColor: presentation.isSearching ? Color.accentColor.opacity(0.65) : nil,
                materialOverride: colorScheme == .light ? .popover : .hudWindow,
                shadowOpacity: 0.18,
                shadowRadius: 3.5,
                shadowOffsetY: 1.5
            )
        )
        .contentShape(Capsule())
        .background(FloatingAccessoryAnchor(isActive: isExpanded))
        .allowsHitTesting(isExpanded)
        .environment(\.colorScheme, colorScheme)
    }

    private func cycleScope() {
        switch settings.quickInputHistoryScope {
        case .pane: settings.quickInputHistoryScope = .tab
        case .tab: settings.quickInputHistoryScope = .global
        case .global: settings.quickInputHistoryScope = .pane
        }
        presentation.requestFocus()
    }
}

private struct QuickInputHistoryEmptyCapsule: View {
    let text: String
    let width: CGFloat
    let chromeBackground: Color
    let isExpanded: Bool

    private var colorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: QuickInputHistoryLayout.entryCapsuleHeight)
        .background(
            QuickInputGlassSurface(
                cornerRadius: QuickInputHistoryLayout.entryCapsuleHeight * 0.5,
                themeColor: chromeBackground,
                tintOpacity: 0.80,
                colorScheme: colorScheme,
                materialOverride: colorScheme == .light ? .popover : .hudWindow,
                shadowOpacity: 0.18,
                shadowRadius: 3.5,
                shadowOffsetY: 1.5
            )
        )
        .contentShape(Capsule())
        .background(FloatingAccessoryAnchor(isActive: isExpanded))
        .allowsHitTesting(isExpanded)
        .environment(\.colorScheme, colorScheme)
    }
}

private struct QuickInputHistoryErrorCapsule: View {
    let text: String
    let width: CGFloat
    let chromeBackground: Color
    let isExpanded: Bool

    private var colorScheme: ColorScheme {
        NSColor(chromeBackground).isLightColor ? .light : .dark
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: QuickInputHistoryLayout.entryCapsuleHeight)
        .background(
            QuickInputGlassSurface(
                cornerRadius: QuickInputHistoryLayout.entryCapsuleHeight * 0.5,
                themeColor: chromeBackground,
                tintOpacity: 0.80,
                colorScheme: colorScheme,
                borderColor: Color.orange.opacity(0.55),
                materialOverride: colorScheme == .light ? .popover : .hudWindow,
                shadowOpacity: 0.18,
                shadowRadius: 3.5,
                shadowOffsetY: 1.5
            )
        )
        .contentShape(Capsule())
        .background(FloatingAccessoryAnchor(isActive: isExpanded))
        .allowsHitTesting(isExpanded)
        .environment(\.colorScheme, colorScheme)
    }
}
