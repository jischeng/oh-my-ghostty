import Foundation

/// The versioned wire contract between Ghostty and an out-of-process plugin.
enum PluginProtocolContract {
    static let currentVersion: UInt16 = 1
    static let maximumFrameLength = 1_048_576
}

enum PluginCapability: String, Codable, CaseIterable, Sendable {
    case terminalEvents
    case sessionStatus
    case tabIcon
    case tabMetadata
    case commands
    case settingsContribution
    case inspectorPane
    case sidebarModel
    case quickInput
    case terminalControl
    case rawTerminalOutput
}

enum TabActivityState: String, Codable, CaseIterable, Sendable {
    case idle
    case working
    case done
    case needsAttention
    case error
}

struct PluginTabIcon: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case systemSymbol
        case bundledAsset
    }

    let kind: Kind
    let name: String
}

struct TabActivity: Equatable, Sendable {
    let source: String
    let state: TabActivityState
    let label: String?
    let message: String?
    let detail: String?
    let progress: Double?
    let icon: PluginTabIcon?
}

struct PluginHello: Codable, Equatable, Sendable {
    let pluginID: String
    let pluginVersion: String
    let supportedProtocolVersions: [UInt16]
    let requestedCapabilities: [PluginCapability]
    let nonce: String
}

struct PluginWelcome: Codable, Equatable, Sendable {
    let selectedProtocolVersion: UInt16
    let grantedCapabilities: [PluginCapability]
    let hostVersion: String
}

struct PluginSubscription: Codable, Equatable, Sendable {
    let events: [PluginSessionEvent.Kind]
}

struct PluginSessionSnapshot: Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let foregroundPID: Int?
    let progress: PluginTerminalProgress?
    let isFocused: Bool
}

struct PluginTerminalProgress: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case set
        case error
        case indeterminate
        case pause
    }

    let state: State
    let percent: UInt8?
}

struct PluginSessionEvent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case opened
        case closed
        case titleChanged
        case progressChanged
        case foregroundProcessChanged
        case focusChanged
    }

    let kind: Kind
    let session: PluginSessionSnapshot
}

struct PluginSessionStatus: Codable, Equatable, Sendable {
    enum State: String, Codable, CaseIterable, Sendable {
        case running
        case waiting
        case completed
        case failed
    }

    let agent: String
    let title: String?
    let state: State
    let message: String?
    let detail: String?
    let progress: Double?
    let icon: PluginTabIcon?

    init(
        agent: String,
        title: String?,
        state: State,
        message: String? = nil,
        detail: String? = nil,
        progress: Double? = nil,
        icon: PluginTabIcon? = nil
    ) {
        self.agent = agent
        self.title = title
        self.state = state
        self.message = message
        self.detail = detail
        self.progress = progress
        self.icon = icon
    }

    var activity: TabActivity {
        let activityState: TabActivityState
        switch state {
        case .running: activityState = .working
        case .waiting: activityState = .needsAttention
        case .completed: activityState = .done
        case .failed: activityState = .error
        }
        return .init(
            source: agent,
            state: activityState,
            label: title,
            message: message,
            detail: detail,
            progress: progress,
            icon: icon
        )
    }
}

struct PluginSetSessionStatus: Codable, Equatable, Sendable {
    let sessionID: UUID
    let revision: UInt64
    let status: PluginSessionStatus
    let ttlMilliseconds: UInt64?
}

struct PluginClearSessionStatus: Codable, Equatable, Sendable {
    let sessionID: UUID
    let revision: UInt64
}

struct PluginAcknowledgement: Codable, Equatable, Sendable {
    let acceptedSequence: UInt64
}

struct PluginProtocolFailure: Codable, Equatable, Error, Sendable {
    enum Code: String, Codable, Sendable {
        case incompatibleVersion
        case invalidMessage
        case permissionDenied
        case sessionNotFound
        case staleRevision
        case internalError
    }

    let code: Code
    let message: String
}

struct PluginWireMessage: Codable, Equatable, Sendable {
    enum Body: Equatable, Sendable {
        case hello(PluginHello)
        case welcome(PluginWelcome)
        case subscribe(PluginSubscription)
        case sessionEvent(PluginSessionEvent)
        case setSessionStatus(PluginSetSessionStatus)
        case clearSessionStatus(PluginClearSessionStatus)
        case acknowledgement(PluginAcknowledgement)
        case failure(PluginProtocolFailure)
    }

