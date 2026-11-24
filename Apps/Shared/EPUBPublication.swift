import Foundation
import ZIPFoundation

struct EPUBChapter: Codable, Equatable, Sendable {
    let path: String
    let title: String
}

struct EPUBPublication: Codable, Sendable {
    let rootURL: URL
    let title: String?
    let chapters: [EPUBChapter]
    var mediaTypes: [String: String] = [:]
    var briefDescription: String? = nil

    func url(for chapter: Int) -> URL {
        rootURL.appendingPathComponent(chapters[chapter].path)
    }

    static func location(progress: Double, chapterCount: Int) -> (chapter: Int, fraction: Double) {
        guard chapterCount > 0 else { return (0, 0) }
        let position = (progress.isFinite ? min(max(progress, 0), 1) : 0) * Double(chapterCount)
        let chapter = min(Int(position), chapterCount - 1)
        return (chapter, min(max(position - Double(chapter), 0), 1))
    }

    static func progress(chapter: Int, fraction: Double, chapterCount: Int) -> Double {
        guard chapterCount > 0 else { return 0 }
        // Keep an unfinished chapter on its own side of the next chapter boundary.
        let upperBound = chapter == chapterCount - 1 ? 1.0 : 1.0 - 1e-8
        let fraction = fraction.isFinite ? min(max(fraction, 0), upperBound) : 0
        return min(max((Double(chapter) + fraction) / Double(chapterCount), 0), 1)
    }
}

enum EPUBError: LocalizedError {
    case invalidBook, unsafePath, tooLarge, encrypted, noChapters

    var errorDescription: String? {
        switch self {
        case .invalidBook: "This EPUB is damaged or is missing its book information. Try importing another copy."
        case .unsafePath: "This EPUB contains an invalid file path and could not be opened."
        case .tooLarge: "This EPUB is too large to prepare on this device."
        case .encrypted: "This EPUB is protected by DRM. Import a DRM-free copy to read it in CloudReader."
        case .noChapters: "This EPUB does not contain any readable chapters."
        }
    }
}

