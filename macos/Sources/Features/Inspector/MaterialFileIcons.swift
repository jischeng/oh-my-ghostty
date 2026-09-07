import AppKit

/// Official Material Icon Theme associations, shared by local and SSH file trees.
/// Resolve exact filenames before longest compound extensions (e.g. `d.ts`).
enum MaterialFileIcons {
    private struct Associations: Decodable {
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let folderNames: [String: String]
        let folderNamesExpanded: [String: String]
    }

    private struct Manifest: Decodable {
        let fileNames: [String: String]
        let fileExtensions: [String: String]
        let folderNames: [String: String]
        let folderNamesExpanded: [String: String]
        let light: Associations
        let file: String
        let folder: String
        let folderExpanded: String
    }

    private static let manifest: Manifest? = {
        guard let data = NSDataAsset(name: "material-icon-associations")?.data else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }()

    static func assetName(
        for filename: String,
        isDirectory: Bool,
        isExpanded: Bool = false,
        isLight: Bool = false
    ) -> String? {
        guard let manifest else { return nil }
        let name = filename.lowercased()
        let icon: String
        if isDirectory {
            let names = isExpanded ? manifest.folderNamesExpanded : manifest.folderNames
            let lightNames = isExpanded ? manifest.light.folderNamesExpanded : manifest.light.folderNames
            icon = (isLight ? lightNames[name] : nil) ?? names[name]
                ?? (isExpanded ? manifest.folderExpanded : manifest.folder)
        } else if let match = (isLight ? manifest.light.fileNames[name] : nil) ?? manifest.fileNames[name] {
            icon = match
        } else {
            var suffix = name[...]
            var match: String?
            while let dot = suffix.firstIndex(of: ".") {
                suffix = suffix[suffix.index(after: dot)...]
                let key = String(suffix)
                if let candidate = (isLight ? manifest.light.fileExtensions[key] : nil)
                    ?? manifest.fileExtensions[key] {
                    match = candidate
                    break
                }
            }
            icon = match ?? manifest.file
        }
        return "material-" + icon
    }
}
