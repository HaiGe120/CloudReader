package io.github.haige120.cloudreader.data

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.DemoBook
import java.io.File
import java.io.IOException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryMutationDurabilityTest {
    private val context get() = InstrumentationRegistry.getInstrumentation().targetContext

    @Test fun concurrentFavoriteAndProgressMutationsDoNotOverwriteEachOther() = runBlocking {
        val fixture = fixture()
        try {
            val initial = book().copy(progress = 0.1, isBookmarked = false)
            fixture.dao.putBook(initial.toRow())
            val repository = fixture.repository()
            val staleSnapshot = initial
            (0 until 30).map { index ->
                async(Dispatchers.IO) {
                    if (index % 2 == 0) repository.bookmark(staleSnapshot)
                    else repository.progress(staleSnapshot, 0.65, "txt:65")
                }
            }.awaitAll()

            val saved = fixture.dao.book(initial.id)!!.toDomain()
            assertTrue("Fifteen atomic favorite toggles have odd parity", saved.isBookmarked)
            assertEquals(0.65, saved.progress, 0.0)
            assertEquals("txt:65", saved.localLocation)
        } finally {
            fixture.close()
        }
    }

    @Test fun deletingDemoBookSurvivesRepositoryRecreation() = runBlocking {
        val fixture = fixture()
        try {
            val repository = fixture.repository()
            repository.seedDemoBook()
            val saved = fixture.dao.book(DemoBook.ID)!!.toDomain()
            assertTrue(File(fixture.books, saved.fileName).isFile)

            repository.remove(saved)
            val relaunched = fixture.repository()
            relaunched.seedDemoBook()

            assertNull(fixture.dao.book(DemoBook.ID))
            assertNotNull(fixture.dao.bookDeletion(DemoBook.ID))
            assertFalse(File(fixture.books, saved.fileName).exists())
        } finally {
            fixture.close()
        }
    }

    @Test fun failedSyncedFileCommitDoesNotPublishDatabaseRow() = runBlocking {
        val fixture = fixture()
        try {
            val renameFailure = RepositoryFileOps(rename = { _, _ -> false })
            val repository = fixture.repository(renameFailure)
            assertThrows(IOException::class.java) {
                runBlocking { repository.installSyncedBook(book().copy(modifiedAt = 2.0), byteArrayOf(1, 2, 3)) }
            }

            assertNull(fixture.dao.book(ID))
            assertTrue(fixture.books.listFiles().orEmpty().isEmpty())
        } finally {
            fixture.close()
        }
    }

    @Test fun interruptedDeleteLeavesDurableTombstoneAndCanBeRetried() = runBlocking {
        val fixture = fixture()
        try {
            val value = book()
            fixture.dao.putBook(value.toRow())
            fixture.dao.putBookDeletion(BookTombstoneRow(value.id, 0.5, """{"futureDeletion":{"keep":true}}"""))
            val file = File(fixture.books, value.fileName).apply { writeBytes(byteArrayOf(7, 8, 9)) }
            val failing = fixture.repository(RepositoryFileOps(delete = { false }))

            assertThrows(IOException::class.java) { runBlocking { failing.remove(value) } }
            assertNull(fixture.dao.book(value.id))
            assertEquals("""{"futureDeletion":{"keep":true}}""", fixture.dao.bookDeletion(value.id)!!.unknownJson)
            assertTrue("A failed byte deletion must leave the file available for retry", file.exists())

            fixture.repository().remove(value)
            assertFalse(file.exists())
            assertNotNull(fixture.dao.bookDeletion(value.id))
        } finally {
            fixture.close()
        }
    }

    @Test fun staleRemoteMetadataCannotReplaceLatestLocalStateAndNewerRemoteKeepsLocalLocation() = runBlocking {
        val fixture = fixture()
        try {
            val current = book().copy(title = "Latest local", progress = 0.73, isBookmarked = true, modifiedAt = 30.0, localLocation = "txt:123")
            fixture.dao.putBook(current.toRow())
            val localFile = File(fixture.books, current.fileName).apply { writeBytes(byteArrayOf(1)) }
            val repository = fixture.repository()

            val staleInstalled = repository.installSyncedBook(book().copy(title = "Stale remote", modifiedAt = 20.0), byteArrayOf(2))
            assertFalse(staleInstalled)
            assertEquals(current, fixture.dao.book(current.id)!!.toDomain())
            assertEquals(listOf(1.toByte()), localFile.readBytes().toList())

            val newerInstalled = repository.installSyncedBook(book().copy(title = "New remote", modifiedAt = 40.0), byteArrayOf(3))
            assertTrue(newerInstalled)
            val updated = fixture.dao.book(current.id)!!.toDomain()
            assertEquals("New remote", updated.title)
            assertEquals("txt:123", updated.localLocation)
            assertEquals(listOf(3.toByte()), fixture.repository().fileFor(updated)!!.readBytes().toList())
            assertFalse("Old bytes are removed only after the replacement row commits", localFile.exists())
        } finally {
            fixture.close()
        }
    }

    @Test fun equalTimeCanonicalWinnerCanReplaceBytesOnlyAgainstCapturedRow() = runBlocking {
        val fixture = fixture()
        try {
            val current = book().copy(title = "Beta", modifiedAt = 20.0, progress = 0.2, localLocation = "txt:20")
            fixture.dao.putBook(current.toRow())
            val oldFile = File(fixture.books, current.fileName).apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val replacement = current.copy(title = "Alpha", fileName = "remote.txt")
            assertTrue(fixture.repository().installSyncedBook(replacement, byteArrayOf(7, 8), expectedCurrent = current, allowEqualTimeReplacement = true))
            val updated = fixture.dao.book(ID)!!.toDomain()
            assertEquals("Alpha", updated.title)
            assertEquals(20.0, updated.modifiedAt, 0.0)
            assertEquals(0.2, updated.progress, 0.0)
            assertEquals("txt:20", updated.localLocation)
            assertEquals(listOf(7.toByte(), 8.toByte()), fixture.repository().fileFor(updated)!!.readBytes().toList())
            assertFalse(oldFile.exists())
        } finally { fixture.close() }
    }

    @Test fun equalTimeCommitRejectsStaleCapturedRowAndRetainsOldBytes() = runBlocking {
        val fixture = fixture()
        try {
            val current = book().copy(title = "Captured", modifiedAt = 20.0)
            fixture.dao.putBook(current.toRow())
            val oldFile = File(fixture.books, current.fileName).apply { writeBytes(byteArrayOf(1, 2, 3)) }
            val racingOps = RepositoryFileOps(rename = { source, target ->
                val renamed = source.renameTo(target)
                runBlocking { fixture.dao.putBook(current.copy(isBookmarked = true, modifiedAt = 21.0).toRow()) }
                renamed
            })
            assertFalse(fixture.repository(racingOps).installSyncedBook(
                current.copy(title = "Remote tie"), byteArrayOf(9), expectedCurrent = current, allowEqualTimeReplacement = true,
            ))
            assertEquals(listOf(1.toByte(), 2.toByte(), 3.toByte()), oldFile.readBytes().toList())
            assertEquals("Captured", fixture.dao.book(ID)!!.title)
            assertTrue(fixture.books.listFiles().orEmpty().none { it.name.startsWith("sync-") })
        } finally { fixture.close() }
    }

    @Test fun equalTimeInstallFailureKeepsOldCopyAndRow() = runBlocking {
        val fixture = fixture()
        try {
            val current = book().copy(title = "Original", modifiedAt = 20.0)
            fixture.dao.putBook(current.toRow())
            val oldFile = File(fixture.books, current.fileName).apply { writeBytes(byteArrayOf(4, 5)) }
            assertThrows(IOException::class.java) {
                runBlocking { fixture.repository(RepositoryFileOps(rename = { _, _ -> false })).installSyncedBook(
                    current.copy(title = "Candidate"), byteArrayOf(6), expectedCurrent = current, allowEqualTimeReplacement = true,
                ) }
            }
            assertEquals("Original", fixture.dao.book(ID)!!.title)
            assertEquals(listOf(4.toByte(), 5.toByte()), oldFile.readBytes().toList())
        } finally { fixture.close() }
    }

    @Test fun equalTimeMetadataOnlyUpdatePreservesManagedFileAndDeviceLocation() = runBlocking {
        val fixture = fixture()
        try {
            val current = book().copy(title = "Beta", modifiedAt = 20.0, progress = 0.4, localLocation = "txt:80")
            fixture.dao.putBook(current.toRow())
            val managedFile = File(fixture.books, current.fileName).apply { writeBytes(byteArrayOf(3, 4, 5)) }
            val updated = current.copy(title = "Alpha", fileName = "portable.txt", localLocation = null)
            assertTrue(fixture.repository().updateSyncedBookMetadata(updated, current))
            val saved = fixture.dao.book(ID)!!.toDomain()
            assertEquals("Alpha", saved.title)
            assertEquals(current.fileName, saved.fileName)
            assertEquals("txt:80", saved.localLocation)
            assertEquals(0.4, saved.progress, 0.0)
            assertEquals(listOf(3.toByte(), 4.toByte(), 5.toByte()), managedFile.readBytes().toList())
        } finally { fixture.close() }
    }

    private fun fixture(): Fixture {
        val database = Room.inMemoryDatabaseBuilder(context, CloudReaderDatabase::class.java).build()
        val books = File(context.cacheDir, "library-mutations-${System.nanoTime()}").apply { check(mkdirs()) }
        return Fixture(database, books)
    }

    private fun book() = BookRecord(
        id = ID, title = "Book", fileName = "$ID.txt", format = "txt", addedAt = 1.0, modifiedAt = 1.0,
    )

    private class Fixture(val database: CloudReaderDatabase, val books: File) {
        val dao get() = database.libraryDao()
        fun repository(fileOps: RepositoryFileOps = RepositoryFileOps()) = LibraryRepository(
            InstrumentationRegistry.getInstrumentation().targetContext, dao, books, fileOps,
        )
        fun close() {
            database.close()
            books.deleteRecursively()
        }
    }

    companion object { private const val ID = "C4D7A012-5B5F-4A42-9D39-83A1421A9657" }
}
