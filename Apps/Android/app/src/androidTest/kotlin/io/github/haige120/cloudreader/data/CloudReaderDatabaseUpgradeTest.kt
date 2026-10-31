package io.github.haige120.cloudreader.data

import android.database.sqlite.SQLiteDatabase
import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.BookTombstone
import io.github.haige120.cloudreader.domain.ChatRecord
import io.github.haige120.cloudreader.domain.ConversationTombstone
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CloudReaderDatabaseUpgradeTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun existingV1DataOpensUnchanged() = runBlocking {
        val name = "room-v1-${System.nanoTime()}.db"
        val file = context.getDatabasePath(name).also { it.parentFile?.mkdirs() }
        createV1Database(file, version = 1)
        val database = Room.databaseBuilder(context, CloudReaderDatabase::class.java, name).build()
        try {
            val dao = database.libraryDao()
            assertEquals(BookRow("book-id", "Saved title", "Author", "Description", "saved.txt", "txt", 12.25, 13.5, 0.375, true, 14.75, "/private/books/saved.txt", "{\"extra\":1}"), dao.book("book-id"))
            assertEquals(listOf(BookTombstoneRow("deleted-book", 15.25, "{\"tomb\":true}")), dao.bookDeletions())
            assertEquals(listOf(ConversationRow("62B27B43-A87E-402D-8D6A-A70747F50291", "{\"id\":\"62B27B43-A87E-402D-8D6A-A70747F50291\",\"title\":\"Saved chat\",\"messages\":[],\"createdAt\":16.125,\"modifiedAt\":16.25,\"futureChat\":{\"x\":1}}", 16.25)), dao.allConversations())
            assertEquals(listOf(ConversationTombstoneRow("deleted-chat", 17.25, "{\"tomb\":2}")), dao.conversationDeletions())
            val isolatedBooks = File(context.cacheDir, "room-snapshot-${System.nanoTime()}")
            val library = LibraryRepository(context, dao, isolatedBooks)
            try {
                val snapshot = library.snapshot()
                assertEquals(listOf(BookRecord("book-id", "Saved title", "Author", "Description", "saved.txt", "txt", 12.25, 13.5, 0.375, true, 14.75, "/private/books/saved.txt", "{\"extra\":1}")), snapshot.books)
                assertEquals(listOf(BookTombstone("deleted-book", 15.25, "{\"tomb\":true}")), snapshot.bookDeletions)
                assertEquals(listOf(ChatRecord("62B27B43-A87E-402D-8D6A-A70747F50291", "Saved chat", emptyList(), createdAt = 16.125, modifiedAt = 16.25, unknownJson = "{\"futureChat\":{\"x\":1}}")), snapshot.conversations)
                assertEquals(listOf(ConversationTombstone("deleted-chat", 17.25, "{\"tomb\":2}")), snapshot.conversationDeletions)
            } finally {
                isolatedBooks.deleteRecursively()
            }
        } finally {
            database.close()
            context.deleteDatabase(name)
        }
    }

    @Test fun unsupportedUpgradeFailsWithoutDroppingData() {
        val name = "room-unsupported-${System.nanoTime()}.db"
        val file = context.getDatabasePath(name).also { it.parentFile?.mkdirs() }
        createV1Database(file, version = 2)
        val database = Room.databaseBuilder(context, CloudReaderDatabase::class.java, name).build()
        try {
            assertThrows(IllegalStateException::class.java) {
                database.openHelper.writableDatabase
            }
            SQLiteDatabase.openDatabase(file.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
                db.rawQuery("SELECT title FROM books WHERE id = 'book-id'", null).use { cursor ->
                    check(cursor.moveToFirst())
                    assertEquals("Saved title", cursor.getString(0))
                }
                assertEquals(2, db.version)
            }
        } finally {
            database.close()
            context.deleteDatabase(name)
        }
    }

    private fun createV1Database(file: File, version: Int) {
        SQLiteDatabase.openOrCreateDatabase(file, null).use { db ->
            db.execSQL("CREATE TABLE IF NOT EXISTS `books` (`id` TEXT NOT NULL, `title` TEXT NOT NULL, `author` TEXT, `briefDescription` TEXT, `fileName` TEXT NOT NULL, `format` TEXT NOT NULL, `addedAt` REAL NOT NULL, `lastOpenedAt` REAL, `progress` REAL NOT NULL, `isBookmarked` INTEGER NOT NULL, `modifiedAt` REAL NOT NULL, `localLocation` TEXT, `unknownJson` TEXT NOT NULL, PRIMARY KEY(`id`))")
            db.execSQL("CREATE TABLE IF NOT EXISTS `book_deletions` (`bookID` TEXT NOT NULL, `deletedAt` REAL NOT NULL, `unknownJson` TEXT NOT NULL, PRIMARY KEY(`bookID`))")
            db.execSQL("CREATE TABLE IF NOT EXISTS `conversations` (`id` TEXT NOT NULL, `wireJson` TEXT NOT NULL, `modifiedAt` REAL NOT NULL, PRIMARY KEY(`id`))")
            db.execSQL("CREATE TABLE IF NOT EXISTS `conversation_deletions` (`conversationID` TEXT NOT NULL, `deletedAt` REAL NOT NULL, `unknownJson` TEXT NOT NULL, PRIMARY KEY(`conversationID`))")
            db.execSQL("CREATE TABLE IF NOT EXISTS room_master_table (id INTEGER PRIMARY KEY,identity_hash TEXT)")
            db.execSQL("INSERT OR REPLACE INTO room_master_table (id,identity_hash) VALUES(42, 'f93f4465dd7d119bc1c90256d709588c')")
            db.execSQL("INSERT INTO books VALUES ('book-id','Saved title','Author','Description','saved.txt','txt',12.25,13.5,0.375,1,14.75,'/private/books/saved.txt','{\"extra\":1}')")
            db.execSQL("INSERT INTO book_deletions VALUES ('deleted-book',15.25,'{\"tomb\":true}')")
            db.execSQL("INSERT INTO conversations VALUES ('62B27B43-A87E-402D-8D6A-A70747F50291','{\"id\":\"62B27B43-A87E-402D-8D6A-A70747F50291\",\"title\":\"Saved chat\",\"messages\":[],\"createdAt\":16.125,\"modifiedAt\":16.25,\"futureChat\":{\"x\":1}}',16.25)")
            db.execSQL("INSERT INTO conversation_deletions VALUES ('deleted-chat',17.25,'{\"tomb\":2}')")
            db.version = version
        }
    }
}
