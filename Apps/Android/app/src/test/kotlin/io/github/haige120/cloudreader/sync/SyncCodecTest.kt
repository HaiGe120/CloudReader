package io.github.haige120.cloudreader.sync

import io.github.haige120.cloudreader.domain.ChatMessage
import io.github.haige120.cloudreader.domain.ChatRecord
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.BookTombstone
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.util.UUID

class SyncCodecTest {
    @Test fun reviewedMergeVectorsAndOrderInvariance() {
        val vectorFile = generateSequence(File(requireNotNull(System.getProperty("user.dir")))) { it.parentFile }
            .map { File(it, "Contracts/v1/merge-vectors.json") }.first(File::isFile)
        val vectors = kotlinx.serialization.json.Json.parseToJsonElement(vectorFile.readText()).jsonObject["vectors"]!!.jsonArray
            .associateBy { it.jsonObject.getValue("id").jsonPrimitive.content }
        val ids = mapOf("B1" to "0E7B7B49-9652-4E82-BA2E-84F58CC90D46", "C1" to "62B27B43-A87E-402D-8D6A-A70747F50291")
        fun resolve(value: JsonElement): JsonElement = when (value) {
            is JsonObject -> JsonObject(value.mapValues { resolve(it.value) })
            is JsonArray -> JsonArray(value.map(::resolve))
            is JsonPrimitive -> if (value.isString) ids[value.content]?.let(::JsonPrimitive) ?: value else value
        }
        fun str(value: JsonElement) = value.jsonPrimitive.content
        fun num(value: JsonElement) = str(value).toDouble()
        fun obj(value: JsonObject, key: String) = value.getValue(key).jsonObject
        fun arr(value: JsonObject, key: String) = value.getValue(key).jsonArray
        fun vector(name: String) = vectors.getValue(name).jsonObject
        fun message(value: JsonObject): ChatMessage {
            val m = resolve(value).jsonObject
            return ChatMessage(str(m.getValue("id")), str(m.getValue("role")), str(m.getValue("text")), num(m.getValue("createdAt")))
        }
        fun chat(value: JsonObject): ChatRecord {
            val c = resolve(value).jsonObject
            return ChatRecord(
                id = str(c.getValue("id")), title = str(c.getValue("title")),
                messages = arr(c, "messages").map { message(it.jsonObject) },
                createdAt = num(c.getValue("createdAt")), modifiedAt = num(c.getValue("modifiedAt")),
            )
        }

        for (name in listOf("delete-before-edit", "delete-equal-edit", "delete-after-edit")) {
            val case = vector(name); val input = obj(case, "inputs")
            val record = obj(input, "record"); val tombstone = obj(input, "tombstone")
            val tombstoneID = str(resolve(tombstone.getValue("id")))
            val deletion = MergePolicy.mergeBookTombstones(listOf(BookTombstone(tombstoneID, num(tombstone.getValue("deletedAt"))))).first.single()
            val expected = obj(case, "expected").getValue("recordPresent").jsonPrimitive.content.toBoolean()
            assertEquals(name, expected, MergePolicy.survives(num(record.getValue("modifiedAt")), deletion.deletedAt))
        }

        run {
            val case = vector("newer-edit-keeps-older-tombstone"); val input = obj(case, "inputs")
            val records = arr(input, "records").map { resolve(it.jsonObject).jsonObject }
            val deletions = arr(input, "tombstones").map { item ->
                val t = resolve(item.jsonObject).jsonObject
                BookTombstone(str(t.getValue("id")), num(t.getValue("deletedAt")))
            }
            val winner = records.maxBy { num(it.getValue("modifiedAt")) }
            val deletion = MergePolicy.mergeBookTombstones(deletions).first.single()
            val expected = obj(case, "expected")
            assertEquals(num(expected.getValue("recordModifiedAt")), num(winner.getValue("modifiedAt")), 0.0)
            assertEquals(num(expected.getValue("tombstoneDeletedAt")), deletion.deletedAt, 0.0)
            assertEquals(expected.getValue("recordPresent").jsonPrimitive.content.toBoolean(), MergePolicy.survives(num(winner.getValue("modifiedAt")), deletion.deletedAt))
        }

        run {
            val case = vector("book-equal-time-portable-tie-and-recovery"); val input = obj(case, "inputs")
            val paths = obj(input, "deviceLocalPaths")
            val candidates = arr(input, "candidates").mapIndexed { index, value ->
                val c = value.jsonObject
                val path = if (index == 0) "first" else "second"
                MergePolicy.BookCandidate(
                    SyncCodec.bookFromJson(resolve(obj(c, "book")).jsonObject).copy(localLocation = str(paths.getValue(path))),
                    str(c.getValue("sha256")),
                )
            }
            val expected = obj(case, "expected")
            val expectedRecovery = arr(expected, "recoveryCandidates").map { candidate ->
                val resolved = resolve(candidate).jsonObject
                val normalizedBook = SyncCodec.bookToJson(SyncCodec.bookFromJson(obj(resolved, "book")))
                val normalized = kotlinx.serialization.json.buildJsonObject {
                    put("book", normalizedBook)
                    put("sha256", resolved.getValue("sha256"))
                }
                MergePolicy.canonical(normalized)
            }.sorted()
            val merged = MergePolicy.mergeBooks(candidates)
            assertEquals(expectedRecovery, merged.recovery.map(MergePolicy::canonical).sorted())
            assertEquals(expectedRecovery.first(), MergePolicy.canonical(merged.primary!!.portable()))
            assertEquals(merged, MergePolicy.mergeBooks(candidates.reversed()))
            assertTrue(candidates.all { !MergePolicy.canonical(it.portable()).contains("device-") })
        }

        run {
            val case = vector("conversation-equal-time-portable-tie")
            val candidates = arr(obj(case, "inputs"), "candidates").map { chat(it.jsonObject) }
            val expectedTitle = arr(obj(case, "inputs"), "candidates").map { resolve(it).jsonObject }
                .minBy { MergePolicy.canonical(it) }.getValue("title").jsonPrimitive.content
            val ab = SyncCodec.mergeChats(candidates[0], candidates[1])
            assertEquals(expectedTitle, ab.title)
            assertEquals(ab, SyncCodec.mergeChats(candidates[1], candidates[0]))
        }

        run {
            val case = vector("message-union-and-order"); val input = obj(case, "inputs")
            val left = arr(input, "left").map { message(it.jsonObject) }
            val right = arr(input, "right").map { message(it.jsonObject) }
            val expectedIDs = arr(obj(case, "expected"), "messageIDsInOrder").map(::str)
            val conversation = ChatRecord(ids.getValue("C1"), "Vector", left, createdAt = 1.0, modifiedAt = 2.0)
            val merged = SyncCodec.mergeChats(conversation, conversation.copy(messages = right))
            assertEquals(expectedIDs, merged.messages.map { it.id })
            assertEquals(1, merged.messages.count { it.id == right.first().id })
            assertEquals(merged, SyncCodec.mergeChats(merged, conversation.copy(messages = right)))
        }

        run {
            val case = vector("same-message-id-different-payload"); val input = obj(case, "inputs")
            val candidates = arr(input, "candidates").map { message(it.jsonObject) }
            val conversation = ChatRecord(ids.getValue("C1"), "Vector", listOf(candidates[0]), createdAt = 1.0, modifiedAt = 4.0)
            val competing = conversation.copy(messages = listOf(candidates[1]))
            val primary = SyncCodec.mergeChats(conversation, competing).messages.single()
            fun portable(m: ChatMessage) = kotlinx.serialization.json.buildJsonObject {
                put("id", m.id); put("role", m.role); put("text", m.text); put("createdAt", m.createdAt)
            }
            val expected = arr(obj(case, "expected"), "recoveryCandidates").map { MergePolicy.canonical(resolve(it)) }.sorted()
            val recovered = MergePolicy.chatCollisionRecovery(conversation, competing).map { MergePolicy.canonical(it.getValue("value")) }.sorted()
            assertEquals(expected, recovered)
            assertEquals(expected.first(), MergePolicy.canonical(portable(primary)))
            assertEquals(arr(obj(case, "expected"), "messageIDsInManifest").map(::str), listOf(primary.id))
        }

        for (name in listOf("opaque-unknown-disjoint-and-equal-values", "opaque-unknown-same-key-conflict")) {
            val case = vector(name); val input = obj(case, "inputs")
            val left = resolve(input.getValue("left")).jsonObject; val right = resolve(input.getValue("right")).jsonObject
            val (merged, recovery) = MergePolicy.mergeOpaqueJson(left.toString(), right.toString(), ids.getValue("C1"))
            val expected = obj(case, "expected")
            if (name == "opaque-unknown-disjoint-and-equal-values") {
                assertEquals(resolve(expected.getValue("primaryUnknownFields")), merged)
                assertTrue(recovery.isEmpty())
                assertEquals(merged, MergePolicy.mergeOpaqueJson(merged.toString(), right.toString()).first)
            } else {
                val expectedCandidates = arr(expected, "recoveryCandidates").map { resolve(obj(it.jsonObject, "value")) }.map(MergePolicy::canonical).sorted()
                val field = str(arr(expected, "recoveryCandidates").first().jsonObject.getValue("field"))
                assertEquals(listOf(left.getValue(field), right.getValue(field)).minBy(MergePolicy::canonical), merged.getValue(field))
                assertEquals(expectedCandidates, recovery.map { MergePolicy.canonical(it.getValue("value")) }.sorted())
                assertEquals(false, expected.getValue("recursiveMerge").jsonPrimitive.content.toBoolean())
            }
        }

        run {
            val case = vector("provider-permutations-duplicate-and-retry"); val input = obj(case, "inputs")
            val providers = obj(input, "providers"); val expected = obj(case, "expected")
            val seed = ChatRecord(ids.getValue("C1"), "Provider merge", emptyList(), createdAt = 1.0, modifiedAt = 1.0)
            data class State(val chat: ChatRecord, val deletions: List<BookTombstone>)
            fun apply(state: State, providerID: String): State {
                val provider = providers.getValue(providerID).jsonObject
                val messages = provider["conversationMessages"]?.jsonArray.orEmpty().map { message(it.jsonObject) }
                val incoming = seed.copy(messages = messages)
                val tombstones = provider["bookTombstone"]?.jsonObject?.let { t ->
                    listOf(BookTombstone(ids.getValue(str(t.getValue("id"))), num(t.getValue("deletedAt"))))
                }.orEmpty()
                return State(SyncCodec.mergeChats(state.chat, incoming), MergePolicy.mergeBookTombstones(state.deletions + tombstones).first)
            }
            fun fold(order: List<String>) = order.fold(State(seed, emptyList()), ::apply)
            val orders = arr(input, "providerOrders").map { it.jsonArray.map(::str) }
            val results = orders.map(::fold)
            val expectedState = results.first()
            assertTrue(results.all { it == expectedState })
            assertEquals(arr(expected, "conversationMessageIDs").map(::str), expectedState.chat.messages.map { it.id })
            assertEquals(num(expected.getValue("bookTombstoneDeletedAt")), expectedState.deletions.single().deletedAt, 0.0)
            val replay = obj(input, "replay")
            val retryProvider = str(replay.getValue("afterFailure")).substringAfterLast("retry ").trim()
            val duplicateProvider = str(replay.getValue("provider"))
            val partial = fold(orders.first().filter { it != retryProvider })
            assertEquals(partial, apply(partial, duplicateProvider))
            assertEquals(expectedState, apply(partial, retryProvider))
        }

        run {
            val case = vector("wall-clock-skew-limitation"); val input = obj(case, "inputs"); val expected = obj(case, "expected")
            val edit = obj(input, "deviceA"); val deletion = obj(input, "deviceB")
            assertTrue(MergePolicy.survives(num(edit.getValue("modifiedAt")), num(deletion.getValue("deletedAt"))))
            assertEquals(false, expected.getValue("actualRealEventOrderInferred").jsonPrimitive.content.toBoolean())
            assertEquals(false, expected.getValue("causalGuarantee").jsonPrimitive.content.toBoolean())
            assertTrue(str(expected.getValue("v1TimestampComparison")).contains("record survives"))
        }
    }

