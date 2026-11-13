import AppKit
import Darwin
import Foundation
import Testing
@testable import Ghostty

struct SessionRuntimeHostLauncherTests {
    @Test func parseAcceptsInternalRuntimeHostInvocationAndRejectsNormalLaunch() {
        #expect(SessionRuntimeHostLauncher.parse(arguments: ["/Applications/OMG.app/Contents/MacOS/omg"]) == nil)
        #expect(SessionRuntimeHostLauncher.parse(arguments: ["/Applications/OMG.app/Contents/MacOS/omg", "+version"]) == nil)
        #expect(SessionRuntimeHostLauncher.parse(arguments: ["/Applications/OMG.app/Contents/MacOS/omg", "+internal-runtime-host", "/tmp/ready"]) == nil)
        #expect(SessionRuntimeHostLauncher.parse(arguments: ["/Applications/OMG.app/Contents/MacOS/omg", "+internal-runtime-host", "", "--", "/bin/echo"]) == nil)

        let parsed = SessionRuntimeHostLauncher.parse(arguments: [
            "/Applications/OMG.app/Contents/MacOS/omg",
            "+internal-runtime-host",
            "/tmp/omg-ready.pid",
            "--",
            "/tmp/omgd",
            "host-local",
            "/tmp/state",
        ])
        #expect(parsed == .init(
            readyPath: "/tmp/omg-ready.pid",
            command: ["/tmp/omgd", "host-local", "/tmp/state"]
        ))
    }

    @Test func applyingHostBundleEnvironmentPopulatesHostBundleMetadata() {
        let env = SessionRuntimeHostLauncher.applyingHostBundleEnvironment(["PATH": "/usr/bin:/bin"], bundle: .main)
        if Bundle.main.bundleURL.pathExtension == "app",
           let bundleID = Bundle.main.bundleIdentifier,
           bundleID.hasPrefix("com.jischeng.omg") {
            #expect(env[SessionRuntimeHostLauncher.hostBundlePathEnvironmentKey] == Bundle.main.bundleURL.path)
            #expect(env[SessionRuntimeHostLauncher.hostBundleIDEnvironmentKey] == bundleID)
        }
        #expect(env["PATH"] == "/usr/bin:/bin")
    }

    @Test func spawnDetachedChildCreatesSessionLeaderAndWritesReadyPid() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omg-host-launcher-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let readyURL = root.appendingPathComponent("ready.pid")
        let pid = try SessionRuntimeHostLauncher.spawnDetachedChild(.init(
            readyPath: readyURL.path,
            command: ["/bin/sleep", "30"]
        ))
        defer {
            _ = kill(pid, SIGTERM)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }

        let recorded = try String(contentsOf: readyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(Int32(recorded) == pid)
        #expect(getsid(pid) == pid)
    }

    @MainActor
    @Test func restoredInitialFrameSkipsDefaultIntrinsicShrinkDuringWindowLoad() throws {
        let app = try #require(NSApp.delegate as? AppDelegate).ghostty
        let native = try #require(app.app)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/sleep 60"
        let surface = Ghostty.SurfaceView(native, baseConfig: config)

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let targetWidth = min(max(visible.width - 80, 960), 1280)
        let targetHeight = min(max(visible.height - 80, 720), 860)
        let targetFrame = NSRect(
            x: visible.minX + 20,
            y: visible.minY + 20,
            width: targetWidth,
            height: targetHeight
        )

        let controller = TerminalController(
            app,
            withSurfaceTree: .init(view: surface),
            initialFrame: targetFrame
        )
        defer {
            controller.window?.delegate = nil
            controller.window?.close()
        }

        let window = try #require(controller.window)
        #expect(abs(window.frame.width - targetFrame.width) <= 2)
        #expect(abs(window.frame.height - targetFrame.height) <= 2)
    }
}
