package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.merge.MergePolicy
import io.github.haige120.cloudreader.core.model.BookRecord
import io.github.haige120.cloudreader.core.model.BookTombstone
import io.github.haige120.cloudreader.core.model.ChatMessage
import io.github.haige120.cloudreader.core.model.ChatRecord
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class MergePolicyTest {
    private val bookID = "00000000-0000-0000-0000-000000000101"
    private val chatID = "00000000-0000-0000-0000-000000000201"
    private val messageID = "00000000-0000-0000-0000-000000000301"

    private fun book(title: String, time: Double, unknown: String = "{}") = BookRecord(bookID, title, fileName = "book.txt", format = "txt", addedAt = 1.0, modifiedAt = time, unknownJson = unknown)

    @Test fun equalTimeBookUsesPortableCanonicalWinnerAndKeepsOpaqueRecovery() {
        val alpha = MergePolicy.BookCandidate(book("Alpha", 7.0, "{\"future\":\"z\"}"), "a")
        val beta = MergePolicy.BookCandidate(book("Beta", 7.0, "{\"future\":\"a\"}"), "b")
        val result = MergePolicy.mergeBooks(listOf(beta, alpha))
        assertEquals("Alpha", result.primary?.book?.title)
        assertTrue(result.primary?.book?.unknownJson?.contains("a") == true)
        assertTrue(result.recovery.any { it.toString().contains("future") && it.toString().contains("z") })
    }

    @Test fun chatMergesMessagesByCanonicalIdAndOrdersByTimeThenId() {
        val first = ChatMessage(messageID, "user", "first", 2.0)
        val second = ChatMessage(messageID, "user", "second", 2.0)
        val one = ChatMessage("00000000-0000-0000-0000-000000000302", "assistant", "reply", 1.0)
        val a = ChatRecord(chatID, "Chat", listOf(first, one), createdAt = 1.0, modifiedAt = 3.0)
        val b = ChatRecord(chatID, "Chat", listOf(second), createdAt = 2.0, modifiedAt = 3.0)
        val merged = MergePolicy.mergeChats(a, b)
        assertEquals(listOf(one.id, messageID), merged.messages.map { it.id })
        assertEquals("first", merged.messages.last().text)
        assertEquals(1.0, merged.createdAt, 0.0)
        assertEquals(3.0, merged.modifiedAt, 0.0)
        assertEquals(2, MergePolicy.chatCollisionRecovery(a, b).count { it["kind"].toString().contains("message") })
    }

    @Test fun tombstoneEqualitySuppressesRecordAndNewestTombstoneWins() {
        assertTrue(!MergePolicy.survives(5.0, 5.0))
        assertTrue(MergePolicy.survives(5.0001, 5.0))
        val first = BookTombstone(bookID, 4.0, "{\"a\":1}")
        val second = BookTombstone(bookID.lowercase(), 5.0, "{\"b\":2}")
        val merged = MergePolicy.mergeBookTombstones(listOf(first, second)).first.single()
        assertEquals(5.0, merged.deletedAt, 0.0)
        assertEquals(bookID, merged.bookID)
        assertTrue(merged.unknownJson.contains("a"))
        assertTrue(merged.unknownJson.contains("b"))
    }

    @Test fun canonicalNumbersFollowJcsBoundaries() {
        assertEquals("0.000001", MergePolicy.canonicalNumber(0.000001))
        assertEquals("1e-7", MergePolicy.canonicalNumber(1e-7))
        assertEquals("1e+21", MergePolicy.canonicalNumber(1e21))
        assertEquals("123000000000000000000", MergePolicy.canonicalNumber(1.23e20))
        assertEquals("{\"a\":null,\"z\":false}", MergePolicy.canonical(Json.parseToJsonElement("{\"z\":false,\"a\":null}")))
    }
}
