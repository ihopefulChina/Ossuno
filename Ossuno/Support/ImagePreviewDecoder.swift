import AppKit
import ImageIO

enum ImagePreviewDecoder {
    static func decode(_ data: Data, maxPixel: CGFloat) -> NSImage? {
        guard isDecodableImage(data) else { return nil }

        if looksLikeSVG(data) {
            return nsImage(from: data, maxPixel: maxPixel)
        }

        let sourceOptions = sourceOptions(for: data)
        if let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
                kCGImageSourceShouldCacheImmediately: true
            ]
            if let image = cgImage(from: source, options: options as CFDictionary) {
                return image
            }
            if let image = cgImage(from: source, options: nil) {
                return rasterized(image, maxPixel: maxPixel) ?? image
            }
        }
        return nsImage(from: data, maxPixel: maxPixel)
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        if looksLikeSVG(data) { return true }
        guard data.count >= 12 else { return false }
        // OSS IMG 失败时会返回 XML；不要把它当成图解。
        if data.first == 0x3C { return false }
        return true
    }

    static func looksLikeSVG(_ data: Data) -> Bool {
        guard let prefix = String(data: data.prefix(512), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        if prefix.hasPrefix("<svg") { return true }
        return prefix.hasPrefix("<?xml") && prefix.contains("<svg")
    }

    private static func sourceOptions(for data: Data) -> CFDictionary {
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let hint = typeHint(for: data) {
            options[kCGImageSourceTypeIdentifierHint] = hint
        }
        return options as CFDictionary
    }

    private static func typeHint(for data: Data) -> CFString? {
        if data.starts(with: [0xFF, 0xD8]) { return "public.jpeg" as CFString }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "public.png" as CFString }
        if data.count >= 12,
           data.starts(with: [0x52, 0x49, 0x46, 0x46]),
           data[8...11].elementsEqual([0x57, 0x45, 0x42, 0x50]) {
            return "org.webmproject.webp" as CFString
        }
        if data.starts(with: [0x47, 0x49, 0x46, 0x38]) { return "com.compuserve.gif" as CFString }
        if data.count >= 12,
           data[4...7].elementsEqual(Array("ftyp".utf8)),
           let brand = String(data: data[8..<12], encoding: .ascii) {
            switch brand {
            case "heic", "heix", "hevc", "hevx":
                return "public.heic" as CFString
            case "mif1", "msf1", "heif":
                return "public.heif" as CFString
            default:
                break
            }
        }
        return nil
    }

    private static func cgImage(from source: CGImageSource, options: CFDictionary?) -> NSImage? {
        let cg: CGImage?
        if let options {
            cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options)
                ?? CGImageSourceCreateImageAtIndex(source, 0, options)
        } else {
            cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let cg, cg.width > 0, cg.height > 0 else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func nsImage(from data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        if image.size.width <= 0 || image.size.height <= 0 {
            image.size = NSSize(width: maxPixel, height: maxPixel)
        }
        return rasterized(image, maxPixel: maxPixel) ?? image
    }

    private static func rasterized(_ image: NSImage, maxPixel: CGFloat) -> NSImage? {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = maxPixel / longest
        let width = max(1, Int((size.width * scale).rounded(.toNearestOrAwayFromZero)))
        let height = max(1, Int((size.height * scale).rounded(.toNearestOrAwayFromZero)))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: NSRect(origin: .zero, size: size),
            operation: .copy,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        let output = NSImage(size: NSSize(width: width, height: height))
        output.addRepresentation(rep)
        return output
    }
}
