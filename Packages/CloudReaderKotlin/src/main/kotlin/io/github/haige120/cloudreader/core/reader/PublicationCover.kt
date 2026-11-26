package io.github.haige120.cloudreader.core.reader

import org.jsoup.Jsoup
import org.jsoup.parser.Parser
import java.io.DataInputStream
import java.io.File
import java.net.URI
import java.util.Base64
import java.util.zip.ZipFile

/** Looks up embedded artwork without unpacking the publication or fetching external resources. */
object PublicationCover {
    private const val MAX_IMAGE = 16 * 1024 * 1024
    private const val MAX_METADATA = 2 * 1024 * 1024

    fun image(file: File, format: String): ByteArray? = when (format) {
        "epub", "cbz" -> ZipFile(file).use { zip ->
            if (zip.size() > 25_000) null else if (format == "epub") epub(zip) else comic(zip)
        }
        "fb2" -> fictionBook(file)
        else -> null
    }

    private fun ZipFile.bytes(path: String, limit: Int): ByteArray? {
        val entry = getEntry(path) ?: return null
        if (entry.isDirectory || entry.size !in 1L..limit.toLong()) return null
        return getInputStream(entry).use { input ->
            ByteArray(entry.size.toInt()).also { DataInputStream(input).readFully(it) }
        }
    }

    private fun comic(zip: ZipFile): ByteArray? {
        val first = zip.entries().asSequence().map { it.name }.filter { path ->
            path.substringAfterLast('.').lowercase() in setOf("jpg", "jpeg", "png", "gif", "webp") &&
                path.split('/').none { it.startsWith('.') || it == "__MACOSX" }
        }.minWithOrNull(PublicationLoader.natural) ?: return null
        return zip.bytes(first, MAX_IMAGE)
    }

    private fun resolve(base: String, href: String): String? {
        val ref = runCatching { URI(href.replace(" ", "%20")) }.getOrNull() ?: return null
        if (ref.isAbsolute || ref.rawAuthority != null || ref.path.isNullOrBlank() || ref.path.startsWith('/')) return null
        val path = URI(null, null, "/$base", null).resolve(ref).normalize().path
        return path.removePrefix("/").takeIf { ".." !in it.split('/') }
    }

    private fun parse(bytes: ByteArray) = Jsoup.parse(bytes.inputStream(), null, "", Parser.xmlParser())

    private fun epub(zip: ZipFile): ByteArray? {
        val container = zip.bytes("META-INF/container.xml", MAX_METADATA) ?: return null
        val packagePath = parse(container).selectFirst("rootfile")?.attr("full-path") ?: return null
        val doc = parse(zip.bytes(packagePath, MAX_METADATA) ?: return null)
        val items = doc.select("manifest > item")
        val legacy = doc.selectFirst("meta[name=cover]")?.attr("content")
        val first = doc.selectFirst("spine > itemref")?.attr("idref")
        val declared = listOfNotNull(
            items.firstOrNull { "cover-image" in it.attr("properties").split(Regex("\\s+")) },
            items.firstOrNull { it.id() == legacy },
            doc.selectFirst("guide > reference[type=cover]"),
            items.firstOrNull { it.id().equals("cover", true) || it.attr("href").substringAfterLast('/').substringBeforeLast('.').equals("cover", true) },
        )
        val firstPage = items.firstOrNull { it.id() == first }
        for (item in (declared + listOfNotNull(firstPage)).distinct()) {
            val path = resolve(packagePath, item.attr("href")) ?: continue
            val ext = path.substringAfterLast('.').lowercase()
            if (ext in setOf("xhtml", "htm", "html", "svg") || item.attr("media-type").contains("html")) {
                val page = parse(zip.bytes(path, MAX_METADATA) ?: continue)
                if (item !in declared &&
                    page.selectFirst("body")?.text()?.isNotBlank() == true) continue
                val image = page.selectFirst("img, image") ?: continue
                val href = listOf("src", "href", "xlink:href").firstNotNullOfOrNull { image.attr(it).takeIf(String::isNotBlank) } ?: continue
                val imagePath = resolve(path, href) ?: continue
                zip.bytes(imagePath, MAX_IMAGE)?.let { return it }
            } else if (item.attr("media-type").startsWith("image/") || ext in setOf("jpg", "jpeg", "png", "gif", "webp")) {
                zip.bytes(path, MAX_IMAGE)?.let { return it }
            }
        }
        return null
    }

    private fun fictionBook(file: File): ByteArray? {
        if (file.length() !in 1L..MAX_IMAGE.toLong()) return null
        val doc = file.inputStream().use { Jsoup.parse(it, null, "", Parser.xmlParser()) }
        val cover = doc.selectFirst("title-info > coverpage > image") ?: return null
        val ref = cover.attributes().firstOrNull { it.key.substringAfter(':') == "href" }?.value ?: return null
        if (!ref.startsWith('#') || ref.length < 2) return null
        val binary = doc.select("binary").firstOrNull { it.id() == ref.drop(1) } ?: return null
        return Base64.getMimeDecoder().decode(binary.text())
    }
}
