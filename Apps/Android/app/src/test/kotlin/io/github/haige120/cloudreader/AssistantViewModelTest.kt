package io.github.haige120.cloudreader

import androidx.lifecycle.SavedStateHandle
import io.github.haige120.cloudreader.ai.AIProfile
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.ChatMessage
import io.github.haige120.cloudreader.domain.ChatRecord
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.StandardTestDispatcher
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AssistantViewModelTest {
    private val dispatcher = StandardTestDispatcher()

    @Before fun setMain() { Dispatchers.setMain(dispatcher) }
    @After fun resetMain() { Dispatchers.resetMain() }

    @Test fun restoresSelectedConversationAndItsSavedConsent() = runTest(dispatcher) {
        val chat = chat("saved", includeContext = true)
        val store = FakeStore(listOf(chat))
        val handle = SavedStateHandle(mapOf("assistant.activeConversationId" to chat.id))
        val model = AssistantViewModel(store, AssistantRequester { _, _ -> "answer" }, handle)
        runCurrent()
        assertEquals(chat.id, model.state.value.activeConversationId)
        assertTrue(model.state.value.includeContext)
    }

    @Test fun newConversationDefaultsToNoContextAndPersistsUserAndAssistantHistory() = runTest(dispatcher) {
        val store = FakeStore()
        val requested = mutableListOf<ChatRecord>()
        val model = AssistantViewModel(store, AssistantRequester { _, chat -> requested += chat; "answer" })
        runCurrent()
        model.setContextConsent(false)
        model.updateDraft("  What is this?  ")
        model.send(AIProfile(model = "test"), AssistantContext(BookRecord("book", "Title", briefDescription = "About", fileName = "a.txt", format = "txt", addedAt = 1.0, modifiedAt = 1.0), "private passage", "private text"))
        advanceUntilIdle()
        val saved = store.chats.value.single()
        assertEquals(listOf("What is this?", "answer"), saved.messages.map { it.text })
        assertNull(saved.selectedText)
        assertNull(saved.bookContext)
        assertFalse(saved.includeBookContext)
        assertNull(requested.single().selectedText)
        assertEquals(2, saved.messages.size)
    }

    @Test fun incomingReaderContextStaysAvailableUntilSendingAndRequiresConsent() = runTest(dispatcher) {
        val store = FakeStore()
        var requested: ChatRecord? = null
        val model = AssistantViewModel(store, AssistantRequester { _, chat -> requested = chat; "answer" })
        runCurrent()
        val book = BookRecord("book", "Title", fileName = "a.txt", format = "txt", addedAt = 1.0, modifiedAt = 1.0)
        val context = AssistantContext(book, "selected passage")

        model.prepareReaderContext(context)
        assertEquals(context, model.state.value.pendingReaderContext)
        assertFalse(model.state.value.includeContext)
        assertTrue(store.chats.value.isEmpty())

        model.setContextConsent(true)
        model.updateDraft("Explain this")
        model.send(AIProfile(model = "test"))
        advanceUntilIdle()

        assertEquals("selected passage", requested?.selectedText)
        assertEquals(book.id, requested?.bookID)
        assertTrue(requested?.includeBookContext == true)
        assertNull(model.state.value.pendingReaderContext)
    }

    @Test fun incomingReaderContextIsNotSentWithoutOptIn() = runTest(dispatcher) {
        val store = FakeStore()
        var requested: ChatRecord? = null
        val model = AssistantViewModel(store, AssistantRequester { _, chat -> requested = chat; "answer" })
        runCurrent()
        model.prepareReaderContext(AssistantContext(selectedText = "private passage", boundedBookText = "private text"))
        model.updateDraft("Question without context")
        model.send(AIProfile(model = "test"))
        advanceUntilIdle()

        assertNull(requested?.selectedText)
        assertNull(requested?.bookContext)
        assertFalse(requested?.includeBookContext ?: true)
        assertNull(model.state.value.pendingReaderContext)
    }

    @Test fun explicitlyChangingConversationDiscardsPendingReaderContext() = runTest(dispatcher) {
        val saved = chat("saved")
        val model = AssistantViewModel(FakeStore(listOf(saved)), AssistantRequester { _, _ -> "answer" })
        runCurrent()
        model.prepareReaderContext(AssistantContext(selectedText = "first passage"))
        model.selectConversation(saved.id)
        assertNull(model.state.value.pendingReaderContext)
        assertEquals(saved.id, model.state.value.activeConversationId)

        model.prepareReaderContext(AssistantContext(selectedText = "second passage"))
        model.newConversation()
        assertNull(model.state.value.pendingReaderContext)
        assertFalse(model.state.value.includeContext)
    }

    @Test fun cancellationLeavesTheUserQuestionSavedAndRetryCanFinishIt() = runTest(dispatcher) {
        val store = FakeStore()
        val gate = CompletableDeferred<String>()
        var callCount = 0
        val model = AssistantViewModel(store, AssistantRequester { _, _ ->
            callCount++
            if (callCount == 1) gate.await() else "retried"
        })
        runCurrent()
        model.updateDraft("question")
        model.send(AIProfile(model = "test"))
        runCurrent()
        assertTrue(model.state.value.busy)
        assertEquals("question", store.chats.value.single().messages.single().text)
        model.cancelRequest()
        runCurrent()
        assertFalse(model.state.value.busy)
        assertEquals(1, store.chats.value.single().messages.size)
        model.retry(AIProfile(model = "test"))
        advanceUntilIdle()
        assertEquals(listOf("question", "retried"), store.chats.value.single().messages.map { it.text })
        assertFalse(model.state.value.busy)
    }

    @Test fun retryUsesCurrentConsentAndDoesNotResendPreviouslySavedContextAfterOptOut() = runTest(dispatcher) {
        val saved = chat("context-chat", includeContext = true).copy(selectedText = "private passage")
        val store = FakeStore(listOf(saved))
        var asked: ChatRecord? = null
        var calls = 0
        val model = AssistantViewModel(store, AssistantRequester { _, chat ->
            calls++
            asked = chat
            if (calls == 1) error("temporary failure")
            "answer"
        }, SavedStateHandle(mapOf("assistant.activeConversationId" to saved.id)))
        runCurrent()
        model.updateDraft("follow up")
        model.send(AIProfile(model = "test"))
        advanceUntilIdle()
        model.setContextConsent(false)
        model.retry(AIProfile(model = "test"))
        advanceUntilIdle()
        assertNull(asked?.selectedText)
        assertNull(store.chats.value.single().selectedText)
        assertFalse(store.chats.value.single().includeBookContext)
    }

    @Test fun contextConsentChangesPersistAndOptOutClearsSavedBookText() = runTest(dispatcher) {
        val saved = chat("context-chat", includeContext = true).copy(
            selectedText = "private passage",
            bookContext = "private excerpt",
            contextDescription = "Selected passage",
        )
        val store = FakeStore(listOf(saved))
        val handle = SavedStateHandle(mapOf("assistant.activeConversationId" to saved.id))
        val model = AssistantViewModel(store, AssistantRequester { _, _ -> "answer" }, handle)
        runCurrent()

        model.setContextConsent(false)
        advanceUntilIdle()

        val persisted = store.chats.value.single()
        assertFalse(persisted.includeBookContext)
        assertNull(persisted.selectedText)
        assertNull(persisted.bookContext)
        assertNull(persisted.contextDescription)

        val restored = AssistantViewModel(store, AssistantRequester { _, _ -> "answer" }, handle)
        runCurrent()
        assertFalse(restored.state.value.includeContext)
    }

    private class FakeStore(initial: List<ChatRecord> = emptyList()) : AssistantStore {
        val chats = MutableStateFlow(initial)
        override val conversations = chats
        override suspend fun save(chat: ChatRecord) { chats.value = chats.value.filterNot { it.id == chat.id } + chat }
        override suspend fun remove(chat: ChatRecord) { chats.value = chats.value.filterNot { it.id == chat.id } }
    }

    private fun chat(id: String, includeContext: Boolean = false) = ChatRecord(
        id = id, title = "saved", messages = listOf(ChatMessage("m", "user", "hello", 1.0)),
        selectedText = "passage", includeBookContext = includeContext, createdAt = 1.0, modifiedAt = 1.0,
    )
}
