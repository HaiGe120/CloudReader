package io.github.haige120.cloudreader.sync

import io.github.haige120.cloudreader.data.ChatMessage
import io.github.haige120.cloudreader.data.ChatRecord
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class SyncCodecTest {
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
