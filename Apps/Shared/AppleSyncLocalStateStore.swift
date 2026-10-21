import CloudReaderCore
import Foundation

/// App-private durable state used by sync. Recovery alternatives stay local because v1 has no wire field for them.
actor AppleSyncLocalStateStore {
    private struct RecoveryJournal: Codable {
        let version: Int
        let candidates: [SyncRecoveryCandidate]
    }

    private struct RootOpaqueSnapshot: Codable {
        let version: Int
        let fields: [String: JSONValue]
    }

    private let directory: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.directory = directory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CloudReader", isDirectory: true)
            .appendingPathComponent("SyncState", isDirectory: true)
        self.fileManager = fileManager
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
    }

    func loadRecoveryCandidates() throws -> [SyncRecoveryCandidate] {
        let url = recoveryURL
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let journal = try decoder.decode(RecoveryJournal.self, from: Data(contentsOf: url))
        guard journal.version == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unsupported sync recovery journal version."])
        }
        return stableCandidates(journal.candidates)
    }

    func appendRecoveryCandidates(_ candidates: [SyncRecoveryCandidate]) throws {
        guard !candidates.isEmpty else { return }
        // Decode strictly before changing anything: a damaged journal must never be silently replaced.
        let current = try loadRecoveryCandidates()
        let journal = RecoveryJournal(version: 1, candidates: stableCandidates(current + candidates))
        try atomicWrite(encoder.encode(journal), to: recoveryURL)
    }

    func loadRootOpaqueManifestFields() throws -> [String: JSONValue] {
        let url = rootOpaqueURL
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let snapshot = try decoder.decode(RootOpaqueSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "Unsupported root opaque snapshot version."])
        }
        return snapshot.fields
    }

    func saveRootOpaqueManifestFields(_ fields: [String: JSONValue]) throws {
        try atomicWrite(encoder.encode(RootOpaqueSnapshot(version: 1, fields: fields)), to: rootOpaqueURL)
    }

    private var recoveryURL: URL { directory.appendingPathComponent("sync-recovery-v1.json") }
    private var rootOpaqueURL: URL { directory.appendingPathComponent("sync-root-opaque-v1.json") }

    private func stableCandidates(_ candidates: [SyncRecoveryCandidate]) -> [SyncRecoveryCandidate] {
        let keyed = candidates.compactMap { candidate -> (Data, SyncRecoveryCandidate)? in
            guard let data = try? encoder.encode(candidate) else { return nil }
            return (data, candidate)
        }
        var seen = Set<Data>()
        return keyed.filter { seen.insert($0.0).inserted }
            .sorted { $0.0.lexicographicallyPrecedes($1.0) }
            .map(\.1)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Data.WritingOptions.atomic writes a sibling temporary file then replaces the destination.
        try data.write(to: url, options: .atomic)
    }
}
