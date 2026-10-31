package io.github.haige120.cloudreader.core.reader

import java.io.File
import java.io.InputStream
import java.net.URI
import java.nio.file.Files
import java.util.UUID
import java.util.zip.ZipFile
import org.jsoup.Jsoup
import org.jsoup.nodes.Element
import org.jsoup.parser.Parser
import org.jsoup.safety.Safelist

data class PublicationChapter(val title: String, val file: File)
data class PreparedPublication(val root: File, val chapters: List<PublicationChapter> = emptyList(), val images: List<File> = emptyList())

/** Bounded, script-free preparation shared by Android and desktop. Imported bytes are never modified. */
object PublicationLoader {
    private const val MAX_ENTRY = 64L * 1024 * 1024
    private const val MAX_TOTAL = 1024L * 1024 * 1024
    private const val MAX_XML = 16 * 1024 * 1024
    private val natural = Comparator<String> { a, b ->
        val x = Regex("[0-9]+|[^0-9]+").findAll(a.lowercase()).map { it.value }.toList()
        val y = Regex("[0-9]+|[^0-9]+").findAll(b.lowercase()).map { it.value }.toList()
        for (i in 0 until minOf(x.size, y.size)) {
            val p = x[i]; val q = y[i]
            val result = if (p.first().isDigit() && q.first().isDigit()) {
                val pn = p.trimStart('0').ifEmpty { "0" }; val qn = q.trimStart('0').ifEmpty { "0" }
                pn.length.compareTo(qn.length).takeIf { it != 0 } ?: pn.compareTo(qn)
            } else p.compareTo(q)
            if (result != 0) return@Comparator result
        }
        x.size.compareTo(y.size).takeIf { it != 0 } ?: a.compareTo(b)
    }

    fun prepare(source: File, cache: File, format: String = source.extension.lowercase()): PreparedPublication {
        require(source.isFile) { "The local book is missing." }
        require(format in listOf("epub", "fb2", "cbz")) { "No reader is enabled for ${format.uppercase()}." }
        cache.mkdirs()
        val stage = File(cache, "publication-${UUID.randomUUID()}").canonicalFile
        check(stage.mkdirs()) { "Could not create reader cache." }
        try {
            return when (format) {
                "fb2" -> fb2(source, stage)
                else -> {
                    unpack(source, stage)
                    if (format == "cbz") {
                        val images = stage.walkTopDown().filter { it.isFile && it.extension.lowercase() in listOf("jpg", "jpeg", "png", "gif", "webp") }
                            .sortedWith { a, b -> natural.compare(a.relativeTo(stage).path, b.relativeTo(stage).path) }.toList()
                        require(images.isNotEmpty()) { "This comic has no supported images." }
                        PreparedPublication(stage, images = images)
                    } else epub(stage)
                }
            }
        } catch (failure: Throwable) {
            stage.deleteRecursively()
            throw failure
        }
    }

    private fun unpack(source: File, root: File) {
        var total = 0L
        ZipFile(source).use { archive ->
            require(archive.size() <= 10_000) { "The archive contains too many entries." }
            val names = HashSet<String>()
            archive.entries().asSequence().forEach { entry ->
                check(!Thread.currentThread().isInterrupted) { "Reader preparation cancelled." }
                val target = safeFile(root, entry.name)
                require(names.add(target.canonicalPath)) { "The archive contains duplicate paths." }
                require(entry.size <= MAX_ENTRY) { "An archive entry exceeds the size limit." }
                if (entry.isDirectory) { check(target.isDirectory || target.mkdirs()); return@forEach }
                check(target.parentFile.isDirectory || target.parentFile.mkdirs())
                var entryBytes = 0L
                archive.getInputStream(entry).use { input -> target.outputStream().use { output ->
                    val buffer = ByteArray(32 * 1024)
                    while (true) {
                        check(!Thread.currentThread().isInterrupted) { "Reader preparation cancelled." }
                        val count = input.read(buffer); if (count < 0) break
                        entryBytes += count; total += count
                        require(entryBytes <= MAX_ENTRY && total <= MAX_TOTAL) { "The archive expands beyond the reader limit." }
                        output.write(buffer, 0, count)
                    }
                } }
            }
        }
    }

    private fun epub(root: File): PreparedPublication {
        val encryption = File(root, "META-INF/encryption.xml")
        if (encryption.isFile) {
            val allowed = setOf("http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC")
            require(xml(encryption).getAllElements().filter { it.tagName().substringAfter(':') == "EncryptionMethod" }.all { it.attr("Algorithm") in allowed }) { "DRM-protected EPUB resources are not supported." }
        }
        require(!File(root, "META-INF/rights.xml").isFile) { "DRM-protected EPUBs are not supported." }
        val container = xml(File(root, "META-INF/container.xml"))
        val packagePath = container.getAllElements().firstOrNull { it.tagName().substringAfter(':') == "rootfile" }?.attr("full-path")
            ?.takeIf { it.isNotBlank() } ?: error("The EPUB package is missing.")
        val packageFile = safeFile(root, packagePath)
        val packageDoc = xml(packageFile)
        val manifest = packageDoc.getAllElements().filter { it.tagName().substringAfter(':') == "item" }.associateBy { it.attr("id") }
        val chapters = packageDoc.getAllElements().filter { it.tagName().substringAfter(':') == "itemref" }.map { ref ->
            val item = manifest[ref.attr("idref")] ?: error("The EPUB spine references a missing resource.")
            val relative = URI(item.attr("href")).path ?: error("Invalid EPUB resource path.")
            val chapter = safeFile(root, packageFile.parentFile.relativeTo(root).invariantSeparatorsPath.let { if (it == "") relative else "$it/$relative" })
            require(chapter.extension.lowercase() in listOf("html", "xhtml", "htm")) { "Fixed-layout and non-HTML EPUB chapters are not supported." }
            val document = Jsoup.parse(readBounded(chapter.inputStream()), chapter.toURI().toString())
            val title = document.selectFirst("h1,h2,title")?.text()?.takeIf { it.isNotBlank() } ?: "Chapter ${ref.elementSiblingIndex() + 1}"
            sanitize(document.body(), chapter, root)
            PublicationChapter(title, chapter)
        }
        require(chapters.isNotEmpty()) { "This EPUB has no readable chapters." }
        // Notes and linked HTML outside the spine must receive the same active-content policy.
        root.walkTopDown().filter { it.isFile && it.extension.lowercase() in listOf("html", "xhtml", "htm") && chapters.none { chapter -> chapter.file == it } }
            .forEach { file -> sanitize(Jsoup.parse(readBounded(file.inputStream()), file.toURI().toString()).body(), file, root) }
        return PreparedPublication(root, chapters)
    }

