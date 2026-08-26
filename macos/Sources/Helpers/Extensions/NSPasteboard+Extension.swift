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

    /// If the pasteboard holds an image but no text/file content, write the
    /// image as PNG into a dedicated temporary directory and return the
    /// shell-escaped absolute path so agents can consume it as a file. Returns
    /// nil when there is no usable image. Stored files are pruned after 7 days.
    func imagePastePath() -> String? {
        guard let image = NSImage(pasteboard: self),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return nil
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("omg-paste", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        Self.pruneOldImagePasteFiles(in: directory)

        let file = directory
            .appendingPathComponent("omg-paste-\(UUID().uuidString).png")
        do {
            try png.write(to: file, options: .atomic)
        } catch {
            return nil
        }
        return Ghostty.Shell.escape(file.path)
    }

    /// Removes image paste files older than the retention window.
    private static func pruneOldImagePasteFiles(in directory: URL) {
        let cutoff = Date(timeIntervalSinceNow: -7 * 24 * 60 * 60)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for entry in entries {
            guard entry.pathExtension == "png",
                  let values = try? entry.resourceValues(
                      forKeys: [.contentModificationDateKey]
                  ),
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
