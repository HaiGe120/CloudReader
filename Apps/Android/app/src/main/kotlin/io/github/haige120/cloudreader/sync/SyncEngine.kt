package io.github.haige120.cloudreader.sync

import android.content.Context
import android.net.Uri
import io.github.haige120.cloudreader.data.CloudReaderPreferences
import io.github.haige120.cloudreader.data.ConversationRow
import io.github.haige120.cloudreader.data.LibraryDao
import io.github.haige120.cloudreader.data.LibraryRepository
import io.github.haige120.cloudreader.data.SecureVault
import io.github.haige120.cloudreader.data.toDomain
import io.github.haige120.cloudreader.data.toRow
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.ConversationJsonAdapter
import io.github.haige120.cloudreader.domain.canonicalUUID
import io.github.haige120.cloudreader.domain.nowFoundationSeconds
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

data class DestinationOutcome(val books: Int, val conversations: Int, val error: String? = null)
data class SyncOutcome(val successful: List<String>, val failed: Map<String, String>, val books: Int, val conversations: Int,
    val destinations: Map<String, DestinationOutcome> = emptyMap())

enum class SyncTrigger { MANUAL, LOCAL_CHANGE, FOREGROUND, PROVIDER_SELECTION }

/** Shares overlapping trigger requests; cancellation of the executing request reaches the pass. */
internal class SyncRequestCoordinator(private val action: suspend (SyncTrigger) -> SyncOutcome) {
    private val guard = Any()
    private var active: kotlinx.coroutines.CompletableDeferred<SyncOutcome>? = null
    private var pendingTrigger: SyncTrigger? = null

    suspend fun request(trigger: SyncTrigger): SyncOutcome {
        val current: kotlinx.coroutines.CompletableDeferred<SyncOutcome>?
        val shared: kotlinx.coroutines.CompletableDeferred<SyncOutcome>
        synchronized(guard) {
            current = active?.takeIf { it.isActive }
            if (current != null && trigger.requiresFollowUp()) pendingTrigger = trigger
            if (current == null) {
                shared = kotlinx.coroutines.CompletableDeferred()
                active = shared
            } else shared = current
        }
        if (current != null) return current.await()
        try {
            var next = trigger
            var value: SyncOutcome
            while (true) {
                value = action(next)
                synchronized(guard) {
                    val pending = pendingTrigger
                    if (pending == null) {
                        shared.complete(value)
                        if (active === shared) active = null
                        return value
                    }
                    pendingTrigger = null
                    next = pending
                }
            }
        } catch (error: Throwable) {
            shared.completeExceptionally(error)
            throw error
        } finally {
            synchronized(guard) { if (active === shared) active = null; pendingTrigger = null }
        }
    }

    private fun SyncTrigger.requiresFollowUp(): Boolean =
        this == SyncTrigger.PROVIDER_SELECTION || this == SyncTrigger.LOCAL_CHANGE
}

internal suspend fun runSelectedDestinations(
    selected: List<String>,
    pass: suspend (String) -> Pair<Int, Int>,
): SyncOutcome {
    val destinations = selected.distinct().sorted()
    if (destinations.isEmpty()) return SyncOutcome(emptyList(), emptyMap(), 0, 0)
    val failed = linkedMapOf<String, String>()
    val outcomes = linkedMapOf<String, DestinationOutcome>()
    var bookCount = 0
    var chatCount = 0
    repeat(if (destinations.size > 1) 2 else 1) {
        for (provider in destinations) {
            try {
                val counts = pass(provider)
                bookCount = counts.first
                chatCount = counts.second
                failed.remove(provider)
                outcomes[provider] = DestinationOutcome(counts.first, counts.second)
            } catch (error: kotlinx.coroutines.CancellationException) {
                throw error
            } catch (error: Exception) {
                failed[provider] = error.localizedMessage ?: "Sync failed."
                outcomes[provider] = DestinationOutcome(0, 0, failed[provider])
            }
        }
    }
    return SyncOutcome(destinations.filterNot(failed::containsKey), failed, bookCount, chatCount, outcomes)
}

internal suspend fun <T> withRemoteStore(store: RemoteBookStore, action: suspend (RemoteBookStore) -> T): T =
    try { action(store) }
    finally { withContext(kotlinx.coroutines.NonCancellable) { store.close() } }

