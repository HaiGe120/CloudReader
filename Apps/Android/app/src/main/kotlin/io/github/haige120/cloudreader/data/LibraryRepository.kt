package io.github.haige120.cloudreader.data

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import io.github.haige120.cloudreader.sync.SyncCodec
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.withContext

class LibraryRepository(context: Context, private val dao: LibraryDao) {
    private val appContext = context.applicationContext
    private val booksDir = File(appContext.filesDir, "CloudReader/Books").apply { mkdirs() }

    val books: Flow<List<BookRow>> = dao.observeBooks()
    val conversations: Flow<List<ConversationRow>> = dao.observeConversations()

    fun fileFor(book: BookRow): File? {
        if (!book.fileName.matches(Regex("[A-Za-z0-9._-]{1,160}")) || book.fileName.contains("..")) return null
        return File(booksDir, book.fileName).takeIf { it.canonicalFile.parentFile == booksDir.canonicalFile && it.isFile }
    }

    suspend fun importUris(uris: List<Uri>): Pair<Int, Int> = withContext(Dispatchers.IO) {
        var imported = 0
        var rejected = 0
        for (uri in uris) {
            val displayName = appContext.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) cursor.getString(0) else null
            } ?: uri.lastPathSegment?.substringAfterLast('/')
            val format = BookFormat.fromExtension(displayName?.substringAfterLast('.', "") ?: "")
            if (format == null) { rejected++; continue }
            val id = UUID.randomUUID().toString().uppercase(Locale.ROOT)
            val fileName = "$id.${format.extension}"
            try {
                appContext.contentResolver.openInputStream(uri)?.use { input -> File(booksDir, fileName).outputStream().use(input::copyTo) }
                    ?: throw IllegalStateException("The selected file is unavailable.")
                val sourceName = displayName?.substringBeforeLast('.')?.takeIf { it.isNotBlank() } ?: "Untitled"
                val title = sourceName.replace('_', ' ').replace('-', ' ')
                val now = nowFoundationSeconds()
                dao.putBook(BookRow(id, title, fileName = fileName, format = format.extension, addedAt = now, modifiedAt = now))
                imported++
            } catch (_: Exception) {
                File(booksDir, fileName).delete()
                rejected++
            }
        }
        imported to rejected
    }

    suspend fun seedDemoBook() = withContext(Dispatchers.IO) {
        if (dao.book(DemoBook.ID) != null) return@withContext
        val fileName = "demo-cloudreader-field-guide.txt"
        val out = File(booksDir, fileName)
        if (!out.exists()) appContext.assets.open("CloudReader_Field_Guide.txt").use { input -> out.outputStream().use(input::copyTo) }
        dao.putBook(BookRow(DemoBook.ID, DemoBook.TITLE, DemoBook.AUTHOR, DemoBook.DESCRIPTION, fileName, "txt", DemoBook.ADDED_AT, modifiedAt = DemoBook.ADDED_AT))
    }

    suspend fun opened(book: BookRow) {
        val now = nowFoundationSeconds()
        dao.putBook(book.copy(lastOpenedAt = now, modifiedAt = now))
    }

    suspend fun progress(book: BookRow, fraction: Double, localLocation: String? = book.localLocation) {
        val normalized = fraction.coerceIn(0.0, 1.0)
        val current = dao.book(book.id) ?: book
        if (kotlin.math.abs(normalized - current.progress) < 0.01 && localLocation == current.localLocation) return
        dao.putBook(current.copy(progress = normalized, localLocation = localLocation, modifiedAt = nowFoundationSeconds()))
    }

    suspend fun bookmark(book: BookRow) {
        val current = dao.book(book.id) ?: book
        dao.putBook(current.copy(isBookmarked = !current.isBookmarked, modifiedAt = nowFoundationSeconds()))
    }

    suspend fun remove(book: BookRow) {
        fileFor(book)?.delete()
        dao.removeBook(book.id)
        dao.putBookDeletion(BookTombstone(book.id, nowFoundationSeconds()))
    }

    suspend fun saveChat(chat: ChatRecord) {
        val old = dao.allConversations().firstOrNull { it.id == chat.id }?.let { SyncCodec.chatFromJson(it.wireJson) }
        val normalized = chat.copy(
            title = chat.messages.firstOrNull { it.role == "user" }?.text?.replace('\n', ' ')?.take(64) ?: chat.title,
            createdAt = old?.createdAt ?: chat.createdAt,
            modifiedAt = nowFoundationSeconds(),
        )
        dao.clearConversationDeletion(chat.id)
        dao.putConversation(normalized.row())
    }

    suspend fun removeChat(chat: ChatRecord) {
        dao.removeConversation(chat.id)
        dao.putConversationDeletion(ConversationTombstone(chat.id, nowFoundationSeconds()))
    }

    suspend fun installSyncedBook(book: BookRow, bytes: ByteArray) = withContext(Dispatchers.IO) {
        val format = BookFormat.fromExtension(book.format) ?: throw IllegalArgumentException("Unsupported book format")
        val safeID = canonicalUUID(book.id)
        val name = "sync-$safeID.${format.extension}"
        File(booksDir, "$name.tmp").writeBytes(bytes)
        File(booksDir, "$name.tmp").renameTo(File(booksDir, name))
        dao.putBook(book.copy(id = safeID, fileName = name))
        dao.clearBookDeletion(safeID)
    }

    suspend fun applyDeletion(tombstone: BookTombstone) {
        val id = canonicalUUID(tombstone.bookID)
        val local = dao.book(id)
        if (local != null && local.modifiedAt <= tombstone.deletedAt) {
            fileFor(local)?.delete()
            dao.removeBook(id)
        }
        val previous = dao.bookDeletions().firstOrNull { it.bookID == id }
        if (previous == null || previous.deletedAt < tombstone.deletedAt) dao.putBookDeletion(tombstone.copy(bookID = id))
    }
}
