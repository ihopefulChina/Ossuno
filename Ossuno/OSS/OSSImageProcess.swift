import Foundation

enum OSSImageProcess {
    case grid
    case row
    case inspector

    var query: String {
        switch self {
        case .grid:
            "image/resize,m_fill,w_128,h_128,limit_1"
        case .row:
            "image/resize,m_lfit,w_40,h_40,limit_1"
        case .inspector:
            "image/resize,m_lfit,w_640,h_640,limit_1"
        }
    }

    var cacheKey: String {
        switch self {
        case .grid: "g4"
        case .row: "r2"
        case .inspector: "i3"
        }
    }

    func queries(for key: String) -> [String] {
        // WebP / HEIC / GIF 处理后 ImageIO 经常解不开。先向 IMG 要 JPEG，
        // 列表单元格复用窗口短，少一次失败重试更容易出图。
        if ImageKind.needsJPEGPreview(key: key) {
            return [
                query + "/format,jpg",
                "image/resize,m_lfit,w_160,h_160/format,jpg",
                query
            ]
        }
        return [query, "image/resize,m_lfit,w_160,limit_1"]
    }

    var maxPixel: CGFloat {
        switch self {
        case .grid: 128
        case .row: 40
        case .inspector: 640
        }
    }
}
