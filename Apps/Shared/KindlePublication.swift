import Foundation
import CryptoKit
import WebKit

/// Structural facts checked before the pinned Foliate decoder receives a Kindle file.
struct KindleContainerInfo: Equatable {
    enum Generation: Equatable { case mobi6, kf8, combo }
    let generation: Generation
    let compression: UInt16
    let textRecordCount: UInt16
    let recordCount: UInt16
}

enum KindleDecodeError: LocalizedError, Equatable {
    case invalidContainer, unsupportedCompression, unsupportedFormat, drmProtected, decoderResourcesMissing

    var errorDescription: String? {
        switch self {
        case .invalidContainer: "This Kindle book is damaged or uses an unsupported container."
        case .unsupportedCompression: "This Kindle book uses an unsupported compression method."
        case .unsupportedFormat: "This Kindle layout is not supported."
        case .drmProtected: "This Kindle book is protected by DRM. Import a DRM-free copy."
        case .decoderResourcesMissing: "This build is missing the local Kindle decoder resources."
        }
    }
}

/// Safe, bounded PalmDB/MOBI preflight. It rejects encrypted records before any
/// parser or decompressor is run. Offsets and table size are checked before slicing.
enum KindlePreflight {
    static let maximumInputBytes = 128 * 1_024 * 1_024

    static func inspect(_ data: Data) throws -> KindleContainerInfo {
        guard data.count >= 86, data.count <= maximumInputBytes else { throw KindleDecodeError.invalidContainer }
        let bytes = [UInt8](data)
        func u16(_ offset: Int) -> UInt16 { UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]) }
        func u32(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
        }
        guard String(bytes: bytes[60..<68], encoding: .ascii) == "BOOKMOBI" else { throw KindleDecodeError.invalidContainer }
        let count = u16(76)
        guard count >= 2, 78 + Int(count) * 8 <= bytes.count else { throw KindleDecodeError.invalidContainer }
        let tableEnd = 78 + Int(count) * 8
        let offsets = (0..<Int(count)).map { Int(u32(78 + $0 * 8)) }
        guard offsets.first! >= tableEnd, offsets.allSatisfy({ $0 >= tableEnd && $0 < bytes.count }),
              zip(offsets, offsets.dropFirst()).allSatisfy({ pair in pair.0 < pair.1 }) else { throw KindleDecodeError.invalidContainer }
        // All MOBI field offsets below are relative to the PalmDOC record, including
        // its 16-byte prefix. Applying that prefix twice reads unrelated bytes.
        func inspectHeader(record: Int) throws -> (compression: UInt16, textCount: UInt16, version: UInt32, boundary: Int?) {
            let first = offsets[record]
            let end = record + 1 < offsets.count ? offsets[record + 1] : bytes.count
            guard end - first >= 16 else { throw KindleDecodeError.invalidContainer }
            guard u16(first + 12) == 0 else { throw KindleDecodeError.drmProtected }
            guard end - first >= 248,
                  String(bytes: bytes[(first + 16)..<(first + 20)], encoding: .ascii) == "MOBI" else {
                throw KindleDecodeError.invalidContainer
            }
            let compression = u16(first), textCount = u16(first + 8)
            guard [1, 2, 17480].contains(compression) else { throw KindleDecodeError.unsupportedCompression }
            guard textCount > 0, record + Int(textCount) < offsets.count else { throw KindleDecodeError.invalidContainer }
            let encoding = u32(first + 28), version = u32(first + 36)
            guard (encoding == 1252 || encoding == 65001), (6...8).contains(version), u32(first + 24) == 2 else {
                throw KindleDecodeError.unsupportedFormat
            }
            // MOBI6 uses these fields for dictionary indexes. KF8 repurposes
            // offset 40 for its index layout, including ordinary reflowable books.
            guard version >= 8 || [u32(first + 40), u32(first + 44)].allSatisfy({ $0 == 0 || $0 == UInt32.max }) else {
                throw KindleDecodeError.unsupportedFormat
            }
            let mobiLength = Int(u32(first + 20))
            guard mobiLength >= 232, first + 16 + mobiLength <= end,
                  version < 8 || mobiLength >= 248 else { throw KindleDecodeError.invalidContainer }
            let titleOffset = Int(u32(first + 84)), titleLength = Int(u32(first + 88))
            guard (titleOffset == 0 && titleLength == 0) ||
                    (titleLength <= 4096 && titleOffset >= 16 + mobiLength && first + titleOffset + titleLength <= end) else {
                throw KindleDecodeError.invalidContainer
            }
            var boundary: Int?
            if u32(first + 128) & 0x40 != 0 {
                let exthStart = first + 16 + mobiLength
                guard exthStart + 12 <= end, String(bytes: bytes[exthStart..<(exthStart + 4)], encoding: .ascii) == "EXTH" else {
                    throw KindleDecodeError.invalidContainer
                }
                let exthLength = Int(u32(exthStart + 4)), recordCount = Int(u32(exthStart + 8))
                guard exthLength >= 12, exthStart + exthLength <= end, recordCount <= 4096 else { throw KindleDecodeError.invalidContainer }
                var cursor = exthStart + 12
                for _ in 0..<recordCount {
                    guard cursor + 8 <= exthStart + exthLength else { throw KindleDecodeError.invalidContainer }
                    let type = u32(cursor), length = Int(u32(cursor + 4))
                    guard length >= 8, cursor + length <= exthStart + exthLength else { throw KindleDecodeError.invalidContainer }
                    if type == 121, length >= 12 {
                        let value = u32(cursor + 8)
                        if value != UInt32.max {
                            guard value > 0, value < UInt32(count) else { throw KindleDecodeError.invalidContainer }
                            boundary = Int(value)
                        }
                    } else if type == 122 {
                        let fixed = String(bytes: bytes[(cursor + 8)..<(cursor + length)], encoding: .ascii)?.lowercased()
                        if fixed != "no" && fixed != "false" && fixed != "0" { throw KindleDecodeError.unsupportedFormat }
                    }
                    cursor += length
                }
            }
            return (compression, textCount, version, boundary)
        }
        let primary = try inspectHeader(record: 0)
        if primary.version < 8, let boundary = primary.boundary {
            let secondary = try inspectHeader(record: boundary)
            guard secondary.version == 8 else { throw KindleDecodeError.invalidContainer }
            return KindleContainerInfo(generation: .combo, compression: secondary.compression, textRecordCount: secondary.textCount, recordCount: count)
        }
        return KindleContainerInfo(generation: primary.version == 8 ? .kf8 : .mobi6,
            compression: primary.compression, textRecordCount: primary.textCount, recordCount: count)
    }
}

