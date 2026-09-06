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
            background: color("#282c34", fallback: .black),
            lineHighlight: color("#2c313a", fallback: .controlAccentColor.withAlphaComponent(0.08)),
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
            background: color("#fafafa", fallback: .white),
            lineHighlight: color("#f2f2f2", fallback: .controlAccentColor.withAlphaComponent(0.08)),
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
            background: color("#282a36", fallback: .black),
            lineHighlight: color("#44475a", fallback: .controlAccentColor.withAlphaComponent(0.08)),
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
            background: color("#0d1117", fallback: .black),
            lineHighlight: color("#161b22", fallback: .controlAccentColor.withAlphaComponent(0.08)),
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
