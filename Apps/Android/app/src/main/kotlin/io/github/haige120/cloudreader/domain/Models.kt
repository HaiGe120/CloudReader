package io.github.haige120.cloudreader.domain

// Legacy import paths remain source compatible; values have one Kotlin owner.
typealias BookFormat = io.github.haige120.cloudreader.core.model.BookFormat
typealias BookRecord = io.github.haige120.cloudreader.core.model.BookRecord
typealias BookTombstone = io.github.haige120.cloudreader.core.model.BookTombstone
typealias ConversationTombstone = io.github.haige120.cloudreader.core.model.ConversationTombstone
typealias ChatMessage = io.github.haige120.cloudreader.core.model.ChatMessage
typealias ChatRecord = io.github.haige120.cloudreader.core.model.ChatRecord
typealias LibrarySnapshot = io.github.haige120.cloudreader.core.model.LibrarySnapshot
fun nowFoundationSeconds() = io.github.haige120.cloudreader.core.model.nowFoundationSeconds()
fun canonicalUUID(value: String) = io.github.haige120.cloudreader.core.model.canonicalUUID(value)

object DemoBook {
    const val ID = "0E7B7B49-9652-4E82-BA2E-84F58CC90D46"
    const val TITLE = "The Open Shelf"
    const val AUTHOR = "The CloudReader Project"
    const val ADDED_AT = 1_767_225_600.0 - 978_307_200.0
    const val DESCRIPTION = "An original field guide to CloudReader’s goals, reading experience, portable library, cloud sync, privacy, and reader-controlled AI."
}
