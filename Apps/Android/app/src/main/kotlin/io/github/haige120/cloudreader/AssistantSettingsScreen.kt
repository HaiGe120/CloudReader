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

    io.github.haige120.cloudreader.ui.AssistantContent(
        chats = chats, active = active, draft = state.draft, busy = state.busy,
        includeContext = state.includeContext,
        contextPreview = readerContext?.selectedText ?: active?.selectedText ?: readerContext?.book?.title ?: active?.bookTitle,
        error = state.error, profileLabel = "$aiName · ${model.ifBlank { "Set up an AI model in Settings" }}",
        onDraft = assistant::updateDraft, onSelect = assistant::selectConversation, onNew = assistant::newConversation,
        onConsent = assistant::setContextConsent,
        onSend = {
            scope.launch {
                val sourceBook = readerContext?.book ?: active?.bookID?.let { id -> app.database.libraryDao().book(id)?.toDomain() }
                val selected = readerContext?.selectedText ?: active?.selectedText
                val bounded = if (state.includeContext && selected.isNullOrBlank() && sourceBook != null) boundedBookText(androidContext, app, sourceBook) else null
                assistant.send(AIProfile(aiName, protocol, endpoint, model), AssistantContext(sourceBook, selected, bounded))
            }
        },
        onCancel = assistant::cancelRequest,
        onRetry = { assistant.retry(AIProfile(aiName, protocol, endpoint, model)) },
        onDelete = assistant::deleteActive,
        onShare = {
            active?.let { chat ->
                val prompt = buildString {
                    append(chat.messages.lastOrNull { it.role == "user" }?.text.orEmpty())
                    if (state.includeContext) {
                        chat.selectedText?.let { append("\n\nSelected passage:\n$it") }
                        chat.bookContext?.let { append("\n\nBook excerpt:\n$it") }
                    }
                }
                if (prompt.isNotBlank()) androidContext.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, prompt), "Share prompt"))
            }
        },
    )
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
    onGoogleCredentialsSaved: () -> Unit = {},
) {
    val scope = rememberCoroutineScope()
    val model: SettingsViewModel = viewModel(factory = SettingsViewModel.factory(app))
    val state by model.state.collectAsStateWithLifecycle()
    val selected = state.selectedProviders
    var showGoogleSetup by remember { mutableStateOf(false) }
    val googleRegistration = remember(app) { OAuthConnector(app, app.preferences, app.vault).googleOAuthRegistration() }
    val providerIDs = listOf("googleDrive", "dropbox", "pCloud", "webDAV", "sftp", "filesFolder")
    val providerNames = mapOf("googleDrive" to "Google Drive", "dropbox" to "Dropbox", "pCloud" to "pCloud", "webDAV" to "HTTPS WebDAV", "sftp" to "SFTP", "filesFolder" to "Android folder")
    LaunchedEffect(state.message) {
        state.message?.let { onMessage(it); model.consumeMessage() }
    }
    LaunchedEffect(state.googleCredentialsSavedRevision) {
        if (state.googleCredentialsSavedRevision > 0) onGoogleCredentialsSaved()
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 22.dp, vertical = 18.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Settings", fontFamily = FontFamily.Serif, fontSize = 29.sp, fontWeight = FontWeight.SemiBold)
        Text("Your connection details stay on this device. Sync copies books, progress, favorites, deletions, and saved conversations.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.secondary)
        SectionTitle("Sync destinations")
        providerIDs.forEach { id ->
            val folderReady = id != "filesFolder" || state.folderName.isNotBlank()
            val providerReady = folderReady && (id != "googleDrive" || !state.googleCredentialsSaving)
            Row(Modifier.fillMaxWidth().background(Color(0xFFFFFDF7), RoundedCornerShape(14.dp)).clickable(enabled = providerReady) { model.selectProvider(id, id !in selected) }.padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                Checkbox(checked = id in selected, onCheckedChange = { checked -> if (providerReady) model.selectProvider(id, checked) }, enabled = providerReady)
                Column(Modifier.weight(1f)) {
                    Text(providerNames.getValue(id), fontWeight = FontWeight.SemiBold)
                    Text(if (id == "filesFolder" && !folderReady) "Choose a folder below" else if (id in selected) "Selected for foreground sync" else "Not selected", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.secondary)
                }
                when (id) {
                    "googleDrive" -> TextButton(onClick = onConnectGoogle, enabled = !googleConnection.busy && !state.googleCredentialsSaving) {
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
        SectionTitle("Google Drive app credentials")
        Text("Use your own Google Cloud project's Web application OAuth client ID and secret. That project also needs an Android OAuth client registered for this app's package and signing certificate. Android client IDs do not have a secret.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
        TextButton(onClick = { showGoogleSetup = true }) { Text("Android registration details") }
        Field("Google OAuth client ID (Web application)", state.googleClientId, { model.update(SettingsField.GOOGLE_CLIENT_ID, it) }, placeholder = "…apps.googleusercontent.com")
        SecretField("Google OAuth client secret", state.googleClientSecret, { model.update(SettingsField.GOOGLE_CLIENT_SECRET, it) }, "Leave blank to keep the saved secret for this ID")
        Button(onClick = { model.saveGoogleCredentials() }, enabled = !googleConnection.busy && !state.googleCredentialsSaving) { Text(if (state.googleCredentialsSaving) "Saving…" else "Save Google app credentials") }
        Text("Save first, then tap Google Drive Connect above. Changing credentials requires reconnecting. Clear the client ID and leave the secret blank to return to built-in Google sign-in.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)

        SectionTitle("Other provider app IDs")
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
    if (showGoogleSetup) {
        AlertDialog(
            onDismissRequest = { showGoogleSetup = false },
            title = { Text("Google Drive setup") },
            text = {
                androidx.compose.foundation.text.selection.SelectionContainer {
                    Text("Create Android and Web application OAuth clients in the same Google Cloud project, enable the Drive API, and configure the consent audience. Use the Web client ID and secret below.\n\n$googleRegistration\n\nGoogle allows this package and certificate pair in only one project. Web credentials from a different project will not work with that Android registration.")
                }
            },
            confirmButton = { TextButton(onClick = { showGoogleSetup = false }) { Text("Done") } },
        )
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
