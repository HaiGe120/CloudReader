package io.github.haige120.cloudreader

import android.net.Uri
import android.content.Context
import android.content.ContentResolver
import android.content.pm.ProviderInfo
import android.content.ContextWrapper
import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.haige120.cloudreader.data.CloudReaderDatabase
import io.github.haige120.cloudreader.data.BookRow
import io.github.haige120.cloudreader.data.LibraryDao
import io.github.haige120.cloudreader.data.LibraryRepository
import io.github.haige120.cloudreader.data.toDomain
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withContext
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryImportTest {
    @Test fun importsSupportedFilesWithoutChangingSourcesAndSkipsUnknownTypes() = runBlocking {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val targetContext = instrumentation.targetContext
        val provider = TestDocumentProvider().apply { attachInfo(targetContext, ProviderInfo()) }
        val resolver = ContentResolver.wrap(provider)
        val testContext = object : ContextWrapper(targetContext) {
            override fun getApplicationContext(): Context = this
            override fun getContentResolver() = resolver
        }
        val database = Room.inMemoryDatabaseBuilder(targetContext, CloudReaderDatabase::class.java).build()
        val testBooksDir = File(targetContext.cacheDir, "library-import-${System.nanoTime()}")
        check(testBooksDir.mkdirs())
        try {
            val nonce = System.nanoTime()
            val first = "duplicate-$nonce.txt"
            val second = "duplicate-2-$nonce.txt"
            val unsupported = "notes-$nonce.docx"
            val firstBytes = "First copy · 中文".toByteArray(Charsets.UTF_8)
            val secondBytes = "Second copy · 日本語".toByteArray(Charsets.UTF_8)
            TestDocumentProvider.register(first, firstBytes)
            TestDocumentProvider.register(second, secondBytes)
            TestDocumentProvider.register(unsupported, "not a book".toByteArray())
            val firstUri = documentUri(first, "Duplicate title.txt")
            val secondUri = documentUri(second, "Duplicate title.txt")
            val unsupportedUri = documentUri(unsupported, "Notes.docx")

            assertEquals(firstBytes.toList(), resolver.openInputStream(firstUri)!!.use { it.readBytes().toList() })
            assertEquals("Duplicate title.txt", resolver.query(firstUri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)!!.use {
                it.moveToFirst()
                it.getString(0)
            })

            val library = LibraryRepository(testContext, database.libraryDao(), booksDirectory = testBooksDir)
            val result = library.importUris(listOf(firstUri, secondUri, unsupportedUri))
            val books = database.libraryDao().allBooks()

            assertEquals(2 to 1, result)
            assertEquals(2, books.size)
            assertEquals(2, books.map { it.fileName }.toSet().size)
            assertEquals(setOf(firstBytes.toList(), secondBytes.toList()), books.map { it.toDomain() }.mapNotNull(library::fileFor).map { it.readBytes().toList() }.toSet())
            assertEquals(firstBytes.toList(), TestDocumentProvider.fixture(first)!!.toList())
            assertEquals(secondBytes.toList(), TestDocumentProvider.fixture(second)!!.toList())
            assertTrue(books.all { it.title == "Duplicate title" })
            assertNotEquals(books[0].id, books[1].id)
        } finally {
            database.close()
            testBooksDir.deleteRecursively()
            TestDocumentProvider.clear()
        }
    }

    @Test fun metadataAndOpenFailuresSkipOnlyTheirOwnDocuments() = runBlocking {
        val fixture = importFixture()
        try {
            val first = documentUri("first.txt", "First.txt")
            val failedQuery = documentUri("query.txt", "Query.txt").buildUpon().appendQueryParameter("failure", "query").build()
            val failedOpen = documentUri("open.txt", "Open.txt").buildUpon().appendQueryParameter("failure", "open").build()
            val last = documentUri("last.txt", "Last.txt")
            val firstBytes = "first source".toByteArray()
            val lastBytes = "last source".toByteArray()
            TestDocumentProvider.register("first.txt", firstBytes)
            TestDocumentProvider.register("last.txt", lastBytes)

            assertEquals(2 to 2, fixture.library.importUris(listOf(first, failedQuery, failedOpen, last)))

            val books = fixture.database.libraryDao().allBooks()
            assertEquals(setOf("First", "Last"), books.map { it.title }.toSet())
            assertEquals(setOf(firstBytes.toList(), lastBytes.toList()), books.map { it.toDomain() }.mapNotNull(fixture.library::fileFor).map { it.readBytes().toList() }.toSet())
            assertEquals(2, fixture.booksDir.listFiles().orEmpty().size)
            assertEquals(firstBytes.toList(), TestDocumentProvider.fixture("first.txt")!!.toList())
            assertEquals(lastBytes.toList(), TestDocumentProvider.fixture("last.txt")!!.toList())
        } finally {
            fixture.close()
        }
    }

    @Test fun providerCancellationPropagatesAndDoesNotImportLaterDocuments() = runBlocking {
        val fixture = importFixture()
        try {
            val cancelled = documentUri("cancelled.txt", "Cancelled.txt").buildUpon().appendQueryParameter("failure", "cancel").build()
            val later = documentUri("later.txt", "Later.txt")
            TestDocumentProvider.register("later.txt", "later source".toByteArray())

            var propagated = false
            try {
                fixture.library.importUris(listOf(cancelled, later))
            } catch (_: CancellationException) {
                propagated = true
            }
            assertTrue("Cancellation must escape instead of counting as a skipped file", propagated)
            assertTrue(fixture.database.libraryDao().allBooks().isEmpty())
            assertTrue(fixture.booksDir.listFiles().orEmpty().isEmpty())
        } finally {
            fixture.close()
        }
    }

    @Test fun cancellationDuringCopyRemovesPartialFileWithoutCommittingABook() = runBlocking {
        val fixture = importFixture()
        val written = CountDownLatch(1)
        val resume = CountDownLatch(1)
        var importing: Deferred<Pair<Int, Int>>? = null
        try {
            TestDocumentProvider.register("partial.txt", "partially copied source".toByteArray())
            TestDocumentProvider.pauseAfterWrite("partial.txt", written, resume)
            val task = async(Dispatchers.IO) { fixture.library.importUris(listOf(documentUri("partial.txt", "Partial.txt"))) }
            importing = task
            assertTrue(written.await(5, TimeUnit.SECONDS))
            withTimeout(5_000) {
                while (fixture.booksDir.listFiles().orEmpty().none { it.length() > 0 }) delay(10)
            }
            task.cancel()
            resume.countDown()
            task.join()

            assertTrue(task.isCancelled)
            assertTrue(fixture.database.libraryDao().allBooks().isEmpty())
            assertTrue(fixture.booksDir.listFiles().orEmpty().isEmpty())
            assertEquals("partially copied source", TestDocumentProvider.fixture("partial.txt")!!.toString(Charsets.UTF_8))
        } finally {
            resume.countDown()
            withContext(NonCancellable) {
                importing?.cancelAndJoin()
                fixture.close()
            }
        }
    }

    @Test fun cancellationAtRowCommitRollsBackTheNewBookAndCopiedFile() = runBlocking {
        val fixture = importFixture { actual ->
            object : LibraryDao by actual {
                override suspend fun putBook(book: BookRow) {
                    actual.putBook(book)
                    throw CancellationException("Cancelled while committing the import")
                }
            }
        }
        try {
            TestDocumentProvider.register("commit.txt", "source bytes".toByteArray())
            var propagated = false
            try {
                fixture.library.importUris(listOf(documentUri("commit.txt", "Commit.txt")))
            } catch (_: CancellationException) {
                propagated = true
            }
            assertTrue(propagated)
            assertTrue(fixture.database.libraryDao().allBooks().isEmpty())
            assertTrue(fixture.booksDir.listFiles().orEmpty().isEmpty())
        } finally {
            fixture.close()
        }
    }

    private fun importFixture(daoAdapter: (LibraryDao) -> LibraryDao = { it }): ImportFixture {
        val target = InstrumentationRegistry.getInstrumentation().targetContext
        val provider = TestDocumentProvider().apply { attachInfo(target, ProviderInfo()) }
        val resolver = ContentResolver.wrap(provider)
        val testContext = object : ContextWrapper(target) {
            override fun getApplicationContext(): Context = this
            override fun getContentResolver() = resolver
        }
        val database = Room.inMemoryDatabaseBuilder(target, CloudReaderDatabase::class.java).build()
        val booksDir = File(target.cacheDir, "library-import-${System.nanoTime()}").apply { check(mkdirs()) }
        return ImportFixture(database, booksDir, LibraryRepository(testContext, daoAdapter(database.libraryDao()), booksDirectory = booksDir))
    }

    private data class ImportFixture(val database: CloudReaderDatabase, val booksDir: File, val library: LibraryRepository) {
        fun close() {
            TestDocumentProvider.clear()
            database.close()
            booksDir.deleteRecursively()
        }
    }

    private fun documentUri(fileName: String, displayName: String): Uri = Uri.Builder()
        .scheme("content")
        .authority("io.github.haige120.cloudreader.testdocuments")
        .appendPath("documents")
        .appendPath(fileName)
        .appendQueryParameter("name", displayName)
        .build()
}
