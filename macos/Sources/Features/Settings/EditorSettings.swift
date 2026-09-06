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

enum EditorSyntaxTheme: String, CaseIterable, Identifiable, Sendable {
    case oneDark
    case oneLight
    case dracula
    case githubDark
    case followTerminal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneDark: "Atom One Dark"
        case .oneLight: "Atom One Light"
        case .dracula: "Dracula"
        case .githubDark: "GitHub Dark"
        case .followTerminal: "Adaptive (Follow Terminal)"
        }
    }
}

enum EditorFontFamily: String, CaseIterable, Identifiable, Sendable {
    case jetbrainsMono
    case sfMono
    case menlo
    case firaCode
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .jetbrainsMono: "JetBrains Mono"
        case .sfMono: "SF Mono"
        case .menlo: "Menlo"
        case .firaCode: "Fira Code"
        case .system: "System Monospaced"
        }
    }
}

struct EditorSettings: Equatable, Sendable {
    let keymapPreset: EditorKeymapPreset
    let backgroundMode: EditorBackgroundMode
    let syntaxTheme: EditorSyntaxTheme
    let fontFamily: EditorFontFamily
    let fontSize: Double
    let tabWidth: Int
    let wordWrap: Bool

    var keymapProfile: EditorKeymap.Profile {
        keymapPreset.profile
    }

    var keymap: EditorKeymap {
        switch keymapProfile {
        case .idea: .idea
        case .vscode: .vscode
        }
    }
}