    @Test fun bookTieAndRecoveryArePermutationInvariantAndExcludeLocalPath() {
        val a = BookRecord("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", "Beta", fileName = "same.txt", format = "txt", addedAt = 1.0, modifiedAt = 20.0, localLocation = "/a/private")
        val b = a.copy(title = "Alpha", localLocation = "/b/private")
        val candidates = listOf(MergePolicy.BookCandidate(a, "b".repeat(64)), MergePolicy.BookCandidate(b, "a".repeat(64)))
        val ab = MergePolicy.mergeBooks(candidates)
        val ba = MergePolicy.mergeBooks(candidates.reversed())
        assertEquals("Alpha", ab.primary!!.book.title)
        assertEquals(ab, ba)
        assertEquals(2, ab.recovery.size)
        assertEquals(false, MergePolicy.canonical(ab.recovery.first()).contains("private"))
    }

    @Test fun messageIDCollisionChoosesCanonicalPayloadAndKeepsRecovery() {
        val id = "00000000-0000-0000-0000-000000000003"
        val a = ChatRecord("62B27B43-A87E-402D-8D6A-A70747F50291", "A", listOf(ChatMessage(id, "user", "original", 3.0)), createdAt = 1.0, modifiedAt = 4.0)
        val b = a.copy(messages = listOf(ChatMessage(id, "user", "different", 3.0)))
        val primary = SyncCodec.mergeChats(a, b)
        assertEquals(SyncCodec.mergeChats(b, a), primary)
        assertEquals("different", primary.messages.single().text)
        assertEquals(2, MergePolicy.chatCollisionRecovery(a, b).size)
    }

