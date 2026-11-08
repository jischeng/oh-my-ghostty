import Foundation

enum Ghostty {
    enum Shell {
        static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    }
}

@main
struct MobileSupport {
    static func main() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard data.count <= 16384,
                  let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let result = try await perform(request)
            FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
        } catch {
            FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject:
                ["t": "error", "message": error.localizedDescription])) ?? Data())
        }
    }

    static func registry(_ request: [String: Any]) -> [[String: Any]] {
        let domain = request["domain"] as? String ?? "com.jischeng.omg.debug"
        guard ["com.jischeng.omg.debug", "com.jischeng.omg", "com.jischeng.omg.debug.workspace"].contains(domain),
              let data = UserDefaults(suiteName: domain)?.data(forKey: "OMG.SSH.Registry.v1"),
              let store = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return store["hosts"] as? [[String: Any]] ?? []
    }

    static func perform(_ request: [String: Any]) async throws -> [String: Any] {
        switch request["operation"] as? String {
        case "hosts":
            return ["t": "hosts", "hosts": [["id": "local", "name": "Local Machine"]] +
                registry(request).compactMap { row -> [String: String]? in
                    guard let id = row["id"] as? String, let name = row["name"] as? String else { return nil }
                    return ["id": id, "name": name]
                }]
        case "directories":
            let path = request["path"] as? String ?? ""
            guard path.isEmpty || (path.hasPrefix("/") && !path.contains("\0") && !path.contains("\n") && path.utf8.count <= 4096) else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let host = request["host"] as? String ?? "local"
            if host != "local" {
                let connection = try connection(host, request: request)
                let script = """
                import json,os,sys
                p=os.path.realpath(sys.argv[1] or os.path.expanduser('~'))
                if not os.path.isdir(p): raise ValueError('Not a folder')
                names=[]
                for entry in os.scandir(p):
                    if len(names)>=1000: break
                    if not entry.name.startswith('.') and entry.is_dir(): names.append(entry.name)
                print(json.dumps(dict(t='directories',path=p,parent=os.path.dirname(p),names=sorted(names))))
                """
                let command = "python3 -c \(Ghostty.Shell.quote(script)) \(Ghostty.Shell.quote(path))"
                let data = try runSSH(connection, command: command)
                return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            }
            let root = URL(fileURLWithPath: path.isEmpty ? NSHomeDirectory() : path).resolvingSymlinksInPath()
            let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            let names = try files.prefix(1000).filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
                .map(\.lastPathComponent).sorted()
            return ["t": "directories", "path": root.path, "parent": root.deletingLastPathComponent().path, "names": names]
        case "sshCommand":
            let host = request["host"] as? String ?? ""
            let connection = try connection(host, request: request)
            guard let destination = connection["destination"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            return ["t": "sshCommand", "destination": destination, "options": connection["options"] as? [String] ?? []]
        default:
            throw CocoaError(.featureUnsupported)
        }
    }

    static func connection(_ id: String, request: [String: Any]) throws -> [String: Any] {
        guard let entry = registry(request).first(where: { $0["id"] as? String == id }),
              let connection = entry["connection"] as? [String: Any] else { throw CocoaError(.fileNoSuchFile) }
        return connection
    }

    static func runSSH(_ connection: [String: Any], command: String) throws -> Data {
        guard let destination = connection["destination"] as? String, !destination.hasPrefix("-") else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"] +
            (connection["options"] as? [String] ?? []) + [destination, command]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, data.count <= 1024 * 1024 else { throw CocoaError(.fileReadUnknown) }
        return data
    }
}
