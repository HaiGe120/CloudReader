import CloudReaderCore
import NaturalLanguage
import PDFKit
import SwiftUI
import WebKit

/// Snapshot text only when the reader opens a chat. In scrolling layouts a
/// page means one viewport. A two-page spread supplies both visible pages.
struct ReaderPageContext {
    var previous: String?
    var current: String?
    var next: String?
    var location: String?
    var bookDescription: String?
    var previousLabel = "Previous page"
    var nextLabel = "Next page"

    static func pages(count: Int, first: Int, visibleCount: Int,
                      text: (Int) -> String?) -> Self? {
        guard (0..<count).contains(first) else { return nil }
        let last = min(first + max(1, visibleCount) - 1, count - 1)
        return Self(previous: first > 0 ? text(first - 1) : nil,
                    current: (first...last).compactMap(text).joined(separator: "\n\n"),
                    next: last + 1 < count ? text(last + 1) : nil,
                    location: first == last ? "Page \(first + 1)" : "Pages \(first + 1)–\(last + 1)")
    }

    func excerpt(limit: Int) -> String? {
        let parts = [("Currently reading", current), (previousLabel, previous), (nextLabel, next)]
            .compactMap { label, value -> (String, String)? in
                guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return (label, text)
            }
        guard !parts.isEmpty else { return nil }
        let budget = max(1, (limit - 120) / parts.count)
        return parts.map { label, text in
            let snippet = label == previousLabel ? String(text.suffix(budget)) : String(text.prefix(budget))
            return "\(label):\n\(snippet)"
        }.joined(separator: "\n\n")
    }

