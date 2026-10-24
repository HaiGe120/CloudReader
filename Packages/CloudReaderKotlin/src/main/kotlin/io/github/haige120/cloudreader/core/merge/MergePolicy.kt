package io.github.haige120.cloudreader.core.merge

import io.github.haige120.cloudreader.core.contract.SyncCodec
import io.github.haige120.cloudreader.core.model.BookRecord
import io.github.haige120.cloudreader.core.model.BookTombstone
import io.github.haige120.cloudreader.core.model.ChatMessage
import io.github.haige120.cloudreader.core.model.ChatRecord
import io.github.haige120.cloudreader.core.model.ConversationTombstone
import io.github.haige120.cloudreader.core.model.canonicalUUID
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import kotlin.math.abs

/** Pure deterministic v1 conflict selection. Recovery values are portable candidates. */
public object MergePolicy {
    public data class BookCandidate(
        val book: BookRecord,
        val sha256: String,
        val entryUnknown: JsonObject = JsonObject(emptyMap()),
    ) {
        public fun portable(): JsonObject = buildJsonObject {
            put("book", SyncCodec.bookToJson(book).portableBook())
            put("sha256", sha256)
        }
        public fun completeCandidate(): JsonObject = buildJsonObject {
            put("book", SyncCodec.bookToJson(book).portableBook())
            put("sha256", sha256)
            entryUnknown.forEach { (key, value) -> if (key !in setOf("book", "sha256")) put(key, value) }
        }
    }

    public data class BookMergeResult(val primary: BookCandidate?, val recovery: List<JsonObject>)

    public fun mergeBooks(candidates: List<BookCandidate>): BookMergeResult {
        val unique = candidates.distinctBy { canonical(it.completeCandidate()) }
        val newest = unique.maxOfOrNull { it.book.modifiedAt }
        val chosen = unique.filter { it.book.modifiedAt == newest }.minWithOrNull { a, b -> compareCanonical(a.portable(), b.portable()) }
        val recovery = mutableListOf<JsonObject>()
        if (unique.size > 1) recovery += unique.map { it.completeCandidate() }
        var bookUnknown = JsonObject(emptyMap())
        var entryUnknown = JsonObject(emptyMap())
        if (chosen != null) {
            val id = chosen.book.id
            unique.forEach { candidate ->
                val (bookFields, bookConflicts) = mergeOpaqueJson(bookUnknown.toString(), candidate.book.unknownJson, id)
                bookUnknown = bookFields; recovery += bookConflicts
                val (entryFields, entryConflicts) = mergeOpaqueObjects(entryUnknown, candidate.entryUnknown, id)
                entryUnknown = entryFields; recovery += entryConflicts
            }
        }
        val primary = chosen?.copy(book = chosen.book.copy(unknownJson = bookUnknown.toString()), entryUnknown = entryUnknown)
        return BookMergeResult(primary, recovery.distinctBy(::canonical).sortedWith(::compareCanonical))
    }

    public fun mergeTombstones(values: List<Double>): Double? = values.maxOrNull()

    public fun mergeBookTombstones(values: List<BookTombstone>): Pair<List<BookTombstone>, List<JsonObject>> = mergeTombstonesByID(
        values, { it.bookID }, { it.deletedAt }, SyncCodec::tombstoneJson,
    ) { id, time, unknown -> BookTombstone(id, time, unknown) }

    public fun mergeConversationTombstones(values: List<ConversationTombstone>): Pair<List<ConversationTombstone>, List<JsonObject>> = mergeTombstonesByID(
        values, { it.conversationID }, { it.deletedAt }, SyncCodec::chatTombstoneJson,
    ) { id, time, unknown -> ConversationTombstone(id, time, unknown) }

    /** A record survives only when its edit is strictly newer than a deletion. */
    public fun survives(modifiedAt: Double, deletedAt: Double?): Boolean = deletedAt == null || modifiedAt > deletedAt

