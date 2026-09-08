import AppKit
import GhosttyKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Initialize a pasteboard type from a MIME type string
    init?(mimeType: String) {
        // Explicit mappings for common MIME types
        switch mimeType {
        case "text/plain":
            self = .string
            return
        default:
            break
        }

        // Try to get UTType from MIME type
        guard let utType = UTType(mimeType: mimeType) else {
            // Fallback: use the MIME type directly as identifier
            self.init(mimeType)
            return
        }

        // Use the UTType's identifier
        self.init(utType.identifier)
    }
}

extension NSPasteboard {
    /// The pasteboard to used for Ghostty selection.
    static var ghosttySelection: NSPasteboard = {
        NSPasteboard(name: .init("com.jischeng.omg.selection"))
    }()

    /// Gets the contents of the pasteboard as a string following a specific set of semantics.
    /// Does these things in order:
    /// - Tries to get the absolute filesystem path of the file in the pasteboard if there is one and ensures the file path is properly escaped.
    /// - Tries to get any string from the pasteboard.
    /// If all of the above fail, returns None.
    func getOpinionatedStringContents() -> String? {
        let strings = (pasteboardItems ?? []).compactMap { item in
            if let plist = item.propertyList(forType: .fileURL),
               let fileURL = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL?,
               fileURL.isFileURL {
                return Ghostty.Shell.escape(fileURL.path)
            } else {
                return item.string(forType: .string)
            }
        }

        guard !strings.isEmpty else {
            return nil
        }
        return strings.joined(separator: " ")
    }

    /// Checks if a file URL points to an image file.
    static func isImageFileURL(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            return false
        }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty {
            if let utType = UTType(filenameExtension: ext), utType.conforms(to: .image) {
                return true
            }
            let commonExtensions: Set<String> = [
                "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif",
                "heic", "heif", "avif", "ico", "svg",
            ]
            if commonExtensions.contains(ext) {
                return true
            }
        }
        if let values = try? url.resourceValues(forKeys: [.contentTypeKey]),
           let contentType = values.contentType,
           contentType.conforms(to: .image) {
            return true
        }
        return false
    }

    /// Returns the local file URL if the pasteboard contains a single existing image file.
    func existingImageFileURL() -> URL? {
        if let items = pasteboardItems, items.count == 1,
           let item = items.first {
            var resolvedURL: URL?
            if let plist = item.propertyList(forType: .fileURL),
               let url = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) as URL? {
                resolvedURL = url
            } else if let str = item.string(forType: .fileURL),
                      let url = URL(string: str) {
                resolvedURL = url
            }
            if let resolvedURL,
               resolvedURL.isFileURL,
               Self.isImageFileURL(resolvedURL),
               FileManager.default.fileExists(atPath: resolvedURL.path) {
                return resolvedURL
            }
        }
        if let urls = readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], urls.count == 1,
           let fileURL = urls.first,
           fileURL.isFileURL,
           Self.isImageFileURL(fileURL),
           FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }

    /// Checks whether the pasteboard carries any file URLs.
    func hasFileURLs() -> Bool {
        if let items = pasteboardItems {
            for item in items {
                if item.types.contains(.fileURL) ||
                   item.propertyList(forType: .fileURL) != nil ||
                   item.string(forType: .fileURL) != nil {
                    return true
                }
            }
        }
        if let urls = readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL], !urls.isEmpty {
            return true
        }
        return false
    }

    /// If the pasteboard holds an image (either as an existing image file URL,
    /// or as image data on the clipboard), returns a file URL pointing to the image.
    /// For an existing image file on disk (such as copied from Lark/Feishu or Finder),
    /// its URL is returned directly. For raw clipboard image data, the image is
    /// written as PNG to a temporary directory. Returns nil if the pasteboard does not
    /// contain an image or if it contains non-image file URLs.
    func imagePasteURL(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-paste", isDirectory: true)
    ) -> URL? {
        if let existing = existingImageFileURL() {
            return existing
        }
        if hasFileURLs() {
            return nil
        }
        return imagePasteFile(directory: directory)
    }

    /// If the pasteboard holds an image but no text/file content, write the
    /// image as PNG into a dedicated temporary directory and return its URL.
    /// Returns nil when there is no usable image. Stored files are pruned after
    /// 7 days.
    func imagePasteFile(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-paste", isDirectory: true)
    ) -> URL? {
        guard let image = NSImage(pasteboard: self),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: directory.path) {
                let attributes = try fileManager.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    return nil
                }
            } else {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        } catch {
            return nil
        }

        Self.pruneOldImagePasteFiles(in: directory)

        let file = directory
            .appendingPathComponent("omg-paste-\(UUID().uuidString).png")
        guard fileManager.createFile(
            atPath: file.path,
            contents: png,
            attributes: [.posixPermissions: 0o600]
        ) else { return nil }
        do {
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: file.path
            )
        } catch {
            try? fileManager.removeItem(at: file)
            return nil
        }
        return file
    }

    /// Writes an image-only pasteboard item locally and returns the
    /// shell-escaped path used by local terminal sessions.
    func imagePastePath(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-paste", isDirectory: true)
    ) -> String? {
        imagePasteURL(directory: directory).map { Ghostty.Shell.escape($0.path) }
    }

    /// Removes image paste files older than the retention window.
    private static func pruneOldImagePasteFiles(in directory: URL) {
        let cutoff = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .contentModificationDateKey,
                .isRegularFileKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            guard entry.pathExtension == "png",
                  let values = try? entry.resourceValues(
                      forKeys: [.contentModificationDateKey, .isRegularFileKey]
                  ),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// The pasteboard for the Ghostty enum type.
    static func ghostty(_ clipboard: ghostty_clipboard_e) -> NSPasteboard? {
        switch clipboard {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return Self.general

        case GHOSTTY_CLIPBOARD_SELECTION:
            return Self.ghosttySelection

        default:
            return nil
        }
    }
}
