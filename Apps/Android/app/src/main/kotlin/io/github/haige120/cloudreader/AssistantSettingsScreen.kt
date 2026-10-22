package io.github.haige120.cloudreader

import android.app.Activity
import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.haige120.cloudreader.ai.AIProfile
import io.github.haige120.cloudreader.ai.readBoundedBookContext
import io.github.haige120.cloudreader.data.toDomain
import io.github.haige120.cloudreader.sync.OAuthConnector
import java.io.File
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable
fun AssistantScreen(app: CloudReaderApp, context: ReaderContext?, onContextConsumed: () -> Unit, onMessage: (String) -> Unit) {
    val aiName by app.preferences.observe("ai.name", "My AI").collectAsState(initial = "My AI")
    val protocol by app.preferences.observe("ai.protocol", "openAIResponses").collectAsState(initial = "openAIResponses")
    val endpoint by app.preferences.observe("ai.endpoint", "").collectAsState(initial = "")
    val model by app.preferences.observe("ai.model", "").collectAsState(initial = "")
    val assistant: AssistantViewModel = viewModel(factory = AssistantViewModel.factory(app))
    val state by assistant.state.collectAsStateWithLifecycle()
    val chats = state.conversations
    val active = state.activeConversation
    val readerContext = state.pendingReaderContext
    var confirmDelete by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val androidContext = LocalContext.current

    LaunchedEffect(context?.book?.id, context?.selectedText) {
        if (context != null) {
            assistant.prepareReaderContext(AssistantContext(context.book, context.selectedText))
            onContextConsumed()
        }
    }
    LaunchedEffect(state.error) { state.error?.let(onMessage) }

    Column(Modifier.fillMaxSize().padding(horizontal = 20.dp, vertical = 14.dp)) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Ask CloudReader", fontFamily = FontFamily.Serif, fontSize = 29.sp, fontWeight = FontWeight.SemiBold)
                Text("$aiName · ${model.ifBlank { "Set up an AI model in Settings" }}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.secondary)
            }
            IconButton(onClick = {
                val chat = active
                if (chat != null) {
                    val latestPrompt = chat.messages.lastOrNull { it.role == "user" }?.text.orEmpty()
                    val prepared = buildString {
                        append(latestPrompt)
                    if (state.includeContext && !chat.selectedText.isNullOrBlank()) append("\n\nSelected passage:\n${chat.selectedText}")
                    if (state.includeContext && !chat.bookContext.isNullOrBlank()) append("\n\nBook excerpt:\n${chat.bookContext}")
                    }
                    if (prepared.isNotBlank()) androidContext.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, prepared), "Share prompt"))
                }
            }) { Icon(Icons.Filled.Share, contentDescription = "Share prepared prompt") }
            IconButton(onClick = assistant::newConversation) { Icon(Icons.Filled.Add, contentDescription = "New conversation") }
            if (active != null) IconButton(onClick = { confirmDelete = true }) {
                Icon(Icons.Filled.DeleteOutline, contentDescription = "Delete conversation")
            }
        }

        if (chats.isNotEmpty()) {
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                chats.forEach { chat ->
                    val selected = state.activeConversationId == chat.id
                    TextButton(onClick = { assistant.selectConversation(chat.id) }, modifier = Modifier.background(if (selected) Color(0xFFE4EADF) else Color(0xFFEFE9DD), RoundedCornerShape(18.dp))) {
                        Text(chat.title.ifBlank { "New conversation" }.take(28), maxLines = 1)
                    }
                }
            }
            Spacer(Modifier.height(6.dp))
        }

        val current = active
        if (current == null || current.messages.isEmpty()) {
            Column(Modifier.weight(1f).fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.AutoMirrored.Filled.Send, contentDescription = null, tint = MaterialTheme.colorScheme.primary)
                Spacer(Modifier.height(12.dp))
                Text(if (readerContext?.selectedText != null) "Ask about this passage" else "What are you reading today?", fontFamily = FontFamily.Serif, fontSize = 21.sp, textAlign = TextAlign.Center)
                Text("Your conversations stay in your library and sync with its selected destinations.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 7.dp))
            }
        } else {
            LazyColumn(Modifier.weight(1f).fillMaxWidth(), contentPadding = PaddingValues(vertical = 12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                items(current.messages, key = { it.id }) { message ->
                    val userMessage = message.role == "user"
                    Row(Modifier.fillMaxWidth(), horizontalArrangement = if (userMessage) Arrangement.End else Arrangement.Start) {
                        Card(
                            modifier = Modifier.fillMaxWidth(0.9f),
                            shape = RoundedCornerShape(18.dp),
                            colors = CardDefaults.cardColors(containerColor = if (userMessage) Color(0xFFE4EADF) else Color(0xFFFFFDF7)),
                        ) { Text(message.text, modifier = Modifier.padding(14.dp), style = MaterialTheme.typography.bodyLarge) }
                    }
                }
                if (state.busy) item { CircularProgressIndicator(modifier = Modifier.padding(14.dp)) }
            }
        }

        val hasReaderContext = readerContext?.book != null || readerContext?.selectedText != null || active?.selectedText != null || active?.bookID != null
        if (hasReaderContext) {
            Row(Modifier.fillMaxWidth().clickable { assistant.setContextConsent(!state.includeContext) }.padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = state.includeContext, onCheckedChange = assistant::setContextConsent)
                Column {
                    Text("Include selected passage or book text", style = MaterialTheme.typography.labelLarge)
                    Text("Included only after sending · up to 18,000 characters · saved with this chat and synced to selected destinations", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                }
            }
        }
        Row(Modifier.fillMaxWidth().padding(bottom = 8.dp), verticalAlignment = Alignment.Bottom) {
            OutlinedTextField(
                value = state.draft, onValueChange = assistant::updateDraft, modifier = Modifier.weight(1f),
                placeholder = { Text("Ask a question") }, minLines = 1, maxLines = 5, shape = RoundedCornerShape(18.dp), enabled = !state.busy,
            )
            IconButton(
                enabled = !state.busy && state.draft.isNotBlank(),
                onClick = {
                    scope.launch {
                        val sourceBook = readerContext?.book ?: active?.bookID?.let { id -> app.database.libraryDao().book(id)?.toDomain() }
                        val selected = readerContext?.selectedText ?: active?.selectedText
                        val bounded = if (state.includeContext && selected.isNullOrBlank() && sourceBook != null) boundedBookText(androidContext, app, sourceBook) else null
                        assistant.send(AIProfile(aiName, protocol, endpoint, model), AssistantContext(sourceBook, selected, bounded))
                    }
                },
            ) { Icon(Icons.AutoMirrored.Filled.Send, contentDescription = "Send question", tint = MaterialTheme.colorScheme.primary) }
            if (state.busy) IconButton(onClick = assistant::cancelRequest) { Text("Stop") }
            if (!state.busy && state.error != null) IconButton(onClick = { assistant.retry(AIProfile(aiName, protocol, endpoint, model)) }) { Text("Retry") }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete conversation?") },
            text = { Text("This also removes it from selected sync destinations when they next connect.") },
            confirmButton = {
                TextButton(onClick = {
                    val doomed = active
                    confirmDelete = false
                    if (doomed != null) assistant.removeConversation(doomed)
                }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

private suspend fun boundedBookText(context: android.content.Context, app: CloudReaderApp, book: io.github.haige120.cloudreader.domain.BookRecord): String? = withContext(Dispatchers.IO) {
    runCatching {
        if (book.format == "txt") {
            app.library.fileFor(book)?.takeIf(File::isFile)?.let(::readBoundedBookContext)
        } else if (book.format == "pdf") {
            PdfReaderActivity.pdfContextFile(context, book.id).takeIf(File::isFile)?.let(::readBoundedBookContext)
        } else null
    }.getOrNull()
}

@Composable
fun SettingsScreen(
    activity: Activity,
    app: CloudReaderApp,
    onPickFolder: () -> Unit,
    googleConnection: GoogleDriveConnectionState,
    onConnectGoogle: () -> Unit,
    onMessage: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    val model: SettingsViewModel = viewModel(factory = SettingsViewModel.factory(app))
    val state by model.state.collectAsStateWithLifecycle()
    val selected = state.selectedProviders
    val providerIDs = listOf("googleDrive", "dropbox", "pCloud", "webDAV", "sftp", "filesFolder")
    val providerNames = mapOf("googleDrive" to "Google Drive", "dropbox" to "Dropbox", "pCloud" to "pCloud", "webDAV" to "HTTPS WebDAV", "sftp" to "SFTP", "filesFolder" to "Android folder")
    LaunchedEffect(state.message) {
        state.message?.let { onMessage(it); model.consumeMessage() }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 22.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Settings", fontFamily = FontFamily.Serif, fontSize = 29.sp, fontWeight = FontWeight.SemiBold)
        Text("Your connection details stay on this device. Sync copies books, progress, favorites, deletions, and saved conversations.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.secondary)
        SectionTitle("Sync destinations")
        providerIDs.forEach { id ->
            val folderReady = id != "filesFolder" || state.folderName.isNotBlank()
            Row(Modifier.fillMaxWidth().background(Color(0xFFFFFDF7), RoundedCornerShape(14.dp)).clickable { if (folderReady) model.selectProvider(id, id !in selected) }.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = id in selected, onCheckedChange = { checked -> if (folderReady) model.selectProvider(id, checked) }, enabled = folderReady)
                Column(Modifier.weight(1f)) {
                    Text(providerNames.getValue(id), fontWeight = FontWeight.SemiBold)
                    Text(if (id == "filesFolder" && !folderReady) "Choose a folder below" else if (id in selected) "Selected for foreground sync" else "Not selected", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                }
                when (id) {
                    "googleDrive" -> TextButton(onClick = onConnectGoogle, enabled = !googleConnection.busy) {
                        Text(if (googleConnection.busy) "Connecting…" else if (id in selected) "Reconnect" else "Connect")
                    }
                    "dropbox" -> TextButton(onClick = {
                        scope.launch { runCatching { OAuthConnector(activity, app.preferences, app.vault).connectDropbox() }.onSuccess { onMessage(it) }.onFailure { onMessage(it.localizedMessage ?: "Dropbox sign-in failed") } }
                    }) { Text("Sign in") }
                    "pCloud" -> TextButton(onClick = {
                        scope.launch { runCatching { OAuthConnector(activity, app.preferences, app.vault).connectPCloud() }.onSuccess { model.selectProvider(id, true); onMessage(it) }.onFailure { onMessage(it.localizedMessage ?: "pCloud sign-in failed") } }
                    }) { Text("Sign in") }
                    "filesFolder" -> TextButton(onClick = onPickFolder) { Text(if (folderReady) "Change" else "Choose") }
                    else -> Unit
                }
            }
            if (id == "googleDrive") {
                val status = if (googleConnection.busy) "Waiting for Google authorization…" else googleConnection.message
                if (status != null) Text(status, style = MaterialTheme.typography.bodySmall)
            }
        }
        Field("Dropbox app key", state.dropboxKey, { model.update(SettingsField.DROPBOX_KEY, it) })
        Field("pCloud app key", state.pcloudKey, { model.update(SettingsField.PCLOUD_KEY, it) })
        Button(onClick = { model.saveProviderIDs() }) { Text("Save provider app IDs") }

        SectionTitle("HTTPS WebDAV")
        Field("Server URL", state.webdavUrl, { model.update(SettingsField.WEBDAV_URL, it) }, placeholder = "https://example.com/dav")
        Field("Username", state.webdavUser, { model.update(SettingsField.WEBDAV_USER, it) })
        SecretField("Password", state.webdavPassword, { model.update(SettingsField.WEBDAV_PASSWORD, it) }, "Leave blank to keep the saved password")
        Button(onClick = { model.saveWebDav() }) { Text("Save WebDAV") }

        SectionTitle("Pinned-host-key SFTP")
        Field("Host", state.sftpHost, { model.update(SettingsField.SFTP_HOST, it) })
        Field("Port", state.sftpPort, { model.update(SettingsField.SFTP_PORT, it) }, placeholder = "22")
        Field("Username", state.sftpUser, { model.update(SettingsField.SFTP_USER, it) })
        SecretField("Password", state.sftpPassword, { model.update(SettingsField.SFTP_PASSWORD, it) }, "Leave blank to keep the saved password")
        Field("Remote directory", state.sftpDirectory, { model.update(SettingsField.SFTP_DIRECTORY, it) }, placeholder = "CloudReader")
        Field("OpenSSH host public key", state.sftpKey, { model.update(SettingsField.SFTP_KEY, it) }, placeholder = "ssh-ed25519 AAAA…")
        Button(onClick = { model.saveSftp() }) { Text("Save pinned SFTP") }

        SectionTitle("Remote AI profile")
        Field("Profile name", state.aiName, { model.update(SettingsField.AI_NAME, it) })
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            listOf("openAIResponses", "openAIChatCompletions", "anthropicMessages").forEach { choice ->
                TextButton(onClick = { model.update(SettingsField.AI_PROTOCOL, choice) }, modifier = Modifier.background(if (state.aiProtocol == choice) Color(0xFFE4EADF) else Color.Transparent, RoundedCornerShape(16.dp))) {
                    Text(when (choice) { "openAIResponses" -> "Responses"; "openAIChatCompletions" -> "Chat Completions"; else -> "Anthropic" }, fontSize = 12.sp)
                }
            }
        }
        Field("Model", state.aiModel, { model.update(SettingsField.AI_MODEL, it) }, placeholder = "Model ID")
        Field("Custom HTTPS endpoint (optional)", state.aiEndpoint, { model.update(SettingsField.AI_ENDPOINT, it) }, placeholder = "Leave blank for the provider default")
        SecretField("API key", state.aiKey, { model.update(SettingsField.AI_KEY, it) })
        Button(onClick = { model.saveAi() }) { Text("Save AI profile") }
        Text("Book text is included only when you turn it on in a conversation and press Send. Android uses remote AI; Apple on-device models and Siri stay Apple-only.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
        Spacer(Modifier.height(18.dp))
    }
}

@Composable
private fun SectionTitle(title: String) {
    HorizontalDivider(Modifier.padding(top = 9.dp))
    Text(title, fontFamily = FontFamily.Serif, fontSize = 21.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 4.dp))
}

@Composable
private fun Field(label: String, value: String, onValue: (String) -> Unit, placeholder: String = "") {
    OutlinedTextField(value, onValueChange = onValue, modifier = Modifier.fillMaxWidth(), label = { Text(label) }, placeholder = { if (placeholder.isNotBlank()) Text(placeholder) }, singleLine = true)
}

@Composable
private fun SecretField(label: String, value: String, onValue: (String) -> Unit, placeholder: String = "") {
    OutlinedTextField(value, onValueChange = onValue, modifier = Modifier.fillMaxWidth(), label = { Text(label) }, placeholder = { if (placeholder.isNotBlank()) Text(placeholder) }, singleLine = true, visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation())
}
