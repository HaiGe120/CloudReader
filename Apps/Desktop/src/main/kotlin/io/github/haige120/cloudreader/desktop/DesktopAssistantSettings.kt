package io.github.haige120.cloudreader.desktop

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.haige120.cloudreader.core.assistant.AIProfile
import io.github.haige120.cloudreader.core.assistant.RemoteAssistant
import io.github.haige120.cloudreader.core.assistant.providerEndpoint
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient

internal fun AIProfile.desktopOrigin(): String {
    val url = providerEndpoint(this).toHttpUrl()
    require(url.username.isEmpty() && url.password.isEmpty()) { "Use an endpoint without embedded credentials." }
    return "${url.scheme}://${url.host}:${url.port}"
}

private val assistantClient = OkHttpClient.Builder().followRedirects(false).build()
internal fun desktopAssistant(profile: AIProfile, settings: DesktopSettings, secrets: DesktopSecrets, enteredKey: String = ""): RemoteAssistant {
    val origin = profile.desktopOrigin()
    val key = enteredKey.trim().ifEmpty { savedDesktopKey(origin, settings, secrets::read) }
    return RemoteAssistant({ key }, assistantClient)
}

internal fun savedDesktopKey(origin: String, settings: DesktopSettings, read: (String) -> String?): String? {
    read(originKey(origin))?.let { return it }
    val legacyOrigin = settings.get("ai.legacyKeyOrigin").ifEmpty {
        runCatching { settings.profile().desktopOrigin() }.getOrDefault("invalid")
    }
    return if (origin == legacyOrigin) read("ai.apiKey") else null
}

internal fun originKey(origin: String) = "ai.apiKey." + digest(origin.toByteArray())

@Composable
internal fun DesktopModelPicker(profile: AIProfile, enteredKey: String, settings: DesktopSettings, secrets: DesktopSecrets,
    onChoose: (String) -> Unit, onDismiss: () -> Unit) {
    var models by remember { mutableStateOf<List<String>?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    LaunchedEffect(Unit) {
        try {
            models = withContext(Dispatchers.IO) { desktopAssistant(profile, settings, secrets, enteredKey).models(profile) }
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: Exception) {
            error = failure.message ?: "Could not load models."
        }
    }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Choose a model") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(query, { query = it }, label = { Text("Search models") }, singleLine = true)
            val choices = models?.filter { it.contains(query.trim(), ignoreCase = true) }
            when {
                error != null -> Text(error.orEmpty(), color = MaterialTheme.colorScheme.error)
                choices == null -> CircularProgressIndicator()
                choices.isEmpty() -> Text("No matching models")
                else -> LazyColumn(Modifier.heightIn(max = 320.dp)) {
                    items(choices, key = { it }) { model -> TextButton(onClick = { onChoose(model) }) { Text(model) } }
                }
            }
        }
    }, confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } })
}

@Composable
internal fun DesktopWordTranslation(word: String, settings: DesktopSettings, secrets: DesktopSecrets, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val profile = remember { settings.profile().copy(webSearch = false) }
    val valid = word.length in 1..120 && word.matches(Regex("""[\p{L}\p{M}]+(?:[-'’][\p{L}\p{M}]+)*"""))
    var language by remember { mutableStateOf(settings.get("reader.translationLanguage", java.util.Locale.getDefault().displayLanguage)) }
    var answer by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    AlertDialog(onDismissRequest = onDismiss, title = { Text("Translate word") }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            if (!valid) Text("Select one word in the book, then choose Translate.")
            else {
                Text(word, style = MaterialTheme.typography.titleMedium)
                OutlinedTextField(language, { language = it; answer = null; error = null }, enabled = !busy,
                    label = { Text("Translate into") }, singleLine = true)
                Text("Send this word to ${profile.name} for translation.", style = MaterialTheme.typography.bodySmall)
                answer?.let { androidx.compose.foundation.text.selection.SelectionContainer { Text(it) } }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (busy) CircularProgressIndicator()
            }
        }
    }, confirmButton = {
        if (valid) Button(enabled = !busy && language.isNotBlank(), onClick = {
            busy = true
            error = null
            scope.launch {
                try {
                    val target = language.trim()
                    answer = withContext(Dispatchers.IO) {
                        settings.save(mapOf("reader.translationLanguage" to target))
                        val message = io.github.haige120.cloudreader.core.model.ChatMessage(
                            java.util.UUID.randomUUID().toString(), "user", "Translate the word “$word” into $target. Give only the translation.",
                            io.github.haige120.cloudreader.core.model.nowFoundationSeconds())
                        desktopAssistant(profile, settings, secrets).ask(profile, listOf(message))
                    }
                } catch (cancelled: CancellationException) {
                    throw cancelled
                } catch (failure: Exception) {
                    error = failure.message ?: "Translation failed."
                } finally {
                    busy = false
                }
            }
        }) { Text("Translate") }
    }, dismissButton = { TextButton(onClick = onDismiss) { Text("Close") } })
}
