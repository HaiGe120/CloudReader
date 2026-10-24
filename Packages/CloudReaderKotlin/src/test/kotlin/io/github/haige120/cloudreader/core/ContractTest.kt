package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.contract.SyncCodec
import io.github.haige120.cloudreader.core.contract.SyncManifest
import io.github.haige120.cloudreader.core.contract.SyncedBook
import io.github.haige120.cloudreader.core.model.BookRecord
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class ContractTest {
    private val id = "A3B54F17-90DD-41E3-A9A3-6D3A163A67D2"

    @Test fun legacyDefaultsAndReferenceDateFractionsRoundTrip() {
        val source = """{"id":"$id","title":"Legacy","fileName":"legacy.txt","format":"txt","addedAt":123.125}"""
        val book = SyncCodec.bookFromJson(kotlinx.serialization.json.Json.parseToJsonElement(source).jsonObject)
        assertEquals(0.0, book.progress, 0.0)
        assertFalse(book.isBookmarked)
        assertEquals(123.125, book.modifiedAt, 0.0)
        assertEquals("TXT", book.format.uppercase())
        assertEquals("$id", book.id)
    }

    @Test fun unknownBookFieldsSurviveButDevicePathStaysOutOfWire() {
        val source = """{"id":"$id","title":"Book","fileName":"book.txt","format":"TXT","addedAt":1.5,"future":{"x":true},"localLocation":"/private/file"}"""
        val book = SyncCodec.bookFromJson(kotlinx.serialization.json.Json.parseToJsonElement(source).jsonObject)
        assertTrue(book.unknownJson.contains("future"))
        val encoded = SyncCodec.bookToJson(book)
        assertEquals("txt", encoded["format"]?.toString()?.trim('"'))
        assertTrue(encoded.containsKey("future"))
        assertFalse(encoded.containsKey("localLocation"))
    }

    @Test fun unsafeWireValuesAreRejected() {
        fun parse(extra: String) = SyncCodec.bookFromJson(kotlinx.serialization.json.Json.parseToJsonElement("""{"id":"$id","title":"x","fileName":"x.txt","format":"txt","addedAt":1,$extra}""").jsonObject)
        assertThrows(IllegalArgumentException::class.java) { parse("\"fileName\":\"../x.txt\"") }
        assertThrows(IllegalArgumentException::class.java) { parse("\"progress\":1.1") }
        assertThrows(IllegalArgumentException::class.java) { parse("\"format\":\"doc\"") }
    }

    @Test fun manifestRetainsUnknownRootAndEntryFields() {
        val book = BookRecord(id, "x", fileName = "x.txt", format = "txt", addedAt = 1.0, modifiedAt = 2.0, unknownJson = "{\"bookFuture\":42}")
        val manifest = SyncManifest(updatedAt = 3.0, books = listOf(SyncedBook(book, "${"a".repeat(64)}", kotlinx.serialization.json.Json.parseToJsonElement("{\"entryFuture\":true}").jsonObject)), unknown = kotlinx.serialization.json.Json.parseToJsonElement("{\"rootFuture\":\"ok\"}").jsonObject)
        val restored = SyncCodec.manifestFromJson(SyncCodec.manifestToBytes(manifest))
        assertTrue(restored.unknown.containsKey("rootFuture"))
        assertTrue(restored.books.single().unknown.containsKey("entryFuture"))
        assertTrue(restored.books.single().book.unknownJson.contains("bookFuture"))
    }
}
