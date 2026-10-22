package io.github.haige120.cloudreader.domain

enum class BookFormat(val extension: String) {
    EPUB("epub"), PDF("pdf"), TXT("txt"), MOBI("mobi"), AZW3("azw3"), FB2("fb2"), CBZ("cbz"), CBR("cbr");

    val readable get() = this == EPUB || this == PDF || this == TXT

    companion object { fun fromExtension(value: String) = entries.firstOrNull { it.extension == value.lowercase() } }
}

/** Local library value. localLocation is device-only and is never emitted by the sync codec. */
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
    val bookFormat get() = BookFormat.fromExtension(format)
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
    val messages: List<ChatMessage>,
    val bookID: String? = null,
    val bookTitle: String? = null,
    val bookDescription: String? = null,
    val selectedText: String? = null,
    val bookContext: String? = null,
    val contextDescription: String? = null,
    val includeBookContext: Boolean = false,
    val createdAt: Double,
    val modifiedAt: Double,
    val unknownJson: String = "{}",
)

data class LibrarySnapshot(
    val books: List<BookRecord> = emptyList(),
    val bookDeletions: List<BookTombstone> = emptyList(),
    val conversations: List<ChatRecord> = emptyList(),
    val conversationDeletions: List<ConversationTombstone> = emptyList(),
)

fun nowFoundationSeconds(): Double = System.currentTimeMillis() / 1000.0 - 978_307_200.0
fun canonicalUUID(value: String): String {
    require(value.matches(Regex("(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"))) { "Invalid UUID: $value" }
    return java.util.UUID.fromString(value).toString().uppercase()
}

object DemoBook {
    const val ID = "0E7B7B49-9652-4E82-BA2E-84F58CC90D46"
    const val TITLE = "The Open Shelf"
    const val AUTHOR = "The CloudReader Project"
    const val ADDED_AT = 1_767_225_600.0 - 978_307_200.0
    const val DESCRIPTION = "An original field guide to CloudReader’s goals, reading experience, portable library, cloud sync, privacy, and reader-controlled AI."
}
