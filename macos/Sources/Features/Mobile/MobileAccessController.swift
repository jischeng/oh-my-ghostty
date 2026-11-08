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
    @Published private(set) var connectedDevices = 0

    private let executable: URL
    private let support: URL
    private let tokenFile: URL
    private let port: Int
    private let addressProvider: () -> String?
    private var process: Process?
    private var log: FileHandle?
    private var intentionalStop = false
    private var terminationObserver: NSObjectProtocol?

    var listenAddress: String? {
        address.map { "\($0):\(port)" }
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
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            state = .failed("The bundled mobile runtime is missing.")
            return
        }
        guard let listenAddress else {
            state = .failed("No private IPv4 LAN address is available.")
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
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, let running = self.process, running.isRunning else { return }
                self.state = .running
                await self.refreshInvitation()
            }
        } catch {
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
        connectedDevices = 0
        state = .stopped
    }

    func refreshInvitation() async {
        guard let listenAddress else {
            errorMessage = "No private IPv4 LAN address is available."
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: support, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
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
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard process.terminationStatus == 0,
                  let text = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  text.hasPrefix("omg://device?") else {
                let message = String(
                    data: errors.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                )?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(
                    domain: "OMGMobileAccess", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: message?.isEmpty == false
                        ? message! : "Could not create a pairing invitation."]
                )
            }
            errorMessage = nil
            invitation = text
        } catch {
            invitation = nil
            errorMessage = error.localizedDescription
        }
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