    private fun fb2(source: File, root: File): PreparedPublication {
        val document = xml(source)
        val binaries = document.getAllElements().filter { it.tagName().substringAfter(':') == "binary" }
        binaries.forEachIndexed { i, binary ->
            val data = java.util.Base64.getMimeDecoder().decode(binary.text())
            require(data.size <= MAX_ENTRY) { "An FB2 image exceeds the reader limit." }
            val ext = when (binary.attr("content-type")) { "image/png" -> "png"; "image/jpeg" -> "jpg"; "image/gif" -> "gif"; else -> return@forEachIndexed }
            File(root, "image-$i.$ext").writeBytes(data)
            document.getAllElements().filter { it.tagName().substringAfter(':') == "image" }.forEach { image ->
                val href = image.attributes().firstOrNull { it.key.substringAfter(':') == "href" }?.value
                if (href == "#${binary.id()}") image.tagName("img").attr("src", "image-$i.$ext")
            }
        }
        val bodies = document.getAllElements().filter { it.tagName().substringAfter(':') == "body" }
        require(bodies.isNotEmpty()) { "The FB2 has no readable body." }
        val chapters = bodies.mapIndexed { i, body ->
            body.getAllElements().toList().forEach { element ->
                when (element.tagName().substringAfter(':')) {
                    "title" -> element.tagName("h2")
                    "section", "body", "poem", "stanza" -> element.tagName("section")
                    "subtitle" -> element.tagName("h3")
                    "emphasis" -> element.tagName("em")
                    "strong" -> element.tagName("strong")
                    "v" -> element.tagName("p")
                    "empty-line" -> element.tagName("br")
                }
                element.attributes().firstOrNull { it.key.endsWith(":href") }?.let { element.attr("href", it.value) }
            }
            val title = body.selectFirst("h2,h3")?.text()?.takeIf { it.isNotBlank() } ?: "Part ${i + 1}"
            val target = File(root, "part-$i.html")
            sanitize(body, target, root)
            PublicationChapter(title, target)
        }
        return PreparedPublication(root, chapters)
    }

    private fun sanitize(body: Element, output: File, root: File) {
        body.select("script,style,iframe,object,embed,form,link,meta,svg,math").remove()
        body.select("img[src]").forEach { img ->
            val raw = img.attr("src")
            val resolved = runCatching {
                val uri = URI(raw)
                require(!uri.isAbsolute && uri.rawAuthority == null)
                safeFile(root, output.parentFile.relativeTo(root).invariantSeparatorsPath.let { if (it.isBlank()) uri.path else "$it/${uri.path}" })
            }.getOrNull()
            if (resolved == null || !resolved.isFile) img.remove() else img.attr("src", output.parentFile.toPath().relativize(resolved.toPath()).toString().replace('\\', '/'))
        }
        body.select("a[href]").forEach { a ->
            val href = a.attr("href")
            if (runCatching { URI(href).isAbsolute || URI(href).rawAuthority != null }.getOrDefault(true)) a.removeAttr("href")
        }
        val safe = Safelist.relaxed().addTags("section").addAttributes(":all", "id").addAttributes("a", "href").addAttributes("img", "src").preserveRelativeLinks(true)
            .removeProtocols("img", "src", "http", "https").removeProtocols("a", "href", "http", "https", "ftp", "mailto")
        // Relative references have already been restricted to this preparation directory.
        val cleaned = Jsoup.clean(body.html(), "", safe)
        output.writeText("<!doctype html><html><head><meta charset=\"utf-8\"></head><body>$cleaned</body></html>")
    }

    fun safeFile(root: File, name: String): File {
        require(name.isNotBlank() && !name.startsWith('/') && '\\' !in name && ':' !in name && '\u0000' !in name) { "Unsafe archive path." }
        val resolved = File(root, name).canonicalFile
        require(resolved.toPath().startsWith(root.canonicalFile.toPath()) && resolved != root.canonicalFile) { "Archive path escapes the reader cache." }
        return resolved
    }

    private fun xml(file: File) = Jsoup.parse(readBounded(file.inputStream()), "", Parser.xmlParser()).also {
        require(it.childNodes().none { node -> node.nodeName() == "#doctype" }) { "Document types are not allowed in book XML." }
    }
    private fun readBounded(input: InputStream): String = input.use {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val n = it.read(buffer)
            if (n < 0) break
            require(output.size() + n <= MAX_XML) { "A book chapter exceeds the reader limit." }
            output.write(buffer, 0, n)
        }
        val bytes = output.toByteArray()
        require(bytes.size <= MAX_XML) { "A book chapter exceeds the reader limit." }
        bytes.toString(Charsets.UTF_8).removePrefix("\uFEFF")
    }
}
