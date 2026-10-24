package io.github.haige120.cloudreader.core

import io.github.haige120.cloudreader.core.assistant.AIProfile
import io.github.haige120.cloudreader.core.assistant.buildAIPayload
import io.github.haige120.cloudreader.core.assistant.buildAIInstructions
import io.github.haige120.cloudreader.core.assistant.decodeAIAnswer
import io.github.haige120.cloudreader.core.model.ChatMessage
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AssistantProtocolTest {
    @Test
    fun payloadsBoundContextAndDecodeResponses() {
        val message = ChatMessage("00000000-0000-0000-0000-000000000001", "user", "Explain this", 1.0)
        val instructions = buildAIInstructions("Book", "selected", "context", maximumCharacters = 4)
        assertTrue(instructions.contains("sele"))
        val payload = buildAIPayload(AIProfile(protocol = "openAIResponses", model = "demo"), listOf(message), instructions)
        assertEquals("demo", payload["model"]?.toString()?.trim('"'))
        val answer = decodeAIAnswer("openAIResponses", Json.parseToJsonElement("""{"output_text":"done"}""").jsonObject)
        assertEquals("done", answer)
    }
}
