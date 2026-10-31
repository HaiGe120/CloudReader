package io.github.haige120.cloudreader.data

import androidx.room.Entity
import androidx.room.PrimaryKey
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.BookTombstone
import io.github.haige120.cloudreader.domain.ConversationTombstone

// Room v1 rows. Keep these property names and types aligned with the exported schema.
@Entity(tableName = "books")
data class BookRow(
    @PrimaryKey val id: String,
    val title: String,
    val author: String? = null,
    val briefDescription: String? = null,
    val fileName: String,
    val format: String,
    val addedAt: Double,
    val lastOpenedAt: Double? = null,
    val progress: Double = 0.0,
    val isBookmarked: Boolean = false,
    val modifiedAt: Double,
    val localLocation: String? = null,
    val unknownJson: String = "{}",
)

@Entity(tableName = "book_deletions")
data class BookTombstoneRow(@PrimaryKey val bookID: String, val deletedAt: Double, val unknownJson: String = "{}")

@Entity(tableName = "conversations")
data class ConversationRow(@PrimaryKey val id: String, val wireJson: String, val modifiedAt: Double)

@Entity(tableName = "conversation_deletions")
data class ConversationTombstoneRow(@PrimaryKey val conversationID: String, val deletedAt: Double, val unknownJson: String = "{}")

fun BookRow.toDomain() = BookRecord(
    id, title, author, briefDescription, fileName, format, addedAt, lastOpenedAt,
    progress, isBookmarked, modifiedAt, localLocation, unknownJson,
)

fun BookRecord.toRow() = BookRow(
    id, title, author, briefDescription, fileName, format, addedAt, lastOpenedAt,
    progress, isBookmarked, modifiedAt, localLocation, unknownJson,
)

fun BookTombstoneRow.toDomain() = BookTombstone(bookID, deletedAt, unknownJson)
fun BookTombstone.toRow() = BookTombstoneRow(bookID, deletedAt, unknownJson)
fun ConversationTombstoneRow.toDomain() = ConversationTombstone(conversationID, deletedAt, unknownJson)
fun ConversationTombstone.toRow() = ConversationTombstoneRow(conversationID, deletedAt, unknownJson)
