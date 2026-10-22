package io.github.haige120.cloudreader.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import io.github.haige120.cloudreader.domain.BookFormat
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.BookTombstone
import io.github.haige120.cloudreader.domain.ChatRecord
import io.github.haige120.cloudreader.domain.ConversationJsonAdapter
import io.github.haige120.cloudreader.domain.ConversationTombstone
import io.github.haige120.cloudreader.domain.DemoBook
import io.github.haige120.cloudreader.domain.LibrarySnapshot
import io.github.haige120.cloudreader.domain.canonicalUUID
import io.github.haige120.cloudreader.domain.nowFoundationSeconds
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext

class LibraryRepository internal constructor(
    context: Context,
    private val dao: LibraryDao,
    booksDirectory: File?,
    private val fileOps: RepositoryFileOps,
) {
    constructor(context: Context, dao: LibraryDao, booksDirectory: File? = null) : this(
        context, dao, booksDirectory, RepositoryFileOps(),
    )

    private val appContext = context.applicationContext
    private val booksDir = (booksDirectory ?: File(appContext.filesDir, "CloudReader/Books")).apply { mkdirs() }

    val books: Flow<List<BookRecord>> = dao.observeBooks().map { rows -> rows.map(BookRow::toDomain) }
    val conversations: Flow<List<ChatRecord>> = dao.observeConversations().map { rows ->
        rows.mapNotNull { row -> runCatching { ConversationJsonAdapter.decode(row.wireJson) }.getOrNull() }
    }

    suspend fun snapshot(): LibrarySnapshot = dao.snapshot().let { stored ->
        LibrarySnapshot(
            books = stored.books.map(BookRow::toDomain),
            bookDeletions = stored.bookDeletions.map(BookTombstoneRow::toDomain),
            conversations = stored.conversations.map { ConversationJsonAdapter.decode(it.wireJson) },
            conversationDeletions = stored.conversationDeletions.map(ConversationTombstoneRow::toDomain),
        )
    }

    fun fileFor(book: BookRecord): File? {
        if (!book.fileName.matches(Regex("[A-Za-z0-9._-]{1,160}")) || book.fileName.contains("..")) return null
        return File(booksDir, book.fileName).takeIf { it.canonicalFile.parentFile == booksDir.canonicalFile && it.isFile }
    }

    suspend fun importUris(uris: List<Uri>): Pair<Int, Int> = withContext(Dispatchers.IO) {
        var imported = 0
        var rejected = 0
        for (uri in uris) {
            var copiedFile: File? = null
            var committingID: String? = null
            try {
                val importContext = currentCoroutineContext()
                importContext.ensureActive()
                val displayName = appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) cursor.getString(0) else null
                } ?: uri.lastPathSegment?.substringAfterLast('/')
                val format = BookFormat.fromExtension(displayName?.substringAfterLast('.', "") ?: "")
                if (format == null) { rejected++; continue }
                val id = UUID.randomUUID().toString().uppercase(Locale.ROOT)
                val fileName = "$id.${format.extension}"
                val target = File(booksDir, fileName).also { copiedFile = it }
                appContext.contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            importContext.ensureActive()
                            val read = input.read(buffer)
                            if (read < 0) break
                            importContext.ensureActive()
                            output.write(buffer, 0, read)
                        }
                    }
                }
                    ?: throw IllegalStateException("The selected file is unavailable.")
                importContext.ensureActive()
                val sourceName = displayName?.substringBeforeLast('.')?.takeIf { it.isNotBlank() } ?: "Untitled"
                val title = sourceName.replace('_', ' ').replace('-', ' ')
                val now = nowFoundationSeconds()
                committingID = id
                dao.putBook(BookRecord(id, title, fileName = fileName, format = format.extension, addedAt = now, modifiedAt = now).toRow())
                committingID = null
                imported++
            } catch (cancelled: CancellationException) {
                withContext(NonCancellable) {
                    committingID?.let { dao.removeBook(it) }
                    copiedFile?.delete()
                }
                throw cancelled
            } catch (_: Exception) {
                copiedFile?.delete()
                rejected++
            }
        }
        imported to rejected
    }

    suspend fun seedDemoBook() = withContext(Dispatchers.IO) {
        if (dao.book(DemoBook.ID) != null || dao.bookDeletion(DemoBook.ID) != null) return@withContext
        val fileName = "demo-cloudreader-field-guide.txt"
        val out = File(booksDir, fileName)
        val createdHere = !out.exists()
        if (createdHere) appContext.assets.open("CloudReader_Field_Guide.txt").use { input -> out.outputStream().use(input::copyTo) }
        val seeded = dao.seedBookUnlessDeleted(
            BookRecord(DemoBook.ID, DemoBook.TITLE, DemoBook.AUTHOR, DemoBook.DESCRIPTION, fileName, "txt", DemoBook.ADDED_AT, modifiedAt = DemoBook.ADDED_AT).toRow(),
        )
        if (!seeded && createdHere) fileOps.delete(out)
    }

    suspend fun opened(book: BookRecord) {
        val now = nowFoundationSeconds()
        dao.updateOpened(book.id, now)
    }

    suspend fun progress(book: BookRecord, fraction: Double, localLocation: String? = book.localLocation) {
        val normalized = fraction.coerceIn(0.0, 1.0)
        dao.setProgressIfNeeded(book.id, normalized, localLocation, nowFoundationSeconds())
    }

    suspend fun bookmark(book: BookRecord) {
        dao.toggleBookmark(book.id, nowFoundationSeconds())
    }

    suspend fun remove(book: BookRecord) {
        val removed = dao.deleteBookWithTombstone(book.id, nowFoundationSeconds())
        val file = removed?.toDomain()?.let(::fileFor) ?: managedFileFor(book.fileName)
        if (file != null && file.exists() && !fileOps.delete(file)) {
            throw IOException("The book was removed from the library, but its file could not be deleted.")
        }
    }

    suspend fun saveChat(chat: ChatRecord) {
        val old = dao.allConversations().firstOrNull { it.id == chat.id }?.let { ConversationJsonAdapter.decode(it.wireJson) }
        val normalized = chat.copy(
            title = chat.messages.firstOrNull { it.role == "user" }?.text?.replace('\n', ' ')?.take(64) ?: chat.title,
            createdAt = old?.createdAt ?: chat.createdAt,
            modifiedAt = nowFoundationSeconds(),
        )
        dao.clearConversationDeletion(chat.id)
        dao.putConversation(ConversationRow(normalized.id, ConversationJsonAdapter.encode(normalized).toString(), normalized.modifiedAt))
    }

    suspend fun removeChat(chat: ChatRecord) {
        dao.removeConversation(chat.id)
        dao.putConversationDeletion(ConversationTombstone(chat.id, nowFoundationSeconds()).toRow())
    }

    suspend fun installSyncedBook(
        book: BookRecord,
        bytes: ByteArray,
        expectedCurrent: BookRecord? = null,
        allowEqualTimeReplacement: Boolean = false,
    ): Boolean = withContext(Dispatchers.IO) {
        val format = BookFormat.fromExtension(book.format) ?: throw IllegalArgumentException("Unsupported book format")
        val safeID = canonicalUUID(book.id)
        val current = dao.book(safeID)?.toDomain()
        if (current != null && current.modifiedAt > book.modifiedAt) return@withContext false
        if (current != null && current.modifiedAt == book.modifiedAt && !allowEqualTimeReplacement) return@withContext false
        if (allowEqualTimeReplacement && (current == null || expectedCurrent == null || current != expectedCurrent || current.modifiedAt != book.modifiedAt)) return@withContext false
        val expectedRow = if (allowEqualTimeReplacement) dao.book(safeID) else null
        val tombstone = dao.bookDeletion(safeID)
        if (tombstone != null && tombstone.deletedAt >= book.modifiedAt) return@withContext false

        val name = "sync-$safeID-${UUID.randomUUID()}.${format.extension}"
        val stage = File(booksDir, ".$name.tmp")
        val target = File(booksDir, name)
        var databaseCommitted = false
        try {
            FileOutputStream(stage).use { output -> output.write(bytes); output.fd.sync() }
            if (!fileOps.rename(stage, target)) throw IOException("Could not commit the downloaded book file.")
            val updated = book.copy(id = safeID, fileName = name, localLocation = current?.localLocation).toRow()
            val committed = if (allowEqualTimeReplacement) {
                dao.installSyncedBookIfUnchanged(updated, requireNotNull(expectedRow), allowEqualTime = true)
            } else dao.installSyncedBookIfNewer(updated)
            if (!committed) {
                if (target.exists() && !fileOps.delete(target)) throw IOException("The stale downloaded file could not be cleaned up.")
                return@withContext false
            }
            databaseCommitted = true
            current?.let(::fileFor)?.let { old -> if (old.exists()) fileOps.delete(old) }
            true
        } catch (error: Throwable) {
            if (!databaseCommitted && target.exists() && !fileOps.delete(target)) {
                error.addSuppressed(IOException("The uncommitted downloaded file could not be removed."))
            }
            if (stage.exists() && !fileOps.delete(stage)) {
                error.addSuppressed(IOException("The staged downloaded file could not be removed."))
            }
            throw error
        }
    }

    /** Equal-time metadata-only update; exact row matching and the DAO transaction protect newer local edits. */
    suspend fun updateSyncedBookMetadata(book: BookRecord, expectedCurrent: BookRecord): Boolean = withContext(Dispatchers.IO) {
        val id = canonicalUUID(book.id)
        val expectedRow = dao.book(id) ?: return@withContext false
        if (expectedRow.toDomain() != expectedCurrent || expectedCurrent.modifiedAt != book.modifiedAt) return@withContext false
        val tombstone = dao.bookDeletion(id)
        if (tombstone != null && tombstone.deletedAt >= book.modifiedAt) return@withContext false
        dao.updateSyncedBookMetadataIfUnchanged(book.copy(
            id = id, fileName = expectedCurrent.fileName, localLocation = expectedCurrent.localLocation,
        ).toRow(), expectedRow)
    }

    suspend fun applyDeletion(tombstone: BookTombstone) {
        val id = canonicalUUID(tombstone.bookID)
        val removed = dao.applyBookTombstone(tombstone.copy(bookID = id).toRow())
        val file = removed?.toDomain()?.let(::fileFor)
        if (file != null && file.exists() && !fileOps.delete(file)) {
            throw IOException("The remote deletion was recorded, but the local book file could not be deleted.")
        }
    }

    private fun managedFileFor(name: String): File? {
        if (!name.matches(Regex("[A-Za-z0-9._-]{1,160}")) || name.contains("..")) return null
        return File(booksDir, name).takeIf { it.canonicalFile.parentFile == booksDir.canonicalFile }
    }
}

internal data class RepositoryFileOps(
    val rename: (File, File) -> Boolean = { source, target -> source.renameTo(target) },
    val delete: (File) -> Boolean = File::delete,
)
