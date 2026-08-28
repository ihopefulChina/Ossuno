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

        var info = stat()
        guard lstat(match.candidate.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw MCPPathPolicyError.notRegularFile(match.candidate.path)
        }
        if info.st_nlink > 1 {
            throw MCPPathPolicyError.hardLink(match.candidate.path)
        }
        try ensureCanonicalContainment(match.candidate, root: match.root)
        return match.candidate
    }

    func validateDownloadPath(_ rawPath: String) throws -> URL {
        let match = try match(rawPath)
        try rejectSymlinks(in: match.candidate, below: match.lexicalRoot)
        try ensureCanonicalContainment(match.candidate, root: match.root)
        return match.candidate
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
        }
    }
}
