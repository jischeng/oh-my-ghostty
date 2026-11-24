import Combine
import Foundation
import Testing
@testable import Ghostty

@MainActor
struct AgentConversationTitleStoreTests {
    private let conversation = AgentConversationID("0f0e0d0c-1111-4222-8333-444455556666")!

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-agent-titles-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("titles.json")
    }

    @Test func aSourceIsNeverDowngradedAndOnlyTheAgentRenames() {
        let store = AgentConversationTitleStore()
        var changed: [AgentConversationTitleStore.Key] = []
        var published = 0
        let titles = store.titleChanges.sink { changed.append($0) }
        let object = store.objectWillChange.sink { published += 1 }
        defer { titles.cancel(); object.cancel() }

        #expect(store.title(agent: .claude, conversationID: conversation) == nil)
        #expect(store.set("Fix the flaky login test", source: .prompt, agent: .claude, conversationID: conversation))
        #expect(store.record(agent: .claude, conversationID: conversation)?.source == .prompt)
        // The opening prompt does not change.
        #expect(!store.set("Another prompt", source: .prompt, agent: .claude, conversationID: conversation))

        #expect(store.set("Login test flake", source: .generated, agent: .claude, conversationID: conversation))
        #expect(!store.set("Fix the flaky login test", source: .prompt, agent: .claude, conversationID: conversation))
        // A generated title is never replaced by another generated one.
        #expect(!store.set("Second summary", source: .generated, agent: .claude, conversationID: conversation))
        #expect(store.title(agent: .claude, conversationID: conversation) == "Login test flake")

        #expect(store.set("Stabilise login", source: .native, agent: .claude, conversationID: conversation))
        #expect(!store.set("Login test flake", source: .generated, agent: .claude, conversationID: conversation))
        #expect(!store.set("Stabilise login", source: .native, agent: .claude, conversationID: conversation))
        // The Agent, or the user through it, may rename its own conversation.
        #expect(store.set("Renamed by the user", source: .native, agent: .claude, conversationID: conversation))
        #expect(store.title(agent: .claude, conversationID: conversation) == "Renamed by the user")

        // The same ID under another Agent is another conversation.
        #expect(store.title(agent: .codex, conversationID: conversation) == nil)
        #expect(changed.count == 4)
        #expect(changed.allSatisfy { $0 == .init(agent: .claude, conversationID: conversation) })
        #expect(published == 4)
    }

    @Test func titlesAreOneReadableLineThatFitsATab() {
        let columns = AgentConversationTitleStore.promptTitleColumns
        #expect(AgentConversationTitleStore.displayTitle("  \n\n  Fix   the\tbuild  \nand more", columns: columns) == "Fix the build")
        #expect(AgentConversationTitleStore.displayTitle(" \n\t ", columns: columns) == nil)
        #expect(AgentConversationTitleStore.displayTitle("a\u{0007}b\u{202E}c", columns: columns) == "abc")

        let long = String(repeating: "word ", count: 40)
        let cut = AgentConversationTitleStore.displayTitle(long, columns: 20)
        #expect(cut == "word word word word…")
        // A wide character takes two columns.
        #expect(AgentConversationTitleStore.displayTitle(String(repeating: "标", count: 30), columns: 20)
            == String(repeating: "标", count: 10) + "…")
        #expect(AgentConversationTitleStore.displayTitle("修复登录测试", columns: 20) == "修复登录测试")

        let store = AgentConversationTitleStore()
        #expect(!store.set("\n \n", source: .native, agent: .claude, conversationID: conversation))
        #expect(store.set(long, source: .prompt, agent: .claude, conversationID: conversation))
        let prompt = store.title(agent: .claude, conversationID: conversation) ?? ""
        #expect(prompt.hasSuffix("…"))
        #expect(prompt.count <= columns + 1)
    }

    @Test func lookupFollowsThePaneDescriptorAndTheMode() {
        let store = AgentConversationTitleStore()
        store.set("Stabilise login", source: .native, agent: .claude, conversationID: conversation)
        let bound = AgentResumeDescriptor(
            agent: .claude, conversationID: conversation, scope: .local, workingDirectory: "/repo"
        )
        #expect(store.title(for: bound, mode: .native) == "Stabilise login")
        #expect(store.title(for: bound, mode: .generate) == "Stabilise login")
        #expect(store.title(for: bound, mode: .off) == nil)
        #expect(store.title(for: nil, mode: .generate) == nil)
        // An Agent without a conversation, or another Agent's, shows none.
        #expect(store.title(for: .init(agent: .claude, scope: .local, workingDirectory: "/repo"), mode: .generate) == nil)
        #expect(store.title(
            for: .init(agent: .codex, conversationID: conversation, scope: .local, workingDirectory: "/repo"),
            mode: .generate
        ) == nil)
        // The host is not part of the identity, so a connection handoff keeps the title.
        #expect(store.title(
            for: .init(agent: .claude, conversationID: conversation, scope: .remote, workingDirectory: "/srv"),
            mode: .generate
        ) == "Stabilise login")
    }

    @Test func archiveIsPrivateAndSurvivesARelaunch() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let store = AgentConversationTitleStore(fileURL: file)
        store.set("Stabilise login", source: .native, agent: .claude, conversationID: conversation, remoteHost: "build-box")
        store.flushPendingWrites()

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        #expect(((directory[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777 == 0o700)

        let reopened = AgentConversationTitleStore(fileURL: file)
        let record = try #require(reopened.record(agent: .claude, conversationID: conversation))
        #expect(record.title == "Stabilise login")
        #expect(record.source == .native)
        #expect(record.remoteHost == "build-box")
        // A relaunch keeps the rule: nothing weaker replaces what was stored.
        #expect(!reopened.set("Summary", source: .generated, agent: .claude, conversationID: conversation))

        reopened.removeAll()
        reopened.flushPendingWrites()
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func oldAndSurplusRecordsArePruned() throws {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = AgentConversationTitleStore(now: { now })
        store.set("Old conversation", source: .native, agent: .claude, conversationID: conversation)
        now = now.addingTimeInterval(AgentConversationTitleStore.retention + 60)
        let recent = try #require(AgentConversationID("recent"))
        store.set("Recent conversation", source: .native, agent: .claude, conversationID: recent)
        #expect(store.title(agent: .claude, conversationID: conversation) == nil)
        #expect(store.title(agent: .claude, conversationID: recent) == "Recent conversation")

        for index in 0..<AgentConversationTitleStore.maximumRecords {
            now = now.addingTimeInterval(1)
            let id = try #require(AgentConversationID("conversation-\(index)"))
            store.set("Title \(index)", source: .native, agent: .codex, conversationID: id)
        }
        #expect(store.records.count == AgentConversationTitleStore.maximumRecords)
        // The oldest record made room for the newest.
        #expect(store.title(agent: .claude, conversationID: recent) == nil)
        let newest = try #require(AgentConversationID("conversation-\(AgentConversationTitleStore.maximumRecords - 1)"))
        #expect(store.title(agent: .codex, conversationID: newest) != nil)
    }

    @Test func unreadableRecordsAndNewerArchivesAreLeftAlone() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let updated = Date().timeIntervalSinceReferenceDate
        func record(agent: String, id: String, title: String) -> [String: Any] {
            ["agent": agent, "conversationID": id, "title": title, "source": "native", "updatedAt": updated]
        }
        // A record of an Agent this build does not know costs only itself.
        let mixed: [String: Any] = ["version": 1, "records": [
            record(agent: "not-an-agent", id: "a", title: "Unknown agent"),
            record(agent: "claude", id: "bad id with spaces", title: "Invalid ID"),
            record(agent: "claude", id: conversation.rawValue, title: "Stabilise login"),
        ]]
        try JSONSerialization.data(withJSONObject: mixed).write(to: file)
        let store = AgentConversationTitleStore(fileURL: file)
        #expect(store.records.count == 1)
        #expect(store.title(agent: .claude, conversationID: conversation) == "Stabilise login")

        // An archive from a newer build is neither read nor replaced.
        let newer: [String: Any] = ["version": 99, "records": [
            record(agent: "claude", id: conversation.rawValue, title: "From the future"),
        ]]
        let newerData = try JSONSerialization.data(withJSONObject: newer)
        try newerData.write(to: file)
        let cautious = AgentConversationTitleStore(fileURL: file)
        #expect(cautious.records.isEmpty)
        #expect(cautious.set("Stabilise login", source: .native, agent: .claude, conversationID: conversation))
        cautious.flushPendingWrites()
        #expect(try Data(contentsOf: file) == newerData)
    }
}