/// Unpacks once, off the main actor. The cache is disposable; the imported original is untouched.
actor EPUBLoader {
    static let shared = EPUBLoader()
    private let fileManager = FileManager.default

    func open(url: URL, bookID: UUID) throws -> EPUBPublication {
        try Task.checkCancellation()
        // URL resource values can remain cached on the same URL instance after a sync
        // replaces its file. Read fresh attributes so a replaced book is never stale.
        let values = try fileManager.attributesOfItem(atPath: url.path)
        let fingerprint = "v4-\(values[.size] as? UInt64 ?? 0)-\((values[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        let cache = try fileManager.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("EPUB", isDirectory: true).appendingPathComponent(bookID.uuidString, isDirectory: true)
        let marker = cache.appendingPathComponent("publication.json")
        if let data = try? Data(contentsOf: marker),
           let saved = try? JSONDecoder().decode(CachedPublication.self, from: data), saved.fingerprint == fingerprint,
           !saved.chapters.isEmpty,
           saved.chapters.allSatisfy({ chapter in
               let resource = cache.appendingPathComponent(chapter.path).standardizedFileURL
               guard resource.path.hasPrefix(cache.path + "/") else { return false }
               return fileManager.fileExists(atPath: resource.path)
           }) {
            return EPUBPublication(rootURL: cache, title: saved.title, chapters: saved.chapters, mediaTypes: saved.mediaTypes, briefDescription: saved.briefDescription)
        }

        let staging = cache.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) }
        catch { throw EPUBError.invalidBook }
        var totalSize: UInt64 = 0
        var entryCount = 0
        for entry in archive {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= 25_000, entry.uncompressedSize <= 128 * 1_024 * 1_024 else { throw EPUBError.tooLarge }
            totalSize += entry.uncompressedSize
            guard totalSize <= 1_024 * 1_024 * 1_024 else { throw EPUBError.tooLarge }
            guard entry.type != .symlink else { throw EPUBError.unsafePath }
            // ZIP entry names are literal paths, not URL-encoded package hrefs.
            guard !entry.path.hasPrefix("/"), !entry.path.contains("\\"),
                  !entry.path.split(separator: "/").contains("..") else { throw EPUBError.unsafePath }
            let destination = staging.appendingPathComponent(entry.path).standardizedFileURL
            guard destination.path.hasPrefix(staging.path + "/") else { throw EPUBError.unsafePath }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
        }

        let container = try Self.xml(at: staging.appendingPathComponent("META-INF/container.xml"))
        let packagePath = try Self.packagePath(in: container)
        let packageURL = try Self.resolve(packagePath, relativeTo: staging, root: staging)
        let package = try Self.xml(at: packageURL)
        if let encryption = try? Self.xml(at: staging.appendingPathComponent("META-INF/encryption.xml")) {
            let fontAlgorithms = ["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"]
            if encryption.descendants(named: "EncryptionMethod").contains(where: { !fontAlgorithms.contains($0.attributes["Algorithm"] ?? "") }) {
                throw EPUBError.encrypted
            }
        }
        let base = packageURL.deletingLastPathComponent()
        var manifest: [String: EPUBXMLNode] = [:]
        for item in package.descendants(named: "manifest").first?.children ?? [] {
            if let id = item.attributes["id"] { manifest[id] = item }
        }
        var mediaTypes: [String: String] = [:]
        for item in manifest.values {
            guard let href = item.attributes["href"], let type = item.attributes["media-type"],
                  let resource = try? Self.resolve(href, relativeTo: base, root: staging) else { continue }
            mediaTypes[String(resource.path.dropFirst(staging.path.count + 1))] = type
        }
        var labels: [String: String] = [:]
        for item in manifest.values {
            let isNav = (item.attributes["properties"] ?? "").split(separator: " ").contains("nav")
            let isNCX = item.attributes["media-type"] == "application/x-dtbncx+xml"
            guard isNav || isNCX, let href = item.attributes["href"],
                  let navURL = try? Self.resolve(href, relativeTo: base, root: staging),
                  let nav = try? Self.xml(at: navURL) else { continue }
            if isNav {
                let navigation = nav.descendants(named: "nav")
                let toc = navigation.first(where: { ($0.attributes["epub:type"] ?? $0.attributes["type"] ?? "").contains("toc") }) ?? navigation.first
                for link in toc?.descendants(named: "a") ?? [] {
                    if let target = link.attributes["href"], let resolved = try? Self.resolve(target, relativeTo: navURL.deletingLastPathComponent(), root: staging) {
                        if labels[resolved.path] == nil { labels[resolved.path] = link.allText }
                    }
                }
            } else {
                for point in nav.descendants(named: "navPoint") {
                    if let target = point.children.first(where: { $0.name == "content" })?.attributes["src"],
                       let resolved = try? Self.resolve(target, relativeTo: navURL.deletingLastPathComponent(), root: staging),
                       let label = point.children.first(where: { $0.name == "navLabel" })?.allText,
                       labels[resolved.path] == nil { labels[resolved.path] = label }
                }
            }
        }
        var chapters: [EPUBChapter] = []
        for reference in package.descendants(named: "spine").first?.children ?? [] {
            guard reference.name == "itemref", reference.attributes["linear"] != "no",
                  let item = manifest[reference.attributes["idref"] ?? ""],
                  ["application/xhtml+xml", "text/html", "image/svg+xml"].contains(item.attributes["media-type"] ?? ""),
                  let href = item.attributes["href"] else { continue }
            let chapterURL = try Self.resolve(href, relativeTo: base, root: staging)
            guard fileManager.fileExists(atPath: chapterURL.path) else { throw EPUBError.invalidBook }
            let path = String(chapterURL.path.dropFirst(staging.path.count + 1))
            let label = labels[chapterURL.path]?.trimmingCharacters(in: .whitespacesAndNewlines)
            chapters.append(EPUBChapter(path: path, title: label?.isEmpty == false ? label! : "Chapter \(chapters.count + 1)"))
        }
        guard !chapters.isEmpty else { throw EPUBError.noChapters }
        let metadata = package.descendants(named: "metadata").first?.children
        let title = metadata?.first(where: { $0.name == "title" })?.allText
        let description = metadata?.first(where: { $0.name == "description" })?.allText
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let brief = description.flatMap { $0.isEmpty ? nil : String($0.prefix(800)) }
        let saved = CachedPublication(fingerprint: fingerprint, title: title, chapters: chapters, mediaTypes: mediaTypes, briefDescription: brief)
        try JSONEncoder().encode(saved).write(to: staging.appendingPathComponent("publication.json"), options: .atomic)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: cache.path) { try fileManager.removeItem(at: cache) }
        try fileManager.moveItem(at: staging, to: cache)
        return EPUBPublication(rootURL: cache, title: title, chapters: chapters, mediaTypes: mediaTypes, briefDescription: brief)
    }

    static func resolve(_ href: String, relativeTo base: URL, root: URL) throws -> URL {
        guard let components = URLComponents(string: href), components.scheme == nil, components.host == nil,
              !components.path.hasPrefix("/"), !components.path.contains("\\"), !components.path.contains("\0") else { throw EPUBError.unsafePath }
        let url = base.appendingPathComponent(components.path).standardizedFileURL
        guard url.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw EPUBError.unsafePath }
        return url
    }

    private static func packagePath(in container: EPUBXMLNode) throws -> String {
        let rootfiles = container.descendants(named: "rootfile")
        guard let path = (rootfiles.first { $0.attributes["media-type"] == "application/oebps-package+xml" } ?? rootfiles.first)?.attributes["full-path"] else {
            throw EPUBError.invalidBook
        }
        return path
    }

    private static func xml(at url: URL) throws -> EPUBXMLNode {
        try xml(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private static func xml(data: Data, captureInlineSVG: Bool = false) throws -> EPUBXMLNode {
        guard data.count <= 4 * 1_024 * 1_024 else { throw EPUBError.tooLarge }
        let delegate = EPUBXMLParser(captureInlineSVG: captureInlineSVG)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else { throw EPUBError.invalidBook }
        return root
    }

    private struct CachedPublication: Codable {
        let fingerprint: String
        let title: String?
        let chapters: [EPUBChapter]
        let mediaTypes: [String: String]
        let briefDescription: String?
    }
}

extension EPUBLoader {
    /// Reads the container, package and selected cover resources directly from the ZIP.
    /// Library thumbnails do not need the reader's unpacked chapter cache.
    static func coverData(at url: URL) throws -> Data? {
        let archive = try Archive(url: url, accessMode: .read)
        // All resolved paths are keys into the archive. No URL here is opened.
        let root = URL(fileURLWithPath: "/EPUB", isDirectory: true)
        let xmlLimit = 4 * 1_024 * 1_024
        func read(_ resource: URL, limit: Int) throws -> Data? {
            let path = String(resource.path.dropFirst(root.path.count + 1))
            let match = try archive.enumerated().first { index, entry in
                try Task.checkCancellation()
                guard index < 25_000 else { throw EPUBError.tooLarge }
                return entry.path == path && entry.type == .file
            }
            guard let entry = match?.element, entry.uncompressedSize > 0, entry.uncompressedSize <= UInt64(limit) else { return nil }
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard chunk.count <= limit - bytes.count else { throw EPUBError.tooLarge }
                bytes.append(chunk)
            }
            guard checksum == entry.checksum else { throw EPUBError.invalidBook }
            return bytes
        }

        guard let container = try read(root.appendingPathComponent("META-INF/container.xml"), limit: xmlLimit) else {
            throw EPUBError.invalidBook
        }
        let packageURL = try resolve(packagePath(in: xml(data: container)), relativeTo: root, root: root)
        guard let packageData = try read(packageURL, limit: xmlLimit) else { throw EPUBError.invalidBook }
        let package = try xml(data: packageData)
        let items = package.children.first { $0.name == "manifest" }?.children ?? []
        let base = packageURL.deletingLastPathComponent()

        func artwork(at resource: URL, mediaType: String?, depth: Int = 0, imageOnlyPage: Bool = false) throws -> Data? {
            let ext = resource.pathExtension.lowercased()
            let isSVG = mediaType == "image/svg+xml" || ext == "svg"
            let isPage = ["application/xhtml+xml", "text/html"].contains(mediaType ?? "") || ["htm", "xhtml", "html"].contains(ext)
            if !isPage && !isSVG {
                guard !imageOnlyPage || mediaType?.hasPrefix("image/") == true else { return nil }
                return try read(resource, limit: 16 * 1_024 * 1_024)
            }
            guard depth <= 2, let data = try read(resource, limit: xmlLimit),
                  let page = try? xml(data: data, captureInlineSVG: isPage) else { return nil }
            let body = page.descendants(named: "body").first ?? page
            if imageOnlyPage && isPage && body.hasTextOutsideSVG { return nil }
            let htmlImage = body.descendants(named: "img").first
            let drawing = page.name == "svg" ? page : body.descendants(named: "svg").first
            if htmlImage == nil, let drawing {
                // Keep the complete drawing (including title text, layers and transforms)
                // when its image resources travel inside the SVG itself.
                let references = drawing.descendants(named: "image") + drawing.descendants(named: "use")
                if references.allSatisfy({ element in
                    guard let href = element.attributes["href"] ?? element.attributes["xlink:href"] else { return true }
                    return href.hasPrefix("data:image/") || href.hasPrefix("#")
                }) {
                    return drawing === page ? data : drawing.inlineSVG
                }
            }
            guard let image = htmlImage ?? drawing?.descendants(named: "image").first ?? body.descendants(named: "object").first else { return nil }
            guard let href = image.attributes["src"] ?? image.attributes["href"] ?? image.attributes["xlink:href"] ?? image.attributes["data"] else { return nil }
            if href.hasPrefix("data:image/"), let comma = href.firstIndex(of: ","), href[..<comma].hasSuffix(";base64") {
                return Data(base64Encoded: String(href[href.index(after: comma)...]), options: .ignoreUnknownCharacters)
            }
            guard let imageURL = try? resolve(href, relativeTo: resource.deletingLastPathComponent(), root: root) else { return nil }
            return try artwork(at: imageURL, mediaType: nil, depth: depth + 1)
        }

        let declared = items.first { ($0.attributes["properties"] ?? "").split(whereSeparator: \.isWhitespace).contains("cover-image") }
        let legacyID = package.children.first { $0.name == "metadata" }?.children.first {
            $0.name == "meta" && $0.attributes["name"]?.lowercased() == "cover"
        }?.attributes["content"]
        let legacy = legacyID.flatMap { id in items.first { $0.attributes["id"] == id } }
        let guide = package.children.first { $0.name == "guide" }?.children.first { $0.attributes["type"]?.lowercased() == "cover" }
        let named = items.first { item in
            let type = item.attributes["media-type"] ?? ""
            guard type.hasPrefix("image/") || ["application/xhtml+xml", "text/html"].contains(type),
                  let href = item.attributes["href"], let url = try? resolve(href, relativeTo: base, root: root) else { return false }
            let names = [item.attributes["id"] ?? "", url.deletingPathExtension().lastPathComponent]
            return names.contains { ["cover", "coverimage", "frontcover", "coverpage", "coverart"].contains($0.lowercased().filter(\.isLetter)) }
        }
        let firstID = package.children.first { $0.name == "spine" }?.children.first { $0.name == "itemref" }?.attributes["idref"]
        let firstPage = firstID.flatMap { id in items.first { $0.attributes["id"] == id } }

        var tried = Set<URL>()
        for (candidate, imageOnlyPage) in [(declared, false), (legacy, false), (guide, false), (named, false), (firstPage, true)] {
            guard let candidate, let href = candidate.attributes["href"], let resource = try? resolve(href, relativeTo: base, root: root),
                  tried.insert(resource).inserted else { continue }
            if let bytes = try artwork(at: resource, mediaType: candidate.attributes["media-type"], imageOnlyPage: imageOnlyPage) {
                return bytes
            }
        }
        return nil
    }
}