    public fun mergeChats(a: ChatRecord, b: ChatRecord): ChatRecord {
        val metadata = when {
            a.modifiedAt > b.modifiedAt -> a
            b.modifiedAt > a.modifiedAt -> b
            compareCanonical(chatPortable(a), chatPortable(b)) <= 0 -> a
            else -> b
        }
        val byID = (a.messages + b.messages).groupBy { canonicalUUID(it.id) }.mapValues { (id, messages) ->
            val winner = messages.minWithOrNull { x, y -> compareCanonical(messagePortable(x), messagePortable(y)) }!!
            var opaque = JsonObject(emptyMap())
            messages.forEach { message -> opaque = mergeOpaqueJson(opaque.toString(), message.unknownJson, id).first }
            winner.copy(id = id, unknownJson = opaque.toString())
        }
        return metadata.copy(
            messages = byID.values.sortedWith(compareBy<ChatMessage> { it.createdAt }.thenBy { canonicalUUID(it.id) }),
            createdAt = minOf(a.createdAt, b.createdAt), modifiedAt = maxOf(a.modifiedAt, b.modifiedAt),
            unknownJson = mergeOpaque(a.unknownJson, b.unknownJson).toString(),
        )
    }

    public fun chatCollisionRecovery(a: ChatRecord, b: ChatRecord): List<JsonObject> =
        (a.messages + b.messages).groupBy { canonicalUUID(it.id) }.values.flatMap { messages ->
            val distinct = messages.distinctBy { canonical(messagePortable(it)) }.sortedWith { x, y -> compareCanonical(messagePortable(x), messagePortable(y)) }
            if (distinct.size < 2) emptyList() else distinct.map { buildJsonObject { put("kind", "message"); put("conversationID", canonicalUUID(a.id)); put("value", messagePortable(it)) } }
        }.distinctBy(::canonical).sortedWith(::compareCanonical) + opaqueRecovery(a, b)

    public fun mergeOpaqueJson(a: String, b: String, entityID: String? = null): Pair<JsonObject, List<JsonObject>> =
        mergeOpaqueObjects(parseObject(a), parseObject(b), entityID)

    private fun mergeOpaqueObjects(left: JsonObject, right: JsonObject, entityID: String? = null): Pair<JsonObject, List<JsonObject>> {
        val merged = linkedMapOf<String, JsonElement>()
        val recovery = mutableListOf<JsonObject>()
        for (key in (left.keys + right.keys).toSortedSet()) {
            val candidates = listOfNotNull(left[key], right[key]).distinctBy(::canonical).sortedWith(::compareCanonical)
            merged[key] = candidates.first()
            if (candidates.size > 1) candidates.forEach { value -> recovery += buildJsonObject {
                put("kind", "opaque"); entityID?.let { put("entityID", it) }; put("field", key); put("value", value)
            } }
        }
        return JsonObject(merged) to recovery.sortedWith(::compareCanonical)
    }

    public fun canonical(element: JsonElement): String = when (element) {
        is JsonObject -> element.keys.sorted().joinToString(separator = ",", prefix = "{", postfix = "}") { key -> "${quote(key)}:${canonical(element.getValue(key))}" }
        is JsonArray -> element.joinToString(separator = ",", prefix = "[", postfix = "]") { canonical(it) }
        is JsonPrimitive -> if (element.isString) quote(element.content) else {
            val number = element.content.toDoubleOrNull()
            if (number != null) jcsNumber(number) else element.content
        }
    }

    public fun canonicalNumber(value: Double): String = jcsNumber(value)

    /** Excludes Android's per-install managed filename and all device-only locations. */
    public fun portableBookMetadata(book: BookRecord): JsonObject = JsonObject(SyncCodec.bookToJson(book).filterKeys { it != "fileName" })

    public fun equalTimeBookCandidateDiffers(local: BookRecord, candidate: BookCandidate, localSha256: String?): Boolean =
        candidate.book.modifiedAt == local.modifiedAt && (candidate.sha256 != localSha256 || portableBookMetadata(candidate.book) != portableBookMetadata(local))

    public fun compareCanonical(a: JsonElement, b: JsonElement): Int = compareUtf8(canonical(a), canonical(b))

    private fun compareCanonical(a: String, b: String): Int = compareUtf8(a, b)
    private fun compareUtf8(a: String, b: String): Int {
        val left = a.toByteArray(Charsets.UTF_8); val right = b.toByteArray(Charsets.UTF_8)
        for (index in 0 until minOf(left.size, right.size)) {
            val difference = (left[index].toInt() and 0xff) - (right[index].toInt() and 0xff)
            if (difference != 0) return difference
        }
        return left.size - right.size
    }

