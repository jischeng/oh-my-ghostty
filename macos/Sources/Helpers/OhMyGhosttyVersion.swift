import Foundation

struct OhMyGhosttyVersion: Equatable {
    static let repositoryURL = URL(string: "https://github.com/jischeng/oh-my-ghostty")
    static let upstreamURL = URL(string: "https://github.com/ghostty-org/ghostty")
    static let updateFeedURL = URL(
        string: "https://github.com/jischeng/oh-my-ghostty/releases/latest/download/appcast.xml"
    )

    let omg: String
    let ghostty: String
    let ghosttyRevision: String

    init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        self.omg = Self.string(
            "OMGVersion",
            fallback: "CFBundleShortVersionString",
            in: infoDictionary
        )
        self.ghostty = Self.string("GhosttyBaseVersion", in: infoDictionary)
        self.ghosttyRevision = Self.string("GhosttyBaseRevision", in: infoDictionary)
    }

    var releaseTag: String? {
        guard omg.range(
            of: #"^\d+\.\d+\.\d+$"#,
            options: .regularExpression
        ) != nil else { return nil }
        return "v\(omg)"
    }

    private static func string(
        _ key: String,
        fallback: String? = nil,
        in infoDictionary: [String: Any]
    ) -> String {
        if let value = infoDictionary[key] as? String, !value.isEmpty {
            return value
        }
        if let fallback,
           let value = infoDictionary[fallback] as? String,
           !value.isEmpty {
            return value
        }
        return "unknown"
    }
}
