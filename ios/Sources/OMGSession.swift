import Foundation
import TermioShared
import TermioStream

/// The full upstream terminal screen uses this port without knowing omgd's framing.
///
/// Attachments start as passive read-only observers (`RuntimeWriterGate`): opening or
/// foregrounding a session, rotating the phone, or toggling the keyboard while viewing
/// NEVER sends `takeover/1` or shrinks the desktop terminal. Writer transfer and the
/// 8-byte pixel `'R'` resize occur ONLY when the user sends input/paste or explicitly
/// triggers `takeover()`.
final class OMGSession: StreamDeviceSession {
    static let activityDidChange = Notification.Name("OMGSessionActivityDidChange")
    static let generationDidChange = Notification.Name("OMGSessionGenerationDidChange")

    var onOutput: ((Data) -> Void)?
    var onState: ((DeviceSessionState) -> Void)?
    var onSharedGrid: ((TerminalGrid, Bool) -> Void)?
    var onStreaming: ((Bool) -> Void)?
    var onStreamSignal: ((TermiodStreamTerminal.Signal) -> Void)?
    var onStreamData: ((Data) -> Void)?
    var streamTerminal: TermiodStreamTerminal? { connection?.terminal }
    @MainActor var prefersStreamPlane: Bool { TermiodStreamRenderer.isAvailable }

    private var connection: RuntimeConnection?
    private let routeID: String
    private var activeRouteID: String
    private let targetID: String?
    private var generation: String?
    private(set) var liveActivity: RuntimeActivitySnapshot?
    private var writerGate = RuntimeWriterGate()
    private var inputRejected = false
    private var theme: TermiodStreamTerminal.Theme?
    private var terminalIdentity: ObjectIdentifier?
    private var lastGrid: TerminalGrid?
    private var lastWriter: Bool?

