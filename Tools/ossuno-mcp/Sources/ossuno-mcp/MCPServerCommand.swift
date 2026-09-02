import Foundation
import MCP

enum MCPServerCommand {
    /// 默认 Bucket：来自环境变量 OSSUNO_MCP_DEFAULT_BUCKET（由 MCP 客户端配置的 env 传入）。
    /// 设置后所有工具的 bucket 参数变为可选，未传时自动回退到该值。
    private static let defaultBucket: String? = {
        guard let raw = ProcessInfo.processInfo.environment["OSSUNO_MCP_DEFAULT_BUCKET"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }()

    static var serverInstructions: String {
        let defaultBucketLine = defaultBucket.map {
            "- 用户未指定 Bucket 时，默认使用「\($0)」（来自环境变量 OSSUNO_MCP_DEFAULT_BUCKET）。"
        } ?? "- 未设置默认 Bucket：用户未指定 Bucket 时，先 list_buckets 再与用户确认目标。"
        return """
        ossuno-mcp 让你直接操作用户的阿里云 OSS（凭证已保存在 macOS 钥匙串，无需向用户索要）。

        工具：list_buckets 列出 Bucket；list_objects 按文件夹层级浏览（delimiter 传空字符串可递归）；\
        upload_file 上传本机文件；download_file 下载到本机；presign_url 生成私有 Bucket 的临时下载链接。

        约定：
        \(defaultBucketLine)
        - 先浏览确认再操作：不确定路径就用 list_objects 逐层看。
        - 上传后报告 bucket、key 与 URL；私有 Bucket 分享用 presign_url 生成的临时链接。
        - upload_file 默认拒绝覆盖远端同名对象；只有用户明确确认后才能传 overwrite=true。
        - 下载不覆盖本地同名文件，遇到报错时与用户确认新路径。
        - 本地文件仅允许访问 OSSUNO_MCP_ALLOWED_ROOTS 配置的目录；默认是桌面、文稿、下载和临时目录。
        - 删除、覆盖、批量操作前，先向用户复述范围并确认。
        - GB 级大文件建议用户改用 Ossuno App（分片上传、断点续传更完整）。
        """
    }

    static func run() async -> Int32 {
        let server = Server(
            name: "ossuno-mcp",
            version: OssunoMCPVersion.current,
            instructions: serverInstructions,
            capabilities: .init(
                prompts: .init(listChanged: false),
                tools: .init(listChanged: false)
            )
        )

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: Self.toolDefinitions())
        }

        await server.withMethodHandler(CallTool.self) { params in
            await Self.handleCall(params)
        }

