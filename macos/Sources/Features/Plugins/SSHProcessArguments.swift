import Darwin
import Foundation

/// Parses OpenSSH's short-option grammar once for foreground recognition and
/// auxiliary connections. A value option consumes the rest of its argument,
/// so `-4vp2222` means `-4 -v -p 2222`, not a set of independent flags.
struct OpenSSHArguments: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let name: Character
        let value: String?

        var arguments: [String] {
            ["-" + String(name)] + (value.map { [$0] } ?? [])
        }
    }

    let options: [Option]
    let destination: String
    let command: [String]

    var interactiveDestination: String? {
        let noninteractive = "GNOQTVWfns"
        guard command.isEmpty, !options.contains(where: { noninteractive.contains($0.name) }) else { return nil }
        return destination
    }

    init?(_ arguments: [String]) {
        let flags = "46AaCfGgKkMNnqsTtVvXxYy"
        let values = "BbcDEeFIiJLlmOoPpQRSWw"
        guard arguments.allSatisfy({ !$0.contains("\0") }) else { return nil }
        var options: [Option] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" { index += 1; break }
            guard argument.hasPrefix("-"), argument != "-" else { break }
            var characters = argument.dropFirst()
            while let name = characters.first {
                characters = characters.dropFirst()
                if values.contains(name) {
                    let value: String
                    if characters.isEmpty {
                        index += 1
                        guard index < arguments.count else { return nil }
                        value = arguments[index]
                    } else {
                        value = String(characters)
                    }
                    options.append(Option(name: name, value: value))
                    break
                }
                guard flags.contains(name) else { return nil }
                options.append(Option(name: name, value: nil))
            }
            index += 1
        }
        guard index < arguments.count, !arguments[index].isEmpty,
              !arguments[index].hasPrefix("-") else { return nil }
        self.options = options
        self.destination = arguments[index]
        self.command = Array(arguments.dropFirst(index + 1))
    }
}

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

    static func workingDirectory(pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.hasPrefix("/") ? path : nil
    }

    /// Foreground observation supplies an absolute executable. Older +ssh
    /// descriptors may contain a bare name; resolve those using the host app's
    /// PATH explicitly, retaining the original cwd for relative PATH entries.
    static func executablePath(
        for executable: String,
        workingDirectory: String,
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
    ) -> String? {
        guard !executable.isEmpty, !executable.contains("\0"),
              workingDirectory.hasPrefix("/"), !workingDirectory.contains("\0") else { return nil }
        if executable.hasPrefix("/") { return executable }
        if executable.contains("/") {
            return (workingDirectory as NSString).appendingPathComponent(executable)
        }
        for entry in searchPath.split(separator: ":", omittingEmptySubsequences: false) {
            let directory = entry.hasPrefix("/") ? String(entry) :
                (workingDirectory as NSString).appendingPathComponent(String(entry))
            let path = (directory as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
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
        let commands = text.split(whereSeparator: \.isWhitespace).compactMap { Int32($0) }.compactMap { pid in
            read(pid: pid).map { (arguments: $0, workingDirectory: workingDirectory(pid: pid)) }
        }.filter { $0.arguments.first.map { ($0 as NSString).lastPathComponent == "ssh" } == true }
        guard !commands.isEmpty else { return nil }
        guard commands.count == 1, let invocation = commands.first else {
            return (.ambiguous, nil)
        }
        let argv = invocation.arguments
        guard let destination = ForegroundSSHProcessDetector.interactiveDestination(Array(argv.dropFirst())) else {
            return (.ambiguous, nil)
        }
        let alias = destination.split(separator: "@").last.map(String.init) ?? destination
        guard SSHPlugin.validAlias(alias) else { return (.ambiguous, nil) }
        let executable = argv[0]
        return (.interactive(alias: alias, transferTarget: destination),
                SSHReplayDescriptor(version: 1, ssh: executable, forwardEnv: false, terminfo: false,
                                    cache: false, args: Array(argv.dropFirst()),
                                    localWorkingDirectory: invocation.workingDirectory))
    }
}
