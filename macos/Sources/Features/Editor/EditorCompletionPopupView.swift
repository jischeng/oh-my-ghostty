import AppKit
import SwiftUI

/// Observable state managing active completion suggestions and popup presentation.
@MainActor
public final class CompletionState: ObservableObject {
    @Published public var isPresented: Bool = false
    @Published public var candidates: [CompletionItem] = []
    @Published public var selectedIndex: Int = 0
    @Published public var prefix: String = ""
    @Published public var prefixRange: NSRange = NSRange(location: 0, length: 0)
    @Published public var presentationPoint: CGPoint = .zero

    public init() {}

    public var currentSelection: CompletionItem? {
        guard isPresented, !candidates.isEmpty, selectedIndex >= 0, selectedIndex < candidates.count else {
            return nil
        }
        return candidates[selectedIndex]
    }

    public func selectNext() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % candidates.count
    }

    public func selectPrevious() {
        guard !candidates.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + candidates.count) % candidates.count
    }

    public func dismiss() {
        // Selection updates also arrive during SwiftUI reconciliation. Publishing
        // unchanged values here feeds another reconciliation and never settles.
        if isPresented { isPresented = false }
        if !candidates.isEmpty { candidates = [] }
        if selectedIndex != 0 { selectedIndex = 0 }
        if !prefix.isEmpty { prefix = "" }
        if prefixRange != .zero { prefixRange = .zero }
    }

    public func update(
        candidates: [CompletionItem],
        prefix: String,
        prefixRange: NSRange,
        at point: CGPoint
    ) {
        let candidates = candidates.filter { $0.label.lowercased().hasPrefix(prefix.lowercased()) }
        self.candidates = candidates
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.presentationPoint = point
        self.selectedIndex = 0
        self.isPresented = !candidates.isEmpty
    }

    public func filter(prefix: String, prefixRange: NSRange, at point: CGPoint) {
        let selected = currentSelection
        self.prefix = prefix
        self.prefixRange = prefixRange
        self.presentationPoint = point
        let lower = prefix.lowercased()
        let matching = candidates.filter { $0.label.lowercased().hasPrefix(lower) }
        self.candidates = matching
        self.selectedIndex = selected.flatMap { matching.firstIndex(of: $0) } ?? 0
        self.isPresented = !matching.isEmpty
    }
}

/// Floating autocomplete suggestions popup.
struct EditorCompletionPopupView: View {
    @ObservedObject var state: CompletionState
    let onCommit: (CompletionItem) -> Void

    var body: some View {
        if state.isPresented && !state.candidates.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: state.candidates.count > 6) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(state.candidates.enumerated()), id: \.element.id) { index, item in
                                CompletionRowView(
                                    item: item,
                                    prefix: state.prefix,
                                    isSelected: index == state.selectedIndex
                                )
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    onCommit(item)
                                }
                            }
                        }
                        .padding(3)
                    }
                    .onChange(of: state.selectedIndex) { newIndex in
                        withAnimation(.easeInOut(duration: 0.08)) {
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
            .frame(width: 250)
            .frame(maxHeight: min(CGFloat(state.candidates.count) * 26 + 12, 190))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.28), radius: 10, x: 0, y: 5)
        }
    }
}

private struct CompletionRowView: View {
    let item: CompletionItem
    let prefix: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Semantic Kind Badge
            Text(item.kind.symbol)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(item.kind.color)
                .frame(width: 14, height: 14)
                .background(item.kind.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))

            // Label with matched prefix highlight
            highlightedLabel(item.label, prefix: prefix)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 4)

            // Detail descriptor
            if let detail = item.detail {
                Text(detail)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            isSelected
                ? Color.accentColor.opacity(0.25)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
    }

    @ViewBuilder
    private func highlightedLabel(_ label: String, prefix: String) -> some View {
        if let range = label.range(of: prefix, options: .caseInsensitive) {
            let before = String(label[..<range.lowerBound])
            let match = String(label[range])
            let after = String(label[range.upperBound...])
            HStack(spacing: 0) {
                if !before.isEmpty {
                    Text(before).foregroundStyle(Color.primary)
                }
                Text(match).fontWeight(.bold).foregroundStyle(Color.accentColor)
                if !after.isEmpty {
                    Text(after).foregroundStyle(Color.primary)
                }
            }
        } else {
            Text(label).foregroundStyle(Color.primary)
        }
    }
}
