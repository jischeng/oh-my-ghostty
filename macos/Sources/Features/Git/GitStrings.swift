import Foundation

struct GitStrings: Equatable, Sendable {
    private static let placeholders = try? NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
    let languageCode: String
    init(language: OhMyGhosttyLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        languageCode = SettingsStrings(language: language, preferredLanguages: preferredLanguages).languageCode
    }
    func text(_ key: String) -> String { Self.catalog[key]?[languageCode] ?? Self.catalog[key]?["en"] ?? key }
    func format(_ key: String, _ values: [String]) -> String {
        let template = text(key)
        guard let pattern = Self.placeholders else { return template }
        let result = NSMutableString(string: template)
        for match in pattern.matches(in: template, range: NSRange(location: 0, length: (template as NSString).length)).reversed() {
            guard let index = Int((template as NSString).substring(with: match.range(at: 1))), values.indices.contains(index) else { continue }
            result.replaceCharacters(in: match.range, with: values[index])
        }
        return result as String
    }
    static let catalog: [String: [String: String]] = {
        guard let url = Bundle(for: GitStringResources.self).url(forResource: "GitStrings", withExtension: "json") ?? Bundle.main.url(forResource: "GitStrings", withExtension: "json"),
              let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return values
    }()
}
private final class GitStringResources: NSObject {}

/// Services can produce localized app errors off the main actor. Git output
/// and user data never pass through this lookup.
enum GitL10n {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var strings = GitStrings()
    }
    private static let storage = Storage()
    static var current: GitStrings {
        storage.lock.lock(); defer { storage.lock.unlock() }
        return storage.strings
    }
    static func configure(language: OhMyGhosttyLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        storage.lock.lock(); defer { storage.lock.unlock() }
        storage.strings = GitStrings(language: language, preferredLanguages: preferredLanguages)
    }
    static func text(_ key: String) -> String { current.text(key) }
    static func format(_ key: String, _ values: String...) -> String { current.format(key, values) }
}
