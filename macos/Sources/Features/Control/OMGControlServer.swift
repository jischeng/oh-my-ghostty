import Foundation
import OSLog

/// One accepted control-plane client. All socket work happens on the
/// server's serial queue; `send`, `close` and `onClose` are safe from any
/// thread.
final class OMGControlConnection: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private var source: DispatchSourceRead?
    private var framer = OMGControlLineFramer()
    private var closeHandlers: [@Sendable () -> Void] = []
    private var isClosed = false

    fileprivate init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
    }

    /// Queue-confined. `receive` gets each complete frame; `finished` runs
    /// once after the peer hangs up or the connection is closed.
    fileprivate func resume(
        receive: @escaping (Data, OMGControlConnection) -> Void,
        finished: @escaping (OMGControlConnection) -> Void
    ) {
        let descriptor = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EAGAIN || errno == EINTR { return }
            guard count > 0, let frames = try? self.framer.append(Data(buffer[..<count])) else {
                // End of stream, a read error, or an oversized frame.
                self.closeOnQueue()
                return
            }
            for frame in frames where !self.isClosed { receive(frame, self) }
        }
        // Strong on purpose: the close handlers must run even when the server
        // has already dropped this connection. Cancellation ends the cycle.
        source.setCancelHandler { [self] in
            Darwin.close(descriptor)
            let handlers = closeHandlers
            closeHandlers = []
            handlers.forEach { $0() }
            finished(self)
        }
        self.source = source
        source.resume()
    }

    /// Queue-confined.
    fileprivate func closeOnQueue() {
        guard !isClosed else { return }
        isClosed = true
        source?.cancel()
        source = nil
    }

    /// Writes one frame. A peer that cannot take a small reply is dropped.
    func send(_ frame: Data) {
        queue.async { [self] in
            guard !isClosed else { return }
            if !OMGControlSocket.writeAll(fd, frame + [0x0A]) { closeOnQueue() }
        }
    }

    func close() {
        queue.async { [self] in closeOnQueue() }
    }

    /// Runs `handler` once the connection ends; immediately if it already has.
    func onClose(_ handler: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if isClosed { handler() } else { closeHandlers.append(handler) }
        }
    }
}

/// Listens on a private Unix socket and hands each request frame to a
/// handler. The socket's directory is owner-only, the socket is 0600, and a
/// peer running as another user is dropped before any byte is read.
final class OMGControlServer: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case pathTooLong
        case notPrivate
        case alreadyListening
        case system(Int32)
    }

    typealias Handler = @Sendable (Data, OMGControlConnection) -> Void

    static let maximumConnections = 64
    private static let logger = Logger(subsystem: "com.jischeng.omg", category: "control")

    private let queue = DispatchQueue(label: "com.jischeng.omg.control")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ObjectIdentifier: OMGControlConnection] = [:]
    private var boundPath: String?

    deinit {
        if let boundPath { unlink(boundPath) }
        acceptSource?.cancel()
    }

    /// Binds `path` and starts accepting. Throws without disturbing a live
    /// listener that another instance of this channel already owns.
    func start(path: String, handler: @escaping Handler) throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            guard var address = OMGControlSocket.address(path: path) else { throw Failure.pathTooLong }
            try Self.preparePrivateDirectory(for: path)
            try Self.removeStaleSocket(at: path)

            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.system(errno) }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0,
                  fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
                let code = errno
                close(fd)
                if bound == 0 { unlink(path) }
                throw Failure.system(code)
            }

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending(handler) }
            source.setCancelHandler { close(fd) }
            listenFD = fd
            boundPath = path
            acceptSource = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            listenFD = -1
            if let boundPath { unlink(boundPath) }
            boundPath = nil
            for connection in connections.values { connection.closeOnQueue() }
            connections.removeAll()
        }
    }

    private func acceptPending(_ handler: @escaping Handler) {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            guard OMGControlSocket.peerIsCurrentUser(fd), connections.count < Self.maximumConnections else {
                close(fd)
                continue
            }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var enabled: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            let connection = OMGControlConnection(fd: fd, queue: queue)
            connections[ObjectIdentifier(connection)] = connection
            connection.resume(receive: handler) { [weak self] finished in
                self?.connections.removeValue(forKey: ObjectIdentifier(finished))
            }
        }
    }

    /// The socket's directory must belong to this user alone. A directory
    /// someone else created first, or one others can enter, is refused.
    private static func preparePrivateDirectory(for path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try SessionRuntimeBridgeStorage.ensurePrivateDirectory(directory)
        } catch {
            logger.error("control socket directory is not private: \(error.localizedDescription, privacy: .public)")
            throw Failure.notPrivate
        }
    }

    /// A socket left by a crashed instance is replaced; one that still
    /// answers belongs to a running instance and is left alone.
    private static func removeStaleSocket(at path: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else { throw Failure.notPrivate }
        if let fd = OMGControlSocket.connect(path: path) {
            close(fd)
            throw Failure.alreadyListening
        }
        guard unlink(path) == 0 else { throw Failure.system(errno) }
    }
}
