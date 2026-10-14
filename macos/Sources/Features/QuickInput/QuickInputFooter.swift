import SwiftUI

// Shared typography, hit targets, hover and pressed feedback for all actions.
enum QuickInputFooterStyle {
    static let font = Font.system(size: 12)
    static let iconFont = Font.system(size: 10, weight: .regular)
    static let labelSpacing: CGFloat = 6
    static let itemSpacing: CGFloat = 4
}

struct QuickInputFooterButtonStyle: ButtonStyle {
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6)
            .frame(minHeight: 24)
            .background(.primary.opacity(
                isEnabled && (isActive || isHovered || configuration.isPressed)
                    ? (configuration.isPressed ? 0.16 : 0.08) : 0
            ), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovered = $0 }
    }
}

struct QuickInputShortcutHint: View {
    let symbols: [String]
    let title: String

    var body: some View {
        HStack(spacing: QuickInputFooterStyle.labelSpacing) {
            HStack(spacing: 2) {
                ForEach(symbols, id: \.self) { symbol in
                    Image(systemName: symbol).font(QuickInputFooterStyle.iconFont)
                }
            }
            Text(title).font(QuickInputFooterStyle.font)
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuickInputFooterActionButton: View {
    let symbols: [String]
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { QuickInputShortcutHint(symbols: symbols, title: title) }
            .buttonStyle(QuickInputFooterButtonStyle())
    }
}

struct QuickInputFooterIconButton: View {
    let title: String
    let symbol: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(QuickInputFooterStyle.iconFont)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(QuickInputFooterButtonStyle(isActive: isActive))
        .accessibilityLabel(title)
        .help(title)
    }
}

struct QuickInputHistoryButton: View {
    let title: String
    var isActive = false
    let action: () -> Void

    var body: some View {
        QuickInputFooterIconButton(title: title, symbol: "clock.arrow.circlepath",
                                  isActive: isActive, action: action)
    }
}
