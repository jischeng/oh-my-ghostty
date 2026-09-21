import Foundation

/// Suggests the next minor tag from a branch's tag history and validates names.
enum GitTagService {
    static func validate(_ name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == name, !name.isEmpty, name.utf8.count <= 200, !name.contains("\0"),
              !name.contains(".."), !name.contains(" "), !name.contains("~"), !name.contains("^"),
              !name.contains(":"), !name.contains("?"), !name.contains("*"), !name.contains("["),
              !name.hasPrefix("-"), !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.hasSuffix("."), !name.hasSuffix(".lock"), !name.contains("//"),
              !name.contains("@{"), !name.contains("\\"), name.unicodeScalars.allSatisfy({ $0 != "@" }) else {
            throw GitDiffServiceError.gitFailed(GitL10n.text("Invalid tag name."))
        }
    }

    /// Parse v?X.Y(.Z|-suffix) tags and bump the minor version, resetting patch.
    /// e.g. v1.6.124 → v1.7.0, 1.6 → 1.7.0. Returns nil when no version tag exists.
    private struct VersionTag { let prefix: String; let major: Int; let minor: Int; let patch: Int }

    static func suggestNextMinor(tags: [String]) -> String? {
        var best: VersionTag?
        for tag in tags {
            let match = tag.firstMatch(of: /^(v?)(\d+)\.(\d+)(?:\.(\d+))?/)
            guard let match else { continue }
            let prefix = String(match.1)
            guard let major = Int(match.2), let minor = Int(match.3) else { continue }
            let patch = match.4.flatMap { Int($0) } ?? 0
            let candidate = VersionTag(prefix: prefix, major: major, minor: minor, patch: patch)
            if best == nil || (major, minor, patch) > (best!.major, best!.minor, best!.patch) { best = candidate }
        }
        guard let best else { return nil }
        return "\(best.prefix)\(best.major).\(best.minor + 1).0"
    }
}
