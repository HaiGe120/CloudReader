package io.github.haige120.cloudreader

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** UTF-16 offsets use the same indexing convention as Android TextView and Kotlin String. */
internal fun validTextOffset(localLocation: String?, textLength: Int): Int? {
    if (textLength < 0 || localLocation == null) return null
    val match = Regex("^txt:(\\d+):utf16$").matchEntire(localLocation) ?: return null
    val offset = match.groupValues[1].toIntOrNull() ?: return null
    return offset.takeIf { it in 0..textLength }
}

internal fun textOffsetForProgress(progress: Double, textLength: Int): Int =
    (progress.coerceIn(0.0, 1.0) * textLength.coerceAtLeast(0)).toInt()

/** Writes only reader progress fields, resolving the current library row by [bookId]. */
internal fun interface ReaderProgressWriter {
    suspend fun write(bookId: String, progress: Double, localLocation: String)
}

/** Owns one book's pending location and debounce/flush behavior independently of its UI host. */
internal class ReaderSession(
    private val bookId: String,
    private val scope: CoroutineScope,
    private val writer: ReaderProgressWriter,
    private val debounceMillis: Long = 450,
) {
    private data class Checkpoint(val progress: Double, val localLocation: String)

    private val stateLock = Any()
    private val writeLock = Mutex()
    private var pending: Checkpoint? = null
    private var debounceJob: Job? = null
    private var generation = 0L

    fun checkpoint(progress: Double, localLocation: String) {
        synchronized(stateLock) {
            pending = Checkpoint(progress.coerceIn(0.0, 1.0), localLocation)
            val currentGeneration = ++generation
            debounceJob?.cancel()
            debounceJob = scope.launch {
                delay(debounceMillis)
                val shouldFlush = synchronized(stateLock) {
                    if (generation != currentGeneration) false
                    else {
                        debounceJob = null
                        true
                    }
                }
                if (shouldFlush) flush(cancelDebounce = false)
            }
        }
    }

    suspend fun flush(cancelDebounce: Boolean = true) {
        if (cancelDebounce) {
            synchronized(stateLock) {
                debounceJob?.cancel()
                debounceJob = null
            }
        }
        writeLock.withLock {
            val checkpoint = synchronized(stateLock) {
                pending.also { pending = null }
            }
            if (checkpoint != null) {
                try {
                    writer.write(bookId, checkpoint.progress, checkpoint.localLocation)
                } catch (failure: Throwable) {
                    synchronized(stateLock) {
                        if (pending == null) pending = checkpoint
                    }
                    throw failure
                }
            }
        }
    }
}