    init(endpoint: DeviceEndpoint, sessionID: String) {
        routeID = sessionID
        activeRouteID = sessionID
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
                    $0.id == self.targetID
                        && $0.generation == self.generation
                        && MobileSessionRoute.isAttachableEndedState($0.ended)
                }) else {
                    self.onState?(.failed("The session is no longer running."))
                    return
                }
                connection.open(session)
            }
            connection.onGenerationChanged = { [weak self] nextGeneration in
                guard let self else { return }
                let previous = self.activeRouteID
                let nextRoute = route.replacingGeneration(nextGeneration)
                self.generation = nextGeneration
                self.activeRouteID = nextRoute
                NotificationCenter.default.post(
                    name: Self.generationDidChange,
                    object: nil,
                    userInfo: ["oldSessionID": previous, "newSessionID": nextRoute]
                )
            }
            connection.onChange = { [weak self] in self?.changed() }
            connection.onOutput = { [weak self] data in self?.onStreamData?(data) }
            connection.onActivity = { [weak self, weak connection] snapshot in
                guard let self else { return }
                self.liveActivity = snapshot
                if RuntimeActivityAckPolicy.shouldAcknowledgeOnActivity(
                    rendering: self.writerGate.isRendering,
                    snapshot: snapshot
                ) {
                    connection?.acknowledge()
                }
                NotificationCenter.default.post(
                    name: Self.activityDidChange,
                    object: nil,
                    userInfo: ["sessionID": self.activeRouteID, "snapshot": snapshot]
                )
            }
            connection.onSignal = { [weak self] signal in self?.onStreamSignal?(signal) }
            connection.onWriterChanged = { [weak self, weak connection] granted in
                guard let self, let connection else { return }
                let effects = self.writerGate.writerChanged(granted)
                self.apply(effects, on: connection)
                if granted {
                    self.inputRejected = false
                    self.onState?(.connected)
                } else {
                    self.onState?(.readOnly(connection.supportsWriterTransfer
                        ? "另一终端正在操作，键入即可接管。"
                        : "此 runtime 不支持输入权交接，请使用新版 runtime 创建的会话。"))
                }
            }
            connection.onState = { [weak self] state in
                guard let self else { return }
                switch state {
                case .attached:
                    onState?(.connected)
                case .connecting:
                    writerGate.didDetach()
                    onState?(.connecting)
                case .disconnected:
                    writerGate.didDetach()
                    onState?(.reconnecting)
                case .closed:
                    writerGate.didDetach()
                    onState?(.closed)
                case .failed(let reason):
                    writerGate.didDetach()
                    onState?(.failed(reason))
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
        writerGate.didDetach()
        connection?.stop()
    }

    func send(_ data: Data) {
        send(data, acknowledgesActivity: true)
    }

    func send(_ data: Data, acknowledgesActivity: Bool) {
        guard let connection, connection.isAttached, !data.isEmpty else { return }
        if !writerGate.isAttached {
            _ = writerGate.didAttach()
        }
        let shouldAcknowledge = RuntimeActivityAckPolicy.shouldAcknowledgeOnInput(
            data,
            acknowledgesActivity: acknowledgesActivity,
            liveActivity: liveActivity
        )
        switch writerGate.enqueueInput(data, maximumBytes: RuntimeConnection.maximumInput) {
        case .failure(.inputLimitExceeded):
            inputRejected = true
            onState?(.readOnly("Input exceeds the 1 MiB limit."))
        case .success(let effects):
            if connection.isWriter, inputRejected {
                inputRejected = false
                onState?(.connected)
            }
            if shouldAcknowledge {
                connection.acknowledge()
            }
            apply(effects, on: connection)
        }
    }

    func sendInput(_ event: Termiod.InputEvent) {
        guard let terminal = streamTerminal else { return }
        // Focus reports, passive wheel scrolling, passive pointer motion/release,
        // and orphan key releases are not user input and cannot claim the writer token.
        switch event {
        case .focus:
            return
        case .wheel where !writerGate.isWriter && writerGate.pendingInput.isEmpty:
            return
        case .mouse(let mouse) where !writerGate.isWriter && mouse.action != .press:
            return
        case .key(let key) where !writerGate.isWriter && writerGate.pendingInput.isEmpty && key.action == .release:
            return
        default:
            break
        }
        guard event.shouldForwardToRuntimeSession(
            isWriter: writerGate.isWriter,
            hasPendingInput: !writerGate.pendingInput.isEmpty
        ) else { return }
        if let bytes = try? terminal.encodeInput(event) {
            send(bytes, acknowledgesActivity: event.acknowledgesActivity)
        }
    }

    func takeover() {
        guard let connection, connection.isAttached else { return }
        if !writerGate.isAttached {
            _ = writerGate.didAttach()
        }
        apply(writerGate.requestTakeover(), on: connection)
    }

    func sendDeviceReport(_ data: Data) {
        // omgd owns query answers; neither an observer nor a writer duplicates them.
    }

    func setViewport(columns: Int, rows: Int) {
        setViewport(columns: columns, rows: rows, pixelWidth: 0, pixelHeight: 0)
    }

    func setViewport(columns: Int, rows: Int, pixelWidth: Int, pixelHeight: Int) {
        let next = RuntimeViewport.clamped(
            columns: columns,
            rows: rows,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        let effects = writerGate.setViewport(next)
        if let connection {
            apply(effects, on: connection)
        }
    }

    func noteSurfaceGrid(columns: Int, rows: Int) {
        // A decoded native snapshot is already authoritative; no keyframe is needed.
    }

    func setRendering(_ showing: Bool) {
        let effects = writerGate.setRendering(showing)
        guard showing, let connection else { return }
        if RuntimeActivityAckPolicy.shouldAcknowledgeOnBecomeVisible(
            isAttached: connection.isAttached,
            liveActivity: liveActivity
        ) {
            connection.acknowledge()
        }
        apply(effects, on: connection)
        changed()
    }

    func reassertGrid() {
        if let connection {
            apply(writerGate.reassertGrid(), on: connection)
        }
        changed()
    }

    func setStreamTheme(_ theme: TermiodStreamTerminal.Theme) {
        self.theme = theme
        try? streamTerminal?.setTheme(theme)
    }

    func setHostAnswers(_ answers: Termiod.HostAnswers) {
        // Existing omgd answers probes in its own VT, including while detached.
    }

    private func apply(_ effects: [RuntimeWriterGate.Effect], on connection: RuntimeConnection) {
        for effect in effects {
            switch effect {
            case .claimWriter:
                connection.claim()
            case .sendInput(let bytes):
                connection.inputBytes(bytes)
            case .sendResize(let viewport):
                connection.resize(viewport)
            }
        }
    }

    private func changed() {
        guard let connection else { return }
        guard connection.isAttached else {
            writerGate.didDetach()
            lastWriter = nil
            return
        }
        if !writerGate.isAttached {
            _ = writerGate.didAttach()
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
    }
}
