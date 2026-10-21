import Foundation
import CryptoKit
import ImageIO
import ZIPFoundation
import CloudReaderCore

struct CBZPage: Codable, Equatable, Sendable {
    let path: String
    let name: String
}
struct CBZPublication: Sendable {
    let rootURL: URL
    let pages: [CBZPage]

    func url(for index: Int) -> URL { rootURL.appendingPathComponent(pages[index].path) }
}

enum CBZError: LocalizedError {
    case invalidArchive, encrypted, unsafePath, tooLarge, noImages

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "This comic archive is damaged or uses an unsupported ZIP feature. Try importing another copy."
        case .encrypted: "This comic archive is encrypted and cannot be read. Import an unencrypted copy."
        case .unsafePath: "This comic archive contains an unsafe file path and could not be opened."
        case .tooLarge: "This comic archive is too large to prepare on this device."
        case .noImages: "This comic archive does not contain any readable pages."
        }
    }
}

actor CBZLoader {
    static let shared = CBZLoader()
    private let fileManager = FileManager.default
    private let cacheRoot: URL?

    init(cacheRoot: URL? = nil) { self.cacheRoot = cacheRoot }

    func open(url: URL, bookID: UUID) throws -> CBZPublication {
        try Task.checkCancellation()
        let fingerprint = try Self.fingerprint(of: url)
        let root: URL
        if let cacheRoot {
            root = cacheRoot
        } else {
            root = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("CBZ", isDirectory: true)
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        let marker = cache.appendingPathComponent("complete.json")
        if let data = try? Data(contentsOf: marker),
           let saved = try? JSONDecoder().decode(CacheRecord.self, from: data), saved.fingerprint == fingerprint,
           !saved.pages.isEmpty, saved.pages.allSatisfy({ Self.isSafePath($0.path) && fileManager.fileExists(atPath: cache.appendingPathComponent($0.path).path) }) {
            return CBZPublication(rootURL: cache, pages: saved.pages)
        }

        let staging = root.appendingPathComponent(".\(bookID.uuidString).\(UUID().uuidString).staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw CBZError.invalidArchive }
        let declaredEntryCount = try Self.validateCentralDirectory(at: url)
        var entries: [Entry] = []
        var total: UInt64 = 0
        var seenPaths = Set<String>()
        do {
            for entry in archive {
                try Task.checkCancellation()
                entries.append(entry)
                guard entries.count <= 10_000 else { throw CBZError.tooLarge }
                guard entry.type != .symlink else { throw CBZError.unsafePath }
                let checkedPath = entry.type == .directory && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
                guard Self.isSafePath(checkedPath) else { throw CBZError.unsafePath }
                let canonicalPath = checkedPath.precomposedStringWithCanonicalMapping.lowercased()
                guard seenPaths.insert(canonicalPath).inserted else { throw CBZError.unsafePath }
                guard entry.uncompressedSize <= 64 * 1_024 * 1_024 else { throw CBZError.tooLarge }
                let (sum, overflow) = total.addingReportingOverflow(entry.uncompressedSize)
                guard !overflow, sum <= 1_024 * 1_024 * 1_024 else { throw CBZError.tooLarge }
                total = sum
            }
            guard entries.count == declaredEntryCount else { throw CBZError.invalidArchive }
            guard !entries.isEmpty else { throw CBZError.invalidArchive }
            // ZIPFoundation rejects encrypted entries while opening the central directory. A
            // missing/unsupported entry therefore fails extraction and is reported as a bad archive.
            var pages: [CBZPage] = []
            for entry in entries where entry.type == .file {
                try Task.checkCancellation()
                let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                // Comic archives commonly include ComicInfo.xml and readme files. Their paths
                // and declared sizes were validated above; only image pages are extracted.
                guard Self.imageExtensions.contains(ext) else { continue }
                let destination = staging.appendingPathComponent(entry.path).standardizedFileURL
                guard destination.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw CBZError.unsafePath }
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                do { _ = try archive.extract(entry, to: destination) }
                catch { throw CBZError.invalidArchive }
                guard Self.isImage(at: destination) else { throw CBZError.invalidArchive }
                pages.append(CBZPage(path: entry.path, name: URL(fileURLWithPath: entry.path).lastPathComponent))
            }
            pages.sort { Self.naturalLess($0.path, $1.path) }
            guard !pages.isEmpty else { throw CBZError.noImages }
            try Task.checkCancellation()
            let record = CacheRecord(fingerprint: fingerprint, pages: pages)
            try JSONEncoder().encode(record).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
            if fileManager.fileExists(atPath: cache.path) { try fileManager.removeItem(at: cache) }
            try fileManager.moveItem(at: staging, to: cache)
            return CBZPublication(rootURL: cache, pages: pages)
        } catch let error as CBZError { throw error }
        catch { throw CBZError.invalidArchive }
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    private static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return "cbz-v1-" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validateCentralDirectory(at url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw CBZError.invalidArchive }
        let scanSize = min(fileSize, 65_557)
        try handle.seek(toOffset: fileSize - scanSize)
        guard let tail = try handle.read(upToCount: Int(scanSize)), tail.count >= 22 else { throw CBZError.invalidArchive }

        var endRecordOffset: UInt64?
        if tail.count >= 22 {
            for position in stride(from: tail.count - 22, through: max(tail.count - 65_557, 0), by: -1) {
                guard readUInt32(tail, at: position) == 0x06054b50,
                      let commentLength = readUInt16(tail, at: position + 20),
                      position + 22 + Int(commentLength) == tail.count else { continue }
                endRecordOffset = fileSize - scanSize + UInt64(position)
                break
            }
        }
        guard let endRecordOffset,
              let endPosition = Int(exactly: endRecordOffset - (fileSize - scanSize)),
              let disk = readUInt16(tail, at: endPosition + 4), disk == 0,
              let centralDisk = readUInt16(tail, at: endPosition + 6), centralDisk == 0,
              let countOnDisk = readUInt16(tail, at: endPosition + 8),
              let countInDirectory = readUInt16(tail, at: endPosition + 10),
              let centralSize32 = readUInt32(tail, at: endPosition + 12),
              let centralOffset32 = readUInt32(tail, at: endPosition + 16) else { throw CBZError.invalidArchive }

        var count = UInt64(countInDirectory)
        var centralSize = UInt64(centralSize32)
        var centralOffset = UInt64(centralOffset32)
        if countInDirectory == UInt16.max || countOnDisk == UInt16.max || centralSize32 == UInt32.max || centralOffset32 == UInt32.max {
            guard endRecordOffset >= 20 else { throw CBZError.invalidArchive }
            try handle.seek(toOffset: endRecordOffset - 20)
            guard let locator = try handle.read(upToCount: 20), locator.count == 20,
                  readUInt32(locator, at: 0) == 0x07064b50,
                  readUInt32(locator, at: 4) == 0,
                  readUInt32(locator, at: 16) == 1,
                  let zip64Offset = readUInt64(locator, at: 8) else { throw CBZError.invalidArchive }
            try handle.seek(toOffset: zip64Offset)
            guard let zip64 = try handle.read(upToCount: 56), zip64.count == 56,
                  readUInt32(zip64, at: 0) == 0x06064b50,
                  readUInt32(zip64, at: 16) == 0,
                  readUInt32(zip64, at: 20) == 0,
                  let zip64CountOnDisk = readUInt64(zip64, at: 24),
                  let zip64Count = readUInt64(zip64, at: 32), zip64CountOnDisk == zip64Count,
                  let zip64Size = readUInt64(zip64, at: 40),
                  let zip64OffsetValue = readUInt64(zip64, at: 48) else { throw CBZError.invalidArchive }
            count = zip64Count
            centralSize = zip64Size
            centralOffset = zip64OffsetValue
        } else if countOnDisk != countInDirectory {
            throw CBZError.invalidArchive
        }
        guard count <= 10_000, let entryCount = Int(exactly: count),
              centralOffset <= fileSize, centralSize <= fileSize - centralOffset,
              centralOffset + centralSize <= endRecordOffset else { throw CBZError.invalidArchive }

        var position: UInt64 = 0
        for _ in 0..<entryCount {
            try Task.checkCancellation()
            guard position <= centralSize, centralSize - position >= 46 else { throw CBZError.invalidArchive }
            try handle.seek(toOffset: centralOffset + position)
            guard let header = try handle.read(upToCount: 46), header.count == 46,
                  readUInt32(header, at: 0) == 0x02014b50,
                  let flags = readUInt16(header, at: 8),
                  let diskStart = readUInt16(header, at: 34),
                  let nameLength = readUInt16(header, at: 28),
                  let extraLength = readUInt16(header, at: 30),
                  let commentLength = readUInt16(header, at: 32) else { throw CBZError.invalidArchive }
            if flags & 1 != 0 { throw CBZError.encrypted }
            guard diskStart == 0 else { throw CBZError.invalidArchive }
            let recordLength = UInt64(46) + UInt64(nameLength) + UInt64(extraLength) + UInt64(commentLength)
            guard recordLength <= centralSize - position else { throw CBZError.invalidArchive }
            position += recordLength
        }
        return entryCount
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count,
              let low = readUInt32(data, at: offset), let high = readUInt32(data, at: offset + 4) else { return nil }
        return UInt64(low) | (UInt64(high) << 32)
    }

    static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains(":"), !path.contains("\0"),
              !path.hasPrefix("~"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        return true
    }

    static func naturalLess(_ lhs: String, _ rhs: String) -> Bool {
        func tokens(_ value: String) -> [String] {
            var output: [String] = [], current = "", numeric: Bool?
            for char in value.lowercased() {
                let isDigit = char.isNumber
                if let numeric, numeric != isDigit { output.append(current); current = "" }
                numeric = isDigit; current.append(char)
            }
            if !current.isEmpty { output.append(current) }
            return output
        }
        let left = tokens(lhs), right = tokens(rhs)
        for index in 0..<min(left.count, right.count) {
            let x = left[index], y = right[index]
            if x == y { continue }
            if let nx = UInt64(x), let ny = UInt64(y), nx != ny { return nx < ny }
            if x.count != y.count, x.allSatisfy(\.isNumber), y.allSatisfy(\.isNumber) { return x.count < y.count }
            return x < y
        }
        return left.count == right.count ? lhs < rhs : left.count < right.count
    }

    static func spreadIndices(pageCount: Int, group: Int) -> [Int] {
        let first = max(group, 0) * 2
        guard first < pageCount else { return [] }
        return Array(first..<min(first + 2, pageCount))
    }

    static func alignedPageIndex(_ page: Int, pageCount: Int, columns: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let stride = max(columns, 1)
        return (min(max(page, 0), pageCount - 1) / stride) * stride
    }

    static func lastGroupStart(pageCount: Int, columns: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        let stride = max(columns, 1)
        return ((pageCount - 1) / stride) * stride
    }

    private static func isImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 65_536, height <= 65_536,
              width <= 100_000_000 / height else { return false }
        return true
    }

    private struct CacheRecord: Codable { let fingerprint: String; let pages: [CBZPage] }
}
