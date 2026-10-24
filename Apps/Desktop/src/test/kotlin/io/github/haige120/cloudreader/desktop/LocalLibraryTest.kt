package io.github.haige120.cloudreader.desktop

import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class LocalLibraryTest {
    @Test
    fun importsTxtCopiesSourceAndRestoresProgress() {
        val root = Files.createTempDirectory("cloudreader-desktop-test")
        val source = Files.createTempFile(root, "sample", ".txt")
        Files.writeString(source, "第一行\nSecond line")
        val repository = FileLibraryRepository(root.resolve("library"))

        val imported = repository.importBook(source) as? ImportResult.Imported ?: fail("TXT import failed")
        assertTrue(imported.book.sourcePath != source)
        assertTrue(imported.book.sourcePath.fileName.toString().startsWith("book-"))
        assertEquals("第一行\nSecond line", Files.readString(imported.book.sourcePath))

        repository.updateProgress(imported.book.id, 3)
        val restored = FileLibraryRepository(root.resolve("library")).books().single()
        assertEquals(3, restored.textOffset)
    }

    @Test
    fun leavesPdfAndEpubVisibleAsUnsupported() {
        val root = Files.createTempDirectory("cloudreader-desktop-test")
        val repository = FileLibraryRepository(root.resolve("library"))
        val pdf = Files.createTempFile(root, "sample", ".pdf")
        val result = repository.importBook(pdf) as? ImportResult.Unsupported ?: fail("PDF should be reported as unsupported")
        assertEquals(BookFormat.PDF, result.format)
    }

    @Test
    fun recognizesAdditionalPortableFormatsBeforeReaderSupportExists() {
        val root = Files.createTempDirectory("cloudreader-desktop-test")
        val repository = FileLibraryRepository(root.resolve("library"))
        val fb2 = Files.createTempFile(root, "sample", ".fb2")
        val result = repository.importBook(fb2) as? ImportResult.Unsupported ?: fail("FB2 should be reported as unsupported")
        assertEquals(BookFormat.FB2, result.format)
    }
}


class CredentialStoreTest {
    @Test
    fun plaintextStoreRequiresExplicitOptIn() {
        val file = Files.createTempDirectory("cloudreader-credentials").resolve("credentials.properties")
        try {
            OptInPlaintextCredentialStore(file, enabled = false)
            fail("Plaintext store must require explicit opt-in")
        } catch (_: IllegalStateException) {
            // expected
        }
        val store = OptInPlaintextCredentialStore(file, enabled = true)
        store.write("provider", "account", "secret")
        assertEquals("secret", OptInPlaintextCredentialStore(file, enabled = true).read("provider", "account"))
    }
}
