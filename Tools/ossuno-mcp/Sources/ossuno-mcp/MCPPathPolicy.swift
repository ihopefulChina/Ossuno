import Darwin
import Foundation

/// Restricts MCP file tools to an explicit set of local directories.
///
/// Configure roots with `OSSUNO_MCP_ALLOWED_ROOTS`, using macOS' `:` path
/// separator or a JSON string array. When it is absent, the conventional
/// Desktop, Documents, Downloads and temporary directories are allowed.
struct MCPPathPolicy: Sendable {
    static let environmentKey = "OSSUNO_MCP_ALLOWED_ROOTS"

    struct Root: Sendable {
        let configured: URL
        let canonical: URL
    }

    struct StagedUpload: Sendable {
        let originalURL: URL
        let fileURL: URL
        let size: Int64
    }

    struct DownloadTarget: Sendable {
        let destination: URL
        fileprivate let root: Root
        fileprivate let components: [String]

        func publish(_ temporaryURL: URL) throws -> Int64 {
            try MCPPathPolicy.publishDownloadedFile(temporaryURL, to: self)
        }
    }

    private let roots: [Root]

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws {
        let configuredPaths: [String]
        if let raw = environment[Self.environmentKey] {
            configuredPaths = try Self.parseRoots(raw)
        } else {
            let home = fileManager.homeDirectoryForCurrentUser.path
            configuredPaths = [
                "\(home)/Desktop",
                "\(home)/Documents",
                "\(home)/Downloads",
                "/tmp",
                fileManager.temporaryDirectory.path,
            ]
        }
        try self.init(paths: configuredPaths)
    }

