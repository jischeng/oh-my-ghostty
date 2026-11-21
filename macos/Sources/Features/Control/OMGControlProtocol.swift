import Foundation

/// Wire contract of OMG's local control plane, shared by the app's listener
/// and the `omg +edit` / `omg +view` client: JSON-RPC 2.0 over a Unix stream
/// socket, one JSON object per line.
enum OMGControlProtocol {
    static let version = "2.0"
    /// A frame is one request or response line, excluding its newline.
    static let maximumFrameBytes = 1 << 20

    enum Method: String, Sendable {
        case editorOpen = "editor.open"
        case viewerOpen = "viewer.open"
    }
}

/// Where a channel's control socket lives. Release and each Dev channel
/// listen separately, so a pane always reaches the app that owns it.
enum OMGControlSocketPath {
    /// Darwin's `sockaddr_un.sun_path` holds 104 bytes including the NUL.
    static let maximumPathBytes = 103

    static let knownChannels = ["release", "debug", "debug-workspace", "debug-pty"]

    static func normalizedChannel(_ channel: String?) -> String {
        guard let channel, knownChannels.contains(channel) else { return "release" }
        return channel
    }

    /// Mirrors `OMGApplicationEnvironment.applicationSupportURL`, keyed by the
    /// channel a pane reports in `OH_MY_GHOSTTY_CHANNEL`.
    static func supportDirectoryName(channel: String) -> String {
        switch normalizedChannel(channel) {
        case "debug": "OMG Dev"
        case "debug-workspace": "OMG Dev Workspace"
        case "debug-pty": "OMG Dev PTY"
        default: "OMG"
        }
    }

    /// `<Application Support>/<OMG channel>/control/v1.sock`. A home directory
    /// long enough to overflow `sun_path` uses a per-user directory directly
    /// under sticky `/tmp` instead; both ends derive the same answer from the
    /// same inputs.
    static func path(
        channel: String = OMGApplicationEnvironment.channel(),
        applicationSupportBase: URL? = nil,
        uid: uid_t = getuid()
    ) -> String {
        let channel = normalizedChannel(channel)
        let base = applicationSupportBase ?? FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let primary = base
            .appendingPathComponent(supportDirectoryName(channel: channel), isDirectory: true)
            .appendingPathComponent("control", isDirectory: true)
            .appendingPathComponent("v1.sock")
            .path
        if primary.utf8.count <= maximumPathBytes { return primary }
        return "/tmp/omg-control-\(uid)-\(channel)/v1.sock"
    }
}

/// A JSON-RPC request ID: clients may send a number or a string.
enum OMGControlID: Codable, Equatable, Sendable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// Parameters of `editor.open` and `viewer.open`.
struct OMGControlOpenParams: Codable, Equatable, Sendable {
    /// A file path, optionally with a `:line[:column]` suffix; relative paths
    /// resolve against `cwd`. `viewer.open` also accepts an http(s) URL.
    var path: String
    /// The caller's absolute working directory.
    var cwd: String
    /// `OMG_PANE_ID` of the calling pane, when the caller runs inside one.
    var pane: String?
    /// `OH_MY_GHOSTTY_SESSION` of the calling tab; the fallback for `pane`.
    var tab: String?
    /// `current`, `tab`, `right`, `down`, `left`, or `up`. nil follows the
    /// user's editor open-destination setting.
    var destination: String?
    /// Reply only once the opened document is closed.
    var wait: Bool?
}

struct OMGControlRequest: Codable, Equatable, Sendable {
    var jsonrpc = OMGControlProtocol.version
    var id: OMGControlID
    var method: String
    var params: OMGControlOpenParams

    func frame() throws -> Data {
        try OMGControlFrame.encode(self)
    }
}

struct OMGControlError: Codable, Equatable, Sendable, Error {
    let code: Int
    let message: String

    static func parseError(_ message: String = "Invalid JSON") -> Self { .init(code: -32_700, message: message) }
    static func invalidRequest(_ message: String) -> Self { .init(code: -32_600, message: message) }
    static func methodNotFound(_ method: String) -> Self {
        .init(code: -32_601, message: "Unknown method `\(method)`")
    }
    static func invalidParams(_ message: String) -> Self { .init(code: -32_602, message: message) }
    /// The request was valid but OMG could not carry it out.
    static func failed(_ message: String) -> Self { .init(code: -32_000, message: message) }
}

struct OMGControlResponse: Codable, Equatable, Sendable, Error {
    var jsonrpc = OMGControlProtocol.version
    /// nil only when the request's own ID could not be read.
    var id: OMGControlID?
    var result: [String: String]?
    var error: OMGControlError?

    static func success(_ id: OMGControlID, _ result: [String: String]) -> Self {
        .init(id: id, result: result, error: nil)
    }

    static func failure(_ id: OMGControlID?, _ error: OMGControlError) -> Self {
        .init(id: id, result: nil, error: error)
    }

    func frame() -> Data {
        (try? OMGControlFrame.encode(self)) ?? Data(
            #"{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"Internal error"}}"#.utf8
        )
    }
}

enum OMGControlFrame {
    struct TooLarge: Error {}

    /// One compact JSON line. JSONEncoder escapes control characters, so the
    /// encoding never contains a raw newline.
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= OMGControlProtocol.maximumFrameBytes else { throw TooLarge() }
        return data
    }

    /// The method named by a request frame plus enough to answer it, or the
    /// error response to send back.
    static func decodeRequest(_ frame: Data) -> Result<OMGControlRequest, OMGControlResponse> {
        struct Envelope: Decodable {
            let jsonrpc: String?
            let id: OMGControlID?
            let method: String?
        }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: frame) else {
            return .failure(.failure(nil, .parseError()))
        }
        guard envelope.jsonrpc == OMGControlProtocol.version else {
            return .failure(.failure(envelope.id, .invalidRequest("Expected JSON-RPC 2.0")))
        }
        guard let id = envelope.id else {
            return .failure(.failure(nil, .invalidRequest("A request needs an id")))
        }
        guard let method = envelope.method else {
            return .failure(.failure(id, .invalidRequest("A request needs a method")))
        }
        guard OMGControlProtocol.Method(rawValue: method) != nil else {
            return .failure(.failure(id, .methodNotFound(method)))
        }
        do {
            return .success(try JSONDecoder().decode(OMGControlRequest.self, from: frame))
        } catch {
            return .failure(.failure(id, .invalidParams("Expected params with `path` and `cwd` strings")))
        }
    }
}

/// Splits a byte stream into newline-terminated frames and refuses a frame
/// larger than the protocol limit instead of buffering it.
struct OMGControlLineFramer {
    private var buffer = Data()

    mutating func append(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            guard line.count <= OMGControlProtocol.maximumFrameBytes else { throw OMGControlFrame.TooLarge() }
            if !line.isEmpty { frames.append(Data(line)) }
            buffer = Data(buffer[buffer.index(after: newline)...])
        }
        guard buffer.count <= OMGControlProtocol.maximumFrameBytes else { throw OMGControlFrame.TooLarge() }
        return frames
    }
}

/// POSIX plumbing shared by the listener and the client.
enum OMGControlSocket {
    static func address(path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= OMGControlSocketPath.maximumPathBytes,
              !bytes.contains(0) else { return nil }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }

    /// A connected stream socket, or nil when nothing is listening at `path`.
    static func connect(path: String) -> Int32? {
        guard var address = address(path: path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard status == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    /// Only this user's processes may talk to the control plane.
    static func peerIsCurrentUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }
}
