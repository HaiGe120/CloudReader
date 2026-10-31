package io.github.haige120.cloudreader.sync

import kotlinx.coroutines.flow.asFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import org.junit.Assert.assertEquals
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SyncTriggerFlowsTest {
    @Test fun skipsInitialSelectionAndEmitsDistinctSubsequentChanges() = runTest {
        val snapshots = listOf(setOf("drive"), setOf("drive"), setOf("drive", "webDAV"), setOf("drive", "webDAV"), emptySet())
        assertEquals(listOf(setOf("drive", "webDAV"), emptySet()), snapshots.asFlow().afterInitialDistinct().toList())
    }

    @Test fun changedSelectionObservedDuringRunQueuesCoordinatorFollowUp() = runTest {
        val selection = MutableStateFlow(setOf("drive"))
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val triggers = mutableListOf<SyncTrigger>()
        val coordinator = SyncRequestCoordinator { trigger ->
            triggers += trigger
            if (triggers.size == 1) { entered.complete(Unit); release.await() }
            SyncOutcome(emptyList(), emptyMap(), triggers.size, 0)
        }
        val watching = launch {
            selection.afterInitialDistinct().collect {
                launch { coordinator.request(SyncTrigger.PROVIDER_SELECTION) }
            }
        }
        val foreground = async { coordinator.request(SyncTrigger.FOREGROUND) }
        entered.await()
        selection.value = setOf("drive", "webDAV")
        runCurrent()
        release.complete(Unit)
        foreground.await()
        runCurrent()
        watching.cancel()

        assertEquals(listOf(SyncTrigger.FOREGROUND, SyncTrigger.PROVIDER_SELECTION), triggers)
    }
}