        await server.withMethodHandler(ListPrompts.self) { _ in
            ListPrompts.Result(prompts: Self.promptDefinitions())
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            try Self.handleGetPrompt(params)
        }

        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            // start() is non-blocking; wait until the message loop ends (stdin EOF).
            await server.waitUntilCompleted()
        } catch {
            let message = "ossuno-mcp 服务启动或传输失败：\(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            return 1
        }
        return 0
    }

    // MARK: - Tool definitions

    static func toolDefinitions() -> [Tool] {
        func schema(_ properties: [String: Value], required: [String]) -> Value {
            .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(required.map { .string($0) }),
            ])
        }
        func stringProp(_ describe: String) -> Value {
            .object(["type": .string("string"), "description": .string(describe)])
        }
        func intProp(_ describe: String, _ default: Int) -> Value {
            .object([
                "type": .string("integer"),
                "description": .string(describe),
                "default": .int(`default`),
            ])
        }
        func boolProp(_ describe: String, _ default: Bool) -> Value {
            .object([
                "type": .string("boolean"),
                "description": .string(describe),
                "default": .bool(`default`),
            ])
        }

        // 设置了默认 Bucket 时，bucket 参数变为可选，并把实际默认值写进描述让 AI 直接可见。
        let bucketRequired = defaultBucket == nil
        func bucketProp(_ label: String) -> Value {
            if let defaultBucket {
                return stringProp("\(label)；不传时默认使用 \(defaultBucket)")
            }
            return stringProp(label)
        }
        func requiredBucket(_ others: [String]) -> [String] {
            bucketRequired ? ["bucket"] + others : others
        }

        return [
            Tool(
                name: "list_buckets",
                description: "列出当前 OSS 账号下的所有 Bucket（名称、地域、创建时间）。",
                inputSchema: schema([:], required: []),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "list_objects",
                description: "列出指定 Bucket 中的对象和子文件夹。默认按文件夹层级（delimiter=/）浏览；要递归列出所有对象时传 delimiter 为空字符串。",
                inputSchema: schema([
                    "bucket": bucketProp("Bucket 名称"),
                    "prefix": stringProp("对象前缀（文件夹路径），可选"),
                    "delimiter": stringProp("分隔符，默认 '/'；空字符串表示递归列出"),
                    "max_keys": intProp("最多返回条数（1-1000），默认 200", 200),
                    "continuation_token": stringProp("上一页返回的 next_continuation_token；获取下一页时原样传入"),
                ], required: requiredBucket([])),
                annotations: .init(readOnlyHint: true)
            ),
            Tool(
                name: "upload_file",
                description: "上传允许目录内的本机普通文件到 OSS。默认查询 Bucket 版本控制状态并拒绝覆盖；版本控制为 Enabled/Suspended 或状态无法确认时安全拒绝。只有用户明确确认覆盖后才能传 overwrite=true。大文件建议使用 Ossuno App。",
                inputSchema: schema([
                    "bucket": bucketProp("目标 Bucket 名称"),
                    "local_path": stringProp("允许目录内、且不经过符号链接的本地普通文件绝对路径"),
                    "key": stringProp("目标对象 Key（含路径），缺省使用本地文件名"),
                    "content_type": stringProp("Content-Type，缺省按扩展名推断"),
                    "overwrite": boolProp("是否覆盖远端同名对象，默认 false；true 会跳过版本状态与存在性保护。仅在用户明确确认覆盖后设为 true，版本控制为 Suspended 时覆盖可能不可逆", false),
                ], required: requiredBucket(["local_path"])),
                annotations: .init(destructiveHint: true, idempotentHint: false)
            ),
            Tool(
                name: "download_file",
                description: "从 OSS 下载对象到本机指定路径。",
                inputSchema: schema([
                    "bucket": bucketProp("Bucket 名称"),
                    "key": stringProp("对象 Key"),
                    "local_path": stringProp("允许目录内、且不经过符号链接的本地保存绝对路径"),
                ], required: requiredBucket(["key", "local_path"]))
            ),
            Tool(
                name: "presign_url",
                description: "为私有 Bucket 中的对象生成带签名的临时下载链接。",
                inputSchema: schema([
                    "bucket": bucketProp("Bucket 名称"),
                    "key": stringProp("对象 Key"),
                    "expires_seconds": intProp("链接有效期（秒），默认 3600，最长 604800", 3600),
                ], required: requiredBucket(["key"])),
                annotations: .init(readOnlyHint: true)
            ),
        ]
    }

    // MARK: - Dispatch

    private static func handleCall(_ params: CallTool.Parameters) async -> CallTool.Result {
        let arguments = params.arguments ?? [:]
        let client: MCPOSSClient
        do {
            let profile = try ProfileStore.loadActive()
            client = MCPOSSClient(profile: profile)
        } catch {
            return errorResult(
                "\(error.localizedDescription)\n请先运行 `ossuno-mcp auth` 配置 OSS 凭证。"
            )
        }

        do {
            switch params.name {
            case "list_buckets":
                return try await listBuckets(client)
            case "list_objects":
                return try await listObjects(client, arguments)
            case "upload_file":
                return try await uploadFile(client, arguments)
            case "download_file":
                return try await downloadFile(client, arguments)
            case "presign_url":
                return try await presignURL(client, arguments)
            default:
                return errorResult("未知工具：\(params.name)")
            }
        } catch {
            return errorResult("操作失败：\(error.localizedDescription)")
        }
    }

    // MARK: - Tool implementations

    /// bucket 解析：优先取调用参数，缺失时回退到环境变量配置的默认 Bucket。
    private static func resolveBucket(_ arguments: [String: Value]) throws -> String {
        if let bucket = arguments["bucket"]?.mcpString, !bucket.isEmpty {
            return bucket
        }
        if let defaultBucket {
            return defaultBucket
        }
        throw MissingArgumentError(
            "bucket（未传 bucket 且未设置默认 Bucket；可在 MCP 客户端配置 env OSSUNO_MCP_DEFAULT_BUCKET 指定默认值）"
        )
    }

    private static func listBuckets(_ client: MCPOSSClient) async throws -> CallTool.Result {
        let buckets = try await client.listBuckets()
        let formatter = ISO8601DateFormatter()
        let payload = buckets.map { bucket -> [String: Value] in
            var item: [String: Value] = [
                "name": .string(bucket.name),
                "region": .string(bucket.regionID),
            ]
            if let createdAt = bucket.createdAt {
                item["created_at"] = .string(formatter.string(from: createdAt))
            }
            return item
        }
        return textResult(Self.encodeJSON([
            "count": .int(buckets.count),
            "buckets": .array(payload.map { .object($0) }),
        ]))
    }

    private static func listObjects(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let bucket = try resolveBucket(arguments)
        let prefix = arguments["prefix"]?.mcpString
        let delimiterRaw = arguments["delimiter"]?.mcpString
        let delimiter: String?
        if let delimiterRaw {
            delimiter = delimiterRaw.isEmpty ? nil : delimiterRaw
        } else {
            delimiter = "/"
        }
        let maxKeys = arguments["max_keys"]?.mcpInt ?? 200
        let continuationToken = arguments["continuation_token"]?.mcpString

        let listing = try await client.listObjects(
            bucket: bucket,
            prefix: prefix,
            delimiter: delimiter,
            maxKeys: maxKeys,
            token: continuationToken
        )
        let formatter = ISO8601DateFormatter()
        let folders = listing.folders.map { folder -> [String: Value] in
            ["prefix": .string(folder.prefix)]
        }
        let objects = listing.objects.map { object -> [String: Value] in
            var item: [String: Value] = [
                "key": .string(object.key),
                "size": .int(Int(object.size)),
            ]
            if let lastModified = object.lastModified {
                item["last_modified"] = .string(formatter.string(from: lastModified))
            }
            if !object.etag.isEmpty {
                item["etag"] = .string(object.etag)
            }
            return item
        }
        var payload: [String: Value] = [
            "bucket": .string(bucket),
            "prefix": .string(prefix ?? ""),
            "folders": .array(folders.map { .object($0) }),
            "objects": .array(objects.map { .object($0) }),
            "truncated": .bool(listing.isTruncated),
        ]
        if let next = listing.nextToken {
            payload["next_continuation_token"] = .string(next)
        }
        return textResult(Self.encodeJSON(.object(payload)))
    }

    private static func uploadFile(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let bucket = try resolveBucket(arguments)
        guard let localPath = arguments["local_path"]?.mcpString, !localPath.isEmpty else {
            throw MissingArgumentError("local_path")
        }
        let pathPolicy = try MCPPathPolicy()
        let stagedUpload = try pathPolicy.stageUploadPath(localPath)
        defer { try? FileManager.default.removeItem(at: stagedUpload.fileURL) }
        let fileURL = stagedUpload.originalURL
        var key = arguments["key"]?.mcpString ?? ""
        if key.isEmpty {
            key = fileURL.lastPathComponent
        }
        key = key.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !key.isEmpty else { throw MissingArgumentError("key（对象 Key 不能为空）") }
        let contentType = try MCPHTTPSafety.validatedContentType(
            arguments["content_type"]?.mcpString
                ?? contentTypeHint(forExtension: fileURL.pathExtension)
        )
        let overwrite = arguments["overwrite"]?.mcpBool ?? false
        let result = try await client.uploadFile(
            bucket: bucket,
            key: key,
            fileURL: stagedUpload.fileURL,
            contentType: contentType,
            overwrite: overwrite
        )
        return textResult(Self.encodeJSON([
            "bucket": .string(result.bucket),
            "key": .string(result.key),
            "size": .int(Int(result.size)),
            "etag": .string(result.etag),
            "url": .string(result.url.absoluteString),
            "note": .string("url 为直链；若 Bucket 为私有读，请改用 presign_url 工具生成临时链接。"),
        ]))
    }

    private static func downloadFile(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let bucket = try resolveBucket(arguments)
        guard let key = arguments["key"]?.mcpString, !key.isEmpty else {
            throw MissingArgumentError("key")
        }
        guard let localPath = arguments["local_path"]?.mcpString, !localPath.isEmpty else {
            throw MissingArgumentError("local_path")
        }
        let pathPolicy = try MCPPathPolicy()
        let target = try pathPolicy.prepareDownloadPath(localPath)
        let result = try await client.downloadFile(bucket: bucket, key: key, to: target)
        return textResult(Self.encodeJSON([
            "bucket": .string(result.bucket),
            "key": .string(result.key),
            "local_path": .string(result.localPath),
            "size": .int(Int(result.size)),
        ]))
    }

    private static func presignURL(_ client: MCPOSSClient, _ arguments: [String: Value]) async throws -> CallTool.Result {
        let bucket = try resolveBucket(arguments)
        guard let key = arguments["key"]?.mcpString, !key.isEmpty else {
            throw MissingArgumentError("key")
        }
        var expires = arguments["expires_seconds"]?.mcpInt ?? 3600
        expires = max(1, min(expires, 604_800))
        let url = try client.presignedURL(bucket: bucket, key: key, expires: expires)
        return textResult(Self.encodeJSON([
            "url": .string(url.absoluteString),
            "expires_seconds": .int(expires),
        ]))
    }

    // MARK: - Helpers

    private static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func encodeJSON(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func contentTypeHint(forExtension ext: String) -> String? {
        let table = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "gif": "image/gif",
            "webp": "image/webp",
            "avif": "image/avif",
            "svg": "image/svg+xml",
            "heic": "image/heic",
            "pdf": "application/pdf",
            "json": "application/json",
            "txt": "text/plain",
            "md": "text/markdown",
            "html": "text/html",
            "css": "text/css",
            "js": "text/javascript",
            "mp4": "video/mp4",
            "mp3": "audio/mpeg",
            "zip": "application/zip",
        ]
        return table[ext.lowercased()]
    }

    // MARK: - Prompts

    private static func promptDefinitions() -> [Prompt] {
        [
            Prompt(
                name: "ossuno-oss-expert",
                title: "OSS 专家模式",
                description: "把 Agent 定位为阿里云 OSS 操作专家，附安全使用规则"
            ),
            Prompt(
                name: "oss-batch-upload",
                title: "批量上传工作流",
                description: "按步骤把一个本机目录批量上传到 OSS，保留目录结构",
                arguments: [
                    .init(
                        name: "directory",
                        title: "源目录",
                        description: "待上传的本机目录绝对路径",
                        required: false
                    )
                ]
            )
        ]
    }

    private static func handleGetPrompt(_ params: GetPrompt.Parameters) throws -> GetPrompt.Result {
        let directory = params.arguments?["directory"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let source = directory.isEmpty ? "（先向用户确认）" : directory

        switch params.name {
        case "ossuno-oss-expert":
            return GetPrompt.Result(
                description: "OSS 专家模式",
                messages: [
                    .user(.text(text: """
                    你现在是阿里云 OSS 操作专家，通过 ossuno-mcp 的工具帮助用户管理 OSS 文件。

                    工作规则：
                    1. 先弄清目标再动手：不确定 Bucket 时先 list_buckets；不确定路径时用 list_objects 逐层浏览（delimiter 默认 '/'，传空可递归）。
                    2. 上传后报告 bucket、key 和对象 URL；若 Bucket 为私有读，主动用 presign_url 生成临时链接再交给用户。
                    3. upload_file 默认拒绝远端覆盖。只有用户明确确认要替换同名对象并理解版本控制暂停时可能不可逆后，才传 overwrite=true。
                    4. 下载前确认保存路径；本地已有同名文件会报错，此时与用户确认新路径，不建议直接覆盖。
                    5. 本地路径必须位于允许目录内，不得尝试绕过目录或符号链接限制。
                    6. 删除、覆盖、批量操作，先向用户复述范围并获得确认。
                    7. GB 级大文件提醒用户改用 Ossuno App（分片上传、断点续传更完整）。
                    8. 回答简洁：给关键结果（key、URL、大小），不堆砌原始 JSON。
                    """))
                ]
            )
        case "oss-batch-upload":
            return GetPrompt.Result(
                description: "批量上传工作流",
                messages: [
                    .user(.text(text: """
                    请把本机目录「\(source)」批量上传到 OSS，步骤：
                    1. 与用户确认目标 Bucket 和 key 前缀；不确定 Bucket 时先 list_buckets。
                    2. 列出目录下待上传文件（含子目录），展示清单与总大小。
                    3. 逐个调用 upload_file，key = 「目标前缀 + 相对路径」，保持目录结构。
                    4. 汇总成功/失败清单，失败的说明原因；私有 Bucket 再生成一条示例 presign_url。
                    """))
                ]
            )
        default:
            throw MissingArgumentError("未知的提示词：\(params.name)")
        }
    }
}

struct MissingArgumentError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { "缺少或无效的参数：\(message)" }
}

extension Value {
    var mcpString: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var mcpInt: Int? {
        if case .int(let value) = self { return value }
        if case .double(let value) = self,
           value.isFinite,
           value >= Double(Int.min),
           value < Double(Int.max) {
            return Int(value)
        }
        return nil
    }

    var mcpBool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
