import AppKit
import SwiftUI

/// A rich Typora-style Markdown preview renderer with local and remote image support.
struct MarkdownPreviewView: View {
    let text: String
    let fileURL: URL?
    let terminalBackground: NSColor
    let terminalBackgroundOpacity: Double
    let foregroundColor: NSColor

    private var baseDirectory: URL {
        fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(parseBlocks().enumerated()), id: \.offset) { _, block in
                    render(block: block)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
    }

    @ViewBuilder
    private func render(block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            VStack(alignment: .leading, spacing: 6) {
                Text(content)
                    .font(headingFont(level: level))
                    .fontWeight(.bold)
                    .foregroundStyle(Color(nsColor: foregroundColor))
                if level <= 2 {
                    Divider()
                }
            }
            .padding(.top, level == 1 ? 8 : 4)

        case .image(let alt, let path):
            VStack(alignment: .center, spacing: 4) {
                if let image = loadImage(path: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(6)
                        .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        .frame(maxWidth: .infinity, maxHeight: 420)
                } else if let url = URL(string: path), url.scheme == "http" || url.scheme == "https" {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit().cornerRadius(6)
                        case .failure:
                            Label("Failed to load image: \(alt)", systemImage: "photo.badge.exclamationmark")
                                .foregroundStyle(.secondary)
                        case .empty:
                            ProgressView().controlSize(.small)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: 420)
                } else {
                    Label("Missing image: \(path)", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !alt.isEmpty {
                    Text(alt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)

        case .codeBlock(let lang, let code):
            VStack(alignment: .leading, spacing: 4) {
                if !lang.isEmpty {
                    Text(lang)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(Color(nsColor: foregroundColor))
                        .padding(10)
                        .textSelection(.enabled)
                }
            }
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 1))

        case .quote(let quote):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4)
                Text(LocalizedStringKey(quote))
                    .font(.body)
                    .italic()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

        case .listItem(let item):
            HStack(alignment: .top, spacing: 8) {
                Text("•")
                    .fontWeight(.bold)
                    .foregroundStyle(Color.accentColor)
                Text(LocalizedStringKey(item))
                    .foregroundStyle(Color(nsColor: foregroundColor))
            }

        case .divider:
            Divider().padding(.vertical, 8)

        case .paragraph(let text):
            Text(LocalizedStringKey(text))
                .font(.body)
                .foregroundStyle(Color(nsColor: foregroundColor))
                .lineSpacing(4)
                .textSelection(.enabled)
        }
    }

    private func loadImage(path: String) -> NSImage? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return NSImage(contentsOfFile: trimmed)
        }
        let resolved = baseDirectory.appendingPathComponent(trimmed)
        if let img = NSImage(contentsOf: resolved) {
            return img
        }
        return NSImage(contentsOfFile: trimmed)
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .system(size: 26, weight: .bold)
        case 2: .system(size: 20, weight: .bold)
        case 3: .system(size: 16, weight: .semibold)
        case 4: .system(size: 14, weight: .semibold)
        default: .system(size: 13, weight: .bold)
        }
    }

    private enum MarkdownBlock {
        case heading(level: Int, text: String)
        case image(alt: String, path: String)
        case codeBlock(lang: String, code: String)
        case quote(text: String)
        case listItem(text: String)
        case divider
        case paragraph(text: String)
    }

    private func parseBlocks() -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                i += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let fenceLine = lines[i]
                    if fenceLine.trimmingCharacters(in: .whitespaces).hasPrefix("```")
                        || fenceLine.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                        i += 1
                        break
                    }
                    codeLines.append(fenceLine)
                    i += 1
                }
                blocks.append(.codeBlock(lang: lang, code: codeLines.joined(separator: "\n")))
                continue
            }

            if trimmed.hasPrefix("#") {
                let hashes = trimmed.prefix(while: { $0 == "#" })
                if hashes.count <= 6 && trimmed.dropFirst(hashes.count).hasPrefix(" ") {
                    let content = String(trimmed.dropFirst(hashes.count + 1)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: hashes.count, text: content))
                    i += 1
                    continue
                }
            }

            // Image: ![alt](path)
            if trimmed.hasPrefix("![") && trimmed.contains("](") && trimmed.hasSuffix(")") {
                if let altEnd = trimmed.firstIndex(of: "]"),
                   let urlStart = trimmed.range(of: "](")?.upperBound,
                   let urlEnd = trimmed.lastIndex(of: ")") {
                    let alt = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)..<altEnd])
                    let path = String(trimmed[urlStart..<urlEnd])
                    blocks.append(.image(alt: alt, path: path))
                    i += 1
                    continue
                }
            }

            if trimmed.hasPrefix(">") {
                let quote = String(trimmed.dropFirst(1)).trimmingCharacters(in: .whitespaces)
                blocks.append(.quote(text: quote))
                i += 1
                continue
            }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                blocks.append(.listItem(text: String(trimmed.dropFirst(2))))
                i += 1
                continue
            }

            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.divider)
                i += 1
                continue
            }

            blocks.append(.paragraph(text: line))
            i += 1
        }
        return blocks
    }
}
