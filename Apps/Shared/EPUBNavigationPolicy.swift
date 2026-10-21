import Foundation

/// Interprets an EPUB-internal link after the native WebKit host has validated
/// its scheme and host. Presentation and resource loading stay platform-owned.
enum EPUBNavigationPolicy {
    enum Destination: Equatable {
        case chapter(index: Int, fragment: String?)
        case document(path: String, fragment: String?)
    }

    static func destination(
        path: String,
        fragment: String?,
        currentPath: String?,
        chapters: [EPUBChapter],
        mediaTypes: [String: String]
    ) -> Destination? {
        guard !path.isEmpty, path != currentPath else { return nil }

        if let index = chapters.firstIndex(where: { $0.path == path }) {
            return .chapter(index: index, fragment: fragment)
        }

        let extensionIsDocument = ["html", "htm", "xhtml", "svg"].contains(
            (path as NSString).pathExtension.lowercased()
        )
        let mime = mediaTypes[path]?.lowercased()
        let mimeIsDocument = ["text/html", "application/xhtml+xml", "image/svg+xml"].contains(mime ?? "")
        guard extensionIsDocument || mimeIsDocument else { return nil }
        return .document(path: path, fragment: fragment)
    }
}