    @Test fun opaqueValuesAreUnionedWithoutRecursiveMergeAndConflictsAreRetained() {
        val (merged, recovery) = MergePolicy.mergeOpaqueJson(
            """{"future":{"nested":[1,2]},"same":["x",2]}""",
            """{"future":{"nested":[1,3]},"other":false,"same":["x",2]}""",
        )
        assertEquals(3, merged.size)
        assertEquals(2, recovery.size)
        assertEquals(2, merged["future"]!!.jsonObject["nested"]!!.jsonArray.size)
        assertEquals(recovery, recovery.reversed().sortedBy(MergePolicy::canonical))
    }

    @Test fun durableRecoveryDeduplicatesOnRetry() {
        val file = File.createTempFile("cloudreader-recovery", ".json").also { it.delete() }
        val store = SyncRecoveryStore(file)
        val first = kotlinx.serialization.json.buildJsonObject { put("kind", "message"); put("id", UUID.randomUUID().toString()) }
        val candidate = kotlinx.serialization.json.buildJsonObject { put("kind", "message"); put("id", UUID.randomUUID().toString()) }
        store.append(listOf(first)); store.append(listOf(candidate)); store.append(listOf(candidate))
        val parsed = kotlinx.serialization.json.Json.parseToJsonElement(file.readText()).jsonArray
        assertEquals(2, parsed.size)
        file.delete()
    }

