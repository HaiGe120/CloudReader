package io.github.haige120.cloudreader.core.assistant

import io.github.haige120.cloudreader.core.model.ChatMessage
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

class RemoteAssistant(
    private val apiKey: () -> String?,
    private val calls: Call.Factory = OkHttpClient(),
) {
    private val json = Json { ignoreUnknownKeys = true }

    suspend fun ask(profile: AIProfile, messages: List<ChatMessage>, bookTitle: String? = null, selectedText: String? = null, bookContext: String? = null): String {
        require(profile.model.isNotBlank()) { "Add a model name in Settings." }
        val key = apiKey()?.takeIf { it.isNotBlank() } ?: throw IllegalStateException("Add an AI API key in Settings.")
        val endpoint = endpoint(profile)
        val instructions = buildAIInstructions(bookTitle, selectedText, bookContext)
        val payload = buildAIPayload(profile, messages, instructions)
        val request = Request.Builder().url(endpoint).post(payload.toString().toRequestBody("application/json".toMediaType())).apply {
            when (profile.protocol) {
                "anthropicMessages" -> header("x-api-key", key).header("anthropic-version", "2023-06-01")
                else -> header("Authorization", "Bearer $key")
            }
            header("Content-Type", "application/json")
        }.build()
        return withContext(Dispatchers.IO) { execute(request).use { response ->
            val body = response.body?.string().orEmpty()
            if (response.code == 401 || response.code == 403) throw IllegalStateException("AI authentication failed (HTTP ${response.code}). Check the API key and its permissions.")
            if (response.code == 429) throw IllegalStateException("The AI provider rate limit was reached. Wait a little, then try again.")
            if (!response.isSuccessful) throw IllegalStateException("AI provider returned HTTP ${response.code}: ${body.take(500)}")
            decodeAIAnswer(profile.protocol, json.parseToJsonElement(body).jsonObject).ifBlank { throw IllegalStateException("The AI provider returned no readable text.") }
        } }
    }

    private suspend fun execute(request: Request): Response = suspendCancellableCoroutine { continuation ->
        val call = calls.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: java.io.IOException) {
                if (continuation.isActive) continuation.resumeWithException(e)
            }

            override fun onResponse(call: Call, response: Response) {
                if (continuation.isActive) continuation.resume(response) { _, value, _ -> value.close() }
                else response.close()
            }
        })
    }

    private fun endpoint(profile: AIProfile): String {
        val default = when (profile.protocol) {
            "openAIChatCompletions" -> "https://api.openai.com/v1/chat/completions"
            "openAIResponses" -> "https://api.openai.com/v1/responses"
            "anthropicMessages" -> "https://api.anthropic.com/v1/messages"
            else -> throw IllegalArgumentException("Choose an AI protocol in Settings.")
        }
        val value = profile.endpoint.ifBlank { default }
        val uri = URI(value)
        val secure = uri.scheme.equals("https", true) && !uri.host.isNullOrBlank()
        val localDevelopment = uri.scheme.equals("http", true) && uri.host in setOf("localhost", "127.0.0.1", "::1")
        require(secure || localDevelopment) { "Use an HTTPS endpoint. HTTP is allowed only for localhost development." }
        return value
    }

}
