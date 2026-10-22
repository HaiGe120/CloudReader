package io.github.haige120.cloudreader

import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ReaderSessionTest {
    private data class Write(val bookId: String, val progress: Double, val location: String)

    @Test fun debounceWritesOnlyLatestCheckpoint() = runTest {
        val writes = mutableListOf<Write>()
        val session = ReaderSession("stable-book-id", this, ReaderProgressWriter { id, progress, location ->
            writes += Write(id, progress, location)
        })

        session.checkpoint(0.2, "txt:20:utf16")
        advanceTimeBy(300)
        session.checkpoint(0.4, "txt:40:utf16")
        advanceTimeBy(449)
        assertEquals(emptyList<Write>(), writes)
        advanceTimeBy(1)
        advanceUntilIdle()

        assertEquals(listOf(Write("stable-book-id", 0.4, "txt:40:utf16")), writes)
    }

    @Test fun explicitFlushWritesImmediatelyAndCancelsDebounce() = runTest {
        val writes = mutableListOf<Write>()
        val session = ReaderSession("book", this, ReaderProgressWriter { id, progress, location ->
            writes += Write(id, progress, location)
        })
        session.checkpoint(0.75, "txt:75:utf16")

        session.flush()
        assertEquals(listOf(Write("book", 0.75, "txt:75:utf16")), writes)
        advanceTimeBy(1_000)
        advanceUntilIdle()
        assertEquals(1, writes.size)
    }

    @Test fun lifecycleFlushPersistsPdfLocationAndClampsPortableProgress() = runTest {
        data class FakeRow(val progress: Double, val location: String?, val bookmarked: Boolean)
        val rows = mutableMapOf("pdf-id" to FakeRow(0.1, "pdf:0", bookmarked = true))
        val writes = mutableListOf<Write>()
        val writer = ReaderProgressWriter { id, progress, location ->
            writes += Write(id, progress, location)
            val row = rows[id] ?: return@ReaderProgressWriter
            rows[id] = row.copy(progress = progress, location = location)
        }
        val session = ReaderSession("pdf-id", this, writer)
        session.checkpoint(1.2, "pdf:8")

        // The stop handler delegates to the same flush boundary as an explicit close.
        session.flush()

        assertEquals(listOf(Write("pdf-id", 1.0, "pdf:8")), writes)
        assertEquals(FakeRow(1.0, "pdf:8", bookmarked = true), rows["pdf-id"])
    }

    @Test fun checkpointArrivingDuringWriteIsPersistedAfterTheOlderWrite() = runTest {
        val writes = mutableListOf<Write>()
        val firstWriteStarted = CompletableDeferred<Unit>()
        val finishFirstWrite = CompletableDeferred<Unit>()
        val session = ReaderSession("book", this, ReaderProgressWriter { id, progress, location ->
            writes += Write(id, progress, location)
            if (progress == 0.2) {
                firstWriteStarted.complete(Unit)
                finishFirstWrite.await()
            }
        })

        session.checkpoint(0.2, "txt:20:utf16")
        val olderFlush = async { session.flush() }
        firstWriteStarted.await()

        session.checkpoint(0.8, "txt:80:utf16")
        val newerFlush = async { session.flush() }
        finishFirstWrite.complete(Unit)
        olderFlush.await()
        newerFlush.await()

        assertEquals(
            listOf(Write("book", 0.2, "txt:20:utf16"), Write("book", 0.8, "txt:80:utf16")),
            writes,
        )
    }
}
