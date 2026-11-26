package io.github.haige120.cloudreader

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfDocument
import androidx.test.platform.app.InstrumentationRegistry
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class ShelfArtworkTest {
    @get:Rule val temp = TemporaryFolder(InstrumentationRegistry.getInstrumentation().targetContext.cacheDir)

    @Test fun pdfUsesFirstPageAtThumbnailSize() {
        val file = temp.newFile()
        val document = PdfDocument()
        try {
            for ((index, color) in listOf(Color.RED, Color.BLUE).withIndex()) {
                val page = document.startPage(PdfDocument.PageInfo.Builder(600, 900, index + 1).create())
                page.canvas.drawColor(color)
                document.finishPage(page)
            }
            file.outputStream().use(document::writeTo)
        } finally {
            document.close()
        }
        val cover = requireNotNull(loadCoverBitmap(file, "pdf"))
        assertEquals(512, cover.height)
        assertEquals(Color.RED, cover.getPixel(cover.width / 2, cover.height / 2))
    }

    @Test fun largeComicPageIsSampledAndCorruptFilesKeepFallback() {
        val file = temp.newFile()
        ZipOutputStream(file.outputStream()).use { zip ->
            zip.putNextEntry(ZipEntry("001.png"))
            val page = Bitmap.createBitmap(1200, 1800, Bitmap.Config.ARGB_8888)
            page.eraseColor(Color.GREEN)
            assertTrue(page.compress(Bitmap.CompressFormat.PNG, 100, zip))
            page.recycle()
            zip.closeEntry()
        }
        val cover = requireNotNull(loadCoverBitmap(file, "cbz"))
        assertTrue(cover.height in 1..512)
        assertEquals(Color.GREEN, cover.getPixel(cover.width / 2, cover.height / 2))
        file.writeText("Damaged book")
        assertNull(loadCoverBitmap(file, "epub"))
    }
}
