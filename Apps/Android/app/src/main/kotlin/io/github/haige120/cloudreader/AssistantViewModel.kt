package io.github.haige120.cloudreader

import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.createSavedStateHandle
import androidx.lifecycle.viewModelScope
import androidx.lifecycle.viewmodel.CreationExtras
import io.github.haige120.cloudreader.ai.AIProfile
import io.github.haige120.cloudreader.domain.BookRecord
import io.github.haige120.cloudreader.domain.ChatMessage
import io.github.haige120.cloudreader.domain.ChatRecord
import io.github.haige120.cloudreader.domain.nowFoundationSeconds
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.launch
import kotlin.coroutines.coroutineContext
import java.util.UUID

data class AssistantUiState(
    val conversations: List<ChatRecord> = emptyList(),
    val activeConversationId: String? = null,
    val draft: String = "",
    val includeContext: Boolean = false,
    val busy: Boolean = false,
    val error: String? = null,
    val pendingReaderContext: AssistantContext? = null,
) {
    val activeConversation: ChatRecord? get() = conversations.firstOrNull { it.id == activeConversationId }
}

/** Inputs resolved by the screen's platform boundary. Book text is loaded only after consent. */
data class AssistantContext(
    val book: BookRecord? = null,
    val selectedText: String? = null,
    val boundedBookText: String? = null,
)

interface AssistantStore {
    val conversations: kotlinx.coroutines.flow.Flow<List<ChatRecord>>
    suspend fun save(chat: ChatRecord)
    suspend fun remove(chat: ChatRecord)
}

fun interface AssistantRequester {
    suspend fun ask(profile: AIProfile, chat: ChatRecord): String
}

