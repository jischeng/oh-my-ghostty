import AppKit
import SwiftUI

final class MarkdownImageCache {
    struct Entry {
        let image: NSImage
        let modificationDate: Date?
        let fileSize: UInt64?
    }

    static let shared = MarkdownImageCache()
    private let cache = NSCache<NSString, EntryBox>()

    final class EntryBox {
        let entry: Entry
        init(_ entry: Entry) { self.entry = entry }
    }

    func object(forKey key: String) -> Entry? {
        cache.object(forKey: key as NSString)?.entry
    }

    func setObject(_ entry: Entry, forKey key: String) {
        cache.setObject(EntryBox(entry), forKey: key as NSString)
    }

    func removeObject(forKey key: String) {
        cache.removeObject(forKey: key as NSString)
    }

    func removeAllObjects() {
        cache.removeAllObjects()
    }
}

enum MarkdownImageCacheHelper {
    static func cacheKey(
        path: String,
        isRemote: Bool,
        baseDirectory: URL,
        filesystem: (any WorkspaceFilesystem)?
    ) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPath: String
        let scopeID: String
        if isRemote {
            scopeID = filesystem?.descriptor.id ?? "remote"
            if trimmed.hasPrefix("/") {
                resolvedPath = trimmed
            } else {
                resolvedPath = baseDirectory.appendingPathComponent(trimmed).path
            }
        } else {
            scopeID = "local"
            if trimmed.hasPrefix("/") {
                resolvedPath = URL(fileURLWithPath: trimmed).path
            } else {
                resolvedPath = baseDirectory.appendingPathComponent(trimmed).path
            }
        }
        return "\(scopeID):\(resolvedPath)"
    }
}

private struct MarkdownImageView: View {
    let alt: String
    let path: String
    let isRemote: Bool
    let baseDirectory: URL
    let filesystem: (any WorkspaceFilesystem)?

    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var loadFailed = false

    private var isHttpUrl: Bool {
        path.hasPrefix("http://") || path.hasPrefix("https://")
    }

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            if isHttpUrl, let url = URL(string: path) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFit().cornerRadius(6)
                    case .failure:
                        failureView
                    case .empty:
                        ProgressView().controlSize(.small)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 420)
            } else if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .cornerRadius(6)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: 420)
            } else if isLoading {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, minHeight: 40)
            } else if loadFailed {
                failureView
            } else {
                Color.clear
                    .frame(height: 10)
                    .onAppear { loadImage() }
            }

            if !alt.isEmpty {
                Text(alt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var failureView: some View {
        Label(isRemote ? "Remote image unavailable: \(path)" : "Missing image: \(path)",
              systemImage: "photo.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func loadImage() {
        guard !isHttpUrl else { return }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = MarkdownImageCacheHelper.cacheKey(
            path: trimmed,
            isRemote: isRemote,
            baseDirectory: baseDirectory,
            filesystem: filesystem
        )

        if isRemote {
            guard let filesystem else {
                loadFailed = true
                return
            }
            let resolvedRemotePath: String
            if trimmed.hasPrefix("/") {
                resolvedRemotePath = trimmed
            } else {
                resolvedRemotePath = baseDirectory.appendingPathComponent(trimmed).path
            }

            if let cached = MarkdownImageCache.shared.object(forKey: cacheKey) {
                self.image = cached.image
                return
            }

            isLoading = true
            Task {
                do {
                    let data = try await filesystem.readFile(at: resolvedRemotePath)
                    if let loaded = NSImage(data: data) {
                        let entry = MarkdownImageCache.Entry(image: loaded, modificationDate: nil, fileSize: UInt64(data.count))
                        MarkdownImageCache.shared.setObject(entry, forKey: cacheKey)
                        await MainActor.run {
                            self.image = loaded
                            self.isLoading = false
                        }
                    } else {
                        await MainActor.run {
                            self.loadFailed = true
                            self.isLoading = false
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.loadFailed = true
                        self.isLoading = false
                    }
                }
            }
        } else {
            let resolvedURL: URL
            if trimmed.hasPrefix("/") {
                resolvedURL = URL(fileURLWithPath: trimmed)
            } else {
                resolvedURL = baseDirectory.appendingPathComponent(trimmed)
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: resolvedURL.path)
            let modDate = attributes?[.modificationDate] as? Date
            let size = (attributes?[.size] as? NSNumber)?.uint64Value

            if let cached = MarkdownImageCache.shared.object(forKey: cacheKey) {
                if cached.modificationDate == modDate && cached.fileSize == size {
                    self.image = cached.image
                    return
                }
            }

            isLoading = true
            Task.detached(priority: .utility) {
                if let loaded = NSImage(contentsOf: resolvedURL) {
                    let entry = MarkdownImageCache.Entry(image: loaded, modificationDate: modDate, fileSize: size)
                    MarkdownImageCache.shared.setObject(entry, forKey: cacheKey)
                    await MainActor.run {
                        self.image = loaded
                        self.isLoading = false
                    }
                } else {
                    await MainActor.run {
                        self.loadFailed = true
                        self.isLoading = false
                    }
                }
            }
        }
    }
}

/// A rich Typora-style Markdown preview renderer with local and remote image support.
struct MarkdownPreviewView: View {
    let text: String
    let fileURL: URL?
    var isRemote: Bool = false
    var filesystem: (any WorkspaceFilesystem)?
    let terminalBackground: NSColor
    let terminalBackgroundOpacity: Double
    let foregroundColor: NSColor

    @State private var blocks: [MarkdownBlock] = []
    @State private var parseTask: Task<Void, Never>?

    private var baseDirectory: URL {
        fileURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    render(block: block)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.clear)
        .onAppear {
            scheduleParsing()
        }
        .onChange(of: text) { _ in
            scheduleParsing()
        }
        .onDisappear {
            parseTask?.cancel()
        }
    }

    private func scheduleParsing() {
        parseTask?.cancel()
        let currentText = text
        parseTask = Task.detached(priority: .userInitiated) {
            let parsed = Self.parseBlocks(from: currentText)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.blocks = parsed
            }
        }
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
            MarkdownImageView(
                alt: alt,
                path: path,
                isRemote: isRemote,
                baseDirectory: baseDirectory,
                filesystem: filesystem
            )

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

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: .system(size: 26, weight: .bold)
        case 2: .system(size: 20, weight: .bold)
        case 3: .system(size: 16, weight: .semibold)
        case 4: .system(size: 14, weight: .semibold)
        default: .system(size: 13, weight: .bold)
        }
    }

    private enum MarkdownBlock: Sendable {
        case heading(level: Int, text: String)
        case image(alt: String, path: String)
        case codeBlock(lang: String, code: String)
        case quote(text: String)
        case listItem(text: String)
        case divider
        case paragraph(text: String)
    }

    private static func parseBlocks(from text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = text.components(separatedBy: .newlines)
        var i = 0
        while i < lines.count {
            if Task.isCancelled { return [] }
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
                    if Task.isCancelled { return [] }
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
