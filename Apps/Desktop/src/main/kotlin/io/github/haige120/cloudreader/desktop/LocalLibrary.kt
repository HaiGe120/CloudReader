package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.contract.SyncCodec
import io.github.haige120.cloudreader.core.contract.SyncManifest
import io.github.haige120.cloudreader.core.contract.SyncedBook
import io.github.haige120.cloudreader.core.model.*
import java.nio.charset.StandardCharsets
import java.nio.file.*
import java.security.MessageDigest
import java.time.Instant
import java.util.Properties

/** Existing properties metadata remains readable; all replacements are staged in the same directory. */
class FileLibraryRepository(private val root: Path) : LibraryRepository, DropTarget {
    private val metadataDir = root.resolve("metadata")
    private val contentDir = root.resolve("content")
    private val stateFile = root.resolve("portable-state.json")
    private var state: SyncManifest
    init {
        Files.createDirectories(metadataDir); Files.createDirectories(contentDir)
        state = if (Files.exists(stateFile)) SyncCodec.manifestFromJson(Files.readAllBytes(stateFile)) else SyncManifest()
    }

    @Synchronized override fun books(): List<BookRecord> = Files.list(metadataDir).use { files ->
        files.iterator().asSequence().filter { it.fileName.toString().endsWith(".properties") }
            .mapNotNull(::readMetadata).filter { record -> state.deletions.none { it.bookID.equals(record.id.value, true) && it.deletedAt >= record.modifiedAt } }.sortedByDescending { it.lastOpenedAt ?: it.importedAt.epochSecond.toDouble() - 978_307_200.0 }.toList()
    }

    @Synchronized override fun importBook(path: Path): ImportResult {
        if (!Files.isRegularFile(path)) return ImportResult.Failed("The selected path is not a file")
        val format = BookFormat.from(path)
        if (format == BookFormat.UNKNOWN) return ImportResult.Unsupported(format, "This file format is not supported.")
        var installed: Path? = null
        return try {
            val id = newBookId()
            val target = contentDir.resolve(PortableContractBridge.objectName(id, format))
            val stage = Files.createTempFile(contentDir, "import-", ".tmp")
            try { Files.copy(path, stage, StandardCopyOption.REPLACE_EXISTING); replace(stage, target) }
            finally { Files.deleteIfExists(stage) }
            installed = target
            val book = BookRecord(id, path.fileName.toString().substringBeforeLast('.'), format, target, Instant.now())
            writeMetadata(book)
            ImportResult.Imported(book)
        } catch (failure: Exception) {
            installed?.let { Files.deleteIfExists(it) }
            ImportResult.Failed("Could not import ${path.fileName}: ${failure.message}", failure)
        }
    }
    override fun accept(paths: List<Path>): List<ImportResult> = paths.map(::importBook)

    @Synchronized fun seedDemo() {
        val id=BookId("0E7B7B49-9652-4E82-BA2E-84F58CC90D46")
        if (books().any { it.id.value.equals(id.value,true) } || state.deletions.any { it.bookID == id.value }) return
        val input=javaClass.getResourceAsStream("/CloudReader_Field_Guide.txt") ?: return
        val target=contentDir.resolve("book-${id.value}.txt")
        if (!Files.exists(target)) input.use { atomicWrite(target,it.readBytes()) } else input.close()
        writeMetadata(BookRecord(id,"The Open Shelf",BookFormat.TXT,target,Instant.parse("2026-01-01T00:00:00Z"),author="The CloudReader Project"))
    }

