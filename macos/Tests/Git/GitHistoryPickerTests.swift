import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct GitHistoryPickerTests {
    private final class HoverWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Test func unfavoritedStarsFollowRowHoverAndFavoritesStayVisible() throws {
        let cell = GitCollectionCell(frame: .init(x: 0, y: 0, width: 320, height: 26))
        let branch = GitBranchInfo(name: "main", commit: .init("abc1234"), isCurrent: true,
                                   isRemote: false, upstream: "", tracking: "")
        let row = GitCollectionRow(item: .init(id: branch.id, title: branch.name, kind: .branch(branch, worktrees: [])), depth: 0)
        var toggles = 0
        cell.configure(row, colors: .init(), toggle: {}, stage: {}, favorite: (false, { toggles += 1 }))
        cell.layoutSubtreeIfNeeded()
        let button = cell.favoriteButton
        #expect(!button.isHidden, "The invisible star must keep its clickable hit region")
        #expect(!button.showsStar)
        #expect(cell.hitTest(.init(x: 300, y: 13)) === button)
        button.setRowHovered(true)
        #expect(button.showsStar)
        button.setRowHovered(false)
        #expect(!button.showsStar)
        cell.configure(row, colors: .init(), toggle: {}, stage: {}, favorite: (true, {}))
        #expect(button.showsStar)
        button.setRowHovered(true)
        button.setRowHovered(false)
        #expect(button.showsStar)
        cell.configure(row, colors: .init(), toggle: {}, stage: {}, favorite: (false, { toggles += 1 }))
        #expect(!button.showsStar, "Reused cells must clear the previous branch's filled star")
        button.performClick(nil)
        #expect(toggles == 1)
        cell.configure(row, colors: .init(), toggle: {}, stage: {})
        #expect(button.isHidden, "Other Git collections must not acquire a favorite action")
    }

    @Test func favoritesPersistShareWorktreesAndSeparateRepositoriesAndSSHHosts() throws {
        let suite = "GitHistoryFavoritesTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let worktree = GitRepositoryIdentity(worktreePath: "/repo-feature", gitDirPath: "/repo/.git/worktrees/feature", commonGitDirPath: "/repo/.git")
        let other = GitRepositoryIdentity(worktreePath: "/other", gitDirPath: "/other/.git", commonGitDirPath: "/other/.git")
        let store = GitHistoryBranchFavorites(repository: repository, defaults: defaults)
        store.toggle("HEAD")
        store.toggle("refs/heads/main")
        store.toggle("refs/remotes/origin/main")
        store.toggle("refs/tags/v1")
        #expect(GitHistoryBranchFavorites(repository: repository, defaults: defaults).refs == ["HEAD", "refs/heads/main", "refs/remotes/origin/main"])
        #expect(GitHistoryBranchFavorites(repository: worktree, defaults: defaults).refs == store.refs)
        #expect(GitHistoryBranchFavorites(repository: other, defaults: defaults).refs.isEmpty)
        func remote(_ host: String) throws -> GitHistoryBranchFavorites {
            GitHistoryBranchFavorites(repository: GitRepositoryIdentity(target: .ssh(try GitSSHConnection(destination: host)),
                worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git"), defaults: defaults)
        }
        let firstHost = try remote("host-a")
        let secondHost = try remote("host-b")
        #expect(firstHost.refs.isEmpty)
        firstHost.toggle("refs/heads/remote-only")
        #expect(secondHost.refs.isEmpty)
        #expect(!store.refs.contains("refs/heads/remote-only"))
        store.toggle("refs/heads/main")
        #expect(store.refs == ["HEAD", "refs/remotes/origin/main"])
        store.toggle("refs/remotes/origin/main")
        store.toggle("HEAD")
        #expect(store.refs.isEmpty)
    }

    @Test func favoriteFilterKeepsFullRefIdentitySearchAndTreeModes() {
        let branches = [("feature/main", false), ("origin/main", true), ("main", false)].map { name, remote in
            GitBranchInfo(name: name, commit: .init("abc1234"), isCurrent: name == "main", isRemote: remote, upstream: "", tracking: "")
        }
        let source = GitCollectionSource.refs(branches: branches, worktrees: [], scopes: true, branchesError: nil, worktreesError: nil)
        let favorites: Set<String> = ["HEAD", "refs/heads/feature/main", "refs/remotes/origin/main", "refs/heads/deleted"]
        for mode in GitCollectionMode.allCases {
            let nodes = GitCollectionBuilder.nodes(source: source, mode: mode, favoriteBranchIDs: favorites,
                                                   favoritesOnly: true, includesHead: true)
            let rows = GitCollectionBuilder.rows(nodes)
            #expect(Set(rows.map(\.id)).count == rows.count)
            #expect(rows.contains { $0.item.favoriteID == "HEAD" })
            #expect(rows.filter { if case .branch = $0.item.kind { return true }; return false }.compactMap(\.item.favoriteID).sorted()
                == ["refs/heads/feature/main", "refs/remotes/origin/main"])
            let searched = GitCollectionBuilder.rows(GitCollectionBuilder.nodes(source: source, mode: mode, query: "ORIGIN",
                favoriteBranchIDs: favorites, favoritesOnly: true))
            #expect(searched.contains { $0.item.favoriteID == "refs/remotes/origin/main" })
            #expect(!searched.contains { $0.item.favoriteID == "refs/heads/feature/main" })
        }
        let empty = GitCollectionBuilder.nodes(source: source, mode: .list, favoriteBranchIDs: [],
                                               favoritesOnly: true)
        #expect(empty.first?.children.first?.item.title ==
            GitL10n.text("No favorites. Star a branch or worktree to add it here."))
    }

    @Test func favoritesSectionPrecedesNormalSectionsInBranchColumn() {
        let branches = ["main", "feature/demo"].map {
            GitBranchInfo(name: $0, commit: .init("abc1234"), isCurrent: $0 == "main",
                          isRemote: false, upstream: "", tracking: "")
        }
        let worktree = GitWorktreeInfo(path: "/repo-feature", head: .init("abc1234"),
                                       branchRef: "refs/heads/feature/demo", isMain: false, isCurrent: true)
        let source = GitCollectionSource.refs(branches: branches, worktrees: [worktree], scopes: false,
                                              branchesError: nil, worktreesError: nil)
        let favorites: Set<String> = ["refs/heads/main", GitHistoryBranchFavorites.worktreeID(path: worktree.path)]
        for mode in GitCollectionMode.allCases {
            let nodes = GitCollectionBuilder.nodes(source: source, mode: mode,
                                                   favoriteBranchIDs: favorites, includesHead: true)
            #expect(nodes.first?.item.id == "refs/favorites")
            if mode == .list {
                #expect(nodes.first?.children.map(\.item.id)
                    == ["refs/favorites/refs/heads/main", "refs/favorites/worktree:/repo-feature"])
                #expect(nodes.first?.children.compactMap(\.item.favoriteID)
                    == ["refs/heads/main", "worktree:/repo-feature"])
            }
            #expect(nodes.dropFirst().contains { $0.item.id == "refs/local" })
            #expect(nodes.dropFirst().contains { $0.item.id == "worktrees" })
            let rows = GitCollectionBuilder.rows(nodes)
            #expect(Set(rows.map(\.id)).count == rows.count)
        }
    }

    @Test func favoritesMigrateLegacyStrippedKeysAndKeepWorktrees() throws {
        let suite = "GitHistoryFavoritesMigration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git",
                                               commonGitDirPath: "/repo/.git")
        // Property lists dropped the NUL separators in some exports; binary plists keep them.
        defaults.set(["local/repo/.git": ["HEAD", "refs/heads/main"]],
                     forKey: "git.history.favoriteBranches")
        let store = GitHistoryBranchFavorites(repository: repository, defaults: defaults)
        #expect(store.refs == ["HEAD", "refs/heads/main"])
        store.toggle(GitHistoryBranchFavorites.worktreeID(path: "/repo-feature"))
        #expect(GitHistoryBranchFavorites(repository: repository, defaults: defaults).refs
            == ["HEAD", "refs/heads/main", "worktree:/repo-feature"])
    }

    @Test func favoritesMigrateNULSeparatedLegacyKeysAndShareSSHRepositoriesAcrossLocalCWDs() throws {
        let suite = "GitHistoryFavoritesNULMigration." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let localRepo = GitRepositoryIdentity(worktreePath: "/Users/me/repo", gitDirPath: "/Users/me/repo/.git",
                                              commonGitDirPath: "/Users/me/repo/.git")
        let sshFromDirA = try GitSSHConnection(destination: "dev@host", options: ["-p", "2222"],
                                               workspaceID: "ssh:dev", executablePath: "/usr/bin/ssh",
                                               localWorkingDirectory: "/Users/me/cwd-a")
        let sshFromDirB = try GitSSHConnection(destination: "dev@host", options: ["-p", "2222"],
                                               workspaceID: "ssh:dev-alias", executablePath: "/opt/homebrew/bin/ssh",
                                               localWorkingDirectory: "/Users/me/cwd-b")
        let otherSSH = try GitSSHConnection(destination: "dev@other-host", options: ["-p", "2222"],
                                            workspaceID: "ssh:other", executablePath: "/usr/bin/ssh",
                                            localWorkingDirectory: "/Users/me/cwd-a")
        let remoteRepoA = GitRepositoryIdentity(target: .ssh(sshFromDirA), worktreePath: "/srv/repo",
                                                gitDirPath: "/srv/repo/.git", commonGitDirPath: "/srv/repo/.git")
        let remoteRepoB = GitRepositoryIdentity(target: .ssh(sshFromDirB), worktreePath: "/srv/repo",
                                                gitDirPath: "/srv/repo/.git", commonGitDirPath: "/srv/repo/.git")
        let otherRemoteRepo = GitRepositoryIdentity(target: .ssh(otherSSH), worktreePath: "/srv/repo",
                                                    gitDirPath: "/srv/repo/.git", commonGitDirPath: "/srv/repo/.git")

        defaults.set([
            "local\0/Users/me/repo/.git": ["HEAD", "refs/heads/main", "refs/remotes/origin/main"],
            "ssh\0" + sshFromDirA.identity + "\0/srv/repo/.git": ["HEAD", "refs/remotes/origin/feature-a"],
            "ssh\0" + sshFromDirB.identity + "\0/srv/repo/.git": ["refs/heads/dev", "refs/remotes/origin/feature-a"],
            "ssh\0" + otherSSH.identity + "\0/srv/repo/.git": ["refs/heads/unrelated"]
        ], forKey: "git.history.favoriteBranches")

        #expect(GitHistoryBranchFavorites(repository: localRepo, defaults: defaults).refs
            == ["HEAD", "refs/heads/main", "refs/remotes/origin/main"])
        #expect(GitHistoryBranchFavorites(repository: remoteRepoA, defaults: defaults).refs
            == ["HEAD", "refs/heads/dev", "refs/remotes/origin/feature-a"])
        #expect(GitHistoryBranchFavorites(repository: remoteRepoB, defaults: defaults).refs
            == ["HEAD", "refs/heads/dev", "refs/remotes/origin/feature-a"])
        #expect(GitHistoryBranchFavorites(repository: otherRemoteRepo, defaults: defaults).refs
            == ["refs/heads/unrelated"])

        GitHistoryBranchFavorites(repository: remoteRepoA, defaults: defaults).toggle("refs/heads/release")
        #expect(GitHistoryBranchFavorites(repository: remoteRepoB, defaults: defaults).refs
            == ["HEAD", "refs/heads/dev", "refs/heads/release", "refs/remotes/origin/feature-a"])
    }

    @Test func favoriteButtonsUpdateWithoutBrowsingAndPickerStillSelectsCurrentScope() async throws {
        let suite = "GitHistoryFavoritesPickerTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git", commonGitDirPath: "/repo/.git")
        let branches = ["main", "feature/demo"].map {
            GitBranchInfo(name: $0, commit: .init("abc1234"), isCurrent: $0 == "main", isRemote: false, upstream: "", tracking: "")
        }
        var actions: [InspectorGitAction] = []
        var closed = false
        let picker = GitHistoryScopePicker(title: "All branches", branches: branches, enabled: true,
            selectedID: "scope:allBranches", repository: repository) { actions.append($0) }
        let controller = GitHistoryScopePopoverController(content: picker, defaults: defaults) { closed = true }
        let window = HoverWindow(contentRect: .init(origin: .zero, size: controller.preferredContentSize),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(60))
        controller.view.layoutSubtreeIfNeeded()
        let table = try #require(find(GitCollectionTableView.self, in: controller.view).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        func star(_ id: String) throws -> GitBranchFavoriteButton {
            let row = try #require(coordinator.rows.firstIndex { $0.id == id })
            let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? GitCollectionCell)
            cell.layoutSubtreeIfNeeded()
            #expect(!cell.favoriteButton.isHidden)
            #expect(cell.favoriteButton.frame.width == 24)
            return cell.favoriteButton
        }
        let mainRow = try #require(coordinator.rows.firstIndex { $0.id == "refs/heads/main" })
        let featureRow = try #require(coordinator.rows.firstIndex { $0.id == "refs/heads/feature/demo" })
        let mainBackground = try #require(table.rowView(atRow: mainRow, makeIfNecessary: true) as? GitCollectionRowView)
        let featureBackground = try #require(table.rowView(atRow: featureRow, makeIfNecessary: true) as? GitCollectionRowView)
        let mainStar = try star("refs/heads/main")
        let featureStar = try star("refs/heads/feature/demo")
        func movePointer(to row: Int, x: CGFloat) throws {
            let location = table.convert(NSPoint(x: x, y: table.rect(ofRow: row).midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0
            ))
            #expect(event.window === table.window)
            #expect(window.isKeyWindow && window.isVisible)
            #expect(!table.isHiddenOrHasHiddenAncestor)
            #expect(table.visibleRect.contains(table.convert(event.locationInWindow, from: nil)))
            #expect(NSApp.sendAction(#selector(NSResponder.mouseMoved(with:)), to: table, from: event))
        }
        try movePointer(to: mainRow, x: 40)
        #expect(mainStar.showsStar && !featureStar.showsStar)
        #expect(mainBackground.isPointerHovered && !featureBackground.isPointerHovered)
        try movePointer(to: mainRow, x: 300)
        #expect(mainStar.showsStar && !featureStar.showsStar)
        try movePointer(to: featureRow, x: 40)
        #expect(!mainStar.showsStar && featureStar.showsStar)
        #expect(!mainBackground.isPointerHovered && featureBackground.isPointerHovered)
        table.clearHover()
        #expect(!mainStar.showsStar && !featureStar.showsStar)
        #expect(!mainBackground.isPointerHovered && !featureBackground.isPointerHovered)
        try star("HEAD").performClick(nil)
        try star("refs/heads/main").performClick(nil)
        #expect(GitHistoryBranchFavorites(repository: repository, defaults: defaults).refs == ["HEAD", "refs/heads/main"])
        #expect(actions.isEmpty && !closed)
        #expect(controller.scopeControlForTesting.buttonsForTesting.map(\.title)
            == ["Current", "Favorites", "All"].map { GitL10n.text($0) })
        controller.scopeControlForTesting.buttonsForTesting[1].performClick(nil)
        #expect(actions == [.selectHistoryScope(.favorites)] && !closed)
        #expect(coordinator.rows.contains { $0.item.favoriteID == "HEAD" })
        #expect(coordinator.rows.contains { $0.item.favoriteID == "refs/heads/main" })
        #expect(!coordinator.rows.contains { $0.item.favoriteID == "refs/heads/feature/demo" })
        let selected = try #require(coordinator.rows.firstIndex { $0.item.favoriteID == "refs/heads/main" })
        coordinator.activate(row: selected)
        #expect(actions.last == .browseBranch("refs/heads/main") && closed)
        closed = false
        try star(GitCollectionBuilder.favoriteRowID("refs/heads/main")).performClick(nil)
        #expect(!coordinator.rows.contains { $0.item.favoriteID == "refs/heads/main" })
        #expect(!closed)
        controller.scopeControlForTesting.buttonsForTesting[2].performClick(nil)
        #expect(coordinator.rows.contains { $0.id == "refs/heads/feature/demo" })
        #expect(actions.last == .selectHistoryScope(.allBranches))
        #expect(!closed)
        closed = false
        controller.scopeControlForTesting.buttonsForTesting[0].performClick(nil)
        #expect(actions.last == .selectHistoryScope(.currentBranch))
        #expect(!closed)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { find(type, in: $0) }
    }

    @Test func pickerSearchArrowEnterAndEscapeUseFullReferencesAndWorktreeIdentity() async throws {
        let branches = ["main", "feature/query", "feature/quota", "origin/foo"].map {
            GitBranchInfo(name: $0, commit: .init("abc1234"), isCurrent: $0 == "main", isRemote: $0.hasPrefix("origin/"), upstream: "", tracking: "")
        }
        let worktree = GitWorktreeInfo(path: "/dev/repo-feature", head: .init("abc1234"), branchRef: "refs/heads/feature/query", isMain: false, isCurrent: false)
        var actions: [InspectorGitAction] = []
        let picker = GitHistoryScopePicker(title: "All branches", branches: branches, enabled: true,
            worktrees: [worktree], selectedID: "scope:allBranches") { actions.append($0) }
        let host = NSHostingView(rootView: picker)
        host.sizingOptions = []
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 60), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(100))
        let control = try #require(find(GitHistoryScopePicker.Control.self, in: host).first)

        func open() async throws -> (NSPopover, NSSearchField, GitCollectionTableView) {
            control.showPicker()
            try await Task.sleep(for: .milliseconds(100))
            let popover = try #require(control.popover)
            let view = try #require(popover.contentViewController?.view)
            let search = try #require(find(NSSearchField.self, in: view).first)
            let table = try #require(find(GitCollectionTableView.self, in: view).first)
            let owner = try #require(popover.contentViewController as? GitHistoryScopePopoverController)
            #expect(search.cell is GitSearchFieldCell)
            #expect(search.focusRingType == .none)
            #expect(view.layer?.backgroundColor != nil)
            #expect(owner.scopeControlForTesting.bounds.width == 320)
            #expect(owner.scopeControlForTesting.buttonsForTesting.map(\.title)
                == ["Current", "Favorites", "All"].map { GitL10n.text($0) })
            #expect(owner.scopeControlForTesting.bounds.height == 26)
            for button in owner.modeControlForTesting.buttonsForTesting {
                #expect(!button.isBordered)
                #expect(abs(button.bounds.height - 24) < 1)
            }
            #expect(table.visibleRect.height > 120 && search.bounds.width > 150)
            #expect(popover.contentSize.height <= 340 && popover.contentSize.width == 340)
            #expect(table.visibleRect.minY <= 1, "Initial branch rows must not be clipped")
            let editor = try #require(search.currentEditor() as? NSTextView)
            let textRect = search.convert(editor.bounds, from: editor)
            #expect(textRect.minX + editor.textContainerInset.width + (editor.textContainer?.lineFragmentPadding ?? 0) >= 16,
                    "Focused search text must leave room for the search icon")
            if FileManager.default.fileExists(atPath: "/tmp/omg-native-visual-review") {
                for (suffix, name) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                    let appearance = try #require(NSAppearance(named: name))
                    popover.contentViewController?.view.appearance = appearance
                    view.layoutSubtreeIfNeeded()
                    view.displayIfNeeded()
                    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    appearance.performAsCurrentDrawingAppearance {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                    }
                    try #require(bitmap.representation(using: .png, properties: [:]))
                        .write(to: URL(fileURLWithPath: "/tmp/omg-git-history-picker-\(suffix).png"))
                }
            }
            return (popover, search, table)
        }
        func type(_ text: String, into field: NSSearchField) async throws {
            field.stringValue = text
            let delegate = try #require(field.delegate as? GitHistoryScopePopoverController)
            delegate.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            try await Task.sleep(for: .milliseconds(80))
        }
        func key(_ selector: String, in field: NSSearchField) throws {
            let delegate = try #require(field.delegate as? GitHistoryScopePopoverController)
            let editor = field.currentEditor() as? NSTextView ?? NSTextView()
            #expect(delegate.control(field, textView: editor, doCommandBy: NSSelectorFromString(selector)))
        }
        let (popover, search, table) = try await open()
        let owner = try #require(popover.contentViewController as? GitHistoryScopePopoverController)
        owner.scopeControlForTesting.buttonsForTesting[0].performClick(nil)
        #expect(popover.isShown && actions.last == .selectHistoryScope(.currentBranch))
        owner.scopeControlForTesting.buttonsForTesting[2].performClick(nil)
        #expect(popover.isShown && actions.last == .selectHistoryScope(.allBranches))
        var updated = picker
        updated.selectedID = "scope:favorites"
        host.rootView = updated
        try await Task.sleep(for: .milliseconds(50))
        #expect(popover.isShown && owner.scopeControlForTesting.buttonsForTesting[1].state == .on)
        updated.selectedID = "scope:allBranches"
        host.rootView = updated
        try await Task.sleep(for: .milliseconds(50))
        #expect(popover.isShown && owner.scopeControlForTesting.buttonsForTesting[2].state == .on)
        actions.removeAll()
        try await type("FEATURE/QU", into: search)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        #expect(coordinator.rows[table.selectedRow].id == "refs/heads/feature/query")
        try key("moveDown:", in: search)
        #expect(coordinator.rows[table.selectedRow].id == "refs/heads/feature/quota")
        try key("moveUp:", in: search)
        #expect(coordinator.rows[table.selectedRow].id == "refs/heads/feature/query")
        try key("moveDown:", in: search)
        try key("insertNewline:", in: search)
        #expect(actions == [.browseBranch("refs/heads/feature/quota")])
        #expect(!popover.isShown)

        let (worktreePopover, worktreeSearch, _) = try await open()
        try await type("REPO-FEATURE", into: worktreeSearch)
        try key("insertNewline:", in: worktreeSearch)
        #expect(actions.last == .browseWorktree(worktree.path))
        #expect(!worktreePopover.isShown)

        let (cancelled, cancelledSearch, _) = try await open()
        try await type("origin/FOO", into: cancelledSearch)
        let before = actions
        try key("cancelOperation:", in: cancelledSearch)
        #expect(!cancelled.isShown && actions == before)
    }

    @Test func starredBranchesInAllScopeSurviveRefreshSearchStarToggleAndHoverIndependently() async throws {
        let suite = "GitHistoryFavoritesAllScopeDiff." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let repository = GitRepositoryIdentity(worktreePath: "/repo", gitDirPath: "/repo/.git",
                                               commonGitDirPath: "/repo/.git")
        let worktree = GitWorktreeInfo(path: "/repo-feature", head: .init("abc1234"),
                                       branchRef: "refs/heads/feature/demo", isMain: false, isCurrent: false)
        let store = GitHistoryBranchFavorites(repository: repository, defaults: defaults)
        store.toggle("HEAD")
        store.toggle("refs/heads/main")
        store.toggle("refs/remotes/origin/main")
        store.toggle(GitHistoryBranchFavorites.worktreeID(path: worktree.path))

        let branches = [
            GitBranchInfo(name: "main", commit: .init("abc1234"), isCurrent: true,
                          isRemote: false, upstream: "origin/main", tracking: ""),
            GitBranchInfo(name: "feature/demo", commit: .init("def5678"), isCurrent: false,
                          isRemote: false, upstream: "", tracking: ""),
            GitBranchInfo(name: "origin/main", commit: .init("abc1234"), isCurrent: false,
                          isRemote: true, upstream: "", tracking: "")
        ]
        var actions: [InspectorGitAction] = []
        let picker = GitHistoryScopePicker(title: "All branches", branches: branches, enabled: true,
                                           worktrees: [worktree], selectedID: "scope:allBranches",
                                           repository: repository) { actions.append($0) }
        let controller = GitHistoryScopePopoverController(content: picker, defaults: defaults) {}
        let window = HoverWindow(contentRect: .init(origin: .zero, size: controller.preferredContentSize),
                                 styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(60))
        controller.view.layoutSubtreeIfNeeded()

        let table = try #require(find(GitCollectionTableView.self, in: controller.view).first)
        let coordinator = try #require(table.target as? GitCollectionView.Coordinator)
        #expect(Set(coordinator.rows.map(\.id)).count == coordinator.rows.count)

        // Content refresh immediately after opening must diff cleanly without duplicate-key crashes.
        controller.updateContent(picker)
        #expect(Set(coordinator.rows.map(\.id)).count == coordinator.rows.count)

        let favoriteMainIndex = try #require(coordinator.rows.firstIndex {
            $0.id == GitCollectionBuilder.favoriteRowID("refs/heads/main")
        })
        let regularMainIndex = try #require(coordinator.rows.firstIndex { $0.id == "refs/heads/main" })
        #expect(favoriteMainIndex < regularMainIndex)

        // Hovering the Favorites copy must not highlight the normal Branches copy.
        table.scrollRowToVisible(favoriteMainIndex)
        let favPoint = table.convert(NSPoint(x: 40, y: table.rect(ofRow: favoriteMainIndex).midY), to: nil)
        let hoverEvent = try #require(NSEvent.mouseEvent(
            with: .mouseMoved, location: favPoint, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0
        ))
        #expect(NSApp.sendAction(#selector(NSResponder.mouseMoved(with:)), to: table, from: hoverEvent))
        let favRowView = try #require(table.rowView(atRow: favoriteMainIndex, makeIfNecessary: true) as? GitCollectionRowView)
        #expect(favRowView.isPointerHovered)
        if let regularRowView = table.rowView(atRow: regularMainIndex, makeIfNecessary: false) as? GitCollectionRowView {
            #expect(!regularRowView.isPointerHovered)
        }

        // Typing and clearing search in the popover search field must incrementally diff without crashing.
        let search = controller.searchFieldForTesting
        for query in ["m", "ma", "main", "demo", ""] {
            search.stringValue = query
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            #expect(Set(coordinator.rows.map(\.id)).count == coordinator.rows.count)
        }

        // Unstarring from the Favorites section removes only the Favorites row and updates the normal row's star.
        let favRow = try #require(coordinator.rows.firstIndex {
            $0.id == GitCollectionBuilder.favoriteRowID("refs/heads/main")
        })
        let favCell = try #require(table.view(atColumn: 0, row: favRow, makeIfNecessary: true) as? GitCollectionCell)
        favCell.favoriteButton.performClick(nil)
        #expect(!coordinator.rows.contains { $0.id == GitCollectionBuilder.favoriteRowID("refs/heads/main") })
        #expect(coordinator.rows.contains { $0.id == "refs/heads/main" })
        #expect(!GitHistoryBranchFavorites(repository: repository, defaults: defaults).refs.contains("refs/heads/main"))
    }
}
