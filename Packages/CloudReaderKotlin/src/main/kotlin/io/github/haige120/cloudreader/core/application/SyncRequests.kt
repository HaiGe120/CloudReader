package io.github.haige120.cloudreader.core.application

enum class SyncTrigger { MANUAL, LOCAL_CHANGE, FOREGROUND, PROVIDER_SELECTION }

/** Shares overlapping trigger requests; cancellation of the executing request reaches the pass. */
class SyncRequestCoordinator<T>(private val action: suspend (SyncTrigger) -> T) {
    private val guard = Any()
    private var active: kotlinx.coroutines.CompletableDeferred<T>? = null
    private var pendingTrigger: SyncTrigger? = null

    suspend fun request(trigger: SyncTrigger): T {
        val current: kotlinx.coroutines.CompletableDeferred<T>?
        val shared: kotlinx.coroutines.CompletableDeferred<T>
        synchronized(guard) {
            current = active?.takeIf { it.isActive }
            if (current != null && trigger.requiresFollowUp()) pendingTrigger = trigger
            if (current == null) {
                shared = kotlinx.coroutines.CompletableDeferred()
                active = shared
            } else shared = current
        }
        if (current != null) return current.await()
        try {
            var next = trigger
            var value: T
            while (true) {
                value = action(next)
                synchronized(guard) {
                    val pending = pendingTrigger
                    if (pending == null) {
                        shared.complete(value)
                        if (active === shared) active = null
                        return value
                    }
                    pendingTrigger = null
                    next = pending
                }
            }
        } catch (error: Throwable) {
            shared.completeExceptionally(error)
            throw error
        } finally {
            synchronized(guard) {
                if (active === shared) { active = null; pendingTrigger = null }
            }
        }
    }

    private fun SyncTrigger.requiresFollowUp(): Boolean =
        this == SyncTrigger.PROVIDER_SELECTION || this == SyncTrigger.LOCAL_CHANGE
}
