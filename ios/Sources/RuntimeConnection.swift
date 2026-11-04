import Foundation
import os
import Security
import UIKit

enum Log {
    static let device = Logger(subsystem: "com.jischeng.omg.mobile", category: "terminal")
    static let companion = Logger(subsystem: "com.jischeng.omg.mobile", category: "network")
}

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
    let endpoint: MobileEndpoint
    private let link: WebSocketLink
    private var decoder = RuntimeFrame.Decoder()
    private var watermark = RuntimeWatermark()
    private var attachment = RuntimeAttachment()
    private var heartbeat: Timer?
    private var session: MobileSession?
    private var active = false
    var hasSession: Bool { session != nil }
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
    var onStatus: ((String) -> Void)?

    init(base: URL, token: String, endpoint: MobileEndpoint) {
        self.endpoint = endpoint
        let url = base.appendingPathComponent("ws").appendingPathComponent(endpoint.id)
        var config = WebSocketLink.Configuration(name: "omg", url: url)
        config.delegateQueue = .main
        config.maximumMessageSize = RuntimeFrame.maximumPayload + 13
        config.subprotocols = ["omg.\(token)"]
        config.pingRunLoopMode = .common
        link = WebSocketLink(configuration: config)
        link.onConnecting = { [weak self] in self?.resetConnection(); self?.onStatus?("正在连接…") }
        link.onOpen = { [weak self] in
            guard let self else { return }
            send(RuntimeFrame(80))
            refresh()
            if let session { open(session) }
        }
        link.onData = { [weak self] data in self?.receive(data) }
        link.onDown = { [weak self] in self?.resetConnection(); self?.onStatus?("连接中断，正在重连…") }
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
        // Same 150 ms settled-viewport rule as Termio's TermiodSession: keyboard
        // animations must not become a burst of SIGWINCH and TUI repaints.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
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
    func input(_ event: Termiod.InputEvent) {
        // Requiring a writer acknowledgement avoids replaying taps after reconnect.
        guard isWriter, snapshotApplied, let terminal else { return }
        if case .paste(let text, _) = event, text.utf8.count > 64 * 1024 {
            onStatus?("单次粘贴最多 64 KiB，请分段粘贴。")
            return
        }
        do {
            let data = try terminal.encodeInput(event)
            if !data.isEmpty { inner(RuntimeFrame(73, 0, data)) }
        } catch { onStatus?("输入编码失败：\(error.localizedDescription)") }
    }
    private func resetConnection() {
        decoder = RuntimeFrame.Decoder()
        watermark = RuntimeWatermark()
        attachment = RuntimeAttachment()
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
                    if frame.sequence != 0 { snapshotApplied = false; isWriter = false; onChange?() }
                    onStatus?(String(data: frame.data, encoding: .utf8) ?? "无法读取会话错误")
                case 81 where attachment.accepts(frame):
                    snapshotApplied = false
                    isWriter = false
                    onStatus?("会话连接已结束")
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
                onStatus?("正在重新同步会话…")
            } else {
                stop()
                onStatus?("无法恢复终端状态：\(error.localizedDescription)")
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
            terminal = try TermiodStreamTerminal(nativeSnapshot: frame.data)
            watermark.snapshot(frame.sequence)
            snapshotApplied = true
            inner(RuntimeFrame(65, frame.sequence))
            onStatus?("正在查看 · 点击“接管”后操作")
            onChange?()
        case 79:
            try watermark.output(frame)
            terminal?.write(frame.data)
            onChange?()
        case 82:
            guard frame.data.count == 4 || frame.data.count == 8 else { throw RuntimeFrame.Failure.invalidSequence }
            let cols = UInt16(frame.data[0]) << 8 | UInt16(frame.data[1])
            let rows = UInt16(frame.data[2]) << 8 | UInt16(frame.data[3])
            try terminal?.resize(rows: rows, cols: cols, reflow: true)
            onChange?()
        case 87:
            isWriter = true
            onStatus?("正在操作 · Mac 可重新接管")
            onChange?()
        case 66:
            isWriter = false
            sentViewport = nil
            requestedViewport = nil
            viewportGeneration &+= 1
            onStatus?(transferSupported ? "输入权已交给其他终端 · 可再次接管" : "此 runtime 版本不支持交接输入权")
            onChange?()
        case 88:
            isWriter = false
            snapshotApplied = false
            sessionEnded = true
            onStatus?("进程已退出：\(String(data: frame.data, encoding: .utf8) ?? "?")")
            onChange?()
        case 69:
            onStatus?(String(data: frame.data, encoding: .utf8) ?? "无法读取会话错误")
        default: break
        }
    }
}
