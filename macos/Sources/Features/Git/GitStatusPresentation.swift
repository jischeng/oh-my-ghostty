import AppKit

extension GitDiffChangeKind {
    var color: NSColor {
        switch self {
        case .added: .systemGreen
        case .modified: .systemOrange
        case .deleted, .unmerged: .systemRed
        case .renamed: .systemBlue
        case .copied: .systemTeal
        case .typeChanged: .systemPurple
        case .unknown: .secondaryLabelColor
        }
    }
}
