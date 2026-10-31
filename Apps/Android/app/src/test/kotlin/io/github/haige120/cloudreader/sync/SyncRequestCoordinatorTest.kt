package io.github.haige120.cloudreader.sync

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class SyncRequestCoordinatorTest {
    @Test fun overlappingTriggersCoalesceIntoOnePass() = runTest {
        val calls = AtomicInteger()
        val coordinator = SyncRequestCoordinator {
            calls.incrementAndGet()
            delay(100)
            SyncOutcome(listOf("drive"), emptyMap(), 2, 1)
        }
        coroutineScope {
            val first = async { coordinator.request(SyncTrigger.MANUAL) }
            val second = async { coordinator.request(SyncTrigger.FOREGROUND) }
            assertEquals(first.await(), second.await())
        }
        assertEquals(1, calls.get())
    }

    @Test fun cancellationFromExecutingCallerReachesPassAndNextRequestCanRun() = runTest {
        var cancelled = false
        var calls = 0
        val coordinator = SyncRequestCoordinator {
            calls++
            if (calls == 1) try { kotlinx.coroutines.awaitCancellation() } catch (error: CancellationException) {
                cancelled = true; throw error
            }
            SyncOutcome(listOf("drive"), emptyMap(), 1, 0)
        }
        val request = launch { coordinator.request(SyncTrigger.LOCAL_CHANGE) }
        runCurrent()
        request.cancelAndJoin()
        assertEquals(true, cancelled)
        assertEquals(1, coordinator.request(SyncTrigger.MANUAL).books)
        assertEquals(2, calls)
    }

    @Test fun failureIsSharedAndFollowingRequestIsNotBlocked() = runTest {
        var calls = 0
        val coordinator = SyncRequestCoordinator {
            calls++
            if (calls == 1) error("offline")
            SyncOutcome(listOf("drive"), emptyMap(), 1, 0)
        }
        try { coordinator.request(SyncTrigger.MANUAL); throw AssertionError("expected failure") }
        catch (_: IllegalStateException) { }
        assertEquals(1, coordinator.request(SyncTrigger.FOREGROUND).books)
    }

    @Test fun selectionAndLocalChangeArrivingDuringRunScheduleLatestFollowUp() = runTest {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val triggers = mutableListOf<SyncTrigger>()
        val coordinator = SyncRequestCoordinator { trigger ->
            triggers += trigger
            if (triggers.size == 1) { entered.complete(Unit); release.await() }
            SyncOutcome(emptyList(), emptyMap(), triggers.size, 0)
        }
        val running = async { coordinator.request(SyncTrigger.MANUAL) }
        entered.await()
        val selection = async { coordinator.request(SyncTrigger.PROVIDER_SELECTION) }
        val localChange = async { coordinator.request(SyncTrigger.LOCAL_CHANGE) }
        runCurrent()
        release.complete(Unit)
        running.await(); selection.await(); localChange.await()
        assertEquals(listOf(SyncTrigger.MANUAL, SyncTrigger.LOCAL_CHANGE), triggers)
    }

    @Test fun emptySelectionDoesNotConstructAnyStore() = runTest {
        var storeRequests = 0
        val outcome = runSelectedDestinations(emptyList()) { storeRequests++; 1 to 0 }
        assertEquals(0, storeRequests)
        assertEquals(emptyList<String>(), outcome.successful)
        assertEquals(emptyMap<String, String>(), outcome.failed)
    }

    @Test fun partialDestinationFailureRetainsBothDestinationOutcomes() = runTest {
        val calls = mutableListOf<String>()
        val outcome = runSelectedDestinations(listOf("zeta", "alpha")) { provider ->
            calls += provider
            if (provider == "alpha") error("offline")
            3 to 2
        }
        assertEquals(listOf("alpha", "zeta"), calls.take(2))
        assertEquals(listOf("zeta"), outcome.successful)
        assertEquals("offline", outcome.failed["alpha"])
        assertEquals(DestinationOutcome(3, 2), outcome.destinations["zeta"])
        assertEquals("offline", outcome.destinations["alpha"]?.error)
    }

    @Test fun fakeStoreClosesOnSuccessFailureAndCancellation() = runTest {
        class FakeStore : RemoteBookStore {
            var closes = 0
            override suspend fun read(name: String): ByteArray? = null
            override suspend fun write(name: String, bytes: ByteArray) = Unit
            override suspend fun close() { closes++ }
        }
        val success = FakeStore()
        assertEquals("ok", withRemoteStore(success) { "ok" })
        assertEquals(1, success.closes)

        val failure = FakeStore()
        try { withRemoteStore(failure) { error("pass failed") }; throw AssertionError("expected failure") }
        catch (_: IllegalStateException) { }
        assertEquals(1, failure.closes)

        val canceled = FakeStore()
        val request = launch { withRemoteStore(canceled) { kotlinx.coroutines.awaitCancellation() } }
        runCurrent()
        request.cancelAndJoin()
        assertEquals(1, canceled.closes)
    }
}
