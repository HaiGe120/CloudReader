package io.github.haige120.cloudreader

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class GoogleDriveConnectionViewModelTest {
    @Test fun asynchronousCodeExchangeStaysPendingAndSavesOnlyTheResultingAccessToken() = runTest {
        val exchange = CompletableDeferred<String>()
        val saved = mutableListOf<String>()
        val model = GoogleDriveConnectionViewModel({ saved += it }, backgroundScope)
        model.completeAsync(cancelled = false, hasData = true) { exchange.await() }
        runCurrent()
        assertTrue(model.state.value.busy)
        assertTrue(saved.isEmpty())
        exchange.complete("exchanged-access-token")
        runCurrent()
        assertEquals(listOf("exchanged-access-token"), saved)
        assertEquals("Google Drive connected", model.state.value.message)
    }

    @Test fun asynchronousSetupAndExchangeFailuresAllowRetryWithoutSavingCredentials() = runTest {
        val saved = mutableListOf<String>()
        val model = GoogleDriveConnectionViewModel({ saved += it }, backgroundScope)
        model.connectAsync { _, _ -> throw IllegalStateException("Add a client secret") }
        runCurrent()
        assertEquals("Add a client secret", model.state.value.message)
        assertFalse(model.state.value.busy)
        model.completeAsync(cancelled = true, hasData = true) { throw IllegalStateException("Google rejected the authorization code") }
        runCurrent()
        assertEquals("Google rejected the authorization code", model.state.value.message)
        assertFalse(model.state.value.busy)
        assertTrue(saved.isEmpty())
    }

    @Test fun pendingInteractiveFlowStaysBusyUntilItsTokenIsSaved() = runTest {
        val savedTokens = mutableListOf<String>()
        val saving = CompletableDeferred<Unit>()
        val model = GoogleDriveConnectionViewModel({ token ->
            saving.await()
            savedTokens += token
        }, backgroundScope)
        var deliverToken: ((String) -> Unit)? = null

        model.connect { onToken, _ -> deliverToken = onToken }
        runCurrent()
        assertTrue(model.state.value.busy)
        assertNull(model.state.value.message)

        deliverToken!!("interactive-token")
        runCurrent()
        assertTrue(model.state.value.busy)
        assertNull(model.state.value.message)
        assertTrue(savedTokens.isEmpty())

        saving.complete(Unit)
        runCurrent()
        assertEquals(listOf("interactive-token"), savedTokens)
        assertFalse(model.state.value.busy)
        assertEquals("Google Drive connected", model.state.value.message)
    }

    @Test fun directTokenIsSavedAndDuplicateTapIsIgnored() = runTest {
        val savedTokens = mutableListOf<String>()
        val model = GoogleDriveConnectionViewModel({ savedTokens += it }, backgroundScope)
        var starts = 0
        model.connect { onToken, _ ->
            starts++
            onToken("cached-token")
        }
        model.connect { _, _ -> starts++ }

        assertEquals(1, starts)
        assertTrue(model.state.value.busy)
        runCurrent()
        assertEquals(listOf("cached-token"), savedTokens)
        assertEquals("Google Drive connected", model.state.value.message)
        model.consumeMessage()
        assertNull(model.state.value.message)
    }

    @Test fun nonOkIntentIsParsedAndItsProviderFailureIsVisible() = runTest {
        val model = GoogleDriveConnectionViewModel({ error("Must not save") }, backgroundScope)
        var parsed = false
        model.complete(cancelled = true, hasData = true) {
            parsed = true
            throw IllegalStateException("Google sign-in configuration is invalid (10).")
        }
        assertTrue(parsed)
        assertFalse(model.state.value.busy)
        assertEquals("Google sign-in configuration is invalid (10).", model.state.value.message)
    }

    @Test fun resultAfterRecreationCanSaveWithoutPriorConnectCall() = runTest {
        val savedTokens = mutableListOf<String>()
        val model = GoogleDriveConnectionViewModel({ savedTokens += it }, backgroundScope)
        model.complete(cancelled = false, hasData = true) { "returned-token" }
        assertTrue(model.state.value.busy)
        runCurrent()
        assertEquals(listOf("returned-token"), savedTokens)
        assertEquals("Google Drive connected", model.state.value.message)
    }

    @Test fun noDataCancellationAndMissingResultBothHaveVisibleMessages() = runTest {
        val model = GoogleDriveConnectionViewModel({}, backgroundScope)
        model.connect { _, _ -> }
        model.complete(cancelled = true, hasData = false) { error("No intent to parse") }
        assertFalse(model.state.value.busy)
        assertEquals("Google Drive connection cancelled.", model.state.value.message)

        model.connect { _, _ -> }
        model.complete(cancelled = false, hasData = false) { error("No intent to parse") }
        assertFalse(model.state.value.busy)
        assertEquals("Google Drive did not return a sign-in result. Please try again.", model.state.value.message)
    }

    @Test fun launchAndProviderFailuresAreVisibleAndRetrySucceeds() = runTest {
        val savedTokens = mutableListOf<String>()
        val model = GoogleDriveConnectionViewModel({ savedTokens += it }, backgroundScope)
        model.connect { _, _ -> throw IllegalStateException("Could not open Google sign-in") }
        assertFalse(model.state.value.busy)
        assertEquals("Could not open Google sign-in", model.state.value.message)

        model.connect { _, onError -> onError(IllegalStateException("Google authorization failed")) }
        assertFalse(model.state.value.busy)
        assertEquals("Google authorization failed", model.state.value.message)

        model.connect { _, _ -> }
        model.fail(IllegalStateException("The consent screen is unavailable"))
        assertFalse(model.state.value.busy)
        assertEquals("The consent screen is unavailable", model.state.value.message)

        model.connect { onToken, _ -> onToken("retry-token") }
        runCurrent()
        assertEquals(listOf("retry-token"), savedTokens)
        assertEquals("Google Drive connected", model.state.value.message)
    }

    @Test fun credentialSaveFailureNeverClaimsSuccessAndCanBeRetried() = runTest {
        var saves = 0
        val model = GoogleDriveConnectionViewModel({
            saves++
            if (saves == 1) throw IllegalStateException("Could not save Google credentials")
        }, backgroundScope)
        model.connect { onToken, _ -> onToken("token") }
        runCurrent()
        assertFalse(model.state.value.busy)
        assertEquals("Could not save Google credentials", model.state.value.message)

        model.connect { onToken, _ -> onToken("token") }
        assertNull(model.state.value.message)
        runCurrent()
        assertEquals(2, saves)
        assertEquals("Google Drive connected", model.state.value.message)
    }

    @Test fun blankTokenAndMessageLessFailureHaveUsefulErrors() = runTest {
        val model = GoogleDriveConnectionViewModel({ error("Must not save") }, backgroundScope)
        model.connect { onToken, _ -> onToken(" ") }
        assertFalse(model.state.value.busy)
        assertEquals("Google Drive did not return an access token. Please try again.", model.state.value.message)

        model.fail(IllegalStateException())
        assertEquals("Google Drive connection failed. Please try again.", model.state.value.message)
    }

    @Test fun coroutineCancellationResetsBusyWithoutReportingAConnectionFailure() = runTest {
        val model = GoogleDriveConnectionViewModel({ throw CancellationException("Stopped") }, backgroundScope)
        model.connect { onToken, _ -> onToken("token") }
        runCurrent()
        assertFalse(model.state.value.busy)
        assertNull(model.state.value.message)
    }
}
