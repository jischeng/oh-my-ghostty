import TermioShared
import TermioStream
import Foundation
import os
import Security
import UIKit

enum PairingStore {
    static var address: String {
        get { UserDefaults.standard.string(forKey: "server") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "server") }
    }
    static var token: String {
        var query = key
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func save(token: String) throws {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = key
            attributes.forEach { entry[$0.key] = $0.value }
            let added = SecItemAdd(entry as CFDictionary, nil)
            guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
        } else if status != errSecSuccess {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
    private static var key: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jischeng.omg.mobile", kSecAttrAccount as String: "pairing"]
    }
}

struct MobileEndpoint: Decodable {
    let id: String
    let name: String
}

struct MobileSession: Decodable {
    let id: String
    let generation: String
    let pid: Int?
    let cwd: String?
    let ended: String?
}

/// The host protocol is unchanged by the LAN pipe. Every attachment starts
/// attach-only, acknowledges its native snapshot, and initially observes.
final class RuntimeConnection {
    static let maximumInput = 1024 * 1024
    enum State { case connecting, attached, disconnected, closed, failed(String) }
    let endpoint: MobileEndpoint
    private let link: WebSocketLink
    private var decoder = RuntimeFrame.Decoder()
    private var watermark = RuntimeWatermark()
    private var attachment = RuntimeAttachment()
    private var heartbeat: Timer?
    private var session: MobileSession?
    private var active = false
    var hasSession: Bool { session != nil }
    var isAttached: Bool { snapshotApplied }
    var supportsWriterTransfer: Bool { transferSupported }
    private var snapshotApplied = false
    private var transferSupported = false
    private var sentViewport: TerminalGrid?
    private var requestedViewport: TerminalGrid?
    private var viewportGeneration: UInt64 = 0
    private var sessionEnded = false
    private(set) var terminal: TermiodStreamTerminal?
    private(set) var isWriter = false
    var onSessions: (([MobileSession]) -> Void)?
    var onChange: (() -> Void)?
    var onState: ((State) -> Void)?
    var onOutput: ((Data) -> Void)?
    var onSignal: ((TermiodStreamTerminal.Signal) -> Void)?
    var onWriterChanged: ((Bool) -> Void)?

