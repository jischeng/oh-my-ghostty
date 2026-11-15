import Darwin
import Foundation

/// Writes OMG private configuration and cache files atomically with `0700`
/// parent directories and `0600` file permissions so user settings and cached
/// session metadata are never exposed world-readable at rest or during staging.
enum OMGPrivateFileWriter {
    enum WriteError: LocalizedError {
        case unsafePath
        case createFailed
        case renameFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .unsafePath:
                "Refusing to write private file through a symbolic link."
            case .createFailed:
                "Could not create private temporary file."
            case .renameFailed(let code):
                String(cString: strerror(code))
            }
        }
    }

    private static func isSymbolicLink(at path: String) -> Bool {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func writeAtomically(
        _ data: Data,
        to fileURL: URL,
        permissions: mode_t = 0o600
    ) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        for candidate in [directory, fileURL] {
            guard !isSymbolicLink(at: candidate.path) else {
                throw WriteError.unsafePath
            }
        }

        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard !isSymbolicLink(at: directory.path), !isSymbolicLink(at: fileURL.path) else {
            throw WriteError.unsafePath
        }
        let canonicalDirectory = directory.resolvingSymlinksInPath().path
        if canonicalDirectory != "/",
           canonicalDirectory != "/tmp",
           canonicalDirectory != "/private/tmp" {
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? manager.removeItem(at: temporary) }

        let safeMode = permissions & 0o777
        let fd = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            safeMode
        )
        guard fd >= 0 else {
            throw WriteError.createFailed
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                var offset = 0
                while offset < rawBuffer.count {
                    let count = Darwin.write(
                        fd,
                        base.advanced(by: offset),
                        rawBuffer.count - offset
                    )
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    offset += count
                }
            }
            _ = Darwin.fchmod(fd, safeMode)
            Darwin.close(fd)
        } catch {
            Darwin.close(fd)
            throw error
        }

        guard !isSymbolicLink(at: fileURL.path) else {
            throw WriteError.unsafePath
        }
        guard Darwin.rename(temporary.path, fileURL.path) == 0 else {
            throw WriteError.renameFailed(errno)
        }
    }

    static func tightenPermissionsIfPresent(at fileURL: URL) {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        var dirStat = stat()
        if Darwin.lstat(directory.path, &dirStat) == 0,
           (dirStat.st_mode & S_IFMT) == S_IFDIR {
            let canonicalDirectory = directory.resolvingSymlinksInPath().path
            if canonicalDirectory != "/",
               canonicalDirectory != "/tmp",
               canonicalDirectory != "/private/tmp" {
                try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            }
        }
        var fileStat = stat()
        if Darwin.lstat(fileURL.path, &fileStat) == 0,
           (fileStat.st_mode & S_IFMT) == S_IFREG {
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }
}
