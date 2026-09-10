import Foundation

enum GitCollectionMode: String, CaseIterable {
    case list, tree
    var symbol: String { self == .list ? "list.bullet" : "list.bullet.indent" }
    var title: String { self == .list ? "List" : "Tree" }
}

enum GitChangeSection: String, Equatable, Sendable {
    case staged, unstaged
    var target: GitDiffTarget { self == .staged ? .staged : .unstaged }
    var title: String { self == .staged ? "Staged" : "Unstaged / Untracked" }
    func rowID(path: String) -> String { "changes/\(rawValue)/file/\(path)" }
}

enum GitCollectionSource: Equatable {
    case changes(staged: [GitDiffFile], unstaged: [GitDiffFile], stagedError: String?, unstagedError: String?)
    case refs(branches: [GitBranchInfo], worktrees: [GitWorktreeInfo], scopes: Bool, branchesError: String?, worktreesError: String?)

    static func changes(_ tree: GitWorkingTreeContent) -> Self {
        .changes(staged: tree.staged, unstaged: tree.unstaged, stagedError: tree.stagedError, unstagedError: tree.unstagedError)
    }
}

struct GitCollectionItem: Equatable {
    enum Kind: Equatable {
        case category(Int)
        case folder(Int)
        case file(GitDiffFile, GitChangeSection)
        case branch(GitBranchInfo, worktrees: [String])
        case worktree(GitWorktreeInfo)
        case scope(GitHistoryScope)
        case notice(error: Bool)
    }
    let id: String
    var title: String
    var subtitle: String?
    let kind: Kind
    var enabled = true
    var pending = false

    var isFolder: Bool { if case .folder = kind { return true }; return false }
    var isCategory: Bool { if case .category = kind { return true }; return false }
    var isSelectable: Bool { !isCategory && { if case .notice = kind { return false }; return true }() }
    var tooltip: String {
        switch kind {
        case .file(let file, _): return (file.isUntracked ? "Untracked" : file.kind.label) + " · " + file.displayPath
        case .branch(let branch, let paths):
            return ([branch.name, branch.upstream + " " + branch.tracking] + paths.map { "Worktree: " + $0 })
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .worktree(let worktree):
            return [worktree.branchName, worktree.path, worktree.isDirty == true ? "Dirty" : nil,
                    worktree.lockedReason, worktree.prunableReason, worktree.statusError].compactMap { $0 }.joined(separator: "\n")
        default: return [title, subtitle].compactMap { $0 }.joined(separator: "\n")
        }
    }
}

final class GitCollectionNode {
    var item: GitCollectionItem
    var children: [GitCollectionNode]
    init(_ item: GitCollectionItem, children: [GitCollectionNode] = []) {
        self.item = item; self.children = children
    }
}

struct GitCollectionRow: Equatable {
    let item: GitCollectionItem
    let depth: Int
    var expanded = false
    var id: String { item.id }
    var height: CGFloat {
        switch item.kind {
        case .category: 30
        case .file: item.subtitle == nil ? 26 : 38
        case .worktree: 40
        default: 26
        }
    }
}

/// Presentation state is independent of Git status and survives tab/mode changes.
final class GitCollectionState {
    var collapsed: [String: Set<String>] = [:]
    var selected: [String: String] = [:]
    var scrollAnchors: [String: (id: String, offset: CGFloat)] = [:]
}

