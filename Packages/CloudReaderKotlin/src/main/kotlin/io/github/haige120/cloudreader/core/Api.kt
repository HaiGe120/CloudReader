@file:Suppress("unused")

package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.contract.SyncCodec as ContractSyncCodec
import io.github.haige120.cloudreader.core.merge.MergePolicy as CoreMergePolicy
import io.github.haige120.cloudreader.core.model.BookFormat as ModelBookFormat
import io.github.haige120.cloudreader.core.model.BookRecord as ModelBookRecord
import io.github.haige120.cloudreader.core.model.BookTombstone as ModelBookTombstone
import io.github.haige120.cloudreader.core.model.ChatMessage as ModelChatMessage
import io.github.haige120.cloudreader.core.model.ChatRecord as ModelChatRecord
import io.github.haige120.cloudreader.core.model.ConversationTombstone as ModelConversationTombstone
import io.github.haige120.cloudreader.core.model.LibrarySnapshot as ModelLibrarySnapshot
import io.github.haige120.cloudreader.core.contract.SyncManifest as ContractSyncManifest
import io.github.haige120.cloudreader.core.contract.SyncedBook as ContractSyncedBook

typealias BookFormat = ModelBookFormat
typealias BookRecord = ModelBookRecord
typealias BookTombstone = ModelBookTombstone
typealias ChatMessage = ModelChatMessage
typealias ChatRecord = ModelChatRecord
typealias ConversationTombstone = ModelConversationTombstone
typealias LibrarySnapshot = ModelLibrarySnapshot
typealias SyncedBook = ContractSyncedBook
typealias SyncManifest = ContractSyncManifest
typealias MergePolicy = CoreMergePolicy

/** Facade kept in the root package for desktop callers that do not need package-level layering. */
public object SyncCodec {
    public fun bookToJson(book: BookRecord) = ContractSyncCodec.bookToJson(book)
    public fun bookFromJson(obj: kotlinx.serialization.json.JsonObject) = ContractSyncCodec.bookFromJson(obj)
    public fun chatToJson(chat: ChatRecord) = ContractSyncCodec.chatToJson(chat)
    public fun chatFromJson(value: String) = ContractSyncCodec.chatFromJson(value)
    public fun chatFromJson(obj: kotlinx.serialization.json.JsonObject) = ContractSyncCodec.chatFromJson(obj)
    public fun manifestToJson(manifest: SyncManifest) = ContractSyncCodec.manifestToJson(manifest)
    public fun manifestToBytes(manifest: SyncManifest) = ContractSyncCodec.manifestToBytes(manifest)
    public fun manifestFromJson(value: String) = ContractSyncCodec.manifestFromJson(value)
    public fun manifestFromJson(bytes: ByteArray) = ContractSyncCodec.manifestFromJson(bytes)
    public fun bookObjectName(book: BookRecord) = ContractSyncCodec.bookObjectName(book)
}

public fun canonicalUUID(value: String): String = io.github.haige120.cloudreader.core.model.canonicalUUID(value)
public fun nowFoundationSeconds(): Double = io.github.haige120.cloudreader.core.model.nowFoundationSeconds()
