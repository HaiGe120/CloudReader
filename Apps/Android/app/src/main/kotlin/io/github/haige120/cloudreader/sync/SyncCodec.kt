package io.github.haige120.cloudreader.sync

import io.github.haige120.cloudreader.data.BookFormat
import io.github.haige120.cloudreader.data.BookRow
import io.github.haige120.cloudreader.data.BookTombstone
import io.github.haige120.cloudreader.data.ChatMessage
import io.github.haige120.cloudreader.data.ChatRecord
import io.github.haige120.cloudreader.data.ConversationTombstone
import io.github.haige120.cloudreader.data.canonicalUUID
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

    fun bookToJson(book: BookRow): JsonObject = buildJsonObject {
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

    fun bookFromJson(obj: JsonObject): BookRow {
        val id = canonicalUUID(obj.string("id"))
        val format = obj.string("format").lowercase()
        require(BookFormat.fromExtension(format) != null) { "Unknown book format: $format" }
        val name = obj.string("fileName")
        require(name.matches(Regex("[A-Za-z0-9._-]{1,160}")) && !name.contains("..")) { "Unsafe book filename" }
        val addedAt = obj.number("addedAt")
        val known = BOOK_KEYS
        return BookRow(
            id = id, title = obj.string("title"), author = obj.optString("author"),
            briefDescription = obj.optString("briefDescription"), fileName = name, format = format,
            addedAt = addedAt, lastOpenedAt = obj.optNumber("lastOpenedAt"),
            progress = (obj.optNumber("progress") ?: 0.0).coerceIn(0.0, 1.0),
            isBookmarked = obj["isBookmarked"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: false,
            modifiedAt = obj.optNumber("modifiedAt") ?: obj.optNumber("lastOpenedAt") ?: addedAt,
            unknownJson = json.encodeToString(JsonObject.serializer(), JsonObject(obj.filterKeys { it !in known })),
        )
    }

    fun chatToJson(chat: ChatRecord): JsonObject = buildJsonObject {
        parseObject(chat.unknownJson).filterKeys { it !in CHAT_KEYS }.forEach { (key, value) -> put(key, value) }
        put("id", canonicalUUID(chat.id)); put("title", chat.title)
        put("messages", buildJsonArray { chat.messages.forEach { add(messageToJson(it)) } })
        chat.bookID?.let { put("bookID", canonicalUUID(it)) }
        chat.bookTitle?.let { put("bookTitle", it) }
        chat.bookDescription?.let { put("bookDescription", it) }
        chat.selectedText?.let { put("selectedText", it) }
        chat.bookContext?.let { put("bookContext", it) }
        chat.contextDescription?.let { put("contextDescription", it) }
        put("includeBookContext", chat.includeBookContext)
        put("createdAt", chat.createdAt); put("modifiedAt", chat.modifiedAt)
    }

    fun chatFromJson(value: String): ChatRecord = chatFromJson(json.parseToJsonElement(value).jsonObject)

    fun chatFromJson(obj: JsonObject): ChatRecord {
        val messages = obj["messages"]?.jsonArray?.map { element ->
            val message = element.jsonObject
            ChatMessage(
                id = canonicalUUID(message.string("id")), role = message.string("role"),
                text = message.string("text"), createdAt = message.number("createdAt"),
                unknownJson = json.encodeToString(JsonObject.serializer(), JsonObject(message.filterKeys { it !in MESSAGE_KEYS })),
            )
        } ?: emptyList()
        val createdAt = obj.optNumber("createdAt") ?: messages.minOfOrNull { it.createdAt } ?: 0.0
        return ChatRecord(
            id = canonicalUUID(obj.string("id")), title = obj.string("title"), messages = messages,
            bookID = obj.optString("bookID")?.let(::canonicalUUID), bookTitle = obj.optString("bookTitle"),
            bookDescription = obj.optString("bookDescription"), selectedText = obj.optString("selectedText"),
            bookContext = obj.optString("bookContext"), contextDescription = obj.optString("contextDescription"),
            includeBookContext = obj["includeBookContext"]?.jsonPrimitive?.contentOrNull?.toBooleanStrictOrNull() ?: false,
            createdAt = createdAt, modifiedAt = obj.optNumber("modifiedAt") ?: createdAt,
            unknownJson = json.encodeToString(JsonObject.serializer(), JsonObject(obj.filterKeys { it !in CHAT_KEYS })),
        )
    }

    fun mergeChats(a: ChatRecord, b: ChatRecord): ChatRecord {
        val newest = if (a.modifiedAt >= b.modifiedAt) a else b
        val messages = (a.messages + b.messages).associateBy { it.id }.values.sortedWith(
            compareBy<ChatMessage> { it.createdAt }.thenBy { it.id }
        )
        return newest.copy(
            messages = messages, createdAt = minOf(a.createdAt, b.createdAt),
            modifiedAt = maxOf(a.modifiedAt, b.modifiedAt),
        )
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
                SyncedBook(
                    bookFromJson(itemObject["book"]!!.jsonObject), itemObject.string("sha256"),
                    JsonObject(itemObject.filterKeys { it !in BOOK_ITEM_KEYS }),
                )
            } ?: emptyList(),
            deletions = root["deletions"]?.jsonArray?.map { parseBookTombstone(it.jsonObject) } ?: emptyList(),
            conversations = root["conversations"]?.jsonArray?.map { chatFromJson(it.jsonObject) } ?: emptyList(),
            conversationDeletions = root["conversationDeletions"]?.jsonArray?.map { parseChatTombstone(it.jsonObject) } ?: emptyList(),
            unknown = JsonObject(root.filterKeys { it !in ROOT_KEYS }),
        )
    }

    fun bookObjectName(book: BookRow): String = "book-${canonicalUUID(book.id)}.${book.format.lowercase()}"

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

    private fun messageToJson(message: ChatMessage) = buildJsonObject {
        parseObject(message.unknownJson).filterKeys { it !in MESSAGE_KEYS }.forEach { (key, value) -> put(key, value) }
        put("id", canonicalUUID(message.id)); put("role", message.role); put("text", message.text); put("createdAt", message.createdAt)
    }
    private fun parseObject(value: String): JsonObject = runCatching { json.parseToJsonElement(value).jsonObject }.getOrDefault(JsonObject(emptyMap()))
    private fun JsonObject.string(key: String): String = this[key]?.jsonPrimitive?.contentOrNull ?: error("Missing $key")
    private fun JsonObject.optString(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.number(key: String): Double = this[key]?.jsonPrimitive?.doubleOrNull ?: error("Missing or invalid $key")
    private fun JsonObject.optNumber(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull

    private val BOOK_KEYS = setOf("id", "title", "author", "briefDescription", "fileName", "format", "addedAt", "lastOpenedAt", "progress", "isBookmarked", "modifiedAt")
    private val CHAT_KEYS = setOf("id", "title", "messages", "bookID", "bookTitle", "bookDescription", "selectedText", "bookContext", "contextDescription", "includeBookContext", "createdAt", "modifiedAt")
    private val MESSAGE_KEYS = setOf("id", "role", "text", "createdAt")
    private val BOOK_TOMBSTONE_KEYS = setOf("bookID", "deletedAt")
    private val CHAT_TOMBSTONE_KEYS = setOf("conversationID", "deletedAt")
    private val BOOK_ITEM_KEYS = setOf("book", "sha256")
    private val ROOT_KEYS = setOf("schemaVersion", "updatedAt", "books", "deletions", "conversations", "conversationDeletions")
}

data class SyncedBook(val book: BookRow, val sha256: String, val unknown: JsonObject = JsonObject(emptyMap()))
data class SyncManifest(
    val schemaVersion: Int = 1,
    val updatedAt: Double = 0.0,
    val books: List<SyncedBook> = emptyList(),
    val deletions: List<BookTombstone> = emptyList(),
    val conversations: List<ChatRecord> = emptyList(),
    val conversationDeletions: List<ConversationTombstone> = emptyList(),
    val unknown: JsonObject = JsonObject(emptyMap()),
)
