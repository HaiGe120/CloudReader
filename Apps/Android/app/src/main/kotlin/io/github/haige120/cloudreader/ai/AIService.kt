package io.github.haige120.cloudreader.ai

import io.github.haige120.cloudreader.domain.ChatMessage
import io.github.haige120.cloudreader.data.SecureVault
import io.github.haige120.cloudreader.core.assistant.AIProfile as SharedAIProfile
import io.github.haige120.cloudreader.core.assistant.buildAIPayload as sharedBuildAIPayload
import io.github.haige120.cloudreader.core.assistant.buildAIInstructions as sharedBuildAIInstructions
import io.github.haige120.cloudreader.core.assistant.decodeAIAnswer as sharedDecodeAIAnswer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Call
import okhttp3.Callback
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URI
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

typealias AIProfile = io.github.haige120.cloudreader.core.assistant.AIProfile

class AIService private constructor(apiKey: () -> String?, calls: Call.Factory) {
    constructor(vault: SecureVault, http: OkHttpClient = OkHttpClient()) : this({ vault.get("ai.apiKey") }, http)
    private val service = io.github.haige120.cloudreader.core.assistant.RemoteAssistant(apiKey, calls)
    suspend fun ask(profile: AIProfile, messages: List<ChatMessage>, bookTitle: String? = null, selectedText: String? = null, bookContext: String? = null) =
        service.ask(profile, messages, bookTitle, selectedText, bookContext)
    companion object {
        internal fun forTesting(apiKey: () -> String?, calls: Call.Factory) = AIService(apiKey, calls)
    }
}

internal fun buildAIInstructions(bookTitle: String?, selectedText: String?, bookContext: String?): String =
    sharedBuildAIInstructions(bookTitle, selectedText, bookContext)

internal fun buildAIPayload(profile: AIProfile, messages: List<ChatMessage>, instructions: String): JsonObject {
    val sharedMessages = messages.map {
        io.github.haige120.cloudreader.core.model.ChatMessage(it.id, it.role, it.text, it.createdAt, it.unknownJson)
    }
    return sharedBuildAIPayload(SharedAIProfile(profile.name, profile.protocol, profile.endpoint, profile.model), sharedMessages, instructions)
}

internal fun decodeAIAnswer(protocol: String, obj: JsonObject): String = sharedDecodeAIAnswer(protocol, obj)
