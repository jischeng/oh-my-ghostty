import Foundation
import Testing
@testable import Ghostty

struct PanePromptReaderTests {
    private func line(_ role: String, _ text: String) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["message": ["role": role, "content": text]])
        data.append(10)
        return data
    }

    @Test func keepsLatestUsersAfterHundredsOfAssistantMessagesAndCopiesFullText() throws {
        var parser = PanePromptReader.Parser()
        let full = "  " + String(repeating: "中文\n<instructions>literal</instructions>", count: 600) + "  "
        for _ in 0..<650 { parser.append(try line("assistant", "response"), namespace: "session") }
        parser.append(try line("user", full), namespace: "session")
        parser.append(try line("user", full), namespace: "session")
        #expect(parser.snapshot.items.map(\.text) == [full, full])
        #expect(parser.snapshot.items[0].id != parser.snapshot.items[1].id)
        #expect(parser.snapshot.items.allSatisfy { !$0.location.isAvailable })
    }

    @Test func incompleteUTF8AndJSONAreNotPublishedOrDuplicated() throws {
        var parser = PanePromptReader.Parser()
        let data = try line("user", "你好")
        for byte in data.dropLast() { parser.append(Data([byte]), namespace: "s") }
        #expect(parser.snapshot.items.isEmpty)
        parser.append(Data([10]), namespace: "s")
        #expect(parser.snapshot.items.map(\.text) == ["你好"])
        let id = parser.snapshot.items[0].id
        parser.append(try line("user", "你好"), namespace: "s")
        #expect(parser.snapshot.items.count == 2)
        #expect(parser.snapshot.items[0].id == id)
    }

    @Test func boundsRecentRowsWithoutStoppingAtMessageLimit() throws {
        var parser = PanePromptReader.Parser()
        for index in 0..<140 { parser.append(try line("user", "prompt-\(index)"), namespace: "s") }
        #expect(parser.snapshot.items.count == 100)
        #expect(parser.snapshot.items.first?.text == "prompt-40")
        #expect(parser.snapshot.items.last?.text == "prompt-139")
        #expect(parser.snapshot.limited)
    }

    @Test func oversizedPromptIsSkippedNotCopiedAsTruncatedText() throws {
        var parser = PanePromptReader.Parser()
        parser.append(try line("user", String(repeating: "x", count: 1_048_577)), namespace: "s")
        parser.append(try line("user", "after oversized record"), namespace: "s")
        #expect(parser.snapshot.items.map(\.text) == ["after oversized record"])
        #expect(parser.snapshot.limited)
    }

    @Test func excludesToolResultsButPreservesLiteralUserMarkup() throws {
        var parser = PanePromptReader.Parser()
        let record: [String: Any] = ["message": ["role": "user", "content": [
            ["type": "tool_result", "text": "not a prompt"],
            ["type": "text", "text": "<instructions>my literal question</instructions>"],
        ]]]
        var data = try JSONSerialization.data(withJSONObject: record)
        data.append(10)
        parser.append(data, namespace: "s")
        #expect(parser.snapshot.items.map(\.text) == ["<instructions>my literal question</instructions>"])
    }

    @Test func localReaderAppendsAndResetsAfterFileReplacement() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try line("user", "first").write(to: url)
        let session = AgentHistorySession(agent: .claude,
            conversationID: try #require(AgentConversationID(UUID().uuidString)), title: "test",
            workingDirectory: nil, updatedAt: Date(), sourcePath: url.path, isActive: true)
        let reader = PanePromptReader(session: session)
        let first = try await reader.refresh()
        #expect(first.items.map(\.text) == ["first"])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: line("user", "second"))
        try handle.close()
        let appended = try await reader.refresh()
        #expect(appended.items.map(\.text) == ["first", "second"])
        #expect(appended.items.first?.id == first.items.first?.id)
        #expect(try await reader.refresh() == appended)
        try line("user", "replacement").write(to: url, options: .atomic)
        #expect(try await reader.refresh().items.map(\.text) == ["replacement"])
    }

    private actor RemoteReplies {
        var replies: [String]
        init(_ replies: [String]) { self.replies = replies }
        func next() -> String { replies.removeFirst() }
    }

    @Test func remoteAppendPreservesOccurrencesAndTruncationChangesGeneration() async throws {
        let first = try line("user", "one")
        let appended = first + (try line("user", "two"))
        let replacement = try line("user", "new")
        let replies = RemoteReplies([
            "10:\(first.count):v1\n0\n" + first.base64EncodedString(),
            "10:\(appended.count):v2\n0\n" + appended.base64EncodedString(),
            "10:\(replacement.count):v3\n0\n" + replacement.base64EncodedString(),
        ])
        let access = AgentHistoryRemoteAccess(alias: "host") { _ in await replies.next() }
        let session = AgentHistorySession(agent: .claude,
            conversationID: try #require(AgentConversationID(UUID().uuidString)), title: "test",
            workingDirectory: nil, updatedAt: Date(), sourcePath: "/tmp/session.jsonl", remoteHost: "host", isActive: true)
        let reader = PanePromptReader(session: session, remoteAccess: access)
        let initial = try await reader.refresh()
        let next = try await reader.refresh()
        #expect(next.items.map(\.text) == ["one", "two"])
        #expect(next.items.first?.id == initial.items.first?.id)
        let replaced = try await reader.refresh()
        #expect(replaced.items.map(\.text) == ["new"])
        #expect(replaced.items.first?.id != initial.items.first?.id)
    }

    @Test func remoteTailPreservesBytesAndSkipsUnchangedBody() async throws {
        let data = try line("user", "remote prompt")
        let access = AgentHistoryRemoteAccess(alias: "host") { command in
            #expect(command.contains("base64"))
            #expect(command.contains("tail -c"))
            return "revision\n0\n" + data.base64EncodedString() + "\n"
        }
        let result = try await access.promptTail(path: "/home/user/session.jsonl", previousRevision: nil, maximumBytes: 1024)
        #expect(result.data == data)
        let unchanged = AgentHistoryRemoteAccess(alias: "host") { _ in "UNCHANGED\n" }
        #expect(try await unchanged.promptTail(path: "/home/user/session.jsonl", previousRevision: "revision", maximumBytes: 1024).data == nil)
    }
}
