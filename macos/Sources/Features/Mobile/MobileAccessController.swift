import AppKit
import Combine
import CoreImage
import Darwin
import Foundation

/// Owns the LAN-only mobile gateway while OMG is running. Pairing remains a
/// single-token operation: starting the gateway allows the documented mobile
/// capabilities, and revoking the token disconnects every paired phone.
@MainActor
final class MobileAccessController: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    static let shared = MobileAccessController()

    @Published private(set) var state: State = .stopped
    @Published private(set) var invitation: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var address: String?
    @Published private(set) var publicURL: String = ""
    @Published private(set) var connectedDevices = 0

    private let executable: URL
    private let support: URL
    private let tokenFile: URL
    private let publicURLFile: URL
    private let port: Int
    private let addressProvider: () -> String?
    private var process: Process?
    private var log: FileHandle?
    private var intentionalStop = false
    private var terminationObserver: NSObjectProtocol?

    var listenAddress: String? {
        if let address { return "\(address):\(port)" }
        if !publicURL.isEmpty { return "127.0.0.1:\(port)" }
        return nil
    }

    var displayEndpoint: String? {
        if !publicURL.isEmpty { return publicURL }
        return listenAddress
    }

    var hasPairing: Bool {
        FileManager.default.fileExists(atPath: tokenFile.path)
    }

    init(
        executable: URL? = nil,
        support: URL = OMGApplicationEnvironment.applicationSupportURL(),
        port: Int = 8791,
        addressProvider: @escaping () -> String? = MobileAccessController.lanIPv4Address
    ) {
        self.executable = executable ?? Bundle.main.resourceURL!
            .appendingPathComponent("session-runtime/omgd")
        self.support = support
        self.port = port
        self.addressProvider = addressProvider
        tokenFile = support.appendingPathComponent("mobile-pair.token")
        publicURLFile = support.appendingPathComponent("mobile-public-url.txt")
        if let saved = try? String(contentsOf: publicURLFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let normalized = Self.validatedPublicURL(saved) {
            publicURL = normalized
        }
        address = addressProvider()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        process?.terminate()
    }

    func start() {
        guard !state.isRunning, state != .starting else { return }
        address = addressProvider()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            let reason = "The bundled mobile runtime is missing."
            errorMessage = reason
            state = .failed(reason)
            return
        }
        guard let listenAddress else {
            let reason = "No private IPv4 LAN address is available."
            errorMessage = reason
            state = .failed(reason)
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let logURL = support.appendingPathComponent("mobile-gateway.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(
                    atPath: logURL.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                )
            }
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "mobile", "--listen", listenAddress,
                "--app-support", support.path,
                "--token-file", tokenFile.path,
            ]
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self, weak process] finished in
                DispatchQueue.main.async {
                    guard let self, let process, self.process === process else { return }
                    self.process = nil
                    try? handle.close()
                    self.log = nil
                    if self.intentionalStop {
                        self.state = .stopped
                    } else {
                        let reason = finished.terminationStatus == 0
                            ? "The mobile gateway stopped."
                            : "The mobile gateway exited with status \(finished.terminationStatus). Check that port \(self.port) is available."
                        self.errorMessage = reason
                        self.state = .failed(reason)
                    }
                }
            }
            intentionalStop = false
            errorMessage = nil
            invitation = nil
            self.process = process
            log = handle
            state = .starting
            try process.run()
            Task { [weak self, weak process] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, let process, self.process === process, process.isRunning else { return }
                self.state = .running
                await self.refreshInvitation()
            }
        } catch {
            errorMessage = error.localizedDescription
            state = .failed(error.localizedDescription)
            try? log?.close()
            log = nil
        }
    }

    func stop() {
        intentionalStop = true
        process?.terminate()
        process = nil
        try? log?.close()
        log = nil
        invitation = nil
        errorMessage = nil
        connectedDevices = 0
        state = .stopped
    }

    func refreshInvitation() async {
        address = addressProvider()
        guard let listenAddress else {
            errorMessage = "No private IPv4 LAN address is available."
            return
        }
        let executable = self.executable
        let support = self.support
        let tokenFile = self.tokenFile
        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let text = try await Task.detached { () -> String in
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                process.executableURL = executable
                process.arguments = [
                    "mobile", "--listen", listenAddress,
                    "--app-support", support.path,
                    "--token-file", tokenFile.path,
                    "--print-invite",
                ]
                process.standardOutput = output
                process.standardError = errors
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0,
                      let text = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                      text.hasPrefix("omg://device?") else {
                    let message = String(data: errorData, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    throw NSError(
                        domain: "OMGMobileAccess", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false
                            ? message! : "Could not create a pairing invitation."]
                    )
                }
                return text
            }.value
            errorMessage = nil
            invitation = applyPublicURL(to: text)
        } catch {
            invitation = nil
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func setPublicURL(_ rawValue: String) -> Bool {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            publicURL = ""
            errorMessage = nil
            try? FileManager.default.removeItem(at: publicURLFile)
            if let current = invitation {
                invitation = applyPublicURL(to: current)
            }
            return true
        }
        guard let normalized = Self.validatedPublicURL(trimmed) else {
            errorMessage = "Public endpoints must use wss:// (TLS) with a valid host and no query or credentials."
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(normalized.utf8).write(to: publicURLFile, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: publicURLFile.path)
            publicURL = normalized
            errorMessage = nil
            if let current = invitation {
                invitation = applyPublicURL(to: current)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func applyPublicURL(to rawInvite: String) -> String {
        guard let components = URLComponents(string: rawInvite),
              let items = components.queryItems,
              let token = items.first(where: { $0.name == "token" })?.value else {
            return rawInvite
        }
        let targetURL: String
        if !publicURL.isEmpty {
            targetURL = publicURL
        } else if let listenAddress {
            targetURL = "ws://\(listenAddress)"
        } else {
            return rawInvite
        }
        return "omg://device?url=\(targetURL)&token=\(token)"
    }

    static func validatedPublicURL(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed) else { return nil }
        switch components.scheme?.lowercased() {
        case "wss", "https":
            components.scheme = "wss"
        case "ws", "http":
            guard let host = components.host, isPrivateOrLoopbackHost(host) else { return nil }
            components.scheme = "ws"
        default:
            return nil
        }
        guard let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              !components.path.contains(".."), !components.path.contains("\\") else {
            return nil
        }
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return components.string
    }

    static func isPrivateOrLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" || lower.hasSuffix(".local") {
            return true
        }
        let octets = lower.split(separator: ".", omittingEmptySubsequences: false).compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 127 ||
            octets[0] == 10 ||
            (octets[0] == 172 && (16...31).contains(octets[1])) ||
            (octets[0] == 192 && octets[1] == 168) ||
            (octets[0] == 169 && octets[1] == 254) ||
            (octets[0] == 100 && (64...127).contains(octets[1]))
    }

    func revokePairings() {
        stop()
        try? FileManager.default.removeItem(at: tokenFile)
        invitation = nil
    }

    func copyInvitation() {
        guard let invitation else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(invitation, forType: .string)
    }

    static func qrImage(for invitation: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(invitation.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }

    private static func lanIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        var candidates: [(name: String, address: String)] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let socketAddress = current.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress, socklen_t(socketAddress.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            let components = address.split(separator: ".").compactMap { Int($0) }
            guard components.count == 4 else { continue }
            let isPrivate = components[0] == 10 ||
                (components[0] == 172 && (16...31).contains(components[1])) ||
                (components[0] == 192 && components[1] == 168) ||
                (components[0] == 169 && components[1] == 254)
            guard isPrivate else { continue }
            candidates.append((String(cString: current.pointee.ifa_name), address))
        }
        return candidates.first { $0.name == "en0" }?.address ??
            candidates.first { $0.name == "en1" }?.address ??
            candidates.first?.address
    }
}
