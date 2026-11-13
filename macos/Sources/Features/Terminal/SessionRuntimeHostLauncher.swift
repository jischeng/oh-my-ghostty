import Darwin
import Foundation

/// Runs a persistent local `omgd` host under the enclosing OMG `.app` bundle's
/// main executable so macOS TCC attributes `omgd` and its shell children to
/// OMG (`com.jischeng.omg` / `com.jischeng.omg.debug`), while staying in its
/// own `launchd` job coalition outside the GUI app's Dock lifecycle.
enum SessionRuntimeHostLauncher {
    static let actionFlag = "+internal-runtime-host"
    static let hostBundlePathEnvironmentKey = "OMG_HOST_APP_BUNDLE"
    static let hostBundleIDEnvironmentKey = "OMG_HOST_APP_BUNDLE_ID"
    static let hostLaunchdLabelEnvironmentKey = "OMG_RUNTIME_HOST_LABEL"

    struct Invocation: Equatable {
        let readyPath: String
        let command: [String]
    }

    static func parse(arguments: [String]) -> Invocation? {
        guard arguments.count >= 5,
              arguments[1] == actionFlag,
              arguments[3] == "--" else {
            return nil
        }
        let readyPath = arguments[2]
        let command = Array(arguments.dropFirst(4))
        guard !readyPath.isEmpty, let program = command.first, !program.isEmpty else {
            return nil
        }
        return Invocation(readyPath: readyPath, command: command)
    }

    static func applyingHostBundleEnvironment(
        _ environment: [String: String],
        bundle: Bundle = .main
    ) -> [String: String] {
        var result = environment
        let bundleURL = bundle.bundleURL
        if bundleURL.pathExtension == "app",
           let bundleID = bundle.bundleIdentifier,
           bundleID.hasPrefix("com.jischeng.omg") {
            result[hostBundlePathEnvironmentKey] = bundleURL.path
            result[hostBundleIDEnvironmentKey] = bundleID
        }
        return result
    }

    static func spawnDetachedChild(_ invocation: Invocation) throws -> pid_t {
        var attr: posix_spawnattr_t?
        let initCode = posix_spawnattr_init(&attr)
        guard initCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: initCode) ?? .EINVAL)
        }
        defer { _ = posix_spawnattr_destroy(&attr) }

        let flagsCode = posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        guard flagsCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: flagsCode) ?? .EINVAL)
        }

        let previousHup = signal(SIGHUP, SIG_IGN)
        defer { _ = signal(SIGHUP, previousHup) }

        var cStrings = invocation.command.map { strdup($0) }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }
        guard let program = cStrings.first ?? nil else {
            throw POSIXError(.EINVAL)
        }
        var argv = cStrings + [nil]

        var pid: pid_t = 0
        let spawnCode = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawnp(&pid, program, nil, &attr, buffer.baseAddress, environ)
        }
        guard spawnCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: spawnCode) ?? .EINVAL)
        }

        let stagingPath = invocation.readyPath + ".tmp"
        let payload = Data("\(pid)".utf8)
        let fd = Darwin.open(stagingPath, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else {
            let err = errno
            _ = kill(pid, SIGTERM)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        let written = payload.withUnsafeBytes { rawBuffer -> Int in
            guard let base = rawBuffer.baseAddress else { return 0 }
            return Darwin.write(fd, base, rawBuffer.count)
        }
        _ = Darwin.close(fd)
        guard written == payload.count, Darwin.rename(stagingPath, invocation.readyPath) == 0 else {
            let err = errno
            _ = Darwin.unlink(stagingPath)
            _ = kill(pid, SIGTERM)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
        return pid
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        guard let invocation = parse(arguments: arguments) else { return }
        let jobLabel = ProcessInfo.processInfo.environment[hostLaunchdLabelEnvironmentKey]
        unsetenv(hostLaunchdLabelEnvironmentKey)
        unsetenv(hostBundlePathEnvironmentKey)
        unsetenv(hostBundleIDEnvironmentKey)

        let childPid: pid_t
        do {
            childPid = try spawnDetachedChild(invocation)
        } catch {
            let message = "OMG runtime host wrapper failed: \(error)\n"
            _ = message.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
            _exit(1)
        }

        var status: Int32 = 0
        while waitpid(childPid, &status, 0) < 0 {
            if errno != EINTR { break }
        }

        if let jobLabel, !jobLabel.isEmpty {
            bootoutFinishedJob(label: jobLabel)
        }
        _exit(0)
    }

    private static func bootoutFinishedJob(label: String) {
        let target = "gui/\(getuid())/\(label)"
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { return }
        defer { _ = posix_spawn_file_actions_destroy(&fileActions) }
        _ = posix_spawn_file_actions_addopen(&fileActions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_addopen(&fileActions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        _ = posix_spawn_file_actions_addopen(&fileActions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        let args = ["/bin/launchctl", "bootout", target]
        let cStrings = args.map { strdup($0) }
        defer {
            for pointer in cStrings {
                free(pointer)
            }
        }
        var argv = cStrings + [nil]
        var pid: pid_t = 0
        let rc = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&pid, "/bin/launchctl", &fileActions, nil, buffer.baseAddress, environ)
        }
        if rc == 0 {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        }
    }
}
