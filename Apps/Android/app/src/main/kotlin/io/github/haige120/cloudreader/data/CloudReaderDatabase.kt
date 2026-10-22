package io.github.haige120.cloudreader.data

import android.content.Context
import androidx.room.Dao
import androidx.room.Database
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.room.Transaction
import kotlinx.coroutines.flow.Flow

@Dao
interface LibraryDao {
    @Query("SELECT * FROM books ORDER BY addedAt DESC") fun observeBooks(): Flow<List<BookRow>>
    @Query("SELECT * FROM books") suspend fun allBooks(): List<BookRow>
    @Query("SELECT * FROM books WHERE id = :id LIMIT 1") suspend fun book(id: String): BookRow?
    @Query("SELECT * FROM book_deletions WHERE bookID = :id LIMIT 1") suspend fun bookDeletion(id: String): BookTombstoneRow?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putBook(book: BookRow)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putBooks(books: List<BookRow>)
    @Query("DELETE FROM books WHERE id = :id") suspend fun removeBook(id: String)
    @Query("UPDATE books SET lastOpenedAt = :openedAt, modifiedAt = :openedAt WHERE id = :id")
    suspend fun updateOpened(id: String, openedAt: Double): Int
    @Query("UPDATE books SET progress = :progress, localLocation = :localLocation, modifiedAt = :modifiedAt WHERE id = :id")
    suspend fun updateProgressFields(id: String, progress: Double, localLocation: String?, modifiedAt: Double): Int
    @Query("UPDATE books SET isBookmarked = CASE WHEN isBookmarked = 0 THEN 1 ELSE 0 END, modifiedAt = :modifiedAt WHERE id = :id")
    suspend fun toggleBookmark(id: String, modifiedAt: Double): Int
    @Query("SELECT * FROM book_deletions") suspend fun bookDeletions(): List<BookTombstoneRow>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putBookDeletion(item: BookTombstoneRow)
    @Query("DELETE FROM book_deletions WHERE bookID = :id") suspend fun clearBookDeletion(id: String)

    @Transaction
    suspend fun setProgressIfNeeded(id: String, progress: Double, localLocation: String?, modifiedAt: Double): Boolean {
        val current = book(id) ?: return false
        if (kotlin.math.abs(progress - current.progress) < 0.01 && localLocation == current.localLocation) return false
        return updateProgressFields(id, progress, localLocation, modifiedAt) > 0
    }

    @Transaction
    suspend fun seedBookUnlessDeleted(row: BookRow): Boolean {
        if (bookDeletion(row.id) != null) return false
        if (book(row.id) == null) putBook(row)
        return true
    }

    @Transaction
    suspend fun deleteBookWithTombstone(id: String, deletedAt: Double): BookRow? {
        val previous = bookDeletion(id)
        val tombstone = when {
            previous == null -> BookTombstoneRow(id, deletedAt)
            previous.deletedAt >= deletedAt -> previous
            else -> previous.copy(deletedAt = deletedAt)
        }
        if (previous == null || previous.deletedAt < deletedAt) putBookDeletion(tombstone)
        val current = book(id)
        removeBook(id)
        return current
    }

    @Transaction
    suspend fun applyBookTombstone(tombstone: BookTombstoneRow): BookRow? {
        val previous = bookDeletion(tombstone.bookID)
        val winning = previous?.takeIf { it.deletedAt >= tombstone.deletedAt } ?: tombstone
        if (previous == null || previous.deletedAt < tombstone.deletedAt) putBookDeletion(winning)
        val current = book(tombstone.bookID)
        if (current != null && current.modifiedAt <= winning.deletedAt) {
            removeBook(tombstone.bookID)
            return current
        }
        return null
    }

    @Transaction
    suspend fun installSyncedBookIfNewer(row: BookRow): Boolean {
        val current = book(row.id)
        if (current != null && current.modifiedAt >= row.modifiedAt) return false
        val tombstone = bookDeletion(row.id)
        if (tombstone != null && tombstone.deletedAt >= row.modifiedAt) return false
        putBook(row.copy(localLocation = current?.localLocation))
        clearBookDeletion(row.id)
        return true
    }

    @Transaction
    suspend fun installSyncedBookIfUnchanged(row: BookRow, expectedCurrent: BookRow, allowEqualTime: Boolean): Boolean {
        if (book(row.id) != expectedCurrent) return false
        if (row.modifiedAt < expectedCurrent.modifiedAt) return false
        if (row.modifiedAt == expectedCurrent.modifiedAt && !allowEqualTime) return false
        val tombstone = bookDeletion(row.id)
        if (tombstone != null && tombstone.deletedAt >= row.modifiedAt) return false
        putBook(row.copy(localLocation = expectedCurrent.localLocation))
        clearBookDeletion(row.id)
        return true
    }

    @Transaction
    suspend fun updateSyncedBookMetadataIfUnchanged(row: BookRow, expectedCurrent: BookRow): Boolean {
        if (book(row.id) != expectedCurrent || row.modifiedAt != expectedCurrent.modifiedAt) return false
        val tombstone = bookDeletion(row.id)
        if (tombstone != null && tombstone.deletedAt >= row.modifiedAt) return false
        putBook(row.copy(fileName = expectedCurrent.fileName, localLocation = expectedCurrent.localLocation))
        clearBookDeletion(row.id)
        return true
    }

    @Query("SELECT * FROM conversations ORDER BY modifiedAt DESC") fun observeConversations(): Flow<List<ConversationRow>>
    @Query("SELECT * FROM conversations") suspend fun allConversations(): List<ConversationRow>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putConversation(conversation: ConversationRow)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putConversations(conversations: List<ConversationRow>)
    @Query("DELETE FROM conversations WHERE id = :id") suspend fun removeConversation(id: String)
    @Query("SELECT * FROM conversation_deletions") suspend fun conversationDeletions(): List<ConversationTombstoneRow>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putConversationDeletion(item: ConversationTombstoneRow)
    @Query("DELETE FROM conversation_deletions WHERE conversationID = :id") suspend fun clearConversationDeletion(id: String)

    @Transaction
    suspend fun snapshot(): StoredLibrarySnapshot = StoredLibrarySnapshot(
        books = allBooks(),
        bookDeletions = bookDeletions(),
        conversations = allConversations(),
        conversationDeletions = conversationDeletions(),
    )
}

data class StoredLibrarySnapshot(
    val books: List<BookRow>,
    val bookDeletions: List<BookTombstoneRow>,
    val conversations: List<ConversationRow>,
    val conversationDeletions: List<ConversationTombstoneRow>,
)

@Database(
    entities = [BookRow::class, BookTombstoneRow::class, ConversationRow::class, ConversationTombstoneRow::class],
    version = 1,
    exportSchema = true,
)
abstract class CloudReaderDatabase : RoomDatabase() {
    abstract fun libraryDao(): LibraryDao

    companion object {
        @Volatile private var instance: CloudReaderDatabase? = null
        fun get(context: Context): CloudReaderDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context, CloudReaderDatabase::class.java, "cloudreader.db")
                .build().also { instance = it }
        }
    }
}
