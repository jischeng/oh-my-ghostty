import Darwin
import Foundation

private nonisolated(unsafe) var foregroundChildPID: pid_t = 0

private func forwardSignalToForegroundChild(_ sig: Int32) {
    let pid = foregroundChildPID
    if pid > 0 {
        _ = kill(pid, sig)
    }
}

/// Runs a persistent local `omgd` host (or foreground child such as `mobile serve`)
/// under the enclosing OMG `.app` bundle's main executable so macOS TCC and
/// Local Network privacy attribute child processes to OMG (`com.jischeng.omg`
/// / `com.jischeng.omg.debug`), while `+internal-runtime-host` stays in its
/// own `launchd` job coalition outside the GUI app's Dock lifecycle.
enum SessionRuntimeHostLauncher {
    static let actionFlag = "+internal-runtime-host"
    static let foregroundActionFlag = "+internal-runtime-foreground"
    static let hostBundlePathEnvironmentKey = "OMG_HOST_APP_BUNDLE"
    static let hostBundleIDEnvironmentKey = "OMG_HOST_APP_BUNDLE_ID"
    static let hostLaunchdLabelEnvironmentKey = "OMG_RUNTIME_HOST_LABEL"
    static let wrapperIdentityEnvironmentKey = "OMG_WRAPPER_IDENTITY"
    static let wrapperExecutableEnvironmentKey = "OMG_WRAPPER_EXECUTABLE"

    struct Invocation: Equatable {
        let readyPath: String
        let command: [String]
    }

    struct ForegroundInvocation: Equatable {
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

    static func parseForeground(arguments: [String]) -> ForegroundInvocation? {
        guard arguments.count >= 4,
              arguments[1] == foregroundActionFlag,
              arguments[2] == "--" else {
            return nil
        }
        let command = Array(arguments.dropFirst(3))
        guard let program = command.first, !program.isEmpty else {
            return nil
        }
        return ForegroundInvocation(command: command)
    }

    static func isValidOMGHostBundleIdentifier(_ bundleID: String) -> Bool {
        guard bundleID == "com.jischeng.omg" || bundleID.hasPrefix("com.jischeng.omg.") else {
            return false
        }
        return bundleID.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z")) ||
                (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z")) ||
                (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")) ||
                byte == UInt8(ascii: ".") ||
                byte == UInt8(ascii: "-") ||
                byte == UInt8(ascii: "_")
        }
    }

    static func isEphemeralOrTrashedBundlePath(_ path: String) -> Bool {
        path.contains("/org.sparkle-project.Sparkle/") || path.contains("/.Trash/")
    }

    static func applyingHostBundleEnvironment(
        _ environment: [String: String],
        bundleURL: URL,
        bundleIdentifier: String?,
        allowInitialBundleFallback: Bool,
        fallbackBundleURL: URL = OMGApplicationEnvironment.initialBundleURL,
        fallbackBundleIdentifier: String? = OMGApplicationEnvironment.initialBundleIdentifier
    ) -> [String: String] {
        var result = environment
        var resolvedURL = bundleURL.standardizedFileURL
        var resolvedID = bundleIdentifier
        if allowInitialBundleFallback, isEphemeralOrTrashedBundlePath(resolvedURL.path) {
            resolvedURL = fallbackBundleURL.standardizedFileURL
            resolvedID = fallbackBundleIdentifier ?? resolvedID
        }
        if resolvedURL.pathExtension == "app",
           !isEphemeralOrTrashedBundlePath(resolvedURL.path),
           let bundleID = resolvedID?.trimmingCharacters(in: .whitespacesAndNewlines),
           isValidOMGHostBundleIdentifier(bundleID) {
            result[hostBundlePathEnvironmentKey] = resolvedURL.path
            result[hostBundleIDEnvironmentKey] = bundleID
        }
        return result
    }

    static func applyingHostBundleEnvironment(
        _ environment: [String: String],
        bundle: Bundle = .main
    ) -> [String: String] {
        applyingHostBundleEnvironment(
            environment,
            bundleURL: bundle.bundleURL,
            bundleIdentifier: bundle.bundleIdentifier,
            allowInitialBundleFallback: bundle === Bundle.main
        )
    }

    private static func spawnChild(command: [String], detached: Bool) throws -> pid_t {
        var attr: posix_spawnattr_t?
        let initCode = posix_spawnattr_init(&attr)
        guard initCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: initCode) ?? .EINVAL)
        }
        defer { _ = posix_spawnattr_destroy(&attr) }

        var emptyMask = sigset_t()
        sigemptyset(&emptyMask)
        _ = posix_spawnattr_setsigmask(&attr, &emptyMask)

        var defaultSignals = sigset_t()
        sigemptyset(&defaultSignals)
        sigaddset(&defaultSignals, SIGTERM)
        sigaddset(&defaultSignals, SIGINT)
        sigaddset(&defaultSignals, SIGHUP)
        _ = posix_spawnattr_setsigdefault(&attr, &defaultSignals)