    var brief: String? {
        guard let current else { return nil }
        let tokenizer = NLTokenizer(unit: .sentence)
        let text = String(current.prefix(2_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        tokenizer.string = text
        let sentences = tokenizer.tokens(for: text.startIndex..<text.endIndex).prefix(2)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
        guard !sentences.isEmpty else { return nil }
        return "From the current passage: " + String(sentences.prefix(360))
    }
}

struct ReaderChatRequest: Identifiable {
    let id = UUID()
    let book: Book
    let description: String?
    let excerpt: String?
    let passage: String?
    let location: String?
}

@MainActor @Observable final class ReaderPageSource {
    var selectionRect: CGRect?
    @ObservationIgnored var capture: (() async -> ReaderPageContext?)?

    func chatRequest(for book: Book, selection: String?, library: BookLibrary) async -> ReaderChatRequest {
        let pages = await capture?()
        let limit = AIProfileStore.load().modelSource == .appleOnDevice ? AIService.onDeviceContextCharacterLimit : 18_000
        let excerpt = pages?.excerpt(limit: limit)
        let description = book.briefDescription ?? pages?.bookDescription ?? pages?.brief ?? library.briefDescription(for: book)
        let location = excerpt == nil ? nil : [pages?.location, "Includes nearby readable text."].compactMap { $0 }.joined(separator: " · ")
        return ReaderChatRequest(book: book, description: description, excerpt: excerpt,
                                 passage: selection.map { String($0.prefix(6_000)) }, location: location)
    }

    #if os(macOS)
    func locateSelection(in window: NSWindow?, windowRect: CGRect) {
        guard let height = window?.contentView?.bounds.height else { return }
        selectionRect = CGRect(x: windowRect.minX, y: height - windowRect.maxY,
                               width: windowRect.width, height: windowRect.height)
    }
    #endif

    func usePDF(_ view: PDFView) {
        capture = { [weak view] in
            guard let view, let document = view.document, let current = view.currentPage else { return nil }
            let spread = view.displayMode == .twoUp || view.displayMode == .twoUpContinuous
            return .pages(count: document.pageCount, first: document.index(for: current), visibleCount: spread ? 2 : 1) {
                document.page(at: $0)?.string
            }
        }
    }

    func useHTML(_ view: WKWebView, chapter: Int, publication: EPUBPublication, ready: @escaping () -> Bool) {
        capture = { [weak view] in
            guard let view, ready(), publication.chapters.indices.contains(chapter),
                  let result = try? await view.callAsyncJavaScript("return window.cloudReader.pageContext()",
                      arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any] else { return nil }
            var context = ReaderPageContext(previous: result["previous"] as? String,
                current: result["current"] as? String, next: result["next"] as? String,
                location: publication.chapters[chapter].title, bookDescription: publication.briefDescription)
            // Use the same viewport, stylesheet and local resource handler to
            // measure the neighboring chapter without moving the visible reader.
            let visibleCount = max(1, result["visible"] as? Int ?? 1)
            let pageLength = min(4_000, max(600, (context.current?.count ?? 0) / visibleCount))
            func edge(_ index: Int, last: Bool) async -> (text: String?, estimated: Bool) {
                let path = publication.chapters[index].path
                if let rendered = await ChapterPagePreview().excerpt(in: view, path: path, layout: result, last: last) {
                    return (rendered, false)
                }
                // A cold WebKit process can miss the interaction deadline.
                // Preserve a page-sized text excerpt from the correct edge.
                let excerpt = await Task.detached(priority: .userInitiated) {
                    guard let url = try? EPUBResourcePolicy.resourceURL(root: publication.rootURL, relativePath: path) else { return nil as String? }
                    return ChapterExcerpt.read(url: url, last: last, limit: pageLength)
                }.value
                return (excerpt, true)
            }
            if result["atStart"] as? Bool == true, chapter > 0 {
                let previous = await edge(chapter - 1, last: true)
                context.previous = previous.text
                if previous.estimated { context.previousLabel = "Previous chapter ending (excerpt)" }
            }
            if result["atEnd"] as? Bool == true, chapter + 1 < publication.chapters.count {
                let next = await edge(chapter + 1, last: false)
                context.next = next.text
                if next.estimated { context.nextLabel = "Next chapter opening (excerpt)" }
            }
            return context
        }
    }

    // Executed inside the reader's isolated script world. Split text nodes only
    // at viewport boundaries, including paragraphs that span several columns.
    static let htmlPageFunction = #"""
    function(horizontal, pitch, visible, atStart, atEnd, origin = 0) {
      const chunks = {previous: '', current: '', next: ''};
      const extent = Math.max(1, horizontal ? pitch : innerHeight);
      const bucket = rect => Math.floor(((horizontal ? rect.left + Math.min(1, rect.width/2) : rect.top + rect.height/2) - origin) / extent);
      const range = document.createRange();
      function collect(node, start, end) {
        if (end <= start) return;
        range.setStart(node, start); range.setEnd(node, end);
        const rects = range.getClientRects();
        if (!rects.length) return;
        const first = bucket(rects[0]), last = bucket(rects[rects.length - 1]);
        if (last < -1 || first > visible) return;
        if (first !== last && end - start > 1) {
          const mid = Math.floor((start + end) / 2);
          collect(node, start, mid); collect(node, mid, end);
          return;
        }
        const key = first < 0 ? 'previous' : first < visible ? 'current' : 'next';
        const value = node.nodeValue.slice(start, end);
        if (key === 'previous') chunks[key] = (chunks[key] + value).slice(-6000);
        else if (chunks[key].length < 12000) chunks[key] += value.slice(0, 12000 - chunks[key].length);
      }
      const walker = document.createTreeWalker(document.body || document.documentElement, NodeFilter.SHOW_TEXT);
      while (walker.nextNode()) {
        const node = walker.currentNode;
        if (!node.parentElement || node.parentElement.closest('script,style,[hidden],[aria-hidden="true"]')) continue;
        if (getComputedStyle(node.parentElement).visibility !== 'visible') continue;
        collect(node, 0, node.length);
        if (node.nextSibling === null) {
          for (const key of Object.keys(chunks)) if (chunks[key] && !chunks[key].endsWith(' ')) chunks[key] += ' ';
        }
      }
      return {...chunks, atStart, atEnd, horizontal, pitch, visible,
        css: document.getElementById('cloudreader-style')?.textContent || ''};
    }
    """#
}

extension EnvironmentValues {
    @Entry var readerPageSource: ReaderPageSource? = nil
}

@MainActor
private final class ChapterPagePreview: NSObject, WKNavigationDelegate {
    private var pending: CheckedContinuation<Bool, Never>?
    private var documentURL: URL?

    func excerpt(in reader: WKWebView, path: String, layout: [String: Any], last: Bool) async -> String? {
        var components = URLComponents()
        components.scheme = "cloudreader-epub"
        components.host = "book"
        components.path = "/" + path
        guard let url = components.url, let handler = reader.configuration.urlSchemeHandler(forURLScheme: "cloudreader-epub"),
              let css = layout["css"] as? String, let pitch = layout["pitch"] as? Double,
              let horizontal = layout["horizontal"] as? Bool else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = reader.configuration.websiteDataStore
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(handler, forURLScheme: "cloudreader-epub")
        configuration.userContentController.addUserScript(WKUserScript(source: """
            let meta = document.querySelector('meta[name="viewport"]') || document.createElement('meta');
            meta.name = 'viewport'; meta.content = 'width=device-width, initial-scale=1';
            (document.head || document.documentElement).appendChild(meta);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        guard let parent = reader.superview else { return nil }
        let preview = WKWebView(frame: reader.frame, configuration: configuration)
        // WebKit defers custom-scheme loads on unattached iOS web views.
        #if os(iOS)
        preview.isUserInteractionEnabled = false
        preview.accessibilityElementsHidden = true
        preview.alpha = 0.01
        parent.insertSubview(preview, belowSubview: reader)
        #else
        preview.alphaValue = 0.01
        preview.setAccessibilityElement(false)
        parent.addSubview(preview, positioned: .below, relativeTo: reader)
        #endif
        documentURL = url
        preview.navigationDelegate = self
        let timeout = Task {
            try await Task.sleep(for: .seconds(2))
            finish(false)
        }
        defer { timeout.cancel(); preview.stopLoading(); preview.removeFromSuperview() }
        let loaded = await withCheckedContinuation { continuation in
            pending = continuation
            if preview.load(URLRequest(url: url)) == nil { finish(false) }
        }
        guard loaded else { return nil }
        return try? await preview.callAsyncJavaScript("""
            if (!document.body) return '';
            document.querySelectorAll('[style]').forEach(element => {
              for (const property of ['font-family','font-size','font-weight','line-height','text-indent','color',
                'background-color','background-image','margin-left','margin-right','margin-inline-start','margin-inline-end'])
                element.style.removeProperty(property);
            });
            const style = document.createElement('style');
            style.textContent = css; (document.head || document.documentElement).appendChild(style);
            const root = document.scrollingElement || document.documentElement;
            let origin = 0;
            if (last && horizontal) {
              let right = 0;
              const range = document.createRange();
              range.selectNodeContents(document.body);
              for (const rect of range.getClientRects()) if (rect.width && rect.height) right = Math.max(right, rect.right);
              origin = Math.max(0, Math.floor((right - 1) / pitch)) * pitch;
            } else if (last) {
              origin = Math.max(0, root.scrollHeight - innerHeight);
            }
            const collect = \(ReaderPageSource.htmlPageFunction);
            return collect(horizontal, pitch, 1, false, false, origin).current;
            """, arguments: ["css": css, "pitch": pitch, "horizontal": horizontal, "last": last],
            in: nil, contentWorld: .defaultClient) as? String
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url == documentURL ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }

    private func finish(_ loaded: Bool) {
        pending?.resume(returning: loaded)
        pending = nil
    }
}

// Read only body text and bound retained memory when a chapter cannot be laid
// out in time. Opening excerpts can stop the parser as soon as they are full.
private final class ChapterExcerpt: NSObject, XMLParserDelegate {
    let last: Bool
    let limit: Int
    private var inBody = false
    private var ignoredDepth = 0
    private var buffer = ""

    private init(last: Bool, limit: Int) { self.last = last; self.limit = limit }

    static func read(url: URL, last: Bool, limit: Int) -> String? {
        guard let parser = XMLParser(contentsOf: url) else { return nil }
        let reader = ChapterExcerpt(last: last, limit: limit)
        parser.delegate = reader
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        _ = parser.parse()
        let result = reader.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        if name == "body" { inBody = true }
        if ignoredDepth > 0 || ["style", "script"].contains(name) || attributes["hidden"] != nil || attributes["aria-hidden"] == "true" {
            ignoredDepth += 1
        } else if ["p", "div", "br", "li", "h1", "h2"].contains(name) {
            self.parser(parser, foundCharacters: "\n")
        }
    }

    func parser(_ parser: XMLParser, foundCharacters value: String) {
        guard inBody, ignoredDepth == 0 else { return }
        buffer.append(value)
        if buffer.count >= limit {
            buffer = last ? String(buffer.suffix(limit)) : String(buffer.prefix(limit))
            if !last { parser.abortParsing() }
        }
    }

    func parser(_ parser: XMLParser, foundCDATA data: Data) {
        self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if ignoredDepth > 0 { ignoredDepth -= 1 }
        if name == "body" { inBody = false }
    }
}