    @Test fun rootOpaqueFieldsUnionAcrossDestinationSnapshotsAndSurviveRestart() {
        val directory = kotlin.io.path.createTempDirectory("cloudreader-root-opaque-").toFile()
        try {
            val file = File(directory, "sync-opaque-v1.json")
            val firstDestination = SyncOpaqueManifestStore(file)
            val first = firstDestination.merge(kotlinx.serialization.json.Json.parseToJsonElement("""{"fromA":{"nested":[1,2]},"shared":{"x":1}}""").jsonObject)
            assertTrue(first.first.containsKey("fromA"))

            val secondDestination = SyncOpaqueManifestStore(file)
            val second = secondDestination.merge(kotlinx.serialization.json.Json.parseToJsonElement("""{"fromB":false,"shared":{"x":2}}""").jsonObject)
            assertTrue(second.first.containsKey("fromA"))
            assertEquals("false", second.first["fromB"]!!.jsonPrimitive.content)
            assertEquals(2, second.second.size)
            assertTrue(second.second.all { it["entityID"]!!.jsonPrimitive.content == "manifest" })

            val afterRestart = SyncOpaqueManifestStore(file).merge(kotlinx.serialization.json.JsonObject(emptyMap())).first
            assertEquals(second.first, afterRestart)
        } finally { directory.deleteRecursively() }
    }

    @Test fun equalTimeMetadataWinnerIsDetectedEvenWhenContentHashMatches() {
        val local = BookRecord("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", "Beta", fileName = "managed-random.txt", format = "txt", addedAt = 1.0, modifiedAt = 20.0, localLocation = "txt:55")
        val remote = local.copy(title = "Alpha", fileName = "portable.txt", localLocation = null)
        assertTrue(MergePolicy.portableBookMetadata(local) != MergePolicy.portableBookMetadata(remote))
        val hash = "a".repeat(64)
        assertTrue(MergePolicy.equalTimeBookCandidateDiffers(local, MergePolicy.BookCandidate(remote, hash), hash))
        assertEquals(
            MergePolicy.portableBookMetadata(local.copy(fileName = "another-managed-name.txt")),
            MergePolicy.portableBookMetadata(local),
        )
        assertEquals(false, MergePolicy.equalTimeBookCandidateDiffers(
            local, MergePolicy.BookCandidate(local.copy(fileName = "portable.txt"), hash), hash,
        ))
    }

    @Test fun canonicalComparatorUsesUnsignedUtf8AndJcsNumberThresholds() {
        assertEquals("0.000001", MergePolicy.canonicalNumber(1e-6))
        assertEquals("1e-7", MergePolicy.canonicalNumber(1e-7))
        assertEquals("100000000000000000000", MergePolicy.canonicalNumber(1e20))
        assertEquals("1e+21", MergePolicy.canonicalNumber(1e21))
        assertEquals(-1, MergePolicy.compareCanonical(kotlinx.serialization.json.JsonPrimitive("é"), kotlinx.serialization.json.JsonPrimitive("😀")).compareTo(0))
    }

