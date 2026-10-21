import Foundation

/// Resource rules shared by the native WKURLSchemeHandler adapters.
/// WebKit task lifecycle and platform MIME type discovery remain in each app.
enum EPUBResourcePolicy {
    private static let contentSecurityPolicy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src cloudreader-epub: data: blob:; style-src cloudreader-epub: 'unsafe-inline'; script-src 'none'; connect-src 'none'; frame-src 'none'; form-action 'none';\"/>"

    static func resourceURL(root: URL, relativePath: String) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw EPUBError.unsafePath
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = canonicalRoot.appendingPathComponent(relativePath).standardizedFileURL
            .resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(canonicalRoot.path + "/") else {
            throw EPUBError.unsafePath
        }
        return candidate
    }

    static func prepare(
        data input: Data,
        resourceURL: URL,
        requestPath: String,
        mediaTypes: [String: String],
        fallbackMIMEType: String
    ) throws -> (data: Data, mimeType: String) {
        let ext = resourceURL.pathExtension.lowercased()
        let rawMIME = mediaTypes[requestPath] ?? fallbackMIMEType
        let mime = normalizedMIMEType(rawMIME)
        let isHTML = ["text/html", "application/xhtml+xml"].contains(mime)
            || ["html", "xhtml", "htm"].contains(ext)
        guard isHTML else { return (input, mime) }

        guard var html = String(data: input, encoding: .utf8) ?? String(data: input, encoding: .utf16) else {
            throw EPUBError.invalidBook
        }
        if let head = html.range(of: "<head(?:\\s[^>]*)?>", options: [.regularExpression, .caseInsensitive]) {
            html.insert(contentsOf: contentSecurityPolicy, at: head.upperBound)
        } else {
            html = contentSecurityPolicy + html
        }
        return (Data(html.utf8), "text/html")
    }

    static func normalizedMIMEType(_ value: String) -> String {
        let base = value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
        let normalized = base.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? "application/octet-stream" : normalized
    }
}
