import Foundation
import TermioShared
import TermioStream

/// The full upstream terminal screen uses this port without knowing omgd's framing.
final class OMGSession: StreamDeviceSession {
    var onOutput: ((Data) -> Void)?
    var onState: ((DeviceSessionState) -> Void)?
    var onSharedGrid: ((TerminalGrid, Bool) -> Void)?
    var onStreaming: ((Bool) -> Void)?
    var onStreamSignal: ((TermiodStreamTerminal.Signal) -> Void)?
    var onStreamData: ((Data) -> Void)?
    var streamTerminal: TermiodStreamTerminal? { connection?.terminal }

    private var connection: RuntimeConnection?
    private let targetID: String?
    private let generation: String?
    private var pending = Data()
    private var claiming = false
    private var needsAutoClaim = true
    private var inputRejected = false
    private var rendering = true
    private var theme: TermiodStreamTerminal.Theme?
    private var terminalIdentity: ObjectIdentifier?
    private var viewport: TerminalGrid?
    private var lastGrid: TerminalGrid?
    private var lastWriter = false

    init(endpoint: DeviceEndpoint, sessionID: String) {
        let route = MobileSessionRoute(sessionID)
        targetID = route?.sessionID
        generation = route?.generation
        if let route, let token = endpoint.token {
            let connection = RuntimeConnection(base: endpoint.url, token: token,
                endpoint: MobileEndpoint(id: route.endpointID, name: "OMG"))
            self.connection = connection
            connection.onSessions = { [weak self, weak connection] sessions in
                guard let self, let connection, !connection.hasSession else { return }
                guard let session = sessions.first(where: {
                    $0.id == self.targetID && $0.generation == self.generation && $0.ended == nil
                }) else {
                    self.onState?(.failed("The session is no longer running."))
                    return
                }
                connection.open(session)
            }
            connection.onChange = { [weak self] in self?.changed() }
            connection.onOutput = { [weak self] data in self?.onStreamData?(data) }
            connection.onSignal = { [weak self] signal in self?.onStreamSignal?(signal) }
            connection.onWriterChanged = { [weak self, weak connection] granted in
                guard let self, let connection else { return }
                if granted {
                    onState?(.connected)
                } else {
                    discardPending()
                    onState?(.readOnly(connection.supportsWriterTransfer
                        ? "另一终端正在操作，键入即可接管。"
                        : "此 runtime 不支持输入权交接，请使用新版 runtime 创建的会话。"))
                }
            }
            connection.onState = { [weak self] state in
                guard let self else { return }
                switch state {
                case .attached: onState?(.connected)
                case .connecting: discardPending(); onState?(.connecting)
                case .disconnected: discardPending(); onState?(.reconnecting)
                case .closed: discardPending(); onState?(.closed)
                case .failed(let reason): discardPending(); onState?(.failed(reason))
                }
            }
        }
    }

    func start() {
        guard let connection else { onState?(.failed("Invalid OMG session identity.")); return }
        onState?(.connecting)
        connection.start()
    }

    func stop() {
        discardPending()
        connection?.stop()
    }

    func send(_ data: Data) {
        guard let connection, connection.isAttached, !data.isEmpty else { return }
        guard data.count <= RuntimeConnection.maximumInput,
              pending.count + data.count <= RuntimeConnection.maximumInput else {
            discardPending()
            inputRejected = true
            onState?(.readOnly("Input exceeds the 1 MiB limit."))
            return
        }
        if connection.isWriter {
            if inputRejected { inputRejected = false; onState?(.connected) }
            connection.inputBytes(data)
        } else {
            pending.append(data)
            if !claiming {
                claiming = true
                connection.claim()
            }
        }
    }

    func sendInput(_ event: Termiod.InputEvent) {
        guard let terminal = streamTerminal else { return }
        // Encoding uses the exact VT modes of this attachment. Query/focus
        // reports are not user input and cannot take the writer token.
        if case .focus = event { return }
        if let bytes = try? terminal.encodeInput(event) { send(bytes) }
    }

    func sendDeviceReport(_ data: Data) {
        // omgd owns query answers; neither an observer nor a writer duplicates them.
    }

    func setViewport(columns: Int, rows: Int) {
        let next = TerminalGrid(rows: UInt16(clamping: rows), cols: UInt16(clamping: columns))
        let viewportChanged = viewport != next
        viewport = next
        guard rendering, let connection, connection.isAttached else { return }
        if connection.isWriter {
            connection.resize(next)
        } else if (needsAutoClaim || viewportChanged), !claiming {
            needsAutoClaim = false
            claiming = true
            connection.claim()
        }
    }

    func noteSurfaceGrid(columns: Int, rows: Int) {
        // A decoded native snapshot is already authoritative; no keyframe is needed.
    }

    func setRendering(_ showing: Bool) {
        let becameVisible = !rendering && showing
        rendering = showing
        if becameVisible {
            needsAutoClaim = true
            changed()
        }
    }

    func reassertGrid() {
        needsAutoClaim = true
        changed()
    }

    func setStreamTheme(_ theme: TermiodStreamTerminal.Theme) {
        self.theme = theme
        try? streamTerminal?.setTheme(theme)
    }

    func setHostAnswers(_ answers: Termiod.HostAnswers) {
        // Existing omgd answers probes in its own VT, including while detached.
    }

    private func discardPending() {
        pending.resetBytes(in: pending.indices)
        pending.removeAll()
        claiming = false
    }

    private func changed() {
        guard let connection else { return }
        if !connection.isAttached {
            discardPending()
            return
        }
        if let terminal = streamTerminal {
            let identity = ObjectIdentifier(terminal)
            if identity != terminalIdentity {
                terminalIdentity = identity
                if let theme { try? terminal.setTheme(theme) }
                onStreaming?(true)
            }
            let size = terminal.grid
            let grid = TerminalGrid(rows: size.rows, cols: size.cols)
            if grid != lastGrid || connection.isWriter != lastWriter {
                lastGrid = grid
                lastWriter = connection.isWriter
                onSharedGrid?(grid, connection.isWriter)
            }
        }
        if connection.isWriter {
            needsAutoClaim = false
            if !pending.isEmpty { connection.inputBytes(pending) }
            discardPending()
            if rendering, let viewport { connection.resize(viewport) }
        } else if rendering, needsAutoClaim {
            needsAutoClaim = false
            if !claiming {
                claiming = true
                connection.claim()
            }
        }
    }
}
