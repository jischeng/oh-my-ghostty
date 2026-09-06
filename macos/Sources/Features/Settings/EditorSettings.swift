import Foundation

enum EditorKeymapPreset: String, CaseIterable, Identifiable, Sendable {
    case idea
    case vscode

    var id: String { rawValue }

    var profile: EditorKeymap.Profile {
        switch self {
        case .idea: .idea
        case .vscode: .vscode
        }
    }
}

enum EditorBackgroundMode: String, CaseIterable, Identifiable, Sendable {
    case followTerminal
    case system

    var id: String { rawValue }
}

struct EditorSettings: Equatable, Sendable {
    let keymapPreset: EditorKeymapPreset
    let backgroundMode: EditorBackgroundMode
    let fontSize: Double
    let tabWidth: Int
    let wordWrap: Bool

    var keymapProfile: EditorKeymap.Profile {
        keymapPreset.profile
    }

    var keymap: EditorKeymap {
        EditorKeymap(profile: keymapProfile)
    }
}