private final class EPUBXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [EPUBXMLNode] = []
    var inlineSVG: Data?
    var allText: String { ([text] + children.map(\.allText)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    var hasTextOutsideSVG: Bool {
        name != "svg" && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || children.contains(where: \.hasTextOutsideSVG))
    }

    init(name: String, attributes: [String: String]) {
        self.name = name.split(separator: ":").last.map(String.init) ?? name
        self.attributes = attributes
    }

    func descendants(named name: String) -> [EPUBXMLNode] {
        children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(named: name) }
    }
}

private final class EPUBXMLParser: NSObject, XMLParserDelegate {
    var root: EPUBXMLNode?
    private var stack: [EPUBXMLNode] = []
    private var captureInlineSVG: Bool
    private var svgRoot: EPUBXMLNode?
    private var svgSource = ""

    init(captureInlineSVG: Bool) { self.captureInlineSVG = captureInlineSVG }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        guard stack.count < 128 else { parser.abortParsing(); return }
        let node = EPUBXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        if captureInlineSVG && (svgRoot != nil || node.name == "svg") {
            var attributes = attributeDict
            if svgRoot == nil {
                svgRoot = node
                attributes["xmlns"] = attributeDict["xmlns"] ?? "http://www.w3.org/2000/svg"
                for ancestor in stack.reversed() {
                    for (key, value) in ancestor.attributes where key.hasPrefix("xmlns:") && attributes[key] == nil {
                        attributes[key] = value
                    }
                }
            }
            svgSource += "<" + elementName
            for (key, value) in attributes {
                svgSource += " " + key + "=\"" + Self.escapedXML(value).replacingOccurrences(of: "\"", with: "&quot;") + "\""
            }
            svgSource += ">"
        }
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
        if svgRoot != nil { svgSource += Self.escapedXML(string) }
    }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        self.parser(parser, foundCharacters: String(decoding: CDATABlock, as: UTF8.self))
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let node = stack.popLast()
        if let svgRoot {
            svgSource += "</" + elementName + ">"
            if node === svgRoot {
                svgRoot.inlineSVG = Data(svgSource.utf8)
                self.svgRoot = nil
                captureInlineSVG = false
                svgSource = ""
            }
        }
    }

    private static func escapedXML(_ string: String) -> String {
        string.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