/// Offline DRM-free MOBI/AZW3 conversion into the existing EPUB/WebKit publication shape.
actor KindleLoader {
    static let shared = KindleLoader()
    private let cacheRoot: URL?

    init(cacheRoot: URL? = nil) { self.cacheRoot = cacheRoot }

    func open(url: URL, bookID: UUID) async throws -> EPUBPublication {
        try Task.checkCancellation()
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (values[.size] as? NSNumber)?.uint64Value ?? UInt64.max
        guard size <= UInt64(KindlePreflight.maximumInputBytes) else { throw EPUBError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let info = try KindlePreflight.inspect(data)
        try Task.checkCancellation()
        let fingerprint = "kindle-v2-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let base: URL
        if let cacheRoot {
            base = cacheRoot.appendingPathComponent(bookID.uuidString, isDirectory: true)
        } else {
            base = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Kindle", isDirectory: true).appendingPathComponent(bookID.uuidString, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let cache = base.appendingPathComponent(fingerprint, isDirectory: true)
        if let cached = cachedPublication(at: cache, fingerprint: fingerprint) { return cached }

        guard ["index.html", "converter.js", "mobi.js", "fflate.js"].allSatisfy({
            let parts = $0.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 2 && Bundle.main.url(forResource: String(parts[0]), withExtension: String(parts[1])) != nil
        }) else {
            throw KindleDecodeError.decoderResourcesMissing
        }
        let runner = await KindleWebRunner.shared
        let export = try await runner.convert(data)
        try Task.checkCancellation()
        // Another open can finish while this actor awaits the WebKit conversion.
        if let cached = cachedPublication(at: cache, fingerprint: fingerprint) { return cached }
        guard !export.chapters.isEmpty, export.chapters.count <= 10_000 else { throw EPUBError.noChapters }
        let stage = base.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        var stageForCleanup: URL? = stage
        defer {
            if let stageForCleanup { try? FileManager.default.removeItem(at: stageForCleanup) }
        }
        var mediaTypes: [String: String] = [:]
        var total = 0
        for chapter in export.chapters {
            try Task.checkCancellation()
            guard Self.validChapterPath(chapter.path) else { throw KindleDecodeError.invalidContainer }
            let html = Self.sanitize(chapter.html)
            total += html.utf8.count
            guard total <= 128 * 1_024 * 1_024 else { throw EPUBError.tooLarge }
            let destination = stage.appendingPathComponent(chapter.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: destination, options: .atomic)
        }
        for resource in export.resources {
            try Task.checkCancellation()
            guard Self.validResourcePath(resource.path), resource.base64.utf8.count <= 24 * 1_024 * 1_024,
                  let bytes = Data(base64Encoded: resource.base64), bytes.count <= 16 * 1_024 * 1_024,
                  Self.validMediaType(resource.type) else { throw EPUBError.invalidBook }
            total += bytes.count
            guard total <= 128 * 1_024 * 1_024 else { throw EPUBError.tooLarge }
            let destination = stage.appendingPathComponent(resource.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if resource.type == "text/css" {
                guard let css = String(data: bytes, encoding: .utf8) else { throw EPUBError.invalidBook }
                try Data(Self.sanitizeCSS(css).utf8).write(to: destination, options: .atomic)
            } else {
                try bytes.write(to: destination, options: .atomic)
            }
            mediaTypes[resource.path] = resource.type
        }
        let chapters = export.chapters.enumerated().map { index, chapter in
            EPUBChapter(path: chapter.path, title: chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title)
        }
        let marker = KindleCacheMarker(fingerprint: fingerprint, title: export.title, chapters: chapters, mediaTypes: mediaTypes)
        try JSONEncoder().encode(marker).write(to: stage.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.removeItem(at: cache)
        }
        try FileManager.default.moveItem(at: stage, to: cache)
        stageForCleanup = nil
        guard let publication = cachedPublication(at: cache, fingerprint: fingerprint) else { throw EPUBError.invalidBook }
        _ = info
        return publication
    }

    private func cachedPublication(at root: URL, fingerprint: String) -> EPUBPublication? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("complete.json")),
              let marker = try? JSONDecoder().decode(KindleCacheMarker.self, from: data), marker.fingerprint == fingerprint,
              !marker.chapters.isEmpty,
              marker.chapters.allSatisfy({ Self.validChapterPath($0.path) && FileManager.default.fileExists(atPath: root.appendingPathComponent($0.path).path) }),
              marker.mediaTypes.keys.allSatisfy({ Self.validResourcePath($0) && FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }) else { return nil }
        return EPUBPublication(rootURL: root, title: marker.title, chapters: marker.chapters, mediaTypes: marker.mediaTypes)
    }

    private static func validChapterPath(_ path: String) -> Bool {
        path.range(of: #"^Text/chapter-[0-9]{5}\.html$"#, options: .regularExpression) != nil
    }
    private static func validResourcePath(_ path: String) -> Bool {
        path.range(of: #"^Resources/resource-[0-9]{5}(?:\.(?:jpg|png|gif|svg|css|xhtml|html))?$"#, options: .regularExpression) != nil
    }
    private static func validMediaType(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#, options: .regularExpression) != nil
    }
    private static func sanitize(_ html: String) -> String {
        var value = html
        for pattern in [#"(?is)<script\b[^>]*>.*?</script\s*>"#, #"(?is)<iframe\b[^>]*>.*?</iframe\s*>"#, #"(?is)\s+on[a-z]+\s*=\s*(["']).*?\1"#] {
            value = value.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return value
    }
    private static func sanitizeCSS(_ css: String) -> String {
        css.replacingOccurrences(of: #"(?is)@import\s+[^;]+;?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?is)url\(\s*["']?(?:https?:|file:|javascript:|//)[^)]*\)"#, with: "none", options: .regularExpression)
    }
}

private struct KindleCacheMarker: Codable {
    let fingerprint: String
    let title: String?
    let chapters: [EPUBChapter]
    let mediaTypes: [String: String]
}

private struct KindleExport: Decodable {
    struct Chapter: Decodable { let path: String; let title: String; let html: String }
    struct Resource: Decodable { let path: String; let type: String; let base64: String }
    let title: String?
    let chapters: [Chapter]
    let resources: [Resource]
    let warnings: [String]?
}

@MainActor
private final class KindleWebRunner: NSObject, WKNavigationDelegate {
    static let shared = KindleWebRunner(bundle: .main)

    private let webView: WKWebView
    private let harnessURL: URL
    private let resourceHandler: KindleResourceSchemeHandler
    private var loaded: CheckedContinuation<Void, Error>?
    private var isLoaded = false
    private var loadError: Error?
    private var activeConversionID: UUID?

    init(bundle: Bundle) {
        harnessURL = URL(string: "cloudreader-kindle://reader/index.html")!
        resourceHandler = KindleResourceSchemeHandler(bundle: bundle)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(resourceHandler, forURLScheme: "cloudreader-kindle")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.load(URLRequest(url: harnessURL))
    }

    func convert(_ data: Data) async throws -> KindleExport {
        // Actor calls can reenter while JavaScript awaits. Keep the decoder's
        // temporary URL factory and resource maps exclusive to one publication.
        while activeConversionID != nil {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        let conversionID = UUID()
        activeConversionID = conversionID
        defer { activeConversionID = nil }
        if let loadError { throw loadError }
        if !isLoaded {
            try await withTaskCancellationHandler(operation: {
                try await self.waitUntilLoaded()
            }, onCancel: {
                Task { @MainActor [weak self] in self?.cancel(conversionID) }
            })
        }
        try Task.checkCancellation()
        try await waitUntilDecoderReady()
        let result: Any?
        do {
            result = try await withTaskCancellationHandler {
                try await webView.callAsyncJavaScript(
                    "if (!window.kindler) throw new Error('Decoder is not ready'); return await window.kindler.convert(input)",
                    arguments: ["input": data.base64EncodedString()], in: nil, contentWorld: .page
                )
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(conversionID) }
            }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String,
               message.contains("UNSUPPORTED_KINDLE_FORMAT") {
                throw KindleDecodeError.unsupportedFormat
            }
            throw error
        }
        try Task.checkCancellation()
        guard let dictionary = result as? [String: Any],
              JSONSerialization.isValidJSONObject(dictionary),
              let json = try? JSONSerialization.data(withJSONObject: dictionary),
              let decoded = try? JSONDecoder().decode(KindleExport.self, from: json) else { throw EPUBError.invalidBook }
        if let warnings = decoded.warnings, !warnings.isEmpty {
            NSLog("Kindle decoder warnings: %@", warnings.joined(separator: " | "))
        }
        return decoded
    }

    private func cancel(_ conversionID: UUID) {
        guard activeConversionID == conversionID else { return }
        abortWait()
        webView.evaluateJavaScript("window.kindler?.cancel()")
    }
    private func abortWait() {
        loaded?.resume(throwing: CancellationError())
        loaded = nil
    }
    private func waitUntilLoaded() async throws {
        if let loadError { throw loadError }
        if isLoaded { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let loadError { continuation.resume(throwing: loadError) }
            else if isLoaded { continuation.resume() }
            else { loaded = continuation }
        }
    }

    private func waitUntilDecoderReady() async throws {
        for _ in 0..<250 {
            try Task.checkCancellation()
            if let ready = try await webView.evaluateJavaScript("typeof window.kindler") as? String, ready == "object" { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw KindleDecodeError.decoderResourcesMissing
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        guard let loaded else { return }
        self.loaded = nil
        loaded.resume()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error
        loaded?.resume(throwing: error); loaded = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = error
        loaded?.resume(throwing: error); loaded = nil
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.standardizedFileURL == harnessURL ? .allow : .cancel)
    }
}

/// Serves only the pinned decoder's bundled files over one isolated same-origin
/// scheme. This permits ES module imports without granting file-URL read access.
private final class KindleResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    private let bundle: Bundle
    private let allowedResources: [String: (fileExtension: String, mimeType: String)] = [
        "index.html": ("html", "text/html"),
        "converter.js": ("js", "text/javascript"),
        "mobi.js": ("js", "text/javascript"),
        "fflate.js": ("js", "text/javascript"),
    ]

    init(bundle: Bundle) { self.bundle = bundle }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "cloudreader-kindle", url.host == "reader",
              url.pathComponents.count == 2,
              let name = url.pathComponents.last,
              let resource = allowedResources[name],
              let file = bundle.url(forResource: String(name.dropLast(resource.fileExtension.count + 1)), withExtension: resource.fileExtension),
              let data = try? Data(contentsOf: file) else {
            urlSchemeTask.didFailWithError(NSError(domain: "KindleDecoderResources", code: 404))
            return
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": resource.mimeType + (resource.fileExtension == "html" ? "; charset=utf-8" : ""),
                "Access-Control-Allow-Origin": "*",
                "Cache-Control": "no-store",
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) { }
}
