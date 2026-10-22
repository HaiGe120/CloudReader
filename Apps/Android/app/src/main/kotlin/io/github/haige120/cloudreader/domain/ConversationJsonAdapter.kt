package io.github.haige120.cloudreader.domain

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put

/** Shared JSON mapping for the persisted and synced conversation payload. */
object ConversationJsonAdapter {
    private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
    private val chatKeys = setOf("id", "title", "messages", "bookID", "bookTitle", "bookDescription", "selectedText", "bookContext", "contextDescription", "includeBookContext", "createdAt", "modifiedAt")
    private val messageKeys = setOf("id", "role", "text", "createdAt")

    fun encode(chat: ChatRecord): JsonObject = buildJsonObject {
        extras(chat.unknownJson, chatKeys).forEach { (key, value) -> put(key, value) }
        put("id", canonicalUUID(chat.id)); put("title", chat.title)
        put("messages", buildJsonArray { chat.messages.forEach { add(encodeMessage(it)) } })
        chat.bookID?.let { put("bookID", canonicalUUID(it)) }
        chat.bookTitle?.let { put("bookTitle", it) }
        chat.bookDescription?.let { put("bookDescription", it) }
        chat.selectedText?.let { put("selectedText", it) }
        chat.bookContext?.let { put("bookContext", it) }
        chat.contextDescription?.let { put("contextDescription", it) }
        put("includeBookContext", chat.includeBookContext)
        put("createdAt", chat.createdAt); put("modifiedAt", chat.modifiedAt)
    }

    fun decode(value: String): ChatRecord = decode(json.parseToJsonElement(value).jsonObject)

    fun decode(obj: JsonObject): ChatRecord {
        val messages = obj["messages"]?.jsonArray?.map { element ->
            val message = element.jsonObject
            ChatMessage(
                id = canonicalUUID(message.string("id")), role = message.string("role"),
                text = message.string("text"), createdAt = message.number("createdAt"),
                unknownJson = JsonObject(message.filterKeys { it !in messageKeys }).toString(),
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
            unknownJson = JsonObject(obj.filterKeys { it !in chatKeys }).toString(),
        )
    }

    private fun encodeMessage(message: ChatMessage) = buildJsonObject {
        extras(message.unknownJson, messageKeys).forEach { (key, value) -> put(key, value) }
        put("id", canonicalUUID(message.id)); put("role", message.role); put("text", message.text); put("createdAt", message.createdAt)
    }

    private fun extras(value: String, known: Set<String>): JsonObject = runCatching {
        JsonObject(json.parseToJsonElement(value).jsonObject.filterKeys { it !in known })
    }.getOrDefault(JsonObject(emptyMap()))

    private fun JsonObject.string(key: String): String = this[key]?.jsonPrimitive?.contentOrNull ?: error("Missing $key")
    private fun JsonObject.optString(key: String): String? = this[key]?.jsonPrimitive?.contentOrNull
    private fun JsonObject.number(key: String): Double = (this[key]?.jsonPrimitive?.doubleOrNull ?: error("Missing or invalid $key"))
        .also { require(it.isFinite()) { "Non-finite $key" } }
    private fun JsonObject.optNumber(key: String): Double? = this[key]?.jsonPrimitive?.doubleOrNull?.also {
        require(it.isFinite()) { "Non-finite $key" }
    }
}
