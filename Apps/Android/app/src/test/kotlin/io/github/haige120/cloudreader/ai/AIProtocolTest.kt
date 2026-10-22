package io.github.haige120.cloudreader.ai

import io.github.haige120.cloudreader.domain.ChatMessage
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import okhttp3.Call
import okhttp3.Callback
import okhttp3.Request
import okhttp3.Response
import java.io.IOException
import okio.Timeout

class AIProtocolTest {
    private val messages = listOf(ChatMessage("00000000-0000-0000-0000-000000000001", "user", "What does this mean?", 0.0))
    private val profile = AIProfile(model = "test-model")

    @Test fun buildsAllThreeRequestShapes() {
        val chat = buildAIPayload(profile.copy(protocol = "openAIChatCompletions"), messages, "Instructions")
        assertEquals("test-model", chat["model"]!!.jsonPrimitive.content)
        assertEquals("system", chat["messages"]!!.jsonArray.first().jsonObject["role"]!!.jsonPrimitive.content)
        assertEquals("user", chat["messages"]!!.jsonArray.last().jsonObject["role"]!!.jsonPrimitive.content)

        val responses = buildAIPayload(profile.copy(protocol = "openAIResponses"), messages, "Instructions")
        assertEquals("developer", responses["input"]!!.jsonArray.first().jsonObject["role"]!!.jsonPrimitive.content)

        val anthropic = buildAIPayload(profile.copy(protocol = "anthropicMessages"), messages, "Instructions")
        assertEquals("Instructions", anthropic["system"]!!.jsonPrimitive.content)
        assertEquals(1200, anthropic["max_tokens"]!!.jsonPrimitive.content.toInt())
        assertEquals("user", anthropic["messages"]!!.jsonArray.single().jsonObject["role"]!!.jsonPrimitive.content)
    }

    @Test fun contextIsAbsentUntilExplicitlyProvidedAndEachTextIsBounded() {
        val plain = buildAIInstructions(null, null, null)
        assertFalse(plain.contains("<context>"))
        val selected = "x".repeat(20_000)
        val fullText = "y".repeat(20_001)
        val included = buildAIInstructions("A Book", selected, fullText)
        assertTrue(included.contains("A Book"))
        assertTrue(included.contains("x".repeat(18_000)))
        assertFalse(included.contains("x".repeat(18_001)))
        assertTrue(included.contains("y".repeat(18_000)))
        assertFalse(included.contains("y".repeat(18_001)))
    }

    @Test fun decodesProviderResponses() {
        val json = Json
        assertEquals("chat answer", decodeAIAnswer("openAIChatCompletions", json.parseToJsonElement(
            """{"choices":[{"message":{"content":"chat answer"}}]}""",
        ).jsonObject))
        assertEquals("responses answer", decodeAIAnswer("openAIResponses", json.parseToJsonElement(
            """{"output_text":"responses answer"}""",
        ).jsonObject))
        assertEquals("anthropic answer", decodeAIAnswer("anthropicMessages", json.parseToJsonElement(
            """{"content":[{"type":"text","text":"anthropic answer"}]}""",
        ).jsonObject))
    }

    @Test fun coroutineCancellationCancelsTheActiveOkHttpCall() = runBlocking {
        val enteredEnqueue = CompletableDeferred<Unit>()
        lateinit var pendingCall: PendingCall
        val callFactory = Call.Factory { request ->
            PendingCall(request, enteredEnqueue).also { pendingCall = it }
        }
        val service = AIService.forTesting({ "test-key" }, callFactory)

        val request = launch {
            service.ask(
                profile.copy(endpoint = "http://127.0.0.1/ai"),
                messages,
            )
        }
        enteredEnqueue.await()
        request.cancelAndJoin()

        assertTrue(pendingCall.isCanceled())
    }

    private class PendingCall(
        private val request: Request,
        private val enteredEnqueue: CompletableDeferred<Unit>,
    ) : Call {
        @Volatile private var canceled = false
        @Volatile private var callback: Callback? = null

        override fun request() = request
        override fun execute(): Response = error("The asynchronous path should be used")
        override fun enqueue(responseCallback: Callback) {
            callback = responseCallback
            enteredEnqueue.complete(Unit)
        }
        override fun cancel() {
            canceled = true
            callback?.onFailure(this, IOException("Canceled"))
        }
        override fun isExecuted() = callback != null
        override fun isCanceled() = canceled
        override fun timeout() = Timeout()
        override fun clone(): Call = PendingCall(request, enteredEnqueue)
    }
}
