import Foundation

public struct SyncRecoveryCandidate: Codable, Hashable, Sendable {
    public var kind: String
    public var entityID: String
    public var field: String?
    public var value: JSONValue
    public init(kind: String, entityID: String, field: String? = nil, value: JSONValue) {
        self.kind = kind; self.entityID = entityID; self.field = field; self.value = value
    }
}

public struct RemoteManifestMergeResult: Sendable {
    public var manifest: RemoteLibraryManifest
    public var recoveryCandidates: [SyncRecoveryCandidate]
    public init(manifest: RemoteLibraryManifest, recoveryCandidates: [SyncRecoveryCandidate]) {
        self.manifest = manifest; self.recoveryCandidates = recoveryCandidates
    }
}

enum SyncMergePolicy {
    static func json<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        let data = (try? encoder.encode(value)) ?? Data("null".utf8)
        return (try? JSONDecoder().decode(JSONValue.self, from: data)) ?? .null
    }
    static func mergedOpaque(_ groups: [(String, String, OpaqueJSONFields)], recovery: inout [SyncRecoveryCandidate]) -> OpaqueJSONFields {
        var out: [String: JSONValue] = [:]
        for (kind,id,fields) in groups {
            for (key,value) in fields.values {
                if let old = out[key], old != value {
                    let candidates = [old,value].sorted(by: JCSCanonicalJSON.less)
                    out[key] = candidates[0]
                    for candidate in candidates { recovery.append(.init(kind: kind, entityID: id, field: key, value: candidate)) }
                } else { out[key] = value }
            }
        }
        return OpaqueJSONFields(values: out)
    }

    static func portableBook(_ book: Book) -> JSONValue {
        var copy = book
        copy.unknownFields = OpaqueJSONFields()
        return json(copy)
    }

    static func portableConversationMetadata(_ conversation: AIConversationRecord) -> JSONValue {
        var copy = conversation
        copy.messages = []
        copy.unknownFields = OpaqueJSONFields()
        guard case .object(var fields) = json(copy) else { return .null }
        fields.removeValue(forKey: "messages")
        return .object(fields)
    }

    static func portableMessage(_ message: AIConversationMessage) -> JSONValue {
        var copy = message
        copy.unknownFields = OpaqueJSONFields()
        return json(copy)
    }

    static func portableBookTombstone(_ value: BookDeletion) -> JSONValue {
        .object(["bookID": .string(value.bookID.uuidString.uppercased()), "deletedAt": .number(Decimal(value.deletedAt.timeIntervalSinceReferenceDate))])
    }

    static func portableConversationTombstone(_ value: AIConversationDeletion) -> JSONValue {
        .object(["conversationID": .string(value.conversationID.uuidString.uppercased()), "deletedAt": .number(Decimal(value.deletedAt.timeIntervalSinceReferenceDate))])
    }
}

public extension RemoteLibraryManifest {
    /// Root-level forward-compatible fields, exposed for app-private persistence only.
    var rootUnknownFields: [String: JSONValue] { unknownFields.values }

    /// Merges persisted root-level unknown fields using JCS whole-value selection.
    func mergingRootUnknownFields(_ fields: [String: JSONValue]) -> (manifest: RemoteLibraryManifest, recoveryCandidates: [SyncRecoveryCandidate]) {
        var copy = self
        var recovery: [SyncRecoveryCandidate] = []
        copy.unknownFields = SyncMergePolicy.mergedOpaque([("opaque", "manifest", unknownFields), ("opaque", "manifest", OpaqueJSONFields(values: fields))], recovery: &recovery)
        let unique = Dictionary(grouping: recovery, by: { JCSCanonicalJSON.string(SyncMergePolicy.json($0)) }).values.compactMap(\.first)
        return (copy, unique.sorted { JCSCanonicalJSON.bytes(SyncMergePolicy.json($0)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(SyncMergePolicy.json($1))) })
    }