    private enum MessageType: String, Codable {
        case hello
        case welcome
        case subscribe
        case sessionEvent
        case setSessionStatus
        case clearSessionStatus
        case acknowledgement
        case failure
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sequence
        case correlationID = "correlation_id"
        case type
        case payload
    }

    let version: UInt16
    let sequence: UInt64
    let correlationID: UInt64?
    let body: Body

    init(
        version: UInt16 = PluginProtocolContract.currentVersion,
        sequence: UInt64,
        correlationID: UInt64? = nil,
        body: Body
    ) {
        self.version = version
        self.sequence = sequence
        self.correlationID = correlationID
        self.body = body
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt16.self, forKey: .version)
        sequence = try container.decode(UInt64.self, forKey: .sequence)
        correlationID = try container.decodeIfPresent(UInt64.self, forKey: .correlationID)

        switch try container.decode(MessageType.self, forKey: .type) {
        case .hello:
            body = .hello(try container.decode(PluginHello.self, forKey: .payload))
        case .welcome:
            body = .welcome(try container.decode(PluginWelcome.self, forKey: .payload))
        case .subscribe:
            body = .subscribe(try container.decode(PluginSubscription.self, forKey: .payload))
        case .sessionEvent:
            body = .sessionEvent(try container.decode(PluginSessionEvent.self, forKey: .payload))
        case .setSessionStatus:
            body = .setSessionStatus(try container.decode(PluginSetSessionStatus.self, forKey: .payload))
        case .clearSessionStatus:
            body = .clearSessionStatus(try container.decode(PluginClearSessionStatus.self, forKey: .payload))
        case .acknowledgement:
            body = .acknowledgement(try container.decode(PluginAcknowledgement.self, forKey: .payload))
        case .failure:
            body = .failure(try container.decode(PluginProtocolFailure.self, forKey: .payload))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(sequence, forKey: .sequence)
        try container.encodeIfPresent(correlationID, forKey: .correlationID)

        switch body {
        case .hello(let payload):
            try container.encode(MessageType.hello, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .welcome(let payload):
            try container.encode(MessageType.welcome, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .subscribe(let payload):
            try container.encode(MessageType.subscribe, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .sessionEvent(let payload):
            try container.encode(MessageType.sessionEvent, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .setSessionStatus(let payload):
            try container.encode(MessageType.setSessionStatus, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .clearSessionStatus(let payload):
            try container.encode(MessageType.clearSessionStatus, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .acknowledgement(let payload):
            try container.encode(MessageType.acknowledgement, forKey: .type)
            try container.encode(payload, forKey: .payload)
        case .failure(let payload):
            try container.encode(MessageType.failure, forKey: .type)
            try container.encode(payload, forKey: .payload)
        }
    }
}

enum PluginWireCodec {
    enum CodecError: Error, Equatable {
        case emptyFrame
        case frameTooLarge(Int)
    }

    static func encode(_ message: PluginWireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(message)

        guard !payload.isEmpty else { throw CodecError.emptyFrame }
        guard payload.count <= PluginProtocolContract.maximumFrameLength else {
            throw CodecError.frameTooLarge(payload.count)
        }

        var length = UInt32(payload.count).bigEndian
        var frame = Data(capacity: MemoryLayout<UInt32>.size + payload.count)
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    static func decode(_ payload: Data) throws -> PluginWireMessage {
        try JSONDecoder().decode(PluginWireMessage.self, from: payload)
    }

    struct FrameDecoder {
        private var buffer = Data()

        var bufferedByteCount: Int { buffer.count }

        mutating func append(_ data: Data) throws -> [Data] {
            buffer.append(data)
            var frames: [Data] = []
            let headerLength = MemoryLayout<UInt32>.size

            while buffer.count >= headerLength {
                let payloadLength = buffer.prefix(headerLength).reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
                let length = Int(payloadLength)

                guard length > 0 else { throw CodecError.emptyFrame }
                guard length <= PluginProtocolContract.maximumFrameLength else {
                    throw CodecError.frameTooLarge(length)
                }

                let frameLength = headerLength + length
                guard buffer.count >= frameLength else { break }

                let payloadStart = buffer.index(buffer.startIndex, offsetBy: headerLength)
                let payloadEnd = buffer.index(payloadStart, offsetBy: length)
                frames.append(Data(buffer[payloadStart..<payloadEnd]))
                buffer.removeSubrange(buffer.startIndex..<payloadEnd)
            }

            return frames
        }
    }
}