    @Synchronized override fun updateProgress(id: BookId, textOffset: Int): BookRecord? {
        val current = books().firstOrNull { it.id.value.equals(id.value, true) } ?: return null
        val length = Files.newBufferedReader(current.sourcePath).use { reader ->
            var n = 0; val buffer = CharArray(8192)
            while (true) { val count = reader.read(buffer); if (count < 0) break; n += count }; n
        }
        val offset = textOffset.coerceIn(0, length)
        return current.copy(textOffset = offset, progress = if (length == 0) 0.0 else offset.toDouble() / length,
            localLocation = "txt:$offset", modifiedAt = nowFoundationSeconds()).also(::writeMetadata)
    }
    @Synchronized fun savePosition(id: BookId, progress: Double, location: String): BookRecord? {
        require(progress.isFinite())
        val current = books().firstOrNull { it.id.value.equals(id.value, true) } ?: return null
        return current.copy(progress = progress.coerceIn(0.0, 1.0), localLocation = location,
            textOffset = location.removePrefix("txt:").toIntOrNull() ?: current.textOffset,
            modifiedAt = nowFoundationSeconds()).also(::writeMetadata)
    }
    @Synchronized fun opened(id: BookId): BookRecord? {
        val current = books().firstOrNull { it.id.value.equals(id.value, true) } ?: return null
        val now = nowFoundationSeconds()
        return current.copy(lastOpenedAt = now, modifiedAt = now).also(::writeMetadata)
    }
    @Synchronized override fun setFavorite(id: BookId, favorite: Boolean): BookRecord? {
        val current = books().firstOrNull { it.id.value.equals(id.value, true) } ?: return null
        return current.copy(isFavorite = favorite, modifiedAt = nowFoundationSeconds()).also(::writeMetadata)
    }
    @Synchronized fun remove(id: BookId) {
        val current = books().firstOrNull { it.id.value.equals(id.value, true) } ?: return
        persistState(state.copy(deletions = state.deletions.filterNot { it.bookID.equals(id.value, true) } + BookTombstone(canonicalUUID(id.value), nowFoundationSeconds())))
        Files.deleteIfExists(metadataPath(id))
        Files.deleteIfExists(current.sourcePath)
    }
    @Synchronized fun chats(): List<ChatRecord> = state.conversations.sortedByDescending { it.modifiedAt }
    @Synchronized fun saveChat(chat: ChatRecord) = persistState(state.copy(conversations = state.conversations.filterNot { it.id == chat.id } + chat))
    @Synchronized fun removeChat(id: String) = persistState(state.copy(
        conversations = state.conversations.filterNot { it.id.equals(id, true) },
        conversationDeletions = state.conversationDeletions.filterNot { it.conversationID == id } + ConversationTombstone(id, nowFoundationSeconds())))

    @Synchronized fun manifest(): SyncManifest {
        val deleted = state.deletions.associateBy { it.bookID }
        val records = books().filter { (deleted[canonicalUUID(it.id.value)]?.deletedAt ?: Double.NEGATIVE_INFINITY) < it.modifiedAt }
        return state.copy(updatedAt = nowFoundationSeconds(), books = records.map { record ->
            val old = state.books.firstOrNull { it.book.id.equals(record.id.value, true) }
            SyncedBook(record.portable(), sha256(record.sourcePath), old?.unknown ?: kotlinx.serialization.json.JsonObject(emptyMap()))
        })
    }
    /** Content is verified and installed before publishing its metadata; missing bytes retain local state. */
    @Synchronized fun installManifest(merged: SyncManifest, downloaded: Map<String, ByteArray>) {
        val current = books().associateBy { canonicalUUID(it.id.value) }
        merged.books.forEach { item ->
            val name = SyncCodec.bookObjectName(item.book)
            val destination = contentDir.resolve(name)
            downloaded[item.book.id]?.let { bytes ->
                require(digest(bytes) == item.sha256) { "Downloaded book has an invalid hash." }
                atomicWrite(destination, bytes)
            }
            val local = current[item.book.id]
            val source = when {
                Files.isRegularFile(destination) && sha256(destination) == item.sha256 -> destination
                local != null && Files.isRegularFile(local.sourcePath) && sha256(local.sourcePath) == item.sha256 -> local.sourcePath
                else -> error("Book content is unavailable; sync metadata was not committed.")
            }
            val p = item.book
            // Device-only anchors describe the previous progress. A newer remote
            // position must resume by its portable fraction, not a stale anchor.
            val retainAnchor = local != null && kotlin.math.abs(local.progress - p.progress) < 1e-9
            val format = BookFormat.entries.first { it.extension == p.format }
            writeMetadata(BookRecord(BookId(p.id), p.title, format, source, Instant.ofEpochMilli(((p.addedAt + 978_307_200.0) * 1000).toLong()),
                textOffset = if (retainAnchor) local!!.textOffset else 0, isFavorite = p.isBookmarked, progress = p.progress, lastOpenedAt = p.lastOpenedAt,
                modifiedAt = p.modifiedAt, author = p.author, localLocation = if (retainAnchor) local!!.localLocation else null, unknownJson = p.unknownJson))
        }
        persistState(merged)
        merged.deletions.forEach { deletion ->
            current[deletion.bookID]?.takeIf { it.modifiedAt <= deletion.deletedAt }?.let {
                Files.deleteIfExists(metadataPath(it.id)); Files.deleteIfExists(it.sourcePath)
            }
        }
    }
    fun content(bookID: String): Path = books().firstOrNull { it.id.value.equals(bookID, true) }?.sourcePath ?: error("Book missing")

