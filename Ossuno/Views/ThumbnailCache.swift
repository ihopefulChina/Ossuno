import AppKit
import Foundation

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private static let originalPreviewBytes = 4_000_000
    private static let memoryLimit = 280

    private var memory: [String: NSImage] = [:]
    private var order: [String] = []
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let limit = 6

    func load(
        object: OSSObject,
        style: OSSImageProcess,
        scope: String,
        client: OSSClient
    ) async -> NSImage? {
        let token = "\(scope)|\(style.cacheKey)|\(object.key)|\(object.etag)"
        if let cached = memory[token] {
            touch(token)
            return cached
        }
        if let existing = inflight[token] {
            return await existing.value
        }

        let task = Task<NSImage?, Never> { [object, style, client] in
            await self.fetch(object: object, style: style, client: client)
        }
        inflight[token] = task
        let image = await task.value
        inflight[token] = nil
        if let image {
            store(token, image: image)
        }
        return image
    }

    private func fetch(
        object: OSSObject,
        style: OSSImageProcess,
        client: OSSClient
    ) async -> NSImage? {
        let key = object.key
        let queries = ImageKind.imgProcessable(key: key) ? style.queries(for: key) : []
        let maxPixel = style.maxPixel
        let allowOriginal = !ImageKind.imgProcessable(key: key)
            || object.size <= Int64(Self.originalPreviewBytes)
        await waitForSlot()
        defer { finishSlot() }
        if Task.isCancelled { return nil }

        var loadedImage: NSImage?
        for process in queries {
            if Task.isCancelled { return nil }
            if let data = try? await client.objectData(key: key, process: process),
               data.count <= Self.originalPreviewBytes,
               let image = ImagePreviewDecoder.decode(data, maxPixel: maxPixel) {
                loadedImage = image
                break
            }
        }
        if loadedImage == nil,
           allowOriginal,
           !Task.isCancelled,
           let data = try? await client.objectData(key: key),
           data.count <= Self.originalPreviewBytes {
            loadedImage = ImagePreviewDecoder.decode(data, maxPixel: maxPixel)
        }
        return loadedImage
    }

    private func store(_ token: String, image: NSImage) {
        memory[token] = image
        touch(token)
        while order.count > Self.memoryLimit {
            let evicted = order.removeFirst()
            memory.removeValue(forKey: evicted)
        }
    }

    private func touch(_ token: String) {
        order.removeAll { $0 == token }
        order.append(token)
    }

    private func waitForSlot() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func finishSlot() {
        if waiters.isEmpty {
            running = max(0, running - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