enum GitCollectionBuilder {
    static func nodes(source: GitCollectionSource, mode: GitCollectionMode, query: String = "",
                      pending: Set<String> = [], canWrite: Bool = true) -> [GitCollectionNode] {
        switch source {
        case .changes(let staged, let unstaged, let stagedError, let unstagedError):
            return [(GitChangeSection.staged, staged, stagedError), (.unstaged, unstaged, unstagedError)].map { section, files, error in
                let key = "changes/" + section.rawValue
                let entries = files.filter { matches(query, text: $0.displayPath) }.map { file in
                    let folder = (file.path as NSString).deletingLastPathComponent
                    return (file.path, GitCollectionItem(id: section.rowID(path: file.path),
                        title: (file.path as NSString).lastPathComponent,
                        subtitle: mode == .list ? folder : nil,
                        kind: .file(file, section), enabled: canWrite && error == nil && !pending.contains(file.path),
                        pending: pending.contains(file.path)))
                }
                let children = grouped(entries, category: key, mode: mode)
                return category(key, title: section.title, count: files.count, children: children, error: error,
                                empty: query.isEmpty ? "No changes" : "No matching files")
            }
        case .refs(let branches, let worktrees, let scopes, let branchesError, let worktreesError):
            let occupied = Dictionary(grouping: worktrees.compactMap { tree in tree.branchRef.map { ($0, tree.path) } }, by: { $0.0 })
            var roots = scopes && query.isEmpty ? GitHistoryScope.allCases.map { scope in
                GitCollectionNode(.init(id: "scope:" + scope.rawValue, title: scope.displayName, kind: .scope(scope)))
            } : []
            for remote in [false, true] {
                let key = remote ? "refs/remote" : "refs/local"
                let all = branches.filter { $0.isRemote == remote }
                let entries = all.filter { matches(query, text: $0.name) }.map { branch in
                    (branch.name, GitCollectionItem(id: branch.id, title: branch.name,
                        kind: .branch(branch, worktrees: occupied[branch.id, default: []].map(\.1)), enabled: branchesError == nil))
                }
                roots.append(category(key, title: remote ? "Remote Branches" : "Branches", count: all.count,
                    children: grouped(entries, category: key, mode: mode), error: branchesError,
                    empty: query.isEmpty ? "No branches" : "No matching branches"))
            }
            let trees = worktrees.filter { matches(query, text: $0.branchName + " " + $0.path + " " + ($0.head?.rawValue ?? "")) }
                .map { worktree in
                    GitCollectionNode(.init(id: "worktree:" + worktree.path,
                        title: worktree.branchRef == nil ? worktree.head?.shortSHA ?? "No commits" : worktree.branchName,
                        subtitle: worktree.path, kind: .worktree(worktree), enabled: worktreesError == nil && !worktree.isBare))
                }
            roots.append(category("worktrees", title: "Worktrees", count: worktrees.count, children: trees,
                                  error: worktreesError, empty: query.isEmpty ? "No worktrees" : "No matching worktrees"))
            return roots
        }
    }

    static func rows(_ nodes: [GitCollectionNode], collapsed: Set<String> = []) -> [GitCollectionRow] {
        var result: [GitCollectionRow] = []
        func append(_ nodes: [GitCollectionNode], depth: Int) {
            for node in nodes {
                let expanded = !collapsed.contains(node.item.id)
                result.append(.init(item: node.item, depth: depth, expanded: expanded))
                if expanded || node.item.isCategory { append(node.children, depth: node.item.isCategory ? depth : depth + 1) }
            }
        }
        append(nodes, depth: 0)
        return result
    }

    private static func matches(_ query: String, text: String) -> Bool {
        let parts = query.split(whereSeparator: \.isWhitespace)
        return parts.allSatisfy { text.matchedIndices(for: String($0)) != nil }
    }

    private static func category(_ key: String, title: String, count: Int, children: [GitCollectionNode],
                                 error: String?, empty: String) -> GitCollectionNode {
        var values = children
        if let error { values.insert(GitCollectionNode(.init(id: key + "/error", title: error, kind: .notice(error: true))), at: 0) }
        if values.isEmpty { values = [GitCollectionNode(.init(id: key + "/empty", title: empty, kind: .notice(error: false)))] }
        return GitCollectionNode(.init(id: key, title: title, kind: .category(count)), children: values)
    }

    private static func grouped(_ entries: [(String, GitCollectionItem)], category: String, mode: GitCollectionMode) -> [GitCollectionNode] {
        let sorted = entries.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        guard mode == .tree else { return sorted.map { GitCollectionNode($0.1) } }
        let root = GitCollectionNode(.init(id: category, title: "", kind: .category(entries.count)))
        var folders: [String: GitCollectionNode] = [:]
        for (path, value) in sorted {
            let parts = path.split(separator: "/").map(String.init)
            var parent = root
            var prefix = ""
            for part in parts.dropLast() {
                prefix += "/" + part
                let key = category + "/folder" + prefix
                let folder: GitCollectionNode
                if let existing = folders[key] {
                    folder = existing
                    if case .folder(let count) = folder.item.kind {
                        folder.item = .init(id: key, title: part, kind: .folder(count + 1))
                    }
                } else {
                    folder = GitCollectionNode(.init(id: key, title: part, kind: .folder(1)))
                    folders[key] = folder
                    parent.children.append(folder)
                }
                parent = folder
            }
            var item = value
            item.title = parts.last ?? value.title
            parent.children.append(GitCollectionNode(item))
        }
        func order(_ node: GitCollectionNode) {
            node.children.sort {
                if $0.item.isFolder != $1.item.isFolder { return $0.item.isFolder }
                return $0.item.title.localizedStandardCompare($1.item.title) == .orderedAscending
            }
            node.children.forEach(order)
        }
        order(root)
        return root.children
    }
}
