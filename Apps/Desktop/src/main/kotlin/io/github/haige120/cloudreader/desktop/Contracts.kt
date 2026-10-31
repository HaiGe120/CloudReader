package io.github.haige120.cloudreader.desktop

import java.nio.charset.StandardCharsets
import java.nio.file.Files
import java.nio.file.Path
import java.util.Properties
import java.time.Instant
import java.util.UUID

@JvmInline
value class BookId(val value: String)

enum class BookFormat(val extension: String) {
    TXT("txt"),
    PDF("pdf"),
    EPUB("epub"),
    FB2("fb2"),
    CBZ("cbz"),
    CBR("cbr"),
    MOBI("mobi"),
    AZW3("azw3"),
    UNKNOWN("");

    companion object {
        fun from(path: Path): BookFormat = when (path.fileName.toString().substringAfterLast('.', "").lowercase()) {
            "txt" -> TXT
            "pdf" -> PDF
            "epub" -> EPUB
            "fb2" -> FB2
            "cbz" -> CBZ
            "cbr" -> CBR
            "mobi" -> MOBI
            "azw3" -> AZW3
            else -> UNKNOWN
        }
    }
}

data class BookRecord(
    val id: BookId,
    val title: String,
    val format: BookFormat,
    val sourcePath: Path,
    val importedAt: Instant,
    val textOffset: Int = 0,
    val isFavorite: Boolean = false,
    val progress: Double = 0.0,
    val lastOpenedAt: Double? = null,
    val modifiedAt: Double = importedAt.epochSecond.toDouble() - 978_307_200.0,
    val author: String? = null,
    val localLocation: String? = null,
    val unknownJson: String = "{}",
)

fun BookRecord.portable() = io.github.haige120.cloudreader.core.model.BookRecord(
    io.github.haige120.cloudreader.core.model.canonicalUUID(id.value), title, author, fileName = sourcePath.fileName.toString(), format = format.extension,
    addedAt = importedAt.toEpochMilli() / 1000.0 - 978_307_200.0, lastOpenedAt = lastOpenedAt,
    progress = progress, isBookmarked = isFavorite, modifiedAt = modifiedAt,
    localLocation = localLocation ?: if (textOffset > 0) "txt:$textOffset" else null, unknownJson = unknownJson,
)

interface LibraryRepository {
    fun books(): List<BookRecord>
    fun importBook(path: Path): ImportResult
    fun updateProgress(id: BookId, textOffset: Int): BookRecord?
    fun setFavorite(id: BookId, favorite: Boolean): BookRecord?
}

sealed interface ImportResult {
    data class Imported(val book: BookRecord) : ImportResult
    data class Unsupported(val format: BookFormat, val message: String) : ImportResult
    data class Failed(val message: String, val cause: Throwable? = null) : ImportResult
}

interface ReaderDocument : AutoCloseable {
    val book: BookRecord
    val text: String
}

interface ContentReader {
    fun supports(format: BookFormat): Boolean
    fun open(book: BookRecord): ReaderDocument
}

interface CredentialStore {
    fun read(service: String, account: String): String?
    fun write(service: String, account: String, secret: String)
    fun delete(service: String, account: String)
}

interface FilePicker {
    fun pickBook(): Path?
}

interface DropTarget {
    fun accept(paths: List<Path>): List<ImportResult>
}

class UnsupportedCredentialStore(private val reason: String) : CredentialStore {
    override fun read(service: String, account: String): String? = null
    override fun write(service: String, account: String, secret: String) =
        error("OS credential storage unavailable: $reason")
    override fun delete(service: String, account: String) = Unit
}

/**
 * Explicit opt-in fallback for systems without a supported OS secret service.
 * The normal entry point keeps this disabled and Settings must disclose the
 * local plaintext storage before enabling it.
 */
class OptInPlaintextCredentialStore(private val file: Path, enabled: Boolean) : CredentialStore {
    private val properties = Properties()

    init {
        check(enabled) { "Plaintext credential storage is disabled by default; enable it explicitly in Settings." }
        file.parent?.let { Files.createDirectories(it) }
        if (Files.exists(file)) Files.newBufferedReader(file, StandardCharsets.UTF_8).use { properties.load(it) }
        restrictToCurrentUser()
    }

    override fun read(service: String, account: String): String? = properties.getProperty("$service|$account")

    override fun write(service: String, account: String, secret: String) {
        properties.setProperty("$service|$account", secret)
        Files.newBufferedWriter(file, StandardCharsets.UTF_8).use { properties.store(it, "Explicitly opted-in CloudReader credentials") }
        restrictToCurrentUser()
    }

    override fun delete(service: String, account: String) {
        properties.remove("$service|$account")
        Files.newBufferedWriter(file, StandardCharsets.UTF_8).use { properties.store(it, "Explicitly opted-in CloudReader credentials") }
        restrictToCurrentUser()
    }

    private fun restrictToCurrentUser() {
        runCatching {
            val permissions = java.nio.file.attribute.PosixFilePermissions.fromString("rw-------")
            Files.setPosixFilePermissions(file, permissions)
        }
    }
}

class MemoryCredentialStore : CredentialStore {
    private val values = mutableMapOf<Pair<String, String>, String>()
    override fun read(service: String, account: String): String? = values[service to account]
    override fun write(service: String, account: String, secret: String) { values[service to account] = secret }
    override fun delete(service: String, account: String) { values.remove(service to account) }
}

fun newBookId(): BookId = BookId(UUID.randomUUID().toString())
