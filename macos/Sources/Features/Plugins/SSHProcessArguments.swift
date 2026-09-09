import Darwin
import Foundation

/// Captures argv boundaries from the user's foreground SSH process; ps command
/// strings cannot distinguish spaces inside IdentityFile/ProxyCommand values.
enum SSHProcessArguments {
    static func read(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > 4, size <= 1024 * 1024 else { return nil }
        var data = Data(count: size)
        let result = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard result == 0 else { return nil }
        let bytes = Data(data.prefix(size))
        guard var argv = decode(bytes) else { return nil }
        let executable = bytes.dropFirst(MemoryLayout<Int32>.size).prefix { $0 != 0 }
        if let path = String(data: executable, encoding: .utf8), path.hasPrefix("/") { argv[0] = path }
        return argv
    }

    static func decode(_ data: Data) -> [String]? {
        guard data.count >= MemoryLayout<Int32>.size else { return nil }
        let count = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0 && count <= 256 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < data.count && data[index] != 0 { index += 1 }
        while index < data.count && data[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<count {
            guard index < data.count, let end = data[index...].firstIndex(of: 0),
                  let value = String(data: data[index..<end], encoding: .utf8) else { return nil }
            result.append(value)
            index = end + 1
        }
        return result
    }

    static func observe(groupID: Int) -> (observation: ForegroundSSHProcessObservation, replay: SSHReplayDescriptor?)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=", "-g", String(groupID)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return nil }
        let commands = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.compactMap { read(pid: $0) }
            .filter { $0.first.map { ($0 as NSString).lastPathComponent == "ssh" } == true }
        guard !commands.isEmpty else { return nil }
        guard commands.count == 1, let argv = commands.first,
              let destination = ForegroundSSHProcessDetector.interactiveDestination(Array(argv.dropFirst())) else {
            return (.ambiguous, nil)
        }
        let alias = destination.split(separator: "@").last.map(String.init) ?? destination
        guard SSHPlugin.validAlias(alias) else { return (.ambiguous, nil) }
        let executable = argv[0].hasPrefix("/") ? argv[0] : "/usr/bin/ssh"
        return (.interactive(alias: alias, transferTarget: destination),
                SSHReplayDescriptor(version: 1, ssh: executable, forwardEnv: false, terminfo: false,
                                    cache: false, args: Array(argv.dropFirst())))
    }
}
