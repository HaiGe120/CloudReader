import Foundation
import ImageIO

enum KindleCoverSource {
    static func imageData(at url: URL) throws -> Data? {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= KindlePreflight.maximumInputBytes else { return nil }
        // Header validation and resource lookup only touch the mapped pages they need.
        let book = try Data(contentsOf: url, options: .alwaysMapped)
        for range in try KindlePreflight.inspect(book).coverRecordRanges {
            guard range.count <= 16 * 1_024 * 1_024 else { continue }
            let bytes = book.subdata(in: range)
            guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                  CGImageSourceCopyPropertiesAtIndex(source, 0, nil) != nil else { continue }
            return bytes
        }
        return nil
    }
}
