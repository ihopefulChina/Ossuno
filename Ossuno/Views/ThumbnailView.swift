import AppKit
import SwiftUI

struct ThumbnailView: View {
    let object: OSSObject
    var style: OSSImageProcess = .grid
    /// Client factory captured at the view's call site. Table rows render in
    /// an AppKit cell context where `@Environment(AppModel.self)` is not
    /// reliably available, so the model is never read from the environment
    /// here.
    var loadClient: () -> OSSClient?
    /// Distinguishes the same object key across accounts or buckets so a
    /// cached preview cannot leak into another workspace.
    var scope: String = ""
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Color(nsColor: .quaternaryLabelColor)
            .opacity(0.18)
            .overlay {
                if object.isImage {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } else if failed {
                        FinderFileIcon(key: object.key, size: style == .row ? 16 : 48)
                    } else if style == .row {
                        FinderFileIcon(key: object.key, size: 16)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                } else {
                    FinderFileIcon(key: object.key, size: style == .row ? 16 : 64)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: scope + object.etag + object.key + style.cacheKey) {
                image = nil
                failed = false
                await load()
            }
    }

    private func load() async {
        guard object.isImage else { return }
        guard let client = loadClient() else {
            failed = true
            return
        }
        if let nsImage = await ThumbnailCache.shared.load(
            object: object,
            style: style,
            scope: scope,
            client: client
        ) {
            image = nsImage
        } else {
            failed = true
        }
    }
}
