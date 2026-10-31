package io.github.haige120.cloudreader.core.model

/** Formats supported by the v1 portable book contract. */
enum class BookFormat(val extension: String) {
    EPUB("epub"), PDF("pdf"), TXT("txt"), MOBI("mobi"), AZW3("azw3"), FB2("fb2"), CBZ("cbz"), CBR("cbr");

    val hasNativeReader: Boolean get() = this == EPUB || this == PDF || this == TXT
    val readable: Boolean get() = hasNativeReader || this == FB2 || this == CBZ

    companion object {
        fun fromExtension(value: String): BookFormat? = entries.firstOrNull { it.extension == value.lowercase() }
    }
}

/** Portable library metadata. `localLocation` is device-only and never emitted by the codec. */
data class BookRecord(
    val id: String,
    val title: String,
    val author: String? = null,
    val briefDescription: String? = null,
    val fileName: String,
    val format: String,
    val addedAt: Double,
    val lastOpenedAt: Double? = null,
    val progress: Double = 0.0,
    val isBookmarked: Boolean = false,
    val modifiedAt: Double,
    val localLocation: String? = null,
    val unknownJson: String = "{}",
) {
    val bookFormat: BookFormat? get() = BookFormat.fromExtension(format)
}

data class BookTombstone(val bookID: String, val deletedAt: Double, val unknownJson: String = "{}")
data class ConversationTombstone(val conversationID: String, val deletedAt: Double, val unknownJson: String = "{}")

data class ChatMessage(
    val id: String,
    val role: String,
    val text: String,
    val createdAt: Double,
    val unknownJson: String = "{}",
)

data class ChatRecord(
    val id: String,
    val title: String,
    val messages: List<ChatMessage> = emptyList(),
    val bookID: String? = null,
    val bookTitle: String? = null,
    val bookDescription: String? = null,
    val selectedText: String? = null,
    val bookContext: String? = null,
    val contextDescription: String? = null,
    val includeBookContext: Boolean = false,
    val createdAt: Double = 0.0,
    val modifiedAt: Double = createdAt,
    val unknownJson: String = "{}",
)

data class LibrarySnapshot(
    val books: List<BookRecord> = emptyList(),
    val bookDeletions: List<BookTombstone> = emptyList(),
    val conversations: List<ChatRecord> = emptyList(),
    val conversationDeletions: List<ConversationTombstone> = emptyList(),
)

/** Foundation-reference-date seconds (2001-01-01T00:00:00Z), matching the v1 contract. */
fun nowFoundationSeconds(): Double = System.currentTimeMillis() / 1000.0 - 978_307_200.0

private val UUID_PATTERN = Regex("(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

/** Returns uppercase canonical UUID spelling and rejects malformed identifiers. */
fun canonicalUUID(value: String): String {
    require(UUID_PATTERN.matches(value)) { "Invalid UUID: $value" }
    return java.util.UUID.fromString(value).toString().uppercase()
}
