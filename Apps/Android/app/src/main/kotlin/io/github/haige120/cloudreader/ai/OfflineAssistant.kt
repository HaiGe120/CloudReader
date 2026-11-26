package io.github.haige120.cloudreader.ai

import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import io.github.haige120.cloudreader.domain.ChatMessage

internal suspend fun answerOffline(
    messages: List<ChatMessage>, title: String?, selected: String?, nearby: String?,
): String {
    val model = Generation.getClient()
    try {
        check(model.checkStatus() == FeatureStatus.AVAILABLE) {
            "You’re offline and Gemini Nano is unavailable on this device. Reconnect and retry."
        }
        val prompt = buildString {
            appendLine(buildAIInstructions(title, selected?.take(2000), nearby?.take(4000)))
            messages.takeLast(8).forEach { appendLine("${it.role}: ${it.text.take(1500)}") }
        }
        return model.generateContent(prompt).candidates.firstOrNull()?.text?.takeIf(String::isNotBlank)
            ?: error("Gemini Nano returned no readable answer.")
    } finally {
        model.close()
    }
}
