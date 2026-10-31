package io.github.haige120.cloudreader.core.application

import io.github.haige120.cloudreader.core.contract.*
import io.github.haige120.cloudreader.core.merge.MergePolicy
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** Reuses the v1 tie-breaking policy. Unconditional provider writes still require sequential device sync. */
object ManifestMerger {
    data class Result(val manifest: SyncManifest, val recovery: List<JsonObject>)
    fun merge(a: SyncManifest, b: SyncManifest): Result {
        val recovery = mutableListOf<JsonObject>()
        val (deletions, bookRecovery) = MergePolicy.mergeBookTombstones(a.deletions + b.deletions)
        val (chatDeletions, chatRecovery) = MergePolicy.mergeConversationTombstones(a.conversationDeletions + b.conversationDeletions)
        recovery += bookRecovery; recovery += chatRecovery
        val books = (a.books + b.books).groupBy { it.book.id.uppercase() }.toSortedMap().mapNotNull { (id, values) ->
            val result = MergePolicy.mergeBooks(values.map { MergePolicy.BookCandidate(it.book, it.sha256, it.unknown) })
            recovery += result.recovery
            result.primary?.takeIf { primary -> deletions.none { it.bookID == id && it.deletedAt >= primary.book.modifiedAt } }
                ?.let { SyncedBook(it.book, it.sha256, it.entryUnknown) }
        }
        val chats = (a.conversations + b.conversations).groupBy { it.id.uppercase() }.toSortedMap().mapNotNull { (id, values) ->
            val chat = values.reduce(MergePolicy::mergeChats)
            chat.takeIf { chatDeletions.none { deletion -> deletion.conversationID == id && deletion.deletedAt >= chat.modifiedAt } }
        }
        val (unknown, conflicts) = MergePolicy.mergeOpaqueJson(a.unknown.toString(), b.unknown.toString())
        recovery += conflicts
        return Result(SyncManifest(updatedAt = maxOf(a.updatedAt, b.updatedAt), books = books, deletions = deletions,
            conversations = chats, conversationDeletions = chatDeletions, unknown = unknown), recovery)
    }
}
