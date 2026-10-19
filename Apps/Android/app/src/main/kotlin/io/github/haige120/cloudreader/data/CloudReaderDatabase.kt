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
import io.github.haige120.cloudreader.sync.SyncCodec
import kotlinx.coroutines.flow.Flow

@Dao
interface LibraryDao {
    @Query("SELECT * FROM books ORDER BY addedAt DESC") fun observeBooks(): Flow<List<BookRow>>
    @Query("SELECT * FROM books") suspend fun allBooks(): List<BookRow>
    @Query("SELECT * FROM books WHERE id = :id LIMIT 1") suspend fun book(id: String): BookRow?
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putBook(book: BookRow)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putBooks(books: List<BookRow>)
    @Query("DELETE FROM books WHERE id = :id") suspend fun removeBook(id: String)
    @Query("SELECT * FROM book_deletions") suspend fun bookDeletions(): List<BookTombstone>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putBookDeletion(item: BookTombstone)
    @Query("DELETE FROM book_deletions WHERE bookID = :id") suspend fun clearBookDeletion(id: String)

    @Query("SELECT * FROM conversations ORDER BY modifiedAt DESC") fun observeConversations(): Flow<List<ConversationRow>>
    @Query("SELECT * FROM conversations") suspend fun allConversations(): List<ConversationRow>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putConversation(conversation: ConversationRow)
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putConversations(conversations: List<ConversationRow>)
    @Query("DELETE FROM conversations WHERE id = :id") suspend fun removeConversation(id: String)
    @Query("SELECT * FROM conversation_deletions") suspend fun conversationDeletions(): List<ConversationTombstone>
    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun putConversationDeletion(item: ConversationTombstone)
    @Query("DELETE FROM conversation_deletions WHERE conversationID = :id") suspend fun clearConversationDeletion(id: String)

    @Transaction
    suspend fun snapshot(): LibrarySnapshot = LibrarySnapshot(
        allBooks(), bookDeletions(), allConversations().map { SyncCodec.chatFromJson(it.wireJson) }, conversationDeletions()
    )
}

@Database(
    entities = [BookRow::class, BookTombstone::class, ConversationRow::class, ConversationTombstone::class],
    version = 1,
    exportSchema = false,
)
abstract class CloudReaderDatabase : RoomDatabase() {
    abstract fun libraryDao(): LibraryDao

    companion object {
        @Volatile private var instance: CloudReaderDatabase? = null
        fun get(context: Context): CloudReaderDatabase = instance ?: synchronized(this) {
            instance ?: Room.databaseBuilder(context, CloudReaderDatabase::class.java, "cloudreader.db")
                .fallbackToDestructiveMigration(false).build().also { instance = it }
        }
    }
}
