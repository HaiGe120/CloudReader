package io.github.haige120.cloudreader.sync

import androidx.room.Room
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import io.github.haige120.cloudreader.data.CloudReaderDatabase
import io.github.haige120.cloudreader.data.ConversationRow
import io.github.haige120.cloudreader.data.LibraryRepository
import io.github.haige120.cloudreader.data.toRow
import io.github.haige120.cloudreader.domain.ConversationJsonAdapter
import java.io.File
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class ContractFixtureTest {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val assets get() = instrumentation.context.assets
    private val json = Json.Default

    @Test fun actualFixtureOutcomesMatchSiblingExpectations() {
        val fixtures = assets.list("")!!.filter { it.endsWith(".json") && !it.endsWith(".expected.json") }.sorted()
        assertEquals("Fixture loader should include the complete shared v1 set", 13, fixtures.size)
        for (fixture in fixtures) {
            val input = read(fixture)
            val expected = json.parseToJsonElement(read(fixture.removeSuffix(".json") + ".expected.json")).jsonObject
            val classification = expected.getValue("classification").jsonPrimitive.content
            val shouldReject = classification.startsWith("reject") || classification == "safety rejection expectation"
            if (shouldReject) {
                assertThrows("$fixture should be rejected", Exception::class.java) { SyncCodec.manifestFromJson(input.encodeToByteArray()) }
            } else {
                val manifest = SyncCodec.manifestFromJson(input.encodeToByteArray())
                when (fixture) {
                    "minimal-legacy.json" -> {
                        assertEquals(1, manifest.schemaVersion)
                        assertTrue(manifest.deletions.isEmpty())
                        val book = manifest.books.single().book
                        assertEquals(0.0, book.progress, 0.0)
                        assertFalse(book.isBookmarked)
                        assertEquals(book.addedAt, book.modifiedAt, 0.0)
                        assertEquals(null, book.lastOpenedAt)
                    }
                    "full-record.json" -> {
                        val book = manifest.books.single().book
                        assertEquals(800000000.125, book.addedAt, 0.0)
                        assertEquals(812000000.75, book.lastOpenedAt!!, 0.0)
                        assertEquals(812345678.125, book.modifiedAt, 0.0)
                        assertEquals("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", book.id)
                        assertEquals("book-${book.id}.epub", SyncCodec.bookObjectName(book))
                    }
                    "mixed-case-uuid.json" -> assertEquals("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", manifest.books.single().book.id)
                    "unknown-role.json" -> assertEquals("tool", manifest.conversations.single().messages.single().role)
                    "nested-unknown.json" -> assertUnknownValuesPreserved(input, SyncCodec.manifestToJson(manifest))
                    "deletion-equal-time.json" -> assertTrue("This fixture is parse-only; merge behavior belongs to C02", manifest.books.isNotEmpty())
                }
            }
        }
    }

    @Test fun malformedEntityIdsAreRejectedByWireDecoder() {
        val full = read("full-record.json")
        val malformed = full
            .replace("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", "not-a-uuid")
            .replace("11345678-9652-4E82-BA2E-84F58CC90D46", "not-a-uuid")
            .replace("22345678-9652-4E82-BA2E-84F58CC90D46", "not-a-uuid")
        val malformedBook = full.replace("0E7B7B49-9652-4E82-BA2E-84F58CC90D46", "not-a-uuid")
        for (input in listOf(malformed, malformedBook)) {
            assertThrows(Exception::class.java) { SyncCodec.manifestFromJson(input.encodeToByteArray()) }
        }
    }

    @Test fun nestedUnknownValuesSurviveDurableBookAndConversationEdit() = runBlocking {
        val manifest = SyncCodec.manifestFromJson(read("nested-unknown.json").encodeToByteArray())
        val context = instrumentation.targetContext
        val dbName = "contract-${System.nanoTime()}.db"
        val booksDir = File(context.cacheDir, "contract-books-${System.nanoTime()}")
        val database = Room.databaseBuilder(context, CloudReaderDatabase::class.java, dbName).build()
        try {
            val dao = database.libraryDao()
            val originalBook = manifest.books.single().book
            val originalChat = manifest.conversations.single()
            dao.putBook(originalBook.toRow())
            dao.putBookDeletion(manifest.deletions.single().toRow())
            dao.putConversation(ConversationRow(originalChat.id, ConversationJsonAdapter.encode(originalChat).toString(), originalChat.modifiedAt))

            val repository = LibraryRepository(context, dao, booksDir)
            val loaded = repository.snapshot()
            val editedBook = loaded.books.single().copy(title = "Edited title")
            val editedChat = loaded.conversations.single().copy(title = "Edited conversation")
            dao.putBook(editedBook.toRow())
            dao.putConversation(ConversationRow(editedChat.id, ConversationJsonAdapter.encode(editedChat).toString(), editedChat.modifiedAt))

            val reloaded = repository.snapshot()
            assertEquals("Edited title", reloaded.books.single().title)
            assertEquals("Edited conversation", reloaded.conversations.single().title)
            assertEquals("""{"keep":true}""", json.parseToJsonElement(reloaded.bookDeletions.single().unknownJson).jsonObject.getValue("futureTombstone").toString())
            assertEquals("""{"x":[1,{"keep":true}]}""", json.parseToJsonElement(reloaded.books.single().unknownJson).jsonObject.getValue("futureBook").toString())
            assertEquals("""{"keep":true}""", json.parseToJsonElement(reloaded.conversations.single().unknownJson).jsonObject.getValue("futureConversation").toString())
            assertEquals("""{"keep":true}""", json.parseToJsonElement(reloaded.conversations.single().messages.single().unknownJson).jsonObject.getValue("futureMessage").toString())
            assertEquals("""{"x":[1,{"keep":true}]}""", SyncCodec.bookToJson(reloaded.books.single()).getValue("futureBook").toString())
            assertEquals("""{"keep":true}""", ConversationJsonAdapter.encode(reloaded.conversations.single()).getValue("futureConversation").toString())
            assertEquals("""{"keep":true}""", ConversationJsonAdapter.encode(reloaded.conversations.single()).getValue("messages").jsonArray.single().jsonObject.getValue("futureMessage").toString())
        } finally {
            database.close()
            context.deleteDatabase(dbName)
            booksDir.deleteRecursively()
        }
    }

    private fun read(name: String): String = assets.open(name).bufferedReader().use { it.readText() }

    private fun assertUnknownValuesPreserved(input: String, output: JsonObject) {
        val source = json.parseToJsonElement(input).jsonObject
        assertEquals(source.getValue("futureRoot"), output.getValue("futureRoot"))
        assertEquals(source.getValue("books").jsonArray.single().jsonObject.getValue("futureEntry"), output.getValue("books").jsonArray.single().jsonObject.getValue("futureEntry"))
        assertEquals(source.getValue("books").jsonArray.single().jsonObject.getValue("book").jsonObject.getValue("futureBook"), output.getValue("books").jsonArray.single().jsonObject.getValue("book").jsonObject.getValue("futureBook"))
        assertEquals(source.getValue("deletions").jsonArray.single().jsonObject.getValue("futureTombstone"), output.getValue("deletions").jsonArray.single().jsonObject.getValue("futureTombstone"))
        val sourceChat = source.getValue("conversations").jsonArray.single().jsonObject
        val outputChat = output.getValue("conversations").jsonArray.single().jsonObject
        assertEquals(sourceChat.getValue("futureConversation"), outputChat.getValue("futureConversation"))
        assertEquals(sourceChat.getValue("messages").jsonArray.single().jsonObject.getValue("futureMessage"), outputChat.getValue("messages").jsonArray.single().jsonObject.getValue("futureMessage"))
    }
}
