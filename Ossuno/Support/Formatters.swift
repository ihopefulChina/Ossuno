import Foundation

enum Formatters {
    static func bytes(_ value: Int64) -> String {
        if value == 0 { return "0 KB" }
        return value.formatted(
            .byteCount(
                style: .file,
                allowedUnits: [.bytes, .kb, .mb, .gb],
                spellsOutZero: false,
                includesActualByteCount: false
            )
        )
    }

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return value.formatted(date: .abbreviated, time: .shortened)
    }
}

enum ImageKind {
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp",
        "png", "apng",
        "gif",
        "webp",
        "bmp", "dib",
        "tif", "tiff",
        "heic", "heif", "heics",
        "avif",
        "svg", "svgz",
        "ico", "cur",
        "jp2", "j2k", "jpf", "jpx",
        "jxl"
    ]

    static let textExtensions: Set<String> = [
        "txt", "text", "log",
        "json", "jsonl", "ndjson", "csv", "tsv",
        "md", "markdown", "html", "htm", "css", "scss", "sass", "less",
        "js", "mjs", "cjs", "jsx", "ts", "tsx", "vue", "svelte",
        "xml", "yaml", "yml", "toml", "ini", "conf", "config", "env", "properties", "plist",
        "sql", "graphql", "gql",
        "sh", "bash", "zsh", "fish", "swift", "m", "mm", "h", "hpp", "c", "cc", "cpp",
        "java", "kt", "kts", "py", "rb", "php", "go", "rs", "dart", "lua", "gradle"
    ]

    /// 「只显示素材文件」浏览过滤覆盖的素材类型全集。
    /// 上传不做任何类型限制（OSS 本身支持任意文件），这里仅决定哪些文件算「素材」。
    static let materialExtensions: Set<String> = [
        // 视频
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "f4v",
        "mpg", "mpeg", "mpe", "3gp", "3g2", "rm", "rmvb",
        "mts", "m2ts", "m2t", "asf",
        // 音频
        "mp3", "wav", "aac", "m4a", "flac", "ogg", "oga", "wma",
        "aiff", "aif", "mid", "midi", "opus", "caf",
        // 设计 / 创意源文件
        "psd", "psb", "ai", "eps", "sketch", "fig", "xd",
        "indd", "idml", "cdr", "afdesign", "afphoto", "afpublisher", "procreate",
        // 相机 RAW
        "raw", "cr2", "cr3", "nef", "arw", "dng", "orf",
        "rw2", "raf", "pef", "srw",
        // 文档
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "key", "pages", "numbers", "csv", "tsv", "md", "markdown", "rtf", "epub",
        // 压缩包 / 镜像
        "zip", "zipx", "rar", "7z", "tar", "gz", "bz2", "xz", "zst",
        "dmg", "iso", "pkg", "apk",
        // 字体
        "ttf", "otf", "ttc", "woff", "woff2",
        // 常见网页 / 配置 / 代码素材
        "html", "htm", "css", "js", "mjs", "jsx", "ts", "tsx",
        "xml", "yaml", "yml", "toml", "ini", "plist", "sql", "graphql"
    ]

    static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "avi", "mkv", "webm", "wmv", "flv", "f4v",
        "mpg", "mpeg", "mpe", "3gp", "3g2", "rm", "rmvb",
        "mts", "m2ts", "m2t", "asf"
    ]

    static let audioExtensions: Set<String> = [
        "mp3", "wav", "aac", "m4a", "flac", "ogg", "oga", "wma",
        "aiff", "aif", "mid", "midi", "opus", "caf"
    ]

    static func `extension`(of key: String) -> String {
        (key as NSString).pathExtension.lowercased()
    }

    static func isImage(key: String) -> Bool {
        imageExtensions.contains(`extension`(of: key))
    }

    static func isText(key: String) -> Bool {
        textExtensions.contains(`extension`(of: key))
    }

    static func isVideo(key: String) -> Bool {
        videoExtensions.contains(`extension`(of: key))
    }

    static func isAudio(key: String) -> Bool {
        audioExtensions.contains(`extension`(of: key))
    }

    static func isSupported(key: String) -> Bool {
        let ext = `extension`(of: key)
        return imageExtensions.contains(ext)
            || textExtensions.contains(ext)
            || materialExtensions.contains(ext)
    }

    static func contentType(for key: String) -> String {
        switch `extension`(of: key) {
        // 图片
        case "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp": "image/jpeg"
        case "png", "apng": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        case "heic", "heics": "image/heic"
        case "heif": "image/heif"
        case "tif", "tiff": "image/tiff"
        case "bmp", "dib": "image/bmp"
        case "svg", "svgz": "image/svg+xml"
        case "avif": "image/avif"
        case "jxl": "image/jxl"
        case "ico", "cur": "image/x-icon"
        case "jp2", "j2k", "jpf", "jpx": "image/jp2"
        case "psd", "psb": "image/vnd.adobe.photoshop"
        case "ai", "eps": "application/postscript"
        case "dng": "image/dng"
        case "cr2": "image/x-canon-cr2"
        case "cr3": "image/x-canon-cr3"
        case "nef": "image/x-nikon-nef"
        case "arw": "image/x-sony-arw"
        case "orf": "image/x-olympus-orf"
        case "rw2": "image/x-panasonic-rw2"
        case "raf": "image/x-fuji-raf"
        case "pef": "image/x-pentax-pef"
        // 视频
        case "mp4": "video/mp4"
        case "m4v": "video/x-m4v"
        case "mov": "video/quicktime"
        case "avi": "video/x-msvideo"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "wmv": "video/x-ms-wmv"
        case "flv", "f4v": "video/x-flv"
        case "mpg", "mpeg", "mpe": "video/mpeg"
        case "3gp": "video/3gpp"
        case "3g2": "video/3gpp2"
        case "rm", "rmvb": "application/vnd.rn-realmedia"
        case "mts", "m2ts", "m2t": "video/mp2t"
        case "asf": "video/x-ms-asf"
        // 音频
        case "mp3": "audio/mpeg"
        case "wav": "audio/wav"
        case "aac": "audio/aac"
        case "m4a": "audio/mp4"
        case "flac": "audio/flac"
        case "ogg", "oga": "audio/ogg"
        case "wma": "audio/x-ms-wma"
        case "aiff", "aif": "audio/aiff"
        case "mid", "midi": "audio/midi"
        case "opus": "audio/opus"
        case "caf": "audio/x-caf"
        // 文档
        case "pdf": "application/pdf"
        case "doc": "application/msword"
        case "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": "application/vnd.ms-excel"
        case "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": "application/vnd.ms-powerpoint"
        case "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        case "key": "application/x-iwork-keynote-sffkey"
        case "pages": "application/x-iwork-pages-sffpages"
        case "numbers": "application/x-iwork-numbers-sffnumbers"
        case "csv": "text/csv"
        case "tsv": "text/tab-separated-values"
        case "md", "markdown": "text/markdown"
        case "rtf": "text/rtf"
        case "epub": "application/epub+zip"
        // 压缩包 / 镜像
        case "zip", "zipx": "application/zip"
        case "rar": "application/vnd.rar"
        case "7z": "application/x-7z-compressed"
        case "tar": "application/x-tar"
        case "gz": "application/gzip"
        case "bz2": "application/x-bzip2"
        case "xz": "application/x-xz"
        case "zst": "application/zstd"
        case "dmg": "application/x-apple-diskimage"
        case "iso": "application/x-iso9660-image"
        case "apk": "application/vnd.android.package-archive"
        // 字体
        case "ttf": "font/ttf"
        case "otf": "font/otf"
        case "ttc": "font/collection"
        case "woff": "font/woff"
        case "woff2": "font/woff2"
        // 文本 / 网页 / 配置
        case "json", "jsonl", "ndjson": "application/json"
        case "txt", "text", "log": "text/plain"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "js", "mjs", "cjs", "jsx": "text/javascript"
        case "ts", "tsx": "text/plain"
        case "xml": "application/xml"
        case "yaml", "yml": "application/yaml"
        case "toml": "application/toml"
        case "sql": "application/sql"
        // 设计源文件（无官方 MIME 的用通用二进制）
        case "sketch": "application/x-sketch"
        case "fig": "application/x-figma"
        case "xd": "application/vnd.adobe.xd"
        case "indd", "idml": "application/x-indesign"
        case "cdr": "application/vnd.corel-draw"
        case "afdesign": "application/x-affinity-designer"
        case "afphoto": "application/x-affinity-photo"
        case "afpublisher": "application/x-affinity-publisher"
        case "procreate": "application/x-procreate"
        default: "application/octet-stream"
        }
    }

    static func displayKind(for key: String) -> String {
        let ext = `extension`(of: key).uppercased()
        if ext.isEmpty { return "文件" }
        if isImage(key: key) { return "\(ext) 图片" }
        if ext == "JSON" { return "JSON" }
        if isText(key: key) { return "\(ext) 文本" }
        if isVideo(key: key) { return "\(ext) 视频" }
        if isAudio(key: key) { return "\(ext) 音频" }
        return "\(ext) 文件"
    }

    /// WebP / HEIC / GIF 处理后 ImageIO 经常解不开，缩略图再要一版 JPEG。
    static func needsJPEGPreview(key: String) -> Bool {
        switch `extension`(of: key) {
        case "webp", "heic", "heif", "heics", "gif", "avif":
            true
        default:
            false
        }
    }

    /// Aliyun IMG can decode these for `x-oss-process`. SVG / ICO 等只能当对象存。
    static func imgProcessable(key: String) -> Bool {
        switch `extension`(of: key) {
        case "jpg", "jpeg", "jpe", "jfif", "pjpeg", "pjp",
             "png", "apng",
             "gif",
             "webp",
             "bmp", "dib",
             "tif", "tiff",
             "heic", "heif", "heics",
             "avif":
            true
        default:
            false
        }
    }
}
