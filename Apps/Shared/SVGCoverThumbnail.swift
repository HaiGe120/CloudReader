import ImageIO
import WebKit

@MainActor
enum SVGCoverThumbnail {
    private static let webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return WKWebView(frame: .zero, configuration: configuration)
    }()

    static func thumbnail(data: Data, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled, maxPixelSize > 0, data.count <= 4 * 1_024 * 1_024 else { return nil }
        let root = SVGRoot()
        let parser = XMLParser(data: data)
        parser.delegate = root
        parser.shouldProcessNamespaces = true
        parser.externalEntityResolvingPolicy = .never
        _ = parser.parse()
        guard root.isSVG else { return nil }
        // An SVG loaded into an Image is inert. Never navigate to the book's XML or inject it into the DOM.
        let arguments: [String: Any] = ["source": data.base64EncodedString(), "limit": min(maxPixelSize, 1024)]
        let script = """
            const image = new Image();
            image.src = "data:image/svg+xml;base64," + source;
            await image.decode();
            const width = image.naturalWidth, height = image.naturalHeight;
            if (!width || !height) return null;
            const canvas = document.createElement("canvas");
            const longest = Math.max(width, height);
            canvas.width = Math.max(1, Math.round(width / longest * limit));
            canvas.height = Math.max(1, Math.round(height / longest * limit));
            canvas.getContext("2d").drawImage(image, 0, 0, canvas.width, canvas.height);
            return canvas.toDataURL("image/png").split(",")[1];
            """
        let encoded: String? = await withCheckedContinuation { continuation in
            // A stalled WebContent process cannot run its own JavaScript timeout.
            var pending: CheckedContinuation<String?, Never>? = continuation
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                pending?.resume(returning: nil)
                pending = nil
            }
            webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                timeout.cancel()
                pending?.resume(returning: (try? result.get()) as? String)
                pending = nil
            }
        }
        guard !Task.isCancelled, let encoded, let png = Data(base64Encoded: encoded) else { return nil }
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

private final class SVGRoot: NSObject, XMLParserDelegate {
    var isSVG = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        isSVG = elementName == "svg" && namespaceURI == "http://www.w3.org/2000/svg"
        parser.abortParsing()
    }
}
