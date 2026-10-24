package io.github.haige120.cloudreader.desktop

import io.github.haige120.cloudreader.core.contract.SyncCodec
import io.github.haige120.cloudreader.core.model.BookRecord
import org.junit.Assert.assertEquals
import org.junit.Test

class CoreContractSmokeTest {
    @Test
    fun desktopResolvesPortableBookObjectNamesThroughSharedCore() {
        val book = BookRecord(
            id = "0E7B7B49-9652-4E82-BA2E-84F58CC90D46",
            title = "The Open Shelf",
            fileName = "local.txt",
            format = "txt",
            addedAt = 0.0,
            modifiedAt = 0.0,
        )
        assertEquals(
            "book-0E7B7B49-9652-4E82-BA2E-84F58CC90D46.txt",
            SyncCodec.bookObjectName(book),
        )
    }
}
