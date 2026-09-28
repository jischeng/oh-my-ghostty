import Foundation
import Testing
@testable import Ghostty

@MainActor
struct DevMemoryDiagnosticsTests {
    @Test func fixedSchemaRejectsContentAndUsesPrivateFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-memory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DevMemoryLog(directory: root)
        log.append(event: "secret terminal command", surfaces: 1, tabs: 1, windows: 1)
        log.append(event: "sample", surfaces: 2, tabs: 1, windows: 1)
        let file = root.appendingPathComponent("events.jsonl")
        let lines = try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["time", "event", "surfaces", "tabs", "windows"])
        #expect(object["event"] as? String == "sample")
        #expect(object["surfaces"] as? Int == 2)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func rotatesWithoutExceedingTwoMegabytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-memory-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let log = DevMemoryLog(directory: root)
        for _ in 0..<25_000 {
            log.append(event: "sample", surfaces: 1, tabs: 1, windows: 1)
        }
        let files = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.fileSizeKey])
        #expect(Set(files.map(\.lastPathComponent)) == ["events.jsonl", "events.previous.jsonl"])
        for file in files {
            let size = try #require(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
            #expect(size <= DevMemoryLog.maxBytes)
        }
    }
}
