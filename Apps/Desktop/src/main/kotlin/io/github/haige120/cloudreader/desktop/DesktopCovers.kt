package io.github.haige120.cloudreader.desktop

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.produceState
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.toComposeImageBitmap
import io.github.haige120.cloudreader.core.reader.PublicationCover
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.apache.pdfbox.Loader
import org.apache.pdfbox.rendering.PDFRenderer
import java.awt.image.BufferedImage
import java.io.File
import javax.imageio.ImageIO
import javax.imageio.stream.MemoryCacheImageInputStream
import kotlin.math.ceil

private const val thumbnailEdge = 288
private val workers = Dispatchers.IO.limitedParallelism(2)
private data class CoverKey(val file: File, val length: Long, val modified: Long)
private val thumbnails = object : LinkedHashMap<CoverKey, ImageBitmap?>(32, .75f, true) {
    override fun removeEldestEntry(eldest: MutableMap.MutableEntry<CoverKey, ImageBitmap?>?) = size > 36
}

@Composable
internal fun desktopCover(book: BookRecord): ImageBitmap? = key(book.sourcePath, book.modifiedAt) {
    val image by produceState<ImageBitmap?>(null) {
        value = withContext(workers) {
            val file = book.sourcePath.toFile()
            val id = CoverKey(file, file.length(), file.lastModified())
            synchronized(thumbnails) {
                if (thumbnails.containsKey(id)) return@withContext thumbnails[id]
            }
            val cover = try {
                readDesktopCover(file, book.format)?.toComposeImageBitmap()
            } catch (_: Exception) {
                null
            }
            synchronized(thumbnails) { thumbnails[id] = cover }
            cover
        }
    }
    image
}

internal fun readDesktopCover(file: File, format: BookFormat): BufferedImage? {
    if (format == BookFormat.PDF) return Loader.loadPDF(file).use { document ->
        if (document.numberOfPages == 0) return@use null
        val box = document.getPage(0).cropBox
        if (!box.width.isFinite() || !box.height.isFinite() || box.width <= 0 || box.height <= 0) return@use null
        PDFRenderer(document).apply { isSubsamplingAllowed = true }
            .renderImage(0, minOf(1f, thumbnailEdge / maxOf(box.width, box.height)))
    }
    val bytes = PublicationCover.image(file, format.extension) ?: return null
    return MemoryCacheImageInputStream(bytes.inputStream()).use { stream ->
        val reader = ImageIO.getImageReaders(stream).asSequence().firstOrNull() ?: return@use null
        try {
            reader.input = stream
            val edge = maxOf(reader.getWidth(0), reader.getHeight(0))
            val sample = ceil(edge.toDouble() / thumbnailEdge).toInt().coerceAtLeast(1)
            reader.read(0, reader.defaultReadParam.apply { setSourceSubsampling(sample, sample, 0, 0) })
        } finally {
            reader.dispose()
        }
    }
}
