import Foundation
import UniformTypeIdentifiers

/// A small, file-only handoff between the share extension and the app.
/// A completed directory is published with an atomic rename so the app never
/// imports a file while an item provider is still writing it.
struct SharedBookInbox {
    static let appGroupIdentifier = "group.io.github.haige120.cloudreader"
    static let supportedExtensions: Set<String> = ["epub", "pdf", "txt", "mobi", "azw3", "fb2", "cbz", "cbr"]
    static let live = SharedBookInbox()

    private let containerURL: URL?
    private let fileManager: FileManager

    init(containerURL: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedBookInbox.appGroupIdentifier), fileManager: FileManager = .default) {
        self.containerURL = containerURL
        self.fileManager = fileManager
    }

    static var contentTypes: [UTType] {
        [.epub, .pdf, .plainText] + ["mobi", "azw3", "fb2", "cbz", "cbr"].compactMap {
            UTType(filenameExtension: $0, conformingTo: .data)
        }
    }

    @discardableResult
    func stageFile(at source: URL, suggestedName: String? = nil, preferredExtension: String? = nil) throws -> URL {
        guard source.isFileURL else { throw InboxError.unsupportedFile }
        let hasAccess = source.startAccessingSecurityScopedResource()
        defer { if hasAccess { source.stopAccessingSecurityScopedResource() } }

        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw InboxError.unsupportedFile }

        let name = try Self.fileName(source: source, suggestedName: suggestedName, preferredExtension: preferredExtension)
        let inbox = try inboxDirectory(create: true)
        let identifier = UUID().uuidString
        let stagingDirectory = inbox.appendingPathComponent(".\(identifier)", isDirectory: true)
        let readyDirectory = inbox.appendingPathComponent(identifier, isDirectory: true)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        do {
            let destination = stagingDirectory.appendingPathComponent(name)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readableURL in
                do { try fileManager.copyItem(at: readableURL, to: destination) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            try fileManager.moveItem(at: stagingDirectory, to: readyDirectory)
            return readyDirectory.appendingPathComponent(name)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }
    }

    func pendingFiles() throws -> [URL] {
        let inbox = try inboxDirectory(create: false)
        guard fileManager.fileExists(atPath: inbox.path) else { return [] }
        let directories = try fileManager.contentsOfDirectory(at: inbox, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey], options: [.skipsHiddenFiles])
            .filter { UUID(uuidString: $0.lastPathComponent) != nil && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted {
                let first = (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let second = (try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return first < second
            }
        return try directories.flatMap { directory in
            try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).filter { url in
                guard Self.supportedExtensions.contains(url.pathExtension.lowercased()),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }
        }
    }

    /// Remove a queued copy only after the app has successfully imported it.
    func removeFile(at url: URL) throws {
        let inbox = try inboxDirectory(create: false).standardizedFileURL
        let directory = url.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent() == inbox,
              UUID(uuidString: directory.lastPathComponent) != nil else { throw InboxError.invalidInboxFile }
        try fileManager.removeItem(at: directory)
    }

    private func inboxDirectory(create: Bool) throws -> URL {
        guard let containerURL else { throw InboxError.sharedContainerUnavailable }
        let directory = containerURL.appendingPathComponent("SharedBookInbox", isDirectory: true)
        if create { try fileManager.createDirectory(at: directory, withIntermediateDirectories: true) }
        return directory
    }

    private static func fileName(source: URL, suggestedName: String?, preferredExtension: String?) throws -> String {
        let suggested = suggestedName.map { ($0 as NSString).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
        let original = source.lastPathComponent
        let name: String
        if let suggested, supportedExtensions.contains((suggested as NSString).pathExtension.lowercased()) {
            name = suggested
        } else if supportedExtensions.contains(source.pathExtension.lowercased()) {
            if let suggested, (suggested as NSString).pathExtension.isEmpty {
                name = "\(suggested).\(source.pathExtension)"
            } else {
                name = original
            }
        } else if let preferredExtension, supportedExtensions.contains(preferredExtension.lowercased()) {
            name = "\(suggested ?? source.deletingPathExtension().lastPathComponent).\(preferredExtension.lowercased())"
        } else {
            throw InboxError.unsupportedFile
        }
        guard !name.hasPrefix("."), !name.contains(":"), name.utf8.count <= 240 else { throw InboxError.unsupportedFile }
        return name
    }

    enum InboxError: LocalizedError {
        case sharedContainerUnavailable
        case unsupportedFile
        case invalidInboxFile

        var errorDescription: String? {
            switch self {
            case .sharedContainerUnavailable: "CloudReader's shared storage is unavailable. Open CloudReader once, then try sharing the book again."
            case .unsupportedFile: "Choose an EPUB, PDF, TXT, MOBI, AZW3, FB2, CBZ, or CBR book file."
            case .invalidInboxFile: "The shared book could not be found."
            }
        }
    }
}
