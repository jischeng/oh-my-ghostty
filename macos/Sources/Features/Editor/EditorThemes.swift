import AppKit
import CodeEditSourceEditor

extension EditorTheme {
    private static func color(_ hex: String, fallback: NSColor) -> NSColor {
        NSColor(hex: hex) ?? fallback
    }

    /// The iconic Atom One Dark syntax highlighting theme.
    static var oneDark: EditorTheme {
        EditorTheme(
            text: color("#abb2bf", fallback: .textColor),
            insertionPoint: color("#528bff", fallback: .controlAccentColor),
            invisibles: color("#4b5263", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#528bff", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#3e4451", fallback: .selectedTextBackgroundColor),
            keywords: color("#c678dd", fallback: .systemPurple),
            commands: color("#61afef", fallback: .systemBlue),
            types: color("#e5c07b", fallback: .systemYellow),
            attributes: color("#d19a66", fallback: .systemOrange),
            variables: color("#e06c75", fallback: .systemRed),
            values: color("#d19a66", fallback: .systemOrange),
            numbers: color("#d19a66", fallback: .systemOrange),
            strings: color("#98c379", fallback: .systemGreen),
            characters: color("#98c379", fallback: .systemGreen),
            comments: color("#5c6370", fallback: .secondaryLabelColor)
        )
    }

    /// Atom One Light theme.
    static var oneLight: EditorTheme {
        EditorTheme(
            text: color("#383a42", fallback: .textColor),
            insertionPoint: color("#526fff", fallback: .controlAccentColor),
            invisibles: color("#a0a1a7", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#4078f2", fallback: .controlAccentColor).withAlphaComponent(0.06),
            selection: color("#e5e5e6", fallback: .selectedTextBackgroundColor),
            keywords: color("#a626a4", fallback: .systemPurple),
            commands: color("#4078f2", fallback: .systemBlue),
            types: color("#c18401", fallback: .systemYellow),
            attributes: color("#986801", fallback: .systemOrange),
            variables: color("#e45649", fallback: .systemRed),
            values: color("#986801", fallback: .systemOrange),
            numbers: color("#986801", fallback: .systemOrange),
            strings: color("#50a14f", fallback: .systemGreen),
            characters: color("#50a14f", fallback: .systemGreen),
            comments: color("#a0a1a7", fallback: .secondaryLabelColor)
        )
    }

    /// Dracula syntax theme.
    static var dracula: EditorTheme {
        EditorTheme(
            text: color("#f8f8f2", fallback: .textColor),
            insertionPoint: color("#f8f8f0", fallback: .white),
            invisibles: color("#6272a4", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#bd93f9", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#44475a", fallback: .selectedTextBackgroundColor),
            keywords: color("#ff79c6", fallback: .systemPink),
            commands: color("#8be9fd", fallback: .systemCyan),
            types: color("#8be9fd", fallback: .systemCyan),
            attributes: color("#50fa7b", fallback: .systemGreen),
            variables: color("#50fa7b", fallback: .systemGreen),
            values: color("#bd93f9", fallback: .systemPurple),
            numbers: color("#bd93f9", fallback: .systemPurple),
            strings: color("#f1fa8c", fallback: .systemYellow),
            characters: color("#f1fa8c", fallback: .systemYellow),
            comments: color("#6272a4", fallback: .secondaryLabelColor)
        )
    }

    /// GitHub Dark syntax theme.
    static var githubDark: EditorTheme {
        EditorTheme(
            text: color("#c9d1d9", fallback: .textColor),
            insertionPoint: color("#58a6ff", fallback: .controlAccentColor),
            invisibles: color("#484f58", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#58a6ff", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#388bfd", fallback: .selectedTextBackgroundColor).withAlphaComponent(0.4),
            keywords: color("#ff7b72", fallback: .systemRed),
            commands: color("#79c0ff", fallback: .systemBlue),
            types: color("#ffa657", fallback: .systemOrange),
            attributes: color("#d2a8ff", fallback: .systemPurple),
            variables: color("#d2a8ff", fallback: .systemPurple),
            values: color("#79c0ff", fallback: .systemBlue),
            numbers: color("#79c0ff", fallback: .systemBlue),
            strings: color("#a5d6ff", fallback: .systemCyan),
            characters: color("#a5d6ff", fallback: .systemCyan),
            comments: color("#8b949e", fallback: .secondaryLabelColor)
        )
    }

    /// Nord syntax theme.
    static var nord: EditorTheme {
        EditorTheme(
            text: color("#d8dee9", fallback: .textColor),
            insertionPoint: color("#88c0d0", fallback: .controlAccentColor),
            invisibles: color("#4c566a", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#88c0d0", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#434c5e", fallback: .selectedTextBackgroundColor),
            keywords: color("#81a1c1", fallback: .systemPurple),
            commands: color("#88c0d0", fallback: .systemBlue),
            types: color("#8fbcbb", fallback: .systemTeal),
            attributes: color("#d08770", fallback: .systemOrange),
            variables: color("#bf616a", fallback: .systemRed),
            values: color("#ebcb8b", fallback: .systemYellow),
            numbers: color("#b48ead", fallback: .systemPurple),
            strings: color("#a3be8c", fallback: .systemGreen),
            characters: color("#a3be8c", fallback: .systemGreen),
            comments: color("#4c566a", fallback: .secondaryLabelColor)
        )
    }

    /// Monokai syntax theme.
    static var monokai: EditorTheme {
        EditorTheme(
            text: color("#f8f8f2", fallback: .textColor),
            insertionPoint: color("#f8f8f0", fallback: .white),
            invisibles: color("#75715e", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#fd971f", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#49483e", fallback: .selectedTextBackgroundColor),
            keywords: color("#f92672", fallback: .systemPink),
            commands: color("#66d9ef", fallback: .systemCyan),
            types: color("#66d9ef", fallback: .systemCyan),
            attributes: color("#a6e22e", fallback: .systemGreen),
            variables: color("#fd971f", fallback: .systemOrange),
            values: color("#ae81ff", fallback: .systemPurple),
            numbers: color("#ae81ff", fallback: .systemPurple),
            strings: color("#e6db74", fallback: .systemYellow),
            characters: color("#e6db74", fallback: .systemYellow),
            comments: color("#75715e", fallback: .secondaryLabelColor)
        )
    }

    /// Catppuccin Mocha syntax theme.
    static var catppuccinMocha: EditorTheme {
        EditorTheme(
            text: color("#cdd6f4", fallback: .textColor),
            insertionPoint: color("#f5e0dc", fallback: .controlAccentColor),
            invisibles: color("#585b70", fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: color("#89b4fa", fallback: .controlAccentColor).withAlphaComponent(0.08),
            selection: color("#45475a", fallback: .selectedTextBackgroundColor),
            keywords: color("#cba6f7", fallback: .systemPurple),
            commands: color("#89b4fa", fallback: .systemBlue),
            types: color("#f9e2af", fallback: .systemYellow),
            attributes: color("#fab387", fallback: .systemOrange),
            variables: color("#f38ba8", fallback: .systemRed),
            values: color("#fab387", fallback: .systemOrange),
            numbers: color("#fab387", fallback: .systemOrange),
            strings: color("#a6e3a1", fallback: .systemGreen),
            characters: color("#a6e3a1", fallback: .systemGreen),
            comments: color("#6c7086", fallback: .secondaryLabelColor)
        )
    }

    /// Adaptive theme derived from terminal colors.
    static func adaptive(background: NSColor, foreground: NSColor) -> EditorTheme {
        EditorTheme(
            text: foreground,
            insertionPoint: foreground,
            invisibles: .tertiaryLabelColor,
            background: background,
            lineHighlight: .controlAccentColor.withAlphaComponent(0.08),
            selection: .selectedTextBackgroundColor,
            keywords: .systemPurple,
            commands: .systemBlue,
            types: .systemMint,
            attributes: .systemOrange,
            variables: .systemTeal,
            values: .systemIndigo,
            numbers: .systemOrange,
            strings: .systemGreen,
            characters: .systemGreen,
            comments: .secondaryLabelColor
        )
    }
}

/// JSON-serializable theme definition compatible with CodeEdit / TextMate themes.
public struct EditorThemeDefinition: Codable, Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let text: String?
    public let insertionPoint: String?
    public let invisibles: String?
    public let lineHighlight: String?
    public let selection: String?
    public let keywords: String?
    public let commands: String?
    public let types: String?
    public let attributes: String?
    public let variables: String?
    public let values: String?
    public let numbers: String?
    public let strings: String?
    public let characters: String?
    public let comments: String?

    public func toEditorTheme() -> EditorTheme {
        func parse(_ hex: String?, fallback: NSColor) -> NSColor {
            guard let hex else { return fallback }
            return NSColor(hex: hex) ?? fallback
        }

        return EditorTheme(
            text: parse(text, fallback: .textColor),
            insertionPoint: parse(insertionPoint, fallback: .controlAccentColor),
            invisibles: parse(invisibles, fallback: .tertiaryLabelColor),
            background: .clear,
            lineHighlight: parse(lineHighlight, fallback: .controlAccentColor.withAlphaComponent(0.08)),
            selection: parse(selection, fallback: .selectedTextBackgroundColor),
            keywords: parse(keywords, fallback: .systemPurple),
            commands: parse(commands, fallback: .systemBlue),
            types: parse(types, fallback: .systemYellow),
            attributes: parse(attributes, fallback: .systemOrange),
            variables: parse(variables, fallback: .systemRed),
            values: parse(values, fallback: .systemOrange),
            numbers: parse(numbers, fallback: .systemOrange),
            strings: parse(strings, fallback: .systemGreen),
            characters: parse(characters, fallback: .systemGreen),
            comments: parse(comments, fallback: .secondaryLabelColor)
        )
    }
}

/// Manager for discovering and loading user themes from `~/.config/ghostty/editor-themes/`.
@MainActor
public final class EditorThemeManager: ObservableObject {
    public static let shared = EditorThemeManager()

    @Published public private(set) var customThemes: [String: EditorTheme] = [:]

    private init() {
        reloadCustomThemes()
    }

    public func reloadCustomThemes() {
        let home = NSHomeDirectory()
        let configURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".config/ghostty/editor-themes")
        let appSupportURL = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/com.jischeng.omg/editor-themes")

        var loaded: [String: EditorTheme] = [:]
        for dir in [configURL, appSupportURL] {
            guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                continue
            }
            for file in files where file.pathExtension.lowercased() == "json" {
                if let data = try? Data(contentsOf: file),
                   let def = try? JSONDecoder().decode(EditorThemeDefinition.self, from: data) {
                    loaded[def.name] = def.toEditorTheme()
                }
            }
        }
        self.customThemes = loaded
    }
}
