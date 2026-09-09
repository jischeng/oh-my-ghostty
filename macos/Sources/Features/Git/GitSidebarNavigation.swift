import SwiftUI

struct GitSidebarNavigation: View {
    let selected: InspectorGitContent.ActiveTab
    let select: (InspectorGitContent.ActiveTab) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(InspectorGitContent.ActiveTab.allCases, id: \.self) { tab in
                Item(tab: tab, selected: selected == tab) { select(tab) }
            }
        }
        .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.14), lineWidth: 0.5))
    }

    private struct Item: View {
        let tab: InspectorGitContent.ActiveTab
        let selected: Bool
        let action: () -> Void
        @State private var hovered = false
        var body: some View {
            Button(action: action) {
                Text(tab.rawValue)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .contentShape(Rectangle())
                    .background(Color.primary.opacity(hovered ? 0.05 : 0))
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? Color.accentColor : .clear)
                            .frame(height: 1.5).padding(.horizontal, 12)
                    }
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityValue(selected ? "Selected" : "")
        }
    }
}
