package io.github.haige120.cloudreader.desktop

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.Properties

/**
 * Small durable local store for the feasibility slice. Metadata is deliberately
 * private to the desktop adapter; portable schema and sync integration belong
 * to the future Kotlin contract module (D02).
 */
class FileLibraryRepository(private val root: Path) : LibraryRepository, DropTarget {
    private val metadataDir = root.resolve("metadata")
    private val contentDir = root.resolve("content")

    init {
        Files.createDirectories(metadataDir)
        Files.createDirectories(contentDir)
    }

    override fun books(): List<BookRecord> = Files.list(metadataDir).use { files ->
        files.filter { it.fileName.toString().endsWith(".properties") }
            .mapNotNull(::readMetadata)
            .sortedByDescending { it.importedAt }
            .toList()
    }

    override fun importBook(path: Path): ImportResult {
        if (!Files.isRegularFile(path)) return ImportResult.Failed("The selected path is not a file")
        val format = BookFormat.from(path)
        if (format != BookFormat.TXT) {
            return ImportResult.Unsupported(
                format,
                "${format.name} reading is reserved for a later desktop slice; this prototype imports TXT only.",
            )
        }
        return runCatching {
            val id = newBookId()
            val target = contentDir.resolve(PortableContractBridge.objectName(id, format))
            Files.copy(path, target, StandardCopyOption.REPLACE_EXISTING)
            val book = BookRecord(id, path.fileName.toString().substringBeforeLast('.'), format, target, Instant.now())
            writeMetadata(book)
            ImportResult.Imported(book)
        }.getOrElse { ImportResult.Failed("Could not import ${path.fileName}", it) }
    }

    override fun accept(paths: List<Path>): List<ImportResult> = paths.map(::importBook)

    override fun updateProgress(id: BookId, textOffset: Int): BookRecord? {
        val current = books().firstOrNull { it.id == id } ?: return null
        val length = runCatching { Files.readString(current.sourcePath, StandardCharsets.UTF_8).length }.getOrDefault(0)
        val updated = current.copy(textOffset = textOffset.coerceIn(0, length))
        writeMetadata(updated)
        return updated
    }

    override fun setFavorite(id: BookId, favorite: Boolean): BookRecord? {
        val current = books().firstOrNull { it.id == id } ?: return null
        return current.copy(isFavorite = favorite).also(::writeMetadata)
    }

    private fun metadataPath(id: BookId): Path = metadataDir.resolve("${id.value}.properties")

    private fun writeMetadata(book: BookRecord) {
        val properties = Properties().apply {
            setProperty("id", book.id.value)
            setProperty("title", book.title)
            setProperty("format", book.format.name)
            setProperty("sourcePath", book.sourcePath.toString())
            setProperty("importedAt", book.importedAt.toString())
            setProperty("textOffset", book.textOffset.toString())
            setProperty("isFavorite", book.isFavorite.toString())
        }
        Files.newBufferedWriter(metadataPath(book.id), StandardCharsets.UTF_8).use { properties.store(it, "CloudReader desktop prototype") }
    }

    private fun readMetadata(path: Path): BookRecord? = runCatching {
        val properties = Properties()
        Files.newBufferedReader(path, StandardCharsets.UTF_8).use { properties.load(it) }
        BookRecord(
            id = BookId(properties.getProperty("id")),
            title = properties.getProperty("title"),
            format = BookFormat.valueOf(properties.getProperty("format")),
            sourcePath = Path.of(properties.getProperty("sourcePath")),
            importedAt = Instant.parse(properties.getProperty("importedAt")),
            textOffset = properties.getProperty("textOffset", "0").toInt(),
            isFavorite = properties.getProperty("isFavorite", "false").toBoolean(),
        )
    }.getOrNull()
}

class TxtContentReader : ContentReader {
    override fun supports(format: BookFormat): Boolean = format == BookFormat.TXT

    override fun open(book: BookRecord): ReaderDocument {
        require(supports(book.format)) { "TXT reader cannot open ${book.format}" }
        val content = Files.readString(book.sourcePath, StandardCharsets.UTF_8)
        return object : ReaderDocument {
            override val book: BookRecord = book
            override val text: String = content
            override fun close() = Unit
        }
    }
}
