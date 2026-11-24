import CloudReaderCore
import ImageIO
import UIKit

/// Disposable, device-local thumbnails derived from the managed book files.
actor BookCoverThumbnails {
    static let shared = BookCoverThumbnails()
    private static let maxPixelSize = 640
    private let cache = NSCache<NSURL, Entry>()

    private struct FileVersion: Equatable {
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init?(at url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }
    }

    private final class Entry {
        let version: FileVersion
        let format: BookFormat
        let image: UIImage?

        init(version: FileVersion, format: BookFormat, image: UIImage?) {
            self.version = version
            self.format = format
            self.image = image
        }
    }

    init() {
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1_024 * 1_024
    }

    func thumbnail(at url: URL, format: BookFormat) async -> UIImage? {
        guard format != .txt, !Task.isCancelled, let version = FileVersion(at: url) else { return nil }
        let key = url as NSURL
        if let entry = cache.object(forKey: key), entry.version == version, entry.format == format {
            return entry.image
        }
        let image: UIImage?
        do {
            image = try await loadThumbnail(at: url, format: format)
        } catch {
            // Retry a failed read the next time the tile appears.
            return nil
        }
        guard !Task.isCancelled, FileVersion(at: url) == version else { return nil }
        let cost = image?.cgImage.map { $0.bytesPerRow * $0.height } ?? 1
        cache.setObject(Entry(version: version, format: format, image: image), forKey: key, cost: cost)
        return image
    }

    private func loadThumbnail(at url: URL, format: BookFormat) async throws -> UIImage? {
        let artwork: Data?
        switch format {
        case .epub: artwork = try EPUBLoader.coverData(at: url)
        case .mobi, .azw3: artwork = try KindleCoverSource.imageData(at: url)
        case .fb2: artwork = try IllustratedCoverSource.fb2(at: url)
        case .cbz: artwork = try IllustratedCoverSource.cbz(at: url)
        case .cbr: artwork = try IllustratedCoverSource.cbr(at: url)
        case .pdf: return Self.firstPDFPage(at: url)
        case .txt: return nil
        }
        guard let artwork else { return nil }
        try Task.checkCancellation()
        if let image = Self.downsample(artwork) { return image }
        guard let vector = await SVGCoverThumbnail.thumbnail(data: artwork, maxPixelSize: Self.maxPixelSize) else {
            // Unlike an absent cover, a decoder failure can be temporary.
            throw CocoaError(.fileReadUnknown)
        }
        return vector
    }

    private static func downsample(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: thumbnail)
    }

    private static func thumbnailSize(for size: CGSize) -> CGSize? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        let limit = CGFloat(maxPixelSize)
        return CGSize(width: max(1, (size.width / longest * limit).rounded()),
                      height: max(1, (size.height / longest * limit).rounded()))
    }

    private static func firstPDFPage(at url: URL) -> UIImage? {
        guard let document = CGPDFDocument(url as CFURL), document.isUnlocked,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox).standardized
        let rotated = page.rotationAngle % 180 != 0
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard let size = thumbnailSize(for: pageSize),
              let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(bounds)
        context.concatenate(page.getDrawingTransform(.cropBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let bitmap = context.makeImage() else { return nil }
        return UIImage(cgImage: bitmap)
    }
}