        let spawnFlags = Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF) |
            (detached ? Int16(POSIX_SPAWN_SETSID) : 0)
        let flagsCode = posix_spawnattr_setflags(&attr, spawnFlags)
        guard flagsCode == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: flagsCode) ?? .EINVAL)
        }

        let previousHup = detached ? signal(SIGHUP, SIG_IGN) : nil
        defer {
            if detached {
                _ = signal(SIGHUP, previousHup ?? SIG_DFL)
            }
        }

        let cStrings = command.map { strdup($0) }
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
        return pid
    }

    static func currentWrapperExecutableMetadata(bundle: Bundle = .main) -> (executablePath: String, dev: UInt64, ino: UInt64)? {
        let bundleURL = bundle.bundleURL
        guard bundleURL.pathExtension == "app",
              let bundleID = bundle.bundleIdentifier,
              isValidOMGHostBundleIdentifier(bundleID) else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let pidPath: String? = {
            let len = proc_pidpath(getpid(), &buffer, UInt32(buffer.count))
            return len > 0 ? String(cString: buffer) : nil
        }()
        guard let executablePath = pidPath ?? bundle.executableURL?.path,
              !executablePath.isEmpty,
              !isEphemeralOrTrashedBundlePath(executablePath) else {
            return nil
        }
        let fd = Darwin.open(executablePath, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else {
            return nil
        }
        defer { _ = Darwin.close(fd) }
        var st = Darwin.stat()
        guard Darwin.fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        return (executablePath, UInt64(bitPattern: Int64(st.st_dev)), st.st_ino)
    }

    static func spawnDetachedChild(_ invocation: Invocation) throws -> pid_t {
        if let meta = currentWrapperExecutableMetadata() {
            setenv(wrapperIdentityEnvironmentKey, "\(getpid()):\(meta.dev):\(meta.ino)", 1)
            setenv(wrapperExecutableEnvironmentKey, meta.executablePath, 1)
        } else {
            unsetenv(wrapperIdentityEnvironmentKey)
            unsetenv(wrapperExecutableEnvironmentKey)
        }
        defer {
            unsetenv(wrapperIdentityEnvironmentKey)
            unsetenv(wrapperExecutableEnvironmentKey)
        }
        let pid = try spawnChild(command: invocation.command, detached: true)

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

    static func spawnForegroundChild(_ invocation: ForegroundInvocation) throws -> pid_t {
        try spawnChild(command: invocation.command, detached: false)
    }

    static func runForegroundLifecycle(
        _ foreground: ForegroundInvocation,
        initialParentPID: pid_t = getppid()
    ) -> Int32 {
        var blockMask = sigset_t()
        var previousMask = sigset_t()
        sigemptyset(&blockMask)
        sigaddset(&blockMask, SIGTERM)
        sigaddset(&blockMask, SIGINT)
        sigaddset(&blockMask, SIGHUP)
        _ = pthread_sigmask(SIG_BLOCK, &blockMask, &previousMask)

        let childPid: pid_t
        do {
            childPid = try spawnForegroundChild(foreground)
        } catch {
            _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)
            let message = "OMG foreground runtime wrapper failed: \(error)\n"
            _ = message.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
            return 1
        }

        foregroundChildPID = childPid
        var action = sigaction()
        action.__sigaction_u.__sa_handler = forwardSignalToForegroundChild
        sigemptyset(&action.sa_mask)
        action.sa_flags = 0
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            _ = sigaction(sig, &action, nil)
        }

        let terminateOrphanedChild: @Sendable () -> Void = {
            let pid = foregroundChildPID
            guard pid > 0 else { return }
            _ = kill(pid, SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                let remaining = foregroundChildPID
                if remaining == pid, remaining > 0 {
                    _ = kill(remaining, SIGKILL)
                }
            }
        }

        var parentSource: DispatchSourceProcess?
        if initialParentPID > 1 {
            let source = DispatchSource.makeProcessSource(
                identifier: initialParentPID,
                eventMask: .exit,
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler(handler: terminateOrphanedChild)
            source.resume()
            parentSource = source
            if getppid() != initialParentPID {
                terminateOrphanedChild()
            }
        }

        _ = pthread_sigmask(SIG_SETMASK, &previousMask, nil)

        var status: Int32 = 0
        while waitpid(childPid, &status, 0) < 0 {
            if errno != EINTR { break }
        }
        foregroundChildPID = 0
        parentSource?.cancel()

        let signalNumber = status & 0x7f
        if signalNumber == 0 {
            return (status >> 8) & 0xff
        }
        if signalNumber != 0x7f {
            return 128 + signalNumber
        }
        return 1
    }

    static func foregroundEnvironment(
        _ environment: [String: String],
        bundle: Bundle = .main
    ) -> [String: String] {
        var result = environment
        result.removeValue(forKey: hostLaunchdLabelEnvironmentKey)
        let bundlePath = result[hostBundlePathEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleID = result[hostBundleIDEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if bundlePath.isEmpty ||
            !isValidOMGHostBundleIdentifier(bundleID) ||
            isEphemeralOrTrashedBundlePath(bundlePath) {
            result.removeValue(forKey: hostBundlePathEnvironmentKey)
            result.removeValue(forKey: hostBundleIDEnvironmentKey)
            result = applyingHostBundleEnvironment(result, bundle: bundle)
        }
        return result
    }

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        if let foreground = parseForeground(arguments: arguments) {
            let parentPID = getppid()
            let updatedEnv = foregroundEnvironment(ProcessInfo.processInfo.environment)
            unsetenv(hostLaunchdLabelEnvironmentKey)
            if let path = updatedEnv[hostBundlePathEnvironmentKey],
               let id = updatedEnv[hostBundleIDEnvironmentKey] {
                setenv(hostBundlePathEnvironmentKey, path, 1)
                setenv(hostBundleIDEnvironmentKey, id, 1)
            } else {
                unsetenv(hostBundlePathEnvironmentKey)
                unsetenv(hostBundleIDEnvironmentKey)
            }
            _exit(runForegroundLifecycle(foreground, initialParentPID: parentPID))
        }

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