    @Test fun appleSchemaV1RoundTripPreservesTimestampsIdentityAndUnknownFields() {
        val fixture = """
            {
              "schemaVersion":1,"updatedAt":811200000.125,"futureRoot":{"x":1},
              "books":[{"futureEntry":"keep","sha256":"${"a".repeat(64)}","book":{
                "id":"0e7b7b49-9652-4e82-ba2e-84f58cc90d46","title":"The Open Shelf","author":"The CloudReader Project",
                "briefDescription":"Guide","fileName":"open-shelf.txt","format":"txt","addedAt":811000000.25,
                "lastOpenedAt":811100000.5,"progress":0.375,"isBookmarked":true,"modifiedAt":811100000.5,
                "futureBookField":{"edition":2}
              }}],
              "deletions":[{"bookID":"AE78B302-46FE-4478-977B-9E6F862A2C8D","deletedAt":811100000.5,"futureDeletion":true}],
              "conversations":[{"id":"62B27B43-A87E-402D-8D6A-A70747F50291","title":"Question","messages":[
                {"id":"DCA22815-A838-45E5-85BC-BA835D550432","role":"user","text":"Hello","createdAt":811100000.5,"futureMessage":"keep"}
              ],"createdAt":811100000.5,"modifiedAt":811100000.5,"futureChatField":"keep"}],
              "conversationDeletions":[{"conversationID":"62B27B43-A87E-402D-8D6A-A70747F50292","deletedAt":811000000.0,"futureChatDeletion":3}]
            }
        """.trimIndent().toByteArray()

        val decoded = SyncCodec.manifestFromJson(fixture)
        val encoded = SyncCodec.manifestToJson(decoded)
        val book = decoded.books.single().book
        assertEquals("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", book.id)
        assertEquals(811000000.25, book.addedAt, 0.0) // Foundation reference-date seconds remain numeric and unchanged.
        assertEquals("book-0E7B7B49-9652-4E82-BA2E-84F58CC90D46.txt", SyncCodec.bookObjectName(book))
        assertEquals("1", encoded["futureRoot"]!!.jsonObject["x"]!!.jsonPrimitive.content)
        assertNotNull(encoded["books"]!!.jsonArray.single().jsonObject["futureEntry"])
        assertNotNull(encoded["books"]!!.jsonArray.single().jsonObject["book"]!!.jsonObject["futureBookField"])
        assertNotNull(encoded["deletions"]!!.jsonArray.single().jsonObject["futureDeletion"])
        assertNotNull(encoded["conversations"]!!.jsonArray.single().jsonObject["futureChatField"])
        assertNotNull(encoded["conversations"]!!.jsonArray.single().jsonObject["messages"]!!.jsonArray.single().jsonObject["futureMessage"])
        assertNotNull(encoded["conversationDeletions"]!!.jsonArray.single().jsonObject["futureChatDeletion"])
    }

    @Test fun conversationMergeUsesStableMessageIDsAndPreservesBothMessages() {
        val a = ChatRecord("62B27B43-A87E-402D-8D6A-A70747F50291", "A", listOf(
            ChatMessage("DCA22815-A838-45E5-85BC-BA835D550432", "user", "First", 1.0),
        ), createdAt = 1.0, modifiedAt = 2.0)
        val b = a.copy(title = "B", messages = listOf(
            a.messages.single(), ChatMessage("15ECA1D9-34C5-4A96-8367-15B0F248DFD4", "assistant", "Second", 3.0),
        ), modifiedAt = 4.0)
        val merged = SyncCodec.mergeChats(a, b)
        assertEquals("B", merged.title)
        assertEquals(2, merged.messages.size)
        assertEquals("Second", merged.messages.last().text)
    }

    @Test fun optionalLegacyBookFieldsRemainOptional() {
        val legacy = kotlinx.serialization.json.Json.parseToJsonElement(
            """{"id":"0E7B7B49-9652-4E82-BA2E-84F58CC90D46","title":"Legacy","fileName":"legacy.mobi","format":"mobi","addedAt":1,"progress":0}"""
        ).jsonObject
        val book = SyncCodec.bookFromJson(legacy)
        assertEquals(0.0, book.progress, 0.0)
        assertEquals("mobi", book.format)
        assertEquals(false, book.isBookmarked)
    }
}