    private fun metadataPath(id: BookId): Path = metadataDir.resolve("${java.util.UUID.fromString(id.value)}.properties")
    private fun writeMetadata(book: BookRecord) {
        val properties = Properties().apply {
            setProperty("id", book.id.value); setProperty("title", book.title); setProperty("format", book.format.name)
            setProperty("sourcePath", book.sourcePath.toString()); setProperty("importedAt", book.importedAt.toString())
            setProperty("textOffset", book.textOffset.toString()); setProperty("isFavorite", book.isFavorite.toString())
            setProperty("progress", book.progress.toString()); setProperty("modifiedAt", book.modifiedAt.toString())
            book.lastOpenedAt?.let { setProperty("lastOpenedAt", it.toString()) }; book.author?.let { setProperty("author", it) }
            book.localLocation?.let { setProperty("localLocation", it) }; setProperty("unknownJson", book.unknownJson)
        }
        val writer = java.io.StringWriter().also { properties.store(it, "CloudReader device-local metadata") }
        atomicWrite(metadataPath(book.id), writer.toString().toByteArray(StandardCharsets.UTF_8))
    }
    private fun readMetadata(path: Path): BookRecord? = runCatching {
        val p = Properties().apply { Files.newBufferedReader(path, StandardCharsets.UTF_8).use(::load) }
        val source = Path.of(p.getProperty("sourcePath")).toAbsolutePath().normalize()
        require(source.startsWith(contentDir.toAbsolutePath().normalize())) { "Local metadata points outside the library." }
        val imported = Instant.parse(p.getProperty("importedAt"))
        BookRecord(BookId(p.getProperty("id")), p.getProperty("title"), BookFormat.valueOf(p.getProperty("format")), source, imported,
            p.getProperty("textOffset", "0").toInt(), p.getProperty("isFavorite", "false").toBoolean(), p.getProperty("progress", "0").toDouble(),
            p.getProperty("lastOpenedAt")?.toDouble(), p.getProperty("modifiedAt")?.toDouble() ?: imported.epochSecond.toDouble() - 978_307_200.0,
            p.getProperty("author"), p.getProperty("localLocation"), p.getProperty("unknownJson", "{}"))
    }.getOrNull()
    private fun persistState(value: SyncManifest) { atomicWrite(stateFile, SyncCodec.manifestToBytes(value)); state = value }
}

internal fun atomicWrite(path: Path, bytes: ByteArray) {
    Files.createDirectories(path.parent)
    val stage = Files.createTempFile(path.parent, ".cloudreader-", ".tmp")
    try {
        java.io.FileOutputStream(stage.toFile()).use { it.write(bytes); it.fd.sync() }
        replace(stage, path)
    } finally { Files.deleteIfExists(stage) }
}
internal fun replace(stage: Path, destination: Path) {
    try { Files.move(stage, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE) }
    catch (_: AtomicMoveNotSupportedException) { Files.move(stage, destination, StandardCopyOption.REPLACE_EXISTING) }
}
internal fun digest(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }
internal fun sha256(path: Path): String {
    val hash = MessageDigest.getInstance("SHA-256")
    Files.newInputStream(path).use { input -> val b = ByteArray(64 * 1024); while (true) { val n = input.read(b); if (n < 0) break; hash.update(b, 0, n) } }
    return hash.digest().joinToString("") { "%02x".format(it) }
}
class TxtContentReader : ContentReader {
    override fun supports(format: BookFormat) = format == BookFormat.TXT
    override fun open(book: BookRecord): ReaderDocument {
        require(supports(book.format)); require(Files.size(book.sourcePath) <= 32 * 1024 * 1024) { "This text file exceeds the reader limit." }
        val bytes = Files.readAllBytes(book.sourcePath)
        val content = when {
            bytes.size >= 2 && bytes[0] == 0xff.toByte() && bytes[1] == 0xfe.toByte() -> String(bytes,2,bytes.size-2,Charsets.UTF_16LE)
            bytes.size >= 2 && bytes[0] == 0xfe.toByte() && bytes[1] == 0xff.toByte() -> String(bytes,2,bytes.size-2,Charsets.UTF_16BE)
            else -> bytes.toString(Charsets.UTF_8).removePrefix("\uFEFF")
        }
        return object : ReaderDocument { override val book = book; override val text = content; override fun close() = Unit }
    }
}
