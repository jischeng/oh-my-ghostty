import CryptoKit
import Darwin
import Foundation

/// OpenSSH owns connection/channel lifetimes and expires idle masters after
/// 60 seconds. A private socket namespace prevents sharing an interactive
/// terminal's master or reusing a connection with different routing options.
enum GitSSHControlSocket {
    private static let session = UUID().uuidString

    static func path(for connection: GitSSHConnection, executablePath: String) throws -> String {
        // Darwin's Unix socket paths are limited to 104 bytes; the normal
        // per-user temporary directory can consume almost all of that space.
        let directory = "/tmp/omg-git-\(getuid())"
        guard mkdir(directory, 0o700) == 0 || errno == EEXIST else {
            throw GitExecutionError.executionFailed("Cannot create the SSH connection directory.")
        }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else {
            throw GitExecutionError.executionFailed("The SSH connection directory must be private and owned by this user.")
        }
        let identity = session + "\0" + executablePath + "\0" + connection.identity
        let digest = SHA256.hash(data: Data(identity.utf8)).prefix(20)
            .map { String(format: "%02x", $0) }.joined()
        return directory + "/" + digest
    }
}
