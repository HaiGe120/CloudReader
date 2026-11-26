package io.github.haige120.cloudreader

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.util.LruCache
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import io.github.haige120.cloudreader.core.reader.PublicationCover
import io.github.haige120.cloudreader.domain.BookRecord
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

private val coverWorker = Dispatchers.IO.limitedParallelism(2)
private const val EDGE = 512
private val thumbnails = object : LruCache<File, Bitmap>(12 * 1024 * 1024) {
    override fun sizeOf(key: File, value: Bitmap) = value.allocationByteCount
}

@Composable
internal fun shelfArtwork(app: CloudReaderApp, book: BookRecord): ImageBitmap? {
    if (book.format !in setOf("epub", "fb2", "cbz", "pdf")) return null
    // Each imported or replaced managed file has a unique name, including sync replacements.
    return key(book.fileName, book.format) {
        val cover by produceState<ImageBitmap?>(null) {
            value = withContext(coverWorker) {
                val file = app.library.fileFor(book) ?: return@withContext null
                val bitmap = thumbnails.get(file) ?: loadCoverBitmap(file, book.format)?.also { thumbnails.put(file, it) }
                bitmap?.asImageBitmap()
            }
        }
        cover
    }
}

internal fun loadCoverBitmap(file: File, format: String): Bitmap? {
    return try {
        if (format == "pdf") return pdfCover(file)
        val bytes = PublicationCover.image(file, format) ?: return null
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val longest = max(bounds.outWidth, bounds.outHeight)
        val options = BitmapFactory.Options().apply {
            inSampleSize = 1
            while (longest.toLong() > EDGE.toLong() * inSampleSize) {
                inSampleSize = 2 * inSampleSize
            }
        }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options)
    } catch (_: Exception) {
        // Damaged, encrypted, and unavailable publications keep their title cover.
        null
    }
}

private fun pdfCover(file: File): Bitmap? =
    ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { descriptor ->
        PdfRenderer(descriptor).use { document ->
            if (document.pageCount == 0) return null
            document.openPage(0).use { page ->
                val scale = EDGE.toDouble() / max(page.width, page.height).coerceAtLeast(1)
                Bitmap.createBitmap(max(1, (page.width * scale).roundToInt()),
                    max(1, (page.height * scale).roundToInt()), Bitmap.Config.ARGB_8888).also {
                    it.eraseColor(Color.WHITE)
                    page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                }
            }
        }
    }
