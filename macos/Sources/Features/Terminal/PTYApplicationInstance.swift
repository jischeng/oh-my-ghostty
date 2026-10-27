import AppKit
import Darwin

/// The PTY experiment can be launched both from Finder and directly by its
/// relay script. Both must own the same profile for the whole GUI lifetime,
/// before AppDelegate loads any workspace catalog or restoration state.
final class PTYApplicationInstance {
    private let descriptor: Int32

    enum Failure: Error {
        case alreadyRunning
        case system(Int32)
    }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appendingPathComponent("gui-instance.lock").path
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_EXLOCK | O_NONBLOCK, 0o600)
        guard fd >= 0 else {
            let code = errno
            if code == EWOULDBLOCK { throw Failure.alreadyRunning }
            throw Failure.system(code)
        }
        descriptor = fd
    }

    deinit {
        // Do not unlink the lock: another process may already have opened its
        // inode. Closing the last descriptor releases the advisory lock.
        Darwin.close(descriptor)
    }

    @MainActor
    static func acquireForCurrentApplication() throws -> PTYApplicationInstance? {
        guard OMGApplicationEnvironment.isPTYDevelopment else { return nil }
        let lease = try PTYApplicationInstance(directory: OMGApplicationEnvironment.applicationSupportURL())
        // Upgrade compatibility: an older GUI does not take the lock yet.
        let existing = NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.jischeng.omg.debug.pty"
        ).contains {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated
        }
        guard !existing else { throw Failure.alreadyRunning }
        return lease
    }
}
