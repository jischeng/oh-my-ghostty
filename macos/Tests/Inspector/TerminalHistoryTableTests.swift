import AppKit
import SwiftUI
import Testing
@testable import Ghostty

@MainActor
struct TerminalHistoryTableTests {
    @Test func compactRowsHaveBoundedHeightAndRequireAnchors() {
        let coordinator = TerminalHistoryTable.Coordinator()
        let item = InspectorHistoryItem(id: "prompt", kind: .agentPrompt,
                                       text: String(repeating: "Long prompt 中文 ", count: 50))
        coordinator.items = [item]
        let table = NSTableView()
        coordinator.table = table
        coordinator.updateWidth(320)
        let longHeight = coordinator.tableView(table, heightOfRow: 0)
        #expect(longHeight <= 108)
        coordinator.items = [.init(id: "short", kind: .agentPrompt, text: "resume")]
        #expect(coordinator.tableView(table, heightOfRow: 0) < longHeight)
        #expect(coordinator.tableView(table, heightOfRow: 0) < 60)
        #expect(!TerminalHistoryTable.Coordinator.canJump(item))
        #expect(TerminalHistoryTable.Coordinator.canJump(.init(
            id: "any-opaque-id", kind: .command, text: "ll",
            location: .command(surfaceID: UUID(), executionID: 1, epoch: UUID())
        )))
    }

    @Test func hostedHistoryScrollsAndCopiesWithoutOverlapping() async throws {
        let items = (0..<40).map { index in
            InspectorHistoryItem(id: "row-\(index)", kind: .agentPrompt,
                                 text: String(repeating: "Prompt \(index) 中文 long text. ", count: 30))
        }
        var jumped: [String] = []
        let host = NSHostingView(rootView: TerminalHistoryTable(items: items) { jumped.append($0.id) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScroll(in: host))
        let table = try #require(scroll.documentView as? TerminalHistoryTable.HistoryTable)
        #expect(table.numberOfRows == 40)
        #expect(table.bounds.height > scroll.contentSize.height)
        table.scrollRowToVisible(39)
        #expect(scroll.contentView.bounds.minY > 0)
        table.scrollRowToVisible(0)
        #expect(table.rect(ofRow: 1).minY >= table.rect(ofRow: 0).maxY)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(table.copyText?() == items[0].text)
        let expanded = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? TerminalHistoryTable.HistoryCell)
        #expect(!expanded.jump.isEnabled)
        #expect(expanded.jump.image != nil)
        #expect(table.style == .plain)
        expanded.jump.performClick(nil)
        #expect(jumped.isEmpty)
        #expect(expanded.subviews.count == 3)
    }

    @Test func archivedShellRowCopiesButNeverOffersFalseJump() async throws {
        let item = InspectorHistoryItem(kind: .command, text: "ll",
                                        timestamp: Date(), location: .unavailable(.expired))
        var jumped = false
        let host = NSHostingView(rootView: TerminalHistoryTable(items: [item]) { _ in jumped = true })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 140),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let table = try #require(findScroll(in: host)?.documentView as? TerminalHistoryTable.HistoryTable)
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(table.copyText?() == "ll")
        let row = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true)
            as? TerminalHistoryTable.HistoryCell)
        #expect(row.date.stringValue.contains(InfoStrings.current.archivedCommandLabel))
        #expect(!row.jump.isEnabled)
        row.jump.performClick(nil)
        #expect(!jumped)
    }

    @Test func mixedHostRowsShowOriginWithoutEnablingArchivedJump() {
        let coordinator = TerminalHistoryTable.Coordinator()
        let table = TerminalHistoryTable.HistoryTable(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        coordinator.update(items: [
            .init(id: "remote", kind: .command, text: "ll", timestamp: Date(),
                  location: .unavailable(.expired), sourceLabel: "SSH · cloud"),
            .init(id: "local", kind: .command, text: "ll", timestamp: Date(),
                  location: .unavailable(.expired), sourceLabel: "Local"),
        ], strings: .init(language: .english))
        let remote = coordinator.tableView(table, viewFor: table.tableColumns.first, row: 0)
            as? TerminalHistoryTable.HistoryCell
        let local = coordinator.tableView(table, viewFor: table.tableColumns.first, row: 1)
            as? TerminalHistoryTable.HistoryCell
        #expect(remote?.date.stringValue.contains("SSH · cloud") == true)
        #expect(local?.date.stringValue.contains("Local") == true)
        #expect(remote?.jump.isEnabled == false)
        #expect(local?.jump.isEnabled == false)
    }

    @Test func compactInfoHostsPortsAndShellHistoryTogether() async throws {
        let texts = [
            "看看这个模块的实现，重点检查多轮对话的定位和不同 pane 之间的隔离。",
            "Please review the implementation. Preserve the complete prompt when copying, even when this preview wraps onto several lines.",
            "继续",
            String(repeating: "长文本预览应当正常换行，不覆盖下一条记录。", count: 20),
        ]
        let items = (0..<16).map { index in
            InspectorHistoryItem(id: "fixture-\(index)", kind: .command,
                                 text: texts[index % texts.count], timestamp: Date(timeIntervalSince1970: 1_790_079_600 - Double(index * 90)))
        }
        let info = InspectorInfoContent(portForwards: .init(hostAlias: "dev-server", items: []),
                                        historyItems: items)
        let host = NSHostingView(rootView: InspectorInfoView(info: info, dividerColor: .gray.opacity(0.2), perform: { _ in })
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 500),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 500)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScroll(in: host))
        #expect(scroll.contentSize.height > 300)
        let table = try #require(scroll.documentView as? TerminalHistoryTable.HistoryTable)
        #expect(table.numberOfRows == 16)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(table.copyText?() == texts[1])
        // Opt-in visual artifact, with no filesystem writes in normal test runs.
        if let path = ProcessInfo.processInfo.environment["OMG_HISTORY_SNAPSHOT"],
           let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: image)
            try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    @Test func agentPaneShowsOnlyShellExecutionsAndKeepsJumpActions() async throws {
        let surfaceID = UUID()
        let epoch = UUID()
        let commands = (1...2).map { execution in
            InspectorHistoryItem(
                id: "command-\(execution)", kind: .command, text: "ll",
                location: .command(surfaceID: surfaceID, executionID: UInt64(execution), epoch: epoch)
            )
        }
        let info = InspectorInfoContent(
            portForwards: .init(hostAlias: "dev-server", items: []),
            historyItems: [commands[0], .init(kind: .agentPrompt, text: "ll"), commands[1]],
            isAgentSession: true, agentName: "Pi"
        )
        var jumped: [String] = []
        let host = NSHostingView(rootView: InspectorInfoView(info: info, dividerColor: .gray) { action in
            if case .jumpToHistoryItem(let item) = action { jumped.append(item.id) }
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.frame = window.contentView?.bounds ?? .zero
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(findScroll(in: host))
        let table = try #require(scroll.documentView as? TerminalHistoryTable.HistoryTable)
        #expect(table.numberOfRows == 2)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        #expect(table.copyText?() == "ll")
        let cell = try #require(table.view(atColumn: 0, row: 1, makeIfNecessary: true)
            as? TerminalHistoryTable.HistoryCell)
        #expect(cell.jump.isEnabled)
        cell.jump.performClick(nil)
        #expect(jumped == [commands[1].id])
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? TerminalHistoryTable.HistoryScrollView { return scroll }
        for child in view.subviews {
            if let scroll = findScroll(in: child) { return scroll }
        }
        return nil
    }

    @Test func reloadPreservesSelectionAndScrollButNeverSelectsAnotherOccurrence() {
        let coordinator = TerminalHistoryTable.Coordinator()
        let table = TerminalHistoryTable.HistoryTable(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.headerView = nil
        table.dataSource = coordinator
        table.delegate = coordinator
        scroll.documentView = table
        coordinator.table = table
        let items = (0..<40).map { InspectorHistoryItem(id: "row-\($0)", kind: .command, text: "ll") }
        coordinator.update(items: items, strings: .init(language: .english))
        table.selectRowIndexes(IndexSet(integer: 15), byExtendingSelection: false)
        table.scrollRowToVisible(15)
        let oldTop = table.row(at: scroll.contentView.bounds.origin)
        coordinator.update(items: [.init(id: "new", kind: .command, text: "ll")] + items,
                           strings: .init(language: .english))
        #expect(table.selectedRow == 16)
        #expect(table.row(at: scroll.contentView.bounds.origin) == oldTop + 1)
        coordinator.update(items: items.filter { $0.id != "row-15" }, strings: .init(language: .english))
        #expect(table.selectedRow == -1)
        #expect(!TerminalHistoryTable.Coordinator.canJump(.init(id: "command:fake:1", kind: .command, text: "ll")))
    }

    @Test func emptyPortsStayCompactAndPopulatedPortsAreBounded() {
        #expect(InfoHistoryLayout.portHeight(count: 0) == 64)
        #expect(InfoHistoryLayout.portHeight(count: 1) > 64)
        #expect(InfoHistoryLayout.portHeight(count: 1, detailCount: 1) > InfoHistoryLayout.portHeight(count: 1))
        #expect(InfoHistoryLayout.portHeight(count: 100) <= 180)
        // Eight ports fit a tall pane without an inner scroll area, and a
        // long list still leaves at least half of the pane to history.
        let tall = InfoHistoryLayout.portLimit(paneHeight: 900)
        #expect(tall == 450)
        #expect(InfoHistoryLayout.portHeight(count: 8, limit: tall) > 180)
        #expect(InfoHistoryLayout.portHeight(count: 8, limit: tall) < tall)
        #expect(InfoHistoryLayout.portHeight(count: 100, limit: tall) == tall)
        #expect(InfoHistoryLayout.portLimit(paneHeight: 200) == 180)
    }

    @Test func remoteTargetColumnHugsItsWidestValueWithinBounds() {
        let short = InfoHistoryLayout.targetColumnWidth(["80"])
        let port = InfoHistoryLayout.targetColumnWidth(["80", "42149"])
        #expect(short >= 36)
        #expect(port > short)
        #expect(InfoHistoryLayout.targetColumnWidth(["database.internal.example.com:5432"]) == 120)
        #expect(InfoHistoryLayout.targetColumnWidth([]) == 36)
    }

    @Test func workingDirectoryFollowsThePaneSession() {
        func context(_ session: PaneSessionContext) -> InspectorPaneContext {
            .init(tabID: UUID(), surfaceID: UUID(), title: "shell",
                  workingDirectory: session.workingDirectory, workspace: nil, session: session)
        }
        let home = NSHomeDirectory()
        let local = InfoWorkingDirectory.resolve(
            context(.init(workingDirectory: home + "/code", terminalTitle: "shell")))
        #expect(local == .init(path: home + "/code", host: nil))
        #expect(local?.displayPath == "~/code")
        #expect(InfoWorkingDirectory.resolve(
            context(.init(workingDirectory: nil, terminalTitle: "shell"))) == nil)
        #expect(InfoWorkingDirectory.resolve(
            context(.init(workingDirectory: "relative", terminalTitle: "shell"))) == nil)

        var connecting = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "shell")
        connecting.apply(.init(action: .start, id: "omg-ssh-1", metadata: "type=remote;targethost=cloud"),
                         currentWorkingDirectory: "/tmp", currentTerminalTitle: "shell")
        #expect(InfoWorkingDirectory.resolve(context(connecting)) == nil)

        var ready = PaneSessionContext(workingDirectory: "/tmp", terminalTitle: "shell")
        ready.apply(.init(action: .start, id: "omg-ssh-2",
                          metadata: "type=remote;targethost=cloud;serverid=server-1;cwd=/home/test"),
                    currentWorkingDirectory: "/tmp", currentTerminalTitle: "shell")
        let remote = InfoWorkingDirectory.resolve(context(ready))
        #expect(remote == .init(path: "/home/test", host: "cloud"))
        // A remote home is not this Mac's home, so it is never abbreviated.
        #expect(InfoWorkingDirectory(path: home, host: "cloud").displayPath == home)
    }

    @Test func externalAppsKeepCandidateOrderAndRespectTheLimit() {
        let installed = ["com.apple.dt.Xcode", "dev.zed.Zed", "com.jetbrains.intellij",
                         "com.jetbrains.intellij.ce", "com.sublimetext.4"]
        let apps = InfoExternalApp.installed(limit: 3) { bundleID in
            guard installed.contains(bundleID) else { return nil }
            let name = bundleID.hasPrefix("com.jetbrains.intellij") ? "IntelliJ IDEA" : bundleID
            return URL(fileURLWithPath: "/Applications/\(name).app")
        }
        // Ultimate and Community share a display name; only the first is offered.
        #expect(apps.map(\.id) == ["dev.zed.Zed", "com.apple.dt.Xcode", "com.jetbrains.intellij"])
        #expect(apps.last?.name == "IntelliJ IDEA")
        #expect(InfoExternalApp.installed { _ in nil }.isEmpty)
    }

    @Test func workingDirectoryOffersLocalActionsAndOnlyCopyForRemote() async throws {
        let zed = InfoExternalApp(id: "dev.zed.Zed", name: "Zed",
                                  url: URL(fileURLWithPath: "/Applications/Zed.app"))
        let local = InfoWorkingDirectory(path: NSHomeDirectory() + "/code/test/oh-my-ghostty", host: nil)
        let remote = InfoWorkingDirectory(path: "/home/test/mapping-platform", host: "cloud")
        #expect(local.actions(apps: [zed]) == [.copyPath, .revealInFinder, .open(zed)])
        // Finder and local editors cannot reach a directory on an SSH host.
        #expect(remote.actions(apps: [zed]) == [.copyPath])

        var actions = InfoDirectoryActions()
        actions.installedApps = { [zed] }
        let forwards = InspectorPortForwardList(hostAlias: "cloud", items: [
            .init(id: "a", remoteHost: "127.0.0.1", remotePort: 42149, localPort: 42149,
                  processName: "python3", status: .active),
            .init(id: "b", remoteHost: "127.0.0.1", remotePort: 8080, localPort: nil,
                  processName: nil, status: .starting),
            .init(id: "c", remoteHost: "db.internal", remotePort: 5432, localPort: 5432,
                  processName: nil, status: .failed("SSH connection was refused.")),
        ])
        let history = (0..<4).map {
            InspectorHistoryItem(id: "row-\($0)", kind: .command, text: ["ll", "git status", "ssh cloud", "make test"][$0],
                                 timestamp: Date(timeIntervalSince1970: 1_790_079_600 - Double($0 * 90)))
        }
        for (name, directory, info) in [
            ("local", local, InspectorInfoContent()),
            ("remote", remote, InspectorInfoContent(portForwards: forwards, historyItems: history)),
        ] {
            let host = NSHostingView(rootView: InspectorInfoView(
                info: info, directory: directory, directoryActions: actions,
                dividerColor: .gray.opacity(0.2), perform: { _ in })
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 520),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 520)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
            host.layoutSubtreeIfNeeded()
            // Sections stack from the top, so history keeps the remaining room.
            #expect(host.fittingSize.width <= 300)
            #expect((findScroll(in: host) != nil) == !info.historyItems.isEmpty)
            // Opt-in visual artifact, with no filesystem writes in normal test runs.
            if let path = ProcessInfo.processInfo.environment["OMG_INFO_SNAPSHOT"],
               let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: image)
                try image.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(path)-\(name).png"))
            }
        }
    }

    @Test func timestampsShortenWithRecencyAndKeepTheFullValueForHover() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) throws -> Date {
            try #require(calendar.date(from: .init(year: year, month: month, day: day,
                                                   hour: hour, minute: minute, second: 7)))
        }
        let now = try date(2026, 11, 21, 16, 8)
        typealias Format = TerminalHistoryTable.Format
        #expect(Format.timestamp(try date(2026, 11, 21, 9, 5), now: now, calendar: calendar) == "09:05")
        #expect(Format.timestamp(try date(2026, 11, 20, 23, 59), now: now, calendar: calendar) == "11-20 23:59")
        #expect(Format.timestamp(try date(2025, 12, 31, 8, 0), now: now, calendar: calendar) == "2025-12-31 08:00")
        #expect(Format.fullTimestamp(try date(2026, 11, 21, 9, 5), calendar: calendar) == "2026-11-21 09:05:07")
    }

    @Test func durationsAppearOnlyForCommandsThatTookNoticeableTime() {
        typealias Format = TerminalHistoryTable.Format
        #expect(Format.duration(milliseconds: nil) == nil)
        #expect(Format.duration(milliseconds: 999) == nil)
        #expect(Format.duration(milliseconds: 1_000) == "1.0s")
        #expect(Format.duration(milliseconds: 3_240) == "3.2s")
        #expect(Format.duration(milliseconds: 125_000) == "2m 5s")
        #expect(Format.duration(milliseconds: 3_780_000) == "1h 3m")
    }

    @Test func failedCommandsAreMarkedAndSuccessfulOnesStayQuiet() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let now = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 21, hour: 16)))
        let ran = try #require(calendar.date(from: .init(year: 2026, month: 11, day: 21, hour: 9, minute: 5)))
        let coordinator = TerminalHistoryTable.Coordinator()
        coordinator.now = { now }
        coordinator.calendar = calendar
        let table = NSTableView()
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        coordinator.table = table
        coordinator.update(items: [
            .init(id: "failed", kind: .command, text: "make test", timestamp: ran,
                  exitCode: 2, duration: 3_240, sourceLabel: "Local"),
            .init(id: "passed", kind: .command, text: "ll", timestamp: ran, exitCode: 0, duration: 12),
            .init(id: "running", kind: .command, text: "sleep 60", timestamp: ran),
        ], strings: .init(language: .english))
        func cell(_ row: Int) throws -> TerminalHistoryTable.HistoryCell {
            try #require(coordinator.tableView(table, viewFor: table.tableColumns.first, row: row)
                as? TerminalHistoryTable.HistoryCell)
        }
        let failed = try cell(0)
        #expect(failed.failed)
        #expect(failed.date.stringValue == "exit 2  ·  09:05  ·  3.2s  ·  Local")
        #expect(failed.date.toolTip == "2026-11-21 09:05:00  ·  exit 2  ·  took 3.240s  ·  Local")
        let color = failed.date.attributedStringValue.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        #expect(color as? NSColor == .systemRed)
        let passed = try cell(1)
        #expect(!passed.failed)
        #expect(passed.date.stringValue == "09:05")
        // A command without a reported outcome is never shown as failed.
        let running = try cell(2)
        #expect(!running.failed)
        #expect(running.date.stringValue == "09:05")
    }

    @Test func labelFramesStayWithinRow() {
        let cell = TerminalHistoryTable.HistoryCell(frame: NSRect(x: 0, y: 0, width: 260, height: 116))
        cell.layout()
        #expect(cell.bounds.contains(cell.text.frame))
        #expect(cell.bounds.contains(cell.date.frame))
        #expect(!cell.text.frame.intersects(cell.date.frame))
        #expect(!cell.text.frame.intersects(cell.jump.frame))
        #expect(cell.text.frame.minY == TerminalHistoryTable.Metrics.verticalInset)
        #expect(cell.text.frame.maxY + TerminalHistoryTable.Metrics.textDateGap == cell.date.frame.minY)
        #expect(cell.bounds.maxY - cell.date.frame.maxY == TerminalHistoryTable.Metrics.verticalInset)
        #expect(cell.jump.frame.maxX <= cell.bounds.maxX)

        let shortCell = TerminalHistoryTable.HistoryCell(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
        shortCell.layout()
        #expect(shortCell.text.frame.maxY < shortCell.date.frame.minY)
        #expect(shortCell.bounds.contains(shortCell.date.frame))
        #expect(shortCell.bounds.maxY - shortCell.date.frame.maxY == TerminalHistoryTable.Metrics.verticalInset)
    }

    @Test func contextMenuOffersCommandOutputActionsForLiveRowsAndDisablesThemForArchivedRows() throws {
        let coordinator = TerminalHistoryTable.Coordinator()
        let table = TerminalHistoryTable.HistoryTable(frame: NSRect(x: 0, y: 0, width: 320, height: 180))
        table.addTableColumn(NSTableColumn(identifier: .init("history")))
        table.dataSource = coordinator
        table.delegate = coordinator
        coordinator.table = table
        let surfaceID = UUID()
        let liveItem = InspectorHistoryItem(
            id: "live-cmd",
            kind: .command,
            text: "git diff --stat",
            timestamp: Date(),
            location: .command(surfaceID: surfaceID, executionID: 1, epoch: UUID())
        )
        let archivedItem = InspectorHistoryItem(
            id: "archived-cmd",
            kind: .command,
            text: "ls -la",
            timestamp: Date(),
            location: .unavailable(.expired)
        )

        var copiedOutputIDs: [String] = []
        var openedOutputIDs: [String] = []
        var jumpedIDs: [String] = []

        coordinator.canExtractOutput = { item in item.location.isAvailable }
        coordinator.copyOutput = { item in copiedOutputIDs.append(item.id) }
        coordinator.openOutputInEditor = { item in openedOutputIDs.append(item.id) }
        coordinator.jump = { item in jumpedIDs.append(item.id) }
        coordinator.update(items: [liveItem, archivedItem], strings: .init(language: .english))

        let liveMenu = try #require(coordinator.contextMenu(forRow: 0))
        let liveActions = liveMenu.items.filter { !$0.isSeparatorItem }
        #expect(liveActions.map(\.title) == [
            "Copy Command",
            "Copy Command Output",
            "Open Command Output in Editor",
            "Jump to Command",
        ])
        #expect(liveActions.allSatisfy { $0.isEnabled })

        _ = liveActions[1].target?.perform(liveActions[1].action, with: liveActions[1])
        _ = liveActions[2].target?.perform(liveActions[2].action, with: liveActions[2])
        _ = liveActions[3].target?.perform(liveActions[3].action, with: liveActions[3])
        #expect(copiedOutputIDs == ["live-cmd"])
        #expect(openedOutputIDs == ["live-cmd"])
        #expect(jumpedIDs == ["live-cmd"])

        let archivedMenu = try #require(coordinator.contextMenu(forRow: 1))
        let archivedActions = archivedMenu.items.filter { !$0.isSeparatorItem }
        #expect(archivedActions[0].isEnabled)
        #expect(!archivedActions[1].isEnabled)
        #expect(!archivedActions[2].isEnabled)
        #expect(!archivedActions[3].isEnabled)
    }
}
