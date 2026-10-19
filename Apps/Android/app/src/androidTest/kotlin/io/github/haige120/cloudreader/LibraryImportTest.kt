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
import io.github.haige120.cloudreader.data.LibraryRepository
import java.io.File
import kotlinx.coroutines.runBlocking
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
        val managedDir = File(targetContext.filesDir, "CloudReader/Books")
        managedDir.deleteRecursively()
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

            val library = LibraryRepository(testContext, database.libraryDao())
            val result = library.importUris(listOf(firstUri, secondUri, unsupportedUri))
            val books = database.libraryDao().allBooks()

            assertEquals(2 to 1, result)
            assertEquals(2, books.size)
            assertEquals(2, books.map { it.fileName }.toSet().size)
            assertEquals(setOf(firstBytes.toList(), secondBytes.toList()), books.mapNotNull(library::fileFor).map { it.readBytes().toList() }.toSet())
            assertEquals(firstBytes.toList(), TestDocumentProvider.fixture(first)!!.toList())
            assertEquals(secondBytes.toList(), TestDocumentProvider.fixture(second)!!.toList())
            assertTrue(books.all { it.title == "Duplicate title" })
            assertNotEquals(books[0].id, books[1].id)
        } finally {
            database.close()
            managedDir.deleteRecursively()
            TestDocumentProvider.clear()
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