    init(base: URL, token: String, endpoint: MobileEndpoint) {
        self.endpoint = endpoint
        let url = base.appendingPathComponent("ws").appendingPathComponent(endpoint.id)
        var config = WebSocketLink.Configuration(name: "omg", url: url)
        config.delegateQueue = .main
        config.maximumMessageSize = RuntimeFrame.maximumPayload + 13
        config.subprotocols = ["omg.\(token)"]
        config.pingRunLoopMode = .common
        link = WebSocketLink(configuration: config)
        link.onConnecting = { [weak self] in
            self?.resetConnection()
            self?.onState?(.connecting)
        }
        link.onOpen = { [weak self] in
            guard let self else { return }
            send(RuntimeFrame(80))
            refresh()
            if let session { open(session) }
        }
        link.onData = { [weak self] data in self?.receive(data) }
        link.onDown = { [weak self] in
            self?.resetConnection()
            self?.onState?(.disconnected)
        }
        link.onForeground = { [weak self] in self?.refresh() }
    }
    func start() {
        guard !active else { return }
        active = true
        link.start()
        heartbeat = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.send(RuntimeFrame(80)) }
        if let heartbeat { RunLoop.main.add(heartbeat, forMode: .common) }
    }
    func stop() {
        active = false
        heartbeat?.invalidate()
        heartbeat = nil
        link.stop()
        resetConnection()
    }
    func refresh() {
        if !active { start() } else { send(RuntimeFrame(76)) }
    }
    func open(_ session: MobileSession) {
        if let previous = attachment.detach() { send(RuntimeFrame(81, previous)) }
        self.session = session
        sessionEnded = false
        snapshotApplied = false
        isWriter = false
        sentViewport = nil
        requestedViewport = nil
        viewportGeneration &+= 1
        terminal = nil
        watermark = RuntimeWatermark()
        let stream = attachment.open()
        let request: [String: String] = ["id": session.id, "generation": session.generation]
        guard let bytes = try? JSONSerialization.data(withJSONObject: request) else { return }
        if !active { start() } else { send(RuntimeFrame(85, stream, bytes)) }
    }
    func detach() {
        if let previous = attachment.detach() { send(RuntimeFrame(81, previous)) }
        session = nil
        snapshotApplied = false
        isWriter = false
        requestedViewport = nil
        sentViewport = nil
        viewportGeneration &+= 1
        terminal = nil
    }
    func claim() {
        guard snapshotApplied else { return }
        inner(RuntimeFrame(87, 0, transferSupported ? Data("takeover/1".utf8) : Data()))
    }
    func resize(_ grid: TerminalGrid) {
        guard isWriter, snapshotApplied, grid != requestedViewport else { return }
        requestedViewport = grid
        viewportGeneration &+= 1
        let generation = viewportGeneration
        if sentViewport == nil {
            sentViewport = grid
            sendResize(grid)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, isWriter, snapshotApplied, generation == viewportGeneration,
                  grid == requestedViewport, grid != sentViewport else { return }
            sentViewport = grid
            sendResize(grid)
        }
    }
    private func sendResize(_ grid: TerminalGrid) {
        let cols = min(grid.cols, 500), rows = min(grid.rows, 300)
        inner(RuntimeFrame(82, 0, Data([UInt8(cols >> 8), UInt8(cols & 255),
                                      UInt8(rows >> 8), UInt8(rows & 255)])))
    }
    func inputBytes(_ data: Data) {
        guard isWriter, snapshotApplied, data.count <= Self.maximumInput else { return }
        inner(RuntimeFrame(73, 0, data))
    }
    private func resetConnection() {
        decoder = RuntimeFrame.Decoder()
        watermark = RuntimeWatermark()
        _ = attachment.detach()
        snapshotApplied = false
        isWriter = false
        sentViewport = nil
        requestedViewport = nil
        viewportGeneration &+= 1
        onChange?()
    }
    private func send(_ frame: RuntimeFrame) {
        guard link.isUp else { return }
        link.send(frame.encoded())
    }
    private func inner(_ frame: RuntimeFrame) {
        guard let stream = attachment.stream else { return }
        send(RuntimeFrame(68, stream, frame.encoded()))
    }
    private func receive(_ data: Data) {
        do {
            for frame in try decoder.append(data) {
                switch frame.kind {
                case 76:
                    onSessions?(try JSONDecoder().decode([MobileSession].self, from: frame.data))
                case 68 where attachment.accepts(frame):
                    var innerDecoder = RuntimeFrame.Decoder()
                    let frames = try innerDecoder.append(frame.data)
                    guard frames.count == 1, frames[0].encoded().count == frame.data.count else {
                        throw RuntimeFrame.Failure.invalidSequence
                    }
                    try receiveInner(frames[0])
                case 69 where frame.sequence == 0 || attachment.accepts(frame):
                    if frame.sequence != 0 {
                        snapshotApplied = false
                        isWriter = false
                        onChange?()
                    }
                    onState?(.failed(String(data: frame.data, encoding: .utf8) ?? "Session error"))
                case 81 where attachment.accepts(frame):
                    snapshotApplied = false
                    isWriter = false
                    onState?(.disconnected)
                    onChange?()
                    if session != nil && !sessionEnded { link.resynchronize() }
                default: break
                }
            }
        } catch {
            resetConnection()
            if let failure = error as? RuntimeFrame.Failure,
               failure == .invalidSequence || failure == .missingSnapshot {
                link.resynchronize()
            } else {
                stop()
                onState?(.failed(error.localizedDescription))
            }
        }
    }
    private func receiveInner(_ frame: RuntimeFrame) throws {
        switch frame.kind {
        case 74:
            let metadata = try JSONSerialization.jsonObject(with: frame.data) as? [String: Any]
            transferSupported = metadata?["writer_transfer"] as? Bool ?? false
        case 83:
            // Regular local sessions are answered by omgd, so this terminal's
            // automatic reports are deliberately not sent back as user input.
            guard let stream = attachment.stream else { throw RuntimeFrame.Failure.invalidSequence }
            terminal = try TermiodStreamTerminal(nativeSnapshot: frame.data, onSignal: { [weak self] signal in
                // Upstream effects run under the VT lock. UI work must wait
                // until write/restore returns and still belong to this stream.
                DispatchQueue.main.async { [weak self] in
                    guard let self, snapshotApplied, attachment.stream == stream else { return }
                    onSignal?(signal)
                }
            })
            watermark.snapshot(frame.sequence)
            snapshotApplied = true
            inner(RuntimeFrame(65, frame.sequence))
            onChange?()
            onState?(.attached)
        case 79:
            try watermark.output(frame)
            terminal?.write(frame.data)
            onOutput?(frame.data)
            onChange?()
        case 71:
            guard watermark.position == frame.sequence else { throw RuntimeFrame.Failure.invalidSequence }
        case 82:
            guard frame.data.count == 4 || frame.data.count == 8 else { throw RuntimeFrame.Failure.invalidSequence }
            let cols = UInt16(frame.data[0]) << 8 | UInt16(frame.data[1])
            let rows = UInt16(frame.data[2]) << 8 | UInt16(frame.data[3])
            try terminal?.resize(rows: rows, cols: cols, reflow: true)
            onChange?()
        case 87:
            isWriter = true
            onChange?()
            onWriterChanged?(true)
        case 66:
            isWriter = false
            onWriterChanged?(false)
            sentViewport = nil
            requestedViewport = nil
            viewportGeneration &+= 1
            onChange?()
        case 88:
            isWriter = false
            snapshotApplied = false
            sessionEnded = true
            onState?(.closed)
            onChange?()
        default: break
        }
    }
}
