import Darwin
import Foundation
import OSLog

/// Performs one-time, channel-scoped cutover from pre-epoch-2 session-runtime
/// artifacts (pinned per-revision `~/.omg/run/*` directories, `versions/`,
/// `pending-closes.json`, and stale `workspaces/state.json` pane bindings) so
/// upgrading from OMG `<= 0.21.1` restores windows, tabs, splits, directories,
/// titles, colors, and Agent/SSH metadata without dead error banners.
enum SessionRuntimeUpgradeCutover {
    static let currentEpoch = 2

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.jischeng.omg",
        category: "SessionRuntimeUpgradeCutover"
    )

    private struct EpochMarker: Codable, Equatable {
        var epoch: Int
    }

    private struct CatalogArchive: Codable {
        var version: Int
        var endpoints: [SessionRuntimeCatalogEndpoint]
    }

    static func runIfNeeded() {
        guard !OMGApplicationEnvironment.isRunningTests else { return }
        let supportRoot = OMGApplicationEnvironment.applicationSupportURL()
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let bundledRevision = (try? String(
            contentsOf: SessionRuntimeConnections.resources.appendingPathComponent("revision"),
            encoding: .utf8
        ))?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try performIfNeeded(
                applicationSupportRoot: supportRoot,
                homeDirectory: homeDirectory,
                bundledRevision: bundledRevision?.isEmpty == true ? nil : bundledRevision,
                terminateProcesses: true
            )
        } catch {
            logger.error(
                "Session runtime upgrade cutover failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    @discardableResult
    static func performIfNeeded(
        applicationSupportRoot: URL,
        homeDirectory: URL,
        bundledRevision: String?,
        terminateProcesses: Bool
    ) throws -> Bool {
        let sessionRuntimeRoot = applicationSupportRoot
            .appendingPathComponent("session-runtime", isDirectory: true)
        let epochURL = sessionRuntimeRoot
            .appendingPathComponent("runtime-epoch.json", isDirectory: false)
        if let epoch = readEpoch(at: epochURL), epoch >= currentEpoch {
            return false
        }

        let normalizedBundledRevision = bundledRevision?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBundledRevision = (normalizedBundledRevision?.isEmpty == true)
            ? nil
            : normalizedBundledRevision

        let matchedRunDirectories = identifyLegacyRunDirectories(
            applicationSupportRoot: applicationSupportRoot,
            homeDirectory: homeDirectory,
            bundledRevision: cleanBundledRevision
        )

        if terminateProcesses {
            terminateChannelProcesses(
                matchedRunDirectories: matchedRunDirectories,
                applicationSupportRoot: applicationSupportRoot
            )
        }
        for directory in matchedRunDirectories {
            try? FileManager.default.removeItem(at: directory)
        }

        let versionsURL = sessionRuntimeRoot.appendingPathComponent("versions", isDirectory: true)
        if FileManager.default.fileExists(atPath: versionsURL.path) {
            try? FileManager.default.removeItem(at: versionsURL)
        }
        let pendingClosesURL = sessionRuntimeRoot
            .appendingPathComponent("pending-closes.json", isDirectory: false)
        if FileManager.default.fileExists(atPath: pendingClosesURL.path) {
            try? FileManager.default.removeItem(at: pendingClosesURL)
        }
        sanitizeEndpointsArchive(
            at: sessionRuntimeRoot.appendingPathComponent("endpoints.json", isDirectory: false),
            bundledRevision: cleanBundledRevision
        )

        let workspacesDir = applicationSupportRoot.appendingPathComponent("workspaces", isDirectory: true)
        for fileName in ["state.json", "state.json.previous", "sessions.json"] {
            sanitizeWorkspaceSnapshot(
                at: workspacesDir.appendingPathComponent(fileName, isDirectory: false),
                bundledRevision: cleanBundledRevision
            )
        }

        let markerData = try JSONEncoder().encode(EpochMarker(epoch: currentEpoch))
        try OMGPrivateFileWriter.writeAtomically(markerData, to: epochURL, permissions: 0o600)
        return true
    }

    // MARK: - Epoch & Directory Discovery

    private static func readEpoch(at url: URL) -> Int? {
        guard !isSymbolicLink(at: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 64 * 1_024,
              let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(EpochMarker.self, from: data) else {
            return nil
        }
        return marker.epoch
    }

    private static func identifyLegacyRunDirectories(
        applicationSupportRoot: URL,
        homeDirectory: URL,
        bundledRevision: String?
    ) -> [URL] {
        let canonicalSupport = canonicalPath(applicationSupportRoot)
        let standardizedSupport = SessionRuntimeConnections.normalizedSupportPath(applicationSupportRoot)
        let revisions = collectChannelRevisions(
            applicationSupportRoot: applicationSupportRoot,
            bundledRevision: bundledRevision
        )

        let runRoot = homeDirectory.appendingPathComponent(".omg/run", isDirectory: true)
        var matchedByCanonicalPath: [String: URL] = [:]
        var otherChannelCanonicalPaths = Set<String>()

        if !isSymbolicLink(at: runRoot.path),
           let entries = try? FileManager.default.contentsOfDirectory(
            at: runRoot,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            for entry in entries {
                guard isRealDirectory(at: entry.path) else { continue }
                let entryCanonical = canonicalPath(entry)
                if let stamped = readSupportRootStamp(in: entry) {
                    if stamped == canonicalSupport {
                        matchedByCanonicalPath[entryCanonical] = entry
                    } else {
                        otherChannelCanonicalPaths.insert(entryCanonical)
                    }
                }
            }
        }

        var supportRoots = [applicationSupportRoot]
        if canonicalSupport != standardizedSupport {
            supportRoots.append(URL(fileURLWithPath: canonicalSupport, isDirectory: true))
        }
        for revision in revisions {
            for supportRoot in supportRoots {
                let candidate = SessionRuntimeConnections.legacyLocalStateDirectory(
                    supportRoot: supportRoot,
                    revision: revision,
                    homeDirectory: homeDirectory
                )
                guard isRealDirectory(at: candidate.path) else { continue }
                let candidateCanonical = canonicalPath(candidate)
                guard !otherChannelCanonicalPaths.contains(candidateCanonical) else { continue }
                if let stamped = readSupportRootStamp(in: candidate), stamped != canonicalSupport {
                    continue
                }
                if matchedByCanonicalPath[candidateCanonical] == nil {
                    matchedByCanonicalPath[candidateCanonical] = candidate
                }
            }
        }

        return matchedByCanonicalPath.values.sorted { $0.path < $1.path }
    }

    private static func readSupportRootStamp(in runDirectory: URL) -> String? {
        let stampURL = runDirectory.appendingPathComponent("support-root", isDirectory: false)
        guard !isSymbolicLink(at: stampURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: stampURL.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size > 0, size <= 16_384,
              let data = try? Data(contentsOf: stampURL),
              let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return canonicalPath(URL(fileURLWithPath: raw, isDirectory: true))
    }

    private static func collectChannelRevisions(
        applicationSupportRoot: URL,
        bundledRevision: String?
    ) -> Set<String> {
        var revisions = Set<String>()
        if let bundledRevision, !bundledRevision.isEmpty {
            revisions.insert(bundledRevision)
        }

        let sessionRuntimeRoot = applicationSupportRoot
            .appendingPathComponent("session-runtime", isDirectory: true)
        let versionsDir = sessionRuntimeRoot.appendingPathComponent("versions", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: versionsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                if !name.isEmpty, !name.hasPrefix(".") {
                    revisions.insert(name)
                }
            }
        }

        let endpointsURL = sessionRuntimeRoot.appendingPathComponent("endpoints.json", isDirectory: false)
        if !isSymbolicLink(at: endpointsURL.path),
           let data = try? Data(contentsOf: endpointsURL),
           data.count <= 4 * 1_024 * 1_024 {
            if let archive = try? JSONDecoder().decode(CatalogArchive.self, from: data) {
                for endpoint in archive.endpoints where !endpoint.descriptor.revision.isEmpty {
                    revisions.insert(endpoint.descriptor.revision)
                }
            }
            if let object = try? JSONSerialization.jsonObject(with: data) {
                collectRevisionStrings(fromJSON: object, into: &revisions)
            }
        }

        let workspacesDir = applicationSupportRoot.appendingPathComponent("workspaces", isDirectory: true)
        for fileName in ["state.json", "state.json.previous", "sessions.json"] {
            let fileURL = workspacesDir.appendingPathComponent(fileName, isDirectory: false)
            guard !isSymbolicLink(at: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  data.count <= 32 * 1_024 * 1_024 else {
                continue
            }
            if let snapshot = try? JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: data) {
                for tab in snapshot.tabs {
                    if let state = try? JSONDecoder().decode(TerminalWorkspaceSessionState.self, from: tab.state),
                       let panes = state.surfaceTree.root?.panes {
                        for pane in panes {
                            if let revision = pane.runtimeDescriptor?.revision, !revision.isEmpty {
                                revisions.insert(revision)
                            }
                        }
                    }
                    if let object = try? JSONSerialization.jsonObject(with: tab.state) {
                        collectRevisionStrings(fromJSON: object, into: &revisions)
                    }
                }
            }
        }

        return revisions
    }

    private static func collectRevisionStrings(fromJSON value: Any, into revisions: inout Set<String>) {
        if let dict = value as? [String: Any] {
            if let revision = dict["revision"] as? String, !revision.isEmpty {
                revisions.insert(revision)
            }
            for nested in dict.values {
                collectRevisionStrings(fromJSON: nested, into: &revisions)
            }
        } else if let array = value as? [Any] {
            for item in array {
                collectRevisionStrings(fromJSON: item, into: &revisions)
            }
        }
    }

    // MARK: - Process Termination

    private static func terminateChannelProcesses(
        matchedRunDirectories: [URL],
        applicationSupportRoot: URL
    ) {
        let versionsURL = applicationSupportRoot
            .appendingPathComponent("session-runtime/versions", isDirectory: true)
        let runPrefixes = pathVariants(for: matchedRunDirectories)
        let versionPrefixes = pathVariants(for: [versionsURL])
        let allChannelPrefixes = Array(Set(runPrefixes + versionPrefixes))
        let sessionChildPIDs = collectRecordedSessionPIDs(in: matchedRunDirectories)
        var sessionParentPIDs = Set<pid_t>()
        let currentUID = getuid()

        for childPID in sessionChildPIDs {
            if let info = bsdInfo(for: childPID), info.pbi_uid == currentUID, info.pbi_ppid > 1 {
                sessionParentPIDs.insert(pid_t(info.pbi_ppid))
            }
        }

        let currentPID = getpid()
        var targetPIDs: [pid_t] = []
        for pid in allProcessIDs() where pid > 1 && pid != currentPID {
            guard let info = bsdInfo(for: pid),
                  info.pbi_uid == currentUID,
                  info.pbi_status != 5,
                  let executablePath = processExecutablePath(pid),
                  isOMGDaemonPath(executablePath) else {
                continue
            }
            if matchesChannelProcess(
                pid: pid,
                executablePath: executablePath,
                sessionChildPIDs: sessionChildPIDs,
                sessionParentPIDs: sessionParentPIDs,
                versionPrefixes: versionPrefixes,
                allChannelPrefixes: allChannelPrefixes
            ) {
                targetPIDs.append(pid)
            }
        }

        guard !targetPIDs.isEmpty else { return }
        for pid in targetPIDs {
            _ = Darwin.kill(pid, SIGTERM)
        }

        for _ in 0..<25 {
            if !targetPIDs.contains(where: { isVerifiedLivingOMGD($0, expectedUID: currentUID) }) {
                return
            }
            usleep(10_000)
        }

        for pid in targetPIDs where isVerifiedLivingOMGD(pid, expectedUID: currentUID) {
            _ = Darwin.kill(pid, SIGKILL)
        }
    }

    private static func collectRecordedSessionPIDs(in directories: [URL]) -> Set<pid_t> {
        var pids = Set<pid_t>()
        for directory in directories {
            let sessionsDir = directory.appendingPathComponent("sessions", isDirectory: true)
            guard isRealDirectory(at: sessionsDir.path),
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: sessionsDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                  ) else {
                continue
            }
            for entry in entries where entry.pathExtension == "json" && !isSymbolicLink(at: entry.path) {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: entry.path),
                      let size = (attributes[.size] as? NSNumber)?.intValue,
                      size <= 65_536,
                      let data = try? Data(contentsOf: entry),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rawPID = (json["pid"] as? NSNumber)?.int32Value,
                      rawPID > 1 else {
                    continue
                }
                pids.insert(rawPID)
            }
        }
        return pids
    }

    private static func matchesChannelProcess(
        pid: pid_t,
        executablePath: String,
        sessionChildPIDs: Set<pid_t>,
        sessionParentPIDs: Set<pid_t>,
        versionPrefixes: [String],
        allChannelPrefixes: [String]
    ) -> Bool {
        if sessionChildPIDs.contains(pid) || sessionParentPIDs.contains(pid) {
            return true
        }
        if pathBelongs(executablePath, toAnyPrefixIn: versionPrefixes) {
            return true
        }
        if let args = processArguments(pid),
           args.contains(where: { $0.hasPrefix("/") && pathBelongs($0, toAnyPrefixIn: allChannelPrefixes) }) {
            return true
        }
        if let cwd = processWorkingDirectory(pid),
           pathBelongs(cwd, toAnyPrefixIn: allChannelPrefixes) {
            return true
        }
        for openPath in processOpenPaths(pid) where pathBelongs(openPath, toAnyPrefixIn: allChannelPrefixes) {
            return true
        }
        return false
    }

    private static func isVerifiedLivingOMGD(_ pid: pid_t, expectedUID: uid_t) -> Bool {
        guard let info = bsdInfo(for: pid),
              info.pbi_uid == expectedUID,
              info.pbi_status != 5,
              let executablePath = processExecutablePath(pid),
              isOMGDaemonPath(executablePath) else {
            return false
        }
        return true
    }

    private static func isOMGDaemonPath(_ path: String) -> Bool {
        path == "/omgd" || path.hasSuffix("/omgd")
    }

    private static func allProcessIDs() -> [pid_t] {
        let estimatedBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        let capacity = max(256, (Int(estimatedBytes) / MemoryLayout<pid_t>.size) + 64)
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytes = buffer.withUnsafeMutableBytes { rawBuffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, rawBuffer.baseAddress, Int32(rawBuffer.count))
        }
        guard bytes > 0 else { return [] }
        let count = min(buffer.count, Int(bytes) / MemoryLayout<pid_t>.size)
        return Array(buffer.prefix(count))
    }

    private static func bsdInfo(for pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    private static func processExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func processWorkingDirectory(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
        }
        return path.hasPrefix("/") ? path : nil
    }

    private static func processArguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size,
              size <= 1024 * 1024 else {
            return nil
        }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({
            sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0)
        }) == 0 else {
            return nil
        }
        let bytes = Data(data.prefix(size))
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc <= 512 else { return nil }
        var cursor = MemoryLayout<Int32>.size
        while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        var args: [String] = []
        args.reserveCapacity(min(Int(argc), 64))
        for _ in 0..<argc {
            guard cursor < bytes.count else { break }
            let start = cursor
            while cursor < bytes.count && bytes[cursor] != 0 { cursor += 1 }
            if let arg = String(bytes: bytes[start..<cursor], encoding: .utf8) {
                args.append(arg)
            }
            cursor += 1
        }
        return args.isEmpty ? nil : args
    }

    private static func processOpenPaths(_ pid: pid_t) -> [String] {
        let fdSize = MemoryLayout<proc_fdinfo>.size
        let estimated = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard estimated > 0 else { return [] }
        let capacity = max(16, (Int(estimated) / fdSize) + 16)
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let filled = descriptors.withUnsafeMutableBytes { rawBuffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, rawBuffer.baseAddress, Int32(rawBuffer.count))
        }
        guard filled > 0 else { return [] }
        let count = min(descriptors.count, Int(filled) / fdSize)
        var paths: [String] = []
        for index in 0..<count {
            let entry = descriptors[index]
            if entry.proc_fdtype == PROX_FDTYPE_VNODE {
                var vnodeInfo = vnode_fdinfowithpath()
                let infoSize = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                if proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnodeInfo, infoSize) == infoSize {
                    let path = withUnsafePointer(to: &vnodeInfo.pvip.vip_path) {
                        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                    }
                    if path.hasPrefix("/") {
                        paths.append(path)
                    }
                }
            } else if entry.proc_fdtype == PROX_FDTYPE_SOCKET {
                var socketInfo = socket_fdinfo()
                let infoSize = Int32(MemoryLayout<socket_fdinfo>.size)
                if proc_pidfdinfo(pid, entry.proc_fd, PROC_PIDFDSOCKETINFO, &socketInfo, infoSize) == infoSize,
                   socketInfo.psi.soi_family == AF_UNIX {
                    let path = withUnsafePointer(to: &socketInfo.psi.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) {
                        String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
                    }
                    if path.hasPrefix("/") {
                        paths.append(path)
                    }
                }
            }
        }
        return paths
    }

    // MARK: - Sanitization

    private static func sanitizeEndpointsArchive(at url: URL, bundledRevision: String?) {
        guard !isSymbolicLink(at: url.path),
              FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 4 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url),
              let archive = try? JSONDecoder().decode(CatalogArchive.self, from: data),
              archive.version == 1 else {
            return
        }

        var byKey: [String: SessionRuntimeCatalogEndpoint] = [:]
        for var endpoint in archive.endpoints {
            if let bundledRevision, !bundledRevision.isEmpty {
                endpoint.descriptor.revision = bundledRevision
            }
            let key = endpoint.descriptor.isLocal ? "local" : endpoint.descriptor.identity
            if let existing = byKey[key] {
                if existing.lastUsedAt < endpoint.lastUsedAt {
                    byKey[key] = endpoint
                }
            } else {
                byKey[key] = endpoint
            }
        }

        let sanitized = byKey.values
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(512)
            .map { $0 }
        let updated = CatalogArchive(version: 1, endpoints: sanitized)
        do {
            let encoded = try JSONEncoder().encode(updated)
            try OMGPrivateFileWriter.writeAtomically(encoded, to: url, permissions: 0o600)
        } catch {
            logger.error(
                "Failed to sanitize endpoints archive: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func sanitizeWorkspaceSnapshot(at url: URL, bundledRevision: String?) {
        guard !isSymbolicLink(at: url.path),
              FileManager.default.fileExists(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= 32 * 1_024 * 1_024,
              let data = try? Data(contentsOf: url),
              var snapshot = try? JSONDecoder().decode(TerminalWorkspaceSessionStore.Snapshot.self, from: data),
              snapshot.version == 1 || snapshot.version == 2 else {
            return
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for index in snapshot.tabs.indices {
            guard var state = try? JSONDecoder().decode(
                TerminalWorkspaceSessionState.self,
                from: snapshot.tabs[index].state
            ) else {
                continue
            }
            var mapping: [String: String] = [:]
            if var root = state.surfaceTree.root {
                sanitizeNode(&root, mapping: &mapping, bundledRevision: bundledRevision)
                state.surfaceTree.root = root
            }
            if let focused = state.focusedSurface,
               let updatedFocus = mapping[focused] ?? mapping[focused.lowercased()] {
                state.focusedSurface = updatedFocus
            }
            if let encodedState = try? encoder.encode(state) {
                snapshot.tabs[index].state = encodedState
            }
        }

        do {
            let encodedSnapshot = try encoder.encode(snapshot)
            try OMGPrivateFileWriter.writeAtomically(encodedSnapshot, to: url, permissions: 0o600)
        } catch {
            logger.error(
                "Failed to sanitize workspace snapshot \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func sanitizeNode(
        _ node: inout TerminalWorkspaceSessionState.Node,
        mapping: inout [String: String],
        bundledRevision: String?
    ) {
        switch node {
        case .leaf(var pane):
            let oldUUID = pane.uuid
            let newUUID = UUID().uuidString
            mapping[oldUUID] = newUUID
            mapping[oldUUID.lowercased()] = newUUID
            pane.uuid = newUUID
            pane.runtimeCreateOnRestore = true
            if var descriptor = pane.runtimeDescriptor {
                if let bundledRevision, !bundledRevision.isEmpty {
                    descriptor.revision = bundledRevision
                }
                if descriptor.isLocal {
                    descriptor.initialWorkingDirectory =
                        SessionRuntimeDescriptor.validWorkingDirectory(pane.pwd)
                        ?? SessionRuntimeDescriptor.validWorkingDirectory(descriptor.localWorkingDirectory)
                        ?? SessionRuntimeDescriptor.validWorkingDirectory(descriptor.initialWorkingDirectory)
                }
                pane.runtimeDescriptor = descriptor
            }
            node = .leaf(pane)
        case .split(var branch):
            sanitizeNode(&branch.left, mapping: &mapping, bundledRevision: bundledRevision)
            sanitizeNode(&branch.right, mapping: &mapping, bundledRevision: bundledRevision)
            node = .split(branch)
        }
    }

    // MARK: - Path Helpers

    private static func isSymbolicLink(at path: String) -> Bool {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    private static func isRealDirectory(at path: String) -> Bool {
        var st = stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFDIR
    }

    private static func canonicalPath(_ url: URL) -> String {
        var current = url.standardizedFileURL
        var trailing: [String] = []
        while current.path != "/" && !FileManager.default.fileExists(atPath: current.path) {
            trailing.append(current.lastPathComponent)
            current = current.deletingLastPathComponent()
        }
        var resolved = current.standardizedFileURL.resolvingSymlinksInPath()
        for component in trailing.reversed() {
            resolved.appendPathComponent(component)
        }
        return SessionRuntimeConnections.normalizedSupportPath(resolved)
    }

    private static func pathVariants(for urls: [URL]) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for url in urls {
            for candidate in [
                SessionRuntimeConnections.normalizedSupportPath(url),
                canonicalPath(url),
            ] where seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private static func pathBelongs(_ candidate: String, toAnyPrefixIn prefixes: [String]) -> Bool {
        let normalized = SessionRuntimeConnections.normalizedSupportPath(URL(fileURLWithPath: candidate))
        let canonical = canonicalPath(URL(fileURLWithPath: candidate))
        for prefix in prefixes {
            if isPath(normalized, equalOrInside: prefix) || isPath(canonical, equalOrInside: prefix) {
                return true
            }
        }
        return false
    }

    private static func isPath(_ candidate: String, equalOrInside prefix: String) -> Bool {
        candidate == prefix || candidate.hasPrefix(prefix == "/" ? "/" : prefix + "/")
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
