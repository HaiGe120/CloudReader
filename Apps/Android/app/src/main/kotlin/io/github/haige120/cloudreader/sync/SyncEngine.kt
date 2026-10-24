package io.github.haige120.cloudreader.sync

import android.content.Context
import android.net.Uri
import io.github.haige120.cloudreader.data.CloudReaderPreferences
import io.github.haige120.cloudreader.data.ConversationRow
import io.github.haige120.cloudreader.data.LibraryDao
import io.github.haige120.cloudreader.data.LibraryRepository
import io.github.haige120.cloudreader.data.SecureVault
import io.github.haige120.cloudreader.core.contract.SyncCodec as SharedSyncCodec
import io.github.haige120.cloudreader.data.canonicalUUID
import io.github.haige120.cloudreader.data.nowFoundationSeconds
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.contentOrNull
import okhttp3.OkHttpClient

data class SyncOutcome(val successful: List<String>, val failed: Map<String, String>, val books: Int, val conversations: Int)

class SyncEngine(
    private val context: Context,
    private val dao: LibraryDao,
    private val library: LibraryRepository,
    private val preferences: CloudReaderPreferences,
    private val vault: SecureVault,
    private val googleToken: suspend () -> String? = { null },
) {
    private val syncMutex = Mutex()

    suspend fun sync(): SyncOutcome = withContext(Dispatchers.IO) {
        syncMutex.withLock {
            val destinations = preferences.selectedProviders.first().toList().sorted()
            if (destinations.isEmpty()) return@withLock SyncOutcome(emptyList(), emptyMap(), 0, 0)
            val failed = linkedMapOf<String, String>()
            var bookCount = 0
            var chatCount = 0
            val passes = if (destinations.size > 1) 2 else 1
            repeat(passes) {
                for (provider in destinations) {
                    try {
                        val store = makeStore(provider)
                        val counts = syncOnce(store)
                        bookCount = counts.first; chatCount = counts.second
                        failed.remove(provider)
                    } catch (error: Exception) {
                        failed[provider] = error.localizedMessage ?: "Sync failed."
                    }
                }
            }
            SyncOutcome(destinations.filterNot(failed::containsKey), failed, bookCount, chatCount)
        }
    }

    private suspend fun makeStore(provider: String): RemoteBookStore = when (provider) {
        "filesFolder" -> FolderStore(context, Uri.parse(preferences.cachedFolderUri() ?: error("Choose a folder in Settings.")))
        "webDAV" -> WebDavStore(preferences, vault)
        "sftp" -> SftpStore(context, vault)
        "dropbox" -> DropboxStore(vault, preferences)
        "pCloud" -> PCloudStore(vault)
        "googleDrive" -> {
            googleToken() ?: error("Reconnect Google Drive in Settings.")
            GoogleDriveStore(vault)
        }
        else -> error("Unknown sync destination: $provider")
    }

    private suspend fun CloudReaderPreferences.cachedFolderUri(): String? = get("folder.treeUri")

    private suspend fun syncOnce(store: RemoteBookStore): Pair<Int, Int> {
        val remoteBytes = store.read("manifest.json")
        // Run the shared JVM contract preflight before the Android adapter
        // applies its Room/local-file merge. This keeps wire safety rules in
        // one implementation while preserving the Android storage boundary.
        remoteBytes?.let { SharedSyncCodec.manifestFromJson(it) }
        val remote = remoteBytes?.let(SyncCodec::manifestFromJson) ?: SyncManifest(updatedAt = nowFoundationSeconds())

        for (deletion in remote.deletions) library.applyDeletion(deletion)
        remote.conversationDeletions.forEach { deletion ->
            val current = dao.allConversations().firstOrNull { it.id == canonicalUUID(deletion.conversationID) }
            val mergedDeletion = dao.conversationDeletions().firstOrNull { it.conversationID == deletion.conversationID }
            if (current != null && current.modifiedAt <= deletion.deletedAt) dao.removeConversation(current.id)
            if (mergedDeletion == null || mergedDeletion.deletedAt < deletion.deletedAt) dao.putConversationDeletion(deletion)
        }

        val localChats = dao.allConversations().associate { it.id to SyncCodec.chatFromJson(it.wireJson) }.toMutableMap()
        for (incoming in remote.conversations) {
            val id = canonicalUUID(incoming.id)
            val tombstone = dao.conversationDeletions().firstOrNull { it.conversationID == id }
            if (tombstone != null && tombstone.deletedAt >= incoming.modifiedAt) continue
            val merged = localChats[id]?.let { SyncCodec.mergeChats(it, incoming) } ?: incoming
            localChats[id] = merged
            dao.putConversation(merged.row())
            dao.clearConversationDeletion(id)
        }

        val remoteByID = remote.books.associateBy { canonicalUUID(it.book.id) }
        val remoteContent = mutableMapOf<String, ByteArray>()
        for (item in remote.books) {
            val id = canonicalUUID(item.book.id)
            val local = dao.book(id)
            if (local == null || item.book.modifiedAt > local.modifiedAt) {
                val deletion = dao.bookDeletions().firstOrNull { it.bookID == id }
                if (deletion != null && deletion.deletedAt >= item.book.modifiedAt) continue
                require(item.sha256.matches(Regex("[0-9a-f]{64}"))) { "${item.book.title} has an invalid SHA-256 value in the destination index." }
                val data = store.read(SyncCodec.bookObjectName(item.book))
                    ?: throw IllegalStateException("${item.book.title} is listed in the sync index but its book file is missing.")
                require(sha256(data).equals(item.sha256, ignoreCase = true)) { "${item.book.title} failed its SHA-256 check." }
                library.installSyncedBook(item.book, data)
                remoteContent[id] = data
            }
        }

        val localSnapshot = dao.snapshot()
        val localByID = localSnapshot.books.associateBy { canonicalUUID(it.id) }
        val mergedRecords = linkedMapOf<String, io.github.haige120.cloudreader.data.BookRow>()
        remote.books.forEach { item -> mergedRecords[canonicalUUID(item.book.id)] = item.book }
        localByID.forEach { (id, book) ->
            val existing = mergedRecords[id]
            if (existing == null || book.modifiedAt >= existing.modifiedAt) mergedRecords[id] = book
        }

        val tombstones = (remote.deletions + localSnapshot.bookDeletions)
            .groupBy { canonicalUUID(it.bookID) }.map { (id, values) -> values.maxBy { it.deletedAt }.copy(bookID = id) }
        val deletionByID = tombstones.associateBy { it.bookID }
        val outBooks = mutableListOf<SyncedBook>()
        for ((id, book) in mergedRecords) {
            if (deletionByID[id]?.deletedAt?.let { it >= book.modifiedAt } == true) continue
            val local = localByID[id]
            val content = if (local != null && local.modifiedAt >= (remoteByID[id]?.book?.modifiedAt ?: Double.NEGATIVE_INFINITY)) {
                library.fileFor(local)?.readBytes()
            } else remoteContent[id] ?: remoteByID[id]?.let { store.read(SyncCodec.bookObjectName(it.book)) }
            if (content == null) {
                throw IllegalStateException("${book.title} is in your library, but its local file is missing or unreadable. The destination index was left unchanged.")
            }
            val hash = sha256(content)
            if (remoteByID[id]?.sha256?.equals(hash, ignoreCase = true) != true) {
                store.write(SyncCodec.bookObjectName(book), content)
            }
            outBooks += SyncedBook(book, hash, remoteByID[id]?.unknown ?: kotlinx.serialization.json.JsonObject(emptyMap()))
        }

        val chatTombstones = (remote.conversationDeletions + dao.conversationDeletions())
            .groupBy { canonicalUUID(it.conversationID) }.map { (id, values) -> values.maxBy { it.deletedAt }.copy(conversationID = id) }
        val chatDeletionByID = chatTombstones.associateBy { it.conversationID }
        val outChats = dao.allConversations().map { SyncCodec.chatFromJson(it.wireJson) }.filter { chat ->
            chatDeletionByID[canonicalUUID(chat.id)]?.deletedAt?.let { it >= chat.modifiedAt } != true
        }

        val manifest = remote.copy(
            schemaVersion = 1, updatedAt = nowFoundationSeconds(), books = outBooks,
            deletions = tombstones, conversations = outChats, conversationDeletions = chatTombstones,
        )
        store.write("manifest.json", SyncCodec.manifestToJson(manifest).toString().toByteArray(Charsets.UTF_8))
        return outBooks.size to outChats.size
    }

    companion object {
        fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