class AssistantViewModel(
    private val store: AssistantStore,
    private val requester: AssistantRequester,
    private val savedState: SavedStateHandle = SavedStateHandle(),
) : ViewModel() {
    private val mutableState = MutableStateFlow(AssistantUiState(activeConversationId = savedState[ACTIVE_ID]))
    val state: StateFlow<AssistantUiState> = mutableState.asStateFlow()
    private var requestJob: Job? = null

    init {
        viewModelScope.launch {
            store.conversations.collect { chats ->
                val sorted = chats.sortedByDescending { it.modifiedAt }
                val selected = mutableState.value.activeConversationId
                val active = selected?.let { id -> sorted.firstOrNull { it.id == id } }
                if (selected != null && active == null) selectConversation(null)
                mutableState.value = mutableState.value.copy(
                    conversations = sorted,
                    activeConversationId = active?.id,
                    includeContext = active?.includeBookContext ?: false,
                )
                active?.id?.let { savedState[ACTIVE_ID] = it }
            }
        }
    }

    fun updateDraft(value: String) { mutableState.value = mutableState.value.copy(draft = value) }

    fun selectConversation(id: String?) {
        savedState[ACTIVE_ID] = id
        val chat = mutableState.value.conversations.firstOrNull { it.id == id }
        mutableState.value = mutableState.value.copy(activeConversationId = id, includeContext = chat?.includeBookContext ?: false, error = null, pendingReaderContext = null)
    }

    fun newConversation() = selectConversation(null)

    fun prepareReaderContext(context: AssistantContext) {
        newConversation()
        mutableState.value = mutableState.value.copy(pendingReaderContext = context)
    }

    fun removeConversation(chat: ChatRecord) {
        cancelRequest()
        if (mutableState.value.activeConversationId == chat.id) newConversation()
        viewModelScope.launch { store.remove(chat) }
    }

    fun setContextConsent(allowed: Boolean) {
        val current = mutableState.value
        val active = current.activeConversation
        val updated = active?.copy(
            selectedText = active.selectedText.takeIf { allowed },
            bookContext = active.bookContext.takeIf { allowed },
            contextDescription = active.contextDescription.takeIf { allowed },
            includeBookContext = allowed,
            modifiedAt = nowFoundationSeconds(),
        )
        mutableState.value = current.copy(
            conversations = if (updated == null) current.conversations else current.conversations.map { if (it.id == updated.id) updated else it },
            includeContext = allowed,
        )
        if (updated != null) viewModelScope.launch { store.save(updated) }
    }

    fun send(profile: AIProfile, context: AssistantContext? = null) {
        val current = mutableState.value
        val question = current.draft.trim()
        if (question.isBlank() || current.busy) return
        val old = current.activeConversation
        val consent = current.includeContext
        val preparedContext = context ?: current.pendingReaderContext ?: AssistantContext()
        mutableState.value = current.copy(draft = "", busy = true, error = null)
        requestJob = viewModelScope.launch {
            try {
                val now = nowFoundationSeconds()
                val book = preparedContext.book
                val selected = if (consent) preparedContext.selectedText ?: old?.selectedText else null
                val text = if (consent && selected.isNullOrBlank()) preparedContext.boundedBookText ?: old?.bookContext else null
                val user = ChatMessage(UUID.randomUUID().toString().uppercase(), "user", question, now)
                val withUser = (old ?: ChatRecord(
                    id = UUID.randomUUID().toString().uppercase(), title = "New conversation", messages = emptyList(),
                    createdAt = now, modifiedAt = now,
                )).copy(
                    messages = (old?.messages.orEmpty() + user),
                    bookID = book?.id ?: old?.bookID,
                    bookTitle = book?.title ?: old?.bookTitle,
                    bookDescription = book?.briefDescription ?: old?.bookDescription,
                    selectedText = selected,
                    bookContext = text,
                    contextDescription = if (selected != null) "Selected passage" else if (text != null) "Bounded book excerpt" else null,
                    includeBookContext = consent,
                    modifiedAt = now,
                )
                selectConversation(withUser.id)
                store.save(withUser)
                val answer = requester.ask(profile, withUser.copy(messages = withUser.messages.takeLast(40)))
                val saved = withUser.copy(
                    messages = withUser.messages + ChatMessage(UUID.randomUUID().toString().uppercase(), "assistant", answer, nowFoundationSeconds()),
                    modifiedAt = nowFoundationSeconds(),
                )
                store.save(saved)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (failure: Throwable) {
                mutableState.value = mutableState.value.copy(error = failure.localizedMessage ?: "The AI request failed.")
            } finally {
                if (requestJob === coroutineContext[Job]) {
                    requestJob = null
                    mutableState.value = mutableState.value.copy(busy = false)
                }
            }
        }
    }

    fun retry(profile: AIProfile) {
        val chat = mutableState.value.activeConversation ?: return
        val question = chat.messages.lastOrNull { it.role == "user" } ?: return
        val consent = mutableState.value.includeContext
        val previous = chat.messages.takeWhile { it.id != question.id }
        val retryChat = chat.copy(
            messages = previous,
            selectedText = chat.selectedText.takeIf { consent },
            bookContext = chat.bookContext.takeIf { consent },
            contextDescription = chat.contextDescription.takeIf { consent },
            includeBookContext = consent,
            modifiedAt = nowFoundationSeconds(),
        )
        mutableState.value = mutableState.value.copy(conversations = mutableState.value.conversations.map { if (it.id == chat.id) retryChat else it }, busy = true, error = null)
        requestJob = viewModelScope.launch {
            try {
                store.save(retryChat.copy(messages = previous + question))
                val answer = requester.ask(profile, retryChat.copy(messages = (previous + question).takeLast(40)))
                store.save(retryChat.copy(messages = previous + question + ChatMessage(UUID.randomUUID().toString().uppercase(), "assistant", answer, nowFoundationSeconds()), modifiedAt = nowFoundationSeconds()))
            } catch (cancelled: CancellationException) { throw cancelled }
            catch (failure: Throwable) { mutableState.value = mutableState.value.copy(error = failure.localizedMessage ?: "The AI request failed.") }
            finally {
                if (requestJob === coroutineContext[Job]) {
                    requestJob = null
                    mutableState.value = mutableState.value.copy(busy = false)
                }
            }
        }
    }

    fun cancelRequest() {
        requestJob?.cancel()
        requestJob = null
        mutableState.value = mutableState.value.copy(busy = false, error = "Request canceled. You can retry.")
    }
    fun consumeError() { mutableState.value = mutableState.value.copy(error = null) }

    fun deleteActive() { mutableState.value.activeConversation?.let(::removeConversation) }

    override fun onCleared() { requestJob?.cancel(); requestJob = null }

    companion object {
        private const val ACTIVE_ID = "assistant.activeConversationId"
        fun factory(app: CloudReaderApp): ViewModelProvider.Factory = object : ViewModelProvider.Factory {
            @Suppress("UNCHECKED_CAST")
            override fun <T : ViewModel> create(modelClass: Class<T>, extras: CreationExtras): T {
                require(AssistantViewModel::class.java.isAssignableFrom(modelClass))
                val store = object : AssistantStore {
                    override val conversations = app.library.conversations
                    override suspend fun save(chat: ChatRecord) = app.library.saveChat(chat)
                    override suspend fun remove(chat: ChatRecord) = app.library.removeChat(chat)
                }
                return AssistantViewModel(store, AssistantRequester { profile, chat ->
                    app.ai.ask(profile, chat.messages, chat.bookTitle, chat.selectedText, chat.bookContext)
                }, extras.createSavedStateHandle()) as T
            }
        }
    }
}
