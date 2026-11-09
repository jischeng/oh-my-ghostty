import Foundation
import Security
import TermioShared
import UIKit

final class OMGSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene,
              let app = UIApplication.shared.delegate as? AppDelegate else { return }
        _ = app.install(in: scene)
        window = app.window
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--ui-test-server"),
           arguments.indices.contains(index + 1),
           let tokenIndex = arguments.firstIndex(of: "--ui-test-token"),
           arguments.indices.contains(tokenIndex + 1),
           let url = URL(string: "ws://\(arguments[index + 1])") {
            let token = arguments[tokenIndex + 1]
            if CompanionLink.activeMac?.endpoint != DeviceEndpoint(kind: .omgd, url: url, token: token) {
                CompanionLink.pairOMG(url: url, token: token)
            }
        }
        #endif
        if !ProcessInfo.processInfo.arguments.contains("--ui-test-server"),
           CompanionLink.activeMac == nil, !PairingStore.address.isEmpty, !PairingStore.token.isEmpty,
           let url = URL(string: PairingStore.address.contains("://")
                ? PairingStore.address : "ws://\(PairingStore.address)") {
            CompanionLink.pairOMG(url: url, token: PairingStore.token)
        }
        if let url = options.urlContexts.first?.url {
            CompanionLink.pair(rawAddress: url.absoluteString)
        }
    }

    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        if let url = contexts.first?.url { CompanionLink.pair(rawAddress: url.absoluteString) }
    }
}

enum OMGPairing {
    static func invite(_ text: String) -> (url: URL, token: String)? {
        guard let invite = URLComponents(string: text), invite.scheme == "omg",
              invite.host == "device" else { return nil }
        let fields = Dictionary((invite.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                                uniquingKeysWith: { _, last in last })
        guard let raw = fields["url"], let url = URL(string: raw),
              let token = fields["token"], valid(url: url, token: token) else { return nil }
        return (url, token)
    }

    static func valid(url: URL, token: String) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["ws", "wss"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.contains(".."), !url.path.contains("\\"),
              (32...256).contains(token.utf8.count),
              token.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
        else { return false }
        if scheme == "ws" && !isPrivateOrLoopbackHost(host) {
            return false
        }
        return true
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

    static func verify(url: URL, token: String,
                       completion: @escaping (Result<CompanionRoster, CompanionLink.PairingFailure>) -> Void) {
        guard valid(url: url, token: token) else { completion(.failure(.unreadableAddress)); return }
        let client = CompanionClient(url: url.appendingPathComponent("control"), token: token)
        var finished = false
        var deadline: DispatchWorkItem?
        func finish(_ result: Result<CompanionRoster, CompanionLink.PairingFailure>) {
            guard !finished else { return }
            finished = true
            deadline?.cancel()
            deadline = nil
            client.stop()
            client.onRoster = nil
            client.onError = nil
            client.onConnectionFailure = nil
            completion(result)
        }
        client.onRoster = { finish(.success($0)) }
        client.onError = { finish(.failure(.unreachable($0))) }
        client.onConnectionFailure = { finish(.failure(.unreachable($0))) }
        let timeout = DispatchWorkItem { finish(.failure(.unreachable("OMG did not answer."))) }
        deadline = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
        client.start()
    }
}

extension MockSession {
    var omgAccessibilityID: String {
        guard let value = rosterID else { return key }
        return MobileSessionRoute(value)?.sessionID ?? value
    }
}

enum OMGCredentials {
    private static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.jischeng.omg.mobile.paired-hosts",
         kSecAttrAccount as String: id]
    }
    static func token(_ id: String) -> String? {
        var query = query(id)
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func store(_ token: String, id: String) -> Bool {
        let fields: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query(id) as CFDictionary, fields as CFDictionary)
        if result == errSecItemNotFound {
            return SecItemAdd(query(id).merging(fields, uniquingKeysWith: { _, value in value }) as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }
    static func remove(_ id: String) { SecItemDelete(query(id) as CFDictionary) }
}

enum OMGOpenSource {
    @MainActor static func present(in parent: UIViewController) {
        let names = ["LICENSE", "LICENSE.termio", "LICENSE.libghostty-swift", "LICENSE.GhosttyTheme",
                     "LICENSE.Highlightr", "LICENSE.highlight.js", "LICENSE.MSDisplayLink"]
        let text = names.compactMap { name -> String? in
            guard let url = Bundle.main.url(forResource: name, withExtension: nil),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return "\(name)\n\n\(text)"
        }.joined(separator: "\n\n----------------\n\n")
        let bytes = Data(text.utf8)
        parent.present(FileViewerController(file: DeviceFile(path: "Open Source Licenses.txt",
            data: bytes, size: bytes.count, isBinary: false, isTruncated: false)), animated: true)
    }
}