class SyncEngine(
    private val context: Context,
    private val dao: LibraryDao,
    private val library: LibraryRepository,
    private val preferences: CloudReaderPreferences,
    private val vault: SecureVault,
    private val storeFactory: (suspend (String) -> RemoteBookStore)? = null,
    private val clock: () -> Double = ::nowFoundationSeconds,
    private val googleToken: suspend () -> String? = { null },
) {
    private val syncMutex = Mutex()
    private val coordinator = SyncRequestCoordinator { _ -> performSync() }

    suspend fun request(trigger: SyncTrigger = SyncTrigger.MANUAL): SyncOutcome = coordinator.request(trigger)

    @Deprecated("Use request(trigger) so all trigger sources share the coordinator")
    suspend fun sync(): SyncOutcome = request(SyncTrigger.MANUAL)

    private suspend fun performSync(): SyncOutcome = withContext(Dispatchers.IO) {
        syncMutex.withLock {
            val destinations = preferences.selectedProviders.first().toList().sorted()
            runSelectedDestinations(destinations) { provider ->
                val store = (storeFactory ?: ::makeStore).invoke(provider)
                withRemoteStore(store, ::syncOnce)
            }
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
        var remote = remoteBytes?.let(SyncCodec::manifestFromJson) ?: SyncManifest(updatedAt = clock())
        val recovery = SyncRecoveryStore(java.io.File(context.filesDir, "CloudReader/sync-recovery-v1.json"))
        val (rootUnknown, rootConflicts) = SyncOpaqueManifestStore(
            java.io.File(context.filesDir, "CloudReader/sync-opaque-v1.json"),
        ).merge(remote.unknown)
        recovery.append(rootConflicts)
        remote = remote.copy(unknown = rootUnknown)

        for (deletion in remote.deletions) library.applyDeletion(deletion)
        remote.conversationDeletions.forEach { deletion ->
            val current = dao.allConversations().firstOrNull { it.id == canonicalUUID(deletion.conversationID) }
            val mergedDeletion = dao.conversationDeletions().firstOrNull { it.conversationID == deletion.conversationID }
            if (current != null && !MergePolicy.survives(current.modifiedAt, deletion.deletedAt)) dao.removeConversation(current.id)
            if (mergedDeletion == null || mergedDeletion.deletedAt < deletion.deletedAt) dao.putConversationDeletion(deletion.toRow())
        }

        val localChats = dao.allConversations().associate { it.id to ConversationJsonAdapter.decode(it.wireJson) }.toMutableMap()
        for (incoming in remote.conversations) {
            val id = canonicalUUID(incoming.id)
            val tombstone = dao.conversationDeletions().firstOrNull { it.conversationID == id }
            if (!MergePolicy.survives(incoming.modifiedAt, tombstone?.deletedAt)) continue
            val old = localChats[id]
            if (old != null) recovery.append(MergePolicy.chatCollisionRecovery(old, incoming))
            val merged = old?.let { SyncCodec.mergeChats(it, incoming) } ?: incoming
            localChats[id] = merged
            dao.putConversation(ConversationRow(merged.id, ConversationJsonAdapter.encode(merged).toString(), merged.modifiedAt))
            dao.clearConversationDeletion(id)
        }

        val groupedRemote = remote.books.groupBy { canonicalUUID(it.book.id) }
        val remoteByID = linkedMapOf<String, SyncedBook>()
        groupedRemote.forEach { (id, entries) ->
            val result = MergePolicy.mergeBooks(entries.map { MergePolicy.BookCandidate(it.book, it.sha256, it.unknown) })
            recovery.append(result.recovery)
            result.primary?.let { remoteByID[id] = SyncedBook(it.book, it.sha256, it.entryUnknown) }
        }
        val remoteContent = mutableMapOf<String, ByteArray>()
        for ((id, item) in remoteByID) {
            val local = dao.book(id)
            val localDomain = local?.toDomain()
            val localFile = localDomain?.let(library::fileFor)
            val localHash = localFile?.takeIf { it.isFile }?.let { SyncEngine.sha256(it.readBytes()) }
            val selected = if (localDomain != null && localHash != null) {
                val merged = MergePolicy.mergeBooks(listOf(
                    // Local managed filenames differ per device; normalize them to the wire candidate before tie-breaking.
                    MergePolicy.BookCandidate(localDomain.copy(fileName = item.book.fileName), localHash),
                    MergePolicy.BookCandidate(item.book, item.sha256, item.unknown),
                ))
                recovery.append(merged.recovery)
                merged.primary
            } else MergePolicy.BookCandidate(item.book, item.sha256, item.unknown)
            val selectedMetadataDiffers = selected != null && localDomain != null &&
                MergePolicy.portableBookMetadata(selected.book) != MergePolicy.portableBookMetadata(localDomain)
            val selectedNeedsApply = selected != null && (
                localDomain == null || selected.book.modifiedAt > localDomain.modifiedAt ||
                    MergePolicy.equalTimeBookCandidateDiffers(localDomain, selected, localHash)
                )
            if (selectedNeedsApply) {
                val candidate = requireNotNull(selected)
                val deletion = dao.bookDeletions().firstOrNull { it.bookID == id }
                if (!MergePolicy.survives(candidate.book.modifiedAt, deletion?.deletedAt)) continue
                require(candidate.sha256.matches(Regex("[0-9a-f]{64}"))) { "${candidate.book.title} has an invalid SHA-256 value in the destination index." }
                val equalTimeSelection = localDomain?.modifiedAt == candidate.book.modifiedAt
                val metadataOnly = equalTimeSelection && localHash == candidate.sha256 && selectedMetadataDiffers
                val data = if (metadataOnly) localFile.readBytes() else store.read(SyncCodec.bookObjectName(candidate.book))
                    ?: throw IllegalStateException("${candidate.book.title} is listed in the sync index but its book file is missing.")
                require(sha256(data).equals(candidate.sha256, ignoreCase = true)) { "${candidate.book.title} failed its SHA-256 check." }
                // installSyncedBook checks the latest durable row again after the remote read suspension.
                val installed = if (metadataOnly) {
                    library.updateSyncedBookMetadata(candidate.book, requireNotNull(localDomain))
                } else library.installSyncedBook(
                    candidate.book, data, expectedCurrent = if (equalTimeSelection) localDomain else null,
                    allowEqualTimeReplacement = equalTimeSelection,
                )
                val latest = dao.book(id)?.toDomain()
                val latestBytes = latest?.let(library::fileFor)?.takeIf { it.isFile }?.readBytes()
                val latestHash = latestBytes?.let(::sha256)
                if (installed || (latest?.modifiedAt == candidate.book.modifiedAt && latestHash == candidate.sha256 &&
                        MergePolicy.portableBookMetadata(latest) == MergePolicy.portableBookMetadata(candidate.book))) {
                    remoteContent[id] = if (installed) data else requireNotNull(latestBytes)
                } else if (latest?.modifiedAt == candidate.book.modifiedAt &&
                    (latestHash != candidate.sha256 || MergePolicy.portableBookMetadata(latest) != MergePolicy.portableBookMetadata(candidate.book))) {
                    throw IllegalStateException("${candidate.book.title} changed locally during equal-time sync. The candidate was saved for local recovery.")
                }
            }
        }

        val localSnapshot = library.snapshot()
        val localByID = localSnapshot.books.associateBy { canonicalUUID(it.id) }
        val mergedRecords = linkedMapOf<String, BookRecord>()
        remoteByID.forEach { (id, item) -> mergedRecords[id] = item.book }
        localByID.forEach { (id, book) ->
            val existing = mergedRecords[id]
            if (existing == null || book.modifiedAt > existing.modifiedAt) mergedRecords[id] = book
            else if (book.modifiedAt == existing.modifiedAt) {
                val localFile = library.fileFor(book)
                val localHash = localFile?.takeIf { it.isFile }?.let { sha256(it.readBytes()) }
                val remote = remoteByID[id]
                if (localHash != null && remote != null) {
                    val result = MergePolicy.mergeBooks(listOf(
                        MergePolicy.BookCandidate(book.copy(fileName = remote.book.fileName), localHash),
                        MergePolicy.BookCandidate(existing, remote.sha256, remote.unknown),
                    ))
                    recovery.append(result.recovery)
                    result.primary?.let { mergedRecords[id] = it.book }
                } else if (MergePolicy.canonical(SyncCodec.bookToJson(book)) < MergePolicy.canonical(SyncCodec.bookToJson(existing))) mergedRecords[id] = book
            }
        }

        val (tombstones, bookTombstoneRecovery) = MergePolicy.mergeBookTombstones(remote.deletions + localSnapshot.bookDeletions)
        recovery.append(bookTombstoneRecovery)
        val deletionByID = tombstones.associateBy { it.bookID }
        val outBooks = mutableListOf<SyncedBook>()
        for ((id, book) in mergedRecords) {
            if (deletionByID[id]?.deletedAt?.let { it >= book.modifiedAt } == true) continue
            val local = localByID[id]
            val content = if (local != null && local.modifiedAt > (remoteByID[id]?.book?.modifiedAt ?: Double.NEGATIVE_INFINITY)) {
                library.fileFor(local)?.readBytes()
            } else if (local != null && local.modifiedAt == remoteByID[id]?.book?.modifiedAt) {
                val localBytes = library.fileFor(local)?.readBytes()
                val localHash = localBytes?.let(::sha256)
                if (localHash == remoteByID[id]?.sha256) localBytes else remoteContent[id] ?: store.read(SyncCodec.bookObjectName(book))
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

        val (chatTombstones, chatTombstoneRecovery) = MergePolicy.mergeConversationTombstones(
            remote.conversationDeletions + dao.conversationDeletions().map { it.toDomain() },
        )
        recovery.append(chatTombstoneRecovery)
        val chatDeletionByID = chatTombstones.associateBy { it.conversationID }
        val outChats = dao.allConversations().map { ConversationJsonAdapter.decode(it.wireJson) }.filter { chat ->
            chatDeletionByID[canonicalUUID(chat.id)]?.deletedAt?.let { it >= chat.modifiedAt } != true
        }

        val manifest = remote.copy(
            schemaVersion = 1, updatedAt = clock(), books = outBooks,
            deletions = tombstones, conversations = outChats, conversationDeletions = chatTombstones,
        )
        store.write("manifest.json", SyncCodec.manifestToJson(manifest).toString().toByteArray(Charsets.UTF_8))
        return outBooks.size to outChats.size
    }

    companion object {
        fun sha256(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
    }
}
