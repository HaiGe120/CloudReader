import Foundation

enum IllustratedCoverSource {
    static func fb2(at url: URL) throws -> Data? {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size <= 64 * 1_024 * 1_024 else { throw EPUBError.tooLarge }
        guard let stream = InputStream(url: url) else { throw EPUBError.invalidBook }
        let parser = XMLParser(stream: stream)
        let delegate = FB2CoverParser()
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let completed = parser.parse()
        try Task.checkCancellation()
        if let cover = delegate.cover { return cover }
        guard completed || delegate.finished else { throw EPUBError.invalidBook }
        return nil
    }

    static func cbz(at url: URL) throws -> Data? { try CBZLoader.coverData(at: url) }
    static func cbr(at url: URL) throws -> Data? { try CBRLoader.coverData(at: url) }
}

/// FB2 places title metadata before the body and its binary resources. Only collect the
/// binary referenced by title-info/coverpage, leaving chapter text and illustrations streamed.
private final class FB2CoverParser: NSObject, XMLParserDelegate {
    private var stack: [String] = []
    private var coverID: String?
    private var base64: Data?
    private let maximumBytes = 12 * 1_024 * 1_024
    private(set) var finished = false
    private(set) var cover: Data?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard !Task.isCancelled, stack.count < 128 else { parser.abortParsing(); return }
        stack.append(elementName.lowercased())
        if stack == ["fictionbook", "description", "title-info", "coverpage", "image"], coverID == nil {
            let href = attributes.first { $0.key == "href" || $0.key.hasSuffix(":href") }?.value
            if let href, href.hasPrefix("#"), href.count > 1 { coverID = String(href.dropFirst()) }
        } else if stack == ["fictionbook", "binary"], let coverID, attributes["id"] == coverID {
            base64 = Data()
        } else if stack == ["fictionbook", "body"], coverID == nil {
            finished = true
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !Task.isCancelled else { parser.abortParsing(); return }
        guard base64 != nil else { return }
        let bytes = string.utf8
        guard bytes.count <= maximumBytes * 2 - (base64?.count ?? 0) else {
            finished = true
            parser.abortParsing()
            return
        }
        base64?.append(contentsOf: bytes)
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        if let text = String(data: data, encoding: .utf8) { self.parser(parser, foundCharacters: text) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "binary", let base64 {
            if let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
               !decoded.isEmpty, decoded.count <= maximumBytes { cover = decoded }
            finished = true
            parser.abortParsing()
        }
        _ = stack.popLast()
    }
}
