import Foundation
import Testing
@testable import Ghostty

struct RemoteShellHistoryInstallerTests {
    private func run(_ args: [String], script: URL, home: URL) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + args
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path
        environment["XDG_CONFIG_HOME"] = home.appendingPathComponent(".config").path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }

    @Test func installerIsExplicitIdempotentAndPreservesUserConfiguration() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-remote-shell-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installer = home.appendingPathComponent("omg-shell-history.py")
        try RemoteShellHistoryInstaller.script.write(to: installer, atomically: true, encoding: .utf8)
        let existing = home.appendingPathComponent(".zshrc")
        try "# user's prompt setup\n".write(to: existing, atomically: true, encoding: .utf8)
        #expect(try run(["install"], script: installer, home: home).0 == 0)
        let first = try String(contentsOf: existing, encoding: .utf8)
        #expect(first.hasPrefix("# user's prompt setup\n"))
        #expect(first.components(separatedBy: "# >>> OMG shell history").count == 2)
        #expect(try run(["install"], script: installer, home: home).0 == 0)
        #expect(try String(contentsOf: existing, encoding: .utf8) == first)
        let status = try run(["status"], script: installer, home: home)
        #expect(status.0 == 0)
        #expect(status.1.contains("fish: installed"))
        #expect(status.1.contains("bash: installed"))
        let scriptDir = home.appendingPathComponent(".config/oh-my-ghostty/shell-history")
        for name in ["fish", "zsh", "bash"] {
            #expect(FileManager.default.fileExists(atPath:
                scriptDir.appendingPathComponent("history.\(name)").path))
        }
        #expect(try run(["uninstall"], script: installer, home: home).0 == 0)
        #expect(try String(contentsOf: existing, encoding: .utf8) == "# user's prompt setup\n")
        #expect(try run(["status"], script: installer, home: home).1.contains("fish: not installed"))
    }

    @Test func refusesSymlinkedShellRCWithoutModifyingTarget() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-remote-shell-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let target = home.appendingPathComponent("real-zshrc")
        try "unaltered".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".zshrc"), withDestinationURL: target
        )
        let installer = home.appendingPathComponent("omg-shell-history.py")
        try RemoteShellHistoryInstaller.script.write(to: installer, atomically: true, encoding: .utf8)
        let result = try run(["install"], script: installer, home: home)
        #expect(result.0 != 0)
        #expect(result.1.contains("Refusing"))
        #expect(try String(contentsOf: target, encoding: .utf8) == "unaltered")
        #expect(!FileManager.default.fileExists(atPath:
            home.appendingPathComponent(".config/fish/config.fish").path))
    }

    @Test func exportedShellSnippetsParseWithoutTouchingUserHome() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-remote-shell-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let installer = home.appendingPathComponent("omg-shell-history.py")
        try RemoteShellHistoryInstaller.script.write(to: installer, atomically: true, encoding: .utf8)
        #expect(try run(["install"], script: installer, home: home).0 == 0)
        let root = home.appendingPathComponent(".config/oh-my-ghostty/shell-history")
        for (shell, binary) in [("zsh", "/bin/zsh"), ("bash", "/bin/bash"),
                                ("fish", "/opt/homebrew/bin/fish")] {
            guard FileManager.default.isExecutableFile(atPath: binary) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = ["-n", root.appendingPathComponent("history.\(shell)").path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}
