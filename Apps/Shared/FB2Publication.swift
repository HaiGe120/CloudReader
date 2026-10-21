import Foundation
import CryptoKit
import ImageIO

/// Converts FictionBook 2 XML into local HTML for the existing EPUB/WebKit reader.
/// The source document is only read; generated files live in a disposable cache.
actor FB2Loader {
    static let shared = FB2Loader()

    private let fileManager = FileManager.default
    private let maximumInputBytes = 64 * 1_024 * 1_024
    private let maximumOutputBytes = 128 * 1_024 * 1_024
    private let maximumDepth = 128
    private let maximumImageBytes = 12 * 1_024 * 1_024
    private let maximumTotalImageBytes = 48 * 1_024 * 1_024

    func open(url: URL, bookID: UUID) throws -> EPUBPublication {
        try Task.checkCancellation()
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let inputSize = (attributes[.size] as? UInt64) ?? (attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max
        guard inputSize <= UInt64(maximumInputBytes) else { throw EPUBError.tooLarge }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumInputBytes else { throw EPUBError.tooLarge }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fingerprint = "fb2-v1-\(digest)"
        let base = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("FB2", isDirectory: true).appendingPathComponent(bookID.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let cache = base.appendingPathComponent(fingerprint, isDirectory: true)
        if let publication = cachedPublication(at: cache, fingerprint: fingerprint) { return publication }

        let staging = base.appendingPathComponent(".stage-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        try Task.checkCancellation()
        let converter = FB2XMLConverter(maximumDepth: maximumDepth, maximumOutputBytes: maximumOutputBytes,
                                        maximumImageBytes: maximumImageBytes, maximumTotalImageBytes: maximumTotalImageBytes)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = converter
        guard parser.parse(), !converter.cancelled, !Task.isCancelled else {
            if Task.isCancelled || converter.cancelled { throw CancellationError() }
            throw EPUBError.invalidBook
        }
        guard converter.sawFictionBook, converter.sawBody, !converter.html.isEmpty else { throw EPUBError.invalidBook }
        try Task.checkCancellation()

        var html = "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(Self.escape(converter.title ?? "Book"))</title></head><body>\(converter.html)"
        if !converter.notesHTML.isEmpty { html += "<section class=\"fb2-notes\"><h1>Notes</h1>\(converter.notesHTML)</section>" }
        html += "</body></html>"

        var mediaTypes: [String: String] = [:]
        let resources = staging.appendingPathComponent("Resources", isDirectory: true)
        if !converter.binaries.isEmpty { try fileManager.createDirectory(at: resources, withIntermediateDirectories: true) }
        for (id, binary) in converter.binaries {
            try Task.checkCancellation()
            guard let image = Self.validatedImage(binary.data) else { continue }
            let relativePath = "Resources/image-\(binary.index).\(image.ext)"
            try image.data.write(to: resources.appendingPathComponent("image-\(binary.index).\(image.ext)"), options: .atomic)
            mediaTypes[relativePath] = image.mime
            for token in converter.imageTokens[id] ?? [] { html = html.replacingOccurrences(of: token, with: relativePath) }
        }
        for token in converter.allImageTokens where html.contains(token) { html = html.replacingOccurrences(of: token, with: "") }
        guard html.utf8.count <= maximumOutputBytes else { throw EPUBError.tooLarge }
        try Data(html.utf8).write(to: staging.appendingPathComponent("chapter.html"), options: .atomic)
        let chapter = EPUBChapter(path: "chapter.html", title: converter.title?.isEmpty == false ? converter.title! : "Chapter 1")
        let marker = FB2CacheMarker(fingerprint: fingerprint, title: converter.title, chapter: chapter, mediaTypes: mediaTypes)
        try JSONEncoder().encode(marker).write(to: staging.appendingPathComponent("complete.json"), options: .atomic)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: cache.path) { try? fileManager.removeItem(at: staging) }
        else { try fileManager.moveItem(at: staging, to: cache) }
        guard let publication = cachedPublication(at: cache, fingerprint: fingerprint) else { throw EPUBError.invalidBook }
        return publication
    }

    private func cachedPublication(at root: URL, fingerprint: String) -> EPUBPublication? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent("complete.json")),
              let marker = try? JSONDecoder().decode(FB2CacheMarker.self, from: data),
              marker.fingerprint == fingerprint, marker.chapter.path == "chapter.html",
              fileManager.fileExists(atPath: root.appendingPathComponent("chapter.html").path) else { return nil }
        for path in marker.mediaTypes.keys {
            guard !path.hasPrefix("/"), !path.contains(".."), !path.contains("\\"),
                  fileManager.fileExists(atPath: root.appendingPathComponent(path).standardizedFileURL.path) else { return nil }
        }
        return EPUBPublication(rootURL: root, title: marker.title, chapters: [marker.chapter], mediaTypes: marker.mediaTypes)
    }

    fileprivate static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func validatedImage(_ input: Data) -> (data: Data, ext: String, mime: String)? {
        let type: (String, String)?
        if input.starts(with: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) { type = ("png", "image/png") }
        else if input.starts(with: [0xff, 0xd8, 0xff]) { type = ("jpg", "image/jpeg") }
        else if input.starts(with: Array("GIF8".utf8)) { type = ("gif", "image/gif") }
        else if input.count >= 12, String(data: input[0..<4], encoding: .ascii) == "RIFF", String(data: input[8..<12], encoding: .ascii) == "WEBP" { type = ("webp", "image/webp") }
        else { type = nil }
        guard let type, let source = CGImageSourceCreateWithData(input as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 16_000_000 / height,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return (input, type.0, type.1)
    }
}

private struct FB2CacheMarker: Codable {
    let fingerprint: String
    let title: String?
    let chapter: EPUBChapter
    let mediaTypes: [String: String]
}

private final class FB2XMLConverter: NSObject, XMLParserDelegate {
    private let maximumDepth: Int
    private let maximumOutputBytes: Int
    private let maximumImageBytes: Int
    private let maximumTotalImageBytes: Int
    private var stack: [String] = []
    private var binaryID: String?
    private var binaryText = ""
    private var captureTitle = false
    private var titleText = ""
    private var listTags: [String] = []
    private var inBody = false
    private var inNotes = false
    private(set) var sawFictionBook = false
    private(set) var sawBody = false
    private(set) var cancelled = false
    private(set) var title: String?
    private(set) var html = ""
    private(set) var notesHTML = ""
    private(set) var binaries: [String: (index: Int, data: Data)] = [:]
    private(set) var imageTokens: [String: [String]] = [:]
    private(set) var allImageTokens: [String] = []
    private var imageIndex = 0

    init(maximumDepth: Int, maximumOutputBytes: Int, maximumImageBytes: Int, maximumTotalImageBytes: Int) {
        self.maximumDepth = maximumDepth; self.maximumOutputBytes = maximumOutputBytes
        self.maximumImageBytes = maximumImageBytes; self.maximumTotalImageBytes = maximumTotalImageBytes
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        guard !Task.isCancelled, stack.count < maximumDepth else { cancelled = Task.isCancelled; parser.abortParsing(); return }
        let name = elementName.lowercased()
        let attrs = Dictionary(uniqueKeysWithValues: attributes.map { ($0.key.lowercased(), $0.value) })
        if stack.isEmpty { sawFictionBook = name == "fictionbook" }
        stack.append(name)
        if name == "body" {
            sawBody = true
            inNotes = attrs["name"] == "notes"
            inBody = !inNotes
        }
        if name == "book-title" && stack.contains("title-info") { captureTitle = true; titleText = "" }
        if name == "binary" { binaryID = attrs["id"]; binaryText = ""; return }
        guard inBody || inNotes else { return }
        let tag: String? = switch name {
        case "section": "section"; case "title": "h2"; case "subtitle": "h3"; case "p": "p"; case "strong": "strong"; case "emphasis": "em"; case "strikethrough": "del"
        case "sub": "sub"; case "sup": "sup"; case "code": "code"; case "poem": "blockquote"; case "stanza": "div"
        case "v": "p"; case "cite": "blockquote"; case "epigraph": "blockquote"; case "empty-line": "br"
        case "table": "table"; case "tr": "tr"; case "td": "td"; case "th": "th"; case "ul": "ul"; case "ol": "ol"; case "li", "item": "li"
        case "list": attrs["type"] == "ordered" ? "ol" : "ul"
        case "a": "a"; case "image": "img"; case "text-author": "p"; case "date": "time"; default: nil
        }
        guard let tag else { return }
        if name == "list" { listTags.append(tag) }
        if tag == "img" {
            let href = attrs["l:href"] ?? attrs["href"] ?? ""
            guard href.hasPrefix("#"), href.count > 1 else { return }
            let id = String(href.dropFirst())
            let token = "FB2RESOURCE-\(UUID().uuidString)-TOKEN"
            imageTokens[id, default: []].append(token); allImageTokens.append(token)
            append("<img src=\"\(token)\" alt=\"\" />", toNotes: inNotes, parser: parser)
        } else if tag == "a" {
            let href = attrs["l:href"] ?? attrs["href"] ?? ""
            if href.hasPrefix("#"), href.count > 1 { append("<a href=\"#\(FB2Loader.escape(String(href.dropFirst())))\">", toNotes: inNotes, parser: parser) }
            else { append("<span>", toNotes: inNotes, parser: parser) }
        } else if name == "section", let id = attrs["id"], !id.isEmpty {
            append("<section id=\"\(FB2Loader.escape(id))\">", toNotes: inNotes, parser: parser)
        } else { append("<\(tag)>", toNotes: inNotes, parser: parser) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !Task.isCancelled else { cancelled = true; parser.abortParsing(); return }
        if binaryID != nil { binaryText += string; if binaryText.utf8.count > maximumImageBytes * 2 { parser.abortParsing() }; return }
        if captureTitle { titleText += string }
        guard inBody || inNotes else { return }
        append(FB2Loader.escape(string), toNotes: inNotes, parser: parser)
    }

    func parser(_ parser: XMLParser, foundIgnorableWhitespace whitespaceString: String) { self.parser(parser, foundCharacters: whitespaceString) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.lowercased()
        if name == "binary", let id = binaryID {
            let compact = binaryText.filter { !$0.isWhitespace }
            guard compact.utf8.count <= maximumImageBytes * 2, let bytes = Data(base64Encoded: compact), bytes.count <= maximumImageBytes,
                  binaries.values.reduce(0, { $0 + $1.data.count }) + bytes.count <= maximumTotalImageBytes else { parser.abortParsing(); return }
            imageIndex += 1; binaries[id] = (imageIndex, bytes); binaryID = nil; binaryText = ""
        }
        if name == "book-title", captureTitle { title = titleText.trimmingCharacters(in: .whitespacesAndNewlines); captureTitle = false }
        guard inBody || inNotes else { if stack.last == name { _ = stack.popLast() }; return }
        let tags: [String: String] = ["section":"section", "title":"h2", "subtitle":"h3", "p":"p", "strong":"strong", "emphasis":"em", "strikethrough":"del", "sub":"sub", "sup":"sup", "code":"code", "poem":"blockquote", "stanza":"div", "v":"p", "cite":"blockquote", "epigraph":"blockquote", "table":"table", "tr":"tr", "td":"td", "th":"th", "ul":"ul", "ol":"ol", "li":"li", "item":"li", "a":"a", "text-author":"p", "date":"time"]
        if name == "list", let tag = listTags.popLast() { append("</\(tag)>", toNotes: inNotes, parser: parser) }
        else if let tag = tags[name] { append("</\(tag)>", toNotes: inNotes, parser: parser) }
        if name == "body" { inNotes = false; inBody = false }
        if stack.last == name { _ = stack.popLast() }
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }

    private func append(_ text: String, toNotes: Bool, parser: XMLParser) {
        if toNotes { notesHTML += text } else { html += text }
        if html.utf8.count + notesHTML.utf8.count > maximumOutputBytes { parser.abortParsing() }
    }
}
