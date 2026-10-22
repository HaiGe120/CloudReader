package io.github.haige120.cloudreader.sync

import io.github.haige120.cloudreader.domain.BookFormat
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.BookTombstone
import io.github.haige120.cloudreader.domain.ChatMessage
import io.github.haige120.cloudreader.domain.ChatRecord
import io.github.haige120.cloudreader.domain.ConversationJsonAdapter
import io.github.haige120.cloudreader.domain.ConversationTombstone
import io.github.haige120.cloudreader.domain.canonicalUUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.put

object SyncCodec {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }

    fun bookToJson(book: BookRecord): JsonObject = buildJsonObject {
        parseObject(book.unknownJson).filterKeys { it !in BOOK_KEYS }.forEach { (key, value) -> put(key, value) }
        put("id", canonicalUUID(book.id)); put("title", book.title)
        book.author?.let { put("author", it) }
        book.briefDescription?.let { put("briefDescription", it) }
        put("fileName", book.fileName)
        put("format", BookFormat.fromExtension(book.format)?.extension ?: error("Unsupported book format"))
        put("addedAt", book.addedAt)
        book.lastOpenedAt?.let { put("lastOpenedAt", it) }
        put("progress", book.progress); put("isBookmarked", book.isBookmarked); put("modifiedAt", book.modifiedAt)
    }

    fun bookFromJson(obj: JsonObject): BookRecord {
        val id = canonicalUUID(obj.string("id"))
        val format = obj.string("format").lowercase()
        require(BookFormat.fromExtension(format) != null) { "Unknown book format: $format" }
        val name = obj.string("fileName")
        require(name.matches(Regex("[A-Za-z0-9._-]{1,160}")) && !name.contains("..")) { "Unsafe book filename" }
        val addedAt = obj.number("addedAt")
        val known = BOOK_KEYS
        return BookRecord(
            id = id, title = obj.string("title"), author = obj.optString("author"),
            briefDescription = obj.optString("briefDescription"), fileName = name, format = format,
            addedAt = addedAt, lastOpenedAt = obj.optNumber("lastOpenedAt"),
            progress = (obj.optNumber("progress") ?: 0.0).also { require(it in 0.0..1.0) { "Invalid reading progress" } },
            isBookmarked = obj["isBookmarked"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: false,
            modifiedAt = obj.optNumber("modifiedAt") ?: obj.optNumber("lastOpenedAt") ?: addedAt,
            unknownJson = json.encodeToString(JsonObject.serializer(), JsonObject(obj.filterKeys { it !in known })),
        )
    }

    fun chatToJson(chat: ChatRecord): JsonObject = ConversationJsonAdapter.encode(chat)

    fun chatFromJson(value: String): ChatRecord = ConversationJsonAdapter.decode(value)

    fun chatFromJson(obj: JsonObject): ChatRecord = ConversationJsonAdapter.decode(obj)

    fun mergeChats(a: ChatRecord, b: ChatRecord): ChatRecord {
        return MergePolicy.mergeChats(a, b)
    }

    fun manifestToJson(manifest: SyncManifest): JsonObject = buildJsonObject {
        manifest.unknown.filterKeys { it !in ROOT_KEYS }.forEach { (key, value) -> put(key, value) }
        put("schemaVersion", manifest.schemaVersion); put("updatedAt", manifest.updatedAt)
        put("books", buildJsonArray { manifest.books.forEach { item ->
            add(buildJsonObject {
                item.unknown.filterKeys { it !in BOOK_ITEM_KEYS }.forEach { (key, value) -> put(key, value) }
                put("book", bookToJson(item.book)); put("sha256", item.sha256)
            })
        } })
        put("deletions", buildJsonArray { manifest.deletions.forEach { add(tombstoneJson(it)) } })
        put("conversations", buildJsonArray { manifest.conversations.forEach { add(chatToJson(it)) } })
        put("conversationDeletions", buildJsonArray { manifest.conversationDeletions.forEach { add(chatTombstoneJson(it)) } })
    }

    fun manifestFromJson(bytes: ByteArray): SyncManifest {
        val root = json.parseToJsonElement(bytes.decodeToString()).jsonObject
        val version = root["schemaVersion"]?.jsonPrimitive?.contentOrNull?.toIntOrNull() ?: 1
        require(version == 1) { "Unsupported CloudReader sync version: $version" }
        return SyncManifest(
            schemaVersion = version, updatedAt = root.optNumber("updatedAt") ?: 0.0,
            books = root["books"]?.jsonArray?.map { item ->
                val itemObject = item.jsonObject
                val digest = itemObject.string("sha256")
                require(digest.matches(Regex("[0-9a-f]{64}"))) { "Invalid SHA-256 value" }
                SyncedBook(
                    bookFromJson(itemObject["book"]!!.jsonObject), digest,
                    JsonObject(itemObject.filterKeys { it !in BOOK_ITEM_KEYS }),
                )
            } ?: emptyList(),
            deletions = root["deletions"]?.jsonArray?.map { parseBookTombstone(it.jsonObject) } ?: emptyList(),
            conversations = root["conversations"]?.jsonArray?.map { chatFromJson(it.jsonObject) } ?: emptyList(),
            conversationDeletions = root["conversationDeletions"]?.jsonArray?.map { parseChatTombstone(it.jsonObject) } ?: emptyList(),
            unknown = JsonObject(root.filterKeys { it !in ROOT_KEYS }),
        )
    }

    fun bookObjectName(book: BookRecord): String = "book-${canonicalUUID(book.id)}.${book.format.lowercase()}"

    fun parseBookTombstone(obj: JsonObject) = BookTombstone(
        canonicalUUID(obj.string("bookID")), obj.number("deletedAt"),
        json.encodeToString(JsonObject.serializer(), JsonObject(obj.filterKeys { it !in BOOK_TOMBSTONE_KEYS })),
    )
    fun tombstoneJson(item: BookTombstone) = buildJsonObject {
        parseObject(item.unknownJson).filterKeys { it !in BOOK_TOMBSTONE_KEYS }.forEach { (key, value) -> put(key, value) }
        put("bookID", canonicalUUID(item.bookID)); put("deletedAt", item.deletedAt)
    }
    fun parseChatTombstone(obj: JsonObject) = ConversationTombstone(
        canonicalUUID(obj.string("conversationID")), obj.number("deletedAt"),
        json.encodeToString(JsonObject.serializer(), JsonObject(obj.filterKeys { it !in CHAT_TOMBSTONE_KEYS })),
    )
    fun chatTombstoneJson(item: ConversationTombstone) = buildJsonObject {
        parseObject(item.unknownJson).filterKeys { it !in CHAT_TOMBSTONE_KEYS }.forEach { (key, value) -> put(key, value) }
        put("conversationID", canonicalUUID(item.conversationID)); put("deletedAt", item.deletedAt)
    }

    private fun parseObject(value: String): JsonObject = runCatching { json.parseToJsonElement(value).jsonObject }.getOrDefault(JsonObject(emptyMap()))
    private fun JsonObject.string(key: String): String = this[key]?.jsonPrimitive?.contentOrNull ?: error("Missing $key")
    private fun JsonObject.optString(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.number(key: String): Double = (this[key]?.jsonPrimitive?.doubleOrNull ?: error("Missing or invalid $key"))
        .also { require(it.isFinite()) { "Non-finite $key" } }
    private fun JsonObject.optNumber(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull?.also {
        require(it.isFinite()) { "Non-finite $key" }
    }

    private val BOOK_KEYS = setOf("id", "title", "author", "briefDescription", "fileName", "format", "addedAt", "lastOpenedAt", "progress", "isBookmarked", "modifiedAt")
    private val BOOK_TOMBSTONE_KEYS = setOf("bookID", "deletedAt")
    private val CHAT_TOMBSTONE_KEYS = setOf("conversationID", "deletedAt")
    private val BOOK_ITEM_KEYS = setOf("book", "sha256")
    private val ROOT_KEYS = setOf("schemaVersion", "updatedAt", "books", "deletions", "conversations", "conversationDeletions")
}

data class SyncedBook(val book: BookRecord, val sha256: String, val unknown: JsonObject = JsonObject(emptyMap()))
data class SyncManifest(
    val schemaVersion: Int = 1,
    val updatedAt: Double = 0.0,
    val books: List<SyncedBook> = emptyList(),
    val deletions: List<BookTombstone> = emptyList(),
    val conversations: List<ChatRecord> = emptyList(),
    val conversationDeletions: List<ConversationTombstone> = emptyList(),
    val unknown: JsonObject = JsonObject(emptyMap()),
)
