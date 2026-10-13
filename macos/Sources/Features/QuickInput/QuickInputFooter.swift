import SwiftUI

// Shared typography and spacing for shortcut hints and the History action.
enum QuickInputFooterStyle {
    static let font = Font.system(size: 12)
    static let iconFont = Font.system(size: 12, weight: .regular)
    static let labelSpacing: CGFloat = 6
    static let itemSpacing: CGFloat = 8
}

struct QuickInputShortcutHint: View {
    let symbols: [String]
    let title: String

    var body: some View {
        HStack(spacing: QuickInputFooterStyle.labelSpacing) {
            HStack(spacing: 2) {
                ForEach(symbols, id: \.self) { symbol in
                    Image(systemName: symbol)
                        .font(QuickInputFooterStyle.iconFont)
                }
            }
            Text(title).font(QuickInputFooterStyle.font)
        }
        .accessibilityElement(children: .combine)
    }
}

struct QuickInputHistoryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: QuickInputFooterStyle.labelSpacing) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(QuickInputFooterStyle.iconFont)
                Text(title).font(QuickInputFooterStyle.font)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            // A plain Button otherwise hits just the image/text shapes. Include
            // the gap and padding so the whole action is one continuous target.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
