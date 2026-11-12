import Foundation

/// Opaque roster identities bind a UI row to one endpoint and one generation.
public struct MobileSessionRoute: Equatable {
    public let endpointID: String
    public let sessionID: String
    public let generation: String

    public init?(_ value: String) {
        let fields = value.split(separator: "/", omittingEmptySubsequences: false)
        guard fields.count == 3, Self.hex(fields[0], count: 64),
              UUID(uuidString: String(fields[1])) != nil,
              Self.hex(fields[2], count: 32) else { return nil }
        endpointID = String(fields[0])
        sessionID = String(fields[1])
        generation = String(fields[2])
    }

    private static func hex(_ text: Substring, count: Int) -> Bool {
        text.utf8.count == count && text.utf8.allSatisfy {
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }
    }
}

/// Resolves iOS session and project icons so SSH shells and SSH project folders
/// display the cloud mark matching macOS `PaneSessionContext.tabIconSystemName`.
public enum MobileSessionIcon {
    public static func fallbackSystemSymbol(agent: String, remoteHost: String?) -> String {
        guard agent == "terminal" else { return "sparkles" }
        let isRemote = !(remoteHost?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return isRemote ? "cloud" : "terminal"
    }

    public static func isRemoteSSHProject(deviceAlias: String?, sessionRemoteHosts: [String?]) -> Bool {
        if let alias = deviceAlias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty {
            return true
        }
        guard !sessionRemoteHosts.isEmpty else { return false }
        return sessionRemoteHosts.allSatisfy {
            !($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }
}
