import Foundation
import UniformTypeIdentifiers

extension SharedBookInbox {
    func stage(_ provider: NSItemProvider) async throws {
        #if os(iOS)
        let suggestedName = provider.suggestedName
        #else
        let suggestedName: String? = nil
        #endif
        let specificTypeIdentifier = provider.registeredTypeIdentifiers.first { identifier in
            guard let type = UTType(identifier), let fileExtension = type.preferredFilenameExtension else { return false }
            return SharedBookInbox.supportedExtensions.contains(fileExtension.lowercased())
        }
        let suggestedExtension = suggestedName.map { ($0 as NSString).pathExtension.lowercased() }
        let genericTypeIdentifier = provider.registeredTypeIdentifiers.first { UTType($0)?.conforms(to: .data) == true }
        let typeIdentifier = specificTypeIdentifier ?? (suggestedExtension.map { SharedBookInbox.supportedExtensions.contains($0) } == true ? genericTypeIdentifier : nil)
        let urlIdentifier = [UTType.fileURL.identifier, UTType.url.identifier].first {
            provider.hasItemConformingToTypeIdentifier($0)
        }

        if let typeIdentifier {
            let preferredExtension = specificTypeIdentifier.flatMap { UTType($0)?.preferredFilenameExtension } ?? suggestedExtension
            do {
                try await stageFileRepresentation(provider, typeIdentifier: typeIdentifier, suggestedName: suggestedName, preferredExtension: preferredExtension)
                return
            } catch {
                guard urlIdentifier != nil else { throw error }
            }
        }
        guard let urlIdentifier else { throw SharedBookInbox.InboxError.unsupportedFile }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadItem(forTypeIdentifier: urlIdentifier) { item, error in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url, url.isFileURL else {
                    continuation.resume(throwing: error ?? SharedBookInbox.InboxError.unsupportedFile)
                    return
                }
                do {
                    try self.stageFile(at: url, suggestedName: suggestedName)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func stageFileRepresentation(_ provider: NSItemProvider, typeIdentifier: String, suggestedName: String?, preferredExtension: String?) async throws {
        // Item-provider URLs are valid only inside this completion handler.
        // Copy into the app group before resuming the async operation.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? SharedBookInbox.InboxError.unsupportedFile)
                    return
                }
                do {
                    try self.stageFile(at: url, suggestedName: suggestedName, preferredExtension: preferredExtension)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
