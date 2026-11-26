package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.assistant.AIProfile
import io.github.haige120.cloudreader.core.model.ChatMessage
import io.github.haige120.cloudreader.core.model.ChatRecord
import io.github.haige120.cloudreader.core.model.canonicalUUID
import org.apache.pdfbox.pdmodel.PDDocument
import org.apache.pdfbox.pdmodel.PDPage
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.awt.image.BufferedImage
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import javax.imageio.ImageIO

class DesktopParityTest {
    @Rule @JvmField val folder = TemporaryFolder()

    @Test fun comicAndPdfCoversFitTheShelfThumbnail() {
        val comic = folder.newFile("pages.cbz")
        ZipOutputStream(comic.outputStream()).use { archive ->
            archive.putNextEntry(ZipEntry("page-1.png"))
            ImageIO.write(BufferedImage(1500, 2400, BufferedImage.TYPE_INT_RGB), "png", archive)
            archive.closeEntry()
        }
        val pdf = folder.newFile("cover.pdf")
        PDDocument().use { it.addPage(PDPage()); it.save(pdf) }
        for ((file, format) in listOf(comic to BookFormat.CBZ, pdf to BookFormat.PDF)) {
            val thumb = requireNotNull(readDesktopCover(file, format))
            assertTrue(thumb.height in 1..288)
            assertTrue(thumb.width in 1 until thumb.height)
        }
        assertNull(readDesktopCover(folder.newFile("text.txt"), BookFormat.TXT))
    }

    @Test fun disablingBookContextClearsSavedExcerptsWithoutLosingOrRevivingTheConversation() {
        val root = folder.root.toPath()
        val repository = FileLibraryRepository(root)
        val id = canonicalUUID(newBookId().value)
        val message = ChatMessage(canonicalUUID(newBookId().value), "user", "Why?", 1.0)
        val chat = ChatRecord(id, "Question", messages = listOf(message),
            selectedText = "selected", bookContext = "nearby", includeBookContext = true)
        repository.saveChat(chat)
        repository.setChatContextConsent(id, false)
        val saved = FileLibraryRepository(root).chats().single()
        assertFalse(saved.includeBookContext)
        assertNull(saved.selectedText)
        assertNull(saved.bookContext)
        assertEquals(chat.messages, saved.messages)
        repository.removeChat(id)
        repository.setChatContextConsent(id, true)
        assertTrue(repository.chats().isEmpty())
    }

    @Test fun changingProviderRetainsTheLegacyKeyOnlyForItsOriginalOrigin() {
        val root = folder.root.toPath()
        val settings = DesktopSettings(root.resolve("settings.properties"))
        settings.save(mapOf("credentials.plaintext" to "true"))
        val secrets = DesktopSecrets(root, settings)
        val first = settings.profile().desktopOrigin()
        val next = AIProfile(endpoint = "https://example.org/v1/responses").desktopOrigin()
        val legacy = mapOf("ai.apiKey" to "old")
        assertEquals("old", savedDesktopKey(first, settings, legacy::get))
        assertNull(savedDesktopKey(next, settings, legacy::get))
        saveDesktopSettings(settings, secrets, mapOf("ai.endpoint" to "https://example.org/v1/responses",
            "ai.webSearch" to "true"), mapOf("ai.apiKey" to "new"))
        val reloaded = DesktopSettings(root.resolve("settings.properties"))
        assertTrue(reloaded.profile().webSearch)
        assertEquals("old", savedDesktopKey(first, reloaded, legacy::get))
        assertNull(savedDesktopKey(next, reloaded, legacy::get))
        assertEquals("new", secrets.read(originKey(next)))
    }
}
