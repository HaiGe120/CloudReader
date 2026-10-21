import Combine
import CloudReaderCore
import Foundation

/// Serializes OS-resolved document URLs through the library's copy and durable commit path.
/// Platform UI owns picker/drop presentation; iOS supplies the inbox acknowledgment callback.
@MainActor
final class BookImportCoordinator: ObservableObject {
    @Published private(set) var isImporting = false
    @Published private(set) var bookToOpen: Book?
    @Published private(set) var lastResult = BookImportResult()

    private struct Request {
        let url: URL
        let hasSecurityAccess: Bool
        let acknowledgeDurableImport: ((URL) throws -> Void)?
    }

    private var requests: [Request] = []
    private var queuedURLs: Set<URL> = []
    private var activeTask: Task<Void, Never>?

    func importFiles(
        _ urls: [URL],
        library: BookLibrary,
        acknowledgeDurableImport: ((URL) throws -> Void)? = nil
    ) {
        for url in urls where url.isFileURL {
            let key = url.standardizedFileURL
            guard queuedURLs.insert(key).inserted else { continue }
            requests.append(Request(
                url: url,
                hasSecurityAccess: url.startAccessingSecurityScopedResource(),
                acknowledgeDurableImport: acknowledgeDurableImport
            ))
        }
        guard activeTask == nil, !requests.isEmpty else { return }
        isImporting = true
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.drain(library: library)
        }
    }

    /// Stops queued work immediately and lets an active copy finish its cleanup path.
    /// The source remains available, so the caller can enqueue it again to retry.
    func cancelPendingImports() {
        for request in requests {
            if request.hasSecurityAccess { request.url.stopAccessingSecurityScopedResource() }
            queuedURLs.remove(request.url.standardizedFileURL)
        }
        requests.removeAll()
        activeTask?.cancel()
    }

    private func drain(library: BookLibrary) async {
        var result = BookImportResult()
        var firstImported: Book?
        while !requests.isEmpty, !Task.isCancelled {
            let batch = requests
            requests.removeAll()
            let byURL = Dictionary(uniqueKeysWithValues: batch.map { ($0.url.standardizedFileURL, $0) })
            let batchResult = await library.importBooksAsync(from: batch.map(\.url))
            result.importedBooks.append(contentsOf: batchResult.importedBooks)
            result.importedSourceURLs.append(contentsOf: batchResult.importedSourceURLs)
            result.rejectedFileNames.append(contentsOf: batchResult.rejectedFileNames)
            for (source, imported) in zip(batchResult.importedSourceURLs, batchResult.importedBooks) {
                if firstImported == nil { firstImported = imported }
                do {
                    try byURL[source.standardizedFileURL]?.acknowledgeDurableImport?(source)
                } catch {
                    library.alertMessage = "The book was imported, but its shared copy could not be cleared."
                }
            }
            for request in batch {
                if request.hasSecurityAccess { request.url.stopAccessingSecurityScopedResource() }
                queuedURLs.remove(request.url.standardizedFileURL)
            }
        }
        lastResult = result
        activeTask = nil
        isImporting = false
        if let firstImported { bookToOpen = firstImported }
        // Requests enqueued while cancellation was unwinding remain available to run.
        if !requests.isEmpty {
            isImporting = true
            activeTask = Task { [weak self] in
                guard let self else { return }
                await self.drain(library: library)
            }
        }
    }
}