    init(paths: [String]) throws {
        var unique: [String: Root] = [:]
        for rawPath in paths {
            let expanded = NSString(string: rawPath).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw MCPPathPolicyError.invalidRoot(rawPath)
            }
            let configured = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
            guard configured.path != "/" else {
                throw MCPPathPolicyError.invalidRoot(rawPath)
            }
            let canonical = configured.resolvingSymlinksInPath().standardizedFileURL
            unique[canonical.path] = Root(configured: configured, canonical: canonical)
        }
        guard !unique.isEmpty else {
            throw MCPPathPolicyError.noAllowedRoots
        }
        roots = unique.values.sorted { $0.canonical.path < $1.canonical.path }
    }

    var allowedRootsDescription: String {
        roots.map(\.configured.path).joined(separator: "、")
    }

    func validateUploadPath(_ rawPath: String) throws -> URL {
        let match = try match(rawPath)
        try rejectSymlinks(in: match.candidate, below: match.lexicalRoot)
        let descriptor = try openUploadFile(match)
        Darwin.close(descriptor)
        return match.candidate
    }

    /// Opens the caller-selected file through an allowed-root directory
    /// descriptor, then snapshots those exact bytes into a private temporary
    /// file. URLSession can safely open the snapshot after arbitrary awaits;
    /// replacing the caller's path can no longer redirect the upload.
    func stageUploadPath(_ rawPath: String) throws -> StagedUpload {
        let match = try match(rawPath)
        let descriptor = try openUploadFile(match)
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw MCPPathPolicyError.cannotInspect(match.candidate.path)
        }
        let stagedURL = try Self.copyToPrivateTemporaryFile(from: descriptor)
        return StagedUpload(
            originalURL: match.candidate,
            fileURL: stagedURL,
            size: Int64(info.st_size)
        )
    }

    func validateDownloadPath(_ rawPath: String) throws -> URL {
        try prepareDownloadPath(rawPath).destination
    }

    /// Captures the allowed root and relative components, but deliberately
    /// re-opens every component with openat/O_NOFOLLOW when publishing. This
    /// keeps a path swapped during the network request from redirecting the
    /// final write through a symbolic link.
    func prepareDownloadPath(_ rawPath: String) throws -> DownloadTarget {
        let match = try match(rawPath)
        try rejectSymlinks(in: match.candidate, below: match.lexicalRoot)
        try ensureCanonicalContainment(match.candidate, root: match.root)
        var existing = stat()
        if lstat(match.candidate.path, &existing) == 0 {
            throw MCPPathPolicyError.localFileExists(match.candidate.path)
        }
        if errno != ENOENT {
            throw MCPPathPolicyError.cannotInspect(match.candidate.path)
        }
        let components = relativeComponents(for: match)
        guard !components.isEmpty else {
            throw MCPPathPolicyError.notRegularFile(match.candidate.path)
        }
        return DownloadTarget(
            destination: match.candidate,
            root: match.root,
            components: components
        )
    }

    private struct Match {
        let candidate: URL
        let root: Root
        /// The root spelling that matched the caller's path. A configured root
        /// itself may be a symlink (for example /tmp); descendants may not be.
        let lexicalRoot: URL
    }

    private func match(_ rawPath: String) throws -> Match {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw MCPPathPolicyError.absolutePathRequired(rawPath)
        }
        let candidate = URL(fileURLWithPath: expanded).standardizedFileURL
        for root in roots {
            if Self.contains(candidate.path, in: root.configured.path) {
                return Match(candidate: candidate, root: root, lexicalRoot: root.configured)
            }
            if Self.contains(candidate.path, in: root.canonical.path) {
                return Match(candidate: candidate, root: root, lexicalRoot: root.canonical)
            }
        }
        throw MCPPathPolicyError.outsideAllowedRoots(
            path: candidate.path,
            roots: allowedRootsDescription
        )
    }

    private func relativeComponents(for match: Match) -> [String] {
        String(match.candidate.path.dropFirst(match.lexicalRoot.path.count))
            .split(separator: "/")
            .map(String.init)
    }

    private func openUploadFile(_ match: Match) throws -> Int32 {
        try ensureCanonicalContainment(match.candidate, root: match.root)
        let components = relativeComponents(for: match)
        guard let filename = components.last else {
            throw MCPPathPolicyError.notRegularFile(match.candidate.path)
        }
        return try Self.withDirectoryDescriptor(
            root: match.root,
            components: Array(components.dropLast()),
            createMissing: false,
            candidatePath: match.candidate.path
        ) { parent in
            let descriptor = filename.withCString {
                openat(parent, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else {
                if Self.isSymbolicLink(parent: parent, name: filename) {
                    throw MCPPathPolicyError.symbolicLink(match.candidate.path)
                }
                throw MCPPathPolicyError.notRegularFile(match.candidate.path)
            }

            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == S_IFREG else {
                Darwin.close(descriptor)
                throw MCPPathPolicyError.notRegularFile(match.candidate.path)
            }
            guard info.st_nlink == 1 else {
                Darwin.close(descriptor)
                throw MCPPathPolicyError.hardLink(match.candidate.path)
            }
            return descriptor
        }
    }

    private func rejectSymlinks(in candidate: URL, below root: URL) throws {
        let relative = String(candidate.path.dropFirst(root.path.count))
            .split(separator: "/")
            .map(String.init)
        var current = root
        for component in relative {
            current.appendPathComponent(component)
            var info = stat()
            if lstat(current.path, &info) != 0 {
                // A not-yet-created download path is fine. No deeper existing
                // component can exist once an ancestor is missing.
                if errno == ENOENT { break }
                throw MCPPathPolicyError.cannotInspect(current.path)
            }
            if info.st_mode & S_IFMT == S_IFLNK {
                throw MCPPathPolicyError.symbolicLink(current.path)
            }
        }
    }

    private func ensureCanonicalContainment(_ candidate: URL, root: Root) throws {
        let canonical = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(canonical.path, in: root.canonical.path) else {
            throw MCPPathPolicyError.outsideAllowedRoots(
                path: candidate.path,
                roots: allowedRootsDescription
            )
        }
    }

    private static func contains(_ path: String, in root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func publishDownloadedFile(
        _ temporaryURL: URL,
        to target: DownloadTarget
    ) throws -> Int64 {
        let filename = target.components.last!
        return try withDirectoryDescriptor(
            root: target.root,
            components: Array(target.components.dropLast()),
            createMissing: true,
            candidatePath: target.destination.path
        ) { parent in
            var existing = stat()
            let exists = filename.withCString {
                fstatat(parent, $0, &existing, AT_SYMLINK_NOFOLLOW)
            } == 0
            if exists {
                throw MCPPathPolicyError.localFileExists(target.destination.path)
            }
            if errno != ENOENT {
                throw MCPPathPolicyError.cannotInspect(target.destination.path)
            }

            let source = temporaryURL.path.withCString {
                open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard source >= 0 else {
                throw MCPPathPolicyError.cannotInspect(temporaryURL.path)
            }
            defer { Darwin.close(source) }

            var sourceInfo = stat()
            guard fstat(source, &sourceInfo) == 0,
                  sourceInfo.st_mode & S_IFMT == S_IFREG else {
                throw MCPPathPolicyError.notRegularFile(temporaryURL.path)
            }

            let stagingName = ".ossuno-mcp-\(UUID().uuidString).tmp"
            let staging = stagingName.withCString {
                openat(
                    parent,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    mode_t(S_IRUSR | S_IWUSR)
                )
            }
            guard staging >= 0 else {
                throw MCPPathPolicyError.cannotWrite(target.destination.path)
            }
            var stagingExists = true
            defer {
                Darwin.close(staging)
                if stagingExists {
                    _ = stagingName.withCString { unlinkat(parent, $0, 0) }
                }
            }

            try copyFileDescriptor(from: source, to: staging)
            guard fsync(staging) == 0 else {
                throw MCPPathPolicyError.cannotWrite(target.destination.path)
            }

            let linked = stagingName.withCString { stagingPointer in
                filename.withCString { filenamePointer in
                    linkat(parent, stagingPointer, parent, filenamePointer, 0)
                }
            }
            guard linked == 0 else {
                if errno == EEXIST {
                    throw MCPPathPolicyError.localFileExists(target.destination.path)
                }
                throw MCPPathPolicyError.cannotWrite(target.destination.path)
            }
            stagingExists = stagingName.withCString { unlinkat(parent, $0, 0) } != 0
            return Int64(sourceInfo.st_size)
        }
    }

    private static func copyToPrivateTemporaryFile(from source: Int32) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        var template = Array(
            directory.appendingPathComponent("ossuno-mcp-upload-XXXXXX").path.utf8CString
        )
        let destination = mkstemp(&template)
        guard destination >= 0 else {
            throw MCPPathPolicyError.cannotWrite(directory.path)
        }
        let path = String(
            decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        let url = URL(fileURLWithPath: path)
        var keepFile = false
        defer {
            Darwin.close(destination)
            if !keepFile { try? FileManager.default.removeItem(at: url) }
        }
        guard fchmod(destination, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
            throw MCPPathPolicyError.cannotWrite(url.path)
        }
        try copyFileDescriptor(from: source, to: destination)
        guard fsync(destination) == 0 else {
            throw MCPPathPolicyError.cannotWrite(url.path)
        }
        keepFile = true
        return url
    }

    private static func copyFileDescriptor(from source: Int32, to destination: Int32) throws {
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        while true {
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(source, bytes.baseAddress, bytes.count)
            }
            if readCount == 0 { return }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw MCPPathPolicyError.cannotInspect("file descriptor")
            }
            var written = 0
            while written < readCount {
                let writeCount = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress!.advanced(by: written),
                        readCount - written
                    )
                }
                if writeCount < 0 {
                    if errno == EINTR { continue }
                    throw MCPPathPolicyError.cannotWrite("file descriptor")
                }
                written += writeCount
            }
        }
    }

    private static func withDirectoryDescriptor<Result>(
        root: Root,
        components: [String],
        createMissing: Bool,
        candidatePath: String,
        body: (Int32) throws -> Result
    ) throws -> Result {
        var current = root.canonical.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard current >= 0 else {
            throw MCPPathPolicyError.cannotInspect(root.configured.path)
        }
        defer { Darwin.close(current) }

        for component in components {
            var next = component.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0, errno == ENOENT, createMissing {
                let created = component.withCString {
                    mkdirat(current, $0, mode_t(S_IRWXU))
                }
                guard created == 0 || errno == EEXIST else {
                    throw MCPPathPolicyError.cannotWrite(candidatePath)
                }
                next = component.withCString {
                    openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
            }
            guard next >= 0 else {
                if isSymbolicLink(parent: current, name: component) {
                    throw MCPPathPolicyError.symbolicLink(candidatePath)
                }
                throw MCPPathPolicyError.cannotInspect(candidatePath)
            }
            Darwin.close(current)
            current = next
        }
        return try body(current)
    }

    private static func isSymbolicLink(parent: Int32, name: String) -> Bool {
        var info = stat()
        let inspected = name.withCString {
            fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        return inspected == 0 && info.st_mode & S_IFMT == S_IFLNK
    }

    private static func parseRoots(_ raw: String) throws -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MCPPathPolicyError.noAllowedRoots }
        if trimmed.hasPrefix("[") {
            guard let data = trimmed.data(using: .utf8),
                  let paths = try? JSONDecoder().decode([String].self, from: data) else {
                throw MCPPathPolicyError.invalidRootsConfiguration
            }
            return paths.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
        return trimmed.split(separator: ":", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

enum MCPPathPolicyError: LocalizedError, Equatable {
    case noAllowedRoots
    case invalidRootsConfiguration
    case invalidRoot(String)
    case absolutePathRequired(String)
    case outsideAllowedRoots(path: String, roots: String)
    case symbolicLink(String)
    case hardLink(String)
    case notRegularFile(String)
    case cannotInspect(String)
    case localFileExists(String)
    case cannotWrite(String)

    var errorDescription: String? {
        switch self {
        case .noAllowedRoots:
            return "未配置可访问的本地目录。请设置 \(MCPPathPolicy.environmentKey)。"
        case .invalidRootsConfiguration:
            return "\(MCPPathPolicy.environmentKey) 格式无效；请使用冒号分隔的绝对路径或 JSON 字符串数组。"
        case .invalidRoot(let path):
            return "允许目录必须是绝对路径且不能是文件系统根目录：\(path)"
        case .absolutePathRequired(let path):
            return "本地路径必须是绝对路径：\(path)"
        case .outsideAllowedRoots(let path, let roots):
            return "拒绝访问允许目录之外的路径：\(path)。当前允许目录：\(roots)。可通过 \(MCPPathPolicy.environmentKey) 配置。"
        case .symbolicLink(let path):
            return "拒绝通过符号链接访问本地文件：\(path)"
        case .hardLink(let path):
            return "拒绝通过硬链接访问本地文件：\(path)"
        case .notRegularFile(let path):
            return "上传源必须是存在的普通文件：\(path)"
        case .cannotInspect(let path):
            return "无法安全检查本地路径：\(path)"
        case .localFileExists(let path):
            return "本地已存在同名文件，未覆盖：\(path)。请换一个保存路径，或先删除该文件。"
        case .cannotWrite(let path):
            return "无法安全写入本地路径：\(path)"
        }
    }
}
