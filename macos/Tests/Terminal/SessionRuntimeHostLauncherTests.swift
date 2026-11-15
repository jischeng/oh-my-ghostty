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

    @Test func parseForegroundAcceptsForegroundInvocationAndRejectsMalformed() {
        #expect(SessionRuntimeHostLauncher.parseForeground(arguments: ["/Applications/OMG.app/Contents/MacOS/omg"]) == nil)
        #expect(SessionRuntimeHostLauncher.parseForeground(arguments: ["/Applications/OMG.app/Contents/MacOS/omg", "+internal-runtime-foreground", "--"]) == nil)
        #expect(SessionRuntimeHostLauncher.parseForeground(arguments: ["/Applications/OMG.app/Contents/MacOS/omg", "+internal-runtime-foreground", "--", ""]) == nil)
        #expect(SessionRuntimeHostLauncher.parseForeground(arguments: ["/Applications/OMG.app/Contents/MacOS/omg", "+internal-runtime-foreground", "/tmp/x", "--", "/bin/echo"]) == nil)

        let parsed = SessionRuntimeHostLauncher.parseForeground(arguments: [
            "/Applications/OMG.app/Contents/MacOS/omg",
            "+internal-runtime-foreground",
            "--",
            "/tmp/omgd",
            "mobile",
            "serve",
        ])
        #expect(parsed == .init(command: ["/tmp/omgd", "mobile", "serve"]))
    }

    @Test func spawnForegroundChildStaysInCallerSessionAndResetsBlockedSignals() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("omg-fg-mask-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let maskOut = dir.appendingPathComponent("sigmask.txt")

        var blockSet = sigset_t()
        var oldSet = sigset_t()
        sigemptyset(&blockSet)
        sigaddset(&blockSet, SIGTERM)
        #expect(pthread_sigmask(SIG_BLOCK, &blockSet, &oldSet) == 0)

        let probePid: pid_t
        do {
            probePid = try SessionRuntimeHostLauncher.spawnForegroundChild(.init(command: [
                "/usr/bin/python3",
                "-c",
                "import pathlib, signal, sys; blocked = signal.SIGTERM in signal.pthread_sigmask(signal.SIG_BLOCK, []); pathlib.Path(sys.argv[1]).write_text('blocked' if blocked else 'clear')",
                maskOut.path,
            ]))
            _ = pthread_sigmask(SIG_SETMASK, &oldSet, nil)
        } catch {
            _ = pthread_sigmask(SIG_SETMASK, &oldSet, nil)
            throw error
        }
        var probeStatus: Int32 = 0
        while waitpid(probePid, &probeStatus, 0) < 0 && errno == EINTR {}
        #expect(try String(contentsOf: maskOut, encoding: .utf8) == "clear")

        let pid = try SessionRuntimeHostLauncher.spawnForegroundChild(.init(
            command: ["/bin/sleep", "30"]
        ))
        defer {
            _ = kill(pid, SIGTERM)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }

        #expect(pid > 0)
        #expect(getsid(pid) != pid)
    }

    @Test func foregroundWrapperPreservesExitCodeForwardsSigtermAndReapsChildOnParentKillWhenAppHosted() throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let bundleID = Bundle.main.bundleIdentifier,
              bundleID.hasPrefix("com.jischeng.omg"),
              let executableURL = Bundle.main.executableURL else {
            return
        }

        let exitProbe = Process()
        exitProbe.executableURL = executableURL
        exitProbe.arguments = [SessionRuntimeHostLauncher.foregroundActionFlag, "--", "/bin/sh", "-c", "exit 42"]
        try exitProbe.run()
        exitProbe.waitUntilExit()
        #expect(exitProbe.terminationStatus == 42)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omg-fg-sig-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let childPIDFile = dir.appendingPathComponent("child.pid")
        let termMarker = dir.appendingPathComponent("child-term")

        let wrapper = Process()
        wrapper.executableURL = executableURL
        wrapper.arguments = [
            SessionRuntimeHostLauncher.foregroundActionFlag,
            "--",
            "/bin/sh",
            "-c",
            "trap 'touch \"\(termMarker.path)\"; exit 0' TERM; echo $$ > \"\(childPIDFile.path)\"; while :; do sleep 0.05; done",
        ]
        try wrapper.run()
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: childPIDFile.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        wrapper.terminate()
        wrapper.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: termMarker.path))

        // Simulate host crash (`SIGKILL` of parent process) -> foreground wrapper detects parent exit and terminates child.
        let orphanChildPIDFile = dir.appendingPathComponent("orphan-child.pid")
        let orphanTermMarker = dir.appendingPathComponent("orphan-child-term")
        let parentSpawner = Process()
        parentSpawner.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parentSpawner.arguments = [
            "-c",
            """
            import os, pathlib, signal, subprocess, sys, time
            exe, flag, pid_file, marker = sys.argv[1:5]
            p = subprocess.Popen([
                exe, flag, "--", "/bin/sh", "-c",
                f'trap "touch \\"{marker}\\"; exit 0" TERM; echo $$ > "{pid_file}"; while :; do sleep 0.05; done'
            ])
            deadline = time.time() + 5.0
            while not pathlib.Path(pid_file).exists() and time.time() < deadline:
                time.sleep(0.02)
            os.kill(os.getpid(), signal.SIGKILL)
            """,
            executableURL.path,
            SessionRuntimeHostLauncher.foregroundActionFlag,
            orphanChildPIDFile.path,
            orphanTermMarker.path,
        ]
        try parentSpawner.run()
        parentSpawner.waitUntilExit()

        let orphanDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: orphanTermMarker.path), Date() < orphanDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(FileManager.default.fileExists(atPath: orphanTermMarker.path))
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
