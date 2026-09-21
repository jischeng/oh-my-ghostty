import Foundation

struct GitForge: Equatable, Sendable {
    enum Kind: Sendable { case github, gitlab }
    let base: URL
    let kind: Kind

    init?(origin: String?) {
        guard var value = origin?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if !value.contains("://"), let colon = value.firstIndex(of: ":") {
            let host = value[..<colon].split(separator: "@").last.map(String.init) ?? ""
            value = "https://" + host + "/" + value[value.index(after: colon)...]
        }
        guard var components = URLComponents(string: value), let host = components.host,
              !host.isEmpty, ["http", "https", "ssh", "git"].contains(components.scheme ?? "") else { return nil }
        if components.scheme == "ssh" || components.scheme == "git" { components.scheme = "https"; components.port = nil }
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        if components.path.hasSuffix(".git") { components.path = String(components.path.dropLast(4)) }
        guard components.path.split(separator: "/").count >= 2, let url = components.url else { return nil }
        base = url
        // GitLab is commonly self-hosted under arbitrary enterprise domain names.
        kind = host.lowercased().contains("github") ? .github : .gitlab
    }

    func commit(_ id: String, file: GitDiffFile? = nil, parent: String? = nil) -> URL? {
        guard id.count >= 7, id.allSatisfy(\.isHexDigit) else { return nil }
        var url = base
        if kind == .gitlab { url.appendPathComponent("-") }
        if let file {
            url.appendPathComponent("blob")
            // Deleted files exist in the first parent, not the selected commit.
            if file.kind == .deleted {
                guard let parent, parent.count >= 7, parent.allSatisfy(\.isHexDigit) else { return nil }
                url.appendPathComponent(parent)
            } else { url.appendPathComponent(id) }
            for component in file.path.split(separator: "/") { url.appendPathComponent(String(component)) }
        } else {
            url.appendPathComponent("commit")
            url.appendPathComponent(id)
        }
        return url
    }
}