    private fun chatPortable(chat: ChatRecord) = buildJsonObject {
        put("id", canonicalUUID(chat.id)); put("title", chat.title)
        chat.bookID?.let { put("bookID", canonicalUUID(it)) }; chat.bookTitle?.let { put("bookTitle", it) }
        chat.bookDescription?.let { put("bookDescription", it) }; chat.selectedText?.let { put("selectedText", it) }
        chat.bookContext?.let { put("bookContext", it) }; chat.contextDescription?.let { put("contextDescription", it) }
        put("includeBookContext", chat.includeBookContext); put("createdAt", chat.createdAt); put("modifiedAt", chat.modifiedAt)
        put("messages", JsonArray(chat.messages.map(::messagePortable)))
    }

    private fun <T> mergeTombstonesByID(
        values: List<T>, idOf: (T) -> String, timeOf: (T) -> Double, encode: (T) -> JsonObject,
        create: (String, Double, String) -> T,
    ): Pair<List<T>, List<JsonObject>> {
        val recovery = mutableListOf<JsonObject>()
        val merged = values.groupBy { canonicalUUID(idOf(it)) }.map { (id, candidates) ->
            val newest = candidates.maxOf(timeOf)
            val winner = candidates.filter { timeOf(it) == newest }.minWithOrNull { a, b -> compareCanonical(encode(a), encode(b)) }!!
            var mergedUnknown = JsonObject(emptyMap())
            candidates.forEach { candidate ->
                val unknown = JsonObject(encode(candidate).filterKeys { key -> key !in setOf("bookID", "conversationID", "deletedAt") })
                val (next, conflicts) = mergeOpaqueJson(mergedUnknown.toString(), unknown.toString(), id)
                mergedUnknown = next; recovery += conflicts
            }
            create(id, newest, mergedUnknown.toString())
        }
        return merged to recovery.sortedWith(::compareCanonical)
    }

    private fun messagePortable(message: ChatMessage) = buildJsonObject {
        put("id", canonicalUUID(message.id)); put("role", message.role); put("text", message.text); put("createdAt", message.createdAt)
    }

    private fun mergeOpaque(a: String, b: String): JsonObject = mergeOpaqueJson(a, b).first
    private fun opaqueRecovery(a: ChatRecord, b: ChatRecord): List<JsonObject> {
        val result = mutableListOf<JsonObject>()
        result += mergeOpaqueJson(a.unknownJson, b.unknownJson, canonicalUUID(a.id)).second
        val left = a.messages.associateBy { canonicalUUID(it.id) }; val right = b.messages.associateBy { canonicalUUID(it.id) }
        for (id in (left.keys intersect right.keys).sorted()) result += mergeOpaqueJson(left.getValue(id).unknownJson, right.getValue(id).unknownJson, id).second
        return result
    }
    private fun parseObject(value: String): JsonObject = runCatching { Json.parseToJsonElement(value).jsonObject }.getOrDefault(JsonObject(emptyMap()))
    private fun JsonObject.portableBook(): JsonObject = JsonObject(filterKeys { it in PORTABLE_BOOK_KEYS })
    private fun quote(value: String): String = JsonPrimitive(value).toString()
    private fun jcsNumber(value: Double): String {
        require(value.isFinite()) { "Non-finite numbers are not canonical JSON." }
        if (value == 0.0) return "0"
        val decimal = java.math.BigDecimal.valueOf(value).stripTrailingZeros()
        val absolute = abs(value)
        if (absolute >= 1e-6 && absolute < 1e21) return decimal.toPlainString()
        val scientific = decimal.toString().replace("E", "e")
        return if (absolute >= 1e21 && !scientific.substringAfter('e', "").startsWith("+")) scientific.replace("e", "e+") else scientific
    }

    private val PORTABLE_BOOK_KEYS = setOf("id", "title", "author", "briefDescription", "fileName", "format", "addedAt", "lastOpenedAt", "progress", "isBookmarked", "modifiedAt")
}
