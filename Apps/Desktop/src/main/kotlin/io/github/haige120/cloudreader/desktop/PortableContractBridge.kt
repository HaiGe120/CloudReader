package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.contract.SyncCodec
import io.github.haige120.cloudreader.core.model.BookRecord as PortableBookRecord

/**
 * Keeps device-local records separate from the v1 wire model while routing
 * portable object naming through the shared Kotlin implementation.
 */
object PortableContractBridge {
    fun objectName(id: BookId, format: BookFormat): String = SyncCodec.bookObjectName(
        PortableBookRecord(
            id = id.value,
            title = "",
            fileName = "",
            format = format.extension,
            addedAt = 0.0,
            modifiedAt = 0.0,
        ),
    )
}
