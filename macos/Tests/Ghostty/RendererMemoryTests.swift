import AppKit
import Foundation
import Testing
@testable import Ghostty
@testable import GhosttyKit

@MainActor
struct RendererMemoryTests {
    @Test func inactiveSurfacesRetainTheirLastImageAndResumeRendering() async throws {
        guard let label = try? String(contentsOfFile: "/tmp/omg-memory-probe", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        let app = try #require(NSApp.delegate as? AppDelegate)
        var controllers: [TerminalController] = []
        defer { for controller in controllers { controller.window?.delegate = nil; controller.window?.close() } }
        for _ in 0..<4 {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "printf 'memory probe\n'; sleep 30"
            let controller = TerminalController(app.ghostty, withBaseConfig: config)
            controllers.append(controller)
            controller.window?.setContentSize(.init(width: 1600, height: 900))
            controller.window?.makeKeyAndOrderFront(nil)
        }
        try await Task.sleep(for: .milliseconds(600))
        let views = try controllers.map { try #require($0.surfaceTree.first) }
        let handles = try views.map { try #require($0.surface) }
        for _ in 0..<4 {
            for handle in handles { ghostty_surface_set_occlusion(handle, true); ghostty_surface_refresh(handle) }
            try await Task.sleep(for: .milliseconds(80))
        }
        func footprint(_ phase: String) async throws {
            let pid = ProcessInfo.processInfo.processIdentifier
            try await Task.detached {
                let process = Process(); let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
                process.arguments = ["-p", String(pid)]
                process.standardOutput = pipe; process.standardError = pipe
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                try data.write(to: URL(fileURLWithPath: "/tmp/omg-memory-\(label)-\(phase).txt"))
            }.value
        }
        try await footprint("visible")
        for handle in handles { ghostty_surface_set_occlusion(handle, false) }
        try await Task.sleep(for: .milliseconds(500))
        try await footprint("hidden")
        for view in views { #expect(view.layer?.contents != nil) }
        for handle in handles { ghostty_surface_set_occlusion(handle, true); ghostty_surface_refresh(handle) }
        try await Task.sleep(for: .milliseconds(200))
        for view in views { #expect(view.layer?.contents != nil) }
        try await footprint("resumed")
    }
}
