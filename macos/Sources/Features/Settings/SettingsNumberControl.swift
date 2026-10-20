import SwiftUI

/// Consistent numeric control with direct editing and keyboard-accessible steps.
/// The model remains responsible for persistence and validation of typed values.
struct OMGSettingsNumberControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var suffix = ""

    var body: some View {
        HStack(spacing: 0) {
            Button { value = max(range.lowerBound, value - 1) } label: {
                Image(systemName: "minus").frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .disabled(value <= range.lowerBound)
            .accessibilityLabel(title + " −")
            TextField(title, value: $value, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.plain).multilineTextAlignment(.center).monospacedDigit()
                .frame(width: 44).accessibilityLabel(title)
            if !suffix.isEmpty { Text(suffix).font(.caption).foregroundStyle(.secondary).padding(.trailing, 6) }
            Button { value = min(range.upperBound, value + 1) } label: {
                Image(systemName: "plus").frame(width: 28, height: 32).contentShape(Rectangle())
            }
            .disabled(value >= range.upperBound)
            .accessibilityLabel(title + " +")
        }
        .buttonStyle(.plain).font(.system(size: 12))
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.09)))
        .fixedSize()
    }
}
