package io.github.haige120.cloudreader.data

import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.BookTombstone
import io.github.haige120.cloudreader.domain.ConversationTombstone
import io.github.haige120.cloudreader.domain.ConversationJsonAdapter
import org.junit.Assert.assertEquals
import org.junit.Test

class StorageMapperTest {
    @Test fun bookMappingRetainsLocalFieldsAndOpaqueData() {
        val book = BookRecord(
            id = "book-id", title = "Title", author = "Author", briefDescription = "Description",
            fileName = "book.txt", format = "txt", addedAt = 1.25, lastOpenedAt = 2.5,
            progress = 0.375, isBookmarked = true, modifiedAt = 3.75,
            localLocation = "device-only-offset", unknownJson = "{\"future\":{\"value\":1}}",
        )
        assertEquals(book, book.toRow().toDomain())
    }

    @Test fun tombstoneMappingsRetainUnknownData() {
        val book = BookTombstone("book-id", 1.5, "{\"extra\":true}")
        val chat = ConversationTombstone("chat-id", 2.5, "{\"extra\":2}")
        assertEquals(book, book.toRow().toDomain())
        assertEquals(chat, chat.toRow().toDomain())
    }

    @Test fun conversationPayloadRoundTripRetainsFractionalDatesAndNestedUnknowns() {
        val wire = """{"id":"62B27B43-A87E-402D-8D6A-A70747F50291","title":"Question","messages":[{"id":"DCA22815-A838-45E5-85BC-BA835D550432","role":"user","text":"Hello","createdAt":811100000.125,"futureMessage":{"x":[1,true]}}],"createdAt":811000000.25,"modifiedAt":811200000.375,"futureChat":{"edition":2}}"""
        val decoded = ConversationJsonAdapter.decode(wire)
        val encoded = ConversationJsonAdapter.encode(decoded)
        assertEquals(811000000.25, decoded.createdAt, 0.0)
        assertEquals(811100000.125, decoded.messages.single().createdAt, 0.0)
        assertEquals("{\"futureChat\":{\"edition\":2}}", decoded.unknownJson)
        assertEquals("{\"futureMessage\":{\"x\":[1,true]}}", decoded.messages.single().unknownJson)
        assertEquals(decoded, ConversationJsonAdapter.decode(encoded.toString()))
    }
}
