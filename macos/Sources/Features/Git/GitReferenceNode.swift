import Foundation

/// Folder paths are presentation only; leaves retain the exact original ref.
final class GitReferenceNode: NSObject {
    let title: String
    let kind: GitRefDecorationKind
    let isSection: Bool
    var ref: GitRefDecoration?
    var children: [GitReferenceNode] = []
    init(title: String, kind: GitRefDecorationKind, isSection: Bool = false, ref: GitRefDecoration? = nil) {
        self.title = title
        self.kind = kind
        self.isSection = isSection
        self.ref = ref
    }
    static func build(_ refs: [GitRefDecoration]) -> [GitReferenceNode] {
        let branches = GitReferenceNode(title: "Branches", kind: .localBranch, isSection: true)
        let remotes = GitReferenceNode(title: "Remote Branches", kind: .remoteBranch, isSection: true)
        let tags = GitReferenceNode(title: "Tags", kind: .tag, isSection: true)
        var heads: [GitReferenceNode] = []
        for ref in GitRefDecoration.orderedForDisplay(refs) {
            switch ref.kind {
            case .head:
                heads.append(.init(title: "HEAD", kind: .head, isSection: true, ref: ref))
            case .tag:
                tags.children.append(.init(title: ref.name, kind: .tag, ref: ref))
            case .localBranch, .currentBranch, .remoteBranch:
                var parent = ref.kind == .remoteBranch ? remotes : branches
                let components = ref.name.split(separator: "/").map(String.init)
                for (index, component) in components.enumerated() {
                    let node = parent.children.first { $0.title == component } ?? {
                        let node = GitReferenceNode(title: component, kind: parent.kind)
                        parent.children.append(node)
                        return node
                    }()
                    if index == components.count - 1 { node.ref = ref }
                    parent = node
                }
            }
        }
        return heads + [branches, remotes, tags].filter { !$0.children.isEmpty }
    }
}