    func merging(_ other: RemoteLibraryManifest) -> RemoteManifestMergeResult {
        var result = RemoteLibraryManifest(); result.schemaVersion = 1
        var recovery: [SyncRecoveryCandidate] = []
        result.updatedAt = updatedAt.timeIntervalSinceReferenceDate >= other.updatedAt.timeIntervalSinceReferenceDate ? updatedAt : other.updatedAt
        let books = books + other.books
        var mergedBooks: [SyncedBook] = []
        let bookGroups = Dictionary(grouping: books, by: { $0.book.id })
        for id in bookGroups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            let values = bookGroups[id] ?? []
            guard let newest = values.map({ $0.book.modifiedAt.timeIntervalSinceReferenceDate }).max() else { continue }
            let tied = values.filter { $0.book.modifiedAt.timeIntervalSinceReferenceDate == newest }
            func bookTie(_ value: SyncedBook) -> JSONValue { .object(["book": SyncMergePolicy.portableBook(value.book), "sha256": .string(value.sha256)]) }
            let winner = tied.min { JCSCanonicalJSON.bytes(bookTie($0)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(bookTie($1))) }!
            let unique = Dictionary(grouping: values, by: { JCSCanonicalJSON.string(SyncMergePolicy.json($0)) }).values.compactMap(\.first)
            if unique.count > 1 { for v in unique { recovery.append(.init(kind:"book", entityID:id.uuidString.uppercased(), value:SyncMergePolicy.json(v))) } }
            var chosen = winner
            chosen.unknownFields = SyncMergePolicy.mergedOpaque(values.map { ("opaque",id.uuidString.uppercased(),$0.unknownFields) }, recovery: &recovery)
            chosen.book.unknownFields = SyncMergePolicy.mergedOpaque(values.map { ("opaque",id.uuidString.uppercased(),$0.book.unknownFields) }, recovery: &recovery)
            mergedBooks.append(chosen)
        }
        result.books = mergedBooks
        let allBookTombstones = deletions + other.deletions
        result.deletions = Dictionary(grouping: allBookTombstones, by: \.bookID).keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let group = allBookTombstones.filter { $0.bookID == id }
            guard let newest = group.map({ $0.deletedAt.timeIntervalSinceReferenceDate }).max() else { return nil }
            let tied = group.filter { $0.deletedAt.timeIntervalSinceReferenceDate == newest }
            var chosen = tied.min { JCSCanonicalJSON.bytes(SyncMergePolicy.portableBookTombstone($0)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(SyncMergePolicy.portableBookTombstone($1))) }!
            chosen.unknownFields = SyncMergePolicy.mergedOpaque(group.map { ("opaque", id.uuidString.uppercased(), $0.unknownFields) }, recovery: &recovery)
            return chosen
        }
        let allChatTombstones = conversationDeletions + other.conversationDeletions
        result.conversationDeletions = Dictionary(grouping: allChatTombstones, by: \.conversationID).keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let group = allChatTombstones.filter { $0.conversationID == id }
            guard let newest = group.map({ $0.deletedAt.timeIntervalSinceReferenceDate }).max() else { return nil }
            let tied = group.filter { $0.deletedAt.timeIntervalSinceReferenceDate == newest }
            var chosen = tied.min { JCSCanonicalJSON.bytes(SyncMergePolicy.portableConversationTombstone($0)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(SyncMergePolicy.portableConversationTombstone($1))) }!
            chosen.unknownFields = SyncMergePolicy.mergedOpaque(group.map { ("opaque", id.uuidString.uppercased(), $0.unknownFields) }, recovery: &recovery)
            return chosen
        }
        let allChats = conversations + other.conversations
        result.conversations = Dictionary(grouping: allChats, by:\.id).keys.sorted { $0.uuidString < $1.uuidString }.compactMap { id in
            let c = allChats.filter{$0.id == id}; guard !c.isEmpty else{return nil}
            let base = c.min { a,b in
                if a.modifiedAt != b.modifiedAt { return a.modifiedAt > b.modifiedAt }
                var x=a,y=b; x.messages=[]; y.messages=[]
                return JCSCanonicalJSON.bytes(SyncMergePolicy.portableConversationMetadata(x)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(SyncMergePolicy.portableConversationMetadata(y)))
            }!
            var merged=base
            let messages=c.flatMap(\.messages)
            merged.messages=Dictionary(grouping:messages,by:\.id).keys.sorted { $0.uuidString < $1.uuidString }.compactMap { mid in
                let m=messages.filter{$0.id == mid}; let distinct=Dictionary(grouping:m,by:{JCSCanonicalJSON.string(SyncMergePolicy.portableMessage($0))}).values.compactMap(\.first)
                if distinct.count > 1 { for x in distinct { recovery.append(.init(kind:"message",entityID:id.uuidString.uppercased(),value:SyncMergePolicy.json(x))) } }
                guard var winner = distinct.min(by: { JCSCanonicalJSON.bytes(SyncMergePolicy.portableMessage($0)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(SyncMergePolicy.portableMessage($1))) }) else { return nil }
                winner.unknownFields = SyncMergePolicy.mergedOpaque(m.map { ("opaque", mid.uuidString.uppercased(), $0.unknownFields) }, recovery: &recovery)
                return winner
            }.sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString.uppercased() < $1.id.uuidString.uppercased() : $0.createdAt < $1.createdAt }
            merged.createdAt=c.map(\.createdAt).min()!; merged.modifiedAt=c.map(\.modifiedAt).max()!
            merged.unknownFields=SyncMergePolicy.mergedOpaque(c.map { ("opaque",id.uuidString.uppercased(),$0.unknownFields) }, recovery:&recovery)
            return merged
        }
        result.unknownFields=SyncMergePolicy.mergedOpaque([("opaque","manifest",unknownFields),("opaque","manifest",other.unknownFields)],recovery:&recovery)
        let filteredBooks=result.books.filter { book in !(result.deletions.first{$0.bookID == book.book.id}.map{$0.deletedAt >= book.book.modifiedAt} ?? false) }
        result.books=filteredBooks
        result.conversations=result.conversations.filter { c in !(result.conversationDeletions.first{$0.conversationID == c.id}.map{$0.deletedAt >= c.modifiedAt} ?? false) }
        let normalized = Dictionary(grouping: recovery, by:{ JCSCanonicalJSON.string(SyncMergePolicy.json($0)) }).values.compactMap(\.first).sorted { JCSCanonicalJSON.bytes(SyncMergePolicy.json($0)).lexicographicallyPrecedes(JCSCanonicalJSON.bytes(SyncMergePolicy.json($1))) }
        return .init(manifest:result,recoveryCandidates:normalized)
    }
}
