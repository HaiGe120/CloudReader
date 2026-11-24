import CryptoKit
import Foundation
import ImageIO
import Cunrar

/// Prepares a CBR archive for the existing comic reader. Extraction is performed by
/// UnRAR's callback API while advancing one archive handle from header to header; this
/// preserves solid-compression state and never buffers an entire page in memory.
actor CBRLoader {
    static let shared = CBRLoader()

    private let fileManager = FileManager.default
    private let cacheRoot: URL?
    private let limits: CBRResourceLimits
    private let onImageChunk: (@Sendable () -> Void)?

    init(
        cacheRoot: URL? = nil,
        limits: CBRResourceLimits = .production,
        onImageChunk: (@Sendable () -> Void)? = nil
    ) {
        self.cacheRoot = cacheRoot
        self.limits = limits
        self.onImageChunk = onImageChunk
    }

    func open(url: URL, bookID: UUID) async throws -> CBZPublication {
        try Task.checkCancellation()
        let fingerprint = try Self.fingerprint(of: url)
        let base = try cacheRoot ?? fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("CBR", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let cache = base.appendingPathComponent(bookID.uuidString, isDirectory: true)
        if let publication = cachedPublication(at: cache, fingerprint: fingerprint) { return publication }

        let staging = base.appendingPathComponent(".\(bookID.uuidString).\(UUID().uuidString).staging", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var stagingForCleanup: URL? = staging
        defer {
            if let stagingForCleanup { try? fileManager.removeItem(at: stagingForCleanup) }
        }

        let archive = try CBRArchiveCursor(url: url, mode: UInt32(RAR_OM_EXTRACT), limits: limits)
        var pageRecords: [(CBZPage, URL)] = []
        while let entry = try archive.next() {
            guard entry.isPage else { try archive.skip(); continue }
            let path = entry.path
            let size = entry.size
            let destination = staging.appendingPathComponent(path).standardizedFileURL
            guard destination.path.hasPrefix(staging.standardizedFileURL.path + "/") else { throw CBRArchiveError.unsafeEntry }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let output = try FileHandle(forWritingTo: createEmptyFile(at: destination))
            let callbackContext = CBRCallbackContext(write: { try output.write(contentsOf: $0) }, expectedBytes: size, onImageChunk: onImageChunk)
            do {
                defer { try? output.close() }
                try await withTaskCancellationHandler {
                    try archive.readCurrentPage(into: callbackContext)
                } onCancel: {
                    callbackContext.cancel()
                }
            }
            guard Self.isImage(at: destination) else { throw CBRArchiveError.invalidArchive }
            pageRecords.append((CBZPage(path: path, name: URL(fileURLWithPath: path).lastPathComponent), destination))
        }
        guard !pageRecords.isEmpty else { throw CBRArchiveError.noImages }
        pageRecords.sort { CBZLoader.naturalLess($0.0.path, $1.0.path) }
        try Task.checkCancellation()
        let pages = pageRecords.map(\.0)
        let marker = CBRCacheRecord(fingerprint: fingerprint, pages: pages)
        try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        if fileManager.fileExists(atPath: cache.path) { try fileManager.removeItem(at: cache) }
        try fileManager.moveItem(at: staging, to: cache)
        stagingForCleanup = nil
        return CBZPublication(rootURL: cache, pages: pages)
    }

    /// List mode locates the first page in reading order without inflating each image.
    /// Extraction then advances a fresh handle only as far as the selected page.
    static func coverData(at url: URL) throws -> Data? {
        let listing = try CBRArchiveCursor(url: url, mode: UInt32(RAR_OM_LIST), limits: .production)
        var firstPath: String?
        while let entry = try listing.next() {
            if entry.isPage, CBZLoader.isVisiblePage(entry.path),
               firstPath.map({ CBZLoader.naturalLess(entry.path, $0) }) ?? true {
                firstPath = entry.path
            }
            try listing.skip()
        }
        guard let firstPath else { return nil }
        let archive = try CBRArchiveCursor(url: url, mode: UInt32(RAR_OM_EXTRACT), limits: .production)
        while let entry = try archive.next() {
            guard entry.path == firstPath, entry.isPage else { try archive.skip(); continue }
            var bytes = Data()
            let context = CBRCallbackContext(write: { bytes.append($0) }, expectedBytes: entry.size, onImageChunk: nil)
            try archive.readCurrentPage(into: context)
            return bytes
        }
        throw CBRArchiveError.invalidArchive
    }

    private func createEmptyFile(at url: URL) throws -> URL {
        guard fileManager.createFile(atPath: url.path, contents: nil) else { throw CBRArchiveError.invalidArchive }
        return url
    }

    private func cachedPublication(at root: URL, fingerprint: String) -> CBZPublication? {
        guard let bytes = try? Data(contentsOf: root.appendingPathComponent("complete.json")),
              let marker = try? JSONDecoder().decode(CBRCacheRecord.self, from: bytes),
              marker.fingerprint == fingerprint, !marker.pages.isEmpty,
              marker.pages.allSatisfy({ CBZLoader.isSafePath($0.path) && fileManager.fileExists(atPath: root.appendingPathComponent($0.path).path) }) else { return nil }
        return CBZPublication(rootURL: root, pages: marker.pages)
    }

    private static func fingerprint(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return "cbr-v1-" + hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func isImage(at url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width > 0 && height > 0 && width <= 65_536 && height <= 65_536 && width <= 100_000_000 / height
    }
}

/// Applies the same header validation to reader preparation and cover extraction.
private final class CBRArchiveCursor {
    private let handle: UnsafeMutableRawPointer
    private let limits: CBRResourceLimits
    private var seen = Set<String>()
    private var total: UInt64 = 0
    private var count = 0

    init(url: URL, mode: UInt32, limits: CBRResourceLimits) throws {
        self.limits = limits
        var openData = RAROpenArchiveDataEx()
        openData.OpenMode = mode
        openData.CmtBuf = nil
        openData.CmtBufW = nil
        openData.CmtBufSize = 0
        let archiveHandle: UnsafeMutableRawPointer? = url.path.utf8CString.withUnsafeBufferPointer { path in
            openData.ArcName = UnsafeMutablePointer(mutating: path.baseAddress)
            return UnsafeMutableRawPointer(RAROpenArchiveEx(&openData))
        }
        guard let archiveHandle, openData.OpenResult == UInt32(ERAR_SUCCESS) else { throw CBRArchiveError.invalidArchive }
        self.handle = archiveHandle
        guard openData.Flags & UInt32(ROADF_ENCHEADERS) == 0,
              openData.Flags & UInt32(ROADF_VOLUME) == 0 else { throw CBRArchiveError.unsupportedArchive }
    }

    deinit { _ = RARCloseArchive(handle) }

    func next() throws -> (path: String, size: UInt64, isPage: Bool)? {
        var header = RARHeaderDataEx()
        try Task.checkCancellation()
        let readResult = RARReadHeaderEx(handle, &header)
        if readResult == Int32(ERAR_END_ARCHIVE) { return nil }
        guard readResult == Int32(ERAR_SUCCESS) else { throw CBRArchiveError.invalidArchive }
        count += 1
        guard count <= limits.maximumEntries else { throw CBRArchiveError.tooLarge }
        let flags = header.Flags
        guard flags & UInt32(RHDF_SPLITBEFORE | RHDF_SPLITAFTER) == 0 else { throw CBRArchiveError.unsupportedArchive }
        guard flags & UInt32(RHDF_ENCRYPTED) == 0 else { throw CBRArchiveError.encrypted }
        // RedirType identifies Unix/Windows links in RAR5. Reject all redirections.
        guard header.RedirType == 0 else { throw CBRArchiveError.unsafeEntry }
        // RAR4 stores Unix file type in the high FileAttr mode bits. 0120000 is
        // S_IFLNK; reject it even though legacy headers have no RedirType.
        if header.HostOS == 3, header.FileAttr & 0o170000 == 0o120000 {
            throw CBRArchiveError.unsafeEntry
        }
        let name = withUnsafePointer(to: &header.FileName.0) { String(cString: $0) }
        let isDirectory = flags & UInt32(RHDF_DIRECTORY) != 0
        let path = isDirectory && name.hasSuffix("/") ? String(name.dropLast()) : name
        guard CBZLoader.isSafePath(path) else { throw CBRArchiveError.unsafeEntry }
        let canonical = path.precomposedStringWithCanonicalMapping.lowercased()
        guard seen.insert(canonical).inserted else { throw CBRArchiveError.unsafeEntry }

        let size = UInt64(header.UnpSizeHigh) << 32 | UInt64(header.UnpSize)
        let (nextTotal, overflow) = total.addingReportingOverflow(size)
        guard !overflow, nextTotal <= limits.maximumOutputBytes else { throw CBRArchiveError.tooLarge }
        total = nextTotal
        guard header.DictSize <= limits.maximumDictionaryKiB else { throw CBRArchiveError.tooLarge }

        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let isPage = !isDirectory && CBZLoader.imageExtensions.contains(ext)
        if isPage, size > limits.maximumPageBytes { throw CBRArchiveError.tooLarge }
        return (path, size, isPage)
    }

    func readCurrentPage(into context: CBRCallbackContext) throws {
        try withExtendedLifetime(context) {
            let pointer = Unmanaged.passUnretained(context).toOpaque()
            RARSetCallback(handle, Self.processDataCallback, Int(bitPattern: pointer))
            defer { RARSetCallback(handle, nil, 0) }
            // RAR_TEST supplies the bytes through our callback without writing archive paths.
            let result = RARProcessFile(handle, Int32(RAR_TEST), nil, nil)
            try Task.checkCancellation()
            guard result == Int32(ERAR_SUCCESS), !context.failed, context.bytesWritten == context.expectedBytes else {
                throw CBRArchiveError.invalidArchive
            }
        }
    }

    private static let processDataCallback: UNRARCALLBACK = { message, userData, address, byteCount in
        guard message == UCM_PROCESSDATA.rawValue, userData != 0, byteCount >= 0,
              let source = UnsafeRawPointer(bitPattern: address),
              let contextPointer = UnsafeRawPointer(bitPattern: userData) else { return 0 }
        let context = Unmanaged<CBRCallbackContext>.fromOpaque(contextPointer).takeUnretainedValue()
        guard !Task.isCancelled, !context.isCancelled else {
            context.failed = true
            return -1
        }
        let amount = UInt64(byteCount)
        guard context.bytesWritten <= context.expectedBytes, amount <= context.expectedBytes - context.bytesWritten else {
            context.failed = true
            return -1
        }
        do {
            context.onImageChunk?()
            try context.write(Data(bytes: source, count: Int(byteCount)))
            context.bytesWritten += amount
            return 0
        } catch {
            context.failed = true
            return -1
        }
    }

    func skip() throws {
        guard RARProcessFile(handle, Int32(RAR_SKIP), nil, nil) == Int32(ERAR_SUCCESS) else {
            throw CBRArchiveError.invalidArchive
        }
    }
}

struct CBRResourceLimits {
    let maximumEntries: Int
    let maximumPageBytes: UInt64
    let maximumOutputBytes: UInt64
    let maximumDictionaryKiB: UInt32

    static let production = CBRResourceLimits(
        maximumEntries: 10_000,
        maximumPageBytes: 64 * 1_024 * 1_024,
        maximumOutputBytes: 1_024 * 1_024 * 1_024,
        maximumDictionaryKiB: 64 * 1_024
    )
}

private final class CBRCallbackContext {
    let write: (Data) throws -> Void
    let expectedBytes: UInt64
    var bytesWritten: UInt64 = 0
    var failed = false
    private let cancellationLock = NSLock()
    private var cancelled = false
    let onImageChunk: (@Sendable () -> Void)?

    var isCancelled: Bool {
        cancellationLock.lock()
        defer { cancellationLock.unlock() }
        return cancelled
    }

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    init(write: @escaping (Data) throws -> Void, expectedBytes: UInt64, onImageChunk: (@Sendable () -> Void)?) {
        self.write = write
        self.expectedBytes = expectedBytes
        self.onImageChunk = onImageChunk
    }
}

private struct CBRCacheRecord: Codable {
    let fingerprint: String
    let pages: [CBZPage]
}

enum CBRArchiveError: LocalizedError {
    case invalidArchive, encrypted, unsafeEntry, tooLarge, noImages, unsupportedArchive

    var errorDescription: String? {
        switch self {
        case .invalidArchive: "This comic archive is damaged or uses an unsupported RAR feature."
        case .encrypted: "Encrypted comic archives cannot be opened."
        case .unsafeEntry: "This comic archive contains an unsafe entry."
        case .tooLarge: "This comic archive exceeds the preparation limits for this device."
        case .noImages: "This comic archive does not contain readable pages."
        case .unsupportedArchive: "Split or encrypted-header RAR archives are not supported."
        }
    }
}
