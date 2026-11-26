package io.github.haige120.cloudreader.ai

import io.github.haige120.cloudreader.domain.ChatMessage
import io.github.haige120.cloudreader.data.SecureVault
import io.github.haige120.cloudreader.core.assistant.buildAIPayload as sharedBuildAIPayload
import io.github.haige120.cloudreader.core.assistant.buildAIInstructions as sharedBuildAIInstructions
import io.github.haige120.cloudreader.core.assistant.decodeAIAnswer as sharedDecodeAIAnswer
import kotlinx.serialization.json.JsonObject
import okhttp3.Call
import okhttp3.OkHttpClient
import okhttp3.HttpUrl.Companion.toHttpUrl
import io.github.haige120.cloudreader.core.assistant.RemoteAssistant
import io.github.haige120.cloudreader.data.CloudReaderPreferences

typealias AIProfile = io.github.haige120.cloudreader.core.assistant.AIProfile

internal fun AIProfile.origin(): String {
    val url = io.github.haige120.cloudreader.core.assistant.providerEndpoint(this).toHttpUrl()
    require(url.username.isEmpty() && url.password.isEmpty()) { "Use an endpoint without embedded credentials." }
    return "${url.scheme}://${url.host}:${url.port}"
}

// Legacy vaults contain a raw key. New records bind the key to its origin in one encrypted write.
internal fun boundKey(record: String?, legacyOrigin: String, origin: String): String? {
    if (record == null) return null
    if (!record.startsWith("origin-v1\n")) return record.takeIf { legacyOrigin == origin }
    val parts = record.split('\n', limit = 3)
    return parts.getOrNull(2)?.takeIf { parts[1] == origin }
}

internal fun encodeKey(key: String, origin: String) = "origin-v1\n$origin\n$key"

class AIService private constructor(private val keyFor: suspend (AIProfile) -> String?, private val calls: Call.Factory) {
    constructor(vault: SecureVault, prefs: CloudReaderPreferences) : this({ profile ->
        val savedOrigin = AIProfile(
            protocol = prefs.get("ai.protocol") ?: "openAIResponses", endpoint = prefs.get("ai.endpoint").orEmpty()
        ).origin()
        boundKey(vault.get("ai.apiKey"), savedOrigin, profile.origin())
    }, OkHttpClient.Builder().followRedirects(false).build())

    suspend fun ask(profile: AIProfile, messages: List<ChatMessage>, bookTitle: String? = null, selectedText: String? = null, bookContext: String? = null): String {
        val key = keyFor(profile)
        return RemoteAssistant({ key }, calls).ask(profile, messages, bookTitle, selectedText, bookContext)
    }

    suspend fun models(profile: AIProfile, enteredKey: String): List<String> {
        profile.origin()
        val key = enteredKey.trim().ifEmpty { keyFor(profile) }
        return RemoteAssistant({ key }, calls).models(profile)
    }

    companion object {
        internal fun forTesting(apiKey: () -> String?, calls: Call.Factory) = AIService({ apiKey() }, calls)
    }
}

internal fun buildAIInstructions(bookTitle: String?, selectedText: String?, bookContext: String?): String =
    sharedBuildAIInstructions(bookTitle, selectedText, bookContext)

internal fun buildAIPayload(profile: AIProfile, messages: List<ChatMessage>, instructions: String): JsonObject =
    sharedBuildAIPayload(profile, messages, instructions)

internal fun decodeAIAnswer(protocol: String, obj: JsonObject): String = sharedDecodeAIAnswer(protocol, obj)
